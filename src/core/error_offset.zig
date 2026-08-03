//! Source-corresponding parser and expression error-offset recording.

const std = @import("std");

pub const expression_outer_on: u32 = 0x0000_0001;
pub const expression_inner_on: u32 = 0x0000_0002;
pub const expression_from_ddl: u32 = 0x4000_0000;

/// Minimal typed view of the Parse field used by sqlite3RecordErrorByteOffset.
pub const ParseView = struct {
    tail: ?[*:0]const u8,
};

/// Minimal typed view of the sqlite3 fields used by both offset helpers.
pub const ConnectionView = struct {
    error_byte_offset: c_int,
    parse: ?*const ParseView,
};

/// Minimal typed view of the Expr fields used by sqlite3RecordErrorOffsetOfExpr.
pub const ExpressionView = struct {
    flags: u32,
    offset: c_int,
    left: ?*const ExpressionView,
};

/// Upstream: sqlite3RecordErrorByteOffset().
pub fn recordByteOffset(connection: *ConnectionView, token: [*]const u8) void {
    if (connection.error_byte_offset != -2) return;
    const parse = connection.parse orelse return;
    const text = parse.tail orelse return;
    const length = std.mem.len(text);
    const start = @intFromPtr(text);
    const candidate = @intFromPtr(token);
    if (candidate >= start and candidate < start + length) {
        connection.error_byte_offset = @intCast(candidate - start);
    }
}

/// Upstream: sqlite3RecordErrorOffsetOfExpr().
pub fn recordExpressionOffset(connection: *ConnectionView, expression_optional: ?*const ExpressionView) void {
    var expression = expression_optional;
    while (expression) |value| {
        if (value.flags & (expression_outer_on | expression_inner_on) == 0 and value.offset > 0) break;
        expression = value.left;
    }
    const value = expression orelse return;
    if (value.flags & expression_from_ddl != 0) return;
    connection.error_byte_offset = value.offset;
}

test "byte offsets preserve sentinel range and first-error behavior" {
    const sql: [:0]const u8 = "select token";
    var parse = ParseView{ .tail = sql };
    var connection = ConnectionView{ .error_byte_offset = -2, .parse = &parse };
    recordByteOffset(&connection, sql.ptr + 7);
    try std.testing.expectEqual(@as(c_int, 7), connection.error_byte_offset);
    recordByteOffset(&connection, sql.ptr + 2);
    try std.testing.expectEqual(@as(c_int, 7), connection.error_byte_offset);
    connection.error_byte_offset = -2;
    recordByteOffset(&connection, sql.ptr + sql.len);
    try std.testing.expectEqual(@as(c_int, -2), connection.error_byte_offset);
}

test "expression offsets traverse join and empty nodes and reject DDL" {
    const leaf = ExpressionView{ .flags = 0, .offset = 9, .left = null };
    const join = ExpressionView{ .flags = expression_outer_on, .offset = 2, .left = &leaf };
    var connection = ConnectionView{ .error_byte_offset = -2, .parse = null };
    recordExpressionOffset(&connection, &join);
    try std.testing.expectEqual(@as(c_int, 9), connection.error_byte_offset);
    const ddl = ExpressionView{ .flags = expression_from_ddl, .offset = 4, .left = null };
    connection.error_byte_offset = -2;
    recordExpressionOffset(&connection, &ddl);
    try std.testing.expectEqual(@as(c_int, -2), connection.error_byte_offset);
}
