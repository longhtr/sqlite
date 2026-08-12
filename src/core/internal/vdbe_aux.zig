//! Source-corresponding small VDBE state helpers from `vdbeaux.c`.

const std = @import("std");
pub const types = @import("vdbe_types.zig");
pub const canonical_opcode = @import("../generated/opcodes.zig");
pub const db_allocator = @import("db_allocator.zig");
const btree_aux = @import("btree_aux.zig");
const vdbe_mem = @import("vdbe_mem.zig");
const global_memory = @import("../memory.zig");
const compiler_ownership = @import("compiler_ownership.zig");

const limit_vdbe_op: usize = 5;
const result_corrupt: c_int = 11;

fn parseDatabase(parse: *types.Parse) *types.Sqlite3 {
    return @ptrCast(@alignCast(parse.db.?));
}

/// Source `sqlite3ParseObjectInit()`: clear the recursive header and
/// non-recursive tail while preserving Lemon recursive state, then link the
/// Parse at the connection head.
pub fn initializeParseObject(parse: *types.Parse, db: *types.Sqlite3) void {
    const bytes: [*]u8 = @ptrCast(parse);
    const header_start = @offsetOf(types.Parse, "zErrMsg");
    @memset(bytes[header_start .. header_start + types.Parse.header_size], 0);
    @memset(bytes[types.Parse.recursive_offset .. types.Parse.recursive_offset + types.Parse.tail_size], 0);
    std.debug.assert(db.pParse != parse);
    parse.pOuterParse = db.pParse;
    db.pParse = parse;
    parse.db = @ptrCast(db);
    if (db.mallocFailed != 0) {
        db.errByteOffset = -1;
        parse.nErr += 1;
        parse.rc = if (db.suppressErr != 0) types.result_no_memory else types.result_error;
        parse.pWith = null;
    }
}

/// Source `sqlite3ParseObjectReset()`: release every Parse-owned allocation,
/// restore lookaside availability, and unlink this Parse from the connection.
pub fn resetParseObject(parse: *types.Parse) void {
    const db = parseDatabase(parse);
    std.debug.assert(db.pParse == parse);
    std.debug.assert(parse.nested == 0);
    if (parse.aTableLock) |locks| db_allocator.freeNN(db, @ptrCast(locks));
    while (parse.pCleanup) |cleanup| {
        parse.pCleanup = cleanup.pNext;
        cleanup.xCleanup.?(parse.db, cleanup.pPtr);
        db_allocator.freeNN(db, @ptrCast(cleanup));
    }
    if (parse.aLabel) |labels| db_allocator.freeNN(db, @ptrCast(labels));
    compiler_ownership.deleteExpressionList(db, parse.pConstExpr);
    std.debug.assert(db.lookaside.bDisable >= parse.disableLookaside);
    db.lookaside.bDisable -= parse.disableLookaside;
    db.lookaside.sz = if (db.lookaside.bDisable != 0) 0 else db.lookaside.szTrue;
    std.debug.assert(db.pParse == parse);
    db.pParse = parse.pOuterParse;
}

/// Source `sqlite3VdbeCreate()`: allocate the statement object, link it at
/// the connection head, establish Parse ownership, and append OP_Init.
pub fn create(parse: *types.Parse) ?*types.Vdbe {
    const db = parseDatabase(parse);
    const raw = db_allocator.mallocRawNN(db, @sizeOf(types.Vdbe)) orelse return null;
    const machine: *types.Vdbe = @ptrCast(@alignCast(raw));
    const bytes: [*]u8 = @ptrCast(raw);
    @memset(bytes[@offsetOf(types.Vdbe, "aOp")..@sizeOf(types.Vdbe)], 0);
    machine.db = db;
    if (db.pVdbe) |head| head.ppVPrev = &machine.pVNext;
    machine.pVNext = db.pVdbe;
    machine.ppVPrev = &db.pVdbe;
    db.pVdbe = machine;
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    machine.pParse = parse;
    parse.pVdbe = @ptrCast(machine);
    std.debug.assert(parse.aLabel == null);
    std.debug.assert(parse.nLabel == 0);
    std.debug.assert(machine.nOpAlloc == 0);
    std.debug.assert(parse.szOpAlloc == 0);
    _ = addOperation2(machine, .Init, 0, 1);
    return machine;
}

/// Source `growOpArray()`: preserve geometric growth, allocator-reported
/// capacity, the connection opcode limit, and unchanged ownership on OOM.
fn growOperationArray(machine: *types.Vdbe, operation_count: c_int) c_int {
    const parse = machine.pParse.?;
    const db = parseDatabase(parse);
    const new_count: i64 = if (machine.nOpAlloc != 0)
        2 * @as(i64, machine.nOpAlloc)
    else
        1024 / @as(i64, @sizeOf(types.VdbeOp));

    if (new_count > db.aLimit[limit_vdbe_op]) {
        _ = db_allocator.oomFault(db);
        return types.result_no_memory;
    }

    std.debug.assert(operation_count <= 1024 / @as(c_int, @intCast(@sizeOf(types.VdbeOp))));
    std.debug.assert(new_count >= @as(i64, machine.nOpAlloc) + operation_count);
    const bytes: u64 = @intCast(new_count * @as(i64, @sizeOf(types.VdbeOp)));
    const raw = db_allocator.realloc(db, if (machine.aOp) |operations| @ptrCast(operations) else null, bytes) orelse
        return types.result_no_memory;
    const operations: [*]types.VdbeOp = @ptrCast(@alignCast(raw));
    parse.szOpAlloc = @intCast(db_allocator.allocationSize(db, raw));
    machine.nOpAlloc = @divTrunc(parse.szOpAlloc, @as(c_int, @intCast(@sizeOf(types.VdbeOp))));
    machine.aOp = operations;
    return types.result_ok;
}

fn growOperation3(machine: *types.Vdbe, opcode: canonical_opcode.Opcode, p1: c_int, p2: c_int, p3: c_int) c_int {
    std.debug.assert(machine.nOpAlloc <= machine.nOp);
    if (growOperationArray(machine, 1) != types.result_ok) return 1;
    std.debug.assert(machine.nOpAlloc > machine.nOp);
    return addOperation3(machine, opcode, p1, p2, p3);
}

fn addOperation4IntSlow(machine: *types.Vdbe, opcode: canonical_opcode.Opcode, p1: c_int, p2: c_int, p3: c_int, p4: c_int) c_int {
    const address = addOperation3(machine, opcode, p1, p2, p3);
    if (machine.db.?.mallocFailed == 0) {
        const operation = &machine.aOp.?[@intCast(address)];
        operation.p4type = types.p4.int32;
        operation.p4.i = p4;
    }
    return address;
}

pub fn addOperation0(machine: *types.Vdbe, opcode: canonical_opcode.Opcode) c_int {
    return addOperation3(machine, opcode, 0, 0, 0);
}

pub fn addOperation1(machine: *types.Vdbe, opcode: canonical_opcode.Opcode, p1: c_int) c_int {
    return addOperation3(machine, opcode, p1, 0, 0);
}

pub fn addOperation2(machine: *types.Vdbe, opcode: canonical_opcode.Opcode, p1: c_int, p2: c_int) c_int {
    return addOperation3(machine, opcode, p1, p2, 0);
}

pub fn addOperation3(machine: *types.Vdbe, opcode: canonical_opcode.Opcode, p1: c_int, p2: c_int, p3: c_int) c_int {
    const address = machine.nOp;
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    if (machine.nOpAlloc <= address) return growOperation3(machine, opcode, p1, p2, p3);
    std.debug.assert(machine.aOp != null);
    machine.nOp += 1;
    const operation = &machine.aOp.?[@intCast(address)];
    operation.opcode = opcode;
    operation.p5 = 0;
    operation.p1 = p1;
    operation.p2 = p2;
    operation.p3 = p3;
    operation.p4.p = null;
    operation.p4type = types.p4.not_used;
    return address;
}

