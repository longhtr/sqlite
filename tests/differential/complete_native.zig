const std = @import("std");
const complete = @import("complete");

fn show8(id: usize, sql: []const u8) void {
    std.debug.print("{d}\t{d}\n", .{ id, @intFromBool(complete.isComplete(sql)) });
}
fn show16(id: usize, sql: []const u16) void {
    std.debug.print("{d}\t{d}\n", .{ id, @intFromBool(complete.isCompleteUtf16(sql)) });
}
pub fn main() void {
    show8(1, "");
    show8(2, "  \n");
    show8(3, "select 1;");
    show8(4, "select ';'");
    show8(5, "select ';'; -- tail");
    show8(6, "select 1; /* tail */");
    show8(7, "select 1; /* tail");
    show8(8, "create table t(x);");
    show8(9, "create trigger t after insert on x begin select 1; end");
    show8(10, "create trigger t after insert on x begin select 1; end;");
    show8(11, "explain create temporary trigger t after insert on x begin select 1; end;");
    show8(12, "select [unterminated");
    show16(13, &.{ 's', 'e', 'l', 'e', 'c', 't', ' ', 0x20ac, ';' });
    show16(14, &.{ 's', 'e', 'l', 'e', 'c', 't', ' ', 0x20ac });
    show16(15, &.{ 'c', 'r', 'e', 'a', 't', 'e', ' ', 't', 'r', 'i', 'g', 'g', 'e', 'r', ' ', 't', ' ', 'b', 'e', 'g', 'i', 'n', ' ', 'e', 'n', 'd', ';' });
    show16(16, &.{ 'c', 'r', 'e', 'a', 't', 'e', ' ', 't', 'r', 'i', 'g', 'g', 'e', 'r', ' ', 't', ' ', 'b', 'e', 'g', 'i', 'n', ' ', 'e', 'n', 'd', ';', ' ', 'e', 'n', 'd', ';' });
}
