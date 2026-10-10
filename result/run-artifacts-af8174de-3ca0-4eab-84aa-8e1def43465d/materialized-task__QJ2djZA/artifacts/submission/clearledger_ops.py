#!/usr/bin/env python3
"""ClearLedger operational helper used by deploy.sh.

Subcommands:
  preflight  <config.json>                 repair control-plane state Terraform cannot fix alone
                                           (KMS keys pending deletion / disabled)
  iam        <config.json> <outputs.json>  strip out-of-band IAM policies from the six roles
  schema-wait <config.json> <outputs.json> wait until PostgreSQL accepts connections
  reconcile  <config.json> <outputs.json>  converge outbox, SQS, DynamoDB, S3 archive and Valkey
                                           against PostgreSQL (the system of record)

All AWS calls go to the configured endpoint explicitly.
"""
import hashlib
import json
import re
import sys
import time
from collections import OrderedDict

import boto3
from botocore.config import Config


def log(msg):
    print(f"[clearledger-ops] {msg}", flush=True)


def load(path):
    with open(path) as fh:
        return json.load(fh)


def client(cfg, service):
    return boto3.client(
        service,
        endpoint_url=cfg["aws_endpoint_url"],
        region_name=cfg["region"],
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 8, "mode": "standard"}, connect_timeout=10, read_timeout=120),
    )


# ---------------------------------------------------------------------------
# Canonical serialization (matches the Rust services' serde struct order)
# ---------------------------------------------------------------------------

ENVELOPE_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
                  "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId",
              "status", "clearingStage", "memo"]


def canonical_envelope(payload):
    env = OrderedDict()
    for k in ENVELOPE_ORDER:
        if k == "data":
            data = OrderedDict()
            src = payload.get("data") or {}
            for dk in DATA_ORDER:
                if src.get(dk) is not None:
                    data[dk] = src[dk]
            env["data"] = data
        elif k in payload and payload[k] is not None:
            env[k] = payload[k]
    return json.dumps(env, separators=(",", ":"), ensure_ascii=False)


def rfc3339_offset(ts):
    """chrono to_rfc3339() style (+00:00) from a chrono Z-suffixed timestamp."""
    if ts.endswith("Z"):
        return ts[:-1] + "+00:00"
    return ts


def projection_json(st):
    out = OrderedDict()
    out["settlementId"] = st["settlement_id"]
    out["accountId"] = st["account_id"]
    out["reference"] = st["reference"]
    out["debitParty"] = st["debit_party"]
    out["creditParty"] = st["credit_party"]
    out["status"] = st["status"]
    out["clearingStage"] = st["clearing_stage"]
    if st.get("last_entry_id") is not None:
        out["lastEntryId"] = st["last_entry_id"]
    if st.get("last_memo") is not None:
        out["lastMemo"] = st["last_memo"]
    out["version"] = st["version"]
    out["entryCount"] = st["entry_count"]
    out["updatedAt"] = st["updated_at_z"]
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False)


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

def pg_connect(cfg, out, timeout=240):
    import psycopg2
    db = out["database"]
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            conn = psycopg2.connect(host=db["endpoint"], port=db["port"], dbname=cfg["db_name"],
                                    user=cfg["db_username"], password=cfg["db_password"], connect_timeout=5)
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(3)
    raise SystemExit(f"PostgreSQL not reachable: {type(last).__name__}")


# ---------------------------------------------------------------------------
# preflight: KMS
# ---------------------------------------------------------------------------

def cmd_preflight(cfg):
    kms = client(cfg, "kms")
    prefix = cfg["resource_prefix"]
    key_ids = set()
    try:
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page.get("Aliases", []):
                if a.get("AliasName", "").startswith(f"alias/{prefix}-") and a.get("TargetKeyId"):
                    key_ids.add(a["TargetKeyId"])
        for page in kms.get_paginator("list_keys").paginate():
            for k in page.get("Keys", []):
                try:
                    tags = kms.list_resource_tags(KeyId=k["KeyId"]).get("Tags", [])
                except Exception:  # noqa: BLE001
                    continue
                if any(t.get("TagKey") == "ClearLedgerDeployment" and t.get("TagValue") == prefix for t in tags):
                    key_ids.add(k["KeyId"])
    except Exception as exc:  # noqa: BLE001
        log(f"kms discovery skipped: {exc}")
        return
    for kid in sorted(key_ids):
        try:
            meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        except Exception:  # noqa: BLE001
            continue
        state = meta.get("KeyState")
        if state == "PendingDeletion":
            log(f"cancelling scheduled deletion of KMS key {kid}")
            kms.cancel_key_deletion(KeyId=kid)
            state = "Disabled"
        if state == "Disabled":
            log(f"re-enabling KMS key {kid}")
            kms.enable_key(KeyId=kid)
        try:
            if not kms.get_key_rotation_status(KeyId=kid).get("KeyRotationEnabled"):
                kms.enable_key_rotation(KeyId=kid)
        except Exception:  # noqa: BLE001
            pass


# ---------------------------------------------------------------------------
# IAM out-of-band policy cleanup
# ---------------------------------------------------------------------------

