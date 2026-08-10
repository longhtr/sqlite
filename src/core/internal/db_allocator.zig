//! Connection-aware allocation paths from `malloc.c`.
//!
//! These operate directly on the active-profile `sqlite3` and `Lookaside`
//! layouts and share the same process allocator as the public allocation API.

const std = @import("std");
const memory = @import("../memory.zig");
pub const types = @import("vdbe_types.zig");

pub fn isLookaside(db: *const types.Sqlite3, pointer: *const anyopaque) bool {
    const start = db.lookaside.pStart orelse return false;
    const end = db.lookaside.pTrueEnd orelse return false;
    const address = @intFromPtr(pointer);
    return address >= @intFromPtr(start) and address < @intFromPtr(end);
}

fn lookasideAllocationSize(db: *const types.Sqlite3, pointer: *const anyopaque) usize {
    const middle = db.lookaside.pMiddle orelse return db.lookaside.szTrue;
    return if (@intFromPtr(pointer) < @intFromPtr(middle)) db.lookaside.szTrue else types.lookaside_small;
}

/// Source `sqlite3DbMallocSize()`.
pub fn allocationSize(db: ?*types.Sqlite3, pointer: *anyopaque) usize {
    if (db) |connection| {
        const address = @intFromPtr(pointer);
        if (connection.lookaside.pTrueEnd) |end| {
            if (address < @intFromPtr(end)) {
                if (connection.lookaside.pMiddle) |middle| {
                    if (address >= @intFromPtr(middle)) return types.lookaside_small;
                }
                if (connection.lookaside.pStart) |start| {
                    if (address >= @intFromPtr(start)) return connection.lookaside.szTrue;
                }
            }
        }
    }
    return memory.processManager().size(pointer);
}

fn atomicStoreInterrupt(db: *types.Sqlite3, value: c_int) void {
    @atomicStore(c_int, &db.u1.isInterrupted, value, .monotonic);
}

/// Source `sqlite3OomFault()`.
pub fn oomFault(db: *types.Sqlite3) ?*anyopaque {
    if (db.mallocFailed == 0 and db.bBenignMalloc == 0) {
        db.mallocFailed = 1;
        if (db.nVdbeExec > 0) atomicStoreInterrupt(db, 1);
        types.disableLookaside(&db.lookaside);
        if (db.pParse) |parse| {
            // sqlite3ErrorMsg(db->pParse, "out of memory") cannot allocate after
            // mallocFailed is set. Preserve its exact active-profile net state.
            db.errByteOffset = -1;
            parse.nErr += 1;
            if (db.suppressErr == 0) {
                free(db, if (parse.zErrMsg) |message| @ptrCast(message) else null);
                parse.zErrMsg = null;
                parse.pWith = null;
            }
            parse.rc = types.result_no_memory;
            var outer = parse.pOuterParse;
            while (outer) |owner| : (outer = owner.pOuterParse) {
                owner.nErr += 1;
                owner.rc = types.result_no_memory;
            }
        }
    }
    return null;
}

pub fn oomClear(db: *types.Sqlite3) void {
    if (db.mallocFailed != 0 and db.nVdbeExec == 0) {
        db.mallocFailed = 0;
        atomicStoreInterrupt(db, 0);
        std.debug.assert(db.lookaside.bDisable > 0);
        types.enableLookaside(&db.lookaside);
    }
}

fn mallocRawFinish(db: *types.Sqlite3, amount: u64) ?*anyopaque {
    const pointer = memory.processManager().alloc(amount);
    if (pointer == null) _ = oomFault(db);
    return pointer;
}

pub fn mallocRaw(db: ?*types.Sqlite3, amount: u64) ?*anyopaque {
    if (db) |connection| return mallocRawNN(connection, amount);
    return memory.processManager().alloc(amount);
}

fn pop(head: *?*types.LookasideSlot) ?*types.LookasideSlot {
    const slot = head.* orelse return null;
    head.* = slot.pNext;
    return slot;
}

