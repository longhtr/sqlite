//! Rollback-mode pager for the Phase 8 DELETE/FULL profile.
//!
//! Upstream fidelity sources: `src/pager.c` and `src/pager.h` at check-in
//! bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc.
//! This module owns only native Zig state. It calls VFS methods through the
//! public `sqlite3_vfs`/`sqlite3_file` ABI and uses the native page cache.
//! WAL, savepoints, persistent journals, and atomic-write optimizations remain
//! deliberately unreachable.

const std = @import("std");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const ResultCode = @import("result_code.zig").ResultCode;
const limits = @import("build_profile").limits;
pub const page_cache = @import("page_cache.zig");
pub const vfs = @import("vfs.zig");
pub const memory_journal = @import("memory_journal.zig");
pub const wal = @import("wal.zig");

pub const header_size = 100;
pub const minimum_page_size: u32 = limits.minimum_database_page_size;
pub const maximum_page_size: u32 = limits.max_page_size;
pub const default_page_size: u32 = limits.default_page_size;
pub const maximum_page_count: u32 = limits.max_page_count;
pub const pending_byte: u64 = 0x4000_0000;

pub const readonly_rollback = ResultCode.fromC(8 | (3 << 8));
pub const readonly_database_moved = ResultCode.fromC(8 | (4 << 8));
pub const ioerr_fstat = ResultCode.fromC(10 | (7 << 8));

pub const State = enum(u8) {
    open,
    reader,
    writer_locked,
    writer_cache_modified,
    writer_database_modified,
    writer_finished,
    error_,
    closed,
};

pub const Transition = struct { from: State, to: State };

/// Machine-readable transitions enabled by the Phase 8 rollback profile.
pub const phase8_transitions = [_]Transition{
    .{ .from = .open, .to = .reader },
    .{ .from = .reader, .to = .open },
    .{ .from = .reader, .to = .writer_locked },
    .{ .from = .writer_locked, .to = .writer_cache_modified },
    .{ .from = .writer_locked, .to = .writer_finished },
    .{ .from = .writer_cache_modified, .to = .writer_database_modified },
    .{ .from = .writer_cache_modified, .to = .writer_finished },
    .{ .from = .writer_database_modified, .to = .writer_finished },
    .{ .from = .writer_locked, .to = .reader },
    .{ .from = .writer_cache_modified, .to = .reader },
    .{ .from = .writer_database_modified, .to = .reader },
    .{ .from = .writer_finished, .to = .reader },
    .{ .from = .open, .to = .closed },
};

pub fn transitionAllowed(from: State, to: State) bool {
    if (from == to) return true;
    for (phase8_transitions) |transition| {
        if (transition.from == from and transition.to == to) return true;
    }
    return false;
}

pub const Header = struct {
    bytes: [header_size]u8,
    page_size: u32,
    reserved_bytes: u8,
    read_version: u8,
    write_version: u8,
};

pub const BusyHandler = *const fn (context: ?*anyopaque) bool;

pub const Stats = struct {
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    database_reads: u64 = 0,
    database_writes: u64 = 0,
    cache_spills: u64 = 0,
};

pub const OpenOptions = struct {
    extra_size: usize = 16,
    max_cached_pages: usize = 2_000,
    writable: bool = false,
    wal_external_index: bool = false,
    journal_spill_threshold: i64 = 0,
};

pub const CommitEvent = enum {
    journal_write,
    journal_initial_sync,
    journal_header_write,
    journal_final_sync,
    database_write,
    database_sync,
    journal_delete,
};
pub const CommitHook = *const fn (context: ?*anyopaque, event: CommitEvent) bool;

pub const OpenOutcome = struct {
    result: ResultCode,
    pager: ?Pager = null,
};

pub const PageOutcome = struct {
    result: ResultCode,
    page: ?*page_cache.Page = null,
};

const AlignedFileBytes = []align(@alignOf(vfs.sqlite3_file)) u8;

const SavepointPage = struct { number: u32, data: []u8 };
const Savepoint = struct {
    database_pages: u32,
    pages: std.ArrayList(SavepointPage) = .empty,

    fn deinit(self: *Savepoint, allocator: std.mem.Allocator) void {
        for (self.pages.items) |page| allocator.free(page.data);
        self.pages.deinit(allocator);
    }
};

