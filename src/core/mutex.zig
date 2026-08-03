//! SQLite mutex abstraction for the THREADSAFE=1 profile.
//!
//! Dynamic fast/recursive mutexes and the twelve stable static mutex identities
//! mirror `mutex.c` and `mutex_unix.c`. Internal allocation returns null when
//! core mutexes are disabled, matching `sqlite3MutexAlloc`.

const std = @import("std");
const config_types = @import("internal/config_types.zig");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;

/// ABI-exact shape of public `sqlite3_mutex_methods`.
pub const MutexMethods = config_types.MutexMethods;

var barrier_token = std.atomic.Value(u8).init(0);
pub fn memoryBarrier() void {
    _ = barrier_token.fetchAdd(0, .seq_cst);
}

pub fn pthreadInit() callconv(.c) c_int {
    return 0;
}
pub fn pthreadEnd() callconv(.c) c_int {
    return 0;
}

pub fn noopInit() callconv(.c) c_int {
    return 0;
}
pub fn noopEnd() callconv(.c) c_int {
    return 0;
}
pub fn noopAlloc(_: c_int) callconv(.c) ?*anyopaque {
    return @ptrFromInt(8);
}
pub fn noopFree(_: ?*anyopaque) callconv(.c) void {}
pub fn noopEnter(_: ?*anyopaque) callconv(.c) void {}
pub fn noopTry(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}
pub fn noopLeave(_: ?*anyopaque) callconv(.c) void {}

pub const noop_methods = MutexMethods{
    .xMutexInit = noopInit,
    .xMutexEnd = noopEnd,
    .xMutexAlloc = noopAlloc,
    .xMutexFree = noopFree,
    .xMutexEnter = noopEnter,
    .xMutexTry = noopTry,
    .xMutexLeave = noopLeave,
    .xMutexHeld = null,
    .xMutexNotheld = null,
};

pub fn noopMethods() *const MutexMethods {
    return &noop_methods;
}

pub const MethodsAdapter = struct {
    methods: MutexMethods,

    pub fn init(methods: MutexMethods) MethodsAdapter {
        return .{ .methods = methods };
    }
    pub fn start(self: *MethodsAdapter) c_int {
        return if (self.methods.xMutexInit) |callback| callback() else 0;
    }
    pub fn stop(self: *MethodsAdapter) c_int {
        return if (self.methods.xMutexEnd) |callback| callback() else 0;
    }
    pub fn alloc(self: *MethodsAdapter, kind: Kind) ?*anyopaque {
        return self.methods.xMutexAlloc.?(@intFromEnum(kind));
    }
    pub fn free(self: *MethodsAdapter, value: ?*anyopaque) void {
        if (value != null) self.methods.xMutexFree.?(value);
    }
    pub fn enter(self: *MethodsAdapter, value: ?*anyopaque) void {
        if (value != null) self.methods.xMutexEnter.?(value);
    }
    pub fn tryEnter(self: *MethodsAdapter, value: ?*anyopaque) c_int {
        return if (value) |_| self.methods.xMutexTry.?(value) else 0;
    }
    pub fn leave(self: *MethodsAdapter, value: ?*anyopaque) void {
        if (value != null) self.methods.xMutexLeave.?(value);
    }
    pub fn held(self: *MethodsAdapter, value: ?*anyopaque) bool {
        return value == null or self.methods.xMutexHeld == null or self.methods.xMutexHeld.?(value) != 0;
    }
    pub fn notHeld(self: *MethodsAdapter, value: ?*anyopaque) bool {
        return value == null or self.methods.xMutexNotheld == null or self.methods.xMutexNotheld.?(value) != 0;
    }
};

pub const Mode = enum { single_thread, multi_thread, serialized };
pub const Kind = enum(u8) {
    fast = 0,
    recursive = 1,
    static_main = 2,
    static_mem = 3,
    static_open = 4,
    static_prng = 5,
    static_lru = 6,
    static_pmem = 7,
    static_app1 = 8,
    static_app2 = 9,
    static_app3 = 10,
    static_vfs1 = 11,
    static_vfs2 = 12,
    static_vfs3 = 13,

    pub fn isStatic(self: Kind) bool {
        return @intFromEnum(self) >= 2;
    }
};

