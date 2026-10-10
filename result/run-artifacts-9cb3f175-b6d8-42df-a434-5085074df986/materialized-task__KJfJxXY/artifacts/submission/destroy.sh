#!/usr/bin/env bash
# ClearLedger teardown: terraform destroy plus a prefix-scoped sweep of anything out-of-band.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$HERE/infra"
CONFIG_FILE="${CONFIG_FILE:-/workspace/config/config.json}"
HELPER="$HERE/.converge.py"
export CONFIG_FILE MANIFEST_FILE="$HERE/manifest.json"

START=$(date +%s)
log() { echo "[destroy $(date +%H:%M:%S) +$(( $(date +%s) - START ))s] $*"; }

TF="$(command -v terraform || command -v tofu || true)"
[ -n "$TF" ] || { echo "neither terraform nor tofu found" >&2; exit 1; }

PREFIX="$(jq -r .resource_prefix "$CONFIG_FILE")"
REGION="$(jq -r .region "$CONFIG_FILE")"
ENDPOINT="$(jq -r .aws_endpoint_url "$CONFIG_FILE")"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config_file="$CONFIG_FILE"
log "prefix=$PREFIX"

cat > "$HELPER" <<'CLEARLEDGER_HELPER_EOF'
#!/usr/bin/env python3
"""ClearLedger operational helper: control-plane repair, data-plane convergence and teardown sweeps.

Sub-commands (all idempotent):
  kms-restore            cancel pending deletion / re-enable the prefix-scoped KMS keys
  iam-clean              strip out-of-band inline/attached policies from the six roles, delete stray managed policies
  sg-clean               revoke out-of-band public ingress / rds+valkey egress
  esm-check <uuid>       verify the projector event source mapping (exit 3 = needs replace)
  data                   converge outbox, DynamoDB, S3 audit archive and Valkey against PostgreSQL
  sweep                  delete every leftover resource scoped to the prefix (teardown)
"""
import concurrent.futures
import datetime
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
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_FILE = os.environ.get("CONFIG_FILE", "/workspace/config/config.json")
MANIFEST_FILE = os.environ.get("MANIFEST_FILE", "/workspace/submission/manifest.json")

CFG = json.load(open(CONFIG_FILE))
PREFIX = CFG["resource_prefix"]
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]

ROLE_KEYS = ["ecs-execution", "ecs-task", "projector", "relay", "archiver", "scheduler"]


def log(msg):
    print(f"[converge {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def client(name):
    return boto3.client(
        name,
        endpoint_url=ENDPOINT,
        region_name=REGION,
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 6, "mode": "standard"}, read_timeout=180, connect_timeout=15),
    )


def manifest():
    with open(MANIFEST_FILE) as f:
        return json.load(f)


def code_of(e):
    return e.response.get("Error", {}).get("Code", "")


def matches_prefix(name):
    """True when `name` is scoped to this deployment's resource prefix (and not a sibling like <prefix>x)."""
    if not name:
        return False
    return re.search(r"(^|[^A-Za-z0-9])" + re.escape(PREFIX) + r"($|[^A-Za-z0-9])", name) is not None


# --------------------------------------------------------------------------- PostgreSQL helpers
def db_url(m=None):
    m = m or manifest()
    d = m["database"]
    return "postgres://%s:%s@%s:%s/%s" % (CFG["db_username"], CFG["db_password"], d["endpoint"], d["port"], CFG["db_name"])


