//! SQLite SQL tokenizer translated from `src/tokenize.c`.

const tokens = @import("generated/tokens.zig");
const keywords = @import("generated/keywords.zig");
const fallback = @import("generated/fallback.zig");
pub const token = tokens;

const class = [256]u8{ 29, 28, 28, 28, 28, 28, 28, 28, 28, 7, 7, 28, 7, 7, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 7, 15, 8, 5, 4, 22, 24, 8, 17, 18, 21, 20, 23, 11, 26, 16, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 5, 19, 12, 14, 13, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 2, 2, 9, 28, 28, 28, 2, 8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 2, 2, 28, 10, 28, 25, 28, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 30, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27 };

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isId(c: u8) bool {
    return c >= 0x80 or isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}
fn equalFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if ((x & ~@as(u8, 0x20)) != y) return false;
    return true;
}

pub fn keywordCode(text: []const u8) u16 {
    if (text.len < 2) return tokens.tk_id;
    for (keywords.entries) |entry| if (equalFold(text, entry.name)) return entry.token;
    return tokens.tk_id;
}

pub fn isIdChar(c: u8) bool {
    return isId(c);
}

fn nextSignificant(position: *[*:0]const u8) u16 {
    var current = position.*;
    while (true) {
        const result = get(current);
        current += result.length;
        if (result.token_type == tokens.tk_space or result.token_type == tokens.tk_comment) continue;
        position.* = current;
        const typ = result.token_type;
        if (typ == tokens.tk_id or typ == tokens.tk_string or typ == tokens.tk_join_kw or
            typ == tokens.tk_window or typ == tokens.tk_over or
            (typ < fallback.to_id.len and fallback.to_id[typ])) return tokens.tk_id;
        return typ;
    }
}

pub fn analyzeWindow(input_after_keyword: [*:0]const u8) u16 {
    var position = input_after_keyword;
    if (nextSignificant(&position) != tokens.tk_id) return tokens.tk_id;
    return if (nextSignificant(&position) == tokens.tk_as) tokens.tk_window else tokens.tk_id;
}

pub fn analyzeOver(input_after_keyword: [*:0]const u8, previous: u16) u16 {
    if (previous != tokens.tk_rp) return tokens.tk_id;
    var position = input_after_keyword;
    const next = nextSignificant(&position);
    return if (next == tokens.tk_lp or next == tokens.tk_id) tokens.tk_over else tokens.tk_id;
}

pub fn analyzeFilter(input_after_keyword: [*:0]const u8, previous: u16) u16 {
    if (previous != tokens.tk_rp) return tokens.tk_id;
    var position = input_after_keyword;
    return if (nextSignificant(&position) == tokens.tk_lp) tokens.tk_filter else tokens.tk_id;
}

pub const Result = struct { length: usize, token_type: u16 };

