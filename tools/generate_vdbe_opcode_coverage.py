#!/usr/bin/env python3
"""Generate or verify the canonical-to-bounded-runtime VDBE opcode ledger.

This ledger records name-level runtime coverage only. A mapping does not claim
source fidelity, complete operand semantics, or complete error/ownership paths.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANONICAL_ZIG = ROOT / "src/core/generated/opcodes.zig"
VDBE_ZIG = ROOT / "src/core/vdbe.zig"
VDBE_C = ROOT / "upstream/sqlite/src/vdbe.c"
OPCODE_MANIFEST = ROOT / "generated/opcodes/manifest.json"
OUTPUT = ROOT / "upstream/vdbe-opcode-coverage.json"

# Runtime spellings that cannot be obtained by mechanically converting the
# canonical CamelCase name to snake_case.
RUNTIME_ALIASES = {
    "And": "and_",
    "Compare": "compare_values",
    "If": "if_",
    "Null": "null_",
    "Or": "or_",
    "Return": "return_",
    "SCopy": "scopy",
    "VOpen": "open_virtual",
}

# These operations belong only to the bounded handwritten VM. They must not be
# counted as canonical SQLite execution cases.
TRANSITIONAL_RUNTIME = {
    "open_data": "opens a Program-owned in-memory table rather than a canonical SQLite cursor",
    "to_blob": "bounded convenience conversion; canonical SQLite emits Cast with blob affinity",
    "to_text": "bounded convenience conversion; canonical SQLite emits Cast with text affinity",
}


def snake_case(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def parse_canonical() -> list[tuple[str, int]]:
    values = [
        (name, int(value))
        for name, value in re.findall(
            r"^    ([A-Za-z][A-Za-z0-9]*) = (\d+),$",
            CANONICAL_ZIG.read_text(),
            re.MULTILINE,
        )
    ]
    if [value for _, value in values] != list(range(len(values))):
        raise SystemExit("vdbe-opcode-coverage: canonical opcode identities are not contiguous")
    return values


def parse_runtime() -> list[str]:
    source = VDBE_ZIG.read_text()
    match = re.search(r"pub const Opcode = enum \{(.*?)\n\};", source, re.DOTALL)
    if match is None:
        raise SystemExit("vdbe-opcode-coverage: bounded runtime Opcode enum not found")
    return re.findall(r"^    ([a-z][a-z0-9_]*),$", match.group(1), re.MULTILINE)


def generate() -> dict:
    canonical = parse_canonical()
    runtime = parse_runtime()
    runtime_set = set(runtime)
    if len(runtime_set) != len(runtime):
        raise SystemExit("vdbe-opcode-coverage: duplicate bounded runtime opcode")

    execution_cases = set(re.findall(r"case\s+OP_([A-Za-z0-9_]+)\s*:", VDBE_C.read_text()))
    canonical_names = {name for name, _ in canonical}
    if not execution_cases <= canonical_names:
        unknown = sorted(execution_cases - canonical_names)
        raise SystemExit(f"vdbe-opcode-coverage: unknown upstream execution cases: {unknown}")

    runtime_to_canonical: dict[str, str] = {}
    entries = []
    for name, number in canonical:
        runtime_name = RUNTIME_ALIASES.get(name, snake_case(name))
        mapped = runtime_name in runtime_set
        if mapped:
            if runtime_name in runtime_to_canonical:
                raise SystemExit(f"vdbe-opcode-coverage: duplicate runtime mapping: {runtime_name}")
            runtime_to_canonical[runtime_name] = name
        executes = name in execution_cases
        if executes and mapped:
            status = "bounded-runtime-mapped"
        elif executes:
            status = "unmapped-execution-case"
        elif mapped:
            status = "represented-non-execution-identity"
        else:
            status = "unrepresented-non-execution-identity"
        entries.append({
            "canonical_name": name,
            "number": number,
            "upstream_execution_case": executes,
            "bounded_runtime_opcode": runtime_name if mapped else None,
            "status": status,
            "implementation_credit": False,
            "fidelity_claim": False,
        })

    accounted_runtime = set(runtime_to_canonical) | set(TRANSITIONAL_RUNTIME)
    if accounted_runtime != runtime_set:
        missing = sorted(runtime_set - accounted_runtime)
        stale = sorted(accounted_runtime - runtime_set)
        raise SystemExit(
            "vdbe-opcode-coverage: runtime accounting mismatch; "
            f"unaccounted={missing}, stale={stale}"
        )

    mapped_execution = sum(
        entry["upstream_execution_case"] and entry["bounded_runtime_opcode"] is not None
        for entry in entries
    )
    mapped_non_execution = sum(
        not entry["upstream_execution_case"] and entry["bounded_runtime_opcode"] is not None
        for entry in entries
    )
    opcode_manifest = json.loads(OPCODE_MANIFEST.read_text())
    if len(canonical) != opcode_manifest["opcode_count"]:
        raise SystemExit("vdbe-opcode-coverage: canonical manifest count mismatch")
    if len(execution_cases) != opcode_manifest["execution_case_count"]:
        raise SystemExit("vdbe-opcode-coverage: execution-case manifest count mismatch")

    return {
        "schema_version": 1,
        "sqlite_checkin": opcode_manifest["sqlite_checkin"],
        "scope": "canonical opcode identity to bounded handwritten Zig runtime name mapping",
        "warning": "A mapped case proves name-level runtime presence only, not complete SQLite semantics or fidelity.",
        "summary": {
            "canonical_opcode_identities": len(canonical),
            "canonical_execution_cases": len(execution_cases),
            "canonical_non_execution_identities": len(canonical) - len(execution_cases),
            "canonical_execution_cases_with_bounded_runtime_mapping": mapped_execution,
            "canonical_execution_cases_without_bounded_runtime_mapping": len(execution_cases) - mapped_execution,
            "canonical_non_execution_identities_represented": mapped_non_execution,
            "bounded_runtime_opcodes": len(runtime),
            "bounded_runtime_opcodes_mapped_to_canonical_execution_cases": mapped_execution,
            "bounded_runtime_opcodes_mapped_to_non_execution_identities": mapped_non_execution,
            "transitional_runtime_only_opcodes": len(TRANSITIONAL_RUNTIME),
            "source_translated_execution_cases": 0,
            "subsystem_integrated_execution_cases": 0,
        },
        "transitional_runtime_opcodes": [
            {"runtime_opcode": name, "reason": TRANSITIONAL_RUNTIME[name]}
            for name in sorted(TRANSITIONAL_RUNTIME)
        ],
        "opcodes": entries,
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
                "vdbe-opcode-coverage: ledger is stale; "
                "run tools/generate_vdbe_opcode_coverage.py"
            )
        summary = report["summary"]
        print(
            "vdbe-opcode-coverage: verified "
            f"{summary['canonical_execution_cases_with_bounded_runtime_mapping']}/"
            f"{summary['canonical_execution_cases']} bounded runtime name mappings "
            "(scaffolding; 0 integrated)"
        )
        return
    OUTPUT.write_text(rendered)
    print(f"vdbe-opcode-coverage: wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
