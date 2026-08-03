#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int probe_random_initialize(const uint8_t entropy[44]);
void probe_random_shutdown(void);
void probe_random_bytes(int count, uint8_t *output);
void probe_random_reset(void);
void probe_random_save(void);
void probe_random_restore(void);

static int nibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

int main(int argc, char **argv) {
  uint8_t entropy[44];
  int i;
  if (argc < 2 || strlen(argv[1]) != 88) return 2;
  for (i = 0; i < 44; ++i) {
    int high = nibble(argv[1][i * 2]);
    int low = nibble(argv[1][i * 2 + 1]);
    if (high < 0 || low < 0) return 3;
    entropy[i] = (uint8_t)((high << 4) | low);
  }
  if (probe_random_initialize(entropy) != 0) return 4;
  for (i = 2; i < argc; ++i) {
    if (strcmp(argv[i], "s") == 0) {
      probe_random_save();
      printf("S\n");
    } else if (strcmp(argv[i], "r") == 0) {
      probe_random_restore();
      printf("R\n");
    } else if (strcmp(argv[i], "0") == 0) {
      probe_random_reset();
      printf("Z\n");
    } else {
      char *end = NULL;
      long count = strtol(argv[i], &end, 10);
      uint8_t output[256];
      int j;
      if (end == argv[i] || *end != 0 || count <= 0 || count > 256) return 5;
      probe_random_bytes((int)count, output);
      printf("B\t%ld\t", count);
      for (j = 0; j < count; ++j) printf("%02x", output[j]);
      printf("\n");
    }
  }
  probe_random_shutdown();
  return 0;
}
