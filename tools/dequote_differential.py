#!/usr/bin/env python3
"""Compare SQLite in-place string and borrowed Token dequoting."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: dequote_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 15 or len(native) != 15:
        raise SystemExit(f"dequote-differential: expected 15 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"dequote-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("dequote-differential: output length mismatch")
    print("dequote-differential: 15 string, Token, Expr-view, quoted-number, separator, and IntValue observations match")


if __name__ == "__main__":
    main()
