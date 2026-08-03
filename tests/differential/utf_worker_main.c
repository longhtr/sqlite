#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint8_t probe_utf8_append(uint8_t output[4], uint32_t value);
uint8_t probe_utf16le_write(uint8_t output[4], uint32_t value);
uint8_t probe_utf16be_write(uint8_t output[4], uint32_t value);
uint32_t probe_utf8_read(const uint8_t *input, uint32_t *length);
uint32_t probe_utf8_read_bounded(const uint8_t *input, uint32_t byte_count,
                                 uint32_t *length);
uint32_t probe_utf8_read_limited(const uint8_t *input, int byte_count,
                                 uint32_t *length);
int probe_utf8_char_len(const uint8_t *input, int byte_count);
int probe_utf16_byte_len(const uint8_t *input, int byte_count, int character_count);

static int hex_nibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

static int parse_hex(const char *text, uint8_t output[1025], int *byte_count) {
  size_t length = strlen(text);
  size_t i;
  if ((length & 1) != 0 || length == 0 || length > 2048) return 0;
  for (i = 0; i < length / 2; ++i) {
    int high = hex_nibble(text[i * 2]);
    int low = hex_nibble(text[i * 2 + 1]);
    if (high < 0 || low < 0) return 0;
    output[i] = (uint8_t)((high << 4) | low);
  }
  output[length / 2] = 0;
  *byte_count = (int)(length / 2);
  return 1;
}

static void print_hex(const uint8_t *bytes, uint8_t length) {
  uint8_t i;
  for (i = 0; i < length; ++i) printf("%02x", bytes[i]);
}

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "v:", 2) == 0) {
      char *end = NULL;
      uintmax_t parsed = strtoumax(argv[i] + 2, &end, 10);
      uint8_t utf8[4], little[4], big[4];
      uint8_t n8, nl, nb;
      if (end == argv[i] + 2 || *end != 0 || parsed > UINT32_MAX) return 2;
      n8 = probe_utf8_append(utf8, (uint32_t)parsed);
      nl = probe_utf16le_write(little, (uint32_t)parsed);
      nb = probe_utf16be_write(big, (uint32_t)parsed);
      printf("V\t%" PRIuMAX "\t%u\t", parsed, n8);
      print_hex(utf8, n8);
      printf("\t%u\t", nl);
      print_hex(little, nl);
      printf("\t%u\t", nb);
      print_hex(big, nb);
      printf("\n");
    } else if (strncmp(argv[i], "r:", 2) == 0) {
      char *limit_text = argv[i] + 2;
      char *separator = strchr(limit_text, ':');
      char *end = NULL;
      long limit;
      uint8_t bytes[1025];
      int byte_count;
      uint32_t read_length, bounded_length, limited_length;
      uint32_t read_value, bounded_value, limited_value;
      if (separator == NULL) return 3;
      *separator = 0;
      limit = strtol(limit_text, &end, 10);
      if (end == limit_text || *end != 0 || limit <= 0 || limit > INT32_MAX ||
          !parse_hex(separator + 1, bytes, &byte_count) || limit > byte_count) return 4;
      read_value = probe_utf8_read(bytes, &read_length);
      bounded_value = probe_utf8_read_bounded(bytes, (uint32_t)limit, &bounded_length);
      limited_value = probe_utf8_read_limited(bytes, (int)limit, &limited_length);
      printf("R\t%u\t%" PRIu32 "\t%u\t%" PRIu32 "\t%u\t%" PRIu32
             "\t%d\t%d\n",
             read_length, read_value, bounded_length, bounded_value,
             limited_length, limited_value,
             probe_utf8_char_len(bytes, (int)limit),
             probe_utf8_char_len(bytes, -1));
    } else if (strncmp(argv[i], "u:", 2) == 0) {
      char *count_text = argv[i] + 2;
      char *separator = strchr(count_text, ':');
      char *end = NULL;
      long character_count;
      uint8_t bytes[1025];
      int byte_count;
      if (separator == NULL) return 5;
      *separator = 0;
      character_count = strtol(count_text, &end, 10);
      if (end == count_text || *end != 0 || character_count < 0 ||
          character_count > INT32_MAX ||
          !parse_hex(separator + 1, bytes, &byte_count)) return 6;
      printf("U\t%d\n", probe_utf16_byte_len(bytes, byte_count,
                                               (int)character_count));
    } else {
      return 7;
    }
  }
  return 0;
}
