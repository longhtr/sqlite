#!/usr/bin/env python3
"""Generate deterministic bounded WAL scaffold fixtures."""
from pathlib import Path
import sqlite3,hashlib,json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/wal'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True);p=out/'base-4096.db'
 for q in (p,Path(str(p)+'-wal'),Path(str(p)+'-shm')):q.unlink(missing_ok=True)
 db=sqlite3.connect(p);db.execute('PRAGMA page_size=4096');db.execute('PRAGMA journal_mode=WAL');db.execute('PRAGMA synchronous=FULL');db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT)');db.executemany('INSERT INTO t(v) VALUES(?)',[(f'v-{i}',) for i in range(20)]);db.commit();db.close();data=bytearray(p.read_bytes());data[96:100]=(3053004).to_bytes(4,'big');p.write_bytes(data)
 m={'schema_version':1,'phase':'phase-10-wal','profile':'sqlite-3.53.4-wal-full-4096','generator':'tools/generate_wal_fixtures.py','fixtures':[{'name':p.name,'size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'page_size':4096,'read_version':data[19],'write_version':data[18]}],'events':['header-write','header-sync','frame-header-write','frame-page-write','wal-sync','index-publish','checkpoint-db-write','checkpoint-db-sync','wal-reset']}
 (out/'manifest.json').write_text(json.dumps(m,indent=2)+'\n');print('generate-wal-fixtures: wrote 1 fixture')
if __name__=='__main__':main()
