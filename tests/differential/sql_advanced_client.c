#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static void execdone(sqlite3*db,const char*tag,const char*sql){sqlite3_stmt*s=0;int p=sqlite3_prepare_v2(db,sql,-1,&s,0),st=-1,fin=-1;if(p==0){st=sqlite3_step(s);fin=sqlite3_finalize(s);}printf("%s:%d:%d:%d\n",tag,p,st,fin);}
static void row(sqlite3*db,const char*tag,const char*sql){sqlite3_stmt*s=0;int p=sqlite3_prepare_v2(db,sql,-1,&s,0),st=-1;long long v=-1;if(p==0){st=sqlite3_step(s);if(st==100)v=sqlite3_column_int64(s,0);sqlite3_finalize(s);}printf("%s:%d:%d:%lld\n",tag,p,st,v);}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open(":memory:",&db)!=0)return 1;sqlite3_exec(db,"ATTACH 'tests/fixtures/btree-mutation/none-512.db' AS src; CREATE TABLE t(id INTEGER PRIMARY KEY,v BLOB); INSERT INTO t SELECT * FROM src.t; DETACH src",0,0,0);
#endif
 if(!db)return 1;execdone(db,"upsert","INSERT INTO t(id,v) VALUES(1,'ignored') ON CONFLICT DO NOTHING");row(db,"window","SELECT row_number() OVER ()");row(db,"pragma","PRAGMA user_version");execdone(db,"vacuum","VACUUM");
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=0;
#else
 return sqlite3_close(db)!=0;
#endif
}
