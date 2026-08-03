//! SQLite-compatible decimal parser plus exact binary/decimal decode used by
//! the formatter. `sqlite3AtoF` retains its separately evidenced Zig parser;
//! `FpDecode` and its scaling arithmetic are source-corresponding.

const std = @import("std");

fn isSpace(byte: u8) bool {
    return byte == ' ' or (byte >= 0x09 and byte <= 0x0d);
}
fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn convert(mantissa: u64, exponent: i32) f64 {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}e{d}", .{ mantissa, exponent }) catch unreachable;
    return std.fmt.parseFloat(f64, text) catch unreachable;
}

pub const Result = struct { value: f64, code: c_int };

pub const powers_of_ten_first: i32 = -348;
pub const powers_of_ten_last: i32 = 347;
pub const u64_digits: usize = 20;

pub fn u64Bit(index: u6) u64 {
    return @as(u64, 1) << index;
}

/// Source representation: sqliteInt.h `struct FpDecode`.
pub const Decode = extern struct {
    n: c_int,
    iDP: c_int,
    z: ?[*]const u8,
    zBuf: [u64_digits + 1]u8,
    sign: u8,
    isSpecial: u8,
};

pub const Multiply128Result = struct { high: u64, low: u64 };
pub const Multiply160Result = struct { high: u64, low: u32 };
pub const DecimalScale = struct { high: u64, low: u32 };
pub const DecimalConversion = struct { digits: u64, exponent: i32 };

/// Upstream: sqlite3Multiply128().
pub fn multiply128(left: u64, right: u64) Multiply128Result {
    const product: u128 = @as(u128, left) * right;
    return .{ .high = @truncate(product >> 64), .low = @truncate(product) };
}

/// Upstream: sqlite3Multiply160().
pub fn multiply160(high: u64, low: u32, right: u64) Multiply160Result {
    var product: u128 = @as(u128, high) * right;
    product +%= (@as(u128, low) * right) >> 32;
    return .{ .high = @truncate(product >> 64), .low = @truncate(product >> 32) };
}

const base_powers = [27]u64{
    0x8000000000000000, 0xa000000000000000, 0xc800000000000000,
    0xfa00000000000000, 0x9c40000000000000, 0xc350000000000000,
    0xf424000000000000, 0x9896800000000000, 0xbebc200000000000,
    0xee6b280000000000, 0x9502f90000000000, 0xba43b74000000000,
    0xe8d4a51000000000, 0x9184e72a00000000, 0xb5e620f480000000,
    0xe35fa931a0000000, 0x8e1bc9bf04000000, 0xb1a2bc2ec5000000,
    0xde0b6b3a76400000, 0x8ac7230489e80000, 0xad78ebc5ac620000,
    0xd8d726b7177a8000, 0x878678326eac9000, 0xa968163f0a57b400,
    0xd3c21bcecceda100, 0x84595161401484a0, 0xa56fa5b99019a5c8,
};
const scale_powers = [26]u64{
    0x8049a4ac0c5811ae, 0xcf42894a5dce35ea, 0xa76c582338ed2621,
    0x873e4f75e2224e68, 0xda7f5bf590966848, 0xb080392cc4349dec,
    0x8e938662882af53e, 0xe65829b3046b0afa, 0xba121a4650e4ddeb,
    0x964e858c91ba2655, 0xf2d56790ab41c2a2, 0xc428d05aa4751e4c,
    0x9e74d1b791e07e48, 0xcccccccccccccccc, 0xcecb8f27f4200f3a,
    0xa70c3c40a64e6c51, 0x86f0ac99b4e8dafd, 0xda01ee641a708de9,
    0xb01ae745b101e9e4, 0x8e41ade9fbebc27d, 0xe5d3ef282a242e81,
    0xb9a74a0637ce2ee1, 0x95f83d0a1fb69cd9, 0xf24a01a73cf2dccf,
    0xc3b8358109e84f07, 0x9e19db92b4e31ba9,
};
const scale_powers_low = [26]u32{
    0x205b896d, 0x52064cad, 0xaf2af2b8, 0x5a7744a7, 0xaf39a475,
    0xbd8d794e, 0x547eb47b, 0x0cb4a5a3, 0x92f34d62, 0x3a6a07f9,
    0xfae27299, 0xaa97e14c, 0x775ea265, 0xcccccccc, 0x00000000,
    0x999090b6, 0x69a028bb, 0xe80e6f48, 0x5ec05dd0, 0x14588f14,
    0x8f1668c9, 0x6d953e2c, 0x4abdaf10, 0xbc633b39, 0x0a862f81,
    0x6c07a2c2,
};

