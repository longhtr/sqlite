//! Source-shaped pager journal, savepoint, locking, spill, and mapping primitives.
const std = @import("std");

pub const Error = error{ Io, NoMemory, Range, Busy, Corrupt, Done, ReadOnly, Full };
pub const LockingMode = enum(u1) { normal, exclusive };
pub const LockLevel = enum(u3) { none, shared, reserved, pending, exclusive, unknown };
pub const PagerState = enum(u3) { open, reader, writer_locked, writer_cache_modified, writer_database_modified, writer_finished, failed };
pub const JournalMode = enum(u3) { delete, persist, off, truncate, memory, wal };
pub const Getter = enum { normal, mapped, failed };
pub const Savepoint = struct {
    pages: []bool,
    original_pages: u32 = 0,
    journal_offset: u64 = 0,
    header_offset: u64 = 0,
    subjournal_record: usize = 0,
    truncate_on_release: bool = true,
};
pub const Page = struct {
    number: u32 = 0,
    dirty: bool = false,
    writeable: bool = false,
    dont_write: bool = false,
    need_sync: bool = false,
    mapped: bool = false,
    referenced: bool = false,
    hash: u64 = 0,
};

pub const CachedPage = struct {
    page: Page,
    data: []u8,
    references: usize = 1,
};
pub const SyncFlags = packed struct(u8) {
    level: u2 = 1,
    full_fsync: bool = false,
    checkpoint_full_fsync: bool = false,
    cache_spill: bool = true,
    reserved: u3 = 0,
};
pub const LockAttempt = *const fn (?*anyopaque, LockLevel) Error!void;
pub const BusyHandler = *const fn (?*anyopaque, usize) bool;
pub const SavepointOperation = enum { release, rollback };
pub const JournalMagic = [8]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };

pub const Pager = struct {
    allocator: std.mem.Allocator,
    journal_offset: u64 = 0,
    journal_header: u64 = 0,
    journal_size: u64 = 0,
    journal_size_limit: i64 = -1,
    sector_size: u32 = 512,
    page_size: u32 = 4096,
    reserve_bytes: u16 = 0,
    maximum_pages: u32 = std.math.maxInt(u32),
    database_pages: u32 = 0,
    original_pages: u32 = 0,
    file_pages: u32 = 0,
    no_sync: bool = false,
    full_sync: bool = false,
    extra_sync: bool = false,
    temporary: bool = false,
    read_only: bool = false,
    exclusive: bool = false,
    no_lock: bool = false,
    file_open: bool = true,
    journal_enabled: bool = true,
    journal_open: bool = false,
    subjournal_open: bool = false,
    subjournal_records: usize = 0,
    journal_records: u32 = 0,
    checksum_initial: u32 = 0,
    data_version: u64 = 0,
    mmap_size: u64 = 0,
    mapped_pages: usize = 0,
    use_fetch: bool = false,
    getter_generation: usize = 0,
    getter: Getter = .normal,
    state: PagerState = .open,
    busy_handler: ?BusyHandler = null,
    busy_context: ?*anyopaque = null,
    lock_level: LockLevel = .none,
    journal_mode: JournalMode = .delete,
    error_code: ?Error = null,
    change_count_done: bool = false,
    set_super_journal: bool = false,
    wal_open: bool = false,
    wal_exists: bool = false,
    database_moved: bool = false,
    device_safe_append: bool = false,
    device_atomic: bool = false,
    dirty_cache: bool = false,
    spill_disabled: bool = false,
    sync_flags: u8 = 0,
    wal_sync_flags: u8 = 0,
    stats: [4]u64 = .{ 0, 0, 0, 0 },
    journal: std.ArrayList(u8) = .empty,
    subjournal: std.ArrayList(u8) = .empty,
    database: std.ArrayList(u8) = .empty,
    savepoints: std.ArrayList(Savepoint) = .empty,
    journaled_pages: ?[]bool = null,
    cache: std.ArrayList(*CachedPage) = .empty,
    closed: bool = false,

    pub fn deinit(self: *Pager) void {
        if (self.closed) return;
        releaseAllSavepoints(self);
        self.savepoints.deinit(self.allocator);
        self.journal.deinit(self.allocator);
        self.subjournal.deinit(self.allocator);
        self.database.deinit(self.allocator);
        if (self.journaled_pages) |pages| self.allocator.free(pages);
        for (self.cache.items) |cached| {
            self.allocator.free(cached.data);
            self.allocator.destroy(cached);
        }
        self.cache.deinit(self.allocator);
        self.closed = true;
    }
};

fn putU32(output: []u8, value: u32) void {
    std.mem.writeInt(u32, output[0..4], value, .big);
}

fn getU32(input: []const u8) u32 {
    return std.mem.readInt(u32, input[0..4], .big);
}

fn resizeZero(list: *std.ArrayList(u8), allocator: std.mem.Allocator, size: usize) Error!void {
    const old = list.items.len;
    list.resize(allocator, size) catch return error.NoMemory;
    if (size > old) @memset(list.items[old..], 0);
}

/// Source `journalHdrOffset()`.
pub fn journalHeaderOffset(pager: *const Pager) u64 {
    if (pager.journal_offset == 0) return 0;
    const header_size = @max(@as(u64, pager.sector_size), 512);
    return ((pager.journal_offset - 1) / header_size + 1) * header_size;
}

/// Source `pagerSyncHotJournal()`.
pub fn syncHotJournal(pager: *Pager, sync: ?*const fn () bool) Error!void {
    if (!pager.no_sync and sync != null and !sync.?()) return error.Io;
    pager.journal_header = pager.journal_size;
}

/// Source `releaseAllSavepoints()`.
pub fn releaseAllSavepoints(pager: *Pager) void {
    for (pager.savepoints.items) |savepoint| pager.allocator.free(savepoint.pages);
    pager.savepoints.clearRetainingCapacity();
    if (!pager.exclusive) pager.subjournal_open = false;
    pager.subjournal.clearRetainingCapacity();
    pager.subjournal_records = 0;
}

/// Source `sqlite3PagerDontWrite()`.
pub fn dontWrite(pager: *const Pager, page: *Page) void {
    if (!pager.temporary and page.dirty and pager.savepoints.items.len == 0) {
        page.dont_write = true;
        page.writeable = false;
        page.hash = if (page.hash == 0) 1 else page.hash;
    }
}

