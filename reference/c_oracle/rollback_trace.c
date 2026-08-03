#include "sqlite3.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum TraceKind {
  TRACE_OTHER,
  TRACE_DATABASE,
  TRACE_JOURNAL,
  TRACE_WAL
} TraceKind;

typedef enum TraceEvent {
  EVENT_JOURNAL_WRITE,
  EVENT_JOURNAL_SYNC,
  EVENT_DATABASE_WRITE,
  EVENT_DATABASE_SYNC,
  EVENT_JOURNAL_DELETE,
  EVENT_DATABASE_LOCK,
  EVENT_DATABASE_UNLOCK
} TraceEvent;

typedef struct TraceFile {
  sqlite3_file base;
  sqlite3_file *real;
  const sqlite3_io_methods *real_methods;
  TraceKind kind;
} TraceFile;

static sqlite3_vfs trace_vfs;
static sqlite3_vfs *base_vfs;
static sqlite3_io_methods trace_methods;
static TraceEvent events[4096];
static int event_count;
static const char trace_vfs_name[] = "sqlite-zig-rollback-trace";
static const char database_name[] = "sqlite-zig-rollback-trace.db";

static void record_event(TraceEvent event) {
  if (event_count < (int)(sizeof(events) / sizeof(events[0]))) {
    events[event_count++] = event;
  }
}

static TraceFile *traceFile(sqlite3_file *file) {
  return (TraceFile *)file;
}

static int traceClose(sqlite3_file *file) {
  TraceFile *trace = traceFile(file);
  int rc = trace->real_methods->xClose(trace->real);
  trace->base.pMethods = NULL;
  return rc;
}
static int traceRead(sqlite3_file *file, void *buffer, int amount,
                     sqlite3_int64 offset) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xRead(trace->real, buffer, amount, offset);
}
static int traceWrite(sqlite3_file *file, const void *buffer, int amount,
                      sqlite3_int64 offset) {
  TraceFile *trace = traceFile(file);
  if (trace->kind == TRACE_JOURNAL) record_event(EVENT_JOURNAL_WRITE);
  if (trace->kind == TRACE_DATABASE) record_event(EVENT_DATABASE_WRITE);
  return trace->real_methods->xWrite(trace->real, buffer, amount, offset);
}
static int traceTruncate(sqlite3_file *file, sqlite3_int64 size) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xTruncate(trace->real, size);
}
static int traceSync(sqlite3_file *file, int flags) {
  TraceFile *trace = traceFile(file);
  if (trace->kind == TRACE_JOURNAL) record_event(EVENT_JOURNAL_SYNC);
  if (trace->kind == TRACE_DATABASE) record_event(EVENT_DATABASE_SYNC);
  return trace->real_methods->xSync(trace->real, flags);
}
static int traceFileSize(sqlite3_file *file, sqlite3_int64 *size) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xFileSize(trace->real, size);
}
static int traceLock(sqlite3_file *file, int lock) {
  TraceFile *trace = traceFile(file);
  if (trace->kind == TRACE_DATABASE) record_event(EVENT_DATABASE_LOCK);
  return trace->real_methods->xLock(trace->real, lock);
}
static int traceUnlock(sqlite3_file *file, int lock) {
  TraceFile *trace = traceFile(file);
  if (trace->kind == TRACE_DATABASE) record_event(EVENT_DATABASE_UNLOCK);
  return trace->real_methods->xUnlock(trace->real, lock);
}
static int traceCheckReservedLock(sqlite3_file *file, int *out) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xCheckReservedLock(trace->real, out);
}
static int traceFileControl(sqlite3_file *file, int op, void *argument) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xFileControl(trace->real, op, argument);
}
static int traceSectorSize(sqlite3_file *file) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xSectorSize(trace->real);
}
static int traceDeviceCharacteristics(sqlite3_file *file) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->xDeviceCharacteristics(trace->real);
}
static int traceShmMap(sqlite3_file *file, int page, int page_size, int extend,
                       void volatile **out) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->iVersion >= 2 && trace->real_methods->xShmMap
             ? trace->real_methods->xShmMap(trace->real, page, page_size,
                                            extend, out)
             : SQLITE_IOERR_SHMMAP;
}
static int traceShmLock(sqlite3_file *file, int offset, int count, int flags) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->iVersion >= 2 && trace->real_methods->xShmLock
             ? trace->real_methods->xShmLock(trace->real, offset, count, flags)
             : SQLITE_IOERR_SHMLOCK;
}
static void traceShmBarrier(sqlite3_file *file) {
  TraceFile *trace = traceFile(file);
  if (trace->real_methods->iVersion >= 2 && trace->real_methods->xShmBarrier)
    trace->real_methods->xShmBarrier(trace->real);
}
static int traceShmUnmap(sqlite3_file *file, int delete_flag) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->iVersion >= 2 && trace->real_methods->xShmUnmap
             ? trace->real_methods->xShmUnmap(trace->real, delete_flag)
             : SQLITE_OK;
}
static int traceFetch(sqlite3_file *file, sqlite3_int64 offset, int amount,
                      void **out) {
  TraceFile *trace = traceFile(file);
  if (trace->real_methods->iVersion >= 3 && trace->real_methods->xFetch)
    return trace->real_methods->xFetch(trace->real, offset, amount, out);
  *out = NULL;
  return SQLITE_OK;
}
static int traceUnfetch(sqlite3_file *file, sqlite3_int64 offset, void *ptr) {
  TraceFile *trace = traceFile(file);
  return trace->real_methods->iVersion >= 3 && trace->real_methods->xUnfetch
             ? trace->real_methods->xUnfetch(trace->real, offset, ptr)
             : SQLITE_OK;
}

