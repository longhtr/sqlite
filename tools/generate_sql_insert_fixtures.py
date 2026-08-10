#!/usr/bin/env python3
"""Generate deterministic bounded INSERT scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-insert'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 cases=[{'name':'initial','rows':300},{'name':'literal','sql':"INSERT INTO t(id,v) VALUES(1000,x'aabb')"},{'name':'duplicate','sql':"INSERT INTO t(id,v) VALUES(1000,x'cc')"},{'name':'replace','sql':"INSERT OR REPLACE INTO t(id,v) VALUES(1000,x'cc')"},{'name':'bound-auto-rowid','sql':'INSERT INTO t(v) VALUES(?1)'}]
 doc={'schema_version':1,'phase':'phase-13-insert-slice','status':'bounded-regression-evidence','profile':'single-row-table-insert-v1','database':'tests/fixtures/btree-mutation/none-512.db','cases':cases,'case_count':5,'differential_observations':9,'durability':['DELETE/FULL generated-path fault rollback and continuation','WAL reader visibility and checkpoint','constraint leaves content unchanged','all prepare/bind/record/B-tree allocation sites']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-insert-fixtures: wrote INSERT profile')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
