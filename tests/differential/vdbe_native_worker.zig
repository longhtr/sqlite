const std = @import("std");
const vdbe = @import("vdbe");

fn encode(value: vdbe.Mem) void {
    var mem = value;
    switch (vdbe.vdbe_mem.valueType(&mem)) {
        1 => std.debug.print("\tI:{d}", .{vdbe.vdbe_mem.valueInt64(&mem)}),
        2 => std.debug.print("\tR:{d}", .{vdbe.vdbe_mem.valueDouble(&mem)}),
        3 => {
            std.debug.print("\tT:", .{});
            const bytes = vdbe.vdbe_mem.valueText(&mem, 1).?[0..@intCast(mem.n)];
            for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
        },
        4 => {
            std.debug.print("\tB:", .{});
            const bytes = vdbe.vdbe_mem.valueBlob(&mem);
            if (bytes) |data| for (data[0..@intCast(mem.n)]) |byte| std.debug.print("{x:0>2}", .{byte});
        },
        else => std.debug.print("\tN", .{}),
    }
}

fn execute(name: []const u8, program: *const vdbe.Program) !void {
    var vm = try vdbe.Vm.init(std.heap.c_allocator, program, null);
    defer vm.deinit();
    var row: usize = 0;
    while (true) {
        const outcome = vm.step();
        if (outcome.result == .row) {
            std.debug.print("{s}\trow:{d}", .{ name, row });
            for (0..vm.columnCount()) |index| encode(vm.column(index).?.*);
            std.debug.print("\n{s}\tregisters:{d}", .{ name, row });
            for (0..vm.columnCount()) |index| encode(vm.column(index).?.*);
            std.debug.print("\n", .{});
            row += 1;
        } else {
            std.debug.print("{s}\tdone\t{d}\t{d}\n", .{ name, outcome.result.toC(), @intFromEnum(outcome.state) });
            break;
        }
    }
}

fn absFunction(_: ?*anyopaque, arguments: []vdbe.Mem, output: *vdbe.Mem, _: std.mem.Allocator) vdbe.ResultCode {
    if (arguments.len != 1 or vdbe.vdbe_mem.valueType(&arguments[0]) != 1) return .misuse;
    const value = vdbe.vdbe_mem.valueInt64(&arguments[0]);
    vdbe.vdbe_mem.setInt64(output, if (value < 0) -value else value);
    return .ok;
}
fn lengthFunction(_: ?*anyopaque, arguments: []vdbe.Mem, output: *vdbe.Mem, _: std.mem.Allocator) vdbe.ResultCode {
    if (arguments.len != 1 or vdbe.vdbe_mem.valueType(&arguments[0]) != 3) return .misuse;
    vdbe.vdbe_mem.setInt64(output, vdbe.vdbe_mem.valueBytes(&arguments[0], 1));
    return .ok;
}

const scalar_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 7, .p2 = 1 },                 .{ .opcode = .integer, .p1 = 5, .p2 = 2 },
    .{ .opcode = .add, .p1 = 2, .p2 = 1, .p3 = 3 },            .{ .opcode = .subtract, .p1 = 2, .p2 = 1, .p3 = 4 },
    .{ .opcode = .multiply, .p1 = 2, .p2 = 1, .p3 = 5 },       .{ .opcode = .divide, .p1 = 2, .p2 = 1, .p3 = 6 },
    .{ .opcode = .remainder, .p1 = 2, .p2 = 1, .p3 = 7 },      .{ .opcode = .string, .p2 = 8, .p4 = .{ .bytes = "ab" } },
    .{ .opcode = .string, .p2 = 9, .p4 = .{ .bytes = "cd" } }, .{ .opcode = .concat, .p1 = 9, .p2 = 8, .p3 = 10 },
    .{ .opcode = .integer, .p1 = 0, .p2 = 11 },                .{ .opcode = .not, .p1 = 11, .p2 = 12 },
    .{ .opcode = .null_, .p2 = 13 },                           .{ .opcode = .and_, .p1 = 11, .p2 = 13, .p3 = 14 },
    .{ .opcode = .integer, .p1 = 1, .p2 = 15 },                .{ .opcode = .or_, .p1 = 15, .p2 = 13, .p3 = 16 },
    .{ .opcode = .copy, .p1 = 10, .p2 = 8 },                   .{ .opcode = .copy, .p1 = 12, .p2 = 9 },
    .{ .opcode = .copy, .p1 = 14, .p2 = 10 },                  .{ .opcode = .copy, .p1 = 16, .p2 = 11 },
    .{ .opcode = .result_row, .p1 = 3, .p2 = 9 },              .{ .opcode = .halt },
};
const scalar_program = vdbe.Program{ .instructions = &scalar_ops, .register_count = 16 };