pub const Pager = struct {
    allocator: std.mem.Allocator,
    abi_vfs: *vfs.sqlite3_vfs,
    file_bytes: AlignedFileBytes,
    file: *vfs.sqlite3_file,
    filename: [:0]u8,
    journal_name: [:0]u8,
    wal_name: [:0]u8,
    cache: *page_cache.Cache,
    state: State = .open,
    page_size: u32 = default_page_size,
    reserved_bytes: u8 = 0,
    database_pages: u32 = 0,
    maximum_pages: u32 = maximum_page_count,
    read_only: bool = true,
    has_held_shared_lock: bool = false,
    configured: bool = false,
    file_version: [16]u8 = .{0} ** 16,
    stats: Stats = .{},
    busy_handler: ?BusyHandler = null,
    busy_context: ?*anyopaque = null,
    busy_handler_hint: [2]?*anyopaque = .{ null, null },
    journal: ?memory_journal.Journal = null,
    journal_spill_threshold: i64 = 0,
    journaled_pages: ?[]bool = null,
    journal_offset: u64 = 0,
    journal_header: u64 = 0,
    journal_records: u32 = 0,
    journal_checksum_seed: u32 = 0,
    journal_sector_size: u32 = 4096,
    sector_size_known: bool = false,
    original_database_pages: u32 = 0,
    commit_hook: ?CommitHook = null,
    commit_context: ?*anyopaque = null,
    temp_page: []u8 = &.{},
    wal_mode: bool = false,
    wal_state: ?wal.Wal = null,
    wal_external_index: bool = false,
    savepoints: std.ArrayList(Savepoint) = .empty,

    /// Upstream: sqlite3PagerOpen + sqlite3PagerReadFileheader and the
    /// immediate B-tree header checks that select Pager.pageSize.
    ///
    /// Ownership: on success Pager owns its file allocation, filenames, and
    /// cache. On failure all acquired resources are released before return.
    /// The supplied public VFS table remains borrowed and must outlive Pager.
    pub fn open(
        allocator: std.mem.Allocator,
        abi_vfs: *vfs.sqlite3_vfs,
        supplied_name: []const u8,
        options: OpenOptions,
    ) OpenOutcome {
        if (abi_vfs.iVersion < 1 or abi_vfs.szOsFile < @sizeOf(vfs.sqlite3_file) or
            abi_vfs.mxPathname <= 0 or abi_vfs.xOpen == null or abi_vfs.xFullPathname == null)
        {
            return .{ .result = .cannot_open };
        }
        if (options.extra_size < 8 or options.extra_size >= 1_000) {
            return .{ .result = .misuse };
        }

        const input_name = allocator.dupeZ(u8, supplied_name) catch
            return .{ .result = .no_memory };
        defer allocator.free(input_name);

        const path_capacity: usize = @intCast(abi_vfs.mxPathname + 1);
        const path_buffer = allocator.allocSentinel(u8, path_capacity, 0) catch
            return .{ .result = .no_memory };
        defer allocator.free(path_buffer);
        @memset(path_buffer, 0);
        const full_rc = vfs.osFullPathname(abi_vfs, input_name.ptr, path_buffer[0..path_capacity]);
        if (full_rc != vfs.OK) return .{ .result = ResultCode.fromC(full_rc) };
        const path_length = std.mem.indexOfScalar(u8, path_buffer[0..path_capacity], 0) orelse
            return .{ .result = .cannot_open };
        if (path_length + 8 > @as(usize, @intCast(abi_vfs.mxPathname))) {
            return .{ .result = .cannot_open };
        }

        const filename = allocator.dupeZ(u8, path_buffer[0..path_length]) catch
            return .{ .result = .no_memory };
        const journal_name = std.fmt.allocPrintSentinel(allocator, "{s}-journal", .{filename}, 0) catch {
            allocator.free(filename);
            return .{ .result = .no_memory };
        };
        const wal_name = std.fmt.allocPrintSentinel(allocator, "{s}-wal", .{filename}, 0) catch {
            allocator.free(journal_name);
            allocator.free(filename);
            return .{ .result = .no_memory };
        };

        const file_bytes = allocator.alignedAlloc(
            u8,
            .of(vfs.sqlite3_file),
            @intCast(abi_vfs.szOsFile),
        ) catch {
            allocator.free(wal_name);
            allocator.free(journal_name);
            allocator.free(filename);
            return .{ .result = .no_memory };
        };
        @memset(file_bytes, 0);
        const file: *vfs.sqlite3_file = @ptrCast(file_bytes.ptr);
        var output_flags: c_int = 0;
        const database_open_flags = if (options.writable)
            vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB
        else
            vfs.OPEN_READONLY | vfs.OPEN_MAIN_DB;
        const open_rc = vfs.osOpen(abi_vfs, filename.ptr, file, database_open_flags, &output_flags);
        if (open_rc != vfs.OK) {
            allocator.free(file_bytes);
            allocator.free(wal_name);
            allocator.free(journal_name);
            allocator.free(filename);
            return .{ .result = ResultCode.fromC(open_rc) };
        }
        if (file.pMethods == null) {
            allocator.free(file_bytes);
            allocator.free(wal_name);
            allocator.free(journal_name);
            allocator.free(filename);
            return .{ .result = .cannot_open };
        }

        const cache = page_cache.Cache.create(
            allocator,
            default_page_size,
            options.extra_size,
            true,
            options.max_cached_pages,
            page_cache.activeProcessLifecycle(),
        ) orelse {
            if (file.pMethods) |methods| {
                if (methods.xClose) |close_fn| _ = close_fn(file);
            }
            allocator.free(file_bytes);
            allocator.free(wal_name);
            allocator.free(journal_name);
            allocator.free(filename);
            return .{ .result = .no_memory };
        };

        var pager = Pager{
            .allocator = allocator,
            .abi_vfs = abi_vfs,
            .file_bytes = file_bytes,
            .file = file,
            .filename = filename,
            .journal_name = journal_name,
            .wal_name = wal_name,
            .cache = cache,
            .read_only = !options.writable,
            .wal_external_index = options.wal_external_index,
            .journal_spill_threshold = options.journal_spill_threshold,
        };
        const configure_rc = pager.readAndConfigureHeader();
        if (configure_rc != .ok) {
            pager.deinitAfterOpenFailure();
            return .{ .result = configure_rc };
        }
        pager.temp_page = allocator.alloc(u8, pager.page_size) catch {
            pager.deinitAfterOpenFailure();
            return .{ .result = .no_memory };
        };
        return .{ .result = .ok, .pager = pager };
    }

    fn ioMethods(self: *const Pager) ?*const vfs.sqlite3_io_methods {
        return self.file.pMethods;
    }

    fn readAt(self: *Pager, output: []u8, offset: u64) ResultCode {
        const methods = self.ioMethods() orelse return .io_error;
        const read_fn = methods.xRead orelse return .io_error;
        if (offset > std.math.maxInt(i64) or output.len > std.math.maxInt(c_int)) return .full;
        return ResultCode.fromC(read_fn(
            self.file,
            @ptrCast(output.ptr),
            @intCast(output.len),
            @intCast(offset),
        ));
    }

    fn fileSize(self: *Pager, output: *u64) ResultCode {
        const methods = self.ioMethods() orelse return .io_error;
        const size_fn = methods.xFileSize orelse return ioerr_fstat;
        var size: i64 = 0;
        const rc = ResultCode.fromC(size_fn(self.file, &size));
        if (rc != .ok) return rc;
        if (size < 0) return ioerr_fstat;
        output.* = @intCast(size);
        return .ok;
    }

    fn readFromFile(file: *vfs.sqlite3_file, output: []u8, offset: u64) ResultCode {
        const methods = file.pMethods orelse return .io_error;
        const read_fn = methods.xRead orelse return .io_error;
        if (offset > std.math.maxInt(i64) or output.len > std.math.maxInt(c_int)) return .full;
        return ResultCode.fromC(read_fn(file, @ptrCast(output.ptr), @intCast(output.len), @intCast(offset)));
    }

    fn writeToFile(file: *vfs.sqlite3_file, input: []const u8, offset: u64) ResultCode {
        const methods = file.pMethods orelse return .io_error;
        const write_fn = methods.xWrite orelse return .io_error;
        if (offset > std.math.maxInt(i64) or input.len > std.math.maxInt(c_int)) return .full;
        return ResultCode.fromC(write_fn(file, @ptrCast(input.ptr), @intCast(input.len), @intCast(offset)));
    }

    fn syncFile(file: *vfs.sqlite3_file) ResultCode {
        const methods = file.pMethods orelse return .io_error;
        const sync_fn = methods.xSync orelse return .io_error;
        return ResultCode.fromC(sync_fn(file, 2));
    }

    fn truncateFile(file: *vfs.sqlite3_file, size: u64) ResultCode {
        const methods = file.pMethods orelse return .io_error;
        const truncate_fn = methods.xTruncate orelse return .io_error;
        if (size > std.math.maxInt(i64)) return .full;
        return ResultCode.fromC(truncate_fn(file, @intCast(size)));
    }

    fn putU32(output: []u8, offset: usize, value: u32) void {
        output[offset] = @truncate(value >> 24);
        output[offset + 1] = @truncate(value >> 16);
        output[offset + 2] = @truncate(value >> 8);
        output[offset + 3] = @truncate(value);
    }

    fn getU32(input: []const u8, offset: usize) u32 {
        return (@as(u32, input[offset]) << 24) | (@as(u32, input[offset + 1]) << 16) |
            (@as(u32, input[offset + 2]) << 8) | input[offset + 3];
    }

    /// Upstream: sqlite3PagerReadFileheader. Short reads are normalized to
    /// success with the unread suffix left zero-filled.
    pub fn readFileHeader(self: *Pager, output: []u8) ResultCode {
        @memset(output, 0);
        const rc = self.readAt(output, 0);
        return if (rc.toC() == vfs.IOERR_SHORT_READ) .ok else rc;
    }

    fn validPageSize(value: u32) bool {
        return value >= minimum_page_size and value <= maximum_page_size and
            std.math.isPowerOfTwo(value);
    }

    fn parseHeader(bytes: [header_size]u8) ?Header {
        if (!std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) return null;
        const encoded = (@as(u16, bytes[16]) << 8) | bytes[17];
        const page_size: u32 = if (encoded == 1) 65_536 else encoded;
        if (!validPageSize(page_size)) return null;
        if ((bytes[18] != 1 and bytes[18] != 2) or
            (bytes[19] != 1 and bytes[19] != 2)) return null;
        if (bytes[21] != 64 or bytes[22] != 32 or bytes[23] != 32) return null;
        if (@as(u32, bytes[20]) >= page_size or page_size - bytes[20] < 480) return null;
        return .{
            .bytes = bytes,
            .page_size = page_size,
            .reserved_bytes = bytes[20],
            .read_version = bytes[19],
            .write_version = bytes[18],
        };
    }

    fn readAndConfigureHeader(self: *Pager) ResultCode {
        var size: u64 = 0;
        const size_rc = self.fileSize(&size);
        if (size_rc != .ok) return size_rc;
        if (size == 0) {
            self.configured = true;
            return .ok;
        }
        if (size < header_size) return .not_a_database;
        var bytes: [header_size]u8 = undefined;
        const read_rc = self.readFileHeader(&bytes);
        if (read_rc != .ok) return read_rc;
        const header = parseHeader(bytes) orelse return .not_a_database;
        const cache_rc = self.cache.setPageSize(header.page_size);
        if (cache_rc != .ok) return cacheResult(cache_rc);
        self.page_size = header.page_size;
        self.reserved_bytes = header.reserved_bytes;
        self.wal_mode = header.read_version == 2 or header.write_version == 2;
        self.configured = true;
        return .ok;
    }

    fn access(self: *Pager, name: [:0]const u8, output: *c_int) ResultCode {
        const access_fn = self.abi_vfs.xAccess orelse return .io_error;
        return ResultCode.fromC(access_fn(
            self.abi_vfs,
            name.ptr,
            vfs.ACCESS_EXISTS,
            output,
        ));
    }

    fn journalChecksum(self: *const Pager, data: []const u8) u32 {
        var checksum = self.journal_checksum_seed;
        var index: isize = @as(isize, @intCast(self.page_size)) - 200;
        while (index > 0) : (index -= 200) checksum +%= data[@intCast(index)];
        return checksum;
    }

    /// Source `databaseIsUnmoved()`: ask the VFS whether a nonempty database
    /// has been renamed or unlinked, preserving the historical NOTFOUND-as-
    /// unchanged fallback.
    pub fn databaseIsUnmoved(self: *Pager) ResultCode {
        if (self.database_pages == 0) return .ok;
        var moved: c_int = 0;
        const rc = ResultCode.fromC(vfs.osFileControl(self.file, vfs.FCNTL_HAS_MOVED, &moved));
        if (rc == .not_found) return .ok;
        if (rc != .ok) return rc;
        return if (moved != 0) readonly_database_moved else .ok;
    }

    fn openJournalFile(self: *Pager, truncate_existing: bool) ResultCode {
        if (self.journal != null) return .ok;
        const unmoved = self.databaseIsUnmoved();
        if (unmoved != .ok) return unmoved;
        const opened = memory_journal.Journal.open(
            self.allocator,
            self.abi_vfs,
            self.journal_name.ptr,
            vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_JOURNAL,
            self.journal_spill_threshold,
        );
        const rc = ResultCode.fromC(opened.result);
        if (rc != .ok) return rc;
        self.journal = opened.journal;
        if (truncate_existing) {
            const truncate_rc = ResultCode.fromC(self.journal.?.truncate(0));
            if (truncate_rc != .ok) {
                _ = self.closeJournalFile(false);
                return truncate_rc;
            }
        }
        return .ok;
    }

    fn closeJournalFile(self: *Pager, delete_file: bool) ResultCode {
        var rc: ResultCode = .ok;
        if (self.journal) |*journal| {
            rc = ResultCode.fromC(journal.close());
            self.journal = null;
        }
        if (delete_file and rc == .ok) {
            const delete_fn = self.abi_vfs.xDelete orelse return .io_error;
            rc = ResultCode.fromC(delete_fn(self.abi_vfs, self.journal_name.ptr, 0));
            if (rc == .ok and !self.emitCommitEvent(.journal_delete)) return .interrupt;
        }
        return rc;
    }

    fn clearSavepoints(self: *Pager) void {
        for (self.savepoints.items) |*savepoint| {
            savepoint.deinit(self.allocator);
        }
        self.savepoints.clearRetainingCapacity();
    }

    fn clearTransaction(self: *Pager) void {
        self.clearSavepoints();
        if (self.journaled_pages) |pages| self.allocator.free(pages);
        self.journaled_pages = null;
        self.journal_offset = 0;
        self.journal_header = 0;
        self.journal_records = 0;
        self.journal_checksum_seed = 0;
        self.original_database_pages = 0;
    }

    fn emitCommitEvent(self: *Pager, event: CommitEvent) bool {
        const hook = self.commit_hook orelse return true;
        return hook(self.commit_context, event);
    }

    pub fn setCommitHook(self: *Pager, hook: ?CommitHook, context: ?*anyopaque) void {
        self.commit_hook = hook;
        self.commit_context = context;
    }

    /// Source `sqlite3PagerJrnlFile()`: return an open WAL handle in WAL mode,
    /// otherwise the open rollback-journal handle.
    pub fn journalFile(self: *Pager) ?*vfs.sqlite3_file {
        if (self.wal_state) |*state| {
            if (state.file) |file| return file;
        }
        return if (self.journal) |*journal| journal.abiFile() else null;
    }

    /// Source `sqlite3PagerVfs()`: return the borrowed VFS owner.
    pub fn filesystem(self: *Pager) *vfs.sqlite3_vfs {
        return self.abi_vfs;
    }

    /// Source `sqlite3PagerFile()`: return the borrowed database file handle.
    pub fn databaseFile(self: *Pager) *vfs.sqlite3_file {
        return self.file;
    }

    /// Source `sqlite3PagerJournalname()`: return the Pager-owned rollback
    /// journal pathname.
    pub fn journalName(self: *const Pager) [:0]const u8 {
        return self.journal_name;
    }

    /// Source `setSectorSize()`: normalize the VFS device sector size once per
    /// pager before either large-sector journaling or a journal header write.
    fn refreshSectorSize(self: *Pager) ResultCode {
        if (self.sector_size_known) return .ok;
        const methods = self.ioMethods() orelse return .io_error;
        const raw_sector = if (methods.xSectorSize) |sector_size| sector_size(self.file) else 512;
        var sector: u32 = if (raw_sector >= 32) @intCast(raw_sector) else 512;
        if (sector > 65_536 or !std.math.isPowerOfTwo(sector)) sector = 4096;
        self.journal_sector_size = sector;
        self.sector_size_known = true;
        return .ok;
    }

    fn writeInitialJournalHeader(self: *Pager) ResultCode {
        const journal = if (self.journal) |*value| value else return .misuse;
        const sector_rc = self.refreshSectorSize();
        if (sector_rc != .ok) return sector_rc;
        const sector = self.journal_sector_size;
        const header = self.allocator.alloc(u8, sector) catch return .no_memory;
        defer self.allocator.free(header);
        @memset(header, 0);
        var random: [4]u8 = .{ 0xa5, 0x5a, 0xc3, 0x3c };
        if (vfs.osRandomness(self.abi_vfs, &random) < random.len) return .io_error;
        self.journal_checksum_seed = @as(u32, random[0]) |
            (@as(u32, random[1]) << 8) | (@as(u32, random[2]) << 16) |
            (@as(u32, random[3]) << 24);
        putU32(header, 12, self.journal_checksum_seed);
        putU32(header, 16, self.original_database_pages);
        putU32(header, 20, sector);
        putU32(header, 24, self.page_size);
        const rc = ResultCode.fromC(journal.write(header, 0));
        if (rc != .ok) return rc;
        self.journal_offset = sector;
        return .ok;
    }

    fn playbackJournal(self: *Pager, source: *memory_journal.Journal, write_database: bool) ResultCode {
        var header: [28]u8 = undefined;
        var rc = ResultCode.fromC(source.read(&header, 0));
        if (rc != .ok) return if (rc.toC() == vfs.IOERR_SHORT_READ) .corrupt else rc;
        const magic = [_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };
        if (!std.mem.eql(u8, header[0..8], &magic)) return .corrupt;
        var record_count = getU32(&header, 8);
        self.journal_checksum_seed = getU32(&header, 12);
        const original_pages = getU32(&header, 16);
        const sector_size = getU32(&header, 20);
        const journal_page_size = getU32(&header, 24);
        if (journal_page_size != self.page_size or sector_size < 32 or sector_size > 65_536 or
            !std.math.isPowerOfTwo(sector_size) or original_pages > maximum_page_count)
            return .corrupt;
        var journal_size: i64 = 0;
        rc = ResultCode.fromC(source.fileSize(&journal_size));
        if (rc != .ok) return rc;
        if (journal_size < 0 or @as(u64, @intCast(journal_size)) < sector_size) return .corrupt;
        const record_size: u64 = self.page_size + 8;
        const available = (@as(u64, @intCast(journal_size)) - sector_size) / record_size;
        if (record_count == 0xffff_ffff) record_count = @intCast(@min(available, maximum_page_count));
        if (record_count > available) return .corrupt;
        if (self.temp_page.len != self.page_size) return .no_memory;
        const data = self.temp_page;
        var offset: u64 = sector_size;
        for (0..record_count) |_| {
            var number_bytes: [4]u8 = undefined;
            rc = ResultCode.fromC(source.read(&number_bytes, offset));
            if (rc != .ok) return rc;
            const page_number = getU32(&number_bytes, 0);
            if (page_number == 0 or page_number == @as(u32, @intCast(pending_byte / self.page_size + 1))) return .corrupt;
            rc = ResultCode.fromC(source.read(data, offset + 4));
            if (rc != .ok) return rc;
            var checksum_bytes: [4]u8 = undefined;
            rc = ResultCode.fromC(source.read(&checksum_bytes, offset + 4 + self.page_size));
            if (rc != .ok) return rc;
            if (getU32(&checksum_bytes, 0) != self.journalChecksum(data)) return .corrupt;
            if (page_number <= original_pages) {
                if (write_database) {
                    const database_offset = std.math.mul(u64, page_number - 1, self.page_size) catch return .full;
                    rc = writeToFile(self.file, data, database_offset);
                    if (rc != .ok) return rc;
                    self.stats.database_writes += 1;
                }
                if (self.cache.pages.get(page_number)) |cached| {
                    @memcpy(cached.data, data);
                    cached.extra[0] = 1;
                    self.cache.makeClean(cached);
                }
            }
            offset += record_size;
        }
        if (write_database) {
            const target_size = std.math.mul(u64, original_pages, self.page_size) catch return .full;
            rc = truncateFile(self.file, target_size);
            if (rc != .ok) return rc;
            rc = syncFile(self.file);
            if (rc != .ok) return rc;
        }
        self.database_pages = original_pages;
        self.cache.truncate(original_pages);
        self.cache.cleanAll();
        return .ok;
    }

    /// Source `pagerSyncHotJournal()`: make the rollback journal durable and
    /// publish its complete synchronized byte boundary before playback.
    fn syncHotJournal(self: *Pager) ResultCode {
        const journal = if (self.journal) |*value| value else return .misuse;
        var rc = ResultCode.fromC(journal.sync(0));
        if (rc != .ok) return rc;
        var size: i64 = 0;
        rc = ResultCode.fromC(journal.fileSize(&size));
        if (rc != .ok) return rc;
        if (size < 0) return ioerr_fstat;
        self.journal_header = @intCast(size);
        return .ok;
    }

    fn recoverHotJournal(self: *Pager) ResultCode {
        const methods = self.ioMethods() orelse return .io_error;
        const lock_fn = methods.xLock orelse return .io_error;
        var rc = ResultCode.fromC(lock_fn(self.file, vfs.LOCK_EXCLUSIVE));
        if (rc != .ok) return rc;
        rc = self.openJournalFile(false);
        if (rc == .ok) rc = self.syncHotJournal();
        if (rc == .ok) rc = self.playbackJournal(&self.journal.?, true);
        const close_rc = self.closeJournalFile(rc == .ok);
        if (rc == .ok) rc = close_rc;
        if (rc == .ok) {
            const unlock_fn = methods.xUnlock orelse return .io_error;
            rc = ResultCode.fromC(unlock_fn(self.file, vfs.LOCK_SHARED));
        }
        if (rc == .ok) self.cache.clear();
        return rc;
    }

    fn probeJournal(self: *Pager) struct { result: ResultCode, hot: bool } {
        var exists: c_int = 0;
        var rc = self.access(self.journal_name, &exists);
        if (rc != .ok or exists == 0) return .{ .result = rc, .hot = false };

        const methods = self.ioMethods() orelse return .{ .result = .io_error, .hot = false };
        const reserved_fn = methods.xCheckReservedLock orelse
            return .{ .result = .io_error, .hot = false };
        var reserved: c_int = 0;
        rc = ResultCode.fromC(reserved_fn(self.file, &reserved));
        if (rc != .ok or reserved != 0) return .{ .result = rc, .hot = false };

        var database_size: u64 = 0;
        rc = self.fileSize(&database_size);
        if (rc != .ok) return .{ .result = rc, .hot = false };
        // Upstream deletes a stale journal for a zero-byte database. Phase 6
        // forbids all mutation, so this bounded profile reports the same
        // read-only recovery requirement without deleting anything.
        if (database_size == 0) return .{ .result = readonly_rollback, .hot = true };

        const journal_bytes = self.allocator.alignedAlloc(
            u8,
            .of(vfs.sqlite3_file),
            @intCast(self.abi_vfs.szOsFile),
        ) catch return .{ .result = .no_memory, .hot = false };
        defer self.allocator.free(journal_bytes);
        @memset(journal_bytes, 0);
        const journal_file: *vfs.sqlite3_file = @ptrCast(journal_bytes.ptr);
        var output_flags: c_int = 0;
        rc = ResultCode.fromC(vfs.osOpen(
            self.abi_vfs,
            self.journal_name.ptr,
            journal_file,
            vfs.OPEN_READONLY | vfs.OPEN_MAIN_JOURNAL,
            &output_flags,
        ));
        if (rc.primary() == .cannot_open) return .{ .result = .ok, .hot = true };
        if (rc != .ok) return .{ .result = rc, .hot = false };
        defer if (journal_file.pMethods) |journal_methods| {
            if (journal_methods.xClose) |close_fn| _ = close_fn(journal_file);
        };
        const journal_methods = journal_file.pMethods orelse
            return .{ .result = .io_error, .hot = false };
        const read_fn = journal_methods.xRead orelse
            return .{ .result = .io_error, .hot = false };
        var first: u8 = 0;
        rc = ResultCode.fromC(read_fn(journal_file, &first, 1, 0));
        if (rc.toC() == vfs.IOERR_SHORT_READ) rc = .ok;
        return .{ .result = rc, .hot = rc == .ok and first != 0 };
    }

    pub fn isWalMode(self: *const Pager) bool {
        return self.wal_mode;
    }

    /// Source `sqlite3PagerSetBusyHandler()`: install the callback and its
    /// adjacent context, then expose that pair to custom VFS implementations
    /// through the best-effort SQLITE_FCNTL_BUSYHANDLER hint.
    pub fn setBusyHandler(self: *Pager, handler: ?BusyHandler, context: ?*anyopaque) void {
        self.busy_handler = handler;
        self.busy_context = context;
        self.busy_handler_hint = .{
            if (handler) |callback| @ptrCast(@constCast(callback)) else null,
            context,
        };
        _ = vfs.osFileControl(self.file, vfs.FCNTL_BUSYHANDLER, @ptrCast(&self.busy_handler_hint));
    }

    fn lockShared(self: *Pager) ResultCode {
        const methods = self.ioMethods() orelse return .io_error;
        const lock_fn = methods.xLock orelse return .io_error;
        while (true) {
            const rc = ResultCode.fromC(lock_fn(self.file, vfs.LOCK_SHARED));
            if (rc != .busy) return rc;
            const handler = self.busy_handler orelse return rc;
            if (!handler(self.busy_context)) return rc;
        }
    }

    fn failedBeginRead(self: *Pager, result: ResultCode) ResultCode {
        if (self.wal_state) |*state| state.deinit();
        self.wal_state = null;
        if (self.ioMethods()) |methods| {
            if (methods.xUnlock) |unlock_fn| _ = unlock_fn(self.file, vfs.LOCK_NONE);
        }
        self.state = .open;
        return result;
    }

    /// Upstream: sqlite3PagerSharedLock, restricted to rollback read-only
    /// operation. Hot rollback journals are recovered by writable pagers and
    /// committed WAL snapshots are indexed through the public shared-memory ABI.
    pub fn beginRead(self: *Pager) ResultCode {
        if (self.state == .reader) return .ok;
        if (self.state != .open or !self.configured) return .misuse;
        if (self.cache.refCount() != 0) return .busy;
        var rc = self.lockShared();
        if (rc != .ok) return rc;

        const journal = self.probeJournal();
        if (journal.result != .ok) return self.failedBeginRead(journal.result);
        if (journal.hot) {
            if (self.read_only) return self.failedBeginRead(readonly_rollback);
            rc = self.recoverHotJournal();
            if (rc != .ok) return self.failedBeginRead(rc);
        }

        var wal_exists: c_int = 0;
        rc = self.access(self.wal_name, &wal_exists);
        if (rc != .ok) return self.failedBeginRead(rc);
        if (wal_exists != 0 or self.wal_mode) {
            if (self.wal_state == null) {
                const opened = wal.Wal.open(
                    self.allocator,
                    self.abi_vfs,
                    self.file,
                    self.wal_name,
                    self.page_size,
                    !self.read_only,
                    wal_exists != 0,
                    !self.wal_external_index,
                );
                if (opened.result != .ok) return self.failedBeginRead(opened.result);
                self.wal_state = opened.wal.?;
            } else {
                rc = self.wal_state.?.recover();
                if (rc != .ok) return self.failedBeginRead(rc);
            }
            self.cache.clear();
        }

        if (self.has_held_shared_lock) {
            var version: [16]u8 = .{0} ** 16;
            rc = self.readAt(&version, 24);
            if (rc.toC() == vfs.IOERR_SHORT_READ) rc = .ok;
            if (rc != .ok) return self.failedBeginRead(rc);
            if (!std.mem.eql(u8, &version, &self.file_version)) self.cache.clear();
        }

        var size: u64 = 0;
        rc = self.fileSize(&size);
        if (rc != .ok) return self.failedBeginRead(rc);
        const rounded = std.math.add(u64, size, self.page_size - 1) catch
            return self.failedBeginRead(.full);
        const pages = rounded / self.page_size;
        if (pages > maximum_page_count) return self.failedBeginRead(.full);
        self.database_pages = @intCast(pages);
        if (self.wal_state) |*state| {
            if (state.database_pages != 0) self.database_pages = state.database_pages;
        }
        std.debug.assert(transitionAllowed(self.state, .reader));
        self.state = .reader;
        self.has_held_shared_lock = true;
        return .ok;
    }

    pub fn endRead(self: *Pager) ResultCode {
        if (self.state == .open) return .ok;
        if (self.state != .reader) return .misuse;
        if (self.cache.refCount() != 0) return .busy;
        const methods = self.ioMethods() orelse return .io_error;
        const unlock_fn = methods.xUnlock orelse return .io_error;
        const rc = ResultCode.fromC(unlock_fn(self.file, vfs.LOCK_NONE));
        if (rc != .ok) return rc;
        if (self.wal_state) |*state| state.deinit();
        self.wal_state = null;
        std.debug.assert(transitionAllowed(self.state, .open));
        self.state = .open;
        return .ok;
    }

    fn cacheResult(result: page_cache.Result) ResultCode {
        return switch (result) {
            .ok => .ok,
            .not_found => .not_found,
            .out_of_memory => .no_memory,
            .busy => .busy,
            .corrupt => .corrupt,
        };
    }

    /// Source `pagerStress()`: spill unreferenced rollback-journal pages when
    /// a soft cache fetch cannot allocate without exceeding its limit.
    fn pagerStress(context: ?*anyopaque, page: *page_cache.Page) page_cache.Result {
        const self: *Pager = @ptrCast(@alignCast(context orelse return .corrupt));
        const rc = self.flushUnreferencedDirty();
        if (rc == .ok and !page.flags.dirty) {
            self.stats.cache_spills += 1;
            return .ok;
        }
        return switch (rc) {
            .ok, .busy => .busy,
            .no_memory => .out_of_memory,
            .corrupt => .corrupt,
            else => .busy,
        };
    }

    fn hasReadTransaction(self: *const Pager) bool {
        return self.state == .reader or self.state == .writer_locked or
            self.state == .writer_cache_modified or self.state == .writer_database_modified;
    }

    pub fn getPage(self: *Pager, page_number: u32, no_content: bool) PageOutcome {
        if (!self.hasReadTransaction()) return .{ .result = .misuse };
        if (page_number == 0) return .{ .result = .corrupt };
        const locking_page: u32 = @intCast(pending_byte / self.page_size + 1);
        if (page_number == locking_page) return .{ .result = .corrupt };

        const was_cached = self.cache.pages.get(page_number) != null;
        const create_mode: page_cache.FetchMode = if (self.cache.isDirty()) .soft_create else .hard_create;
        var fetched = self.cache.fetch(page_number, create_mode, null);
        if (fetched.result == .busy) {
            fetched = self.cache.fetch(page_number, .hard_create, .{ .callback = pagerStress, .context = self });
        }
        if (fetched.result != .ok) return .{ .result = cacheResult(fetched.result) };
        const page = fetched.page.?;
        if (was_cached and page.extra[0] != 0 and !no_content) {
            self.stats.cache_hits += 1;
            return .{ .result = .ok, .page = page };
        }

        if (page_number > self.database_pages or no_content) {
            if (page_number > self.maximum_pages) {
                _ = self.cache.drop(page);
                return .{ .result = .full };
            }
            @memset(page.data, 0);
        } else {
            self.stats.cache_misses += 1;
            var found_in_wal = false;
            if (self.wal_state) |*state| {
                const read = state.readPage(page_number, page.data);
                if (read.result != .ok) {
                    _ = self.cache.drop(page);
                    return .{ .result = read.result };
                }
                found_in_wal = read.found;
            }
            if (!found_in_wal) {
                const offset = std.math.mul(u64, page_number - 1, self.page_size) catch {
                    _ = self.cache.drop(page);
                    return .{ .result = .full };
                };
                var rc = self.readAt(page.data, offset);
                if (rc.toC() == vfs.IOERR_SHORT_READ) rc = .ok;
                if (rc != .ok) {
                    _ = self.cache.drop(page);
                    return .{ .result = rc };
                }
                self.stats.database_reads += 1;
            }
        }
        page.extra[0] = 1;
        if (page_number == 1 and page.data.len >= 40) {
            @memcpy(&self.file_version, page.data[24..40]);
        }
        return .{ .result = .ok, .page = page };
    }

    pub fn lookup(self: *Pager, page_number: u32) ?*page_cache.Page {
        if (!self.hasReadTransaction() or page_number == 0) return null;
        return self.cache.fetch(page_number, .lookup, null).page;
    }

    pub fn reference(self: *Pager, page: *page_cache.Page) void {
        self.cache.reference(page);
    }

    pub fn release(self: *Pager, page: *page_cache.Page) ResultCode {
        return cacheResult(self.cache.release(page));
    }

    pub fn pageCount(self: *const Pager) u32 {
        return self.database_pages;
    }

    pub fn pageSize(self: *const Pager) u32 {
        return self.page_size;
    }

    /// Source `sqlite3PagerMaxPageCount()`: replace a positive maximum and
    /// always return the effective Pager page limit.
    pub fn maxPageCount(self: *Pager, requested: u32) u32 {
        if (requested != 0) self.maximum_pages = requested;
        return self.maximum_pages;
    }

    pub fn cacheReferences(self: *const Pager) usize {
        return self.cache.refCount();
    }

    pub fn cachePages(self: *const Pager) usize {
        return self.cache.pageCount();
    }

    /// Source `sqlite3PagerMemUsed()`: approximate the Pager and PCache bytes.
    /// Zig owns these allocations separately, so allocator object sizes replace
    /// the source's single sqlite3MallocSize(pPager) allocation measurement.
    pub fn memoryUsed(self: *const Pager) usize {
        const pointer_overhead = 5 * @sizeOf(*anyopaque);
        const per_page = std.math.add(usize, @as(usize, self.page_size), self.cache.extra_size) catch return std.math.maxInt(usize);
        const modeled_per_page = std.math.add(usize, per_page, @sizeOf(page_cache.Page) + pointer_overhead) catch return std.math.maxInt(usize);
        const cache_bytes = std.math.mul(usize, modeled_per_page, self.cache.pageCount()) catch return std.math.maxInt(usize);
        const pager_bytes = std.math.add(usize, @sizeOf(Pager), self.file_bytes.len) catch return std.math.maxInt(usize);
        const filename_bytes = std.math.add(usize, self.filename.len + 1, self.journal_name.len + 1) catch return std.math.maxInt(usize);
        const all_names = std.math.add(usize, filename_bytes, self.wal_name.len + 1) catch return std.math.maxInt(usize);
        const owner_bytes = std.math.add(usize, pager_bytes, @sizeOf(page_cache.Cache) + all_names) catch return std.math.maxInt(usize);
        const with_cache = std.math.add(usize, owner_bytes, cache_bytes) catch return std.math.maxInt(usize);
        return std.math.add(usize, with_cache, @as(usize, self.page_size)) catch std.math.maxInt(usize);
    }

    /// Source `sqlite3PagerSetCachesize()`: forward the signed cache
    /// configuration to the owned PCache.
    pub fn setCacheSize(self: *Pager, pages: i64) void {
        self.cache.setConfiguredCacheSize(pages);
    }

    /// Source `sqlite3PagerSetSpillsize()`: update or query the signed spill
    /// limit and return its effective PCache value.
    pub fn setSpillSize(self: *Pager, pages: i64) usize {
        return self.cache.setConfiguredSpillSize(pages);
    }

    /// Source `sqlite3PagerShrink()`: release as many unpinned clean cache
    /// pages as possible.
    pub fn shrinkCache(self: *Pager) usize {
        return self.cache.shrink();
    }

    fn lockForWrite(self: *Pager, target: c_int, invoke_busy: bool) ResultCode {
        const methods = self.ioMethods() orelse return .io_error;
        const lock_fn = methods.xLock orelse return .io_error;
        while (true) {
            const rc = ResultCode.fromC(lock_fn(self.file, target));
            if (rc != .busy or !invoke_busy) return rc;
            const handler = self.busy_handler orelse return rc;
            if (!handler(self.busy_context)) return rc;
        }
    }

    pub fn beginWrite(self: *Pager) ResultCode {
        if (self.read_only) return .read_only;
        if (self.state != .reader) return if (self.state == .writer_locked or
            self.state == .writer_cache_modified or self.state == .writer_database_modified) .ok else .misuse;
        const rc = if (self.wal_mode)
            if (self.wal_state) |*state| state.beginWrite() else .cannot_open
        else
            self.lockForWrite(vfs.LOCK_RESERVED, false);
        if (rc != .ok) return rc;
        self.original_database_pages = self.database_pages;
        std.debug.assert(transitionAllowed(self.state, .writer_locked));
        self.state = .writer_locked;
        return .ok;
    }

    fn beginJournal(self: *Pager) ResultCode {
        std.debug.assert(self.state == .writer_locked);
        const pages = self.allocator.alloc(bool, @as(usize, self.original_database_pages) + 1) catch
            return .no_memory;
        @memset(pages, false);
        self.journaled_pages = pages;
        var rc = self.openJournalFile(true);
        if (rc == .ok) rc = self.writeInitialJournalHeader();
        if (rc != .ok) {
            _ = self.closeJournalFile(true);
            const original_pages = self.original_database_pages;
            self.clearTransaction();
            self.original_database_pages = original_pages;
            return rc;
        }
        std.debug.assert(transitionAllowed(self.state, .writer_cache_modified));
        self.state = .writer_cache_modified;
        return .ok;
    }

    fn appendJournalRecord(self: *Pager, page: *page_cache.Page) ResultCode {
        const journal = if (self.journal) |*value| value else return .misuse;
        var number: [4]u8 = undefined;
        putU32(&number, 0, page.key);
        var rc = ResultCode.fromC(journal.write(&number, self.journal_offset));
        if (rc != .ok) return rc;
        rc = ResultCode.fromC(journal.write(page.data, self.journal_offset + 4));
        if (rc != .ok) return rc;
        var checksum: [4]u8 = undefined;
        putU32(&checksum, 0, self.journalChecksum(page.data));
        rc = ResultCode.fromC(journal.write(&checksum, self.journal_offset + 4 + self.page_size));
        if (rc != .ok) return rc;
        self.journal_offset += self.page_size + 8;
        self.journal_records += 1;
        self.journaled_pages.?[page.key] = true;
        if (!self.emitCommitEvent(.journal_write)) return .interrupt;
        return .ok;
    }

    fn captureSavepointPage(self: *Pager, savepoint: *Savepoint, page: *page_cache.Page) ResultCode {
        for (savepoint.pages.items) |snapshot| {
            if (snapshot.number == page.key) return .ok;
        }
        const data = self.allocator.dupe(u8, page.data) catch return .no_memory;
        savepoint.pages.append(self.allocator, .{ .number = page.key, .data = data }) catch {
            self.allocator.free(data);
            return .no_memory;
        };
        return .ok;
    }

    fn capturePageForSavepoints(self: *Pager, page: *page_cache.Page) ResultCode {
        for (self.savepoints.items) |*savepoint| {
            const rc = self.captureSavepointPage(savepoint, page);
            if (rc != .ok) return rc;
        }
        return .ok;
    }

    /// Source `pager_write()`: make one page writable and journal its prior
    /// image. Large-sector cohort handling belongs to `makeWritable()`.
    fn makeWritableSingle(self: *Pager, page: *page_cache.Page) ResultCode {
        if (self.read_only) return .read_only;
        if (self.state != .writer_locked and self.state != .writer_cache_modified and
            self.state != .writer_database_modified) return .misuse;
        if (self.cache.pages.get(page.key) != page or page.ref_count == 0) return .misuse;
        const savepoint_rc = self.capturePageForSavepoints(page);
        if (savepoint_rc != .ok) return savepoint_rc;
        if (page.flags.writeable) return .ok;
        if (self.wal_mode) {
            if (self.state == .writer_locked) self.state = .writer_cache_modified;
            self.cache.makeDirty(page);
            page.flags.writeable = true;
            self.database_pages = @max(self.database_pages, page.key);
            return .ok;
        }
        if (self.state == .writer_locked) {
            const begin_rc = self.beginJournal();
            if (begin_rc != .ok) return begin_rc;
        }
        if (page.key <= self.original_database_pages and !self.journaled_pages.?[page.key]) {
            page.flags.need_sync = true;
            const journal_rc = self.appendJournalRecord(page);
            if (journal_rc != .ok) return journal_rc;
        } else if (page.key > self.original_database_pages) {
            page.flags.need_sync = self.state != .writer_database_modified;
        }
        self.cache.makeDirty(page);
        page.flags.writeable = true;
        self.database_pages = @max(self.database_pages, page.key);
        return .ok;
    }

    /// Integrated source `pagerWriteLargeSector()`: journal every database
    /// page sharing the physical sector before exposing any as writable.
    fn makeWritableLargeSector(self: *Pager, target: *page_cache.Page) ResultCode {
        const pages_per_sector = self.journal_sector_size / self.page_size;
        std.debug.assert(pages_per_sector > 1 and std.math.isPowerOfTwo(pages_per_sector));
        const first = ((target.key - 1) & ~(pages_per_sector - 1)) + 1;
        const count = if (target.key > self.database_pages)
            target.key - first + 1
        else
            @min(pages_per_sector, self.database_pages + 1 - first);
        const locking_page: u32 = @intCast(pending_byte / self.page_size + 1);
        var need_sync = false;
        for (first..first + count) |number_value| {
            const number: u32 = @intCast(number_value);
            if (number == locking_page) continue;
            const already_journaled = self.journaled_pages != null and
                number < self.journaled_pages.?.len and self.journaled_pages.?[number];
            if (number == target.key or !already_journaled) {
                const fetched = self.getPage(number, false);
                if (fetched.result != .ok) return fetched.result;
                const cohort_page = fetched.page.?;
                const rc = self.makeWritableSingle(cohort_page);
                if (cohort_page.flags.need_sync) {
                    need_sync = true;
                }
                _ = self.release(cohort_page);
                if (rc != .ok) return rc;
            } else if (self.lookup(number)) |cohort_page| {
                if (cohort_page.flags.need_sync) {
                    need_sync = true;
                }
                _ = self.release(cohort_page);
            }
        }
        if (need_sync) {
            for (first..first + count) |number_value| {
                if (self.lookup(@intCast(number_value))) |cohort_page| {
                    cohort_page.flags.need_sync = true;
                    _ = self.release(cohort_page);
                }
            }
        }
        return .ok;
    }

    /// Source `sqlite3PagerWrite()` dispatches the ordinary and large-sector
    /// paths after honoring already-writable pages.
    pub fn makeWritable(self: *Pager, page: *page_cache.Page) ResultCode {
        if (page.flags.writeable and self.database_pages >= page.key) return .ok;
        if (!self.wal_mode) {
            const sector_rc = self.refreshSectorSize();
            if (sector_rc != .ok) return sector_rc;
            if (self.journal_sector_size > self.page_size) return self.makeWritableLargeSector(page);
        }
        return self.makeWritableSingle(page);
    }

    fn updateChangeCounter(self: *Pager) ResultCode {
        const fetched = self.getPage(1, false);
        if (fetched.result != .ok) return fetched.result;
        const page = fetched.page.?;
        defer _ = self.release(page);
        const rc = self.makeWritable(page);
        if (rc != .ok) return rc;
        const counter = getU32(page.data, 24) +% 1;
        putU32(page.data, 24, counter);
        putU32(page.data, 92, counter);
        putU32(page.data, 96, 3_053_004);
        return .ok;
    }

    fn syncJournalForCommit(self: *Pager) ResultCode {
        const journal = if (self.journal) |*value| value else return .misuse;
        var rc = self.lockForWrite(vfs.LOCK_EXCLUSIVE, true);
        if (rc != .ok) return rc;
        rc = ResultCode.fromC(journal.sync(2));
        if (rc != .ok) return rc;
        if (!self.emitCommitEvent(.journal_initial_sync)) return .interrupt;
        const magic = [_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };
        var header: [12]u8 = undefined;
        @memcpy(header[0..8], &magic);
        putU32(&header, 8, self.journal_records);
        rc = ResultCode.fromC(journal.write(&header, 0));
        if (rc != .ok) return rc;
        if (!self.emitCommitEvent(.journal_header_write)) return .interrupt;
        rc = ResultCode.fromC(journal.sync(2));
        if (rc != .ok) return rc;
        if (!self.emitCommitEvent(.journal_final_sync)) return .interrupt;
        self.cache.clearSyncFlags();
        std.debug.assert(transitionAllowed(self.state, .writer_database_modified));
        self.state = .writer_database_modified;
        return .ok;
    }

    /// Source `pagerWalFrames()`: trim pages beyond the committed image and
    /// forward an ascending no-allocation dirty chain to the WAL owner.
    fn writeWalFrames(self: *Pager, dirty_head: ?*page_cache.Page) ResultCode {
        var source = dirty_head;
        var first: ?*page_cache.Page = null;
        var tail: ?*page_cache.Page = null;
        var count: usize = 0;
        while (source) |page| {
            source = page.sort_next;
            if (page.key > self.database_pages) continue;
            page.sort_next = null;
            if (tail) |previous| {
                previous.sort_next = page;
            } else {
                first = page;
            }
            tail = page;
            count += 1;
        }
        if (first == null) return .corrupt;
        const rc = if (self.wal_state) |*state| state.append(first, self.database_pages) else .cannot_open;
        if (rc == .ok) {
            self.stats.database_writes += count;
        }
        return rc;
    }

    /// Source `pager_write_pagelist()`: write the sorted rollback-mode dirty
    /// chain directly, without allocating a temporary pointer array.
    fn writeDirtyPageList(self: *Pager, dirty_head: ?*page_cache.Page) ResultCode {
        var dirty = dirty_head;
        while (dirty) |page| : (dirty = page.sort_next) {
            if (page.key > self.database_pages or page.flags.dont_write) continue;
            const offset = std.math.mul(u64, page.key - 1, self.page_size) catch return .full;
            const rc = writeToFile(self.file, page.data, offset);
            if (rc != .ok) return rc;
            self.stats.database_writes += 1;
            if (!self.emitCommitEvent(.database_write)) return .interrupt;
        }
        return .ok;
    }

    pub fn commitPhaseOne(self: *Pager) ResultCode {
        if (self.state == .writer_locked) {
            self.state = .writer_finished;
            return .ok;
        }
        if (self.state != .writer_cache_modified) return .misuse;
        var rc = self.updateChangeCounter();
        if (rc != .ok) return rc;
        if (self.wal_mode) {
            rc = self.writeWalFrames(self.cache.dirtyListHead());
            if (rc != .ok) return rc;
            self.cache.cleanAll();
            std.debug.assert(transitionAllowed(self.state, .writer_finished));
            self.state = .writer_finished;
            return .ok;
        }
        rc = self.syncJournalForCommit();
        if (rc != .ok) return rc;
        rc = self.writeDirtyPageList(self.cache.dirtyListHead());
        if (rc != .ok) return rc;
        const image_size = std.math.mul(u64, self.database_pages, self.page_size) catch return .full;
        rc = truncateFile(self.file, image_size);
        if (rc != .ok) return rc;
        rc = syncFile(self.file);
        if (rc != .ok) return rc;
        if (!self.emitCommitEvent(.database_sync)) return .interrupt;
        std.debug.assert(transitionAllowed(self.state, .writer_finished));
        self.state = .writer_finished;
        return .ok;
    }

    pub fn commitPhaseTwo(self: *Pager) ResultCode {
        if (self.state != .writer_finished) return .misuse;
        var rc: ResultCode = .ok;
        if (self.wal_mode) {
            rc = if (self.wal_state) |*state| state.endWrite() else .cannot_open;
        } else if (self.journal != null) rc = self.closeJournalFile(true);
        if (rc != .ok) return rc;
        self.cache.cleanAll();
        self.clearTransaction();
        const methods = self.ioMethods() orelse return .io_error;
        const unlock_fn = methods.xUnlock orelse return .io_error;
        rc = ResultCode.fromC(unlock_fn(self.file, vfs.LOCK_SHARED));
        if (rc != .ok) return rc;
        std.debug.assert(transitionAllowed(self.state, .reader));
        self.state = .reader;
        return .ok;
    }

    pub fn commit(self: *Pager) ResultCode {
        const first = self.commitPhaseOne();
        if (first != .ok) return first;
        return self.commitPhaseTwo();
    }

    pub fn setWalEventHook(self: *Pager, hook: ?wal.EventHook, context: ?*anyopaque) ResultCode {
        if (self.wal_state) |*state| {
            state.setEventHook(hook, context);
            return .ok;
        }
        return .misuse;
    }

    pub fn flushUnreferencedDirty(self: *Pager) ResultCode {
        if (self.state != .writer_locked and self.state != .writer_cache_modified and self.state != .writer_database_modified) return .ok;
        if (self.wal_mode) return .busy;
        var rc = self.syncJournalForCommit();
        if (rc != .ok) return rc;
        var dirty = self.cache.dirtyListHead();
        while (dirty) |page| {
            dirty = page.sort_next;
            if (page.ref_count != 0 or page.flags.dont_write) continue;
            const offset = std.math.mul(u64, page.key - 1, self.page_size) catch return .full;
            rc = writeToFile(self.file, page.data, offset);
            if (rc != .ok) return rc;
            self.stats.database_writes += 1;
            self.cache.makeClean(page);
        }
        return .ok;
    }

    /// Source `sqlite3PagerCheckpoint()`: validate pager state, dispatch the
    /// requested WAL checkpoint mode, and invalidate pages after backfill.
    pub fn checkpointWalMode(self: *Pager, mode: wal.CheckpointMode) wal.CheckpointOutcome {
        if (!self.wal_mode or self.state != .reader) return .{ .result = .misuse };
        if (self.cache.refCount() != 0) return .{ .result = .busy };
        const outcome = if (self.wal_state) |*state| state.checkpointMode(mode) else wal.CheckpointOutcome{ .result = .cannot_open };
        if (outcome.result == .ok and outcome.checkpointed != 0) {
            self.cache.clear();
        }
        return outcome;
    }

    pub fn checkpointWal(self: *Pager) wal.CheckpointOutcome {
        return self.checkpointWalMode(.truncate);
    }

    /// Source `sqlite3PagerWalCallback()`: forward one-shot committed-frame
    /// consumption to the owned WAL handle, or return zero without one.
    pub fn takeWalCallbackFrame(self: *Pager) u32 {
        const state = if (self.wal_state) |*value| value else return 0;
        const frame = state.callback_frame;
        state.callback_frame = 0;
        return frame;
    }

    pub fn rollback(self: *Pager) ResultCode {
        if (self.state == .reader or self.state == .open) return .ok;
        if (self.state != .writer_locked and self.state != .writer_cache_modified and
            self.state != .writer_database_modified and self.state != .writer_finished) return .misuse;
        if (self.cache.refCount() != 0) return .busy;
        var rc: ResultCode = .ok;
        if (self.wal_mode) {
            self.cache.clear();
            self.database_pages = self.original_database_pages;
            rc = if (self.wal_state) |*state| state.endWrite() else .cannot_open;
        } else if (self.state == .writer_database_modified or self.state == .writer_finished) {
            if (self.journal == null) rc = self.openJournalFile(false);
            if (rc == .ok) rc = self.playbackJournal(&self.journal.?, true);
        } else {
            self.cache.clear();
            self.database_pages = self.original_database_pages;
        }
        const close_rc = if (self.wal_mode) ResultCode.ok else self.closeJournalFile(rc == .ok);
        if (rc == .ok) rc = close_rc;
        if (rc != .ok) return rc;
        self.cache.cleanAll();
        self.clearTransaction();
        const methods = self.ioMethods() orelse return .io_error;
        const unlock_fn = methods.xUnlock orelse return .io_error;
        rc = ResultCode.fromC(unlock_fn(self.file, vfs.LOCK_SHARED));
        if (rc != .ok) return rc;
        std.debug.assert(transitionAllowed(self.state, .reader));
        self.state = .reader;
        return .ok;
    }

    /// Source `pagerOpenSavepoint()`: extend the savepoint array and snapshot
    /// every page already dirty at each newly opened boundary.
    pub fn openSavepoints(self: *Pager, requested_count: usize) ResultCode {
        if (self.state != .writer_locked and self.state != .writer_cache_modified and self.state != .writer_database_modified) return .misuse;
        if (requested_count <= self.savepoints.items.len) return .ok;
        while (self.savepoints.items.len < requested_count) {
            var savepoint = Savepoint{ .database_pages = self.database_pages };
            var page = self.cache.dirtyListHead();
            while (page) |dirty| : (page = dirty.sort_next) {
                const rc = self.captureSavepointPage(&savepoint, dirty);
                if (rc != .ok) {
                    savepoint.deinit(self.allocator);
                    return rc;
                }
            }
            self.savepoints.append(self.allocator, savepoint) catch {
                savepoint.deinit(self.allocator);
                return .no_memory;
            };
        }
        return .ok;
    }

    pub fn rollbackSavepoint(self: *Pager, index: usize) ResultCode {
        if (index >= self.savepoints.items.len or self.cache.refCount() != 0) return .misuse;
        const savepoint = &self.savepoints.items[index];
        self.cache.truncate(savepoint.database_pages);
        for (savepoint.pages.items) |snapshot| {
            const fetched = self.cache.fetch(snapshot.number, .hard_create, null);
            if (fetched.result != .ok) return switch (fetched.result) {
                .out_of_memory => .no_memory,
                else => .corrupt,
            };
            const page = fetched.page.?;
            @memcpy(page.data, snapshot.data);
            self.cache.makeDirty(page);
            page.flags.writeable = true;
            _ = self.cache.release(page);
        }
        self.database_pages = savepoint.database_pages;
        var remove = self.savepoints.items.len;
        while (remove > index + 1) {
            remove -= 1;
            self.savepoints.items[remove].deinit(self.allocator);
        }
        self.savepoints.shrinkRetainingCapacity(index + 1);
        return .ok;
    }

    pub fn releaseSavepoint(self: *Pager, index: usize) ResultCode {
        if (index >= self.savepoints.items.len) return .misuse;
        var remove = self.savepoints.items.len;
        while (remove > index) {
            remove -= 1;
            self.savepoints.items[remove].deinit(self.allocator);
        }
        self.savepoints.shrinkRetainingCapacity(index);
        return .ok;
    }

    pub fn movePage(self: *Pager, page: *page_cache.Page, new_number: u32) ResultCode {
        _ = self;
        _ = page;
        _ = new_number;
        return .read_only;
    }

    /// Source `sqlite3PagerTruncateImage()`: record the smaller in-memory
    /// database image immediately before commit; phase one performs the
    /// physical file truncation after dirty-page writes.
    pub fn truncateImage(self: *Pager, pages: u32) ResultCode {
        if (self.read_only) return .read_only;
        if (pages > self.database_pages or
            (self.state != .writer_cache_modified and self.state != .writer_database_modified))
        {
            return .misuse;
        }
        self.database_pages = pages;
        return .ok;
    }

    /// Diagnostic process-death teardown. It never rolls back or deletes the
    /// journal and is used only after the VFS durability model has crashed.
    pub fn crashClose(self: *Pager) void {
        if (self.wal_state) |*state| state.deinit();
        self.wal_state = null;
        if (self.journal) |*journal| {
            _ = journal.close();
            self.journal = null;
        }
        if (self.file.pMethods) |methods| {
            if (methods.xClose) |close_fn| _ = close_fn(self.file);
        }
        self.clearTransaction();
        self.savepoints.deinit(self.allocator);
        self.cache.destroy();
        if (self.temp_page.len != 0) self.allocator.free(self.temp_page);
        self.allocator.free(self.file_bytes);
        self.allocator.free(self.filename);
        self.allocator.free(self.journal_name);
        self.allocator.free(self.wal_name);
        self.state = .closed;
    }

    pub fn close(self: *Pager) ResultCode {
        if (self.state == .closed) return .ok;
        if (self.cache.refCount() != 0) return .busy;
        if (self.state == .writer_locked or self.state == .writer_cache_modified or
            self.state == .writer_database_modified or self.state == .writer_finished)
        {
            const rollback_rc = self.rollback();
            if (rollback_rc != .ok) return rollback_rc;
        }
        if (self.state == .reader) {
            const end_rc = self.endRead();
            if (end_rc != .ok) return end_rc;
        }
        if (self.state != .open) return .misuse;
        const methods = self.ioMethods() orelse return .io_error;
        const close_fn = methods.xClose orelse return .io_error;
        const rc = ResultCode.fromC(close_fn(self.file));
        self.clearTransaction();
        self.savepoints.deinit(self.allocator);
        self.cache.destroy();
        if (self.temp_page.len != 0) self.allocator.free(self.temp_page);
        self.allocator.free(self.file_bytes);
        self.allocator.free(self.filename);
        self.allocator.free(self.journal_name);
        self.allocator.free(self.wal_name);
        self.state = .closed;
        return rc;
    }

    fn deinitAfterOpenFailure(self: *Pager) void {
        if (self.file.pMethods) |methods| {
            if (methods.xClose) |close_fn| _ = close_fn(self.file);
        }
        self.cache.destroy();
        if (self.temp_page.len != 0) self.allocator.free(self.temp_page);
        self.allocator.free(self.file_bytes);
        self.allocator.free(self.filename);
        self.allocator.free(self.journal_name);
        self.allocator.free(self.wal_name);
        self.state = .closed;
    }
};

