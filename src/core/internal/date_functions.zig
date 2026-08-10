//! SQL date/time function callbacks from `date.c`.

const std = @import("std");
const formatter = @import("../formatter.zig");
const memory = @import("../memory.zig");
const date = @import("date_time.zig");
const modifiers = @import("date_modifiers.zig");
const mem = @import("vdbe_mem.zig");
const types = @import("vdbe_types.zig");

fn argument(arguments: ?[*]?*types.Mem, index: usize) *types.Mem {
    return arguments.?[index].?;
}

/// Source `isDate()`.
pub fn parseArguments(context: *types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem, output: *date.DateTime) bool {
    output.* = .{};
    if (argument_count == 0) return date.setToCurrent(context, output);
    const first = argument(arguments, 0);
    const first_type = mem.valueType(first);
    if (first_type == 1 or first_type == 2) {
        date.setRawDateNumber(output, mem.valueDouble(first));
    } else {
        const text = mem.valueText(first, 1) orelse return true;
        if (date.parseDateOrTime(context, @ptrCast(text), output)) return true;
    }
    for (1..@intCast(argument_count)) |index| {
        const modifier_value = argument(arguments, index);
        const text = mem.valueText(modifier_value, 1) orelse return true;
        if (modifiers.parseModifier(context, @ptrCast(text), mem.valueBytes(modifier_value, 1), output, @intCast(index)) != 0) return true;
    }
    date.computeJulianDay(output);
    if (output.error_state or !date.validJulianDay(output.julian_milliseconds)) return true;
    if (argument_count == 1 and output.valid_ymd and output.day > 28) output.valid_ymd = false;
    return false;
}

/// Source `juliandayFunc()`.
pub fn julianDay(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    var value: date.DateTime = undefined;
    if (!parseArguments(context, argument_count, arguments, &value)) mem.resultDouble(context, @as(f64, @floatFromInt(value.julian_milliseconds)) / 86_400_000);
}

/// Source `unixepochFunc()`.
pub fn unixEpoch(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    var value: date.DateTime = undefined;
    if (!parseArguments(context, argument_count, arguments, &value)) {
        if (value.use_subseconds) mem.resultDouble(context, @as(f64, @floatFromInt(value.julian_milliseconds - 210_866_760_000_000)) / 1000) else mem.resultInt64(context, @divTrunc(value.julian_milliseconds, 1000) - 210_866_760_000);
    }
}

fn putTwo(buffer: []u8, offset: usize, value: c_int) void {
    buffer[offset] = @intCast('0' + @rem(@divTrunc(value, 10), 10));
    buffer[offset + 1] = @intCast('0' + @rem(value, 10));
}
fn putYear(buffer: []u8, offset: usize, year: c_int) void {
    buffer[offset] = @intCast('0' + @rem(@divTrunc(year, 1000), 10));
    buffer[offset + 1] = @intCast('0' + @rem(@divTrunc(year, 100), 10));
    buffer[offset + 2] = @intCast('0' + @rem(@divTrunc(year, 10), 10));
    buffer[offset + 3] = @intCast('0' + @rem(year, 10));
}

/// Source `datetimeFunc()`.
pub fn dateTime(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    var value: date.DateTime = undefined;
    if (parseArguments(context, argument_count, arguments, &value)) return;
    date.computeCalendarAndClock(&value);
    var buffer: [32]u8 = undefined;
    const year = if (value.year < 0) -value.year else value.year;
    putYear(&buffer, 1, year);
    buffer[5] = '-';
    putTwo(&buffer, 6, value.month);
    buffer[8] = '-';
    putTwo(&buffer, 9, value.day);
    buffer[11] = ' ';
    putTwo(&buffer, 12, value.hour);
    buffer[14] = ':';
    putTwo(&buffer, 15, value.minute);
    buffer[17] = ':';
    var length: c_int = undefined;
    if (value.use_subseconds) {
        const seconds: c_int = @intFromFloat(1000 * value.seconds + 0.5);
        putTwo(&buffer, 18, @divTrunc(seconds, 1000));
        buffer[20] = '.';
        buffer[21] = @intCast('0' + @rem(@divTrunc(seconds, 100), 10));
        buffer[22] = @intCast('0' + @rem(@divTrunc(seconds, 10), 10));
        buffer[23] = @intCast('0' + @rem(seconds, 10));
        length = 24;
    } else {
        putTwo(&buffer, 18, @intFromFloat(value.seconds));
        length = 20;
    }
    if (value.year < 0) {
        buffer[0] = '-';
        mem.resultText(context, &buffer, length, .transient);
    } else mem.resultText(context, buffer[1..].ptr, length - 1, .transient);
}

