//! Native bounded VDBE program, register, cursor, frame, and execution core.
//! The instruction format is intentionally Zig-owned. It models observable
//! SQLite VM behavior without sharing the private C Vdbe/VdbeOp layouts.

const std = @import("std");
pub const ResultCode = @import("result_code.zig").ResultCode;
pub const public_api = @import("public_api.zig");
pub const btree = @import("btree.zig");
const log_est = @import("log_est.zig");
const varint = @import("varint.zig");
pub const canonical_opcode = @import("generated/opcodes.zig");
pub const vdbe_mem = @import("internal/vdbe_mem.zig");
pub const vdbe_types = vdbe_mem.types;
pub const Mem = vdbe_types.Mem;
const mem_flag = vdbe_types.mem_flag;

pub const ValueTag = enum { null_, integer, real, text, blob };
pub const Literal = union(ValueTag) {
    null_,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Opcode = enum {
    init,
    goto,
    gosub,
    return_,
    init_coroutine,
    yield,
    end_coroutine,
    once,
    integer,
    int64,
    real,
    string,
    string8,
    blob,
    begin_subrtn,
    null_,
    soft_null,
    variable,
    move,
    copy,
    scopy,
    int_copy,
    add,
    subtract,
    multiply,
    divide,
    remainder,
    bit_and,
    bit_or,
    shift_left,
    shift_right,
    add_imm,
    concat,
    not,
    bit_not,
    and_,
    or_,
    is_true,
    zero_or_null,
    must_be_int,
    real_affinity,
    cast,
    affinity,
    make_record,
    to_text,
    to_blob,
    is_type,
    is_null,
    not_null,
    if_null_row,
    if_not_open,
    if_,
    if_not,
    if_pos,
    if_not_zero,
    decr_jump_zero,
    mem_max,
    offset_limit,
    row_set_add,
    row_set_read,
    row_set_test,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    else_eq,
    permutation,
    compare_values,
    jump,
    open_data,
    open_read,
    open_virtual,
    rewind,
    last,
    seek_end,
    if_size_between,
    if_empty,
    next,
    prev,
    sequence,
    sequence_test,
    null_row,
    seek_rowid,
    rowid,
    row_data,
    idx_rowid,
    column,
    count,
    close,
    function,
    pure_func,
    program,
    param,
    clr_subtype,
    get_subtype,
    set_subtype,
    result_row,
    halt_if_null,
    halt,
    noop,
};

pub const P4 = union(enum) {
    none,
    integer: i64,
    real: f64,
    bytes: []const u8,
    index: u16,
};

pub const Instruction = struct {
    opcode: Opcode,
    p1: i32 = 0,
    p2: i32 = 0,
    p3: i32 = 0,
    p4: P4 = .none,
    p5: u16 = 0,
};

pub const TableRow = struct { rowid: i64, values: []const Literal };
pub const Table = struct { rows: []const TableRow };
pub const Subprogram = struct { instructions: []const Instruction };

pub const FunctionCallback = *const fn (
    context: ?*anyopaque,
    arguments: []Mem,
    output: *Mem,
    allocator: std.mem.Allocator,
) ResultCode;
pub const Destructor = *const fn (?*anyopaque) void;
pub const Function = struct {
    callback: FunctionCallback,
    context: ?*anyopaque = null,
    destructor: ?Destructor = null,
};

pub const VirtualSource = struct {
    context: ?*anyopaque,
    open: *const fn (?*anyopaque, *?*anyopaque) ResultCode,
    close: *const fn (?*anyopaque) void,
    filter: *const fn (?*anyopaque) ResultCode,
    next: *const fn (?*anyopaque) ResultCode,
    eof: *const fn (?*anyopaque) bool,
    column: *const fn (?*anyopaque, usize, *Mem) ResultCode,
    rowid: *const fn (?*anyopaque, *i64) ResultCode,
};

pub const Program = struct {
    instructions: []const Instruction,
    register_count: u16,
    cursor_count: u16 = 0,
    tables: []const Table = &.{},
    functions: []const Function = &.{},
    subprograms: []const Subprogram = &.{},
    virtual_sources: []const VirtualSource = &.{},
    variables: []const Literal = &.{},
};

pub const State = enum { ready, running, row, halted, failed };
pub const StepOutcome = struct { result: ResultCode, state: State };
pub const ProgressCallback = *const fn (?*anyopaque, u64) bool;

const MemoryCursor = struct { table: usize, position: ?usize = null };
const VirtualCursor = struct { source: *const VirtualSource, handle: ?*anyopaque, result: ResultCode = .ok };
const Cursor = union(enum) {
    closed,
    memory: MemoryCursor,
    btree: btree.Cursor,
    virtual: VirtualCursor,

    fn deinit(self: *Cursor) void {
        switch (self.*) {
            .btree => |*cursor| cursor.deinit(),
            .virtual => |cursor| cursor.source.close(cursor.handle),
            else => {},
        }
        self.* = .closed;
    }
};

const Frame = struct {
    instructions: []const Instruction,
    pc: usize,
    subprogram: ?u16,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    program: *const Program,
    database: ?*btree.Database,
    registers: []Mem,
    cursors: []Cursor,
    cursor_null_rows: []bool,
    cursor_sequences: []i64,
    frames: std.ArrayList(Frame) = .empty,
    instructions: []const Instruction,
    pc: usize = 0,
    current_subprogram: ?u16 = null,
    state: State = .ready,
    result_code: ResultCode = .ok,
    result_first: usize = 0,
    result_count: usize = 0,
    executed: u64 = 0,
    instruction_limit: u64 = 100_000,
    interrupt_requested: bool = false,
    progress_interval: u64 = 0,
    progress_callback: ?ProgressCallback = null,
    progress_context: ?*anyopaque = null,
    functions_destroyed: bool = false,
    last_compare: std.math.Order = .eq,
    pending_permutation: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const Program,
        database: ?*btree.Database,
    ) !Vm {
        if (program.register_count == 0) return error.InvalidProgram;
        const registers = try allocator.alloc(Mem, @as(usize, program.register_count) + 1);
        errdefer allocator.free(registers);
        for (registers) |*mem| vdbe_mem.init(mem, null, mem_flag.null_);
        const cursors = try allocator.alloc(Cursor, program.cursor_count);
        errdefer allocator.free(cursors);
        @memset(cursors, .closed);
        const cursor_null_rows = try allocator.alloc(bool, program.cursor_count);
        errdefer allocator.free(cursor_null_rows);
        @memset(cursor_null_rows, false);
        const cursor_sequences = try allocator.alloc(i64, program.cursor_count);
        @memset(cursor_sequences, 0);
        return .{
            .allocator = allocator,
            .program = program,
            .database = database,
            .registers = registers,
            .cursors = cursors,
            .cursor_null_rows = cursor_null_rows,
            .cursor_sequences = cursor_sequences,
            .instructions = program.instructions,
        };
    }

    pub fn deinit(self: *Vm) void {
        for (self.cursors) |*cursor| cursor.deinit();
        self.allocator.free(self.cursor_sequences);
        self.allocator.free(self.cursor_null_rows);
        self.allocator.free(self.cursors);
        for (self.registers) |*value| vdbe_mem.release(value);
        self.allocator.free(self.registers);
        self.frames.deinit(self.allocator);
        self.destroyFunctions();
        self.cursors = &.{};
        self.cursor_null_rows = &.{};
        self.cursor_sequences = &.{};
        self.registers = &.{};
        self.state = .halted;
    }

    fn destroyFunctions(self: *Vm) void {
        if (self.functions_destroyed) return;
        self.functions_destroyed = true;
        for (self.program.functions) |function| {
            if (function.destructor) |destructor| destructor(function.context);
        }
    }

    pub fn requestInterrupt(self: *Vm) void {
        self.interrupt_requested = true;
    }

    pub fn setProgressHandler(self: *Vm, interval: u64, callback: ?ProgressCallback, context: ?*anyopaque) void {
        self.progress_interval = interval;
        self.progress_callback = callback;
        self.progress_context = context;
    }

    pub fn setInstructionLimit(self: *Vm, limit: u64) void {
        self.instruction_limit = limit;
    }

    pub fn register(self: *const Vm, index: usize) ?*const Mem {
        if (index == 0 or index >= self.registers.len) return null;
        return &self.registers[index];
    }

    pub fn assignRegister(self: *Vm, index: usize, value: *const Mem) ResultCode {
        if (index == 0 or index >= self.registers.len or self.state != .ready) return .misuse;
        return if (vdbe_mem.copy(&self.registers[index], value) == 0) .ok else .no_memory;
    }

    pub fn reset(self: *Vm) void {
        self.closeCursors();
        for (self.registers) |*value| vdbe_mem.setNull(value);
        self.frames.clearRetainingCapacity();
        self.instructions = self.program.instructions;
        self.pc = 0;
        self.current_subprogram = null;
        self.state = .ready;
        self.result_code = .ok;
        self.result_first = 0;
        self.result_count = 0;
        self.executed = 0;
        self.interrupt_requested = false;
        self.last_compare = .eq;
        self.pending_permutation = null;
        @memset(self.cursor_null_rows, false);
        @memset(self.cursor_sequences, 0);
    }

    pub fn columnCount(self: *const Vm) usize {
        return if (self.state == .row) self.result_count else 0;
    }

    pub fn column(self: *const Vm, index: usize) ?*const Mem {
        if (self.state != .row or index >= self.result_count) return null;
        return &self.registers[self.result_first + index];
    }

    fn closeCursors(self: *Vm) void {
        for (self.cursors, 0..) |*cursor, index| {
            cursor.deinit();
            self.cursor_null_rows[index] = false;
            self.cursor_sequences[index] = 0;
        }
    }

    fn fail(self: *Vm, result: ResultCode) StepOutcome {
        self.closeCursors();
        self.result_code = result;
        self.state = .failed;
        return .{ .result = result, .state = .failed };
    }

    fn checkRegister(self: *const Vm, value: i32) ?usize {
        if (value <= 0) return null;
        const index: usize = @intCast(value);
        return if (index < self.registers.len) index else null;
    }

    fn checkPc(self: *const Vm, value: i32) ?usize {
        if (value < 0) return null;
        const index: usize = @intCast(value);
        return if (index <= self.instructions.len) index else null;
    }

    fn setNull(self: *Vm, index: usize) void {
        vdbe_mem.setNull(&self.registers[index]);
    }

    fn setInteger(self: *Vm, index: usize, value: i64) void {
        vdbe_mem.out2Prerelease(&self.registers[index]).u.i = value;
    }

    fn setReal(self: *Vm, index: usize, value: f64) void {
        vdbe_mem.setDouble(&self.registers[index], value);
    }

    fn setBytes(self: *Vm, index: usize, bytes: []const u8, encoding: u8) ResultCode {
        const rc = vdbe_mem.setStr(&self.registers[index], bytes.ptr, @intCast(bytes.len), encoding, .transient);
        return ResultCode.fromC(rc);
    }

    fn copyValue(self: *Vm, from: usize, to: usize) ResultCode {
        return if (vdbe_mem.copy(&self.registers[to], &self.registers[from]) == 0) .ok else .no_memory;
    }

    fn materialize(self: *Vm, literal: Literal, target: usize) ResultCode {
        return switch (literal) {
            .null_ => result: {
                self.setNull(target);
                break :result .ok;
            },
            .integer => |value| result: {
                self.setInteger(target, value);
                break :result .ok;
            },
            .real => |value| result: {
                self.setReal(target, value);
                break :result .ok;
            },
            .text => |bytes| self.setBytes(target, bytes, 1),
            .blob => |bytes| self.setBytes(target, bytes, 0),
        };
    }

    pub fn step(self: *Vm) StepOutcome {
        if (self.state == .halted) return .{ .result = .done, .state = .halted };
        if (self.state == .failed) return .{ .result = self.result_code, .state = .failed };
        if (self.state == .row or self.state == .ready) self.state = .running;
        while (self.pc < self.instructions.len) {
            if (self.interrupt_requested) return self.fail(.interrupt);
            if (self.executed >= self.instruction_limit) return self.fail(.interrupt);
            self.executed += 1;
            if (self.progress_interval != 0 and self.executed % self.progress_interval == 0) {
                if (self.progress_callback) |callback| {
                    if (!callback(self.progress_context, self.executed)) return self.fail(.interrupt);
                }
            }
            const instruction = self.instructions[self.pc];
            self.pc += 1;
            if (self.execute(instruction)) |outcome| return outcome;
        }
        if (self.frames.items.len != 0) {
            const frame = self.frames.pop().?;
            self.instructions = frame.instructions;
            self.pc = frame.pc;
            self.current_subprogram = frame.subprogram;
            return self.step();
        }
        self.closeCursors();
        self.state = .halted;
        self.result_code = .ok;
        return .{ .result = .done, .state = .halted };
    }

    fn jump(self: *Vm, target: i32) ResultCode {
        self.pc = self.checkPc(target) orelse return .corrupt;
        return .ok;
    }

    fn execute(self: *Vm, instruction: Instruction) ?StepOutcome {
        switch (instruction.opcode) {
            .init, .goto => {
                const rc = self.jump(instruction.p2);
                if (rc != .ok) return self.fail(rc);
            },
            .gosub => {
                const register_index = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                self.setInteger(register_index, @intCast(self.pc));
                const rc = self.jump(instruction.p2);
                if (rc != .ok) return self.fail(rc);
            },
            .return_ => {
                const register_index = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (self.registers[register_index].flags & mem_flag.integer == 0) return self.fail(.corrupt);
                const target = self.registers[register_index].u.i;
                if (target < 0 or target > std.math.maxInt(i32)) return self.fail(.corrupt);
                const rc = self.jump(@intCast(target));
                if (rc != .ok) return self.fail(rc);
            },
            .init_coroutine => {
                const register_index = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (instruction.p3 <= 0) return self.fail(.corrupt);
                self.setInteger(register_index, instruction.p3 - 1);
                if (instruction.p2 != 0) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .yield => {
                const register_index = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (self.registers[register_index].flags & mem_flag.integer == 0) return self.fail(.corrupt);
                const target = self.registers[register_index].u.i;
                self.setInteger(register_index, @intCast(self.pc - 1));
                if (target < 0 or target >= std.math.maxInt(i32)) return self.fail(.corrupt);
                const rc = self.jump(@intCast(target + 1));
                if (rc != .ok) return self.fail(rc);
            },
            .end_coroutine => {
                const register_index = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (self.registers[register_index].flags & mem_flag.integer == 0) return self.fail(.corrupt);
                const caller_index = self.registers[register_index].u.i;
                if (caller_index < 0 or caller_index >= self.instructions.len) return self.fail(.corrupt);
                const caller = self.instructions[@intCast(caller_index)];
                if (caller.opcode != .yield) return self.fail(.corrupt);
                self.setInteger(register_index, @as(i64, @intCast(self.pc)) - 2);
                const rc = self.jump(caller.p2);
                if (rc != .ok) return self.fail(rc);
            },
            .once => {
                const register_index = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (self.registers[register_index].flags & mem_flag.integer != 0 and self.registers[register_index].u.i != 0) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                } else self.setInteger(register_index, 1);
            },
            .integer => {
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                self.setInteger(target, instruction.p1);
            },
            .int64 => {
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const value = switch (instruction.p4) {
                    .integer => |v| v,
                    else => return self.fail(.corrupt),
                };
                self.setInteger(target, value);
            },
            .real => {
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const value = switch (instruction.p4) {
                    .real => |v| v,
                    else => return self.fail(.corrupt),
                };
                self.setReal(target, value);
            },
            .string, .string8, .blob => {
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const bytes = switch (instruction.p4) {
                    .bytes => |v| v,
                    else => return self.fail(.corrupt),
                };
                const literal: Literal = if (instruction.opcode == .blob) .{ .blob = bytes } else .{ .text = bytes };
                const rc = self.materialize(literal, target);
                if (rc != .ok) return self.fail(rc);
            },
            .begin_subrtn, .null_ => {
                const first = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const last = if (instruction.p3 <= instruction.p2)
                    first
                else
                    self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                for (first..last + 1) |index| {
                    self.setNull(index);
                    if (instruction.p1 != 0) self.registers[index].flags |= mem_flag.cleared;
                }
            },
            .soft_null => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                self.registers[target].flags = (self.registers[target].flags & ~mem_flag.affinity_mask) | mem_flag.null_;
            },
            .variable => {
                if (instruction.p1 <= 0) return self.fail(.corrupt);
                const variable_index: usize = @intCast(instruction.p1 - 1);
                if (variable_index >= self.program.variables.len) return self.fail(.corrupt);
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const rc = self.materialize(self.program.variables[variable_index], target);
                if (rc != .ok) return self.fail(rc);
            },
            .move, .copy, .scopy, .int_copy => {
                const from = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const to = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const count: usize = if (instruction.p3 <= 0) 1 else @intCast(instruction.p3);
                if (from + count > self.registers.len or to + count > self.registers.len) return self.fail(.corrupt);
                for (0..count) |offset| {
                    const rc = self.copyValue(from + offset, to + offset);
                    if (rc != .ok) return self.fail(rc);
                    if (instruction.opcode == .move) self.setNull(from + offset);
                }
            },
            .add, .subtract, .multiply, .divide, .remainder, .bit_and, .bit_or, .shift_left, .shift_right => {
                const right = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const left = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                arithmetic(instruction.opcode, &self.registers[left], &self.registers[right], &self.registers[output]);
            },
            .add_imm => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const value = integerValue(&self.registers[target]);
                self.setInteger(target, value +% instruction.p2);
            },
            .concat => {
                const right = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const left = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                if (isNull(&self.registers[left]) or isNull(&self.registers[right])) {
                    self.setNull(output);
                } else {
                    const left_bytes = textBytes(&self.registers[left]) orelse return self.fail(.no_memory);
                    const right_bytes = textBytes(&self.registers[right]) orelse return self.fail(.no_memory);
                    const bytes = self.allocator.alloc(u8, left_bytes.len + right_bytes.len) catch return self.fail(.no_memory);
                    defer self.allocator.free(bytes);
                    @memcpy(bytes[0..left_bytes.len], left_bytes);
                    @memcpy(bytes[left_bytes.len..], right_bytes);
                    const rc = self.setBytes(output, bytes, 1);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .not, .bit_not => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (isNull(&self.registers[source])) {
                    self.setNull(output);
                } else if (instruction.opcode == .not) {
                    self.setInteger(output, if (truth(&self.registers[source]).?) 0 else 1);
                } else self.setInteger(output, ~integerValue(&self.registers[source]));
            },
            .is_true => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (instruction.p3 != 0 and instruction.p3 != 1) return self.fail(.corrupt);
                const invert = switch (instruction.p4) {
                    .integer => |value| value,
                    else => return self.fail(.corrupt),
                };
                if (invert != 0 and invert != 1) return self.fail(.corrupt);
                const value: i64 = if (truth(&self.registers[source])) |boolean| @intFromBool(boolean) else instruction.p3;
                self.setInteger(output, value ^ invert);
            },
            .zero_or_null => {
                const first = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const third = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                if (isNull(&self.registers[first]) or isNull(&self.registers[third])) self.setNull(output) else self.setInteger(output, 0);
            },
            .and_, .or_ => {
                const right = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const left = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                setBoolean(&self.registers[output], instruction.opcode, truth(&self.registers[left]), truth(&self.registers[right]));
            },
            .must_be_int => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const converted = exactInteger(&self.registers[target]) orelse {
                    if (instruction.p2 != 0) {
                        const rc = self.jump(instruction.p2);
                        if (rc != .ok) return self.fail(rc);
                        return null;
                    }
                    return self.fail(.mismatch);
                };
                self.setInteger(target, converted);
            },
            .real_affinity => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (self.registers[target].flags & mem_flag.integer != 0) self.setReal(target, @floatFromInt(self.registers[target].u.i));
            },
            .cast => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (instruction.p2 < 0 or instruction.p2 > std.math.maxInt(u8)) return self.fail(.corrupt);
                const rc = vdbe_mem.cast(&self.registers[target], @intCast(instruction.p2), 1);
                if (rc != 0) return self.fail(ResultCode.fromC(rc));
            },
            .affinity => {
                const first = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (instruction.p2 <= 0) return self.fail(.corrupt);
                const count: usize = @intCast(instruction.p2);
                if (first + count > self.registers.len) return self.fail(.corrupt);
                const affinities = switch (instruction.p4) {
                    .bytes => |value| value,
                    else => return self.fail(.corrupt),
                };
                if (affinities.len != count) return self.fail(.corrupt);
                for (self.registers[first..][0..count], affinities) |*value, affinity_value| {
                    vdbe_mem.applyAffinity(value, affinity_value, 1);
                    if (affinity_value == 0x45 and value.flags & mem_flag.integer != 0 and
                        value.u.i <= 140_737_488_355_327 and value.u.i >= -140_737_488_355_328)
                    {
                        value.flags |= mem_flag.integer_real;
                        value.flags &= ~mem_flag.integer;
                    }
                }
            },
            .make_record => {
                const first = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (instruction.p2 <= 0) return self.fail(.corrupt);
                const count: usize = @intCast(instruction.p2);
                if (first + count > self.registers.len) return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                if (output >= first and output < first + count) return self.fail(.corrupt);
                switch (instruction.p4) {
                    .none => {},
                    .bytes => |affinities| {
                        if (affinities.len != count) return self.fail(.corrupt);
                        for (self.registers[first..][0..count], affinities) |*value, affinity_value| {
                            vdbe_mem.applyAffinity(value, affinity_value, 1);
                            if (affinity_value == 0x45 and value.flags & mem_flag.integer != 0) {
                                value.flags |= mem_flag.integer_real;
                                value.flags &= ~mem_flag.integer;
                            }
                        }
                    },
                    else => return self.fail(.corrupt),
                }
                for (self.registers[first..][0..count]) |*value| {
                    if (value.flags & mem_flag.zero != 0 and vdbe_mem.expandBlob(value) != 0) return self.fail(.no_memory);
                }
                const record = encodeRecord(self.allocator, self.registers[first..][0..count]) catch |err| return self.fail(switch (err) {
                    error.OutOfMemory => .no_memory,
                    error.TooBig => .too_big,
                    error.InvalidValue => .corrupt,
                });
                defer self.allocator.free(record);
                const rc = self.setBytes(output, record, 0);
                if (rc != .ok) return self.fail(rc);
            },
            .to_text, .to_blob => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const affinity: u8 = if (instruction.opcode == .to_text) 0x42 else 0x41;
                const rc = vdbe_mem.cast(&self.registers[target], affinity, 1);
                if (rc != 0) return self.fail(ResultCode.fromC(rc));
            },
            .is_type => {
                const type_value: u8 = if (instruction.p1 < 0) blk: {
                    const source = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                    var value = self.registers[source];
                    break :blk @intCast(vdbe_mem.valueType(&value));
                } else blk: {
                    const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                    if (instruction.p3 < 0) return self.fail(.corrupt);
                    break :blk self.cursorStorageType(cursor_index, @intCast(instruction.p3), instruction.p4) orelse return self.fail(.corrupt);
                };
                if (type_value < 1 or type_value > 5) return self.fail(.corrupt);
                if (instruction.p5 & (@as(u16, 1) << @intCast(type_value - 1)) != 0) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .is_null, .not_null => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const null_value = isNull(&self.registers[source]);
                if (null_value == (instruction.opcode == .is_null)) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_null_row => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                if (self.cursor_null_rows[cursor_index]) {
                    const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                    self.setNull(output);
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_not_open => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                if (!cursorIsOpen(&self.cursors[cursor_index]) or self.cursor_null_rows[cursor_index]) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_, .if_not => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const value = truth(&self.registers[source]) orelse (instruction.p3 != 0);
                if (value == (instruction.opcode == .if_)) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_pos => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const value = integerValue(&self.registers[source]);
                if (value > 0) {
                    self.setInteger(source, value -% instruction.p3);
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_not_zero => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const value = integerValue(&self.registers[source]);
                if (value != 0) {
                    if (value > 0) self.setInteger(source, value - 1);
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .decr_jump_zero => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const initial = integerValue(&self.registers[source]);
                const value = if (initial > std.math.minInt(i64)) initial - 1 else initial;
                self.setInteger(source, value);
                if (value == 0) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .mem_max => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const source = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const left = integerValue(&self.registers[target]);
                const right = integerValue(&self.registers[source]);
                self.setInteger(target, @max(left, right));
            },
            .offset_limit => {
                const limit = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const offset = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                const limit_value = integerValue(&self.registers[limit]);
                const offset_value = @max(@as(i64, 0), integerValue(&self.registers[offset]));
                if (limit_value <= 0) {
                    self.setInteger(output, -1);
                } else {
                    const sum = @addWithOverflow(limit_value, offset_value);
                    self.setInteger(output, if (sum[1] != 0) -1 else sum[0]);
                }
            },
            .row_set_add => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const source = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (self.registers[source].flags & mem_flag.integer == 0) return self.fail(.corrupt);
                var set = vdbe_mem.rowSet(&self.registers[target]);
                if (set == null) {
                    if (self.registers[target].flags & mem_flag.blob != 0) return self.fail(.corrupt);
                    set = vdbe_mem.setRowSet(&self.registers[target], self.allocator) catch return self.fail(.no_memory);
                }
                set.?.insert(self.registers[source].u.i) catch return self.fail(.no_memory);
            },
            .row_set_read => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                const set = vdbe_mem.rowSet(&self.registers[source]);
                if (set == null and self.registers[source].flags & mem_flag.blob != 0)
                    return self.fail(.corrupt);
                const value = if (set) |present| present.next() else null;
                if (value == null) {
                    self.setNull(source);
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                } else {
                    self.setInteger(output, value.?);
                }
            },
            .row_set_test => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const source = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                if (self.registers[source].flags & mem_flag.integer == 0) return self.fail(.corrupt);
                const batch_i64 = switch (instruction.p4) {
                    .integer => |value| value,
                    else => return self.fail(.corrupt),
                };
                if (batch_i64 < -1 or batch_i64 > std.math.maxInt(i32)) return self.fail(.corrupt);
                var set = vdbe_mem.rowSet(&self.registers[target]);
                if (set == null) {
                    if (self.registers[target].flags & mem_flag.blob != 0) return self.fail(.corrupt);
                    set = vdbe_mem.setRowSet(&self.registers[target], self.allocator) catch return self.fail(.no_memory);
                }
                const batch: i32 = @intCast(batch_i64);
                if (batch != 0 and try_result: {
                    const exists = set.?.testValue(batch, self.registers[source].u.i) catch return self.fail(.no_memory);
                    break :try_result exists;
                }) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                } else if (batch >= 0) {
                    set.?.insert(self.registers[source].u.i) catch return self.fail(.no_memory);
                }
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const right = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const left = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                const compared = compare(&self.registers[left], &self.registers[right]);
                var take = false;
                if (compared) |order| {
                    self.last_compare = order;
                    take = switch (instruction.opcode) {
                        .eq => order == .eq,
                        .ne => order != .eq,
                        .lt => order == .lt,
                        .le => order != .gt,
                        .gt => order == .gt,
                        .ge => order != .lt,
                        else => unreachable,
                    };
                } else {
                    self.last_compare = .lt;
                    take = instruction.p5 & 1 != 0;
                }
                if (take) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .else_eq => {
                if (self.last_compare == .eq) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .permutation => {
                const indexes = switch (instruction.p4) {
                    .bytes => |value| value,
                    else => return self.fail(.corrupt),
                };
                if (indexes.len == 0) return self.fail(.corrupt);
                self.pending_permutation = indexes;
            },
            .compare_values => {
                const left = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const right = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (instruction.p3 <= 0) return self.fail(.corrupt);
                const count: usize = @intCast(instruction.p3);
                const permutation = if (instruction.p5 & 1 != 0) self.pending_permutation orelse return self.fail(.corrupt) else null;
                defer self.pending_permutation = null;
                if (permutation) |indexes| if (indexes.len != count) return self.fail(.corrupt);
                if (permutation == null and (left + count > self.registers.len or right + count > self.registers.len)) return self.fail(.corrupt);
                self.last_compare = .eq;
                for (0..count) |ordinal| {
                    const offset: usize = if (permutation) |indexes| indexes[ordinal] else ordinal;
                    if (left + offset >= self.registers.len or right + offset >= self.registers.len) return self.fail(.corrupt);
                    const order = compareStorage(&self.registers[left + offset], &self.registers[right + offset]);
                    if (order != .eq) {
                        self.last_compare = order;
                        break;
                    }
                }
            },
            .jump => {
                const target = switch (self.last_compare) {
                    .lt => instruction.p1,
                    .eq => instruction.p2,
                    .gt => instruction.p3,
                };
                const rc = self.jump(target);
                if (rc != .ok) return self.fail(rc);
            },
            .open_data => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const table_index: usize = @intCast(instruction.p2);
                if (table_index >= self.program.tables.len) return self.fail(.corrupt);
                self.cursors[cursor_index].deinit();
                self.cursors[cursor_index] = .{ .memory = .{ .table = table_index } };
                self.cursor_null_rows[cursor_index] = false;
                self.cursor_sequences[cursor_index] = 0;
            },
            .open_read => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const database = self.database orelse return self.fail(.misuse);
                const root: u32 = if (instruction.p2 <= 0) return self.fail(.corrupt) else @intCast(instruction.p2);
                const kind: btree.TreeKind = if (instruction.p3 == 0) .table else .index;
                const outcome = database.openCursor(root, kind);
                if (outcome.result != .ok) return self.fail(outcome.result);
                self.cursors[cursor_index].deinit();
                self.cursors[cursor_index] = .{ .btree = outcome.cursor.? };
                self.cursor_null_rows[cursor_index] = false;
                self.cursor_sequences[cursor_index] = 0;
            },
            .open_virtual => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const source_index: usize = if (instruction.p2 < 0) return self.fail(.corrupt) else @intCast(instruction.p2);
                if (source_index >= self.program.virtual_sources.len) return self.fail(.corrupt);
                const source = &self.program.virtual_sources[source_index];
                var handle: ?*anyopaque = null;
                const rc = source.open(source.context, &handle);
                if (rc != .ok) return self.fail(rc);
                self.cursors[cursor_index].deinit();
                self.cursors[cursor_index] = .{ .virtual = .{ .source = source, .handle = handle } };
                self.cursor_null_rows[cursor_index] = false;
                self.cursor_sequences[cursor_index] = 0;
            },
            .rewind, .last, .seek_end => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                if (instruction.opcode == .seek_end and instruction.p2 != 0) return self.fail(.corrupt);
                const positioned = cursorPosition(&self.cursors[cursor_index], self.program, instruction.opcode != .rewind);
                self.cursor_null_rows[cursor_index] = !positioned;
                if (cursorResult(&self.cursors[cursor_index]) != .ok) return self.fail(cursorResult(&self.cursors[cursor_index]));
                if (!positioned) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_size_between => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const upper = switch (instruction.p4) {
                    .integer => |value| value,
                    else => return self.fail(.corrupt),
                };
                const count_value = cursorCount(&self.cursors[cursor_index], self.program) orelse return self.fail(.corrupt);
                const estimate: i64 = if (count_value == 0) -1 else log_est.fromInt(@intCast(count_value));
                if (estimate >= instruction.p3 and estimate <= upper) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .if_empty => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const count_value = cursorCount(&self.cursors[cursor_index], self.program) orelse return self.fail(.corrupt);
                if (count_value == 0) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .next, .prev => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const positioned = cursorAdvance(&self.cursors[cursor_index], self.program, instruction.opcode == .prev);
                self.cursor_null_rows[cursor_index] = !positioned;
                if (cursorResult(&self.cursors[cursor_index]) != .ok) return self.fail(cursorResult(&self.cursors[cursor_index]));
                if (positioned) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .sequence, .sequence_test => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                if (!cursorIsOpen(&self.cursors[cursor_index])) return self.fail(.corrupt);
                const value = self.cursor_sequences[cursor_index];
                self.cursor_sequences[cursor_index] +%= 1;
                if (instruction.opcode == .sequence) {
                    const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                    self.setInteger(output, value);
                } else if (value == 0) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .null_row => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                self.cursor_null_rows[cursor_index] = true;
            },
            .seek_rowid => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const source = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                const rowid = integerValue(&self.registers[source]);
                const positioned = cursorSeek(&self.cursors[cursor_index], self.program, rowid);
                self.cursor_null_rows[cursor_index] = !positioned;
                if (!positioned) {
                    const rc = self.jump(instruction.p2);
                    if (rc != .ok) return self.fail(rc);
                }
            },
            .rowid => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const rowid_value = cursorRowid(&self.cursors[cursor_index], self.program) orelse return self.fail(.corrupt);
                self.setInteger(target, rowid_value);
            },
            .row_data => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (self.cursor_null_rows[cursor_index]) return self.fail(.corrupt);
                const payload = switch (self.cursors[cursor_index]) {
                    .btree => |*cursor| (cursor.current() orelse return self.fail(.corrupt)).payload,
                    else => return self.fail(.corrupt),
                };
                const rc = self.setBytes(target, payload, 0);
                if (rc != .ok) return self.fail(rc);
            },
            .idx_rowid => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (self.cursor_null_rows[cursor_index]) {
                    self.setNull(target);
                } else switch (self.cursors[cursor_index]) {
                    .btree => |*cursor| {
                        if (cursor.kind != .index) return self.fail(.corrupt);
                        const outcome = cursor.record();
                        if (outcome.result != .ok) return self.fail(outcome.result);
                        var record = outcome.record.?;
                        defer record.deinit();
                        if (record.values.len == 0) return self.fail(.corrupt);
                        const rowid_value = switch (record.values[record.values.len - 1]) {
                            .integer => |value| value,
                            else => return self.fail(.corrupt),
                        };
                        self.setInteger(target, rowid_value);
                    },
                    else => return self.fail(.corrupt),
                }
            },
            .column => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const target = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                const rc = self.cursorColumn(cursor_index, instruction.p2, target);
                if (rc != .ok) return self.fail(rc);
            },
            .count => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                const target = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const count_value = cursorCount(&self.cursors[cursor_index], self.program) orelse return self.fail(.corrupt);
                if (count_value > std.math.maxInt(i64)) return self.fail(.too_big);
                self.setInteger(target, @intCast(count_value));
            },
            .close => {
                const cursor_index = cursorIndex(self, instruction.p1) orelse return self.fail(.corrupt);
                self.cursors[cursor_index].deinit();
                self.cursor_null_rows[cursor_index] = false;
                self.cursor_sequences[cursor_index] = 0;
            },
            .function, .pure_func => {
                const function_index = switch (instruction.p4) {
                    .index => |value| value,
                    else => return self.fail(.corrupt),
                };
                if (function_index >= self.program.functions.len or instruction.p1 < 0) return self.fail(.corrupt);
                const count: usize = @intCast(instruction.p1);
                const first = if (count == 0) @as(usize, 1) else self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (first + count > self.registers.len) return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                var result = std.mem.zeroes(Mem);
                vdbe_mem.init(&result, null, mem_flag.null_);
                const rc = self.program.functions[function_index].callback(
                    self.program.functions[function_index].context,
                    self.registers[first..][0..count],
                    &result,
                    self.allocator,
                );
                if (rc != .ok) {
                    vdbe_mem.release(&result);
                    return self.fail(rc);
                }
                vdbe_mem.move(&self.registers[output], &result);
            },
            .program => {
                const subprogram = switch (instruction.p4) {
                    .index => |value| value,
                    else => return self.fail(.corrupt),
                };
                if (subprogram >= self.program.subprograms.len) return self.fail(.corrupt);
                if (self.current_subprogram == subprogram and instruction.p5 & 1 != 0) return null;
                self.frames.append(self.allocator, .{ .instructions = self.instructions, .pc = self.pc, .subprogram = self.current_subprogram }) catch return self.fail(.no_memory);
                self.instructions = self.program.subprograms[subprogram].instructions;
                self.pc = 0;
                self.current_subprogram = subprogram;
            },
            .param => {
                const from = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const to = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                const rc = self.copyValue(from, to);
                if (rc != .ok) return self.fail(rc);
            },
            .clr_subtype => {
                const target = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                self.registers[target].flags &= ~mem_flag.subtype;
            },
            .get_subtype => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (self.registers[source].flags & mem_flag.subtype != 0) self.setInteger(output, self.registers[source].eSubtype) else self.setNull(output);
            },
            .set_subtype => {
                const source = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                const output = self.checkRegister(instruction.p2) orelse return self.fail(.corrupt);
                if (isNull(&self.registers[source])) {
                    self.registers[output].flags &= ~mem_flag.subtype;
                } else {
                    self.registers[output].flags |= mem_flag.subtype;
                    self.registers[output].eSubtype = @intCast(integerValue(&self.registers[source]) & 0xff);
                }
            },
            .result_row => {
                const first = self.checkRegister(instruction.p1) orelse return self.fail(.corrupt);
                if (instruction.p2 <= 0) return self.fail(.corrupt);
                const count: usize = @intCast(instruction.p2);
                if (first + count > self.registers.len) return self.fail(.corrupt);
                self.result_first = first;
                self.result_count = count;
                self.state = .row;
                self.result_code = .row;
                return .{ .result = .row, .state = .row };
            },
            .halt_if_null => {
                const source = self.checkRegister(instruction.p3) orelse return self.fail(.corrupt);
                if (isNull(&self.registers[source])) return self.haltInstruction(instruction);
            },
            .halt => return self.haltInstruction(instruction),
            .noop => {},
        }
        return null;
    }

    fn haltInstruction(self: *Vm, instruction: Instruction) ?StepOutcome {
        const result = ResultCode.fromC(instruction.p1);
        if (self.frames.items.len != 0 and result == .ok) {
            const frame = self.frames.pop().?;
            self.instructions = frame.instructions;
            self.pc = frame.pc;
            self.current_subprogram = frame.subprogram;
            return null;
        }
        self.result_code = result;
        if (result == .ok) {
            self.closeCursors();
            self.state = .halted;
            return .{ .result = .done, .state = .halted };
        }
        return self.fail(result);
    }

    fn cursorStorageType(self: *Vm, cursor_index: usize, column_index: usize, fallback: P4) ?u8 {
        if (self.cursor_null_rows[cursor_index]) return 5;
        return switch (self.cursors[cursor_index]) {
            .closed, .virtual => null,
            .memory => |memory| blk: {
                const position = memory.position orelse break :blk null;
                const values = self.program.tables[memory.table].rows[position].values;
                if (column_index >= values.len) break :blk fallbackType(fallback);
                break :blk literalStorageType(values[column_index]);
            },
            .btree => |*cursor| blk: {
                const outcome = cursor.record();
                if (outcome.result != .ok) break :blk null;
                var record = outcome.record.?;
                defer record.deinit();
                if (column_index >= record.values.len) break :blk fallbackType(fallback);
                break :blk switch (record.values[column_index]) {
                    .null_ => 5,
                    .integer => 1,
                    .real => 2,
                    .text => 3,
                    .blob => 4,
                };
            },
        };
    }

    fn cursorColumn(self: *Vm, cursor_index: usize, column_index_value: i32, target: usize) ResultCode {
        if (column_index_value < 0) return .corrupt;
        if (self.cursor_null_rows[cursor_index]) {
            self.setNull(target);
            return .ok;
        }
        const column_index: usize = @intCast(column_index_value);
        switch (self.cursors[cursor_index]) {
            .closed => return .corrupt,
            .memory => |memory| {
                const position = memory.position orelse return .corrupt;
                const rows = self.program.tables[memory.table].rows;
                if (position >= rows.len or column_index >= rows[position].values.len) {
                    self.setNull(target);
                    return .ok;
                }
                return self.materialize(rows[position].values[column_index], target);
            },
            .virtual => |cursor| {
                var value = std.mem.zeroes(Mem);
                vdbe_mem.init(&value, null, mem_flag.null_);
                const rc = cursor.source.column(cursor.handle, column_index, &value);
                if (rc != .ok) {
                    vdbe_mem.release(&value);
                    return rc;
                }
                vdbe_mem.move(&self.registers[target], &value);
                return .ok;
            },
            .btree => |*cursor| {
                const outcome = cursor.record();
                if (outcome.result != .ok) return outcome.result;
                var record = outcome.record.?;
                defer record.deinit();
                if (column_index >= record.values.len) {
                    self.setNull(target);
                    return .ok;
                }
                const source = record.values[column_index];
                return switch (source) {
                    .null_ => result: {
                        self.setNull(target);
                        break :result .ok;
                    },
                    .integer => |value| result: {
                        self.setInteger(target, value);
                        break :result .ok;
                    },
                    .real => |value| result: {
                        self.setReal(target, value);
                        break :result .ok;
                    },
                    .text => |bytes| self.setBytes(target, bytes, 1),
                    .blob => |bytes| self.setBytes(target, bytes, 0),
                };
            },
        }
    }
};

