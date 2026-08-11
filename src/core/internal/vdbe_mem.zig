//! Source-corresponding `Mem` and record primitives from `vdbemem.c` and
//! `vdbeaux.c`, including connection allocation and ownership lifecycles.

const std = @import("std");
const numeric = @import("../numeric.zig");
const sqlite_float = @import("../float.zig");
const formatter = @import("../formatter.zig");
const utf = @import("../utf.zig");
const varint = @import("../varint.zig");
const memory = @import("../memory.zig");
const db_allocator = @import("db_allocator.zig");
const public_api = @import("../public_api.zig");
const rowset = @import("../rowset.zig");
pub const types = @import("vdbe_types.zig");

/// Source representation: sqliteInt.h `struct PrintfArguments`.
pub const PrintfArguments = extern struct {
    nArg: c_int,
    nUsed: c_int,
    apArg: ?[*]?*types.Mem,
};

/// Upstream printf.c getIntArg(). Missing arguments produce zero and are not consumed.
pub fn getPrintfIntArg(arguments: *PrintfArguments) i64 {
    if (arguments.nArg <= arguments.nUsed) return 0;
    const index: usize = @intCast(arguments.nUsed);
    arguments.nUsed += 1;
    return valueInt64(arguments.apArg.?[index].?);
}

/// Upstream printf.c getDoubleArg(). Missing arguments produce zero and are not consumed.
pub fn getPrintfDoubleArg(arguments: *PrintfArguments) f64 {
    if (arguments.nArg <= arguments.nUsed) return 0.0;
    const index: usize = @intCast(arguments.nUsed);
    arguments.nUsed += 1;
    return valueDouble(arguments.apArg.?[index].?);
}

/// Upstream printf.c getTextArg(). Missing arguments produce null and are not consumed.
pub fn getPrintfTextArg(arguments: *PrintfArguments) ?[*]u8 {
    if (arguments.nArg <= arguments.nUsed) return null;
    const index: usize = @intCast(arguments.nUsed);
    arguments.nUsed += 1;
    return @constCast(valueText(arguments.apArg.?[index], 1));
}

pub fn realSameAsInt(real: f64, integer: i64) bool {
    const converted: f64 = @floatFromInt(integer);
    return real == 0.0 or
        (@as(u64, @bitCast(real)) == @as(u64, @bitCast(converted)) and
            integer >= -2_251_799_813_685_248 and integer < 2_251_799_813_685_248);
}

pub fn realToI64(real: f64) i64 {
    if (real < -9_223_372_036_854_774_784.0) return std.math.minInt(i64);
    if (real > 9_223_372_036_854_774_784.0) return std.math.maxInt(i64);
    return @intFromFloat(real);
}

pub fn intFloatCompare(integer: i64, real: f64) c_int {
    if (std.math.isNan(real)) return 1;
    if (real < -9_223_372_036_854_775_808.0) return 1;
    if (real >= 9_223_372_036_854_775_808.0) return -1;
    const truncated: i64 = @intFromFloat(real);
    if (integer < truncated) return -1;
    if (integer > truncated) return 1;
    const converted: f64 = @floatFromInt(integer);
    return if (converted < real) -1 else @intFromBool(converted > real);
}

pub const small_type_sizes: [128]u8 = sizes: {
    var result = [_]u8{0} ** 128;
    const fixed = [_]u8{ 0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0 };
    @memcpy(result[0..fixed.len], &fixed);
    for (12..result.len) |serial_type| result[serial_type] = @intCast((serial_type - 12) / 2);
    break :sizes result;
};

pub fn serialTypeLen(serial_type: u32) u32 {
    if (serial_type >= small_type_sizes.len) return (serial_type - 12) / 2;
    return small_type_sizes[serial_type];
}

pub fn oneByteSerialTypeLen(serial_type: u8) u8 {
    std.debug.assert(serial_type < 128);
    return small_type_sizes[serial_type];
}

fn signedByte(byte: u8) i64 {
    return @as(i8, @bitCast(byte));
}

fn fourByteUnsigned(bytes: [*]const u8) u32 {
    return @as(u32, bytes[0]) << 24 |
        @as(u32, bytes[1]) << 16 |
        @as(u32, bytes[2]) << 8 |
        bytes[3];
}

fn serialGetLarge(bytes: [*]const u8, serial_type: u32, mem: *types.Mem) void {
    const raw = @as(u64, fourByteUnsigned(bytes)) << 32 | fourByteUnsigned(bytes + 4);
    if (serial_type == 6) {
        mem.u.i = @bitCast(raw);
        mem.flags = types.mem_flag.integer;
    } else {
        const real: f64 = @bitCast(raw);
        mem.u.r = real;
        mem.flags = if (std.math.isNan(real)) types.mem_flag.null_ else types.mem_flag.real;
    }
}

pub fn serialGet7(bytes: [*]const u8, mem: *types.Mem) c_int {
    const raw = @as(u64, fourByteUnsigned(bytes)) << 32 | fourByteUnsigned(bytes + 4);
    const real: f64 = @bitCast(raw);
    mem.u.r = real;
    if (std.math.isNan(real)) {
        mem.flags = types.mem_flag.null_;
        return 1;
    }
    mem.flags = types.mem_flag.real;
    return 0;
}

pub fn serialGet(bytes: [*]const u8, serial_type: u32, mem: *types.Mem) void {
    switch (serial_type) {
        10 => {
            mem.flags = types.mem_flag.null_ | types.mem_flag.zero;
            mem.n = 0;
            mem.u.nZero = 0;
        },
        0, 11 => mem.flags = types.mem_flag.null_,
        1 => {
            mem.u.i = signedByte(bytes[0]);
            mem.flags = types.mem_flag.integer;
        },
        2 => {
            mem.u.i = signedByte(bytes[0]) * 256 | bytes[1];
            mem.flags = types.mem_flag.integer;
        },
        3 => {
            mem.u.i = signedByte(bytes[0]) * 65_536 | @as(i64, bytes[1]) << 8 | bytes[2];
            mem.flags = types.mem_flag.integer;
        },
        4 => {
            mem.u.i = signedByte(bytes[0]) * 16_777_216 |
                @as(i64, bytes[1]) << 16 | @as(i64, bytes[2]) << 8 | bytes[3];
            mem.flags = types.mem_flag.integer;
        },
        5 => {
            const high = signedByte(bytes[0]) * 256 | bytes[1];
            mem.u.i = high * 4_294_967_296 + fourByteUnsigned(bytes + 2);
            mem.flags = types.mem_flag.integer;
        },
        6, 7 => serialGetLarge(bytes, serial_type, mem),
        8, 9 => {
            mem.u.i = serial_type - 8;
            mem.flags = types.mem_flag.integer;
        },
        else => {
            mem.z = @constCast(bytes);
            mem.n = @bitCast((serial_type - 12) / 2);
            mem.flags = if (serial_type & 1 == 0)
                types.mem_flag.blob | types.mem_flag.ephemeral
            else
                types.mem_flag.string | types.mem_flag.ephemeral;
        },
    }
}

fn memIntValue(mem: *const types.Mem) i64 {
    const pointer = mem.z orelse return 0;
    const length: usize = @intCast(mem.n);
    const encoding: numeric.TextEncoding = @enumFromInt(mem.enc);
    return numeric.parseI64(pointer[0..length], encoding).value;
}

pub fn intValue(mem: *const types.Mem) i64 {
    const flags = mem.flags;
    if (flags & (types.mem_flag.integer | types.mem_flag.integer_real) != 0) return mem.u.i;
    if (flags & types.mem_flag.real != 0) return realToI64(mem.u.r);
    if (flags & (types.mem_flag.string | types.mem_flag.blob) != 0 and mem.z != null) return memIntValue(mem);
    return 0;
}

fn realValueSlowPath(mem: *types.Mem, output: *f64) c_int {
    output.* = 0.0;
    if (mem.enc == 1) {
        const buffer = db_allocator.stringNDuplicate(mem.db.?, mem.z, @intCast(mem.n)) orelse return 0;
        const result = sqlite_float.parse(buffer);
        output.* = result.value;
        db_allocator.freeNN(mem.db, @ptrCast(buffer));
        return result.code;
    }
    const input_length: usize = @intCast(mem.n & ~@as(c_int, 1));
    const raw = db_allocator.mallocRaw(mem.db, input_length / 2 + 2) orelse return 0;
    const buffer: [*]u8 = @ptrCast(raw);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index + 1 < input_length) {
        if (mem.enc == 2) {
            buffer[output_index] = mem.z.?[input_index];
            if (mem.z.?[input_index + 1] != 0) break;
        } else {
            if (mem.z.?[input_index] != 0) break;
            buffer[output_index] = mem.z.?[input_index + 1];
        }
        input_index += 2;
        output_index += 1;
    }
    buffer[output_index] = 0;
    const result = sqlite_float.parse(@ptrCast(buffer));
    output.* = result.value;
    db_allocator.freeNN(mem.db, raw);
    return if (input_index < input_length) -100 else result.code;
}

pub fn realValueRC(mem: *types.Mem, output: *f64) c_int {
    if (mem.z == null) {
        output.* = 0.0;
        return 0;
    }
    if (mem.enc == 1 and
        (mem.flags & types.mem_flag.terminated != 0 or zeroTerminateIfAble(mem)))
    {
        const result = sqlite_float.parse(@ptrCast(mem.z.?));
        output.* = result.value;
        return result.code;
    }
    if (mem.n == 0) {
        output.* = 0.0;
        return 0;
    }
    return realValueSlowPath(mem, output);
}

fn realValueNoRC(mem: *types.Mem) f64 {
    var result: f64 = undefined;
    _ = realValueRC(mem, &result);
    return result;
}

