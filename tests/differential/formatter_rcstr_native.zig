const std = @import("std");
const formatter = @import("formatter");

fn header(text: [*]u8) *formatter.ReferenceCountedStringHeader {
    return @ptrCast(@alignCast(text - @sizeOf(formatter.ReferenceCountedStringHeader)));
}

fn dump(name: []const u8, manager: *formatter.memory.Manager, text: [*]u8, length: usize) void {
    const value = header(text);
    std.debug.print("{s}\t{d}\t{d}\t", .{ name, manager.size(value), value.nRCRef });
    for (text[0..length]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    if (manager.start() != formatter.memory.ok) return error.InitializeFailed;
    defer manager.stop();
    std.debug.print("LAYOUT\t{d}\t{d}\t{d}\n", .{
        @sizeOf(formatter.ReferenceCountedStringHeader),
        @alignOf(formatter.ReferenceCountedStringHeader),
        @offsetOf(formatter.ReferenceCountedStringHeader, "nRCRef"),
    });
    var text = formatter.rcStrNew(&manager, 5) orelse return error.OutOfMemory;
    std.mem.copyForwards(u8, text[0..6], "abcde\x00");
    dump("new", &manager, text, 5);
    const same_one = formatter.rcStrRef(text);
    std.debug.print("ref-one\t{d}\t{d}\n", .{ @intFromBool(same_one == text), header(text).nRCRef });
    const same_two = formatter.rcStrRef(text);
    std.debug.print("ref-two\t{d}\t{d}\n", .{ @intFromBool(same_two == text), header(text).nRCRef });
    formatter.rcStrUnref(&manager, text);
    std.debug.print("unref\t{d}\n", .{header(text).nRCRef});
    formatter.rcStrUnref(&manager, text);
    text = formatter.rcStrResize(&manager, text, 10) orelse return error.OutOfMemory;
    dump("grown", &manager, text, 5);
    text = formatter.rcStrResize(&manager, text, 2) orelse return error.OutOfMemory;
    dump("shrunk", &manager, text, 2);
    formatter.rcStrUnref(&manager, text);
}
