//! SQLite-compatible allocator facade, memory statistics, and heap limits.
//!
//! The low-level backend is configurable before initialization. The pinned
//! profile's `mem1.c` stores the rounded request in an eight-byte prefix because
//! HAVE_MALLOC_USABLE_SIZE is not selected.

const std = @import("std");
const builtin = @import("builtin");
const config_types = @import("internal/config_types.zig");
const mutex = @import("mutex.zig");
const limits = @import("build_profile").limits;
pub const max_allocation_size: u64 = limits.max_allocation_size;

pub const ok: c_int = 0;
pub const no_memory: c_int = 7;
pub const misuse: c_int = 21;

var test_release_memory_hook: ?*const fn () void = null;

/// The pinned profile omits SQLITE_ENABLE_MEMORY_MANAGEMENT.
pub fn releaseMemory(_: c_int) c_int {
    if (builtin.is_test) {
        if (test_release_memory_hook) |hook| hook();
    }
    return 0;
}

/// Deprecated compatibility hook; upstream is an unconditional no-op.
pub fn memoryAlarm() c_int {
    return ok;
}

/// ABI-exact shape of public `sqlite3_mem_methods`.
pub const MemMethods = config_types.MemMethods;

pub const MethodsBackend = struct {
    methods: MemMethods,

    pub fn init(methods: MemMethods) MethodsBackend {
        return .{ .methods = methods };
    }

    pub fn backend(self: *MethodsBackend) Backend {
        return .{
            .context = self,
            .mallocFn = methodsMalloc,
            .freeFn = methodsFree,
            .reallocFn = methodsRealloc,
            .sizeFn = methodsSize,
            .roundupFn = methodsRoundup,
            .initFn = methodsInit,
            .shutdownFn = methodsShutdown,
        };
    }
    fn cast(context: *anyopaque) *MethodsBackend {
        return @ptrCast(@alignCast(context));
    }
    fn methodsMalloc(context: *anyopaque, amount: usize) ?*anyopaque {
        return cast(context).methods.xMalloc.?(@intCast(amount));
    }
    fn methodsFree(context: *anyopaque, pointer: ?*anyopaque) void {
        cast(context).methods.xFree.?(pointer);
    }
    fn methodsRealloc(context: *anyopaque, pointer: ?*anyopaque, amount: usize) ?*anyopaque {
        return cast(context).methods.xRealloc.?(pointer, @intCast(amount));
    }
    fn methodsSize(context: *anyopaque, pointer: *anyopaque) usize {
        return @intCast(cast(context).methods.xSize.?(pointer));
    }
    fn methodsRoundup(context: *anyopaque, amount: usize) usize {
        return @intCast(cast(context).methods.xRoundup.?(@intCast(amount)));
    }
    fn methodsInit(context: *anyopaque) c_int {
        const methods = &cast(context).methods;
        return if (methods.xInit) |callback| callback(methods.pAppData) else ok;
    }
    fn methodsShutdown(context: *anyopaque) void {
        const methods = &cast(context).methods;
        if (methods.xShutdown) |callback| callback(methods.pAppData);
    }
};

pub const Backend = struct {
    context: *anyopaque,
    mallocFn: *const fn (*anyopaque, usize) ?*anyopaque,
    freeFn: *const fn (*anyopaque, ?*anyopaque) void,
    reallocFn: *const fn (*anyopaque, ?*anyopaque, usize) ?*anyopaque,
    sizeFn: *const fn (*anyopaque, *anyopaque) usize,
    roundupFn: *const fn (*anyopaque, usize) usize,
    initFn: *const fn (*anyopaque) c_int,
    shutdownFn: *const fn (*anyopaque) void,
};

var system_context: u8 = 0;
extern "c" fn malloc_usable_size(pointer: *anyopaque) usize;
const size_header_bytes = @sizeOf(u64);

