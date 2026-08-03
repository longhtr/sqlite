/* Internal pure UTF primitive differential worker. */
#include "sqlite3.c"

uint8_t probe_utf8_append(uint8_t output[4], uint32_t value) {
  return (uint8_t)sqlite3AppendOneUtf8Character((char *)output, value);
}
uint8_t probe_utf16le_write(uint8_t output[4], uint32_t value) {
  uint8_t *cursor = output;
  WRITE_UTF16LE(cursor, value);
  return (uint8_t)(cursor - output);
}
uint8_t probe_utf16be_write(uint8_t output[4], uint32_t value) {
  uint8_t *cursor = output;
  WRITE_UTF16BE(cursor, value);
  return (uint8_t)(cursor - output);
}
uint32_t probe_utf8_read(const uint8_t *input, uint32_t *length) {
  const uint8_t *cursor = input;
  uint32_t value = sqlite3Utf8Read(&cursor);
  *length = (uint32_t)(cursor - input);
  return value;
}
uint32_t probe_utf8_read_bounded(const uint8_t *input, uint32_t byte_count,
                                 uint32_t *length) {
  const uint8_t *cursor = input;
  const uint8_t *term = input + byte_count;
  uint32_t value;
  READ_UTF8(cursor, term, value);
  *length = (uint32_t)(cursor - input);
  return value;
}
uint32_t probe_utf8_read_limited(const uint8_t *input, int byte_count,
                                 uint32_t *length) {
  uint32_t value;
  *length = (uint32_t)sqlite3Utf8ReadLimited(input, byte_count, &value);
  return value;
}
int probe_utf8_char_len(const uint8_t *input, int byte_count) {
  return sqlite3Utf8CharLen((const char *)input, byte_count);
}
int probe_utf16_byte_len(const uint8_t *input, int byte_count, int character_count) {
  return sqlite3Utf16ByteLen(input, byte_count, character_count);
}

#include "../../tests/differential/utf_worker_main.c"
