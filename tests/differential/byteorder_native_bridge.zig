const byteorder = @import("byteorder");

pub export fn probe_get4byte(input: [*]const u8) callconv(.c) u32 {
    const bytes: *const [4]u8 = @ptrCast(input);
    return byteorder.readU32(bytes);
}

pub export fn probe_put4byte(output: [*]u8, value: u32) callconv(.c) void {
    const bytes: *[4]u8 = @ptrCast(output);
    byteorder.writeU32(bytes, value);
}
