"""Validate active translation claims without blocking ordinary repository controls.

Every Python entrypoint calls :func:`require_ready` to validate the tracking
manifests structurally. Only the explicit checkpoint promotion gate calls
:func:`require_checkpoint_ready`; builds, audits, generators, and incident
recovery remain available while an active batch is below its threshold.
"""

from __future__ import annotations

import collections
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "upstream/active-port-batch.json"
HISTORICAL_CLAIMS = ROOT / "upstream/historical-port-claims.json"
CHECKPOINTS = ROOT / "upstream/port-checkpoints.json"
SOURCE_INVENTORY = ROOT / "upstream/source-inventory.json"
ZIG_INVENTORY = ROOT / "upstream/zig-declaration-inventory.json"
SYMBOL_MAP = ROOT / "upstream/symbol-map.json"
ATOMIC_INDEX = ROOT / "upstream/atomic-units/index.json"

PROMOTED_STATES = {
    "source-translated",
    "internal-trace-equivalent",
    "subsystem-integrated",
    "assurance-passed",
}


def fail(message: str) -> None:
    raise SystemExit(f"port-batch-gate: {message}")


def load_object(path: pathlib.Path) -> dict[str, object]:
    def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                fail(f"duplicate key {key!r} in {path.relative_to(ROOT)}")
            result[key] = value
        return result

    value = json.loads(path.read_text(), object_pairs_hook=unique)
    if not isinstance(value, dict):
        fail(f"expected object root in {path.relative_to(ROOT)}")
    return value


def expected_class(entity: dict[str, object]) -> str:
    span = int(entity["end_line"]) - int(entity["line"]) + 1
    return "short" if span < 10 else "substantive"


def atomic_units() -> dict[str, dict[str, object]]:
    index = load_object(ATOMIC_INDEX)
    result: dict[str, dict[str, object]] = {}
    for summary in index.get("units", []):
        if not isinstance(summary, dict) or not isinstance(summary.get("path"), str):
            fail("atomic-unit index contains a malformed summary")
        dossier = load_object(ROOT / summary["path"])
        unit_id = dossier.get("id")
        if not isinstance(unit_id, str) or unit_id in result:
            fail("atomic-unit index contains a missing or duplicate unit ID")
        result[unit_id] = dossier
    return result


