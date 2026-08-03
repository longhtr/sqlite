const std = @import("std");
const rowset = @import("rowset");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var set = rowset.RowSet.init(allocator);
    defer set.deinit();
    for ([_]i64{ 9, -3, 9, 2, 1, -3, 20, 2 }) |value| try set.insert(value);
    std.debug.print("1", .{});
    while (set.next()) |value| std.debug.print("\t{d}", .{value});
    std.debug.print("\n2\t{d}\n", .{@intFromBool(set.next() != null)});
    set.deinit();

    set = rowset.RowSet.init(allocator);
    var index: i64 = 99;
    while (index >= 0) : (index -= 1) {
        try set.insert(index);
        try set.insert(index);
    }
    var sum: i64 = 0;
    var count: usize = 0;
    while (set.next()) |value| {
        sum += value;
        count += 1;
    }
    std.debug.print("3\t{d}\t{d}\n", .{ count, sum });
    set.deinit();

    set = rowset.RowSet.init(allocator);
    try set.insert(10);
    try set.insert(20);
    std.debug.print("4\t{d}", .{@intFromBool(try set.testValue(0, 10))});
    std.debug.print("\t{d}", .{@intFromBool(try set.testValue(1, 10))});
    try set.insert(30);
    std.debug.print("\t{d}", .{@intFromBool(try set.testValue(1, 30))});
    std.debug.print("\t{d}", .{@intFromBool(try set.testValue(2, 30))});
    std.debug.print("\t{d}\n", .{@intFromBool(try set.testValue(2, 10))});

    for (0..18) |offset| {
        const value: i64 = @intCast(100 + offset);
        try set.insert(value);
        if (!(try set.testValue(@intCast(3 + offset), value))) return error.FreezeMismatch;
    }
    var hits: usize = 0;
    for (0..18) |offset| hits += @intFromBool(try set.testValue(20, @intCast(100 + offset)));
    std.debug.print("5\t{d}\t{d}\t{d}\n", .{
        hits,
        @intFromBool(try set.testValue(20, 10)),
        @intFromBool(try set.testValue(20, 999)),
    });
    try set.insert(777);
    std.debug.print("6\t{d}\t{d}\n", .{
        @intFromBool(try set.testValue(20, 777)),
        @intFromBool(try set.testValue(21, 777)),
    });
    set.clear();
    try set.insert(-7);
    const value = set.next();
    std.debug.print("7\t{d}\t{d}\t{d}\n", .{
        @intFromBool(value != null),
        value.?,
        @intFromBool(set.next() != null),
    });
}
