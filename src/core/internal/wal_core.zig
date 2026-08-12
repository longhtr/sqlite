//! Source-shaped WAL index mapping, hashing, locking, iteration, and savepoint undo.
const std = @import("std");
const mutex = @import("../mutex.zig");

pub const Error = error{ NoMemory, Range, Busy, Corrupt, Io, ReadOnly, Retry, Protocol };
pub const hash_table_page_count: usize = 4096;
pub const hash_table_slot_count: usize = 8192;
pub const first_hash_page_count: usize = 4062;

pub const Header = struct {
    initialized: bool = false,
    version: u32 = 0,
    max_frame: u32 = 0,
    database_pages: u32 = 0,
    page_size: u32 = 0,
    change: u32 = 0,
    frame_checksum: [2]u32 = .{ 0, 0 },
    checksum: [2]u32 = .{ 0, 0 },
};

pub const IndexPage = struct {
    page_numbers: []u32,
    hash: []u16,

    fn init(allocator: std.mem.Allocator) Error!IndexPage {
        const page_numbers = allocator.alloc(u32, hash_table_page_count) catch return error.NoMemory;
        errdefer allocator.free(page_numbers);
        const hash = allocator.alloc(u16, hash_table_slot_count) catch return error.NoMemory;
        @memset(page_numbers, 0);
        @memset(hash, 0);
        return .{ .page_numbers = page_numbers, .hash = hash };
    }

    fn deinit(self: *IndexPage, allocator: std.mem.Allocator) void {
        allocator.free(self.page_numbers);
        allocator.free(self.hash);
    }
};

pub const HashLocation = struct {
    page_numbers: []u32,
    hash: []u16,
    zero: u32,
};

pub const FrameData = struct {
    page_number: u32,
    database_pages: u32,
    data: []const u8,
    checksum: [2]u32 = .{ 0, 0 },
};
pub const StoredFrame = struct {
    page_number: u32,
    database_pages: u32,
    data: []u8,
    checksum: [2]u32,
};
pub const Writer = struct {
    wal: *Wal,
    sync_point: usize = 0,
    sync_count: usize = 0,
};
pub const UndoCallback = *const fn (?*anyopaque, u32) Error!void;
pub const BusyCallback = *const fn (?*anyopaque) bool;

pub const Wal = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList(IndexPage) = .empty,
    header: Header = .{},
    published_headers: [2]Header = .{ .{}, .{} },
    exclusive_mode: bool = false,
    write_lock: bool = false,
    checkpoint_lock: bool = false,
    read_only_index: bool = false,
    shared_locks: u64 = 0,
    exclusive_locks: u64 = 0,
    checkpoint_sequence: u32 = 0,
    callback_frame: u32 = 0,
    rechecksum_frame: u32 = 0,
    salt: [2]u32 = .{ 0, 0 },
    backfill: u32 = 0,
    backfill_attempted: u32 = 0,
    read_marks: [5]u32 = .{ 0, 0, std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
    read_lock: i8 = -1,
    minimum_frame: u32 = 1,
    read_only: bool = false,
    unreliable_index: bool = false,
    page_size: usize = 0,
    maximum_size: i64 = -1,
    sync_header: bool = true,
    pad_to_sector_boundary: bool = true,
    file_open: bool = false,
    name: ?[]u8 = null,
    wal_bytes: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(StoredFrame) = .empty,
    database: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Wal) void {
        for (self.pages.items) |*page| page.deinit(self.allocator);
        self.pages.deinit(self.allocator);
        for (self.frames.items) |frame| self.allocator.free(frame.data);
        self.frames.deinit(self.allocator);
        self.wal_bytes.deinit(self.allocator);
        self.database.deinit(self.allocator);
        if (self.name) |name| self.allocator.free(name);
    }
};

/// Source `walPagesize()` after the WAL header page size has been decoded.
pub fn pageSize(wal: *const Wal) u32 {
    return wal.header.page_size;
}

/// Source `sqlite3WalLimit()`.
pub fn setLimit(wal: ?*Wal, byte_limit: i64) void {
    if (wal) |value| value.maximum_size = byte_limit;
}

/// Source `sqlite3WalDbsize()`.
pub fn databaseSize(wal: ?*const Wal) u32 {
    const value = wal orelse return 0;
    if (value.read_lock < 0) return 0;
    return value.header.database_pages;
}

/// Source `sqlite3WalCallback()`.
pub fn takeCallbackFrame(wal: ?*Wal) u32 {
    const value = wal orelse return 0;
    const frame = value.callback_frame;
    value.callback_frame = 0;
    return frame;
}

fn headerChecksum(header: *const Header) [2]u32 {
    var one: u32 = @intFromBool(header.initialized) +% header.version;
    var two: u32 = header.max_frame +% header.database_pages +% one;
    one +%= header.page_size +% header.change +% header.frame_checksum[0] +% two;
    two +%= header.frame_checksum[1] +% one;
    return .{ one, two };
}

/// Source `walHash()`.
pub fn hashPage(page_number: u32) usize {
    std.debug.assert(page_number > 0);
    return @intCast((page_number *% 383) & (hash_table_slot_count - 1));
}

/// Source `walNextHash()`.
pub fn nextHash(slot: usize) usize {
    return (slot + 1) & (hash_table_slot_count - 1);
}

/// Source `walIndexPageRealloc()` (`src/wal.c:756-804`).
pub fn indexPageReallocate(wal: *Wal, index: usize) Error!*IndexPage {
    while (wal.pages.items.len <= index) {
        const page = try IndexPage.init(wal.allocator);
        wal.pages.append(wal.allocator, page) catch {
            var owned = page;
            owned.deinit(wal.allocator);
            return error.NoMemory;
        };
    }
    return &wal.pages.items[index];
}

