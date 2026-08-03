#!/usr/bin/env python3
"""Emit an honest whole-port compatibility report after the regression gates."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "zig-out/compatibility-report.json"


def digest(paths: list[Path]) -> str:
    value = hashlib.sha256()
    for path in sorted(paths):
        value.update(str(path.relative_to(ROOT)).encode())
        value.update(b"\0")
        value.update(path.read_bytes())
        value.update(b"\0")
    return value.hexdigest()


def main() -> None:
    port = json.loads((ROOT / "upstream/port-status.json").read_text())
    api = json.loads((ROOT / "upstream/api-manifest.json").read_text())
    phase17 = json.loads((ROOT / "upstream/phase17-manifest.json").read_text())
    profile = json.loads((ROOT / "upstream/SQLITE_BUILD_PROFILE.json").read_text())

    evidence_inputs = [
        ROOT / "upstream/port-status.json",
        ROOT / "upstream/source-inventory.json",
        ROOT / "upstream/source-dependencies.json",
        ROOT / "upstream/behavioral-inventory.json",
        ROOT / "upstream/zig-declaration-inventory.json",
        ROOT / "upstream/symbol-map.json",
        ROOT / "upstream/native-c-boundary.json",
        ROOT / "upstream/parser-action-coverage.json",
        ROOT / "upstream/vdbe-opcode-coverage.json",
        ROOT / "generated/opcodes/manifest.json",
        ROOT / "generated/parser/zig-tables-manifest.json",
        ROOT / "generated/internal/vdbe-layout.json",
        ROOT / "upstream/api-manifest.json",
        ROOT / "upstream/SQLITE_BUILD_PROFILE.json",
        ROOT / "tests/fixtures/phase17/manifest.json",
        ROOT / "docs/PORTING_CHARTER.md",
        ROOT / "docs/ENGINEERING_PROCESS.md",
        ROOT / "docs/CURRENT_STATE.md",
        ROOT / "docs/EXECUTION_PLAN.md",
        ROOT / "docs/TESTING.md",
        ROOT / "docs/decisions/ADR-0041-source-faithful-gates.md",
    ]
    evidence_inputs.extend(sorted((ROOT / "upstream/atomic-units").glob("*.json")))

    report = {
        "schema_version": 2,
        "overall_status": "incomplete-no-compatibility-claim",
        "goal": port["goal"],
        "baseline": {
            "sqlite_checkin": port["baseline_checkin"],
            "profile": profile["profile_id"],
        },
        "source_port": port["source"],
        "engineering_process": port["engineering_process"],
        "public_api": port["public_api"],
        "native_engine": port["implementation"],
        "test_interpretation": port["evidence"],
        "bounded_regressions": {
            "status": "passing when this report is emitted by `zig build compatibility-report`",
            "phase17": phase17["status"],
            "warning": "Regression success is not complete SQLite compatibility.",
        },
        "release": {
            "candidate": False,
            "product_kind": "Zig-native source-faithful port; not a drop-in C ABI replacement",
            "pure_zig_production_artifact": port["implementation"]["production_c_sources"] == 0,
            "data_safety_claim": False,
            "blockers": port["release_blockers"],
        },
        "evidence_digest": digest(evidence_inputs),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"compatibility-report: wrote {OUT.relative_to(ROOT)} (status: incomplete)")


if __name__ == "__main__":
    main()
