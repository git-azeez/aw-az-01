#!/usr/bin/env python3
"""ClearLedger convergence tool used by deploy.sh.

  reconcile.py control-plane   remove out-of-band IAM policies, repair security
                               group rules and KMS key state that Terraform does
                               not own or cannot see
  reconcile.py data-plane      converge outbox -> SQS, the S3 audit archive,
                               DynamoDB projections and the Valkey cache against
                               PostgreSQL (the system of record)

Inputs: /workspace/config/config.json and /workspace/submission/manifest.json.
"""
import datetime
import hashlib
import json
import math
import os
import re
import sys
import time

import boto3
import psycopg2
import redis
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_PATH = os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json")
MANIFEST_PATH = os.environ.get("CLEARLEDGER_MANIFEST", "/workspace/submission/manifest.json")

CFG = json.load(open(CONFIG_PATH))
MAN = json.load(open(MANIFEST_PATH))
PREFIX = CFG["resource_prefix"]
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]
AUDIT_PREFIX = MAN["audit"]["prefix"]
BUCKET = MAN["audit"]["bucket_name"]
TABLE = MAN["projections"]["table_name"]
CACHE_TTL = 90
ARCHIVE_BATCH = 100


def log(msg):
    print(f"[reconcile {datetime.datetime.utcnow().strftime('%H:%M:%S')}] {msg}", flush=True)


def client(service):
    return boto3.client(
        service,
        region_name=REGION,
        endpoint_url=ENDPOINT,
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 5, "mode": "standard"}, connect_timeout=10, read_timeout=60),
    )


def pg_connect(retries=30):
    last = None
    for _ in range(retries):
        try:
            conn = psycopg2.connect(
                host=MAN["database"]["endpoint"],
                port=MAN["database"]["port"],
                dbname=CFG["db_name"],
                user=CFG["db_username"],
                password=CFG["db_password"],
                connect_timeout=10,
            )
            conn.autocommit = True
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    raise RuntimeError(f"cannot connect to PostgreSQL: {last}")


# --------------------------------------------------------------------------
# Canonical serialisations (mirror what the ClearLedger workers emit)
# --------------------------------------------------------------------------
ENVELOPE_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
                  "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId",
              "status", "clearingStage", "memo"]


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def canonical_envelope(payload):
    out = {k: payload[k] for k in ENVELOPE_ORDER if k in payload}
    data = payload.get("data") or {}
    out["data"] = {k: data[k] for k in DATA_ORDER if data.get(k) is not None}
    return dumps(out)


def fmt_time(dt, zulu):
    """chrono AutoSi formatting: no fraction, 3 or 6 digits."""
    dt = dt.astimezone(datetime.timezone.utc)
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    us = dt.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return base + frac + ("Z" if zulu else "+00:00")


def S(v):
    return {"S": str(v)}


def N(v):
    return {"N": str(int(v))}


def event_item(ev):
    p = ev["payload"]
    d = p.get("data") or {}
    pk = f"SETTLEMENT#{ev['settlement_id']}"
    item = {
        "PK": S(pk),
        "SK": S("EVENT#%08d" % ev["aggregate_version"]),
        "settlement_id": S(ev["settlement_id"]),
        "event_id": S(ev["event_id"]),
        "version": N(ev["aggregate_version"]),
        "event_type": S(ev["event_type"]),
        "status": S(d["status"]),
        "clearing_stage": S(d["clearingStage"]),
        "occurred_at": S(fmt_time(ev["occurred_at"], False)),
        "correlation_id": S(ev["correlation_id"]),
        "envelope": S(canonical_envelope(p)),
    }
    if d.get("entryId") is not None:
        item["entry_id"] = S(d["entryId"])
    if d.get("memo") is not None:
        item["memo"] = S(d["memo"])
    return item


