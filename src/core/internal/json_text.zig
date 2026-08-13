//! JSON text/JSONB translation and validation from SQLite `json.c`.

const std = @import("std");
const core = @import("json_core.zig");

pub const Error = error{ Malformed, OutOfMemory, TooDeep };
const invalid_character: u32 = 0x99999;

fn appendRaw(output: *core.JsonString, bytes: []const u8) Error!void {
    if (!core.appendRaw(output, bytes)) return error.OutOfMemory;
}

fn appendByte(output: *core.JsonString, byte: u8) Error!void {
    if (!core.appendCharacter(output, byte)) return error.OutOfMemory;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}
fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}
fn isHex(byte: u8) bool {
    return std.ascii.isHex(byte);
}

const TextParser = struct {
    parse: *core.JsonParse,
    text: []const u8,
    index: usize,

    fn skipSpace(self: *TextParser) Error!void {
        while (self.index < self.text.len) {
            const c = self.text[self.index];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.index += 1;
                continue;
            }
            if (c == 0x0b or c == 0x0c) {
                self.parse.has_nonstandard = true;
                self.index += 1;
                continue;
            }
            if (c == '/' and self.index + 1 < self.text.len) {
                if (self.text[self.index + 1] == '/') {
                    self.parse.has_nonstandard = true;
                    self.index += 2;
                    while (self.index < self.text.len and self.text[self.index] != '\n' and self.text[self.index] != '\r') self.index += 1;
                    continue;
                }
                if (self.text[self.index + 1] == '*') {
                    self.parse.has_nonstandard = true;
                    self.index += 2;
                    while (self.index + 1 < self.text.len and !(self.text[self.index] == '*' and self.text[self.index + 1] == '/')) self.index += 1;
                    if (self.index + 1 >= self.text.len) return error.Malformed;
                    self.index += 2;
                    continue;
                }
            }
            const spaces = [_][]const u8{ "\xc2\xa0", "\xe1\x9a\x80", "\xe2\x80\x80", "\xe2\x80\x81", "\xe2\x80\x82", "\xe2\x80\x83", "\xe2\x80\x84", "\xe2\x80\x85", "\xe2\x80\x86", "\xe2\x80\x87", "\xe2\x80\x88", "\xe2\x80\x89", "\xe2\x80\x8a", "\xe2\x80\xa8", "\xe2\x80\xa9", "\xe2\x80\xaf", "\xe2\x81\x9f", "\xe3\x80\x80", "\xef\xbb\xbf" };
            var matched = false;
            for (spaces) |space| if (std.mem.startsWith(u8, self.text[self.index..], space)) {
                self.parse.has_nonstandard = true;
                self.index += space.len;
                matched = true;
                break;
            };
            if (!matched) break;
        }
    }

    fn parseQuoted(self: *TextParser) Error!void {
        const delimiter = self.text[self.index];
        if (delimiter == '\'') self.parse.has_nonstandard = true;
        self.index += 1;
        const start = self.index;
        var node_type = core.kind.text;
        while (self.index < self.text.len) : (self.index += 1) {
            const c = self.text[self.index];
            if (c == delimiter) {
                core.appendNode(self.parse, node_type, self.text[start..self.index], self.index - start);
                self.index += 1;
                return;
            }
            if (c == '\\') {
                if (self.index + 1 >= self.text.len) return error.Malformed;
                const escaped = self.text[self.index + 1];
                if (escaped == '"' or escaped == '\\' or escaped == '/' or escaped == 'b' or escaped == 'f' or escaped == 'n' or escaped == 'r' or escaped == 't') {
                    if (node_type == core.kind.text) node_type = core.kind.text_json;
                    self.index += 1;
                } else if (self.index + 5 < self.text.len and core.is4HexEscape(self.text[self.index + 1 .. self.index + 6], &node_type)) {
                    self.index += 5;
                } else if (escaped == '\'' or escaped == 'v' or escaped == '0' or escaped == '\n' or escaped == '\r' or (escaped == 'x' and self.index + 3 < self.text.len and core.is2Hex(self.text[self.index + 2 .. self.index + 4]))) {
                    node_type = core.kind.text5;
                    self.parse.has_nonstandard = true;
                    if (escaped == 'x') self.index += 3 else self.index += 1;
                } else return error.Malformed;
            } else if (c < 0x20) {
                if (c == 0) return error.Malformed;
                node_type = core.kind.text5;
                self.parse.has_nonstandard = true;
            } else if (c == '"' and delimiter == '\'') node_type = core.kind.text5;
        }
        return error.Malformed;
    }

    fn parseIdentifier(self: *TextParser, label: bool) Error!void {
        const start = self.index;
        if (!isIdentifierStart(self.text[self.index])) return error.Malformed;
        self.index += 1;
        while (self.index < self.text.len and isIdentifierContinue(self.text[self.index])) self.index += 1;
        if (label) {
            self.parse.has_nonstandard = true;
            core.appendNode(self.parse, core.kind.text_raw, self.text[start..self.index], self.index - start);
            return;
        }
        const word = self.text[start..self.index];
        if (std.ascii.eqlIgnoreCase(word, "Infinity") or std.ascii.eqlIgnoreCase(word, "inf")) {
            self.parse.has_nonstandard = true;
            core.appendNode(self.parse, core.kind.float, "9e999", 5);
        } else if (std.ascii.eqlIgnoreCase(word, "NaN") or std.ascii.eqlIgnoreCase(word, "QNaN") or std.ascii.eqlIgnoreCase(word, "SNaN")) {
            self.parse.has_nonstandard = true;
            core.expandAndAppendByte(self.parse, core.kind.null_);
        } else return error.Malformed;
    }

    fn parseNumber(self: *TextParser) Error!void {
        var start = self.index;
        var nonstandard = false;
        var float5 = false;
        var floating = false;
        if (self.text[self.index] == '+' or self.text[self.index] == '-') {
            nonstandard = self.text[self.index] == '+';
            self.index += 1;
            if (self.index >= self.text.len) return error.Malformed;
            if (isIdentifierStart(self.text[self.index])) {
                const negative = self.text[start] == '-';
                const word_start = self.index;
                while (self.index < self.text.len and isIdentifierContinue(self.text[self.index])) {
                    self.index += 1;
                }
                const word = self.text[word_start..self.index];
                if (!std.ascii.eqlIgnoreCase(word, "Infinity") and !std.ascii.eqlIgnoreCase(word, "inf")) return error.Malformed;
                self.parse.has_nonstandard = true;
                core.appendNode(self.parse, core.kind.float, if (negative) "-9e999" else "9e999", if (negative) 6 else 5);
                return;
            }
        }
        if (self.index + 2 < self.text.len and self.text[self.index] == '0' and (self.text[self.index + 1] == 'x' or self.text[self.index + 1] == 'X')) {
            self.index += 2;
            const digits = self.index;
            while (self.index < self.text.len and isHex(self.text[self.index])) self.index += 1;
            if (self.index == digits) return error.Malformed;
            self.parse.has_nonstandard = true;
            if (self.text[start] == '+') start += 1;
            core.appendNode(self.parse, core.kind.int5, self.text[start..self.index], self.index - start);
            return;
        }
        var digits_before: usize = 0;
        while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) : (self.index += 1) digits_before += 1;
        if (digits_before > 1 and self.text[start + @intFromBool(self.text[start] == '+' or self.text[start] == '-')] == '0') return error.Malformed;
        if (self.index < self.text.len and self.text[self.index] == '.') {
            floating = true;
            self.index += 1;
            const fraction_start = self.index;
            while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) self.index += 1;
            if (digits_before == 0 or self.index == fraction_start) {
                nonstandard = true;
                float5 = true;
            }
        }
        if (digits_before == 0 and !floating) return error.Malformed;
        if (self.index < self.text.len and (self.text[self.index] == 'e' or self.text[self.index] == 'E')) {
            floating = true;
            self.index += 1;
            if (self.index < self.text.len and (self.text[self.index] == '+' or self.text[self.index] == '-')) self.index += 1;
            const exponent_start = self.index;
            while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) self.index += 1;
            if (self.index == exponent_start) return error.Malformed;
        }
        if (self.text[start] == '+') start += 1;
        if (nonstandard) self.parse.has_nonstandard = true;
        const node_type: u8 = if (floating) (if (float5) core.kind.float5 else core.kind.float) else core.kind.int;
        core.appendNode(self.parse, node_type, self.text[start..self.index], self.index - start);
    }

    fn parseContainer(self: *TextParser, node_type: u8, closing: u8) Error!void {
        if (self.parse.depth >= 1000) return error.TooDeep;
        self.parse.depth += 1;
        defer self.parse.depth -= 1;
        const root = self.parse.blob.items.len;
        core.appendNode(self.parse, node_type, null, self.text.len - self.index);
        const payload_start = self.parse.blob.items.len;
        self.index += 1;
        try self.skipSpace();
        if (self.index < self.text.len and self.text[self.index] == closing) {
            self.index += 1;
            _ = core.changePayloadSize(self.parse, root, 0);
            return;
        }
        while (self.index < self.text.len) {
            if (node_type == core.kind.object) {
                if (self.text[self.index] == '"' or self.text[self.index] == '\'') try self.parseQuoted() else try self.parseIdentifier(true);
                try self.skipSpace();
                if (self.index >= self.text.len or self.text[self.index] != ':') return error.Malformed;
                self.index += 1;
                try self.skipSpace();
            }
            try self.parseValue();
            try self.skipSpace();
            if (self.index >= self.text.len) return error.Malformed;
            if (self.text[self.index] == closing) {
                self.index += 1;
                _ = core.changePayloadSize(self.parse, root, @intCast(self.parse.blob.items.len - payload_start));
                return;
            }
            if (self.text[self.index] != ',') return error.Malformed;
            self.index += 1;
            try self.skipSpace();
            if (self.index < self.text.len and self.text[self.index] == closing) {
                self.parse.has_nonstandard = true;
                self.index += 1;
                _ = core.changePayloadSize(self.parse, root, @intCast(self.parse.blob.items.len - payload_start));
                return;
            }
        }
        return error.Malformed;
    }

    fn parseValue(self: *TextParser) Error!void {
        try self.skipSpace();
        if (self.index >= self.text.len) return error.Malformed;
        const c = self.text[self.index];
        if (c == '{') return self.parseContainer(core.kind.object, '}');
        if (c == '[') return self.parseContainer(core.kind.array, ']');
        if (c == '"' or c == '\'') return self.parseQuoted();
        if (std.mem.startsWith(u8, self.text[self.index..], "true") and (self.index + 4 == self.text.len or !isIdentifierContinue(self.text[self.index + 4]))) {
            core.expandAndAppendByte(self.parse, core.kind.true_);
            self.index += 4;
            return;
        }
        if (std.mem.startsWith(u8, self.text[self.index..], "false") and (self.index + 5 == self.text.len or !isIdentifierContinue(self.text[self.index + 5]))) {
            core.expandAndAppendByte(self.parse, core.kind.false_);
            self.index += 5;
            return;
        }
        if (std.mem.startsWith(u8, self.text[self.index..], "null") and (self.index + 4 == self.text.len or !isIdentifierContinue(self.text[self.index + 4]))) {
            core.expandAndAppendByte(self.parse, core.kind.null_);
            self.index += 4;
            return;
        }
        if (c == '+' or c == '-' or c == '.' or std.ascii.isDigit(c)) return self.parseNumber();
        return self.parseIdentifier(false);
    }
};

