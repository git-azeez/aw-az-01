"""Data-plane convergence for ClearLedger.

PostgreSQL (clearledger.settlements / events / outbox) is the system of record. This script makes the derived
stores agree 1-to-1 with it:

  1. unpublished outbox rows are published through the outbox_relay Lambda
  2. the DynamoDB projection table holds exactly STATE + EVENT#* items matching PostgreSQL
  3. Valkey holds only valid, fresh, matching cache entries
  4. the versioned S3 audit archive matches clearledger.outbox exactly once per row (through audit_archiver),
     with every noncurrent version and delete marker purged

Usage: reconcile.py [deadline_epoch_seconds]
"""
import hashlib
import json
import re
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal

import redis
from botocore.exceptions import ClientError

from common import Aws, load_config, load_manifest, log, pg_connect

CACHE_PREFIX = "clearledger:"
CACHE_KEY_PREFIX = "clearledger:settlement:"
KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")

ENVELOPE_ORDER = [
    "schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId", "aggregateVersion",
    "occurredAt", "correlationId", "idempotencyKey", "data",
]
DATA_ORDER = [
    "kind", "accountId", "reference", "debitParty", "creditParty", "entryId", "status", "clearingStage", "memo",
]


class Ctx:
    def __init__(self, deadline):
        self.cfg = load_config()
        self.manifest = load_manifest()
        self.aws = Aws(self.cfg)
        self.deadline = deadline
        db = self.manifest["database"]
        self.pg_host, self.pg_port = db["endpoint"], int(db["port"])
        self.queue_url = self.manifest["messaging"]["queue_url"]
        self.table = self.manifest["projections"]["table_name"]
        self.bucket = self.manifest["audit"]["bucket_name"]
        self.prefix = self.manifest["audit"]["prefix"]
        self.relay_fn = self.manifest["workers"]["outbox_relay"]["function_name"]
        self.archiver_fn = self.manifest["workers"]["audit_archiver"]["function_name"]
        self.valkey_host = self.manifest["cache"]["endpoint"]
        self.valkey_port = int(self.manifest["cache"]["port"])

    def remaining(self):
        return self.deadline - time.time()

    def pg(self, readonly=False, repeatable=False):
        conn = pg_connect(self.cfg, self.pg_host, self.pg_port)
        if repeatable:
            conn.set_session(isolation_level="REPEATABLE READ", readonly=readonly)
        return conn

    def scalar(self, sql):
        conn = self.pg()
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
                return cur.fetchone()[0]
        finally:
            conn.rollback()
            conn.close()


# ---------------------------------------------------------------------------
# Formatting helpers (mirror what the projector / API emit)
# ---------------------------------------------------------------------------
def rfc3339(dt):
    """chrono::DateTime::to_rfc3339 (AutoSi) for a UTC instant."""
    dt = dt.astimezone(timezone.utc)
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    micro = dt.microsecond
    if micro == 0:
        frac = ""
    elif micro % 1000 == 0:
        frac = f".{micro // 1000:03d}"
    else:
        frac = f".{micro:06d}"
    return f"{base}{frac}+00:00"


def parse_ts(value):
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc)
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(timezone.utc)


def ordered_envelope(payload):
    out = {}
    for k in ENVELOPE_ORDER:
        if k in payload:
            out[k] = payload[k]
    for k in payload:
        if k not in out:
            out[k] = payload[k]
    data = out.get("data")
    if isinstance(data, dict):
        d2 = {}
        for k in DATA_ORDER:
            if k in data:
                d2[k] = data[k]
        for k in data:
            if k not in d2:
                d2[k] = data[k]
        out["data"] = d2
    return out


def envelope_json(payload):
    return json.dumps(ordered_envelope(payload), separators=(",", ":"), ensure_ascii=False)


def S(v):
    return {"S": str(v)}


def N(v):
    return {"N": str(v)}


def norm_item(item):
    out = {}
    for k, v in item.items():
        if "N" in v:
            out[k] = ("N", Decimal(v["N"]))
        elif "S" in v:
            out[k] = ("S", v["S"])
        else:
            out[k] = tuple(sorted(v.items()))
    return out


