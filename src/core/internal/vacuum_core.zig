//! VACUUM compilation, guarded SQL recursion, and database-copy lifecycle.
const std = @import("std");
const backup = @import("backup_core.zig");

pub const Error = error{ OutOfMemory, Sql, Transaction, StatementsActive, NonTextFilename, OutputExists, Copy };
pub const ExecuteResult = struct { rows: []const []const u8 = &.{} };
pub const ExecuteCallback = *const fn (?*anyopaque, []const u8) Error!ExecuteResult;

pub const Executor = struct {
    context: ?*anyopaque = null,
    execute_callback: ExecuteCallback,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    main: *backup.Btree,
    vacuum_into: ?*backup.Btree = null,
    auto_commit: bool = true,
    active_statements: usize = 1,
    writable_schema: bool = false,
    ignore_checks: bool = false,
    foreign_keys: bool = true,
    reverse_order: bool = false,
    defensive: bool = false,
    count_rows: bool = false,
    trace_mask: u8 = 0,
    changes: i64 = 0,
    total_changes: i64 = 0,
    schema_generation: usize = 0,
};

pub const VacuumOperation = struct { database_index: usize, into: ?[]const u8 };

fn permittedNestedSql(sql: []const u8) bool {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    return trimmed.len >= 3 and (std.mem.eql(u8, trimmed[0..3], "CRE") or std.mem.eql(u8, trimmed[0..3], "INS"));
}

/// Source `execSql()`.
pub fn executeSql(executor: Executor, sql: []const u8) Error!void {
    const result = try executor.execute_callback(executor.context, sql);
    if (!std.ascii.startsWithIgnoreCase(std.mem.trim(u8, sql, " \t\r\n"), "SELECT")) return;
    for (result.rows) |nested| {
        if (permittedNestedSql(nested)) try executeSql(executor, nested);
    }
}

fn appendQuoted(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) Error!void {
    output.append(allocator, '\'') catch return error.OutOfMemory;
    for (value) |byte| {
        output.append(allocator, byte) catch return error.OutOfMemory;
        if (byte == '\'') output.append(allocator, byte) catch return error.OutOfMemory;
    }
    output.append(allocator, '\'') catch return error.OutOfMemory;
}

/// Source `execSqlF()`.
pub fn executeSqlFormat(allocator: std.mem.Allocator, executor: Executor, format: []const u8, arguments: []const []const u8) Error!void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var argument_index: usize = 0;
    var index: usize = 0;
    while (index < format.len) {
        if (format[index] != '%' or index + 1 >= format.len) {
            output.append(allocator, format[index]) catch return error.OutOfMemory;
            index += 1;
            continue;
        }
        const conversion = format[index + 1];
        if (conversion == '%') {
            output.append(allocator, '%') catch return error.OutOfMemory;
        } else {
            if (argument_index >= arguments.len) return error.Sql;
            const argument = arguments[argument_index];
            argument_index += 1;
            if (conversion == 'Q') {
                try appendQuoted(&output, allocator, argument);
            } else if (conversion == 's' or conversion == 'w') {
                output.appendSlice(allocator, argument) catch return error.OutOfMemory;
            } else {
                return error.Sql;
            }
        }
        index += 2;
    }
    try executeSql(executor, output.items);
}

/// Source `sqlite3Vacuum()`.
pub fn compileVacuum(database_index: usize, into: ?[]const u8) VacuumOperation {
    return .{ .database_index = database_index, .into = into };
}