pub fn addOperation4Int(machine: *types.Vdbe, opcode: canonical_opcode.Opcode, p1: c_int, p2: c_int, p3: c_int, p4: c_int) c_int {
    const address = machine.nOp;
    if (machine.nOpAlloc <= address) return addOperation4IntSlow(machine, opcode, p1, p2, p3, p4);
    machine.nOp += 1;
    const operation = &machine.aOp.?[@intCast(address)];
    operation.opcode = opcode;
    operation.p5 = 0;
    operation.p1 = p1;
    operation.p2 = p2;
    operation.p3 = p3;
    operation.p4.i = p4;
    operation.p4type = types.p4.int32;
    return address;
}

/// Source `sqlite3VdbeGoto()` unconditional-jump append wrapper.
pub fn addGoto(machine: *types.Vdbe, destination: c_int) c_int {
    return addOperation3(machine, .Goto, 0, destination, 0);
}

/// Source `sqlite3VdbeAddOp4()` with explicit pointer ownership.
pub fn addOperation4(
    machine: *types.Vdbe,
    opcode: canonical_opcode.Opcode,
    p1: c_int,
    p2: c_int,
    p3: c_int,
    payload: ?*anyopaque,
    payload_type: i8,
) c_int {
    const address = addOperation3(machine, opcode, p1, p2, p3);
    if (payload_type == types.p4.transient) {
        if (payload) |text| {
            changeP4String(machine, address, @ptrCast(text), 0);
        } else if (machine.db.?.mallocFailed == 0) {
            const operation = operationForP4Change(machine, address);
            clearReplaceableP4(operation);
            operation.p4.z = null;
            operation.p4type = types.p4.dynamic;
        }
    } else {
        std.debug.assert(payload_type != types.p4.int32);
        changeP4(machine, address, payload, payload_type);
    }
    return address;
}

/// Source `sqlite3VdbeLoadString()`.
pub fn loadString(machine: *types.Vdbe, destination: c_int, text: [*:0]const u8) c_int {
    return addOperation4(machine, .String8, 0, destination, 0, @ptrCast(@constCast(text)), types.p4.transient);
}

pub const MultiLoadValue = union(enum) {
    string: ?[*:0]const u8,
    integer: c_int,
    stop,
};

/// Typed source-faithful replacement for `sqlite3VdbeMultiLoad()` varargs.
pub fn multiLoad(machine: *types.Vdbe, first_destination: c_int, values: []const MultiLoadValue) void {
    var result_count: c_int = 0;
    for (values, 0..) |value, offset| {
        const destination = first_destination + @as(c_int, @intCast(offset));
        switch (value) {
            .string => |text_optional| {
                if (text_optional) |text| {
                    _ = addOperation4(machine, .String8, 0, destination, 0, @ptrCast(@constCast(text)), types.p4.transient);
                } else {
                    _ = addOperation4(machine, .Null, 0, destination, 0, null, types.p4.transient);
                }
            },
            .integer => |integer| _ = addOperation2(machine, .Integer, integer, destination),
            .stop => return,
        }
        result_count += 1;
    }
    _ = addOperation2(machine, .ResultRow, first_destination, result_count);
}

/// Source `sqlite3MultiWrite()`.
pub fn markMultiWrite(parse: *types.Parse) void {
    const top_level = parse.pToplevel orelse parse;
    top_level.isMultiWrite = 1;
}

/// Source `sqlite3MayAbort()`.
pub fn markMayAbort(parse: *types.Parse) void {
    const top_level = parse.pToplevel orelse parse;
    top_level.flags0 |= 0x02;
}

/// Source `sqlite3VdbeAddFunctionCall()`.
pub fn addFunctionCall(
    parse: *types.Parse,
    constant_argument_mask: c_int,
    first_argument_register: c_int,
    result_register: c_int,
    argument_count: c_int,
    function: *const types.FuncDef,
    call_context: c_int,
) c_int {
    const machine: *types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    const raw = db_allocator.mallocRawNN(parseDatabase(parse), types.contextSize(@intCast(argument_count))) orelse {
        freeEphemeralFunction(parseDatabase(parse), @ptrCast(@constCast(function)));
        return 0;
    };
    const context: *types.Context = @ptrCast(@alignCast(raw));
    context.pOut = null;
    context.pFunc = @ptrCast(@constCast(function));
    context.pVdbe = null;
    context.isError = 0;
    context.argc = @intCast(argument_count);
    context.iOp = currentAddress(machine);
    const address = addOperation4(
        machine,
        if (call_context != 0) .PureFunc else .Function,
        constant_argument_mask,
        first_argument_register,
        result_register,
        context,
        types.p4.funcctx,
    );
    changeP5(machine, @intCast(call_context & 0x2e));
    markMayAbort(parse);
    return address;
}

/// Source `sqlite3VdbeAddOp4Dup8()`.
pub fn addOperation4Duplicate8(
    machine: *types.Vdbe,
    opcode: canonical_opcode.Opcode,
    p1: c_int,
    p2: c_int,
    p3: c_int,
    payload: *const [8]u8,
    payload_type: i8,
) c_int {
    std.debug.assert(payload_type == types.p4.int64 or payload_type == types.p4.real);
    const copy = db_allocator.mallocRawNN(machine.db.?, 8);
    if (copy) |allocation| @memcpy(@as([*]u8, @ptrCast(allocation))[0..8], payload);
    return addOperation4(machine, opcode, p1, p2, p3, copy, payload_type);
}

/// Preformatted-message form of source `sqlite3VdbeExplain()`.
pub fn addExplain(parse: *types.Parse, push: bool, message: [*:0]const u8) c_int {
    const db = parseDatabase(parse);
    if (parse.explain != 2 and db.flags & types.connection_flag.statement_scan_status == 0) return 0;
    const machine: *types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    const owned_message = db_allocator.stringDuplicate(db, message);
    const this_address = machine.nOp;
    const address = addOperation4(machine, .Explain, this_address, parse.addrExplain, 0, if (owned_message) |owned| @ptrCast(owned) else null, types.p4.dynamic);
    if (push) parse.addrExplain = this_address;
    return address;
}

/// Source `sqlite3VdbeAddParseSchemaOp()`.
pub fn addParseSchemaOperation(machine: *types.Vdbe, database_index: c_int, where_clause: ?[*:0]u8, p5: u16) void {
    _ = addOperation4(machine, .ParseSchema, database_index, 0, 0, if (where_clause) |text| @ptrCast(text) else null, types.p4.dynamic);
    changeP5(machine, p5);
    var index: c_int = 0;
    while (index < machine.db.?.nDb) : (index += 1) usesBtree(machine, index);
    markMayAbort(machine.pParse.?);
}

/// Source `sqlite3VdbeEndCoroutine()`.
pub fn endCoroutine(machine: *types.Vdbe, yield_register: c_int) void {
    _ = addOperation1(machine, .EndCoroutine, yield_register);
    machine.pParse.?.nTempReg = 0;
    machine.pParse.?.nRangeReg = 0;
}

/// Preformatted-message form of source `sqlite3VdbeError()`.
pub fn setErrorMessage(machine: *types.Vdbe, message: [*:0]const u8) void {
    const db = machine.db.?;
    db_allocator.free(db, if (machine.zErrMsg) |previous| @ptrCast(previous) else null);
    machine.zErrMsg = db_allocator.stringDuplicate(db, message);
}

