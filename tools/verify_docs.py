#!/usr/bin/env python3
"""Validate documentation ownership, references, commands, and synchronized facts."""

from __future__ import annotations

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
REQUIRED = {
    "README.md",
    "PORTING_CHARTER.md",
    "ENGINEERING_PROCESS.md",
    "CURRENT_STATE.md",
    "EXECUTION_PLAN.md",
    "RISK_REGISTER.md",
    "SCOPE.md",
    "THREAT_MODEL.md",
    "ARCHITECTURE.md",
    "DURABILITY_MODEL.md",
    "TESTING.md",
    "UPSTREAM_SYNC.md",
}
EXCLUDED_PARTS = {"upstream", ".reference-build", ".zig-cache", "zig-out", ".git"}
REMOVED_DOCUMENTS = {"docs/COMPATIBILITY.md", "docs/HYBRID_BOUNDARIES.md", "docs/PORTING_RULES.md"}


def load_json(path: pathlib.Path) -> dict[str, object]:
    """Load an object-root JSON file while rejecting duplicate keys."""
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise SystemExit(
                    f"verify-docs: duplicate JSON key {key!r} in {path.relative_to(ROOT)}"
                )
            result[key] = value
        return result

    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    if not isinstance(data, dict):
        raise SystemExit(f"verify-docs: expected JSON object in {path.relative_to(ROOT)}")
    return data


def anchor(title: str) -> str:
    title = title.lower().replace("“", "").replace("”", "").replace("`", "")
    return re.sub(r"[^a-z0-9 _-]", "", title).replace(" ", "-")


def maintained_paths() -> list[pathlib.Path]:
    return sorted(
        path
        for path in ROOT.rglob("*.md")
        if path.name != "AGENTS.md"
        and not any(part in EXCLUDED_PARTS for part in path.relative_to(ROOT).parts)
    )


def verify_markdown(path: pathlib.Path) -> None:
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
        raise SystemExit(f"verify-docs: unbalanced code fence in {path.relative_to(ROOT)}")
    if any(line.rstrip() != line for line in lines):
        raise SystemExit(f"verify-docs: trailing whitespace in {path.relative_to(ROOT)}")
    for line in lines:
        for target in re.findall(r"\]\(#([^)]+)\)", line):
            if target not in headings:
                raise SystemExit(f"verify-docs: missing anchor #{target} in {path.relative_to(ROOT)}")


def verify_inventory(paths: list[pathlib.Path]) -> None:
    inventory = (ROOT / "docs/README.md").read_text()
    maintained = {str(path.relative_to(ROOT)) for path in paths}
    rows = re.findall(r"^\| `([^`]+\.md)` \| ([^|]+) \|$", inventory, re.MULTILINE)
    row_targets = {target for target, _ in rows}
    purposes = [purpose.strip() for _, purpose in rows]
    if row_targets != maintained or len(rows) != len(maintained):
        raise SystemExit(
            "verify-docs: purpose-table inventory mismatch; "
            f"missing={sorted(maintained - row_targets)} stale={sorted(row_targets - maintained)}"
        )
    if len(purposes) != len(set(purposes)):
        raise SystemExit("verify-docs: document purposes must be non-duplicated")
    agents = (ROOT / "AGENTS.md").read_text()
    if "`docs/README.md` is the canonical documentation registry" not in agents:
        raise SystemExit("verify-docs: AGENTS.md does not reference the complete documentation registry")


def verify_local_references(paths: list[pathlib.Path]) -> None:
    for path in paths:
        text = path.read_text()
        for link in re.findall(r"\]\(([^)#]+)(?:#[^)]+)?\)", text):
            if "://" not in link and not (path.parent / link).resolve().exists():
                raise SystemExit(f"verify-docs: missing Markdown link {link!r} in {path.relative_to(ROOT)}")
        references = set(re.findall(r"`((?:config|docs|generated|reference|src|tests|tools|upstream)/[^`\s]+)`", text))
        for reference in references:
            cleaned = reference.rstrip(".,;:")
            if any(character in cleaned for character in "*?["):
                if not list(ROOT.glob(cleaned)):
                    raise SystemExit(f"verify-docs: unmatched path pattern {cleaned!r} in {path.relative_to(ROOT)}")
            elif not (ROOT / cleaned).exists():
                raise SystemExit(f"verify-docs: missing path {cleaned!r} in {path.relative_to(ROOT)}")


