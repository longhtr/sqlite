//! Source-shaped VDBE cursor, frame, transaction, and stepping lifecycle.
const std = @import("std");
const db_allocator = @import("db_allocator.zig");
const vdbe_aux = @import("vdbe_aux.zig");
const vdbe_mem = @import("vdbe_mem.zig");
const formatter = @import("../formatter.zig");
const global_memory = @import("../memory.zig");
const varint = @import("../varint.zig");
pub const types = @import("vdbe_types.zig");

pub const result_ok: c_int = 0;
pub const result_error: c_int = 1;
pub const result_busy: c_int = 5;
pub const result_no_memory: c_int = 7;
pub const result_interrupt: c_int = 9;
pub const result_full: c_int = 13;
pub const result_schema: c_int = 17;
pub const result_misuse: c_int = 21;
pub const result_range: c_int = 25;
pub const result_row: c_int = 100;
pub const result_done: c_int = 101;

const BtreeMutexOperations = struct {
    context: ?*anyopaque,
    tryLock: *const fn (?*anyopaque, *types.Btree) c_int,
    lock: *const fn (?*anyopaque, *types.Btree) void,
    unlock: *const fn (?*anyopaque, *types.Btree) void,
};

fn defaultBtreeTryLock(_: ?*anyopaque, _: *types.Btree) c_int {
    return result_ok;
}
fn defaultBtreeLock(_: ?*anyopaque, _: *types.Btree) void {}
fn defaultBtreeUnlock(_: ?*anyopaque, _: *types.Btree) void {}
const default_btree_mutex_operations = BtreeMutexOperations{
    .context = null,
    .tryLock = defaultBtreeTryLock,
    .lock = defaultBtreeLock,
    .unlock = defaultBtreeUnlock,
};

/// Source `btreeLockCarefully()`: try the requested BtShared lock without
/// blocking, or release and reacquire all later wanted locks in address order.
fn btreeLockCarefully(tree: *types.Btree, operations: *const BtreeMutexOperations) void {
    if (operations.tryLock(operations.context, tree) == result_ok) {
        tree.locked = 1;
        return;
    }

    var later = tree.pNext;
    while (later) |current| : (later = current.pNext) {
        std.debug.assert(current.sharable != 0);
        std.debug.assert(current.locked == 0 or current.wantToLock > 0);
        if (current.locked != 0) {
            operations.unlock(operations.context, current);
            current.locked = 0;
        }
    }
    operations.lock(operations.context, tree);
    tree.locked = 1;
    later = tree.pNext;
    while (later) |current| : (later = current.pNext) {
        if (current.wantToLock != 0) {
            operations.lock(operations.context, current);
            current.locked = 1;
        }
    }
}

/// Source `sqlite3VdbeEnter()`: lock the non-TEMP shared btrees in the VM's
/// lock mask in database order.
pub fn enterBtrees(machine: *types.Vdbe) void {
    if (machine.lockMask == 0) return;
    const db = machine.db.?;
    var index: c_int = 0;
    while (index < db.nDb) : (index += 1) {
        if (index == 1 or machine.lockMask & (@as(types.DbMask, 1) << @intCast(index)) == 0) {
            continue;
        }
        const tree = db.aDb.?[@intCast(index)].pBt orelse continue;
        tree.wantToLock += 1;
        if (tree.locked == 0) {
            btreeLockCarefully(tree, &default_btree_mutex_operations);
        }
    }
}

/// Source `vdbeLeave()`: release the shared btrees acquired by enterBtrees.
pub fn leaveBtrees(machine: *types.Vdbe) void {
    if (machine.lockMask == 0) return;
    const db = machine.db.?;
    var index: c_int = 0;
    while (index < db.nDb) : (index += 1) {
        if (index == 1 or machine.lockMask & (@as(types.DbMask, 1) << @intCast(index)) == 0) {
            continue;
        }
        const tree = db.aDb.?[@intCast(index)].pBt orelse continue;
        if (tree.wantToLock > 0) {
            tree.wantToLock -= 1;
        }
        if (tree.wantToLock == 0) {
            tree.locked = 0;
        }
    }
}

/// Source `freeCursorWithCache()`.
pub fn freeCursorWithCache(machine: *types.Vdbe, cursor: *types.VdbeCursor) void {
    const cache = cursor.pCache orelse return freeCursor(machine, cursor);
    cursor.flags.colCache = false;
    cursor.pCache = null;
    if (cache.pCValue) |text| {
        formatter.rcStrUnref(global_memory.processManager(), text);
    }
    db_allocator.freeNN(machine.db.?, @ptrCast(cache));
    freeCursor(machine, cursor);
}

