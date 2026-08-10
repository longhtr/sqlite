#!/usr/bin/env python3
"""Compare pinned C and native Zig four-byte big-endian helpers."""

from __future__ import annotations

import random
import bounded_subprocess as subprocess
import sys


def run(worker: str, values: list[int]) -> bytes:
    return subprocess.run(
        [worker, *(str(value) for value in values)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout


def scenarios() -> list[list[int]]:
    result = [[0, 1, 0x7FFFFFFF, 0x80000000, 0xDEADBEEF, 0xFFFFFFFF]]
    for seed in range(23):
        randomizer = random.Random(seed)
        result.append([randomizer.getrandbits(32) for _ in range(200)])
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: byteorder_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for case, values in enumerate(cases):
        oracle = run(sys.argv[1], values)
        native = run(sys.argv[2], values)
        if oracle != native:
            raise SystemExit(
                f"byte-order mismatch in case {case}\n"
                f"values={values!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"byteorder-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
