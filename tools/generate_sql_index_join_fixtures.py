#!/usr/bin/env python3
"""Generate deterministic bounded index/join scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-index-join'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-13-index-join-slice','status':'bounded-regression-evidence','profile':'covering-index-and-self-pk-join-v1','database':'tests/fixtures/btree-mutation/index-without-rowid-1024.db','queries':['SELECT v,id FROM t INDEXED BY t_v','SELECT id,id FROM t JOIN t USING(id)'],'rows_per_query':300,'differential_observations':604,'features':['covering index order','index record columns','bounded same-table primary-key USING join','generated cursor loop']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-index-join-fixtures: wrote index/join profile')
if __name__=='__main__':main()