/// Source `sqlite3PagerLockingMode()`.
pub fn lockingMode(pager: *Pager, requested: ?LockingMode, wal_uses_heap: bool) LockingMode {
    if (requested) |mode| {
        if (!pager.temporary and !wal_uses_heap) pager.exclusive = mode == .exclusive;
    }
    return if (pager.exclusive) .exclusive else .normal;
}

/// Source `sqlite3PagerMaxPageCount()`.
pub fn maxPageCount(pager: *Pager, requested: u32) u32 {
    if (requested != 0) pager.maximum_pages = @max(requested, pager.database_pages);
    return pager.maximum_pages;
}

/// Source `sqlite3PagerOpenSavepoint()`.
pub fn openSavepoints(pager: *Pager, requested: usize) Error!void {
    if (!pager.journal_enabled or requested <= pager.savepoints.items.len) return;
    while (pager.savepoints.items.len < requested) {
        const pages = pager.allocator.alloc(bool, @as(usize, pager.database_pages) + 1) catch return error.NoMemory;
        errdefer pager.allocator.free(pages);
        @memset(pages, false);
        pager.savepoints.append(pager.allocator, .{
            .pages = pages,
            .original_pages = pager.database_pages,
            .journal_offset = if (pager.journal_offset > 0) pager.journal_offset else @max(@as(u64, pager.sector_size), 512),
            .subjournal_record = pager.subjournal_records,
        }) catch return error.NoMemory;
    }
    pager.subjournal_open = true;
}

/// Source `pagerFixMaplimit()`.
pub fn fixMapLimit(pager: *Pager, file_open: bool, method_version: u8, accepted_size: ?*u64) void {
    if (!file_open or method_version < 3) return;
    pager.use_fetch = pager.mmap_size > 0;
    pager.getter_generation += 1;
    if (accepted_size) |size| size.* = pager.mmap_size;
}

/// Source `subjRequiresPage()`.
pub fn subjournalRequiresPage(pager: *Pager, page_number: u32) bool {
    for (pager.savepoints.items, 0..) |savepoint, index| {
        if (savepoint.original_pages >= page_number and page_number < savepoint.pages.len and !savepoint.pages[page_number]) {
            for (pager.savepoints.items[index + 1 ..]) |*later| later.truncate_on_release = false;
            return true;
        }
    }
    return false;
}

/// Source `sqlite3PagerDirectReadOk()`.
pub fn directReadOk(pager: *const Pager, page_number: u32, wal_frame: ?u32, subpage_reads: bool) bool {
    if (!pager.file_open or pager.dirty_cache or !subpage_reads) return false;
    if (wal_frame != null and wal_frame.? != 0 and page_number != 0) return false;
    return true;
}

/// Source `setGetterMethod()`.
pub fn setGetterMethod(pager: *Pager) void {
    pager.getter = if (pager.error_code != null) .failed else if (pager.use_fetch) .mapped else .normal;
    pager.getter_generation += 1;
}

/// Source `pagerUnlockDb()`.
pub fn unlockDatabase(pager: *Pager, level: LockLevel, attempt: ?LockAttempt, context: ?*anyopaque) Error!void {
    if (level != .none and level != .shared) return error.Range;
    if (pager.file_open and !pager.no_lock and attempt != null) try attempt.?(context, level);
    if (pager.lock_level != .unknown) pager.lock_level = level;
    pager.change_count_done = pager.temporary;
}

/// Source `pagerLockDb()`.
pub fn lockDatabase(pager: *Pager, level: LockLevel, attempt: ?LockAttempt, context: ?*anyopaque) Error!void {
    if (level != .shared and level != .reserved and level != .exclusive) return error.Range;
    if (@intFromEnum(pager.lock_level) < @intFromEnum(level) or pager.lock_level == .unknown) {
        if (!pager.no_lock and attempt != null) try attempt.?(context, level);
        if (pager.lock_level != .unknown or level == .exclusive) pager.lock_level = level;
    }
}

/// Source `jrnlBufferSize()`.
pub fn journalBufferSize(pager: *const Pager) i32 {
    if (pager.device_atomic and pager.database_pages > 0) return -1;
    if (pager.device_atomic and pager.sector_size <= pager.page_size) {
        return @intCast(@max(pager.sector_size, 512) + pager.page_size + 8);
    }
    return 0;
}

/// Source `readSuperJournal()`.
pub fn readSuperJournal(bytes: []const u8, maximum: usize, output: []u8) Error!?[]const u8 {
    if (bytes.len < 16) return null;
    const length = getU32(bytes[bytes.len - 16 ..][0..4]);
    const checksum = getU32(bytes[bytes.len - 12 ..][0..4]);
    if (length == 0 or length >= maximum or length > bytes.len - 16 or !std.mem.eql(u8, bytes[bytes.len - 8 ..], &JournalMagic)) return null;
    if (length > output.len) return error.Range;
    const start = bytes.len - 16 - length;
    @memcpy(output[0..length], bytes[start .. start + length]);
    var sum = checksum;
    for (output[0..length]) |byte| sum -%= byte;
    if (sum != 0 or output[0] == 0) return null;
    return output[0..length];
}

/// Source `zeroJournalHdr()`.
pub fn zeroJournalHeader(pager: *Pager, truncate: bool) Error!void {
    if (!pager.journal_open or pager.journal_offset == 0) return;
    if (truncate or pager.journal_size_limit == 0) {
        pager.journal.clearRetainingCapacity();
    } else {
        try resizeZero(&pager.journal, pager.allocator, @max(pager.journal.items.len, 28));
        @memset(pager.journal.items[0..28], 0);
    }
    if (pager.journal_size_limit > 0 and pager.journal.items.len > pager.journal_size_limit) {
        pager.journal.shrinkRetainingCapacity(@intCast(pager.journal_size_limit));
    }
}

/// Source `writeSuperJournal()`.
pub fn writeSuperJournal(pager: *Pager, name: ?[]const u8) Error!void {
    const value = name orelse return;
    if (pager.journal_mode == .memory or !pager.journal_open) return;
    pager.set_super_journal = true;
    if (pager.full_sync) pager.journal_offset = journalHeaderOffset(pager);
    const start: usize = @intCast(pager.journal_offset);
    try resizeZero(&pager.journal, pager.allocator, start + value.len + 20);
    putU32(pager.journal.items[start..][0..4], std.math.maxInt(u32));
    @memcpy(pager.journal.items[start + 4 .. start + 4 + value.len], value);
    putU32(pager.journal.items[start + 4 + value.len ..][0..4], @intCast(value.len));
    var checksum: u32 = 0;
    for (value) |byte| checksum +%= byte;
    putU32(pager.journal.items[start + 8 + value.len ..][0..4], checksum);
    @memcpy(pager.journal.items[start + 12 + value.len ..][0..8], &JournalMagic);
    pager.journal_offset += value.len + 20;
    pager.journal.shrinkRetainingCapacity(@intCast(pager.journal_offset));
}

