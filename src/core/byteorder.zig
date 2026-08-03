//! Four-byte big-endian integer helpers translated from SQLite `src/util.c`.

const std = @import("std");

/// Upstream: sqlite3Get4byte (line 1837).
pub fn readU32(input: *const [4]u8) u32 {
    return @as(u32, input[0]) << 24 |
        @as(u32, input[1]) << 16 |
        @as(u32, input[2]) << 8 |
        input[3];
}

/// Upstream: sqlite3Put4byte (line 1855).
pub fn writeU32(output: *[4]u8, value: u32) void {
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

test "known big-endian values" {
    const cases = [_]struct { u32, [4]u8 }{
        .{ 0, .{ 0, 0, 0, 0 } },
        .{ 1, .{ 0, 0, 0, 1 } },
        .{ 0x0102_0304, .{ 1, 2, 3, 4 } },
        .{ 0x8000_0000, .{ 0x80, 0, 0, 0 } },
        .{ std.math.maxInt(u32), .{ 0xff, 0xff, 0xff, 0xff } },
    };
    for (cases) |case| {
        var bytes: [4]u8 = undefined;
        writeU32(&bytes, case[0]);
        try std.testing.expectEqual(case[1], bytes);
        try std.testing.expectEqual(case[0], readU32(&bytes));
    }
}

test "unaligned source bytes have no native-endian dependency" {
    const bytes = [_]u8{ 0xaa, 0xde, 0xad, 0xbe, 0xef, 0xbb };
    const input: *const [4]u8 = @ptrCast(&bytes[1]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), readU32(input));
}
