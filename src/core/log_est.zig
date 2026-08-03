//! SQLite LogEst arithmetic (`10*log2(x)` in a compact signed integer).

const std = @import("std");

pub const LogEst = i16;

pub fn add(a: LogEst, b: LogEst) LogEst {
    const adjustment = [_]u8{
        10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 6, 5, 5, 5, 4,
        4,  4,  4, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2,
    };
    if (a >= b) {
        if (a > b + 49) return a;
        if (a > b + 31) return a + 1;
        return a + adjustment[@intCast(a - b)];
    }
    if (b > a + 49) return b;
    if (b > a + 31) return b + 1;
    return b + adjustment[@intCast(b - a)];
}

pub fn fromInt(input: u64) LogEst {
    const adjustment = [_]LogEst{ 0, 2, 3, 5, 6, 7, 8, 9 };
    var value = input;
    var result: LogEst = 40;
    if (value < 8) {
        if (value < 2) return 0;
        while (value < 8) {
            result -= 10;
            value <<= 1;
        }
    } else {
        while (value > 255) {
            result += 40;
            value >>= 4;
        }
        while (value > 15) {
            result += 10;
            value >>= 1;
        }
    }
    return adjustment[value & 7] + result - 10;
}

pub fn fromDouble(value: f64) LogEst {
    if (value <= 1) return 0;
    if (value <= 2_000_000_000) return fromInt(@intFromFloat(value));
    const bits: u64 = @bitCast(value);
    const exponent: i64 = @as(i64, @intCast(bits >> 52)) - 1022;
    return @intCast(exponent * 10);
}

pub fn toInt(input: LogEst) u64 {
    var value = input;
    var fraction: u64 = @intCast(@mod(value, 10));
    value = @divTrunc(value, 10);
    if (fraction >= 5) fraction -= 2 else if (fraction >= 1) fraction -= 1;
    if (value > 60) return std.math.maxInt(i64);
    return if (value >= 3)
        (fraction + 8) << @intCast(value - 3)
    else
        (fraction + 8) >> @intCast(3 - value);
}

test "integer double addition and inverse boundaries" {
    try std.testing.expectEqual(@as(LogEst, 0), fromInt(0));
    try std.testing.expectEqual(@as(LogEst, 10), fromInt(2));
    try std.testing.expectEqual(@as(LogEst, 100), fromInt(1024));
    try std.testing.expectEqual(@as(LogEst, 110), add(100, 100));
    try std.testing.expectEqual(@as(LogEst, 100), add(100, 40));
    try std.testing.expectEqual(fromInt(2_000_000_000), fromDouble(2_000_000_000));
    try std.testing.expectEqual(@as(u64, 1024), toInt(100));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), toInt(610));
}