/// Source `sqlite3VdbeFreeCursorNN()` for the active native cursor owners.
pub fn freeCursor(machine: *types.Vdbe, cursor: *types.VdbeCursor) void {
    if (cursor.flags.colCache) return freeCursorWithCache(machine, cursor);
    switch (cursor.eCurType) {
        types.cursor_type.btree => cursor.uc.pCursor = null,
        types.cursor_type.sorter => cursor.uc.pSorter = null,
        types.cursor_type.virtual_table => cursor.uc.pVCur = null,
        types.cursor_type.pseudo => {},
        else => unreachable,
    }
    cursor.pKeyInfo = vdbe_aux.keyInfoRef(null);
    cursor.aRow = null;
    cursor.aOffset = null;
}

/// Source `closeCursorsInFrame()`.
pub fn closeCursorsInFrame(machine: *types.Vdbe) void {
    const cursors = machine.apCsr orelse return;
    for (cursors[0..@intCast(machine.nCursor)]) |*slot| {
        if (slot.*) |cursor| {
            freeCursor(machine, cursor);
        }
        slot.* = null;
    }
}

/// Source `sqlite3VdbeFrameDelete()`.
pub fn deleteFrame(frame: *types.VdbeFrame) void {
    const machine = frame.v.?;
    const memories = types.frameMem(frame);
    const cursor_bytes: [*]u8 = @ptrCast(memories + @as(usize, @intCast(frame.nChildMem)));
    const cursors: [*]?*types.VdbeCursor = @ptrCast(@alignCast(cursor_bytes));
    for (cursors[0..@intCast(frame.nChildCsr)]) |cursor_optional| {
        if (cursor_optional) |cursor| {
            freeCursor(machine, cursor);
        }
    }
    vdbe_mem.releaseArray(memories, frame.nChildMem);
    const saved = machine.pAuxData;
    machine.pAuxData = frame.pAuxData;
    vdbe_mem.deleteAuxData(machine, -1, 0);
    machine.pAuxData = saved;
    db_allocator.freeNN(machine.db.?, @ptrCast(frame));
}

/// Source `sqlite3VdbeFrameRestore()`.
pub fn restoreFrame(frame: *types.VdbeFrame) c_int {
    const machine = frame.v.?;
    closeCursorsInFrame(machine);
    machine.aOp = frame.aOp;
    machine.nOp = frame.nOp;
    machine.aMem = frame.aMem;
    machine.nMem = frame.nMem;
    machine.apCsr = frame.apCsr;
    machine.nCursor = frame.nCursor;
    machine.db.?.lastRowid = frame.lastRowid;
    machine.nChange = frame.nChange;
    machine.db.?.nChange = frame.nDbChange;
    vdbe_mem.deleteAuxData(machine, -1, 0);
    machine.pAuxData = frame.pAuxData;
    frame.pAuxData = null;
    return frame.pc;
}

/// Source `closeAllCursors()`.
pub fn closeAllCursors(machine: *types.Vdbe) void {
    if (machine.pFrame) |current| {
        var root = current;
        while (root.pParent) |parent| {
            root = parent;
        }
        _ = restoreFrame(root);
        machine.pFrame = null;
        machine.nFrame = 0;
    }
    closeCursorsInFrame(machine);
    vdbe_mem.releaseArray(machine.aMem, machine.nMem);
    while (machine.pDelFrame) |frame| {
        machine.pDelFrame = frame.pParent;
        deleteFrame(frame);
    }
    vdbe_mem.deleteAuxData(machine, -1, 0);
}

pub const StatementOperation = enum { rollback, release };

/// Source `vdbeCloseStatement()`.
pub fn closeStatement(machine: *types.Vdbe, operation: StatementOperation) c_int {
    const db = machine.db.?;
    if (db.nStatement == 0 or machine.iStatement == 0) return result_ok;
    std.debug.assert(machine.iStatement == db.nStatement + db.nSavepoint);
    db.nStatement -= 1;
    machine.iStatement = 0;
    if (operation == .rollback) {
        db.nDeferredCons = machine.nStmtDefCons;
        db.nDeferredImmCons = machine.nStmtDefImmCons;
    }
    return result_ok;
}