/// Source `addToSavepointBitvecs()`.
pub fn addToSavepointBitvectors(pager: *Pager, page_number: u32) Error!void {
    for (pager.savepoints.items) |*savepoint| {
        if (page_number <= savepoint.original_pages) {
            if (page_number >= savepoint.pages.len) return error.Range;
            savepoint.pages[page_number] = true;
        }
    }
}

/// Source `pager_error()`.
pub fn recordError(pager: *Pager, value: Error) Error {
    if (value == error.Full or value == error.Io) {
        pager.error_code = value;
        pager.state = .failed;
        setGetterMethod(pager);
    }
    return value;
}

/// Source `pagerUnlockAndRollback()`.
pub fn unlockAndRollback(pager: *Pager) void {
    if (pager.state != .open and pager.state != .failed) {
        pager.database_pages = pager.original_pages;
        pager.dirty_cache = false;
    }
    pager.state = .open;
    pager.lock_level = .none;
    pager.journal_open = false;
}

/// Source `pagerIsSuperJrnlName()`.
pub fn isSuperJournalName(name: []const u8) bool {
    if (name.len >= 12 and std.mem.eql(u8, name[name.len - 12 .. name.len - 9], "-mj")) {
        for (name[name.len - 9 ..]) |byte| {
            if (!std.ascii.isHex(byte)) return false;
        }
        return true;
    }
    if (name.len >= 4 and name[name.len - 4] == '.' and name[name.len - 3] == '9') {
        return std.ascii.isHex(name[name.len - 2]) and std.ascii.isHex(name[name.len - 1]);
    }
    return false;
}

/// Source `pager_delsuper()`.
pub fn deleteSuperJournal(name: []const u8, own_journal: []const u8, children: []const []const u8, child_super_names: []const ?[]const u8) bool {
    if (!isSuperJournalName(name)) return false;
    var own_seen = false;
    for (children, 0..) |child, index| {
        if (std.mem.eql(u8, child, own_journal)) {
            own_seen = true;
        } else if (index < child_super_names.len) {
            if (child_super_names[index]) |super_name| if (std.mem.eql(u8, super_name, name)) return false;
        }
    }
    return own_seen;
}

/// Source `pager_truncate()`.
pub fn truncateDatabase(pager: *Pager, pages: u32) Error!void {
    const bytes = std.math.mul(usize, pages, pager.page_size) catch return error.Full;
    try resizeZero(&pager.database, pager.allocator, bytes);
    pager.file_pages = pages;
}

/// Source `readDbPage()`.
pub fn readDatabasePage(pager: *Pager, page_number: u32, wal_data: ?[]const u8, output: []u8) Error!void {
    if (output.len != pager.page_size or page_number == 0) return error.Range;
    if (wal_data) |data| {
        if (data.len != output.len) return error.Range;
        @memcpy(output, data);
    } else {
        const start = std.math.mul(usize, page_number - 1, pager.page_size) catch return error.Full;
        if (start >= pager.database.items.len) @memset(output, 0) else {
            const count = @min(output.len, pager.database.items.len - start);
            @memcpy(output[0..count], pager.database.items[start .. start + count]);
            if (count < output.len) @memset(output[count..], 0);
        }
    }
    pager.stats[1] += 1;
}

/// Source `pagerUndoCallback()`.
pub fn undoPage(pager: *Pager, page: *Page, restored: bool) void {
    if (!page.referenced) page.dirty = false else page.writeable = restored;
    pager.dirty_cache = pager.dirty_cache and page.dirty;
}

/// Source `pagerRollbackWal()`.
pub fn rollbackWal(pager: *Pager, pages: []Page) void {
    pager.database_pages = pager.original_pages;
    for (pages) |*page| undoPage(pager, page, true);
}

/// Source `pagerWalFrames()`.
pub fn walFrames(pager: *Pager, pages: []Page, truncate_to: u32, commit: bool) usize {
    var count: usize = 0;
    for (pages) |*page| {
        if (!commit or page.number <= truncate_to) {
            page.dirty = false;
            count += 1;
        }
    }
    pager.stats[2] += count;
    if (commit) pager.database_pages = truncate_to;
    return count;
}

/// Source `pagerOpenWalIfPresent()`.
pub fn openWalIfPresent(pager: *Pager) void {
    if (pager.temporary) return;
    if (pager.wal_exists and pager.database_pages == 0) pager.wal_exists = false else if (pager.wal_exists) pager.wal_open = true else if (pager.journal_mode == .wal) pager.journal_mode = .delete;
}

/// Source `pagerPlaybackSavepoint()`.
pub fn playbackSavepoint(pager: *Pager, index: ?usize) Error!void {
    if (index) |value| {
        if (value >= pager.savepoints.items.len) return error.Range;
        const savepoint = &pager.savepoints.items[value];
        pager.database_pages = savepoint.original_pages;
        pager.journal_offset = @max(pager.journal_offset, savepoint.journal_offset);
        pager.subjournal_records = savepoint.subjournal_record;
    } else {
        pager.database_pages = pager.original_pages;
        if (pager.wal_open) pager.dirty_cache = false;
    }
    pager.change_count_done = pager.temporary;
}

/// Source `sqlite3PagerSetFlags()`.
pub fn setFlags(pager: *Pager, flags: SyncFlags) void {
    if (pager.temporary or flags.level == 0) {
        pager.no_sync = true;
        pager.full_sync = false;
        pager.extra_sync = false;
    } else {
        pager.no_sync = false;
        pager.full_sync = flags.level >= 2;
        pager.extra_sync = flags.level == 3;
    }
    pager.sync_flags = if (pager.no_sync) 0 else if (flags.full_fsync) 3 else 2;
    pager.wal_sync_flags = pager.sync_flags << 2;
    if (pager.full_sync) pager.wal_sync_flags |= pager.sync_flags;
    if (flags.checkpoint_full_fsync and !pager.no_sync) pager.wal_sync_flags |= 3 << 2;
    pager.spill_disabled = !flags.cache_spill;
}

/// Source `pagerOpentemp()`.
pub fn openTemporary(pager: *Pager) void {
    pager.temporary = true;
    pager.file_open = true;
    pager.no_lock = true;
}

