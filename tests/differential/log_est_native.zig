const std = @import("std");
const log_est = @import("log_est");

pub fn main() void {
    const integers = [_]u64{ 0, 1, 2, 3, 7, 8, 15, 16, 255, 256, 2_000_000_000, std.math.maxInt(u64) };
    const additions = [_][2]log_est.LogEst{ .{ 0, 0 }, .{ 100, 100 }, .{ 100, 99 }, .{ 100, 69 }, .{ 100, 68 }, .{ 100, 40 } };
    const doubles = [_]f64{ 0.5, 1.0, 3.5, 2_000_000_001.0, 1.0e100 };
    const estimates = [_]log_est.LogEst{ 0, 10, 33, 100, 609, 610 };
    var id: usize = 0;
    for (integers) |value| {
        std.debug.print("{d}\tI\t{d}\t{d}\n", .{ id, value, log_est.fromInt(value) });
        id += 1;
    }
    for (additions) |values| {
        std.debug.print("{d}\tA\t{d}\t{d}\t{d}\n", .{ id, values[0], values[1], log_est.add(values[0], values[1]) });
        id += 1;
    }
    for (doubles) |value| {
        std.debug.print("{d}\tD\t{d}\n", .{ id, log_est.fromDouble(value) });
        id += 1;
    }
    for (estimates) |value| {
        std.debug.print("{d}\tT\t{d}\t{d}\n", .{ id, value, log_est.toInt(value) });
        id += 1;
    }
}
