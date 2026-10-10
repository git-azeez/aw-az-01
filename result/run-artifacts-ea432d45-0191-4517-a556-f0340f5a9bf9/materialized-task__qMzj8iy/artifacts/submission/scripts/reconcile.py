#!/usr/bin/env python3
"""ClearLedger control-plane drift repair and data-plane convergence.

PostgreSQL (clearledger.settlements / events / outbox) is the system of record.
DynamoDB, Valkey and the S3 audit archive are derived stores that are converged
1-to-1 against it.

Sub-commands (run by deploy.sh in this order):
  drift    remove out-of-band IAM policies / security-group rules
  drain    publish every unpublished outbox row through the relay Lambda and wait
           for the projector to consume the queue
  archive  converge the S3 audit archive with clearledger.outbox
  ddb      converge the DynamoDB projection table with PostgreSQL
  valkey   converge the Valkey cache with PostgreSQL (run last: entries carry a TTL)
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import sys
import time

import boto3
import psycopg2
import redis
from botocore.config import Config

CFG = {}
MAN = {}
CLIENTS = {}


def log(msg):
    print(f"[reconcile] {msg}", flush=True)


def load(config_path, manifest_path):
    global CFG, MAN
    CFG = json.load(open(config_path))
    MAN = json.load(open(manifest_path))


def client(name):
    if name not in CLIENTS:
        CLIENTS[name] = boto3.client(
            name,
            endpoint_url=CFG["aws_endpoint_url"],
            region_name=CFG["region"],
            aws_access_key_id="test",
            aws_secret_access_key="test",
            config=Config(read_timeout=150, connect_timeout=10, retries={"max_attempts": 4, "mode": "standard"}),
        )
    return CLIENTS[name]


def ddb_table():
    res = boto3.resource(
        "dynamodb",
        endpoint_url=CFG["aws_endpoint_url"],
        region_name=CFG["region"],
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 6, "mode": "standard"}),
    )
    return res.Table(MAN["projections"]["table_name"])


def pg():
    db = MAN["database"]
    last = None
    for _ in range(30):
        try:
            conn = psycopg2.connect(
                host=db["endpoint"], port=db["port"], dbname=db["db_name"],
                user=CFG["db_username"], password=CFG["db_password"], connect_timeout=10,
            )
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("SET TIME ZONE 'UTC'")
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    raise RuntimeError(f"cannot connect to PostgreSQL: {last}")


def scalar(conn, sql, args=None):
    with conn.cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchone()[0]


# ----------------------------------------------------------------------------
# drift: IAM and security groups
# ----------------------------------------------------------------------------

def role_names():
    return [arn.rsplit("/", 1)[-1] for arn in MAN["iam"].values()]


def iam_drift():
    iam = client("iam")
    prefix = CFG["resource_prefix"]
    for role in role_names():
        canonical = f"{role}-policy"
        try:
            names = []
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                names += page["PolicyNames"]
            for name in names:
                if name != canonical:
                    log(f"IAM: deleting out-of-band inline policy {role}/{name}")
                    iam.delete_role_policy(RoleName=role, PolicyName=name)
            attached = []
            for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
                attached += page["AttachedPolicies"]
            for pol in attached:
                log(f"IAM: detaching {pol['PolicyArn']} from {role}")
                iam.detach_role_policy(RoleName=role, PolicyArn=pol["PolicyArn"])
        except iam.exceptions.NoSuchEntityException:
            log(f"IAM: role {role} not found (skipped)")
    delete_orphan_policies(prefix)


def delete_orphan_policies(prefix):
    iam = client("iam")
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for pol in page["Policies"]:
            if not pol["PolicyName"].startswith(prefix + "-") and pol["PolicyName"] != prefix:
                continue
            arn = pol["Arn"]
            attached = False
            for ep in iam.get_paginator("list_entities_for_policy").paginate(PolicyArn=arn):
                if ep["PolicyGroups"] or ep["PolicyUsers"] or ep["PolicyRoles"]:
                    attached = True
            if attached:
                continue
            log(f"IAM: deleting detached customer-managed policy {pol['PolicyName']}")
            for v in iam.list_policy_versions(PolicyArn=arn)["Versions"]:
                if not v["IsDefaultVersion"]:
                    iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
            iam.delete_policy(PolicyArn=arn)


def perm_sources(perm):
    src = [("cidr", r["CidrIp"]) for r in perm.get("IpRanges", [])]
    src += [("cidr6", r["CidrIpv6"]) for r in perm.get("Ipv6Ranges", [])]
    src += [("sg", p["GroupId"]) for p in perm.get("UserIdGroupPairs", [])]
    src += [("pl", p["PrefixListId"]) for p in perm.get("PrefixListIds", [])]
    return src


def sg_drift():
    ec2 = client("ec2")
    ids = MAN["network"]["security_group_ids"]
    vpc_cidr = ec2.describe_vpcs(VpcIds=[MAN["network"]["vpc_id"]])["Vpcs"][0]["CidrBlock"]
    groups = {g["GroupId"]: g for g in ec2.describe_security_groups(GroupIds=list(ids.values()))["SecurityGroups"]}

    def revoke(gid, perm, egress):
        log(f"SG: revoking {'egress' if egress else 'ingress'} {perm.get('IpProtocol')}:{perm.get('FromPort')}-{perm.get('ToPort')} on {gid}")
        fn = ec2.revoke_security_group_egress if egress else ec2.revoke_security_group_ingress
        fn(GroupId=gid, IpPermissions=[perm])

    def split(perm):
        """one permission per source so a bad source does not take good ones with it"""
        out = []
        for key, field in (("IpRanges", "CidrIp"), ("Ipv6Ranges", "CidrIpv6"), ("UserIdGroupPairs", "GroupId"), ("PrefixListIds", "PrefixListId")):
            for item in perm.get(key, []):
                p = {k: v for k, v in perm.items() if k not in ("IpRanges", "Ipv6Ranges", "UserIdGroupPairs", "PrefixListIds")}
                p[key] = [item]
                out.append((p, key, item))
        if not out:
            out.append((perm, None, None))
        return out

    # egress
    for name in ("rds", "valkey"):
        gid = ids[name]
        for perm in groups[gid].get("IpPermissionsEgress", []):
            revoke(gid, perm, True)
    gid = ids["alb"]
    for perm in groups[gid].get("IpPermissionsEgress", []):
        for p, key, item in split(perm):
            proto, fp, tp = p.get("IpProtocol"), p.get("FromPort"), p.get("ToPort")
            bad = proto != "tcp" or fp != 8080 or tp != 8080
            if key == "IpRanges" and item["CidrIp"] == "0.0.0.0/0":
                bad = True
            if key == "Ipv6Ranges":
                bad = True
            if bad:
                revoke(gid, p, True)

    # ingress: only the contracted rule may remain
    allowed = {
        "alb": (80, {("cidr", "0.0.0.0/0")}),
        "ecs": (8080, {("sg", ids["alb"])}),
        "rds": (5432, {("sg", ids["ecs"]), ("cidr", vpc_cidr)}),
        "valkey": (6379, {("sg", ids["ecs"]), ("cidr", vpc_cidr)}),
    }
    for name, (port, srcs) in allowed.items():
        gid = ids[name]
        for perm in groups[gid].get("IpPermissions", []):
            for p, key, item in split(perm):
                ok = p.get("IpProtocol") == "tcp" and p.get("FromPort") == port and p.get("ToPort") == port
                if key is None:
                    ok = False
                else:
                    ident = {"IpRanges": "cidr", "Ipv6Ranges": "cidr6", "UserIdGroupPairs": "sg", "PrefixListIds": "pl"}[key]
                    val = item.get("CidrIp") or item.get("CidrIpv6") or item.get("GroupId") or item.get("PrefixListId")
                    ok = ok and (ident, val) in srcs
                if not ok:
                    revoke(gid, p, False)


# ----------------------------------------------------------------------------
# drain: outbox -> SQS -> projector
# ----------------------------------------------------------------------------

def invoke(function_name, payload=b"{}"):
    last = None
    for attempt in range(4):
        try:
            r = client("lambda").invoke(FunctionName=function_name, InvocationType="RequestResponse", Payload=payload)
            body = r["Payload"].read()
            if r.get("FunctionError"):
                raise RuntimeError(f"{function_name} failed: {body[:300]!r}")
            try:
                return json.loads(body or b"{}")
            except ValueError:
                return {}
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2 + attempt * 2)
    raise RuntimeError(f"invoking {function_name}: {last}")


def drain():
    conn = pg()
    relay = MAN["workers"]["outbox_relay"]["function_name"]
    pending = scalar(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
    log(f"outbox: {pending} unpublished row(s)")
    rounds = 0
    while pending > 0:
        rounds += 1
        if rounds > pending // 50 + 12:
            raise RuntimeError(f"outbox relay could not publish {pending} row(s)")
        res = invoke(relay)
        pending = scalar(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        log(f"relay round {rounds}: {res} -> {pending} unpublished")
        if pending and not res.get("published"):
            time.sleep(2)
    wait_queue_idle()


def wait_queue_idle(timeout=75):
    sqs = client("sqs")
    url = MAN["messaging"]["queue_url"]
    deadline = time.time() + timeout
    quiet = 0
    while time.time() < deadline:
        try:
            a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["All"])["Attributes"]
        except Exception as exc:  # noqa: BLE001
            log(f"queue attributes unavailable: {exc}")
            time.sleep(2)
            continue
        busy = sum(int(a.get(k, 0)) for k in (
            "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible", "ApproximateNumberOfMessagesDelayed"))
        if busy == 0:
            quiet += 1
            if quiet >= 2:
                log("main queue is idle")
                return
        else:
            quiet = 0
        time.sleep(1.5)
    log("main queue did not go idle in time; continuing with direct reconciliation")


# ----------------------------------------------------------------------------
# archive: S3 audit bucket <-> clearledger.outbox
# ----------------------------------------------------------------------------

KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def s3_versions(bucket):
    s3 = client("s3")
    versions, markers = [], []
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
        versions += page.get("Versions", [])
        markers += page.get("DeleteMarkers", [])
    return versions, markers


def s3_delete_versions(bucket, entries):
    s3 = client("s3")
    entries = list(entries)
    for i in range(0, len(entries), 500):
        chunk = [{"Key": e["Key"], "VersionId": e["VersionId"]} for e in entries[i:i + 500]]
        resp = s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
        if resp.get("Errors"):
            raise RuntimeError(f"S3 delete errors: {resp['Errors'][:3]}")


def pending_archive(conn):
    return scalar(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL")


def archive_pending(conn):
    fn = MAN["workers"]["audit_archiver"]["function_name"]
    pending = pending_archive(conn)
    rounds = 0
    while pending > 0:
        rounds += 1
        if rounds > pending // 100 + 12:
            raise RuntimeError(f"audit archiver could not archive {pending} row(s)")
        res = invoke(fn)
        pending = pending_archive(conn)
        log(f"archiver round {rounds}: {res} -> {pending} unarchived")
        if pending and not res.get("archived"):
            time.sleep(2)


def validate_archive(conn, bucket):
    """Returns (ok, reason). Only current (IsLatest) object versions are considered."""
    s3 = client("s3")
    with conn.cursor() as cur:
        cur.execute("SELECT seq, event_id::text, payload, archived_at IS NOT NULL FROM clearledger.outbox ORDER BY seq")
        rows = cur.fetchall()
    by_event = {r[1]: r for r in rows}
    all_seqs = [r[0] for r in rows]
    if any(not r[3] for r in rows):
        return False, "outbox rows without archived_at"
    versions, markers = s3_versions(bucket)
    if any(m["IsLatest"] for m in markers):
        return False, "current delete marker present"
    current = [v for v in versions if v["IsLatest"]]
    batches = []
    for v in current:
        m = KEY_RE.match(v["Key"])
        if not m:
            return False, f"non-canonical object {v['Key']}"
        first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
        body = s3.get_object(Bucket=bucket, Key=v["Key"], VersionId=v["VersionId"])["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            return False, f"digest mismatch for {v['Key']}"
        seqs = []
        for line in body.decode("utf-8").split("\n"):
            if not line.strip():
                continue
            try:
                doc = json.loads(line)
            except ValueError:
                return False, f"invalid JSON line in {v['Key']}"
            row = by_event.get(doc.get("eventId") if isinstance(doc, dict) else None)
            if row is None or row[2] != doc:
                return False, f"record in {v['Key']} does not match outbox"
            seqs.append(row[0])
        if not seqs or seqs != sorted(set(seqs)):
            return False, f"records of {v['Key']} are not strictly ascending"
        if seqs[0] != first or seqs[-1] != last:
            return False, f"{v['Key']} bounds do not match its records"
        if [s for s in all_seqs if first <= s <= last] != seqs:
            return False, f"{v['Key']} is not gap-free"
        batches.append((first, last, seqs))
    batches.sort()
    for a, b in zip(batches, batches[1:]):
        if b[0] <= a[1]:
            return False, "overlapping batches"
    covered = [s for b in batches for s in b[2]]
    if covered != all_seqs:
        return False, "archive does not cover the outbox 1-to-1"
    return True, "ok"


def archive():
    conn = pg()
    bucket = MAN["audit"]["bucket_name"]
    ok, why = False, ""
    for attempt in range(4):
        archive_pending(conn)
        ok, why = validate_archive(conn, bucket)
        log(f"archive validation (attempt {attempt + 1}): {why}")
        if ok:
            break
        # rebuild from scratch: one contiguous, deterministic sequence of batches
        with conn.cursor() as cur:
            cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
        versions, markers = s3_versions(bucket)
        log(f"purging {len(versions)} version(s) and {len(markers)} delete marker(s) before re-archival")
        s3_delete_versions(bucket, versions + markers)
    if not ok:
        raise RuntimeError(f"audit archive could not be reconciled: {why}")
    versions, markers = s3_versions(bucket)
    stale = [v for v in versions if not v["IsLatest"]] + markers
    if stale:
        log(f"purging {len(stale)} noncurrent version(s)/delete marker(s)")
        s3_delete_versions(bucket, stale)
    ok, why = validate_archive(conn, bucket)
    if not ok:
        raise RuntimeError(f"audit archive invalid after purge: {why}")
    versions, markers = s3_versions(bucket)
    log(f"audit archive converged: {len(versions)} batch object(s), {len(markers)} delete marker(s)")


# ----------------------------------------------------------------------------
# PostgreSQL snapshot and canonical renderings
# ----------------------------------------------------------------------------

ENVELOPE_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId", "aggregateVersion",
                  "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId", "status", "clearingStage", "memo"]


def ordered_envelope(payload):
    out = {k: payload[k] for k in ENVELOPE_ORDER if k in payload}
    out["data"] = {k: payload["data"][k] for k in DATA_ORDER if k in payload["data"]}
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


def chrono_rfc3339(ts, zulu):
    ts = ts.astimezone(dt.timezone.utc)
    base = ts.strftime("%Y-%m-%dT%H:%M:%S")
    us = ts.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return base + frac + ("Z" if zulu else "+00:00")


def snapshot():
    conn = pg()
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            cur.execute("""SELECT settlement_id::text, account_id, reference, debit_party, credit_party, current_status,
                                  current_stage, last_entry_id::text, last_memo, version, entry_count, updated_at
                             FROM clearledger.settlements ORDER BY settlement_id""")
            settlements = cur.fetchall()
            cur.execute("""SELECT settlement_id::text, aggregate_version, event_id::text, event_type, correlation_id,
                                  occurred_at, payload
                             FROM clearledger.events ORDER BY settlement_id, aggregate_version""")
            events = cur.fetchall()
    finally:
        conn.rollback()
        conn.close()
    return settlements, events


def expected_items(settlements, events):
    evs = {}
    for e in events:
        evs.setdefault(e[0], []).append(e)
    items = {}
    for s in settlements:
        sid, account, ref, debit, credit, status, stage, last_entry, last_memo, version, count, updated = s
        pk = f"SETTLEMENT#{sid}"
        state = {
            "PK": pk, "SK": "STATE", "GSI1PK": f"ACCOUNT#{account}", "GSI1SK": f"SETTLEMENT#{sid}",
            "settlement_id": sid, "account_id": account, "reference": ref, "debit_party": debit,
            "credit_party": credit, "status": status, "clearing_stage": stage, "version": version,
            "entry_count": count, "updated_at": chrono_rfc3339(updated, False),
        }
        if last_entry is not None:
            state["last_entry_id"] = last_entry
        if last_memo is not None:
            state["last_memo"] = last_memo
        items[(pk, "STATE")] = state
        for (_, v, event_id, etype, corr, occurred, payload) in evs.get(sid, []):
            data = payload["data"]
            item = {
                "PK": pk, "SK": f"EVENT#{v:08d}", "settlement_id": sid, "event_id": event_id, "version": v,
                "event_type": etype, "status": data["status"], "clearing_stage": data["clearingStage"],
                "occurred_at": chrono_rfc3339(occurred, False), "correlation_id": corr,
                "envelope": ordered_envelope(payload),
            }
            if data.get("entryId") is not None:
                item["entry_id"] = data["entryId"]
            if data.get("memo") is not None:
                item["memo"] = data["memo"]
            items[(pk, item["SK"])] = item
    return items


def parse_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def item_matches(actual, expected):
    if set(actual) != set(expected):
        return False
    for k, want in expected.items():
        got = actual[k]
        if k in ("version", "entry_count"):
            if int(got) != want:
                return False
        elif k in ("updated_at", "occurred_at"):
            try:
                if parse_ts(got) != parse_ts(want):
                    return False
            except (ValueError, TypeError):
                return False
        elif k == "envelope":
            try:
                if json.loads(got) != json.loads(want):
                    return False
            except (ValueError, TypeError):
                return False
        elif got != want:
            return False
    return True


# ----------------------------------------------------------------------------
# ddb
# ----------------------------------------------------------------------------

def scan_table(table):
    items, kwargs = [], {"ConsistentRead": True}
    while True:
        page = table.scan(**kwargs)
        items += page.get("Items", [])
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def ddb():
    table = ddb_table()
    for attempt in range(3):
        settlements, events = snapshot()
        want = expected_items(settlements, events)
        have = {}
        for it in scan_table(table):
            have[(it.get("PK"), it.get("SK"))] = it
        deletes = [k for k in have if k not in want]
        puts = [k for k, exp in want.items() if k not in have or not item_matches(have[k], exp)]
        log(f"dynamodb: {len(have)} item(s) present, {len(want)} expected, {len(deletes)} to delete, {len(puts)} to write")
        if not deletes and not puts:
            return
        with table.batch_writer() as bw:
            for pk, sk in deletes:
                if pk is None or sk is None:
                    continue
                bw.delete_item(Key={"PK": pk, "SK": sk})
            for k in puts:
                bw.put_item(Item=want[k])
        for pk, sk in deletes:
            if pk is None or sk is None:
                log(f"dynamodb: skipping malformed item without full key: {pk!r}/{sk!r}")
    # final verification
    settlements, events = snapshot()
    want = expected_items(settlements, events)
    have = {(i.get("PK"), i.get("SK")): i for i in scan_table(table)}
    bad = [k for k in have if k not in want] + [k for k, e in want.items() if k not in have or not item_matches(have[k], e)]
    if bad:
        raise RuntimeError(f"dynamodb did not converge: {bad[:5]}")


# ----------------------------------------------------------------------------
# valkey
# ----------------------------------------------------------------------------

def projection_json(s):
    sid, account, ref, debit, credit, status, stage, last_entry, last_memo, version, count, updated = s
    doc = {"settlementId": sid, "accountId": account, "reference": ref, "debitParty": debit,
           "creditParty": credit, "status": status, "clearingStage": stage}
    if last_entry is not None:
        doc["lastEntryId"] = last_entry
    if last_memo is not None:
        doc["lastMemo"] = last_memo
    doc.update({"version": version, "entryCount": count, "updatedAt": chrono_rfc3339(updated, True)})
    return json.dumps(doc, separators=(",", ":"), ensure_ascii=False)


def valkey():
    settlements, _ = snapshot()
    ttl = 90
    cache = MAN["cache"]
    r = redis.Redis(host=cache["endpoint"], port=cache["port"], decode_responses=True, socket_timeout=10)
    want = {f"clearledger:settlement:{s[0]}": projection_json(s) for s in settlements}
    dbs = [0]
    try:
        for name in r.info("keyspace"):
            if name.startswith("db") and name[2:].isdigit() and int(name[2:]) not in dbs:
                dbs.append(int(name[2:]))
    except redis.RedisError:
        pass
    for db in dbs:
        rr = redis.Redis(host=cache["endpoint"], port=cache["port"], db=db, decode_responses=True, socket_timeout=10)
        stray = [k for k in rr.scan_iter(count=1000) if db != 0 or k not in want]
        for i in range(0, len(stray), 500):
            rr.delete(*stray[i:i + 500])
        if stray:
            log(f"valkey db{db}: purged {len(stray)} stray key(s)")
    pipe = r.pipeline(transaction=False)
    for k, v in want.items():
        pipe.set(k, v, ex=ttl)
    pipe.execute()
    keys = sorted(r.scan_iter(count=1000))
    if keys != sorted(want):
        raise RuntimeError("valkey did not converge")
    log(f"valkey: {len(want)} settlement key(s) populated (ttl {ttl}s)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("step", choices=["drift", "drain", "archive", "ddb", "valkey"])
    ap.add_argument("--config", default="/workspace/config/config.json")
    ap.add_argument("--manifest", default="/workspace/submission/manifest.json")
    args = ap.parse_args()
    load(args.config, args.manifest)
    if args.step == "drift":
        iam_drift()
        sg_drift()
    elif args.step == "drain":
        drain()
    elif args.step == "archive":
        archive()
    elif args.step == "ddb":
        ddb()
    elif args.step == "valkey":
        valkey()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"[reconcile] ERROR: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
