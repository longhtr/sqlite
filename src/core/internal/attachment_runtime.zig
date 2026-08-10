//! Attached-database expression, runtime, and compile operations from `attach.c`.
const std = @import("std");

pub const Error = error{ OutOfMemory, TooMany, Duplicate, NotFound, Locked, CannotDetach, Resolve, Open };
pub const ExpressionTag = enum { identifier, string, compound, null_ };
pub const Expression = struct { tag: ExpressionTag, text: []const u8 = "" };
pub const Database = struct {
    name: []u8,
    filename: []u8,
    transaction_active: bool = false,
    backup_active: bool = false,
    encoding: u8 = 1,
};
pub const OpenCallback = *const fn (?*anyopaque, []const u8, bool, bool) bool;
pub const CloseCallback = *const fn (?*anyopaque, []const u8) void;

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
            self.allocator.free(database.name);
            self.allocator.free(database.filename);
        }
        self.databases.deinit(self.allocator);
    }
};

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

/// Source `attachFunc()`.
pub fn attachFunction(connection: *Connection, filename: []const u8, name: []const u8) Error!void {
    if (connection.databases.items.len >= connection.maximum_attached + 2) return error.TooMany;
    if (databaseIndex(connection, name) != null) return error.Duplicate;
    if (connection.open_callback) |open| {
        if (!open(connection.context, filename, connection.allow_create, connection.allow_write)) return error.Open;
    }
    const owned_name = connection.allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer connection.allocator.free(owned_name);
    const owned_filename = connection.allocator.dupe(u8, filename) catch return error.OutOfMemory;
    errdefer connection.allocator.free(owned_filename);
    connection.databases.append(connection.allocator, .{
        .name = owned_name,
        .filename = owned_filename,
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
    if (connection.close_callback) |close| close(connection.context, database.filename);
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