/// Source `jsonTranslateTextToBlob()`.
pub fn translateTextToBlob(parse: *core.JsonParse, text: []const u8, start: usize) Error!usize {
    var parser = TextParser{ .parse = parse, .text = text, .index = start };
    parser.parseValue() catch |err| {
        parse.error_index = @intCast(parser.index);
        return err;
    };
    if (parse.oom) return error.OutOfMemory;
    return parser.index;
}

/// Source `jsonConvertTextToBlob()`.
pub fn convertTextToBlob(parse: *core.JsonParse, text: []const u8) Error!void {
    parse.blob.clearRetainingCapacity();
    parse.error_index = 0;
    parse.has_nonstandard = false;
    const end = translateTextToBlob(parse, text, 0) catch |err| {
        parse.blob.clearRetainingCapacity();
        return err;
    };
    var parser = TextParser{ .parse = parse, .text = text, .index = end };
    try parser.skipSpace();
    if (parser.index != text.len) {
        parse.error_index = @intCast(parser.index);
        parse.blob.clearRetainingCapacity();
        return error.Malformed;
    }
}

fn appendCanonicalText(output: *core.JsonString, payload: []const u8, node_type: u8) Error!void {
    try appendByte(output, '"');
    var index: usize = 0;
    while (index < payload.len) {
        const c = payload[index];
        if (node_type == core.kind.text5 and c == '"') try appendRaw(output, "\\\"") else if (node_type == core.kind.text5 and c <= 0x1f) {
            if (!core.appendControlCharacter(output, c)) return error.OutOfMemory;
        } else if (node_type == core.kind.text5 and c == '\\') {
            var value: u32 = 0;
            const consumed = core.unescapeOne(payload[index..], &value);
            if (value == invalid_character) return error.Malformed;
            if (value != 0) {
                var buffer: [4]u8 = undefined;
                if (value > 0x10ffff) return error.Malformed;
                const encoded = std.unicode.utf8Encode(@intCast(value), &buffer) catch return error.Malformed;
                if (value == '"' or value == '\\' or value < 0x20) {
                    if (value < 0x20) {
                        if (!core.appendControlCharacter(output, @intCast(value))) return error.OutOfMemory;
                    } else try appendRaw(output, if (value == '"') "\\\"" else "\\\\");
                } else try appendRaw(output, buffer[0..encoded]);
            }
            index += consumed;
            continue;
        } else try appendByte(output, c);
        index += 1;
    }
    try appendByte(output, '"');
}

