#!/usr/bin/env python3
"""ClearLedger operational tooling used by deploy.sh / destroy.sh.

Sub-commands
  guard      Remove out-of-band IAM policies from the six workload roles and
             unrestricted egress rules from the alb/rds/valkey security groups.
  reconcile  Converge derived data stores (SQS backlog, DynamoDB projections,
             Valkey cache, versioned S3 audit archive) against PostgreSQL.
  sweep      Prefix-scoped teardown of anything left behind after
             `terraform destroy` (never touches cl-base-* resources).

PostgreSQL access goes through `psql` (no Python driver is required).
Secrets are never printed.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
BATCH_RE = re.compile(r"^ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson$")
CACHE_PREFIX = "clearledger:settlement:"

ENVELOPE_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
                  "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty",
              "entryId", "status", "clearingStage", "memo"]


def log(msg):
    print(f"[clearledger-ops] {msg}", flush=True)


# ---------------------------------------------------------------------------
# AWS clients
# ---------------------------------------------------------------------------

class Aws:
    def __init__(self, endpoint, region):
        cfg = Config(retries={"max_attempts": 8, "mode": "standard"},
                     connect_timeout=10, read_timeout=180)
        self._kw = dict(endpoint_url=endpoint, region_name=region,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
                        config=cfg)
        self._s3cfg = Config(retries={"max_attempts": 8, "mode": "standard"},
                             s3={"addressing_style": "path"}, connect_timeout=10, read_timeout=180)
        self._cache = {}

    def __call__(self, name):
        if name not in self._cache:
            kw = dict(self._kw)
            if name == "s3":
                kw["config"] = self._s3cfg
            self._cache[name] = boto3.client(name, **kw)
        return self._cache[name]


def err_code(e):
    return e.response.get("Error", {}).get("Code", "") if isinstance(e, ClientError) else ""


# ---------------------------------------------------------------------------
# PostgreSQL via psql
# ---------------------------------------------------------------------------

class Pg:
    def __init__(self, host, port, db, user, password):
        self.args = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
                     "-h", host, "-p", str(port), "-U", user, "-d", db]
        self.env = dict(os.environ, PGPASSWORD=password, PGTZ="UTC",
                        PGCONNECT_TIMEOUT="10", PGAPPNAME="clearledger-deploy")

    def run(self, sql):
        last = None
        for attempt in range(5):
            p = subprocess.run(self.args + ["-c", sql], env=self.env,
                               capture_output=True, text=True)
            if p.returncode == 0:
                return p.stdout
            last = p.stderr.strip()
            time.sleep(2 + attempt * 2)
        raise RuntimeError(f"psql failed: {last}")

    def json(self, sql):
        out = self.run(f"SELECT COALESCE(json_agg(t), '[]'::json) FROM ({sql}) t").strip()
        return json.loads(out or "[]")

    def scalar(self, sql):
        return self.run(sql).strip()


# ---------------------------------------------------------------------------
# Formatting helpers (mirror clearledger-projector / API serialisation)
# ---------------------------------------------------------------------------

def rfc3339(ts):
    """PostgreSQL JSON timestamptz -> chrono to_rfc3339() (AutoSi, +00:00)."""
    if ts is None:
        return None
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(.*)$", ts)
    if not m:
        return ts
    date, clock, frac, tz = m.groups()
    tz = tz or "+00:00"
    if tz in ("Z", "+00", "+00:00"):
        tz = "+00:00"
    out = f"{date}T{clock}"
    if frac:
        frac = (frac + "000000000")[:9]
        if frac.endswith("000000"):
            frac = frac[:3]
        elif frac.endswith("000"):
            frac = frac[:6]
        if int(frac) != 0:
            out += "." + frac
    return out + tz


def rfc3339_z(ts):
    s = rfc3339(ts)
    return s[:-6] + "Z" if s and s.endswith("+00:00") else s


def parse_ts(s):
    if not isinstance(s, str):
        return None
    try:
        t = s.strip().replace("z", "Z")
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        m = re.match(r"^(.*T\d{2}:\d{2}:\d{2})(?:\.(\d+))?([+-]\d{2}:\d{2})$", t)
        if not m:
            return None
        base, frac, tz = m.groups()
        frac = ((frac or "") + "000000")[:6]
        return dt.datetime.fromisoformat(f"{base}.{frac}{tz}")
    except Exception:
        return None


def canonical_envelope(payload):
    data = payload.get("data") or {}
    d = {k: data[k] for k in DATA_ORDER if k in data}
    for k in data:
        if k not in d:
            d[k] = data[k]
    env = {}
    for k in ENVELOPE_ORDER:
        if k in payload:
            env[k] = d if k == "data" else payload[k]
    for k in payload:
        if k not in env:
            env[k] = payload[k]
    return env


def canonical_json(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


# ---------------------------------------------------------------------------
# Minimal RESP client for Valkey
# ---------------------------------------------------------------------------

class Resp:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, int(port)), timeout=15)
        self.f = self.sock.makefile("rb")

    def cmd(self, *args):
        out = [b"*%d\r\n" % len(args)]
        for a in args:
            b = a if isinstance(a, bytes) else str(a).encode()
            out.append(b"$%d\r\n%s\r\n" % (len(b), b))
        self.sock.sendall(b"".join(out))
        return self._read()

    def _read(self):
        line = self.f.readline()
        if not line:
            raise ConnectionError("valkey connection closed")
        t, rest = line[:1], line[1:-2]
        if t == b"+":
            return rest.decode()
        if t == b"-":
            raise RuntimeError(rest.decode())
        if t == b":":
            return int(rest)
        if t == b"$":
            n = int(rest)
            if n < 0:
                return None
            data = self.f.read(n + 2)
            return data[:-2]
        if t == b"*":
            n = int(rest)
            if n < 0:
                return None
            return [self._read() for _ in range(n)]
        raise RuntimeError(f"unexpected RESP reply {line!r}")


# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------

class Ctx:
    def __init__(self, manifest_path, config_path):
        with open(config_path) as fh:
            self.cfg = json.load(fh)
        with open(manifest_path) as fh:
            self.m = json.load(fh)
        self.prefix = self.cfg["resource_prefix"]
        self.region = self.cfg.get("region", "us-east-1")
        self.endpoint = self.cfg.get("aws_endpoint_url") or os.environ.get("AWS_ENDPOINT_URL")
        self.aws = Aws(self.endpoint, self.region)
        db = self.m["database"]
        self.pg = Pg(db["endpoint"], db["port"], self.cfg["db_name"], self.cfg["db_username"],
                     self.cfg["db_password"])


# ---------------------------------------------------------------------------
# guard: IAM + security-group drift
# ---------------------------------------------------------------------------

def cmd_guard(ctx):
    iam = ctx.aws("iam")
    p = ctx.prefix
    canonical = {
        f"{p}-ecs-execution": f"{p}-ecs-execution-policy",
        f"{p}-ecs-task": f"{p}-ecs-task-policy",
        f"{p}-projector": f"{p}-projector-policy",
        f"{p}-relay": f"{p}-relay-policy",
        f"{p}-archiver": f"{p}-archiver-policy",
        f"{p}-scheduler": f"{p}-scheduler-policy",
    }
    for role, keep in canonical.items():
        try:
            names = []
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                names += page.get("PolicyNames", [])
            for n in names:
                if n != keep:
                    log(f"removing out-of-band inline policy {n} from {role}")
                    iam.delete_role_policy(RoleName=role, PolicyName=n)
            attached = []
            for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
                attached += page.get("AttachedPolicies", [])
            for a in attached:
                log(f"detaching out-of-band managed policy {a['PolicyArn']} from {role}")
                iam.detach_role_policy(RoleName=role, PolicyArn=a["PolicyArn"])
        except ClientError as e:
            if err_code(e) not in ("NoSuchEntity", "NoSuchEntityException"):
                raise

    ec2 = ctx.aws("ec2")
    sgs = ctx.m["network"]["security_group_ids"]
    for role in ("alb", "rds", "valkey"):
        gid = sgs[role]
        try:
            g = ec2.describe_security_groups(GroupIds=[gid])["SecurityGroups"][0]
        except ClientError as e:
            log(f"security group {gid} not found ({err_code(e)})")
            continue
        for perm in g.get("IpPermissionsEgress", []):
            bad4 = [r for r in perm.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
            bad6 = [r for r in perm.get("Ipv6Ranges", []) if r.get("CidrIpv6") == "::/0"]
            if not bad4 and not bad6:
                continue
            rp = {"IpProtocol": perm["IpProtocol"]}
            if "FromPort" in perm:
                rp["FromPort"] = perm["FromPort"]
            if "ToPort" in perm:
                rp["ToPort"] = perm["ToPort"]
            if bad4:
                rp["IpRanges"] = [{"CidrIp": "0.0.0.0/0"}]
            if bad6:
                rp["Ipv6Ranges"] = [{"CidrIpv6": "::/0"}]
            log(f"revoking unrestricted egress on {role} security group")
            try:
                ec2.revoke_security_group_egress(GroupId=gid, IpPermissions=[rp])
            except ClientError as e:
                log(f"revoke failed: {err_code(e)}")


# ---------------------------------------------------------------------------
# reconcile helpers
# ---------------------------------------------------------------------------

def invoke(ctx, fn):
    lam = ctx.aws("lambda")
    r = lam.invoke(FunctionName=fn, InvocationType="RequestResponse", Payload=b"{}")
    body = r["Payload"].read().decode(errors="replace")
    if r.get("FunctionError"):
        raise RuntimeError(f"{fn} returned FunctionError: {body[:500]}")
    return body


def drain_outbox(ctx):
    fn = ctx.m["workers"]["outbox_relay"]["function_name"]
    for i in range(200):
        pending = int(ctx.pg.scalar("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL"))
        if pending == 0:
            log("outbox drained (0 unpublished rows)")
            return
        log(f"outbox has {pending} unpublished rows; invoking {fn}")
        try:
            invoke(ctx, fn)
        except Exception as e:  # transient cold start etc.
            log(f"relay invocation failed: {e}")
            time.sleep(3)
    raise RuntimeError("outbox could not be drained")


def wait_queue_idle(ctx, timeout=120):
    sqs = ctx.aws("sqs")
    url = ctx.m["messaging"]["queue_url"]
    deadline = time.time() + timeout
    idle = 0
    while time.time() < deadline:
        try:
            a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=[
                "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"])["Attributes"]
            n = int(a.get("ApproximateNumberOfMessages", 0)) + int(a.get("ApproximateNumberOfMessagesNotVisible", 0))
        except ClientError as e:
            log(f"queue attributes unavailable: {err_code(e)}")
            return
        if n == 0:
            idle += 1
            if idle >= 2:
                log("main queue idle")
                return
        else:
            idle = 0
        time.sleep(2)
    log("main queue still has in-flight messages; continuing with direct reconciliation")


def load_pg_state(ctx):
    settlements = ctx.pg.json(
        "SELECT settlement_id::text AS settlement_id, account_id, reference, debit_party, credit_party, "
        "current_status, current_stage, last_entry_id::text AS last_entry_id, last_memo, version, "
        "entry_count, created_at, updated_at FROM clearledger.settlements")
    events = ctx.pg.json(
        "SELECT seq, event_id::text AS event_id, settlement_id::text AS settlement_id, aggregate_version, "
        "event_type, correlation_id, idempotency_key, occurred_at, payload FROM clearledger.events "
        "ORDER BY settlement_id, aggregate_version")
    return settlements, events


def expected_items(settlements, events):
    items = {}
    for s in settlements:
        sid = s["settlement_id"]
        pk = f"SETTLEMENT#{sid}"
        it = {
            "PK": {"S": pk}, "SK": {"S": "STATE"},
            "GSI1PK": {"S": f"ACCOUNT#{s['account_id']}"}, "GSI1SK": {"S": pk},
            "settlement_id": {"S": sid}, "account_id": {"S": s["account_id"]},
            "reference": {"S": s["reference"]}, "debit_party": {"S": s["debit_party"]},
            "credit_party": {"S": s["credit_party"]}, "status": {"S": s["current_status"]},
            "clearing_stage": {"S": s["current_stage"]}, "version": {"N": str(s["version"])},
            "entry_count": {"N": str(s["entry_count"])}, "updated_at": {"S": rfc3339(s["updated_at"])},
        }
        if s.get("last_entry_id"):
            it["last_entry_id"] = {"S": s["last_entry_id"]}
        if s.get("last_memo") is not None:
            it["last_memo"] = {"S": s["last_memo"]}
        items[(pk, "STATE")] = it
    for e in events:
        sid = e["settlement_id"]
        pk = f"SETTLEMENT#{sid}"
        sk = "EVENT#%08d" % int(e["aggregate_version"])
        data = (e["payload"] or {}).get("data") or {}
        it = {
            "PK": {"S": pk}, "SK": {"S": sk}, "settlement_id": {"S": sid},
            "event_id": {"S": e["event_id"]}, "version": {"N": str(e["aggregate_version"])},
            "event_type": {"S": e["event_type"]}, "status": {"S": data.get("status", "")},
            "clearing_stage": {"S": data.get("clearingStage", "")},
            "occurred_at": {"S": rfc3339(e["occurred_at"])},
            "correlation_id": {"S": e["correlation_id"]},
            "envelope": {"S": canonical_json(canonical_envelope(e["payload"]))},
        }
        if data.get("entryId") is not None:
            it["entry_id"] = {"S": data["entryId"]}
        if data.get("memo") is not None:
            it["memo"] = {"S": data["memo"]}
        items[(pk, sk)] = it
    return items


def items_equal(actual, expected):
    if set(actual.keys()) != set(expected.keys()):
        return False
    for k, v in expected.items():
        a = actual.get(k)
        if k == "envelope":
            try:
                if "S" not in a or json.loads(a["S"]) != json.loads(v["S"]):
                    return False
            except Exception:
                return False
            continue
        if k in ("updated_at", "occurred_at"):
            if not a or "S" not in a or parse_ts(a["S"]) != parse_ts(v["S"]) or parse_ts(a["S"]) is None:
                return False
            continue
        if a != v:
            if "N" in v and a and "N" in a:
                try:
                    if int(a["N"]) == int(v["N"]):
                        continue
                except Exception:
                    pass
            return False
    return True


def scan_table(ddb, table):
    items = []
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        r = ddb.scan(**kw)
        items += r.get("Items", [])
        if not r.get("LastEvaluatedKey"):
            return items
        kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]


def reconcile_dynamodb(ctx):
    ddb = ctx.aws("dynamodb")
    table = ctx.m["projections"]["table_name"]
    for attempt in range(6):
        actual_list = scan_table(ddb, table)            # scan BEFORE reading PostgreSQL
        settlements, events = load_pg_state(ctx)
        expected = expected_items(settlements, events)
        actual = {}
        for it in actual_list:
            pk = it.get("PK", {}).get("S")
            sk = it.get("SK", {}).get("S")
            actual[(pk, sk)] = it
        changes = 0
        for key, it in actual.items():
            if key not in expected:
                ddb.delete_item(TableName=table, Key={"PK": it["PK"], "SK": it["SK"]})
                changes += 1
        for key, exp in expected.items():
            cur = actual.get(key)
            if cur is not None and items_equal(cur, exp):
                continue
            kw = {"TableName": table, "Item": exp}
            if key[1] == "STATE":
                if cur is None:
                    kw["ConditionExpression"] = "attribute_not_exists(PK)"
                elif "version" in cur and "N" in cur["version"]:
                    kw["ConditionExpression"] = "#v = :v"
                    kw["ExpressionAttributeNames"] = {"#v": "version"}
                    kw["ExpressionAttributeValues"] = {":v": cur["version"]}
            try:
                ddb.put_item(**kw)
            except ClientError as e:
                if err_code(e) != "ConditionalCheckFailedException":
                    raise
            changes += 1
        log(f"dynamodb pass {attempt + 1}: {len(expected)} expected items, "
            f"{len(actual)} present, {changes} corrected")
        if changes == 0:
            return settlements
    log("dynamodb reconciliation reached pass limit")
    return load_pg_state(ctx)[0]


def expected_projection(s):
    return {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["current_status"],
        "clearingStage": s["current_stage"], "lastEntryId": s.get("last_entry_id"),
        "lastMemo": s.get("last_memo"), "version": s["version"], "entryCount": s["entry_count"],
        "updatedAt": s["updated_at"],
    }


def projection_matches(raw, exp):
    try:
        obj = json.loads(raw)
    except Exception:
        return False
    if not isinstance(obj, dict):
        return False
    allowed = set(exp.keys())
    if not set(obj.keys()) <= allowed:
        return False
    for k, v in exp.items():
        a = obj.get(k)
        if k == "updatedAt":
            if parse_ts(a) is None or parse_ts(a) != parse_ts(rfc3339(v)):
                return False
        elif k in ("version", "entryCount"):
            if not isinstance(a, int) or isinstance(a, bool) or a != v:
                return False
        elif k in ("lastEntryId",):
            if (a or None) and v:
                if str(a).lower() != str(v).lower():
                    return False
            elif (a or None) != (v or None):
                return False
        else:
            if a != v:
                return False
    return True


def reconcile_valkey(ctx):
    c = ctx.m["cache"]
    try:
        r = Resp(c["endpoint"], c["port"])
    except Exception as e:
        log(f"valkey unreachable ({e}); skipping cache reconciliation")
        return
    keys = []
    cursor = b"0"
    while True:
        res = r.cmd("SCAN", cursor, "MATCH", "clearledger:*", "COUNT", 1000)
        cursor = res[0]
        keys += res[1]
        if cursor in (b"0", "0"):
            break
    snapshot = {}
    for k in keys:
        t = r.cmd("TYPE", k)
        val = r.cmd("GET", k) if t == "string" else None
        ttl = r.cmd("PTTL", k)
        snapshot[k] = (t, val, ttl)
    settlements = {s["settlement_id"]: s for s in load_pg_state(ctx)[0]}
    deleted = 0
    for k, (t, val, ttl) in snapshot.items():
        ks = k.decode(errors="replace")
        reason = None
        sid = ks[len(CACHE_PREFIX):] if ks.startswith(CACHE_PREFIX) else None
        if sid is None or not UUID_RE.match(sid):
            reason = "unexpected key"
        elif sid.lower() not in settlements and sid not in settlements:
            reason = "orphan"
        elif t != "string" or val is None:
            reason = "wrong type"
        elif ttl is None or ttl <= 0 or ttl > 90_000:
            reason = "invalid ttl"
        elif not projection_matches(val, expected_projection(settlements.get(sid) or settlements[sid.lower()])):
            reason = "divergent payload"
        if reason:
            r.cmd("DEL", k)
            deleted += 1
    log(f"valkey: {len(snapshot)} cache keys inspected, {deleted} removed")


# ---------------------------------------------------------------------------
# S3 audit archive
# ---------------------------------------------------------------------------

def list_versions(s3, bucket):
    versions, markers = [], []
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
        versions += page.get("Versions", []) or []
        markers += page.get("DeleteMarkers", []) or []
    return versions, markers


def delete_versions(s3, bucket, objs):
    objs = [o for o in objs if o.get("Key") is not None]
    for i in range(0, len(objs), 500):
        chunk = objs[i:i + 500]
        try:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
        except ClientError:
            for o in chunk:
                kw = {"Bucket": bucket, "Key": o["Key"]}
                if o.get("VersionId"):
                    kw["VersionId"] = o["VersionId"]
                s3.delete_object(**kw)


def validate_batch(key, body, outbox_by_event):
    m = BATCH_RE.match(key)
    if not m:
        return None
    first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
    if hashlib.sha256(body).hexdigest()[:16] != digest:
        return None
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not text.endswith("\n"):
        return None
    lines = text[:-1].split("\n")
    seqs = []
    for line in lines:
        if not line.strip():
            return None
        try:
            obj = json.loads(line)
        except Exception:
            return None
        if not isinstance(obj, dict):
            return None
        row = outbox_by_event.get(str(obj.get("eventId", "")).lower())
        if row is None or obj != row["payload"]:
            return None
        seqs.append(int(row["seq"]))
    if not seqs or seqs[0] != first or seqs[-1] != last:
        return None
    if any(b <= a for a, b in zip(seqs, seqs[1:])):
        return None
    return seqs


def s3_pass(ctx):
    """One convergence pass. Returns number of corrective actions taken."""
    s3 = ctx.aws("s3")
    bucket = ctx.m["audit"]["bucket_name"]
    actions = 0
    versions, markers = list_versions(s3, bucket)

    # 1. purge delete markers, noncurrent versions and anything outside the canonical layout
    purge = [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in markers]
    latest_deleted = {m["Key"] for m in markers if m.get("IsLatest")}
    current = {}
    for v in versions:
        if not v.get("IsLatest") or v["Key"] in latest_deleted or not BATCH_RE.match(v["Key"]):
            purge.append({"Key": v["Key"], "VersionId": v["VersionId"]})
        else:
            current[v["Key"]] = v
    if purge:
        log(f"s3: purging {len(purge)} noncurrent versions / delete markers / stray objects")
        delete_versions(s3, bucket, purge)
        actions += len(purge)

    outbox = ctx.pg.json(
        "SELECT seq, event_id::text AS event_id, payload, published_at IS NOT NULL AS published, "
        "archived_at IS NOT NULL AS archived FROM clearledger.outbox ORDER BY seq")
    by_event = {r["event_id"].lower(): r for r in outbox}
    by_seq = {int(r["seq"]): r for r in outbox}

    # 2. validate current batches; keep the first non-overlapping valid set
    batches = []
    invalid = []
    for key, v in current.items():
        body = s3.get_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])["Body"].read()
        seqs = validate_batch(key, body, by_event)
        if seqs is None:
            invalid.append({"Key": key, "VersionId": v["VersionId"]})
        else:
            batches.append((seqs[0], key, v["VersionId"], seqs))
    batches.sort()
    covered = set()
    for first, key, vid, seqs in batches:
        if covered.intersection(seqs):
            invalid.append({"Key": key, "VersionId": vid})
        else:
            covered.update(seqs)
    if invalid:
        log(f"s3: removing {len(invalid)} invalid or duplicate batch objects")
        delete_versions(s3, bucket, invalid)
        actions += len(invalid)

    # 3. align archived_at with what is actually in S3
    published = {s for s, r in by_seq.items() if r["published"]}
    mark = sorted(s for s in covered if s in published and not by_seq[s]["archived"])
    reset = sorted(s for s in published - covered if by_seq[s]["archived"])
    if mark:
        ctx.pg.run("UPDATE clearledger.outbox SET archived_at = GREATEST(NOW(), published_at) "
                   f"WHERE archived_at IS NULL AND published_at IS NOT NULL AND seq IN ({','.join(map(str, mark))})")
        actions += len(mark)
    if reset:
        log(f"s3: {len(reset)} archived outbox rows missing from S3; scheduling re-archive")
        ctx.pg.run("UPDATE clearledger.outbox SET archived_at = NULL "
                   f"WHERE archived_at IS NOT NULL AND seq IN ({','.join(map(str, reset))})")
        actions += len(reset)

    # 4. archive everything still pending through the audit archiver
    fn = ctx.m["workers"]["audit_archiver"]["function_name"]
    for _ in range(200):
        pending = int(ctx.pg.scalar(
            "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL"))
        if pending == 0:
            break
        log(f"s3: {pending} published rows awaiting archive; invoking {fn}")
        try:
            invoke(ctx, fn)
        except Exception as e:
            log(f"archiver invocation failed: {e}")
            time.sleep(3)
        actions += 1
    return actions


def reconcile_s3(ctx):
    for i in range(8):
        n = s3_pass(ctx)
        log(f"s3 pass {i + 1}: {n} corrective actions")
        if n == 0:
            return
    raise RuntimeError("S3 audit archive did not converge")


def cmd_reconcile(ctx):
    drain_outbox(ctx)
    wait_queue_idle(ctx)
    reconcile_dynamodb(ctx)
    reconcile_valkey(ctx)
    reconcile_s3(ctx)
    # late projector deliveries cannot regress state, but re-verify once more
    drain_outbox(ctx)
    reconcile_dynamodb(ctx)
    reconcile_valkey(ctx)
    log("data-plane reconciliation complete")


# ---------------------------------------------------------------------------
# sweep: prefix-scoped teardown
# ---------------------------------------------------------------------------

def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ClientError as e:
        log(f"  ignored {err_code(e) or e}")
    except Exception as e:  # noqa
        log(f"  ignored {e}")


def owned(name, prefix):
    return bool(name) and name.startswith(prefix) and not name.startswith("cl-base")


def tag_owned(tags, prefix):
    for t in tags or []:
        k = t.get("Key", t.get("key", t.get("TagKey")))
        v = t.get("Value", t.get("value", t.get("TagValue")))
        if k == "ClearLedgerDeployment" and v == prefix:
            return True
    return False


def sweep(aws, prefix, region):
    p = prefix
    if not p or p.startswith("cl-base"):
        raise SystemExit("refusing to sweep baseline prefix")

    # --- schedules
    sch = aws("scheduler")
    for grp in ["default"] + [g["Name"] for g in (safe(sch.list_schedule_groups) or {}).get("ScheduleGroups", [])
                              if owned(g["Name"], p)]:
        for s in (safe(sch.list_schedules, GroupName=grp) or {}).get("Schedules", []):
            if owned(s["Name"], p):
                log(f"deleting schedule {grp}/{s['Name']}")
                safe(sch.delete_schedule, Name=s["Name"], GroupName=grp)
        if grp != "default":
            safe(sch.delete_schedule_group, Name=grp)

    # --- lambda
    lam = aws("lambda")
    for m in (safe(lam.list_event_source_mappings) or {}).get("EventSourceMappings", []):
        fn = m.get("FunctionArn", "").split(":")[-1]
        src = m.get("EventSourceArn", "").split(":")[-1]
        if owned(fn, p) or owned(src, p):
            log(f"deleting event source mapping {m['UUID']}")
            safe(lam.delete_event_source_mapping, UUID=m["UUID"])
    for f in (safe(lam.list_functions) or {}).get("Functions", []):
        if owned(f["FunctionName"], p):
            log(f"deleting function {f['FunctionName']}")
            safe(lam.delete_function, FunctionName=f["FunctionName"])

    # --- ECS
    ecs = aws("ecs")
    for carn in (safe(ecs.list_clusters) or {}).get("clusterArns", []):
        cname = carn.split("/")[-1]
        if not owned(cname, p):
            continue
        for sarn in (safe(ecs.list_services, cluster=carn) or {}).get("serviceArns", []):
            safe(ecs.update_service, cluster=carn, service=sarn, desiredCount=0)
            safe(ecs.delete_service, cluster=carn, service=sarn, force=True)
        for tarn in (safe(ecs.list_tasks, cluster=carn) or {}).get("taskArns", []):
            safe(ecs.stop_task, cluster=carn, task=tarn)
        log(f"deleting ECS cluster {cname}")
        safe(ecs.delete_cluster, cluster=carn)
    for fam in (safe(ecs.list_task_definition_families, familyPrefix=p) or {}).get("families", []):
        if not owned(fam, p):
            continue
        for st in ("ACTIVE", "INACTIVE"):
            for td in (safe(ecs.list_task_definitions, familyPrefix=fam, status=st) or {}).get("taskDefinitionArns", []):
                safe(ecs.deregister_task_definition, taskDefinition=td)
                if hasattr(ecs, "delete_task_definitions"):
                    safe(ecs.delete_task_definitions, taskDefinitions=[td])

    # --- ELBv2
    elb = aws("elbv2")
    for lb in (safe(elb.describe_load_balancers) or {}).get("LoadBalancers", []):
        if owned(lb["LoadBalancerName"], p):
            for ls in (safe(elb.describe_listeners, LoadBalancerArn=lb["LoadBalancerArn"]) or {}).get("Listeners", []):
                safe(elb.delete_listener, ListenerArn=ls["ListenerArn"])
            log(f"deleting load balancer {lb['LoadBalancerName']}")
            safe(elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in (safe(elb.describe_target_groups) or {}).get("TargetGroups", []):
        if owned(tg["TargetGroupName"], p):
            log(f"deleting target group {tg['TargetGroupName']}")
            safe(elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])

    # --- SQS
    sqs = aws("sqs")
    for url in (safe(sqs.list_queues, QueueNamePrefix=p) or {}).get("QueueUrls", []) or []:
        if owned(url.rsplit("/", 1)[-1], p):
            log(f"deleting queue {url.rsplit('/', 1)[-1]}")
            safe(sqs.delete_queue, QueueUrl=url)

    # --- DynamoDB
    ddb = aws("dynamodb")
    for t in (safe(ddb.list_tables) or {}).get("TableNames", []):
        if owned(t, p):
            log(f"deleting table {t}")
            safe(ddb.update_table, TableName=t, DeletionProtectionEnabled=False)
            safe(ddb.delete_table, TableName=t)

    # --- S3 (versioned, non-empty)
    s3 = aws("s3")
    for b in (safe(s3.list_buckets) or {}).get("Buckets", []):
        if not owned(b["Name"], p):
            continue
        log(f"emptying and deleting bucket {b['Name']}")
        try:
            vs, ms = list_versions(s3, b["Name"])
            delete_versions(s3, b["Name"], [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in vs + ms])
            for page in s3.get_paginator("list_objects_v2").paginate(Bucket=b["Name"]):
                objs = [{"Key": o["Key"]} for o in page.get("Contents", []) or []]
                if objs:
                    delete_versions(s3, b["Name"], objs)
        except ClientError as e:
            log(f"  ignored {err_code(e)}")
        safe(s3.delete_bucket, Bucket=b["Name"])

    # --- ElastiCache
    ec = aws("elasticache")
    for rg in (safe(ec.describe_replication_groups) or {}).get("ReplicationGroups", []):
        if owned(rg["ReplicationGroupId"], p):
            log(f"deleting replication group {rg['ReplicationGroupId']}")
            safe(ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
    for cc in (safe(ec.describe_cache_clusters) or {}).get("CacheClusters", []):
        if owned(cc["CacheClusterId"], p) and not cc.get("ReplicationGroupId"):
            safe(ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])

    # --- RDS
    rds = aws("rds")
    for db in (safe(rds.describe_db_instances) or {}).get("DBInstances", []):
        if owned(db["DBInstanceIdentifier"], p):
            log(f"deleting DB instance {db['DBInstanceIdentifier']}")
            safe(rds.modify_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 DeletionProtection=False, ApplyImmediately=True)
            safe(rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)

    # --- Cognito
    cog = aws("cognito-idp")
    for up in (safe(cog.list_user_pools, MaxResults=60) or {}).get("UserPools", []):
        if owned(up["Name"], p):
            log(f"deleting user pool {up['Name']}")
            for d in [safe(cog.describe_user_pool, UserPoolId=up["Id"])]:
                dom = ((d or {}).get("UserPool") or {}).get("Domain")
                if dom:
                    safe(cog.delete_user_pool_domain, Domain=dom, UserPoolId=up["Id"])
            safe(cog.delete_user_pool, UserPoolId=up["Id"])

    # --- CloudWatch Logs
    # (our /clearledger/<prefix>/* groups plus service-created groups such as
    #  /aws/lambda/<prefix>-*, /ecs/<prefix>-*, /aws/rds/instance/<prefix>-*/...)
    logs = aws("logs")
    kw = {}
    doomed = []
    while True:
        r = safe(logs.describe_log_groups, **kw) or {}
        for g in r.get("logGroups", []):
            n = g["logGroupName"]
            if "cl-base" in n:
                continue
            if any(seg == p or seg.startswith(p + "-") or seg.startswith(p + "_") for seg in n.split("/")):
                doomed.append(n)
        if not r.get("nextToken"):
            break
        kw["nextToken"] = r["nextToken"]
    for n in doomed:
        log(f"deleting log group {n}")
        safe(logs.delete_log_group, logGroupName=n)

    # --- IAM roles / policies
    iam = aws("iam")
    roles = []
    for page in iam.get_paginator("list_roles").paginate():
        roles += page.get("Roles", [])
    for r in roles:
        name = r["RoleName"]
        tagged = False
        if not owned(name, p):
            t = safe(iam.list_role_tags, RoleName=name) or {}
            tagged = tag_owned(t.get("Tags"), p) and not name.startswith("cl-base")
            if not tagged:
                continue
        log(f"deleting IAM role {name}")
        for n in (safe(iam.list_role_policies, RoleName=name) or {}).get("PolicyNames", []):
            safe(iam.delete_role_policy, RoleName=name, PolicyName=n)
        for a in (safe(iam.list_attached_role_policies, RoleName=name) or {}).get("AttachedPolicies", []):
            safe(iam.detach_role_policy, RoleName=name, PolicyArn=a["PolicyArn"])
        for ip in (safe(iam.list_instance_profiles_for_role, RoleName=name) or {}).get("InstanceProfiles", []):
            safe(iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
        safe(iam.delete_role, RoleName=name)
    pols = []
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        pols += page.get("Policies", [])
    for pol in pols:
        name = pol["PolicyName"]
        if not owned(name, p):
            t = safe(iam.list_policy_tags, PolicyArn=pol["Arn"]) or {}
            if not (tag_owned(t.get("Tags"), p) and not name.startswith("cl-base")):
                continue
        log(f"deleting IAM policy {name}")
        ents = safe(iam.list_entities_for_policy, PolicyArn=pol["Arn"]) or {}
        for x in ents.get("PolicyRoles", []):
            safe(iam.detach_role_policy, RoleName=x["RoleName"], PolicyArn=pol["Arn"])
        for x in ents.get("PolicyUsers", []):
            safe(iam.detach_user_policy, UserName=x["UserName"], PolicyArn=pol["Arn"])
        for x in ents.get("PolicyGroups", []):
            safe(iam.detach_group_policy, GroupName=x["GroupName"], PolicyArn=pol["Arn"])
        for v in (safe(iam.list_policy_versions, PolicyArn=pol["Arn"]) or {}).get("Versions", []):
            if not v.get("IsDefaultVersion"):
                safe(iam.delete_policy_version, PolicyArn=pol["Arn"], VersionId=v["VersionId"])
        safe(iam.delete_policy, PolicyArn=pol["Arn"])

    # --- KMS aliases + keys (schedule deletion)
    kms = aws("kms")
    aliases = []
    for page in kms.get_paginator("list_aliases").paginate():
        aliases += page.get("Aliases", [])
    key_ids = set()
    for a in aliases:
        if a["AliasName"].startswith(f"alias/{p}") and not a["AliasName"].startswith("alias/cl-base"):
            if a.get("TargetKeyId"):
                key_ids.add(a["TargetKeyId"])
            log(f"deleting KMS alias {a['AliasName']}")
            safe(kms.delete_alias, AliasName=a["AliasName"])
    keys = []
    for page in kms.get_paginator("list_keys").paginate():
        keys += page.get("Keys", [])
    for k in keys:
        kid = k["KeyId"]
        md = (safe(kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
        if md.get("KeyManager") == "AWS":
            continue
        mine = kid in key_ids
        if not mine:
            t = safe(kms.list_resource_tags, KeyId=kid) or {}
            mine = tag_owned(t.get("Tags"), p)
        if mine and md.get("KeyState") not in ("PendingDeletion", None):
            log(f"scheduling deletion of KMS key {kid}")
            safe(kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)

    # --- EC2 networking
    ec2 = aws("ec2")
    vpcs = (safe(ec2.describe_vpcs, Filters=[{"Name": "tag:ClearLedgerDeployment", "Values": [p]}]) or {}).get("Vpcs", [])
    for v in vpcs:
        vid = v["VpcId"]
        log(f"deleting VPC {vid} and dependencies")
        flt = [{"Name": "vpc-id", "Values": [vid]}]
        for e in (safe(ec2.describe_network_interfaces, Filters=flt) or {}).get("NetworkInterfaces", []):
            if e.get("Attachment", {}).get("AttachmentId"):
                safe(ec2.detach_network_interface, AttachmentId=e["Attachment"]["AttachmentId"], Force=True)
            safe(ec2.delete_network_interface, NetworkInterfaceId=e["NetworkInterfaceId"])
        for g in (safe(ec2.describe_internet_gateways, Filters=[{"Name": "attachment.vpc-id", "Values": [vid]}]) or {}).get("InternetGateways", []):
            safe(ec2.detach_internet_gateway, InternetGatewayId=g["InternetGatewayId"], VpcId=vid)
            safe(ec2.delete_internet_gateway, InternetGatewayId=g["InternetGatewayId"])
        for rt in (safe(ec2.describe_route_tables, Filters=flt) or {}).get("RouteTables", []):
            if any(a.get("Main") for a in rt.get("Associations", [])):
                continue
            for a in rt.get("Associations", []):
                safe(ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            safe(ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        sgs = [g for g in (safe(ec2.describe_security_groups, Filters=flt) or {}).get("SecurityGroups", [])
               if g["GroupName"] != "default"]
        for g in sgs:
            if g.get("IpPermissions"):
                safe(ec2.revoke_security_group_ingress, GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
            if g.get("IpPermissionsEgress"):
                safe(ec2.revoke_security_group_egress, GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
        for g in sgs:
            safe(ec2.delete_security_group, GroupId=g["GroupId"])
        for s in (safe(ec2.describe_subnets, Filters=flt) or {}).get("Subnets", []):
            safe(ec2.delete_subnet, SubnetId=s["SubnetId"])
        safe(ec2.delete_vpc, VpcId=vid)
    for g in (safe(ec2.describe_internet_gateways, Filters=[{"Name": "tag:ClearLedgerDeployment", "Values": [p]}]) or {}).get("InternetGateways", []):
        safe(ec2.delete_internet_gateway, InternetGatewayId=g["InternetGatewayId"])
    for sn in (safe(rds.describe_db_subnet_groups) or {}).get("DBSubnetGroups", []):
        if owned(sn["DBSubnetGroupName"], p):
            safe(rds.delete_db_subnet_group, DBSubnetGroupName=sn["DBSubnetGroupName"])
    for sn in (safe(ec.describe_cache_subnet_groups) or {}).get("CacheSubnetGroups", []):
        if owned(sn["CacheSubnetGroupName"], p):
            safe(ec.delete_cache_subnet_group, CacheSubnetGroupName=sn["CacheSubnetGroupName"])


def cmd_sweep(config_path):
    with open(config_path) as fh:
        cfg = json.load(fh)
    aws = Aws(cfg.get("aws_endpoint_url") or os.environ.get("AWS_ENDPOINT_URL"), cfg.get("region", "us-east-1"))
    sweep(aws, cfg["resource_prefix"], cfg.get("region", "us-east-1"))
    log("sweep complete")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["guard", "reconcile", "sweep"])
    ap.add_argument("--config", default="/workspace/config/config.json")
    ap.add_argument("--manifest", default="/workspace/submission/manifest.json")
    a = ap.parse_args()
    if a.command == "sweep":
        cmd_sweep(a.config)
        return
    ctx = Ctx(a.manifest, a.config)
    if a.command == "guard":
        cmd_guard(ctx)
    else:
        cmd_reconcile(ctx)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
