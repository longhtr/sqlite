#!/usr/bin/env python3
"""Validate dependency-closed atomic-unit dossiers through assurance."""

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
    zig = {item["id"]: item for item in zig_inventory["declarations"]}
    mappings = {item["id"]: item for item in symbol_map["entities"]}
    indexed_paths = {ROOT / item["path"] for item in index["units"]}
    actual_paths = set(DIRECTORY.glob("*.json")) - {INDEX}
    if indexed_paths != actual_paths:
        fail(f"index paths differ: missing={sorted(actual_paths-indexed_paths)} stale={sorted(indexed_paths-actual_paths)}")

    unit_ids: set[str] = set()
    dossiers_by_id: dict[str, dict[str, object]] = {}
    assigned_source: dict[str, str] = {}
    assigned_behaviors: dict[str, str] = {}
    counts = {state: 0 for state in STATES}
    for summary in index["units"]:
        dossier = json.loads((ROOT / summary["path"]).read_text())
        unit_id = dossier.get("id")
        if not unit_id or unit_id in unit_ids:
            fail(f"missing/duplicate unit id: {unit_id}")
        unit_ids.add(unit_id)
        dossiers_by_id[unit_id] = dossier
        status = dossier.get("status")
        if status not in STATES or summary.get("id") != unit_id or summary.get("status") != status:
            fail(f"{unit_id}: index/status mismatch")
        status_index = STATES.index(status)
        counts[status] += 1
        if dossier.get("schema_version") != 1:
            fail(f"{unit_id}: schema mismatch")
        context_required = status_index >= STATES.index("source-context-reviewed")
        if dossier.get("admission_ready") is not context_required:
            fail(f"{unit_id}: admission-ready flag differs from evidence state")
        if context_required:
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
            if context_required and any(
                marker in relation for marker in ("placeholder", "review-boundary", "untranslated-boundary")
            ):
                fail(f"{unit_id}: context review maps {identity} to a non-implementation boundary")
            canonical = mappings.get(identity, {})
            if canonical.get("classification") != status:
                fail(f"{unit_id}: symbol-map state differs for {identity}")
            declarations = item.get("zig_declaration_ids", [])
            if not declarations:
                fail(f"{unit_id}: source mapping has no Zig target: {identity}")
            for declaration in declarations:
                if declaration not in zig:
                    fail(f"{unit_id}: unknown Zig declaration {declaration}")
            canonical_declarations = {
                target.get("declaration_id")
                for target in canonical.get("zig", [])
                if isinstance(target, dict)
            }
            if set(declarations) != canonical_declarations:
                fail(f"{unit_id}: dossier and symbol-map targets differ for {identity}")

        assurance = dossier.get("assurance", {})
        for state, flag in FLAG_FOR_STATE.items():
            expected = status_index >= STATES.index(state)
            if assurance.get(flag) is not expected:
                fail(f"{unit_id}: assurance.{flag} differs from evidence state {status}")
        receipts = dossier.get("evidence_receipts", [])
        if status_index >= STATES.index("internal-trace-equivalent"):
            if not isinstance(receipts, list) or not receipts:
                fail(f"{unit_id}: trace-equivalent state requires durable evidence receipts")
            declaration_ids = sorted({
                declaration
                for mapping in dossier_mappings
                for declaration in mapping["zig_declaration_ids"]
            })
            source_scope_sha256 = hashlib.sha256("\n".join(
                f"{identity}\t{source[identity]['source_sha256']}"
                for identity in sorted(source_ids)
            ).encode()).hexdigest()
            zig_scope_sha256 = hashlib.sha256("\n".join(
                f"{identity}\t{zig[identity]['source_sha256']}"
                for identity in declaration_ids
            ).encode()).hexdigest()
            commands = assurance.get("commands", [])
            for receipt in receipts:
                required_receipt = {
                    "command", "result_owner", "result_sha256",
                    "source_scope_sha256", "zig_scope_sha256",
                }
                if not isinstance(receipt, dict) or set(receipt) != required_receipt:
                    fail(f"{unit_id}: malformed durable evidence receipt")
                if not all(isinstance(receipt[key], str) and receipt[key] for key in required_receipt):
                    fail(f"{unit_id}: incomplete durable evidence receipt")
                if receipt["command"] not in commands:
                    fail(f"{unit_id}: receipt command is absent from assurance commands")
                owner = pathlib.PurePosixPath(receipt["result_owner"])
                if owner.is_absolute() or ".." in owner.parts:
                    fail(f"{unit_id}: receipt result owner escapes the repository")
                owner_path = ROOT / owner
                if not owner_path.is_file() or hashlib.sha256(owner_path.read_bytes()).hexdigest() != receipt["result_sha256"]:
                    fail(f"{unit_id}: receipt result owner is missing or stale")
                if receipt["source_scope_sha256"] != source_scope_sha256:
                    fail(f"{unit_id}: receipt source scope is stale")
                if receipt["zig_scope_sha256"] != zig_scope_sha256:
                    fail(f"{unit_id}: receipt Zig scope is stale")
        elif receipts:
            fail(f"{unit_id}: pre-trace state must not carry promotion receipts")
        if status_index >= STATES.index("assurance-passed") and not assurance.get("commands"):
            fail(f"{unit_id}: assurance status requires executable commands")
        required_sections = {
            "dependencies", "contracts", "representation_differences", "oracle",
            "assurance", "integration", "independent_review", "known_blockers",
        }
        missing = sorted(required_sections - dossier.keys())
        if missing:
            fail(f"{unit_id}: missing dossier sections {missing}")

    stale_dependencies = sorted(
        dependency
        for dossier in dossiers_by_id.values()
        for dependency in dossier["dependencies"]["atomic_unit_ids"]
        if dependency not in unit_ids
    )
    if stale_dependencies:
        fail(f"unknown atomic-unit dependencies: {stale_dependencies}")

    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(unit_id: str) -> None:
        if unit_id in visiting:
            fail(f"atomic-unit dependency cycle reaches {unit_id}")
        if unit_id in visited:
            return
        visiting.add(unit_id)
        unit_status = dossiers_by_id[unit_id]["status"]
        for dependency in dossiers_by_id[unit_id]["dependencies"]["atomic_unit_ids"]:
            dependency_status = dossiers_by_id[dependency]["status"]
            if STATES.index(dependency_status) < STATES.index(unit_status):
                fail(
                    f"{unit_id}: state {unit_status} exceeds dependency "
                    f"{dependency} at {dependency_status}"
                )
            visit(dependency)
        visiting.remove(unit_id)
        visited.add(unit_id)

    for unit_id in sorted(unit_ids):
        visit(unit_id)
    print(
        f"verify-atomic-units: {len(unit_ids)} dossiers; "
        f"{len(assigned_source)} source entities and {len(assigned_behaviors)} behavior blocks assigned; "
        f"{counts['assurance-passed']} assurance-passed"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
