#!/usr/bin/env python3
"""ClearLedger data-plane and control-plane convergence helpers used by deploy.sh.

PostgreSQL (clearledger.*) is the system of record.  DynamoDB, Valkey and the S3 audit
archive are derived stores that are converged 1-to-1 against it.

Sub-commands:
  drain-outbox     invoke the outbox relay until no unpublished outbox rows remain
  wait-queue       wait for the main SQS queue to be drained by the projector
  iam-sg           remove out-of-band IAM policies from the six roles and open SG egress
  verify-control   verify (and report) drift on SQS / schedules / logs / lambda / mapping
  dynamodb         converge the DynamoDB projection table
  valkey           converge the Valkey cache
  s3               converge the S3 audit archive
"""
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import boto3
import psycopg2
import redis
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_PATH = os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json")
MANIFEST_PATH = os.environ.get(
    "CLEARLEDGER_MANIFEST",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "manifest.json"),
)

CFG = json.load(open(CONFIG_PATH))
MAN = json.load(open(MANIFEST_PATH))
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]
PREFIX = CFG["resource_prefix"]

UUID_RE = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


def log(msg):
    print(f"[reconcile] {msg}", flush=True)


def client(name, **kw):
    cfg = Config(retries={"max_attempts": 6, "mode": "standard"}, read_timeout=kw.pop("read_timeout", 60),
                 connect_timeout=10)
    return boto3.client(name, region_name=REGION, endpoint_url=ENDPOINT, aws_access_key_id="test",
                        aws_secret_access_key="test", config=cfg, **kw)


def pg_connect(retries=30):
    db = MAN["database"]
    last = None
    for _ in range(retries):
        try:
            conn = psycopg2.connect(host=db["endpoint"], port=db["port"], dbname=CFG["db_name"],
                                    user=CFG["db_username"], password=CFG["db_password"], connect_timeout=10)
            conn.autocommit = True
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    raise RuntimeError(f"cannot connect to PostgreSQL: {last}")


def q1(conn, sql, args=None):
    with conn.cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchone()[0]


def parse_ts(value):
    """Parse RFC3339 / ISO-8601 into an aware datetime (UTC)."""
    if isinstance(value, dt.datetime):
        return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
    s = str(value).strip()
    s = re.sub(r"[zZ]$", "+00:00", s)
    m = re.match(r"^(.*?)(\.\d+)?([+-]\d{2}:\d{2})$", s)
    if m:
        frac = (m.group(2) or "")[:7]
        s = m.group(1) + frac + m.group(3)
    return dt.datetime.fromisoformat(s).astimezone(dt.timezone.utc)


def fmt_rfc3339_offset(ts):
    """chrono-style RFC3339 with +00:00 offset and 0/3/6 fractional digits."""
    ts = ts.astimezone(dt.timezone.utc)
    us = ts.microsecond
    base = ts.strftime("%Y-%m-%dT%H:%M:%S")
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = f".{us // 1000:03d}"
    else:
        frac = f".{us:06d}"
    return f"{base}{frac}+00:00"


def fmt_rfc3339_z(ts):
    return fmt_rfc3339_offset(ts).replace("+00:00", "Z")


# --------------------------------------------------------------------------- outbox relay
def lambda_invoke(function_name, payload=None):
    lam = client("lambda", read_timeout=170)
    resp = lam.invoke(FunctionName=function_name, InvocationType="RequestResponse",
                      Payload=json.dumps(payload or {}).encode())
    body = resp["Payload"].read().decode("utf-8", "replace")
    if resp.get("FunctionError"):
        raise RuntimeError(f"{function_name} failed: {body[:500]}")
    try:
        return json.loads(body)
    except ValueError:
        return {"raw": body}


