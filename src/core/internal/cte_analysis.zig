//! Common-table-expression allocation and ownership from `build.c`.

const std = @import("std");
const compiler_ownership = @import("compiler_ownership.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const sqlite_string = @import("../string.zig");
const types = @import("vdbe_types.zig");

fn withSize(count: usize) usize {
    return @offsetOf(parse_types.With, "a") + count * @sizeOf(parse_types.Cte);
}

/// Source `sqlite3CteNew()`.
pub fn newCte(parse: *parse_types.Parse, name: *const parse_types.Token, columns: ?*parse_types.ExprList, query: ?*parse_types.Select, materialization: u8) ?*parse_types.Cte {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocZero(db, @sizeOf(parse_types.Cte)) orelse {
        compiler_ownership.deleteExpressionList(db, columns);
        compiler_ownership.deleteSelect(db, query);
        return null;
    };
    const result: *parse_types.Cte = @ptrCast(@alignCast(raw));
    result.pSelect = query;
    result.pCols = columns;
    result.zName = schema_analysis.nameFromToken(db, name);
    result.eM10d = materialization;
    return result;
}

/// Source `cteClear()`.
pub fn clearCte(db: *types.Sqlite3, cte: *parse_types.Cte) void {
    compiler_ownership.deleteExpressionList(db, cte.pCols);
    compiler_ownership.deleteSelect(db, cte.pSelect);
    db_allocator.free(db, if (cte.zName) |name| @ptrCast(name) else null);
}

pub fn deleteCte(db: *types.Sqlite3, cte: *parse_types.Cte) void {
    clearCte(db, cte);
    db_allocator.freeNN(db, cte);
}

/// Source `sqlite3WithDelete()`.
pub fn deleteWith(db: *types.Sqlite3, with_optional: ?*parse_types.With) void {
    const with = with_optional orelse return;
    for (with.items()) |*cte| clearCte(db, cte);
    db_allocator.freeNN(db, with);
}

pub fn deleteWithCallback(db_opaque: ?*parse_types.Sqlite3, pointer: ?*anyopaque) callconv(.c) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(db_opaque.?));
    deleteWith(db, if (pointer) |present| @ptrCast(@alignCast(present)) else null);
}

/// Source `sqlite3WithAdd()`.
pub fn addCte(parse: *parse_types.Parse, with_optional: ?*parse_types.With, cte_optional: ?*parse_types.Cte) ?*parse_types.With {
    const cte = cte_optional orelse return with_optional;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (cte.zName != null and with_optional != null) {
        for (with_optional.?.items()) |item| {
            if (sqlite_string.compareInternal(cte.zName.?, item.zName.?) == 0) {
                var buffer: [256]u8 = undefined;
                const message = std.fmt.bufPrint(&buffer, "duplicate WITH table name: {s}", .{cte.zName.?}) catch "duplicate WITH table name";
                db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
                parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
                parse.nErr += 1;
                parse.rc = 1;
            }
        }
    }
    const new_count: usize = if (with_optional) |with| @intCast(with.nCte + 1) else 1;
    const raw = if (with_optional) |with| db_allocator.realloc(db, with, withSize(new_count)) else db_allocator.mallocZero(db, withSize(1));
    const result: *parse_types.With = if (raw) |present| @ptrCast(@alignCast(present)) else {
        deleteCte(db, cte);
        return with_optional;
    };
    result.items()[@intCast(result.nCte)] = cte.*;
    result.nCte += 1;
    db_allocator.freeNN(db, cte);
    return result;
}
