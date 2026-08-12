//! Connection error-state publication from `util.c`.

const std = @import("std");
const vfs = @import("../vfs.zig");
const vdbe_mem = @import("vdbe_mem.zig");
pub const types = @import("vdbe_types.zig");

const result_ok: c_int = 0;
const result_io_error: c_int = 10;
const result_cannot_open: c_int = 14;
const result_io_error_no_memory: c_int = result_io_error | (12 << 8);

fn updateSystemError(db: *types.Sqlite3, result: c_int) void {
    if (result == result_io_error_no_memory) return;
    const primary = result & 0xff;
    if (primary != result_cannot_open and primary != result_io_error) return;
    const filesystem: *vfs.sqlite3_vfs = @ptrCast(@alignCast(db.pVfs orelse return));
    const callback = filesystem.xGetLastError orelse return;
    var unused: [1]u8 = .{0};
    db.iSysErrno = callback(filesystem, 0, &unused);
}

/// Source `sqlite3ErrorFinish()`.
pub fn finishDatabaseError(db: *types.Sqlite3, result: c_int) void {
    if (db.pErr) |value| vdbe_mem.setNull(value);
    updateSystemError(db, result);
}

/// Source `sqlite3Error()`.
pub fn setDatabaseError(db: *types.Sqlite3, result: c_int) void {
    db.errCode = result;
    if (result != result_ok or db.pErr != null) {
        finishDatabaseError(db, result);
    } else {
        db.errByteOffset = -1;
    }
}

/// Source `sqlite3ErrorClear()`.
pub fn clearDatabaseError(db: *types.Sqlite3) void {
    db.errCode = result_ok;
    db.errByteOffset = -1;
    if (db.pErr) |value| vdbe_mem.setNull(value);
}

test "database error publication clears messages offsets and captures VFS errno" {
    const Harness = struct {
        fn lastError(_: *vfs.sqlite3_vfs, count: c_int, _: [*]u8) callconv(.c) c_int {
            std.debug.assert(count == 0);
            return 37;
        }
    };
    var filesystem = std.mem.zeroes(vfs.sqlite3_vfs);
    filesystem.xGetLastError = Harness.lastError;
    var db = std.mem.zeroes(types.Sqlite3);
    db.pVfs = @ptrCast(&filesystem);
    db.errByteOffset = 9;
    var error_value = std.mem.zeroes(types.Mem);
    error_value.flags = types.mem_flag.integer;
    error_value.u.i = 42;
    db.pErr = &error_value;

    setDatabaseError(&db, result_cannot_open);
    try std.testing.expectEqual(result_cannot_open, db.errCode);
    try std.testing.expectEqual(@as(c_int, 37), db.iSysErrno);
    try std.testing.expectEqual(types.mem_flag.null_, error_value.flags);
    clearDatabaseError(&db);
    try std.testing.expectEqual(result_ok, db.errCode);
    try std.testing.expectEqual(@as(c_int, -1), db.errByteOffset);

    db.iSysErrno = 11;
    setDatabaseError(&db, result_io_error_no_memory);
    try std.testing.expectEqual(@as(c_int, 11), db.iSysErrno);
    db.pErr = null;
    db.errByteOffset = 5;
    setDatabaseError(&db, result_ok);
    try std.testing.expectEqual(@as(c_int, -1), db.errByteOffset);
}