/// Source `sqlite3PagerSetPagesize()`.
pub fn setPageSize(pager: *Pager, requested: u32, reserve: i32, references: usize) Error!u32 {
    if (requested != 0 and (requested < 512 or requested > 65_536 or !std.math.isPowerOfTwo(requested))) return error.Range;
    if (requested != 0 and requested != pager.page_size and references == 0 and (pager.database_pages == 0 or !pager.temporary)) {
        pager.page_size = requested;
        pager.database_pages = @intCast((pager.database.items.len + requested - 1) / requested);
    }
    if (reserve >= 0) {
        if (reserve >= 1000) return error.Range;
        pager.reserve_bytes = @intCast(reserve);
    }
    return pager.page_size;
}

/// Source `pager_wait_on_lock()`.
pub fn waitOnLock(pager: *Pager, level: LockLevel, attempt: LockAttempt, context: ?*anyopaque, busy: ?BusyHandler) Error!void {
    var retries: usize = 0;
    while (true) {
        lockDatabase(pager, level, attempt, context) catch |failure| {
            if (failure != error.Busy or busy == null or !busy.?(context, retries)) return failure;
            retries += 1;
            continue;
        };
        return;
    }
}

/// Source `pagerAcquireMapPage()`.
pub fn acquireMappedPage(pager: *Pager, page: *Page, page_number: u32) void {
    page.* = .{ .number = page_number, .mapped = true, .referenced = true };
    pager.mapped_pages += 1;
}

/// Source `databaseIsUnmoved()`.
pub fn databaseIsUnmoved(pager: *const Pager, control_supported: bool) Error!void {
    if (pager.temporary or pager.database_pages == 0 or !control_supported) return;
    if (pager.database_moved) return error.ReadOnly;
}

/// Source `pager_write_pagelist()`.
pub fn writePageList(pager: *Pager, pages: []Page, data: []const []const u8) Error!void {
    for (pages, 0..) |*page, index| {
        if (page.number == 0 or page.number > pager.database_pages or page.dont_write) continue;
        if (index >= data.len or data[index].len != pager.page_size) return error.Range;
        const start = std.math.mul(usize, page.number - 1, pager.page_size) catch return error.Full;
        try resizeZero(&pager.database, pager.allocator, start + pager.page_size);
        @memcpy(pager.database.items[start .. start + pager.page_size], data[index]);
        page.hash = std.hash.Wyhash.hash(0, data[index]);
        pager.file_pages = @max(pager.file_pages, page.number);
        pager.stats[2] += 1;
    }
}

/// Source `openSubJournal()`.
pub fn openSubJournal(pager: *Pager) void {
    if (!pager.subjournal_open) pager.subjournal_open = true;
}

/// Source `subjournalPage()`.
pub fn subjournalPage(pager: *Pager, page_number: u32, data: []const u8) Error!void {
    if (pager.journal_mode != .off) {
        if (data.len != pager.page_size) return error.Range;
        openSubJournal(pager);
        const offset = pager.subjournal_records * (pager.page_size + 4);
        try resizeZero(&pager.subjournal, pager.allocator, offset + pager.page_size + 4);
        putU32(pager.subjournal.items[offset..][0..4], page_number);
        @memcpy(pager.subjournal.items[offset + 4 .. offset + 4 + pager.page_size], data);
    }
    pager.subjournal_records += 1;
    try addToSavepointBitvectors(pager, page_number);
}

/// Source `pagerStress()`.
pub fn stressPage(pager: *Pager, page: *Page, data: []const u8) Error!void {
    if (pager.error_code != null or pager.spill_disabled or !page.dirty) return;
    pager.stats[3] += 1;
    if (pager.wal_open) {
        if (subjournalRequiresPage(pager, page.number)) try subjournalPage(pager, page.number, data);
        _ = walFrames(pager, @as(*[1]Page, page)[0..], 0, false);
    } else {
        try writePageList(pager, @as(*[1]Page, page)[0..], &.{data});
    }
    page.dirty = false;
}

/// Source `sqlite3PagerFlush()`.
pub fn flush(pager: *Pager, pages: []Page, data: []const []const u8) Error!void {
    if (pager.error_code) |failure| return failure;
    for (pages, 0..) |*page, index| {
        if (page.dirty and !page.referenced) {
            if (index >= data.len) return error.Range;
            try stressPage(pager, page, data[index]);
        }
    }
}

/// Source `getPageMMap()`.
pub fn getMappedPage(pager: *Pager, page: *Page, page_number: u32, readonly: bool, wal_frame: ?u32) bool {
    if (!pager.use_fetch or page_number <= 1 or (!readonly and pager.state != .reader) or (wal_frame != null and wal_frame.? != 0)) return false;
    acquireMappedPage(pager, page, page_number);
    return true;
}

/// Source `getPageError()`.
pub fn getPageError(pager: *const Pager, output: *?*Page) Error!void {
    output.* = null;
    if (pager.error_code) |failure| return failure;
    return error.Corrupt;
}

/// Source `pagerWriteLargeSector()`.
pub fn writeLargeSector(pager: *Pager, pages: []Page, target: usize) Error!void {
    if (target >= pages.len or pager.page_size == 0) return error.Range;
    const per_sector = @max(@as(usize, 1), pager.sector_size / pager.page_size);
    const first = target - target % per_sector;
    const end = @min(pages.len, first + per_sector);
    var needs_sync = false;
    for (pages[first..end]) |page| needs_sync = needs_sync or page.need_sync;
    for (pages[first..end]) |*page| {
        page.dirty = true;
        page.writeable = true;
        if (needs_sync) page.need_sync = true;
    }
}

/// Source `sqlite3PagerExclusiveLock()`.
pub fn exclusiveLock(pager: *Pager, attempt: ?LockAttempt, context: ?*anyopaque) Error!void {
    if (pager.error_code) |failure| return failure;
    if (!pager.wal_open) try lockDatabase(pager, .exclusive, attempt, context);
}

/// Source `sqlite3PagerCacheStat()`.
pub fn cacheStat(pager: *Pager, statistic: usize, reset: bool, total: *u64) Error!void {
    if (statistic >= pager.stats.len) return error.Range;
    total.* += pager.stats[statistic];
    if (reset) pager.stats[statistic] = 0;
}

