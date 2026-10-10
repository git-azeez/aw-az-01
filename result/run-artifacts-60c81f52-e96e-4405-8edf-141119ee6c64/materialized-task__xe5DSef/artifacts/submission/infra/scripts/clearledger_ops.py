#!/usr/bin/env python3
"""ClearLedger operational helpers used by deploy.sh / destroy.sh.

Sub-commands:
  iam-drift       remove out-of-band inline / attached policies from the six workload roles
                  and delete detached <prefix>* customer-managed policies
  sg-drift        revoke out-of-band egress rules on the alb / rds / valkey security groups
  esm-check       print "replace" when the projector event source mapping must be re-bound
  reconcile       converge derived data stores (SQS drain, DynamoDB, Valkey, S3) with PostgreSQL
  destroy-sweep   remove any remaining <prefix>-scoped resources (pre/post terraform destroy)

The script only depends on boto3 (shipped with the AWS CLI) and the psql binary.
"""

import base64
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_PATH = os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json")
MANIFEST_PATH = os.environ.get("CLEARLEDGER_MANIFEST", "/workspace/submission/manifest.json")

with open(CONFIG_PATH) as fh:
    CFG = json.load(fh)

PREFIX = CFG["resource_prefix"]
REGION = CFG.get("region", "us-east-1")
ENDPOINT = CFG.get("aws_endpoint_url", "http://aws:4566")
BASELINE_PREFIX = "cl-base"

ROLE_POLICIES = {
    f"{PREFIX}-ecs-execution": f"{PREFIX}-ecs-execution-policy",
    f"{PREFIX}-ecs-task": f"{PREFIX}-ecs-task-policy",
    f"{PREFIX}-projector": f"{PREFIX}-projector-policy",
    f"{PREFIX}-outbox-relay": f"{PREFIX}-outbox-relay-policy",
    f"{PREFIX}-audit-archiver": f"{PREFIX}-audit-archiver-policy",
    f"{PREFIX}-scheduler": f"{PREFIX}-scheduler-policy",
}

AUDIT_KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def log(msg):
    print(f"[clearledger-ops] {msg}", flush=True)


_clients = {}


def aws(service):
    if service not in _clients:
        _clients[service] = boto3.client(
            service,
            region_name=REGION,
            endpoint_url=ENDPOINT,
            aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
            aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
            config=Config(retries={"max_attempts": 5, "mode": "standard"},
                          read_timeout=120, connect_timeout=10,
                          s3={"addressing_style": "path"}),
        )
    return _clients[service]


def ours(name):
    return bool(name) and name.startswith(PREFIX) and not name.startswith(BASELINE_PREFIX)


def err_code(e):
    return e.response.get("Error", {}).get("Code", "") if isinstance(e, ClientError) else ""


def safe(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except ClientError as e:
        log(f"  ignored {fn.__name__ if hasattr(fn, '__name__') else fn}: {err_code(e)}")
    except Exception as e:  # noqa: BLE001
        log(f"  ignored error: {e}")
    return None


def load_manifest():
    with open(MANIFEST_PATH) as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# PostgreSQL via psql
# ---------------------------------------------------------------------------
class Pg:
    def __init__(self, host, port, db, user, password):
        self.base = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
                     "-h", str(host), "-p", str(port), "-U", user, "-d", db]
        self.env = dict(os.environ, PGPASSWORD=password, PGCONNECT_TIMEOUT="10")

    def run(self, sql):
        last = None
        for attempt in range(5):
            r = subprocess.run(self.base + ["-c", sql], env=self.env, capture_output=True, text=True)
            if r.returncode == 0:
                return r.stdout
            last = r.stderr.strip()
            time.sleep(2 + attempt * 2)
        raise RuntimeError(f"psql failed: {last}")

    def json(self, sql):
        out = self.run(f"SELECT coalesce(json_agg(t), '[]'::json) FROM ({sql}) t").strip()
        return json.loads(out or "[]")


def pg_from_manifest(m):
    d = m["database"]
    return Pg(d["endpoint"], d["port"], CFG["db_name"], CFG["db_username"], CFG["db_password"])


# ---------------------------------------------------------------------------
# Minimal RESP client for Valkey
# ---------------------------------------------------------------------------
class Resp:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, int(port)), timeout=15)
        self.buf = b""

    def _readline(self):
        while b"\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("valkey connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _readn(self, n):
        while len(self.buf) < n + 2:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("valkey connection closed")
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data

    def _read(self):
        line = self._readline()
        t, rest = line[:1], line[1:]
        if t == b"+":
            return rest.decode()
        if t == b"-":
            raise RuntimeError(rest.decode())
        if t == b":":
            return int(rest)
        if t == b"$":
            n = int(rest)
            return None if n < 0 else self._readn(n)
        if t == b"*":
            n = int(rest)
            return None if n < 0 else [self._read() for _ in range(n)]
        raise RuntimeError(f"unexpected RESP type {line!r}")

    def cmd(self, *args):
        parts = [a if isinstance(a, bytes) else str(a).encode() for a in args]
        payload = b"*%d\r\n" % len(parts) + b"".join(b"$%d\r\n%s\r\n" % (len(p), p) for p in parts)
        self.sock.sendall(payload)
        return self._read()

    def scan_all(self):
        keys, cursor = [], b"0"
        while True:
            cursor, batch = self.cmd("SCAN", cursor, "COUNT", 1000)
            keys.extend(batch)
            if cursor in (b"0", 0, "0"):
                return keys


