const frontend = @import("frontend");
const statement = frontend.statement;

comptime {
    _ = &frontend.sqlite3_open;
    _ = &frontend.sqlite3_close;
    _ = &frontend.sqlite3_exec;
    _ = &frontend.sqlite3_serialize;
    _ = &frontend.sqlite3_deserialize;
    _ = &frontend.sqlite3_db_readonly;
    _ = &frontend.sqlite3_blob_open;
    _ = &frontend.sqlite3_blob_bytes;
    _ = &frontend.sqlite3_blob_read;
    _ = &frontend.sqlite3_blob_write;
    _ = &frontend.sqlite3_blob_close;
    _ = &frontend.sqlite3_backup_init;
    _ = &frontend.sqlite3_backup_step;
    _ = &frontend.sqlite3_backup_finish;
    _ = &frontend.sqlite3_backup_remaining;
    _ = &frontend.sqlite3_backup_pagecount;
    _ = &frontend.sqlite3_txn_state;
    _ = &frontend.sqlite3_wal_checkpoint_v2;
    _ = &frontend.sqlite3_table_column_metadata;
    _ = &frontend.sqlite3_file_control;
    _ = &frontend.sqlite3_db_release_memory;
    _ = &frontend.sqlite3_db_cacheflush;
    _ = &frontend.zig_sqlite3_db_config_flag;
    _ = &frontend.sqlite3_prepare_v2;
    _ = &statement.sqlite3_step;
    _ = &statement.sqlite3_finalize;
    _ = &statement.sqlite3_column_int64;
}
