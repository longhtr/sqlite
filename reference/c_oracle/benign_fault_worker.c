#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

static int begins=0,ends=0;
static void on_begin(void){begins++;}
static void on_end(void){ends++;}
static void alt_begin(void){begins+=10;}
static void alt_end(void){ends+=20;}
int main(void){
  printf("1\t%zu\t%d\t%d\n",sizeof(sqlite3Hooks),sqlite3Hooks.xBenignBegin==0,sqlite3Hooks.xBenignEnd==0);
  sqlite3BenignMallocHooks(on_begin,on_end);sqlite3BeginBenignMalloc();sqlite3BeginBenignMalloc();sqlite3EndBenignMalloc();printf("2\t%d\t%d\n",begins,ends);
  sqlite3BenignMallocHooks(alt_begin,alt_end);sqlite3BeginBenignMalloc();sqlite3EndBenignMalloc();printf("3\t%d\t%d\n",begins,ends);
  sqlite3BenignMallocHooks(0,alt_end);sqlite3BeginBenignMalloc();sqlite3EndBenignMalloc();printf("4\t%d\t%d\n",begins,ends);
  sqlite3BenignMallocHooks(0,0);sqlite3BeginBenignMalloc();sqlite3EndBenignMalloc();printf("5\t%d\t%d\n",begins,ends);return 0;
}
