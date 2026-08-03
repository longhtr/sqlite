const std = @import("std");
const vfs_mod = @import("vfs");

extern fn run_memory_vfs_probe(vfs: *vfs_mod.sqlite3_vfs) callconv(.c) c_int;
var active: ?*vfs_mod.MemoryVfs = null;

pub export fn sqlite_zig_vfs_reset_trace() callconv(.c) void {
    active.?.events.clearRetainingCapacity();
}

pub export fn sqlite_zig_vfs_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var used: usize = 0;
    for (active.?.events.items) |event| {
        const name: ?[]const u8 = if (event.kind == .journal and event.method == .write)
            "journal-write\n"
        else if (event.kind == .journal and event.method == .sync)
            "journal-sync\n"
        else if (event.kind == .database and event.method == .write)
            "database-write\n"
        else if (event.kind == .database and event.method == .sync)
            "database-sync\n"
        else if (event.kind == .journal and event.method == .delete)
            "journal-delete\n"
        else
            null;
        if (name) |text| {
            if (used + text.len > @as(usize, @intCast(capacity))) return -1;
            @memcpy(output[used..][0..text.len], text);
            used += text.len;
        }
    }
    return @intCast(used);
}

pub fn main() !void {
    var memory_vfs = vfs_mod.MemoryVfs.init(std.heap.c_allocator);
    defer memory_vfs.deinit();
    active = &memory_vfs;
    defer active = null;
    var adapter = vfs_mod.AbiAdapter.init("sqlite-zig-memory", &memory_vfs);
    const rc = run_memory_vfs_probe(&adapter.abi);
    if (rc != 0) {
        std.log.err("memory VFS probe failed at case {d}", .{rc});
        return error.MemoryVfsProbeFailed;
    }
}
