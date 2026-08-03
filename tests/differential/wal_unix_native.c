#include "sqlite3.c"
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int sqlite3_phase15_wal_native(const char*,unsigned int,int);
static int value(sqlite3 *db){sqlite3_stmt*s=0;int v=-1;if(sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&s,0)==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW)v=sqlite3_column_int(s,0);sqlite3_finalize(s);return v;}
static int childop(const char*exe,const char*path,unsigned v,int op){pid_t p=fork();if(p<0)return 1;if(p==0){char sv[32],so[32];snprintf(sv,sizeof(sv),"%u",v);snprintf(so,sizeof(so),"%d",op);execl(exe,exe,"child",path,sv,so,(char*)0);_exit(127);}int status=0;if(waitpid(p,&status,0)<0||!WIFEXITED(status))return 1;return WEXITSTATUS(status);}
static int copyfile(const char*from,const char*to){FILE*i=fopen(from,"rb"),*o=fopen(to,"wb");char b[8192];size_t n;if(!i||!o)return 1;while((n=fread(b,1,sizeof(b),i))>0)if(fwrite(b,1,n,o)!=n)return 1;fclose(i);fclose(o);return 0;}
int main(int n,char**a){if(n==5&&!strcmp(a[1],"child"))return sqlite3_phase15_wal_native(a[2],(unsigned)strtoul(a[3],0,10),atoi(a[4]));if(n!=2)return 2;char path[256],aux[300];snprintf(path,sizeof(path),"/tmp/sqlite-zig-wal-native-%d.db",(int)getpid());if(copyfile(a[1],path))return 1;int write_rc=childop(a[0],path,1515,0);snprintf(aux,sizeof(aux),"%s-shm",path);unlink(aux);sqlite3*db=0;int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE,0);int current=rc?-1:value(db);sqlite3_stmt*s=0;if(rc==SQLITE_OK)rc=sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&s,0);if(rc==SQLITE_OK&&sqlite3_step(s)==SQLITE_ROW){const char*z=(const char*)sqlite3_column_text(s,0);if(!z||strcmp(z,"ok"))rc=SQLITE_CORRUPT;}sqlite3_finalize(s);sqlite3_close(db);unlink(path);snprintf(aux,sizeof(aux),"%s-wal",path);unlink(aux);snprintf(aux,sizeof(aux),"%s-shm",path);unlink(aux);if(write_rc!=SQLITE_OK||rc!=SQLITE_OK||current!=1515){fprintf(stderr,"native write=%d rc=%d current=%d\n",write_rc,rc,current);return 1;}printf("wal-unix-native\tcross-process\tpass\n");return 0;}