pub fn realValue(mem: *types.Mem) f64 {
    if (mem.flags & types.mem_flag.real != 0) return mem.u.r;
    if (mem.flags & (types.mem_flag.integer | types.mem_flag.integer_real) != 0) return @floatFromInt(mem.u.i);
    if (mem.flags & (types.mem_flag.string | types.mem_flag.blob) != 0) return realValueNoRC(mem);
    return 0.0;
}

pub fn booleanValue(mem: *types.Mem, if_null: c_int) c_int {
    if (mem.flags & (types.mem_flag.integer | types.mem_flag.integer_real) != 0) return @intFromBool(mem.u.i != 0);
    if (mem.flags & types.mem_flag.null_ != 0) return if_null;
    return @intFromBool(realValue(mem) != 0.0);
}

pub fn realify(mem: *types.Mem) c_int {
    mem.u.r = realValue(mem);
    types.memSetTypeFlag(mem, types.mem_flag.real);
    return 0;
}

pub fn alsoAnInt(mem: *types.Mem, real: f64, output: *i64) bool {
    const converted = realToI64(real);
    if (realSameAsInt(real, converted)) {
        output.* = converted;
        return true;
    }
    const encoding: numeric.TextEncoding = @enumFromInt(mem.enc);
    const parsed = numeric.parseI64(mem.z.?[0..@intCast(mem.n)], encoding);
    output.* = parsed.value;
    return parsed.code == 0;
}

pub fn applyNumericAffinity(mem: *types.Mem, try_integer: bool) void {
    var real: f64 = undefined;
    const result = realValueRC(mem, &real);
    if (result <= 0) return;
    if (result & 2 == 0 and alsoAnInt(mem, real, &mem.u.i)) {
        mem.flags |= types.mem_flag.integer;
    } else {
        mem.u.r = real;
        mem.flags |= types.mem_flag.real;
        if (try_integer) integerAffinity(mem);
    }
    mem.flags &= ~types.mem_flag.string;
}

pub fn applyAffinity(mem: *types.Mem, affinity: u8, encoding: u8) void {
    if (affinity >= 0x43) {
        if (mem.flags & types.mem_flag.integer == 0) {
            if (mem.flags & (types.mem_flag.real | types.mem_flag.integer_real) == 0) {
                if (mem.flags & types.mem_flag.string != 0) applyNumericAffinity(mem, true);
            } else if (affinity <= 0x45) {
                integerAffinity(mem);
            }
        }
    } else if (affinity == 0x42) {
        if (mem.flags & types.mem_flag.string == 0 and
            mem.flags & (types.mem_flag.real | types.mem_flag.integer | types.mem_flag.integer_real) != 0)
        {
            _ = stringify(mem, encoding, true);
        }
        mem.flags &= ~(types.mem_flag.real | types.mem_flag.integer | types.mem_flag.integer_real);
    }
}

pub fn valueApplyAffinity(mem: *types.Mem, affinity: u8, encoding: u8) void {
    applyAffinity(mem, affinity, encoding);
}

pub fn computeNumericType(mem: *types.Mem) u16 {
    if (mem.flags & types.mem_flag.zero != 0 and expandBlob(mem) != 0) {
        mem.u.i = 0;
        return types.mem_flag.integer;
    }
    var real: f64 = undefined;
    const real_code = realValueRC(mem, &real);
    mem.u.r = real;
    const encoding: numeric.TextEncoding = @enumFromInt(mem.enc);
    const parsed = numeric.parseI64(mem.z.?[0..@intCast(mem.n)], encoding);
    if (real_code <= 0) {
        if (real_code & 2 == 0 and parsed.code <= 1) {
            mem.u.i = parsed.value;
            return types.mem_flag.integer;
        }
        return types.mem_flag.real;
    }
    if (real_code & 2 == 0 and parsed.code == 0) {
        mem.u.i = parsed.value;
        return types.mem_flag.integer;
    }
    return types.mem_flag.real;
}

pub fn numericType(mem: *types.Mem) u16 {
    const existing = mem.flags & (types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real | types.mem_flag.null_);
    if (existing != 0) return existing;
    return computeNumericType(mem);
}

pub fn filterHash(memories: []const types.Mem) u64 {
    var hash: u64 = 0;
    for (memories) |*mem| {
        if (mem.flags & (types.mem_flag.integer | types.mem_flag.integer_real) != 0) {
            hash +%= @bitCast(mem.u.i);
        } else if (mem.flags & types.mem_flag.real != 0) {
            hash +%= @bitCast(intValue(mem));
        } else if (mem.flags & (types.mem_flag.string | types.mem_flag.blob) != 0) {
            hash +%= 4093 + (mem.flags & (types.mem_flag.string | types.mem_flag.blob));
        }
    }
    return hash;
}

pub fn memTypeName(mem: *const types.Mem) []const u8 {
    return switch (valueType(mem)) {
        1 => "INT",
        2 => "REAL",
        3 => "TEXT",
        4 => "BLOB",
        else => "NULL",
    };
}

pub fn numerify(mem: *types.Mem) c_int {
    if (mem.flags & (types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real | types.mem_flag.null_) == 0) {
        var parsed_real: f64 = undefined;
        const real_code = realValueRC(mem, &parsed_real);
        mem.u.r = parsed_real;
        const encoding: numeric.TextEncoding = @enumFromInt(mem.enc);
        const parsed_integer = numeric.parseI64(mem.z.?[0..@intCast(mem.n)], encoding);
        var integer = parsed_integer.value;
        if ((real_code & 2 == 0 and parsed_integer.code < 2) or blk: {
            integer = realToI64(parsed_real);
            break :blk realSameAsInt(parsed_real, integer);
        }) {
            mem.u.i = integer;
            types.memSetTypeFlag(mem, types.mem_flag.integer);
        } else {
            types.memSetTypeFlag(mem, types.mem_flag.real);
        }
    }
    mem.flags &= ~(types.mem_flag.string | types.mem_flag.blob | types.mem_flag.zero);
    return 0;
}

pub fn cast(mem: *types.Mem, affinity: u8, encoding: u8) c_int {
    if (mem.flags & types.mem_flag.null_ != 0) return 0;
    switch (affinity) {
        0x41 => {
            if (mem.flags & types.mem_flag.blob == 0) {
                applyAffinity(mem, 0x42, encoding);
                if (mem.flags & types.mem_flag.string != 0) types.memSetTypeFlag(mem, types.mem_flag.blob);
            } else {
                mem.flags &= ~(types.mem_flag.type_mask & ~types.mem_flag.blob);
            }
        },
        0x43 => _ = numerify(mem),
        0x44 => _ = integerify(mem),
        0x45 => _ = realify(mem),
        0x42 => {
            mem.flags |= (mem.flags & types.mem_flag.blob) >> 3;
            applyAffinity(mem, 0x42, encoding);
            mem.flags &= ~(types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real | types.mem_flag.blob | types.mem_flag.zero);
            if (encoding != 1) mem.n &= ~@as(c_int, 1);
            const result = changeEncoding(mem, encoding);
            if (result != 0) return result;
            _ = zeroTerminateIfAble(mem);
        },
        else => unreachable,
    }
    return 0;
}

pub fn integerAffinity(mem: *types.Mem) void {
    if (mem.flags & types.mem_flag.integer_real != 0) {
        types.memSetTypeFlag(mem, types.mem_flag.integer);
        return;
    }
    const integer = realToI64(mem.u.r);
    const converted: f64 = @floatFromInt(integer);
    if (mem.u.r == converted and integer > std.math.minInt(i64) and integer < std.math.maxInt(i64)) {
        mem.u.i = integer;
        types.memSetTypeFlag(mem, types.mem_flag.integer);
    }
}

pub fn integerify(mem: *types.Mem) c_int {
    mem.u.i = intValue(mem);
    types.memSetTypeFlag(mem, types.mem_flag.integer);
    return 0;
}

fn compareStringWithEncodingChange(
    first: *const types.Mem,
    second: *const types.Mem,
    collation: *const types.CollSeq,
    error_code: ?*u8,
) c_int {
    var first_copy = std.mem.zeroes(types.Mem);
    var second_copy = std.mem.zeroes(types.Mem);
    init(&first_copy, first.db, types.mem_flag.null_);
    init(&second_copy, first.db, types.mem_flag.null_);
    shallowCopy(&first_copy, first, types.mem_flag.ephemeral);
    shallowCopy(&second_copy, second, types.mem_flag.ephemeral);
    const first_text = valueText(&first_copy, collation.enc);
    const second_text = valueText(&second_copy, collation.enc);
    const result: c_int = if (first_text == null or second_text == null) blk: {
        if (error_code) |code| code.* = 7;
        break :blk 0;
    } else collation.xCmp.?(
        collation.pUser,
        first_copy.n,
        @ptrCast(first_text.?),
        second_copy.n,
        @ptrCast(second_text.?),
    );
    releaseMalloc(&first_copy);
    releaseMalloc(&second_copy);
    return result;
}

fn compareString(first: *const types.Mem, second: *const types.Mem, collation: *const types.CollSeq, error_code: ?*u8) c_int {
    if (first.enc == collation.enc) {
        return collation.xCmp.?(
            collation.pUser,
            first.n,
            if (first.z) |value| @ptrCast(value) else null,
            second.n,
            if (second.z) |value| @ptrCast(value) else null,
        );
    }
    return compareStringWithEncodingChange(first, second, collation, error_code);
}

fn isAllZero(bytes: [*]const u8, length: c_int) bool {
    for (bytes[0..@intCast(length)]) |byte| if (byte != 0) return false;
    return true;
}

