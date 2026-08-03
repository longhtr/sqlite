const std = @import("std");
const btree = @import("btree");
const vfs = btree.vfs;

const fixtures = [_][]const u8{
    "core-512.db",
    "utf16le-1024.db",
    "utf16be-2048.db",
    "autovacuum-4096.db",
    "autovacuum-full-8192.db",
    "core-16384.db",
    "core-32768.db",
    "wide-65536.db",
};

const Root = struct {
    kind_name: []u8,
    name: []u8,
    page: u32,
    tree_kind: btree.TreeKind,
};

fn install(memory: *vfs.MemoryVfs, name: []const u8, bytes: []const u8) !void {
    const opened = memory.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return error.Open;
    const file = opened.file.?;
    if (file.write(bytes, 0) != vfs.OK) return error.Write;
    if (file.sync() != vfs.OK) return error.Sync;
    if (memory.closeAndDestroy(file) != vfs.OK) return error.Close;
}

fn hashBytes(initial: u64, bytes: []const u8) u64 {
    var hash = initial;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1_099_511_628_211;
    }
    return hash;
}
fn hashU32(initial: u64, value: u32) u64 {
    const bytes: [4]u8 = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
    return hashBytes(initial, &bytes);
}
fn hashU64(initial: u64, value: u64) u64 {
    var bytes: [8]u8 = undefined;
    for (0..8) |index| bytes[index] = @truncate(value >> @intCast(56 - index * 8));
    return hashBytes(initial, &bytes);
}

fn lessRoot(_: void, left: Root, right: Root) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn rootText(allocator: std.mem.Allocator, database: *btree.Database, value: btree.Value) ![]u8 {
    if (value != .text) return error.Schema;
    return btree.textToUtf8(allocator, value.text, database.encoding);
}

fn discoverRoots(allocator: std.mem.Allocator, database: *btree.Database) !std.ArrayList(Root) {
    var roots = std.ArrayList(Root).empty;
    errdefer {
        for (roots.items) |root| {
            allocator.free(root.kind_name);
            allocator.free(root.name);
        }
        roots.deinit(allocator);
    }
    var cursor = database.openCursor(1, .table).cursor orelse return error.Schema;
    defer cursor.deinit();
    if (!cursor.first()) return roots;
    while (cursor.current()) |_| {
        const decoded = cursor.record();
        if (decoded.result != .ok) return error.Schema;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len >= 5 and record.values[0] == .text and record.values[1] == .text and
            record.values[3] == .integer)
        {
            const kind_name = try rootText(allocator, database, record.values[0]);
            errdefer allocator.free(kind_name);
            const name = try rootText(allocator, database, record.values[1]);
            errdefer allocator.free(name);
            if ((std.mem.eql(u8, kind_name, "table") or std.mem.eql(u8, kind_name, "index")) and
                !std.mem.startsWith(u8, name, "sqlite_"))
            {
                try roots.append(allocator, .{
                    .kind_name = kind_name,
                    .name = name,
                    .page = @intCast(record.values[3].integer),
                    .tree_kind = if (std.mem.eql(u8, kind_name, "table") and !std.mem.eql(u8, name, "wr")) .table else .index,
                });
            } else {
                allocator.free(kind_name);
                allocator.free(name);
            }
        }
        if (!cursor.next()) break;
    }
    std.mem.sort(Root, roots.items, {}, lessRoot);
    return roots;
}

fn printHex(bytes: []const u8) void {
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
}

fn printValue(allocator: std.mem.Allocator, database: *btree.Database, value: btree.Value) !void {
    switch (value) {
        .null_ => std.debug.print("N", .{}),
        .integer => |integer| std.debug.print("I{d}", .{integer}),
        .real => |real| std.debug.print("R{x:0>16}", .{@as(u64, @bitCast(real))}),
        .text => |text| {
            const utf8 = try btree.textToUtf8(allocator, text, database.encoding);
            defer allocator.free(utf8);
            std.debug.print("T", .{});
            printHex(utf8);
        },
        .blob => |blob| {
            std.debug.print("B", .{});
            printHex(blob);
        },
    }
}

