//! Global initialization/configuration coordinator for native infrastructure.
//!
//! Concurrent callers serialize, recursive initialization by the initializing
//! thread returns immediately, and shutdown unwinds memory then mutex state.

const std = @import("std");
pub const memory = @import("memory.zig");
pub const mutex = @import("mutex.zig");
pub const lookaside = @import("lookaside.zig");
pub const page_cache = @import("page_cache.zig");
pub const vfs = @import("vfs.zig");
pub const unix_vfs = @import("unix_vfs.zig");
pub const auto_extension = @import("auto_extension.zig");
pub const process_config = @import("process_config.zig");

pub const Hooks = struct {
    context: *anyopaque,
    builtinInitFn: ?*const fn () void = null,
    pcacheInitFn: ?*const fn (*anyopaque) c_int = null,
    pcacheShutdownFn: ?*const fn (*anyopaque) void = null,
    postInitFn: ?*const fn (*anyopaque) c_int = null,
    postMallocShutdownFn: ?*const fn (*anyopaque) void = null,
    initFn: *const fn (*anyopaque) c_int,
    shutdownFn: *const fn (*anyopaque) void,
};

var noop_context: u8 = 0;
fn noopInit(_: *anyopaque) c_int {
    return memory.ok;
}
fn noopShutdown(_: *anyopaque) void {}
pub fn noopHooks() Hooks {
    return .{ .context = &noop_context, .initFn = noopInit, .shutdownFn = noopShutdown };
}

pub const State = enum { uninitialized, initializing, initialized };