/// Source `jsonTranslateBlobToText()`.
pub fn translateBlobToText(parse: *core.JsonParse, root: usize, output: *core.JsonString) Error!usize {
    var size: u32 = 0;
    const header = core.payloadSize(parse, root, &size);
    if (header == 0 or root + header + size > parse.blob.items.len) return error.Malformed;
    const node_type = parse.blob.items[root] & 15;
    const payload = parse.blob.items[root + header .. root + header + size];
    switch (node_type) {
        core.kind.null_ => try appendRaw(output, "null"),
        core.kind.true_ => try appendRaw(output, "true"),
        core.kind.false_ => try appendRaw(output, "false"),
        core.kind.int, core.kind.float => if (payload.len == 0) return error.Malformed else try appendRaw(output, payload),
        core.kind.int5 => {
            const negative = payload.len > 0 and payload[0] == '-';
            const offset: usize = @intFromBool(negative or (payload.len > 0 and payload[0] == '+'));
            if (payload.len < offset + 3 or payload[offset] != '0' or (payload[offset + 1] != 'x' and payload[offset + 1] != 'X')) return error.Malformed;
            const value = std.fmt.parseInt(u64, payload[offset + 2 ..], 16) catch {
                try appendRaw(output, if (negative) "-9.0e999" else "9.0e999");
                return root + header + size;
            };
            var buffer: [32]u8 = undefined;
            const rendered = if (negative)
                std.fmt.bufPrint(&buffer, "-{d}", .{value}) catch return error.OutOfMemory
            else
                std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutOfMemory;
            try appendRaw(output, rendered);
        },
        core.kind.float5 => {
            if (payload.len == 0) return error.Malformed;
            var index: usize = 0;
            if (payload[0] == '-') {
                try appendByte(output, '-');
                index = 1;
            }
            if (index < payload.len and payload[index] == '.') try appendByte(output, '0');
            while (index < payload.len) : (index += 1) {
                try appendByte(output, payload[index]);
                if (payload[index] == '.' and (index + 1 == payload.len or !std.ascii.isDigit(payload[index + 1]))) try appendByte(output, '0');
            }
        },
        core.kind.text, core.kind.text_json, core.kind.text5 => try appendCanonicalText(output, payload, node_type),
        core.kind.text_raw => if (!core.appendQuotedString(output, payload)) return error.OutOfMemory,
        core.kind.array, core.kind.object => {
            if (parse.depth >= 1000) {
                output.reportTooDeep();
                return error.TooDeep;
            }
            parse.depth += 1;
            defer parse.depth -= 1;
            try appendByte(output, if (node_type == core.kind.array) '[' else '{');
            var index = root + header;
            const end = index + size;
            var count: usize = 0;
            while (index < end) : (count += 1) {
                index = try translateBlobToText(parse, index, output);
                if (index > end) return error.Malformed;
                if (index < end) try appendByte(output, if (node_type == core.kind.object and count % 2 == 0) ':' else ',');
            }
            if (node_type == core.kind.object and count % 2 != 0) return error.Malformed;
            try appendByte(output, if (node_type == core.kind.array) ']' else '}');
        },
        else => return error.Malformed,
    }
    return root + header + size;
}

