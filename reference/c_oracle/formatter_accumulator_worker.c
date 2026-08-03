#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <stddef.h>

static void dump(const char *name, StrAccum *p){
  unsigned int i;
  printf("%s\t%u\t%u\t%u\t%u\t%u\t%d\t",name,p->nAlloc,p->mxAlloc,p->nChar,p->accError,p->printfFlags,isMalloced(p));
  if(p->zText){
    for(i=0; i<p->nChar; i++) printf("%02x",(unsigned char)p->zText[i]);
  }else{
    printf("NULL");
  }
  printf("\n");
}

int main(void){
  StrAccum acc;
  char fixed[8];
  char finish[32];
  if(sqlite3_initialize()!=SQLITE_OK) return 2;
  printf("LAYOUT\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\n",sizeof(StrAccum),_Alignof(StrAccum),offsetof(StrAccum,db),offsetof(StrAccum,zText),offsetof(StrAccum,nAlloc),offsetof(StrAccum,mxAlloc),offsetof(StrAccum,nChar),offsetof(StrAccum,accError),offsetof(StrAccum,printfFlags));

  sqlite3StrAccumInit(&acc,0,fixed,sizeof(fixed),0);
  dump("fixed-init",&acc);
  sqlite3_str_append(&acc,"1234567",7);
  dump("fixed-full",&acc);
  sqlite3_str_appendchar(&acc,1,'8');
  dump("fixed-toobig",&acc);
  sqlite3_str_reset(&acc);
  dump("fixed-reset",&acc);

  sqlite3StrAccumInit(&acc,0,fixed,sizeof(fixed),128);
  sqlite3_str_append(&acc,"abc",3);
  sqlite3_str_append(&acc,"defghijkl",9);
  dump("dynamic-grown",&acc);
  sqlite3_str_truncate(&acc,5);
  dump("dynamic-truncated",&acc);
  sqlite3StrAccumFinish(&acc);
  dump("dynamic-finished",&acc);
  sqlite3_str_reset(&acc);
  dump("dynamic-reset",&acc);

  sqlite3StrAccumInit(&acc,0,finish,sizeof(finish),128);
  sqlite3_str_appendall(&acc,"hello");
  sqlite3StrAccumFinish(&acc);
  dump("finish-reallocated",&acc);
  sqlite3_str_reset(&acc);

  sqlite3StrAccumInit(&acc,0,0,0,10);
  sqlite3_str_append(&acc,"01234567890123456789",20);
  dump("dynamic-toobig",&acc);

  sqlite3StrAccumInit(&acc,0,0,0,128);
  sqlite3_str_append(&acc,"",0);
  dump("empty-allocation",&acc);
  sqlite3_str_reset(&acc);

  sqlite3_shutdown();
  return 0;
}
