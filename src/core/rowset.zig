//! SQLite rowid set translated from `src/rowset.c`.
//!
//! Inserts are accumulated in allocation chunks. `next()` sorts and extracts
//! unique values, while `test()` freezes each changed batch into a forest of
//! balanced search trees. As upstream requires, extraction and batch testing
//! are mutually exclusive modes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const allocation_size: usize = 1024;

const Entry = struct {
    value: i64 = 0,
    right: ?*Entry = null,
    left: ?*Entry = null,
};

pub const entries_per_chunk: usize = (allocation_size - 8) / @sizeOf(Entry);

const Chunk = struct {
    next: ?*Chunk = null,
    entries: [entries_per_chunk]Entry = undefined,
};

const sorted_flag: u16 = 0x01;
const next_flag: u16 = 0x02;

/// Upstream: `RowSet` and sqlite3RowSetInit().
pub const RowSet = struct {
    allocator: Allocator,
    chunks: ?*Chunk = null,
    entry: ?*Entry = null,
    last: ?*Entry = null,
    fresh: ?[*]Entry = null,
    forest: ?*Entry = null,
    fresh_count: u16 = 0,
    flags: u16 = sorted_flag,
    batch: i32 = 0,

    pub fn init(allocator: Allocator) RowSet {
        return .{ .allocator = allocator };
    }

    pub fn create(allocator: Allocator) Allocator.Error!*RowSet {
        const result = try allocator.create(RowSet);
        result.* = init(allocator);
        return result;
    }

    /// Upstream: sqlite3RowSetClear().
    pub fn clear(self: *RowSet) void {
        var chunk = self.chunks;
        while (chunk) |current| {
            chunk = current.next;
            self.allocator.destroy(current);
        }
        self.chunks = null;
        self.fresh_count = 0;
        self.fresh = null;
        self.entry = null;
        self.last = null;
        self.forest = null;
        self.flags = sorted_flag;
    }

    /// Zig-owned equivalent of sqlite3RowSetDelete().
    pub fn deinit(self: *RowSet) void {
        self.clear();
    }

    pub fn destroy(self: *RowSet) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deleteOpaque(pointer: ?*anyopaque) callconv(.c) void {
        const self: *RowSet = @ptrCast(@alignCast(pointer orelse return));
        self.destroy();
    }

    fn allocateEntry(self: *RowSet) Allocator.Error!*Entry {
        if (self.fresh_count == 0) {
            const chunk = try self.allocator.create(Chunk);
            chunk.next = self.chunks;
            self.chunks = chunk;
            self.fresh = &chunk.entries;
            self.fresh_count = entries_per_chunk;
        }
        self.fresh_count -= 1;
        const result = &self.fresh.?[0];
        self.fresh.? += 1;
        return result;
    }

    /// Upstream: sqlite3RowSetInsert().
    pub fn insert(self: *RowSet, rowid: i64) Allocator.Error!void {
        std.debug.assert((self.flags & next_flag) == 0);
        const new_entry = try self.allocateEntry();
        new_entry.* = .{ .value = rowid };
        if (self.last) |prior| {
            if (rowid <= prior.value) self.flags &= ~sorted_flag;
            prior.right = new_entry;
        } else {
            self.entry = new_entry;
        }
        self.last = new_entry;
    }

    /// Upstream: sqlite3RowSetNext(). Returns the next unique rowid.
    pub fn next(self: *RowSet) ?i64 {
        std.debug.assert(self.forest == null);
        if ((self.flags & next_flag) == 0) {
            if ((self.flags & sorted_flag) == 0) self.entry = sortEntries(self.entry);
            self.flags |= sorted_flag | next_flag;
        }

        const current = self.entry orelse return null;
        const result = current.value;
        self.entry = current.right;
        if (self.entry == null) self.clear();
        return result;
    }

    /// Upstream: sqlite3RowSetTest(). Only entries frozen by a batch-number
    /// change are visible. Inserts made within the current batch remain hidden.
    pub fn testValue(self: *RowSet, batch: i32, rowid: i64) Allocator.Error!bool {
        std.debug.assert((self.flags & next_flag) == 0);

        if (batch != self.batch) {
            if (self.entry) |unsorted| {
                var list: ?*Entry = unsorted;
                if ((self.flags & sorted_flag) == 0) list = sortEntries(list);

                var previous_tree_link = &self.forest;
                var tree = self.forest;
                while (tree) |current_tree| : (tree = current_tree.right) {
                    previous_tree_link = &current_tree.right;
                    if (current_tree.left == null) {
                        current_tree.left = listToTree(list.?);
                        break;
                    }

                    var first: ?*Entry = null;
                    var tail: ?*Entry = null;
                    treeToList(current_tree.left.?, &first, &tail);
                    current_tree.left = null;
                    list = mergeEntries(first.?, list.?);
                }

                if (tree == null) {
                    const forest_entry = try self.allocateEntry();
                    forest_entry.* = .{ .left = listToTree(list.?) };
                    previous_tree_link.* = forest_entry;
                }
                self.entry = null;
                self.last = null;
                self.flags |= sorted_flag;
            }
            self.batch = batch;
        }

        var tree = self.forest;
        while (tree) |current_tree| : (tree = current_tree.right) {
            var node = current_tree.left;
            while (node) |current| {
                if (current.value < rowid) {
                    node = current.right;
                } else if (current.value > rowid) {
                    node = current.left;
                } else {
                    return true;
                }
            }
        }
        return false;
    }

    /// Test-only structural observations.
    pub fn chunkCount(self: *const RowSet) usize {
        var count: usize = 0;
        var chunk = self.chunks;
        while (chunk) |current| : (chunk = current.next) count += 1;
        return count;
    }
};

