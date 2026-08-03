#!/usr/bin/env python3
"""Compare bounded SQL index-planner scaffold observations against the C oracle."""
import bounded_subprocess as subprocess
import sys
import time
def run(p):
 t=time.monotonic();x=subprocess.run([p],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE);d=time.monotonic()-t
 if x.returncode:raise SystemExit(f'{p} failed\n{x.stdout}\n{x.stderr}')
 return x.stdout.splitlines(),d
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: sql_index_planner_differential.py ORACLE NATIVE')
 (a,_),(b,t)=map(run,sys.argv[1:])
 if a!=b:raise SystemExit(f'index planner mismatch\noracle={a!r}\nnative={b!r}')
 if t>2:raise SystemExit(f'index planner budget exceeded: {t:.3f}s')
 print(f'sql-index-planner-differential: {len(b)} covering-order observations match; native {t:.3f}s')
if __name__=='__main__':main()
