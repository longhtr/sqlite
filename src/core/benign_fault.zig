//! SQLite benign-allocation-failure hook registry.

const std = @import("std");

pub const Hook = *const fn () callconv(.c) void;

pub const Hooks = extern struct {
    begin_callback: ?Hook,
    end_callback: ?Hook,
};

pub var process_hooks = Hooks{ .begin_callback = null, .end_callback = null };

pub fn configure(begin_callback: ?Hook, end_callback: ?Hook) void {
    process_hooks.begin_callback = begin_callback;
    process_hooks.end_callback = end_callback;
}

pub fn begin() void {
    if (process_hooks.begin_callback) |callback| callback();
}

pub fn end() void {
    if (process_hooks.end_callback) |callback| callback();
}

test "registration replacement and nullable dispatch" {
    const Probe = struct {
        var begins: usize = 0;
        var ends: usize = 0;
        fn onBegin() callconv(.c) void {
            begins += 1;
        }
        fn onEnd() callconv(.c) void {
            ends += 1;
        }
    };
    configure(Probe.onBegin, Probe.onEnd);
    begin();
    begin();
    end();
    try std.testing.expectEqual(@as(usize, 2), Probe.begins);
    try std.testing.expectEqual(@as(usize, 1), Probe.ends);
    configure(null, null);
    begin();
    end();
    try std.testing.expectEqual(@as(usize, 2), Probe.begins);
    try std.testing.expectEqual(@as(usize, 1), Probe.ends);
}