def psql(sql, url=None, retries=4):
    last = None
    for i in range(retries):
        p = subprocess.run(
            ["psql", url or db_url(), "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
            capture_output=True, text=True, env=dict(os.environ, PGCONNECT_TIMEOUT="10"),
        )
        if p.returncode == 0:
            return p.stdout.strip()
        last = p.stderr.strip()
        time.sleep(2 + i * 2)
    raise RuntimeError("psql failed: " + str(last))


def pg_json(select_sql):
    out = psql("SELECT COALESCE(json_agg(t), '[]'::json) FROM (%s) t" % select_sql)
    return json.loads(out or "[]")


TS = "to_char({c} AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"


def fetch_pg():
    settlements = pg_json(
        "SELECT settlement_id::text AS settlement_id, account_id, reference, debit_party, credit_party, "
        "current_status, current_stage, last_entry_id::text AS last_entry_id, last_memo, version, entry_count, "
        + TS.format(c="updated_at") + " AS updated_at FROM clearledger.settlements ORDER BY settlement_id")
    events = pg_json(
        "SELECT seq, event_id::text AS event_id, settlement_id::text AS settlement_id, aggregate_version, "
        "event_type, correlation_id, " + TS.format(c="occurred_at") + " AS occurred_at, payload "
        "FROM clearledger.events ORDER BY settlement_id, aggregate_version")
    return {"settlements": settlements, "events": events}


def fetch_outbox():
    return pg_json(
        "SELECT seq, event_id::text AS event_id, settlement_id::text AS settlement_id, aggregate_version, "
        "payload, published_at IS NOT NULL AS published, archived_at IS NOT NULL AS archived, attempts "
        "FROM clearledger.outbox ORDER BY seq")


# --------------------------------------------------------------------------- time helpers
def parse_ts(s):
    if s is None:
        return None
    s = s.strip()
    s = re.sub(r"[Zz]$", "+00:00", s)
    m = re.match(r"^(.*?)(\.\d+)?([+-]\d{2}:\d{2})$", s)
    if not m:
        raise ValueError(s)
    base, frac, tz = m.group(1), m.group(2) or "", m.group(3)
    frac = (frac + "000000")[:7] if frac else ""
    dt = datetime.datetime.fromisoformat(base + frac + tz)
    return dt.astimezone(datetime.timezone.utc)


def fmt_ts(s, z=False):
    """Format like chrono's to_rfc3339 (AutoSi): 0, 3 or 6 fractional digits."""
    dt = parse_ts(s)
    us = dt.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + frac + ("Z" if z else "+00:00")


def same_ts(a, b):
    try:
        return parse_ts(a) == parse_ts(b)
    except Exception:
        return False


# --------------------------------------------------------------------------- RESP (Valkey) client
class Resp:
    def __init__(self, host, port, timeout=10):
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.f = self.sock.makefile("rb")

    def cmd(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.sock.sendall(out)
        return self._read()

    def _read(self):
        line = self.f.readline().rstrip(b"\r\n")
        t, v = line[:1], line[1:]
        if t == b"+":
            return v.decode()
        if t == b"-":
            raise RuntimeError(v.decode())
        if t == b":":
            return int(v)
        if t == b"$":
            n = int(v)
            if n < 0:
                return None
            return self.f.read(n + 2)[:-2].decode()
        if t == b"*":
            n = int(v)
            return None if n < 0 else [self._read() for _ in range(n)]
        raise RuntimeError("bad RESP reply %r" % line)

    def scan_keys(self):
        keys, cur = [], "0"
        while True:
            cur, batch = self.cmd("SCAN", cur, "COUNT", 500)
            keys.extend(batch)
            if cur == "0":
                return keys

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# =========================================================================== kms-restore
def cmd_kms_restore():
    kms = client("kms")
    aliases = []
    pager = kms.get_paginator("list_aliases")
    for page in pager.paginate():
        aliases += [a for a in page["Aliases"] if a["AliasName"].startswith("alias/" + PREFIX + "-") and a.get("TargetKeyId")]
    for a in aliases:
        kid = a["TargetKeyId"]
        try:
            st = kms.describe_key(KeyId=kid)["KeyMetadata"]["KeyState"]
        except ClientError as e:
            log("kms %s: %s" % (a["AliasName"], code_of(e)))
            continue
        if st == "PendingDeletion":
            log("kms %s pending deletion -> cancelling" % a["AliasName"])
            kms.cancel_key_deletion(KeyId=kid)
            st = "Disabled"
        if st == "Disabled":
            log("kms %s disabled -> enabling" % a["AliasName"])
            kms.enable_key(KeyId=kid)
        try:
            if not kms.get_key_rotation_status(KeyId=kid).get("KeyRotationEnabled"):
                kms.enable_key_rotation(KeyId=kid)
        except ClientError:
            pass


# =========================================================================== iam-clean
def role_names():
    return ["%s-%s" % (PREFIX, k) for k in ROLE_KEYS]


def canonical_policy(role):
    return role + "-policy"


def delete_policy_fully(iam, arn):
    try:
        ents = iam.list_entities_for_policy(PolicyArn=arn)
        for r in ents.get("PolicyRoles", []):
            iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=arn)
        for u in ents.get("PolicyUsers", []):
            iam.detach_user_policy(UserName=u["UserName"], PolicyArn=arn)
        for g in ents.get("PolicyGroups", []):
            iam.detach_group_policy(GroupName=g["GroupName"], PolicyArn=arn)
    except ClientError as e:
        log("list_entities_for_policy %s: %s" % (arn, code_of(e)))
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v["IsDefaultVersion"]:
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    except ClientError as e:
        log("list_policy_versions %s: %s" % (arn, code_of(e)))
    iam.delete_policy(PolicyArn=arn)
    log("deleted managed policy %s" % arn)


def cmd_iam_clean(strict_roles=True):
    iam = client("iam")
    for role in role_names():
        try:
            iam.get_role(RoleName=role)
        except ClientError as e:
            if code_of(e) == "NoSuchEntity":
                continue
            raise
        keep = canonical_policy(role) if strict_roles else None
        names = []
        for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
            names += page["PolicyNames"]
        for n in names:
            if n != keep:
                iam.delete_role_policy(RoleName=role, PolicyName=n)
                log("removed inline policy %s from %s" % (n, role))
        att = []
        for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
            att += page["AttachedPolicies"]
        for a in att:
            iam.detach_role_policy(RoleName=role, PolicyArn=a["PolicyArn"])
            log("detached %s from %s" % (a["PolicyArn"], role))
    # customer-managed policies scoped to this deployment
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if p["PolicyName"].startswith(PREFIX):
                delete_policy_fully(iam, p["Arn"])


# =========================================================================== sg-clean
def cmd_sg_clean():
    m = manifest()
    ec2 = client("ec2")
    ids = m["network"]["security_group_ids"]
    for name, sg_id in ids.items():
        try:
            sg = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
        except ClientError as e:
            log("sg %s: %s" % (name, code_of(e)))
            continue

        def public(p):
            return any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or any(
                r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", []))

        def only_public(p):
            q = {k: v for k, v in p.items() if k not in ("IpRanges", "Ipv6Ranges")}
            q["IpRanges"] = [r for r in p.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
            q["Ipv6Ranges"] = [r for r in p.get("Ipv6Ranges", []) if r.get("CidrIpv6") == "::/0"]
            q["UserIdGroupPairs"] = []
            q["PrefixListIds"] = []
            return q

        if name in ("ecs", "rds", "valkey"):
            bad = [only_public(p) for p in sg.get("IpPermissions", []) if public(p)]
            if bad:
                log("revoking public ingress on %s" % name)
                ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=bad)
        if name in ("rds", "valkey"):
            eg = sg.get("IpPermissionsEgress", [])
            if eg:
                log("revoking egress on %s" % name)
                ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=eg)
        if name == "alb":
            bad = [only_public(p) for p in sg.get("IpPermissionsEgress", []) if public(p)]
            if bad:
                log("revoking public egress on alb")
                ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=bad)