/// Source `walIndexPage()` (`src/wal.c:805-815`).
pub fn indexPage(wal: *Wal, index: usize) Error!*IndexPage {
    if (index < wal.pages.items.len) return &wal.pages.items[index];
    return indexPageReallocate(wal, index);
}

/// Source `walShmBarrier()`: skip the external shared-memory barrier only
/// while the WAL index is connection-private heap memory.
pub fn sharedMemoryBarrier(wal: *const Wal) void {
    if (!wal.exclusive_mode) mutex.memoryBarrier();
}

/// Source `walIndexWriteHdr()` (`src/wal.c:942-954`).
pub fn indexWriteHeader(wal: *Wal) void {
    std.debug.assert(wal.write_lock);
    wal.header.initialized = true;
    wal.header.version = 3_007_000;
    wal.header.checksum = headerChecksum(&wal.header);
    wal.published_headers[1] = wal.header;
    sharedMemoryBarrier(wal);
    wal.published_headers[0] = wal.header;
}

/// Source `walLockShared()` (`src/wal.c:1085-1097`).
pub fn lockShared(wal: *Wal, index: u6) Error!void {
    if (wal.exclusive_mode) return;
    const bit = @as(u64, 1) << index;
    if ((wal.exclusive_locks & bit) != 0) return error.Busy;
    wal.shared_locks |= bit;
}

/// Source `walLockExclusive()` (`src/wal.c:1107-1121`).
pub fn lockExclusive(wal: *Wal, index: u6, count: u6) Error!void {
    if (wal.exclusive_mode) return;
    if (count == 0 or @as(u7, index) + count > 64) return error.Range;
    const mask = if (count == 64) std.math.maxInt(u64) else ((@as(u64, 1) << count) - 1) << index;
    if ((wal.shared_locks & mask) != 0 or (wal.exclusive_locks & mask) != 0) return error.Busy;
    wal.exclusive_locks |= mask;
}

/// Source `walUnlockExclusive()` (`src/wal.c:1122-1131`).
pub fn unlockExclusive(wal: *Wal, index: u6, count: u6) void {
    if (wal.exclusive_mode or count == 0 or @as(u7, index) + count > 64) return;
    const mask = if (count == 64) std.math.maxInt(u64) else ((@as(u64, 1) << count) - 1) << index;
    wal.exclusive_locks &= ~mask;
}

/// Source `walHashGet()` (`src/wal.c:1173-1195`).
pub fn hashGet(wal: *Wal, index: usize) Error!HashLocation {
    const page = try indexPage(wal, index);
    return .{
        .page_numbers = page.page_numbers,
        .hash = page.hash,
        .zero = if (index == 0) 0 else @intCast(first_hash_page_count + (index - 1) * hash_table_page_count),
    };
}

/// Source `walFramePage()` (`src/wal.c:1203-1213`).
pub fn framePage(frame: u32) usize {
    if (frame <= first_hash_page_count) return 0;
    return 1 + @as(usize, frame - first_hash_page_count - 1) / hash_table_page_count;
}

/// Source `walCleanupHash()` (`src/wal.c:1239-1294`).
pub fn cleanupHash(wal: *Wal) Error!void {
    if (wal.header.max_frame == 0) return;
    var location = try hashGet(wal, framePage(wal.header.max_frame));
    const limit: usize = @intCast(wal.header.max_frame - location.zero);
    for (location.hash) |*entry| {
        if (entry.* > limit) {
            entry.* = 0;
        }
    }
    if (limit < location.page_numbers.len) @memset(location.page_numbers[limit..], 0);
}

/// Source `walIndexAppend()` (`src/wal.c:1301-1377`).
pub fn indexAppend(wal: *Wal, frame: u32, page_number: u32) Error!void {
    var location = try hashGet(wal, framePage(frame));
    const index: usize = @intCast(frame - location.zero);
    if (index == 0 or index > hash_table_page_count) return error.Range;
    if (index == 1) {
        @memset(location.page_numbers, 0);
        @memset(location.hash, 0);
    }
    if (location.page_numbers[index - 1] != 0) try cleanupHash(wal);
    var slot = hashPage(page_number);
    var collisions = index;
    while (location.hash[slot] != 0) {
        if (collisions == 0) return error.Corrupt;
        collisions -= 1;
        slot = nextHash(slot);
    }
    location.page_numbers[index - 1] = page_number;
    location.hash[slot] = @intCast(index);
}

pub const Segment = struct {
    zero: u32,
    page_numbers: []const u32,
    indexes: []const u16,
    next: usize = 0,
};

pub const Iterator = struct {
    prior: u32 = 0,
    segments: []Segment,
};

/// Source `walIteratorNext()` (`src/wal.c:1764-1792`).
pub fn iteratorNext(iterator: *Iterator, page_output: *u32, frame_output: *u32) bool {
    var result: u32 = std.math.maxInt(u32);
    var segment_index = iterator.segments.len;
    while (segment_index > 0) {
        segment_index -= 1;
        const segment = &iterator.segments[segment_index];
        while (segment.next < segment.indexes.len) {
            const page = segment.page_numbers[segment.indexes[segment.next]];
            if (page > iterator.prior) {
                if (page < result) {
                    result = page;
                    frame_output.* = segment.zero + segment.indexes[segment.next];
                }
                break;
            }
            segment.next += 1;
        }
    }
    iterator.prior = result;
    page_output.* = result;
    return result == std.math.maxInt(u32);
}

