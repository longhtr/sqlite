//! Source-shaped in-memory rollback journal with optional VFS spill.

const std = @import("std");
const vfs = @import("vfs.zig");
pub const vfs_api = vfs;

const default_allocation_size: usize = 1024;

const Chunk = struct {
    next: ?*Chunk = null,
};

const Point = struct {
    offset: u64 = 0,
    chunk: ?*Chunk = null,
};

pub const Journal = struct {
    base: vfs.sqlite3_file,
    allocator: std.mem.Allocator,
    chunk_size: usize,
    spill_threshold: i64,
    first: ?*Chunk = null,
    endpoint: Point = .{},
    readpoint: Point = .{},
    flags: c_int,
    underlying_vfs: ?*vfs.sqlite3_vfs,
    journal_name: ?[*:0]const u8,
    real_storage: ?[]align(@alignOf(vfs.sqlite3_file)) u8 = null,
    real_file: ?*vfs.sqlite3_file = null,

    pub const OpenResult = struct { result: c_int, journal: Journal };

    pub fn open(allocator: std.mem.Allocator, underlying_vfs: ?*vfs.sqlite3_vfs, journal_name: ?[*:0]const u8, flags: c_int, spill_threshold: i64) OpenResult {
        var journal = Journal{
            .base = .{ .pMethods = &journal_io_methods },
            .allocator = allocator,
            .chunk_size = if (spill_threshold > 0) @intCast(spill_threshold) else default_allocation_size - @sizeOf(Chunk),
            .spill_threshold = spill_threshold,
            .flags = flags,
            .underlying_vfs = underlying_vfs,
            .journal_name = journal_name,
        };
        if (spill_threshold == 0) return .{ .result = journal.createFile(), .journal = journal };
        return .{ .result = vfs.OK, .journal = journal };
    }

    fn chunkAllocationSize(self: *const Journal) usize {
        return @sizeOf(Chunk) + self.chunk_size;
    }

    fn allocateChunk(self: *Journal) ?*Chunk {
        const allocation = self.allocator.alignedAlloc(u8, std.mem.Alignment.of(Chunk), self.chunkAllocationSize()) catch return null;
        const chunk: *Chunk = @ptrCast(allocation.ptr);
        chunk.* = .{};
        return chunk;
    }

    fn chunkBytes(self: *const Journal, chunk: *Chunk) []u8 {
        const pointer: [*]u8 = @ptrFromInt(@intFromPtr(chunk) + @sizeOf(Chunk));
        return pointer[0..self.chunk_size];
    }

    fn freeChunk(self: *Journal, chunk: *Chunk) void {
        const pointer: [*]align(@alignOf(Chunk)) u8 = @ptrCast(chunk);
        self.allocator.free(pointer[0..self.chunkAllocationSize()]);
    }

    fn freeChunks(self: *Journal, first: ?*Chunk) void {
        var current = first;
        while (current) |chunk| {
            const next = chunk.next;
            self.freeChunk(chunk);
            current = next;
        }
    }

    fn realMethods(self: *Journal) ?*const vfs.sqlite3_io_methods {
        return if (self.real_file) |file| file.pMethods else null;
    }

    fn closeReal(self: *Journal) c_int {
        var result = vfs.OK;
        if (self.real_file) |file| {
            if (file.pMethods) |methods| {
                if (methods.xClose) |close_fn| result = close_fn(file);
            }
        }
        if (self.real_storage) |storage| self.allocator.free(storage);
        self.real_storage = null;
        self.real_file = null;
        return result;
    }

    pub fn close(self: *Journal) c_int {
        const result = if (self.real_file != null) self.closeReal() else blk: {
            self.freeChunks(self.first);
            self.first = null;
            self.endpoint = .{};
            self.readpoint = .{};
            break :blk vfs.OK;
        };
        self.base.pMethods = null;
        return result;
    }

    pub fn abiFile(self: *Journal) *vfs.sqlite3_file {
        return &self.base;
    }

    pub fn isInMemory(self: *const Journal) bool {
        return self.real_file == null;
    }

    pub fn createFile(self: *Journal) c_int {
        if (self.real_file != null) return vfs.OK;
        const underlying = self.underlying_vfs orelse return vfs.ERROR;
        const open_fn = underlying.xOpen orelse return vfs.ERROR;
        const file_size = @max(@as(usize, @intCast(underlying.szOsFile)), @sizeOf(vfs.sqlite3_file));
        const storage = self.allocator.alignedAlloc(u8, std.mem.Alignment.of(vfs.sqlite3_file), file_size) catch return vfs.NOMEM;
        @memset(storage, 0);
        const file: *vfs.sqlite3_file = @ptrCast(storage.ptr);
        var result = open_fn(underlying, self.journal_name, file, self.flags, null);
        if (result == vfs.OK) {
            if (file.pMethods) |methods| {
                if (methods.xWrite) |write_call| {
                    var offset: u64 = 0;
                    var current = self.first;
                    while (current) |chunk| : (current = chunk.next) {
                        const amount = @min(self.chunk_size, self.endpoint.offset - offset);
                        if (amount == 0) break;
                        result = write_call(file, self.chunkBytes(chunk).ptr, @intCast(amount), @intCast(offset));
                        if (result != vfs.OK) break;
                        offset += amount;
                    }
                } else result = vfs.ERROR;
            } else result = vfs.ERROR;
        }
        if (result != vfs.OK) {
            if (file.pMethods) |methods| {
                if (methods.xClose) |close_fn| _ = close_fn(file);
            }
            self.allocator.free(storage);
            return result;
        }
        self.freeChunks(self.first);
        self.first = null;
        self.endpoint.chunk = null;
        self.readpoint = .{};
        self.real_storage = storage;
        self.real_file = file;
        return vfs.OK;
    }

    pub fn read(self: *Journal, output: []u8, offset: u64) c_int {
        if (self.real_file) |file| {
            const read_fn = (file.pMethods orelse return vfs.ERROR).xRead orelse return vfs.ERROR;
            return read_fn(file, output.ptr, @intCast(output.len), @intCast(offset));
        }
        const end = std.math.add(u64, offset, output.len) catch return vfs.IOERR_SHORT_READ;
        if (end > self.endpoint.offset) return vfs.IOERR_SHORT_READ;
        var chunk: ?*Chunk = null;
        var chunk_start: u64 = 0;
        if (offset != 0 and self.readpoint.offset == offset) {
            chunk = self.readpoint.chunk;
            chunk_start = offset - offset % self.chunk_size;
        } else {
            chunk = self.first;
            while (chunk != null and chunk_start + self.chunk_size <= offset) {
                chunk = chunk.?.next;
                chunk_start += self.chunk_size;
            }
        }
        var written: usize = 0;
        var within: usize = @intCast(offset % self.chunk_size);
        while (written < output.len) {
            const current = chunk orelse return vfs.IOERR_SHORT_READ;
            const amount = @min(output.len - written, self.chunk_size - within);
            const reached_boundary = within + amount == self.chunk_size;
            @memcpy(output[written .. written + amount], self.chunkBytes(current)[within .. within + amount]);
            written += amount;
            within = 0;
            if (written < output.len or reached_boundary) chunk = current.next;
        }
        self.readpoint = if (chunk != null) .{ .offset = end, .chunk = chunk } else .{};
        return vfs.OK;
    }

    pub fn write(self: *Journal, input: []const u8, offset: u64) c_int {
        if (self.real_file) |file| {
            const write_fn = (file.pMethods orelse return vfs.ERROR).xWrite orelse return vfs.ERROR;
            return write_fn(file, input.ptr, @intCast(input.len), @intCast(offset));
        }
        const end = std.math.add(u64, offset, input.len) catch return vfs.FULL;
        if (self.spill_threshold > 0 and end > self.spill_threshold) {
            const result = self.createFile();
            return if (result == vfs.OK) self.write(input, offset) else result;
        }
        if (offset > self.endpoint.offset) return vfs.IOERR_WRITE;
        if (offset > 0 and offset != self.endpoint.offset) _ = self.truncate(offset);
        if (offset == 0 and self.first != null) {
            if (input.len >= self.chunk_size) return vfs.IOERR_WRITE;
            @memcpy(self.chunkBytes(self.first.?)[0..input.len], input);
            return vfs.OK;
        }
        var consumed: usize = 0;
        while (consumed < input.len) {
            var chunk = self.endpoint.chunk;
            const within: usize = @intCast(self.endpoint.offset % self.chunk_size);
            if (within == 0) {
                const created = self.allocateChunk() orelse return vfs.IOERR_NOMEM;
                if (chunk) |previous| previous.next = created else self.first = created;
                chunk = created;
                self.endpoint.chunk = created;
            }
            const amount = @min(input.len - consumed, self.chunk_size - within);
            @memcpy(self.chunkBytes(chunk.?)[within .. within + amount], input[consumed .. consumed + amount]);
            consumed += amount;
            self.endpoint.offset += amount;
        }
        return vfs.OK;
    }

    pub fn truncate(self: *Journal, size: u64) c_int {
        if (self.real_file) |file| {
            const truncate_fn = (file.pMethods orelse return vfs.ERROR).xTruncate orelse return vfs.ERROR;
            return truncate_fn(file, @intCast(size));
        }
        if (size >= self.endpoint.offset) return vfs.OK;
        var last: ?*Chunk = null;
        if (size == 0) {
            self.freeChunks(self.first);
            self.first = null;
        } else {
            var boundary: u64 = self.chunk_size;
            last = self.first;
            while (last != null and boundary < size) {
                last = last.?.next;
                boundary += self.chunk_size;
            }
            if (last) |chunk| {
                self.freeChunks(chunk.next);
                chunk.next = null;
            }
        }
        self.endpoint = .{ .offset = size, .chunk = last };
        self.readpoint = .{};
        return vfs.OK;
    }

    pub fn sync(self: *Journal, flags: c_int) c_int {
        if (self.real_file) |file| {
            const sync_fn = (file.pMethods orelse return vfs.ERROR).xSync orelse return vfs.ERROR;
            return sync_fn(file, flags);
        }
        return vfs.OK;
    }

    pub fn fileSize(self: *Journal, output: *i64) c_int {
        if (self.real_file) |file| {
            const size_fn = (file.pMethods orelse return vfs.ERROR).xFileSize orelse return vfs.ERROR;
            return size_fn(file, output);
        }
        output.* = @intCast(self.endpoint.offset);
        return vfs.OK;
    }
};