def drain_outbox(deadline_s=240):
    conn = pg_connect()
    fn = MAN["workers"]["outbox_relay"]["function_name"]
    t0 = time.time()
    stalls = 0
    while True:
        pending = q1(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        if pending == 0:
            log("outbox drained: no unpublished rows")
            return
        if time.time() - t0 > deadline_s:
            raise RuntimeError(f"outbox still has {pending} unpublished rows after {deadline_s}s")
        try:
            res = lambda_invoke(fn)
            log(f"relay invoked: {res} (pending before: {pending})")
        except Exception as exc:  # noqa: BLE001
            log(f"relay invocation failed: {exc}")
            res = {}
        after = q1(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        if after >= pending:
            stalls += 1
            time.sleep(min(2 * stalls, 10))
        else:
            stalls = 0


def wait_queue(timeout_s=45):
    sqs = client("sqs")
    url = MAN["messaging"]["queue_url"]
    t0 = time.time()
    quiet = 0
    while time.time() - t0 < timeout_s:
        try:
            a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["All"])["Attributes"]
            total = sum(int(a.get(k, 0)) for k in (
                "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
                "ApproximateNumberOfMessagesDelayed"))
        except ClientError as exc:
            log(f"queue not readable yet: {exc}")
            total = 1
        quiet = quiet + 1 if total == 0 else 0
        if quiet >= 2:
            log("main queue is drained")
            return
        time.sleep(2)
    log("main queue still holds messages after the wait window; continuing with direct reconciliation")


# --------------------------------------------------------------------------- IAM / SG drift
def role_name(arn):
    return arn.rsplit("/", 1)[-1]


def iam_sg_cleanup():
    iam = client("iam")
    for key, arn in MAN["iam"].items():
        name = role_name(arn)
        canonical = f"{name}-policy"
        names = []
        for page in iam.get_paginator("list_role_policies").paginate(RoleName=name):
            names += page["PolicyNames"]
        for pn in names:
            if pn != canonical:
                log(f"removing out-of-band inline policy {pn} from {name}")
                iam.delete_role_policy(RoleName=name, PolicyName=pn)
        attached = []
        for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=name):
            attached += page["AttachedPolicies"]
        for ap in attached:
            log(f"detaching out-of-band policy {ap['PolicyArn']} from {name}")
            iam.detach_role_policy(RoleName=name, PolicyArn=ap["PolicyArn"])
        if canonical not in names:
            raise RuntimeError(f"canonical policy {canonical} missing from role {name}")

    ec2 = client("ec2")
    ids = [MAN["network"]["security_group_ids"][k] for k in ("alb", "rds", "valkey")]
    for sg in ec2.describe_security_groups(GroupIds=ids)["SecurityGroups"]:
        for perm in sg.get("IpPermissionsEgress", []):
            v4 = [r for r in perm.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
            v6 = [r for r in perm.get("Ipv6Ranges", []) if r.get("CidrIpv6") == "::/0"]
            if not v4 and not v6:
                continue
            revoke = {"IpProtocol": perm["IpProtocol"]}
            if "FromPort" in perm:
                revoke["FromPort"] = perm["FromPort"]
            if "ToPort" in perm:
                revoke["ToPort"] = perm["ToPort"]
            if v4:
                revoke["IpRanges"] = v4
            if v6:
                revoke["Ipv6Ranges"] = v6
            log(f"revoking open egress {revoke} on {sg['GroupId']}")
            ec2.revoke_security_group_egress(GroupId=sg["GroupId"], IpPermissions=[revoke])


# --------------------------------------------------------------------------- control plane verify
def verify_control():
    """Return exit code 0 when no drift is visible on the attributes terraform may not see."""
    problems = []
    sqs = client("sqs")
    main, dlq = MAN["messaging"]["queue_url"], MAN["messaging"]["dlq_url"]
    try:
        a = sqs.get_queue_attributes(QueueUrl=main, AttributeNames=["All"])["Attributes"]
        if a.get("VisibilityTimeout") != "3":
            problems.append(f"main VisibilityTimeout={a.get('VisibilityTimeout')}")
        if a.get("MessageRetentionPeriod") != "172800":
            problems.append(f"main MessageRetentionPeriod={a.get('MessageRetentionPeriod')}")
        if a.get("ReceiveMessageWaitTimeSeconds") != "2":
            problems.append(f"main ReceiveMessageWaitTimeSeconds={a.get('ReceiveMessageWaitTimeSeconds')}")
        rp = json.loads(a.get("RedrivePolicy", "{}") or "{}")
        if int(rp.get("maxReceiveCount", 0)) != 4 or rp.get("deadLetterTargetArn") != MAN["messaging"]["dlq_arn"]:
            problems.append(f"main RedrivePolicy={rp}")
        d = sqs.get_queue_attributes(QueueUrl=dlq, AttributeNames=["All"])["Attributes"]
        if d.get("MessageRetentionPeriod") != "1209600":
            problems.append(f"dlq MessageRetentionPeriod={d.get('MessageRetentionPeriod')}")
    except ClientError as exc:
        problems.append(f"queue lookup failed: {exc}")

    lam = client("lambda")
    proj = MAN["workers"]["projector"]["function_name"]
    try:
        esms = lam.list_event_source_mappings(FunctionName=proj)["EventSourceMappings"]
        good = [e for e in esms if e.get("EventSourceArn") == MAN["messaging"]["queue_arn"]
                and e.get("State") in ("Enabled", "Enabling")
                and e.get("BatchSize") == 5
                and "ReportBatchItemFailures" in (e.get("FunctionResponseTypes") or [])]
        if not good:
            problems.append(f"projector event source mapping missing/disabled: {esms}")
        elif MAN["messaging"]["event_source_mapping_uuid"] not in [e["UUID"] for e in good]:
            problems.append("manifest event_source_mapping_uuid is stale")
    except ClientError as exc:
        problems.append(f"event source mapping lookup failed: {exc}")

    sched = client("scheduler")
    for name, expr in ((MAN["schedules"]["outbox_schedule_name"], "rate(1 minute)"),
                       (MAN["schedules"]["archive_schedule_name"], "rate(5 minutes)")):
        try:
            s = sched.get_schedule(Name=name)
            if s.get("State") != "ENABLED" or s.get("ScheduleExpression") != expr:
                problems.append(f"schedule {name}: {s.get('State')} {s.get('ScheduleExpression')}")
        except ClientError as exc:
            problems.append(f"schedule {name} lookup failed: {exc}")

    logs = client("logs")
    for lg in MAN["logs"].values():
        r = logs.describe_log_groups(logGroupNamePrefix=lg)["logGroups"]
        m = [g for g in r if g["logGroupName"] == lg]
        if not m:
            problems.append(f"log group {lg} missing")
        elif (m[0].get("retentionInDays") or 0) < 14:
            problems.append(f"log group {lg} retention={m[0].get('retentionInDays')}")

    expected_env = {
        "projector": {"PROJECTION_TABLE", "VALKEY_URL", "CLOUDWATCH_LOG_GROUP", "AWS_ENDPOINT_URL"},
        "outbox_relay": {"DATABASE_URL", "SQS_QUEUE_URL", "OUTBOX_BATCH_SIZE", "CLOUDWATCH_LOG_GROUP", "AWS_ENDPOINT_URL"},
        "audit_archiver": {"DATABASE_URL", "AUDIT_BUCKET", "AUDIT_PREFIX", "CLOUDWATCH_LOG_GROUP", "AWS_ENDPOINT_URL"},
    }
    fixed = {("outbox_relay", "OUTBOX_BATCH_SIZE"): "50", ("audit_archiver", "AUDIT_PREFIX"): "ledger-audit/",
             ("outbox_relay", "SQS_QUEUE_URL"): MAN["messaging"]["queue_url"],
             ("audit_archiver", "AUDIT_BUCKET"): MAN["audit"]["bucket_name"],
             ("projector", "PROJECTION_TABLE"): MAN["projections"]["table_name"]}
    for w, keys in expected_env.items():
        fn = MAN["workers"][w]["function_name"]
        try:
            env = lam.get_function_configuration(FunctionName=fn).get("Environment", {}).get("Variables", {})
        except ClientError as exc:
            problems.append(f"lambda {fn} lookup failed: {exc}")
            continue
        for k in keys:
            if k not in env:
                problems.append(f"lambda {fn} missing env {k}")
        for (ww, k), v in fixed.items():
            if ww == w and env.get(k) != v:
                problems.append(f"lambda {fn} env {k}={env.get(k)!r}")
        if env.get("AWS_ENDPOINT_URL") != ENDPOINT:
            problems.append(f"lambda {fn} env AWS_ENDPOINT_URL={env.get('AWS_ENDPOINT_URL')!r}")

    for p in problems:
        log(f"DRIFT: {p}")
    return 1 if problems else 0


# --------------------------------------------------------------------------- PostgreSQL snapshot
ENV_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId", "aggregateVersion",
             "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId", "status",
              "clearingStage", "memo"]


