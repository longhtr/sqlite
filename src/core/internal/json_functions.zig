//! SQL JSON functions and JSONB path editing from SQLite `json.c`.

const std = @import("std");
const memory = @import("../memory.zig");
const core = @import("json_core.zig");
const text = @import("json_text.zig");
const mem = @import("vdbe_mem.zig");
const types = @import("vdbe_types.zig");

const Context = ?*types.Context;
const Arguments = ?[*]?*types.Mem;
const json_subtype = 74;
pub const lookup_error: usize = 0xffffffff;
pub const lookup_not_found: usize = 0xfffffffe;
pub const lookup_not_array: usize = 0xfffffffd;
pub const lookup_too_deep: usize = 0xfffffffc;
pub const lookup_path_error: usize = 0xfffffffb;
const edit_delete: u8 = 1;
const edit_replace: u8 = 2;
const edit_insert: u8 = 3;
const edit_set: u8 = 4;
const edit_array_insert: u8 = 5;
const json_cache_id: c_int = -429938;
const json_cache_size: usize = 4;

const JsonCacheEntry = struct {
    source: []u8,
    parse: *core.JsonParse,
};

const JsonCache = struct {
    entries: std.ArrayList(JsonCacheEntry) = .empty,
};

fn argument(arguments: Arguments, index: usize) *types.Mem {
    return arguments.?[index].?;
}
fn allocator() std.mem.Allocator {
    return memory.processAllocator();
}
fn valueSlice(value: *types.Mem) ?[]const u8 {
    const pointer = mem.valueText(value, 1) orelse return null;
    return pointer[0..@intCast(mem.valueBytes(value, 1))];
}
fn blobSlice(value: *types.Mem) ?[]const u8 {
    const pointer = mem.valueBlob(value) orelse return null;
    return pointer[0..@intCast(mem.valueBytes(value, 1))];
}
fn resultError(context: *types.Context, message: []const u8) void {
    mem.resultError(context, message.ptr, @intCast(message.len));
}
fn resultOwnedText(context: *types.Context, bytes: []u8, subtype: bool) void {
    mem.resultText(context, bytes.ptr, @intCast(bytes.len), .transient);
    allocator().free(bytes);
    if (subtype) mem.resultSubtype(context, json_subtype);
}
fn resultOwnedBlob(context: *types.Context, bytes: []u8) void {
    mem.resultBlob(context, bytes.ptr, @intCast(bytes.len), .transient);
    allocator().free(bytes);
}
fn operationError(context: *types.Context, err: anyerror) void {
    if (err == error.OutOfMemory) mem.resultErrorNoMem(context) else resultError(context, if (err == error.TooDeep) "JSON nested too deep" else "malformed JSON");
}

/// Source `jsonCacheDelete()`.
fn cacheDelete(pointer: ?*anyopaque) callconv(.c) void {
    const cache: *JsonCache = @ptrCast(@alignCast(pointer orelse return));
    const process_allocator = allocator();
    for (cache.entries.items) |*entry| {
        process_allocator.free(entry.source);
        core.freeParse(entry.parse);
    }
    cache.entries.deinit(process_allocator);
    process_allocator.destroy(cache);
}

/// Source `jsonCacheInsert()`.
pub fn cacheInsert(context: *types.Context, source: []const u8, parse: *const core.JsonParse) text.Error!void {
    const cache: *JsonCache = if (mem.getAuxData(context, json_cache_id)) |raw| @ptrCast(@alignCast(raw)) else create: {
        const created = allocator().create(JsonCache) catch return error.OutOfMemory;
        created.* = .{};
        mem.setAuxData(context, json_cache_id, created, cacheDelete);
        const installed = mem.getAuxData(context, json_cache_id) orelse return error.OutOfMemory;
        break :create @ptrCast(@alignCast(installed));
    };
    if (cache.entries.items.len >= json_cache_size) {
        const oldest = cache.entries.orderedRemove(0);
        allocator().free(oldest.source);
        core.freeParse(oldest.parse);
    }
    const copy = allocator().create(core.JsonParse) catch return error.OutOfMemory;
    errdefer allocator().destroy(copy);
    copy.* = core.JsonParse.init(allocator());
    errdefer copy.blob.deinit(copy.allocator);
    copy.blob.appendSlice(copy.allocator, parse.blob.items) catch return error.OutOfMemory;
    copy.read_only = true;
    copy.has_nonstandard = parse.has_nonstandard;
    const source_copy = allocator().dupe(u8, source) catch return error.OutOfMemory;
    errdefer allocator().free(source_copy);
    cache.entries.append(allocator(), .{ .source = source_copy, .parse = copy }) catch return error.OutOfMemory;
}

/// Source `jsonCacheSearch()`.
pub fn cacheSearch(context: *types.Context, value: *types.Mem) ?*const core.JsonParse {
    if (mem.valueType(value) != 3) return null;
    const source = valueSlice(value) orelse return null;
    const cache: *JsonCache = @ptrCast(@alignCast(mem.getAuxData(context, json_cache_id) orelse return null));
    var index: usize = 0;
    while (index < cache.entries.items.len) : (index += 1) {
        if (!std.mem.eql(u8, cache.entries.items[index].source, source)) continue;
        if (index + 1 < cache.entries.items.len) {
            const found = cache.entries.orderedRemove(index);
            cache.entries.appendAssumeCapacity(found);
        }
        return cache.entries.items[cache.entries.items.len - 1].parse;
    }
    return null;
}