/// Source `sqlite3DbMallocRawNN()` with two-size lookaside selection.
pub fn mallocRawNN(db: *types.Sqlite3, amount: u64) ?*anyopaque {
    std.debug.assert(db.pnBytesFreed == null);
    if (amount > db.lookaside.sz) {
        if (db.lookaside.bDisable == 0) {
            db.lookaside.anStat[1] += 1;
        } else if (db.mallocFailed != 0) {
            return null;
        }
        return mallocRawFinish(db, amount);
    }
    if (amount <= types.lookaside_small) {
        if (pop(&db.lookaside.pSmallFree) orelse pop(&db.lookaside.pSmallInit)) |slot| {
            db.lookaside.anStat[0] += 1;
            return slot;
        }
    }
    if (pop(&db.lookaside.pFree) orelse pop(&db.lookaside.pInit)) |slot| {
        db.lookaside.anStat[0] += 1;
        return slot;
    }
    db.lookaside.anStat[2] += 1;
    return mallocRawFinish(db, amount);
}

pub fn mallocZero(db: ?*types.Sqlite3, amount: u64) ?*anyopaque {
    const pointer = mallocRaw(db, amount) orelse return null;
    @memset(@as([*]u8, @ptrCast(pointer))[0..@intCast(amount)], 0);
    return pointer;
}

fn measureAllocationSize(db: *types.Sqlite3, pointer: *anyopaque) void {
    db.pnBytesFreed.?.* += @intCast(allocationSize(db, pointer));
}

/// Source `sqlite3DbFreeNN()`.
pub fn freeNN(db: ?*types.Sqlite3, pointer: *anyopaque) void {
    if (db) |connection| {
        const address = @intFromPtr(pointer);
        if (connection.lookaside.pEnd) |end| {
            if (address < @intFromPtr(end)) {
                if (connection.lookaside.pMiddle) |middle| {
                    if (address >= @intFromPtr(middle)) {
                        const slot: *types.LookasideSlot = @ptrCast(@alignCast(pointer));
                        slot.pNext = connection.lookaside.pSmallFree;
                        connection.lookaside.pSmallFree = slot;
                        return;
                    }
                }
                if (connection.lookaside.pStart) |start| {
                    if (address >= @intFromPtr(start)) {
                        const slot: *types.LookasideSlot = @ptrCast(@alignCast(pointer));
                        slot.pNext = connection.lookaside.pFree;
                        connection.lookaside.pFree = slot;
                        return;
                    }
                }
            }
        }
        if (connection.pnBytesFreed != null) {
            measureAllocationSize(connection, pointer);
            return;
        }
    }
    memory.processManager().free(pointer);
}

/// Source `sqlite3DbNNFreeNN()`; the non-null connection specialization.
pub fn freeConnectionNN(db: *types.Sqlite3, pointer: *anyopaque) void {
    freeNN(db, pointer);
}

pub fn free(db: ?*types.Sqlite3, pointer: ?*anyopaque) void {
    if (pointer) |value| freeNN(db, value);
}

/// Source `dbReallocFinish()`.
fn reallocFinish(db: *types.Sqlite3, old: *anyopaque, amount: u64) ?*anyopaque {
    if (db.mallocFailed != 0) return null;
    if (isLookaside(db, old)) {
        const replacement = mallocRawNN(db, amount) orelse return null;
        const old_size = lookasideAllocationSize(db, old);
        @memcpy(
            @as([*]u8, @ptrCast(replacement))[0..old_size],
            @as([*]const u8, @ptrCast(old))[0..old_size],
        );
        freeNN(db, old);
        return replacement;
    }
    const replacement = memory.processManager().realloc(old, amount);
    if (replacement == null) _ = oomFault(db);
    return replacement;
}

/// Source `sqlite3DbRealloc()`.
pub fn realloc(db: *types.Sqlite3, pointer: ?*anyopaque, amount: u64) ?*anyopaque {
    const old = pointer orelse return mallocRawNN(db, amount);
    const address = @intFromPtr(old);
    if (db.lookaside.pEnd) |end| {
        if (address < @intFromPtr(end)) {
            if (db.lookaside.pMiddle) |middle| {
                if (address >= @intFromPtr(middle)) {
                    if (amount <= types.lookaside_small) return old;
                    return reallocFinish(db, old, amount);
                }
            }
            if (db.lookaside.pStart) |start| {
                if (address >= @intFromPtr(start) and amount <= db.lookaside.szTrue) return old;
            }
        }
    }
    return reallocFinish(db, old, amount);
}

