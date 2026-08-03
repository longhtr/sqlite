const std = @import("std");
const pager_module = @import("pager");
const Pager = pager_module.Pager;
const vfs = pager_module.vfs;
fn install(memory: *vfs.MemoryVfs, name: []const u8, data: []const u8, flags: c_int) !void {
    const o = memory.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | flags);
    if (o.rc != vfs.OK) return error.Open;
    const f = o.file.?;
    if (f.write(data, 0) != vfs.OK or f.sync() != vfs.OK) return error.Write;
    if (memory.closeAndDestroy(f) != vfs.OK) return error.Close;
}
fn version(data: []const u8) u32 {
    return (@as(u32, data[60]) << 24) | (@as(u32, data[61]) << 16) | (@as(u32, data[62]) << 8) | data[63];
}
fn setVersion(data: []u8, v: u32) void {
    data[60] = @truncate(v >> 24);
    data[61] = @truncate(v >> 16);
    data[62] = @truncate(v >> 8);
    data[63] = @truncate(v);
}
fn dump(io: std.Io, a: std.mem.Allocator, m: *vfs.MemoryVfs, host: []const u8, name: []const u8, durable: bool) !void {
    const b = if (durable) try m.copyDurable(a, name) else try m.copyVolatile(a, name);
    defer a.free(b);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = host, .data = b });
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.Args;
    const path = args.next() orelse return error.Args;
    const value = try std.fmt.parseInt(u32, args.next() orelse "0", 10);
    const a = init.gpa;
    const io = init.io;
    const db = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
    defer a.free(db);
    var memory = vfs.MemoryVfs.init(a);
    defer memory.deinit();
    try install(&memory, "db", db, vfs.OPEN_MAIN_DB);
    var wal_path_buf: [4096]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}-wal", .{path});
    var host_wal = false;
    if (std.Io.Dir.cwd().access(io, wal_path, .{})) |_| {
        host_wal = true;
    } else |_| {}
    if (host_wal) {
        const wb = try std.Io.Dir.cwd().readFileAlloc(io, wal_path, a, .limited(32 * 1024 * 1024));
        defer a.free(wb);
        try install(&memory, "db-wal", wb, vfs.OPEN_WAL);
    }
    var adapter = vfs.AbiAdapter.init("wal-native", &memory);
    var pager = Pager.open(a, &adapter.abi, "db", .{ .writable = true }).pager orelse return error.Pager;
    try expect(pager.beginRead());
    const first = pager.getPage(1, false);
    try expect(first.result);
    const old = version(first.page.?.data);
    try expect(pager.release(first.page.?));
    std.debug.print("wal-native\t{d}\n", .{old});
    if (std.mem.eql(u8, mode, "write") or std.mem.eql(u8, mode, "crash") or std.mem.eql(u8, mode, "checkpoint")) {
        try expect(pager.beginWrite());
        const p = pager.getPage(1, false).page.?;
        try expect(pager.makeWritable(p));
        setVersion(p.data, value);
        try expect(pager.release(p));
        try expect(pager.commit());
    }
    if (std.mem.eql(u8, mode, "checkpoint")) {
        const c = pager.checkpointWal();
        try expect(c.result);
    }
    const crash = std.mem.eql(u8, mode, "crash");
    if (crash) {
        memory.crash();
        pager.crashClose();
    } else try expect(pager.close());
    try dump(io, a, &memory, path, "db", crash);
    var exists: c_int = 0;
    _ = memory.access("db-wal", vfs.ACCESS_EXISTS, &exists);
    if (exists != 0) try dump(io, a, &memory, wal_path, "db-wal", crash) else std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};
}
fn expect(rc: anytype) !void {
    if (rc != .ok) return error.Result;
}