fn nodeSpan(parse: *const core.JsonParse, index: usize) ?usize {
    var size: u32 = 0;
    const header = core.payloadSize(parse, index, &size);
    if (header == 0) return null;
    return header + size;
}
fn parsePathKey(path: []const u8, start: usize, key: *[]const u8, raw: *bool) ?usize {
    if (start >= path.len) return null;
    if (path[start] == '"') {
        var index = start + 1;
        while (index < path.len and path[index] != '"') : (index += 1) {
            if (path[index] == '\\' and index + 1 < path.len) index += 1;
        }
        if (index >= path.len) return null;
        key.* = path[start + 1 .. index];
        raw.* = std.mem.indexOfScalar(u8, key.*, '\\') == null;
        return index + 1;
    }
    var index = start;
    while (index < path.len and path[index] != '.' and path[index] != '[') index += 1;
    if (index == start) return null;
    key.* = path[start..index];
    raw.* = true;
    return index;
}

/// Source `jsonLookupStep()`.
pub fn lookupStep(parse: *core.JsonParse, root: usize, path: []const u8, label_index: usize) usize {
    if (parse.depth >= 1000) return lookup_too_deep;
    if (path.len == 0) {
        parse.label_index = label_index;
        if (parse.edit != 0) {
            const span = nodeSpan(parse, root) orelse return lookup_error;
            if (parse.edit == edit_delete) {
                const first = if (label_index > 0) label_index else root;
                core.editBlob(parse, first, span + root - first, null, 0);
            } else if (parse.edit == edit_array_insert) {
                core.editBlob(parse, root, 0, parse.insertion, parse.insertion.len);
            } else if (parse.edit != edit_insert) core.editBlob(parse, root, span, parse.insertion, parse.insertion.len);
        }
        return root;
    }
    var size: u32 = 0;
    const header = core.payloadSize(parse, root, &size);
    if (header == 0) return lookup_error;
    if (path[0] == '.') {
        if ((parse.blob.items[root] & 15) != core.kind.object) return lookup_not_found;
        var key: []const u8 = undefined;
        var raw_key = true;
        const tail = parsePathKey(path, 1, &key, &raw_key) orelse return lookup_path_error;
        var index = root + header;
        const end = index + size;
        while (index < end) {
            var label_size: u32 = 0;
            const label_header = core.payloadSize(parse, index, &label_size);
            if (label_header == 0 or index + label_header + label_size >= end) return lookup_error;
            const label_type = parse.blob.items[index] & 15;
            if (label_type < core.kind.text or label_type > core.kind.text_raw) return lookup_error;
            const label = parse.blob.items[index + label_header .. index + label_header + label_size];
            const value_index = index + label_header + label_size;
            const span = nodeSpan(parse, value_index) orelse return lookup_error;
            if (value_index + span > end) return lookup_error;
            if (core.labelsEqual(key, raw_key, label, label_type == core.kind.text or label_type == core.kind.text_raw)) {
                parse.depth += 1;
                defer parse.depth -= 1;
                const result = lookupStep(parse, value_index, path[tail..], index);
                if (parse.delta != 0) core.adjustSizeAfterEdit(parse, root);
                return result;
            }
            index = value_index + span;
        }
        if (index != end) return lookup_error;
        if (parse.edit >= edit_insert and path[tail..].len == 0) {
            var label_parse = core.JsonParse.init(parse.allocator);
            defer label_parse.blob.deinit(parse.allocator);
            core.appendNode(&label_parse, if (raw_key) core.kind.text_raw else core.kind.text5, key, key.len);
            const total = label_parse.blob.items.len + parse.insertion.len;
            if (!core.makeBlobEditable(parse, total)) return lookup_error;
            const old_delta = parse.delta;
            core.editBlob(parse, end, 0, null, total);
            @memcpy(parse.blob.items[end .. end + label_parse.blob.items.len], label_parse.blob.items);
            @memcpy(parse.blob.items[end + label_parse.blob.items.len .. end + total], parse.insertion);
            parse.delta = old_delta + @as(i64, @intCast(total));
            core.adjustSizeAfterEdit(parse, root);
            return end + label_parse.blob.items.len;
        }
        return lookup_not_found;
    }
    if (path[0] == '[') {
        if ((parse.blob.items[root] & 15) != core.kind.array) return lookup_not_found;
        var cursor: usize = 1;
        var ordinal: u64 = 0;
        if (cursor < path.len and path[cursor] == '#') {
            ordinal = core.arrayCount(parse, root);
            cursor += 1;
            if (cursor < path.len and path[cursor] == '-') {
                cursor += 1;
                var amount: u64 = 0;
                const first = cursor;
                while (cursor < path.len and std.ascii.isDigit(path[cursor])) : (cursor += 1) amount = @min(0xffffffff, amount * 10 + path[cursor] - '0');
                if (cursor == first or amount > ordinal) return lookup_not_found;
                ordinal -= amount;
            }
        } else {
            const first = cursor;
            while (cursor < path.len and std.ascii.isDigit(path[cursor])) : (cursor += 1) ordinal = @min(0xffffffff, ordinal * 10 + path[cursor] - '0');
            if (cursor == first) return lookup_path_error;
        }
        if (cursor >= path.len or path[cursor] != ']') return lookup_path_error;
        var index = root + header;
        const end = index + size;
        while (index < end and ordinal > 0) : (ordinal -= 1) index += nodeSpan(parse, index) orelse return lookup_error;
        if (index > end) return lookup_error;
        if (index < end and ordinal == 0) {
            parse.depth += 1;
            defer parse.depth -= 1;
            const result = lookupStep(parse, index, path[cursor + 1 ..], 0);
            if (parse.delta != 0) core.adjustSizeAfterEdit(parse, root);
            return result;
        }
        if (index == end and ordinal == 0 and parse.edit >= edit_insert and path[cursor + 1 ..].len == 0) {
            core.editBlob(parse, end, 0, parse.insertion, parse.insertion.len);
            core.adjustSizeAfterEdit(parse, root);
            return end;
        }
        return lookup_not_found;
    }
    return lookup_path_error;
}