fn installFile(memory: *vfs.MemoryVfs, name: []const u8, data: []const u8) !void {
    const opened = memory.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return error.VfsOpen;
    const file = opened.file.?;
    if (file.write(data, 0) != vfs.OK) return error.VfsWrite;
    if (file.sync() != vfs.OK) return error.VfsSync;
    if (memory.closeAndDestroy(file) != vfs.OK) return error.VfsClose;
}

fn expectOpen(
    memory: *vfs.MemoryVfs,
    adapter: *vfs.AbiAdapter,
    name: []const u8,
    data: []const u8,
) !OpenOutcome {
    try installFile(memory, name, data);
    return Pager.open(std.testing.allocator, &adapter.abi, name, .{});
}

fn readFixture(name: []const u8) ![]u8 {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "tests/fixtures/pager/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(128 * 1024),
    );
}

test "Phase 8 state transition table includes rollback writer states" {
    try std.testing.expect(transitionAllowed(.open, .reader));
    try std.testing.expect(transitionAllowed(.reader, .open));
    try std.testing.expect(transitionAllowed(.reader, .writer_locked));
    try std.testing.expect(transitionAllowed(.writer_locked, .writer_cache_modified));
    try std.testing.expect(transitionAllowed(.writer_cache_modified, .writer_database_modified));
    try std.testing.expect(transitionAllowed(.writer_database_modified, .writer_finished));
    try std.testing.expect(transitionAllowed(.writer_finished, .reader));
    try std.testing.expect(!transitionAllowed(.open, .writer_locked));
}