def verify_build_targets(paths: list[pathlib.Path]) -> int:
    build_text = (ROOT / "build.zig").read_text()
    targets = set(re.findall(r"\.step\(\"([^\"]+)\"", build_text))
    documented: set[str] = set()
    for path in paths:
        for command in re.findall(r"zig build\s+([^\n`]+)", path.read_text()):
            command = command.split("#", 1)[0]
            for token in command.split():
                if token.startswith("-"):
                    continue
                documented.add(token)
    missing = sorted(documented - targets)
    if missing:
        raise SystemExit(f"verify-docs: documented build targets do not exist: {missing}")
    required = {
        "test",
        "port-batch-audit",
        "port-batch-checkpoint",
        "atomic-unit-audit",
        "source-ledger",
        "port-audit",
        "verify-config",
        "docs-test",
        "tooling-audit",
        "test-upstream",
    }
    if not required <= documented:
        raise SystemExit(f"verify-docs: result ownership omits build targets {sorted(required - documented)}")
    return len(documented)


def verify_aggregate_result_graph() -> int:
    build = (ROOT / "build.zig").read_text()
    public_steps = re.findall(r'b\.step\("([^"]+)",\s*"([^"]+)"', build)
    names = [name for name, _ in public_steps]
    descriptions = [description for _, description in public_steps]
    if not public_steps or len(names) != len(set(names)) or len(descriptions) != len(set(descriptions)):
        raise SystemExit("verify-docs: build result targets need unique names and purposes")

    start = build.index('const test_step = b.step("test"')
    end = build.index("const report =", start)
    aggregate = build[start:end]
    dependencies = re.findall(r"test_step\.dependOn\(([^)]+)\);", aggregate)
    if not dependencies or len(dependencies) != len(set(dependencies)):
        raise SystemExit("verify-docs: aggregate test graph has missing or duplicate result dependencies")
    if "verify_config.step.dependOn(&port_audit.step);" not in build:
        raise SystemExit("verify-docs: configuration verification does not own status verification")
    if "test_step.dependOn(&port_audit.step);" in aggregate:
        raise SystemExit("verify-docs: aggregate repeats the status verifier already owned by verify-config")

    testing = (ROOT / "docs/TESTING.md").read_text()
    required = (
        "stdout is not a maintained artifact",
        "aggregate dependencies",
        "zig-out/compatibility-report.json",
        "disposable digest-backed output",
    )
    if any(item not in testing for item in required):
        raise SystemExit("verify-docs: aggregate or compatibility result ownership is not documented")
    return len(dependencies)


def verify_test_module_ownership() -> int:
    candidates = sorted(
        path
        for directory in (ROOT / "tests", ROOT / "reference")
        for extension in ("*.zig", "*.c")
        for path in directory.rglob(extension)
        if path.name not in {"sqlite3.c", "sqlite3-lines.c"}
    )
    owners = [ROOT / "build.zig", *sorted((ROOT / "tools").glob("*.py"))]
    owners += sorted((ROOT / "src").rglob("*.zig"))
    owners += candidates
    owner_text = {owner: owner.read_text(errors="replace") for owner in owners}
    for candidate in candidates:
        relative = candidate.relative_to(ROOT).as_posix()
        quoted_name = f'"{candidate.name}"'
        referenced = any(
            owner != candidate
            and (relative in owner_text[owner] or quoted_name in owner_text[owner])
            for owner in owners
        )
        if not referenced:
            raise SystemExit(f"verify-docs: test/oracle module lacks an invocation or importing owner: {relative}")
    return len(candidates)


