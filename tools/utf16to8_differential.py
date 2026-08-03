#!/usr/bin/env python3
"""Compare SQLite connection-allocated UTF-16 to UTF-8 conversion."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: utf16to8_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 5 or len(native) != 5:
        raise SystemExit(f"utf16to8-differential: expected 5 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"utf16to8-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("utf16to8-differential: output length mismatch")
    print("utf16to8-differential: 5 LE, BE, BMP, surrogate, and bounded ownership observations match")


if __name__ == "__main__":
    main()