/// Source `pagerExclusiveLock()`.
pub fn exclusiveLockRecovering(pager: *Pager, attempt: LockAttempt, context: ?*anyopaque) Error!void {
    const original = pager.lock_level;
    lockDatabase(pager, .exclusive, attempt, context) catch |failure| {
        pager.lock_level = original;
        return failure;
    };
}

/// Source `sqlite3PagerMovepage()`.
pub fn movePage(pager: *Pager, pages: []Page, source_index: usize, destination_number: u32, commit: bool, source_data: []const u8) Error!void {
    if (source_index >= pages.len or destination_number == 0) return error.Range;
    const source = &pages[source_index];
    if (source.dirty and subjournalRequiresPage(pager, source.number)) try subjournalPage(pager, source.number, source_data);
    const original_number = source.number;
    const preserve_sync = source.need_sync and !commit;
    for (pages, 0..) |*page, index| {
        if (index == source_index or page.number != destination_number) continue;
        source.need_sync = source.need_sync or page.need_sync;
        if (pager.temporary) page.number = pager.database_pages + 1 else page.* = .{};
        break;
    }
    source.number = destination_number;
    source.dirty = true;
    source.writeable = true;
    if (preserve_sync) {
        for (pages) |*page| {
            if (page.number == original_number) {
                page.need_sync = true;
                page.dirty = true;
                break;
            }
        }
    }
}

/// Source `sqlite3PagerSavepoint()`.
pub fn operateSavepoint(pager: *Pager, operation: SavepointOperation, index: isize) Error!void {
    if (pager.error_code) |failure| return failure;
    if (index >= @as(isize, @intCast(pager.savepoints.items.len))) return;
    const remaining: usize = if (operation == .release) @intCast(@max(index, 0)) else @intCast(index + 1);
    if (operation == .release and remaining < pager.savepoints.items.len) {
        const released = pager.savepoints.items[remaining];
        if (released.truncate_on_release and pager.subjournal_open) {
            const size = released.subjournal_record * (pager.page_size + 4);
            if (size < pager.subjournal.items.len) pager.subjournal.shrinkRetainingCapacity(size);
            pager.subjournal_records = released.subjournal_record;
        }
    } else if (operation == .rollback) {
        try playbackSavepoint(pager, if (remaining == 0) null else remaining - 1);
    }
    var position = remaining;
    while (position < pager.savepoints.items.len) : (position += 1) pager.allocator.free(pager.savepoints.items[position].pages);
    pager.savepoints.shrinkRetainingCapacity(remaining);
}

/// Source `sqlite3PagerSetJournalMode()`.
pub fn setJournalMode(pager: *Pager, requested: JournalMode, memory_database: bool) JournalMode {
    var mode = requested;
    if (pager.temporary and mode == .wal) mode = pager.journal_mode;
    if (memory_database and mode != .memory and mode != .off) mode = pager.journal_mode;
    const old = pager.journal_mode;
    if (old != mode) {
        pager.journal_mode = mode;
        const old_persistent = old == .truncate or old == .persist;
        if (!pager.exclusive and old_persistent and mode != .persist and mode != .truncate and mode != .wal) {
            pager.journal_open = false;
            pager.journal.clearRetainingCapacity();
        } else if (mode == .off or mode == .memory) {
            pager.journal_open = false;
        }
    }
    return pager.journal_mode;
}

/// Source `sqlite3PagerTruncateImage()`.
pub fn truncateImage(pager: *Pager, page_count: u32) Error!void {
    if (page_count > pager.database_pages or @intFromEnum(pager.state) < @intFromEnum(PagerState.writer_cache_modified)) return error.Range;
    pager.database_pages = page_count;
}

/// Source `sqlite3SectorSize()`: sanitize the VFS sector-size result.
pub fn sectorSize(raw_size: u32) u32 {
    if (raw_size < 32) return 512;
    return @min(raw_size, 65_536);
}

/// Source `pagerBeginReadTransaction()`: restart the WAL snapshot and discard
/// cache state whenever the published WAL header changed.
pub fn beginReadTransaction(pager: *Pager, wal_changed: bool) Error!void {
    if (!pager.wal_open or (pager.state != .open and pager.state != .reader)) return error.Range;
    if (wal_changed) {
        for (pager.cache.items) |cached| {
            pager.allocator.free(cached.data);
            pager.allocator.destroy(cached);
        }
        pager.cache.clearRetainingCapacity();
        pager.mapped_pages = 0;
    }
    pager.state = .reader;
}

/// Source `pagerPagecount()`: prefer a committed WAL size and otherwise round
/// the database byte-size up to a page boundary.
pub fn pageCount(pager: *Pager, wal_pages: u32) Error!u32 {
    if (pager.state != .open or pager.lock_level == .none or pager.temporary) return error.Range;
    const count = if (wal_pages != 0)
        wal_pages
    else
        @as(u32, @intCast((pager.database.items.len + pager.page_size - 1) / pager.page_size));
    pager.maximum_pages = @max(pager.maximum_pages, count);
    return count;
}

/// Source `sqlite3PagerSetBusyHandler()`.
pub fn setBusyHandler(pager: *Pager, callback: ?BusyHandler, context: ?*anyopaque) void {
    pager.busy_handler = callback;
    pager.busy_context = context;
}

fn cachedPageIndex(pager: *const Pager, page_number: u32) ?usize {
    for (pager.cache.items, 0..) |cached, index| {
        if (cached.page.number == page_number) {
            return index;
        }
    }
    return null;
}

/// Source `sqlite3PagerGet()`: dispatch a cache hit or materialize the page
/// from the current database image.
pub fn getPage(pager: *Pager, page_number: u32, no_content: bool) Error!*CachedPage {
    if (page_number == 0 or page_number > pager.maximum_pages) return error.Range;
    if (pager.error_code) |failure| return failure;
    if (cachedPageIndex(pager, page_number)) |index| {
        const cached = pager.cache.items[index];
        cached.references += 1;
        cached.page.referenced = true;
        return cached;
    }
    const cached = pager.allocator.create(CachedPage) catch return error.NoMemory;
    errdefer pager.allocator.destroy(cached);
    const data = pager.allocator.alloc(u8, pager.page_size) catch return error.NoMemory;
    errdefer pager.allocator.free(data);
    if (no_content) @memset(data, 0) else try readDatabasePage(pager, page_number, null, data);
    cached.* = .{ .page = .{ .number = page_number, .referenced = true }, .data = data };
    pager.cache.append(pager.allocator, cached) catch return error.NoMemory;
    return cached;
}

