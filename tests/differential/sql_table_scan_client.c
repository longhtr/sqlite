#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);
extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static int scan(sqlite3*db,const char*sql){sqlite3_stmt*s=0;int rc=sqlite3_prepare_v2(db,sql,-1,&s,0),rows=0;if(rc!=SQLITE_OK){printf("prepare:%d\n",rc);return rc;}printf("columns:%d:%s:%s\n",sqlite3_column_count(s),sqlite3_column_name(s,0),sqlite3_column_name(s,1));while((rc=sqlite3_step(s))==SQLITE_ROW){const unsigned char*b=sqlite3_column_blob(s,1);int n=sqlite3_column_bytes(s,1);printf("row:%lld:%d:%02x:%02x\n",sqlite3_column_int64(s,0),n,n?b[0]:0,n?b[n-1]:0);rows++;}printf("done:%d:%d\n",rc,rows);return sqlite3_finalize(s);}
int main(void){sqlite3*db=0;sqlite3_stmt*s=0;int missing;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open_v2("tests/fixtures/btree-mutation/none-512.db",&db,SQLITE_OPEN_READONLY,0)!=SQLITE_OK)return 1;
#endif
 if(!db||scan(db,"SELECT id,v FROM t")!=SQLITE_OK)return 1;missing=sqlite3_prepare_v2(db,"SELECT id FROM missing",-1,&s,0);printf("missing:%d\n",missing);if(s)sqlite3_finalize(s);
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
