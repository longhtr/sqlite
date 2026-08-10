//! Core SQL scalar and aggregate function bodies from `func.c`.

const std = @import("std");
extern fn sqlite3_randomness(c_int, ?*anyopaque) callconv(.c) void;
extern fn sqlite3_compileoption_get(c_int) callconv(.c) ?[*:0]const u8;
extern fn sqlite3_compileoption_used(?[*:0]const u8) callconv(.c) c_int;
const build_profile = @import("build_profile");
const sqlite_float = @import("../float.zig");
const formatter = @import("../formatter.zig");
const logging = @import("../logging.zig");
const memory = @import("../memory.zig");
const utf = @import("../utf.zig");
const db_allocator = @import("db_allocator.zig");
const formatter_sql = @import("formatter_sql.zig");
const mem = @import("vdbe_mem.zig");
const types = @import("vdbe_types.zig");

const CallbackContext = ?*types.Context;
const CallbackArguments = ?[*]?*types.Mem;

fn argument(arguments: CallbackArguments, index: usize) *types.Mem {
    return arguments.?[index].?;
}

/// Source `sqlite3GetFuncCollSeq()`.
pub fn functionCollation(context: *types.Context) *types.CollSeq {
    const machine = context.pVdbe.?;
    return machine.aOp.?[@intCast(context.iOp - 1)].p4.pColl.?;
}

/// Source `sqlite3SkipAccumulatorLoad()`.
pub fn skipAccumulatorLoad(context: *types.Context) void {
    context.isError = -1;
    context.skipFlag = 1;
}

/// Source `minmaxFunc()`.
pub fn scalarMinMax(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const invert: c_int = if (context.pFunc.?.pUserData == null) 0 else -1;
    const collation = functionCollation(context);
    var best: usize = 0;
    if (mem.valueType(argument(arguments, 0)) == 5) return;
    for (1..@intCast(argument_count)) |index| {
        if (mem.valueType(argument(arguments, index)) == 5) return;
        if ((mem.compare(argument(arguments, best), argument(arguments, index), collation) ^ invert) >= 0) best = index;
    }
    mem.resultValue(context, argument(arguments, best));
}

/// Source `nullifFunc()`.
pub fn nullIf(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    if (mem.compare(argument(arguments, 0), argument(arguments, 1), functionCollation(context)) != 0) {
        mem.resultValue(context, argument(arguments, 0));
    }
}

/// Source `typeofFunc()`.
pub fn typeOf(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const names = [_][*:0]const u8{ "integer", "real", "text", "blob", "null" };
    const context = context_optional.?;
    const value_type = mem.valueType(argument(arguments, 0));
    mem.resultText(context, names[@intCast(value_type - 1)], -1, .static);
}

/// Source `sqlite3QuoteValue()`.
pub fn quoteValue(accumulator: *formatter.Accumulator, value: *types.Mem, escape_controls: bool) void {
    const manager = memory.processManager();
    switch (mem.valueType(value)) {
        2 => formatter.strAppendFormat(accumulator, manager, "%!0.17g", &.{.{ .float = mem.valueDouble(value) }}),
        1 => formatter.strAppendFormat(accumulator, manager, "%lld", &.{.{ .signed = mem.valueInt64(value) }}),
        4 => {
            const blob = mem.valueBlob(value);
            const byte_count: usize = @intCast(mem.valueBytes(value, 1));
            _ = formatter.strAccumEnlarge(accumulator, manager, @intCast(byte_count * 2 + 4));
            if (accumulator.accError == 0) {
                const output = accumulator.zText.?;
                output[0] = 'X';
                output[1] = '\'';
                if (blob) |bytes| for (bytes[0..byte_count], 0..) |byte, index| {
                    output[index * 2 + 2] = "0123456789ABCDEF"[byte >> 4];
                    output[index * 2 + 3] = "0123456789ABCDEF"[byte & 15];
                };
                output[byte_count * 2 + 2] = '\'';
                output[byte_count * 2 + 3] = 0;
                accumulator.nChar = @intCast(byte_count * 2 + 3);
            }
        },
        3 => {
            const text = mem.valueText(value, 1) orelse return;
            formatter.strAppendFormat(accumulator, manager, if (escape_controls) "%#Q" else "%Q", &.{.{ .string = std.mem.span(@as([*:0]const u8, @ptrCast(text))) }});
        },
        else => formatter.strAppend(accumulator, manager, "NULL"),
    }
}

/// Source `quoteFunc()`.
pub fn quote(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const db = context.pOut.?.db.?;
    var accumulator: formatter.Accumulator = undefined;
    formatter.strAccumInit(&accumulator, db, null, 0, @intCast(db.aLimit[0]));
    quoteValue(&accumulator, argument(arguments, 0), context.pFunc.?.pUserData != null);
    const output = formatter.strAccumFinish(&accumulator, memory.processManager());
    mem.resultText(context, output, @intCast(accumulator.nChar), .dynamic);
    if (accumulator.accError != 0) {
        mem.resultNull(context);
        mem.resultErrorCode(context, accumulator.accError);
    }
}

/// Source `unicodeFunc()`.
pub fn unicode(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const text = mem.valueText(argument(arguments, 0), 1) orelse return;
    if (text[0] != 0) mem.resultInt(context_optional.?, @intCast(utf.read(@ptrCast(text)).value));
}

/// Source `instrFunc()`.
pub fn instruction(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const original_haystack = argument(arguments, 0);
    const original_needle = argument(arguments, 1);
    const haystack_type = mem.valueType(original_haystack);
    const needle_type = mem.valueType(original_needle);
    if (haystack_type == 5 or needle_type == 5) return;

    var haystack_value = original_haystack;
    var needle_value = original_needle;
    var haystack_copy: ?*types.Mem = null;
    var needle_copy: ?*types.Mem = null;
    defer mem.valueFree(haystack_copy);
    defer mem.valueFree(needle_copy);

    var haystack_length = mem.valueBytes(haystack_value, 1);
    var needle_length = mem.valueBytes(needle_value, 1);
    var text_mode = false;
    var haystack: ?[*]const u8 = null;
    var needle: ?[*]const u8 = null;
    if (needle_length > 0) {
        if (haystack_type == 4 and needle_type == 4) {
            haystack = mem.valueBlob(haystack_value);
            needle = mem.valueBlob(needle_value);
        } else if (haystack_type != 4 and needle_type != 4) {
            haystack = mem.valueText(haystack_value, 1);
            needle = mem.valueText(needle_value, 1);
            text_mode = true;
        } else {
            haystack_copy = mem.valueDuplicate(haystack_value) orelse {
                mem.resultErrorNoMem(context);
                return;
            };
            haystack_value = haystack_copy.?;
            haystack = mem.valueText(haystack_value, 1) orelse {
                mem.resultErrorNoMem(context);
                return;
            };
            haystack_length = mem.valueBytes(haystack_value, 1);
            needle_copy = mem.valueDuplicate(needle_value) orelse {
                mem.resultErrorNoMem(context);
                return;
            };
            needle_value = needle_copy.?;
            needle = mem.valueText(needle_value, 1) orelse {
                mem.resultErrorNoMem(context);
                return;
            };
            needle_length = mem.valueBytes(needle_value, 1);
            text_mode = true;
        }
        if (needle == null or (haystack_length != 0 and haystack == null)) {
            mem.resultErrorNoMem(context);
            return;
        }
    }

    var result: c_int = 1;
    var byte_offset: usize = 0;
    while (needle_length <= haystack_length) {
        if (needle_length == 0 or std.mem.eql(
            u8,
            haystack.?[byte_offset..][0..@intCast(needle_length)],
            needle.?[0..@intCast(needle_length)],
        )) break;
        result += 1;
        byte_offset += 1;
        haystack_length -= 1;
        while (text_mode and haystack_length > 0 and haystack.?[byte_offset] & 0xc0 == 0x80) {
            byte_offset += 1;
            haystack_length -= 1;
        }
    }
    if (needle_length > haystack_length) result = 0;
    mem.resultInt(context, result);
}