/// Source EXPLAIN parent lookup and stack pop helpers.
pub fn explainParent(parse: *types.Parse) c_int {
    if (parse.addrExplain == 0) return 0;
    const machine: *types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    return getOperation(machine, parse.addrExplain).p2;
}

pub fn explainPop(parse: *types.Parse) void {
    parse.addrExplain = explainParent(parse);
}

/// Source `sqlite3ProgressCheck()`: preserve interrupt and callback order.
pub fn progressCheck(parse: *types.Parse) void {
    const db = parseDatabase(parse);
    if (@atomicLoad(c_int, &db.u1.isInterrupted, .monotonic) != 0) {
        parse.nErr += 1;
        parse.rc = types.result_interrupt;
    }
    if (db.xProgress) |callback| {
        if (parse.rc == types.result_interrupt) {
            parse.nProgressSteps = 0;
        } else {
            parse.nProgressSteps += 1;
            if (parse.nProgressSteps >= db.nProgressOps) {
                if (callback(db.pProgressArg) != 0) {
                    parse.nErr += 1;
                    parse.rc = types.result_interrupt;
                }
                parse.nProgressSteps = 0;
            }
        }
    }
}

/// Source `sqlite3VdbeMakeLabel()` stores the negative issued-label count.
pub fn makeLabel(parse: *types.Parse) c_int {
    parse.nLabel -= 1;
    return parse.nLabel;
}

fn resizeResolveLabel(parse: *types.Parse, machine: *types.Vdbe, index: c_int) void {
    const new_size = 10 - parse.nLabel;
    const bytes: u64 = @intCast(@as(i64, new_size) * @sizeOf(c_int));
    const replacement = db_allocator.reallocOrFree(parseDatabase(parse), if (parse.aLabel) |labels| @ptrCast(labels) else null, bytes);
    parse.aLabel = if (replacement) |pointer| @ptrCast(@alignCast(pointer)) else null;
    if (parse.aLabel == null) {
        parse.nLabelAlloc = 0;
    } else {
        if (new_size >= 100 and @divTrunc(new_size, 100) > @divTrunc(parse.nLabelAlloc, 100)) progressCheck(parse);
        parse.nLabelAlloc = new_size;
        parse.aLabel.?[@intCast(index)] = machine.nOp;
    }
}

/// Source `sqlite3VdbeResolveLabel()` binds one issued label to the next op.
pub fn resolveLabel(machine: *types.Vdbe, label: c_int) void {
    const parse = machine.pParse.?;
    const index = types.labelAddress(label);
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    std.debug.assert(index < -parse.nLabel);
    std.debug.assert(index >= 0);
    if (parse.nLabelAlloc + parse.nLabel < 0) {
        resizeResolveLabel(parse, machine, index);
    } else {
        parse.aLabel.?[@intCast(index)] = machine.nOp;
    }
}

pub fn runOnlyOnce(machine: *types.Vdbe) void {
    _ = addOperation2(machine, .Expire, 1, 1);
}

pub fn reusable(machine: *types.Vdbe) void {
    var index: usize = 1;
    while (index < @as(usize, @intCast(machine.nOp))) : (index += 1) {
        if (machine.aOp.?[index].opcode == .Expire) {
            machine.aOp.?[1].opcode = .Noop;
            break;
        }
    }
}

/// Source `resolveP2Values()`: resolve jump labels and derive reader/write and
/// virtual-table argument metadata by scanning backwards to OP_Init.
pub fn resolveP2Values(machine: *types.Vdbe, maximum_vtab_arguments: *c_int) void {
    var maximum = maximum_vtab_arguments.*;
    const parse = machine.pParse.?;
    const labels = parse.aLabel;
    std.debug.assert(parseDatabase(parse).mallocFailed == 0);
    machine.flags.readOnly = true;
    machine.flags.bIsReader = false;
    var index: usize = @intCast(machine.nOp - 1);
    while (true) : (index -= 1) {
        const operation = &machine.aOp.?[index];
        if (@intFromEnum(operation.opcode) <= canonical_opcode.max_jump_opcode) {
            switch (operation.opcode) {
                .Transaction => {
                    if (operation.p2 != 0) machine.flags.readOnly = false;
                    machine.flags.bIsReader = true;
                },
                .AutoCommit, .Savepoint => machine.flags.bIsReader = true,
                .Checkpoint, .Vacuum, .JournalMode => {
                    machine.flags.readOnly = false;
                    machine.flags.bIsReader = true;
                },
                .Init => {
                    std.debug.assert(operation.p2 >= 0);
                    break;
                },
                .VUpdate => {
                    if (operation.p2 > maximum) maximum = operation.p2;
                },
                .VFilter => {
                    std.debug.assert(index >= 3);
                    const integer = machine.aOp.?[index - 1];
                    std.debug.assert(integer.opcode == .Integer);
                    std.debug.assert(integer.p2 == operation.p3 + 1);
                    if (integer.p1 > maximum) maximum = integer.p1;
                    if (operation.p2 < 0) operation.p2 = labels.?[@intCast(types.labelAddress(operation.p2))];
                    std.debug.assert(operation.p2 > 0);
                    std.debug.assert(operation.p2 < machine.nOp);
                },
                else => {
                    if (operation.p2 < 0) {
                        std.debug.assert(operation.opcode.flags() & canonical_opcode.property.jump != 0);
                        const label_index = types.labelAddress(operation.p2);
                        std.debug.assert(label_index < -parse.nLabel);
                        operation.p2 = labels.?[@intCast(label_index)];
                    }
                    std.debug.assert(operation.p2 > 0 or operation.opcode.flags() & canonical_opcode.property.jump0 != 0);
                    std.debug.assert(operation.p2 < machine.nOp or operation.opcode.flags() & canonical_opcode.property.jump == 0);
                },
            }
            std.debug.assert(operation.opcode.flags() & canonical_opcode.property.jump == 0 or operation.p2 >= 0);
        }
        std.debug.assert(index > 0);
    }
    if (labels) |allocation| {
        db_allocator.freeNN(machine.db.?, @ptrCast(allocation));
        parse.aLabel = null;
    }
    parse.nLabel = 0;
    maximum_vtab_arguments.* = maximum;
    std.debug.assert(machine.flags.bIsReader or machine.btreeMask == 0);
}

const ReusableSpace = struct {
    space: [*]u8,
    free: i64,
    needed: i64,
};

fn round8(value: i64) i64 {
    return (value + 7) & ~@as(i64, 7);
}

fn allocateReusable(space: *ReusableSpace, existing: ?*anyopaque, byte_count: i64) ?*anyopaque {
    if (existing) |allocation| return allocation;
    const aligned = round8(byte_count);
    if (aligned <= space.free) {
        space.free -= aligned;
        return @ptrCast(space.space + @as(usize, @intCast(space.free)));
    }
    space.needed += aligned;
    return null;
}

fn initializeMemArray(memory: ?[*]types.Mem, count: c_int, db: *types.Sqlite3, flags: u16) void {
    if (count <= 0) return;
    const cells = memory.?;
    for (0..@intCast(count)) |index| {
        cells[index].flags = flags;
        cells[index].db = db;
        cells[index].szMalloc = 0;
    }
}

