/* Internal Bitvec differential worker. The amalgamation and bridge share one
** translation unit so SQLITE_PRIVATE Bitvec symbols remain directly callable. */
#include "sqlite3.c"

int probe_initialize(void) {
  return sqlite3_initialize();
}
void probe_shutdown(void) {
  sqlite3_shutdown();
}
void *probe_bitvec_create(uint32_t size) {
  return sqlite3BitvecCreate(size);
}
void probe_bitvec_destroy(void *handle) {
  sqlite3BitvecDestroy((Bitvec *)handle);
}
int probe_bitvec_set(void *handle, uint32_t index) {
  return sqlite3BitvecSet((Bitvec *)handle, index);
}
void probe_bitvec_clear(void *handle, uint32_t index) {
  uint32_t scratch[BITVEC_NINT];
  sqlite3BitvecClear((Bitvec *)handle, index, scratch);
}
int probe_bitvec_test(void *handle, uint32_t index) {
  return sqlite3BitvecTest((Bitvec *)handle, index);
}
uint32_t probe_bitvec_size(void *handle) {
  return sqlite3BitvecSize((Bitvec *)handle);
}
int probe_bitvec_representation(void *handle) {
  Bitvec *vector = (Bitvec *)handle;
  if (vector->iSize <= BITVEC_NBIT) return 0;
  return vector->iDivisor == 0 ? 1 : 2;
}

#include "../../tests/differential/bitvec_worker_main.c"
