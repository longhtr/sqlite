#include "sqlite3.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int exec_sql(sqlite3 *db, const char *sql){
  char *error=0;
  int rc=sqlite3_exec(db,sql,0,0,&error);
  if(rc!=SQLITE_OK){ fprintf(stderr,"sql failed rc=%d: %s\n",rc,error?error:""); sqlite3_free(error); }
  return rc;
}

static int commit_value(const char *path, int value){
  sqlite3 *db=0; char sql[128]; int rc;
  rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);
  if(rc==SQLITE_OK) rc=exec_sql(db,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;");
  sqlite3_snprintf(sizeof(sql),sql,"PRAGMA user_version=%d",value);
  if(rc==SQLITE_OK) rc=exec_sql(db,sql);
  if(sqlite3_close(db)!=SQLITE_OK && rc==SQLITE_OK) rc=SQLITE_ERROR;
  return rc;
}

static int hot_value(const char *path, int value){
  sqlite3 *db=0; char sql[128]; int rc;
  rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);
  if(rc==SQLITE_OK) rc=exec_sql(db,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; BEGIN IMMEDIATE;");
  sqlite3_snprintf(sizeof(sql),sql,"PRAGMA user_version=%d",value);
  if(rc==SQLITE_OK) rc=exec_sql(db,sql);
  if(rc==SQLITE_OK) rc=sqlite3BtreeCommitPhaseOne(db->aDb[0].pBt,0);
  fflush(stdout); fflush(stderr);
  if(rc==SQLITE_OK) _Exit(0);
  sqlite3_close(db);
  return rc;
}

static int inspect(const char *path){
  sqlite3 *db=0; sqlite3_stmt *statement=0; int version=-1,rc;
  rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&statement,0);
  if(rc==SQLITE_OK && sqlite3_step(statement)==SQLITE_ROW) version=sqlite3_column_int(statement,0); else if(rc==SQLITE_OK) rc=SQLITE_ERROR;
  sqlite3_finalize(statement); statement=0;
  if(rc==SQLITE_OK) rc=sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&statement,0);
  if(rc==SQLITE_OK && sqlite3_step(statement)==SQLITE_ROW){
    const char *text=(const char*)sqlite3_column_text(statement,0);
    if(!text || strcmp(text,"ok")!=0) rc=SQLITE_CORRUPT;
  }else if(rc==SQLITE_OK) rc=SQLITE_ERROR;
  sqlite3_finalize(statement);
  if(rc==SQLITE_OK) printf("inspect\t%d\tok\n",version);
  sqlite3_close(db);
  return rc;
}

int main(int argc,char **argv){
  int rc=SQLITE_MISUSE;
  if(argc>=3 && strcmp(argv[1],"inspect")==0) rc=inspect(argv[2]);
  else if(argc>=4 && strcmp(argv[1],"commit")==0) rc=commit_value(argv[2],atoi(argv[3]));
  else if(argc>=4 && strcmp(argv[1],"hot")==0) rc=hot_value(argv[2],atoi(argv[3]));
  else fprintf(stderr,"usage: rollback-oracle (inspect|commit|hot) DB [VALUE]\n");
  return rc;
}
