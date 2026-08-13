//! Attached-database and SQLite filename helpers from `build.c`, `attach.c`, and `main.c`.

const std = @import("std");
const sqlite_string = @import("../string.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const types = @import("vdbe_types.zig");

/// Source `databaseName()`.
pub fn databaseName(name_initial: [*]const u8) [*:0]const u8 {
    var address = @intFromPtr(name_initial);
    while (true) : (address -= 1) {
        const prefix: [*]const u8 = @ptrFromInt(address - 4);
        if (prefix[0] == 0 and prefix[1] == 0 and prefix[2] == 0 and prefix[3] == 0) return @ptrFromInt(address);
    }
}

/// Source `appendText()`.
pub fn appendText(output: [*]u8, text: [*:0]const u8) [*]u8 {
    const length = std.mem.len(text);
    @memcpy(output[0 .. length + 1], text[0 .. length + 1]);
    return output + length + 1;
}

/// Source `sqlite3FindDbName()`.
pub fn findDatabaseName(db: *types.Sqlite3, name_optional: ?[*:0]const u8) c_int {
    const name = name_optional orelse return -1;
    var index = db.nDb - 1;
    while (index >= 0) : (index -= 1) {
        const database = &db.aDb.?[@intCast(index)];
        if (sqlite_string.compare(database.zDbSName, name) == 0 or
            (index == 0 and sqlite_string.compare("main", name) == 0)) return index;
    }
    return -1;
}

/// Source `sqlite3FindDb()`.
pub fn findDatabase(db: *types.Sqlite3, token: *const parse_types.Token) c_int {
    const name = schema_analysis.nameFromToken(db, token);
    defer db_allocator.free(db, if (name) |present| present else null);
    return findDatabaseName(db, name);
}

/// Source `sqlite3SchemaToIndex()`.
pub fn schemaToIndex(db: *types.Sqlite3, target: ?*schema.Schema) c_int {
    const present = target orelse return -32768;
    for (db.aDb.?[0..@intCast(db.nDb)], 0..) |attached, index| if (attached.pSchema == present) return @intCast(index);
    unreachable;
}

/// Source `sqlite3DbNameToBtree()`.
pub fn databaseNameToBtree(db: *types.Sqlite3, name: ?[*:0]const u8) ?*types.Btree {
    const index = if (name != null) findDatabaseName(db, name) else 0;
    return if (index < 0) null else db.aDb.?[@intCast(index)].pBt;
}

/// Source `sqlite3DbIsNamed()`.
pub fn databaseIsNamed(db: *types.Sqlite3, index: c_int, name: [*:0]const u8) bool {
    return sqlite_string.compare(db.aDb.?[@intCast(index)].zDbSName, name) == 0 or
        (index == 0 and sqlite_string.compare("main", name) == 0);
}
