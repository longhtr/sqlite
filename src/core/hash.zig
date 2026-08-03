//! Case-insensitive string hash table translated from SQLite `src/hash.c`.
//!
//! Fidelity constraints:
//! - keys and values remain caller-owned and keys are zero-terminated;
//! - replacement is ASCII-case-insensitive and retains SQLite's hash value;
//! - every element remains on one doubly-linked list, grouped by bucket;
//! - tables with fewer than five entries use a linear search;
//! - bucket allocation failure is benign, while element allocation failure
//!   returns the new value and leaves the table unchanged.

const std = @import("std");
const sqlite_string = @import("string.zig");
const Allocator = std.mem.Allocator;
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const layout = @import("generated/internal_vdbe_layout.zig");

const malloc_soft_limit: u32 = 1024;

/// Upstream: src/hash.h :: struct _ht (line 47)
pub const Bucket = extern struct {
    count: c_uint,
    chain: ?*HashElem,
};

/// Upstream: src/hash.h :: HashElem (line 59)
pub const HashElem = extern struct {
    next: ?*HashElem,
    prev: ?*HashElem,
    data: ?*anyopaque,
    key: [*:0]const u8,
    hash_value: c_uint,

    /// Equivalent to `sqliteHashNext`.
    pub fn nextElement(self: *const HashElem) ?*HashElem {
        return self.next;
    }

    /// Equivalent to `sqliteHashData`.
    pub fn value(self: *const HashElem) ?*anyopaque {
        return self.data;
    }
};

/// Upstream: src/hash.h :: Hash (line 43)
pub const Hash = extern struct {
    bucket_count: c_uint,
    entry_count: c_uint,
    first_entry: ?*HashElem,
    buckets: ?[*]Bucket,

    /// Upstream: sqlite3HashInit (line 23).
    pub fn init() Hash {
        return std.mem.zeroes(Hash);
    }

    /// Initialize caller-provided bulk storage, as `sqlite3HashInit` does.
    pub fn initialize(self: *Hash) void {
        std.debug.assert(@intFromPtr(self) != 0);
        self.first_entry = null;
        self.entry_count = 0;
        self.bucket_count = 0;
        self.buckets = null;
    }

    /// Upstream: sqlite3HashClear (line 35).
    pub fn clear(self: *Hash, allocator: Allocator) void {
        std.debug.assert(@intFromPtr(self) != 0);
        var element = self.first_entry;
        self.first_entry = null;
        if (self.buckets) |buckets| {
            allocator.free(buckets[0..@intCast(self.bucket_count)]);
        }
        self.buckets = null;
        self.bucket_count = 0;
        while (element) |current| {
            const next = current.next;
            allocator.destroy(current);
            element = next;
        }
        self.entry_count = 0;
    }

    /// Upstream: sqlite3HashFind (line 222).
    pub fn find(self: *const Hash, key: [*:0]const u8) ?*anyopaque {
        std.debug.assert(@intFromPtr(self) != 0);
        return if (findElementWithHash(self, key, null)) |element| element.data else null;
    }

    /// Upstream: sqlite3HashInsert (line 242).
    ///
    /// Returns the replaced/removed value, null for a successful new insert,
    /// or `data` if the element allocation fails. The key is never copied.
    pub fn insert(
        self: *Hash,
        allocator: Allocator,
        key: [*:0]const u8,
        data: ?*anyopaque,
    ) ?*anyopaque {
        std.debug.assert(@intFromPtr(self) != 0);

        var hash_value: u32 = undefined;
        if (findElementWithHash(self, key, &hash_value)) |element| {
            const old_data = element.data.?;
            if (data == null) {
                removeElement(self, allocator, element);
            } else {
                element.data = data;
                element.key = key;
            }
            return old_data;
        }
        if (data == null) return null;

        const new_element = allocator.create(HashElem) catch return data;
        new_element.key = key;
        new_element.hash_value = hash_value;
        new_element.data = data;
        self.entry_count +%= 1;
        if (self.entry_count >= 5 and self.entry_count > 2 *% self.bucket_count) {
            _ = rehash(self, allocator, self.entry_count *% 3);
        }
        const bucket = if (self.buckets) |buckets|
            &buckets[new_element.hash_value % self.bucket_count]
        else
            null;
        insertElement(self, bucket, new_element);
        return null;
    }

    /// Equivalent to `sqliteHashFirst`.
    pub fn first(self: *const Hash) ?*HashElem {
        return self.first_entry;
    }

    /// Equivalent to `sqliteHashCount`.
    pub fn count(self: *const Hash) c_uint {
        return self.entry_count;
    }
};