pub const Mutex = struct {
    native: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    owner: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    depth: usize = 0,
    kind: Kind = .fast,
    dynamic: bool = false,

    fn threadId() u64 {
        return @intCast(std.Thread.getCurrentId());
    }

    pub fn enter(self: *Mutex) void {
        const id = threadId();
        if (self.kind == .recursive and self.owner.load(.acquire) == id) {
            self.depth += 1;
            return;
        }
        std.debug.assert(std.c.pthread_mutex_lock(&self.native) == .SUCCESS);
        std.debug.assert(self.depth == 0);
        self.depth = 1;
        self.owner.store(id, .release);
    }

    pub fn tryEnter(self: *Mutex) bool {
        const id = threadId();
        if (self.kind == .recursive and self.owner.load(.acquire) == id) {
            self.depth += 1;
            return true;
        }
        if (std.c.pthread_mutex_trylock(&self.native) != .SUCCESS) return false;
        std.debug.assert(self.depth == 0);
        self.depth = 1;
        self.owner.store(id, .release);
        return true;
    }

    pub fn leave(self: *Mutex) void {
        std.debug.assert(self.held());
        self.depth -= 1;
        if (self.depth == 0) {
            self.owner.store(0, .release);
            std.debug.assert(std.c.pthread_mutex_unlock(&self.native) == .SUCCESS);
        } else {
            std.debug.assert(self.kind == .recursive);
        }
    }

    pub fn held(self: *const Mutex) bool {
        return self.owner.load(.acquire) == threadId() and self.depth != 0;
    }

    pub fn notHeld(self: *const Mutex) bool {
        return !self.held();
    }
};

pub const Handle = union(enum) {
    native: *Mutex,
    configured: struct {
        adapter: *MethodsAdapter,
        pointer: ?*anyopaque,
    },

    pub fn enter(self: *Handle) void {
        switch (self.*) {
            .native => |value| value.enter(),
            .configured => |value| value.adapter.enter(value.pointer),
        }
    }

    pub fn leave(self: *Handle) void {
        switch (self.*) {
            .native => |value| value.leave(),
            .configured => |value| value.adapter.leave(value.pointer),
        }
    }

    pub fn nativeMutex(self: *const Handle) ?*Mutex {
        return switch (self.*) {
            .native => |value| value,
            .configured => null,
        };
    }
};

pub var process_static_mutexes: [12]Mutex = .{
    .{ .kind = .static_main },
    .{ .kind = .static_mem },
    .{ .kind = .static_open },
    .{ .kind = .static_prng },
    .{ .kind = .static_lru },
    .{ .kind = .static_pmem },
    .{ .kind = .static_app1 },
    .{ .kind = .static_app2 },
    .{ .kind = .static_app3 },
    .{ .kind = .static_vfs1 },
    .{ .kind = .static_vfs2 },
    .{ .kind = .static_vfs3 },
};

pub fn processStatic(kind: Kind) *Mutex {
    std.debug.assert(kind.isStatic());
    return &process_static_mutexes[@intFromEnum(kind) - 2];
}