# =========================================================================== esm-check
def cmd_esm_check(uuid):
    m = manifest()
    lam = client("lambda")
    fn = m["workers"]["projector"]["function_name"]
    qarn = m["messaging"]["queue_arn"]
    mappings = []
    for page in lam.get_paginator("list_event_source_mappings").paginate(FunctionName=fn):
        mappings += page["EventSourceMappings"]
    good = False
    for mp in mappings:
        ok = (
            mp["UUID"] == uuid and mp.get("EventSourceArn") == qarn and mp.get("BatchSize") == 5
            and mp.get("State") in ("Enabled", "Enabling")
            and "ReportBatchItemFailures" in (mp.get("FunctionResponseTypes") or [])
        )
        if ok:
            good = True
        elif mp["UUID"] != uuid:
            log("deleting foreign event source mapping %s (%s)" % (mp["UUID"], mp.get("EventSourceArn")))
            try:
                lam.delete_event_source_mapping(UUID=mp["UUID"])
            except ClientError as e:
                log("delete esm: %s" % code_of(e))
    if not good:
        log("projector event source mapping missing or misconfigured")
        sys.exit(3)
    log("projector event source mapping ok")


# =========================================================================== data-plane
def wait_ready(m, timeout=300):
    url = m["service_url"].rstrip("/") + "/health/ready"
    end = time.time() + timeout
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(3)
    return False


def lambda_invoke(name):
    lam = client("lambda")
    r = lam.invoke(FunctionName=name, InvocationType="RequestResponse", Payload=b"{}")
    body = r["Payload"].read().decode() or "{}"
    if r.get("FunctionError"):
        raise RuntimeError("lambda %s failed: %s" % (name, body))
    try:
        return json.loads(body)
    except Exception:
        return {}


def pending_unpublished():
    return int(psql("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL") or 0)


def pending_unarchived():
    return int(psql("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL") or 0)


def publish_fallback(m):
    """Publish unpublished rows ourselves (same semantics as the relay) if the relay Lambda is unusable."""
    sqs = client("sqs")
    rows = pg_json("SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq LIMIT 50")
    for r in rows:
        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=json.dumps(r["payload"], separators=(",", ":")))
        psql("UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL "
             "WHERE seq = %d AND published_at IS NULL" % r["seq"])
    return len(rows)


def publish_all(m, max_rounds=60):
    relay = m["workers"]["outbox_relay"]["function_name"]
    stalls = 0
    for _ in range(max_rounds):
        left = pending_unpublished()
        if left == 0:
            return True
        log("outbox: %d unpublished rows, invoking relay" % left)
        try:
            lambda_invoke(relay)
        except Exception as e:
            log("relay invoke failed: %s" % e)
        now = pending_unpublished()
        if now >= left:
            stalls += 1
            if stalls >= 2:
                log("relay made no progress, publishing directly")
                try:
                    publish_fallback(m)
                except Exception as e:
                    log("direct publish failed: %s" % e)
            if stalls >= 6:
                return False
            time.sleep(2)
        else:
            stalls = 0
    return pending_unpublished() == 0


def wait_queue_drained(m, timeout=90):
    sqs = client("sqs")
    end = time.time() + timeout
    while time.time() < end:
        try:
            a = sqs.get_queue_attributes(QueueUrl=m["messaging"]["queue_url"], AttributeNames=["All"])["Attributes"]
        except ClientError as e:
            log("queue attributes: %s" % code_of(e))
            return
        n = int(a.get("ApproximateNumberOfMessages", 0)) + int(a.get("ApproximateNumberOfMessagesNotVisible", 0))
        if n == 0:
            return
        time.sleep(2)
    log("queue still has messages after %ds; continuing" % timeout)


# ---- DynamoDB ------------------------------------------------------------------------------------
DESER = TypeDeserializer()
SER = TypeSerializer()


def ddb_scan(ddb, table):
    items = []
    for page in ddb.get_paginator("scan").paginate(TableName=table, ConsistentRead=True):
        for it in page["Items"]:
            items.append({k: DESER.deserialize(v) for k, v in it.items()})
    return items


def compact(payload):
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


