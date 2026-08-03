#!/usr/bin/env python3
"""Compare source-corresponding SQLite RCStr layout and ownership traces."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: formatter_rcstr_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 7 or len(native) != 7:
        raise SystemExit(
            f"formatter-rcstr-differential: expected 7 observations, got oracle={len(oracle)} native={len(native)}"
        )
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(
                    f"formatter-rcstr-differential: mismatch at observation {index}: oracle={left!r} native={right!r}"
                )
        raise SystemExit("formatter-rcstr-differential: output length mismatch")
    print("formatter-rcstr-differential: exact layout and 6 allocation/reference/resize observations match")


if __name__ == "__main__":
    main()