pub fn blobCompare(first: *const types.Mem, second: *const types.Mem) c_int {
    const first_length = first.n;
    const second_length = second.n;
    if ((first.flags | second.flags) & types.mem_flag.zero != 0) {
        if (first.flags & second.flags & types.mem_flag.zero != 0) return first.u.nZero - second.u.nZero;
        if (first.flags & types.mem_flag.zero != 0) {
            if (!isAllZero(second.z.?, second.n)) return -1;
            return first.u.nZero - second_length;
        }
        if (!isAllZero(first.z.?, first.n)) return 1;
        return first_length - second.u.nZero;
    }
    const common: usize = @intCast(@min(first_length, second_length));
    for (first.z.?[0..common], second.z.?[0..common]) |left, right| {
        if (left != right) return @as(c_int, left) - right;
    }
    return first_length - second_length;
}

pub fn compare(first: *const types.Mem, second: *const types.Mem, collation: ?*const types.CollSeq) c_int {
    const first_flags = first.flags;
    const second_flags = second.flags;
    const combined = first_flags | second_flags;
    if (combined & types.mem_flag.null_ != 0)
        return @as(c_int, @intFromBool(second_flags & types.mem_flag.null_ != 0)) -
            @as(c_int, @intFromBool(first_flags & types.mem_flag.null_ != 0));
    if (combined & (types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real) != 0) {
        const integers = types.mem_flag.integer | types.mem_flag.integer_real;
        if (first_flags & second_flags & integers != 0) return if (first.u.i < second.u.i) -1 else @intFromBool(first.u.i > second.u.i);
        if (first_flags & second_flags & types.mem_flag.real != 0) return if (first.u.r < second.u.r) -1 else @intFromBool(first.u.r > second.u.r);
        if (first_flags & integers != 0) {
            if (second_flags & types.mem_flag.real != 0) return intFloatCompare(first.u.i, second.u.r);
            if (second_flags & integers != 0) return if (first.u.i < second.u.i) -1 else @intFromBool(first.u.i > second.u.i);
            return -1;
        }
        if (first_flags & types.mem_flag.real != 0) {
            if (second_flags & integers != 0) return -intFloatCompare(second.u.i, first.u.r);
            return -1;
        }
        return 1;
    }
    if (combined & types.mem_flag.string != 0) {
        if (first_flags & types.mem_flag.string == 0) return 1;
        if (second_flags & types.mem_flag.string == 0) return -1;
        if (collation) |sequence| return compareString(first, second, sequence, null);
    }
    return blobCompare(first, second);
}

pub fn recordDecodeInt(serial_type: u32, bytes: [*]const u8) i64 {
    var value = std.mem.zeroes(types.Mem);
    serialGet(bytes, serial_type, &value);
    return value.u.i;
}

pub fn allocUnpackedRecord(key_info: *types.KeyInfo) ?*types.UnpackedRecord {
    const prefix_size = std.mem.alignForward(usize, @sizeOf(types.UnpackedRecord), 8);
    const byte_count = prefix_size + @sizeOf(types.Mem) * (@as(usize, key_info.nKeyField) + 1);
    const raw = db_allocator.mallocRaw(key_info.db, byte_count) orelse return null;
    const record: *types.UnpackedRecord = @ptrCast(@alignCast(raw));
    const bytes: [*]u8 = @ptrCast(raw);
    record.aMem = @ptrCast(@alignCast(bytes + prefix_size));
    record.pKeyInfo = key_info;
    record.nField = key_info.nKeyField + 1;
    return record;
}

pub fn unpackRecord(key: []const u8, record: *types.UnpackedRecord) void {
    const key_info = record.pKeyInfo.?;
    const header = varint.get32(key.ptr);
    var header_index: u32 = header.length;
    var data_index: u32 = header.value;
    var field: u16 = 0;
    record.default_rc = 0;
    while (header_index < header.value and data_index <= key.len) {
        const serial = varint.get32(key.ptr + header_index);
        header_index += serial.length;
        const value = &record.aMem.?[field];
        value.enc = key_info.enc;
        value.db = key_info.db;
        value.szMalloc = 0;
        value.z = null;
        serialGet(key.ptr + data_index, serial.value, value);
        data_index += serialTypeLen(serial.value);
        field += 1;
        if (field >= record.nField) break;
    }
    if (data_index > key.len and field != 0) {
        const index = field - @intFromBool(field < record.nField);
        setNull(&record.aMem.?[index]);
    }
    record.nField = field;
}

fn keyCollation(key_info: *const types.KeyInfo, index: usize) ?*const types.CollSeq {
    const collations: [*]const ?*types.CollSeq = @ptrCast(&key_info.aColl);
    return collations[index];
}

pub fn recordCompareWithSkip(
    key_length: c_int,
    key_pointer: *const anyopaque,
    unpacked: *types.UnpackedRecord,
    skip_first: bool,
) c_int {
    const key: [*]const u8 = @ptrCast(key_pointer);
    const length: usize = @intCast(@max(key_length, 0));
    if (length == 0) {
        unpacked.errCode = 11;
        return 0;
    }
    const header = varint.get32(key);
    if (header.value > length or header.length > header.value) {
        unpacked.errCode = 11;
        return 0;
    }
    var header_index: usize = header.length;
    var data_index: usize = header.value;
    var field: usize = 0;
    if (skip_first) {
        if (header_index >= header.value) {
            unpacked.errCode = 11;
            return 0;
        }
        const serial = varint.get32(key + header_index);
        header_index += serial.length;
        data_index += serialTypeLen(serial.value);
        field = 1;
    }
    const key_info = unpacked.pKeyInfo.?;
    while (field < unpacked.nField) : (field += 1) {
        if (header_index >= header.value or data_index > length) {
            unpacked.errCode = 11;
            return 0;
        }
        const serial = varint.get32(key + header_index);
        const payload_length: usize = serialTypeLen(serial.value);
        if (data_index + payload_length > length) {
            unpacked.errCode = 11;
            return 0;
        }
        var left = std.mem.zeroes(types.Mem);
        left.enc = key_info.enc;
        left.db = key_info.db;
        serialGet(key + data_index, serial.value, &left);
        const right = &unpacked.aMem.?[field];
        const collation = if (left.flags & types.mem_flag.string != 0 and right.flags & types.mem_flag.string != 0)
            keyCollation(key_info, field)
        else
            null;
        var result = compare(&left, right, collation);
        if (key_info.db) |db| {
            if (db.mallocFailed != 0) {
                unpacked.errCode = 7;
                return 0;
            }
        }
        if (result != 0) {
            const sort_flags = key_info.aSortFlags.?[field];
            if (sort_flags != 0) {
                const either_null = left.flags & types.mem_flag.null_ != 0 or right.flags & types.mem_flag.null_ != 0;
                if (sort_flags & 2 == 0 or ((sort_flags & 1 != 0) != either_null)) result = -result;
            }
            return result;
        }
        header_index += serial.length;
        data_index += payload_length;
    }
    unpacked.eqSeen = 1;
    return unpacked.default_rc;
}

pub fn recordCompare(key_length: c_int, key: *const anyopaque, unpacked: *types.UnpackedRecord) callconv(.c) c_int {
    return recordCompareWithSkip(key_length, key, unpacked, false);
}

pub fn recordCompareInt(key_length: c_int, key: *const anyopaque, unpacked: *types.UnpackedRecord) callconv(.c) c_int {
    return recordCompareWithSkip(key_length, key, unpacked, false);
}

pub fn recordCompareString(key_length: c_int, key: *const anyopaque, unpacked: *types.UnpackedRecord) callconv(.c) c_int {
    return recordCompareWithSkip(key_length, key, unpacked, false);
}

pub fn findRecordCompare(unpacked: *types.UnpackedRecord) types.RecordCompare {
    const key_info = unpacked.pKeyInfo.?;
    if (key_info.nAllField <= 13) {
        const flags = unpacked.aMem.?[0].flags;
        if (key_info.aSortFlags.?[0] & 2 != 0) return recordCompare;
        if (key_info.aSortFlags.?[0] != 0) {
            unpacked.r1 = 1;
            unpacked.r2 = -1;
        } else {
            unpacked.r1 = -1;
            unpacked.r2 = 1;
        }
        if (flags & types.mem_flag.integer != 0) {
            unpacked.u.i = unpacked.aMem.?[0].u.i;
            return recordCompareInt;
        }
        if (flags & (types.mem_flag.real | types.mem_flag.integer_real | types.mem_flag.null_ | types.mem_flag.blob) == 0 and
            keyCollation(key_info, 0) == null)
        {
            unpacked.u.z = unpacked.aMem.?[0].z;
            unpacked.n = unpacked.aMem.?[0].n;
            return recordCompareString;
        }
    }
    return recordCompare;
}

pub fn initArray(memories: [*]types.Mem, count: c_int, db: *types.Sqlite3, flags: u16) void {
    var index: usize = 0;
    while (index < @as(usize, @intCast(@max(count, 0)))) : (index += 1) {
        memories[index].flags = flags;
        memories[index].db = db;
        memories[index].szMalloc = 0;
    }
}

pub fn releaseArray(memories_optional: ?[*]types.Mem, count: c_int) void {
    const memories = memories_optional orelse return;
    if (count == 0) return;
    const db = memories[0].db.?;
    var index: usize = 0;
    if (db.pnBytesFreed != null) {
        while (index < @as(usize, @intCast(count))) : (index += 1) {
            if (memories[index].szMalloc != 0) db_allocator.free(db, memories[index].zMalloc);
        }
        return;
    }
    while (index < @as(usize, @intCast(count))) : (index += 1) {
        const mem = &memories[index];
        if (mem.flags & (types.mem_flag.aggregate | types.mem_flag.dynamic) != 0) {
            release(mem);
            mem.flags = types.mem_flag.undefined_;
        } else if (mem.szMalloc != 0) {
            db_allocator.freeConnectionNN(db, mem.zMalloc.?);
            mem.szMalloc = 0;
            mem.flags = types.mem_flag.undefined_;
        }
    }
}

