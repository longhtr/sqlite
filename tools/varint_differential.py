#!/usr/bin/env python3
"""Compare pinned C and native Zig SQLite varint protocols."""

from __future__ import annotations

import random
import bounded_subprocess as subprocess
import sys


def run(worker: str, operations: list[str]) -> bytes:
    return subprocess.run(
        [worker, *operations],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout


def scenarios() -> list[list[str]]:
    boundaries = {
        0,
        1,
        0x7F,
        0x80,
        0x3FFF,
        0x4000,
        0x1FFFFF,
        0x200000,
        0x0FFFFFFF,
        0x10000000,
        0xFFFFFFFF,
        0x100000000,
        0x00FFFFFFFFFFFFFF,
        0x0100000000000000,
        0x7FFFFFFFFFFFFFFF,
        0x8000000000000000,
        0xFFFFFFFFFFFFFFFF,
    }
    result = [[*(f"v:{value}" for value in sorted(boundaries)),
               "x:800000000000000000", "x:818203aaaaaaaaaaaa",
               "x:ffffffffffffffffff"]]
    for seed in range(23):
        randomizer = random.Random(seed)
        operations: list[str] = []
        for _ in range(80):
            if randomizer.randrange(2) == 0:
                operations.append(f"v:{randomizer.getrandbits(64)}")
            else:
                data = bytes(randomizer.getrandbits(8) for _ in range(9))
                operations.append(f"x:{data.hex()}")
        result.append(operations)
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: varint_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for case, operations in enumerate(cases):
        oracle = run(sys.argv[1], operations)
        native = run(sys.argv[2], operations)
        if oracle != native:
            raise SystemExit(
                f"varint mismatch in case {case}\n"
                f"operations={operations!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"varint-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