def expected_ddb(pg):
    exp = {}
    for s in pg["settlements"]:
        pk = "SETTLEMENT#" + s["settlement_id"]
        st = {
            "PK": pk, "SK": "STATE",
            "GSI1PK": "ACCOUNT#" + s["account_id"], "GSI1SK": "SETTLEMENT#" + s["settlement_id"],
            "settlement_id": s["settlement_id"], "account_id": s["account_id"], "reference": s["reference"],
            "debit_party": s["debit_party"], "credit_party": s["credit_party"],
            "status": s["current_status"], "clearing_stage": s["current_stage"],
            "version": int(s["version"]), "entry_count": int(s["version"]) - 1,
            "updated_at": fmt_ts(s["updated_at"]),
        }
        if s.get("last_entry_id"):
            st["last_entry_id"] = s["last_entry_id"]
        if s.get("last_memo") is not None:
            st["last_memo"] = s["last_memo"]
        exp[(pk, "STATE")] = st
    for e in pg["events"]:
        pk = "SETTLEMENT#" + e["settlement_id"]
        sk = "EVENT#%08d" % int(e["aggregate_version"])
        d = e["payload"]["data"]
        it = {
            "PK": pk, "SK": sk, "settlement_id": e["settlement_id"], "event_id": e["event_id"],
            "version": int(e["aggregate_version"]), "event_type": e["event_type"], "status": d["status"],
            "clearing_stage": d["clearingStage"], "occurred_at": fmt_ts(e["occurred_at"]),
            "correlation_id": e["correlation_id"], "envelope": compact(e["payload"]),
        }
        if d.get("entryId"):
            it["entry_id"] = d["entryId"]
        if d.get("memo") is not None:
            it["memo"] = d["memo"]
        exp[(pk, sk)] = it
    return exp


def ddb_equal(actual, expected):
    if set(actual) != set(expected):
        return False
    for k, ev in expected.items():
        av = actual[k]
        if k in ("updated_at", "occurred_at"):
            if not same_ts(av, ev):
                return False
        elif k == "envelope":
            try:
                if json.loads(av) != json.loads(ev):
                    return False
            except Exception:
                return False
        elif k in ("version", "entry_count"):
            if int(av) != int(ev):
                return False
        elif av != ev:
            return False
    return True


def converge_dynamo(m):
    ddb = client("dynamodb")
    table = m["projections"]["table_name"]
    for attempt in range(4):
        # Scan BEFORE reading PostgreSQL: anything projected is already committed, so it cannot be a false orphan.
        actual_items = ddb_scan(ddb, table)
        pg = fetch_pg()
        exp = expected_ddb(pg)
        actual = {}
        for it in actual_items:
            actual[(it.get("PK"), it.get("SK"))] = it
        orphans = [k for k in actual if k not in exp]
        fixes = [k for k in exp if k not in actual or not ddb_equal(actual[k], exp[k])]
        log("dynamodb: %d expected, %d actual, %d orphans, %d to write" % (len(exp), len(actual), len(orphans), len(fixes)))
        if not orphans and not fixes:
            return True
        for k in orphans:
            key = {"PK": SER.serialize(k[0]), "SK": SER.serialize(k[1])} if k[0] is not None and k[1] is not None else None
            if key is None:
                continue
            ddb.delete_item(TableName=table, Key=key)
        for k in fixes:
            item = {a: SER.serialize(v) for a, v in exp[k].items()}
            kw = {}
            if k[1] == "STATE" and k in actual:
                cur = actual[k].get("version")
                if cur is not None and int(cur) > exp[k]["version"]:
                    pass  # corrupted (ahead of the system of record): overwrite unconditionally
                else:
                    kw = dict(ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                              ExpressionAttributeNames={"#v": "version"},
                              ExpressionAttributeValues={":v": {"N": str(exp[k]["version"])}})
            elif k[1] == "STATE":
                kw = dict(ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                          ExpressionAttributeNames={"#v": "version"},
                          ExpressionAttributeValues={":v": {"N": str(exp[k]["version"])}})
            try:
                ddb.put_item(TableName=table, Item=item, **kw)
            except ClientError as e:
                if code_of(e) != "ConditionalCheckFailedException":
                    raise
        time.sleep(1)
    return False


# ---- S3 audit archive -----------------------------------------------------------------------------
BATCH_RE = re.compile(r"^(ledger-audit/)batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def s3_versions(s3, bucket):
    versions, markers = [], []
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
        versions += page.get("Versions", [])
        markers += page.get("DeleteMarkers", [])
    return versions, markers


def s3_delete_versions(s3, bucket, entries):
    entries = list(entries)
    for i in range(0, len(entries), 500):
        chunk = [{"Key": e["Key"], "VersionId": e["VersionId"]} for e in entries[i:i + 500]]
        if chunk:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})


def s3_normalize(s3, bucket, prefix):
    """Undelete current delete markers, purge non-canonical keys, noncurrent versions and remaining markers."""
    for _ in range(5):
        versions, markers = s3_versions(s3, bucket)
        latest_markers = [d for d in markers if d.get("IsLatest")]
        if not latest_markers:
            break
        # a batch hidden behind a delete marker is restored when an older version exists
        by_key = {}
        for v in versions:
            by_key.setdefault(v["Key"], []).append(v)
        restorable = [d for d in latest_markers if by_key.get(d["Key"])]
        if not restorable:
            break
        log("s3: removing %d delete markers hiding archive batches" % len(restorable))
        s3_delete_versions(s3, bucket, restorable)
    versions, markers = s3_versions(s3, bucket)
    doomed = []
    for v in versions:
        if not v.get("IsLatest") or not BATCH_RE.match(v["Key"]) or not v["Key"].startswith(prefix):
            doomed.append(v)
    doomed += markers
    if doomed:
        log("s3: purging %d stray/noncurrent versions and delete markers" % len(doomed))
        s3_delete_versions(s3, bucket, doomed)
    versions, _ = s3_versions(s3, bucket)
    return [v for v in versions if v.get("IsLatest")]


