#!/usr/bin/env python3
"""Generate or verify the historical-public-to-Zig responsibility inventory.

The canonical C declarations are inputs, not the product API. Every declaration
is retained so removing C transport cannot silently remove SQLite behavior.
Current C-shaped Zig declarations are migration candidates only.
"""

from __future__ import annotations

import argparse
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
API_MANIFEST = ROOT / "upstream/api-manifest.json"
ZIG_INVENTORY = ROOT / "upstream/zig-declaration-inventory.json"
OUTPUT = ROOT / "upstream/public-responsibility-inventory.json"

NON_VARIADIC_BEHAVIOR_TARGETS = {
    "sqlite3_config": [
        "src/core/public_api.zig::function::zig_sqlite3_config_no_args",
        "src/core/public_api.zig::function::zig_sqlite3_config_memstatus",
        "src/core/public_api.zig::function::zig_sqlite3_config_log",
    ],
    "sqlite3_db_config": [
        "src/core/sql_frontend.zig::function::zig_sqlite3_db_config_main_name",
        "src/core/sql_frontend.zig::function::zig_sqlite3_db_config_lookaside",
        "src/core/sql_frontend.zig::function::zig_sqlite3_db_config_flag",
    ],
    "sqlite3_log": ["src/core/public_api.zig::function::logFormat"],
    "sqlite3_mprintf": ["src/core/formatter.zig::function::allocFormat"],
    "sqlite3_snprintf": ["src/core/formatter.zig::function::fixedFormat"],
    "sqlite3_str_appendf": ["src/core/formatter.zig::function::strAppendFormat"],
    "sqlite3_str_vappendf": ["src/core/formatter.zig::function::strAppendFormat"],
    "sqlite3_test_control": [
        "src/core/public_api.zig::function::zig_sqlite3_test_control_no_args",
        "src/core/public_api.zig::function::zig_sqlite3_test_control_int",
    ],
    "sqlite3_vmprintf": ["src/core/formatter.zig::function::allocFormat"],
    "sqlite3_vsnprintf": ["src/core/formatter.zig::function::fixedFormat"],
    "sqlite3_vtab_config": ["src/core/sql_frontend.zig::function::zig_sqlite3_vtab_config"],
}

PLANNED_OWNERS = {
    "backup": "src/api/backup.zig",
    "binding": "src/api/statement.zig",
    "callback": "src/api/callback.zig",
    "collation": "src/api/collation.zig",
    "column": "src/api/statement.zig",
    "configuration": "src/api/configuration.zig",
    "connection": "src/api/connection.zig",
    "extension": "src/api/extension.zig",
    "formatting": "src/api/formatting.zig",
    "incremental-blob": "src/api/blob.zig",
    "memory": "src/api/memory.zig",
    "metadata": "src/api/metadata.zig",
    "mutex": "src/api/mutex.zig",
    "statement": "src/api/statement.zig",
    "status": "src/api/status.zig",
    "value": "src/api/value.zig",
    "vfs": "src/api/vfs.zig",
    "virtual-table": "src/api/virtual_table.zig",
}