# ---------------------------------------------------------------------------
# PostgreSQL snapshot
# ---------------------------------------------------------------------------
def snapshot(ctx):
    conn = ctx.pg(readonly=True, repeatable=True)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT settlement_id::text, account_id, reference, debit_party, credit_party, current_status,"
                " current_stage, last_entry_id::text, last_memo, version, entry_count, updated_at"
                " FROM clearledger.settlements"
            )
            settlements = {}
            for r in cur.fetchall():
                settlements[r[0]] = dict(
                    settlement_id=r[0], account_id=r[1], reference=r[2], debit_party=r[3], credit_party=r[4],
                    status=r[5], stage=r[6], last_entry_id=r[7], last_memo=r[8], version=r[9],
                    entry_count=r[10], updated_at=r[11],
                )
            cur.execute(
                "SELECT settlement_id::text, event_id::text, aggregate_version, event_type, correlation_id,"
                " occurred_at, payload FROM clearledger.events ORDER BY settlement_id, aggregate_version"
            )
            events = {}
            for r in cur.fetchall():
                events.setdefault(r[0], []).append(
                    dict(event_id=r[1], version=r[2], event_type=r[3], correlation_id=r[4], occurred_at=r[5], payload=r[6])
                )
        return settlements, events
    finally:
        conn.rollback()
        conn.close()


def expected_items(settlements, events):
    items = {}
    for sid, s in settlements.items():
        pk = f"SETTLEMENT#{sid}"
        state = {
            "PK": S(pk), "SK": S("STATE"),
            "GSI1PK": S(f"ACCOUNT#{s['account_id']}"), "GSI1SK": S(f"SETTLEMENT#{sid}"),
            "settlement_id": S(sid), "account_id": S(s["account_id"]), "reference": S(s["reference"]),
            "debit_party": S(s["debit_party"]), "credit_party": S(s["credit_party"]),
            "status": S(s["status"]), "clearing_stage": S(s["stage"]),
            "version": N(s["version"]), "entry_count": N(s["entry_count"]),
            "updated_at": S(rfc3339(s["updated_at"])),
        }
        if s["last_entry_id"]:
            state["last_entry_id"] = S(s["last_entry_id"])
        if s["last_memo"] is not None:
            state["last_memo"] = S(s["last_memo"])
        items[(pk, "STATE")] = state
        for e in events.get(sid, []):
            data = e["payload"].get("data", {})
            sk = f"EVENT#{e['version']:08d}"
            item = {
                "PK": S(pk), "SK": S(sk), "settlement_id": S(sid), "event_id": S(e["event_id"]),
                "version": N(e["version"]), "event_type": S(e["event_type"]),
                "status": S(data.get("status")), "clearing_stage": S(data.get("clearingStage")),
                "occurred_at": S(rfc3339(e["occurred_at"])), "correlation_id": S(e["correlation_id"]),
                "envelope": S(envelope_json(e["payload"])),
            }
            if data.get("entryId"):
                item["entry_id"] = S(data["entryId"])
            if data.get("memo") is not None:
                item["memo"] = S(data["memo"])
            items[(pk, sk)] = item
    return items


def projection_json(s):
    return {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["status"],
        "clearingStage": s["stage"], "lastEntryId": s["last_entry_id"], "lastMemo": s["last_memo"],
        "version": s["version"], "entryCount": s["entry_count"], "updatedAt": s["updated_at"],
    }


# ---------------------------------------------------------------------------
# 1. outbox relay + queue
# ---------------------------------------------------------------------------
def invoke(ctx, fn):
    lam = ctx.aws.client("lambda", read_timeout=300)
    resp = lam.invoke(FunctionName=fn, InvocationType="RequestResponse", Payload=b"{}")
    body = resp["Payload"].read().decode("utf-8", "replace")
    if resp.get("FunctionError"):
        log(f"lambda {fn}: FunctionError {resp['FunctionError']}: {body[:300]}")
        return None
    try:
        return json.loads(body)
    except ValueError:
        return {}


def drain_outbox(ctx):
    sql = "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL"
    pending = ctx.scalar(sql)
    attempts = 0
    stalled = 0
    while pending > 0:
        if ctx.remaining() < 60:
            raise RuntimeError(f"out of time with {pending} unpublished outbox rows")
        attempts += 1
        log(f"relay: {pending} unpublished outbox row(s); invoking {ctx.relay_fn} (attempt {attempts})")
        result = invoke(ctx, ctx.relay_fn)
        new_pending = ctx.scalar(sql)
        if new_pending >= pending:
            stalled += 1
            if stalled >= 5:
                raise RuntimeError(f"outbox relay is not draining ({new_pending} rows left, last result {result})")
            time.sleep(3)
        else:
            stalled = 0
        pending = new_pending
    return attempts