pub fn init(mem: *types.Mem, db: ?*types.Sqlite3, flags: u16) void {
    std.debug.assert((flags & ~types.mem_flag.type_mask) == 0);
    mem.flags = flags;
    mem.db = db;
    mem.szMalloc = 0;
}

pub fn noOpDestructor(_: ?*anyopaque) callconv(.c) void {}

pub fn translate(mem: *types.Mem, desired_encoding: u8) c_int {
    std.debug.assert(mem.flags & types.mem_flag.string != 0);
    std.debug.assert(mem.enc != desired_encoding and mem.enc != 0);
    if (mem.enc != 1 and desired_encoding != 1) {
        if (makeWriteable(mem) != 0) return 7;
        const even_length: usize = @intCast(mem.n & ~@as(c_int, 1));
        var index: usize = 0;
        while (index < even_length) : (index += 2) {
            const temporary = mem.z.?[index];
            mem.z.?[index] = mem.z.?[index + 1];
            mem.z.?[index + 1] = temporary;
        }
        mem.enc = desired_encoding;
        return 0;
    }

    const input_length: usize = if (desired_encoding == 1) blk: {
        mem.n &= ~@as(c_int, 1);
        break :blk @intCast(mem.n);
    } else @intCast(mem.n);
    const maximum: usize = if (desired_encoding == 1) 2 * input_length + 1 else 2 * input_length + 2;
    const raw_output = db_allocator.mallocRaw(mem.db, maximum) orelse return 7;
    const output: [*]u8 = @ptrCast(raw_output);
    var input_index: usize = 0;
    var output_index: usize = 0;
    if (mem.enc == 1) {
        while (input_index < input_length) {
            const decoded = utf.readBounded(mem.z.?[input_index..input_length]);
            input_index += decoded.length;
            var encoded: [4]u8 = undefined;
            const encoded_length = if (desired_encoding == 2)
                utf.writeUtf16Le(&encoded, decoded.value)
            else
                utf.writeUtf16Be(&encoded, decoded.value);
            @memcpy(output[output_index..][0..encoded_length], encoded[0..encoded_length]);
            output_index += encoded_length;
        }
        output[output_index] = 0;
        output[output_index + 1] = 0;
    } else {
        while (input_index + 1 < input_length) {
            var codepoint: u32 = if (mem.enc == 2)
                @as(u32, mem.z.?[input_index]) | @as(u32, mem.z.?[input_index + 1]) << 8
            else
                @as(u32, mem.z.?[input_index]) << 8 | mem.z.?[input_index + 1];
            input_index += 2;
            if (codepoint >= 0xd800 and codepoint < 0xe000 and input_index + 1 < input_length) {
                const second: u32 = if (mem.enc == 2)
                    @as(u32, mem.z.?[input_index]) | @as(u32, mem.z.?[input_index + 1]) << 8
                else
                    @as(u32, mem.z.?[input_index]) << 8 | mem.z.?[input_index + 1];
                input_index += 2;
                codepoint = (second & 0x03ff) + ((codepoint & 0x003f) << 10) + (((codepoint & 0x03c0) + 0x0040) << 10);
            }
            var encoded: [4]u8 = undefined;
            const encoded_length = utf.appendOneUtf8(&encoded, codepoint);
            @memcpy(output[output_index..][0..encoded_length], encoded[0..encoded_length]);
            output_index += encoded_length;
        }
        output[output_index] = 0;
    }
    const flags = types.mem_flag.string | types.mem_flag.terminated |
        (mem.flags & (types.mem_flag.affinity_mask | types.mem_flag.subtype));
    release(mem);
    mem.flags = flags;
    mem.enc = desired_encoding;
    mem.z = output;
    mem.zMalloc = output;
    mem.n = @intCast(output_index);
    mem.szMalloc = @intCast(db_allocator.allocationSize(mem.db, output));
    return 0;
}

pub fn changeEncoding(mem: *types.Mem, desired_encoding: u8) c_int {
    std.debug.assert(desired_encoding >= 1 and desired_encoding <= 3);
    if (mem.flags & types.mem_flag.string == 0) {
        mem.enc = desired_encoding;
        return 0;
    }
    if (mem.enc == desired_encoding) return 0;
    return translate(mem, desired_encoding);
}

pub fn handleBom(mem: *types.Mem) c_int {
    var bom: u8 = 0;
    if (mem.n > 1) {
        if (mem.z.?[0] == 0xfe and mem.z.?[1] == 0xff) bom = 3;
        if (mem.z.?[0] == 0xff and mem.z.?[1] == 0xfe) bom = 2;
    }
    if (bom != 0) {
        if (makeWriteable(mem) != 0) return 7;
        mem.n -= 2;
        const length: usize = @intCast(mem.n);
        std.mem.copyForwards(u8, mem.z.?[0..length], mem.z.?[2 .. length + 2]);
        mem.z.?[length] = 0;
        mem.z.?[length + 1] = 0;
        mem.flags |= types.mem_flag.terminated;
        mem.enc = bom;
    }
    return 0;
}

fn renderNumber(buffer: []u8, mem: *types.Mem) void {
    std.debug.assert(buffer.len > 22);
    std.debug.assert(mem.flags & (types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real) != 0);
    if (mem.flags & (types.mem_flag.integer | types.mem_flag.integer_real) != 0) {
        const text = std.fmt.bufPrint(buffer, "{d}", .{mem.u.i}) catch unreachable;
        mem.n = @intCast(text.len);
        if (mem.flags & types.mem_flag.integer_real != 0) {
            buffer[text.len] = '.';
            buffer[text.len + 1] = '0';
            buffer[text.len + 2] = 0;
            mem.n += 2;
        } else buffer[text.len] = 0;
        return;
    }
    const precision: i64 = if (mem.db) |db| db.nFpDigit else 17;
    const arguments = [_]formatter.FormatArgument{ .{ .signed = precision }, .{ .float = mem.u.r } };
    const length = formatter.fixedFormat(memory.processManager(), buffer, "%!.*g", &arguments);
    buffer[length] = 0;
    mem.n = @intCast(length);
}

pub fn stringify(mem: *types.Mem, desired_encoding: u8, force: bool) c_int {
    if (clearAndResize(mem, 32) != 0) {
        mem.enc = 0;
        return 7;
    }
    renderNumber(mem.z.?[0..32], mem);
    mem.enc = 1;
    mem.flags |= types.mem_flag.string | types.mem_flag.terminated;
    if (force) mem.flags &= ~(types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real);
    _ = changeEncoding(mem, desired_encoding);
    return 0;
}

pub fn grow(mem: *types.Mem, requested: c_int, preserve: bool) c_int {
    std.debug.assert(!preserve or mem.flags & (types.mem_flag.blob | types.mem_flag.string) != 0);
    if (requested <= 0 or @as(u64, @intCast(requested)) > memory.max_allocation_size) {
        setNull(mem);
        mem.z = null;
        mem.szMalloc = 0;
        return 7;
    }
    var keep = preserve;
    if (mem.szMalloc > 0 and keep and mem.z == mem.zMalloc) {
        const old = mem.z.?;
        if (mem.db) |db| {
            mem.z = if (db_allocator.reallocOrFree(db, old, @intCast(requested))) |value| @ptrCast(value) else null;
            mem.zMalloc = mem.z;
        } else {
            const replacement = memory.processManager().realloc(old, @intCast(requested));
            if (replacement == null) memory.process_manager.free(old);
            mem.zMalloc = if (replacement) |value| @ptrCast(value) else null;
            mem.z = mem.zMalloc;
        }
        keep = false;
    } else {
        if (mem.szMalloc > 0) db_allocator.freeNN(mem.db, mem.zMalloc.?);
        mem.zMalloc = if (db_allocator.mallocRaw(mem.db, @intCast(requested))) |value| @ptrCast(value) else null;
    }
    if (mem.zMalloc == null) {
        setNull(mem);
        mem.z = null;
        mem.szMalloc = 0;
        return 7;
    }
    mem.szMalloc = @intCast(db_allocator.allocationSize(mem.db, mem.zMalloc.?));
    if (keep and mem.z != null) {
        @memcpy(mem.zMalloc.?[0..@intCast(mem.n)], mem.z.?[0..@intCast(mem.n)]);
    }
    if (mem.flags & types.mem_flag.dynamic != 0) {
        mem.xDel.?(if (mem.z) |pointer| @ptrCast(pointer) else null);
    }
    mem.z = mem.zMalloc;
    mem.flags &= ~(types.mem_flag.dynamic | types.mem_flag.ephemeral | types.mem_flag.static);
    return 0;
}

pub fn clearAndResize(mem: *types.Mem, requested: c_int) c_int {
    std.debug.assert(requested > 0);
    if (mem.szMalloc < requested) return grow(mem, requested, false);
    mem.z = mem.zMalloc;
    mem.flags &= types.mem_flag.null_ | types.mem_flag.integer | types.mem_flag.real | types.mem_flag.integer_real;
    return 0;
}

pub fn zeroTerminateIfAble(mem: *types.Mem) bool {
    if (mem.flags & (types.mem_flag.string | types.mem_flag.terminated | types.mem_flag.ephemeral | types.mem_flag.static) != types.mem_flag.string)
        return false;
    if (mem.enc != 1 or mem.z == null or mem.n < 0) return false;
    if (mem.flags & types.mem_flag.dynamic != 0) {
        if (mem.xDel == public_api.sqlite3_free and public_api.sqlite3_msize(@ptrCast(mem.z.?)) >= @as(u64, @intCast(mem.n + 1))) {
            mem.z.?[@intCast(mem.n)] = 0;
            mem.flags |= types.mem_flag.terminated;
            return true;
        }
        if (mem.xDel == formatter.rcStrUnrefOpaque) {
            mem.flags |= types.mem_flag.terminated;
            return true;
        }
    } else if (mem.szMalloc >= mem.n + 1) {
        mem.z.?[@intCast(mem.n)] = 0;
        mem.flags |= types.mem_flag.terminated;
        return true;
    }
    return false;
}

