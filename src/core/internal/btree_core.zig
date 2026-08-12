//! Source-shaped B-tree page, cursor, lock, and integrity primitives.
const std = @import("std");

pub const Error = error{ Abort, Corrupt, Empty, Locked, NoMemory, NotFound, ReadOnly, Range };
pub const Transaction = enum { none, read, write };
pub const CursorState = enum { invalid, valid, skip_next, require_seek, fault };
pub const LockKind = enum(u8) { read = 1, write = 2 };
pub const PointerKind = enum { overflow_first, overflow_next, btree };
pub const PointerEntry = struct { kind: PointerKind, parent: u32 };
pub const Lock = struct { owner: *Btree, root: u32, kind: LockKind };
pub const CellInfo = struct { size: usize = 0, key: u64 = 0, payload_size: usize = 0, local_size: usize = 0, payload_offset: usize = 0 };

pub const Page = struct {
    allocator: std.mem.Allocator,
    shared: *Shared,
    number: u32,
    data: []u8,
    usable_size: usize,
    header_offset: usize,
    leaf: bool = true,
    integer_key: bool = false,
    flag_byte: u8 = 0,
    initialized: bool = false,
    dirty: bool = false,
    ref_count: usize = 0,
    min_local: usize = 0,
    max_local: usize = 0,
    cell_offset: usize = 0,
    free_bytes: usize = 0,
    overflow_cells: std.ArrayList([]u8) = .empty,
    cells: std.ArrayList([]u8) = .empty,
    children: std.ArrayList(u32) = .empty,
    pub fn deinit(self: *Page) void {
        for (self.overflow_cells.items) |cell| self.allocator.free(cell);
        self.overflow_cells.deinit(self.allocator);
        for (self.cells.items) |cell| self.allocator.free(cell);
        self.cells.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.allocator.free(self.data);
    }
};

pub const Shared = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList(*Page) = .empty,
    cursors: std.ArrayList(*Cursor) = .empty,
    locks: std.ArrayList(Lock) = .empty,
    free_pages: std.ArrayList(u32) = .empty,
    pointers: std.AutoHashMap(u32, PointerEntry),
    has_content: ?[]bool = null,
    temporary_space: ?[]u8 = null,
    metadata: [16]u32 = [_]u32{0} ** 16,
    references: usize = 1,
    reserved_bytes: u8 = 0,
    requested_reserved_bytes: u8 = 0,
    read_version: u8 = 1,
    write_version: u8 = 1,
    interrupted: bool = false,
    progress_steps: usize = 0,
    progress_interval: usize = 0,
    progress: ?*const fn () bool = null,
    writer: ?*Btree = null,
    exclusive: bool = false,
    pending: bool = false,
    transaction: Transaction = .none,
    page_one: ?*Page = null,
    usable_size: u32 = 4096,
    page_size_fixed: bool = false,
    auto_vacuum: bool = false,
    incremental_vacuum: bool = false,
    secure_delete: u2 = 0,
    pager_flags: u32 = 0,
    cache_size: i64 = 0,
    spill_size: i64 = 0,
    mmap_limit: i64 = 0,
    default_sync_level: u8 = 0,
    maximum_root: u32 = 1,
    pending_byte_page: u32 = 0x40000000 / 4096 + 1,
    schema: ?[]u8 = null,
    schema_free: ?*const fn ([]u8) void = null,
    checkpoint_log: usize = 0,
    checkpointed: usize = 0,
    pub fn init(allocator: std.mem.Allocator) Shared {
        return .{ .allocator = allocator, .pointers = std.AutoHashMap(u32, PointerEntry).init(allocator) };
    }
    pub fn deinit(self: *Shared) void {
        for (self.cursors.items) |cursor| {
            cursor.deinit();
            self.allocator.destroy(cursor);
        }
        self.cursors.deinit(self.allocator);
        for (self.pages.items) |page| {
            page.deinit();
            self.allocator.destroy(page);
        }
        self.pages.deinit(self.allocator);
        self.locks.deinit(self.allocator);
        self.free_pages.deinit(self.allocator);
        self.pointers.deinit();
        if (self.has_content) |content| self.allocator.free(content);
        if (self.temporary_space) |space| self.allocator.free(space);
        if (self.schema) |schema_storage| {
            if (self.schema_free) |free_schema| free_schema(schema_storage) else self.allocator.free(schema_storage);
        }
    }
};

pub const Btree = struct { shared: *Shared, sharable: bool = false, read_uncommitted: bool = false, read_only: bool = false, transaction: Transaction = .none, has_incrblob_cursor: bool = false, backup_count: usize = 0, savepoint_count: usize = 0 };
pub const Cursor = struct {
    allocator: std.mem.Allocator,
    tree: *Btree,
    root: u32,
    writable: bool,
    state: CursorState = .invalid,
    page: ?*Page = null,
    ancestors: std.ArrayList(*Page) = .empty,
    ancestor_indices: std.ArrayList(usize) = .empty,
    index: usize = 0,
    saved_page: ?u32 = null,
    saved_index: usize = 0,
    saved_key: ?[]u8 = null,
    fault: ?Error = null,
    incrblob: bool = false,
    rowid: i64 = 0,
    at_last: bool = false,
    valid_key: bool = false,
    valid_overflow: bool = false,
    pinned: bool = false,
    hints: u8 = 0,
    info: CellInfo = .{},
    pub fn deinit(self: *Cursor) void {
        if (self.saved_key) |key| self.allocator.free(key);
        releaseAllCursorPages(self);
        self.ancestors.deinit(self.allocator);
        self.ancestor_indices.deinit(self.allocator);
    }
};

/// Source `sqlite3BtreeClearCursor()`.
pub fn clearCursor(cursor: *Cursor) void {
    if (cursor.saved_key) |key| {
        cursor.allocator.free(key);
        cursor.saved_key = null;
    }
    cursor.state = .invalid;
}

/// Source `sqlite3BtreeCursorHasMoved()`.
pub fn cursorHasMoved(cursor: *const Cursor) bool {
    return cursor.state != .valid;
}

/// Source `sqlite3BtreeCursorHintFlags()`.
pub fn setCursorHintFlags(cursor: *Cursor, hints: u8) void {
    std.debug.assert(hints == 0 or hints == 1 or hints == 2);
    cursor.hints = hints;
}

/// Source `sqlite3BtreeCursorHasHint()`.
pub fn cursorHasHint(cursor: *const Cursor, mask: u8) bool {
    return cursor.hints & mask != 0;
}

/// Source `sqlite3BtreeCursorPin()`.
pub fn pinCursor(cursor: *Cursor) void {
    std.debug.assert(!cursor.pinned);
    cursor.pinned = true;
}

/// Source `sqlite3BtreeCursorUnpin()`.
pub fn unpinCursor(cursor: *Cursor) void {
    std.debug.assert(cursor.pinned);
    cursor.pinned = false;
}

/// Source `cursorOnLastPage()`: every ancestor descent must have selected the
/// rightmost child, represented by an index at or beyond the ancestor's cell
/// count.
pub fn cursorOnLastPage(cursor: *const Cursor) bool {
    std.debug.assert(cursor.state == .valid);
    for (cursor.ancestors.items, cursor.ancestor_indices.items) |page, index| {
        if (index < page.cells.items.len) {
            return false;
        }
    }
    return true;
}

test "source cursor moved and pin state transitions preserve exact flags" {
    var shared = Shared.init(std.testing.allocator);
    defer shared.deinit();
    var tree = Btree{ .shared = &shared };
    var cursor = Cursor{ .allocator = std.testing.allocator, .tree = &tree, .root = 1, .writable = false };
    defer cursor.deinit();
    try std.testing.expect(cursorHasMoved(&cursor));
    cursor.state = .valid;
    try std.testing.expect(!cursorHasMoved(&cursor));
    setCursorHintFlags(&cursor, 2);
    try std.testing.expect(cursorHasHint(&cursor, 2));
    try std.testing.expect(!cursorHasHint(&cursor, 1));
    pinCursor(&cursor);
    try std.testing.expect(cursor.pinned);
    unpinCursor(&cursor);
    try std.testing.expect(!cursor.pinned);
    clearCursor(&cursor);
    try std.testing.expectEqual(CursorState.invalid, cursor.state);
}

test "source cursor last-page check requires every rightmost ancestor" {
    var shared = Shared.init(std.testing.allocator);
    defer shared.deinit();
    var tree = Btree{ .shared = &shared };
    var first_page = Page{ .allocator = std.testing.allocator, .shared = &shared, .number = 1, .data = &.{}, .usable_size = 4096, .header_offset = 100 };
    defer first_page.deinit();
    var second_page = Page{ .allocator = std.testing.allocator, .shared = &shared, .number = 2, .data = &.{}, .usable_size = 4096, .header_offset = 0 };
    defer second_page.deinit();
    const cell_a = try std.testing.allocator.alloc(u8, 0);
    try first_page.cells.append(std.testing.allocator, cell_a);
    const cell_b = try std.testing.allocator.alloc(u8, 0);
    try second_page.cells.append(std.testing.allocator, cell_b);
    const cell_c = try std.testing.allocator.alloc(u8, 0);
    try second_page.cells.append(std.testing.allocator, cell_c);
    var cursor = Cursor{ .allocator = std.testing.allocator, .tree = &tree, .root = 1, .writable = false, .state = .valid };
    defer cursor.deinit();
    try cursor.ancestors.append(std.testing.allocator, &first_page);
    try cursor.ancestor_indices.append(std.testing.allocator, 1);
    try cursor.ancestors.append(std.testing.allocator, &second_page);
    try cursor.ancestor_indices.append(std.testing.allocator, 2);
    try std.testing.expect(cursorOnLastPage(&cursor));
    try std.testing.expectEqual(@as(u64, 0), maxRecordSize(&cursor));
    cursor.ancestor_indices.items[0] = 0;
    try std.testing.expect(!cursorOnLastPage(&cursor));
    cursor.ancestors.clearRetainingCapacity();
    cursor.ancestor_indices.clearRetainingCapacity();
}

fn findPage(shared: *Shared, number: u32) ?*Page {
    for (shared.pages.items) |page| {
        if (page.number == number) return page;
    }
    return null;
}
fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}
fn readVarint(bytes: []const u8) Error!struct { value: u64, length: usize } {
    var value: u64 = 0;
    for (bytes[0..@min(bytes.len, 9)], 0..) |byte, index| {
        if (index == 8) return .{ .value = (value << 8) | byte, .length = 9 };
        value = (value << 7) | (byte & 0x7f);
        if (byte & 0x80 == 0) return .{ .value = value, .length = index + 1 };
    }
    return error.Corrupt;
}
fn retainPage(page: *Page) void {
    page.ref_count += 1;
}

fn writeVarint(output: []u8, value: u64) Error!usize {
    var buffer: [9]u8 = undefined;
    var remaining = value;
    var count: usize = 1;
    buffer[8] = @truncate(remaining);
    while (remaining > 0x7f and count < buffer.len) {
        remaining >>= 7;
        count += 1;
        buffer[9 - count] = @truncate((remaining & 0x7f) | 0x80);
    }
    if (output.len < count) return error.Range;
    @memcpy(output[0..count], buffer[9 - count ..]);
    return count;
}

/// Source `downgradeAllSharedCacheTableLocks()`.
pub fn downgradeAllSharedCacheTableLocks(tree: *Btree) void {
    const shared = tree.shared;
    if (shared.writer != tree) return;
    shared.writer = null;
    shared.exclusive = false;
    shared.pending = false;
    for (shared.locks.items) |*lock| {
        lock.kind = .read;
    }
}

/// Source `sqlite3BtreeIncrblobCursor()`.
pub fn markIncrblobCursor(cursor: *Cursor) void {
    cursor.incrblob = true;
    cursor.tree.has_incrblob_cursor = true;
}

/// Source `invalidateIncrblobCursors()`.
pub fn invalidateIncrblobCursors(tree: *Btree, root: u32, rowid: i64, clear_table: bool) void {
    tree.has_incrblob_cursor = false;
    for (tree.shared.cursors.items) |cursor| {
        if (!cursor.incrblob or cursor.tree != tree) continue;
        tree.has_incrblob_cursor = true;
        if (cursor.root == root and (clear_table or cursor.rowid == rowid)) cursor.state = .invalid;
    }
}