pub const Subsystem = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .serialized,
    initialized: bool = false,
    configured_methods: ?MethodsAdapter = null,

    pub fn init(allocator: std.mem.Allocator) Subsystem {
        return .{ .allocator = allocator };
    }

    pub fn configure(self: *Subsystem, mode: Mode) error{Misuse}!void {
        if (self.initialized) return error.Misuse;
        self.mode = mode;
    }

    pub fn configureMethods(self: *Subsystem, methods: MutexMethods) error{Misuse}!void {
        if (self.initialized) return error.Misuse;
        self.configured_methods = MethodsAdapter.init(methods);
    }

    pub fn start(self: *Subsystem) void {
        self.initialized = true;
        for (&process_static_mutexes) |*value| value.dynamic = false;
    }

    /// One sqlite3MutexInit() attempt. Upstream invokes xMutexInit on every
    /// non-final sqlite3_initialize() attempt, including retries after a later
    /// allocator, PCache, or OS failure, while retaining isMutexInit ownership.
    pub fn startLifecycle(self: *Subsystem) c_int {
        if (self.configured_methods) |*adapter| {
            const result = adapter.start();
            if (result != 0) return result;
        } else {
            memoryBarrier();
            if (self.coreMutexEnabled()) {
                if (pthreadInit() != 0) return 1;
            } else if (noopInit() != 0) return 1;
        }
        if (!self.initialized) self.start();
        memoryBarrier();
        return 0;
    }

    pub fn stop(self: *Subsystem) void {
        self.initialized = false;
    }

    pub fn stopLifecycle(self: *Subsystem) c_int {
        if (!self.initialized) return 0;
        self.stop();
        if (self.configured_methods) |*adapter| return adapter.stop();
        return if (self.coreMutexEnabled()) pthreadEnd() else noopEnd();
    }

    pub fn coreMutexEnabled(self: *const Subsystem) bool {
        return self.mode != .single_thread;
    }

    pub fn connectionMutexEnabled(self: *const Subsystem) bool {
        return self.mode == .serialized;
    }

    /// Internal SQLite allocation semantics. Null means mutex operations are no-ops.
    pub fn alloc(self: *Subsystem, kind: Kind) error{OutOfMemory}!?*Mutex {
        std.debug.assert(self.initialized);
        if (!self.coreMutexEnabled()) return null;
        if (kind.isStatic()) return processStatic(kind);
        const mutex = self.allocator.create(Mutex) catch return error.OutOfMemory;
        mutex.* = .{ .kind = kind, .dynamic = true };
        return mutex;
    }

    pub fn allocHandle(self: *Subsystem, kind: Kind) error{OutOfMemory}!?Handle {
        std.debug.assert(self.initialized);
        if (!self.coreMutexEnabled()) return null;
        if (self.configured_methods) |*adapter| {
            const pointer = adapter.alloc(kind);
            if (pointer == null and !kind.isStatic()) return error.OutOfMemory;
            return .{ .configured = .{ .adapter = adapter, .pointer = pointer } };
        }
        return .{ .native = (try self.alloc(kind)).? };
    }

    pub fn freeHandle(self: *Subsystem, handle_optional: ?Handle) void {
        const handle = handle_optional orelse return;
        switch (handle) {
            .configured => |value| value.adapter.free(value.pointer),
            .native => |value| self.free(value),
        }
    }

    pub fn allocOpaque(self: *Subsystem, kind: Kind) ?*anyopaque {
        if (self.configured_methods) |*adapter| return adapter.alloc(kind);
        if (!self.coreMutexEnabled()) return noopAlloc(@intFromEnum(kind));
        return @ptrCast((self.alloc(kind) catch return null).?);
    }

    pub fn freeOpaque(self: *Subsystem, pointer: ?*anyopaque) void {
        if (self.configured_methods) |*adapter| return adapter.free(pointer);
        if (!self.coreMutexEnabled()) return noopFree(pointer);
        const value: ?*Mutex = if (pointer) |item| @ptrCast(@alignCast(item)) else null;
        self.free(value);
    }

    pub fn enterOpaque(self: *Subsystem, pointer: ?*anyopaque) void {
        if (self.configured_methods) |*adapter| return adapter.enter(pointer);
        if (!self.coreMutexEnabled()) return noopEnter(pointer);
        const value: ?*Mutex = if (pointer) |item| @ptrCast(@alignCast(item)) else null;
        enter(value);
    }

    pub fn tryOpaque(self: *Subsystem, pointer: ?*anyopaque) c_int {
        if (self.configured_methods) |*adapter| return adapter.tryEnter(pointer);
        if (!self.coreMutexEnabled()) return noopTry(pointer);
        const value: ?*Mutex = if (pointer) |item| @ptrCast(@alignCast(item)) else null;
        return if (tryEnter(value)) 0 else 5;
    }

    pub fn leaveOpaque(self: *Subsystem, pointer: ?*anyopaque) void {
        if (self.configured_methods) |*adapter| return adapter.leave(pointer);
        if (!self.coreMutexEnabled()) return noopLeave(pointer);
        const value: ?*Mutex = if (pointer) |item| @ptrCast(@alignCast(item)) else null;
        leave(value);
    }

    pub fn heldOpaque(self: *Subsystem, pointer: ?*anyopaque) bool {
        if (self.configured_methods) |*adapter| return adapter.held(pointer);
        if (!self.coreMutexEnabled()) return true;
        const value: ?*Mutex = if (pointer) |item| @ptrCast(@alignCast(item)) else null;
        return held(value);
    }

    pub fn notHeldOpaque(self: *Subsystem, pointer: ?*anyopaque) bool {
        if (self.configured_methods) |*adapter| return adapter.notHeld(pointer);
        if (!self.coreMutexEnabled()) return true;
        const value: ?*Mutex = if (pointer) |item| @ptrCast(@alignCast(item)) else null;
        return notHeld(value);
    }

    pub fn free(self: *Subsystem, value_or_null: ?*Mutex) void {
        const value = value_or_null orelse return;
        std.debug.assert(value.depth == 0);
        if (value.dynamic) {
            std.debug.assert(std.c.pthread_mutex_destroy(&value.native) == .SUCCESS);
            self.allocator.destroy(value);
        }
    }
};

