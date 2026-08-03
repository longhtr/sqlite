#include "sqlite3.c"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint64_t digest_page(const unsigned char *data, int length){
  uint64_t hash = UINT64_C(14695981039346656037);
  int i;
  for(i=0; i<length; i++){
    hash ^= data[i];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static int public_validation(const char *path){
  sqlite3 *db = 0;
  sqlite3_stmt *statement = 0;
  char uri[320];
  int rc;
  sqlite3_snprintf(sizeof(uri), uri, "file:%s?immutable=1", path);
  rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_URI, 0);
  if( rc==SQLITE_OK ){
    rc = sqlite3_prepare_v2(db, "SELECT * FROM sqlite_schema", -1, &statement, 0);
  }
  if( rc==SQLITE_OK ){
    rc = sqlite3_step(statement);
    if( rc==SQLITE_ROW || rc==SQLITE_DONE ) rc = SQLITE_OK;
  }
  sqlite3_finalize(statement);
  sqlite3_close(db);
  return rc;
}

static void reinitialize_page(DbPage *page){ (void)page; }
static int stop_busy(void *context){ (void)context; return 0; }

static int pager_trace(const char *name, const char *path){
  sqlite3_vfs *vfs = sqlite3_vfs_find(0);
  Pager *pager = 0;
  DbPage *page1 = 0;
  DbPage *again = 0;
  unsigned char header[100];
  u32 page_size = 4096;
  int pages = 0;
  int rc;
  int probe;
  u64 hits = 0;
  u64 misses = 0;

  rc = sqlite3PagerOpen(vfs, &pager, path, 16, 0,
      SQLITE_OPEN_READONLY|SQLITE_OPEN_MAIN_DB, reinitialize_page);
  if( rc!=SQLITE_OK ){
    printf("pager\t%s\t%d\t0\t0\n", name, rc);
    return rc;
  }
  rc = sqlite3PagerReadFileheader(pager, 100, header);
  if( rc==SQLITE_OK && memcmp(header, "SQLite format 3", 15)==0 ){
    page_size = ((u32)header[16]<<8) | header[17];
    if( page_size==1 ) page_size = 65536;
    rc = sqlite3PagerSetPagesize(pager, &page_size, header[20]);
  }
  if( rc==SQLITE_OK ) rc = sqlite3PagerSharedLock(pager);
  if( rc==SQLITE_OK ) sqlite3PagerPagecount(pager, &pages);
  printf("pager\t%s\t%d\t%u\t%d\n", name, rc, page_size, pages);
  if( rc!=SQLITE_OK ){
    sqlite3PagerClose(pager, 0);
    return rc;
  }

  rc = sqlite3PagerGet(pager, 1, &page1, 0);
  printf("page\t%s\t1\t%d\t%016llx\n", name, rc,
      rc==SQLITE_OK ? (unsigned long long)digest_page(sqlite3PagerGetData(page1), (int)page_size) : 0);
  if( rc!=SQLITE_OK ){
    sqlite3PagerClose(pager, 0);
    return rc;
  }
  rc = sqlite3PagerGet(pager, 1, &again, 0);
  printf("hit\t%s\t%d\t%d\n", name, rc,
      rc==SQLITE_OK ? sqlite3PagerPageRefcount(again) : 0);
  if( rc==SQLITE_OK ) sqlite3PagerUnrefNotNull(again);

  for(probe=2; probe<=pages+1 && probe<=3; probe++){
    DbPage *page = 0;
    rc = sqlite3PagerGet(pager, (Pgno)probe, &page, 0);
    printf("page\t%s\t%d\t%d\t%016llx\n", name, probe, rc,
        rc==SQLITE_OK ? (unsigned long long)digest_page(sqlite3PagerGetData(page), (int)page_size) : 0);
    if( rc==SQLITE_OK ) sqlite3PagerUnrefNotNull(page);
  }
  sqlite3PagerCacheStat(pager, SQLITE_DBSTATUS_CACHE_HIT, 0, &hits);
  sqlite3PagerCacheStat(pager, SQLITE_DBSTATUS_CACHE_MISS, 0, &misses);
  printf("stats\t%s\t%llu\t%llu\n", name,
      (unsigned long long)hits, (unsigned long long)misses);
  sqlite3PagerUnrefPageOne(page1);
  rc = sqlite3PagerClose(pager, 0);
  if( rc!=SQLITE_OK ) return rc;
  return SQLITE_OK;
}