pub fn get(input: [*:0]const u8) Result {
    const z: [*]const u8 = input;
    var i: usize = 0;
    var typ: u16 = tokens.tk_illegal;
    switch (class[z[0]]) {
        7 => {
            i = 1;
            while (isSpace(z[i])) i += 1;
            typ = tokens.tk_space;
            return .{ .length = i, .token_type = typ };
        },
        11 => {
            if (z[1] == '-') {
                i = 2;
                while (z[i] != 0 and z[i] != '\n') i += 1;
                typ = tokens.tk_comment;
                return .{ .length = i, .token_type = typ };
            }
            if (z[1] == '>') return .{ .length = 2 + @as(usize, @intFromBool(z[2] == '>')), .token_type = tokens.tk_ptr };
            return .{ .length = 1, .token_type = tokens.tk_minus };
        },
        17 => return .{ .length = 1, .token_type = tokens.tk_lp },
        18 => return .{ .length = 1, .token_type = tokens.tk_rp },
        19 => return .{ .length = 1, .token_type = tokens.tk_semi },
        20 => return .{ .length = 1, .token_type = tokens.tk_plus },
        21 => return .{ .length = 1, .token_type = tokens.tk_star },
        22 => return .{ .length = 1, .token_type = tokens.tk_rem },
        23 => return .{ .length = 1, .token_type = tokens.tk_comma },
        24 => return .{ .length = 1, .token_type = tokens.tk_bitand },
        25 => return .{ .length = 1, .token_type = tokens.tk_bitnot },
        16 => {
            if (z[1] != '*' or z[2] == 0) return .{ .length = 1, .token_type = tokens.tk_slash };
            i = 3;
            var c = z[2];
            while ((c != '*' or z[i] != '/') and blk: {
                c = z[i];
                break :blk c != 0;
            }) i += 1;
            if (c != 0) i += 1;
            return .{ .length = i, .token_type = tokens.tk_comment };
        },
        14 => return .{ .length = 1 + @as(usize, @intFromBool(z[1] == '=')), .token_type = tokens.tk_eq },
        12 => return if (z[1] == '=') .{ .length = 2, .token_type = tokens.tk_le } else if (z[1] == '>') .{ .length = 2, .token_type = tokens.tk_ne } else if (z[1] == '<') .{ .length = 2, .token_type = tokens.tk_lshift } else .{ .length = 1, .token_type = tokens.tk_lt },
        13 => return if (z[1] == '=') .{ .length = 2, .token_type = tokens.tk_ge } else if (z[1] == '>') .{ .length = 2, .token_type = tokens.tk_rshift } else .{ .length = 1, .token_type = tokens.tk_gt },
        15 => return if (z[1] == '=') .{ .length = 2, .token_type = tokens.tk_ne } else .{ .length = 1, .token_type = tokens.tk_illegal },
        10 => return if (z[1] == '|') .{ .length = 2, .token_type = tokens.tk_concat } else .{ .length = 1, .token_type = tokens.tk_bitor },
        8 => {
            const delim = z[0];
            i = 1;
            while (z[i] != 0) {
                if (z[i] == delim) {
                    if (z[i + 1] == delim) i += 1 else break;
                }
                i += 1;
            }
            if (z[i] == '\'') return .{ .length = i + 1, .token_type = tokens.tk_string };
            if (z[i] != 0) return .{ .length = i + 1, .token_type = tokens.tk_id };
            return .{ .length = i, .token_type = tokens.tk_illegal };
        },
        26 => {
            if (!isDigit(z[1])) return .{ .length = 1, .token_type = tokens.tk_dot };
            typ = tokens.tk_integer;
        },
        3 => typ = tokens.tk_integer,
        9 => {
            i = 1;
            while (z[i] != 0 and z[i] != ']') i += 1;
            if (z[i] == ']') {
                i += 1;
                typ = tokens.tk_id;
            } else typ = tokens.tk_illegal;
            return .{ .length = i, .token_type = typ };
        },
        6 => {
            i = 1;
            while (isDigit(z[i])) i += 1;
            return .{ .length = i, .token_type = tokens.tk_variable };
        },
        4, 5 => {
            var n: usize = 0;
            typ = tokens.tk_variable;
            i = 1;
            while (z[i] != 0) {
                const c = z[i];
                if (isId(c)) n += 1 else if (c == '(' and n > 0) {
                    i += 1;
                    while (z[i] != 0 and !isSpace(z[i]) and z[i] != ')') i += 1;
                    if (z[i] == ')') i += 1 else typ = tokens.tk_illegal;
                    break;
                } else if (c == ':' and z[i + 1] == ':') i += 1 else break;
                i += 1;
            }
            if (n == 0) typ = tokens.tk_illegal;
            return .{ .length = i, .token_type = typ };
        },
        1 => {
            if (class[z[1]] > 2) {
                i = 1;
            } else {
                i = 2;
                while (class[z[i]] <= 2) i += 1;
                if (isId(z[i])) i += 1 else return .{ .length = i, .token_type = keywordCode(z[0..i]) };
            }
        },
        0 => {
            if (z[1] == '\'') {
                typ = tokens.tk_blob;
                i = 2;
                while (isHex(z[i])) i += 1;
                if (z[i] != '\'' or i % 2 != 0) {
                    typ = tokens.tk_illegal;
                    while (z[i] != 0 and z[i] != '\'') i += 1;
                }
                if (z[i] != 0) i += 1;
                return .{ .length = i, .token_type = typ };
            }
            i = 1;
        },
        2, 27 => i = 1,
        30 => {
            if (z[1] == 0xbb and z[2] == 0xbf) return .{ .length = 3, .token_type = tokens.tk_space };
            i = 1;
        },
        29 => return .{ .length = 0, .token_type = tokens.tk_illegal },
        else => return .{ .length = 1, .token_type = tokens.tk_illegal },
    }
    if (typ == tokens.tk_integer) {
        if (z[0] == '0' and (z[1] == 'x' or z[1] == 'X') and isHex(z[2])) {
            i = 3;
            while (true) {
                if (!isHex(z[i])) {
                    if (z[i] == '_') typ = tokens.tk_qnumber else break;
                }
                i += 1;
            }
        } else {
            i = 0;
            while (true) {
                if (!isDigit(z[i])) {
                    if (z[i] == '_') typ = tokens.tk_qnumber else break;
                }
                i += 1;
            }
            if (z[i] == '.') {
                if (typ == tokens.tk_integer) typ = tokens.tk_float;
                i += 1;
                while (true) {
                    if (!isDigit(z[i])) {
                        if (z[i] == '_') typ = tokens.tk_qnumber else break;
                    }
                    i += 1;
                }
            }
            if ((z[i] == 'e' or z[i] == 'E') and (isDigit(z[i + 1]) or ((z[i + 1] == '+' or z[i + 1] == '-') and isDigit(z[i + 2])))) {
                if (typ == tokens.tk_integer) typ = tokens.tk_float;
                i += 2;
                while (true) {
                    if (!isDigit(z[i])) {
                        if (z[i] == '_') typ = tokens.tk_qnumber else break;
                    }
                    i += 1;
                }
            }
        }
        while (isId(z[i])) {
            typ = tokens.tk_illegal;
            i += 1;
        }
        return .{ .length = i, .token_type = typ };
    }
    while (isId(z[i])) i += 1;
    return .{ .length = i, .token_type = tokens.tk_id };
}

test "representative tokenizer boundaries" {
    const testing = @import("std").testing;
    try testing.expectEqual(Result{ .length = 6, .token_type = tokens.tk_select }, get("select"));
    try testing.expectEqual(Result{ .length = 4, .token_type = tokens.tk_float }, get("1e+2"));
    try testing.expectEqual(Result{ .length = 3, .token_type = tokens.tk_blob }, get("x''"));
    try testing.expectEqual(Result{ .length = 0, .token_type = tokens.tk_illegal }, get(""));
    try testing.expectEqual(tokens.tk_window, analyzeWindow(" x AS rest"));
    try testing.expectEqual(tokens.tk_id, analyzeWindow(" x FROM rest"));
    try testing.expectEqual(tokens.tk_over, analyzeOver(" (x)", tokens.tk_rp));
    try testing.expectEqual(tokens.tk_filter, analyzeFilter(" (WHERE x)", tokens.tk_rp));
}
