const std = @import("std");
pub const vdbe_mem = @import("internal/vdbe_mem.zig");
pub const db_allocator = @import("internal/db_allocator.zig");
pub const btree_aux = @import("internal/btree_aux.zig");
pub const vdbe_aux = @import("internal/vdbe_aux.zig");
pub const vdbe_api = @import("internal/vdbe_api.zig");
pub const vdbe_record = @import("internal/vdbe_record.zig");
pub const walker = @import("internal/walker.zig");
pub const collation = @import("internal/collation.zig");
pub const builtin_functions = @import("internal/builtin_functions.zig");
pub const memory = @import("memory.zig");
pub const public_api = @import("public_api.zig");

test "analyze all active internal VDBE memory declarations" {
    if (!memory.process_manager.started) try std.testing.expectEqual(memory.ok, memory.process_manager.start());
    comptime {
        for (std.meta.declarations(vdbe_mem)) |declaration| {
            _ = @field(vdbe_mem, declaration.name);
        }
        for (std.meta.declarations(vdbe_aux)) |declaration| {
            _ = @field(vdbe_aux, declaration.name);
        }
        for (std.meta.declarations(vdbe_api)) |declaration| {
            _ = @field(vdbe_api, declaration.name);
        }
        for (std.meta.declarations(btree_aux)) |declaration| {
            _ = @field(btree_aux, declaration.name);
        }
        for (std.meta.declarations(vdbe_record)) |declaration| {
            _ = @field(vdbe_record, declaration.name);
        }
        for (std.meta.declarations(walker)) |declaration| {
            _ = @field(walker, declaration.name);
        }
        for (std.meta.declarations(collation)) |declaration| {
            _ = @field(collation, declaration.name);
        }
        for (std.meta.declarations(builtin_functions)) |declaration| {
            _ = @field(builtin_functions, declaration.name);
        }
    }
}

test "PrintfArguments consumes typed Mem values and defaults missing values" {
    var integer: vdbe_mem.types.Mem = undefined;
    var real: vdbe_mem.types.Mem = undefined;
    var text: vdbe_mem.types.Mem = undefined;
    vdbe_mem.init(&integer, null, vdbe_mem.types.mem_flag.null_);
    vdbe_mem.init(&real, null, vdbe_mem.types.mem_flag.null_);
    vdbe_mem.init(&text, null, vdbe_mem.types.mem_flag.null_);
    vdbe_mem.setInt64(&integer, -9_223_372_036_854_775_807);
    vdbe_mem.setDouble(&real, 1.25);
    try std.testing.expectEqual(@as(c_int, 0), vdbe_mem.setStr(&text, "hello", -1, 1, .static));
    var values = [_]?*vdbe_mem.types.Mem{ &integer, &real, &text };
    var arguments = vdbe_mem.PrintfArguments{ .nArg = values.len, .nUsed = 0, .apArg = &values };
    try std.testing.expectEqual(@as(i64, -9_223_372_036_854_775_807), vdbe_mem.getPrintfIntArg(&arguments));
    try std.testing.expectEqual(@as(f64, 1.25), vdbe_mem.getPrintfDoubleArg(&arguments));
    try std.testing.expectEqualStrings("hello", std.mem.span(@as([*:0]u8, @ptrCast(vdbe_mem.getPrintfTextArg(&arguments).?))));
    try std.testing.expectEqual(@as(c_int, 3), arguments.nUsed);
    try std.testing.expectEqual(@as(i64, 0), vdbe_mem.getPrintfIntArg(&arguments));
    try std.testing.expectEqual(@as(f64, 0.0), vdbe_mem.getPrintfDoubleArg(&arguments));
    try std.testing.expect(vdbe_mem.getPrintfTextArg(&arguments) == null);
    try std.testing.expectEqual(@as(c_int, 3), arguments.nUsed);
}