/// Source `walMerge()` (`src/wal.c:1817-1855`).
pub fn merge(content: []const u32, left: []u16, right: []const u16, temporary: []u16) usize {
    var left_index: usize = 0;
    var right_index: usize = 0;
    var output_index: usize = 0;
    while (left_index < left.len or right_index < right.len) {
        const log_page = if (left_index < left.len and (right_index >= right.len or content[left[left_index]] < content[right[right_index]])) blk: {
            defer left_index += 1;
            break :blk left[left_index];
        } else blk: {
            defer right_index += 1;
            break :blk right[right_index];
        };
        const database_page = content[log_page];
        temporary[output_index] = log_page;
        output_index += 1;
        if (left_index < left.len and content[left[left_index]] == database_page) {
            left_index += 1;
        }
    }
    @memcpy(left[0..output_index], temporary[0..output_index]);
    return output_index;
}

/// Source `walMergesort()` (`src/wal.c:1874-1932`).
pub fn mergeSort(allocator: std.mem.Allocator, content: []const u32, indexes: *std.ArrayList(u16)) Error!void {
    if (indexes.items.len < 2) return;
    const temporary = allocator.alloc(u16, indexes.items.len) catch return error.NoMemory;
    defer allocator.free(temporary);
    var width: usize = 1;
    while (width < indexes.items.len) : (width *= 2) {
        var start: usize = 0;
        while (start < indexes.items.len) : (start += width * 2) {
            const middle = @min(start + width, indexes.items.len);
            const end = @min(start + width * 2, indexes.items.len);
            var left = start;
            var right = middle;
            var output = start;
            while (left < middle or right < end) {
                if (left < middle and (right >= end or content[indexes.items[left]] <= content[indexes.items[right]])) {
                    temporary[output] = indexes.items[left];
                    left += 1;
                } else {
                    temporary[output] = indexes.items[right];
                    right += 1;
                }
                output += 1;
            }
            @memcpy(indexes.items[start..end], temporary[start..end]);
        }
    }
    var output: usize = 0;
    for (indexes.items) |index| {
        if (output == 0 or content[indexes.items[output - 1]] != content[index]) {
            indexes.items[output] = index;
            output += 1;
        }
    }
    indexes.shrinkRetainingCapacity(output);
}

pub const OwnedIterator = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,
    owned_indexes: std.ArrayList([]u16) = .empty,
    iterator: Iterator = .{ .segments = &.{} },

    pub fn deinit(self: *OwnedIterator) void {
        for (self.owned_indexes.items) |indexes| self.allocator.free(indexes);
        self.owned_indexes.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }
};

/// Source `walIteratorInit()` (`src/wal.c:1954-2017`).
pub fn iteratorInitialize(wal: *Wal, backfill: u32) Error!OwnedIterator {
    if (!wal.checkpoint_lock or wal.header.max_frame == 0) return error.Range;
    var result = OwnedIterator{ .allocator = wal.allocator };
    errdefer result.deinit();
    const first = framePage(backfill + 1);
    const last = framePage(wal.header.max_frame);
    var page_index = first;
    while (page_index <= last) : (page_index += 1) {
        const location = try hashGet(wal, page_index);
        const entry_count: usize = if (page_index == last) @intCast(wal.header.max_frame - location.zero) else hash_table_page_count;
        var list = std.ArrayList(u16).empty;
        defer list.deinit(wal.allocator);
        list.ensureTotalCapacity(wal.allocator, entry_count) catch return error.NoMemory;
        for (0..entry_count) |index| list.appendAssumeCapacity(@intCast(index));
        try mergeSort(wal.allocator, location.page_numbers, &list);
        const owned = wal.allocator.dupe(u16, list.items) catch return error.NoMemory;
        result.owned_indexes.append(wal.allocator, owned) catch {
            wal.allocator.free(owned);
            return error.NoMemory;
        };
        result.segments.append(wal.allocator, .{
            .zero = location.zero + 1,
            .page_numbers = location.page_numbers,
            .indexes = owned,
        }) catch return error.NoMemory;
    }
    result.iterator = .{ .segments = result.segments.items };
    return result;
}

/// Source `sqlite3WalSavepoint()`.
pub fn savepoint(wal: *const Wal) [4]u32 {
    std.debug.assert(wal.write_lock);
    return .{
        wal.header.max_frame,
        wal.header.frame_checksum[0],
        wal.header.frame_checksum[1],
        wal.checkpoint_sequence,
    };
}

/// Source `sqlite3WalSavepointUndo()` (`src/wal.c:3832-3861`).
pub fn savepointUndo(wal: *Wal, data: *[4]u32) Error!void {
    if (!wal.write_lock) return error.Range;
    if (data[3] != wal.checkpoint_sequence) {
        data[0] = 0;
        data[3] = wal.checkpoint_sequence;
    }
    if (data[0] < wal.header.max_frame) {
        wal.header.max_frame = data[0];
        wal.header.frame_checksum = .{ data[1], data[2] };
        try cleanupHash(wal);
        if (wal.rechecksum_frame > wal.header.max_frame) {
            wal.rechecksum_frame = 0;
        }
    }
}

/// Source `walBusyLock()`.
pub fn busyLock(wal: *Wal, callback: ?BusyCallback, context: ?*anyopaque, index: u6, count: u6) Error!void {
    while (true) {
        lockExclusive(wal, index, count) catch |failure| {
            if (failure != error.Busy or callback == null or !callback.?(context)) return failure;
            continue;
        };
        return;
    }
}

/// Source `walRestartHdr()`.
pub fn restartHeader(wal: *Wal, second_salt: u32) void {
    wal.checkpoint_sequence +%= 1;
    wal.header.max_frame = 0;
    wal.salt[0] +%= 1;
    wal.salt[1] = second_salt;
    indexWriteHeader(wal);
    wal.backfill = 0;
    wal.backfill_attempted = 0;
    wal.read_marks[1] = 0;
    for (wal.read_marks[2..]) |*mark| mark.* = std.math.maxInt(u32);
}