def cmd_iam(cfg, out):
    iam = client(cfg, "iam")
    prefix = cfg["resource_prefix"]
    roles = {k: v.rsplit("/", 1)[-1] for k, v in out["iam"].items()}
    for key, role in roles.items():
        canonical = f"{role}-policy"
        try:
            names = iam.list_role_policies(RoleName=role).get("PolicyNames", [])
        except Exception as exc:  # noqa: BLE001
            log(f"iam: cannot list inline policies of {role}: {exc}")
            continue
        for name in names:
            if name != canonical:
                log(f"iam: removing out-of-band inline policy {name} from {role}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
        for ap in iam.list_attached_role_policies(RoleName=role).get("AttachedPolicies", []):
            log(f"iam: detaching out-of-band managed policy {ap['PolicyArn']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=ap["PolicyArn"])
    # Delete unattached prefix-scoped customer-managed policies.
    try:
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for pol in page.get("Policies", []):
                if not pol["PolicyName"].startswith(prefix):
                    continue
                arn = pol["Arn"]
                ents = iam.list_entities_for_policy(PolicyArn=arn)
                if ents.get("PolicyRoles") or ents.get("PolicyUsers") or ents.get("PolicyGroups"):
                    continue
                for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
                    if not v.get("IsDefaultVersion"):
                        iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
                log(f"iam: deleting unattached policy {arn}")
                iam.delete_policy(PolicyArn=arn)
    except Exception as exc:  # noqa: BLE001
        log(f"iam: managed policy sweep skipped: {exc}")


def cmd_schema_wait(cfg, out):
    conn = pg_connect(cfg, out)
    conn.close()
    log("PostgreSQL is reachable")


# ---------------------------------------------------------------------------
# reconcile
# ---------------------------------------------------------------------------

class Reconciler:
    def __init__(self, cfg, out):
        self.cfg = cfg
        self.out = out
        self.sqs = client(cfg, "sqs")
        self.lmb = client(cfg, "lambda")
        self.ddb = client(cfg, "dynamodb")
        self.s3 = client(cfg, "s3")
        self.table = out["projections"]["table_name"]
        self.bucket = out["audit"]["bucket_name"]
        self.prefix = out["audit"]["prefix"]
        self.queue_url = out["messaging"]["queue_url"]
        self.conn = pg_connect(cfg, out)
        self.conn.autocommit = False

    # -- PostgreSQL helpers -------------------------------------------------
    def q(self, sql, args=None):
        with self.conn.cursor() as cur:
            cur.execute(sql, args)
            rows = cur.fetchall() if cur.description else []
        self.conn.commit()
        return rows

    # -- outbox ---------------------------------------------------------------
    def repair_outbox(self):
        """Every event must have exactly one mirrored outbox row."""
        missing = self.q("""
            SELECT e.event_id, e.settlement_id, e.aggregate_version, e.correlation_id, e.payload::text
              FROM clearledger.events e
              LEFT JOIN clearledger.outbox o ON o.event_id = e.event_id
             WHERE o.event_id IS NULL
             ORDER BY e.settlement_id, e.aggregate_version""")
        if not missing:
            return
        log(f"outbox: restoring {len(missing)} missing outbox rows")
        with self.conn.cursor() as cur:
            for ev_id, sid, ver, cid, payload in missing:
                cur.execute("SAVEPOINT sp")
                try:
                    cur.execute("""INSERT INTO clearledger.outbox (event_id, settlement_id, aggregate_version, correlation_id, payload)
                                   VALUES (%s, %s, %s, %s, %s::jsonb)""", (ev_id, sid, ver, cid, payload))
                except Exception:  # noqa: BLE001
                    cur.execute("ROLLBACK TO SAVEPOINT sp")
                    cur.execute("SET LOCAL session_replication_role = replica")
                    cur.execute("""INSERT INTO clearledger.outbox (event_id, settlement_id, aggregate_version, correlation_id, payload)
                                   VALUES (%s, %s, %s, %s, %s::jsonb)""", (ev_id, sid, ver, cid, payload))
                    cur.execute("SET LOCAL session_replication_role = origin")
                cur.execute("RELEASE SAVEPOINT sp")
        self.conn.commit()

    def unpublished(self):
        return self.q("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")[0][0]

    def publish_outbox(self):
        fn = self.out["workers"]["outbox_relay"]["function_name"]
        for _ in range(40):
            n = self.unpublished()
            if n == 0:
                return
            log(f"outbox: {n} unpublished rows, invoking {fn}")
            try:
                resp = self.lmb.invoke(FunctionName=fn, InvocationType="RequestResponse", Payload=b"{}")
                if resp.get("FunctionError"):
                    log("outbox: relay reported an error; falling back to direct publish")
                    break
            except Exception as exc:  # noqa: BLE001
                log(f"outbox: relay invoke failed ({type(exc).__name__}); falling back to direct publish")
                break
            if self.unpublished() >= n:
                break
        # Direct publish fallback (same envelope serialization as the relay).
        with self.conn.cursor() as cur:
            cur.execute("""SELECT seq, payload::text FROM clearledger.outbox
                            WHERE published_at IS NULL ORDER BY seq FOR UPDATE SKIP LOCKED""")
            rows = cur.fetchall()
            for seq, payload in rows:
                body = canonical_envelope(json.loads(payload))
                self.sqs.send_message(QueueUrl=self.queue_url, MessageBody=body)
                cur.execute("""UPDATE clearledger.outbox
                                  SET published_at = GREATEST(NOW(), created_at), attempts = attempts + 1, last_error = NULL
                                WHERE seq = %s AND published_at IS NULL""", (seq,))
        self.conn.commit()
        if rows:
            log(f"outbox: published {len(rows)} rows directly")

    def wait_queue_drained(self, timeout=90):
        deadline = time.time() + timeout
        quiet = 0
        while time.time() < deadline:
            try:
                attrs = self.sqs.get_queue_attributes(
                    QueueUrl=self.queue_url,
                    AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
                )["Attributes"]
                pending = int(attrs.get("ApproximateNumberOfMessages", 0)) + int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0))
            except Exception as exc:  # noqa: BLE001
                log(f"sqs: attribute read failed: {exc}")
                pending = 0
            if pending == 0:
                quiet += 1
                if quiet >= 2:
                    return
            else:
                quiet = 0
            time.sleep(2)
        log("sqs: queue not fully drained before timeout; continuing with direct reconciliation")

    # -- authoritative model -------------------------------------------------
    def load_model(self):
        settlements = self.q("""
            SELECT settlement_id::text, account_id, reference, debit_party, credit_party, current_status,
                   current_stage, last_entry_id::text, last_memo, version, entry_count
              FROM clearledger.settlements""")
        events = self.q("""
            SELECT settlement_id::text, aggregate_version, event_id::text, event_type, correlation_id, payload::text
              FROM clearledger.events ORDER BY settlement_id, aggregate_version""")
        by_sid = {}
        for sid, ver, eid, etype, cid, payload in events:
            by_sid.setdefault(sid, []).append((ver, eid, etype, cid, json.loads(payload)))
        model = {}
        for (sid, acct, ref, debit, credit, status, stage, last_entry, last_memo, ver, cnt) in settlements:
            evs = by_sid.get(sid, [])
            items = {}
            latest_memo = None
            last_payload = None
            for (ev_ver, eid, etype, cid, payload) in evs:
                if ev_ver > ver:
                    continue
                data = payload.get("data") or {}
                item = {
                    "PK": {"S": f"SETTLEMENT#{sid}"},
                    "SK": {"S": f"EVENT#{ev_ver:08d}"},
                    "settlement_id": {"S": sid},
                    "event_id": {"S": eid},
                    "version": {"N": str(ev_ver)},
                    "event_type": {"S": etype},
                    "status": {"S": data.get("status")},
                    "clearing_stage": {"S": data.get("clearingStage")},
                    "occurred_at": {"S": rfc3339_offset(payload["occurredAt"])},
                    "correlation_id": {"S": cid},
                    "envelope": {"S": canonical_envelope(payload)},
                }
                if data.get("entryId") is not None:
                    item["entry_id"] = {"S": data["entryId"]}
                if data.get("memo") is not None:
                    item["memo"] = {"S": data["memo"]}
                    latest_memo = data["memo"]
                items[item["SK"]["S"]] = item
                last_payload = payload
            if last_payload is None:
                continue
            ldata = last_payload.get("data") or {}
            state = {
                "settlement_id": sid,
                "account_id": acct,
                "reference": ref,
                "debit_party": debit,
                "credit_party": credit,
                "status": ldata.get("status", status),
                "clearing_stage": ldata.get("clearingStage", stage),
                "version": int(last_payload["aggregateVersion"]),
                "entry_count": int(last_payload["aggregateVersion"]) - 1,
                "last_entry_id": ldata.get("entryId"),
                "last_memo": latest_memo if latest_memo is not None else last_memo,
                "updated_at_z": last_payload["occurredAt"],
            }
            st_item = {
                "PK": {"S": f"SETTLEMENT#{sid}"},
                "SK": {"S": "STATE"},
                "GSI1PK": {"S": f"ACCOUNT#{acct}"},
                "GSI1SK": {"S": f"SETTLEMENT#{sid}"},
                "settlement_id": {"S": sid},
                "account_id": {"S": acct},
                "reference": {"S": ref},
                "debit_party": {"S": debit},
                "credit_party": {"S": credit},
                "status": {"S": state["status"]},
                "clearing_stage": {"S": state["clearing_stage"]},
                "version": {"N": str(state["version"])},
                "entry_count": {"N": str(state["entry_count"])},
                "updated_at": {"S": rfc3339_offset(state["updated_at_z"])},
            }
            if state["last_entry_id"] is not None:
                st_item["last_entry_id"] = {"S": state["last_entry_id"]}
            if state["last_memo"] is not None:
                st_item["last_memo"] = {"S": state["last_memo"]}
            items["STATE"] = st_item
            model[sid] = {"items": items, "state": state}
        return model

    # -- DynamoDB ------------------------------------------------------------
    def reconcile_dynamodb(self, model):
        expected = {}
        for sid, m in model.items():
            for sk, item in m["items"].items():
                expected[(item["PK"]["S"], sk)] = item
        actual = {}
        kwargs = {"TableName": self.table, "ConsistentRead": True}
        while True:
            page = self.ddb.scan(**kwargs)
            for it in page.get("Items", []):
                pk = it.get("PK", {}).get("S")
                sk = it.get("SK", {}).get("S")
                actual[(pk, sk)] = it
            if "LastEvaluatedKey" not in page:
                break
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
        puts = [item for key, item in expected.items() if actual.get(key) != item]
        deletes = [key for key in actual if key not in expected]
        reqs = [{"PutRequest": {"Item": i}} for i in puts]
        reqs += [{"DeleteRequest": {"Key": {"PK": {"S": pk}, "SK": {"S": sk}}}} for pk, sk in deletes]
        for i in range(0, len(reqs), 25):
            batch = {self.table: reqs[i:i + 25]}
            for _ in range(10):
                resp = self.ddb.batch_write_item(RequestItems=batch)
                batch = resp.get("UnprocessedItems") or {}
                if not batch:
                    break
                time.sleep(0.5)
        log(f"dynamodb: {len(expected)} expected items, {len(puts)} written, {len(deletes)} removed")
        return len(puts) + len(deletes)

    # -- S3 audit archive ----------------------------------------------------
    KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")

    def list_versions(self):
        versions = []
        kwargs = {"Bucket": self.bucket}
        while True:
            page = self.s3.list_object_versions(**kwargs)
            for v in page.get("Versions", []):
                versions.append({"Key": v["Key"], "VersionId": v.get("VersionId"), "IsLatest": v.get("IsLatest"), "marker": False})
            for d in page.get("DeleteMarkers", []):
                versions.append({"Key": d["Key"], "VersionId": d.get("VersionId"), "IsLatest": d.get("IsLatest"), "marker": True})
            if page.get("IsTruncated"):
                kwargs["KeyMarker"] = page.get("NextKeyMarker")
                kwargs["VersionIdMarker"] = page.get("NextVersionIdMarker")
            else:
                break
        return versions

    def delete_versions(self, objs):
        objs = [o for o in objs]
        for i in range(0, len(objs), 500):
            chunk = objs[i:i + 500]
            payload = {"Objects": [{"Key": o["Key"], "VersionId": o["VersionId"]} if o.get("VersionId") else {"Key": o["Key"]} for o in chunk], "Quiet": True}
            try:
                self.s3.delete_objects(Bucket=self.bucket, Delete=payload)
            except Exception:  # noqa: BLE001
                for o in chunk:
                    kw = {"Bucket": self.bucket, "Key": o["Key"]}
                    if o.get("VersionId"):
                        kw["VersionId"] = o["VersionId"]
                    self.s3.delete_object(**kw)

    @staticmethod
    def batch_body(rows):
        return "".join(canonical_envelope(p) + "\n" for (_seq, p) in rows).encode("utf-8")

    def batch_key(self, rows, body):
        digest = hashlib.sha256(body).hexdigest()[:16]
        return f"{self.prefix}batch-{rows[0][0]:08d}-{rows[-1][0]:08d}-{digest}.ndjson"

    def reconcile_s3(self, max_batch=100):
        rows = self.q("""SELECT seq, payload::text, published_at IS NOT NULL, archived_at IS NOT NULL
                           FROM clearledger.outbox ORDER BY seq""")
        seqs = [r[0] for r in rows]
        payload_by_seq = {r[0]: json.loads(r[1]) for r in rows}
        published = {r[0] for r in rows if r[2]}
        index_of = {s: i for i, s in enumerate(seqs)}

        versions = self.list_versions()
        latest = {}
        for v in versions:
            if v["IsLatest"]:
                latest[v["Key"]] = v
        candidates = []
        for key, v in latest.items():
            if v["marker"]:
                continue
            m = self.KEY_RE.match(key)
            if not m:
                continue
            first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
            if first > last or first not in index_of or last not in index_of:
                continue
            try:
                obj = self.s3.get_object(Bucket=self.bucket, Key=key, VersionId=v["VersionId"]) if v.get("VersionId") \
                    else self.s3.get_object(Bucket=self.bucket, Key=key)
                body = obj["Body"].read()
            except Exception:  # noqa: BLE001
                continue
            if hashlib.sha256(body).hexdigest()[:16] != digest:
                continue
            slice_rows = [(s, payload_by_seq[s]) for s in seqs[index_of[first]:index_of[last] + 1]]
            if any(s not in published for s, _ in slice_rows):
                continue
            if body != self.batch_body(slice_rows):
                continue
            candidates.append((first, last, key))
        # Keep a non-overlapping set (earliest first, then widest).
        candidates.sort(key=lambda c: (c[0], -c[1]))
        keep = []
        covered_until = -1
        for first, last, key in candidates:
            if first > covered_until:
                keep.append((first, last, key))
                covered_until = last
        keep_keys = {k for _, _, k in keep}
        covered = set()
        for first, last, _ in keep:
            covered.update(seqs[index_of[first]:index_of[last] + 1])

        # Purge everything that is not the current version of a kept batch.
        purge = [v for v in versions if not (v["Key"] in keep_keys and v["IsLatest"] and not v["marker"])]
        if purge:
            self.delete_versions(purge)

        # Archive uncovered published rows in contiguous runs.
        runs, cur = [], []
        for s in seqs:
            if s in covered or s not in published:
                if cur:
                    runs.append(cur)
                    cur = []
                continue
            cur.append(s)
            if len(cur) >= max_batch:
                runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        written = 0
        for run in runs:
            batch_rows = [(s, payload_by_seq[s]) for s in run]
            body = self.batch_body(batch_rows)
            key = self.batch_key(batch_rows, body)
            self.s3.put_object(Bucket=self.bucket, Key=key, Body=body, ContentType="application/x-ndjson")
            covered.update(run)
            written += 1
        # Re-purge noncurrent versions that may have been produced by re-writes.
        if written:
            stale = [v for v in self.list_versions() if not v["IsLatest"] or v["marker"]]
            if stale:
                self.delete_versions(stale)

        # PostgreSQL: archived_at must be set exactly for archived rows.
        unarchived_but_covered = [r[0] for r in rows if r[0] in covered and not r[3]]
        archived_not_covered = [r[0] for r in rows if r[0] not in covered and r[3]]
        if unarchived_but_covered:
            self.q("""UPDATE clearledger.outbox SET archived_at = GREATEST(NOW(), published_at)
                       WHERE seq = ANY(%s) AND archived_at IS NULL AND published_at IS NOT NULL""",
                   (unarchived_but_covered,))
        if archived_not_covered:
            # Only possible for unpublished rows (not archivable yet): reset for later archival.
            self.q("UPDATE clearledger.outbox SET archived_at = NULL WHERE seq = ANY(%s)", (archived_not_covered,))
        changes = len(purge) + written + len(unarchived_but_covered) + len(archived_not_covered)
        log(f"s3: kept {len(keep)} batches, wrote {written}, purged {len(purge)} versions/markers, "
            f"stamped {len(unarchived_but_covered)} rows")
        return changes

    # -- Valkey --------------------------------------------------------------
    def reconcile_valkey(self, model, ttl=90):
        import redis
        cache = self.out["cache"]
        r = redis.Redis(host=cache["endpoint"], port=int(cache["port"]), socket_timeout=10, socket_connect_timeout=10)
        expected = {f"clearledger:settlement:{sid}": projection_json(m["state"]) for sid, m in model.items()}
        removed = 0
        for key in r.scan_iter(match="*", count=1000):
            k = key.decode("utf-8", "replace")
            if k not in expected:
                r.delete(key)
                removed += 1
        pipe = r.pipeline(transaction=False)
        for k, v in expected.items():
            pipe.set(k, v.encode("utf-8"), ex=ttl)
        pipe.execute()
        log(f"valkey: populated {len(expected)} keys (ttl {ttl}s), removed {removed} stray keys")

    def run(self):
        self.repair_outbox()
        self.publish_outbox()
        self.wait_queue_drained()
        for attempt in range(3):
            model = self.load_model()
            changes = self.reconcile_dynamodb(model)
            changes += self.reconcile_s3()
            if changes == 0:
                break
        model = self.load_model()
        self.reconcile_valkey(model)