pub const Coordinator = struct {
    memory_manager: *memory.Manager,
    mutex_subsystem: *mutex.Subsystem,
    hooks: Hooks,
    state: State = .uninitialized,
    owner: u64 = 0,
    lookaside_slot_size: u16 = 1_200,
    lookaside_slot_count: u16 = 40,
    pcache_initialized: bool = false,
    state_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    state_changed: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn init(memory_manager: *memory.Manager, mutex_subsystem: *mutex.Subsystem, hooks: Hooks) Coordinator {
        return .{ .memory_manager = memory_manager, .mutex_subsystem = mutex_subsystem, .hooks = hooks };
    }

    fn threadId() u64 {
        return @intCast(std.Thread.getCurrentId());
    }
    fn lock(self: *Coordinator) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.state_lock) == .SUCCESS);
    }
    fn unlock(self: *Coordinator) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.state_lock) == .SUCCESS);
    }

    pub fn configureMode(self: *Coordinator, mode: mutex.Mode) error{Misuse}!void {
        self.lock();
        defer self.unlock();
        if (self.state != .uninitialized) return error.Misuse;
        try self.mutex_subsystem.configure(mode);
    }

    pub fn configureMutexMethods(self: *Coordinator, methods: mutex.MutexMethods) error{Misuse}!void {
        self.lock();
        defer self.unlock();
        if (self.state != .uninitialized) return error.Misuse;
        try self.mutex_subsystem.configureMethods(methods);
    }

    pub fn configureMemoryStatus(self: *Coordinator, enabled: bool) error{Misuse}!void {
        self.lock();
        defer self.unlock();
        if (self.state != .uninitialized) return error.Misuse;
        try self.memory_manager.configureMemoryStatus(enabled);
    }

    pub fn configurePageCache(self: *Coordinator, storage: ?*anyopaque, page_size: c_int, page_count: c_int) error{Misuse}!void {
        self.lock();
        defer self.unlock();
        if (self.state != .uninitialized) return error.Misuse;
        try self.memory_manager.configurePageCache(storage, page_size, page_count);
    }

    pub fn configureLookaside(self: *Coordinator, slot_size: u16, slot_count: u16) error{Misuse}!void {
        self.lock();
        defer self.unlock();
        if (self.state != .uninitialized) return error.Misuse;
        self.lookaside_slot_size = slot_size;
        self.lookaside_slot_count = slot_count;
    }

    pub fn configureBackend(self: *Coordinator, backend: memory.Backend) error{Misuse}!void {
        self.lock();
        defer self.unlock();
        if (self.state != .uninitialized) return error.Misuse;
        try self.memory_manager.configureBackend(backend);
    }

    /// Source `sqlite3_initialize()` process state machine.
    pub fn initialize(self: *Coordinator) c_int {
        const id = threadId();
        var mutex_attempted = false;
        self.lock();
        while (true) switch (self.state) {
            .initialized => {
                self.unlock();
                return memory.ok;
            },
            .initializing => {
                if (!mutex_attempted) {
                    self.unlock();
                    const mutex_result = self.mutex_subsystem.startLifecycle();
                    if (mutex_result != memory.ok) return mutex_result;
                    mutex_attempted = true;
                    self.lock();
                    continue;
                }
                if (self.owner == id) {
                    self.unlock();
                    return memory.ok;
                }
                std.debug.assert(std.c.pthread_cond_wait(&self.state_changed, &self.state_lock) == .SUCCESS);
            },
            .uninitialized => {
                self.state = .initializing;
                self.owner = id;
                self.unlock();
                break;
            },
        };

        var result: c_int = if (mutex_attempted) memory.ok else self.mutex_subsystem.startLifecycle();
        var init_mutex: ?mutex.Handle = null;
        const main_mutex = if (result == memory.ok)
            self.mutex_subsystem.allocHandle(.static_main) catch null
        else
            null;
        if (main_mutex) |value| {
            var handle = value;
            handle.enter();
        }
        if (result == memory.ok and !self.memory_manager.started) {
            const allocator_mutex = self.mutex_subsystem.allocHandle(.static_mem) catch blk: {
                result = memory.no_memory;
                break :blk null;
            };
            if (result == memory.ok) result = self.memory_manager.startWithMutex(allocator_mutex);
        }
        if (result == memory.ok) {
            init_mutex = self.mutex_subsystem.allocHandle(.recursive) catch blk: {
                result = memory.no_memory;
                break :blk null;
            };
        }
        if (main_mutex) |value| {
            var handle = value;
            handle.leave();
        }
        if (init_mutex) |*handle| handle.enter();
        defer {
            if (init_mutex) |*handle| handle.leave();
            self.mutex_subsystem.freeHandle(init_mutex);
        }
        if (result == memory.ok) {
            if (self.hooks.builtinInitFn) |callback| callback();
        }
        if (result == memory.ok and !self.pcache_initialized) {
            result = if (self.hooks.pcacheInitFn) |callback| callback(self.hooks.context) else memory.ok;
            if (result == memory.ok) self.pcache_initialized = true;
        }
        if (result == memory.ok) result = self.hooks.initFn(self.hooks.context);
        if (result == memory.ok) {
            result = if (self.hooks.postInitFn) |callback| callback(self.hooks.context) else memory.ok;
        }

        self.lock();
        self.owner = 0;
        self.state = if (result == memory.ok) .initialized else .uninitialized;
        std.debug.assert(std.c.pthread_cond_broadcast(&self.state_changed) == .SUCCESS);
        self.unlock();
        return result;
    }

    /// Source `sqlite3_shutdown()` reverse-order owner teardown.
    pub fn shutdown(self: *Coordinator) c_int {
        self.lock();
        if (self.state == .initializing) {
            self.unlock();
            return memory.misuse;
        }
        const fully_initialized = self.state == .initialized;
        if (!fully_initialized and !self.pcache_initialized and !self.memory_manager.started and !self.mutex_subsystem.initialized) {
            self.unlock();
            return memory.ok;
        }
        self.state = .initializing;
        self.owner = threadId();
        self.unlock();

        if (fully_initialized) self.hooks.shutdownFn(self.hooks.context);
        if (self.pcache_initialized) {
            if (self.hooks.pcacheShutdownFn) |callback| callback(self.hooks.context);
            self.pcache_initialized = false;
        }
        if (self.memory_manager.started) self.memory_manager.stop();
        if (self.hooks.postMallocShutdownFn) |callback| callback(self.hooks.context);
        _ = self.mutex_subsystem.stopLifecycle();

        self.lock();
        self.owner = 0;
        self.state = .uninitialized;
        std.debug.assert(std.c.pthread_cond_broadcast(&self.state_changed) == .SUCCESS);
        self.unlock();
        return memory.ok;
    }
};

