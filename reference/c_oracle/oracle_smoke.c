#include "sqlite3.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int expect_row(void *context, int columns, char **values, char **names) {
  int *seen = (int *)context;
  if (columns != 3) return 1;
  if (strcmp(names[0], "answer") != 0) return 1;
  if (strcmp(values[0], "42") != 0) return 1;
  if (strcmp(values[1], "integer") != 0) return 1;
  if (strcmp(values[2], "X'0001FF'") != 0) return 1;
  *seen += 1;
  return 0;
}

int main(void) {
  sqlite3 *db = NULL;
  char *error_message = NULL;
  int seen = 0;

  if (strcmp(sqlite3_libversion(), SQLITE_VERSION) != 0) return 10;
  if (strcmp(sqlite3_sourceid(), SQLITE_SOURCE_ID) != 0) return 11;
  if (sqlite3_libversion_number() != SQLITE_VERSION_NUMBER) return 12;
  if (sqlite3_threadsafe() != 1) return 13;

  if (sqlite3_open(":memory:", &db) != SQLITE_OK) return 20;
  const int rc = sqlite3_exec(
      db,
      "SELECT 40+2 AS answer, typeof(40+2), quote(x'0001ff')",
      expect_row,
      &seen,
      &error_message);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "oracle SQL failure: %s\n",
            error_message != NULL ? error_message : sqlite3_errmsg(db));
    sqlite3_free(error_message);
    sqlite3_close(db);
    return 21;
  }
  if (seen != 1) {
    sqlite3_close(db);
    return 22;
  }
  if (sqlite3_close(db) != SQLITE_OK) return 23;

  printf("sqlite_version=%s\n", sqlite3_libversion());
  printf("sqlite_source_id=%s\n", sqlite3_sourceid());
  printf("threadsafe=%d\n", sqlite3_threadsafe());
  return 0;
}
