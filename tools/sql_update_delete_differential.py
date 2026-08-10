#!/usr/bin/env python3
"""Compare bounded UPDATE/DELETE scaffold observations against the C oracle."""
import bounded_subprocess as subprocess
import sys
def run(path):
 p=subprocess.run([path],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if p.returncode:raise SystemExit(f'{path} failed ({p.returncode})\n{p.stdout}\n{p.stderr}')
 return p.stdout.splitlines()
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: sql_update_delete_differential.py ORACLE NATIVE')
 oracle,native=map(run,sys.argv[1:])
 if oracle!=native:raise SystemExit(f'UPDATE/DELETE mismatch\noracle={oracle!r}\nnative={native!r}')
 print(f'sql-update-delete-differential: {len(native)} mutation/state observations match')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
