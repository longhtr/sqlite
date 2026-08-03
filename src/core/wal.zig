//! Native bounded WAL reader/writer, recovery index, and checkpoint engine.
//! The on-disk format is SQLite-compatible. The in-memory index is rebuilt
//! from committed frames and published through the public VFS shared-memory
//! methods; no private C layout crosses this module.

const std = @import("std");
const ResultCode = @import("result_code.zig").ResultCode;
pub const vfs = @import("vfs.zig");
pub const page_cache = @import("page_cache.zig");

pub const wal_magic: u32 = 0x377f0682;
pub const wal_version: u32 = 3_007_000;
pub const header_size: u64 = 32;
pub const frame_header_size: u64 = 24;
pub const write_lock: c_int = 0;
pub const checkpoint_lock: c_int = 1;
pub const recover_lock: c_int = 2;
pub const read_lock: c_int = 3;

const AlignedFileBytes = []align(@alignOf(vfs.sqlite3_file)) u8;
const Checksum = struct { one: u32 = 0, two: u32 = 0 };
pub const Frame = struct { number: u32, page_number: u32, database_pages: u32, offset: u64 };

pub const OpenOutcome = struct { result: ResultCode, wal: ?Wal = null };
pub const ReadOutcome = struct { result: ResultCode, found: bool = false };
pub const CheckpointOutcome = struct { result: ResultCode, frames: u32 = 0, checkpointed: u32 = 0 };
pub const Event = enum { header_write, header_sync, frame_header_write, frame_page_write, wal_sync, index_publish, checkpoint_database_write, checkpoint_database_sync, wal_reset };
pub const EventHook = *const fn (?*anyopaque, Event) bool;

