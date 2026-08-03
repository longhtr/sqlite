#include "sqlite3.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int exec_sql(sqlite3 *db,const char *sql){char *z=0;int rc=sqlite3_exec(db,sql,0,0,&z);if(rc){fprintf(stderr,"%s\n",z?z:"");sqlite3_free(z);}return rc;}
static int write_value(const char *path,int value,int abrupt){
 sqlite3 *db=0;char sql[100];int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);
 if(rc==SQLITE_OK)rc=exec_sql(db,"PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;PRAGMA wal_autocheckpoint=0;BEGIN IMMEDIATE;");
 sqlite3_snprintf(sizeof(sql),sql,"PRAGMA user_version=%d",value);if(rc==SQLITE_OK)rc=exec_sql(db,sql);if(rc==SQLITE_OK)rc=exec_sql(db,"COMMIT");
 fflush(stdout);fflush(stderr);if(rc==SQLITE_OK&&abrupt)_Exit(0);sqlite3_close(db);return rc;
}
static int inspect(const char *path){sqlite3 *db=0,*unused=0;sqlite3_stmt *s=0;int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0),value=-1;
 if(rc==SQLITE_OK)rc=sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&s,0);if(rc==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW)value=sqlite3_column_int(s,0);else if(rc==SQLITE_OK)rc=SQLITE_ERROR;sqlite3_finalize(s);s=0;
 if(rc==SQLITE_OK)rc=sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&s,0);if(rc==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW){const char *z=(const char*)sqlite3_column_text(s,0);if(!z||strcmp(z,"ok"))rc=SQLITE_CORRUPT;}else if(rc==SQLITE_OK)rc=SQLITE_ERROR;sqlite3_finalize(s);
 if(rc==SQLITE_OK)printf("wal-inspect\t%d\tok\n",value);sqlite3_close(db);(void)unused;return rc;}
static int checkpoint(const char *path){sqlite3 *db=0;int log=0,done=0;int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);if(rc==SQLITE_OK)rc=sqlite3_wal_checkpoint_v2(db,0,SQLITE_CHECKPOINT_TRUNCATE,&log,&done);if(rc==SQLITE_OK)printf("checkpoint\t%d\t%d\n",log,done);sqlite3_close(db);return rc;}
int main(int n,char **a){if(n==3&&!strcmp(a[1],"inspect"))return inspect(a[2]);if(n==4&&!strcmp(a[1],"write"))return write_value(a[2],atoi(a[3]),1);if(n==3&&!strcmp(a[1],"checkpoint"))return checkpoint(a[2]);return SQLITE_MISUSE;}