fn cursorIsOpen(cursor: *const Cursor) bool {
    return switch (cursor.*) {
        .closed => false,
        else => true,
    };
}

fn cursorIndex(vm: *const Vm, value: i32) ?usize {
    if (value < 0) return null;
    const index: usize = @intCast(value);
    return if (index < vm.cursors.len) index else null;
}

fn cursorPosition(cursor: *Cursor, program: *const Program, last_position: bool) bool {
    return switch (cursor.*) {
        .closed => false,
        .memory => |*memory| blk: {
            const rows = program.tables[memory.table].rows;
            if (rows.len == 0) {
                memory.position = null;
                break :blk false;
            }
            memory.position = if (last_position) rows.len - 1 else 0;
            break :blk true;
        },
        .btree => |*native| if (last_position) native.last() else native.first(),
        .virtual => |*item| blk: {
            if (last_position) break :blk false;
            item.result = item.source.filter(item.handle);
            break :blk item.result == .ok and !item.source.eof(item.handle);
        },
    };
}

fn cursorAdvance(cursor: *Cursor, program: *const Program, previous: bool) bool {
    return switch (cursor.*) {
        .closed => false,
        .memory => |*memory| blk: {
            const position = memory.position orelse break :blk false;
            const rows = program.tables[memory.table].rows;
            if (previous) {
                if (position == 0) {
                    memory.position = null;
                    break :blk false;
                }
                memory.position = position - 1;
                break :blk true;
            }
            if (position + 1 >= rows.len) {
                memory.position = null;
                break :blk false;
            }
            memory.position = position + 1;
            break :blk true;
        },
        .btree => |*native| if (previous) native.previous() else native.next(),
        .virtual => |*item| blk: {
            if (previous) break :blk false;
            item.result = item.source.next(item.handle);
            break :blk item.result == .ok and !item.source.eof(item.handle);
        },
    };
}

