//! Process-global automatic-extension registration and reset ownership.
//!
//! The lifecycle owner resets this registry during sqlite3_shutdown(), after
//! OS shutdown and before allocator shutdown, matching main.c.

const std = @import("std");
const memory = @import("memory.zig");

pub const Entry = *const fn (?*anyopaque, ?*?[*:0]u8, ?*const anyopaque) callconv(.c) c_int;

var entries: [64]?Entry = [_]?Entry{null} ** 64;
var entry_count: usize = 0;
var extension_api: ?*const anyopaque = null;

pub fn setApi(pointer: ?*const anyopaque) void {
    extension_api = pointer;
}

pub fn api() ?*const anyopaque {
    return extension_api;
}

pub fn run(database: ?*anyopaque) c_int {
    for (entries[0..entry_count]) |entry| {
        var message: ?[*:0]u8 = null;
        const result = entry.?(database, &message, extension_api);
        if (message) |text| memory.processManager().free(@ptrCast(text));
        if (result != 0) return result;
    }
    return 0;
}

pub fn add(pointer: ?*const fn () callconv(.c) void) c_int {
    const entry: Entry = if (pointer) |value| @ptrCast(value) else return 21;
    for (entries[0..entry_count]) |existing| if (existing.? == entry) return 0;
    if (entry_count == entries.len) return 13;
    entries[entry_count] = entry;
    entry_count += 1;
    return 0;
}

pub fn cancel(pointer: ?*const fn () callconv(.c) void) c_int {
    const entry: Entry = if (pointer) |value| @ptrCast(value) else return 0;
    for (entries[0..entry_count], 0..) |existing, index| if (existing.? == entry) {
        std.mem.copyForwards(?Entry, entries[index .. entry_count - 1], entries[index + 1 .. entry_count]);
        entry_count -= 1;
        entries[entry_count] = null;
        return 1;
    };
    return 0;
}

pub fn reset() void {
    @memset(&entries, null);
    entry_count = 0;
}

pub fn count() usize {
    return entry_count;
}