/// Source `subtypeFunc()`.
pub fn subtype(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    mem.resultInt(context_optional.?, @intCast(mem.valueSubtype(argument(arguments, 0))));
}

/// Source `versionFunc()`.
pub fn version(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    mem.resultText(context_optional.?, build_profile.sqlite_version.ptr, -1, .static);
}

/// Source `sourceidFunc()`.
pub fn sourceId(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    mem.resultText(context_optional.?, build_profile.sqlite_source_id.ptr, -1, .static);
}

/// Source `errlogFunc()`.
pub fn errorLog(_: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const message = mem.valueText(argument(arguments, 1), 1) orelse return;
    logging.message(mem.valueInt(argument(arguments, 0)), @ptrCast(message));
}

/// Source `compileoptionusedFunc()`.
pub fn compileOptionUsed(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const name = mem.valueText(argument(arguments, 0), 1) orelse return;
    mem.resultInt(context_optional.?, sqlite3_compileoption_used(@ptrCast(name)));
}

/// Source `compileoptiongetFunc()`.
pub fn compileOptionGet(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const option = sqlite3_compileoption_get(mem.valueInt(argument(arguments, 0)));
    mem.resultText(context_optional.?, option, -1, .static);
}

/// Source `lengthFunc()`.
pub fn length(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    switch (mem.valueType(value)) {
        1, 2, 4 => mem.resultInt(context, mem.valueBytes(value, 1)),
        3 => {
            const text = mem.valueText(value, 1) orelse return;
            var bytes: usize = 0;
            var character_count: c_int = 0;
            while (text[bytes] != 0) : (character_count += 1) {
                bytes += 1;
                while (text[bytes] & 0xc0 == 0x80) bytes += 1;
            }
            mem.resultInt(context, character_count);
        },
        else => mem.resultNull(context),
    }
}

/// Source `bytelengthFunc()`.
pub fn byteLength(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    switch (mem.valueType(value)) {
        4 => mem.resultInt(context, mem.valueBytes(value, 1)),
        1, 2 => {
            const multiplier: i64 = if (context.pOut.?.db.?.enc <= 1) 1 else 2;
            mem.resultInt64(context, @as(i64, mem.valueBytes(value, 1)) * multiplier);
        },
        3 => mem.resultInt(context, mem.valueBytes(value, if (mem.valueEncoding(value) <= 1) 1 else 2)),
        else => mem.resultNull(context),
    }
}

/// Source `absFunc()`.
pub fn absolute(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    switch (mem.valueType(value)) {
        1 => {
            const integer = mem.valueInt64(value);
            if (integer == std.math.minInt(i64)) {
                mem.resultError(context, "integer overflow", -1);
            } else {
                mem.resultInt64(context, if (integer < 0) -integer else integer);
            }
        },
        5 => mem.resultNull(context),
        else => {
            const real = mem.valueDouble(value);
            mem.resultDouble(context, if (real < 0) -real else real);
        },
    }
}

/// Source `contextMalloc()` using the owning connection allocator.
pub fn contextAllocate(context: *types.Context, byte_count: i64) ?[*]u8 {
    const db = context.pOut.?.db.?;
    if (byte_count <= 0 or byte_count > db.aLimit[0]) {
        mem.resultErrorTooBig(context);
        return null;
    }
    const allocation = db_allocator.mallocRawNN(db, @intCast(byte_count)) orelse {
        mem.resultErrorNoMem(context);
        return null;
    };
    return @ptrCast(allocation);
}

/// Source `printfFunc()`.
pub fn printFormat(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    if (argument_count < 1) return;
    const context = context_optional.?;
    const format_pointer = mem.valueText(argument(arguments, 0), 1) orelse return;
    const format = std.mem.span(@as([*:0]const u8, @ptrCast(format_pointer)));
    var printf_arguments = mem.PrintfArguments{
        .nArg = argument_count - 1,
        .nUsed = 0,
        .apArg = arguments.? + 1,
    };
    var accumulator: formatter.Accumulator = undefined;
    const db = context.pOut.?.db.?;
    formatter.strAccumInit(&accumulator, db, null, 0, @intCast(db.aLimit[0]));
    accumulator.printfFlags = formatter.printf_sql_function;
    const allocator = memory.processAllocator();
    const scratch = allocator.alloc(formatter.FormatArgument, format.len) catch {
        mem.resultErrorNoMem(context);
        return;
    };
    defer allocator.free(scratch);
    formatter_sql.append(&accumulator, memory.processManager(), format, &printf_arguments, scratch) catch {
        formatter.strAccumSetError(&accumulator, memory.processManager(), formatter.too_big);
    };
    formatter_sql.resultAccumulator(context, &accumulator);
}

/// Source `roundFunc()`.
pub fn round(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    var precision: i64 = 0;
    if (argument_count == 2) {
        if (mem.valueType(argument(arguments, 1)) == 5) return;
        precision = std.math.clamp(mem.valueInt64(argument(arguments, 1)), 0, 30);
    }
    if (mem.valueType(argument(arguments, 0)) == 5) return;
    var result = mem.valueDouble(argument(arguments, 0));
    if (result >= -4_503_599_627_370_496.0 and result <= 4_503_599_627_370_496.0) {
        if (precision == 0) {
            result = @floatFromInt(@as(i64, @intFromFloat(result + if (result < 0) @as(f64, -0.5) else @as(f64, 0.5))));
        } else {
            var buffer: [70]u8 = undefined;
            _ = formatter.fixedFormat(memory.processManager(), &buffer, "%!.*f", &.{
                .{ .signed = precision },
                .{ .float = result },
            });
            result = sqlite_float.parse(@ptrCast(&buffer)).value;
        }
    }
    mem.resultDouble(context, result);
}

/// Source `upperFunc()`.
pub fn upper(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const source = mem.valueText(value, 1) orelse return;
    const byte_count = mem.valueBytes(value, 1);
    const result = contextAllocate(context, @as(i64, byte_count) + 1) orelse return;
    for (source[0..@intCast(byte_count)], result[0..@intCast(byte_count)]) |byte, *output| {
        output.* = if (byte >= 'a' and byte <= 'z') byte - 0x20 else byte;
    }
    result[@intCast(byte_count)] = 0;
    mem.resultText(context, result, byte_count, .dynamic);
}