test "golden headers configure page size and read transactions" {
    const Fixture = struct { file: []const u8, name: []const u8, size: u32, pages: u32 };
    const fixtures = [_]Fixture{
        .{ .file = "empty.db", .name = "empty.db", .size = 4096, .pages = 0 },
        .{ .file = "valid-empty-512.db", .name = "512.db", .size = 512, .pages = 1 },
        .{ .file = "valid-empty-4096.db", .name = "4096.db", .size = 4096, .pages = 1 },
        .{ .file = "valid-empty-65536.db", .name = "65536.db", .size = 65536, .pages = 1 },
        .{ .file = "valid-wal-header-without-wal.db", .name = "wal-header.db", .size = 4096, .pages = 1 },
    };
    for (fixtures) |fixture| {
        const bytes = try readFixture(fixture.file);
        defer std.testing.allocator.free(bytes);
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var adapter = vfs.AbiAdapter.init("pager-golden", &memory);
        const outcome = try expectOpen(&memory, &adapter, fixture.name, bytes);
        try std.testing.expectEqual(ResultCode.ok, outcome.result);
        var pager = outcome.pager.?;
        try std.testing.expectEqual(fixture.size, pager.page_size);
        try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
        try std.testing.expectEqual(State.reader, pager.state);
        try std.testing.expectEqual(fixture.pages, pager.pageCount());
        try std.testing.expectEqual(ResultCode.ok, pager.endRead());
        try std.testing.expectEqual(ResultCode.ok, pager.close());
    }
}

