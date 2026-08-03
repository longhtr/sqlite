const std = @import("std");
const formatter = @import("formatter");

fn show(id: usize, value: *formatter.Accumulator) void {
    const text = formatter.strValue(value);
    std.debug.print("{d}\t{d}\t{d}\t", .{ id, formatter.strErrorCode(value), formatter.strLength(value) });
    if (text) |bytes| {
        for (bytes[0..value.nChar]) |byte| std.debug.print("{x:0>2}", .{byte});
    } else std.debug.print("NULL", .{});
    std.debug.print("\n", .{});
}
pub fn main() !void {
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    if (manager.start() != formatter.memory.ok) return error.InitializeFailed;
    defer manager.stop();
    var value = formatter.stringObjectNew(&manager, null, 1_000_000_000);
    show(1, value);
    formatter.strAppendAll(value, &manager, "hello");
    show(2, value);
    var text = formatter.stringObjectFinish(&manager, value);
    std.debug.print("3\t{d}\t", .{@intFromBool(text != null)});
    if (text) |bytes| {
        for (std.mem.span(bytes)) |byte| std.debug.print("{x:0>2}", .{byte});
        manager.free(bytes);
    }
    std.debug.print("\n", .{});
    value = formatter.stringObjectNew(&manager, null, 30);
    formatter.strAppendAll(value, &manager, "1234567890123456789012345678901");
    show(4, value);
    text = formatter.stringObjectFinish(&manager, value);
    std.debug.print("5\t{d}\n", .{@intFromBool(text == null)});
    if (text) |bytes| manager.free(bytes);
    value = formatter.stringObjectNew(&manager, null, 1_000_000_000);
    formatter.strAppendAll(value, &manager, "discard");
    formatter.stringObjectFree(&manager, value);
}
