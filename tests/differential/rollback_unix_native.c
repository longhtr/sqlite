#include "sqlite3.c"
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int sqlite3_phase15_wal_native(const char*,unsigned int,int);
static int copyfile(const char*a,const char*b){FILE*i=fopen(a,"rb"),*o=fopen(b,"wb");char x[8192];size_t n;if(!i||!o)return 1;while((n=fread(x,1,sizeof x,i)))if(fwrite(x,1,n,o)!=n)return 1;fclose(i);fclose(o);return 0;}
static int val(sqlite3*d){sqlite3_stmt*s=0;int v=-1;if(!sqlite3_prepare_v2(d,"PRAGMA user_version",-1,&s,0)&&sqlite3_step(s)==SQLITE_ROW)v=sqlite3_column_int(s,0);sqlite3_finalize(s);return v;}
int main(int n,char**a){if(n==3&&!strcmp(a[1],"child"))return sqlite3_phase15_wal_native(a[2],1516,0);if(n!=2)return 2;char p[256],j[280];snprintf(p,sizeof p,"/tmp/sqlite-zig-rollback-native-%d.db",getpid());if(copyfile(a[1],p))return 1;pid_t c=fork();if(c==0){execl(a[0],a[0],"child",p,(char*)0);_exit(127);}int st=0;waitpid(c,&st,0);sqlite3*d=0;int rc=sqlite3_open_v2(p,&d,SQLITE_OPEN_READWRITE,0),v=rc?-1:val(d);sqlite3_stmt*s=0;if(!rc)rc=sqlite3_prepare_v2(d,"PRAGMA integrity_check",-1,&s,0);if(!rc&&sqlite3_step(s)==SQLITE_ROW&&strcmp((const char*)sqlite3_column_text(s,0),"ok"))rc=SQLITE_CORRUPT;sqlite3_finalize(s);sqlite3_close(d);unlink(p);snprintf(j,sizeof j,"%s-journal",p);int journal_exists=!access(j,F_OK);unlink(j);if(st||rc||v!=1516||journal_exists){fprintf(stderr,"rollback native status=%d rc=%d value=%d journal=%d\n",st,rc,v,journal_exists);return 1;}puts("rollback-unix-native\tcross-process\tpass");return 0;}