# ---------------------------------------------------------------------------
# sweep: prefix / tag scoped teardown of anything Terraform did not remove
# ---------------------------------------------------------------------------

class Sweeper:
    TAG = "ClearLedgerDeployment"

    def __init__(self, cfg):
        self.cfg = cfg
        self.prefix = cfg["resource_prefix"]
        self.name_re = re.compile(rf"^{re.escape(self.prefix)}([^A-Za-z0-9]|$)")
        self.errors = 0

    def ours(self, name):
        if not name or name.startswith("cl-base-"):
            return False
        return bool(self.name_re.match(name))

    def tagged(self, tags):
        """tags: list of {Key/Value} or {TagKey/TagValue} dicts, or a plain dict."""
        if not tags:
            return False
        if isinstance(tags, dict):
            return tags.get(self.TAG) == self.prefix
        for t in tags:
            k = t.get("Key", t.get("TagKey"))
            v = t.get("Value", t.get("TagValue"))
            if k == self.TAG and v == self.prefix:
                return True
        return False

    def c(self, svc):
        return client(self.cfg, svc)

    def attempt(self, what, fn, *a, **kw):
        try:
            return fn(*a, **kw)
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            if any(s in msg for s in ("NotFound", "does not exist", "NoSuch", "not found", "ResourceNotFound")):
                return None
            self.errors += 1
            log(f"sweep: {what} failed: {type(exc).__name__}: {msg[:200]}")
            return None

    # Individual services -------------------------------------------------
    def ecs(self):
        ecs = self.c("ecs")
        arns = self.attempt("ecs list clusters", lambda: ecs.list_clusters().get("clusterArns", [])) or []
        for arn in arns:
            name = arn.rsplit("/", 1)[-1]
            if not self.ours(name):
                continue
            svcs = self.attempt("ecs list services", lambda: ecs.list_services(cluster=arn).get("serviceArns", [])) or []
            for s in svcs:
                self.attempt("ecs scale service", ecs.update_service, cluster=arn, service=s, desiredCount=0)
                self.attempt("ecs delete service", ecs.delete_service, cluster=arn, service=s, force=True)
            tasks = self.attempt("ecs list tasks", lambda: ecs.list_tasks(cluster=arn).get("taskArns", [])) or []
            for t in tasks:
                self.attempt("ecs stop task", ecs.stop_task, cluster=arn, task=t, reason="clearledger destroy")
            log(f"sweep: deleting ECS cluster {name}")
            for _ in range(10):
                if self.attempt("ecs delete cluster", ecs.delete_cluster, cluster=arn) is not None:
                    break
                time.sleep(3)
        for status in ("ACTIVE", "INACTIVE"):
            tds = self.attempt("ecs list task defs", lambda: ecs.list_task_definitions(familyPrefix=self.prefix, status=status).get("taskDefinitionArns", [])) or []
            for td in tds:
                fam = td.rsplit("/", 1)[-1].split(":")[0]
                if not self.ours(fam):
                    continue
                if status == "ACTIVE":
                    self.attempt("ecs deregister task def", ecs.deregister_task_definition, taskDefinition=td)
                self.attempt("ecs delete task def", ecs.delete_task_definitions, taskDefinitions=[td])

    def elbv2(self):
        elb = self.c("elbv2")
        lbs = self.attempt("elb list", lambda: elb.describe_load_balancers().get("LoadBalancers", [])) or []
        for lb in lbs:
            if not self.ours(lb["LoadBalancerName"]):
                continue
            for li in self.attempt("elb listeners", lambda: elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", [])) or []:
                self.attempt("elb delete listener", elb.delete_listener, ListenerArn=li["ListenerArn"])
            log(f"sweep: deleting load balancer {lb['LoadBalancerName']}")
            self.attempt("elb delete lb", elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
        tgs = self.attempt("elb tgs", lambda: elb.describe_target_groups().get("TargetGroups", [])) or []
        for tg in tgs:
            if self.ours(tg["TargetGroupName"]):
                log(f"sweep: deleting target group {tg['TargetGroupName']}")
                for _ in range(5):
                    if self.attempt("elb delete tg", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"]) is not None:
                        break
                    time.sleep(2)

    def lambdas(self):
        lmb = self.c("lambda")
        esms = self.attempt("lambda esm list", lambda: lmb.list_event_source_mappings().get("EventSourceMappings", [])) or []
        for m in esms:
            fn = m.get("FunctionArn", "").rsplit(":", 1)[-1]
            src = m.get("EventSourceArn", "").rsplit(":", 1)[-1]
            if self.ours(fn) or self.ours(src):
                log(f"sweep: deleting event source mapping {m['UUID']}")
                self.attempt("lambda delete esm", lmb.delete_event_source_mapping, UUID=m["UUID"])
        fns = []
        marker = None
        while True:
            kw = {"Marker": marker} if marker else {}
            page = self.attempt("lambda list", lmb.list_functions, **kw)
            if not page:
                break
            fns += page.get("Functions", [])
            marker = page.get("NextMarker")
            if not marker:
                break
        for f in fns:
            if self.ours(f["FunctionName"]):
                log(f"sweep: deleting lambda {f['FunctionName']}")
                self.attempt("lambda delete", lmb.delete_function, FunctionName=f["FunctionName"])

    def scheduler(self):
        sch = self.c("scheduler")
        groups = self.attempt("scheduler groups", lambda: sch.list_schedule_groups().get("ScheduleGroups", [])) or []
        names = {g["Name"] for g in groups} | {"default"}
        for g in names:
            for s in self.attempt("scheduler list", lambda: sch.list_schedules(GroupName=g).get("Schedules", [])) or []:
                if self.ours(s["Name"]):
                    log(f"sweep: deleting schedule {s['Name']}")
                    self.attempt("scheduler delete", sch.delete_schedule, Name=s["Name"], GroupName=g)
            if g != "default" and self.ours(g):
                self.attempt("scheduler delete group", sch.delete_schedule_group, Name=g)

    def events(self):
        ev = self.c("events")
        for r in self.attempt("events rules", lambda: ev.list_rules().get("Rules", [])) or []:
            if self.ours(r["Name"]):
                tg = self.attempt("events targets", lambda: ev.list_targets_by_rule(Rule=r["Name"]).get("Targets", [])) or []
                if tg:
                    self.attempt("events remove targets", ev.remove_targets, Rule=r["Name"], Ids=[t["Id"] for t in tg], Force=True)
                self.attempt("events delete rule", ev.delete_rule, Name=r["Name"], Force=True)

    def sqs(self):
        sqs = self.c("sqs")
        urls = self.attempt("sqs list", lambda: sqs.list_queues(QueueNamePrefix=self.prefix).get("QueueUrls", [])) or []
        for u in urls:
            if self.ours(u.rsplit("/", 1)[-1]):
                log(f"sweep: deleting queue {u}")
                self.attempt("sqs delete", sqs.delete_queue, QueueUrl=u)

    def sns(self):
        sns = self.c("sns")
        for t in self.attempt("sns list", lambda: sns.list_topics().get("Topics", [])) or []:
            if self.ours(t["TopicArn"].rsplit(":", 1)[-1]):
                self.attempt("sns delete", sns.delete_topic, TopicArn=t["TopicArn"])

    def dynamodb(self):
        ddb = self.c("dynamodb")
        for t in self.attempt("ddb list", lambda: ddb.list_tables().get("TableNames", [])) or []:
            if self.ours(t):
                log(f"sweep: deleting DynamoDB table {t}")
                self.attempt("ddb delete", ddb.delete_table, TableName=t)

    def s3(self):
        s3 = self.c("s3")
        for b in self.attempt("s3 list", lambda: s3.list_buckets().get("Buckets", [])) or []:
            name = b["Name"]
            if not self.ours(name):
                continue
            log(f"sweep: emptying and deleting bucket {name}")
            kw = {"Bucket": name}
            while True:
                page = self.attempt("s3 list versions", s3.list_object_versions, **kw)
                if not page:
                    break
                objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("Versions", []) + page.get("DeleteMarkers", [])]
                if objs:
                    self.attempt("s3 delete objects", s3.delete_objects, Bucket=name, Delete={"Objects": objs, "Quiet": True})
                if not page.get("IsTruncated"):
                    break
                kw = {"Bucket": name, "KeyMarker": page.get("NextKeyMarker"), "VersionIdMarker": page.get("NextVersionIdMarker")}
            page = self.attempt("s3 list objects", s3.list_objects_v2, Bucket=name) or {}
            for o in page.get("Contents", []):
                self.attempt("s3 delete object", s3.delete_object, Bucket=name, Key=o["Key"])
            self.attempt("s3 delete bucket", s3.delete_bucket, Bucket=name)

    def rds(self):
        rds = self.c("rds")
        for db in self.attempt("rds list", lambda: rds.describe_db_instances().get("DBInstances", [])) or []:
            if self.ours(db["DBInstanceIdentifier"]):
                log(f"sweep: deleting RDS instance {db['DBInstanceIdentifier']}")
                self.attempt("rds delete", rds.delete_db_instance, DBInstanceIdentifier=db["DBInstanceIdentifier"],
                             SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
        for snap in self.attempt("rds snapshots", lambda: rds.describe_db_snapshots().get("DBSnapshots", [])) or []:
            if self.ours(snap.get("DBSnapshotIdentifier")):
                self.attempt("rds delete snapshot", rds.delete_db_snapshot, DBSnapshotIdentifier=snap["DBSnapshotIdentifier"])
        for _ in range(30):
            left = [d for d in (self.attempt("rds list", lambda: rds.describe_db_instances().get("DBInstances", [])) or [])
                    if self.ours(d["DBInstanceIdentifier"])]
            if not left:
                break
            time.sleep(3)
        for sg in self.attempt("rds subnet groups", lambda: rds.describe_db_subnet_groups().get("DBSubnetGroups", [])) or []:
            if self.ours(sg["DBSubnetGroupName"]):
                self.attempt("rds delete subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=sg["DBSubnetGroupName"])
        for pg in self.attempt("rds param groups", lambda: rds.describe_db_parameter_groups().get("DBParameterGroups", [])) or []:
            if self.ours(pg["DBParameterGroupName"]):
                self.attempt("rds delete param group", rds.delete_db_parameter_group, DBParameterGroupName=pg["DBParameterGroupName"])

    def elasticache(self):
        ec = self.c("elasticache")
        for rg in self.attempt("ec rgs", lambda: ec.describe_replication_groups().get("ReplicationGroups", [])) or []:
            if self.ours(rg["ReplicationGroupId"]):
                log(f"sweep: deleting replication group {rg['ReplicationGroupId']}")
                self.attempt("ec delete rg", ec.delete_replication_group, ReplicationGroupId=rg["ReplicationGroupId"])
        for cc in self.attempt("ec clusters", lambda: ec.describe_cache_clusters().get("CacheClusters", [])) or []:
            if self.ours(cc["CacheClusterId"]) and not cc.get("ReplicationGroupId"):
                self.attempt("ec delete cluster", ec.delete_cache_cluster, CacheClusterId=cc["CacheClusterId"])
        for _ in range(30):
            left = [r for r in (self.attempt("ec rgs", lambda: ec.describe_replication_groups().get("ReplicationGroups", [])) or [])
                    if self.ours(r["ReplicationGroupId"])]
            if not left:
                break
            time.sleep(3)
        for sg in self.attempt("ec subnet groups", lambda: ec.describe_cache_subnet_groups().get("CacheSubnetGroups", [])) or []:
            if self.ours(sg["CacheSubnetGroupName"]):
                self.attempt("ec delete subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=sg["CacheSubnetGroupName"])

    def cognito(self):
        cg = self.c("cognito-idp")
        pools = self.attempt("cognito list", lambda: cg.list_user_pools(MaxResults=60).get("UserPools", [])) or []
        for p in pools:
            if not self.ours(p["Name"]):
                continue
            desc = self.attempt("cognito describe", lambda: cg.describe_user_pool(UserPoolId=p["Id"])["UserPool"]) or {}
            if desc.get("Domain"):
                self.attempt("cognito delete domain", cg.delete_user_pool_domain, Domain=desc["Domain"], UserPoolId=p["Id"])
            log(f"sweep: deleting user pool {p['Name']}")
            self.attempt("cognito delete pool", cg.delete_user_pool, UserPoolId=p["Id"])

    def iam(self):
        iam = self.c("iam")
        roles = []
        for page in (self.attempt("iam roles", lambda: list(iam.get_paginator("list_roles").paginate())) or []):
            roles += page.get("Roles", [])
        for r in roles:
            name = r["RoleName"]
            if not self.ours(name):
                continue
            log(f"sweep: deleting IAM role {name}")
            for pn in self.attempt("iam inline", lambda: iam.list_role_policies(RoleName=name).get("PolicyNames", [])) or []:
                self.attempt("iam delete inline", iam.delete_role_policy, RoleName=name, PolicyName=pn)
            for ap in self.attempt("iam attached", lambda: iam.list_attached_role_policies(RoleName=name).get("AttachedPolicies", [])) or []:
                self.attempt("iam detach", iam.detach_role_policy, RoleName=name, PolicyArn=ap["PolicyArn"])
            for ip in self.attempt("iam profiles", lambda: iam.list_instance_profiles_for_role(RoleName=name).get("InstanceProfiles", [])) or []:
                self.attempt("iam remove role from profile", iam.remove_role_from_instance_profile,
                             InstanceProfileName=ip["InstanceProfileName"], RoleName=name)
            self.attempt("iam delete role", iam.delete_role, RoleName=name)
        pols = []
        for page in (self.attempt("iam policies", lambda: list(iam.get_paginator("list_policies").paginate(Scope="Local"))) or []):
            pols += page.get("Policies", [])
        for p in pols:
            if not self.ours(p["PolicyName"]):
                continue
            arn = p["Arn"]
            ents = self.attempt("iam entities", iam.list_entities_for_policy, PolicyArn=arn) or {}
            for r in ents.get("PolicyRoles", []):
                self.attempt("iam detach role", iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
            for u in ents.get("PolicyUsers", []):
                self.attempt("iam detach user", iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
            for g in ents.get("PolicyGroups", []):
                self.attempt("iam detach group", iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
            for v in (self.attempt("iam versions", iam.list_policy_versions, PolicyArn=arn) or {}).get("Versions", []):
                if not v.get("IsDefaultVersion"):
                    self.attempt("iam delete version", iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
            log(f"sweep: deleting IAM policy {p['PolicyName']}")
            self.attempt("iam delete policy", iam.delete_policy, PolicyArn=arn)
        for ip in (self.attempt("iam instance profiles", lambda: iam.list_instance_profiles().get("InstanceProfiles", [])) or []):
            if self.ours(ip["InstanceProfileName"]):
                for r in ip.get("Roles", []):
                    self.attempt("iam remove role", iam.remove_role_from_instance_profile,
                                 InstanceProfileName=ip["InstanceProfileName"], RoleName=r["RoleName"])
                self.attempt("iam delete profile", iam.delete_instance_profile, InstanceProfileName=ip["InstanceProfileName"])

    def kms(self):
        kms = self.c("kms")
        targets = set()
        aliases = []
        for page in (self.attempt("kms aliases", lambda: list(kms.get_paginator("list_aliases").paginate())) or []):
            aliases += page.get("Aliases", [])
        for a in aliases:
            an = a.get("AliasName", "")
            if an.startswith("alias/") and self.ours(an[len("alias/"):]):
                if a.get("TargetKeyId"):
                    targets.add(a["TargetKeyId"])
                self.attempt("kms delete alias", kms.delete_alias, AliasName=an)
        keys = []
        for page in (self.attempt("kms keys", lambda: list(kms.get_paginator("list_keys").paginate())) or []):
            keys += page.get("Keys", [])
        for k in keys:
            tags = self.attempt("kms tags", lambda: kms.list_resource_tags(KeyId=k["KeyId"]).get("Tags", [])) or []
            if self.tagged(tags):
                targets.add(k["KeyId"])
        for kid in targets:
            meta = (self.attempt("kms describe", kms.describe_key, KeyId=kid) or {}).get("KeyMetadata", {})
            if meta.get("KeyManager") == "AWS" or meta.get("KeyState") in (None, "PendingDeletion"):
                continue
            log(f"sweep: scheduling deletion of KMS key {kid}")
            self.attempt("kms schedule deletion", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)

    def logs(self):
        lg = self.c("logs")
        groups = []
        for page in (self.attempt("logs list", lambda: list(lg.get_paginator("describe_log_groups").paginate())) or []):
            groups += page.get("logGroups", [])
        for g in groups:
            name = g["logGroupName"]
            parts = [p for p in re.split(r"[/]", name) if p]
            if any(self.ours(p) for p in parts):
                log(f"sweep: deleting log group {name}")
                self.attempt("logs delete", lg.delete_log_group, logGroupName=name)

    def secrets_ssm(self):
        sm = self.c("secretsmanager")
        for s in (self.attempt("secrets list", lambda: sm.list_secrets().get("SecretList", [])) or []):
            if self.ours(s["Name"]) or self.tagged(s.get("Tags")):
                self.attempt("secret delete", sm.delete_secret, SecretId=s["ARN"], ForceDeleteWithoutRecovery=True)
        ssm = self.c("ssm")
        for p in (self.attempt("ssm list", lambda: ssm.describe_parameters().get("Parameters", [])) or []):
            parts = [x for x in p["Name"].split("/") if x]
            if any(self.ours(x) for x in parts):
                self.attempt("ssm delete", ssm.delete_parameter, Name=p["Name"])

    def ecr(self):
        ecr = self.c("ecr")
        for r in (self.attempt("ecr list", lambda: ecr.describe_repositories().get("repositories", [])) or []):
            if self.ours(r["repositoryName"]):
                self.attempt("ecr delete", ecr.delete_repository, repositoryName=r["repositoryName"], force=True)

    def ec2(self):
        ec2 = self.c("ec2")

        def name_of(tags):
            for t in tags or []:
                if t.get("Key") == "Name":
                    return t.get("Value")
            return None

        vpcs = self.attempt("ec2 vpcs", lambda: ec2.describe_vpcs().get("Vpcs", [])) or []
        our_vpcs = [v["VpcId"] for v in vpcs if not v.get("IsDefault") and (self.tagged(v.get("Tags")) or self.ours(name_of(v.get("Tags"))))]
        sgs = self.attempt("ec2 sgs", lambda: ec2.describe_security_groups().get("SecurityGroups", [])) or []
        our_sgs = [s for s in sgs if s.get("GroupName") != "default" and (
            s.get("VpcId") in our_vpcs or self.ours(s.get("GroupName")) or self.tagged(s.get("Tags")))]
        # Break cross references between security groups first.
        for s in our_sgs:
            if s.get("IpPermissions"):
                self.attempt("ec2 revoke ingress", ec2.revoke_security_group_ingress, GroupId=s["GroupId"], IpPermissions=s["IpPermissions"])
            if s.get("IpPermissionsEgress"):
                self.attempt("ec2 revoke egress", ec2.revoke_security_group_egress, GroupId=s["GroupId"], IpPermissions=s["IpPermissionsEgress"])
        enis = self.attempt("ec2 enis", lambda: ec2.describe_network_interfaces().get("NetworkInterfaces", [])) or []
        for e in enis:
            if e.get("VpcId") in our_vpcs:
                if e.get("Attachment", {}).get("AttachmentId"):
                    self.attempt("ec2 detach eni", ec2.detach_network_interface, AttachmentId=e["Attachment"]["AttachmentId"], Force=True)
                self.attempt("ec2 delete eni", ec2.delete_network_interface, NetworkInterfaceId=e["NetworkInterfaceId"])
        for s in our_sgs:
            log(f"sweep: deleting security group {s['GroupId']} ({s.get('GroupName')})")
            self.attempt("ec2 delete sg", ec2.delete_security_group, GroupId=s["GroupId"])
        for vpc in our_vpcs:
            flt = [{"Name": "vpc-id", "Values": [vpc]}]
            for ng in (self.attempt("ec2 nat", lambda: ec2.describe_nat_gateways(Filters=flt).get("NatGateways", [])) or []):
                self.attempt("ec2 delete nat", ec2.delete_nat_gateway, NatGatewayId=ng["NatGatewayId"])
            for ep in (self.attempt("ec2 endpoints", lambda: ec2.describe_vpc_endpoints(Filters=flt).get("VpcEndpoints", [])) or []):
                self.attempt("ec2 delete endpoint", ec2.delete_vpc_endpoints, VpcEndpointIds=[ep["VpcEndpointId"]])
            for igw in (self.attempt("ec2 igw", lambda: ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]).get("InternetGateways", [])) or []):
                self.attempt("ec2 detach igw", ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
                self.attempt("ec2 delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
            for sn in (self.attempt("ec2 subnets", lambda: ec2.describe_subnets(Filters=flt).get("Subnets", [])) or []):
                self.attempt("ec2 delete subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
            for rt in (self.attempt("ec2 rts", lambda: ec2.describe_route_tables(Filters=flt).get("RouteTables", [])) or []):
                if any(a.get("Main") for a in rt.get("Associations", [])):
                    continue
                for a in rt.get("Associations", []):
                    if a.get("RouteTableAssociationId"):
                        self.attempt("ec2 disassociate rt", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
                self.attempt("ec2 delete rt", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
            for acl in (self.attempt("ec2 acls", lambda: ec2.describe_network_acls(Filters=flt).get("NetworkAcls", [])) or []):
                if not acl.get("IsDefault"):
                    self.attempt("ec2 delete acl", ec2.delete_network_acl, NetworkAclId=acl["NetworkAclId"])
            log(f"sweep: deleting VPC {vpc}")
            self.attempt("ec2 delete vpc", ec2.delete_vpc, VpcId=vpc)
        # Detached tagged leftovers outside our VPCs.
        for igw in (self.attempt("ec2 igws", lambda: ec2.describe_internet_gateways().get("InternetGateways", [])) or []):
            if (self.tagged(igw.get("Tags")) or self.ours(name_of(igw.get("Tags")))) and not igw.get("Attachments"):
                self.attempt("ec2 delete igw", ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])
        for addr in (self.attempt("ec2 eips", lambda: ec2.describe_addresses().get("Addresses", [])) or []):
            if self.tagged(addr.get("Tags")) and addr.get("AllocationId"):
                self.attempt("ec2 release eip", ec2.release_address, AllocationId=addr["AllocationId"])

    def leftovers(self):
        tg = self.c("resourcegroupstaggingapi")
        try:
            res = tg.get_resources(TagFilters=[{"Key": self.TAG, "Values": [self.prefix]}]).get("ResourceTagMappingList", [])
        except Exception:  # noqa: BLE001
            return []
        return [r["ResourceARN"] for r in res]

    def run(self):
        order = [self.ecs, self.scheduler, self.events, self.lambdas, self.elbv2, self.sqs, self.sns,
                 self.dynamodb, self.s3, self.rds, self.elasticache, self.cognito, self.secrets_ssm, self.ecr,
                 self.logs, self.iam, self.kms, self.ec2]
        for fn in order:
            try:
                fn()
            except Exception as exc:  # noqa: BLE001
                self.errors += 1
                log(f"sweep: {fn.__name__} failed: {exc}")
        # Second EC2 pass: dependencies released asynchronously by the first pass.
        try:
            self.ec2()
        except Exception:  # noqa: BLE001
            pass
        left = [a for a in self.leftovers() if ":kms:" not in a]
        if left:
            log(f"sweep: tagged resources still reported: {len(left)}")
            for a in left[:50]:
                log(f"  {a}")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    cfg = load(sys.argv[2])
    out = load(sys.argv[3]) if len(sys.argv) > 3 else None
    if cmd == "preflight":
        cmd_preflight(cfg)
    elif cmd == "iam":
        cmd_iam(cfg, out)
    elif cmd == "schema-wait":
        cmd_schema_wait(cfg, out)
    elif cmd == "reconcile":
        Reconciler(cfg, out).run()
    elif cmd == "sweep":
        Sweeper(cfg).run()
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
