#!/usr/bin/env python3
"""Compare native limit/config constants with the pinned C preprocessor."""

from __future__ import annotations

import json
import pathlib
import re
import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROFILE = json.loads((ROOT / "upstream/SQLITE_BUILD_PROFILE.json").read_text())
FIELDS = {
    "SQLITE_MAX_LENGTH": "max_length",
    "SQLITE_MIN_LENGTH": "min_length",
    "SQLITE_MAX_ALLOCATION_SIZE": "max_allocation_size",
    "SQLITE_MAX_COLUMN": "max_column",
    "SQLITE_MAX_SQL_LENGTH": "max_sql_length",
    "SQLITE_MAX_EXPR_DEPTH": "max_expr_depth",
    "SQLITE_MAX_PARSER_DEPTH": "max_parser_depth",
    "SQLITE_MAX_COMPOUND_SELECT": "max_compound_select",
    "SQLITE_MAX_VDBE_OP": "max_vdbe_op",
    "SQLITE_MAX_FUNCTION_ARG": "max_function_arg",
    "SQLITE_DEFAULT_CACHE_SIZE": "default_cache_size",
    "SQLITE_DEFAULT_WAL_AUTOCHECKPOINT": "default_wal_autocheckpoint",
    "SQLITE_MAX_ATTACHED": "max_attached",
    "SQLITE_MAX_VARIABLE_NUMBER": "max_variable_number",
    "SQLITE_MAX_PAGE_SIZE": "max_page_size",
    "SQLITE_DEFAULT_PAGE_SIZE": "default_page_size",
    "SQLITE_MAX_DEFAULT_PAGE_SIZE": "max_default_page_size",
    "SQLITE_MAX_PAGE_COUNT": "max_page_count",
    "SQLITE_MAX_LIKE_PATTERN_LENGTH": "max_like_pattern_length",
    "SQLITE_MAX_TRIGGER_DEPTH": "max_trigger_depth",
    "SQLITE_DEFAULT_MEMSTATUS": "default_memstatus",
    "SQLITE_DEFAULT_SYNCHRONOUS": "default_synchronous",
    "SQLITE_DEFAULT_WAL_SYNCHRONOUS": "default_wal_synchronous",
    "SQLITE_DEFAULT_RECURSIVE_TRIGGERS": "default_recursive_triggers",
    "SQLITE_MAX_WORKER_THREADS": "max_worker_threads",
    "SQLITE_DEFAULT_WORKER_THREADS": "default_worker_threads",
    "SQLITE_DEFAULT_PCACHE_INITSZ": "default_pcache_initial_size",
    "SQLITE_DEFAULT_MMAP_SIZE": "default_mmap_size",
}


def parse_c_integer(text: str, macros: dict[str, str]) -> int:
    seen: set[str] = set()
    while text in macros and text not in seen:
        seen.add(text)
        text = macros[text]
    text = text.strip().strip("()")
    return int(re.sub(r"(?i)(u|l)+$", "", text), 0)


def main() -> None:
    compiler = PROFILE["oracle"]["production_compiler"]["path"]
    defines = [f"-D{name}={value}" for name, value in PROFILE["configure"]["library_defines"].items()]
    output = subprocess.check_output([
        compiler, "-std=c99", *defines, "-dM", "-E",
        str(ROOT / "reference/c_oracle/sqlite3.c"),
    ], text=True)
    macros: dict[str, str] = {}
    for line in output.splitlines():
        match = re.match(r"#define\s+(\w+)\s+(.+)$", line)
        if match:
            macros[match.group(1)] = match.group(2).strip()

    zig = (ROOT / "config/limits.zig").read_text()
    for macro, field in FIELDS.items():
        match = re.search(rf"pub const {field}(?::[^=]+)?=\s*([^;]+);", zig)
        if not match:
            raise SystemExit(f"verify-limits: missing Zig field {field}")
        value_text = match.group(1).strip().replace("_", "")
        if value_text in {"true", "false"}:
            zig_value = int(value_text == "true")
        else:
            zig_value = int(value_text, 0)
        c_value = parse_c_integer(macros[macro], macros)
        if zig_value != c_value:
            raise SystemExit(f"verify-limits: {field}={zig_value}, {macro}={c_value}")

    features = (ROOT / "config/features.zig").read_text()
    expected_features = dict(PROFILE["configure"]["optional_builtin_extensions"])
    expected_features.update({
        "loadable_extensions": PROFILE["configure"]["loadable_extensions"],
        "json": PROFILE["configure"]["json"],
        "math_functions": PROFILE["configure"]["library_defines"].get("SQLITE_ENABLE_MATH_FUNCTIONS") == "1",
        "percentile": PROFILE["configure"]["library_defines"].get("SQLITE_ENABLE_PERCENTILE") == "1",
        "zlib": PROFILE["configure"]["library_defines"].get("SQLITE_HAVE_ZLIB") == "1",
    })
    for name, enabled in expected_features.items():
        match = re.search(rf"pub const {name} = (true|false);", features)
        if not match or (match.group(1) == "true") != enabled:
            raise SystemExit(f"verify-limits: feature mismatch: {name}")
    infrastructure = (ROOT / "config/infrastructure.zig").read_text()
    infrastructure_expected = {
        "threadsafe": int(macros["SQLITE_THREADSAFE"]),
        "default_core_mutex": int(macros["SQLITE_THREADSAFE"]) > 0,
        "default_connection_mutex": int(macros["SQLITE_THREADSAFE"]) == 1,
        "default_memory_statistics": parse_c_integer(macros["SQLITE_DEFAULT_MEMSTATUS"], macros) != 0,
        "two_size_lookaside": "SQLITE_OMIT_TWOSIZE_LOOKASIDE" not in macros,
        "dedicated_scratch_allocator": False,
        "memory_management_release": "SQLITE_ENABLE_MEMORY_MANAGEMENT" in macros,
        "system_allocator": "SQLITE_SYSTEM_MALLOC" in macros,
    }
    lookaside_size, lookaside_count = (int(value) for value in macros["SQLITE_DEFAULT_LOOKASIDE"].split(","))
    infrastructure_expected["default_lookaside_slot_size"] = lookaside_size
    infrastructure_expected["default_lookaside_slot_count"] = lookaside_count
    for name, expected in infrastructure_expected.items():
        match = re.search(rf"pub const {name}(?::[^=]+)?\s*=\s*([^;]+);", infrastructure)
        if not match:
            raise SystemExit(f"verify-limits: missing infrastructure choice: {name}")
        text = match.group(1).strip().replace("_", "")
        actual = text == "true" if text in {"true", "false"} else int(text, 0)
        if actual != expected:
            raise SystemExit(f"verify-limits: infrastructure mismatch: {name}")
    print(
        f"verify-limits: {len(FIELDS)} limits/defaults, {len(expected_features)} features, "
        f"and {len(infrastructure_expected)} infrastructure choices match"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