const cursor_rows = [_]vdbe.TableRow{
    .{ .rowid = 1, .values = &.{.{ .text = "one" }} },
    .{ .rowid = 3, .values = &.{.{ .text = "three" }} },
    .{ .rowid = 5, .values = &.{.{ .text = "five" }} },
};
const cursor_tables = [_]vdbe.Table{.{ .rows = &cursor_rows }};
const cursor_ops = [_]vdbe.Instruction{
    .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },  .{ .opcode = .rewind, .p1 = 0, .p2 = 6 },
    .{ .opcode = .rowid, .p1 = 0, .p2 = 1 },      .{ .opcode = .column, .p1 = 0, .p2 = 0, .p3 = 2 },
    .{ .opcode = .result_row, .p1 = 1, .p2 = 2 }, .{ .opcode = .next, .p1 = 0, .p2 = 2 },
    .{ .opcode = .halt },
};
const cursor_program = vdbe.Program{ .instructions = &cursor_ops, .register_count = 2, .cursor_count = 1, .tables = &cursor_tables };

const functions = [_]vdbe.Function{ .{ .callback = absFunction }, .{ .callback = lengthFunction } };
const function_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = -9, .p2 = 1 },                 .{ .opcode = .function, .p1 = 1, .p2 = 1, .p3 = 3, .p4 = .{ .index = 0 } },
    .{ .opcode = .string, .p2 = 2, .p4 = .{ .bytes = "zig" } }, .{ .opcode = .function, .p1 = 1, .p2 = 2, .p3 = 4, .p4 = .{ .index = 1 } },
    .{ .opcode = .null_, .p2 = 5 },                             .{ .opcode = .string, .p2 = 6, .p4 = .{ .bytes = "fallback" } },
    .{ .opcode = .is_null, .p1 = 5, .p2 = 8 },                  .{ .opcode = .copy, .p1 = 5, .p2 = 6 },
    .{ .opcode = .result_row, .p1 = 3, .p2 = 4 },               .{ .opcode = .halt },
};
const function_program = vdbe.Program{ .instructions = &function_ops, .register_count = 6, .functions = &functions };

const sub_ops = [_]vdbe.Instruction{ .{ .opcode = .integer, .p1 = 42, .p2 = 2 }, .{ .opcode = .halt } };
const subs = [_]vdbe.Subprogram{.{ .instructions = &sub_ops }};
const frame_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 8, .p2 = 1 },      .{ .opcode = .program, .p4 = .{ .index = 0 } },
    .{ .opcode = .add, .p1 = 1, .p2 = 2, .p3 = 3 }, .{ .opcode = .result_row, .p1 = 2, .p2 = 2 },
    .{ .opcode = .halt },
};
const frame_program = vdbe.Program{ .instructions = &frame_ops, .register_count = 3, .subprograms = &subs };

const comparison_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 7, .p2 = 1 },      .{ .opcode = .integer, .p1 = 7, .p2 = 2 },
    .{ .opcode = .integer, .p1 = 0, .p2 = 3 },      .{ .opcode = .eq, .p1 = 2, .p2 = 5, .p3 = 1 },
    .{ .opcode = .goto, .p2 = 6 },                  .{ .opcode = .integer, .p1 = 1, .p2 = 3 },
    .{ .opcode = .integer, .p1 = 5, .p2 = 2 },      .{ .opcode = .integer, .p1 = 0, .p2 = 4 },
    .{ .opcode = .gt, .p1 = 2, .p2 = 10, .p3 = 1 }, .{ .opcode = .goto, .p2 = 11 },
    .{ .opcode = .integer, .p1 = 1, .p2 = 4 },      .{ .opcode = .null_, .p2 = 5 },
    .{ .opcode = .result_row, .p1 = 3, .p2 = 3 },   .{ .opcode = .halt },
};
const comparison_program = vdbe.Program{ .instructions = &comparison_ops, .register_count = 5 };

const cast_ops = [_]vdbe.Instruction{
    .{ .opcode = .string, .p2 = 1, .p4 = .{ .bytes = "42" } }, .{ .opcode = .copy, .p1 = 1, .p2 = 2 },
    .{ .opcode = .must_be_int, .p1 = 2 },                      .{ .opcode = .real_affinity, .p1 = 2 },
    .{ .opcode = .copy, .p1 = 1, .p2 = 3 },                    .{ .opcode = .to_blob, .p1 = 3 },
    .{ .opcode = .result_row, .p1 = 1, .p2 = 3 },              .{ .opcode = .halt },
};
const cast_program = vdbe.Program{ .instructions = &cast_ops, .register_count = 3 };

