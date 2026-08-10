//! Deferred parser ownership from `prepare.c`.

const compiler_ownership = @import("compiler_ownership.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const types = @import("vdbe_types.zig");

pub const CleanupCallback = *const fn (?*parse_types.Sqlite3, ?*anyopaque) callconv(.c) void;

/// Source `sqlite3ParserAddCleanup()`.
pub fn add(parse: *parse_types.Parse, callback: CleanupCallback, pointer_initial: ?*anyopaque) ?*anyopaque {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocRaw(db, @sizeOf(parse_types.ParseCleanup));
    if (raw) |present| {
        const cleanup: *parse_types.ParseCleanup = @ptrCast(@alignCast(present));
        cleanup.pNext = parse.pCleanup;
        cleanup.pPtr = pointer_initial;
        cleanup.xCleanup = callback;
        parse.pCleanup = cleanup;
        return pointer_initial;
    }
    callback(parse.db, pointer_initial);
    return null;
}

pub fn expressionCallback(db_opaque: ?*parse_types.Sqlite3, pointer: ?*anyopaque) callconv(.c) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(db_opaque.?));
    compiler_ownership.deleteExpression(db, if (pointer) |present| @ptrCast(@alignCast(present)) else null);
}

pub fn expressionListCallback(db_opaque: ?*parse_types.Sqlite3, pointer: ?*anyopaque) callconv(.c) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(db_opaque.?));
    compiler_ownership.deleteExpressionList(db, if (pointer) |present| @ptrCast(@alignCast(present)) else null);
}
