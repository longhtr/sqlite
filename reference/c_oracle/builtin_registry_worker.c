#include "sqlite3.c"
#include <stdint.h>
#include <stdio.h>

static int omitted(const char *name){
  static const char *const names[] = {
    "load_extension",
    "sqlite_add_constraint",
    "sqlite_drop_column",
    "sqlite_drop_constraint",
    "sqlite_fail",
    "sqlite_find_constraint",
    "sqlite_rename_column",
    "sqlite_rename_quotefix",
    "sqlite_rename_table",
    "sqlite_rename_test"
  };
  unsigned int i;
  for(i=0; i<sizeof(names)/sizeof(names[0]); i++){
    if( sqlite3_stricmp(name, names[i])==0 ) return 1;
  }
  return 0;
}

int main(void){
  int bucket;
  if( sqlite3_initialize()!=SQLITE_OK ) return 1;
  for(bucket=0; bucket<SQLITE_FUNC_HASH_SZ; bucket++){
    FuncDef *head;
    for(head=sqlite3BuiltinFunctions.a[bucket]; head; head=head->u.pHash){
      FuncDef *definition;
      if( omitted(head->zName) ) continue;
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