/// Upstream: rowSetEntryMerge(). Inputs are sorted; duplicates are removed.
fn mergeEntries(first_input: *Entry, second_input: *Entry) *Entry {
    var first: ?*Entry = first_input;
    var second: ?*Entry = second_input;
    var head = Entry{};
    var tail = &head;

    while (true) {
        const a = first.?;
        const b = second.?;
        if (a.value <= b.value) {
            if (a.value < b.value) {
                tail.right = a;
                tail = a;
            }
            first = a.right;
            if (first == null) {
                tail.right = second;
                break;
            }
        } else {
            tail.right = b;
            tail = b;
            second = b.right;
            if (second == null) {
                tail.right = first;
                break;
            }
        }
    }
    return head.right.?;
}

/// Upstream: rowSetEntrySort(). Bottom-up merge sort with 40 buckets.
fn sortEntries(input: ?*Entry) ?*Entry {
    var buckets = [_]?*Entry{null} ** 40;
    var remaining = input;
    while (remaining) |entry| {
        const following = entry.right;
        entry.right = null;
        var merged = entry;
        var index: usize = 0;
        while (buckets[index]) |bucket| : (index += 1) {
            merged = mergeEntries(bucket, merged);
            buckets[index] = null;
        }
        buckets[index] = merged;
        remaining = following;
    }

    var result = buckets[0];
    for (buckets[1..]) |bucket| {
        const present = bucket orelse continue;
        result = if (result) |prior| mergeEntries(prior, present) else present;
    }
    return result;
}

/// Upstream: rowSetTreeToList().
fn treeToList(input: *Entry, first: *?*Entry, last: *?*Entry) void {
    if (input.left) |left| {
        var prior: ?*Entry = null;
        treeToList(left, first, &prior);
        prior.?.right = input;
    } else {
        first.* = input;
    }
    if (input.right) |right| {
        treeToList(right, &input.right, last);
    } else {
        last.* = input;
    }
}

/// Upstream: rowSetNDeepTree().
fn nDeepTree(list: *?*Entry, depth: i32) ?*Entry {
    if (list.* == null) return null;
    if (depth > 1) {
        const left = nDeepTree(list, depth - 1);
        const root = list.* orelse return left;
        root.left = left;
        list.* = root.right;
        root.right = nDeepTree(list, depth - 1);
        return root;
    }
    const root = list.*.?;
    list.* = root.right;
    root.left = null;
    root.right = null;
    return root;
}

/// Upstream: rowSetListToTree().
fn listToTree(input: *Entry) *Entry {
    var root = input;
    var list = root.right;
    root.left = null;
    root.right = null;
    var depth: i32 = 1;
    while (list) |next_root| : (depth += 1) {
        const left = root;
        root = next_root;
        list = root.right;
        root.left = left;
        root.right = nDeepTree(&list, depth);
    }
    return root;
}

comptime {
    std.debug.assert(entries_per_chunk > 0);
    std.debug.assert(entries_per_chunk <= std.math.maxInt(u16));
}

test "next returns sorted unique rowids and clears storage" {
    var set = RowSet.init(std.testing.allocator);
    defer set.deinit();
    for ([_]i64{ 9, -3, 9, 2, 1, -3, 20, 2 }) |value| try set.insert(value);
    try std.testing.expectEqual(@as(?i64, -3), set.next());
    try std.testing.expectEqual(@as(?i64, 1), set.next());
    try std.testing.expectEqual(@as(?i64, 2), set.next());
    try std.testing.expectEqual(@as(?i64, 9), set.next());
    try std.testing.expectEqual(@as(?i64, 20), set.next());
    try std.testing.expectEqual(@as(?i64, null), set.next());
    try std.testing.expectEqual(@as(usize, 0), set.chunkCount());
}

test "batch changes freeze inserts and same-batch inserts stay hidden" {
    var set = RowSet.init(std.testing.allocator);
    defer set.deinit();
    try set.insert(10);
    try set.insert(20);

    try std.testing.expect(!(try set.testValue(0, 10)));
    try std.testing.expect(try set.testValue(1, 10));
    try std.testing.expect(!(try set.testValue(1, 30)));

    try set.insert(30);
    try std.testing.expect(!(try set.testValue(1, 30)));
    try std.testing.expect(try set.testValue(2, 30));
    try std.testing.expect(try set.testValue(2, 10));

    try set.insert(40);
    try set.insert(20);
    try std.testing.expect(!(try set.testValue(2, 40)));
    try std.testing.expect(try set.testValue(3, 40));
    try std.testing.expect(try set.testValue(3, 20));
    try std.testing.expect(!(try set.testValue(3, 99)));
}

test "chunk growth clear reuse and allocation failures" {
    var set = RowSet.init(std.testing.allocator);
    defer set.deinit();
    for (0..entries_per_chunk + 1) |index| try set.insert(@intCast(index));
    try std.testing.expectEqual(@as(usize, 2), set.chunkCount());
    set.clear();
    try std.testing.expectEqual(@as(usize, 0), set.chunkCount());
    try set.insert(7);
    try std.testing.expectEqual(@as(?i64, 7), set.next());

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var failing = RowSet.init(allocator);
            defer failing.deinit();
            for (0..entries_per_chunk * 3) |index| {
                try failing.insert(@intCast(index));
            }
            _ = try failing.testValue(1, 7);
        }
    }.run, .{});
}
