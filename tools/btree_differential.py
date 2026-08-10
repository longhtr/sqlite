#!/usr/bin/env python3
"""Compare bounded reconstructed-B-tree traversal/record observations with pinned SQLite."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import bounded_subprocess as subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "tests/fixtures/btree/manifest.json"


def run(path: str) -> list[str]:
    result = subprocess.run([path], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise SystemExit(
            f"{path} failed ({result.returncode})\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    output = result.stdout if result.stdout.strip() else result.stderr
    return output.strip().splitlines()


def verify_fixtures() -> int:
    manifest = json.loads(MANIFEST.read_text())
    for fixture in manifest["fixtures"]:
        data = (MANIFEST.parent / fixture["name"]).read_bytes()
        if len(data) != fixture["size"] or hashlib.sha256(data).hexdigest() != fixture["sha256"]:
            raise SystemExit(f"B-tree fixture drift: {fixture['name']}")
    return len(manifest["fixtures"])


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: btree_differential.py ORACLE NATIVE")
    count = verify_fixtures()
    oracle = run(sys.argv[1])
    native = run(sys.argv[2])
    if oracle != native:
        differences = []
        for index in range(max(len(oracle), len(native))):
            left = oracle[index] if index < len(oracle) else "<missing>"
            right = native[index] if index < len(native) else "<missing>"
            if left != right:
                differences.append(f"line {index+1}:\n  C {left!r}\n  Z {right!r}")
            if len(differences) == 16:
                break
        raise SystemExit("B-tree differential mismatch\n" + "\n".join(differences))
    print(f"btree-differential: {count} fixtures and {len(native)} observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
