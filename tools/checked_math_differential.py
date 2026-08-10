#!/usr/bin/env python3
"""Compare SQLite checked integer and floating classification utilities."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: checked_math_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 22 or len(native) != 22:
        raise SystemExit(f"checked-math-differential: expected 22 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"checked-math-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("checked-math-differential: output length mismatch")
    print("checked-math-differential: 22 add, subtract, multiply, absolute, NaN, and infinity observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
