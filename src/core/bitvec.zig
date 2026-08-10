//! Fixed-size sparse/dense bitmap translated from SQLite `src/bitvec.c`.
//!
//! Fidelity constraints:
//! - bit indexes are one-based;
//! - the object and representation thresholds match the target C ABI;
//! - sparse hash insertion order and hash-to-subtree transition are preserved;
//! - rehash allocation failure may leave a partial subtree, as in upstream;
//! - callers retain ownership and must destroy the object after any set error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
pub const sqlite_random = @import("random.zig");

pub const structure_size: usize = 512;
const header_size = 3 * @sizeOf(u32);
const pointer_size = @sizeOf(*BitVec);
pub const payload_size: usize = ((structure_size - header_size) / pointer_size) * pointer_size;
pub const BitmapElement = u8;
pub const bitmap_element_bits: usize = 8;
pub const bitmap_elements: usize = payload_size / @sizeOf(u8);
pub const bitmap_bits: u32 = bitmap_elements * bitmap_element_bits;
pub const hash_slots: usize = payload_size / @sizeOf(u32);
const hash_slots_u32: u32 = @intCast(hash_slots);
pub const max_hash_entries: u32 = hash_slots / 2;
pub const subtree_slots: usize = payload_size / pointer_size;
const subtree_slots_u32: u32 = @intCast(subtree_slots);

const Payload = extern union {
    bitmap: [bitmap_elements]BitmapElement,
    hash_values: [hash_slots]u32,
    subtrees: [subtree_slots]?*BitVec,
};

/// Upstream: src/bitvec.c :: Bitvec (line 94)
/// Baseline: bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc
pub const BitVec = extern struct {
    size: u32,
    set_count: u32,
    divisor: u32,
    payload: Payload,

    /// Upstream: sqlite3BitvecCreate (line 116)
    pub fn create(allocator: Allocator, size: u32) Allocator.Error!*BitVec {
        const result = try allocator.create(BitVec);
        result.* = std.mem.zeroes(BitVec);
        result.size = size;
        return result;
    }

    /// Upstream: sqlite3BitvecTestNotNull (line 131)
    pub fn isSet(self: *const BitVec, index: u32) bool {
        var bit_index = index -% 1;
        if (bit_index >= self.size) return false;

        var current = self;
        while (current.divisor != 0) {
            const bin = bit_index / current.divisor;
            bit_index %= current.divisor;
            current = current.payload.subtrees[bin] orelse return false;
        }

        if (current.size <= bitmap_bits) {
            const element = bit_index / bitmap_element_bits;
            const shift: u3 = @intCast(bit_index & (bitmap_element_bits - 1));
            return (current.payload.bitmap[element] & (@as(u8, 1) << shift)) != 0;
        }

        const stored_index = bit_index + 1;
        var slot = hash(bit_index);
        while (current.payload.hash_values[slot] != 0) {
            if (current.payload.hash_values[slot] == stored_index) return true;
            slot = (slot + 1) % hash_slots;
        }
        return false;
    }

    /// Nullable equivalent of upstream `sqlite3BitvecTest` (line 154).
    pub fn testOptional(optional: ?*const BitVec, index: u32) bool {
        const self = optional orelse return false;
        return self.isSet(index);
    }

    /// Upstream: sqlite3BitvecSet (line 170)
    pub fn set(self: *BitVec, allocator: Allocator, index: u32) Allocator.Error!void {
        std.debug.assert(index > 0);
        std.debug.assert(index <= self.size);
        return setInternal(self, allocator, index);
    }

    /// Nullable equivalent preserving upstream's NULL-is-success behavior.
    pub fn setOptional(optional: ?*BitVec, allocator: Allocator, index: u32) Allocator.Error!void {
        const self = optional orelse return;
        return self.set(allocator, index);
    }

    /// Upstream: sqlite3BitvecClear (line 243).
    /// `scratch` is caller-owned and may be reused across calls.
    pub fn clearWithScratch(self: *BitVec, index: u32, scratch: *[hash_slots]u32) void {
        std.debug.assert(index > 0);
        std.debug.assert(index <= self.size);

        var bit_index = index - 1;
        var current = self;
        while (current.divisor != 0) {
            const bin = bit_index / current.divisor;
            bit_index %= current.divisor;
            current = current.payload.subtrees[bin] orelse return;
        }

        if (current.size <= bitmap_bits) {
            const element = bit_index / bitmap_element_bits;
            const shift: u3 = @intCast(bit_index & (bitmap_element_bits - 1));
            current.payload.bitmap[element] &= ~(@as(u8, 1) << shift);
            return;
        }

        scratch.* = current.payload.hash_values;
        @memset(&current.payload.hash_values, 0);
        current.set_count = 0;
        for (scratch) |stored_index| {
            if (stored_index != 0 and stored_index != bit_index + 1) {
                var slot = hash(stored_index - 1);
                current.set_count += 1;
                while (current.payload.hash_values[slot] != 0) {
                    slot = (slot + 1) % hash_slots;
                }
                current.payload.hash_values[slot] = stored_index;
            }
        }
    }

    /// Convenience wrapper around `clearWithScratch`; performs no allocation.
    pub fn clear(self: *BitVec, index: u32) void {
        var scratch: [hash_slots]u32 = undefined;
        self.clearWithScratch(index, &scratch);
    }

    /// Upstream: sqlite3BitvecDestroy (line 280)
    pub fn destroy(self: *BitVec, allocator: Allocator) void {
        if (self.divisor != 0) {
            for (self.payload.subtrees) |subtree| {
                if (subtree) |child| child.destroy(allocator);
            }
        }
        allocator.destroy(self);
    }

    /// Upstream: sqlite3BitvecSize (line 295)
    pub fn capacity(self: *const BitVec) u32 {
        return self.size;
    }

    pub const Representation = enum { bitmap, hash, subtree };

    /// Test-only structural observation; not part of SQLite's interface.
    pub fn representation(self: *const BitVec) Representation {
        if (self.size <= bitmap_bits) return .bitmap;
        if (self.divisor == 0) return .hash;
        return .subtree;
    }
};