fn journalOwner(file: *vfs.sqlite3_file) *Journal {
    return @fieldParentPtr("base", file);
}

fn journalClose(file: *vfs.sqlite3_file) callconv(.c) c_int {
    return journalOwner(file).close();
}

fn journalRead(file: *vfs.sqlite3_file, output: *anyopaque, amount: c_int, offset: i64) callconv(.c) c_int {
    if (amount < 0 or offset < 0) return vfs.IOERR_READ;
    return journalOwner(file).read(@as([*]u8, @ptrCast(output))[0..@intCast(amount)], @intCast(offset));
}

fn journalWrite(file: *vfs.sqlite3_file, input: *const anyopaque, amount: c_int, offset: i64) callconv(.c) c_int {
    if (amount < 0 or offset < 0) return vfs.IOERR_WRITE;
    return journalOwner(file).write(@as([*]const u8, @ptrCast(input))[0..@intCast(amount)], @intCast(offset));
}

fn journalTruncate(file: *vfs.sqlite3_file, size: i64) callconv(.c) c_int {
    if (size < 0) return vfs.IOERR_TRUNCATE;
    return journalOwner(file).truncate(@intCast(size));
}

fn journalSync(file: *vfs.sqlite3_file, flags: c_int) callconv(.c) c_int {
    return journalOwner(file).sync(flags);
}