pub const CommitHooks = struct {
    context: ?*anyopaque = null,
    virtual_sync: ?*const fn (?*anyopaque, *types.Vdbe) c_int = null,
    phase_one: ?*const fn (?*anyopaque, *types.Btree, bool) c_int = null,
    phase_two: ?*const fn (?*anyopaque, *types.Btree, bool) c_int = null,
    virtual_commit: ?*const fn (?*anyopaque) void = null,
};

/// Source `vdbeCommit()`: synchronize virtual tables, run the commit hook,
/// complete phase one for every writer before any phase-two completion, and
/// only then publish the virtual-table commit.
pub fn commit(db: *types.Sqlite3, machine: *types.Vdbe, hooks: CommitHooks) c_int {
    if (hooks.virtual_sync) |sync_callback| {
        const result = sync_callback(hooks.context, machine);
        if (result != result_ok) return result;
    }
    var has_writer = false;
    var writer_count: usize = 0;
    var index: c_int = 0;
    while (index < db.nDb) : (index += 1) {
        const tree = db.aDb.?[@intCast(index)].pBt orelse continue;
        if (tree.inTrans >= 2) {
            has_writer = true;
            if (index != 1) {
                writer_count += 1;
            }
            tree.locked = 1;
        }
    }
    if (has_writer) {
        if (db.xCommitCallback) |callback| {
            if (callback(db.pCommitArg) != 0) {
                return 531;
            }
        }
        index = 0;
        while (index < db.nDb) : (index += 1) {
            const tree = db.aDb.?[@intCast(index)].pBt orelse continue;
            if (tree.inTrans < 2) {
                continue;
            }
            if (hooks.phase_one) |phase_one| {
                const result = phase_one(hooks.context, tree, writer_count > 1);
                if (result != result_ok) {
                    return result;
                }
            }
        }
    }
    index = 0;
    while (index < db.nDb) : (index += 1) {
        const tree = db.aDb.?[@intCast(index)].pBt orelse continue;
        if (tree.inTrans == 0) {
            continue;
        }
        if (hooks.phase_two) |phase_two| {
            const result = phase_two(hooks.context, tree, writer_count > 1);
            if (result != result_ok) {
                return result;
            }
        }
        tree.inTrans = 0;
        tree.locked = 0;
    }
    if (hooks.virtual_commit) |virtual_commit| virtual_commit(hooks.context);
    return result_ok;
}

fn isSpecialError(code: c_int) bool {
    return switch (code & 0xff) {
        result_no_memory, 10, result_interrupt, result_full => true,
        else => false,
    };
}

/// Source `sqlite3VdbeHalt()`.
pub fn halt(machine: *types.Vdbe, hooks: CommitHooks) c_int {
    const db = machine.db.?;
    if (machine.eVdbeState == types.vdbe_state.halt) return result_ok;
    if (machine.eVdbeState != types.vdbe_state.run) return result_misuse;
    if (db.mallocFailed != 0) machine.rc = result_no_memory;
    closeAllCursors(machine);
    if (machine.flags.bIsReader) {
        enterBtrees(machine);
        const special = isSpecialError(machine.rc);
        var statement_operation: ?StatementOperation = null;
        if (special and (!machine.flags.readOnly or (machine.rc & 0xff) != result_interrupt)) {
            if (((machine.rc & 0xff) == result_no_memory or (machine.rc & 0xff) == result_full) and machine.flags.usesStmtJournal) {
                statement_operation = .rollback;
            } else {
                db.autoCommit = 1;
                machine.nChange = 0;
            }
        }
        if (db.autoCommit != 0 and db.nVdbeWrite == @intFromBool(!machine.flags.readOnly)) {
            if (machine.rc == result_ok and db.nDeferredCons + db.nDeferredImmCons == 0) {
                const commit_result = commit(db, machine, hooks);
                if (commit_result == result_busy and machine.flags.readOnly) {
                    leaveBtrees(machine);
                    return result_busy;
                }
                if (commit_result != result_ok) {
                    machine.rc = commit_result;
                    machine.nChange = 0;
                } else {
                    db.nDeferredCons = 0;
                    db.nDeferredImmCons = 0;
                }
            } else {
                machine.nChange = 0;
            }
            db.nStatement = 0;
        } else if (statement_operation == null) {
            statement_operation = if (machine.rc == result_ok) .release else .rollback;
        }
        if (statement_operation) |operation| {
            const close_result = closeStatement(machine, operation);
            if (close_result != result_ok) machine.rc = close_result;
        }
        if (machine.flags.changeCntOn) {
            vdbe_aux.setChanges(db, if (statement_operation == .rollback) 0 else machine.nChange);
            machine.nChange = 0;
        }
        leaveBtrees(machine);
    }
    db.nVdbeActive = @max(0, db.nVdbeActive - 1);
    if (!machine.flags.readOnly) db.nVdbeWrite = @max(0, db.nVdbeWrite - 1);
    if (machine.flags.bIsReader) db.nVdbeRead = @max(0, db.nVdbeRead - 1);
    machine.eVdbeState = types.vdbe_state.halt;
    if (db.mallocFailed != 0) machine.rc = result_no_memory;
    return if (machine.rc == result_busy) result_busy else result_ok;
}

