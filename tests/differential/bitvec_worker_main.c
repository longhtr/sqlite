#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int probe_initialize(void);
void probe_shutdown(void);
void *probe_bitvec_create(uint32_t size);
void probe_bitvec_destroy(void *handle);
int probe_bitvec_set(void *handle, uint32_t index);
void probe_bitvec_clear(void *handle, uint32_t index);
int probe_bitvec_test(void *handle, uint32_t index);
uint32_t probe_bitvec_size(void *handle);
int probe_bitvec_representation(void *handle);

static int parse_index(const char *text, uint32_t *out) {
  char *end = NULL;
  unsigned long long value = strtoull(text, &end, 10);
  if (end == text || *end != '\0' || value > UINT32_MAX) return 0;
  *out = (uint32_t)value;
  return 1;
}

int main(int argc, char **argv) {
  void *vector;
  uint32_t size;
  uint64_t digest = UINT64_C(1469598103934665603);
  uint32_t set_count = 0;
  uint32_t index;
  int set_rc = 0;
  int i;

  if (argc < 2 || !parse_index(argv[1], &size) || size == 0) return 2;
  if (probe_initialize() != 0) return 8;
  vector = probe_bitvec_create(size);
  if (vector == NULL) return 3;

  for (i = 2; i < argc; ++i) {
    if (strlen(argv[i]) < 3 || argv[i][1] != ':' ||
        !parse_index(argv[i] + 2, &index)) {
      probe_bitvec_destroy(vector);
      return 4;
    }
    switch (argv[i][0]) {
      case 's': {
        int rc;
        if (index == 0 || index > size) {
          probe_bitvec_destroy(vector);
          return 5;
        }
        rc = probe_bitvec_set(vector, index);
        if (set_rc == 0 && rc != 0) set_rc = rc;
        break;
      }
      case 'c':
        if (index == 0 || index > size) {
          probe_bitvec_destroy(vector);
          return 6;
        }
        probe_bitvec_clear(vector, index);
        break;
      case 't':
        printf("T\t%" PRIu32 "\t%d\n", index,
               probe_bitvec_test(vector, index));
        break;
      default:
        probe_bitvec_destroy(vector);
        return 7;
    }
  }

  for (index = 1; index <= size; ++index) {
    const int value = probe_bitvec_test(vector, index);
    set_count += (uint32_t)value;
    digest ^= (uint64_t)value;
    digest *= UINT64_C(1099511628211);
    digest ^= index;
    digest *= UINT64_C(1099511628211);
  }
  printf("RESULT\t%" PRIu32 "\t%" PRIu32 "\t%d\t%d\t%" PRIu32
         "\t%016" PRIx64 "\n",
         size, probe_bitvec_size(vector), set_rc,
         probe_bitvec_representation(vector), set_count, digest);
  probe_bitvec_destroy(vector);
  probe_shutdown();
  return 0;
}