# ---------------------------------------------------------------------------
# Canonical serialisation (matches the Rust workers' serde struct order)
# ---------------------------------------------------------------------------
ENVELOPE_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
                  "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty",
              "entryId", "status", "clearingStage", "memo"]


def canonical_envelope(p):
    out = {}
    for k in ENVELOPE_ORDER:
        if k == "data":
            d = p.get("data") or {}
            dd = {}
            for dk in DATA_ORDER:
                if dk in d and not (dk in ("entryId", "memo") and d[dk] is None):
                    dd[dk] = d[dk]
            for dk in d:
                if dk not in dd and d[dk] is not None and dk not in DATA_ORDER:
                    dd[dk] = d[dk]
            out["data"] = dd
        elif k in p:
            out[k] = p[k]
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


def rfc3339(date_part, frac6, suffix="+00:00"):
    """chrono SecondsFormat::AutoSi rendering of a UTC timestamp."""
    frac6 = (frac6 or "").ljust(6, "0")[:6]
    if frac6 == "000000":
        f = ""
    elif frac6.endswith("000"):
        f = "." + frac6[:3]
    else:
        f = "." + frac6
    return f"{date_part}{f}{suffix}"


TS_SQL = ("to_char({c} AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS') AS {n}_d, "
          "to_char({c} AT TIME ZONE 'UTC', 'US') AS {n}_f")


def ts_cols(col, name):
    return TS_SQL.format(c=col, n=name)


