#!/usr/bin/env python3
"""Generate deterministic bounded SQL expression scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-expression'
CASES=[
 {'name':'scalar','sql':"SELECT 7+5, 'ab'||'cd', NULL, -3.5"},
 {'name':'parameters','sql':"SELECT ?1*2, :x||'!'"},
 {'name':'precedence','sql':'SELECT 2+3*4, (2+3)*4, NOT 0, NULL AND 0, NULL OR 1'},
 {'name':'blob','sql':"SELECT x'00ff'"},
 {'name':'tail','sql':'SELECT 8;SELECT 9'},
]
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-13-expression-select-slice','status':'bounded-regression-evidence','profile':'expression-only-select-v1','cases':CASES,'case_count':5,'differential_observations':15,'prepare_symbols':['sqlite3_prepare','sqlite3_prepare_v2','sqlite3_prepare_v3','sqlite3_prepare16','sqlite3_prepare16_v2','sqlite3_prepare16_v3'],'operators':['unary +','unary -','NOT','*','/','%','+','-','||','AND','OR'],'values':['NULL','integer','real','text','blob','numbered parameter','named parameter']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-expression-fixtures: wrote 5 cases')
if __name__=='__main__':main()