/// Source `jsonCreateEditSubstructure()`.
pub fn createEditSubstructure(parse: *core.JsonParse, tail: []const u8) text.Error!core.JsonParse {
    var inserted = core.JsonParse.init(parse.allocator);
    errdefer inserted.blob.deinit(parse.allocator);
    if (tail.len == 0) {
        inserted.blob.appendSlice(parse.allocator, parse.insertion) catch return error.OutOfMemory;
        return inserted;
    }
    core.expandAndAppendByte(&inserted, if (tail[0] == '.') core.kind.object else core.kind.array);
    inserted.edit = edit_set;
    inserted.insertion = parse.insertion;
    const result = lookupStep(&inserted, 0, tail, 0);
    if (result >= lookup_path_error) return if (result == lookup_too_deep) error.TooDeep else error.Malformed;
    return inserted;
}

/// Source `jsonFunctionArgToBlob()`.
pub fn functionArgumentToBlob(value: *types.Mem) text.Error!core.JsonParse {
    var parse = core.JsonParse.init(allocator());
    errdefer parse.blob.deinit(parse.allocator);
    switch (mem.valueType(value)) {
        5 => core.expandAndAppendByte(&parse, core.kind.null_),
        4 => {
            const bytes = blobSlice(value) orelse return error.Malformed;
            if (!text.argumentIsJsonb(&parse, bytes)) return error.Malformed;
        },
        3 => {
            const bytes = valueSlice(value) orelse return error.OutOfMemory;
            if (mem.valueSubtype(value) == json_subtype) try text.convertTextToBlob(&parse, bytes) else core.appendNode(&parse, core.kind.text_raw, bytes, bytes.len);
        },
        2 => {
            const bytes = valueSlice(value) orelse return error.OutOfMemory;
            core.appendNode(&parse, core.kind.float, bytes, bytes.len);
        },
        1 => {
            const bytes = valueSlice(value) orelse return error.OutOfMemory;
            core.appendNode(&parse, core.kind.int, bytes, bytes.len);
        },
        else => core.expandAndAppendByte(&parse, core.kind.null_),
    }
    if (parse.oom) return error.OutOfMemory;
    return parse;
}

/// Source `jsonParseFuncArg()`.
pub fn parseFunctionArgument(context: *types.Context, value: *types.Mem, editable: bool) text.Error!?core.JsonParse {
    if (mem.valueType(value) == 5) return null;
    if (cacheSearch(context, value)) |cached| {
        var parse = core.JsonParse.init(allocator());
        errdefer parse.blob.deinit(parse.allocator);
        parse.blob.appendSlice(parse.allocator, cached.blob.items) catch return error.OutOfMemory;
        parse.read_only = !editable;
        parse.has_nonstandard = cached.has_nonstandard;
        return parse;
    }
    var parse = core.JsonParse.init(allocator());
    errdefer parse.blob.deinit(parse.allocator);
    if (mem.valueType(value) == 4) {
        const bytes = blobSlice(value) orelse return error.Malformed;
        if (text.argumentIsJsonb(&parse, bytes)) {
            parse.read_only = !editable;
            return parse;
        }
    }
    const input = valueSlice(value) orelse return error.OutOfMemory;
    try text.convertTextToBlob(&parse, input);
    try cacheInsert(context, input, &parse);
    parse.read_only = !editable;
    return parse;
}