/// Source `sqlite3VdbeReset()`.
pub fn reset(machine: *types.Vdbe) c_int {
    const db = machine.db.?;
    if (machine.eVdbeState == types.vdbe_state.run) _ = halt(machine, .{});
    if (machine.pc >= 0) {
        if (db.pErr != null or machine.zErrMsg != null) {
            _ = vdbe_aux.transferError(machine);
        } else db.errCode = machine.rc;
    }
    if (machine.zErrMsg) |message| db_allocator.freeNN(db, @ptrCast(message));
    machine.zErrMsg = null;
    machine.pResultRow = null;
    return machine.rc & db.errMask;
}

/// Source `sqlite3VdbeFinalize()`.
pub fn finalize(machine: *types.Vdbe) c_int {
    const result = if (machine.eVdbeState >= types.vdbe_state.ready) reset(machine) else result_ok;
    vdbe_aux.deleteVdbe(machine);
    return result;
}

/// Source `sqlite3NotPureFunc()`.
pub fn notPureFunction(context: *types.Context) bool {
    const machine = context.pVdbe orelse return true;
    const operations = machine.aOp orelse return true;
    const operation = operations[@intCast(context.iOp)];
    if (operation.opcode != .PureFunc) return true;
    const location = if (operation.p5 & 0x2000 != 0)
        "a CHECK constraint"
    else if (operation.p5 & 0x1000 != 0)
        "a generated column"
    else
        "an index";
    var buffer: [256]u8 = undefined;
    const name = if (context.pFunc.?.zName) |value| std.mem.span(value) else "function";
    const message = std.fmt.bufPrint(&buffer, "non-deterministic use of {s}() in {s}", .{ name, location }) catch "non-deterministic function";
    vdbe_mem.resultError(context, message.ptr, @intCast(message.len));
    return false;
}

pub const Execute = *const fn (?*anyopaque, *types.Vdbe) c_int;

/// Source `sqlite3Step()` inner VM lifecycle.
pub fn stepMachine(machine: *types.Vdbe, execute: Execute, context: ?*anyopaque) c_int {
    const db = machine.db.?;
    if (machine.eVdbeState != types.vdbe_state.run) {
        if (machine.eVdbeState == types.vdbe_state.ready) {
            if (machine.flags.expired != 0) {
                machine.rc = result_schema;
                return vdbe_aux.transferError(machine) & db.errMask;
            }
            if (db.nVdbeActive == 0) {
                @atomicStore(c_int, &db.u1.isInterrupted, 0, .monotonic);
            }
            db.nVdbeActive += 1;
            if (!machine.flags.readOnly) {
                db.nVdbeWrite += 1;
            }
            if (machine.flags.bIsReader) {
                db.nVdbeRead += 1;
            }
            machine.pc = 0;
            machine.eVdbeState = types.vdbe_state.run;
        } else if (machine.eVdbeState == types.vdbe_state.halt) {
            _ = reset(machine);
            machine.eVdbeState = types.vdbe_state.ready;
            return stepMachine(machine, execute, context);
        }
    }
    db.nVdbeExec += 1;
    const result = execute(context, machine);
    db.nVdbeExec -= 1;
    if (result == result_row) {
        db.errCode = result_row;
        return result_row;
    }
    machine.pResultRow = null;
    if (result != result_done and machine.prepFlags & types.prepare_save_sql != 0) {
        _ = vdbe_aux.transferError(machine);
    }
    db.errCode = result;
    return result & db.errMask;
}

pub const ValueListIterator = struct {
    records: []const []const u8,
    index: usize = 0,
    output: *types.Mem,
};

