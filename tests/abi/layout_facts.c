#include "sqlite3.h"

#include <stddef.h>
#include <stdio.h>

#define TYPE_FACTS(type) \
  printf("\"" #type "\":{\"size\":%zu,\"align\":%zu", \
         sizeof(type), _Alignof(type))
#define OFFSET(type, field) \
  printf(",\"" #field "\":%zu", offsetof(type, field))
#define END_TYPE() printf("}")

int main(void) {
  printf("{");

  TYPE_FACTS(sqlite3_vfs);
  OFFSET(sqlite3_vfs, iVersion);
  OFFSET(sqlite3_vfs, szOsFile);
  OFFSET(sqlite3_vfs, xOpen);
  OFFSET(sqlite3_vfs, xCurrentTimeInt64);
  OFFSET(sqlite3_vfs, xNextSystemCall);
  END_TYPE();

  printf(",");
  TYPE_FACTS(sqlite3_io_methods);
  OFFSET(sqlite3_io_methods, iVersion);
  OFFSET(sqlite3_io_methods, xRead);
  OFFSET(sqlite3_io_methods, xWrite);
  OFFSET(sqlite3_io_methods, xShmMap);
  OFFSET(sqlite3_io_methods, xFetch);
  OFFSET(sqlite3_io_methods, xUnfetch);
  END_TYPE();

  printf(",");
  TYPE_FACTS(sqlite3_mem_methods);
  OFFSET(sqlite3_mem_methods, xMalloc);
  OFFSET(sqlite3_mem_methods, xRoundup);
  OFFSET(sqlite3_mem_methods, xShutdown);
  OFFSET(sqlite3_mem_methods, pAppData);
  END_TYPE();

  printf(",");
  TYPE_FACTS(sqlite3_module);
  OFFSET(sqlite3_module, iVersion);
  OFFSET(sqlite3_module, xCreate);
  OFFSET(sqlite3_module, xBestIndex);
  OFFSET(sqlite3_module, xShadowName);
  OFFSET(sqlite3_module, xIntegrity);
  END_TYPE();

  printf(",");
  TYPE_FACTS(sqlite3_index_info);
  OFFSET(sqlite3_index_info, nConstraint);
  OFFSET(sqlite3_index_info, idxStr);
  OFFSET(sqlite3_index_info, estimatedRows);
  OFFSET(sqlite3_index_info, colUsed);
  END_TYPE();

  printf(",");
  TYPE_FACTS(sqlite3_pcache_methods2);
  OFFSET(sqlite3_pcache_methods2, iVersion);
  OFFSET(sqlite3_pcache_methods2, xInit);
  OFFSET(sqlite3_pcache_methods2, xFetch);
  OFFSET(sqlite3_pcache_methods2, xShrink);
  END_TYPE();

  printf(",");
  TYPE_FACTS(sqlite3_mutex_methods);
  OFFSET(sqlite3_mutex_methods, xMutexInit);
  OFFSET(sqlite3_mutex_methods, xMutexAlloc);
  OFFSET(sqlite3_mutex_methods, xMutexHeld);
  OFFSET(sqlite3_mutex_methods, xMutexNotheld);
  END_TYPE();

  printf("}\n");
  return 0;
}