fn cursorResult(cursor: *const Cursor) ResultCode {
    return switch (cursor.*) {
        .virtual => |item| item.result,
        else => .ok,
    };
}

fn cursorSeek(cursor: *Cursor, program: *const Program, rowid: i64) bool {
    return switch (cursor.*) {
        .closed => false,
        .memory => |*memory| blk: {
            const rows = program.tables[memory.table].rows;
            var lower: usize = 0;
            var upper = rows.len;
            while (lower < upper) {
                const middle = lower + (upper - lower) / 2;
                if (rows[middle].rowid < rowid) lower = middle + 1 else upper = middle;
            }
            if (lower >= rows.len or rows[lower].rowid != rowid) {
                memory.position = null;
                break :blk false;
            }
            memory.position = lower;
            break :blk true;
        },
        .btree => |*native| native.seekTable(rowid),
        .virtual => false,
    };
}

fn cursorRowid(cursor: *const Cursor, program: *const Program) ?i64 {
    return switch (cursor.*) {
        .closed => null,
        .memory => |memory| program.tables[memory.table].rows[memory.position orelse return null].rowid,
        .btree => |native| (native.current() orelse return null).rowid,
        .virtual => |item| value: {
            var rowid: i64 = 0;
            if (item.source.rowid(item.handle, &rowid) != .ok) return null;
            break :value rowid;
        },
    };
}

