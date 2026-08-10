#!/usr/bin/env python3
"""Compare the native registered built-in subset with the pinned C topology."""

import sys
import bounded_subprocess as subprocess


def run(worker: str) -> bytes:
    return subprocess.run([worker], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: builtin_registry_differential.py C_WORKER ZIG_WORKER")
    oracle = run(sys.argv[1])
    native = run(sys.argv[2])
    if oracle != native:
        raise SystemExit(
            "built-in registry topology mismatch\n"
            f"C={oracle.decode(errors='replace')}\nZ={native.decode(errors='replace')}"
        )
    count = len(native.splitlines())
    if count != 167:
        raise SystemExit(f"built-in registry emitted {count} definitions, expected 167")
    print("builtin-registry-differential: 167 definitions match exact hash and overload topology")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
