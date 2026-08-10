//! Connection lifecycle and busy-handler helpers from `main.c`.

const db_allocator = @import("db_allocator.zig");
const vfs = @import("../vfs.zig");
const types = @import("vdbe_types.zig");

/// Source `sqlite3CloseSavepoints()`.
pub fn closeSavepoints(db: *types.Sqlite3) void {
    while (db.pSavepoint) |savepoint| {
        db.pSavepoint = savepoint.pNext;
        db_allocator.freeNN(db, savepoint);
    }
    db.nSavepoint = 0;
    db.nStatement = 0;
    db.isTransactionSavepoint = 0;
}

/// Source `functionDestroy()`.
pub fn destroyFunction(db: *types.Sqlite3, function: *types.FuncDef) void {
    const destructor = function.u.pDestructor orelse return;
    destructor.nRef -= 1;
    if (destructor.nRef == 0) {
        destructor.xDestroy.?(destructor.pUserData);
        db_allocator.freeNN(db, destructor);
    }
}

/// Source `sqliteDefaultBusyCallback()`.
pub fn defaultBusyCallback(context: ?*anyopaque, count: c_int) callconv(.c) c_int {
    const delays = [_]u8{ 1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100 };
    const totals = [_]u8{ 0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228 };
    const db: *types.Sqlite3 = @ptrCast(@alignCast(context.?));
    var delay: c_int = undefined;
    var prior: c_int = undefined;
    if (count < delays.len) {
        delay = delays[@intCast(count)];
        prior = totals[@intCast(count)];
    } else {
        delay = delays[delays.len - 1];
        prior = totals[totals.len - 1] + delay * (count - @as(c_int, delays.len - 1));
    }
    if (prior + delay > db.busyTimeout) {
        delay = db.busyTimeout - prior;
        if (delay <= 0) return 0;
    }
    const public_vfs: *vfs.sqlite3_vfs = @ptrCast(@alignCast(db.pVfs.?));
    _ = public_vfs.xSleep.?(public_vfs, delay * 1000);
    return 1;
}

/// Source `sqlite3InvokeBusyHandler()`.
pub fn invokeBusyHandler(handler: *types.BusyHandler) c_int {
    const callback = handler.xBusyHandler orelse return 0;
    if (handler.nBusy < 0) return 0;
    const result = callback(handler.pBusyArg, handler.nBusy);
    if (result == 0) handler.nBusy = -1 else handler.nBusy += 1;
    return result;
}

/// Source `sqlite3TempInMemory()` for the pinned `SQLITE_TEMP_STORE=1` profile.
pub fn tempInMemory(db: *const types.Sqlite3) bool {
    return db.temp_store == 2;
}
