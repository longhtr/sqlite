const std = @import("std");
const statement = @import("statement");
const vdbe = statement.vdbe;

const binding_ops = [_]vdbe.Instruction{
    .{ .opcode = .result_row, .p1 = 1, .p2 = 4 },
    .{ .opcode = .halt },
};
const binding_program = vdbe.Program{ .instructions = &binding_ops, .register_count = 4 };
const parameters = [_]statement.ParameterMetadata{
    .{ .name = ":integer" }, .{ .name = "@text" }, .{ .name = "$blob" }, .{ .name = "?4" },
};
const columns = [_]statement.ColumnMetadata{
    .{ .name = "integer" }, .{ .name = "text" }, .{ .name = "blob" }, .{ .name = "utf16" },
};
const error_ops = [_]vdbe.Instruction{.{ .opcode = .halt, .p1 = 2067 }};
const error_program = vdbe.Program{ .instructions = &error_ops, .register_count = 1 };
const extended_result_mask: c_int = -1;

export fn sqlite3_zig_phase12_fixture(name: [*:0]const u8) ?*statement.sqlite3_stmt {
    if (statement.public_api.sqlite3_initialize() != 0) return null;
    const bytes = std.mem.span(name);
    const created = if (std.mem.eql(u8, bytes, "bindings"))
        statement.Statement.create(std.heap.c_allocator, &binding_program, &parameters, &columns)
    else if (std.mem.eql(u8, bytes, "error"))
        statement.Statement.create(std.heap.c_allocator, &error_program, &.{}, &.{})
    else
        return null;
    const prepared = created catch return null;
    prepared.setResultMask(&extended_result_mask);
    return statement.toOpaque(prepared);
}

comptime {
    _ = &statement.sqlite3_step;
    _ = &statement.sqlite3_reset;
    _ = &statement.sqlite3_finalize;
    _ = &statement.sqlite3_clear_bindings;
    _ = &statement.sqlite3_bind_parameter_count;
    _ = &statement.sqlite3_bind_parameter_name;
    _ = &statement.sqlite3_bind_parameter_index;
    _ = &statement.sqlite3_bind_null;
    _ = &statement.sqlite3_bind_int;
    _ = &statement.sqlite3_bind_int64;
    _ = &statement.sqlite3_bind_double;
    _ = &statement.sqlite3_bind_text;
    _ = &statement.sqlite3_bind_text16;
    _ = &statement.sqlite3_bind_text64;
    _ = &statement.sqlite3_bind_blob;
    _ = &statement.sqlite3_bind_blob64;
    _ = &statement.sqlite3_bind_zeroblob;
    _ = &statement.sqlite3_bind_zeroblob64;
    _ = &statement.sqlite3_column_count;
    _ = &statement.sqlite3_data_count;
    _ = &statement.sqlite3_column_type;
    _ = &statement.sqlite3_column_int;
    _ = &statement.sqlite3_column_int64;
    _ = &statement.sqlite3_column_double;
    _ = &statement.sqlite3_column_text;
    _ = &statement.sqlite3_column_text16;
    _ = &statement.sqlite3_column_blob;
    _ = &statement.sqlite3_column_bytes;
    _ = &statement.sqlite3_column_bytes16;
    _ = &statement.sqlite3_column_name;
    _ = &statement.sqlite3_stmt_busy;
    _ = &statement.sqlite3_stmt_readonly;
    _ = &statement.sqlite3_stmt_isexplain;
}