pub var process_mutex_subsystem = mutex.Subsystem.init(std.heap.c_allocator);
pub const process_pcache = &page_cache.process_lifecycle;
pub var process_unix_vfs = unix_vfs.UnixVfs.initMode(std.heap.c_allocator, .posix);
pub var process_unix_adapter = unix_vfs.Adapter.init("unix", &process_unix_vfs);
pub var process_unix_none_vfs = unix_vfs.UnixVfs.initMode(std.heap.c_allocator, .none);
pub var process_unix_none_adapter = unix_vfs.Adapter.init("unix-none", &process_unix_none_vfs);
pub var process_unix_dotfile_vfs = unix_vfs.UnixVfs.initMode(std.heap.c_allocator, .dotfile);
pub var process_unix_dotfile_adapter = unix_vfs.Adapter.init("unix-dotfile", &process_unix_dotfile_vfs);
pub var process_unix_excl_vfs = unix_vfs.UnixVfs.initMode(std.heap.c_allocator, .exclusive);
pub var process_unix_excl_adapter = unix_vfs.Adapter.init("unix-excl", &process_unix_excl_vfs);
pub var process_mem_vfs = vfs.MemoryVfs.initMemdb(std.heap.c_allocator);
pub var process_mem_context = vfs.MemdbContext{ .native = &process_mem_vfs, .original = &process_unix_adapter.abi };
pub var process_mem_adapter = vfs.MemdbAdapter.init(&process_mem_context);
pub var process_os_initialized = false;

fn initializeProcessPcache(_: *anyopaque) c_int {
    const result = process_pcache.initialize(
        process_mutex_subsystem.coreMutexEnabled(),
        memory.process_manager.static_page,
        memory.process_manager.static_page_count,
    );
    if (result != memory.ok) return result;
    const group_mutex = process_mutex_subsystem.allocHandle(.static_lru) catch return memory.no_memory;
    const slot_mutex = process_mutex_subsystem.allocHandle(.static_pmem) catch return memory.no_memory;
    process_pcache.attachInfrastructure(&memory.process_manager, group_mutex, slot_mutex);
    return memory.ok;
}
fn setupProcessPcache(_: *anyopaque) c_int {
    process_pcache.setupBuffer(
        memory.process_manager.static_page,
        memory.process_manager.static_page_size,
        memory.process_manager.static_page_count,
    );
    return memory.ok;
}
fn shutdownProcessPcache(_: *anyopaque) void {
    process_pcache.shutdown();
}
fn initializeProcessOs(_: *anyopaque) c_int {
    return initializeOs();
}

/// Source `sqlite3_os_init()`: register every emitted Unix locking style in
/// source order, make POSIX Unix the default, and then register memdb.
pub fn initializeOs() c_int {
    if (process_os_initialized) return memory.ok;
    process_mem_vfs.vfs_name_manager = &memory.process_manager;
    vfs.registerProcessVfs(&process_unix_adapter.abi, true);
    vfs.registerProcessVfs(&process_unix_none_adapter.abi, false);
    vfs.registerProcessVfs(&process_unix_dotfile_adapter.abi, false);
    vfs.registerProcessVfs(&process_unix_excl_adapter.abi, false);
    vfs.registerProcessVfs(&process_mem_adapter.abi, false);
    process_os_initialized = true;
    return memory.ok;
}

fn shutdownProcessOs(_: *anyopaque) void {
    shutdownOs();
}

