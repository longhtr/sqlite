#!/usr/bin/env python3
"""Compare the pinned C and native Zig BitVec operation protocols."""

from __future__ import annotations

import random
import bounded_subprocess as subprocess
import sys


def run(worker: str, size: int, operations: list[str]) -> bytes:
    return subprocess.run(
        [worker, str(size), *operations],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout


def scenarios() -> list[tuple[int, list[str]]]:
    result: list[tuple[int, list[str]]] = []
    result.append((400, [*(f"s:{i}" for i in range(1, 401)), "c:8", "t:0", "t:8", "t:9", "t:401"]))
    collisions = [1 + ordinal * 124 for ordinal in range(63)]
    result.append((100_000, [*(f"s:{i}" for i in collisions), *(f"t:{i}" for i in collisions), "c:125", "t:125"]))
    result.append((4_000, [*(f"s:{i}" for i in range(1, 4_001, 7)), *(f"c:{i}" for i in range(1, 4_001, 77))]))
    result.append((400_000, [*(f"s:{i}" for i in range(100_000, 105_000)), *(f"c:{i}" for i in range(1, 400_001, 997))]))

    for seed in range(20):
        randomizer = random.Random(seed)
        size = randomizer.choice((397, 3_968, 3_969, 5_000, 50_000, 400_000))
        operations: list[str] = []
        for _ in range(300):
            operation = randomizer.choices(("s", "c", "t"), weights=(6, 2, 3))[0]
            if operation == "t" and randomizer.randrange(10) == 0:
                index = randomizer.choice((0, size + 1))
            else:
                index = randomizer.randint(1, size)
            operations.append(f"{operation}:{index}")
        result.append((size, operations))
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: bitvec_differential.py C_WORKER ZIG_WORKER")
    for case, (size, operations) in enumerate(scenarios()):
        oracle = run(sys.argv[1], size, operations)
        native = run(sys.argv[2], size, operations)
        if oracle != native:
            raise SystemExit(
                f"BitVec mismatch in case {case}, size {size}\n"
                f"operations={operations!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"bitvec-differential: {len(scenarios())} isolated cases match")


if __name__ == "__main__":
    main()