fn cursorCount(cursor: *const Cursor, program: *const Program) ?usize {
    return switch (cursor.*) {
        .closed => null,
        .memory => |memory| program.tables[memory.table].rows.len,
        .btree => |native| native.count(),
        .virtual => null,
    };
}

const RecordDescriptor = struct { serial: u64, length: usize };
const RecordError = error{ OutOfMemory, TooBig, InvalidValue };

fn recordDescriptor(value: *Mem) ?RecordDescriptor {
    if (value.flags & mem_flag.null_ != 0) return .{ .serial = 0, .length = 0 };
    if (value.flags & (mem_flag.integer | mem_flag.integer_real) != 0) {
        const integer = value.u.i;
        const magnitude: u64 = @intCast(if (integer < 0) ~integer else integer);
        if (magnitude <= 127) {
            if ((integer == 0 or integer == 1)) return .{ .serial = @intCast(8 + integer), .length = 0 };
            return .{ .serial = 1, .length = 1 };
        }
        if (magnitude <= 32_767) return .{ .serial = 2, .length = 2 };
        if (magnitude <= 8_388_607) return .{ .serial = 3, .length = 3 };
        if (magnitude <= 2_147_483_647) return .{ .serial = 4, .length = 4 };
        if (magnitude <= 140_737_488_355_327) return .{ .serial = 5, .length = 6 };
        if (value.flags & mem_flag.integer_real != 0) {
            value.u.r = @floatFromInt(integer);
            value.flags &= ~mem_flag.integer_real;
            value.flags |= mem_flag.real;
            return .{ .serial = 7, .length = 8 };
        }
        return .{ .serial = 6, .length = 8 };
    }
    if (value.flags & mem_flag.real != 0) return .{ .serial = 7, .length = 8 };
    if (value.flags & (mem_flag.string | mem_flag.blob) != 0) {
        if (value.n < 0 or value.z == null) return null;
        const length: usize = @intCast(value.n);
        return .{ .serial = 12 + 2 * @as(u64, @intCast(length)) + @intFromBool(value.flags & mem_flag.string != 0), .length = length };
    }
    return null;
}

