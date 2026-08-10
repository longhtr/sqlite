#!/usr/bin/env python3
"""Compare pinned C and native Zig SQLite string primitives."""

from __future__ import annotations

import random
import bounded_subprocess as subprocess
import sys


def encode(value: bytes | None) -> str:
    return "~" if value is None else value.hex()


def run(worker: str, cases: list[tuple[int, bytes | None, bytes | None]]) -> bytes:
    operations = [f"c:{count}:{encode(left)}:{encode(right)}" for count, left, right in cases]
    return subprocess.run(
        [worker, *operations],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout


def scenarios() -> list[list[tuple[int, bytes | None, bytes | None]]]:
    result = [[
        (0, None, None),
        (0, None, b""),
        (0, b"", None),
        (-4, b"abc", b"XYZ"),
        (2, b"abC", b"ABd"),
        (3, b"abC", b"ABd"),
        (20, b"SQLite", b"sQLITE"),
        (20, b"a", b"aa"),
        (20, bytes((0xC3, 0x80)), bytes((0xC3, 0xA0))),
        (20, b"abc\x00ignored", b"ABC\x00different"),
    ]]
    for seed in range(23):
        randomizer = random.Random(seed)
        cases: list[tuple[int, bytes | None, bytes | None]] = []
        for _ in range(160):
            count = randomizer.choice((-10, -1, 0, 1, 2, 5, 20, 100))
            values: list[bytes | None] = []
            for _side in range(2):
                if randomizer.randrange(20) == 0:
                    values.append(None)
                else:
                    length = randomizer.randrange(0, 80)
                    values.append(bytes(randomizer.randrange(0, 256) for _ in range(length)))
            cases.append((count, values[0], values[1]))
        result.append(cases)
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: string_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for case, inputs in enumerate(cases):
        oracle = run(sys.argv[1], inputs)
        native = run(sys.argv[2], inputs)
        if oracle != native:
            raise SystemExit(
                f"string mismatch in case {case}\n"
                f"inputs={inputs!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"string-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