def queue_depth(ctx):
    sqs = ctx.aws.client("sqs")
    attrs = sqs.get_queue_attributes(
        QueueUrl=ctx.queue_url,
        AttributeNames=[
            "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
            "ApproximateNumberOfMessagesDelayed",
        ],
    )["Attributes"]
    return sum(int(v) for v in attrs.values())


def wait_queue_idle(ctx, timeout=60):
    end = min(time.time() + timeout, ctx.deadline - 150)
    quiet = 0
    depth = -1
    while time.time() < end:
        try:
            depth = queue_depth(ctx)
        except ClientError as exc:
            log(f"queue: attributes unavailable ({exc.response['Error']['Code']})")
            return False
        if depth == 0:
            quiet += 1
            if quiet >= 2:
                return True
        else:
            quiet = 0
        time.sleep(2)
    log(f"queue: still {depth} message(s) in flight after {timeout}s; continuing")
    return False


# ---------------------------------------------------------------------------
# 2. DynamoDB
# ---------------------------------------------------------------------------
def scan_table(ctx):
    ddb = ctx.aws.client("dynamodb")
    items = {}
    for page in ddb.get_paginator("scan").paginate(TableName=ctx.table, ConsistentRead=True):
        for it in page["Items"]:
            items[(it.get("PK", {}).get("S"), it.get("SK", {}).get("S"))] = it
    return items


def reconcile_dynamodb(ctx):
    ddb = ctx.aws.client("dynamodb")
    # Scan first, snapshot PostgreSQL second: a settlement created in between is then only ever "missing"
    # (and written), never mistaken for an orphan.
    actual = scan_table(ctx)
    settlements, events = snapshot(ctx)
    expected = expected_items(settlements, events)

    deletes = [k for k in actual if k not in expected]
    puts = []
    for k, item in expected.items():
        cur = actual.get(k)
        if cur is None or norm_item(cur) != norm_item(item):
            puts.append(k)

    for (pk, sk) in deletes:
        if pk is None or sk is None:
            log(f"dynamodb: item with malformed key skipped: {pk!r}/{sk!r}")
            continue
        ddb.delete_item(TableName=ctx.table, Key={"PK": S(pk), "SK": S(sk)})
    for k in puts:
        item = expected[k]
        kwargs = {}
        if k[1] == "STATE":
            kwargs = dict(
                ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                ExpressionAttributeNames={"#v": "version"},
                ExpressionAttributeValues={":v": item["version"]},
            )
        try:
            ddb.put_item(TableName=ctx.table, Item=item, **kwargs)
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
    if deletes or puts:
        log(f"dynamodb: removed {len(deletes)} stray item(s), wrote {len(puts)} missing/divergent item(s)")
    return len(deletes) + len(puts)


# ---------------------------------------------------------------------------
# 3. Valkey
# ---------------------------------------------------------------------------
def cache_matches(payload_text, s):
    try:
        cached = json.loads(payload_text)
    except (TypeError, ValueError):
        return False
    if not isinstance(cached, dict):
        return False
    want = projection_json(s)
    for key, val in want.items():
        got = cached.get(key)
        if key == "updatedAt":
            try:
                if parse_ts(got) != val.astimezone(timezone.utc):
                    return False
            except (TypeError, ValueError):
                return False
        elif got != val:
            return False
    return True


def reconcile_valkey(ctx):
    client = redis.Redis(
        host=ctx.valkey_host, port=ctx.valkey_port, decode_responses=True, socket_timeout=10, socket_connect_timeout=10
    )
    settlements, _ = snapshot(ctx)
    removed = 0
    for key in list(client.scan_iter(match=CACHE_PREFIX + "*", count=500)):
        keep = False
        if key.startswith(CACHE_KEY_PREFIX):
            sid = key[len(CACHE_KEY_PREFIX):]
            s = settlements.get(sid)
            if s is not None:
                try:
                    ttl = client.ttl(key)
                    value = client.get(key) if client.type(key) == "string" else None
                    keep = value is not None and 0 < ttl <= 90 and cache_matches(value, s)
                except redis.RedisError:
                    keep = False
        if not keep:
            client.delete(key)
            removed += 1
    if removed:
        log(f"valkey: removed {removed} orphan/stale/invalid cache key(s)")
    return removed


