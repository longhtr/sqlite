const varint = @import("varint");

pub export fn probe_varint_put(output: [*]u8, value: u64) callconv(.c) u8 {
    return varint.put(output, value);
}

pub export fn probe_varint_get(input: [*]const u8, value: *u64) callconv(.c) u8 {
    const decoded = varint.get(input);
    value.* = decoded.value;
    return decoded.length;
}

pub export fn probe_varint_get32(input: [*]const u8, value: *u32) callconv(.c) u8 {
    const decoded = varint.get32(input);
    value.* = decoded.value;
    return decoded.length;
}

pub export fn probe_varint_get32_nr(input: [*]const u8) callconv(.c) u32 {
    return varint.get32NoResultLength(input);
}

pub export fn probe_varint_put32(output: [*]u8, value: u32) callconv(.c) u8 {
    return varint.put32(output, value);
}

pub export fn probe_varint_length(value: u64) callconv(.c) u8 {
    return varint.length(value);
}
