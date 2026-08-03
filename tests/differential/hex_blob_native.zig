const std = @import("std");
const numeric = @import("numeric");

fn show(id: usize, text: []const u8) !void {
    const bytes = try numeric.hexToBlob(std.heap.c_allocator, text);
    defer std.heap.c_allocator.free(bytes);
    std.debug.print("{d}\t{d}\t", .{ id, bytes.len });
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\t{x:0>2}\n", .{bytes.ptr[bytes.len]});
}
pub fn main() !void {
    try show(1, "'");
    try show(2, "00'");
    try show(3, "4142'");
    try show(4, "deadbeef'");
    try show(5, "Ff'");
}
