//! SQLite variable-length integer codec translated from `src/util.c`.
//!
//! The decoder accepts non-canonical encodings exactly as SQLite does: it
//! stops at the first byte with a clear high bit among bytes 0 through 7,
//! while byte 8 always contributes eight payload bits. No allocation occurs.

const std = @import("std");

/// Upstream: putVarint64 (line 1579).
fn put64(output: [*]u8, input: u64) u8 {
    var value = input;
    if ((value & 0xff00_0000_0000_0000) != 0) {
        output[8] = @truncate(value);
        value >>= 8;
        var index: usize = 8;
        while (index != 0) {
            index -= 1;
            output[index] = @as(u8, @truncate(value & 0x7f)) | 0x80;
            value >>= 7;
        }
        return 9;
    }

    var buffer: [10]u8 = undefined;
    var count: usize = 0;
    while (true) {
        buffer[count] = @as(u8, @truncate(value & 0x7f)) | 0x80;
        count += 1;
        value >>= 7;
        if (value == 0) break;
    }
    buffer[0] &= 0x7f;
    for (0..count) |index| {
        output[index] = buffer[count - index - 1];
    }
    return @intCast(count);
}

/// Upstream: sqlite3PutVarint (line 1603).
pub fn put(output: [*]u8, value: u64) u8 {
    if (value <= 0x7f) {
        output[0] = @truncate(value & 0x7f);
        return 1;
    }
    if (value <= 0x3fff) {
        output[0] = @as(u8, @truncate((value >> 7) & 0x7f)) | 0x80;
        output[1] = @truncate(value & 0x7f);
        return 2;
    }
    return put64(output, value);
}

pub const Decoded64 = struct {
    value: u64,
    length: u8,
};

/// Upstream: sqlite3GetVarint (line 1633).
///
/// This uses the algebraically equivalent byte-wise form of SQLite's
/// precomputed-mask implementation and retains the same read/stop order.
pub fn get(input: [*]const u8) Decoded64 {
    var value: u64 = 0;
    for (0..8) |index| {
        const byte = input[index];
        value = (value << 7) | (byte & 0x7f);
        if ((byte & 0x80) == 0) {
            return .{ .value = value, .length = @intCast(index + 1) };
        }
    }
    value = (value << 8) | input[8];
    return .{ .value = value, .length = 9 };
}

pub const Decoded32 = struct {
    value: u32,
    length: u8,
};

/// Upstream: sqlite3GetVarint32 (line 1794). The caller has handled the
/// one-byte macro fast path and `input[0]` has its high bit set.
fn get32Long(input: [*]const u8) Decoded32 {
    std.debug.assert((input[0] & 0x80) != 0);
    if ((input[1] & 0x80) == 0) {
        return .{
            .value = (@as(u32, input[0] & 0x7f) << 7) | input[1],
            .length = 2,
        };
    }
    if ((input[2] & 0x80) == 0) {
        return .{
            .value = (@as(u32, input[0] & 0x7f) << 14) |
                (@as(u32, input[1] & 0x7f) << 7) | input[2],
            .length = 3,
        };
    }
    const decoded = get(input);
    return .{
        .value = if (decoded.value > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(decoded.value),
        .length = decoded.length,
    };
}

/// Macro-equivalent `getVarint32`, including the one-byte fast path.
pub fn get32(input: [*]const u8) Decoded32 {
    if (input[0] < 0x80) return .{ .value = input[0], .length = 1 };
    return get32Long(input);
}

/// Macro-equivalent `getVarint32NR`.
pub fn get32NoResultLength(input: [*]const u8) u32 {
    if (input[0] < 0x80) return input[0];
    return get32Long(input).value;
}

/// Macro-equivalent `putVarint32`.
pub fn put32(output: [*]u8, value: u32) u8 {
    if (value < 0x80) {
        output[0] = @truncate(value);
        return 1;
    }
    return put(output, value);
}

/// Upstream: sqlite3VarintLen (line 1827).
pub fn length(value_input: u64) u8 {
    var value = value_input;
    var result: u8 = 1;
    while (true) {
        value >>= 7;
        if (value == 0) return result;
        result += 1;
    }
}

fn expectRoundTrip(value: u64, expected_length: u8) !void {
    var encoded: [9]u8 = undefined;
    const encoded_length = put(&encoded, value);
    try std.testing.expectEqual(expected_length, encoded_length);
    const decoded = get(&encoded);
    try std.testing.expectEqual(value, decoded.value);
    try std.testing.expectEqual(encoded_length, decoded.length);
}

test "encoding boundaries and full u64 round trips" {
    const cases = [_]struct { u64, u8 }{
        .{ 0, 1 },
        .{ 0x7f, 1 },
        .{ 0x80, 2 },
        .{ 0x3fff, 2 },
        .{ 0x4000, 3 },
        .{ 0x1f_ffff, 3 },
        .{ 0x20_0000, 4 },
        .{ 0x00ff_ffff_ffff_ffff, 8 },
        .{ 0x0100_0000_0000_0000, 9 },
        .{ std.math.maxInt(u64), 9 },
    };
    for (cases) |case| try expectRoundTrip(case[0], case[1]);
}

test "known SQLite encodings" {
    var encoded: [9]u8 = undefined;
    var count = put(&encoded, 0x80);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, encoded[0..count]);
    count = put(&encoded, 0x4000);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x80, 0x00 }, encoded[0..count]);
    count = put(&encoded, std.math.maxInt(u64));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, encoded[0..count]);
}

test "32-bit decoder saturates and macro fast paths match" {
    var encoded: [9]u8 = undefined;
    var count = put32(&encoded, 127);
    try std.testing.expectEqual(@as(u8, 1), count);
    try std.testing.expectEqual(Decoded32{ .value = 127, .length = 1 }, get32(&encoded));
    try std.testing.expectEqual(@as(u32, 127), get32NoResultLength(&encoded));

    count = put32(&encoded, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u8, 5), count);
    try std.testing.expectEqual(Decoded32{ .value = std.math.maxInt(u32), .length = 5 }, get32(&encoded));

    _ = put(&encoded, @as(u64, std.math.maxInt(u32)) + 1);
    try std.testing.expectEqual(Decoded32{ .value = std.math.maxInt(u32), .length = 5 }, get32(&encoded));
}

test "noncanonical and truncated-at-terminator encodings" {
    const two_zero = [_]u8{ 0x80, 0x00 } ++ [_]u8{0} ** 7;
    try std.testing.expectEqual(Decoded64{ .value = 0, .length = 2 }, get(&two_zero));
    try std.testing.expectEqual(Decoded32{ .value = 0, .length = 2 }, get32(&two_zero));

    const early = [_]u8{ 0x81, 0x82, 0x03 } ++ [_]u8{0xaa} ** 6;
    try std.testing.expectEqual(Decoded64{ .value = 16_643, .length = 3 }, get(&early));
}

test "varint length preserves upstream shift-by-seven behavior" {
    try std.testing.expectEqual(@as(u8, 1), length(0));
    try std.testing.expectEqual(@as(u8, 1), length(127));
    try std.testing.expectEqual(@as(u8, 2), length(128));
    try std.testing.expectEqual(@as(u8, 9), length(std.math.maxInt(i63)));
    try std.testing.expectEqual(@as(u8, 10), length(std.math.maxInt(u64)));
}