fn journalFileSize(file: *vfs.sqlite3_file, output: *i64) callconv(.c) c_int {
    return journalOwner(file).fileSize(output);
}

const journal_io_methods = vfs.sqlite3_io_methods{
    .iVersion = 1,
    .xClose = journalClose,
    .xRead = journalRead,
    .xWrite = journalWrite,
    .xTruncate = journalTruncate,
    .xSync = journalSync,
    .xFileSize = journalFileSize,
    .xLock = null,
    .xUnlock = null,
    .xCheckReservedLock = null,
    .xFileControl = null,
    .xSectorSize = null,
    .xDeviceCharacteristics = null,
    .xShmMap = null,
    .xShmLock = null,
    .xShmBarrier = null,
    .xShmUnmap = null,
    .xFetch = null,
    .xUnfetch = null,
};

pub fn journalSize(underlying_vfs: *const vfs.sqlite3_vfs) usize {
    return @max(@as(usize, @intCast(underlying_vfs.szOsFile)), @sizeOf(Journal));
}

test "memory journal publishes the source sqlite3_file method tail" {
    const opened = Journal.open(std.testing.allocator, null, null, 0, -1);
    try std.testing.expectEqual(vfs.OK, opened.result);
    var journal = opened.journal;
    const file = journal.abiFile();
    const methods = file.pMethods.?;
    try std.testing.expectEqual(@as(c_int, 1), methods.iVersion);
    try std.testing.expect(methods.xLock == null and methods.xFileControl == null);
    try std.testing.expect(methods.xShmMap == null and methods.xFetch == null);
    try std.testing.expectEqual(vfs.OK, methods.xWrite.?(file, "abcdef".ptr, 6, 0));
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(vfs.OK, methods.xRead.?(file, &output, output.len, 1));
    try std.testing.expectEqualStrings("bcde", &output);
    var size: i64 = -1;
    try std.testing.expectEqual(vfs.OK, methods.xFileSize.?(file, &size));
    try std.testing.expectEqual(@as(i64, 6), size);
    try std.testing.expectEqual(vfs.OK, methods.xClose.?(file));
    try std.testing.expectEqual(null, file.pMethods);
}

