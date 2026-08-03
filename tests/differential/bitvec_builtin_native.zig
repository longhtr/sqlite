const std = @import("std");
const bitvec = @import("bitvec");

pub fn main() void {
    var entropy: [44]u8 = undefined;
    for (&entropy, 0..) |*byte, index| byte.* = @intCast(index);
    var random_state = bitvec.sqlite_random.State{};
    random_state.initialize(&entropy);
    var sequential = [_]i32{ 1, 5, 1, 2, 2, 2, 1, 4, 0 };
    var rc = bitvec.builtinTest(std.heap.c_allocator, 100, &sequential, &random_state, &entropy);
    std.debug.print("1\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ rc, sequential[1], sequential[2], sequential[5], sequential[6] });
    var fault = [_]i32{ 5, 1, 7, 1, 0 };
    rc = bitvec.builtinTest(std.heap.c_allocator, 100, &fault, &random_state, &entropy);
    std.debug.print("2\t{d}\n", .{rc});
    var random_program = [_]i32{ 3, 20, 4, 7, 0 };
    rc = bitvec.builtinTest(std.heap.c_allocator, 1000, &random_program, &random_state, &entropy);
    std.debug.print("3\t{d}\t{d}\t{d}\t{d}\n", .{ rc, random_program[1], random_program[3], random_state.remaining });
    var negative = [_]i32{ 1, 4, 1, 3, 0 };
    rc = bitvec.builtinTest(std.heap.c_allocator, -100, &negative, &random_state, &entropy);
    std.debug.print("4\t{d}\n", .{rc});
}
