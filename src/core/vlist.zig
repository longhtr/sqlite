//! SQLite variable-name/number list with source-corresponding packed storage.

const std = @import("std");

pub const VList = struct {
    allocator: std.mem.Allocator,
    words: []align(@alignOf(i32)) i32 = &.{},

    pub fn init(allocator: std.mem.Allocator) VList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VList) void {
        if (self.words.len != 0) self.allocator.free(self.words);
        self.words = &.{};
    }

    /// Upstream: sqlite3VListAdd(). OOM leaves the original list unchanged.
    pub fn add(self: *VList, name: []const u8, value: i32) std.mem.Allocator.Error!void {
        const slots: usize = name.len / 4 + 3;
        const used: usize = if (self.words.len == 0) 2 else @intCast(self.words[1]);
        if (self.words.len == 0 or used + slots > self.words.len) {
            const allocation_count = (if (self.words.len == 0) @as(usize, 10) else 2 * self.words.len) + slots;
            if (self.words.len == 0) {
                const replacement = try self.allocator.alloc(i32, allocation_count);
                replacement[1] = 2;
                self.words = replacement;
            } else {
                self.words = try self.allocator.realloc(self.words, allocation_count);
            }
            self.words[0] = @intCast(allocation_count);
        }
        const index: usize = @intCast(self.words[1]);
        self.words[index] = value;
        self.words[index + 1] = @intCast(slots);
        const destination = std.mem.sliceAsBytes(self.words[index + 2 .. index + slots]);
        @memcpy(destination[0..name.len], name);
        destination[name.len] = 0;
        self.words[1] = @intCast(index + slots);
    }

    /// Upstream: sqlite3VListNumToName(). The result borrows list storage.
    pub fn numberToName(self: *const VList, value: i32) ?[*:0]const u8 {
        if (self.words.len == 0) return null;
        var index: usize = 2;
        const used: usize = @intCast(self.words[1]);
        while (index < used) : (index += @intCast(self.words[index + 1])) {
            if (self.words[index] == value) return @ptrCast(std.mem.sliceAsBytes(self.words[index + 2 ..]).ptr);
        }
        return null;
    }

    /// Upstream: sqlite3VListNameToNum().
    pub fn nameToNumber(self: *const VList, name: []const u8) i32 {
        if (self.words.len == 0) return 0;
        var index: usize = 2;
        const used: usize = @intCast(self.words[1]);
        while (index < used) : (index += @intCast(self.words[index + 1])) {
            const stored: [*:0]const u8 = @ptrCast(std.mem.sliceAsBytes(self.words[index + 2 ..]).ptr);
            if (std.mem.eql(u8, std.mem.span(stored), name)) return self.words[index];
        }
        return 0;
    }

    pub fn allocatedSlots(self: *const VList) usize {
        return self.words.len;
    }

    pub fn usedSlots(self: *const VList) usize {
        return if (self.words.len == 0) 0 else @intCast(self.words[1]);
    }
};

test "packed growth lookups replacement names and OOM ownership" {
    var list = VList.init(std.testing.allocator);
    defer list.deinit();
    try list.add("?one", 1);
    try list.add(":long-variable", 7);
    try std.testing.expectEqual(@as(i32, 1), list.nameToNumber("?one"));
    try std.testing.expectEqual(@as(i32, 7), list.nameToNumber(":long-variable"));
    try std.testing.expectEqualStrings("?one", std.mem.span(list.numberToName(1).?));
    try std.testing.expectEqual(@as(i32, 0), list.nameToNumber("missing"));
    try std.testing.expect(list.numberToName(99) == null);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var value = VList.init(allocator);
            defer value.deinit();
            try value.add("first", 1);
            try value.add("a-name-long-enough-to-grow", 2);
        }
    }.run, .{});
}
