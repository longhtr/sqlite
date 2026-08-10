#!/usr/bin/env python3
"""Compare the pinned C pcache/pcache1 workload with the native cache."""
import bounded_subprocess as subprocess
import sys

def run(path):
    result=subprocess.run([path],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if result.returncode:
        raise SystemExit(f"{path} failed ({result.returncode})\n{result.stdout}{result.stderr}")
    return (result.stdout or result.stderr).strip().splitlines()

def main():
    oracle=run(sys.argv[1]);native=run(sys.argv[2])
    if oracle!=native:
        raise SystemExit("page-cache differential mismatch\nC="+repr(oracle)+"\nZ="+repr(native))
    print(f"pcache-differential: {len(native)} state/dirty/stress/purge observations match")

if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