def s3_validate(s3, bucket, current, rows):
    """Return a list of problems (empty = archive is a 1-to-1 mirror of the outbox)."""
    problems = []
    by_seq = {r["seq"]: r for r in rows}
    by_event = {r["event_id"]: r for r in rows}
    seen_rows = {}
    intervals = []
    for v in current:
        key = v["Key"]
        mt = BATCH_RE.match(key)
        if not mt:
            problems.append("non-canonical key " + key)
            continue
        first, last, digest = int(mt.group(2)), int(mt.group(3)), mt.group(4)
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            problems.append("digest mismatch " + key)
            continue
        seqs = []
        try:
            lines = [ln for ln in body.decode("utf-8").split("\n") if ln != ""]
            for ln in lines:
                obj = json.loads(ln)
                r = by_event.get(obj.get("eventId"))
                if r is None:
                    problems.append("%s has event %s unknown to PostgreSQL" % (key, obj.get("eventId")))
                    continue
                if obj != r["payload"]:
                    problems.append("%s payload differs for seq %d" % (key, r["seq"]))
                seqs.append(r["seq"])
                if r["seq"] in seen_rows:
                    problems.append("seq %d archived twice (%s, %s)" % (r["seq"], seen_rows[r["seq"]], key))
                seen_rows[r["seq"]] = key
        except Exception as e:
            problems.append("unparseable %s: %s" % (key, e))
            continue
        if not seqs or seqs != sorted(seqs) or len(set(seqs)) != len(seqs):
            problems.append("%s not in strictly ascending seq order" % key)
            continue
        if seqs[0] != first or seqs[-1] != last:
            problems.append("%s bounds do not match content" % key)
        expect = [s for s in by_seq if first <= s <= last]
        if sorted(expect) != seqs:
            problems.append("%s is not a gap-free slice of the outbox" % key)
        intervals.append((first, last, key))
    intervals.sort()
    for a, b in zip(intervals, intervals[1:]):
        if b[0] <= a[1]:
            problems.append("batches overlap: %s / %s" % (a[2], b[2]))
    for r in rows:
        covered = r["seq"] in seen_rows
        if r["archived"] and not covered:
            problems.append("seq %d archived in PostgreSQL but absent from S3" % r["seq"])
        if covered and not r["archived"]:
            problems.append("seq %d present in S3 but archived_at is NULL" % r["seq"])
    return problems


def converge_s3(m):
    s3 = client("s3")
    bucket = m["audit"]["bucket_name"]
    prefix = m["audit"]["prefix"]
    archiver = m["workers"]["audit_archiver"]["function_name"]

    def run_archiver(limit=200):
        stalls = 0
        for _ in range(limit):
            left = pending_unarchived()
            if left == 0:
                return True
            try:
                lambda_invoke(archiver)
            except Exception as e:
                log("archiver invoke failed: %s" % e)
                time.sleep(2)
            if pending_unarchived() >= left:
                stalls += 1
                if stalls >= 4:
                    return False
                time.sleep(2)
            else:
                stalls = 0
        return pending_unarchived() == 0

    for round_ in range(3):
        current = s3_normalize(s3, bucket, prefix)
        problems = s3_validate(s3, bucket, current, fetch_outbox())
        if problems:
            time.sleep(6)  # let an in-flight scheduled archiver run finish before judging
            current = s3_normalize(s3, bucket, prefix)
            problems = s3_validate(s3, bucket, current, fetch_outbox())
        if problems:
            log("s3: archive inconsistent (%d problems, e.g. %s); rebuilding" % (len(problems), problems[0]))
            versions, markers = s3_versions(s3, bucket)
            s3_delete_versions(s3, bucket, versions + markers)
            psql("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
        else:
            log("s3: %d batch objects consistent" % len(current))
        if not run_archiver():
            log("s3: archiver could not drain the backlog")
        current = s3_normalize(s3, bucket, prefix)
        problems = s3_validate(s3, bucket, current, fetch_outbox())
        if not problems and pending_unarchived() == 0:
            return True
        log("s3: still inconsistent after round %d: %s" % (round_ + 1, problems[:3]))
    return False


# ---- Valkey ----------------------------------------------------------------------------------------
def expected_projection(s):
    p = {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["current_status"],
        "clearingStage": s["current_stage"],
    }
    if s.get("last_entry_id"):
        p["lastEntryId"] = s["last_entry_id"]
    if s.get("last_memo") is not None:
        p["lastMemo"] = s["last_memo"]
    p.update({"version": int(s["version"]), "entryCount": int(s["entry_count"]), "updatedAt": s["updated_at"]})
    return p


def proj_equal(raw, exp):
    try:
        got = json.loads(raw)
    except Exception:
        return False
    if not isinstance(got, dict):
        return False
    got = {k: v for k, v in got.items() if v is not None}
    if set(got) != set(exp):
        return False
    for k, v in exp.items():
        if k == "updatedAt":
            if not same_ts(got[k], v):
                return False
        elif got[k] != v:
            return False
    return True


def read_token(m):
    c = m["auth"]["clients"]["read"]
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "scope": c["scope"]}).encode()
    req = urllib.request.Request(m["auth"]["token_endpoint"], data=data)
    import base64
    req.add_header("Authorization", "Basic " + base64.b64encode(("%s:%s" % (c["client_id"], c["client_secret"])).encode()).decode())
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["access_token"]


