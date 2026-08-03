#include "sqlite3.c"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int zig_phase7_cell(const unsigned char*, size_t, unsigned, sqlite3_int64,
                           unsigned, unsigned char*, size_t, size_t*);

static void zig_cell(sqlite3_context *context, int argc, sqlite3_value **argv){
  const unsigned char *db_bytes;
  unsigned char *output;
  size_t output_length=0;
  int db_length, rc;
  (void)argc;
  db_bytes=(const unsigned char*)sqlite3_value_blob(argv[0]);
  db_length=sqlite3_value_bytes(argv[0]);
  output=sqlite3_malloc64(65536);
  if(!output){ sqlite3_result_error_nomem(context); return; }
  rc=zig_phase7_cell(db_bytes,(size_t)db_length,(unsigned)sqlite3_value_int(argv[1]),
      sqlite3_value_int64(argv[2]),(unsigned)sqlite3_value_int(argv[3]),output,65536,&output_length);
  if(rc==SQLITE_OK) sqlite3_result_text(context,(char*)output,(int)output_length,sqlite3_free);
  else { sqlite3_free(output); sqlite3_result_error_code(context,rc); }
}

static unsigned char *read_file(const char *path, int *length){
  FILE *file=fopen(path,"rb"); unsigned char *bytes; long size;
  if(!file) return 0;
  if(fseek(file,0,SEEK_END)!=0){ fclose(file); return 0; }
  size=ftell(file); rewind(file);
  bytes=sqlite3_malloc64((sqlite3_uint64)size);
  if(!bytes){ fclose(file); return 0; }
  if(fread(bytes,1,(size_t)size,file)!=(size_t)size){ sqlite3_free(bytes); fclose(file); return 0; }
  fclose(file); *length=(int)size; return bytes;
}

static void append_hex(char **cursor, const unsigned char *data, int length){
  static const char hex[]="0123456789abcdef"; int i;
  for(i=0;i<length;i++){ *(*cursor)++=hex[data[i]>>4]; *(*cursor)++=hex[data[i]&15]; }
}
static void normalize_column(sqlite3_stmt *statement, int column, char *output){
  int type=sqlite3_column_type(statement,column); char *cursor=output;
  if(type==SQLITE_NULL){ *cursor++='N'; }
  else if(type==SQLITE_INTEGER){ sqlite3_snprintf(64,cursor,"I%lld",(long long)sqlite3_column_int64(statement,column)); cursor+=strlen(cursor); }
  else if(type==SQLITE_FLOAT){
    double real=sqlite3_column_double(statement,column); uint64_t bits; memcpy(&bits,&real,8);
    sqlite3_snprintf(32,cursor,"R%016llx",(unsigned long long)bits); cursor+=17;
  }else if(type==SQLITE_TEXT){
    const unsigned char *text=sqlite3_column_text(statement,column); int length=sqlite3_column_bytes(statement,column);
    *cursor++='T'; append_hex(&cursor,text,length);
  }else{
    const unsigned char *blob=sqlite3_column_blob(statement,column); int length=sqlite3_column_bytes(statement,column);
    *cursor++='B'; append_hex(&cursor,blob,length);
  }
  *cursor=0;
}

static int run_fixture(const char *fixture){
  char path[256],uri[320],expected[65536];
  sqlite3 *db=0; sqlite3_stmt *rows=0,*call=0,*root_stmt=0;
  unsigned char *bytes=0; int length=0,root=0,rc,column,step_rc=SQLITE_DONE;
  sqlite3_snprintf(sizeof(path),path,"tests/fixtures/btree/%s",fixture);
  bytes=read_file(path,&length); if(!bytes) return SQLITE_IOERR_READ;
  sqlite3_snprintf(sizeof(uri),uri,"file:%s?immutable=1",path);
  rc=sqlite3_open_v2(uri,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_URI,0);
  if(rc!=SQLITE_OK) goto done;
  rc=sqlite3_create_function(db,"zig_cell",4,SQLITE_UTF8|SQLITE_DETERMINISTIC,0,zig_cell,0,0);
  if(rc!=SQLITE_OK) goto done;
  rc=sqlite3_prepare_v2(db,"SELECT rootpage FROM sqlite_schema WHERE name='items'",-1,&root_stmt,0);
  if(rc==SQLITE_OK && sqlite3_step(root_stmt)==SQLITE_ROW) root=sqlite3_column_int(root_stmt,0); else rc=SQLITE_ERROR;
  sqlite3_finalize(root_stmt); root_stmt=0; if(rc!=SQLITE_OK) goto done;
  rc=sqlite3_prepare_v2(db,"SELECT id,i,r,t,b,z FROM items WHERE id IN(1,250,500,1099511627776) ORDER BY id",-1,&rows,0);
  if(rc!=SQLITE_OK) goto done;
  rc=sqlite3_prepare_v2(db,"SELECT zig_cell(?1,?2,?3,?4)",-1,&call,0);
  while(rc==SQLITE_OK && (step_rc=sqlite3_step(rows))==SQLITE_ROW){
    sqlite3_int64 rowid=sqlite3_column_int64(rows,0);
    for(column=0;column<6;column++){
      const unsigned char *actual; int actual_length;
      normalize_column(rows,column,expected);
      sqlite3_reset(call); sqlite3_clear_bindings(call);
      sqlite3_bind_blob(call,1,bytes,length,SQLITE_STATIC);
      sqlite3_bind_int(call,2,root);
      sqlite3_bind_int64(call,3,rowid);
      sqlite3_bind_int(call,4,column);
      if(sqlite3_step(call)!=SQLITE_ROW){ rc=sqlite3_errcode(db); break; }
      actual=sqlite3_column_text(call,0); actual_length=sqlite3_column_bytes(call,0);
      if((int)strlen(expected)!=actual_length || memcmp(expected,actual,(size_t)actual_length)!=0){
        fprintf(stderr,"hybrid mismatch %s row %lld column %d\nexpected %s\nactual %.*s\n",
            fixture,(long long)rowid,column,expected,actual_length,actual);
        rc=SQLITE_MISMATCH; break;
      }
    }
  }
  if(rc==SQLITE_OK && step_rc!=SQLITE_DONE) rc=step_rc;
 done:
  sqlite3_finalize(call); sqlite3_finalize(rows); sqlite3_finalize(root_stmt);
  sqlite3_close(db); sqlite3_free(bytes); return rc;
}

int main(void){
  static const char *fixtures[]={
    "core-512.db","utf16le-1024.db","utf16be-2048.db","autovacuum-4096.db",
    "autovacuum-full-8192.db","core-16384.db","core-32768.db","wide-65536.db"
  };
  size_t i; int rc=sqlite3_initialize();
  for(i=0;rc==SQLITE_OK && i<sizeof(fixtures)/sizeof(fixtures[0]);i++) rc=run_fixture(fixtures[i]);
  if(rc==SQLITE_OK) printf("phase7-hybrid-select\t192\tpass\n");
  sqlite3_shutdown(); return rc;
}
