#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static int any_nonzero(const unsigned char *bytes,int n){int i;for(i=0;i<n;i++)if(bytes[i])return 1;return 0;}
int main(void){
  unsigned char first[16],a[20],b[20],more[8];
  sqlite3_randomness(0,0);printf("1\t%d\t%d\n",sqlite3Prng.s[0]==0,sqlite3Prng.n);
  sqlite3_randomness(16,first);printf("2\t%d\t%d\t%d\n",sqlite3Prng.s[0]!=0,sqlite3Prng.n,any_nonzero(first,16));
  sqlite3PrngSaveState();sqlite3_randomness(20,a);sqlite3PrngRestoreState();sqlite3_randomness(20,b);printf("3\t%d\t%d\n",memcmp(a,b,20)==0,sqlite3Prng.n);
  sqlite3_randomness(8,more);printf("4\t%d\n",sqlite3Prng.n);
  sqlite3_randomness(5,0);printf("5\t%d\t%d\n",sqlite3Prng.s[0]==0,sqlite3Prng.n);
  sqlite3_shutdown();return 0;
}
