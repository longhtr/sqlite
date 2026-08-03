const sqlite_string = @import("sqlite_string");

pub export fn probe_stricmp(
    left: ?[*:0]const u8,
    right: ?[*:0]const u8,
) callconv(.c) c_int {
    return sqlite_string.compare(left, right);
}

pub export fn probe_stricmp_internal(
    left: [*:0]const u8,
    right: [*:0]const u8,
) callconv(.c) c_int {
    return sqlite_string.compareInternal(left, right);
}

pub export fn probe_strnicmp(
    left: ?[*:0]const u8,
    right: ?[*:0]const u8,
    count: c_int,
) callconv(.c) c_int {
    return sqlite_string.compareN(left, right, count);
}

pub export fn probe_strihash(value: ?[*:0]const u8) callconv(.c) u8 {
    return sqlite_string.insensitiveHash(value);
}

pub export fn probe_strlen30(value: ?[*:0]const u8) callconv(.c) c_int {
    return sqlite_string.length30(value);
}

pub export fn probe_strlen30_nn(value: [*:0]const u8) callconv(.c) c_int {
    return sqlite_string.length30NonNull(value);
}