/// Source `sqlite3VdbeMakeReady()`: consume Parse sizing metadata, reuse the
/// opcode-allocation tail, allocate any deficit, initialize VM arrays, and
/// transition to READY state.
pub fn makeReady(machine: *types.Vdbe, parse: *types.Parse) void {
    std.debug.assert(machine.nOp > 0);
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    std.debug.assert(machine.pParse == parse);
    std.debug.assert(parseDatabase(parse) == machine.db.?);
    machine.pVList = if (parse.pVList) |list| @ptrCast(list) else null;
    parse.pVList = null;
    const db = machine.db.?;
    std.debug.assert(db.mallocFailed == 0);
    const variable_count: c_int = parse.nVar;
    var memory_count = parse.nMem + parse.nTab;
    const cursor_count = parse.nTab;
    var argument_count = parse.nMaxArg;
    if (cursor_count == 0 and memory_count > 0) memory_count += 1;

    const operation_bytes = round8(@as(i64, @sizeOf(types.VdbeOp)) * machine.nOp);
    var bulk = ReusableSpace{
        .space = @as([*]u8, @ptrCast(machine.aOp.?)) + @as(usize, @intCast(operation_bytes)),
        .free = (@as(i64, parse.szOpAlloc) - operation_bytes) & ~@as(i64, 7),
        .needed = 0,
    };
    std.debug.assert(bulk.free >= 0);

    resolveP2Values(machine, &argument_count);
    machine.flags.usesStmtJournal = parse.isMultiWrite != 0 and parse.flags0 & 0x02 != 0;
    if (parse.explain != 0) {
        if (memory_count < 10) memory_count = 10;
        machine.flags.explain = @intCast(parse.explain);
        machine.nResColumn = @intCast(12 - 4 * @as(c_int, parse.explain));
    }
    machine.flags.expired = 0;

    machine.aMem = if (allocateReusable(&bulk, null, @as(i64, memory_count) * @sizeOf(types.Mem))) |raw| @ptrCast(@alignCast(raw)) else null;
    machine.aVar = if (allocateReusable(&bulk, null, @as(i64, variable_count) * @sizeOf(types.Mem))) |raw| @ptrCast(@alignCast(raw)) else null;
    machine.apArg = if (allocateReusable(&bulk, null, @as(i64, argument_count) * @sizeOf(?*types.Mem))) |raw| @ptrCast(@alignCast(raw)) else null;
    machine.apCsr = if (allocateReusable(&bulk, null, @as(i64, cursor_count) * @sizeOf(?*types.VdbeCursor))) |raw| @ptrCast(@alignCast(raw)) else null;
    if (bulk.needed != 0) {
        const allocation = db_allocator.mallocRawNN(db, @intCast(bulk.needed));
        machine.pFree = allocation;
        if (db.mallocFailed == 0) {
            bulk.space = @ptrCast(allocation.?);
            bulk.free = bulk.needed;
            machine.aMem = if (allocateReusable(&bulk, if (machine.aMem) |p| @ptrCast(p) else null, @as(i64, memory_count) * @sizeOf(types.Mem))) |raw| @ptrCast(@alignCast(raw)) else null;
            machine.aVar = if (allocateReusable(&bulk, if (machine.aVar) |p| @ptrCast(p) else null, @as(i64, variable_count) * @sizeOf(types.Mem))) |raw| @ptrCast(@alignCast(raw)) else null;
            machine.apArg = if (allocateReusable(&bulk, if (machine.apArg) |p| @ptrCast(p) else null, @as(i64, argument_count) * @sizeOf(?*types.Mem))) |raw| @ptrCast(@alignCast(raw)) else null;
            machine.apCsr = if (allocateReusable(&bulk, if (machine.apCsr) |p| @ptrCast(p) else null, @as(i64, cursor_count) * @sizeOf(?*types.VdbeCursor))) |raw| @ptrCast(@alignCast(raw)) else null;
        }
    }

    if (db.mallocFailed != 0) {
        machine.nVar = 0;
        machine.nCursor = 0;
        machine.nMem = 0;
    } else {
        machine.nCursor = cursor_count;
        machine.nVar = @intCast(variable_count);
        initializeMemArray(machine.aVar, variable_count, db, types.mem_flag.null_);
        machine.nMem = memory_count;
        initializeMemArray(machine.aMem, memory_count, db, types.mem_flag.undefined_);
        if (cursor_count > 0) @memset(machine.apCsr.?[0..@intCast(cursor_count)], null);
    }
    rewind(machine);
}

pub fn setChanges(db: *types.Sqlite3, change_count: i64) void {
    db.nChange = change_count;
    db.nTotalChange += change_count;
}

pub fn countChanges(machine: *types.Vdbe) void {
    machine.flags.changeCntOn = true;
}

pub fn expirePreparedStatements(db: *types.Sqlite3, code: c_int) void {
    var machine = db.pVdbe;
    while (machine) |current| : (machine = current.pVNext) {
        current.flags.expired = @intCast(code + 1);
    }
}

pub fn database(machine: *types.Vdbe) ?*types.Sqlite3 {
    return machine.db;
}

pub fn prepareFlags(machine: *const types.Vdbe) u8 {
    return machine.prepFlags;
}

pub fn functionName(context: *const types.Context) ?[*:0]const u8 {
    return context.pFunc.?.zName;
}

pub fn parser(machine: *types.Vdbe) ?*types.Parse {
    return machine.pParse;
}

/// Source `sqlite3VdbeSwap()`: exchange recompiled bytecode while retaining
/// handle linkage and SQL identity, then publish reprepare metadata on B.
pub fn swap(machine_a: *types.Vdbe, machine_b: *types.Vdbe) void {
    std.debug.assert(machine_a.db == machine_b.db);
    const temporary = machine_a.*;
    machine_a.* = machine_b.*;
    machine_b.* = temporary;
    std.mem.swap(?*types.Vdbe, &machine_a.pVNext, &machine_b.pVNext);
    std.mem.swap(?*?*types.Vdbe, &machine_a.ppVPrev, &machine_b.ppVPrev);
    std.mem.swap(?[*:0]u8, &machine_a.zSql, &machine_b.zSql);
    machine_b.expmask = machine_a.expmask;
    machine_b.prepFlags = machine_a.prepFlags;
    machine_b.aCounter = machine_a.aCounter;
    machine_b.aCounter[types.statement_status_reprepare] += 1;
}

pub fn setSql(machine_optional: ?*types.Vdbe, sql: [*]const u8, length: c_int, prepare_flags: u8) void {
    const machine = machine_optional orelse return;
    machine.prepFlags = prepare_flags;
    if (prepare_flags & types.prepare_save_sql == 0) machine.expmask = 0;
    machine.zSql = db_allocator.stringNDuplicate(machine.db.?, sql, @intCast(length));
}

var dummy_operation = std.mem.zeroes(types.VdbeOp);

/// Source `sqlite3VdbeAddOpList()`: append a generated compact operation
/// list and relocate positive jump P2 operands by the insertion base.
pub fn addOperationList(machine: *types.Vdbe, count: c_int, compact: [*]const types.VdbeOpList, source_line: c_int) ?[*]types.VdbeOp {
    _ = source_line;
    std.debug.assert(count > 0);
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    if (machine.nOp + count > machine.nOpAlloc and growOperationArray(machine, count) != types.result_ok) return null;
    const base = machine.nOp;
    const first = machine.aOp.? + @as(usize, @intCast(base));
    for (0..@intCast(count)) |index| {
        const input = compact[index];
        const output = &first[index];
        output.opcode = input.opcode;
        output.p1 = input.p1;
        output.p2 = input.p2;
        std.debug.assert(input.p2 >= 0);
        if (input.opcode.flags() & canonical_opcode.property.jump != 0 and input.p2 > 0) output.p2 += base;
        output.p3 = input.p3;
        output.p4type = types.p4.not_used;
        output.p4.p = null;
        output.p5 = 0;
    }
    machine.nOp += count;
    return first;
}

