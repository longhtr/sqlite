/* Internal ASCII-case-folded string differential worker. */
#include "sqlite3.c"

int probe_stricmp(const char *left, const char *right) {
  return sqlite3_stricmp(left, right);
}
int probe_stricmp_internal(const char *left, const char *right) {
  return sqlite3StrICmp(left, right);
}
int probe_strnicmp(const char *left, const char *right, int count) {
  return sqlite3_strnicmp(left, right, count);
}
uint8_t probe_strihash(const char *value) {
  return sqlite3StrIHash(value);
}
int probe_strlen30(const char *value) {
  return sqlite3Strlen30(value);
}
int probe_strlen30_nn(const char *value) {
  return sqlite3Strlen30NN(value);
}

#include "../../tests/differential/string_worker_main.c"