fn addTerminator(mem: *types.Mem) c_int {
    if (grow(mem, mem.n + 3, true) != 0) return 7;
    const length: usize = @intCast(mem.n);
    mem.z.?[length] = 0;
    mem.z.?[length + 1] = 0;
    mem.z.?[length + 2] = 0;
    mem.flags |= types.mem_flag.terminated;
    return 0;
}

pub fn expandBlob(mem: *types.Mem) c_int {
    const expanded_length = @as(i64, mem.n) + mem.u.nZero;
    var bytes: c_int = undefined;
    if (expanded_length <= 0) {
        if (mem.flags & types.mem_flag.blob == 0) return 0;
        bytes = 1;
    } else if (expanded_length > std.math.maxInt(c_int)) {
        setNull(mem);
        return 7;
    } else {
        bytes = @intCast(expanded_length);
    }
    if (grow(mem, bytes, true) != 0) return 7;
    @memset(mem.z.?[@intCast(mem.n)..@intCast(mem.n + mem.u.nZero)], 0);
    mem.n += mem.u.nZero;
    mem.flags &= ~(types.mem_flag.zero | types.mem_flag.terminated);
    return 0;
}

pub fn makeWriteable(mem: *types.Mem) c_int {
    if (mem.flags & (types.mem_flag.string | types.mem_flag.blob) != 0) {
        if (mem.flags & types.mem_flag.zero != 0 and expandBlob(mem) != 0) return 7;
        if (mem.szMalloc == 0 or mem.z != mem.zMalloc) {
            const result = addTerminator(mem);
            if (result != 0) return result;
        }
    }
    mem.flags &= ~types.mem_flag.ephemeral;
    return 0;
}

pub fn nulTerminate(mem: *types.Mem) c_int {
    if (mem.flags & (types.mem_flag.terminated | types.mem_flag.string) != types.mem_flag.string) return 0;
    return addTerminator(mem);
}

pub fn finalize(mem: *types.Mem, function: *types.FuncDef) c_int {
    var context: types.Context = std.mem.zeroes(types.Context);
    var output: types.Mem = std.mem.zeroes(types.Mem);
    output.flags = types.mem_flag.null_;
    output.db = mem.db;
    context.pOut = &output;
    context.pMem = mem;
    context.pFunc = function;
    context.enc = types.encoding(output.db.?);
    function.xFinalize.?(&context);
    if (mem.szMalloc > 0) db_allocator.freeNN(mem.db, mem.zMalloc.?);
    mem.* = output;
    return context.isError;
}

pub fn aggregateValue(accumulator: *types.Mem, output: *types.Mem, function: *types.FuncDef) c_int {
    var context: types.Context = std.mem.zeroes(types.Context);
    setNull(output);
    context.pOut = output;
    context.pMem = accumulator;
    context.pFunc = function;
    context.enc = types.encoding(accumulator.db.?);
    function.xValue.?(&context);
    return context.isError;
}

fn clearExternalAndSetNull(mem: *types.Mem) void {
    if (mem.flags & types.mem_flag.aggregate != 0) {
        _ = finalize(mem, mem.u.pDef.?);
    }
    if (mem.flags & types.mem_flag.dynamic != 0) {
        mem.xDel.?(if (mem.z) |pointer| @ptrCast(pointer) else null);
    }
    mem.flags = types.mem_flag.null_;
}

fn clear(mem: *types.Mem) void {
    if (types.memIsDynamic(mem)) clearExternalAndSetNull(mem);
    if (mem.szMalloc != 0) {
        db_allocator.freeNN(mem.db, mem.zMalloc.?);
        mem.szMalloc = 0;
    }
    mem.z = null;
}

pub fn release(mem: *types.Mem) void {
    if (types.memIsDynamic(mem) or mem.szMalloc != 0) clear(mem);
}

pub fn releaseMalloc(mem: *types.Mem) void {
    std.debug.assert(!types.memIsDynamic(mem));
    if (mem.szMalloc != 0) clear(mem);
}

pub fn setNull(mem: *types.Mem) void {
    if (types.memIsDynamic(mem)) clearExternalAndSetNull(mem) else mem.flags = types.mem_flag.null_;
}

pub fn valueSetNull(mem: *types.Mem) void {
    setNull(mem);
}

pub fn setZeroBlob(mem: *types.Mem, length: c_int) void {
    release(mem);
    mem.flags = types.mem_flag.blob | types.mem_flag.zero;
    mem.n = 0;
    mem.u.nZero = @max(length, 0);
    mem.enc = 1;
    mem.z = null;
}

fn releaseAndSetInt64(mem: *types.Mem, value: i64) void {
    setNull(mem);
    mem.u.i = value;
    mem.flags = types.mem_flag.integer;
}

pub fn setInt64(mem: *types.Mem, value: i64) void {
    if (types.memIsDynamic(mem)) {
        releaseAndSetInt64(mem, value);
    } else {
        mem.u.i = value;
        mem.flags = types.mem_flag.integer;
    }
}

pub fn out2PrereleaseWithClear(mem: *types.Mem) *types.Mem {
    setNull(mem);
    mem.flags = types.mem_flag.integer;
    return mem;
}

pub fn out2Prerelease(mem: *types.Mem) *types.Mem {
    if (types.memIsDynamic(mem)) return out2PrereleaseWithClear(mem);
    mem.flags = types.mem_flag.integer;
    return mem;
}

pub fn setArrayInt64(memories: [*]types.Mem, index: c_int, value: i64) void {
    setInt64(&memories[@intCast(index)], value);
}

pub fn setPointer(
    mem: *types.Mem,
    pointer: ?*anyopaque,
    pointer_type: ?[*:0]const u8,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) void {
    std.debug.assert(mem.flags == types.mem_flag.null_);
    clear(mem);
    mem.u.zPType = pointer_type orelse "";
    mem.z = if (pointer) |value| @ptrCast(value) else null;
    mem.flags = types.mem_flag.null_ | types.mem_flag.dynamic | types.mem_flag.subtype | types.mem_flag.terminated;
    mem.eSubtype = 'p';
    mem.xDel = destructor orelse noOpDestructor;
}

pub fn setDouble(mem: *types.Mem, value: f64) void {
    setNull(mem);
    if (!std.math.isNan(value)) {
        mem.u.r = value;
        mem.flags = types.mem_flag.real;
    }
}

pub fn isRowSet(mem: *const types.Mem) bool {
    return mem.flags & (types.mem_flag.blob | types.mem_flag.dynamic) ==
        (types.mem_flag.blob | types.mem_flag.dynamic) and
        mem.xDel == rowset.RowSet.deleteOpaque;
}

pub fn setRowSet(mem: *types.Mem, allocator: std.mem.Allocator) std.mem.Allocator.Error!*rowset.RowSet {
    std.debug.assert(!isRowSet(mem));
    release(mem);
    const value = try rowset.RowSet.create(allocator);
    mem.z = @ptrCast(value);
    mem.flags = types.mem_flag.blob | types.mem_flag.dynamic;
    mem.xDel = rowset.RowSet.deleteOpaque;
    return value;
}

pub fn rowSet(mem: *types.Mem) ?*rowset.RowSet {
    if (!isRowSet(mem)) return null;
    return @ptrCast(@alignCast(mem.z.?));
}

pub fn tooBig(mem: *const types.Mem) bool {
    if (mem.flags & (types.mem_flag.string | types.mem_flag.blob) == 0) return false;
    var length: i64 = @max(mem.n, 0);
    if (mem.flags & types.mem_flag.zero != 0) length += @max(mem.u.nZero, 0);
    const limit: i64 = if (mem.db) |db| db.aLimit[0] else 1_000_000_000;
    return length > limit;
}

fn copyCellPrefix(to: *types.Mem, from: *const types.Mem) void {
    @memcpy(std.mem.asBytes(to)[0..types.mem_cell_prefix_size], std.mem.asBytes(from)[0..types.mem_cell_prefix_size]);
}

fn clearCopy(to: *types.Mem, from: *const types.Mem, source_type: u16) void {
    clearExternalAndSetNull(to);
    std.debug.assert(!types.memIsDynamic(to));
    shallowCopy(to, from, source_type);
}

pub fn shallowCopy(to: *types.Mem, from: *const types.Mem, source_type: u16) void {
    std.debug.assert(to.db == from.db);
    if (types.memIsDynamic(to)) {
        clearCopy(to, from, source_type);
        return;
    }
    copyCellPrefix(to, from);
    if (from.flags & types.mem_flag.static == 0) {
        to.flags &= ~(types.mem_flag.dynamic | types.mem_flag.static | types.mem_flag.ephemeral);
        std.debug.assert(source_type == types.mem_flag.ephemeral or source_type == types.mem_flag.static);
        to.flags |= source_type;
    }
}

pub const StringOwnership = union(enum) {
    static,
    transient,
    dynamic,
    custom: *const fn (?*anyopaque) callconv(.c) void,
};

fn disposeInput(mem: *types.Mem, source: [*]const u8, ownership: StringOwnership) void {
    switch (ownership) {
        .static, .transient => {},
        .dynamic => db_allocator.free(mem.db, @ptrCast(@constCast(source))),
        .custom => |destructor| destructor(@ptrCast(@constCast(source))),
    }
}