def struct_order(payload):
    out = {k: payload[k] for k in ENV_ORDER if k in payload}
    out["data"] = {k: payload["data"][k] for k in DATA_ORDER if k in payload["data"]}
    return out


def load_pg_state(conn):
    """Return (settlements, events) keyed by settlement id from one consistent snapshot."""
    settlements, events = {}, {}
    with conn.cursor() as cur:
        cur.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        try:
            cur.execute("""SELECT settlement_id::text, account_id, reference, debit_party, credit_party,
                                  current_status, current_stage, last_entry_id::text, last_memo, version,
                                  entry_count, updated_at
                           FROM clearledger.settlements""")
            for r in cur.fetchall():
                settlements[r[0]] = dict(zip(
                    ["settlement_id", "account_id", "reference", "debit_party", "credit_party", "status",
                     "clearing_stage", "last_entry_id", "last_memo", "version", "entry_count", "updated_at"], r))
            cur.execute("""SELECT settlement_id::text, event_id::text, aggregate_version, event_type,
                                  correlation_id, occurred_at, payload
                           FROM clearledger.events ORDER BY settlement_id, aggregate_version""")
            for r in cur.fetchall():
                events.setdefault(r[0], []).append(dict(zip(
                    ["settlement_id", "event_id", "version", "event_type", "correlation_id", "occurred_at",
                     "payload"], r)))
        finally:
            cur.execute("COMMIT")
    return settlements, events