/// Upstream: powerOfTen().
pub fn powerOfTen(power: i32) DecimalScale {
    std.debug.assert(power >= powers_of_ten_first and power <= powers_of_ten_last);
    var group: i32 = undefined;
    var remainder: i32 = undefined;
    if (power < 0) {
        if (power == -1) return .{ .high = scale_powers[13], .low = scale_powers_low[13] };
        group = @divTrunc(power, 27);
        remainder = @rem(power, 27);
        if (remainder != 0) {
            group -= 1;
            remainder += 27;
        }
    } else if (power < 27) {
        return .{ .high = base_powers[@intCast(power)], .low = 0 };
    } else {
        group = @divTrunc(power, 27);
        remainder = @rem(power, 27);
    }
    const index: usize = @intCast(group + 13);
    const scale = scale_powers[index];
    if (remainder == 0) return .{ .high = scale, .low = scale_powers_low[index] };
    const product = multiply160(scale, scale_powers_low[index], base_powers[@intCast(remainder)]);
    if (product.high & u64Bit(63) == 0) {
        return .{ .high = (product.high << 1) | ((product.low >> 31) & 1), .low = (product.low << 1) | 1 };
    }
    return .{ .high = product.high, .low = product.low };
}

pub fn power10To2(power: i32) i32 {
    return (power * 108_853) >> 15;
}

pub fn power2To10(power: i32) i32 {
    return (power * 78_913) >> 18;
}

pub fn countLeadingZeros(value: u64) c_int {
    return @intCast(@clz(value));
}

/// Upstream: sqlite3Fp2Convert10().
pub fn binaryToDecimal(mantissa: u64, exponent: i32, digit_count: i32) DecimalConversion {
    std.debug.assert(digit_count >= 1 and digit_count <= 18);
    const power = digit_count - 1 - power2To10(exponent + 63);
    const scale = powerOfTen(power);
    const product = multiply128(mantissa, scale.high);
    const shift_eighteen = -(exponent + power10To2(power) + 2);
    const digits = if (digit_count == 18) blk: {
        const shifted = product.high >> @intCast(shift_eighteen);
        break :blk (shifted + ((shifted << 1) & 2)) >> 1;
    } else product.high >> @intCast(-(exponent + power10To2(power) + 1));
    return .{ .digits = digits, .exponent = -power };
}

/// Upstream: sqlite3Fp10Convert2().
pub fn decimalToBinary(digits_value: u64, power: i32) f64 {
    if (power < powers_of_ten_first) return 0.0;
    if (power > powers_of_ten_last) return std.math.inf(f64);
    const bit_count: i32 = 64 - countLeadingZeros(digits_value);
    const binary_power = power10To2(power);
    var exponent = 53 - bit_count - binary_power;
    if (exponent > 1074) {
        if (exponent >= 1130) return 0.0;
        exponent = 1074;
    }
    const shift: u6 = @intCast(-(exponent - (64 - bit_count) + binary_power + 3));
    var scale = powerOfTen(power);
    if (scale.low != 0) {
        scale.high +%= 1;
        scale.low = ~scale.low;
    }
    const normalized = digits_value << @intCast(64 - bit_count);
    var product = multiply128(normalized, scale.high);
    const middle_one: u32 = @truncate(product.low >> 32);
    var sticky: u64 = 1;
    if (product.high & (u64Bit(shift) - 1) == 0) {
        const middle_two: u32 = @truncate(multiply128(normalized, @as(u64, scale.low) << 32).high >> 32);
        sticky = @intFromBool(middle_one -% middle_two > 1);
        product.high -%= @intFromBool(middle_one < middle_two);
    }
    var rounded = (product.high >> shift) | sticky;
    const adjust: u1 = @intFromBool(rounded >= u64Bit(55) - 2);
    if (adjust != 0) {
        rounded = (rounded >> adjust) | (rounded & 1);
        exponent -= adjust;
    }
    var mantissa = (rounded + 1 + ((rounded >> 2) & 1)) >> 2;
    if (exponent <= -972) return std.math.inf(f64);
    if (mantissa & u64Bit(52) != 0) {
        mantissa = (mantissa & ~u64Bit(52)) | (@as(u64, @intCast(1075 - exponent)) << 52);
    }
    return @bitCast(mantissa);
}

