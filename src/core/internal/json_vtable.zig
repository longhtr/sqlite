//! JSON table-valued cursor behavior from SQLite `json.c`.

const std = @import("std");
const core = @import("json_core.zig");
const functions = @import("json_functions.zig");
const text = @import("json_text.zig");
const mem = @import("vdbe_mem.zig");
const types = @import("vdbe_types.zig");

pub const Error = text.Error;

pub const Column = enum(u8) {
    key,
    value,
    type_,
    atom,
    id,
    parent,
    full_key,
    path,
    json,
    root,
};

pub const Connection = struct {
    mode: u8,
    recursive: bool,
};

pub const Parent = struct {
    head: usize,
    value: usize,
    end: usize,
    path_length: usize,
    key: i64,
};

pub const Cursor = struct {
    allocator: std.mem.Allocator,
    parse: core.JsonParse,
    rowid: u32 = 0,
    index: usize = 0,
    end: usize = 0,
    root_length: usize = 0,
    container_type: u8 = 0,
    recursive: bool,
    mode: u8,
    parents: std.ArrayList(Parent) = .empty,
    path: core.JsonString,
};

fn appendRaw(output: *core.JsonString, bytes: []const u8) Error!void {
    if (!core.expandAndAppendString(output, bytes)) return error.OutOfMemory;
}

fn nodeSpan(parse: *const core.JsonParse, index: usize) ?usize {
    var size: u32 = 0;
    const header = core.payloadSize(parse, index, &size);
    if (header == 0) return null;
    return header + size;
}

fn skipLabel(cursor: *const Cursor) usize {
    if (cursor.container_type != core.kind.object) return cursor.index;
    const span = nodeSpan(&cursor.parse, cursor.index) orelse return cursor.index;
    const result = cursor.index + span;
    return if (result >= cursor.parse.blob.items.len) cursor.index else result;
}

/// Source `jsonEachConnect()`.
pub fn connect(name: []const u8) ?Connection {
    const mode: u8 = if (std.ascii.startsWithIgnoreCase(name, "jsonb_")) 2 else 1;
    const suffix = if (mode == 2) name[6..] else if (name.len >= 5) name[5..] else return null;
    if (!std.ascii.eqlIgnoreCase(suffix, "each") and !std.ascii.eqlIgnoreCase(suffix, "tree")) return null;
    return .{ .mode = mode, .recursive = std.ascii.eqlIgnoreCase(suffix, "tree") };
}

/// Source `jsonEachOpen()`.
pub fn open(allocator: std.mem.Allocator, connection: Connection) Error!*Cursor {
    const cursor = allocator.create(Cursor) catch return error.OutOfMemory;
    cursor.* = .{
        .allocator = allocator,
        .parse = core.JsonParse.init(allocator),
        .recursive = connection.recursive,
        .mode = connection.mode,
        .path = core.JsonString.init(allocator),
    };
    return cursor;
}

/// Source `jsonEachCursorReset()`.
pub fn cursorReset(cursor: *Cursor) void {
    cursor.parse.blob.deinit(cursor.parse.allocator);
    cursor.parse = core.JsonParse.init(cursor.allocator);
    cursor.path.bytes.clearRetainingCapacity();
    cursor.parents.clearRetainingCapacity();
    cursor.rowid = 0;
    cursor.index = 0;
    cursor.end = 0;
    cursor.root_length = 0;
    cursor.container_type = 0;
}

/// Source `jsonEachClose()`.
pub fn close(cursor: *Cursor) void {
    const allocator = cursor.allocator;
    cursor.parse.blob.deinit(cursor.parse.allocator);
    cursor.path.deinit();
    cursor.parents.deinit(allocator);
    allocator.destroy(cursor);
}

/// Source `jsonEachEof()`.
pub fn eof(cursor: *const Cursor) bool {
    return cursor.index >= cursor.end;
}

/// Source `jsonAppendPathName()`.
pub fn appendPathName(cursor: *Cursor) Error!void {
    if (cursor.parents.items.len == 0) return error.Malformed;
    if (cursor.container_type == core.kind.array) {
        var buffer: [32]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buffer, "[{d}]", .{cursor.parents.items[cursor.parents.items.len - 1].key}) catch return error.OutOfMemory;
        return appendRaw(&cursor.path, rendered);
    }
    if (cursor.container_type != core.kind.object) return error.Malformed;
    var size: u32 = 0;
    const header = core.payloadSize(&cursor.parse, cursor.index, &size);
    if (header == 0) return error.Malformed;
    const label = cursor.parse.blob.items[cursor.index + header .. cursor.index + header + size];
    var quote = label.len == 0 or !std.ascii.isAlphabetic(label[0]);
    if (!quote) for (label) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            quote = true;
            break;
        }
    };
    try appendRaw(&cursor.path, if (quote) ".\"" else ".");
    try appendRaw(&cursor.path, label);
    if (quote) try appendRaw(&cursor.path, "\"");
}

