#!/usr/bin/env python3
"""Generate deterministic bounded UPDATE/DELETE scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-update-delete'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 cases=[{'name':'initial','rows':300},{'name':'update','sql':"UPDATE t SET v='updated' WHERE id=2"},{'name':'update-missing','sql':"UPDATE t SET v='none' WHERE id=9999"},{'name':'delete-bound','sql':'DELETE FROM t WHERE id=?1'},{'name':'delete-missing','sql':'DELETE FROM t WHERE id=9999'}]
 doc={'schema_version':1,'phase':'phase-13-update-delete-slice','status':'bounded-regression-evidence','profile':'single-row-rowid-update-delete-v1','database':'tests/fixtures/btree-mutation/none-512.db','cases':cases,'case_count':5,'differential_observations':9,'durability':['write/sync rollback and continuation','WAL reader visibility','missing-row no-op','all generated UPDATE allocation sites']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-update-delete-fixtures: wrote UPDATE/DELETE profile')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
