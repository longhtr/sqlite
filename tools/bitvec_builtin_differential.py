#!/usr/bin/env python3
"""Compare SQLite's mutable Bitvec built-in test interpreter."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: bitvec_builtin_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 4 or len(native) != 4:
        raise SystemExit(f"bitvec-builtin-differential: expected 4 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"bitvec-builtin-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("bitvec-builtin-differential: output length mismatch")
    print("bitvec-builtin-differential: 4 sequential, deliberate-fault, random, and negative-size observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
