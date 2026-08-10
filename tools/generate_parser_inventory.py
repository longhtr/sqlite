#!/usr/bin/env python3
"""Generate rule/symbol/action identities for the pinned SQLite Lemon grammar."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sqlite3

ROOT = pathlib.Path(__file__).resolve().parent.parent
GENERATED = ROOT / "generated/parser"
GRAMMAR = ROOT / "upstream/sqlite/src/parse.y"
PARSER_C = GENERATED / "sqlite_parse.c"
PARSER_H = GENERATED / "sqlite_parse.h"
PARSER_SQL = GENERATED / "sqlite_parse.sql"
OUTPUT = GENERATED / "sqlite-parser-manifest.json"


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def action_map(text: str) -> dict[int, dict[str, object]]:
    begin = text.index("/********** Begin reduce actions")
    end = text.index("/********** End reduce actions", begin)
    lines = text[begin:end].splitlines()
    result: dict[int, dict[str, object]] = {}
    pending: list[int] = []
    case_re = re.compile(r"^\s*case\s+(\d+):\s*/\*")
    source_re = re.compile(r'^#line\s+(\d+)\s+"parse\.y"')
    generated_re = re.compile(r'^#line\s+\d+\s+"parse\.c"')
    index = 0
    while index < len(lines):
        case = case_re.match(lines[index])
        if case:
            pending.append(int(case.group(1)))
            index += 1
            continue
        source = source_re.match(lines[index])
        if source and pending:
            action_line = int(source.group(1))
            code: list[str] = []
            index += 1
            while index < len(lines) and not generated_re.match(lines[index]):
                code.append(lines[index])
                index += 1
            normalized = "\n".join(line.rstrip() for line in code).strip() + "\n"
            fact = {
                "source_line": action_line,
                "generated_action_sha256": hashlib.sha256(normalized.encode()).hexdigest(),
            }
            for rule_id in pending:
                if rule_id in result:
                    raise SystemExit(f"duplicate semantic action for rule {rule_id}")
                result[rule_id] = fact
            pending.clear()
            continue
        index += 1
    return result


def parser_constant(text: str, name: str) -> int:
    match = re.search(rf"^#define\s+{name}\s+(\d+)", text, re.MULTILINE)
    if match is None:
        raise SystemExit(f"missing generated parser constant {name}")
    return int(match.group(1))


def main() -> None:
    database = sqlite3.connect(":memory:")
    database.executescript(PARSER_SQL.read_text())
    parser_text = PARSER_C.read_text()
    actions = action_map(parser_text)

    symbols = []
    symbol_by_id: dict[int, dict[str, object]] = {}
    for symbol_id, name, terminal, fallback in database.execute(
        "SELECT id,name,isTerminal,fallback FROM symbol ORDER BY id"
    ):
        item = {
            "id": symbol_id,
            "name": name,
            "terminal": bool(terminal),
            "fallback_id": fallback,
        }
        symbols.append(item)
        symbol_by_id[symbol_id] = item

    rhs_by_rule: dict[int, list[dict[str, object]]] = {}
    for rule_id, position, symbol_id in database.execute(
        "SELECT ruleid,pos,sym FROM rulerhs ORDER BY ruleid,pos,rowid"
    ):
        symbol = symbol_by_id[symbol_id]
        rhs_by_rule.setdefault(rule_id, []).append({
            "position": position,
            "symbol_id": symbol_id,
            "symbol": symbol["name"],
        })

    rules = []
    for rule_id, lhs_id, text in database.execute(
        "SELECT ruleid,lhs,txt FROM rule ORDER BY ruleid"
    ):
        action = actions.get(rule_id)
        rules.append({
            "id": rule_id,
            "identity": f"src/parse.y::rule::{rule_id}::{text}",
            "text": text,
            "lhs_id": lhs_id,
            "lhs": symbol_by_id[lhs_id]["name"],
            "rhs": rhs_by_rule.get(rule_id, []),
            "semantic_action": action,
        })

    if len(rules) != parser_constant(parser_text, "YYNRULE"):
        raise SystemExit("Lemon SQL rule count differs from generated parser")
    if set(actions) - {rule["id"] for rule in rules}:
        raise SystemExit("generated semantic action references unknown rule")

    manifest = {
        "schema_version": 1,
        "sqlite_checkin": "bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc",
        "profile": "sqlite-3.53.4-core-default-threadsafe1",
        "generator": {
            "source": "upstream/sqlite/tool/lemon.c",
            "source_sha256": sha256(ROOT / "upstream/sqlite/tool/lemon.c"),
            "template": "upstream/sqlite/tool/lempar.c",
            "template_sha256": sha256(ROOT / "upstream/sqlite/tool/lempar.c"),
            "defines": [
                "SQLITE_ENABLE_MATH_FUNCTIONS",
                "SQLITE_ENABLE_PERCENTILE",
                "SQLITE_HAVE_ZLIB=1",
                "SQLITE_THREADSAFE=1",
            ],
        },
        "grammar": {
            "source": "upstream/sqlite/src/parse.y",
            "source_sha256": sha256(GRAMMAR),
        },
        "outputs": {
            "generated/parser/sqlite_parse.c": sha256(PARSER_C),
            "generated/parser/sqlite_parse.h": sha256(PARSER_H),
            "generated/parser/sqlite_parse.sql": sha256(PARSER_SQL),
        },
        "counts": {
            "states": parser_constant(parser_text, "YYNSTATE"),
            "rules": len(rules),
            "symbols": len(symbols),
            "terminals": sum(symbol["terminal"] for symbol in symbols),
            "semantic_action_rules": len(actions),
            "default_action_rules": len(rules) - len(actions),
        },
        "symbols": symbols,
        "rules": rules,
    }
    OUTPUT.write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        f"generated {OUTPUT.relative_to(ROOT)} with "
        f"{len(rules)} rules and {len(actions)} semantic-action mappings"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