fn varintLength(value: u64) usize {
    var scratch: [9]u8 = undefined;
    return varint.put(&scratch, value);
}

fn encodeRecord(allocator: std.mem.Allocator, values: []Mem) RecordError![]u8 {
    var header_body: usize = 0;
    var payload_length: usize = 0;
    for (values) |*value| {
        const descriptor = recordDescriptor(value) orelse return error.InvalidValue;
        header_body = std.math.add(usize, header_body, varintLength(descriptor.serial)) catch return error.TooBig;
        payload_length = std.math.add(usize, payload_length, descriptor.length) catch return error.TooBig;
    }
    var header_length = header_body + varintLength(header_body + 1);
    while (header_body + varintLength(header_length) != header_length) header_length = header_body + varintLength(header_length);
    const total = std.math.add(usize, header_length, payload_length) catch return error.TooBig;
    if (total > btree.maximum_payload) return error.TooBig;
    const output = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(output);
    var header_offset: usize = varint.put(output.ptr, header_length);
    var payload_offset = header_length;
    for (values) |*value| {
        const descriptor = recordDescriptor(value) orelse return error.InvalidValue;
        header_offset += varint.put(output.ptr + header_offset, descriptor.serial);
        switch (descriptor.serial) {
            0, 8, 9 => {},
            1...6 => {
                const bits: u64 = @bitCast(value.u.i);
                for (0..descriptor.length) |index| output[payload_offset + index] = @truncate(bits >> @intCast(8 * (descriptor.length - index - 1)));
                payload_offset += descriptor.length;
            },
            7 => {
                const bits: u64 = @bitCast(value.u.r);
                for (0..8) |index| output[payload_offset + index] = @truncate(bits >> @intCast(8 * (7 - index)));
                payload_offset += 8;
            },
            else => {
                @memcpy(output[payload_offset..][0..descriptor.length], value.z.?[0..descriptor.length]);
                payload_offset += descriptor.length;
            },
        }
    }
    std.debug.assert(header_offset == header_length and payload_offset == total);
    return output;
}

fn fallbackType(value: P4) ?u8 {
    return switch (value) {
        .integer => |type_value| if (type_value >= 1 and type_value <= 5) @intCast(type_value) else null,
        else => null,
    };
}

fn literalStorageType(value: Literal) u8 {
    return switch (value) {
        .integer => 1,
        .real => 2,
        .text => 3,
        .blob => 4,
        .null_ => 5,
    };
}

fn isNull(value: *const Mem) bool {
    return value.flags & mem_flag.null_ != 0;
}

fn integerValue(value: *const Mem) i64 {
    return vdbe_mem.intValue(value);
}

fn exactInteger(value: *const Mem) ?i64 {
    if (value.flags & (mem_flag.integer | mem_flag.integer_real) != 0) return value.u.i;
    if (value.flags & mem_flag.real != 0) {
        const real = value.u.r;
        if (!std.math.isFinite(real) or @trunc(real) != real) return null;
        const integer = vdbe_mem.realToI64(real);
        return if (vdbe_mem.realSameAsInt(real, integer)) integer else null;
    }
    var copy = value.*;
    if (vdbe_mem.numerify(&copy) != 0 or copy.flags & mem_flag.integer == 0) return null;
    return copy.u.i;
}

const Numeric = union(enum) { integer: i64, real: f64, invalid };

fn numeric(value: *const Mem) Numeric {
    if (isNull(value)) return .invalid;
    var copy = value.*;
    if (vdbe_mem.numerify(&copy) != 0) return .invalid;
    if (copy.flags & (mem_flag.integer | mem_flag.integer_real) != 0) return .{ .integer = copy.u.i };
    if (copy.flags & mem_flag.real != 0) return .{ .real = copy.u.r };
    return .invalid;
}

fn arithmetic(opcode: Opcode, left_value: *const Mem, right_value: *const Mem, output: *Mem) void {
    if (isNull(left_value) or isNull(right_value)) {
        vdbe_mem.setNull(output);
        return;
    }
    if (opcode == .bit_and or opcode == .bit_or or opcode == .shift_left or opcode == .shift_right or opcode == .remainder) {
        const a = integerValue(left_value);
        const b = integerValue(right_value);
        const result: ?i64 = switch (opcode) {
            .bit_and => a & b,
            .bit_or => a | b,
            .shift_left => if (b < 0) shift(a, negativeMagnitude(b), false) else shift(a, b, true),
            .shift_right => if (b < 0) shift(a, negativeMagnitude(b), true) else shift(a, b, false),
            .remainder => if (b == 0) null else if (a == std.math.minInt(i64) and b == -1) 0 else @rem(a, b),
            else => unreachable,
        };
        if (result) |integer| vdbe_mem.setInt64(output, integer) else vdbe_mem.setNull(output);
        return;
    }
    const left = numeric(left_value);
    const right = numeric(right_value);
    if (left == .invalid or right == .invalid) {
        vdbe_mem.setNull(output);
        return;
    }
    if (left == .integer and right == .integer) {
        const a = left.integer;
        const b = right.integer;
        switch (opcode) {
            .add => if (@addWithOverflow(a, b)[1] == 0) vdbe_mem.setInt64(output, a + b) else vdbe_mem.setDouble(output, @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b))),
            .subtract => if (@subWithOverflow(a, b)[1] == 0) vdbe_mem.setInt64(output, a - b) else vdbe_mem.setDouble(output, @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b))),
            .multiply => if (@mulWithOverflow(a, b)[1] == 0) vdbe_mem.setInt64(output, a * b) else vdbe_mem.setDouble(output, @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b))),
            .divide => if (b == 0) vdbe_mem.setNull(output) else if (a == std.math.minInt(i64) and b == -1) vdbe_mem.setDouble(output, -@as(f64, @floatFromInt(a))) else vdbe_mem.setInt64(output, @divTrunc(a, b)),
            else => unreachable,
        }
        return;
    }
    const a: f64 = switch (left) {
        .integer => |value| @floatFromInt(value),
        .real => |value| value,
        else => unreachable,
    };
    const b: f64 = switch (right) {
        .integer => |value| @floatFromInt(value),
        .real => |value| value,
        else => unreachable,
    };
    if (opcode == .divide and b == 0) {
        vdbe_mem.setNull(output);
    } else vdbe_mem.setDouble(output, switch (opcode) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .divide => a / b,
        else => unreachable,
    });
}