/// Source `walLimitSize()`.
pub fn limitSize(wal: *Wal, maximum: usize) void {
    if (wal.wal_bytes.items.len > maximum) wal.wal_bytes.shrinkRetainingCapacity(maximum);
}

/// Source `walIndexTryHdr()`.
pub fn indexTryHeader(wal: *Wal, changed: *bool) bool {
    const first = wal.published_headers[0];
    sharedMemoryBarrier(wal);
    const second = wal.published_headers[1];
    if (!std.meta.eql(first, second) or !first.initialized or !std.mem.eql(u32, &first.checksum, &headerChecksum(&first))) return false;
    if (!std.meta.eql(wal.header, first)) {
        changed.* = true;
        wal.header = first;
    }
    return true;
}

/// Source `walRestartLog()`.
pub fn restartLog(wal: *Wal, random_salt: u32) Error!void {
    if (wal.read_lock != 0 or wal.backfill != wal.header.max_frame or wal.backfill == 0) return;
    try lockExclusive(wal, 1, @intCast(wal.read_marks.len - 1));
    restartHeader(wal, random_salt);
    unlockExclusive(wal, 1, @intCast(wal.read_marks.len - 1));
    wal.read_lock = -1;
}

fn framePageNumber(wal: *Wal, frame: u32) Error!u32 {
    const location = try hashGet(wal, framePage(frame));
    const index: usize = @intCast(frame - location.zero - 1);
    if (index >= location.page_numbers.len) return error.Range;
    return location.page_numbers[index];
}

/// Source `sqlite3WalUndo()`.
pub fn undo(wal: *Wal, callback: UndoCallback, context: ?*anyopaque) Error!void {
    if (!wal.write_lock) return;
    const maximum = wal.header.max_frame;
    wal.header = wal.published_headers[0];
    var frame = wal.header.max_frame + 1;
    while (frame <= maximum) : (frame += 1) {
        const page_number = try framePageNumber(wal, frame);
        if (page_number == 1) return error.Corrupt;
        try callback(context, page_number);
    }
    if (maximum != wal.header.max_frame) try cleanupHash(wal);
    wal.rechecksum_frame = 0;
}

/// Source `sqlite3WalExclusiveMode()`.
pub fn exclusiveMode(wal: *Wal, operation: i2) bool {
    if (operation == 0) {
        if (!wal.exclusive_mode) return false;
        wal.exclusive_mode = false;
        lockShared(wal, @intCast(@max(wal.read_lock, 0))) catch {
            wal.exclusive_mode = true;
            return false;
        };
        return true;
    }
    if (operation > 0) {
        if (wal.read_lock >= 0) {
            wal.shared_locks &= ~(@as(u64, 1) << @intCast(wal.read_lock));
        }
        wal.exclusive_mode = true;
        return true;
    }
    return !wal.exclusive_mode;
}

fn checksumFrame(initial: [2]u32, frame: *const FrameData) [2]u32 {
    var result = initial;
    result[0] +%= frame.page_number +% result[1];
    result[1] +%= frame.database_pages +% result[0];
    var offset: usize = 0;
    while (offset + 4 <= frame.data.len) : (offset += 4) {
        result[0] +%= std.mem.readInt(u32, frame.data[offset..][0..4], .big) +% result[1];
        result[1] +%= result[0];
    }
    return result;
}

/// Source `walRewriteChecksums()`.
pub fn rewriteChecksums(wal: *Wal, frames: []FrameData, last: u32, initial: [2]u32) Error!void {
    if (wal.rechecksum_frame == 0) return error.Range;
    var checksum = initial;
    var frame_number = wal.rechecksum_frame;
    wal.rechecksum_frame = 0;
    while (frame_number <= last) : (frame_number += 1) {
        if (frame_number == 0 or frame_number > frames.len) return error.Range;
        const frame = &frames[frame_number - 1];
        checksum = checksumFrame(checksum, frame);
        frame.checksum = checksum;
    }
    wal.header.frame_checksum = checksum;
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}

fn frameOffset(frame: u32, page_size: usize) usize {
    return 32 + @as(usize, frame - 1) * (24 + page_size);
}

/// Source `walChecksumBytes()`.
pub fn checksumBytes(native_checksum: bool, bytes: []const u8, initial: ?[2]u32) [2]u32 {
    std.debug.assert(bytes.len >= 8 and bytes.len <= 65_536 and bytes.len % 8 == 0);
    var result = initial orelse .{ 0, 0 };
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 8) {
        const first = std.mem.readInt(u32, bytes[offset..][0..4], if (native_checksum) .little else .big);
        const second = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], if (native_checksum) .little else .big);
        result[0] +%= first +% result[1];
        result[1] +%= second +% result[0];
    }
    return result;
}

/// Source `walEncodeFrame()`.
pub fn encodeFrame(wal: *Wal, page_number: u32, database_pages: u32, data: []const u8, output: *[24]u8) Error!void {
    if (wal.page_size == 0 or data.len != wal.page_size) return error.Range;
    writeU32(output[0..4], page_number);
    writeU32(output[4..8], database_pages);
    if (wal.rechecksum_frame == 0) {
        writeU32(output[8..12], wal.salt[0]);
        writeU32(output[12..16], wal.salt[1]);
        var checksum = checksumBytes(true, output[0..8], wal.header.frame_checksum);
        checksum = checksumBytes(true, data, checksum);
        wal.header.frame_checksum = checksum;
        writeU32(output[16..20], checksum[0]);
        writeU32(output[20..24], checksum[1]);
    } else {
        @memset(output[8..24], 0);
    }
}

