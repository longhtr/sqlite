#!/usr/bin/env python3
"""Generate deterministic bounded planner scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-planner'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 cases=[('eq-seek','SELECT id,v FROM t WHERE id = 42','seek-rowid'),('ne-reverse-limit','SELECT id FROM t WHERE id != 42 ORDER BY id DESC LIMIT 3','last-filter-prev-limit'),('lt','SELECT id FROM t WHERE id < 3','rewind-filter-next'),('le','SELECT id FROM t WHERE id <= 2','rewind-filter-next'),('gt-reverse','SELECT id FROM t WHERE id > 298 ORDER BY id DESC','last-filter-prev'),('ge','SELECT id FROM t WHERE id >= 299','rewind-filter-next'),('reverse-limit','SELECT id FROM t ORDER BY id DESC LIMIT 3','last-prev-limit'),('zero-limit','SELECT id FROM t ORDER BY id DESC LIMIT 0','constant-empty')]
 doc={'schema_version':1,'phase':'phase-14-rowid-planner-slice','status':'bounded-regression-evidence','profile':'rowid-predicate-order-limit-v1','database':'tests/fixtures/btree-mutation/none-512.db','cases':[{'name':n,'sql':s,'normalized_plan':p} for n,s,p in cases],'case_count':len(cases),'differential_observations':31,'native_runtime_budget_seconds':2.0}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-planner-fixtures: wrote rowid planner profile')
if __name__=='__main__':main()
