const utf = @import("utf");

pub export fn probe_utf8_append(output: [*]u8, value: u32) callconv(.c) u8 {
    const buffer: *[4]u8 = @ptrCast(output);
    return utf.appendOneUtf8(buffer, value);
}

pub export fn probe_utf16le_write(output: [*]u8, value: u32) callconv(.c) u8 {
    const buffer: *[4]u8 = @ptrCast(output);
    return utf.writeUtf16Le(buffer, value);
}

pub export fn probe_utf16be_write(output: [*]u8, value: u32) callconv(.c) u8 {
    const buffer: *[4]u8 = @ptrCast(output);
    return utf.writeUtf16Be(buffer, value);
}

pub export fn probe_utf8_read(input: [*:0]const u8, length: *u32) callconv(.c) u32 {
    const result = utf.read(input);
    length.* = result.length;
    return result.value;
}

pub export fn probe_utf8_read_bounded(
    input: [*]const u8,
    byte_count: u32,
    length: *u32,
) callconv(.c) u32 {
    const result = utf.readBounded(input[0..byte_count]);
    length.* = result.length;
    return result.value;
}

pub export fn probe_utf8_read_limited(
    input: [*]const u8,
    byte_count: c_int,
    length: *u32,
) callconv(.c) u32 {
    const result = utf.readLimited(input, byte_count);
    length.* = result.length;
    return result.value;
}

pub export fn probe_utf8_char_len(input: [*:0]const u8, byte_count: c_int) callconv(.c) c_int {
    return utf.characterCount(input, byte_count);
}

pub export fn probe_utf16_byte_len(
    input: [*]const u8,
    byte_count: c_int,
    character_count: c_int,
) callconv(.c) c_int {
    return utf.utf16ByteLength(input, byte_count, character_count);
}
