#!/usr/bin/env python3
"""Generate deterministic bounded advanced-SQL scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-advanced'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 cases=[{'family':'upsert','sql':"INSERT INTO t(id,v) VALUES(1,'ignored') ON CONFLICT DO NOTHING"},{'family':'window','sql':'SELECT row_number() OVER ()'},{'family':'pragma','sql':'PRAGMA user_version'},{'family':'vacuum','sql':'VACUUM'}]
 doc={'schema_version':1,'phase':'phase-13-scoped-advanced-slice','status':'bounded-regression-evidence','profile':'upsert-window-pragma-vacuum-v1','cases':cases,'case_count':4,'differential_observations':4,'deferred_to_phase17':['persistent views and triggers','ATTACH/DETACH connection topology','general window frames','writable pragmas','non-empty-freelist VACUUM']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-advanced-fixtures: wrote advanced profile')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
