const std = @import("std");

var action_calls: c_int = 0;
var allocation_attempt: usize = 0;
var fail_at: ?usize = null;
var outstanding: usize = 0;

pub export fn sqlite_zig_parser_set_fail(index: isize) callconv(.c) void {
    allocation_attempt = 0;
    fail_at = if (index < 0) null else @intCast(index);
}

pub export fn sqlite_zig_parser_malloc(size: usize) callconv(.c) ?*anyopaque {
    defer allocation_attempt += 1;
    if (fail_at != null and fail_at.? == allocation_attempt) return null;
    const pointer = std.c.malloc(size);
    if (pointer != null) outstanding += 1;
    return pointer;
}

pub export fn sqlite_zig_parser_free(pointer: ?*anyopaque) callconv(.c) void {
    if (pointer != null) outstanding -= 1;
    std.c.free(pointer);
}

pub export fn sqlite_zig_parser_outstanding() callconv(.c) usize {
    return outstanding;
}

pub export fn sqlite_zig_parser_add(lhs: c_int, rhs: c_int) callconv(.c) c_int {
    action_calls += 1;
    return lhs + rhs;
}

pub export fn sqlite_zig_parser_action_calls() callconv(.c) c_int {
    return action_calls;
}

extern fn run_parser_probe() callconv(.c) c_int;

pub fn main() !void {
    const rc = run_parser_probe();
    if (rc != 0) {
        std.log.err("Lemon/Zig action probe failed at case {d}", .{rc});
        return error.ParserProbeFailed;
    }
}
