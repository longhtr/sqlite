const std = @import("std");
const pcache = @import("page_cache");

const StressState = struct { cache: *pcache.Cache, count: usize = 0, key: u32 = 0 };
fn stress(context: ?*anyopaque, page: *pcache.Page) pcache.Result {
    const state: *StressState = @ptrCast(@alignCast(context.?));
    state.count += 1;
    state.key = page.key;
    state.cache.makeClean(page);
    return .ok;
}
fn printDirty(cache: *pcache.Cache) !void {
    const list = try cache.dirtyList(std.heap.c_allocator);
    defer std.heap.c_allocator.free(list);
    std.debug.print("dirty", .{});
    for (list) |page| std.debug.print(" {d}", .{page.key});
    std.debug.print("\n", .{});
}

fn sequencePage(cache: *pcache.Cache, state: *StressState, key: u32) !*pcache.Page {
    const fetched = cache.fetch(key, .hard_create, .{ .callback = stress, .context = state });
    if (fetched.result != .ok) return error.Fetch;
    return fetched.page.?;
}

fn printState(cache: *pcache.Cache, sequence: usize, step: usize) !void {
    const dirty = try cache.dirtyList(std.heap.c_allocator);
    defer std.heap.c_allocator.free(dirty);
    std.debug.print("state {d} {d} {d} {d} dirty", .{
        sequence,
        step,
        cache.pageCount(),
        cache.refCount(),
    });
    for (dirty) |page| std.debug.print(" {d}", .{page.key});
    std.debug.print("\n", .{});
}

fn runSequences() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const input = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/pcache/state-sequences.txt",
        std.heap.c_allocator,
        .limited(128 * 1024),
    );
    defer std.heap.c_allocator.free(input);

    var cache: pcache.Cache = undefined;
    var state: StressState = undefined;
    var opened = false;
    var sequence: usize = 0;
    var step: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const operation = fields.next() orelse continue;
        if (std.mem.eql(u8, operation, "BEGIN")) {
            if (opened) return error.NestedSequence;
            sequence = try std.fmt.parseInt(usize, fields.next().?, 10);
            cache = pcache.Cache.init(std.heap.c_allocator, 256, 8, true, 128);
            cache.setSpillSize(64);
            state = .{ .cache = &cache };
            opened = true;
            step = 0;
            continue;
        }
        if (std.mem.eql(u8, operation, "END")) {
            if (!opened) return error.MissingSequence;
            cache.deinit();
            opened = false;
            continue;
        }
        if (!opened) return error.MissingSequence;
        const first = if (fields.next()) |value| try std.fmt.parseInt(u32, value, 10) else 0;
        const second = if (fields.next()) |value| try std.fmt.parseInt(u32, value, 10) else 0;
        if (operation[0] == 'F') {
            const page = try sequencePage(&cache, &state, first);
            _ = cache.release(page);
        } else if (operation[0] == 'D') {
            const page = try sequencePage(&cache, &state, first);
            cache.makeDirty(page);
            _ = cache.release(page);
        } else if (operation[0] == 'C') {
            const page = try sequencePage(&cache, &state, first);
            cache.makeClean(page);
            _ = cache.release(page);
        } else if (operation[0] == 'M') {
            const page = try sequencePage(&cache, &state, first);
            if (cache.move(page, second) != .ok) return error.Move;
            _ = cache.release(page);
        } else if (operation[0] == 'T') {
            cache.cleanAll();
            cache.truncate(first);
        } else if (operation[0] == 'A') {
            cache.cleanAll();
        } else if (operation[0] == 'H') {
            _ = cache.shrink();
        } else return error.Operation;
        try printState(&cache, sequence, step);
        step += 1;
        if (!cache.checkInvariants()) return error.Invariant;
    }
    if (opened) return error.UnclosedSequence;
}