fn rawFromPayload(pointer: *anyopaque) [*]u8 {
    return @as([*]u8, @ptrCast(pointer)) - size_header_bytes;
}
fn writeStoredSize(raw: [*]u8, size: usize) void {
    const header: *align(1) u64 = @ptrCast(raw);
    header.* = @intCast(size);
}
/// Source `sqlite3MemMalloc()`: retain the rounded request in the pinned
/// profile's eight-byte prefix so xSize can recover it without libc support.
fn systemMalloc(_: *anyopaque, size: usize) ?*anyopaque {
    const allocation_size = std.math.add(usize, size, size_header_bytes) catch return null;
    const raw_pointer = std.c.malloc(allocation_size) orelse return null;
    const raw: [*]u8 = @ptrCast(raw_pointer);
    writeStoredSize(raw, size);
    return @ptrCast(raw + size_header_bytes);
}
/// Source `sqlite3MemFree()`.
fn systemFree(_: *anyopaque, pointer: ?*anyopaque) void {
    const payload = pointer orelse return;
    std.c.free(@ptrCast(rawFromPayload(payload)));
}
/// Source `sqlite3MemRealloc()`: preserve the old allocation on failure.
fn systemRealloc(_: *anyopaque, pointer: ?*anyopaque, size: usize) ?*anyopaque {
    const payload = pointer orelse return systemMalloc(&system_context, size);
    const allocation_size = std.math.add(usize, size, size_header_bytes) catch return null;
    const resized = std.c.realloc(@ptrCast(rawFromPayload(payload)), allocation_size) orelse return null;
    const raw: [*]u8 = @ptrCast(resized);
    writeStoredSize(raw, size);
    return @ptrCast(raw + size_header_bytes);
}
/// Source `sqlite3MemSize()`.
fn systemSize(_: *anyopaque, pointer: *anyopaque) usize {
    const header: *align(1) const u64 = @ptrCast(rawFromPayload(pointer));
    return @intCast(header.*);
}
fn systemRoundup(_: *anyopaque, size: usize) usize {
    return (size + 7) & ~@as(usize, 7);
}
/// Source `sqlite3MemInit()` for the emitted non-Apple system allocator.
fn systemInit(_: *anyopaque) c_int {
    return ok;
}
fn systemShutdown(_: *anyopaque) void {}

/// Source `sqlite3MemSetDefault()`: install the complete mem1 method table.
pub fn systemBackend() Backend {
    return .{
        .context = &system_context,
        .mallocFn = systemMalloc,
        .freeFn = systemFree,
        .reallocFn = systemRealloc,
        .sizeFn = systemSize,
        .roundupFn = systemRoundup,
        .initFn = systemInit,
        .shutdownFn = systemShutdown,
    };
}

pub const FaultingBackend = struct {
    inner: Backend,
    fail_at: ?usize = null,
    sticky: bool = false,
    attempt_count: usize = 0,
    fired: bool = false,

    pub fn backend(self: *FaultingBackend) Backend {
        return .{
            .context = self,
            .mallocFn = faultMalloc,
            .freeFn = faultFree,
            .reallocFn = faultRealloc,
            .sizeFn = faultSize,
            .roundupFn = faultRoundup,
            .initFn = faultInit,
            .shutdownFn = faultShutdown,
        };
    }

    fn shouldFail(self: *FaultingBackend) bool {
        const index = self.attempt_count;
        self.attempt_count += 1;
        const target = self.fail_at orelse return false;
        if (index < target or (!self.sticky and self.fired)) return false;
        self.fired = true;
        return true;
    }
    fn cast(context: *anyopaque) *FaultingBackend {
        return @ptrCast(@alignCast(context));
    }
    fn faultMalloc(context: *anyopaque, amount: usize) ?*anyopaque {
        const self = cast(context);
        if (self.shouldFail()) return null;
        return self.inner.mallocFn(self.inner.context, amount);
    }
    fn faultFree(context: *anyopaque, pointer: ?*anyopaque) void {
        const self = cast(context);
        self.inner.freeFn(self.inner.context, pointer);
    }
    fn faultRealloc(context: *anyopaque, pointer: ?*anyopaque, amount: usize) ?*anyopaque {
        const self = cast(context);
        if (self.shouldFail()) return null;
        return self.inner.reallocFn(self.inner.context, pointer, amount);
    }
    fn faultSize(context: *anyopaque, pointer: *anyopaque) usize {
        const self = cast(context);
        return self.inner.sizeFn(self.inner.context, pointer);
    }
    fn faultRoundup(context: *anyopaque, amount: usize) usize {
        const self = cast(context);
        return self.inner.roundupFn(self.inner.context, amount);
    }
    fn faultInit(context: *anyopaque) c_int {
        const self = cast(context);
        return self.inner.initFn(self.inner.context);
    }
    fn faultShutdown(context: *anyopaque) void {
        const self = cast(context);
        self.inner.shutdownFn(self.inner.context);
    }
};

