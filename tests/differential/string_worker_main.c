#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int probe_stricmp(const char *left, const char *right);
int probe_stricmp_internal(const char *left, const char *right);
int probe_strnicmp(const char *left, const char *right, int count);
uint8_t probe_strihash(const char *value);
int probe_strlen30(const char *value);
int probe_strlen30_nn(const char *value);

static int hex_nibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

static int parse_string(const char *text, uint8_t output[1025], const char **result) {
  size_t length;
  size_t i;
  if (strcmp(text, "~") == 0) {
    *result = NULL;
    return 1;
  }
  length = strlen(text);
  if ((length & 1) != 0 || length > 2048) return 0;
  for (i = 0; i < length / 2; ++i) {
    int high = hex_nibble(text[i * 2]);
    int low = hex_nibble(text[i * 2 + 1]);
    if (high < 0 || low < 0) return 0;
    output[i] = (uint8_t)((high << 4) | low);
  }
  output[length / 2] = 0;
  *result = (const char *)output;
  return 1;
}

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; ++i) {
    char *count_text;
    char *left_text;
    char *right_text;
    char *separator;
    char *end = NULL;
    long parsed_count;
    uint8_t left_storage[1025];
    uint8_t right_storage[1025];
    const char *left;
    const char *right;
    int internal;

    if (argv[i][0] != 'c' || argv[i][1] != ':') return 2;
    count_text = argv[i] + 2;
    separator = strchr(count_text, ':');
    if (separator == NULL) return 3;
    *separator = 0;
    left_text = separator + 1;
    separator = strchr(left_text, ':');
    if (separator == NULL) return 4;
    *separator = 0;
    right_text = separator + 1;
    if (strchr(right_text, ':') != NULL) return 5;

    parsed_count = strtol(count_text, &end, 10);
    if (end == count_text || *end != 0 || parsed_count < INT32_MIN ||
        parsed_count > INT32_MAX) return 6;
    if (!parse_string(left_text, left_storage, &left) ||
        !parse_string(right_text, right_storage, &right)) return 7;

    internal = left != NULL && right != NULL
                   ? probe_stricmp_internal(left, right)
                   : 9999;
    printf("C\t%d\t%d\t%d\t%u\t%u\t%d\t%d\t%d\t%d\n",
           probe_stricmp(left, right), internal,
           probe_strnicmp(left, right, (int)parsed_count),
           probe_strihash(left), probe_strihash(right),
           probe_strlen30(left), probe_strlen30(right),
           left != NULL ? probe_strlen30_nn(left) : -1,
           right != NULL ? probe_strlen30_nn(right) : -1);
  }
  return 0;
}
