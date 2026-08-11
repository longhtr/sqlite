//! Source-corresponding prepared-statement metadata, result-column, binding,
//! and VList operations from `vdbeapi.c` and `util.c`.

const std = @import("std");
const global = @import("../global.zig");
const public_api = @import("../public_api.zig");
const db_allocator = @import("db_allocator.zig");
const vdbe_aux = @import("vdbe_aux.zig");
const vdbe_mem = @import("vdbe_mem.zig");
pub const types = @import("vdbe_types.zig");

const result_error: c_int = 1;
const result_no_memory: c_int = 7;
const result_too_big: c_int = 18;
const result_misuse: c_int = 21;
const result_range: c_int = 25;
const result_io_error_no_memory: c_int = 10 | (12 << 8);
const statement_status_memory_used: c_int = 99;
const utf8: u8 = 1;
const utf8_terminated: u8 = 16;
const utf16_native: u8 = if (@import("builtin").target.cpu.arch.endian() == .little) 2 else 3;

fn enterConnection(connection: *types.Sqlite3) void {
    global.process_mutex_subsystem.enterOpaque(if (connection.mutex) |mutex| @ptrCast(mutex) else null);
}

fn leaveConnection(connection: *types.Sqlite3) void {
    global.process_mutex_subsystem.leaveOpaque(if (connection.mutex) |mutex| @ptrCast(mutex) else null);
}

fn setConnectionError(connection: *types.Sqlite3, result: c_int) void {
    connection.errCode = result;
    if (result != 0 or connection.pErr != null) {
        if (connection.pErr) |error_value| vdbe_mem.setNull(error_value);
    } else {
        connection.errByteOffset = -1;
    }
}

fn handleApiError(connection: *types.Sqlite3, result: c_int) c_int {
    if (connection.mallocFailed != 0 or result == result_io_error_no_memory) {
        db_allocator.oomClear(connection);
        setConnectionError(connection, result_no_memory);
        return result_no_memory;
    }
    return result & connection.errMask;
}

pub fn apiExit(connection: *types.Sqlite3, result: c_int) c_int {
    if (connection.mallocFailed != 0 or result != 0) return handleApiError(connection, result);
    return 0;
}

pub fn vdbeSafety(machine: *types.Vdbe) bool {
    if (machine.db != null) return false;
    public_api.zig_sqlite3_log_message(result_misuse, "API called with finalized prepared statement");
    return true;
}

pub fn vdbeSafetyNotNull(machine_optional: ?*types.Vdbe) bool {
    const machine = machine_optional orelse {
        public_api.zig_sqlite3_log_message(result_misuse, "API called with NULL prepared statement");
        return true;
    };
    return vdbeSafety(machine);
}

pub fn statementExpired(machine_optional: ?*types.Vdbe) c_int {
    const machine = machine_optional orelse return 1;
    const connection = machine.db.?;
    enterConnection(connection);
    const expired = machine.flags.expired;
    leaveConnection(connection);
    return expired;
}

pub fn clearBindings(machine: *types.Vdbe) c_int {
    const connection = machine.db.?;
    enterConnection(connection);
    if (machine.aVar) |variables| {
        for (variables[0..@intCast(machine.nVar)]) |*variable| {
            vdbe_mem.release(variable);
            variable.flags = types.mem_flag.null_;
        }
    }
    std.debug.assert(machine.prepFlags & types.prepare_save_sql != 0 or machine.expmask == 0);
    if (machine.expmask != 0) machine.flags.expired = 1;
    leaveConnection(connection);
    return 0;
}

/// Source `vdbeUnbind()`. Success deliberately returns with the connection
/// mutex held so the binding setter can replace the now-NULL value atomically.
pub fn unbind(machine_optional: ?*types.Vdbe, variable_index: u32) c_int {
    if (vdbeSafetyNotNull(machine_optional)) return result_misuse;
    const machine = machine_optional.?;
    const connection = machine.db.?;
    enterConnection(connection);
    if (machine.eVdbeState != types.vdbe_state.ready) {
        setConnectionError(connection, result_misuse);
        leaveConnection(connection);
        public_api.zig_sqlite3_log_message(result_misuse, "bind on a busy prepared statement");
        return result_misuse;
    }
    if (variable_index >= @as(u32, @intCast(machine.nVar))) {
        setConnectionError(connection, result_range);
        leaveConnection(connection);
        return result_range;
    }
    const variables = machine.aVar.?;
    const variable = &variables[variable_index];
    vdbe_mem.release(variable);
    variable.flags = types.mem_flag.null_;
    connection.errCode = 0;
    std.debug.assert(machine.prepFlags & types.prepare_save_sql != 0 or machine.expmask == 0);
    const mask: u32 = if (variable_index >= 31) 0x8000_0000 else mask: {
        const shift: u5 = @intCast(variable_index);
        break :mask @as(u32, 1) << shift;
    };
    if (machine.expmask != 0 and machine.expmask & mask != 0) {
        machine.flags.expired = 1;
    }
    return 0;
}