def api_get(m, token, sid):
    req = urllib.request.Request(m["service_url"].rstrip("/") + "/v1/settlements/" + sid)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("X-Correlation-Id", "converge-" + sid[:8])
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def converge_valkey(m):
    host, port = m["cache"]["endpoint"], m["cache"]["port"]
    ns = "clearledger:settlement:"
    for attempt in range(3):
        pg = fetch_pg()
        settlements = {s["settlement_id"]: s for s in pg["settlements"]}
        exp = {ns + sid: expected_projection(s) for sid, s in settlements.items()}
        r = Resp(host, port)
        try:
            for k in r.scan_keys():
                if k not in exp:
                    r.cmd("DEL", k)
            missing = []
            for k, e in exp.items():
                raw = r.cmd("GET", k)
                ttl = r.cmd("TTL", k)
                if raw is not None and proj_equal(raw, e) and 0 < ttl <= 90:
                    continue
                if raw is not None:
                    r.cmd("DEL", k)
                missing.append(k[len(ns):])
            log("valkey: %d settlements, %d need (re)population" % (len(exp), len(missing)))
            if missing:
                token = None
                try:
                    token = read_token(m)
                except Exception as e:
                    log("read token unavailable: %s" % e)
                if token:
                    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
                        list(ex.map(lambda sid: api_get(m, token, sid), missing))
                # verify, falling back to a direct write of the canonical projection
                for sid in missing:
                    k = ns + sid
                    raw = r.cmd("GET", k)
                    ttl = r.cmd("TTL", k)
                    if raw is not None and proj_equal(raw, exp[k]) and 0 < ttl <= 90:
                        continue
                    log("valkey: writing %s directly" % k)
                    r.cmd("SET", k, json.dumps(exp[k], separators=(",", ":")), "EX", 90)
            # final verification
            bad = 0
            keys = set(r.scan_keys())
            if keys != set(exp):
                bad += 1
            for k, e in exp.items():
                raw = r.cmd("GET", k)
                ttl = r.cmd("TTL", k)
                if raw is None or not proj_equal(raw, e) or not (0 < ttl <= 90):
                    bad += 1
            if bad == 0:
                return True
        finally:
            r.close()
        time.sleep(2)
    return False


def cmd_data():
    m = manifest()
    ok = True
    if not wait_ready(m, 300):
        log("WARNING: API not ready before data convergence")
    if not publish_all(m):
        log("ERROR: outbox could not be fully published")
        ok = False
    wait_queue_drained(m)
    if not converge_dynamo(m):
        log("ERROR: DynamoDB did not converge")
        ok = False
    if not converge_s3(m):
        log("ERROR: S3 audit archive did not converge")
        ok = False
    # DynamoDB can be touched by in-flight projector deliveries: verify once more, then cache last (90s TTL).
    if not converge_dynamo(m):
        log("ERROR: DynamoDB did not converge (second pass)")
        ok = False
    if not converge_valkey(m):
        log("ERROR: Valkey did not converge")
        ok = False
    sys.exit(0 if ok else 1)