def state_item(s):
    sid = str(s["settlement_id"])
    item = {
        "PK": S(f"SETTLEMENT#{sid}"),
        "SK": S("STATE"),
        "GSI1PK": S(f"ACCOUNT#{s['account_id']}"),
        "GSI1SK": S(f"SETTLEMENT#{sid}"),
        "settlement_id": S(sid),
        "account_id": S(s["account_id"]),
        "reference": S(s["reference"]),
        "debit_party": S(s["debit_party"]),
        "credit_party": S(s["credit_party"]),
        "status": S(s["current_status"]),
        "clearing_stage": S(s["current_stage"]),
        "version": N(s["version"]),
        "entry_count": N(s["entry_count"]),
        "updated_at": S(fmt_time(s["updated_at"], False)),
        "last_memo": S(s["last_memo"]),
    }
    if s["last_entry_id"] is not None:
        item["last_entry_id"] = S(s["last_entry_id"])
    return item


def cache_key(sid):
    return f"clearledger:settlement:{sid}"


def cache_value(s):
    out = {
        "settlementId": str(s["settlement_id"]),
        "accountId": s["account_id"],
        "reference": s["reference"],
        "debitParty": s["debit_party"],
        "creditParty": s["credit_party"],
        "status": s["current_status"],
        "clearingStage": s["current_stage"],
    }
    if s["last_entry_id"] is not None:
        out["lastEntryId"] = str(s["last_entry_id"])
    out["lastMemo"] = s["last_memo"]
    out["version"] = s["version"]
    out["entryCount"] = s["entry_count"]
    out["updatedAt"] = fmt_time(s["updated_at"], True)
    return dumps(out)


# --------------------------------------------------------------------------
# PostgreSQL snapshot helpers
# --------------------------------------------------------------------------
def dict_rows(cur):
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def load_snapshot(conn):
    """Consistent snapshot of the authoritative tables."""
    conn.autocommit = False
    try:
        cur = conn.cursor()
        cur.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        cur.execute("SELECT settlement_id::text AS settlement_id, account_id, reference, debit_party, credit_party, "
                    "current_status, current_stage, last_entry_id::text AS last_entry_id, last_memo, version, "
                    "entry_count, updated_at FROM clearledger.settlements ORDER BY settlement_id")
        settlements = dict_rows(cur)
        cur.execute("SELECT event_id::text AS event_id, settlement_id::text AS settlement_id, aggregate_version, "
                    "event_type, correlation_id, occurred_at, payload FROM clearledger.events "
                    "ORDER BY settlement_id, aggregate_version")
        events = dict_rows(cur)
        cur.execute("SELECT seq, event_id::text AS event_id, payload, published_at, archived_at "
                    "FROM clearledger.outbox ORDER BY seq")
        outbox = dict_rows(cur)
        conn.commit()
    finally:
        conn.autocommit = True
    return settlements, events, outbox


# --------------------------------------------------------------------------
# Control plane
# --------------------------------------------------------------------------
def reconcile_iam():
    iam = client("iam")
    roles = {k: v.rsplit("/", 1)[-1] for k, v in MAN["iam"].items()}
    for role_name in roles.values():
        try:
            inline = iam.list_role_policies(RoleName=role_name)["PolicyNames"]
        except ClientError as exc:
            log(f"iam: role {role_name} unavailable ({exc.response['Error']['Code']})")
            continue
        for name in inline:
            if name != role_name:
                log(f"iam: removing out-of-band inline policy {name} from {role_name}")
                iam.delete_role_policy(RoleName=role_name, PolicyName=name)
        for att in iam.list_attached_role_policies(RoleName=role_name)["AttachedPolicies"]:
            log(f"iam: detaching managed policy {att['PolicyName']} from {role_name}")
            iam.detach_role_policy(RoleName=role_name, PolicyArn=att["PolicyArn"])
    # unattached, prefix-scoped customer-managed policies
    marker = None
    while True:
        kw = {"Scope": "Local"}
        if marker:
            kw["Marker"] = marker
        resp = iam.list_policies(**kw)
        for pol in resp.get("Policies", []):
            if not pol["PolicyName"].startswith(PREFIX):
                continue
            ents = iam.list_entities_for_policy(PolicyArn=pol["Arn"])
            if ents.get("PolicyRoles") or ents.get("PolicyUsers") or ents.get("PolicyGroups"):
                continue
            log(f"iam: deleting unattached managed policy {pol['PolicyName']}")
            for ver in iam.list_policy_versions(PolicyArn=pol["Arn"]).get("Versions", []):
                if not ver["IsDefaultVersion"]:
                    iam.delete_policy_version(PolicyArn=pol["Arn"], VersionId=ver["VersionId"])
            iam.delete_policy(PolicyArn=pol["Arn"])
        if resp.get("IsTruncated"):
            marker = resp.get("Marker")
        else:
            break


