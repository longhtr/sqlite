#!/usr/bin/env python3
"""Fail closed on C code and object members linked into the native library."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "upstream/native-c-boundary.json"
OUTPUT = ROOT / "zig-out/native-c-audit.json"


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"native-c-audit: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", nargs="?", default="zig-out/lib/libsqlite3.a")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    archive = (ROOT / args.archive).resolve()
    if not archive.is_file():
        fail(f"native archive not found: {archive}")

    for source in manifest["native_c_sources"] + manifest.get("test_only_c_sources", []):
        path = ROOT / source["path"]
        if not path.is_file():
            fail(f"missing inventoried C source: {source['path']}")
        if sha256(path) != source["sha256"]:
            fail(f"inventoried C source changed without boundary review: {source['path']}")
        if len(path.read_text().splitlines()) != source["lines"]:
            fail(f"inventoried C source line count changed: {source['path']}")

    raw_members = subprocess.check_output(["ar", "t", str(archive)], text=True).splitlines()
    members = [pathlib.Path(item).name for item in raw_members]
    expected_members = manifest["expected_native_archive_members"]
    if sorted(members) != sorted(expected_members):
        fail(f"unexpected native archive members: {members}")

    expected_symbols = sorted(
        symbol
        for group in manifest["c_global_symbols"].values()
        for symbol in group
    )
    actual_symbols: list[str] = []
    c_objects: list[str] = []
    for raw_member, member in zip(raw_members, members, strict=True):
        if member != "variadic_shims.o":
            continue
        object_path = ROOT / raw_member
        if not object_path.is_file():
            fail(f"archive C object is not inspectable: {raw_member}")
        c_objects.append(member)
        output = subprocess.check_output(
            ["nm", "-g", "--defined-only", str(object_path)], text=True
        )
        actual_symbols.extend(line.split()[-1] for line in output.splitlines() if line.split())
    actual_symbols.sort()
    if actual_symbols != expected_symbols:
        fail(f"native C symbol partition changed: {actual_symbols}")

    report = {
        "schema_version": 3,
        "status": manifest["status"],
        "completion_claim": False,
        "archive": archive.relative_to(ROOT).as_posix(),
        "archive_sha256": sha256(archive),
        "members": members,
        "c_objects": c_objects,
        "c_global_symbols": actual_symbols,
        "upstream_sqlite_implementation_objects": 0,
        "release_blocking_violation_count": len(c_objects) + len(actual_symbols),
        "required_production_c_object_count": 0,
        "test_only_c_sources": [source["path"] for source in manifest.get("test_only_c_sources", [])],
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("native-c-audit: production archive contains zero C objects and zero C globals")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
