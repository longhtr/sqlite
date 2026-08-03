const std = @import("std");
const caller = @import("caller");
const formatter = caller.formatter;
const public_api = caller.public_api;

fn hexLine(id: usize, text: [*:0]const u8) void {
    const bytes = std.mem.span(text);
    std.debug.print("{d}\t{d}\t", .{ id, bytes.len });
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}
fn logCallback(_: ?*anyopaque, code: c_int, message: [*:0]const u8) callconv(.c) void {
    std.debug.print("8\t{d}\t", .{code});
    for (std.mem.span(message)) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}
pub fn main() !void {
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    if (manager.start() != formatter.memory.ok) return error.InitializeFailed;
    defer manager.stop();
    var text = formatter.allocFormat(&manager, 1_000_000_000, 0, "%d|%Q|%.2f", &.{ .{ .signed = 7 }, .{ .string = "a'b" }, .{ .float = 1.25 } }) orelse return error.OutOfMemory;
    hexLine(1, text);
    manager.free(text);
    text = formatter.allocFormat(&manager, 1_000_000_000, 0, "", &.{}) orelse return error.OutOfMemory;
    hexLine(2, text);
    manager.free(text);
    text = formatter.allocFormat(&manager, 1_000_000_000, 0, "%#q", &.{.{ .string = "a\\\x01b" }}) orelse return error.OutOfMemory;
    hexLine(3, text);
    manager.free(text);
    var buffer: [16]u8 = undefined;
    @memset(&buffer, 0x7f);
    _ = formatter.fixedFormat(&manager, buffer[0..8], "abcdefghi", &.{});
    hexLine(4, @ptrCast(&buffer));
    @memset(&buffer, 0x7f);
    _ = formatter.fixedFormat(&manager, buffer[0..1], "x", &.{});
    hexLine(5, @ptrCast(&buffer));
    @memset(&buffer, 0x7f);
    _ = formatter.fixedFormat(&manager, buffer[0..0], "x", &.{});
    std.debug.print("6\t1\t{x:0>2}\n", .{buffer[0]});
    const token = formatter.Token{ .z = "token-bytes", .n = 5 };
    text = formatter.allocFormat(&manager, 1_000_000_000, formatter.printf_internal, "%T", &.{.{ .token = &token }}) orelse return error.OutOfMemory;
    hexLine(7, text);
    manager.free(text);
    _ = public_api.zig_sqlite3_config_log(logCallback, null);
    defer _ = public_api.sqlite3_shutdown();
    public_api.logFormat(17, "error %d", &.{.{ .signed = 9 }});
}
