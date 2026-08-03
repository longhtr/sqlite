#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

uint32_t probe_get4byte(const uint8_t *input);
void probe_put4byte(uint8_t *output, uint32_t value);

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; ++i) {
    char *end = NULL;
    uintmax_t parsed = strtoumax(argv[i], &end, 10);
    uint8_t storage[6] = {0xaa, 0, 0, 0, 0, 0xbb};
    uint32_t value;
    if (end == argv[i] || *end != '\0' || parsed > UINT32_MAX) return 2;
    value = (uint32_t)parsed;
    probe_put4byte(&storage[1], value);
    printf("%" PRIu32 "\t%02x%02x%02x%02x\t%" PRIu32 "\t%02x%02x\n",
           value, storage[1], storage[2], storage[3], storage[4],
           probe_get4byte(&storage[1]), storage[0], storage[5]);
  }
  return 0;
}