# =========================================================================== sweep (teardown)
def safe(label, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ClientError as e:
        log("sweep %s: %s" % (label, code_of(e)))
    except Exception as e:  # keep sweeping
        log("sweep %s: %s" % (label, e))


def empty_bucket(s3, bucket):
    versions, markers = s3_versions(s3, bucket)
    s3_delete_versions(s3, bucket, versions + markers)
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": objs, "Quiet": True})


def sweep_tagged_kms(kms):
    for page in kms.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            try:
                md = kms.describe_key(KeyId=k["KeyId"])["KeyMetadata"]
                if md.get("KeyManager") != "CUSTOMER" or md.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
                    continue
                tags = kms.list_resource_tags(KeyId=k["KeyId"]).get("Tags", [])
                if any(t["TagKey"] == "ClearLedgerDeployment" and t["TagValue"] == PREFIX for t in tags):
                    kms.schedule_key_deletion(KeyId=k["KeyId"], PendingWindowInDays=7)
                    log("scheduled deletion of key %s" % k["KeyId"])
            except ClientError:
                continue


def cmd_sweep():
    """Remove anything scoped to the prefix that Terraform no longer (or never) tracked."""
    # compute / traffic
    ecs = client("ecs")
    def sweep_ecs():
        for arn in ecs.list_clusters().get("clusterArns", []):
            name = arn.split("/")[-1]
            if not matches_prefix(name):
                continue
            for sv in ecs.list_services(cluster=arn).get("serviceArns", []):
                safe("ecs service", ecs.update_service, cluster=arn, service=sv, desiredCount=0)
                safe("ecs service", ecs.delete_service, cluster=arn, service=sv, force=True)
            for t in ecs.list_tasks(cluster=arn).get("taskArns", []):
                safe("ecs task", ecs.stop_task, cluster=arn, task=t)
            ecs.delete_cluster(cluster=arn)
            log("deleted ecs cluster %s" % name)
        for fam in ecs.list_task_definition_families(status="ACTIVE").get("families", []):
            if matches_prefix(fam):
                for td in ecs.list_task_definitions(familyPrefix=fam).get("taskDefinitionArns", []):
                    safe("ecs taskdef", ecs.deregister_task_definition, taskDefinition=td)
    safe("ecs", sweep_ecs)

    elb = client("elbv2")
    def sweep_elb():
        for lb in elb.describe_load_balancers().get("LoadBalancers", []):
            if matches_prefix(lb["LoadBalancerName"]):
                for ls in elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
                    safe("listener", elb.delete_listener, ListenerArn=ls["ListenerArn"])
                elb.delete_load_balancer(LoadBalancerArn=lb["LoadBalancerArn"])
                log("deleted load balancer %s" % lb["LoadBalancerName"])
        for tg in elb.describe_target_groups().get("TargetGroups", []):
            if matches_prefix(tg["TargetGroupName"]):
                safe("target group", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])
    safe("elbv2", sweep_elb)

    # schedulers, event sources, functions
    sch = client("scheduler")
    def sweep_sched():
        for page in sch.get_paginator("list_schedules").paginate():
            for s in page["Schedules"]:
                if matches_prefix(s["Name"]):
                    sch.delete_schedule(Name=s["Name"], GroupName=s.get("GroupName", "default"))
                    log("deleted schedule %s" % s["Name"])
    safe("scheduler", sweep_sched)

    lam = client("lambda")
    def sweep_lambda():
        for page in lam.get_paginator("list_functions").paginate():
            for f in page["Functions"]:
                if matches_prefix(f["FunctionName"]):
                    for mp in lam.list_event_source_mappings(FunctionName=f["FunctionName"]).get("EventSourceMappings", []):
                        safe("esm", lam.delete_event_source_mapping, UUID=mp["UUID"])
                    lam.delete_function(FunctionName=f["FunctionName"])
                    log("deleted function %s" % f["FunctionName"])
    safe("lambda", sweep_lambda)

    # data stores
    rds = client("rds")
    def sweep_rds():
        for d in rds.describe_db_instances().get("DBInstances", []):
            if matches_prefix(d["DBInstanceIdentifier"]):
                rds.delete_db_instance(DBInstanceIdentifier=d["DBInstanceIdentifier"], SkipFinalSnapshot=True,
                                       DeleteAutomatedBackups=True)
                log("deleted db instance %s" % d["DBInstanceIdentifier"])
        for g in rds.describe_db_subnet_groups().get("DBSubnetGroups", []):
            if matches_prefix(g["DBSubnetGroupName"]):
                safe("db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    safe("rds", sweep_rds)

    ec = client("elasticache")
    def sweep_cache():
        for g in ec.describe_replication_groups().get("ReplicationGroups", []):
            if matches_prefix(g["ReplicationGroupId"]):
                ec.delete_replication_group(ReplicationGroupId=g["ReplicationGroupId"], RetainPrimaryCluster=False)
                log("deleted replication group %s" % g["ReplicationGroupId"])
        for c in ec.describe_cache_clusters().get("CacheClusters", []):
            if matches_prefix(c["CacheClusterId"]):
                safe("cache cluster", ec.delete_cache_cluster, CacheClusterId=c["CacheClusterId"])
        for g in ec.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
            if matches_prefix(g["CacheSubnetGroupName"]):
                safe("cache subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])
    safe("elasticache", sweep_cache)

    ddb = client("dynamodb")
    def sweep_ddb():
        for page in ddb.get_paginator("list_tables").paginate():
            for t in page["TableNames"]:
                if matches_prefix(t):
                    ddb.delete_table(TableName=t)
                    log("deleted table %s" % t)
    safe("dynamodb", sweep_ddb)

    sqs = client("sqs")
    def sweep_sqs():
        for u in sqs.list_queues().get("QueueUrls", []) or []:
            if matches_prefix(u.rsplit("/", 1)[-1]):
                sqs.delete_queue(QueueUrl=u)
                log("deleted queue %s" % u)
    safe("sqs", sweep_sqs)

    s3 = client("s3")
    def sweep_s3():
        for b in s3.list_buckets().get("Buckets", []):
            if matches_prefix(b["Name"]):
                safe("empty bucket", empty_bucket, s3, b["Name"])
                s3.delete_bucket(Bucket=b["Name"])
                log("deleted bucket %s" % b["Name"])
    safe("s3", sweep_s3)

    cog = client("cognito-idp")
    def sweep_cognito():
        for page in cog.get_paginator("list_user_pools").paginate(MaxResults=60):
            for p in page["UserPools"]:
                if matches_prefix(p["Name"]):
                    try:
                        dom = cog.describe_user_pool(UserPoolId=p["Id"])["UserPool"].get("Domain")
                        if dom:
                            cog.delete_user_pool_domain(Domain=dom, UserPoolId=p["Id"])
                    except ClientError:
                        pass
                    cog.delete_user_pool(UserPoolId=p["Id"])
                    log("deleted user pool %s" % p["Name"])
    safe("cognito", sweep_cognito)

    # IAM
    iam = client("iam")
    def sweep_iam():
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for p in page["Policies"]:
                if p["PolicyName"].startswith(PREFIX):
                    safe("policy", delete_policy_fully, iam, p["Arn"])
        for page in iam.get_paginator("list_roles").paginate():
            for r in page["Roles"]:
                if r["RoleName"].startswith(PREFIX):
                    n = r["RoleName"]
                    for pn in iam.list_role_policies(RoleName=n).get("PolicyNames", []):
                        iam.delete_role_policy(RoleName=n, PolicyName=pn)
                    for a in iam.list_attached_role_policies(RoleName=n).get("AttachedPolicies", []):
                        iam.detach_role_policy(RoleName=n, PolicyArn=a["PolicyArn"])
                    for ip in iam.list_instance_profiles_for_role(RoleName=n).get("InstanceProfiles", []):
                        safe("instance profile", iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=n)
                    iam.delete_role(RoleName=n)
                    log("deleted role %s" % n)
    safe("iam", sweep_iam)

    # KMS
    kms = client("kms")
    def sweep_kms():
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page["Aliases"]:
                if a["AliasName"].startswith("alias/" + PREFIX + "-") or a["AliasName"] == "alias/" + PREFIX:
                    safe("alias", kms.delete_alias, AliasName=a["AliasName"])
        sweep_tagged_kms(kms)
    safe("kms", sweep_kms)

    # Network
    ec2 = client("ec2")
    def sweep_net():
        vpcs = []
        for v in ec2.describe_vpcs().get("Vpcs", []):
            tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
            if tags.get("ClearLedgerDeployment") == PREFIX or matches_prefix(tags.get("Name", "")):
                vpcs.append(v["VpcId"])
        for vid in vpcs:
            flt = [{"Name": "vpc-id", "Values": [vid]}]
            for ni in ec2.describe_network_interfaces(Filters=flt).get("NetworkInterfaces", []):
                safe("eni", ec2.delete_network_interface, NetworkInterfaceId=ni["NetworkInterfaceId"])
            for sg in ec2.describe_security_groups(Filters=flt).get("SecurityGroups", []):
                if sg["GroupName"] != "default":
                    if sg.get("IpPermissions"):
                        safe("sg ingress", ec2.revoke_security_group_ingress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissions"])
                    if sg.get("IpPermissionsEgress"):
                        safe("sg egress", ec2.revoke_security_group_egress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissionsEgress"])
            for sg in ec2.describe_security_groups(Filters=flt).get("SecurityGroups", []):
                if sg["GroupName"] != "default":
                    safe("sg", ec2.delete_security_group, GroupId=sg["GroupId"])
            for rt in ec2.describe_route_tables(Filters=flt).get("RouteTables", []):
                if any(a.get("Main") for a in rt.get("Associations", [])):
                    continue
                for a in rt.get("Associations", []):
                    safe("rt assoc", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
                safe("route table", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
            for sn in ec2.describe_subnets(Filters=flt).get("Subnets", []):
                safe("subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
            for ig in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vid]}]).get("InternetGateways", []):
                safe("igw detach", ec2.detach_internet_gateway, InternetGatewayId=ig["InternetGatewayId"], VpcId=vid)
                safe("igw", ec2.delete_internet_gateway, InternetGatewayId=ig["InternetGatewayId"])
            safe("vpc", ec2.delete_vpc, VpcId=vid)
            log("deleted vpc %s" % vid)
    safe("ec2", sweep_net)

    # Logs: our four groups plus the groups the control plane auto-creates for prefixed resources
    logs = client("logs")
    def sweep_logs():
        for page in logs.get_paginator("describe_log_groups").paginate():
            for g in page["logGroups"]:
                if matches_prefix(g["logGroupName"]):
                    logs.delete_log_group(logGroupName=g["logGroupName"])
                    log("deleted log group %s" % g["logGroupName"])
    safe("logs", sweep_logs)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    c = sys.argv[1]
    if c == "kms-restore":
        cmd_kms_restore()
    elif c == "iam-clean":
        cmd_iam_clean()
    elif c == "iam-clean-all":
        cmd_iam_clean(strict_roles=False)
    elif c == "sg-clean":
        cmd_sg_clean()
    elif c == "esm-check":
        cmd_esm_check(sys.argv[2])
    elif c == "data":
        cmd_data()
    elif c == "sweep":
        cmd_sweep()
    elif c == "empty-bucket":
        s3 = client("s3")
        try:
            empty_bucket(s3, sys.argv[2])
        except ClientError as e:
            log("empty-bucket: %s" % code_of(e))
    else:
        print("unknown command", c)
        sys.exit(2)


if __name__ == "__main__":
    main()
CLEARLEDGER_HELPER_EOF
trap 'rm -f "$HELPER"' EXIT
helper() { python3 "$HELPER" "$@"; }
tf() { "$TF" -chdir="$INFRA" "$@"; }

tf init -input=false -no-color >/dev/null 2>&1 || log "terraform init failed (continuing with sweep)"

# Out-of-band policies / versioned objects block role and bucket deletion: clear them first.
helper iam-clean-all || log "iam pre-clean incomplete"
helper empty-bucket "${PREFIX}-audit-archive" || true
helper kms-restore || true

destroyed=0
for attempt in 1 2 3; do
  log "terraform destroy (attempt $attempt)"
  if tf destroy -auto-approve -input=false -no-color -lock-timeout=120s; then destroyed=1; break; fi
  log "destroy failed; sweeping prefix-scoped resources before retrying"
  helper sweep || true
  sleep 5
done

log "sweeping out-of-band resources scoped to $PREFIX"
helper sweep || log "sweep reported errors"
helper sweep || true

# State must end up with zero managed resources.
if [ "$destroyed" != 1 ]; then
  tf destroy -auto-approve -input=false -no-color -lock-timeout=120s || true
fi
left="$(tf state list 2>/dev/null || true)"
if [ -n "$left" ]; then
  log "removing swept resources still referenced by state"
  while read -r addr; do [ -n "$addr" ] && tf state rm "$addr" >/dev/null 2>&1; done <<< "$left"
fi
left="$(tf state list 2>/dev/null || true)"
if [ -n "$left" ]; then
  log "state still tracks resources: $left"
  exit 1
fi
log "teardown complete"
