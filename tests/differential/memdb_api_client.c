#include "sqlite3.h"
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail_next_allocation = 0;
typedef union AllocationHeader { size_t size; max_align_t alignment; } AllocationHeader;
static void *fault_malloc(int amount){
  if(fail_next_allocation){ fail_next_allocation=0; return 0; }
  AllocationHeader *allocation = malloc(sizeof(*allocation)+(size_t)amount);
  if(!allocation) return 0;
  allocation->size=(size_t)amount;
  return allocation+1;
}
static void fault_free(void *pointer){ if(pointer) free(((AllocationHeader*)pointer)-1); }
static void *fault_realloc(void *pointer,int amount){
  if(!pointer) return fault_malloc(amount);
  if(fail_next_allocation){ fail_next_allocation=0; return 0; }
  AllocationHeader *allocation=((AllocationHeader*)pointer)-1;
  allocation=realloc(allocation,sizeof(*allocation)+(size_t)amount);
  if(!allocation) return 0;
  allocation->size=(size_t)amount;
  return allocation+1;
}
static int fault_size(void *pointer){ return (int)(((AllocationHeader*)pointer)-1)->size; }
static int fault_roundup(int amount){ return (amount+7)&~7; }
static int fault_init(void *context){ (void)context; return SQLITE_OK; }
static void fault_shutdown(void *context){ (void)context; }
static sqlite3_mem_methods fault_methods={fault_malloc,fault_free,fault_realloc,fault_size,fault_roundup,fault_init,fault_shutdown,0};
#ifdef NATIVE_ENGINE
extern int zig_sqlite3_config_malloc(const sqlite3_mem_methods*);
extern int zig_sqlite3_db_config_flag(sqlite3*,int,int,int*);
extern int zig_sqlite3_db_config_main_name(sqlite3*,const char*);
#endif

static int query_value(sqlite3 *db, const char *sql, sqlite3_int64 *value){
  sqlite3_stmt *statement = 0;
  int rc = sqlite3_prepare_v2(db, sql, -1, &statement, 0);
  if(rc==SQLITE_OK){
    rc = sqlite3_step(statement);
    if(rc==SQLITE_ROW) *value = sqlite3_column_int64(statement, 0);
  }
  sqlite3_finalize(statement);
  return rc;
}

