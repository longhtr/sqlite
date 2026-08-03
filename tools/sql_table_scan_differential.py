#!/usr/bin/env python3
"""Compare bounded table-scan scaffold observations against the C oracle."""
import bounded_subprocess as subprocess
import sys
def run(path):
 p=subprocess.run([path],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if p.returncode:raise SystemExit(f'{path} failed ({p.returncode})\n{p.stdout}\n{p.stderr}')
 return p.stdout.splitlines()
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: sql_table_scan_differential.py ORACLE NATIVE')
 oracle,native=map(run,sys.argv[1:])
 if oracle!=native:raise SystemExit(f'table scan mismatch\noracle={oracle[:8]!r}...\nnative={native[:8]!r}...')
 print(f'sql-table-scan-differential: {len(native)} schema/row/halt observations match')
if __name__=='__main__':main()
