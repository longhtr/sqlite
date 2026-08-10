#!/usr/bin/env python3
"""Inventory canonical C entities and active-profile object symbols.

Universal Ctags supplies file/line/signature/end metadata for functions,
globals, types, members, enumerators, and macros. Libclang inspects the pinned
line-macro amalgamation and physical #line mapping supplies exact active-profile
source identities. Unmatched entities remain explicitly inactive, not guessed.
"""

from __future__ import annotations

import collections
import hashlib
import json
import pathlib
import re
import bounded_subprocess as subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "upstream/sqlite/src"
OUTPUT = ROOT / "upstream/source-inventory.json"
CHECKIN = "bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc"


def source_files() -> list[pathlib.Path]:
    result = []
    for pattern in ("*.c", "*.h"):
        for path in sorted(SOURCE.glob(pattern)):
            if path.name.startswith("test") or path.name.startswith("tcl"):
                continue
            result.append(path)
    return sorted(set(result))


def line_predicates(path: pathlib.Path) -> list[str]:
    """Return the enclosing textual preprocessor predicate for each source line."""
    lines = path.read_text(errors="surrogateescape").splitlines()
    predicates = ["always"] * len(lines)
    stack: list[str] = []
    index = 0
    while index < len(lines):
        start = index
        logical = lines[index].strip()
        while logical.endswith("\\") and index + 1 < len(lines):
            logical = logical[:-1] + " " + lines[index + 1].strip()
            index += 1
        current = " && ".join(f"({item})" for item in stack) if stack else "always"
        for line_index in range(start, index + 1):
            predicates[line_index] = current
        if logical.startswith("#ifdef "):
            stack.append(f"defined({logical[7:].strip()})")
        elif logical.startswith("#ifndef "):
            stack.append(f"!defined({logical[8:].strip()})")
        elif logical.startswith("#if "):
            stack.append(logical[4:].strip())
        elif logical.startswith("#elif ") and stack:
            stack[-1] = f"elif({logical[6:].strip()})"
        elif logical == "#else" and stack:
            stack[-1] = f"else-of({stack[-1]})"
        elif logical.startswith("#endif") and stack:
            stack.pop()
        index += 1
    return predicates


def linemacro_locations(path: pathlib.Path) -> dict[int, tuple[str, int]]:
    """Map amalgamation physical lines back to #line source identities."""
    result: dict[int, tuple[str, int]] = {}
    current_file = path.name
    current_line = 1
    directive = re.compile(r'^#line\s+(\d+)\s+"([^"]+)"')
    for physical_line, text in enumerate(
        path.read_text(errors="surrogateescape").splitlines(), 1
    ):
        match = directive.match(text)
        if match:
            current_line = int(match.group(1))
            current_file = pathlib.Path(match.group(2)).name
            continue
        result[physical_line] = (current_file, current_line)
        current_line += 1
    return result


def active_entities(linemacro_amalgamation: pathlib.Path) -> dict[tuple[str, str, str], set[int]]:
    """Use pinned libclang to identify entities compiled into the active profile."""
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-clang-inventory-") as temp:
        executable = pathlib.Path(temp) / "clang-inventory"
        subprocess.run([
            "cc", "-std=c99", "-O2", str(ROOT / "tools/clang_inventory.c"),
            "-lclang", "-o", str(executable),
        ], check=True)
        output = subprocess.check_output([str(executable), str(linemacro_amalgamation)], text=True)
    physical_locations = linemacro_locations(linemacro_amalgamation)
    result: dict[tuple[str, str, str], set[int]] = collections.defaultdict(set)
    for row in output.splitlines():
        kind, filename, presumed_line, physical_line, parent_kind, parent_name, name = row.split("\t", 6)
        filename = pathlib.Path(filename).name
        mapped = physical_locations.get(int(physical_line))
        line = int(presumed_line)
        if mapped is not None and mapped[0] == filename:
            line = mapped[1]
        result[(kind, filename, name)].add(line)
    return result


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_source_inventory.py LINEMACRO_AMALGAMATION")
    linemacro_amalgamation = pathlib.Path(sys.argv[1]).resolve()
    if not linemacro_amalgamation.is_file():
        raise SystemExit(f"line-macro amalgamation not found: {linemacro_amalgamation}")

    files = source_files()
    command = [
        "ctags",
        "--output-format=json",
        "--fields=+neKSE",
        "--kinds-C=defgmstuv",
        "-o",
        "-",
        *map(str, files),
    ]
    ctags_version = subprocess.check_output(["ctags", "--version"], text=True).splitlines()[0]
    output = subprocess.check_output(command, text=True)
    tags = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    active = active_entities(linemacro_amalgamation)
    candidate_lines: dict[tuple[str, str, str], set[int]] = collections.defaultdict(set)
    for tag in tags:
        key = (tag["kind"], pathlib.Path(tag["path"]).name, tag["name"])
        candidate_lines[key].add(int(tag["line"]))

    predicates_by_path = {path: line_predicates(path) for path in files}
    entities = []
    for tag in tags:
        path = pathlib.Path(tag["path"])
        relative = path.relative_to(ROOT / "upstream/sqlite").as_posix()
        start = int(tag["line"])
        end = int(tag.get("end", start))
        lines = path.read_text(errors="surrogateescape").splitlines(keepends=True)
        body = "".join(lines[start - 1:end]).encode("utf-8", "surrogateescape")
        name = tag["name"]
        kind = tag["kind"]
        key = (kind, path.name, name)
        active_lines = active.get(key, set())
        candidates = candidate_lines[key]
        exact_active_lines = active_lines & candidates
        if start in exact_active_lines:
            activity = "active-profile"
        elif exact_active_lines:
            activity = "inactive-or-not-emitted"
        elif active_lines and len(candidates) == 1:
            activity = "active-profile-location-adjusted"
        elif active_lines:
            activity = "ambiguous-active-location"
        else:
            activity = "inactive-or-not-emitted"
        entities.append({
            "id": f"{relative}::{kind}::{name}::line-{start}",
            "file": relative,
            "kind": kind,
            "name": name,
            "line": start,
            "end_line": end,
            "signature": tag.get("signature"),
            "file_scope": tag.get("file", False),
            "activity": activity,
            "feature_predicate": predicates_by_path[path][start - 1],
            "compiler_presumed_lines": sorted(active_lines),
            "source_sha256": hashlib.sha256(body).hexdigest(),
            "ledger_status": (
                "unmapped" if activity.startswith("active-profile") else "inactive-profile"
            ),
        })

    counts = collections.Counter(entity["activity"] for entity in entities)
    by_kind = collections.Counter(entity["kind"] for entity in entities)
    manifest = {
        "schema_version": 1,
        "sqlite_checkin": CHECKIN,
        "profile": "sqlite-3.53.4-core-default-threadsafe1",
        "inventory_method": "universal-ctags entities plus libclang AST of line-macro active-profile amalgamation",
        "ctags_version": ctags_version,
        "scope": "core src/*.{c,h} excluding test* and tcl* files",
        "limitations": [
            "One generated os_unix macro has a unique adjusted location recorded as evidence.",
            "Generated grammar entities and optional extensions require separate inventory passes."
        ],
        "counts": {
            "total": len(entities),
            "by_activity": dict(sorted(counts.items())),
            "by_kind": dict(sorted(by_kind.items()))
        },
        "entities": entities,
    }
    OUTPUT.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"generated {OUTPUT.relative_to(ROOT)} with {len(entities)} source entities")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
