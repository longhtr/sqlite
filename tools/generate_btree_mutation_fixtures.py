#!/usr/bin/env python3
"""Generate deterministic bounded reconstructed-B-tree mutation fixtures."""
from pathlib import Path
import hashlib,json,sqlite3,sys
ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'tests/fixtures/btree-mutation'

def create(path,page_size,mode):
    path.unlink(missing_ok=True)
    db=sqlite3.connect(path)
    db.execute(f'PRAGMA page_size={page_size}')
    db.execute(f'PRAGMA auto_vacuum={mode}')
    db.execute('PRAGMA journal_mode=OFF');db.execute('PRAGMA synchronous=OFF');db.execute('VACUUM')
    db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v BLOB)')
    rows=[]
    for i in range(1,301): rows.append((i,bytes([i&255])*(12000 if i==300 else 20+i%100)))
    db.executemany('INSERT INTO t VALUES(?,?)',rows);db.commit()
    root=db.execute("SELECT rootpage FROM sqlite_schema WHERE name='t'").fetchone()[0]
    integrity=db.execute('PRAGMA integrity_check').fetchone()[0];db.close()
    data=bytearray(path.read_bytes());data[96:100]=(3053004).to_bytes(4,'big');path.write_bytes(data)
    return {'name':path.name,'sha256':hashlib.sha256(data).hexdigest(),'size':len(data),'page_size':page_size,'auto_vacuum':mode.lower(),'root_page':root,'initial_ids':list(range(1,301)),'integrity_check':integrity}

def create_complex(path):
    path.unlink(missing_ok=True);db=sqlite3.connect(path)
    db.executescript("PRAGMA page_size=1024;PRAGMA auto_vacuum=NONE;VACUUM;CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT);CREATE INDEX t_v ON t(v,id);CREATE TABLE wr(k TEXT,n INTEGER,v BLOB,PRIMARY KEY(k,n)) WITHOUT ROWID;")
    db.executemany('INSERT INTO t VALUES(?,?)',[(i,f'v-{i:05d}') for i in range(1,301)])
    db.executemany('INSERT INTO wr VALUES(?,?,?)',[(f'k-{i%17:02d}',i,bytes([i&255])*(i%40)) for i in range(1,301)]);db.commit()
    roots={n:r for n,r in db.execute("SELECT name,rootpage FROM sqlite_schema WHERE name IN ('t_v','wr')")};db.close()
    data=bytearray(path.read_bytes());data[96:100]=(3053004).to_bytes(4,'big');path.write_bytes(data)
    return {'name':path.name,'sha256':hashlib.sha256(data).hexdigest(),'size':len(data),'page_size':1024,'index_root':roots['t_v'],'without_rowid_root':roots['wr']}

def main():
    out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
    for p in out.glob('*.db'):p.unlink()
    specs=[('none-512.db',512,'NONE'),('incremental-4096.db',4096,'INCREMENTAL'),('full-4096.db',4096,'FULL')]
    fixtures=[create(out/n,p,m) for n,p,m in specs]
    roundtrip=create_complex(out/'index-without-rowid-1024.db')
    manifest={'schema_version':1,'phase':'phase-9-btree-mutation','profile':'sqlite-3.53.4-table-index-freelist-autovacuum','generator':'tools/generate_btree_mutation_fixtures.py','seed':0x9B7EE,'fixtures':fixtures,'roundtrip_fixture':roundtrip}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'generate-btree-mutation-fixtures: wrote {len(fixtures)+1} fixtures')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