/// Source `sqlite3VdbeTakeOpArray()`: finalize and transfer the operation
/// allocation out of its builder Vdbe without copying.
pub fn takeOperationArray(machine: *types.Vdbe, operation_count: *c_int, maximum_arguments: *c_int) [*]types.VdbeOp {
    const operations = machine.aOp.?;
    std.debug.assert(machine.db.?.mallocFailed == 0);
    std.debug.assert(machine.btreeMask == 0);
    resolveP2Values(machine, maximum_arguments);
    operation_count.* = machine.nOp;
    machine.aOp = null;
    return operations;
}

pub fn currentAddress(machine: *const types.Vdbe) c_int {
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    return machine.nOp;
}

pub fn getOperation(machine: *types.Vdbe, address: c_int) *types.VdbeOp {
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    std.debug.assert((address >= 0 and address < machine.nOp) or machine.db.?.mallocFailed != 0);
    if (machine.db.?.mallocFailed != 0) return &dummy_operation;
    return &machine.aOp.?[@intCast(address)];
}

pub fn getLastOperation(machine: *types.Vdbe) *types.VdbeOp {
    return getOperation(machine, machine.nOp - 1);
}

pub fn changeOpcode(machine: *types.Vdbe, address: c_int, opcode: canonical_opcode.Opcode) void {
    std.debug.assert(address >= 0);
    getOperation(machine, address).opcode = opcode;
}

pub fn changeP1(machine: *types.Vdbe, address: c_int, value: c_int) void {
    std.debug.assert(address >= 0);
    getOperation(machine, address).p1 = value;
}

pub fn changeP2(machine: *types.Vdbe, address: c_int, value: c_int) void {
    std.debug.assert(address >= 0 or machine.db.?.mallocFailed != 0);
    getOperation(machine, address).p2 = value;
}

pub fn changeP3(machine: *types.Vdbe, address: c_int, value: c_int) void {
    std.debug.assert(address >= 0);
    getOperation(machine, address).p3 = value;
}

pub fn changeP5(machine: *types.Vdbe, value: u16) void {
    std.debug.assert(machine.nOp > 0 or machine.db.?.mallocFailed != 0);
    if (machine.nOp > 0) machine.aOp.?[@intCast(machine.nOp - 1)].p5 = value;
}

pub fn typeofColumn(machine: *types.Vdbe, destination: c_int) void {
    const operation = getLastOperation(machine);
    if (operation.p3 == destination and operation.opcode == .Column) {
        operation.p5 |= types.op_flag_typeof_argument;
    }
}

pub fn jumpHere(machine: *types.Vdbe, address: c_int) void {
    changeP2(machine, address, machine.nOp);
}

pub fn jumpHereOrPopInstruction(machine: *types.Vdbe, address: c_int) void {
    if (address == machine.nOp - 1) {
        const operation = machine.aOp.?[@intCast(address)];
        std.debug.assert(operation.opcode == .Once or operation.opcode == .If or operation.opcode == .FkIfZero);
        std.debug.assert(operation.p4type == types.p4.not_used);
        machine.nOp -= 1;
    } else {
        changeP2(machine, address, machine.nOp);
    }
}

/// Source virtual-table reference owners used by P4_VTAB.
pub fn vtabModuleUnref(db: *types.Sqlite3, module: *types.Module) void {
    std.debug.assert(module.nRefModule > 0);
    module.nRefModule -= 1;
    if (module.nRefModule == 0) {
        if (module.xDestroy) |destroy| destroy(module.pAux);
        std.debug.assert(module.pEpoTab == null);
        db_allocator.freeNN(db, @ptrCast(module));
    }
}

pub fn vtabLock(table: *types.VTable) void {
    table.nRef += 1;
}

pub fn vtabUnlock(table: *types.VTable) void {
    const db = table.db.?;
    std.debug.assert(table.nRef > 0);
    std.debug.assert(db.eOpenState == types.connection_state_open or db.eOpenState == types.connection_state_zombie);
    table.nRef -= 1;
    if (table.nRef == 0) {
        if (table.pVtab) |public_table| {
            const disconnect = public_table.pModule.?.xDisconnect.?;
            _ = disconnect(public_table);
        }
        vtabModuleUnref(db, table.pMod.?);
        db_allocator.freeNN(db, @ptrCast(table));
    }
}

/// Source P4 leaf-owner cleanup helpers.
pub fn freeEphemeralFunction(db: *types.Sqlite3, function: *types.FuncDef) void {
    if (function.funcFlags & types.function_flag_ephemeral != 0) db_allocator.freeNN(db, @ptrCast(function));
}

pub fn freeP4Mem(db: *types.Sqlite3, value: *types.Mem) void {
    if (value.szMalloc != 0) {
        if (value.zMalloc) |allocation| db_allocator.freeNN(db, @ptrCast(allocation));
    }
    db_allocator.freeNN(db, @ptrCast(value));
}

pub fn freeP4FunctionContext(db: *types.Sqlite3, context: *types.Context) void {
    freeEphemeralFunction(db, context.pFunc.?);
    db_allocator.freeNN(db, @ptrCast(context));
}

/// Source `freeP4()` owner dispatch for the selected profile.
pub fn freeP4(db: *types.Sqlite3, owner_type: i8, owner: ?*anyopaque) void {
    switch (owner_type) {
        types.p4.funcctx => freeP4FunctionContext(db, @ptrCast(@alignCast(owner.?))),
        types.p4.real, types.p4.int64, types.p4.dynamic, types.p4.intarray => db_allocator.free(db, owner),
        types.p4.keyinfo => if (db.pnBytesFreed == null) keyInfoUnref(if (owner) |value| @ptrCast(@alignCast(value)) else null),
        types.p4.funcdef => if (owner) |value| freeEphemeralFunction(db, @ptrCast(@alignCast(value))),
        types.p4.mem => if (db.pnBytesFreed == null)
            vdbe_mem.valueFree(if (owner) |value| @ptrCast(@alignCast(value)) else null)
        else if (owner) |value|
            freeP4Mem(db, @ptrCast(@alignCast(value))),
        types.p4.vtab => if (db.pnBytesFreed == null) {
            if (owner) |value| vtabUnlock(@ptrCast(@alignCast(value)));
        },
        types.p4.table_ref => if (db.pnBytesFreed == null) {
            compiler_ownership.deleteTable(db, if (owner) |value| @ptrCast(@alignCast(value)) else null);
        },
        types.p4.subroutine_signature => if (owner) |value| {
            const signature: *types.SubrtnSig = @ptrCast(@alignCast(value));
            db_allocator.free(db, if (signature.zAff) |affinity| @ptrCast(affinity) else null);
            db_allocator.freeNN(db, @ptrCast(signature));
        },
        else => {},
    }
}

/// Source `vdbeFreeOpArray()`: release owned P4 values in reverse order,
/// then release the operation array.
pub fn freeOperationArray(db: *types.Sqlite3, operations: ?[*]types.VdbeOp, operation_count: c_int) void {
    std.debug.assert(operation_count >= 0);
    const owned = operations orelse return;
    std.debug.assert(operation_count > 0);
    var index: usize = @intCast(operation_count);
    while (index != 0) {
        index -= 1;
        const operation = &owned[index];
        if (operation.p4type <= types.p4.free_if_le) freeP4(db, operation.p4type, operation.p4.p);
    }
    db_allocator.freeNN(db, @ptrCast(owned));
}

fn operationForP4Change(machine: *types.Vdbe, address_argument: c_int) *types.VdbeOp {
    std.debug.assert(machine.nOp > 0 and address_argument < machine.nOp);
    const address = if (address_argument < 0) machine.nOp - 1 else address_argument;
    return &machine.aOp.?[@intCast(address)];
}

