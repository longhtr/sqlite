const std = @import("std");
const vlist = @import("vlist");

pub fn main() !void {
    var list = vlist.VList.init(std.heap.c_allocator);
    defer list.deinit();
    std.debug.print("1\t{d}\t{d}\n", .{ list.nameToNumber("x"), @intFromBool(list.numberToName(1) == null) });
    try list.add("a", 1);
    std.debug.print("2\t{d}\t{d}\n", .{ list.allocatedSlots(), list.usedSlots() });
    try list.add("longname", 7);
    std.debug.print("3\t{d}\t{d}\n", .{ list.allocatedSlots(), list.usedSlots() });
    std.debug.print("4\t{d}\t{d}\n", .{ list.nameToNumber("a"), list.nameToNumber("longname") });
    try list.add("third-long-name", 9);
    std.debug.print("5\t{d}\t{d}\n", .{ list.allocatedSlots(), list.usedSlots() });
    std.debug.print("6\t{s}\n", .{std.mem.span(list.numberToName(9).?)});
    std.debug.print("7\t{d}\t{d}\n", .{ list.nameToNumber("missing"), @intFromBool(list.numberToName(99) == null) });
    std.debug.print("8\t{d}\n", .{list.nameToNumber("long")});
}