/// Source `jsonEachNext()`.
pub fn next(cursor: *Cursor) Error!void {
    if (cursor.recursive) {
        var level_change = false;
        const value_index = skipLabel(cursor);
        const node_type = cursor.parse.blob.items[value_index] & 15;
        const span = nodeSpan(&cursor.parse, value_index) orelse return error.Malformed;
        if (node_type == core.kind.object or node_type == core.kind.array) {
            cursor.parents.append(cursor.allocator, .{
                .head = cursor.index,
                .value = value_index,
                .end = value_index + span,
                .key = -1,
                .path_length = cursor.path.bytes.items.len,
            }) catch return error.OutOfMemory;
            level_change = true;
            if (cursor.container_type != 0 and cursor.parents.items.len > 1) try appendPathName(cursor);
            var payload_size: u32 = 0;
            const header = core.payloadSize(&cursor.parse, value_index, &payload_size);
            if (header == 0) return error.Malformed;
            cursor.index = value_index + header;
        } else {
            cursor.index = value_index + span;
        }
        while (cursor.parents.items.len > 0 and cursor.index >= cursor.parents.items[cursor.parents.items.len - 1].end) {
            const parent = cursor.parents.pop().?;
            cursor.path.bytes.items.len = parent.path_length;
            level_change = true;
        }
        if (level_change) {
            cursor.container_type = if (cursor.parents.items.len > 0)
                cursor.parse.blob.items[cursor.parents.items[cursor.parents.items.len - 1].value] & 15
            else
                0;
        }
    } else {
        const value_index = skipLabel(cursor);
        const span = nodeSpan(&cursor.parse, value_index) orelse return error.Malformed;
        cursor.index = value_index + span;
    }
    if (cursor.container_type == core.kind.array and cursor.parents.items.len > 0) cursor.parents.items[cursor.parents.items.len - 1].key += 1;
    cursor.rowid += 1;
}

/// Source `jsonEachPathLength()`.
pub fn pathLength(cursor: *Cursor) usize {
    var length = cursor.path.bytes.items.len;
    if (cursor.rowid == 0 and cursor.recursive and length >= 2) {
        while (length > 1) {
            length -= 1;
            if (cursor.path.bytes.items[length] != '[' and cursor.path.bytes.items[length] != '.') continue;
            const result = functions.lookupStep(&cursor.parse, 0, cursor.path.bytes.items[1..length], 0);
            if (result >= functions.lookup_path_error) continue;
            var size: u32 = 0;
            const header = core.payloadSize(&cursor.parse, result, &size);
            if (header != 0 and result + header == cursor.index) break;
        }
    }
    return length;
}

fn resultPath(context: *types.Context, path: []const u8) void {
    mem.resultText(context, path.ptr, @intCast(path.len), .transient);
}

/// Source `jsonEachColumn()`.
pub fn column(cursor: *Cursor, context: *types.Context, requested: Column) void {
    switch (requested) {
        .key => {
            if (cursor.parents.items.len == 0) {
                if (cursor.root_length == 1) return;
                const base = pathLength(cursor);
                const key = cursor.path.bytes.items[base..cursor.root_length];
                if (key.len > 2 and key[0] == '[') {
                    mem.resultInt64(context, std.fmt.parseInt(i64, key[1 .. key.len - 1], 10) catch return);
                } else if (key.len > 3 and key[0] == '.' and key[1] == '"') {
                    resultPath(context, key[2 .. key.len - 1]);
                } else if (key.len > 1) resultPath(context, key[1..]);
                return;
            }
            if (cursor.container_type == core.kind.object) {
                functions.returnFromBlob(&cursor.parse, cursor.index, context, 1);
            } else if (cursor.container_type == core.kind.array) {
                mem.resultInt64(context, cursor.parents.items[cursor.parents.items.len - 1].key);
            }
        },
        .value => {
            const value_index = skipLabel(cursor);
            functions.returnFromBlob(&cursor.parse, value_index, context, cursor.mode);
            if ((cursor.parse.blob.items[value_index] & 15) >= core.kind.array) mem.resultSubtype(context, 74);
        },
        .type_ => {
            const names = [_][]const u8{ "null", "true", "false", "integer", "integer", "real", "real", "text", "text", "text", "text", "array", "object" };
            const name = names[cursor.parse.blob.items[skipLabel(cursor)] & 15];
            resultPath(context, name);
        },
        .atom => {
            const value_index = skipLabel(cursor);
            if ((cursor.parse.blob.items[value_index] & 15) < core.kind.array) functions.returnFromBlob(&cursor.parse, value_index, context, 1);
        },
        .id => mem.resultInt64(context, @intCast(cursor.index)),
        .parent => if (cursor.parents.items.len > 0 and cursor.recursive) mem.resultInt64(context, @intCast(cursor.parents.items[cursor.parents.items.len - 1].head)),
        .full_key => {
            const original = cursor.path.bytes.items.len;
            if (cursor.parents.items.len > 0) appendPathName(cursor) catch {
                mem.resultErrorNoMem(context);
                return;
            };
            resultPath(context, cursor.path.bytes.items);
            cursor.path.bytes.items.len = original;
        },
        .path => resultPath(context, cursor.path.bytes.items[0..pathLength(cursor)]),
        .json => mem.resultBlob(context, cursor.parse.blob.items.ptr, @intCast(cursor.parse.blob.items.len), .transient),
        .root => resultPath(context, cursor.path.bytes.items[0..cursor.root_length]),
    }
}

