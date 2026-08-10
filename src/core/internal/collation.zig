//! Built-in collation implementations from `main.c`.

const std = @import("std");
const sqlite_string = @import("../string.zig");
const types = @import("vdbe_types.zig");

/// Source `binCollFunc()`.
pub fn binary(
    _: ?*anyopaque,
    first_length: c_int,
    first_pointer: ?*const anyopaque,
    second_length: c_int,
    second_pointer: ?*const anyopaque,
) callconv(.c) c_int {
    const compared_length: usize = @intCast(@min(first_length, second_length));
    const first: [*]const u8 = @ptrCast(first_pointer.?);
    const second: [*]const u8 = @ptrCast(second_pointer.?);
    const order = std.mem.order(u8, first[0..compared_length], second[0..compared_length]);
    return switch (order) {
        .lt => -1,
        .gt => 1,
        .eq => first_length - second_length,
    };
}

/// Source `rtrimCollFunc()`.
pub fn rightTrimmed(
    user: ?*anyopaque,
    first_length_initial: c_int,
    first_pointer: ?*const anyopaque,
    second_length_initial: c_int,
    second_pointer: ?*const anyopaque,
) callconv(.c) c_int {
    var first_length = first_length_initial;
    var second_length = second_length_initial;
    const first: [*]const u8 = @ptrCast(first_pointer.?);
    const second: [*]const u8 = @ptrCast(second_pointer.?);
    while (first_length > 0 and first[@intCast(first_length - 1)] == ' ') first_length -= 1;
    while (second_length > 0 and second[@intCast(second_length - 1)] == ' ') second_length -= 1;
    return binary(user, first_length, first_pointer, second_length, second_pointer);
}

/// Source `sqlite3IsBinary()`.
pub fn isBinary(collation: ?*const types.CollSeq) bool {
    return collation == null or collation.?.xCmp == binary;
}

/// Source `nocaseCollatingFunc()`.
pub fn noCase(
    _: ?*anyopaque,
    first_length: c_int,
    first_pointer: ?*const anyopaque,
    second_length: c_int,
    second_pointer: ?*const anyopaque,
) callconv(.c) c_int {
    const compared_length = @min(first_length, second_length);
    const first: [*:0]const u8 = @ptrCast(first_pointer.?);
    const second: [*:0]const u8 = @ptrCast(second_pointer.?);
    const result = sqlite_string.compareN(first, second, compared_length);
    return if (result == 0) first_length - second_length else result;
}