fn clearReplaceableP4(operation: *types.VdbeOp) void {
    if (operation.p4type == types.p4.not_used) return;
    std.debug.assert(operation.p4type > types.p4.free_if_le);
    operation.p4type = types.p4.not_used;
    operation.p4.p = null;
}

pub fn changeP4(machine: *types.Vdbe, address_argument: c_int, owner: ?*anyopaque, owner_type: i8) void {
    const db = machine.db.?;
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    std.debug.assert(machine.aOp != null or db.mallocFailed != 0);
    std.debug.assert(owner_type < 0 and owner_type != types.p4.int32);
    if (db.mallocFailed != 0) {
        if (owner_type != types.p4.vtab) freeP4(db, owner_type, owner);
        return;
    }
    const operation = operationForP4Change(machine, address_argument);
    clearReplaceableP4(operation);
    if (owner) |value| {
        operation.p4.p = value;
        operation.p4type = owner_type;
        if (owner_type == types.p4.vtab) vtabLock(@ptrCast(@alignCast(value)));
    }
}

pub fn changeP4Int32(machine: *types.Vdbe, address_argument: c_int, value: c_int) void {
    const db = machine.db.?;
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    std.debug.assert(machine.aOp != null or db.mallocFailed != 0);
    if (db.mallocFailed != 0) return;
    const operation = operationForP4Change(machine, address_argument);
    clearReplaceableP4(operation);
    operation.p4.i = value;
    operation.p4type = types.p4.int32;
}

pub fn changeP4String(machine: *types.Vdbe, address_argument: c_int, source: [*]const u8, length_argument: c_int) void {
    const db = machine.db.?;
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init);
    std.debug.assert(machine.aOp != null or db.mallocFailed != 0);
    std.debug.assert(length_argument >= 0);
    if (db.mallocFailed != 0) return;
    const operation = operationForP4Change(machine, address_argument);
    clearReplaceableP4(operation);
    const length: usize = if (length_argument == 0) std.mem.len(@as([*:0]const u8, @ptrCast(source))) else @intCast(length_argument);
    operation.p4.z = db_allocator.stringNDuplicate(db, source, length);
    operation.p4type = types.p4.dynamic;
}

pub fn appendP4(machine: *types.Vdbe, owner: ?*anyopaque, owner_type: i8) void {
    std.debug.assert(owner_type != types.p4.int32 and owner_type != types.p4.vtab and owner_type <= 0);
    if (machine.db.?.mallocFailed != 0) {
        freeP4(machine.db.?, owner_type, owner);
        return;
    }
    std.debug.assert(owner != null or owner_type == types.p4.dynamic);
    std.debug.assert(machine.nOp > 0);
    const operation = &machine.aOp.?[@intCast(machine.nOp - 1)];
    std.debug.assert(operation.p4type == types.p4.not_used);
    operation.p4type = owner_type;
    operation.p4.p = owner;
}

pub fn changeToNoop(machine: *types.Vdbe, address: c_int) c_int {
    const db = machine.db.?;
    if (db.mallocFailed != 0) return 0;
    std.debug.assert(address >= 0 and address < machine.nOp);
    const operation = &machine.aOp.?[@intCast(address)];
    freeP4(db, operation.p4type, operation.p4.p);
    operation.p4type = types.p4.not_used;
    operation.p4.z = null;
    operation.opcode = .Noop;
    return 1;
}

pub fn deletePriorOpcode(machine: *types.Vdbe, opcode: canonical_opcode.Opcode) c_int {
    if (machine.nOp > 0 and machine.aOp.?[@intCast(machine.nOp - 1)].opcode == opcode) {
        return changeToNoop(machine, machine.nOp - 1);
    }
    return 0;
}

pub fn clearVdbeObject(db: *types.Sqlite3, machine: *types.Vdbe) void {
    std.debug.assert(machine.db == null or machine.db == db);
    if (machine.aColName) |column_names| {
        vdbe_mem.releaseArray(column_names, @intCast(@as(usize, machine.nResAlloc) * types.column_name.count));
        db_allocator.freeNN(db, @ptrCast(column_names));
    }
    var subprogram = machine.pProgram;
    while (subprogram) |program| {
        const next = program.pNext;
        freeOperationArray(db, program.aOp, program.nOp);
        db_allocator.free(db, @ptrCast(program));
        subprogram = next;
    }
    if (machine.eVdbeState != types.vdbe_state.init) {
        vdbe_mem.releaseArray(machine.aVar, machine.nVar);
        if (machine.pVList) |variables| db_allocator.freeNN(db, @ptrCast(variables));
        if (machine.pFree) |bulk| db_allocator.freeNN(db, bulk);
    }
    freeOperationArray(db, machine.aOp, machine.nOp);
    if (machine.zSql) |sql| db_allocator.freeNN(db, @ptrCast(sql));
}

pub fn deleteVdbe(machine: *types.Vdbe) void {
    const db = machine.db.?;
    clearVdbeObject(db, machine);
    if (db.pnBytesFreed == null) {
        const previous_link = machine.ppVPrev.?;
        previous_link.* = machine.pVNext;
        if (machine.pVNext) |next| next.ppVPrev = previous_link;
    }
    db_allocator.freeNN(db, @ptrCast(machine));
}

test "source Parse object initialization preserves recursive middle state" {
    var outer = std.mem.zeroes(types.Parse);
    var parse: types.Parse = undefined;
    @memset(@as([*]u8, @ptrCast(&parse))[0..@sizeOf(types.Parse)], 0xa5);
    parse.aTempReg[0] = 42;
    parse.oldmask = 0x1234;
    var db = std.mem.zeroes(types.Sqlite3);
    db.pParse = &outer;
    initializeParseObject(&parse, &db);
    try std.testing.expect(db.pParse == &parse);
    try std.testing.expect(parse.pOuterParse == &outer);
    try std.testing.expectEqual(@intFromPtr(&db), @intFromPtr(parse.db.?));
    try std.testing.expectEqual(@as(c_int, 0), parse.nErr);
    try std.testing.expectEqual(@as(u32, 0), parse.sLastToken.n);
    try std.testing.expectEqual(@as(c_int, 42), parse.aTempReg[0]);
    try std.testing.expectEqual(@as(u32, 0x1234), parse.oldmask);

    db.pParse = &outer;
    db.mallocFailed = 1;
    initializeParseObject(&parse, &db);
    try std.testing.expectEqual(@as(c_int, 1), parse.nErr);
    try std.testing.expectEqual(types.result_error, parse.rc);
    try std.testing.expectEqual(@as(c_int, -1), db.errByteOffset);
}

test "source Parse object reset restores lookaside and outer owner" {
    var outer = std.mem.zeroes(types.Parse);
    var parse = std.mem.zeroes(types.Parse);
    var db = std.mem.zeroes(types.Sqlite3);
    db.pParse = &parse;
    db.lookaside.bDisable = 3;
    db.lookaside.sz = 0;
    db.lookaside.szTrue = 1200;
    parse.db = @ptrCast(&db);
    parse.pOuterParse = &outer;
    parse.disableLookaside = 2;

    resetParseObject(&parse);

    try std.testing.expect(db.pParse == &outer);
    try std.testing.expectEqual(@as(u32, 1), db.lookaside.bDisable);
    try std.testing.expectEqual(@as(u16, 0), db.lookaside.sz);

    db.pParse = &parse;
    db.lookaside.bDisable = 2;
    parse.disableLookaside = 2;
    resetParseObject(&parse);
    try std.testing.expectEqual(@as(u32, 0), db.lookaside.bDisable);
    try std.testing.expectEqual(@as(u16, 1200), db.lookaside.sz);
}

