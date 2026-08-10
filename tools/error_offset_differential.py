#!/usr/bin/env python3
"""Compare SQLite parser/token and expression error-offset recording."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: error_offset_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 10 or len(native) != 10:
        raise SystemExit(f"error-offset-differential: expected 10 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"error-offset-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("error-offset-differential: output length mismatch")
    print("error-offset-differential: 10 token-range, first-error, expression-chain, join, and DDL observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