fn runGroup() !void {
    var storage: [8192]u8 align(8) = undefined;
    var manager = pcache.memory.Manager.init(pcache.memory.systemBackend());
    if (manager.start() != pcache.memory.ok) return error.MemoryInit;
    var lifecycle = pcache.Lifecycle{};
    if (lifecycle.initialize(false, &storage, 8) != 0) return error.PcacheInit;
    lifecycle.setupBuffer(&storage, 1024, 8);
    lifecycle.attachInfrastructure(&manager, null, null);
    var first = pcache.Cache.initWithLifecycle(std.heap.c_allocator, 512, 16, true, 3, &lifecycle);
    var second = pcache.Cache.initWithLifecycle(std.heap.c_allocator, 512, 16, true, 3, &lifecycle);
    const first_one = first.fetch(1, .hard_create, null).page.?;
    const saved = @intFromPtr(first_one);
    const first_two = first.fetch(2, .hard_create, null).page.?;
    _ = first.release(first_one);
    _ = first.release(first_two);
    const second_ten = second.fetch(10, .hard_create, null).page.?;
    const second_eleven = second.fetch(11, .hard_create, null).page.?;
    _ = second.release(second_ten);
    _ = second.release(second_eleven);
    std.debug.print("group {d} {d} {d} {d}\n", .{
        lifecycle.shared_group.purgeable_pages,
        lifecycle.shared_group.max_pages,
        lifecycle.shared_group.min_pages,
        lifecycle.free_slot_count,
    });
    const second_twelve = second.fetch(12, .hard_create, null).page.?;
    std.debug.print("recycle {d} {d} {d} {d} {d}\n", .{
        @intFromBool(@intFromPtr(second_twelve) == saved),
        first.pageCount(),
        second.pageCount(),
        lifecycle.shared_group.purgeable_pages,
        lifecycle.free_slot_count,
    });
    _ = second.release(second_twelve);
    first.setCacheSize(1);
    second.setCacheSize(1);
    std.debug.print("limit {d} {d} {d} {d} {d}\n", .{
        first.pageCount(),
        second.pageCount(),
        lifecycle.shared_group.purgeable_pages,
        lifecycle.shared_group.max_pages,
        lifecycle.free_slot_count,
    });
    _ = first.shrink();
    std.debug.print("groupshrink {d} {d} {d} {d}\n", .{
        first.pageCount(),
        second.pageCount(),
        lifecycle.shared_group.purgeable_pages,
        lifecycle.free_slot_count,
    });
    first.deinit();
    second.deinit();
    lifecycle.shutdown();
    manager.stop();
}

fn runHash() !void {
    var cache = pcache.Cache.init(std.heap.c_allocator, 512, 16, true, 600);
    defer cache.deinit();
    var pages: [258]*pcache.Page = undefined;
    for (0..257) |index| pages[index] = cache.fetch(@intCast(index + 1), .hard_create, null).page.?;
    pages[257] = cache.fetch(513, .hard_create, null).page.?;
    const head = cache.pages.buckets.?[1].?;
    std.debug.print("hash {d} {d} {d} {d}\n", .{
        cache.pages.buckets.?.len,
        cache.pages.page_count,
        head.key,
        head.hash_next.?.key,
    });
    for (pages) |page| _ = cache.release(page);
}

