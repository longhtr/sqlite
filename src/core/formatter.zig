//! Source-corresponding SQLite formatter metadata, accumulation, ownership,
//! and Zig-native typed rendering. Exact internal error-offset integration remains.

const std = @import("std");
const utf = @import("utf.zig");
const sqlite_float = @import("float.zig");
pub const memory = @import("memory.zig");

pub const FormatByte = u8;

pub const et_radix: u8 = 0;
pub const et_float: u8 = 1;
pub const et_exp: u8 = 2;
pub const et_generic: u8 = 3;
pub const et_size: u8 = 4;
pub const et_string: u8 = 5;
pub const et_dynstring: u8 = 6;
pub const et_percent: u8 = 7;
pub const et_charx: u8 = 8;
pub const et_escape_q: u8 = 9;
pub const et_escape_Q: u8 = 10;
pub const et_token: u8 = 11;
pub const et_srcitem: u8 = 12;
pub const et_pointer: u8 = 13;
pub const et_escape_w: u8 = 14;
pub const et_ordinal: u8 = 15;
pub const et_decimal: u8 = 16;
pub const et_invalid: u8 = 17;

pub const flag_signed: u8 = 1;
pub const flag_string: u8 = 4;
pub const print_buffer_size: usize = 70;
pub const buffer_size: usize = print_buffer_size;
pub const floating_precision_limit: usize = 100_000_000;
pub const max_log_message: usize = print_buffer_size * 10;

pub const digits = "0123456789ABCDEF0123456789abcdef";
pub const prefixes = "-x0\x00X0";

pub const FormatInfo = struct {
    fmttype: u8,
    base: u8,
    flags: u8,
    conversion_type: u8,
    charset: u8,
    prefix: u8,
    iNxt: u8,
};

pub const format_info = [23]FormatInfo{
    .{ .fmttype = 's', .base = 0, .flags = 4, .conversion_type = et_string, .charset = 0, .prefix = 0, .iNxt = 1 },
    .{ .fmttype = 'E', .base = 0, .flags = 1, .conversion_type = et_exp, .charset = 14, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'u', .base = 10, .flags = 0, .conversion_type = et_decimal, .charset = 0, .prefix = 0, .iNxt = 3 },
    .{ .fmttype = 'G', .base = 0, .flags = 1, .conversion_type = et_generic, .charset = 14, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'w', .base = 0, .flags = 4, .conversion_type = et_escape_w, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'x', .base = 16, .flags = 0, .conversion_type = et_radix, .charset = 16, .prefix = 1, .iNxt = 0 },
    .{ .fmttype = 'c', .base = 0, .flags = 0, .conversion_type = et_charx, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'z', .base = 0, .flags = 4, .conversion_type = et_dynstring, .charset = 0, .prefix = 0, .iNxt = 6 },
    .{ .fmttype = 'd', .base = 10, .flags = 1, .conversion_type = et_decimal, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'e', .base = 0, .flags = 1, .conversion_type = et_exp, .charset = 30, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'f', .base = 0, .flags = 1, .conversion_type = et_float, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'g', .base = 0, .flags = 1, .conversion_type = et_generic, .charset = 30, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'Q', .base = 0, .flags = 4, .conversion_type = et_escape_Q, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'i', .base = 10, .flags = 1, .conversion_type = et_decimal, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = '%', .base = 0, .flags = 0, .conversion_type = et_percent, .charset = 0, .prefix = 0, .iNxt = 16 },
    .{ .fmttype = 'T', .base = 0, .flags = 0, .conversion_type = et_token, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'S', .base = 0, .flags = 0, .conversion_type = et_srcitem, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'X', .base = 16, .flags = 0, .conversion_type = et_radix, .charset = 0, .prefix = 4, .iNxt = 0 },
    .{ .fmttype = 'n', .base = 0, .flags = 0, .conversion_type = et_size, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'o', .base = 8, .flags = 0, .conversion_type = et_radix, .charset = 0, .prefix = 2, .iNxt = 17 },
    .{ .fmttype = 'p', .base = 16, .flags = 0, .conversion_type = et_pointer, .charset = 0, .prefix = 1, .iNxt = 0 },
    .{ .fmttype = 'q', .base = 0, .flags = 4, .conversion_type = et_escape_q, .charset = 0, .prefix = 0, .iNxt = 0 },
    .{ .fmttype = 'r', .base = 10, .flags = 1, .conversion_type = et_ordinal, .charset = 0, .prefix = 0, .iNxt = 0 },
};

pub const printf_internal: u8 = 0x01;
pub const printf_sql_function: u8 = 0x02;
pub const printf_malloced: u8 = 0x04;

pub const no_memory: u8 = 7;
pub const too_big: u8 = 18;

var oom_accumulator = Accumulator{
    .db = null,
    .zText = null,
    .nAlloc = 0,
    .mxAlloc = 0,
    .nChar = 0,
    .accError = no_memory,
    .printfFlags = 0,
};

/// Source representation: sqliteInt.h `struct sqlite3_str` / `StrAccum`.
pub const Accumulator = extern struct {
    db: ?*anyopaque,
    zText: ?[*]u8,
    nAlloc: u32,
    mxAlloc: u32,
    nChar: u32,
    accError: u8,
    printfFlags: u8,
};

/// Source representation: sqliteInt.h `struct RCStr`.
pub const ReferenceCountedStringHeader = extern struct {
    nRCRef: u64,
};

pub const Lookup = struct {
    info_index: u8,
    conversion_type: u8,
};

/// Preserve the two-probe ASCII hash lookup from sqlite3_str_vappendf().
pub fn lookup(character: u8) Lookup {
    var index: u8 = @intCast(@as(usize, character) % format_info.len);
    if (format_info[index].fmttype == character) {
        return .{ .info_index = index, .conversion_type = format_info[index].conversion_type };
    }
    index = format_info[index].iNxt;
    if (format_info[index].fmttype == character) {
        return .{ .info_index = index, .conversion_type = format_info[index].conversion_type };
    }
    return .{ .info_index = 0, .conversion_type = et_invalid };
}

pub fn isMalloced(accumulator: *const Accumulator) bool {
    return accumulator.printfFlags & printf_malloced != 0;
}

/// Upstream: sqlite3StrAccumInit(). The optional database identity is retained
/// for later connection allocator integration; allocation is explicit here.
pub fn strAccumInit(
    accumulator: *Accumulator,
    database: ?*anyopaque,
    base: ?[*]u8,
    base_size: u32,
    maximum: u32,
) void {
    accumulator.* = .{
        .db = database,
        .zText = base,
        .nAlloc = base_size,
        .mxAlloc = maximum,
        .nChar = 0,
        .accError = 0,
        .printfFlags = 0,
    };
}

/// Upstream: sqlite3_str_reset(). Error state deliberately survives reset.
pub fn strReset(accumulator: *Accumulator, manager: *memory.Manager) void {
    if (isMalloced(accumulator)) {
        manager.free(if (accumulator.zText) |text| @ptrCast(text) else null);
        accumulator.printfFlags &= ~printf_malloced;
    }
    accumulator.nAlloc = 0;
    accumulator.nChar = 0;
    accumulator.zText = null;
}

