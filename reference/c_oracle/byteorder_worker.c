/* Internal four-byte big-endian differential worker. */
#include "sqlite3.c"

uint32_t probe_get4byte(const uint8_t *input) {
  return sqlite3Get4byte(input);
}
void probe_put4byte(uint8_t *output, uint32_t value) {
  sqlite3Put4byte(output, value);
}

#include "../../tests/differential/byteorder_worker_main.c"
