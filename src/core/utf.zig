//! Pure UTF primitives translated from SQLite `src/utf.c`.
//!
//! These deliberately preserve SQLite's permissive handling of malformed and
//! overlong UTF-8. They are byte codecs, not Unicode validation routines.

const std = @import("std");

/// Upstream: sqlite3Utf8Trans1 (line 52).
pub const utf8_trans1 = [64]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x00, 0x01, 0x02, 0x03, 0x00, 0x01, 0x00, 0x00,
};

pub const native_utf16_little_endian = true;

/// Upstream: WRITE_UTF8 and sqlite3AppendOneUtf8Character (lines 64 and 114).
pub fn appendOneUtf8(output: *[4]u8, value: u32) u8 {
    if (value < 0x80) {
        output[0] = @truncate(value);
        return 1;
    }
    if (value < 0x800) {
        output[0] = 0xc0 + @as(u8, @truncate((value >> 6) & 0x1f));
        output[1] = 0x80 + @as(u8, @truncate(value & 0x3f));
        return 2;
    }
    if (value < 0x10000) {
        output[0] = 0xe0 + @as(u8, @truncate((value >> 12) & 0x0f));
        output[1] = 0x80 + @as(u8, @truncate((value >> 6) & 0x3f));
        output[2] = 0x80 + @as(u8, @truncate(value & 0x3f));
        return 3;
    }
    output[0] = 0xf0 + @as(u8, @truncate((value >> 18) & 0x07));
    output[1] = 0x80 + @as(u8, @truncate((value >> 12) & 0x3f));
    output[2] = 0x80 + @as(u8, @truncate((value >> 6) & 0x3f));
    output[3] = 0x80 + @as(u8, @truncate(value & 0x3f));
    return 4;
}

/// Upstream: WRITE_UTF16LE (line 84).
pub fn writeUtf16Le(output: *[4]u8, value: u32) u8 {
    if (value <= 0xffff) {
        output[0] = @truncate(value);
        output[1] = @truncate(value >> 8);
        return 2;
    }
    output[0] = @truncate(((value >> 10) & 0x003f) + (((value -% 0x10000) >> 10) & 0x00c0));
    output[1] = @truncate(0x00d8 + (((value -% 0x10000) >> 18) & 0x03));
    output[2] = @truncate(value);
    output[3] = @truncate(0x00dc + ((value >> 8) & 0x03));
    return 4;
}

/// Upstream: WRITE_UTF16BE (line 96).
pub fn writeUtf16Be(output: *[4]u8, value: u32) u8 {
    if (value <= 0xffff) {
        output[0] = @truncate(value >> 8);
        output[1] = @truncate(value);
        return 2;
    }
    output[0] = @truncate(0x00d8 + (((value -% 0x10000) >> 18) & 0x03));
    output[1] = @truncate(((value >> 10) & 0x003f) + (((value -% 0x10000) >> 10) & 0x00c0));
    output[2] = @truncate(0x00dc + ((value >> 8) & 0x03));
    output[3] = @truncate(value);
    return 4;
}

fn replaceInvalid(value: u32) u32 {
    if (value < 0x80 or
        (value & 0xffff_f800) == 0xd800 or
        (value & 0xffff_fffe) == 0xfffe)
    {
        return 0xfffd;
    }
    return value;
}

pub const ReadResult = struct {
    value: u32,
    length: u32,
};

/// Upstream: sqlite3Utf8Read (line 175). Input must be zero-terminated.
pub fn read(input: [*:0]const u8) ReadResult {
    var length: u32 = 1;
    var value: u32 = input[0];
    if (value >= 0xc0) {
        value = utf8_trans1[value - 0xc0];
        while ((input[length] & 0xc0) == 0x80) : (length += 1) {
            value = (value << 6) +% (input[length] & 0x3f);
        }
        value = replaceInvalid(value);
    }
    return .{ .value = value, .length = length };
}

/// Upstream: READ_UTF8 (line 164), bounded by an explicit terminator.
pub fn readBounded(input: []const u8) ReadResult {
    std.debug.assert(input.len > 0);
    var length: usize = 1;
    var value: u32 = input[0];
    if (value >= 0xc0) {
        value = utf8_trans1[value - 0xc0];
        while (length < input.len and (input[length] & 0xc0) == 0x80) : (length += 1) {
            value = (value << 6) +% (input[length] & 0x3f);
        }
        value = replaceInvalid(value);
    }
    return .{ .value = value, .length = @intCast(length) };
}

/// Upstream: sqlite3Utf8ReadLimited (line 208). No validity replacement.
pub fn readLimited(input: [*]const u8, byte_count: c_int) ReadResult {
    std.debug.assert(byte_count > 0);
    var value: u32 = input[0];
    var index: c_int = 1;
    if (value >= 0xc0) {
        value = utf8_trans1[value - 0xc0];
        const limit = @min(byte_count, 4);
        while (index < limit and (input[@intCast(index)] & 0xc0) == 0x80) : (index += 1) {
            value = (value << 6) +% (input[@intCast(index)] & 0x3f);
        }
    }
    return .{ .value = value, .length = @intCast(index) };
}

/// Upstream: SQLITE_SKIP_UTF8 (src/sqliteInt.h line 4624).
pub fn skip(input: [*:0]const u8) u32 {
    var length: u32 = 1;
    if (input[0] >= 0xc0) {
        while ((input[length] & 0xc0) == 0x80) length += 1;
    }
    return length;
}

