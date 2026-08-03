const std = @import("std");
const types = @import("types.zig");

test "C integer assumptions match the first ABI profile" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(c_int));
    try std.testing.expectEqual(@sizeOf(?*anyopaque), @sizeOf(?*types.sqlite3));
}
