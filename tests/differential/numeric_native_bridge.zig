const numeric = @import("numeric");
const sqlite_float = @import("sqlite_float");
pub export fn probe_atoi64(p: [*]const u8, n: c_int, out: *i64, enc: c_int) callconv(.c) c_int {
    const e: numeric.TextEncoding = @enumFromInt(@as(u8, @intCast(enc)));
    const r = numeric.parseI64(p[0..@intCast(n)], e);
    out.* = r.value;
    return r.code;
}
pub export fn probe_dec_or_hex(p: [*:0]const u8, out: *i64) callconv(.c) c_int {
    const r = numeric.parseDecimalOrHex(p);
    out.* = r.value;
    return r.code;
}
pub export fn probe_get_int32(p: [*:0]const u8, out: *i32) callconv(.c) c_int {
    const r = numeric.getInt32(p);
    if (r.valid) out.* = r.value;
    return @intFromBool(r.valid);
}
pub export fn probe_atoi(p: [*:0]const u8) callconv(.c) i32 {
    return numeric.atoi(p);
}
pub export fn probe_get_uint32(p: [*:0]const u8, out: *u32) callconv(.c) c_int {
    const r = numeric.getUInt32(p);
    out.* = r.value;
    return @intFromBool(r.valid);
}

pub export fn probe_atof(p: [*:0]const u8, out: *f64) callconv(.c) c_int {
    const result = sqlite_float.parse(p);
    out.* = result.value;
    return result.code;
}

pub export fn probe_format_i64(value: i64, output: [*]u8) callconv(.c) c_int {
    const buffer: *[21]u8 = @ptrCast(output);
    const text = numeric.formatI64(buffer, value);
    output[text.len] = 0;
    return @intCast(text.len);
}