/// Source `sqlite3PagerLookup()`: return only an already-cached page.
pub fn lookupPage(pager: *Pager, page_number: u32) ?*CachedPage {
    const index = cachedPageIndex(pager, page_number) orelse return null;
    const cached = pager.cache.items[index];
    cached.references += 1;
    cached.page.referenced = true;
    return cached;
}

/// Source `sqlite3PagerUnrefNotNull()`: release one page reference while
/// preserving cache ownership.
pub fn unrefPage(pager: *Pager, cached: *CachedPage) void {
    std.debug.assert(cached.references > 0);
    cached.references -= 1;
    cached.page.referenced = cached.references != 0;
    if (cached.page.mapped and cached.references == 0 and pager.mapped_pages != 0) pager.mapped_pages -= 1;
}

/// Source `sqlite3PagerSync()`.
pub fn syncDatabase(pager: *Pager, super_journal: ?[]const u8) Error!void {
    _ = super_journal;
    if (pager.error_code) |failure| return failure;
    if (!pager.no_sync and !pager.temporary and !pager.file_open) return error.Io;
    if (!pager.no_sync) pager.stats[0] += 1;
}

/// Source `pager_write_changecounter()`: update all three database-header
/// words that identify a changed image.
pub fn writeChangeCounter(page_one: []u8, prior_version: []const u8) Error!u32 {
    if (page_one.len < 100 or prior_version.len < 4) return error.Range;
    const next = getU32(prior_version[0..4]) +% 1;
    putU32(page_one[24..28], next);
    putU32(page_one[92..96], next);
    putU32(page_one[96..100], 3_050_005);
    return next;
}

/// Source `sqlite3PagerOpenWal()`.
pub fn openWal(pager: *Pager, supported: bool, already_open: *bool) Error!void {
    already_open.* = pager.temporary or pager.wal_open;
    if (already_open.*) return;
    if (!supported) return error.Io;
    pager.journal_open = false;
    pager.wal_open = true;
    pager.wal_exists = true;
    pager.journal_mode = .wal;
    pager.state = .open;
}

/// Source `sqlite3PagerCloseWal()`.
pub fn closeWal(pager: *Pager, checkpoint_succeeded: bool) Error!void {
    if (pager.journal_mode != .wal) return error.Range;
    if (!pager.wal_open and pager.wal_exists) pager.wal_open = true;
    if (pager.wal_open and !checkpoint_succeeded) return error.Busy;
    pager.wal_open = false;
    pager.wal_exists = false;
    pager.lock_level = .exclusive;
    setGetterMethod(pager);
}

/// Source `sqlite3PagerCommitPhaseTwo()`.
pub fn commitPhaseTwo(pager: *Pager) Error!void {
    if (pager.error_code) |failure| return failure;
    pager.data_version +%= 1;
    if (pager.state == .writer_locked and pager.exclusive and pager.journal_mode == .persist) {
        pager.state = .reader;
        return;
    }
    try endTransaction(pager, pager.set_super_journal, true);
}

/// Source `sqlite3PagerRollback()`.
pub fn rollbackTransaction(pager: *Pager) Error!void {
    if (pager.state == .failed) return pager.error_code orelse error.Io;
    if (@intFromEnum(pager.state) <= @intFromEnum(PagerState.reader)) return;
    if (pager.wal_open) {
        try playbackSavepoint(pager, null);
        try endTransaction(pager, pager.set_super_journal, false);
    } else if (!pager.journal_open or pager.state == .writer_locked) {
        const modified = @intFromEnum(pager.state) > @intFromEnum(PagerState.writer_locked);
        try endTransaction(pager, false, false);
        if (modified and pager.journal_mode == .off and !pager.temporary) return recordError(pager, error.Io);
    } else {
        try playbackJournal(pager, false);
    }
}

fn journalChecksum(initial: u32, data: []const u8) u32 {
    var result = initial;
    var index = data.len;
    while (index > 0) {
        index -= @min(index, 200);
        result +%= data[index];
    }
    return result;
}

/// Source `pagerAddPageToRollbackJournal()`.
pub fn addPageToRollbackJournal(pager: *Pager, page: *Page, data: []const u8) Error!void {
    if (!pager.journal_open or data.len != pager.page_size or page.number == 0) return error.Range;
    page.need_sync = true;
    const offset: usize = @intCast(pager.journal_offset);
    const record_size = pager.page_size + 8;
    try resizeZero(&pager.journal, pager.allocator, offset + record_size);
    putU32(pager.journal.items[offset..][0..4], page.number);
    @memcpy(pager.journal.items[offset + 4 .. offset + 4 + pager.page_size], data);
    putU32(pager.journal.items[offset + 4 + pager.page_size ..][0..4], journalChecksum(pager.checksum_initial, data));
    pager.journal_offset += record_size;
    pager.journal_records += 1;
    if (pager.journaled_pages) |pages| {
        if (page.number < pages.len) {
            pages[page.number] = true;
        }
    }
    try addToSavepointBitvectors(pager, page.number);
}

/// Source `sqlite3PagerClose()`: benignly roll back, release WAL and cache
/// state, and close every owned allocation.
pub fn closePager(pager: *Pager, checkpoint_on_close: bool) void {
    pager.exclusive = false;
    if (pager.wal_open and checkpoint_on_close) {
        pager.wal_exists = false;
        pager.wal_open = false;
    }
    rollbackTransaction(pager) catch {};
    pager.deinit();
}

/// Source `sqlite3PagerBegin()`.
pub fn beginWriteTransaction(pager: *Pager, exclusive_lock: bool, subjournal_in_memory: bool) Error!void {
    _ = subjournal_in_memory;
    if (pager.error_code) |failure| return failure;
    if (pager.state != .reader and pager.state != .writer_locked) return error.Range;
    if (pager.state == .reader) {
        if (pager.wal_open) {
            if (pager.read_only) return error.ReadOnly;
        } else {
            pager.lock_level = if (exclusive_lock) .exclusive else .reserved;
        }
        pager.state = .writer_locked;
        pager.original_pages = pager.database_pages;
        pager.file_pages = pager.database_pages;
        pager.journal_offset = 0;
    }
}

/// Source `pager_open_journal()`.
pub fn openRollbackJournal(pager: *Pager) Error!void {
    if (pager.state != .writer_locked) return error.Range;
    if (pager.error_code) |failure| return failure;
    if (!pager.wal_open and pager.journal_mode != .off) {
        const pages = pager.allocator.alloc(bool, @as(usize, pager.database_pages) + 1) catch return error.NoMemory;
        @memset(pages, false);
        if (pager.journaled_pages) |prior| pager.allocator.free(prior);
        pager.journaled_pages = pages;
        pager.journal_open = true;
        pager.journal_records = 0;
        pager.journal_offset = 0;
        pager.set_super_journal = false;
        pager.journal_header = 0;
        try writeJournalHeader(pager);
    }
    pager.state = .writer_cache_modified;
}

