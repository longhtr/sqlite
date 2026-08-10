//! Process-wide named in-memory database registry corresponding to `memdb.c`.

const std = @import("std");
const mutex = @import("mutex.zig");
const vfs = @import("vfs.zig");

const maximum_shared_databases = 64;

pub const Shared = struct {
    name: [:0]u8,
    backend: vfs.MemoryVfs,
    anchor: *vfs.MemoryFile,
    references: usize = 1,
};

pub const OpenOutcome = struct {
    shared: *Shared,
    created: bool,
};

var initialized = false;
var stores: [maximum_shared_databases]?*Shared = .{null} ** maximum_shared_databases;
var store_count: usize = 0;

/// Source `sqlite3MemdbInit()`: initialize the process-wide named-memory VFS
/// registry. Repeated initialization is harmless and preserves live stores.
pub fn initialize() void {
    const lock = mutex.processStatic(.static_vfs1);
    lock.enter();
    defer lock.leave();
    if (!initialized) {
        initialized = true;
        store_count = 0;
        @memset(&stores, null);
    }
}

/// Source `memdbOpen()`: find or create a named shared memory store while
/// holding the static VFS mutex, then acquire one connection reference.
pub fn open(name: []const u8) error{ OutOfMemory, TooMany, OpenFailed }!OpenOutcome {
    initialize();
    const lock = mutex.processStatic(.static_vfs1);
    lock.enter();
    defer lock.leave();
    for (stores[0..store_count]) |entry| {
        const shared = entry orelse continue;
        if (std.mem.eql(u8, shared.name, name)) {
            shared.references += 1;
            return .{ .shared = shared, .created = false };
        }
    }
    if (store_count == stores.len) return error.TooMany;
    const allocator = std.heap.c_allocator;
    const shared = try allocator.create(Shared);
    errdefer allocator.destroy(shared);
    const owned_name = try allocator.dupeZ(u8, name);
    shared.* = .{ .name = owned_name, .backend = vfs.MemoryVfs.initMemdb(allocator), .anchor = undefined };
    const anchored = shared.backend.open("/main", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (anchored.rc != vfs.OK) {
        shared.backend.deinit();
        allocator.free(owned_name);
        return error.OpenFailed;
    }
    shared.anchor = anchored.file.?;
    stores[store_count] = shared;
    store_count += 1;
    return .{ .shared = shared, .created = true };
}

/// Source `memdbClose()`: drop a connection reference and destroy an
/// unreferenced named store after removing it atomically from the registry.
pub fn close(shared: *Shared) void {
    const lock = mutex.processStatic(.static_vfs1);
    lock.enter();
    std.debug.assert(shared.references != 0);
    shared.references -= 1;
    if (shared.references != 0) {
        lock.leave();
        return;
    }
    var found: ?usize = null;
    for (stores[0..store_count], 0..) |entry, index| {
        if (entry == shared) {
            found = index;
            break;
        }
    }
    const index = found orelse {
        lock.leave();
        return;
    };
    store_count -= 1;
    stores[index] = stores[store_count];
    stores[store_count] = null;
    lock.leave();
    const allocator = std.heap.c_allocator;
    _ = shared.backend.closeAndDestroy(shared.anchor);
    shared.backend.deinit();
    allocator.free(shared.name);
    allocator.destroy(shared);
}

/// Source `memdbAccess()`: report whether a named process-local store is
/// currently registered without creating it or changing its reference count.
pub fn access(name: []const u8) bool {
    if (!initialized) return false;
    const lock = mutex.processStatic(.static_vfs1);
    lock.enter();
    defer lock.leave();
    for (stores[0..store_count]) |entry| {
        if (entry) |shared| {
            if (std.mem.eql(u8, shared.name, name)) return true;
        }
    }
    return false;
}

/// Source `memdbFullPathname()`: named memory paths are already canonical;
/// copy the path into caller-owned, sentinel-terminated storage.
pub fn fullPathname(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![:0]u8 {
    return allocator.dupeZ(u8, name);
}

pub const SchemaStore = struct {
    backend: *vfs.MemoryVfs,
    allow_no_copy: bool,
};

/// Source `memdbFromDbSchema()`: resolve the main schema to its private or
/// named memory store and distinguish stores eligible for NOCOPY borrowing.
pub fn fromSchema(private: ?*vfs.MemoryVfs, shared: ?*Shared, schema: ?[]const u8) ?SchemaStore {
    if (schema) |name| {
        if (!std.ascii.eqlIgnoreCase(name, "main")) return null;
    }
    if (private) |backend| return .{ .backend = backend, .allow_no_copy = true };
    if (shared) |entry| return .{ .backend = &entry.backend, .allow_no_copy = false };
    return null;
}

/// Source `memdbFetch()`: return a bounded borrowed range when it is wholly
/// contained in the current memory image.
pub fn fetch(backend: *vfs.MemoryVfs, name: []const u8, offset: usize, amount: usize) ?[]u8 {
    const image = backend.borrowVolatile(name) orelse return null;
    const end = std.math.add(usize, offset, amount) catch return null;
    if (end > image.len) return null;
    return image[offset..end];
}

/// Source `memdbRead()`: copy a bounded image range and zero-fill a short
/// read while preserving SQLITE_IOERR_SHORT_READ.
pub fn read(backend: *vfs.MemoryVfs, name: []const u8, output: []u8, offset: usize) c_int {
    @memset(output, 0);
    const image = backend.borrowVolatile(name) orelse return vfs.IOERR_SHORT_READ;
    if (offset >= image.len) return if (output.len == 0) vfs.OK else vfs.IOERR_SHORT_READ;
    const amount = @min(output.len, image.len - offset);
    @memcpy(output[0..amount], image[offset..][0..amount]);
    return if (amount == output.len) vfs.OK else vfs.IOERR_SHORT_READ;
}

/// Source `memdbEnlarge()`: enforce the configured memory-store size ceiling
/// before a write asks the backing VFS to grow its image.
pub fn enlarge(backend: *vfs.MemoryVfs, requested_size: usize) c_int {
    if (backend.memdb_max_size < 0) return vfs.FULL;
    if (requested_size > @as(usize, @intCast(backend.memdb_max_size))) return vfs.FULL;
    return vfs.OK;
}

/// Source `memdbWrite()`: grow within the memory limit, zero gaps through the
/// VFS write contract, and preserve the backing file's result code.
pub fn write(backend: *vfs.MemoryVfs, name: []const u8, input: []const u8, offset: usize) c_int {
    const end = std.math.add(usize, offset, input.len) catch return vfs.FULL;
    const growth = enlarge(backend, end);
    if (growth != vfs.OK) return growth;
    const opened = backend.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return opened.rc;
    const file = opened.file.?;
    const result = file.write(input, offset);
    const close_result = backend.closeAndDestroy(file);
    return if (result == vfs.OK) close_result else result;
}

/// Source `memdbTruncate()`: reject growth and reduce a named memory image
/// through its active VFS file implementation.
pub fn truncate(backend: *vfs.MemoryVfs, name: []const u8, size: usize) c_int {
    const image = backend.borrowVolatile(name) orelse return vfs.CORRUPT;
    if (size > image.len) return vfs.CORRUPT;
    const opened = backend.open(name, vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return opened.rc;
    const file = opened.file.?;
    const result = file.truncate(size);
    const close_result = backend.closeAndDestroy(file);
    return if (result == vfs.OK) close_result else result;
}

/// Source `memdbFileControl()`: apply or query the memory image size limit,
/// never reducing it below the current logical database size.
pub fn fileControl(backend: *vfs.MemoryVfs, name: []const u8, requested_limit: i64) i64 {
    const current: i64 = if (backend.borrowVolatile(name)) |image| @intCast(image.len) else 0;
    var limit = requested_limit;
    if (limit < current) {
        limit = if (limit < 0) backend.memdb_max_size else current;
    }
    backend.memdb_max_size = limit;
    return limit;
}

pub const Serialization = union(enum) {
    borrowed: []u8,
    owned: []u8,
};

/// Source `sqlite3_serialize()`: borrow eligible private images for NOCOPY or
/// produce an allocator-owned, short-read-checked database image.
pub fn serialize(allocator: std.mem.Allocator, store: SchemaStore, name: []const u8, no_copy: bool) std.mem.Allocator.Error!?Serialization {
    const image = store.backend.borrowVolatile(name) orelse return null;
    if (no_copy) {
        if (!store.allow_no_copy) return null;
        return .{ .borrowed = fetch(store.backend, name, 0, image.len) orelse return null };
    }
    const copy = try allocator.alloc(u8, image.len);
    errdefer allocator.free(copy);
    if (read(store.backend, name, copy, 0) != vfs.OK) return null;
    return .{ .owned = copy };
}

/// Source `sqlite3_deserialize()`: create a private memdb, transfer the caller
/// buffer into its main file, and preserve resize and readonly ownership flags.
pub fn deserialize(
    allocator: std.mem.Allocator,
    data: [*]u8,
    size: usize,
    capacity: usize,
    flags: c_uint,
    maximum: i64,
) error{ InvalidSize, OutOfMemory, OpenFailed }!vfs.MemoryVfs {
    if (size > capacity) return error.InvalidSize;
    var backend = vfs.MemoryVfs.init(allocator);
    backend.memdb_max_size = maximum;
    errdefer backend.deinit();
    const opened = backend.open("main", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc == vfs.NOMEM) return error.OutOfMemory;
    if (opened.rc != vfs.OK) return error.OpenFailed;
    const file = opened.file.?;
    backend.adoptVolatileBuffer(file, data, size, capacity, flags);
    _ = backend.closeAndDestroy(file);
    return backend;
}

test "deserialize preserves the configured memdb maximum" {
    const data = try std.testing.allocator.alloc(u8, 16);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var backend = try deserialize(std.testing.allocator, data.ptr, data.len, data.len, vfs.DESERIALIZE_RESIZEABLE, 16);
    defer backend.deinit();
    const opened = backend.open("main", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(vfs.OK, opened.rc);
    const file = opened.file.?;
    try std.testing.expectEqual(vfs.FULL, file.write(&.{1}, data.len));
    try std.testing.expectEqual(vfs.OK, backend.closeAndDestroy(file));
}