pub fn shutdownOs() void {
    process_os_initialized = false;
    auto_extension.reset();
}
fn clearProcessDirectories(_: *anyopaque) void {
    process_config.clearShutdownDirectories();
}
fn processHooks() Hooks {
    return .{
        .context = &noop_context,
        .pcacheInitFn = initializeProcessPcache,
        .pcacheShutdownFn = shutdownProcessPcache,
        .postInitFn = setupProcessPcache,
        .postMallocShutdownFn = clearProcessDirectories,
        .initFn = initializeProcessOs,
        .shutdownFn = shutdownProcessOs,
    };
}

pub var process_coordinator = Coordinator.init(&memory.process_manager, &process_mutex_subsystem, processHooks());

pub fn configureProcessMutexMethods(methods: mutex.MutexMethods) error{Misuse}!void {
    try process_coordinator.configureMutexMethods(methods);
}

pub fn initializeProcess() c_int {
    return process_coordinator.initialize();
}

/// Installs the process built-in registry initializer before entering the
/// source lifecycle state machine. Concurrent public callers may repeat this
/// with the same function identity; only the outer initializer invokes it.
pub fn initializeProcessWithBuiltins(initializer: *const fn () void) c_int {
    process_coordinator.lock();
    if (process_coordinator.hooks.builtinInitFn) |configured| {
        std.debug.assert(configured == initializer);
    } else if (process_coordinator.state == .uninitialized) {
        process_coordinator.hooks.builtinInitFn = initializer;
    } else {
        process_coordinator.unlock();
        return memory.misuse;
    }
    process_coordinator.unlock();
    return process_coordinator.initialize();
}

pub fn shutdownProcess() c_int {
    return process_coordinator.shutdown();
}

const HookProbe = struct {
    coordinator: ?*Coordinator = null,
    init_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    shutdown_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    result: c_int = memory.ok,
    recurse: bool = false,

    fn initHook(context: *anyopaque) c_int {
        const self: *HookProbe = @ptrCast(@alignCast(context));
        _ = self.init_count.fetchAdd(1, .monotonic);
        if (self.recurse) std.debug.assert(self.coordinator.?.initialize() == memory.ok);
        return self.result;
    }
    fn shutdownHook(context: *anyopaque) void {
        const self: *HookProbe = @ptrCast(@alignCast(context));
        _ = self.shutdown_count.fetchAdd(1, .monotonic);
    }
    fn hooks(self: *HookProbe) Hooks {
        return .{ .context = self, .initFn = initHook, .shutdownFn = shutdownHook };
    }
};

test "process coordinator owns memory mutex extension and directory lifecycle" {
    const Extension = struct {
        fn entry() callconv(.c) void {}
    };
    _ = shutdownProcess();
    try std.testing.expectEqual(memory.ok, auto_extension.add(Extension.entry));
    process_config.sqlite3_temp_directory = @ptrFromInt(8);
    process_config.sqlite3_data_directory = @ptrFromInt(16);
    try process_coordinator.configureMode(.serialized);
    try std.testing.expectEqual(memory.ok, initializeProcess());
    try std.testing.expect(process_mutex_subsystem.initialized);
    try std.testing.expect(memory.process_manager.started);
    try std.testing.expect(process_pcache.initialized);
    try std.testing.expect(process_pcache.slot_mutex.?.nativeMutex() == mutex.processStatic(.static_pmem));
    try std.testing.expect(memory.process_manager.pcache_lock.?.nativeMutex() == mutex.processStatic(.static_pmem));
    try std.testing.expect(process_os_initialized);
    try std.testing.expect(vfs.findProcessVfs(null) == &process_unix_adapter.abi);
    try std.testing.expect(vfs.findProcessVfs("unix-none") == &process_unix_none_adapter.abi);
    try std.testing.expect(vfs.findProcessVfs("unix-dotfile") == &process_unix_dotfile_adapter.abi);
    try std.testing.expect(vfs.findProcessVfs("unix-excl") == &process_unix_excl_adapter.abi);
    try std.testing.expect(vfs.findProcessVfs("memdb") == &process_mem_adapter.abi);
    var memdb_storage: [64]u8 align(16) = undefined;
    const memdb_file: *vfs.sqlite3_file = @ptrCast(&memdb_storage);
    try std.testing.expectEqual(vfs.OK, process_mem_adapter.abi.xOpen.?(&process_mem_adapter.abi, "/control", memdb_file, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB, null));
    var vfs_name: ?[*:0]u8 = null;
    try std.testing.expectEqual(vfs.OK, memdb_file.pMethods.?.xFileControl.?(memdb_file, vfs.FCNTL_VFSNAME, @ptrCast(&vfs_name)));
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(vfs_name.?), "memdb("));
    memory.process_manager.free(@ptrCast(vfs_name.?));
    try std.testing.expectEqual(vfs.OK, memdb_file.pMethods.?.xClose.?(memdb_file));
    try std.testing.expect(memory.process_manager.lock.?.nativeMutex() == mutex.processStatic(.static_mem));
    try std.testing.expectEqual(memory.ok, initializeProcess());
    try std.testing.expectEqual(memory.ok, shutdownProcess());
    try std.testing.expect(!process_mutex_subsystem.initialized);
    try std.testing.expect(!memory.process_manager.started);
    try std.testing.expect(!process_pcache.initialized);
    try std.testing.expect(!process_os_initialized);
    try std.testing.expectEqual(@as(usize, 0), auto_extension.count());
    try std.testing.expectEqual(null, process_config.sqlite3_temp_directory);
    try std.testing.expectEqual(null, process_config.sqlite3_data_directory);
    try std.testing.expectEqual(null, memory.process_manager.lock);
}