/// Upstream: sqlite3FpDecode().
pub fn decode(output: *Decode, real_argument: f64, round_argument: c_int, maximum_round: c_int) void {
    var real = real_argument;
    var round = round_argument;
    output.isSpecial = 0;
    std.debug.assert(maximum_round > 0);
    if (real < 0.0) {
        output.sign = '-';
        real = -real;
    } else if (real == 0.0) {
        output.sign = '+';
        output.n = 1;
        output.iDP = 1;
        output.z = "0";
        return;
    } else {
        output.sign = '+';
    }
    var bits: u64 = @bitCast(real);
    var exponent: i32 = @intCast((bits >> 52) & 0x7ff);
    if (exponent == 0x7ff) {
        output.isSpecial = 1 + @as(u8, @intFromBool(bits != 0x7ff0000000000000));
        output.n = 0;
        output.iDP = 0;
        output.z = &output.zBuf;
        return;
    }
    bits &= 0x000f_ffff_ffff_ffff;
    if (exponent == 0) {
        const leading = countLeadingZeros(bits);
        bits <<= @intCast(leading);
        exponent = -1074 - leading;
    } else {
        bits = (bits << 11) | u64Bit(63);
        exponent -= 1086;
    }
    const converted = binaryToDecimal(bits, exponent, if (round <= 0 or round >= 18) 18 else round + 1);
    var value = converted.digits;
    var index: usize = u64_digits;
    while (value >= 10) {
        const pair: u8 = @intCast(value % 100);
        index -= 2;
        output.zBuf[index] = '0' + pair / 10;
        output.zBuf[index + 1] = '0' + pair % 10;
        value /= 100;
    }
    if (value != 0) {
        index -= 1;
        output.zBuf[index] = '0' + @as(u8, @intCast(value));
    }
    var length: c_int = @intCast(u64_digits - index);
    output.iDP = length + converted.exponent;
    if (round <= 0) {
        round = output.iDP - round;
        if (round == 0 and output.zBuf[index] >= '5') {
            round = 1;
            index -= 1;
            output.zBuf[index] = '0';
            length += 1;
            output.iDP += 1;
        }
    }
    var digits_pointer: [*]u8 = output.zBuf[index..].ptr;
    if (round > 0 and (round < length or length > maximum_round)) {
        if (round > maximum_round) round = maximum_round;
        if (round == 17) {
            if (digits_pointer[15] == '9' and digits_pointer[14] == '9') {
                var reduced: c_int = 14;
                while (reduced > 0 and digits_pointer[@intCast(reduced - 1)] == '9') reduced -= 1;
                var candidate: u64 = if (reduced == 0) 1 else digits_pointer[0] - '0';
                var at: c_int = 1;
                while (at < reduced) : (at += 1) candidate = candidate * 10 + digits_pointer[@intCast(at)] - '0';
                if (reduced != 0) candidate += 1;
                if (@as(u64, @bitCast(real)) == @as(u64, @bitCast(decimalToBinary(candidate, converted.exponent + length - reduced)))) round = reduced + 1;
            } else if (output.iDP >= length or (digits_pointer[15] == '0' and digits_pointer[14] == '0' and digits_pointer[13] == '0')) {
                var reduced: c_int = 13;
                while (digits_pointer[@intCast(reduced - 1)] == '0') reduced -= 1;
                var candidate: u64 = digits_pointer[0] - '0';
                var at: c_int = 1;
                while (at < reduced) : (at += 1) candidate = candidate * 10 + digits_pointer[@intCast(at)] - '0';
                if (@as(u64, @bitCast(real)) == @as(u64, @bitCast(decimalToBinary(candidate, converted.exponent + length - reduced)))) round = reduced + 1;
            }
        }
        length = round;
        if (digits_pointer[@intCast(round)] >= '5') {
            var at = round - 1;
            while (true) {
                digits_pointer[@intCast(at)] += 1;
                if (digits_pointer[@intCast(at)] <= '9') break;
                digits_pointer[@intCast(at)] = '0';
                if (at == 0) {
                    digits_pointer -= 1;
                    digits_pointer[0] = '1';
                    length += 1;
                    output.iDP += 1;
                    break;
                }
                at -= 1;
            }
        }
    }
    while (digits_pointer[@intCast(length - 1)] == '0') {
        length -= 1;
        std.debug.assert(length > 0);
    }
    output.n = length;
    output.z = digits_pointer;
}

