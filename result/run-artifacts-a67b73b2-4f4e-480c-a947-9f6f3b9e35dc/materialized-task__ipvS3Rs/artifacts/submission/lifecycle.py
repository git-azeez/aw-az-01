"""Control-plane repair and database-authoritative derived-store convergence.

Cloud resource creation is exclusively Terraform's responsibility. This helper
only invokes existing workers, repairs operational drift, and removes resources.
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import boto3
import jsonschema
import psycopg2
import psycopg2.extras
import redis
import requests
from botocore.config import Config
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parent
C = json.loads(Path(os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json")).read_text())
PREFIX = C["resource_prefix"]
SESSION = boto3.Session(aws_access_key_id="test", aws_secret_access_key="test", region_name=C["region"])
CLIENTS = {}
ROLE_KEYS = ("ecs_execution", "ecs_task", "projector", "relay", "archiver", "scheduler")
MISSING = {"ResourceNotFoundException", "ResourceNotFound", "NoSuchEntity", "NoSuchEntityException", "NoSuchBucket", "NoSuchKey", "NoSuchTagSet", "DBInstanceNotFound", "DBInstanceNotFoundFault", "AWS.SimpleQueueService.NonExistentQueue", "QueueDoesNotExist", "NotFoundException", "NotFound", "404", "ReplicationGroupNotFoundFault", "CacheClusterNotFound", "CacheClusterNotFoundFault"}


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=C["aws_endpoint_url"], config=Config(
            connect_timeout=5, read_timeout=30, retries={"max_attempts": 4, "mode": "standard"},
            s3={"addressing_style": "path"}))
    return CLIENTS[service]


def optional(fn, **kw):
    try:
        return fn(**kw)
    except ClientError as e:
        if e.response["Error"]["Code"] in MISSING:
            return None
        raise


def pages(service, operation, key, **kw):
    c = client(service)
    if c.can_paginate(operation):
        return [x for p in c.get_paginator(operation).paginate(**kw) for x in p.get(key, [])]
    return getattr(c, operation)(**kw).get(key, [])


def scoped(name, tags=None):
    # The baseline namespace is excluded even if someone adds a deployment tag.
    if any(part.startswith("cl-base-") for part in name.split("/")):
        return False
    if isinstance(tags, list):
        tags = {t["Key"]: t["Value"] for t in tags}
    return (any(part.startswith(PREFIX) for part in name.split("/"))
            or (tags or {}).get("ClearLedgerDeployment") == PREFIX)


def manifest():
    return json.loads((ROOT / "manifest.json").read_text())


def db(m=None):
    m = m or manifest()
    d = m["database"]
    return psycopg2.connect(host=d["endpoint"], port=d["port"], dbname=C["db_name"],
                            user=C["db_username"], password=C["db_password"], connect_timeout=5)


def sql(conn, query, args=None):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query, args)
        return [dict(x) for x in cur.fetchall()] if cur.description else []


def count(conn, predicate):
    return sql(conn, "SELECT count(*) AS n FROM clearledger.outbox WHERE " + predicate)[0]["n"]


def guard():
    if PREFIX.startswith("cl-base-") or not re.fullmatch(r"[a-z][a-z0-9-]{3,24}", PREFIX):
        raise RuntimeError("Invalid deployment prefix")
    state = ROOT / "infra/terraform.tfstate"
    if state.exists():
        s = json.loads(state.read_text())
        old = s.get("outputs", {}).get("manifest", {}).get("value", {}).get("resource_prefix")
        if old and old != PREFIX and any(r.get("mode") == "managed" for r in s.get("resources", [])):
            raise RuntimeError("Active state belongs to another deployment prefix")


def delete_policy(arn):
    iam = client("iam")
    for v in pages("iam", "list_policy_versions", "Versions", PolicyArn=arn):
        if not v["IsDefaultVersion"]:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    optional(iam.delete_policy, PolicyArn=arn)


def repair_iam(all_roles=False):
    iam = client("iam")
    roles = pages("iam", "list_roles", "Roles")
    for role in roles:
        name = role["RoleName"]
        if all_roles:
            tags = iam.list_role_tags(RoleName=name).get("Tags", [])
            if not scoped(name, tags):
                continue
        elif name not in [PREFIX + "-" + k for k in ROLE_KEYS]:
            continue
        canonical = name + "-canonical"
        for policy in pages("iam", "list_role_policies", "PolicyNames", RoleName=name):
            if all_roles or policy != canonical:
                iam.delete_role_policy(RoleName=name, PolicyName=policy)
        for policy in pages("iam", "list_attached_role_policies", "AttachedPolicies", RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=policy["PolicyArn"])
    for p in pages("iam", "list_policies", "Policies", Scope="Local"):
        tags = iam.list_policy_tags(PolicyArn=p["Arn"]).get("Tags", [])
        if scoped(p["PolicyName"], tags):
            entities = iam.list_entities_for_policy(PolicyArn=p["Arn"])
            if all_roles:
                for r in entities.get("PolicyRoles", []):
                    if scoped(r["RoleName"]):
                        iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=p["Arn"])
                for u in entities.get("PolicyUsers", []):
                    if scoped(u["UserName"]):
                        iam.detach_user_policy(UserName=u["UserName"], PolicyArn=p["Arn"])
                for g in entities.get("PolicyGroups", []):
                    if scoped(g["GroupName"]):
                        iam.detach_group_policy(GroupName=g["GroupName"], PolicyArn=p["Arn"])
                entities = iam.list_entities_for_policy(PolicyArn=p["Arn"])
            if not any(entities.get(k) for k in ("PolicyRoles", "PolicyUsers", "PolicyGroups")):
                delete_policy(p["Arn"])


def repair():
    repair_iam()
    # A surviving mapping to a deleted queue can retain a dead poller, although
    # a recreated queue has an identical ARN. Remove the mapping before refresh.
    q = optional(client("sqs").get_queue_url, QueueName=PREFIX + "-events")
    if not q:
        for e in pages("lambda", "list_event_source_mappings", "EventSourceMappings"):
            if e.get("FunctionArn", "").endswith(":" + PREFIX + "-projector"):
                optional(client("lambda").delete_event_source_mapping, UUID=e["UUID"])
    ec2 = client("ec2")
    groups = ec2.describe_security_groups(Filters=[{"Name": "tag:ClearLedgerDeployment", "Values": [PREFIX]}])["SecurityGroups"]
    for g in groups:
        if g["GroupName"] in (PREFIX + "-rds", PREFIX + "-valkey") and g.get("IpPermissionsEgress"):
            ec2.revoke_security_group_egress(GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
        if g["GroupName"] == PREFIX + "-alb":
            bad = [p for p in g.get("IpPermissionsEgress", []) if p["IpProtocol"] == "-1"
                   or any(x["CidrIp"] == "0.0.0.0/0" for x in p.get("IpRanges", []))
                   or any(x["CidrIpv6"] == "::/0" for x in p.get("Ipv6Ranges", []))]
            if bad:
                ec2.revoke_security_group_egress(GroupId=g["GroupId"], IpPermissions=bad)


def protect():
    result = subprocess.check_output(["terraform", "-chdir=" + str(ROOT / "infra"), "show", "-json", str(ROOT / "infra/deploy.tfplan")])
    plan = json.loads(result)
    for r in plan.get("resource_changes", []):
        if r["type"] in {"aws_db_instance", "aws_dynamodb_table", "aws_s3_bucket"} and "delete" in r["change"]["actions"]:
            raise RuntimeError("Refusing destructive replacement of authoritative or durable store: " + r["address"])


def export_manifest():
    value = json.loads(subprocess.check_output(["terraform", "-chdir=" + str(ROOT / "infra"), "output", "-json", "manifest"]))
    schema = json.loads(Path("/workspace/contracts/schemas/manifest.schema.json").read_text())
    jsonschema.Draft202012Validator(schema).validate(value)
    data = json.dumps(value, indent=2) + "\n"
    if len(data.encode()) > 1024 * 1024:
        raise RuntimeError("Manifest too large")
    tmp = ROOT / "manifest.json.tmp"
    tmp.write_text(data)
    tmp.chmod(0o600)
    tmp.replace(ROOT / "manifest.json")
    (ROOT / "infra/deploy.tfplan").unlink(missing_ok=True)
    print("Manifest exported and schema validated")


def schema():
    deadline = time.monotonic() + 90
    while True:
        try:
            conn = db()
            break
        except psycopg2.OperationalError:
            if time.monotonic() > deadline:
                raise RuntimeError("PostgreSQL did not become reachable") from None
            time.sleep(2)
    conn.close()
    m = manifest()["database"]
    env = dict(os.environ, PGPASSWORD=C["db_password"], PGCONNECT_TIMEOUT="5")
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-h", m["endpoint"], "-p", str(m["port"]),
                    "-U", C["db_username"], "-d", C["db_name"], "-f", str(ROOT / "schema.sql")], env=env, check=True)
    print("PostgreSQL schema initialized")


def ready():
    url = manifest()["service_url"] + "/health/ready"
    end = time.monotonic() + 120
    while time.monotonic() < end:
        try:
            r = requests.get(url, timeout=5)
            if r.status_code == 200:
                print("API ready")
                return
        except requests.RequestException:
            pass
        time.sleep(2)
    raise RuntimeError("API readiness timed out")


def invoke(m, key, payload=None):
    r = client("lambda").invoke(FunctionName=m["workers"][key]["function_name"],
                                 InvocationType="RequestResponse", Payload=json.dumps(payload or {}).encode())
    body = r["Payload"].read()
    if r.get("FunctionError"):
        # Do not print worker errors: they can contain connection credentials.
        raise RuntimeError("Worker invocation failed: " + key)
    return json.loads(body) if body else {}


def mapping(m, enabled):
    lam = client("lambda")
    uuid = m["messaging"]["event_source_mapping_uuid"]
    lam.update_event_source_mapping(UUID=uuid, Enabled=enabled)
    end = time.monotonic() + 30
    while time.monotonic() < end:
        state = lam.get_event_source_mapping(UUID=uuid)["State"]
        if state == ("Enabled" if enabled else "Disabled"):
            return
        time.sleep(0.3)
    raise RuntimeError("Event mapping did not reach requested state")


def schedules(m, enabled):
    sch = client("scheduler")
    for name in (m["schedules"]["outbox_schedule_name"], m["schedules"]["archive_schedule_name"]):
        s = sch.get_schedule(Name=name)
        # UpdateSchedule is replacement semantics: preserve the whole target.
        kw = {k: s[k] for k in ("Name", "GroupName", "ScheduleExpression", "ScheduleExpressionTimezone", "FlexibleTimeWindow", "Target", "StartDate", "EndDate", "Description", "KmsKeyArn", "ActionAfterCompletion") if k in s}
        kw["State"] = "ENABLED" if enabled else "DISABLED"
        sch.update_schedule(**kw)


def drain(conn, m, predicate, worker, deadline):
    while count(conn, predicate):
        if time.monotonic() > deadline:
            raise RuntimeError("Timed out draining " + worker)
        invoke(m, worker)
    conn.commit()


def versions(bucket):
    out = []
    for p in client("s3").get_paginator("list_object_versions").paginate(Bucket=bucket):
        out += [dict(v, marker=False) for v in p.get("Versions", [])]
        out += [dict(v, marker=True) for v in p.get("DeleteMarkers", [])]
    return out


def purge_versions(bucket, rows):
    for i in range(0, len(rows), 1000):
        r = client("s3").delete_objects(Bucket=bucket, Delete={"Objects": [
            {"Key": v["Key"], "VersionId": v["VersionId"]} for v in rows[i:i + 1000]], "Quiet": True})
        if r.get("Errors"):
            raise RuntimeError("Failed to purge S3 versions")


def archive_valid(conn, m):
    bucket = m["audit"]["bucket_name"]
    # A REPEATABLE READ snapshot keeps records/metadata mutually consistent.
    rows = sql(conn, "SELECT seq,payload,archived_at FROM clearledger.outbox ORDER BY seq")
    expected = {r["seq"]: r for r in rows}
    seen = set()
    for v in versions(bucket):
        if v["marker"] or not v["IsLatest"]:
            continue
        match = re.fullmatch(r"ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson", v["Key"])
        if not match:
            return False
        first, last = int(match[1]), int(match[2])
        seqs = [x for x in expected if first <= x <= last]
        if not seqs or seqs[0] != first or seqs[-1] != last or seen.intersection(seqs):
            return False
        body = client("s3").get_object(Bucket=bucket, Key=v["Key"], VersionId=v["VersionId"])["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != match[3]:
            return False
        try:
            payloads = [json.loads(x) for x in body.splitlines()]
        except (ValueError, UnicodeError):
            return False
        if payloads != [expected[s]["payload"] for s in seqs]:
            return False
        seen.update(seqs)
    # Missing tail is handled by archiving, but missing already-archived rows
    # demand replay. Orphan objects and overlaps demand canonical regeneration.
    return all((r["archived_at"] is not None) == (r["seq"] in seen) for r in rows)


def reconcile_archive(conn, m, deadline):
    bucket = m["audit"]["bucket_name"]
    if not archive_valid(conn, m):
        # Outbox remains authoritative. Reset only replayable archival metadata;
        # the worker generates every key/body and stamps archived_at itself.
        sql(conn, "UPDATE clearledger.outbox SET archived_at=NULL WHERE archived_at IS NOT NULL")
        conn.commit()
        purge_versions(bucket, versions(bucket))
    drain(conn, m, "published_at IS NOT NULL AND archived_at IS NULL", "audit_archiver", deadline)
    if not archive_valid(conn, m):
        raise RuntimeError("Audit archive failed canonical validation")
    purge_versions(bucket, [v for v in versions(bucket) if v["marker"] or not v["IsLatest"]])


def scan_table(table):
    out = []
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        r = client("dynamodb").scan(**kw)
        out.extend(r.get("Items", []))
        if not r.get("LastEvaluatedKey"):
            return out
        kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]


def av(v):
    if isinstance(v, int):
        return {"N": str(v)}
    return {"S": v}


def reconcile_projection(conn, m, commit=True):
    table = m["projections"]["table_name"]
    ddb = client("dynamodb")
    cache = redis.Redis(host=m["cache"]["endpoint"], port=m["cache"]["port"], socket_timeout=5, decode_responses=True)
    # Short write barrier: requests already committed remain available, while
    # new writes wait for exact projection convergence. Projector is paused.
    # All four locks use application write order to avoid lock-order inversion.
    sql(conn, "SET LOCAL lock_timeout='15s'")
    sql(conn, "LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE MODE")
    settlements = sql(conn, "SELECT * FROM clearledger.settlements ORDER BY settlement_id")
    events = sql(conn, "SELECT * FROM clearledger.events ORDER BY settlement_id,aggregate_version")
    expected = {}
    projections = {}
    latest = {str(e["settlement_id"]): e["payload"]["occurredAt"] for e in events}
    for s in settlements:
        sid = str(s["settlement_id"])
        pk = "SETTLEMENT#" + sid
        state = dict(PK=pk, SK="STATE", GSI1PK="ACCOUNT#" + s["account_id"], GSI1SK=pk,
                     settlement_id=sid, account_id=s["account_id"], reference=s["reference"],
                     debit_party=s["debit_party"], credit_party=s["credit_party"], status=s["current_status"],
                     clearing_stage=s["current_stage"], version=s["version"], entry_count=s["entry_count"], updated_at=latest[sid])
        if s["last_entry_id"] is not None:
            state["last_entry_id"] = str(s["last_entry_id"])
        if s["last_memo"] is not None:
            state["last_memo"] = s["last_memo"]
        expected[(pk, "STATE")] = {k: av(v) for k, v in state.items()}
        projections[sid] = dict(settlementId=sid, accountId=s["account_id"], reference=s["reference"],
                                debitParty=s["debit_party"], creditParty=s["credit_party"], status=s["current_status"],
                                clearingStage=s["current_stage"], lastEntryId=str(s["last_entry_id"]) if s["last_entry_id"] else None,
                                lastMemo=s["last_memo"], version=s["version"], entryCount=s["entry_count"], updatedAt=latest[sid])
    for e in events:
        sid = str(e["settlement_id"])
        p = e["payload"]
        d = p["data"]
        item = dict(PK="SETTLEMENT#" + sid, SK=f'EVENT#{e["aggregate_version"]:08d}', settlement_id=sid,
                    event_id=str(e["event_id"]), version=e["aggregate_version"], event_type=e["event_type"],
                    status=d["status"], clearing_stage=d["clearingStage"], occurred_at=p["occurredAt"],
                    correlation_id=e["correlation_id"], envelope=json.dumps(p, separators=(",", ":"), sort_keys=True))
        if d.get("entryId") is not None:
            item["entry_id"] = d["entryId"]
        if d.get("memo") is not None:
            item["memo"] = d["memo"]
        expected[(item["PK"], item["SK"])] = {k: av(v) for k, v in item.items()}
    actual = {(x["PK"]["S"], x["SK"]["S"]): x for x in scan_table(table)}
    for key in actual.keys() - expected.keys():
        ddb.delete_item(TableName=table, Key={"PK": av(key[0]), "SK": av(key[1])})
    for key, item in expected.items():
        if actual.get(key) != item:
            ddb.put_item(TableName=table, Item=item)
    # Purge every stray key, including keys outside the settlement namespace.
    keys = {"clearledger:settlement:" + s for s in projections}
    for key in cache.scan_iter(count=500):
        if key not in keys:
            cache.delete(key)
    with cache.pipeline() as pipe:
        for sid, p in projections.items():
            pipe.set("clearledger:settlement:" + sid, json.dumps(p, separators=(",", ":")), ex=90)
        pipe.execute()
    verified = {(x["PK"]["S"], x["SK"]["S"]): x for x in scan_table(table)}
    if verified != expected:
        raise RuntimeError("Projection table did not converge")
    for sid, p in projections.items():
        key = "clearledger:settlement:" + sid
        if json.loads(cache.get(key)) != p or not 0 < cache.ttl(key) <= 90:
            raise RuntimeError("Cache did not converge")
    if commit:
        conn.commit()
    print(f"Reconciled {len(settlements)} settlements and {len(events)} ledger events")


def reconcile():
    m = manifest()
    conn = db(m)
    conn.autocommit = True
    deadline = time.monotonic() + 300
    barrier = db(m)
    try:
        schedules(m, False)
        mapping(m, False)
        # Allow in-flight scheduled invocations / SQS batches to finish.
        time.sleep(4)
        # Block only aggregate writes during the final convergence window.
        # Workers may still publish/archive outbox metadata on their own
        # connections. PostgreSQL's SHARE lock waits for earlier API writes.
        sql(barrier, "SET LOCAL lock_timeout='20s'")
        sql(barrier, "LOCK TABLE clearledger.settlements IN SHARE MODE")
        drain(conn, m, "published_at IS NULL", "outbox_relay", deadline)
        reconcile_archive(conn, m, deadline)
        # Let queued duplicates / legitimate backlog run through the supplied
        # projector before cache population, as each delivery invalidates cache.
        mapping(m, True)
        end = min(deadline, time.monotonic() + 60)
        quiet = 0
        while time.monotonic() < end:
            a = client("sqs").get_queue_attributes(QueueUrl=m["messaging"]["queue_url"], AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"])["Attributes"]
            quiet = quiet + 1 if all(int(v) == 0 for v in a.values()) else 0
            if quiet >= 3:
                break
            time.sleep(1)
        if quiet < 3:
            raise RuntimeError("Projector backlog did not drain")
        mapping(m, False)
        time.sleep(1)
        reconcile_projection(barrier, m, commit=False)
        if count(conn, "published_at IS NULL OR archived_at IS NULL"):
            raise RuntimeError("Outbox did not fully converge")
    finally:
        barrier.rollback()
        barrier.close()
        conn.close()
        # Always restore the operational triggers, including after an error.
        schedules(m, True)
        mapping(m, True)
    print("Derived stores converged; worker triggers restored")


def scoped_buckets():
    s3 = client("s3")
    for b in s3.list_buckets().get("Buckets", []):
        name = b["Name"]
        if name.startswith("cl-base-"):
            continue
        tags = optional(s3.get_bucket_tagging, Bucket=name)
        if scoped(name, tags.get("TagSet", []) if tags else []):
            yield name


def pre_destroy():
    # Remove dependency blockers before Terraform's reverse dependency graph.
    vpcs = client("ec2").describe_vpcs()["Vpcs"]
    ids = [v["VpcId"] for v in vpcs if scoped("", v.get("Tags", []))]
    path = ROOT / ".teardown-scope.json"
    if path.exists():
        old = json.loads(path.read_text())
        if old.get("resource_prefix") == PREFIX:
            ids += old.get("vpc_ids", [])
    if (ROOT / "manifest.json").exists():
        m = manifest()
        if m["resource_prefix"] == PREFIX:
            ids.append(m["network"]["vpc_id"])
    path.write_text(json.dumps({"resource_prefix": PREFIX, "vpc_ids": sorted(set(ids))}))
    for s in pages("scheduler", "list_schedules", "Schedules"):
        if scoped(s["Name"]):
            optional(client("scheduler").delete_schedule, Name=s["Name"], GroupName=s.get("GroupName", "default"))
    for e in pages("lambda", "list_event_source_mappings", "EventSourceMappings"):
        if scoped(e.get("FunctionArn", "").rsplit(":", 1)[-1]):
            optional(client("lambda").delete_event_source_mapping, UUID=e["UUID"])
    time.sleep(4)
    # Removing queues here also handles dangling DLQ redrive references and
    # avoids waiting on emulator-specific SQS deletion consistency timers.
    sqs = client("sqs")
    for url in pages("sqs", "list_queues", "QueueUrls"):
        tags = optional(sqs.list_queue_tags, QueueUrl=url)
        if scoped(url.rsplit("/", 1)[-1], (tags or {}).get("Tags", {})):
            optional(sqs.delete_queue, QueueUrl=url)
    repair_iam(all_roles=True)
    for b in scoped_buckets():
        purge_versions(b, versions(b))
        objects = pages("s3", "list_objects_v2", "Contents", Bucket=b)
        for o in objects:
            client("s3").delete_object(Bucket=b, Key=o["Key"])
        purge_versions(b, versions(b))


def cleanup():
    # Additional operational resources may be absent from state. Enumerate
    # explicitly rather than deleting by broad account-wide wildcards.
    sch = client("scheduler")
    for s in pages("scheduler", "list_schedules", "Schedules"):
        if scoped(s["Name"]):
            optional(sch.delete_schedule, Name=s["Name"], GroupName=s.get("GroupName", "default"))
    lam = client("lambda")
    for f in pages("lambda", "list_functions", "Functions"):
        tags = lam.list_tags(Resource=f["FunctionArn"]).get("Tags", {})
        if scoped(f["FunctionName"], tags):
            for e in pages("lambda", "list_event_source_mappings", "EventSourceMappings", FunctionName=f["FunctionName"]):
                optional(lam.delete_event_source_mapping, UUID=e["UUID"])
            optional(lam.delete_function, FunctionName=f["FunctionName"])
    sqs = client("sqs")
    for url in pages("sqs", "list_queues", "QueueUrls"):
        tags = optional(sqs.list_queue_tags, QueueUrl=url)
        if scoped(url.rsplit("/", 1)[-1], (tags or {}).get("Tags", {})):
            optional(sqs.delete_queue, QueueUrl=url)
    ddb = client("dynamodb")
    for name in pages("dynamodb", "list_tables", "TableNames"):
        t = ddb.describe_table(TableName=name)["Table"]
        tags = ddb.list_tags_of_resource(ResourceArn=t["TableArn"]).get("Tags", [])
        if scoped(name, tags):
            optional(ddb.delete_table, TableName=name)
    for b in list(scoped_buckets()):
        purge_versions(b, versions(b))
        for o in pages("s3", "list_objects_v2", "Contents", Bucket=b):
            client("s3").delete_object(Bucket=b, Key=o["Key"])
        purge_versions(b, versions(b))
        optional(client("s3").delete_bucket, Bucket=b)
    repair_iam(all_roles=True)
    iam = client("iam")
    for role in pages("iam", "list_roles", "Roles"):
        name = role["RoleName"]
        if scoped(name, iam.list_role_tags(RoleName=name).get("Tags", [])):
            for profile in pages("iam", "list_instance_profiles_for_role", "InstanceProfiles", RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile["InstanceProfileName"], RoleName=name)
                if scoped(profile["InstanceProfileName"]):
                    iam.delete_instance_profile(InstanceProfileName=profile["InstanceProfileName"])
            optional(iam.delete_role, RoleName=name)
    logs = client("logs")
    for g in pages("logs", "describe_log_groups", "logGroups"):
        if scoped(g["logGroupName"], logs.list_tags_log_group(logGroupName=g["logGroupName"]).get("tags", {})):
            optional(logs.delete_log_group, logGroupName=g["logGroupName"])
    kms = client("kms")
    key_ids = set()
    for a in pages("kms", "list_aliases", "Aliases"):
        if a["AliasName"].startswith("alias/" + PREFIX + "-"):
            if a.get("TargetKeyId"):
                key_ids.add(a["TargetKeyId"])
            optional(kms.delete_alias, AliasName=a["AliasName"])
    for k in pages("kms", "list_keys", "Keys"):
        meta = kms.describe_key(KeyId=k["KeyId"])["KeyMetadata"]
        if meta.get("KeyManager") != "CUSTOMER":
            continue
        tags = kms.list_resource_tags(KeyId=k["KeyId"]).get("Tags", [])
        tag_dict = {t["TagKey"]: t["TagValue"] for t in tags}
        if k["KeyId"] in key_ids or scoped(meta.get("Description", ""), tag_dict):
            if meta["KeyState"] != "PendingDeletion":
                kms.schedule_key_deletion(KeyId=k["KeyId"], PendingWindowInDays=10)
    rds = client("rds")
    for r in pages("rds", "describe_db_instances", "DBInstances"):
        if scoped(r["DBInstanceIdentifier"], r.get("TagList", [])):
            optional(rds.delete_db_instance, DBInstanceIdentifier=r["DBInstanceIdentifier"], SkipFinalSnapshot=True)
    cache = client("elasticache")
    for r in pages("elasticache", "describe_replication_groups", "ReplicationGroups"):
        tags = cache.list_tags_for_resource(ResourceName=r["ARN"]).get("TagList", [])
        if scoped(r["ReplicationGroupId"], tags):
            optional(cache.delete_replication_group, ReplicationGroupId=r["ReplicationGroupId"], RetainPrimaryCluster=False)
    for r in pages("elasticache", "describe_cache_clusters", "CacheClusters"):
        if scoped(r["CacheClusterId"]) and not r.get("ReplicationGroupId"):
            optional(cache.delete_cache_cluster, CacheClusterId=r["CacheClusterId"])
    cleanup_compute_network()
    print("Prefix-scoped operational resources removed")


def cleanup_compute_network():
    ecs = client("ecs")
    for arn in pages("ecs", "list_clusters", "clusterArns"):
        cluster = ecs.describe_clusters(clusters=[arn], include=["TAGS"])["clusters"][0]
        tags = {t["key"]: t["value"] for t in cluster.get("tags", [])}
        owned_cluster = scoped(cluster["clusterName"], tags)
        for service_arn in pages("ecs", "list_services", "serviceArns", cluster=arn):
            service = ecs.describe_services(cluster=arn, services=[service_arn], include=["TAGS"])["services"][0]
            stags = {t["key"]: t["value"] for t in service.get("tags", [])}
            if owned_cluster or scoped(service["serviceName"], stags):
                ecs.update_service(cluster=arn, service=service_arn, desiredCount=0)
                ecs.delete_service(cluster=arn, service=service_arn, force=True)
        if owned_cluster:
            for task in pages("ecs", "list_tasks", "taskArns", cluster=arn):
                ecs.stop_task(cluster=arn, task=task, reason="ClearLedger teardown")
            ecs.delete_cluster(cluster=arn)
    for arn in pages("ecs", "list_task_definitions", "taskDefinitionArns", status="ACTIVE"):
        definition = ecs.describe_task_definition(taskDefinition=arn, include=["TAGS"])
        tags = {t["key"]: t["value"] for t in definition.get("tags", [])}
        if scoped(definition["taskDefinition"]["family"], tags):
            ecs.deregister_task_definition(taskDefinition=arn)
    elb = client("elbv2")
    for lb in pages("elbv2", "describe_load_balancers", "LoadBalancers"):
        tags = elb.describe_tags(ResourceArns=[lb["LoadBalancerArn"]])["TagDescriptions"][0].get("Tags", [])
        if scoped(lb["LoadBalancerName"], tags):
            optional(elb.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in pages("elbv2", "describe_target_groups", "TargetGroups"):
        tags = elb.describe_tags(ResourceArns=[tg["TargetGroupArn"]])["TagDescriptions"][0].get("Tags", [])
        if scoped(tg["TargetGroupName"], tags):
            optional(elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])
    cog = client("cognito-idp")
    for p in pages("cognito-idp", "list_user_pools", "UserPools", MaxResults=60):
        detail = cog.describe_user_pool(UserPoolId=p["Id"])["UserPool"]
        if scoped(p["Name"], detail.get("UserPoolTags", {})):
            if detail.get("Domain"):
                optional(cog.delete_user_pool_domain, Domain=detail["Domain"], UserPoolId=p["Id"])
            optional(cog.delete_user_pool, UserPoolId=p["Id"])
        else:
            for c in pages("cognito-idp", "list_user_pool_clients", "UserPoolClients", UserPoolId=p["Id"], MaxResults=60):
                if scoped(c["ClientName"]):
                    optional(cog.delete_user_pool_client, UserPoolId=p["Id"], ClientId=c["ClientId"])
    for g in pages("rds", "describe_db_subnet_groups", "DBSubnetGroups"):
        if scoped(g["DBSubnetGroupName"]):
            optional(client("rds").delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    for g in pages("elasticache", "describe_cache_subnet_groups", "CacheSubnetGroups"):
        if scoped(g["CacheSubnetGroupName"]):
            optional(client("elasticache").delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])
    ec2 = client("ec2")
    def owned(r, field=""):
        tags = {t["Key"]: t["Value"] for t in r.get("Tags", [])}
        return scoped(r.get(field, tags.get("Name", "")), tags)
    vpcs = ec2.describe_vpcs()["Vpcs"]
    current_vpcs = {v["VpcId"] for v in vpcs}
    scope_path = ROOT / ".teardown-scope.json"
    scope = json.loads(scope_path.read_text()) if scope_path.exists() else {}
    deleted_vpcs = set(scope.get("vpc_ids", [])) - current_vpcs if scope.get("resource_prefix") == PREFIX else set()
    # Some local control planes leave an untagged default SG/main route table
    # after DeleteVpc. Only sweep defaults belonging to recorded owned VPCs.
    groups = [g for g in ec2.describe_security_groups()["SecurityGroups"] if owned(g, "GroupName") or g.get("VpcId") in deleted_vpcs]
    for g in groups:
        if g.get("IpPermissions"):
            ec2.revoke_security_group_ingress(GroupId=g["GroupId"], IpPermissions=g["IpPermissions"])
        if g.get("IpPermissionsEgress"):
            ec2.revoke_security_group_egress(GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
    for g in groups:
        optional(ec2.delete_security_group, GroupId=g["GroupId"])
    for s in ec2.describe_subnets()["Subnets"]:
        if owned(s):
            optional(ec2.delete_subnet, SubnetId=s["SubnetId"])
    for r in ec2.describe_route_tables()["RouteTables"]:
        if (owned(r) and not any(a.get("Main") for a in r.get("Associations", []))) or r.get("VpcId") in deleted_vpcs:
            for a in r.get("Associations", []):
                if not a.get("Main"):
                    optional(ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
            optional(ec2.delete_route_table, RouteTableId=r["RouteTableId"])
    for g in ec2.describe_internet_gateways()["InternetGateways"]:
        if owned(g):
            for a in g.get("Attachments", []):
                optional(ec2.detach_internet_gateway, InternetGatewayId=g["InternetGatewayId"], VpcId=a["VpcId"])
            optional(ec2.delete_internet_gateway, InternetGatewayId=g["InternetGatewayId"])
    for v in ec2.describe_vpcs()["Vpcs"]:
        if owned(v):
            optional(ec2.delete_vpc, VpcId=v["VpcId"])


def empty_state():
    state = json.loads((ROOT / "infra/terraform.tfstate").read_text())
    if any(r.get("mode") == "managed" and r.get("instances") for r in state.get("resources", [])):
        raise RuntimeError("Managed resources remain in Terraform state")
    print("Teardown complete: zero managed resources in state")


if __name__ == "__main__":
    commands = {"guard": guard, "repair": repair, "protect": protect, "manifest": export_manifest,
                "schema": schema, "ready": ready, "reconcile": reconcile, "pre-destroy": pre_destroy,
                "cleanup": cleanup, "empty-state": empty_state}
    commands[sys.argv[1]]()