def domain_for(symbol: str) -> str:
    if symbol.startswith("sqlite3_backup_"):
        return "backup"
    if symbol.startswith("sqlite3_bind_"):
        return "binding"
    if symbol.startswith("sqlite3_blob_"):
        return "incremental-blob"
    if symbol.startswith("sqlite3_column_") or symbol == "sqlite3_data_count":
        return "column"
    if symbol.startswith("sqlite3_value_"):
        return "value"
    if symbol.startswith("sqlite3_result_") or symbol in {
        "sqlite3_aggregate_context", "sqlite3_aggregate_count", "sqlite3_context_db_handle",
        "sqlite3_get_auxdata", "sqlite3_set_auxdata", "sqlite3_user_data",
    }:
        return "callback"
    if symbol.startswith("sqlite3_str_") or symbol in {
        "sqlite3_mprintf", "sqlite3_vmprintf", "sqlite3_snprintf", "sqlite3_vsnprintf",
    }:
        return "formatting"
    if symbol.startswith("sqlite3_mutex_") or symbol == "sqlite3_db_mutex":
        return "mutex"
    if symbol.startswith("sqlite3_vfs_") or symbol in {
        "sqlite3_file_control", "sqlite3_filename_database", "sqlite3_filename_journal",
        "sqlite3_filename_wal", "sqlite3_create_filename", "sqlite3_free_filename",
        "sqlite3_database_file_object", "sqlite3_system_errno",
    }:
        return "vfs"
    if symbol.startswith("sqlite3_vtab_") or symbol in {
        "sqlite3_create_module", "sqlite3_create_module_v2", "sqlite3_declare_vtab",
        "sqlite3_drop_modules", "sqlite3_overload_function",
    }:
        return "virtual-table"
    if "collation" in symbol:
        return "collation"
    if symbol.startswith("sqlite3_create_function") or symbol == "sqlite3_create_window_function":
        return "callback"
    if symbol.startswith("sqlite3_status") or symbol.startswith("sqlite3_db_status") or symbol == "sqlite3_stmt_status":
        return "status"
    if symbol.startswith("sqlite3_malloc") or symbol.startswith("sqlite3_realloc") or symbol in {
        "sqlite3_free", "sqlite3_msize", "sqlite3_memory_used", "sqlite3_memory_highwater",
        "sqlite3_release_memory", "sqlite3_db_release_memory", "sqlite3_soft_heap_limit",
        "sqlite3_soft_heap_limit64", "sqlite3_hard_heap_limit64", "sqlite3_memory_alarm",
    }:
        return "memory"
    if symbol in {
        "sqlite3_config", "sqlite3_db_config", "sqlite3_test_control", "sqlite3_limit",
        "sqlite3_extended_result_codes", "sqlite3_enable_shared_cache",
    }:
        return "configuration"
    if symbol.startswith("sqlite3_prepare") or symbol in {
        "sqlite3_step", "sqlite3_reset", "sqlite3_finalize", "sqlite3_clear_bindings",
        "sqlite3_transfer_bindings", "sqlite3_expired", "sqlite3_expanded_sql",
        "sqlite3_sql", "sqlite3_normalized_sql", "sqlite3_stmt_busy", "sqlite3_stmt_readonly",
        "sqlite3_stmt_isexplain", "sqlite3_stmt_explain", "sqlite3_next_stmt",
    }:
        return "statement"
    if symbol in {
        "sqlite3_version", "sqlite3_libversion", "sqlite3_sourceid", "sqlite3_libversion_number",
        "sqlite3_threadsafe", "sqlite3_compileoption_used", "sqlite3_compileoption_get",
        "sqlite3_keyword_count", "sqlite3_keyword_name", "sqlite3_keyword_check",
    }:
        return "metadata"
    if symbol in {
        "sqlite3_auto_extension", "sqlite3_cancel_auto_extension", "sqlite3_reset_auto_extension",
        "sqlite3_enable_load_extension", "sqlite3_load_extension",
    }:
        return "extension"
    if symbol.endswith("_hook") or symbol in {
        "sqlite3_busy_handler", "sqlite3_busy_timeout", "sqlite3_progress_handler",
        "sqlite3_set_authorizer", "sqlite3_trace", "sqlite3_trace_v2", "sqlite3_profile",
        "sqlite3_unlock_notify", "sqlite3_log",
    }:
        return "callback"
    return "connection"