/// Source `lowerFunc()`.
pub fn lower(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const source = mem.valueText(value, 1) orelse return;
    const byte_count = mem.valueBytes(value, 1);
    const result = contextAllocate(context, @as(i64, byte_count) + 1) orelse return;
    for (source[0..@intCast(byte_count)], result[0..@intCast(byte_count)]) |byte, *output| {
        output.* = if (byte >= 'A' and byte <= 'Z') byte + 0x20 else byte;
    }
    result[@intCast(byte_count)] = 0;
    mem.resultText(context, result, byte_count, .dynamic);
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// Source `isNHex()`.
pub fn decodeHexDigits(bytes: []const u8, digit_count: usize, output: *u32) bool {
    if (bytes.len < digit_count) return false;
    var value: u32 = 0;
    for (bytes[0..digit_count]) |byte| value = (value << 4) + (hexDigit(byte) orelse return false);
    output.* = value;
    return true;
}

/// Source `unistrFunc()`.
pub fn unicodeEscapes(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const source_pointer = mem.valueText(value, 1) orelse return;
    const source_length: usize = @intCast(mem.valueBytes(value, 1));
    const result = contextAllocate(context, @intCast(source_length + 1)) orelse return;
    var input: usize = 0;
    var output: usize = 0;
    while (input < source_length) {
        if (source_pointer[input] != '\\') {
            result[output] = source_pointer[input];
            input += 1;
            output += 1;
            continue;
        }
        if (input + 1 >= source_length) {
            db_allocator.free(context.pOut.?.db, result);
            mem.resultError(context, "invalid Unicode escape", -1);
            return;
        }
        if (source_pointer[input + 1] == '\\') {
            result[output] = '\\';
            input += 2;
            output += 1;
            continue;
        }
        var codepoint: u32 = undefined;
        var digits_start = input + 1;
        var digits: usize = 4;
        switch (source_pointer[input + 1]) {
            '+' => {
                digits_start = input + 2;
                digits = 6;
            },
            'u' => digits_start = input + 2,
            'U' => {
                digits_start = input + 2;
                digits = 8;
            },
            else => {},
        }
        if (!decodeHexDigits(source_pointer[digits_start..source_length], digits, &codepoint)) {
            db_allocator.free(context.pOut.?.db, result);
            mem.resultError(context, "invalid Unicode escape", -1);
            return;
        }
        var encoded: [4]u8 = undefined;
        const encoded_length = utf.appendOneUtf8(&encoded, codepoint);
        @memcpy(result[output..][0..encoded_length], encoded[0..encoded_length]);
        output += encoded_length;
        input = digits_start + digits;
    }
    result[output] = 0;
    mem.resultText64(context, result, output, 16, .dynamic);
}

/// Source `charFunc()`.
pub fn characters(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const result = contextAllocate(context, @as(i64, argument_count) * 4 + 1) orelse return;
    var written: usize = 0;
    for (0..@intCast(argument_count)) |index| {
        const integer = mem.valueInt64(argument(arguments, index));
        const codepoint: u21 = if (integer < 0 or integer > 0x10ffff) 0xfffd else @intCast(integer);
        if (codepoint < 0x80) {
            result[written] = @intCast(codepoint);
            written += 1;
        } else if (codepoint < 0x800) {
            result[written] = 0xc0 | @as(u8, @intCast(codepoint >> 6));
            result[written + 1] = 0x80 | @as(u8, @intCast(codepoint & 0x3f));
            written += 2;
        } else if (codepoint < 0x10000) {
            result[written] = 0xe0 | @as(u8, @intCast(codepoint >> 12));
            result[written + 1] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3f));
            result[written + 2] = 0x80 | @as(u8, @intCast(codepoint & 0x3f));
            written += 3;
        } else {
            result[written] = 0xf0 | @as(u8, @intCast(codepoint >> 18));
            result[written + 1] = 0x80 | @as(u8, @intCast((codepoint >> 12) & 0x3f));
            result[written + 2] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3f));
            result[written + 3] = 0x80 | @as(u8, @intCast(codepoint & 0x3f));
            written += 4;
        }
    }
    result[written] = 0;
    mem.resultText64(context, result, written, 16, .dynamic);
}

/// Source `strContainsChar()`.
pub fn containsCharacter(text: []const u8, codepoint: u32) bool {
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = utf.readBounded(text[offset..]);
        if (decoded.value == codepoint) return true;
        offset += decoded.length;
    }
    return false;
}

/// Source `unhexFunc()`.
pub fn unhex(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const hex_value = argument(arguments, 0);
    const hex_text = mem.valueText(hex_value, 1) orelse return;
    const hex_length: usize = @intCast(mem.valueBytes(hex_value, 1));
    var allowed: []const u8 = "";
    if (argument_count == 2) {
        const allowed_value = argument(arguments, 1);
        const allowed_text = mem.valueText(allowed_value, 1) orelse return;
        allowed = allowed_text[0..@intCast(mem.valueBytes(allowed_value, 1))];
    }
    const result = contextAllocate(context, @intCast(hex_length / 2 + 1)) orelse return;
    var input: usize = 0;
    var output: usize = 0;
    while (input < hex_length and hex_text[input] != 0) {
        var high = hexDigit(hex_text[input]);
        while (high == null) {
            const decoded = utf.readBounded(hex_text[input..hex_length]);
            if (!containsCharacter(allowed, decoded.value)) {
                db_allocator.free(context.pOut.?.db, result);
                return;
            }
            input += decoded.length;
            if (input >= hex_length or hex_text[input] == 0) {
                mem.resultBlob(context, result, @intCast(output), .dynamic);
                return;
            }
            high = hexDigit(hex_text[input]);
        }
        input += 1;
        if (input >= hex_length) {
            db_allocator.free(context.pOut.?.db, result);
            return;
        }
        const low = hexDigit(hex_text[input]) orelse {
            db_allocator.free(context.pOut.?.db, result);
            return;
        };
        input += 1;
        result[output] = (high.? << 4) | low;
        output += 1;
    }
    mem.resultBlob(context, result, @intCast(output), .dynamic);
}

/// Source `hexFunc()`.
pub fn hexadecimal(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const digits = "0123456789ABCDEF";
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const source = mem.valueBlob(value);
    const byte_count = mem.valueBytes(value, 1);
    const result = contextAllocate(context, @as(i64, byte_count) * 2 + 1) orelse return;
    if (source) |bytes| {
        for (bytes[0..@intCast(byte_count)], 0..) |byte, index| {
            result[index * 2] = digits[byte >> 4];
            result[index * 2 + 1] = digits[byte & 0x0f];
        }
    }
    const output_length: usize = @intCast(byte_count * 2);
    result[output_length] = 0;
    mem.resultText64(context, result, output_length, 16, .dynamic);
}

/// Source `randomFunc()`.
pub fn randomInteger(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    var value: i64 = undefined;
    sqlite3_randomness(@sizeOf(i64), &value);
    if (value < 0) value = -(value & std.math.maxInt(i64));
    mem.resultInt64(context_optional.?, value);
}

/// Source `randomBlob()`.
pub fn randomBlob(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const byte_count: i64 = @max(mem.valueInt64(argument(arguments, 0)), 1);
    const result = contextAllocate(context, byte_count) orelse return;
    sqlite3_randomness(@intCast(byte_count), result);
    mem.resultBlob64(context, result, @intCast(byte_count), .dynamic);
}

/// Source `last_insert_rowid()` SQL function.
pub fn lastInsertRowid(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    mem.resultInt64(context, context.pOut.?.db.?.lastRowid);
}