/// Source `walDecodeFrame()`.
pub fn decodeFrame(wal: *Wal, header_bytes: *const [24]u8, data: []const u8, page_output: *u32, truncate_output: *u32) bool {
    if (data.len != wal.page_size or wal.page_size == 0) return false;
    if (readU32(header_bytes[8..12]) != wal.salt[0] or readU32(header_bytes[12..16]) != wal.salt[1]) return false;
    const page_number = readU32(header_bytes[0..4]);
    if (page_number == 0) return false;
    var checksum = checksumBytes(true, header_bytes[0..8], wal.header.frame_checksum);
    checksum = checksumBytes(true, data, checksum);
    if (checksum[0] != readU32(header_bytes[16..20]) or checksum[1] != readU32(header_bytes[20..24])) return false;
    wal.header.frame_checksum = checksum;
    page_output.* = page_number;
    truncate_output.* = readU32(header_bytes[4..8]);
    return true;
}

/// Source `walIndexRecover()`.
pub fn indexRecover(wal: *Wal) Error!void {
    wal.header = .{};
    for (wal.pages.items) |*page| {
        @memset(page.page_numbers, 0);
        @memset(page.hash, 0);
    }
    if (wal.wal_bytes.items.len <= 32) return;
    const disk_header = wal.wal_bytes.items[0..32];
    const magic = readU32(disk_header[0..4]);
    const page_size = readU32(disk_header[8..12]);
    if ((magic & 0xffff_fffe) != 0x377f_0682 or page_size < 512 or page_size > 65_536 or !std.math.isPowerOfTwo(page_size)) return;
    const expected = checksumBytes(true, disk_header[0..24], null);
    if (expected[0] != readU32(disk_header[24..28]) or expected[1] != readU32(disk_header[28..32])) return;
    wal.page_size = page_size;
    wal.salt = .{ readU32(disk_header[16..20]), readU32(disk_header[20..24]) };
    wal.header.frame_checksum = expected;
    var frame: u32 = 1;
    while (frameOffset(frame, wal.page_size) + 24 + wal.page_size <= wal.wal_bytes.items.len) : (frame += 1) {
        const offset = frameOffset(frame, wal.page_size);
        const header_bytes: *const [24]u8 = @ptrCast(wal.wal_bytes.items[offset..][0..24]);
        const data = wal.wal_bytes.items[offset + 24 .. offset + 24 + wal.page_size];
        var page_number: u32 = 0;
        var truncate_to: u32 = 0;
        if (!decodeFrame(wal, header_bytes, data, &page_number, &truncate_to)) break;
        try indexAppend(wal, frame, page_number);
        if (truncate_to != 0) {
            wal.header.max_frame = frame;
            wal.header.database_pages = truncate_to;
        }
    }
    wal.header.initialized = true;
    wal.header.version = 3_007_000;
    wal.header.page_size = @intCast(wal.page_size);
    wal.header.checksum = headerChecksum(&wal.header);
    wal.published_headers = .{ wal.header, wal.header };
    wal.backfill = 0;
    wal.backfill_attempted = wal.header.max_frame;
}

/// Source `walIndexClose()`.
pub fn indexClose(wal: *Wal, delete: bool) void {
    for (wal.pages.items) |*page| page.deinit(wal.allocator);
    wal.pages.clearRetainingCapacity();
    if (delete) wal.wal_bytes.clearRetainingCapacity();
    wal.shared_locks = 0;
    wal.exclusive_locks = 0;
}

pub const OpenOptions = struct {
    heap_index: bool = false,
    maximum_size: i64 = -1,
    read_only: bool = false,
    sequential_device: bool = false,
    powersafe_overwrite: bool = false,
};

/// Source `sqlite3WalOpen()`: establish format invariants, own the WAL name,
/// initialize locking mode, and apply database device characteristics.
pub fn open(allocator: std.mem.Allocator, name: []const u8, options: OpenOptions) Error!*Wal {
    if (name.len == 0) return error.Range;
    std.debug.assert(@sizeOf(Header) >= 40);
    std.debug.assert(hash_table_page_count == 4096);
    std.debug.assert(first_hash_page_count == 4062);
    std.debug.assert(hash_table_slot_count == 8192);
    const wal = allocator.create(Wal) catch return error.NoMemory;
    errdefer allocator.destroy(wal);
    const owned_name = allocator.dupe(u8, name) catch return error.NoMemory;
    wal.* = .{
        .allocator = allocator,
        .exclusive_mode = options.heap_index,
        .maximum_size = options.maximum_size,
        .read_only = options.read_only,
        .sync_header = !options.sequential_device,
        .pad_to_sector_boundary = !options.powersafe_overwrite,
        .file_open = true,
        .name = owned_name,
    };
    return wal;
}

/// Source `sqlite3WalClose()`.
pub fn close(wal_optional: ?*Wal, checkpoint_on_close: bool) Error!void {
    const wal = wal_optional orelse return;
    if (checkpoint_on_close and wal.header.max_frame != 0) try checkpoint(wal, .passive, null, null);
    indexClose(wal, checkpoint_on_close);
    const allocator = wal.allocator;
    wal.deinit();
    allocator.destroy(wal);
}

/// Source `walIndexReadHdr()`.
pub fn indexReadHeader(wal: *Wal, changed: *bool) Error!void {
    changed.* = false;
    if (wal.pages.items.len != 0 and indexTryHeader(wal, changed)) return;
    if (wal.read_only and wal.wal_bytes.items.len != 0) {
        wal.unreliable_index = true;
    }
    const before = wal.header;
    try indexRecover(wal);
    changed.* = !std.meta.eql(before, wal.header);
    if (wal.unreliable_index and wal.header.max_frame == 0) {
        wal.unreliable_index = false;
    }
}

