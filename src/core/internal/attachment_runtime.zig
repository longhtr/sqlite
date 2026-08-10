//! Attached-database expression, runtime, and compile operations from `attach.c`.
const std = @import("std");

pub const Error = error{ OutOfMemory, TooMany, Duplicate, NotFound, Locked, CannotDetach, Resolve, Open };
pub const ExpressionTag = enum { identifier, string, compound, null_ };
pub const Expression = struct { tag: ExpressionTag, text: []const u8 = "" };
pub const Database = struct {
    name: [:0]u8,
    filename: [:0]u8,
    native_context: ?*anyopaque = null,
    transaction_active: bool = false,
    backup_active: bool = false,
    encoding: u8 = 1,
};
pub const OpenCallback = *const fn (?*anyopaque, []const u8, bool, bool) ?*anyopaque;
pub const CloseCallback = *const fn (?*anyopaque, *anyopaque) void;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    databases: std.ArrayList(Database) = .empty,
    maximum_attached: usize = 10,
    encoding: u8 = 1,
    allow_create: bool = true,
    allow_write: bool = true,
    context: ?*anyopaque = null,
    open_callback: ?OpenCallback = null,
    close_callback: ?CloseCallback = null,
    schema_generation: usize = 0,

    pub fn deinit(self: *Connection) void {
        for (self.databases.items) |database| {
            if (database.native_context) |native| if (self.close_callback) |close| close(self.context, native);
            self.allocator.free(database.name);
            self.allocator.free(database.filename);
        }
        self.databases.deinit(self.allocator);
    }
};

pub fn initializeConnection(allocator: std.mem.Allocator, main_filename: []const u8, context: ?*anyopaque, open_callback: ?OpenCallback, close_callback: ?CloseCallback) Error!Connection {
    var connection = Connection{ .allocator = allocator, .context = context, .open_callback = open_callback, .close_callback = close_callback };
    const main_name = allocator.dupeZ(u8, "main") catch return error.OutOfMemory;
    const main_file = allocator.dupeZ(u8, main_filename) catch {
        allocator.free(main_name);
        return error.OutOfMemory;
    };
    connection.databases.append(allocator, .{ .name = main_name, .filename = main_file }) catch {
        allocator.free(main_file);
        allocator.free(main_name);
        return error.OutOfMemory;
    };
    const temp_name = allocator.dupeZ(u8, "temp") catch {
        connection.deinit();
        return error.OutOfMemory;
    };
    const temp_file = allocator.dupeZ(u8, "") catch {
        allocator.free(temp_name);
        connection.deinit();
        return error.OutOfMemory;
    };
    connection.databases.append(allocator, .{ .name = temp_name, .filename = temp_file }) catch {
        allocator.free(temp_file);
        allocator.free(temp_name);
        connection.deinit();
        return error.OutOfMemory;
    };
    return connection;
}

pub const OperationTag = enum { attach, detach };
pub const Operation = struct {
    tag: OperationTag,
    filename: ?Expression,
    database_name: Expression,
    key: ?Expression,
    expire_all: bool,
};

/// Source `resolveAttachExpr()`.
pub fn resolveAttachExpression(expression: ?*Expression) Error!void {
    const value = expression orelse return;
    if (value.tag == .identifier) {
        value.tag = .string;
    } else if (value.tag == .compound) {
        return error.Resolve;
    }
}

fn databaseIndex(connection: *const Connection, name: []const u8) ?usize {
    for (connection.databases.items, 0..) |database, index| {
        if (std.ascii.eqlIgnoreCase(database.name, name)) return index;
        if (index == 0 and std.ascii.eqlIgnoreCase(name, "main")) return index;
    }
    return null;
}

pub fn findDatabase(connection: *Connection, name: []const u8) ?*Database {
    const index = databaseIndex(connection, name) orelse return null;
    return &connection.databases.items[index];
}

/// Source `attachFunc()`.
pub fn attachFunction(connection: *Connection, filename: []const u8, name: []const u8) Error!void {
    if (connection.databases.items.len >= connection.maximum_attached + 2) return error.TooMany;
    if (databaseIndex(connection, name) != null) return error.Duplicate;
    const native_context = if (connection.open_callback) |open|
        open(connection.context, filename, connection.allow_create, connection.allow_write) orelse return error.Open
    else
        null;
    errdefer if (native_context) |native| if (connection.close_callback) |close| close(connection.context, native);
    const owned_name = connection.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    errdefer connection.allocator.free(owned_name);
    const owned_filename = connection.allocator.dupeZ(u8, filename) catch return error.OutOfMemory;
    errdefer connection.allocator.free(owned_filename);
    connection.databases.append(connection.allocator, .{
        .name = owned_name,
        .filename = owned_filename,
        .native_context = native_context,
        .encoding = connection.encoding,
    }) catch return error.OutOfMemory;
    connection.schema_generation += 1;
}

/// Source `detachFunc()`.
pub fn detachFunction(connection: *Connection, name: []const u8) Error!void {
    const index = databaseIndex(connection, name) orelse return error.NotFound;
    if (index < 2) return error.CannotDetach;
    const database = &connection.databases.items[index];
    if (database.transaction_active or database.backup_active) return error.Locked;
    if (database.native_context) |native| if (connection.close_callback) |close| close(connection.context, native);
    connection.allocator.free(database.name);
    connection.allocator.free(database.filename);
    _ = connection.databases.orderedRemove(index);
    connection.schema_generation += 1;
}

/// Source `codeAttach()`.
pub fn codeAttachment(tag: OperationTag, filename: ?Expression, database_name: Expression, key: ?Expression) Error!Operation {
    var result = Operation{
        .tag = tag,
        .filename = filename,
        .database_name = database_name,
        .key = key,
        .expire_all = tag == .detach,
    };
    if (result.filename) |*value| try resolveAttachExpression(value);
    try resolveAttachExpression(&result.database_name);
    if (result.key) |*value| try resolveAttachExpression(value);
    return result;
}

/// Source `sqlite3Detach()`.
pub fn compileDetach(database_name: Expression) Error!Operation {
    return codeAttachment(.detach, null, database_name, null);
}

/// Source `sqlite3Attach()`.
pub fn compileAttach(filename: Expression, database_name: Expression, key: ?Expression) Error!Operation {
    return codeAttachment(.attach, filename, database_name, key);
}
