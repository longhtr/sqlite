#!/usr/bin/env python3
"""Compare bounded advanced-SQL scaffold observations against the C oracle."""
import bounded_subprocess as subprocess
import sys
def run(path):
 p=subprocess.run([path],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if p.returncode:raise SystemExit(f'{path} failed ({p.returncode})\n{p.stdout}\n{p.stderr}')
 return p.stdout.splitlines()
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: sql_advanced_differential.py ORACLE NATIVE')
 oracle,native=map(run,sys.argv[1:])
 if oracle!=native:raise SystemExit(f'advanced SQL mismatch\noracle={oracle!r}\nnative={native!r}')
 print(f'sql-advanced-differential: {len(native)} scoped advanced-family observations match')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