/// Upstream: sqlite3StrAccumSetError().
pub fn strAccumSetError(accumulator: *Accumulator, manager: *memory.Manager, error_code: u8) void {
    std.debug.assert(error_code == no_memory or error_code == too_big);
    accumulator.accError = error_code;
    if (accumulator.mxAlloc != 0) strReset(accumulator, manager);
}

/// Upstream: sqlite3StrAccumEnlarge().
pub fn strAccumEnlarge(accumulator: *Accumulator, manager: *memory.Manager, amount: i64) c_int {
    std.debug.assert(amount >= 0 and amount <= std.math.maxInt(c_int));
    std.debug.assert(@as(i64, accumulator.nChar) + amount >= accumulator.nAlloc);
    if (accumulator.accError != 0) return 0;
    if (accumulator.mxAlloc == 0) {
        strAccumSetError(accumulator, manager, too_big);
        const remaining = accumulator.nAlloc -% accumulator.nChar -% 1;
        return @bitCast(remaining);
    }

    const was_malloced = isMalloced(accumulator);
    const old_text = accumulator.zText;
    const old_allocation: ?*anyopaque = if (was_malloced)
        (if (old_text) |text| @ptrCast(text) else null)
    else
        null;
    var new_size = @as(i64, accumulator.nChar) + amount + 1;
    if (new_size + accumulator.nChar <= accumulator.mxAlloc) new_size += accumulator.nChar;
    if (new_size > accumulator.mxAlloc) {
        strReset(accumulator, manager);
        strAccumSetError(accumulator, manager, too_big);
        return 0;
    }

    accumulator.nAlloc = @intCast(new_size);
    const allocation = manager.realloc(old_allocation, @intCast(new_size));
    if (allocation) |new_pointer| {
        const new_text: [*]u8 = @ptrCast(new_pointer);
        if (!was_malloced and accumulator.nChar > 0) {
            std.mem.copyForwards(u8, new_text[0..accumulator.nChar], old_text.?[0..accumulator.nChar]);
        }
        accumulator.zText = new_text;
        accumulator.nAlloc = @intCast(manager.size(new_pointer));
        accumulator.printfFlags |= printf_malloced;
    } else {
        strReset(accumulator, manager);
        strAccumSetError(accumulator, manager, no_memory);
        return 0;
    }
    return @intCast(amount);
}

/// Upstream: sqlite3StrAccumEnlargeIfNeeded().
pub fn strAccumEnlargeIfNeeded(accumulator: *Accumulator, manager: *memory.Manager, amount: i64) u8 {
    if (amount + accumulator.nChar >= accumulator.nAlloc) {
        _ = strAccumEnlarge(accumulator, manager, amount);
    }
    return accumulator.accError;
}

/// Upstream: sqlite3_str_appendchar().
pub fn strAppendChar(accumulator: *Accumulator, manager: *memory.Manager, count: c_int, character: u8) void {
    if (count <= 0) return;
    var accepted = count;
    if (@as(i64, accumulator.nChar) + count >= accumulator.nAlloc) {
        accepted = strAccumEnlarge(accumulator, manager, count);
        if (accepted <= 0) return;
    }
    const start = accumulator.nChar;
    accumulator.nChar += @intCast(accepted);
    @memset(accumulator.zText.?[start..accumulator.nChar], character);
}

/// Upstream: sqlite3_str_append() and enlargeAndAppend().
pub fn strAppend(accumulator: *Accumulator, manager: *memory.Manager, text: []const u8) void {
    std.debug.assert(accumulator.zText != null or accumulator.nChar == 0 or accumulator.accError != 0);
    if (@as(u64, accumulator.nChar) + text.len >= accumulator.nAlloc) {
        const accepted = strAccumEnlarge(accumulator, manager, @intCast(text.len));
        if (accepted <= 0) return;
        const count: usize = @intCast(accepted);
        std.mem.copyForwards(u8, accumulator.zText.?[accumulator.nChar..][0..count], text[0..count]);
        accumulator.nChar += @intCast(count);
    } else if (text.len != 0) {
        std.mem.copyForwards(u8, accumulator.zText.?[accumulator.nChar..][0..text.len], text);
        accumulator.nChar += @intCast(text.len);
    }
}

pub fn strAppendAll(accumulator: *Accumulator, manager: *memory.Manager, text: [:0]const u8) void {
    strAppend(accumulator, manager, text);
}

/// Upstream: sqlite3_str_truncate().
pub fn strTruncate(accumulator: *Accumulator, length: c_int) void {
    if (length >= 0 and @as(u32, @intCast(length)) < accumulator.nChar) {
        accumulator.nChar = @intCast(length);
        accumulator.zText.?[accumulator.nChar] = 0;
    }
}

pub fn strErrorCode(accumulator: ?*const Accumulator) c_int {
    return if (accumulator) |value| value.accError else no_memory;
}

pub fn strLength(accumulator: ?*const Accumulator) c_int {
    return if (accumulator) |value| @intCast(value.nChar) else 0;
}

/// Upstream: sqlite3_str_value().
pub fn strValue(accumulator: ?*Accumulator) ?[*:0]u8 {
    const value = accumulator orelse return null;
    if (value.nChar == 0) return null;
    value.zText.?[value.nChar] = 0;
    return @ptrCast(value.zText.?);
}

/// Upstream: sqlite3StrAccumFinish() and strAccumFinishRealloc().
pub fn strAccumFinish(accumulator: *Accumulator, manager: *memory.Manager) ?[*:0]u8 {
    const current = accumulator.zText orelse return null;
    current[accumulator.nChar] = 0;
    if (accumulator.mxAlloc > 0 and !isMalloced(accumulator)) {
        const allocation = manager.alloc(@as(u64, accumulator.nChar) + 1);
        if (allocation) |new_pointer| {
            const new_text: [*]u8 = @ptrCast(new_pointer);
            std.mem.copyForwards(u8, new_text[0 .. accumulator.nChar + 1], current[0 .. accumulator.nChar + 1]);
            accumulator.zText = new_text;
            accumulator.printfFlags |= printf_malloced;
        } else {
            strAccumSetError(accumulator, manager, no_memory);
            return null;
        }
    }
    return @ptrCast(accumulator.zText.?);
}

/// Zig-native sqlite3_str_new() responsibility with an explicit connection
/// length limit. OOM returns the source-compatible sticky singleton.
pub fn stringObjectNew(manager: *memory.Manager, database: ?*anyopaque, maximum: u32) *Accumulator {
    const allocation = manager.alloc(@sizeOf(Accumulator)) orelse return &oom_accumulator;
    const accumulator: *Accumulator = @ptrCast(@alignCast(allocation));
    strAccumInit(accumulator, database, null, 0, maximum);
    return accumulator;
}

pub fn stringObjectFinish(manager: *memory.Manager, accumulator: ?*Accumulator) ?[*:0]u8 {
    const value = accumulator orelse return null;
    if (value == &oom_accumulator) return null;
    const output = strAccumFinish(value, manager);
    manager.free(value);
    return output;
}

pub fn stringObjectFree(manager: *memory.Manager, accumulator: ?*Accumulator) void {
    const value = accumulator orelse return;
    if (value == &oom_accumulator) return;
    strReset(value, manager);
    manager.free(value);
}

