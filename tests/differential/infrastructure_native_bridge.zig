const std = @import("std");
const global = @import("infrastructure");
const memory = global.memory;
const lookaside = global.lookaside;
const mutex = global.mutex;
const vfs = global.vfs;

fn emit(output: [*]u8, capacity: c_int, comptime format: []const u8, args: anytype) c_int {
    const buffer = output[0..@intCast(capacity)];
    const text = std.fmt.bufPrint(buffer, format, args) catch return -1;
    return @intCast(text.len);
}

pub export fn probe_memory_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var manager = memory.Manager.init(memory.systemBackend());
    var page: [2048]u8 align(8) = undefined;
    manager.configurePageCache(&page, 511, 4) catch unreachable;
    const rc = manager.start();
    const invalid_page_null = @intFromBool(manager.static_page == null);
    const invalid_page_size = manager.static_page_size;
    const invalid_page_count = manager.static_page_count;
    _ = manager.status(.memory_used, true);
    _ = manager.status(.malloc_count, true);
    _ = manager.status(.malloc_size, true);
    var pointer = manager.alloc(17).?;
    const size1 = manager.size(pointer);
    const used1 = manager.status(.memory_used, false).current;
    const count1 = manager.status(.malloc_count, false).current;
    const request_high = manager.status(.malloc_size, false).highwater;
    @as([*]u8, @ptrCast(pointer))[0] = 0x5a;
    if (manager.realloc(pointer, 257)) |resized| pointer = resized;
    const size2 = manager.size(pointer);
    const used2 = manager.status(.memory_used, false).current;
    const preserve1 = @intFromBool(@as([*]u8, @ptrCast(pointer))[0] == 0x5a);
    _ = manager.setHardLimit(used2 + 8);
    const failed = @intFromBool(manager.realloc(pointer, 4096) == null);
    const preserve2 = @intFromBool(@as([*]u8, @ptrCast(pointer))[0] == 0x5a);
    _ = manager.setHardLimit(0);
    manager.free(pointer);
    const used0 = manager.status(.memory_used, false).current;
    const count0 = manager.status(.malloc_count, false).current;
    const config_misuse: c_int = if (manager.configureMemoryStatus(false)) |_| memory.ok else |_| memory.misuse;
    manager.stop();
    manager.stop();
    manager.configurePageCache(&page, 512, 4) catch unreachable;
    _ = manager.start();
    const valid_page = @intFromBool(manager.static_page == @as(*anyopaque, @ptrCast(&page)));
    const valid_page_size = manager.static_page_size;
    const valid_page_count = manager.static_page_count;
    manager.stop();
    return emit(output, capacity, "M\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t0\t0\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        rc,                size1,              used1,      count1,          request_high,     size2,         used2,
        preserve1,         failed,             preserve2,  used0,           count0,           config_misuse, invalid_page_null,
        invalid_page_size, invalid_page_count, valid_page, valid_page_size, valid_page_count,
    });
}