pub fn main() !void {
    var storage: [2048]u8 align(8) = undefined;
    var manager = pcache.memory.Manager.init(pcache.memory.systemBackend());
    if (manager.start() != pcache.memory.ok) return error.MemoryInit;
    var lifecycle = pcache.Lifecycle{};
    if (lifecycle.initialize(true, &storage, 2) != 0) return error.PcacheInit;
    lifecycle.setupBuffer(&storage, 1024, 2);
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = pcache.mutex.processStatic(.static_lru) },
        .{ .native = pcache.mutex.processStatic(.static_pmem) },
    );
    const slot_a = lifecycle.pageMalloc(512).?;
    const slot_b = lifecycle.pageMalloc(512).?;
    const slot_c = lifecycle.pageMalloc(512).?;
    std.debug.print("slots {d} {d} {d} {d} {d}\n", .{
        @intFromBool(lifecycle.isStaticPointer(slot_a)),
        @intFromBool(lifecycle.isStaticPointer(slot_b)),
        @intFromBool(lifecycle.isStaticPointer(slot_c)),
        lifecycle.free_slot_count,
        @intFromBool(lifecycle.under_pressure),
    });
    std.debug.print("pressure {d} {d}\n", .{
        @intFromBool(lifecycle.underMemoryPressure(512 + 16)),
        @intFromBool(lifecycle.underMemoryPressure(2048 + 16)),
    });
    lifecycle.pageFree(slot_a);
    lifecycle.pageFree(slot_b);
    lifecycle.pageFree(slot_c);
    std.debug.print("slotfree {d} {d}\n", .{ lifecycle.free_slot_count, @intFromBool(lifecycle.under_pressure) });
    lifecycle.shutdown();

    var bulk_lifecycle = pcache.Lifecycle{};
    if (bulk_lifecycle.initialize(true, null, 3) != 0) return error.PcacheInit;
    bulk_lifecycle.attachInfrastructure(
        &manager,
        .{ .native = pcache.mutex.processStatic(.static_lru) },
        .{ .native = pcache.mutex.processStatic(.static_pmem) },
    );
    var bulk_cache = pcache.Cache.initWithLifecycle(std.heap.c_allocator, 512, 16, true, 5, &bulk_lifecycle);
    const bulk_a = bulk_cache.fetch(1, .hard_create, null).page.?;
    const bulk_b = bulk_cache.fetch(2, .hard_create, null).page.?;
    const bulk_c = bulk_cache.fetch(3, .hard_create, null).page.?;
    std.debug.print("bulk {d} {d} {d} {d} {d}\n", .{
        @intFromBool(bulk_cache.bulk_pointer != null),
        @intFromBool(bulk_cache.bulk_free == null),
        @intFromBool(bulk_a.bulk_local),
        @intFromBool(bulk_b.bulk_local),
        @intFromBool(bulk_c.bulk_local),
    });
    const bulk_d = bulk_cache.fetch(4, .hard_create, null).page.?;
    std.debug.print("bulkoverflow {d}\n", .{@intFromBool(bulk_d.bulk_local)});
    _ = bulk_cache.release(bulk_a);
    _ = bulk_cache.release(bulk_b);
    _ = bulk_cache.release(bulk_c);
    _ = bulk_cache.release(bulk_d);
    _ = bulk_cache.shrink();
    std.debug.print("bulkfree {d}\n", .{@intFromBool(bulk_cache.bulk_pointer == null)});
    bulk_cache.deinit();
    bulk_lifecycle.shutdown();
    manager.stop();

    var cache = pcache.Cache.init(std.heap.c_allocator, 512, 16, true, 3);
    defer cache.deinit();
    cache.setSpillSize(1);
    const page3 = cache.fetch(3, .hard_create, null).page.?;
    const page1 = cache.fetch(1, .hard_create, null).page.?;
    const page2 = cache.fetch(2, .hard_create, null).page.?;
    cache.makeDirty(page3);
    cache.makeDirty(page1);
    cache.makeDirty(page2);
    try printDirty(&cache);
    std.debug.print("refs {d}\n", .{cache.refCount()});
    _ = cache.release(page1);
    _ = cache.release(page2);
    _ = cache.release(page3);
    std.debug.print("refs {d}\n", .{cache.refCount()});
    var state = StressState{ .cache = &cache };
    const page4 = cache.fetch(4, .hard_create, .{ .callback = stress, .context = &state }).page.?;
    std.debug.print("stress {d} {d}\n", .{ state.count, state.key });
    std.debug.print("pages {d}\n", .{cache.pageCount()});
    try printDirty(&cache);
    cache.makeClean(page4);
    _ = cache.move(page4, 8);
    _ = cache.release(page4);
    cache.cleanAll();
    cache.truncate(3);
    std.debug.print("pages {d}\n", .{cache.pageCount()});

    var purge_cache = pcache.Cache.init(std.heap.c_allocator, 512, 16, true, 4);
    defer purge_cache.deinit();
    const page11 = purge_cache.fetch(11, .hard_create, null).page.?;
    const page12 = purge_cache.fetch(12, .hard_create, null).page.?;
    _ = purge_cache.release(page11);
    _ = purge_cache.release(page12);
    std.debug.print("purge {d}", .{purge_cache.pageCount()});
    _ = purge_cache.shrink();
    std.debug.print(" {d}\n", .{purge_cache.pageCount()});
    try runSequences();
    try runGroup();
    try runHash();
}