/// Source `invokeValueDestructor()`: consume a rejected non-dynamic input and
/// publish SQLITE_TOOBIG when a valid function context is available.
pub fn invokeValueDestructor(pointer: ?*const anyopaque, ownership: StringOwnership, context: ?*types.Context) c_int {
    switch (ownership) {
        .static, .transient => {},
        .custom => |destructor| destructor(if (pointer) |value| @ptrCast(@constCast(value)) else null),
        .dynamic => unreachable,
    }
    if (context) |active| resultErrorTooBig(active);
    return 18;
}

fn valueToText(value: *types.Mem, encoding_argument: u8) ?[*]const u8 {
    const encoding = encoding_argument & ~@as(u8, 8);
    std.debug.assert(encoding >= 1 and encoding <= 3);
    if (value.flags & (types.mem_flag.blob | types.mem_flag.string) != 0) {
        if (value.flags & types.mem_flag.zero != 0 and expandBlob(value) != 0) return null;
        value.flags |= types.mem_flag.string;
        if (value.enc != encoding and changeEncoding(value, encoding) != 0) return null;
        if (encoding_argument & 8 != 0 and @intFromPtr(value.z.?) & 1 != 0) {
            if (makeWriteable(value) != 0) return null;
        }
        if (nulTerminate(value) != 0) return null;
    } else {
        if (stringify(value, encoding, false) != 0) return null;
    }
    return if (value.enc == encoding) value.z else null;
}

fn setResultStrOrError(
    context: *types.Context,
    source: ?[*]const u8,
    length: i64,
    encoding: u8,
    ownership: StringOwnership,
) void {
    const output = context.pOut.?;
    const result = if (encoding == 1 and output.db != null)
        setText(output, source, length, ownership)
    else if (encoding == 16 and output.db != null) blk: {
        const rc = setText(output, source, length, ownership);
        output.flags |= types.mem_flag.terminated;
        break :blk rc;
    } else setStr(output, source, length, encoding, ownership);
    if (result != 0) {
        context.isError = result;
        return;
    }
    if (context.enc >= 1 and context.enc <= 3) _ = changeEncoding(output, context.enc);
    if (tooBig(output)) context.isError = 18;
}

pub fn resultBlob(context: *types.Context, source: ?[*]const u8, length: c_int, ownership: StringOwnership) void {
    setResultStrOrError(context, source, length, 0, ownership);
}

pub fn resultBlob64(context: *types.Context, source: ?[*]const u8, length: u64, ownership: StringOwnership) void {
    if (length > std.math.maxInt(c_int)) {
        _ = invokeValueDestructor(if (source) |pointer| @ptrCast(pointer) else null, ownership, context);
        return;
    }
    setResultStrOrError(context, source, @intCast(length), 0, ownership);
}

pub fn resultText(context: *types.Context, source: ?[*]const u8, length: c_int, ownership: StringOwnership) void {
    setResultStrOrError(context, source, length, 1, ownership);
}

pub fn resultText64(context: *types.Context, source: ?[*]const u8, length_argument: u64, encoding_argument: u8, ownership: StringOwnership) void {
    var length = length_argument;
    var encoding = encoding_argument;
    if (encoding != 1 and encoding != 16) {
        if (encoding == 4) encoding = 2;
        length &= ~@as(u64, 1);
    }
    if (length > std.math.maxInt(c_int)) {
        _ = invokeValueDestructor(if (source) |pointer| @ptrCast(pointer) else null, ownership, context);
        return;
    }
    setResultStrOrError(context, source, @intCast(length), encoding, ownership);
    _ = zeroTerminateIfAble(context.pOut.?);
}

pub fn resultText16(context: *types.Context, source: ?[*]const u8, length: c_int, encoding: u8, ownership: StringOwnership) void {
    setResultStrOrError(context, source, length & ~@as(c_int, 1), encoding, ownership);
}

pub fn resultError(context: *types.Context, source: ?[*]const u8, length: c_int) void {
    context.isError = 1;
    _ = setStr(context.pOut.?, source, length, 1, .transient);
}

pub fn resultError16(context: *types.Context, source: ?[*]const u8, length: c_int) void {
    context.isError = 1;
    _ = setStr(context.pOut.?, source, length, 2, .transient);
}

pub fn resultPointer(
    context: *types.Context,
    pointer: ?*anyopaque,
    pointer_type: ?[*:0]const u8,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) void {
    const output = context.pOut.?;
    release(output);
    output.flags = types.mem_flag.null_;
    setPointer(output, pointer, pointer_type, destructor);
}

pub fn userData(context: *types.Context) ?*anyopaque {
    return context.pFunc.?.pUserData;
}

pub fn contextDatabase(context: *types.Context) ?*types.Sqlite3 {
    return context.pOut.?.db;
}

pub fn virtualTableNoChange(context: *types.Context) bool {
    return valueNoChange(context.pOut.?);
}

fn createAggregateContext(context: *types.Context, byte_count: c_int) ?*anyopaque {
    const aggregate = context.pMem.?;
    if (byte_count <= 0) {
        setNull(aggregate);
        aggregate.z = null;
    } else {
        if (clearAndResize(aggregate, byte_count) != 0) return null;
        aggregate.flags = types.mem_flag.aggregate;
        aggregate.u.pDef = context.pFunc;
        @memset(aggregate.z.?[0..@intCast(byte_count)], 0);
    }
    return if (aggregate.z) |pointer| @ptrCast(pointer) else null;
}

pub fn aggregateContext(context: *types.Context, byte_count: c_int) ?*anyopaque {
    if (context.pMem.?.flags & types.mem_flag.aggregate == 0)
        return createAggregateContext(context, byte_count);
    return if (context.pMem.?.z) |pointer| @ptrCast(pointer) else null;
}

pub fn aggregateCount(context: *types.Context) c_int {
    return context.pMem.?.n;
}

pub fn deleteAuxData(machine: *types.Vdbe, operation: c_int, mask: u32) void {
    var link = &machine.pAuxData;
    while (link.*) |entry| {
        const remove = operation < 0 or
            (entry.iAuxOp == operation and entry.iAuxArg >= 0 and
                (entry.iAuxArg > 31 or mask & (@as(u32, 1) << @intCast(entry.iAuxArg)) == 0));
        if (remove) {
            if (entry.xDeleteAux) |destroy| destroy(entry.pAux);
            link.* = entry.pNextAux;
            db_allocator.freeNN(machine.db, entry);
        } else {
            link = &entry.pNextAux;
        }
    }
}

pub fn getAuxData(context: *types.Context, argument: c_int) ?*anyopaque {
    var auxiliary = context.pVdbe.?.pAuxData;
    while (auxiliary) |entry| : (auxiliary = entry.pNextAux) {
        if (entry.iAuxArg == argument and (entry.iAuxOp == context.iOp or argument < 0)) return entry.pAux;
    }
    return null;
}

pub fn setAuxData(
    context: *types.Context,
    argument: c_int,
    data: ?*anyopaque,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) void {
    const machine = context.pVdbe.?;
    var auxiliary = machine.pAuxData;
    while (auxiliary) |entry| : (auxiliary = entry.pNextAux) {
        if (entry.iAuxArg == argument and (entry.iAuxOp == context.iOp or argument < 0)) break;
    }
    if (auxiliary == null) {
        const raw = db_allocator.mallocZero(machine.db, @sizeOf(types.AuxData)) orelse {
            if (destructor) |destroy| destroy(data);
            return;
        };
        auxiliary = @ptrCast(@alignCast(raw));
        auxiliary.?.iAuxOp = context.iOp;
        auxiliary.?.iAuxArg = argument;
        auxiliary.?.pNextAux = machine.pAuxData;
        machine.pAuxData = auxiliary;
        if (context.isError == 0) context.isError = -1;
    } else if (auxiliary.?.xDeleteAux) |destroy| {
        destroy(auxiliary.?.pAux);
    }
    auxiliary.?.pAux = data;
    auxiliary.?.xDeleteAux = destructor;
}

pub fn errorString(code_argument: c_int) [:0]const u8 {
    if (code_argument == 516) return "abort due to ROLLBACK";
    if (code_argument == 100) return "another row available";
    if (code_argument == 101) return "no more rows available";
    return switch (code_argument & 0xff) {
        0 => "not an error",
        1 => "SQL logic error",
        3 => "access permission denied",
        4 => "query aborted",
        5 => "database is locked",
        6 => "database table is locked",
        7 => "out of memory",
        8 => "attempt to write a readonly database",
        9 => "interrupted",
        10 => "disk I/O error",
        11 => "database disk image is malformed",
        12 => "unknown operation",
        13 => "database or disk is full",
        14 => "unable to open database file",
        15 => "locking protocol",
        17 => "database schema has changed",
        18 => "string or blob too big",
        19 => "constraint failed",
        20 => "datatype mismatch",
        21 => "bad parameter or other API misuse",
        23 => "authorization denied",
        25 => "column index out of range",
        26 => "file is not a database",
        27 => "notification message",
        28 => "warning message",
        else => "unknown error",
    };
}

pub fn resultErrorCode(context: *types.Context, code: c_int) void {
    context.isError = if (code != 0) code else -1;
    if (context.pOut.?.flags & types.mem_flag.null_ != 0) {
        const message = errorString(code);
        setResultStrOrError(context, message.ptr, -1, 1, .static);
    }
}

pub fn resultErrorTooBig(context: *types.Context) void {
    context.isError = 18;
    _ = setStr(context.pOut.?, "string or blob too big", -1, 1, .static);
}

/// Source `sqlite3VdbeValueListFree()`.
pub fn valueListFree(pointer: ?*anyopaque) callconv(.c) void {
    if (pointer) |value| memory.processManager().free(value);
}

pub fn resultErrorNoMem(context: *types.Context) void {
    setNull(context.pOut.?);
    context.isError = 7;
    if (context.pOut.?.db) |db| _ = db_allocator.oomFault(db);
}

