#!/usr/bin/env python3
"""ClearLedger data-plane / drift convergence, run by deploy.sh after apply.

PostgreSQL is the system of record. This script:
  1. removes out-of-band IAM policies / unrestricted SG egress (belt and braces
     on top of Terraform's exclusive policy management),
  2. drains unpublished outbox rows through the outbox_relay Lambda,
  3. converges the DynamoDB projection table 1:1 with settlements/events,
  4. converges Valkey cache entries with the authoritative projection,
  5. converges the versioned S3 audit archive 1:1 with clearledger.outbox
     (re-archiving through the audit_archiver Lambda) and purges every
     noncurrent version and delete marker.
"""
import base64
import datetime as dt
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

import boto3
from botocore.config import Config

UUID_RE = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
BATCH_KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")
CACHE_KEY_RE = re.compile(r"^clearledger:settlement:(" + UUID_RE + r")$")

ENV_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
             "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId",
              "status", "clearingStage", "memo"]


def log(msg):
    print(f"[reconcile] {msg}", flush=True)


# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
MANIFEST = json.load(open(sys.argv[1]))
CONFIG = json.load(open(sys.argv[2]))
ENDPOINT = CONFIG["aws_endpoint_url"]
REGION = CONFIG["region"]
PREFIX = CONFIG["resource_prefix"]

_cfg = Config(region_name=REGION, retries={"max_attempts": 5, "mode": "standard"},
              read_timeout=180, connect_timeout=10, s3={"addressing_style": "path"})


def client(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION,
                        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
                        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
                        config=_cfg)


ddb = client("dynamodb")
s3 = client("s3")
lam = client("lambda")
sqs = client("sqs")
iam = client("iam")
ec2 = client("ec2")

DB = MANIFEST["database"]
PG_ENV = dict(os.environ, PGPASSWORD=CONFIG["db_password"], PGTZ="UTC", PGCONNECT_TIMEOUT="10")


