from __future__ import annotations

import json
import random
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import jsonschema
import pytest

from .helpers import (
    CONTRACTS_DIR,
    INFRA_DIR,
    MANIFEST_PATH,
    STATE_PATH,
    SUBMISSION_DIR,
    load_baseline,
    load_config,
    load_manifest,
    resolve_service_url,
    run_script,
    snapshot_inventory,
    wait_until,
)
from .scoring import ScoreRecorder


@dataclass
class VerifierContext:
    config: dict[str, Any]
    baseline: dict[str, Any]
    pre_deploy_inventory: dict[str, set[str]]
    recorder: ScoreRecorder
    rng: random.Random
    manifest: dict[str, Any] = field(default_factory=dict)
    committed_settlements: dict[str, dict[str, Any]] = field(default_factory=dict)
    tokens: dict[str, str] = field(default_factory=dict)

    def refresh_manifest(self) -> dict[str, Any]:
        self.manifest = load_manifest()
        return self.manifest


_RECORDER = ScoreRecorder()


def _verify_submission_layout() -> tuple[bool, str]:
    deploy_sh = SUBMISSION_DIR / "deploy.sh"
    destroy_sh = SUBMISSION_DIR / "destroy.sh"
    if not deploy_sh.is_file():
        return False, "Missing /workspace/submission/deploy.sh"
    if not destroy_sh.is_file():
        return False, "Missing /workspace/submission/destroy.sh"
    if not INFRA_DIR.is_dir():
        return False, "Missing /workspace/submission/infra directory"
    tf_files = list(INFRA_DIR.rglob("*.tf")) + list(INFRA_DIR.rglob("*.tofu"))
    if not tf_files:
        return False, "No .tf or .tofu files found under /workspace/submission/infra"

    forbidden_State = [
        p
        for p in SUBMISSION_DIR.rglob("*")
        if p.name in {"terraform.tfstate", "terraform.tfstate.backup", ".terraform.lock.hcl"}
        and not STATE_PATH.exists()
    ]
    _ = forbidden_State
    return True, f"Found {len(tf_files)} IaC source files"


@pytest.fixture(scope="session")
def ctx() -> VerifierContext:
    config = load_config()
    baseline = load_baseline()
    seed = int(config["resource_prefix"].split("-")[-1], 16)
    rng = random.Random(seed)
    pre_inv = snapshot_inventory(config)

    layout_ok, layout_note = _verify_submission_layout()
    _RECORDER.set_gate("submission_layout", layout_ok, layout_note)
    assert layout_ok, layout_note

    deploy_sh = SUBMISSION_DIR / "deploy.sh"
    try:
        deploy_sh.chmod(0o755)
        (SUBMISSION_DIR / "destroy.sh").chmod(0o755)
    except OSError:
        pass

    deploy_proc = run_script(deploy_sh, timeout_sec=720)
    deploy_ok = deploy_proc.returncode == 0 and STATE_PATH.is_file()
    _RECORDER.set_gate(
        "deploy_succeeded",
        deploy_ok,
        f"rc={deploy_proc.returncode}" if deploy_ok else f"rc={deploy_proc.returncode}: {deploy_proc.stderr[-600:]}",
    )
    assert deploy_ok, f"deploy.sh failed (rc={deploy_proc.returncode}):\nSTDOUT:\n{deploy_proc.stdout[-1000:]}\nSTDERR:\n{deploy_proc.stderr[-1000:]}"

    assert MANIFEST_PATH.is_file(), "Missing /workspace/submission/manifest.json after deploy.sh"
    assert MANIFEST_PATH.stat().st_size <= 1024 * 1024, "manifest.json exceeds 1 MiB"
    manifest = load_manifest()
    schema = json.loads((CONTRACTS_DIR / "schemas" / "manifest.schema.json").read_text())
    try:
        jsonschema.validate(instance=manifest, schema=schema)
        assert manifest["resource_prefix"] == config["resource_prefix"]
        manifest_ok = True
        manifest_note = "manifest.json conforms to schema"
    except Exception as err:  # noqa: BLE001
        manifest_ok = False
        manifest_note = str(err)
    _RECORDER.set_gate("manifest_valid", manifest_ok, manifest_note)
    assert manifest_ok, f"manifest.json validation failed: {manifest_note}"

    service_url = resolve_service_url(manifest["service_url"], config)

    def _check_ready() -> bool:
        with httpx.Client(timeout=5.0) as client:
            r_live = client.get(f"{service_url}/health/live")
            r_ready = client.get(f"{service_url}/health/ready")
            return r_live.status_code == 200 and r_ready.status_code == 200

    try:
        wait_until(_check_ready, timeout_sec=60.0, interval_sec=1.5, description="API /health/ready == 200")
        reach_ok = True
        reach_note = f"{service_url}/health/ready returned 200"
    except Exception as err:  # noqa: BLE001
        reach_ok = False
        reach_note = str(err)
    _RECORDER.set_gate("service_reachable", reach_ok, reach_note)
    assert reach_ok, reach_note

    return VerifierContext(
        config=config,
        baseline=baseline,
        pre_deploy_inventory=pre_inv,
        recorder=_RECORDER,
        rng=rng,
        manifest=manifest,
    )


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    module_order = {
        "test_declared.py": 0,
        "test_live.py": 1,
        "test_behavior.py": 2,
        "test_lifecycle.py": 3,
    }
    items.sort(key=lambda item: module_order.get(Path(str(item.fspath)).name, 99))


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    _ = session, exitstatus
    _RECORDER.write_outputs()
