#!/usr/bin/env python3
"""Compare normalized DELETE/FULL durability events on oracle and memory VFS."""
import bounded_subprocess as subprocess
import sys
wanted={"journal-write","journal-sync","database-write","database-sync","journal-delete"}
def trace(worker):
 lines=subprocess.run([worker],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True).stdout.splitlines()
 result=[]
 for line in lines:
  event=line.split()[-1]
  if event in wanted and (not result or result[-1]!=event):result.append(event)
 return result
def main():
 oracle,native=trace(sys.argv[1]),trace(sys.argv[2])
 if oracle!=native:raise SystemExit(f'VFS trace mismatch\nC={oracle}\nZ={native}')
 expected=['journal-write','journal-sync','journal-write','journal-sync','database-write','database-sync','journal-delete']
 if native!=expected:raise SystemExit(f'unexpected normalized durability trace: {native}')
 print('vfs-trace-differential: normalized DELETE/FULL trace matches')
if __name__=='__main__':main()
