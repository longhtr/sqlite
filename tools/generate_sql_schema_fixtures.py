#!/usr/bin/env python3
"""Generate deterministic bounded schema scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/sql-schema'
CASES=[
 {'name':'initial','sql':None,'expected_tables':1},
 {'name':'create','sql':'CREATE TABLE created(x INTEGER, y TEXT)','prepare':0,'step':101,'tables':2},
 {'name':'duplicate','sql':'CREATE TABLE created(x)','prepare':1,'tables':2},
 {'name':'if-not-exists','sql':'CREATE TABLE IF NOT EXISTS created(x)','prepare':0,'step':101,'tables':2},
 {'name':'drop','sql':'DROP TABLE created','prepare':0,'step':101,'tables':1},
 {'name':'missing','sql':'DROP TABLE created','prepare':1,'tables':1},
 {'name':'if-exists','sql':'DROP TABLE IF EXISTS created','prepare':0,'step':101,'tables':1},
 {'name':'malformed','sql':'CREATE TABLE broken(','prepare':1,'tables':1},
]
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-13-schema-simple-ddl-slice','status':'bounded-regression-evidence','profile':'create-drop-table-v1','cases':CASES,'case_count':8,'differential_observations':8,'durability':['DELETE/FULL transaction and rollback','WAL commit/read/checkpoint','open/lock/write/sync/delete faults','all allocation sites']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-sql-schema-fixtures: wrote 8 cases')
if __name__=='__main__':main()