pub fn enter(mutex: ?*Mutex) void {
    if (mutex) |value| value.enter();
}
pub fn tryEnter(mutex: ?*Mutex) bool {
    return if (mutex) |value| value.tryEnter() else true;
}
pub fn leave(mutex: ?*Mutex) void {
    if (mutex) |value| value.leave();
}
pub fn held(mutex: ?*const Mutex) bool {
    return if (mutex) |value| value.held() else true;
}
pub fn notHeld(mutex: ?*const Mutex) bool {
    return if (mutex) |value| value.notHeld() else true;
}

test "no-op method table returns stable sentinel and successful operations" {
    const methods = noopMethods();
    try std.testing.expectEqual(@as(c_int, 0), methods.xMutexInit.?());
    const first = methods.xMutexAlloc.?(0);
    const second = methods.xMutexAlloc.?(13);
    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(first.?));
    try std.testing.expect(first == second);
    methods.xMutexEnter.?(first);
    try std.testing.expectEqual(@as(c_int, 0), methods.xMutexTry.?(first));
    methods.xMutexLeave.?(first);
    methods.xMutexFree.?(first);
    try std.testing.expectEqual(@as(c_int, 0), methods.xMutexEnd.?());
    try std.testing.expect(methods.xMutexHeld == null and methods.xMutexNotheld == null);
}

test "sqlite3_mutex_methods ABI layout" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(MutexMethods));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(MutexMethods));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MutexMethods, "xMutexInit"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(MutexMethods, "xMutexAlloc"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(MutexMethods, "xMutexHeld"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(MutexMethods, "xMutexNotheld"));
}

