const std = @import("std");
const vdbe_module = @import("vdbe_builder");
const builder = vdbe_module.vdbe_aux;
const api = vdbe_module.vdbe_api;
const btree_aux = vdbe_module.btree_aux;
const vdbe_record = vdbe_module.vdbe_record;
const memory = vdbe_module.memory;
const vdbe_mem = vdbe_module.vdbe_mem;
const types = builder.types;

const ProgressState = struct { result: c_int = 0, calls: usize = 0 };
var vtab_disconnect_calls: c_int = 0;
var module_destroy_calls: c_int = 0;
var bind_destructor_calls: c_int = 0;
var reprepare_calls: c_int = 0;
fn testVtabDisconnect(_: ?*types.PublicVtab) callconv(.c) c_int {
    vtab_disconnect_calls += 1;
    return 0;
}
fn testModuleDestroy(_: ?*anyopaque) callconv(.c) void {
    module_destroy_calls += 1;
}
fn testBindDestructor(_: ?*anyopaque) callconv(.c) void {
    bind_destructor_calls += 1;
}
fn testReprepare(_: *types.Vdbe) c_int {
    reprepare_calls += 1;
    return 0;
}
fn progressCallback(raw: ?*anyopaque) callconv(.c) c_int {
    const state: *ProgressState = @ptrCast(@alignCast(raw.?));
    state.calls += 1;
    return state.result;
}

fn clearCreated(db: *types.Sqlite3) void {
    while (db.pVdbe) |machine| builder.deleteVdbe(machine);
}

fn resetMachine(db: *types.Sqlite3, parse: *types.Parse, machine: *types.Vdbe) void {
    clearCreated(db);
    if (db.mallocFailed != 0) builder.db_allocator.oomClear(db);
    builder.freeOperationArray(db, machine.aOp, machine.nOp);
    if (machine.zErrMsg) |message| builder.db_allocator.freeNN(db, @ptrCast(message));
    if (parse.aLabel) |labels| builder.db_allocator.freeNN(db, @ptrCast(labels));
    db.xProgress = null;
    db.pProgressArg = null;
    db.nProgressOps = 0;
    db.lookaside.bDisable = 0;
    db.lookaside.sz = db.lookaside.szTrue;
    @atomicStore(c_int, &db.u1.isInterrupted, 0, .monotonic);
    parse.* = std.mem.zeroes(types.Parse);
    machine.* = std.mem.zeroes(types.Vdbe);
    parse.db = @ptrCast(db);
    db.pParse = parse;
    machine.db = db;
    machine.pParse = parse;
    machine.eVdbeState = types.vdbe_state.init;
}

fn parseInt(token: []const u8) !c_int {
    return std.fmt.parseInt(c_int, token, 10);
}

fn next(tokens: anytype) ![]const u8 {
    return tokens.next() orelse error.MalformedOperation;
}

fn lookasideContains(db: *types.Sqlite3, pointer: *const anyopaque) bool {
    var slot = db.lookaside.pFree;
    var guard: usize = 0;
    while (slot) |current| : ({
        slot = current.pNext;
        guard += 1;
    }) {
        if (current == @as(*types.LookasideSlot, @ptrCast(@alignCast(@constCast(pointer))))) return true;
        if (guard >= 1000) break;
    }
    slot = db.lookaside.pSmallFree;
    guard = 0;
    while (slot) |current| : ({
        slot = current.pNext;
        guard += 1;
    }) {
        if (current == @as(*types.LookasideSlot, @ptrCast(@alignCast(@constCast(pointer))))) return true;
        if (guard >= 1000) break;
    }
    return false;
}

fn operationCode(name: []const u8) !builder.canonical_opcode.Opcode {
    return std.meta.stringToEnum(builder.canonical_opcode.Opcode, name) orelse error.UnknownOpcode;
}

fn globalString(text: []const u8) ?[*:0]u8 {
    const raw = memory.processManager().alloc(text.len + 1) orelse return null;
    const result: [*:0]u8 = @ptrCast(raw);
    @memcpy(result[0..text.len], text);
    result[text.len] = 0;
    return result;
}

