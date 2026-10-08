from __future__ import annotations

import base64
from fnmatch import fnmatchcase
import json
import os
import random
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import boto3
from botocore.config import Config as BotoConfig
import httpx
import psycopg
import redis

for _proxy_var in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
    os.environ.pop(_proxy_var, None)
os.environ["NO_PROXY"] = "localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
os.environ["no_proxy"] = os.environ["NO_PROXY"]
os.environ["AWS_EC2_METADATA_DISABLED"] = "true"

_BOTO_CONFIG = BotoConfig(
    retries={"max_attempts": 2, "mode": "standard"},
    connect_timeout=3,
    read_timeout=10,
    proxies={},
)

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
        config=_BOTO_CONFIG,
    )


def _iac_env() -> dict[str, str]:
    env = os.environ.copy()
    for pvar in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
        env.pop(pvar, None)
    cfg = load_config()
    env.setdefault("AWS_DEFAULT_REGION", cfg["region"])
    env.setdefault("AWS_REGION", cfg["region"])
    env.setdefault("AWS_ENDPOINT_URL", cfg["aws_endpoint_url"])
    env.setdefault("AWS_ACCESS_KEY_ID", "test")
    env.setdefault("AWS_SECRET_ACCESS_KEY", "test")
    env.setdefault("AWS_EC2_METADATA_DISABLED", "true")
    env.setdefault("NO_PROXY", os.environ["NO_PROXY"])
    env.setdefault("no_proxy", os.environ["NO_PROXY"])
    env.setdefault("TF_CLI_CONFIG_FILE", "/etc/terraform.tfrc")
    env.setdefault("TF_IN_AUTOMATION", "1")
    for key, val in cfg.items():
        if isinstance(val, (str, int, float, bool)):
            env.setdefault(f"TF_VAR_{key}", str(val))
    return env


def resolve_iac_binaries(infra_dir: Path = INFRA_DIR) -> list[str]:
    lock_file = infra_dir / ".terraform.lock.hcl"
    preferred = ["terraform", "tofu"]
    if lock_file.is_file():
        lock_text = lock_file.read_text(errors="ignore")
        if "registry.opentofu.org" in lock_text and "registry.terraform.io" not in lock_text:
            preferred = ["tofu", "terraform"]
    available = [b for b in preferred if shutil.which(b)]
    assert available, "Neither terraform nor tofu is installed in the test environment"
    return available