pub fn setLinear(bits: []u8, index: u32) void {
    bits[index >> 3] |= @as(u8, 1) << @intCast(index & 7);
}

pub fn clearLinear(bits: []u8, index: u32) void {
    bits[index >> 3] &= ~(@as(u8, 1) << @intCast(index & 7));
}

pub fn testLinear(bits: []const u8, index: u32) bool {
    return bits[index >> 3] & (@as(u8, 1) << @intCast(index & 7)) != 0;
}

fn hash(zero_based_index: u32) usize {
    return @intCast(zero_based_index % hash_slots);
}

fn setInternal(root: *BitVec, allocator: Allocator, one_based_index: u32) Allocator.Error!void {
    var bit_index = one_based_index - 1;
    var current = root;

    while (current.size > bitmap_bits and current.divisor != 0) {
        const bin = bit_index / current.divisor;
        bit_index %= current.divisor;
        if (current.payload.subtrees[bin] == null) {
            current.payload.subtrees[bin] = try BitVec.create(allocator, current.divisor);
        }
        current = current.payload.subtrees[bin].?;
    }

    if (current.size <= bitmap_bits) {
        const element = bit_index / bitmap_element_bits;
        const shift: u3 = @intCast(bit_index & (bitmap_element_bits - 1));
        current.payload.bitmap[element] |= @as(u8, 1) << shift;
        return;
    }

    const stored_index = bit_index + 1;
    var slot = hash(bit_index);
    if (current.payload.hash_values[slot] == 0) {
        if (current.set_count < hash_slots - 1) {
            current.set_count += 1;
            current.payload.hash_values[slot] = stored_index;
            return;
        }
    } else {
        while (current.payload.hash_values[slot] != 0) {
            if (current.payload.hash_values[slot] == stored_index) return;
            slot = (slot + 1) % hash_slots;
        }
        if (current.set_count < max_hash_entries) {
            current.set_count += 1;
            current.payload.hash_values[slot] = stored_index;
            return;
        }
    }

    const prior_values = try allocator.dupe(u32, &current.payload.hash_values);
    defer allocator.free(prior_values);

    @memset(&current.payload.subtrees, null);
    current.divisor = current.size / subtree_slots_u32;
    if (current.size % subtree_slots_u32 != 0) current.divisor += 1;
    if (current.divisor < bitmap_bits) current.divisor = bitmap_bits;

    var allocation_failed = false;
    setInternal(current, allocator, stored_index) catch {
        allocation_failed = true;
    };
    for (prior_values) |prior_index| {
        if (prior_index != 0) {
            setInternal(current, allocator, prior_index) catch {
                allocation_failed = true;
            };
        }
    }
    if (allocation_failed) return error.OutOfMemory;
}

comptime {
    std.debug.assert(payload_size <= structure_size - header_size);
    std.debug.assert(@sizeOf(BitVec) == structure_size);
    std.debug.assert(@sizeOf(Payload) == payload_size);
}