pub fn reallocOrFree(db: *types.Sqlite3, pointer: ?*anyopaque, amount: u64) ?*anyopaque {
    const replacement = realloc(db, pointer, amount);
    if (replacement == null) free(db, pointer);
    return replacement;
}

pub fn stdAllocator(db: *types.Sqlite3) std.mem.Allocator {
    return .{ .ptr = db, .vtable = &connection_allocator_vtable };
}

const connection_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = connectionAllocate,
    .resize = connectionResize,
    .remap = connectionRemap,
    .free = connectionFree,
};

fn connectionAllocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 8) return null;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(context));
    return @ptrCast(mallocRawNN(db, length));
}

fn connectionResize(context: *anyopaque, buffer: []u8, _: std.mem.Alignment, new_length: usize, _: usize) bool {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(context));
    return new_length <= allocationSize(db, buffer.ptr);
}

fn connectionRemap(context: *anyopaque, buffer: []u8, _: std.mem.Alignment, new_length: usize, _: usize) ?[*]u8 {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(context));
    return @ptrCast(realloc(db, buffer.ptr, new_length));
}

fn connectionFree(context: *anyopaque, buffer: []u8, _: std.mem.Alignment, _: usize) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(context));
    freeNN(db, buffer.ptr);
}

/// Source `sqlite3DbStrDup()`.
pub fn stringDuplicate(db: ?*types.Sqlite3, input: ?[*:0]const u8) ?[*:0]u8 {
    const source = input orelse return null;
    const length = std.mem.len(source) + 1;
    const raw = mallocRaw(db, length) orelse return null;
    const output: [*]u8 = @ptrCast(raw);
    @memcpy(output[0..length], source[0..length]);
    return @ptrCast(output);
}

/// Source `sqlite3ArrayAllocate()`.
pub fn arrayAllocate(db: *types.Sqlite3, array_initial: ?*anyopaque, entry_size: c_int, entry_count: *c_int, new_index: *c_int) ?*anyopaque {
    const count: i64 = entry_count.*;
    new_index.* = entry_count.*;
    var array = array_initial;
    if (count & (count - 1) == 0) {
        const capacity: i64 = if (count == 0) 1 else 2 * count;
        array = realloc(db, array, @intCast(capacity * entry_size)) orelse {
            new_index.* = -1;
            return array_initial;
        };
    }
    const bytes: [*]u8 = @ptrCast(array.?);
    @memset(bytes[@intCast(count * entry_size)..@intCast((count + 1) * entry_size)], 0);
    entry_count.* += 1;
    return array;
}

/// Source `sqlite3DbSpanDup()`.
pub fn spanDuplicate(db: *types.Sqlite3, start_initial: [*]const u8, end: [*]const u8) ?[*:0]u8 {
    var start = start_initial;
    while (std.ascii.isWhitespace(start[0])) start += 1;
    var length: usize = @intCast(@intFromPtr(end) - @intFromPtr(start));
    while (std.ascii.isWhitespace(start[length - 1])) length -= 1;
    return stringNDuplicate(db, start, length);
}

/// Source `sqlite3DbStrNDup()`.
pub fn stringNDuplicate(db: *types.Sqlite3, input: ?[*]const u8, length: usize) ?[*:0]u8 {
    std.debug.assert(length & 0x7fff_ffff == length);
    const source = input orelse return null;
    const raw = mallocRawNN(db, length + 1) orelse return null;
    const output: [*]u8 = @ptrCast(raw);
    @memcpy(output[0..length], source[0..length]);
    output[length] = 0;
    return @ptrCast(output);
}

fn testConnection(storage: []align(8) u8, big_size: u16, middle: usize) types.Sqlite3 {
    var db = std.mem.zeroes(types.Sqlite3);
    db.mallocFailed = 0;
    db.bBenignMalloc = 0;
    db.nVdbeExec = 0;
    db.pParse = null;
    db.pnBytesFreed = null;
    db.u1.isInterrupted = 0;
    db.lookaside = .{
        .bDisable = 0,
        .sz = big_size,
        .szTrue = big_size,
        .bMalloced = 0,
        .nSlot = 0,
        .anStat = .{ 0, 0, 0 },
        .pInit = null,
        .pFree = null,
        .pSmallInit = null,
        .pSmallFree = null,
        .pMiddle = storage.ptr + middle,
        .pStart = storage.ptr,
        .pEnd = storage.ptr + storage.len,
        .pTrueEnd = storage.ptr + storage.len,
    };
    return db;
}