const AllocatorEventProbe = struct {
    events: [256]u8 = undefined,
    count: usize = 0,

    fn event(self: *AllocatorEventProbe, value: u8) void {
        if (self.count < self.events.len) {
            self.events[self.count] = value;
            self.count += 1;
        }
    }
    fn reset(self: *AllocatorEventProbe) void {
        self.count = 0;
    }
    fn backend(self: *AllocatorEventProbe) memory.Backend {
        return .{ .context = self, .mallocFn = allocMalloc, .freeFn = allocFree, .reallocFn = allocRealloc, .sizeFn = allocSize, .roundupFn = allocRoundup, .initFn = allocInit, .shutdownFn = allocShutdown };
    }
    fn cast(context: *anyopaque) *AllocatorEventProbe {
        return @ptrCast(@alignCast(context));
    }
    fn allocMalloc(context: *anyopaque, amount: usize) ?*anyopaque {
        const self = cast(context);
        self.event('A');
        const base = std.c.malloc(amount + 8) orelse return null;
        const header: *i64 = @ptrCast(@alignCast(base));
        header.* = @intCast(amount);
        return @ptrFromInt(@intFromPtr(base) + 8);
    }
    fn allocFree(context: *anyopaque, pointer: ?*anyopaque) void {
        cast(context).event('F');
        if (pointer) |value| std.c.free(@ptrFromInt(@intFromPtr(value) - 8));
    }
    fn allocRealloc(context: *anyopaque, pointer: ?*anyopaque, amount: usize) ?*anyopaque {
        const self = cast(context);
        self.event('X');
        const base: ?*anyopaque = if (pointer) |value| @ptrFromInt(@intFromPtr(value) - 8) else null;
        const replacement = std.c.realloc(base, amount + 8) orelse return null;
        const header: *i64 = @ptrCast(@alignCast(replacement));
        header.* = @intCast(amount);
        return @ptrFromInt(@intFromPtr(replacement) + 8);
    }
    fn allocSize(context: *anyopaque, pointer: *anyopaque) usize {
        cast(context).event('S');
        const header: *const i64 = @ptrFromInt(@intFromPtr(pointer) - 8);
        return @intCast(header.*);
    }
    fn allocRoundup(context: *anyopaque, amount: usize) usize {
        cast(context).event('R');
        return (amount + 7) & ~@as(usize, 7);
    }
    fn allocInit(_: *anyopaque) c_int {
        return 0;
    }
    fn allocShutdown(_: *anyopaque) void {}
};

var allocator_event_probe: ?*AllocatorEventProbe = null;
fn allocatorMutexInit() callconv(.c) c_int {
    return 0;
}
fn allocatorMutexEnd() callconv(.c) c_int {
    return 0;
}
fn allocatorMutexAlloc(_: c_int) callconv(.c) ?*anyopaque {
    return @ptrFromInt(8);
}
fn allocatorMutexFree(_: ?*anyopaque) callconv(.c) void {}
fn allocatorMutexEnter(_: ?*anyopaque) callconv(.c) void {
    allocator_event_probe.?.event('E');
}
fn allocatorMutexTry(_: ?*anyopaque) callconv(.c) c_int {
    allocator_event_probe.?.event('T');
    return 0;
}
fn allocatorMutexLeave(_: ?*anyopaque) callconv(.c) void {
    allocator_event_probe.?.event('L');
}
fn allocatorMutexHeld(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}
fn allocatorMutexNotheld(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub export fn probe_allocator_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var probe = AllocatorEventProbe{};
    allocator_event_probe = &probe;
    defer allocator_event_probe = null;
    var adapter = mutex.MethodsAdapter.init(.{
        .xMutexInit = allocatorMutexInit,
        .xMutexEnd = allocatorMutexEnd,
        .xMutexAlloc = allocatorMutexAlloc,
        .xMutexFree = allocatorMutexFree,
        .xMutexEnter = allocatorMutexEnter,
        .xMutexTry = allocatorMutexTry,
        .xMutexLeave = allocatorMutexLeave,
        .xMutexHeld = allocatorMutexHeld,
        .xMutexNotheld = allocatorMutexNotheld,
    });
    var manager = memory.Manager.init(probe.backend());
    _ = manager.startWithMutex(.{ .configured = .{ .adapter = &adapter, .pointer = @ptrFromInt(8) } });
    probe.reset();
    manager.soft_limit = 64;
    const first = manager.alloc(17).?;
    const size1 = manager.size(first);
    @as([*]u8, @ptrCast(first))[0] = 0x5a;
    const second = manager.alloc(33).?;
    const size2 = manager.size(second);
    const used = manager.statusValue(.memory_used);
    const near = @intFromBool(manager.nearly_full);
    manager.hard_limit = used + 8;
    const failed = @intFromBool(manager.realloc(first, 80) == null);
    const preserve = @intFromBool(@as([*]u8, @ptrCast(first))[0] == 0x5a);
    manager.free(first);
    manager.free(second);
    const used_end = manager.statusValue(.memory_used);
    const count_end = manager.statusValue(.malloc_count);
    const high = manager.max_value[@intFromEnum(memory.Status.malloc_size)];
    const events = probe.events[0..probe.count];
    manager.stop();
    return emit(output, capacity, "A\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        events, size1, size2, used, near, failed, preserve, used_end, count_end, high,
    });
}

