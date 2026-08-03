#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1

static void extension_answer(sqlite3_context *context,int count,sqlite3_value **values){
  (void)count;
  (void)values;
  sqlite3_result_int(context,42);
}

#ifdef _WIN32
__declspec(dllexport)
#endif
int sqlite3_extension_init(sqlite3 *database,char **error_message,const sqlite3_api_routines *api){
  (void)error_message;
  SQLITE_EXTENSION_INIT2(api);
  int rc=sqlite3_overload_function(database,"extension_overloaded",0);
  if(rc!=SQLITE_OK)return rc;
  return sqlite3_create_function(database,"extension_answer",0,SQLITE_UTF8,0,extension_answer,0,0);
}