def perm_is_public(perm):
    return any(r.get("CidrIp") == "0.0.0.0/0" for r in perm.get("IpRanges", [])) or \
        any(r.get("CidrIpv6") == "::/0" for r in perm.get("Ipv6Ranges", []))


def reconcile_security_groups():
    ec2 = client("ec2")
    ids = MAN["network"]["security_group_ids"]
    groups = {g["GroupId"]: g for g in ec2.describe_security_groups(GroupIds=list(ids.values()))["SecurityGroups"]}

    def only_group_source(perm, port, src):
        return (perm.get("IpProtocol") == "tcp" and perm.get("FromPort") == port and perm.get("ToPort") == port
                and not perm.get("IpRanges") and not perm.get("Ipv6Ranges") and not perm.get("PrefixListIds")
                and [p["GroupId"] for p in perm.get("UserIdGroupPairs", [])] == [src])

    def revoke(gid, perms, egress):
        if not perms:
            return
        log(f"ec2: revoking {len(perms)} out-of-band {'egress' if egress else 'ingress'} rule(s) on {gid}")
        fn = ec2.revoke_security_group_egress if egress else ec2.revoke_security_group_ingress
        for perm in perms:
            clean = {k: v for k, v in perm.items() if v}
            for pair in clean.get("UserIdGroupPairs", []):
                pair.pop("Description", None)
            for rng in clean.get("IpRanges", []) + clean.get("Ipv6Ranges", []):
                rng.pop("Description", None)
            try:
                fn(GroupId=gid, IpPermissions=[clean])
            except ClientError as exc:
                log(f"ec2: revoke failed on {gid}: {exc.response['Error']['Code']}")

    # ecs: ingress only tcp/8080 from the alb security group
    g = groups[ids["ecs"]]
    revoke(g["GroupId"], [p for p in g["IpPermissions"] if not only_group_source(p, 8080, ids["alb"])], False)
    # rds / valkey: ingress only from the ecs group, no egress at all
    for name, port in (("rds", 5432), ("valkey", 6379)):
        g = groups[ids[name]]
        revoke(g["GroupId"], [p for p in g["IpPermissions"] if not only_group_source(p, port, ids["ecs"])], False)
        revoke(g["GroupId"], g["IpPermissionsEgress"], True)
    # alb: no public egress, no ingress other than tcp/80
    g = groups[ids["alb"]]
    revoke(g["GroupId"], [p for p in g["IpPermissionsEgress"] if perm_is_public(p)], True)
    revoke(g["GroupId"], [p for p in g["IpPermissions"]
                          if not (p.get("IpProtocol") == "tcp" and p.get("FromPort") == 80 and p.get("ToPort") == 80
                                  and not p.get("UserIdGroupPairs"))], False)