/// Source `changes()` SQL function.
pub fn changes(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    mem.resultInt64(context, context.pOut.?.db.?.nChange);
}

/// Source `total_changes()` SQL function.
pub fn totalChanges(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    mem.resultInt64(context, context.pOut.?.db.?.nTotalChange);
}

pub const SumContext = extern struct {
    real_sum: f64,
    error_term: f64,
    integer_sum: i64,
    count: i64,
    approximate: u8,
    overflowed: u8,
};

/// Source `kahanBabuskaNeumaierStep()`.
pub fn kahanStep(sum: *SumContext, value: f64) void {
    const previous = sum.real_sum;
    const next = previous + value;
    if (@abs(previous) > @abs(value)) {
        sum.error_term += (previous - next) + value;
    } else {
        sum.error_term += (value - next) + previous;
    }
    sum.real_sum = next;
}

/// Source `kahanBabuskaNeumaierStepInt64()`.
pub fn kahanStepInteger(sum: *SumContext, value: i64) void {
    if (value <= -4_503_599_627_370_496 or value >= 4_503_599_627_370_496) {
        const small = @rem(value, 16_384);
        kahanStep(sum, @floatFromInt(value - small));
        kahanStep(sum, @floatFromInt(small));
    } else {
        kahanStep(sum, @floatFromInt(value));
    }
}

/// Source `kahanBabuskaNeumaierInit()`.
pub fn kahanInitialize(sum: *SumContext, value: i64) void {
    if (value <= -4_503_599_627_370_496 or value >= 4_503_599_627_370_496) {
        const small = @rem(value, 16_384);
        sum.real_sum = @floatFromInt(value - small);
        sum.error_term = @floatFromInt(small);
    } else {
        sum.real_sum = @floatFromInt(value);
        sum.error_term = 0;
    }
}

fn sumContext(context: *types.Context, size: c_int) ?*SumContext {
    const raw = mem.aggregateContext(context, size) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Source `sumStep()`.
pub fn sumStep(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const sum = sumContext(context, @sizeOf(SumContext)) orelse return;
    const value = argument(arguments, 0);
    const value_type = mem.valueNumericType(value);
    if (value_type == 5) return;
    sum.count += 1;
    if (sum.approximate == 0) {
        if (value_type != 1) {
            kahanInitialize(sum, sum.integer_sum);
            sum.approximate = 1;
            kahanStep(sum, mem.valueDouble(value));
        } else {
            const addend = mem.valueInt64(value);
            const result = @addWithOverflow(sum.integer_sum, addend);
            if (result[1] == 0) {
                sum.integer_sum = result[0];
            } else {
                sum.overflowed = 1;
                kahanInitialize(sum, sum.integer_sum);
                sum.approximate = 1;
                kahanStepInteger(sum, addend);
            }
        }
    } else if (value_type == 1) {
        kahanStepInteger(sum, mem.valueInt64(value));
    } else {
        sum.overflowed = 0;
        kahanStep(sum, mem.valueDouble(value));
    }
}

/// Source `sumInverse()`.
pub fn sumInverse(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const sum = sumContext(context, @sizeOf(SumContext)) orelse return;
    const value = argument(arguments, 0);
    const value_type = mem.valueNumericType(value);
    if (value_type == 5) return;
    sum.count -= 1;
    if (sum.approximate == 0) {
        const subtrahend = mem.valueInt64(value);
        const result = @subWithOverflow(sum.integer_sum, subtrahend);
        if (result[1] == 0) {
            sum.integer_sum = result[0];
            return;
        }
        sum.overflowed = 1;
        sum.approximate = 1;
        kahanInitialize(sum, sum.integer_sum);
    }
    if (value_type == 1) {
        const integer = mem.valueInt64(value);
        if (integer != std.math.minInt(i64)) {
            kahanStepInteger(sum, -integer);
        } else {
            kahanStepInteger(sum, std.math.maxInt(i64));
            kahanStepInteger(sum, 1);
        }
    } else {
        kahanStep(sum, -mem.valueDouble(value));
    }
}

/// Source `sumFinalize()`.
pub fn sumFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const sum = sumContext(context, 0) orelse return;
    if (sum.count <= 0) return;
    if (sum.approximate != 0) {
        if (sum.overflowed != 0) {
            mem.resultError(context, "integer overflow", -1);
        } else {
            mem.resultDouble(context, sum.real_sum + if (std.math.isFinite(sum.error_term)) sum.error_term else 0);
        }
    } else {
        mem.resultInt64(context, sum.integer_sum);
    }
}

/// Source `avgFinalize()`.
pub fn averageFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const sum = sumContext(context, 0) orelse return;
    if (sum.count <= 0) return;
    var result: f64 = if (sum.approximate != 0) sum.real_sum else @floatFromInt(sum.integer_sum);
    if (sum.approximate != 0 and std.math.isFinite(sum.error_term)) result += sum.error_term;
    mem.resultDouble(context, result / @as(f64, @floatFromInt(sum.count)));
}

/// Source `totalFinalize()`.
pub fn totalFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const sum = sumContext(context, 0);
    var result: f64 = 0;
    if (sum) |present| {
        result = if (present.approximate != 0) present.real_sum else @floatFromInt(present.integer_sum);
        if (present.approximate != 0 and std.math.isFinite(present.error_term)) result += present.error_term;
    }
    mem.resultDouble(context, result);
}

const UnaryMath = *const fn (f64) callconv(.c) f64;
const BinaryMath = *const fn (f64, f64) callconv(.c) f64;

/// Source `xCeil()`.
pub fn ceilingValue(value: f64) callconv(.c) f64 {
    return @ceil(value);
}

/// Source `xFloor()`.
pub fn floorValue(value: f64) callconv(.c) f64 {
    return @floor(value);
}

/// Active-profile C99 `trunc()` callback used by the source math registrar.
pub fn truncateValue(value: f64) callconv(.c) f64 {
    return @trunc(value);
}

pub fn exponentialValue(value: f64) callconv(.c) f64 {
    return @exp(value);
}

pub fn powerValue(base: f64, exponent: f64) callconv(.c) f64 {
    return std.math.pow(f64, base, exponent);
}
pub fn moduloValue(left: f64, right: f64) callconv(.c) f64 {
    return @rem(left, right);
}
pub fn squareRootValue(value: f64) callconv(.c) f64 {
    return @sqrt(value);
}
pub fn arcCosineValue(value: f64) callconv(.c) f64 {
    return std.math.acos(value);
}
pub fn arcSineValue(value: f64) callconv(.c) f64 {
    return std.math.asin(value);
}
pub fn arcTangentValue(value: f64) callconv(.c) f64 {
    return std.math.atan(value);
}
pub fn arcTangent2Value(left: f64, right: f64) callconv(.c) f64 {
    return std.math.atan2(left, right);
}
pub fn cosineValue(value: f64) callconv(.c) f64 {
    return @cos(value);
}
pub fn sineValue(value: f64) callconv(.c) f64 {
    return @sin(value);
}
pub fn tangentValue(value: f64) callconv(.c) f64 {
    return @tan(value);
}
pub fn hyperbolicCosineValue(value: f64) callconv(.c) f64 {
    return std.math.cosh(value);
}
pub fn hyperbolicSineValue(value: f64) callconv(.c) f64 {
    return std.math.sinh(value);
}
pub fn hyperbolicTangentValue(value: f64) callconv(.c) f64 {
    return std.math.tanh(value);
}
pub fn inverseHyperbolicCosineValue(value: f64) callconv(.c) f64 {
    return std.math.acosh(value);
}
pub fn inverseHyperbolicSineValue(value: f64) callconv(.c) f64 {
    return std.math.asinh(value);
}
pub fn inverseHyperbolicTangentValue(value: f64) callconv(.c) f64 {
    return std.math.atanh(value);
}

