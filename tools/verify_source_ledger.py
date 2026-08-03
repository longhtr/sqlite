#!/usr/bin/env python3
"""Validate source classifications and AST-resolved Zig declaration targets."""

from __future__ import annotations

import collections
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

ACTIVE_REVIEW_STATES = {
    "context-reviewed",
    "fidelity-ported",
    "generated",
    "targeted-differential-passed",
    "source-context-reviewed",
    "scaffolded",
    "source-translated",
    "internal-trace-equivalent",
    "subsystem-integrated",
    "assurance-passed",
    "independently-fidelity-reviewed",
    "subsystem-integration-passed",
    "fidelity-reviewed",
    "architecture-irrelevant-reviewed",
}
LEGACY_STATES = {
    "legacy-candidate-target-resolved",
    "legacy-candidate-unresolved",
}
INACTIVE_STATES = {"inactive-profile", "inactive-profile-legacy-candidate"}


def fail(message: str) -> None:
    raise SystemExit(f"verify-source-ledger: {message}")


def main() -> None:
    source_manifest = json.loads((ROOT / "upstream/source-inventory.json").read_text())
    zig_manifest = json.loads((ROOT / "upstream/zig-declaration-inventory.json").read_text())
    ledger = json.loads((ROOT / "upstream/symbol-map.json").read_text())

    if ledger.get("schema_version") != 2 or ledger.get("status") != "initial-classification":
        fail("unexpected ledger schema or status")
    if ledger.get("completion_claim") is not False:
        fail("incomplete ledger must not claim completion")
    if ledger.get("sqlite_checkin") != source_manifest.get("sqlite_checkin"):
        fail("ledger and source inventory use different SQLite baselines")

    source_items = source_manifest["entities"]
    sources = {item["id"]: item for item in source_items}
    if len(sources) != len(source_items):
        fail("duplicate source identities")
    declarations = {item["id"]: item for item in zig_manifest["declarations"]}
    if len(declarations) != len(zig_manifest["declarations"]):
        fail("duplicate Zig declaration identities")

    active_ids = {
        item["id"] for item in source_items
        if item["activity"].startswith("active-profile")
    }
    for item in source_items:
        expected = "unmapped" if item["id"] in active_ids else "inactive-profile"
        if item.get("ledger_status") != expected:
            fail(f"invalid initial classification for {item['id']}")

    entries = ledger["entities"]
    if len({item["id"] for item in entries}) != len(entries):
        fail("duplicate ledger overrides")

    counts: collections.Counter[str] = collections.Counter()
    target_count = 0
    unresolved_count = 0
    reviewed_count = 0
    for entry in entries:
        source = sources.get(entry["id"])
        if source is None:
            fail(f"unknown source identity: {entry['id']}")
        if entry.get("source_sha256") != source["source_sha256"]:
            fail(f"stale source hash: {entry['id']}")

        classification = entry.get("classification")
        counts[classification] += 1
        active = entry["id"] in active_ids
        if active and classification not in LEGACY_STATES | ACTIVE_REVIEW_STATES:
            fail(f"invalid active classification for {entry['id']}: {classification}")
        if not active and classification not in INACTIVE_STATES:
            fail(f"invalid inactive classification for {entry['id']}: {classification}")
        if entry.get("fidelity_reviewed") is not (classification == "fidelity-reviewed"):
            fail(f"inconsistent fidelity review flag: {entry['id']}")

        targets = entry.get("zig", [])
        for target in targets:
            if set(target) != {"declaration_id", "source_sha256"}:
                fail(f"non-canonical Zig target shape: {entry['id']}")
            declaration = declarations.get(target["declaration_id"])
            if declaration is None:
                fail(f"missing Zig declaration: {target['declaration_id']}")
            if target["source_sha256"] != declaration["source_sha256"]:
                fail(f"stale Zig declaration hash: {target['declaration_id']}")
            target_count += 1

        unresolved = entry.get("unresolved_legacy_targets", [])
        unresolved_count += len(unresolved)
        if classification == "legacy-candidate-unresolved" and not unresolved:
            fail(f"unresolved candidate lacks unresolved targets: {entry['id']}")
        if classification == "legacy-candidate-target-resolved" and unresolved:
            fail(f"resolved candidate contains unresolved targets: {entry['id']}")

        if classification in ACTIVE_REVIEW_STATES:
            reviewed_count += 1
            if classification != "architecture-irrelevant-reviewed" and not targets:
                fail(f"reviewed mapping has no Zig declaration: {entry['id']}")
            if not entry.get("obligations"):
                fail(f"reviewed mapping has no obligations: {entry['id']}")
            evidence = entry.get("evidence", {})
            required_evidence = {
                "context_review", "targeted_differential",
                "subsystem_integration", "fidelity_review",
            }
            if classification == "fidelity-reviewed" and not required_evidence <= evidence.keys():
                fail(f"fidelity-reviewed mapping lacks required evidence: {entry['id']}")

    if dict(sorted(counts.items())) != ledger.get("classification_counts"):
        fail("classification counts are stale")

    overrides = {entry["id"]: entry["classification"] for entry in entries}
    effective = {
        identity: overrides.get(identity, sources[identity]["ledger_status"])
        for identity in active_ids
    }
    allowed_active = {"unmapped"} | LEGACY_STATES | ACTIVE_REVIEW_STATES
    invalid = {identity: state for identity, state in effective.items() if state not in allowed_active}
    if invalid or len(effective) != len(active_ids):
        fail("not every active source entity has a valid initial classification")

    print(
        "verify-source-ledger: "
        f"{len(active_ids)} active entities classified; "
        f"{reviewed_count} reviewed mappings; "
        f"{target_count} AST-resolved targets; "
        f"{unresolved_count} unresolved legacy targets"
    )


if __name__ == "__main__":
    main()