/// Source `jsonReturnFromBlob()`.
pub fn returnFromBlob(parse: *core.JsonParse, index: usize, context: *types.Context, mode: u8) void {
    var size: u32 = 0;
    const header = core.payloadSize(parse, index, &size);
    if (header == 0) {
        resultError(context, "malformed JSON");
        return;
    }
    const node_type = parse.blob.items[index] & 15;
    const payload = parse.blob.items[index + header .. index + header + size];
    switch (node_type) {
        core.kind.null_ => mem.resultNull(context),
        core.kind.true_ => mem.resultInt(context, 1),
        core.kind.false_ => mem.resultInt(context, 0),
        core.kind.int, core.kind.int5 => {
            const value = std.fmt.parseInt(i64, payload, if (node_type == core.kind.int5) 0 else 10) catch {
                const real = std.fmt.parseFloat(f64, payload) catch {
                    resultError(context, "malformed JSON");
                    return;
                };
                mem.resultDouble(context, real);
                return;
            };
            mem.resultInt64(context, value);
        },
        core.kind.float, core.kind.float5 => mem.resultDouble(context, std.fmt.parseFloat(f64, payload) catch {
            resultError(context, "malformed JSON");
            return;
        }),
        core.kind.text, core.kind.text_raw => mem.resultText(context, payload.ptr, @intCast(payload.len), .transient),
        core.kind.text_json, core.kind.text5 => {
            var output = std.ArrayList(u8).empty;
            defer output.deinit(allocator());
            var cursor: usize = 0;
            while (cursor < payload.len) if (payload[cursor] == '\\') {
                var codepoint: u32 = 0;
                const consumed = core.unescapeOne(payload[cursor..], &codepoint);
                cursor += consumed;
                if (codepoint != 0 and codepoint != 0x99999) {
                    var encoded: [4]u8 = undefined;
                    if (codepoint > 0x10ffff) continue;
                    const count = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
                    output.appendSlice(allocator(), encoded[0..count]) catch {
                        mem.resultErrorNoMem(context);
                        return;
                    };
                }
            } else {
                output.append(allocator(), payload[cursor]) catch {
                    mem.resultErrorNoMem(context);
                    return;
                };
                cursor += 1;
            };
            mem.resultText(context, output.items.ptr, @intCast(output.items.len), .transient);
        },
        core.kind.array, core.kind.object => if (mode == 2) mem.resultBlob(context, parse.blob.items[index..][0 .. header + size].ptr, @intCast(header + size), .transient) else {
            var output = core.JsonString.init(allocator());
            defer output.deinit();
            _ = text.translateBlobToText(parse, index, &output) catch |err| {
                operationError(context, err);
                return;
            };
            mem.resultText(context, output.bytes.items.ptr, @intCast(output.bytes.items.len), .transient);
            mem.resultSubtype(context, json_subtype);
        },
        else => resultError(context, "malformed JSON"),
    }
}

/// Source `jsonReturnParse()`.
pub fn returnParse(context: *types.Context, parse: *core.JsonParse, as_blob: bool) void {
    if (parse.oom) {
        mem.resultErrorNoMem(context);
        return;
    }
    if (as_blob) {
        mem.resultBlob(context, parse.blob.items.ptr, @intCast(parse.blob.items.len), .transient);
        return;
    }
    var output = core.JsonString.init(allocator());
    defer output.deinit();
    _ = text.translateBlobToText(parse, 0, &output) catch |err| {
        operationError(context, err);
        return;
    };
    mem.resultText(context, output.bytes.items.ptr, @intCast(output.bytes.items.len), .transient);
    mem.resultSubtype(context, json_subtype);
}

/// Source `jsonInsertIntoBlob()`.
pub fn insertIntoBlob(context: *types.Context, count: c_int, arguments: Arguments, edit: u8) void {
    var parsed = parseFunctionArgument(context, argument(arguments, 0), count > 1) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer parsed.blob.deinit(parsed.allocator);
    var index: usize = 1;
    while (index + 1 < @as(usize, @intCast(count))) : (index += 2) {
        if (mem.valueType(argument(arguments, index)) == 5) continue;
        const path = valueSlice(argument(arguments, index)) orelse {
            mem.resultErrorNoMem(context);
            return;
        };
        if (path.len == 0 or path[0] != '$') {
            resultError(context, "bad JSON path");
            return;
        }
        var insertion = functionArgumentToBlob(argument(arguments, index + 1)) catch |err| {
            operationError(context, err);
            return;
        };
        defer insertion.blob.deinit(insertion.allocator);
        if (path.len == 1) {
            if (edit == edit_replace or edit == edit_set) core.editBlob(&parsed, 0, parsed.blob.items.len, insertion.blob.items, insertion.blob.items.len);
        } else {
            parsed.edit = edit;
            parsed.insertion = insertion.blob.items;
            parsed.delta = 0;
            const result = lookupStep(&parsed, 0, path[1..], 0);
            if (result >= lookup_path_error and result != lookup_not_found) {
                resultError(context, "bad JSON path");
                return;
            }
        }
    }
    returnParse(context, &parsed, false);
}

/// Source `jsonQuoteFunc()`.
pub fn quoteFunction(context_optional: Context, _: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    var parse = functionArgumentToBlob(argument(arguments, 0)) catch |err| {
        operationError(context, err);
        return;
    };
    defer parse.blob.deinit(parse.allocator);
    returnParse(context, &parse, false);
}

/// Source `jsonArrayFunc()`.
pub fn arrayFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    var parse = core.JsonParse.init(allocator());
    defer parse.blob.deinit(parse.allocator);
    core.appendNode(&parse, core.kind.array, null, 0);
    const start = parse.blob.items.len;
    for (0..@intCast(count)) |index| {
        var item = functionArgumentToBlob(argument(arguments, index)) catch |err| {
            operationError(context, err);
            return;
        };
        defer item.blob.deinit(item.allocator);
        parse.blob.appendSlice(parse.allocator, item.blob.items) catch {
            mem.resultErrorNoMem(context);
            return;
        };
    }
    _ = core.changePayloadSize(&parse, 0, @intCast(parse.blob.items.len - start));
    returnParse(context, &parse, false);
}