def expected_items(sid, s, evs):
    """Expected DynamoDB items (native python values) keyed by SK."""
    pk = f"SETTLEMENT#{sid}"
    items = {}
    state = {
        "PK": pk, "SK": "STATE", "GSI1PK": f"ACCOUNT#{s['account_id']}", "GSI1SK": f"SETTLEMENT#{sid}",
        "settlement_id": sid, "account_id": s["account_id"], "reference": s["reference"],
        "debit_party": s["debit_party"], "credit_party": s["credit_party"], "status": s["status"],
        "clearing_stage": s["clearing_stage"], "version": int(s["version"]),
        "entry_count": int(s["entry_count"]), "updated_at": s["updated_at"],
    }
    if s["last_entry_id"] is not None:
        state["last_entry_id"] = s["last_entry_id"]
    if s["last_memo"] is not None:
        state["last_memo"] = s["last_memo"]
    items["STATE"] = state
    for e in evs:
        d = e["payload"]["data"]
        it = {
            "PK": pk, "SK": f"EVENT#{e['version']:08d}", "settlement_id": sid, "event_id": e["event_id"],
            "version": int(e["version"]), "event_type": e["event_type"], "status": d["status"],
            "clearing_stage": d["clearingStage"], "occurred_at": e["occurred_at"],
            "correlation_id": e["correlation_id"], "envelope": e["payload"],
        }
        if d.get("entryId") is not None:
            it["entry_id"] = d["entryId"]
        if d.get("memo") is not None:
            it["memo"] = d["memo"]
        items[it["SK"]] = it
    return items


def normalise(item):
    out = {}
    for k, v in item.items():
        if isinstance(v, Decimal):
            v = int(v) if v == v.to_integral_value() else float(v)
        if k in ("occurred_at", "updated_at"):
            try:
                v = parse_ts(v)
            except Exception:  # noqa: BLE001
                pass
        elif k == "envelope":
            if isinstance(v, (str, bytes)):
                try:
                    v = json.loads(v)
                except ValueError:
                    pass
        out[k] = v
    return out


