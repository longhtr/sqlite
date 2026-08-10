//! Date/time modifier interpreter from `date.c`.

const std = @import("std");
const sqlite_float = @import("../float.zig");
const date = @import("date_time.zig");
const types = @import("vdbe_types.zig");

fn equal(text: [*:0]const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.span(text), expected);
}
fn starts(text: [*:0]const u8, expected: []const u8) bool {
    const span = std.mem.span(text);
    return span.len >= expected.len and std.ascii.eqlIgnoreCase(span[0..expected.len], expected);
}
fn parsePrefix(text: [*:0]const u8, length: usize) ?f64 {
    var stack: [128]u8 = undefined;
    if (length >= stack.len) return null;
    @memcpy(stack[0..length], text[0..length]);
    stack[length] = 0;
    const result = sqlite_float.parse(@ptrCast(&stack));
    return if (result.code > 0) result.value else null;
}

/// Source `parseModifier()`.
pub fn parseModifier(context: *types.Context, modifier: [*:0]const u8, _: c_int, value: *date.DateTime, index: c_int) c_int {
    if (equal(modifier, "auto")) {
        if (index > 1) return 1;
        date.autoAdjustDate(value);
        return 0;
    }
    if (equal(modifier, "ceiling")) {
        date.computeJulianDay(value);
        date.clearCalendarClockTimezone(value);
        value.floor_days = 0;
        return 0;
    }
    if (equal(modifier, "floor")) {
        date.computeJulianDay(value);
        value.julian_milliseconds -= @as(i64, value.floor_days) * 86_400_000;
        date.clearCalendarClockTimezone(value);
        return 0;
    }
    if (equal(modifier, "julianday")) {
        if (index > 1) return 1;
        if (value.valid_julian and value.raw_seconds) {
            value.raw_seconds = false;
            return 0;
        }
        return 1;
    }
    if (equal(modifier, "localtime")) {
        if (!value.local) if (date.toLocalTime(value, context)) return 1;
        value.utc = false;
        value.local = true;
        return 0;
    }
    if (equal(modifier, "unixepoch") and value.raw_seconds) {
        if (index > 1) return 1;
        const adjusted = value.seconds * 1000 + 210_866_760_000_000.0;
        if (adjusted < 0 or adjusted >= 464_269_060_800_000.0) return 1;
        date.clearCalendarClockTimezone(value);
        value.julian_milliseconds = @intFromFloat(adjusted + 0.5);
        value.valid_julian = true;
        value.raw_seconds = false;
        return 0;
    }
    if (equal(modifier, "utc")) {
        if (!value.utc) {
            date.computeJulianDay(value);
            const original = value.julian_milliseconds;
            var guess = original;
            var difference: i64 = 0;
            var attempts: u8 = 0;
            while (true) {
                guess -= difference;
                var local = date.DateTime{ .julian_milliseconds = guess, .valid_julian = true };
                if (date.toLocalTime(&local, context)) return 1;
                date.computeJulianDay(&local);
                difference = local.julian_milliseconds - original;
                if (difference == 0 or attempts >= 3) break;
                attempts += 1;
            }
            value.* = .{ .julian_milliseconds = guess, .valid_julian = true, .utc = true };
        }
        return 0;
    }
    if (starts(modifier, "weekday ")) {
        const parsed = sqlite_float.parse(modifier + 8);
        if (parsed.code <= 0 or parsed.value < 0 or parsed.value >= 7 or @floor(parsed.value) != parsed.value) return 1;
        const weekday: i64 = @intFromFloat(parsed.value);
        date.computeCalendarAndClock(value);
        value.timezone_minutes = 0;
        value.valid_julian = false;
        date.computeJulianDay(value);
        var current = @rem(@divTrunc(value.julian_milliseconds + 129_600_000, 86_400_000), 7);
        if (current > weekday) current -= 7;
        value.julian_milliseconds += (weekday - current) * 86_400_000;
        date.clearCalendarClockTimezone(value);
        return 0;
    }
    if (equal(modifier, "subsec") or equal(modifier, "subsecond")) {
        value.use_subseconds = true;
        return 0;
    }
    if (starts(modifier, "start of ")) {
        if (!value.valid_julian and !value.valid_ymd and !value.valid_hms) return 1;
        date.computeYearMonthDay(value);
        value.valid_hms = true;
        value.hour = 0;
        value.minute = 0;
        value.seconds = 0;
        value.raw_seconds = false;
        value.timezone_minutes = 0;
        value.valid_julian = false;
        const unit = modifier + 9;
        if (equal(unit, "month")) value.day = 1 else if (equal(unit, "year")) {
            value.month = 1;
            value.day = 1;
        } else if (!equal(unit, "day")) return 1;
        return 0;
    }
    return numericModifier(context, modifier, value);
}

