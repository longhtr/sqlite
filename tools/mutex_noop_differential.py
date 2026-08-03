#!/usr/bin/env python3
"""Compare SQLite release-profile no-op mutex method table."""
from __future__ import annotations
import bounded_subprocess as subprocess
import sys

def output(executable: str) -> list[str]:
    result=subprocess.run([executable],text=True,capture_output=True,check=True)
    return (result.stdout+result.stderr).splitlines()

def main() -> None:
    if len(sys.argv)!=3: raise SystemExit("usage: mutex_noop_differential.py ORACLE NATIVE")
    oracle,native=output(sys.argv[1]),output(sys.argv[2])
    if len(oracle)!=5 or len(native)!=5: raise SystemExit(f"mutex-noop-differential: expected 5 observations, got oracle={len(oracle)} native={len(native)}")
    if oracle!=native:
        for index,(left,right) in enumerate(zip(oracle,native)):
            if left!=right: raise SystemExit(f"mutex-noop-differential: mismatch at observation {index}: oracle={left!r} native={right!r}")
        raise SystemExit("mutex-noop-differential: output length mismatch")
    print("mutex-noop-differential: 5 layout, callbacks, sentinel, try, and static-table observations match")
if __name__=="__main__": main()
