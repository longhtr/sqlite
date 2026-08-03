#!/usr/bin/env python3
"""Generate an AST-derived inventory of native Zig declarations."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import pathlib
import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "upstream/zig-declaration-inventory.json"
SCOPES = (ROOT / "config", ROOT / "src")


def source_files() -> list[pathlib.Path]:
    return sorted(path for scope in SCOPES for path in scope.rglob("*.zig"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    files = source_files()
    relative = [path.relative_to(ROOT).as_posix() for path in files]
    command = [
        "zig",
        "run",
        "tools/zig_declaration_inventory.zig",
        "--",
        *relative,
    ]
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if completed.returncode != 0:
        raise SystemExit(completed.stderr or completed.stdout)

    source_by_file = {name: (ROOT / name).read_bytes() for name in relative}
    declarations = []
    seen: set[tuple[str, str, str]] = set()
    for row in completed.stderr.splitlines():
        fields = row.split("\t")
        if len(fields) != 7:
            raise SystemExit(f"unexpected AST inventory output: {row!r}")
        file_name, kind, qualified, visibility, line, start, end = fields
        key = (file_name, kind, qualified)
        if key in seen:
            raise SystemExit(f"duplicate Zig declaration identity: {key}")
        seen.add(key)
        start_int = int(start)
        end_int = int(end)
        body = source_by_file[file_name][start_int:end_int]
        declarations.append({
            "id": f"{file_name}::{kind}::{qualified}",
            "file": file_name,
            "kind": kind,
            "name": qualified.rsplit(".", 1)[-1],
            "qualified_name": qualified,
            "visibility": visibility,
            "line": int(line),
            "byte_start": start_int,
            "byte_end": end_int,
            "source_sha256": hashlib.sha256(body).hexdigest(),
        })

    declarations.sort(key=lambda item: (item["file"], item["line"], item["kind"], item["qualified_name"]))
    by_kind = collections.Counter(item["kind"] for item in declarations)
    manifest = {
        "schema_version": 1,
        "inventory_method": "std.zig.Ast declaration traversal",
        "scope": ["config/**/*.zig", "src/**/*.zig"],
        "zig_version": subprocess.check_output(["zig", "version"], text=True).strip(),
        "counts": {
            "files": len(files),
            "declarations": len(declarations),
            "by_kind": dict(sorted(by_kind.items())),
        },
        "declarations": declarations,
    }
    rendered = json.dumps(manifest, indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
            raise SystemExit(
                "Zig declaration inventory is stale; run "
                "tools/generate_zig_declaration_inventory.py"
            )
        print(f"verified {len(declarations)} AST-derived Zig declarations")
    else:
        OUTPUT.write_text(rendered)
        print(f"generated {OUTPUT.relative_to(ROOT)} with {len(declarations)} Zig declarations")


if __name__ == "__main__":
    main()