def generate() -> dict:
    api = json.loads(API_MANIFEST.read_text())
    zig = json.loads(ZIG_INVENTORY.read_text())
    declarations_by_name: dict[str, list[str]] = {}
    zig_ids = {item["id"] for item in zig["declarations"]}
    for item in zig["declarations"]:
        declarations_by_name.setdefault(item["name"], []).append(item["id"])

    entries = []
    for declaration in api["declarations"]:
        symbol = declaration["symbol"]
        deferred = declaration["phase"] == "deferred-profile"
        candidates = sorted(declarations_by_name.get(symbol, [])) if not deferred else []
        non_variadic_targets = NON_VARIADIC_BEHAVIOR_TARGETS.get(symbol, []) if not deferred else []
        missing_targets = [target for target in non_variadic_targets if target not in zig_ids]
        if missing_targets:
            raise SystemExit(
                f"public-responsibility-inventory: unresolved non-variadic targets for {symbol}: {missing_targets}"
            )
        if deferred:
            status = "deferred-profile"
        elif declaration["status"] == "fidelity-evidenced":
            status = "fidelity-evidenced-transitional-c-shaped"
        elif candidates:
            status = "provisional-bounded-transitional-c-shaped"
        elif non_variadic_targets:
            status = "non-variadic-behavior-target-partial"
        else:
            status = "unmapped-required-behavior"
        domain = domain_for(symbol)
        entries.append({
            "historical_symbol": symbol,
            "historical_kind": declaration["kind"],
            "historical_header_line": declaration["header_line"],
            "behavior_scope": "deferred-profile" if deferred else "active-required",
            "responsibility_id": f"public.{domain}.{symbol.removeprefix('sqlite3_')}",
            "domain": domain,
            "planned_zig_api_owner": PLANNED_OWNERS[domain],
            "c_transport_disposition": (
                "c-varargs-or-va-list-not-product-required"
                if declaration["kind"] == "variadic-function" or symbol in NON_VARIADIC_BEHAVIOR_TARGETS
                else "c-symbol-and-calling-convention-not-product-required"
            ),
            "behavior_disposition": (
                "deferred-with-profile" if deferred else "must-remain-in-zig-product"
            ),
            "current_zig_candidates": candidates,
            "non_variadic_behavior_targets": non_variadic_targets,
            "implementation_status": status,
            "completion_credit": False,
        })

    active = [entry for entry in entries if entry["behavior_scope"] == "active-required"]
    deferred = [entry for entry in entries if entry["behavior_scope"] == "deferred-profile"]
    unmapped = [entry for entry in active if entry["implementation_status"] == "unmapped-required-behavior"]
    if len(entries) != api["counts"]["total"] or len(active) != api["counts"]["exported_total"]:
        raise SystemExit("public-responsibility-inventory: API manifest count mismatch")
    if unmapped:
        raise SystemExit(
            "public-responsibility-inventory: active behavior lacks even a migration target: "
            + ", ".join(entry["historical_symbol"] for entry in unmapped)
        )

    return {
        "schema_version": 1,
        "sqlite_checkin": api["sqlite_checkin"],
        "source": "upstream/api-manifest.json",
        "goal": "account for public SQLite behavior while replacing C transport with a coherent Zig-native API",
        "warning": "Current Zig candidates are transitional evidence. Planned owner paths are design assignments, not implemented declarations or completion evidence.",
        "summary": {
            "historical_header_declarations": len(entries),
            "active_required_behavior_entries": len(active),
            "active_behavior_entries_accounted": len(active) - len(unmapped),
            "deferred_profile_entries": len(deferred),
            "active_entries_with_transitional_c_shaped_zig_candidates": sum(bool(entry["current_zig_candidates"]) for entry in active),
            "active_c_variadic_transport_entries": sum(entry["c_transport_disposition"] == "c-varargs-or-va-list-not-product-required" for entry in active),
            "active_variadic_transport_entries_with_non_variadic_targets": sum(bool(entry["non_variadic_behavior_targets"]) for entry in active),
            "active_entries_complete": 0,
            "planned_zig_api_domains": len({entry["domain"] for entry in active}),
        },
        "responsibilities": entries,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    report = generate()
    rendered = json.dumps(report, indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
            raise SystemExit(
                "public-responsibility-inventory: stale; "
                "run tools/generate_public_responsibility_inventory.py"
            )
        summary = report["summary"]
        print(
            "public-responsibility-inventory: verified "
            f"{summary['active_behavior_entries_accounted']}/"
            f"{summary['active_required_behavior_entries']} active behavior entries accounted"
        )
        return
    OUTPUT.write_text(rendered)
    print(f"public-responsibility-inventory: wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