def to_ddb_item(item):
    out = dict(item)
    if "updated_at" in out:
        out["updated_at"] = fmt_rfc3339_offset(out["updated_at"])
    if "occurred_at" in out:
        out["occurred_at"] = fmt_rfc3339_offset(out["occurred_at"])
    if "envelope" in out:
        out["envelope"] = json.dumps(struct_order(out["envelope"]), separators=(",", ":"), ensure_ascii=False)
    ser = TypeSerializer()
    return {k: ser.serialize(v) for k, v in out.items()}


# --------------------------------------------------------------------------- DynamoDB
def ddb_scan_all(ddb, table):
    des = TypeDeserializer()
    parts = {}
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        r = ddb.scan(**kw)
        for raw in r.get("Items", []):
            item = {k: des.deserialize(v) for k, v in raw.items()}
            parts.setdefault(item.get("PK"), {})[item.get("SK")] = item
        if "LastEvaluatedKey" not in r:
            break
        kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]
    return parts


def ddb_pass(conn, ddb, table):
    parts = ddb_scan_all(ddb, table)           # scan first ...
    settlements, events = load_pg_state(conn)   # ... then PG, so PG is never older than what was scanned
    deletes, puts = [], []

    pk_re = re.compile(rf"^SETTLEMENT#({UUID_RE})$")
    for pk, items in parts.items():
        m = pk_re.match(pk) if isinstance(pk, str) else None
        sid = m.group(1) if m else None
        if sid is None or sid not in settlements:
            if sid is not None and q1(conn, "SELECT count(*) FROM clearledger.settlements WHERE settlement_id = %s",
                                      (sid,)):
                continue  # created after the snapshot; the next pass handles it
            for sk in items:
                log(f"deleting orphan DynamoDB item {pk} / {sk}")
                deletes.append((pk, sk))

    for sid, s in settlements.items():
        pk = f"SETTLEMENT#{sid}"
        have = parts.get(pk, {})
        want = expected_items(sid, s, events.get(sid, []))
        for sk in sorted(set(have) - set(want)):
            log(f"deleting stray DynamoDB item {pk} / {sk}")
            deletes.append((pk, sk))
        for sk, w in want.items():
            h = have.get(sk)
            if h is not None and normalise(h) == normalise(w):
                continue
            if len(puts) < 20:
                log(f"{'repairing' if h else 'creating'} DynamoDB item {pk} / {sk}")
            puts.append((sk, w))

    def do_delete(args):
        pk, sk = args
        ddb.delete_item(TableName=table, Key={"PK": {"S": pk}, "SK": {"S": sk}})

    def do_put(args):
        sk, w = args
        kw = {"TableName": table, "Item": to_ddb_item(w)}
        if sk == "STATE":
            # never regress a state the projector has advanced in the meantime
            kw["ConditionExpression"] = "attribute_not_exists(PK) OR version <= :v"
            kw["ExpressionAttributeValues"] = {":v": {"N": str(w["version"])}}
        try:
            ddb.put_item(**kw)
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    if len(puts) > 20:
        log(f"... and {len(puts) - 20} more DynamoDB item(s) to create/repair")
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(do_delete, deletes))
        list(pool.map(do_put, puts))
    return len(deletes) + len(puts)


def reconcile_dynamodb():
    conn = pg_connect()
    ddb = client("dynamodb")
    table = MAN["projections"]["table_name"]
    for i in range(1, 8):
        n = ddb_pass(conn, ddb, table)
        log(f"dynamodb pass {i}: {n} change(s)")
        if n == 0:
            return
        time.sleep(2)
    raise RuntimeError("DynamoDB did not converge")


# --------------------------------------------------------------------------- Valkey
def projection_json(s):
    return {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["status"],
        "clearingStage": s["clearing_stage"], "lastEntryId": s["last_entry_id"], "lastMemo": s["last_memo"],
        "version": int(s["version"]), "entryCount": int(s["entry_count"]), "updatedAt": parse_ts(s["updated_at"]),
    }


def norm_cached(d):
    d = dict(d)
    d["updatedAt"] = parse_ts(d["updatedAt"])
    d.setdefault("lastEntryId", None)
    d.setdefault("lastMemo", None)
    return d


