//! Process-global automatic-extension registration and reset ownership.
//!
//! The lifecycle owner resets this registry during sqlite3_shutdown(), after
//! OS shutdown and before allocator shutdown, matching main.c.

const std = @import("std");
const memory = @import("memory.zig");
const sqlite_mutex = @import("mutex.zig");

pub const Entry = *const fn (?*anyopaque, ?*?[*:0]u8, ?*const anyopaque) callconv(.c) c_int;

var entries: std.ArrayList(Entry) = .empty;
var extension_api: ?*const anyopaque = null;
var registry_mutex: sqlite_mutex.Mutex = .{ .kind = .recursive };

pub fn setApi(pointer: ?*const anyopaque) void {
    registry_mutex.enter();
    defer registry_mutex.leave();
    extension_api = pointer;
}

pub fn api() ?*const anyopaque {
    registry_mutex.enter();
    defer registry_mutex.leave();
    return extension_api;
}

/// Source `sqlite3AutoLoadExtensions()`: fetch each entry while holding the
/// process registry mutex, invoke it without the mutex, and stop at the first
/// initializer error while freeing its optional diagnostic.
pub fn autoLoadExtensions(database: ?*anyopaque) c_int {
    var index: usize = 0;
    while (true) : (index += 1) {
        registry_mutex.enter();
        const entry = if (index < entries.items.len) entries.items[index] else null;
        const api_pointer = extension_api;
        registry_mutex.leave();
        const callback = entry orelse return 0;
        var message: ?[*:0]u8 = null;
        const result = callback(database, &message, api_pointer);
        if (message) |text| memory.processManager().free(@ptrCast(text));
        if (result != 0) return result;
    }
}

pub fn run(database: ?*anyopaque) c_int {
    return autoLoadExtensions(database);
}

/// Source `sqlite3_auto_extension()`: deduplicate and append one initializer
/// to the dynamically sized process list while holding the main mutex.
pub fn registerAutoExtension(pointer: ?*const fn () callconv(.c) void) c_int {
    const entry: Entry = if (pointer) |value| @ptrCast(value) else return 21;
    registry_mutex.enter();
    defer registry_mutex.leave();
    for (entries.items) |existing| {
        if (existing == entry) return 0;
    }
    entries.append(std.heap.c_allocator, entry) catch return 7;
    return 0;
}

pub fn add(pointer: ?*const fn () callconv(.c) void) c_int {
    return registerAutoExtension(pointer);
}

/// Source `sqlite3_cancel_auto_extension()`: remove at most one matching
/// initializer by replacing it with the final list entry.
pub fn cancelAutoExtension(pointer: ?*const fn () callconv(.c) void) c_int {
    const entry: Entry = if (pointer) |value| @ptrCast(value) else return 0;
    registry_mutex.enter();
    defer registry_mutex.leave();
    for (entries.items, 0..) |existing, index| {
        if (existing == entry) {
            _ = entries.swapRemove(index);
            return 1;
        }
    }
    return 0;
}

pub fn cancel(pointer: ?*const fn () callconv(.c) void) c_int {
    return cancelAutoExtension(pointer);
}

/// Source `sqlite3_reset_auto_extension()`: release the dynamic registry and
/// restore its canonical empty state under the process mutex.
pub fn resetAutoExtensions() void {
    registry_mutex.enter();
    defer registry_mutex.leave();
    entries.deinit(std.heap.c_allocator);
    entries = .empty;
}

pub fn reset() void {
    resetAutoExtensions();
}

pub fn count() usize {
    registry_mutex.enter();
    defer registry_mutex.leave();
    return entries.items.len;
}