/// Upstream: sqlite3Utf8CharLen (line 475).
pub fn characterCount(input: [*:0]const u8, byte_count: c_int) c_int {
    var result: c_int = 0;
    var index: u32 = 0;
    const bounded = byte_count >= 0;
    const limit: u32 = if (bounded) @intCast(byte_count) else std.math.maxInt(u32);
    while (input[index] != 0 and index < limit) {
        index += skip(input + index);
        result += 1;
    }
    return result;
}

/// Upstream: sqlite3Utf16ByteLen (line 551), for the initial little-endian
/// target's native UTF-16 representation.
pub fn utf16ByteLength(input: [*]const u8, byte_count: c_int, character_count: c_int) c_int {
    std.debug.assert(character_count >= 0);
    if (byte_count <= 0) return 0;
    var high_byte_index: usize = 1;
    const end_index: usize = @intCast(byte_count - 1);
    var characters: c_int = 0;
    while (characters < character_count and high_byte_index <= end_index) : (characters += 1) {
        const high = input[high_byte_index];
        high_byte_index += 2;
        if (high >= 0xd8 and high < 0xdc and high_byte_index <= end_index and
            input[high_byte_index] >= 0xdc and input[high_byte_index] < 0xe0)
        {
            high_byte_index += 2;
        }
    }
    return @intCast(high_byte_index - 1);
}

test "UTF-8 encoding boundaries" {
    const cases = [_]struct { u32, []const u8 }{
        .{ 0, &.{0} },
        .{ 0x7f, &.{0x7f} },
        .{ 0x80, &.{ 0xc2, 0x80 } },
        .{ 0x7ff, &.{ 0xdf, 0xbf } },
        .{ 0x800, &.{ 0xe0, 0xa0, 0x80 } },
        .{ 0xffff, &.{ 0xef, 0xbf, 0xbf } },
        .{ 0x10000, &.{ 0xf0, 0x90, 0x80, 0x80 } },
        .{ 0x10ffff, &.{ 0xf4, 0x8f, 0xbf, 0xbf } },
    };
    for (cases) |case| {
        var output: [4]u8 = undefined;
        const length = appendOneUtf8(&output, case[0]);
        try std.testing.expectEqualSlices(u8, case[1], output[0..length]);
    }
}

test "UTF-8 read preserves SQLite malformed-input behavior" {
    const continuation = [_:0]u8{0x80};
    try std.testing.expectEqual(ReadResult{ .value = 0x80, .length = 1 }, read(&continuation));
    const overlong_ascii = [_:0]u8{ 0xc1, 0x81 };
    try std.testing.expectEqual(ReadResult{ .value = 0xfffd, .length = 2 }, read(&overlong_ascii));
    const overlong_non_ascii = [_:0]u8{ 0xe0, 0x82, 0x80 };
    try std.testing.expectEqual(ReadResult{ .value = 0x80, .length = 3 }, read(&overlong_non_ascii));
    const surrogate = [_:0]u8{ 0xed, 0xa0, 0x80 };
    try std.testing.expectEqual(ReadResult{ .value = 0xfffd, .length = 3 }, read(&surrogate));
    const noncharacter = [_:0]u8{ 0xef, 0xbf, 0xbe };
    try std.testing.expectEqual(ReadResult{ .value = 0xfffd, .length = 3 }, read(&noncharacter));
}

test "bounded and limited readers differ on replacement" {
    const malformed = [_]u8{ 0xc1, 0x81, 0xaa, 0xaa };
    try std.testing.expectEqual(ReadResult{ .value = 0xfffd, .length = 2 }, readBounded(malformed[0..2]));
    try std.testing.expectEqual(ReadResult{ .value = 268_970, .length = 4 }, readLimited(&malformed, 4));
    try std.testing.expectEqual(ReadResult{ .value = 1, .length = 1 }, readLimited(&malformed, 1));
}

test "UTF-16 writers preserve byte order and surrogate pairs" {
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 2), writeUtf16Le(&output, 0x20ac));
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x20 }, output[0..2]);
    try std.testing.expectEqual(@as(u8, 2), writeUtf16Be(&output, 0x20ac));
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0xac }, output[0..2]);
    try std.testing.expectEqual(@as(u8, 4), writeUtf16Le(&output, 0x1f600));
    try std.testing.expectEqualSlices(u8, &.{ 0x3d, 0xd8, 0x00, 0xde }, &output);
    try std.testing.expectEqual(@as(u8, 4), writeUtf16Be(&output, 0x1f600));
    try std.testing.expectEqualSlices(u8, &.{ 0xd8, 0x3d, 0xde, 0x00 }, &output);
}

test "character and native UTF-16 byte counts" {
    const utf8 = [_:0]u8{ 'a', 0xe2, 0x82, 0xac, 'b' };
    try std.testing.expectEqual(@as(c_int, 3), characterCount(&utf8, -1));
    try std.testing.expectEqual(@as(c_int, 2), characterCount(&utf8, 2));
    try std.testing.expectEqual(@as(c_int, 0), characterCount(&utf8, 0));

    const utf16le = [_]u8{ 0x61, 0, 0x3d, 0xd8, 0, 0xde, 0x62, 0 };
    try std.testing.expectEqual(@as(c_int, 2), utf16ByteLength(&utf16le, utf16le.len, 1));
    try std.testing.expectEqual(@as(c_int, 6), utf16ByteLength(&utf16le, utf16le.len, 2));
    try std.testing.expectEqual(@as(c_int, 8), utf16ByteLength(&utf16le, utf16le.len, 3));
}