pub export fn probe_lookaside_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var manager = memory.Manager.init(memory.systemBackend());
    _ = manager.start();
    var arena = lookaside.Lookaside.init(&manager);
    var storage: [4096]u8 align(8) = undefined;
    var storage2: [256]u8 align(8) = undefined;
    arena.configure(null, 1200, 40) catch unreachable;
    const default_size = arena.big_size;
    const default_slots = arena.slot_count;
    const config_rc: c_int = if (arena.configure(&storage, 512, 8)) |_| 0 else |_| 7;
    const small = arena.alloc(64).?;
    const big = arena.alloc(400).?;
    const small_is = @intFromBool(arena.isLookaside(small));
    const big_is = @intFromBool(arena.isLookaside(big));
    const busy: c_int = if (arena.configure(null, 128, 2)) |_| 0 else |err| switch (err) {
        error.Busy => 5,
        error.OutOfMemory => 7,
    };
    @as([*]u8, @ptrCast(big))[0] = 0x7b;
    const grown = arena.realloc(big, 1000).?;
    const grown_is = @intFromBool(arena.isLookaside(grown));
    const preserve = @intFromBool(@as([*]u8, @ptrCast(grown))[0] == 0x7b);
    arena.free(grown);
    arena.free(small);
    const used = arena.used(false);
    const hit = arena.counter(.hit, false);
    const miss_size = arena.counter(.miss_size, false);
    arena.configure(&storage2, 128, 2) catch unreachable;
    const a = arena.alloc(100).?;
    const b = arena.alloc(100).?;
    const c = arena.alloc(100).?;
    const c_is = @intFromBool(arena.isLookaside(c));
    arena.free(c);
    arena.free(b);
    arena.free(a);
    const miss_full = arena.counter(.miss_full, false);
    arena.deinit();
    manager.stop();
    return emit(output, capacity, "L\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        config_rc,    default_size,   default_slots, small_is,  big_is, busy,      grown_is, preserve,
        used.current, used.highwater, hit,           miss_size, c_is,   miss_full,
    });
}

pub export fn probe_mutex_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var subsystem = mutex.Subsystem.init(std.heap.c_allocator);
    subsystem.configure(.serialized) catch unreachable;
    subsystem.start();
    const recursive = (subsystem.alloc(.recursive) catch unreachable).?;
    recursive.enter();
    const try_result: c_int = if (recursive.tryEnter()) 0 else 5;
    recursive.leave();
    recursive.leave();
    const static1 = subsystem.alloc(.static_mem) catch unreachable;
    const static2 = subsystem.alloc(.static_mem) catch unreachable;
    const static_equal = @intFromBool(static1 == static2);
    const Probe = struct {
        fn run(lock: *mutex.Mutex, result: *c_int) void {
            result.* = if (lock.tryEnter()) 0 else 5;
            if (result.* == 0) lock.leave();
        }
    };
    recursive.enter();
    var busy: c_int = -1;
    var thread = std.Thread.spawn(.{}, Probe.run, .{ recursive, &busy }) catch unreachable;
    thread.join();
    recursive.leave();
    subsystem.free(recursive);
    subsystem.stop();

    subsystem.configure(.single_thread) catch unreachable;
    subsystem.start();
    const single_null = @intFromBool((subsystem.alloc(.static_main) catch unreachable) == null);
    subsystem.stop();
    subsystem.configure(.multi_thread) catch unreachable;
    subsystem.start();
    const multi_nonnull = @intFromBool((subsystem.alloc(.static_main) catch unreachable) != null);
    subsystem.stop();
    subsystem.configure(.serialized) catch unreachable;
    subsystem.start();
    const serial_nonnull = @intFromBool((subsystem.alloc(.static_main) catch unreachable) != null);
    subsystem.stop();
    return emit(output, capacity, "X\t0\t0\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        try_result, static_equal, busy, single_null, multi_nonnull, serial_nonnull,
    });
}