test "connection allocation uses and returns both lookaside sizes" {
    var storage: [640]u8 align(8) = undefined;
    var db = testConnection(&storage, 512, 512);
    const big: *types.LookasideSlot = @ptrCast(@alignCast(&storage));
    const small: *types.LookasideSlot = @ptrCast(@alignCast(&storage[512]));
    big.pNext = null;
    small.pNext = null;
    db.lookaside.pInit = big;
    db.lookaside.pSmallInit = small;

    const small_value = mallocRawNN(&db, 32).?;
    const big_value = mallocRawNN(&db, 400).?;
    try std.testing.expectEqual(@as(usize, 128), allocationSize(&db, small_value));
    try std.testing.expectEqual(@as(usize, 512), allocationSize(&db, big_value));
    try std.testing.expectEqual(@as(u32, 2), db.lookaside.anStat[0]);
    freeNN(&db, small_value);
    freeNN(&db, big_value);
    try std.testing.expect(db.lookaside.pSmallFree == small);
    try std.testing.expect(db.lookaside.pFree == big);
}

test "OOM state propagates through active and outer Parse owners" {
    var storage: [128]u8 align(8) = undefined;
    var db = testConnection(&storage, 64, 0);
    var outer = std.mem.zeroes(types.Parse);
    var parse = std.mem.zeroes(types.Parse);
    parse.pOuterParse = &outer;
    parse.rc = types.result_ok;
    outer.rc = types.result_ok;
    db.pParse = &parse;
    db.errByteOffset = -2;
    db.nVdbeExec = 1;

    _ = oomFault(&db);
    try std.testing.expectEqual(@as(u8, 1), db.mallocFailed);
    try std.testing.expectEqual(@as(c_int, 1), @atomicLoad(c_int, &db.u1.isInterrupted, .monotonic));
    try std.testing.expectEqual(@as(c_int, -1), db.errByteOffset);
    try std.testing.expectEqual(@as(c_int, 1), parse.nErr);
    try std.testing.expectEqual(types.result_no_memory, parse.rc);
    try std.testing.expectEqual(@as(c_int, 1), outer.nErr);
    try std.testing.expectEqual(types.result_no_memory, outer.rc);
    oomClear(&db);
    try std.testing.expectEqual(@as(u8, 1), db.mallocFailed);
    db.nVdbeExec = 0;
    oomClear(&db);
    try std.testing.expectEqual(@as(u8, 0), db.mallocFailed);
    try std.testing.expectEqual(@as(c_int, 0), @atomicLoad(c_int, &db.u1.isInterrupted, .monotonic));
}

test "heap fallback, duplication, measurement, and OOM state" {
    const allocator_was_started = memory.process_manager.started;
    if (!allocator_was_started) try std.testing.expectEqual(memory.ok, memory.process_manager.start());
    defer if (!allocator_was_started) memory.process_manager.stop();

    var storage: [128]u8 align(8) = undefined;
    var db = testConnection(&storage, 64, 0);
    db.lookaside.pStart = null;
    db.lookaside.pMiddle = null;
    db.lookaside.pEnd = null;
    db.lookaside.pTrueEnd = null;
    db.lookaside.sz = 0;
    db.lookaside.szTrue = 0;
    db.lookaside.bDisable = 1;

    const duplicate = stringDuplicate(&db, "sqlite").?;
    try std.testing.expectEqualStrings("sqlite", std.mem.span(duplicate));
    var measured: c_int = 0;
    db.pnBytesFreed = &measured;
    freeNN(&db, duplicate);
    try std.testing.expect(measured >= 7);
    db.pnBytesFreed = null;
    memory.process_manager.free(duplicate);

    db.lookaside.szTrue = 1200;
    _ = oomFault(&db);
    try std.testing.expectEqual(@as(u8, 1), db.mallocFailed);
    try std.testing.expectEqual(@as(u32, 2), db.lookaside.bDisable);
    try std.testing.expectEqual(@as(u16, 0), db.lookaside.sz);
    oomClear(&db);
    try std.testing.expectEqual(@as(u8, 0), db.mallocFailed);
    try std.testing.expectEqual(@as(u32, 1), db.lookaside.bDisable);
}
