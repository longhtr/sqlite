const std = @import("std");
const fault = @import("benign_fault");

var begins: c_int = 0;
var ends: c_int = 0;
fn onBegin() callconv(.c) void {
    begins += 1;
}
fn onEnd() callconv(.c) void {
    ends += 1;
}
fn alternateBegin() callconv(.c) void {
    begins += 10;
}
fn alternateEnd() callconv(.c) void {
    ends += 20;
}

pub fn main() void {
    fault.configure(null, null);
    std.debug.print("1\t{d}\t{d}\t{d}\n", .{ @sizeOf(fault.Hooks), @intFromBool(fault.process_hooks.begin_callback == null), @intFromBool(fault.process_hooks.end_callback == null) });
    fault.configure(onBegin, onEnd);
    fault.begin();
    fault.begin();
    fault.end();
    std.debug.print("2\t{d}\t{d}\n", .{ begins, ends });
    fault.configure(alternateBegin, alternateEnd);
    fault.begin();
    fault.end();
    std.debug.print("3\t{d}\t{d}\n", .{ begins, ends });
    fault.configure(null, alternateEnd);
    fault.begin();
    fault.end();
    std.debug.print("4\t{d}\t{d}\n", .{ begins, ends });
    fault.configure(null, null);
    fault.begin();
    fault.end();
    std.debug.print("5\t{d}\t{d}\n", .{ begins, ends });
}