pub const Status = enum(u8) {
    memory_used = 0,
    pagecache_used = 1,
    pagecache_overflow = 2,
    scratch_used = 3,
    scratch_overflow = 4,
    malloc_size = 5,
    parser_stack = 6,
    pagecache_size = 7,
    scratch_size = 8,
    malloc_count = 9,
};

pub const StatusValue = struct { current: i64, highwater: i64 };

pub const Manager = struct {
    backend: Backend,
    lock: ?mutex.Handle = null,
    pcache_lock: ?mutex.Handle = null,
    started: bool = false,
    memory_status: bool = true,
    now_value: [10]i64 = .{0} ** 10,
    max_value: [10]i64 = .{0} ** 10,
    soft_limit: i64 = 0,
    hard_limit: i64 = 0,
    nearly_full: bool = false,
    static_page: ?*anyopaque = null,
    static_page_size: c_int = 0,
    static_page_count: c_int = 0,

    pub fn init(backend: Backend) Manager {
        return .{ .backend = backend };
    }

    fn enter(self: *Manager) void {
        if (self.lock) |*value| value.enter();
    }
    fn leave(self: *Manager) void {
        if (self.lock) |*value| value.leave();
    }

    fn alarmWhileUnlocked(self: *Manager, amount: c_int) void {
        self.leave();
        _ = releaseMemory(amount);
        self.enter();
    }

    pub fn configureBackend(self: *Manager, backend: Backend) error{Misuse}!void {
        if (self.started) return error.Misuse;
        self.backend = backend;
    }

    pub fn configureMemoryStatus(self: *Manager, enabled: bool) error{Misuse}!void {
        if (self.started) return error.Misuse;
        self.memory_status = enabled;
    }

    pub fn configurePageCache(self: *Manager, storage: ?*anyopaque, page_size: c_int, page_count: c_int) error{Misuse}!void {
        if (self.started) return error.Misuse;
        self.static_page = storage;
        self.static_page_size = page_size;
        self.static_page_count = page_count;
    }

    pub fn start(self: *Manager) c_int {
        return self.startWithMutex(.{ .native = mutex.processStatic(.static_mem) });
    }

    /// Source `sqlite3MallocInit()`.
    pub fn startWithMutex(self: *Manager, allocator_mutex: ?mutex.Handle) c_int {
        if (self.started) return ok;
        self.lock = allocator_mutex;
        if (self.static_page == null or self.static_page_size < 512 or self.static_page_count <= 0) {
            self.static_page = null;
            self.static_page_size = 0;
        }
        const result = self.backend.initFn(self.backend.context);
        if (result == ok) {
            self.started = true;
        } else {
            self.soft_limit = 0;
            self.hard_limit = 0;
            self.nearly_full = false;
            self.lock = null;
        }
        return result;
    }

    pub fn stop(self: *Manager) void {
        if (!self.started) return;
        self.backend.shutdownFn(self.backend.context);
        self.started = false;
        self.soft_limit = 0;
        self.hard_limit = 0;
        self.nearly_full = false;
        self.lock = null;
        self.pcache_lock = null;
    }

    pub fn setPcacheMutex(self: *Manager, pcache_mutex: ?mutex.Handle) void {
        self.pcache_lock = pcache_mutex;
    }

    fn statusEnter(self: *Manager, operation: Status) void {
        if (operation == .pagecache_used or operation == .pagecache_overflow or operation == .pagecache_size) {
            if (self.pcache_lock) |*value| return value.enter();
        }
        self.enter();
    }

    fn statusLeave(self: *Manager, operation: Status) void {
        if (operation == .pagecache_used or operation == .pagecache_overflow or operation == .pagecache_size) {
            if (self.pcache_lock) |*value| return value.leave();
        }
        self.leave();
    }

    pub fn statusValue(self: *const Manager, operation: Status) i64 {
        return self.now_value[@intFromEnum(operation)];
    }

    /// Source `sqlite3StatusUp()`; callers hold the operation's owner mutex.
    pub fn statusUp(self: *Manager, operation: Status, amount: i64) void {
        const index = @intFromEnum(operation);
        self.now_value[index] += amount;
        self.max_value[index] = @max(self.max_value[index], self.now_value[index]);
    }

    pub fn statusDown(self: *Manager, operation: Status, amount: i64) void {
        std.debug.assert(amount >= 0);
        self.now_value[@intFromEnum(operation)] -= amount;
    }

    /// Source `sqlite3StatusHighwater()`.
    pub fn statusHighwater(self: *Manager, operation: Status, value: i64) void {
        std.debug.assert(value >= 0);
        std.debug.assert(operation == .malloc_size or operation == .pagecache_size or operation == .parser_stack);
        const index = @intFromEnum(operation);
        self.max_value[index] = @max(self.max_value[index], value);
    }

    fn updateAllocation(self: *Manager, amount: usize) void {
        self.statusUp(.memory_used, @intCast(amount));
        self.statusUp(.malloc_count, 1);
    }

    pub fn allocZero(self: *Manager, requested: u64) ?*anyopaque {
        const pointer = self.alloc(requested) orelse return null;
        @memset(@as([*]u8, @ptrCast(pointer))[0..@intCast(requested)], 0);
        return pointer;
    }

    /// Source `mallocWithAlarm()`. The allocator mutex is held on entry.
    fn allocateWithAlarm(self: *Manager, request: usize) ?*anyopaque {
        const full = self.backend.roundupFn(self.backend.context, request);
        self.statusHighwater(.malloc_size, @intCast(request));
        if (self.soft_limit > 0 and self.statusValue(.memory_used) >= self.soft_limit - @as(i64, @intCast(full))) {
            self.nearly_full = true;
            self.alarmWhileUnlocked(@intCast(full));
            if (self.hard_limit > 0 and self.statusValue(.memory_used) >= self.hard_limit - @as(i64, @intCast(full))) return null;
        } else {
            self.nearly_full = false;
        }
        const pointer = self.backend.mallocFn(self.backend.context, full) orelse return null;
        self.updateAllocation(self.backend.sizeFn(self.backend.context, pointer));
        return pointer;
    }

    /// Source `sqlite3Malloc()`.
    pub fn alloc(self: *Manager, requested: u64) ?*anyopaque {
        std.debug.assert(self.started);
        if (requested == 0 or requested > max_allocation_size) return null;
        if (!self.memory_status) return self.backend.mallocFn(self.backend.context, @intCast(requested));
        self.enter();
        defer self.leave();
        const pointer = self.allocateWithAlarm(@intCast(requested)) orelse return null;
        std.debug.assert(@intFromPtr(pointer) & 7 == 0);
        return pointer;
    }

    pub fn size(self: *Manager, pointer: *anyopaque) usize {
        return self.backend.sizeFn(self.backend.context, pointer);
    }

    /// Source `sqlite3_free()` after public auto-initialization.
    pub fn free(self: *Manager, pointer: ?*anyopaque) void {
        const value = pointer orelse return;
        std.debug.assert(self.started);
        if (!self.memory_status) {
            self.backend.freeFn(self.backend.context, value);
            return;
        }
        self.enter();
        defer self.leave();
        self.statusDown(.memory_used, @intCast(self.backend.sizeFn(self.backend.context, value)));
        self.statusDown(.malloc_count, 1);
        self.backend.freeFn(self.backend.context, value);
    }

    /// Source `sqlite3Realloc()`.
    pub fn realloc(self: *Manager, old: ?*anyopaque, requested: u64) ?*anyopaque {
        std.debug.assert(self.started);
        const pointer = old orelse return self.alloc(requested);
        if (requested == 0) {
            self.free(pointer);
            return null;
        }
        if (requested > max_allocation_size) return null;
        const old_size = self.backend.sizeFn(self.backend.context, pointer);
        const new_size = self.backend.roundupFn(self.backend.context, @intCast(requested));
        if (old_size == new_size) return pointer;
        if (!self.memory_status) return self.backend.reallocFn(self.backend.context, pointer, new_size);
        self.enter();
        defer self.leave();
        self.statusHighwater(.malloc_size, @intCast(requested));
        const difference: i64 = @as(i64, @intCast(new_size)) - @as(i64, @intCast(old_size));
        const used_before_alarm = self.statusValue(.memory_used);
        if (difference > 0 and self.soft_limit > 0 and used_before_alarm >= self.soft_limit - difference) {
            self.alarmWhileUnlocked(@intCast(difference));
            if (self.hard_limit > 0 and used_before_alarm >= self.hard_limit - difference) return null;
        }
        const result = self.backend.reallocFn(self.backend.context, pointer, new_size) orelse return null;
        const actual_new = self.backend.sizeFn(self.backend.context, result);
        self.statusUp(.memory_used, @as(i64, @intCast(actual_new)) - @as(i64, @intCast(old_size)));
        std.debug.assert(@intFromPtr(result) & 7 == 0);
        return result;
    }

    /// Source `sqlite3_status64()` core query and reset operation.
    pub fn status(self: *Manager, operation: Status, reset: bool) StatusValue {
        self.statusEnter(operation);
        defer self.statusLeave(operation);
        const index = @intFromEnum(operation);
        const result: StatusValue = .{ .current = self.now_value[index], .highwater = self.max_value[index] };
        if (reset) self.max_value[index] = self.now_value[index];
        return result;
    }

    pub fn heapNearlyFull(self: *Manager) bool {
        self.enter();
        defer self.leave();
        return self.nearly_full;
    }

    /// Source `sqlite3_soft_heap_limit64()`. Release is deliberately invoked
    /// after dropping the allocator mutex because cache release may allocate.
    pub fn setSoftLimit(self: *Manager, value: i64) i64 {
        self.enter();
        const previous = self.soft_limit;
        if (value < 0) {
            self.leave();
            return previous;
        }
        var next = value;
        if (self.hard_limit > 0 and (next == 0 or next > self.hard_limit)) next = self.hard_limit;
        self.soft_limit = next;
        const used = self.statusValue(.memory_used);
        self.nearly_full = next > 0 and next <= used;
        self.leave();
        const excess = used - next;
        if (excess > 0) _ = releaseMemory(@intCast(@as(u64, @bitCast(excess)) & 0x7fff_ffff));
        return previous;
    }

    /// Source `sqlite3_hard_heap_limit64()`.
    pub fn setHardLimit(self: *Manager, value: i64) i64 {
        self.enter();
        defer self.leave();
        const previous = self.hard_limit;
        if (value >= 0) {
            self.hard_limit = value;
            if (value < self.soft_limit or self.soft_limit == 0) self.soft_limit = value;
        }
        return previous;
    }
};

