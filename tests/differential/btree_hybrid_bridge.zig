const std = @import("std");
const btree = @import("btree");
const vfs = btree.vfs;

fn install(memory: *vfs.MemoryVfs, bytes: []const u8) bool {
    const opened = memory.open("hybrid.db", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return false;
    const file = opened.file.?;
    if (file.write(bytes, 0) != vfs.OK or file.sync() != vfs.OK) return false;
    return memory.closeAndDestroy(file) == vfs.OK;
}

const Output = struct {
    bytes: []u8,
    used: usize = 0,

    fn append(self: *Output, data: []const u8) !void {
        if (data.len > self.bytes.len - self.used) return error.NoSpace;
        @memcpy(self.bytes[self.used..][0..data.len], data);
        self.used += data.len;
    }

    fn hex(self: *Output, data: []const u8) !void {
        const alphabet = "0123456789abcdef";
        if (data.len > (self.bytes.len - self.used) / 2) return error.NoSpace;
        for (data) |byte| {
            self.bytes[self.used] = alphabet[byte >> 4];
            self.bytes[self.used + 1] = alphabet[byte & 15];
            self.used += 2;
        }
    }

    fn print(self: *Output, comptime format: []const u8, args: anytype) !void {
        const written = std.fmt.bufPrint(self.bytes[self.used..], format, args) catch return error.NoSpace;
        self.used += written.len;
    }
};

fn writeValue(output: *Output, allocator: std.mem.Allocator, database: *btree.Database, value: btree.Value) !void {
    switch (value) {
        .null_ => try output.append("N"),
        .integer => |integer| try output.print("I{d}", .{integer}),
        .real => |real| try output.print("R{x:0>16}", .{@as(u64, @bitCast(real))}),
        .text => |text| {
            const utf8 = try btree.textToUtf8(allocator, text, database.encoding);
            defer allocator.free(utf8);
            try output.append("T");
            try output.hex(utf8);
        },
        .blob => |blob| {
            try output.append("B");
            try output.hex(blob);
        },
    }
}

pub export fn zig_phase7_cell(
    database_bytes: [*]const u8,
    database_length: usize,
    root_page: u32,
    rowid: i64,
    column: u32,
    output_bytes: [*]u8,
    output_capacity: usize,
    output_length: *usize,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    output_length.* = 0;
    var memory = vfs.MemoryVfs.init(allocator);
    defer memory.deinit();
    if (!install(&memory, database_bytes[0..database_length])) return 10;
    var adapter = vfs.AbiAdapter.init("phase7-hybrid", &memory);
    const opened = btree.Database.open(allocator, &adapter.abi, "hybrid.db");
    if (opened.result != .ok) return opened.result.toC();
    var database = opened.database.?;
    defer _ = database.close();
    const cursor_outcome = database.openCursor(root_page, .table);
    if (cursor_outcome.result != .ok) return cursor_outcome.result.toC();
    var cursor = cursor_outcome.cursor.?;
    defer cursor.deinit();
    if (!cursor.seekTable(rowid)) return 12;
    var output = Output{ .bytes = output_bytes[0..output_capacity] };
    if (column == 0) {
        output.print("I{d}", .{rowid}) catch return 18;
    } else {
        const decoded = cursor.record();
        if (decoded.result != .ok) return decoded.result.toC();
        var record = decoded.record.?;
        defer record.deinit();
        if (column >= record.values.len) return 25;
        writeValue(&output, allocator, &database, record.values[column]) catch |err| return switch (err) {
            error.OutOfMemory => 7,
            error.NoSpace => 18,
            else => 11,
        };
    }
    output_length.* = output.used;
    return 0;
}