/// Source `jsonObjectFunc()`.
pub fn objectFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    if (count & 1 != 0) {
        resultError(context, "json_object() requires an even number of arguments");
        return;
    }
    var parse = core.JsonParse.init(allocator());
    defer parse.blob.deinit(parse.allocator);
    core.appendNode(&parse, core.kind.object, null, 0);
    const start = parse.blob.items.len;
    var index: usize = 0;
    while (index < @as(usize, @intCast(count))) : (index += 2) {
        if (mem.valueType(argument(arguments, index)) != 3) {
            resultError(context, "json_object() labels must be TEXT");
            return;
        }
        const label = valueSlice(argument(arguments, index)) orelse {
            mem.resultErrorNoMem(context);
            return;
        };
        core.appendNode(&parse, core.kind.text_raw, label, label.len);
        var item = functionArgumentToBlob(argument(arguments, index + 1)) catch |err| {
            operationError(context, err);
            return;
        };
        defer item.blob.deinit(item.allocator);
        parse.blob.appendSlice(parse.allocator, item.blob.items) catch {
            mem.resultErrorNoMem(context);
            return;
        };
    }
    _ = core.changePayloadSize(&parse, 0, @intCast(parse.blob.items.len - start));
    returnParse(context, &parse, false);
}

/// Source `jsonArrayLengthFunc()`.
pub fn arrayLengthFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    var parsed = parseFunctionArgument(context, argument(arguments, 0), false) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer parsed.blob.deinit(parsed.allocator);
    var index: usize = 0;
    if (count == 2) {
        const path = valueSlice(argument(arguments, 1)) orelse return;
        if (path.len == 0 or path[0] != '$') {
            resultError(context, "bad JSON path");
            return;
        }
        index = lookupStep(&parsed, 0, path[1..], 0);
        if (index == lookup_not_found) {
            mem.resultInt64(context, 0);
            return;
        }
        if (index >= lookup_path_error) {
            resultError(context, "bad JSON path");
            return;
        }
    }
    mem.resultInt64(context, if ((parsed.blob.items[index] & 15) == core.kind.array) core.arrayCount(&parsed, index) else 0);
}

/// Source `jsonExtractFunc()`.
pub fn extractFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    if (count < 2) return;
    var parsed = parseFunctionArgument(context, argument(arguments, 0), false) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer parsed.blob.deinit(parsed.allocator);
    if (count == 2) {
        const path = valueSlice(argument(arguments, 1)) orelse return;
        if (path.len == 0 or path[0] != '$') {
            resultError(context, "bad JSON path");
            return;
        }
        const index = lookupStep(&parsed, 0, path[1..], 0);
        if (index == lookup_not_found) return;
        if (index >= lookup_path_error) {
            resultError(context, "bad JSON path");
            return;
        }
        returnFromBlob(&parsed, index, context, 0);
        return;
    }
    var output = core.JsonString.init(allocator());
    defer output.deinit();
    appendByteCompat(&output, '[') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    for (1..@intCast(count)) |argument_index| {
        if (argument_index > 1) appendByteCompat(&output, ',') catch {
            mem.resultErrorNoMem(context);
            return;
        };
        const path = valueSlice(argument(arguments, argument_index)) orelse return;
        const index = if (path.len > 0 and path[0] == '$') lookupStep(&parsed, 0, path[1..], 0) else lookup_path_error;
        if (index == lookup_not_found) {
            if (!core.expandAndAppendString(&output, "null")) {
                mem.resultErrorNoMem(context);
                return;
            }
        } else if (index >= lookup_path_error) {
            resultError(context, "bad JSON path");
            return;
        } else _ = text.translateBlobToText(&parsed, index, &output) catch |err| {
            operationError(context, err);
            return;
        };
    }
    appendByteCompat(&output, ']') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    returnString(context, &output, null);
}
fn appendByteCompat(output: *core.JsonString, byte: u8) !void {
    if (!core.growString(output, 1)) return error.OutOfMemory;
    output.bytes.appendAssumeCapacity(byte);
}

/// Source `jsonAppendSqlValue()`.
pub fn appendSqlValue(context: *types.Context, output: *core.JsonString, value: *types.Mem) text.Error!void {
    var parse = try functionArgumentToBlob(value);
    defer parse.blob.deinit(parse.allocator);
    _ = text.translateBlobToText(&parse, 0, output) catch |err| {
        operationError(context, err);
        return err;
    };
}

/// Source `jsonReturnString()`.
pub fn returnString(context: *types.Context, output: *core.JsonString, parse_optional: ?*const core.JsonParse) void {
    if (output.malformed) {
        resultError(context, "malformed JSON");
        output.bytes.clearRetainingCapacity();
        return;
    }
    if (output.too_deep) {
        resultError(context, "JSON nested too deep");
        output.bytes.clearRetainingCapacity();
        return;
    }
    if (parse_optional) |parse| cacheInsert(context, output.bytes.items, parse) catch {
        mem.resultErrorNoMem(context);
        output.bytes.clearRetainingCapacity();
        return;
    };
    const flags: usize = if (mem.userData(context)) |data| @intFromPtr(data) else 0;
    if (flags & 0x10 != 0) {
        const blob = text.returnStringAsBlob(output.allocator, output.bytes.items) catch |err| {
            operationError(context, err);
            output.bytes.clearRetainingCapacity();
            return;
        };
        resultOwnedBlob(context, blob);
    } else {
        mem.resultText(context, output.bytes.items.ptr, @intCast(output.bytes.items.len), .transient);
        mem.resultSubtype(context, json_subtype);
    }
    output.bytes.clearRetainingCapacity();
}

