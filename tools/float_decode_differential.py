#!/usr/bin/env python3
"""Compare SQLite floating conversion helpers and FpDecode state."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: float_decode_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 298 or len(native) != 298:
        raise SystemExit(f"float-decode-differential: expected 298 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"float-decode-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("float-decode-differential: output length mismatch")
    print("float-decode-differential: 298 layout, scaling, conversion, boundary, special, rounding, and seeded-bit observations match")


if __name__ == "__main__":
    main()
