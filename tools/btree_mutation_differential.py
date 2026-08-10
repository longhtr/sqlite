#!/usr/bin/env python3
"""Compare bounded reconstructed-B-tree mutation, continuation, integrity, and graph observations."""
from pathlib import Path
import json, random, shutil, sys, tempfile
import bounded_subprocess as subprocess
ROOT=Path(__file__).resolve().parent.parent
MANIFEST=json.loads((ROOT/'tests/fixtures/btree-mutation/manifest.json').read_text())

def run(cmd):
 r=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if r.returncode: raise SystemExit(f"failed {r.returncode}: {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
 return (r.stdout or r.stderr).strip()

def batch(ids,seed,count=36):
 r=random.Random(seed);ops=[];next_id=1000+seed%100000
 for _ in range(count):
  candidates=sorted(ids-{1})
  if candidates and r.random()<.48:
   value=r.choice(candidates);ids.remove(value);ops.append(f'D {value}')
  else:
   while next_id in ids:next_id+=1
   ids.add(next_id);ops.append(f'I {next_id}');next_id+=1+r.randrange(3)
 return ops

def write_ops(path,ops):path.write_text('\n'.join(ops)+'\n')
def check(oracle,path,ids):
 out=run([oracle,'inspect',str(path)]);fields=out.split('\t')
 expected=['state',str(len(ids)),str(sum(ids)),str(min(ids) if ids else 0),str(max(ids) if ids else 0)]
 if fields[:5]!=expected or fields[-1]!='ok':raise SystemExit(f'state mismatch {out!r} expected {expected}')
 return out

def main():
 if len(sys.argv)!=3:raise SystemExit('usage: btree_mutation_differential.py ORACLE NATIVE')
 oracle,native=sys.argv[1:];observations=0
 with tempfile.TemporaryDirectory(prefix='sqlite-zig-phase9-') as td:
  td=Path(td)
  for fi,fixture in enumerate(MANIFEST['fixtures']):
   source=ROOT/'tests/fixtures/btree-mutation'/fixture['name']
   for direction in range(2):
    db=td/f'{fi}-{direction}.db';shutil.copyfile(source,db);ids=set(fixture['initial_ids'])
    op1=batch(ids,MANIFEST['seed']+fi*101+direction*17);p1=td/f'{fi}-{direction}-1.ops';write_ops(p1,op1)
    if direction==0:run([oracle,'mutate',str(db),str(p1)])
    else:run([native,str(db),str(fixture['root_page']),str(p1)])
    check(oracle,db,ids);observations+=1
    op2=batch(ids,MANIFEST['seed']+fi*211+direction*29+7);p2=td/f'{fi}-{direction}-2.ops';write_ops(p2,op2)
    if direction==0:run([native,str(db),str(fixture['root_page']),str(p2)])
    else:run([oracle,'mutate',str(db),str(p2)])
    check(oracle,db,ids);observations+=1
    if Path(str(db)+'-journal').exists():raise SystemExit('acknowledged batch left journal')
    observations+=1
  roundtrip=MANIFEST['roundtrip_fixture'];source=ROOT/'tests/fixtures/btree-mutation'/roundtrip['name'];ops=td/'roundtrip.ops';write_ops(ops,['R'])
  for label,root in (('index',roundtrip['index_root']),('without-rowid',roundtrip['without_rowid_root'])):
   db=td/f'{label}.db';shutil.copyfile(source,db)
   run([native,str(db),str(root),str(ops)]);check(oracle,db,set(range(1,301)));observations+=1
   if Path(str(db)+'-journal').exists():raise SystemExit('index roundtrip left journal')
   observations+=1
 print(f'btree-mutation-differential: {len(MANIFEST["fixtures"])+1} partitions and {observations} batch observations match')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
