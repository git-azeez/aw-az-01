#!/usr/bin/env python3
"""Converge every derived data store against PostgreSQL (the system of record).

  1. outbox      -> every committed event is published to SQS (relay Lambda,
                    with an in-process fallback)
  2. DynamoDB    -> exactly one STATE item and one EVENT#<v> item per committed
                    event of every settlement, nothing else
  3. S3 audit    -> every outbox row appears exactly once in a canonical,
                    gap-free, non-overlapping ledger-audit/ batch; noncurrent
                    versions, delete markers and foreign objects are purged
  4. Valkey      -> only clearledger:settlement:<id> keys for known settlements,
                    each populated through the API's own cache-aside path

The passes are repeated until a verification round finds nothing to repair, so
the result also holds when writes land while the script runs.
"""
import concurrent.futures as cf
import hashlib
import json
import re
import sys
import time

import psycopg2.extras
import redis
import requests
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.exceptions import ClientError

from common import (canonical_json, client, db_connect, load_json, log,
                    parse_ts, rfc3339_auto)

BATCH_SIZE = 100
KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")
SER = TypeSerializer()
DES = TypeDeserializer()


class Ctx:
    def __init__(self, cfg, mf):
        self.cfg = cfg
        self.mf = mf
        self.sqs = client(cfg, "sqs")
        self.ddb = client(cfg, "dynamodb")
        self.s3 = client(cfg, "s3")
        self.lam = client(cfg, "lambda")
        self.table = mf["projections"]["table_name"]
        self.bucket = mf["audit"]["bucket_name"]
        self.queue_url = mf["messaging"]["queue_url"]

    def pg(self):
        conn = db_connect(self.cfg, self.mf)
        conn.autocommit = True
        return conn


# --------------------------------------------------------------------------
# 1. Outbox relay
# --------------------------------------------------------------------------

def unpublished(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        return cur.fetchone()[0]


def converge_outbox(ctx):
    conn = ctx.pg()
    try:
        for attempt in range(8):
            pending = unpublished(conn)
            if pending == 0:
                return
            log(f"outbox: {pending} unpublished rows, invoking relay (attempt {attempt + 1})")
            try:
                ctx.lam.invoke(FunctionName=ctx.mf["workers"]["outbox_relay"]["function_name"], Payload=b"{}")
            except Exception as exc:  # noqa: BLE001
                log(f"outbox: relay invocation failed: {exc}")
            time.sleep(1)

        # Fallback: publish whatever the relay could not.
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq")
            rows = cur.fetchall()
        for row in rows:
            ctx.sqs.send_message(QueueUrl=ctx.queue_url, MessageBody=canonical_json(row["payload"]))
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL "
                    "WHERE seq = %s AND published_at IS NULL", (row["seq"],))
        log(f"outbox: published {len(rows)} rows through the fallback publisher")
    finally:
        conn.close()


def wait_queue_drained(ctx, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            attrs = ctx.sqs.get_queue_attributes(
                QueueUrl=ctx.queue_url,
                AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
            )["Attributes"]
        except ClientError:
            return
        if int(attrs.get("ApproximateNumberOfMessages", 0)) + int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)) == 0:
            return
        time.sleep(1)


# --------------------------------------------------------------------------
# 2. DynamoDB projections
# --------------------------------------------------------------------------

def load_pg_model(conn):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM clearledger.settlements ORDER BY settlement_id")
        settlements = cur.fetchall()
        cur.execute("SELECT * FROM clearledger.events ORDER BY settlement_id, aggregate_version")
        events = cur.fetchall()
    by_s = {}
    for ev in events:
        by_s.setdefault(str(ev["settlement_id"]), []).append(ev)
    return settlements, by_s