def validate(require_threshold: bool = False) -> dict[str, int | str]:
    manifest = load_object(MANIFEST)
    historical = load_object(HISTORICAL_CLAIMS)
    checkpoints = load_object(CHECKPOINTS)
    source_manifest = load_object(SOURCE_INVENTORY)
    zig_manifest = load_object(ZIG_INVENTORY)
    ledger = load_object(SYMBOL_MAP)

    if manifest.get("schema_version") != 2:
        fail("active manifest schema must be 2")
    if manifest.get("completion_claim") is not False:
        fail("active manifest must not claim project completion")
    if manifest.get("historical_claim_ledger") != HISTORICAL_CLAIMS.relative_to(ROOT).as_posix():
        fail("active manifest references the wrong historical claim ledger")
    status = manifest.get("status")
    if status not in {"idle", "active"}:
        fail(f"unknown active manifest status: {status!r}")
    if checkpoints.get("schema_version") != 1:
        fail("checkpoint ledger schema must be 1")
    if checkpoints.get("completion_claim") is not False:
        fail("checkpoint ledger must not claim project completion")
    if checkpoints.get("sqlite_checkin") != source_manifest.get("sqlite_checkin"):
        fail("checkpoint and source ledgers use different SQLite baselines")

    checkpoint_items = checkpoints.get("checkpoints")
    if not isinstance(checkpoint_items, list):
        fail("checkpoint ledger checkpoints must be a list")
    checkpoint_ids: list[str] = []
    checkpoint_source_ids: set[str] = set()
    previous_checkpoint: str | None = None
    for checkpoint in checkpoint_items:
        required_checkpoint = {
            "id", "parent_checkpoint_id", "git_commit", "entries",
            "short_functions", "substantive_functions", "evidence_receipts",
            "translation_credit",
        }
        if not isinstance(checkpoint, dict) or set(checkpoint) != required_checkpoint:
            fail("checkpoint ledger contains a malformed checkpoint")
        checkpoint_id = checkpoint["id"]
        if not isinstance(checkpoint_id, str) or re.fullmatch(r"[a-z0-9][a-z0-9-]*", checkpoint_id) is None:
            fail("checkpoint ledger contains an invalid checkpoint ID")
        if checkpoint["parent_checkpoint_id"] != previous_checkpoint:
            fail(f"checkpoint parent chain is broken at {checkpoint_id}")
        if not isinstance(checkpoint["git_commit"], str) or re.fullmatch(r"[0-9a-f]{40,64}", checkpoint["git_commit"]) is None:
            fail(f"checkpoint lacks an exact Git commit: {checkpoint_id}")
        if checkpoint["translation_credit"] is not True:
            fail(f"checkpoint does not explicitly grant translation credit: {checkpoint_id}")
        checkpoint_entries = checkpoint["entries"]
        if not isinstance(checkpoint_entries, list) or not checkpoint_entries:
            fail(f"checkpoint contains no entry snapshot: {checkpoint_id}")
        counts: collections.Counter[str] = collections.Counter()
        local_ids: set[str] = set()
        for entry in checkpoint_entries:
            required_entry = {
                "source_entity_id", "source_sha256", "zig_declaration_id",
                "zig_declaration_sha256", "atomic_unit_id", "class", "complete",
            }
            if not isinstance(entry, dict) or set(entry) != required_entry or entry.get("complete") is not True:
                fail(f"checkpoint contains a malformed entry: {checkpoint_id}")
            identity = entry.get("source_entity_id")
            entry_class = entry.get("class")
            if not isinstance(identity, str) or entry_class not in {"short", "substantive"}:
                fail(f"checkpoint contains an invalid entry identity/class: {checkpoint_id}")
            if identity in local_ids or identity in checkpoint_source_ids:
                fail(f"checkpoint source identity is credited more than once: {identity}")
            for key in ("source_sha256", "zig_declaration_id", "zig_declaration_sha256", "atomic_unit_id"):
                if not isinstance(entry.get(key), str) or not entry[key]:
                    fail(f"checkpoint entry lacks {key}: {identity}")
            local_ids.add(identity)
            counts[entry_class] += 1
        if checkpoint["short_functions"] != counts["short"] or checkpoint["substantive_functions"] != counts["substantive"]:
            fail(f"checkpoint totals are stale: {checkpoint_id}")
        if counts["short"] < 200 and counts["substantive"] < 50:
            fail(f"checkpoint is below the translation threshold: {checkpoint_id}")
        receipts = checkpoint["evidence_receipts"]
        if not isinstance(receipts, list) or not receipts:
            fail(f"checkpoint lacks durable evidence receipts: {checkpoint_id}")
        for receipt in receipts:
            if (
                not isinstance(receipt, dict)
                or set(receipt) != {"path", "sha256"}
                or not isinstance(receipt.get("path"), str)
                or not isinstance(receipt.get("sha256"), str)
            ):
                fail(f"checkpoint has a malformed evidence receipt: {checkpoint_id}")
            owner = pathlib.PurePosixPath(receipt["path"])
            if owner.is_absolute() or ".." in owner.parts:
                fail(f"checkpoint evidence owner escapes the repository: {checkpoint_id}")
            owner_path = ROOT / owner
            if not owner_path.is_file() or hashlib.sha256(owner_path.read_bytes()).hexdigest() != receipt["sha256"]:
                fail(f"checkpoint evidence owner is missing or stale: {checkpoint_id}")
        checkpoint_source_ids.update(local_ids)
        checkpoint_ids.append(checkpoint_id)
        previous_checkpoint = checkpoint_id
    if len(checkpoint_ids) != len(set(checkpoint_ids)):
        fail("checkpoint ledger contains duplicate checkpoint IDs")
    expected_base = checkpoint_ids[-1] if checkpoint_ids else None
    if manifest.get("base_checkpoint_id") != expected_base:
        fail("active batch does not start from the latest checkpoint")

    minimum_short = manifest.get("minimum_short_functions")
    minimum_substantive = manifest.get("minimum_substantive_functions")
    if not isinstance(minimum_short, int) or minimum_short < 200:
        fail("short-function threshold was weakened")
    if not isinstance(minimum_substantive, int) or minimum_substantive < 50:
        fail("substantive-function threshold was weakened")

    sources = {
        item["id"]: item
        for item in source_manifest.get("entities", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    declarations = {
        item["id"]: item
        for item in zig_manifest.get("declarations", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    mappings = {
        item["id"]: item
        for item in ledger.get("entities", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    units = atomic_units()

    if historical.get("schema_version") != 1 or historical.get("sqlite_checkin") != source_manifest.get("sqlite_checkin"):
        fail("historical mechanical claims use another schema or SQLite baseline")
    if historical.get("completion_credit") is not False:
        fail("historical mechanical claims need an explicit no-credit boundary")
    historical_entries = historical.get("entries")
    if not isinstance(historical_entries, list):
        fail("historical mechanical claim entries must be a list")
    historical_ids: list[str] = []
    historical_counts: collections.Counter[str] = collections.Counter()
    for entry in historical_entries:
        if not isinstance(entry, dict):
            fail("historical mechanical claim is not an object")
        identity = entry.get("source_entity_id")
        if not isinstance(identity, str) or identity not in sources:
            fail(f"historical mechanical claim has unknown source ID: {identity!r}")
        entity = sources[identity]
        if entity.get("kind") != "function" or not str(entity.get("activity", "")).startswith("active-profile"):
            fail(f"historical mechanical claim is not an active function: {identity}")
        source_class = expected_class(entity)
        if entry.get("class") != source_class:
            fail(f"historical mechanical claim has wrong class: {identity}")
        if entry.get("complete") is not True:
            fail(f"historical mechanical claim lost its historical complete marker: {identity}")
        zig_path = entry.get("zig_path")
        zig_function = entry.get("zig_function")
        if not isinstance(zig_path, str) or not isinstance(zig_function, str):
            fail(f"historical mechanical claim has malformed target: {identity}")
        if not any(
            declaration.get("file") == zig_path
            and declaration.get("kind") == "function"
            and declaration.get("name") == zig_function
            for declaration in declarations.values()
        ):
            fail(f"historical mechanical target is absent from the AST inventory: {identity}")
        historical_ids.append(identity)
        historical_counts[source_class] += 1
    if len(historical_ids) != len(set(historical_ids)):
        fail("historical mechanical claims contain duplicate source IDs")
    if historical.get("short_functions") != historical_counts["short"] or historical.get("substantive_functions") != historical_counts["substantive"]:
        fail("historical mechanical claim totals are stale")
    overlap = checkpoint_source_ids & set(historical_ids)
    if overlap:
        fail(f"historical claims overlap accepted checkpoints: {sorted(overlap)[0]}")

    entries = manifest.get("entries")
    if not isinstance(entries, list):
        fail("active entries must be a list")
    if status == "idle" and entries:
        fail("idle active manifest contains entries")
    if status == "active" and not entries:
        fail("active manifest contains no entries")

    source_ids: list[str] = []
    completed: collections.Counter[str] = collections.Counter()
    for entry in entries:
        if not isinstance(entry, dict):
            fail("active entry is not an object")
        required = {
            "source_entity_id", "source_sha256", "zig_declaration_id",
            "zig_declaration_sha256", "atomic_unit_id", "class", "complete",
        }
        if set(entry) != required:
            fail(f"active entry has non-canonical fields: {sorted(set(entry) ^ required)}")
        identity = entry["source_entity_id"]
        if not isinstance(identity, str) or identity not in sources:
            fail(f"active entry has unknown source ID: {identity!r}")
        if identity in historical_ids or identity in checkpoint_source_ids:
            fail(f"previously recorded function cannot receive net-new batch credit: {identity}")
        entity = sources[identity]
        if entity.get("kind") != "function" or not str(entity.get("activity", "")).startswith("active-profile"):
            fail(f"active entry is not an active-profile function: {identity}")
        if entry["source_sha256"] != entity.get("source_sha256"):
            fail(f"active entry has stale source hash: {identity}")
        source_class = expected_class(entity)
        if entry["class"] != source_class:
            fail(f"active entry has wrong class: {identity}")

        declaration_id = entry["zig_declaration_id"]
        declaration = declarations.get(declaration_id)
        if declaration is None or declaration.get("kind") != "function":
            fail(f"active entry has missing/non-function Zig declaration: {declaration_id}")
        if entry["zig_declaration_sha256"] != declaration.get("source_sha256"):
            fail(f"active entry has stale Zig declaration hash: {declaration_id}")

        mapping = mappings.get(identity)
        mapping_targets = {
            target.get("declaration_id")
            for target in mapping.get("zig", [])
            if isinstance(target, dict)
        } if mapping else set()
        if mapping is None or mapping.get("classification") not in PROMOTED_STATES or declaration_id not in mapping_targets:
            fail(f"active entry lacks a promoted canonical symbol mapping: {identity}")

        unit_id = entry["atomic_unit_id"]
        unit = units.get(unit_id)
        if unit is None or unit.get("status") not in PROMOTED_STATES:
            fail(f"active entry lacks a promoted atomic unit: {identity}")
        unit_mapping = next(
            (
                item for item in unit.get("mappings", [])
                if isinstance(item, dict) and item.get("source_entity_id") == identity
            ),
            None,
        )
        if unit_mapping is None or declaration_id not in unit_mapping.get("zig_declaration_ids", []):
            fail(f"active entry target differs from its atomic-unit mapping: {identity}")

        if entry["complete"] is not True:
            fail(f"active entry is not complete: {identity}")
        source_ids.append(identity)
        completed[source_class] += 1

    if len(source_ids) != len(set(source_ids)):
        fail("active entries contain duplicate source IDs")
    if require_threshold:
        if status != "active":
            fail("checkpoint promotion requires an active batch")
        if completed["short"] < minimum_short and completed["substantive"] < minimum_substantive:
            fail(
                "checkpoint threshold not reached: "
                f"short={completed['short']}/{minimum_short}; "
                f"substantive={completed['substantive']}/{minimum_substantive}"
            )

    return {
        "status": status,
        "active_entries": len(entries),
        "short": completed["short"],
        "substantive": completed["substantive"],
        "historical_claims": len(historical_entries),
        "checkpoints": len(checkpoint_items),
    }


def require_ready() -> None:
    """Validate manifests structurally while leaving ordinary tools available."""
    validate(require_threshold=False)


def require_checkpoint_ready() -> dict[str, int | str]:
    """Require a fully reconciled active batch at a translation threshold."""
    return validate(require_threshold=True)