/// Upstream: strHash (line 55). The initial profile is ASCII, not EBCDIC.
fn stringHash(key: [*:0]const u8) u32 {
    var result: u32 = 0;
    var index: usize = 0;
    while (key[index] != 0) : (index += 1) {
        result +%= key[index] & 0xdf;
        result *%= 0x9e3779b1;
    }
    return result;
}

/// Upstream: insertElement (line 79).
fn insertElement(hash: *Hash, bucket: ?*Bucket, new_element: *HashElem) void {
    const head: ?*HashElem = if (bucket) |entry| blk: {
        const old_head = if (entry.count != 0) entry.chain else null;
        entry.count +%= 1;
        entry.chain = new_element;
        break :blk old_head;
    } else null;

    if (head) |old_head| {
        new_element.next = old_head;
        new_element.prev = old_head.prev;
        if (old_head.prev) |previous| {
            previous.next = new_element;
        } else {
            hash.first_entry = new_element;
        }
        old_head.prev = new_element;
    } else {
        new_element.next = hash.first_entry;
        if (hash.first_entry) |first| first.prev = new_element;
        new_element.prev = null;
        hash.first_entry = new_element;
    }
}

/// Upstream: rehash (line 113). Allocation failure is intentionally benign.
fn rehash(hash: *Hash, allocator: Allocator, requested_size: u32) bool {
    var new_size = requested_size;
    const bucket_limit: u32 = malloc_soft_limit / @sizeOf(Bucket);
    if (@as(usize, new_size) * @sizeOf(Bucket) > malloc_soft_limit) {
        new_size = bucket_limit;
    }
    if (new_size == hash.bucket_count) return false;

    const new_buckets = allocator.alloc(Bucket, @intCast(new_size)) catch return false;
    if (hash.buckets) |old_buckets| {
        allocator.free(old_buckets[0..@intCast(hash.bucket_count)]);
    }
    @memset(new_buckets, std.mem.zeroes(Bucket));
    hash.buckets = new_buckets.ptr;
    hash.bucket_count = @intCast(new_buckets.len);

    var element = hash.first_entry;
    hash.first_entry = null;
    while (element) |current| {
        const next = current.next;
        insertElement(hash, &new_buckets[current.hash_value % new_size], current);
        element = next;
    }
    return true;
}

/// Upstream: findElementWithHash (line 153).
fn findElementWithHash(
    hash: *const Hash,
    key: [*:0]const u8,
    output_hash: ?*u32,
) ?*HashElem {
    const hash_value = stringHash(key);
    var element: ?*HashElem = undefined;
    var remaining: u32 = undefined;
    if (hash.buckets) |buckets| {
        const bucket = &buckets[hash_value % hash.bucket_count];
        element = bucket.chain;
        remaining = bucket.count;
    } else {
        element = hash.first_entry;
        remaining = hash.entry_count;
    }
    if (output_hash) |output| output.* = hash_value;
    while (remaining != 0) : (remaining -= 1) {
        const current = element.?;
        if (hash_value == current.hash_value and sqlite_string.compareInternal(current.key, key) == 0) {
            return current;
        }
        element = current.next;
    }
    return null;
}

