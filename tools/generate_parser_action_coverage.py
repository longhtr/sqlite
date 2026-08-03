#!/usr/bin/env python3
"""Generate or verify the canonical Lemon typed action-contract ledger.

A contract records local semantic-union flow and an owner interface. It is
parser scaffolding, not evidence that SQLite's concrete semantic action,
side-effects, cleanup, or compiler integration is implemented.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PARSER_MANIFEST = ROOT / "generated/parser/sqlite-parser-manifest.json"
PARSER_ZIG = ROOT / "src/core/parser.zig"
OUTPUT = ROOT / "upstream/parser-action-coverage.json"

CONTRACT_RULES = set(range(348))


def generate() -> dict:
    manifest = json.loads(PARSER_MANIFEST.read_text())
    source = PARSER_ZIG.read_text()
    count_match = re.search(r"pub const typed_action_contract_rule_count: u16 = (\d+);", source)
    if count_match is None or int(count_match.group(1)) != len(CONTRACT_RULES):
        raise SystemExit("parser-action-coverage: parser action-contract count mismatch")

    action_rules = [rule for rule in manifest["rules"] if rule["semantic_action"] is not None]
    if len(action_rules) != manifest["counts"]["semantic_action_rules"]:
        raise SystemExit("parser-action-coverage: semantic-action manifest count mismatch")
    if {rule["id"] for rule in action_rules} != set(range(len(action_rules))):
        raise SystemExit("parser-action-coverage: action rules are no longer the canonical leading partition")
    if not CONTRACT_RULES <= {rule["id"] for rule in action_rules}:
        raise SystemExit("parser-action-coverage: contract rule absent from canonical actions")

    entries = []
    for rule in action_rules:
        contracted = rule["id"] in CONTRACT_RULES
        entries.append({
            "rule_id": rule["id"],
            "identity": rule["identity"],
            "text": rule["text"],
            "source_line": rule["semantic_action"]["source_line"],
            "generated_action_sha256": rule["semantic_action"]["generated_action_sha256"],
            "status": "typed-local-flow-contract" if contracted else "missing-typed-contract",
            "implementation_credit": False,
            "fidelity_claim": False,
            "evidence": [
                "src/core/parser.zig",
                "src/core/parser.zig unit tests",
            ] if contracted else [],
        })

    return {
        "schema_version": 2,
        "sqlite_checkin": manifest["sqlite_checkin"],
        "grammar": manifest["grammar"],
        "scope": "typed local semantic-value flow and owner contracts only",
        "warning": "Action contracts are scaffolding and grant no source-translation, integration, or fidelity credit. Concrete SQLite owners, exact side effects/error/OOM/cleanup, resolver/compiler execution, and broad native evidence remain required.",
        "summary": {
            "canonical_semantic_action_rules": len(action_rules),
            "typed_local_flow_contract_rules": len(CONTRACT_RULES),
            "semantic_action_rules_without_typed_contract": len(action_rules) - len(CONTRACT_RULES),
            "source_translated_action_rules": 0,
            "subsystem_integrated_action_rules": 0,
        },
        "actions": entries,
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
                "parser-action-coverage: ledger is stale; "
                "run tools/generate_parser_action_coverage.py"
            )
        summary = report["summary"]
        print(
            "parser-action-coverage: verified "
            f"{summary['typed_local_flow_contract_rules']}/"
            f"{summary['canonical_semantic_action_rules']} typed local-flow contracts "
            "(scaffolding; 0 integrated)"
        )
        return
    OUTPUT.write_text(rendered)
    print(f"parser-action-coverage: wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
