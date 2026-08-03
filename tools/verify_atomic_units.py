#!/usr/bin/env python3
"""Validate dependency-closed atomic-unit dossiers and independent-review boundaries."""

from __future__ import annotations

import hashlib
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / "upstream/atomic-units"
INDEX = DIRECTORY / "index.json"
STATES = [
    "inventoried",
    "source-context-reviewed",
    "scaffolded",
    "source-translated",
    "internal-trace-equivalent",
    "subsystem-integrated",
    "assurance-passed",
    "independently-fidelity-reviewed",
]
FLAG_FOR_STATE = {
    "source-context-reviewed": "source_context_reviewed",
    "source-translated": "source_translated",
    "internal-trace-equivalent": "internal_trace_equivalent",
    "subsystem-integrated": "subsystem_integrated",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify-atomic-units: {message}")


def main() -> None:
    index = json.loads(INDEX.read_text())
    source_inventory = json.loads((ROOT / "upstream/source-inventory.json").read_text())
    behavior_inventory = json.loads((ROOT / "upstream/behavioral-inventory.json").read_text())
    zig_inventory = json.loads((ROOT / "upstream/zig-declaration-inventory.json").read_text())
    symbol_map = json.loads((ROOT / "upstream/symbol-map.json").read_text())
    if index.get("schema_version") != 1 or index.get("sqlite_checkin") != source_inventory["sqlite_checkin"]:
        fail("index baseline/schema mismatch")

    source = {
        item["id"]: item for item in source_inventory["entities"]
        if item["activity"].startswith("active-profile")
    }
    behaviors = {item["id"]: item for item in behavior_inventory["blocks"]}
    zig = {item["id"] for item in zig_inventory["declarations"]}
    mappings = {item["id"]: item for item in symbol_map["entities"]}
    indexed_paths = {ROOT / item["path"] for item in index["units"]}
    actual_paths = set(DIRECTORY.glob("*.json")) - {INDEX}
    if indexed_paths != actual_paths:
        fail(f"index paths differ: missing={sorted(actual_paths-indexed_paths)} stale={sorted(indexed_paths-actual_paths)}")

    unit_ids: set[str] = set()
    assigned_source: dict[str, str] = {}
    assigned_behaviors: dict[str, str] = {}
    counts = {state: 0 for state in STATES}
    for summary in index["units"]:
        dossier = json.loads((ROOT / summary["path"]).read_text())
        unit_id = dossier.get("id")
        if not unit_id or unit_id in unit_ids:
            fail(f"missing/duplicate unit id: {unit_id}")
        unit_ids.add(unit_id)
        status = dossier.get("status")
        if status not in STATES or summary.get("id") != unit_id or summary.get("status") != status:
            fail(f"{unit_id}: index/status mismatch")
        counts[status] += 1
        if dossier.get("schema_version") != 1:
            fail(f"{unit_id}: schema mismatch")
        if not dossier.get("admission_ready") and STATES.index(status) >= STATES.index("source-translated"):
            fail(f"{unit_id}: translated status without admission-ready dossier")
        if status == "source-context-reviewed":
            if not dossier.get("admission_ready"):
                fail(f"{unit_id}: context-reviewed status without admission-ready dossier")
            context_review = dossier.get("context_review", {})
            required_context = {
                "implementation_spans", "callers", "callees",
                "assertions_branches_cleanup", "upstream_tests",
            }
            missing_context = sorted(
                key for key in required_context
                if not isinstance(context_review.get(key), list) or not context_review[key]
            )
            if missing_context:
                fail(f"{unit_id}: context review lacks nonempty evidence {missing_context}")

        scope = dossier.get("scope", {})
        for file_record in scope.get("source_files", []):
            path = ROOT / "upstream/sqlite" / file_record["path"]
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != file_record["sha256"]:
                fail(f"{unit_id}: source file/hash mismatch: {file_record.get('path')}")
        source_ids = scope.get("source_entity_ids", [])
        behavior_ids = scope.get("behavioral_block_ids", [])
        if len(source_ids) != len(set(source_ids)) or len(behavior_ids) != len(set(behavior_ids)):
            fail(f"{unit_id}: duplicate responsibility identity")
        for identity in source_ids:
            if identity not in source:
                fail(f"{unit_id}: unknown/inactive source entity {identity}")
            if identity in assigned_source:
                fail(f"{identity}: assigned to both {assigned_source[identity]} and {unit_id}")
            assigned_source[identity] = unit_id
        for identity in behavior_ids:
            if identity not in behaviors:
                fail(f"{unit_id}: unknown behavior block {identity}")
            if identity in assigned_behaviors:
                fail(f"{identity}: assigned to both {assigned_behaviors[identity]} and {unit_id}")
            assigned_behaviors[identity] = unit_id

        dossier_mappings = dossier.get("mappings", [])
        if {item.get("source_entity_id") for item in dossier_mappings} != set(source_ids):
            fail(f"{unit_id}: mappings do not exactly cover source entities")
        for item in dossier_mappings:
            identity = item["source_entity_id"]
            relation = item.get("relation", "").lower()
            if status == "source-context-reviewed" and any(
                marker in relation for marker in ("placeholder", "review-boundary", "untranslated-boundary")
            ):
                fail(f"{unit_id}: context review maps {identity} to a non-implementation boundary")
            if mappings.get(identity, {}).get("classification") != status:
                fail(f"{unit_id}: symbol-map state differs for {identity}")
            if not item.get("zig_declaration_ids"):
                fail(f"{unit_id}: source mapping has no Zig target: {identity}")
            for declaration in item["zig_declaration_ids"]:
                if declaration not in zig:
                    fail(f"{unit_id}: unknown Zig declaration {declaration}")

        assurance = dossier.get("assurance", {})
        status_index = STATES.index(status)
        for state, flag in FLAG_FOR_STATE.items():
            if status_index >= STATES.index(state) and assurance.get(flag) is not True:
                fail(f"{unit_id}: {status} requires assurance.{flag}=true")
        if status_index >= STATES.index("assurance-passed") and not assurance.get("commands"):
            fail(f"{unit_id}: assurance status requires executable commands")
        review = dossier.get("independent_review", {})
        if status == "independently-fidelity-reviewed":
            if review.get("status") != "passed" or not review.get("reviewer") or not review.get("review_commit"):
                fail(f"{unit_id}: final promotion lacks independent reviewer/commit")
        elif review.get("status") == "passed":
            fail(f"{unit_id}: passed independent review without final status")

        required_sections = {
            "dependencies", "contracts", "representation_differences", "oracle",
            "assurance", "integration", "independent_review", "known_blockers",
        }
        missing = sorted(required_sections - dossier.keys())
        if missing:
            fail(f"{unit_id}: missing dossier sections {missing}")

    stale_dependencies = sorted(
        dependency
        for summary in index["units"]
        for dependency in json.loads((ROOT / summary["path"]).read_text())["dependencies"]["atomic_unit_ids"]
        if dependency not in unit_ids
    )
    if stale_dependencies:
        fail(f"unknown atomic-unit dependencies: {stale_dependencies}")
    print(
        f"verify-atomic-units: {len(unit_ids)} dossiers; "
        f"{len(assigned_source)} source entities and {len(assigned_behaviors)} behavior blocks assigned; "
        f"{counts['independently-fidelity-reviewed']} independently reviewed"
    )


if __name__ == "__main__":
    main()