# ---------------------------------------------------------------------------
# IAM drift
# ---------------------------------------------------------------------------
def delete_policy_fully(iam, arn):
    try:
        for page in iam.get_paginator("list_entities_for_policy").paginate(PolicyArn=arn):
            for r in page.get("PolicyRoles", []):
                safe(iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
            for u in page.get("PolicyUsers", []):
                safe(iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
            for g in page.get("PolicyGroups", []):
                safe(iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
    except ClientError as e:
        log(f"  list_entities_for_policy {arn}: {err_code(e)}")
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v.get("IsDefaultVersion"):
                safe(iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    except ClientError as e:
        log(f"  list_policy_versions {arn}: {err_code(e)}")
    safe(iam.delete_policy, PolicyArn=arn)


def list_local_policies(iam):
    out = []
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        out.extend(page.get("Policies", []))
    return out


def cmd_iam_drift():
    iam = aws("iam")
    for role, canonical in ROLE_POLICIES.items():
        try:
            names = []
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                names.extend(page.get("PolicyNames", []))
        except ClientError as e:
            if err_code(e) in ("NoSuchEntity", "NoSuchEntityException"):
                continue
            raise
        for n in names:
            if n != canonical:
                log(f"removing out-of-band inline policy {n} from {role}")
                safe(iam.delete_role_policy, RoleName=role, PolicyName=n)
        attached = []
        for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
            attached.extend(page.get("AttachedPolicies", []))
        for a in attached:
            log(f"detaching out-of-band policy {a['PolicyArn']} from {role}")
            safe(iam.detach_role_policy, RoleName=role, PolicyArn=a["PolicyArn"])
    # Terraform does not manage any customer-managed policies, so every
    # <prefix>* customer-managed policy is out-of-band.
    for p in list_local_policies(iam):
        if ours(p["PolicyName"]):
            log(f"deleting out-of-band customer-managed policy {p['PolicyName']}")
            delete_policy_fully(iam, p["Arn"])


# ---------------------------------------------------------------------------
# Security group drift
# ---------------------------------------------------------------------------
def cmd_sg_drift():
    m = load_manifest()
    ec2 = aws("ec2")
    sgs = m["network"]["security_group_ids"]
    try:
        vpc_cidr = ec2.describe_vpcs(VpcIds=[m["network"]["vpc_id"]])["Vpcs"][0]["CidrBlock"]
    except Exception:  # noqa: BLE001
        vpc_cidr = None
    for role in ("alb", "rds", "valkey"):
        try:
            sg = ec2.describe_security_groups(GroupIds=[sgs[role]])["SecurityGroups"][0]
        except ClientError as e:
            log(f"describe sg {role}: {err_code(e)}")
            continue
        bad = []
        for perm in sg.get("IpPermissionsEgress", []):
            if role in ("rds", "valkey"):
                bad.append(perm)
                continue
            proto = str(perm.get("IpProtocol"))
            ok_port = proto == "tcp" and perm.get("FromPort") == 8080 and perm.get("ToPort") == 8080
            ranges = [r.get("CidrIp") for r in perm.get("IpRanges", [])]
            v6 = perm.get("Ipv6Ranges", [])
            if not ok_port or v6 or any(r in ("0.0.0.0/0",) for r in ranges) or \
                    any(r != vpc_cidr for r in ranges) or perm.get("UserIdGroupPairs") or perm.get("PrefixListIds"):
                bad.append(perm)
        if bad:
            log(f"revoking {len(bad)} out-of-band egress rule(s) on {role} security group")
            for perm in bad:
                clean = {k: v for k, v in perm.items() if k in
                         ("IpProtocol", "FromPort", "ToPort", "IpRanges", "Ipv6Ranges",
                          "UserIdGroupPairs", "PrefixListIds") and v not in (None, [])}
                safe(ec2.revoke_security_group_egress, GroupId=sgs[role], IpPermissions=[clean])


# ---------------------------------------------------------------------------
# Event source mapping health
# ---------------------------------------------------------------------------
def cmd_esm_check(state_path):
    """Prints 'replace' when the projector ESM must be re-created/re-bound."""
    try:
        with open(state_path) as fh:
            st = json.load(fh)
    except Exception:  # noqa: BLE001
        return
    esm_uuid, queue_name = None, None
    for r in st.get("resources", []):
        if r.get("type") == "aws_lambda_event_source_mapping" and r.get("instances"):
            esm_uuid = r["instances"][0]["attributes"].get("uuid")
        if r.get("type") == "aws_sqs_queue" and r.get("name") == "main" and r.get("instances"):
            queue_name = r["instances"][0]["attributes"].get("name")
    if not esm_uuid or not queue_name:
        return
    try:
        aws("sqs").get_queue_url(QueueName=queue_name)
    except ClientError:
        print("replace")
        return
    try:
        esm = aws("lambda").get_event_source_mapping(UUID=esm_uuid)
        if esm.get("State") in ("Deleting",):
            print("replace")
    except ClientError:
        pass


# ---------------------------------------------------------------------------
# Data-plane reconciliation
# ---------------------------------------------------------------------------
def invoke(fn_name, payload=None):
    lam = aws("lambda")
    r = lam.invoke(FunctionName=fn_name, InvocationType="RequestResponse",
                   Payload=json.dumps(payload or {}).encode())
    body = r["Payload"].read().decode(errors="replace")
    if r.get("FunctionError"):
        log(f"  {fn_name} returned error: {body[:300]}")
    return body


def drain_outbox(pg, m):
    fn = m["workers"]["outbox_relay"]["function_name"]
    for i in range(60):
        n = int(pg.run("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL").strip())
        if n == 0:
            log("outbox drained (0 unpublished rows)")
            return
        log(f"outbox has {n} unpublished row(s); invoking {fn}")
        safe(invoke, fn)
        time.sleep(0.5 if i < 10 else 2)
    log("WARNING: outbox still has unpublished rows after relay attempts")


def queue_depth(url):
    a = aws("sqs").get_queue_attributes(
        QueueUrl=url, AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
                                      "ApproximateNumberOfMessagesDelayed"])["Attributes"]
    return sum(int(a.get(k, 0)) for k in a)


def wait_queue_idle(m, timeout=150):
    url = m["messaging"]["queue_url"]
    deadline = time.time() + timeout
    zero_streak = 0
    while time.time() < deadline:
        try:
            d = queue_depth(url)
        except ClientError as e:
            log(f"queue depth error {err_code(e)}")
            return
        if d == 0:
            zero_streak += 1
            if zero_streak >= 2:
                log("main queue idle")
                return
        else:
            zero_streak = 0
        time.sleep(2)
    log("WARNING: main queue not idle before timeout; continuing")


def ddb_attr(v):
    if isinstance(v, bool):
        return {"BOOL": v}
    if isinstance(v, int):
        return {"N": str(v)}
    return {"S": str(v)}


def expected_projection(pg):
    settlements = pg.json(
        "SELECT settlement_id::text AS sid, account_id, reference, debit_party, credit_party, current_status, "
        "current_stage, last_entry_id::text AS last_entry_id, last_memo, version, entry_count, "
        + ts_cols("updated_at", "upd") + " FROM clearledger.settlements ORDER BY settlement_id")
    events = pg.json(
        "SELECT settlement_id::text AS sid, event_id::text AS event_id, aggregate_version, event_type, "
        "correlation_id, payload, " + ts_cols("occurred_at", "occ")
        + " FROM clearledger.events ORDER BY settlement_id, aggregate_version")
    expected = {}
    for s in settlements:
        pk = f"SETTLEMENT#{s['sid']}"
        item = {
            "PK": pk, "SK": "STATE",
            "GSI1PK": f"ACCOUNT#{s['account_id']}", "GSI1SK": pk,
            "settlement_id": s["sid"], "account_id": s["account_id"], "reference": s["reference"],
            "debit_party": s["debit_party"], "credit_party": s["credit_party"],
            "status": s["current_status"], "clearing_stage": s["current_stage"],
            "version": int(s["version"]), "entry_count": int(s["entry_count"]),
            "updated_at": rfc3339(s["upd_d"], s["upd_f"]),
        }
        if s.get("last_entry_id") is not None:
            item["last_entry_id"] = s["last_entry_id"]
        if s.get("last_memo") is not None:
            item["last_memo"] = s["last_memo"]
        expected[(pk, "STATE")] = item
    for e in events:
        pk = f"SETTLEMENT#{e['sid']}"
        sk = "EVENT#%08d" % int(e["aggregate_version"])
        p = e["payload"]
        d = p.get("data") or {}
        item = {
            "PK": pk, "SK": sk, "settlement_id": e["sid"], "event_id": e["event_id"],
            "version": int(e["aggregate_version"]), "event_type": e["event_type"],
            "status": d.get("status"), "clearing_stage": d.get("clearingStage"),
            "occurred_at": rfc3339(e["occ_d"], e["occ_f"]),
            "correlation_id": e["correlation_id"], "envelope": canonical_envelope(p),
        }
        if d.get("entryId") is not None:
            item["entry_id"] = d["entryId"]
        if d.get("memo") is not None:
            item["memo"] = d["memo"]
        expected[(pk, sk)] = item
    return settlements, expected


def item_matches(actual, exp):
    if set(actual.keys()) != set(exp.keys()):
        return False
    for k, v in exp.items():
        a = actual[k]
        if k == "envelope":
            if "S" not in a:
                return False
            try:
                if json.loads(a["S"]) != json.loads(v):
                    return False
            except ValueError:
                return False
            continue
        if a != ddb_attr(v):
            return False
    return True


def reconcile_dynamodb(pg, m):
    table = m["projections"]["table_name"]
    ddb = aws("dynamodb")
    settlements, expected = expected_projection(pg)
    actual = {}
    for page in ddb.get_paginator("scan").paginate(TableName=table, ConsistentRead=True):
        for it in page.get("Items", []):
            pk = it.get("PK", {}).get("S")
            sk = it.get("SK", {}).get("S")
            actual[(pk, sk)] = it
    puts, deletes = [], []
    for key, exp in expected.items():
        a = actual.get(key)
        if a is None or not item_matches(a, exp):
            puts.append({k: ddb_attr(v) for k, v in exp.items()})
    for key, it in actual.items():
        if key not in expected:
            deletes.append({"PK": it["PK"], "SK": it["SK"]})
    log(f"dynamodb: {len(expected)} expected items, {len(actual)} present, "
        f"{len(puts)} to upsert, {len(deletes)} to delete")
    reqs = [{"PutRequest": {"Item": p}} for p in puts] + [{"DeleteRequest": {"Key": d}} for d in deletes]
    for i in range(0, len(reqs), 25):
        chunk = {table: reqs[i:i + 25]}
        for _ in range(10):
            r = ddb.batch_write_item(RequestItems=chunk)
            chunk = r.get("UnprocessedItems") or {}
            if not chunk:
                break
            time.sleep(0.5)
    return settlements, expected


def verify_dynamodb(m, expected):
    ddb = aws("dynamodb")
    table = m["projections"]["table_name"]
    actual = {}
    for page in ddb.get_paginator("scan").paginate(TableName=table, ConsistentRead=True):
        for it in page.get("Items", []):
            actual[(it["PK"]["S"], it["SK"]["S"])] = it
    if set(actual) != set(expected):
        return False
    return all(item_matches(actual[k], expected[k]) for k in expected)


def http_json(url, data=None, headers=None, method=None, timeout=20):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, dict(r.headers), r.read()


def read_token(m):
    c = m["auth"]["clients"]["read"]
    basic = base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode()
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "scope": c["scope"],
                                   "client_id": c["client_id"]}).encode()
    for attempt in range(5):
        try:
            _, _, raw = http_json(m["auth"]["token_endpoint"], data=body, method="POST",
                                  headers={"Authorization": f"Basic {basic}",
                                           "Content-Type": "application/x-www-form-urlencoded"})
            return json.loads(raw)["access_token"]
        except Exception as e:  # noqa: BLE001
            log(f"token request failed ({e}); retrying")
            time.sleep(2 + attempt)
    raise RuntimeError("unable to obtain read token")


def reconcile_valkey(m, settlements):
    c = m["cache"]
    r = Resp(c["endpoint"], c["port"])
    wanted = {f"clearledger:settlement:{s['sid']}" for s in settlements}
    # Purge stray keys in non-default logical databases.
    try:
        info = r.cmd("INFO", "keyspace")
        info = info.decode() if isinstance(info, bytes) else str(info)
        for db in re.findall(r"^db(\d+):", info, re.M):
            if db != "0":
                r.cmd("SELECT", db)
                r.cmd("FLUSHDB")
        r.cmd("SELECT", 0)
    except Exception as e:  # noqa: BLE001
        log(f"valkey keyspace inspection failed: {e}")
    keys = r.scan_all()
    stale = [k for k in keys]
    for i in range(0, len(stale), 500):
        r.cmd("DEL", *stale[i:i + 500])
    log(f"valkey: removed {len(stale)} key(s) "
        f"({len([k for k in keys if k.decode(errors='replace') not in wanted])} stray/orphan); "
        f"populating {len(wanted)} settlement key(s)")
    if not wanted:
        return
    token = read_token(m)
    base = m["service_url"].rstrip("/")
    pending = sorted(wanted)
    for attempt in range(6):
        missing = []
        for key in pending:
            sid = key.rsplit(":", 1)[1]
            try:
                http_json(f"{base}/v1/settlements/{sid}",
                          headers={"Authorization": f"Bearer {token}",
                                   "X-Correlation-Id": f"deploy-reconcile-{sid[:8]}"})
            except urllib.error.HTTPError as e:
                log(f"  GET settlement {sid} -> HTTP {e.code}")
                if e.code == 401:
                    token = read_token(m)
            except Exception as e:  # noqa: BLE001
                log(f"  GET settlement {sid} failed: {e}")
        for key in pending:
            ttl = r.cmd("TTL", key)
            if not isinstance(ttl, int) or ttl <= 0 or ttl > 90:
                missing.append(key)
        if not missing:
            break
        pending = missing
        log(f"  {len(missing)} cache key(s) not populated yet; retrying")
        time.sleep(2)
    # Final sweep: nothing but wanted keys.
    for k in r.scan_all():
        if k.decode(errors="replace") not in wanted:
            r.cmd("DEL", k)
    if pending and missing:
        log(f"WARNING: {len(missing)} cache key(s) could not be populated")


# ---------------------------- S3 audit archive -----------------------------
def list_versions(s3, bucket):
    versions, markers = [], []
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
        versions.extend(page.get("Versions", []))
        markers.extend(page.get("DeleteMarkers", []))
    return versions, markers


def delete_versions(s3, bucket, objs):
    objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in objs]
    for i in range(0, len(objs), 500):
        chunk = objs[i:i + 500]
        try:
            r = s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
            for e in r.get("Errors", []) or []:
                safe(s3.delete_object, Bucket=bucket, Key=e["Key"], VersionId=e["VersionId"])
        except ClientError:
            for o in chunk:
                safe(s3.delete_object, Bucket=bucket, Key=o["Key"], VersionId=o["VersionId"])


