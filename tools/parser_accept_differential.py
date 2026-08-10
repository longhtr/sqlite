#!/usr/bin/env python3
"""Compare prepare acceptance through C tokenizer and Zig-tokenizer/C-parser paths."""
import random, sys
import bounded_subprocess as subprocess

def run(w,items):return subprocess.run([w,*(x.hex() for x in items)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout

def cases():
 curated=[b'',b';',b'SELECT 1',b'SELECT 1+2*3;',b'SELECT .5e+2, x\'00ff\'',b'CREATE TABLE t(a INTEGER PRIMARY KEY,b TEXT)',b'WITH x(a) AS (VALUES(1)) SELECT a FROM x',b'SELECT sum(a) FILTER (WHERE a>0) OVER () FROM (VALUES(1)) AS x(a)',b'BEGIN; COMMIT;',b'SELECT',b'SELECT (1',b'CREATE TABLE',b'!',b'SELECT 1_000',b'SELECT /*unterminated',b'EXPLAIN QUERY PLAN SELECT 1',b'PRAGMA page_size',b'INSERT INTO missing VALUES(1)',b'\xef\xbb\xbfSELECT 1']
 out=[curated]
 atoms=['SELECT','1','NULL','(',')',',','+','-','*','/','FROM','WHERE','AND','OR','VALUES','AS',';','x',"'s'"]
 for seed in range(23):
  q=random.Random(seed);out.append([(' '.join(q.choice(atoms) for _ in range(q.randrange(0,30)))).encode() for _ in range(200)])
 return out

def main():
 for i,items in enumerate(cases()):
  a,b=run(sys.argv[1],items),run(sys.argv[2],items)
  if a!=b:raise SystemExit(f'parser acceptance mismatch {i}\nC={a.decode()}\nH={b.decode()}')
 print('parser-accept-differential: 24 isolated cases match')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