pub const Wal = struct {
    allocator: std.mem.Allocator,
    abi_vfs: *vfs.sqlite3_vfs,
    database_file: *vfs.sqlite3_file,
    name: [:0]const u8,
    file_bytes: ?AlignedFileBytes = null,
    file: ?*vfs.sqlite3_file = null,
    writable: bool,
    page_size: u32,
    salt: [2]u32 = .{ 0, 0 },
    header_checksum: Checksum = .{},
    frame_checksum: Checksum = .{},
    frame_count: u32 = 0,
    database_pages: u32 = 0,
    frames: std.AutoHashMap(u32, Frame),
    read_locked: bool = false,
    write_locked: bool = false,
    checkpoint_locked: bool = false,
    event_hook: ?EventHook = null,
    event_context: ?*anyopaque = null,
    publish_native_index: bool = true,

    pub fn open(
        allocator: std.mem.Allocator,
        abi_vfs: *vfs.sqlite3_vfs,
        database_file: *vfs.sqlite3_file,
        name: [:0]const u8,
        page_size: u32,
        writable: bool,
        exists: bool,
        publish_native_index: bool,
    ) OpenOutcome {
        var wal = Wal{
            .allocator = allocator,
            .abi_vfs = abi_vfs,
            .database_file = database_file,
            .name = name,
            .writable = writable,
            .page_size = page_size,
            .frames = std.AutoHashMap(u32, Frame).init(allocator),
            .publish_native_index = publish_native_index,
        };
        if (exists) {
            const rc = wal.openFile(false);
            if (rc != .ok) {
                wal.frames.deinit();
                return .{ .result = rc };
            }
            const database_methods = methods(database_file) orelse {
                wal.deinit();
                return .{ .result = .io_error };
            };
            const map_function = database_methods.xShmMap orelse {
                wal.deinit();
                return .{ .result = .io_error };
            };
            var mapped: ?*volatile anyopaque = null;
            var recover_rc = ResultCode.fromC(map_function(database_file, 0, vfs.SHM_REGION_SIZE, 1, &mapped));
            if (recover_rc == .ok) recover_rc = wal.lock(recover_lock, vfs.SHM_LOCK | vfs.SHM_EXCLUSIVE);
            if (recover_rc == .ok) recover_rc = wal.recover();
            const unlock_rc = wal.lock(recover_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
            if (recover_rc == .ok) recover_rc = unlock_rc;
            if (recover_rc != .ok) {
                wal.deinit();
                return .{ .result = recover_rc };
            }
        }
        if (!exists) {
            const publish_rc = wal.publishIndex();
            if (publish_rc != .ok) {
                wal.deinit();
                return .{ .result = publish_rc };
            }
        }
        const lock_rc = wal.lock(read_lock, vfs.SHM_LOCK | vfs.SHM_SHARED);
        if (lock_rc != .ok) {
            wal.deinit();
            return .{ .result = lock_rc };
        }
        wal.read_locked = true;
        return .{ .result = .ok, .wal = wal };
    }

    fn methods(file: *vfs.sqlite3_file) ?*const vfs.sqlite3_io_methods {
        return file.pMethods;
    }

    fn readFile(file: *vfs.sqlite3_file, output: []u8, offset: u64) ResultCode {
        const read_fn = (methods(file) orelse return .io_error).xRead orelse return .io_error;
        if (output.len > std.math.maxInt(c_int) or offset > std.math.maxInt(i64)) return .full;
        return ResultCode.fromC(read_fn(file, @ptrCast(output.ptr), @intCast(output.len), @intCast(offset)));
    }

    fn writeFile(file: *vfs.sqlite3_file, input: []const u8, offset: u64) ResultCode {
        const write_fn = (methods(file) orelse return .io_error).xWrite orelse return .io_error;
        if (input.len > std.math.maxInt(c_int) or offset > std.math.maxInt(i64)) return .full;
        return ResultCode.fromC(write_fn(file, @ptrCast(input.ptr), @intCast(input.len), @intCast(offset)));
    }

    fn fileSize(file: *vfs.sqlite3_file, output: *u64) ResultCode {
        const size_fn = (methods(file) orelse return .io_error).xFileSize orelse return .io_error;
        var size: i64 = 0;
        const rc = ResultCode.fromC(size_fn(file, &size));
        if (rc != .ok) return rc;
        if (size < 0) return .io_error;
        output.* = @intCast(size);
        return .ok;
    }

    fn truncateFile(file: *vfs.sqlite3_file, size: u64) ResultCode {
        const function = (methods(file) orelse return .io_error).xTruncate orelse return .io_error;
        return ResultCode.fromC(function(file, @intCast(size)));
    }

    fn syncFile(file: *vfs.sqlite3_file) ResultCode {
        const function = (methods(file) orelse return .io_error).xSync orelse return .io_error;
        return ResultCode.fromC(function(file, 2));
    }

    fn openFile(self: *Wal, create: bool) ResultCode {
        if (self.file != null) return .ok;
        const bytes = self.allocator.alignedAlloc(u8, .of(vfs.sqlite3_file), @intCast(self.abi_vfs.szOsFile)) catch
            return .no_memory;
        @memset(bytes, 0);
        const file: *vfs.sqlite3_file = @ptrCast(bytes.ptr);
        const open_fn = self.abi_vfs.xOpen orelse {
            self.allocator.free(bytes);
            return .cannot_open;
        };
        var output_flags: c_int = 0;
        var flags = (if (self.writable) vfs.OPEN_READWRITE else vfs.OPEN_READONLY) | vfs.OPEN_WAL;
        if (create) flags |= vfs.OPEN_CREATE;
        const rc = ResultCode.fromC(open_fn(self.abi_vfs, self.name.ptr, file, flags, &output_flags));
        if (rc != .ok) {
            self.allocator.free(bytes);
            return rc;
        }
        self.file_bytes = bytes;
        self.file = file;
        return .ok;
    }

    fn lock(self: *Wal, offset: c_int, flags: c_int) ResultCode {
        const function = (methods(self.database_file) orelse return .io_error).xShmLock orelse return .io_error;
        return ResultCode.fromC(function(self.database_file, offset, 1, flags));
    }

    fn barrier(self: *Wal) void {
        if (methods(self.database_file)) |io| if (io.xShmBarrier) |function| function(self.database_file);
    }

    fn getU32(bytes: []const u8, offset: usize) u32 {
        return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
            (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
    }

    fn putU32(bytes: []u8, offset: usize, value: u32) void {
        bytes[offset] = @truncate(value >> 24);
        bytes[offset + 1] = @truncate(value >> 16);
        bytes[offset + 2] = @truncate(value >> 8);
        bytes[offset + 3] = @truncate(value);
    }

    fn checksum(bytes: []const u8, native_order: bool, initial: Checksum) Checksum {
        std.debug.assert(bytes.len >= 8 and bytes.len % 8 == 0);
        var result = initial;
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 8) {
            const first = if (native_order)
                std.mem.readInt(u32, bytes[offset..][0..4], .little)
            else
                std.mem.readInt(u32, bytes[offset..][0..4], .big);
            const second = if (native_order)
                std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little)
            else
                std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .big);
            result.one +%= first +% result.two;
            result.two +%= second +% result.one;
        }
        return result;
    }

    fn frameOffset(self: *const Wal, number: u32) u64 {
        return header_size + @as(u64, number - 1) * (frame_header_size + self.page_size);
    }

    pub fn recover(self: *Wal) ResultCode {
        const file = self.file orelse return .ok;
        self.frames.clearRetainingCapacity();
        self.frame_count = 0;
        self.database_pages = 0;
        var size: u64 = 0;
        var rc = fileSize(file, &size);
        if (rc != .ok) return rc;
        if (size == 0) return self.publishIndex();
        if (size < header_size) return .corrupt;
        var header: [32]u8 = undefined;
        rc = readFile(file, &header, 0);
        if (rc != .ok) return rc;
        const magic = getU32(&header, 0);
        if ((magic & 0xffff_fffe) != wal_magic or getU32(&header, 4) != wal_version) return .corrupt;
        const encoded_page_size = getU32(&header, 8);
        const parsed_page_size: u32 = if (encoded_page_size == 1) 65_536 else encoded_page_size;
        if (parsed_page_size != self.page_size) return .corrupt;
        const native_order = (magic & 1) == 0;
        const header_checksum = checksum(header[0..24], native_order, .{});
        if (header_checksum.one != getU32(&header, 24) or header_checksum.two != getU32(&header, 28)) return .corrupt;
        self.salt = .{ getU32(&header, 16), getU32(&header, 20) };
        self.header_checksum = header_checksum;
        var running = header_checksum;
        var committed_checksum = header_checksum;
        var all = std.ArrayList(Frame).empty;
        defer all.deinit(self.allocator);
        const data = self.allocator.alloc(u8, self.page_size) catch return .no_memory;
        defer self.allocator.free(data);
        var number: u32 = 1;
        var last_commit: u32 = 0;
        const frame_bytes: u64 = frame_header_size + self.page_size;
        while (header_size + @as(u64, number) * frame_bytes <= size) : (number += 1) {
            var frame_header: [24]u8 = undefined;
            const offset = self.frameOffset(number);
            rc = readFile(file, &frame_header, offset);
            if (rc != .ok) break;
            rc = readFile(file, data, offset + frame_header_size);
            if (rc != .ok) break;
            if (getU32(&frame_header, 8) != self.salt[0] or getU32(&frame_header, 12) != self.salt[1]) break;
            running = checksum(frame_header[0..8], native_order, running);
            running = checksum(data, native_order, running);
            if (running.one != getU32(&frame_header, 16) or running.two != getU32(&frame_header, 20)) break;
            const page_number = getU32(&frame_header, 0);
            const db_pages = getU32(&frame_header, 4);
            if (page_number == 0) break;
            all.append(self.allocator, .{ .number = number, .page_number = page_number, .database_pages = db_pages, .offset = offset }) catch return .no_memory;
            if (db_pages != 0) {
                last_commit = number;
                self.database_pages = db_pages;
                committed_checksum = running;
            }
        }
        self.frame_count = last_commit;
        self.frame_checksum = committed_checksum;
        for (all.items) |frame| {
            if (frame.number > last_commit) break;
            self.frames.put(frame.page_number, frame) catch return .no_memory;
        }
        return self.publishIndex();
    }

    pub fn setEventHook(self: *Wal, hook: ?EventHook, context: ?*anyopaque) void {
        self.event_hook = hook;
        self.event_context = context;
    }

    fn emit(self: *Wal, event: Event) ResultCode {
        const hook = self.event_hook orelse return .ok;
        return if (hook(self.event_context, event)) .ok else .interrupt;
    }

    fn publishIndex(self: *Wal) ResultCode {
        if (!self.publish_native_index) {
            const external_io = methods(self.database_file) orelse return .io_error;
            const external_map = external_io.xShmMap orelse return .io_error;
            var external_pointer: ?*volatile anyopaque = null;
            const external_rc = ResultCode.fromC(external_map(self.database_file, 0, vfs.SHM_REGION_SIZE, 1, &external_pointer));
            if (external_rc != .ok) return external_rc;
            self.barrier();
            return self.emit(.index_publish);
        }
        const io = methods(self.database_file) orelse return .io_error;
        const map_fn = io.xShmMap orelse return .io_error;
        var pointer: ?*volatile anyopaque = null;
        const rc = ResultCode.fromC(map_fn(self.database_file, 0, vfs.SHM_REGION_SIZE, 1, &pointer));
        if (rc != .ok) return rc;
        const raw = pointer orelse return .io_error;
        const bytes: [*]volatile u8 = @ptrCast(raw);
        const values = [_]u32{ 0x5a574958, self.frame_count, self.database_pages, self.salt[0], self.salt[1], self.frame_checksum.one, self.frame_checksum.two };
        for (values, 0..) |value, index| {
            bytes[index * 4] = @truncate(value >> 24);
            bytes[index * 4 + 1] = @truncate(value >> 16);
            bytes[index * 4 + 2] = @truncate(value >> 8);
            bytes[index * 4 + 3] = @truncate(value);
        }
        self.barrier();
        return self.emit(.index_publish);
    }

    pub fn readPage(self: *Wal, page_number: u32, output: []u8) ReadOutcome {
        const frame = self.frames.get(page_number) orelse return .{ .result = .ok };
        if (output.len != self.page_size) return .{ .result = .misuse };
        const rc = readFile(self.file orelse return .{ .result = .corrupt }, output, frame.offset + frame_header_size);
        return .{ .result = rc, .found = rc == .ok };
    }

    pub fn beginWrite(self: *Wal) ResultCode {
        if (!self.writable) return .read_only;
        if (self.write_locked) return .ok;
        const rc = self.lock(write_lock, vfs.SHM_LOCK | vfs.SHM_EXCLUSIVE);
        if (rc == .ok) self.write_locked = true;
        return rc;
    }

    pub fn endWrite(self: *Wal) ResultCode {
        if (!self.write_locked) return .ok;
        const rc = self.lock(write_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
        if (rc == .ok) self.write_locked = false;
        return rc;
    }

    fn writeHeader(self: *Wal) ResultCode {
        var header: [32]u8 = .{0} ** 32;
        putU32(&header, 0, wal_magic);
        putU32(&header, 4, wal_version);
        putU32(&header, 8, if (self.page_size == 65_536) 1 else self.page_size);
        putU32(&header, 12, 0);
        var random: [8]u8 = .{ 0xa5, 0x5a, 0xc3, 0x3c, 0x17, 0xe9, 0x42, 0x81 };
        if (self.abi_vfs.xRandomness) |function| if (function(self.abi_vfs, 8, &random) < 8) return .io_error;
        self.salt = .{ std.mem.readInt(u32, random[0..4], .little), std.mem.readInt(u32, random[4..8], .little) };
        putU32(&header, 16, self.salt[0]);
        putU32(&header, 20, self.salt[1]);
        self.header_checksum = checksum(header[0..24], true, .{});
        self.frame_checksum = self.header_checksum;
        putU32(&header, 24, self.header_checksum.one);
        putU32(&header, 28, self.header_checksum.two);
        var rc = writeFile(self.file.?, &header, 0);
        if (rc == .ok) rc = self.emit(.header_write);
        if (rc == .ok) rc = syncFile(self.file.?);
        if (rc == .ok) rc = self.emit(.header_sync);
        return rc;
    }

    pub fn append(self: *Wal, pages: []*page_cache.Page, database_pages: u32) ResultCode {
        if (!self.write_locked or pages.len == 0 or database_pages == 0) return .misuse;
        var rc = self.openFile(true);
        if (rc != .ok) return rc;
        const committed_size = if (self.frame_count == 0) 0 else self.frameOffset(self.frame_count + 1);
        rc = truncateFile(self.file.?, committed_size);
        if (rc != .ok) return rc;
        if (self.frame_count == 0) {
            rc = self.writeHeader();
            if (rc != .ok) return rc;
        }
        var running = self.frame_checksum;
        var number = self.frame_count;
        for (pages, 0..) |page, index| {
            number += 1;
            var frame_header: [24]u8 = .{0} ** 24;
            putU32(&frame_header, 0, page.key);
            putU32(&frame_header, 4, if (index + 1 == pages.len) database_pages else 0);
            putU32(&frame_header, 8, self.salt[0]);
            putU32(&frame_header, 12, self.salt[1]);
            running = checksum(frame_header[0..8], true, running);
            running = checksum(page.data, true, running);
            putU32(&frame_header, 16, running.one);
            putU32(&frame_header, 20, running.two);
            const offset = self.frameOffset(number);
            rc = writeFile(self.file.?, &frame_header, offset);
            if (rc == .ok) rc = self.emit(.frame_header_write);
            if (rc == .ok) rc = writeFile(self.file.?, page.data, offset + frame_header_size);
            if (rc == .ok) rc = self.emit(.frame_page_write);
            if (rc != .ok) return rc;
            self.frames.put(page.key, .{ .number = number, .page_number = page.key, .database_pages = if (index + 1 == pages.len) database_pages else 0, .offset = offset }) catch return .no_memory;
        }
        rc = syncFile(self.file.?);
        if (rc == .ok) rc = self.emit(.wal_sync);
        if (rc != .ok) return rc;
        self.frame_count = number;
        self.database_pages = database_pages;
        self.frame_checksum = running;
        return self.publishIndex();
    }

    pub fn checkpoint(self: *Wal) CheckpointOutcome {
        if (self.frame_count == 0) return .{ .result = .ok };
        var rc = self.lock(checkpoint_lock, vfs.SHM_LOCK | vfs.SHM_EXCLUSIVE);
        if (rc != .ok) return .{ .result = rc, .frames = self.frame_count };
        self.checkpoint_locked = true;
        const exclusive_read = self.lock(read_lock, vfs.SHM_LOCK | vfs.SHM_EXCLUSIVE);
        if (exclusive_read != .ok) {
            _ = self.lock(checkpoint_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
            self.checkpoint_locked = false;
            return .{ .result = exclusive_read, .frames = self.frame_count };
        }
        const pages = self.allocator.alloc(u32, self.frames.count()) catch {
            _ = self.lock(read_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
            _ = self.lock(checkpoint_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
            self.checkpoint_locked = false;
            return .{ .result = .no_memory, .frames = self.frame_count };
        };
        defer self.allocator.free(pages);
        var iterator = self.frames.keyIterator();
        var count: usize = 0;
        while (iterator.next()) |key| {
            pages[count] = key.*;
            count += 1;
        }
        std.mem.sort(u32, pages, {}, std.sort.asc(u32));
        const buffer = self.allocator.alloc(u8, self.page_size) catch {
            _ = self.lock(read_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
            _ = self.lock(checkpoint_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
            self.checkpoint_locked = false;
            return .{ .result = .no_memory, .frames = self.frame_count };
        };
        defer self.allocator.free(buffer);
        var checkpointed: u32 = 0;
        for (pages) |page_number| {
            if (page_number > self.database_pages) continue;
            const read = self.readPage(page_number, buffer);
            if (read.result != .ok or !read.found) {
                rc = if (read.result != .ok) read.result else .corrupt;
                break;
            }
            rc = writeFile(self.database_file, buffer, @as(u64, page_number - 1) * self.page_size);
            if (rc == .ok) rc = self.emit(.checkpoint_database_write);
            if (rc != .ok) break;
            checkpointed += 1;
        }
        if (rc == .ok) rc = truncateFile(self.database_file, @as(u64, self.database_pages) * self.page_size);
        if (rc == .ok) rc = syncFile(self.database_file);
        if (rc == .ok) rc = self.emit(.checkpoint_database_sync);
        if (rc == .ok) {
            rc = truncateFile(self.file.?, 0);
            if (rc == .ok) rc = syncFile(self.file.?);
            if (rc == .ok) rc = self.emit(.wal_reset);
            if (rc == .ok) {
                self.frames.clearRetainingCapacity();
                self.frame_count = 0;
                self.database_pages = 0;
                self.frame_checksum = .{};
                _ = self.publishIndex();
            }
        }
        _ = self.lock(read_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
        _ = self.lock(checkpoint_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
        self.checkpoint_locked = false;
        return .{ .result = rc, .frames = self.frame_count, .checkpointed = checkpointed };
    }

    pub fn deinit(self: *Wal) void {
        _ = self.endWrite();
        if (self.checkpoint_locked) _ = self.lock(checkpoint_lock, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE);
        if (self.read_locked) {
            _ = self.lock(read_lock, vfs.SHM_UNLOCK | vfs.SHM_SHARED);
            self.read_locked = false;
        }
        if (self.file) |file| {
            if (methods(file)) |io| {
                if (io.xClose) |function| _ = function(file);
            }
            if (self.file_bytes) |bytes| self.allocator.free(bytes);
        }
        self.frames.deinit();
        self.file = null;
        self.file_bytes = null;
    }
};
