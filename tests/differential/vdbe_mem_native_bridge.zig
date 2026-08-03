const std = @import("std");
const module = @import("vdbe_mem");
const mem = module.vdbe_mem;
const db_allocator = module.db_allocator;
const vdbe_aux = module.vdbe_aux;
const memory = module.memory;

fn startTestProcessManager() void {
    if (!memory.process_manager.started) std.debug.assert(memory.process_manager.start() == memory.ok);
}

export fn probe_real_to_i64(bits: u64) callconv(.c) i64 {
    return mem.realToI64(@bitCast(bits));
}

export fn probe_real_same_as_int(bits: u64, integer: i64) callconv(.c) c_int {
    return @intFromBool(mem.realSameAsInt(@bitCast(bits), integer));
}

export fn probe_int_float_compare(integer: i64, bits: u64) callconv(.c) c_int {
    return mem.intFloatCompare(integer, @bitCast(bits));
}

fn inputMem(flags: u16, union_bits: u64, encoding: u8, data: ?[*]u8, length: usize) mem.types.Mem {
    var value: mem.types.Mem = undefined;
    @memset(std.mem.asBytes(&value), 0);
    value.flags = flags;
    value.u.i = @bitCast(union_bits);
    value.enc = encoding;
    value.z = data;
    value.n = @intCast(length);
    return value;
}

export fn probe_serial_type_len(serial_type: u32) callconv(.c) u32 {
    return mem.serialTypeLen(serial_type);
}

export fn probe_one_byte_serial_type_len(serial_type: u8) callconv(.c) u8 {
    return mem.oneByteSerialTypeLen(serial_type);
}

export fn probe_serial_get(bytes: [*]const u8, serial_type: u32, output_flags: *u16, output_union: *u64, output_length: *c_int, output_alias: *c_int) callconv(.c) void {
    var value: mem.types.Mem = undefined;
    @memset(std.mem.asBytes(&value), 0xa5);
    mem.serialGet(bytes, serial_type, &value);
    output_flags.* = value.flags;
    output_union.* = @bitCast(value.u.i);
    output_length.* = value.n;
    output_alias.* = @intFromBool(value.z == @as([*]u8, @constCast(bytes)));
}

export fn probe_int_value(flags: u16, union_bits: u64, encoding: u8, data: ?[*]u8, length: usize) callconv(.c) i64 {
    const value = inputMem(flags, union_bits, encoding, data, length);
    return mem.intValue(&value);
}

export fn probe_integerify(flags: u16, union_bits: u64, encoding: u8, data: ?[*]u8, length: usize, output_flags: *u16, output_union: *u64) callconv(.c) c_int {
    var value = inputMem(flags, union_bits, encoding, data, length);
    const result = mem.integerify(&value);
    output_flags.* = value.flags;
    output_union.* = @bitCast(value.u.i);
    return result;
}

export fn probe_integer_affinity(flags: u16, union_bits: u64, output_flags: *u16, output_union: *u64) callconv(.c) void {
    var value = inputMem(flags, union_bits, 0, null, 0);
    mem.integerAffinity(&value);
    output_flags.* = value.flags;
    output_union.* = @bitCast(value.u.i);
}

export fn probe_noop_destructor(address: usize) callconv(.c) usize {
    mem.noOpDestructor(if (address == 0) null else @ptrFromInt(address));
    return address;
}

export fn probe_mem_init(flags: u16, db_address: usize, output: [*]u8) callconv(.c) void {
    var value: mem.types.Mem = undefined;
    @memset(std.mem.asBytes(&value), 0xa5);
    const db: ?*mem.types.Sqlite3 = if (db_address == 0) null else @ptrFromInt(db_address);
    mem.init(&value, db, flags);
    @memcpy(output[0..@sizeOf(mem.types.Mem)], std.mem.asBytes(&value));
}

var lifecycle_destructor_count: usize = 0;
fn lifecycleDestructor(pointer: ?*anyopaque) callconv(.c) void {
    if (pointer != null) lifecycle_destructor_count += 1;
}
fn publicFreeDestructor(_: ?*anyopaque) callconv(.c) void {}
fn lifecycleCompare(_: ?*anyopaque, first_length: c_int, first: ?*const anyopaque, second_length: c_int, second: ?*const anyopaque) callconv(.c) c_int {
    const common: usize = @intCast(@min(first_length, second_length));
    const first_bytes: [*]const u8 = @ptrCast(first.?);
    const second_bytes: [*]const u8 = @ptrCast(second.?);
    for (first_bytes[0..common], second_bytes[0..common]) |left, right| {
        if (left != right) return @as(c_int, left) - right;
    }
    return first_length - second_length;
}
fn lifecycleFinalize(context: ?*mem.types.Context) callconv(.c) void {
    const value = context.?.pOut.?;
    value.u.i = 77;
    value.flags = mem.types.mem_flag.integer;
    context.?.isError = 19;
}
fn lifecycleValue(context: ?*mem.types.Context) callconv(.c) void {
    const value = context.?.pOut.?;
    value.u.i = 88;
    value.flags = mem.types.mem_flag.integer;
    context.?.isError = 23;
}

