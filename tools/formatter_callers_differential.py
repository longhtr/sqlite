#!/usr/bin/env python3
"""Compare typed allocation, fixed-buffer, internal, and logging formatter callers."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: formatter_callers_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 8 or len(native) != 8:
        raise SystemExit(f"formatter-callers-differential: expected 8 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"formatter-callers-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("formatter-callers-differential: output length mismatch")
    print("formatter-callers-differential: 8 allocated, fixed, internal, truncation, empty, and logging observations match")


if __name__ == "__main__":
    main()