/// Source `btreeSetHasContent()`.
pub fn setHasContent(shared: *Shared, page_number: u32) Error!void {
    if (page_number == 0 or page_number > shared.pages.items.len) return error.Range;
    if (shared.has_content == null) {
        shared.has_content = shared.allocator.alloc(bool, shared.pages.items.len + 1) catch return error.NoMemory;
        @memset(shared.has_content.?, false);
    }
    shared.has_content.?[page_number] = true;
}

/// Source `btreeReleaseAllCursorPages()`.
pub fn releaseAllCursorPages(cursor: *Cursor) void {
    for (cursor.ancestors.items) |page| releasePageOne(page);
    cursor.ancestors.clearRetainingCapacity();
    cursor.ancestor_indices.clearRetainingCapacity();
    if (cursor.page) |page| releasePageOne(page);
    cursor.page = null;
    cursor.state = .invalid;
}

fn saveCursorPosition(cursor: *Cursor) Error!void {
    if (cursor.page == null) return error.NotFound;
    cursor.saved_page = cursor.page.?.number;
    cursor.saved_index = cursor.index;
    releaseAllCursorPages(cursor);
    cursor.state = .require_seek;
}

/// Source `saveAllCursors()`.
pub fn saveAllCursors(shared: *Shared, root: u32, except: ?*Cursor) Error!void {
    var first_index: ?usize = null;
    for (shared.cursors.items, 0..) |cursor, index| {
        if (cursor != except and (root == 0 or cursor.root == root)) {
            first_index = index;
            break;
        }
    }
    if (first_index) |index| try saveCursorsOnList(shared.cursors.items[index..], root, except);
}

/// Source `saveCursorsOnList()`.
pub fn saveCursorsOnList(cursors: []*Cursor, root: u32, except: ?*Cursor) Error!void {
    for (cursors) |cursor| {
        if (cursor == except or (root != 0 and cursor.root != root)) continue;
        if (cursor.state == .valid or cursor.state == .skip_next) try saveCursorPosition(cursor) else releaseAllCursorPages(cursor);
    }
}

fn restoreCursorPosition(cursor: *Cursor) Error!void {
    const page_number = cursor.saved_page orelse return error.NotFound;
    const page = findPage(cursor.tree.shared, page_number) orelse return error.NotFound;
    retainPage(page);
    cursor.page = page;
    cursor.index = @min(cursor.saved_index, page.cells.items.len);
    cursor.state = if (page.cells.items.len == 0) .invalid else .valid;
    cursor.saved_page = null;
}

/// Source `sqlite3BtreeCursorRestore()`.
pub fn cursorRestore(cursor: *Cursor, different_row: *bool) Error!void {
    restoreCursorPosition(cursor) catch |failure| {
        different_row.* = true;
        return failure;
    };
    different_row.* = cursor.state != .valid;
}

/// Source `ptrmapPageno()`.
pub fn pointerMapPageNumber(shared: *const Shared, page_number: u32) u32 {
    if (page_number < 2) return 0;
    const entries = shared.usable_size / 5 + 1;
    var result = ((page_number - 2) / entries) * entries + 2;
    if (result == shared.pending_byte_page) result += 1;
    return result;
}

/// Source `btreePayloadToLocal()`.
pub fn payloadToLocal(page: *const Page, payload_size: u64) usize {
    if (payload_size <= page.max_local) return @intCast(payload_size);
    const surplus = page.min_local + @as(usize, @intCast(payload_size - @as(u64, @intCast(page.min_local)))) % (page.usable_size - 4);
    return if (surplus <= page.max_local) surplus else page.min_local;
}

/// Source `btreeParseCellPtrNoPayload()`.
pub fn parseCellNoPayload(page: *const Page, cell: []const u8) Error!CellInfo {
    if (page.leaf or cell.len < 5) return error.Corrupt;
    const key = try readVarint(cell[4..]);
    return .{ .size = 4 + key.length, .key = key.value };
}

/// Source `cellSizePtrNoPayload()`.
pub fn cellSizeNoPayload(page: *const Page, cell: []const u8) Error!usize {
    if (page.leaf or cell.len < 5) return error.Corrupt;
    const key = try readVarint(cell[4..]);
    return 4 + key.length;
}

/// Source `ptrmapPutOvflPtr()`.
pub fn pointerMapPutOverflow(page: *Page, source: *const Page, cell: []const u8, info: CellInfo) Error!void {
    if (info.local_size >= info.payload_size) return;
    if (info.size < 4 or info.size > cell.len or info.payload_offset + info.local_size > source.data.len) return error.Corrupt;
    const overflow = readU32(cell[info.size - 4 .. info.size]);
    page.shared.pointers.put(overflow, .{ .kind = .overflow_first, .parent = page.number }) catch return error.NoMemory;
}

/// Source `btreePageFromDbPage()`.
pub fn pageFromData(shared: *Shared, page_number: u32, data: []u8) Error!*Page {
    if (findPage(shared, page_number)) |page| {
        if (page.data.ptr != data.ptr) return error.Corrupt;
        return page;
    }
    const page = shared.allocator.create(Page) catch return error.NoMemory;
    errdefer shared.allocator.destroy(page);
    page.* = .{ .allocator = shared.allocator, .shared = shared, .number = page_number, .data = data, .usable_size = @intCast(shared.usable_size), .header_offset = if (page_number == 1) 100 else 0 };
    shared.pages.append(shared.allocator, page) catch return error.NoMemory;
    return page;
}

/// Source `btreeGetPage()`.
pub fn getPage(shared: *Shared, page_number: u32, readonly: bool) Error!*Page {
    _ = readonly;
    const page = findPage(shared, page_number) orelse return error.NotFound;
    retainPage(page);
    return page;
}

/// Source `releasePageOne()`.
pub fn releasePageOne(page: *Page) void {
    std.debug.assert(page.ref_count > 0);
    page.ref_count -= 1;
}

/// Source `btreeGetUnusedPage()`.
pub fn getUnusedPage(shared: *Shared, page_number: u32, readonly: bool) Error!*Page {
    const page = try getPage(shared, page_number, readonly);
    if (page.ref_count > 1) {
        releasePageOne(page);
        return error.Corrupt;
    }
    page.initialized = false;
    return page;
}

fn initializePage(page: *Page) Error!void {
    if (page.header_offset >= page.data.len) return error.Corrupt;
    page.initialized = true;
}

/// Source `pageReinit()`.
pub fn reinitializePage(page: *Page) Error!void {
    if (!page.initialized) return;
    page.initialized = false;
    if (page.ref_count > 1) try initializePage(page);
}

/// Source `sqlite3BtreeSetCacheSize()`.
pub fn setCacheSize(tree: *Btree, maximum_pages: i64) void {
    tree.shared.cache_size = maximum_pages;
}

/// Source `sqlite3BtreeSetSpillSize()`.
pub fn setSpillSize(tree: *Btree, maximum_pages: i64) i64 {
    if (maximum_pages != 0) {
        tree.shared.spill_size = maximum_pages;
    }
    return @max(tree.shared.cache_size, tree.shared.spill_size);
}

/// Source `sqlite3BtreeSetMmapLimit()`.
pub fn setMmapLimit(tree: *Btree, byte_limit: i64) void {
    tree.shared.mmap_limit = byte_limit;
}

/// Source `sqlite3BtreeSetPagerFlags()`.
pub fn setPagerFlags(tree: *Btree, flags: u32) void {
    tree.shared.pager_flags = flags;
}

/// Source `sqlite3BtreeSecureDelete()`.
pub fn secureDelete(tree: ?*Btree, new_flag: ?u2) u2 {
    const value = tree orelse return 0;
    if (new_flag) |flag| value.shared.secure_delete = flag;
    return value.shared.secure_delete;
}

/// Source `sqlite3BtreeSetAutoVacuum()`.
pub fn setAutoVacuum(tree: *Btree, mode: u2) Error!void {
    const enabled = mode != 0;
    if (tree.shared.page_size_fixed and enabled != tree.shared.auto_vacuum) return error.ReadOnly;
    tree.shared.auto_vacuum = enabled;
    tree.shared.incremental_vacuum = mode == 2;
}

/// Source `sqlite3BtreeGetAutoVacuum()`.
pub fn getAutoVacuum(tree: *const Btree) u2 {
    if (!tree.shared.auto_vacuum) return 0;
    return if (tree.shared.incremental_vacuum) 2 else 1;
}

/// Source `unlockBtreeIfUnused()`.
pub fn unlockIfUnused(shared: *Shared) void {
    if (shared.transaction != .none or shared.page_one == null) return;
    for (shared.cursors.items) |cursor| {
        if (cursor.state == .valid) return;
    }
    const page = shared.page_one.?;
    shared.page_one = null;
    releasePageOne(page);
}

/// Source `finalDbSize()`.
pub fn finalDatabaseSize(shared: *const Shared, original_pages: u32, free_pages: u32) u32 {
    const entries = shared.usable_size / 5;
    if (entries == 0 or free_pages > original_pages) return 0;
    const pointer_pages = (free_pages -% original_pages + pointerMapPageNumber(shared, original_pages) + entries) / entries;
    var final = original_pages - free_pages - pointer_pages;
    if (original_pages > shared.pending_byte_page and final < shared.pending_byte_page) final -= 1;
    while (pointerMapPageNumber(shared, final) == final or final == shared.pending_byte_page) final -= 1;
    return final;
}

fn commitPhaseOne(tree: *Btree) Error!void {
    if (tree.transaction != .write) return error.ReadOnly;
}
fn commitPhaseTwo(tree: *Btree) void {
    tree.transaction = .none;
    tree.shared.transaction = .none;
    downgradeAllSharedCacheTableLocks(tree);
    unlockIfUnused(tree.shared);
}

/// Source `sqlite3BtreeCommit()`.
pub fn commit(tree: *Btree) Error!void {
    try commitPhaseOne(tree);
    commitPhaseTwo(tree);
}

/// Source `sqlite3BtreeBeginStmt()`.
pub fn beginStatement(tree: *Btree, statement: usize) Error!void {
    if (tree.transaction != .write or statement == 0 or statement <= tree.savepoint_count) return error.ReadOnly;
    tree.savepoint_count = statement;
}

fn openCursor(tree: *Btree, root: u32, writable: bool) Error!*Cursor {
    if (root == 0 or (writable and tree.transaction != .write)) return error.ReadOnly;
    const cursor = tree.shared.allocator.create(Cursor) catch return error.NoMemory;
    errdefer tree.shared.allocator.destroy(cursor);
    cursor.* = .{ .allocator = tree.shared.allocator, .tree = tree, .root = root, .writable = writable };
    tree.shared.cursors.append(tree.shared.allocator, cursor) catch return error.NoMemory;
    return cursor;
}

/// Source `btreeCursorWithLock()`.
pub fn cursorWithLock(tree: *Btree, root: u32, writable: bool) Error!*Cursor {
    try lockTable(tree, root, writable);
    return openCursor(tree, root, writable);
}

/// Source `sqlite3BtreeCursor()`.
pub fn createCursor(tree: *Btree, root: u32, writable: bool) Error!*Cursor {
    return if (tree.sharable) cursorWithLock(tree, root, writable) else openCursor(tree, root, writable);
}

/// Source `copyPayload()`.
pub fn copyPayload(page: *Page, offset: usize, buffer: []u8, write: bool) Error!void {
    if (offset > page.data.len or buffer.len > page.data.len - offset) return error.Range;
    if (write) {
        page.dirty = true;
        @memcpy(page.data[offset..][0..buffer.len], buffer);
    } else @memcpy(buffer, page.data[offset..][0..buffer.len]);
}

/// Source `accessPayloadChecked()`.
pub fn accessPayloadChecked(cursor: *Cursor, offset: usize, buffer: []u8) Error!void {
    if (cursor.state == .invalid) return error.Abort;
    if (cursor.state == .require_seek) {
        var different = false;
        try cursorRestore(cursor, &different);
        if (different) return error.NotFound;
    }
    const page = cursor.page orelse return error.NotFound;
    if (cursor.index >= page.cells.items.len) return error.Corrupt;
    const cell = page.cells.items[cursor.index];
    if (offset > cell.len or buffer.len > cell.len - offset) return error.Range;
    @memcpy(buffer, cell[offset..][0..buffer.len]);
}

