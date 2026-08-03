#!/usr/bin/env python3
"""Compare source-corresponding SQLite StrAccum state transitions."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: formatter_accumulator_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 12 or len(native) != 12:
        raise SystemExit(
            f"formatter-accumulator-differential: expected one layout and 11 states, got oracle={len(oracle)} native={len(native)}"
        )
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(
                    f"formatter-accumulator-differential: mismatch at state {index}: oracle={left!r} native={right!r}"
                )
        raise SystemExit("formatter-accumulator-differential: output length mismatch")
    print("formatter-accumulator-differential: exact layout and 11 fixed, dynamic, limit, finish, and reset states match")


if __name__ == "__main__":
    main()
