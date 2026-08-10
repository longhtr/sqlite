#!/usr/bin/env python3
"""Generate deterministic bounded table-scan scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-table-scan'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-13-table-scan-select-slice','status':'bounded-regression-evidence','profile':'single-table-full-scan-v1','database':'tests/fixtures/btree-mutation/none-512.db','schema':'CREATE TABLE t(id INTEGER PRIMARY KEY,v BLOB)','queries':['SELECT id,v FROM t','SELECT v,id FROM t','SELECT * FROM t'],'row_count':300,'differential_observations':303,'features':['sqlite_schema lookup','column resolution','INTEGER PRIMARY KEY rowid alias','star expansion','OpenRead/Rewind/Column/Rowid/Next/ResultRow/Halt']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-table-scan-fixtures: wrote table-scan profile')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
