#include "sqlite3.h"

#include <string.h>

int main(void) {
  if (strcmp(sqlite3_version, SQLITE_VERSION) != 0) return 1;
  if (strcmp(sqlite3_libversion(), SQLITE_VERSION) != 0) return 2;
  if (strcmp(sqlite3_sourceid(), SQLITE_SOURCE_ID) != 0) return 3;
  if (sqlite3_libversion_number() != SQLITE_VERSION_NUMBER) return 4;
  if (sqlite3_threadsafe() != 1) return 5;
  return 0;
}
