const std = @import("std");
const strings = @import("sqlite_string");
const Token = struct { z: ?[*]const u8, n: c_uint };

fn show(id: usize, original: []const u8) void {
    var buffer: [32:0]u8 = [_:0]u8{0} ** 32;
    @memcpy(buffer[0..original.len], original);
    strings.dequote(&buffer);
    const text = std.mem.span(@as([*:0]u8, &buffer));
    std.debug.print("{d}\tD\t{d}\t", .{ id, text.len });
    for (text) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}
fn token(id: usize, text: [:0]const u8) void {
    var value = Token{ .z = text.ptr, .n = @intCast(text.len) };
    strings.dequoteToken(&value);
    std.debug.print("{d}\tT\t{d}\t{d}\n", .{ id, @intFromPtr(value.z.?) - @intFromPtr(text.ptr), value.n });
}
fn expression(id: usize, original: []const u8) void {
    var buffer: [32:0]u8 = [_:0]u8{0} ** 32;
    @memcpy(buffer[0..original.len], original);
    var value = strings.ExpressionTokenView{ .text = &buffer, .flags = 0 };
    strings.dequoteExpression(&value);
    std.debug.print("{d}\tE\t{d}\t{s}\n", .{ id, value.flags & (strings.expression_quoted | strings.expression_double_quoted), std.mem.span(value.text) });
}
fn number(id: usize, original: []const u8) void {
    var buffer: [32:0]u8 = [_:0]u8{0} ** 32;
    @memcpy(buffer[0..original.len], original);
    const result = strings.dequoteNumber(&buffer);
    const int_value = result.integer_value orelse 0;
    const text = if (result.integer_value == null) std.mem.span(@as([*:0]u8, &buffer)) else "";
    std.debug.print("{d}\tN\t{c}\t{d}\t{d}\t{d}\t{s}\n", .{ id, if (result.kind == .integer) @as(u8, 'I') else 'F', @intFromBool(result.integer_value != null), int_value, @intFromBool(result.invalid_separator), text });
}
pub fn main() void {
    show(1, "'a''b'");
    show(2, "[a-b]");
    show(3, "`a``b`");
    show(4, "plain");
    show(5, "\"a\"\"b\"");
    token(6, "\"abc\"");
    token(7, "\"ab\"\"cd\"");
    token(8, "\"\"");
    var initialized = Token{ .z = null, .n = 0 };
    strings.tokenInit(&initialized, "token");
    std.debug.print("9\tI\t{d}\n", .{initialized.n});
    expression(10, "\"name\"");
    expression(11, "'value'");
    number(12, "1_23");
    number(13, "1_2.5e+1");
    number(14, "1_.2");
    number(15, "0x7fff_ffff");
}
