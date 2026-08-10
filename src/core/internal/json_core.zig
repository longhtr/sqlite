//! SQLite JSONB storage, escaping, and path primitives from `json.c`.

const std = @import("std");

pub const kind = struct {
    pub const null_: u8 = 0;
    pub const true_: u8 = 1;
    pub const false_: u8 = 2;
    pub const int: u8 = 3;
    pub const int5: u8 = 4;
    pub const float: u8 = 5;
    pub const float5: u8 = 6;
    pub const text: u8 = 7;
    pub const text_json: u8 = 8;
    pub const text5: u8 = 9;
    pub const text_raw: u8 = 10;
    pub const array: u8 = 11;
    pub const object: u8 = 12;
};

pub const JsonString = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8),
    malformed: bool = false,
    too_deep: bool = false,

    pub fn init(allocator: std.mem.Allocator) JsonString {
        return .{ .allocator = allocator, .bytes = .empty };
    }
    pub fn deinit(self: *JsonString) void {
        self.bytes.deinit(self.allocator);
    }
};

pub const JsonParse = struct {
    allocator: std.mem.Allocator,
    blob: std.ArrayList(u8),
    read_only: bool = false,
    oom: bool = false,
    delta: i64 = 0,
    depth: u16 = 0,
    error_index: u32 = 0,
    has_nonstandard: bool = false,
    edit: u8 = 0,
    insertion: []const u8 = &.{},
    label_index: usize = 0,
    references: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) JsonParse {
        return .{ .allocator = allocator, .blob = .empty };
    }
};

/// Source `jsonParseReset()`.
pub fn resetParse(parse: *JsonParse) void {
    const allocator = parse.allocator;
    std.debug.assert(parse.references <= 1);
    parse.blob.deinit(allocator);
    parse.* = JsonParse.init(allocator);
}

/// Source `jsonParseFree()`.
pub fn freeParse(parse_optional: ?*JsonParse) void {
    const parse = parse_optional orelse return;
    if (parse.references > 1) {
        parse.references -= 1;
        return;
    }
    const allocator = parse.allocator;
    resetParse(parse);
    allocator.destroy(parse);
}

pub const JsonParent = struct { head: u32 = 0, value: u32 = 0, end: u32 = 0, path_length: u32 = 0, key: i64 = 0 };
pub const JsonCursor = struct { parse: *JsonParse, index: u32, end: u32, container_type: u8, parents: []JsonParent, parent_count: u32, path: JsonString };

/// Source `json5Whitespace()`.
pub fn json5Whitespace(input: [*:0]const u8) usize {
    var n: usize = 0;
    while (true) switch (input[n]) {
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20 => n += 1,
        '/' => {
            if (input[n + 1] == '*' and input[n + 2] != 0) {
                var j = n + 3;
                while (input[j] != 0 and (input[j] != '/' or input[j - 1] != '*')) : (j += 1) {}
                if (input[j] == 0) return n;
                n = j + 1;
            } else if (input[n + 1] == '/') {
                var j = n + 2;
                while (input[j] != 0 and input[j] != '\n' and input[j] != '\r') : (j += 1) {
                    if (input[j] == 0xe2 and input[j + 1] == 0x80 and (input[j + 2] == 0xa8 or input[j + 2] == 0xa9)) {
                        j += 2;
                        break;
                    }
                }
                n = j + @intFromBool(input[j] != 0);
            } else return n;
        },
        0xc2 => if (input[n + 1] == 0xa0) {
            n += 2;
        } else return n,
        0xe1 => if (input[n + 1] == 0x9a and input[n + 2] == 0x80) {
            n += 3;
        } else return n,
        0xe2 => if ((input[n + 1] == 0x80 and (input[n + 2] <= 0x8a or input[n + 2] == 0xa8 or input[n + 2] == 0xa9 or input[n + 2] == 0xaf)) or (input[n + 1] == 0x81 and input[n + 2] == 0x9f)) {
            n += 3;
        } else return n,
        0xe3 => if (input[n + 1] == 0x80 and input[n + 2] == 0x80) {
            n += 3;
        } else return n,
        0xef => if (input[n + 1] == 0xbb and input[n + 2] == 0xbf) {
            n += 3;
        } else return n,
        else => return n,
    };
}

