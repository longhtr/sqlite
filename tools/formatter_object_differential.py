#!/usr/bin/env python3
"""Compare SQLite dynamic string object construction, limits, and finish."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: formatter_object_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 5 or len(native) != 5:
        raise SystemExit(f"formatter-object-differential: expected 5 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"formatter-object-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("formatter-object-differential: output length mismatch")
    print("formatter-object-differential: 5 construction, append, finish, connection-limit, and error observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
