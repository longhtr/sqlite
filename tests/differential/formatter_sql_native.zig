const std = @import("std");
const root = @import("formatter_sql");
const formatter = root.formatter;
const mem = root.vdbe_mem;

fn show(id: usize, accumulator: *formatter.Accumulator, arguments: *mem.PrintfArguments) void {
    _ = formatter.strValue(accumulator);
    std.debug.print("{d}\t{d}\t{d}\t", .{ id, accumulator.accError, arguments.nUsed });
    for (accumulator.zText.?[0..accumulator.nChar]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}
fn initAccumulator(accumulator: *formatter.Accumulator, base: *[256]u8) void {
    formatter.strAccumInit(accumulator, null, base, base.len, 0);
    accumulator.printfFlags |= formatter.printf_sql_function;
}

pub fn main() !void {
    if (root.public_api.sqlite3_initialize() != 0) return error.InitializeFailed;
    defer _ = root.public_api.sqlite3_shutdown();
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    if (manager.start() != formatter.memory.ok) return error.InitializeFailed;
    defer manager.stop();
    var cells: [7]mem.types.Mem = undefined;
    for (&cells) |*cell| mem.init(cell, null, mem.types.mem_flag.null_);
    defer for (&cells) |*cell| mem.release(cell);
    mem.setInt64(&cells[0], -42);
    mem.setDouble(&cells[1], 1.25);
    _ = mem.setStr(&cells[2], "a'b", -1, 1, .static);
    _ = mem.setStr(&cells[3], "éx", -1, 1, .static);
    _ = mem.setStr(&cells[4], "dyn", -1, 1, .static);
    mem.setInt64(&cells[5], 5);
    mem.setInt64(&cells[6], 9);
    var pointers: [7]?*mem.types.Mem = undefined;
    for (&pointers, &cells) |*pointer, *cell| pointer.* = cell;
    var arguments = mem.PrintfArguments{ .nArg = 7, .nUsed = 0, .apArg = &pointers };
    var accumulator: formatter.Accumulator = undefined;
    var base: [256]u8 = undefined;
    var scratch: [128]formatter.FormatArgument = undefined;
    initAccumulator(&accumulator, &base);
    try root.formatter_sql.append(&accumulator, &manager, "%08d|%.2f|%Q|%.2c|%z|%n|%*d", &arguments, &scratch);
    show(1, &accumulator, &arguments);

    arguments.nArg = 0;
    arguments.nUsed = 0;
    initAccumulator(&accumulator, &base);
    try root.formatter_sql.append(&accumulator, &manager, "%d|%f|%s|%Q|%c", &arguments, &scratch);
    show(2, &accumulator, &arguments);

    _ = mem.setStr(&cells[0], "42", -1, 1, .static);
    _ = mem.setStr(&cells[1], "1.5", -1, 1, .static);
    mem.setInt64(&cells[2], 99);
    arguments.nArg = 3;
    arguments.nUsed = 0;
    initAccumulator(&accumulator, &base);
    try root.formatter_sql.append(&accumulator, &manager, "%d|%.1f|%s", &arguments, &scratch);
    show(3, &accumulator, &arguments);

    _ = mem.setStr(&cells[0], "borrowed", -1, 1, .static);
    mem.setInt64(&cells[1], 7);
    arguments.nArg = 2;
    arguments.nUsed = 0;
    initAccumulator(&accumulator, &base);
    try root.formatter_sql.append(&accumulator, &manager, "%z|%n|%d", &arguments, &scratch);
    show(4, &accumulator, &arguments);

    mem.setInt64(&cells[0], -6);
    mem.setInt64(&cells[1], 3);
    mem.setInt64(&cells[2], 12);
    arguments.nArg = 3;
    arguments.nUsed = 0;
    initAccumulator(&accumulator, &base);
    try root.formatter_sql.append(&accumulator, &manager, "%*.*d", &arguments, &scratch);
    show(5, &accumulator, &arguments);

    var output: mem.types.Mem = undefined;
    mem.init(&output, null, mem.types.mem_flag.null_);
    var context = mem.types.Context{
        .pOut = &output,
        .pFunc = null,
        .pMem = null,
        .pVdbe = null,
        .iOp = 0,
        .isError = 0,
        .enc = 1,
        .skipFlag = 0,
        .argc = 0,
        .argv = .{},
    };
    formatter.strAccumInit(&accumulator, null, &base, 8, 0);
    root.formatter_sql.resultAccumulator(&context, &accumulator);
    std.debug.print("6\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ context.isError, output.flags, output.n, accumulator.nChar, @intFromBool(accumulator.zText == null) });
    mem.release(&output);
    mem.init(&output, null, mem.types.mem_flag.null_);
    context.pOut = &output;
    context.isError = 0;
    formatter.strAccumInit(&accumulator, null, null, 0, 128);
    formatter.strAppendAll(&accumulator, &formatter.memory.process_manager, "hello");
    root.formatter_sql.resultAccumulator(&context, &accumulator);
    std.debug.print("7\t{d}\t{d}\t{d}\t", .{ context.isError, output.flags, output.n });
    for (output.z.?[0..@intCast(output.n)]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
    mem.release(&output);
    mem.init(&output, null, mem.types.mem_flag.null_);
    context.pOut = &output;
    context.isError = 0;
    formatter.strAccumInit(&accumulator, null, &base, 8, 0);
    formatter.strAppendAll(&accumulator, &formatter.memory.process_manager, "12345678");
    root.formatter_sql.resultAccumulator(&context, &accumulator);
    std.debug.print("8\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ context.isError, output.flags, output.n, accumulator.nChar, @intFromBool(accumulator.zText == null) });
    mem.release(&output);
}