def expected_items(settlements, events_by_settlement):
    """(PK, SK) -> {attribute: python value} exactly as the projector writes them."""
    items = {}
    for s in settlements:
        sid = str(s["settlement_id"])
        pk = f"SETTLEMENT#{sid}"
        state = {
            "PK": pk, "SK": "STATE",
            "GSI1PK": f"ACCOUNT#{s['account_id']}", "GSI1SK": f"SETTLEMENT#{sid}",
            "settlement_id": sid, "account_id": s["account_id"], "reference": s["reference"],
            "debit_party": s["debit_party"], "credit_party": s["credit_party"],
            "status": s["current_status"], "clearing_stage": s["current_stage"],
            "version": int(s["version"]), "entry_count": int(s["entry_count"]),
            "updated_at": rfc3339_auto(s["updated_at"]),
            "last_memo": s["last_memo"],
        }
        if s["last_entry_id"] is not None:
            state["last_entry_id"] = str(s["last_entry_id"])
        items[(pk, "STATE")] = state
        for ev in events_by_settlement.get(sid, []):
            data = ev["payload"].get("data", {})
            sk = "EVENT#%08d" % ev["aggregate_version"]
            item = {
                "PK": pk, "SK": sk, "settlement_id": sid, "event_id": str(ev["event_id"]),
                "version": int(ev["aggregate_version"]), "event_type": ev["event_type"],
                "status": data.get("status"), "clearing_stage": data.get("clearingStage"),
                "occurred_at": rfc3339_auto(ev["occurred_at"]),
                "correlation_id": ev["correlation_id"],
                "envelope": canonical_json(ev["payload"]),
            }
            if data.get("entryId") is not None:
                item["entry_id"] = data["entryId"]
            if data.get("memo") is not None:
                item["memo"] = data["memo"]
            items[(pk, sk)] = item
    return items


TIMESTAMP_ATTRS = {"updated_at", "occurred_at"}


def same_item(actual, expected):
    if set(actual) != set(expected):
        return False
    for key, want in expected.items():
        have = actual[key]
        if key in TIMESTAMP_ATTRS:
            try:
                if parse_ts(have) != parse_ts(want):
                    return False
            except (ValueError, TypeError):
                return False
        elif key == "envelope":
            try:
                if json.loads(have) != json.loads(want):
                    return False
            except (ValueError, TypeError):
                return False
        elif key in ("version", "entry_count"):
            if int(have) != int(want):
                return False
        elif have != want:
            return False
    return True


def scan_table(ctx):
    items = {}
    kwargs = {"TableName": ctx.table, "ConsistentRead": True}
    while True:
        page = ctx.ddb.scan(**kwargs)
        for raw in page["Items"]:
            item = {k: DES.deserialize(v) for k, v in raw.items()}
            for k, v in list(item.items()):
                if hasattr(v, "as_tuple"):
                    item[k] = int(v)
            items[(item.get("PK"), item.get("SK"))] = item
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def batch_write(ctx, requests_):
    for i in range(0, len(requests_), 25):
        chunk = requests_[i:i + 25]
        for _ in range(10):
            resp = ctx.ddb.batch_write_item(RequestItems={ctx.table: chunk})
            chunk = resp.get("UnprocessedItems", {}).get(ctx.table, [])
            if not chunk:
                break
            time.sleep(0.5)


def converge_dynamodb(ctx, conn):
    settlements, events_by_s = load_pg_model(conn)
    want = expected_items(settlements, events_by_s)
    have = scan_table(ctx)

    puts_events, puts_state, deletes = [], [], []
    for key, exp in want.items():
        act = have.get(key)
        if act is None or not same_item(act, exp):
            req = {"PutRequest": {"Item": {k: SER.serialize(v) for k, v in exp.items()}}}
            (puts_state if key[1] == "STATE" else puts_events).append(req)
    for key in have:
        if key not in want:
            deletes.append({"DeleteRequest": {"Key": {"PK": {"S": key[0] or ""}, "SK": {"S": key[1] or ""}}}})

    # Events first so STATE never points past the ledger; strays last.
    batch_write(ctx, puts_events)
    batch_write(ctx, puts_state)
    batch_write(ctx, [d for d in deletes if d["DeleteRequest"]["Key"]["PK"]["S"] and d["DeleteRequest"]["Key"]["SK"]["S"]])
    changed = len(puts_events) + len(puts_state) + len(deletes)
    if changed:
        log(f"dynamodb: repaired {len(puts_events)} event items, {len(puts_state)} state items, removed {len(deletes)} stray items")
    return changed


