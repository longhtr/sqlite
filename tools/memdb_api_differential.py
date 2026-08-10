#!/usr/bin/env python3
"""Compare public memdb serialization ownership and continuation with pinned SQLite."""
import sys

import bounded_subprocess as subprocess


def run(path):
    process = subprocess.run([path], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if process.returncode:
        raise SystemExit(f"{path} failed ({process.returncode})\n{process.stdout}\n{process.stderr}")
    return process.stdout.splitlines()


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: memdb_api_differential.py ORACLE NATIVE")
    oracle, native = map(run, sys.argv[1:])
    if oracle != native:
        raise SystemExit(f"memdb API mismatch\noracle={oracle!r}\nnative={native!r}")
    print(f"memdb-api-differential: {len(native)} ownership, flag, malformed, and continuation observations match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