def reconcile_valkey():
    conn = pg_connect()
    host, port = MAN["cache"]["endpoint"], int(MAN["cache"]["port"])
    r = redis.Redis(host=host, port=port, decode_responses=True, socket_timeout=10, socket_connect_timeout=10)
    key_re = re.compile(rf"^clearledger:settlement:({UUID_RE})$")
    for attempt in range(3):
        settlements, _ = load_pg_state(conn)
        removed = 0
        for key in list(r.scan_iter(match="*", count=500)):
            m = key_re.match(key)
            reason = None
            if not m:
                reason = "not a settlement cache key"
            else:
                sid = m.group(1)
                s = settlements.get(sid)
                if s is None:
                    if q1(conn, "SELECT count(*) FROM clearledger.settlements WHERE settlement_id = %s", (sid,)):
                        continue
                    reason = "orphan (settlement not in PostgreSQL)"
                else:
                    ttl = r.ttl(key)
                    if not (0 < ttl <= 90):
                        reason = f"invalid ttl {ttl}"
                    else:
                        try:
                            val = r.get(key)
                            if val is None:
                                continue
                            if norm_cached(json.loads(val)) != projection_json(s):
                                reason = "payload diverges from authoritative projection"
                        except Exception:  # noqa: BLE001
                            reason = "unreadable payload"
            if reason:
                log(f"deleting Valkey key {key}: {reason}")
                r.delete(key)
                removed += 1
        log(f"valkey pass {attempt + 1}: removed {removed}")
        if removed == 0:
            return
    # the API only re-populates keys from DynamoDB which is already converged, so this terminates


# --------------------------------------------------------------------------- S3 audit archive
KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def list_versions(s3, bucket):
    versions, markers = [], []
    kw = {"Bucket": bucket}
    while True:
        r = s3.list_object_versions(**kw)
        versions += r.get("Versions", [])
        markers += r.get("DeleteMarkers", [])
        if not r.get("IsTruncated"):
            break
        kw["KeyMarker"] = r.get("NextKeyMarker")
        if r.get("NextVersionIdMarker"):
            kw["VersionIdMarker"] = r["NextVersionIdMarker"]
    return versions, markers


def delete_versions(s3, bucket, entries):
    entries = [{"Key": e["Key"], "VersionId": e["VersionId"]} for e in entries]
    for i in range(0, len(entries), 500):
        chunk = entries[i:i + 500]
        r = s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
        errs = r.get("Errors")
        if errs:
            raise RuntimeError(f"delete_objects errors: {errs[:3]}")


def purge_noncurrent(s3, bucket):
    versions, markers = list_versions(s3, bucket)
    latest_is_marker = {m["Key"] for m in markers if m.get("IsLatest")}
    doomed = []
    for v in versions:
        if not v.get("IsLatest") or v["Key"] in latest_is_marker:
            doomed.append(v)
    for m in markers:
        doomed.append(m)  # any delete marker: latest ones hide a key that is invalid anyway
    if doomed:
        log(f"purging {len(doomed)} noncurrent version(s)/delete marker(s)")
        delete_versions(s3, bucket, doomed)
    return len(doomed)


def purge_everything(s3, bucket):
    versions, markers = list_versions(s3, bucket)
    allv = versions + markers
    if allv:
        log(f"purging all {len(allv)} object version(s)/delete marker(s) from {bucket}")
        delete_versions(s3, bucket, allv)


