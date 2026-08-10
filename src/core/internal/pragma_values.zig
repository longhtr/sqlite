//! PRAGMA keyword/value decoders from `pragma.c`.

const std = @import("std");
const sqlite_string = @import("../string.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");

fn decimal(text: [*:0]const u8) c_int {
    var index: usize = 0;
    var sign: c_int = 1;
    if (text[0] == '-') {
        sign = -1;
        index = 1;
    } else if (text[0] == '+') index = 1;
    var value: c_int = 0;
    while (text[index] >= '0' and text[index] <= '9') : (index += 1) value = value * 10 + text[index] - '0';
    return value * sign;
}

/// Source `getSafetyLevel()`.
pub fn safetyLevel(text: [*:0]const u8, omit_full: bool, default: u8) u8 {
    const names = [_][]const u8{ "on", "no", "off", "false", "yes", "true", "extra", "full" };
    const values = [_]u8{ 1, 0, 0, 0, 1, 1, 3, 2 };
    if (text[0] >= '0' and text[0] <= '9') return @intCast(decimal(text));
    const input = std.mem.span(text);
    for (names, values) |name, value| {
        if (input.len == name.len and sqlite_string.compareN(text, @ptrCast(name.ptr), @intCast(input.len)) == 0 and (!omit_full or value <= 1)) return value;
    }
    return default;
}

/// Source `sqlite3GetBoolean()`.
pub fn boolean(text: [*:0]const u8, default: bool) bool {
    return safetyLevel(text, true, @intFromBool(default)) != 0;
}

/// Source `getLockingMode()`.
pub fn lockingMode(text: ?[*:0]const u8) c_int {
    const present = text orelse return -1;
    if (sqlite_string.compareInternal(present, "exclusive") == 0) return 1;
    if (sqlite_string.compareInternal(present, "normal") == 0) return 0;
    return -1;
}

/// Source `getAutoVacuum()`.
pub fn autoVacuum(text: [*:0]const u8) c_int {
    if (sqlite_string.compareInternal(text, "none") == 0) return 0;
    if (sqlite_string.compareInternal(text, "full") == 0) return 1;
    if (sqlite_string.compareInternal(text, "incremental") == 0) return 2;
    const value = decimal(text);
    return if (value >= 0 and value <= 2) value else 0;
}

/// Source `actionName()`.
pub fn actionName(action: u8) [*:0]const u8 {
    return switch (action) {
        parse_types.foreign_action.set_null => "SET NULL",
        parse_types.foreign_action.set_default => "SET DEFAULT",
        parse_types.foreign_action.cascade => "CASCADE",
        parse_types.foreign_action.restrict => "RESTRICT",
        else => "NO ACTION",
    };
}

/// Source `sqlite3JournalModename()`.
pub fn journalModeName(mode: c_int) ?[*:0]const u8 {
    const names = [_][*:0]const u8{ "delete", "persist", "off", "truncate", "memory", "wal" };
    if (mode < 0 or mode >= names.len) return null;
    return names[@intCast(mode)];
}

/// Source `tableSkipIntegrityCheck()`.
pub fn tableSkipIntegrityCheck(table: *const schema.Table, requested: ?*const schema.Table) bool {
    if (requested) |selected| return table != selected;
    return table.flags & 0x0002_0000 != 0;
}

/// Source `getTempStore()`.
pub fn tempStore(text: [*:0]const u8) c_int {
    if (text[0] >= '0' and text[0] <= '2') return text[0] - '0';
    if (sqlite_string.compareInternal(text, "file") == 0) return 1;
    if (sqlite_string.compareInternal(text, "memory") == 0) return 2;
    return 0;
}
