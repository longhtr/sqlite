//! SQLite ASCII-case-folded string primitives translated from `src/util.c`
//! and the `sqlite3UpperToLower` table in `src/global.c`.
//!
//! Case folding affects only US-ASCII A through Z. Bytes 0x80 through 0xff
//! remain unchanged, including when they form part of UTF-8 text.

const std = @import("std");
const numeric = @import("numeric.zig");

fn isQuote(byte: u8) bool {
    return byte == '\'' or byte == '"' or byte == '`' or byte == '[';
}

/// Upstream: sqlite3Dequote().
pub fn dequote(input_optional: ?[*:0]u8) void {
    const input = input_optional orelse return;
    var quote = input[0];
    if (!isQuote(quote)) return;
    if (quote == '[') quote = ']';
    var source: usize = 1;
    var target: usize = 0;
    while (true) : (source += 1) {
        std.debug.assert(input[source] != 0);
        if (input[source] == quote) {
            if (input[source + 1] == quote) {
                input[target] = quote;
                target += 1;
                source += 1;
            } else break;
        } else {
            input[target] = input[source];
            target += 1;
        }
    }
    input[target] = 0;
}

pub const expression_quoted: u32 = 0x0400_0000;
pub const expression_double_quoted: u32 = 0x0000_0080;

pub const ExpressionTokenView = struct {
    text: [*:0]u8,
    flags: u32,
};

/// Upstream: sqlite3DequoteExpr(), using the reached Expr fields.
pub fn dequoteExpression(expression: *ExpressionTokenView) void {
    expression.flags |= expression_quoted;
    if (expression.text[0] == '"') expression.flags |= expression_double_quoted;
    dequote(expression.text);
}

pub const NumberKind = enum { integer, float };
pub const DequotedNumber = struct {
    kind: NumberKind,
    integer_value: ?i32,
    invalid_separator: bool,
};

/// Upstream: sqlite3DequoteNumber(), with parser error reporting returned as
/// typed state rather than written through Parse.
pub fn dequoteNumber(text: [*:0]u8) DequotedNumber {
    const original = std.mem.span(text);
    const hexadecimal = original.len >= 2 and original[0] == '0' and (original[1] == 'x' or original[1] == 'X');
    var kind: NumberKind = .integer;
    var invalid = false;
    var source: usize = 0;
    var target: usize = 0;
    while (source <= original.len) : (source += 1) {
        const byte = text[source];
        if (byte != '_') {
            text[target] = byte;
            target += 1;
            if (byte == 'e' or byte == 'E' or byte == '.') kind = .float;
        } else {
            const before_valid = source > 0 and if (hexadecimal) std.ascii.isHex(text[source - 1]) else std.ascii.isDigit(text[source - 1]);
            const after_valid = source + 1 < original.len and if (hexadecimal) std.ascii.isHex(text[source + 1]) else std.ascii.isDigit(text[source + 1]);
            if (!before_valid or !after_valid) invalid = true;
        }
    }
    if (hexadecimal) kind = .integer;
    const parsed: numeric.ParseI32Result = if (kind == .integer) numeric.getInt32(text) else .{ .value = 0, .valid = false };
    return .{ .kind = kind, .integer_value = if (parsed.valid) parsed.value else null, .invalid_separator = invalid };
}

/// Upstream: sqlite3DequoteToken().
pub fn dequoteToken(token: anytype) void {
    if (token.n < 2 or token.z == null) return;
    const length: usize = @intCast(token.n);
    const bytes = token.z.?;
    if (!isQuote(bytes[0])) return;
    for (bytes[1 .. length - 1]) |byte| {
        if (isQuote(byte)) return;
    }
    token.z = bytes + 1;
    token.n -= 2;
}

/// Upstream: sqlite3TokenInit().
pub fn tokenInit(token: anytype, text: [*:0]const u8) void {
    token.z = text;
    token.n = @intCast(@min(std.mem.len(text), 0x3fff_ffff));
}