/// Source `jsonPrettyIndent()`.
pub fn appendPrettyIndent(output: *core.JsonString, indent: []const u8, level: usize) Error!void {
    var amount: usize = 0;
    while (amount < level) : (amount += 1) try appendRaw(output, indent);
}

/// Source `jsonTranslateBlobToPrettyText()`.
pub fn translateBlobToPrettyText(parse: *core.JsonParse, root: usize, output: *core.JsonString, indent: []const u8, level: usize) Error!usize {
    var size: u32 = 0;
    const header = core.payloadSize(parse, root, &size);
    if (header == 0) return error.Malformed;
    const node_type = parse.blob.items[root] & 15;
    if (node_type != core.kind.array and node_type != core.kind.object) return translateBlobToText(parse, root, output);
    if (level >= 1000) {
        output.reportTooDeep();
        return error.TooDeep;
    }
    try appendByte(output, if (node_type == core.kind.array) '[' else '{');
    var index = root + header;
    const end = index + size;
    var count: usize = 0;
    if (index < end) try appendByte(output, '\n');
    while (index < end) : (count += 1) {
        try appendPrettyIndent(output, indent, level + 1);
        if (node_type == core.kind.object) {
            index = try translateBlobToText(parse, index, output);
            if (index >= end) return error.Malformed;
            try appendRaw(output, ": ");
            index = try translateBlobToPrettyText(parse, index, output, indent, level + 1);
        } else index = try translateBlobToPrettyText(parse, index, output, indent, level + 1);
        if (index < end) try appendRaw(output, ",\n");
    }
    if (index != end) return error.Malformed;
    if (size > 0) {
        try appendByte(output, '\n');
        try appendPrettyIndent(output, indent, level);
    }
    try appendByte(output, if (node_type == core.kind.array) ']' else '}');
    return end;
}