test "memory journal chunks read overwrite truncate and close" {
    const opened = Journal.open(std.testing.allocator, null, null, 0, -1);
    try std.testing.expectEqual(vfs.OK, opened.result);
    var journal = opened.journal;
    defer _ = journal.close();
    const bytes = "abcdefgh" ** 200;
    try std.testing.expectEqual(vfs.OK, journal.write(bytes, 0));
    var output: [1100]u8 = undefined;
    try std.testing.expectEqual(vfs.OK, journal.read(&output, 500));
    try std.testing.expectEqualSlices(u8, bytes[500..1600], &output);
    try std.testing.expectEqual(vfs.IOERR_SHORT_READ, journal.read(&output, 501));
    try std.testing.expectEqual(vfs.OK, journal.write("HEADER", 0));
    var header: [6]u8 = undefined;
    try std.testing.expectEqual(vfs.OK, journal.read(&header, 0));
    try std.testing.expectEqualStrings("HEADER", &header);
    try std.testing.expectEqual(vfs.OK, journal.truncate(900));
    var size: i64 = -1;
    try std.testing.expectEqual(vfs.OK, journal.fileSize(&size));
    try std.testing.expectEqual(@as(i64, 900), size);
    try std.testing.expectEqual(vfs.OK, journal.write("tail", 900));
}

test "memory journal spills atomically to underlying VFS" {
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("journal-spill", &memory);
    const opened = Journal.open(std.testing.allocator, &adapter.abi, "spill-journal", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_JOURNAL, 32);
    try std.testing.expectEqual(vfs.OK, opened.result);
    var journal = opened.journal;
    defer _ = journal.close();
    try std.testing.expect(journal.isInMemory());
    try std.testing.expectEqual(vfs.OK, journal.write("0123456789abcdef", 0));
    try std.testing.expectEqual(vfs.OK, journal.write("0123456789abcdef0123", 16));
    try std.testing.expect(!journal.isInMemory());
    var output: [36]u8 = undefined;
    try std.testing.expectEqual(vfs.OK, journal.read(&output, 0));
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123", &output);
}

test "memory journal allocation failure retains a closable prefix" {
    var failing = @import("testing_one_shot_allocator.zig").OneShotFailAllocator.init(std.testing.allocator, 0);
    const opened = Journal.open(failing.allocator(), null, null, 0, -1);
    var journal = opened.journal;
    try std.testing.expectEqual(vfs.IOERR_NOMEM, journal.write("x", 0));
    try std.testing.expectEqual(vfs.OK, journal.close());
}
