const std = @import("std");
const pager_module = @import("pager");
const Pager = pager_module.Pager;
const vfs = pager_module.vfs;

fn install(memory: *vfs.MemoryVfs, name: []const u8, bytes: []const u8) !void {
    const opened = memory.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return error.Open;
    const file = opened.file.?;
    if (file.write(bytes, 0) != vfs.OK or file.sync() != vfs.OK) return error.Write;
    if (memory.closeAndDestroy(file) != vfs.OK) return error.Close;
}

fn userVersion(page: []const u8) u32 {
    return (@as(u32, page[60]) << 24) | (@as(u32, page[61]) << 16) |
        (@as(u32, page[62]) << 8) | page[63];
}

fn setUserVersion(page: []u8, value: u32) void {
    page[60] = @truncate(value >> 24);
    page[61] = @truncate(value >> 16);
    page[62] = @truncate(value >> 8);
    page[63] = @truncate(value);
}

fn mutate(pager: *Pager, value: u32) !void {
    if (pager.beginWrite() != .ok) return error.Begin;
    const fetched = pager.getPage(1, false);
    if (fetched.result != .ok) return error.Fetch;
    const page = fetched.page.?;
    if (pager.makeWritable(page) != .ok) return error.Writable;
    setUserVersion(page.data, value);
    if (pager.release(page) != .ok) return error.Release;
}

fn dump(io: std.Io, allocator: std.mem.Allocator, memory: *vfs.MemoryVfs, path: []const u8, durable: bool) !void {
    const bytes = if (durable)
        try memory.copyDurable(allocator, "db")
    else
        try memory.copyVolatile(allocator, "db");
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.Arguments;
    const path = args.next() orelse return error.Arguments;
    const value_text = args.next() orelse return error.Arguments;
    const value = try std.fmt.parseInt(u32, value_text, 10);
    const database_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(database_bytes);

    var memory = vfs.MemoryVfs.init(allocator);
    defer memory.deinit();
    try install(&memory, "db", database_bytes);
    var journal_path_buffer: [4096]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_path_buffer, "{s}-journal", .{path});
    if (std.mem.eql(u8, mode, "recover")) {
        const journal_bytes = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(journal_bytes);
        try install(&memory, "db-journal", journal_bytes);
    }

    var adapter = vfs.AbiAdapter.init("rollback-native", &memory);
    var pager = Pager.open(allocator, &adapter.abi, "db", .{ .writable = true }).pager orelse return error.PagerOpen;
    if (pager.beginRead() != .ok) return error.BeginRead;

    if (std.mem.eql(u8, mode, "recover")) {
        const fetched = pager.getPage(1, false);
        if (fetched.result != .ok) return error.Fetch;
        const old = userVersion(fetched.page.?.data);
        if (pager.release(fetched.page.?) != .ok) return error.Release;
        std.debug.print("recovered\t{d}\n", .{old});
        try mutate(&pager, value);
        if (pager.commit() != .ok) return error.Commit;
        if (pager.close() != .ok) return error.Close;
        try dump(io, allocator, &memory, path, false);
        std.Io.Dir.cwd().deleteFile(io, journal_path) catch {};
    } else if (std.mem.eql(u8, mode, "commit")) {
        try mutate(&pager, value);
        if (pager.commit() != .ok) return error.Commit;
        if (pager.close() != .ok) return error.Close;
        try dump(io, allocator, &memory, path, false);
    } else if (std.mem.eql(u8, mode, "hot")) {
        try mutate(&pager, value);
        if (pager.commitPhaseOne() != .ok) return error.Commit;
        memory.crash();
        pager.crashClose();
        try dump(io, allocator, &memory, path, true);
        const journal = try memory.copyDurable(allocator, "db-journal");
        defer allocator.free(journal);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = journal_path, .data = journal });
    } else return error.Arguments;
}