fn numericModifier(context: *types.Context, modifier_initial: [*:0]const u8, value: *date.DateTime) c_int {
    _ = context;
    var modifier = modifier_initial;
    const sign_character = modifier[0];
    var prefix_length: usize = 1;
    while (modifier[prefix_length] != 0 and modifier[prefix_length] != ':' and !std.ascii.isWhitespace(modifier[prefix_length])) : (prefix_length += 1) {
        if (modifier[prefix_length] == '-') break;
    }
    if (modifier[prefix_length] == '-' and (sign_character == '+' or sign_character == '-')) {
        const year_digits: usize = prefix_length - 1;
        if (year_digits != 4 and year_digits != 5) return 1;
        var year: c_int = 0;
        for (modifier[1 .. 1 + year_digits]) |byte| {
            if (!std.ascii.isDigit(byte)) return 1;
            year = year * 10 + byte - '0';
        }
        const month_start = 2 + year_digits;
        if (modifier[1 + year_digits] != '-' or modifier[month_start + 2] != '-') return 1;
        var month: c_int = undefined;
        var day: c_int = undefined;
        if (date.getDigits(modifier + month_start, "20a-20d", &.{ &month, &day }) != 2 or month >= 12 or day >= 31) return 1;
        date.computeCalendarAndClock(value);
        value.valid_julian = false;
        if (sign_character == '-') {
            value.year -= year;
            value.month -= month;
            day = -day;
        } else {
            value.year += year;
            value.month += month;
        }
        const adjustment = if (value.month > 0) @divTrunc(value.month - 1, 12) else @divTrunc(value.month - 12, 12);
        value.year += adjustment;
        value.month -= adjustment * 12;
        date.computeFloor(value);
        date.computeJulianDay(value);
        value.valid_hms = false;
        value.valid_ymd = false;
        value.julian_milliseconds += @as(i64, day) * 86_400_000;
        const tail = month_start + 5;
        if (modifier[tail] == 0) return 0;
        if (!std.ascii.isWhitespace(modifier[tail])) return 1;
        modifier += tail + 1;
        while (std.ascii.isWhitespace(modifier[0])) modifier += 1;
        return timeOffset(modifier, sign_character, value);
    }
    if (modifier[prefix_length] == ':') return timeOffset(modifier, sign_character, value);
    const amount = parsePrefix(modifier, prefix_length) orelse return 1;
    var unit = modifier + prefix_length;
    while (std.ascii.isWhitespace(unit[0])) unit += 1;
    var unit_span: []const u8 = std.mem.span(unit);
    if (unit_span.len > 0 and (unit_span[unit_span.len - 1] == 's' or unit_span[unit_span.len - 1] == 'S')) unit_span = unit_span[0 .. unit_span.len - 1];
    const names = [_][]const u8{ "second", "minute", "hour", "day", "month", "year" };
    const limits = [_]f64{ 4.6427e14, 7.7379e12, 1.2897e11, 5_373_485, 176_546, 14_713 };
    const scales = [_]f64{ 1, 60, 3600, 86400, 2_592_000, 31_536_000 };
    for (names, limits, scales, 0..) |name, limit, scale, unit_index| {
        if (!std.ascii.eqlIgnoreCase(unit_span, name) or amount <= -limit or amount >= limit) continue;
        var remainder = amount;
        if (unit_index == 4 or unit_index == 5) {
            date.computeCalendarAndClock(value);
            const whole: c_int = @intFromFloat(remainder);
            if (unit_index == 4) {
                value.month += whole;
                const adjustment = if (value.month > 0) @divTrunc(value.month - 1, 12) else @divTrunc(value.month - 12, 12);
                value.year += adjustment;
                value.month -= adjustment * 12;
            } else value.year += whole;
            date.computeFloor(value);
            value.valid_julian = false;
            remainder -= @floatFromInt(whole);
        }
        date.computeJulianDay(value);
        value.julian_milliseconds += @intFromFloat(remainder * 1000 * scale + if (remainder < 0) @as(f64, -0.5) else 0.5);
        date.clearCalendarClockTimezone(value);
        value.floor_days = 0;
        return 0;
    }
    return 1;
}

fn timeOffset(text_initial: [*:0]const u8, sign_character: u8, value: *date.DateTime) c_int {
    var text = text_initial;
    if (!std.ascii.isDigit(text[0])) text += 1;
    var offset = date.DateTime{};
    if (date.parseClock(text, &offset)) return 1;
    date.computeJulianDay(&offset);
    offset.julian_milliseconds -= 43_200_000;
    offset.julian_milliseconds -= @divTrunc(offset.julian_milliseconds, 86_400_000) * 86_400_000;
    if (sign_character == '-') offset.julian_milliseconds = -offset.julian_milliseconds;
    date.computeJulianDay(value);
    date.clearCalendarClockTimezone(value);
    value.julian_milliseconds += offset.julian_milliseconds;
    return 0;
}