def verify_result_artifacts() -> tuple[int, int]:
    baseline = dict(
        line.split("=", 1)
        for line in (ROOT / "upstream/SQLITE_BASELINE").read_text().splitlines()
        if "=" in line
    )
    config_verifier = (ROOT / "tools/verify_config.py").read_text()
    phase_paths = sorted((ROOT / "upstream").glob("phase*-manifest.json"))
    phase_ids: set[str] = set()
    for path in phase_paths:
        data = load_json(path)
        phase = data.get("phase")
        if not isinstance(phase, str) or phase in phase_ids:
            raise SystemExit(f"verify-docs: historical result has missing/duplicate purpose: {path.relative_to(ROOT)}")
        phase_ids.add(phase)
        if (
            data.get("baseline_checkin") != baseline["fossil_checkin"]
            or data.get("status") != "bounded-regression-evidence"
            or data.get("evidence_classification") != "bounded-regression-only"
            or data.get("project_completion_claim") is not False
            or data.get("completion_claim", False) is not False
        ):
            raise SystemExit(f"verify-docs: historical result boundary is stale: {path.relative_to(ROOT)}")
        if path.relative_to(ROOT).as_posix() not in config_verifier:
            raise SystemExit(f"verify-docs: historical result lacks a verification owner: {path.relative_to(ROOT)}")
        children = data.get("slices")
        if isinstance(children, list) and all(isinstance(item, str) and item.endswith(".json") for item in children):
            child_data = [load_json(path.parent / item) for item in children]
            mapped = sum(item.get("mapped_entity_count", 0) for item in child_data)
            if mapped != data.get("mapped_entity_count"):
                raise SystemExit(f"verify-docs: aggregate result total is stale: {path.relative_to(ROOT)}")

    build = (ROOT / "build.zig").read_text()
    fixture_paths = sorted((ROOT / "tests/fixtures").glob("*/manifest.json"))
    fixture_purposes: set[str] = set()
    for path in fixture_paths:
        data = load_json(path)
        purpose = data.get("profile") or data.get("phase")
        if not isinstance(purpose, str) or purpose in fixture_purposes:
            raise SystemExit(f"verify-docs: fixture manifest has missing/duplicate purpose: {path.relative_to(ROOT)}")
        fixture_purposes.add(purpose)
        tool_name = f"generate_{path.parent.name.replace('-', '_')}_fixtures.py"
        tool = ROOT / "tools" / tool_name
        if not tool.is_file() or tool_name not in build:
            raise SystemExit(f"verify-docs: fixture manifest lacks a build-owned generator: {path.relative_to(ROOT)}")
    return len(phase_paths), len(fixture_paths)