test "configured mutex methods participate in coordinator lifecycle" {
    const Probe = struct {
        var counts: [7]usize = .{0} ** 7;
        fn init() callconv(.c) c_int {
            counts[0] += 1;
            return 0;
        }
        fn end() callconv(.c) c_int {
            counts[1] += 1;
            return 0;
        }
        fn alloc(kind: c_int) callconv(.c) ?*anyopaque {
            counts[2] += 1;
            return @ptrFromInt(@as(usize, @intCast(kind)) + 16);
        }
        fn free(_: ?*anyopaque) callconv(.c) void {
            counts[3] += 1;
        }
        fn enter(_: ?*anyopaque) callconv(.c) void {
            counts[4] += 1;
        }
        fn tryEnter(_: ?*anyopaque) callconv(.c) c_int {
            counts[5] += 1;
            return 0;
        }
        fn leave(_: ?*anyopaque) callconv(.c) void {
            counts[6] += 1;
        }
    };
    Probe.counts = .{0} ** 7;
    const methods = mutex.MutexMethods{
        .xMutexInit = Probe.init,
        .xMutexEnd = Probe.end,
        .xMutexAlloc = Probe.alloc,
        .xMutexFree = Probe.free,
        .xMutexEnter = Probe.enter,
        .xMutexTry = Probe.tryEnter,
        .xMutexLeave = Probe.leave,
        .xMutexHeld = null,
        .xMutexNotheld = null,
    };
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var coordinator = Coordinator.init(&manager, &mutexes, noopHooks());
    try coordinator.configureMutexMethods(methods);
    try std.testing.expectEqual(memory.ok, coordinator.initialize());
    try std.testing.expect(manager.lock.?.nativeMutex() == null);
    const dynamic = mutexes.allocOpaque(.recursive);
    mutexes.enterOpaque(dynamic);
    try std.testing.expectEqual(@as(c_int, 0), mutexes.tryOpaque(dynamic));
    mutexes.leaveOpaque(dynamic);
    mutexes.freeOpaque(dynamic);
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
    try std.testing.expectEqual([_]usize{ 1, 1, 4, 2, 3, 1, 3 }, Probe.counts);
}