/// Process-wide allocator state shared by public and internal SQLite paths.
pub var process_manager = Manager.init(systemBackend());

/// Return the process allocator after the global lifecycle owner has started it.
/// Internal SQLite allocation paths run only after sqlite3_initialize(); they
/// must not create a second, memory-only initialization path.
pub fn processManager() *Manager {
    if (builtin.is_test and !process_manager.started) std.debug.assert(process_manager.start() == ok);
    std.debug.assert(process_manager.started);
    return &process_manager;
}

/// Zig allocator view of SQLite's process allocation domain.
pub fn processAllocator() std.mem.Allocator {
    return .{ .ptr = processManager(), .vtable = &process_allocator_vtable };
}

const process_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = processAllocate,
    .resize = processResize,
    .remap = processRemap,
    .free = processFree,
};

fn processAllocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    _ = return_address;
    if (alignment.toByteUnits() > 8) return null;
    const manager: *Manager = @ptrCast(@alignCast(context));
    return @ptrCast(manager.alloc(length));
}

fn processResize(context: *anyopaque, buffer: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
    _ = alignment;
    _ = return_address;
    const manager: *Manager = @ptrCast(@alignCast(context));
    return new_length <= manager.size(buffer.ptr);
}

fn processRemap(context: *anyopaque, buffer: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
    _ = alignment;
    _ = return_address;
    const manager: *Manager = @ptrCast(@alignCast(context));
    return @ptrCast(manager.realloc(buffer.ptr, new_length));
}

