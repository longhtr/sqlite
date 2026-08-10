//! Collation hash lookup, synthesis, and factory callbacks from `callback.c`.

const std = @import("std");
const db_allocator = @import("db_allocator.zig");
const mem = @import("vdbe_mem.zig");
const vdbe_aux = @import("vdbe_aux.zig");
const types = @import("vdbe_types.zig");

fn parseDatabase(parse: *types.Parse) *types.Sqlite3 {
    return @ptrCast(@alignCast(parse.db.?));
}

fn setMissingCollationError(parse: *types.Parse, name: [*:0]const u8) void {
    const db = parseDatabase(parse);
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "no such collation sequence: {s}", .{name}) catch "no such collation sequence";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 257;
}

/// Source `callCollNeeded()`.
pub fn callCollationNeeded(db: *types.Sqlite3, encoding: u8, name: [*:0]const u8) void {
    if (db.xCollNeeded) |callback| {
        const external = db_allocator.stringDuplicate(db, name) orelse return;
        callback(db.pCollNeededArg, db, encoding, external);
        db_allocator.freeNN(db, external);
    }
    if (db.xCollNeeded16) |callback| {
        const value = mem.valueNew(db) orelse return;
        defer mem.valueFree(value);
        mem.valueSetStr(value, -1, name, 1, .static);
        if (mem.valueText(value, 2)) |external| callback(db.pCollNeededArg, db, db.enc, @ptrCast(external));
    }
}

/// Source `synthCollSeq()`.
pub fn synthesizeCollation(db: *types.Sqlite3, requested: *types.CollSeq) c_int {
    for ([_]u8{ 3, 2, 1 }) |encoding| {
        const alternative = findCollation(db, encoding, requested.zName, false).?;
        if (alternative.xCmp != null) {
            requested.* = alternative.*;
            requested.xDel = null;
            return 0;
        }
    }
    return 1;
}

/// Source `findCollSeqEntry()`.
pub fn findCollationEntry(db: *types.Sqlite3, name: [*:0]const u8, create: bool) ?[*]types.CollSeq {
    if (db.aCollSeq.find(name)) |pointer| return @ptrCast(@alignCast(pointer));
    if (!create) return null;
    const name_length = std.mem.len(name) + 1;
    const raw = db_allocator.mallocZero(db, 3 * @sizeOf(types.CollSeq) + name_length) orelse return null;
    const collations: [*]types.CollSeq = @ptrCast(@alignCast(raw));
    const name_storage: [*]u8 = @ptrFromInt(@intFromPtr(raw) + 3 * @sizeOf(types.CollSeq));
    @memcpy(name_storage[0..name_length], name[0..name_length]);
    for (0..3) |index| {
        collations[index].zName = @ptrCast(name_storage);
        collations[index].enc = @intCast(index + 1);
    }
    const replaced = db.aCollSeq.insert(db_allocator.stdAllocator(db), collations[0].zName.?, collations);
    if (replaced == collations) {
        _ = db_allocator.oomFault(db);
        db_allocator.freeNN(db, raw);
        return null;
    }
    return collations;
}

/// Source `sqlite3FindCollSeq()`.
pub fn findCollation(db: *types.Sqlite3, encoding: u8, name_optional: ?[*:0]const u8, create: bool) ?*types.CollSeq {
    const name = name_optional orelse return db.pDfltColl;
    const entries = findCollationEntry(db, name, create) orelse return null;
    return &entries[encoding - 1];
}

/// Source `sqlite3SetTextEncoding()`.
pub fn setTextEncoding(db: *types.Sqlite3, encoding: u8) void {
    db.enc = encoding;
    db.pDfltColl = findCollation(db, encoding, "BINARY", false);
    vdbe_aux.expirePreparedStatements(db, 1);
}

/// Source `sqlite3GetCollSeq()`.
pub fn getCollation(parse: *types.Parse, encoding: u8, native: ?*types.CollSeq, name: [*:0]const u8) ?*types.CollSeq {
    const db = parseDatabase(parse);
    var result = native orelse findCollation(db, encoding, name, false);
    if (result == null or result.?.xCmp == null) {
        callCollationNeeded(db, encoding, name);
        result = findCollation(db, encoding, name, false);
    }
    if (result != null and result.?.xCmp == null and synthesizeCollation(db, result.?) != 0) result = null;
    if (result == null) setMissingCollationError(parse, name);
    return result;
}

/// Source `sqlite3LocateCollSeq()`.
pub fn locateCollation(parse: *types.Parse, name: [*:0]const u8) ?*types.CollSeq {
    const db = parseDatabase(parse);
    const initialization_busy = db.init.busy != 0;
    var result = findCollation(db, db.enc, name, initialization_busy);
    if (!initialization_busy and (result == null or result.?.xCmp == null)) result = getCollation(parse, db.enc, result, name);
    return result;
}

/// Source `sqlite3CheckCollSeq()`.
pub fn checkCollation(parse: *types.Parse, collation: ?*types.CollSeq) c_int {
    const present = collation orelse return 0;
    if (present.xCmp == null and getCollation(parse, parseDatabase(parse).enc, present, present.zName.?) == null) return 1;
    return 0;
}
