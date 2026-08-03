const std = @import("std");
const float = @import("sqlite_float");

fn showDecode(id: usize, value: f64, round: c_int, maximum: c_int) void {
    var decoded: float.Decode = undefined;
    float.decode(&decoded, value, round, maximum);
    std.debug.print("D{d:0>2}\t{x:0>16}\t{d}\t{d}\t{d}\t{c}\t{d}\t", .{
        id, @as(u64, @bitCast(value)), round, maximum, decoded.n, decoded.sign, decoded.isSpecial,
    });
    if (decoded.z) |digits| std.debug.print("{s}", .{digits[0..@intCast(decoded.n)]});
    std.debug.print("\t{d}\n", .{decoded.iDP});
}

pub fn main() void {
    const products = [_][2]u64{
        .{ 1, 1 },
        .{ 0xffffffffffffffff, 0xffffffffffffffff },
        .{ 0x8123456789abcdef, 0xfedcba9876543210 },
    };
    const wide = [_]struct { high: u64, low: u32, right: u64 }{
        .{ .high = 1, .low = 1, .right = 1 },
        .{ .high = 0xffffffffffffffff, .low = 0xffffffff, .right = 0xffffffffffffffff },
        .{ .high = 0x8123456789abcdef, .low = 0x76543210, .right = 0xfedcba9876543210 },
    };
    const powers = [_]i32{ -348, -324, -27, -1, 0, 26, 27, 347 };
    std.debug.print("LAYOUT\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @sizeOf(float.Decode),        @alignOf(float.Decode),          @offsetOf(float.Decode, "n"),    @offsetOf(float.Decode, "iDP"),
        @offsetOf(float.Decode, "z"), @offsetOf(float.Decode, "zBuf"), @offsetOf(float.Decode, "sign"), @offsetOf(float.Decode, "isSpecial"),
    });
    for (products, 0..) |values, index| {
        const result = float.multiply128(values[0], values[1]);
        std.debug.print("M128-{d}\t{x:0>16}\t{x:0>16}\n", .{ index, result.high, result.low });
    }
    for (wide, 0..) |values, index| {
        const result = float.multiply160(values.high, values.low, values.right);
        std.debug.print("M160-{d}\t{x:0>16}\t{x:0>8}\n", .{ index, result.high, result.low });
    }
    for (powers, 0..) |power, index| {
        const result = float.powerOfTen(power);
        std.debug.print("P10-{d}\t{d}\t{x:0>16}\t{x:0>8}\n", .{ index, power, result.high, result.low });
    }
    std.debug.print("RATIO\t{d}\t{d}\t{d}\t{d}\n", .{
        float.power10To2(-348), float.power10To2(347), float.power2To10(-1074), float.power2To10(1023),
    });
    const binary_cases = [_]struct { mantissa: u64, exponent: i32, count: i32 }{
        .{ .mantissa = 0x8000000000000000, .exponent = -1086, .count = 18 },
        .{ .mantissa = 0xa000000000000000, .exponent = -66, .count = 16 },
        .{ .mantissa = 0xffffffffffffffff, .exponent = -100, .count = 7 },
        .{ .mantissa = 0x8000000000000000, .exponent = 960, .count = 18 },
    };
    for (binary_cases, 0..) |values, index| {
        const result = float.binaryToDecimal(values.mantissa, values.exponent, values.count);
        std.debug.print("B2D-{d}\t{d}\t{d}\n", .{ index, result.digits, result.exponent });
    }
    const decimal_cases = [_]struct { digits: u64, power: i32 }{
        .{ .digits = 1, .power = -348 },  .{ .digits = 1, .power = -324 },                    .{ .digits = 1, .power = -1 },
        .{ .digits = 4947, .power = -2 }, .{ .digits = 3_141_592_653_589_793, .power = -15 }, .{ .digits = 1, .power = 347 },
    };
    for (decimal_cases, 0..) |values, index| {
        const result = float.decimalToBinary(values.digits, values.power);
        std.debug.print("D2B-{d}\t{x:0>16}\n", .{ index, @as(u64, @bitCast(result)) });
    }
    showDecode(0, 0.0, 6, 16);
    showDecode(1, @bitCast(@as(u64, 0x8000000000000000)), 6, 16);
    showDecode(2, 1.0, 6, 16);
    showDecode(3, -1.0, 6, 16);
    showDecode(4, 1.25, -6, 16);
    showDecode(5, 49.47, 17, 20);
    showDecode(6, 0.1, 16, 16);
    showDecode(7, std.math.floatMin(f64), 16, 16);
    showDecode(8, @bitCast(@as(u64, 1)), 16, 16);
    showDecode(9, std.math.floatMax(f64), 16, 16);
    showDecode(10, std.math.inf(f64), 6, 16);
    showDecode(11, -std.math.inf(f64), 6, 16);
    showDecode(12, @bitCast(@as(u64, 0x7ff8000000000001)), 6, 16);
    showDecode(13, 3.141592653589793, -6, 16);
    showDecode(14, 9.999, 3, 16);
    showDecode(15, 999.5, 3, 16);
    var state: u64 = 0x9e3779b97f4a7c15;
    const rounds = [_]c_int{ -20, -6, 0, 1, 6, 16, 17, 30 };
    for (0..256) |index| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        showDecode(100 + index, @bitCast(state), rounds[index & 7], if (index & 1 != 0) 20 else 16);
    }
}
