//! Parse-time error publication from SQLite `util.c`.

const std = @import("std");
const memory = @import("../memory.zig");
const db_allocator = @import("db_allocator.zig");
const types = @import("vdbe_types.zig");

/// Source `sqlite3ErrorMsg()`, after its varargs formatter has produced the
/// message bytes. Formatting remains with typed callers; this owner preserves
/// Parse replacement, suppression, OOM, byte-offset, result, and WITH state.
pub fn report(parse: *types.Parse, message: []const u8) void {
    const db = parse.db orelse unreachable;
    const active = db.pParse orelse unreachable;
    std.debug.assert(active == parse or active.pToplevel == parse);

    db.errByteOffset = -2;
    const rendered = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    if (db.errByteOffset < -1) db.errByteOffset = -1;
    if (db.suppressErr != 0) {
        db_allocator.free(db, if (rendered) |value| @ptrCast(value) else null);
        if (db.mallocFailed != 0) {
            parse.nErr += 1;
            parse.rc = types.result_no_memory;
        }
        return;
    }

    parse.nErr += 1;
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = rendered;
    parse.rc = types.result_error;
    parse.pWith = null;
}

test "parse errors replace messages, normalize offsets, and honor suppression" {
    const allocator_was_started = memory.process_manager.started;
    if (!allocator_was_started) try std.testing.expectEqual(memory.ok, memory.process_manager.start());
    defer if (!allocator_was_started) memory.process_manager.stop();

    var db = std.mem.zeroes(types.Sqlite3);
    var parse = std.mem.zeroes(types.Parse);
    parse.db = &db;
    db.pParse = &parse;
    report(&parse, "first error");
    try std.testing.expectEqual(types.result_error, parse.rc);
    try std.testing.expectEqual(@as(c_int, 1), parse.nErr);
    try std.testing.expectEqual(@as(c_int, -1), db.errByteOffset);
    try std.testing.expectEqualStrings("first error", std.mem.span(parse.zErrMsg.?));

    report(&parse, "replacement");
    try std.testing.expectEqual(@as(c_int, 2), parse.nErr);
    try std.testing.expectEqualStrings("replacement", std.mem.span(parse.zErrMsg.?));
    db.suppressErr = 1;
    report(&parse, "hidden");
    try std.testing.expectEqual(@as(c_int, 2), parse.nErr);
    try std.testing.expectEqualStrings("replacement", std.mem.span(parse.zErrMsg.?));
    db_allocator.free(&db, @ptrCast(parse.zErrMsg.?));
    parse.zErrMsg = null;
}
