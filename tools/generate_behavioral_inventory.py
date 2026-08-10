#!/usr/bin/env python3
"""Generate active-profile control-flow/assertion blocks missed by declaration inventory."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import pathlib
import tempfile

import bounded_subprocess as subprocess
from generate_source_inventory import line_predicates, linemacro_locations

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "upstream/sqlite/src"
AMALGAMATION = ROOT / "reference/c_oracle/sqlite3-lines.c"
CLANG_TOOL = ROOT / "tools/clang_behavior.c"
OUTPUT = ROOT / "upstream/behavioral-inventory.json"
ATOMIC_INDEX = ROOT / "upstream/atomic-units/index.json"
CHECKIN = "bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc"


def source_excerpt_hash(path: pathlib.Path, start_line: int, end_line: int) -> str:
    lines = path.read_text(errors="surrogateescape").splitlines(keepends=True)
    if not lines:
        return hashlib.sha256(b"").hexdigest()
    start = max(1, min(start_line, len(lines)))
    end = max(start, min(end_line, len(lines)))
    body = "".join(lines[start - 1 : end]).encode("utf-8", "surrogateescape")
    return hashlib.sha256(body).hexdigest()


def generate() -> dict:
    source_inventory = json.loads((ROOT / "upstream/source-inventory.json").read_text())
    active_functions: dict[tuple[str, str], str] = {}
    function_ranges: dict[str, list[tuple[int, int, str, str]]] = collections.defaultdict(list)
    for entity in source_inventory["entities"]:
        if entity["kind"] == "function" and entity["activity"].startswith("active-profile"):
            active_functions[(entity["file"], entity["name"])] = entity["id"]
            function_ranges[entity["file"]].append((
                int(entity["line"]), int(entity["end_line"]), entity["name"], entity["id"]
            ))

    with tempfile.TemporaryDirectory(prefix="sqlite-zig-behavioral-inventory-") as temporary:
        executable = pathlib.Path(temporary) / "clang-behavior"
        subprocess.run(
            ["cc", "-std=c99", "-O2", CLANG_TOOL, "-lclang", "-o", executable],
            check=True,
        )
        output = subprocess.check_output([executable, AMALGAMATION], text=True)

    physical_locations = linemacro_locations(AMALGAMATION)
    predicates: dict[pathlib.Path, list[str]] = {}
    ordinals: collections.Counter[tuple[str, str, str, int, int]] = collections.Counter()
    blocks: list[dict[str, object]] = []
    for row in output.splitlines():
        (
            kind,
            filename,
            raw_start_line,
            raw_start_column,
            raw_end_line,
            raw_end_column,
            raw_physical_line,
            function,
            label,
        ) = row.split("\t", 8)
        filename = pathlib.Path(filename).name
        path = SOURCE / filename
        if not path.is_file() or path.suffix not in {".c", ".h", ".y"}:
            continue
        start_line = int(raw_start_line)
        physical = physical_locations.get(int(raw_physical_line))
        if physical is not None and physical[0] == filename:
            start_line = physical[1]
        end_line = int(raw_end_line)
        if end_line < start_line or end_line - start_line > 100_000:
            end_line = start_line
        start_column = int(raw_start_column)
        end_column = int(raw_end_column)
        relative = f"src/{filename}"
        predicates.setdefault(path, line_predicates(path))
        line_predicate = predicates[path]
        feature_predicate = (
            line_predicate[start_line - 1]
            if 0 < start_line <= len(line_predicate)
            else "generated-location-unavailable"
        )
        source_entity = active_functions.get((relative, function))
        if kind == "assert" and not function:
            enclosing = [
                candidate for candidate in function_ranges.get(relative, [])
                if candidate[0] <= start_line <= candidate[1]
            ]
            if enclosing:
                _, _, function, source_entity = min(
                    enclosing, key=lambda candidate: candidate[1] - candidate[0]
                )
        ordinal_key = (relative, function, kind, start_line, start_column)
        ordinal = ordinals[ordinal_key]
        ordinals[ordinal_key] += 1
        identity = (
            f"{relative}::function::{function}::behavior::{kind}::"
            f"line-{start_line}-column-{start_column}::ordinal-{ordinal}"
        )
        blocks.append({
            "id": identity,
            "file": relative,
            "function": function,
            "kind": kind,
            "label": label or None,
            "line": start_line,
            "column": start_column,
            "end_line": end_line,
            "end_column": end_column,
            "feature_predicate": feature_predicate,
            "source_entity_id": source_entity,
            "source_excerpt_sha256": source_excerpt_hash(path, start_line, end_line),
            "evidence_state": "inventoried",
            "atomic_unit_id": None,
        })

    blocks.sort(key=lambda item: (
        item["file"], item["line"], item["column"], item["kind"], item["function"], item["id"]
    ))
    blocks_by_id = {block["id"]: block for block in blocks}
    if ATOMIC_INDEX.is_file():
        index = json.loads(ATOMIC_INDEX.read_text())
        for summary in index.get("units", []):
            dossier = json.loads((ROOT / summary["path"]).read_text())
            for identity in dossier.get("scope", {}).get("behavioral_block_ids", []):
                block = blocks_by_id.get(identity)
                if block is None:
                    raise SystemExit(f"behavioral-inventory: atomic unit references unknown block: {identity}")
                if block["atomic_unit_id"] is not None:
                    raise SystemExit(f"behavioral-inventory: block assigned more than once: {identity}")
                block["atomic_unit_id"] = dossier["id"]
                block["evidence_state"] = dossier["status"]
    by_kind = collections.Counter(str(block["kind"]) for block in blocks)
    by_file = collections.Counter(str(block["file"]) for block in blocks)
    functions = {(block["file"], block["function"]) for block in blocks}
    return {
        "schema_version": 1,
        "sqlite_checkin": CHECKIN,
        "profile": source_inventory["profile"],
        "method": "libclang active line-macro amalgamation statement/assertion cursors mapped to canonical source",
        "scope": "active-profile if/switch/case/default/conditional/loop/goto/label/return/break/continue/assert blocks",
        "warning": "Inventory is planning/accounting only. A block receives progress credit only through a dependency-closed atomic-unit dossier and engineering-process promotion gates.",
        "generator_sha256": hashlib.sha256(CLANG_TOOL.read_bytes()).hexdigest(),
        "counts": {
            "blocks": len(blocks),
            "functions_with_blocks": len(functions),
            "files": len(by_file),
            "assigned_to_atomic_units": sum(block["atomic_unit_id"] is not None for block in blocks),
            "by_kind": dict(sorted(by_kind.items())),
            "by_file": dict(sorted(by_file.items())),
        },
        "blocks": blocks,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    report = generate()
    rendered = json.dumps(report, indent=2) + "\n"
    if arguments.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
            raise SystemExit(
                "behavioral-inventory: stale; run tools/generate_behavioral_inventory.py"
            )
        print(
            "behavioral-inventory: verified "
            f"{report['counts']['blocks']} blocks in "
            f"{report['counts']['functions_with_blocks']} functions"
        )
        return
    OUTPUT.write_text(rendered)
    print(
        f"behavioral-inventory: wrote {OUTPUT.relative_to(ROOT)} with "
        f"{report['counts']['blocks']} blocks"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