pub fn resultIntReal(context: *types.Context) void {
    const output = context.pOut.?;
    if (output.flags & types.mem_flag.integer != 0) {
        output.flags &= ~types.mem_flag.integer;
        output.flags |= types.mem_flag.integer_real;
    }
}

pub fn resultDouble(context: *types.Context, value: f64) void {
    setDouble(context.pOut.?, value);
}

pub fn resultInt(context: *types.Context, value: c_int) void {
    setInt64(context.pOut.?, value);
}

pub fn resultInt64(context: *types.Context, value: i64) void {
    setInt64(context.pOut.?, value);
}

pub fn resultNull(context: *types.Context) void {
    setNull(context.pOut.?);
}

pub fn resultSubtype(context: *types.Context, subtype: c_uint) void {
    const output = context.pOut.?;
    output.eSubtype = @truncate(subtype);
    output.flags |= types.mem_flag.subtype;
}

pub fn resultValue(context: *types.Context, value: *const types.Mem) void {
    const output = context.pOut.?;
    if (copy(output, value) != 0) {
        context.isError = 7;
        return;
    }
    if (context.enc >= 1 and context.enc <= 3) _ = changeEncoding(output, context.enc);
    if (tooBig(output)) context.isError = 18;
}

pub fn resultZeroBlob64(context: *types.Context, length: u64) c_int {
    const output = context.pOut.?;
    const limit: u64 = if (output.db) |db| @intCast(db.aLimit[0]) else 1_000_000_000;
    if (length > limit) {
        context.isError = 18;
        return 18;
    }
    setZeroBlob(output, @intCast(length));
    return 0;
}

pub fn resultZeroBlob(context: *types.Context, length: c_int) void {
    _ = resultZeroBlob64(context, @intCast(@max(length, 0)));
}

pub fn valueBlob(value: *types.Mem) ?[*]const u8 {
    if (value.flags & (types.mem_flag.blob | types.mem_flag.string) != 0) {
        if (value.flags & types.mem_flag.zero != 0 and expandBlob(value) != 0) return null;
        value.flags |= types.mem_flag.blob;
        return if (value.n != 0) value.z else null;
    }
    return valueText(value, 1);
}

pub fn valueDouble(value: *types.Mem) f64 {
    return realValue(value);
}

pub fn valueInt(value: *types.Mem) c_int {
    return @truncate(intValue(value));
}

pub fn valueInt64(value: *types.Mem) i64 {
    return intValue(value);
}

pub fn valueSubtype(value: *types.Mem) c_uint {
    return if (value.flags & types.mem_flag.subtype != 0) value.eSubtype else 0;
}

pub fn valuePointer(value: *types.Mem, pointer_type: ?[*:0]const u8) ?*anyopaque {
    const requested = pointer_type orelse return null;
    if (value.flags & (types.mem_flag.type_mask | types.mem_flag.terminated | types.mem_flag.subtype) ==
        (types.mem_flag.null_ | types.mem_flag.terminated | types.mem_flag.subtype) and
        value.eSubtype == 'p' and value.u.zPType != null and
        std.mem.eql(u8, std.mem.span(value.u.zPType.?), std.mem.span(requested)))
    {
        return if (value.z) |pointer| @ptrCast(pointer) else null;
    }
    return null;
}

pub fn valueText(value_optional: ?*types.Mem, encoding: u8) ?[*]const u8 {
    const value = value_optional orelse return null;
    if (value.flags & (types.mem_flag.string | types.mem_flag.terminated) ==
        (types.mem_flag.string | types.mem_flag.terminated) and value.enc == encoding)
    {
        return value.z;
    }
    if (value.flags & types.mem_flag.null_ != 0) return null;
    return valueToText(value, encoding);
}

pub fn valueType(value: *const types.Mem) c_int {
    if (value.flags & types.mem_flag.null_ != 0) return 5;
    if (value.flags & (types.mem_flag.real | types.mem_flag.integer_real) != 0) return 2;
    if (value.flags & types.mem_flag.integer != 0) return 1;
    if (value.flags & types.mem_flag.string != 0) return 3;
    return 4;
}

pub fn valueEncoding(value: *const types.Mem) c_int {
    return value.enc;
}

/// Upstream: sqlite3Utf16to8(). The returned process/connection allocation is
/// transferred to the caller and must be released through db_allocator.free().
pub fn utf16To8(db: *types.Sqlite3, source: *const anyopaque, byte_count: c_int, encoding: u8) ?[*:0]u8 {
    var value: types.Mem = undefined;
    init(&value, db, types.mem_flag.null_);
    _ = setStr(&value, @ptrCast(source), byte_count, encoding, .static);
    _ = changeEncoding(&value, 1);
    if (db.mallocFailed != 0) {
        release(&value);
        value.z = null;
    }
    return if (value.z) |text| @ptrCast(text) else null;
}

pub fn valueNoChange(value: *const types.Mem) bool {
    return value.flags & (types.mem_flag.null_ | types.mem_flag.zero) == (types.mem_flag.null_ | types.mem_flag.zero);
}

pub fn valueFromBind(value: *const types.Mem) bool {
    return value.flags & types.mem_flag.from_bind != 0;
}

pub fn valueNumericType(value: *types.Mem) c_int {
    var result = valueType(value);
    if (result == 3) {
        applyNumericAffinity(value, false);
        result = valueType(value);
    }
    return result;
}

pub fn valueDuplicate(original_optional: ?*const types.Mem) ?*types.Mem {
    const original = original_optional orelse return null;
    const raw = db_allocator.mallocZero(null, @sizeOf(types.Mem)) orelse return null;
    const duplicate: *types.Mem = @ptrCast(@alignCast(raw));
    @memcpy(
        std.mem.asBytes(duplicate)[0..types.mem_cell_prefix_size],
        std.mem.asBytes(original)[0..types.mem_cell_prefix_size],
    );
    duplicate.flags &= ~types.mem_flag.dynamic;
    duplicate.db = null;
    if (duplicate.flags & (types.mem_flag.string | types.mem_flag.blob) != 0) {
        duplicate.flags &= ~(types.mem_flag.static | types.mem_flag.dynamic);
        duplicate.flags |= types.mem_flag.ephemeral;
        if (makeWriteable(duplicate) != 0) {
            valueFree(duplicate);
            return null;
        }
    } else if (duplicate.flags & types.mem_flag.null_ != 0) {
        duplicate.flags &= ~(types.mem_flag.terminated | types.mem_flag.subtype);
    }
    return duplicate;
}

pub fn valueIsOfClass(value: *const types.Mem, destructor: *const fn (?*anyopaque) callconv(.c) void) bool {
    return value.flags & (types.mem_flag.string | types.mem_flag.blob) != 0 and
        value.flags & types.mem_flag.dynamic != 0 and value.xDel == destructor;
}

pub fn valueNew(db: ?*types.Sqlite3) ?*types.Mem {
    const raw = db_allocator.mallocZero(db, @sizeOf(types.Mem)) orelse return null;
    const value: *types.Mem = @ptrCast(@alignCast(raw));
    value.flags = types.mem_flag.null_;
    value.db = db;
    return value;
}

pub fn valueSetStr(value: ?*types.Mem, length: c_int, source: ?[*]const u8, encoding: u8, ownership: StringOwnership) void {
    if (value) |mem| _ = setStr(mem, source, length, encoding, ownership);
}

pub fn valueFree(value: ?*types.Mem) void {
    const mem = value orelse return;
    release(mem);
    db_allocator.freeNN(mem.db, mem);
}

fn valueBytesSlow(value: *types.Mem, encoding: u8) c_int {
    return if (valueToText(value, encoding) != null) value.n else 0;
}

pub fn valueBytes(value: *types.Mem, encoding: u8) c_int {
    std.debug.assert(encoding >= 1 and encoding <= 3);
    if (value.flags & types.mem_flag.string != 0 and value.enc == encoding) return @max(value.n, 0);
    if (value.flags & types.mem_flag.string != 0 and encoding != 1 and value.enc != 1) return value.n;
    if (value.flags & types.mem_flag.blob != 0) {
        const length = @as(i64, @max(value.n, 0)) + if (value.flags & types.mem_flag.zero != 0) @max(value.u.nZero, 0) else 0;
        return @intCast(@min(length, std.math.maxInt(c_int)));
    }
    if (value.flags & types.mem_flag.null_ != 0) return 0;
    return valueBytesSlow(value, encoding);
}

pub fn setStr(
    mem: *types.Mem,
    source_optional: ?[*]const u8,
    length_argument: i64,
    encoding_argument: u8,
    ownership: StringOwnership,
) c_int {
    const source = source_optional orelse {
        setNull(mem);
        return 0;
    };
    std.debug.assert(encoding_argument != 0 or length_argument >= 0);
    const limit: i64 = if (mem.db) |db| db.aLimit[0] else 1_000_000_000;
    var encoding = encoding_argument;
    var length = length_argument;
    var flags: u16 = undefined;
    if (length < 0) {
        std.debug.assert(encoding != 0);
        if (encoding == 1) {
            length = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(source))));
        } else {
            length = 0;
            while (length <= limit and (source[@intCast(length)] | source[@intCast(length + 1)]) != 0) : (length += 2) {}
        }
        flags = types.mem_flag.string | types.mem_flag.terminated;
    } else if (encoding == 0) {
        flags = types.mem_flag.blob;
        encoding = 1;
    } else {
        flags = types.mem_flag.string;
    }
    if (length > limit) {
        if (ownership != .transient) disposeInput(mem, source, ownership);
        setNull(mem);
        return 18;
    }
    switch (ownership) {
        .transient => {
            var allocation = length;
            if (flags & types.mem_flag.terminated != 0) allocation += if (encoding == 1) 1 else 2;
            if (allocation > std.math.maxInt(c_int)) return 7;
            if (clearAndResize(mem, @intCast(@max(allocation, 32))) != 0) return 7;
            const byte_length: usize = @intCast(allocation);
            @memcpy(mem.z.?[0..byte_length], source[0..byte_length]);
        },
        else => {
            release(mem);
            mem.z = @constCast(source);
            switch (ownership) {
                .dynamic => {
                    mem.zMalloc = mem.z;
                    mem.szMalloc = @intCast(db_allocator.allocationSize(mem.db, mem.zMalloc.?));
                    mem.xDel = null;
                },
                .static => {
                    mem.xDel = null;
                    flags |= types.mem_flag.static;
                },
                .custom => |destructor| {
                    mem.xDel = destructor;
                    flags |= types.mem_flag.dynamic;
                },
                .transient => unreachable,
            }
        },
    }
    mem.n = @intCast(length & 0x7fff_ffff);
    mem.flags = flags;
    mem.enc = encoding;
    if (encoding > 1 and handleBom(mem) != 0) return 7;
    return 0;
}