test "malformed database headers return exact not-a-database code" {
    const fixtures = [_][]const u8{
        "malformed-short-header.db",
        "malformed-magic.db",
        "malformed-page-size.db",
        "malformed-payload-fractions.db",
    };
    for (fixtures, 0..) |fixture_name, index| {
        const fixture = try readFixture(fixture_name);
        defer std.testing.allocator.free(fixture);
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var adapter = vfs.AbiAdapter.init("pager-malformed", &memory);
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "bad-{d}.db", .{index});
        const outcome = try expectOpen(&memory, &adapter, name, fixture);
        try std.testing.expectEqual(ResultCode.not_a_database, outcome.result);
        try std.testing.expect(outcome.pager == null);
    }
}

test "page acquisition fills cache normalizes short reads and tracks hits" {
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("pager-pages", &memory);
    const fixture = try readFixture("truncated-second-page.db");
    defer std.testing.allocator.free(fixture);
    const outcome = try expectOpen(&memory, &adapter, "truncated.db", fixture);
    var pager = outcome.pager.?;
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    try std.testing.expectEqual(@as(u32, 2), pager.pageCount());

    const page1 = pager.getPage(1, false);
    try std.testing.expectEqual(ResultCode.ok, page1.result);
    try std.testing.expectEqualStrings("SQLite format 3\x00", page1.page.?.data[0..16]);
    try std.testing.expectEqual(ResultCode.ok, pager.release(page1.page.?));

    const page2 = pager.getPage(2, false);
    try std.testing.expectEqual(ResultCode.ok, page2.result);
    try std.testing.expectEqual(@as(u8, (126 * 37) & 0xff), page2.page.?.data[126]);
    try std.testing.expectEqual(@as(u8, 0), page2.page.?.data[127]);
    try std.testing.expectEqual(ResultCode.ok, pager.release(page2.page.?));

    const page2_hit = pager.getPage(2, false);
    try std.testing.expectEqual(ResultCode.ok, page2_hit.result);
    try std.testing.expectEqual(@as(u64, 1), pager.stats.cache_hits);
    try std.testing.expectEqual(ResultCode.ok, pager.release(page2_hit.page.?));

    const page3 = pager.getPage(3, false);
    try std.testing.expectEqual(ResultCode.ok, page3.result);
    try std.testing.expect(std.mem.allEqual(u8, page3.page.?.data, 0));
    try std.testing.expectEqual(ResultCode.ok, pager.release(page3.page.?));
    try std.testing.expect(pager.cache.checkInvariants());
    try std.testing.expectEqual(ResultCode.ok, pager.endRead());
    try std.testing.expectEqual(ResultCode.ok, pager.close());
}

test "pager memory usage tracks owner, page size, extra bytes, and cache pages" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "memory-used.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-memory-used", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "memory-used.db", .{ .extra_size = 24 }).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    const owner_bytes = pager.memoryUsed();
    try std.testing.expect(owner_bytes >= @sizeOf(Pager) + @sizeOf(page_cache.Cache) + pager.file_bytes.len + @as(usize, pager.page_size));
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    const page = pager.getPage(1, false).page.?;
    const expected_page_bytes = @as(usize, pager.page_size) + pager.cache.extra_size + @sizeOf(page_cache.Page) + 5 * @sizeOf(*anyopaque);
    try std.testing.expectEqual(owner_bytes + expected_page_bytes, pager.memoryUsed());
    try std.testing.expectEqual(ResultCode.ok, pager.release(page));
    try std.testing.expectEqual(ResultCode.ok, pager.endRead());
}

fn readUserVersion(page: []const u8) u32 {
    return Pager.getU32(page, 60);
}

fn writeUserVersion(page: []u8, value: u32) void {
    Pager.putU32(page, 60, value);
}

test "Phase 8 commit and rollback preserve DELETE FULL ordering and content" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "write.db", fixture);
    memory.events.clearRetainingCapacity();
    var adapter = vfs.AbiAdapter.init("pager-write", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "write.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
    const page = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(page));
    writeUserVersion(page.data, 0x1020_3040);
    try std.testing.expectEqual(ResultCode.ok, pager.release(page));
    try std.testing.expectEqual(ResultCode.ok, pager.commit());
    try std.testing.expectEqual(State.reader, pager.state);
    try std.testing.expect(!pager.cache.isDirty());
    var journal_exists: c_int = 1;
    try std.testing.expectEqual(vfs.OK, memory.access("write.db-journal", vfs.ACCESS_EXISTS, &journal_exists));
    try std.testing.expectEqual(@as(c_int, 0), journal_exists);

    var observed = std.ArrayList(vfs.Event).empty;
    defer observed.deinit(std.testing.allocator);
    for (memory.events.items) |event| {
        if ((event.method == .write or event.method == .sync or event.method == .delete) and
            (event.kind == .journal or event.kind == .database))
            try observed.append(std.testing.allocator, event);
    }
    var first_journal_sync: ?usize = null;
    var first_database_write: ?usize = null;
    var database_sync: ?usize = null;
    var journal_delete: ?usize = null;
    for (observed.items, 0..) |event, index| {
        if (event.kind == .journal and event.method == .sync and first_journal_sync == null) first_journal_sync = index;
        if (event.kind == .database and event.method == .write and first_database_write == null) first_database_write = index;
        if (event.kind == .database and event.method == .sync) database_sync = index;
        if (event.kind == .journal and event.method == .delete) journal_delete = index;
    }
    try std.testing.expect(first_journal_sync.? < first_database_write.?);
    try std.testing.expect(first_database_write.? < database_sync.?);
    try std.testing.expect(database_sync.? < journal_delete.?);

    try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
    const rolled = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(rolled));
    writeUserVersion(rolled.data, 0xdead_beef);
    try std.testing.expectEqual(ResultCode.ok, pager.release(rolled));
    try std.testing.expectEqual(ResultCode.ok, pager.rollback());
    const restored = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 0x1020_3040), readUserVersion(restored.data));
    try std.testing.expectEqual(ResultCode.ok, pager.release(restored));
    try std.testing.expectEqual(ResultCode.ok, pager.close());
}

test "pager routes memory-only rollback through the source-shaped journal owner" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "memory-journal.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-memory-journal", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "memory-journal.db", .{
        .writable = true,
        .journal_spill_threshold = -1,
    }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
    const page = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(page));
    try std.testing.expect(pager.journal != null and pager.journal.?.isInMemory());
    writeUserVersion(page.data, 0x5566_7788);
    try std.testing.expectEqual(ResultCode.ok, pager.release(page));
    try std.testing.expectEqual(ResultCode.ok, pager.rollback());
    const restored = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 0), readUserVersion(restored.data));
    try std.testing.expectEqual(ResultCode.ok, pager.release(restored));
    var exists: c_int = 1;
    try std.testing.expectEqual(vfs.OK, memory.access("memory-journal.db-journal", vfs.ACCESS_EXISTS, &exists));
    try std.testing.expectEqual(@as(c_int, 0), exists);
    try std.testing.expectEqual(ResultCode.ok, pager.close());
}

test "hot journal recovery restores pre-commit database and permits continuation" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "crash.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-crash", &memory);
    var writer = Pager.open(std.testing.allocator, &adapter.abi, "crash.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, writer.beginRead());
    try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
    const changed = writer.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, writer.makeWritable(changed));
    writeUserVersion(changed.data, 77);
    try std.testing.expectEqual(ResultCode.ok, writer.release(changed));
    try std.testing.expectEqual(ResultCode.ok, writer.commitPhaseOne());
    try std.testing.expectEqual(State.writer_finished, writer.state);
    memory.crash();
    writer.crashClose();

    var recovered = Pager.open(std.testing.allocator, &adapter.abi, "crash.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, recovered.beginRead());
    const old = recovered.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 0), readUserVersion(old.data));
    try std.testing.expectEqual(ResultCode.ok, recovered.release(old));
    var journal_exists: c_int = 1;
    try std.testing.expectEqual(vfs.OK, memory.access("crash.db-journal", vfs.ACCESS_EXISTS, &journal_exists));
    try std.testing.expectEqual(@as(c_int, 0), journal_exists);

    try std.testing.expectEqual(ResultCode.ok, recovered.beginWrite());
    const next = recovered.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, recovered.makeWritable(next));
    writeUserVersion(next.data, 88);
    try std.testing.expectEqual(ResultCode.ok, recovered.release(next));
    try std.testing.expectEqual(ResultCode.ok, recovered.commit());
    try std.testing.expectEqual(ResultCode.ok, recovered.close());
    memory.crash();

    var reader = Pager.open(std.testing.allocator, &adapter.abi, "crash.db", .{}).pager.?;
    try std.testing.expectEqual(ResultCode.ok, reader.beginRead());
    const durable = reader.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 88), readUserVersion(durable.data));
    try std.testing.expectEqual(ResultCode.ok, reader.release(durable));
    try std.testing.expectEqual(ResultCode.ok, reader.close());
}

const CrashStop = struct {
    target: CommitEvent,
    stopped: bool = false,
};

fn stopAtCommitEvent(context: ?*anyopaque, event: CommitEvent) bool {
    const stop: *CrashStop = @ptrCast(@alignCast(context.?));
    if (!stop.stopped and event == stop.target) {
        stop.stopped = true;
        return false;
    }
    return true;
}

