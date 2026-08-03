#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int probe_initialize(void);
void probe_shutdown(void);
void *probe_hash_create(void);
void probe_hash_destroy(void *handle);
uintptr_t probe_hash_insert(void *handle, const char *key, uintptr_t value);
uintptr_t probe_hash_delete(void *handle, const char *key);
uintptr_t probe_hash_find(const void *handle, const char *key);
uint32_t probe_hash_count(const void *handle);
uint32_t probe_hash_bucket_count(const void *handle);
const void *probe_hash_first(const void *handle);
const void *probe_hash_next(const void *element);
const char *probe_hash_element_key(const void *element);
uintptr_t probe_hash_element_data(const void *element);
uint32_t probe_hash_element_hash(const void *element);

static int parse_value(const char *text, uintptr_t *out) {
  char *end = NULL;
  uintmax_t value = strtoumax(text, &end, 10);
  if (end == text || *end != '\0' || value == 0 || value > UINTPTR_MAX) {
    return 0;
  }
  *out = (uintptr_t)value;
  return 1;
}

int main(int argc, char **argv) {
  void *hash;
  int i;

  if (probe_initialize() != 0) return 8;
  hash = probe_hash_create();
  if (hash == NULL) return 3;

  for (i = 1; i < argc; ++i) {
    char *operation = argv[i];
    const char *key;
    uintptr_t result;
    uintptr_t found;
    if (operation[0] == '\0' || operation[1] != ':' || operation[2] == '\0') {
      probe_hash_destroy(hash);
      return 4;
    }
    key = operation + 2;
    switch (operation[0]) {
      case 'i': {
        char *separator = strrchr(operation + 2, ':');
        uintptr_t value;
        if (separator == NULL || separator == operation + 2 ||
            !parse_value(separator + 1, &value)) {
          probe_hash_destroy(hash);
          return 5;
        }
        *separator = '\0';
        result = probe_hash_insert(hash, key, value);
        break;
      }
      case 'd':
        result = probe_hash_delete(hash, key);
        break;
      case 'f':
        result = probe_hash_find(hash, key);
        break;
      default:
        probe_hash_destroy(hash);
        return 6;
    }
    found = probe_hash_find(hash, key);
    printf("OP\t%c\t%s\t%" PRIuPTR "\t%" PRIuPTR "\t%" PRIu32
           "\t%" PRIu32 "\n",
           operation[0], key, result, found, probe_hash_count(hash),
           probe_hash_bucket_count(hash));
  }

  {
    const void *element = probe_hash_first(hash);
    uint32_t traversed = 0;
    while (element != NULL) {
      printf("E\t%s\t%" PRIuPTR "\t%08" PRIx32 "\n",
             probe_hash_element_key(element), probe_hash_element_data(element),
             probe_hash_element_hash(element));
      traversed++;
      element = probe_hash_next(element);
    }
    printf("RESULT\t%" PRIu32 "\t%" PRIu32 "\t%" PRIu32 "\n",
           probe_hash_count(hash), probe_hash_bucket_count(hash), traversed);
  }

  probe_hash_destroy(hash);
  probe_shutdown();
  return 0;
}
