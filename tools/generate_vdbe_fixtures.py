#!/usr/bin/env python3
"""Generate deterministic bounded handwritten-VDBE scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/vdbe'
PROGRAMS=[
 {'name':'scalar','oracle_sql':"SELECT 7+5,7-5,7*5,7/5,7%5,'ab'||'cd',NOT 0,NULL AND 0,NULL OR 1",'classes':['register','arithmetic','null','result','halt']},
 {'name':'cursor','oracle_sql':"WITH t(id,v) AS (VALUES(1,'one'),(3,'three'),(5,'five')) SELECT id,v FROM t ORDER BY id",'classes':['cursor','rewind','column','next','resume']},
 {'name':'function','oracle_sql':"SELECT abs(-9),length('zig'),NULL,coalesce(NULL,'fallback')",'classes':['callback','jump','null','text']},
 {'name':'frame','oracle_sql':'SELECT 42,42+8','classes':['subprogram','frame','return','register']},
 {'name':'comparison','oracle_sql':'SELECT 7=7,7>5,NULL','classes':['comparison','jump','null']},
 {'name':'cast','oracle_sql':"SELECT CAST('42' AS TEXT),CAST('42' AS REAL),CAST('42' AS BLOB)",'classes':['affinity','cast','encoding']},
 {'name':'seek','oracle_sql':"WITH t(id,v) AS (VALUES(1,'one'),(3,'three'),(5,'five')) SELECT id,v,(SELECT count(*) FROM t) FROM t WHERE id=3",'classes':['cursor','seek','count']},
 {'name':'coroutine','oracle_sql':'SELECT 10 UNION ALL SELECT 20','classes':['coroutine','yield','resume','end']},
 {'name':'extended','oracle_sql':"SELECT ~5,NULL IS TRUE,NULL IS NOT TRUE,CAST('42' AS INTEGER)",'classes':['bit-not','is-true','cast','null']},
 {'name':'cursor_state','oracle_sql':"SELECT a.x,b.y FROM (SELECT 1 x UNION ALL SELECT 2 ORDER BY x) a LEFT JOIN (SELECT 1 x,'one' y) b ON a.x=b.x ORDER BY a.x",'classes':['if-empty','sequence','null-row','if-null-row','if-not-open']},
 {'name':'variable','oracle_sql':'SELECT ?1,?2,?3','classes':['binding','variable','text','integer','null']},
 {'name':'record','oracle_sql':'internal VDBE MakeRecord fixture','classes':['make-record','serial-type','header','payload','blob']},
 {'name':'rowset','oracle_sql':'internal VDBE RowSetAdd/RowSetRead fixture','classes':['row-set-add','row-set-read','sort','duplicate-removal','mem-destructor']},
 {'name':'rowset_test','oracle_sql':'internal VDBE RowSetTest fixture','classes':['row-set-test','batch-visibility','jump','mem-destructor']},
 {'name':'error','oracle_sql':'UNIQUE constraint violation fixture','classes':['error','halt','constraint','sticky-state']},
]
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-11-vdbe-core','profile':'handcrafted-oracle-derived-v1','program_count':len(PROGRAMS),'observation_count':53,'programs':PROGRAMS,'native_only_classes':['gosub','destructor','interrupt','progress','instruction-limit','malformed-program','btree-cursor','oom']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print(f'generate-vdbe-fixtures: wrote {len(PROGRAMS)} programs')
if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