fn processFree(context: *anyopaque, buffer: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    _ = alignment;
    _ = return_address;
    const manager: *Manager = @ptrCast(@alignCast(context));
    manager.free(buffer.ptr);
}

/// Transitional test-harness alias. Unlike the former implementation this
/// never starts the allocator and therefore cannot bypass global lifecycle.
pub fn ensureProcessManager() *Manager {
    return processManager();
}

test "sqlite3_mem_methods ABI layout" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(MemMethods));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(MemMethods));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MemMethods, "xMalloc"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(MemMethods, "xRoundup"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(MemMethods, "xShutdown"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(MemMethods, "pAppData"));
}

test "system allocator rounds, sizes, tracks, and resets highwater" {
    var manager = Manager.init(systemBackend());
    try std.testing.expectEqual(ok, manager.start());
    defer manager.stop();
    const pointer = manager.alloc(17).?;
    try std.testing.expect(@intFromPtr(pointer) & 7 == 0);
    try std.testing.expect(manager.size(pointer) >= 17);
    const used = manager.status(.memory_used, false);
    try std.testing.expectEqual(@as(i64, @intCast(manager.size(pointer))), used.current);
    try std.testing.expectEqual(@as(i64, 1), manager.status(.malloc_count, false).current);
    try std.testing.expectEqual(@as(i64, 17), manager.status(.malloc_size, false).highwater);
    try std.testing.expectEqual(StatusValue{ .current = 0, .highwater = 0 }, manager.status(.scratch_used, true));
    try std.testing.expectEqual(StatusValue{ .current = 0, .highwater = 0 }, manager.status(.scratch_overflow, true));
    try std.testing.expectEqual(StatusValue{ .current = 0, .highwater = 0 }, manager.status(.scratch_size, true));
    manager.free(pointer);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, true).current);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).highwater);
}

