/* Internal deterministic-injected PRNG differential worker. */
#include "sqlite3.c"

static uint8_t probeEntropy[44];

static void probe_seed_state(void) {
  static const uint32_t init[4] = {
    0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
  };
  memcpy(&sqlite3Prng.s[0], init, 16);
  memcpy(&sqlite3Prng.s[4], probeEntropy, 44);
  sqlite3Prng.s[15] = sqlite3Prng.s[12];
  sqlite3Prng.s[12] = 0;
  sqlite3Prng.n = 0;
}

int probe_random_initialize(const uint8_t entropy[44]) {
  int rc = sqlite3_initialize();
  memcpy(probeEntropy, entropy, 44);
  memset(&sqlite3Prng, 0, sizeof(sqlite3Prng));
  return rc;
}
void probe_random_shutdown(void) {
  sqlite3_shutdown();
}
void probe_random_bytes(int count, uint8_t *output) {
  if (sqlite3Prng.s[0] == 0) probe_seed_state();
  sqlite3_randomness(count, output);
}
void probe_random_reset(void) {
  sqlite3_randomness(0, NULL);
}
void probe_random_save(void) {
  sqlite3PrngSaveState();
}
void probe_random_restore(void) {
  sqlite3PrngRestoreState();
}

#include "../../tests/differential/random_worker_main.c"