fn negativeMagnitude(value: i64) i64 {
    return if (value == std.math.minInt(i64)) std.math.maxInt(i64) else -value;
}

fn shift(value: i64, amount_value: i64, left: bool) i64 {
    const amount: u6 = @intCast(@min(@as(i64, 63), @max(@as(i64, 0), amount_value)));
    return if (left) value << amount else value >> amount;
}

fn truth(value: *Mem) ?bool {
    if (isNull(value)) return null;
    return vdbe_mem.booleanValue(value, 0) != 0;
}

fn setBoolean(output: *Mem, opcode: Opcode, left: ?bool, right: ?bool) void {
    if (opcode == .and_) {
        if (left == false or right == false) return vdbe_mem.setInt64(output, 0);
        if (left == null or right == null) return vdbe_mem.setNull(output);
        return vdbe_mem.setInt64(output, 1);
    }
    if (left == true or right == true) return vdbe_mem.setInt64(output, 1);
    if (left == null or right == null) return vdbe_mem.setNull(output);
    vdbe_mem.setInt64(output, 0);
}

fn compareStorage(left: *const Mem, right: *const Mem) std.math.Order {
    return std.math.order(vdbe_mem.compare(left, right, null), 0);
}

fn compare(left: *const Mem, right: *const Mem) ?std.math.Order {
    if (isNull(left) or isNull(right)) return null;
    return std.math.order(vdbe_mem.compare(left, right, null), 0);
}

fn textBytes(value: *Mem) ?[]const u8 {
    const bytes = vdbe_mem.valueText(value, 1) orelse return null;
    return bytes[0..@intCast(value.n)];
}

const test_rows = [_]TableRow{
    .{ .rowid = 1, .values = &.{ .{ .text = "one" }, .{ .integer = 10 } } },
    .{ .rowid = 3, .values = &.{ .{ .text = "three" }, .{ .integer = 30 } } },
    .{ .rowid = 5, .values = &.{ .{ .text = "five" }, .{ .integer = 50 } } },
};
const test_tables = [_]Table{.{ .rows = &test_rows }};

test "opcode loop resumes rows and memory cursors seek iterate and close" {
    const operations = [_]Instruction{
        .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },
        .{ .opcode = .count, .p1 = 0, .p2 = 4 },
        .{ .opcode = .integer, .p1 = 3, .p2 = 3 },
        .{ .opcode = .seek_rowid, .p1 = 0, .p2 = 9, .p3 = 3 },
        .{ .opcode = .rowid, .p1 = 0, .p2 = 1 },
        .{ .opcode = .column, .p1 = 0, .p2 = 0, .p3 = 2 },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 4 },
        .{ .opcode = .next, .p1 = 0, .p2 = 4 },
        .{ .opcode = .close, .p1 = 0 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 4, .cursor_count = 1, .tables = &test_tables };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 3), vm.column(0).?.u.i);
    try std.testing.expectEqualStrings("three", textBytes(@constCast(vm.column(1).?)).?);
    try std.testing.expectEqual(@as(i64, 3), vm.column(3).?.u.i);
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 5), vm.column(0).?.u.i);
    try std.testing.expectEqualStrings("five", textBytes(@constCast(vm.column(1).?)).?);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
    try std.testing.expectEqual(State.halted, vm.state);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "RowSet opcodes preserve sorted extraction and batch visibility" {
    const read_operations = [_]Instruction{
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
    const read_program = Program{ .instructions = &read_operations, .register_count = 3 };
    var read_vm = try Vm.init(std.testing.allocator, &read_program, null);
    defer read_vm.deinit();
    try std.testing.expectEqual(ResultCode.row, read_vm.step().result);
    try std.testing.expectEqual(@as(i64, 3), read_vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.row, read_vm.step().result);
    try std.testing.expectEqual(@as(i64, 9), read_vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.done, read_vm.step().result);
    try std.testing.expect(read_vm.register(1).?.flags & mem_flag.null_ != 0);

    const test_operations = [_]Instruction{
        .{ .opcode = .integer, .p1 = 10, .p2 = 3 },
        .{ .opcode = .row_set_test, .p1 = 1, .p2 = 20, .p3 = 3, .p4 = .{ .integer = 0 } },
        .{ .opcode = .integer, .p1 = 20, .p2 = 3 },
        .{ .opcode = .row_set_test, .p1 = 1, .p2 = 20, .p3 = 3, .p4 = .{ .integer = 0 } },
        .{ .opcode = .integer, .p1 = 10, .p2 = 3 },
        .{ .opcode = .row_set_test, .p1 = 1, .p2 = 8, .p3 = 3, .p4 = .{ .integer = 1 } },
        .{ .opcode = .integer, .p1 = 0, .p2 = 4 },
        .{ .opcode = .goto, .p2 = 9 },
        .{ .opcode = .integer, .p1 = 1, .p2 = 4 },
        .{ .opcode = .integer, .p1 = 30, .p2 = 3 },
        .{ .opcode = .row_set_test, .p1 = 1, .p2 = 13, .p3 = 3, .p4 = .{ .integer = 1 } },
        .{ .opcode = .integer, .p1 = 2, .p2 = 5 },
        .{ .opcode = .goto, .p2 = 14 },
        .{ .opcode = .integer, .p1 = -2, .p2 = 5 },
        .{ .opcode = .integer, .p1 = 30, .p2 = 3 },
        .{ .opcode = .row_set_test, .p1 = 1, .p2 = 18, .p3 = 3, .p4 = .{ .integer = 2 } },
        .{ .opcode = .integer, .p1 = 0, .p2 = 6 },
        .{ .opcode = .goto, .p2 = 19 },
        .{ .opcode = .integer, .p1 = 3, .p2 = 6 },
        .{ .opcode = .result_row, .p1 = 4, .p2 = 3 },
        .{ .opcode = .halt },
    };
    const test_program = Program{ .instructions = &test_operations, .register_count = 6 };
    var test_vm = try Vm.init(std.testing.allocator, &test_program, null);
    defer test_vm.deinit();
    try std.testing.expectEqual(ResultCode.row, test_vm.step().result);
    try std.testing.expectEqual(@as(i64, 1), test_vm.column(0).?.u.i);
    try std.testing.expectEqual(@as(i64, 2), test_vm.column(1).?.u.i);
    try std.testing.expectEqual(@as(i64, 3), test_vm.column(2).?.u.i);
    try std.testing.expectEqual(ResultCode.done, test_vm.step().result);
}

fn rowSetAllocationExercise(allocator: std.mem.Allocator) !void {
    const operations = [_]Instruction{
        .{ .opcode = .integer, .p1 = 5, .p2 = 2 },
        .{ .opcode = .row_set_add, .p1 = 1, .p2 = 2 },
        .{ .opcode = .integer, .p1 = 7, .p2 = 2 },
        .{ .opcode = .row_set_test, .p1 = 1, .p2 = 5, .p3 = 2, .p4 = .{ .integer = 1 } },
        .{ .opcode = .halt },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 2 };
    var vm = Vm.init(allocator, &program, null) catch return error.OutOfMemory;
    defer vm.deinit();
    const outcome = vm.step();
    if (outcome.result == .no_memory) return error.OutOfMemory;
    if (outcome.result != .done) return error.UnexpectedResult;
}

test "RowSet opcode allocation failures release Mem ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, rowSetAllocationExercise, .{});
}

const CallbackState = struct { calls: usize = 0, destroys: usize = 0 };
fn testCallback(context: ?*anyopaque, arguments: []Mem, output: *Mem, _: std.mem.Allocator) ResultCode {
    const state: *CallbackState = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    if (arguments.len != 2) return .misuse;
    vdbe_mem.setInt64(output, integerValue(&arguments[0]) + integerValue(&arguments[1]));
    return .ok;
}
fn testDestructor(context: ?*anyopaque) void {
    const state: *CallbackState = @ptrCast(@alignCast(context.?));
    state.destroys += 1;
}

test "subprogram frames functions result rows and destructors have bounded lifetime" {
    var callback_state = CallbackState{};
    const functions = [_]Function{.{ .callback = testCallback, .context = &callback_state, .destructor = testDestructor }};
    const child = [_]Instruction{
        .{ .opcode = .integer, .p1 = 40, .p2 = 1 },
        .{ .opcode = .integer, .p1 = 2, .p2 = 2 },
        .{ .opcode = .function, .p1 = 2, .p2 = 1, .p3 = 3, .p4 = .{ .index = 0 } },
        .{ .opcode = .halt },
    };
    const subprograms = [_]Subprogram{.{ .instructions = &child }};
    const operations = [_]Instruction{
        .{ .opcode = .program, .p4 = .{ .index = 0 } },
        .{ .opcode = .result_row, .p1 = 3, .p2 = 1 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 3, .functions = &functions, .subprograms = &subprograms };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 42), vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
    try std.testing.expectEqual(@as(usize, 1), callback_state.calls);
    try std.testing.expectEqual(@as(usize, 0), callback_state.destroys);
    vm.deinit();
    try std.testing.expectEqual(@as(usize, 1), callback_state.destroys);
}

fn stopProgress(_: ?*anyopaque, _: u64) bool {
    return false;
}