/// Source `jsonbValidityCheck()`.
pub fn validityCheck(parse: *core.JsonParse, root: usize, end: usize, depth: usize) usize {
    if (depth > 1000 or root >= end) return root + 1;
    var size: u32 = 0;
    const header = core.payloadSize(parse, root, &size);
    if (header == 0 or root + header + size != end) return root + 1;
    const node_type = parse.blob.items[root] & 15;
    const payload = parse.blob.items[root + header .. end];
    switch (node_type) {
        core.kind.null_, core.kind.true_, core.kind.false_ => return if (size == 0) 0 else root + 1,
        core.kind.int => {
            if (payload.len == 0) return root + 1;
            const digits = if (payload[0] == '-') payload[1..] else payload;
            if (digits.len == 0) return root + 1;
            for (digits, root + header + @intFromBool(payload[0] == '-')..) |c, index| if (!std.ascii.isDigit(c)) return index + 1;
            return 0;
        },
        core.kind.int5 => {
            const offset: usize = @intFromBool(payload.len > 0 and payload[0] == '-');
            if (payload.len < offset + 3 or payload[offset] != '0' or (payload[offset + 1] != 'x' and payload[offset + 1] != 'X')) return root + 1;
            for (payload[offset + 2 ..], root + header + offset + 2..) |c, index| if (!isHex(c)) return index + 1;
            return 0;
        },
        core.kind.float, core.kind.float5 => {
            _ = std.fmt.parseFloat(f64, payload) catch return root + 1;
            return 0;
        },
        core.kind.text => {
            for (payload, root + header..) |c, index| if (!ordinaryTextByte(c)) return index + 1;
            return 0;
        },
        core.kind.text_json, core.kind.text5 => {
            var index: usize = 0;
            while (index < payload.len) : (index += 1) if (payload[index] == '\\') {
                var value: u32 = 0;
                const consumed = core.unescapeOne(payload[index..], &value);
                if (value == invalid_character or (node_type == core.kind.text_json and (payload[index + 1] == 'x' or payload[index + 1] == 'v' or payload[index + 1] == '0'))) return root + header + index + 1;
                index += consumed - 1;
            } else if (node_type == core.kind.text_json and payload[index] <= 0x1f) return root + header + index + 1;
            return 0;
        },
        core.kind.text_raw => return 0,
        core.kind.array, core.kind.object => {
            var index = root + header;
            var count: usize = 0;
            while (index < end) : (count += 1) {
                var child_size: u32 = 0;
                const child_header = core.payloadSize(parse, index, &child_size);
                if (child_header == 0 or index + child_header + child_size > end) return index + 1;
                if (node_type == core.kind.object and count % 2 == 0) {
                    const child_type = parse.blob.items[index] & 15;
                    if (child_type < core.kind.text or child_type > core.kind.text_raw) return index + 1;
                }
                const failure = validityCheck(parse, index, index + child_header + child_size, depth + 1);
                if (failure != 0) return failure;
                index += child_header + child_size;
            }
            return if (node_type == core.kind.object and count % 2 != 0) end + 1 else 0;
        },
        else => return root + 1,
    }
}