/// Upstream: sqlite3UpperToLower (src/global.c line 24).
pub const upper_to_lower: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, index| entry.* = @intCast(index);
    for ('A'..'Z' + 1) |byte| table[byte] = @intCast(byte + 0x20);
    break :blk table;
};

/// Upstream: `UpperToLower` (src/util.c line 396).
pub fn foldByte(byte: u8) u8 {
    return upper_to_lower[byte];
}

/// Upstream: sqlite3StrICmp (line 416). Inputs are non-null.
pub fn compareInternal(left: [*:0]const u8, right: [*:0]const u8) c_int {
    var index: usize = 0;
    while (true) : (index += 1) {
        const left_byte = left[index];
        const right_byte = right[index];
        if (left_byte == right_byte) {
            if (left_byte == 0) return 0;
        } else {
            const difference = @as(c_int, foldByte(left_byte)) - foldByte(right_byte);
            if (difference != 0) return difference;
        }
    }
}

/// Upstream: sqlite3_stricmp (line 408).
pub fn compare(left: ?[*:0]const u8, right: ?[*:0]const u8) c_int {
    const left_value = left orelse return if (right == null) 0 else -1;
    const right_value = right orelse return 1;
    return compareInternal(left_value, right_value);
}

/// Upstream: sqlite3_strnicmp (line 435).
pub fn compareN(left: ?[*:0]const u8, right: ?[*:0]const u8, count: c_int) c_int {
    const left_value = left orelse return if (right == null) 0 else -1;
    const right_value = right orelse return 1;
    if (count <= 0) return 0;

    var remaining = count;
    var index: usize = 0;
    while (remaining > 0 and left_value[index] != 0 and
        foldByte(left_value[index]) == foldByte(right_value[index]))
    {
        index += 1;
        remaining -= 1;
    }
    if (remaining == 0) return 0;
    return @as(c_int, foldByte(left_value[index])) - foldByte(right_value[index]);
}

/// Alias-equivalent implementation of `sqlite3StrNICmp`.
pub const compareInternalN = compareN;

/// Upstream: sqlite3StrIHash (line 451).
pub fn insensitiveHash(value: ?[*:0]const u8) u8 {
    const string = value orelse return 0;
    var result: u8 = 0;
    var index: usize = 0;
    while (string[index] != 0) : (index += 1) {
        result +%= foldByte(string[index]);
    }
    return result;
}

/// Upstream: sqlite3Strlen30 (line 92).
pub fn length30(value: ?[*:0]const u8) c_int {
    const string = value orelse return 0;
    return @intCast(std.mem.len(string) & 0x3fff_ffff);
}

/// Macro-equivalent `sqlite3Strlen30NN` for a non-null input.
pub fn length30NonNull(value: [*:0]const u8) c_int {
    return @intCast(std.mem.len(value) & 0x3fff_ffff);
}

test "dequote and Token optimization preserve SQLite quote rules" {
    var quoted = [_:0]u8{ '\'', 'a', '\'', '\'', 'b', '\'' };
    dequote(&quoted);
    try std.testing.expectEqualStrings("a'b", std.mem.span(@as([*:0]u8, &quoted)));
    var bracket = [_:0]u8{ '[', 'a', '-', 'b', ']' };
    dequote(&bracket);
    try std.testing.expectEqualStrings("a-b", std.mem.span(@as([*:0]u8, &bracket)));
    var plain = [_:0]u8{'x'};
    dequote(&plain);
    try std.testing.expectEqualStrings("x", std.mem.span(@as([*:0]u8, &plain)));

    const TestToken = struct { z: ?[*]const u8, n: c_uint };
    const simple: [:0]const u8 = "\"abc\"";
    var token = TestToken{ .z = null, .n = 0 };
    tokenInit(&token, simple);
    dequoteToken(&token);
    try std.testing.expectEqual(@as(c_uint, 3), token.n);
    try std.testing.expectEqualStrings("abc", token.z.?[0..3]);
    const doubled: [:0]const u8 = "\"ab\"\"cd\"";
    tokenInit(&token, doubled);
    dequoteToken(&token);
    try std.testing.expectEqual(@as(c_uint, 8), token.n);
}