pub fn stringObjectIsOom(accumulator: *const Accumulator) bool {
    return accumulator == &oom_accumulator;
}

/// Upstream: printfTempBuf().
pub fn printfTempBuffer(accumulator: *Accumulator, manager: *memory.Manager, size: i64) ?[*]u8 {
    if (accumulator.accError != 0) return null;
    if (size < 0 or (size > accumulator.nAlloc and size > accumulator.mxAlloc)) {
        strAccumSetError(accumulator, manager, too_big);
        return null;
    }
    const allocation = manager.alloc(@intCast(size)) orelse {
        strAccumSetError(accumulator, manager, no_memory);
        return null;
    };
    return @ptrCast(allocation);
}

/// Source representation: sqliteInt.h `struct Token`.
pub const Token = extern struct {
    z: ?[*]const u8,
    n: c_uint,
};

pub const SourceItemFormat = struct {
    alias: ?[]const u8 = null,
    name: ?[]const u8 = null,
    database: ?[]const u8 = null,
    fixed_schema: bool = false,
    is_subquery: bool = false,
    nested_from: bool = false,
    multi_value: bool = false,
    select_id: u32 = 0,
    row_count: u32 = 0,
};

pub const FormatArgument = union(enum) {
    signed: i64,
    unsigned: u64,
    float: f64,
    string: ?[]const u8,
    owned_string: ?[*:0]u8,
    borrowed_dynamic_string: ?[]const u8,
    character: u32,
    character_text: ?[]const u8,
    pointer: usize,
    count: *c_int,
    ignored_count,
    token: ?*const Token,
    expression_token: ?[]const u8,
    source_item: ?SourceItemFormat,
};

const ArgumentCursor = struct {
    values: []const FormatArgument,
    used: usize = 0,

    fn next(self: *ArgumentCursor) ?FormatArgument {
        if (self.used >= self.values.len) return null;
        defer self.used += 1;
        return self.values[self.used];
    }
    fn signed(self: *ArgumentCursor) i64 {
        return switch (self.next() orelse return 0) {
            .signed => |value| value,
            .unsigned => |value| @bitCast(value),
            else => 0,
        };
    }
    fn unsigned(self: *ArgumentCursor) u64 {
        return switch (self.next() orelse return 0) {
            .unsigned => |value| value,
            .signed => |value| @bitCast(value),
            .pointer => |value| value,
            else => 0,
        };
    }
    fn string(self: *ArgumentCursor) ?[]const u8 {
        return switch (self.next() orelse return null) {
            .string => |value| value,
            else => null,
        };
    }
    fn ownedString(self: *ArgumentCursor) ?[*:0]u8 {
        return switch (self.next() orelse return null) {
            .owned_string => |value| value,
            else => null,
        };
    }
    fn double(self: *ArgumentCursor) f64 {
        return switch (self.next() orelse return 0.0) {
            .float => |value| value,
            else => 0.0,
        };
    }
};

const FormatFlags = struct {
    left: bool = false,
    prefix: u8 = 0,
    alternate: bool = false,
    alternate_two: bool = false,
    zero: bool = false,
    thousand: bool = false,
};

fn appendField(
    accumulator: *Accumulator,
    manager: *memory.Manager,
    bytes: []const u8,
    width: c_int,
    left: bool,
    character_width: bool,
) void {
    var display_length: usize = bytes.len;
    if (character_width) for (bytes) |byte| {
        if (byte & 0xc0 == 0x80) display_length -= 1;
    };
    const padding: c_int = @max(0, width - @as(c_int, @intCast(display_length)));
    if (!left) strAppendChar(accumulator, manager, padding, ' ');
    strAppend(accumulator, manager, bytes);
    if (left) strAppendChar(accumulator, manager, padding, ' ');
}

fn nulTerminatedPrefix(input: []const u8) []const u8 {
    return input[0..(std.mem.indexOfScalar(u8, input, 0) orelse input.len)];
}

fn utf8Prefix(input: []const u8, characters: usize) []const u8 {
    var position: usize = 0;
    var remaining = characters;
    while (remaining > 0 and position < input.len and input[position] != 0) : (remaining -= 1) {
        position += 1;
        while (position < input.len and input[position] & 0xc0 == 0x80) position += 1;
    }
    return input[0..position];
}

fn renderInteger(
    accumulator: *Accumulator,
    manager: *memory.Manager,
    info: FormatInfo,
    conversion_type: u8,
    cursor: *ArgumentCursor,
    flags: FormatFlags,
    width: c_int,
    precision_argument: c_int,
) void {
    var prefix = flags.prefix;
    var value: u64 = undefined;
    if (info.flags & flag_signed != 0) {
        const signed_value = cursor.signed();
        if (signed_value < 0) {
            value = ~@as(u64, @bitCast(signed_value)) +% 1;
            prefix = '-';
        } else {
            value = @intCast(signed_value);
        }
    } else {
        value = cursor.unsigned();
        prefix = 0;
    }
    const alternate = flags.alternate and value != 0;
    var precision = precision_argument;
    if (flags.zero and precision < width - @intFromBool(prefix != 0)) {
        precision = width - @intFromBool(prefix != 0);
    }
    const requested: i64 = @as(i64, @max(precision, 0)) + 10 + if (flags.thousand) @divTrunc(@as(i64, @max(precision, 0)), 3) else 0;
    var local: [buffer_size]u8 = undefined;
    var allocated: ?[*]u8 = null;
    const output: []u8 = if (requested <= local.len)
        local[0..]
    else blk: {
        allocated = printfTempBuffer(accumulator, manager, requested) orelse return;
        break :blk allocated.?[0..@intCast(requested)];
    };
    defer if (allocated) |temporary| manager.free(temporary);
    var at = output.len;
    if (conversion_type == et_ordinal) {
        const ordinal = "thstndrd";
        var suffix: usize = @intCast(value % 10);
        if (suffix >= 4 or (value / 10) % 10 == 1) suffix = 0;
        at -= 1;
        output[at] = ordinal[suffix * 2 + 1];
        at -= 1;
        output[at] = ordinal[suffix * 2];
    }
    const charset = digits[info.charset..];
    while (true) {
        at -= 1;
        output[at] = charset[@intCast(value % info.base)];
        value /= info.base;
        if (value == 0) break;
    }
    var length = output.len - at;
    if (precision > length) {
        const zeros: usize = @intCast(precision - @as(c_int, @intCast(length)));
        at -= zeros;
        @memset(output[at..][0..zeros], '0');
        length += zeros;
    }
    if (flags.thousand) {
        const commas = (length - 1) / 3;
        if (commas > 0) {
            const old_at = at;
            at -= commas;
            var source: usize = 0;
            var target: usize = 0;
            const first = (length - 1) % 3 + 1;
            while (source < length) : (source += 1) {
                output[at + target] = output[old_at + source];
                target += 1;
                if (source + 1 < length and source + 1 >= first and (source + 1 - first) % 3 == 0) {
                    output[at + target] = ',';
                    target += 1;
                }
            }
            length += commas;
        }
    }
    if (prefix != 0) {
        at -= 1;
        output[at] = prefix;
        length += 1;
    }
    if (alternate and info.prefix != 0) {
        const prefix_text = std.mem.sliceTo(prefixes[info.prefix..], 0);
        for (prefix_text) |byte| {
            at -= 1;
            output[at] = byte;
            length += 1;
        }
    }
    appendField(accumulator, manager, output[at..][0..length], width, flags.left, false);
}