/// Source `walBeginShmUnreliable()`.
pub fn beginUnreliableIndex(wal: *Wal, changed: *bool) Error!void {
    if (!wal.unreliable_index or !wal.read_only) return error.Range;
    if (wal.wal_bytes.items.len < 32) {
        changed.* = true;
        if (wal.header.max_frame != 0) return error.Retry;
    } else if (readU32(wal.wal_bytes.items[16..20]) != wal.salt[0] or readU32(wal.wal_bytes.items[20..24]) != wal.salt[1]) {
        return error.Retry;
    }
    try lockShared(wal, 3);
    wal.read_lock = 0;
}

fn unlockShared(wal: *Wal, index: u6) void {
    if (wal.exclusive_mode) return;
    wal.shared_locks &= ~(@as(u64, 1) << index);
}

/// Source `walTryBeginRead()`.
pub fn tryBeginRead(wal: *Wal, changed: *bool, force_wal: bool, attempts: *usize) Error!void {
    if (wal.read_lock >= 0) return error.Range;
    attempts.* += 1;
    if (attempts.* > 100) return error.Protocol;
    if (!force_wal) {
        indexReadHeader(wal, changed) catch |failure| {
            if (failure == error.Busy) return error.Retry;
            return failure;
        };
        if (wal.unreliable_index) return beginUnreliableIndex(wal, changed);
    }
    if (!force_wal and wal.backfill == wal.header.max_frame) {
        lockShared(wal, 3) catch return error.Retry;
        sharedMemoryBarrier(wal);
        if (!std.meta.eql(wal.published_headers[0], wal.header)) {
            unlockShared(wal, 3);
            return error.Retry;
        }
        wal.read_lock = 0;
        return;
    }
    var selected: usize = 0;
    var maximum: u32 = 0;
    for (wal.read_marks[1..], 1..) |mark, index| {
        if (mark <= wal.header.max_frame and mark >= maximum) {
            maximum = mark;
            selected = index;
        }
    }
    if (maximum < wal.header.max_frame and !wal.read_only) {
        selected = 1;
        wal.read_marks[selected] = wal.header.max_frame;
        maximum = wal.header.max_frame;
    }
    if (selected == 0) return error.Retry;
    lockShared(wal, @intCast(3 + selected)) catch return error.Retry;
    wal.minimum_frame = wal.backfill + 1;
    sharedMemoryBarrier(wal);
    if (wal.read_marks[selected] != maximum or !std.meta.eql(wal.published_headers[0], wal.header)) {
        unlockShared(wal, @intCast(3 + selected));
        return error.Retry;
    }
    wal.read_lock = @intCast(selected);
}

/// Source `walBeginReadTransaction()`.
pub fn beginReadTransaction(wal: *Wal, changed: *bool) Error!void {
    var attempts: usize = 0;
    while (true) {
        tryBeginRead(wal, changed, false, &attempts) catch |failure| {
            if (failure == error.Retry) continue;
            return failure;
        };
        return;
    }
}

/// Source `sqlite3WalEndReadTransaction()`.
pub fn endReadTransaction(wal: *Wal) void {
    if (wal.read_lock >= 0) {
        wal.write_lock = false;
        const slot: u6 = @intCast(3 + @max(wal.read_lock, 0));
        unlockShared(wal, slot);
        wal.read_lock = -1;
    }
}

/// Source `walFindFrame()`.
pub fn findFrame(wal: *Wal, page_number: u32) Error!u32 {
    if (wal.read_lock < 0) return error.Range;
    if (wal.header.max_frame == 0 or (wal.read_lock == 0 and !wal.unreliable_index)) return 0;
    var frame = wal.header.max_frame;
    while (frame >= wal.minimum_frame and frame > 0) : (frame -= 1) {
        if (try framePageNumber(wal, frame) == page_number) return frame;
    }
    return 0;
}

/// Source `sqlite3WalFindFrame()`.
pub fn findFrameApi(wal: *Wal, page_number: u32, frame_output: *u32) Error!void {
    frame_output.* = try findFrame(wal, page_number);
}

/// Source `sqlite3WalReadFrame()`.
pub fn readFrame(wal: *Wal, frame: u32, output: []u8) Error!void {
    if (frame == 0 or wal.page_size == 0) return error.Range;
    const offset = frameOffset(frame, wal.page_size) + 24;
    if (offset > wal.wal_bytes.items.len or output.len > @min(wal.page_size, wal.wal_bytes.items.len - offset)) return error.Io;
    @memcpy(output, wal.wal_bytes.items[offset .. offset + output.len]);
}

/// Source `sqlite3WalBeginWriteTransaction()`.
pub fn beginWriteTransaction(wal: *Wal) Error!void {
    if (wal.read_lock < 0 or wal.write_lock) return error.Range;
    if (wal.read_only) return error.ReadOnly;
    try lockExclusive(wal, 0, 1);
    wal.write_lock = true;
    if (!std.meta.eql(wal.header, wal.published_headers[0])) {
        unlockExclusive(wal, 0, 1);
        wal.write_lock = false;
        return error.Busy;
    }
}

/// Source `walWriteToLog()`.
pub fn writeToLog(writer: *Writer, content: []const u8, offset: usize) Error!void {
    const end = std.math.add(usize, offset, content.len) catch return error.Range;
    if (writer.sync_point > offset and writer.sync_point <= end) {
        writer.sync_count += 1;
    }
    const old = writer.wal.wal_bytes.items.len;
    writer.wal.wal_bytes.resize(writer.wal.allocator, @max(old, end)) catch return error.NoMemory;
    if (writer.wal.wal_bytes.items.len > old) @memset(writer.wal.wal_bytes.items[old..], 0);
    @memcpy(writer.wal.wal_bytes.items[offset..end], content);
}