test "freeP4 nullable selected owner families" {
    var db = std.mem.zeroes(types.Sqlite3);
    freeP4(&db, types.p4.dynamic, null);
    freeP4(&db, types.p4.keyinfo, null);
    freeP4(&db, types.p4.funcdef, null);
    freeP4(&db, types.p4.mem, null);
    freeP4(&db, types.p4.vtab, null);
    freeP4(&db, types.p4.table_ref, null);
    freeP4(&db, types.p4.subroutine_signature, null);
}

/// Source `sqlite3KeyInfoUnref()` and `sqlite3KeyInfoRef()` reference owner.
pub fn keyInfoUnref(key_info_optional: ?*types.KeyInfo) void {
    const key_info = key_info_optional orelse return;
    std.debug.assert(key_info.db != null);
    std.debug.assert(key_info.nRef > 0);
    key_info.nRef -= 1;
    if (key_info.nRef == 0) db_allocator.freeNN(key_info.db, @ptrCast(key_info));
}

pub fn keyInfoRef(key_info_optional: ?*types.KeyInfo) ?*types.KeyInfo {
    const key_info = key_info_optional orelse return null;
    std.debug.assert(key_info.nRef > 0);
    key_info.nRef += 1;
    return key_info;
}

pub fn linkSubProgram(machine: *types.Vdbe, program: *types.SubProgram) void {
    program.pNext = machine.pProgram;
    machine.pProgram = program;
}

pub fn hasSubProgram(machine: *const types.Vdbe) bool {
    return machine.pProgram != null;
}

pub fn frameMemDelete(argument: ?*anyopaque) callconv(.c) void {
    const frame: *types.VdbeFrame = @ptrCast(@alignCast(argument.?));
    const machine = frame.v.?;
    frame.pParent = machine.pDelFrame;
    machine.pDelFrame = frame;
}

/// Source `sqlite3VdbeRewind()`: establish first-execution state.
pub fn rewind(machine: *types.Vdbe) void {
    std.debug.assert(machine.eVdbeState == types.vdbe_state.init or machine.eVdbeState == types.vdbe_state.ready or machine.eVdbeState == types.vdbe_state.halt);
    std.debug.assert(machine.nOp > 0);
    machine.eVdbeState = types.vdbe_state.ready;
    machine.pc = -1;
    machine.rc = types.result_ok;
    machine.errorAction = types.conflict_abort;
    machine.nChange = 0;
    machine.cacheCtr = 1;
    machine.minWriteFileFormat = 255;
    machine.iStatement = 0;
    machine.nFkConstraint = 0;
}

pub fn resetStepResult(machine: *types.Vdbe) void {
    machine.rc = types.result_ok;
}

pub const TableMovetoFunction = *const fn (*types.BtCursor, i64, c_int, *c_int) c_int;

/// Source `sqlite3VdbeFinishMoveto()`: resolve a deferred exact table-rowid
/// seek, reject a missing target as corruption, and invalidate the row cache.
pub fn finishMovedCursor(cursor: *types.VdbeCursor, table_moveto: TableMovetoFunction) c_int {
    std.debug.assert(cursor.deferredMoveto != 0);
    std.debug.assert(cursor.isTable != 0);
    std.debug.assert(cursor.eCurType == types.cursor_type.btree);
    var seek_result: c_int = 0;
    const result = table_moveto(cursor.uc.pCursor.?, cursor.movetoTarget, 0, &seek_result);
    if (result != 0) {
        return result;
    }
    if (seek_result != 0) {
        return result_corrupt;
    }
    cursor.deferredMoveto = 0;
    cursor.cacheStatus = types.cache_stale;
    return types.result_ok;
}

fn testTableMoveto(_: *types.BtCursor, target: i64, _: c_int, seek_result: *c_int) c_int {
    if (target < 0) {
        return 10;
    }
    seek_result.* = if (target == 0) 1 else 0;
    return 0;
}

test "source deferred table moveto preserves errors corruption and success state" {
    var opaque_cursor: usize = 0;
    var cursor = std.mem.zeroes(types.VdbeCursor);
    cursor.eCurType = types.cursor_type.btree;
    cursor.isTable = 1;
    cursor.deferredMoveto = 1;
    cursor.uc.pCursor = @ptrCast(&opaque_cursor);
    cursor.cacheStatus = 42;

    cursor.movetoTarget = -1;
    try std.testing.expectEqual(@as(c_int, 10), finishMovedCursor(&cursor, testTableMoveto));
    try std.testing.expectEqual(@as(u8, 1), cursor.deferredMoveto);
    try std.testing.expectEqual(@as(u32, 42), cursor.cacheStatus);

    cursor.movetoTarget = 0;
    try std.testing.expectEqual(result_corrupt, finishMovedCursor(&cursor, testTableMoveto));
    try std.testing.expectEqual(@as(u8, 1), cursor.deferredMoveto);

    cursor.movetoTarget = 7;
    try std.testing.expectEqual(types.result_ok, finishMovedCursor(&cursor, testTableMoveto));
    try std.testing.expectEqual(@as(u8, 0), cursor.deferredMoveto);
    try std.testing.expectEqual(types.cache_stale, cursor.cacheStatus);
}

pub const CursorRestoreFunction = *const fn (*types.BtCursor, *c_int) c_int;

/// Source `sqlite3VdbeHandleMovedCursor()`: restore a moved B-tree cursor,
/// invalidate its row cache, and publish a null row if restoration moved to a
/// different record.
pub fn handleMovedCursor(cursor: *types.VdbeCursor, restore: CursorRestoreFunction) c_int {
    std.debug.assert(cursor.eCurType == types.cursor_type.btree);
    const btree_cursor = cursor.uc.pCursor.?;
    var different_row: c_int = 0;
    const result = restore(btree_cursor, &different_row);
    cursor.cacheStatus = types.cache_stale;
    if (different_row != 0) {
        cursor.nullRow = 1;
    }
    return result;
}

fn testRestoreMovedCursor(_: *types.BtCursor, different_row: *c_int) c_int {
    different_row.* = 1;
    return 10;
}

test "source moved cursor restoration invalidates cache and nulls changed row" {
    var opaque_cursor: usize = 0;
    var cursor = std.mem.zeroes(types.VdbeCursor);
    cursor.eCurType = types.cursor_type.btree;
    cursor.uc.pCursor = @ptrCast(&opaque_cursor);
    cursor.cacheStatus = 42;

    try std.testing.expectEqual(@as(c_int, 10), handleMovedCursor(&cursor, testRestoreMovedCursor));
    try std.testing.expectEqual(types.cache_stale, cursor.cacheStatus);
    try std.testing.expectEqual(@as(u8, 1), cursor.nullRow);
}

pub fn transferError(machine: *types.Vdbe) c_int {
    const db = machine.db.?;
    const result = machine.rc;
    if (machine.zErrMsg) |message| {
        db.bBenignMalloc += 1;
        if (db.pErr == null) db.pErr = vdbe_mem.valueNew(db);
        vdbe_mem.valueSetStr(db.pErr, -1, message, 1, .transient);
        db.bBenignMalloc -= 1;
    } else if (db.pErr) |error_value| {
        vdbe_mem.setNull(error_value);
    }
    db.errCode = result;
    db.errByteOffset = -1;
    return result;
}