fn ordinaryTextByte(byte: u8) bool {
    return byte >= 0x20 and byte != '"' and byte != '\\';
}

/// Source `jsonArgIsJsonb()`.
pub fn argumentIsJsonb(parse: *core.JsonParse, bytes: []const u8) bool {
    parse.blob.clearRetainingCapacity();
    parse.blob.appendSlice(parse.allocator, bytes) catch {
        parse.oom = true;
        return false;
    };
    if (bytes.len == 0 or (bytes[0] & 15) > core.kind.object) return false;
    var size: u32 = 0;
    const header = core.payloadSize(parse, 0, &size);
    if (header == 0 or header + size != bytes.len or ((bytes[0] & 15) <= core.kind.false_ and size != 0)) return false;
    return size > 7 or ((bytes[0] != '{' and bytes[0] != '[' and !std.ascii.isDigit(bytes[0])) or validityCheck(parse, 0, bytes.len, 1) == 0);
}

/// Source `jsonReturnStringAsBlob()`: translate well-formed generated text to
/// an independently owned editable JSONB image.
pub fn returnStringAsBlob(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var parse = core.JsonParse.init(allocator);
    defer parse.blob.deinit(allocator);
    try convertTextToBlob(&parse, text);
    return allocator.dupe(u8, parse.blob.items) catch error.OutOfMemory;
}

/// Source `jsonReturnTextJsonFromBlob()`: translate one borrowed JSONB image
/// to independently owned canonical JSON text.
pub fn returnTextFromBlob(allocator: std.mem.Allocator, blob: []const u8) Error![]u8 {
    var parse = core.JsonParse.init(allocator);
    defer parse.blob.deinit(allocator);
    parse.blob.appendSlice(allocator, blob) catch return error.OutOfMemory;
    var output = core.JsonString.init(allocator);
    errdefer output.deinit();
    _ = try translateBlobToText(&parse, 0, &output);
    return output.bytes.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Source `jsonBadPathError()`.
pub fn badPathError(allocator: std.mem.Allocator, path: []const u8, code: u32) Error![]u8 {
    const prefix = switch (code) {
        0xfffffffd => "not an array element: ",
        0xffffffff => "malformed JSON: ",
        0xfffffffc => "JSON path too deep: ",
        else => "bad JSON path: ",
    };
    return std.mem.concat(allocator, u8, &.{ prefix, path }) catch error.OutOfMemory;
}