/// Source `jsonTypeFunc()`.
pub fn typeFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const names = [_][]const u8{ "null", "true", "false", "integer", "integer", "real", "real", "text", "text", "text", "text", "array", "object" };
    const context = context_optional.?;
    var parsed = parseFunctionArgument(context, argument(arguments, 0), false) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer parsed.blob.deinit(parsed.allocator);
    var index: usize = 0;
    if (count == 2) {
        const path = valueSlice(argument(arguments, 1)) orelse return;
        if (path.len == 0 or path[0] != '$') {
            resultError(context, "bad JSON path");
            return;
        }
        index = lookupStep(&parsed, 0, path[1..], 0);
        if (index == lookup_not_found) return;
        if (index >= lookup_path_error) {
            resultError(context, "bad JSON path");
            return;
        }
    }
    const name = names[parsed.blob.items[index] & 15];
    mem.resultText(context, name.ptr, @intCast(name.len), .transient);
}

/// Source `jsonPrettyFunc()`.
pub fn prettyFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    var parsed = parseFunctionArgument(context, argument(arguments, 0), false) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer parsed.blob.deinit(parsed.allocator);
    const indent = if (count == 2) valueSlice(argument(arguments, 1)) orelse "    " else "    ";
    var output = core.JsonString.init(allocator());
    defer output.deinit();
    _ = text.translateBlobToPrettyText(&parsed, 0, &output, indent, 0) catch |err| {
        operationError(context, err);
        return;
    };
    returnString(context, &output, null);
}

/// Source `jsonValidFunc()`.
pub fn validFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    if (mem.valueType(argument(arguments, 0)) == 5) return;
    const flags: i64 = if (count == 2) mem.valueInt64(argument(arguments, 1)) else 1;
    if (flags < 1 or flags > 15) {
        resultError(context, "FLAGS parameter to json_valid() must be between 1 and 15");
        return;
    }
    var valid = false;
    if (mem.valueType(argument(arguments, 0)) == 4 and flags & 12 != 0) {
        var parsed = core.JsonParse.init(allocator());
        defer parsed.blob.deinit(parsed.allocator);
        const bytes = blobSlice(argument(arguments, 0)) orelse return;
        if (text.argumentIsJsonb(&parsed, bytes)) valid = flags & 4 != 0 or text.validityCheck(&parsed, 0, bytes.len, 1) == 0;
    }
    if (!valid and flags & 3 != 0) {
        var parsed = core.JsonParse.init(allocator());
        defer parsed.blob.deinit(parsed.allocator);
        const input = valueSlice(argument(arguments, 0)) orelse return;
        text.convertTextToBlob(&parsed, input) catch {
            mem.resultInt(context, 0);
            return;
        };
        valid = flags & 2 != 0 or !parsed.has_nonstandard;
    }
    mem.resultInt(context, @intFromBool(valid));
}

/// Source `jsonErrorFunc()`.
pub fn errorPositionFunction(context_optional: Context, _: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    if (mem.valueType(argument(arguments, 0)) == 5) return;
    var parsed = core.JsonParse.init(allocator());
    defer parsed.blob.deinit(parsed.allocator);
    if (mem.valueType(argument(arguments, 0)) == 4) {
        const bytes = blobSlice(argument(arguments, 0)) orelse return;
        if (text.argumentIsJsonb(&parsed, bytes)) {
            mem.resultInt64(context, @intCast(text.validityCheck(&parsed, 0, bytes.len, 1)));
            return;
        }
    }
    const input = valueSlice(argument(arguments, 0)) orelse return;
    text.convertTextToBlob(&parsed, input) catch {
        var characters: i64 = 1;
        for (input[0..@min(input.len, parsed.error_index)]) |byte| if (byte & 0xc0 != 0x80) {
            characters += 1;
        };
        mem.resultInt64(context, characters);
        return;
    };
    mem.resultInt64(context, 0);
}

/// Source `jsonRemoveFunc()`.
pub fn removeFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    var parsed = parseFunctionArgument(context, argument(arguments, 0), count > 1) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer parsed.blob.deinit(parsed.allocator);
    for (1..@intCast(count)) |index| {
        const path = valueSlice(argument(arguments, index)) orelse return;
        if (path.len == 1 and path[0] == '$') return;
        if (path.len == 0 or path[0] != '$') {
            resultError(context, "bad JSON path");
            return;
        }
        parsed.edit = edit_delete;
        parsed.delta = 0;
        const result = lookupStep(&parsed, 0, path[1..], 0);
        if (result >= lookup_path_error and result != lookup_not_found) {
            resultError(context, "bad JSON path");
            return;
        }
    }
    returnParse(context, &parsed, false);
}