def outbox_rows(pg):
    return pg.json("SELECT seq, event_id::text AS event_id, payload, published_at IS NOT NULL AS published, "
                   "archived_at IS NOT NULL AS archived FROM clearledger.outbox ORDER BY seq")


def analyse_archive(s3, bucket, rows):
    """Returns (accepted objects [(first,last,key,versionId)], invalid current versions)."""
    by_seq = {r["seq"]: r for r in rows}
    seqs = [r["seq"] for r in rows]
    index = {s: i for i, s in enumerate(seqs)}
    versions, markers = list_versions(s3, bucket)
    latest_marker_keys = {mk["Key"] for mk in markers if mk.get("IsLatest")}
    current = [v for v in versions if v.get("IsLatest") and v["Key"] not in latest_marker_keys]
    candidates, invalid = [], []
    for v in current:
        key = v["Key"]
        mt = AUDIT_KEY_RE.match(key)
        if not mt:
            invalid.append(v)
            continue
        first, last, digest = int(mt.group(1)), int(mt.group(2)), mt.group(3)
        if first > last or first not in index or last not in index:
            invalid.append(v)
            continue
        try:
            body = s3.get_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])["Body"].read()
        except ClientError:
            invalid.append(v)
            continue
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            invalid.append(v)
            continue
        expected_rows = [by_seq[s] for s in seqs[index[first]:index[last] + 1]]
        try:
            text = body.decode("utf-8")
            lines = text.split("\n")
            if lines and lines[-1] == "":
                lines = lines[:-1]
            records = [json.loads(ln) for ln in lines]
        except (UnicodeDecodeError, ValueError):
            invalid.append(v)
            continue
        if len(records) != len(expected_rows) or not text.endswith("\n") or \
                any(rec != row["payload"] for rec, row in zip(records, expected_rows)) or \
                any(not row["published"] for row in expected_rows):
            invalid.append(v)
            continue
        candidates.append((first, last, key, v))
    # Keep strictly disjoint intervals (earliest-first, larger batch preferred on ties).
    candidates.sort(key=lambda c: (c[0], -(c[1] - c[0])))
    accepted, covered_until = [], None
    for c in candidates:
        if covered_until is not None and c[0] <= covered_until:
            invalid.append(c[3])
            continue
        accepted.append(c)
        covered_until = c[1]
    return accepted, invalid, versions, markers


