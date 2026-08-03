//! Source-corresponding SQLite finite checks and checked integer arithmetic.

const std = @import("std");

pub fn isNan(value: f64) bool {
    return std.math.isNan(value);
}

pub fn isOverflow(value: f64) bool {
    const bits: u64 = @bitCast(value);
    return bits & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000;
}

pub fn add(value: *i64, operand: i64) c_int {
    const result = @addWithOverflow(value.*, operand);
    if (result[1] != 0) return 1;
    value.* = result[0];
    return 0;
}

pub fn subtract(value: *i64, operand: i64) c_int {
    const result = @subWithOverflow(value.*, operand);
    if (result[1] != 0) return 1;
    value.* = result[0];
    return 0;
}

pub fn multiply(value: *i64, operand: i64) c_int {
    const result = @mulWithOverflow(value.*, operand);
    if (result[1] != 0) return 1;
    value.* = result[0];
    return 0;
}

pub fn absInt32(value: i32) i32 {
    if (value == std.math.minInt(i32)) return std.math.maxInt(i32);
    return if (value < 0) -value else value;
}

test "checked operations preserve inputs on overflow" {
    var value: i64 = std.math.maxInt(i64);
    try std.testing.expectEqual(@as(c_int, 1), add(&value, 1));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), value);
    value = std.math.minInt(i64);
    try std.testing.expectEqual(@as(c_int, 1), subtract(&value, 1));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), value);
    value = std.math.maxInt(i64);
    try std.testing.expectEqual(@as(c_int, 1), multiply(&value, 2));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), value);
    try std.testing.expectEqual(std.math.maxInt(i32), absInt32(std.math.minInt(i32)));
    try std.testing.expect(isNan(std.math.nan(f64)));
    try std.testing.expect(isOverflow(std.math.inf(f64)));
    try std.testing.expect(!isOverflow(1.0));
}