# ---------------------------------------------------------------------------
# 4. S3 audit archive
# ---------------------------------------------------------------------------
def list_all_versions(ctx):
    s3 = ctx.aws.client("s3")
    versions, markers = [], []
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=ctx.bucket):
        versions += page.get("Versions", [])
        markers += page.get("DeleteMarkers", [])
    return versions, markers


def outbox_rows(ctx):
    conn = ctx.pg(readonly=True, repeatable=True)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT seq, event_id::text, payload, published_at IS NOT NULL, archived_at IS NOT NULL"
                " FROM clearledger.outbox ORDER BY seq"
            )
            return {r[0]: dict(seq=r[0], event_id=r[1], payload=r[2], published=r[3], archived=r[4]) for r in cur.fetchall()}
    finally:
        conn.rollback()
        conn.close()


def delete_key_history(ctx, key, versions, markers):
    s3 = ctx.aws.client("s3")
    for v in versions:
        if v["Key"] == key:
            s3.delete_object(Bucket=ctx.bucket, Key=key, VersionId=v["VersionId"])
    for m in markers:
        if m["Key"] == key:
            s3.delete_object(Bucket=ctx.bucket, Key=key, VersionId=m["VersionId"])


def inspect_object(ctx, ver, rows_by_event):
    """Returns (seqs, error). seqs is the ordered list of outbox seqs covered when the object is canonical."""
    key = ver["Key"]
    m = KEY_RE.match(key)
    if not m:
        return None, "non-canonical key"
    s3 = ctx.aws.client("s3")
    try:
        body = s3.get_object(Bucket=ctx.bucket, Key=key, VersionId=ver["VersionId"])["Body"].read()
    except ClientError as exc:
        return None, f"unreadable ({exc.response['Error']['Code']})"
    if hashlib.sha256(body).hexdigest()[:16] != m.group(3):
        return None, "digest mismatch"
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        return None, "not utf-8"
    lines = [ln for ln in text.split("\n") if ln != ""]
    if not lines:
        return None, "empty batch"
    seqs = []
    for ln in lines:
        try:
            doc = json.loads(ln)
        except ValueError:
            return None, "invalid json line"
        if not isinstance(doc, dict):
            return None, "line is not an object"
        row = rows_by_event.get(str(doc.get("eventId")).lower())
        if row is None:
            return None, "line does not match any outbox row"
        if doc != row["payload"]:
            return None, "line payload differs from outbox payload"
        seqs.append(row["seq"])
    if any(b <= a for a, b in zip(seqs, seqs[1:])):
        return None, "records not in strictly ascending seq order"
    if seqs[0] != int(m.group(1)) or seqs[-1] != int(m.group(2)):
        return None, "key sequence range does not match content"
    return seqs, None


def archive_pending(ctx):
    sql = "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL"
    pending = ctx.scalar(sql)
    stalled = 0
    runs = 0
    while pending > 0:
        if ctx.remaining() < 45:
            raise RuntimeError(f"out of time with {pending} unarchived outbox rows")
        runs += 1
        log(f"archiver: {pending} unarchived outbox row(s); invoking {ctx.archiver_fn} (run {runs})")
        result = invoke(ctx, ctx.archiver_fn)
        new_pending = ctx.scalar(sql)
        if new_pending >= pending:
            stalled += 1
            if stalled >= 4:
                raise RuntimeError(f"audit archiver is not draining ({new_pending} rows left, last result {result})")
            time.sleep(3)
        else:
            stalled = 0
        pending = new_pending
    return runs


