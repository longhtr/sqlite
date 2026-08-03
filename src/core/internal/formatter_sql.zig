//! Adapter from exact Mem-backed PrintfArguments to the Zig-native formatter.

const std = @import("std");
const formatter = @import("../formatter.zig");
const vdbe_mem = @import("vdbe_mem.zig");

pub const Error = error{ScratchTooSmall};

fn push(scratch: []formatter.FormatArgument, used: *usize, argument: formatter.FormatArgument) Error!void {
    if (used.* >= scratch.len) return error.ScratchTooSmall;
    scratch[used.*] = argument;
    used.* += 1;
}

fn textArgument(arguments: *vdbe_mem.PrintfArguments) ?[]const u8 {
    const pointer = vdbe_mem.getPrintfTextArg(arguments) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(pointer)));
}

/// Adapt SQLITE_PRINTF_SQLFUNC argument semantics and append the result.
/// `scratch` must hold one entry per `*`, conversion, and `%n` in `format`.
/// Upstream: sqlite3ResultStrAccum(). Dynamic accumulator text transfers to
/// the result Mem; fixed/empty and error paths reset the accumulator.
pub fn resultAccumulator(context: *vdbe_mem.types.Context, accumulator: *formatter.Accumulator) void {
    if (accumulator.accError != 0) {
        vdbe_mem.resultErrorCode(context, accumulator.accError);
        formatter.strReset(accumulator, &formatter.memory.process_manager);
    } else if (formatter.isMalloced(accumulator)) {
        vdbe_mem.resultText(context, accumulator.zText, @intCast(accumulator.nChar), .dynamic);
    } else {
        vdbe_mem.resultText(context, "", 0, .static);
        formatter.strReset(accumulator, &formatter.memory.process_manager);
    }
}

pub fn append(
    accumulator: *formatter.Accumulator,
    manager: *formatter.memory.Manager,
    format: []const u8,
    arguments: *vdbe_mem.PrintfArguments,
    scratch: []formatter.FormatArgument,
) Error!void {
    var position: usize = 0;
    var used: usize = 0;
    while (position < format.len) {
        const percent = std.mem.indexOfScalarPos(u8, format, position, '%') orelse break;
        position = percent + 1;
        if (position >= format.len) break;
        while (position < format.len) : (position += 1) switch (format[position]) {
            '-', '+', ' ', '#', '!', '0', ',' => {},
            else => break,
        };
        if (position < format.len and format[position] == '*') {
            try push(scratch, &used, .{ .signed = vdbe_mem.getPrintfIntArg(arguments) });
            position += 1;
        } else while (position < format.len and std.ascii.isDigit(format[position])) : (position += 1) {}
        if (position < format.len and format[position] == '.') {
            position += 1;
            if (position < format.len and format[position] == '*') {
                try push(scratch, &used, .{ .signed = vdbe_mem.getPrintfIntArg(arguments) });
                position += 1;
            } else while (position < format.len and std.ascii.isDigit(format[position])) : (position += 1) {}
        }
        if (position < format.len and format[position] == 'l') {
            position += 1;
            if (position < format.len and format[position] == 'l') position += 1;
        }
        if (position >= format.len) break;
        const conversion = formatter.lookup(format[position]).conversion_type;
        position += 1;
        switch (conversion) {
            formatter.et_decimal, formatter.et_ordinal => try push(scratch, &used, .{ .signed = vdbe_mem.getPrintfIntArg(arguments) }),
            formatter.et_radix, formatter.et_pointer => try push(scratch, &used, .{ .unsigned = @bitCast(vdbe_mem.getPrintfIntArg(arguments)) }),
            formatter.et_float, formatter.et_exp, formatter.et_generic => try push(scratch, &used, .{ .float = vdbe_mem.getPrintfDoubleArg(arguments) }),
            formatter.et_string, formatter.et_escape_q, formatter.et_escape_Q, formatter.et_escape_w => try push(scratch, &used, .{ .string = textArgument(arguments) }),
            formatter.et_dynstring => try push(scratch, &used, .{ .borrowed_dynamic_string = textArgument(arguments) }),
            formatter.et_charx => try push(scratch, &used, .{ .character_text = textArgument(arguments) }),
            formatter.et_size => try push(scratch, &used, .ignored_count),
            formatter.et_percent => {},
            else => break,
        }
    }
    formatter.strAppendFormat(accumulator, manager, format, scratch[0..used]);
}

test "Mem-backed SQL formatter adapts typed values and consumption" {
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    try std.testing.expectEqual(formatter.memory.ok, manager.start());
    defer manager.stop();
    var cells: [7]vdbe_mem.types.Mem = undefined;
    for (&cells) |*cell| vdbe_mem.init(cell, null, vdbe_mem.types.mem_flag.null_);
    vdbe_mem.setInt64(&cells[0], -42);
    vdbe_mem.setDouble(&cells[1], 1.25);
    try std.testing.expectEqual(@as(c_int, 0), vdbe_mem.setStr(&cells[2], "a'b", -1, 1, .static));
    try std.testing.expectEqual(@as(c_int, 0), vdbe_mem.setStr(&cells[3], "éx", -1, 1, .static));
    try std.testing.expectEqual(@as(c_int, 0), vdbe_mem.setStr(&cells[4], "dyn", -1, 1, .static));
    vdbe_mem.setInt64(&cells[5], 5);
    vdbe_mem.setInt64(&cells[6], 9);
    var pointers: [7]?*vdbe_mem.types.Mem = undefined;
    for (&pointers, &cells) |*pointer, *cell| pointer.* = cell;
    var arguments = vdbe_mem.PrintfArguments{ .nArg = pointers.len, .nUsed = 0, .apArg = &pointers };
    var base: [128]u8 = undefined;
    var accumulator: formatter.Accumulator = undefined;
    formatter.strAccumInit(&accumulator, null, &base, base.len, 0);
    var scratch: [16]formatter.FormatArgument = undefined;
    try append(&accumulator, &manager, "%08d|%.2f|%Q|%.2c|%z|%n|%*d", &arguments, &scratch);
    try std.testing.expectEqualStrings("-0000042|1.25|'a''b'|éé|dyn||    9", std.mem.span(formatter.strValue(&accumulator).?));
    try std.testing.expectEqual(@as(c_int, 7), arguments.nUsed);
}