def purge_noncurrent(s3, bucket):
    for _ in range(5):
        versions, markers = list_versions(s3, bucket)
        latest_marker_keys = {mk["Key"] for mk in markers if mk.get("IsLatest")}
        doomed = list(markers)
        doomed += [v for v in versions if not v.get("IsLatest") or v["Key"] in latest_marker_keys]
        if not doomed:
            return
        log(f"s3: purging {len(doomed)} noncurrent version(s)/delete marker(s)")
        delete_versions(s3, bucket, doomed)


def reconcile_s3(pg, m):
    bucket = m["audit"]["bucket_name"]
    fn = m["workers"]["audit_archiver"]["function_name"]
    s3 = aws("s3")
    for rnd in range(4):
        rows = outbox_rows(pg)
        accepted, invalid, _, _ = analyse_archive(s3, bucket, rows)
        if invalid:
            log(f"s3: removing {len(invalid)} invalid/overlapping/stray object(s)")
            delete_versions(s3, bucket, invalid)
        covered = set()
        seqs = [r["seq"] for r in rows]
        index = {s: i for i, s in enumerate(seqs)}
        for first, last, _, _ in accepted:
            covered.update(seqs[index[first]:index[last] + 1])
        uncovered = [r for r in rows if r["seq"] not in covered and r["published"]]
        # Covered rows must be flagged archived in PostgreSQL.
        fix_archived = [r["seq"] for r in rows if r["seq"] in covered and not r["archived"]]
        if fix_archived:
            pg.run("UPDATE clearledger.outbox SET archived_at = now() WHERE seq IN (%s) AND archived_at IS NULL"
                   % ",".join(str(s) for s in fix_archived))
        if not uncovered:
            purge_noncurrent(s3, bucket)
            accepted2, invalid2, _, _ = analyse_archive(s3, bucket, outbox_rows(pg))
            if not invalid2:
                log(f"s3: archive converged ({len(accepted2)} batch object(s), {len(rows)} outbox row(s))")
                return
            continue
        # Split uncovered rows into runs contiguous in outbox order.
        runs, cur = [], []
        for r in uncovered:
            if cur and index[r["seq"]] != index[cur[-1]] + 1:
                runs.append(cur)
                cur = []
            cur.append(r["seq"])
        if cur:
            runs.append(cur)
        log(f"s3: {len(uncovered)} outbox row(s) need (re-)archival in {len(runs)} contiguous run(s)")
        all_unc = [str(s) for s in (r["seq"] for r in uncovered)]
        # Park every uncovered row, then release one contiguous run at a time so
        # each archiver batch is a gap-free, non-overlapping slice.
        pg.run("UPDATE clearledger.outbox SET archived_at = now() WHERE seq IN (%s) AND archived_at IS NULL"
               % ",".join(all_unc))
        for run in runs:
            ids = ",".join(str(s) for s in run)
            pg.run("UPDATE clearledger.outbox SET archived_at = NULL WHERE seq IN (%s)" % ids)
            for _ in range(len(run) // 50 + 10):
                left = int(pg.run("SELECT count(*) FROM clearledger.outbox WHERE seq IN (%s) "
                                  "AND archived_at IS NULL" % ids).strip())
                if left == 0:
                    break
                safe(invoke, fn)
            else:
                log("WARNING: archiver did not archive the full run")
        purge_noncurrent(s3, bucket)
    log("WARNING: s3 archive did not fully converge")


def cmd_reconcile():
    m = load_manifest()
    pg = pg_from_manifest(m)
    t0 = time.time()
    drain_outbox(pg, m)
    wait_queue_idle(m)
    settlements, expected = reconcile_dynamodb(pg, m)
    # Anything the projector processes concurrently is idempotent; re-check once.
    wait_queue_idle(m, timeout=30)
    if not verify_dynamodb(m, expected):
        log("dynamodb drift detected after first pass; re-reconciling")
        settlements, expected = reconcile_dynamodb(pg, m)
    reconcile_s3(pg, m)
    # The archiver does not touch projections; re-verify projections and then warm the cache last.
    drain_outbox(pg, m)
    wait_queue_idle(m, timeout=30)
    if not verify_dynamodb(m, expected_projection(pg)[1]):
        settlements, expected = reconcile_dynamodb(pg, m)
    reconcile_valkey(m, settlements)
    log(f"data-plane reconciliation finished in {time.time() - t0:.1f}s")


# ---------------------------------------------------------------------------
# Destroy sweep
# ---------------------------------------------------------------------------
def tag_value(tags, key="ClearLedgerDeployment"):
    for t in tags or []:
        if t.get("Key") == key or t.get("TagKey") == key:
            return t.get("Value", t.get("TagValue"))
    return None


def sweep_iam(full):
    iam = aws("iam")
    roles = []
    for page in iam.get_paginator("list_roles").paginate():
        roles.extend(page.get("Roles", []))
    for role in roles:
        name = role["RoleName"]
        if not ours(name):
            continue
        managed_by_tf = name in ROLE_POLICIES
        for page in iam.get_paginator("list_role_policies").paginate(RoleName=name):
            for pn in page.get("PolicyNames", []):
                if not managed_by_tf or pn != ROLE_POLICIES.get(name) or full:
                    safe(iam.delete_role_policy, RoleName=name, PolicyName=pn)
        for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=name):
            for a in page.get("AttachedPolicies", []):
                safe(iam.detach_role_policy, RoleName=name, PolicyArn=a["PolicyArn"])
        if full or not managed_by_tf:
            try:
                for ip in iam.list_instance_profiles_for_role(RoleName=name).get("InstanceProfiles", []):
                    safe(iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"],
                         RoleName=name)
                    if ours(ip["InstanceProfileName"]):
                        safe(iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
            except ClientError:
                pass
            log(f"deleting IAM role {name}")
            safe(iam.delete_role, RoleName=name)
    for p in list_local_policies(iam):
        if ours(p["PolicyName"]):
            log(f"deleting IAM policy {p['PolicyName']}")
            delete_policy_fully(iam, p["Arn"])
    try:
        for page in iam.get_paginator("list_instance_profiles").paginate():
            for ip in page.get("InstanceProfiles", []):
                if ours(ip["InstanceProfileName"]):
                    for r in ip.get("Roles", []):
                        safe(iam.remove_role_from_instance_profile,
                             InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
                    safe(iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])
    except ClientError:
        pass


def empty_bucket(s3, bucket):
    for _ in range(5):
        versions, markers = list_versions(s3, bucket)
        objs = versions + markers
        if not objs:
            break
        delete_versions(s3, bucket, objs)
    try:
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
            for o in page.get("Contents", []):
                safe(s3.delete_object, Bucket=bucket, Key=o["Key"])
    except ClientError:
        pass


def sweep_s3(delete_buckets):
    s3 = aws("s3")
    for b in s3.list_buckets().get("Buckets", []):
        name = b["Name"]
        if not ours(name):
            continue
        log(f"emptying S3 bucket {name}")
        empty_bucket(s3, name)
        if delete_buckets:
            safe(s3.delete_bucket, Bucket=name)


def sweep_rest():
    # EventBridge Scheduler
    sch = aws("scheduler")
    try:
        groups = ["default"] + [g["Name"] for g in sch.list_schedule_groups().get("ScheduleGroups", [])
                                if g["Name"] != "default"]
        for g in groups:
            for page in sch.get_paginator("list_schedules").paginate(GroupName=g):
                for s in page.get("Schedules", []):
                    if ours(s["Name"]):
                        log(f"deleting schedule {g}/{s['Name']}")
                        safe(sch.delete_schedule, Name=s["Name"], GroupName=g)
            if ours(g):
                safe(sch.delete_schedule_group, Name=g)
    except ClientError as e:
        log(f"scheduler sweep: {err_code(e)}")
    # Lambda + event source mappings
    lam = aws("lambda")
    try:
        fns = []
        for page in lam.get_paginator("list_functions").paginate():
            fns.extend(page.get("Functions", []))
        for page in lam.get_paginator("list_event_source_mappings").paginate():
            for esm in page.get("EventSourceMappings", []):
                fn = esm.get("FunctionArn", "").split(":function:")[-1].split(":")[0]
                src = esm.get("EventSourceArn", "").split(":")[-1]
                if ours(fn) or ours(src):
                    log(f"deleting event source mapping {esm['UUID']}")
                    safe(lam.delete_event_source_mapping, UUID=esm["UUID"])
        for f in fns:
            if ours(f["FunctionName"]):
                log(f"deleting lambda {f['FunctionName']}")
                safe(lam.delete_function, FunctionName=f["FunctionName"])
    except ClientError as e:
        log(f"lambda sweep: {err_code(e)}")
    # SQS
    sqs = aws("sqs")
    try:
        for url in sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", []) or []:
            if ours(url.rsplit("/", 1)[-1]):
                log(f"deleting queue {url}")
                safe(sqs.delete_queue, QueueUrl=url)
    except ClientError as e:
        log(f"sqs sweep: {err_code(e)}")
    # DynamoDB
    ddb = aws("dynamodb")
    try:
        for page in ddb.get_paginator("list_tables").paginate():
            for t in page.get("TableNames", []):
                if ours(t):
                    log(f"deleting dynamodb table {t}")
                    safe(ddb.delete_table, TableName=t)
    except ClientError as e:
        log(f"dynamodb sweep: {err_code(e)}")
    # CloudWatch Logs
    logs = aws("logs")
    try:
        for lp in (f"/clearledger/{PREFIX}", f"/aws/lambda/{PREFIX}", f"/ecs/{PREFIX}", PREFIX):
            for page in logs.get_paginator("describe_log_groups").paginate(logGroupNamePrefix=lp):
                for g in page.get("logGroups", []):
                    log(f"deleting log group {g['logGroupName']}")
                    safe(logs.delete_log_group, logGroupName=g["logGroupName"])
    except ClientError as e:
        log(f"logs sweep: {err_code(e)}")
    # ECS
    ecs = aws("ecs")
    try:
        for arn in ecs.list_clusters().get("clusterArns", []):
            cname = arn.rsplit("/", 1)[-1]
            if not ours(cname):
                continue
            for sarn in ecs.list_services(cluster=arn).get("serviceArns", []):
                safe(ecs.update_service, cluster=arn, service=sarn, desiredCount=0)
                safe(ecs.delete_service, cluster=arn, service=sarn, force=True)
            for tarn in ecs.list_tasks(cluster=arn).get("taskArns", []):
                safe(ecs.stop_task, cluster=arn, task=tarn)
            log(f"deleting ECS cluster {cname}")
            safe(ecs.delete_cluster, cluster=arn)
        for page in ecs.get_paginator("list_task_definitions").paginate(familyPrefix=PREFIX):
            for td in page.get("taskDefinitionArns", []):
                safe(ecs.deregister_task_definition, taskDefinition=td)
    except ClientError as e:
        log(f"ecs sweep: {err_code(e)}")
    # ELBv2
    elb = aws("elbv2")
    try:
        for lb in elb.describe_load_balancers().get("LoadBalancers", []):
            if ours(lb["LoadBalancerName"]):
                for ls in elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
                    safe(elb.delete_listener, ListenerArn=ls["ListenerArn"])
                log(f"deleting load balancer {lb['LoadBalancerName']}")
                safe(elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
        for tg in elb.describe_target_groups().get("TargetGroups", []):
            if ours(tg["TargetGroupName"]):
                safe(elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])
    except ClientError as e:
        log(f"elbv2 sweep: {err_code(e)}")
    # ElastiCache
    ec = aws("elasticache")
    try:
        for rg in ec.describe_replication_groups().get("ReplicationGroups", []):
            if ours(rg["ReplicationGroupId"]):
                log(f"deleting replication group {rg['ReplicationGroupId']}")
                safe(ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
        for cc in ec.describe_cache_clusters().get("CacheClusters", []):
            if ours(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId"):
                safe(ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
        for sg in ec.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
            if ours(sg["CacheSubnetGroupName"]):
                safe(ec.delete_cache_subnet_group, CacheSubnetGroupName=sg["CacheSubnetGroupName"])
    except ClientError as e:
        log(f"elasticache sweep: {err_code(e)}")
    # RDS
    rds = aws("rds")
    try:
        for db in rds.describe_db_instances().get("DBInstances", []):
            if ours(db["DBInstanceIdentifier"]) and db.get("DBInstanceStatus") != "deleting":
                log(f"deleting RDS instance {db['DBInstanceIdentifier']}")
                safe(rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                     SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
        for g in rds.describe_db_subnet_groups().get("DBSubnetGroups", []):
            if ours(g["DBSubnetGroupName"]):
                safe(rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    except ClientError as e:
        log(f"rds sweep: {err_code(e)}")
    # Cognito
    cog = aws("cognito-idp")
    try:
        for p in cog.list_user_pools(MaxResults=60).get("UserPools", []):
            if ours(p["Name"]):
                log(f"deleting user pool {p['Name']}")
                try:
                    d = cog.describe_user_pool(UserPoolId=p["Id"])["UserPool"]
                    if d.get("Domain"):
                        safe(cog.delete_user_pool_domain, Domain=d["Domain"], UserPoolId=p["Id"])
                except ClientError:
                    pass
                safe(cog.delete_user_pool, UserPoolId=p["Id"])
    except ClientError as e:
        log(f"cognito sweep: {err_code(e)}")
    # KMS aliases + keys
    kms = aws("kms")
    try:
        alias_targets = set()
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page.get("Aliases", []):
                if a["AliasName"].startswith(f"alias/{PREFIX}") and \
                        not a["AliasName"].startswith(f"alias/{BASELINE_PREFIX}"):
                    if a.get("TargetKeyId"):
                        alias_targets.add(a["TargetKeyId"])
                    log(f"deleting KMS alias {a['AliasName']}")
                    safe(kms.delete_alias, AliasName=a["AliasName"])
        for page in kms.get_paginator("list_keys").paginate():
            for k in page.get("Keys", []):
                kid = k["KeyId"]
                try:
                    meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
                except ClientError:
                    continue
                if meta.get("KeyManager") == "AWS" or meta.get("KeyState") in ("PendingDeletion",):
                    continue
                tagged = False
                try:
                    tagged = tag_value(kms.list_resource_tags(KeyId=kid).get("Tags", [])) == PREFIX
                except ClientError:
                    pass
                desc = meta.get("Description") or ""
                if tagged or kid in alias_targets or desc.startswith(f"{PREFIX}-"):
                    log(f"scheduling deletion of KMS key {kid}")
                    safe(kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)
    except ClientError as e:
        log(f"kms sweep: {err_code(e)}")


def sweep_network():
    ec2 = aws("ec2")
    try:
        vpcs = ec2.describe_vpcs(Filters=[{"Name": "tag:ClearLedgerDeployment", "Values": [PREFIX]}]).get("Vpcs", [])
    except ClientError:
        return
    for vpc in vpcs:
        vid = vpc["VpcId"]
        log(f"sweeping VPC {vid}")
        for sg in ec2.describe_security_groups(Filters=[{"Name": "vpc-id", "Values": [vid]}]).get("SecurityGroups", []):
            if sg["GroupName"] == "default":
                continue
            if sg.get("IpPermissions"):
                safe(ec2.revoke_security_group_ingress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissions"])
            if sg.get("IpPermissionsEgress"):
                safe(ec2.revoke_security_group_egress, GroupId=sg["GroupId"],
                     IpPermissions=sg["IpPermissionsEgress"])
        for sg in ec2.describe_security_groups(Filters=[{"Name": "vpc-id", "Values": [vid]}]).get("SecurityGroups", []):
            if sg["GroupName"] != "default":
                safe(ec2.delete_security_group, GroupId=sg["GroupId"])
        for rt in ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vid]}]).get("RouteTables", []):
            main = any(a.get("Main") for a in rt.get("Associations", []))
            for a in rt.get("Associations", []):
                if not a.get("Main"):
                    safe(ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            if not main:
                safe(ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
        for igw in ec2.describe_internet_gateways(
                Filters=[{"Name": "attachment.vpc-id", "Values": [vid]}]).get("InternetGateways", []):
            safe(ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vid)
            safe(ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for sn in ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vid]}]).get("Subnets", []):
            safe(ec2.delete_subnet, SubnetId=sn["SubnetId"])
        safe(ec2.delete_vpc, VpcId=vid)


def cmd_destroy_sweep(phase):
    if phase == "pre":
        # Make Terraform-managed resources deletable: strip out-of-band IAM attachments,
        # empty versioned buckets, drop breakglass roles.
        sweep_iam(full=False)
        sweep_s3(delete_buckets=False)
    else:
        sweep_iam(full=True)
        sweep_s3(delete_buckets=True)
        sweep_rest()
        sweep_network()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "iam-drift":
        cmd_iam_drift()
    elif cmd == "sg-drift":
        cmd_sg_drift()
    elif cmd == "esm-check":
        cmd_esm_check(sys.argv[2])
    elif cmd == "reconcile":
        cmd_reconcile()
    elif cmd == "destroy-sweep":
        cmd_destroy_sweep(sys.argv[2] if len(sys.argv) > 2 else "post")
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