/// SQL callback for JSON replacement after argument validation.
pub fn replaceFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    if (count < 1) return;
    if (count & 1 == 0) {
        resultError(context, "json_replace() needs an odd number of arguments");
        return;
    }
    insertIntoBlob(context, count, arguments, edit_replace);
}

/// SQL callback for JSON set after argument validation.
pub fn setFunction(context_optional: Context, count: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    if (count < 1) return;
    if (count & 1 == 0) {
        resultError(context, "json_set() needs an odd number of arguments");
        return;
    }
    insertIntoBlob(context, count, arguments, edit_set);
}

/// Source `jsonMergePatch()`.
pub fn mergePatch(target: *core.JsonParse, target_index: usize, patch: *const core.JsonParse, patch_index: usize, depth: usize) text.Error!void {
    if (depth >= 1000) return error.TooDeep;
    const patch_span = nodeSpan(patch, patch_index) orelse return error.Malformed;
    if ((patch.blob.items[patch_index] & 15) != core.kind.object) {
        const target_span = nodeSpan(target, target_index) orelse return error.Malformed;
        core.editBlob(target, target_index, target_span, patch.blob.items[patch_index..][0..patch_span], patch_span);
        return;
    }
    if ((target.blob.items[target_index] & 15) != core.kind.object) {
        const target_span = nodeSpan(target, target_index) orelse return error.Malformed;
        core.editBlob(target, target_index, target_span, &.{core.kind.object}, 1);
    }
    var patch_size: u32 = 0;
    const patch_header = core.payloadSize(patch, patch_index, &patch_size);
    var cursor = patch_index + patch_header;
    const end = cursor + patch_size;
    while (cursor < end) {
        var label_size: u32 = 0;
        const label_header = core.payloadSize(patch, cursor, &label_size);
        if (label_header == 0) return error.Malformed;
        const label_type = patch.blob.items[cursor] & 15;
        const label = patch.blob.items[cursor + label_header .. cursor + label_header + label_size];
        const value_index = cursor + label_header + label_size;
        const value_span = nodeSpan(patch, value_index) orelse return error.Malformed;
        cursor = value_index + value_span;
        var target_size: u32 = 0;
        const target_header = core.payloadSize(target, target_index, &target_size);
        var target_cursor = target_index + target_header;
        const target_end: usize = @intCast(@as(i64, @intCast(target_cursor + target_size)) + target.delta);
        var match: ?struct { label: usize, value: usize, span: usize } = null;
        while (target_cursor < target_end) {
            var candidate_size: u32 = 0;
            const candidate_header = core.payloadSize(target, target_cursor, &candidate_size);
            if (candidate_header == 0) return error.Malformed;
            const candidate_type = target.blob.items[target_cursor] & 15;
            const candidate = target.blob.items[target_cursor + candidate_header .. target_cursor + candidate_header + candidate_size];
            const candidate_value = target_cursor + candidate_header + candidate_size;
            const candidate_span = nodeSpan(target, candidate_value) orelse return error.Malformed;
            if (core.labelsEqual(label, label_type == core.kind.text or label_type == core.kind.text_raw, candidate, candidate_type == core.kind.text or candidate_type == core.kind.text_raw)) {
                match = .{ .label = target_cursor, .value = candidate_value, .span = candidate_span };
                break;
            }
            target_cursor = candidate_value + candidate_span;
        }
        if (match) |found| {
            if ((patch.blob.items[value_index] & 15) == core.kind.null_) core.editBlob(target, found.label, found.value + found.span - found.label, null, 0) else try mergePatch(target, found.value, patch, value_index, depth + 1);
        } else if ((patch.blob.items[value_index] & 15) != core.kind.null_) {
            const insert_size = label_header + label_size + value_span;
            core.editBlob(target, target_end, 0, null, insert_size);
            @memcpy(target.blob.items[target_end .. target_end + label_header + label_size], patch.blob.items[cursor - value_span - label_size - label_header .. cursor - value_span]);
            @memcpy(target.blob.items[target_end + label_header + label_size .. target_end + insert_size], patch.blob.items[value_index..][0..value_span]);
        }
    }
    if (target.delta != 0) core.adjustSizeAfterEdit(target, target_index);
}

/// Source `jsonPatchFunc()`.
pub fn patchFunction(context_optional: Context, _: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    var target = parseFunctionArgument(context, argument(arguments, 0), true) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer target.blob.deinit(target.allocator);
    var patch = parseFunctionArgument(context, argument(arguments, 1), false) catch |err| {
        operationError(context, err);
        return;
    } orelse return;
    defer patch.blob.deinit(patch.allocator);
    mergePatch(&target, 0, &patch, 0, 0) catch |err| {
        operationError(context, err);
        return;
    };
    returnParse(context, &target, false);
}

const JsonArrayAggregate = struct {
    initialized: bool,
    output: core.JsonString,
};

