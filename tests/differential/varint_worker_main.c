#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint8_t probe_varint_put(uint8_t *output, uint64_t value);
uint8_t probe_varint_get(const uint8_t *input, uint64_t *value);
uint8_t probe_varint_get32(const uint8_t *input, uint32_t *value);
uint32_t probe_varint_get32_nr(const uint8_t *input);
uint8_t probe_varint_put32(uint8_t *output, uint32_t value);
uint8_t probe_varint_length(uint64_t value);

static int parse_u64(const char *text, uint64_t *out) {
  char *end = NULL;
  uintmax_t value = strtoumax(text, &end, 10);
  if (end == text || *end != '\0' || value > UINT64_MAX) return 0;
  *out = (uint64_t)value;
  return 1;
}

static int hex_nibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

static int parse_hex9(const char *text, uint8_t output[9]) {
  int i;
  if (strlen(text) != 18) return 0;
  for (i = 0; i < 9; ++i) {
    int high = hex_nibble(text[i * 2]);
    int low = hex_nibble(text[i * 2 + 1]);
    if (high < 0 || low < 0) return 0;
    output[i] = (uint8_t)((high << 4) | low);
  }
  return 1;
}

static void print_hex(const uint8_t *bytes, uint8_t length) {
  uint8_t i;
  for (i = 0; i < length; ++i) printf("%02x", bytes[i]);
}

static void print_decode(const uint8_t bytes[9]) {
  uint64_t value64;
  uint32_t value32;
  uint8_t length64 = probe_varint_get(bytes, &value64);
  uint8_t length32 = probe_varint_get32(bytes, &value32);
  printf("%u\t%" PRIu64 "\t%u\t%" PRIu32 "\t%" PRIu32,
         length64, value64, length32, value32,
         probe_varint_get32_nr(bytes));
}

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "v:", 2) == 0) {
      uint64_t value;
      uint8_t encoded[9];
      uint8_t encoded32[9];
      uint8_t count;
      if (!parse_u64(argv[i] + 2, &value)) return 2;
      memset(encoded, 0xaa, sizeof(encoded));
      count = probe_varint_put(encoded, value);
      printf("V\t%" PRIu64 "\t%u\t", value, count);
      print_hex(encoded, count);
      printf("\t");
      print_decode(encoded);
      printf("\t%u", probe_varint_length(value));
      if (value <= UINT32_MAX) {
        uint8_t count32;
        memset(encoded32, 0xaa, sizeof(encoded32));
        count32 = probe_varint_put32(encoded32, (uint32_t)value);
        printf("\t%u\t", count32);
        print_hex(encoded32, count32);
      } else {
        printf("\t-\t-");
      }
      printf("\n");
    } else if (strncmp(argv[i], "x:", 2) == 0) {
      uint8_t bytes[9];
      if (!parse_hex9(argv[i] + 2, bytes)) return 3;
      printf("X\t%s\t", argv[i] + 2);
      print_decode(bytes);
      printf("\n");
    } else {
      return 4;
    }
  }
  return 0;
}