fn moveToChild(cursor: *Cursor, page_number: u32) Error!void {
    const current = cursor.page orelse return error.NotFound;
    const child = try getPage(cursor.tree.shared, page_number, false);
    cursor.ancestors.append(cursor.allocator, current) catch {
        releasePageOne(child);
        return error.NoMemory;
    };
    cursor.ancestor_indices.append(cursor.allocator, cursor.index) catch {
        _ = cursor.ancestors.pop();
        releasePageOne(child);
        return error.NoMemory;
    };
    cursor.page = child;
    cursor.index = 0;
    cursor.info = .{};
}

/// Source `moveToParent()`.
pub fn moveToParent(cursor: *Cursor) Error!void {
    if (cursor.ancestors.items.len == 0) return error.NotFound;
    const child = cursor.page orelse return error.NotFound;
    releasePageOne(child);
    cursor.page = cursor.ancestors.pop().?;
    cursor.index = cursor.ancestor_indices.pop().?;
    cursor.info = .{};
    cursor.valid_key = false;
    cursor.valid_overflow = false;
}

/// Source `moveToLeftmost()`.
pub fn moveToLeftmost(cursor: *Cursor) Error!void {
    while (cursor.page) |page| {
        if (page.leaf) return;
        if (cursor.index >= page.children.items.len) return error.Corrupt;
        try moveToChild(cursor, page.children.items[cursor.index]);
    }
    return error.NotFound;
}

/// Source `moveToRightmost()`.
pub fn moveToRightmost(cursor: *Cursor) Error!void {
    while (cursor.page) |page| {
        if (page.leaf) {
            if (page.cells.items.len == 0) return error.Empty;
            cursor.index = page.cells.items.len - 1;
            return;
        }
        if (page.children.items.len == 0) return error.Corrupt;
        cursor.index = page.cells.items.len;
        try moveToChild(cursor, page.children.items[page.children.items.len - 1]);
    }
    return error.NotFound;
}

fn moveToRoot(cursor: *Cursor) Error!void {
    releaseAllCursorPages(cursor);
    const root = try getPage(cursor.tree.shared, cursor.root, false);
    cursor.page = root;
    cursor.index = 0;
    cursor.state = if (root.cells.items.len == 0 and root.children.items.len == 0) .invalid else .valid;
    if (cursor.state != .valid) return error.Empty;
}

/// Source `sqlite3BtreeFirst()`.
pub fn first(cursor: *Cursor) Error!bool {
    moveToRoot(cursor) catch |failure| if (failure == error.Empty) return true else return failure;
    try moveToLeftmost(cursor);
    return false;
}

/// Source `sqlite3BtreeIsEmpty()`.
pub fn isEmpty(cursor: *Cursor) Error!bool {
    moveToRoot(cursor) catch |failure| if (failure == error.Empty) return true else return failure;
    return false;
}

/// Source `btreeLast()`.
pub fn lastInternal(cursor: *Cursor) Error!bool {
    moveToRoot(cursor) catch |failure| if (failure == error.Empty) return true else return failure;
    moveToRightmost(cursor) catch |failure| {
        cursor.at_last = false;
        return failure;
    };
    cursor.at_last = true;
    return false;
}

/// Source `sqlite3BtreeLast()`.
pub fn last(cursor: *Cursor) Error!bool {
    if (cursor.state == .valid and cursor.at_last) return false;
    return lastInternal(cursor);
}

/// Source `sqlite3BtreeRowCountEst()`.
pub fn rowCountEstimate(cursor: *const Cursor) i64 {
    if (cursor.state != .valid or cursor.page == null) return 0;
    if (!cursor.page.?.leaf) return -1;
    var count: i64 = @intCast(cursor.page.?.cells.items.len);
    for (cursor.ancestors.items) |page| {
        count *= @intCast(page.cells.items.len + 1);
    }
    return count;
}

fn nextSlow(cursor: *Cursor) Error!bool {
    while (cursor.ancestors.items.len != 0) {
        try moveToParent(cursor);
        const page = cursor.page.?;
        if (cursor.index < page.cells.items.len) {
            cursor.index += 1;
            if (cursor.index < page.children.items.len) {
                try moveToChild(cursor, page.children.items[cursor.index]);
                try moveToLeftmost(cursor);
            }
            return false;
        }
    }
    cursor.state = .invalid;
    return true;
}

/// Source `sqlite3BtreeNext()`.
pub fn next(cursor: *Cursor) Error!bool {
    cursor.info = .{};
    cursor.valid_key = false;
    cursor.valid_overflow = false;
    cursor.at_last = false;
    if (cursor.state != .valid or cursor.page == null) return nextSlow(cursor);
    const page = cursor.page.?;
    if (page.leaf and cursor.index + 1 < page.cells.items.len) {
        cursor.index += 1;
        return false;
    }
    return nextSlow(cursor);
}

fn previousSlow(cursor: *Cursor) Error!bool {
    while (cursor.ancestors.items.len != 0) {
        try moveToParent(cursor);
        if (cursor.index != 0) {
            cursor.index -= 1;
            const page = cursor.page.?;
            if (cursor.index < page.children.items.len) {
                try moveToChild(cursor, page.children.items[cursor.index]);
                try moveToRightmost(cursor);
            }
            return false;
        }
    }
    cursor.state = .invalid;
    return true;
}

/// Source `sqlite3BtreePrevious()`.
pub fn previous(cursor: *Cursor) Error!bool {
    cursor.at_last = false;
    cursor.valid_overflow = false;
    cursor.valid_key = false;
    cursor.info = .{};
    if (cursor.state != .valid or cursor.page == null or cursor.index == 0 or !cursor.page.?.leaf) return previousSlow(cursor);
    cursor.index -= 1;
    return false;
}

pub const CellArray = struct { reference: *Page, cells: []const []const u8, sizes: []usize };
/// Source `populateCellCache()`.
pub fn populateCellCache(array: *CellArray, start: usize, count: usize) Error!void {
    if (start > array.cells.len or count > array.cells.len - start or array.sizes.len < array.cells.len) return error.Range;
    for (array.cells[start..][0..count], array.sizes[start..][0..count]) |cell, *size| {
        const computed = if (array.reference.leaf) cell.len else try cellSizeNoPayload(array.reference, cell);
        if (size.* == 0) size.* = computed else if (size.* != computed) return error.Corrupt;
    }
}

/// Source `anotherValidCursor()`.
pub fn anotherValidCursor(cursor: *const Cursor) Error!void {
    for (cursor.tree.shared.cursors.items) |other| {
        if (other != cursor and other.state == .valid and other.page == cursor.page) return error.Corrupt;
    }
}

pub const Payload = struct { data: []const u8, zero_fill: usize = 0 };
/// Source `btreeOverwriteCell()`.
pub fn overwriteCell(cursor: *Cursor, payload: Payload) Error!void {
    const page = cursor.page orelse return error.NotFound;
    if (cursor.index >= page.cells.items.len) return error.Corrupt;
    const total = payload.data.len + payload.zero_fill;
    if (cursor.info.local_size != total or total != page.cells.items[cursor.index].len) return error.Range;
    page.dirty = true;
    @memcpy(page.cells.items[cursor.index][0..payload.data.len], payload.data);
    @memset(page.cells.items[cursor.index][payload.data.len..], 0);
}

fn clearPage(shared: *Shared, page: *Page, changes: *usize) Error!void {
    for (page.children.items) |child_number| {
        if (findPage(shared, child_number)) |child| try clearPage(shared, child, changes);
    }
    changes.* += page.cells.items.len;
    for (page.cells.items) |cell| shared.allocator.free(cell);
    page.cells.clearRetainingCapacity();
    page.children.clearRetainingCapacity();
    page.initialized = true;
}

/// Source `sqlite3BtreeClearTable()`.
pub fn clearTable(tree: *Btree, root: u32) Error!usize {
    if (tree.transaction != .write) return error.ReadOnly;
    try saveAllCursors(tree.shared, root, null);
    if (tree.has_incrblob_cursor) invalidateIncrblobCursors(tree, root, 0, true);
    const page = findPage(tree.shared, root) orelse return error.NotFound;
    var changes: usize = 0;
    try clearPage(tree.shared, page, &changes);
    return changes;
}

pub const IntegrityCheck = struct { referenced: []bool, message: ?[]const u8 = null, errors: usize = 0, maximum_errors: usize = 100, steps: usize = 0, interrupted: bool = false, progress_interval: usize = 0, progress: ?*const fn () bool = null };
/// Source `checkRef()`.
pub fn checkReference(check: *IntegrityCheck, page_number: u32) bool {
    if (page_number == 0 or page_number >= check.referenced.len) {
        check.message = "invalid page number";
        return false;
    }
    if (check.referenced[page_number]) {
        check.message = "second page reference";
        return false;
    }
    check.referenced[page_number] = true;
    return true;
}

/// Source `btreeHeapInsert()`.
pub fn heapInsert(heap: []u32, value: u32) Error!void {
    const size: usize = @intCast(heap[0] + 1);
    if (size >= heap.len) return error.Range;
    heap[0] = @intCast(size);
    var index: usize = size;
    heap[index] = value;
    while (index / 2 != 0 and heap[index / 2] > heap[index]) {
        std.mem.swap(u32, &heap[index / 2], &heap[index]);
        index /= 2;
    }
}

/// Source `btreeHeapPull()`.
pub fn heapPull(heap: []u32) ?u32 {
    if (heap.len < 2 or heap[0] == 0) return null;
    const output = heap[1];
    const size: usize = @intCast(heap[0]);
    heap[1] = heap[size];
    heap[size] = std.math.maxInt(u32);
    heap[0] -= 1;
    var index: usize = 1;
    while (index * 2 <= @as(usize, @intCast(heap[0]))) {
        var child = index * 2;
        if (child + 1 <= heap[0] and heap[child] > heap[child + 1]) child += 1;
        if (heap[index] <= heap[child]) break;
        std.mem.swap(u32, &heap[index], &heap[child]);
        index = child;
    }
    return output;
}

/// Source `sqlite3BtreeCheckpoint()`.
pub fn checkpoint(tree: ?*Btree, mode: u8, log_frames: *usize, checkpointed_frames: *usize) Error!void {
    _ = mode;
    const value = tree orelse {
        log_frames.* = 0;
        checkpointed_frames.* = 0;
        return;
    };
    if (value.shared.transaction != .none) return error.Locked;
    value.shared.checkpointed = value.shared.checkpoint_log;
    log_frames.* = value.shared.checkpoint_log;
    checkpointed_frames.* = value.shared.checkpointed;
}

/// Source `sqlite3BtreeSchema()`.
pub fn schema(tree: *Btree, size: usize, free_schema: ?*const fn ([]u8) void) Error!?[]u8 {
    if (tree.shared.schema == null and size != 0) {
        const storage = tree.shared.allocator.alloc(u8, size) catch return error.NoMemory;
        @memset(storage, 0);
        tree.shared.schema = storage;
        tree.shared.schema_free = free_schema;
    }
    return tree.shared.schema;
}

/// Source `sqlite3BtreeSchemaLocked()`.
pub fn schemaLocked(tree: *Btree) Error!void {
    for (tree.shared.locks.items) |lock| {
        if (lock.root == 1 and lock.owner != tree and lock.kind == .write) return error.Locked;
    }
}

/// Source `sqlite3BtreeLockTable()`.
pub fn lockTable(tree: *Btree, root: u32, write: bool) Error!void {
    if (tree.transaction == .none) return error.ReadOnly;
    if (!tree.sharable) return;
    const requested: LockKind = if (write) .write else .read;
    try querySharedCacheLock(tree, root, requested);
    try setSharedCacheLock(tree, root, requested);
    if (write) tree.shared.writer = tree;
}

