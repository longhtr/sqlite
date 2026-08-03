const std = @import("std");
const root = @import("random_process");

fn anyNonzero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return true;
    return false;
}
pub fn main() void {
    root.public_api.sqlite3_randomness(0, null);
    std.debug.print("1\t{d}\t{d}\n", .{ @intFromBool(root.random.process_state.words[0] == 0), root.random.process_state.remaining });
    var first: [16]u8 = undefined;
    root.public_api.sqlite3_randomness(first.len, &first);
    std.debug.print("2\t{d}\t{d}\t{d}\n", .{ @intFromBool(root.random.process_state.words[0] != 0), root.random.process_state.remaining, @intFromBool(anyNonzero(&first)) });
    root.random.saveProcessState();
    var a: [20]u8 = undefined;
    var b: [20]u8 = undefined;
    root.public_api.sqlite3_randomness(a.len, &a);
    root.random.restoreProcessState();
    root.public_api.sqlite3_randomness(b.len, &b);
    std.debug.print("3\t{d}\t{d}\n", .{ @intFromBool(std.mem.eql(u8, &a, &b)), root.random.process_state.remaining });
    var more: [8]u8 = undefined;
    root.public_api.sqlite3_randomness(more.len, &more);
    std.debug.print("4\t{d}\n", .{root.random.process_state.remaining});
    root.public_api.sqlite3_randomness(5, null);
    std.debug.print("5\t{d}\t{d}\n", .{ @intFromBool(root.random.process_state.words[0] == 0), root.random.process_state.remaining });
    _ = root.public_api.sqlite3_shutdown();
}