/// Upstream: removeElement (line 188).
fn removeElement(hash: *Hash, allocator: Allocator, element: *HashElem) void {
    if (element.prev) |previous| {
        previous.next = element.next;
    } else {
        hash.first_entry = element.next;
    }
    if (element.next) |next| next.prev = element.prev;

    if (hash.buckets) |buckets| {
        const bucket = &buckets[element.hash_value % hash.bucket_count];
        if (bucket.chain == element) bucket.chain = element.next;
        std.debug.assert(bucket.count > 0);
        bucket.count -= 1;
    }
    allocator.destroy(element);
    hash.entry_count -= 1;
    if (hash.entry_count == 0) {
        std.debug.assert(hash.first_entry == null);
        hash.clear(allocator);
    }
}

comptime {
    if (@sizeOf(Bucket) != layout.HashBucket.size or @alignOf(Bucket) != layout.HashBucket.alignment or
        @offsetOf(Bucket, "count") != layout.HashBucket.count_offset or
        @offsetOf(Bucket, "chain") != layout.HashBucket.chain_offset)
        @compileError("Hash bucket layout differs from pinned C profile");
    if (@sizeOf(HashElem) != layout.HashElem.size or @alignOf(HashElem) != layout.HashElem.alignment or
        @offsetOf(HashElem, "next") != layout.HashElem.next_offset or
        @offsetOf(HashElem, "prev") != layout.HashElem.prev_offset or
        @offsetOf(HashElem, "data") != layout.HashElem.data_offset or
        @offsetOf(HashElem, "key") != layout.HashElem.pKey_offset or
        @offsetOf(HashElem, "hash_value") != layout.HashElem.h_offset)
        @compileError("HashElem layout differs from pinned C profile");
    if (@sizeOf(Hash) != layout.Hash.size or @alignOf(Hash) != layout.Hash.alignment or
        @offsetOf(Hash, "bucket_count") != layout.Hash.htsize_offset or
        @offsetOf(Hash, "entry_count") != layout.Hash.count_offset or
        @offsetOf(Hash, "first_entry") != layout.Hash.first_offset or
        @offsetOf(Hash, "buckets") != layout.Hash.ht_offset)
        @compileError("Hash layout differs from pinned C profile");
}

fn valuePointer(value: usize) *anyopaque {
    return @ptrFromInt(value);
}

fn expectList(hash: *const Hash, expected: []const []const u8) !void {
    var element = hash.first();
    for (expected) |key| {
        const current = element orelse return error.ShortList;
        try std.testing.expectEqualStrings(key, std.mem.span(current.key));
        element = current.nextElement();
    }
    try std.testing.expectEqual(null, element);
}

test "C layout matches the initial 64-bit target" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Bucket));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(HashElem));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Hash));
    try std.testing.expectEqual(@as(u32, 64), malloc_soft_limit / @sizeOf(Bucket));
}

test "initialization and empty operations" {
    var hash: Hash = undefined;
    hash.initialize();
    try std.testing.expectEqual(@as(c_uint, 0), hash.count());
    try std.testing.expectEqual(null, hash.first());
    try std.testing.expectEqual(null, hash.find("missing"));
    try std.testing.expectEqual(null, hash.insert(std.testing.allocator, "missing", null));
    hash.clear(std.testing.allocator);
}

test "insert replacement lookup and removal are case insensitive" {
    const allocator = std.testing.allocator;
    var hash = Hash.init();
    defer hash.clear(allocator);

    try std.testing.expectEqual(null, hash.insert(allocator, "Alpha", valuePointer(1)));
    try std.testing.expectEqual(valuePointer(1), hash.find("aLPHA"));
    try std.testing.expectEqual(valuePointer(1), hash.insert(allocator, "ALPHA", valuePointer(2)));
    try std.testing.expectEqual(valuePointer(2), hash.find("alpha"));
    try std.testing.expectEqualStrings("ALPHA", std.mem.span(hash.first().?.key));
    try std.testing.expectEqual(valuePointer(2), hash.insert(allocator, "alpha", null));
    try std.testing.expectEqual(@as(c_uint, 0), hash.count());
    try std.testing.expectEqual(@as(c_uint, 0), hash.bucket_count);
}

