#!/usr/bin/env python3
"""Compare process PRNG reset, buffering, and save/restore semantics."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: random_process_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 5 or len(native) != 5:
        raise SystemExit(f"random-process-differential: expected 5 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"random-process-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("random-process-differential: output length mismatch")
    print("random-process-differential: 5 reset, initialization, buffering, save/restore, and null-output observations match")


if __name__ == "__main__":
    main()