test "every modeled DELETE FULL crash point recovers old or committed content" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    const events = std.meta.tags(CommitEvent);
    for (events, 0..) |event, event_index| {
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        try installFile(&memory, "point.db", fixture);
        var adapter = vfs.AbiAdapter.init("pager-crash-point", &memory);
        var writer = Pager.open(std.testing.allocator, &adapter.abi, "point.db", .{ .writable = true }).pager.?;
        try std.testing.expectEqual(ResultCode.ok, writer.beginRead());
        try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
        const page = writer.getPage(1, false).page.?;
        var stop = CrashStop{ .target = event };
        writer.setCommitHook(stopAtCommitEvent, &stop);
        const writable = writer.makeWritable(page);
        if (event == .journal_write) {
            try std.testing.expectEqual(ResultCode.interrupt, writable);
            try std.testing.expectEqual(ResultCode.ok, writer.release(page));
        } else {
            try std.testing.expectEqual(ResultCode.ok, writable);
            writeUserVersion(page.data, 900 + @as(u32, @intCast(event_index)));
            try std.testing.expectEqual(ResultCode.ok, writer.release(page));
            const phase_one = writer.commitPhaseOne();
            if (event == .journal_delete) {
                try std.testing.expectEqual(ResultCode.ok, phase_one);
                try std.testing.expectEqual(ResultCode.interrupt, writer.commitPhaseTwo());
            } else {
                try std.testing.expectEqual(ResultCode.interrupt, phase_one);
            }
        }
        try std.testing.expect(stop.stopped);
        memory.crash();
        writer.crashClose();

        var recovered = Pager.open(std.testing.allocator, &adapter.abi, "point.db", .{ .writable = true }).pager.?;
        try std.testing.expectEqual(ResultCode.ok, recovered.beginRead());
        const check = recovered.getPage(1, false).page.?;
        const expected: u32 = if (event == .journal_delete) 900 + @as(u32, @intCast(event_index)) else 0;
        try std.testing.expectEqual(expected, readUserVersion(check.data));
        try std.testing.expectEqual(ResultCode.ok, recovered.release(check));

        // Recovery continuation is part of every crash-point observation.
        try std.testing.expectEqual(ResultCode.ok, recovered.beginWrite());
        const continuation = recovered.getPage(1, false).page.?;
        try std.testing.expectEqual(ResultCode.ok, recovered.makeWritable(continuation));
        writeUserVersion(continuation.data, 1000 + @as(u32, @intCast(event_index)));
        try std.testing.expectEqual(ResultCode.ok, recovered.release(continuation));
        try std.testing.expectEqual(ResultCode.ok, recovered.commit());
        try std.testing.expectEqual(ResultCode.ok, recovered.close());
    }
}

test "hot journal sync publishes the durable playback boundary after successful sync" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "hot-sync.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-hot-sync", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "hot-sync.db", .{ .writable = true }).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    try std.testing.expectEqual(ResultCode.ok, pager.openJournalFile(true));
    const bytes = [_]u8{0x5a} ** 31;
    try std.testing.expectEqual(vfs.OK, pager.journal.?.write(&bytes, 0));
    try std.testing.expectEqual(ResultCode.ok, pager.syncHotJournal());
    try std.testing.expectEqual(@as(u64, bytes.len), pager.journal_header);

    var rules = [_]vfs.FaultRule{.{ .method = .sync, .code = vfs.IOERR_FSYNC }};
    var faults = vfs.FaultController{ .rules = &rules };
    memory.faults = &faults;
    pager.journal_header = 7;
    try std.testing.expectEqual(ResultCode.fromC(vfs.IOERR_FSYNC), pager.syncHotJournal());
    try std.testing.expectEqual(@as(u64, 7), pager.journal_header);
    memory.faults = null;
    try std.testing.expectEqual(ResultCode.ok, pager.closeJournalFile(false));
}

fn createHotJournal(memory: *vfs.MemoryVfs, adapter: *vfs.AbiAdapter, name: []const u8, fixture: []const u8) !void {
    try installFile(memory, name, fixture);
    var writer = Pager.open(std.testing.allocator, &adapter.abi, name, .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, writer.beginRead());
    try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
    const page = writer.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, writer.makeWritable(page));
    writeUserVersion(page.data, 9999);
    try std.testing.expectEqual(ResultCode.ok, writer.release(page));
    try std.testing.expectEqual(ResultCode.ok, writer.commitPhaseOne());
    memory.crash();
    writer.crashClose();
}

test "malformed hot-journal checksum is rejected without database mutation" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("pager-bad-hot", &memory);
    try createHotJournal(&memory, &adapter, "bad-hot.db", fixture);
    const journal = memory.open("bad-hot.db-journal", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_JOURNAL).file.?;
    const bad_checksum: [4]u8 = .{0} ** 4;
    try std.testing.expectEqual(vfs.OK, journal.write(&bad_checksum, 4096 + 4 + 4096));
    try std.testing.expectEqual(vfs.OK, journal.sync());
    try std.testing.expectEqual(vfs.OK, memory.closeAndDestroy(journal));
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "bad-hot.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.corrupt, pager.beginRead());
    try std.testing.expectEqual(State.open, pager.state);
    var exists: c_int = 0;
    try std.testing.expectEqual(vfs.OK, memory.access("bad-hot.db-journal", vfs.ACCESS_EXISTS, &exists));
    try std.testing.expectEqual(@as(c_int, 1), exists);
    try std.testing.expectEqual(ResultCode.ok, pager.close());
}

test "hot recovery faults retain a retryable journal and exact result" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    const cases = [_]struct { vfs.Method, vfs.FaultMode, c_int }{
        .{ .open, .one_shot, vfs.IOERR },
        .{ .lock, .one_shot, vfs.IOERR },
        .{ .read, .one_shot, vfs.IOERR },
        .{ .write, .one_shot, vfs.IOERR_WRITE },
        .{ .write, .short_operation, vfs.IOERR_WRITE },
        .{ .truncate, .one_shot, vfs.IOERR_TRUNCATE },
        .{ .sync, .one_shot, vfs.IOERR_FSYNC },
        .{ .delete, .one_shot, vfs.IOERR_DELETE },
    };
    for (cases, 0..) |case, index| {
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var adapter = vfs.AbiAdapter.init("pager-recovery-fault", &memory);
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "recover-fault-{d}.db", .{index});
        try createHotJournal(&memory, &adapter, name, fixture);
        var pager = Pager.open(std.testing.allocator, &adapter.abi, name, .{ .writable = true }).pager.?;
        var rules = [_]vfs.FaultRule{.{ .method = case[0], .mode = case[1], .code = case[2] }};
        var faults = vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        try std.testing.expectEqual(ResultCode.fromC(case[2]), pager.beginRead());
        try std.testing.expectEqual(State.open, pager.state);
        try std.testing.expectEqual(@as(usize, 0), pager.cacheReferences());
        try std.testing.expect(faults.injectionWasTriggered(case[0]));
        memory.faults = null;
        try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
        const restored = pager.getPage(1, false).page.?;
        try std.testing.expectEqual(@as(u32, 0), readUserVersion(restored.data));
        try std.testing.expectEqual(ResultCode.ok, pager.release(restored));
        try std.testing.expectEqual(ResultCode.ok, pager.close());
    }
}

fn crashAfterWriteFault(method: vfs.Method, at: usize, mode: vfs.FaultMode, code: c_int) !void {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "subwrite-crash.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-subwrite-crash", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "subwrite-crash.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    var rules = [_]vfs.FaultRule{.{ .method = method, .at = at, .mode = mode, .code = code }};
    var faults = vfs.FaultController{ .rules = &rules };
    memory.faults = &faults;
    var rc = pager.beginWrite();
    const fetched = if (rc == .ok) pager.getPage(1, false) else PageOutcome{ .result = rc };
    const page: ?*page_cache.Page = fetched.page;
    if (rc == .ok) rc = fetched.result;
    if (rc == .ok) {
        rc = pager.makeWritable(page.?);
        if (rc == .ok) writeUserVersion(page.?.data, 0x7788_9900);
    }
    if (page) |held| try std.testing.expectEqual(ResultCode.ok, pager.release(held));
    if (rc == .ok) rc = pager.commitPhaseOne();
    if (rc == .ok) rc = pager.commitPhaseTwo();
    try std.testing.expectEqual(ResultCode.fromC(code), rc);
    try std.testing.expect(faults.injectionWasTriggered(method));
    memory.crash();
    pager.crashClose();
    memory.faults = null;

    var recovered = Pager.open(std.testing.allocator, &adapter.abi, "subwrite-crash.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, recovered.beginRead());
    const restored = recovered.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 0), readUserVersion(restored.data));
    try std.testing.expectEqual(ResultCode.ok, recovered.release(restored));
    try std.testing.expectEqual(ResultCode.ok, recovered.close());
}

test "sub-write sync truncate and delete crash boundaries recover old content" {
    for (0..6) |at| try crashAfterWriteFault(.write, at, .short_operation, vfs.IOERR_WRITE);
    for (0..3) |at| try crashAfterWriteFault(.sync, at, .one_shot, vfs.IOERR_FSYNC);
    for (0..2) |at| try crashAfterWriteFault(.truncate, at, .one_shot, vfs.IOERR_TRUNCATE);
    try crashAfterWriteFault(.delete, 0, .one_shot, vfs.IOERR_DELETE);
}

fn exerciseWriteFault(method: vfs.Method, at: usize, mode: vfs.FaultMode, code: c_int) !void {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "write-fault.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-write-fault", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "write-fault.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    var rules = [_]vfs.FaultRule{.{ .method = method, .at = at, .mode = mode, .code = code }};
    var faults = vfs.FaultController{ .rules = &rules };
    memory.faults = &faults;
    var operation_rc = pager.beginWrite();
    var page: ?*page_cache.Page = null;
    if (operation_rc == .ok) {
        const fetched = pager.getPage(1, false);
        operation_rc = fetched.result;
        page = fetched.page;
    }
    if (operation_rc == .ok) {
        operation_rc = pager.makeWritable(page.?);
        if (operation_rc == .ok) writeUserVersion(page.?.data, 0xaabb_ccdd);
    }
    if (page) |held| try std.testing.expectEqual(ResultCode.ok, pager.release(held));
    if (operation_rc == .ok) operation_rc = pager.commitPhaseOne();
    if (operation_rc == .ok) operation_rc = pager.commitPhaseTwo();
    try std.testing.expectEqual(ResultCode.fromC(code), operation_rc);
    try std.testing.expect(faults.injectionWasTriggered(method));
    memory.faults = null;
    if (pager.state != .reader) try std.testing.expectEqual(ResultCode.ok, pager.rollback());
    const restored = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 0), readUserVersion(restored.data));
    try std.testing.expectEqual(ResultCode.ok, pager.release(restored));
    try std.testing.expect(pager.cache.checkInvariants());

    try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
    const continuation = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(continuation));
    writeUserVersion(continuation.data, 1234);
    try std.testing.expectEqual(ResultCode.ok, pager.release(continuation));
    try std.testing.expectEqual(ResultCode.ok, pager.commit());
    try std.testing.expectEqual(ResultCode.ok, pager.close());
}

test "write sync truncate delete open and lock faults roll back and continue" {
    for (0..6) |at| try exerciseWriteFault(.write, at, .one_shot, vfs.IOERR_WRITE);
    try exerciseWriteFault(.write, 2, .short_operation, vfs.IOERR_WRITE);
    try exerciseWriteFault(.write, 2, .sticky, vfs.IOERR_WRITE);
    for (0..3) |at| try exerciseWriteFault(.sync, at, .one_shot, vfs.IOERR_FSYNC);
    try exerciseWriteFault(.sync, 0, .sticky, vfs.IOERR_FSYNC);
    try exerciseWriteFault(.truncate, 0, .one_shot, vfs.IOERR_TRUNCATE);
    try exerciseWriteFault(.truncate, 1, .one_shot, vfs.IOERR_TRUNCATE);
    try exerciseWriteFault(.delete, 0, .one_shot, vfs.IOERR_DELETE);
    try exerciseWriteFault(.delete, 0, .sticky, vfs.IOERR_DELETE);
    try exerciseWriteFault(.open, 0, .one_shot, vfs.IOERR);
    try exerciseWriteFault(.lock, 0, .one_shot, vfs.IOERR);
}

test "read-only mutation paths are unreachable and leave state unchanged" {
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("pager-readonly", &memory);
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    const outcome = try expectOpen(&memory, &adapter, "readonly.db", fixture);
    var pager = outcome.pager.?;
    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    const page = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.read_only, pager.beginWrite());
    try std.testing.expectEqual(ResultCode.read_only, pager.makeWritable(page));
    try std.testing.expectEqual(ResultCode.read_only, pager.movePage(page, 2));
    try std.testing.expectEqual(ResultCode.read_only, pager.truncateImage(0));
    try std.testing.expectEqual(State.reader, pager.state);
    try std.testing.expectEqual(ResultCode.ok, pager.release(page));
    try std.testing.expectEqual(ResultCode.ok, pager.close());
}

fn stopAfterOneBusy(context: ?*anyopaque) bool {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return false;
}

const MovedProbe = struct {
    delegate: *const vfs.sqlite3_io_methods,
    result: c_int = vfs.OK,
    moved: c_int = 0,
};
var moved_probe: ?*MovedProbe = null;

fn probeMovedFileControl(file: *vfs.sqlite3_file, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    const probe = moved_probe orelse return vfs.NOTFOUND;
    if (operation == vfs.FCNTL_HAS_MOVED) {
        if (probe.result != vfs.OK) return probe.result;
        const output: *c_int = @ptrCast(@alignCast(argument orelse return vfs.ERROR));
        output.* = probe.moved;
        return vfs.OK;
    }
    const control = probe.delegate.xFileControl orelse return vfs.NOTFOUND;
    return control(file, operation, argument);
}

test "journal file accessor selects rollback journal and open WAL handles" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "journal-owner.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-journal-owner", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "journal-owner.db", .{ .writable = true }).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    try std.testing.expect(pager.journalFile() == null);
    try std.testing.expectEqual(@as(u32, 0), pager.takeWalCallbackFrame());
    try std.testing.expectEqual(ResultCode.ok, pager.openJournalFile(true));
    try std.testing.expect(pager.journalFile() == pager.journal.?.abiFile());
    try std.testing.expectEqual(ResultCode.ok, pager.closeJournalFile(false));

    pager.wal_state = wal.Wal.open(std.testing.allocator, &adapter.abi, pager.file, pager.wal_name, pager.page_size, true, false, true).wal.?;
    try std.testing.expectEqual(ResultCode.ok, pager.wal_state.?.beginWrite());
    const fetched = pager.cache.fetch(1, .hard_create, null);
    const page = fetched.page.?;
    @memset(page.data, 0x5a);
    try std.testing.expectEqual(ResultCode.ok, pager.wal_state.?.append(page, 1));
    try std.testing.expect(pager.journalFile() == pager.wal_state.?.file);
    try std.testing.expectEqual(@as(u32, 1), pager.takeWalCallbackFrame());
    try std.testing.expectEqual(@as(u32, 0), pager.takeWalCallbackFrame());
    try std.testing.expectEqual(page_cache.Result.ok, pager.cache.release(page));
    pager.wal_state.?.deinit();
    pager.wal_state = null;
}

test "pager owner accessors preserve VFS file and journal name identity" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "owner-access.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-owner-access", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "owner-access.db", .{}).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    try std.testing.expect(pager.filesystem() == &adapter.abi);
    try std.testing.expect(pager.databaseFile() == pager.file);
    try std.testing.expectEqualStrings("owner-access.db-journal", pager.journalName());
}

