#include "sqlite3.h"
#include <stdio.h>
#include <string.h>

static int query_value(sqlite3 *db, const char *sql, sqlite3_int64 *value){
  sqlite3_stmt *statement = 0;
  int rc = sqlite3_prepare_v2(db, sql, -1, &statement, 0);
  if(rc==SQLITE_OK){
    rc = sqlite3_step(statement);
    if(rc==SQLITE_ROW) *value = sqlite3_column_int64(statement, 0);
  }
  sqlite3_finalize(statement);
  return rc;
}

int main(void){
  sqlite3 *source=0, *clone=0, *readonly=0, *malformed=0;
  sqlite3_int64 size=-1, borrowed_size=-1, value=-1;
  int rc = sqlite3_open(":memory:", &source);
  if(rc!=SQLITE_OK) return rc;
  rc = sqlite3_exec(source, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", 0, 0, 0);
  if(rc!=SQLITE_OK) return rc;

  unsigned char *image = sqlite3_serialize(source, "main", &size, 0);
  printf("copy\t%d\t%lld\t%d\n", image!=0, (long long)size, image!=0 && memcmp(image,"SQLite format 3",15)==0);
  sqlite3_open(":memory:", &clone);
  rc = sqlite3_deserialize(clone, "main", image, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  unsigned char *borrowed = sqlite3_serialize(clone, "main", &borrowed_size, SQLITE_SERIALIZE_NOCOPY);
  printf("adopt\t%d\t%d\t%lld\n", rc, borrowed==image, (long long)borrowed_size);
  rc = query_value(clone, "SELECT x FROM t", &value);
  printf("query\t%d\t%lld\n", rc, (long long)value);

  unsigned char *readonly_image = sqlite3_serialize(source, "main", &size, 0);
  sqlite3_open(":memory:", &readonly);
  rc = sqlite3_deserialize(readonly, "main", readonly_image, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_READONLY);
  int readonly_flag = sqlite3_db_readonly(readonly, "main");
  int write_rc = sqlite3_exec(readonly, "INSERT INTO t VALUES(99)", 0, 0, 0);
  printf("readonly\t%d\t%d\t%d\n", rc, readonly_flag, write_rc);

  unsigned char *bad = sqlite3_serialize(source, "main", &size, 0);
  memset(bad, 0, (size_t)size);
  memcpy(bad, "not-a-database", 14);
  sqlite3_open(":memory:", &malformed);
  rc = sqlite3_deserialize(malformed, "main", bad, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  borrowed_size = -1;
  borrowed = sqlite3_serialize(malformed, "main", &borrowed_size, SQLITE_SERIALIZE_NOCOPY);
  sqlite3_stmt *statement = 0;
  int prepare_rc = sqlite3_prepare_v2(malformed, "SELECT 1", -1, &statement, 0);
  sqlite3_finalize(statement);
  unsigned char *replacement = sqlite3_serialize(source, "main", &size, 0);
  int replacement_rc = sqlite3_deserialize(malformed, "main", replacement, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  printf("malformed\t%d\t%d\t%lld\t%d\t%d\n", rc, borrowed==bad, (long long)borrowed_size, prepare_rc, replacement_rc);

  int close_clone = sqlite3_close(clone);
  int close_readonly = sqlite3_close(readonly);
  int close_malformed = sqlite3_close(malformed);
  int close_source = sqlite3_close(source);
  printf("close\t%d\t%d\t%d\t%d\n", close_clone, close_readonly, close_malformed, close_source);
  return 0;
}
