#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static int run(sqlite3*db,const char*tag,const char*sql){sqlite3_stmt*s=0;int rc=sqlite3_prepare_v2(db,sql,-1,&s,0),n=0;if(rc!=SQLITE_OK){printf("%s:prepare:%d\n",tag,rc);return 1;}printf("%s:columns:%d\n",tag,sqlite3_column_count(s));while((rc=sqlite3_step(s))==SQLITE_ROW){printf("%s:row:%lld:%s\n",tag,sqlite3_column_int64(s,0),sqlite3_column_count(s)>1?(const char*)sqlite3_column_text(s,1):"");n++;}printf("%s:done:%d:%d\n",tag,rc,n);return sqlite3_finalize(s)!=SQLITE_OK;}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open_v2("tests/fixtures/btree-mutation/none-512.db",&db,SQLITE_OPEN_READONLY,0)!=SQLITE_OK)return 1;
#endif
 const char*q[][3]={{"eq","SELECT id,v FROM t WHERE id = 42",0},{"ne","SELECT id FROM t WHERE id != 42 ORDER BY id DESC LIMIT 3",0},{"lt","SELECT id FROM t WHERE id < 3",0},{"le","SELECT id FROM t WHERE id <= 2",0},{"gt","SELECT id FROM t WHERE id > 298 ORDER BY id DESC",0},{"ge","SELECT id FROM t WHERE id >= 299",0},{"reverse","SELECT id FROM t ORDER BY id DESC LIMIT 3",0},{"zero","SELECT id FROM t ORDER BY id DESC LIMIT 0",0}};
 for(unsigned i=0;i<sizeof(q)/sizeof(q[0]);i++)if(run(db,q[i][0],q[i][1]))return 1;
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