const seek_ops = [_]vdbe.Instruction{
    .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },  .{ .opcode = .count, .p1 = 0, .p2 = 3 },
    .{ .opcode = .integer, .p1 = 3, .p2 = 4 },    .{ .opcode = .seek_rowid, .p1 = 0, .p2 = 8, .p3 = 4 },
    .{ .opcode = .rowid, .p1 = 0, .p2 = 1 },      .{ .opcode = .column, .p1 = 0, .p2 = 0, .p3 = 2 },
    .{ .opcode = .result_row, .p1 = 1, .p2 = 3 }, .{ .opcode = .halt },
    .{ .opcode = .halt, .p1 = 11 },
};
const seek_program = vdbe.Program{ .instructions = &seek_ops, .register_count = 4, .cursor_count = 1, .tables = &cursor_tables };

const coroutine_ops = [_]vdbe.Instruction{
    .{ .opcode = .init_coroutine, .p1 = 1, .p2 = 6, .p3 = 3 }, .{ .opcode = .noop },
    .{ .opcode = .yield, .p1 = 1, .p2 = 5 },                   .{ .opcode = .result_row, .p1 = 2, .p2 = 1 },
    .{ .opcode = .goto, .p2 = 2 },                             .{ .opcode = .halt },
    .{ .opcode = .integer, .p1 = 10, .p2 = 2 },                .{ .opcode = .yield, .p1 = 1 },
    .{ .opcode = .integer, .p1 = 20, .p2 = 2 },                .{ .opcode = .yield, .p1 = 1 },
    .{ .opcode = .end_coroutine, .p1 = 1 },
};
const coroutine_program = vdbe.Program{ .instructions = &coroutine_ops, .register_count = 2 };
const extended_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 5, .p2 = 1 },
    .{ .opcode = .bit_not, .p1 = 1, .p2 = 2 },
    .{ .opcode = .null_, .p2 = 3 },
    .{ .opcode = .is_true, .p1 = 3, .p2 = 4, .p3 = 0, .p4 = .{ .integer = 0 } },
    .{ .opcode = .is_true, .p1 = 3, .p2 = 5, .p3 = 0, .p4 = .{ .integer = 1 } },
    .{ .opcode = .string8, .p2 = 6, .p4 = .{ .bytes = "42" } },
    .{ .opcode = .cast, .p1 = 6, .p2 = 0x44 },
    .{ .opcode = .copy, .p1 = 4, .p2 = 3 },
    .{ .opcode = .copy, .p1 = 5, .p2 = 4 },
    .{ .opcode = .copy, .p1 = 6, .p2 = 5 },
    .{ .opcode = .result_row, .p1 = 2, .p2 = 4 },
    .{ .opcode = .halt },
};
const cursor_state_rows = [_]vdbe.TableRow{
    .{ .rowid = 1, .values = &.{.{ .integer = 1 }} },
    .{ .rowid = 2, .values = &.{.{ .integer = 2 }} },
};
const cursor_state_tables = [_]vdbe.Table{ .{ .rows = &cursor_state_rows }, .{ .rows = &.{} } };
const cursor_state_ops = [_]vdbe.Instruction{
    .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },
    .{ .opcode = .open_data, .p1 = 1, .p2 = 1 },
    .{ .opcode = .if_empty, .p1 = 1, .p2 = 4 },
    .{ .opcode = .halt, .p1 = 11 },
    .{ .opcode = .rewind, .p1 = 0, .p2 = 20 },
    .{ .opcode = .sequence, .p1 = 0, .p2 = 3 },
    .{ .opcode = .column, .p1 = 0, .p2 = 0, .p3 = 1 },
    .{ .opcode = .integer, .p1 = 1, .p2 = 4 },
    .{ .opcode = .eq, .p1 = 4, .p2 = 16, .p3 = 1 },
    .{ .opcode = .null_row, .p1 = 1 },
    .{ .opcode = .column, .p1 = 1, .p2 = 0, .p3 = 2 },
    .{ .opcode = .if_null_row, .p1 = 1, .p2 = 13, .p3 = 2 },
    .{ .opcode = .halt, .p1 = 11 },
    .{ .opcode = .if_not_open, .p1 = 1, .p2 = 15 },
    .{ .opcode = .halt, .p1 = 11 },
    .{ .opcode = .goto, .p2 = 18 },
    .{ .opcode = .string, .p2 = 2, .p4 = .{ .bytes = "one" } },
    .{ .opcode = .sequence_test, .p1 = 0, .p2 = 18 },
    .{ .opcode = .result_row, .p1 = 1, .p2 = 2 },
    .{ .opcode = .next, .p1 = 0, .p2 = 5 },
    .{ .opcode = .halt },
};
const cursor_state_program = vdbe.Program{ .instructions = &cursor_state_ops, .register_count = 4, .cursor_count = 2, .tables = &cursor_state_tables };
const variable_values = [_]vdbe.Literal{ .{ .text = "bound" }, .{ .integer = 42 }, .null_ };
const variable_ops = [_]vdbe.Instruction{
    .{ .opcode = .variable, .p1 = 1, .p2 = 1 },
    .{ .opcode = .variable, .p1 = 2, .p2 = 2 },
    .{ .opcode = .variable, .p1 = 3, .p2 = 3 },
    .{ .opcode = .result_row, .p1 = 1, .p2 = 3 },
    .{ .opcode = .halt },
};
const variable_program = vdbe.Program{ .instructions = &variable_ops, .register_count = 3, .variables = &variable_values };
const record_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 42, .p2 = 1 },
    .{ .opcode = .string8, .p2 = 2, .p4 = .{ .bytes = "hi" } },
    .{ .opcode = .null_, .p2 = 3 },
    .{ .opcode = .real, .p2 = 4, .p4 = .{ .real = 3.5 } },
    .{ .opcode = .blob, .p2 = 5, .p4 = .{ .bytes = &.{ 0, 255 } } },
    .{ .opcode = .make_record, .p1 = 1, .p2 = 5, .p3 = 6 },
    .{ .opcode = .result_row, .p1 = 6, .p2 = 1 },
    .{ .opcode = .halt },
};
const record_program = vdbe.Program{ .instructions = &record_ops, .register_count = 6 };
const extended_program = vdbe.Program{ .instructions = &extended_ops, .register_count = 6 };
const rowset_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 9, .p2 = 2 },
    .{ .opcode = .row_set_add, .p1 = 1, .p2 = 2 },
    .{ .opcode = .integer, .p1 = 3, .p2 = 2 },
    .{ .opcode = .row_set_add, .p1 = 1, .p2 = 2 },
    .{ .opcode = .integer, .p1 = 9, .p2 = 2 },
    .{ .opcode = .row_set_add, .p1 = 1, .p2 = 2 },
    .{ .opcode = .row_set_read, .p1 = 1, .p2 = 9, .p3 = 3 },
    .{ .opcode = .result_row, .p1 = 3, .p2 = 1 },
    .{ .opcode = .goto, .p2 = 6 },
    .{ .opcode = .halt },
};
const rowset_program = vdbe.Program{ .instructions = &rowset_ops, .register_count = 3 };
const rowset_test_ops = [_]vdbe.Instruction{
    .{ .opcode = .integer, .p1 = 10, .p2 = 2 },
    .{ .opcode = .row_set_test, .p1 = 1, .p2 = 6, .p3 = 2, .p4 = .{ .integer = 0 } },
    .{ .opcode = .integer, .p1 = 10, .p2 = 2 },
    .{ .opcode = .row_set_test, .p1 = 1, .p2 = 6, .p3 = 2, .p4 = .{ .integer = 1 } },
    .{ .opcode = .integer, .p1 = 0, .p2 = 3 },
    .{ .opcode = .goto, .p2 = 7 },
    .{ .opcode = .integer, .p1 = 1, .p2 = 3 },
    .{ .opcode = .result_row, .p1 = 3, .p2 = 1 },
    .{ .opcode = .halt },
};
const rowset_test_program = vdbe.Program{ .instructions = &rowset_test_ops, .register_count = 3 };
const error_ops = [_]vdbe.Instruction{.{ .opcode = .halt, .p1 = 19 }};
const error_program = vdbe.Program{ .instructions = &error_ops, .register_count = 1 };