def reconcile_kms():
    kms = client("kms")
    for name, arn in MAN["kms"].items():
        key_id = arn.rsplit("/", 1)[-1]
        try:
            meta = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        except ClientError as exc:
            log(f"kms: {name} unavailable ({exc.response['Error']['Code']})")
            continue
        if meta.get("KeyState") == "PendingDeletion":
            log(f"kms: cancelling deletion of {name} key")
            kms.cancel_key_deletion(KeyId=key_id)
            meta = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        if meta.get("KeyState") == "Disabled" or not meta.get("Enabled", True):
            log(f"kms: re-enabling {name} key")
            kms.enable_key(KeyId=key_id)
        try:
            if not kms.get_key_rotation_status(KeyId=key_id).get("KeyRotationEnabled"):
                log(f"kms: re-enabling rotation on {name} key")
                kms.enable_key_rotation(KeyId=key_id)
        except ClientError:
            pass


def control_plane():
    for step in (reconcile_iam, reconcile_security_groups, reconcile_kms):
        try:
            step()
        except Exception as exc:  # noqa: BLE001
            log(f"control-plane step {step.__name__} failed: {exc!r}")
            raise


# --------------------------------------------------------------------------
# Outbox -> SQS
# --------------------------------------------------------------------------
def invoke(function_name):
    lam = client("lambda")
    resp = lam.invoke(FunctionName=function_name, InvocationType="RequestResponse", Payload=b"{}")
    body = resp["Payload"].read().decode() or "{}"
    if resp.get("FunctionError"):
        raise RuntimeError(f"{function_name} failed: {body[:300]}")
    try:
        return json.loads(body)
    except ValueError:
        return {}


def backfill_outbox(conn):
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM clearledger.events e WHERE NOT EXISTS "
                "(SELECT 1 FROM clearledger.outbox o WHERE o.event_id = e.event_id)")
    missing = cur.fetchone()[0]
    if missing:
        log(f"outbox: restoring {missing} missing outbox row(s) from clearledger.events")
        cur.execute("SELECT event_id, settlement_id, aggregate_version, correlation_id, payload::text "
                    "FROM clearledger.events e WHERE NOT EXISTS (SELECT 1 FROM clearledger.outbox o "
                    "WHERE o.event_id = e.event_id) ORDER BY settlement_id, aggregate_version")
        for row in cur.fetchall():
            try:
                cur.execute("INSERT INTO clearledger.outbox (event_id, settlement_id, aggregate_version, "
                            "correlation_id, payload) VALUES (%s, %s, %s, %s, %s::jsonb)", row)
            except psycopg2.Error as exc:
                log(f"outbox: cannot restore row for event {row[0]}: {exc.diag.message_primary}")


def unpublished(conn):
    cur = conn.cursor()
    cur.execute("SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq")
    return cur.fetchall()


def converge_outbox(conn):
    backfill_outbox(conn)
    relay = MAN["workers"]["outbox_relay"]["function_name"]
    stalled = 0
    prev = None
    for _ in range(40):
        pending = unpublished(conn)
        if not pending:
            log("outbox: every committed row is published")
            return
        if prev is not None and len(pending) >= prev:
            stalled += 1
        else:
            stalled = 0
        prev = len(pending)
        if stalled >= 2:
            break
        log(f"outbox: {len(pending)} unpublished row(s); invoking relay")
        try:
            log(f"outbox: relay -> {invoke(relay)}")
        except Exception as exc:  # noqa: BLE001
            log(f"outbox: relay invocation failed: {exc}")
            stalled += 1
    pending = unpublished(conn)
    if not pending:
        return
    log(f"outbox: relay made no progress, publishing {len(pending)} row(s) directly")
    sqs = client("sqs")
    cur = conn.cursor()
    for seq, payload in pending:
        sqs.send_message(QueueUrl=MAN["messaging"]["queue_url"], MessageBody=canonical_envelope(payload))
        cur.execute("UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL "
                    "WHERE seq = %s AND published_at IS NULL", (seq,))


