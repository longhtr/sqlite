//! EXPLAIN opcode enumeration and rendering from `vdbeaux.c`.

const std = @import("std");
const vdbe = @import("../vdbe.zig");

pub const OpcodeLocation = struct {
    address: usize,
    operation: *const vdbe.Instruction,
};

pub const Iterator = struct {
    program: *const vdbe.Program,
    pc: usize = 0,

    /// Source `sqlite3VdbeNextOpcode()`: enumerate the main program followed
    /// by each attached subprogram, preserving a single logical address.
    pub fn nextOpcode(self: *Iterator) ?OpcodeLocation {
        var remaining = self.pc;
        self.pc += 1;
        if (remaining < self.program.instructions.len) {
            return .{ .address = remaining, .operation = &self.program.instructions[remaining] };
        }
        remaining -= self.program.instructions.len;
        for (self.program.subprograms) |subprogram| {
            if (remaining < subprogram.instructions.len) {
                return .{ .address = remaining, .operation = &subprogram.instructions[remaining] };
            }
            remaining -= subprogram.instructions.len;
        }
        return null;
    }
};

/// Source `sqlite3VdbeDisplayP4()`: render every bounded P4 representation
/// into statement-owned text suitable for EXPLAIN output.
pub fn displayP4(allocator: std.mem.Allocator, value: vdbe.P4) std.mem.Allocator.Error![]u8 {
    return switch (value) {
        .none => allocator.dupe(u8, ""),
        .integer => |integer| std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .real => |real| std.fmt.allocPrint(allocator, "{d}", .{real}),
        .bytes => |bytes| allocator.dupe(u8, bytes),
        .index => |index| std.fmt.allocPrint(allocator, "{d}", .{index}),
        .collation => |index| std.fmt.allocPrint(allocator, "collation({d})", .{index}),
    };
}

pub const ExplainRow = struct {
    address: usize,
    opcode: []const u8,
    p1: i32,
    p2: i32,
    p3: i32,
    p4: []u8,
    p5: u16,
};

pub fn deinitRows(allocator: std.mem.Allocator, rows: []ExplainRow) void {
    for (rows) |row| {
        allocator.free(row.p4);
    }
    allocator.free(rows);
}

/// Source `sqlite3VdbeList()`: materialize the complete opcode listing used
/// by an EXPLAIN statement, including attached trigger subprograms.
pub fn list(allocator: std.mem.Allocator, program: *const vdbe.Program) std.mem.Allocator.Error![]ExplainRow {
    var rows = std.ArrayList(ExplainRow).empty;
    errdefer {
        for (rows.items) |row| {
            allocator.free(row.p4);
        }
        rows.deinit(allocator);
    }
    var iterator = Iterator{ .program = program };
    while (iterator.nextOpcode()) |located| {
        const operation = located.operation;
        const p4 = try displayP4(allocator, operation.p4);
        errdefer allocator.free(p4);
        try rows.append(allocator, .{
            .address = located.address,
            .opcode = @tagName(operation.opcode),
            .p1 = operation.p1,
            .p2 = operation.p2,
            .p3 = operation.p3,
            .p4 = p4,
            .p5 = operation.p5,
        });
    }
    return rows.toOwnedSlice(allocator);
}
