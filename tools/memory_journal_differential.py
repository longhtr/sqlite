#!/usr/bin/env python3
"""Compare pinned-C and native in-memory journal traces."""

from __future__ import annotations

import sys

import bounded_subprocess as subprocess


def observations(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def mismatch(oracle: list[str], native: list[str]) -> str | None:
    for index in range(max(len(oracle), len(native))):
        left = oracle[index] if index < len(oracle) else "<missing>"
        right = native[index] if index < len(native) else "<missing>"
        if left != right:
            return f"observation {index}: oracle={left!r} native={right!r}"
    return None


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: memory_journal_differential.py ORACLE NATIVE")
    oracle = observations(sys.argv[1])
    native = observations(sys.argv[2])
    difference = mismatch(oracle, native)
    if difference is not None:
        raise SystemExit(f"memory-journal-differential: mismatch at {difference}")
    if len(oracle) != 14:
        raise SystemExit(f"memory-journal-differential: expected 14 observations, got {len(oracle)}")
    mutated = native.copy()
    fields = mutated[1].split("\t")
    fields[2] = str(int(fields[2]) + 1)
    mutated[1] = "\t".join(fields)
    if mismatch(oracle, mutated) is None:
        raise SystemExit("memory-journal-differential: size mutation escaped comparison")
    print("memory-journal-differential: 14 chunk, cursor, overwrite, truncate, spill, sync, close, and mutation observations match")


if __name__ == "__main__":
    main()