/// Source `ceilingFunc()`.
pub fn ceiling(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    switch (mem.valueNumericType(value)) {
        1 => mem.resultInt64(context, mem.valueInt64(value)),
        2 => {
            const operation: UnaryMath = @ptrCast(@alignCast(context.pFunc.?.pUserData.?));
            mem.resultDouble(context, operation(mem.valueDouble(value)));
        },
        else => {},
    }
}

/// Source `logFunc()`.
pub fn logarithm(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const first = argument(arguments, 0);
    const first_type = mem.valueNumericType(first);
    if (first_type != 1 and first_type != 2) return;
    var value = mem.valueDouble(first);
    if (value <= 0) return;
    var answer: f64 = undefined;
    if (argument_count == 2) {
        const denominator = @log(value);
        if (denominator <= 0) return;
        const second = argument(arguments, 1);
        const second_type = mem.valueNumericType(second);
        if (second_type != 1 and second_type != 2) return;
        value = mem.valueDouble(second);
        if (value <= 0) return;
        answer = @log(value) / denominator;
    } else {
        answer = switch (@intFromPtr(context.pFunc.?.pUserData)) {
            1 => @log10(value),
            2 => @log2(value),
            else => @log(value),
        };
    }
    mem.resultDouble(context, answer);
}

/// Source `degToRad()`.
pub fn degreesToRadians(value: f64) callconv(.c) f64 {
    return value * (std.math.pi / 180.0);
}

/// Source `radToDeg()`.
pub fn radiansToDegrees(value: f64) callconv(.c) f64 {
    return value * (180.0 / std.math.pi);
}

/// Source `math1Func()`.
pub fn unaryMath(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const value_type = mem.valueNumericType(value);
    if (value_type != 1 and value_type != 2) return;
    const operation: UnaryMath = @ptrCast(@alignCast(context.pFunc.?.pUserData.?));
    mem.resultDouble(context, operation(mem.valueDouble(value)));
}

/// Source `math2Func()`.
pub fn binaryMath(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const first = argument(arguments, 0);
    const second = argument(arguments, 1);
    const first_type = mem.valueNumericType(first);
    const second_type = mem.valueNumericType(second);
    if ((first_type != 1 and first_type != 2) or (second_type != 1 and second_type != 2)) return;
    const operation: BinaryMath = @ptrCast(@alignCast(context.pFunc.?.pUserData.?));
    mem.resultDouble(context, operation(mem.valueDouble(first), mem.valueDouble(second)));
}

/// Source `piFunc()`.
pub fn pi(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    mem.resultDouble(context_optional.?, std.math.pi);
}

const TrimCharacter = extern struct {
    pointer: [*]const u8,
    length: u32,
};

fn utf8CharacterLength(pointer: [*]const u8) u32 {
    var byte_count: u32 = 1;
    while (pointer[byte_count] & 0xc0 == 0x80) byte_count += 1;
    return byte_count;
}

/// Source `trimFunc()`.
pub fn trim(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const input_value = argument(arguments, 0);
    if (mem.valueType(input_value) == 5) return;
    var input = mem.valueText(input_value, 1) orelse return;
    var input_length: usize = @intCast(mem.valueBytes(input_value, 1));
    var default_characters = [_]TrimCharacter{.{ .pointer = " ", .length = 1 }};
    var trim_characters: []TrimCharacter = &default_characters;
    var allocated: ?[*]u8 = null;
    defer if (allocated) |block| db_allocator.free(context.pOut.?.db, block);

    if (argument_count == 2) {
        const character_text = mem.valueText(argument(arguments, 1), 1) orelse return;
        var character_count: usize = 0;
        var offset: usize = 0;
        while (character_text[offset] != 0) : (character_count += 1) offset += utf8CharacterLength(character_text + offset);
        if (character_count == 0) trim_characters = &.{} else {
            allocated = contextAllocate(context, @intCast(character_count * @sizeOf(TrimCharacter))) orelse return;
            const character_storage: [*]TrimCharacter = @ptrCast(@alignCast(allocated.?));
            trim_characters = character_storage[0..character_count];
            offset = 0;
            for (trim_characters) |*character| {
                character.pointer = character_text + offset;
                character.length = utf8CharacterLength(character.pointer);
                offset += character.length;
            }
        }
    }

    const flags = @intFromPtr(context.pFunc.?.pUserData);
    if (flags & 1 != 0) {
        while (input_length > 0) {
            const matched = for (trim_characters) |character| {
                if (character.length <= input_length and std.mem.eql(u8, input[0..character.length], character.pointer[0..character.length])) break character.length;
            } else break;
            input += matched;
            input_length -= matched;
        }
    }
    if (flags & 2 != 0) {
        while (input_length > 0) {
            const matched = for (trim_characters) |character| {
                if (character.length <= input_length and std.mem.eql(
                    u8,
                    input[input_length - character.length .. input_length],
                    character.pointer[0..character.length],
                )) break character.length;
            } else break;
            input_length -= matched;
        }
    }
    mem.resultText(context, input, @intCast(input_length), .transient);
}

/// Source `substrFunc()`.
pub fn substring(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const value_type = mem.valueType(value);
    var start = mem.valueInt64(argument(arguments, 1));
    var byte_length: c_int = 0;
    var data: [*]const u8 = undefined;
    if (value_type == 4) {
        byte_length = mem.valueBytes(value, 1);
        data = mem.valueBlob(value) orelse return;
    } else {
        data = mem.valueText(value, 1) orelse return;
        if (start < 0) {
            var scan: usize = 0;
            while (data[scan] != 0) : (byte_length += 1) scan += utf8CharacterLength(data + scan);
        }
    }
    var count: i64 = if (argument_count == 3)
        mem.valueInt64(argument(arguments, 2))
    else
        context.pOut.?.db.?.aLimit[0];
    if (argument_count == 3 and count == 0 and mem.valueType(argument(arguments, 2)) == 5) return;
    if (start == 0 and mem.valueType(argument(arguments, 1)) == 5) return;
    if (start < 0) {
        start += byte_length;
        if (start < 0) {
            if (count < 0) count = 0 else count += start;
            start = 0;
        }
    } else if (start > 0) {
        start -= 1;
    } else if (count > 0) {
        count -= 1;
    }
    if (count < 0) {
        count = if (count < -start) start else -count;
        start -= count;
    }

    if (value_type != 4) {
        var begin: usize = 0;
        var remaining_start = start;
        while (data[begin] != 0 and remaining_start > 0) : (remaining_start -= 1) {
            begin += utf8CharacterLength(data + begin);
        }
        var end = begin;
        var remaining_count = count;
        while (data[end] != 0 and remaining_count > 0) : (remaining_count -= 1) end += utf8CharacterLength(data + end);
        mem.resultText64(context, data + begin, end - begin, 1, .transient);
    } else {
        if (start >= byte_length) {
            start = 0;
            count = 0;
        } else if (count > byte_length - start) {
            count = byte_length - start;
        }
        mem.resultBlob64(context, data + @as(usize, @intCast(start)), @intCast(count), .transient);
    }
}

