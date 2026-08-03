#!/usr/bin/env python3
"""Compare bounded read-only pager scaffold observations with the pinned C pager."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import bounded_subprocess as subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "tests/fixtures/pager/manifest.json"


def run(path: str) -> list[str]:
    result = subprocess.run(
        [path], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
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
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != fixture["size"] or digest != fixture["sha256"]:
            raise SystemExit(f"pager fixture drift: {fixture['name']}")
    return len(manifest["fixtures"])


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: pager_differential.py ORACLE NATIVE")
    fixture_count = verify_fixtures()
    work = ROOT / ".reference-build/pager-differential"
    work.mkdir(parents=True, exist_ok=True)
    source = MANIFEST.parent / "valid-empty-4096.db"
    for name in ("hot.db", "busy.db"):
        shutil.copyfile(source, work / name)
    (work / "hot.db-journal").write_bytes(b"not-zero")
    for name in ("hot.db-wal", "busy.db-journal", "busy.db-wal"):
        (work / name).unlink(missing_ok=True)
    oracle = run(sys.argv[1])
    native = run(sys.argv[2])
    if oracle != native:
        limit = max(len(oracle), len(native))
        differences = []
        for index in range(limit):
            left = oracle[index] if index < len(oracle) else "<missing>"
            right = native[index] if index < len(native) else "<missing>"
            if left != right:
                differences.append(f"line {index + 1}:\n  C {left!r}\n  Z {right!r}")
            if len(differences) == 12:
                break
        raise SystemExit("pager differential mismatch\n" + "\n".join(differences))
    print(
        f"pager-differential: {fixture_count} fixtures and {len(native)} observations match"
    )


if __name__ == "__main__":
    main()
