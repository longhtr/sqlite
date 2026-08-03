//! Source-corresponding VDBE record serial-type length and decode helpers.

pub const types = @import("vdbe_types.zig");
const db_allocator = @import("db_allocator.zig");
const vdbe_mem = @import("vdbe_mem.zig");
const varint = @import("../varint.zig");

pub const small_type_sizes: [128]u8 = blk: {
    var sizes = [_]u8{0} ** 128;
    sizes[1] = 1;
    sizes[2] = 2;
    sizes[3] = 3;
    sizes[4] = 4;
    sizes[5] = 6;
    sizes[6] = 8;
    sizes[7] = 8;
    for (12..128) |serial_type| sizes[serial_type] = @intCast((serial_type - 12) / 2);
    break :blk sizes;
};

pub fn serialTypeLength(serial_type: u32) u32 {
    if (serial_type >= 128) return (serial_type - 12) / 2;
    return small_type_sizes[serial_type];
}

pub fn oneByteSerialTypeLength(serial_type: u8) u8 {
    return small_type_sizes[serial_type];
}

fn oneByteInteger(input: [*]const u8) i64 {
    return @as(i8, @bitCast(input[0]));
}

fn twoByteInteger(input: [*]const u8) i64 {
    const bits = (@as(u16, input[0]) << 8) | input[1];
    return @as(i16, @bitCast(bits));
}

fn threeByteInteger(input: [*]const u8) i64 {
    const bits = (@as(u32, input[0]) << 16) | (@as(u32, input[1]) << 8) | input[2];
    return if (bits & 0x0080_0000 != 0) @as(i64, bits) - 0x0100_0000 else bits;
}

fn fourByteUnsigned(input: [*]const u8) u32 {
    return (@as(u32, input[0]) << 24) | (@as(u32, input[1]) << 16) | (@as(u32, input[2]) << 8) | input[3];
}

fn fourByteInteger(input: [*]const u8) i64 {
    return @as(i32, @bitCast(fourByteUnsigned(input)));
}

fn serialGet(input: [*]const u8, serial_type: u32, value: *types.Mem) void {
    const bits = (@as(u64, fourByteUnsigned(input)) << 32) | fourByteUnsigned(input + 4);
    if (serial_type == 6) {
        value.u.i = @bitCast(bits);
        value.flags = types.mem_flag.integer;
    } else {
        const real: f64 = @bitCast(bits);
        value.u.r = real;
        value.flags = if (real != real) types.mem_flag.null_ else types.mem_flag.real;
    }
}

pub fn serialGet7(input: [*]const u8, value: *types.Mem) c_int {
    const bits = (@as(u64, fourByteUnsigned(input)) << 32) | fourByteUnsigned(input + 4);
    const real: f64 = @bitCast(bits);
    value.u.r = real;
    if (real != real) {
        value.flags = types.mem_flag.null_;
        return 1;
    }
    value.flags = types.mem_flag.real;
    return 0;
}

pub fn serialGetValue(input: [*]const u8, serial_type: u32, value: *types.Mem) void {
    switch (serial_type) {
        10 => {
            value.flags = types.mem_flag.null_ | types.mem_flag.zero;
            value.n = 0;
            value.u.nZero = 0;
        },
        0, 11 => value.flags = types.mem_flag.null_,
        1 => {
            value.u.i = oneByteInteger(input);
            value.flags = types.mem_flag.integer;
        },
        2 => {
            value.u.i = twoByteInteger(input);
            value.flags = types.mem_flag.integer;
        },
        3 => {
            value.u.i = threeByteInteger(input);
            value.flags = types.mem_flag.integer;
        },
        4 => {
            value.u.i = fourByteInteger(input);
            value.flags = types.mem_flag.integer;
        },
        5 => {
            value.u.i = @as(i64, fourByteUnsigned(input + 2)) + (@as(i64, 1) << 32) * twoByteInteger(input);
            value.flags = types.mem_flag.integer;
        },
        6, 7 => serialGet(input, serial_type, value),
        8, 9 => {
            value.u.i = serial_type - 8;
            value.flags = types.mem_flag.integer;
        },
        else => {
            value.z = @constCast(input);
            value.n = @intCast((serial_type - 12) / 2);
            value.flags = if (serial_type & 1 == 0)
                types.mem_flag.blob | types.mem_flag.ephemeral
            else
                types.mem_flag.string | types.mem_flag.ephemeral;
        },
    }
}

fn round8(value: usize) usize {
    return (value + 7) & ~@as(usize, 7);
}

pub fn allocateUnpackedRecord(key_info: *types.KeyInfo) ?*types.UnpackedRecord {
    const memory_offset = round8(@sizeOf(types.UnpackedRecord));
    const field_count: usize = @as(usize, key_info.nKeyField) + 1;
    const byte_count = memory_offset + @sizeOf(types.Mem) * field_count;
    const raw = db_allocator.mallocRaw(key_info.db, byte_count) orelse return null;
    const record: *types.UnpackedRecord = @ptrCast(@alignCast(raw));
    record.aMem = @ptrCast(@alignCast(@as([*]u8, @ptrCast(raw)) + memory_offset));
    record.pKeyInfo = key_info;
    record.nField = @intCast(field_count);
    return record;
}

pub fn unpackRecord(key_size: c_int, key: [*]const u8, record: *types.UnpackedRecord) void {
    const key_info = record.pKeyInfo.?;
    const memory = record.aMem.?;
    const header = varint.get32(key);
    var header_index: u32 = header.length;
    var data_index = header.value;
    var field_count: u16 = 0;
    const capacity = record.nField;
    record.default_rc = 0;

    while (header_index < header.value and data_index <= @as(u32, @intCast(key_size))) {
        const serial = varint.get32(key + header_index);
        header_index += serial.length;
        const value = &memory[field_count];
        value.enc = key_info.enc;
        value.db = key_info.db;
        value.szMalloc = 0;
        value.z = null;
        serialGetValue(key + data_index, serial.value, value);
        data_index += serialTypeLength(serial.value);
        field_count += 1;
        if (field_count >= capacity) break;
    }
    if (data_index > @as(u32, @intCast(key_size)) and field_count != 0) {
        vdbe_mem.setNull(&memory[field_count - 1]);
    }
    record.nField = field_count;
}