fn decodeRecordVarint(bytes: []const u8) ?varint.Decoded32 {
    if (bytes.len == 0) return null;
    if (bytes[0] < 0x80 or bytes.len >= 9) return varint.get32(bytes.ptr);
    var padded = [_]u8{0} ** 9;
    @memcpy(padded[0..bytes.len], bytes);
    return varint.get32(&padded);
}

/// Source `valueFromValueList()` over source-format single-column records.
pub fn valueFromList(iterator: *ValueListIterator, next: bool) c_int {
    if (!next) {
        iterator.index = 0;
    } else {
        iterator.index += 1;
    }
    if (iterator.index >= iterator.records.len) return result_done;
    const record = iterator.records[iterator.index];
    if (record.len < 2) return 11;
    const header = decodeRecordVarint(record[1..]) orelse return 11;
    const serial_offset = 1 + header.length;
    if (serial_offset >= record.len) return 11;
    const serial = decodeRecordVarint(record[serial_offset..]) orelse return 11;
    const data_offset = @as(usize, header.value);
    if (data_offset >= record.len) return 11;
    vdbe_mem.serialGet(record[data_offset..].ptr, serial.value, iterator.output);
    iterator.output.enc = if (iterator.output.db) |db| db.enc else 1;
    if (iterator.output.flags & types.mem_flag.ephemeral != 0 and vdbe_mem.makeWriteable(iterator.output) != 0) return result_no_memory;
    return result_ok;
}

/// Source `allocateCursor()`.
pub fn allocateCursor(machine: *types.Vdbe, cursor_index: c_int, field_count: c_int, cursor_type: u8) ?*types.VdbeCursor {
    if (cursor_index < 0 or cursor_index >= machine.nCursor or field_count < 0) return null;
    const memory_index: usize = if (cursor_index > 0) @intCast(machine.nMem - cursor_index) else 0;
    const memory = &machine.aMem.?[memory_index];
    if (machine.apCsr.?[@intCast(cursor_index)]) |prior| freeCursor(machine, prior);
    machine.apCsr.?[@intCast(cursor_index)] = null;
    const bytes = types.cursorSize(@intCast(field_count));
    if (vdbe_mem.grow(memory, @intCast(bytes), false) != result_ok) return null;
    const cursor: *types.VdbeCursor = @ptrCast(@alignCast(memory.zMalloc.?));
    @memset(@as([*]u8, @ptrCast(cursor))[0..@offsetOf(types.VdbeCursor, "pAltCursor")], 0);
    cursor.eCurType = cursor_type;
    cursor.nField = @intCast(field_count);
    const type_base: [*]u32 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(cursor)) + @offsetOf(types.VdbeCursor, "aType")));
    cursor.aOffset = type_base + @as(usize, @intCast(field_count));
    machine.apCsr.?[@intCast(cursor_index)] = cursor;
    return cursor;
}

/// Source `vdbeColumnFromOverflow()` for a payload already obtained from the
/// btree owner, including the large-value per-cursor cache.
pub fn columnFromOverflow(cursor: *types.VdbeCursor, column: c_int, serial_type: u32, payload_offset: usize, cache_status: u32, cache_counter: u32, payload: []const u8, destination: *types.Mem) c_int {
    const length: usize = vdbe_mem.serialTypeLen(serial_type);
    if (payload_offset > payload.len or length > payload.len - payload_offset) return 11;
    if (destination.db) |db| {
        if (length > @as(usize, @intCast(db.aLimit[0]))) return 18;
    }
    const source = payload[payload_offset .. payload_offset + length];
    if (length > 4000 and cursor.pKeyInfo == null) {
        if (!cursor.flags.colCache) {
            const raw = db_allocator.mallocZero(destination.db.?, @sizeOf(types.VdbeTxtBlbCache)) orelse return result_no_memory;
            cursor.pCache = @ptrCast(@alignCast(raw));
            cursor.flags.colCache = true;
        }
        const cache = cursor.pCache.?;
        if (cache.pCValue == null or cache.iCol != column or cache.cacheStatus != cache_status or cache.colCacheCtr != cache_counter or cache.iOffset != @as(i64, @intCast(payload_offset))) {
            if (cache.pCValue) |old| {
                formatter.rcStrUnref(global_memory.processManager(), old);
            }
            const cached = formatter.rcStrNew(global_memory.processManager(), length + 3) orelse return result_no_memory;
            @memcpy(cached[0..length], source);
            @memset(cached[length .. length + 3], 0);
            cache.pCValue = cached;
            cache.iCol = column;
            cache.cacheStatus = cache_status;
            cache.colCacheCtr = cache_counter;
            cache.iOffset = @intCast(payload_offset);
        }
        vdbe_mem.serialGet(cache.pCValue.?, serial_type, destination);
    } else {
        vdbe_mem.serialGet(source.ptr, serial_type, destination);
    }
    destination.flags &= ~types.mem_flag.ephemeral;
    return result_ok;
}