test "bounded initialize shutdown and reconfiguration loops" {
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var probe = HookProbe{};
    var coordinator = Coordinator.init(&manager, &mutexes, probe.hooks());
    probe.coordinator = &coordinator;
    for (0..100) |index| {
        try coordinator.configureMode(if (index % 2 == 0) .serialized else .multi_thread);
        try coordinator.configureMemoryStatus(index % 3 != 0);
        try coordinator.configureLookaside(@intCast(256 + index * 8), @intCast(20 + index));
        try std.testing.expectEqual(memory.ok, coordinator.initialize());
        try std.testing.expectError(error.Misuse, coordinator.configureMode(.single_thread));
        try std.testing.expectError(error.Misuse, coordinator.configureLookaside(1200, 40));
        try std.testing.expectEqual(memory.ok, coordinator.initialize());
        try std.testing.expectEqual(memory.ok, coordinator.shutdown());
        try std.testing.expectEqual(memory.ok, coordinator.shutdown());
    }
    try std.testing.expectEqual(@as(usize, 100), probe.init_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 100), probe.shutdown_count.load(.monotonic));
}

test "recursive initialization repeats mutex init without rerunning later hooks" {
    const MutexProbe = struct {
        var init_count: usize = 0;
        var end_count: usize = 0;
        fn init() callconv(.c) c_int {
            init_count += 1;
            return memory.ok;
        }
        fn end() callconv(.c) c_int {
            end_count += 1;
            return memory.ok;
        }
    };
    MutexProbe.init_count = 0;
    MutexProbe.end_count = 0;
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var probe = HookProbe{ .recurse = true };
    var coordinator = Coordinator.init(&manager, &mutexes, probe.hooks());
    probe.coordinator = &coordinator;
    var methods = mutex.noop_methods;
    methods.xMutexInit = MutexProbe.init;
    methods.xMutexEnd = MutexProbe.end;
    try coordinator.configureMutexMethods(methods);
    try std.testing.expectEqual(memory.ok, coordinator.initialize());
    try std.testing.expectEqual(@as(usize, 1), probe.init_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), MutexProbe.init_count);
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
    try std.testing.expectEqual(@as(usize, 1), MutexProbe.end_count);
}

test "recursive init-mutex allocation failure preserves prior layers and retries" {
    const Probe = struct {
        var fail_recursive = true;
        fn alloc(kind: c_int) callconv(.c) ?*anyopaque {
            if (fail_recursive and kind == @intFromEnum(mutex.Kind.recursive)) return null;
            return @ptrFromInt(@as(usize, @intCast(kind)) + 16);
        }
    };
    Probe.fail_recursive = true;
    var methods = mutex.noop_methods;
    methods.xMutexAlloc = Probe.alloc;
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var coordinator = Coordinator.init(&manager, &mutexes, noopHooks());
    try coordinator.configureMutexMethods(methods);
    try std.testing.expectEqual(memory.no_memory, coordinator.initialize());
    try std.testing.expectEqual(State.uninitialized, coordinator.state);
    try std.testing.expect(manager.started);
    try std.testing.expect(mutexes.initialized);
    Probe.fail_recursive = false;
    try std.testing.expectEqual(memory.ok, coordinator.initialize());
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
}

test "failed late initialization preserves completed layers and repeats mutex init on retry" {
    const MutexProbe = struct {
        var init_count: usize = 0;
        var end_count: usize = 0;
        fn init() callconv(.c) c_int {
            init_count += 1;
            return memory.ok;
        }
        fn end() callconv(.c) c_int {
            end_count += 1;
            return memory.ok;
        }
    };
    MutexProbe.init_count = 0;
    MutexProbe.end_count = 0;
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var probe = HookProbe{ .result = memory.no_memory };
    var coordinator = Coordinator.init(&manager, &mutexes, probe.hooks());
    probe.coordinator = &coordinator;
    var methods = mutex.noop_methods;
    methods.xMutexInit = MutexProbe.init;
    methods.xMutexEnd = MutexProbe.end;
    try coordinator.configureMutexMethods(methods);
    try std.testing.expectEqual(memory.no_memory, coordinator.initialize());
    try std.testing.expectEqual(@as(usize, 1), MutexProbe.init_count);
    try std.testing.expectEqual(State.uninitialized, coordinator.state);
    try std.testing.expect(manager.started);
    try std.testing.expect(mutexes.initialized);
    try std.testing.expect(coordinator.pcache_initialized);
    probe.result = memory.ok;
    try std.testing.expectEqual(memory.ok, coordinator.initialize());
    try std.testing.expectEqual(@as(usize, 2), MutexProbe.init_count);
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
    try std.testing.expectEqual(@as(usize, 1), MutexProbe.end_count);
}

