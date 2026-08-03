#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_index_connection(void);extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
int main(void){sqlite3*db=0;sqlite3_stmt*s=0;int rc,n=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_index_connection();
#else
 if(sqlite3_open_v2("tests/fixtures/btree-mutation/index-without-rowid-1024.db",&db,SQLITE_OPEN_READONLY,0)!=SQLITE_OK)return 1;
#endif
 rc=sqlite3_prepare_v2(db,"SELECT v,id FROM t ORDER BY v DESC LIMIT 4",-1,&s,0);printf("prepare:%d\n",rc);if(rc)return 1;
 printf("columns:%s:%s\n",sqlite3_column_name(s,0),sqlite3_column_name(s,1));while((rc=sqlite3_step(s))==SQLITE_ROW){printf("row:%s:%lld\n",sqlite3_column_text(s,0),sqlite3_column_int64(s,1));n++;}printf("done:%d:%d\n",rc,n);if(sqlite3_finalize(s))return 1;
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