def run_iac_validate(infra_dir: Path = INFRA_DIR) -> tuple[str, str]:
    env = _iac_env()
    errors: list[str] = []
    for binary in resolve_iac_binaries(infra_dir):
        proc = subprocess.run(
            [binary, "validate", "-no-color"],
            cwd=str(infra_dir),
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if proc.returncode == 0:
            return binary, proc.stdout.strip()
        errors.append(f"{binary} validate (rc={proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
    raise AssertionError("IaC validation failed:\n" + "\n".join(errors))


def _collect_module_config_resources(module_obj: dict[str, Any], out: dict[str, dict[str, Any]]) -> None:
    for res in module_obj.get("resources", []) or []:
        if res.get("mode") == "managed":
            addr = f"{res.get('type')}.{res.get('name')}"
            out[addr] = res.get("expressions") or {}
    for child in module_obj.get("child_modules", []) or []:
        if isinstance(child, dict):
            _collect_module_config_resources(child, out)


def load_iac_configuration(infra_dir: Path = INFRA_DIR) -> dict[str, dict[str, Any]]:
    """Extract parsed Terraform/OpenTofu configuration expressions via `plan -refresh=false` + `show -json`."""
    env = _iac_env()
    for binary in resolve_iac_binaries(infra_dir):
        with tempfile.TemporaryDirectory(prefix="clearledger-iac-") as tmpdir:
            plan_path = Path(tmpdir) / "tfplan"
            plan_proc = subprocess.run(
                [
                    binary,
                    "plan",
                    "-refresh=false",
                    "-input=false",
                    "-no-color",
                    f"-state={STATE_PATH}",
                    f"-out={plan_path}",
                ],
                cwd=str(infra_dir),
                env=env,
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
            if plan_proc.returncode != 0 or not plan_path.is_file():
                continue
            show_proc = subprocess.run(
                [binary, "show", "-json", str(plan_path)],
                cwd=str(infra_dir),
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            if show_proc.returncode != 0 or not show_proc.stdout.strip():
                continue
            doc = json.loads(show_proc.stdout)
            root_mod = (doc.get("configuration") or {}).get("root_module") or {}
            out: dict[str, dict[str, Any]] = {}
            _collect_module_config_resources(root_mod, out)
            return out
    return {}


def config_expr_constant(expr: Any) -> Any:
    if isinstance(expr, dict):
        if "constant_value" in expr:
            return expr["constant_value"]
    return None


def config_depends_on_resource(expr: Any, target_prefix: str) -> bool:
    if isinstance(expr, dict):
        refs = expr.get("references") or []
        if any(str(r) == target_prefix or str(r).startswith(target_prefix) for r in refs):
            return True
        return any(config_depends_on_resource(v, target_prefix) for v in expr.values())
    if isinstance(expr, list):
        return any(config_depends_on_resource(item, target_prefix) for item in expr)
    return False


def _parse_policy_doc(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        text = raw.strip()
        if text.startswith("%7B") or text.startswith("%7b"):
            text = urllib.parse.unquote(text)
        return json.loads(text) if text else {}
    return {}


def _as_str_list(val: Any) -> list[str]:
    if isinstance(val, str):
        return [val]
    if isinstance(val, list):
        return [str(x) for x in val if x is not None]
    return []


def validate_trust_policy(doc: Any, expected_service: str, role_label: str) -> None:
    parsed = _parse_policy_doc(doc)
    stmts = parsed.get("Statement") or []
    if isinstance(stmts, dict):
        stmts = [stmts]
    allowed_services: set[str] = set()
    for stmt in stmts:
        if not isinstance(stmt, dict) or stmt.get("Effect") != "Allow":
            continue
        actions = [a.lower() for a in _as_str_list(stmt.get("Action"))]
        if not any(fnmatchcase("sts:assumerole", pat) for pat in actions):
            continue
        principal = stmt.get("Principal") or {}
        if principal == "*":
            raise AssertionError(f"{role_label} trust policy must not allow wildcard Principal '*'")
        if isinstance(principal, dict):
            for svc in _as_str_list(principal.get("Service")):
                allowed_services.add(svc)
    assert expected_service in allowed_services, (
        f"{role_label} trust policy must allow Service '{expected_service}', found {sorted(allowed_services)}"
    )
    assert allowed_services == {expected_service}, (
        f"{role_label} trust policy must only trust '{expected_service}', found {sorted(allowed_services)}"
    )


def policy_allows(policy_docs: list[dict[str, Any]], action: str, resource: str) -> bool:
    action_l = action.lower()
    allowed = False
    for raw_doc in policy_docs:
        doc = _parse_policy_doc(raw_doc)
        stmts = doc.get("Statement") or []
        if isinstance(stmts, dict):
            stmts = [stmts]
        for stmt in stmts:
            if not isinstance(stmt, dict):
                continue
            effect = stmt.get("Effect")
            actions = [a.lower() for a in _as_str_list(stmt.get("Action"))]
            resources = _as_str_list(stmt.get("Resource"))
            act_match = any(fnmatchcase(action_l, pat) for pat in actions)
            res_match = any(fnmatchcase(resource, pat) for pat in resources)
            if act_match and res_match:
                if effect == "Deny":
                    return False
                if effect == "Allow":
                    allowed = True
    return allowed


def policy_allows_any_resource(policy_docs: list[dict[str, Any]], action: str, resources: list[str]) -> bool:
    return any(policy_allows(policy_docs, action, r) for r in resources)


def _lg_arn_candidates(lg_name: str, raw_arn: str | None, region: str) -> list[str]:
    base = (raw_arn or f"arn:aws:logs:{region}:000000000000:log-group:{lg_name}").rstrip(":*")
    return [base, f"{base}:*", f"{base}:log-stream:*"]


def verify_iam_roles_and_policies(
    manifest: dict[str, Any],
    role_trust_docs: dict[str, Any],
    role_policy_docs: dict[str, list[dict[str, Any]]],
    log_group_arns: dict[str, str],
    label: str = "IAM",
) -> None:
    expected_trust = {
        "ecs_execution_role_arn": "ecs-tasks.amazonaws.com",
        "ecs_task_role_arn": "ecs-tasks.amazonaws.com",
        "projector_role_arn": "lambda.amazonaws.com",
        "relay_role_arn": "lambda.amazonaws.com",
        "archiver_role_arn": "lambda.amazonaws.com",
        "scheduler_role_arn": "scheduler.amazonaws.com",
    }
    iam_map = manifest["iam"]
    assert len(set(iam_map.values())) == 6, f"{label}: all 6 IAM role ARNs must be distinct"

    for role_key, expected_svc in expected_trust.items():
        role_arn = iam_map[role_key]
        assert role_arn in role_trust_docs, f"{label}: missing trust policy for {role_key} ({role_arn})"
        validate_trust_policy(role_trust_docs[role_arn], expected_svc, f"{label} {role_key}")

        docs = role_policy_docs.get(role_arn) or []
        assert docs, f"{label}: role {role_key} ({role_arn}) has no attached or inline policies"
        for raw_doc in docs:
            doc = _parse_policy_doc(raw_doc)
            stmts = doc.get("Statement") or []
            if isinstance(stmts, dict):
                stmts = [stmts]
            for stmt in stmts:
                if not isinstance(stmt, dict) or stmt.get("Effect") != "Allow":
                    continue
                for act in _as_str_list(stmt.get("Action")):
                    assert act != "*" and not act.endswith(":*"), (
                        f"{label}: wildcard IAM action '{act}' is forbidden in {role_key}"
                    )
                for res in _as_str_list(stmt.get("Resource")):
                    assert res != "*", f"{label}: wildcard IAM resource '*' is forbidden in {role_key}"

    region = manifest.get("region", "us-east-1")
    queue_arn = manifest["messaging"]["queue_arn"]
    dlq_arn = manifest["messaging"]["dlq_arn"]
    table_arn = manifest["projections"]["table_arn"]
    index_arn = f"{table_arn}/index/{manifest['projections']['gsi_name']}"
    bucket_arn = manifest["audit"]["bucket_arn"]
    audit_prefix = str(manifest["audit"]["prefix"]).lstrip("/")
    audit_obj_arn = f"{bucket_arn}/{audit_prefix}probe.ndjson"

    kms_db = manifest["kms"]["database_arn"]
    kms_msg = manifest["kms"]["messaging_arn"]
    kms_proj = manifest["kms"]["projection_arn"]
    kms_audit = manifest["kms"]["audit_arn"]

    projector_fn_arn = manifest["workers"]["projector"]["function_arn"]
    relay_fn_arn = manifest["workers"]["outbox_relay"]["function_arn"]
    archiver_fn_arn = manifest["workers"]["audit_archiver"]["function_arn"]

    lg_api = _lg_arn_candidates(
        manifest["logs"]["api_log_group"],
        log_group_arns.get(manifest["logs"]["api_log_group"]),
        region,
    )
    lg_proj = _lg_arn_candidates(
        manifest["logs"]["projector_log_group"],
        log_group_arns.get(manifest["logs"]["projector_log_group"]),
        region,
    )
    lg_relay = _lg_arn_candidates(
        manifest["logs"]["relay_log_group"],
        log_group_arns.get(manifest["logs"]["relay_log_group"]),
        region,
    )
    lg_arch = _lg_arn_candidates(
        manifest["logs"]["archiver_log_group"],
        log_group_arns.get(manifest["logs"]["archiver_log_group"]),
        region,
    )

    def _docs(rkey: str) -> list[dict[str, Any]]:
        return role_policy_docs[iam_map[rkey]]

    # 1. ecs_execution_role_arn
    exec_docs = _docs("ecs_execution_role_arn")
    for act in ("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"):
        assert policy_allows_any_resource(exec_docs, act, lg_api), (
            f"{label}: ecs_execution_role_arn must allow {act} on API log group"
        )
    for forbidden_lg, lg_label in ((lg_proj, "projector"), (lg_relay, "relay"), (lg_arch, "archiver")):
        for log_act in ("logs:PutLogEvents", "logs:CreateLogStream"):
            assert not policy_allows_any_resource(exec_docs, log_act, forbidden_lg), (
                f"{label}: ecs_execution_role_arn must not allow {log_act} on {lg_label} log group (no shared /clearledger/* wildcard)"
            )
    for kms_arn, kms_label in ((kms_db, "database"), (kms_msg, "messaging"), (kms_proj, "projection"), (kms_audit, "audit")):
        for kms_act in ("kms:Decrypt", "kms:GenerateDataKey"):
            assert not policy_allows(exec_docs, kms_act, kms_arn), (
                f"{label}: ecs_execution_role_arn must not allow {kms_act} on {kms_label} KMS key"
            )
    assert not policy_allows(exec_docs, "sqs:SendMessage", queue_arn), (
        f"{label}: ecs_execution_role_arn must not allow sqs:SendMessage"
    )
    assert not policy_allows(exec_docs, "dynamodb:GetItem", table_arn), (
        f"{label}: ecs_execution_role_arn must not allow dynamodb:GetItem"
    )
    assert not policy_allows(exec_docs, "s3:PutObject", audit_obj_arn), (
        f"{label}: ecs_execution_role_arn must not allow s3:PutObject"
    )

    # 2. ecs_task_role_arn
    task_docs = _docs("ecs_task_role_arn")
    for act in ("sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"):
        assert policy_allows(task_docs, act, queue_arn), f"{label}: ecs_task_role_arn must allow {act} on main queue"
    for act in ("dynamodb:GetItem", "dynamodb:Query", "dynamodb:DescribeTable"):
        assert policy_allows(task_docs, act, table_arn), f"{label}: ecs_task_role_arn must allow {act} on table"
    assert policy_allows(task_docs, "dynamodb:Query", index_arn), (
        f"{label}: ecs_task_role_arn must allow dynamodb:Query on AccountIndex"
    )
    for act in ("kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"):
        assert policy_allows(task_docs, act, kms_msg), f"{label}: ecs_task_role_arn must allow {act} on messaging KMS"
        assert policy_allows(task_docs, act, kms_proj), (
            f"{label}: ecs_task_role_arn must allow {act} on projection KMS"
        )
    for act in ("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"):
        assert policy_allows_any_resource(task_docs, act, lg_api), (
            f"{label}: ecs_task_role_arn must allow {act} on API log group"
        )
    for forbidden_lg, lg_label in ((lg_proj, "projector"), (lg_relay, "relay"), (lg_arch, "archiver")):
        for log_act in ("logs:PutLogEvents", "logs:CreateLogStream"):
            assert not policy_allows_any_resource(task_docs, log_act, forbidden_lg), (
                f"{label}: ecs_task_role_arn must not allow {log_act} on {lg_label} log group"
            )
    for sqs_forbid in ("sqs:ReceiveMessage", "sqs:DeleteMessage"):
        assert not policy_allows(task_docs, sqs_forbid, queue_arn), (
            f"{label}: ecs_task_role_arn must not allow {sqs_forbid} on main queue"
        )
    assert not policy_allows(task_docs, "sqs:SendMessage", dlq_arn), (
        f"{label}: ecs_task_role_arn must not allow sqs:SendMessage on DLQ"
    )
    for ddb_forbid in ("dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"):
        assert not policy_allows(task_docs, ddb_forbid, table_arn), (
            f"{label}: ecs_task_role_arn must not allow {ddb_forbid} on projection table"
        )
    assert not policy_allows(task_docs, "s3:PutObject", audit_obj_arn), (
        f"{label}: ecs_task_role_arn must not allow s3:PutObject on audit bucket"
    )
    for kms_arn, kms_label in ((kms_db, "database"), (kms_audit, "audit")):
        for kms_act in ("kms:Decrypt", "kms:GenerateDataKey"):
            assert not policy_allows(task_docs, kms_act, kms_arn), (
                f"{label}: ecs_task_role_arn must not allow {kms_act} on {kms_label} KMS key"
            )

    # 3. projector_role_arn
    proj_docs = _docs("projector_role_arn")
    for act in ("sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"):
        assert policy_allows(proj_docs, act, queue_arn), f"{label}: projector_role_arn must allow {act} on main queue"
    assert policy_allows(proj_docs, "sqs:SendMessage", dlq_arn), (
        f"{label}: projector_role_arn must allow sqs:SendMessage on DLQ"
    )
    for act in ("dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"):
        assert policy_allows(proj_docs, act, table_arn), f"{label}: projector_role_arn must allow {act} on table"
    assert policy_allows(proj_docs, "dynamodb:Query", index_arn), (
        f"{label}: projector_role_arn must allow dynamodb:Query on AccountIndex"
    )
    for act in ("kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"):
        assert policy_allows(proj_docs, act, kms_msg), f"{label}: projector_role_arn must allow {act} on messaging KMS"
        assert policy_allows(proj_docs, act, kms_proj), (
            f"{label}: projector_role_arn must allow {act} on projection KMS"
        )
    for act in ("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"):
        assert policy_allows_any_resource(proj_docs, act, lg_proj), (
            f"{label}: projector_role_arn must allow {act} on projector log group"
        )
    for forbidden_lg, lg_label in ((lg_api, "API"), (lg_relay, "relay"), (lg_arch, "archiver")):
        for log_act in ("logs:PutLogEvents", "logs:CreateLogStream"):
            assert not policy_allows_any_resource(proj_docs, log_act, forbidden_lg), (
                f"{label}: projector_role_arn must not allow {log_act} on {lg_label} log group"
            )
    assert not policy_allows(proj_docs, "sqs:SendMessage", queue_arn), (
        f"{label}: projector_role_arn must not allow sqs:SendMessage on main queue"
    )
    assert not policy_allows(proj_docs, "sqs:ReceiveMessage", dlq_arn), (
        f"{label}: projector_role_arn must not allow sqs:ReceiveMessage on DLQ"
    )
    assert not policy_allows(proj_docs, "dynamodb:DeleteItem", table_arn), (
        f"{label}: projector_role_arn must not allow dynamodb:DeleteItem on projection table"
    )
    assert not policy_allows(proj_docs, "s3:PutObject", audit_obj_arn), (
        f"{label}: projector_role_arn must not allow s3:PutObject on audit bucket"
    )
    for kms_arn, kms_label in ((kms_db, "database"), (kms_audit, "audit")):
        for kms_act in ("kms:Decrypt", "kms:GenerateDataKey"):
            assert not policy_allows(proj_docs, kms_act, kms_arn), (
                f"{label}: projector_role_arn must not allow {kms_act} on {kms_label} KMS key"
            )

    # 4. relay_role_arn
    relay_docs = _docs("relay_role_arn")
    for act in ("sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"):
        assert policy_allows(relay_docs, act, queue_arn), f"{label}: relay_role_arn must allow {act} on main queue"
    for act in ("kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"):
        assert policy_allows(relay_docs, act, kms_msg), f"{label}: relay_role_arn must allow {act} on messaging KMS"
        assert policy_allows(relay_docs, act, kms_db), f"{label}: relay_role_arn must allow {act} on database KMS"
    for act in ("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"):
        assert policy_allows_any_resource(relay_docs, act, lg_relay), (
            f"{label}: relay_role_arn must allow {act} on relay log group"
        )
    for forbidden_lg, lg_label in ((lg_api, "API"), (lg_proj, "projector"), (lg_arch, "archiver")):
        for log_act in ("logs:PutLogEvents", "logs:CreateLogStream"):
            assert not policy_allows_any_resource(relay_docs, log_act, forbidden_lg), (
                f"{label}: relay_role_arn must not allow {log_act} on {lg_label} log group"
            )
    for sqs_forbid in ("sqs:ReceiveMessage", "sqs:DeleteMessage"):
        assert not policy_allows(relay_docs, sqs_forbid, queue_arn), (
            f"{label}: relay_role_arn must not allow {sqs_forbid} on main queue"
        )
    assert not policy_allows(relay_docs, "sqs:SendMessage", dlq_arn), (
        f"{label}: relay_role_arn must not allow sqs:SendMessage on DLQ"
    )
    for ddb_forbid in ("dynamodb:GetItem", "dynamodb:PutItem"):
        assert not policy_allows(relay_docs, ddb_forbid, table_arn), (
            f"{label}: relay_role_arn must not allow {ddb_forbid}"
        )
    assert not policy_allows(relay_docs, "s3:PutObject", audit_obj_arn), (
        f"{label}: relay_role_arn must not allow s3:PutObject"
    )
    for kms_arn, kms_label in ((kms_proj, "projection"), (kms_audit, "audit")):
        for kms_act in ("kms:Decrypt", "kms:GenerateDataKey"):
            assert not policy_allows(relay_docs, kms_act, kms_arn), (
                f"{label}: relay_role_arn must not allow {kms_act} on {kms_label} KMS key"
            )

    # 5. archiver_role_arn
    arch_docs = _docs("archiver_role_arn")
    for act in ("s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"):
        assert policy_allows(arch_docs, act, audit_obj_arn), (
            f"{label}: archiver_role_arn must allow {act} on {audit_obj_arn}"
        )
    assert not policy_allows(arch_docs, "s3:PutObject", f"{bucket_arn}/unscoped-root-object.ndjson"), (
        f"{label}: archiver_role_arn s3:PutObject must be scoped to {bucket_arn}/ledger-audit/*, not {bucket_arn}/*"
    )
    for del_act in ("s3:DeleteObject", "s3:DeleteObjectVersion"):
        assert not policy_allows(arch_docs, del_act, audit_obj_arn), (
            f"{label}: archiver_role_arn must not allow {del_act} on immutable audit archive {audit_obj_arn}"
        )
    for act in ("s3:ListBucket", "s3:GetBucketLocation"):
        assert policy_allows(arch_docs, act, bucket_arn), (
            f"{label}: archiver_role_arn must allow {act} on {bucket_arn}"
        )
    for act in ("kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"):
        assert policy_allows(arch_docs, act, kms_audit), f"{label}: archiver_role_arn must allow {act} on audit KMS"
        assert policy_allows(arch_docs, act, kms_db), f"{label}: archiver_role_arn must allow {act} on database KMS"
    for act in ("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"):
        assert policy_allows_any_resource(arch_docs, act, lg_arch), (
            f"{label}: archiver_role_arn must allow {act} on archiver log group"
        )
    for forbidden_lg, lg_label in ((lg_api, "API"), (lg_proj, "projector"), (lg_relay, "relay")):
        for log_act in ("logs:PutLogEvents", "logs:CreateLogStream"):
            assert not policy_allows_any_resource(arch_docs, log_act, forbidden_lg), (
                f"{label}: archiver_role_arn must not allow {log_act} on {lg_label} log group"
            )
    assert not policy_allows(arch_docs, "sqs:SendMessage", queue_arn), (
        f"{label}: archiver_role_arn must not allow sqs:SendMessage"
    )
    assert not policy_allows(arch_docs, "dynamodb:PutItem", table_arn), (
        f"{label}: archiver_role_arn must not allow dynamodb:PutItem"
    )
    for kms_arn, kms_label in ((kms_msg, "messaging"), (kms_proj, "projection")):
        for kms_act in ("kms:Decrypt", "kms:GenerateDataKey"):
            assert not policy_allows(arch_docs, kms_act, kms_arn), (
                f"{label}: archiver_role_arn must not allow {kms_act} on {kms_label} KMS key"
            )

    # 6. scheduler_role_arn
    sched_docs = _docs("scheduler_role_arn")
    assert policy_allows(sched_docs, "lambda:InvokeFunction", relay_fn_arn), (
        f"{label}: scheduler_role_arn must allow lambda:InvokeFunction on outbox_relay"
    )
    assert policy_allows(sched_docs, "lambda:InvokeFunction", archiver_fn_arn), (
        f"{label}: scheduler_role_arn must allow lambda:InvokeFunction on audit_archiver"
    )
    assert not policy_allows(sched_docs, "lambda:InvokeFunction", projector_fn_arn), (
        f"{label}: scheduler_role_arn must not allow lambda:InvokeFunction on projector"
    )
    assert not policy_allows(sched_docs, "sqs:SendMessage", queue_arn), (
        f"{label}: scheduler_role_arn must not allow sqs:SendMessage"
    )
    assert not policy_allows(sched_docs, "s3:PutObject", audit_obj_arn), (
        f"{label}: scheduler_role_arn must not allow s3:PutObject"
    )
    for forbidden_lg, lg_label in ((lg_api, "API"), (lg_proj, "projector"), (lg_relay, "relay"), (lg_arch, "archiver")):
        for log_act in ("logs:PutLogEvents", "logs:CreateLogStream"):
            assert not policy_allows_any_resource(sched_docs, log_act, forbidden_lg), (
                f"{label}: scheduler_role_arn must not allow {log_act} on {lg_label} log group"
            )
    for kms_arn, kms_label in ((kms_db, "database"), (kms_msg, "messaging"), (kms_proj, "projection"), (kms_audit, "audit")):
        for kms_act in ("kms:Decrypt", "kms:GenerateDataKey"):
            assert not policy_allows(sched_docs, kms_act, kms_arn), (
                f"{label}: scheduler_role_arn must not allow {kms_act} on {kms_label} KMS key"
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
    kms = boto_client("kms", cfg)

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
    inv["iam_policies"] = {p["PolicyName"] for p in iam.list_policies(Scope="Local").get("Policies", [])}
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
    inv["kms_aliases"] = {
        a["AliasName"]
        for a in kms.list_aliases().get("Aliases", [])
        if not str(a.get("AliasName", "")).startswith("alias/aws/")
    }
    active_keys: set[str] = set()
    for k in kms.list_keys().get("Keys", []):
        kid = k.get("KeyId")
        if not kid:
            continue
        meta = kms.describe_key(KeyId=kid).get("KeyMetadata", {})
        if meta.get("KeyManager") == "CUSTOMER" and not str(meta.get("KeyState", "")).endswith("Deletion"):
            active_keys.add(meta.get("Arn") or kid)
    inv["kms_keys"] = active_keys
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

