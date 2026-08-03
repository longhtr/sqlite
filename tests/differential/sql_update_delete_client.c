#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static void state(sqlite3*db,const char*tag){sqlite3_stmt*s=0;int n=0;long long sum=0;unsigned h=0;sqlite3_prepare_v2(db,"SELECT id,v FROM t",-1,&s,0);while(sqlite3_step(s)==SQLITE_ROW){const unsigned char*b=sqlite3_column_blob(s,1);int z=sqlite3_column_bytes(s,1);n++;sum+=sqlite3_column_int64(s,0);for(int i=0;i<z;i++)h=h*33u+b[i];}sqlite3_finalize(s);printf("%s\t%d\t%lld\t%08x\n",tag,n,sum,h);}
static void run(sqlite3*db,const char*tag,const char*sql,int bind){sqlite3_stmt*s=0;int p=sqlite3_prepare_v2(db,sql,-1,&s,0),step=-1,fin=-1;if(p==SQLITE_OK){if(bind)sqlite3_bind_int(s,1,2);step=sqlite3_step(s);fin=sqlite3_finalize(s);}printf("%s\t%d\t%d\t%d\n",tag,p,step,fin);state(db,tag);}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;sqlite3_exec(db,"ATTACH 'tests/fixtures/btree-mutation/none-512.db' AS src; CREATE TABLE t(id INTEGER PRIMARY KEY,v BLOB); INSERT INTO t SELECT * FROM src.t; DETACH src",0,0,0);
#endif
 if(!db)return 1;state(db,"initial");run(db,"update","UPDATE t SET v='updated' WHERE id=2",0);run(db,"update-missing","UPDATE t SET v='none' WHERE id=9999",0);run(db,"delete","DELETE FROM t WHERE id=?1",1);run(db,"delete-missing","DELETE FROM t WHERE id=9999",0);
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
