from __future__ import annotations

import base64
import json
import os
import random
import subprocess
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import boto3
import httpx
import psycopg
import redis

WORKSPACE = Path("/workspace")
CONFIG_PATH = WORKSPACE / "config" / "config.json"
BASELINE_PATH = WORKSPACE / "config" / ".baseline.json"
CONTRACTS_DIR = WORKSPACE / "contracts"
SUBMISSION_DIR = WORKSPACE / "submission"
INFRA_DIR = SUBMISSION_DIR / "infra"
STATE_PATH = INFRA_DIR / "terraform.tfstate"
MANIFEST_PATH = SUBMISSION_DIR / "manifest.json"

CLEARING_STAGE_POOL = [
    ("VALIDATED", "SANCTIONS_SCREENED"),
    ("RESERVED", "LIQUIDITY_LOCKED"),
    ("CLEARED", "NETTING_CONFIRMED"),
    ("SETTLED", "RTGS_FINALIZED"),
    ("RECONCILED", "NOSTRO_MATCHED"),
]


def load_config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text())


def load_baseline() -> dict[str, Any]:
    return json.loads(BASELINE_PATH.read_text())


def load_manifest() -> dict[str, Any]:
    return json.loads(MANIFEST_PATH.read_text())


def load_tfstate() -> dict[str, Any]:
    return json.loads(STATE_PATH.read_text())


def boto_client(service: str, config: dict[str, Any] | None = None):
    cfg = config or load_config()
    return boto3.client(
        service,
        region_name=cfg["region"],
        endpoint_url=cfg["aws_endpoint_url"],
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )


def run_script(script_path: Path, timeout_sec: int) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    cfg = load_config()
    env.setdefault("AWS_DEFAULT_REGION", cfg["region"])
    env.setdefault("AWS_REGION", cfg["region"])
    env.setdefault("AWS_ENDPOINT_URL", cfg["aws_endpoint_url"])
    env.setdefault("AWS_ACCESS_KEY_ID", "test")
    env.setdefault("AWS_SECRET_ACCESS_KEY", "test")
    env.setdefault("TF_CLI_CONFIG_FILE", "/etc/terraform.tfrc")
    return subprocess.run(
        ["/bin/bash", str(script_path)],
        cwd=str(SUBMISSION_DIR),
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
        check=False,
    )


def resolve_floci_host(host: str, config: dict[str, Any] | None = None) -> str:
    cfg = config or load_config()
    endpoint = cfg.get("aws_endpoint_url", "http://aws:4566")
    floci_host = endpoint.split("://")[-1].split(":")[0].split("/")[0]
    if not host or host.endswith(".amazonaws.com") or host == "localhost":
        return floci_host
    return host


def resolve_service_url(service_url: str, config: dict[str, Any] | None = None) -> str:
    cfg = config or load_config()
    floci_host = resolve_floci_host("", cfg)
    cleaned = service_url.strip().rstrip("/")
    if ".amazonaws.com" in cleaned:
        return f"http://{floci_host}:80"
    return cleaned


def pg_connect(manifest: dict[str, Any], config: dict[str, Any]):
    db = manifest["database"]
    host = resolve_floci_host(str(db["endpoint"]), config)
    conninfo = (
        f"host={host} port={db['port']} dbname={db['db_name']} "
        f"user={db['username']} password={config['db_password']} connect_timeout=5"
    )
    return psycopg.connect(conninfo)


def valkey_connect(manifest: dict[str, Any], config: dict[str, Any] | None = None) -> redis.Redis:
    cache = manifest["cache"]
    host = resolve_floci_host(str(cache["endpoint"]), config)
    return redis.Redis(
        host=host,
        port=int(cache["port"]),
        decode_responses=True,
        socket_connect_timeout=5,
        socket_timeout=5,
    )


def fetch_oauth_token(
    manifest: dict[str, Any],
    role: str,
    scope_override: str | None = None,
    secret_override: str | None = None,
    client_id_override: str | None = None,
) -> tuple[int, dict[str, Any]]:
    cfg = load_config()
    auth = manifest["auth"]
    client_cfg = auth["clients"][role]
    client_id = client_id_override if client_id_override is not None else client_cfg["client_id"]
    client_secret = secret_override if secret_override is not None else client_cfg["client_secret"]
    scope = scope_override if scope_override is not None else client_cfg["scope"]

    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    fallback_url = f"{cfg['aws_endpoint_url'].rstrip('/')}/cognito-idp/oauth2/token"
    candidate_urls = [auth["token_endpoint"]]
    if fallback_url not in candidate_urls:
        candidate_urls.append(fallback_url)

    last_status = 500
    last_body: dict[str, Any] = {}
    with httpx.Client(timeout=10.0) as client:
        for url in candidate_urls:
            try:
                resp = client.post(
                    url,
                    headers={
                        "Authorization": f"Basic {basic}",
                        "Content-Type": "application/x-www-form-urlencoded",
                    },
                    data={
                        "grant_type": "client_credentials",
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "scope": scope,
                    },
                )
                try:
                    body = resp.json()
                except Exception:
                    body = {"raw": resp.text}
                last_status, last_body = resp.status_code, body
                if resp.status_code == 200 and "access_token" in body:
                    return resp.status_code, body
                if resp.status_code in {400, 401, 403}:
                    return resp.status_code, body
            except Exception as err:  # noqa: BLE001
                last_body = {"error": str(err)}
    return last_status, last_body


def get_access_token(manifest: dict[str, Any], role: str) -> str:
    status, body = fetch_oauth_token(manifest, role)
    assert status == 200 and "access_token" in body, f"OAuth token fetch failed for {role}: {status} {body}"
    return body["access_token"]


