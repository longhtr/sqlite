#include "sqlite3.h"
#include <stdio.h>
#include <string.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static void state(sqlite3*db,const char*tag){sqlite3_stmt*s=0;int n=0;long long max=0;unsigned hash=0;if(sqlite3_prepare_v2(db,"SELECT id,v FROM t",-1,&s,0)!=SQLITE_OK)return;while(sqlite3_step(s)==SQLITE_ROW){const unsigned char*b=sqlite3_column_blob(s,1);int z=sqlite3_column_bytes(s,1);long long id=sqlite3_column_int64(s,0);n++;if(id>max)max=id;for(int i=0;i<z;i++)hash=hash*33u+b[i];}sqlite3_finalize(s);printf("%s\t%d\t%lld\t%08x\n",tag,n,max,hash);}
static void run(sqlite3*db,const char*tag,const char*sql,int bind){sqlite3_stmt*s=0;int p=sqlite3_prepare_v2(db,sql,-1,&s,0),step=-1,fin=-1;if(p==SQLITE_OK){if(bind)sqlite3_bind_text(s,1,"bound",-1,SQLITE_STATIC);step=sqlite3_step(s);fin=sqlite3_finalize(s);}printf("%s\t%d\t%d\t%d\n",tag,p,step,fin);state(db,tag);}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;sqlite3_exec(db,"ATTACH 'tests/fixtures/btree-mutation/none-512.db' AS src; CREATE TABLE t(id INTEGER PRIMARY KEY,v BLOB); INSERT INTO t SELECT * FROM src.t; DETACH src",0,0,0);
#endif
 if(!db)return 1;state(db,"initial");run(db,"insert","INSERT INTO t(id,v) VALUES(1000,x'aabb')",0);run(db,"duplicate","INSERT INTO t(id,v) VALUES(1000,x'cc')",0);run(db,"replace","INSERT OR REPLACE INTO t(id,v) VALUES(1000,x'cc')",0);run(db,"bound","INSERT INTO t(v) VALUES(?1)",1);
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
