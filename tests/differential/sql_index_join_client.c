#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_index_connection(void);extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static int run(sqlite3*db,const char*tag,const char*sql){sqlite3_stmt*s=0;int rc=sqlite3_prepare_v2(db,sql,-1,&s,0),n=0;if(rc!=SQLITE_OK){printf("%s:prepare:%d\n",tag,rc);return 1;}printf("%s:columns:%s:%s\n",tag,sqlite3_column_name(s,0),sqlite3_column_name(s,1));while((rc=sqlite3_step(s))==SQLITE_ROW){printf("%s:%s:%lld\n",tag,sqlite3_column_text(s,0),sqlite3_column_int64(s,1));n++;}printf("%s:done:%d:%d\n",tag,rc,n);return sqlite3_finalize(s)!=SQLITE_OK;}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_index_connection();
#else
 if(sqlite3_open_v2("tests/fixtures/btree-mutation/index-without-rowid-1024.db",&db,SQLITE_OPEN_READONLY,0)!=SQLITE_OK)return 1;
#endif
 if(!db||run(db,"index","SELECT v,id FROM t INDEXED BY t_v")||run(db,"join","SELECT id,id FROM t JOIN t USING(id)"))return 1;
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