/// Source `walWriteOneFrame()`.
pub fn writeOneFrame(writer: *Writer, frame: FrameData, offset: usize) Error!void {
    var header_bytes: [24]u8 = undefined;
    try encodeFrame(writer.wal, frame.page_number, frame.database_pages, frame.data, &header_bytes);
    try writeToLog(writer, &header_bytes, offset);
    try writeToLog(writer, frame.data, offset + header_bytes.len);
}

fn writeWalHeader(wal: *Wal) Error!void {
    var bytes = [_]u8{0} ** 32;
    writeU32(bytes[0..4], 0x377f_0682);
    writeU32(bytes[4..8], 3_007_000);
    writeU32(bytes[8..12], @intCast(wal.page_size));
    writeU32(bytes[12..16], wal.checkpoint_sequence);
    writeU32(bytes[16..20], wal.salt[0]);
    writeU32(bytes[20..24], wal.salt[1]);
    const checksum = checksumBytes(true, bytes[0..24], null);
    writeU32(bytes[24..28], checksum[0]);
    writeU32(bytes[28..32], checksum[1]);
    wal.header.frame_checksum = checksum;
    var writer = Writer{ .wal = wal };
    try writeToLog(&writer, &bytes, 0);
}

/// Source `walFrames()`.
pub fn writeFrames(wal: *Wal, page_size: usize, input_frames: []const FrameData, truncate_to: u32, commit: bool, sync: bool) Error!void {
    if (!wal.write_lock or input_frames.len == 0 or commit != (truncate_to != 0)) return error.Range;
    if (wal.header.max_frame == 0) {
        wal.page_size = page_size;
        if (wal.salt[0] == 0 and wal.salt[1] == 0) {
            wal.salt = .{ 1, 0xa5a5_5a5a };
        }
        try writeWalHeader(wal);
    }
    if (wal.page_size != page_size) return error.Corrupt;
    var writer = Writer{ .wal = wal };
    var frame_number = wal.header.max_frame;
    for (input_frames, 0..) |input, index| {
        frame_number += 1;
        const database_pages = if (commit and index + 1 == input_frames.len) truncate_to else 0;
        const frame = FrameData{ .page_number = input.page_number, .database_pages = database_pages, .data = input.data };
        if (sync and commit and index + 1 == input_frames.len) {
            writer.sync_point = frameOffset(frame_number, page_size) + 24 + page_size;
        }
        try writeOneFrame(&writer, frame, frameOffset(frame_number, page_size));
        try indexAppend(wal, frame_number, input.page_number);
        const owned = wal.allocator.dupe(u8, input.data) catch return error.NoMemory;
        wal.frames.append(wal.allocator, .{ .page_number = input.page_number, .database_pages = database_pages, .data = owned, .checksum = wal.header.frame_checksum }) catch {
            wal.allocator.free(owned);
            return error.NoMemory;
        };
    }
    wal.header.max_frame = frame_number;
    wal.header.page_size = @intCast(page_size);
    if (commit) {
        wal.header.database_pages = truncate_to;
        wal.header.change +%= 1;
        indexWriteHeader(wal);
        wal.callback_frame = frame_number;
    }
    if (wal.maximum_size >= 0 and wal.wal_bytes.items.len > wal.maximum_size) limitSize(wal, @intCast(@max(wal.maximum_size, 0)));
}

/// Source `sqlite3WalFrames()`.
pub fn writeFramesApi(wal: *Wal, page_size: usize, input_frames: []const FrameData, truncate_to: u32, commit: bool, sync: bool) Error!void {
    try writeFrames(wal, page_size, input_frames, truncate_to, commit, sync);
}

pub const CheckpointMode = enum { passive, full, restart, truncate };

/// Source `walCheckpoint()`: serialize checkpoints, reduce the safe frame for
/// active readers, hold reader slot zero during backfill, and implement FULL,
/// RESTART, and TRUNCATE lock semantics.
pub fn checkpoint(wal: *Wal, mode: CheckpointMode, busy: ?BusyCallback, context: ?*anyopaque) Error!void {
    const acquired_checkpoint = !wal.checkpoint_lock;
    if (acquired_checkpoint) {
        lockExclusive(wal, 1, 1) catch return error.Busy;
        wal.checkpoint_lock = true;
    }
    defer if (acquired_checkpoint) {
        wal.checkpoint_lock = false;
        unlockExclusive(wal, 1, 1);
    };
    if (wal.backfill < wal.header.max_frame) {
        var safe_frame = wal.header.max_frame;
        for (wal.read_marks[1..], 1..) |mark, index| {
            if (mark == std.math.maxInt(u32) or safe_frame <= mark) {
                continue;
            }
            const callback = if (mode == .passive) null else busy;
            busyLock(wal, callback, context, @intCast(3 + index), 1) catch |failure| {
                if (failure != error.Busy) return failure;
                safe_frame = mark;
                continue;
            };
            wal.read_marks[index] = if (index == 1) safe_frame else std.math.maxInt(u32);
            unlockExclusive(wal, @intCast(3 + index), 1);
        }
        if (wal.backfill < safe_frame) {
            var owned = try iteratorInitialize(wal, wal.backfill);
            defer owned.deinit();
            busyLock(wal, if (mode == .passive) null else busy, context, 3, 1) catch |failure| {
                if (failure == error.Busy and mode == .passive) return;
                return failure;
            };
            defer unlockExclusive(wal, 3, 1);
            const original_backfill = wal.backfill;
            wal.backfill_attempted = safe_frame;
            while (true) {
                var page_number: u32 = 0;
                var frame_number: u32 = 0;
                if (iteratorNext(&owned.iterator, &page_number, &frame_number)) {
                    break;
                }
                if (frame_number <= original_backfill or frame_number > safe_frame or page_number > wal.header.database_pages) {
                    continue;
                }
                if (frame_number == 0 or frame_number > wal.frames.items.len) {
                    return error.Corrupt;
                }
                const source = wal.frames.items[frame_number - 1].data;
                const offset = std.math.mul(usize, page_number - 1, wal.page_size) catch return error.Range;
                const old = wal.database.items.len;
                wal.database.resize(wal.allocator, @max(old, offset + wal.page_size)) catch return error.NoMemory;
                if (wal.database.items.len > old) {
                    @memset(wal.database.items[old..], 0);
                }
                @memcpy(wal.database.items[offset .. offset + wal.page_size], source);
            }
            if (safe_frame == wal.header.max_frame) {
                const final_size = std.math.mul(usize, wal.header.database_pages, wal.page_size) catch return error.Range;
                wal.database.shrinkRetainingCapacity(@min(wal.database.items.len, final_size));
            }
            wal.backfill = safe_frame;
        }
    }
    if (mode != .passive and wal.backfill < wal.header.max_frame) return error.Busy;
    if ((mode == .restart or mode == .truncate) and wal.backfill == wal.header.max_frame) {
        try busyLock(wal, busy, context, 4, @intCast(wal.read_marks.len - 1));
        defer unlockExclusive(wal, 4, @intCast(wal.read_marks.len - 1));
        if (mode == .truncate) {
            restartHeader(wal, wal.salt[1] +% 1);
            wal.wal_bytes.clearRetainingCapacity();
            wal.frames.clearRetainingCapacity();
        }
    }
}