const MethodsProbe = struct { initialized: usize = 0, shutdown: usize = 0 };
fn probeMalloc(amount: c_int) callconv(.c) ?*anyopaque {
    return std.c.malloc(@intCast(amount));
}
fn probeFree(pointer: ?*anyopaque) callconv(.c) void {
    std.c.free(pointer);
}
fn probeRealloc(pointer: ?*anyopaque, amount: c_int) callconv(.c) ?*anyopaque {
    return std.c.realloc(pointer, @intCast(amount));
}
fn probeSize(pointer: ?*anyopaque) callconv(.c) c_int {
    return @intCast(malloc_usable_size(pointer.?));
}
fn probeRoundup(amount: c_int) callconv(.c) c_int {
    return (amount + 7) & ~@as(c_int, 7);
}
fn probeInit(context: ?*anyopaque) callconv(.c) c_int {
    const probe: *MethodsProbe = @ptrCast(@alignCast(context.?));
    probe.initialized += 1;
    return ok;
}
fn probeShutdown(context: ?*anyopaque) callconv(.c) void {
    const probe: *MethodsProbe = @ptrCast(@alignCast(context.?));
    probe.shutdown += 1;
}

test "configured method table is copied and receives lifecycle calls" {
    var probe = MethodsProbe{};
    var methods = MemMethods{
        .xMalloc = probeMalloc,
        .xFree = probeFree,
        .xRealloc = probeRealloc,
        .xSize = probeSize,
        .xRoundup = probeRoundup,
        .xInit = probeInit,
        .xShutdown = probeShutdown,
        .pAppData = &probe,
    };
    var adapter = MethodsBackend.init(methods);
    methods.xMalloc = null;
    var manager = Manager.init(adapter.backend());
    try std.testing.expectEqual(ok, manager.start());
    const pointer = manager.alloc(29).?;
    manager.free(pointer);
    manager.stop();
    try std.testing.expectEqual(@as(usize, 1), probe.initialized);
    try std.testing.expectEqual(@as(usize, 1), probe.shutdown);
}

