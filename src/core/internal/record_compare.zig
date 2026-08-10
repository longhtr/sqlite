//! Allocation-free SQLite record decoding and comparison from `vdbeaux.c`.

const std = @import("std");

pub const Value = union(enum) {
    null_,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Error = error{CorruptRecord};

const Field = struct {
    serial_type: u32,
    bytes: []const u8,
};

const Cursor = struct {
    record: []const u8,
    header_end: usize,
    header_offset: usize,
    data_offset: usize,

    fn init(record: []const u8) Error!Cursor {
        const header = try readVarint(record, 0);
        if (header.value > record.len or header.value < header.length) return error.CorruptRecord;
        return .{ .record = record, .header_end = @intCast(header.value), .header_offset = header.length, .data_offset = @intCast(header.value) };
    }

    fn next(self: *Cursor) Error!?Field {
        if (self.header_offset >= self.header_end) return null;
        const serial = try readVarint(self.record[0..self.header_end], self.header_offset);
        self.header_offset += serial.length;
        const length = serialTypeLength(@intCast(serial.value));
        const end = std.math.add(usize, self.data_offset, length) catch return error.CorruptRecord;
        if (end > self.record.len) return error.CorruptRecord;
        const field = Field{ .serial_type = @intCast(serial.value), .bytes = self.record[self.data_offset..end] };
        self.data_offset = end;
        return field;
    }
};

const Varint = struct { value: u64, length: usize };

fn readVarint(bytes: []const u8, start: usize) Error!Varint {
    if (start >= bytes.len) return error.CorruptRecord;
    var value: u64 = 0;
    var index: usize = start;
    while (index < bytes.len and index - start < 8) : (index += 1) {
        value = (value << 7) | (bytes[index] & 0x7f);
        if (bytes[index] & 0x80 == 0) return .{ .value = value, .length = index - start + 1 };
    }
    if (index >= bytes.len) return error.CorruptRecord;
    value = (value << 8) | bytes[index];
    return .{ .value = value, .length = index - start + 1 };
}

fn serialTypeLength(serial_type: u32) usize {
    return switch (serial_type) {
        0, 8, 9, 10, 11 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6, 7 => 8,
        else => (serial_type - 12) / 2,
    };
}

fn signedBigEndian(bytes: []const u8) i64 {
    if (bytes.len == 0) return 0;
    var bits: u64 = 0;
    for (bytes) |byte| {
        bits = (bits << 8) | byte;
    }
    if (bytes.len < 8 and bytes[0] & 0x80 != 0) {
        const shift: u6 = @intCast(bytes.len * 8);
        const sign_extension: u64 = std.math.maxInt(u64);
        bits |= sign_extension << shift;
    }
    return @bitCast(bits);
}

/// Source `serialGet()`: decode serial types 6 and 7 without host-endian
/// assumptions and normalize NaN to SQL NULL.
pub fn serialGet(bytes: []const u8, serial_type: u32) Error!Value {
    if (bytes.len != 8 or (serial_type != 6 and serial_type != 7)) return error.CorruptRecord;
    var bits: u64 = 0;
    for (bytes) |byte| {
        bits = (bits << 8) | byte;
    }
    if (serial_type == 6) return .{ .integer = @bitCast(bits) };
    const value: f64 = @bitCast(bits);
    if (std.math.isNan(value)) return .null_;
    return .{ .real = value };
}

/// Source `serialGet7()`: decode an IEEE754 serial-7 payload and report NaN
/// through a nullable result.
pub fn serialGet7(bytes: []const u8) Error!?f64 {
    const value = try serialGet(bytes, 7);
    return switch (value) {
        .null_ => null,
        .real => |real| real,
        else => error.CorruptRecord,
    };
}

/// Source `sqlite3VdbeSerialGet()`: decode every SQLite record serial type
/// into an allocation-free borrowed value.
pub fn serialGetValue(field: Field) Error!Value {
    if (field.bytes.len != serialTypeLength(field.serial_type)) return error.CorruptRecord;
    return switch (field.serial_type) {
        0, 10, 11 => .null_,
        1, 2, 3, 4, 5, 6 => if (field.serial_type == 6) try serialGet(field.bytes, 6) else .{ .integer = signedBigEndian(field.bytes) },
        7 => try serialGet(field.bytes, 7),
        8 => .{ .integer = 0 },
        9 => .{ .integer = 1 },
        else => if (field.serial_type & 1 == 1) .{ .text = field.bytes } else .{ .blob = field.bytes },
    };
}

/// Source `vdbeRecordDecodeInt()`: decode any integer serial type without
/// constructing a temporary memory cell.
pub fn recordDecodeInteger(serial_type: u32, bytes: []const u8) Error!i64 {
    if (serial_type == 8) return 0;
    if (serial_type == 9) return 1;
    if (serial_type < 1 or serial_type > 6) return error.CorruptRecord;
    if (bytes.len != serialTypeLength(serial_type)) return error.CorruptRecord;
    return signedBigEndian(bytes);
}

/// Source `vdbeSkipField()`: advance over one serial type and payload while
/// validating both record-header and data bounds.
pub fn skipField(cursor: *Cursor) Error!bool {
    const before_header = cursor.header_offset;
    const before_data = cursor.data_offset;
    const field = try cursor.next() orelse return false;
    if (cursor.header_offset <= before_header) return error.CorruptRecord;
    if (cursor.data_offset != before_data + field.bytes.len) return error.CorruptRecord;
    return true;
}

/// Source `sqlite3BlobCompare()`: compare blobs bytewise, then by length.
pub fn blobCompare(first: []const u8, second: []const u8) i32 {
    const common = @min(first.len, second.len);
    const order = std.mem.order(u8, first[0..common], second[0..common]);
    if (order == .lt) return -1;
    if (order == .gt) return 1;
    return if (first.len < second.len) -1 else if (first.len > second.len) 1 else 0;
}

/// Source `sqlite3IntFloatCompare()`: compare an exact signed integer with a
/// double without rounding the integer before range checks.
pub fn integerFloatCompare(integer: i64, real: f64) i32 {
    if (std.math.isNan(real)) return 1;
    if (real < -9223372036854775808.0) return 1;
    if (real >= 9223372036854775808.0) return -1;
    const truncated: i64 = @intFromFloat(real);
    if (integer < truncated) return -1;
    if (integer > truncated) return 1;
    const converted: f64 = @floatFromInt(integer);
    return if (converted < real) -1 else if (converted > real) 1 else 0;
}

fn rank(value: Value) u8 {
    return switch (value) {
        .null_ => 0,
        .integer, .real => 1,
        .text => 2,
        .blob => 3,
    };
}

/// Source `sqlite3MemCompare()`: preserve SQLite's NULL, numeric, text, and
/// blob storage-class ordering for decoded record fields.
pub fn memoryCompare(first: Value, second: Value) i32 {
    const first_rank = rank(first);
    const second_rank = rank(second);
    if (first_rank != second_rank) return if (first_rank < second_rank) -1 else 1;
    return switch (first) {
        .null_ => 0,
        .integer => |left| switch (second) {
            .integer => |right| if (left < right) -1 else if (left > right) 1 else 0,
            .real => |right| integerFloatCompare(left, right),
            else => unreachable,
        },
        .real => |left| switch (second) {
            .integer => |right| -integerFloatCompare(right, left),
            .real => |right| if (left < right) -1 else if (left > right) 1 else 0,
            else => unreachable,
        },
        .text => |left| switch (second) {
            .text => |right| blobCompare(left, right),
            else => unreachable,
        },
        .blob => |left| switch (second) {
            .blob => |right| blobCompare(left, right),
            else => unreachable,
        },
    };
}

/// Source `sqlite3VdbeRecordUnpack()`: decode a record into caller-owned
/// value slots while retaining text and blob slices as borrowed payloads.
pub fn recordUnpack(allocator: std.mem.Allocator, record: []const u8) ![]Value {
    var values = std.ArrayList(Value).empty;
    errdefer values.deinit(allocator);
    var cursor = try Cursor.init(record);
    while (try cursor.next()) |field| {
        try values.append(allocator, try serialGetValue(field));
    }
    if (cursor.data_offset != record.len) return error.CorruptRecord;
    return values.toOwnedSlice(allocator);
}

/// Source `sqlite3VdbeRecordCompareWithSkip()`: stream two encoded records,
/// optionally skipping their first equal field, without allocating.
pub fn recordCompareWithSkip(first: []const u8, second: []const u8, skip_first: bool) Error!std.math.Order {
    var left = try Cursor.init(first);
    var right = try Cursor.init(second);
    if (skip_first) {
        if (!try skipField(&left) or !try skipField(&right)) return error.CorruptRecord;
    }
    while (true) {
        const left_field = try left.next();
        const right_field = try right.next();
        if (left_field == null or right_field == null) {
            if (left_field == null and right_field == null) return .eq;
            return if (left_field == null) .lt else .gt;
        }
        const compared = memoryCompare(try serialGetValue(left_field.?), try serialGetValue(right_field.?));
        if (compared < 0) return .lt;
        if (compared > 0) return .gt;
    }
}

/// Source `vdbeRecordCompareInt()`: fast-path the first integer field before
/// falling back to the streaming trailing-field comparator.
pub fn recordCompareInteger(first: []const u8, second: []const u8) Error!std.math.Order {
    var left = try Cursor.init(first);
    var right = try Cursor.init(second);
    const left_field = try left.next() orelse return error.CorruptRecord;
    const right_field = try right.next() orelse return error.CorruptRecord;
    const left_value = try serialGetValue(left_field);
    const right_value = try serialGetValue(right_field);
    if (left_value != .integer or right_value != .integer) return recordCompareWithSkip(first, second, false);
    if (left_value.integer < right_value.integer) return .lt;
    if (left_value.integer > right_value.integer) return .gt;
    return recordCompareWithSkip(first, second, true);
}

/// Source `vdbeRecordCompareString()`: fast-path BINARY text in the first
/// field before comparing any trailing fields.
pub fn recordCompareString(first: []const u8, second: []const u8) Error!std.math.Order {
    var left = try Cursor.init(first);
    var right = try Cursor.init(second);
    const left_value = try serialGetValue(try left.next() orelse return error.CorruptRecord);
    const right_value = try serialGetValue(try right.next() orelse return error.CorruptRecord);
    if (left_value != .text or right_value != .text) return recordCompareWithSkip(first, second, false);
    const compared = blobCompare(left_value.text, right_value.text);
    if (compared < 0) return .lt;
    if (compared > 0) return .gt;
    return recordCompareWithSkip(first, second, true);
}

pub const CompareStrategy = enum { generic, integer, string };

/// Source `sqlite3VdbeFindCompare()`: choose a safe first-field specialization
/// from the serial types encoded in both records.
pub fn findRecordCompare(first: []const u8, second: []const u8) Error!CompareStrategy {
    var left = try Cursor.init(first);
    var right = try Cursor.init(second);
    const left_field = try left.next() orelse return .generic;
    const right_field = try right.next() orelse return .generic;
    if (left_field.serial_type >= 1 and left_field.serial_type <= 9 and left_field.serial_type != 7 and
        right_field.serial_type >= 1 and right_field.serial_type <= 9 and right_field.serial_type != 7) return .integer;
    if (left_field.serial_type >= 13 and left_field.serial_type & 1 == 1 and
        right_field.serial_type >= 13 and right_field.serial_type & 1 == 1) return .string;
    return .generic;
}

pub fn compareRecords(first: []const u8, second: []const u8) Error!std.math.Order {
    return switch (try findRecordCompare(first, second)) {
        .integer => recordCompareInteger(first, second),
        .string => recordCompareString(first, second),
        .generic => recordCompareWithSkip(first, second, false),
    };
}

/// Source `sqlite3VdbeIdxRowid()`: validate an index record and decode its
/// final field as the integer table rowid without allocating a full record.
pub const KeyAccessor = *const fn (?*const anyopaque, usize) Value;

/// Source `sqlite3VdbeIdxKeyCompare()`: compare an encoded index key against
/// caller-provided unpacked fields without materializing the record.
pub fn indexKeyCompare(record: []const u8, key_count: usize, context: ?*const anyopaque, accessor: KeyAccessor) Error!std.math.Order {
    var cursor = try Cursor.init(record);
    var index: usize = 0;
    while (index < key_count) : (index += 1) {
        const field = try cursor.next() orelse return .lt;
        const compared = memoryCompare(try serialGetValue(field), accessor(context, index));
        if (compared < 0) return .lt;
        if (compared > 0) return .gt;
    }
    return .eq;
}

/// Source `vdbeIsMatchingIndexKey()`: report exact equality after a bounded
/// encoded-versus-unpacked index-key comparison.
pub fn isMatchingIndexKey(record: []const u8, key_count: usize, context: ?*const anyopaque, accessor: KeyAccessor) Error!bool {
    if (key_count == 0) return false;
    const order = try indexKeyCompare(record, key_count, context, accessor);
    return order == .eq;
}

pub const RecordAccessor = *const fn (?*const anyopaque, usize) []const u8;
pub const SearchResult = struct { position: usize, found: bool };

/// Source `sqlite3VdbeFindIndexKey()`: binary-search encoded index records
/// against an unpacked key and report the lower-bound position.
pub fn findIndexKey(record_count: usize, records_context: ?*const anyopaque, record_accessor: RecordAccessor, key_count: usize, key_context: ?*const anyopaque, key_accessor: KeyAccessor) Error!SearchResult {
    if (key_count == 0) return .{ .position = 0, .found = false };
    var lower: usize = 0;
    var upper = record_count;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const order = try indexKeyCompare(record_accessor(records_context, middle), key_count, key_context, key_accessor);
        if (order == .lt) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    if (lower == record_count) return .{ .position = lower, .found = false };
    const found = try isMatchingIndexKey(record_accessor(records_context, lower), key_count, key_context, key_accessor);
    return .{ .position = lower, .found = found };
}

/// Source `sqlite3VdbeIdxRowid()`: validate an index record and decode its
/// final field as the integer table rowid without allocating a full record.
pub fn indexRowid(record: []const u8) Error!i64 {
    var cursor = try Cursor.init(record);
    var last: ?Field = null;
    while (try cursor.next()) |field| {
        last = field;
    }
    if (cursor.data_offset != record.len) return error.CorruptRecord;
    const field = last orelse return error.CorruptRecord;
    if (field.serial_type < 1 or field.serial_type > 9 or field.serial_type == 7) return error.CorruptRecord;
    return recordDecodeInteger(field.serial_type, field.bytes);
}
