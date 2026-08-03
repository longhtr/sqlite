#include "sqlite3.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int hx(int c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;}
int main(int argc,char**argv){sqlite3*db=0;if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 2;for(int k=1;k<argc;k++){size_t n=strlen(argv[k]);if(n&1)return 3;unsigned char*b=malloc(n/2+1);if(!b)return 4;for(size_t i=0;i<n;i+=2){int a=hx(argv[k][i]),c=hx(argv[k][i+1]);if(a<0||c<0)return 5;b[i/2]=(unsigned char)((a<<4)|c);}n/=2;b[n]=0;sqlite3_stmt*s=0;const char*tail=0;int rc=sqlite3_prepare_v2(db,(const char*)b,(int)n,&s,&tail);printf("P\t%d\t%ld\t%d\n",rc,tail?(long)(tail-(const char*)b):-1L,s!=0);sqlite3_finalize(s);free(b);}sqlite3_close(db);return 0;}