/// Source `replaceFunc()`.
pub fn replace(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const db = context.pOut.?.db.?;
    const source_value = argument(arguments, 0);
    const pattern_value = argument(arguments, 1);
    const replacement_value = argument(arguments, 2);
    const source = mem.valueText(source_value, 1) orelse return;
    const source_length: c_int = mem.valueBytes(source_value, 1);
    const pattern = mem.valueText(pattern_value, 1) orelse return;
    if (pattern[0] == 0) {
        mem.resultText(context, source, source_length, .transient);
        return;
    }
    const pattern_length: c_int = mem.valueBytes(pattern_value, 1);
    const replacement = mem.valueText(replacement_value, 1) orelse return;
    const replacement_length: c_int = mem.valueBytes(replacement_value, 1);
    var allocation_size: i64 = @as(i64, source_length) + 1;
    var output = contextAllocate(context, allocation_size) orelse return;
    var input_index: c_int = 0;
    var output_index: usize = 0;
    var expansion_count: u32 = 0;
    const final_match_start = source_length - pattern_length;
    while (input_index <= final_match_start) : (input_index += 1) {
        if (source[@intCast(input_index)] != pattern[0] or
            !std.mem.eql(u8, source[@intCast(input_index)..][0..@intCast(pattern_length)], pattern[0..@intCast(pattern_length)]))
        {
            output[output_index] = source[@intCast(input_index)];
            output_index += 1;
            continue;
        }
        if (replacement_length > pattern_length) {
            allocation_size += replacement_length - pattern_length;
            if (allocation_size - 1 > db.aLimit[0]) {
                mem.resultErrorTooBig(context);
                db_allocator.free(db, output);
                return;
            }
            expansion_count += 1;
            if (expansion_count & (expansion_count - 1) == 0) {
                const old_output = output;
                const growth_size: u64 = @intCast(allocation_size + (allocation_size - source_length - 1));
                output = if (db_allocator.realloc(db, old_output, growth_size)) |resized| @ptrCast(resized) else {
                    mem.resultErrorNoMem(context);
                    db_allocator.free(db, old_output);
                    return;
                };
            }
        }
        @memcpy(output[output_index..][0..@intCast(replacement_length)], replacement[0..@intCast(replacement_length)]);
        output_index += @intCast(replacement_length);
        input_index += pattern_length - 1;
    }
    const remaining: usize = @intCast(source_length - input_index);
    @memcpy(output[output_index..][0..remaining], source[@intCast(input_index)..][0..remaining]);
    output_index += remaining;
    output[output_index] = 0;
    mem.resultText(context, output, @intCast(output_index), .dynamic);
}

/// Source `concatFuncCore()`.
pub fn concatenateCore(
    context: *types.Context,
    argument_count: c_int,
    arguments: CallbackArguments,
    separator: []const u8,
) void {
    var maximum_length: i64 = @as(i64, @max(argument_count - 1, 0)) * @as(i64, @intCast(separator.len));
    for (0..@intCast(argument_count)) |index| {
        maximum_length += mem.valueBytes(argument(arguments, index), 1);
    }
    const result = contextAllocate(context, maximum_length + 1) orelse return;
    var written: usize = 0;
    var have_value = false;
    for (0..@intCast(argument_count)) |index| {
        const value = argument(arguments, index);
        if (mem.valueType(value) == 5) continue;
        const bytes = mem.valueText(value, 1) orelse continue;
        const byte_count: usize = @intCast(mem.valueBytes(value, 1));
        if (have_value and separator.len != 0) {
            @memcpy(result[written..][0..separator.len], separator);
            written += separator.len;
        }
        @memcpy(result[written..][0..byte_count], bytes[0..byte_count]);
        written += byte_count;
        have_value = true;
    }
    result[written] = 0;
    mem.resultText64(context, result, written, 16, .dynamic);
}

/// Source `concatFunc()`.
pub fn concatenate(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    concatenateCore(context_optional.?, argument_count, arguments, "");
}

/// Source `concatwsFunc()`.
pub fn concatenateWithSeparator(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const separator_value = argument(arguments, 0);
    const separator = mem.valueText(separator_value, 1) orelse return;
    const separator_length: usize = @intCast(mem.valueBytes(separator_value, 1));
    concatenateCore(context_optional.?, argument_count - 1, arguments.? + 1, separator[0..separator_length]);
}

/// Source `signFunc()`.
pub fn sign(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    const value_type = mem.valueNumericType(value);
    if (value_type != 1 and value_type != 2) return;
    const real = mem.valueDouble(value);
    mem.resultInt(context, if (real < 0) -1 else if (real > 0) 1 else 0);
}

/// Source `zeroblobFunc()`.
pub fn zeroBlob(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const blob_length: u64 = @intCast(@max(mem.valueInt64(argument(arguments, 0)), 0));
    const result = mem.resultZeroBlob64(context, blob_length);
    if (result != 0) mem.resultErrorCode(context, result);
}

