//! Online backup page-copy state machine from `backup.c`.
const std = @import("std");

pub const Error = error{ OutOfMemory, NotFound, SameConnection, DestinationBusy, Busy, ReadOnly, Io, Done };
pub const Transaction = enum { none, read, write };

pub const Btree = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    page_size: usize,
    reserve_bytes: u8 = 0,
    schema_cookie: u32 = 0,
    default_cache_size: u32 = 0,
    text_encoding: u32 = 1,
    user_version: u32 = 0,
    application_id: u32 = 0,
    auto_vacuum: u8 = 0,
    transaction: Transaction = .none,
    journal_mode_wal: bool = false,
    memory_database: bool = false,
    backup_count: usize = 0,
    data: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Btree) void {
        self.data.deinit(self.allocator);
    }

    pub fn pageCount(self: *const Btree) usize {
        if (self.data.items.len == 0) return 0;
        return (self.data.items.len + self.page_size - 1) / self.page_size;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    databases: []Btree,
    schema_generation: usize = 0,
    last_error: ?Error = null,
};

/// Source `isFatalError()`: BUSY is the only retryable error represented by
/// this typed backup owner; LOCKED is not in its local error set.
pub fn isFatalError(result: ?Error) bool {
    return if (result) |failure| failure != error.Busy else false;
}

pub const Backup = struct {
    allocator: std.mem.Allocator,
    destination_connection: *Connection,
    destination_name: []u8,
    destination: ?*Btree = null,
    destination_schema: u32 = 0,
    destination_locked: bool = false,
    next_page: usize = 1,
    source_connection: *Connection,
    source: *Btree,
    result: ?Error = null,
    remaining: usize = 0,
    page_count: usize = 0,
    attached: bool = false,
};

/// Source `findBtree()`.
pub fn findBtree(error_connection: *Connection, connection: *Connection, name: []const u8) ?*Btree {
    for (connection.databases) |*tree| {
        if (std.ascii.eqlIgnoreCase(tree.name, name)) return tree;
    }
    error_connection.last_error = error.NotFound;
    return null;
}

fn resizeZero(tree: *Btree, size: usize) Error!void {
    const old = tree.data.items.len;
    tree.data.resize(tree.allocator, size) catch return error.OutOfMemory;
    if (size > old) @memset(tree.data.items[old..], 0);
}

/// Source `backupOnePage()`.
pub fn backupOnePage(backup: *Backup, source_page: usize, source_data: []const u8, is_update: bool) Error!void {
    const destination = backup.destination orelse return error.NotFound;
    std.debug.assert(backup.destination_locked);
    const source_size = backup.source.page_size;
    const destination_size = destination.page_size;
    const copy_size = @min(source_size, destination_size);
    const end = std.math.mul(usize, source_page, source_size) catch return error.Io;
    var offset = end - source_size;
    while (offset < end) : (offset += destination_size) {
        const destination_page = offset / destination_size + 1;
        const destination_offset = (destination_page - 1) * destination_size;
        try resizeZero(destination, destination_offset + destination_size);
        const input_offset = offset % source_size;
        const output_offset = offset % destination_size;
        @memcpy(destination.data.items[destination_offset + output_offset ..][0..copy_size], source_data[input_offset..][0..copy_size]);
        if (offset == 0 and !is_update and destination.data.items.len >= 32) {
            std.mem.writeInt(u32, destination.data.items[28..32], @intCast(backup.source.pageCount()), .big);
        }
    }
}

/// Source `sqlite3_backup_init()`.
pub fn initialize(destination_connection: *Connection, destination_name: []const u8, source_connection: *Connection, source_name: []const u8) Error!*Backup {
    if (destination_connection == source_connection) return error.SameConnection;
    const destination = findBtree(destination_connection, destination_connection, destination_name) orelse return error.NotFound;
    const source = findBtree(destination_connection, source_connection, source_name) orelse return error.NotFound;
    if (destination.transaction != .none) return error.DestinationBusy;
    const backup = destination_connection.allocator.create(Backup) catch return error.OutOfMemory;
    errdefer destination_connection.allocator.destroy(backup);
    const owned_name = destination_connection.allocator.dupe(u8, destination_name) catch return error.OutOfMemory;
    backup.* = .{
        .allocator = destination_connection.allocator,
        .destination_connection = destination_connection,
        .destination_name = owned_name,
        .source_connection = source_connection,
        .source = source,
    };
    source.backup_count += 1;
    return backup;
}

