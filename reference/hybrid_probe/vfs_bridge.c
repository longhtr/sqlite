#include "sqlite3.h"

#include <stdio.h>
#include <string.h>

extern void sqlite_zig_probe_scalar(sqlite3_context *, int, sqlite3_value **);
extern int sqlite_zig_probe_randomness(unsigned char *, int);
extern unsigned int sqlite_zig_probe_randomness_calls(void);

static sqlite3_vfs probe_vfs;
static sqlite3_vfs *base_vfs;
static const char probe_name[] = "sqlite-zig-phase0-vfs";

static int probeOpen(sqlite3_vfs *vfs, sqlite3_filename name,
                     sqlite3_file *file, int flags, int *out_flags) {
  (void)vfs;
  return base_vfs->xOpen(base_vfs, name, file, flags, out_flags);
}
static int probeDelete(sqlite3_vfs *vfs, const char *name, int sync_dir) {
  (void)vfs;
  return base_vfs->xDelete(base_vfs, name, sync_dir);
}
static int probeAccess(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
  (void)vfs;
  return base_vfs->xAccess(base_vfs, name, flags, out);
}
static int probeFullPathname(sqlite3_vfs *vfs, const char *name, int out_len,
                             char *out) {
  (void)vfs;
  return base_vfs->xFullPathname(base_vfs, name, out_len, out);
}
static void *probeDlOpen(sqlite3_vfs *vfs, const char *name) {
  (void)vfs;
  return base_vfs->xDlOpen != NULL ? base_vfs->xDlOpen(base_vfs, name) : NULL;
}
static void probeDlError(sqlite3_vfs *vfs, int len, char *message) {
  (void)vfs;
  if (base_vfs->xDlError != NULL) base_vfs->xDlError(base_vfs, len, message);
  else if (len > 0) message[0] = '\0';
}
static void (*probeDlSym(sqlite3_vfs *vfs, void *handle,
                         const char *symbol))(void) {
  (void)vfs;
  return base_vfs->xDlSym != NULL
             ? base_vfs->xDlSym(base_vfs, handle, symbol)
             : NULL;
}
static void probeDlClose(sqlite3_vfs *vfs, void *handle) {
  (void)vfs;
  if (base_vfs->xDlClose != NULL) base_vfs->xDlClose(base_vfs, handle);
}
static int probeRandomness(sqlite3_vfs *vfs, int len, char *out) {
  (void)vfs;
  return sqlite_zig_probe_randomness((unsigned char *)out, len);
}
static int probeSleep(sqlite3_vfs *vfs, int microseconds) {
  (void)vfs;
  return base_vfs->xSleep(base_vfs, microseconds);
}
static int probeCurrentTime(sqlite3_vfs *vfs, double *time) {
  (void)vfs;
  return base_vfs->xCurrentTime(base_vfs, time);
}
static int probeGetLastError(sqlite3_vfs *vfs, int len, char *message) {
  (void)vfs;
  return base_vfs->xGetLastError != NULL
             ? base_vfs->xGetLastError(base_vfs, len, message)
             : 0;
}
static int probeCurrentTimeInt64(sqlite3_vfs *vfs, sqlite3_int64 *time) {
  (void)vfs;
  return base_vfs->xCurrentTimeInt64 != NULL
             ? base_vfs->xCurrentTimeInt64(base_vfs, time)
             : SQLITE_NOTFOUND;
}
static int probeSetSystemCall(sqlite3_vfs *vfs, const char *name,
                              sqlite3_syscall_ptr call) {
  (void)vfs;
  return base_vfs->xSetSystemCall != NULL
             ? base_vfs->xSetSystemCall(base_vfs, name, call)
             : SQLITE_NOTFOUND;
}
static sqlite3_syscall_ptr probeGetSystemCall(sqlite3_vfs *vfs,
                                               const char *name) {
  (void)vfs;
  return base_vfs->xGetSystemCall != NULL
             ? base_vfs->xGetSystemCall(base_vfs, name)
             : NULL;
}
static const char *probeNextSystemCall(sqlite3_vfs *vfs,
                                       const char *name) {
  (void)vfs;
  return base_vfs->xNextSystemCall != NULL
             ? base_vfs->xNextSystemCall(base_vfs, name)
             : NULL;
}