fn minMaxAccumulator(context: *types.Context) ?*types.Mem {
    const raw = mem.aggregateContext(context, @sizeOf(types.Mem)) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Source `minmaxStep()`.
pub fn minMaxStep(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const candidate = argument(arguments, 0);
    const best = minMaxAccumulator(context) orelse return;
    if (mem.valueType(candidate) == 5) {
        if (best.flags != 0) skipAccumulatorLoad(context);
    } else if (best.flags != 0) {
        const maximum = context.pFunc.?.pUserData != null;
        const comparison = mem.compare(best, candidate, functionCollation(context));
        if ((maximum and comparison < 0) or (!maximum and comparison > 0)) {
            _ = mem.copy(best, candidate);
        } else {
            skipAccumulatorLoad(context);
        }
    } else {
        best.db = context.pOut.?.db;
        _ = mem.copy(best, candidate);
    }
}

/// Source `minMaxValueFinalize()`.
pub fn minMaxValueFinalize(context: *types.Context, value_only: bool) void {
    const raw = mem.aggregateContext(context, 0) orelse return;
    const result: *types.Mem = @ptrCast(@alignCast(raw));
    if (result.flags != 0) mem.resultValue(context, result);
    if (!value_only) mem.release(result);
}

/// Source `minMaxValue()`.
pub fn minMaxValue(context_optional: CallbackContext) callconv(.c) void {
    minMaxValueFinalize(context_optional.?, true);
}

/// Source `minMaxFinalize()`.
pub fn minMaxFinalize(context_optional: CallbackContext) callconv(.c) void {
    minMaxValueFinalize(context_optional.?, false);
}

pub const GroupConcatContext = extern struct {
    text: ?[*]u8,
    length: usize,
    capacity: usize,
    count: c_int,
    first_separator_length: c_int,
    separator_lengths: ?[*]c_int,
};

fn groupConcatContext(context: *types.Context, size: c_int) ?*GroupConcatContext {
    const raw = mem.aggregateContext(context, size) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn groupConcatEnsure(context: *types.Context, group: *GroupConcatContext, additional: usize) bool {
    const required = group.length + additional + 1;
    if (required <= group.capacity) return true;
    const limit: usize = @intCast(context.pOut.?.db.?.aLimit[0]);
    if (required > limit) {
        mem.resultErrorTooBig(context);
        return false;
    }
    var capacity = @max(group.capacity, 32);
    while (capacity < required) {
        capacity = @min(limit, capacity * 2);
    }
    const raw = db_allocator.realloc(context.pOut.?.db.?, if (group.text) |text| @ptrCast(text) else null, capacity) orelse {
        mem.resultErrorNoMem(context);
        return false;
    };
    group.text = @ptrCast(raw);
    group.capacity = capacity;
    return true;
}

fn groupConcatAppend(context: *types.Context, group: *GroupConcatContext, text: []const u8) bool {
    if (!groupConcatEnsure(context, group, text.len)) return false;
    @memcpy(group.text.?[group.length..][0..text.len], text);
    group.length += text.len;
    group.text.?[group.length] = 0;
    return true;
}

/// Source `groupConcatStep()`.
pub fn groupConcatStep(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    if (mem.valueType(value) == 5) return;
    const group = groupConcatContext(context, @sizeOf(GroupConcatContext)) orelse return;
    const first = group.count == 0;
    var separator_length: c_int = 0;
    if (argument_count == 1) {
        separator_length = 1;
        if (!first and !groupConcatAppend(context, group, ",")) return;
        if (first) group.first_separator_length = 1;
    } else {
        const separator_value = argument(arguments, 1);
        if (mem.valueText(separator_value, 1)) |separator| {
            separator_length = mem.valueBytes(separator_value, 1);
            if (!first and !groupConcatAppend(context, group, separator[0..@intCast(separator_length)])) return;
        }
        if (first) {
            group.first_separator_length = separator_length;
        } else if (separator_length != group.first_separator_length or group.separator_lengths != null) {
            const old_lengths = group.separator_lengths;
            const count: usize = @intCast(group.count);
            const raw = db_allocator.realloc(context.pOut.?.db.?, if (old_lengths) |lengths| @ptrCast(lengths) else null, (count + 1) * @sizeOf(c_int)) orelse {
                mem.resultErrorNoMem(context);
                return;
            };
            group.separator_lengths = @ptrCast(@alignCast(raw));
            if (old_lengths == null) {
                for (group.separator_lengths.?[0 .. count - 1]) |*separator_entry| separator_entry.* = group.first_separator_length;
            }
            group.separator_lengths.?[count - 1] = separator_length;
        }
    }
    group.count += 1;
    const text = mem.valueText(value, 1) orelse return;
    _ = groupConcatAppend(context, group, text[0..@intCast(mem.valueBytes(value, 1))]);
}

/// Source `groupConcatInverse()`.
pub fn groupConcatInverse(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const value = argument(arguments, 0);
    if (mem.valueType(value) == 5) return;
    const group = groupConcatContext(context, @sizeOf(GroupConcatContext)) orelse return;
    _ = mem.valueText(value, 1);
    var remove: usize = @intCast(mem.valueBytes(value, 1));
    group.count -= 1;
    if (group.separator_lengths) |lengths| {
        if (group.count > 0) {
            remove += @intCast(lengths[0]);
            std.mem.copyForwards(c_int, lengths[0..@intCast(group.count - 1)], lengths[1..@intCast(group.count)]);
        }
    } else remove += @intCast(group.first_separator_length);
    if (remove >= group.length) {
        group.length = 0;
    } else {
        group.length -= remove;
        std.mem.copyForwards(u8, group.text.?[0..group.length], group.text.?[remove .. remove + group.length]);
    }
    if (group.length == 0) {
        db_allocator.free(context.pOut.?.db, if (group.separator_lengths) |lengths| @ptrCast(lengths) else null);
        group.separator_lengths = null;
        group.capacity = 0;
    }
}

/// Source `groupConcatFinalize()`.
pub fn groupConcatFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const group = groupConcatContext(context, 0) orelse return;
    if (group.text) |text| {
        mem.resultText64(context, text, group.length, 16, .dynamic);
        group.text = null;
    }
    db_allocator.free(context.pOut.?.db, if (group.separator_lengths) |lengths| @ptrCast(lengths) else null);
    group.separator_lengths = null;
}

/// Source `groupConcatValue()`.
pub fn groupConcatValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const group = groupConcatContext(context, 0) orelse return;
    if (group.count > 0 and group.length == 0) {
        mem.resultText(context, "", 1, .static);
    } else if (group.text) |text| {
        mem.resultText(context, text, @intCast(group.length), .transient);
    }
}

pub const PercentileContext = extern struct {
    allocated: u64,
    used: u64,
    sorted: u8,
    keep_sorted: u8,
    fraction_valid: u8,
    _padding: [5]u8 = .{0} ** 5,
    fraction: f64,
    values: ?[*]f64,
};

/// Source `percentIsInfinity()`.
pub fn percentileIsInfinity(value: f64) bool {
    const bits: u64 = @bitCast(value);
    return bits >> 52 & 0x7ff == 0x7ff;
}

/// Source `percentSameValue()`.
pub fn percentileSameValue(first: f64, second: f64) bool {
    const difference = first - second;
    return difference >= -0.001 and difference <= 0.001;
}

/// Source `percentBinarySearch()`.
pub fn percentileBinarySearch(percentile: *const PercentileContext, value: f64, exact: bool) i64 {
    var first: i64 = 0;
    var last: i64 = @as(i64, @intCast(percentile.used)) - 1;
    while (last >= first) {
        const middle = @divTrunc(first + last, 2);
        const found = percentile.values.?[@intCast(middle)];
        if (found < value) first = middle + 1 else if (found > value) last = middle - 1 else return middle;
    }
    return if (exact) -1 else first;
}

const PercentileError = enum { fraction_range, fraction_changed, non_numeric, infinite };

/// Typed source `percentError()` formatter.
pub fn percentileError(context: *types.Context, kind: PercentileError, maximum: f64) void {
    const name = context.pFunc.?.zName.?;
    var buffer: [256]u8 = undefined;
    const message = switch (kind) {
        .fraction_range => if (maximum == 100)
            std.fmt.bufPrint(&buffer, "the fraction argument to {s}() is not between 0.0 and 100.0", .{name}) catch unreachable
        else
            std.fmt.bufPrint(&buffer, "the fraction argument to {s}() is not between 0.0 and 1.0", .{name}) catch unreachable,
        .fraction_changed => std.fmt.bufPrint(&buffer, "the fraction argument to {s}() is not the same for all input rows", .{name}) catch unreachable,
        .non_numeric => std.fmt.bufPrint(&buffer, "input to {s}() is not numeric", .{name}) catch unreachable,
        .infinite => std.fmt.bufPrint(&buffer, "Inf input to {s}()", .{name}) catch unreachable,
    };
    mem.resultError(context, message.ptr, @intCast(message.len));
}

