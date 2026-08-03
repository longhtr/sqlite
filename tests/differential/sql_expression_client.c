#include "sqlite3.h"
#include <stdio.h>
#include <string.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);
extern int sqlite3_zig_phase13_close(sqlite3*);
#endif
static void field(sqlite3_stmt*s,int i){int t=sqlite3_column_type(s,i),n,j;const unsigned char*z;if(t==SQLITE_NULL){printf("\tN");return;}if(t==SQLITE_INTEGER){printf("\tI:%lld",sqlite3_column_int64(s,i));return;}if(t==SQLITE_FLOAT){printf("\tR:%.15g",sqlite3_column_double(s,i));return;}z=sqlite3_column_blob(s,i);n=sqlite3_column_bytes(s,i);printf("\t%c:",t==SQLITE_TEXT?'T':'B');for(j=0;j<n;j++)printf("%02x",z[j]);}
static int run(sqlite3*db,const char*name,const char*sql,int bindings){sqlite3_stmt*s=0;const char*tail=0;int rc=sqlite3_prepare_v2(db,sql,-1,&s,&tail);if(rc!=SQLITE_OK){printf("%s\tprepare:%d\n",name,rc);return 1;}if(bindings){if(sqlite3_bind_parameter_count(s)!=2||sqlite3_bind_parameter_index(s,":x")!=2)return 1;sqlite3_bind_int(s,1,6);sqlite3_bind_text(s,2,"go",2,SQLITE_STATIC);}rc=sqlite3_step(s);if(rc!=SQLITE_ROW)return 1;printf("%s\trow",name);for(int i=0;i<sqlite3_column_count(s);i++)field(s,i);printf("\n%s\tnames",name);for(int i=0;i<sqlite3_column_count(s);i++)printf("\t%s",sqlite3_column_name(s,i));printf("\n%s\ttail:%s\n",name,tail);if(sqlite3_step(s)!=SQLITE_DONE)return 1;return sqlite3_finalize(s)!=SQLITE_OK;}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;
#endif
 if(!db)return 1;if(run(db,"scalar","SELECT 7+5, 'ab'||'cd', NULL, -3.5",0))return 1;if(run(db,"parameters","SELECT ?1*2, :x||'!'",1))return 1;if(run(db,"precedence","SELECT 2+3*4, (2+3)*4, NOT 0, NULL AND 0, NULL OR 1",0))return 1;if(run(db,"blob","SELECT x'00ff'",0))return 1;if(run(db,"tail","SELECT 8;SELECT 9",0))return 1;
#ifdef NATIVE_ENGINE
 if(sqlite3_zig_phase13_close(db)!=SQLITE_OK)return 1;
#else
 sqlite3_close(db);
#endif
 return 0;}
