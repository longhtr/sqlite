#!/usr/bin/env python3
"""Compare SQLite formatter metadata and ASCII hash lookup with the Zig port."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: formatter_metadata_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 282 or len(native) != 282:
        raise SystemExit(
            f"formatter-metadata-differential: expected 282 observations, got oracle={len(oracle)} native={len(native)}"
        )
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(
                    f"formatter-metadata-differential: mismatch at observation {index}: oracle={left!r} native={right!r}"
                )
        raise SystemExit("formatter-metadata-differential: output length mismatch")
    print("formatter-metadata-differential: 282 constants, table, and lookup observations match")


if __name__ == "__main__":
    main()
