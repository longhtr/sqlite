/* Internal Hash differential worker. The amalgamation and bridge share one
** translation unit so SQLITE_PRIVATE Hash symbols remain directly callable. */
#include "sqlite3.c"

int probe_initialize(void) {
  return sqlite3_initialize();
}
void probe_shutdown(void) {
  sqlite3_shutdown();
}
void *probe_hash_create(void) {
  Hash *hash = (Hash *)malloc(sizeof(*hash));
  if (hash != NULL) sqlite3HashInit(hash);
  return hash;
}
void probe_hash_destroy(void *handle) {
  Hash *hash = (Hash *)handle;
  if (hash == NULL) return;
  sqlite3HashClear(hash);
  free(hash);
}
uintptr_t probe_hash_insert(void *handle, const char *key, uintptr_t value) {
  return (uintptr_t)sqlite3HashInsert((Hash *)handle, key, (void *)value);
}
uintptr_t probe_hash_delete(void *handle, const char *key) {
  return (uintptr_t)sqlite3HashInsert((Hash *)handle, key, NULL);
}
uintptr_t probe_hash_find(const void *handle, const char *key) {
  return (uintptr_t)sqlite3HashFind((const Hash *)handle, key);
}
uint32_t probe_hash_count(const void *handle) {
  return (uint32_t)sqliteHashCount((const Hash *)handle);
}
uint32_t probe_hash_bucket_count(const void *handle) {
  return ((const Hash *)handle)->htsize;
}
const void *probe_hash_first(const void *handle) {
  return sqliteHashFirst((const Hash *)handle);
}
const void *probe_hash_next(const void *element) {
  return sqliteHashNext((const HashElem *)element);
}
const char *probe_hash_element_key(const void *element) {
  return ((const HashElem *)element)->pKey;
}
uintptr_t probe_hash_element_data(const void *element) {
  return (uintptr_t)sqliteHashData((const HashElem *)element);
}
uint32_t probe_hash_element_hash(const void *element) {
  return ((const HashElem *)element)->h;
}

#include "../../tests/differential/hash_worker_main.c"