/// Source `jsonStringGrow()`.
pub fn growString(output: *JsonString, additional: usize) bool {
    output.bytes.ensureUnusedCapacity(output.allocator, additional) catch return false;
    return true;
}

/// Source `jsonStringExpandAndAppend()`.
pub fn expandAndAppendString(output: *JsonString, input: []const u8) bool {
    if (input.len == 0 or !growString(output, input.len)) return input.len == 0;
    output.bytes.appendSliceAssumeCapacity(input);
    return true;
}

/// Source `jsonAppendControlChar()`.
pub fn appendControlCharacter(output: *JsonString, byte: u8) bool {
    const special = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 'b', 't', 'n', 0, 'f', 'r', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    if (!growString(output, 6)) return false;
    if (special[byte] != 0) {
        output.bytes.appendSliceAssumeCapacity(&.{ '\\', special[byte] });
    } else {
        output.bytes.appendSliceAssumeCapacity(&.{ '\\', 'u', '0', '0', "0123456789abcdef"[byte >> 4], "0123456789abcdef"[byte & 15] });
    }
    return true;
}

fn ordinaryJsonByte(byte: u8) bool {
    return byte >= 0x20 and byte != '"' and byte != '\\';
}

/// Source `jsonAppendString()`.
pub fn appendQuotedString(output: *JsonString, input: []const u8) bool {
    if (!growString(output, input.len + 2)) return false;
    output.bytes.appendAssumeCapacity('"');
    for (input) |byte| {
        if (ordinaryJsonByte(byte)) output.bytes.appendAssumeCapacity(byte) else if (byte == '"' or byte == '\\') {
            if (!growString(output, 2)) return false;
            output.bytes.appendSliceAssumeCapacity(&.{ '\\', byte });
        } else if (!appendControlCharacter(output, byte)) return false;
    }
    output.bytes.appendAssumeCapacity('"');
    return true;
}

/// Source `jsonBlobExpand()`.
pub fn expandBlob(parse: *JsonParse, needed: usize) bool {
    if (parse.blob.capacity >= needed) return true;
    parse.blob.ensureTotalCapacity(parse.allocator, @max(needed + 100, @max(100, parse.blob.capacity * 2))) catch {
        parse.oom = true;
        return false;
    };
    return true;
}

/// Source `jsonBlobMakeEditable()`.
pub fn makeBlobEditable(parse: *JsonParse, extra: usize) bool {
    if (parse.oom or parse.read_only) return false;
    return expandBlob(parse, parse.blob.items.len + extra);
}

/// Source `jsonBlobExpandAndAppendOneByte()`.
pub fn expandAndAppendByte(parse: *JsonParse, byte: u8) void {
    if (!expandBlob(parse, parse.blob.items.len + 1)) return;
    parse.blob.appendAssumeCapacity(byte);
}

/// Source `jsonBlobAppendNode()`.
pub fn appendNode(parse: *JsonParse, node_type: u8, payload: ?[]const u8, payload_size: u64) void {
    if (!expandBlob(parse, parse.blob.items.len + @as(usize, @intCast(payload_size)) + 9)) return;
    if (payload_size <= 11) parse.blob.appendAssumeCapacity(node_type | @as(u8, @intCast(payload_size << 4))) else if (payload_size <= 0xff) {
        parse.blob.appendSliceAssumeCapacity(&.{ node_type | 0xc0, @intCast(payload_size) });
    } else if (payload_size <= 0xffff) {
        parse.blob.appendSliceAssumeCapacity(&.{ node_type | 0xd0, @intCast(payload_size >> 8), @intCast(payload_size) });
    } else {
        parse.blob.appendSliceAssumeCapacity(&.{ node_type | 0xe0, @intCast(payload_size >> 24), @intCast(payload_size >> 16), @intCast(payload_size >> 8), @intCast(payload_size) });
    }
    if (payload) |bytes| parse.blob.appendSliceAssumeCapacity(bytes);
}