/// Source `pager_incr_changecounter()`.
pub fn incrementChangeCounter(pager: *Pager, direct: bool) Error!void {
    if (pager.state != .writer_cache_modified and pager.state != .writer_database_modified) return error.Range;
    if (pager.change_count_done or pager.database_pages == 0) return;
    const page = try getPage(pager, 1, false);
    defer unrefPage(pager, page);
    if (!direct) {
        page.page.dirty = true;
        page.page.writeable = true;
    }
    var prior: [4]u8 = undefined;
    if (page.data.len < 28) return error.Corrupt;
    @memcpy(&prior, page.data[24..28]);
    _ = try writeChangeCounter(page.data, &prior);
    if (direct) {
        try resizeZero(&pager.database, pager.allocator, pager.page_size);
        @memcpy(pager.database.items[0..pager.page_size], page.data);
        pager.stats[2] += 1;
    }
    pager.change_count_done = true;
}

/// Source `pager_unlock()`.
pub fn unlockPager(pager: *Pager) void {
    if (pager.journaled_pages) |pages| {
        pager.allocator.free(pages);
        pager.journaled_pages = null;
    }
    releaseAllSavepoints(pager);
    if (pager.wal_open) {
        pager.state = .open;
    } else if (!pager.exclusive) {
        pager.journal_open = false;
        pager.lock_level = .none;
        pager.state = .open;
    }
    if (pager.error_code != null) {
        for (pager.cache.items) |cached| {
            cached.page = .{};
        }
        pager.error_code = null;
        pager.change_count_done = pager.temporary;
        pager.state = .open;
        setGetterMethod(pager);
    }
    pager.journal_offset = 0;
    pager.journal_header = 0;
    pager.set_super_journal = false;
}

/// Source `hasHotJournal()` using the source lock, database-size, and first
/// journal-byte tests.
pub fn hotJournalExists(pager: *Pager, journal_exists: bool, reserved_lock: bool) Error!bool {
    if (!pager.journal_enabled or pager.state != .open) return error.Range;
    if (!journal_exists or reserved_lock) return false;
    const pages = (pager.database.items.len + pager.page_size - 1) / pager.page_size;
    if (pages == 0 and !pager.journal_open) {
        pager.journal.clearRetainingCapacity();
        return false;
    }
    return pager.journal.items.len != 0 and pager.journal.items[0] != 0;
}

/// Source `readJournalHdr()`.
pub fn readJournalHeader(pager: *Pager, hot: bool, record_count: *u32, database_size: *u32) Error!void {
    const header_size: usize = @intCast(@max(@as(u64, pager.sector_size), 512));
    pager.journal_offset = journalHeaderOffset(pager);
    const offset: usize = @intCast(pager.journal_offset);
    if (offset + header_size > pager.journal.items.len) return error.Done;
    if (hot or pager.journal_offset != pager.journal_header) {
        if (!std.mem.eql(u8, pager.journal.items[offset..][0..8], &JournalMagic)) return error.Done;
    }
    record_count.* = getU32(pager.journal.items[offset + 8 ..][0..4]);
    pager.checksum_initial = getU32(pager.journal.items[offset + 12 ..][0..4]);
    database_size.* = getU32(pager.journal.items[offset + 16 ..][0..4]);
    const sector = getU32(pager.journal.items[offset + 20 ..][0..4]);
    var page_size = getU32(pager.journal.items[offset + 24 ..][0..4]);
    if (page_size == 0) page_size = pager.page_size;
    if (page_size < 512 or page_size > 65_536 or !std.math.isPowerOfTwo(page_size) or sector < 32 or sector > 65_536 or !std.math.isPowerOfTwo(sector)) return error.Done;
    pager.page_size = page_size;
    pager.sector_size = sector;
    pager.journal_offset += header_size;
}

/// Source `writeJournalHdr()`.
pub fn writeJournalHeader(pager: *Pager) Error!void {
    if (!pager.journal_open) return error.Range;
    for (pager.savepoints.items) |*savepoint| {
        if (savepoint.header_offset == 0) {
            savepoint.header_offset = pager.journal_offset;
        }
    }
    pager.journal_offset = journalHeaderOffset(pager);
    pager.journal_header = pager.journal_offset;
    const header_size: usize = @intCast(@max(@as(u64, pager.sector_size), 512));
    const offset: usize = @intCast(pager.journal_offset);
    try resizeZero(&pager.journal, pager.allocator, offset + header_size);
    const header = pager.journal.items[offset .. offset + header_size];
    @memset(header, 0);
    if (pager.no_sync or pager.journal_mode == .memory or pager.device_safe_append) {
        @memcpy(header[0..8], &JournalMagic);
        putU32(header[8..12], std.math.maxInt(u32));
    }
    pager.checksum_initial = @truncate(pager.data_version *% 1_103_515_245 +% 12_345);
    putU32(header[12..16], pager.checksum_initial);
    putU32(header[16..20], pager.original_pages);
    putU32(header[20..24], pager.sector_size);
    putU32(header[24..28], pager.page_size);
    pager.journal_offset += header_size;
    pager.journal_size = @max(pager.journal_size, pager.journal_offset);
}

/// Source `pager_end_transaction()`.
pub fn endTransaction(pager: *Pager, has_super_journal: bool, commit: bool) Error!void {
    if (@intFromEnum(pager.state) < @intFromEnum(PagerState.writer_locked) and @intFromEnum(pager.lock_level) < @intFromEnum(LockLevel.reserved)) return;
    releaseAllSavepoints(pager);
    if (pager.journal_open) {
        switch (pager.journal_mode) {
            .truncate => pager.journal.clearRetainingCapacity(),
            .persist => try zeroJournalHeader(pager, has_super_journal or pager.temporary),
            .delete, .memory, .wal => {
                pager.journal_open = false;
                pager.journal.clearRetainingCapacity();
            },
            .off => {},
        }
    }
    if (pager.journaled_pages) |pages| {
        pager.allocator.free(pages);
        pager.journaled_pages = null;
    }
    pager.journal_records = 0;
    if (!pager.wal_open and commit and pager.file_pages > pager.database_pages) try truncateDatabase(pager, pager.database_pages);
    if (!pager.exclusive) pager.lock_level = .shared;
    pager.state = .reader;
    pager.set_super_journal = false;
    pager.dirty_cache = false;
}

