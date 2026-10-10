#!/usr/bin/env python3
"""ClearLedger operational reconciliation helpers used by deploy.sh.

Sub-commands
  control   remove out-of-band IAM policies / security-group rules
  data      converge outbox -> SQS, DynamoDB, S3 audit archive and Valkey
            against the authoritative PostgreSQL state

PostgreSQL (clearledger.settlements / events / outbox) is the system of record;
everything else is derived from it.
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import sys
import time
from collections import OrderedDict

import boto3
import psycopg2
import redis
from botocore.config import Config
from botocore.exceptions import ClientError

UTC = dt.timezone.utc
BATCH_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def log(msg):
    print(f"[reconcile] {msg}", flush=True)


class Ctx:
    def __init__(self, config_path, manifest_path):
        with open(config_path) as fh:
            self.cfg = json.load(fh)
        with open(manifest_path) as fh:
            self.m = json.load(fh)
        self.region = self.cfg["region"]
        self.endpoint = self.cfg["aws_endpoint_url"]
        self.prefix = self.cfg["resource_prefix"]
        self._boto_cfg = Config(
            retries={"max_attempts": 8, "mode": "standard"},
            s3={"addressing_style": "path"},
            connect_timeout=10,
            read_timeout=120,
        )

    def client(self, service):
        return boto3.client(
            service,
            endpoint_url=self.endpoint,
            region_name=self.region,
            aws_access_key_id="test",
            aws_secret_access_key="test",
            config=self._boto_cfg,
        )

    def pg(self):
        db = self.m["database"]
        conn = psycopg2.connect(
            host=db["endpoint"],
            port=db["port"],
            dbname=self.cfg["db_name"],
            user=self.cfg["db_username"],
            password=self.cfg["db_password"],
            connect_timeout=15,
            application_name="clearledger-reconcile",
        )
        conn.autocommit = False
        return conn

    def valkey(self):
        c = self.m["cache"]
        return redis.Redis(host=c["endpoint"], port=c["port"], decode_responses=True, socket_timeout=15)


# ---------------------------------------------------------------------------
# Canonical serialisation (mirrors the Rust services' serde output)
# ---------------------------------------------------------------------------
def fmt_ts(value):
    """chrono AutoSi formatting: 0, 3 or 6 fractional digits."""
    value = value.astimezone(UTC)
    base = value.strftime("%Y-%m-%dT%H:%M:%S")
    us = value.microsecond
    if us == 0:
        return base
    if us % 1000 == 0:
        return f"{base}.{us // 1000:03d}"
    return f"{base}.{us:06d}"


def canon_envelope(p):
    d = p["data"]
    data = OrderedDict()
    data["kind"] = d["kind"]
    for k in ("accountId", "reference", "debitParty", "creditParty"):
        data[k] = d[k]
    if d.get("entryId") is not None:
        data["entryId"] = d["entryId"]
    data["status"] = d["status"]
    data["clearingStage"] = d["clearingStage"]
    if d.get("memo") is not None:
        data["memo"] = d["memo"]
    env = OrderedDict()
    for k in (
        "schemaVersion",
        "eventId",
        "eventType",
        "aggregateType",
        "aggregateId",
        "aggregateVersion",
        "occurredAt",
        "correlationId",
        "idempotencyKey",
    ):
        env[k] = p[k]
    env["data"] = data
    return json.dumps(env, separators=(",", ":"), ensure_ascii=False)


def canon_projection(s):
    out = OrderedDict()
    out["settlementId"] = str(s["settlement_id"])
    out["accountId"] = s["account_id"]
    out["reference"] = s["reference"]
    out["debitParty"] = s["debit_party"]
    out["creditParty"] = s["credit_party"]
    out["status"] = s["current_status"]
    out["clearingStage"] = s["current_stage"]
    if s["last_entry_id"] is not None:
        out["lastEntryId"] = str(s["last_entry_id"])
    if s["last_memo"] is not None:
        out["lastMemo"] = s["last_memo"]
    out["version"] = s["version"]
    out["entryCount"] = s["entry_count"]
    out["updatedAt"] = fmt_ts(s["updated_at"]) + "Z"
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


# ---------------------------------------------------------------------------
# PostgreSQL snapshot
# ---------------------------------------------------------------------------
def load_pg(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT settlement_id, account_id, reference, debit_party, credit_party, current_status, current_stage,"
        " last_entry_id, last_memo, version, entry_count, created_at, updated_at"
        " FROM clearledger.settlements ORDER BY settlement_id"
    )
    cols = [c.name for c in cur.description]
    settlements = [dict(zip(cols, r)) for r in cur.fetchall()]
    cur.execute(
        "SELECT event_id, settlement_id, aggregate_version, event_type, correlation_id, occurred_at, payload"
        " FROM clearledger.events ORDER BY settlement_id, aggregate_version"
    )
    cols = [c.name for c in cur.description]
    events = [dict(zip(cols, r)) for r in cur.fetchall()]
    conn.rollback()
    return settlements, events


def load_outbox(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT seq, event_id, settlement_id, aggregate_version, payload, published_at, archived_at"
        " FROM clearledger.outbox ORDER BY seq"
    )
    cols = [c.name for c in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    conn.rollback()
    return rows


def count_unpublished(conn):
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
    n = cur.fetchone()[0]
    conn.rollback()
    return n


# ---------------------------------------------------------------------------
# 1. Outbox -> SQS
# ---------------------------------------------------------------------------
def publish_outbox(ctx, conn):
    lam = ctx.client("lambda")
    fn = ctx.m["workers"]["outbox_relay"]["function_name"]
    pending = count_unpublished(conn)
    attempts = 0
    while pending and attempts < 12:
        attempts += 1
        try:
            resp = lam.invoke(FunctionName=fn, InvocationType="RequestResponse", Payload=b"{}")
            resp["Payload"].read()
        except ClientError as exc:
            log(f"relay invoke failed: {exc}")
            time.sleep(2)
        new_pending = count_unpublished(conn)
        log(f"outbox relay run {attempts}: unpublished {pending} -> {new_pending}")
        if new_pending == pending:
            time.sleep(1)
        pending = new_pending
    if not pending:
        return
    # Fallback: publish directly with exactly the relay's contract.
    log(f"relay left {pending} rows unpublished; publishing directly")
    sqs = ctx.client("sqs")
    url = ctx.m["messaging"]["queue_url"]
    cur = conn.cursor()
    cur.execute("SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq")
    for seq, payload in cur.fetchall():
        sqs.send_message(QueueUrl=url, MessageBody=canon_envelope(payload))
        cur.execute(
            "UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL"
            " WHERE seq = %s AND published_at IS NULL",
            (seq,),
        )
    conn.commit()


# ---------------------------------------------------------------------------
# 2. DynamoDB
# ---------------------------------------------------------------------------
def S(v):
    return {"S": v}


def N(v):
    return {"N": str(v)}


def expected_dynamo(settlements, events):
    items = {}
    for s in settlements:
        sid = str(s["settlement_id"])
        pk = f"SETTLEMENT#{sid}"
        st = {
            "PK": S(pk),
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
            "updated_at": S(fmt_ts(s["updated_at"]) + "+00:00"),
        }
        if s["last_entry_id"] is not None:
            st["last_entry_id"] = S(str(s["last_entry_id"]))
        if s["last_memo"] is not None:
            st["last_memo"] = S(s["last_memo"])
        items[(pk, "STATE")] = st
    for e in events:
        sid = str(e["settlement_id"])
        pk = f"SETTLEMENT#{sid}"
        sk = f"EVENT#{e['aggregate_version']:08d}"
        d = e["payload"]["data"]
        it = {
            "PK": S(pk),
            "SK": S(sk),
            "settlement_id": S(sid),
            "event_id": S(str(e["event_id"])),
            "version": N(e["aggregate_version"]),
            "event_type": S(e["event_type"]),
            "status": S(d["status"]),
            "clearing_stage": S(d["clearingStage"]),
            "occurred_at": S(fmt_ts(e["occurred_at"]) + "+00:00"),
            "correlation_id": S(e["correlation_id"]),
            "envelope": S(canon_envelope(e["payload"])),
        }
        if d.get("entryId") is not None:
            it["entry_id"] = S(d["entryId"])
        if d.get("memo") is not None:
            it["memo"] = S(d["memo"])
        items[(pk, sk)] = it
    return items


def scan_all(ddb, table):
    items = []
    kwargs = {"TableName": table, "ConsistentRead": True}
    while True:
        resp = ddb.scan(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            return items
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def batch_write(ddb, table, requests_):
    for i in range(0, len(requests_), 25):
        chunk = requests_[i : i + 25]
        delay = 0.2
        while chunk:
            resp = ddb.batch_write_item(RequestItems={table: chunk})
            chunk = resp.get("UnprocessedItems", {}).get(table, [])
            if chunk:
                time.sleep(delay)
                delay = min(delay * 2, 3)


def reconcile_dynamodb(ctx, conn):
    ddb = ctx.client("dynamodb")
    table = ctx.m["projections"]["table_name"]
    settlements, events = load_pg(conn)
    expected = expected_dynamo(settlements, events)
    actual = {}
    for it in scan_all(ddb, table):
        actual[(it["PK"]["S"], it["SK"]["S"])] = it
    puts, dels = [], []
    for key, exp in expected.items():
        if actual.get(key) != exp:
            puts.append({"PutRequest": {"Item": exp}})
    for key in actual:
        if key not in expected:
            dels.append({"DeleteRequest": {"Key": {"PK": S(key[0]), "SK": S(key[1])}}})
    log(f"dynamodb: expected={len(expected)} actual={len(actual)} rewrite={len(puts)} delete={len(dels)}")
    batch_write(ddb, table, dels + puts)
    return len(puts) + len(dels)


# ---------------------------------------------------------------------------
# 3. S3 audit archive
# ---------------------------------------------------------------------------
def list_all_versions(s3, bucket):
    out = []
    kwargs = {"Bucket": bucket}
    while True:
        resp = s3.list_object_versions(**kwargs)
        for v in resp.get("Versions", []):
            out.append(("version", v["Key"], v["VersionId"], v.get("IsLatest", False)))
        for v in resp.get("DeleteMarkers", []):
            out.append(("marker", v["Key"], v["VersionId"], v.get("IsLatest", False)))
        if not resp.get("IsTruncated"):
            return out
        kwargs["KeyMarker"] = resp.get("NextKeyMarker")
        if resp.get("NextVersionIdMarker"):
            kwargs["VersionIdMarker"] = resp["NextVersionIdMarker"]


def delete_versions(s3, bucket, victims):
    for i in range(0, len(victims), 500):
        chunk = victims[i : i + 500]
        resp = s3.delete_objects(
            Bucket=bucket,
            Delete={"Objects": [{"Key": k, "VersionId": v} for k, v in chunk], "Quiet": True},
        )
        errs = resp.get("Errors") or []
        if errs:
            raise RuntimeError(f"s3 delete errors: {errs[:3]}")


def reconcile_s3(ctx, conn, batch_size=100):
    s3 = ctx.client("s3")
    bucket = ctx.m["audit"]["bucket_name"]
    prefix = ctx.m["audit"]["prefix"]
    rows = load_outbox(conn)
    seqs = [r["seq"] for r in rows]
    index_of = {r["seq"]: i for i, r in enumerate(rows)}

    versions = list_all_versions(s3, bucket)
    candidates = []
    for kind, key, vid, latest in versions:
        m = BATCH_RE.match(key)
        if kind == "version" and latest and m:
            candidates.append((int(m.group(1)), int(m.group(2)), m.group(3), key, vid))
    candidates.sort()

    kept = []  # (first, last, key, vid)
    covered = set()
    last_end = -1
    for first, last, digest, key, vid in candidates:
        if first <= last_end or first > last:
            continue
        body = s3.get_object(Bucket=bucket, Key=key, VersionId=vid)["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            continue
        try:
            lines = [json.loads(x) for x in body.decode("utf-8").split("\n") if x != ""]
        except Exception:  # noqa: BLE001
            continue
        in_range = [r for r in rows if first <= r["seq"] <= last]
        if not in_range or in_range[0]["seq"] != first or in_range[-1]["seq"] != last:
            continue
        if len(in_range) != len(lines):
            continue
        if any(r["published_at"] is None for r in in_range):
            continue
        if any(line != r["payload"] for line, r in zip(lines, in_range)):
            continue
        kept.append((first, last, key, vid))
        covered.update(r["seq"] for r in in_range)
        last_end = last

    keep_ids = {(k, v) for _, _, k, v in kept}
    victims = [(key, vid) for _, key, vid, _ in versions if (key, vid) not in keep_ids]
    if victims:
        log(f"s3: purging {len(victims)} invalid/noncurrent object versions or delete markers")
        delete_versions(s3, bucket, victims)

    # Archive every published, uncovered row in contiguous slices.
    new_batches = 0
    run = []

    def flush(run_rows):
        nonlocal new_batches
        for i in range(0, len(run_rows), batch_size):
            part = run_rows[i : i + batch_size]
            body = "".join(canon_envelope(r["payload"]) + "\n" for r in part).encode("utf-8")
            digest = hashlib.sha256(body).hexdigest()[:16]
            key = f"{prefix}batch-{part[0]['seq']:08d}-{part[-1]['seq']:08d}-{digest}.ndjson"
            s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/x-ndjson")
            covered.update(r["seq"] for r in part)
            new_batches += 1

    for r in rows:
        if r["seq"] not in covered and r["published_at"] is not None:
            run.append(r)
        else:
            if run:
                flush(run)
                run = []
    if run:
        flush(run)

    cur = conn.cursor()
    cur.execute(
        "UPDATE clearledger.outbox SET archived_at = NOW()"
        " WHERE seq = ANY(%s) AND archived_at IS NULL AND published_at IS NOT NULL",
        (sorted(covered),),
    )
    stamped = cur.rowcount
    conn.commit()
    log(f"s3: kept={len(kept)} new_batches={new_batches} purged={len(victims)} stamped_archived_at={stamped}")
    return len(victims) + new_batches + stamped


def verify_s3(ctx, conn):
    """Returns a list of problems; empty when the archive is exactly 1-to-1 with PostgreSQL."""
    s3 = ctx.client("s3")
    bucket = ctx.m["audit"]["bucket_name"]
    rows = load_outbox(conn)
    problems = []
    versions = list_all_versions(s3, bucket)
    seen = {}
    last_end = -1
    for kind, key, vid, latest in sorted(versions, key=lambda t: t[1]):
        m = BATCH_RE.match(key)
        if kind != "version" or not latest or not m:
            problems.append(f"unexpected object/marker {kind} {key}")
            continue
        first, last = int(m.group(1)), int(m.group(2))
        body = s3.get_object(Bucket=bucket, Key=key, VersionId=vid)["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != m.group(3):
            problems.append(f"bad digest {key}")
        if first <= last_end:
            problems.append(f"overlap at {key}")
        last_end = max(last_end, last)
        in_range = [r for r in rows if first <= r["seq"] <= last]
        lines = [json.loads(x) for x in body.decode().split("\n") if x]
        if len(lines) != len(in_range) or any(a != b["payload"] for a, b in zip(lines, in_range)):
            problems.append(f"content mismatch {key}")
        for r in in_range:
            seen[r["seq"]] = seen.get(r["seq"], 0) + 1
    for r in rows:
        if r["published_at"] is None:
            continue
        if seen.get(r["seq"], 0) != 1:
            problems.append(f"seq {r['seq']} archived {seen.get(r['seq'], 0)} times")
        if r["archived_at"] is None:
            problems.append(f"seq {r['seq']} archived_at is NULL")
    return problems


# ---------------------------------------------------------------------------
# 4. Valkey
# ---------------------------------------------------------------------------
def reconcile_valkey(ctx, conn, ttl=90):
    r = ctx.valkey()
    settlements, _ = load_pg(conn)
    expected = {f"clearledger:settlement:{s['settlement_id']}": canon_projection(s) for s in settlements}
    removed = 0
    batch = []
    for key in r.scan_iter(match="*", count=500):
        if key not in expected:
            batch.append(key)
            if len(batch) >= 500:
                removed += r.delete(*batch)
                batch = []
    if batch:
        removed += r.delete(*batch)
    pipe = r.pipeline(transaction=False)
    for key, val in expected.items():
        pipe.set(key, val, ex=ttl)
    pipe.execute()
    log(f"valkey: expected={len(expected)} purged_stray={removed}")


# ---------------------------------------------------------------------------
# Control plane clean-up
# ---------------------------------------------------------------------------
def control(ctx):
    iam = ctx.client("iam")
    ec2 = ctx.client("ec2")
    prefix = ctx.prefix

    role_arns = ctx.m["iam"]
    for arn in role_arns.values():
        role = arn.rsplit("/", 1)[-1]
        canonical = f"{role}-policy"
        try:
            names = iam.list_role_policies(RoleName=role)["PolicyNames"]
            attached = iam.list_attached_role_policies(RoleName=role)["AttachedPolicies"]
        except ClientError as exc:
            log(f"iam: cannot inspect {role}: {exc}")
            continue
        for name in names:
            if name != canonical:
                log(f"iam: deleting out-of-band inline policy {role}/{name}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
        for pol in attached:
            log(f"iam: detaching out-of-band managed policy {pol['PolicyArn']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=pol["PolicyArn"])

    for pol in iam.list_policies(Scope="Local").get("Policies", []):
        if pol["PolicyName"].startswith(prefix) and pol.get("AttachmentCount", 0) == 0:
            log(f"iam: deleting unattached customer-managed policy {pol['PolicyName']}")
            delete_policy(iam, pol["Arn"])

    sg_ids = ctx.m["network"]["security_group_ids"]
    groups = ec2.describe_security_groups(GroupIds=list(sg_ids.values()))["SecurityGroups"]
    by_id = {g["GroupId"]: g for g in groups}
    allowed_src = {
        sg_ids["ecs"]: (8080, sg_ids["alb"]),
        sg_ids["rds"]: (5432, sg_ids["ecs"]),
        sg_ids["valkey"]: (6379, sg_ids["ecs"]),
    }
    for gid, (port, src) in allowed_src.items():
        g = by_id[gid]
        revoke = []
        for perm in g.get("IpPermissions", []):
            base = {"IpProtocol": perm["IpProtocol"]}
            if "FromPort" in perm:
                base["FromPort"] = perm["FromPort"]
                base["ToPort"] = perm["ToPort"]
            ok_port = perm.get("IpProtocol") == "tcp" and perm.get("FromPort") == port and perm.get("ToPort") == port
            extra = dict(base)
            extra_ranges = [r for r in perm.get("IpRanges", [])]
            extra_v6 = [r for r in perm.get("Ipv6Ranges", [])]
            extra_pl = [r for r in perm.get("PrefixListIds", [])]
            extra_pairs = [
                p for p in perm.get("UserIdGroupPairs", []) if not (ok_port and p.get("GroupId") == src)
            ]
            if extra_ranges:
                extra["IpRanges"] = [{"CidrIp": r["CidrIp"]} for r in extra_ranges]
            if extra_v6:
                extra["Ipv6Ranges"] = [{"CidrIpv6": r["CidrIpv6"]} for r in extra_v6]
            if extra_pl:
                extra["PrefixListIds"] = [{"PrefixListId": r["PrefixListId"]} for r in extra_pl]
            if extra_pairs:
                extra["UserIdGroupPairs"] = [{"GroupId": p["GroupId"]} for p in extra_pairs]
            if any(k in extra for k in ("IpRanges", "Ipv6Ranges", "PrefixListIds", "UserIdGroupPairs")):
                revoke.append(extra)
        if revoke:
            log(f"ec2: revoking {len(revoke)} out-of-band ingress rule(s) on {gid}")
            ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=revoke)
    for name in ("rds", "valkey"):
        g = by_id[sg_ids[name]]
        if g.get("IpPermissionsEgress"):
            log(f"ec2: revoking {len(g['IpPermissionsEgress'])} egress rule(s) on {name} security group")
            ec2.revoke_security_group_egress(GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])


def delete_policy(iam, arn):
    for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
        if not v["IsDefaultVersion"]:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    iam.delete_policy(PolicyArn=arn)


# ---------------------------------------------------------------------------
def data(ctx, batch_size):
    conn = ctx.pg()
    try:
        for attempt in range(1, 5):
            publish_outbox(ctx, conn)
            reconcile_s3(ctx, conn, batch_size)
            problems = verify_s3(ctx, conn)
            if not problems:
                break
            log(f"s3 verification attempt {attempt}: {problems[:5]}")
            time.sleep(1)
        else:
            log("WARNING: S3 archive did not fully converge (concurrent writers?)")
        for attempt in range(1, 4):
            changed = reconcile_dynamodb(ctx, conn)
            if not changed:
                break
        # Cache last so the entries carry the longest possible TTL.
        reconcile_valkey(ctx, conn)
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["control", "data"])
    ap.add_argument("--config", default="/workspace/config/config.json")
    ap.add_argument("--manifest", default="/workspace/submission/manifest.json")
    ap.add_argument("--audit-batch-size", type=int, default=100)
    args = ap.parse_args()
    ctx = Ctx(args.config, args.manifest)
    if args.command == "control":
        control(ctx)
    else:
        data(ctx, args.audit_batch_size)


if __name__ == "__main__":
    sys.exit(main())
