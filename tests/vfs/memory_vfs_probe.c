#include "sqlite3.h"
#include <stdio.h>
#include <string.h>
extern void sqlite_zig_vfs_reset_trace(void);
extern int sqlite_zig_vfs_trace(char*,int);
static int count_one(void *p,int n,char**v,char**c){(void)c;if(n!=1||!v[0]||strcmp(v[0],"1"))return 1;*(int*)p=1;return 0;}
int run_memory_vfs_probe(sqlite3_vfs *vfs){
  sqlite3_file *f=0;sqlite3 *db=0;char *err=0;char path[128],buf[8];sqlite3_int64 size=0;int out=0,flags=0,seen=0,rc,n;char trace[8192];
  if(sizeof(sqlite3_vfs)!=168||sizeof(sqlite3_io_methods)!=152)return 1;
  if(vfs->iVersion!=3||!vfs->xCurrentTimeInt64||!vfs->xNextSystemCall)return 2;
  if(sqlite3_vfs_register(vfs,0)!=SQLITE_OK)return 3;
  if(sqlite3_vfs_find("sqlite-zig-memory")!=vfs)return 4;
  if(vfs->xFullPathname(vfs,"core-file",sizeof(path),path)!=SQLITE_OK||strcmp(path,"core-file"))return 5;
  f=(sqlite3_file*)sqlite3_malloc(vfs->szOsFile);memset(f,0,vfs->szOsFile);
  if(vfs->xOpen(vfs,"core-file",f,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_MAIN_DB,&flags)!=SQLITE_OK)return 6;
  if(!f->pMethods||f->pMethods->iVersion!=3||!f->pMethods->xFetch||!f->pMethods->xShmMap)return 7;
  if(f->pMethods->xWrite(f,"abc",3,0)!=SQLITE_OK)return 8;
  memset(buf,0xcc,sizeof(buf));if(f->pMethods->xRead(f,buf,5,0)!=SQLITE_IOERR_SHORT_READ)return 9;
  if(memcmp(buf,"abc\0\0",5))return 10;
  if(f->pMethods->xFileSize(f,&size)!=SQLITE_OK||size!=3)return 11;
  if(f->pMethods->xTruncate(f,2)!=SQLITE_OK||f->pMethods->xSync(f,SQLITE_SYNC_NORMAL)!=SQLITE_OK)return 12;
  if(f->pMethods->xClose(f)!=SQLITE_OK)return 13;sqlite3_free(f);
  if(vfs->xAccess(vfs,"core-file",SQLITE_ACCESS_EXISTS,&out)!=SQLITE_OK||!out)return 14;
  if(vfs->xDelete(vfs,"core-file",1)!=SQLITE_OK)return 15;
  if(vfs->xAccess(vfs,"core-file",SQLITE_ACCESS_EXISTS,&out)!=SQLITE_OK||out)return 16;
  rc=sqlite3_open_v2("phase4.db",&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,"sqlite-zig-memory");if(rc!=SQLITE_OK)return 17;
  rc=sqlite3_exec(db,"PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;CREATE TABLE t(x);",0,0,&err);if(rc!=SQLITE_OK){fprintf(stderr,"setup: %s\n",err);return 18;}
  sqlite_zig_vfs_reset_trace();
  rc=sqlite3_exec(db,"BEGIN;INSERT INTO t VALUES(1);COMMIT;",0,0,&err);if(rc!=SQLITE_OK){fprintf(stderr,"transaction: %s\n",err);return 19;}
  if(sqlite3_exec(db,"SELECT count(*) FROM t",count_one,&seen,&err)!=SQLITE_OK||!seen)return 20;
  n=sqlite_zig_vfs_trace(trace,sizeof(trace));if(n<0)return 21;fwrite(trace,1,(size_t)n,stdout);
  if(sqlite3_close(db)!=SQLITE_OK)return 22;
  if(sqlite3_vfs_unregister(vfs)!=SQLITE_OK)return 23;
  return 0;
}
