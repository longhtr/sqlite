const std = @import("std");

pub export fn sqlite_zig_variadic_dispatch(
    op: c_int,
    int_arg: c_int,
    ptr_arg: ?*anyopaque,
    i64_arg: i64,
    double_arg: f64,
) callconv(.c) c_int {
    return switch (op) {
        0 => 100,
        1 => if (int_arg == 42) 142 else -101,
        2 => if (ptr_arg != null and int_arg == 7) 207 else -102,
        3 => if (i64_arg == 0x102030405060708 and double_arg == 2.5) 325 else -103,
        else => -104,
    };
}

extern fn run_variadic_probe() callconv(.c) c_int;

pub fn main() !void {
    const rc = run_variadic_probe();
    if (rc != 0) {
        std.log.err("variadic ABI probe failed at case {d}", .{rc});
        return error.VariadicAbiProbeFailed;
    }
}