static int expect42(void *context, int columns, char **values, char **names) {
  int *seen = (int *)context;
  (void)names;
  if (columns != 1 || values[0] == NULL || strcmp(values[0], "42") != 0)
    return 1;
  *seen += 1;
  return 0;
}

static void remove_probe_files(void) {
  remove("sqlite-zig-hybrid-probe.db");
  remove("sqlite-zig-hybrid-probe.db-journal");
  remove("sqlite-zig-hybrid-probe.db-wal");
  remove("sqlite-zig-hybrid-probe.db-shm");
}

int run_hybrid_probe(void) {
  sqlite3 *db = NULL;
  char *error = NULL;
  unsigned char random_bytes[16];
  int seen = 0;
  int rc;

  if (sqlite3_initialize() != SQLITE_OK) return 1;
  base_vfs = sqlite3_vfs_find(NULL);
  if (base_vfs == NULL || base_vfs->iVersion < 1) return 2;

  memcpy(&probe_vfs, base_vfs, sizeof(probe_vfs));
  probe_vfs.pNext = NULL;
  probe_vfs.zName = probe_name;
  probe_vfs.pAppData = base_vfs;
  probe_vfs.xOpen = probeOpen;
  probe_vfs.xDelete = probeDelete;
  probe_vfs.xAccess = probeAccess;
  probe_vfs.xFullPathname = probeFullPathname;
  probe_vfs.xDlOpen = probeDlOpen;
  probe_vfs.xDlError = probeDlError;
  probe_vfs.xDlSym = probeDlSym;
  probe_vfs.xDlClose = probeDlClose;
  probe_vfs.xRandomness = probeRandomness;
  probe_vfs.xSleep = probeSleep;
  probe_vfs.xCurrentTime = probeCurrentTime;
  probe_vfs.xGetLastError = probeGetLastError;
  if (probe_vfs.iVersion >= 2) probe_vfs.xCurrentTimeInt64 = probeCurrentTimeInt64;
  if (probe_vfs.iVersion >= 3) {
    probe_vfs.xSetSystemCall = probeSetSystemCall;
    probe_vfs.xGetSystemCall = probeGetSystemCall;
    probe_vfs.xNextSystemCall = probeNextSystemCall;
  }

  if (sqlite3_vfs_register(&probe_vfs, 0) != SQLITE_OK) return 3;
  if (probe_vfs.xRandomness(&probe_vfs, (int)sizeof(random_bytes),
                            (char *)random_bytes) != (int)sizeof(random_bytes))
    return 4;
  if (sqlite_zig_probe_randomness_calls() == 0) return 5;

  remove_probe_files();
  rc = sqlite3_open_v2("sqlite-zig-hybrid-probe.db", &db,
                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, probe_name);
  if (rc != SQLITE_OK) return 6;
  rc = sqlite3_create_function_v2(db, "zig_add1", 1,
                                  SQLITE_UTF8 | SQLITE_DETERMINISTIC, NULL,
                                  sqlite_zig_probe_scalar, NULL, NULL, NULL);
  if (rc != SQLITE_OK) return 7;
  rc = sqlite3_exec(db,
                    "CREATE TABLE t(x INTEGER);"
                    "INSERT INTO t VALUES(41);"
                    "SELECT zig_add1(x) FROM t;",
                    expect42, &seen, &error);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "hybrid SQL failure: %s\n",
            error != NULL ? error : sqlite3_errmsg(db));
    sqlite3_free(error);
    sqlite3_close(db);
    return 8;
  }
  if (seen != 1) return 9;
  if (sqlite3_close(db) != SQLITE_OK) return 10;
  if (sqlite3_vfs_unregister(&probe_vfs) != SQLITE_OK) return 11;
  remove_probe_files();
  return 0;
}