/// Source `sqlite3VdbeLogAbort()`: render the stable abort diagnostic used by
/// the process logger.
pub fn logAbort(allocator: std.mem.Allocator, machine: *const types.Vdbe, result: c_int, operation_index: usize) ![]u8 {
    const sql = if (machine.zSql) |text| std.mem.span(text) else "";
    const message = if (machine.zErrMsg) |text| std.mem.span(text) else "error";
    const prefix = if (machine.pFrame != null) "/* trigger */ " else "";
    return std.fmt.allocPrint(allocator, "statement aborts at {d}: {s}; [{s}{s}] ({d})", .{ operation_index, message, prefix, sql, result });
}

test "source careful Btree lock preserves ascending reacquisition" {
    const Harness = struct {
        events: [8]u8 = [_]u8{0} ** 8,
        count: usize = 0,
        try_result: c_int = result_ok,

        fn record(context: ?*anyopaque, prefix: u8, tree: *types.Btree) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.events[self.count] = prefix + tree.inTrans;
            self.count += 1;
        }
        fn tryLock(context: ?*anyopaque, tree: *types.Btree) c_int {
            record(context, 0x10, tree);
            return @as(*@This(), @ptrCast(@alignCast(context.?))).try_result;
        }
        fn lock(context: ?*anyopaque, tree: *types.Btree) void {
            record(context, 0x20, tree);
        }
        fn unlock(context: ?*anyopaque, tree: *types.Btree) void {
            record(context, 0x30, tree);
        }
    };
    var harness = Harness{};
    const operations = BtreeMutexOperations{
        .context = &harness,
        .tryLock = Harness.tryLock,
        .lock = Harness.lock,
        .unlock = Harness.unlock,
    };
    var first = std.mem.zeroes(types.Btree);
    first.inTrans = 1;
    first.sharable = 1;
    btreeLockCarefully(&first, &operations);
    try std.testing.expectEqual(@as(u8, 1), first.locked);
    try std.testing.expectEqualSlices(u8, &.{0x11}, harness.events[0..harness.count]);

    harness.count = 0;
    harness.try_result = result_busy;
    first.locked = 0;
    var second = std.mem.zeroes(types.Btree);
    second.inTrans = 2;
    second.sharable = 1;
    second.locked = 1;
    second.wantToLock = 1;
    var third = std.mem.zeroes(types.Btree);
    third.inTrans = 3;
    third.sharable = 1;
    third.wantToLock = 1;
    first.pNext = &second;
    second.pNext = &third;
    btreeLockCarefully(&first, &operations);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x32, 0x21, 0x22, 0x23 }, harness.events[0..harness.count]);
    try std.testing.expectEqual(@as(u8, 1), first.locked);
    try std.testing.expectEqual(@as(u8, 1), second.locked);
    try std.testing.expectEqual(@as(u8, 1), third.locked);
}

fn testExecuteDone(_: ?*anyopaque, _: *types.Vdbe) c_int {
    return result_done;
}

test "checkpoint batch VDBE inner step lifecycle" {
    var db = std.mem.zeroes(types.Sqlite3);
    db.errMask = std.math.maxInt(c_int);
    var machine = std.mem.zeroes(types.Vdbe);
    machine.db = &db;
    machine.eVdbeState = types.vdbe_state.ready;
    try std.testing.expectEqual(result_done, stepMachine(&machine, testExecuteDone, null));
    try std.testing.expectEqual(types.vdbe_state.run, machine.eVdbeState);
    try std.testing.expectEqual(@as(c_int, 1), db.nVdbeActive);
    try std.testing.expectEqual(result_ok, halt(&machine, .{}));
    try std.testing.expectEqual(types.vdbe_state.halt, machine.eVdbeState);
    try std.testing.expectEqual(@as(c_int, 0), db.nVdbeActive);
}
