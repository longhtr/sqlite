//! Integer numeric parsing primitives translated from SQLite `src/util.c`.

const std = @import("std");

pub const TextEncoding = enum(u8) { utf8 = 1, utf16le = 2, utf16be = 3 };

fn isSpace(byte: u8) bool {
    return byte == ' ' or (byte >= 0x09 and byte <= 0x0d);
}
fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}
fn isHex(byte: u8) bool {
    return isDigit(byte) or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F');
}

/// Upstream: sqlite3HexToInt (line 1879).
pub fn hexToInt(byte: u8) u8 {
    std.debug.assert(isHex(byte));
    return (byte + 9 * (1 & (byte >> 6))) & 0x0f;
}

/// Upstream: sqlite3HexToBlob(). `input` includes the trailing quote but not
/// the leading `x'`. The returned allocation includes a zero sentinel.
pub fn hexToBlob(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![:0]u8 {
    std.debug.assert(input.len >= 1 and input.len & 1 == 1);
    const output = try allocator.allocSentinel(u8, (input.len - 1) / 2, 0);
    var index: usize = 0;
    while (index + 1 < input.len) : (index += 2) {
        output[index / 2] = hexToInt(input[index]) << 4 | hexToInt(input[index + 1]);
    }
    return output;
}

const TextView = struct {
    input: []const u8,
    encoding: TextEncoding,
    length: usize,
    non_numeric_high_byte: bool,

    fn init(input: []const u8, encoding: TextEncoding) TextView {
        if (encoding == .utf8) return .{ .input = input, .encoding = encoding, .length = input.len, .non_numeric_high_byte = false };
        const unit_count = (input.len & ~@as(usize, 1)) / 2;
        const low_offset: usize = if (encoding == .utf16le) 0 else 1;
        const high_offset = low_offset ^ 1;
        for (0..unit_count) |index| {
            if (input[index * 2 + high_offset] != 0) {
                return .{ .input = input, .encoding = encoding, .length = index, .non_numeric_high_byte = true };
            }
        }
        return .{ .input = input, .encoding = encoding, .length = unit_count, .non_numeric_high_byte = false };
    }

    fn at(self: TextView, index: usize) u8 {
        if (self.encoding == .utf8) return self.input[index];
        const low_offset: usize = if (self.encoding == .utf16le) 0 else 1;
        return self.input[index * 2 + low_offset];
    }
};

fn compare2pow63(view: TextView, start: usize) c_int {
    const boundary = "9223372036854775808";
    for (0..19) |index| {
        const actual = view.at(start + index);
        const expected = boundary[index];
        if (actual != expected) return (@as(c_int, actual) - expected) * 10;
    }
    return 0;
}

pub const ParseI64Result = struct { value: i64, code: c_int };

/// Upstream: sqlite3Atoi64 (line 1166).
pub fn parseI64(input: []const u8, encoding: TextEncoding) ParseI64Result {
    const view = TextView.init(input, encoding);
    var position: usize = 0;
    while (position < view.length and isSpace(view.at(position))) position += 1;
    var negative = false;
    if (position < view.length and view.at(position) == '-') {
        negative = true;
        position += 1;
    } else if (position < view.length and view.at(position) == '+') {
        position += 1;
    }
    const before_digits = position;
    while (position < view.length and view.at(position) == '0') position += 1;
    const significant_start = position;
    var value: u64 = 0;
    while (position < view.length and isDigit(view.at(position))) : (position += 1) {
        value = value *% 10 +% (view.at(position) - '0');
    }
    const digit_count = position - significant_start;

    var output: i64 = undefined;
    if (value > std.math.maxInt(i64)) {
        output = if (negative) std.math.minInt(i64) else std.math.maxInt(i64);
    } else if (negative) {
        output = -@as(i64, @intCast(value));
    } else {
        output = @intCast(value);
    }

    var code: c_int = 0;
    if (digit_count == 0 and before_digits == significant_start) {
        code = -1;
    } else if (view.non_numeric_high_byte) {
        code = 1;
    } else if (position < view.length) {
        var suffix = position;
        while (suffix < view.length) : (suffix += 1) {
            if (!isSpace(view.at(suffix))) {
                code = 1;
                break;
            }
        }
    }

    if (digit_count < 19) return .{ .value = output, .code = code };
    const comparison: c_int = if (digit_count > 19) 1 else compare2pow63(view, significant_start);
    if (comparison < 0) return .{ .value = output, .code = code };
    output = if (negative) std.math.minInt(i64) else std.math.maxInt(i64);
    if (comparison > 0) return .{ .value = output, .code = 2 };
    return .{ .value = output, .code = if (negative) code else 3 };
}

/// Upstream: sqlite3DecOrHexToI64 (line 1269).
pub fn parseDecimalOrHex(input: [*:0]const u8) ParseI64Result {
    if (input[0] == '0' and (input[1] == 'x' or input[1] == 'X')) {
        var position: usize = 2;
        while (input[position] == '0') position += 1;
        const significant_start = position;
        var value: u64 = 0;
        while (isHex(input[position])) : (position += 1) {
            value = value *% 16 +% hexToInt(input[position]);
        }
        const output: i64 = @bitCast(value);
        if (position - significant_start > 16) return .{ .value = output, .code = 2 };
        if (input[position] != 0) return .{ .value = output, .code = 1 };
        return .{ .value = output, .code = 0 };
    }
    var length: usize = 0;
    while (input[length] == '+' or input[length] == '-' or input[length] == ' ' or
        input[length] == '\n' or input[length] == '\t' or isDigit(input[length]))
    {
        length += 1;
    }
    if (input[length] != 0) length += 1;
    return parseI64(input[0..length], .utf8);
}

pub const ParseI32Result = struct { value: i32, valid: bool };

/// Upstream: sqlite3GetInt32 (line 1303).
pub fn getInt32(input: [*:0]const u8) ParseI32Result {
    var position: usize = 0;
    var negative: i64 = 0;
    if (input[0] == '-') {
        negative = 1;
        position = 1;
    } else if (input[0] == '+') {
        position = 1;
    } else if (input[0] == '0' and (input[1] == 'x' or input[1] == 'X') and isHex(input[2])) {
        position = 2;
        while (input[position] == '0') position += 1;
        var value: u32 = 0;
        var count: usize = 0;
        while (count < 8 and isHex(input[position + count])) : (count += 1) {
            value = value * 16 + hexToInt(input[position + count]);
        }
        if ((value & 0x8000_0000) == 0 and !isHex(input[position + count])) {
            return .{ .value = @bitCast(value), .valid = true };
        }
        return .{ .value = 0, .valid = false };
    }
    if (!isDigit(input[position])) return .{ .value = 0, .valid = false };
    while (input[position] == '0') position += 1;
    var value: i64 = 0;
    var count: usize = 0;
    while (count < 11 and isDigit(input[position + count])) : (count += 1) {
        value = value * 10 + input[position + count] - '0';
    }
    if (count > 10 or value - negative > std.math.maxInt(i32)) return .{ .value = 0, .valid = false };
    if (negative != 0) value = -value;
    return .{ .value = @intCast(value), .valid = true };
}

/// Upstream: sqlite3Atoi (line 1362).
pub fn atoi(input: [*:0]const u8) i32 {
    return getInt32(input).value;
}

pub const ParseU32Result = struct { value: u32, valid: bool };

/// Upstream: sqlite3GetUInt32 (line 1538).
pub fn getUInt32(input: [*:0]const u8) ParseU32Result {
    var value: u64 = 0;
    var position: usize = 0;
    while (isDigit(input[position])) : (position += 1) {
        value = value * 10 + input[position] - '0';
        if (value > 4_294_967_296) return .{ .value = 0, .valid = false };
    }
    if (position == 0 or input[position] != 0) return .{ .value = 0, .valid = false };
    return .{ .value = @truncate(value), .valid = true };
}

/// Output-equivalent formatting subset for sqlite3Int64ToText (line 1068).
pub fn formatI64(output: *[21]u8, value: i64) []const u8 {
    return std.fmt.bufPrint(output, "{d}", .{value}) catch unreachable;
}

test "hex blob allocation preserves bytes sentinel and OOM" {
    const bytes = try hexToBlob(std.testing.allocator, "0041ff'");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x41, 0xff }, bytes);
    try std.testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
    const empty = try hexToBlob(std.testing.allocator, "'");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const result = try hexToBlob(allocator, "4142'");
            defer allocator.free(result);
        }
    }.run, .{});
}