/// Upstream: sqlite3BitvecBuiltinTest(). The operation array is mutable by
/// design: repeat counts and sequential start values are updated in place.
pub fn builtinTest(
    allocator: Allocator,
    size_argument: i32,
    operations: []i32,
    random_state: *sqlite_random.State,
    entropy: *const [44]u8,
) i32 {
    const size: u32 = if (size_argument <= 0)
        2 *% @as(u32, @bitCast(-%size_argument))
    else
        @intCast(size_argument);
    const vector = BitVec.create(allocator, size) catch return -1;
    defer vector.destroy(allocator);
    const reference = if (size_argument > 0)
        allocator.alloc(u8, @intCast((7 + @as(u64, size)) / 8 + 1)) catch return -1
    else
        null;
    defer if (reference) |bytes| allocator.free(bytes);
    if (reference) |bytes| @memset(bytes, 0);
    var scratch: [hash_slots]u32 = undefined;

    // Preserve source NULL behavior probes.
    BitVec.setOptional(null, allocator, 1) catch return -1;

    var pc: usize = 0;
    while (pc < operations.len and operations[pc] != 0) {
        const operation = operations[pc];
        if (operation >= 6) {
            pc += 1;
            continue;
        }
        var index: i32 = undefined;
        var advance: usize = undefined;
        switch (operation) {
            1, 2, 5 => {
                if (pc + 3 >= operations.len) return -1;
                advance = 4;
                index = operations[pc + 2] -% 1;
                operations[pc + 2] +%= operations[pc + 3];
            },
            else => {
                if (pc + 1 >= operations.len) return -1;
                advance = 2;
                var bytes: [4]u8 = undefined;
                random_state.fill(&bytes, entropy);
                index = @bitCast(std.mem.readInt(u32, &bytes, .little));
            },
        }
        operations[pc + 1] -%= 1;
        if (operations[pc + 1] > 0) advance = 0;
        pc += advance;
        const normalized: u32 = (@as(u32, @bitCast(index)) & 0x7fff_ffff) % size;
        const one_based = normalized + 1;
        if (operation & 1 != 0) {
            if (reference) |bytes| setLinear(bytes, one_based);
            if (operation != 5) vector.set(allocator, one_based) catch return -1;
        } else {
            if (reference) |bytes| clearLinear(bytes, one_based);
            vector.clearWithScratch(one_based, &scratch);
        }
    }

    if (reference) |bytes| {
        var result: i64 = @intFromBool(BitVec.testOptional(null, 0));
        result += @intFromBool(vector.isSet(size +% 1));
        result += @intFromBool(vector.isSet(0));
        result += @as(i64, vector.capacity()) - size;
        if (result != 0) return @intCast(result);
        var index: u32 = 1;
        while (index <= size) : (index += 1) {
            if (testLinear(bytes, index) != vector.isSet(index)) return @intCast(index);
        }
    }
    return 0;
}

fn runSequentialProgram(allocator: Allocator, size: u32, program: []const u32) !void {
    const vector = try BitVec.create(allocator, size);
    defer vector.destroy(allocator);
    const reference = try allocator.alloc(bool, @as(usize, size) + 1);
    defer allocator.free(reference);
    @memset(reference, false);

    var pc: usize = 0;
    while (program[pc] != 0) {
        const operation = program[pc];
        const count = program[pc + 1];
        var index = program[pc + 2];
        const increment = program[pc + 3];
        for (0..count) |_| {
            const normalized = ((index - 1) % size) + 1;
            switch (operation) {
                1 => {
                    reference[normalized] = true;
                    try vector.set(allocator, normalized);
                },
                2 => {
                    reference[normalized] = false;
                    vector.clear(normalized);
                },
                else => return error.InvalidTestOperation,
            }
            index +%= increment;
        }
        pc += 4;
    }

    for (0..@as(usize, size) + 1) |index| {
        try std.testing.expectEqual(reference[index], vector.isSet(@intCast(index)));
    }
}

test "linear reference macros preserve indexed bit operations" {
    var bits = [_]u8{0} ** 4;
    setLinear(&bits, 1);
    setLinear(&bits, 17);
    try std.testing.expect(testLinear(&bits, 1));
    try std.testing.expect(testLinear(&bits, 17));
    clearLinear(&bits, 1);
    try std.testing.expect(!testLinear(&bits, 1));
    try std.testing.expect(testLinear(&bits, 17));
}

test "C layout and thresholds match the initial target" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(BitVec));
    try std.testing.expectEqual(@as(usize, 496), payload_size);
    try std.testing.expectEqual(@as(u32, 3968), bitmap_bits);
    try std.testing.expectEqual(@as(usize, 124), hash_slots);
    try std.testing.expectEqual(@as(u32, 62), max_hash_entries);
    try std.testing.expectEqual(@as(usize, 62), subtree_slots);
}