pub fn setColumnCount(machine: *types.Vdbe, result_columns: c_int) void {
    const db = machine.db.?;
    if (machine.nResAlloc != 0) {
        vdbe_mem.releaseArray(machine.aColName, @as(c_int, machine.nResAlloc) * @as(c_int, @intCast(types.column_name.count)));
        db_allocator.free(db, machine.aColName);
    }
    const cell_count = result_columns * @as(c_int, @intCast(types.column_name.count));
    machine.nResColumn = @intCast(result_columns);
    machine.nResAlloc = @intCast(result_columns);
    const raw = db_allocator.mallocRawNN(db, @as(u64, @intCast(cell_count)) * @sizeOf(types.Mem)) orelse {
        machine.aColName = null;
        return;
    };
    machine.aColName = @ptrCast(@alignCast(raw));
    vdbe_mem.initArray(machine.aColName.?, cell_count, db, types.mem_flag.null_);
}

pub fn setColumnName(machine: *types.Vdbe, index: c_int, variant: usize, name: ?[*]const u8, ownership: vdbe_mem.StringOwnership) c_int {
    std.debug.assert(index < machine.nResAlloc);
    std.debug.assert(variant < types.column_name.count);
    if (machine.db.?.mallocFailed != 0) return types.result_no_memory;
    const cell = &machine.aColName.?[@intCast(index + @as(c_int, @intCast(variant)) * machine.nResAlloc)];
    return vdbe_mem.setText(cell, name, -1, ownership);
}

pub fn getBoundValue(machine_optional: ?*types.Vdbe, variable: c_int, affinity: u8) ?*types.Mem {
    std.debug.assert(variable > 0);
    const machine = machine_optional orelse return null;
    const source = &machine.aVar.?[@intCast(variable - 1)];
    if (source.flags & types.mem_flag.null_ != 0) return null;
    const result = vdbe_mem.valueNew(machine.db) orelse return null;
    _ = vdbe_mem.copy(result, source);
    vdbe_mem.valueApplyAffinity(result, affinity, 1);
    return result;
}

pub fn setVariableMask(machine: *types.Vdbe, variable: c_int) void {
    std.debug.assert(variable > 0);
    if (variable >= 32) {
        machine.expmask |= 0x8000_0000;
    } else {
        machine.expmask |= @as(u32, 1) << @intCast(variable - 1);
    }
}

/// Source `sqlite3VtabImportErrmsg()`: move a global-allocator virtual-table
/// error through a connection-owned duplicate and clear both prior owners.
pub fn importVtabError(machine: *types.Vdbe, public_table: *types.PublicVtab) void {
    const message = public_table.zErrMsg orelse return;
    const db = machine.db.?;
    db_allocator.free(db, if (machine.zErrMsg) |old| @ptrCast(old) else null);
    machine.zErrMsg = db_allocator.stringDuplicate(db, message);
    global_memory.processManager().free(@ptrCast(message));
    public_table.zErrMsg = null;
}

/// Source `sqlite3VdbeUsesBtree()`: record database use and shared-cache lock
/// requirements, excluding the TEMP database from the lock mask.
pub fn usesBtree(machine: *types.Vdbe, database_index: c_int) void {
    const db = machine.db.?;
    std.debug.assert(database_index >= 0 and database_index < db.nDb);
    std.debug.assert(database_index < @bitSizeOf(types.DbMask));
    machine.btreeMask |= @as(types.DbMask, 1) << @intCast(database_index);
    if (database_index != 1 and btree_aux.sharable(db.aDb.?[@intCast(database_index)].pBt.?) != 0) {
        machine.lockMask |= @as(types.DbMask, 1) << @intCast(database_index);
    }
}

fn foreignKeyError(machine: *types.Vdbe) c_int {
    machine.rc = types.result_constraint_foreign_key;
    machine.errorAction = types.conflict_abort;
    const db = machine.db.?;
    db_allocator.free(db, if (machine.zErrMsg) |message| @ptrCast(message) else null);
    machine.zErrMsg = db_allocator.stringDuplicate(db, "FOREIGN KEY constraint failed");
    if (machine.prepFlags & types.prepare_save_sql == 0) return types.result_error;
    return types.result_constraint_foreign_key;
}

/// Source immediate and deferred foreign-key commit guards.
pub fn checkForeignKeyImmediate(machine: *types.Vdbe) c_int {
    if (machine.nFkConstraint == 0) return types.result_ok;
    return foreignKeyError(machine);
}

pub fn checkForeignKeyDeferred(machine: *types.Vdbe) c_int {
    const db = machine.db.?;
    if (db.nDeferredCons + db.nDeferredImmCons == 0) return types.result_ok;
    return foreignKeyError(machine);
}

fn testBuilder(db: *types.Sqlite3, parse: *types.Parse) types.Vdbe {
    db.* = std.mem.zeroes(types.Sqlite3);
    db.aLimit[limit_vdbe_op] = 250_000_000;
    parse.* = std.mem.zeroes(types.Parse);
    parse.db = @ptrCast(db);
    var machine = std.mem.zeroes(types.Vdbe);
    machine.db = db;
    machine.pParse = parse;
    machine.eVdbeState = types.vdbe_state.init;
    return machine;
}

fn freeTestOperations(machine: *types.Vdbe) void {
    if (machine.aOp) |operations| db_allocator.freeNN(machine.db, @ptrCast(operations));
    machine.aOp = null;
    machine.nOp = 0;
    machine.nOpAlloc = 0;
}

test "VDBE operation append preserves source growth and operand initialization" {
    var db: types.Sqlite3 = undefined;
    var parse: types.Parse = undefined;
    var machine = testBuilder(&db, &parse);
    defer freeTestOperations(&machine);

    try std.testing.expectEqual(@as(c_int, 0), addOperation0(&machine, .Init));
    try std.testing.expectEqual(@as(c_int, 1), addOperation1(&machine, .Integer, 17));
    try std.testing.expectEqual(@as(c_int, 2), addOperation2(&machine, .Goto, 3, 9));
    try std.testing.expectEqual(@as(c_int, 3), addOperation3(&machine, .Add, 1, 2, 3));
    try std.testing.expectEqual(@as(c_int, 4), addOperation4Int(&machine, .OpenRead, 4, 5, 6, 7));

    try std.testing.expect(machine.nOpAlloc >= machine.nOp);
    try std.testing.expectEqual(@as(c_int, @intCast(db_allocator.allocationSize(&db, @ptrCast(machine.aOp.?)))), parse.szOpAlloc);
    const operations = machine.aOp.?;
    try std.testing.expectEqual(canonical_opcode.Opcode.Init, operations[0].opcode);
    try std.testing.expectEqual(types.p4.not_used, operations[0].p4type);
    try std.testing.expectEqual(@as(c_int, 17), operations[1].p1);
    try std.testing.expectEqual(@as(c_int, 9), operations[2].p2);
    try std.testing.expectEqual(@as(c_int, 3), operations[3].p3);
    try std.testing.expectEqual(types.p4.int32, operations[4].p4type);
    try std.testing.expectEqual(@as(c_int, 7), operations[4].p4.i);
    for (operations[0..5]) |operation| try std.testing.expectEqual(@as(u16, 0), operation.p5);
}

test "VDBE operation limit failure preserves the existing array" {
    var db: types.Sqlite3 = undefined;
    var parse: types.Parse = undefined;
    var machine = testBuilder(&db, &parse);
    db.aLimit[limit_vdbe_op] = 0;

    try std.testing.expectEqual(@as(c_int, 1), addOperation3(&machine, .Init, 0, 0, 0));
    try std.testing.expectEqual(@as(c_int, 0), machine.nOp);
    try std.testing.expectEqual(@as(c_int, 0), machine.nOpAlloc);
    try std.testing.expect(machine.aOp == null);
    try std.testing.expectEqual(@as(u8, 1), db.mallocFailed);
    try std.testing.expectEqual(@as(u32, 1), db.lookaside.bDisable);
}