test "interrupt progress limits halt errors and malformed programs are sticky" {
    const loop = [_]Instruction{.{ .opcode = .goto, .p2 = 0 }};
    const loop_program = Program{ .instructions = &loop, .register_count = 1 };
    var limited = try Vm.init(std.testing.allocator, &loop_program, null);
    defer limited.deinit();
    limited.setInstructionLimit(7);
    try std.testing.expectEqual(ResultCode.interrupt, limited.step().result);
    try std.testing.expectEqual(@as(u64, 7), limited.executed);
    try std.testing.expectEqual(ResultCode.interrupt, limited.step().result);

    var directly_interrupted = try Vm.init(std.testing.allocator, &loop_program, null);
    defer directly_interrupted.deinit();
    directly_interrupted.requestInterrupt();
    try std.testing.expectEqual(ResultCode.interrupt, directly_interrupted.step().result);
    try std.testing.expectEqual(@as(u64, 0), directly_interrupted.executed);

    var progressed = try Vm.init(std.testing.allocator, &loop_program, null);
    defer progressed.deinit();
    progressed.setProgressHandler(3, stopProgress, null);
    try std.testing.expectEqual(ResultCode.interrupt, progressed.step().result);
    try std.testing.expectEqual(@as(u64, 3), progressed.executed);

    const error_ops = [_]Instruction{.{ .opcode = .halt, .p1 = 19 }};
    const error_program = Program{ .instructions = &error_ops, .register_count = 1 };
    var failed = try Vm.init(std.testing.allocator, &error_program, null);
    defer failed.deinit();
    try std.testing.expectEqual(ResultCode.constraint, failed.step().result);
    try std.testing.expectEqual(State.failed, failed.state);
    try std.testing.expectEqual(ResultCode.constraint, failed.step().result);

    const null_halt_ops = [_]Instruction{
        .{ .opcode = .null_, .p2 = 1 },
        .{ .opcode = .halt_if_null, .p1 = 19, .p3 = 1 },
        .{ .opcode = .halt },
    };
    const null_halt_program = Program{ .instructions = &null_halt_ops, .register_count = 1 };
    var null_halt = try Vm.init(std.testing.allocator, &null_halt_program, null);
    defer null_halt.deinit();
    try std.testing.expectEqual(ResultCode.constraint, null_halt.step().result);

    const malformed_ops = [_]Instruction{.{ .opcode = .goto, .p2 = 99 }};
    const malformed_program = Program{ .instructions = &malformed_ops, .register_count = 1 };
    var malformed = try Vm.init(std.testing.allocator, &malformed_program, null);
    defer malformed.deinit();
    try std.testing.expectEqual(ResultCode.corrupt, malformed.step().result);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const child_operations = [_]Instruction{
        .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },
        .{ .opcode = .rewind, .p1 = 0, .p2 = 6 },
        .{ .opcode = .column, .p1 = 0, .p2 = 0, .p3 = 1 },
        .{ .opcode = .copy, .p1 = 1, .p2 = 2 },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 2 },
        .{ .opcode = .next, .p1 = 0, .p2 = 2 },
        .{ .opcode = .halt },
    };
    const subprograms = [_]Subprogram{.{ .instructions = &child_operations }};
    const operations = [_]Instruction{ .{ .opcode = .program, .p4 = .{ .index = 0 } }, .{ .opcode = .halt } };
    const program = Program{ .instructions = &operations, .register_count = 2, .cursor_count = 1, .tables = &test_tables, .subprograms = &subprograms };
    var vm = Vm.init(allocator, &program, null) catch return error.OutOfMemory;
    defer vm.deinit();
    while (true) {
        const outcome = vm.step();
        if (outcome.result == .no_memory) return error.OutOfMemory;
        if (outcome.result == .done) break;
        if (outcome.result != .row) return error.UnexpectedResult;
    }
}

test "VDBE register cursor and result ownership survives bounded allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

fn readVdbeFixture() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/btree/core-512.db",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
}

fn installVdbeFile(memory: *btree.vfs.MemoryVfs, name: []const u8, data: []const u8) !void {
    const opened = memory.open(name, btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(btree.vfs.OK, opened.rc);
    const file = opened.file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(data, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
}

test "OpenRead Rowid and Column execute against native B-tree cursor" {
    const fixture = try readVdbeFixture();
    defer std.testing.allocator.free(fixture);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installVdbeFile(&memory, "vdbe-btree.db", fixture);
    var adapter = btree.vfs.AbiAdapter.init("vdbe-btree", &memory);
    const opened = btree.Database.open(std.testing.allocator, &adapter.abi, "vdbe-btree.db");
    try std.testing.expectEqual(ResultCode.ok, opened.result);
    var database = opened.database.?;
    defer _ = database.close();
    const expected_outcome = database.openCursor(2, .table);
    try std.testing.expectEqual(ResultCode.ok, expected_outcome.result);
    var expected_cursor = expected_outcome.cursor.?;
    defer expected_cursor.deinit();
    try std.testing.expect(expected_cursor.first());
    const expected_payload = expected_cursor.current().?.payload;
    const index_outcome = database.openCursor(3, .index);
    try std.testing.expectEqual(ResultCode.ok, index_outcome.result);
    var index_cursor = index_outcome.cursor.?;
    defer index_cursor.deinit();
    try std.testing.expect(index_cursor.first());
    const index_record_outcome = index_cursor.record();
    try std.testing.expectEqual(ResultCode.ok, index_record_outcome.result);
    var index_record = index_record_outcome.record.?;
    defer index_record.deinit();
    const expected_index_rowid = switch (index_record.values[index_record.values.len - 1]) {
        .integer => |value| value,
        else => return error.UnexpectedResult,
    };
    const operations = [_]Instruction{
        .{ .opcode = .open_read, .p1 = 0, .p2 = 2, .p3 = 0 },
        .{ .opcode = .open_read, .p1 = 1, .p2 = 3, .p3 = 1 },
        .{ .opcode = .rewind, .p1 = 0, .p2 = 10 },
        .{ .opcode = .rewind, .p1 = 1, .p2 = 10 },
        .{ .opcode = .rowid, .p1 = 0, .p2 = 1 },
        .{ .opcode = .column, .p1 = 0, .p2 = 1, .p3 = 2 },
        .{ .opcode = .row_data, .p1 = 0, .p2 = 3 },
        .{ .opcode = .idx_rowid, .p1 = 1, .p2 = 4 },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 4 },
        .{ .opcode = .halt },
        .{ .opcode = .halt, .p1 = 11 },
    };
    const program = Program{ .instructions = &operations, .register_count = 4, .cursor_count = 2 };
    var vm = try Vm.init(std.testing.allocator, &program, &database);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 1), vm.column(0).?.u.i);
    try std.testing.expectEqual(@as(i64, 17), vm.column(1).?.u.i);
    const row_bytes = vdbe_mem.valueBlob(@constCast(vm.column(2).?)).?;
    try std.testing.expectEqualSlices(u8, expected_payload, row_bytes[0..@intCast(vm.column(2).?.n)]);
    try std.testing.expectEqual(expected_index_rowid, vm.column(3).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "coroutine yield resume and end follow program-counter exchange" {
    const operations = [_]Instruction{
        .{ .opcode = .init_coroutine, .p1 = 1, .p2 = 6, .p3 = 3 },
        .{ .opcode = .noop },
        .{ .opcode = .yield, .p1 = 1, .p2 = 5 },
        .{ .opcode = .result_row, .p1 = 2, .p2 = 1 },
        .{ .opcode = .goto, .p2 = 2 },
        .{ .opcode = .halt },
        .{ .opcode = .integer, .p1 = 10, .p2 = 2 },
        .{ .opcode = .yield, .p1 = 1 },
        .{ .opcode = .integer, .p1 = 20, .p2 = 2 },
        .{ .opcode = .yield, .p1 = 1 },
        .{ .opcode = .end_coroutine, .p1 = 1 },
    };
    const program = Program{ .instructions = &operations, .register_count = 2 };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 10), vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 20), vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "String8 PureFunc and ElseEq aliases preserve execution semantics" {
    var callback_state = CallbackState{};
    const functions = [_]Function{.{ .callback = testCallback, .context = &callback_state }};
    const operations = [_]Instruction{
        .{ .opcode = .integer, .p1 = 7, .p2 = 2 },
        .{ .opcode = .integer, .p1 = 7, .p2 = 3 },
        .{ .opcode = .lt, .p1 = 3, .p2 = 5, .p3 = 2 },
        .{ .opcode = .else_eq, .p2 = 5 },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .string8, .p2 = 1, .p4 = .{ .bytes = "alias" } },
        .{ .opcode = .integer, .p1 = 40, .p2 = 2 },
        .{ .opcode = .integer, .p1 = 2, .p2 = 3 },
        .{ .opcode = .pure_func, .p1 = 2, .p2 = 2, .p3 = 4, .p4 = .{ .index = 0 } },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 4 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 4, .functions = &functions };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqualStrings("alias", textBytes(@constCast(vm.column(0).?)).?);
    try std.testing.expectEqual(@as(i64, 42), vm.column(3).?.u.i);
    try std.testing.expectEqual(@as(usize, 1), callback_state.calls);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "comparison jumps casts arithmetic nulls gosub and return preserve registers" {
    const operations = [_]Instruction{
        .{ .opcode = .gosub, .p1 = 1, .p2 = 13 },
        .{ .opcode = .string, .p2 = 2, .p4 = .{ .bytes = "42" } },
        .{ .opcode = .must_be_int, .p1 = 2 },
        .{ .opcode = .real_affinity, .p1 = 2 },
        .{ .opcode = .to_text, .p1 = 2 },
        .{ .opcode = .integer, .p1 = 7, .p2 = 3 },
        .{ .opcode = .integer, .p1 = 7, .p2 = 4 },
        .{ .opcode = .eq, .p1 = 4, .p2 = 10, .p3 = 3 },
        .{ .opcode = .integer, .p1 = -1, .p2 = 5 },
        .{ .opcode = .goto, .p2 = 11 },
        .{ .opcode = .copy, .p1 = 6, .p2 = 5 },
        .{ .opcode = .result_row, .p1 = 2, .p2 = 4 },
        .{ .opcode = .halt },
        .{ .opcode = .integer, .p1 = 99, .p2 = 6 },
        .{ .opcode = .return_, .p1 = 1 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 6 };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqualStrings("42.0", textBytes(@constCast(vm.column(0).?)).?);
    try std.testing.expectEqual(@as(i64, 7), vm.column(1).?.u.i);
    try std.testing.expectEqual(@as(i64, 7), vm.column(2).?.u.i);
    try std.testing.expectEqual(@as(i64, 99), vm.column(3).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "extended register opcodes preserve counters nulls casts maxima and subtypes" {
    const operations = [_]Instruction{
        .{ .opcode = .integer, .p1 = 5, .p2 = 1 },
        .{ .opcode = .integer, .p1 = 2, .p2 = 2 },
        .{ .opcode = .offset_limit, .p1 = 1, .p2 = 3, .p3 = 2 },
        .{ .opcode = .bit_not, .p1 = 1, .p2 = 4 },
        .{ .opcode = .null_, .p2 = 5 },
        .{ .opcode = .is_true, .p1 = 5, .p2 = 6, .p3 = 1, .p4 = .{ .integer = 1 } },
        .{ .opcode = .zero_or_null, .p1 = 1, .p2 = 7, .p3 = 5 },
        .{ .opcode = .integer, .p1 = 3, .p2 = 8 },
        .{ .opcode = .if_pos, .p1 = 8, .p2 = 10, .p3 = 2 },
        .{ .opcode = .integer, .p1 = 999, .p2 = 8 },
        .{ .opcode = .integer, .p1 = 2, .p2 = 9 },
        .{ .opcode = .if_not_zero, .p1 = 9, .p2 = 13 },
        .{ .opcode = .integer, .p1 = 999, .p2 = 9 },
        .{ .opcode = .integer, .p1 = 20, .p2 = 10 },
        .{ .opcode = .mem_max, .p1 = 1, .p2 = 10 },
        .{ .opcode = .string, .p2 = 11, .p4 = .{ .bytes = "value" } },
        .{ .opcode = .integer, .p1 = 65, .p2 = 12 },
        .{ .opcode = .set_subtype, .p1 = 12, .p2 = 11 },
        .{ .opcode = .get_subtype, .p1 = 11, .p2 = 13 },
        .{ .opcode = .clr_subtype, .p1 = 11 },
        .{ .opcode = .get_subtype, .p1 = 11, .p2 = 14 },
        .{ .opcode = .begin_subrtn, .p1 = 1, .p2 = 15, .p3 = 16 },
        .{ .opcode = .soft_null, .p1 = 11 },
        .{ .opcode = .string, .p2 = 17, .p4 = .{ .bytes = "42" } },
        .{ .opcode = .cast, .p1 = 17, .p2 = 0x44 },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 17 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 17 };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 20), vm.column(0).?.u.i);
    try std.testing.expectEqual(@as(i64, 7), vm.column(2).?.u.i);
    try std.testing.expectEqual(@as(i64, -6), vm.column(3).?.u.i);
    try std.testing.expectEqual(@as(i64, 0), vm.column(5).?.u.i);
    try std.testing.expect(isNull(vm.column(6).?));
    try std.testing.expectEqual(@as(i64, 1), vm.column(7).?.u.i);
    try std.testing.expectEqual(@as(i64, 1), vm.column(8).?.u.i);
    try std.testing.expect(isNull(vm.column(10).?));
    try std.testing.expectEqual(@as(i64, 65), vm.column(12).?.u.i);
    try std.testing.expect(isNull(vm.column(13).?));
    try std.testing.expect(vm.column(14).?.flags & mem_flag.cleared != 0);
    try std.testing.expect(vm.column(15).?.flags & mem_flag.cleared != 0);
    try std.testing.expectEqual(@as(i64, 42), vm.column(16).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "MakeRecord uses canonical integer serial types and preserves OOM ownership" {
    const integers = [_]i64{ -1, 0, 1, 127, 128, 32_768, 8_388_608, 2_147_483_648, 140_737_488_355_328, std.math.minInt(i64) };
    var values: [integers.len]Mem = undefined;
    for (&values, integers) |*value, integer| {
        vdbe_mem.init(value, null, mem_flag.null_);
        vdbe_mem.setInt64(value, integer);
    }
    const record = try encodeRecord(std.testing.allocator, &values);
    defer std.testing.allocator.free(record);
    const expected = [_]u8{
        0x0b, 0x01, 0x08, 0x09, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x06,
        0xff, 0x7f, 0x00, 0x80, 0x00, 0x80, 0x00, 0x00, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, &expected, record);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var value = std.mem.zeroes(Mem);
            vdbe_mem.init(&value, null, mem_flag.null_);
            vdbe_mem.setInt64(&value, 42);
            const encoded = try encodeRecord(allocator, @as(*[1]Mem, @ptrCast(&value)));
            defer allocator.free(encoded);
        }
    }.run, .{});
}

