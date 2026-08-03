#!/usr/bin/env python3
"""Compare bounded planner scaffold observations against the C oracle."""
import bounded_subprocess as subprocess
import sys
import time
def run(path):
 start=time.monotonic();p=subprocess.run([path],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE);elapsed=time.monotonic()-start
 if p.returncode:raise SystemExit(f'{path} failed ({p.returncode})\n{p.stdout}\n{p.stderr}')
 return p.stdout.splitlines(),elapsed
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: sql_planner_differential.py ORACLE NATIVE')
 (oracle,oracle_s),(native,native_s)=map(run,sys.argv[1:])
 if oracle!=native:
  for i,(a,b) in enumerate(zip(oracle,native)):
   if a!=b:raise SystemExit(f'planner mismatch at {i}: oracle={a!r} native={b!r}')
  raise SystemExit(f'planner length mismatch: oracle={len(oracle)} native={len(native)}')
 if native_s>2.0:raise SystemExit(f'native planner corpus exceeded 2s budget: {native_s:.3f}s')
 print(f'sql-planner-differential: {len(native)} predicate/order/limit observations match; native {native_s:.3f}s')
if __name__=='__main__':main()
