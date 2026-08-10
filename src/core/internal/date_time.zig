//! Julian-day and calendar transformations from `date.c`.

const std = @import("std");
const sqlite_float = @import("../float.zig");
const sqlite_string = @import("../string.zig");
const vfs = @import("../vfs.zig");
const mem = @import("vdbe_mem.zig");
const types = @import("vdbe_types.zig");

pub const CalendarTime = extern struct {
    second: c_int,
    minute: c_int,
    hour: c_int,
    month_day: c_int,
    month: c_int,
    year: c_int,
    week_day: c_int,
    year_day: c_int,
    daylight: c_int,
    gmt_offset: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(*const c_long, *CalendarTime) ?*CalendarTime;

pub const DateTime = struct {
    julian_milliseconds: i64 = 0,
    year: c_int = 0,
    month: c_int = 0,
    day: c_int = 0,
    hour: c_int = 0,
    minute: c_int = 0,
    timezone_minutes: c_int = 0,
    seconds: f64 = 0,
    valid_julian: bool = false,
    valid_ymd: bool = false,
    valid_hms: bool = false,
    floor_days: c_int = 0,
    raw_seconds: bool = false,
    error_state: bool = false,
    use_subseconds: bool = false,
    utc: bool = false,
    local: bool = false,
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or (byte >= 9 and byte <= 13);
}
/// Typed source `getDigits()` varargs translation.
pub fn getDigits(date_initial: [*]const u8, format_initial: [*:0]const u8, outputs: []const *c_int) c_int {
    const maximums = [_]u16{ 12, 14, 24, 31, 59, 14712 };
    var date = date_initial;
    var format = format_initial;
    var converted: c_int = 0;
    while (converted < outputs.len) {
        var digits: u8 = format[0] - '0';
        const minimum: c_int = format[1] - '0';
        const maximum = maximums[format[2] - 'a'];
        const separator = format[3];
        var result: c_int = 0;
        while (digits > 0) : (digits -= 1) {
            if (date[0] < '0' or date[0] > '9') return converted;
            result = result * 10 + date[0] - '0';
            date += 1;
        }
        if (result < minimum or result > maximum or (separator != 0 and separator != date[0])) return converted;
        outputs[@intCast(converted)].* = result;
        date += 1;
        converted += 1;
        format += 4;
        if (separator == 0) break;
    }
    return converted;
}

/// Source `parseTimezone()`.
pub fn parseTimezone(text_initial: [*:0]const u8, value: *DateTime) bool {
    var text: [*:0]const u8 = text_initial;
    while (isSpace(text[0])) {
        text += 1;
    }
    value.timezone_minutes = 0;
    const sign: c_int = if (text[0] == '-') -1 else if (text[0] == '+') 1 else if (text[0] == 'Z' or text[0] == 'z') zulu: {
        text += 1;
        value.local = false;
        value.utc = true;
        break :zulu 0;
    } else return text[0] != 0;
    if (sign != 0) {
        text += 1;
        var hours: c_int = undefined;
        var minutes: c_int = undefined;
        if (getDigits(text, "20b:20e", &.{ &hours, &minutes }) != 2) return true;
        text += 5;
        value.timezone_minutes = sign * (minutes + hours * 60);
        if (value.timezone_minutes == 0) {
            value.local = false;
            value.utc = true;
        }
    }
    while (isSpace(text[0])) {
        text += 1;
    }
    return text[0] != 0;
}

/// Source `parseHhMmSs()`.
pub fn parseClock(text_initial: [*:0]const u8, value: *DateTime) bool {
    var text: [*:0]const u8 = text_initial;
    var hours: c_int = undefined;
    var minutes: c_int = undefined;
    if (getDigits(text, "20c:20e", &.{ &hours, &minutes }) != 2) return true;
    text += 5;
    var seconds: c_int = 0;
    var fractional: f64 = 0;
    if (text[0] == ':') {
        text += 1;
        if (getDigits(text, "20e", &.{&seconds}) != 1) return true;
        text += 2;
        if (text[0] == '.' and text[1] >= '0' and text[1] <= '9') {
            var scale: f64 = 1;
            text += 1;
            while (text[0] >= '0' and text[0] <= '9') : (text += 1) {
                fractional = fractional * 10 + @as(f64, @floatFromInt(text[0] - '0'));
                scale *= 10;
            }
            fractional /= scale;
            if (fractional > 0.999) fractional = 0.999;
        }
    }
    value.valid_julian = false;
    value.raw_seconds = false;
    value.valid_hms = true;
    value.hour = hours;
    value.minute = minutes;
    value.seconds = @as(f64, @floatFromInt(seconds)) + fractional;
    return parseTimezone(text, value);
}

/// Source `datetimeError()`.
pub fn setError(value: *DateTime) void {
    value.* = .{ .error_state = true };
}

/// Source `computeJD()`.
pub fn computeJulianDay(value: *DateTime) void {
    if (value.valid_julian) return;
    var year: c_int = if (value.valid_ymd) value.year else 2000;
    var month: c_int = if (value.valid_ymd) value.month else 1;
    const day: c_int = if (value.valid_ymd) value.day else 1;
    if (year < -4713 or year > 9999 or value.raw_seconds) {
        setError(value);
        return;
    }
    if (month <= 2) {
        year -= 1;
        month += 12;
    }
    const century = @divTrunc(year + 4800, 100);
    const correction = 38 - century + @divTrunc(century, 4);
    const year_days = @divTrunc(36525 * (year + 4716), 100);
    const month_days = @divTrunc(306001 * (month + 1), 10000);
    value.julian_milliseconds = @intFromFloat(@as(f64, @floatFromInt(year_days + month_days + day + correction - 1524)) * 86_400_000.0 - 43_200_000.0);
    value.valid_julian = true;
    if (value.valid_hms) {
        value.julian_milliseconds += @as(i64, value.hour) * 3_600_000 + @as(i64, value.minute) * 60_000 + @as(i64, @intFromFloat(value.seconds * 1000 + 0.5));
        if (value.timezone_minutes != 0) {
            value.julian_milliseconds -= @as(i64, value.timezone_minutes) * 60_000;
            value.valid_ymd = false;
            value.valid_hms = false;
            value.timezone_minutes = 0;
            value.utc = true;
            value.local = false;
        }
    }
}

/// Source `computeFloor()`.
pub fn computeFloor(value: *DateTime) void {
    if (value.day <= 28 or (@as(c_int, 1) << @intCast(value.month)) & 0x15aa != 0) value.floor_days = 0 else if (value.month != 2) value.floor_days = @intFromBool(value.day == 31) else if (@rem(value.year, 4) != 0 or (@rem(value.year, 100) == 0 and @rem(value.year, 400) != 0)) value.floor_days = value.day - 28 else value.floor_days = value.day - 29;
}

/// Source `parseYyyyMmDd()`.
pub fn parseCalendar(text_initial: [*:0]const u8, value: *DateTime) bool {
    var text: [*:0]const u8 = text_initial;
    const negative = text[0] == '-';
    if (negative) text += 1;
    var year: c_int = undefined;
    var month: c_int = undefined;
    var day: c_int = undefined;
    if (getDigits(text, "40f-21a-21d", &.{ &year, &month, &day }) != 3) return true;
    text += 10;
    while (isSpace(text[0]) or text[0] == 'T') text += 1;
    if (parseClock(text, value)) {
        if (text[0] == 0) value.valid_hms = false else return true;
    }
    value.valid_julian = false;
    value.valid_ymd = true;
    value.year = if (negative) -year else year;
    value.month = month;
    value.day = day;
    computeFloor(value);
    if (value.timezone_minutes != 0) computeJulianDay(value);
    return false;
}

/// Source `sqlite3StmtCurrentTime()`.
pub fn statementCurrentTime(context: *types.Context) i64 {
    const machine = context.pVdbe.?;
    if (machine.iCurrentTime == 0) {
        const filesystem: *vfs.sqlite3_vfs = @ptrCast(@alignCast(context.pOut.?.db.?.pVfs.?));
        const result = vfs.osCurrentTimeInt64(filesystem, &machine.iCurrentTime);
        if (result != 0) machine.iCurrentTime = 0;
    }
    return machine.iCurrentTime;
}

/// Source `setDateTimeToCurrent()`.
pub fn setToCurrent(context: *types.Context, value: *DateTime) bool {
    value.julian_milliseconds = statementCurrentTime(context);
    if (value.julian_milliseconds <= 0) return true;
    value.valid_julian = true;
    value.utc = true;
    value.local = false;
    clearCalendarClockTimezone(value);
    return false;
}

/// Source `parseDateOrTime()`.
pub fn parseDateOrTime(context: *types.Context, text: [*:0]const u8, value: *DateTime) bool {
    if (!parseCalendar(text, value) or !parseClock(text, value)) return false;
    if (sqlite_string.compareInternal(text, "now") == 0) return setToCurrent(context, value);
    const parsed = sqlite_float.parse(text);
    if (parsed.code > 0) {
        setRawDateNumber(value, parsed.value);
        return false;
    }
    if (sqlite_string.compareInternal(text, "subsec") == 0 or sqlite_string.compareInternal(text, "subsecond") == 0) {
        value.use_subseconds = true;
        return setToCurrent(context, value);
    }
    return true;
}

/// Source `setRawDateNumber()`.
pub fn setRawDateNumber(value: *DateTime, number: f64) void {
    value.seconds = number;
    value.raw_seconds = true;
    if (number >= 0 and number < 5_373_484.5) {
        value.julian_milliseconds = @intFromFloat(number * 86_400_000 + 0.5);
        value.valid_julian = true;
    }
}

/// Source `validJulianDay()`.
pub fn validJulianDay(value: i64) bool {
    return value >= 0 and value <= 464_269_060_799_999;
}

/// Source `computeYMD()`.
pub fn computeYearMonthDay(value: *DateTime) void {
    if (value.valid_ymd) return;
    if (!value.valid_julian) {
        value.year = 2000;
        value.month = 1;
        value.day = 1;
    } else if (!validJulianDay(value.julian_milliseconds)) {
        setError(value);
        return;
    } else {
        const z: c_int = @intCast(@divTrunc(value.julian_milliseconds + 43_200_000, 86_400_000));
        const alpha: c_int = @as(c_int, @intFromFloat(@as(f64, @floatFromInt(z + 32044)) / 36524.25)) - 52;
        const a = z + 1 + alpha - @divTrunc(alpha + 100, 4) + 25;
        const b = a + 1524;
        const c: c_int = @intFromFloat((@as(f64, @floatFromInt(b)) - 122.1) / 365.25);
        const d = @divTrunc(36525 * (c & 32767), 100);
        const e: c_int = @intFromFloat(@as(f64, @floatFromInt(b - d)) / 30.6001);
        const x: c_int = @intFromFloat(30.6001 * @as(f64, @floatFromInt(e)));
        value.day = b - d - x;
        value.month = if (e < 14) e - 1 else e - 13;
        value.year = if (value.month > 2) c - 4716 else c - 4715;
    }
    value.valid_ymd = true;
}

/// Source `computeHMS()`.
pub fn computeHourMinuteSecond(value: *DateTime) void {
    if (value.valid_hms) return;
    computeJulianDay(value);
    const day_ms: c_int = @intCast(@rem(value.julian_milliseconds + 43_200_000, 86_400_000));
    value.seconds = @as(f64, @floatFromInt(@rem(day_ms, 60_000))) / 1000;
    const day_minutes = @divTrunc(day_ms, 60_000);
    value.minute = @rem(day_minutes, 60);
    value.hour = @divTrunc(day_minutes, 60);
    value.raw_seconds = false;
    value.valid_hms = true;
}

/// Source `computeYMD_HMS()`.
pub fn computeCalendarAndClock(value: *DateTime) void {
    computeYearMonthDay(value);
    computeHourMinuteSecond(value);
}

/// Source `clearYMD_HMS_TZ()`.
pub fn clearCalendarClockTimezone(value: *DateTime) void {
    value.valid_ymd = false;
    value.valid_hms = false;
    value.timezone_minutes = 0;
}

/// Source `osLocaltime()` for the active POSIX profile.
pub fn osLocaltime(timestamp: *const c_long, output: *CalendarTime) bool {
    return localtime_r(timestamp, output) == null;
}

/// Source `toLocaltime()`.
pub fn toLocalTime(value: *DateTime, context: *types.Context) bool {
    computeJulianDay(value);
    var mapped = value.*;
    var year_difference: c_int = 0;
    var timestamp: c_long = undefined;
    if (value.julian_milliseconds < 210_866_760_000_000 or value.julian_milliseconds > 213_014_145_600_000) {
        computeCalendarAndClock(&mapped);
        year_difference = (2000 + @rem(mapped.year, 4)) - mapped.year;
        mapped.year += year_difference;
        mapped.valid_julian = false;
        computeJulianDay(&mapped);
        timestamp = @intCast(@divTrunc(mapped.julian_milliseconds, 1000) - 210_866_760_000);
    } else timestamp = @intCast(@divTrunc(value.julian_milliseconds, 1000) - 210_866_760_000);
    var local = @as(CalendarTime, std.mem.zeroes(CalendarTime));
    if (osLocaltime(&timestamp, &local)) {
        mem.resultError(context, "local time unavailable", -1);
        return true;
    }
    value.year = local.year + 1900 - year_difference;
    value.month = local.month + 1;
    value.day = local.month_day;
    value.hour = local.hour;
    value.minute = local.minute;
    value.seconds = @as(f64, @floatFromInt(local.second)) + @as(f64, @floatFromInt(@rem(value.julian_milliseconds, 1000))) * 0.001;
    value.valid_ymd = true;
    value.valid_hms = true;
    value.valid_julian = false;
    value.raw_seconds = false;
    value.timezone_minutes = 0;
    value.error_state = false;
    return false;
}

/// Source `autoAdjustDate()`.
pub fn autoAdjustDate(value: *DateTime) void {
    if (!value.raw_seconds or value.valid_julian) value.raw_seconds = false else if (value.seconds >= -210_866_760_000 and value.seconds <= 253_402_300_799) {
        const adjusted = value.seconds * 1000 + 210_866_760_000_000.0;
        clearCalendarClockTimezone(value);
        value.julian_milliseconds = @intFromFloat(adjusted + 0.5);
        value.valid_julian = true;
        value.raw_seconds = false;
    }
}

/// Source `daysAfterJan01()`.
pub fn daysAfterJanuaryFirst(value: *const DateTime) c_int {
    var january = value.*;
    january.valid_julian = false;
    january.month = 1;
    january.day = 1;
    computeJulianDay(&january);
    return @intCast(@divTrunc(value.julian_milliseconds - january.julian_milliseconds + 43_200_000, 86_400_000));
}

/// Source `daysAfterMonday()`.
pub fn daysAfterMonday(value: *const DateTime) c_int {
    return @intCast(@rem(@divTrunc(value.julian_milliseconds + 43_200_000, 86_400_000), 7));
}

/// Source `daysAfterSunday()`.
pub fn daysAfterSunday(value: *const DateTime) c_int {
    return @intCast(@rem(@divTrunc(value.julian_milliseconds + 129_600_000, 86_400_000), 7));
}