var method_counts: [4]usize = .{0} ** 4;
fn customMalloc(amount: c_int) callconv(.c) ?*anyopaque {
    const base = std.c.malloc(@as(usize, @intCast(amount)) + 8) orelse return null;
    const header: *i64 = @ptrCast(@alignCast(base));
    header.* = amount;
    return @ptrFromInt(@intFromPtr(base) + 8);
}
fn customFree(pointer: ?*anyopaque) callconv(.c) void {
    if (pointer) |value| std.c.free(@ptrFromInt(@intFromPtr(value) - 8));
}
fn customRealloc(pointer: ?*anyopaque, amount: c_int) callconv(.c) ?*anyopaque {
    const base: ?*anyopaque = if (pointer) |value| @ptrFromInt(@intFromPtr(value) - 8) else null;
    const replacement = std.c.realloc(base, @as(usize, @intCast(amount)) + 8) orelse return null;
    const header: *i64 = @ptrCast(@alignCast(replacement));
    header.* = amount;
    return @ptrFromInt(@intFromPtr(replacement) + 8);
}
fn customSize(pointer: ?*anyopaque) callconv(.c) c_int {
    const header: *const i64 = @ptrFromInt(@intFromPtr(pointer.?) - 8);
    return @intCast(header.*);
}
fn customRound(amount: c_int) callconv(.c) c_int {
    return (amount + 7) & ~@as(c_int, 7);
}
fn customMemInit(_: ?*anyopaque) callconv(.c) c_int {
    method_counts[0] += 1;
    return 0;
}
fn customMemEnd(_: ?*anyopaque) callconv(.c) void {
    method_counts[1] += 1;
}
fn customMutexInit() callconv(.c) c_int {
    method_counts[2] += 1;
    return 0;
}
fn customMutexEnd() callconv(.c) c_int {
    method_counts[3] += 1;
    return 0;
}
fn customMutexAlloc(_: c_int) callconv(.c) ?*anyopaque {
    return @ptrFromInt(8);
}
fn customMutexFree(_: ?*anyopaque) callconv(.c) void {}
fn customMutexEnter(_: ?*anyopaque) callconv(.c) void {}
fn customMutexTry(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}
fn customMutexLeave(_: ?*anyopaque) callconv(.c) void {}
fn customMutexHeld(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}
fn customMutexNotheld(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub export fn probe_methods_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    method_counts = .{0} ** 4;
    var mem_methods = memory.MemMethods{
        .xMalloc = customMalloc,
        .xFree = customFree,
        .xRealloc = customRealloc,
        .xSize = customSize,
        .xRoundup = customRound,
        .xInit = customMemInit,
        .xShutdown = customMemEnd,
        .pAppData = null,
    };
    var mem_adapter = memory.MethodsBackend.init(mem_methods);
    mem_methods.xMalloc = null;
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.heap.c_allocator);
    var coordinator = global.Coordinator.init(&manager, &mutexes, global.noopHooks());
    coordinator.configureBackend(mem_adapter.backend()) catch unreachable;

    var mutex_methods = mutex.MutexMethods{
        .xMutexInit = customMutexInit,
        .xMutexEnd = customMutexEnd,
        .xMutexAlloc = customMutexAlloc,
        .xMutexFree = customMutexFree,
        .xMutexEnter = customMutexEnter,
        .xMutexTry = customMutexTry,
        .xMutexLeave = customMutexLeave,
        .xMutexHeld = customMutexHeld,
        .xMutexNotheld = customMutexNotheld,
    };
    coordinator.configureMutexMethods(mutex_methods) catch unreachable;
    mutex_methods.xMutexAlloc = null;
    _ = coordinator.initialize();
    var pointer = manager.alloc(17).?;
    const size1 = manager.size(pointer);
    pointer = manager.realloc(pointer, 257).?;
    const size2 = manager.size(pointer);
    manager.free(pointer);
    const value = mutexes.allocOpaque(.recursive);
    mutexes.enterOpaque(value);
    const try_result = mutexes.tryOpaque(value);
    mutexes.leaveOpaque(value);
    mutexes.leaveOpaque(value);
    mutexes.freeOpaque(value);
    _ = coordinator.shutdown();
    return emit(output, capacity, "D\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        method_counts[0], method_counts[1], size1, size2, method_counts[2], method_counts[3], try_result,
    });
}

