#!/usr/bin/env python3
"""Compare pinned baseline protocol and version metadata in isolated workers."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys

REQUEST = b"HELLO\t1\nVERSION\nQUIT\n"


def run(path: str) -> list[str]:
    completed = subprocess.run(
        [path], input=REQUEST, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True
    )
    lines = completed.stdout.decode("utf-8", "strict").splitlines()
    if len(lines) != 3 or not lines[0].startswith("OK\t1\t") or lines[2] != "BYE":
        raise SystemExit(f"invalid worker response from {path}: {lines!r}")
    return lines


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: differential_probe.py ORACLE_WORKER NATIVE_WORKER")
    oracle = run(sys.argv[1])
    native = run(sys.argv[2])
    if oracle[1] != native[1]:
        raise SystemExit(f"metadata mismatch:\noracle={oracle[1]}\nnative={native[1]}")
    print(f"differential-probe: metadata matches: {native[1]}")


if __name__ == "__main__":
    main()
