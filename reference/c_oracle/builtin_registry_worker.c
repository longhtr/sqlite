#include "sqlite3.c"
#include <stdint.h>
#include <stdio.h>

int main(void){
  int bucket;
  if( sqlite3_initialize()!=SQLITE_OK ) return 1;
  for(bucket=0; bucket<SQLITE_FUNC_HASH_SZ; bucket++){
    FuncDef *head;
    for(head=sqlite3BuiltinFunctions.a[bucket]; head; head=head->u.pHash){
      FuncDef *definition;
      for(definition=head; definition; definition=definition->pNext){
        uintptr_t user_data = (uintptr_t)definition->pUserData;
        if( user_data>255 ) user_data = 0;
        printf("%d\t%s\t%d\t%08x\t%llu\n", bucket, definition->zName,
               definition->nArg, definition->funcFlags,
               (unsigned long long)user_data);
      }
    }
  }
  sqlite3_shutdown();
  return 0;
}