def verify_policy_and_facts(paths: list[pathlib.Path]) -> None:
    all_text = "\n".join(path.read_text() for path in paths)
    for removed in REMOVED_DOCUMENTS:
        if removed in all_text or removed in (ROOT / "AGENTS.md").read_text():
            raise SystemExit(f"verify-docs: stale consolidated document reference {removed}")
    normative = [ROOT / "CONTRIBUTING.md", *(ROOT / "docs" / name for name in REQUIRED)]
    for path in normative:
        text = path.read_text()
        if "fidelity-closure review" in text or "Independent fidelity review is required" in text:
            raise SystemExit(f"verify-docs: deferred review revived in {path.relative_to(ROOT)}")

    charter = (ROOT / "docs/PORTING_CHARTER.md").read_text()
    scope = (ROOT / "docs/SCOPE.md").read_text()
    process = (ROOT / "docs/ENGINEERING_PROCESS.md").read_text()
    plan = (ROOT / "docs/EXECUTION_PLAN.md").read_text()
    if "source-faithful native Zig core" not in charter or "Production engine modules and artifacts contain only Zig" not in scope:
        raise SystemExit("verify-docs: pure-Zig source-faithful charter is missing")
    if "dependency-closed source unit" not in process or "Every oracle, native worker" not in process:
        raise SystemExit("verify-docs: source or containment gate is missing")
    if "Work package 8 — built-ins and Zig API" not in plan:
        raise SystemExit("verify-docs: Zig-native API work package is missing")

    status = load_json(ROOT / "upstream/port-status.json")
    source = status["source"]
    tracking = status["translation_tracking"]
    implementation = status["implementation"]
    engineering = status["engineering_process"]
    parser_data = load_json(ROOT / "upstream/parser-action-coverage.json")
    opcode_data = load_json(ROOT / "upstream/vdbe-opcode-coverage.json")
    parser = parser_data["summary"]
    opcode = opcode_data["summary"]
    current = (ROOT / "docs/CURRENT_STATE.md").read_text()
    facts = {
        f"| Active source entities | {source['active_profile_entities']:,} active |": current,
        f"| Historical reviewed-or-later classifications | {source['active_entities_context_reviewed_or_later']:,} |": current,
        f"| Inventoried, unpromoted entities | {source['active_entities_inventoried']:,} |": current,
        f"| Unmapped entities | {source['active_entities_unmapped']:,} |": current,
        f"| Behavioral inventory | {source['behavioral_blocks_inventoried']:,} blocks in {source['behavioral_functions_inventoried']:,} functions |": current,
        f"| Atomic-unit dossiers total | {source['atomic_unit_dossiers_total']} |": current,
        f"| Admission-ready dossiers | {source['atomic_unit_dossiers_admission_ready']} |": current,
        f"| Historical mechanical function claims | {tracking['historical_mechanical_claims']:,}; {tracking['completion_credit']} completion credit |": current,
        f"| Active batch and durable checkpoints | {tracking['active_batch_entries']} entries; {tracking['durable_checkpoints']} checkpoints |": current,
        f"| Exact internal layouts | {implementation['source_faithful_internal_layouts_total']} |": current,
        f"| Purposeful tools | {engineering['purposeful_python_tool_scripts']} purposeful Python scripts |": current,
        f"| Bounded opcode mappings | {opcode['canonical_execution_cases_with_bounded_runtime_mapping']}/{opcode['canonical_execution_cases']}; {opcode['subsystem_integrated_execution_cases']} integrated |": current,
        f"| Lemon action contracts | {parser['typed_local_flow_contract_rules']}/{parser['canonical_semantic_action_rules']}; {parser['subsystem_integrated_action_rules']} integrated |": current,
    }
    for fact, text in facts.items():
        if fact not in text:
            raise SystemExit(f"verify-docs: synchronized fact {fact!r} is missing")
    if parser["subsystem_integrated_action_rules"] != 0 or opcode["subsystem_integrated_execution_cases"] != 0:
        raise SystemExit("verify-docs: scaffold ledgers unexpectedly grant integration credit")

    boundary = load_json(ROOT / "upstream/native-c-boundary.json")
    if boundary["required_end_state"]["production_c_objects"] != 0:
        raise SystemExit("verify-docs: production C-object target is not zero")

    baseline = dict(
        line.split("=", 1)
        for line in (ROOT / "upstream/SQLITE_BASELINE").read_text().splitlines()
        if "=" in line
    )
    baseline_owners = {
        "README.md": (baseline["version"],),
        "docs/PORTING_CHARTER.md": (baseline["version"],),
        "docs/SCOPE.md": (baseline["version"], baseline["fossil_checkin"]),
    }
    for relative, required_values in baseline_owners.items():
        text = (ROOT / relative).read_text()
        for value in required_values:
            if value not in text:
                raise SystemExit(f"verify-docs: pinned baseline is stale in {relative}")

    upstream_result = (ROOT / "reference/c_oracle/UPSTREAM_TEST_EVIDENCE.md").read_text()
    for required in (baseline["version"], baseline["fossil_checkin"], "zig build test-upstream", "oracle validation only"):
        if required not in upstream_result:
            raise SystemExit(f"verify-docs: upstream result evidence is missing {required!r}")
    testing = (ROOT / "docs/TESTING.md").read_text()
    if re.search(r"\b[\d,]+-test result\b", testing):
        raise SystemExit("verify-docs: immutable upstream test count is duplicated outside its result artifact")


def main() -> None:
    for name in REQUIRED:
        path = ROOT / "docs" / name
        if not path.is_file() or not path.read_text().strip():
            raise SystemExit(f"verify-docs: missing or empty docs/{name}")
    paths = maintained_paths()
    for path in paths:
        verify_markdown(path)
    verify_inventory(paths)
    verify_local_references(paths)
    target_count = verify_build_targets(paths)
    result_dependencies = verify_aggregate_result_graph()
    test_modules = verify_test_module_ownership()
    phase_results, fixture_manifests = verify_result_artifacts()
    verify_policy_and_facts(paths)
    print(
        f"verify-docs: {len(paths)} purpose-owned documents, {target_count} documented build targets, "
        f"{result_dependencies} aggregate dependencies, {test_modules} test/oracle modules, "
        f"{phase_results} historical results, and {fixture_manifests} fixture manifests OK"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