int main(void){
#ifdef NATIVE_ENGINE
  int config_rc=zig_sqlite3_config_malloc(&fault_methods);
#else
  int config_rc=sqlite3_config(SQLITE_CONFIG_MALLOC,&fault_methods);
#endif
  if(config_rc!=SQLITE_OK) return config_rc;
  sqlite3 *source=0, *clone=0, *readonly=0, *malformed=0, *attached=0, *backup_target=0;
  sqlite3_int64 size=-1, borrowed_size=-1, value=-1;
  int rc = sqlite3_open(":memory:", &source);
  if(rc!=SQLITE_OK) return rc;
  rc = sqlite3_exec(source, "CREATE TABLE t(id INTEGER PRIMARY KEY,x); INSERT INTO t VALUES(1,42)", 0, 0, 0);
  if(rc!=SQLITE_OK) return rc;
  unsigned char *seed = sqlite3_serialize(source, "main", &size, 0);
  sqlite3 *normalized=0;
  sqlite3_open(":memory:", &normalized);
  rc=sqlite3_deserialize(normalized,"main",seed,size,size,SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  if(rc!=SQLITE_OK) return rc;
  sqlite3_close(source);
  source=normalized;
  size=-1;

  fail_next_allocation=1;
  unsigned char *failed_image = sqlite3_serialize(source, "main", &size, 0);
  printf("copy-oom\t%d\t%lld\n", failed_image==0, (long long)size);
  unsigned char *image = sqlite3_serialize(source, "main", &size, 0);
  printf("copy\t%d\t%lld\t%d\n", image!=0, (long long)size, image!=0 && memcmp(image,"SQLite format 3",15)==0);
  sqlite3_open(":memory:", &clone);
  rc = sqlite3_deserialize(clone, "main", image, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  unsigned char *borrowed = sqlite3_serialize(clone, "main", &borrowed_size, SQLITE_SERIALIZE_NOCOPY);
  printf("adopt\t%d\t%d\t%lld\n", rc, borrowed==image, (long long)borrowed_size);
  rc = query_value(clone, "SELECT x FROM t", &value);
  printf("query\t%d\t%lld\n", rc, (long long)value);

  unsigned char *readonly_image = sqlite3_serialize(source, "main", &size, 0);
  sqlite3_open(":memory:", &readonly);
  rc = sqlite3_deserialize(readonly, "main", readonly_image, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_READONLY);
  int readonly_flag = sqlite3_db_readonly(readonly, "main");
  int write_rc = sqlite3_exec(readonly, "INSERT INTO t VALUES(99)", 0, 0, 0);
  printf("readonly\t%d\t%d\t%d\n", rc, readonly_flag, write_rc);

  unsigned char *bad = sqlite3_serialize(source, "main", &size, 0);
  memset(bad, 0, (size_t)size);
  memcpy(bad, "not-a-database", 14);
  sqlite3_open(":memory:", &malformed);
  rc = sqlite3_deserialize(malformed, "main", bad, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  borrowed_size = -1;
  borrowed = sqlite3_serialize(malformed, "main", &borrowed_size, SQLITE_SERIALIZE_NOCOPY);
  sqlite3_stmt *statement = 0;
  int prepare_rc = sqlite3_prepare_v2(malformed, "SELECT 1", -1, &statement, 0);
  sqlite3_finalize(statement);
  unsigned char *replacement = sqlite3_serialize(source, "main", &size, 0);
  int replacement_rc = sqlite3_deserialize(malformed, "main", replacement, size, size, SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  printf("malformed\t%d\t%d\t%lld\t%d\t%d\n", rc, borrowed==bad, (long long)borrowed_size, prepare_rc, replacement_rc);

  sqlite3_open(":memory:", &attached);
  int attach_rc=sqlite3_exec(attached,"ATTACH ':memory:' AS aux",0,0,0);
  unsigned char *attached_image=sqlite3_serialize(source,"main",&size,0);
  int attached_deserialize_rc=sqlite3_deserialize(attached,"aux",attached_image,size,size,SQLITE_DESERIALIZE_FREEONCLOSE|SQLITE_DESERIALIZE_RESIZEABLE);
  borrowed_size=-1;
  unsigned char *attached_borrowed=sqlite3_serialize(attached,"aux",&borrowed_size,SQLITE_SERIALIZE_NOCOPY);
  borrowed_size=-1;
  fail_next_allocation=1;
  unsigned char *attached_failed=sqlite3_serialize(attached,"aux",&borrowed_size,0);
  printf("attached-copy-oom\t%d\t%lld\n",attached_failed==0,(long long)borrowed_size);
  unsigned char *attached_replacement=sqlite3_serialize(source,"main",&size,0);
  fail_next_allocation=1;
  int attached_oom_rc=sqlite3_deserialize(attached,"aux",attached_replacement,size,size,0);
  borrowed_size=-1;
  attached_borrowed=sqlite3_serialize(attached,"aux",&borrowed_size,SQLITE_SERIALIZE_NOCOPY);
  printf("attached-deserialize-oom\t%d\t%d\t%lld\n",attached_oom_rc,attached_borrowed==attached_image,(long long)borrowed_size);
  sqlite3_int64 attached_value=-1;
  int attached_query_rc=query_value(attached,"SELECT x FROM aux.t",&attached_value);
  int attached_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.t VALUES(2,43)",0,0,0);
  int attached_update_rc=sqlite3_exec(attached,"UPDATE aux.t SET x=44 WHERE id=2",0,0,0);
  int attached_delete_rc=sqlite3_exec(attached,"DELETE FROM aux.t WHERE id=1",0,0,0);
  sqlite3_int64 attached_final_value=-1;
  int attached_final_query_rc=query_value(attached,"SELECT x FROM aux.t WHERE id=2",&attached_final_value);
  int attached_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.created(id INTEGER PRIMARY KEY,value)",0,0,0);
  int attached_created_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.created VALUES(1,99)",0,0,0);
  sqlite3_int64 attached_created_value=-1;
  int attached_created_query_rc=query_value(attached,"SELECT value FROM aux.created",&attached_created_value);
  int attached_drop_rc=sqlite3_exec(attached,"DROP TABLE aux.created",0,0,0);
#ifdef NATIVE_ENGINE
  int attached_fk_config_rc=zig_sqlite3_db_config_flag(attached,SQLITE_DBCONFIG_ENABLE_FKEY,1,0);
#else
  int attached_fk_config_rc=sqlite3_db_config(attached,SQLITE_DBCONFIG_ENABLE_FKEY,1,0);
#endif
  int attached_parent_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.parent(id INTEGER PRIMARY KEY)",0,0,0);
  int attached_child_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.child(id INTEGER PRIMARY KEY,parent_id REFERENCES parent(id) ON DELETE CASCADE)",0,0,0);
  int attached_parent_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.parent VALUES(1)",0,0,0);
  int attached_child_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.child VALUES(1,1)",0,0,0);
  int attached_invalid_child_rc=sqlite3_exec(attached,"INSERT INTO aux.child VALUES(2,99)",0,0,0);
  int attached_parent_delete_rc=sqlite3_exec(attached,"DELETE FROM aux.parent WHERE id=1",0,0,0);
  sqlite3_int64 attached_child_count=-1;
  int attached_child_count_rc=query_value(attached,"SELECT count(*) FROM aux.child",&attached_child_count);
  int attached_child_drop_rc=sqlite3_exec(attached,"DROP TABLE aux.child",0,0,0);
  int attached_parent_drop_rc=sqlite3_exec(attached,"DROP TABLE aux.parent",0,0,0);
  printf("attached\t%d\t%d\t%d\t%lld\t%d\t%d\t%lld\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\n",attach_rc,attached_deserialize_rc,attached_borrowed==attached_image,(long long)borrowed_size,sqlite3_db_readonly(attached,"aux"),attached_query_rc,(long long)attached_value,attached_insert_rc,attached_update_rc,attached_delete_rc,attached_final_query_rc,(long long)attached_final_value,attached_create_rc,attached_created_insert_rc,attached_created_query_rc,(long long)attached_created_value,attached_drop_rc,attached_fk_config_rc,attached_parent_create_rc,attached_child_create_rc,attached_parent_insert_rc,attached_child_insert_rc,attached_invalid_child_rc,attached_parent_delete_rc,attached_child_count_rc,(long long)attached_child_count,attached_child_drop_rc,attached_parent_drop_rc);

  int actions_parent_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_parent(id INTEGER PRIMARY KEY)",0,0,0);
  int actions_null_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_null(id INTEGER PRIMARY KEY,parent_id REFERENCES action_parent(id) ON DELETE SET NULL)",0,0,0);
  int actions_default_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_default(id INTEGER PRIMARY KEY,parent_id DEFAULT 2 REFERENCES action_parent(id) ON DELETE SET DEFAULT)",0,0,0);
  int actions_restrict_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_restrict(id INTEGER PRIMARY KEY,parent_id REFERENCES action_parent(id) ON DELETE RESTRICT)",0,0,0);
  int actions_parent_one_rc=sqlite3_exec(attached,"INSERT INTO aux.action_parent VALUES(1)",0,0,0);
  int actions_parent_two_rc=sqlite3_exec(attached,"INSERT INTO aux.action_parent VALUES(2)",0,0,0);
  int actions_null_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.action_null VALUES(1,1)",0,0,0);
  int actions_default_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.action_default VALUES(1,1)",0,0,0);
  int actions_restrict_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.action_restrict VALUES(1,1)",0,0,0);
  int actions_restricted_delete_rc=sqlite3_exec(attached,"DELETE FROM aux.action_parent WHERE id=1",0,0,0);
  int actions_restrict_clear_rc=sqlite3_exec(attached,"DELETE FROM aux.action_restrict WHERE id=1",0,0,0);
  int actions_parent_delete_rc=sqlite3_exec(attached,"DELETE FROM aux.action_parent WHERE id=1",0,0,0);
  sqlite3_int64 actions_null_value=-1,actions_default_value=-1;
  int actions_null_query_rc=query_value(attached,"SELECT parent_id FROM aux.action_null",&actions_null_value);
  int actions_default_query_rc=query_value(attached,"SELECT parent_id FROM aux.action_default",&actions_default_value);
  printf("attached-fk-actions\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%lld\n",actions_parent_create_rc,actions_null_create_rc,actions_default_create_rc,actions_restrict_create_rc,actions_parent_one_rc,actions_parent_two_rc,actions_null_insert_rc,actions_default_insert_rc,actions_restrict_insert_rc,actions_restricted_delete_rc,actions_restrict_clear_rc,actions_parent_delete_rc,actions_null_query_rc,(long long)actions_null_value,actions_default_query_rc,(long long)actions_default_value);
  sqlite3_exec(attached,"DROP TABLE aux.action_null",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_default",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_restrict",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_parent",0,0,0);

  int attached_blob_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.blobs(id INTEGER PRIMARY KEY,payload BLOB)",0,0,0);
  int attached_blob_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.blobs VALUES(1,x'01020304')",0,0,0);
  sqlite3_blob *attached_blob=0;
  int attached_blob_open_rc=sqlite3_blob_open(attached,"aux","blobs","payload",1,1,&attached_blob);
  int attached_blob_bytes=sqlite3_blob_bytes(attached_blob);
  unsigned char attached_blob_before[4]={0,0,0,0};
  int attached_blob_read_rc=sqlite3_blob_read(attached_blob,attached_blob_before,4,0);
  const unsigned char attached_blob_patch=0x7f;
  int attached_blob_write_rc=sqlite3_blob_write(attached_blob,&attached_blob_patch,1,1);
  unsigned char attached_blob_after[4]={0,0,0,0};
  int attached_blob_reread_rc=sqlite3_blob_read(attached_blob,attached_blob_after,4,0);
  int attached_blob_detach_rc=sqlite3_exec(attached,"DETACH aux",0,0,0);
  int attached_blob_close_rc=sqlite3_blob_close(attached_blob);
  int attached_blob_drop_rc=sqlite3_exec(attached,"DROP TABLE aux.blobs",0,0,0);
  printf("attached-blob\t%d\t%d\t%d\t%d\t%d\t%u\t%u\t%u\t%u\t%d\t%d\t%u\t%u\t%u\t%u\t%d\t%d\t%d\n",attached_blob_create_rc,attached_blob_insert_rc,attached_blob_open_rc,attached_blob_bytes,attached_blob_read_rc,attached_blob_before[0],attached_blob_before[1],attached_blob_before[2],attached_blob_before[3],attached_blob_write_rc,attached_blob_reread_rc,attached_blob_after[0],attached_blob_after[1],attached_blob_after[2],attached_blob_after[3],attached_blob_detach_rc,attached_blob_close_rc,attached_blob_drop_rc);

  int backup_target_open_rc=sqlite3_open(":memory:",&backup_target);
  int backup_target_attach_rc=sqlite3_exec(backup_target,"ATTACH ':memory:' AS auxcopy",0,0,0);
  sqlite3_backup *attached_backup=sqlite3_backup_init(backup_target,"auxcopy",attached,"aux");
  int attached_backup_init_ok=attached_backup!=0;
  int attached_backup_detach_rc=sqlite3_exec(attached,"DETACH aux",0,0,0);
  int attached_backup_first_step_rc=sqlite3_backup_step(attached_backup,1);
  int attached_backup_first_remaining=sqlite3_backup_remaining(attached_backup);
  int attached_backup_pages=sqlite3_backup_pagecount(attached_backup);
  int attached_backup_step_rc=sqlite3_backup_step(attached_backup,-1);
  int attached_backup_remaining=sqlite3_backup_remaining(attached_backup);
  int attached_backup_finish_rc=sqlite3_backup_finish(attached_backup);
  sqlite3_int64 attached_backup_value=-1;
  int attached_backup_query_rc=query_value(backup_target,"SELECT x FROM auxcopy.t WHERE id=2",&attached_backup_value);
  int attached_backup_target_detach_rc=sqlite3_exec(backup_target,"DETACH auxcopy",0,0,0);
  int attached_backup_target_close_rc=sqlite3_close(backup_target);
  printf("attached-backup\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\n",backup_target_open_rc,backup_target_attach_rc,attached_backup_init_ok,attached_backup_detach_rc,attached_backup_first_step_rc,attached_backup_first_remaining,attached_backup_pages,attached_backup_step_rc,attached_backup_remaining,attached_backup_finish_rc,attached_backup_query_rc,(long long)attached_backup_value,attached_backup_target_detach_rc,attached_backup_target_close_rc);

  int attached_txn_state=sqlite3_txn_state(attached,"aux");
  int attached_txn_all=sqlite3_txn_state(attached,0);
  int attached_txn_missing=sqlite3_txn_state(attached,"missing");
  int attached_wal_log=77,attached_wal_checkpointed=88;
  int attached_wal_rc=sqlite3_wal_checkpoint_v2(attached,"aux",SQLITE_CHECKPOINT_PASSIVE,&attached_wal_log,&attached_wal_checkpointed);
  int missing_wal_log=77,missing_wal_checkpointed=88;
  int missing_wal_rc=sqlite3_wal_checkpoint_v2(attached,"missing",SQLITE_CHECKPOINT_PASSIVE,&missing_wal_log,&missing_wal_checkpointed);
  printf("attached-state\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",attached_txn_state,attached_txn_all,attached_txn_missing,attached_wal_rc,attached_wal_log,attached_wal_checkpointed,missing_wal_rc,missing_wal_log,missing_wal_checkpointed);

  const char *attached_type=(const char*)1,*attached_collation=(const char*)1;
  int attached_not_null=9,attached_primary_key=9,attached_autoincrement=9;
  int attached_metadata_rc=sqlite3_table_column_metadata(attached,"aux","t","id",&attached_type,&attached_collation,&attached_not_null,&attached_primary_key,&attached_autoincrement);
  const char *missing_type=(const char*)1,*missing_collation=(const char*)1;
  int missing_not_null=9,missing_primary_key=9,missing_autoincrement=9;
  int missing_metadata_rc=sqlite3_table_column_metadata(attached,"aux","t","missing",&missing_type,&missing_collation,&missing_not_null,&missing_primary_key,&missing_autoincrement);
  int attached_reserve=-1;
  int attached_reserve_rc=sqlite3_file_control(attached,"aux",SQLITE_FCNTL_RESERVE_BYTES,&attached_reserve);
  int attached_release_rc=sqlite3_db_release_memory(attached);
  int attached_flush_rc=sqlite3_db_cacheflush(attached);
  printf("attached-control\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",attached_metadata_rc,attached_type&&strcmp(attached_type,"INTEGER")==0,attached_collation&&strcmp(attached_collation,"BINARY")==0,attached_not_null,attached_primary_key,attached_autoincrement,missing_metadata_rc,missing_type==0,missing_collation==0,missing_not_null,missing_primary_key,missing_autoincrement,attached_reserve_rc,attached_reserve,attached_release_rc,attached_flush_rc);
  sqlite3_int64 attached_cache_used=0,attached_cache_high=9;
  int attached_cache_status_rc=sqlite3_db_status64(attached,SQLITE_DBSTATUS_CACHE_USED,&attached_cache_used,&attached_cache_high,0);
  sqlite3_int64 attached_hits=0,attached_hits_high=9;
  int attached_hits_rc=sqlite3_db_status64(attached,SQLITE_DBSTATUS_CACHE_HIT,&attached_hits,&attached_hits_high,1);
  sqlite3_int64 attached_hits_after=9,attached_hits_after_high=9;
  int attached_hits_after_rc=sqlite3_db_status64(attached,SQLITE_DBSTATUS_CACHE_HIT,&attached_hits_after,&attached_hits_after_high,0);
  printf("attached-status\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",attached_cache_status_rc,attached_cache_used>=0,attached_cache_high==0,attached_hits_rc,attached_hits>0,attached_hits_high==0,attached_hits_after_rc,attached_hits_after==0);

#ifdef NATIVE_ENGINE
  int main_name_rc=zig_sqlite3_db_config_main_name(source,"primary");
#else
  int main_name_rc=sqlite3_db_config(source,SQLITE_DBCONFIG_MAINDBNAME,"primary");
#endif
  sqlite3_int64 renamed_value=-1,main_alias_value=-1;
  int renamed_query_rc=query_value(source,"SELECT x FROM primary.t",&renamed_value);
  int main_alias_query_rc=query_value(source,"SELECT x FROM main.t",&main_alias_value);
  int renamed_txn_state=sqlite3_txn_state(source,"primary");
  const char *renamed_db_name=sqlite3_db_name(source,0);
  printf("main-name\t%d\t%d\t%lld\t%d\t%lld\t%d\t%d\n",main_name_rc,renamed_query_rc,(long long)renamed_value,main_alias_query_rc,(long long)main_alias_value,renamed_txn_state,renamed_db_name&&strcmp(renamed_db_name,"primary")==0);
  sqlite3_free(attached_replacement);

  int close_clone = sqlite3_close(clone);
  int close_readonly = sqlite3_close(readonly);
  int close_malformed = sqlite3_close(malformed);
  int close_source = sqlite3_close(source);
  int close_attached = sqlite3_close(attached);
  printf("close\t%d\t%d\t%d\t%d\t%d\n", close_clone, close_readonly, close_malformed, close_source, close_attached);
  return 0;
}