static TraceKind kind_from_flags(int flags) {
  if (flags & SQLITE_OPEN_MAIN_DB) return TRACE_DATABASE;
  if (flags & SQLITE_OPEN_MAIN_JOURNAL) return TRACE_JOURNAL;
  if (flags & SQLITE_OPEN_WAL) return TRACE_WAL;
  return TRACE_OTHER;
}

static int traceOpen(sqlite3_vfs *vfs, sqlite3_filename name,
                     sqlite3_file *file, int flags, int *out_flags) {
  TraceFile *trace = (TraceFile *)file;
  int rc;
  (void)vfs;
  memset(trace, 0, sizeof(*trace));
  trace->real = (sqlite3_file *)((unsigned char *)file + sizeof(*trace));
  trace->kind = kind_from_flags(flags);
  rc = base_vfs->xOpen(base_vfs, name, trace->real, flags, out_flags);
  if (trace->real->pMethods != NULL) {
    trace->real_methods = trace->real->pMethods;
    trace->base.pMethods = &trace_methods;
  }
  return rc;
}
static int traceDelete(sqlite3_vfs *vfs, const char *name, int sync_dir) {
  (void)vfs;
  if (name != NULL && strstr(name, "-journal") != NULL)
    record_event(EVENT_JOURNAL_DELETE);
  return base_vfs->xDelete(base_vfs, name, sync_dir);
}
static int traceAccess(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
  (void)vfs;
  return base_vfs->xAccess(base_vfs, name, flags, out);
}
static int traceFullPathname(sqlite3_vfs *vfs, const char *name, int out_len,
                             char *out) {
  (void)vfs;
  return base_vfs->xFullPathname(base_vfs, name, out_len, out);
}

static int first_event(TraceEvent wanted) {
  int i;
  for (i = 0; i < event_count; ++i)
    if (events[i] == wanted) return i;
  return -1;
}
static int last_event_before(TraceEvent wanted, int limit) {
  int result = -1;
  int i;
  for (i = 0; i < limit; ++i)
    if (events[i] == wanted) result = i;
  return result;
}
static const char *event_name(TraceEvent event) {
  switch (event) {
    case EVENT_JOURNAL_WRITE: return "journal-write";
    case EVENT_JOURNAL_SYNC: return "journal-sync";
    case EVENT_DATABASE_WRITE: return "database-write";
    case EVENT_DATABASE_SYNC: return "database-sync";
    case EVENT_JOURNAL_DELETE: return "journal-delete";
    case EVENT_DATABASE_LOCK: return "database-lock";
    case EVENT_DATABASE_UNLOCK: return "database-unlock";
  }
  return "unknown";
}
static void remove_trace_files(void) {
  remove(database_name);
  remove("sqlite-zig-rollback-trace.db-journal");
  remove("sqlite-zig-rollback-trace.db-wal");
  remove("sqlite-zig-rollback-trace.db-shm");
}