fn renderFloat(
    accumulator: *Accumulator,
    manager: *memory.Manager,
    info: FormatInfo,
    conversion_argument: u8,
    cursor: *ArgumentCursor,
    flags: FormatFlags,
    width: c_int,
    precision_argument: c_int,
) void {
    const real = cursor.double();
    var precision = if (precision_argument < 0) @as(c_int, 6) else @min(precision_argument, @as(c_int, @intCast(floating_precision_limit)));
    const decode_round: c_int = if (conversion_argument == et_float)
        -precision
    else if (conversion_argument == et_generic)
        (if (precision == 0) 1 else precision)
    else
        precision + 1;
    var decoded: sqlite_float.Decode = undefined;
    sqlite_float.decode(&decoded, real, decode_round, if (flags.alternate_two) 20 else 16);
    if (decoded.isSpecial != 0) {
        if (decoded.isSpecial == 2) {
            appendField(accumulator, manager, if (flags.zero) "null" else "NaN", width, flags.left, false);
            return;
        }
        if (!flags.zero) {
            var special: [4]u8 = undefined;
            var length: usize = 0;
            if (decoded.sign == '-') {
                special[length] = '-';
                length += 1;
            } else if (flags.prefix != 0) {
                special[length] = flags.prefix;
                length += 1;
            }
            @memcpy(special[length..][0..3], "Inf");
            length += 3;
            appendField(accumulator, manager, special[0..length], width, flags.left, false);
            return;
        }
        decoded.zBuf[0] = '9';
        decoded.z = &decoded.zBuf;
        decoded.iDP = 1000;
        decoded.n = 1;
    }
    var prefix: u8 = 0;
    if (decoded.sign == '-') {
        if (!(flags.alternate and flags.prefix == 0 and conversion_argument == et_float and decoded.iDP <= decode_round)) prefix = '-';
    } else prefix = flags.prefix;
    const decimal_exponent = decoded.iDP - 1;
    var conversion = conversion_argument;
    var remove_trailing = false;
    if (conversion == et_generic) {
        std.debug.assert(precision > 0);
        precision -= 1;
        remove_trailing = !flags.alternate;
        if (decimal_exponent < -4 or decimal_exponent > precision) {
            conversion = et_exp;
        } else {
            precision -= decimal_exponent;
            conversion = et_float;
        }
    } else {
        remove_trailing = flags.alternate_two;
    }
    var remaining_exponent: c_int = if (conversion == et_exp) 0 else decoded.iDP - 1;
    var needed: i64 = @max(remaining_exponent, 0) + @as(i64, precision) + width + 10;
    if (flags.thousand and remaining_exponent > 0) needed += @divTrunc(@as(i64, remaining_exponent) + 2, 3);
    var temporary: ?[*]u8 = null;
    var direct = false;
    var output: [*]u8 = undefined;
    if (needed + accumulator.nChar >= accumulator.nAlloc) {
        if (accumulator.mxAlloc == 0 and accumulator.accError == 0) {
            temporary = if (manager.alloc(@intCast(needed))) |allocation| @ptrCast(allocation) else {
                strAccumSetError(accumulator, manager, no_memory);
                return;
            };
            output = temporary.?;
        } else {
            if (strAccumEnlarge(accumulator, manager, needed) < needed) return;
            output = accumulator.zText.? + accumulator.nChar;
            direct = true;
        }
    } else {
        output = accumulator.zText.? + accumulator.nChar;
        direct = true;
    }
    defer if (temporary) |allocation| manager.free(allocation);
    var at: usize = 0;
    if (prefix != 0) {
        output[at] = prefix;
        at += 1;
    }
    var digit_index: c_int = 0;
    const decoded_digits = decoded.z.?;
    if (remaining_exponent < 0) {
        output[at] = '0';
        at += 1;
    } else if (flags.thousand) {
        while (remaining_exponent >= 0) : (remaining_exponent -= 1) {
            output[at] = if (digit_index < decoded.n) decoded_digits[@intCast(digit_index)] else '0';
            at += 1;
            digit_index += 1;
            if (@rem(remaining_exponent, 3) == 0 and remaining_exponent > 1) {
                output[at] = ',';
                at += 1;
            }
        }
    } else {
        digit_index = remaining_exponent + 1;
        if (digit_index > decoded.n) digit_index = decoded.n;
        const copy_count: usize = @intCast(digit_index);
        std.mem.copyForwards(u8, output[at..][0..copy_count], decoded_digits[0..copy_count]);
        at += copy_count;
        remaining_exponent -= digit_index;
        if (remaining_exponent >= 0) {
            const zeros: usize = @intCast(remaining_exponent + 1);
            @memset(output[at..][0..zeros], '0');
            at += zeros;
            remaining_exponent = -1;
        }
    }
    const decimal_point = precision > 0 or flags.alternate or flags.alternate_two;
    if (decimal_point) {
        output[at] = '.';
        at += 1;
    }
    if (remaining_exponent < -1 and precision > 0) {
        const zeros: c_int = @min(-1 - remaining_exponent, precision);
        @memset(output[at..][0..@intCast(zeros)], '0');
        at += @intCast(zeros);
        precision -= zeros;
    }
    if (precision > 0) {
        const available = decoded.n - digit_index;
        const count: c_int = @min(available, precision);
        if (count > 0) {
            std.mem.copyForwards(u8, output[at..][0..@intCast(count)], decoded_digits[@intCast(digit_index)..][0..@intCast(count)]);
            at += @intCast(count);
            precision -= count;
        }
        if (precision > 0 and !remove_trailing) {
            @memset(output[at..][0..@intCast(precision)], '0');
            at += @intCast(precision);
        }
    }
    if (remove_trailing and decimal_point) {
        while (output[at - 1] == '0') at -= 1;
        if (output[at - 1] == '.') {
            if (flags.alternate_two) {
                output[at] = '0';
                at += 1;
            } else at -= 1;
        }
    }
    if (conversion == et_exp) {
        var exponent = decimal_exponent;
        output[at] = digits[info.charset];
        at += 1;
        if (exponent < 0) {
            output[at] = '-';
            at += 1;
            exponent = -exponent;
        } else {
            output[at] = '+';
            at += 1;
        }
        if (exponent >= 100) {
            output[at] = @intCast(@divTrunc(exponent, 100) + '0');
            at += 1;
            exponent = @rem(exponent, 100);
        }
        output[at] = @intCast(@divTrunc(exponent, 10) + '0');
        output[at + 1] = @intCast(@rem(exponent, 10) + '0');
        at += 2;
    }
    var length: usize = at;
    if (length < width) {
        const padding: usize = @intCast(width - @as(c_int, @intCast(length)));
        if (flags.left) {
            @memset(output[length..][0..padding], ' ');
        } else if (!flags.zero) {
            std.mem.copyBackwards(u8, output[padding..][0..length], output[0..length]);
            @memset(output[0..padding], ' ');
        } else {
            const adjustment: usize = @intFromBool(prefix != 0);
            std.mem.copyBackwards(u8, output[padding + adjustment ..][0 .. length - adjustment], output[adjustment..length]);
            @memset(output[adjustment..][0..padding], '0');
        }
        length = @intCast(width);
    }
    if (direct) {
        accumulator.nChar += @intCast(length);
        output[length] = 0;
    } else {
        strAppend(accumulator, manager, output[0..length]);
    }
}