pub export fn probe_memdb_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var native = vfs.MemoryVfs.initMemdb(std.heap.c_allocator);
    defer native.deinit();
    var original_native = vfs.MemoryVfs.init(std.heap.c_allocator);
    defer original_native.deinit();
    var original_adapter = vfs.AbiAdapter.init("original", &original_native);
    var context = vfs.MemdbContext{ .native = &native, .original = &original_adapter.abi };
    var adapter = vfs.MemdbAdapter.init(&context);
    const flags = vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB;
    var storage_a: [64]u8 align(16) = undefined;
    var storage_b: [64]u8 align(16) = undefined;
    const a: *vfs.sqlite3_file = @ptrCast(&storage_a);
    const b: *vfs.sqlite3_file = @ptrCast(&storage_b);
    var out_flags: c_int = 0;
    _ = adapter.abi.xOpen.?(&adapter.abi, "/shared", a, flags, &out_flags);
    _ = adapter.abi.xOpen.?(&adapter.abi, "/shared", b, flags, null);
    const methods = a.pMethods.?;
    const tail = @as(c_int, @intFromBool(methods.xCheckReservedLock == null)) |
        (@as(c_int, @intFromBool(methods.xSectorSize == null)) << 1) |
        (@as(c_int, @intFromBool(methods.xShmMap == null)) << 2) |
        (@as(c_int, @intFromBool(methods.xShmLock == null)) << 3) |
        (@as(c_int, @intFromBool(methods.xShmBarrier == null)) << 4) |
        (@as(c_int, @intFromBool(methods.xShmUnmap == null)) << 5) |
        (@as(c_int, @intFromBool(methods.xFetch != null)) << 6) |
        (@as(c_int, @intFromBool(methods.xUnfetch != null)) << 7);
    const device = methods.xDeviceCharacteristics.?(a);
    const write_rc = methods.xWrite.?(a, "abc".ptr, 3, 0);
    var bytes: [3]u8 = .{ 0, 0, 0 };
    const read_rc = methods.xRead.?(b, &bytes, 3, 0);
    const packed_value = (@as(c_int, bytes[0]) << 16) | (@as(c_int, bytes[1]) << 8) | bytes[2];
    const lock_a = methods.xLock.?(a, vfs.LOCK_SHARED);
    const lock_b = methods.xLock.?(b, vfs.LOCK_SHARED);
    const reserved_a = methods.xLock.?(a, vfs.LOCK_RESERVED);
    const reserved_b = methods.xLock.?(b, vfs.LOCK_RESERVED);
    const exclusive_busy = methods.xLock.?(a, vfs.LOCK_EXCLUSIVE);
    const unlock_b = methods.xUnlock.?(b, vfs.LOCK_NONE);
    const exclusive_a = methods.xLock.?(a, vfs.LOCK_EXCLUSIVE);
    var fetched: ?*anyopaque = @ptrFromInt(1);
    const fetch_rc = methods.xFetch.?(a, 0, 3, &fetched);
    const fetch_null = @intFromBool(fetched == null);
    const truncate_rc = methods.xTruncate.?(a, 4);
    const sync_rc = methods.xSync.?(a, 0);
    var limit: i64 = 4;
    const control4 = methods.xFileControl.?(a, vfs.FCNTL_SIZE_LIMIT, &limit);
    const write6 = methods.xWrite.?(a, "def".ptr, 3, 3);
    var size: i64 = 0;
    _ = methods.xFileSize.?(a, &size);
    const write_full = methods.xWrite.?(a, "g".ptr, 1, 6);
    _ = methods.xFileSize.?(a, &size);
    limit = 2;
    const control2 = methods.xFileControl.?(a, vfs.FCNTL_SIZE_LIMIT, &limit);
    var query: i64 = -1;
    const control_query = methods.xFileControl.?(a, vfs.FCNTL_SIZE_LIMIT, &query);
    var vfs_name: ?[*:0]u8 = null;
    const name_rc = methods.xFileControl.?(a, vfs.FCNTL_VFSNAME, @ptrCast(&vfs_name));
    const name_text = std.mem.span(vfs_name.?);
    const name_prefix = @intFromBool(std.mem.startsWith(u8, name_text, "memdb(") and std.mem.endsWith(u8, name_text, ",6)"));
    native.allocator.free(name_text);
    var access_out: c_int = 1;
    const access_rc = adapter.abi.xAccess.?(&adapter.abi, "/shared", vfs.ACCESS_EXISTS, &access_out);

    var private_storage_a: [64]u8 align(16) = undefined;
    var private_storage_b: [64]u8 align(16) = undefined;
    const private_a: *vfs.sqlite3_file = @ptrCast(&private_storage_a);
    const private_b: *vfs.sqlite3_file = @ptrCast(&private_storage_b);
    _ = adapter.abi.xOpen.?(&adapter.abi, "private", private_a, flags, null);
    _ = adapter.abi.xOpen.?(&adapter.abi, "private", private_b, flags, null);
    const private_write = private_a.pMethods.?.xWrite.?(private_a, "x".ptr, 1, 0);
    var private_byte: [1]u8 = .{1};
    const private_read = private_b.pMethods.?.xRead.?(private_b, &private_byte, 1, 0);
    const private_zero = @intFromBool(private_byte[0] == 0);
    _ = private_a.pMethods.?.xClose.?(private_a);
    _ = private_b.pMethods.?.xClose.?(private_b);
    _ = b.pMethods.?.xClose.?(b);
    const alive = a.pMethods.?.xRead.?(a, &bytes, 3, 0);
    _ = a.pMethods.?.xClose.?(a);
    var fresh_storage: [64]u8 align(16) = undefined;
    const fresh: *vfs.sqlite3_file = @ptrCast(&fresh_storage);
    _ = adapter.abi.xOpen.?(&adapter.abi, "/shared", fresh, flags, null);
    const reopen = fresh.pMethods.?.xRead.?(fresh, &private_byte, 1, 0);
    _ = fresh.pMethods.?.xClose.?(fresh);
    const buffer = output[0..@intCast(capacity)];
    const first = std.fmt.bufPrint(buffer, "Q\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{
        adapter.abi.iVersion, @intFromBool(out_flags & vfs.OPEN_MEMORY != 0), methods.iVersion, tail,     device,
        write_rc,             read_rc,                                        packed_value,     lock_a,   lock_b,
        reserved_a,           reserved_b,                                     exclusive_busy,   unlock_b, exclusive_a,
        fetch_rc,             fetch_null,                                     truncate_rc,      sync_rc,  control4,
    }) catch return -1;
    const second = std.fmt.bufPrint(buffer[first.len..], "\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @as(i64, 4), write6,      @as(i64, 6), write_full, size,          control2,     limit,        control_query, query,
        name_rc,     name_prefix, access_rc,   access_out, private_write, private_read, private_zero, alive,         reopen,
    }) catch return -1;
    return @intCast(first.len + second.len);
}

