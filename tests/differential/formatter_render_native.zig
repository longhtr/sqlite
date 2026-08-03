const std = @import("std");
const formatter = @import("formatter");

fn show(id: usize, accumulator: *formatter.Accumulator) void {
    _ = formatter.strValue(accumulator);
    std.debug.print("{d:0>2}\t{d}\t", .{ id, accumulator.accError });
    for (accumulator.zText.?[0..accumulator.nChar]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

fn start(accumulator: *formatter.Accumulator, base: *[512]u8) void {
    formatter.strAccumInit(accumulator, null, base, base.len, 0);
}

pub fn main() !void {
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    if (manager.start() != formatter.memory.ok) return error.InitializeFailed;
    defer manager.stop();
    var accumulator: formatter.Accumulator = undefined;
    var base: [512]u8 = undefined;
    var count: c_int = -1;

    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "plain %% %d %+d % d", &.{ .{ .signed = -12 }, .{ .signed = 7 }, .{ .signed = 7 } });
    show(1, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%08d|%-6u|%,d", &.{ .{ .signed = -42 }, .{ .unsigned = 9 }, .{ .signed = 1_234_567 } });
    show(2, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%#x|%#X|%#o|%p", &.{ .{ .unsigned = 0x2a }, .{ .unsigned = 0x2a }, .{ .unsigned = 9 }, .{ .pointer = 0x1234 } });
    show(3, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%.5d|%10.5d|%r", &.{ .{ .signed = 12 }, .{ .signed = 12 }, .{ .signed = 22 } });
    show(4, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%s|%.3s|%8s|%-8s", &.{ .{ .string = "abcdef" }, .{ .string = "abcdef" }, .{ .string = "xy" }, .{ .string = "xy" } });
    show(5, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%!5.2s", &.{.{ .string = "éx" }});
    show(6, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%c|%.3c|%5c", &.{ .{ .character = 0x20ac }, .{ .character = 0x20ac }, .{ .character = 0x20ac } });
    show(7, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%q|%Q|%w", &.{ .{ .string = "a'b" }, .{ .string = "a'b" }, .{ .string = "a\"b" } });
    show(8, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%#q|%#Q", &.{ .{ .string = "a\\\x01b" }, .{ .string = "a\\\x01b" } });
    show(9, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%10q|%-10Q", &.{ .{ .string = "a'b" }, .{ .string = "a'b" } });
    show(10, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%*.*d|%*d", &.{ .{ .signed = 8 }, .{ .signed = 4 }, .{ .signed = 12 }, .{ .signed = -6 }, .{ .signed = 9 } });
    show(11, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "abc%nXYZ", &.{.{ .count = &count }});
    show(12, &accumulator);
    std.debug.print("COUNT\t{d}\n", .{count});
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%s|%q|%Q", &.{ .{ .string = null }, .{ .string = null }, .{ .string = null } });
    show(13, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "trailing%", &.{});
    show(14, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%Q", &.{.{ .string = "''''''''''''''''''''''''''''''''''''''''" }});
    show(15, &accumulator);

    formatter.strAccumInit(&accumulator, null, null, 0, 128);
    const adopted_allocation = manager.alloc(6) orelse return error.OutOfMemory;
    const adopted: [*:0]u8 = @ptrCast(adopted_allocation);
    std.mem.copyForwards(u8, adopted[0..6], "owned\x00");
    formatter.strAppendFormat(&accumulator, &manager, "%z", &.{.{ .owned_string = adopted }});
    std.debug.print("16\t{d}\t{d}\t{d}\t", .{ accumulator.accError, @intFromBool(accumulator.zText.? == adopted), @intFromBool(formatter.isMalloced(&accumulator)) });
    for (accumulator.zText.?[0..accumulator.nChar]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
    formatter.strReset(&accumulator, &manager);

    start(&accumulator, &base);
    formatter.strAppendAll(&accumulator, &manager, "x");
    const copied_allocation = manager.alloc(6) orelse return error.OutOfMemory;
    const copied: [*:0]u8 = @ptrCast(copied_allocation);
    std.mem.copyForwards(u8, copied[0..6], "owned\x00");
    formatter.strAppendFormat(&accumulator, &manager, "%7z", &.{.{ .owned_string = copied }});
    show(17, &accumulator);

    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%f|%.2f|%+.0f", &.{ .{ .float = 1.25 }, .{ .float = 1.25 }, .{ .float = 1.6 } });
    show(18, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%e|%E|%.3e", &.{ .{ .float = 123.0 }, .{ .float = 0.00123 }, .{ .float = 1.23456 } });
    show(19, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%g|%.3g|%#g|%!g", &.{ .{ .float = 123.45 }, .{ .float = 123.45 }, .{ .float = 123.45 }, .{ .float = 49.47 } });
    show(20, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%010.2f|%-10.2f|%,.2f", &.{ .{ .float = 12.5 }, .{ .float = 12.5 }, .{ .float = 12345.5 } });
    show(21, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%f|%f|%f", &.{ .{ .float = std.math.inf(f64) }, .{ .float = -std.math.inf(f64) }, .{ .float = @bitCast(@as(u64, 0x7ff8000000000001)) } });
    show(22, &accumulator);
    start(&accumulator, &base);
    const negative_zero: f64 = @bitCast(@as(u64, 0x8000000000000000));
    formatter.strAppendFormat(&accumulator, &manager, "%f|%#f|%+f", &.{ .{ .float = negative_zero }, .{ .float = negative_zero }, .{ .float = negative_zero } });
    show(23, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%.17g|%!.17g", &.{ .{ .float = 49.47 }, .{ .float = 49.47 } });
    show(24, &accumulator);
    start(&accumulator, &base);
    formatter.strAppendFormat(&accumulator, &manager, "%*.*f", &.{ .{ .signed = 10 }, .{ .signed = 3 }, .{ .float = 1.25 } });
    show(25, &accumulator);

    var state: u64 = 0xd1b54a32d192ed03;
    for (0..64) |index| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const value: f64 = @bitCast(state);
        const format = switch (index & 7) {
            0 => "%g",
            1 => "%.17g",
            2 => "%!.17g",
            3 => "%.6e",
            4 => "%.4f",
            5 => "%#.0f",
            6 => "%020.6g",
            else => "%,.2f",
        };
        start(&accumulator, &base);
        formatter.strAppendFormat(&accumulator, &manager, format, &.{.{ .float = value }});
        show(100 + index, &accumulator);
    }

    const token = formatter.Token{ .z = "token-bytes", .n = 5 };
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%T", &.{.{ .token = &token }});
    show(200, &accumulator);
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%#T", &.{.{ .expression_token = "expr" }});
    show(201, &accumulator);
    const aliased = formatter.SourceItemFormat{ .alias = "alias", .name = "table", .database = "main" };
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%S", &.{.{ .source_item = aliased }});
    show(202, &accumulator);
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%!S", &.{.{ .source_item = aliased }});
    show(203, &accumulator);
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%S", &.{.{ .source_item = .{ .name = "table", .database = "main" } }});
    show(204, &accumulator);
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%S", &.{.{ .source_item = .{ .is_subquery = true, .nested_from = true, .select_id = 7 } }});
    show(205, &accumulator);
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%S", &.{.{ .source_item = .{ .is_subquery = true, .multi_value = true, .row_count = 3 } }});
    show(206, &accumulator);
    start(&accumulator, &base);
    accumulator.printfFlags |= formatter.printf_internal;
    formatter.strAppendFormat(&accumulator, &manager, "%S", &.{.{ .source_item = .{ .is_subquery = true, .select_id = 9 } }});
    show(207, &accumulator);
}