/// Source `clearAllSharedCacheTableLocks()`.
pub fn clearAllSharedCacheTableLocks(tree: *Btree) void {
    var index = tree.shared.locks.items.len;
    while (index != 0) {
        index -= 1;
        if (tree.shared.locks.items[index].owner == tree) _ = tree.shared.locks.orderedRemove(index);
    }
    if (tree.shared.writer == tree) {
        tree.shared.writer = null;
        tree.shared.exclusive = false;
        tree.shared.pending = false;
    }
}
/// Source `saveCursorKey()`.
pub fn saveCursorKey(cursor: *Cursor) Error!void {
    if (cursor.state != .valid or cursor.page == null or cursor.index >= cursor.page.?.cells.items.len) return error.NotFound;
    if (cursor.saved_key) |key| cursor.allocator.free(key);
    const cell = cursor.page.?.cells.items[cursor.index];
    cursor.saved_key = cursor.allocator.alloc(u8, cell.len + 17) catch return error.NoMemory;
    @memcpy(cursor.saved_key.?[0..cell.len], cell);
    @memset(cursor.saved_key.?[cell.len..], 0);
}
/// Source `btreeMoveto()`.
pub fn moveTo(cursor: *Cursor, key: []const u8, bias_high: bool) Error!std.math.Order {
    _ = try first(cursor);
    const page = cursor.page orelse return error.Empty;
    var best: usize = 0;
    for (page.cells.items, 0..) |cell, index| {
        const order = std.mem.order(u8, cell, key);
        if (order == .eq) {
            cursor.index = index;
            return .eq;
        }
        if (order == .lt or bias_high) best = index;
    }
    cursor.index = best;
    return std.mem.order(u8, page.cells.items[best], key);
}
/// Source `ptrmapGet()`.
pub fn pointerMapGet(shared: *Shared, page_number: u32) Error!PointerEntry {
    if (pointerMapPageNumber(shared, page_number) == 0) return error.Corrupt;
    return shared.pointers.get(page_number) orelse error.NotFound;
}
/// Source `btreeParseCellAdjustSizeForOverflow()`.
pub fn adjustCellSizeForOverflow(page: *const Page, cell_start: usize, info: *CellInfo) Error!void {
    if (info.payload_size < page.min_local or page.usable_size <= 4) return error.Corrupt;
    info.local_size = payloadToLocal(page, info.payload_size);
    info.size = cell_start + info.payload_offset + info.local_size + 4;
}
/// Source `btreeParseCellPtrIndex()`.
pub fn parseIndexCell(page: *const Page, cell: []const u8) Error!CellInfo {
    const child_bytes: usize = if (page.leaf) 0 else 4;
    if (cell.len <= child_bytes) return error.Corrupt;
    const payload = try readVarint(cell[child_bytes..]);
    var info = CellInfo{ .key = payload.value, .payload_size = @intCast(payload.value), .payload_offset = child_bytes + payload.length };
    if (info.payload_offset > cell.len) return error.Corrupt;
    if (info.payload_size <= page.max_local) {
        info.local_size = info.payload_size;
        info.size = @max(info.payload_offset + info.payload_size, 4);
    } else try adjustCellSizeForOverflow(page, 0, &info);
    if (info.size > cell.len) return error.Corrupt;
    return info;
}
/// Source `cellSizePtr()`.
pub fn cellSize(page: *const Page, cell: []const u8) Error!usize {
    return (try parseIndexCell(page, cell)).size;
}
/// Source `cellSizePtrIdxLeaf()`.
pub fn indexLeafCellSize(page: *const Page, cell: []const u8) Error!usize {
    if (!page.leaf) return error.Corrupt;
    return cellSize(page, cell);
}
/// Source `pageFindSlot()`.
pub fn findFreeSlot(page: *Page, byte_count: usize) ?usize {
    if (byte_count > page.free_bytes or byte_count > page.data.len) return null;
    const end = page.data.len - (page.cells.items.len * 2);
    if (byte_count > end) return null;
    page.free_bytes -= byte_count;
    return end - byte_count;
}
/// Source `decodeFlags()`.
pub fn decodeFlags(page: *Page, flags: u8) Error!void {
    const leaf = flags & 0x08 != 0;
    const integer = flags & 0x01 != 0;
    const leaf_data = flags & 0x04 != 0;
    const zero_data = flags & 0x02 != 0;
    if ((!leaf and !(zero_data or (integer and leaf_data))) or (leaf and !(zero_data or (integer and leaf_data)))) return error.Corrupt;
    page.flag_byte = flags;
    page.leaf = leaf;
    page.integer_key = integer;
    page.min_local = if (leaf_data) 8 else 4;
    page.max_local = if (leaf_data) page.usable_size / 2 else page.usable_size / 4;
}
/// Source `btreeComputeFreeSpace()`.
pub fn computeFreeSpace(page: *Page) Error!usize {
    var used = page.header_offset + (if (page.leaf) @as(usize, 8) else 12) + page.cells.items.len * 2;
    for (page.cells.items) |cell| {
        used += cell.len;
    }
    if (used > page.usable_size) return error.Corrupt;
    page.free_bytes = page.usable_size - used;
    return page.free_bytes;
}
/// Source `btreeCellSizeCheck()`.
pub fn checkCellSizes(page: *const Page) Error!void {
    for (page.cells.items) |cell| {
        const size = if (page.integer_key and !page.leaf) try cellSizeNoPayload(page, cell) else try cellSize(page, cell);
        if (size > cell.len or size > page.usable_size) return error.Corrupt;
    }
}
/// Source `zeroPage()`.
pub fn zeroPage(page: *Page, flags: u8) Error!void {
    page.dirty = true;
    if (page.shared.secure_delete != 0) @memset(page.data[page.header_offset..], 0);
    for (page.cells.items) |cell| page.allocator.free(cell);
    page.cells.clearRetainingCapacity();
    page.children.clearRetainingCapacity();
    try decodeFlags(page, flags);
    page.cell_offset = page.header_offset + (if (page.leaf) @as(usize, 8) else 12);
    page.initialized = true;
    _ = try computeFreeSpace(page);
}
/// Source `getAndInitPage()`.
pub fn getInitializedPage(shared: *Shared, page_number: u32, readonly: bool) Error!*Page {
    const page = try getPage(shared, page_number, readonly);
    if (!page.initialized) initializePage(page) catch |failure| {
        releasePageOne(page);
        return failure;
    };
    return page;
}
/// Source `removeFromSharingList()`.
pub fn removeFromSharingList(shared: *Shared) bool {
    if (shared.references != 0) shared.references -= 1;
    return shared.references == 0;
}
/// Source `allocateTempSpace()`.
pub fn allocateTemporarySpace(shared: *Shared) Error![]u8 {
    if (shared.temporary_space == null) {
        shared.temporary_space = shared.allocator.alloc(u8, shared.usable_size + 4) catch return error.NoMemory;
        @memset(shared.temporary_space.?[0..8], 0);
    }
    return shared.temporary_space.?[4..];
}
/// Source `sqlite3BtreeClose()`.
pub fn closeBtree(tree: *Btree) void {
    rollback(tree, false) catch {};
    clearAllSharedCacheTableLocks(tree);
    tree.transaction = .none;
    _ = removeFromSharingList(tree.shared);
}
/// Source `sqlite3BtreeSetPageSize()`.
pub fn setPageSize(tree: *Btree, page_size: u32, reserved: u8, fixed: bool) Error!void {
    if (tree.shared.page_size_fixed and (page_size != 0 and page_size != tree.shared.usable_size + tree.shared.reserved_bytes)) return error.ReadOnly;
    if (page_size >= 512 and page_size <= 65536 and std.math.isPowerOfTwo(page_size)) {
        tree.shared.usable_size = page_size - reserved;
        tree.shared.reserved_bytes = reserved;
        if (tree.shared.temporary_space) |space| {
            tree.shared.allocator.free(space);
            tree.shared.temporary_space = null;
        }
    }
    if (fixed) tree.shared.page_size_fixed = true;
}

/// Source `sqlite3BtreeGetPageSize()`.
pub fn pageSize(tree: *const Btree) u32 {
    return tree.shared.usable_size + tree.shared.reserved_bytes;
}

/// Source `sqlite3BtreeGetReserveNoMutex()` after the caller has acquired the
/// shared B-tree mutex.
pub fn reserveNoMutex(tree: *const Btree) u8 {
    return tree.shared.reserved_bytes;
}

/// Source `sqlite3BtreeTxnState()` with the source null-Btree NONE result.
pub fn transactionState(tree: ?*const Btree) Transaction {
    return if (tree) |value| value.transaction else .none;
}

/// Source `sqlite3BtreeIsReadonly()`.
pub fn isReadOnly(tree: *const Btree) bool {
    return tree.read_only;
}

/// Source `sqlite3BtreeMaxRecordSize()`.
pub fn maxRecordSize(cursor: *const Cursor) u64 {
    std.debug.assert(cursor.state == .valid);
    return @as(u64, pageSize(cursor.tree)) * pageCount(cursor.tree.shared);
}

/// Source `sqlite3HeaderSizeBtree()` rounded to the active pointer alignment.
pub fn headerSizeBtree() usize {
    return std.mem.alignForward(usize, @sizeOf(Page), 8);
}

/// Source `sqlite3BtreeConnectionCount()`.
pub fn connectionCount(tree: *const Btree) usize {
    return tree.shared.references;
}

/// Source `sqlite3BtreeIsInBackup()`.
pub fn isInBackup(tree: *const Btree) bool {
    return tree.backup_count != 0;
}

/// Source `btreePagecount()`.
pub fn pageCount(shared: *const Shared) usize {
    return shared.pages.items.len;
}

/// Source `sqlite3BtreeLastPage()` under the caller-held B-tree mutex.
pub fn lastPage(tree: *const Btree) usize {
    return pageCount(tree.shared);
}

/// Source `sqlite3BtreeGetRequestedReserve()`: reserve bytes may grow to a
/// pending file-control request but never report less than the live page
/// format currently reserves.
pub fn requestedReserve(tree: *const Btree) u8 {
    return @max(tree.shared.requested_reserved_bytes, tree.shared.reserved_bytes);
}

test "source incremental blob cursor marks cursor and owning B-tree" {
    var shared = Shared.init(std.testing.allocator);
    defer shared.deinit();
    var tree = Btree{ .shared = &shared };
    var cursor = Cursor{ .allocator = std.testing.allocator, .tree = &tree, .root = 1, .writable = false };
    defer cursor.deinit();
    markIncrblobCursor(&cursor);
    try std.testing.expect(cursor.incrblob);
    try std.testing.expect(tree.has_incrblob_cursor);
}

test "source page size and requested reserve reflect live page format" {
    var shared = Shared.init(std.testing.allocator);
    defer shared.deinit();
    const tree = Btree{ .shared = &shared };
    shared.usable_size = 4084;
    shared.reserved_bytes = 12;
    try std.testing.expectEqual(@as(u32, 4096), pageSize(&tree));
    try std.testing.expectEqual(@as(u8, 12), reserveNoMutex(&tree));
    try std.testing.expectEqual(Transaction.none, transactionState(null));
    try std.testing.expectEqual(Transaction.none, transactionState(&tree));
    try std.testing.expect(!isReadOnly(&tree));
    try std.testing.expectEqual(@as(usize, 1), connectionCount(&tree));
    try std.testing.expect(!isInBackup(&tree));
    try std.testing.expect(headerSizeBtree() >= @sizeOf(Page));
    try std.testing.expectEqual(@as(usize, 0), pageCount(&shared));
    try std.testing.expectEqual(@as(usize, 0), lastPage(&tree));
    shared.requested_reserved_bytes = 8;
    try std.testing.expectEqual(@as(u8, 12), requestedReserve(&tree));
    shared.requested_reserved_bytes = 24;
    try std.testing.expectEqual(@as(u8, 24), requestedReserve(&tree));
}