/// Source `timeFunc()`.
pub fn time(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    var value: date.DateTime = undefined;
    if (parseArguments(context, argument_count, arguments, &value)) return;
    date.computeHourMinuteSecond(&value);
    var buffer: [16]u8 = undefined;
    putTwo(&buffer, 0, value.hour);
    buffer[2] = ':';
    putTwo(&buffer, 3, value.minute);
    buffer[5] = ':';
    var length: c_int = undefined;
    if (value.use_subseconds) {
        const seconds: c_int = @intFromFloat(1000 * value.seconds + 0.5);
        putTwo(&buffer, 6, @divTrunc(seconds, 1000));
        buffer[8] = '.';
        buffer[9] = @intCast('0' + @rem(@divTrunc(seconds, 100), 10));
        buffer[10] = @intCast('0' + @rem(@divTrunc(seconds, 10), 10));
        buffer[11] = @intCast('0' + @rem(seconds, 10));
        length = 12;
    } else {
        putTwo(&buffer, 6, @intFromFloat(value.seconds));
        length = 8;
    }
    mem.resultText(context, &buffer, length, .transient);
}

/// Source `dateFunc()`.
pub fn calendarDate(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    var value: date.DateTime = undefined;
    if (parseArguments(context, argument_count, arguments, &value)) return;
    date.computeYearMonthDay(&value);
    var buffer: [16]u8 = undefined;
    const year = if (value.year < 0) -value.year else value.year;
    putYear(&buffer, 1, year);
    buffer[5] = '-';
    putTwo(&buffer, 6, value.month);
    buffer[8] = '-';
    putTwo(&buffer, 9, value.day);
    if (value.year < 0) {
        buffer[0] = '-';
        mem.resultText(context, &buffer, 11, .transient);
    } else mem.resultText(context, buffer[1..].ptr, 10, .transient);
}

fn appendFormat(accumulator: *formatter.Accumulator, pattern: []const u8, arguments: []const formatter.FormatArgument) void {
    formatter.strAppendFormat(accumulator, memory.processManager(), pattern, arguments);
}

/// Source `timediffFunc()`.
pub fn timeDifference(context_optional: ?*types.Context, _: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    const context = context_optional.?;
    var first: date.DateTime = undefined;
    var second: date.DateTime = undefined;
    if (parseArguments(context, 1, arguments, &first) or parseArguments(context, 1, arguments.? + 1, &second)) return;
    date.computeCalendarAndClock(&first);
    date.computeCalendarAndClock(&second);
    var sign: u8 = undefined;
    var years: c_int = undefined;
    var months: c_int = undefined;
    if (first.julian_milliseconds >= second.julian_milliseconds) {
        sign = '+';
        years = first.year - second.year;
        if (years != 0) {
            second.year = first.year;
            second.valid_julian = false;
            date.computeJulianDay(&second);
        }
        months = first.month - second.month;
        if (months < 0) {
            years -= 1;
            months += 12;
        }
        if (months != 0) {
            second.month = first.month;
            second.valid_julian = false;
            date.computeJulianDay(&second);
        }
        while (first.julian_milliseconds < second.julian_milliseconds) {
            months -= 1;
            if (months < 0) {
                months = 11;
                years -= 1;
            }
            second.month -= 1;
            if (second.month < 1) {
                second.month = 12;
                second.year -= 1;
            }
            second.valid_julian = false;
            date.computeJulianDay(&second);
        }
        first.julian_milliseconds = first.julian_milliseconds - second.julian_milliseconds + 148_699_540_800_000;
    } else {
        sign = '-';
        years = second.year - first.year;
        if (years != 0) {
            second.year = first.year;
            second.valid_julian = false;
            date.computeJulianDay(&second);
        }
        months = second.month - first.month;
        if (months < 0) {
            years -= 1;
            months += 12;
        }
        if (months != 0) {
            second.month = first.month;
            second.valid_julian = false;
            date.computeJulianDay(&second);
        }
        while (first.julian_milliseconds > second.julian_milliseconds) {
            months -= 1;
            if (months < 0) {
                months = 11;
                years -= 1;
            }
            second.month += 1;
            if (second.month > 12) {
                second.month = 1;
                second.year += 1;
            }
            second.valid_julian = false;
            date.computeJulianDay(&second);
        }
        first.julian_milliseconds = second.julian_milliseconds - first.julian_milliseconds + 148_699_540_800_000;
    }
    date.clearCalendarClockTimezone(&first);
    date.computeCalendarAndClock(&first);
    var accumulator: formatter.Accumulator = undefined;
    formatter.strAccumInit(&accumulator, null, null, 0, 100);
    appendFormat(&accumulator, "%c%04d-%02d-%02d %02d:%02d:%06.3f", &.{
        .{ .character = sign },    .{ .signed = years },        .{ .signed = months },       .{ .signed = first.day - 1 },
        .{ .signed = first.hour }, .{ .signed = first.minute }, .{ .float = first.seconds },
    });
    if (accumulator.accError != 0) mem.resultErrorCode(context, accumulator.accError) else if (formatter.isMalloced(&accumulator)) mem.resultText(context, accumulator.zText, @intCast(accumulator.nChar), .dynamic) else mem.resultText(context, "", 0, .static);
}

