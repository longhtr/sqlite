#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static RCStr *header(char *z){ return ((RCStr*)z)-1; }
static void dump(const char *name, char *z, int n){
  int i;
  RCStr *p = header(z);
  printf("%s\t%d\t%llu\t",name,sqlite3DbMallocSize(0,p),(unsigned long long)p->nRCRef);
  for(i=0; i<n; i++) printf("%02x",(unsigned char)z[i]);
  printf("\n");
}

int main(void){
  char *z;
  char *same;
  if(sqlite3_initialize()!=SQLITE_OK) return 2;
  printf("LAYOUT\t%zu\t%zu\t%zu\n",sizeof(RCStr),_Alignof(RCStr),offsetof(RCStr,nRCRef));
  z = sqlite3RCStrNew(5);
  if(!z) return 3;
  memcpy(z,"abcde\0",6);
  dump("new",z,5);
  same = sqlite3RCStrRef(z);
  printf("ref-one\t%d\t%llu\n",same==z,(unsigned long long)header(z)->nRCRef);
  same = sqlite3RCStrRef(z);
  printf("ref-two\t%d\t%llu\n",same==z,(unsigned long long)header(z)->nRCRef);
  sqlite3RCStrUnref(z);
  printf("unref\t%llu\n",(unsigned long long)header(z)->nRCRef);
  sqlite3RCStrUnref(z);
  z = sqlite3RCStrResize(z,10);
  if(!z) return 4;
  dump("grown",z,5);
  z = sqlite3RCStrResize(z,2);
  if(!z) return 5;
  dump("shrunk",z,2);
  sqlite3RCStrUnref(z);
  sqlite3_shutdown();
  return 0;
}