pub fn main(init: std.process.Init) !void {
    if (vdbe.public_api.sqlite3_initialize() != 0) return error.InitializeFailed;
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const name = arguments.next() orelse return error.Arguments;
    if (std.mem.eql(u8, name, "scalar")) try execute(name, &scalar_program) else if (std.mem.eql(u8, name, "cursor")) try execute(name, &cursor_program) else if (std.mem.eql(u8, name, "function")) try execute(name, &function_program) else if (std.mem.eql(u8, name, "frame")) try execute(name, &frame_program) else if (std.mem.eql(u8, name, "comparison")) try execute(name, &comparison_program) else if (std.mem.eql(u8, name, "cast")) try execute(name, &cast_program) else if (std.mem.eql(u8, name, "seek")) try execute(name, &seek_program) else if (std.mem.eql(u8, name, "coroutine")) try execute(name, &coroutine_program) else if (std.mem.eql(u8, name, "extended")) try execute(name, &extended_program) else if (std.mem.eql(u8, name, "cursor_state")) try execute(name, &cursor_state_program) else if (std.mem.eql(u8, name, "variable")) try execute(name, &variable_program) else if (std.mem.eql(u8, name, "record")) try execute(name, &record_program) else if (std.mem.eql(u8, name, "rowset")) try execute(name, &rowset_program) else if (std.mem.eql(u8, name, "rowset_test")) try execute(name, &rowset_test_program) else if (std.mem.eql(u8, name, "error")) try execute(name, &error_program) else return error.Arguments;
}