def psql(sql):
    cmd = ["psql", "-h", DB["endpoint"], "-p", str(DB["port"]), "-U", CONFIG["db_username"],
           "-d", CONFIG["db_name"], "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql]
    last = None
    for attempt in range(5):
        r = subprocess.run(cmd, env=PG_ENV, capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout.strip()
        last = r.stderr.strip()
        time.sleep(2 + attempt)
    raise RuntimeError(f"psql failed: {last}")


def pg_json(sql):
    out = psql(f"SELECT COALESCE(json_agg(t), '[]'::json) FROM ({sql}) t")
    return json.loads(out or "[]")


def parse_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def chrono_rfc3339(ts, use_z=False):
    """Mimic chrono's DateTime<Utc>::to_rfc3339 (AutoSi fractional seconds)."""
    base = ts.strftime("%Y-%m-%dT%H:%M:%S")
    us = ts.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return base + frac + ("Z" if use_z else "+00:00")


def canonical_envelope(payload):
    out = {}
    for k in ENV_ORDER:
        if k not in payload:
            continue
        if k == "data":
            d = payload["data"]
            out["data"] = {dk: d[dk] for dk in DATA_ORDER if dk in d}
        else:
            out[k] = payload[k]
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


# --------------------------------------------------------------------------
# 1. Control-plane drift guard (IAM + security groups)
# --------------------------------------------------------------------------
def converge_iam():
    canonical = {
        MANIFEST["iam"][k].split("/")[-1]: None for k in MANIFEST["iam"]
    }
    for role in canonical:
        expected_inline = f"{role}-least-privilege"
        try:
            names = iam.list_role_policies(RoleName=role).get("PolicyNames", [])
        except Exception as e:  # noqa: BLE001
            log(f"iam: cannot list inline policies of {role}: {e}")
            continue
        for n in names:
            if n != expected_inline:
                log(f"iam: deleting out-of-band inline policy {n} from {role}")
                iam.delete_role_policy(RoleName=role, PolicyName=n)
        try:
            attached = iam.list_attached_role_policies(RoleName=role).get("AttachedPolicies", [])
        except Exception as e:  # noqa: BLE001
            log(f"iam: cannot list attached policies of {role}: {e}")
            continue
        for p in attached:
            log(f"iam: detaching out-of-band policy {p['PolicyArn']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=p["PolicyArn"])


def converge_security_groups():
    sgs = MANIFEST["network"]["security_group_ids"]
    for name in ("alb", "rds", "valkey"):
        try:
            sg = ec2.describe_security_groups(GroupIds=[sgs[name]])["SecurityGroups"][0]
        except Exception as e:  # noqa: BLE001
            log(f"sg: cannot describe {name}: {e}")
            continue
        for perm in sg.get("IpPermissionsEgress", []):
            bad4 = [r for r in perm.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
            bad6 = [r for r in perm.get("Ipv6Ranges", []) if r.get("CidrIpv6") == "::/0"]
            if not bad4 and not bad6:
                continue
            p = {k: v for k, v in perm.items() if k in ("IpProtocol", "FromPort", "ToPort")}
            if bad4:
                p["IpRanges"] = [{"CidrIp": "0.0.0.0/0"}]
            if bad6:
                p["Ipv6Ranges"] = [{"CidrIpv6": "::/0"}]
            log(f"sg: revoking unrestricted egress {p} on {name}")
            try:
                ec2.revoke_security_group_egress(GroupId=sgs[name], IpPermissions=[p])
            except Exception as e:  # noqa: BLE001
                log(f"sg: revoke failed on {name}: {e}")


# --------------------------------------------------------------------------
# 2. Outbox drain
# --------------------------------------------------------------------------
def invoke(fn):
    r = lam.invoke(FunctionName=fn, InvocationType="RequestResponse", Payload=b"{}")
    body = r["Payload"].read().decode(errors="replace")
    if r.get("FunctionError"):
        log(f"lambda {fn} returned error: {body[:300]}")
        return None
    return body


def drain_outbox():
    fn = MANIFEST["workers"]["outbox_relay"]["function_name"]
    stalled = 0
    for _ in range(60):
        pending = int(psql("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL"))
        if pending == 0:
            log("outbox: no unpublished rows")
            return
        log(f"outbox: {pending} unpublished rows, invoking {fn}")
        invoke(fn)
        after = int(psql("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL"))
        if after >= pending:
            stalled += 1
            if stalled >= 8:
                raise RuntimeError(f"outbox relay is not making progress ({after} rows pending)")
            time.sleep(2)
        else:
            stalled = 0
    raise RuntimeError("outbox drain did not converge")


def wait_queue_drained(timeout=120):
    url = MANIFEST["messaging"]["queue_url"]
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            a = sqs.get_queue_attributes(
                QueueUrl=url,
                AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
            )["Attributes"]
            n = int(a.get("ApproximateNumberOfMessages", 0)) + int(a.get("ApproximateNumberOfMessagesNotVisible", 0))
        except Exception as e:  # noqa: BLE001
            log(f"sqs: attributes unavailable: {e}")
            n = 0
        if n == 0:
            log("sqs: main queue drained")
            return
        time.sleep(2)
    log("sqs: main queue still has in-flight messages; continuing with direct convergence")


# --------------------------------------------------------------------------
# 3. DynamoDB projection convergence
# --------------------------------------------------------------------------
def S(v):
    return {"S": v}


def N(v):
    return {"N": str(int(v))}


def norm_item(item):
    out = {}
    for k, v in item.items():
        (t, val), = v.items()
        if t == "N":
            val = str(int(float(val))) if re.fullmatch(r"-?\d+(\.0+)?", val) else val
        out[k] = (t, val if not isinstance(val, list) else tuple(sorted(map(str, val))))
    return out


def expected_projection(settlements, events):
    items = {}
    for s in settlements:
        sid = s["settlement_id"]
        pk = f"SETTLEMENT#{sid}"
        st = {
            "PK": S(pk), "SK": S("STATE"),
            "GSI1PK": S(f"ACCOUNT#{s['account_id']}"), "GSI1SK": S(f"SETTLEMENT#{sid}"),
            "settlement_id": S(sid), "account_id": S(s["account_id"]),
            "reference": S(s["reference"]), "debit_party": S(s["debit_party"]),
            "credit_party": S(s["credit_party"]), "status": S(s["current_status"]),
            "clearing_stage": S(s["current_stage"]), "version": N(s["version"]),
            "entry_count": N(s["entry_count"]),
            "updated_at": S(chrono_rfc3339(parse_ts(s["updated_at"]))),
        }
        if s.get("last_entry_id") is not None:
            st["last_entry_id"] = S(s["last_entry_id"])
        if s.get("last_memo") is not None:
            st["last_memo"] = S(s["last_memo"])
        items[(pk, "STATE")] = st
    for e in events:
        sid = e["settlement_id"]
        pk = f"SETTLEMENT#{sid}"
        sk = "EVENT#%08d" % int(e["aggregate_version"])
        p = e["payload"]
        d = p.get("data", {})
        it = {
            "PK": S(pk), "SK": S(sk), "settlement_id": S(sid), "event_id": S(e["event_id"]),
            "version": N(e["aggregate_version"]), "event_type": S(e["event_type"]),
            "status": S(d.get("status")), "clearing_stage": S(d.get("clearingStage")),
            "occurred_at": S(chrono_rfc3339(parse_ts(e["occurred_at"]))),
            "correlation_id": S(e["correlation_id"]), "envelope": S(canonical_envelope(p)),
        }
        if d.get("entryId") is not None:
            it["entry_id"] = S(d["entryId"])
        if d.get("memo") is not None:
            it["memo"] = S(d["memo"])
        items[(pk, sk)] = it
    return items


def scan_table(table):
    items = []
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        r = ddb.scan(**kw)
        items.extend(r.get("Items", []))
        if not r.get("LastEvaluatedKey"):
            return items
        kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]


def batch_write(table, requests):
    for i in range(0, len(requests), 25):
        chunk = requests[i:i + 25]
        pending = {table: chunk}
        for _ in range(10):
            r = ddb.batch_write_item(RequestItems=pending)
            pending = r.get("UnprocessedItems") or {}
            if not pending:
                break
            time.sleep(0.5)


def converge_dynamodb():
    table = MANIFEST["projections"]["table_name"]
    # Scan first, then snapshot PostgreSQL: anything projected before the
    # scan was committed before the snapshot, so "absent from PG" == orphan.
    current = scan_table(table)
    settlements = pg_json("SELECT settlement_id, account_id, reference, debit_party, credit_party, "
                          "current_status, current_stage, last_entry_id, last_memo, version, entry_count, "
                          "updated_at FROM clearledger.settlements")
    events = pg_json("SELECT settlement_id, aggregate_version, event_id, event_type, correlation_id, "
                     "occurred_at, payload FROM clearledger.events ORDER BY seq")
    expected = expected_projection(settlements, events)

    seen = set()
    deletes, puts, state_puts = [], [], []
    for it in current:
        key = (it.get("PK", {}).get("S"), it.get("SK", {}).get("S"))
        if key[0] is None or key[1] is None:
            continue
        seen.add(key)
        exp = expected.get(key)
        if exp is None:
            deletes.append({"DeleteRequest": {"Key": {"PK": it["PK"], "SK": it["SK"]}}})
        elif norm_item(exp) != norm_item(it):
            (state_puts if key[1] == "STATE" else puts).append(exp)
    for key, exp in expected.items():
        if key not in seen:
            (state_puts if key[1] == "STATE" else puts).append(exp)

    log(f"dynamodb: {len(current)} items scanned, {len(expected)} expected; "
        f"deleting {len(deletes)}, writing {len(puts)} events and {len(state_puts)} states")
    batch_write(table, deletes)
    batch_write(table, [{"PutRequest": {"Item": p}} for p in puts])
    for st in state_puts:
        try:
            ddb.put_item(TableName=table, Item=st,
                         ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                         ExpressionAttributeNames={"#v": "version"},
                         ExpressionAttributeValues={":v": st["version"]})
        except ddb.exceptions.ConditionalCheckFailedException:
            log(f"dynamodb: {st['PK']['S']} already projected at a newer version")
    return settlements


# --------------------------------------------------------------------------
# 4. Valkey convergence
# --------------------------------------------------------------------------
class Resp:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=15)
        self.f = self.sock.makefile("rb")

    def cmd(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.sock.sendall(out)
        return self._read()

    def _read(self):
        line = self.f.readline()
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
            return None if n < 0 else [self._read() for _ in range(n)]
        raise RuntimeError(f"unexpected RESP reply {line!r}")


def projection_matches(raw, s):
    try:
        c = json.loads(raw)
    except Exception:  # noqa: BLE001
        return False
    if not isinstance(c, dict):
        return False
    want = {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["current_status"],
        "clearingStage": s["current_stage"], "lastEntryId": s.get("last_entry_id"),
        "lastMemo": s.get("last_memo"), "version": s["version"], "entryCount": s["entry_count"],
    }
    allowed = set(want) | {"updatedAt"}
    if set(c) - allowed:
        return False
    for k, v in want.items():
        got = c.get(k)
        if k == "lastEntryId" and got is not None and v is not None:
            if str(got).lower() != str(v).lower():
                return False
        elif k == "settlementId":
            if str(got).lower() != str(v).lower():
                return False
        elif got != v:
            return False
    try:
        return parse_ts(c["updatedAt"]) == parse_ts(s["updated_at"])
    except Exception:  # noqa: BLE001
        return False


def scan_cache(settlements, r):
    by_id = {s["settlement_id"].lower(): s for s in settlements}
    cursor, removed, kept = "0", 0, 0
    while True:
        cursor, keys = r.cmd("SCAN", cursor, "COUNT", 1000)
        cursor = cursor.decode() if isinstance(cursor, bytes) else str(cursor)
        for kb in keys:
            k = kb.decode(errors="replace")
            m = CACHE_KEY_RE.match(k)
            ok = False
            if m and m.group(1).lower() in by_id:
                t = r.cmd("TYPE", kb)
                ttl = r.cmd("TTL", kb)
                if t == "string" and isinstance(ttl, int) and 0 < ttl <= 90:
                    raw = r.cmd("GET", kb)
                    ok = raw is not None and projection_matches(raw, by_id[m.group(1).lower()])
            if ok:
                kept += 1
            else:
                r.cmd("DEL", kb)
                removed += 1
        if cursor == "0":
            break
    return kept, removed


def token(kind):
    c = MANIFEST["auth"]["clients"][kind]
    basic = base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode()
    req = urllib.request.Request(
        MANIFEST["auth"]["token_endpoint"],
        data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": c["scope"]}).encode(),
        headers={"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())["access_token"]


def converge_valkey(settlements):
    cache = MANIFEST["cache"]
    r = Resp(cache["endpoint"], int(cache["port"]))
    kept, removed = scan_cache(settlements, r)
    log(f"valkey: kept {kept} valid entries, removed {removed} orphan/stale/divergent keys")

    # Warm the cache through the API so each settlement has a canonical,
    # TTL-bounded entry written by the application itself.
    if 0 < len(settlements) <= 400:
        try:
            tok = token("read")
            base = MANIFEST["service_url"].rstrip("/")
            for s in settlements:
                req = urllib.request.Request(
                    f"{base}/v1/settlements/{s['settlement_id']}",
                    headers={"Authorization": f"Bearer {tok}", "X-Correlation-Id": "deploy-reconcile"})
                try:
                    urllib.request.urlopen(req, timeout=10).read()
                except Exception:  # noqa: BLE001
                    pass
        except Exception as e:  # noqa: BLE001
            log(f"valkey: cache warm-up skipped: {e}")
    # Re-verify against a fresh snapshot (live traffic may have moved on).
    fresh = pg_json("SELECT settlement_id, account_id, reference, debit_party, credit_party, current_status, "
                    "current_stage, last_entry_id, last_memo, version, entry_count, updated_at "
                    "FROM clearledger.settlements")
    kept, removed = scan_cache(fresh, r)
    log(f"valkey: verified {kept} entries, removed {removed}")


# --------------------------------------------------------------------------
# 5. S3 audit archive convergence
# --------------------------------------------------------------------------
def list_versions(bucket):
    versions, markers = [], []
    kw = {"Bucket": bucket}
    while True:
        r = s3.list_object_versions(**kw)
        versions.extend(r.get("Versions", []))
        markers.extend(r.get("DeleteMarkers", []))
        if not r.get("IsTruncated"):
            break
        kw = {"Bucket": bucket}
        if r.get("NextKeyMarker"):
            kw["KeyMarker"] = r["NextKeyMarker"]
        if r.get("NextVersionIdMarker"):
            kw["VersionIdMarker"] = r["NextVersionIdMarker"]
    return versions, markers


def delete_versions(bucket, objs):
    objs = [o for o in objs if o.get("Key") is not None]
    for i in range(0, len(objs), 500):
        chunk = objs[i:i + 500]
        try:
            r = s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
            errs = r.get("Errors", [])
        except Exception as e:  # noqa: BLE001
            log(f"s3: bulk delete failed ({e}); deleting individually")
            errs = chunk
        for o in errs:
            kw = {"Bucket": bucket, "Key": o["Key"]}
            if o.get("VersionId") and o["VersionId"] != "null":
                kw["VersionId"] = o["VersionId"]
            elif o.get("VersionId") == "null":
                kw["VersionId"] = "null"
            try:
                s3.delete_object(**kw)
            except Exception as e:  # noqa: BLE001
                log(f"s3: delete {kw} failed: {e}")


def validate_batch(key, body, by_event, claimed):
    m = BATCH_KEY_RE.match(key)
    if not m:
        return None, "non-canonical key"
    if hashlib.sha256(body).hexdigest()[:16] != m.group(3):
        return None, "digest mismatch"
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        return None, "not utf-8"
    lines = [ln for ln in text.split("\n") if ln.strip() != ""]
    if not lines:
        return None, "empty batch"
    seqs = []
    for ln in lines:
        try:
            rec = json.loads(ln)
        except Exception:  # noqa: BLE001
            return None, "invalid json line"
        if not isinstance(rec, dict):
            return None, "record is not an object"
        row = by_event.get(str(rec.get("eventId", "")).lower())
        if row is None:
            return None, "unknown event"
        if rec != row["payload"]:
            return None, "payload mismatch"
        seqs.append(int(row["seq"]))
    if any(b <= a for a, b in zip(seqs, seqs[1:])):
        return None, "records not in ascending seq order"
    if seqs[0] != int(m.group(1)) or seqs[-1] != int(m.group(2)):
        return None, "key seq range mismatch"
    if any(s in claimed for s in seqs):
        return None, "duplicate events across batches"
    return seqs, None


def s3_pass(bucket):
    """One convergence pass. Returns (changes, covered seqs)."""
    versions, markers = list_versions(bucket)
    # Snapshot after listing: every archived record already has a row.
    rows = pg_json("SELECT seq, event_id, payload, published_at, archived_at FROM clearledger.outbox ORDER BY seq")
    by_event = {r["event_id"].lower(): r for r in rows}

    by_key = {}
    for v in versions:
        by_key.setdefault(v["Key"], []).append(dict(v, _marker=False))
    for d in markers:
        by_key.setdefault(d["Key"], []).append(dict(d, _marker=True))

    def batch_sort(k):
        m = BATCH_KEY_RE.match(k)
        return (0, int(m.group(1)), k) if m else (1, 0, k)

    to_delete, claimed, changes = [], set(), 0
    for key in sorted(by_key, key=batch_sort):
        entries = by_key[key]
        latest = next((e for e in entries if e.get("IsLatest")), None)
        keep = None
        if latest is not None and not latest["_marker"] and key.startswith("ledger-audit/"):
            try:
                body = s3.get_object(Bucket=bucket, Key=key, VersionId=latest["VersionId"])["Body"].read()
            except Exception:  # noqa: BLE001
                body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            seqs, why = validate_batch(key, body, by_event, claimed)
            if seqs is not None:
                claimed.update(seqs)
                keep = latest
            else:
                log(f"s3: dropping {key}: {why}")
        elif latest is None or latest["_marker"]:
            log(f"s3: dropping {key}: deleted (delete marker is current)")
        else:
            log(f"s3: dropping {key}: outside ledger-audit/")
        for e in entries:
            if keep is not None and e is keep:
                continue
            to_delete.append({"Key": key, "VersionId": e["VersionId"]})
    if to_delete:
        log(f"s3: permanently deleting {len(to_delete)} object versions / delete markers")
        delete_versions(bucket, to_delete)
        changes += len(to_delete)

    # Bring archived_at in line with what the archive actually holds.
    unarchive = [r["seq"] for r in rows if r["archived_at"] is not None and int(r["seq"]) not in claimed]
    mark = [r["seq"] for r in rows
            if r["archived_at"] is None and r["published_at"] is not None and int(r["seq"]) in claimed]
    if unarchive:
        log(f"s3: {len(unarchive)} outbox rows are not archived in S3; resetting archived_at for re-archival")
        psql("UPDATE clearledger.outbox SET archived_at = NULL "
             f"WHERE archived_at IS NOT NULL AND seq = ANY('{{{','.join(map(str, unarchive))}}}'::bigint[])")
        changes += len(unarchive)
    if mark:
        log(f"s3: {len(mark)} outbox rows already archived in S3; stamping archived_at")
        psql("UPDATE clearledger.outbox SET archived_at = GREATEST(NOW(), published_at) "
             "WHERE archived_at IS NULL AND published_at IS NOT NULL "
             f"AND seq = ANY('{{{','.join(map(str, mark))}}}'::bigint[])")
        changes += len(mark)
    return changes


def run_archiver():
    fn = MANIFEST["workers"]["audit_archiver"]["function_name"]
    stalled = 0
    for _ in range(80):
        pending = int(psql("SELECT count(*) FROM clearledger.outbox "
                           "WHERE published_at IS NOT NULL AND archived_at IS NULL"))
        if pending == 0:
            return
        log(f"archive: {pending} published rows awaiting archival, invoking {fn}")
        invoke(fn)
        after = int(psql("SELECT count(*) FROM clearledger.outbox "
                         "WHERE published_at IS NOT NULL AND archived_at IS NULL"))
        if after >= pending:
            stalled += 1
            if stalled >= 8:
                raise RuntimeError("audit archiver is not making progress")
            time.sleep(2)
        else:
            stalled = 0


def converge_s3():
    bucket = MANIFEST["audit"]["bucket_name"]
    for rnd in range(6):
        changes = s3_pass(bucket)
        run_archiver()
        if changes == 0 and rnd > 0:
            log("s3: audit archive converged")
            return
    # Final strict verification.
    changes = s3_pass(bucket)
    run_archiver()
    if s3_pass(bucket) != 0:
        raise RuntimeError("S3 audit archive did not converge")
    log("s3: audit archive converged")


def main():
    t0 = time.time()
    converge_iam()
    converge_security_groups()
    drain_outbox()
    wait_queue_drained()
    settlements = converge_dynamodb()
    converge_valkey(settlements)
    converge_s3()
    # Second relay drain in case live traffic produced new rows meanwhile.
    drain_outbox()
    log(f"done in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