def wait_until(
    predicate: Callable[[], Any],
    timeout_sec: float = 45.0,
    interval_sec: float = 1.0,
    description: str = "condition",
) -> Any:
    deadline = time.monotonic() + timeout_sec
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except Exception as err:  # noqa: BLE001
            last_err = err
        time.sleep(interval_sec)
    if last_err is not None:
        raise AssertionError(f"Timed out waiting for {description}: {last_err}") from last_err
    raise AssertionError(f"Timed out waiting for {description}")


def invoke_lambda_sync(function_name: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    lam = boto_client("lambda")
    resp = lam.invoke(
        FunctionName=function_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload or {"source": "verifier"}).encode(),
    )
    raw = resp["Payload"].read().decode()
    return json.loads(raw) if raw else {}


def build_random_settlement_spec(rng: random.Random, step_count: int | None = None) -> dict[str, Any]:
    settlement_id = str(uuid.uuid4())
    account_id = f"acct-{rng.randint(1000, 9999)}"
    reference = f"CLR-{rng.randint(100000, 999999)}"
    bank_pairs = [
        ("CITIUS33", "CHASUS33"),
        ("BOFAUS3N", "IRVTUS3N"),
        ("DEUTDEFF", "BNPAFRPP"),
        ("BARCGB22", "HSBCGB2L"),
        ("UBSWCHZH", "SOGEFRPP"),
    ]
    debit_party, credit_party = rng.choice(bank_pairs)
    count = step_count if step_count is not None else rng.randint(3, 5)
    chosen = CLEARING_STAGE_POOL[:count]
    base_time = datetime.now(timezone.utc)
    entries = []
    for idx, (status, stage) in enumerate(chosen, start=1):
        entries.append(
            {
                "entryId": str(uuid.uuid4()),
                "status": status,
                "clearingStage": f"{stage}_{idx}",
                "memo": f"Clearing step {idx} at {stage}",
                "occurredAt": (base_time + timedelta(seconds=idx)).isoformat(),
                "expectedVersion": idx,
            }
        )
    return {
        "settlementId": settlement_id,
        "accountId": account_id,
        "reference": reference,
        "debitParty": debit_party,
        "creditParty": credit_party,
        "entries": entries,
    }


def snapshot_inventory(config: dict[str, Any] | None = None) -> dict[str, set[str]]:
    cfg = config or load_config()
    s3 = boto_client("s3", cfg)
    sqs = boto_client("sqs", cfg)
    ddb = boto_client("dynamodb", cfg)
    lam = boto_client("lambda", cfg)
    ecs = boto_client("ecs", cfg)
    elbv2 = boto_client("elbv2", cfg)
    rds = boto_client("rds", cfg)
    ec = boto_client("elasticache", cfg)
    cognito = boto_client("cognito-idp", cfg)
    iam = boto_client("iam", cfg)
    logs = boto_client("logs", cfg)
    ec2 = boto_client("ec2", cfg)
    scheduler = boto_client("scheduler", cfg)

    inv: dict[str, set[str]] = {}
    inv["s3_buckets"] = {b["Name"] for b in s3.list_buckets().get("Buckets", [])}
    inv["sqs_queues"] = set(sqs.list_queues().get("QueueUrls", []))
    inv["dynamodb_tables"] = set(ddb.list_tables().get("TableNames", []))
    inv["lambda_functions"] = {f["FunctionName"] for f in lam.list_functions().get("Functions", [])}
    inv["ecs_clusters"] = set(ecs.list_clusters().get("clusterArns", []))
    inv["load_balancers"] = {lb["LoadBalancerArn"] for lb in elbv2.describe_load_balancers().get("LoadBalancers", [])}
    inv["target_groups"] = {tg["TargetGroupArn"] for tg in elbv2.describe_target_groups().get("TargetGroups", [])}
    inv["rds_instances"] = {
        db["DBInstanceIdentifier"] for db in rds.describe_db_instances().get("DBInstances", [])
    }
    inv["elasticache_clusters"] = {
        c["CacheClusterId"] for c in ec.describe_cache_clusters().get("CacheClusters", [])
    } | {
        rg["ReplicationGroupId"] for rg in ec.describe_replication_groups().get("ReplicationGroups", [])
    }
    inv["cognito_pools"] = {
        p["Id"] for p in cognito.list_user_pools(MaxResults=60).get("UserPools", [])
    }
    inv["iam_roles"] = {r["RoleName"] for r in iam.list_roles().get("Roles", [])}
    auto_log_prefixes = ("/aws/rds/", "/aws/elasticache/", "/aws/lambda/", "/ecs/")
    inv["log_groups"] = {
        lg["logGroupName"]
        for lg in logs.describe_log_groups().get("logGroups", [])
        if not lg["logGroupName"].startswith(auto_log_prefixes)
    }
    inv["vpcs"] = {
        v["VpcId"]
        for v in ec2.describe_vpcs().get("Vpcs", [])
        if not v.get("IsDefault", False)
    }
    inv["schedules"] = {
        s["Name"] for s in scheduler.list_schedules().get("Schedules", [])
    }
    return inv


def diff_inventory(before: dict[str, set[str]], after: dict[str, set[str]]) -> dict[str, dict[str, list[str]]]:
    additions: dict[str, list[str]] = {}
    removals: dict[str, list[str]] = {}
    for key in sorted(set(before) | set(after)):
        added = sorted(after.get(key, set()) - before.get(key, set()))
        removed = sorted(before.get(key, set()) - after.get(key, set()))
        if added:
            additions[key] = added
        if removed:
            removals[key] = removed
    return {"additions": additions, "removals": removals}
