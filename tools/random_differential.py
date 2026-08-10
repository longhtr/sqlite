#!/usr/bin/env python3
"""Compare injected SQLite C and native Zig ChaCha PRNG state traces."""

from __future__ import annotations

import random
import bounded_subprocess as subprocess
import sys


def run(worker: str, entropy: bytes, operations: list[str]) -> bytes:
    return subprocess.run(
        [worker, entropy.hex(), *operations],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout


def scenarios() -> list[tuple[bytes, list[str]]]:
    result = [(bytes(range(44)), ["1", "2", "61", "64", "65", "s", "100", "r", "100", "0", "17"])]
    for seed in range(23):
        rng = random.Random(seed)
        entropy = bytes(rng.getrandbits(8) for _ in range(44))
        operations: list[str] = []
        saved = False
        for _ in range(80):
            choice = rng.randrange(20)
            if choice == 0:
                operations.append("0")
            elif choice == 1:
                operations.append("s")
                saved = True
            elif choice == 2 and saved:
                operations.append("r")
            else:
                operations.append(str(rng.randint(1, 256)))
        result.append((entropy, operations))
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: random_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for case, (entropy, operations) in enumerate(cases):
        oracle = run(sys.argv[1], entropy, operations)
        native = run(sys.argv[2], entropy, operations)
        if oracle != native:
            raise SystemExit(
                f"random mismatch in case {case}\noperations={operations!r}\n"
                f"oracle={oracle.decode(errors='replace')}\n"
                f"native={native.decode(errors='replace')}"
            )
    print(f"random-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