fn renderEscape(
    accumulator: *Accumulator,
    manager: *memory.Manager,
    conversion_type: u8,
    input_optional: ?[]const u8,
    flags: FormatFlags,
    width: c_int,
    precision: c_int,
) void {
    var input = if (input_optional) |value| nulTerminatedPrefix(value) else if (conversion_type == et_escape_Q) "NULL" else "(NULL)";
    if (precision >= 0) input = if (flags.alternate_two) utf8Prefix(input, @intCast(precision)) else input[0..@min(input.len, @as(usize, @intCast(precision)))];
    const quote: u8 = if (conversion_type == et_escape_w) '"' else '\'';
    var alternate = flags.alternate and conversion_type != et_escape_w;
    var controls: usize = 0;
    var backslashes: usize = 0;
    var doubled: usize = 0;
    for (input) |byte| {
        if (byte == quote) doubled += 1;
        if (byte == '\\') backslashes += 1 else if (byte <= 0x1f) controls += 1;
    }
    if (alternate and controls == 0 and conversion_type == et_escape_Q) alternate = false;
    const need_quote: u2 = if (input_optional == null) 0 else if (conversion_type == et_escape_Q) (if (alternate) 2 else 1) else 0;
    const alternate_extra: usize = if (alternate) backslashes + 5 * controls else 0;
    const quote_extra: usize = if (need_quote == 1) 2 else if (need_quote == 2) 10 else 0;
    const length = input.len + doubled + alternate_extra + quote_extra;
    var local: [buffer_size]u8 = undefined;
    var allocated: ?[*]u8 = null;
    const output: []u8 = if (length + 1 <= local.len)
        local[0 .. length + 1]
    else blk: {
        allocated = printfTempBuffer(accumulator, manager, @intCast(length + 1)) orelse return;
        break :blk allocated.?[0 .. length + 1];
    };
    defer if (allocated) |temporary| manager.free(temporary);
    var at: usize = 0;
    if (need_quote == 2) {
        @memcpy(output[0..8], "unistr('");
        at = 8;
    } else if (need_quote == 1) {
        output[at] = '\'';
        at += 1;
    }
    for (input) |byte| {
        output[at] = byte;
        at += 1;
        if (byte == quote) {
            output[at] = byte;
            at += 1;
        } else if (alternate and byte == '\\') {
            output[at] = '\\';
            at += 1;
        } else if (alternate and byte <= 0x1f) {
            at -= 1;
            output[at..][0..6].* = .{ '\\', 'u', '0', '0', if (byte >= 0x10) '1' else '0', digits[16 + (byte & 0xf)] };
            at += 6;
        }
    }
    if (need_quote != 0) {
        output[at] = '\'';
        at += 1;
        if (need_quote == 2) {
            output[at] = ')';
            at += 1;
        }
    }
    std.debug.assert(at == length);
    appendField(accumulator, manager, output[0..length], width, flags.left, flags.alternate_two);
}