test "Expr and quoted-number views preserve flags types separators and IntValue" {
    var expression_text = [_:0]u8{ '"', 'n', 'a', 'm', 'e', '"' };
    var expression = ExpressionTokenView{ .text = &expression_text, .flags = 0 };
    dequoteExpression(&expression);
    try std.testing.expectEqual(expression_quoted | expression_double_quoted, expression.flags);
    try std.testing.expectEqualStrings("name", std.mem.span(expression.text));

    var integer = [_:0]u8{ '1', '_', '2', '3' };
    var result = dequoteNumber(&integer);
    try std.testing.expectEqual(NumberKind.integer, result.kind);
    try std.testing.expectEqual(@as(?i32, 123), result.integer_value);
    try std.testing.expect(!result.invalid_separator);
    var float = [_:0]u8{ '1', '_', '2', '.', '5', 'e', '+', '1' };
    result = dequoteNumber(&float);
    try std.testing.expectEqual(NumberKind.float, result.kind);
    try std.testing.expectEqualStrings("12.5e+1", std.mem.span(@as([*:0]u8, &float)));
    var bad = [_:0]u8{ '1', '_', '.', '2' };
    result = dequoteNumber(&bad);
    try std.testing.expect(result.invalid_separator);
}

test "case-fold table changes only ASCII uppercase" {
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        const expected: u8 = if (byte >= 'A' and byte <= 'Z') byte + 0x20 else byte;
        try std.testing.expectEqual(expected, foldByte(byte));
    }
}

test "null and ASCII comparison behavior" {
    try std.testing.expectEqual(@as(c_int, 0), compare(null, null));
    try std.testing.expectEqual(@as(c_int, -1), compare(null, "a"));
    try std.testing.expectEqual(@as(c_int, 1), compare("a", null));
    try std.testing.expectEqual(@as(c_int, 0), compare("SQLite", "sQLITE"));
    try std.testing.expect(compare("alpha", "beta") < 0);
    try std.testing.expect(compare("beta", "alpha") > 0);
    try std.testing.expect(compare("a", "aa") < 0);
}

test "non-ASCII bytes are not case folded" {
    const left = [_:0]u8{ 0xc3, 0x80 };
    const right = [_:0]u8{ 0xc3, 0xa0 };
    try std.testing.expectEqual(@as(c_int, -32), compare(&left, &right));
}

test "bounded comparison preserves zero and negative count behavior" {
    try std.testing.expectEqual(@as(c_int, 0), compareN("abc", "XYZ", 0));
    try std.testing.expectEqual(@as(c_int, 0), compareN("abc", "XYZ", -4));
    try std.testing.expectEqual(@as(c_int, 0), compareN("abC", "ABd", 2));
    try std.testing.expect(compareN("abC", "ABd", 3) < 0);
    try std.testing.expectEqual(@as(c_int, -1), compareN(null, "x", 0));
    try std.testing.expectEqual(@as(c_int, 1), compareN("x", null, 0));
}

test "case-insensitive hash wraps at eight bits" {
    try std.testing.expectEqual(@as(u8, 0), insensitiveHash(null));
    try std.testing.expectEqual(insensitiveHash("SQLite"), insensitiveHash("sQLITE"));
    const many = [_:0]u8{'Z'} ** 255;
    var expected: u8 = 0;
    for (0..255) |_| expected +%= 'z';
    try std.testing.expectEqual(expected, insensitiveHash(&many));
}

test "30-bit lengths include nullable and non-null forms" {
    try std.testing.expectEqual(@as(c_int, 0), length30(null));
    try std.testing.expectEqual(@as(c_int, 0), length30(""));
    try std.testing.expectEqual(@as(c_int, 6), length30("SQLite"));
    try std.testing.expectEqual(@as(c_int, 6), length30NonNull("SQLite"));
}