/// Upstream: sqlite3AtoF (src/util.c line 871).
pub fn parse(input: [*:0]const u8) Result {
    var position: usize = 0;
    var negative = false;
    var mantissa: u64 = 0;
    var exponent: i32 = 0;
    var state: u4 = 0;
    var digit: u32 = 0;

    while (isSpace(input[position])) position += 1;
    digit = @as(u32, input[position]) -% '0';
    if (digit >= 10) {
        if (input[position] == '-') {
            negative = true;
            position += 1;
            digit = @as(u32, input[position]) -% '0';
        } else if (input[position] == '+') {
            position += 1;
            digit = @as(u32, input[position]) -% '0';
        }
    }

    if (digit < 10) {
        state = 1;
        mantissa = digit;
        position += 1;
        while (isDigit(input[position])) {
            digit = input[position] - '0';
            mantissa = mantissa * 10 + digit;
            position += 1;
            if (mantissa >= (std.math.maxInt(u64) - 9) / 10) {
                state = 9;
                while (isDigit(input[position])) : (position += 1) exponent += 1;
                break;
            }
        }
    } else {
        mantissa = 0;
    }

    if (input[position] == '.') {
        position += 1;
        if (isDigit(input[position])) {
            state |= 1;
            while (isDigit(input[position])) : (position += 1) {
                if (mantissa < (std.math.maxInt(u64) - 9) / 10) {
                    mantissa = mantissa * 10 + input[position] - '0';
                    exponent -= 1;
                } else {
                    state = 11;
                }
            }
        } else if (state == 0) {
            return .{ .value = 0.0, .code = 0 };
        }
        state |= 2;
    } else if (state == 0) {
        return .{ .value = 0.0, .code = 0 };
    }

    if (input[position] == 'e' or input[position] == 'E') {
        position += 1;
        var exponent_sign: i32 = 1;
        if (input[position] == '-') {
            exponent_sign = -1;
            position += 1;
        } else if (input[position] == '+') {
            position += 1;
        }
        digit = @as(u32, input[position]) -% '0';
        if (digit < 10) {
            var explicit_exponent: i32 = @intCast(digit);
            position += 1;
            state |= 2;
            while (isDigit(input[position])) : (position += 1) {
                explicit_exponent = if (explicit_exponent < 10_000)
                    explicit_exponent * 10 + input[position] - '0'
                else
                    10_000;
            }
            exponent += exponent_sign * explicit_exponent;
        } else {
            position -= 1;
        }
    }

    var value: f64 = if (mantissa == 0) 0.0 else convert(mantissa, exponent);
    if (mantissa == 0) state |= 4;
    if (negative) value = -value;

    if (input[position] == 0) return .{ .value = value, .code = state };
    if (isSpace(input[position])) {
        while (isSpace(input[position])) position += 1;
        if (input[position] == 0) return .{ .value = value, .code = state };
    }
    const invalid: u32 = 0xffff_fff0 | @as(u32, state);
    return .{ .value = value, .code = @bitCast(invalid) };
}

test "lexical states and representative values" {
    const cases = [_]struct { [*:0]const u8, f64, c_int }{
        .{ "", 0.0, 0 },
        .{ ".", 0.0, 0 },
        .{ "42", 42.0, 1 },
        .{ "-0.0", -0.0, 7 },
        .{ "  1.25e2  ", 125.0, 3 },
        .{ "1e", 1.0, -15 },
        .{ "1x", 1.0, -15 },
        .{ "3500000000000000.2500001", 3500000000000000.0, 11 },
    };
    for (cases) |case| {
        const result = parse(case[0]);
        try std.testing.expectEqual(@as(u64, @bitCast(case[1])), @as(u64, @bitCast(result.value)));
        try std.testing.expectEqual(case[2], result.code);
    }
}
