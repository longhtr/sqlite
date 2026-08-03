const offset = @import("error_offset");
const std = @import("std");

fn show(id: usize, connection: *const offset.ConnectionView) void {
    std.debug.print("{d}\t{d}\n", .{ id, connection.error_byte_offset });
}
pub fn main() void {
    const sql: [:0]const u8 = "select token";
    const outside: [:0]const u8 = "outside";
    var parse = offset.ParseView{ .tail = sql };
    var connection = offset.ConnectionView{ .error_byte_offset = -2, .parse = &parse };
    offset.recordByteOffset(&connection, sql.ptr + 7);
    show(1, &connection);
    offset.recordByteOffset(&connection, sql.ptr + 2);
    show(2, &connection);
    connection.error_byte_offset = -2;
    offset.recordByteOffset(&connection, outside.ptr);
    show(3, &connection);
    connection.error_byte_offset = -2;
    connection.parse = null;
    offset.recordByteOffset(&connection, sql.ptr + 1);
    show(4, &connection);
    connection.error_byte_offset = -2;
    connection.parse = &parse;
    offset.recordByteOffset(&connection, sql.ptr + sql.len);
    show(5, &connection);
    var leaf = offset.ExpressionView{ .flags = 0, .offset = 7, .left = null };
    connection.error_byte_offset = -2;
    offset.recordExpressionOffset(&connection, &leaf);
    show(6, &connection);
    var parent = offset.ExpressionView{ .flags = 0, .offset = 0, .left = &leaf };
    connection.error_byte_offset = -2;
    offset.recordExpressionOffset(&connection, &parent);
    show(7, &connection);
    parent = .{ .flags = offset.expression_outer_on, .offset = 3, .left = &leaf };
    connection.error_byte_offset = -2;
    offset.recordExpressionOffset(&connection, &parent);
    show(8, &connection);
    leaf = .{ .flags = offset.expression_from_ddl, .offset = 4, .left = null };
    connection.error_byte_offset = -2;
    offset.recordExpressionOffset(&connection, &leaf);
    show(9, &connection);
    connection.error_byte_offset = -2;
    offset.recordExpressionOffset(&connection, null);
    show(10, &connection);
}
