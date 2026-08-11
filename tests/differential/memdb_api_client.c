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

static int query_scan(sqlite3 *db, const char *sql, int *count, sqlite3_int64 *first, sqlite3_int64 *last){
  sqlite3_stmt *statement = 0;
  int rc = sqlite3_prepare_v2(db, sql, -1, &statement, 0);
  *count=0;
  if(rc==SQLITE_OK){
    while((rc=sqlite3_step(statement))==SQLITE_ROW){
      sqlite3_int64 value=sqlite3_column_int64(statement,0);
      if(*count==0) *first=value;
      *last=value;
      *count+=1;
    }
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
  int temporary_create_rc=sqlite3_exec(clone,"CREATE TEMP TABLE t(id INTEGER PRIMARY KEY,x)",0,0,0);
  int temporary_insert_rc=sqlite3_exec(clone,"INSERT INTO t VALUES(1,20)",0,0,0);
  sqlite3_int64 temporary_value=-1,temporary_main_value=-1,temporary_after_update=-1,temporary_count=-1,temporary_main_after_drop=-1;
  int temporary_query_rc=query_value(clone,"SELECT x FROM t",&temporary_value);
  int temporary_main_query_rc=query_value(clone,"SELECT x FROM main.t",&temporary_main_value);
  int temporary_update_rc=sqlite3_exec(clone,"UPDATE t SET x=21 WHERE id=1",0,0,0);
  int temporary_update_query_rc=query_value(clone,"SELECT x FROM temp.t",&temporary_after_update);
  int temporary_delete_rc=sqlite3_exec(clone,"DELETE FROM t WHERE id=1",0,0,0);
  int temporary_count_rc=query_value(clone,"SELECT count(*) FROM t",&temporary_count);
  int temporary_drop_rc=sqlite3_exec(clone,"DROP TABLE t",0,0,0);
  int temporary_main_after_drop_rc=query_value(clone,"SELECT x FROM t",&temporary_main_after_drop);
  printf("temporary\t%d\t%d\t%d\t%lld\t%d\t%lld\t%d\t%d\t%lld\t%d\t%d\t%lld\t%d\t%d\t%lld\n",temporary_create_rc,temporary_insert_rc,temporary_query_rc,(long long)temporary_value,temporary_main_query_rc,(long long)temporary_main_value,temporary_update_rc,temporary_update_query_rc,(long long)temporary_after_update,temporary_delete_rc,temporary_count_rc,(long long)temporary_count,temporary_drop_rc,temporary_main_after_drop_rc,(long long)temporary_main_after_drop);
  int transaction_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int transaction_insert_rollback_rc=sqlite3_exec(clone,"INSERT INTO main.t VALUES(43)",0,0,0);
  int transaction_active=sqlite3_get_autocommit(clone);
  sqlite3_int64 transaction_before_rollback_count=-1,transaction_after_rollback_count=-1,transaction_after_commit_count=-1;
  int transaction_before_rollback_rc=query_value(clone,"SELECT count(*) FROM main.t",&transaction_before_rollback_count);
  int transaction_rollback_rc=sqlite3_exec(clone,"ROLLBACK",0,0,0);
  int transaction_rollback_autocommit=sqlite3_get_autocommit(clone);
  int transaction_after_rollback_rc=query_value(clone,"SELECT count(*) FROM main.t",&transaction_after_rollback_count);
  int transaction_second_begin_rc=sqlite3_exec(clone,"BEGIN TRANSACTION",0,0,0);
  int transaction_insert_commit_rc=sqlite3_exec(clone,"INSERT INTO main.t VALUES(44)",0,0,0);
  int transaction_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  int transaction_commit_autocommit=sqlite3_get_autocommit(clone);
  int transaction_after_commit_rc=query_value(clone,"SELECT count(*) FROM main.t",&transaction_after_commit_count);
  printf("transaction\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%d\t%d\t%lld\n",transaction_begin_rc,transaction_insert_rollback_rc,transaction_active,transaction_before_rollback_rc,(long long)transaction_before_rollback_count,transaction_rollback_rc,transaction_rollback_autocommit,transaction_after_rollback_rc,(long long)transaction_after_rollback_count,transaction_second_begin_rc,transaction_insert_commit_rc,transaction_commit_rc,transaction_commit_autocommit,transaction_after_commit_rc,(long long)transaction_after_commit_count);
  int ddl_rollback_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int ddl_rollback_create_rc=sqlite3_exec(clone,"CREATE TABLE txn_ddl_rollback(id INTEGER PRIMARY KEY)",0,0,0);
  int ddl_rollback_rc=sqlite3_exec(clone,"ROLLBACK",0,0,0);
  sqlite3_int64 ddl_rollback_count=-1,ddl_commit_count=-1,ddl_drop_count=-1;
  int ddl_rollback_query_rc=query_value(clone,"SELECT count(*) FROM txn_ddl_rollback",&ddl_rollback_count);
  int ddl_commit_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int ddl_commit_create_rc=sqlite3_exec(clone,"CREATE TABLE txn_ddl_commit(id INTEGER PRIMARY KEY)",0,0,0);
  int ddl_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  int ddl_commit_insert_rc=sqlite3_exec(clone,"INSERT INTO txn_ddl_commit VALUES(1)",0,0,0);
  int ddl_commit_query_rc=query_value(clone,"SELECT count(*) FROM txn_ddl_commit",&ddl_commit_count);
  int ddl_drop_create_rc=sqlite3_exec(clone,"CREATE TABLE txn_ddl_drop(id INTEGER PRIMARY KEY)",0,0,0);
  int ddl_drop_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int ddl_drop_rc=sqlite3_exec(clone,"DROP TABLE txn_ddl_drop",0,0,0);
  int ddl_drop_rollback_rc=sqlite3_exec(clone,"ROLLBACK",0,0,0);
  int ddl_drop_insert_rc=sqlite3_exec(clone,"INSERT INTO txn_ddl_drop VALUES(1)",0,0,0);
  int ddl_drop_query_rc=query_value(clone,"SELECT count(*) FROM txn_ddl_drop",&ddl_drop_count);
  printf("transaction-ddl\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\n",ddl_rollback_begin_rc,ddl_rollback_create_rc,ddl_rollback_rc,ddl_rollback_query_rc,ddl_commit_begin_rc,ddl_commit_create_rc,ddl_commit_rc,ddl_commit_insert_rc,ddl_commit_query_rc,(long long)ddl_commit_count,ddl_drop_create_rc,ddl_drop_begin_rc,ddl_drop_rc,ddl_drop_rollback_rc,ddl_drop_insert_rc,ddl_drop_query_rc,(long long)ddl_drop_count);
  int index_table_create_rc=sqlite3_exec(clone,"CREATE TABLE index_data(id INTEGER PRIMARY KEY,value)",0,0,0);
  int index_data_insert_rc=sqlite3_exec(clone,"INSERT INTO index_data VALUES(1,30); INSERT INTO index_data VALUES(2,10); INSERT INTO index_data VALUES(3,20)",0,0,0);
  int index_create_rc=sqlite3_exec(clone,"CREATE INDEX idx_index_data_value ON index_data(value)",0,0,0);
  int index_duplicate_rc=sqlite3_exec(clone,"CREATE INDEX idx_index_data_value ON index_data(value)",0,0,0);
  int index_if_not_exists_rc=sqlite3_exec(clone,"CREATE INDEX IF NOT EXISTS idx_index_data_value ON index_data(value)",0,0,0);
  sqlite3_int64 index_first_value=-1,index_last_value=-1,index_after_first=-1,index_after_last=-1;
  int index_count=-1,index_after_count=-1;
  int index_query_rc=query_scan(clone,"SELECT value FROM index_data INDEXED BY idx_index_data_value",&index_count,&index_first_value,&index_last_value);
  int index_post_insert_rc=sqlite3_exec(clone,"INSERT INTO index_data VALUES(4,5)",0,0,0);
  int index_post_update_rc=sqlite3_exec(clone,"UPDATE index_data SET value=15 WHERE id=1",0,0,0);
  int index_post_delete_rc=sqlite3_exec(clone,"DELETE FROM index_data WHERE id=2",0,0,0);
  int index_after_query_rc=query_scan(clone,"SELECT value FROM index_data INDEXED BY idx_index_data_value",&index_after_count,&index_after_first,&index_after_last);
  int index_rollback_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int index_rollback_insert_rc=sqlite3_exec(clone,"INSERT INTO index_data VALUES(5,1)",0,0,0);
  int index_rollback_update_rc=sqlite3_exec(clone,"UPDATE index_data SET value=2 WHERE id=3",0,0,0);
  int index_rollback_delete_rc=sqlite3_exec(clone,"DELETE FROM index_data WHERE id=4",0,0,0);
  int index_rollback_rc=sqlite3_exec(clone,"ROLLBACK",0,0,0);
  sqlite3_int64 index_rollback_first=-1,index_rollback_last=-1,index_commit_first=-1,index_commit_last=-1;
  int index_rollback_count=-1,index_commit_count=-1;
  int index_rollback_query_rc=query_scan(clone,"SELECT value FROM index_data INDEXED BY idx_index_data_value",&index_rollback_count,&index_rollback_first,&index_rollback_last);
  int index_commit_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int index_commit_insert_rc=sqlite3_exec(clone,"INSERT INTO index_data VALUES(5,1)",0,0,0);
  int index_commit_update_rc=sqlite3_exec(clone,"UPDATE index_data SET value=2 WHERE id=3",0,0,0);
  int index_commit_delete_rc=sqlite3_exec(clone,"DELETE FROM index_data WHERE id=4",0,0,0);
  int index_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  int index_commit_query_rc=query_scan(clone,"SELECT value FROM index_data INDEXED BY idx_index_data_value",&index_commit_count,&index_commit_first,&index_commit_last);
  printf("secondary-index\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\n",index_table_create_rc,index_data_insert_rc,index_create_rc,index_duplicate_rc,index_if_not_exists_rc,index_query_rc,index_count,(long long)index_first_value,(long long)index_last_value,index_post_insert_rc,index_post_update_rc,index_post_delete_rc,index_after_query_rc,index_after_count,(long long)index_after_first,(long long)index_after_last,index_rollback_begin_rc,index_rollback_insert_rc,index_rollback_update_rc,index_rollback_delete_rc,index_rollback_rc,index_rollback_query_rc,index_rollback_count,(long long)index_rollback_first,(long long)index_rollback_last,index_commit_begin_rc,index_commit_insert_rc,index_commit_update_rc,index_commit_delete_rc,index_commit_rc,index_commit_query_rc,index_commit_count,(long long)index_commit_first,(long long)index_commit_last);
  int index_drop_rollback_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int index_drop_rollback_drop_rc=sqlite3_exec(clone,"DROP INDEX idx_index_data_value",0,0,0);
  int index_drop_rollback_rc=sqlite3_exec(clone,"ROLLBACK",0,0,0);
  sqlite3_int64 index_drop_rollback_first=-1,index_drop_rollback_last=-1;
  int index_drop_rollback_count=-1;
  int index_drop_rollback_query_rc=query_scan(clone,"SELECT value FROM index_data INDEXED BY idx_index_data_value",&index_drop_rollback_count,&index_drop_rollback_first,&index_drop_rollback_last);
  int index_drop_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int index_drop_rc=sqlite3_exec(clone,"DROP INDEX idx_index_data_value",0,0,0);
  int index_drop_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  sqlite3_int64 index_missing_value=-1;
  int index_missing_query_rc=query_value(clone,"SELECT value FROM index_data INDEXED BY idx_index_data_value",&index_missing_value);
  int index_recreate_rc=sqlite3_exec(clone,"CREATE INDEX idx_index_data_value ON index_data(value)",0,0,0);
  int index_table_drop_rc=sqlite3_exec(clone,"DROP TABLE index_data",0,0,0);
  int index_reuse_table_rc=sqlite3_exec(clone,"CREATE TABLE index_reuse(id INTEGER PRIMARY KEY,value)",0,0,0);
  int index_name_reuse_rc=sqlite3_exec(clone,"CREATE INDEX idx_index_data_value ON index_reuse(value)",0,0,0);
  printf("secondary-index-drop\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",index_drop_rollback_begin_rc,index_drop_rollback_drop_rc,index_drop_rollback_rc,index_drop_rollback_query_rc,index_drop_rollback_count,(long long)index_drop_rollback_first,(long long)index_drop_rollback_last,index_drop_begin_rc,index_drop_rc,index_drop_commit_rc,index_missing_query_rc,index_recreate_rc,index_table_drop_rc,index_reuse_table_rc,index_name_reuse_rc);
#ifdef NATIVE_ENGINE
  int deferred_fk_config_rc=zig_sqlite3_db_config_flag(clone,SQLITE_DBCONFIG_ENABLE_FKEY,1,0);
#else
  int deferred_fk_config_rc=sqlite3_db_config(clone,SQLITE_DBCONFIG_ENABLE_FKEY,1,0);
#endif
  int deferred_parent_create_rc=sqlite3_exec(clone,"CREATE TABLE deferred_parent(id INTEGER PRIMARY KEY)",0,0,0);
  int deferred_child_create_rc=sqlite3_exec(clone,"CREATE TABLE deferred_child(id INTEGER PRIMARY KEY,parent_id REFERENCES deferred_parent(id) DEFERRABLE INITIALLY DEFERRED)",0,0,0);
  int deferred_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int deferred_child_insert_rc=sqlite3_exec(clone,"INSERT INTO deferred_child VALUES(1,9)",0,0,0);
  int deferred_failed_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  int deferred_failed_commit_autocommit=sqlite3_get_autocommit(clone);
  int deferred_parent_insert_rc=sqlite3_exec(clone,"INSERT INTO deferred_parent VALUES(9)",0,0,0);
  int deferred_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  int deferred_commit_autocommit=sqlite3_get_autocommit(clone);
  int deferred_delete_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int deferred_parent_delete_rc=sqlite3_exec(clone,"DELETE FROM deferred_parent WHERE id=9",0,0,0);
  int deferred_delete_rollback_rc=sqlite3_exec(clone,"ROLLBACK",0,0,0);
  int transaction_error_begin_rc=sqlite3_exec(clone,"BEGIN",0,0,0);
  int transaction_error_first_insert_rc=sqlite3_exec(clone,"INSERT INTO deferred_parent VALUES(10)",0,0,0);
  int transaction_error_duplicate_rc=sqlite3_exec(clone,"INSERT INTO deferred_parent VALUES(10)",0,0,0);
  int transaction_error_commit_rc=sqlite3_exec(clone,"COMMIT",0,0,0);
  sqlite3_int64 deferred_parent_count=-1,deferred_child_count=-1;
  int deferred_parent_query_rc=query_value(clone,"SELECT count(*) FROM deferred_parent",&deferred_parent_count);
  int deferred_child_query_rc=query_value(clone,"SELECT count(*) FROM deferred_child",&deferred_child_count);
  printf("deferred-fk\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%lld\n",deferred_fk_config_rc,deferred_parent_create_rc,deferred_child_create_rc,deferred_begin_rc,deferred_child_insert_rc,deferred_failed_commit_rc,deferred_failed_commit_autocommit,deferred_parent_insert_rc,deferred_commit_rc,deferred_commit_autocommit,deferred_delete_begin_rc,deferred_parent_delete_rc,deferred_delete_rollback_rc,transaction_error_begin_rc,transaction_error_first_insert_rc,transaction_error_duplicate_rc,transaction_error_commit_rc,deferred_parent_query_rc,(long long)deferred_parent_count,deferred_child_query_rc,(long long)deferred_child_count);
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
  int attached_index_create_rc=sqlite3_exec(attached,"CREATE INDEX aux.idx_t_x ON t(x)",0,0,0);
  int attached_index_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.t VALUES(3,30)",0,0,0);
  int attached_index_update_rc=sqlite3_exec(attached,"UPDATE aux.t SET x=40 WHERE id=2",0,0,0);
  sqlite3_int64 attached_index_first=-1,attached_index_last=-1;
  int attached_index_count=-1;
  int attached_index_query_rc=query_scan(attached,"SELECT x FROM aux.t INDEXED BY idx_t_x",&attached_index_count,&attached_index_first,&attached_index_last);
  int attached_index_delete_rc=sqlite3_exec(attached,"DELETE FROM aux.t WHERE id=3",0,0,0);
  int attached_index_drop_rc=sqlite3_exec(attached,"DROP INDEX aux.idx_t_x",0,0,0);
  sqlite3_int64 attached_index_missing_value=-1;
  int attached_index_missing_rc=query_value(attached,"SELECT x FROM aux.t INDEXED BY idx_t_x",&attached_index_missing_value);
  printf("attached-index\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\t%d\n",attached_index_create_rc,attached_index_insert_rc,attached_index_update_rc,attached_index_query_rc,attached_index_count,(long long)attached_index_first,(long long)attached_index_last,attached_index_delete_rc,attached_index_drop_rc,attached_index_missing_rc);
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
  int actions_null_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_null(id INTEGER PRIMARY KEY,parent_id REFERENCES action_parent(id) ON DELETE SET NULL ON UPDATE SET NULL)",0,0,0);
  int actions_default_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_default(id INTEGER PRIMARY KEY,parent_id DEFAULT 2 REFERENCES action_parent(id) ON DELETE SET DEFAULT ON UPDATE SET DEFAULT)",0,0,0);
  int actions_restrict_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_restrict(id INTEGER PRIMARY KEY,parent_id REFERENCES action_parent(id) ON DELETE RESTRICT ON UPDATE RESTRICT)",0,0,0);
  int actions_cascade_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.action_cascade(id INTEGER PRIMARY KEY,parent_id REFERENCES action_parent(id) ON UPDATE CASCADE)",0,0,0);
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
  int actions_parent_three_rc=sqlite3_exec(attached,"INSERT INTO aux.action_parent VALUES(3)",0,0,0);
  int actions_null_reset_rc=sqlite3_exec(attached,"UPDATE aux.action_null SET parent_id=3 WHERE id=1",0,0,0);
  int actions_default_reset_rc=sqlite3_exec(attached,"UPDATE aux.action_default SET parent_id=3 WHERE id=1",0,0,0);
  int actions_cascade_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.action_cascade VALUES(1,3)",0,0,0);
  int actions_cascade_index_rc=sqlite3_exec(attached,"CREATE INDEX aux.idx_action_cascade_parent ON action_cascade(parent_id)",0,0,0);
  int actions_update_restrict_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.action_restrict VALUES(2,3)",0,0,0);
  int actions_restricted_update_rc=sqlite3_exec(attached,"UPDATE aux.action_parent SET id=4 WHERE id=3",0,0,0);
  int actions_update_restrict_clear_rc=sqlite3_exec(attached,"DELETE FROM aux.action_restrict WHERE id=2",0,0,0);
  int actions_parent_update_rc=sqlite3_exec(attached,"UPDATE aux.action_parent SET id=4 WHERE id=3",0,0,0);
  sqlite3_int64 actions_update_null_value=-1,actions_update_default_value=-1,actions_update_cascade_value=-1;
  int actions_update_null_query_rc=query_value(attached,"SELECT parent_id FROM aux.action_null",&actions_update_null_value);
  int actions_update_default_query_rc=query_value(attached,"SELECT parent_id FROM aux.action_default",&actions_update_default_value);
  int actions_update_cascade_query_rc=query_value(attached,"SELECT parent_id FROM aux.action_cascade",&actions_update_cascade_value);
  sqlite3_int64 actions_index_cascade_value=-1;
  int actions_index_cascade_query_rc=query_value(attached,"SELECT parent_id FROM aux.action_cascade INDEXED BY idx_action_cascade_parent",&actions_index_cascade_value);
  printf("attached-fk-index-action\t%d\t%d\t%lld\n",actions_cascade_index_rc,actions_index_cascade_query_rc,(long long)actions_index_cascade_value);
  printf("attached-fk-actions\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%lld\t%d\t%lld\n",actions_parent_create_rc,actions_null_create_rc,actions_default_create_rc,actions_restrict_create_rc,actions_cascade_create_rc,actions_parent_one_rc,actions_parent_two_rc,actions_null_insert_rc,actions_default_insert_rc,actions_restrict_insert_rc,actions_restricted_delete_rc,actions_restrict_clear_rc,actions_parent_delete_rc,actions_null_query_rc,(long long)actions_null_value,actions_default_query_rc,(long long)actions_default_value,actions_parent_three_rc,actions_null_reset_rc,actions_default_reset_rc,actions_cascade_insert_rc,actions_update_restrict_insert_rc,actions_restricted_update_rc,actions_update_restrict_clear_rc,actions_parent_update_rc,actions_update_null_query_rc,(long long)actions_update_null_value,actions_update_default_query_rc,(long long)actions_update_default_value,actions_update_cascade_query_rc,(long long)actions_update_cascade_value);
  sqlite3_exec(attached,"DROP TABLE aux.action_null",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_default",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_restrict",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_cascade",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.action_parent",0,0,0);

  int attached_deferred_parent_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.deferred_parent(id INTEGER PRIMARY KEY)",0,0,0);
  int attached_deferred_child_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.deferred_child(id INTEGER PRIMARY KEY,parent_id REFERENCES deferred_parent(id) DEFERRABLE INITIALLY DEFERRED)",0,0,0);
  int attached_deferred_begin_rc=sqlite3_exec(attached,"BEGIN",0,0,0);
  int attached_deferred_child_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.deferred_child VALUES(1,9)",0,0,0);
  int attached_deferred_failed_commit_rc=sqlite3_exec(attached,"COMMIT",0,0,0);
  int attached_deferred_failed_commit_autocommit=sqlite3_get_autocommit(attached);
  int attached_deferred_parent_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.deferred_parent VALUES(9)",0,0,0);
  int attached_deferred_commit_rc=sqlite3_exec(attached,"COMMIT",0,0,0);
  int attached_deferred_commit_autocommit=sqlite3_get_autocommit(attached);
  sqlite3_int64 attached_deferred_child_count=-1;
  int attached_deferred_query_rc=query_value(attached,"SELECT count(*) FROM aux.deferred_child",&attached_deferred_child_count);
  printf("attached-deferred-fk\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\n",attached_deferred_parent_create_rc,attached_deferred_child_create_rc,attached_deferred_begin_rc,attached_deferred_child_insert_rc,attached_deferred_failed_commit_rc,attached_deferred_failed_commit_autocommit,attached_deferred_parent_insert_rc,attached_deferred_commit_rc,attached_deferred_commit_autocommit,attached_deferred_query_rc,(long long)attached_deferred_child_count);
  sqlite3_exec(attached,"DROP TABLE aux.deferred_child",0,0,0);
  sqlite3_exec(attached,"DROP TABLE aux.deferred_parent",0,0,0);

  int attached_blob_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.blobs(id INTEGER PRIMARY KEY,payload BLOB)",0,0,0);
  int attached_blob_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.blobs VALUES(1,x'01020304')",0,0,0);
  int attached_blob_index_create_rc=sqlite3_exec(attached,"CREATE INDEX aux.idx_blobs_payload ON blobs(payload)",0,0,0);
  sqlite3_blob *attached_indexed_write_blob=0,*attached_indexed_read_blob=0;
  int attached_indexed_write_blob_rc=sqlite3_blob_open(attached,"aux","blobs","payload",1,1,&attached_indexed_write_blob);
  int attached_indexed_read_blob_rc=sqlite3_blob_open(attached,"aux","blobs","payload",1,0,&attached_indexed_read_blob);
  int attached_indexed_read_blob_close_rc=sqlite3_blob_close(attached_indexed_read_blob);
  int attached_blob_index_drop_rc=sqlite3_exec(attached,"DROP INDEX aux.idx_blobs_payload",0,0,0);
  printf("attached-blob-guard\t%d\t%d\t%d\t%d\t%d\t%d\n",attached_blob_index_create_rc,attached_indexed_write_blob_rc,attached_indexed_write_blob==0,attached_indexed_read_blob_rc,attached_indexed_read_blob_close_rc,attached_blob_index_drop_rc);
  int attached_blob_parent_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.blob_parent(id INTEGER PRIMARY KEY)",0,0,0);
  int attached_blob_child_create_rc=sqlite3_exec(attached,"CREATE TABLE aux.blob_child(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES blob_parent(id))",0,0,0);
  int attached_blob_parent_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.blob_parent VALUES(1)",0,0,0);
  int attached_blob_child_insert_rc=sqlite3_exec(attached,"INSERT INTO aux.blob_child VALUES(1,1)",0,0,0);
  sqlite3_blob *attached_fk_write_blob=0;
  int attached_fk_write_blob_rc=sqlite3_blob_open(attached,"aux","blob_child","parent_id",1,1,&attached_fk_write_blob);
  int attached_blob_child_drop_rc=sqlite3_exec(attached,"DROP TABLE aux.blob_child",0,0,0);
  int attached_blob_parent_drop_rc=sqlite3_exec(attached,"DROP TABLE aux.blob_parent",0,0,0);
  printf("attached-blob-fk-guard\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",attached_blob_parent_create_rc,attached_blob_child_create_rc,attached_blob_parent_insert_rc,attached_blob_child_insert_rc,attached_fk_write_blob_rc,attached_fk_write_blob==0,attached_blob_child_drop_rc,attached_blob_parent_drop_rc);
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
  sqlite3_int64 attached_backup_replace_size=0;
  unsigned char *attached_backup_replace_image=sqlite3_serialize(attached,"aux",&attached_backup_replace_size,0);
  int attached_backup_source_replace_rc=sqlite3_deserialize(attached,"aux",attached_backup_replace_image,attached_backup_replace_size,attached_backup_replace_size,0);
  sqlite3_free(attached_backup_replace_image);
  int attached_backup_source_update_rc=sqlite3_exec(attached,"UPDATE aux.t SET x=45 WHERE id=2",0,0,0);
  int attached_backup_source_ddl_rc=sqlite3_exec(attached,"CREATE TABLE aux.after_backup(v)",0,0,0);
  int attached_backup_step_rc=sqlite3_backup_step(attached_backup,-1);
  int attached_backup_remaining=sqlite3_backup_remaining(attached_backup);
  int attached_backup_finish_rc=sqlite3_backup_finish(attached_backup);
  sqlite3_int64 attached_backup_value=-1;
  int attached_backup_query_rc=query_value(backup_target,"SELECT x FROM auxcopy.t WHERE id=2",&attached_backup_value);
  sqlite3_int64 attached_backup_schema_count=-1;
  int attached_backup_schema_rc=query_value(backup_target,"SELECT count(*) FROM auxcopy.after_backup",&attached_backup_schema_count);
  int attached_backup_target_detach_rc=sqlite3_exec(backup_target,"DETACH auxcopy",0,0,0);
  int attached_backup_target_close_rc=sqlite3_close(backup_target);
  printf("attached-backup\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%lld\t%d\t%d\n",backup_target_open_rc,backup_target_attach_rc,attached_backup_init_ok,attached_backup_detach_rc,attached_backup_first_step_rc,attached_backup_first_remaining,attached_backup_pages,attached_backup_source_replace_rc,attached_backup_source_update_rc,attached_backup_source_ddl_rc,attached_backup_step_rc,attached_backup_remaining,attached_backup_finish_rc,attached_backup_query_rc,(long long)attached_backup_value,attached_backup_schema_rc,(long long)attached_backup_schema_count,attached_backup_target_detach_rc,attached_backup_target_close_rc);

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