export fn probe_mem_lifecycle(scenario: c_uint, output: *[16]u64) callconv(.c) void {
    @memset(output, 0);
    var db: mem.types.Sqlite3 = std.mem.zeroes(mem.types.Sqlite3);
    var value: mem.types.Mem = std.mem.zeroes(mem.types.Mem);
    var other: mem.types.Mem = std.mem.zeroes(mem.types.Mem);
    var function: mem.types.FuncDef = std.mem.zeroes(mem.types.FuncDef);
    var bytes = [_]u8{0} ** 32;
    lifecycle_destructor_count = 0;
    startTestProcessManager();
    switch (scenario) {
        0 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            mem.setNull(&value);
            output[0] = lifecycle_destructor_count;
            output[1] = value.flags;
        },
        1 => {
            const before = memory.process_manager.status(.memory_used, false).current;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            const allocation = memory.process_manager.alloc(17).?;
            value.zMalloc = @ptrCast(allocation);
            value.szMalloc = @intCast(memory.process_manager.size(allocation));
            mem.release(&value);
            output[0] = lifecycle_destructor_count;
            output[1] = value.flags;
            output[2] = @intCast(value.szMalloc);
            output[3] = @intFromBool(value.z == null);
            output[4] = @intFromBool(memory.process_manager.status(.memory_used, false).current == before);
        },
        2 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            mem.setZeroBlob(&value, 12);
            output[0] = lifecycle_destructor_count;
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = @intCast(value.u.nZero);
            output[4] = value.enc;
            output[5] = @intFromBool(value.z == null);
        },
        3 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            mem.setInt64(&value, -42);
            output[0] = lifecycle_destructor_count;
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
        },
        4 => {
            value.flags = mem.types.mem_flag.null_;
            mem.setDouble(&value, 4.5);
            output[0] = value.flags;
            output[1] = @bitCast(value.u.r);
            mem.setDouble(&value, @bitCast(@as(u64, 0x7ff8_0000_0000_0001)));
            output[2] = value.flags;
        },
        5 => {
            value.flags = mem.types.mem_flag.null_;
            mem.setPointer(&value, &bytes, "probe", lifecycleDestructor);
            output[0] = value.flags;
            output[1] = value.eSubtype;
            output[2] = @intFromBool(std.mem.eql(u8, std.mem.span(value.u.zPType.?), "probe"));
            output[3] = @intFromBool(value.z == @as([*]u8, @ptrCast(&bytes)));
            mem.setNull(&value);
            output[4] = lifecycle_destructor_count;
            output[5] = value.flags;
        },
        6 => {
            value.flags = mem.types.mem_flag.null_;
            other.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            other.z = &bytes;
            other.n = 7;
            mem.shallowCopy(&value, &other, mem.types.mem_flag.ephemeral);
            output[0] = value.flags;
            output[1] = @intFromBool(value.z == @as([*]u8, @ptrCast(&bytes)));
            output[2] = @intCast(value.n);
        },
        7 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            other.flags = mem.types.mem_flag.integer;
            other.u.i = 123;
            mem.move(&value, &other);
            output[0] = lifecycle_destructor_count;
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
            output[3] = other.flags;
            output[4] = @intCast(other.szMalloc);
        },
        8 => {
            db.aLimit[0] = 5;
            value.db = &db;
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero;
            value.n = 4;
            value.u.nZero = 3;
            output[0] = @intFromBool(mem.tooBig(&value));
            value.u.nZero = 1;
            output[1] = @intFromBool(mem.tooBig(&value));
        },
        9 => {
            db.enc = 1;
            function.xFinalize = lifecycleFinalize;
            value.db = &db;
            value.flags = mem.types.mem_flag.aggregate;
            value.u.pDef = &function;
            output[0] = @intCast(mem.finalize(&value, &function));
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
        },
        10 => {
            db.enc = 1;
            function.xValue = lifecycleValue;
            value.db = &db;
            value.flags = mem.types.mem_flag.aggregate;
            value.u.pDef = &function;
            other.db = &db;
            other.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.aggregateValue(&value, &other, &function));
            output[1] = other.flags;
            output[2] = @bitCast(other.u.i);
        },
        11 => {
            @memcpy(bytes[0..3], "abc");
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &bytes;
            value.n = 3;
            output[0] = @intCast(mem.grow(&value, 16, true));
            output[1] = value.flags;
            output[2] = @intFromBool(value.z == value.zMalloc);
            output[3] = @intFromBool(value.szMalloc >= 16);
            output[4] = @intFromBool(std.mem.eql(u8, value.z.?[0..3], "abc"));
            mem.release(&value);
        },
        12 => {
            @memcpy(bytes[0..3], "abc");
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.n = 3;
            value.xDel = lifecycleDestructor;
            output[0] = @intCast(mem.grow(&value, 16, true));
            output[1] = lifecycle_destructor_count;
            output[2] = value.flags;
            output[3] = @intFromBool(std.mem.eql(u8, value.z.?[0..3], "abc"));
            mem.release(&value);
        },
        13 => {
            const allocation = memory.process_manager.alloc(32).?;
            value.zMalloc = @ptrCast(allocation);
            value.szMalloc = @intCast(memory.process_manager.size(allocation));
            value.flags = mem.types.mem_flag.integer | mem.types.mem_flag.string;
            value.u.i = 44;
            output[0] = @intCast(mem.clearAndResize(&value, 16));
            output[1] = value.flags;
            output[2] = @intFromBool(value.z == value.zMalloc);
            output[3] = @bitCast(value.u.i);
            mem.release(&value);
        },
        14 => {
            @memcpy(bytes[0..3], "abc");
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &bytes;
            value.n = 3;
            value.enc = 1;
            output[0] = @intCast(mem.nulTerminate(&value));
            output[1] = value.flags;
            output[2] = @intFromBool(value.z == value.zMalloc);
            output[3] = value.z.?[3];
            output[4] = value.z.?[4];
            mem.release(&value);
        },
        15 => {
            const allocation = memory.process_manager.alloc(8).?;
            value.zMalloc = @ptrCast(allocation);
            value.z = value.zMalloc;
            value.szMalloc = @intCast(memory.process_manager.size(allocation));
            value.n = 3;
            value.enc = 1;
            value.flags = mem.types.mem_flag.string;
            @memcpy(value.z.?[0..3], "abc");
            output[0] = @intFromBool(mem.zeroTerminateIfAble(&value));
            output[1] = value.flags;
            output[2] = value.z.?[3];
            mem.release(&value);
        },
        16 => {
            @memcpy(bytes[0..2], "ab");
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero | mem.types.mem_flag.ephemeral;
            value.z = &bytes;
            value.n = 2;
            value.u.nZero = 3;
            output[0] = @intCast(mem.expandBlob(&value));
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = value.z.?[0];
            output[4] = value.z.?[1];
            output[5] = value.z.?[2];
            output[6] = value.z.?[4];
            mem.release(&value);
        },
        17 => {
            @memcpy(bytes[0..3], "abc");
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &bytes;
            value.n = 3;
            value.enc = 1;
            output[0] = @intCast(mem.makeWriteable(&value));
            output[1] = value.flags;
            output[2] = @intFromBool(value.z == value.zMalloc);
            output[3] = value.z.?[3];
            mem.release(&value);
        },
        18 => {
            const manager = memory.ensureProcessManager();
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            db = allocatorDb();
            @memcpy(bytes[0..3], "abc");
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &bytes;
            value.n = 3;
            output[0] = @intCast(mem.grow(&value, 4096, true));
            output[1] = value.flags;
            output[2] = @intCast(value.szMalloc);
            output[3] = @intFromBool(value.z == null);
            output[4] = db.mallocFailed;
            _ = manager.setHardLimit(0);
            db_allocator.oomClear(&db);
        },
        19 => {
            var source_bytes = [_]u8{ 'c', 'o', 'p', 'y', 0, 0, 0, 0 };
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            const allocation = memory.process_manager.alloc(16).?;
            value.zMalloc = @ptrCast(allocation);
            value.szMalloc = @intCast(memory.process_manager.size(allocation));
            other.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            other.z = &source_bytes;
            other.n = 4;
            other.enc = 1;
            output[0] = @intCast(mem.copy(&value, &other));
            output[1] = lifecycle_destructor_count;
            output[2] = value.flags;
            output[3] = @intFromBool(value.z == value.zMalloc);
            output[4] = @intFromBool(std.mem.eql(u8, value.z.?[0..4], "copy"));
            output[5] = value.z.?[4];
            mem.release(&value);
        },
        20 => {
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            output[0] = @intCast(mem.setText(&value, null, 0, .transient));
            output[1] = lifecycle_destructor_count;
            output[2] = value.flags;
        },
        21 => {
            var source_bytes = [_]u8{ 't', 'e', 'x', 't', 0, 0, 0, 0 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setText(&value, &source_bytes, -1, .transient));
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = value.enc;
            output[4] = @intFromBool(value.z == value.zMalloc);
            output[5] = @intFromBool(std.mem.eql(u8, value.z.?[0..5], "text\x00"));
            mem.release(&value);
        },
        22 => {
            var source_bytes = [_]u8{ 'v', 'a', 'l', 'u', 'e', 0, 0, 0 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setText(&value, &source_bytes, 3, .transient));
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = value.z.?[3];
            mem.release(&value);
        },
        23 => {
            var source_bytes = [_]u8{ 'a', 'l', 'i', 'a', 's', 0, 0, 0 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setText(&value, &source_bytes, 5, .static));
            output[1] = value.flags;
            output[2] = @intFromBool(value.z == @as([*]u8, @ptrCast(&source_bytes)));
            output[3] = @intCast(value.n);
        },
        24 => {
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            @memcpy(bytes[0..5], "owned");
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setText(&value, &bytes, 5, .{ .custom = lifecycleDestructor }));
            output[1] = value.flags;
            mem.release(&value);
            output[2] = lifecycle_destructor_count;
            output[3] = @intFromBool(value.z == null);
        },
        25 => {
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            const allocation = db_allocator.mallocRawNN(&db, 12).?;
            const source: [*]u8 = @ptrCast(allocation);
            @memcpy(source[0..7], "dynamic");
            output[0] = @intCast(mem.setText(&value, source, 7, .dynamic));
            output[1] = value.flags;
            output[2] = @intFromBool(value.z == value.zMalloc);
            output[3] = @intFromBool(value.szMalloc >= 12);
            mem.release(&value);
            output[4] = @intFromBool(value.z == null);
        },
        26 => {
            db = allocatorDb();
            db.aLimit[0] = 3;
            @memcpy(bytes[0..5], "large");
            value.db = &db;
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 1;
            output[0] = @intCast(mem.setText(&value, &bytes, 5, .{ .custom = lifecycleDestructor }));
            output[1] = lifecycle_destructor_count;
            output[2] = value.flags;
        },
        27 => {
            const manager = memory.ensureProcessManager();
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            output[0] = @intCast(mem.setText(&value, "oom", 3, .transient));
            output[1] = value.flags;
            output[2] = @intCast(value.szMalloc);
            output[3] = @intFromBool(value.z == null);
            output[4] = db.mallocFailed;
            _ = manager.setHardLimit(0);
            db_allocator.oomClear(&db);
        },
        28 => {
            var source_bytes = [_]u8{ 0x41, 0xe2, 0x82, 0xac, 0xf0, 0x9f, 0x98, 0x80 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 8;
            value.enc = 1;
            output[0] = @intCast(mem.translate(&value, 2));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            for (0..@min(@as(usize, @intCast(value.n)), 10)) |i| output[4 + i] = value.z.?[i];
            mem.release(&value);
        },
        29 => {
            var source_bytes = [_]u8{ 0x41, 0, 0xac, 0x20, 0x3d, 0xd8, 0, 0xde };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 8;
            value.enc = 2;
            output[0] = @intCast(mem.translate(&value, 1));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            for (0..@min(@as(usize, @intCast(value.n)), 10)) |i| output[4 + i] = value.z.?[i];
            mem.release(&value);
        },
        30 => {
            var source_bytes = [_]u8{ 0x41, 0, 0xac, 0x20 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 4;
            value.enc = 2;
            output[0] = @intCast(mem.translate(&value, 3));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = value.z.?[0];
            output[4] = value.z.?[1];
            output[5] = value.z.?[2];
            output[6] = value.z.?[3];
            mem.release(&value);
        },
        31 => {
            value.flags = mem.types.mem_flag.integer;
            value.enc = 1;
            value.u.i = 9;
            output[0] = @intCast(mem.changeEncoding(&value, 3));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @bitCast(value.u.i);
        },
        32 => {
            var source_bytes = [_]u8{ 0xfe, 0xff, 0, 0x41, 0, 0 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            value.z = &source_bytes;
            value.n = 4;
            value.enc = 2;
            output[0] = @intCast(mem.handleBom(&value));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = value.z.?[0];
            output[5] = value.z.?[1];
            output[6] = @intFromBool(value.z == value.zMalloc);
            mem.release(&value);
        },
        33 => {
            var source_bytes = [_]u8{ 1, 2, 3, 0 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setStr(&value, &source_bytes, 3, 0, .transient));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = value.z.?[0];
            output[5] = value.z.?[2];
            mem.release(&value);
        },
        34 => {
            var source_bytes = [_]u8{ 0xff, 0xfe, 0x41, 0, 0, 0 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setStr(&value, &source_bytes, -1, 2, .transient));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = value.z.?[0];
            output[5] = value.z.?[1];
            mem.release(&value);
        },
        35 => {
            var source_bytes = [_]u8{ 0, 0x41, 0, 0x42 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.setStr(&value, &source_bytes, 4, 3, .{ .custom = lifecycleDestructor }));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            mem.release(&value);
            output[4] = lifecycle_destructor_count;
        },
        36 => {
            const manager = memory.ensureProcessManager();
            var source_bytes = [_]u8{ 'a', 'b', 'c' };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 3;
            value.enc = 1;
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            output[0] = @intCast(mem.translate(&value, 2));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intFromBool(value.z == @as([*]u8, @ptrCast(&source_bytes)));
            output[4] = db.mallocFailed;
            _ = manager.setHardLimit(0);
            db_allocator.oomClear(&db);
        },
        37 => {
            var source_bytes = [_]u8{ ' ', '1', '.', '2', '5', 'e', '2', ' ', 0, 0 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.terminated | mem.types.mem_flag.static;
            value.z = &source_bytes;
            value.n = 9;
            value.enc = 1;
            var real: f64 = undefined;
            output[0] = @as(u32, @bitCast(mem.realValueRC(&value, &real)));
            output[1] = @bitCast(real);
        },
        38 => {
            var source_bytes = [_]u8{ '4', '.', '5', 'x' };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 4;
            value.enc = 1;
            var real: f64 = undefined;
            output[0] = @as(u32, @bitCast(mem.realValueRC(&value, &real)));
            output[1] = @bitCast(real);
            output[2] = value.flags;
        },
        39 => {
            var source_bytes = [_]u8{ '4', 0, '.', 0, '5', 0 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 6;
            value.enc = 2;
            var real: f64 = undefined;
            output[0] = @as(u32, @bitCast(mem.realValueRC(&value, &real)));
            output[1] = @bitCast(real);
        },
        40 => {
            var source_bytes = [_]u8{ '4', 1, '2', 0 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 4;
            value.enc = 2;
            var real: f64 = undefined;
            output[0] = @as(u32, @bitCast(mem.realValueRC(&value, &real)));
            output[1] = @bitCast(real);
        },
        41 => {
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 9_007_199_254_740_991;
            output[0] = @bitCast(mem.realValue(&value));
        },
        42 => {
            var source_bytes = [_]u8{ '0', 0 };
            value.flags = mem.types.mem_flag.null_;
            output[0] = @intCast(mem.booleanValue(&value, 7));
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.terminated | mem.types.mem_flag.static;
            value.z = &source_bytes;
            value.n = 1;
            value.enc = 1;
            output[1] = @intCast(mem.booleanValue(&value, 7));
            source_bytes[0] = '2';
            output[2] = @intCast(mem.booleanValue(&value, 7));
        },
        43 => {
            var source_bytes = [_]u8{ '4', '.', '5', 0 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.terminated | mem.types.mem_flag.static;
            value.z = &source_bytes;
            value.n = 3;
            value.enc = 1;
            output[0] = @intCast(mem.realify(&value));
            output[1] = value.flags;
            output[2] = @bitCast(value.u.r);
        },
        44...47 => {
            const text: [*:0]const u8 = switch (scenario) {
                44 => "42x",
                45 => "4.5",
                46 => "4.0",
                else => "abc",
            };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.terminated | mem.types.mem_flag.static;
            value.z = @constCast(text);
            value.n = @intCast(std.mem.len(text));
            value.enc = 1;
            output[0] = @intCast(mem.numerify(&value));
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
        },
        48 => {
            var source_bytes = [_]u8{ '4', 0, '2', 0 };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 4;
            value.enc = 2;
            output[0] = @intCast(mem.numerify(&value));
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
        },
        49...54 => {
            const reals = [_]f64{ 4.5, 1.0, 1e100, 1.2345678901234567 };
            db = allocatorDb();
            db.nFpDigit = 17;
            value.db = &db;
            if (scenario == 49) {
                value.flags = mem.types.mem_flag.integer;
                value.u.i = -9_223_372_036_854_775_807;
            } else if (scenario == 50) {
                value.flags = mem.types.mem_flag.integer_real;
                value.u.i = 42;
            } else {
                value.flags = mem.types.mem_flag.real;
                value.u.r = reals[scenario - 51];
            }
            output[0] = @intCast(mem.stringify(&value, 1, scenario == 54));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            for (0..@min(@as(usize, @intCast(value.n + 1)), 12)) |i| output[4 + i] = value.z.?[i];
            mem.release(&value);
        },
        55 => {
            db = allocatorDb();
            db.nFpDigit = 17;
            value.db = &db;
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 42;
            const text = mem.valueText(&value, 1);
            output[0] = @intFromBool(text != null);
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = text.?[0];
            output[4] = text.?[1];
            output[5] = text.?[2];
            mem.release(&value);
        },
        56 => {
            var source_bytes = [_]u8{ 'a', 'b' };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero | mem.types.mem_flag.ephemeral;
            value.z = &source_bytes;
            value.n = 2;
            value.u.nZero = 3;
            value.enc = 1;
            const text = mem.valueText(&value, 1);
            output[0] = @intFromBool(text != null);
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = text.?[0];
            output[4] = text.?[1];
            output[5] = text.?[2];
            output[6] = text.?[4];
            output[7] = text.?[5];
            mem.release(&value);
        },
        57 => {
            var source_bytes = [_]u8{ 'a', 0, 'b', 0 };
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            value.z = &source_bytes;
            value.n = 4;
            value.enc = 2;
            output[0] = @intCast(mem.valueBytes(&value, 3));
            output[1] = value.enc;
            output[2] = value.flags;
        },
        58 => {
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero;
            value.n = 2;
            value.u.nZero = 5;
            output[0] = @intCast(mem.valueBytes(&value, 1));
        },
        59 => {
            const before = memory.process_manager.status(.memory_used, false).current;
            db = allocatorDb();
            const created = mem.valueNew(&db);
            output[0] = @intFromBool(created != null);
            output[1] = created.?.flags;
            output[2] = @intFromBool(created.?.db == &db);
            mem.valueFree(created);
            output[3] = @intFromBool(memory.process_manager.status(.memory_used, false).current == before);
        },
        60 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            output[0] = @intFromBool(mem.valueIsOfClass(&value, lifecycleDestructor));
            output[1] = @intFromBool(mem.valueIsOfClass(&value, publicFreeDestructor));
        },
        61 => {
            var source_bytes = [_]u8{ 'x', 'y', 'z', 0 };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            mem.valueSetStr(&value, 3, &source_bytes, 1, .transient);
            output[0] = value.flags;
            output[1] = @intCast(value.n);
            output[2] = value.z.?[0];
            output[3] = value.z.?[2];
            mem.release(&value);
        },
        62, 63 => {
            const text: [*:0]const u8 = if (scenario == 62) "48.00" else "x";
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.terminated | mem.types.mem_flag.static;
            value.z = @constCast(text);
            value.n = @intCast(std.mem.len(text));
            value.enc = 1;
            mem.valueApplyAffinity(&value, 0x43, 1);
            output[0] = value.flags;
            output[1] = @bitCast(value.u.i);
        },
        64 => {
            db = allocatorDb();
            db.nFpDigit = 17;
            value.db = &db;
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 42;
            mem.valueApplyAffinity(&value, 0x42, 1);
            output[0] = value.flags;
            output[1] = @intCast(value.n);
            output[2] = value.z.?[0];
            output[3] = value.z.?[1];
            mem.release(&value);
        },
        65 => {
            value.flags = mem.types.mem_flag.real;
            value.u.r = 4.0;
            mem.valueApplyAffinity(&value, 0x45, 1);
            output[0] = value.flags;
            output[1] = @bitCast(value.u.i);
        },
        66...71 => {
            const texts = [_][*:0]const u8{ "", "48.00", "4.5", "4.5", "ab", "" };
            const affinities = [_]u8{ 0x41, 0x43, 0x44, 0x45, 0x42, 0x42 };
            db = allocatorDb();
            db.nFpDigit = 17;
            value.db = &db;
            const index: usize = scenario - 66;
            if (scenario == 66) {
                value.flags = mem.types.mem_flag.integer;
                value.u.i = 42;
            } else if (scenario == 71) {
                value.flags = mem.types.mem_flag.null_;
            } else {
                const text = texts[index];
                value.flags = (if (scenario == 70) mem.types.mem_flag.blob else mem.types.mem_flag.string) |
                    mem.types.mem_flag.terminated | mem.types.mem_flag.static;
                value.z = @constCast(text);
                value.n = @intCast(std.mem.len(text));
                value.enc = 1;
            }
            output[0] = @intCast(mem.cast(&value, affinities[index], if (scenario == 70) 2 else 1));
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = @bitCast(value.u.i);
            if (value.z != null and value.flags & (mem.types.mem_flag.string | mem.types.mem_flag.blob) != 0) {
                output[5] = value.z.?[0];
                output[6] = value.z.?[1];
            }
            mem.release(&value);
        },
        72 => {
            var array: [3]mem.types.Mem = undefined;
            @memset(std.mem.asBytes(&array), 0xa5);
            db = allocatorDb();
            mem.initArray(&array, 3, &db, mem.types.mem_flag.null_);
            output[0] = array[0].flags;
            output[1] = array[1].flags;
            output[2] = array[2].flags;
            output[3] = @intFromBool(array[0].db == &db);
            output[4] = @intFromBool(array[2].db == &db);
            output[5] = @intCast(array[0].szMalloc);
            output[6] = @intCast(array[2].szMalloc);
        },
        73 => {
            var array = std.mem.zeroes([3]mem.types.Mem);
            db = allocatorDb();
            const before = memory.process_manager.status(.memory_used, false).current;
            array[0].db = &db;
            array[0].flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            array[0].z = &bytes;
            array[0].xDel = lifecycleDestructor;
            array[1].db = &db;
            array[1].flags = mem.types.mem_flag.string;
            const allocation = db_allocator.mallocRawNN(&db, 16).?;
            array[1].zMalloc = @ptrCast(allocation);
            array[1].z = array[1].zMalloc;
            array[1].szMalloc = @intCast(db_allocator.allocationSize(&db, allocation));
            array[2].db = &db;
            array[2].flags = mem.types.mem_flag.integer;
            array[2].u.i = 7;
            mem.releaseArray(&array, 3);
            output[0] = lifecycle_destructor_count;
            output[1] = array[0].flags;
            output[2] = array[1].flags;
            output[3] = @intCast(array[1].szMalloc);
            output[4] = array[2].flags;
            output[5] = @intFromBool(memory.process_manager.status(.memory_used, false).current == before);
        },
        74 => {
            var array = std.mem.zeroes([1]mem.types.Mem);
            db = allocatorDb();
            const allocation = db_allocator.mallocRawNN(&db, 17).?;
            array[0].db = &db;
            array[0].flags = mem.types.mem_flag.string;
            array[0].zMalloc = @ptrCast(allocation);
            array[0].z = array[0].zMalloc;
            array[0].szMalloc = @intCast(db_allocator.allocationSize(&db, allocation));
            var measured: c_int = 0;
            db.pnBytesFreed = &measured;
            mem.releaseArray(&array, 1);
            output[0] = @intCast(measured);
            output[1] = array[0].flags;
            output[2] = @intCast(array[0].szMalloc);
            db.pnBytesFreed = null;
            db_allocator.freeNN(&db, allocation);
        },
        75 => {
            value.flags = mem.types.mem_flag.null_;
            other.flags = mem.types.mem_flag.null_;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            other.flags = mem.types.mem_flag.integer;
            other.u.i = 0;
            output[1] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            output[2] = @as(u32, @bitCast(mem.compare(&other, &value, null)));
        },
        76 => {
            value.flags = mem.types.mem_flag.integer;
            value.u.i = -5;
            other.flags = mem.types.mem_flag.integer_real;
            other.u.i = 7;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            output[1] = @as(u32, @bitCast(mem.compare(&other, &value, null)));
            other.u.i = -5;
            output[2] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
        },
        77 => {
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 9_007_199_254_740_993;
            other.flags = mem.types.mem_flag.real;
            other.u.r = 9_007_199_254_740_992.0;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            output[1] = @as(u32, @bitCast(mem.compare(&other, &value, null)));
        },
        78 => {
            value.flags = mem.types.mem_flag.real;
            value.u.r = -1.5;
            other.flags = mem.types.mem_flag.real;
            other.u.r = 2.0;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            other.u.r = -1.5;
            output[1] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
        },
        79 => {
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 9;
            other.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            other.z = @constCast(@as([*:0]const u8, "0"));
            other.n = 1;
            other.enc = 1;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            output[1] = @as(u32, @bitCast(mem.compare(&other, &value, null)));
        },
        80 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            value.z = @constCast(@as([*:0]const u8, "z"));
            value.n = 1;
            value.enc = 1;
            other.flags = mem.types.mem_flag.blob | mem.types.mem_flag.static;
            other.z = @constCast(@as([*:0]const u8, "a"));
            other.n = 1;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, null)));
            output[1] = @as(u32, @bitCast(mem.compare(&other, &value, null)));
        },
        81 => {
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.static;
            value.z = @constCast(@as([*:0]const u8, "abc"));
            value.n = 3;
            other.flags = mem.types.mem_flag.blob | mem.types.mem_flag.static;
            other.z = @constCast(@as([*:0]const u8, "abd"));
            other.n = 3;
            output[0] = @as(u32, @bitCast(mem.blobCompare(&value, &other)));
            other.z = @constCast(@as([*:0]const u8, "abcx"));
            other.n = 4;
            output[1] = @as(u32, @bitCast(mem.blobCompare(&value, &other)));
        },
        82 => {
            var zeros = [_]u8{ 0, 0, 0 };
            var mixed = [_]u8{ 0, 1, 0 };
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero;
            value.n = 0;
            value.u.nZero = 3;
            other.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero;
            other.n = 0;
            other.u.nZero = 5;
            output[0] = @as(u32, @bitCast(mem.blobCompare(&value, &other)));
            other.flags = mem.types.mem_flag.blob | mem.types.mem_flag.static;
            other.z = &zeros;
            other.n = 3;
            output[1] = @as(u32, @bitCast(mem.blobCompare(&value, &other)));
            other.z = &mixed;
            output[2] = @as(u32, @bitCast(mem.blobCompare(&value, &other)));
        },
        83, 84 => {
            var collation = std.mem.zeroes(mem.types.CollSeq);
            db = allocatorDb();
            collation.enc = if (scenario == 83) 1 else 2;
            collation.xCmp = lifecycleCompare;
            value.db = &db;
            other.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            other.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            value.z = @constCast(@as([*:0]const u8, if (scenario == 83) "abc" else "a"));
            other.z = @constCast(@as([*:0]const u8, if (scenario == 83) "abd" else "b"));
            value.n = if (scenario == 83) 3 else 1;
            other.n = value.n;
            value.enc = 1;
            other.enc = 1;
            output[0] = @as(u32, @bitCast(mem.compare(&value, &other, &collation)));
            output[1] = value.flags;
            output[2] = other.flags;
        },
        85 => {
            const data = [_]u8{ 0xfe, 0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff };
            output[0] = @bitCast(mem.recordDecodeInt(1, &data));
            output[1] = @bitCast(mem.recordDecodeInt(2, &data));
            output[2] = @bitCast(mem.recordDecodeInt(6, &data));
            output[3] = @bitCast(mem.recordDecodeInt(8, &data));
            output[4] = @bitCast(mem.recordDecodeInt(9, &data));
        },
        86 => {
            var info = std.mem.zeroes(mem.types.KeyInfo);
            db = allocatorDb();
            info.db = &db;
            info.nKeyField = 2;
            const record = mem.allocUnpackedRecord(&info);
            const offset = @intFromPtr(record.?.aMem.?) - @intFromPtr(record.?);
            output[0] = @intFromBool(record != null);
            output[1] = @intFromBool(record.?.pKeyInfo == &info);
            output[2] = record.?.nField;
            output[3] = offset;
            output[4] = @intFromBool(offset & 7 == 0);
            db_allocator.freeNN(&db, record.?);
        },
        87 => {
            var info = std.mem.zeroes(mem.types.KeyInfo);
            db = allocatorDb();
            info.db = &db;
            info.nKeyField = 2;
            info.enc = 1;
            const record = mem.allocUnpackedRecord(&info).?;
            const key = [_]u8{ 4, 1, 15, 0, 0xfe, 'x' };
            mem.unpackRecord(&key, record);
            output[0] = @as(u8, @bitCast(record.default_rc));
            output[1] = record.nField;
            output[2] = record.aMem.?[0].flags;
            output[3] = @bitCast(record.aMem.?[0].u.i);
            output[4] = record.aMem.?[1].flags;
            output[5] = @intCast(record.aMem.?[1].n);
            output[6] = record.aMem.?[1].z.?[0];
            output[7] = record.aMem.?[2].flags;
            db_allocator.freeNN(&db, record);
        },
        88 => {
            const normal = [_]u8{ 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 };
            const nan_value = [_]u8{ 0x7f, 0xf8, 0, 0, 0, 0, 0, 1 };
            output[0] = @intCast(mem.serialGet7(&normal, &value));
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
            output[3] = @intCast(mem.serialGet7(&nan_value, &value));
            output[4] = value.flags;
            output[5] = @bitCast(value.u.i);
        },
        89...96 => {
            const KeyInfoWithCollations = extern struct {
                info: mem.types.KeyInfo,
                collations: [2]?*mem.types.CollSeq,
            };
            var key_wrap = std.mem.zeroes(KeyInfoWithCollations);
            var rhs = std.mem.zeroes([2]mem.types.Mem);
            var record = std.mem.zeroes(mem.types.UnpackedRecord);
            var sort_flags = [_]u8{ 0, 0 };
            const key = [_]u8{ 3, 1, 15, 5, 'b' };
            db = allocatorDb();
            key_wrap.info.db = &db;
            key_wrap.info.enc = 1;
            key_wrap.info.nKeyField = 2;
            key_wrap.info.nAllField = 2;
            key_wrap.info.aSortFlags = &sort_flags;
            rhs[0].db = &db;
            rhs[1].db = &db;
            rhs[0].flags = mem.types.mem_flag.integer;
            rhs[0].u.i = if (scenario == 89 or scenario == 90) 7 else 5;
            rhs[1].flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            rhs[1].z = @constCast(@as([*:0]const u8, if (scenario == 93) "b" else "a"));
            rhs[1].n = 1;
            rhs[1].enc = 1;
            record.pKeyInfo = &key_wrap.info;
            record.aMem = &rhs;
            record.nField = 2;
            record.default_rc = if (scenario == 93) -1 else 0;
            if (scenario == 90) sort_flags[0] = 1;
            const result: c_int = switch (scenario) {
                92 => mem.recordCompareWithSkip(5, &key, &record, true),
                94 => blk: {
                    record.nField = 1;
                    rhs[0].flags = mem.types.mem_flag.null_;
                    sort_flags[0] = 2;
                    break :blk mem.recordCompare(5, &key, &record);
                },
                95 => mem.recordCompare(4, &key, &record),
                96 => blk: {
                    record.nField = 1;
                    rhs[0].u.i = 7;
                    const comparison = mem.findRecordCompare(&record);
                    const comparison_result = comparison(5, &key, &record);
                    output[3] = @intFromBool(comparison == mem.recordCompareInt);
                    output[4] = @bitCast(@as(i64, record.r1));
                    output[5] = @bitCast(@as(i64, record.r2));
                    output[6] = @bitCast(record.u.i);
                    break :blk comparison_result;
                },
                else => mem.recordCompare(5, &key, &record),
            };
            output[0] = @as(u32, @bitCast(result));
            output[1] = record.errCode;
            output[2] = record.eqSeen;
        },
        97 => {
            var source = [_]u8{ 'a', 'b' };
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.blob | mem.types.mem_flag.zero | mem.types.mem_flag.ephemeral;
            value.z = &source;
            value.n = 2;
            value.u.nZero = 2;
            const result = mem.valueBlob(&value);
            output[0] = @intFromBool(result != null);
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = result.?[0];
            output[4] = result.?[3];
            mem.release(&value);
        },
        98 => {
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 0x1234567887654321;
            output[0] = @as(u32, @bitCast(mem.valueInt(&value)));
            output[1] = @bitCast(mem.valueInt64(&value));
            output[2] = @bitCast(mem.valueDouble(&value));
        },
        99 => {
            var marker: u8 = 0;
            value.flags = mem.types.mem_flag.null_ | mem.types.mem_flag.terminated | mem.types.mem_flag.subtype | mem.types.mem_flag.static;
            value.eSubtype = 'p';
            value.u.zPType = "kind";
            value.z = @ptrCast(&marker);
            output[0] = mem.valueSubtype(&value);
            output[1] = @intFromBool(mem.valuePointer(&value, "kind") == @as(*anyopaque, @ptrCast(&marker)));
            output[2] = @intFromBool(mem.valuePointer(&value, "other") == null);
        },
        100 => {
            const flags = [_]u16{ mem.types.mem_flag.null_, mem.types.mem_flag.integer, mem.types.mem_flag.real, mem.types.mem_flag.string, mem.types.mem_flag.blob, mem.types.mem_flag.integer_real };
            for (flags, 0..) |flag, index| {
                value.flags = flag;
                output[index] = @intCast(mem.valueType(&value));
            }
        },
        101 => {
            value.enc = 3;
            value.flags = mem.types.mem_flag.null_ | mem.types.mem_flag.zero | mem.types.mem_flag.from_bind;
            output[0] = @intCast(mem.valueEncoding(&value));
            output[1] = @intFromBool(mem.valueNoChange(&value));
            output[2] = @intFromBool(mem.valueFromBind(&value));
        },
        102 => {
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.terminated | mem.types.mem_flag.static;
            value.z = @constCast(@as([*:0]const u8, "48.0"));
            value.n = 4;
            value.enc = 1;
            output[0] = @intCast(mem.valueNumericType(&value));
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
        },
        103 => {
            const before = memory.process_manager.status(.memory_used, false).current;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static;
            value.z = @constCast(@as([*:0]const u8, "abc"));
            value.n = 3;
            value.enc = 1;
            const duplicate = mem.valueDuplicate(&value);
            output[0] = @intFromBool(duplicate != null);
            output[1] = duplicate.?.flags;
            output[2] = @intFromBool(duplicate.?.db == null);
            output[3] = @intFromBool(duplicate.?.z != value.z);
            output[4] = duplicate.?.z.?[1];
            mem.valueFree(duplicate);
            output[5] = @intFromBool(memory.process_manager.status(.memory_used, false).current == before);
        },
        104 => {
            var marker: u8 = 0;
            value.flags = mem.types.mem_flag.null_ | mem.types.mem_flag.terminated | mem.types.mem_flag.subtype | mem.types.mem_flag.static;
            value.eSubtype = 'p';
            value.u.zPType = "kind";
            value.z = @ptrCast(&marker);
            const duplicate = mem.valueDuplicate(&value);
            output[0] = @intFromBool(duplicate != null);
            output[1] = duplicate.?.flags;
            output[2] = @intFromBool(mem.valuePointer(duplicate.?, "kind") == null);
            mem.valueFree(duplicate);
        },
        105 => {
            var context = std.mem.zeroes(mem.types.Context);
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            value.db = &db;
            context.pOut = &value;
            mem.resultInt(&context, -7);
            output[0] = value.flags;
            output[1] = @bitCast(value.u.i);
            mem.resultInt64(&context, 0x1234567887654321);
            output[2] = value.flags;
            output[3] = @bitCast(value.u.i);
            mem.resultDouble(&context, 4.5);
            output[4] = value.flags;
            output[5] = @bitCast(value.u.r);
            mem.resultNull(&context);
            output[6] = value.flags;
        },
        106 => {
            var context = std.mem.zeroes(mem.types.Context);
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 3;
            context.pOut = &value;
            mem.resultSubtype(&context, 0x123);
            output[0] = value.flags;
            output[1] = value.eSubtype;
        },
        107 => {
            var context = std.mem.zeroes(mem.types.Context);
            var source = [_]u8{ 'a', 'b' };
            value = std.mem.zeroes(mem.types.Mem);
            other = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            other.db = &db;
            value.flags = mem.types.mem_flag.null_;
            other.flags = mem.types.mem_flag.string | mem.types.mem_flag.ephemeral;
            other.z = &source;
            other.n = 2;
            other.enc = 1;
            context.pOut = &value;
            context.enc = 2;
            mem.resultValue(&context, &other);
            output[0] = @intCast(context.isError);
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = value.z.?[0];
            output[5] = value.z.?[1];
            output[6] = @intFromBool(value.z != @as([*]u8, @ptrCast(&source)));
            mem.release(&value);
        },
        108 => {
            var context = std.mem.zeroes(mem.types.Context);
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            db.aLimit[0] = 10;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            output[0] = @intCast(mem.resultZeroBlob64(&context, 7));
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = @intCast(value.u.nZero);
            output[4] = @intCast(mem.resultZeroBlob64(&context, 11));
            output[5] = @intCast(context.isError);
        },
        109 => {
            var context = std.mem.zeroes(mem.types.Context);
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            context.enc = 2;
            mem.resultText(&context, "ab", 2, .transient);
            output[0] = @intCast(context.isError);
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = value.z.?[0];
            output[5] = value.z.?[1];
            mem.release(&value);
        },
        110 => {
            var context = std.mem.zeroes(mem.types.Context);
            var source = [_]u8{ 1, 2, 3 };
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            context.enc = 1;
            mem.resultBlob(&context, &source, 3, .transient);
            output[0] = @intCast(context.isError);
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = value.z.?[0];
            output[4] = value.z.?[2];
            mem.release(&value);
        },
        111 => {
            var context = std.mem.zeroes(mem.types.Context);
            var source = [_]u8{ 'a', 0, 'b', 0, 9 };
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            context.enc = 1;
            mem.resultText64(&context, &source, 5, 4, .transient);
            output[0] = @intCast(context.isError);
            output[1] = value.flags;
            output[2] = value.enc;
            output[3] = @intCast(value.n);
            output[4] = value.z.?[0];
            output[5] = value.z.?[1];
            mem.release(&value);
        },
        112 => {
            var context = std.mem.zeroes(mem.types.Context);
            var source16 = [_]u8{ 'e', 0, 'r', 0 };
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            mem.resultError(&context, "bad", 3);
            output[0] = @intCast(context.isError);
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            mem.resultError16(&context, &source16, 4);
            output[3] = @intCast(context.isError);
            output[4] = value.enc;
            output[5] = @intCast(value.n);
            mem.release(&value);
        },
        113 => {
            var context = std.mem.zeroes(mem.types.Context);
            var marker: u8 = 0;
            value = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 2;
            context.pOut = &value;
            mem.resultPointer(&context, &marker, "kind", lifecycleDestructor);
            output[0] = value.flags;
            output[1] = value.eSubtype;
            output[2] = @intFromBool(mem.valuePointer(&value, "kind") == @as(*anyopaque, @ptrCast(&marker)));
            mem.release(&value);
            output[3] = lifecycle_destructor_count;
        },
        114 => {
            var context = std.mem.zeroes(mem.types.Context);
            var function_def = std.mem.zeroes(mem.types.FuncDef);
            var user: u8 = 0;
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.null_ | mem.types.mem_flag.zero;
            function_def.pUserData = &user;
            context.pOut = &value;
            context.pFunc = &function_def;
            output[0] = @intFromBool(mem.userData(&context) == @as(*anyopaque, @ptrCast(&user)));
            output[1] = @intFromBool(mem.contextDatabase(&context) == &db);
            output[2] = @intFromBool(mem.virtualTableNoChange(&context));
        },
        115, 116 => {
            var context = std.mem.zeroes(mem.types.Context);
            var function_def = std.mem.zeroes(mem.types.FuncDef);
            value = std.mem.zeroes(mem.types.Mem);
            other = std.mem.zeroes(mem.types.Mem);
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            function_def.xFinalize = lifecycleFinalize;
            context.pOut = &other;
            context.pMem = &value;
            context.pFunc = &function_def;
            const first = mem.aggregateContext(&context, if (scenario == 115) 12 else 0);
            const second = mem.aggregateContext(&context, 20);
            output[0] = @intFromBool(first != null);
            output[1] = @intFromBool(first == second);
            output[2] = value.flags;
            if (first) |pointer| {
                const bytes_pointer: [*]u8 = @ptrCast(pointer);
                output[3] = bytes_pointer[0];
                output[4] = bytes_pointer[11];
            }
            mem.release(&value);
        },
        117 => {
            var context = std.mem.zeroes(mem.types.Context);
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var first: u8 = 0;
            var second: u8 = 0;
            db = allocatorDb();
            machine.db = &db;
            context.pOut = &value;
            context.pVdbe = &machine;
            context.iOp = 5;
            mem.setAuxData(&context, 2, &first, lifecycleDestructor);
            output[0] = @bitCast(@as(i64, context.isError));
            output[1] = @intFromBool(mem.getAuxData(&context, 2) == @as(*anyopaque, @ptrCast(&first)));
            mem.setAuxData(&context, 2, &second, lifecycleDestructor);
            output[2] = lifecycle_destructor_count;
            output[3] = @intFromBool(mem.getAuxData(&context, 2) == @as(*anyopaque, @ptrCast(&second)));
            context.iOp = 6;
            output[4] = @intFromBool(mem.getAuxData(&context, 2) == null);
            const auxiliary = machine.pAuxData.?;
            if (auxiliary.xDeleteAux) |destroy| destroy(auxiliary.pAux);
            db_allocator.freeNN(&db, auxiliary);
            output[5] = lifecycle_destructor_count;
        },
        118, 119 => {
            const text: [*:0]const u8 = "48.00";
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static | mem.types.mem_flag.terminated;
            value.z = @constCast(text);
            value.n = 5;
            value.enc = 1;
            if (scenario == 118) {
                var integer: i64 = 0;
                output[0] = @intFromBool(mem.alsoAnInt(&value, 48.0, &integer));
                output[1] = @bitCast(integer);
            } else {
                mem.applyNumericAffinity(&value, true);
                output[0] = value.flags;
                output[1] = @bitCast(value.u.i);
            }
        },
        120 => {
            value.flags = mem.types.mem_flag.real;
            value.u.r = 4.0;
            mem.applyAffinity(&value, 0x44, 1);
            output[0] = value.flags;
            output[1] = @bitCast(value.u.i);
        },
        121, 122 => {
            const text: [*:0]const u8 = if (scenario == 121) "42" else "4.5";
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.static | mem.types.mem_flag.terminated;
            value.z = @constCast(text);
            value.n = @intCast(std.mem.len(text));
            value.enc = 1;
            output[0] = mem.computeNumericType(&value);
            output[1] = value.flags;
            output[2] = if (scenario == 121) @bitCast(value.u.i) else @bitCast(value.u.r);
        },
        123 => {
            value.flags = mem.types.mem_flag.integer_real;
            value.u.i = 9;
            output[0] = mem.numericType(&value);
            output[1] = value.flags;
            output[2] = @bitCast(value.u.i);
        },
        124 => {
            value.flags = mem.types.mem_flag.string | mem.types.mem_flag.dynamic;
            value.z = &bytes;
            value.xDel = lifecycleDestructor;
            output[0] = @intFromBool(mem.out2Prerelease(&value) == &value);
            output[1] = value.flags;
            output[2] = lifecycle_destructor_count;
            other.flags = mem.types.mem_flag.null_;
            output[3] = @intFromBool(mem.out2Prerelease(&other) == &other);
            output[4] = other.flags;
        },
        125 => {
            var registers = [_]mem.types.Mem{std.mem.zeroes(mem.types.Mem)} ** 5;
            registers[0].flags = mem.types.mem_flag.integer;
            registers[0].u.i = -2;
            registers[1].flags = mem.types.mem_flag.real;
            registers[1].u.r = 3.9;
            registers[2].flags = mem.types.mem_flag.string;
            registers[3].flags = mem.types.mem_flag.blob;
            registers[4].flags = mem.types.mem_flag.null_;
            output[0] = mem.filterHash(&registers);
        },
        126 => {
            const flags = [_]u16{ mem.types.mem_flag.integer, mem.types.mem_flag.real, mem.types.mem_flag.string, mem.types.mem_flag.blob, mem.types.mem_flag.null_ };
            for (flags, 0..) |flag, index| {
                value.flags = flag;
                const name = mem.memTypeName(&value);
                output[index] = name[0] + name[1] + name[2];
            }
        },
        127, 128 => {
            var context = std.mem.zeroes(mem.types.Context);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            context.enc = 1;
            mem.resultErrorCode(&context, if (scenario == 127) 19 else 0);
            output[0] = @bitCast(@as(i64, context.isError));
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = value.z.?[0] + value.z.?[@intCast(value.n - 1)];
        },
        129 => {
            var context = std.mem.zeroes(mem.types.Context);
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            value.db = &db;
            value.flags = mem.types.mem_flag.null_;
            context.pOut = &value;
            mem.resultErrorTooBig(&context);
            output[0] = @bitCast(@as(i64, context.isError));
            output[1] = value.flags;
            output[2] = @intCast(value.n);
            output[3] = value.z.?[0] + value.z.?[@intCast(value.n - 1)];
        },
        130 => {
            var context = std.mem.zeroes(mem.types.Context);
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 42;
            context.pOut = &value;
            mem.resultIntReal(&context);
            output[0] = value.flags;
            output[1] = @bitCast(value.u.i);
        },
        131 => {
            var context = std.mem.zeroes(mem.types.Context);
            db = allocatorDb();
            value.db = &db;
            value.flags = mem.types.mem_flag.integer;
            value.u.i = 42;
            context.pOut = &value;
            mem.resultErrorNoMem(&context);
            output[0] = @bitCast(@as(i64, context.isError));
            output[1] = value.flags;
            output[2] = db.mallocFailed;
            output[3] = db.lookaside.bDisable;
        },
        132 => {
            var context = std.mem.zeroes(mem.types.Context);
            function = std.mem.zeroes(mem.types.FuncDef);
            function.zName = "percentile";
            context.pFunc = &function;
            const name = vdbe_aux.functionName(&context).?;
            output[0] = @as(u64, name[0]) + name[1] + name[2];
        },
        133 => {
            db = allocatorDb();
            db.nTotalChange = 10;
            vdbe_aux.setChanges(&db, 4);
            output[0] = @bitCast(db.nChange);
            output[1] = @bitCast(db.nTotalChange);
        },
        134 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            vdbe_aux.countChanges(&machine);
            output[0] = @intFromBool(machine.flags.changeCntOn);
        },
        135 => {
            var first = std.mem.zeroes(mem.types.Vdbe);
            var second = std.mem.zeroes(mem.types.Vdbe);
            db = allocatorDb();
            db.pVdbe = &first;
            first.pVNext = &second;
            vdbe_aux.expirePreparedStatements(&db, 1);
            output[0] = first.flags.expired;
            output[1] = second.flags.expired;
        },
        136 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            db = allocatorDb();
            machine.db = &db;
            output[0] = @intFromBool(vdbe_aux.database(&machine) == &db);
        },
        137 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            machine.prepFlags = 0xa5;
            output[0] = vdbe_aux.prepareFlags(&machine);
        },
        138 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var operations = [_]mem.types.VdbeOp{std.mem.zeroes(mem.types.VdbeOp)} ** 3;
            db = allocatorDb();
            machine.db = &db;
            machine.aOp = &operations;
            machine.nOp = 3;
            output[0] = @intCast(vdbe_aux.currentAddress(&machine));
            output[1] = @intFromBool(vdbe_aux.getOperation(&machine, 1) == &operations[1]);
            output[2] = @intFromBool(vdbe_aux.getLastOperation(&machine) == &operations[2]);
            vdbe_aux.changeOpcode(&machine, 1, .Integer);
            vdbe_aux.changeP1(&machine, 1, 11);
            vdbe_aux.changeP2(&machine, 1, 22);
            vdbe_aux.changeP3(&machine, 1, 33);
            vdbe_aux.changeP5(&machine, 44);
            output[3] = @intFromEnum(operations[1].opcode);
            output[4] = @intCast(operations[1].p1);
            output[5] = @intCast(operations[1].p2);
            output[6] = @intCast(operations[1].p3);
            output[7] = operations[2].p5;
        },
        139 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var operations = [_]mem.types.VdbeOp{std.mem.zeroes(mem.types.VdbeOp)} ** 3;
            db = allocatorDb();
            machine.db = &db;
            machine.aOp = &operations;
            machine.nOp = 3;
            operations[2].opcode = .Once;
            vdbe_aux.jumpHere(&machine, 0);
            output[0] = @intCast(operations[0].p2);
            vdbe_aux.jumpHereOrPopInstruction(&machine, 2);
            output[1] = @intCast(machine.nOp);
            vdbe_aux.jumpHereOrPopInstruction(&machine, 0);
            output[2] = @intCast(operations[0].p2);
        },
        140 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            db = allocatorDb();
            db.mallocFailed = 1;
            machine.db = &db;
            output[0] = @intFromEnum(vdbe_aux.getOperation(&machine, 99).opcode);
        },
        141 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            machine.pParse = @ptrFromInt(8);
            output[0] = @intFromBool(vdbe_aux.parser(&machine) == @as(*mem.types.Parse, @ptrFromInt(8)));
        },
        142 => {
            var first = std.mem.zeroes(mem.types.Vdbe);
            var second = std.mem.zeroes(mem.types.Vdbe);
            var next_first = std.mem.zeroes(mem.types.Vdbe);
            var next_second = std.mem.zeroes(mem.types.Vdbe);
            var previous_first: ?*mem.types.Vdbe = &first;
            var previous_second: ?*mem.types.Vdbe = &second;
            var sql_first = [_:0]u8{ 'f', 'i', 'r', 's', 't' };
            var sql_second = [_:0]u8{ 's', 'e', 'c', 'o', 'n', 'd' };
            db = allocatorDb();
            first.db = &db;
            second.db = &db;
            first.pVNext = &next_first;
            second.pVNext = &next_second;
            first.ppVPrev = &previous_first;
            second.ppVPrev = &previous_second;
            first.zSql = &sql_first;
            second.zSql = &sql_second;
            first.pc = 11;
            second.pc = 22;
            first.expmask = 101;
            second.expmask = 202;
            first.prepFlags = 3;
            second.prepFlags = 4;
            first.aCounter[mem.types.statement_status_reprepare] = 6;
            second.aCounter[mem.types.statement_status_reprepare] = 7;
            vdbe_aux.swap(&first, &second);
            output[0] = @intCast(first.pc);
            output[1] = @intCast(second.pc);
            output[2] = @intFromBool(first.pVNext == &next_first);
            output[3] = @intFromBool(second.pVNext == &next_second);
            output[4] = @intFromBool(first.ppVPrev == &previous_first);
            output[5] = @intFromBool(second.ppVPrev == &previous_second);
            output[6] = @intFromBool(first.zSql == @as([*:0]u8, &sql_first));
            output[7] = @intFromBool(second.zSql == @as([*:0]u8, &sql_second));
            output[8] = first.expmask;
            output[9] = second.expmask;
            output[10] = first.prepFlags;
            output[11] = second.prepFlags;
            output[12] = first.aCounter[mem.types.statement_status_reprepare];
            output[13] = second.aCounter[mem.types.statement_status_reprepare];
        },
        143 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var operations = [_]mem.types.VdbeOp{std.mem.zeroes(mem.types.VdbeOp)} ** 2;
            db = allocatorDb();
            machine.db = &db;
            machine.aOp = &operations;
            machine.nOp = 2;
            operations[1].opcode = .Column;
            operations[1].p3 = 7;
            operations[1].p5 = 1;
            vdbe_aux.typeofColumn(&machine, 7);
            output[0] = operations[1].p5;
            operations[1].p5 = 2;
            vdbe_aux.typeofColumn(&machine, 8);
            output[1] = operations[1].p5;
            operations[1].opcode = .Integer;
            vdbe_aux.typeofColumn(&machine, 7);
            output[2] = operations[1].p5;
        },
        144 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var first = std.mem.zeroes(mem.types.SubProgram);
            var second = std.mem.zeroes(mem.types.SubProgram);
            output[0] = @intFromBool(vdbe_aux.hasSubProgram(&machine));
            vdbe_aux.linkSubProgram(&machine, &first);
            vdbe_aux.linkSubProgram(&machine, &second);
            output[1] = @intFromBool(vdbe_aux.hasSubProgram(&machine));
            output[2] = @intFromBool(machine.pProgram == &second);
            output[3] = @intFromBool(second.pNext == &first);
            output[4] = @intFromBool(first.pNext == null);
        },
        145 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var first = std.mem.zeroes(mem.types.VdbeFrame);
            var second = std.mem.zeroes(mem.types.VdbeFrame);
            first.v = &machine;
            second.v = &machine;
            vdbe_aux.frameMemDelete(&first);
            vdbe_aux.frameMemDelete(&second);
            output[0] = @intFromBool(machine.pDelFrame == &second);
            output[1] = @intFromBool(second.pParent == &first);
            output[2] = @intFromBool(first.pParent == null);
        },
        146 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            machine.eVdbeState = mem.types.vdbe_state.halt;
            machine.nOp = 1;
            machine.pc = 9;
            machine.rc = 1;
            machine.errorAction = 1;
            machine.nChange = 33;
            machine.cacheCtr = 55;
            machine.minWriteFileFormat = 4;
            machine.iStatement = 8;
            machine.nFkConstraint = 13;
            vdbe_aux.rewind(&machine);
            output[0] = machine.eVdbeState;
            output[1] = @bitCast(@as(i64, machine.pc));
            output[2] = @intCast(machine.rc);
            output[3] = machine.errorAction;
            output[4] = @bitCast(machine.nChange);
            output[5] = machine.cacheCtr;
            output[6] = machine.minWriteFileFormat;
            output[7] = @intCast(machine.iStatement);
            output[8] = @bitCast(machine.nFkConstraint);
        },
        147 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            machine.rc = 5;
            vdbe_aux.resetStepResult(&machine);
            output[0] = @intCast(machine.rc);
        },
        148, 149 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var sql = [_:0]u8{ 's', 'e', 'l', 'e', 'c', 't', ' ', '4', '2' };
            db = allocatorDb();
            machine.db = &db;
            machine.expmask = 0x1234_5678;
            vdbe_aux.setSql(&machine, &sql, 9, if (scenario == 149) mem.types.prepare_save_sql else 3);
            output[0] = machine.prepFlags;
            output[1] = machine.expmask;
            output[2] = @intFromBool(machine.zSql != @as([*:0]u8, &sql));
            output[3] = @intFromBool(std.mem.eql(u8, std.mem.span(machine.zSql.?), std.mem.span(@as([*:0]u8, &sql))));
            db_allocator.freeNN(&db, machine.zSql.?);
        },
        150 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            vdbe_aux.setVariableMask(&machine, 1);
            output[0] = machine.expmask;
            vdbe_aux.setVariableMask(&machine, 31);
            output[1] = machine.expmask;
            vdbe_aux.setVariableMask(&machine, 32);
            output[2] = machine.expmask;
            vdbe_aux.setVariableMask(&machine, 47);
            output[3] = machine.expmask;
        },
        151 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var variables = [_]mem.types.Mem{std.mem.zeroes(mem.types.Mem)} ** 2;
            var text = [_:0]u8{ '4', '2' };
            db = allocatorDb();
            machine.db = &db;
            machine.aVar = &variables;
            variables[0].flags = mem.types.mem_flag.null_;
            variables[1].db = &db;
            variables[1].flags = mem.types.mem_flag.string | mem.types.mem_flag.static | mem.types.mem_flag.terminated;
            variables[1].z = &text;
            variables[1].n = 2;
            variables[1].enc = 1;
            output[0] = @intFromBool(vdbe_aux.getBoundValue(&machine, 1, 0x44) == null);
            const result = vdbe_aux.getBoundValue(&machine, 2, 0x44);
            output[1] = @intFromBool(result != null);
            if (result) |value_result| {
                output[2] = value_result.flags;
                output[3] = @bitCast(value_result.u.i);
                output[4] = @intFromBool(value_result.db == &db);
                output[5] = @intFromBool(value_result.z != @as([*]u8, &text));
                mem.valueFree(value_result);
            }
        },
        152 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var variable = std.mem.zeroes(mem.types.Mem);
            const manager = memory.ensureProcessManager();
            db = allocatorDb();
            machine.db = &db;
            machine.aVar = @as([*]mem.types.Mem, @ptrCast(&variable));
            variable.db = &db;
            variable.flags = mem.types.mem_flag.integer;
            variable.u.i = 7;
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            output[0] = @intFromBool(vdbe_aux.getBoundValue(&machine, 1, 0x44) == null);
            output[1] = db.mallocFailed;
            _ = manager.setHardLimit(0);
            db_allocator.oomClear(&db);
        },
        153 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var sql = [_:0]u8{ 's', 'e', 'l', 'e', 'c', 't', ' ', '4', '2' };
            const manager = memory.ensureProcessManager();
            db = allocatorDb();
            machine.db = &db;
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            vdbe_aux.setSql(&machine, &sql, 9, mem.types.prepare_save_sql);
            output[0] = @intFromBool(machine.zSql == null);
            output[1] = db.mallocFailed;
            output[2] = machine.prepFlags;
            _ = manager.setHardLimit(0);
            db_allocator.oomClear(&db);
        },
        154 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var name = [_:0]u8{ 'a', 'n', 's', 'w', 'e', 'r' };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            machine.db = &db;
            vdbe_aux.setColumnCount(&machine, 3);
            output[0] = machine.nResColumn;
            output[1] = machine.nResAlloc;
            output[2] = @intFromBool(machine.aColName != null);
            for (machine.aColName.?[0 .. 3 * mem.types.column_name.count]) |*cell| {
                output[3] += @intFromBool(cell.flags == mem.types.mem_flag.null_);
                output[4] += @intFromBool(cell.db == &db);
            }
            output[5] = @intCast(vdbe_aux.setColumnName(&machine, 1, mem.types.column_name.name, &name, .transient));
            output[6] = machine.aColName.?[1].flags;
            output[7] = @intCast(machine.aColName.?[1].n);
            output[8] = @intFromBool(std.mem.eql(u8, machine.aColName.?[1].z.?[0..6], "answer"));
            output[9] = @intFromBool(machine.aColName.?[1].z != @as([*]u8, &name));
            output[10] = machine.aColName.?[1].z.?[6];
            vdbe_aux.setColumnCount(&machine, 1);
            output[11] = machine.nResColumn;
            output[12] = machine.nResAlloc;
            output[13] = @intFromBool(machine.aColName != null);
            mem.releaseArray(machine.aColName, @intCast(mem.types.column_name.count));
            db_allocator.free(&db, machine.aColName);
        },
        155 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var name = [_:0]u8{ 's', 't', 'a', 't', 'i', 'c' };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            machine.db = &db;
            vdbe_aux.setColumnCount(&machine, 1);
            output[0] = @intCast(vdbe_aux.setColumnName(&machine, 0, mem.types.column_name.name, &name, .static));
            output[1] = @intFromBool(machine.aColName.?[0].z == @as([*]u8, &name));
            output[2] = machine.aColName.?[0].flags;
            mem.releaseArray(machine.aColName, @intCast(mem.types.column_name.count));
            db_allocator.free(&db, machine.aColName);
        },
        156 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            const manager = memory.ensureProcessManager();
            db = allocatorDb();
            machine.db = &db;
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            vdbe_aux.setColumnCount(&machine, 3);
            output[0] = machine.nResColumn;
            output[1] = machine.nResAlloc;
            output[2] = @intFromBool(machine.aColName == null);
            output[3] = db.mallocFailed;
            _ = manager.setHardLimit(0);
            db_allocator.oomClear(&db);
        },
        157 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            db = allocatorDb();
            db.pErr = mem.valueNew(&db);
            db.pErr.?.flags = mem.types.mem_flag.integer;
            db.pErr.?.u.i = 42;
            machine.db = &db;
            machine.rc = 5;
            output[0] = @intCast(vdbe_aux.transferError(&machine));
            output[1] = @intCast(db.errCode);
            output[2] = @bitCast(@as(i64, db.errByteOffset));
            output[3] = db.pErr.?.flags;
            mem.valueFree(db.pErr);
        },
        158 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var message = [_:0]u8{ 'f', 'a', 'i', 'l', 'u', 'r', 'e' };
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            db.pErr = null;
            machine.db = &db;
            machine.rc = 1;
            machine.zErrMsg = &message;
            output[0] = @intCast(vdbe_aux.transferError(&machine));
            output[1] = @intCast(db.errCode);
            output[2] = @bitCast(@as(i64, db.errByteOffset));
            output[3] = @intFromBool(db.pErr != null);
            output[4] = db.bBenignMalloc;
            if (db.pErr) |error_value| {
                output[5] = error_value.flags;
                output[6] = @intCast(error_value.n);
                output[7] = @intFromBool(std.mem.eql(u8, error_value.z.?[0..7], "failure"));
                output[8] = @intFromBool(error_value.z != @as([*]u8, &message));
                mem.valueFree(error_value);
            }
        },
        159 => {
            var machine = std.mem.zeroes(mem.types.Vdbe);
            var message = [_:0]u8{ 'f', 'a', 'i', 'l', 'u', 'r', 'e' };
            const manager = memory.ensureProcessManager();
            db = allocatorDb();
            db.aLimit[0] = 1_000_000;
            db.pErr = null;
            machine.db = &db;
            machine.rc = 1;
            machine.zErrMsg = &message;
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            output[0] = @intCast(vdbe_aux.transferError(&machine));
            output[1] = @intFromBool(db.pErr == null);
            output[2] = db.mallocFailed;
            output[3] = db.bBenignMalloc;
            _ = manager.setHardLimit(0);
        },
        else => {},
    }
}

