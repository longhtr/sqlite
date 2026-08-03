#!/usr/bin/env python3
"""Generate native Zig Lemon tables from the pinned SQLite parser output."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PARSE_C = ROOT / "generated/parser/sqlite_parse.c"
PARSER_MANIFEST = ROOT / "generated/parser/sqlite-parser-manifest.json"
OUTPUT = ROOT / "src/core/generated/parser_tables.zig"
MANIFEST = ROOT / "generated/parser/zig-tables-manifest.json"


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def c_array(source: str, name: str) -> list[int]:
    match = re.search(
        rf"static const [^\n]+\s+{re.escape(name)}\[\]\s*=\s*\{{(.*?)\n\}};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise SystemExit(f"parser array not found: {name}")
    body = re.sub(r"/\*.*?\*/", "", match.group(1), flags=re.DOTALL)
    return [int(value, 0) for value in re.findall(r"-?0x[0-9a-fA-F]+|-?\d+", body)]


def define(source: str, name: str) -> int:
    match = re.search(rf"^#define\s+{re.escape(name)}\s+\(?(-?\d+)\)?", source, re.MULTILINE)
    if match is None:
        raise SystemExit(f"parser define not found: {name}")
    return int(match.group(1))


def destructor_kinds(source: str, symbol_count: int) -> list[str]:
    match = re.search(
        r"/\*+ Begin destructor definitions \*+/(.*?)/\*+ End destructor definitions \*+/",
        source,
        re.DOTALL,
    )
    if match is None:
        raise SystemExit("parser destructor definitions not found")
    result = ["none"] * symbol_count
    blocks = re.findall(r"((?:\s*case\s+\d+:[^\n]*\n)+)\s*\{(.*?)\}\s*break;", match.group(1), re.DOTALL)
    classifiers = {
        "sqlite3SelectDelete": "select",
        "sqlite3ExprListDelete": "expr_list",
        "sqlite3SrcListDelete": "src_list",
        "sqlite3WithDelete": "with",
        "sqlite3WindowListDelete": "window_list",
        "sqlite3WindowDelete": "window",
        "sqlite3DeleteTriggerStep": "trigger_step",
    }
    for cases, body in blocks:
        if "sqlite3ExprDelete" in body:
            kind = "frame_bound_expr" if ".pExpr" in body else "expr"
        elif "sqlite3IdListDelete" in body:
            kind = "trigger_event_id_list" if ").b" in body else "id_list"
        else:
            found = [kind for call, kind in classifiers.items() if call in body]
            if len(found) != 1:
                raise SystemExit(f"unclassified parser destructor body: {body.strip()}")
            kind = found[0]
        for value in re.findall(r"case\s+(\d+):", cases):
            symbol = int(value)
            if symbol >= symbol_count or result[symbol] != "none":
                raise SystemExit(f"invalid duplicate parser destructor symbol: {symbol}")
            result[symbol] = kind
    if all(kind == "none" for kind in result):
        raise SystemExit("no parser destructors extracted")
    return result


def emit_array(lines: list[str], name: str, zig_type: str, values: list[int], width: int = 1) -> None:
    lines.append(f"pub const {name} = [_]{zig_type}{{")
    for index in range(0, len(values), width):
        lines.append("    " + ", ".join(str(value) for value in values[index:index + width]) + ",")
    lines += ["};", ""]


def generate() -> tuple[str, dict]:
    parse_bytes = PARSE_C.read_bytes()
    source = parse_bytes.decode()
    parser_manifest = json.loads(PARSER_MANIFEST.read_text())

    constants = {
        "no_code": define(source, "YYNOCODE"),
        "wildcard": define(source, "YYWILDCARD"),
        "state_count": define(source, "YYNSTATE"),
        "rule_count": define(source, "YYNRULE"),
        "rules_with_actions": define(source, "YYNRULE_WITH_ACTION"),
        "terminal_count": define(source, "YYNTOKEN"),
        "max_shift": define(source, "YY_MAX_SHIFT"),
        "min_shift_reduce": define(source, "YY_MIN_SHIFTREDUCE"),
        "max_shift_reduce": define(source, "YY_MAX_SHIFTREDUCE"),
        "error_action": define(source, "YY_ERROR_ACTION"),
        "accept_action": define(source, "YY_ACCEPT_ACTION"),
        "no_action": define(source, "YY_NO_ACTION"),
        "min_reduce": define(source, "YY_MIN_REDUCE"),
        "max_reduce": define(source, "YY_MAX_REDUCE"),
        "action_table_count": define(source, "YY_ACTTAB_COUNT"),
        "shift_count": define(source, "YY_SHIFT_COUNT"),
        "reduce_count": define(source, "YY_REDUCE_COUNT"),
    }
    arrays = {
        "actions": c_array(source, "yy_action"),
        "lookaheads": c_array(source, "yy_lookahead"),
        "shift_offsets": c_array(source, "yy_shift_ofst"),
        "reduce_offsets": c_array(source, "yy_reduce_ofst"),
        "defaults": c_array(source, "yy_default"),
        "fallbacks": c_array(source, "yyFallback"),
        "rule_lhs": c_array(source, "yyRuleInfoLhs"),
        "rule_rhs": c_array(source, "yyRuleInfoNRhs"),
    }
    expected_lengths = {
        "actions": constants["action_table_count"],
        "lookaheads": constants["action_table_count"] + constants["terminal_count"],
        "shift_offsets": constants["shift_count"] + 1,
        "reduce_offsets": constants["reduce_count"] + 1,
        "defaults": constants["state_count"],
        "fallbacks": constants["terminal_count"],
        "rule_lhs": constants["rule_count"],
        "rule_rhs": constants["rule_count"],
    }
    for name, expected in expected_lengths.items():
        if len(arrays[name]) != expected:
            raise SystemExit(f"{name} length {len(arrays[name])} != {expected}")

    symbols = parser_manifest["symbols"]
    rules = parser_manifest["rules"]
    destructors = destructor_kinds(source, constants["no_code"])
    if len(symbols) != constants["no_code"] or len(rules) != constants["rule_count"]:
        raise SystemExit("parser manifest symbol/rule count mismatch")
    rhs_counts = [
        max((item["position"] for item in rule["rhs"]), default=-1) + 1
        for rule in rules
    ]
    if arrays["rule_lhs"] != [rule["lhs_id"] for rule in rules]:
        raise SystemExit("rule LHS metadata differs from parser manifest")
    if arrays["rule_rhs"] != [-count for count in rhs_counts]:
        raise SystemExit("rule RHS metadata differs from parser manifest")

    lines = [
        "//! Generated from the pinned SQLite Lemon parser. Do not edit.",
        "",
    ]
    for name, value in constants.items():
        lines.append(f"pub const {name}: u16 = {value};")
    lines += [
        "",
        "pub const symbol_names = [_][]const u8{",
    ]
    for symbol in symbols:
        lines.append(f"    {json.dumps(symbol['name'])},")
    lines += [
        "};",
        "",
        "pub const DestructorKind = enum {",
        "    none,",
        "    select,",
        "    expr,",
        "    expr_list,",
        "    src_list,",
        "    with,",
        "    window_list,",
        "    id_list,",
        "    window,",
        "    trigger_step,",
        "    trigger_event_id_list,",
        "    frame_bound_expr,",
        "};",
        "",
        "pub const destructors = [_]DestructorKind{",
    ]
    for kind in destructors:
        lines.append(f"    .{kind},")
    lines += ["};", "", "pub const Rule = struct {", "    lhs: u16,", "    rhs_count: u8,", "    has_action: bool,", "};", "", "pub const rules = [_]Rule{"]
    for rule, rhs_count in zip(rules, rhs_counts, strict=True):
        lines.append(
            f"    .{{ .lhs = {rule['lhs_id']}, .rhs_count = {rhs_count}, "
            f".has_action = {'true' if rule['semantic_action'] is not None else 'false'} }},"
        )
    lines += ["};", ""]
    emit_array(lines, "actions", "u16", arrays["actions"])
    emit_array(lines, "lookaheads", "u16", arrays["lookaheads"])
    emit_array(lines, "shift_offsets", "u16", arrays["shift_offsets"])
    emit_array(lines, "reduce_offsets", "i16", arrays["reduce_offsets"])
    emit_array(lines, "defaults", "u16", arrays["defaults"])
    emit_array(lines, "fallbacks", "u16", arrays["fallbacks"])

    lines += [
        "pub fn shiftAction(state: u16, initial_lookahead: u16) u16 {",
        "    if (state > max_shift) return state;",
        "    std.debug.assert(state <= shift_count);",
        "    std.debug.assert(initial_lookahead < terminal_count);",
        "    var lookahead = initial_lookahead;",
        "    while (true) {",
        "        const offset: usize = shift_offsets[state];",
        "        const index = offset + @as(usize, lookahead);",
        "        std.debug.assert(index < lookaheads.len);",
        "        if (lookaheads[index] == lookahead) return actions[index];",
        "        const fallback = fallbacks[lookahead];",
        "        if (fallback != 0) {",
        "            std.debug.assert(fallbacks[fallback] == 0);",
        "            lookahead = fallback;",
        "            continue;",
        "        }",
        "        const wildcard_index = offset + @as(usize, wildcard);",
        "        if (lookahead > 0 and lookaheads[wildcard_index] == wildcard) return actions[wildcard_index];",
        "        return defaults[state];",
        "    }",
        "}",
        "",
        "pub fn reduceAction(state: u16, lookahead: u16) u16 {",
        "    std.debug.assert(state <= reduce_count);",
        "    std.debug.assert(lookahead < no_code);",
        "    const index = @as(i32, reduce_offsets[state]) + @as(i32, lookahead);",
        "    std.debug.assert(index >= 0 and index < action_table_count);",
        "    std.debug.assert(lookaheads[@intCast(index)] == lookahead);",
        "    return actions[@intCast(index)];",
        "}",
        "",
        "const std = @import(\"std\");",
        "comptime {",
        "    if (actions.len != action_table_count or lookaheads.len != action_table_count + terminal_count) @compileError(\"parser action table size mismatch\");",
        "    if (shift_offsets.len != shift_count + 1) @compileError(\"parser shift table size mismatch\");",
        "    if (reduce_offsets.len != reduce_count + 1) @compileError(\"parser reduce table size mismatch\");",
        "    if (defaults.len != state_count or fallbacks.len != terminal_count) @compileError(\"parser state table size mismatch\");",
        "    if (rules.len != rule_count or symbol_names.len != no_code or destructors.len != no_code) @compileError(\"parser metadata size mismatch\");",
        "}",
        "",
    ]
    rendered = "\n".join(lines)
    rendered_bytes = rendered.encode()
    manifest = {
        "schema_version": 1,
        "sqlite_checkin": parser_manifest["sqlite_checkin"],
        "input": "generated/parser/sqlite_parse.c",
        "input_sha256": sha256(parse_bytes),
        "metadata_input": "generated/parser/sqlite-parser-manifest.json",
        "metadata_input_sha256": sha256(PARSER_MANIFEST.read_bytes()),
        "output": "src/core/generated/parser_tables.zig",
        "output_sha256": sha256(rendered_bytes),
        "counts": {
            **constants,
            **{f"{name}_length": len(value) for name, value in arrays.items()},
            "symbols": len(symbols),
            "semantic_actions": sum(rule["semantic_action"] is not None for rule in rules),
            "symbols_with_destructors": sum(kind != "none" for kind in destructors),
            "destructors_by_kind": {kind: destructors.count(kind) for kind in sorted(set(destructors))},
        },
    }
    return rendered, manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered, manifest = generate()
    manifest_text = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
            raise SystemExit("native parser tables are stale; run tools/generate_parser_tables.py")
        if not MANIFEST.is_file() or MANIFEST.read_text() != manifest_text:
            raise SystemExit("native parser table manifest is stale; run tools/generate_parser_tables.py")
        print("parser-tables: verified canonical Lemon tables and rule metadata")
        return
    OUTPUT.write_text(rendered)
    MANIFEST.write_text(manifest_text)
    print("parser-tables: generated canonical Lemon tables and rule metadata")


if __name__ == "__main__":
    main()