int main(void) {
  sqlite3 *db = NULL;
  char *error = NULL;
  int journal_write;
  int database_write;
  int journal_sync;
  int database_sync;
  int journal_delete;
  int i;

  memset(&trace_methods, 0, sizeof(trace_methods));
  trace_methods.iVersion = 3;
  trace_methods.xClose = traceClose;
  trace_methods.xRead = traceRead;
  trace_methods.xWrite = traceWrite;
  trace_methods.xTruncate = traceTruncate;
  trace_methods.xSync = traceSync;
  trace_methods.xFileSize = traceFileSize;
  trace_methods.xLock = traceLock;
  trace_methods.xUnlock = traceUnlock;
  trace_methods.xCheckReservedLock = traceCheckReservedLock;
  trace_methods.xFileControl = traceFileControl;
  trace_methods.xSectorSize = traceSectorSize;
  trace_methods.xDeviceCharacteristics = traceDeviceCharacteristics;
  trace_methods.xShmMap = traceShmMap;
  trace_methods.xShmLock = traceShmLock;
  trace_methods.xShmBarrier = traceShmBarrier;
  trace_methods.xShmUnmap = traceShmUnmap;
  trace_methods.xFetch = traceFetch;
  trace_methods.xUnfetch = traceUnfetch;

  if (sqlite3_initialize() != SQLITE_OK) return 1;
  base_vfs = sqlite3_vfs_find(NULL);
  if (base_vfs == NULL) return 2;
  memcpy(&trace_vfs, base_vfs, sizeof(trace_vfs));
  trace_vfs.pNext = NULL;
  trace_vfs.zName = trace_vfs_name;
  trace_vfs.pAppData = base_vfs;
  trace_vfs.szOsFile = (int)(sizeof(TraceFile) + base_vfs->szOsFile);
  trace_vfs.xOpen = traceOpen;
  trace_vfs.xDelete = traceDelete;
  trace_vfs.xAccess = traceAccess;
  trace_vfs.xFullPathname = traceFullPathname;
  if (sqlite3_vfs_register(&trace_vfs, 0) != SQLITE_OK) return 3;

  remove_trace_files();
  if (sqlite3_open_v2(database_name, &db,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                      trace_vfs_name) != SQLITE_OK)
    return 4;
  if (sqlite3_exec(db,
                   "PRAGMA journal_mode=DELETE;"
                   "PRAGMA synchronous=FULL;"
                   "CREATE TABLE t(x INTEGER);",
                   NULL, NULL, &error) != SQLITE_OK)
    return 5;

  event_count = 0;
  if (sqlite3_exec(db, "BEGIN; INSERT INTO t VALUES(1); COMMIT;",
                   NULL, NULL, &error) != SQLITE_OK) {
    fprintf(stderr, "rollback trace SQL failure: %s\n", error);
    sqlite3_free(error);
    return 6;
  }

  journal_write = first_event(EVENT_JOURNAL_WRITE);
  database_write = first_event(EVENT_DATABASE_WRITE);
  journal_sync = database_write >= 0
                     ? last_event_before(EVENT_JOURNAL_SYNC, database_write)
                     : -1;
  database_sync = first_event(EVENT_DATABASE_SYNC);
  journal_delete = first_event(EVENT_JOURNAL_DELETE);

  for (i = 0; i < event_count; ++i)
    printf("%03d %s\n", i, event_name(events[i]));

  if (journal_write < 0 || journal_sync < 0 || database_write < 0 ||
      database_sync < 0 || journal_delete < 0)
    return 7;
  if (!(journal_write < journal_sync && journal_sync < database_write &&
        database_write < database_sync && database_sync < journal_delete))
    return 8;

  if (sqlite3_close(db) != SQLITE_OK) return 9;
  if (sqlite3_vfs_unregister(&trace_vfs) != SQLITE_OK) return 10;
  remove_trace_files();
  return 0;
}
