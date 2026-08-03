#!/usr/bin/env python3
"""Compare complete SQLite tokenizer streams."""
import pathlib, random, re, sys
import bounded_subprocess as subprocess
ROOT=pathlib.Path(__file__).resolve().parent.parent

def run(w,items):return subprocess.run([w,*(x.hex() for x in items)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout

def cases():
 curated=[b'',b' ',b'--x\nselect',b'/*x*/',b'/*',b'->>',b'!=',b'!',b'||',b'"a"',b'"a',b"'a''b'",b'[abc]',b'[abc',b'.1',b'1_2',b'0x12_ab',b'1.e+2x',b'?',b'?123',b'$abc::x(y)',b'$',b"x'00ff'",b"x'0'",b'\xef\xbb\xbfselect',b'\xefX',b'window x as',b'over(',b'filter(']
 text=(ROOT/'src/core/generated/keywords.zig').read_text();curated += [x.encode() for x in re.findall(r'\.name = "([A-Z_]+)"',text)]
 result=[curated+[bytes([x]) for x in range(256)]]
 for seed in range(23):
  q=random.Random(seed);result.append([bytes(q.randrange(256) for _ in range(q.randrange(0,100))) for _ in range(300)])
 return result

def main():
 for i,items in enumerate(cases()):
  a,b=run(sys.argv[1],items),run(sys.argv[2],items)
  if a!=b:raise SystemExit(f'tokenizer mismatch {i}\nC={a.decode(errors="replace")}\nZ={b.decode(errors="replace")}')
 print('tokenizer-differential: 24 isolated cases match')
if __name__=='__main__':main()