/// Zig-native typed sqlite3_str_vappendf(). The Mem-backed SQL argument
/// adapter and internal error-offset side effects remain pending.
pub fn strAppendFormat(accumulator: *Accumulator, manager: *memory.Manager, format: []const u8, arguments: []const FormatArgument) void {
    var cursor = ArgumentCursor{ .values = arguments };
    var position: usize = 0;
    while (position < format.len) {
        const percent = std.mem.indexOfScalarPos(u8, format, position, '%') orelse {
            strAppend(accumulator, manager, format[position..]);
            return;
        };
        if (percent > position) strAppend(accumulator, manager, format[position..percent]);
        position = percent + 1;
        if (position == format.len) {
            strAppend(accumulator, manager, "%");
            return;
        }
        var flags = FormatFlags{};
        while (position < format.len) : (position += 1) switch (format[position]) {
            '-' => flags.left = true,
            '+' => flags.prefix = '+',
            ' ' => if (flags.prefix == 0) {
                flags.prefix = ' ';
            },
            '#' => flags.alternate = true,
            '!' => flags.alternate_two = true,
            '0' => flags.zero = true,
            ',' => flags.thousand = true,
            else => break,
        };
        var width: c_int = 0;
        if (position < format.len and format[position] == '*') {
            const raw: c_int = @truncate(cursor.signed());
            if (raw < 0) {
                flags.left = true;
                width = if (raw >= -2_147_483_647) -raw else 0;
            } else width = @min(raw, @as(c_int, @intCast(floating_precision_limit)));
            position += 1;
        } else while (position < format.len and std.ascii.isDigit(format[position])) : (position += 1) {
            width = @min(@as(c_int, @intCast(floating_precision_limit)), width *| 10 +| (format[position] - '0'));
        }
        var precision: c_int = -1;
        if (position < format.len and format[position] == '.') {
            position += 1;
            if (position < format.len and format[position] == '*') {
                precision = @truncate(cursor.signed());
                if (precision < 0) precision = if (precision >= -2_147_483_647) -precision else -1;
                position += 1;
            } else {
                precision = 0;
                while (position < format.len and std.ascii.isDigit(format[position])) : (position += 1) {
                    precision = @min(@as(c_int, @intCast(floating_precision_limit)), precision *| 10 +| (format[position] - '0'));
                }
            }
        }
        if (position < format.len and format[position] == 'l') {
            position += 1;
            if (position < format.len and format[position] == 'l') position += 1;
        }
        if (position >= format.len) return;
        const conversion = format[position];
        position += 1;
        const found = lookup(conversion);
        const info = format_info[found.info_index];
        switch (found.conversion_type) {
            et_decimal, et_radix, et_ordinal, et_pointer => renderInteger(accumulator, manager, info, found.conversion_type, &cursor, flags, width, precision),
            et_float, et_exp, et_generic => renderFloat(accumulator, manager, info, found.conversion_type, &cursor, flags, width, precision),
            et_string => {
                var text = nulTerminatedPrefix(cursor.string() orelse "");
                if (precision >= 0) text = if (flags.alternate_two) utf8Prefix(text, @intCast(precision)) else text[0..@min(text.len, @as(usize, @intCast(precision)))];
                appendField(accumulator, manager, text, width, flags.left, flags.alternate_two);
            },
            et_dynstring => {
                if (cursor.used < cursor.values.len and cursor.values[cursor.used] == .borrowed_dynamic_string) {
                    const borrowed = switch (cursor.next().?) {
                        .borrowed_dynamic_string => |value| value,
                        else => unreachable,
                    };
                    var selected = nulTerminatedPrefix(borrowed orelse "");
                    if (precision >= 0) selected = if (flags.alternate_two) utf8Prefix(selected, @intCast(precision)) else selected[0..@min(selected.len, @as(usize, @intCast(precision)))];
                    appendField(accumulator, manager, selected, width, flags.left, flags.alternate_two);
                    continue;
                }
                const owned = cursor.ownedString();
                if (owned) |owned_text| {
                    const text = std.mem.span(owned_text);
                    if (accumulator.nChar == 0 and accumulator.mxAlloc != 0 and width == 0 and precision < 0 and accumulator.accError == 0) {
                        std.debug.assert(!isMalloced(accumulator));
                        accumulator.zText = owned_text;
                        accumulator.nAlloc = @intCast(manager.size(owned_text));
                        accumulator.nChar = @intCast(text.len & 0x7fff_ffff);
                        accumulator.printfFlags |= printf_malloced;
                    } else {
                        var selected: []const u8 = text;
                        if (precision >= 0) selected = if (flags.alternate_two) utf8Prefix(text, @intCast(precision)) else text[0..@min(text.len, @as(usize, @intCast(precision)))];
                        appendField(accumulator, manager, selected, width, flags.left, flags.alternate_two);
                        manager.free(owned_text);
                    }
                }
            },
            et_charx => {
                const argument = cursor.next() orelse FormatArgument{ .character = 0 };
                var encoded: [4]u8 = undefined;
                const encoded_length: u8 = switch (argument) {
                    .character_text => |text_optional| blk: {
                        const text = text_optional orelse {
                            encoded[0] = 0;
                            break :blk 1;
                        };
                        const bounded = nulTerminatedPrefix(text);
                        if (bounded.len == 0) {
                            encoded[0] = 0;
                            break :blk 1;
                        }
                        var length: u8 = 1;
                        encoded[0] = bounded[0];
                        if (bounded[0] & 0xc0 == 0xc0) {
                            while (length < 4 and length < bounded.len and bounded[length] & 0xc0 == 0x80) : (length += 1) {
                                encoded[length] = bounded[length];
                            }
                        }
                        break :blk length;
                    },
                    else => blk: {
                        const character: u32 = switch (argument) {
                            .character => |value| value,
                            .unsigned => |value| @truncate(value),
                            .signed => |value| @truncate(@as(u64, @bitCast(value))),
                            else => 0,
                        };
                        break :blk utf.appendOneUtf8(&encoded, character);
                    },
                };
                const repeats: c_int = if (precision > 1) precision else 1;
                const padding = @max(0, width - repeats);
                if (!flags.left) strAppendChar(accumulator, manager, padding, ' ');
                var repeat: c_int = 0;
                while (repeat < repeats) : (repeat += 1) strAppend(accumulator, manager, encoded[0..encoded_length]);
                if (flags.left) strAppendChar(accumulator, manager, padding, ' ');
            },
            et_escape_q, et_escape_Q, et_escape_w => renderEscape(accumulator, manager, found.conversion_type, cursor.string(), flags, width, precision),
            et_percent => strAppend(accumulator, manager, "%"),
            et_size => switch (cursor.next() orelse return) {
                .count => |target| target.* = @intCast(accumulator.nChar),
                .ignored_count => {},
                else => {},
            },
            et_token => {
                if (accumulator.printfFlags & printf_internal == 0) return;
                if (flags.alternate) {
                    switch (cursor.next() orelse return) {
                        .expression_token => |text| if (text) |value| strAppend(accumulator, manager, nulTerminatedPrefix(value)),
                        else => {},
                    }
                } else switch (cursor.next() orelse return) {
                    .token => |token_optional| if (token_optional) |token| {
                        if (token.n != 0) strAppend(accumulator, manager, token.z.?[0..token.n]);
                    },
                    else => {},
                }
            },
            et_srcitem => {
                if (accumulator.printfFlags & printf_internal == 0) return;
                const item = switch (cursor.next() orelse return) {
                    .source_item => |value| value orelse return,
                    else => return,
                };
                if (item.alias != null and !flags.alternate_two) {
                    strAppend(accumulator, manager, nulTerminatedPrefix(item.alias.?));
                } else if (item.name) |name| {
                    if (!item.fixed_schema and !item.is_subquery and item.database != null) {
                        strAppend(accumulator, manager, nulTerminatedPrefix(item.database.?));
                        strAppend(accumulator, manager, ".");
                    }
                    strAppend(accumulator, manager, nulTerminatedPrefix(name));
                } else if (item.alias) |alias| {
                    strAppend(accumulator, manager, nulTerminatedPrefix(alias));
                } else if (item.is_subquery) {
                    if (item.nested_from) {
                        strAppendFormat(accumulator, manager, "(join-%u)", &.{.{ .unsigned = item.select_id }});
                    } else if (item.multi_value) {
                        strAppendFormat(accumulator, manager, "%u-ROW VALUES CLAUSE", &.{.{ .unsigned = item.row_count }});
                    } else {
                        strAppendFormat(accumulator, manager, "(subquery-%u)", &.{.{ .unsigned = item.select_id }});
                    }
                }
            },
            else => return,
        }
        if (accumulator.accError != 0) return;
    }
}

/// Typed behavioral replacement for sqlite3VMPrintf()/sqlite3_vmprintf().
pub fn allocFormat(
    manager: *memory.Manager,
    maximum: u32,
    format_flags: u8,
    format: []const u8,
    arguments: []const FormatArgument,
) ?[*:0]u8 {
    std.debug.assert(maximum > 0);
    var base: [buffer_size]u8 = undefined;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, &base, base.len, maximum);
    accumulator.printfFlags = format_flags & (printf_internal | printf_sql_function);
    strAppendFormat(&accumulator, manager, format, arguments);
    const output = strAccumFinish(&accumulator, manager);
    if (accumulator.accError != 0) return null;
    return output;
}

/// Typed behavioral replacement for sqlite3_vsnprintf()/sqlite3_snprintf().
pub fn fixedFormat(
    manager: *memory.Manager,
    buffer: []u8,
    format: []const u8,
    arguments: []const FormatArgument,
) usize {
    if (buffer.len == 0) return 0;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(u32))), 0);
    strAppendFormat(&accumulator, manager, format, arguments);
    buffer[accumulator.nChar] = 0;
    return accumulator.nChar;
}

pub const LogCallback = *const fn (?*anyopaque, c_int, []const u8) void;

/// Typed behavioral replacement for renderLogMsg(). The callback is invoked
/// synchronously while the fixed message storage is live.
pub fn renderLogMessage(
    manager: *memory.Manager,
    context: ?*anyopaque,
    callback: LogCallback,
    error_code: c_int,
    format: []const u8,
    arguments: []const FormatArgument,
) void {
    var message: [max_log_message]u8 = undefined;
    const length = fixedFormat(manager, &message, format, arguments);
    callback(context, error_code, message[0..length]);
}

fn rcHeader(text: [*]u8) *ReferenceCountedStringHeader {
    return @ptrCast(@alignCast(text - @sizeOf(ReferenceCountedStringHeader)));
}

fn rcText(header: *ReferenceCountedStringHeader) [*]u8 {
    return @as([*]u8, @ptrCast(header)) + @sizeOf(ReferenceCountedStringHeader);
}

