#!/usr/bin/env python3
"""Compare pinned C and native Zig Hash operation/list protocols."""

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
    result: list[list[str]] = []
    result.append([
        "f:missing", "d:missing", "i:Alpha:1", "f:aLPHA",
        "i:ALPHA:2", "f:alpha", "d:AlPhA", "f:alpha",
    ])
    result.append([
        "i:one:1", "i:two:2", "i:three:3", "i:four:4", "i:five:5",
        "f:ONE", "i:TWO:22", "d:three", "i:six:6", "f:Three",
    ])

    operations = [f"i:key-{index:03d}:{index + 1}" for index in range(140)]
    operations.extend(f"f:KEY-{index:03d}" for index in range(0, 140, 7))
    operations.extend(f"d:key-{index:03d}" for index in range(0, 140, 5))
    operations.extend(f"i:KEY-{index:03d}:{1000 + index}" for index in range(1, 140, 9))
    result.append(operations)

    collision_groups: dict[int, list[str]] = {}
    for index in range(10_000):
        key = f"collision-{index}"
        hash_value = 0
        for byte in key.encode():
            hash_value = ((hash_value + (byte & 0xDF)) * 0x9E3779B1) & 0xFFFFFFFF
        collision_groups.setdefault(hash_value % 15, []).append(key)
    keys = max(collision_groups.values(), key=len)[:40]
    result.append([
        *(f"i:{key}:{index + 1}" for index, key in enumerate(keys)),
        *(f"f:{key.upper()}" for key in keys),
        *(f"d:{key}" for key in keys[::3]),
    ])

    for seed in range(20):
        randomizer = random.Random(seed)
        keys = [f"s{seed}-key-{index:02d}" for index in range(50)]
        operations = []
        next_value = 1
        for _ in range(180):
            operation = randomizer.choices(("i", "f", "d"), weights=(6, 3, 2))[0]
            key = randomizer.choice(keys)
            if randomizer.randrange(5) == 0:
                key = key.upper()
            if operation == "i":
                operations.append(f"i:{key}:{next_value}")
                next_value += 1
            else:
                operations.append(f"{operation}:{key}")
        result.append(operations)
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: hash_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for case, operations in enumerate(cases):
        oracle = run(sys.argv[1], operations)
        native = run(sys.argv[2], operations)
        if oracle != native:
            raise SystemExit(
                f"Hash mismatch in case {case}\n"
                f"operations={operations!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"hash-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    main()