/// Source `jsonArrayStep()`.
pub fn arrayAggregateStep(context_optional: Context, _: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    const storage = mem.aggregateContext(context, @sizeOf(JsonArrayAggregate)) orelse return;
    const aggregate: *JsonArrayAggregate = @ptrCast(@alignCast(storage));
    if (!aggregate.initialized) {
        aggregate.* = .{ .initialized = true, .output = core.JsonString.init(allocator()) };
        appendByteCompat(&aggregate.output, '[') catch {
            mem.resultErrorNoMem(context);
            return;
        };
    } else if (aggregate.output.bytes.items.len > 1) appendByteCompat(&aggregate.output, ',') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    appendSqlValue(context, &aggregate.output, argument(arguments, 0)) catch return;
}

/// Source `jsonArrayCompute()`.
pub fn arrayAggregateCompute(context_optional: Context, final: bool) void {
    const context = context_optional.?;
    const storage = mem.aggregateContext(context, 0);
    if (storage == null) {
        mem.resultText(context, "[]".ptr, 2, .static);
        mem.resultSubtype(context, json_subtype);
        return;
    }
    const aggregate: *JsonArrayAggregate = @ptrCast(@alignCast(storage.?));
    appendByteCompat(&aggregate.output, ']') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    mem.resultText(context, aggregate.output.bytes.items.ptr, @intCast(aggregate.output.bytes.items.len), .transient);
    mem.resultSubtype(context, json_subtype);
    if (final) {
        aggregate.output.deinit();
        aggregate.initialized = false;
    } else {
        aggregate.output.bytes.items.len -= 1;
    }
}

pub fn arrayAggregateValue(context: Context) callconv(.c) void {
    arrayAggregateCompute(context, false);
}

pub fn arrayAggregateFinal(context: Context) callconv(.c) void {
    arrayAggregateCompute(context, true);
}

/// Source `jsonGroupInverse()`.
pub fn groupInverse(context_optional: Context, _: c_int, _: Arguments) callconv(.c) void {
    const context = context_optional.?;
    const storage = mem.aggregateContext(context, 0) orelse return;
    const aggregate: *JsonArrayAggregate = @ptrCast(@alignCast(storage));
    var index: usize = 1;
    var in_string = false;
    var nesting: i32 = 0;
    while (index < aggregate.output.bytes.items.len) : (index += 1) {
        const byte = aggregate.output.bytes.items[index];
        if (byte == ',' and !in_string and nesting == 0) break;
        if (byte == '"') {
            in_string = !in_string;
        } else if (byte == '\\') {
            if (index + 1 < aggregate.output.bytes.items.len) index += 1;
        } else if (!in_string) {
            if (byte == '{' or byte == '[') nesting += 1;
            if (byte == '}' or byte == ']') nesting -= 1;
        }
    }
    if (index < aggregate.output.bytes.items.len) {
        const old_length = aggregate.output.bytes.items.len;
        const new_length = old_length - index;
        std.mem.copyForwards(u8, aggregate.output.bytes.items[1..new_length], aggregate.output.bytes.items[index + 1 .. old_length]);
        aggregate.output.bytes.items.len = new_length;
    } else {
        aggregate.output.bytes.items.len = @min(1, aggregate.output.bytes.items.len);
    }
}

const JsonObjectAggregate = struct {
    initialized: bool,
    output: core.JsonString,
};

/// Source `jsonObjectStep()`.
pub fn objectAggregateStep(context_optional: Context, _: c_int, arguments: Arguments) callconv(.c) void {
    const context = context_optional.?;
    const storage = mem.aggregateContext(context, @sizeOf(JsonObjectAggregate)) orelse return;
    const aggregate: *JsonObjectAggregate = @ptrCast(@alignCast(storage));
    if (!aggregate.initialized) {
        aggregate.* = .{ .initialized = true, .output = core.JsonString.init(allocator()) };
        appendByteCompat(&aggregate.output, '{') catch {
            mem.resultErrorNoMem(context);
            return;
        };
    }
    const label = valueSlice(argument(arguments, 0)) orelse return;
    if (aggregate.output.bytes.items.len > 1) appendByteCompat(&aggregate.output, ',') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    if (!core.appendQuotedString(&aggregate.output, label)) {
        mem.resultErrorNoMem(context);
        return;
    }
    appendByteCompat(&aggregate.output, ':') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    appendSqlValue(context, &aggregate.output, argument(arguments, 1)) catch return;
}

/// Source `jsonObjectCompute()`.
pub fn objectAggregateCompute(context_optional: Context, final: bool) void {
    const context = context_optional.?;
    const storage = mem.aggregateContext(context, 0);
    if (storage == null) {
        mem.resultText(context, "{}".ptr, 2, .static);
        mem.resultSubtype(context, json_subtype);
        return;
    }
    const aggregate: *JsonObjectAggregate = @ptrCast(@alignCast(storage.?));
    appendByteCompat(&aggregate.output, '}') catch {
        mem.resultErrorNoMem(context);
        return;
    };
    mem.resultText(context, aggregate.output.bytes.items.ptr, @intCast(aggregate.output.bytes.items.len), .transient);
    mem.resultSubtype(context, json_subtype);
    if (final) {
        aggregate.output.deinit();
        aggregate.initialized = false;
    } else {
        aggregate.output.bytes.items.len -= 1;
    }
}

pub fn objectAggregateValue(context: Context) callconv(.c) void {
    objectAggregateCompute(context, false);
}

pub fn objectAggregateFinal(context: Context) callconv(.c) void {
    objectAggregateCompute(context, true);
}
