#include "sqlite3.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int mutate(const char *path,const char *operations){
  sqlite3 *db=0; sqlite3_stmt *insert=0,*delete_stmt=0,*seed=0; FILE *file=0;
  unsigned char *payload=0; int payload_size=0; int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);
  if(rc==SQLITE_OK) rc=sqlite3_exec(db,"PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;BEGIN IMMEDIATE",0,0,0);
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"SELECT v FROM t WHERE id=1",-1,&seed,0);
  if(rc==SQLITE_OK && sqlite3_step(seed)==SQLITE_ROW){
    payload_size=sqlite3_column_bytes(seed,0); payload=sqlite3_malloc(payload_size?payload_size:1);
    if(!payload) rc=SQLITE_NOMEM; else if(payload_size) memcpy(payload,sqlite3_column_blob(seed,0),payload_size);
  }else if(rc==SQLITE_OK) rc=SQLITE_CORRUPT;
  sqlite3_finalize(seed);
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"INSERT INTO t(id,v) VALUES(?1,?2)",-1,&insert,0);
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"DELETE FROM t WHERE id=?1",-1,&delete_stmt,0);
  if(rc==SQLITE_OK && !(file=fopen(operations,"r"))) rc=SQLITE_CANTOPEN;
  char line[128];
  while(rc==SQLITE_OK && fgets(line,sizeof(line),file)){
    sqlite3_int64 id=strtoll(line+2,0,10); sqlite3_stmt *statement=line[0]=='I'?insert:delete_stmt;
    sqlite3_bind_int64(statement,1,id);
    if(line[0]=='I') sqlite3_bind_blob(statement,2,payload,payload_size,SQLITE_STATIC);
    if(sqlite3_step(statement)!=SQLITE_DONE || sqlite3_changes(db)!=1) rc=SQLITE_ERROR;
    sqlite3_reset(statement); sqlite3_clear_bindings(statement);
  }
  if(file) fclose(file); sqlite3_finalize(insert); sqlite3_finalize(delete_stmt); sqlite3_free(payload);
  if(rc==SQLITE_OK) rc=sqlite3_exec(db,"COMMIT",0,0,0); else sqlite3_exec(db,"ROLLBACK",0,0,0);
  sqlite3_close(db); return rc;
}

static int inspect(const char *path){
  sqlite3 *db=0; sqlite3_stmt *s=0; int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);
  sqlite3_int64 count=0,sum=0,min=0,max=0; int pages=0,free_pages=0;
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"SELECT count(*),coalesce(sum(id),0),coalesce(min(id),0),coalesce(max(id),0) FROM t",-1,&s,0);
  if(rc==SQLITE_OK && sqlite3_step(s)==SQLITE_ROW){count=sqlite3_column_int64(s,0);sum=sqlite3_column_int64(s,1);min=sqlite3_column_int64(s,2);max=sqlite3_column_int64(s,3);}else if(rc==SQLITE_OK)rc=SQLITE_ERROR;
  sqlite3_finalize(s);s=0;
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"PRAGMA page_count",-1,&s,0); if(rc==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW)pages=sqlite3_column_int(s,0);else if(rc==SQLITE_OK)rc=SQLITE_ERROR;sqlite3_finalize(s);s=0;
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"PRAGMA freelist_count",-1,&s,0); if(rc==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW)free_pages=sqlite3_column_int(s,0);else if(rc==SQLITE_OK)rc=SQLITE_ERROR;sqlite3_finalize(s);s=0;
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&s,0);
  if(rc==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW){const char *z=(const char*)sqlite3_column_text(s,0);if(!z||strcmp(z,"ok"))rc=SQLITE_CORRUPT;}else if(rc==SQLITE_OK)rc=SQLITE_ERROR;
  sqlite3_finalize(s);
  if(rc==SQLITE_OK) printf("state\t%lld\t%lld\t%lld\t%lld\t%d\t%d\tok\n",count,sum,min,max,pages,free_pages);
  sqlite3_close(db);return rc;
}

int main(int argc,char **argv){
  if(argc==3&&strcmp(argv[1],"inspect")==0)return inspect(argv[2]);
  if(argc==4&&strcmp(argv[1],"mutate")==0)return mutate(argv[2],argv[3]);
  fprintf(stderr,"usage: worker inspect DB | mutate DB OPS\n");return SQLITE_MISUSE;
}
