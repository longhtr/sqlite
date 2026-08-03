#!/usr/bin/env python3
"""Compare SQLite trigger-aware SQL completeness state machines."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: complete_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 16 or len(native) != 16:
        raise SystemExit(f"complete-differential: expected 16 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"complete-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("complete-differential: output length mismatch")
    print("complete-differential: 16 comments, quotes, triggers, UTF-8, and UTF-16 observations match")


if __name__ == "__main__":
    main()
