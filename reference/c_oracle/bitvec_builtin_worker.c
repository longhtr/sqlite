#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void init_prng(void){
  static const u32 init[]={0x61707865,0x3320646e,0x79622d32,0x6b206574};
  unsigned char entropy[44];int i;for(i=0;i<44;i++)entropy[i]=(unsigned char)i;
  memset(&sqlite3Prng,0,sizeof(sqlite3Prng));memcpy(sqlite3Prng.s,init,16);memcpy(&sqlite3Prng.s[4],entropy,44);sqlite3Prng.s[15]=sqlite3Prng.s[12];sqlite3Prng.s[12]=0;
}
int main(void){
  int sequential[]={1,5,1,2,2,2,1,4,0};
  int fault[]={5,1,7,1,0};
  int random_program[]={3,20,4,7,0};
  int negative[]={1,4,1,3,0};
  int rc;
  if(sqlite3_initialize()!=SQLITE_OK)return 2;
  init_prng();
  rc=sqlite3BitvecBuiltinTest(100,sequential);printf("1\t%d\t%d\t%d\t%d\t%d\n",rc,sequential[1],sequential[2],sequential[5],sequential[6]);
  rc=sqlite3BitvecBuiltinTest(100,fault);printf("2\t%d\n",rc);
  rc=sqlite3BitvecBuiltinTest(1000,random_program);printf("3\t%d\t%d\t%d\t%d\n",rc,random_program[1],random_program[3],sqlite3Prng.n);
  rc=sqlite3BitvecBuiltinTest(-100,negative);printf("4\t%d\n",rc);
  sqlite3_shutdown();return 0;
}