test "linear list transitions to grouped buckets and preserves order" {
    const allocator = std.testing.allocator;
    var hash = Hash.init();
    defer hash.clear(allocator);

    try std.testing.expectEqual(null, hash.insert(allocator, "one", valuePointer(1)));
    try std.testing.expectEqual(null, hash.insert(allocator, "two", valuePointer(2)));
    try std.testing.expectEqual(null, hash.insert(allocator, "three", valuePointer(3)));
    try std.testing.expectEqual(null, hash.insert(allocator, "four", valuePointer(4)));
    try expectList(&hash, &.{ "four", "three", "two", "one" });
    try std.testing.expectEqual(@as(c_uint, 0), hash.bucket_count);

    try std.testing.expectEqual(null, hash.insert(allocator, "five", valuePointer(5)));
    try std.testing.expectEqual(@as(c_uint, 15), hash.bucket_count);
    for ([_][*:0]const u8{ "one", "two", "three", "four", "five" }) |key| {
        try std.testing.expect(hash.find(key) != null);
    }
}

test "bucket growth is capped by the SQLite malloc soft limit" {
    const allocator = std.testing.allocator;
    var hash = Hash.init();
    defer hash.clear(allocator);
    var keys: [140][16:0]u8 = undefined;

    for (&keys, 0..) |*key, index| {
        _ = std.fmt.bufPrintZ(key, "key-{d}", .{index}) catch unreachable;
        try std.testing.expectEqual(null, hash.insert(allocator, key, valuePointer(index + 1)));
    }
    try std.testing.expectEqual(@as(c_uint, keys.len), hash.count());
    try std.testing.expectEqual(@as(c_uint, 64), hash.bucket_count);
    for (&keys, 0..) |*key, index| {
        try std.testing.expectEqual(valuePointer(index + 1), hash.find(key));
    }
}

test "element allocation failure returns new data without mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var hash = Hash.init();
    defer hash.clear(failing.allocator());
    try std.testing.expectEqual(valuePointer(7), hash.insert(failing.allocator(), "key", valuePointer(7)));
    try std.testing.expectEqual(@as(c_uint, 0), hash.count());
    try std.testing.expect(failing.has_induced_failure);
}

test "rehash allocation failure is benign and leak free" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 5 });
    var hash = Hash.init();
    defer hash.clear(failing.allocator());
    for ([_][*:0]const u8{ "a", "b", "c", "d", "e" }, 1..) |key, value| {
        try std.testing.expectEqual(null, hash.insert(failing.allocator(), key, valuePointer(value)));
    }
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(c_uint, 5), hash.count());
    try std.testing.expectEqual(@as(c_uint, 0), hash.bucket_count);
    for ([_][*:0]const u8{ "a", "b", "c", "d", "e" }) |key| {
        try std.testing.expect(hash.find(key) != null);
    }
}

test "all deterministic sticky program allocation failures are leak free" {
    const keys = [_][*:0]const u8{
        "zero",    "one",       "two",      "three",    "four",   "five",     "six",      "seven",
        "eight",   "nine",      "ten",      "eleven",   "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    };
    var observed_complete_run = false;
    for (0..keys.len + 8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var hash = Hash.init();
        for (keys, 1..) |key, value| {
            _ = hash.insert(failing.allocator(), key, valuePointer(value));
        }
        if (!failing.has_induced_failure) observed_complete_run = true;
        hash.clear(failing.allocator());
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (observed_complete_run) break;
    }
    try std.testing.expect(observed_complete_run);
}

test "all deterministic one-shot program allocation failures are leak free" {
    const keys = [_][*:0]const u8{
        "zero",    "one",       "two",      "three",    "four",   "five",     "six",      "seven",
        "eight",   "nine",      "ten",      "eleven",   "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    };
    var observed_complete_run = false;
    for (0..keys.len + 8) |fail_index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, fail_index);
        var hash = Hash.init();
        for (keys, 1..) |key, value| {
            _ = hash.insert(failing.allocator(), key, valuePointer(value));
        }
        if (!failing.induced_failure) observed_complete_run = true;
        hash.clear(failing.allocator());
        if (observed_complete_run) break;
    }
    try std.testing.expect(observed_complete_run);
}