test "built-in registration precedes PCache and repeats on late retry" {
    const Stages = struct {
        var events: [5]u8 = undefined;
        var count: usize = 0;
        var fail_os = true;
        fn record(event: u8) void {
            events[count] = event;
            count += 1;
        }
        fn builtins() void {
            record(1);
        }
        fn pcache(_: *anyopaque) c_int {
            record(2);
            return memory.ok;
        }
        fn os(_: *anyopaque) c_int {
            record(3);
            if (fail_os) return memory.no_memory;
            return memory.ok;
        }
    };
    Stages.count = 0;
    Stages.fail_os = true;
    var context: u8 = 0;
    const hooks = Hooks{
        .context = &context,
        .builtinInitFn = Stages.builtins,
        .pcacheInitFn = Stages.pcache,
        .initFn = Stages.os,
        .shutdownFn = noopShutdown,
    };
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var coordinator = Coordinator.init(&manager, &mutexes, hooks);
    try std.testing.expectEqual(memory.no_memory, coordinator.initialize());
    Stages.fail_os = false;
    try std.testing.expectEqual(memory.ok, coordinator.initialize());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 1, 3 }, Stages.events[0..Stages.count]);
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
}

test "pcache failure preserves earlier layers and skips OS until retry" {
    const Stages = struct {
        var pcache_result: c_int = memory.no_memory;
        var counts: [4]usize = .{0} ** 4;
        fn pcacheInit(_: *anyopaque) c_int {
            counts[0] += 1;
            return pcache_result;
        }
        fn pcacheShutdown(_: *anyopaque) void {
            counts[1] += 1;
        }
        fn osInit(_: *anyopaque) c_int {
            counts[2] += 1;
            return memory.ok;
        }
        fn osShutdown(_: *anyopaque) void {
            counts[3] += 1;
        }
    };
    Stages.pcache_result = memory.no_memory;
    Stages.counts = .{0} ** 4;
    var context: u8 = 0;
    const hooks = Hooks{
        .context = &context,
        .pcacheInitFn = Stages.pcacheInit,
        .pcacheShutdownFn = Stages.pcacheShutdown,
        .initFn = Stages.osInit,
        .shutdownFn = Stages.osShutdown,
    };
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var coordinator = Coordinator.init(&manager, &mutexes, hooks);
    try std.testing.expectEqual(memory.no_memory, coordinator.initialize());
    try std.testing.expect(manager.started and mutexes.initialized);
    try std.testing.expect(!coordinator.pcache_initialized);
    try std.testing.expectEqual([_]usize{ 1, 0, 0, 0 }, Stages.counts);
    Stages.pcache_result = memory.ok;
    try std.testing.expectEqual(memory.ok, coordinator.initialize());
    try std.testing.expect(coordinator.pcache_initialized);
    try std.testing.expectEqual([_]usize{ 2, 0, 1, 0 }, Stages.counts);
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
    try std.testing.expectEqual([_]usize{ 2, 1, 1, 1 }, Stages.counts);
}

test "concurrent initialization runs hook once" {
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.testing.allocator);
    var probe = HookProbe{};
    var coordinator = Coordinator.init(&manager, &mutexes, probe.hooks());
    probe.coordinator = &coordinator;
    const Worker = struct {
        fn run(value: *Coordinator) void {
            for (0..100) |_| std.debug.assert(value.initialize() == memory.ok);
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&coordinator});
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(usize, 1), probe.init_count.load(.monotonic));
    try std.testing.expectEqual(memory.ok, coordinator.shutdown());
}