/// Source `strftimeFunc()`.
pub fn strftime(context_optional: ?*types.Context, argument_count: c_int, arguments: ?[*]?*types.Mem) callconv(.c) void {
    if (argument_count == 0) return;
    const context = context_optional.?;
    const format_pointer = mem.valueText(argument(arguments, 0), 1) orelse return;
    const format = std.mem.span(@as([*:0]const u8, @ptrCast(format_pointer)));
    var value: date.DateTime = undefined;
    if (parseArguments(context, argument_count - 1, arguments.? + 1, &value)) return;
    date.computeJulianDay(&value);
    date.computeCalendarAndClock(&value);
    var accumulator: formatter.Accumulator = undefined;
    const output_limit: u32 = if (context.pOut) |output| if (output.db) |database| @intCast(@max(database.aLimit[0], 0)) else 1_000_000_000 else 1_000_000_000;
    formatter.strAccumInit(&accumulator, null, null, 0, output_limit);
    var literal_start: usize = 0;
    var index: usize = 0;
    while (index < format.len) : (index += 1) {
        if (format[index] != '%') continue;
        if (literal_start < index) formatter.strAppend(&accumulator, memory.processManager(), format[literal_start..index]);
        index += 1;
        if (index >= format.len) {
            formatter.strReset(&accumulator, memory.processManager());
            return;
        }
        const conversion = format[index];
        literal_start = index + 1;
        switch (conversion) {
            'd', 'e' => appendFormat(&accumulator, if (conversion == 'd') "%02d" else "%2d", &.{.{ .signed = value.day }}),
            'f' => appendFormat(&accumulator, "%06.3f", &.{.{ .float = @min(value.seconds, 59.999) }}),
            'F' => appendFormat(&accumulator, "%04d-%02d-%02d", &.{ .{ .signed = value.year }, .{ .signed = value.month }, .{ .signed = value.day } }),
            'G', 'g' => {
                var thursday = value;
                thursday.julian_milliseconds += @as(i64, 3 - date.daysAfterMonday(&value)) * 86_400_000;
                thursday.valid_ymd = false;
                date.computeYearMonthDay(&thursday);
                appendFormat(&accumulator, if (conversion == 'g') "%02d" else "%04d", &.{.{ .signed = if (conversion == 'g') @rem(thursday.year, 100) else thursday.year }});
            },
            'H', 'k' => appendFormat(&accumulator, if (conversion == 'H') "%02d" else "%2d", &.{.{ .signed = value.hour }}),
            'I', 'l' => {
                var hour = value.hour;
                if (hour > 12) hour -= 12;
                if (hour == 0) hour = 12;
                appendFormat(&accumulator, if (conversion == 'I') "%02d" else "%2d", &.{.{ .signed = hour }});
            },
            'j' => appendFormat(&accumulator, "%03d", &.{.{ .signed = date.daysAfterJanuaryFirst(&value) + 1 }}),
            'J' => appendFormat(&accumulator, "%.16g", &.{.{ .float = @as(f64, @floatFromInt(value.julian_milliseconds)) / 86_400_000 }}),
            'm' => appendFormat(&accumulator, "%02d", &.{.{ .signed = value.month }}),
            'M' => appendFormat(&accumulator, "%02d", &.{.{ .signed = value.minute }}),
            'p', 'P' => formatter.strAppend(&accumulator, memory.processManager(), if (value.hour >= 12) (if (conversion == 'p') "PM" else "pm") else (if (conversion == 'p') "AM" else "am")),
            'R' => appendFormat(&accumulator, "%02d:%02d", &.{ .{ .signed = value.hour }, .{ .signed = value.minute } }),
            's' => if (value.use_subseconds)
                appendFormat(&accumulator, "%.3f", &.{.{ .float = @as(f64, @floatFromInt(value.julian_milliseconds - 210_866_760_000_000)) / 1000 }})
            else
                appendFormat(&accumulator, "%lld", &.{.{ .signed = @divTrunc(value.julian_milliseconds, 1000) - 210_866_760_000 }}),
            'S' => appendFormat(&accumulator, "%02d", &.{.{ .signed = @as(i64, @intFromFloat(value.seconds)) }}),
            'T' => appendFormat(&accumulator, "%02d:%02d:%02d", &.{ .{ .signed = value.hour }, .{ .signed = value.minute }, .{ .signed = @as(i64, @intFromFloat(value.seconds)) } }),
            'u', 'w' => {
                var weekday: u8 = @intCast(date.daysAfterSunday(&value));
                if (weekday == 0 and conversion == 'u') weekday = 7;
                formatter.strAppendChar(&accumulator, memory.processManager(), 1, '0' + weekday);
            },
            'U' => appendFormat(&accumulator, "%02d", &.{.{ .signed = @divTrunc(date.daysAfterJanuaryFirst(&value) - date.daysAfterSunday(&value) + 7, 7) }}),
            'V' => {
                var thursday = value;
                thursday.julian_milliseconds += @as(i64, 3 - date.daysAfterMonday(&value)) * 86_400_000;
                thursday.valid_ymd = false;
                date.computeYearMonthDay(&thursday);
                appendFormat(&accumulator, "%02d", &.{.{ .signed = @divTrunc(date.daysAfterJanuaryFirst(&thursday), 7) + 1 }});
            },
            'W' => appendFormat(&accumulator, "%02d", &.{.{ .signed = @divTrunc(date.daysAfterJanuaryFirst(&value) - date.daysAfterMonday(&value) + 7, 7) }}),
            'Y' => appendFormat(&accumulator, "%04d", &.{.{ .signed = value.year }}),
            '%' => formatter.strAppendChar(&accumulator, memory.processManager(), 1, '%'),
            else => {
                formatter.strReset(&accumulator, memory.processManager());
                return;
            },
        }
    }
    if (literal_start < format.len) formatter.strAppend(&accumulator, memory.processManager(), format[literal_start..]);
    if (accumulator.accError != 0) {
        mem.resultErrorCode(context, accumulator.accError);
        formatter.strReset(&accumulator, memory.processManager());
    } else if (formatter.isMalloced(&accumulator)) {
        mem.resultText(context, accumulator.zText, @intCast(accumulator.nChar), .dynamic);
    } else mem.resultText(context, "", 0, .static);
}

/// Source `ctimeFunc()`.
pub fn currentTime(context: ?*types.Context, _: c_int, _: ?[*]?*types.Mem) callconv(.c) void {
    time(context, 0, null);
}
/// Source `cdateFunc()`.
pub fn currentDate(context: ?*types.Context, _: c_int, _: ?[*]?*types.Mem) callconv(.c) void {
    calendarDate(context, 0, null);
}
/// Source `ctimestampFunc()`.
pub fn currentTimestamp(context: ?*types.Context, _: c_int, _: ?[*]?*types.Mem) callconv(.c) void {
    dateTime(context, 0, null);
}