test "database moved detection preserves empty unsupported moved and error results" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "moved.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-moved", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "moved.db", .{ .writable = true }).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    const original_methods = pager.file.pMethods.?;
    var probe = MovedProbe{ .delegate = original_methods };
    var probing_methods = original_methods.*;
    probing_methods.xFileControl = probeMovedFileControl;
    moved_probe = &probe;
    defer moved_probe = null;
    pager.file.pMethods = &probing_methods;

    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    try std.testing.expectEqual(ResultCode.ok, pager.databaseIsUnmoved());
    probe.moved = 1;
    try std.testing.expectEqual(readonly_database_moved, pager.databaseIsUnmoved());
    probe.result = vfs.IOERR;
    try std.testing.expectEqual(ResultCode.io_error, pager.databaseIsUnmoved());
    probe.result = vfs.NOTFOUND;
    try std.testing.expectEqual(ResultCode.ok, pager.databaseIsUnmoved());
    pager.database_pages = 0;
    probe.result = vfs.IOERR;
    try std.testing.expectEqual(ResultCode.ok, pager.databaseIsUnmoved());
}

const BusyHintProbe = struct {
    delegate: *const vfs.sqlite3_io_methods,
    seen_operation: c_int = -1,
    seen_argument: ?*anyopaque = null,
};
var busy_hint_probe: ?*BusyHintProbe = null;

fn probeBusyFileControl(file: *vfs.sqlite3_file, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    const probe = busy_hint_probe orelse return vfs.NOTFOUND;
    probe.seen_operation = operation;
    probe.seen_argument = argument;
    const control = probe.delegate.xFileControl orelse return vfs.NOTFOUND;
    return control(file, operation, argument);
}

test "truncate image records the commit size and rollback restores the original" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "truncate-image.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-truncate-image", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "truncate-image.db", .{ .writable = true }).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
    try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
    const page = pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(page));
    try std.testing.expectEqual(ResultCode.ok, pager.release(page));
    try std.testing.expectEqual(ResultCode.misuse, pager.truncateImage(2));
    try std.testing.expectEqual(ResultCode.ok, pager.truncateImage(0));
    try std.testing.expectEqual(@as(u32, 0), pager.pageCount());
    try std.testing.expectEqual(ResultCode.ok, pager.rollback());
    try std.testing.expectEqual(@as(u32, 1), pager.pageCount());
}

test "maximum page count updates positive requests and preserves zero queries" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "max-page-count.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-max-page-count", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "max-page-count.db", .{}).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    try std.testing.expectEqual(maximum_page_count, pager.maxPageCount(0));
    try std.testing.expectEqual(@as(u32, 1), pager.maxPageCount(1));
    try std.testing.expectEqual(@as(u32, 1), pager.maxPageCount(0));
    try std.testing.expectEqual(@as(u32, 7), pager.maxPageCount(7));
}

test "busy handler installation forwards callback and context as a VFS hint" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "busy-hint.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-busy-hint", &memory);
    var pager = Pager.open(std.testing.allocator, &adapter.abi, "busy-hint.db", .{}).pager.?;
    defer std.testing.expectEqual(ResultCode.ok, pager.close()) catch unreachable;

    const original_methods = pager.file.pMethods.?;
    var probe = BusyHintProbe{ .delegate = original_methods };
    var probing_methods = original_methods.*;
    probing_methods.xFileControl = probeBusyFileControl;
    busy_hint_probe = &probe;
    defer busy_hint_probe = null;
    pager.file.pMethods = &probing_methods;

    var calls: usize = 0;
    pager.setBusyHandler(stopAfterOneBusy, &calls);
    try std.testing.expectEqual(vfs.FCNTL_BUSYHANDLER, probe.seen_operation);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&pager.busy_handler_hint)), probe.seen_argument);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(@constCast(&stopAfterOneBusy))), pager.busy_handler_hint[0]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&calls)), pager.busy_handler_hint[1]);
    try std.testing.expect(!pager.busy_handler.?(pager.busy_context));
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "writer reserved and exclusive contention preserve busy-callback policy" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "writer-busy.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-writer-busy", &memory);
    var first = Pager.open(std.testing.allocator, &adapter.abi, "writer-busy.db", .{ .writable = true }).pager.?;
    var second = Pager.open(std.testing.allocator, &adapter.abi, "writer-busy.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, first.beginRead());
    try std.testing.expectEqual(ResultCode.ok, second.beginRead());
    try std.testing.expectEqual(ResultCode.ok, first.beginWrite());
    var reserved_busy_calls: usize = 0;
    second.setBusyHandler(stopAfterOneBusy, &reserved_busy_calls);
    try std.testing.expectEqual(ResultCode.busy, second.beginWrite());
    try std.testing.expectEqual(@as(usize, 0), reserved_busy_calls);

    const page = first.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, first.makeWritable(page));
    writeUserVersion(page.data, 55);
    try std.testing.expectEqual(ResultCode.ok, first.release(page));
    var exclusive_busy_calls: usize = 0;
    first.setBusyHandler(stopAfterOneBusy, &exclusive_busy_calls);
    try std.testing.expectEqual(ResultCode.busy, first.commitPhaseOne());
    try std.testing.expectEqual(@as(usize, 1), exclusive_busy_calls);
    try std.testing.expectEqual(State.writer_cache_modified, first.state);
    try std.testing.expectEqual(ResultCode.ok, second.close());
    try std.testing.expectEqual(ResultCode.ok, first.commit());
    try std.testing.expectEqual(ResultCode.ok, first.close());
}

test "hot journal and lock contention return exact codes without mutation" {
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    try installFile(&memory, "hot.db", fixture);
    try installFile(&memory, "hot.db-journal", "not-zero");
    var adapter = vfs.AbiAdapter.init("pager-hot", &memory);
    const hot_outcome = Pager.open(std.testing.allocator, &adapter.abi, "hot.db", .{});
    var hot = hot_outcome.pager.?;
    try std.testing.expectEqual(readonly_rollback, hot.beginRead());
    try std.testing.expectEqual(State.open, hot.state);
    var exists: c_int = 0;
    try std.testing.expectEqual(vfs.OK, memory.access("hot.db-journal", vfs.ACCESS_EXISTS, &exists));
    try std.testing.expectEqual(@as(c_int, 1), exists);
    try std.testing.expectEqual(ResultCode.ok, hot.close());

    try installFile(&memory, "busy.db", fixture);
    const blocker_open = memory.open("busy.db", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB);
    const blocker = blocker_open.file.?;
    try std.testing.expectEqual(vfs.OK, blocker.lock(vfs.LOCK_EXCLUSIVE));
    const busy_outcome = Pager.open(std.testing.allocator, &adapter.abi, "busy.db", .{});
    var busy = busy_outcome.pager.?;
    var busy_calls: usize = 0;
    busy.setBusyHandler(stopAfterOneBusy, &busy_calls);
    try std.testing.expectEqual(ResultCode.busy, busy.beginRead());
    try std.testing.expectEqual(@as(usize, 1), busy_calls);
    try std.testing.expectEqual(State.open, busy.state);
    try std.testing.expectEqual(vfs.OK, blocker.unlock(vfs.LOCK_NONE));
    try std.testing.expectEqual(vfs.OK, memory.closeAndDestroy(blocker));
    try std.testing.expectEqual(ResultCode.ok, busy.close());
}

test "VFS faults preserve exact codes state and cache ownership" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "fault.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-fault", &memory);

    inline for (.{ vfs.Method.open, vfs.Method.full_pathname, vfs.Method.read }) |method| {
        var rules = [_]vfs.FaultRule{.{ .method = method, .code = vfs.IOERR }};
        var faults = vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        const outcome = Pager.open(std.testing.allocator, &adapter.abi, "fault.db", .{});
        try std.testing.expectEqual(ResultCode.io_error, outcome.result);
        try std.testing.expect(outcome.pager == null);
        memory.faults = null;
    }

    var lock_rules = [_]vfs.FaultRule{.{ .method = .lock, .code = vfs.IOERR }};
    var lock_faults = vfs.FaultController{ .rules = &lock_rules };
    memory.faults = &lock_faults;
    const lock_outcome = Pager.open(std.testing.allocator, &adapter.abi, "fault.db", .{});
    var lock_pager = lock_outcome.pager.?;
    try std.testing.expectEqual(ResultCode.io_error, lock_pager.beginRead());
    try std.testing.expectEqual(State.open, lock_pager.state);
    memory.faults = null;
    try std.testing.expectEqual(ResultCode.ok, lock_pager.close());

    const access_outcome = Pager.open(std.testing.allocator, &adapter.abi, "fault.db", .{});
    var access_pager = access_outcome.pager.?;
    var access_rules = [_]vfs.FaultRule{.{ .method = .access, .code = vfs.IOERR_ACCESS }};
    var access_faults = vfs.FaultController{ .rules = &access_rules };
    memory.faults = &access_faults;
    try std.testing.expectEqual(ResultCode.fromC(vfs.IOERR_ACCESS), access_pager.beginRead());
    try std.testing.expectEqual(State.open, access_pager.state);
    memory.faults = null;
    try std.testing.expectEqual(ResultCode.ok, access_pager.close());

    const read_outcome = Pager.open(std.testing.allocator, &adapter.abi, "fault.db", .{});
    var read_pager = read_outcome.pager.?;
    try std.testing.expectEqual(ResultCode.ok, read_pager.beginRead());
    var read_rules = [_]vfs.FaultRule{.{ .method = .read, .code = vfs.IOERR }};
    var read_faults = vfs.FaultController{ .rules = &read_rules };
    memory.faults = &read_faults;
    const fetched = read_pager.getPage(1, false);
    try std.testing.expectEqual(ResultCode.io_error, fetched.result);
    try std.testing.expectEqual(@as(usize, 0), read_pager.cacheReferences());
    try std.testing.expectEqual(@as(usize, 0), read_pager.cachePages());
    try std.testing.expect(read_pager.cache.checkInvariants());
    memory.faults = null;
    try std.testing.expectEqual(ResultCode.ok, read_pager.close());

    var size_rules = [_]vfs.FaultRule{.{ .method = .file_size, .code = vfs.IOERR_FSYNC }};
    var size_faults = vfs.FaultController{ .rules = &size_rules };
    memory.faults = &size_faults;
    const size_outcome = Pager.open(std.testing.allocator, &adapter.abi, "fault.db", .{});
    try std.testing.expectEqual(ResultCode.fromC(vfs.IOERR_FSYNC), size_outcome.result);
    try std.testing.expect(size_outcome.pager == null);
    memory.faults = null;

    const close_outcome = Pager.open(std.testing.allocator, &adapter.abi, "fault.db", .{});
    var close_pager = close_outcome.pager.?;
    var close_rules = [_]vfs.FaultRule{.{ .method = .close, .code = vfs.IOERR }};
    var close_faults = vfs.FaultController{ .rules = &close_rules };
    memory.faults = &close_faults;
    try std.testing.expectEqual(ResultCode.io_error, close_pager.close());
    try std.testing.expectEqual(State.closed, close_pager.state);
    memory.faults = null;
}

test "WAL read write recovery and checkpoint use committed snapshots" {
    const source = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(source);
    const fixture = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(fixture);
    fixture[18] = 2;
    fixture[19] = 2;
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "native-wal.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-native-wal", &memory);
    var writer = Pager.open(std.testing.allocator, &adapter.abi, "native-wal.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, writer.beginRead());
    try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
    const changed = writer.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, writer.makeWritable(changed));
    writeUserVersion(changed.data, 707);
    try std.testing.expectEqual(ResultCode.ok, writer.release(changed));
    try std.testing.expectEqual(ResultCode.ok, writer.commit());
    var exists: c_int = 0;
    try std.testing.expectEqual(vfs.OK, memory.access("native-wal.db-wal", vfs.ACCESS_EXISTS, &exists));
    try std.testing.expectEqual(@as(c_int, 1), exists);

    var reader = Pager.open(std.testing.allocator, &adapter.abi, "native-wal.db", .{}).pager.?;
    try std.testing.expectEqual(ResultCode.ok, reader.beginRead());
    const visible = reader.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 707), readUserVersion(visible.data));
    try std.testing.expectEqual(ResultCode.ok, reader.release(visible));
    const passive = writer.checkpointWal();
    try std.testing.expectEqual(ResultCode.busy, passive.result);
    try std.testing.expectEqual(@as(u32, 0), passive.checkpointed);
    try std.testing.expectEqual(ResultCode.ok, reader.close());
    const restarted = writer.checkpointWal();
    try std.testing.expectEqual(ResultCode.ok, restarted.result);
    try std.testing.expectEqual(ResultCode.ok, writer.close());
    memory.crash();

    var durable = Pager.open(std.testing.allocator, &adapter.abi, "native-wal.db", .{}).pager.?;
    try std.testing.expectEqual(ResultCode.ok, durable.beginRead());
    const checkpointed = durable.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 707), readUserVersion(checkpointed.data));
    try std.testing.expectEqual(ResultCode.ok, durable.release(checkpointed));
    try std.testing.expectEqual(ResultCode.ok, durable.close());
}

const WalStop = struct { target: wal.Event, stopped: bool = false };
fn stopAtWalEvent(context: ?*anyopaque, event: wal.Event) bool {
    const stop: *WalStop = @ptrCast(@alignCast(context.?));
    if (!stop.stopped and stop.target == event) {
        stop.stopped = true;
        return false;
    }
    return true;
}

test "WAL reader snapshots block reset and concurrent readers observe stable commits" {
    const source = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(source);
    const fixture = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(fixture);
    fixture[18] = 2;
    fixture[19] = 2;
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "snapshot.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-wal-snapshot", &memory);
    var old_reader = Pager.open(std.testing.allocator, &adapter.abi, "snapshot.db", .{}).pager.?;
    try std.testing.expectEqual(ResultCode.ok, old_reader.beginRead());
    var writer = Pager.open(std.testing.allocator, &adapter.abi, "snapshot.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, writer.beginRead());
    var contender = Pager.open(std.testing.allocator, &adapter.abi, "snapshot.db", .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, contender.beginRead());
    try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
    try std.testing.expectEqual(ResultCode.busy, contender.beginWrite());
    try std.testing.expectEqual(ResultCode.ok, writer.rollback());
    try std.testing.expectEqual(ResultCode.ok, contender.close());
    for (1..17) |value| {
        try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
        const page = writer.getPage(1, false).page.?;
        try std.testing.expectEqual(ResultCode.ok, writer.makeWritable(page));
        writeUserVersion(page.data, @intCast(value));
        try std.testing.expectEqual(ResultCode.ok, writer.release(page));
        try std.testing.expectEqual(ResultCode.ok, writer.commit());
        var current = Pager.open(std.testing.allocator, &adapter.abi, "snapshot.db", .{}).pager.?;
        try std.testing.expectEqual(ResultCode.ok, current.beginRead());
        const visible = current.getPage(1, false).page.?;
        try std.testing.expectEqual(@as(u32, @intCast(value)), readUserVersion(visible.data));
        try std.testing.expectEqual(ResultCode.ok, current.release(visible));
        try std.testing.expectEqual(ResultCode.ok, current.close());
    }
    const old = old_reader.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 0), readUserVersion(old.data));
    try std.testing.expectEqual(ResultCode.ok, old_reader.release(old));
    try std.testing.expectEqual(ResultCode.busy, writer.checkpointWal().result);
    try std.testing.expectEqual(ResultCode.ok, old_reader.close());
    try std.testing.expectEqual(ResultCode.ok, writer.checkpointWal().result);
    try std.testing.expectEqual(ResultCode.ok, writer.close());
}

