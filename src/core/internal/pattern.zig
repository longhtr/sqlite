//! LIKE and GLOB matching from `func.c`.

const utf = @import("../utf.zig");
const mem = @import("vdbe_mem.zig");
const types = @import("vdbe_types.zig");

pub const CompareInfo = extern struct { match_all: u8, match_one: u8, match_set: u8, no_case: u8 };
pub const glob_info = CompareInfo{ .match_all = '*', .match_one = '?', .match_set = '[', .no_case = 0 };
pub const like_info = CompareInfo{ .match_all = '%', .match_one = '_', .match_set = 0, .no_case = 1 };
pub const like_sensitive_info = CompareInfo{ .match_all = '%', .match_one = '_', .match_set = 0, .no_case = 0 };

pub const match: c_int = 0;
pub const no_match: c_int = 1;
pub const no_wildcard_match: c_int = 2;

fn read(pointer: *[*:0]const u8) u32 {
    const decoded = utf.read(pointer.*);
    pointer.* += decoded.length;
    return decoded.value;
}
fn lower(character: u32) u32 {
    return if (character >= 'A' and character <= 'Z') character + 0x20 else character;
}

/// Source `patternCompare()`.
pub fn compare(
    pattern_initial: [*:0]const u8,
    string_initial: [*:0]const u8,
    info: *const CompareInfo,
    match_other: u32,
) c_int {
    var pattern = pattern_initial;
    var string = string_initial;
    var escaped_end: ?[*:0]const u8 = null;
    while (true) {
        var character = read(&pattern);
        if (character == 0) return if (string[0] == 0) match else no_match;
        if (character == info.match_all) {
            while (true) {
                character = read(&pattern);
                if (character == info.match_all) continue;
                if (character == info.match_one and info.match_one != 0) {
                    if (read(&string) == 0) return no_wildcard_match;
                    continue;
                }
                break;
            }
            if (character == 0) return match;
            if (character == match_other) {
                if (info.match_set == 0) {
                    character = read(&pattern);
                    if (character == 0) return no_wildcard_match;
                } else {
                    while (string[0] != 0) {
                        const result = compare(pattern - 1, string, info, match_other);
                        if (result != no_match) return result;
                        _ = read(&string);
                    }
                    return no_wildcard_match;
                }
            }
            while (true) {
                const input_character = read(&string);
                if (input_character == 0) break;
                const equal = input_character == character or
                    (info.no_case != 0 and input_character < 0x80 and character < 0x80 and lower(input_character) == lower(character));
                if (equal) {
                    const result = compare(pattern, string, info, match_other);
                    if (result != no_match) return result;
                }
            }
            return no_wildcard_match;
        }
        if (character == match_other) {
            if (info.match_set == 0) {
                character = read(&pattern);
                if (character == 0) return no_match;
                escaped_end = pattern;
            } else {
                var prior: u32 = 0;
                var seen = false;
                var invert = false;
                const input_character = read(&string);
                if (input_character == 0) return no_match;
                var set_character = read(&pattern);
                if (set_character == '^') {
                    invert = true;
                    set_character = read(&pattern);
                }
                if (set_character == ']') {
                    if (input_character == ']') seen = true;
                    set_character = read(&pattern);
                }
                while (set_character != 0 and set_character != ']') {
                    if (set_character == '-' and pattern[0] != ']' and pattern[0] != 0 and prior > 0) {
                        set_character = read(&pattern);
                        if (input_character >= prior and input_character <= set_character) seen = true;
                        prior = 0;
                    } else {
                        if (input_character == set_character) seen = true;
                        prior = set_character;
                    }
                    set_character = read(&pattern);
                }
                if (set_character == 0 or seen == invert) return no_match;
                continue;
            }
        }
        const input_character = read(&string);
        if (character == input_character) continue;
        if (info.no_case != 0 and character < 0x80 and input_character < 0x80 and lower(character) == lower(input_character)) continue;
        if (character == info.match_one and (escaped_end == null or @intFromPtr(pattern) != @intFromPtr(escaped_end.?)) and input_character != 0) continue;
        return no_match;
    }
}

/// Source `sqlite3_strglob()`.
pub fn stringGlob(pattern: ?[*:0]const u8, string: ?[*:0]const u8) c_int {
    if (string == null) return @intFromBool(pattern != null);
    if (pattern == null) return 1;
    return compare(pattern.?, string.?, &glob_info, '[');
}

/// Source `sqlite3_strlike()`.
pub fn stringLike(pattern: ?[*:0]const u8, string: ?[*:0]const u8, escape: u32) c_int {
    if (string == null) return @intFromBool(pattern != null);
    if (pattern == null) return 1;
    return compare(pattern.?, string.?, &like_info, escape);
}

fn argument(arguments: ?[*]?*types.Mem, index: usize) *types.Mem {
    return arguments.?[index].?;
}

/// Source `likeFunc()`.
pub fn like(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    const pattern_value = argument(arguments, 0);
    const pattern_length = mem.valueBytes(pattern_value, 1);
    if (pattern_length > context.pOut.?.db.?.aLimit[8]) {
        mem.resultError(context, "LIKE or GLOB pattern too complex", -1);
        return;
    }
    var info = @as(*const CompareInfo, @ptrCast(@alignCast(context.pFunc.?.pUserData.?))).*;
    var escape: u32 = info.match_set;
    if (argument_count == 3) {
        const escape_text = mem.valueText(argument(arguments, 2), 1) orelse return;
        const decoded = utf.read(@ptrCast(escape_text));
        if (decoded.value == 0 or escape_text[decoded.length] != 0) {
            mem.resultError(context, "ESCAPE expression must be a single character", -1);
            return;
        }
        escape = decoded.value;
        if (escape == info.match_all) info.match_all = 0;
        if (escape == info.match_one) info.match_one = 0;
    }
    const pattern_text = mem.valueText(pattern_value, 1) orelse return;
    const input_text = mem.valueText(argument(arguments, 1), 1) orelse return;
    mem.resultInt(context, @intFromBool(compare(@ptrCast(pattern_text), @ptrCast(input_text), &info, escape) == match));
}