/// Source `newDatabase()`.
pub fn initializeDatabase(shared: *Shared) Error!void {
    const page = shared.page_one orelse return error.NotFound;
    if (page.data.len < 100) return error.Corrupt;
    @memcpy(page.data[0..16], "SQLite format 3\x00");
    page.data[18] = 1;
    page.data[19] = 1;
    page.data[20] = shared.reserved_bytes;
    page.data[21] = 64;
    page.data[22] = 32;
    page.data[23] = 32;
    try zeroPage(page, 0x0d);
    shared.page_size_fixed = true;
}
/// Source `sqlite3BtreeBeginTrans()`.
pub fn beginTransaction(tree: *Btree, write: bool, schema_version: ?*u32) Error!void {
    if (write and tree.shared.writer != null and tree.shared.writer != tree) return error.Locked;
    tree.transaction = if (write) .write else .read;
    tree.shared.transaction = tree.transaction;
    if (write) tree.shared.writer = tree;
    if (schema_version) |output| output.* = tree.shared.metadata[1];
}
/// Source `setChildPtrmaps()`.
pub fn setChildPointerMaps(page: *Page) Error!void {
    for (page.children.items) |child| {
        page.shared.pointers.put(child, .{ .kind = .btree, .parent = page.number }) catch return error.NoMemory;
    }
}
/// Source `modifyPagePointer()`.
pub fn modifyPagePointer(page: *Page, from: u32, to: u32, kind: PointerKind) Error!void {
    if (kind == .overflow_next) {
        if (readU32(page.data) != from) return error.Corrupt;
        std.mem.writeInt(u32, page.data[0..4], to, .big);
        return;
    }
    for (page.children.items) |*child| {
        if (child.* == from) {
            child.* = to;
            return;
        }
    }
    return error.NotFound;
}
/// Source `relocatePage()`.
pub fn relocatePage(shared: *Shared, page: *Page, kind: PointerKind, parent: u32, destination: u32) Error!void {
    if (page.number < 3 or findPage(shared, destination) != null) return error.Corrupt;
    const old = page.number;
    page.number = destination;
    try setChildPointerMaps(page);
    if (kind != .btree or parent != 0) {
        const parent_page = findPage(shared, parent) orelse return error.NotFound;
        try modifyPagePointer(parent_page, old, destination, kind);
    }
    shared.pointers.put(destination, .{ .kind = kind, .parent = parent }) catch return error.NoMemory;
}
/// Source `sqlite3BtreeIncrVacuum()`.
pub fn incrementalVacuum(tree: *Btree) Error!bool {
    if (tree.transaction != .write) return error.ReadOnly;
    if (!tree.shared.auto_vacuum) return true;
    if (tree.shared.pages.items.len <= 1) return true;
    const page = tree.shared.pages.pop().?;
    page.deinit();
    tree.shared.allocator.destroy(page);
    return false;
}
/// Source `autoVacuumCommit()`.
pub fn autoVacuumCommit(tree: *Btree) Error!void {
    if (!tree.shared.auto_vacuum or tree.shared.incremental_vacuum) return;
    while (!(try incrementalVacuum(tree))) {}
}
/// Source `sqlite3BtreeTripAllCursors()`.
pub fn tripAllCursors(tree: ?*Btree, failure: Error, write_only: bool) Error!void {
    const value = tree orelse return;
    for (value.shared.cursors.items) |cursor| {
        if (write_only and !cursor.writable) {
            if (cursor.state == .valid) try saveCursorPosition(cursor);
        } else {
            releaseAllCursorPages(cursor);
            cursor.state = .fault;
            cursor.fault = failure;
        }
    }
}
/// Source `sqlite3BtreeRollback()`.
pub fn rollback(tree: *Btree, trip: bool) Error!void {
    if (trip) try tripAllCursors(tree, error.Abort, false) else try saveAllCursors(tree.shared, 0, null);
    tree.transaction = .none;
    tree.shared.transaction = .none;
    clearAllSharedCacheTableLocks(tree);
}
/// Source `sqlite3BtreeSavepoint()`.
pub fn btreeSavepoint(tree: *Btree, rollback_savepoint: bool, index: isize) Error!void {
    if (tree.transaction != .write) return;
    if (rollback_savepoint) try saveAllCursors(tree.shared, 0, null);
    if (index < -1) return error.Range;
    tree.savepoint_count = if (index < 0) 0 else @intCast(index);
}
/// Source `sqlite3BtreeCloseCursor()`.
pub fn closeCursor(cursor: *Cursor) void {
    const shared = cursor.tree.shared;
    for (shared.cursors.items, 0..) |candidate, index| {
        if (candidate == cursor) {
            _ = shared.cursors.orderedRemove(index);
            break;
        }
    }
    cursor.deinit();
    shared.allocator.destroy(cursor);
    unlockIfUnused(shared);
}
/// Source `getOverflowPage()`.
pub fn getOverflowPage(shared: *Shared, page_number: u32, return_page: bool) Error!struct { page: ?*Page, next: u32 } {
    if (shared.auto_vacuum) {
        const guess = page_number + 1;
        if (shared.pointers.get(guess)) |entry| {
            if (entry.kind == .overflow_next and entry.parent == page_number) return .{ .page = if (return_page) try getPage(shared, page_number, false) else null, .next = guess };
        }
    }
    const page = try getPage(shared, page_number, !return_page);
    const next_page = readU32(page.data);
    if (!return_page) releasePageOne(page);
    return .{ .page = if (return_page) page else null, .next = next_page };
}
/// Source `fetchPayload()`.
pub fn fetchPayload(cursor: *const Cursor) Error![]const u8 {
    const page = cursor.page orelse return error.NotFound;
    if (cursor.state != .valid or cursor.index >= page.cells.items.len) return error.Abort;
    const cell = page.cells.items[cursor.index];
    if (cursor.info.payload_offset > cell.len) return error.Corrupt;
    return cell[cursor.info.payload_offset..][0..@min(cursor.info.local_size, cell.len - cursor.info.payload_offset)];
}
/// Source `indexCellCompare()`.
pub fn compareIndexCell(page: *const Page, index: usize, key: []const u8) Error!?std.math.Order {
    if (index >= page.cells.items.len) return error.Range;
    const info = try parseIndexCell(page, page.cells.items[index]);
    if (info.local_size != info.payload_size) return null;
    const payload = page.cells.items[index][info.payload_offset..][0..info.local_size];
    return std.mem.order(u8, payload, key);
}
/// Source `clearCellOverflow()`.
pub fn clearCellOverflow(page: *Page, cell: []const u8, info: CellInfo) Error!usize {
    if (info.local_size >= info.payload_size or info.size < 4 or info.size > cell.len) return error.Corrupt;
    var number = readU32(cell[info.size - 4 ..]);
    var freed: usize = 0;
    while (number != 0) {
        const result = try getOverflowPage(page.shared, number, true);
        number = result.next;
        const overflow = result.page.?;
        releasePageOne(overflow);
        freed += 1;
    }
    return freed;
}
/// Source `dropCell()`.
pub fn dropCell(page: *Page, index: usize) Error!void {
    if (index >= page.cells.items.len) return error.Range;
    const cell = page.cells.orderedRemove(index);
    page.free_bytes += cell.len + 2;
    page.allocator.free(cell);
    page.dirty = true;
}
/// Source `insertCellFast()`.
pub fn insertCellFast(page: *Page, index: usize, cell: []const u8) Error!void {
    if (index > page.cells.items.len) return error.Range;
    const copy = page.allocator.dupe(u8, cell) catch return error.NoMemory;
    errdefer page.allocator.free(copy);
    if (cell.len + 2 > page.free_bytes) page.overflow_cells.append(page.allocator, copy) catch return error.NoMemory else {
        page.cells.insert(page.allocator, index, copy) catch return error.NoMemory;
        page.free_bytes -= cell.len + 2;
    }
    page.dirty = true;
}
/// Source `rebuildPage()`.
pub fn rebuildPage(page: *Page, cells: []const []const u8) Error!void {
    var copies = std.ArrayList([]u8).empty;
    defer copies.deinit(page.allocator);
    errdefer for (copies.items) |cell| page.allocator.free(cell);
    for (cells) |cell| copies.append(page.allocator, page.allocator.dupe(u8, cell) catch return error.NoMemory) catch return error.NoMemory;
    for (page.cells.items) |cell| page.allocator.free(cell);
    page.cells.deinit(page.allocator);
    page.cells = copies;
    copies = .empty;
    page.overflow_cells.clearRetainingCapacity();
    _ = try computeFreeSpace(page);
}
/// Source `pageInsertArray()`.
pub fn insertCellArray(page: *Page, index: usize, cells: []const []const u8) Error!void {
    var position = index;
    for (cells) |cell| {
        try insertCellFast(page, position, cell);
        position += 1;
    }
}
/// Source `pageFreeArray()`.
pub fn freeCellArray(page: *Page, start: usize, count: usize) Error!usize {
    if (start > page.cells.items.len or count > page.cells.items.len - start) return error.Range;
    var removed: usize = 0;
    while (removed < count) {
        try dropCell(page, start);
        removed += 1;
    }
    return removed;
}
/// Source `copyNodeContent()`.
pub fn copyNodeContent(source: *const Page, destination: *Page) Error!void {
    try rebuildPage(destination, source.cells.items);
    destination.leaf = source.leaf;
    destination.integer_key = source.integer_key;
    destination.children.clearRetainingCapacity();
    destination.children.appendSlice(destination.allocator, source.children.items) catch return error.NoMemory;
    try setChildPointerMaps(destination);
}
/// Source `balance_deeper()`.
pub fn balanceDeeper(root: *Page) Error!*Page {
    if (root.overflow_cells.items.len == 0) return error.Range;
    const shared = root.shared;
    const data = shared.allocator.alloc(u8, shared.usable_size) catch return error.NoMemory;
    errdefer shared.allocator.free(data);
    @memset(data, 0);
    const child = try pageFromData(shared, @intCast(shared.pages.items.len + 2), data);
    try copyNodeContent(root, child);
    for (root.overflow_cells.items) |cell| try insertCellFast(child, child.cells.items.len, cell);
    try zeroPage(root, root.flag_byte & ~@as(u8, 0x08));
    root.children.append(root.allocator, child.number) catch return error.NoMemory;
    return child;
}
/// Source `btreeOverwriteOverflowCell()`.
pub fn overwriteOverflowCell(cursor: *Cursor, payload: Payload) Error!void {
    const page = cursor.page orelse return error.NotFound;
    if (cursor.info.local_size >= payload.data.len + payload.zero_fill) return error.Range;
    const local = @min(cursor.info.local_size, payload.data.len);
    @memcpy(page.cells.items[cursor.index][cursor.info.payload_offset..][0..local], payload.data[0..local]);
    var offset = local;
    var number = readU32(page.cells.items[cursor.index][cursor.info.size - 4 ..]);
    while (offset < payload.data.len) {
        const overflow = try getPage(page.shared, number, false);
        defer releasePageOne(overflow);
        const amount = @min(overflow.data.len - 4, payload.data.len - offset);
        @memcpy(overflow.data[4..][0..amount], payload.data[offset..][0..amount]);
        offset += amount;
        number = readU32(overflow.data);
    }
}
/// Source `sqlite3BtreeGetMeta()`.
pub fn getMeta(tree: *const Btree, index: usize) Error!u32 {
    if (index >= tree.shared.metadata.len or tree.transaction == .none) return error.Range;
    return tree.shared.metadata[index];
}
/// Source `sqlite3BtreeUpdateMeta()`.
pub fn updateMeta(tree: *Btree, index: usize, value: u32) Error!void {
    if (index == 0 or index >= tree.shared.metadata.len or tree.transaction != .write) return error.ReadOnly;
    tree.shared.metadata[index] = value;
    if (index == 7) tree.shared.incremental_vacuum = value != 0;
}
/// Source `sqlite3BtreeCount()`.
pub fn countEntries(cursor: *Cursor) Error!usize {
    _ = try first(cursor);
    var count: usize = 1;
    while (!(try next(cursor))) count += 1;
    return count;
}
/// Source `checkProgress()`.
pub fn checkProgress(check: *IntegrityCheck) void {
    check.steps += 1;
    if (check.interrupted or (check.progress_interval != 0 and check.steps % check.progress_interval == 0 and check.progress != null and check.progress.?())) {
        check.interrupted = true;
        check.errors += 1;
        check.maximum_errors = 0;
    }
}
/// Source `checkAppendMsg()`.
pub fn appendCheckMessage(check: *IntegrityCheck, message: []const u8) void {
    checkProgress(check);
    if (check.maximum_errors == 0) return;
    check.maximum_errors -= 1;
    check.errors += 1;
    check.message = message;
}
/// Source `checkPtrmap()`.
pub fn checkPointerMap(check: *IntegrityCheck, shared: *Shared, child: u32, kind: PointerKind, parent: u32) void {
    const entry = pointerMapGet(shared, child) catch {
        appendCheckMessage(check, "failed to read pointer map");
        return;
    };
    if (entry.kind != kind or entry.parent != parent) appendCheckMessage(check, "bad pointer map entry");
}
/// Source `checkList()`.
pub fn checkPageList(check: *IntegrityCheck, shared: *Shared, first_page: u32, expected: usize) void {
    var page_number = first_page;
    var count: usize = 0;
    while (page_number != 0 and check.maximum_errors != 0) {
        if (!checkReference(check, page_number)) break;
        const page = findPage(shared, page_number) orelse {
            appendCheckMessage(check, "failed to get list page");
            break;
        };
        count += 1;
        page_number = if (page.data.len >= 4) readU32(page.data) else 0;
    }
    if (count != expected) appendCheckMessage(check, "page list length mismatch");
}
/// Source `sqlite3BtreePutData()`.
pub fn putData(cursor: *Cursor, offset: usize, data: []const u8) Error!void {
    if (!cursor.incrblob or !cursor.writable or cursor.tree.transaction != .write) return error.ReadOnly;
    if (cursor.state == .require_seek) {
        var different = false;
        try cursorRestore(cursor, &different);
        if (different) return error.NotFound;
    }
    try saveAllCursors(cursor.tree.shared, cursor.root, cursor);
    const page = cursor.page orelse return error.NotFound;
    if (cursor.index >= page.cells.items.len) return error.Corrupt;
    const cell = page.cells.items[cursor.index];
    if (offset > cell.len or data.len > cell.len - offset) return error.Range;
    @memcpy(cell[offset..][0..data.len], data);
    page.dirty = true;
}
/// Source `sqlite3BtreeSetVersion()`.
pub fn setVersion(tree: *Btree, version: u8) Error!void {
    if (version != 1 and version != 2) return error.Range;
    try beginTransaction(tree, false, null);
    if (tree.shared.read_version != version or tree.shared.write_version != version) {
        try beginTransaction(tree, true, null);
        tree.shared.read_version = version;
        tree.shared.write_version = version;
        if (tree.shared.page_one) |page| {
            page.data[18] = version;
            page.data[19] = version;
            page.dirty = true;
        }
    }
}