/// Source `sqlite3RunVacuum()`.
pub fn runVacuum(connection: *Connection, operation: VacuumOperation) Error!void {
    _ = operation.database_index;
    if (!connection.auto_commit) return error.Transaction;
    if (connection.active_statements > 1) return error.StatementsActive;
    if (operation.into) |filename| {
        if (filename.len == 0) return error.NonTextFilename;
        const output = connection.vacuum_into orelse return error.NonTextFilename;
        if (output.data.items.len != 0) return error.OutputExists;
    }

    const saved = .{
        .writable_schema = connection.writable_schema,
        .ignore_checks = connection.ignore_checks,
        .foreign_keys = connection.foreign_keys,
        .reverse_order = connection.reverse_order,
        .defensive = connection.defensive,
        .count_rows = connection.count_rows,
        .trace_mask = connection.trace_mask,
        .changes = connection.changes,
        .total_changes = connection.total_changes,
    };
    defer {
        connection.writable_schema = saved.writable_schema;
        connection.ignore_checks = saved.ignore_checks;
        connection.foreign_keys = saved.foreign_keys;
        connection.reverse_order = saved.reverse_order;
        connection.defensive = saved.defensive;
        connection.count_rows = saved.count_rows;
        connection.trace_mask = saved.trace_mask;
        connection.changes = saved.changes;
        connection.total_changes = saved.total_changes;
        connection.auto_commit = true;
    }
    connection.writable_schema = true;
    connection.ignore_checks = true;
    connection.foreign_keys = false;
    connection.reverse_order = false;
    connection.defensive = false;
    connection.count_rows = false;
    connection.trace_mask = 0;

    var temporary = backup.Btree{
        .allocator = connection.allocator,
        .name = "vacuum",
        .page_size = connection.main.page_size,
        .reserve_bytes = connection.main.reserve_bytes,
        .schema_cookie = connection.main.schema_cookie +% 1,
        .default_cache_size = connection.main.default_cache_size,
        .text_encoding = connection.main.text_encoding,
        .user_version = connection.main.user_version,
        .application_id = connection.main.application_id,
        .auto_vacuum = connection.main.auto_vacuum,
        .transaction = .write,
    };
    defer temporary.deinit();
    temporary.data.appendSlice(connection.allocator, connection.main.data.items) catch return error.OutOfMemory;
    if (operation.into) |_| {
        const output = connection.vacuum_into.?;
        output.transaction = .write;
        temporary.transaction = .read;
        backup.copyFile(output, &temporary) catch return error.Copy;
        output.reserve_bytes = temporary.reserve_bytes;
        output.default_cache_size = temporary.default_cache_size;
        output.text_encoding = temporary.text_encoding;
        output.user_version = temporary.user_version;
        output.application_id = temporary.application_id;
        output.auto_vacuum = temporary.auto_vacuum;
    } else {
        connection.main.transaction = .write;
        temporary.transaction = .read;
        backup.copyFile(connection.main, &temporary) catch return error.Copy;
        connection.main.reserve_bytes = temporary.reserve_bytes;
        connection.main.default_cache_size = temporary.default_cache_size;
        connection.main.text_encoding = temporary.text_encoding;
        connection.main.user_version = temporary.user_version;
        connection.main.application_id = temporary.application_id;
        connection.main.auto_vacuum = temporary.auto_vacuum;
    }
    connection.schema_generation += 1;
}

test "checkpoint batch VACUUM INTO preserves source metadata and copies the image" {
    var main = backup.Btree{
        .allocator = std.testing.allocator,
        .name = "main",
        .page_size = 512,
        .reserve_bytes = 8,
        .schema_cookie = 4,
        .user_version = 17,
        .application_id = 23,
    };
    defer main.deinit();
    try main.data.appendSlice(std.testing.allocator, "database-image");
    var output = backup.Btree{ .allocator = std.testing.allocator, .name = "output", .page_size = 512 };
    defer output.deinit();
    var connection = Connection{ .allocator = std.testing.allocator, .main = &main, .vacuum_into = &output };
    try runVacuum(&connection, .{ .database_index = 0, .into = "copy.db" });
    try std.testing.expectEqualStrings("database-image", output.data.items);
    try std.testing.expectEqual(@as(u8, 8), output.reserve_bytes);
    try std.testing.expectEqual(@as(u32, 17), output.user_version);
    try std.testing.expectEqual(@as(u32, 23), output.application_id);
    try std.testing.expectEqual(@as(usize, 1), connection.schema_generation);
}