test "checkpoint batch WAL backfills the latest safe frame" {
    var wal = Wal{ .allocator = std.testing.allocator, .write_lock = true, .page_size = 512 };
    defer wal.deinit();
    const frame_data = try std.testing.allocator.alloc(u8, 512);
    @memset(frame_data, 0x5a);
    try wal.frames.append(std.testing.allocator, .{ .page_number = 1, .database_pages = 1, .data = frame_data, .checksum = .{ 0, 0 } });
    try indexAppend(&wal, 1, 1);
    wal.header.max_frame = 1;
    wal.header.database_pages = 1;
    indexWriteHeader(&wal);
    try checkpoint(&wal, .passive, null, null);
    try std.testing.expectEqual(@as(u32, 1), wal.backfill);
    try std.testing.expectEqual(@as(usize, 512), wal.database.items.len);
    try std.testing.expectEqual(@as(u8, 0x5a), wal.database.items[0]);
}

test "WAL index append cleanup and savepoint undo" {
    var wal = Wal{ .allocator = std.testing.allocator, .write_lock = true };
    defer wal.deinit();
    var changed = false;
    try std.testing.expect(!indexTryHeader(&wal, &changed));
    wal.published_headers[0] = .{ .initialized = true };
    try std.testing.expect(!indexTryHeader(&wal, &changed));
    wal.published_headers[1] = wal.published_headers[0];
    try std.testing.expect(!indexTryHeader(&wal, &changed));
    wal.published_headers[0].checksum = headerChecksum(&wal.published_headers[0]);
    wal.published_headers[1] = wal.published_headers[0];
    try std.testing.expect(indexTryHeader(&wal, &changed));
    try std.testing.expect(changed);
    changed = false;
    try std.testing.expect(indexTryHeader(&wal, &changed));
    try std.testing.expect(!changed);

    wal.header.database_pages = 9;
    wal.header.page_size = 65_536;
    try std.testing.expectEqual(@as(u32, 65_536), pageSize(&wal));
    sharedMemoryBarrier(&wal);
    wal.exclusive_mode = true;
    sharedMemoryBarrier(&wal);
    wal.exclusive_mode = false;
    try std.testing.expectEqual(@as(usize, 383), hashPage(1));
    try std.testing.expectEqual(@as(usize, 0), nextHash(hash_table_slot_count - 1));
    setLimit(null, 31);
    setLimit(&wal, 31);
    try std.testing.expectEqual(@as(i64, 31), wal.maximum_size);
    try std.testing.expectEqual(@as(u32, 0), databaseSize(null));
    try std.testing.expectEqual(@as(u32, 0), databaseSize(&wal));
    wal.read_lock = 0;
    try std.testing.expectEqual(@as(u32, 9), databaseSize(&wal));
    try std.testing.expectEqual(@as(u32, 0), takeCallbackFrame(null));
    wal.callback_frame = 17;
    try std.testing.expectEqual(@as(u32, 17), takeCallbackFrame(&wal));
    try std.testing.expectEqual(@as(u32, 0), takeCallbackFrame(&wal));
    try indexAppend(&wal, 1, 7);
    try indexAppend(&wal, 2, 3);
    wal.header.max_frame = 2;
    indexWriteHeader(&wal);
    try std.testing.expectEqual(@as(u32, 2), wal.published_headers[0].max_frame);
    wal.header.frame_checksum = .{ 11, 12 };
    wal.checkpoint_sequence = 4;
    const captured = savepoint(&wal);
    try std.testing.expectEqual([4]u32{ 2, 11, 12, 4 }, captured);
    var savepoint_data = [4]u32{ 1, 11, 12, 4 };
    try savepointUndo(&wal, &savepoint_data);
    try std.testing.expectEqual(@as(u32, 1), wal.header.max_frame);
}

test "WAL source merge iterator emits unique page order" {
    const content = [_]u32{ 9, 2, 5, 2 };
    var indexes = std.ArrayList(u16).empty;
    defer indexes.deinit(std.testing.allocator);
    try indexes.appendSlice(std.testing.allocator, &.{ 0, 1, 2, 3 });
    try mergeSort(std.testing.allocator, &content, &indexes);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 0 }, indexes.items);
}