test "IsType and Affinity preserve storage classes and range conversion" {
    const rows = [_]TableRow{.{ .rowid = 1, .values = &.{ .{ .integer = 7 }, .{ .text = "x" } } }};
    const tables = [_]Table{.{ .rows = &rows }};
    const operations = [_]Instruction{
        .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },
        .{ .opcode = .rewind, .p1 = 0, .p2 = 12 },
        .{ .opcode = .is_type, .p1 = 0, .p2 = 4, .p3 = 0, .p5 = 0x01 },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .is_type, .p1 = 0, .p2 = 6, .p3 = 1, .p5 = 0x04 },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .is_type, .p1 = 0, .p2 = 8, .p3 = 9, .p4 = .{ .integer = 5 }, .p5 = 0x10 },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .string, .p2 = 1, .p4 = .{ .bytes = "42" } },
        .{ .opcode = .string, .p2 = 2, .p4 = .{ .bytes = "3.5" } },
        .{ .opcode = .affinity, .p1 = 1, .p2 = 2, .p4 = .{ .bytes = "DE" } },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 2 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 2, .cursor_count = 1, .tables = &tables };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 42), vm.column(0).?.u.i);
    try std.testing.expectEqual(@as(f64, 3.5), vm.column(1).?.u.r);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "IfSizeBetween and SeekEnd preserve row estimates and final positioning" {
    const rows = [_]TableRow{
        .{ .rowid = 2, .values = &.{} },
        .{ .rowid = 7, .values = &.{} },
    };
    const tables = [_]Table{.{ .rows = &rows }};
    const operations = [_]Instruction{
        .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },
        .{ .opcode = .if_size_between, .p1 = 0, .p2 = 3, .p3 = 10, .p4 = .{ .integer = 10 } },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .seek_end, .p1 = 0 },
        .{ .opcode = .rowid, .p1 = 0, .p2 = 1 },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 1 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 1, .cursor_count = 1, .tables = &tables };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 7), vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "cursor state opcodes preserve empty null-row and sequence behavior" {
    const nonempty_rows = [_]TableRow{.{ .rowid = 1, .values = &.{} }};
    const tables = [_]Table{ .{ .rows = &.{} }, .{ .rows = &nonempty_rows } };
    const operations = [_]Instruction{
        .{ .opcode = .open_data, .p1 = 0, .p2 = 0 },
        .{ .opcode = .if_empty, .p1 = 0, .p2 = 3 },
        .{ .opcode = .integer, .p1 = 999, .p2 = 1 },
        .{ .opcode = .sequence, .p1 = 0, .p2 = 1 },
        .{ .opcode = .open_data, .p1 = 1, .p2 = 1 },
        .{ .opcode = .sequence_test, .p1 = 1, .p2 = 7 },
        .{ .opcode = .integer, .p1 = 999, .p2 = 2 },
        .{ .opcode = .sequence, .p1 = 1, .p2 = 2 },
        .{ .opcode = .null_row, .p1 = 0 },
        .{ .opcode = .column, .p1 = 0, .p2 = 0, .p3 = 3 },
        .{ .opcode = .if_null_row, .p1 = 0, .p2 = 12, .p3 = 4 },
        .{ .opcode = .integer, .p1 = 999, .p2 = 4 },
        .{ .opcode = .if_not_open, .p1 = 0, .p2 = 14 },
        .{ .opcode = .integer, .p1 = 999, .p2 = 5 },
        .{ .opcode = .result_row, .p1 = 1, .p2 = 5 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 5, .cursor_count = 2, .tables = &tables };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 0), vm.column(0).?.u.i);
    try std.testing.expectEqual(@as(i64, 1), vm.column(1).?.u.i);
    try std.testing.expect(isNull(vm.column(2).?));
    try std.testing.expect(isNull(vm.column(3).?));
    try std.testing.expect(isNull(vm.column(4).?));
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "Permutation reorders the next vector comparison" {
    const order = [_]u8{ 1, 0 };
    const operations = [_]Instruction{
        .{ .opcode = .integer, .p1 = 1, .p2 = 1 },
        .{ .opcode = .integer, .p1 = 9, .p2 = 2 },
        .{ .opcode = .integer, .p1 = 2, .p2 = 3 },
        .{ .opcode = .integer, .p1 = 8, .p2 = 4 },
        .{ .opcode = .permutation, .p4 = .{ .bytes = &order } },
        .{ .opcode = .compare_values, .p1 = 1, .p2 = 3, .p3 = 2, .p5 = 1 },
        .{ .opcode = .jump, .p1 = 7, .p2 = 7, .p3 = 8 },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .integer, .p1 = 1, .p2 = 5 },
        .{ .opcode = .result_row, .p1 = 5, .p2 = 1 },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 5 };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, 1), vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

test "Compare and three-way Jump retain the preceding register order" {
    const operations = [_]Instruction{
        .{ .opcode = .integer, .p1 = 2, .p2 = 1 },
        .{ .opcode = .integer, .p1 = 3, .p2 = 2 },
        .{ .opcode = .compare_values, .p1 = 1, .p2 = 2, .p3 = 1 },
        .{ .opcode = .jump, .p1 = 5, .p2 = 7, .p3 = 9 },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .integer, .p1 = -1, .p2 = 3 },
        .{ .opcode = .result_row, .p1 = 3, .p2 = 1 },
        .{ .opcode = .halt },
        .{ .opcode = .halt, .p1 = 11 },
        .{ .opcode = .halt, .p1 = 11 },
    };
    const program = Program{ .instructions = &operations, .register_count = 3 };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.row, vm.step().result);
    try std.testing.expectEqual(@as(i64, -1), vm.column(0).?.u.i);
    try std.testing.expectEqual(ResultCode.done, vm.step().result);
}

fn failingCallback(_: ?*anyopaque, _: []Mem, output: *Mem, _: std.mem.Allocator) ResultCode {
    if (vdbe_mem.setStr(output, "discard", 7, 1, .transient) != 0) return .no_memory;
    return .constraint;
}

test "callback errors release provisional results and become sticky halt codes" {
    const functions = [_]Function{.{ .callback = failingCallback }};
    const operations = [_]Instruction{
        .{ .opcode = .null_, .p2 = 1 },
        .{ .opcode = .function, .p1 = 1, .p2 = 1, .p3 = 2, .p4 = .{ .index = 0 } },
        .{ .opcode = .halt },
    };
    const program = Program{ .instructions = &operations, .register_count = 2, .functions = &functions };
    var vm = try Vm.init(std.testing.allocator, &program, null);
    defer vm.deinit();
    try std.testing.expectEqual(ResultCode.constraint, vm.step().result);
    try std.testing.expectEqual(ResultCode.constraint, vm.step().result);
    try std.testing.expectEqual(State.failed, vm.state);
}
