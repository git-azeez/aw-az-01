from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

BLOCKS: dict[str, dict[str, Any]] = {
    "declared.iac_discipline": {"section": "declared", "weight": 3},
    "declared.compute_ingress": {"section": "declared", "weight": 2},
    "declared.data_async": {"section": "declared", "weight": 2},
    "declared.security": {"section": "declared", "weight": 3},
    "live.compute_ingress": {"section": "live", "weight": 5},
    "live.data_event_graph": {"section": "live", "weight": 5},
    "live.security": {"section": "live", "weight": 5},
    "functional.workflow": {"section": "functional", "weight": 9},
    "functional.cache": {"section": "functional", "weight": 7},
    "functional.idempotency_concurrency": {"section": "functional", "weight": 8},
    "async.backlog_recovery": {"section": "async", "weight": 7},
    "async.duplicate_and_dlq": {"section": "async", "weight": 6},
    "recovery.outbox_recovery": {"section": "recovery", "weight": 6},
    "recovery.projection_rebuild": {"section": "recovery", "weight": 5},
    "recovery.ecs_task_replacement": {"section": "recovery", "weight": 5},
    "recovery.rds_reboot": {"section": "recovery", "weight": 4},
    "security.auth_audit_logs": {"section": "security", "weight": 3},
    "lifecycle.reapply_idempotence": {"section": "lifecycle", "weight": 7},
    "lifecycle.clean_destroy": {"section": "lifecycle", "weight": 8},
}


@dataclass
class ScoreRecorder:
    results: dict[str, dict[str, Any]] = field(default_factory=dict)
    gates: dict[str, bool] = field(
        default_factory=lambda: {
            "submission_layout": False,
            "deploy_succeeded": False,
            "manifest_valid": False,
            "service_reachable": False,
        }
    )
    caps: dict[str, int] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        for block_id, meta in BLOCKS.items():
            self.results[block_id] = {
                "section": meta["section"],
                "weight": meta["weight"],
                "passed": False,
                "earned": 0,
                "detail": "not executed",
            }

    def set_gate(self, gate: str, value: bool, note: str | None = None) -> None:
        self.gates[gate] = bool(value)
        if note:
            self.notes.append(f"gate[{gate}]: {note}")

    def add_cap(self, reason: str, cap_value: int) -> None:
        current = self.caps.get(reason)
        if current is None or cap_value < current:
            self.caps[reason] = cap_value

    def record(self, block_id: str, passed: bool, detail: str = "") -> None:
        meta = BLOCKS[block_id]
        self.results[block_id] = {
            "section": meta["section"],
            "weight": meta["weight"],
            "passed": bool(passed),
            "earned": meta["weight"] if passed else 0,
            "detail": detail or ("passed" if passed else "failed"),
        }

    def summary(self) -> dict[str, Any]:
        raw_score = sum(item["earned"] for item in self.results.values())
        gates_passed = all(self.gates.values())
        capped_score = raw_score if gates_passed else 0
        for cap in self.caps.values():
            capped_score = min(capped_score, cap)

        sections: dict[str, dict[str, int]] = {}
        for item in self.results.values():
            sec = item["section"]
            sections.setdefault(sec, {"earned": 0, "possible": 0})
            sections[sec]["earned"] += item["earned"]
            sections[sec]["possible"] += item["weight"]

        passed = gates_passed and capped_score == 100 and raw_score == 100
        return {
            "raw_score": raw_score,
            "final_score": capped_score,
            "max_score": 100,
            "gates_passed": gates_passed,
            "gates": self.gates,
            "caps": self.caps,
            "passed": passed,
            "reward": 1.0 if passed else 0.0,
            "sections": sections,
            "blocks": self.results,
            "notes": self.notes,
        }

    def write_outputs(self) -> dict[str, Any]:
        data = self.summary()
        verifier_dir = Path("/logs/verifier")
        evidence_dir = Path("/workspace/evidence")
        verifier_dir.mkdir(parents=True, exist_ok=True)
        evidence_dir.mkdir(parents=True, exist_ok=True)

        (verifier_dir / "results.json").write_text(json.dumps(data, indent=2) + "\n")
        (evidence_dir / "verifier_results.json").write_text(json.dumps(data, indent=2) + "\n")
        reward_str = "1\n" if data["passed"] else "0\n"
        (verifier_dir / "reward.txt").write_text(reward_str)
        (verifier_dir / "reward.json").write_text(
            json.dumps({"reward": data["reward"], "score": data["final_score"]}) + "\n"
        )
        return data
