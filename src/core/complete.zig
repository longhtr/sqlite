//! SQLite `sqlite3_complete()` trigger-aware statement state machine.

const std = @import("std");

pub const tk_semi: u8 = 0;
pub const tk_ws: u8 = 1;
pub const tk_other: u8 = 2;
pub const tk_explain: u8 = 3;
pub const tk_create: u8 = 4;
pub const tk_temp: u8 = 5;
pub const tk_trigger: u8 = 6;
pub const tk_end: u8 = 7;

const transitions = [8][8]u8{
    .{ 1, 0, 2, 3, 4, 2, 2, 2 },
    .{ 1, 1, 2, 3, 4, 2, 2, 2 },
    .{ 1, 2, 2, 2, 2, 2, 2, 2 },
    .{ 1, 3, 3, 2, 4, 2, 2, 2 },
    .{ 1, 4, 2, 2, 2, 4, 5, 2 },
    .{ 6, 5, 5, 5, 5, 5, 5, 5 },
    .{ 6, 6, 5, 5, 5, 5, 5, 7 },
    .{ 1, 7, 5, 5, 5, 5, 5, 5 },
};

fn isIdChar(value: anytype) bool {
    return value >= 0x80 or std.ascii.isAlphanumeric(@intCast(value)) or value == '_' or value == '$';
}

fn asciiEqualFold(comptime T: type, input: []const T, expected: []const u8) bool {
    if (input.len != expected.len) return false;
    for (input, expected) |actual, wanted| {
        if (actual > 0x7f or std.ascii.toLower(@intCast(actual)) != wanted) return false;
    }
    return true;
}

fn completeUnits(comptime T: type, sql: []const T) bool {
    var state: u8 = 0;
    var index: usize = 0;
    while (index < sql.len and sql[index] != 0) : (index += 1) {
        const current = sql[index];
        var token: u8 = tk_other;
        switch (current) {
            ';' => token = tk_semi,
            ' ', '\r', '\t', '\n', 0x0c => token = tk_ws,
            '/' => {
                if (index + 1 < sql.len and sql[index + 1] == '*') {
                    index += 2;
                    while (index < sql.len and sql[index] != 0 and
                        (sql[index] != '*' or index + 1 >= sql.len or sql[index + 1] != '/')) : (index += 1)
                    {}
                    if (index >= sql.len or sql[index] == 0) return false;
                    index += 1;
                    token = tk_ws;
                }
            },
            '-' => {
                if (index + 1 < sql.len and sql[index + 1] == '-') {
                    while (index < sql.len and sql[index] != 0 and sql[index] != '\n') : (index += 1) {}
                    if (index >= sql.len or sql[index] == 0) return state == 1;
                    token = tk_ws;
                }
            },
            '[' => {
                index += 1;
                while (index < sql.len and sql[index] != 0 and sql[index] != ']') : (index += 1) {}
                if (index >= sql.len or sql[index] == 0) return false;
            },
            '`', '"', '\'' => |quote| {
                index += 1;
                while (index < sql.len and sql[index] != 0 and sql[index] != quote) : (index += 1) {}
                if (index >= sql.len or sql[index] == 0) return false;
            },
            else => {
                if (isIdChar(current)) {
                    const start = index;
                    index += 1;
                    while (index < sql.len and sql[index] != 0 and isIdChar(sql[index])) : (index += 1) {}
                    const word = sql[start..index];
                    index -= 1;
                    token = if (asciiEqualFold(T, word, "create"))
                        tk_create
                    else if (asciiEqualFold(T, word, "trigger"))
                        tk_trigger
                    else if (asciiEqualFold(T, word, "temp") or asciiEqualFold(T, word, "temporary"))
                        tk_temp
                    else if (asciiEqualFold(T, word, "end"))
                        tk_end
                    else if (asciiEqualFold(T, word, "explain"))
                        tk_explain
                    else
                        tk_other;
                }
            },
        }
        state = transitions[state][token];
    }
    return state == 1;
}

pub fn isComplete(sql: []const u8) bool {
    return completeUnits(u8, sql);
}

pub fn isCompleteUtf16(sql: []const u16) bool {
    return completeUnits(u16, sql);
}

test "semicolon comments quotes and trigger endings" {
    try std.testing.expect(isComplete("select 1;"));
    try std.testing.expect(isComplete("select ';'; -- tail"));
    try std.testing.expect(!isComplete("select ';'"));
    try std.testing.expect(!isComplete("select 1; /* unterminated"));
    try std.testing.expect(!isComplete("create trigger t after insert on x begin select 1; end"));
    try std.testing.expect(isComplete("create trigger t after insert on x begin select 1; end;"));
    try std.testing.expect(isComplete("explain create temp trigger t after insert on x begin select 1; end;"));
}

test "UTF-16 state machine preserves ASCII SQL syntax" {
    const complete = [_]u16{ 's', 'e', 'l', 'e', 'c', 't', ' ', 0x20ac, ';' };
    try std.testing.expect(isCompleteUtf16(&complete));
    const trigger = [_]u16{ 'c', 'r', 'e', 'a', 't', 'e', ' ', 't', 'r', 'i', 'g', 'g', 'e', 'r', ' ', 't', ' ', 'b', 'e', 'g', 'i', 'n', ' ', 'e', 'n', 'd', ';' };
    try std.testing.expect(!isCompleteUtf16(&trigger));
}