fn allocatorDb() mem.types.Sqlite3 {
    var db: mem.types.Sqlite3 = undefined;
    db.mallocFailed = 0;
    db.bBenignMalloc = 0;
    db.nVdbeExec = 0;
    db.pParse = null;
    db.pnBytesFreed = null;
    db.u1.isInterrupted = 0;
    db.lookaside = .{
        .bDisable = 1,
        .sz = 0,
        .szTrue = 0,
        .bMalloced = 0,
        .nSlot = 0,
        .anStat = .{ 0, 0, 0 },
        .pInit = null,
        .pFree = null,
        .pSmallInit = null,
        .pSmallFree = null,
        .pMiddle = null,
        .pStart = null,
        .pEnd = null,
        .pTrueEnd = null,
    };
    return db;
}

export fn probe_db_allocator(scenario: c_uint, output: *[16]u64) callconv(.c) void {
    @memset(output, 0);
    var db = allocatorDb();
    startTestProcessManager();
    switch (scenario) {
        0 => {
            var arena: [640]u8 align(8) = [_]u8{0} ** 640;
            const arena_ptr: [*]u8 = @ptrCast(&arena);
            const big: *mem.types.LookasideSlot = @ptrCast(@alignCast(&arena[0]));
            const small: *mem.types.LookasideSlot = @ptrCast(@alignCast(&arena[512]));
            db.lookaside.bDisable = 0;
            db.lookaside.sz = 512;
            db.lookaside.szTrue = 512;
            db.lookaside.pStart = arena_ptr;
            db.lookaside.pMiddle = arena_ptr + 512;
            db.lookaside.pEnd = arena_ptr + arena.len;
            db.lookaside.pTrueEnd = arena_ptr + arena.len;
            db.lookaside.pInit = big;
            db.lookaside.pSmallInit = small;
            const first = db_allocator.mallocRawNN(&db, 32).?;
            const second = db_allocator.mallocRawNN(&db, 400).?;
            output[0] = @intFromPtr(first) - @intFromPtr(&arena);
            output[1] = @intFromPtr(second) - @intFromPtr(&arena);
            output[2] = db_allocator.allocationSize(&db, first);
            output[3] = db_allocator.allocationSize(&db, second);
            output[4] = db.lookaside.anStat[0];
            output[5] = db.lookaside.anStat[1];
            output[6] = db.lookaside.anStat[2];
            db_allocator.freeNN(&db, first);
            db_allocator.freeNN(&db, second);
            output[7] = @intFromBool(db.lookaside.pSmallFree == small);
            output[8] = @intFromBool(db.lookaside.pFree == big);
        },
        1 => {
            const first = db_allocator.mallocRawNN(&db, 17);
            output[0] = @intFromBool(first != null);
            output[1] = if (first) |value| db_allocator.allocationSize(&db, value) else 0;
            if (first) |value| @as([*]u8, @ptrCast(value))[0] = 0x5a;
            const second = db_allocator.realloc(&db, first, 100);
            output[2] = @intFromBool(second != null);
            output[3] = if (second) |value| @as([*]u8, @ptrCast(value))[0] else 0;
            output[4] = if (second) |value| db_allocator.allocationSize(&db, value) else 0;
            output[5] = db.mallocFailed;
            db_allocator.free(&db, second);
        },
        2 => {
            const value = db_allocator.mallocRawNN(&db, 33).?;
            output[0] = db_allocator.allocationSize(&db, value);
            var measured: c_int = 0;
            db.pnBytesFreed = &measured;
            db_allocator.freeNN(&db, value);
            output[1] = @intCast(measured);
            db.pnBytesFreed = null;
            db_allocator.freeNN(&db, value);
        },
        3 => {
            const first = db_allocator.stringDuplicate(&db, "sqlite");
            const second = db_allocator.stringNDuplicate(&db, "abcdef", 3);
            output[0] = @intFromBool(first != null);
            output[1] = @intFromBool(second != null);
            output[2] = if (first) |value| std.mem.len(value) else 0;
            output[3] = if (second) |value| std.mem.len(value) else 0;
            output[4] = if (first) |value| @as(u64, value[0]) + value[5] else 0;
            output[5] = if (second) |value| @as(u64, value[0]) + value[2] else 0;
            db_allocator.free(&db, if (first) |value| @ptrCast(value) else null);
            db_allocator.free(&db, if (second) |value| @ptrCast(value) else null);
        },
        4 => {
            const manager = memory.ensureProcessManager();
            const used = manager.status(.memory_used, false).current;
            _ = manager.setHardLimit(used + 1);
            db.lookaside.szTrue = 1200;
            const value = db_allocator.mallocRawNN(&db, 4096);
            output[0] = @intFromBool(value == null);
            output[1] = db.mallocFailed;
            output[2] = db.lookaside.bDisable;
            output[3] = db.lookaside.sz;
            db.nVdbeExec = 1;
            db_allocator.oomClear(&db);
            output[4] = db.mallocFailed;
            db.nVdbeExec = 0;
            db_allocator.oomClear(&db);
            output[5] = db.mallocFailed;
            output[6] = db.lookaside.bDisable;
            output[7] = db.lookaside.sz;
            if (value) |allocated| db_allocator.freeNN(&db, allocated);
            _ = manager.setHardLimit(0);
        },
        else => {},
    }
}
