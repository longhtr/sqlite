const std = @import("std");
pub const formatter = @import("formatter.zig");
pub const public_api = @import("public_api.zig");
pub const vdbe_mem = @import("internal/vdbe_mem.zig");
pub const formatter_sql = @import("internal/formatter_sql.zig");

test "analyze SQL formatter adapter declarations" {
    comptime {
        for (std.meta.declarations(formatter_sql)) |declaration| {
            _ = @field(formatter_sql, declaration.name);
        }
    }
}

test "StrAccum result transfer preserves errors and dynamic ownership" {
    try std.testing.expectEqual(@as(c_int, 0), public_api.sqlite3_initialize());
    defer _ = public_api.sqlite3_shutdown();
    var output: vdbe_mem.types.Mem = undefined;
    vdbe_mem.init(&output, null, vdbe_mem.types.mem_flag.null_);
    defer vdbe_mem.release(&output);
    var context = vdbe_mem.types.Context{
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
    var base: [8]u8 = undefined;
    var accumulator: formatter.Accumulator = undefined;
    formatter.strAccumInit(&accumulator, null, &base, base.len, 0);
    formatter_sql.resultAccumulator(&context, &accumulator);
    try std.testing.expectEqual(@as(c_int, 0), output.n);
    try std.testing.expect(output.flags & vdbe_mem.types.mem_flag.string != 0);
    vdbe_mem.release(&output);
    vdbe_mem.init(&output, null, vdbe_mem.types.mem_flag.null_);

    formatter.strAccumInit(&accumulator, null, null, 0, 128);
    formatter.strAppend(&accumulator, &formatter.memory.process_manager, "hello");
    const transferred = accumulator.zText.?;
    formatter_sql.resultAccumulator(&context, &accumulator);
    try std.testing.expectEqual(@intFromPtr(transferred), @intFromPtr(output.z.?));
    try std.testing.expectEqualStrings("hello", std.mem.span(@as([*:0]const u8, @ptrCast(vdbe_mem.valueText(&output, 1).?))));
    vdbe_mem.release(&output);
    vdbe_mem.init(&output, null, vdbe_mem.types.mem_flag.null_);

    formatter.strAccumInit(&accumulator, null, &base, base.len, 0);
    formatter.strAppend(&accumulator, &formatter.memory.process_manager, "12345678");
    formatter_sql.resultAccumulator(&context, &accumulator);
    try std.testing.expectEqual(@as(c_int, formatter.too_big), context.isError);
    try std.testing.expectEqual(@as(u32, 0), accumulator.nChar);
    try std.testing.expect(accumulator.zText == null);
}
