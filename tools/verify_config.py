#!/usr/bin/env python3
"""Fail-closed verification of pinned inputs, generated artifacts, and honest port status."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import shutil
import bounded_subprocess as subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def baseline() -> dict[str, str]:
    result: dict[str, str] = {}
    for line in (ROOT / "upstream/SQLITE_BASELINE").read_text().splitlines():
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            result[key] = value
    return result


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"verify-config: {message}")


def main() -> None:
    pinned = baseline()
    profile_path = ROOT / "upstream/SQLITE_BUILD_PROFILE.json"
    profile = json.loads(profile_path.read_text())
    api_manifest = json.loads((ROOT / "upstream/api-manifest.json").read_text())
    json.loads((ROOT / "upstream/source-scope.json").read_text())
    source_inventory = json.loads((ROOT / "upstream/source-inventory.json").read_text())
    source_dependencies = json.loads((ROOT / "upstream/source-dependencies.json").read_text())
    behavioral_inventory = json.loads((ROOT / "upstream/behavioral-inventory.json").read_text())
    active_port_batch = json.loads((ROOT / "upstream/active-port-batch.json").read_text())
    historical_port_claims = json.loads((ROOT / active_port_batch["historical_claim_ledger"]).read_text())
    port_checkpoints = json.loads((ROOT / "upstream/port-checkpoints.json").read_text())
    symbol_map = json.loads((ROOT / "upstream/symbol-map.json").read_text())
    port_status = json.loads((ROOT / "upstream/port-status.json").read_text())
    native_c_boundary = json.loads((ROOT / "upstream/native-c-boundary.json").read_text())
    phase1_manifest = json.loads((ROOT / "upstream/phase1-manifest.json").read_text())
    phase2_manifest = json.loads((ROOT / "upstream/phase2-manifest.json").read_text())
    phase3_manifest = json.loads((ROOT / "upstream/phase3-manifest.json").read_text())
    phase4_manifest = json.loads((ROOT / "upstream/phase4-manifest.json").read_text())
    phase5_manifest = json.loads((ROOT / "upstream/phase5-manifest.json").read_text())
    phase6_manifest = json.loads((ROOT / "upstream/phase6-manifest.json").read_text())
    phase7_manifest = json.loads((ROOT / "upstream/phase7-manifest.json").read_text())
    phase8_manifest = json.loads((ROOT / "upstream/phase8-manifest.json").read_text())
    phase9_manifest = json.loads((ROOT / "upstream/phase9-manifest.json").read_text())
    phase10_manifest = json.loads((ROOT / "upstream/phase10-manifest.json").read_text())
    phase11_manifest = json.loads((ROOT / "upstream/phase11-manifest.json").read_text())
    phase12_manifest = json.loads((ROOT / "upstream/phase12-manifest.json").read_text())
    phase13_expression_manifest = json.loads((ROOT / "upstream/phase13-expression-manifest.json").read_text())
    phase13_schema_manifest = json.loads((ROOT / "upstream/phase13-schema-manifest.json").read_text())
    phase13_table_scan_manifest = json.loads((ROOT / "upstream/phase13-table-scan-manifest.json").read_text())
    phase13_insert_manifest = json.loads((ROOT / "upstream/phase13-insert-manifest.json").read_text())
    phase13_update_delete_manifest = json.loads((ROOT / "upstream/phase13-update-delete-manifest.json").read_text())
    phase13_index_join_manifest = json.loads((ROOT / "upstream/phase13-index-join-manifest.json").read_text())
    phase13_advanced_manifest = json.loads((ROOT / "upstream/phase13-advanced-manifest.json").read_text())
    phase13_manifest = json.loads((ROOT / "upstream/phase13-manifest.json").read_text())
    phase14_rowid_planner_manifest = json.loads((ROOT / "upstream/phase14-rowid-planner-manifest.json").read_text())
    phase14_index_order_manifest = json.loads((ROOT / "upstream/phase14-index-order-manifest.json").read_text())
    phase14_manifest = json.loads((ROOT / "upstream/phase14-manifest.json").read_text())
    phase15_manifest = json.loads((ROOT / "upstream/phase15-manifest.json").read_text())
    phase17_manifest = json.loads((ROOT / "upstream/phase17-manifest.json").read_text())
    historical_phase_manifests = (
        phase1_manifest, phase2_manifest, phase3_manifest, phase4_manifest,
        phase5_manifest, phase6_manifest, phase7_manifest, phase8_manifest,
        phase9_manifest, phase10_manifest, phase11_manifest, phase12_manifest,
        phase13_expression_manifest, phase13_schema_manifest,
        phase13_table_scan_manifest, phase13_insert_manifest,
        phase13_update_delete_manifest, phase13_index_join_manifest,
        phase13_advanced_manifest, phase13_manifest,
        phase14_rowid_planner_manifest, phase14_index_order_manifest,
        phase14_manifest, phase15_manifest, phase17_manifest,
    )
    pager_fixture_manifest = json.loads(
        (ROOT / "tests/fixtures/pager/manifest.json").read_text()
    )
    btree_fixture_manifest = json.loads(
        (ROOT / "tests/fixtures/btree/manifest.json").read_text()
    )
    rollback_fixture_manifest = json.loads(
        (ROOT / "tests/fixtures/rollback/manifest.json").read_text()
    )
    btree_mutation_fixture_manifest = json.loads(
        (ROOT / "tests/fixtures/btree-mutation/manifest.json").read_text()
    )
    wal_fixture_manifest = json.loads((ROOT / "tests/fixtures/wal/manifest.json").read_text())
    vdbe_fixture_manifest = json.loads((ROOT / "tests/fixtures/vdbe/manifest.json").read_text())
    statement_fixture_manifest = json.loads((ROOT / "tests/fixtures/statement/manifest.json").read_text())
    sql_expression_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-expression/manifest.json").read_text())
    sql_schema_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-schema/manifest.json").read_text())
    sql_table_scan_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-table-scan/manifest.json").read_text())
    sql_insert_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-insert/manifest.json").read_text())
    sql_update_delete_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-update-delete/manifest.json").read_text())
    sql_index_join_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-index-join/manifest.json").read_text())
    sql_advanced_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-advanced/manifest.json").read_text())
    sql_planner_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-planner/manifest.json").read_text())
    sql_index_planner_fixture_manifest = json.loads((ROOT / "tests/fixtures/sql-index-planner/manifest.json").read_text())
    unix_vfs_fixture_manifest = json.loads((ROOT / "tests/fixtures/unix-vfs/manifest.json").read_text())
    phase17_fixture_manifest = json.loads((ROOT / "tests/fixtures/phase17/manifest.json").read_text())
    parser_manifest = json.loads((ROOT / "generated/parser/probe-manifest.json").read_text())
    sqlite_parser_manifest = json.loads(
        (ROOT / "generated/parser/sqlite-parser-manifest.json").read_text()
    )
    parser_tables_manifest = json.loads((ROOT / "generated/parser/zig-tables-manifest.json").read_text())
    internal_vdbe_layout = json.loads((ROOT / "generated/internal/vdbe-layout.json").read_text())
    internal_parse_layout = json.loads((ROOT / "generated/internal/parse-layout.json").read_text())
    opcode_manifest = json.loads((ROOT / "generated/opcodes/manifest.json").read_text())

    require((ROOT / "upstream/sqlite/VERSION").read_text().strip() == pinned["version"],
            "vendored SQLite VERSION differs from baseline")
    require((ROOT / "upstream/sqlite/manifest.uuid").read_text().strip() == pinned["fossil_checkin"],
            "vendored Fossil check-in differs from baseline")
    require(profile["baseline_checkin"] == pinned["fossil_checkin"],
            "build profile uses another baseline")
    require(sha256(profile_path) == pinned["build_profile_sha256"],
            "build profile checksum differs from baseline")
    for role in ("production_compiler", "diagnostic_compiler"):
        compiler = profile["oracle"][role]
        compiler_path = pathlib.Path(compiler["path"])
        require(compiler_path.is_file(), f"missing pinned {role}: {compiler_path}")
        require(sha256(compiler_path.resolve()) == compiler["driver_sha256"],
                f"pinned {role} checksum mismatch")
    for name, tool in profile["inventory_tools"].items():
        tool_path = pathlib.Path(tool["path"])
        require(tool_path.is_file(), f"missing pinned inventory tool {name}: {tool_path}")
        require(sha256(tool_path.resolve()) == tool["sha256"],
                f"pinned inventory tool checksum mismatch: {name}")

    expected_generated = {
        "reference/c_oracle/sqlite3.c": profile["oracle"]["generated_amalgamation_sha256"],
        "reference/c_oracle/sqlite3-lines.c": profile["oracle"]["generated_linemacro_amalgamation_sha256"],
        "include/sqlite3.h": profile["oracle"]["generated_sqlite3_h_sha256"],
        "include/sqlite3ext.h": profile["oracle"]["generated_sqlite3ext_h_sha256"],
    }
    expected_generated.update(parser_manifest["outputs"])
    expected_generated.update(sqlite_parser_manifest["outputs"])
    require(sqlite_parser_manifest["sqlite_checkin"] == pinned["fossil_checkin"],
            "SQLite parser manifest uses another baseline")
    require(sqlite_parser_manifest["grammar"]["source_sha256"] ==
            sha256(ROOT / sqlite_parser_manifest["grammar"]["source"]),
            "SQLite parser manifest uses another grammar")
    require(sqlite_parser_manifest["counts"] == {
        "states": 600, "rules": 412, "symbols": 322, "terminals": 187,
        "semantic_action_rules": 348, "default_action_rules": 64,
    }, "unexpected SQLite parser inventory counts")
    require(parser_tables_manifest["sqlite_checkin"] == pinned["fossil_checkin"] and
            parser_tables_manifest["counts"]["state_count"] == 600 and
            parser_tables_manifest["counts"]["rule_count"] == 412 and
            parser_tables_manifest["counts"]["terminal_count"] == 187 and
            parser_tables_manifest["counts"]["actions_length"] == 2379 and
            parser_tables_manifest["counts"]["lookaheads_length"] == 2566 and
            sha256(ROOT / parser_tables_manifest["output"]) == parser_tables_manifest["output_sha256"],
            "native Lemon parser table generation mismatch")
    require(internal_vdbe_layout["sqlite_checkin"] == pinned["fossil_checkin"] and
            set(internal_vdbe_layout["types"]) == {
                "Vdbe", "VdbeCursor", "sqlite3_pcache_methods2", "struct Sqlite3Config",
                "struct sqlite3InitInfo", "Sqlite3Trace",
                "Sqlite3Interrupt", "sqlite3", "BusyHandler", "BtLock", "BtreePayload", "Btree", "Db", "Schema",
                "Column", "Table", "Index", "FKey", "struct _ht", "HashElem", "Hash",
                "LookasideSlot", "Lookaside", "CollSeq",
                "FuncDestructor", "FuncDef", "FuncDefHash", "Savepoint", "Module",
                "DbClientData", "KeyInfo", "UnpackedRecord", "PreUpdate",
                "union MemValue", "Mem", "VdbeTxtBlbCache", "VdbeFrame",
                "AuxData", "sqlite3_context", "ScanStatus", "DblquoteStr",
                "ValueList", "SubrtnSig", "union p4union", "VdbeOp",
                "SubProgram", "VdbeOpList",
            } and
            sha256(ROOT / internal_vdbe_layout["output"]) == internal_vdbe_layout["output_sha256"],
            "internal VDBE layout generation mismatch")
    require(internal_parse_layout["sqlite_checkin"] == pinned["fossil_checkin"] and
            set(internal_parse_layout["types"]) == {
                "Token", "Expr", "Window", "Trigger", "TriggerStep", "Cte", "With", "Upsert", "Select",
                "struct IdList_item", "IdList",
                "struct ExprList_item", "ExprList", "Subquery",
                "OnOrUsing", "struct TrigEvent", "struct FrameBound", "YYMINORTYPE",
                "SrcItem", "SrcList", "ParseCleanup", "Parse",
            } and
            sha256(ROOT / internal_parse_layout["output"]) == internal_parse_layout["output_sha256"],
            "internal Parse layout generation mismatch")
    require(opcode_manifest["sqlite_checkin"] == pinned["fossil_checkin"] and
            opcode_manifest["opcode_count"] == 192 and
            opcode_manifest["execution_case_count"] == 190 and
            opcode_manifest["property_count"] == 192 and
            opcode_manifest["max_jump_opcode"] == 66 and
            sha256(ROOT / opcode_manifest["output"]) == opcode_manifest["output_sha256"],
            "canonical opcode generation mismatch")
    require(api_manifest["header_sha256"] == expected_generated["include/sqlite3.h"],
            "API manifest was generated from another header")
    require(api_manifest["counts"]["total"] == 368,
            "unexpected public API declaration count")
    require(source_inventory["sqlite_checkin"] == pinned["fossil_checkin"],
            "source inventory uses another baseline")
    require(source_inventory["counts"]["total"] == 9074,
            "unexpected canonical source-entity inventory count")
    require(source_inventory["counts"]["by_kind"]["function"] == 3251,
            "unexpected canonical function inventory count")
    require(source_inventory["counts"]["by_activity"]["active-profile"] == 6751,
            "unexpected exact active-profile entity count")
    require(source_inventory["counts"]["by_activity"]["active-profile-location-adjusted"] == 1,
            "unexpected location-adjusted active-profile entity count")
    require(source_inventory["counts"]["by_activity"].get("ambiguous-active-location", 0) == 0,
            "active-profile source identities remain ambiguous")
    inventory_by_id = {item["id"]: item for item in source_inventory["entities"]}
    require(symbol_map["schema_version"] == 3 and
            symbol_map["status"] == "working-classification" and
            not symbol_map["completion_claim"],
            "source ledger must remain an honest working classification")
    require(active_port_batch["schema_version"] == 2 and
            active_port_batch["status"] in {"idle", "active"} and
            not active_port_batch["completion_claim"],
            "active translation tracking boundary mismatch")
    require(historical_port_claims["schema_version"] == 3 and
            historical_port_claims["sqlite_checkin"] == pinned["fossil_checkin"] and
            historical_port_claims["completion_credit"] is False and
            historical_port_claims["reconciliation"]["status"] == "formally-retired" and
            historical_port_claims["reconciliation"]["completion_credit"] is False,
            "historical mechanical claim boundary mismatch")
    require(port_checkpoints["schema_version"] == 1 and
            port_checkpoints["sqlite_checkin"] == pinned["fossil_checkin"] and
            not port_checkpoints["completion_claim"],
            "translation checkpoint ledger mismatch")
    require(port_status["schema_version"] == 3 and
            port_status["overall_status"] == "incomplete-control-revalidation-and-source-port" and
            port_status["baseline_checkin"] == pinned["fossil_checkin"] and
            port_status["source"]["active_entities_initially_classified"] == 6752 and
            port_status["translation_tracking"]["completion_credit"] == 0,
            "whole-port status summary mismatch")
    require(source_dependencies["sqlite_checkin"] == pinned["fossil_checkin"] and
            source_dependencies["counts"]["active_files"] == 85 and
            source_dependencies["counts"]["source_file_units"] == 85,
            "source dependency graph status mismatch")
    require(behavioral_inventory["schema_version"] == 1 and
            behavioral_inventory["sqlite_checkin"] == pinned["fossil_checkin"] and
            behavioral_inventory["counts"]["blocks"] == 25930 and
            0 <= behavioral_inventory["counts"]["assigned_to_atomic_units"] <= behavioral_inventory["counts"]["blocks"],
            "behavioral inventory status mismatch")
    require(not list((ROOT / "src").rglob("*.c")),
            "production src/ tree must not contain C source")
    memory_source = (ROOT / "src/core/memory.zig").read_text()
    require("if (!process_manager.started) _ = process_manager.start()" not in memory_source and
            "shutdownProcessManager" not in memory_source,
            "process allocator retains a memory-only lifecycle bypass")
    production_ensure_users = [
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "src/core").rglob("*.zig")
        if path != ROOT / "src/core/memory.zig" and "ensureProcessManager()" in path.read_text()
    ]
    require(not production_ensure_users,
            f"production allocator callers bypass global lifecycle: {production_ensure_users}")
    require(native_c_boundary["schema_version"] == 3 and
            native_c_boundary["status"] == "production-zero-c-verified" and
            not native_c_boundary["completion_claim"] and
            len(native_c_boundary["native_c_sources"]) == 0 and
            len(native_c_boundary["test_only_c_sources"]) == 1 and
            native_c_boundary["required_end_state"]["production_c_objects"] == 0,
            "native C boundary status mismatch")
    for source in native_c_boundary["native_c_sources"] + native_c_boundary["test_only_c_sources"]:
        path = ROOT / source["path"]
        require(path.is_file() and sha256(path) == source["sha256"] and
                len(path.read_text().splitlines()) == source["lines"],
                f"inventoried C boundary source mismatch: {source['path']}")
    # Historical phase manifests count legacy candidates, not reviewed mappings.
    for mapping in symbol_map["entities"]:
        mapping["phase"] = mapping.get("legacy_phase", "current-reviewed")
        for target in mapping["zig"]:
            target["file"] = target["declaration_id"].split("::", 1)[0]
    require(all(
        manifest.get("status") == "bounded-regression-evidence" and
        manifest.get("evidence_classification") == "bounded-regression-only" and
        manifest.get("project_completion_claim") is False
        for manifest in historical_phase_manifests
    ), "historical phase manifests must be bounded evidence only")
    require(phase1_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 1 manifest uses another baseline")
    require(phase1_manifest["status"] == "bounded-regression-evidence",
            "Phase 1 manifest is not complete")
    phase1_mapping_count = sum(
        1 for mapping in symbol_map["entities"]
        if mapping["phase"] == "fidelity"
        and all(not item["file"].startswith("src/abi/") for item in mapping["zig"])
    )
    require(phase1_manifest["mapped_entity_count"] == phase1_mapping_count == 159,
            "unexpected Phase 1 mapped entity count")
    require(set(phase1_manifest["slices"]) == {
        "byteorder", "varint", "bitvec", "hash", "utf", "string",
        "numeric", "random", "formatting_subset", "limits_and_configuration",
    }, "Phase 1 slice set mismatch")
    require(all(value["status"] == "pass" for value in phase1_manifest["slices"].values()),
            "a Phase 1 utility slice is not passing")
    require(all(value == "pass" for value in phase1_manifest["exit_gates"].values()),
            "a Phase 1 exit gate is not passing")
    require(phase2_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 2 manifest uses another baseline")
    require(phase2_manifest["status"] == "bounded-regression-evidence",
            "Phase 2 manifest is not complete")
    phase2_mapping_count = sum(
        1 for mapping in symbol_map["entities"] if mapping["phase"] == "infrastructure"
    )
    require(phase2_manifest["mapped_entity_count"] == phase2_mapping_count == 97,
            "unexpected Phase 2 mapped entity count")
    require(set(phase2_manifest["slices"]) == {
        "allocator_methods", "memory_statistics_and_limits", "lookaside",
        "scratch_and_temp", "mutex", "global_initialization",
    }, "Phase 2 slice set mismatch")
    require(all(value["status"] == "pass" for value in phase2_manifest["slices"].values()),
            "a Phase 2 infrastructure slice is not passing")
    require(all(value == "pass" for value in phase2_manifest["exit_gates"].values()),
            "a Phase 2 exit gate is not passing")
    require(phase3_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 3 manifest uses another baseline")
    require(phase3_manifest["status"] == "bounded-regression-evidence",
            "Phase 3 manifest is not complete")
    phase3_mapping_count = sum(
        1 for mapping in symbol_map["entities"] if mapping["phase"] == "parser-bridge"
    )
    require(phase3_manifest["mapped_entity_count"] == phase3_mapping_count == 41,
            "unexpected Phase 3 mapped entity count")
    require(all(value["status"] == "pass" for value in phase3_manifest["slices"].values()),
            "a Phase 3 slice is not passing")
    require(all(value == "pass" for value in phase3_manifest["exit_gates"].values()),
            "a Phase 3 exit gate is not passing")
    for relative, expected in phase3_manifest["slices"]["token_definitions"]["outputs"].items():
        require(sha256(ROOT / relative) == expected, f"token metadata hash mismatch: {relative}")
    require(phase4_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 4 manifest uses another baseline")
    require(phase4_manifest["status"] == "bounded-regression-evidence",
            "Phase 4 manifest is not complete")
    phase4_mapping_count = sum(
        1 for mapping in symbol_map["entities"] if mapping["phase"] == "vfs"
    )
    require(phase4_manifest["mapped_entity_count"] == phase4_mapping_count == 50,
            "unexpected Phase 4 mapped entity count")
    require(all(value["status"] == "pass" for value in phase4_manifest["slices"].values()),
            "a Phase 4 slice is not passing")
    require(all(value == "pass" for value in phase4_manifest["exit_gates"].values()),
            "a Phase 4 exit gate is not passing")
    require(phase5_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 5 manifest uses another baseline")
    require(phase5_manifest["status"] == "bounded-regression-evidence",
            "Phase 5 manifest is not complete")
    phase5_mapping_count = sum(
        1 for mapping in symbol_map["entities"] if mapping["phase"] == "page-cache"
    )
    require(phase5_manifest["mapped_entity_count"] == phase5_mapping_count == 171,
            "unexpected Phase 5 mapped entity count")
    require(all(value["status"] == "pass" for value in phase5_manifest["slices"].values()),
            "a Phase 5 slice is not passing")
    require(all(value == "pass" for value in phase5_manifest["exit_gates"].values()),
            "a Phase 5 exit gate is not passing")
    pcache_corpus = ROOT / phase5_manifest["state_sequence_corpus"]["path"]
    require(sha256(pcache_corpus) == phase5_manifest["state_sequence_corpus"]["sha256"],
            "Phase 5 state-sequence corpus hash mismatch")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-pcache-sequences-") as temp:
        regenerated_pcache = pathlib.Path(temp) / "state-sequences.txt"
        subprocess.run([
            sys.executable,
            str(ROOT / "tools/generate_pcache_sequences.py"),
            str(regenerated_pcache),
        ], check=True, stdout=subprocess.DEVNULL)
        require(regenerated_pcache.read_bytes() == pcache_corpus.read_bytes(),
                "Phase 5 state-sequence regeneration differs")
    require(phase6_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 6 manifest uses another baseline")
    require(phase6_manifest["status"] == "bounded-regression-evidence",
            "Phase 6 manifest is not complete")
    phase6_mapping_count = sum(
        1 for mapping in symbol_map["entities"] if mapping["phase"] == "read-only-pager"
    )
    require(phase6_manifest["mapped_entity_count"] == phase6_mapping_count == 50,
            "unexpected Phase 6 mapped entity count")
    require(set(phase6_manifest["slices"]) == {
        "open_and_header", "shared_lock_and_read_transaction",
        "page_acquisition_and_cache_fill", "read_only_boundary",
        "fault_and_ownership",
    }, "Phase 6 slice set mismatch")
    require(all(value["status"] == "pass" for value in phase6_manifest["slices"].values()),
            "a Phase 6 slice is not passing")
    require(all(value == "pass" for value in phase6_manifest["exit_gates"].values()),
            "a Phase 6 exit gate is not passing")
    require(len(pager_fixture_manifest["fixtures"]) == 11,
            "unexpected Phase 6 pager fixture count")
    for fixture in pager_fixture_manifest["fixtures"]:
        relative = pathlib.Path("tests/fixtures/pager") / fixture["name"]
        path = ROOT / relative
        require(path.is_file(), f"missing pager fixture: {fixture['name']}")
        require(path.stat().st_size == fixture["size"],
                f"pager fixture size mismatch: {fixture['name']}")
        require(sha256(path) == fixture["sha256"],
                f"pager fixture hash mismatch: {fixture['name']}")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-pager-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([
            sys.executable,
            str(ROOT / "tools/generate_pager_fixtures.py"),
            str(regenerated),
        ], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/pager"
        require(
            sorted(path.name for path in regenerated.iterdir()) ==
            sorted(path.name for path in committed.iterdir()),
            "pager fixture generator output set differs",
        )
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"pager fixture regeneration differs: {path.name}")
    require(phase7_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 7 manifest uses another baseline")
    require(phase7_manifest["status"] == "bounded-regression-evidence",
            "Phase 7 manifest is not complete")
    phase7_mapping_count = sum(
        1 for mapping in symbol_map["entities"]
        if mapping["phase"] == "read-only-btree-records"
    )
    require(phase7_manifest["mapped_entity_count"] == phase7_mapping_count == 55,
            "unexpected Phase 7 mapped entity count")
    require(len(btree_fixture_manifest["fixtures"]) == 8,
            "unexpected Phase 7 B-tree fixture count")
    require(all(value["status"] == "pass" for value in phase7_manifest["slices"].values()),
            "a Phase 7 slice is not passing")
    require(all(value == "pass" for value in phase7_manifest["exit_gates"].values()),
            "a Phase 7 exit gate is not passing")
    for fixture in btree_fixture_manifest["fixtures"]:
        path = ROOT / "tests/fixtures/btree" / fixture["name"]
        require(path.is_file(), f"missing B-tree fixture: {fixture['name']}")
        require(path.stat().st_size == fixture["size"],
                f"B-tree fixture size mismatch: {fixture['name']}")
        require(sha256(path) == fixture["sha256"],
                f"B-tree fixture hash mismatch: {fixture['name']}")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-btree-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([
            sys.executable,
            str(ROOT / "tools/generate_btree_fixtures.py"),
            str(regenerated),
        ], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/btree"
        require(
            sorted(path.name for path in regenerated.iterdir()) ==
            sorted(path.name for path in committed.iterdir()),
            "B-tree fixture generator output set differs",
        )
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"B-tree fixture regeneration differs: {path.name}")
    require(phase8_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 8 manifest uses another baseline")
    require(phase8_manifest["status"] == "bounded-regression-evidence",
            "Phase 8 manifest is not complete")
    phase8_mapping_count = sum(
        1 for mapping in symbol_map["entities"]
        if mapping["phase"] == "rollback-journal-writes"
    )
    require(phase8_manifest["mapped_entity_count"] == phase8_mapping_count == 40,
            "unexpected Phase 8 mapped entity count")
    require(all(value["status"] == "pass" for value in phase8_manifest["slices"].values()),
            "a Phase 8 slice is not passing")
    require(all(value == "pass" for value in phase8_manifest["exit_gates"].values()),
            "a Phase 8 exit gate is not passing")
    require(len(rollback_fixture_manifest["fixtures"]) == 1,
            "unexpected Phase 8 rollback fixture count")
    fixture = rollback_fixture_manifest["fixtures"][0]
    rollback_fixture = ROOT / "tests/fixtures/rollback" / fixture["name"]
    require(rollback_fixture.stat().st_size == fixture["size"],
            "rollback fixture size mismatch")
    require(sha256(rollback_fixture) == fixture["sha256"],
            "rollback fixture hash mismatch")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-rollback-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([
            sys.executable,
            str(ROOT / "tools/generate_rollback_fixtures.py"),
            str(regenerated),
        ], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/rollback"
        require(
            sorted(path.name for path in regenerated.iterdir()) ==
            sorted(path.name for path in committed.iterdir()),
            "rollback fixture generator output set differs",
        )
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"rollback fixture regeneration differs: {path.name}")
    require(phase9_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 9 manifest uses another baseline")
    require(phase9_manifest["status"] == "bounded-regression-evidence",
            "Phase 9 manifest is not complete")
    phase9_mapping_count = sum(
        1 for mapping in symbol_map["entities"] if mapping["phase"] == "btree-mutation"
    )
    require(phase9_manifest["mapped_entity_count"] == phase9_mapping_count == 37,
            "unexpected Phase 9 mapped entity count")
    require(all(value["status"] == "pass" for value in phase9_manifest["slices"].values()),
            "a Phase 9 slice is not passing")
    require(all(value == "pass" for value in phase9_manifest["exit_gates"].values()),
            "a Phase 9 exit gate is not passing")
    require(len(btree_mutation_fixture_manifest["fixtures"]) == 3,
            "unexpected Phase 9 table fixture count")
    require("roundtrip_fixture" in btree_mutation_fixture_manifest,
            "missing Phase 9 index/WITHOUT ROWID fixture")
    for fixture in btree_mutation_fixture_manifest["fixtures"] + [btree_mutation_fixture_manifest["roundtrip_fixture"]]:
        path = ROOT / "tests/fixtures/btree-mutation" / fixture["name"]
        require(path.stat().st_size == fixture["size"],
                f"mutation fixture size mismatch: {fixture['name']}")
        require(sha256(path) == fixture["sha256"],
                f"mutation fixture hash mismatch: {fixture['name']}")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-btree-mutation-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_btree_mutation_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/btree-mutation"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "mutation fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"mutation fixture regeneration differs: {path.name}")
    require(phase10_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 10 manifest uses another baseline")
    require(phase10_manifest["status"] == "bounded-regression-evidence",
            "Phase 10 manifest is not complete")
    phase10_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "wal")
    require(phase10_manifest["mapped_entity_count"] == phase10_mapping_count == 35,
            "unexpected Phase 10 mapped entity count")
    require(all(value["status"].startswith("pass") for value in phase10_manifest["slices"].values()),
            "a Phase 10 slice is not passing")
    require(all(value == "pass" for value in phase10_manifest["exit_gates"].values()),
            "a Phase 10 exit gate is not passing")
    require(len(wal_fixture_manifest["fixtures"]) == 1, "unexpected WAL fixture count")
    wal_fixture = wal_fixture_manifest["fixtures"][0]
    wal_path = ROOT / "tests/fixtures/wal" / wal_fixture["name"]
    require(wal_path.stat().st_size == wal_fixture["size"] and sha256(wal_path) == wal_fixture["sha256"],
            "WAL fixture mismatch")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-wal-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_wal_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/wal"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "WAL fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"WAL fixture regeneration differs: {path.name}")
    require(phase11_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 11 manifest uses another baseline")
    require(phase11_manifest["status"] == "bounded-regression-evidence",
            "Phase 11 manifest is not complete")
    phase11_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "vdbe-core")
    require(phase11_manifest["mapped_entity_count"] == phase11_mapping_count == 66,
            "unexpected Phase 11 mapped entity count")
    require(phase11_manifest["implemented_opcode_count"] == 68,
            "unexpected Phase 11 opcode count")
    require(all(value["status"] == "pass" for value in phase11_manifest["slices"].values()),
            "a Phase 11 slice is not passing")
    require(all(value == "pass" for value in phase11_manifest["exit_gates"].values()),
            "a Phase 11 exit gate is not passing")
    require(vdbe_fixture_manifest["program_count"] == 15 and vdbe_fixture_manifest["observation_count"] == 53,
            "unexpected VDBE fixture corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-vdbe-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_vdbe_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/vdbe"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "VDBE fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"VDBE fixture regeneration differs: {path.name}")
    require(phase12_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 12 manifest uses another baseline")
    require(phase12_manifest["status"] == "bounded-regression-evidence",
            "Phase 12 manifest is not complete")
    phase12_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "statement-api")
    require(phase12_manifest["mapped_entity_count"] == phase12_mapping_count == 20,
            "unexpected Phase 12 mapped entity count")
    require(phase12_manifest["public_api"]["phase12_symbol_count"] == 33 and
            phase12_manifest["public_api"]["total_exported_sqlite_symbol_count"] == 38,
            "unexpected Phase 12 public API count")
    require(all(value["status"] == "pass" for value in phase12_manifest["slices"].values()),
            "a Phase 12 slice is not passing")
    require(all(value == "pass" for value in phase12_manifest["exit_gates"].values()),
            "a Phase 12 exit gate is not passing")
    require(statement_fixture_manifest["implemented_symbol_count"] == 33 and
            statement_fixture_manifest["canonical_header_assertions"] == 60,
            "unexpected statement fixture corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-statement-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_statement_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/statement"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "statement fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"statement fixture regeneration differs: {path.name}")
    require(phase13_expression_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 13 expression manifest uses another baseline")
    require(phase13_expression_manifest["status"] == "bounded-regression-evidence",
            "Phase 13 expression slice status mismatch")
    phase13_expression_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "sql-expression-slice")
    require(phase13_expression_manifest["mapped_entity_count"] == phase13_expression_mapping_count == 25,
            "unexpected Phase 13 expression mapped entity count")
    require(phase13_expression_manifest["public_prepare_symbol_count"] == 6 and
            phase13_expression_manifest["total_exported_sqlite_symbol_count"] == 44,
            "unexpected Phase 13 expression API count")
    require(all(value == "pass" for value in phase13_expression_manifest["slice_exit_gates"].values()),
            "a Phase 13 expression slice gate is not passing")
    require(sql_expression_fixture_manifest["case_count"] == 5 and
            sql_expression_fixture_manifest["differential_observations"] == 15,
            "unexpected SQL expression fixture corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-sql-expression-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_expression_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-expression"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "SQL expression fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"SQL expression fixture regeneration differs: {path.name}")
    require(phase13_schema_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 13 schema manifest uses another baseline")
    phase13_schema_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "sql-schema-slice")
    require(phase13_schema_manifest["mapped_entity_count"] == phase13_schema_mapping_count == 20,
            "unexpected Phase 13 schema mapped entity count")
    require(all(value == "pass" for value in phase13_schema_manifest["slice_exit_gates"].values()),
            "a Phase 13 schema slice gate is not passing")
    require(sql_schema_fixture_manifest["case_count"] == 8 and sql_schema_fixture_manifest["differential_observations"] == 8,
            "unexpected SQL schema fixture corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-sql-schema-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_schema_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-schema"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "SQL schema fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"SQL schema fixture regeneration differs: {path.name}")
    require(phase13_table_scan_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 13 table-scan manifest uses another baseline")
    phase13_table_scan_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "sql-table-scan-slice")
    require(phase13_table_scan_manifest["mapped_entity_count"] == phase13_table_scan_mapping_count == 16,
            "unexpected Phase 13 table-scan mapped entity count")
    require(all(value == "pass" for value in phase13_table_scan_manifest["slice_exit_gates"].values()),
            "a Phase 13 table-scan gate is not passing")
    require(sql_table_scan_fixture_manifest["row_count"] == 300 and sql_table_scan_fixture_manifest["differential_observations"] == 303,
            "unexpected SQL table-scan fixture corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-sql-table-scan-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_table_scan_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-table-scan"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "SQL table-scan fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"SQL table-scan fixture regeneration differs: {path.name}")
    require(phase13_insert_manifest["baseline_checkin"] == pinned["fossil_checkin"],
            "Phase 13 INSERT manifest uses another baseline")
    phase13_insert_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "sql-insert-slice")
    require(phase13_insert_manifest["mapped_entity_count"] == phase13_insert_mapping_count == 18,
            "unexpected Phase 13 INSERT mapped entity count")
    require(all(value == "pass" for value in phase13_insert_manifest["slice_exit_gates"].values()),
            "a Phase 13 INSERT gate is not passing")
    require(sql_insert_fixture_manifest["case_count"] == 5 and sql_insert_fixture_manifest["differential_observations"] == 9,
            "unexpected SQL INSERT fixture corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-sql-insert-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_insert_fixtures.py"), str(regenerated)],
                       check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-insert"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()),
                "SQL INSERT fixture generator output set differs")
        for path in regenerated.iterdir():
            require(path.read_bytes() == (committed / path.name).read_bytes(),
                    f"SQL INSERT fixture regeneration differs: {path.name}")
    require(phase13_update_delete_manifest["baseline_checkin"] == pinned["fossil_checkin"], "Phase 13 UPDATE/DELETE manifest uses another baseline")
    update_delete_mapping_count = sum(1 for mapping in symbol_map["entities"] if mapping["phase"] == "sql-update-delete-slice")
    require(phase13_update_delete_manifest["mapped_entity_count"] == update_delete_mapping_count == 18, "unexpected UPDATE/DELETE mapping count")
    require(all(value == "pass" for value in phase13_update_delete_manifest["slice_exit_gates"].values()), "an UPDATE/DELETE gate is not passing")
    require(sql_update_delete_fixture_manifest["case_count"] == 5 and sql_update_delete_fixture_manifest["differential_observations"] == 9, "unexpected UPDATE/DELETE corpus")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-sql-update-delete-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_update_delete_fixtures.py"), str(regenerated)], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-update-delete"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()), "UPDATE/DELETE fixture output set differs")
        for path in regenerated.iterdir(): require(path.read_bytes() == (committed / path.name).read_bytes(), f"UPDATE/DELETE fixture differs: {path.name}")
    require(phase13_manifest["status"] == "bounded-regression-evidence" and phase13_manifest["mapped_entity_count"] == 128, "Phase 13 completion manifest mismatch")
    require(all(value == "pass" for value in phase13_manifest["exit_gates"].values()), "a Phase 13 completion gate is not passing")
    require(phase13_index_join_manifest["mapped_entity_count"] == sum(1 for m in symbol_map["entities"] if m["phase"] == "sql-index-join-slice") == 19, "index/join mapping mismatch")
    require(phase13_advanced_manifest["mapped_entity_count"] == sum(1 for m in symbol_map["entities"] if m["phase"] == "sql-advanced-slice") == 12, "advanced mapping mismatch")
    require(sql_index_join_fixture_manifest["differential_observations"] == 604 and sql_advanced_fixture_manifest["differential_observations"] == 4, "final Phase 13 corpus mismatch")
    require(phase14_rowid_planner_manifest["mapped_entity_count"] == sum(1 for m in symbol_map["entities"] if m["phase"] == "phase14-rowid-planner-slice") == 16, "Phase 14 rowid planner mapping mismatch")
    require(sql_planner_fixture_manifest["differential_observations"] == 31 and sql_planner_fixture_manifest["native_runtime_budget_seconds"] == 2.0, "Phase 14 rowid planner corpus mismatch")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-phase14-planner-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_planner_fixtures.py"), str(regenerated)], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-planner"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()), "Phase 14 planner fixture set differs")
        for path in regenerated.iterdir(): require(path.read_bytes() == (committed / path.name).read_bytes(), f"Phase 14 planner fixture differs: {path.name}")
    require(phase14_index_order_manifest["mapped_entity_count"] == sum(1 for m in symbol_map["entities"] if m["phase"] == "phase14-index-order-slice") == 12, "Phase 14 index planner mapping mismatch")
    require(sql_index_planner_fixture_manifest["differential_observations"] == 7, "Phase 14 index planner corpus mismatch")
    require(phase14_manifest["status"] == "bounded-regression-evidence" and phase14_manifest["mapped_entity_count"] == 28 and phase14_manifest["differential_observations"] == 38, "Phase 14 completion manifest mismatch")
    require(all(value.startswith("pass") or value == "resolved-or-documented" for value in phase14_manifest["exit_gates"].values()), "a Phase 14 completion gate is not passing")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-phase14-index-planner-fixtures-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_sql_index_planner_fixtures.py"), str(regenerated)], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/sql-index-planner"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()), "Phase 14 index planner fixture set differs")
        for path in regenerated.iterdir(): require(path.read_bytes() == (committed / path.name).read_bytes(), f"Phase 14 index planner fixture differs: {path.name}")
    require(phase15_manifest["status"] == "bounded-regression-evidence" and phase15_manifest["mapped_entity_count"] == sum(1 for m in symbol_map["entities"] if m["phase"] == "phase15-unix-vfs") == 47, "Phase 15 Unix VFS mapping mismatch")
    require(all(value.startswith("pass") for value in phase15_manifest["exit_gates"].values()), "a Phase 15 exit gate is not passing")
    require(phase17_manifest["status"] == "bounded-regression-evidence" and not phase17_manifest["completion_claim"] and phase17_manifest["mapped_entity_count"] == sum(1 for m in symbol_map["entities"] if m["phase"].startswith("phase17")) == 238, "Phase 17 historical evidence manifest mismatch")
    require(phase17_manifest["exported_sqlite_symbol_count"] == 286 and phase17_manifest["provisional_bounded_symbol_count"] == 281, "Phase 17 provisional export manifest mismatch")
    require(phase17_fixture_manifest["canonical_header_assertions"] == 166 and phase17_fixture_manifest["exported_sqlite_symbols"] == 286 and not phase17_fixture_manifest["completion_claim"], "Phase 17 bounded corpus mismatch")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-phase17-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_phase17_fixtures.py"), str(regenerated)], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/phase17"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()), "Phase 17 fixture set differs")
        for path in regenerated.iterdir(): require(path.read_bytes() == (committed / path.name).read_bytes(), f"Phase 17 fixture differs: {path.name}")
    require(unix_vfs_fixture_manifest["cross_process_observations"] == 2 and unix_vfs_fixture_manifest["target"]["filesystem"] == "btrfs", "Phase 15 Unix VFS corpus mismatch")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-phase15-unix-vfs-") as temp:
        regenerated = pathlib.Path(temp)
        subprocess.run([sys.executable, str(ROOT / "tools/generate_unix_vfs_fixtures.py"), str(regenerated)], check=True, stdout=subprocess.DEVNULL)
        committed = ROOT / "tests/fixtures/unix-vfs"
        require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()), "Phase 15 Unix VFS fixture set differs")
        for path in regenerated.iterdir(): require(path.read_bytes() == (committed / path.name).read_bytes(), f"Phase 15 Unix VFS fixture differs: {path.name}")
    for script, directory in [("generate_sql_index_join_fixtures.py", "sql-index-join"), ("generate_sql_advanced_fixtures.py", "sql-advanced")]:
        with tempfile.TemporaryDirectory(prefix="sqlite-zig-final-phase13-fixtures-") as temp:
            regenerated = pathlib.Path(temp)
            subprocess.run([sys.executable, str(ROOT / "tools" / script), str(regenerated)], check=True, stdout=subprocess.DEVNULL)
            committed = ROOT / "tests/fixtures" / directory
            require(sorted(p.name for p in regenerated.iterdir()) == sorted(p.name for p in committed.iterdir()), f"{directory} fixture set differs")
            for path in regenerated.iterdir(): require(path.read_bytes() == (committed / path.name).read_bytes(), f"{directory} fixture differs: {path.name}")
    require(api_manifest["counts"]["variadic_functions"] == 8,
            "unexpected variadic API declaration count")
    implemented = {
        item["symbol"] for item in api_manifest["declarations"]
        if item["phase"] == "phase-0"
    }
    require(implemented == {
        "sqlite3_version", "sqlite3_libversion", "sqlite3_sourceid",
        "sqlite3_libversion_number", "sqlite3_threadsafe",
    }, "Phase 0 API manifest partition mismatch")
    phase12_api = {
        item["symbol"] for item in api_manifest["declarations"]
        if item["phase"] == "phase-12"
    }
    require(len(phase12_api) == api_manifest["counts"]["exported_phase_12"] == 33,
            "Phase 12 API manifest partition mismatch")
    phase13_expression_api = {
        item["symbol"] for item in api_manifest["declarations"]
        if item["phase"] == "phase-13-expression"
    }
    require(len(phase13_expression_api) == api_manifest["counts"]["exported_phase_13_expression"] == 6,
            "Phase 13 expression API manifest partition mismatch")
    phase17_connection_api = {item["symbol"] for item in api_manifest["declarations"] if item["phase"] == "phase-17-connection-utility"}
    phase17_value_blob_api = {item["symbol"] for item in api_manifest["declarations"] if item["phase"] == "phase-17-value-blob"}
    phase17_utility_api = {item["symbol"] for item in api_manifest["declarations"] if item["phase"] == "phase-17-utility-expansion"}
    phase17_callback_api = {item["symbol"] for item in api_manifest["declarations"] if item["phase"] == "phase-17-callback-context"}
    phase17_maintenance_api = {item["symbol"] for item in api_manifest["declarations"] if item["phase"] == "phase-17-maintenance"}
    phase17_extension_api = {item["symbol"] for item in api_manifest["declarations"] if item["phase"] == "phase-17-extension"}
    require(len(phase17_connection_api) == api_manifest["counts"]["exported_phase_17_connection_utility"] == 94,
            "Phase 17 connection API manifest partition mismatch")
    require(len(phase17_value_blob_api) == api_manifest["counts"]["exported_phase_17_value_blob"] == 42,
            "Phase 17 value/blob API manifest partition mismatch")
    require(len(phase17_utility_api) == api_manifest["counts"]["exported_phase_17_utility_expansion"] == 28,
            "Phase 17 utility API manifest partition mismatch")
    require(len(phase17_callback_api) == api_manifest["counts"]["exported_phase_17_callback_context"] == 42,
            "Phase 17 callback API manifest partition mismatch")
    require(len(phase17_maintenance_api) == api_manifest["counts"]["exported_phase_17_maintenance"] == 10,
            "Phase 17 maintenance API manifest partition mismatch")
    require(len(phase17_extension_api) == api_manifest["counts"]["exported_phase_17_extension"] == 26,
            "Phase 17 extension API manifest partition mismatch")
    require(api_manifest["counts"]["exported_total"] == 286,
            "unexpected provisional public export total")
    require(api_manifest["counts"]["fidelity_evidenced"] == 5 and api_manifest["counts"]["provisional_bounded"] == 281,
            "public API fidelity/provisional classification mismatch")
    require(api_manifest["counts"]["deferred_profile"] == 82 and api_manifest["counts"]["planned"] == 0,
            "deferred-profile public declaration classification mismatch")
    require(all(item["evidence"] for item in api_manifest["declarations"] if item["phase"].startswith("phase-17")),
            "Phase 17 API entry lacks evidence")
    require(all(item["evidence"] for item in api_manifest["declarations"] if item["phase"] == "phase-12"),
            "Phase 12 API entry lacks evidence")
    for relative, expected in expected_generated.items():
        path = ROOT / relative
        require(path.is_file(), f"missing generated artifact: {relative}")
        require(sha256(path) == expected, f"generated artifact drift: {relative}")

    header = (ROOT / "include/sqlite3.h").read_text()
    expected_macros = {
        "SQLITE_VERSION": f'"{pinned["version"]}"',
        "SQLITE_VERSION_NUMBER": "3053004",
        "SQLITE_SOURCE_ID": f'"{pinned["sqlite_source_id"]}"',
    }
    for name, expected in expected_macros.items():
        match = re.search(rf"^#define\s+{name}\s+(.+)$", header, re.MULTILINE)
        require(match is not None and match.group(1).strip() == expected,
                f"header macro mismatch: {name}")

    zig = pathlib.Path(shutil.which("zig") or "")
    require(zig.is_file(), "zig not found")
    version = subprocess.check_output([str(zig), "version"], text=True).strip()
    require(version == pinned["zig_version"], f"expected Zig {pinned['zig_version']}, got {version}")
    require(sha256(zig.resolve()) == pinned["zig_compiler_binary_sha256"],
            "Zig compiler binary checksum mismatch")

    compiler = shutil.which("cc")
    require(compiler is not None, "C compiler not found for src-verify")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-verify-") as temp:
        verifier = pathlib.Path(temp) / "src-verify"
        subprocess.run([
            compiler,
            "-std=c99",
            "-O2",
            str(ROOT / "upstream/sqlite/tool/src-verify.c"),
            "-o",
            str(verifier),
        ], check=True)
        result = subprocess.check_output([str(verifier), str(ROOT / "upstream/sqlite")], text=True)
        require(result.startswith("OK "), "SQLite src-verify did not report OK")

    print("verify-config: pinned source, toolchain, headers, parser probe, and oracle artifacts OK")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