fn scanTree(fixture: []const u8, root: Root, database: *btree.Database) !void {
    const outcome = database.openCursor(root.page, root.tree_kind);
    if (outcome.result != .ok) return error.Scan;
    var cursor = outcome.cursor.?;
    defer cursor.deinit();
    var hash: u64 = 14_695_981_039_346_656_037;
    for (cursor.entries.items) |entry| {
        hash = hashBytes(hash, if (root.tree_kind == .table) "T" else "I");
        if (entry.rowid) |rowid| hash = hashU64(hash, @bitCast(rowid));
        hash = hashU32(hash, @intCast(entry.payload.len));
        hash = hashBytes(hash, entry.payload);
    }
    std.debug.print("tree\t{s}\t{s}\t0\t{d}\t{x:0>16}\n", .{ fixture, root.name, cursor.count(), hash });
}

fn selectedValues(allocator: std.mem.Allocator, fixture: []const u8, root: Root, database: *btree.Database) !void {
    var cursor = database.openCursor(root.page, .table).cursor orelse return error.Scan;
    defer cursor.deinit();
    const rowids = [_]i64{ 1, 250, 500, 1 << 40 };
    for (rowids) |rowid| {
        if (!cursor.seekTable(rowid)) continue;
        const decoded = cursor.record();
        if (decoded.result != .ok) return error.Record;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len != 6) return error.Record;
        std.debug.print("record\t{s}\tI{d}", .{ fixture, rowid });
        for (record.values[1..]) |value| {
            std.debug.print("\t", .{});
            try printValue(allocator, database, value);
        }
        std.debug.print("\n", .{});
    }
}

fn indexSeek(fixture: []const u8, item_root: Root, index_root: Root, database: *btree.Database) !void {
    var table = database.openCursor(item_root.page, .table).cursor orelse return error.Scan;
    defer table.deinit();
    if (!table.seekTable(250)) return error.Seek;
    var row = table.record().record.?;
    defer row.deinit();
    const key = [_]btree.Value{ row.values[3], row.values[1], .{ .integer = 250 } };
    var index = database.openCursor(index_root.page, .index).cursor orelse return error.Scan;
    defer index.deinit();
    const seek = index.seekIndex(&key);
    if (seek.result != .ok or !seek.found) return error.Seek;
    std.debug.print("indexseek\t{s}\t250\n", .{fixture});
}

fn runFixture(allocator: std.mem.Allocator, fixture: []const u8) !void {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "tests/fixtures/btree/{s}", .{fixture});
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(allocator);
    defer memory.deinit();
    try install(&memory, fixture, bytes);
    var adapter = vfs.AbiAdapter.init("btree-native", &memory);
    const opened = btree.Database.open(allocator, &adapter.abi, fixture);
    if (opened.result != .ok) return error.Open;
    var database = opened.database.?;
    defer _ = database.close();
    var roots = try discoverRoots(allocator, &database);
    defer {
        for (roots.items) |root| {
            allocator.free(root.kind_name);
            allocator.free(root.name);
        }
        roots.deinit(allocator);
    }
    for (roots.items) |root| std.debug.print("root\t{s}\t{s}\t{s}\t{d}\n", .{ fixture, root.kind_name, root.name, root.page });
    for (roots.items) |root| try scanTree(fixture, root, &database);
    var item_root: ?Root = null;
    var index_root: ?Root = null;
    for (roots.items) |root| {
        if (std.mem.eql(u8, root.name, "items")) {
            item_root = root;
            try selectedValues(allocator, fixture, root, &database);
        }
        if (std.mem.eql(u8, root.name, "items_t_i")) index_root = root;
    }
    try indexSeek(fixture, item_root orelse return error.Schema, index_root orelse return error.Schema, &database);
}

pub fn main() !void {
    for (fixtures) |fixture| try runFixture(std.heap.c_allocator, fixture);
}