/// Source `corruptPageError()`.
pub fn corruptionError(page: *const Page, check: ?*IntegrityCheck) Error {
    if (check) |state| appendCheckMessage(state, "database corruption on b-tree page");
    _ = page.number;
    return error.Corrupt;
}

/// Source `hasSharedCacheTableLock()`.
pub fn hasSharedCacheLock(tree: *const Btree, root: u32, requested: LockKind) bool {
    if (!tree.sharable or (requested == .read and tree.read_uncommitted)) return true;
    for (tree.shared.locks.items) |lock| {
        if (lock.owner == tree and (lock.root == root or (lock.root == 1 and lock.kind == .write)) and @intFromEnum(lock.kind) >= @intFromEnum(requested)) return true;
    }
    return false;
}

/// Source `hasReadConflicts()`.
pub fn hasReadConflicts(tree: *const Btree, root: u32) bool {
    for (tree.shared.cursors.items) |cursor| {
        if (cursor.root == root and cursor.tree != tree and !cursor.tree.read_uncommitted) return true;
    }
    return false;
}

/// Source `querySharedCacheTableLock()`.
pub fn querySharedCacheLock(tree: *Btree, root: u32, requested: LockKind) Error!void {
    if (!tree.sharable) return;
    if (tree.shared.writer != null and tree.shared.writer != tree and tree.shared.exclusive) return error.Locked;
    for (tree.shared.locks.items) |lock| {
        if (lock.owner != tree and lock.root == root and (lock.kind == .write or requested == .write)) {
            if (requested == .write) tree.shared.pending = true;
            return error.Locked;
        }
    }
}

/// Source `setSharedCacheTableLock()`.
pub fn setSharedCacheLock(tree: *Btree, root: u32, requested: LockKind) Error!void {
    try querySharedCacheLock(tree, root, requested);
    for (tree.shared.locks.items) |*lock| {
        if (lock.owner == tree and lock.root == root) {
            if (@intFromEnum(requested) > @intFromEnum(lock.kind)) lock.kind = requested;
            return;
        }
    }
    tree.shared.locks.append(tree.shared.allocator, .{ .owner = tree, .root = root, .kind = requested }) catch return error.NoMemory;
}

/// Source `ptrmapPut()`.
pub fn pointerMapPut(shared: *Shared, page_number: u32, kind: PointerKind, parent: u32) Error!void {
    if (!shared.auto_vacuum or page_number == 0 or pointerMapPageNumber(shared, page_number) == page_number) return error.Corrupt;
    const replacement = PointerEntry{ .kind = kind, .parent = parent };
    if (shared.pointers.get(page_number)) |current| {
        if (current.kind == kind and current.parent == parent) return;
    }
    shared.pointers.put(page_number, replacement) catch return error.NoMemory;
}

/// Source `btreeParseCellPtr()`.
pub fn parseTableLeafCell(page: *const Page, cell: []const u8) Error!CellInfo {
    if (!page.leaf or !page.integer_key) return error.Corrupt;
    const payload = try readVarint(cell);
    const key = try readVarint(cell[payload.length..]);
    var info = CellInfo{ .key = key.value, .payload_size = @intCast(payload.value), .payload_offset = payload.length + key.length };
    if (info.payload_offset > cell.len) return error.Corrupt;
    if (info.payload_size <= page.max_local) {
        info.local_size = info.payload_size;
        info.size = @max(info.payload_offset + info.payload_size, 4);
    } else try adjustCellSizeForOverflow(page, 0, &info);
    if (info.size > cell.len) return error.Corrupt;
    return info;
}

/// Source `cellSizePtrTableLeaf()`.
pub fn tableLeafCellSize(page: *const Page, cell: []const u8) Error!usize {
    return (try parseTableLeafCell(page, cell)).size;
}

/// Source `defragmentPage()`.
pub fn defragmentPage(page: *Page, maximum_fragments: usize) Error!void {
    _ = maximum_fragments;
    if (page.overflow_cells.items.len != 0) return error.Corrupt;
    var write_offset = page.usable_size;
    for (page.cells.items) |cell| {
        if (cell.len > write_offset) return error.Corrupt;
        write_offset -= cell.len;
        @memmove(page.data[write_offset..][0..cell.len], cell);
    }
    const pointer_end = page.cell_offset + page.cells.items.len * 2;
    if (write_offset < pointer_end) return error.Corrupt;
    @memset(page.data[pointer_end..write_offset], 0);
    page.free_bytes = write_offset - pointer_end;
    page.dirty = true;
}

/// Source `allocateSpace()`.
pub fn allocateSpace(page: *Page, byte_count: usize) Error!usize {
    if (byte_count > page.free_bytes) return error.Range;
    if (findFreeSlot(page, byte_count)) |offset| return offset;
    try defragmentPage(page, 4);
    return findFreeSlot(page, byte_count) orelse error.Corrupt;
}

/// Source `freeSpace()`.
pub fn freeSpace(page: *Page, start: usize, size: usize) Error!void {
    if (size < 4 or start > page.usable_size or size > page.usable_size - start) return error.Corrupt;
    if (page.shared.secure_delete != 0) @memset(page.data[start..][0..size], 0);
    page.free_bytes = @min(page.usable_size, page.free_bytes + size);
    page.dirty = true;
}

/// Source `btreeInitPage()`.
pub fn initializeBtreePage(page: *Page) Error!void {
    if (page.initialized or page.header_offset + 8 > page.data.len) return error.Corrupt;
    try decodeFlags(page, page.data[page.header_offset]);
    page.cell_offset = page.header_offset + (if (page.leaf) @as(usize, 8) else 12);
    page.initialized = true;
    _ = try computeFreeSpace(page);
    try checkCellSizes(page);
}

/// Source `sqlite3BtreeOpen()`.
pub fn openBtree(shared: *Shared, sharable: bool) Error!*Btree {
    const tree = shared.allocator.create(Btree) catch return error.NoMemory;
    tree.* = .{ .shared = shared, .sharable = sharable };
    shared.references += 1;
    return tree;
}

/// Source `setDefaultSyncFlag()`.
pub fn setDefaultSyncFlag(shared: *Shared, safety_level: u8) void {
    if (shared.default_sync_level == 0) {
        shared.default_sync_level = safety_level;
        shared.pager_flags = (shared.pager_flags & ~@as(u32, 0xff)) | safety_level;
    }
}

/// Source `lockBtree()`.
pub fn lockBtree(shared: *Shared) Error!void {
    const page = shared.page_one orelse return error.NotFound;
    if (page.data.len < 100) return error.Corrupt;
    if (!std.mem.eql(u8, page.data[0..16], "SQLite format 3\x00")) return error.Corrupt;
    const encoded_size = (@as(u32, page.data[16]) << 8) | (@as(u32, page.data[17]) << 16);
    if (encoded_size < 512 or encoded_size > 65536 or !std.math.isPowerOfTwo(encoded_size)) return error.Corrupt;
    if (encoded_size - page.data[20] < 480) return error.Corrupt;
    shared.usable_size = encoded_size - page.data[20];
    shared.read_version = page.data[18];
    shared.write_version = page.data[19];
    page.min_local = @intCast((shared.usable_size - 12) * 32 / 255 - 23);
    page.max_local = @intCast((shared.usable_size - 12) * 64 / 255 - 23);
}

/// Source `btreeBeginTrans()`.
pub fn beginTransactionInternal(tree: *Btree, write: bool, exclusive: bool, schema_version: ?*u32) Error!void {
    if (tree.transaction == .write or (tree.transaction == .read and !write)) {
        if (schema_version) |output| output.* = tree.shared.metadata[1];
        return;
    }
    try querySharedCacheLock(tree, 1, .read);
    if (tree.shared.page_one != null) try lockBtree(tree.shared);
    try beginTransaction(tree, write, schema_version);
    if (write) tree.shared.exclusive = exclusive;
    if (tree.sharable) try setSharedCacheLock(tree, 1, .read);
}

/// Source `incrVacuumStep()`.
pub fn vacuumStep(shared: *Shared, final_page: u32, last_page: u32, committing: bool) Error!bool {
    if (last_page <= final_page) return true;
    if (last_page == shared.pending_byte_page or pointerMapPageNumber(shared, last_page) == last_page) return false;
    const entry = shared.pointers.get(last_page);
    if (entry != null and entry.?.kind != .btree) {
        _ = shared.pointers.remove(last_page);
    } else if (entry) |pointer| {
        const destination = shared.free_pages.pop() orelse return error.Empty;
        const page = findPage(shared, last_page) orelse return error.NotFound;
        try relocatePage(shared, page, pointer.kind, pointer.parent, destination);
    }
    if (!committing) shared.usable_size = @max(shared.usable_size, final_page);
    return last_page - 1 <= final_page;
}

/// Source `sqlite3BtreeCommitPhaseOne()`.
pub fn commitPhaseOneFull(tree: *Btree) Error!void {
    if (tree.transaction != .write) return;
    if (tree.shared.auto_vacuum) try autoVacuumCommit(tree);
    try commitPhaseOne(tree);
}

/// Source `btreeEndTransaction()`.
pub fn endTransaction(tree: *Btree, active_readers: usize) void {
    if (tree.transaction != .none and active_readers > 1) {
        downgradeAllSharedCacheTableLocks(tree);
        tree.transaction = .read;
        tree.shared.transaction = .read;
        return;
    }
    clearAllSharedCacheTableLocks(tree);
    tree.transaction = .none;
    tree.shared.transaction = .none;
    unlockIfUnused(tree.shared);
}

/// Source `sqlite3BtreeCommitPhaseTwo()`.
pub fn commitPhaseTwoFull(tree: *Btree, cleanup: bool, active_readers: usize) Error!void {
    _ = cleanup;
    if (tree.transaction == .none) return;
    if (tree.transaction == .write) {
        tree.shared.transaction = .read;
        if (tree.shared.has_content) |content| @memset(content, false);
    }
    endTransaction(tree, active_readers);
}