fn disposeBindingInput(connection: ?*types.Sqlite3, source: ?[*]const u8, ownership: vdbe_mem.StringOwnership) void {
    const pointer = source orelse return;
    switch (ownership) {
        .static, .transient => {},
        .dynamic => db_allocator.free(connection, @ptrCast(@constCast(pointer))),
        .custom => |destructor| destructor(@ptrCast(@constCast(pointer))),
    }
}

/// Source `bindText()`: bind text or blob bytes with source ownership,
/// encoding conversion, plan expiration, API-exit OOM normalization, and
/// destructor consumption on pre-bind failure.
pub fn bindText(
    machine: ?*types.Vdbe,
    one_based_index: c_int,
    source: ?[*]const u8,
    length: i64,
    ownership: vdbe_mem.StringOwnership,
    encoding: u8,
) c_int {
    const variable_index: u32 = @bitCast(one_based_index -% 1);
    var result = unbind(machine, variable_index);
    if (result == 0) {
        const active = machine.?;
        const connection = active.db.?;
        std.debug.assert(active.aVar != null and one_based_index > 0 and one_based_index <= active.nVar);
        if (source != null) {
            const variable = &active.aVar.?[@intCast(variable_index)];
            if (encoding == utf8) {
                result = vdbe_mem.setText(variable, source, length, ownership);
            } else if (encoding == utf8_terminated) {
                result = vdbe_mem.setText(variable, source, length, ownership);
                variable.flags |= types.mem_flag.terminated;
            } else {
                result = vdbe_mem.setStr(variable, source, length, encoding, ownership);
                if (encoding == 0) {
                    variable.enc = connection.enc;
                }
            }
            if (result == 0 and encoding != 0) {
                result = vdbe_mem.changeEncoding(variable, connection.enc);
            }
            if (result != 0) {
                setConnectionError(connection, result);
                result = apiExit(connection, result);
            }
        }
        leaveConnection(connection);
    } else if (ownership != .static and ownership != .transient) {
        disposeBindingInput(if (machine) |active| active.db else null, source, ownership);
    }
    return result;
}

/// Source `sqlite3_bind_double()` against the source-layout Vdbe owner.
pub fn bindDouble(machine: ?*types.Vdbe, one_based_index: c_int, value: f64) c_int {
    const variable_index: u32 = @bitCast(one_based_index -% 1);
    const result = unbind(machine, variable_index);
    if (result == 0) {
        const active = machine.?;
        std.debug.assert(active.aVar != null and one_based_index > 0 and one_based_index <= active.nVar);
        vdbe_mem.setDouble(&active.aVar.?[variable_index], value);
        leaveConnection(active.db.?);
    }
    return result;
}

/// Source `sqlite3_bind_int64()` against the source-layout Vdbe owner.
pub fn bindInt64(machine: ?*types.Vdbe, one_based_index: c_int, value: i64) c_int {
    const variable_index: u32 = @bitCast(one_based_index -% 1);
    const result = unbind(machine, variable_index);
    if (result == 0) {
        const active = machine.?;
        std.debug.assert(active.aVar != null and one_based_index > 0 and one_based_index <= active.nVar);
        vdbe_mem.setInt64(&active.aVar.?[variable_index], value);
        leaveConnection(active.db.?);
    }
    return result;
}

/// Source `sqlite3_bind_null()` against the source-layout Vdbe owner.
pub fn bindNull(machine: ?*types.Vdbe, one_based_index: c_int) c_int {
    const variable_index: u32 = @bitCast(one_based_index -% 1);
    const result = unbind(machine, variable_index);
    if (result == 0) {
        const active = machine.?;
        std.debug.assert(active.aVar != null and one_based_index > 0 and one_based_index <= active.nVar);
        leaveConnection(active.db.?);
    }
    return result;
}

