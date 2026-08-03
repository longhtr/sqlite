const std = @import("std");

const sqlite3_context = opaque {};
const sqlite3_value = opaque {};

extern fn sqlite3_value_int(value: *sqlite3_value) callconv(.c) c_int;
extern fn sqlite3_result_int(context: *sqlite3_context, value: c_int) callconv(.c) void;
extern fn run_hybrid_probe() callconv(.c) c_int;

var randomness_calls: u32 = 0;

pub export fn sqlite_zig_probe_scalar(
    context: *sqlite3_context,
    argc: c_int,
    argv: [*]*sqlite3_value,
) callconv(.c) void {
    if (argc != 1) {
        sqlite3_result_int(context, -1);
        return;
    }
    sqlite3_result_int(context, sqlite3_value_int(argv[0]) + 1);
}

pub export fn sqlite_zig_probe_randomness(buffer: [*]u8, len: c_int) callconv(.c) c_int {
    if (len < 0) return 0;
    const call = randomness_calls;
    randomness_calls += 1;
    for (buffer[0..@intCast(len)], 0..) |*byte, index| {
        byte.* = @truncate(0xa5 +% call +% @as(u32, @intCast(index)));
    }
    return len;
}

pub export fn sqlite_zig_probe_randomness_calls() callconv(.c) u32 {
    return randomness_calls;
}

pub fn main() !void {
    const rc = run_hybrid_probe();
    if (rc != 0) {
        std.log.err("hybrid VFS/callback probe failed at case {d}", .{rc});
        return error.HybridProbeFailed;
    }
}