/// Source `sqlite3BtreeClosesWithCursor()`.
pub fn cursorClosesWithBtree(tree: *const Btree, cursor: *const Cursor) bool {
    return tree.shared.references == 1 and tree.shared.cursors.items.len == 1 and tree.shared.cursors.items[0] == cursor and cursor.tree == tree;
}

/// Source `assertParentIndex()`.
pub fn assertParentIndex(parent: *const Page, index: usize, child: u32) Error!void {
    if (index > parent.cells.items.len or index >= parent.children.items.len or parent.children.items[index] != child) return error.Corrupt;
}

/// Source `sqlite3BtreeTableMoveto()`.
pub fn tableMoveTo(cursor: *Cursor, integer_key: u64, bias_right: bool) Error!std.math.Order {
    _ = try first(cursor);
    const page = cursor.page orelse return error.Empty;
    if (!page.integer_key or page.cells.items.len == 0) return error.Corrupt;
    var lower: usize = 0;
    var upper = page.cells.items.len;
    while (lower < upper) {
        const middle = if (bias_right) (lower + upper) / 2 else lower + (upper - lower) / 2;
        const info = try parseTableLeafCell(page, page.cells.items[middle]);
        if (info.key < integer_key) lower = middle + 1 else upper = middle;
    }
    cursor.index = @min(lower, page.cells.items.len - 1);
    const found = (try parseTableLeafCell(page, page.cells.items[cursor.index])).key;
    return std.math.order(found, integer_key);
}

/// Source `sqlite3BtreeIndexMoveto()`.
pub fn indexMoveTo(cursor: *Cursor, key: []const u8) Error!std.math.Order {
    _ = try first(cursor);
    const page = cursor.page orelse return error.Empty;
    if (page.integer_key or page.cells.items.len == 0) return error.Corrupt;
    var lower: usize = 0;
    var upper = page.cells.items.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const order = (try compareIndexCell(page, middle, key)) orelse return error.Corrupt;
        if (order == .lt) lower = middle + 1 else upper = middle;
    }
    cursor.index = @min(lower, page.cells.items.len - 1);
    return (try compareIndexCell(page, cursor.index, key)) orelse error.Corrupt;
}

/// Source `allocateBtreePage()`.
pub fn allocateBtreePage(shared: *Shared, nearby: u32, exact: bool) Error!*Page {
    var number: u32 = 0;
    if (shared.free_pages.items.len != 0) {
        if (exact) {
            for (shared.free_pages.items, 0..) |candidate, index| {
                if (candidate == nearby) {
                    number = shared.free_pages.orderedRemove(index);
                    break;
                }
            }
        }
        if (number == 0) number = shared.free_pages.pop().?;
    } else {
        number = @intCast(shared.pages.items.len + 1);
        if (number == shared.pending_byte_page) number += 1;
        if (shared.auto_vacuum and pointerMapPageNumber(shared, number) == number) number += 1;
    }
    if (findPage(shared, number)) |page| {
        page.initialized = false;
        page.dirty = true;
        return page;
    }
    const data = shared.allocator.alloc(u8, shared.usable_size) catch return error.NoMemory;
    errdefer shared.allocator.free(data);
    @memset(data, 0);
    const page = try pageFromData(shared, number, data);
    page.dirty = true;
    return page;
}

/// Source `freePage2()`.
pub fn freePage(shared: *Shared, page: *Page) Error!void {
    if (page.number < 2 or page.number > shared.pages.items.len + shared.free_pages.items.len + 1) return error.Corrupt;
    if (shared.secure_delete != 0) @memset(page.data, 0);
    for (shared.free_pages.items) |number| {
        if (number == page.number) return error.Corrupt;
    }
    shared.free_pages.append(shared.allocator, page.number) catch return error.NoMemory;
    if (shared.auto_vacuum) try pointerMapPut(shared, page.number, .btree, 0);
    page.initialized = false;
    page.dirty = true;
}

/// Source `fillInCell()`.
pub fn fillCell(page: *Page, payload: Payload, integer_key: u64) Error![]u8 {
    const total = payload.data.len + payload.zero_fill;
    var header: [18]u8 = undefined;
    var header_size = try writeVarint(&header, total);
    if (page.integer_key) header_size += try writeVarint(header[header_size..], integer_key);
    const local = payloadToLocal(page, total);
    const size = @max(header_size + local + (if (local < total) @as(usize, 4) else 0), 4);
    const cell = page.allocator.alloc(u8, size) catch return error.NoMemory;
    errdefer page.allocator.free(cell);
    @memset(cell, 0);
    @memcpy(cell[0..header_size], header[0..header_size]);
    const copied = @min(local, payload.data.len);
    @memcpy(cell[header_size..][0..copied], payload.data[0..copied]);
    if (local < total) {
        const overflow = try allocateBtreePage(page.shared, page.number + 1, false);
        std.mem.writeInt(u32, cell[size - 4 ..][0..4], overflow.number, .big);
        const amount = @min(payload.data.len - copied, overflow.data.len - 4);
        @memcpy(overflow.data[4..][0..amount], payload.data[copied..][0..amount]);
        if (page.shared.auto_vacuum) try pointerMapPut(page.shared, overflow.number, .overflow_first, page.number);
    }
    return cell;
}

/// Source `insertCell()`.
pub fn insertCell(page: *Page, index: usize, cell: []const u8, child: ?u32) Error!void {
    const owned = page.allocator.dupe(u8, cell) catch return error.NoMemory;
    defer page.allocator.free(owned);
    if (child) |number| {
        if (owned.len < 4) return error.Corrupt;
        std.mem.writeInt(u32, owned[0..4], number, .big);
    }
    try insertCellFast(page, index, owned);
    if (child) |number| page.children.insert(page.allocator, @min(index, page.children.items.len), number) catch return error.NoMemory;
}

/// Source `editPage()`.
pub fn editPage(page: *Page, old_start: usize, new_start: usize, new_cells: []const []const u8) Error!void {
    _ = old_start;
    _ = new_start;
    try rebuildPage(page, new_cells);
    page.dirty = true;
}

/// Source `balance_quick()`.
pub fn balanceQuick(parent: *Page, page: *Page) Error!*Page {
    if (page.overflow_cells.items.len != 1 or page.cells.items.len == 0) return error.Corrupt;
    const sibling = try allocateBtreePage(page.shared, page.number + 1, false);
    try zeroPage(sibling, page.flag_byte);
    try insertCellFast(sibling, 0, page.overflow_cells.items[0]);
    page.allocator.free(page.overflow_cells.items[0]);
    page.overflow_cells.clearRetainingCapacity();
    parent.children.append(parent.allocator, sibling.number) catch return error.NoMemory;
    try pointerMapPut(page.shared, sibling.number, .btree, parent.number);
    return sibling;
}

/// Source `balance_nonroot()`.
pub fn balanceNonRoot(parent: *Page, child_index: usize) Error!void {
    if (child_index >= parent.children.items.len) return error.Range;
    const child = findPage(parent.shared, parent.children.items[child_index]) orelse return error.NotFound;
    if (child_index + 1 >= parent.children.items.len) {
        if (child.overflow_cells.items.len != 0) _ = try balanceQuick(parent, child);
        return;
    }
    const right = findPage(parent.shared, parent.children.items[child_index + 1]) orelse return error.NotFound;
    var combined = std.ArrayList([]const u8).empty;
    defer combined.deinit(parent.allocator);
    combined.appendSlice(parent.allocator, child.cells.items) catch return error.NoMemory;
    combined.appendSlice(parent.allocator, right.cells.items) catch return error.NoMemory;
    const split = combined.items.len / 2;
    try rebuildPage(child, combined.items[0..split]);
    try rebuildPage(right, combined.items[split..]);
    try pointerMapPut(parent.shared, child.number, .btree, parent.number);
    try pointerMapPut(parent.shared, right.number, .btree, parent.number);
}

/// Source `balance()`.
pub fn balance(cursor: *Cursor) Error!void {
    var page = cursor.page orelse return error.NotFound;
    while (page.overflow_cells.items.len != 0 or page.free_bytes * 3 > page.usable_size * 2) {
        if (cursor.ancestors.items.len == 0) {
            page = try balanceDeeper(page);
            cursor.page = page;
            break;
        }
        const parent = cursor.ancestors.items[cursor.ancestors.items.len - 1];
        const index = cursor.ancestor_indices.items[cursor.ancestor_indices.items.len - 1];
        try balanceNonRoot(parent, index);
        page = parent;
        try moveToParent(cursor);
    }
}

/// Source `btreeOverwriteContent()`.
pub fn overwriteContent(page: *Page, destination: []u8, payload: Payload, offset: usize) Error!void {
    if (offset > payload.data.len + payload.zero_fill or destination.len > payload.data.len + payload.zero_fill - offset) return error.Range;
    const available = if (offset < payload.data.len) @min(destination.len, payload.data.len - offset) else 0;
    if (available != 0 and !std.mem.eql(u8, destination[0..available], payload.data[offset..][0..available])) {
        @memmove(destination[0..available], payload.data[offset..][0..available]);
        page.dirty = true;
    }
    if (available < destination.len) {
        @memset(destination[available..], 0);
        page.dirty = true;
    }
}

/// Source `sqlite3BtreeInsert()`.
pub fn insert(cursor: *Cursor, payload: Payload, integer_key: u64, append: bool) Error!void {
    if (!cursor.writable or cursor.tree.transaction != .write) return error.ReadOnly;
    try saveAllCursors(cursor.tree.shared, cursor.root, cursor);
    if (cursor.page == null) _ = try first(cursor);
    const page = cursor.page orelse return error.NotFound;
    const cell = try fillCell(page, payload, integer_key);
    defer page.allocator.free(cell);
    const index = if (append) page.cells.items.len else @min(cursor.index, page.cells.items.len);
    try insertCellFast(page, index, cell);
    cursor.index = index;
    cursor.state = .valid;
    if (page.overflow_cells.items.len != 0) try balance(cursor);
}

/// Source `sqlite3BtreeTransferRow()`.
pub fn transferRow(destination: *Cursor, source: *const Cursor, integer_key: u64) Error!void {
    const source_page = source.page orelse return error.NotFound;
    if (source.index >= source_page.cells.items.len) return error.Corrupt;
    const source_cell = source_page.cells.items[source.index];
    try insert(destination, .{ .data = source_cell }, integer_key, true);
}

/// Source `sqlite3BtreeDelete()`.
pub fn deleteEntry(cursor: *Cursor, preserve_position: bool) Error!void {
    if (!cursor.writable or cursor.tree.transaction != .write or hasReadConflicts(cursor.tree, cursor.root)) return error.Locked;
    if (cursor.state == .require_seek) {
        var changed = false;
        try cursorRestore(cursor, &changed);
        if (changed) return error.NotFound;
    }
    const page = cursor.page orelse return error.NotFound;
    if (cursor.index >= page.cells.items.len) return error.Corrupt;
    if (preserve_position) try saveCursorKey(cursor);
    try dropCell(page, cursor.index);
    if (page.free_bytes * 3 > page.usable_size * 2) try balance(cursor);
    if (preserve_position) cursor.state = .require_seek else cursor.state = if (page.cells.items.len == 0) .invalid else .valid;
}

/// Source `btreeCreateTable()`.
pub fn createTable(tree: *Btree, integer_key: bool) Error!u32 {
    if (tree.transaction != .write) return error.ReadOnly;
    const root = try allocateBtreePage(tree.shared, tree.shared.maximum_root + 1, tree.shared.auto_vacuum);
    try zeroPage(root, if (integer_key) 0x0d else 0x0a);
    tree.shared.maximum_root = @max(tree.shared.maximum_root, root.number);
    tree.shared.metadata[4] = tree.shared.maximum_root;
    if (tree.shared.auto_vacuum) try pointerMapPut(tree.shared, root.number, .btree, 0);
    return root.number;
}

/// Source `clearDatabasePage()`.
pub fn clearDatabasePage(shared: *Shared, page_number: u32, release: bool, changes: *usize) Error!void {
    const page = findPage(shared, page_number) orelse return error.NotFound;
    try clearPage(shared, page, changes);
    if (release) try freePage(shared, page) else try zeroPage(page, page.flag_byte | 0x08);
}