/// Source `sqlite3_bind_pointer()` including destructor consumption when the
/// statement cannot accept the pointer.
pub fn bindPointer(
    machine: ?*types.Vdbe,
    one_based_index: c_int,
    pointer: ?*anyopaque,
    pointer_type: ?[*:0]const u8,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int {
    const variable_index: u32 = @bitCast(one_based_index -% 1);
    const result = unbind(machine, variable_index);
    if (result == 0) {
        const active = machine.?;
        std.debug.assert(active.aVar != null and one_based_index > 0 and one_based_index <= active.nVar);
        vdbe_mem.setPointer(&active.aVar.?[variable_index], pointer, pointer_type, destructor);
        leaveConnection(active.db.?);
    } else if (destructor) |destroy| {
        destroy(pointer);
    }
    return result;
}

/// Source `sqlite3_bind_zeroblob()` against the source-layout Vdbe owner.
pub fn bindZeroBlob(machine: ?*types.Vdbe, one_based_index: c_int, length: c_int) c_int {
    const variable_index: u32 = @bitCast(one_based_index -% 1);
    const result = unbind(machine, variable_index);
    if (result == 0) {
        const active = machine.?;
        std.debug.assert(active.aVar != null and one_based_index > 0 and one_based_index <= active.nVar);
        vdbe_mem.setZeroBlob(&active.aVar.?[variable_index], length);
        leaveConnection(active.db.?);
    }
    return result;
}

/// Source `sqlite3_bind_zeroblob64()`, including the outer recursive mutex
/// scope and API-exit normalization.
pub fn bindZeroBlob64(machine: ?*types.Vdbe, one_based_index: c_int, length: u64) c_int {
    const active = machine orelse return result_misuse;
    const connection = active.db.?;
    enterConnection(connection);
    var result = if (length > @as(u64, @intCast(connection.aLimit[0])))
        result_too_big
    else
        bindZeroBlob(active, one_based_index, @intCast(length));
    result = apiExit(connection, result);
    leaveConnection(connection);
    return result;
}

/// Source `sqlite3_bind_value()`: preserve the source storage-class switch,
/// integer-real conversion, zero-blob representation, and transient copy.
pub fn bindValue(machine: ?*types.Vdbe, one_based_index: c_int, value: *const types.Mem) c_int {
    return switch (vdbe_mem.valueType(value)) {
        1 => bindInt64(machine, one_based_index, value.u.i),
        2 => bindDouble(machine, one_based_index, if (value.flags & types.mem_flag.real != 0) value.u.r else @floatFromInt(value.u.i)),
        4 => if (value.flags & types.mem_flag.zero != 0)
            bindZeroBlob(machine, one_based_index, value.u.nZero)
        else
            bindText(machine, one_based_index, value.z, value.n, .transient, 0),
        3 => bindText(machine, one_based_index, value.z, value.n, .transient, value.enc),
        5 => bindNull(machine, one_based_index),
        else => unreachable,
    };
}

pub fn columnCount(machine_optional: ?*const types.Vdbe) c_int {
    return if (machine_optional) |machine| machine.nResColumn else 0;
}

const explain_column_names_utf8 = [_][*:0]const u8{
    "addr", "opcode", "p1",      "p2",     "p3", "p4", "p5", "comment",
    "id",   "parent", "notused", "detail",
};
const explain_column_names_utf16_data = [_]u16{
    'a', 'd', 'd', 'r', 0,
    'o', 'p', 'c', 'o', 'd',
    'e', 0,   'p', '1', 0,
    'p', '2', 0,   'p', '3',
    0,   'p', '4', 0,   'p',
    '5', 0,   'c', 'o', 'm',
    'm', 'e', 'n', 't', 0,
    'i', 'd', 0,   'p', 'a',
    'r', 'e', 'n', 't', 0,
    'n', 'o', 't', 'u', 's',
    'e', 'd', 0,   'd', 'e',
    't', 'a', 'i', 'l', 0,
};
const explain_column_names_utf16_offsets = [_]u8{ 0, 5, 12, 15, 18, 21, 24, 27, 35, 38, 45, 53 };

/// Source `columnName()` shared result-column metadata accessor.
pub fn columnName(machine_optional: ?*types.Vdbe, column_index: c_int, use_utf16: bool, variant: usize) ?*const anyopaque {
    const machine = machine_optional orelse return null;
    if (column_index < 0) return null;
    const connection = machine.db.?;
    enterConnection(connection);
    defer leaveConnection(connection);

    if (machine.explain != 0) {
        if (variant != types.column_name.name) return null;
        const count: c_int = if (machine.explain == 1) 8 else 4;
        if (column_index >= count) return null;
        const offset: usize = @intCast(column_index + 8 * machine.explain - 8);
        if (use_utf16) {
            return @ptrCast(&explain_column_names_utf16_data[explain_column_names_utf16_offsets[offset]]);
        }
        return @ptrCast(explain_column_names_utf8[offset]);
    }

    if (column_index >= machine.nResColumn or variant >= types.column_name.count) return null;
    const previous_malloc_failed = connection.mallocFailed;
    const index: usize = @intCast(column_index + @as(c_int, @intCast(variant)) * machine.nResColumn);
    const result = vdbe_mem.valueText(&machine.aColName.?[index], if (use_utf16) utf16_native else utf8);
    if (connection.mallocFailed > previous_malloc_failed) {
        db_allocator.oomClear(connection);
        return null;
    }
    return if (result) |pointer| @ptrCast(pointer) else null;
}

pub fn columnName8(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u8 {
    return if (columnName(machine, column_index, false, types.column_name.name)) |pointer| @ptrCast(pointer) else null;
}

pub fn columnName16(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u16 {
    return if (columnName(machine, column_index, true, types.column_name.name)) |pointer| @ptrCast(@alignCast(pointer)) else null;
}

pub fn columnDeclaredType(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u8 {
    return if (columnName(machine, column_index, false, types.column_name.declared_type)) |pointer| @ptrCast(pointer) else null;
}

pub fn columnDeclaredType16(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u16 {
    return if (columnName(machine, column_index, true, types.column_name.declared_type)) |pointer| @ptrCast(@alignCast(pointer)) else null;
}

pub fn dataCount(machine_optional: ?*const types.Vdbe) c_int {
    const machine = machine_optional orelse return 0;
    if (machine.pResultRow == null) return 0;
    return machine.nResColumn;
}

const null_column_value = types.Mem{
    .u = .{ .i = 0 },
    .z = null,
    .n = 0,
    .flags = types.mem_flag.null_,
    .enc = 0,
    .eSubtype = 0,
    .db = null,
    .szMalloc = 0,
    .uTemp = 0,
    .zMalloc = null,
    .xDel = null,
};

pub fn columnNullValue() *types.Mem {
    return @constCast(&null_column_value);
}

pub fn columnMem(machine_optional: ?*types.Vdbe, column_index: c_int) *types.Mem {
    const machine = machine_optional orelse return columnNullValue();
    const connection = machine.db.?;
    enterConnection(connection);
    if (machine.pResultRow != null and column_index >= 0 and column_index < machine.nResColumn) {
        const row: [*]types.Mem = @ptrCast(machine.pResultRow.?);
        return &row[@intCast(column_index)];
    }
    setConnectionError(connection, result_range);
    return columnNullValue();
}

pub fn columnMallocFailure(machine_optional: ?*types.Vdbe) void {
    const machine = machine_optional orelse return;
    const connection = machine.db.?;
    machine.rc = apiExit(connection, machine.rc);
    leaveConnection(connection);
}

pub fn columnBlob(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u8 {
    const result = vdbe_mem.valueBlob(columnMem(machine, column_index));
    columnMallocFailure(machine);
    return result;
}

pub fn columnBytes(machine: ?*types.Vdbe, column_index: c_int) c_int {
    const result = vdbe_mem.valueBytes(columnMem(machine, column_index), utf8);
    columnMallocFailure(machine);
    return result;
}

pub fn columnBytes16(machine: ?*types.Vdbe, column_index: c_int) c_int {
    const result = vdbe_mem.valueBytes(columnMem(machine, column_index), utf16_native);
    columnMallocFailure(machine);
    return result;
}

pub fn columnDouble(machine: ?*types.Vdbe, column_index: c_int) f64 {
    const result = vdbe_mem.valueDouble(columnMem(machine, column_index));
    columnMallocFailure(machine);
    return result;
}

pub fn columnInt(machine: ?*types.Vdbe, column_index: c_int) c_int {
    const result = vdbe_mem.valueInt(columnMem(machine, column_index));
    columnMallocFailure(machine);
    return result;
}

pub fn columnInt64(machine: ?*types.Vdbe, column_index: c_int) i64 {
    const result = vdbe_mem.valueInt64(columnMem(machine, column_index));
    columnMallocFailure(machine);
    return result;
}

pub fn columnText(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u8 {
    const result = vdbe_mem.valueText(columnMem(machine, column_index), utf8);
    columnMallocFailure(machine);
    return result;
}

pub fn columnValue(machine: ?*types.Vdbe, column_index: c_int) *types.Mem {
    const result = columnMem(machine, column_index);
    if (result.flags & types.mem_flag.static != 0) {
        result.flags &= ~types.mem_flag.static;
        result.flags |= types.mem_flag.ephemeral;
    }
    columnMallocFailure(machine);
    return result;
}

pub fn columnText16(machine: ?*types.Vdbe, column_index: c_int) ?[*]const u8 {
    const result = vdbe_mem.valueText(columnMem(machine, column_index), utf16_native);
    columnMallocFailure(machine);
    return result;
}

pub fn columnType(machine: ?*types.Vdbe, column_index: c_int) c_int {
    const result = vdbe_mem.valueType(columnMem(machine, column_index));
    columnMallocFailure(machine);
    return result;
}

fn vlistIntegers(list: *types.VList) [*]c_int {
    return @ptrCast(@alignCast(list));
}

pub fn vlistAdd(
    connection: *types.Sqlite3,
    list_optional: ?*types.VList,
    name: [*]const u8,
    name_length: c_int,
    value: c_int,
) ?*types.VList {
    std.debug.assert(name_length >= 0);
    const integer_count: c_int = @divTrunc(name_length, @sizeOf(c_int)) + 3;
    if (list_optional) |list| std.debug.assert(vlistIntegers(list)[0] >= 3);
    var list = list_optional;
    const needs_growth = list == null or vlistIntegers(list.?)[1] + integer_count > vlistIntegers(list.?)[0];
    if (needs_growth) {
        const previous_allocation = if (list) |existing| @as(i64, vlistIntegers(existing)[0]) else 0;
        const allocation_count: i64 = (if (list == null) 10 else 2 * previous_allocation) + integer_count;
        const replacement = db_allocator.realloc(connection, if (list) |existing| @ptrCast(existing) else null, @intCast(allocation_count * @sizeOf(c_int))) orelse return list;
        list = @ptrCast(@alignCast(replacement));
        const integers = vlistIntegers(list.?);
        if (list_optional == null) integers[1] = 2;
        integers[0] = @intCast(allocation_count);
    }
    const integers = vlistIntegers(list.?);
    const entry_index: usize = @intCast(integers[1]);
    integers[entry_index] = value;
    integers[entry_index + 1] = integer_count;
    const output_name: [*]u8 = @ptrCast(&integers[entry_index + 2]);
    @memcpy(output_name[0..@intCast(name_length)], name[0..@intCast(name_length)]);
    output_name[@intCast(name_length)] = 0;
    integers[1] += integer_count;
    std.debug.assert(integers[1] <= integers[0]);
    return list;
}

pub fn vlistNumberToName(list_optional: ?*types.VList, value: c_int) ?[*:0]const u8 {
    const list = list_optional orelse return null;
    const integers = vlistIntegers(list);
    const used = integers[1];
    var entry_index: c_int = 2;
    while (true) {
        const index: usize = @intCast(entry_index);
        if (integers[index] == value) return @ptrCast(&integers[index + 2]);
        entry_index += integers[index + 1];
        if (entry_index >= used) return null;
    }
}

pub fn vlistNameToNumber(list_optional: ?*types.VList, name: [*]const u8, name_length: c_int) c_int {
    const list = list_optional orelse return 0;
    std.debug.assert(name_length >= 0);
    const integers = vlistIntegers(list);
    const used = integers[1];
    var entry_index: c_int = 2;
    while (true) {
        const index: usize = @intCast(entry_index);
        const stored_name: [*]const u8 = @ptrCast(&integers[index + 2]);
        const length: usize = @intCast(name_length);
        if (std.mem.eql(u8, stored_name[0..length], name[0..length]) and stored_name[length] == 0) return integers[index];
        entry_index += integers[index + 1];
        if (entry_index >= used) return 0;
    }
}

pub fn bindParameterCount(machine_optional: ?*const types.Vdbe) c_int {
    return if (machine_optional) |machine| machine.nVar else 0;
}

pub fn bindParameterName(machine_optional: ?*types.Vdbe, variable: c_int) ?[*:0]const u8 {
    const machine = machine_optional orelse return null;
    return vlistNumberToName(machine.pVList, variable);
}

pub fn parameterIndex(machine_optional: ?*types.Vdbe, name_optional: ?[*]const u8, name_length: c_int) c_int {
    const machine = machine_optional orelse return 0;
    const name = name_optional orelse return 0;
    return vlistNameToNumber(machine.pVList, name, name_length);
}

pub fn bindParameterIndex(machine: ?*types.Vdbe, name: [*:0]const u8) c_int {
    return parameterIndex(machine, name, @intCast(std.mem.len(name)));
}

pub fn transferBindings(from: *types.Vdbe, to: *types.Vdbe) c_int {
    std.debug.assert(to.db == from.db);
    std.debug.assert(to.nVar == from.nVar);
    const connection = to.db.?;
    enterConnection(connection);
    if (from.aVar != null and to.aVar != null) {
        for (0..@intCast(from.nVar)) |index| vdbe_mem.move(&to.aVar.?[index], &from.aVar.?[index]);
    }
    leaveConnection(connection);
    return 0;
}

pub fn transferBindingsDeprecated(from: *types.Vdbe, to: *types.Vdbe) c_int {
    if (from.nVar != to.nVar) return result_error;
    std.debug.assert(to.prepFlags & types.prepare_save_sql != 0 or to.expmask == 0);
    if (to.expmask != 0) to.flags.expired = 1;
    std.debug.assert(from.prepFlags & types.prepare_save_sql != 0 or from.expmask == 0);
    if (from.expmask != 0) from.flags.expired = 1;
    return transferBindings(from, to);
}

pub fn databaseHandle(machine_optional: ?*types.Vdbe) ?*types.Sqlite3 {
    return if (machine_optional) |machine| machine.db else null;
}

pub fn statementReadonly(machine_optional: ?*const types.Vdbe) c_int {
    return if (machine_optional) |machine| @intFromBool(machine.flags.readOnly) else 1;
}

pub fn statementIsExplain(machine_optional: ?*const types.Vdbe) c_int {
    return if (machine_optional) |machine| machine.flags.explain else 0;
}

pub fn statementBusy(machine_optional: ?*const types.Vdbe) c_int {
    return @intFromBool(if (machine_optional) |machine| machine.eVdbeState == types.vdbe_state.run else false);
}

pub fn nextStatement(connection: *types.Sqlite3, machine_optional: ?*types.Vdbe) ?*types.Vdbe {
    enterConnection(connection);
    const next = if (machine_optional) |machine| machine.pVNext else connection.pVdbe;
    leaveConnection(connection);
    return next;
}

pub fn statementStatus(machine: *types.Vdbe, operation: c_int, reset: bool) c_int {
    if (operation == statement_status_memory_used) {
        const connection = machine.db.?;
        enterConnection(connection);
        var memory_used: c_int = 0;
        connection.pnBytesFreed = &memory_used;
        std.debug.assert(connection.lookaside.pEnd == connection.lookaside.pTrueEnd);
        connection.lookaside.pEnd = connection.lookaside.pStart;
        vdbe_aux.deleteVdbe(machine);
        connection.pnBytesFreed = null;
        connection.lookaside.pEnd = connection.lookaside.pTrueEnd;
        leaveConnection(connection);
        return memory_used;
    }
    const index: usize = @intCast(operation);
    const value = machine.aCounter[index];
    if (reset) machine.aCounter[index] = 0;
    return @bitCast(value);
}

pub fn statementSql(machine_optional: ?*const types.Vdbe) ?[*:0]const u8 {
    return if (machine_optional) |machine| machine.zSql else null;
}
