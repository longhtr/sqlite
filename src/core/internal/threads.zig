//! Source-shaped internal worker-thread lifecycle from `src/threads.c`.

const std = @import("std");

pub const Task = *const fn (?*anyopaque) ?*anyopaque;

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    task: Task,
    input: ?*anyopaque,
    output: ?*anyopaque = null,
    done: bool = false,
};

fn run(handle: *Handle) void {
    handle.output = handle.task(handle.input);
    handle.done = true;
}

/// Source `sqlite3ThreadCreate()`. Failure to ask the operating system for a
/// thread falls back to deterministic execution by the caller, as upstream
/// does; only allocation of the thread handle is fatal.
pub fn create(allocator: std.mem.Allocator, task: Task, input: ?*anyopaque, force_sequential: bool) error{OutOfMemory}!*Handle {
    const handle = allocator.create(Handle) catch return error.OutOfMemory;
    handle.* = .{ .allocator = allocator, .task = task, .input = input };
    if (!force_sequential) {
        handle.thread = std.Thread.spawn(.{}, run, .{handle}) catch null;
    }
    if (handle.thread == null) run(handle);
    return handle;
}

/// Source `sqlite3ThreadJoin()`. The handle is consumed regardless of whether
/// work ran on a worker or synchronously during creation.
pub fn join(handle: *Handle, output: *?*anyopaque) void {
    if (handle.thread) |thread| thread.join();
    std.debug.assert(handle.done);
    output.* = handle.output;
    const allocator = handle.allocator;
    allocator.destroy(handle);
}