/// Source `jsonbPayloadSize()`.
pub fn payloadSize(parse: *const JsonParse, index: usize, size: *u32) usize {
    if (index >= parse.blob.items.len) {
        size.* = 0;
        return 0;
    }
    const bytes = parse.blob.items;
    const code = bytes[index] >> 4;
    const header: usize = switch (code) {
        0...11 => 1,
        12 => 2,
        13 => 3,
        14 => 5,
        15 => 9,
        else => unreachable,
    };
    if (index + header > bytes.len) {
        size.* = 0;
        return 0;
    }
    size.* = switch (code) {
        0...11 => code,
        12 => bytes[index + 1],
        13 => (@as(u32, bytes[index + 1]) << 8) | bytes[index + 2],
        14 => std.mem.readInt(u32, bytes[index + 1 ..][0..4], .big),
        15 => if (bytes[index + 1] | bytes[index + 2] | bytes[index + 3] | bytes[index + 4] != 0) {
            size.* = 0;
            return 0;
        } else std.mem.readInt(u32, bytes[index + 5 ..][0..4], .big),
        else => unreachable,
    };
    if (index + header + size.* > bytes.len and @as(i64, @intCast(index + header + size.*)) > @as(i64, @intCast(bytes.len)) - parse.delta) {
        size.* = 0;
        return 0;
    }
    return header;
}

/// Source `jsonBlobChangePayloadSize()`.
pub fn changePayloadSize(parse: *JsonParse, index: usize, new_payload_size: u32) i32 {
    if (parse.oom or index >= parse.blob.items.len) return 0;
    const old_code = parse.blob.items[index] >> 4;
    const old_extra: usize = switch (old_code) {
        0...11 => 0,
        12 => 1,
        13 => 2,
        14 => 4,
        15 => 8,
        else => unreachable,
    };
    const needed: usize = if (new_payload_size <= 11) 0 else if (new_payload_size <= 0xff) 1 else if (new_payload_size <= 0xffff) 2 else 4;
    const delta: i32 = @intCast(@as(i64, @intCast(needed)) - @as(i64, @intCast(old_extra)));
    if (delta > 0) {
        const old_len = parse.blob.items.len;
        if (!expandBlob(parse, old_len + @as(usize, @intCast(delta)))) return 0;
        parse.blob.items.len += @intCast(delta);
        std.mem.copyBackwards(u8, parse.blob.items[index + 1 + @as(usize, @intCast(delta)) ..], parse.blob.items[index + 1 .. old_len]);
    } else if (delta < 0) {
        const remove: usize = @intCast(-delta);
        std.mem.copyForwards(u8, parse.blob.items[index + 1 ..], parse.blob.items[index + 1 + remove ..]);
        parse.blob.items.len -= remove;
    }
    const low = parse.blob.items[index] & 15;
    if (needed == 0) parse.blob.items[index] = low | @as(u8, @intCast(new_payload_size << 4)) else {
        parse.blob.items[index] = low | @as(u8, if (needed == 1) 0xc0 else if (needed == 2) 0xd0 else 0xe0);
        var value = new_payload_size;
        var cursor = index + 1 + needed;
        while (cursor > index + 1) {
            cursor -= 1;
            parse.blob.items[cursor] = @intCast(value);
            value >>= 8;
        }
    }
    return delta;
}

/// Source `jsonbArrayCount()`.
pub fn arrayCount(parse: *const JsonParse, root: usize) u32 {
    var size: u32 = 0;
    var header = payloadSize(parse, root, &size);
    const end = root + header + size;
    var index = root + header;
    var count: u32 = 0;
    while (header > 0 and index < end) : (count += 1) {
        header = payloadSize(parse, index, &size);
        index += header + size;
    }
    return count;
}

