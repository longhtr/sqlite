#!/usr/bin/env python3
"""Compare allocator, lookaside, mutex, and initialization traces."""

import random
import bounded_subprocess as subprocess
import sys


def run(worker: str, operations: list[str]) -> bytes:
    return subprocess.run([worker, *operations], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: infrastructure_differential.py C_WORKER ZIG_WORKER")
    cases = [["memory", "allocator", "lookaside", "mutex", "methods", "global", "memdb"]]
    for seed in range(23):
        operations = ["memory", "allocator", "lookaside", "mutex", "methods", "global", "memdb"]
        random.Random(seed).shuffle(operations)
        cases.append(operations)
    for index, operations in enumerate(cases):
        oracle = run(sys.argv[1], operations)
        native = run(sys.argv[2], operations)
        if oracle != native:
            raise SystemExit(
                f"infrastructure mismatch {index}: {operations!r}\n"
                f"C={oracle.decode(errors='replace')}\nZ={native.decode(errors='replace')}"
            )
    print(f"infrastructure-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