fn percentileContext(context: *types.Context, size: c_int) ?*PercentileContext {
    const raw = mem.aggregateContext(context, size) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Source `percentStep()`.
pub fn percentileStep(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    var fraction: f64 = 0.5;
    if (argument_count == 2) {
        const maximum: f64 = if (@intFromPtr(context.pFunc.?.pUserData) & 2 != 0) 100 else 1;
        const fraction_value = argument(arguments, 1);
        const fraction_type = mem.valueNumericType(fraction_value);
        fraction = mem.valueDouble(fraction_value) / maximum;
        if ((fraction_type != 1 and fraction_type != 2) or fraction < 0 or fraction > 1) {
            percentileError(context, .fraction_range, maximum);
            return;
        }
    }
    const percentile = percentileContext(context, @sizeOf(PercentileContext)) orelse return;
    if (percentile.fraction_valid == 0) {
        percentile.fraction = fraction;
        percentile.fraction_valid = 1;
    } else if (!percentileSameValue(percentile.fraction, fraction)) {
        percentileError(context, .fraction_changed, 0);
        return;
    }
    const input = argument(arguments, 0);
    const input_type = mem.valueType(input);
    if (input_type == 5) return;
    if (input_type != 1 and input_type != 2) {
        percentileError(context, .non_numeric, 0);
        return;
    }
    const value = mem.valueDouble(input);
    if (percentileIsInfinity(value)) {
        percentileError(context, .infinite, 0);
        return;
    }
    if (percentile.used >= percentile.allocated) {
        const new_count = percentile.allocated * 2 + 250;
        const bytes = new_count * @sizeOf(f64);
        const raw = db_allocator.realloc(context.pOut.?.db.?, if (percentile.values) |values| @ptrCast(values) else null, bytes) orelse {
            db_allocator.free(context.pOut.?.db, if (percentile.values) |values| @ptrCast(values) else null);
            percentile.* = std.mem.zeroes(PercentileContext);
            mem.resultErrorNoMem(context);
            return;
        };
        percentile.values = @ptrCast(@alignCast(raw));
        percentile.allocated = new_count;
    }
    const values = percentile.values.?;
    if (percentile.used == 0) {
        values[0] = value;
        percentile.used = 1;
        percentile.sorted = 1;
    } else if (percentile.sorted == 0 or value >= values[@intCast(percentile.used - 1)]) {
        values[@intCast(percentile.used)] = value;
        percentile.used += 1;
    } else if (percentile.keep_sorted != 0) {
        const insertion: usize = @intCast(percentileBinarySearch(percentile, value, false));
        if (insertion < percentile.used) std.mem.copyBackwards(
            f64,
            values[insertion + 1 .. @intCast(percentile.used + 1)],
            values[insertion..@intCast(percentile.used)],
        );
        values[insertion] = value;
        percentile.used += 1;
    } else {
        values[@intCast(percentile.used)] = value;
        percentile.used += 1;
        percentile.sorted = 0;
    }
}

/// Source `percentSort()`.
pub fn percentileSort(values_initial: [*]f64, count_initial: u32) void {
    var values = values_initial;
    var count = count_initial;
    while (count >= 2) {
        if (values[0] > values[count - 1]) std.mem.swap(f64, &values[0], &values[count - 1]);
        if (count == 2) return;
        var greater: u32 = count - 1;
        var index: u32 = count / 2;
        if (values[0] > values[index]) {
            std.mem.swap(f64, &values[0], &values[index]);
        } else if (values[index] > values[greater]) {
            std.mem.swap(f64, &values[index], &values[greater]);
        }
        if (count == 3) return;
        const pivot = values[index];
        var less: u32 = 1;
        index = 1;
        while (index < greater) {
            if (values[index] < pivot) {
                if (index > less) std.mem.swap(f64, &values[index], &values[less]);
                less += 1;
                index += 1;
            } else if (values[index] > pivot) {
                greater -= 1;
                while (greater > index and values[greater] > pivot) greater -= 1;
                std.mem.swap(f64, &values[index], &values[greater]);
            } else index += 1;
        }
        if (less > count / 2) {
            if (count - greater >= 2) percentileSort(values + greater, count - greater);
            count = less;
        } else {
            if (less >= 2) percentileSort(values, less);
            values += greater;
            count -= greater;
        }
    }
}

/// Source `percentInverse()`.
pub fn percentileInverse(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const percentile = percentileContext(context, @sizeOf(PercentileContext)) orelse return;
    const input = argument(arguments, 0);
    const input_type = mem.valueType(input);
    if (input_type == 5 or (input_type != 1 and input_type != 2)) return;
    const value = mem.valueDouble(input);
    if (percentileIsInfinity(value)) return;
    if (percentile.sorted == 0) {
        percentileSort(percentile.values.?, @intCast(percentile.used));
        percentile.sorted = 1;
    }
    percentile.keep_sorted = 1;
    const found = percentileBinarySearch(percentile, value, true);
    if (found >= 0) {
        percentile.used -= 1;
        const index: usize = @intCast(found);
        if (index < percentile.used) std.mem.copyForwards(
            f64,
            percentile.values.?[index..@intCast(percentile.used)],
            percentile.values.?[index + 1 .. @intCast(percentile.used + 1)],
        );
    }
}

/// Source `percentCompute()`.
pub fn percentileCompute(context: *types.Context, final: bool) void {
    const percentile = percentileContext(context, 0) orelse return;
    const values = percentile.values orelse return;
    if (percentile.used != 0) {
        if (percentile.sorted == 0) {
            percentileSort(values, @intCast(percentile.used));
            percentile.sorted = 1;
        }
        const position = percentile.fraction * @as(f64, @floatFromInt(percentile.used - 1));
        const lower_index: usize = @intFromFloat(position);
        const result = if (@intFromPtr(context.pFunc.?.pUserData) & 1 != 0)
            values[lower_index]
        else blk: {
            const upper_index = if (position == @as(f64, @floatFromInt(lower_index)) or lower_index == percentile.used - 1) lower_index else lower_index + 1;
            break :blk values[lower_index] + (values[upper_index] - values[lower_index]) * (position - @as(f64, @floatFromInt(lower_index)));
        };
        mem.resultDouble(context, result);
    }
    if (final) {
        db_allocator.free(context.pOut.?.db, @ptrCast(values));
        percentile.* = std.mem.zeroes(PercentileContext);
    } else percentile.keep_sorted = 1;
}

/// Source `percentFinal()`.
pub fn percentileFinal(context_optional: CallbackContext) callconv(.c) void {
    percentileCompute(context_optional.?, true);
}

/// Source `percentValue()`.
pub fn percentileValue(context_optional: CallbackContext) callconv(.c) void {
    percentileCompute(context_optional.?, false);
}

const CountContext = extern struct { count: i64, inverse_called: c_int };

fn countContext(context: *types.Context) ?*CountContext {
    const raw = mem.aggregateContext(context, @sizeOf(CountContext)) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Source `countStep()`.
pub fn countStep(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const count = countContext(context) orelse return;
    if (argument_count == 0 or mem.valueType(argument(arguments, 0)) != 5) count.count += 1;
}

/// Source `countFinalize()`.
pub fn countFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const raw = mem.aggregateContext(context, 0);
    const result: i64 = if (raw) |pointer| @as(*CountContext, @ptrCast(@alignCast(pointer))).count else 0;
    mem.resultInt64(context, result);
}

/// Source `countInverse()`.
pub fn countInverse(context_optional: CallbackContext, argument_count: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const count = countContext(context) orelse return;
    if (argument_count == 0 or mem.valueType(argument(arguments, 0)) != 5) {
        count.count -= 1;
        count.inverse_called = 1;
    }
}
