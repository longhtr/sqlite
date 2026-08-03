const std = @import("std");
const root = @import("vdbe_mem");
const mem = root.vdbe_mem;

fn show(id: usize, db: *mem.types.Sqlite3, input: []const u8, byte_count: c_int, encoding: u8) void {
    const text = mem.utf16To8(db, input.ptr, byte_count, encoding);
    std.debug.print("{d}\t", .{id});
    if (text) |value| {
        const bytes = std.mem.span(value);
        std.debug.print("{d}\t", .{bytes.len});
        for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
        root.db_allocator.free(db, value);
    } else std.debug.print("-1\tNULL", .{});
    std.debug.print("\n", .{});
}
pub fn main() !void {
    if (root.public_api.sqlite3_initialize() != 0) return error.InitializeFailed;
    defer _ = root.public_api.sqlite3_shutdown();
    var db = std.mem.zeroes(mem.types.Sqlite3);
    db.aLimit[0] = 1_000_000_000;
    db.lookaside.bDisable = 1;
    const le1 = [_]u8{ 'h', 0, 'e', 0, 'l', 0, 'l', 0, 'o', 0, 0, 0 };
    const be1 = [_]u8{ 0, 'h', 0, 'i', 0, 0 };
    const euro_le = [_]u8{ 0xac, 0x20, 0, 0 };
    const smile_le = [_]u8{ 0x3d, 0xd8, 0, 0xde, 0, 0 };
    const bounded = [_]u8{ 'a', 0, 'b', 0, 'c', 0, 0, 0 };
    show(1, &db, &le1, -1, 2);
    show(2, &db, &be1, -1, 3);
    show(3, &db, &euro_le, -1, 2);
    show(4, &db, &smile_le, -1, 2);
    show(5, &db, &bounded, 4, 2);
}