# --------------------------------------------------------------------------
# S3 audit archive
# --------------------------------------------------------------------------
BATCH_RE = re.compile(r"^" + re.escape(AUDIT_PREFIX) + r"batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def render_batch(rows):
    return "".join(canonical_envelope(r["payload"]) + "\n" for r in rows).encode()


def batch_key(rows):
    body = render_batch(rows)
    digest = hashlib.sha256(body).hexdigest()[:16]
    return f"{AUDIT_PREFIX}batch-{rows[0]['seq']:08d}-{rows[-1]['seq']:08d}-{digest}.ndjson", body


def list_versions(s3):
    versions, markers = [], []
    kw = {"Bucket": BUCKET}
    while True:
        resp = s3.list_object_versions(**kw)
        versions += resp.get("Versions", [])
        markers += resp.get("DeleteMarkers", [])
        if resp.get("IsTruncated"):
            kw["KeyMarker"] = resp.get("NextKeyMarker")
            if resp.get("NextVersionIdMarker"):
                kw["VersionIdMarker"] = resp["NextVersionIdMarker"]
        else:
            return versions, markers


def delete_versions(s3, items):
    items = list(items)
    for i in range(0, len(items), 500):
        chunk = items[i:i + 500]
        s3.delete_objects(Bucket=BUCKET, Delete={"Objects": [{"Key": k, "VersionId": v} for k, v in chunk], "Quiet": True})


def purge_archive(s3, valid_keys):
    """Keep exactly one (current) version of every valid batch; remove all else."""
    versions, markers = list_versions(s3)
    latest = {}
    for v in versions:
        if v.get("IsLatest"):
            latest[v["Key"]] = v["VersionId"]
    doomed = []
    for v in versions:
        if v["Key"] in valid_keys and latest.get(v["Key"]) == v["VersionId"]:
            continue
        doomed.append((v["Key"], v["VersionId"]))
    doomed += [(m["Key"], m["VersionId"]) for m in markers]
    if doomed:
        log(f"s3: permanently removing {len(doomed)} stray / noncurrent version(s) and delete marker(s)")
        delete_versions(s3, doomed)


def converge_archive(conn):
    s3 = client("s3")
    _, _, outbox = load_snapshot(conn)
    rows = [{"seq": r["seq"], "payload": r["payload"], "archived_at": r["archived_at"]} for r in outbox]
    by_seq = {r["seq"]: r for r in rows}
    seqs = [r["seq"] for r in rows]

    # 1. classify the objects that are currently visible in the bucket
    versions, _ = list_versions(s3)
    candidates = []
    for v in versions:
        if not v.get("IsLatest"):
            continue
        m = BATCH_RE.match(v["Key"])
        if not m:
            continue
        first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
        if first > last or first not in by_seq or last not in by_seq:
            continue
        try:
            body = s3.get_object(Bucket=BUCKET, Key=v["Key"], VersionId=v["VersionId"])["Body"].read()
        except ClientError:
            continue
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            continue
        expect = render_batch([r for r in rows if first <= r["seq"] <= last])
        if body != expect:
            continue
        candidates.append((first, last, v["Key"]))

    # 2. keep a disjoint set (earliest / widest first)
    kept, end = [], 0
    for first, last, key in sorted(candidates, key=lambda c: (c[0], -c[1])):
        if first > end:
            kept.append((first, last, key))
            end = last

    # 3. fixed point: kept batches must not intersect the spans the archiver will write
    while True:
        covered = {s for f, l, _ in kept for s in seqs if f <= s <= l}
        uncovered = [s for s in seqs if s not in covered]
        spans = [(uncovered[i], uncovered[min(i + ARCHIVE_BATCH, len(uncovered)) - 1])
                 for i in range(0, len(uncovered), ARCHIVE_BATCH)]
        clash = [b for b in kept if any(not (b[1] < sf or b[0] > sl) for sf, sl in spans)]
        if not clash:
            break
        log(f"s3: dropping {len(clash)} batch(es) that would overlap rebuilt batches")
        kept = [b for b in kept if b not in clash]

    valid_keys = {k for _, _, k in kept}
    # 4. remove everything that is not a valid batch, before anything is rewritten
    purge_archive(s3, valid_keys)

    # 5. align archived_at with the surviving archive
    cur = conn.cursor()
    stamp = [s for s in sorted(covered) if by_seq[s]["archived_at"] is None]
    if stamp:
        log(f"s3: marking {len(stamp)} row(s) already present in the archive as archived")
        cur.execute("UPDATE clearledger.outbox SET archived_at = NOW() WHERE seq = ANY(%s) AND archived_at IS NULL "
                    "AND published_at IS NOT NULL", (stamp,))
    reset = [s for s in uncovered if by_seq[s]["archived_at"] is not None]
    if reset:
        log(f"s3: resetting archived_at on {len(reset)} row(s) missing from the archive")
        cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE seq = ANY(%s) AND archived_at IS NOT NULL",
                    (reset,))

    # 6. archive whatever is still missing, using the archiver worker
    if uncovered:
        archiver = MAN["workers"]["audit_archiver"]["function_name"]
        for _ in range(math.ceil(len(uncovered) / ARCHIVE_BATCH) + 3):
            cur.execute("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL")
            if cur.fetchone()[0] == 0:
                break
            try:
                log(f"s3: archiver -> {invoke(archiver)}")
            except Exception as exc:  # noqa: BLE001
                log(f"s3: archiver invocation failed: {exc}")
                break
        cur.execute("SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL "
                    "ORDER BY seq")
        left = [{"seq": s, "payload": p} for s, p in cur.fetchall()]
        if left:
            log(f"s3: archiver left {len(left)} row(s); writing canonical batches directly")
            for i in range(0, len(left), ARCHIVE_BATCH):
                chunk = left[i:i + ARCHIVE_BATCH]
                key, body = batch_key(chunk)
                s3.put_object(Bucket=BUCKET, Key=key, Body=body)
                cur.execute("UPDATE clearledger.outbox SET archived_at = NOW() WHERE seq = ANY(%s) AND archived_at IS NULL",
                            ([c["seq"] for c in chunk],))

    # 7. final audit of the bucket: only valid, current batches may remain
    _, _, outbox = load_snapshot(conn)
    rows = [{"seq": r["seq"], "payload": r["payload"]} for r in outbox]
    versions, _ = list_versions(s3)
    final_valid = set()
    for v in versions:
        if not v.get("IsLatest"):
            continue
        m = BATCH_RE.match(v["Key"])
        if not m:
            continue
        first, last = int(m.group(1)), int(m.group(2))
        body = s3.get_object(Bucket=BUCKET, Key=v["Key"], VersionId=v["VersionId"])["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] == m.group(3) and \
                body == render_batch([r for r in rows if first <= r["seq"] <= last]):
            final_valid.add(v["Key"])
    purge_archive(s3, final_valid)
    log(f"s3: archive holds {len(final_valid)} canonical batch object(s) covering {len(rows)} outbox row(s)")


# --------------------------------------------------------------------------
# DynamoDB projections
# --------------------------------------------------------------------------
def scan_all(ddb):
    items = []
    kw = {"TableName": TABLE, "ConsistentRead": True}
    while True:
        resp = ddb.scan(**kw)
        items += resp.get("Items", [])
        if resp.get("LastEvaluatedKey"):
            kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        else:
            return items


def batch_write(ddb, requests):
    for i in range(0, len(requests), 25):
        chunk = requests[i:i + 25]
        for _ in range(8):
            resp = ddb.batch_write_item(RequestItems={TABLE: chunk})
            chunk = resp.get("UnprocessedItems", {}).get(TABLE, [])
            if not chunk:
                break
            time.sleep(0.5)


def converge_dynamodb(conn):
    ddb = client("dynamodb")
    settlements, events, _ = load_snapshot(conn)
    desired = {}
    for s in settlements:
        item = state_item(s)
        desired[(item["PK"]["S"], "STATE")] = item
    for e in events:
        item = event_item(e)
        desired[(item["PK"]["S"], item["SK"]["S"])] = item
    by_id = {s["settlement_id"]: s for s in settlements}

    actual = {(i["PK"]["S"], i["SK"]["S"]): i for i in scan_all(ddb)}

    # remove orphan partitions and stray sort keys (re-checking PostgreSQL for settlements committed meanwhile)
    cur = conn.cursor()
    stray = []
    for (pk, sk), item in actual.items():
        if (pk, sk) in desired:
            continue
        if pk.startswith("SETTLEMENT#"):
            sid = pk[len("SETTLEMENT#"):]
            if sid not in by_id:
                cur.execute("SELECT 1 FROM clearledger.settlements WHERE settlement_id::text = %s", (sid,))
                if cur.fetchone():
                    continue  # committed after the snapshot; the projector owns it
            elif sk.startswith("EVENT#"):
                cur.execute("SELECT 1 FROM clearledger.events WHERE settlement_id::text = %s AND aggregate_version = %s",
                            (sid, int(sk[6:]) if sk[6:].isdigit() else -1))
                if cur.fetchone():
                    continue
        stray.append({"DeleteRequest": {"Key": {"PK": item["PK"], "SK": item["SK"]}}})
    if stray:
        log(f"dynamodb: deleting {len(stray)} orphan / stray item(s)")
        batch_write(ddb, stray)

    # write missing and divergent items
    puts, states = [], []
    for key, item in desired.items():
        if actual.get(key) == item:
            continue
        (states if key[1] == "STATE" else puts).append(item)
    if puts:
        log(f"dynamodb: writing {len(puts)} missing / divergent event item(s)")
        batch_write(ddb, [{"PutRequest": {"Item": i}} for i in puts])
    if states:
        log(f"dynamodb: writing {len(states)} missing / divergent STATE item(s)")
    for item in states:
        try:
            ddb.put_item(TableName=TABLE, Item=item,
                         ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                         ExpressionAttributeNames={"#v": "version"},
                         ExpressionAttributeValues={":v": item["version"]})
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            sid = item["settlement_id"]["S"]
            cur.execute("SELECT version FROM clearledger.settlements WHERE settlement_id::text = %s", (sid,))
            row = cur.fetchone()
            if row and row[0] == int(item["version"]["N"]):
                ddb.put_item(TableName=TABLE, Item=item)  # stored version is ahead of PostgreSQL: divergent
    # verify
    after = {(i["PK"]["S"], i["SK"]["S"]): i for i in scan_all(ddb)}
    bad = [k for k in desired if after.get(k) != desired[k]]
    log(f"dynamodb: {len(desired)} item(s) expected, {len(after)} present, {len(bad)} still differing")


# --------------------------------------------------------------------------
# Valkey cache
# --------------------------------------------------------------------------
def converge_valkey(conn):
    r = redis.Redis(host=MAN["cache"]["endpoint"], port=MAN["cache"]["port"], decode_responses=True,
                    socket_connect_timeout=10, socket_timeout=30)
    settlements, _, _ = load_snapshot(conn)
    wanted = {cache_key(s["settlement_id"]): cache_value(s) for s in settlements}
    stale = [k for k in r.scan_iter(count=1000) if k not in wanted]
    if stale:
        log(f"valkey: purging {len(stale)} orphan / stray key(s)")
        for i in range(0, len(stale), 500):
            r.delete(*stale[i:i + 500])
    pipe = r.pipeline()
    for k, v in wanted.items():
        pipe.set(k, v, ex=CACHE_TTL)
    pipe.execute()
    log(f"valkey: {len(wanted)} settlement projection(s) cached with a {CACHE_TTL}s TTL")


def data_plane(only=None):
    conn = pg_connect()
    steps = [("outbox", converge_outbox), ("archive", converge_archive),
             ("dynamodb", converge_dynamodb), ("valkey", converge_valkey)]
    for name, fn in steps:
        if only and name not in only:
            continue
        fn(conn)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "control-plane":
        control_plane()
    elif cmd == "data-plane":
        data_plane(sys.argv[2:] or None)
    else:
        sys.exit(__doc__)