test "WAL crash matrix recovers the last durable commit at every named event" {
    const source = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(source);
    const events = std.meta.tags(wal.Event);
    for (events, 0..) |event, index| {
        const fixture = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(fixture);
        fixture[18] = 2;
        fixture[19] = 2;
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "wal-crash-{d}.db", .{index});
        try installFile(&memory, name, fixture);
        var adapter = vfs.AbiAdapter.init("pager-wal-crash", &memory);
        var pager = Pager.open(std.testing.allocator, &adapter.abi, name, .{ .writable = true }).pager.?;
        try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
        var stop = WalStop{ .target = event };
        if (event == .checkpoint_database_write or event == .checkpoint_database_sync or event == .wal_reset) {
            try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
            const page = pager.getPage(1, false).page.?;
            try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(page));
            writeUserVersion(page.data, 800 + @as(u32, @intCast(index)));
            try std.testing.expectEqual(ResultCode.ok, pager.release(page));
            try std.testing.expectEqual(ResultCode.ok, pager.commit());
            try std.testing.expectEqual(ResultCode.ok, pager.setWalEventHook(stopAtWalEvent, &stop));
            try std.testing.expectEqual(ResultCode.interrupt, pager.checkpointWal().result);
        } else {
            try std.testing.expectEqual(ResultCode.ok, pager.setWalEventHook(stopAtWalEvent, &stop));
            try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
            const page = pager.getPage(1, false).page.?;
            try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(page));
            writeUserVersion(page.data, 800 + @as(u32, @intCast(index)));
            try std.testing.expectEqual(ResultCode.ok, pager.release(page));
            try std.testing.expectEqual(ResultCode.interrupt, pager.commitPhaseOne());
        }
        try std.testing.expect(stop.stopped);
        memory.crash();
        pager.crashClose();
        var recovered = Pager.open(std.testing.allocator, &adapter.abi, name, .{}).pager.?;
        try std.testing.expectEqual(ResultCode.ok, recovered.beginRead());
        const page = recovered.getPage(1, false).page.?;
        const committed = event == .wal_sync or event == .index_publish or
            event == .checkpoint_database_write or event == .checkpoint_database_sync or event == .wal_reset;
        const expected: u32 = if (committed) 800 + @as(u32, @intCast(index)) else 0;
        try std.testing.expectEqual(expected, readUserVersion(page.data));
        try std.testing.expectEqual(ResultCode.ok, recovered.release(page));
        try std.testing.expectEqual(ResultCode.ok, recovered.close());
    }
}

fn createCommittedWal(memory: *vfs.MemoryVfs, adapter: *vfs.AbiAdapter, name: []const u8, source: []const u8) !void {
    const fixture = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(fixture);
    fixture[18] = 2;
    fixture[19] = 2;
    try installFile(memory, name, fixture);
    var writer = Pager.open(std.testing.allocator, &adapter.abi, name, .{ .writable = true }).pager.?;
    try std.testing.expectEqual(ResultCode.ok, writer.beginRead());
    try std.testing.expectEqual(ResultCode.ok, writer.beginWrite());
    const page = writer.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, writer.makeWritable(page));
    writeUserVersion(page.data, 5);
    try std.testing.expectEqual(ResultCode.ok, writer.release(page));
    try std.testing.expectEqual(ResultCode.ok, writer.commit());
    try std.testing.expectEqual(ResultCode.ok, writer.close());
}

test "WAL index deletion and stale shared memory rebuild from committed frames" {
    const source = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(source);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("pager-wal-index-rebuild", &memory);
    try createCommittedWal(&memory, &adapter, "index-rebuild.db", source);
    const raw = memory.open("index-rebuild.db", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB).file.?;
    var pointer: ?*volatile anyopaque = null;
    try std.testing.expectEqual(vfs.OK, raw.shmMap(0, vfs.SHM_REGION_SIZE, 1, &pointer));
    const bytes: [*]volatile u8 = @ptrCast(pointer.?);
    for (0..64) |index| bytes[index] = 0xff;
    try std.testing.expectEqual(vfs.OK, raw.shmUnmap(1));
    try std.testing.expectEqual(vfs.OK, memory.closeAndDestroy(raw));
    var rebuilt = Pager.open(std.testing.allocator, &adapter.abi, "index-rebuild.db", .{}).pager.?;
    try std.testing.expectEqual(ResultCode.ok, rebuilt.beginRead());
    const page = rebuilt.getPage(1, false).page.?;
    try std.testing.expectEqual(@as(u32, 5), readUserVersion(page.data));
    try std.testing.expectEqual(ResultCode.ok, rebuilt.release(page));
    try std.testing.expectEqual(ResultCode.ok, rebuilt.close());
}

test "WAL open recovery write and synchronization faults are retryable" {
    const source = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(source);
    const read_cases = [_]struct { vfs.Method, c_int }{
        .{ .open, vfs.IOERR },
        .{ .read, vfs.IOERR },
        .{ .shm_map, vfs.IOERR_SHMMAP },
        .{ .shm_lock, vfs.IOERR_SHMLOCK },
    };
    for (read_cases, 0..) |case, index| {
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var adapter = vfs.AbiAdapter.init("pager-wal-read-fault", &memory);
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "wal-read-fault-{d}.db", .{index});
        try createCommittedWal(&memory, &adapter, name, source);
        var pager = Pager.open(std.testing.allocator, &adapter.abi, name, .{}).pager.?;
        var rules = [_]vfs.FaultRule{.{ .method = case[0], .code = case[1] }};
        var faults = vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        try std.testing.expectEqual(ResultCode.fromC(case[1]), pager.beginRead());
        memory.faults = null;
        try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
        const page = pager.getPage(1, false).page.?;
        try std.testing.expectEqual(@as(u32, 5), readUserVersion(page.data));
        try std.testing.expectEqual(ResultCode.ok, pager.release(page));
        try std.testing.expectEqual(ResultCode.ok, pager.close());
    }
    const write_cases = [_]struct { vfs.Method, c_int }{
        .{ .shm_lock, vfs.IOERR_SHMLOCK },
        .{ .write, vfs.IOERR_WRITE },
        .{ .truncate, vfs.IOERR_TRUNCATE },
        .{ .sync, vfs.IOERR_FSYNC },
    };
    for (write_cases, 0..) |case, index| {
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var adapter = vfs.AbiAdapter.init("pager-wal-write-fault", &memory);
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "wal-write-fault-{d}.db", .{index});
        try createCommittedWal(&memory, &adapter, name, source);
        var pager = Pager.open(std.testing.allocator, &adapter.abi, name, .{ .writable = true }).pager.?;
        try std.testing.expectEqual(ResultCode.ok, pager.beginRead());
        var rules = [_]vfs.FaultRule{.{ .method = case[0], .code = case[1] }};
        var faults = vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        var rc = pager.beginWrite();
        if (rc == .ok) {
            const page = pager.getPage(1, false).page.?;
            rc = pager.makeWritable(page);
            if (rc == .ok) writeUserVersion(page.data, 6);
            _ = pager.release(page);
            if (rc == .ok) rc = pager.commitPhaseOne();
        }
        try std.testing.expectEqual(ResultCode.fromC(case[1]), rc);
        memory.faults = null;
        try std.testing.expectEqual(ResultCode.ok, pager.rollback());
        try std.testing.expectEqual(ResultCode.ok, pager.beginWrite());
        const page = pager.getPage(1, false).page.?;
        try std.testing.expectEqual(ResultCode.ok, pager.makeWritable(page));
        writeUserVersion(page.data, 7);
        try std.testing.expectEqual(ResultCode.ok, pager.release(page));
        try std.testing.expectEqual(ResultCode.ok, pager.commit());
        try std.testing.expectEqual(ResultCode.ok, pager.close());
    }
}

test "malformed WAL is rejected and external change invalidates cache" {
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "wal.db", fixture);
    try installFile(&memory, "wal.db-wal", "wal-present");
    var adapter = vfs.AbiAdapter.init("pager-wal", &memory);
    const wal_outcome = Pager.open(std.testing.allocator, &adapter.abi, "wal.db", .{});
    var wal_pager = wal_outcome.pager.?;
    try std.testing.expectEqual(ResultCode.corrupt, wal_pager.beginRead());
    try std.testing.expectEqual(State.open, wal_pager.state);
    try std.testing.expectEqual(ResultCode.ok, wal_pager.close());

    try installFile(&memory, "change.db", fixture);
    const change_outcome = Pager.open(std.testing.allocator, &adapter.abi, "change.db", .{});
    var change_pager = change_outcome.pager.?;
    try std.testing.expectEqual(ResultCode.ok, change_pager.beginRead());
    const first = change_pager.getPage(1, false).page.?;
    try std.testing.expectEqual(ResultCode.ok, change_pager.release(first));
    try std.testing.expectEqual(ResultCode.ok, change_pager.endRead());
    try std.testing.expectEqual(@as(usize, 1), change_pager.cachePages());

    const writer_open = memory.open("change.db", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB);
    const writer = writer_open.file.?;
    const changed: [16]u8 = .{0xa5} ** 16;
    try std.testing.expectEqual(vfs.OK, writer.write(&changed, 24));
    try std.testing.expectEqual(vfs.OK, writer.sync());
    try std.testing.expectEqual(vfs.OK, memory.closeAndDestroy(writer));
    try std.testing.expectEqual(ResultCode.ok, change_pager.beginRead());
    try std.testing.expectEqual(@as(usize, 0), change_pager.cachePages());
    try std.testing.expectEqual(ResultCode.ok, change_pager.close());
}

fn allocationExercise(allocator: std.mem.Allocator, adapter: *vfs.AbiAdapter) !void {
    const outcome = Pager.open(allocator, &adapter.abi, "oom.db", .{ .max_cached_pages = 2 });
    if (outcome.result == .no_memory) return error.OutOfMemory;
    if (outcome.result != .ok) return error.UnexpectedResult;
    var pager = outcome.pager.?;
    defer {
        if (pager.state != .closed) _ = pager.close();
    }
    const begin_rc = pager.beginRead();
    if (begin_rc == .no_memory) return error.OutOfMemory;
    if (begin_rc != .ok) return error.UnexpectedResult;
    const fetched = pager.getPage(1, false);
    if (fetched.result == .no_memory) return error.OutOfMemory;
    if (fetched.result != .ok) return error.UnexpectedResult;
    _ = pager.release(fetched.page.?);
    if (pager.endRead() != .ok) return error.UnexpectedResult;
    if (pager.close() != .ok) return error.UnexpectedResult;
}

fn stickyAllocationExercise(allocator: std.mem.Allocator) !void {
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    try installFile(&memory, "oom.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-sticky-oom", &memory);
    try allocationExercise(allocator, &adapter);
}

fn walAllocationExercise(allocator: std.mem.Allocator, adapter: *vfs.AbiAdapter) !void {
    const outcome = Pager.open(allocator, &adapter.abi, "wal-oom.db", .{ .writable = true });
    if (outcome.result == .no_memory) return error.OutOfMemory;
    if (outcome.result != .ok) return error.UnexpectedResult;
    var pager = outcome.pager.?;
    defer {
        if (pager.state != .closed) _ = pager.close();
    }
    var rc = pager.beginRead();
    if (rc == .no_memory) return error.OutOfMemory;
    if (rc != .ok) return error.UnexpectedResult;
    rc = pager.beginWrite();
    if (rc != .ok) return error.UnexpectedResult;
    const fetched = pager.getPage(1, false);
    if (fetched.result == .no_memory) return error.OutOfMemory;
    if (fetched.result != .ok) return error.UnexpectedResult;
    const page = fetched.page.?;
    rc = pager.makeWritable(page);
    if (rc != .ok) return error.UnexpectedResult;
    writeUserVersion(page.data, 99);
    _ = pager.release(page);
    rc = pager.commitPhaseOne();
    if (rc == .no_memory) return error.OutOfMemory;
    if (rc != .ok) return error.UnexpectedResult;
    if (pager.commitPhaseTwo() != .ok or pager.close() != .ok) return error.UnexpectedResult;
}

fn writerAllocationExercise(allocator: std.mem.Allocator, adapter: *vfs.AbiAdapter) !void {
    const outcome = Pager.open(allocator, &adapter.abi, "writer-oom.db", .{ .writable = true, .max_cached_pages = 4 });
    if (outcome.result == .no_memory) return error.OutOfMemory;
    if (outcome.result != .ok) return error.UnexpectedResult;
    var pager = outcome.pager.?;
    defer {
        if (pager.state != .closed) _ = pager.close();
    }
    if (pager.beginRead() != .ok or pager.beginWrite() != .ok) return error.UnexpectedResult;
    const fetched = pager.getPage(1, false);
    if (fetched.result == .no_memory) return error.OutOfMemory;
    if (fetched.result != .ok) return error.UnexpectedResult;
    const page = fetched.page.?;
    const writable = pager.makeWritable(page);
    if (writable == .no_memory) {
        _ = pager.release(page);
        return error.OutOfMemory;
    }
    if (writable != .ok) return error.UnexpectedResult;
    writeUserVersion(page.data, 4321);
    _ = pager.release(page);
    const first = pager.commitPhaseOne();
    if (first == .no_memory) return error.OutOfMemory;
    if (first != .ok) return error.UnexpectedResult;
    if (pager.commitPhaseTwo() != .ok) return error.UnexpectedResult;
    if (pager.close() != .ok) return error.UnexpectedResult;
}

fn stickyWriterAllocationExercise(allocator: std.mem.Allocator) !void {
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    try installFile(&memory, "writer-oom.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-writer-oom", &memory);
    try writerAllocationExercise(allocator, &adapter);
}

test "bounded sticky and one-shot allocation failure preserves ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        stickyWriterAllocationExercise,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        stickyAllocationExercise,
        .{},
    );
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(fixture);
    try installFile(&memory, "oom.db", fixture);
    var adapter = vfs.AbiAdapter.init("pager-oom", &memory);

    var completed = false;
    for (0..128) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        allocationExercise(failing.allocator(), &adapter) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
        };
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);

    const wal_fixture = try readFixture("valid-empty-4096.db");
    defer std.testing.allocator.free(wal_fixture);
    const wal_bytes = try std.testing.allocator.dupe(u8, wal_fixture);
    defer std.testing.allocator.free(wal_bytes);
    wal_bytes[18] = 2;
    wal_bytes[19] = 2;
    var wal_memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer wal_memory.deinit();
    try installFile(&wal_memory, "wal-oom.db", wal_bytes);
    var wal_adapter = vfs.AbiAdapter.init("pager-wal-oom", &wal_memory);
    var wal_completed = false;
    for (0..256) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        walAllocationExercise(failing.allocator(), &wal_adapter) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
        };
        if (!failing.induced_failure) {
            wal_completed = true;
            break;
        }
    }
    try std.testing.expect(wal_completed);
}