/// Source `pager_playback_one_page()`.
pub fn playbackOnePage(pager: *Pager, offset: *usize, seen: ?[]bool, main_journal: bool, savepoint: bool) Error!bool {
    const source = if (main_journal) pager.journal.items else pager.subjournal.items;
    const trailer: usize = if (main_journal) 4 else 0;
    const record_size = 4 + pager.page_size + trailer;
    if (offset.* > source.len or record_size > source.len - offset.*) return error.Io;
    const page_number = getU32(source[offset.*..][0..4]);
    const data = source[offset.* + 4 .. offset.* + 4 + pager.page_size];
    offset.* += record_size;
    if (page_number == 0 or page_number > pager.database_pages) return false;
    if (seen) |bits| {
        if (page_number >= bits.len) return error.Range;
        if (bits[page_number]) return true;
        bits[page_number] = true;
    }
    if (main_journal and !savepoint) {
        const checksum = getU32(source[offset.* - 4 .. offset.*]);
        if (checksum != journalChecksum(pager.checksum_initial, data)) return false;
    }
    if (page_number == 1 and data.len > 20) pager.reserve_bytes = data[20];
    const database_offset = std.math.mul(usize, page_number - 1, pager.page_size) catch return error.Full;
    try resizeZero(&pager.database, pager.allocator, database_offset + pager.page_size);
    @memcpy(pager.database.items[database_offset .. database_offset + pager.page_size], data);
    if (cachedPageIndex(pager, page_number)) |index| {
        const cached = pager.cache.items[index];
        @memcpy(cached.data, data);
        cached.page.hash = std.hash.Wyhash.hash(0, data);
    }
    pager.file_pages = @max(pager.file_pages, page_number);
    return true;
}

/// Source `pager_playback()`.
pub fn playbackJournal(pager: *Pager, hot: bool) Error!void {
    if (!pager.journal_open) return error.Range;
    pager.journal_offset = 0;
    var restored: usize = 0;
    while (true) {
        var records: u32 = 0;
        var original_size: u32 = 0;
        readJournalHeader(pager, hot, &records, &original_size) catch |failure| switch (failure) {
            error.Done => break,
            else => return failure,
        };
        if (records == std.math.maxInt(u32)) {
            const remaining = pager.journal.items.len - @as(usize, @intCast(pager.journal_offset));
            records = @intCast(remaining / (pager.page_size + 8));
        }
        if (restored == 0) {
            try truncateDatabase(pager, original_size);
            pager.database_pages = original_size;
            pager.maximum_pages = @max(pager.maximum_pages, original_size);
        }
        var index: u32 = 0;
        while (index < records) : (index += 1) {
            var offset: usize = @intCast(pager.journal_offset);
            const accepted = try playbackOnePage(pager, &offset, null, true, false);
            pager.journal_offset = offset;
            if (!accepted) {
                break;
            }
            restored += 1;
        }
    }
    pager.change_count_done = pager.temporary;
    try syncDatabase(pager, null);
    try endTransaction(pager, false, false);
    pager.sector_size = sectorSize(pager.sector_size);
}

test "checkpoint batch rollback journal playback restores the original database page" {
    var pager = Pager{
        .allocator = std.testing.allocator,
        .page_size = 512,
        .sector_size = 512,
        .database_pages = 1,
        .original_pages = 1,
        .file_pages = 1,
        .maximum_pages = 8,
        .state = .reader,
        .lock_level = .shared,
        .no_sync = true,
    };
    defer pager.deinit();
    try pager.database.resize(std.testing.allocator, 512);
    @memset(pager.database.items, 0x2a);
    try beginWriteTransaction(&pager, false, false);
    try openRollbackJournal(&pager);
    const cached = try getPage(&pager, 1, false);
    try addPageToRollbackJournal(&pager, &cached.page, cached.data);
    @memset(pager.database.items, 0x7b);
    try rollbackTransaction(&pager);
    try std.testing.expectEqualSlices(u8, cached.data, pager.database.items);
    try std.testing.expectEqual(PagerState.reader, pager.state);
}

test "pager source savepoint journal locking and sector primitives" {
    var pager = Pager{ .allocator = std.testing.allocator, .database_pages = 4, .original_pages = 4, .journal_offset = 513, .journal_size = 1024 };
    defer pager.deinit();
    try std.testing.expectEqual(@as(u64, 1024), journalHeaderOffset(&pager));
    try syncHotJournal(&pager, null);
    try openSavepoints(&pager, 2);
    try std.testing.expectEqual(@as(usize, 2), pager.savepoints.items.len);
    try std.testing.expect(subjournalRequiresPage(&pager, 2));
    try addToSavepointBitvectors(&pager, 2);
    try std.testing.expect(!subjournalRequiresPage(&pager, 2));
    pager.mmap_size = 4096;
    var accepted_size: u64 = 0;
    fixMapLimit(&pager, true, 3, &accepted_size);
    setGetterMethod(&pager);
    try std.testing.expectEqual(Getter.mapped, pager.getter);
    var page = Page{ .number = 1, .dirty = true, .writeable = true };
    releaseAllSavepoints(&pager);
    dontWrite(&pager, &page);
    try std.testing.expect(page.dont_write and !page.writeable);
    try std.testing.expectEqual(LockingMode.exclusive, lockingMode(&pager, .exclusive, false));
    try std.testing.expectEqual(@as(u32, 4), maxPageCount(&pager, 2));
    try std.testing.expect(isSuperJournalName("main.db-mj123456789"));
}

test "pager source subjournal spill flags and mapped pages" {
    var pager = Pager{ .allocator = std.testing.allocator, .database_pages = 2, .original_pages = 2, .state = .reader };
    defer pager.deinit();
    try openSavepoints(&pager, 1);
    const bytes = try std.testing.allocator.alloc(u8, pager.page_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 7);
    try subjournalPage(&pager, 1, bytes);
    try std.testing.expectEqual(@as(usize, 1), pager.subjournal_records);
    setFlags(&pager, .{ .level = 2 });
    try std.testing.expect(pager.full_sync and !pager.no_sync);
    pager.use_fetch = true;
    var page = Page{};
    try std.testing.expect(getMappedPage(&pager, &page, 2, true, null));
    try std.testing.expect(page.mapped);
}