# --------------------------------------------------------------------------
# 3. S3 audit archive
# --------------------------------------------------------------------------

def list_versions(ctx):
    versions, markers = [], []
    kwargs = {"Bucket": ctx.bucket}
    while True:
        page = ctx.s3.list_object_versions(**kwargs)
        versions += page.get("Versions", [])
        markers += page.get("DeleteMarkers", [])
        if not page.get("IsTruncated"):
            return versions, markers
        kwargs["KeyMarker"] = page.get("NextKeyMarker")
        if page.get("NextVersionIdMarker"):
            kwargs["VersionIdMarker"] = page["NextVersionIdMarker"]


def delete_versions(ctx, targets):
    """targets: iterable of (key, version_id)"""
    targets = list(targets)
    for i in range(0, len(targets), 500):
        chunk = targets[i:i + 500]
        ctx.s3.delete_objects(
            Bucket=ctx.bucket,
            Delete={"Objects": [{"Key": k, "VersionId": v} for k, v in chunk], "Quiet": True},
        )


def batch_bytes(rows):
    return "".join(canonical_json(r["payload"]) + "\n" for r in rows).encode("utf-8")


def batch_key(rows, body):
    return "ledger-audit/batch-%08d-%08d-%s.ndjson" % (
        rows[0]["seq"], rows[-1]["seq"], hashlib.sha256(body).hexdigest()[:16])


def converge_s3(ctx, conn):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT seq, payload, published_at, archived_at FROM clearledger.outbox ORDER BY seq")
        rows = cur.fetchall()
    seqs = [r["seq"] for r in rows]

    versions, markers = list_versions(ctx)
    latest = {v["Key"]: v for v in versions if v["IsLatest"]}
    changed = 0

    # --- which existing batches are valid -------------------------------
    candidates = []
    for key, ver in latest.items():
        m = KEY_RE.match(key)
        if not m:
            continue
        first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
        try:
            body = ctx.s3.get_object(Bucket=ctx.bucket, Key=key, VersionId=ver["VersionId"])["Body"].read()
        except ClientError:
            continue
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            continue
        span = [r for r in rows if first <= r["seq"] <= last]
        if not span or span[0]["seq"] != first or span[-1]["seq"] != last:
            continue
        if any(r["published_at"] is None for r in span):
            continue
        if body != batch_bytes(span):
            continue
        candidates.append((first, last, key))

    kept, covered_until = [], 0
    for first, last, key in sorted(candidates):
        if first > covered_until:
            kept.append((first, last, key))
            covered_until = last
    covered = set()
    for first, last, _ in kept:
        covered.update(s for s in seqs if first <= s <= last)

    # --- archive everything that is not covered yet -----------------------
    runs, run = [], []
    for r in rows:
        if r["seq"] in covered or r["published_at"] is None:
            if run:
                runs.append(run)
                run = []
        else:
            run.append(r)
    if run:
        runs.append(run)

    final_keys = {key for _, _, key in kept}
    new_seqs = []
    for run in runs:
        for i in range(0, len(run), BATCH_SIZE):
            chunk = run[i:i + BATCH_SIZE]
            body = batch_bytes(chunk)
            key = batch_key(chunk, body)
            ctx.s3.put_object(Bucket=ctx.bucket, Key=key, Body=body, ContentType="application/x-ndjson")
            final_keys.add(key)
            new_seqs += [r["seq"] for r in chunk]
            changed += 1
            log(f"s3: wrote {key} ({len(chunk)} events)")

    # --- archived_at bookkeeping -----------------------------------------
    new_set = set(new_seqs)
    with conn.cursor() as cur:
        for r in rows:
            seq = r["seq"]
            is_covered = seq in covered or seq in new_set
            if is_covered and r["archived_at"] is None and r["published_at"] is not None:
                cur.execute("UPDATE clearledger.outbox SET archived_at = NOW() WHERE seq = %s AND archived_at IS NULL", (seq,))
                changed += 1
            elif seq in new_set and r["archived_at"] is not None:
                # restamp rows that had been marked archived without a backing batch
                cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE seq = %s AND archived_at IS NOT NULL", (seq,))
                cur.execute("UPDATE clearledger.outbox SET archived_at = NOW() WHERE seq = %s AND archived_at IS NULL", (seq,))
                changed += 1
            elif not is_covered and r["archived_at"] is not None:
                cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE seq = %s AND archived_at IS NOT NULL", (seq,))
                changed += 1

    # --- purge everything that is not the current version of a valid batch -
    versions, markers = list_versions(ctx)
    doomed = []
    for v in versions:
        if not (v["Key"] in final_keys and v["IsLatest"]):
            doomed.append((v["Key"], v["VersionId"]))
    for m in markers:
        doomed.append((m["Key"], m["VersionId"]))
    if doomed:
        delete_versions(ctx, doomed)
        changed += len(doomed)
        log(f"s3: purged {len(doomed)} noncurrent / invalid / foreign object versions")
    return changed


