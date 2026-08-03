const std = @import("std");
const memory_journal = @import("memory_journal");
const vfs = memory_journal.vfs_api;

fn hashBytes(bytes: []const u8) u32 {
    var hash: u32 = 2_166_136_261;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 16_777_619;
    }
    return hash;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var opened = memory_journal.Journal.open(allocator, null, null, 0, -1);
    var journal = opened.journal;
    std.debug.print("open\t{d}\t{d}\n", .{ @intFromBool(opened.result == vfs.OK), @intFromBool(journal.isInMemory()) });
    var input: [1600]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    var rc = journal.write(&input, 0);
    var size: i64 = -1;
    _ = journal.fileSize(&size);
    std.debug.print("write\t{d}\t{d}\n", .{ rc, size });
    var output: [1100]u8 = undefined;
    @memset(&output, 0);
    rc = journal.read(&output, 500);
    std.debug.print("read\t{d}\t{d}\t{d}\t{d}\n", .{ rc, hashBytes(&output), output[0], output[1099] });
    rc = journal.read(&output, 501);
    std.debug.print("short\t{d}\n", .{rc});
    rc = journal.write("HEADER", 0);
    @memset(output[0..6], 0);
    _ = journal.read(output[0..6], 0);
    std.debug.print("header\t{d}\t{d}\n", .{ rc, hashBytes(output[0..6]) });
    rc = journal.truncate(900);
    _ = journal.fileSize(&size);
    std.debug.print("truncate\t{d}\t{d}\n", .{ rc, size });
    rc = journal.write("TAIL", 900);
    @memset(output[0..4], 0);
    _ = journal.read(output[0..4], 900);
    _ = journal.fileSize(&size);
    std.debug.print("append\t{d}\t{d}\t{d}\n", .{ rc, size, hashBytes(output[0..4]) });
    std.debug.print("close\t{d}\n", .{journal.close()});

    var memory = vfs.MemoryVfs.init(allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("memory-journal-differential", &memory);
    opened = memory_journal.Journal.open(allocator, &adapter.abi, "spill-journal", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_JOURNAL, 32);
    journal = opened.journal;
    std.debug.print("spill-open\t{d}\t{d}\n", .{ opened.result, @intFromBool(journal.isInMemory()) });
    rc = journal.write("0123456789abcdef", 0);
    std.debug.print("spill-first\t{d}\t{d}\n", .{ rc, @intFromBool(journal.isInMemory()) });
    rc = journal.write("0123456789abcdef0123", 16);
    _ = journal.fileSize(&size);
    std.debug.print("spill-second\t{d}\t{d}\t{d}\n", .{ rc, @intFromBool(journal.isInMemory()), size });
    @memset(output[0..36], 0);
    rc = journal.read(output[0..36], 0);
    std.debug.print("spill-read\t{d}\t{d}\n", .{ rc, hashBytes(output[0..36]) });
    std.debug.print("spill-sync\t{d}\n", .{journal.sync(0x00002)});
    std.debug.print("spill-close\t{d}\n", .{journal.close()});
}
