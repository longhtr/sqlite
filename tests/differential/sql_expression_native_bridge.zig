const std = @import("std");
const frontend = @import("frontend");
const statement = frontend.statement;
const btree = frontend.btree;

const Harness = struct {
    memory: btree.vfs.MemoryVfs,
    adapter: btree.vfs.AbiAdapter,
    database: btree.Database,
    connection: frontend.Connection,
};

fn createHarness(bytes: []const u8) ?*frontend.sqlite3 {
    if (frontend.global.initializeProcess() != 0) return null;
    const allocator = std.heap.c_allocator;
    const harness = allocator.create(Harness) catch return null;
    harness.memory = btree.vfs.MemoryVfs.init(allocator);
    const opened = harness.memory.open("phase13.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    if (opened.rc != btree.vfs.OK) {
        harness.memory.deinit();
        allocator.destroy(harness);
        return null;
    }
    if (opened.file.?.write(bytes, 0) != btree.vfs.OK or opened.file.?.sync() != btree.vfs.OK or harness.memory.closeAndDestroy(opened.file.?) != btree.vfs.OK) {
        harness.memory.deinit();
        allocator.destroy(harness);
        return null;
    }
    harness.adapter = btree.vfs.AbiAdapter.init("phase13-sql", &harness.memory);
    const database = btree.Database.openWritable(allocator, &harness.adapter.abi, "phase13.db");
    if (database.result != .ok) {
        harness.memory.deinit();
        allocator.destroy(harness);
        return null;
    }
    harness.database = database.database.?;
    harness.connection = frontend.Connection.init(allocator, &harness.database);
    return frontend.toOpaque(&harness.connection);
}

export fn sqlite3_zig_phase13_connection() ?*frontend.sqlite3 {
    return createHarness(@embedFile("ddl_fixture"));
}

export fn sqlite3_zig_phase13_index_connection() ?*frontend.sqlite3 {
    return createHarness(@embedFile("index_fixture"));
}

fn harnessFrom(pointer: ?*frontend.sqlite3) ?*Harness {
    const connection: *frontend.Connection = if (pointer) |value| @ptrCast(@alignCast(value)) else return null;
    return @fieldParentPtr("connection", connection);
}

export fn sqlite3_zig_phase13_schema_count(pointer: ?*frontend.sqlite3) c_int {
    const harness = harnessFrom(pointer) orelse return -1;
    const opened = harness.database.openCursor(1, .table);
    if (opened.result != .ok) return -1;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    return @intCast(cursor.count());
}

export fn sqlite3_zig_phase13_close(pointer: ?*frontend.sqlite3) c_int {
    const harness = harnessFrom(pointer) orelse return 21;
    const rc = harness.database.close().toC();
    harness.memory.deinit();
    std.heap.c_allocator.destroy(harness);
    return rc;
}

comptime {
    _ = &frontend.sqlite3_prepare;
    _ = &frontend.sqlite3_prepare_v2;
    _ = &frontend.sqlite3_prepare_v3;
    _ = &frontend.sqlite3_prepare16;
    _ = &frontend.sqlite3_prepare16_v2;
    _ = &frontend.sqlite3_prepare16_v3;
    _ = &statement.sqlite3_step;
    _ = &statement.sqlite3_reset;
    _ = &statement.sqlite3_finalize;
    _ = &statement.sqlite3_bind_int;
    _ = &statement.sqlite3_bind_text;
    _ = &statement.sqlite3_bind_parameter_count;
    _ = &statement.sqlite3_bind_parameter_index;
    _ = &statement.sqlite3_column_count;
    _ = &statement.sqlite3_column_type;
    _ = &statement.sqlite3_column_int64;
    _ = &statement.sqlite3_column_double;
    _ = &statement.sqlite3_column_text;
    _ = &statement.sqlite3_column_blob;
    _ = &statement.sqlite3_column_bytes;
    _ = &statement.sqlite3_column_name;
    _ = &statement.sqlite3_stmt_readonly;
}
