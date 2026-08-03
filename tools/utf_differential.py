#!/usr/bin/env python3
"""Compare pinned C and native Zig pure UTF primitives."""

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
    values = [0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xFFFF,
              0x10000, 0x10FFFF, 0x110000, 0xFFFFFFFF]
    result = [[
        *(f"v:{value}" for value in values),
        "r:1:41", "r:2:c181", "r:3:e08280", "r:3:eda080",
        "r:3:efbfbe", "r:4:f09f9880", "r:2:80ff", "r:1:ff",
        "u:0:61003dd800de6200", "u:1:61003dd800de6200",
        "u:2:61003dd800de6200", "u:3:61003dd800de6200",
    ]]
    for seed in range(23):
        randomizer = random.Random(seed)
        operations: list[str] = []
        for _ in range(60):
            operations.append(f"v:{randomizer.getrandbits(32)}")
            data = bytes(randomizer.randrange(1, 256) for _ in range(randomizer.randrange(1, 30)))
            limit = randomizer.randint(1, len(data))
            operations.append(f"r:{limit}:{data.hex()}")
            utf16 = bytes(randomizer.getrandbits(8) for _ in range(randomizer.randrange(1, 30)))
            characters = randomizer.randrange(0, 20)
            operations.append(f"u:{characters}:{utf16.hex()}")
        result.append(operations)
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: utf_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for case, operations in enumerate(cases):
        oracle = run(sys.argv[1], operations)
        native = run(sys.argv[2], operations)
        if oracle != native:
            raise SystemExit(
                f"UTF mismatch in case {case}\n"
                f"operations={operations!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"utf-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    main()
