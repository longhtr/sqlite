const std = @import("std");
const root = @import("vdbe_mem");
const mem = root.vdbe_mem;

pub fn main() !void {
    std.debug.print("LAYOUT\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @sizeOf(mem.PrintfArguments),
        @alignOf(mem.PrintfArguments),
        @offsetOf(mem.PrintfArguments, "nArg"),
        @offsetOf(mem.PrintfArguments, "nUsed"),
        @offsetOf(mem.PrintfArguments, "apArg"),
    });
    var integer: mem.types.Mem = undefined;
    var real: mem.types.Mem = undefined;
    var text: mem.types.Mem = undefined;
    mem.init(&integer, null, mem.types.mem_flag.null_);
    mem.init(&real, null, mem.types.mem_flag.null_);
    mem.init(&text, null, mem.types.mem_flag.null_);
    mem.setInt64(&integer, -9_223_372_036_854_775_807);
    mem.setDouble(&real, 1.25);
    if (mem.setStr(&text, "hello", -1, 1, .static) != 0) return error.SetTextFailed;
    var values = [_]?*mem.types.Mem{ &integer, &real, &text };
    var arguments = mem.PrintfArguments{ .nArg = values.len, .nUsed = 0, .apArg = &values };
    const int_value = mem.getPrintfIntArg(&arguments);
    std.debug.print("INT\t{d}\t{d}\n", .{ int_value, arguments.nUsed });
    const double_value = mem.getPrintfDoubleArg(&arguments);
    std.debug.print("DOUBLE\t{x:0>16}\t{d}\n", .{ @as(u64, @bitCast(double_value)), arguments.nUsed });
    const text_value = mem.getPrintfTextArg(&arguments);
    std.debug.print("TEXT\t{s}\t{d}\n", .{ std.mem.span(@as([*:0]u8, @ptrCast(text_value.?))), arguments.nUsed });
    const empty_integer = mem.getPrintfIntArg(&arguments);
    std.debug.print("EMPTY-INT\t{d}\t{d}\n", .{ empty_integer, arguments.nUsed });
    const empty_double = mem.getPrintfDoubleArg(&arguments);
    std.debug.print("EMPTY-DOUBLE\t{x:0>16}\t{d}\n", .{ @as(u64, @bitCast(empty_double)), arguments.nUsed });
    const empty_text = mem.getPrintfTextArg(&arguments);
    std.debug.print("EMPTY-TEXT\t{s}\t{d}\n", .{ if (empty_text == null) "NULL" else "VALUE", arguments.nUsed });
    std.debug.print("FINAL\t{d}\n", .{arguments.nUsed});
}