/// Upstream: sqlite3RCStrNew(). The returned N+1 bytes are uninitialized.
pub fn rcStrNew(manager: *memory.Manager, capacity: u64) ?[*]u8 {
    const overhead = @sizeOf(ReferenceCountedStringHeader) + 1;
    if (capacity > memory.max_allocation_size - overhead) return null;
    const allocation = manager.alloc(capacity + overhead) orelse return null;
    const header: *ReferenceCountedStringHeader = @ptrCast(@alignCast(allocation));
    header.nRCRef = 1;
    return rcText(header);
}

/// Upstream: sqlite3RCStrRef().
pub fn rcStrRef(text: [*]u8) [*]u8 {
    const header = rcHeader(text);
    std.debug.assert(header.nRCRef > 0);
    header.nRCRef += 1;
    return text;
}

/// Upstream: sqlite3RCStrUnref().
pub fn rcStrUnref(manager: *memory.Manager, text: [*]u8) void {
    const header = rcHeader(text);
    std.debug.assert(header.nRCRef > 0);
    if (header.nRCRef >= 2) {
        header.nRCRef -= 1;
    } else {
        manager.free(header);
    }
}

/// Upstream: sqlite3RCStrResize(). Failed realloc consumes the old string.
pub fn rcStrResize(manager: *memory.Manager, text: [*]u8, capacity: u64) ?[*]u8 {
    const header = rcHeader(text);
    std.debug.assert(header.nRCRef == 1);
    const overhead = @sizeOf(ReferenceCountedStringHeader) + 1;
    if (capacity > memory.max_allocation_size - overhead) {
        manager.free(header);
        return null;
    }
    const resized = manager.realloc(header, capacity + overhead) orelse {
        manager.free(header);
        return null;
    };
    return rcText(@ptrCast(@alignCast(resized)));
}

const LogProbe = struct {
    code: c_int = 0,
    length: usize = 0,
    bytes: [max_log_message]u8 = undefined,
};

fn captureLog(context: ?*anyopaque, code: c_int, message: []const u8) void {
    const probe: *LogProbe = @ptrCast(@alignCast(context.?));
    probe.code = code;
    probe.length = message.len;
    std.mem.copyForwards(u8, probe.bytes[0..message.len], message);
}

test "formatter metadata and hash chains" {
    try std.testing.expectEqual(@as(usize, 23), format_info.len);
    try std.testing.expectEqualStrings("0123456789ABCDEF0123456789abcdef", digits);
    try std.testing.expectEqual(et_decimal, lookup('d').conversion_type);
    try std.testing.expectEqual(@as(u8, 17), lookup('X').info_index);
    try std.testing.expectEqual(et_invalid, lookup('v').conversion_type);
    for (0..256) |raw| {
        const character: u8 = @intCast(raw);
        const result = lookup(character);
        if (result.conversion_type != et_invalid) {
            try std.testing.expectEqual(character, format_info[result.info_index].fmttype);
        }
    }
}

test "StrAccum fixed buffer retains text on too-big error" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var base: [8]u8 = undefined;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, &base, base.len, 0);
    strAppend(&accumulator, &manager, "1234567");
    try std.testing.expectEqual(@as(c_int, 7), strLength(&accumulator));
    strAppendChar(&accumulator, &manager, 1, '8');
    try std.testing.expectEqual(@as(c_int, too_big), strErrorCode(&accumulator));
    try std.testing.expectEqual(@as(c_int, 7), strLength(&accumulator));
    try std.testing.expectEqualStrings("1234567", std.mem.span(strValue(&accumulator).?));
    strReset(&accumulator, &manager);
    try std.testing.expectEqual(@as(c_int, too_big), strErrorCode(&accumulator));
    try std.testing.expectEqual(@as(c_int, 0), strLength(&accumulator));
}

test "StrAccum grows, truncates, finishes, and resets allocated text" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var base: [8]u8 = undefined;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, &base, base.len, 128);
    strAppend(&accumulator, &manager, "abc");
    strAppend(&accumulator, &manager, "defghijkl");
    try std.testing.expect(isMalloced(&accumulator));
    try std.testing.expectEqualStrings("abcdefghijkl", std.mem.span(strValue(&accumulator).?));
    strTruncate(&accumulator, 5);
    try std.testing.expectEqualStrings("abcde", std.mem.span(strAccumFinish(&accumulator, &manager).?));
    strReset(&accumulator, &manager);
    try std.testing.expect(!isMalloced(&accumulator));
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
}

test "StrAccum allocation failure is sticky and leak-free" {
    for ([_]bool{ false, true }) |sticky| {
        var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0, .sticky = sticky };
        var manager = memory.Manager.init(fault.backend());
        try std.testing.expectEqual(memory.ok, manager.start());
        defer manager.stop();
        var accumulator: Accumulator = undefined;
        strAccumInit(&accumulator, null, null, 0, 128);
        strAppend(&accumulator, &manager, "allocation-required");
        try std.testing.expectEqual(@as(c_int, no_memory), strErrorCode(&accumulator));
        try std.testing.expectEqual(@as(c_int, 0), strLength(&accumulator));
        try std.testing.expect(accumulator.zText == null);
        try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
        strAppend(&accumulator, &manager, "ignored-after-error");
        try std.testing.expectEqual(@as(c_int, no_memory), strErrorCode(&accumulator));
    }
}

test "dynamic string object limit finish free and OOM singleton" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var object = stringObjectNew(&manager, null, 128);
    strAppend(object, &manager, "hello");
    const finished = stringObjectFinish(&manager, object).?;
    try std.testing.expectEqualStrings("hello", std.mem.span(finished));
    manager.free(finished);
    object = stringObjectNew(&manager, null, 5);
    strAppend(object, &manager, "123456");
    try std.testing.expectEqual(@as(c_int, too_big), strErrorCode(object));
    try std.testing.expect(stringObjectFinish(&manager, object) == null);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);

    var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0 };
    var fault_manager = memory.Manager.init(fault.backend());
    try std.testing.expectEqual(memory.ok, fault_manager.start());
    defer fault_manager.stop();
    const failed = stringObjectNew(&fault_manager, null, 128);
    try std.testing.expect(stringObjectIsOom(failed));
    strAppend(failed, &fault_manager, "ignored");
    try std.testing.expectEqual(@as(c_int, no_memory), strErrorCode(failed));
    try std.testing.expect(stringObjectFinish(&fault_manager, failed) == null);
    stringObjectFree(&fault_manager, failed);
}

test "printf temporary buffer limit and allocation failure" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var base: [8]u8 = undefined;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, &base, base.len, 0);
    const temporary = printfTempBuffer(&accumulator, &manager, 8).?;
    try std.testing.expectEqual(@as(usize, 8), manager.size(temporary));
    manager.free(temporary);
    try std.testing.expect(printfTempBuffer(&accumulator, &manager, 9) == null);
    try std.testing.expectEqual(@as(c_int, too_big), strErrorCode(&accumulator));

    var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0 };
    var fault_manager = memory.Manager.init(fault.backend());
    try std.testing.expectEqual(memory.ok, fault_manager.start());
    defer fault_manager.stop();
    var fault_base: [16]u8 = undefined;
    strAccumInit(&accumulator, null, &fault_base, fault_base.len, 0);
    try std.testing.expect(printfTempBuffer(&accumulator, &fault_manager, 8) == null);
    try std.testing.expectEqual(@as(c_int, no_memory), strErrorCode(&accumulator));
    try std.testing.expectEqual(@as(i64, 0), fault_manager.status(.memory_used, false).current);
}