/// Source `jsonAfterEditSizeAdjust()`.
pub fn adjustSizeAfterEdit(parse: *JsonParse, root: usize) void {
    var size: u32 = 0;
    const saved_len = parse.blob.items.len;
    parse.blob.items.len = parse.blob.capacity;
    _ = payloadSize(parse, root, &size);
    parse.blob.items.len = saved_len;
    const adjusted: u32 = @intCast(@as(i64, size) + parse.delta);
    parse.delta += changePayloadSize(parse, root, adjusted);
}

/// Source `jsonBlobOverwrite()`.
pub fn overwriteExpanded(output: []u8, input: []const u8, expansion: u32) bool {
    if (input.len == 0 or (input[0] & 15) <= kind.false_) return false;
    const old_header: usize = switch (input[0] >> 4) {
        0...11 => 1,
        12 => 2,
        13 => 3,
        14 => 5,
        15 => return false,
        else => unreachable,
    };
    const new_header = old_header + expansion;
    if (new_header != 2 and new_header != 3 and new_header != 5 and new_header != 9) return false;
    if (output.len < input.len + expansion) return false;
    output[0] = (input[0] & 15) | @as(u8, switch (new_header) {
        2 => 0xc0,
        3 => 0xd0,
        5 => 0xe0,
        9 => 0xf0,
        else => unreachable,
    });
    @memcpy(output[new_header .. new_header + input.len - old_header], input[old_header..]);
    var payload_size: u64 = input.len - old_header;
    var cursor = new_header;
    while (cursor > 1) {
        cursor -= 1;
        output[cursor] = @intCast(payload_size);
        payload_size >>= 8;
    }
    return true;
}

/// Source `jsonBlobEdit()`.
pub fn editBlob(parse: *JsonParse, delete_index: usize, delete_count: usize, insert: ?[]const u8, insert_count: usize) void {
    const difference: i64 = @as(i64, @intCast(insert_count)) - @as(i64, @intCast(delete_count));
    if (difference < 0 and difference >= -8 and insert != null and overwriteExpanded(parse.blob.items[delete_index .. delete_index + delete_count], insert.?, @intCast(-difference))) return;
    if (difference > 0) {
        const old_len = parse.blob.items.len;
        if (!expandBlob(parse, @intCast(@as(i64, @intCast(old_len)) + difference))) return;
        parse.blob.items.len += @intCast(difference);
        std.mem.copyBackwards(u8, parse.blob.items[delete_index + insert_count ..], parse.blob.items[delete_index + delete_count .. old_len]);
    } else if (difference < 0) {
        std.mem.copyForwards(u8, parse.blob.items[delete_index + insert_count ..], parse.blob.items[delete_index + delete_count ..]);
        parse.blob.items.len -= @intCast(-difference);
    }
    parse.delta += difference;
    if (insert) |bytes| @memcpy(parse.blob.items[delete_index .. delete_index + insert_count], bytes[0..insert_count]);
}

/// Source `jsonBytesToBypass()`.
pub fn escapedNewlineBytes(input: []const u8) usize {
    var index: usize = 0;
    while (index + 1 < input.len and input[index] == '\\') {
        if (input[index + 1] == '\n') index += 2 else if (input[index + 1] == '\r') index += if (index + 2 < input.len and input[index + 2] == '\n') 3 else 2 else if (input[index + 1] == 0xe2 and index + 3 < input.len and input[index + 2] == 0x80 and (input[index + 3] == 0xa8 or input[index + 3] == 0xa9)) index += 4 else break;
    }
    return index;
}

fn hex(byte: u8) u32 {
    return if (byte <= '9') byte - '0' else (byte | 0x20) - 'a' + 10;
}

