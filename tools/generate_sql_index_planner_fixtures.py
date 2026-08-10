#!/usr/bin/env python3
"""Generate deterministic bounded index-planner scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-index-planner'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-14-index-order-slice','status':'bounded-regression-evidence','profile':'covering-order-cost-v1','database':'tests/fixtures/btree-mutation/index-without-rowid-1024.db','cases':[{'name':'covering-reverse-limit','sql':'SELECT v,id FROM t ORDER BY v DESC LIMIT 4','normalized_plan':'covering-index-last-prev-limit','selected_index':'t_v','temporary_sort':False}],'case_count':1,'differential_observations':7,'native_runtime_budget_seconds':2.0,'planner_decisions':['persistent covering index selected automatically by schema candidate name','row count retained from native B-tree cursor statistics','temporary sorting avoided','automatic ephemeral index suppressed because a covering persistent index exists']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-index-planner-fixtures: wrote index planner profile')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
