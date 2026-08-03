#!/usr/bin/env python3
"""Compare SQLite packed variable-name/number list behavior."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: vlist_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 8 or len(native) != 8:
        raise SystemExit(f"vlist-differential: expected 8 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"vlist-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("vlist-differential: output length mismatch")
    print("vlist-differential: 8 packed growth, metadata, exact-name, reverse, and missing lookup observations match")


if __name__ == "__main__":
    main()