/// Source `jsonUnescapeOneChar()`.
pub fn unescapeOne(input: []const u8, output: *u32) usize {
    const invalid = 0x99999;
    if (input.len < 2 or input[0] != '\\') {
        output.* = invalid;
        return input.len;
    }
    switch (input[1]) {
        'u' => {
            if (input.len < 6) {
                output.* = invalid;
                return input.len;
            }
            var value = (hex(input[2]) << 12) | (hex(input[3]) << 8) | (hex(input[4]) << 4) | hex(input[5]);
            if (value & 0xfc00 == 0xd800 and input.len >= 12 and input[6] == '\\' and input[7] == 'u') {
                const low = (hex(input[8]) << 12) | (hex(input[9]) << 8) | (hex(input[10]) << 4) | hex(input[11]);
                if (low & 0xfc00 == 0xdc00) {
                    value = ((value & 0x3ff) << 10) + (low & 0x3ff) + 0x10000;
                    output.* = value;
                    return 12;
                }
            }
            output.* = value;
            return 6;
        },
        'b' => output.* = 0x08,
        'f' => output.* = 0x0c,
        'n' => output.* = '\n',
        'r' => output.* = '\r',
        't' => output.* = '\t',
        'v' => output.* = 0x0b,
        '0' => output.* = if (input.len > 2 and std.ascii.isDigit(input[2])) invalid else 0,
        '\'', '"', '/', '\\' => output.* = input[1],
        'x' => {
            if (input.len < 4) {
                output.* = invalid;
                return input.len;
            }
            output.* = (hex(input[2]) << 4) | hex(input[3]);
            return 4;
        },
        '\r', '\n', 0xe2 => {
            const skipped = escapedNewlineBytes(input);
            if (skipped == 0) {
                output.* = invalid;
                return input.len;
            }
            if (skipped == input.len) {
                output.* = 0;
                return skipped;
            }
            if (input[skipped] == '\\') return skipped + unescapeOne(input[skipped..], output);
            const sequence_length = std.unicode.utf8ByteSequenceLength(input[skipped]) catch {
                output.* = invalid;
                return skipped + 1;
            };
            output.* = std.unicode.utf8Decode(input[skipped..][0..sequence_length]) catch invalid;
            return skipped + sequence_length;
        },
        else => output.* = invalid,
    }
    return 2;
}

fn nextLabelCodepoint(text: *[]const u8, raw: bool) u32 {
    if (text.*.len == 0) return 0;
    if (!raw and text.*[0] == '\\') {
        var value: u32 = 0;
        const count = unescapeOne(text.*, &value);
        text.* = text.*[count..];
        return value;
    }
    const decoded = std.unicode.utf8Decode(text.*[0 .. std.unicode.utf8ByteSequenceLength(text.*[0]) catch 1]) catch text.*[0];
    text.* = text.*[(std.unicode.utf8ByteSequenceLength(text.*[0]) catch 1)..];
    return decoded;
}

/// Source `jsonLabelCompareEscaped()`.
pub fn escapedLabelsEqual(left_initial: []const u8, raw_left: bool, right_initial: []const u8, raw_right: bool) bool {
    var left = left_initial;
    var right = right_initial;
    while (true) {
        const a = nextLabelCodepoint(&left, raw_left);
        const b = nextLabelCodepoint(&right, raw_right);
        if (a != b) return false;
        if (a == 0) return true;
    }
}

/// Source `jsonLabelCompare()`.
pub fn labelsEqual(left: []const u8, raw_left: bool, right: []const u8, raw_right: bool) bool {
    if (raw_left and raw_right) return std.mem.eql(u8, left, right);
    return escapedLabelsEqual(left, raw_left, right, raw_right);
}

/// Source `jsonSkipLabel()`.
pub fn skipCursorLabel(cursor: *const JsonCursor) usize {
    if (cursor.container_type != kind.object) return cursor.index;
    var size: u32 = 0;
    const header = payloadSize(cursor.parse, cursor.index, &size);
    const result = cursor.index + header + size;
    return if (result >= cursor.parse.blob.items.len) cursor.index else result;
}