test "signed integer formatting subset" {
    var output: [21]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatI64(&output, 0));
    try std.testing.expectEqualStrings("9223372036854775807", formatI64(&output, std.math.maxInt(i64)));
    try std.testing.expectEqualStrings("-9223372036854775808", formatI64(&output, std.math.minInt(i64)));
}

test "signed 64-bit boundaries and status codes" {
    const cases = [_]struct { []const u8, i64, c_int }{
        .{ "", 0, -1 },                                      .{ "  +42  ", 42, 0 },                               .{ "42x", 42, 1 },
        .{ "9223372036854775807", std.math.maxInt(i64), 0 }, .{ "9223372036854775808", std.math.maxInt(i64), 3 }, .{ "-9223372036854775808", std.math.minInt(i64), 0 },
        .{ "9223372036854775809", std.math.maxInt(i64), 2 }, .{ "000000000000000000000001", 1, 0 },
    };
    for (cases) |case| {
        const result = parseI64(case[0], .utf8);
        try std.testing.expectEqual(case[1], result.value);
        try std.testing.expectEqual(case[2], result.code);
    }
}

test "UTF-16 integer parsing checks high bytes" {
    const little = [_]u8{ '4', 0, '2', 0 };
    try std.testing.expectEqual(ParseI64Result{ .value = 42, .code = 0 }, parseI64(&little, .utf16le));
    const big = [_]u8{ 0, '4', 0, '2' };
    try std.testing.expectEqual(ParseI64Result{ .value = 42, .code = 0 }, parseI64(&big, .utf16be));
    const malformed = [_]u8{ '4', 1, '2', 0 };
    try std.testing.expectEqual(@as(c_int, -1), parseI64(&malformed, .utf16le).code);
}