# --------------------------------------------------------------------------
# 4. Valkey cache
# --------------------------------------------------------------------------

def read_token(cfg, mf):
    read = mf["auth"]["clients"]["read"]
    resp = requests.post(
        mf["auth"]["token_endpoint"],
        auth=(read["client_id"], read["client_secret"]),
        data={"grant_type": "client_credentials", "scope": read["scope"]},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def cache_key(sid):
    return f"clearledger:settlement:{sid}"


def converge_valkey(ctx, conn):
    mf = ctx.mf
    r = redis.Redis(host=mf["cache"]["endpoint"], port=mf["cache"]["port"], socket_timeout=10, decode_responses=True)
    with conn.cursor() as cur:
        cur.execute("SELECT settlement_id FROM clearledger.settlements ORDER BY settlement_id")
        sids = [str(row[0]) for row in cur.fetchall()]
    wanted = {cache_key(s) for s in sids}

    # Purge every key; the cache is rebuilt below from the converged projection.
    keys = list(r.scan_iter(count=500))
    if keys:
        r.delete(*keys)
    log(f"valkey: purged {len(keys)} keys")

    token = read_token(ctx.cfg, mf)
    base = mf["service_url"].rstrip("/")
    headers = {"Authorization": f"Bearer {token}", "X-Correlation-Id": "deploy-cache-warm"}

    def warm(sid):
        for _ in range(3):
            try:
                resp = requests.get(f"{base}/v1/settlements/{sid}", headers=headers, timeout=15)
            except requests.RequestException:
                time.sleep(1)
                continue
            if resp.status_code == 200:
                return True
            if resp.status_code == 404:
                return False
            time.sleep(1)
        return False

    with cf.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(warm, sids))

    ok = 0
    for sid, warmed in zip(sids, results):
        ttl = r.ttl(cache_key(sid))
        if warmed and r.exists(cache_key(sid)) and 0 < ttl <= 90:
            ok += 1
    stray = [k for k in r.scan_iter(count=500) if k not in wanted]
    if stray:
        r.delete(*stray)
    log(f"valkey: {ok}/{len(sids)} settlements cached, removed {len(stray)} stray keys")
    return len(sids) - ok


# --------------------------------------------------------------------------

def main():
    cfg = load_json(sys.argv[1])
    mf = load_json(sys.argv[2])
    ctx = Ctx(cfg, mf)
    conn = ctx.pg()

    converge_outbox(ctx)
    wait_queue_drained(ctx)

    clean = False
    for round_no in range(1, 6):
        changed = converge_dynamodb(ctx, conn) + converge_s3(ctx, conn)
        if unpublished(conn):
            converge_outbox(ctx)
            changed += 1
        log(f"data plane round {round_no}: {changed} repairs")
        if changed == 0:
            clean = True
            break
    if not clean:
        log("ERROR: data plane did not converge")
        sys.exit(1)

    # The cache goes last: entries expire after 90 seconds, so populate it right
    # before handing control back.
    missing = converge_valkey(ctx, conn)
    for _ in range(2):
        if missing == 0:
            break
        time.sleep(2)
        missing = converge_valkey(ctx, conn)
    if missing:
        log(f"ERROR: {missing} settlements could not be cached")
        sys.exit(1)
    log("data plane converged")


if __name__ == "__main__":
    main()
