const std = @import("std");
const pager_module = @import("pager");
const Pager = pager_module.Pager;
const vfs = pager_module.vfs;

const fixtures = [_][]const u8{
    "empty.db",
    "valid-empty-512.db",
    "valid-empty-4096.db",
    "valid-two-page-4096.db",
    "valid-empty-65536.db",
    "truncated-second-page.db",
    "valid-wal-header-without-wal.db",
    "malformed-short-header.db",
    "malformed-magic.db",
    "malformed-page-size.db",
    "malformed-payload-fractions.db",
};

fn install(memory: *vfs.MemoryVfs, name: []const u8, bytes: []const u8) !void {
    const opened = memory.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return error.Open;
    const file = opened.file.?;
    if (file.write(bytes, 0) != vfs.OK) return error.Write;
    if (file.sync() != vfs.OK) return error.Sync;
    if (memory.closeAndDestroy(file) != vfs.OK) return error.Close;
}

fn digestPage(bytes: []const u8) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1_099_511_628_211;
    }
    return hash;
}

fn printResult(comptime format: []const u8, arguments: anytype) void {
    std.debug.print(format, arguments);
}

fn runFixture(name: []const u8) !void {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "tests/fixtures/pager/{s}", .{name});
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        std.heap.c_allocator,
        .limited(128 * 1024),
    );
    defer std.heap.c_allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.heap.c_allocator);
    defer memory.deinit();
    try install(&memory, name, bytes);
    var adapter = vfs.AbiAdapter.init("pager-native", &memory);
    const outcome = Pager.open(std.heap.c_allocator, &adapter.abi, name, .{});
    printResult("validate\t{s}\t{d}\n", .{ name, outcome.result.toC() });
    if (outcome.result != .ok) return;

    var pager = outcome.pager.?;
    var rc = pager.beginRead();
    printResult("pager\t{s}\t{d}\t{d}\t{d}\n", .{
        name,
        rc.toC(),
        pager.page_size,
        pager.pageCount(),
    });
    if (rc != .ok) return error.BeginRead;

    const first = pager.getPage(1, false);
    printResult("page\t{s}\t1\t{d}\t{x:0>16}\n", .{
        name,
        first.result.toC(),
        if (first.page) |page| digestPage(page.data) else @as(u64, 0),
    });
    if (first.result != .ok) return error.Page;
    const page1 = first.page.?;

    const again = pager.getPage(1, false);
    printResult("hit\t{s}\t{d}\t{d}\n", .{
        name,
        again.result.toC(),
        if (again.page) |page| page.ref_count else @as(u32, 0),
    });
    if (again.result == .ok) _ = pager.release(again.page.?);

    var probe: u32 = 2;
    while (probe <= pager.pageCount() + 1 and probe <= 3) : (probe += 1) {
        const fetched = pager.getPage(probe, false);
        printResult("page\t{s}\t{d}\t{d}\t{x:0>16}\n", .{
            name,
            probe,
            fetched.result.toC(),
            if (fetched.page) |page| digestPage(page.data) else @as(u64, 0),
        });
        if (fetched.result == .ok) _ = pager.release(fetched.page.?);
    }
    printResult("stats\t{s}\t{d}\t{d}\n", .{
        name,
        pager.stats.cache_hits,
        pager.stats.cache_misses,
    });
    _ = pager.release(page1);
    rc = pager.endRead();
    if (rc != .ok) return error.EndRead;
    rc = pager.close();
    if (rc != .ok) return error.Close;
}

fn runSpecialTraces() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/pager/valid-empty-4096.db",
        std.heap.c_allocator,
        .limited(128 * 1024),
    );
    defer std.heap.c_allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.heap.c_allocator);
    defer memory.deinit();
    var adapter = vfs.AbiAdapter.init("pager-native-special", &memory);

    try install(&memory, "hot.db", bytes);
    try install(&memory, "hot.db-journal", "not-zero");
    const hot_outcome = Pager.open(std.heap.c_allocator, &adapter.abi, "hot.db", .{});
    var hot = hot_outcome.pager.?;
    const hot_rc = hot.beginRead();
    printResult("hot\t{d}\n", .{hot_rc.toC()});
    if (hot.close() != .ok) return error.Close;

    try install(&memory, "busy.db", bytes);
    const blocker_outcome = memory.open("busy.db", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB);
    const blocker = blocker_outcome.file.?;
    if (blocker.lock(vfs.LOCK_EXCLUSIVE) != vfs.OK) return error.Lock;
    const busy_outcome = Pager.open(std.heap.c_allocator, &adapter.abi, "busy.db", .{});
    var busy = busy_outcome.pager.?;
    const busy_rc = busy.beginRead();
    printResult("busy\t{d}\n", .{busy_rc.toC()});
    if (busy.close() != .ok) return error.Close;
    if (blocker.unlock(vfs.LOCK_NONE) != vfs.OK) return error.Unlock;
    if (memory.closeAndDestroy(blocker) != vfs.OK) return error.Close;
}

pub fn main() !void {
    for (fixtures) |name| try runFixture(name);
    try runSpecialTraces();
}