test "UTF-16 parsing has no fixed utility buffer limit" {
    var text: [2400]u8 = undefined;
    for (0..1200) |index| {
        text[index * 2] = if (index < 1199) '0' else '7';
        text[index * 2 + 1] = 0;
    }
    try std.testing.expectEqual(ParseI64Result{ .value = 7, .code = 0 }, parseI64(&text, .utf16le));
}

test "hex and 32-bit parser peculiarities" {
    try std.testing.expectEqual(ParseI64Result{ .value = -1, .code = 0 }, parseDecimalOrHex("0xffffffffffffffff"));
    try std.testing.expectEqual(ParseI64Result{ .value = 0, .code = 2 }, parseDecimalOrHex("0x10000000000000000"));
    try std.testing.expectEqual(ParseI32Result{ .value = -2147483648, .valid = true }, getInt32("-2147483648tail"));
    try std.testing.expectEqual(ParseI32Result{ .value = 0x7fffffff, .valid = true }, getInt32("0x7fffffff!"));
    try std.testing.expect(!getInt32("0x80000000").valid);
    try std.testing.expectEqual(@as(i32, 0), atoi("not-a-number"));
    try std.testing.expectEqual(ParseU32Result{ .value = 0, .valid = true }, getUInt32("4294967296"));
    try std.testing.expect(!getUInt32("4294967297").valid);
}