test "zero, excessive, realloc, and hard-limit semantics" {
    var manager = Manager.init(systemBackend());
    try std.testing.expectEqual(ok, manager.start());
    defer manager.stop();
    try std.testing.expectEqual(null, manager.alloc(0));
    try std.testing.expectEqual(null, manager.alloc(max_allocation_size + 1));
    var pointer = manager.alloc(16).?;
    const bytes: [*]u8 = @ptrCast(pointer);
    bytes[0] = 0x5a;
    pointer = manager.realloc(pointer, 80).?;
    try std.testing.expectEqual(@as(u8, 0x5a), @as([*]u8, @ptrCast(pointer))[0]);
    const used = manager.status(.memory_used, false).current;
    _ = manager.setHardLimit(used + 8);
    try std.testing.expectEqual(null, manager.realloc(pointer, 4096));
    try std.testing.expectEqual(@as(u8, 0x5a), @as([*]u8, @ptrCast(pointer))[0]);
    manager.free(pointer);
}

fn faultExercise(fault: *FaultingBackend) void {
    var manager = Manager.init(fault.backend());
    std.debug.assert(manager.start() == ok);
    defer manager.stop();
    var first = manager.alloc(17);
    if (first) |pointer| @as([*]u8, @ptrCast(pointer))[0] = 0xa5;
    if (first) |pointer| {
        if (manager.realloc(pointer, 257)) |resized| first = resized;
    }
    const second = manager.alloc(33);
    if (second) |pointer| manager.free(pointer);
    if (first) |pointer| manager.free(pointer);
}

test "bounded one-shot and sticky allocation faults preserve ownership" {
    inline for ([_]bool{ false, true }) |sticky| {
        var reached_completion = false;
        for (0..8) |fail_index| {
            var fault = FaultingBackend{ .inner = systemBackend(), .fail_at = fail_index, .sticky = sticky };
            faultExercise(&fault);
            if (!fault.fired) {
                reached_completion = true;
                break;
            }
        }
        try std.testing.expect(reached_completion);
    }
}

test "process allocator uses the process STATIC_MEM identity" {
    var manager = Manager.init(systemBackend());
    try std.testing.expectEqual(ok, manager.start());
    try std.testing.expect(manager.lock.?.nativeMutex() == mutex.processStatic(.static_mem));
    manager.stop();
    try std.testing.expectEqual(null, manager.lock);
}

