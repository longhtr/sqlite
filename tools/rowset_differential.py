#!/usr/bin/env python3
"""Compare SQLite RowSet sorting, uniqueness, batching, and reuse."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: rowset_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 7 or len(native) != 7:
        raise SystemExit(
            f"rowset-differential: expected 7 observations, "
            f"got oracle={len(oracle)} native={len(native)}"
        )
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(
                    f"rowset-differential: mismatch at observation {index}: "
                    f"oracle={left!r} native={right!r}"
                )
        raise SystemExit("rowset-differential: output length mismatch")
    print(
        "rowset-differential: 7 sorting, duplicate, chunk-scale, batch-visibility, "
        "forest-merge, clear, and reuse observations match"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