def analyse_archive(conn, s3, bucket):
    """Return a list of problems; empty means the archive is 1-to-1 with clearledger.outbox."""
    problems = []
    with conn.cursor() as cur:
        cur.execute("SELECT seq, event_id::text, payload, published_at IS NOT NULL, archived_at IS NOT NULL "
                    "FROM clearledger.outbox ORDER BY seq")
        rows = {r[1]: r for r in cur.fetchall()}
    versions, markers = list_versions(s3, bucket)
    latest_marker_keys = {m["Key"] for m in markers if m.get("IsLatest")}
    current = [v for v in versions if v.get("IsLatest") and v["Key"] not in latest_marker_keys]
    seen = {}
    for obj in current:
        key = obj["Key"]
        m = KEY_RE.match(key)
        if not m:
            problems.append(f"non-canonical object key {key}")
            continue
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != m.group(3):
            problems.append(f"{key}: sha256 does not match key")
            continue
        lines = [ln for ln in body.split(b"\n") if ln.strip()]
        if not lines:
            problems.append(f"{key}: empty batch")
            continue
        prev = 0
        first = last = None
        for ln in lines:
            try:
                rec = json.loads(ln)
                row = rows.get(rec["eventId"])
            except Exception:  # noqa: BLE001
                problems.append(f"{key}: unparsable record")
                break
            if row is None:
                problems.append(f"{key}: record {rec.get('eventId')} not in outbox")
                continue
            seq = row[0]
            if seq <= prev:
                problems.append(f"{key}: records not strictly ascending by seq")
            prev = seq
            first = seq if first is None else first
            last = seq
            if rec != row[2]:
                problems.append(f"{key}: payload of seq {seq} diverges from outbox")
            if seq in seen:
                problems.append(f"seq {seq} archived more than once ({seen[seq]}, {key})")
            seen[seq] = key
        if first is not None and (first != int(m.group(1)) or last != int(m.group(2))):
            problems.append(f"{key}: key range {m.group(1)}-{m.group(2)} != records {first}-{last}")
    for ev, row in rows.items():
        if row[0] not in seen:
            problems.append(f"outbox seq {row[0]} missing from archive")
        if not row[4]:
            problems.append(f"outbox seq {row[0]} has archived_at IS NULL")
    return problems


def archive_pending(conn, deadline_s=200):
    fn = MAN["workers"]["audit_archiver"]["function_name"]
    t0 = time.time()
    stalls = 0
    while True:
        pending = q1(conn, "SELECT count(*) FROM clearledger.outbox "
                           "WHERE published_at IS NOT NULL AND archived_at IS NULL")
        if pending == 0:
            return
        if time.time() - t0 > deadline_s:
            raise RuntimeError(f"{pending} outbox rows could not be archived within {deadline_s}s")
        try:
            res = lambda_invoke(fn)
            log(f"archiver invoked: {res} (pending before: {pending})")
        except Exception as exc:  # noqa: BLE001
            log(f"archiver invocation failed: {exc}")
        after = q1(conn, "SELECT count(*) FROM clearledger.outbox "
                         "WHERE published_at IS NOT NULL AND archived_at IS NULL")
        if after >= pending:
            stalls += 1
            if stalls >= 6:
                raise RuntimeError("audit archiver makes no progress")
            time.sleep(2)
        else:
            stalls = 0


def reconcile_s3():
    conn = pg_connect()
    s3 = client("s3")
    bucket = MAN["audit"]["bucket_name"]
    for attempt in range(1, 6):
        archive_pending(conn)
        problems = analyse_archive(conn, s3, bucket)
        if not problems:
            purged = purge_noncurrent(s3, bucket)
            if purged == 0 and not q1(conn, "SELECT count(*) FROM clearledger.outbox "
                                            "WHERE published_at IS NOT NULL AND archived_at IS NULL"):
                log("S3 audit archive is 1-to-1 with clearledger.outbox")
                return
            continue
        for p in problems[:20]:
            log(f"archive problem: {p}")
        log(f"rebuilding the audit archive from PostgreSQL (attempt {attempt}, {len(problems)} problem(s))")
        purge_everything(s3, bucket)
        with conn.cursor() as cur:
            cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
            log(f"reset archived_at on {cur.rowcount} outbox row(s)")
    raise RuntimeError("S3 audit archive did not converge")


# --------------------------------------------------------------------------- main
def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "drain-outbox":
        drain_outbox()
    elif cmd == "wait-queue":
        wait_queue()
    elif cmd == "iam-sg":
        iam_sg_cleanup()
    elif cmd == "verify-control":
        sys.exit(verify_control())
    elif cmd == "dynamodb":
        reconcile_dynamodb()
    elif cmd == "valkey":
        reconcile_valkey()
    elif cmd == "s3":
        reconcile_s3()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
