#!/usr/bin/env python3
"""Structural checks for the normative porting documents."""

from __future__ import annotations

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
REQUIRED = [
    "README.md",
    "PORTING_CHARTER.md",
    "ENGINEERING_PROCESS.md",
    "CURRENT_STATE.md",
    "EXECUTION_PLAN.md",
    "RISK_REGISTER.md",
    "SCOPE.md",
    "THREAT_MODEL.md",
    "COMPATIBILITY.md",
    "ARCHITECTURE.md",
    "HYBRID_BOUNDARIES.md",
    "DURABILITY_MODEL.md",
    "PORTING_RULES.md",
    "TESTING.md",
    "UPSTREAM_SYNC.md",
]


def anchor(title: str) -> str:
    title = title.lower().replace("“", "").replace("”", "").replace("`", "")
    return re.sub(r"[^a-z0-9 _-]", "", title).replace(" ", "-")


def main() -> None:
    for name in REQUIRED:
        path = ROOT / "docs" / name
        if not path.is_file() or not path.read_text().strip():
            raise SystemExit(f"verify-docs: missing or empty docs/{name}")

    excluded_parts = {"upstream", ".reference-build", ".zig-cache", "zig-out", ".git"}
    maintained_paths = sorted(
        path for path in ROOT.rglob("*.md")
        if not any(part in excluded_parts for part in path.relative_to(ROOT).parts)
    )
    maintained_documents = {str(path.relative_to(ROOT)) for path in maintained_paths}
    for path in maintained_paths:
        lines = path.read_text().splitlines()
        inside_fence = False
        headings: set[str] = set()
        for line in lines:
            if line.startswith("```"):
                inside_fence = not inside_fence
                continue
            if not inside_fence and (match := re.match(r"^#{1,6} (.*)$", line)):
                headings.add(anchor(match.group(1)))
        if inside_fence:
            raise SystemExit(f"verify-docs: unbalanced Markdown code fence in {path.relative_to(ROOT)}")
        for line in lines:
            for target in re.findall(r"\]\(#([^)]+)\)", line):
                if target not in headings:
                    raise SystemExit(f"verify-docs: missing TOC target #{target} in {path.relative_to(ROOT)}")
        if any(line.rstrip() != line for line in lines):
            raise SystemExit(f"verify-docs: trailing whitespace in {path.relative_to(ROOT)}")

    inventory_path = ROOT / "docs/README.md"
    inventory_targets = set(re.findall(r"`([^`]+\.md)`", inventory_path.read_text()))
    if inventory_targets != maintained_documents:
        missing = sorted(maintained_documents - inventory_targets)
        stale = sorted(inventory_targets - maintained_documents)
        raise SystemExit(f"verify-docs: document inventory mismatch; missing={missing} stale={stale}")

    charter = (ROOT / "docs/PORTING_CHARTER.md").read_text()
    scope = (ROOT / "docs/SCOPE.md").read_text()
    process = (ROOT / "docs/ENGINEERING_PROCESS.md").read_text()
    plan = (ROOT / "docs/EXECUTION_PLAN.md").read_text()
    adr = ROOT / "docs/decisions/ADR-0040-pure-zig-product.md"
    process_adr = ROOT / "docs/decisions/ADR-0041-source-faithful-gates.md"
    if "source-faithful native Zig port" not in charter or "Production engine modules and artifacts contain only Zig" not in scope:
        raise SystemExit("verify-docs: pure-Zig product charter is missing")
    if "dependency-closed atomic source units" not in process or "Mandatory worker containment" not in process:
        raise SystemExit("verify-docs: enforceable source-fidelity process gates are missing")
    if "Stage 6 — complete Zig-native public API" not in plan:
        raise SystemExit("verify-docs: execution plan still lacks the Zig-native API stage")
    if not adr.is_file() or "Accepted" not in adr.read_text():
        raise SystemExit("verify-docs: missing accepted pure-Zig product ADR")
    if not process_adr.is_file() or "Accepted" not in process_adr.read_text():
        raise SystemExit("verify-docs: missing accepted atomic source-fidelity process ADR")
    forbidden = {
        ROOT / "docs/SCOPE.md": "Static and shared Linux libraries with the pinned",
        ROOT / "docs/PORTING_RULES.md": "C in native artifacts may unpack ABI arguments",
        ROOT / "docs/EXECUTION_PLAN.md": "complete public API and extension ABI",
    }
    for path, text in forbidden.items():
        if text in path.read_text():
            raise SystemExit(f"verify-docs: stale C ABI product requirement in {path.relative_to(ROOT)}")

    for path in ROOT.glob("**/*.json"):
        if any(part in {".zig-cache", "zig-out", ".reference-build"} for part in path.parts):
            continue
        json.loads(path.read_text())

    status = json.loads((ROOT / "upstream/port-status.json").read_text())
    source = status["source"]
    implementation = status["implementation"]
    engineering = status["engineering_process"]
    parser_contracts = json.loads((ROOT / "upstream/parser-action-coverage.json").read_text())["summary"]
    opcode_scaffold = json.loads((ROOT / "upstream/vdbe-opcode-coverage.json").read_text())["summary"]
    synchronized_facts = {
        f"{source['active_profile_entities']:,} active": [ROOT / "docs/CURRENT_STATE.md", ROOT / "docs/COMPATIBILITY.md"],
        f"{source['active_entities_context_reviewed_or_later']:,}": [ROOT / "docs/CURRENT_STATE.md", ROOT / "docs/COMPATIBILITY.md"],
        f"{source['active_entities_fidelity_reviewed']:,} fidelity-reviewed": [ROOT / "docs/COMPATIBILITY.md"],
        f"{source['active_entities_unmapped']:,}": [ROOT / "docs/CURRENT_STATE.md", ROOT / "docs/RISK_REGISTER.md"],
        f"{implementation['source_faithful_internal_layouts_total']}": [ROOT / "docs/CURRENT_STATE.md"],
        f"{opcode_scaffold['canonical_execution_cases_with_bounded_runtime_mapping']}/{opcode_scaffold['canonical_execution_cases']}": [ROOT / "docs/CURRENT_STATE.md", ROOT / "docs/COMPATIBILITY.md", ROOT / "docs/ARCHITECTURE.md"],
        f"{parser_contracts['typed_local_flow_contract_rules']}/{parser_contracts['canonical_semantic_action_rules']}": [ROOT / "docs/CURRENT_STATE.md", ROOT / "docs/COMPATIBILITY.md"],
        f"{engineering['purposeful_python_tool_scripts']} purposeful Python": [ROOT / "docs/CURRENT_STATE.md"],
        f"{source['behavioral_blocks_inventoried']:,}": [ROOT / "docs/CURRENT_STATE.md", ROOT / "docs/decisions/ADR-0041-source-faithful-gates.md"],
        f"{source['behavioral_functions_inventoried']:,} functions": [ROOT / "docs/CURRENT_STATE.md"],
        f"Atomic-unit dossiers total | {source['atomic_unit_dossiers_total']}": [ROOT / "docs/CURRENT_STATE.md"],
        f"Admission-ready dossiers | {source['atomic_unit_dossiers_admission_ready']}": [ROOT / "docs/CURRENT_STATE.md"],
    }
    for fact, paths in synchronized_facts.items():
        for path in paths:
            if fact not in path.read_text():
                raise SystemExit(f"verify-docs: synchronized fact {fact!r} missing from {path.relative_to(ROOT)}")
    if parser_contracts["subsystem_integrated_action_rules"] != 0 or opcode_scaffold["subsystem_integrated_execution_cases"] != 0:
        raise SystemExit("verify-docs: scaffold ledgers unexpectedly grant integration credit")
    if source["reviewed_coverage_is_completion_metric"]:
        raise SystemExit("verify-docs: reviewed coverage must never be a completion metric")
    if "Do not headline percentages or scaffold counts" not in process:
        raise SystemExit("verify-docs: engineering process lacks the execution-focused report contract")

    boundary = json.loads((ROOT / "upstream/native-c-boundary.json").read_text())
    if boundary["required_end_state"]["production_c_objects"] != 0:
        raise SystemExit("verify-docs: production C-object target is not zero")
    print(f"verify-docs: {len(maintained_documents)} maintained documents and {len(REQUIRED)} required controls OK")


if __name__ == "__main__":
    main()
