#!/usr/bin/env python3
"""Compare SQLite SQL-formatter argument cursor layout and consumption."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: formatter_arguments_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 8 or len(native) != 8:
        raise SystemExit(
            f"formatter-arguments-differential: expected 8 observations, got oracle={len(oracle)} native={len(native)}"
        )
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(
                    f"formatter-arguments-differential: mismatch at observation {index}: oracle={left!r} native={right!r}"
                )
        raise SystemExit("formatter-arguments-differential: output length mismatch")
    print("formatter-arguments-differential: exact layout and 7 typed consumption/default observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
