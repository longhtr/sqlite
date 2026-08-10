#!/usr/bin/env python3
"""Compare bounded WAL scaffold recovery and checkpoint observations."""
from pathlib import Path
import shutil, sys, tempfile
import bounded_subprocess as subprocess
ROOT=Path(__file__).resolve().parent.parent;BASE=ROOT/'tests/fixtures/wal/base-4096.db'
def run(c):
 r=subprocess.run(c,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if r.returncode:raise SystemExit(f"failed {r.returncode}: {' '.join(c)}\n{r.stdout}\n{r.stderr}")
 return (r.stdout or r.stderr).strip()
def inspect(o,p,v):
 x=run([o,'inspect',str(p)]);w=f'wal-inspect\t{v}\tok'
 if x!=w:raise SystemExit(f'{x!r}!={w!r}')
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: wal_differential.py ORACLE NATIVE')
 o,n=sys.argv[1:];obs=0
 with tempfile.TemporaryDirectory(prefix='sqlite-zig-phase10-') as td:
  td=Path(td)
  p=td/'oracle-native.db';shutil.copyfile(BASE,p);run([o,'write',str(p),'111']);assert Path(str(p)+'-wal').exists();obs+=1
  Path(str(p)+'-shm').unlink(missing_ok=True);x=run([n,'write',str(p),'222']);
  if x!='wal-native\t111':raise SystemExit(x)
  inspect(o,p,222);obs+=3
  x=run([n,'checkpoint',str(p),'333']);
  if x!='wal-native\t222':raise SystemExit(x)
  inspect(o,p,333);obs+=2
  p2=td/'native-crash.db';shutil.copyfile(BASE,p2);x=run([n,'crash',str(p2),'444']);
  if x!='wal-native\t0':raise SystemExit(x)
  inspect(o,p2,444);obs+=2
  p3=td/'stale-index.db';shutil.copyfile(BASE,p3);run([o,'write',str(p3),'555']);Path(str(p3)+'-shm').unlink(missing_ok=True);inspect(o,p3,555);obs+=2
  Path(str(p3)+'-shm').write_bytes(b'stale-index');Path(str(p3)+'-shm').unlink();x=run([n,'read',str(p3),'0']);
  if x!='wal-native\t555':raise SystemExit(x)
  obs+=2
 print(f'wal-differential: {obs} recovery/write/checkpoint/index observations match')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
