#!/usr/bin/env python3
"""Generate deterministic bounded Unix VFS scaffold fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parent.parent;OUT=ROOT/'tests/fixtures/unix-vfs'
def main():
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else OUT;out.mkdir(parents=True,exist_ok=True)
 doc={'schema_version':1,'phase':'phase-15-native-unix-vfs','status':'bounded-regression-evidence','profile':'linux-aarch64-btrfs-v1','target':{'os':'linux','arch':'aarch64','filesystem':'btrfs'},'unit_cases':['URI decoding and pathname','short read zero fill','pread and fsync override faults','mmap fetch/unfetch','OFD database lock contention','shared-memory map and lock','SIGKILL lock release','rollback pager commit','WAL pager commit and checkpoint'],'cross_process_cases':['native rollback writer to SQLite reader','native WAL writer to SQLite reader and stale-shm rebuild'],'cross_process_observations':2,'io_methods_version':3,'system_call_overrides':['open','pread','pwrite','fsync'],'durability_fixtures':['tests/fixtures/btree-mutation/none-512.db','tests/fixtures/wal/base-4096.db']}
 (out/'manifest.json').write_text(json.dumps(doc,indent=2)+'\n');print('generate-unix-vfs-fixtures: wrote native Unix VFS profile')
if __name__=='__main__':main()