test "typed allocated fixed and logging formatter callers" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    const allocated = allocFormat(&manager, 1024, 0, "%d|%Q|%.2f", &.{ .{ .signed = 7 }, .{ .string = "a'b" }, .{ .float = 1.25 } }).?;
    try std.testing.expectEqualStrings("7|'a''b'|1.25", std.mem.span(allocated));
    manager.free(allocated);
    const empty = allocFormat(&manager, 1024, 0, "", &.{}).?;
    try std.testing.expectEqualStrings("", std.mem.span(empty));
    manager.free(empty);
    var fixed: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), fixedFormat(&manager, &fixed, "abcdefghi", &.{}));
    try std.testing.expectEqualStrings("abcdefg", std.mem.span(@as([*:0]u8, @ptrCast(&fixed))));
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), fixedFormat(&manager, &one, "x", &.{}));
    try std.testing.expectEqual(@as(u8, 0), one[0]);
    var probe = LogProbe{};
    renderLogMessage(&manager, &probe, captureLog, 17, "error %d", &.{.{ .signed = 9 }});
    try std.testing.expectEqual(@as(c_int, 17), probe.code);
    try std.testing.expectEqualStrings("error 9", probe.bytes[0..probe.length]);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
}

test "typed allocated formatter callers preserve OOM ownership" {
    for ([_]bool{ false, true }) |sticky| {
        var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0, .sticky = sticky };
        var manager = memory.Manager.init(fault.backend());
        try std.testing.expectEqual(memory.ok, manager.start());
        defer manager.stop();
        try std.testing.expect(allocFormat(&manager, 1024, 0, "small", &.{}) == null);
        try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    }
}

test "typed formatter integer string escape character and count subset" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var base: [256]u8 = undefined;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, &base, base.len, 0);
    var count: c_int = -1;
    const arguments = [_]FormatArgument{
        .{ .signed = -42 },
        .{ .unsigned = 0x2a },
        .{ .string = "a'b" },
        .{ .character = 0x20ac },
        .{ .count = &count },
    };
    strAppendFormat(&accumulator, &manager, "%08d|%#x|%Q|%.2c%n", &arguments);
    try std.testing.expectEqualStrings("-0000042|0x2a|'a''b'|€€", std.mem.span(strValue(&accumulator).?));
    try std.testing.expectEqual(@as(c_int, 27), count);
}

test "typed formatter internal token and source-item rendering" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var base: [256]u8 = undefined;
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, &base, base.len, 0);
    accumulator.printfFlags |= printf_internal;
    const token = Token{ .z = "token-bytes", .n = 5 };
    strAppendFormat(&accumulator, &manager, "%T|%#T|%S|%!S|%S|%S|%S", &.{
        .{ .token = &token },
        .{ .expression_token = "expr" },
        .{ .source_item = .{ .alias = "alias", .name = "table", .database = "main" } },
        .{ .source_item = .{ .alias = "alias", .name = "table", .database = "main" } },
        .{ .source_item = .{ .is_subquery = true, .nested_from = true, .select_id = 7 } },
        .{ .source_item = .{ .is_subquery = true, .multi_value = true, .row_count = 3 } },
        .{ .source_item = .{ .is_subquery = true, .select_id = 9 } },
    });
    try std.testing.expectEqualStrings("token|expr|alias|main.table|(join-7)|3-ROW VALUES CLAUSE|(subquery-9)", std.mem.span(strValue(&accumulator).?));
}

test "typed floating formatter preserves enlargement OOM" {
    for ([_]bool{ false, true }) |sticky| {
        var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0, .sticky = sticky };
        var manager = memory.Manager.init(fault.backend());
        try std.testing.expectEqual(memory.ok, manager.start());
        defer manager.stop();
        var accumulator: Accumulator = undefined;
        strAccumInit(&accumulator, null, null, 0, 128);
        strAppendFormat(&accumulator, &manager, "%f", &.{.{ .float = 1.25 }});
        try std.testing.expectEqual(@as(c_int, no_memory), strErrorCode(&accumulator));
        try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    }
}

test "typed formatter transfers percent-z ownership" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var accumulator: Accumulator = undefined;
    strAccumInit(&accumulator, null, null, 0, 128);
    const adopted_allocation = manager.alloc(6).?;
    const adopted: [*:0]u8 = @ptrCast(adopted_allocation);
    std.mem.copyForwards(u8, adopted[0..6], "owned\x00");
    strAppendFormat(&accumulator, &manager, "%z", &.{.{ .owned_string = adopted }});
    try std.testing.expectEqual(@intFromPtr(adopted), @intFromPtr(accumulator.zText.?));
    try std.testing.expectEqualStrings("owned", std.mem.span(strValue(&accumulator).?));
    try std.testing.expectEqual(@as(i64, 1), manager.status(.malloc_count, false).current);
    strReset(&accumulator, &manager);

    var base: [32]u8 = undefined;
    strAccumInit(&accumulator, null, &base, base.len, 128);
    strAppend(&accumulator, &manager, "x");
    const copied_allocation = manager.alloc(6).?;
    const copied: [*:0]u8 = @ptrCast(copied_allocation);
    std.mem.copyForwards(u8, copied[0..6], "owned\x00");
    strAppendFormat(&accumulator, &manager, "%7z", &.{.{ .owned_string = copied }});
    try std.testing.expectEqualStrings("x  owned", std.mem.span(strValue(&accumulator).?));
    try std.testing.expectEqual(@as(i64, 0), manager.status(.malloc_count, false).current);
}

test "RCStr reference, resize, and release lifecycle" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var text = rcStrNew(&manager, 5).?;
    std.mem.copyForwards(u8, text[0..6], "abcde\x00");
    try std.testing.expectEqual(@as(u64, 1), rcHeader(text).nRCRef);
    _ = rcStrRef(text);
    _ = rcStrRef(text);
    try std.testing.expectEqual(@as(u64, 3), rcHeader(text).nRCRef);
    rcStrUnref(&manager, text);
    rcStrUnref(&manager, text);
    text = rcStrResize(&manager, text, 10).?;
    try std.testing.expectEqualStrings("abcde", std.mem.span(@as([*:0]u8, @ptrCast(text))));
    try std.testing.expectEqual(@as(u64, 1), rcHeader(text).nRCRef);
    rcStrUnref(&manager, text);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
}

test "RCStr failed resize consumes old allocation" {
    for ([_]bool{ false, true }) |sticky| {
        var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 1, .sticky = sticky };
        var manager = memory.Manager.init(fault.backend());
        try std.testing.expectEqual(memory.ok, manager.start());
        defer manager.stop();
        const text = rcStrNew(&manager, 5).?;
        try std.testing.expect(rcStrResize(&manager, text, 100) == null);
        try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    }
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    const text = rcStrNew(&manager, 1).?;
    try std.testing.expect(rcStrResize(&manager, text, memory.max_allocation_size) == null);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
}