pub fn setText(mem: *types.Mem, source_optional: ?[*]const u8, length_argument: i64, ownership: StringOwnership) c_int {
    const source = source_optional orelse {
        setNull(mem);
        return 0;
    };
    const db = mem.db.?;
    const length: i64 = if (length_argument < 0)
        @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(source))))
    else
        length_argument;
    var flags: u16 = if (length_argument < 0)
        types.mem_flag.string | types.mem_flag.terminated
    else
        types.mem_flag.string;
    if (length > db.aLimit[0]) {
        if (ownership != .transient) disposeInput(mem, source, ownership);
        setNull(mem);
        return 18;
    }
    switch (ownership) {
        .transient => {
            if (length >= std.math.maxInt(c_int)) return 7;
            const allocation: c_int = @intCast(@max(length + 1, 32));
            if (clearAndResize(mem, allocation) != 0) return 7;
            const byte_length: usize = @intCast(length);
            @memcpy(mem.z.?[0..byte_length], source[0..byte_length]);
            mem.z.?[byte_length] = 0;
        },
        else => {
            release(mem);
            mem.z = @constCast(source);
            switch (ownership) {
                .dynamic => {
                    mem.zMalloc = mem.z;
                    mem.szMalloc = @intCast(db_allocator.allocationSize(mem.db, mem.zMalloc.?));
                    mem.xDel = null;
                },
                .static => {
                    mem.xDel = null;
                    flags |= types.mem_flag.static;
                },
                .custom => |destructor| {
                    mem.xDel = destructor;
                    flags |= types.mem_flag.dynamic;
                },
                .transient => unreachable,
            }
        },
    }
    mem.flags = flags;
    mem.n = @intCast(length & 0x7fff_ffff);
    mem.enc = 1;
    return 0;
}

pub fn copy(to: *types.Mem, from: *const types.Mem) c_int {
    if (to == from) return 0;
    std.debug.assert(!isRowSet(from));
    if (types.memIsDynamic(to)) clearExternalAndSetNull(to);
    copyCellPrefix(to, from);
    to.flags &= ~types.mem_flag.dynamic;
    if (to.flags & (types.mem_flag.string | types.mem_flag.blob) != 0 and
        from.flags & types.mem_flag.static == 0)
    {
        to.flags |= types.mem_flag.ephemeral;
        return makeWriteable(to);
    }
    return 0;
}

pub fn move(to: *types.Mem, from: *types.Mem) void {
    if (to == from) return;
    std.debug.assert(from.db == null or to.db == null or from.db == to.db);
    release(to);
    to.* = from.*;
    from.flags = types.mem_flag.null_;
    from.szMalloc = 0;
}

var test_aux_destructor_calls: usize = 0;
fn testAuxDestructor(_: ?*anyopaque) callconv(.c) void {
    test_aux_destructor_calls += 1;
}

test "VDBE auxiliary data deletion honors opcode masks and ownership" {
    test_aux_destructor_calls = 0;
    var machine = std.mem.zeroes(types.Vdbe);
    var output = std.mem.zeroes(types.Mem);
    var aggregate = std.mem.zeroes(types.Mem);
    init(&output, null, types.mem_flag.null_);
    init(&aggregate, null, types.mem_flag.null_);
    var context = std.mem.zeroes(types.Context);
    context.pOut = &output;
    context.pMem = &aggregate;
    context.pVdbe = &machine;
    context.iOp = 7;
    var first: u8 = 1;
    var high: u8 = 2;
    var other: u8 = 3;
    setAuxData(&context, 0, &first, testAuxDestructor);
    setAuxData(&context, 33, &high, testAuxDestructor);
    context.iOp = 8;
    setAuxData(&context, 1, &other, testAuxDestructor);

    deleteAuxData(&machine, 7, 1);
    try std.testing.expectEqual(@as(usize, 1), test_aux_destructor_calls);
    context.iOp = 7;
    try std.testing.expect(getAuxData(&context, 0) == @as(*anyopaque, @ptrCast(&first)));
    try std.testing.expect(getAuxData(&context, 33) == null);
    deleteAuxData(&machine, 7, 0);
    try std.testing.expectEqual(@as(usize, 2), test_aux_destructor_calls);
    deleteAuxData(&machine, -1, 0);
    try std.testing.expectEqual(@as(usize, 3), test_aux_destructor_calls);
    try std.testing.expect(machine.pAuxData == null);
}

test "Mem ownership release and setters" {
    var mem = std.mem.zeroes(types.Mem);
    init(&mem, null, types.mem_flag.null_);
    setZeroBlob(&mem, 12);
    try std.testing.expectEqual(types.mem_flag.blob | types.mem_flag.zero, mem.flags);
    try std.testing.expectEqual(@as(c_int, 12), mem.u.nZero);
    setInt64(&mem, -42);
    try std.testing.expectEqual(types.mem_flag.integer, mem.flags);
    try std.testing.expectEqual(@as(i64, -42), mem.u.i);
    setDouble(&mem, std.math.nan(f64));
    try std.testing.expectEqual(types.mem_flag.null_, mem.flags);
}

test "source rejected result input runs destructor and publishes too-big" {
    const Harness = struct {
        var calls: c_int = 0;
        fn destroy(_: ?*anyopaque) callconv(.c) void {
            calls += 1;
        }
    };
    Harness.calls = 0;
    var output = std.mem.zeroes(types.Mem);
    init(&output, null, types.mem_flag.null_);
    var context = std.mem.zeroes(types.Context);
    context.pOut = &output;
    var byte: u8 = 1;
    try std.testing.expectEqual(@as(c_int, 18), invokeValueDestructor(&byte, .{ .custom = Harness.destroy }, &context));
    try std.testing.expectEqual(@as(c_int, 1), Harness.calls);
    try std.testing.expectEqual(@as(c_int, 18), context.isError);
    try std.testing.expect(output.flags & types.mem_flag.string != 0);
}

test "source Mem overflow and RCStr terminator paths are bounded" {
    var overflow = std.mem.zeroes(types.Mem);
    init(&overflow, null, types.mem_flag.blob | types.mem_flag.zero);
    overflow.n = std.math.maxInt(c_int);
    overflow.u.nZero = 1;
    try std.testing.expectEqual(@as(c_int, 7), expandBlob(&overflow));
    try std.testing.expectEqual(types.mem_flag.null_, overflow.flags);

    overflow.flags = types.mem_flag.blob | types.mem_flag.zero;
    overflow.n = std.math.maxInt(c_int);
    overflow.u.nZero = std.math.maxInt(c_int);
    try std.testing.expectEqual(std.math.maxInt(c_int), valueBytes(&overflow, 1));

    const text = formatter.rcStrNew(memory.processManager(), 4).?;
    @memcpy(text[0..4], "rcs\x00");
    var counted = std.mem.zeroes(types.Mem);
    init(&counted, null, types.mem_flag.string);
    counted.flags |= types.mem_flag.dynamic;
    counted.z = text;
    counted.n = 3;
    counted.enc = 1;
    counted.xDel = formatter.rcStrUnrefOpaque;
    try std.testing.expect(zeroTerminateIfAble(&counted));
    try std.testing.expect(counted.flags & types.mem_flag.terminated != 0);
    release(&counted);
}

test "real/integer boundaries and Mem minimum initialization" {
    try std.testing.expectEqual(std.math.minInt(i64), realToI64(-std.math.inf(f64)));
    try std.testing.expectEqual(std.math.maxInt(i64), realToI64(std.math.inf(f64)));
    try std.testing.expect(realSameAsInt(0.0, 0));
    try std.testing.expect(!realSameAsInt(2_251_799_813_685_248.0, 2_251_799_813_685_248));
    try std.testing.expectEqual(@as(c_int, 1), intFloatCompare(0, std.math.nan(f64)));
    try std.testing.expectEqual(@as(c_int, -1), intFloatCompare(4, 4.5));

    var mem: types.Mem = undefined;
    init(&mem, null, types.mem_flag.null_);
    try std.testing.expectEqual(types.mem_flag.null_, mem.flags);
    try std.testing.expectEqual(@as(c_int, 0), mem.szMalloc);
    try std.testing.expectEqual(null, mem.db);

    mem.flags = types.mem_flag.real;
    mem.u.r = 42.0;
    integerAffinity(&mem);
    try std.testing.expectEqual(types.mem_flag.integer, mem.flags);
    try std.testing.expectEqual(@as(i64, 42), mem.u.i);
    mem.flags = types.mem_flag.string;
    mem.z = @constCast("-17x".ptr);
    mem.n = 4;
    mem.enc = 1;
    try std.testing.expectEqual(@as(i64, -17), intValue(&mem));
    try std.testing.expectEqual(@as(c_int, 0), integerify(&mem));
    try std.testing.expectEqual(types.mem_flag.integer, mem.flags);
}