fn observation(case_name: []const u8, sequence: usize, address: c_int, operation_count_before: c_int, machine: *types.Vdbe, parse: *types.Parse) void {
    if (machine.nOp == operation_count_before + 1 and address == operation_count_before) {
        const operation = machine.aOp.?[@intCast(address)];
        const p4_value: c_int = if (operation.p4type == types.p4.int32) operation.p4.i else 0;
        std.debug.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            case_name,
            sequence,
            address,
            machine.nOp,
            machine.nOpAlloc,
            parse.szOpAlloc,
            machine.db.?.mallocFailed,
            parse.nErr,
            parse.rc,
            machine.db.?.errByteOffset,
            @intFromEnum(operation.opcode),
            operation.p1,
            operation.p2,
            operation.p3,
            operation.p5,
            operation.p4type,
            p4_value,
        });
    } else {
        std.debug.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\tNONE\n", .{
            case_name,
            sequence,
            address,
            machine.nOp,
            machine.nOpAlloc,
            parse.szOpAlloc,
            machine.db.?.mallocFailed,
            parse.nErr,
            parse.rc,
            machine.db.?.errByteOffset,
        });
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.Arguments;
    if (args.next() != null) return error.Arguments;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024));
    defer init.gpa.free(input);

    var fault_backend = memory.FaultingBackend{ .inner = memory.systemBackend() };
    try memory.process_manager.configureBackend(fault_backend.backend());
    std.debug.assert(memory.process_manager.start() == memory.ok);
    defer memory.process_manager.stop();

    var db = std.mem.zeroes(types.Sqlite3);
    db.aLimit[0] = 1_000_000_000;
    db.aLimit[5] = 250_000_000;
    db.enc = 1;
    db.errMask = 0xff;
    db.eOpenState = types.connection_state_open;
    db.errByteOffset = -1;
    var lookaside_storage: [4800 + types.lookaside_small]u8 align(8) = undefined;
    const big_slot: *types.LookasideSlot = @ptrCast(@alignCast(&lookaside_storage));
    const second_big_slot: *types.LookasideSlot = @ptrCast(@alignCast(lookaside_storage[0..].ptr + 1200));
    const third_big_slot: *types.LookasideSlot = @ptrCast(@alignCast(lookaside_storage[0..].ptr + 2400));
    const fourth_big_slot: *types.LookasideSlot = @ptrCast(@alignCast(lookaside_storage[0..].ptr + 3600));
    const small_slot: *types.LookasideSlot = @ptrCast(@alignCast(lookaside_storage[0..].ptr + 4800));
    big_slot.pNext = second_big_slot;
    second_big_slot.pNext = third_big_slot;
    third_big_slot.pNext = fourth_big_slot;
    fourth_big_slot.pNext = null;
    small_slot.pNext = null;
    db.lookaside.sz = 1200;
    db.lookaside.szTrue = 1200;
    db.lookaside.nSlot = 5;
    db.lookaside.pInit = big_slot;
    db.lookaside.pSmallInit = small_slot;
    db.lookaside.pMiddle = small_slot;
    db.lookaside.pStart = &lookaside_storage;
    db.lookaside.pEnd = @ptrCast(lookaside_storage[0..].ptr + lookaside_storage.len);
    db.lookaside.pTrueEnd = db.lookaside.pEnd;
    var parse = std.mem.zeroes(types.Parse);
    var create_parse = [_]types.Parse{std.mem.zeroes(types.Parse)} ** 2;
    var machine = std.mem.zeroes(types.Vdbe);
    var detached_operations: ?[*]types.VdbeOp = null;
    var detached_operation_count: c_int = 0;
    var key_info: ?*types.KeyInfo = null;
    var public_vtab = std.mem.zeroes(types.PublicVtab);
    var test_dbs = [_]types.Db{std.mem.zeroes(types.Db)} ** 3;
    var test_btrees = [_]types.Btree{std.mem.zeroes(types.Btree)} ** 3;
    resetMachine(&db, &parse, &machine);
    defer {
        while (key_info) |key| {
            if (key.nRef == 1) key_info = null;
            builder.keyInfoUnref(key);
        }
        if (detached_operations) |operations| builder.db_allocator.freeNN(&db, @ptrCast(operations));
        if (public_vtab.zErrMsg) |message| memory.processManager().free(@ptrCast(message));
        resetMachine(&db, &parse, &machine);
    }

    var case_name: []const u8 = "none";
    var sequence: usize = 0;
    var labels: [256]c_int = undefined;
    var label_count: usize = 0;
    var progress_state = ProgressState{};
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const command = tokens.next() orelse continue;
        if (std.mem.eql(u8, command, "CASE")) {
            while (key_info) |key| {
                if (key.nRef == 1) key_info = null;
                builder.keyInfoUnref(key);
            }
            if (detached_operations) |operations| builder.db_allocator.freeNN(&db, @ptrCast(operations));
            if (public_vtab.zErrMsg) |message| memory.processManager().free(@ptrCast(message));
            public_vtab.zErrMsg = null;
            detached_operations = null;
            detached_operation_count = 0;
            resetMachine(&db, &parse, &machine);
            create_parse = [_]types.Parse{std.mem.zeroes(types.Parse)} ** 2;
            case_name = try next(&tokens);
            sequence = 0;
            label_count = 0;
            progress_state = .{};
            continue;
        }
        if (std.mem.eql(u8, command, "LIMIT")) {
            const limit = try parseInt(try next(&tokens));
            db.aLimit[5] = limit;
            std.debug.print("{s}\t{d}\tLIMIT\t{d}\n", .{ case_name, sequence, limit });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FAILNEXT")) {
            fault_backend.fail_at = fault_backend.attempt_count;
            fault_backend.sticky = false;
            fault_backend.fired = false;
            std.debug.print("{s}\t{d}\tFAILNEXT\n", .{ case_name, sequence });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FAILIN")) {
            const count = try parseInt(try next(&tokens));
            fault_backend.fail_at = fault_backend.attempt_count + @as(usize, @intCast(count - 1));
            fault_backend.sticky = false;
            fault_backend.fired = false;
            std.debug.print("{s}\t{d}\tFAILIN\t{d}\n", .{ case_name, sequence, count });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FAILSTICKY")) {
            fault_backend.fail_at = fault_backend.attempt_count;
            fault_backend.sticky = true;
            fault_backend.fired = false;
            std.debug.print("{s}\t{d}\tFAILSTICKY\n", .{ case_name, sequence });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "CLEARFAULT")) {
            fault_backend.fail_at = null;
            fault_backend.sticky = false;
            fault_backend.fired = false;
            if (db.mallocFailed != 0) builder.db_allocator.oomClear(&db);
            std.debug.print("{s}\t{d}\tCLEARFAULT\n", .{ case_name, sequence });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "LOOKASIDE")) {
            const disabled = try parseInt(try next(&tokens));
            db.lookaside.bDisable = @intCast(disabled);
            db.lookaside.sz = if (disabled != 0) 0 else db.lookaside.szTrue;
            std.debug.print("{s}\t{d}\tLOOKASIDE\t{d}\n", .{ case_name, sequence, disabled });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "CREATE")) {
            const owner_index = try parseInt(try next(&tokens));
            const owner = &create_parse[@intCast(owner_index)];
            owner.db = @ptrCast(&db);
            db.pParse = owner;
            const old_head = db.pVdbe;
            const made = builder.create(owner);
            var has_init: c_int = -1;
            var init_opcode: c_int = -1;
            var init_p1: c_int = -1;
            var init_p2: c_int = -1;
            if (made) |created| {
                if (created.nOp > 0) {
                    has_init = 1;
                    init_opcode = @intFromEnum(created.aOp.?[0].opcode);
                    init_p1 = created.aOp.?[0].p1;
                    init_p2 = created.aOp.?[0].p2;
                } else has_init = 0;
            }
            std.debug.print("{s}\t{d}\tCREATE\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                case_name,
                sequence,
                owner_index,
                @intFromBool(made != null),
                @intFromBool(db.pVdbe == made),
                @intFromBool(if (made) |created| owner.pVdbe != null and @intFromPtr(owner.pVdbe.?) == @intFromPtr(created) else owner.pVdbe == null),
                @intFromBool(if (made) |created| builder.parser(created) == owner else false),
                if (made) |created| created.nOp else -1,
                if (made) |created| created.nOpAlloc else -1,
                has_init,
                init_opcode,
                init_p1,
                init_p2,
                if (made) |created| @as(c_int, created.eVdbeState) else -1,
                @intFromBool(if (made) |created| created.pVNext == old_head else false),
                @intFromBool(if (made) |created| created.ppVPrev == &db.pVdbe else false),
                @intFromBool(if (old_head) |old| if (made) |created| old.ppVPrev == &created.pVNext else false else true),
                db.mallocFailed,
                owner.nErr,
                owner.rc,
            });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "READY")) {
            const owner_index = try parseInt(try next(&tokens));
            const variable_count = try parseInt(try next(&tokens));
            const memory_count = try parseInt(try next(&tokens));
            const cursor_count = try parseInt(try next(&tokens));
            const argument_count = try parseInt(try next(&tokens));
            const multi_write = try parseInt(try next(&tokens));
            const may_abort = try parseInt(try next(&tokens));
            const explain = try parseInt(try next(&tokens));
            const has_list = try parseInt(try next(&tokens));
            const owner = &create_parse[@intCast(owner_index)];
            const made: *types.Vdbe = @ptrCast(@alignCast(owner.pVdbe.?));
            owner.nVar = @intCast(variable_count);
            owner.nMem = memory_count;
            owner.nTab = cursor_count;
            owner.nMaxArg = argument_count;
            owner.isMultiWrite = @intCast(multi_write);
            owner.flags0 = (owner.flags0 & ~@as(u8, 0x02)) | (if (may_abort != 0) @as(u8, 0x02) else 0);
            owner.explain = @intCast(explain);
            if (has_list != 0) owner.pVList = @ptrCast(@alignCast(builder.db_allocator.mallocRawNN(&db, 8).?));
            builder.makeReady(made, owner);
            var cursors_null = true;
            for (0..@intCast(made.nCursor)) |index| {
                if (made.apCsr.?[index] != null) cursors_null = false;
            }
            std.debug.print("{s}\t{d}\tREADY\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{ case_name, sequence, owner_index, made.nVar, made.nMem, made.nCursor, @intFromBool(made.aMem != null), @intFromBool(made.aVar != null), @intFromBool(made.apArg != null), @intFromBool(made.apCsr != null), @intFromBool(made.pFree != null) });
            std.debug.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{ made.eVdbeState, made.pc, made.rc, made.nChange, made.errorAction, made.cacheCtr, made.minWriteFileFormat, made.nFkConstraint, made.iStatement, @intFromBool(made.flags.usesStmtJournal), made.flags.explain, made.nResColumn, made.flags.expired });
            std.debug.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ if (made.nVar != 0) @as(c_int, made.aVar.?[0].flags) else -1, if (made.nVar != 0) @intFromBool(made.aVar.?[0].db == &db) else 0, if (made.nVar != 0) made.aVar.?[0].szMalloc else -1, if (made.nMem != 0) @as(c_int, made.aMem.?[0].flags) else -1, if (made.nMem != 0) @intFromBool(made.aMem.?[0].db == &db) else 0, if (made.nMem != 0) made.aMem.?[0].szMalloc else -1, @intFromBool(cursors_null), @intFromBool(made.flags.readOnly), @intFromBool(made.flags.bIsReader), db.mallocFailed, owner.nLabel, @intFromBool(owner.aLabel != null), @intFromBool(made.pVList != null), @intFromBool(owner.pVList != null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FILL")) {
            const count = try parseInt(try next(&tokens));
            const opcode = try operationCode(try next(&tokens));
            for (0..@intCast(count)) |_| {
                const operation_count_before = machine.nOp;
                const address = builder.addOperation0(&machine, opcode);
                observation(case_name, sequence, address, operation_count_before, &machine, &parse);
                sequence += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, command, "MAKELABELS")) {
            const count = try parseInt(try next(&tokens));
            for (0..@intCast(count)) |_| {
                labels[label_count] = builder.makeLabel(&parse);
                label_count += 1;
            }
            std.debug.print("{s}\t{d}\tMAKELABELS\t{d}\t{d}\t{d}\n", .{ case_name, sequence, label_count, labels[label_count - 1], parse.nLabelAlloc });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "RESOLVE")) {
            const label_index: usize = @intCast(try parseInt(try next(&tokens)));
            builder.resolveLabel(&machine, labels[label_index]);
            const address = types.labelAddress(labels[label_index]);
            const target: c_int = if (parse.aLabel != null and parse.nLabelAlloc > address) parse.aLabel.?[@intCast(address)] else -999;
            std.debug.print("{s}\t{d}\tRESOLVE\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, label_index, machine.nOp, parse.nLabel, parse.nLabelAlloc, @intFromBool(parse.aLabel != null), target, db.mallocFailed, parse.nErr, parse.rc, parse.nProgressSteps });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "PROGRESS")) {
            db.nProgressOps = @intCast(try parseInt(try next(&tokens)));
            progress_state.result = try parseInt(try next(&tokens));
            progress_state.calls = 0;
            db.pProgressArg = &progress_state;
            db.xProgress = progressCallback;
            std.debug.print("{s}\t{d}\tPROGRESS\t{d}\t{d}\n", .{ case_name, sequence, db.nProgressOps, progress_state.result });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "INTERRUPT")) {
            const value = try parseInt(try next(&tokens));
            @atomicStore(c_int, &db.u1.isInterrupted, value, .monotonic);
            std.debug.print("{s}\t{d}\tINTERRUPT\t{d}\n", .{ case_name, sequence, value });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "RUNONCE")) {
            const operation_count_before = machine.nOp;
            builder.runOnlyOnce(&machine);
            observation(case_name, sequence, operation_count_before, operation_count_before, &machine, &parse);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "REUSABLE")) {
            builder.reusable(&machine);
            const opcode: c_int = if (machine.nOp > 1) @intFromEnum(machine.aOp.?[1].opcode) else -1;
            std.debug.print("{s}\t{d}\tREUSABLE\t{d}\n", .{ case_name, sequence, opcode });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "GOTO")) {
            const destination = try parseInt(try next(&tokens));
            const operation_count_before = machine.nOp;
            const address = builder.addGoto(&machine, destination);
            observation(case_name, sequence, address, operation_count_before, &machine, &parse);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "EXPLAINPARENT")) {
            const address = try parseInt(try next(&tokens));
            const target = try parseInt(try next(&tokens));
            parse.addrExplain = 0;
            const none = builder.explainParent(&parse);
            machine.aOp.?[@intCast(address)].p2 = target;
            parse.pVdbe = @ptrCast(&machine);
            parse.addrExplain = address;
            const parent = builder.explainParent(&parse);
            builder.explainPop(&parse);
            std.debug.print("{s}\t{d}\tEXPLAINPARENT\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, address, target, none, parent, parse.addrExplain });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "CURRENT")) {
            std.debug.print("{s}\t{d}\tCURRENT\t{d}\n", .{ case_name, sequence, builder.currentAddress(&machine) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "GET")) {
            const address = try parseInt(try next(&tokens));
            const got = builder.getOperation(&machine, address);
            const is_real = machine.aOp != null and address >= 0 and address < machine.nOp and got == &machine.aOp.?[@intCast(address)];
            std.debug.print("{s}\t{d}\tGET\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, address, @intFromEnum(got.opcode), got.p1, got.p2, got.p3, got.p5, got.p4type, @intFromBool(is_real) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "MUTATE")) {
            const address = try parseInt(try next(&tokens));
            const opcode = try operationCode(try next(&tokens));
            const p1 = try parseInt(try next(&tokens));
            const p2 = try parseInt(try next(&tokens));
            const p3 = try parseInt(try next(&tokens));
            builder.changeOpcode(&machine, address, opcode);
            builder.changeP1(&machine, address, p1);
            builder.changeP2(&machine, address, p2);
            builder.changeP3(&machine, address, p3);
            const operation = machine.aOp.?[@intCast(address)];
            std.debug.print("{s}\t{d}\tMUTATE\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, address, @intFromEnum(operation.opcode), operation.p1, operation.p2, operation.p3 });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P5")) {
            const value = try parseInt(try next(&tokens));
            builder.changeP5(&machine, @intCast(value));
            const actual: c_int = if (machine.nOp != 0) machine.aOp.?[@intCast(machine.nOp - 1)].p5 else -1;
            std.debug.print("{s}\t{d}\tP5\t{d}\t{d}\n", .{ case_name, sequence, value, actual });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "TYPEOF")) {
            const destination = try parseInt(try next(&tokens));
            builder.typeofColumn(&machine, destination);
            std.debug.print("{s}\t{d}\tTYPEOF\t{d}\t{d}\n", .{ case_name, sequence, destination, machine.aOp.?[@intCast(machine.nOp - 1)].p5 });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "JUMPHERE")) {
            const address = try parseInt(try next(&tokens));
            builder.jumpHere(&machine, address);
            std.debug.print("{s}\t{d}\tJUMPHERE\t{d}\t{d}\n", .{ case_name, sequence, address, machine.aOp.?[@intCast(address)].p2 });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "JUMPPOP")) {
            const address = try parseInt(try next(&tokens));
            builder.jumpHereOrPopInstruction(&machine, address);
            const p2: c_int = if (address < machine.nOp) machine.aOp.?[@intCast(address)].p2 else -1;
            std.debug.print("{s}\t{d}\tJUMPPOP\t{d}\t{d}\t{d}\n", .{ case_name, sequence, address, machine.nOp, p2 });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "OOMFAULT")) {
            _ = builder.db_allocator.oomFault(&db);
            std.debug.print("{s}\t{d}\tOOMFAULT\t{d}\n", .{ case_name, sequence, db.mallocFailed });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "BIND")) {
            const owner_index = try parseInt(try next(&tokens));
            const variable = try parseInt(try next(&tokens));
            const value = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            const cell = &made.aVar.?[@intCast(variable - 1)];
            if (value != 0) vdbe_mem.setInt64(cell, value) else vdbe_mem.setNull(cell);
            std.debug.print("{s}\t{d}\tBIND\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, variable, cell.flags, value });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "BINDTEXT")) {
            const owner_index = try parseInt(try next(&tokens));
            const variable = try parseInt(try next(&tokens));
            const mode = try parseInt(try next(&tokens));
            const text = try next(&tokens);
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            bind_destructor_calls = 0;
            const ownership: vdbe_mem.StringOwnership = if (mode == 1 or mode == 2) .{ .custom = testBindDestructor } else .transient;
            if (mode == 2) {
                made.eVdbeState = types.vdbe_state.run;
            }
            if (mode == 3) {
                made.prepFlags |= types.prepare_save_sql;
                const bit: u5 = @intCast(@min(variable - 1, 31));
                made.expmask |= @as(u32, 1) << bit;
            }
            const result = api.bindText(made, variable, text.ptr, @intCast(text.len), ownership, 1);
            if (mode == 2) {
                made.eVdbeState = types.vdbe_state.ready;
            }
            const cell_index: usize = if (variable >= 1 and variable <= made.nVar) @intCast(variable - 1) else 0;
            const cell = &made.aVar.?[cell_index];
            const same_text = cell.z != null and cell.n == text.len and std.mem.eql(u8, cell.z.?[0..text.len], text);
            std.debug.print("{s}\t{d}\tBINDTEXT\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, variable, mode, result, cell.flags, cell.n, cell.enc, made.flags.expired, db.errCode, db.mallocFailed, bind_destructor_calls, @intFromBool(same_text) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "BINDTYPED")) {
            const owner_index = try parseInt(try next(&tokens));
            const variable = try parseInt(try next(&tokens));
            const mode = try parseInt(try next(&tokens));
            const binding_input = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            var value = std.mem.zeroes(types.Mem);
            value.db = &db;
            value.flags = types.mem_flag.null_;
            const result = switch (mode) {
                0 => api.bindDouble(made, variable, @as(f64, @floatFromInt(binding_input)) + 0.5),
                1 => api.bindInt64(made, variable, binding_input),
                2 => api.bindNull(made, variable),
                3 => api.bindPointer(made, variable, @ptrCast(&bind_destructor_calls), "bind-test", testBindDestructor),
                4 => api.bindZeroBlob(made, variable, binding_input),
                5 => api.bindZeroBlob64(made, variable, @bitCast(@as(i64, binding_input))),
                6 => result: {
                    vdbe_mem.setZeroBlob(&value, binding_input);
                    break :result api.bindValue(made, variable, &value);
                },
                else => unreachable,
            };
            const cell_index: usize = if (variable >= 1 and variable <= made.nVar) @intCast(variable - 1) else 0;
            const cell = &made.aVar.?[cell_index];
            const payload: u64 = if (cell.flags & types.mem_flag.real != 0)
                @bitCast(cell.u.r)
            else if (cell.flags & types.mem_flag.integer != 0)
                @bitCast(cell.u.i)
            else if (cell.flags & types.mem_flag.zero != 0)
                @intCast(cell.u.nZero)
            else
                0;
            std.debug.print("{s}\t{d}\tBINDTYPED\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, variable, mode, binding_input, result, cell.flags, cell.enc, cell.n, cell.eSubtype, @intFromBool(cell.xDel != null), bind_destructor_calls, payload });
            vdbe_mem.release(&value);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "EXPLAINMODE")) {
            const mode = try parseInt(try next(&tokens));
            const setup = try parseInt(try next(&tokens));
            var explain_machine = std.mem.zeroes(types.Vdbe);
            explain_machine.db = &db;
            explain_machine.eVdbeState = types.vdbe_state.ready;
            explain_machine.prepFlags = types.prepare_save_sql;
            explain_machine.nMem = 1;
            explain_machine.nResAlloc = 1;
            if (setup == 1) explain_machine.eVdbeState = types.vdbe_state.run;
            if (setup == 2) explain_machine.prepFlags &= ~types.prepare_save_sql;
            reprepare_calls = 0;
            const result = api.statementExplain(&explain_machine, mode, testReprepare);
            std.debug.print("{s}\t{d}\tEXPLAINMODE\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, mode, setup, result, explain_machine.flags.explain, explain_machine.nResColumn, reprepare_calls });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "BOUND")) {
            const owner_index = try parseInt(try next(&tokens));
            const variable = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            const value = builder.getBoundValue(made, variable, 0x44);
            std.debug.print("{s}\t{d}\tBOUND\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, variable, @intFromBool(value != null), if (value) |cell| @as(c_int, cell.flags) else -1, if (value) |cell| cell.u.i else 0, db.mallocFailed });
            vdbe_mem.valueFree(value);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "VARMASK")) {
            const owner_index = try parseInt(try next(&tokens));
            const variable = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            builder.setVariableMask(made, variable);
            std.debug.print("{s}\t{d}\tVARMASK\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, variable, made.expmask });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "USEBTREE")) {
            const database_index = try parseInt(try next(&tokens));
            const is_sharable = try parseInt(try next(&tokens));
            const saved_dbs = db.aDb;
            const saved_count = db.nDb;
            db.aDb = &test_dbs;
            db.nDb = test_dbs.len;
            test_dbs[@intCast(database_index)].pBt = &test_btrees[@intCast(database_index)];
            test_btrees[@intCast(database_index)].db = &db;
            test_btrees[@intCast(database_index)].sharable = @intCast(is_sharable);
            const direct = btree_aux.sharable(&test_btrees[@intCast(database_index)]);
            builder.usesBtree(&machine, database_index);
            db.aDb = saved_dbs;
            db.nDb = saved_count;
            std.debug.print("{s}\t{d}\tUSEBTREE\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, database_index, is_sharable, direct, machine.btreeMask, machine.lockMask });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "UNPACKALLOC")) {
            const key_fields = try parseInt(try next(&tokens));
            var info = std.mem.zeroes(types.KeyInfo);
            info.db = &db;
            info.nKeyField = @intCast(key_fields);
            const record = vdbe_record.allocateUnpackedRecord(&info);
            const memory_offset = (@sizeOf(types.UnpackedRecord) + 7) & ~@as(usize, 7);
            std.debug.print("{s}\t{d}\tUNPACKALLOC\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, key_fields, @intFromBool(record != null), if (record) |value| @as(c_int, value.nField) else -1, @intFromBool(if (record) |value| value.pKeyInfo == &info else false), @intFromBool(if (record) |value| value.aMem == @as([*]types.Mem, @ptrCast(@alignCast(@as([*]u8, @ptrCast(value)) + memory_offset))) else false), db.mallocFailed });
            builder.db_allocator.free(&db, if (record) |value| @ptrCast(value) else null);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "UNPACK")) {
            const record_bytes = [_]u8{ 5, 1, 2, 15, 0, 0xff, 0x80, 0x01, 'A' };
            var info = std.mem.zeroes(types.KeyInfo);
            info.db = &db;
            info.enc = 1;
            info.nKeyField = 3;
            const record = vdbe_record.allocateUnpackedRecord(&info).?;
            vdbe_record.unpackRecord(record_bytes.len, &record_bytes, record);
            const values = record.aMem.?;
            const raw0: u64 = @bitCast(values[0].u.i);
            const raw1: u64 = @bitCast(values[1].u.i);
            const raw2: u64 = @bitCast(values[2].u.i);
            const raw3: u64 = @bitCast(values[3].u.i);
            std.debug.print("{s}\t{d}\tUNPACK\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, record.nField, record.default_rc, values[0].flags, raw0, values[1].flags, raw1, values[2].flags, values[2].n, raw2, values[3].flags, @intFromBool(values[2].z == @as([*]const u8, &record_bytes) + 8), raw3 });
            builder.db_allocator.freeNN(&db, @ptrCast(record));
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "UNPACKTRUNC")) {
            const record_bytes = [_]u8{ 3, 6, 1, 0x80, 1, 2, 3, 4, 5, 6, 7 };
            var info = std.mem.zeroes(types.KeyInfo);
            info.db = &db;
            info.enc = 1;
            info.nKeyField = 2;
            const record = vdbe_record.allocateUnpackedRecord(&info).?;
            vdbe_record.unpackRecord(4, &record_bytes, record);
            const first = record.aMem.?[0];
            std.debug.print("{s}\t{d}\tUNPACKTRUNC\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, record.nField, record.default_rc, first.flags, first.szMalloc });
            builder.db_allocator.freeNN(&db, @ptrCast(record));
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "SERIAL")) {
            const serial_type = try parseInt(try next(&tokens));
            const bytes = [_]u8{ 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
            var value = std.mem.zeroes(types.Mem);
            vdbe_record.serialGetValue(&bytes, @intCast(serial_type), &value);
            const raw: u64 = @bitCast(value.u.i);
            std.debug.print("{s}\t{d}\tSERIAL\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, serial_type, vdbe_record.serialTypeLength(@intCast(serial_type)), if (serial_type < 128) @as(c_int, vdbe_record.oneByteSerialTypeLength(@intCast(serial_type))) else -1, value.flags, value.n, raw, @intFromBool(if (value.z) |text| text == @as([*]const u8, &bytes) else false) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "SERIAL7")) {
            const use_nan = try parseInt(try next(&tokens));
            const finite = [_]u8{ 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 };
            const nan = [_]u8{ 0x7f, 0xf8, 0, 0, 0, 0, 0, 1 };
            const bytes = if (use_nan != 0) &nan else &finite;
            var value = std.mem.zeroes(types.Mem);
            const result = vdbe_record.serialGet7(bytes, &value);
            const raw: u64 = @bitCast(value.u.i);
            std.debug.print("{s}\t{d}\tSERIAL7\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, use_nan, result, value.flags, raw });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FKSTATE")) {
            builder.db_allocator.free(&db, if (machine.zErrMsg) |message| @ptrCast(message) else null);
            machine.zErrMsg = builder.db_allocator.stringDuplicate(&db, "prior-error");
            machine.rc = 55;
            machine.errorAction = 7;
            std.debug.print("{s}\t{d}\tFKSTATE\t{d}\t{d}\t{d}\n", .{ case_name, sequence, machine.rc, machine.errorAction, @intFromBool(if (machine.zErrMsg) |message| std.mem.eql(u8, std.mem.span(message), "prior-error") else false) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FKCHECK")) {
            const mode = try next(&tokens);
            const first = try parseInt(try next(&tokens));
            const second = try parseInt(try next(&tokens));
            const prepare_flags = try parseInt(try next(&tokens));
            machine.prepFlags = @intCast(prepare_flags);
            const result = if (mode[0] == 'I') blk: {
                machine.nFkConstraint = first;
                break :blk builder.checkForeignKeyImmediate(&machine);
            } else blk: {
                db.nDeferredCons = first;
                db.nDeferredImmCons = second;
                break :blk builder.checkForeignKeyDeferred(&machine);
            };
            std.debug.print("{s}\t{d}\tFKCHECK\t{c}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, mode[0], first, second, prepare_flags, result, machine.rc, machine.errorAction, @intFromBool(if (machine.zErrMsg) |message| std.mem.eql(u8, std.mem.span(message), "FOREIGN KEY constraint failed") else false), db.mallocFailed });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "VERRSET")) {
            const incoming = try parseInt(try next(&tokens));
            if (public_vtab.zErrMsg) |message| memory.processManager().free(@ptrCast(message));
            public_vtab.zErrMsg = null;
            builder.db_allocator.free(&db, if (machine.zErrMsg) |message| @ptrCast(message) else null);
            machine.zErrMsg = builder.db_allocator.stringDuplicate(&db, "old-error");
            if (incoming != 0) public_vtab.zErrMsg = globalString("new-error");
            std.debug.print("{s}\t{d}\tVERRSET\t{d}\t{d}\t{d}\n", .{ case_name, sequence, incoming, @intFromBool(machine.zErrMsg != null), @intFromBool(public_vtab.zErrMsg != null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "VIMPORT")) {
            const old = machine.zErrMsg;
            builder.importVtabError(&machine, &public_vtab);
            const current = machine.zErrMsg;
            std.debug.print("{s}\t{d}\tVIMPORT\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(public_vtab.zErrMsg == null), @intFromBool(current != null), @intFromBool(if (current) |message| std.mem.eql(u8, std.mem.span(message), "new-error") else false), @intFromBool(if (current) |message| std.mem.eql(u8, std.mem.span(message), "old-error") else false), @intFromBool(old != current and if (old) |message| lookasideContains(&db, message) else false) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "COLCOUNT")) {
            const owner_index = try parseInt(try next(&tokens));
            const count = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            builder.setColumnCount(made, count);
            std.debug.print("{s}\t{d}\tCOLCOUNT\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, count, made.nResColumn, made.nResAlloc, @intFromBool(made.aColName != null), if (made.aColName) |columns| @as(c_int, columns[0].flags) else -1, @intFromBool(if (made.aColName) |columns| columns[0].db == &db else false), db.mallocFailed });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "COLNAME")) {
            const owner_index = try parseInt(try next(&tokens));
            const column_index = try parseInt(try next(&tokens));
            const variant = try parseInt(try next(&tokens));
            const strategy = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            var dynamic: ?[*]u8 = null;
            const text: [*]const u8 = switch (strategy) {
                0 => "alpha",
                1 => "beta",
                else => blk: {
                    dynamic = builder.db_allocator.stringDuplicate(&db, "gamma");
                    break :blk dynamic.?;
                },
            };
            const ownership: vdbe_mem.StringOwnership = switch (strategy) {
                0 => .static,
                1 => .transient,
                else => .dynamic,
            };
            const result = builder.setColumnName(made, column_index, @intCast(variant), text, ownership);
            const cell: ?*types.Mem = if (made.aColName) |columns| &columns[@intCast(column_index + variant * made.nResAlloc)] else null;
            const expected = switch (strategy) {
                0 => "alpha",
                1 => "beta",
                else => "gamma",
            };
            std.debug.print("{s}\t{d}\tCOLNAME\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, column_index, variant, strategy, result, if (cell) |value| @as(c_int, value.flags) else -1, @intFromBool(if (cell) |value| value.z != null and value.n == expected.len and std.mem.eql(u8, value.z.?[0..expected.len], expected) else false), @intFromBool(if (cell) |value| value.z == text else false), @intFromBool(if (cell) |value| value.szMalloc != 0 and value.zMalloc != null else false) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "METADATA")) {
            const machine_a: *types.Vdbe = @ptrCast(@alignCast(create_parse[0].pVdbe.?));
            const machine_b: *types.Vdbe = @ptrCast(@alignCast(create_parse[1].pVdbe.?));
            const total_before = db.nTotalChange;
            builder.setChanges(&db, 7);
            builder.countChanges(machine_a);
            builder.expirePreparedStatements(&db, 0);
            const first_a = machine_a.flags.expired;
            const first_b = machine_b.flags.expired;
            builder.expirePreparedStatements(&db, 1);
            machine_a.prepFlags = 37;
            machine_a.rc = types.result_interrupt;
            builder.resetStepResult(machine_a);
            std.debug.print("{s}\t{d}\tMETADATA\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, db.nChange, db.nTotalChange - total_before, @intFromBool(machine_a.flags.changeCntOn), first_a, first_b, machine_a.flags.expired, machine_b.flags.expired, @intFromBool(builder.database(machine_a) == &db), builder.prepareFlags(machine_a), machine_a.rc });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APICOLUMNS")) {
            var row = [_]types.Mem{ std.mem.zeroes(types.Mem), std.mem.zeroes(types.Mem) };
            vdbe_mem.init(&row[0], &db, types.mem_flag.null_);
            vdbe_mem.init(&row[1], &db, types.mem_flag.null_);
            vdbe_mem.setInt64(&row[0], 42);
            _ = vdbe_mem.setStr(&row[1], "text", 4, 1, .static);
            machine.pResultRow = &row[0];
            machine.nResColumn = 2;
            const count_null = api.columnCount(null);
            const count_live = api.columnCount(&machine);
            const data_null = api.dataCount(null);
            const data_live = api.dataCount(&machine);
            const integer = api.columnInt(&machine, 0);
            const value = api.columnValue(&machine, 0);
            const text_type = api.columnType(&machine, 1);
            const text = api.columnText(&machine, 1);
            const bytes = api.columnBytes(&machine, 1);
            const blob = api.columnBlob(&machine, 1);
            const text16 = api.columnText16(&machine, 1);
            const bytes16 = api.columnBytes16(&machine, 1);
            const invalid = api.columnInt(&machine, 9);
            const invalid_code = db.errCode;
            std.debug.print("{s}\t{d}\tAPICOLUMNS\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, count_null, count_live, data_null, data_live, integer, @intFromBool(value == &row[0]), text_type, @intFromBool(text != null and std.mem.eql(u8, text.?[0..4], "text")), bytes, @intFromBool(blob != null), @intFromBool(text16 != null), bytes16, invalid, invalid_code });
            vdbe_mem.release(&row[0]);
            vdbe_mem.release(&row[1]);
            machine.pResultRow = null;
            machine.nResColumn = 0;
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APIVLIST")) {
            var list: ?*types.VList = null;
            list = api.vlistAdd(&db, list, ":alpha", 6, 1);
            list = api.vlistAdd(&db, list, "@beta", 5, 2);
            machine.pVList = list;
            machine.nVar = 2;
            const first_name = api.bindParameterName(&machine, 1);
            const first_index = api.bindParameterIndex(&machine, ":alpha");
            const second_index = api.parameterIndex(&machine, "@beta", 5);
            const missing = api.parameterIndex(&machine, "$missing", 8);
            std.debug.print("{s}\t{d}\tAPIVLIST\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, api.bindParameterCount(&machine), @intFromBool(first_name != null and std.mem.eql(u8, std.mem.span(first_name.?), ":alpha")), first_index, second_index, missing, @intFromBool(list != null) });
            builder.db_allocator.free(&db, if (list) |owned| @ptrCast(owned) else null);
            machine.pVList = null;
            machine.nVar = 0;
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APIVLISTOOM")) {
            db.lookaside.bDisable = 1;
            db.lookaside.sz = 0;
            var list: ?*types.VList = null;
            list = api.vlistAdd(&db, list, "alpha", 5, 1);
            list = api.vlistAdd(&db, list, "beta", 4, 2);
            const before = list;
            fault_backend.fail_at = fault_backend.attempt_count;
            fault_backend.sticky = false;
            fault_backend.fired = false;
            list = api.vlistAdd(&db, list, "01234567890123456789", 20, 3);
            const retained = list == before;
            const missing = api.vlistNameToNumber(list, "01234567890123456789", 20);
            const oom_state = db.mallocFailed;
            if (db.mallocFailed != 0) builder.db_allocator.oomClear(&db);
            fault_backend.fail_at = null;
            fault_backend.sticky = false;
            fault_backend.fired = false;
            std.debug.print("{s}\t{d}\tAPIVLISTOOM\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(retained), missing, oom_state });
            builder.db_allocator.free(&db, if (list) |owned| @ptrCast(owned) else null);
            db.lookaside.bDisable = 0;
            db.lookaside.sz = db.lookaside.szTrue;
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APIBINDINGS")) {
            var from = std.mem.zeroes(types.Vdbe);
            var to = std.mem.zeroes(types.Vdbe);
            var from_values = [_]types.Mem{ std.mem.zeroes(types.Mem), std.mem.zeroes(types.Mem) };
            var to_values = [_]types.Mem{ std.mem.zeroes(types.Mem), std.mem.zeroes(types.Mem) };
            from.db = &db;
            to.db = &db;
            from.nVar = 2;
            to.nVar = 2;
            from.aVar = &from_values;
            to.aVar = &to_values;
            from.prepFlags = types.prepare_save_sql;
            to.prepFlags = types.prepare_save_sql;
            for (&from_values) |*value| vdbe_mem.init(value, &db, types.mem_flag.null_);
            for (&to_values) |*value| vdbe_mem.init(value, &db, types.mem_flag.null_);
            vdbe_mem.setInt64(&from_values[0], 11);
            vdbe_mem.setInt64(&from_values[1], 22);
            const direct_result = api.transferBindings(&from, &to);
            vdbe_mem.setInt64(&from_values[0], 33);
            vdbe_mem.setInt64(&from_values[1], 44);
            from.expmask = 1;
            to.expmask = 1;
            const deprecated_result = api.transferBindingsDeprecated(&from, &to);
            const clear_result = api.clearBindings(&to);
            std.debug.print("{s}\t{d}\tAPIBINDINGS\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, direct_result, deprecated_result, clear_result, from.flags.expired, to.flags.expired, from_values[0].flags, to_values[0].flags, to_values[1].flags, to.expmask });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APIMETA")) {
            var second = std.mem.zeroes(types.Vdbe);
            var finalized = std.mem.zeroes(types.Vdbe);
            second.db = &db;
            machine.pVNext = &second;
            db.pVdbe = &machine;
            machine.flags.readOnly = true;
            machine.flags.explain = 2;
            machine.eVdbeState = types.vdbe_state.run;
            machine.flags.expired = 2;
            machine.zSql = @constCast("select 1");
            machine.aCounter[3] = 17;
            const counter_before = api.statementStatus(&machine, 3, true);
            const counter_after = api.statementStatus(&machine, 3, false);
            const sql_text = api.statementSql(&machine);
            std.debug.print("{s}\t{d}\tAPIMETA\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, api.statementExpired(&machine), @intFromBool(api.databaseHandle(&machine) == &db), api.statementReadonly(&machine), api.statementIsExplain(&machine), api.statementBusy(&machine), @intFromBool(api.nextStatement(&db, null) == &machine), @intFromBool(api.nextStatement(&db, &machine) == &second), counter_before, counter_after, @intFromBool(sql_text != null and std.mem.eql(u8, std.mem.span(sql_text.?), "select 1")), @intFromBool(api.vdbeSafety(&machine)), @intFromBool(api.vdbeSafety(&finalized)), @intFromBool(api.vdbeSafetyNotNull(null)) });
            db.pVdbe = null;
            machine.pVNext = null;
            machine.flags.readOnly = false;
            machine.flags.explain = 0;
            machine.flags.expired = 0;
            machine.eVdbeState = types.vdbe_state.init;
            machine.zSql = null;
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APIMEMUSED")) {
            var owner_parse = std.mem.zeroes(types.Parse);
            owner_parse.db = @ptrCast(&db);
            const owned = builder.create(&owner_parse).?;
            _ = builder.addOperation0(owned, .Noop);
            const measured = api.statementStatus(owned, 99, false);
            const still_linked = db.pVdbe == owned and owned.db == &db;
            std.debug.print("{s}\t{d}\tAPIMEMUSED\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(measured > 0), @intFromBool(still_linked) });
            builder.deleteVdbe(owned);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "APIEXIT")) {
            db.errMask = 0xff;
            const masked = api.apiExit(&db, 0x1234);
            _ = builder.db_allocator.oomFault(&db);
            const oom_result = api.apiExit(&db, 0);
            const oom_state = db.mallocFailed;
            const error_code = db.errCode;
            std.debug.print("{s}\t{d}\tAPIEXIT\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, masked, oom_result, oom_state, error_code });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "SETSQLNULL")) {
            builder.setSql(null, "ignored", 7, 3);
            std.debug.print("{s}\t{d}\tSETSQLNULL\n", .{ case_name, sequence });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "SETSQL")) {
            const owner_index = try parseInt(try next(&tokens));
            const made: *types.Vdbe = @ptrCast(@alignCast(create_parse[@intCast(owner_index)].pVdbe.?));
            made.expmask = 55;
            builder.setSql(made, "gamma", 5, 3);
            std.debug.print("{s}\t{d}\tSETSQL\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, owner_index, made.prepFlags, @intFromBool(made.zSql != null), made.expmask, db.mallocFailed });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "SWAP")) {
            const machine_a: *types.Vdbe = @ptrCast(@alignCast(create_parse[0].pVdbe.?));
            const machine_b: *types.Vdbe = @ptrCast(@alignCast(create_parse[1].pVdbe.?));
            builder.setSql(machine_a, "alpha", 5, 3);
            builder.setSql(machine_b, "beta", 4, 4);
            machine_a.aOp.?[0].p1 = 101;
            machine_b.aOp.?[0].p1 = 202;
            machine_a.expmask = 11;
            machine_b.expmask = 22;
            machine_a.aCounter[0] = 10;
            machine_a.aCounter[types.statement_status_reprepare] = 1;
            machine_b.aCounter[0] = 20;
            machine_b.aCounter[types.statement_status_reprepare] = 2;
            builder.swap(machine_a, machine_b);
            std.debug.print("{s}\t{d}\tSWAP\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, machine_a.aOp.?[0].p1, machine_b.aOp.?[0].p1, @intFromBool(std.mem.eql(u8, std.mem.span(machine_a.zSql.?), "alpha")), @intFromBool(std.mem.eql(u8, std.mem.span(machine_b.zSql.?), "beta")), machine_a.expmask, machine_b.expmask, machine_a.prepFlags, machine_b.prepFlags, machine_a.aCounter[0], machine_b.aCounter[0], machine_a.aCounter[5], machine_b.aCounter[5], @intFromBool(db.pVdbe == machine_b), @intFromBool(machine_b.pVNext == machine_a), @intFromBool(machine_a.pVNext == null), @intFromBool(machine_a.pParse == &create_parse[1]), @intFromBool(machine_b.pParse == &create_parse[0]) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "HASSUB")) {
            std.debug.print("{s}\t{d}\tHASSUB\t{d}\n", .{ case_name, sequence, @intFromBool(builder.hasSubProgram(&machine)) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "LINKSUB")) {
            const first_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.SubProgram)).?;
            const second_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.SubProgram)).?;
            const first: *types.SubProgram = @ptrCast(@alignCast(first_raw));
            const second: *types.SubProgram = @ptrCast(@alignCast(second_raw));
            @memset(@as([*]u8, @ptrCast(first_raw))[0..@sizeOf(types.SubProgram)], 0);
            @memset(@as([*]u8, @ptrCast(second_raw))[0..@sizeOf(types.SubProgram)], 0);
            builder.linkSubProgram(&machine, first);
            builder.linkSubProgram(&machine, second);
            std.debug.print("{s}\t{d}\tLINKSUB\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(builder.hasSubProgram(&machine)), @intFromBool(machine.pProgram == second), @intFromBool(second.pNext == first), @intFromBool(first.pNext == null) });
            machine.pProgram = null;
            builder.db_allocator.freeNN(&db, second_raw);
            builder.db_allocator.freeNN(&db, first_raw);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "VTABOWNER")) {
            const has_public_table = try parseInt(try next(&tokens));
            const has_destroy = try parseInt(try next(&tokens));
            const module_refs = try parseInt(try next(&tokens));
            const public_module_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.PublicModule)).?;
            const public_table_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.PublicVtab)).?;
            const module_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.Module)).?;
            const table_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.VTable)).?;
            const public_module: *types.PublicModule = @ptrCast(@alignCast(public_module_raw));
            const public_table: *types.PublicVtab = @ptrCast(@alignCast(public_table_raw));
            const module: *types.Module = @ptrCast(@alignCast(module_raw));
            const table: *types.VTable = @ptrCast(@alignCast(table_raw));
            @memset(@as([*]u8, @ptrCast(public_module_raw))[0..@sizeOf(types.PublicModule)], 0);
            @memset(@as([*]u8, @ptrCast(public_table_raw))[0..@sizeOf(types.PublicVtab)], 0);
            @memset(@as([*]u8, @ptrCast(module_raw))[0..@sizeOf(types.Module)], 0);
            @memset(@as([*]u8, @ptrCast(table_raw))[0..@sizeOf(types.VTable)], 0);
            public_module.xDisconnect = testVtabDisconnect;
            public_table.pModule = public_module;
            module.pModule = public_module;
            module.nRefModule = module_refs;
            if (has_destroy != 0) module.xDestroy = testModuleDestroy;
            table.db = &db;
            table.pMod = module;
            if (has_public_table != 0) table.pVtab = public_table;
            table.nRef = 1;
            vtab_disconnect_calls = 0;
            module_destroy_calls = 0;
            builder.vtabLock(table);
            const after_lock = table.nRef;
            builder.vtabUnlock(table);
            const after_first_unlock = table.nRef;
            const disconnect_after_first = vtab_disconnect_calls;
            builder.vtabUnlock(table);
            const module_freed = lookasideContains(&db, module);
            const module_refs_after = if (module_freed) 0 else module.nRefModule;
            std.debug.print("{s}\t{d}\tVTABOWNER\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, has_public_table, has_destroy, module_refs, after_lock, after_first_unlock, disconnect_after_first, vtab_disconnect_calls, module_destroy_calls, @intFromBool(module_freed), module_refs_after, @intFromBool(lookasideContains(&db, table)) });
            if (!module_freed) builder.vtabModuleUnref(&db, module);
            builder.db_allocator.freeNN(&db, public_table_raw);
            builder.db_allocator.freeNN(&db, public_module_raw);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FUNCFREE")) {
            const ephemeral = try parseInt(try next(&tokens));
            const raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.FuncDef)).?;
            const function: *types.FuncDef = @ptrCast(@alignCast(raw));
            @memset(@as([*]u8, @ptrCast(raw))[0..@sizeOf(types.FuncDef)], 0);
            if (ephemeral != 0) function.funcFlags |= types.function_flag_ephemeral;
            builder.freeEphemeralFunction(&db, function);
            const freed = lookasideContains(&db, function);
            std.debug.print("{s}\t{d}\tFUNCFREE\t{d}\t{d}\n", .{ case_name, sequence, ephemeral, @intFromBool(freed) });
            if (ephemeral == 0) builder.db_allocator.freeNN(&db, raw);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FUNCCTXFREE")) {
            const ephemeral = try parseInt(try next(&tokens));
            const function_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.FuncDef)).?;
            const context_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.Context)).?;
            const function: *types.FuncDef = @ptrCast(@alignCast(function_raw));
            const context: *types.Context = @ptrCast(@alignCast(context_raw));
            @memset(@as([*]u8, @ptrCast(function_raw))[0..@sizeOf(types.FuncDef)], 0);
            @memset(@as([*]u8, @ptrCast(context_raw))[0..@sizeOf(types.Context)], 0);
            if (ephemeral != 0) function.funcFlags = types.function_flag_ephemeral;
            context.pFunc = function;
            builder.freeP4FunctionContext(&db, context);
            std.debug.print("{s}\t{d}\tFUNCCTXFREE\t{d}\t{d}\t{d}\n", .{ case_name, sequence, ephemeral, @intFromBool(lookasideContains(&db, function)), @intFromBool(lookasideContains(&db, context)) });
            if (ephemeral == 0) builder.db_allocator.freeNN(&db, function_raw);
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4MEMFREE")) {
            const has_allocation = try parseInt(try next(&tokens));
            const value_raw = builder.db_allocator.mallocRawNN(&db, @sizeOf(types.Mem)).?;
            const value: *types.Mem = @ptrCast(@alignCast(value_raw));
            @memset(@as([*]u8, @ptrCast(value_raw))[0..@sizeOf(types.Mem)], 0);
            const allocation = if (has_allocation != 0) builder.db_allocator.mallocRawNN(&db, 32).? else null;
            if (allocation) |owned| {
                value.szMalloc = 32;
                value.zMalloc = @ptrCast(owned);
            }
            builder.freeP4Mem(&db, value);
            std.debug.print("{s}\t{d}\tP4MEMFREE\t{d}\t{d}\t{d}\n", .{ case_name, sequence, has_allocation, @intFromBool(lookasideContains(&db, value)), @intFromBool(if (allocation) |owned| lookasideContains(&db, owned) else false) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4DYNAMIC")) {
            const owner = builder.db_allocator.mallocRawNN(&db, 32).?;
            builder.freeP4(&db, types.p4.dynamic, owner);
            std.debug.print("{s}\t{d}\tP4DYNAMIC\t{d}\n", .{ case_name, sequence, @intFromBool(lookasideContains(&db, owner)) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4TABREF")) {
            const raw = builder.db_allocator.mallocZero(&db, @sizeOf(types.Table)).?;
            const table: *types.Table = @ptrCast(@alignCast(raw));
            table.reference_count = 2;
            builder.freeP4(&db, types.p4.table_ref, table);
            const first_reference = table.reference_count;
            const first_freed = lookasideContains(&db, table);
            builder.freeP4(&db, types.p4.table_ref, table);
            std.debug.print("{s}\t{d}\tP4TABREF\t{d}\t{d}\t{d}\n", .{ case_name, sequence, first_reference, @intFromBool(first_freed), @intFromBool(lookasideContains(&db, table)) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4TABLEINDEX")) {
            var schema_owner = std.mem.zeroes(types.Schema);
            var index_name = [_:0]u8{ 'o', 'w', 'n', 'e', 'd', '_', 'i', 'd', 'x' };
            const table_raw = builder.db_allocator.mallocZero(&db, @sizeOf(types.Table)).?;
            const index_raw = builder.db_allocator.mallocZero(&db, @sizeOf(types.Index)).?;
            const table: *types.Table = @ptrCast(@alignCast(table_raw));
            const index: *types.Index = @ptrCast(@alignCast(index_raw));
            table.reference_count = 1;
            table.schema = &schema_owner;
            table.indexes = index;
            index.name = &index_name;
            index.table = table;
            index.schema = &schema_owner;
            _ = schema_owner.index_hash.insert(memory.processAllocator(), &index_name, index);
            builder.freeP4(&db, types.p4.table_ref, table);
            std.debug.print("{s}\t{d}\tP4TABLEINDEX\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(lookasideContains(&db, index)), @intFromBool(lookasideContains(&db, table)), schema_owner.index_hash.count() });
            schema_owner.index_hash.clear(memory.processAllocator());
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4SUBSIG")) {
            const signature_raw = builder.db_allocator.mallocZero(&db, @sizeOf(types.SubrtnSig)).?;
            const affinity = builder.db_allocator.mallocRawNN(&db, 16).?;
            const signature: *types.SubrtnSig = @ptrCast(@alignCast(signature_raw));
            signature.zAff = @ptrCast(affinity);
            builder.freeP4(&db, types.p4.subroutine_signature, signature);
            std.debug.print("{s}\t{d}\tP4SUBSIG\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(lookasideContains(&db, affinity)), @intFromBool(lookasideContains(&db, signature)) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4NOOP")) {
            const owner = builder.db_allocator.mallocRawNN(&db, 32).?;
            const address = builder.addOperation0(&machine, .Noop);
            machine.aOp.?[@intCast(address)].p4type = types.p4.dynamic;
            machine.aOp.?[@intCast(address)].p4.p = owner;
            const changed = builder.changeToNoop(&machine, address);
            std.debug.print("{s}\t{d}\tP4NOOP\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, changed, @intFromBool(lookasideContains(&db, owner)), @intFromEnum(machine.aOp.?[@intCast(address)].opcode), machine.aOp.?[@intCast(address)].p4type });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4CHANGE")) {
            const static_text: [*:0]const u8 = "stable";
            const address = builder.addOperation0(&machine, .Noop);
            builder.changeP4(&machine, address, @ptrCast(@constCast(static_text)), types.p4.static);
            const static_identity = machine.aOp.?[@intCast(address)].p4.z == static_text;
            builder.changeP4Int32(&machine, address, 123456);
            const integer_value = machine.aOp.?[@intCast(address)].p4.i;
            builder.changeP4String(&machine, -1, "alphabet", 5);
            const dynamic_owner = machine.aOp.?[@intCast(address)].p4.p.?;
            const dynamic_type = machine.aOp.?[@intCast(address)].p4type;
            const dynamic_text = std.mem.eql(u8, machine.aOp.?[@intCast(address)].p4.z.?[0..5], "alpha");
            const dynamic_distinct = machine.aOp.?[@intCast(address)].p4.z != static_text;
            _ = builder.changeToNoop(&machine, address);
            const dynamic_freed = lookasideContains(&db, dynamic_owner);
            const oom_address = builder.addOperation0(&machine, .Noop);
            const oom_owner = builder.db_allocator.mallocRawNN(&db, 32).?;
            _ = builder.db_allocator.oomFault(&db);
            builder.changeP4(&machine, oom_address, oom_owner, types.p4.dynamic);
            const oom_owner_freed = lookasideContains(&db, oom_owner);
            const oom_operation_type = machine.aOp.?[@intCast(oom_address)].p4type;
            const oom_state = db.mallocFailed;
            builder.db_allocator.oomClear(&db);
            std.debug.print("{s}\t{d}\tP4CHANGE\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(static_identity), integer_value, dynamic_type, @intFromBool(dynamic_text), @intFromBool(dynamic_distinct), @intFromBool(dynamic_freed), @intFromBool(oom_owner_freed), oom_operation_type, oom_state });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4CHANGEVTAB")) {
            var table = std.mem.zeroes(types.VTable);
            table.db = &db;
            table.nRef = 1;
            const address = builder.addOperation0(&machine, .Noop);
            builder.changeP4(&machine, address, &table, types.p4.vtab);
            const after_lock = table.nRef;
            const pointer_identity = machine.aOp.?[@intCast(address)].p4.p == @as(*anyopaque, @ptrCast(&table));
            const owner_type = machine.aOp.?[@intCast(address)].p4type;
            _ = builder.changeToNoop(&machine, address);
            const after_release = table.nRef;
            std.debug.print("{s}\t{d}\tP4CHANGEVTAB\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, after_lock, @intFromBool(pointer_identity), owner_type, after_release });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4APPEND")) {
            const address = builder.addOperation0(&machine, .Noop);
            const normal_owner = builder.db_allocator.mallocRawNN(&db, 32).?;
            builder.appendP4(&machine, normal_owner, types.p4.dynamic);
            const pointer_identity = machine.aOp.?[@intCast(address)].p4.p == normal_owner;
            const owner_type = machine.aOp.?[@intCast(address)].p4type;
            _ = builder.changeToNoop(&machine, address);
            const normal_freed = lookasideContains(&db, normal_owner);
            const oom_address = builder.addOperation0(&machine, .Noop);
            const oom_owner = builder.db_allocator.mallocRawNN(&db, 32).?;
            _ = builder.db_allocator.oomFault(&db);
            builder.appendP4(&machine, oom_owner, types.p4.dynamic);
            const oom_freed = lookasideContains(&db, oom_owner);
            const oom_operation_type = machine.aOp.?[@intCast(oom_address)].p4type;
            const oom_state = db.mallocFailed;
            builder.db_allocator.oomClear(&db);
            std.debug.print("{s}\t{d}\tP4APPEND\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(pointer_identity), owner_type, @intFromBool(normal_freed), @intFromBool(oom_freed), oom_operation_type, oom_state });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "P4FREEOPS")) {
            const operation_raw = builder.db_allocator.mallocZero(&db, 2 * @sizeOf(types.VdbeOp)).?;
            const operations: [*]types.VdbeOp = @ptrCast(@alignCast(operation_raw));
            const first = builder.db_allocator.mallocRawNN(&db, 32).?;
            const second = builder.db_allocator.mallocRawNN(&db, 32).?;
            operations[0].p4type = types.p4.dynamic;
            operations[0].p4.p = first;
            operations[1].p4type = types.p4.dynamic;
            operations[1].p4.p = second;
            builder.freeOperationArray(&db, operations, 2);
            std.debug.print("{s}\t{d}\tP4FREEOPS\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(lookasideContains(&db, first)), @intFromBool(lookasideContains(&db, second)), @intFromBool(lookasideContains(&db, operations)) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "VDBEDELETE")) {
            var owner_parse = std.mem.zeroes(types.Parse);
            owner_parse.db = @ptrCast(&db);
            const created = builder.create(&owner_parse).?;
            const address = builder.addOperation0(created, .Noop);
            const p4_owner = builder.db_allocator.mallocRawNN(&db, 32).?;
            created.aOp.?[@intCast(address)].p4type = types.p4.dynamic;
            created.aOp.?[@intCast(address)].p4.p = p4_owner;
            const operation_array = created.aOp.?;
            builder.deleteVdbe(created);
            std.debug.print("{s}\t{d}\tVDBEDELETE\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(lookasideContains(&db, p4_owner)), @intFromBool(lookasideContains(&db, operation_array)), @intFromBool(lookasideContains(&db, created)), @intFromBool(db.pVdbe == null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "KEYNEW")) {
            const raw = builder.db_allocator.mallocRawNN(&db, types.keyInfoSize(0));
            if (raw) |allocation| {
                key_info = @ptrCast(@alignCast(allocation));
                @memset(@as([*]u8, @ptrCast(allocation))[0..types.keyInfoSize(0)], 0);
                key_info.?.nRef = 1;
                key_info.?.db = &db;
            }
            std.debug.print("{s}\t{d}\tKEYNEW\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(key_info != null), if (key_info) |key| key.nRef else 0, @intFromBool(if (key_info) |key| key.db == &db else false) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "KEYREF")) {
            const before = key_info;
            const result = builder.keyInfoRef(key_info);
            std.debug.print("{s}\t{d}\tKEYREF\t{d}\t{d}\t{d}\n", .{ case_name, sequence, @intFromBool(result != null), @intFromBool(result == before), if (result) |key| key.nRef else 0 });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "KEYUNREF")) {
            const before = if (key_info) |key| key.nRef else 0;
            if (key_info) |key| {
                if (before == 1) key_info = null;
                builder.keyInfoUnref(key);
            }
            std.debug.print("{s}\t{d}\tKEYUNREF\t{d}\t{d}\t{d}\n", .{ case_name, sequence, before, if (key_info) |key| key.nRef else 0, @intFromBool(key_info != null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "KEYNULL")) {
            builder.keyInfoUnref(null);
            std.debug.print("{s}\t{d}\tKEYNULL\t{d}\n", .{ case_name, sequence, @intFromBool(builder.keyInfoRef(null) != null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "FINALIZE")) {
            var maximum = try parseInt(try next(&tokens));
            const inspect_index = try parseInt(try next(&tokens));
            builder.resolveP2Values(&machine, &maximum);
            std.debug.print("{s}\t{d}\tFINALIZE\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, maximum, inspect_index, machine.aOp.?[@intCast(inspect_index)].p2, @intFromBool(machine.flags.readOnly), @intFromBool(machine.flags.bIsReader), parse.nLabel, @intFromBool(parse.aLabel != null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "TAKE")) {
            var maximum = try parseInt(try next(&tokens));
            const inspect_index = try parseInt(try next(&tokens));
            const before_array = machine.aOp;
            detached_operations = builder.takeOperationArray(&machine, &detached_operation_count, &maximum);
            std.debug.print("{s}\t{d}\tTAKE\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ case_name, sequence, maximum, inspect_index, detached_operation_count, @intFromBool(machine.aOp == null), @intFromBool(detached_operations == before_array), detached_operations.?[@intCast(inspect_index)].p2, parse.nLabel, @intFromBool(parse.aLabel != null) });
            sequence += 1;
            continue;
        }
        if (std.mem.eql(u8, command, "ADDLIST")) {
            const compact = [_]types.VdbeOpList{
                .{ .opcode = .Integer, .p1 = 7, .p2 = 0, .p3 = 1 },
                .{ .opcode = .Goto, .p1 = 0, .p2 = 1, .p3 = 0 },
                .{ .opcode = .Noop, .p1 = 0, .p2 = 0, .p3 = 0 },
            };
            const base = machine.nOp;
            const first = builder.addOperationList(&machine, compact.len, &compact, 100);
            std.debug.print("{s}\t{d}\tADDLIST\t{d}\t{d}\t{d}\t{d}", .{ case_name, sequence, @intFromBool(first != null), machine.nOp, machine.nOpAlloc, @intFromBool(if (first) |operations| operations == machine.aOp.? + @as(usize, @intCast(base)) else false) });
            for (0..compact.len) |index| {
                if (first) |operations| {
                    const operation = operations[index];
                    std.debug.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{ @intFromEnum(operation.opcode), operation.p1, operation.p2, operation.p3, operation.p4type, operation.p5 });
                } else std.debug.print("\t-1\t-1\t-1\t-1\t-1\t-1", .{});
            }
            std.debug.print("\n", .{});
            sequence += 1;
            continue;
        }

        const opcode = try operationCode(try next(&tokens));
        const operation_count_before = machine.nOp;
        const address = if (std.mem.eql(u8, command, "ADD0"))
            builder.addOperation0(&machine, opcode)
        else if (std.mem.eql(u8, command, "ADD1"))
            builder.addOperation1(&machine, opcode, try parseInt(try next(&tokens)))
        else if (std.mem.eql(u8, command, "ADD2"))
            builder.addOperation2(&machine, opcode, try parseInt(try next(&tokens)), try parseInt(try next(&tokens)))
        else if (std.mem.eql(u8, command, "ADD3"))
            builder.addOperation3(&machine, opcode, try parseInt(try next(&tokens)), try parseInt(try next(&tokens)), try parseInt(try next(&tokens)))
        else if (std.mem.eql(u8, command, "ADD4INT"))
            builder.addOperation4Int(&machine, opcode, try parseInt(try next(&tokens)), try parseInt(try next(&tokens)), try parseInt(try next(&tokens)), try parseInt(try next(&tokens)))
        else
            return error.UnknownCommand;
        observation(case_name, sequence, address, operation_count_before, &machine, &parse);
        sequence += 1;
    }
}