test "null and range tests preserve upstream behavior" {
    try std.testing.expect(!BitVec.testOptional(null, 0));
    const vector = try BitVec.create(std.testing.allocator, 400);
    defer vector.destroy(std.testing.allocator);
    try std.testing.expect(!vector.isSet(0));
    try std.testing.expect(!vector.isSet(401));
    try std.testing.expectEqual(@as(u32, 400), vector.capacity());
    try BitVec.setOptional(null, std.testing.allocator, 1);
}

test "bitmap set clear and duplicate set" {
    const allocator = std.testing.allocator;
    const vector = try BitVec.create(allocator, bitmap_bits);
    defer vector.destroy(allocator);
    try std.testing.expectEqual(BitVec.Representation.bitmap, vector.representation());
    for ([_]u32{ 1, 2, 8, 9, bitmap_bits }) |index| {
        try vector.set(allocator, index);
        try vector.set(allocator, index);
        try std.testing.expect(vector.isSet(index));
    }
    vector.clear(8);
    try std.testing.expect(!vector.isSet(8));
    try std.testing.expect(vector.isSet(9));
}

test "hash clear rebuilds probe chains without allocation" {
    const allocator = std.testing.allocator;
    const vector = try BitVec.create(allocator, bitmap_bits + 1);
    defer vector.destroy(allocator);
    for ([_]u32{ 1, 125, 249, 2, 126 }) |index| try vector.set(allocator, index);
    vector.clear(125);
    try std.testing.expect(!vector.isSet(125));
    for ([_]u32{ 1, 249, 2, 126 }) |index| try std.testing.expect(vector.isSet(index));
    try std.testing.expectEqual(BitVec.Representation.hash, vector.representation());
}

test "hash collision triggers recursive representation" {
    const allocator = std.testing.allocator;
    const size: u32 = 100_000;
    const vector = try BitVec.create(allocator, size);
    defer vector.destroy(allocator);
    try std.testing.expectEqual(BitVec.Representation.hash, vector.representation());

    for (0..max_hash_entries + 1) |ordinal| {
        const index: u32 = 1 + @as(u32, @intCast(ordinal)) * hash_slots_u32;
        try vector.set(allocator, index);
    }
    try std.testing.expectEqual(BitVec.Representation.subtree, vector.representation());
    for (0..max_hash_entries + 1) |ordinal| {
        const index: u32 = 1 + @as(u32, @intCast(ordinal)) * hash_slots_u32;
        try std.testing.expect(vector.isSet(index));
    }
}

test "built-in mutable operation interpreter covers sequential random fault and negative modes" {
    var entropy: [44]u8 = undefined;
    for (&entropy, 0..) |*byte, index| {
        byte.* = @intCast(index);
    }
    var random_state = sqlite_random.State{};
    var sequential = [_]i32{ 1, 5, 1, 2, 2, 2, 1, 4, 0 };
    try std.testing.expectEqual(@as(i32, 0), builtinTest(std.testing.allocator, 100, &sequential, &random_state, &entropy));
    var fault = [_]i32{ 5, 1, 7, 1, 0 };
    try std.testing.expectEqual(@as(i32, 7), builtinTest(std.testing.allocator, 100, &fault, &random_state, &entropy));
    var random_program = [_]i32{ 3, 20, 4, 7, 0 };
    try std.testing.expectEqual(@as(i32, 0), builtinTest(std.testing.allocator, 1000, &random_program, &random_state, &entropy));
    var negative = [_]i32{ 1, 4, 1, 3, 0 };
    try std.testing.expectEqual(@as(i32, 0), builtinTest(std.testing.allocator, -100, &negative, &random_state, &entropy));
}

test "upstream sequential set and clear programs" {
    const allocator = std.testing.allocator;
    try runSequentialProgram(allocator, 400, &.{ 1, 400, 1, 1, 0 });
    try runSequentialProgram(allocator, 4_000, &.{ 1, 4_000, 1, 7, 0 });
    try runSequentialProgram(allocator, 40_000, &.{ 1, 40_000, 1, 1, 2, 40_000, 1, 77, 0 });
    try runSequentialProgram(allocator, 400_000, &.{ 1, 5_000, 100_000, 1, 2, 400_000, 1, 37, 0 });
}

fn allocationFailureExercise(allocator: Allocator) !void {
    const vector = try BitVec.create(allocator, 50_000);
    defer vector.destroy(allocator);
    for (0..max_hash_entries + 1) |ordinal| {
        const index: u32 = 1 + @as(u32, @intCast(ordinal)) * hash_slots_u32;
        try vector.set(allocator, index);
    }
}

test "all deterministic sticky allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureExercise,
        .{},
    );
}

test "all deterministic one-shot allocation failures are leak-free" {
    var completed = false;
    for (0..max_hash_entries + 16) |fail_index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, fail_index);
        allocationFailureExercise(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}