test "status primitives preserve current and highwater slots" {
    var manager = Manager.init(systemBackend());
    try std.testing.expectEqual(ok, manager.start());
    defer manager.stop();
    manager.enter();
    manager.statusUp(.pagecache_used, 4);
    manager.statusUp(.pagecache_used, 5);
    manager.statusDown(.pagecache_used, 3);
    manager.statusUp(.pagecache_used, -2);
    manager.statusHighwater(.pagecache_size, 12);
    manager.leave();

    try std.testing.expectEqual(StatusValue{ .current = 4, .highwater = 9 }, manager.status(.pagecache_used, false));
    try std.testing.expectEqual(StatusValue{ .current = 0, .highwater = 12 }, manager.status(.pagecache_size, false));
    _ = manager.status(.pagecache_used, true);
    try std.testing.expectEqual(StatusValue{ .current = 4, .highwater = 4 }, manager.status(.pagecache_used, false));
}

test "soft-limit alarm releases the allocator mutex around releaseMemory" {
    const Probe = struct {
        var manager: *Manager = undefined;
        var observed_unlocked = false;

        fn run() void {
            const native = manager.lock.?.nativeMutex().?;
            if (std.c.pthread_mutex_trylock(&native.native) == .SUCCESS) {
                observed_unlocked = true;
                std.debug.assert(std.c.pthread_mutex_unlock(&native.native) == .SUCCESS);
            }
        }
    };

    var manager = Manager.init(systemBackend());
    try std.testing.expectEqual(ok, manager.start());
    defer manager.stop();
    Probe.manager = &manager;
    Probe.observed_unlocked = false;
    test_release_memory_hook = Probe.run;
    defer test_release_memory_hook = null;
    _ = manager.setSoftLimit(1);
    const allocation = manager.alloc(8).?;
    defer manager.free(allocation);
    try std.testing.expect(Probe.observed_unlocked);
}

test "allocator initialization validates static page-cache configuration" {
    var storage: [2048]u8 align(8) = undefined;
    var valid = Manager.init(systemBackend());
    try valid.configurePageCache(&storage, 512, 4);
    try std.testing.expectEqual(ok, valid.start());
    try std.testing.expect(valid.static_page == @as(*anyopaque, @ptrCast(&storage)));
    try std.testing.expectEqual(@as(c_int, 512), valid.static_page_size);
    try std.testing.expectEqual(@as(c_int, 4), valid.static_page_count);
    valid.stop();

    var invalid = Manager.init(systemBackend());
    try invalid.configurePageCache(&storage, 511, 4);
    try std.testing.expectEqual(ok, invalid.start());
    try std.testing.expectEqual(null, invalid.static_page);
    try std.testing.expectEqual(@as(c_int, 0), invalid.static_page_size);
    try std.testing.expectEqual(@as(c_int, 4), invalid.static_page_count);
    try std.testing.expectError(error.Misuse, invalid.configurePageCache(&storage, 512, 4));
    invalid.stop();
}

test "failed backend initialization clears allocator-local state" {
    const Failing = struct {
        fn init(_: *anyopaque) c_int {
            return no_memory;
        }
    };
    var backend = systemBackend();
    backend.initFn = Failing.init;
    var manager = Manager.init(backend);
    manager.soft_limit = 12;
    manager.hard_limit = 24;
    manager.nearly_full = true;
    try std.testing.expectEqual(no_memory, manager.start());
    try std.testing.expect(!manager.started);
    try std.testing.expectEqual(@as(i64, 0), manager.soft_limit);
    try std.testing.expectEqual(@as(i64, 0), manager.hard_limit);
    try std.testing.expect(!manager.nearly_full);
}

test "memory status configuration is initialization-only" {
    var manager = Manager.init(systemBackend());
    try manager.configureMemoryStatus(false);
    try std.testing.expectEqual(ok, manager.start());
    defer manager.stop();
    try std.testing.expectError(error.Misuse, manager.configureMemoryStatus(true));
    const pointer = manager.alloc(9).?;
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    manager.free(pointer);
}
