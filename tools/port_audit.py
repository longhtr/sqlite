#!/usr/bin/env python3
"""Generate or verify the honest whole-port status summary."""

from __future__ import annotations

import argparse
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "upstream/port-status.json"


def lines(path: pathlib.Path) -> int:
    return path.read_text(errors="ignore").count("\n") + 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    inventory = json.loads((ROOT / "upstream/source-inventory.json").read_text())
    mappings = json.loads((ROOT / "upstream/symbol-map.json").read_text())["entities"]
    zig_inventory = json.loads((ROOT / "upstream/zig-declaration-inventory.json").read_text())
    dependencies = json.loads((ROOT / "upstream/source-dependencies.json").read_text())
    behavioral = json.loads((ROOT / "upstream/behavioral-inventory.json").read_text())
    active_batch = json.loads((ROOT / "upstream/active-port-batch.json").read_text())
    historical_claim_ledger = json.loads((ROOT / active_batch["historical_claim_ledger"]).read_text())
    checkpoints = json.loads((ROOT / "upstream/port-checkpoints.json").read_text())
    atomic_index = json.loads((ROOT / "upstream/atomic-units/index.json").read_text())
    atomic_dossiers = [
        json.loads((ROOT / item["path"]).read_text()) for item in atomic_index["units"]
    ]
    api = json.loads((ROOT / "upstream/api-manifest.json").read_text())
    public_responsibilities = json.loads((ROOT / "upstream/public-responsibility-inventory.json").read_text())
    native_c = json.loads((ROOT / "upstream/native-c-boundary.json").read_text())
    opcodes = json.loads((ROOT / "generated/opcodes/manifest.json").read_text())
    opcode_coverage = json.loads((ROOT / "upstream/vdbe-opcode-coverage.json").read_text())
    parser_tables = json.loads((ROOT / "generated/parser/zig-tables-manifest.json").read_text())
    parser_action_coverage = json.loads((ROOT / "upstream/parser-action-coverage.json").read_text())
    internal_vdbe_layout = json.loads((ROOT / "generated/internal/vdbe-layout.json").read_text())
    internal_parse_layout = json.loads((ROOT / "generated/internal/parse-layout.json").read_text())

    active = {
        item["id"]: item
        for item in inventory["entities"]
        if item.get("activity", "").startswith("active-profile")
    }
    mapping_by_id = {item["id"]: item for item in mappings}
    active_mappings = [item for item in mappings if item["id"] in active]
    planning_states = {"inventoried"}
    reviewed_states = {
        "context-reviewed", "fidelity-ported", "generated",
        "targeted-differential-passed", "source-context-reviewed", "scaffolded",
        "source-translated", "internal-trace-equivalent", "subsystem-integrated",
        "assurance-passed", "subsystem-integration-passed",
        "architecture-irrelevant-reviewed",
    }
    inventoried_active = {
        item["id"] for item in active_mappings
        if item["classification"] in planning_states
    }
    reviewed_active = {
        item["id"] for item in active_mappings
        if item["classification"] in reviewed_states
    }
    legacy_candidates = {
        item["id"] for item in active_mappings
        if item["classification"].startswith("legacy-candidate-")
    }
    reviewed_target_references = sum(
        len(item.get("zig", [])) for item in mappings
        if item["classification"] in reviewed_states
    )
    resolved_legacy_target_references = sum(
        len(item.get("zig", [])) for item in mappings
        if item["classification"].startswith("legacy-candidate-")
    )
    unresolved_target_references = sum(
        len(item.get("unresolved_legacy_targets", [])) for item in active_mappings
    )
    explicitly_classified_active = {
        item["id"] for item in active_mappings
        if item["classification"] in planning_states | reviewed_states
        or item["classification"].startswith("legacy-candidate-")
    }
    unmapped_active = set(active) - explicitly_classified_active

    historical_claims = historical_claim_ledger["entries"]
    historical_ids = {item["source_entity_id"] for item in historical_claims}
    declarations = {item["id"]: item for item in zig_inventory["declarations"]}
    historical_no_canonical_target = 0
    historical_matching_canonical_target = 0
    historical_conflicting_canonical_target = 0
    historical_classifications: dict[str, int] = {}
    for claim in historical_claims:
        identity = claim["source_entity_id"]
        mapping = mapping_by_id.get(identity)
        classification = mapping["classification"] if mapping else active[identity]["ledger_status"]
        historical_classifications[classification] = historical_classifications.get(classification, 0) + 1
        targets = mapping.get("zig", []) if mapping else []
        if not targets:
            historical_no_canonical_target += 1
            continue
        matches = any(
            (declaration := declarations.get(target["declaration_id"])) is not None
            and declaration["file"] == claim["zig_path"]
            and declaration["kind"] == "function"
            and declaration["name"] == claim["zig_function"]
            for target in targets
        )
        if matches:
            historical_matching_canonical_target += 1
        else:
            historical_conflicting_canonical_target += 1
    atomic_source_ids = {
        identity
        for dossier in atomic_dossiers
        for identity in dossier["scope"]["source_entity_ids"]
    }

    opcode_summary = opcode_coverage["summary"]
    parser_action_summary = parser_action_coverage["summary"]
    public_summary = public_responsibilities["summary"]
    atomic_state_counts = {
        state: sum(dossier["status"] == state for dossier in atomic_dossiers)
        for state in (
            "inventoried", "source-context-reviewed", "scaffolded", "source-translated",
            "internal-trace-equivalent", "subsystem-integrated", "assurance-passed",
        )
    }
    translated_or_later = sum(
        dossier["status"] in {
            "source-translated", "internal-trace-equivalent", "subsystem-integrated",
            "assurance-passed",
        }
        for dossier in atomic_dossiers
    )
    integrated_or_later = sum(
        dossier["status"] in {
            "subsystem-integrated", "assurance-passed",
        }
        for dossier in atomic_dossiers
    )

    by_kind: dict[str, dict[str, int]] = {}
    for entity in active.values():
        status = by_kind.setdefault(entity["kind"], {
            "active": 0,
            "legacy_candidates": 0,
            "reviewed": 0,
        })
        status["active"] += 1
        status["inventoried"] = status.get("inventoried", 0) + (entity["id"] in inventoried_active)
        status["legacy_candidates"] += entity["id"] in legacy_candidates
        status["reviewed"] += entity["id"] in reviewed_active

    report = {
        "schema_version": 3,
        "goal": "complete source-faithful SQLite core port with a Zig-native API and zero C in production artifacts",
        "overall_status": "incomplete-control-revalidation-and-source-port",
        "baseline_checkin": inventory["sqlite_checkin"],
        "source": {
            "inventory_total": inventory["counts"]["total"],
            "active_profile_entities": len(active),
            "active_entities_initially_classified": len(active),
            "active_entities_unmapped": len(unmapped_active),
            "active_entities_inventoried": len(inventoried_active),
            "active_entities_with_legacy_candidates": len(legacy_candidates),
            "active_entities_context_reviewed_or_later": len(reviewed_active),
            "reviewed_coverage_percent": round(100 * len(reviewed_active) / len(active), 2),
            "by_kind": by_kind,
            "mapping_status": "working-classification-with-inventoried-unpromoted-atomic-units",
            "reviewed_coverage_is_completion_metric": False,
            "ast_resolved_reviewed_target_references": reviewed_target_references,
            "ast_resolved_legacy_target_references": resolved_legacy_target_references,
            "unresolved_legacy_target_references": unresolved_target_references,
            "mapping_warning": "Inventoried mappings, AST resolution, and legacy candidates are planning facts only, not semantic review, promotion, or fidelity evidence.",
            "active_source_files": dependencies["counts"]["active_files"],
            "source_dependency_file_units": dependencies["counts"]["source_file_units"],
            "atomic_unit_dossiers_total": len(atomic_dossiers),
            "atomic_unit_dossiers_admission_ready": sum(dossier["admission_ready"] for dossier in atomic_dossiers),
            "atomic_units_source_translated_or_later": translated_or_later,
            "atomic_units_subsystem_integrated_or_later": integrated_or_later,
            "atomic_units_assurance_passed": atomic_state_counts["assurance-passed"],
            "behavioral_blocks_inventoried": behavioral["counts"]["blocks"],
            "behavioral_functions_inventoried": behavioral["counts"]["functions_with_blocks"],
            "behavioral_blocks_assigned_to_atomic_units": behavioral["counts"]["assigned_to_atomic_units"],
            "cross_file_dependency_edges": dependencies["counts"]["cross_file_edges"],
            "zig_declaration_inventory": zig_inventory["counts"]["declarations"],
        },
        "translation_tracking": {
            "active_batch_schema": active_batch["schema_version"],
            "active_batch_status": active_batch["status"],
            "historical_claim_ledger": active_batch["historical_claim_ledger"],
            "checkpoint_ledger": "upstream/port-checkpoints.json",
            "active_batch_entries": len(active_batch["entries"]),
            "active_batch_short_functions": sum(item["class"] == "short" for item in active_batch["entries"]),
            "active_batch_substantive_functions": sum(item["class"] == "substantive" for item in active_batch["entries"]),
            "durable_checkpoints": len(checkpoints["checkpoints"]),
            "historical_mechanical_claims": len(historical_claims),
            "historical_mechanical_short_functions": historical_claim_ledger["short_functions"],
            "historical_mechanical_substantive_functions": historical_claim_ledger["substantive_functions"],
            "historical_claims_without_canonical_target": historical_no_canonical_target,
            "historical_claims_matching_canonical_target": historical_matching_canonical_target,
            "historical_claims_conflicting_with_canonical_target": historical_conflicting_canonical_target,
            "historical_claims_assigned_to_atomic_units": len(historical_ids & atomic_source_ids),
            "historical_claim_classifications": dict(sorted(historical_classifications.items())),
            "completion_credit": 0,
            "reconciled": False,
            "warning": historical_claim_ledger["warning"],
        },
        "engineering_process": {
            "authoritative_process": "docs/ENGINEERING_PROCESS.md",
            "current_gate": "all atomic units were downgraded to inventoried pending structured context; historical mechanical function claims have no completion credit; exact active-batch promotion and durable checkpoint controls are installed",
            "headline_progress_basis": "dependency-closed atomic units at source-translated, trace-equivalent, integrated, or assurance-passed states",
            "non_progress_accounting": [
                "reviewed entity percentage",
                "Zig declaration count",
                "exact layout count",
                "parser hook/action-contract count",
                "bounded runtime opcode-name mapping count",
                "tests run only against the C oracle",
                "historical C ABI/export coverage",
            ],
            "prototype_policy": "bounded frontend, handwritten VDBE, reconstructed B-tree, and reduced pager/WAL are frozen substitutes; retain fixtures but replace production ownership by source unit",
            "worker_containment_audit_complete": True,
            "purposeful_python_tool_scripts": len(list((ROOT / "tools").glob("*.py"))),
            "shell_tool_entrypoints": len(list((ROOT / "tools").glob("*.sh"))),
            "bounded_build_commands_and_artifacts": True,
            "containment_mutation_tested": True,
            "behavioral_block_inventory_complete": True,
            "atomic_unit_dossiers_complete": False,
            "atomic_unit_state_counts": atomic_state_counts,
        },
        "public_api": {
            "target": "complete Zig-native API mapped to active SQLite public behavioral responsibilities",
            "semantic_status": "not-complete",
            "zig_native_api_status": "declaration-level responsibilities accounted; coherent Zig surface and complete behavior remain open",
            "responsibility_inventory": {
                "active_required_behavior_entries": public_summary["active_required_behavior_entries"],
                "active_behavior_entries_accounted": public_summary["active_behavior_entries_accounted"],
                "active_entries_complete": public_summary["active_entries_complete"],
                "planned_zig_api_domains": public_summary["planned_zig_api_domains"],
                "active_entries_with_transitional_c_shaped_zig_candidates": public_summary["active_entries_with_transitional_c_shaped_zig_candidates"],
                "active_c_variadic_transport_entries": public_summary["active_c_variadic_transport_entries"],
                "active_variadic_transport_entries_with_non_variadic_targets": public_summary["active_variadic_transport_entries_with_non_variadic_targets"],
                "warning": public_responsibilities["warning"],
            },
            "transitional_c_surface": {
                "historical_header_declarations": api["counts"]["total"],
                "historical_profile_symbols": api["counts"]["exported_total"],
                "production_zig_defined_exports": api["counts"]["exported_total"] - len(native_c.get("test_only_c_entrypoints", [])),
                "test_only_c_transport_symbols": len(native_c.get("test_only_c_entrypoints", [])),
                "fidelity_evidenced_behaviors": api["counts"]["fidelity_evidenced"],
                "provisional_bounded_behaviors": api["counts"]["provisional_bounded"],
                "deferred_profile": api["counts"]["deferred_profile"],
                "completion_metric": False,
            },
        },
        "implementation": {
            "zig_source_lines": sum(lines(path) for path in (ROOT / "src").rglob("*.zig")),
            "production_c_source_lines": sum(item["lines"] for item in native_c["native_c_sources"]),
            "production_c_sources": len(native_c["native_c_sources"]),
            "test_only_c_source_lines": sum(item["lines"] for item in native_c.get("test_only_c_sources", [])),
            "production_c_global_symbols": sum(len(group) for group in native_c["c_global_symbols"].values()),
            "production_c_release_violations": sum(len(group) for group in native_c["c_global_symbols"].values()),
            "production_c_boundary_status": native_c["status"],
            "bounded_vdbe_runtime_opcodes": opcode_summary["bounded_runtime_opcodes"],
            "canonical_vdbe_execution_cases_with_bounded_runtime_mapping": opcode_summary["canonical_execution_cases_with_bounded_runtime_mapping"],
            "canonical_vdbe_execution_cases_without_bounded_runtime_mapping": opcode_summary["canonical_execution_cases_without_bounded_runtime_mapping"],
            "source_translated_vdbe_execution_cases": opcode_summary["source_translated_execution_cases"],
            "subsystem_integrated_vdbe_execution_cases": opcode_summary["subsystem_integrated_execution_cases"],
            "transitional_vdbe_runtime_only_opcodes": opcode_summary["transitional_runtime_only_opcodes"],
            "generated_canonical_opcode_identities": opcodes["opcode_count"],
            "upstream_vdbe_opcode_cases": opcode_summary["canonical_execution_cases"],
            "vdbe_opcode_coverage_warning": opcode_coverage["warning"],
            "native_parser_tables": parser_tables["counts"]["state_count"],
            "native_parser_rules": parser_tables["counts"]["rule_count"],
            "native_parser_destructor_symbols": parser_tables["counts"]["symbols_with_destructors"],
            "native_parser_typed_action_contracts": parser_action_summary["typed_local_flow_contract_rules"],
            "native_parser_actions_without_typed_contract": parser_action_summary["semantic_action_rules_without_typed_contract"],
            "native_parser_source_translated_actions": parser_action_summary["source_translated_action_rules"],
            "native_parser_subsystem_integrated_actions": parser_action_summary["subsystem_integrated_action_rules"],
            "native_parser": "canonical Lemon tables, recognition state machine, exact minor-value union, 50 generated destructor routes, and typed owner contracts/local flow for all 348 generated semantic actions exist as scaffolding; concrete SQLite owners, exact side effects/error/OOM behavior, and parser-to-resolver/compiler execution remain disconnected, and SQL execution still uses the handwritten bounded frontend",
            "source_faithful_internal_vdbe_layouts": len(internal_vdbe_layout["types"]),
            "source_faithful_internal_parse_layouts": len(internal_parse_layout["types"]),
            "source_faithful_internal_layouts_total": len(internal_vdbe_layout["types"]) + len(internal_parse_layout["types"]),
            "mutex_noop_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/mutex_noop.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "benign_fault_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/fault.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "vlist_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite packed VList")
                and item["classification"] == "targeted-differential-passed"
            ),
            "rowset_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/rowset.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "hex_blob_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite connection-allocated hexadecimal")
                and item["classification"] == "targeted-differential-passed"
            ),
            "dequote_entities_differentially_checked": sum(
                1 for item in active_mappings
                if (item["id"].startswith("src/util.c::function::sqlite3Dequote")
                    or item["id"].startswith("src/util.c::function::sqlite3TokenInit"))
                and item["classification"] == "targeted-differential-passed"
            ),
            "checked_math_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite NaN/infinity classifier")
                and item["classification"] == "targeted-differential-passed"
            ),
            "log_est_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite LogEst")
                and item["classification"] == "targeted-differential-passed"
            ),
            "complete_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/complete.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "bitvec_active_entities_reviewed": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/bitvec.c::")
                and item["classification"] in reviewed_states
            ),
            "bitvec_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/bitvec.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "random_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/random.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "utf_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/utf.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "default_mem1_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("active default mem1")
                and item["classification"] == "targeted-differential-passed"
            ),
            "printf_active_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item["id"].startswith("src/printf.c::")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_metadata_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("relation") in {"one-to-one-formatter-metadata", "folded-c-tag-and-typedef"}
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_accumulator_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite StrAccum")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_rcstr_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite RCStr")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_object_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite dynamic sqlite3_str object")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_argument_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite SQL-formatter argument")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_result_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite StrAccum-to-SQL-result")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_temporary_buffer_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite formatter temporary-buffer")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_render_entrypoints_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite complete format parser")
                and item["classification"] == "targeted-differential-passed"
            ),
            "formatter_caller_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite allocated, fixed-buffer")
                and item["classification"] == "targeted-differential-passed"
            ),
            "error_offset_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite expression-origin flag")
                and item["classification"] == "targeted-differential-passed"
            ),
            "floating_decode_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite binary/decimal floating")
                and item["classification"] == "targeted-differential-passed"
            ),
            "token_entities_differentially_checked": sum(
                1 for item in active_mappings
                if item.get("obligations", {}).get("source_role", "").startswith("SQLite lexer Token")
                and item["classification"] == "targeted-differential-passed"
            ),
            "btree_mutation": "whole-tree reconstruction; not a fidelity port of upstream balancing",
            "sql_value_model": "exact Mem is used by VM registers, bindings, statement outputs, virtual-table outputs, and UDF paths; complete VDBE lifecycle integration remains open",
        },
        "evidence": {
            "phase_manifests": "valuable bounded regression evidence only; not whole-subsystem completion",
            "upstream_tests_against_oracle": True,
            "upstream_tests_against_native_zig": False,
            "release_compatibility_claim": False,
        },
        "release_blockers": [
            "record structured source context and durable evidence before promoting any inventoried atomic unit, then reconcile or retire all historical mechanical function claims",
            "assign remaining source and behavioral responsibilities to dependency-closed atomic units, resolve legacy candidates, and context-review every active responsibility",
            "port VDBE builder/labels/fixups, connect concrete Lemon action owners, and complete the SQL resolver, compiler, planner, and generated opcode system",
            "port SQLite Mem/VDBE semantics and all active opcodes",
            "replace bounded B-tree reconstruction, pager, WAL, and VFS subsets with source-faithful implementations",
            "define and complete the Zig-native public API responsibility map and port the complete SQLite formatter",
            "run adapted upstream, SQL, Zig-API, fault, fuzz, concurrency, durability, and performance suites against the native engine",
        ],
    }

    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.write:
        OUTPUT.write_text(rendered)
        print(f"port-audit: wrote {OUTPUT.relative_to(ROOT)}")
        return
    if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
        raise SystemExit("port-audit: upstream/port-status.json is stale; run tools/port_audit.py --write")
    print(
        "port-audit: incomplete port; "
        f"{len(active)} active entities classified, "
        f"{len(reviewed_active)} reviewed"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