def s3_plan(ctx):
    """Classify the bucket. Returns dict describing what must change; empty plan == converged."""
    rows = outbox_rows(ctx)
    rows_by_event = {r["event_id"].lower(): r for r in rows.values()}
    versions, markers = list_all_versions(ctx)

    latest_versions = {v["Key"]: v for v in versions if v["IsLatest"]}
    latest_markers = {m["Key"] for m in markers if m["IsLatest"]}
    all_keys = {v["Key"] for v in versions} | {m["Key"] for m in markers}

    purge_keys = set()   # delete the whole history of these keys
    for key in all_keys:
        if not key.startswith(ctx.prefix) or not KEY_RE.match(key):
            purge_keys.add(key)               # outside ledger-audit/ or not a canonical batch key
        elif key in latest_markers or key not in latest_versions:
            purge_keys.add(key)               # deleted out-of-band: the history must not resurrect

    coverage = {}   # seq -> [keys]
    obj_seqs = {}
    for key, ver in latest_versions.items():
        if key in purge_keys:
            continue
        seqs, err = inspect_object(ctx, ver, rows_by_event)
        if err:
            log(f"s3: {key}: {err}")
            purge_keys.add(key)
            continue
        obj_seqs[key] = seqs
        for sq in seqs:
            coverage.setdefault(sq, []).append(key)

    for sq, keys in coverage.items():
        if len(keys) > 1:
            purge_keys.update(keys)                      # duplicated records
        elif not rows[sq]["archived"]:
            purge_keys.update(keys)                      # archived in S3 but PostgreSQL says otherwise
    surviving = {k for k in obj_seqs if k not in purge_keys}
    covered = {sq for k in surviving for sq in obj_seqs[k]}
    reset_rows = sorted(sq for sq, r in rows.items() if r["archived"] and sq not in covered)
    noncurrent = [v for v in versions if not v["IsLatest"] and v["Key"] in surviving]
    stale_markers = [m for m in markers if m["Key"] in surviving]
    return dict(
        purge_keys=sorted(purge_keys), reset_rows=reset_rows, noncurrent=noncurrent, markers=stale_markers,
        versions=versions, all_markers=markers,
        unarchived=sorted(sq for sq, r in rows.items() if not r["archived"]),
    )


def reconcile_s3(ctx):
    s3 = ctx.aws.client("s3")
    changed = 0
    plan = s3_plan(ctx)
    for key in plan["purge_keys"]:
        log(f"s3: purging invalid/non-canonical/duplicate key {key}")
        delete_key_history(ctx, key, plan["versions"], plan["all_markers"])
        changed += 1
    if plan["reset_rows"]:
        log(f"s3: re-queueing {len(plan['reset_rows'])} outbox row(s) for archival")
        conn = ctx.pg()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE clearledger.outbox SET archived_at = NULL"
                    " WHERE seq = ANY(%s) AND archived_at IS NOT NULL", (plan["reset_rows"],),
                )
            conn.commit()
        finally:
            conn.close()
        changed += len(plan["reset_rows"])
    if plan["unarchived"] or plan["reset_rows"]:
        archive_pending(ctx)
        changed += 1
    # Purge noncurrent versions and delete markers (recomputed: the archiver may have overwritten keys).
    plan = s3_plan(ctx)
    for key in plan["purge_keys"]:
        delete_key_history(ctx, key, plan["versions"], plan["all_markers"])
        changed += 1
    for v in plan["noncurrent"]:
        s3.delete_object(Bucket=ctx.bucket, Key=v["Key"], VersionId=v["VersionId"])
        changed += 1
    for m in plan["markers"]:
        s3.delete_object(Bucket=ctx.bucket, Key=m["Key"], VersionId=m["VersionId"])
        changed += 1
    if plan["noncurrent"] or plan["markers"]:
        log(f"s3: purged {len(plan['noncurrent'])} noncurrent version(s) and {len(plan['markers'])} delete marker(s)")
    return changed


def s3_converged(ctx):
    plan = s3_plan(ctx)
    return not (plan["purge_keys"] or plan["reset_rows"] or plan["noncurrent"] or plan["markers"] or plan["unarchived"])


# ---------------------------------------------------------------------------
def main():
    deadline = float(sys.argv[1]) if len(sys.argv) > 1 else time.time() + 400
    ctx = Ctx(deadline)

    # A round that performs no repair at all proves convergence; repairs trigger another verification round
    # (live traffic or the scheduled workers may have moved the system in the meantime).
    for rnd in range(1, 7):
        log(f"reconcile: round {rnd}")
        drain_outbox(ctx)
        wait_queue_idle(ctx)
        changed = reconcile_dynamodb(ctx) + reconcile_valkey(ctx)
        drain_outbox(ctx)       # rows committed while we worked must also be relayed before archiving
        changed += reconcile_s3(ctx)
        if changed == 0:
            log("reconcile: PostgreSQL, DynamoDB, Valkey and S3 are converged")
            return 0
        if ctx.remaining() < 75:
            break
    log("reconcile: could not reach a stable converged state before the deadline")
    return 1


if __name__ == "__main__":
    sys.exit(main())
