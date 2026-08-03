const std = @import("std");
const btree = @import("btree");
const vfs = btree.vfs;

fn install(memory: *vfs.MemoryVfs, bytes: []const u8) !void {
    const opened = memory.open("db", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return error.Open;
    const file = opened.file.?;
    if (file.write(bytes, 0) != vfs.OK or file.sync() != vfs.OK) return error.Write;
    if (memory.closeAndDestroy(file) != vfs.OK) return error.Close;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.Arguments;
    const root_page = try std.fmt.parseInt(u32, args.next() orelse return error.Arguments, 10);
    const operations_path = args.next() orelse return error.Arguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const operations = try std.Io.Dir.cwd().readFileAlloc(init.io, operations_path, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(operations);
    var memory = vfs.MemoryVfs.init(init.gpa);
    defer memory.deinit();
    try install(&memory, bytes);
    var adapter = vfs.AbiAdapter.init("btree-mutation", &memory);
    var database = btree.Database.openWritable(init.gpa, &adapter.abi, "db").database orelse return error.Database;
    errdefer _ = database.close();
    if (operations.len > 0 and operations[0] == 'R') {
        var index_cursor = database.openCursor(root_page, .index).cursor orelse return error.Cursor;
        if (!index_cursor.first()) return error.Seed;
        const index_payload = try init.gpa.dupe(u8, index_cursor.current().?.payload);
        defer init.gpa.free(index_payload);
        index_cursor.deinit();
        if (database.deleteIndex(root_page, index_payload) != .ok) return error.Mutation;
        if (database.insertIndex(root_page, index_payload) != .ok) return error.Mutation;
        if (database.close() != .ok) return error.Close;
        const output = try memory.copyVolatile(init.gpa, "db");
        defer init.gpa.free(output);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = output });
        return;
    }

    var cursor = database.openCursor(root_page, .table).cursor orelse return error.Cursor;
    if (!cursor.seekTable(1)) return error.Seed;
    const payload = try init.gpa.dupe(u8, cursor.current().?.payload);
    defer init.gpa.free(payload);
    cursor.deinit();

    var lines = std.mem.splitScalar(u8, operations, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 3 or line[1] != ' ') return error.Operation;
        const rowid = try std.fmt.parseInt(i64, line[2..], 10);
        const rc = switch (line[0]) {
            'I' => database.insertTable(root_page, rowid, payload, false),
            'D' => database.deleteTable(root_page, rowid),
            else => return error.Operation,
        };
        if (rc != .ok) return error.Mutation;
    }
    if (database.close() != .ok) return error.Close;
    const output = try memory.copyVolatile(init.gpa, "db");
    defer init.gpa.free(output);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = output });
}