pub fn columnCallback(cursor_pointer: ?*anyopaque, context_pointer: ?*anyopaque, index: c_int) callconv(.c) c_int {
    const cursor: *Cursor = @ptrCast(@alignCast(cursor_pointer orelse return 21));
    const context: *types.Context = @ptrCast(@alignCast(context_pointer orelse return 21));
    if (index < 0 or index > @intFromEnum(Column.root)) return 25;
    column(cursor, context, @enumFromInt(index));
    return 0;
}

pub const Constraint = struct { column: i32, equal: bool, usable: bool };
pub const Plan = struct { index_number: u8 = 0, json_argument: ?usize = null, root_argument: ?usize = null, order_by_consumed: bool = false, estimated_cost: f64 = 1.0e99 };

/// Source `jsonEachBestIndex()`.
pub fn bestIndex(constraints: []const Constraint, rowid_ascending: bool) error{Constraint}!Plan {
    var plan: Plan = .{ .order_by_consumed = rowid_ascending };
    var unusable_mask: u2 = 0;
    var usable_mask: u2 = 0;
    for (constraints, 0..) |constraint, index| {
        if (constraint.column < 8 or constraint.column > 9) continue;
        const bit: u2 = @as(u2, 1) << @intCast(constraint.column - 8);
        if (!constraint.usable) {
            unusable_mask |= bit;
        } else if (constraint.equal) {
            usable_mask |= bit;
            if (constraint.column == 8) plan.json_argument = index else plan.root_argument = index;
        }
    }
    if (unusable_mask & ~usable_mask != 0) return error.Constraint;
    if (plan.json_argument != null) {
        plan.estimated_cost = 1.0;
        plan.index_number = if (plan.root_argument == null) 1 else 3;
    }
    return plan;
}

/// Source `jsonEachFilter()`.
pub fn filter(cursor: *Cursor, input: []const u8, input_is_blob: bool, root_optional: ?[]const u8) Error!void {
    cursorReset(cursor);
    if (input_is_blob and text.argumentIsJsonb(&cursor.parse, input)) {
        // The input has already been adopted as JSONB.
    } else try text.convertTextToBlob(&cursor.parse, input);
    const root = root_optional orelse "$";
    if (root.len == 0 or root[0] != '$') return error.Malformed;
    try appendRaw(&cursor.path, root);
    cursor.root_length = root.len;
    var selected: usize = 0;
    if (root.len > 1) {
        selected = functions.lookupStep(&cursor.parse, 0, root[1..], 0);
        if (selected == functions.lookup_not_found) return;
        if (selected >= functions.lookup_path_error) return error.Malformed;
        if (cursor.parse.label_index != 0) {
            cursor.index = cursor.parse.label_index;
            cursor.container_type = core.kind.object;
        } else {
            cursor.index = selected;
            cursor.container_type = core.kind.array;
        }
    }
    const span = nodeSpan(&cursor.parse, selected) orelse return error.Malformed;
    cursor.end = selected + span;
    if ((cursor.parse.blob.items[selected] & 15) >= core.kind.array and !cursor.recursive) {
        var size: u32 = 0;
        const header = core.payloadSize(&cursor.parse, selected, &size);
        if (header == 0) return error.Malformed;
        cursor.index = selected + header;
        cursor.container_type = cursor.parse.blob.items[selected] & 15;
        cursor.parents.append(cursor.allocator, .{ .head = cursor.index, .value = selected, .end = cursor.end, .path_length = cursor.path.bytes.items.len, .key = 0 }) catch return error.OutOfMemory;
    }
}

/// Source `jsonEachRowid()`.
pub fn rowid(cursor: *const Cursor) i64 {
    return cursor.rowid;
}
