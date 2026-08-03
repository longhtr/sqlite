#include "sqlite3.h"
#include <stdio.h>
#ifdef NATIVE_ENGINE
extern sqlite3 *sqlite3_zig_phase13_connection(void);
extern int sqlite3_zig_phase13_close(sqlite3*);
extern int sqlite3_zig_phase13_schema_count(sqlite3*);
#endif
static int count_schema(sqlite3 *db){
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_schema_count(db);
#else
 sqlite3_stmt*s=0;int n=-1;if(sqlite3_prepare_v2(db,"SELECT count(*) FROM sqlite_schema WHERE type='table'",-1,&s,0)==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW)n=sqlite3_column_int(s,0);sqlite3_finalize(s);return n;
#endif
}
static void execute(sqlite3*db,const char*label,const char*sql){sqlite3_stmt*s=0;int p=sqlite3_prepare_v2(db,sql,-1,&s,0),ro=-1,step=-1,fin=-1;if(p==SQLITE_OK){ro=sqlite3_stmt_readonly(s);step=sqlite3_step(s);fin=sqlite3_finalize(s);}printf("%s\t%d\t%d\t%d\t%d\t%d\n",label,p,ro,step,fin,count_schema(db));}
int main(void){sqlite3*db=0;
#ifdef NATIVE_ENGINE
 db=sqlite3_zig_phase13_connection();
#else
 if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;sqlite3_exec(db,"CREATE TABLE t(id INTEGER)",0,0,0);
#endif
 if(!db)return 1;printf("initial\t%d\n",count_schema(db));execute(db,"create","CREATE TABLE created(x INTEGER, y TEXT)");execute(db,"duplicate","CREATE TABLE created(x)");execute(db,"if-not-exists","CREATE TABLE IF NOT EXISTS created(x)");execute(db,"drop","DROP TABLE created");execute(db,"missing","DROP TABLE created");execute(db,"if-exists","DROP TABLE IF EXISTS created");execute(db,"malformed","CREATE TABLE broken(");
#ifdef NATIVE_ENGINE
 return sqlite3_zig_phase13_close(db)!=SQLITE_OK;
#else
 return sqlite3_close(db)!=SQLITE_OK;
#endif
}
