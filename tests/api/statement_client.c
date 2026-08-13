#include "sqlite3.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern sqlite3_stmt *sqlite3_zig_phase12_fixture(const char *name);
static sqlite3_stmt *g_stmt;
static int g_destructors;
static int g_reentrant_rc;
static void destroy_text(void *p){(void)p;g_destructors++;g_reentrant_rc=sqlite3_bind_int(g_stmt,1,77);}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void){
 sqlite3_stmt*s=sqlite3_zig_phase12_fixture("bindings");CHECK(s!=0);g_stmt=s;
 CHECK(sqlite3_bind_parameter_count(s)==4);CHECK(!strcmp(sqlite3_bind_parameter_name(s,2),"@text"));CHECK(sqlite3_bind_parameter_index(s,"$blob")==3);CHECK(sqlite3_bind_parameter_index(s,":missing")==0);
 CHECK(sqlite3_bind_double(s,1,1.5)==SQLITE_OK);CHECK(sqlite3_bind_int(s,1,3)==SQLITE_OK);CHECK(sqlite3_bind_int64(s,1,INT64_C(9007199254740993))==SQLITE_OK);
 CHECK(sqlite3_bind_text64(s,2,"temp",4,SQLITE_TRANSIENT,SQLITE_UTF8)==SQLITE_OK);unsigned char be[]={0,'x'};CHECK(sqlite3_bind_text64(s,2,(const char*)be,2,SQLITE_TRANSIENT,SQLITE_UTF16BE)==SQLITE_OK);char custom[]="hello";CHECK(sqlite3_bind_text(s,2,custom,-1,destroy_text)==SQLITE_OK);
 unsigned char blob[]={0,1,2,255};CHECK(sqlite3_bind_blob(s,3,blob,sizeof(blob),SQLITE_STATIC)==SQLITE_OK);CHECK(sqlite3_bind_blob64(s,3,blob,sizeof(blob),SQLITE_TRANSIENT)==SQLITE_OK);
 CHECK(sqlite3_bind_zeroblob64(s,4,3)==SQLITE_OK);uint16_t utf16[]={0x0068,0x00e9,0};CHECK(sqlite3_bind_text16(s,4,utf16,-1,SQLITE_STATIC)==SQLITE_OK);
 CHECK(sqlite3_stmt_readonly(s)==1);CHECK(sqlite3_stmt_isexplain(s)==0);CHECK(sqlite3_stmt_busy(s)==0);
 CHECK(sqlite3_step(s)==SQLITE_ROW);CHECK(sqlite3_stmt_busy(s)==1);CHECK(sqlite3_data_count(s)==4);CHECK(sqlite3_column_count(s)==4);
 CHECK(sqlite3_column_type(s,0)==SQLITE_INTEGER);CHECK(sqlite3_column_int64(s,0)==INT64_C(9007199254740993));CHECK(sqlite3_column_int(s,0)==1);CHECK(sqlite3_column_double(s,0)>9.0e15);CHECK(!strcmp((const char*)sqlite3_column_text(s,1),"hello"));CHECK(sqlite3_column_bytes(s,1)==5);
 CHECK(sqlite3_column_type(s,2)==SQLITE_BLOB);CHECK(sqlite3_column_bytes(s,2)==4);CHECK(!memcmp(sqlite3_column_blob(s,2),blob,4));CHECK(sqlite3_column_text16(s,3)!=0);CHECK(sqlite3_column_bytes16(s,3)==4);CHECK(!strcmp(sqlite3_column_name(s,1),"text"));
 char rejected[]="rejected";CHECK(sqlite3_bind_text(s,2,rejected,-1,destroy_text)==SQLITE_MISUSE);CHECK(g_destructors==1);CHECK(g_reentrant_rc==SQLITE_MISUSE);
 CHECK(sqlite3_step(s)==SQLITE_DONE);CHECK(sqlite3_stmt_busy(s)==0);CHECK(sqlite3_data_count(s)==0);CHECK(sqlite3_reset(s)==SQLITE_OK);
 CHECK(sqlite3_bind_text(s,2,"again",5,SQLITE_STATIC)==SQLITE_OK);CHECK(g_destructors==2);CHECK(g_reentrant_rc==SQLITE_MISUSE);
 CHECK(sqlite3_bind_int(s,0,1)==SQLITE_RANGE);CHECK(sqlite3_bind_blob(s,3,blob,-1,SQLITE_STATIC)==SQLITE_MISUSE);CHECK(sqlite3_bind_zeroblob(s,3,-1)==SQLITE_OK);CHECK(sqlite3_bind_zeroblob(s,3,2)==SQLITE_OK);CHECK(sqlite3_bind_null(s,4)==SQLITE_OK);
 CHECK(sqlite3_clear_bindings(s)==SQLITE_OK);CHECK(sqlite3_step(s)==SQLITE_ROW);for(int i=0;i<4;i++)CHECK(sqlite3_column_type(s,i)==SQLITE_NULL);CHECK(sqlite3_finalize(s)==SQLITE_OK);CHECK(sqlite3_finalize(0)==SQLITE_OK);
 sqlite3_stmt*e=sqlite3_zig_phase12_fixture("error");CHECK(e!=0);CHECK(sqlite3_step(e)==SQLITE_CONSTRAINT_UNIQUE);CHECK(sqlite3_finalize(e)==SQLITE_CONSTRAINT_UNIQUE);
 CHECK(sqlite3_step(0)==SQLITE_MISUSE);CHECK(sqlite3_reset(0)==SQLITE_OK);
 puts("statement-canonical-client\tpass");return 0;
}
