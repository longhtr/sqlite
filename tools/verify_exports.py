#!/usr/bin/env python3
"""Inventory the transitional C-shaped exports implemented directly by Zig."""

from __future__ import annotations

import json
import pathlib
import re
import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    manifest = json.loads((ROOT / "upstream/api-manifest.json").read_text())
    boundary = json.loads((ROOT / "upstream/native-c-boundary.json").read_text())
    test_only = set(boundary.get("test_only_c_entrypoints", []))
    expected = {
        item["symbol"] for item in manifest["declarations"]
        if item["status"] in {"fidelity-evidenced", "provisional-bounded"}
        and item["symbol"] not in test_only
    }
    candidates = sorted((ROOT / "zig-out/lib").glob("libsqlite_zig.so*"))
    libraries = [path for path in candidates if path.is_file() and not path.is_symlink()]
    if not libraries:
        raise SystemExit("verify-exports: installed shared library not found")
    output = subprocess.check_output(
        ["nm", "-D", "--defined-only", str(libraries[-1])], text=True
    )
    actual = {
        match.group(1)
        for line in output.splitlines()
        if (match := re.search(r"\b(sqlite3[A-Za-z0-9_]*)$", line))
    }
    if actual != expected:
        raise SystemExit(
            "verify-exports: partition mismatch; "
            f"missing={sorted(expected - actual)}, unexpected={sorted(actual - expected)}"
        )
    print(
        "verify-exports: transitional Zig-defined C-shaped partition contains "
        f"{len(actual)} symbols; this is not a completion metric"
    )


if __name__ == "__main__":
    main()