/// Source `sqlite3_backup_step()`.
pub fn step(backup: *Backup, requested_pages: isize) Error!void {
    if (isFatalError(backup.result)) return backup.result.?;
    if (backup.source.transaction == .write) {
        backup.result = error.Busy;
        return error.Busy;
    }
    const opened_source = backup.source.transaction == .none;
    if (opened_source) {
        backup.source.transaction = .read;
    }
    defer if (opened_source) {
        backup.source.transaction = .none;
    };

    const destination = backup.destination orelse findBtree(backup.destination_connection, backup.destination_connection, backup.destination_name) orelse return error.NotFound;
    backup.destination = destination;
    if (!backup.destination_locked) {
        if (!destination.journal_mode_wal and !destination.memory_database) destination.page_size = backup.source.page_size;
        destination.transaction = .write;
        backup.destination_schema = destination.schema_cookie;
        backup.destination_locked = true;
    }
    const source_page_size = backup.source.page_size;
    const destination_page_size = destination.page_size;
    if ((destination.journal_mode_wal or destination.memory_database) and source_page_size != destination_page_size) {
        backup.result = error.ReadOnly;
        return error.ReadOnly;
    }
    const source_count = backup.source.pageCount();
    const pending_page = @as(usize, 0x4000_0000) / source_page_size + 1;
    const limit: usize = if (requested_pages < 0) std.math.maxInt(usize) else @intCast(requested_pages);
    var copied: usize = 0;
    while (copied < limit and backup.next_page <= source_count) : ({
        copied += 1;
        backup.next_page += 1;
    }) {
        if (backup.next_page == pending_page) {
            continue;
        }
        const start = (backup.next_page - 1) * source_page_size;
        const available = @min(source_page_size, backup.source.data.items.len - start);
        const temporary = backup.allocator.alloc(u8, source_page_size) catch return error.OutOfMemory;
        defer backup.allocator.free(temporary);
        @memset(temporary, 0);
        @memcpy(temporary[0..available], backup.source.data.items[start .. start + available]);
        try backupOnePage(backup, backup.next_page, temporary, false);
    }
    backup.page_count = source_count;
    backup.remaining = source_count + 1 - backup.next_page;
    if (backup.next_page <= source_count) {
        backup.attached = true;
        backup.result = null;
        return;
    }
    var final_source_pages = source_count;
    if (final_source_pages == 0) {
        final_source_pages = 1;
        try resizeZero(destination, destination_page_size);
        @memset(destination.data.items, 0);
    }
    destination.schema_cookie = backup.destination_schema +% 1;
    const destination_pages = if (source_page_size < destination_page_size)
        (final_source_pages + destination_page_size / source_page_size - 1) / (destination_page_size / source_page_size)
    else
        final_source_pages * (source_page_size / destination_page_size);
    const final_size = destination_pages * destination_page_size;
    if (destination.data.items.len > final_size) destination.data.shrinkRetainingCapacity(final_size);
    destination.transaction = .none;
    backup.destination_connection.schema_generation += 1;
    backup.result = error.Done;
    return error.Done;
}

/// Source `sqlite3_backup_finish()`.
pub fn finish(backup: ?*Backup) ?Error {
    const value = backup orelse return null;
    if (value.source.backup_count > 0) {
        value.source.backup_count -= 1;
    }
    if (value.destination) |destination| {
        if (destination.transaction == .write) {
            destination.transaction = .none;
        }
    }
    const result: ?Error = if (value.result) |failure|
        if (failure == error.Done) null else failure
    else
        null;
    value.allocator.free(value.destination_name);
    value.allocator.destroy(value);
    return result;
}

/// Source `backupUpdate()`.
pub fn update(backup: ?*Backup, page: usize, data: []const u8) void {
    var current = backup;
    while (current) |value| {
        if (!isFatalError(value.result) and page < value.next_page) {
            backupOnePage(value, page, data, true) catch |failure| {
                value.result = failure;
            };
        }
        current = null;
    }
}

/// Source `sqlite3BtreeCopyFile()`.
pub fn copyFile(destination: *Btree, source: *Btree) Error!void {
    if (destination.transaction != .write or source.transaction == .none) return error.DestinationBusy;
    destination.page_size = source.page_size;
    try resizeZero(destination, source.data.items.len);
    @memcpy(destination.data.items, source.data.items);
    destination.schema_cookie +%= 1;
    destination.transaction = .none;
}

test "checkpoint batch backup step copies pages and commits a changed schema cookie" {
    var source_databases = [_]Btree{.{ .allocator = std.testing.allocator, .name = "main", .page_size = 512, .schema_cookie = 7 }};
    defer source_databases[0].deinit();
    try source_databases[0].data.resize(std.testing.allocator, 700);
    @memset(source_databases[0].data.items, 0x33);
    var destination_databases = [_]Btree{.{ .allocator = std.testing.allocator, .name = "main", .page_size = 1024, .schema_cookie = 11 }};
    defer destination_databases[0].deinit();
    var source_connection = Connection{ .allocator = std.testing.allocator, .databases = &source_databases };
    var destination_connection = Connection{ .allocator = std.testing.allocator, .databases = &destination_databases };
    const handle = try initialize(&destination_connection, "main", &source_connection, "main");
    try std.testing.expect(!isFatalError(null));
    try std.testing.expect(!isFatalError(error.Busy));
    try std.testing.expect(isFatalError(error.Io));
    try std.testing.expect(isFatalError(error.Done));
    try std.testing.expectError(error.Done, step(handle, -1));
    try std.testing.expectEqual(@as(u32, 12), destination_databases[0].schema_cookie);
    try std.testing.expectEqual(@as(usize, 1024), destination_databases[0].data.items.len);
    try std.testing.expectEqual(@as(u8, 0x33), destination_databases[0].data.items[699]);
    try std.testing.expect(finish(handle) == null);
}