var methods_probe: [7]usize = .{0} ** 7;
fn methodsInitProbe() callconv(.c) c_int {
    methods_probe[0] += 1;
    return 0;
}
fn methodsEndProbe() callconv(.c) c_int {
    methods_probe[1] += 1;
    return 0;
}
fn methodsAllocProbe(_: c_int) callconv(.c) ?*anyopaque {
    methods_probe[2] += 1;
    return @ptrFromInt(8);
}
fn methodsFreeProbe(_: ?*anyopaque) callconv(.c) void {
    methods_probe[3] += 1;
}
fn methodsEnterProbe(_: ?*anyopaque) callconv(.c) void {
    methods_probe[4] += 1;
}
fn methodsTryProbe(_: ?*anyopaque) callconv(.c) c_int {
    methods_probe[5] += 1;
    return 0;
}
fn methodsLeaveProbe(_: ?*anyopaque) callconv(.c) void {
    methods_probe[6] += 1;
}
fn methodsHeldProbe(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}
fn methodsNotheldProbe(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

test "configured mutex method table is copied and routed" {
    methods_probe = .{0} ** 7;
    var methods = MutexMethods{
        .xMutexInit = methodsInitProbe,
        .xMutexEnd = methodsEndProbe,
        .xMutexAlloc = methodsAllocProbe,
        .xMutexFree = methodsFreeProbe,
        .xMutexEnter = methodsEnterProbe,
        .xMutexTry = methodsTryProbe,
        .xMutexLeave = methodsLeaveProbe,
        .xMutexHeld = methodsHeldProbe,
        .xMutexNotheld = methodsNotheldProbe,
    };
    var adapter = MethodsAdapter.init(methods);
    methods.xMutexAlloc = null;
    try std.testing.expectEqual(@as(c_int, 0), adapter.start());
    const value = adapter.alloc(.recursive);
    adapter.enter(value);
    try std.testing.expectEqual(@as(c_int, 0), adapter.tryEnter(value));
    try std.testing.expect(adapter.held(value));
    try std.testing.expect(!adapter.notHeld(value));
    adapter.leave(value);
    adapter.free(value);
    try std.testing.expectEqual(@as(c_int, 0), adapter.stop());
    try std.testing.expectEqual([_]usize{ 1, 1, 1, 1, 1, 1, 1 }, methods_probe);
}

test "process static identities are stable and distinct" {
    try std.testing.expect(processStatic(.static_mem) == processStatic(.static_mem));
    try std.testing.expect(processStatic(.static_mem) != processStatic(.static_main));
    try std.testing.expectEqual(Kind.static_mem, processStatic(.static_mem).kind);
}

test "mode configuration and static identities" {
    var subsystem = Subsystem.init(std.testing.allocator);
    try subsystem.configure(.serialized);
    subsystem.start();
    defer subsystem.stop();
    try std.testing.expect(subsystem.coreMutexEnabled());
    try std.testing.expect(subsystem.connectionMutexEnabled());
    const first = try subsystem.alloc(.static_mem);
    const second = try subsystem.alloc(.static_mem);
    try std.testing.expect(first == second);
    try std.testing.expectError(error.Misuse, subsystem.configure(.single_thread));
}

test "recursive entry and ownership" {
    var subsystem = Subsystem.init(std.testing.allocator);
    subsystem.start();
    defer subsystem.stop();
    const mutex = try subsystem.alloc(.recursive);
    defer subsystem.free(mutex);
    enter(mutex);
    try std.testing.expect(held(mutex));
    try std.testing.expect(tryEnter(mutex));
    leave(mutex);
    try std.testing.expect(held(mutex));
    leave(mutex);
    try std.testing.expect(notHeld(mutex));
}

test "single-thread mode uses nullable no-op internal mutexes" {
    var subsystem = Subsystem.init(std.testing.allocator);
    try subsystem.configure(.single_thread);
    subsystem.start();
    defer subsystem.stop();
    const mutex = try subsystem.alloc(.recursive);
    try std.testing.expectEqual(null, mutex);
    enter(mutex);
    try std.testing.expect(tryEnter(mutex));
    leave(mutex);
    try std.testing.expect(held(mutex));
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var subsystem = Subsystem.init(allocator);
    subsystem.start();
    defer subsystem.stop();
    const value = try subsystem.alloc(.recursive);
    defer subsystem.free(value);
}

test "dynamic mutex allocation has sticky and one-shot OOM coverage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
    var completed = false;
    for (0..4) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        allocationExercise(failing.allocator()) catch |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}

test "contended recursive mutex serializes workers" {
    var subsystem = Subsystem.init(std.testing.allocator);
    subsystem.start();
    defer subsystem.stop();
    const mutex = (try subsystem.alloc(.recursive)).?;
    defer subsystem.free(mutex);
    var counter: usize = 0;
    const Worker = struct {
        fn run(lock: *Mutex, value: *usize) void {
            for (0..10_000) |_| {
                lock.enter();
                lock.enter();
                value.* += 1;
                lock.leave();
                lock.leave();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ mutex, &counter });
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(usize, 40_000), counter);
}
