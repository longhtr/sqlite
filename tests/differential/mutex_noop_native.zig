const std = @import("std");
const mutex = @import("mutex");
pub fn main() void {
    const methods = mutex.noopMethods();
    std.debug.print("1\t{d}\t{d}\t{d}\n", .{ @sizeOf(mutex.MutexMethods), @intFromBool(methods.xMutexHeld == null), @intFromBool(methods.xMutexNotheld == null) });
    std.debug.print("2\t{d}\t{d}\n", .{ methods.xMutexInit.?(), methods.xMutexEnd.?() });
    const first = methods.xMutexAlloc.?(0);
    const second = methods.xMutexAlloc.?(13);
    std.debug.print("3\t{d}\t{d}\n", .{ @intFromPtr(first.?), @intFromBool(first == second) });
    methods.xMutexEnter.?(first);
    std.debug.print("4\t{d}\n", .{methods.xMutexTry.?(first)});
    methods.xMutexLeave.?(first);
    methods.xMutexFree.?(first);
    std.debug.print("5\t{d}\n", .{@intFromBool(methods == mutex.noopMethods())});
}
