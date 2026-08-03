/* Internal varint differential worker. */
#include "sqlite3.c"

uint8_t probe_varint_put(uint8_t *output, uint64_t value) {
  return (uint8_t)sqlite3PutVarint(output, value);
}
uint8_t probe_varint_get(const uint8_t *input, uint64_t *value) {
  return sqlite3GetVarint(input, value);
}
uint8_t probe_varint_get32(const uint8_t *input, uint32_t *value) {
  return getVarint32(input, *value);
}
uint32_t probe_varint_get32_nr(const uint8_t *input) {
  uint32_t value;
  getVarint32NR(input, value);
  return value;
}
uint8_t probe_varint_put32(uint8_t *output, uint32_t value) {
  return (uint8_t)putVarint32(output, value);
}
uint8_t probe_varint_length(uint64_t value) {
  return (uint8_t)sqlite3VarintLen(value);
}

#include "../../tests/differential/varint_worker_main.c"