static int special_traces(void){
  sqlite3_vfs *vfs = sqlite3_vfs_find(0);
  Pager *pager = 0;
  sqlite3_file *blocker = 0;
  int output_flags = 0;
  int rc;

  rc = sqlite3PagerOpen(vfs, &pager, ".reference-build/pager-differential/hot.db", 16, 0,
      SQLITE_OPEN_READONLY|SQLITE_OPEN_MAIN_DB, reinitialize_page);
  if( rc==SQLITE_OK ) rc = sqlite3PagerSharedLock(pager);
  printf("hot\t%d\n", rc);
  if( pager ) sqlite3PagerClose(pager, 0);
  if( rc!=SQLITE_READONLY_ROLLBACK ) return 40;

  blocker = sqlite3_malloc(vfs->szOsFile);
  if( !blocker ) return 41;
  memset(blocker, 0, vfs->szOsFile);
  rc = vfs->xOpen(vfs, ".reference-build/pager-differential/busy.db", blocker,
      SQLITE_OPEN_READWRITE|SQLITE_OPEN_MAIN_DB, &output_flags);
  if( rc==SQLITE_OK ) rc = blocker->pMethods->xLock(blocker, SQLITE_LOCK_SHARED);
  if( rc==SQLITE_OK ) rc = blocker->pMethods->xLock(blocker, SQLITE_LOCK_RESERVED);
  if( rc==SQLITE_OK ) rc = blocker->pMethods->xLock(blocker, SQLITE_LOCK_EXCLUSIVE);
  if( rc!=SQLITE_OK ) return 42;
  pager = 0;
  rc = sqlite3PagerOpen(vfs, &pager, ".reference-build/pager-differential/busy.db", 16, 0,
      SQLITE_OPEN_READONLY|SQLITE_OPEN_MAIN_DB, reinitialize_page);
  if( rc==SQLITE_OK ){
    sqlite3PagerSetBusyHandler(pager, stop_busy, 0);
    rc = sqlite3PagerSharedLock(pager);
  }
  printf("busy\t%d\n", rc);
  if( pager ) sqlite3PagerClose(pager, 0);
  blocker->pMethods->xUnlock(blocker, SQLITE_LOCK_NONE);
  blocker->pMethods->xClose(blocker);
  sqlite3_free(blocker);
  return rc==SQLITE_BUSY ? SQLITE_OK : 43;
}

int main(void){
  static const char *names[] = {
    "empty.db",
    "valid-empty-512.db",
    "valid-empty-4096.db",
    "valid-two-page-4096.db",
    "valid-empty-65536.db",
    "truncated-second-page.db",
    "valid-wal-header-without-wal.db",
    "malformed-short-header.db",
    "malformed-magic.db",
    "malformed-page-size.db",
    "malformed-payload-fractions.db",
  };
  size_t i;
  int rc = sqlite3_initialize();
  if( rc!=SQLITE_OK ) return rc;
  for(i=0; i<sizeof(names)/sizeof(names[0]); i++){
    char path[256];
    int validation;
    sqlite3_snprintf(sizeof(path), path, "tests/fixtures/pager/%s", names[i]);
    validation = public_validation(path);
    printf("validate\t%s\t%d\n", names[i], validation);
    if( validation==SQLITE_OK ){
      rc = pager_trace(names[i], path);
      if( rc!=SQLITE_OK ) return rc;
    }
  }
  rc = special_traces();
  if( rc!=SQLITE_OK ) return rc;
  return sqlite3_shutdown();
}
