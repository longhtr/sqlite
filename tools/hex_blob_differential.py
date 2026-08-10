#!/usr/bin/env python3
"""Compare SQLite hex-literal allocation and decoding."""

from __future__ import annotations

import bounded_subprocess as subprocess
import sys


def output(executable: str) -> list[str]:
    result = subprocess.run([executable], text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: hex_blob_differential.py ORACLE NATIVE")
    oracle = output(sys.argv[1])
    native = output(sys.argv[2])
    if len(oracle) != 5 or len(native) != 5:
        raise SystemExit(f"hex-blob-differential: expected 5 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle != native:
        for index, (left, right) in enumerate(zip(oracle, native)):
            if left != right:
                raise SystemExit(f"hex-blob-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("hex-blob-differential: output length mismatch")
    print("hex-blob-differential: 5 empty, case, zero, byte, allocation, and sentinel observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
