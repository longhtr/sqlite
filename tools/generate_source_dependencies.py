#!/usr/bin/env python3
"""Generate the active-profile SQLite source-file dependency graph."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import pathlib
import bounded_subprocess as subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "upstream/source-dependencies.json"
CLANG_TOOL = ROOT / "tools/clang_dependency.c"
AMALGAMATION = ROOT / "reference/c_oracle/sqlite3-lines.c"

TRACK_FILES = {
    "stage1-internal-model-generated": {
        "sqliteInt.h", "sqliteLimit.h", "sqlite3ext.h", "vdbe.h", "vdbeInt.h",
        "btree.h", "btreeInt.h", "pager.h", "wal.h", "whereInt.h", "mutex.h",
        "os.h", "os_common.h", "os_setup.h", "msvc.h", "vxworks.h", "pcache.h",
    },
    "stage2-foundational-services": {
        "bitvec.c", "callback.c", "complete.c", "date.c", "fault.c", "func.c",
        "global.c", "hash.c", "hash.h", "json.c", "malloc.c", "mem1.c",
        "memdb.c", "memjournal.c", "mutex.c", "mutex_noop.c", "mutex_unix.c",
        "os.c", "os_unix.c", "pcache.c", "pcache1.c", "printf.c", "random.c",
        "status.c", "string.c", "table.c", "threads.c", "utf.c", "util.c",
    },
    "stage3-storage-transactions": {
        "backup.c", "btmutex.c", "btree.c", "pager.c", "wal.c",
    },
    "stage4-vdbe-runtime": {
        "rowset.c", "vdbe.c", "vdbeapi.c", "vdbeaux.c", "vdbeblob.c",
        "vdbemem.c", "vdbesort.c", "vdbetrace.c",
    },
    "stage5-compiler-planner": {
        "alter.c", "analyze.c", "attach.c", "auth.c", "build.c", "delete.c",
        "expr.c", "fkey.c", "insert.c", "pragma.c", "prepare.c", "resolve.c",
        "select.c", "tokenize.c", "trigger.c", "update.c", "upsert.c", "vacuum.c",
        "walker.c", "where.c", "wherecode.c", "whereexpr.c", "window.c",
    },
    "stage6-public-api-extensions": {
        "legacy.c", "loadext.c", "main.c", "vtab.c",
    },
}


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_assignments(active_files: set[str]) -> dict[str, str]:
    assignments: dict[str, str] = {}
    for track, names in TRACK_FILES.items():
        for name in names:
            path = f"src/{name}"
            if path in assignments:
                raise SystemExit(f"duplicate track assignment: {path}")
            if path in active_files:
                assignments[path] = track
    missing = sorted(active_files - assignments.keys())
    if missing:
        raise SystemExit(f"active files lack track assignments: {missing}")
    return assignments


def generate() -> dict:
    inventory = json.loads((ROOT / "upstream/source-inventory.json").read_text())
    active_entities = [
        item for item in inventory["entities"]
        if item["activity"].startswith("active-profile")
    ]
    entity_counts = collections.Counter(item["file"] for item in active_entities)
    active_files = set(entity_counts)
    assignments = build_assignments(active_files)

    with tempfile.TemporaryDirectory(prefix="sqlite-zig-source-dependencies-") as temp:
        executable = pathlib.Path(temp) / "clang-dependency"
        subprocess.run([
            "cc", "-std=c99", "-O2", str(CLANG_TOOL), "-lclang", "-o", str(executable),
        ], check=True)
        output = subprocess.check_output([str(executable), str(AMALGAMATION)], text=True)

    references: set[tuple[str, str, str, str, str, str, str]] = set()
    for row in output.splitlines():
        kind, caller_file, caller_name, caller_line, callee_file, callee_name, callee_line = row.split("\t")
        caller = f"src/{caller_file}"
        callee = f"src/{callee_file}"
        if caller in active_files and callee in active_files:
            references.add((kind, caller, caller_name, caller_line, callee, callee_name, callee_line))

    edge_data: dict[tuple[str, str], collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for kind, caller, _caller_name, _caller_line, callee, _callee_name, _callee_line in references:
        if caller != callee:
            edge_data[(caller, callee)][kind] += 1

    incoming = collections.Counter()
    outgoing = collections.Counter()
    edges = []
    for (caller, callee), kinds in sorted(edge_data.items()):
        count = sum(kinds.values())
        outgoing[caller] += 1
        incoming[callee] += 1
        edges.append({
            "from": caller,
            "to": callee,
            "unique_reference_count": count,
            "by_kind": dict(sorted(kinds.items())),
        })

    nodes = [{
        "file": path,
        "source_file_unit": path.removeprefix("src/"),
        "track": assignments[path],
        "active_entity_count": entity_counts[path],
        "outgoing_file_dependencies": outgoing[path],
        "incoming_file_dependencies": incoming[path],
    } for path in sorted(active_files)]

    track_counts = collections.Counter(assignments.values())
    return {
        "schema_version": 1,
        "sqlite_checkin": inventory["sqlite_checkin"],
        "profile": inventory["profile"],
        "method": "libclang active AST call/global/type references aggregated by source file",
        "generator_sha256": sha256(CLANG_TOOL),
        "counts": {
            "active_files": len(nodes),
            "source_file_units": len(nodes),
            "cross_file_edges": len(edges),
            "unique_active_references": len(references),
            "files_by_track": dict(sorted(track_counts.items())),
        },
        "nodes": nodes,
        "edges": edges,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = json.dumps(generate(), indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
            raise SystemExit("source dependency graph is stale; run tools/generate_source_dependencies.py")
        print("source-dependencies: active file dependency graph verified")
    else:
        OUTPUT.write_text(rendered)
        report = json.loads(rendered)
        print(
            f"source-dependencies: wrote {OUTPUT.relative_to(ROOT)} with "
            f"{report['counts']['active_files']} source-file units and {report['counts']['cross_file_edges']} edges"
        )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
