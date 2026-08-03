const std = @import("std");
const math = @import("checked_math");

fn op(id: *usize, kind: u8, initial: i64, operand: i64) void {
    var value = initial;
    const rc = switch (kind) {
        'A' => math.add(&value, operand),
        'S' => math.subtract(&value, operand),
        else => math.multiply(&value, operand),
    };
    std.debug.print("{d}\t{c}\t{d}\t{d}\t{d}\t{d}\n", .{ id.*, kind, initial, operand, rc, value });
    id.* += 1;
}
pub fn main() void {
    var id: usize = 0;
    op(&id, 'A', 1, 2);
    op(&id, 'A', std.math.maxInt(i64), 1);
    op(&id, 'A', std.math.minInt(i64), -1);
    op(&id, 'A', -5, 9);
    op(&id, 'S', 5, 9);
    op(&id, 'S', std.math.minInt(i64), 1);
    op(&id, 'S', 0, std.math.minInt(i64));
    op(&id, 'S', -1, std.math.minInt(i64));
    op(&id, 'M', 7, -3);
    op(&id, 'M', std.math.maxInt(i64), 2);
    op(&id, 'M', std.math.minInt(i64), -1);
    op(&id, 'M', 0, std.math.minInt(i64));
    for ([_]i32{ 0, -1, -2_147_483_647, std.math.minInt(i32) }) |value| {
        std.debug.print("{d}\tX\t{d}\n", .{ id, math.absInt32(value) });
        id += 1;
    }
    for ([_]u64{ 0, 0x3ff0_0000_0000_0000, 0x7fef_ffff_ffff_ffff, 0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, 0x7ff8_0000_0000_0001 }) |bits| {
        const value: f64 = @bitCast(bits);
        std.debug.print("{d}\tF\t{d}\t{d}\n", .{ id, @intFromBool(math.isNan(value)), @intFromBool(math.isOverflow(value)) });
        id += 1;
    }
}