pub export fn probe_global_trace(output: [*]u8, capacity: c_int) callconv(.c) c_int {
    var manager = memory.Manager.init(memory.systemBackend());
    var mutexes = mutex.Subsystem.init(std.heap.c_allocator);
    var coordinator = global.Coordinator.init(&manager, &mutexes, global.noopHooks());
    var good: usize = 0;
    for (0..100) |index| {
        good += @intFromBool(coordinator.shutdown() == 0);
        coordinator.configureMode(if (index & 1 == 1) .multi_thread else .serialized) catch unreachable;
        good += 1;
        good += @intFromBool(coordinator.initialize() == 0);
        good += @intFromBool(coordinator.initialize() == 0);
        if (coordinator.configureMemoryStatus(true)) |_| {} else |err| good += @intFromBool(err == error.Misuse);
        good += @intFromBool(coordinator.shutdown() == 0);
        good += @intFromBool(coordinator.shutdown() == 0);
        // The oracle loop's initial shutdown is not included in its six checks.
        good -= 1;
    }
    coordinator.configureMode(.serialized) catch unreachable;
    const Race = struct {
        fn run(value: *global.Coordinator, success: *bool) void {
            for (0..100) |_| {
                if (value.initialize() != 0) success.* = false;
            }
        }
    };
    var success = [_]bool{true} ** 8;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = std.Thread.spawn(.{}, Race.run, .{ &coordinator, &success[index] }) catch unreachable;
    for (&threads) |*thread| thread.join();
    var race = true;
    for (success) |value| race = race and value;
    _ = coordinator.shutdown();

    const Lifecycle = struct {
        var mutex_init: usize = 0;
        var mutex_end: usize = 0;
        var pcache_init: usize = 0;
        var pcache_end: usize = 0;
        var active_coordinator: ?*global.Coordinator = null;
        fn mutexInit() callconv(.c) c_int {
            mutex_init += 1;
            return memory.ok;
        }
        fn mutexEnd() callconv(.c) c_int {
            mutex_end += 1;
            return memory.ok;
        }
        fn pcacheInit(_: *anyopaque) c_int {
            pcache_init += 1;
            std.debug.assert(active_coordinator.?.initialize() == memory.ok);
            return if (pcache_init == 1) memory.no_memory else memory.ok;
        }
        fn pcacheEnd(_: *anyopaque) void {
            pcache_end += 1;
        }
        fn osInit(_: *anyopaque) c_int {
            return memory.ok;
        }
        fn osEnd(_: *anyopaque) void {}
    };
    Lifecycle.mutex_init = 0;
    Lifecycle.mutex_end = 0;
    Lifecycle.pcache_init = 0;
    Lifecycle.pcache_end = 0;
    var lifecycle_manager = memory.Manager.init(memory.systemBackend());
    var lifecycle_mutexes = mutex.Subsystem.init(std.heap.c_allocator);
    var context: u8 = 0;
    var lifecycle = global.Coordinator.init(&lifecycle_manager, &lifecycle_mutexes, .{
        .context = &context,
        .pcacheInitFn = Lifecycle.pcacheInit,
        .pcacheShutdownFn = Lifecycle.pcacheEnd,
        .initFn = Lifecycle.osInit,
        .shutdownFn = Lifecycle.osEnd,
    });
    Lifecycle.active_coordinator = &lifecycle;
    var lifecycle_methods = mutex.noop_methods;
    lifecycle_methods.xMutexInit = Lifecycle.mutexInit;
    lifecycle_methods.xMutexEnd = Lifecycle.mutexEnd;
    lifecycle.configureMutexMethods(lifecycle_methods) catch unreachable;
    const result1 = lifecycle.initialize();
    const flags = @as(c_int, @intFromBool(lifecycle_mutexes.initialized)) |
        (@as(c_int, @intFromBool(lifecycle_manager.started)) << 1) |
        (@as(c_int, @intFromBool(lifecycle.pcache_initialized)) << 2) |
        (@as(c_int, @intFromBool(lifecycle.state == .initialized)) << 3);
    const result2 = lifecycle.initialize();
    const result3 = lifecycle.shutdown();
    const result4 = lifecycle.shutdown();
    return emit(output, capacity, "G\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        good,
        @intFromBool(race),
        result1,
        flags,
        @intFromBool(Lifecycle.mutex_init > 1),
        Lifecycle.pcache_init,
        result2,
        result3,
        result4,
        Lifecycle.mutex_end,
        Lifecycle.pcache_end,
        @intFromBool(lifecycle.state == .initialized),
    });
}