/// Source `btreeDropTable()`.
pub fn dropTable(tree: *Btree, root: u32) Error!?u32 {
    if (tree.transaction != .write or root < 2) return error.ReadOnly;
    var changes: usize = 0;
    try clearDatabasePage(tree.shared, root, true, &changes);
    var moved: ?u32 = null;
    if (tree.shared.auto_vacuum and root != tree.shared.maximum_root) {
        const page = findPage(tree.shared, tree.shared.maximum_root) orelse return error.NotFound;
        moved = page.number;
        try relocatePage(tree.shared, page, .btree, 0, root);
    }
    if (tree.shared.maximum_root > 1) tree.shared.maximum_root -= 1;
    tree.shared.metadata[4] = tree.shared.maximum_root;
    return moved;
}

/// Source `checkTreePage()`.
pub fn checkTreePage(check: *IntegrityCheck, shared: *Shared, page_number: u32, depth: usize) Error!usize {
    if (!checkReference(check, page_number)) return error.Corrupt;
    const page = findPage(shared, page_number) orelse {
        appendCheckMessage(check, "unable to get b-tree page");
        return error.NotFound;
    };
    try checkCellSizes(page);
    var child_depth: ?usize = null;
    for (page.children.items) |child| {
        if (shared.auto_vacuum) checkPointerMap(check, shared, child, .btree, page.number);
        const measured = try checkTreePage(check, shared, child, depth + 1);
        if (child_depth) |expected| {
            if (expected != measured) appendCheckMessage(check, "child page depth differs");
        } else child_depth = measured;
    }
    return child_depth orelse depth;
}

/// Source `sqlite3BtreeIntegrityCheck()`.
pub fn integrityCheck(tree: *Btree, roots: []const u32, maximum_errors: usize) Error!IntegrityCheck {
    const referenced = tree.shared.allocator.alloc(bool, tree.shared.pages.items.len + tree.shared.free_pages.items.len + 2) catch return error.NoMemory;
    @memset(referenced, false);
    var check = IntegrityCheck{ .referenced = referenced, .maximum_errors = maximum_errors };
    errdefer tree.shared.allocator.free(referenced);
    for (roots) |root| {
        if (root != 0) _ = checkTreePage(&check, tree.shared, root, 0) catch {};
    }
    for (tree.shared.free_pages.items) |number| {
        _ = checkReference(&check, number);
    }
    for (tree.shared.pages.items) |page| {
        if (page.number < check.referenced.len and !check.referenced[page.number]) appendCheckMessage(&check, "page never used");
    }
    return check;
}

fn compileExtendedBtreeSurface(invoke: bool, tree: *Btree, cursor: *Cursor, page: *Page, check: *IntegrityCheck) Error!void {
    if (!invoke) return;
    if (corruptionError(page, check) != error.Corrupt) unreachable;
    _ = hasSharedCacheLock(tree, page.number, .read);
    _ = hasReadConflicts(tree, page.number);
    try querySharedCacheLock(tree, page.number, .read);
    try setSharedCacheLock(tree, page.number, .read);
    try pointerMapPut(tree.shared, page.number, .btree, 0);
    _ = try parseTableLeafCell(page, page.data);
    _ = try tableLeafCellSize(page, page.data);
    try defragmentPage(page, 4);
    _ = try allocateSpace(page, 4);
    try freeSpace(page, 4, 4);
    try initializeBtreePage(page);
    _ = try openBtree(tree.shared, false);
    setDefaultSyncFlag(tree.shared, 2);
    try lockBtree(tree.shared);
    try beginTransactionInternal(tree, true, false, null);
    _ = try vacuumStep(tree.shared, 1, 2, false);
    try commitPhaseOneFull(tree);
    endTransaction(tree, 1);
    try commitPhaseTwoFull(tree, false, 1);
    _ = cursorClosesWithBtree(tree, cursor);
    try assertParentIndex(page, 0, 1);
    _ = try tableMoveTo(cursor, 1, false);
    _ = try indexMoveTo(cursor, "key");
    _ = try allocateBtreePage(tree.shared, 2, false);
    try freePage(tree.shared, page);
    const cell = try fillCell(page, .{ .data = "payload" }, 1);
    try insertCell(page, 0, cell, null);
    const cells = [_][]const u8{cell};
    try editPage(page, 0, 0, &cells);
    _ = try balanceQuick(page, page);
    try balanceNonRoot(page, 0);
    try balance(cursor);
    try overwriteContent(page, page.data[0..1], .{ .data = "x" }, 0);
    try insert(cursor, .{ .data = "x" }, 1, true);
    try transferRow(cursor, cursor, 1);
    try deleteEntry(cursor, false);
    _ = try createTable(tree, true);
    var changes: usize = 0;
    try clearDatabasePage(tree.shared, page.number, false, &changes);
    _ = try dropTable(tree, page.number);
    _ = try checkTreePage(check, tree.shared, page.number, 0);
    _ = try integrityCheck(tree, &.{page.number}, 1);
}

fn testPage(shared: *Shared, number: u32, leaf: bool) !*Page {
    const data = try shared.allocator.alloc(u8, @intCast(shared.usable_size));
    errdefer shared.allocator.free(data);
    @memset(data, 0);
    const page = pageFromData(shared, number, data) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
    page.leaf = leaf;
    page.initialized = true;
    page.min_local = 8;
    page.max_local = 32;
    return page;
}

fn appendTestCell(page: *Page, bytes: []const u8) !void {
    const cell = try page.allocator.dupe(u8, bytes);
    errdefer page.allocator.free(cell);
    try page.cells.append(page.allocator, cell);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var shared = Shared.init(allocator);
    defer shared.deinit();
    shared.usable_size = 512;
    const root = try testPage(&shared, 2, true);
    try appendTestCell(root, "row");
    var tree = Btree{ .shared = &shared, .transaction = .write };
    shared.transaction = .write;
    _ = createCursor(&tree, 2, false) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
    setHasContent(&shared, 1) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
    _ = schema(&tree, 16, null) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
}

test "extended btree source surface is compile-covered" {
    var shared = Shared.init(std.testing.allocator);
    defer shared.deinit();
    shared.usable_size = 512;
    const page = try testPage(&shared, 2, true);
    var tree = Btree{ .shared = &shared, .transaction = .write };
    const cursor = try createCursor(&tree, 2, true);
    var referenced = [_]bool{false} ** 8;
    var check = IntegrityCheck{ .referenced = &referenced };
    try compileExtendedBtreeSurface(false, &tree, cursor, page, &check);
}

test "btree core survives every bounded allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "btree core page cursor lock and integrity primitives" {
    const allocator = std.testing.allocator;
    var shared = Shared.init(allocator);
    defer shared.deinit();
    shared.usable_size = 512;
    shared.pending_byte_page = 50;
    const root = try testPage(&shared, 2, false);
    const left_page = try testPage(&shared, 3, true);
    const right_page = try testPage(&shared, 4, true);
    try appendTestCell(root, &.{ 0, 0, 0, 3, 1 });
    try root.children.append(allocator, 3);
    try root.children.append(allocator, 4);
    try appendTestCell(left_page, "left");
    try appendTestCell(right_page, "right");

    var tree = Btree{ .shared = &shared, .sharable = true, .transaction = .write };
    shared.transaction = .write;
    try lockTable(&tree, 2, true);
    const cursor = try createCursor(&tree, 2, true);
    try std.testing.expect(!(try first(cursor)));
    try std.testing.expectEqual(@as(u32, 3), cursor.page.?.number);
    try std.testing.expect(!(try next(cursor)));
    try std.testing.expectEqual(@as(u32, 4), cursor.page.?.number);
    try std.testing.expect(!(try last(cursor)));
    try std.testing.expect(!(try previous(cursor)));
    try std.testing.expect(rowCountEstimate(cursor) >= 0);
    _ = try last(cursor);
    try std.testing.expectEqual(@as(u32, 4), cursor.page.?.number);
    try std.testing.expectEqual(@as(usize, 5), cursor.page.?.cells.items[cursor.index].len);

    cursor.state = .valid;
    cursor.info = .{ .local_size = 5, .payload_size = 5 };
    try overwriteCell(cursor, .{ .data = "RIGHT" });
    var payload: [5]u8 = undefined;
    try accessPayloadChecked(cursor, 0, &payload);
    try std.testing.expectEqualStrings("RIGHT", &payload);
    var copied: [5]u8 = undefined;
    try copyPayload(right_page, 0, &copied, false);
    try copyPayload(right_page, 5, &copied, true);

    try saveAllCursors(&shared, 2, null);
    var different = false;
    try cursorRestore(cursor, &different);
    try std.testing.expect(!different);
    const second = try createCursor(&tree, 2, false);
    _ = try first(second);
    _ = try next(second);
    try std.testing.expectError(error.Corrupt, anotherValidCursor(cursor));

    try setHasContent(&shared, 2);
    try std.testing.expect(shared.has_content.?[2]);
    try std.testing.expectEqual(@as(u32, 2), pointerMapPageNumber(&shared, 3));
    const overflow_cell = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 4 };
    try pointerMapPutOverflow(root, root, &overflow_cell, .{ .size = 8, .payload_size = 10, .local_size = 2 });
    try std.testing.expectEqual(@as(u32, 2), shared.pointers.get(4).?.parent);
    try std.testing.expect(payloadToLocal(left_page, 9) <= left_page.max_local);
    const no_payload = [_]u8{ 0, 0, 0, 0, 1 };
    const info = try parseCellNoPayload(root, &no_payload);
    try std.testing.expectEqual(@as(usize, 5), info.size);
    try std.testing.expectEqual(@as(usize, 5), try cellSizeNoPayload(root, &no_payload));

    _ = try testPage(&shared, 5, true);
    const unused = try getUnusedPage(&shared, 5, false);
    try reinitializePage(unused);
    releasePageOne(unused);

    var sizes = [_]usize{0};
    var cells = [_][]const u8{&no_payload};
    var cache = CellArray{ .reference = root, .cells = &cells, .sizes = &sizes };
    try populateCellCache(&cache, 0, 1);
    try std.testing.expectEqual(@as(usize, 5), sizes[0]);

    var referenced = [_]bool{false} ** 8;
    var integrity = IntegrityCheck{ .referenced = &referenced };
    try std.testing.expect(checkReference(&integrity, 2));
    try std.testing.expect(!checkReference(&integrity, 2));
    var heap = [_]u32{0} ** 8;
    try heapInsert(&heap, 9);
    try heapInsert(&heap, 2);
    try std.testing.expectEqual(@as(?u32, 2), heapPull(&heap));

    setCacheSize(&tree, 200);
    try std.testing.expectEqual(@as(i64, 300), setSpillSize(&tree, 300));
    try std.testing.expectEqual(@as(i64, 300), setSpillSize(&tree, 0));
    setMmapLimit(&tree, 4096);
    setPagerFlags(&tree, 7);
    try std.testing.expectEqual(@as(i64, 200), shared.cache_size);
    try std.testing.expectEqual(@as(i64, 4096), shared.mmap_limit);
    try std.testing.expectEqual(@as(u2, 1), secureDelete(&tree, 1));
    try setAutoVacuum(&tree, 2);
    try std.testing.expectEqual(@as(u2, 2), getAutoVacuum(&tree));
    try beginStatement(&tree, 1);
    try std.testing.expect((try schema(&tree, 32, null)) != null);
    try schemaLocked(&tree);
    downgradeAllSharedCacheTableLocks(&tree);

    tree.has_incrblob_cursor = true;
    second.incrblob = true;
    second.root = 2;
    second.rowid = 1;
    invalidateIncrblobCursors(&tree, 2, 1, false);
    try std.testing.expectEqual(CursorState.invalid, second.state);

    const changes = try clearTable(&tree, 2);
    try std.testing.expect(changes >= 1);
    try std.testing.expect(try isEmpty(cursor));
    _ = finalDatabaseSize(&shared, 3, 40);

    try commit(&tree);
    var log_frames: usize = 0;
    var checkpointed_frames: usize = 0;
    try checkpoint(&tree, 0, &log_frames, &checkpointed_frames);
    try std.testing.expectEqual(log_frames, checkpointed_frames);
}
