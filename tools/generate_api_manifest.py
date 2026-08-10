#!/usr/bin/env python3
"""Generate the baseline public API declaration inventory from sqlite3.h.

This is intentionally an inventory generator, not a C parser. ABI layout and
calling-convention facts are independently checked by compiled C probes.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
HEADER = ROOT / "include/sqlite3.h"
OUTPUT = ROOT / "upstream/api-manifest.json"
IMPLEMENTED = {
    "sqlite3_version",
    "sqlite3_libversion",
    "sqlite3_sourceid",
    "sqlite3_libversion_number",
    "sqlite3_threadsafe",
}
PHASE12 = {
    "sqlite3_step", "sqlite3_reset", "sqlite3_finalize", "sqlite3_clear_bindings",
    "sqlite3_bind_parameter_count", "sqlite3_bind_parameter_name", "sqlite3_bind_parameter_index",
    "sqlite3_bind_null", "sqlite3_bind_int", "sqlite3_bind_int64", "sqlite3_bind_double",
    "sqlite3_bind_text", "sqlite3_bind_text16", "sqlite3_bind_text64",
    "sqlite3_bind_blob", "sqlite3_bind_blob64", "sqlite3_bind_zeroblob", "sqlite3_bind_zeroblob64",
    "sqlite3_column_count", "sqlite3_data_count", "sqlite3_column_type", "sqlite3_column_int",
    "sqlite3_column_int64", "sqlite3_column_double", "sqlite3_column_text", "sqlite3_column_text16",
    "sqlite3_column_blob", "sqlite3_column_bytes", "sqlite3_column_bytes16", "sqlite3_column_name",
    "sqlite3_stmt_busy", "sqlite3_stmt_readonly", "sqlite3_stmt_isexplain",
}
PHASE13 = {
    "sqlite3_prepare", "sqlite3_prepare_v2", "sqlite3_prepare_v3",
    "sqlite3_prepare16", "sqlite3_prepare16_v2", "sqlite3_prepare16_v3",
}
PHASE17_CONNECTION = set("""
sqlite3_compileoption_used sqlite3_compileoption_get sqlite3_close sqlite3_close_v2 sqlite3_exec
sqlite3_initialize sqlite3_shutdown sqlite3_os_init sqlite3_os_end sqlite3_extended_result_codes
sqlite3_last_insert_rowid sqlite3_set_last_insert_rowid sqlite3_changes sqlite3_changes64
sqlite3_total_changes sqlite3_total_changes64 sqlite3_interrupt sqlite3_is_interrupted sqlite3_complete
sqlite3_complete16 sqlite3_malloc sqlite3_malloc64 sqlite3_realloc sqlite3_realloc64 sqlite3_free
sqlite3_msize sqlite3_memory_used sqlite3_memory_highwater sqlite3_randomness sqlite3_open sqlite3_open16
sqlite3_open_v2 sqlite3_uri_parameter sqlite3_uri_boolean sqlite3_uri_int64 sqlite3_filename_database
sqlite3_filename_journal sqlite3_filename_wal sqlite3_errcode sqlite3_extended_errcode sqlite3_errmsg
sqlite3_errmsg16 sqlite3_errstr sqlite3_error_offset sqlite3_sleep sqlite3_get_autocommit
sqlite3_db_handle sqlite3_db_name sqlite3_db_filename sqlite3_db_readonly sqlite3_txn_state
sqlite3_release_memory sqlite3_soft_heap_limit64 sqlite3_hard_heap_limit64 sqlite3_soft_heap_limit
sqlite3_keyword_count sqlite3_keyword_name sqlite3_keyword_check sqlite3_stricmp sqlite3_strnicmp
sqlite3_strglob sqlite3_strlike sqlite3_vfs_find sqlite3_vfs_register sqlite3_vfs_unregister
sqlite3_mutex_alloc sqlite3_mutex_free sqlite3_mutex_enter sqlite3_mutex_try sqlite3_mutex_leave
sqlite3_mutex_held sqlite3_mutex_notheld sqlite3_limit sqlite3_sql sqlite3_stmt_status
sqlite3_status sqlite3_status64 sqlite3_db_status sqlite3_db_status64 sqlite3_file_control
sqlite3_db_cacheflush sqlite3_system_errno sqlite3_busy_handler sqlite3_busy_timeout sqlite3_setlk_timeout
sqlite3_serialize sqlite3_deserialize sqlite3_backup_init sqlite3_backup_step sqlite3_backup_finish
sqlite3_backup_remaining sqlite3_backup_pagecount sqlite3_wal_checkpoint sqlite3_wal_checkpoint_v2
""".split())
PHASE17_VALUE_BLOB = set("""
sqlite3_bind_value sqlite3_blob_bytes sqlite3_blob_close sqlite3_blob_open sqlite3_blob_read
sqlite3_blob_reopen sqlite3_blob_write sqlite3_column_database_name sqlite3_column_database_name16
sqlite3_column_decltype sqlite3_column_decltype16 sqlite3_column_name16 sqlite3_column_origin_name
sqlite3_column_origin_name16 sqlite3_column_table_name sqlite3_column_table_name16 sqlite3_column_value
sqlite3_expanded_sql sqlite3_expired sqlite3_stmt_explain sqlite3_transfer_bindings sqlite3_value_blob
sqlite3_value_bytes sqlite3_value_bytes16 sqlite3_value_double sqlite3_value_dup sqlite3_value_encoding
sqlite3_value_free sqlite3_value_frombind sqlite3_value_int sqlite3_value_int64 sqlite3_value_nochange
sqlite3_value_numeric_type sqlite3_value_subtype sqlite3_value_text sqlite3_value_text16
sqlite3_value_text16be sqlite3_value_text16le sqlite3_value_type sqlite3_bind_pointer
sqlite3_result_pointer sqlite3_value_pointer
""".split())
PHASE17_UTILITY2 = set("""
sqlite3_data_directory sqlite3_db_release_memory sqlite3_enable_shared_cache sqlite3_free_table
sqlite3_get_table sqlite3_global_recover sqlite3_memory_alarm sqlite3_mprintf sqlite3_progress_handler
sqlite3_set_authorizer sqlite3_snprintf sqlite3_str_append sqlite3_str_appendall sqlite3_str_appendchar
sqlite3_str_appendf sqlite3_str_errcode sqlite3_str_finish sqlite3_str_free sqlite3_str_length
sqlite3_str_new sqlite3_str_reset sqlite3_str_truncate sqlite3_str_value sqlite3_str_vappendf
sqlite3_temp_directory sqlite3_thread_cleanup sqlite3_vmprintf sqlite3_vsnprintf
""".split())
PHASE17_CALLBACK = set("""
sqlite3_aggregate_context sqlite3_aggregate_count sqlite3_commit_hook sqlite3_context_db_handle
sqlite3_create_filename sqlite3_create_function sqlite3_create_function16 sqlite3_create_function_v2
sqlite3_database_file_object sqlite3_free_filename sqlite3_get_auxdata sqlite3_get_clientdata
sqlite3_next_stmt sqlite3_profile sqlite3_result_blob sqlite3_result_blob64 sqlite3_result_double
sqlite3_result_error sqlite3_result_error16 sqlite3_result_error_code sqlite3_result_error_nomem
sqlite3_result_error_toobig sqlite3_result_int sqlite3_result_int64 sqlite3_result_null
sqlite3_result_subtype sqlite3_result_text sqlite3_result_text16 sqlite3_result_text16be
sqlite3_result_text16le sqlite3_result_text64 sqlite3_result_value sqlite3_result_zeroblob
sqlite3_result_zeroblob64 sqlite3_rollback_hook sqlite3_set_auxdata sqlite3_set_clientdata
sqlite3_trace sqlite3_trace_v2 sqlite3_update_hook sqlite3_uri_key sqlite3_user_data
""".split())
PHASE17_MAINTENANCE = set("""
sqlite3_set_errmsg sqlite3_table_column_metadata sqlite3_unlock_notify sqlite3_wal_autocheckpoint
sqlite3_wal_hook sqlite3_config sqlite3_log sqlite3_db_mutex sqlite3_db_config sqlite3_test_control
""".split())
PHASE17_EXTENSION = set("""
sqlite3_auto_extension sqlite3_cancel_auto_extension sqlite3_create_window_function
sqlite3_enable_load_extension sqlite3_load_extension sqlite3_reset_auto_extension
sqlite3_autovacuum_pages sqlite3_collation_needed sqlite3_collation_needed16 sqlite3_create_collation
sqlite3_create_collation16 sqlite3_create_collation_v2 sqlite3_create_module sqlite3_create_module_v2
sqlite3_declare_vtab sqlite3_drop_modules sqlite3_overload_function sqlite3_vtab_on_conflict
sqlite3_vtab_config sqlite3_vtab_nochange sqlite3_vtab_collation sqlite3_vtab_distinct
sqlite3_vtab_in sqlite3_vtab_in_first sqlite3_vtab_in_next sqlite3_vtab_rhs_value
""".split())


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def condition_text(stack: list[str]) -> str:
    return " && ".join(f"({item})" for item in stack) if stack else "always"


def symbol_from(declaration: str) -> tuple[str, str]:
    semantic = re.sub(r"/\*.*?\*/", " ", declaration)
    function = re.search(r"\b(sqlite3[A-Za-z0-9_]*)\s*\(", semantic)
    if function:
        return function.group(1), "variadic-function" if "..." in semantic else "function"
    data = re.search(r"\b(sqlite3_[A-Za-z0-9_]*)\s*(?:\[|;|=)", semantic)
    if data:
        return data.group(1), "data"
    raise ValueError(f"cannot identify SQLITE_API declaration: {declaration}")


def deferred_profile(symbol: str) -> bool:
    prefixes = ("sqlite3session_", "sqlite3changeset_", "sqlite3changegroup_", "sqlite3rebaser_", "sqlite3_preupdate_", "sqlite3_snapshot_", "sqlite3_carray_", "sqlite3_rtree_", "sqlite3_win32_", "sqlite3_stmt_scanstatus")
    return symbol.startswith(prefixes) or symbol in {"sqlite3_normalized_sql", "sqlite3_activate_cerod"}


def main() -> None:
    lines = HEADER.read_text().splitlines()
    conditions: list[str] = []
    declarations: list[dict[str, object]] = []
    current: list[str] | None = None
    current_line = 0
    current_condition = "always"

    for line_number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("#if "):
            conditions.append(stripped[4:].strip())
        elif stripped.startswith("#ifdef "):
            conditions.append(f"defined({stripped[7:].strip()})")
        elif stripped.startswith("#ifndef "):
            conditions.append(f"!defined({stripped[8:].strip()})")
        elif stripped.startswith("#elif ") and conditions:
            conditions[-1] = stripped[6:].strip()
        elif stripped == "#else" and conditions:
            conditions[-1] = f"else-of({conditions[-1]})"
        elif stripped.startswith("#endif") and conditions:
            conditions.pop()

        if current is None and line.startswith("SQLITE_API"):
            current = [stripped]
            current_line = line_number
            current_condition = condition_text(conditions)
        elif current is not None:
            current.append(stripped)

        if current is not None and ";" in stripped:
            declaration = re.sub(r"\s+", " ", " ".join(current)).strip()
            symbol, kind = symbol_from(declaration)
            declarations.append({
                "symbol": symbol,
                "kind": kind,
                "header_line": current_line,
                "condition": current_condition,
                "declaration": declaration,
                "phase": "phase-0" if symbol in IMPLEMENTED else "phase-12" if symbol in PHASE12 else "phase-13-expression" if symbol in PHASE13 else "phase-17-connection-utility" if symbol in PHASE17_CONNECTION else "phase-17-value-blob" if symbol in PHASE17_VALUE_BLOB else "phase-17-utility-expansion" if symbol in PHASE17_UTILITY2 else "phase-17-callback-context" if symbol in PHASE17_CALLBACK else "phase-17-maintenance" if symbol in PHASE17_MAINTENANCE else "phase-17-extension" if symbol in PHASE17_EXTENSION else "deferred-profile" if deferred_profile(symbol) else "planned",
                "status": "fidelity-evidenced" if symbol in IMPLEMENTED else "deferred-profile" if deferred_profile(symbol) else "provisional-bounded",
                "evidence": ["tests/api/version_client.c"] if symbol in IMPLEMENTED else ["tests/api/statement_client.c", "src/core/statement.zig"] if symbol in PHASE12 else ["tests/differential/sql_expression_client.c", "src/core/sql_frontend.zig"] if symbol in PHASE13 else ["tests/api/phase17_connection_client.c"] if symbol in (PHASE17_CONNECTION | PHASE17_VALUE_BLOB | PHASE17_UTILITY2 | PHASE17_CALLBACK | PHASE17_MAINTENANCE | PHASE17_EXTENSION) else [],
            })
            current = None

    if current is not None:
        raise SystemExit(f"unterminated SQLITE_API declaration at line {current_line}")
    names = [item["symbol"] for item in declarations]
    if len(names) != len(set(names)):
        duplicates = sorted(name for name in set(names) if names.count(name) > 1)
        raise SystemExit(f"duplicate public symbols require explicit handling: {duplicates}")
    if not (IMPLEMENTED | PHASE12 | PHASE13 | PHASE17_CONNECTION | PHASE17_VALUE_BLOB | PHASE17_UTILITY2 | PHASE17_CALLBACK | PHASE17_MAINTENANCE | PHASE17_EXTENSION).issubset(names):
        raise SystemExit(f"implemented symbols missing from header: {sorted((IMPLEMENTED | PHASE12 | PHASE13 | PHASE17_CONNECTION | PHASE17_VALUE_BLOB | PHASE17_UTILITY2 | PHASE17_CALLBACK | PHASE17_MAINTENANCE | PHASE17_EXTENSION) - set(names))}")

    manifest = {
        "schema_version": 1,
        "sqlite_checkin": "bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc",
        "header": "include/sqlite3.h",
        "header_sha256": sha256(HEADER),
        "counts": {
            "total": len(declarations),
            "functions": sum(item["kind"] == "function" for item in declarations),
            "variadic_functions": sum(item["kind"] == "variadic-function" for item in declarations),
            "data": sum(item["kind"] == "data" for item in declarations),
            "exported_phase_0": sum(item["phase"] == "phase-0" for item in declarations),
            "exported_phase_12": sum(item["phase"] == "phase-12" for item in declarations),
            "exported_phase_13_expression": sum(item["phase"] == "phase-13-expression" for item in declarations),
            "exported_phase_17_connection_utility": sum(item["phase"] == "phase-17-connection-utility" for item in declarations),
            "exported_phase_17_value_blob": sum(item["phase"] == "phase-17-value-blob" for item in declarations),
            "exported_phase_17_utility_expansion": sum(item["phase"] == "phase-17-utility-expansion" for item in declarations),
            "exported_phase_17_callback_context": sum(item["phase"] == "phase-17-callback-context" for item in declarations),
            "exported_phase_17_maintenance": sum(item["phase"] == "phase-17-maintenance" for item in declarations),
            "exported_phase_17_extension": sum(item["phase"] == "phase-17-extension" for item in declarations),
            "exported_total": sum(item["phase"] in {"phase-0", "phase-12", "phase-13-expression", "phase-17-connection-utility", "phase-17-value-blob", "phase-17-utility-expansion", "phase-17-callback-context", "phase-17-maintenance", "phase-17-extension"} for item in declarations),
            "fidelity_evidenced": sum(item["status"] == "fidelity-evidenced" for item in declarations),
            "provisional_bounded": sum(item["status"] == "provisional-bounded" for item in declarations),
            "deferred_profile": sum(item["phase"] == "deferred-profile" for item in declarations),
            "planned": sum(item["phase"] == "planned" for item in declarations),
        },
        "declarations": declarations,
    }
    OUTPUT.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"generated {OUTPUT.relative_to(ROOT)} with {len(declarations)} declarations")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
