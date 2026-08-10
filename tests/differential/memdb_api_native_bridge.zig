const frontend = @import("frontend");
const statement = frontend.statement;

comptime {
    _ = &frontend.sqlite3_open;
    _ = &frontend.sqlite3_close;
    _ = &frontend.sqlite3_exec;
    _ = &frontend.sqlite3_serialize;
    _ = &frontend.sqlite3_deserialize;
    _ = &frontend.sqlite3_db_readonly;
    _ = &frontend.sqlite3_prepare_v2;
    _ = &statement.sqlite3_step;
    _ = &statement.sqlite3_finalize;
    _ = &statement.sqlite3_column_int64;
}
