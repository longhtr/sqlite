//! Native pager cache interface and deterministic default cache.
//! Normal Zig ownership is used; no private C layout crosses this boundary.

const std = @import("std");
pub const memory = @import("memory.zig");
pub const mutex = @import("mutex.zig");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const trace_allocator = std.heap.page_allocator;

pub const Result = enum { ok, not_found, out_of_memory, busy, corrupt };

const FreeSlot = extern struct {
    next: ?*FreeSlot,
};

const PageTable = struct {
    allocator: std.mem.Allocator,
    buckets: ?[]?*Page = null,
    page_count: usize = 0,

    const Entry = struct { key_ptr: *u32, value_ptr: **Page };
    const Iterator = struct {
        table: *PageTable,
        bucket_index: usize = 0,
        next_page: ?*Page = null,
        value: *Page = undefined,

        pub fn next(self: *Iterator) ?Entry {
            while (self.next_page == null) {
                const buckets = self.table.buckets orelse return null;
                if (self.bucket_index >= buckets.len) return null;
                self.next_page = buckets[self.bucket_index];
                self.bucket_index += 1;
            }
            const page = self.next_page.?;
            self.next_page = page.hash_next;
            self.value = page;
            return .{ .key_ptr = &page.key, .value_ptr = &self.value };
        }
    };

    fn init(allocator: std.mem.Allocator) PageTable {
        var result = PageTable{ .allocator = allocator };
        result.resize() catch {};
        return result;
    }

    fn ready(self: *const PageTable) bool {
        return self.buckets != null;
    }

    fn resize(self: *PageTable) !void {
        const old = self.buckets;
        const new_count = @max(if (old) |items| items.len * 2 else 0, 256);
        const replacement = try self.allocator.alloc(?*Page, new_count);
        @memset(replacement, null);
        if (old) |items| {
            for (items) |head| {
                var cursor = head;
                while (cursor) |page| {
                    const next = page.hash_next;
                    const bucket = page.key % @as(u32, @intCast(new_count));
                    page.hash_next = replacement[bucket];
                    replacement[bucket] = page;
                    cursor = next;
                }
            }
            self.allocator.free(items);
        }
        self.buckets = replacement;
    }

    pub fn deinit(self: *PageTable) void {
        if (self.buckets) |items| self.allocator.free(items);
        self.* = undefined;
    }

    pub fn count(self: *const PageTable) usize {
        return self.page_count;
    }

    pub fn get(self: *const PageTable, key: u32) ?*Page {
        const buckets = self.buckets orelse return null;
        var page = buckets[key % @as(u32, @intCast(buckets.len))];
        while (page) |current| : (page = current.hash_next) if (current.key == key) return current;
        return null;
    }

    pub fn put(self: *PageTable, key: u32, page: *Page) !void {
        const buckets = self.buckets orelse return error.OutOfMemory;
        if (self.page_count >= buckets.len) self.resize() catch {};
        const active = self.buckets.?;
        const bucket = key % @as(u32, @intCast(active.len));
        page.hash_next = active[bucket];
        active[bucket] = page;
        self.page_count += 1;
    }

    pub fn remove(self: *PageTable, key: u32) bool {
        const buckets = self.buckets orelse return false;
        const bucket = key % @as(u32, @intCast(buckets.len));
        var previous: ?*Page = null;
        var page = buckets[bucket];
        while (page) |current| : (page = current.hash_next) {
            if (current.key == key) {
                if (previous) |before| before.hash_next = current.hash_next else buckets[bucket] = current.hash_next;
                current.hash_next = null;
                self.page_count -= 1;
                return true;
            }
            previous = current;
        }
        return false;
    }

    pub fn rekey(self: *PageTable, page: *Page, old_key: u32, new_key: u32) void {
        std.debug.assert(self.remove(old_key));
        page.key = new_key;
        self.put(new_key, page) catch unreachable;
    }

    pub fn ensureUnusedCapacity(self: *PageTable, additional: usize) !void {
        if (self.buckets == null) return error.OutOfMemory;
        if (self.page_count + additional >= self.buckets.?.len) self.resize() catch {};
    }

    pub fn putAssumeCapacity(self: *PageTable, key: u32, page: *Page) void {
        self.put(key, page) catch unreachable;
    }

    pub fn iterator(self: *PageTable) Iterator {
        return .{ .table = self };
    }
};

const Group = struct {
    max_pages: usize = 0,
    min_pages: usize = 0,
    max_pinned: usize = 10,
    purgeable_pages: usize = 0,
    lru_head: ?*Page = null,
    lru_tail: ?*Page = null,

    fn recomputeMaxPinned(self: *Group) void {
        self.max_pinned = self.max_pages +% 10 -% self.min_pages;
    }
};

pub const Lifecycle = struct {
    initialized: bool = false,
    separate_cache: bool = true,
    initial_pages: c_int = 0,
    static_mutexes: bool = false,
    max_pinned: c_int = 0,
    slot_size: c_int = 0,
    slot_count: c_int = 0,
    free_slot_count: c_int = 0,
    reserve_count: c_int = 0,
    start: ?*anyopaque = null,
    end: ?*anyopaque = null,
    free: ?*FreeSlot = null,
    under_pressure: bool = false,
    status_manager: ?*memory.Manager = null,
    group_mutex: ?mutex.Handle = null,
    slot_mutex: ?mutex.Handle = null,
    shared_group: Group = .{},

    pub fn initialize(self: *Lifecycle, core_mutex: bool, static_page: ?*anyopaque, page_count: c_int) c_int {
        std.debug.assert(!self.initialized);
        self.* = .{};
        self.separate_cache = static_page == null or core_mutex;
        self.static_mutexes = core_mutex;
        self.max_pinned = 10;
        self.initial_pages = if (self.separate_cache and page_count != 0 and static_page == null) page_count else 0;
        self.initialized = true;
        return 0;
    }

    pub fn setupBuffer(self: *Lifecycle, storage: ?*anyopaque, requested_size: c_int, requested_count: c_int) void {
        if (!self.initialized) return;
        var size = requested_size;
        var count = requested_count;
        if (storage == null) {
            size = 0;
            count = 0;
        }
        if (count == 0) size = 0;
        size &= ~@as(c_int, 7);
        self.slot_size = size;
        self.slot_count = count;
        self.free_slot_count = count;
        self.reserve_count = if (count > 90) 10 else @divTrunc(count, 10) + 1;
        self.start = storage;
        self.free = null;
        self.under_pressure = false;
        var cursor: [*]u8 = if (storage) |pointer| @ptrCast(pointer) else @ptrFromInt(@alignOf(FreeSlot));
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            const slot: *FreeSlot = @ptrCast(@alignCast(cursor));
            slot.next = self.free;
            self.free = slot;
            cursor += @intCast(size);
        }
        self.end = if (storage == null) null else @ptrCast(cursor);
    }

    pub fn attachInfrastructure(self: *Lifecycle, status_manager: *memory.Manager, group_mutex: ?mutex.Handle, slot_mutex: ?mutex.Handle) void {
        std.debug.assert(self.initialized);
        self.status_manager = status_manager;
        self.group_mutex = group_mutex;
        self.slot_mutex = slot_mutex;
        status_manager.setPcacheMutex(slot_mutex);
    }

    fn enterSlot(self: *Lifecycle) void {
        if (self.slot_mutex) |*value| value.enter();
    }

    fn leaveSlot(self: *Lifecycle) void {
        if (self.slot_mutex) |*value| value.leave();
    }

    pub fn allocateSlot(self: *Lifecycle, requested_size: usize) ?*anyopaque {
        if (!self.initialized or requested_size > @as(usize, @intCast(@max(self.slot_size, 0)))) return null;
        self.enterSlot();
        defer self.leaveSlot();
        const slot = self.free orelse return null;
        self.free = slot.next;
        self.free_slot_count -= 1;
        self.under_pressure = self.free_slot_count < self.reserve_count;
        slot.next = null;
        if (self.status_manager) |manager| {
            manager.statusHighwater(.pagecache_size, @intCast(requested_size));
            manager.statusUp(.pagecache_used, 1);
        }
        return slot;
    }

    pub fn isStaticPointer(self: *const Lifecycle, pointer: *const anyopaque) bool {
        if (self.start == null or self.end == null) return false;
        const address = @intFromPtr(pointer);
        return address >= @intFromPtr(self.start.?) and address < @intFromPtr(self.end.?);
    }

    pub fn freeSlot(self: *Lifecycle, pointer: *anyopaque) bool {
        if (!self.initialized or self.start == null or self.end == null) return false;
        if (!self.isStaticPointer(pointer)) return false;
        self.enterSlot();
        defer self.leaveSlot();
        const slot: *FreeSlot = @ptrCast(@alignCast(pointer));
        slot.next = self.free;
        self.free = slot;
        self.free_slot_count += 1;
        self.under_pressure = self.free_slot_count < self.reserve_count;
        std.debug.assert(self.free_slot_count <= self.slot_count);
        if (self.status_manager) |manager| manager.statusDown(.pagecache_used, 1);
        return true;
    }

    pub const OverflowAllocation = struct {
        pointer: *anyopaque,
        size: usize,
    };

    pub fn allocateOverflow(self: *Lifecycle, requested_size: usize) ?OverflowAllocation {
        const manager = self.status_manager orelse return null;
        const pointer = manager.alloc(requested_size) orelse return null;
        const size = manager.size(pointer);
        self.enterSlot();
        manager.statusHighwater(.pagecache_size, @intCast(requested_size));
        manager.statusUp(.pagecache_overflow, @intCast(size));
        self.leaveSlot();
        return .{ .pointer = pointer, .size = size };
    }

    pub fn freeOverflow(self: *Lifecycle, pointer: *anyopaque, size: usize) void {
        const manager = self.status_manager.?;
        self.enterSlot();
        manager.statusDown(.pagecache_overflow, @intCast(size));
        self.leaveSlot();
        manager.free(pointer);
    }

    pub fn pageMalloc(self: *Lifecycle, requested_size: usize) ?*anyopaque {
        if (self.allocateSlot(requested_size)) |slot| return slot;
        return (self.allocateOverflow(requested_size) orelse return null).pointer;
    }

    pub fn pageFree(self: *Lifecycle, pointer: ?*anyopaque) void {
        const value = pointer orelse return;
        if (self.freeSlot(value)) return;
        const manager = self.status_manager.?;
        self.freeOverflow(value, manager.size(value));
    }

    pub fn underMemoryPressure(self: *Lifecycle, page_and_extra_size: usize) bool {
        if (self.slot_count != 0 and page_and_extra_size <= @as(usize, @intCast(@max(self.slot_size, 0)))) {
            self.enterSlot();
            defer self.leaveSlot();
            return self.under_pressure;
        }
        return if (self.status_manager) |manager| manager.heapNearlyFull() else false;
    }

    pub fn shutdown(self: *Lifecycle) void {
        if (!self.initialized) return;
        if (self.status_manager) |manager| manager.setPcacheMutex(null);
        self.* = .{};
    }
};

pub var process_lifecycle = Lifecycle{};

pub fn activeProcessLifecycle() ?*Lifecycle {
    return if (process_lifecycle.initialized) &process_lifecycle else null;
}

pub const FetchMode = enum(u2) { lookup = 0, soft_create = 1, hard_create = 2 };

pub const Flags = packed struct(u8) {
    dirty: bool = false,
    writeable: bool = false,
    need_sync: bool = false,
    dont_write: bool = false,
    mmap: bool = false,
    wal_append: bool = false,
    reserved: u2 = 0,
};

pub const Page = struct {
    key: u32,
    data: []u8,
    extra: []u8,
    ref_count: u32 = 0,
    flags: Flags = .{},
    dirty_prev: ?*Page = null,
    dirty_next: ?*Page = null,
    sort_next: ?*Page = null,
    lru_stamp: u64 = 0,
    static_slot: ?*anyopaque = null,
    heap_words: ?[]u64 = null,
    process_heap: ?*anyopaque = null,
    process_heap_size: usize = 0,
    bulk_local: bool = false,
    bulk_next: ?*Page = null,
    hash_next: ?*Page = null,
    owner: ?*Cache = null,
    lru_prev: ?*Page = null,
    lru_next: ?*Page = null,
    on_group_lru: bool = false,

    pub fn isDirty(self: *const Page) bool {
        return self.flags.dirty;
    }
    pub fn isPinned(self: *const Page) bool {
        return self.ref_count != 0;
    }
};

pub const StressCallback = *const fn (context: ?*anyopaque, page: *Page) Result;
pub const Stress = struct { callback: StressCallback, context: ?*anyopaque = null };

pub const TraceKind = enum {
    fetch_hit,
    fetch_miss,
    create,
    reference,
    release,
    pin,
    unpin,
    dirty,
    clean,
    move,
    drop,
    stress,
    evict,
    truncate,
    purge,
};
pub const TraceEvent = struct { kind: TraceKind, key: u32, ref_count: u32 };

pub const Cache = struct {
    allocator: std.mem.Allocator,
    pages: PageTable,
    page_size: usize,
    extra_size: usize,
    max_pages: usize,
    configured_pages: i64,
    spill_size: usize,
    purgeable: bool,
    create_mode: FetchMode = .hard_create,
    dirty_head: ?*Page = null,
    dirty_tail: ?*Page = null,
    synced: ?*Page = null,
    ref_sum: usize = 0,
    clock: u64 = 0,
    events: std.ArrayList(TraceEvent) = .empty,
    lifecycle: ?*Lifecycle = null,
    bulk_pointer: ?*anyopaque = null,
    bulk_size: usize = 0,
    bulk_free: ?*Page = null,
    bulk_page_count: usize = 0,
    bulk_free_count: usize = 0,
    private_group: Group = .{},
    recyclable_pages: usize = 0,
    group_registered: bool = false,

    pub fn init(allocator: std.mem.Allocator, page_size: usize, extra_size: usize, purgeable: bool, max_pages: usize) Cache {
        return initWithLifecycle(allocator, page_size, extra_size, purgeable, max_pages, null);
    }

    /// Source `pcache1Create()`: allocate the cache owner before allocating its
    /// initial hash table. The embedded private Group therefore shares the same
    /// owner allocation, while unified mode borrows Lifecycle.shared_group.
    pub fn create(allocator: std.mem.Allocator, page_size: usize, extra_size: usize, purgeable: bool, max_pages: usize, lifecycle: ?*Lifecycle) ?*Cache {
        const result = allocator.create(Cache) catch return null;
        result.* = initWithLifecycle(allocator, page_size, extra_size, purgeable, max_pages, lifecycle);
        if (!result.ready()) {
            result.deinit();
            allocator.destroy(result);
            return null;
        }
        return result;
    }

    pub fn initWithLifecycle(allocator: std.mem.Allocator, page_size: usize, extra_size: usize, purgeable: bool, max_pages: usize, lifecycle: ?*Lifecycle) Cache {
        const limit = @min(max_pages, 0x7fff_0000);
        var result = Cache{
            .allocator = allocator,
            .pages = PageTable.init(allocator),
            .page_size = page_size,
            .extra_size = extra_size,
            .max_pages = limit,
            .configured_pages = @intCast(limit),
            .spill_size = @max(limit, 1),
            .purgeable = purgeable,
            .lifecycle = lifecycle,
        };
        if (purgeable) {
            if (lifecycle != null and !lifecycle.?.separate_cache) {
                if (lifecycle.?.group_mutex) |*handle| {
                    handle.enter();
                }
                defer {
                    if (lifecycle.?.group_mutex) |*handle| {
                        handle.leave();
                    }
                }
                const group = &lifecycle.?.shared_group;
                const available = 0x7fff_0000 -| group.max_pages;
                result.max_pages = @min(limit, available);
                group.max_pages += result.max_pages;
                group.min_pages += 10;
                group.recomputeMaxPinned();
                result.group_registered = true;
            } else {
                result.private_group.max_pages = limit;
                result.private_group.min_pages = 10;
                result.private_group.recomputeMaxPinned();
            }
        }
        return result;
    }

    pub fn destroy(self: *Cache) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *Cache) void {
        self.enterGroup();
        var iterator = self.pages.iterator();
        while (iterator.next()) |entry| self.destroyPage(entry.value_ptr.*);
        self.releaseBulk();
        if (self.group_registered) {
            const group = &self.lifecycle.?.shared_group;
            std.debug.assert(group.max_pages >= self.max_pages and group.min_pages >= 10);
            group.max_pages -= self.max_pages;
            group.min_pages -= 10;
            group.recomputeMaxPinned();
            self.enforceGroupMax();
            self.group_registered = false;
        }
        self.pages.deinit();
        self.events.deinit(trace_allocator);
        self.leaveGroup();
        self.* = undefined;
    }

    fn record(self: *Cache, kind: TraceKind, page: *const Page) void {
        self.events.append(trace_allocator, .{ .kind = kind, .key = page.key, .ref_count = page.ref_count }) catch {};
    }

    fn usesSharedGroup(self: *const Cache) bool {
        return if (self.lifecycle) |lifecycle| !lifecycle.separate_cache else false;
    }

    fn pageGroup(self: *Cache) *Group {
        if (self.usesSharedGroup()) return &self.lifecycle.?.shared_group;
        return &self.private_group;
    }

    /// Source `pcache1EnterMutex()`/`pcache1LeaveMutex()`: only the unified
    /// PGroup needs serialization. Private cache groups deliberately avoid it.
    fn enterGroup(self: *Cache) void {
        if (self.usesSharedGroup()) {
            if (self.lifecycle.?.group_mutex) |*handle| {
                handle.enter();
            }
        }
    }

    fn leaveGroup(self: *Cache) void {
        if (self.usesSharedGroup()) {
            if (self.lifecycle.?.group_mutex) |*handle| {
                handle.leave();
            }
        }
    }

    fn removeFromGroupLru(self: *Cache, page: *Page) void {
        const owner = if (self.usesSharedGroup()) page.owner orelse self else self;
        if (!self.usesSharedGroup()) page.owner = self;
        if (!page.on_group_lru) return;
        const group = owner.pageGroup();
        if (page.lru_prev) |previous| previous.lru_next = page.lru_next else group.lru_head = page.lru_next;
        if (page.lru_next) |next| next.lru_prev = page.lru_prev else group.lru_tail = page.lru_prev;
        page.lru_prev = null;
        page.lru_next = null;
        page.on_group_lru = false;
        std.debug.assert(owner.recyclable_pages > 0);
        owner.recyclable_pages -= 1;
    }

    fn addToGroupLru(self: *Cache, page: *Page) void {
        if (page.on_group_lru or page.ref_count != 0 or page.flags.dirty or !self.purgeable) return;
        const group = self.pageGroup();
        page.owner = self;
        page.lru_prev = null;
        page.lru_next = group.lru_head;
        if (group.lru_head) |head| head.lru_prev = page else group.lru_tail = page;
        group.lru_head = page;
        page.on_group_lru = true;
        self.recyclable_pages += 1;
    }

    fn pageLayout(self: *const Cache) struct { page_offset: usize, allocation_size: usize } {
        const page_offset = std.mem.alignForward(usize, self.page_size, @alignOf(Page));
        return .{
            .page_offset = page_offset,
            .allocation_size = std.mem.alignForward(usize, page_offset + @sizeOf(Page) + self.extra_size, @alignOf(Page)),
        };
    }

    fn initializeBulk(self: *Cache, layout: @TypeOf(self.pageLayout())) bool {
        const lifecycle = self.lifecycle orelse return false;
        const manager = lifecycle.status_manager orelse return false;
        const configured = lifecycle.initial_pages;
        if (configured == 0 or self.max_pages < 3 or self.bulk_pointer != null) return false;
        const maximum = std.math.mul(usize, layout.allocation_size, self.max_pages) catch return false;
        const requested_uncapped = if (configured > 0)
            std.math.mul(usize, layout.allocation_size, @intCast(configured)) catch maximum
        else
            std.math.mul(usize, 1024, @intCast(-@as(i64, configured))) catch maximum;
        const requested = @min(requested_uncapped, maximum);
        if (requested < layout.allocation_size) return false;
        const pointer = manager.alloc(requested) orelse return false;
        const actual_size = manager.size(pointer);
        const count = actual_size / layout.allocation_size;
        if (count == 0) {
            manager.free(pointer);
            return false;
        }
        self.bulk_pointer = pointer;
        self.bulk_size = actual_size;
        self.bulk_page_count = count;
        self.bulk_free_count = count;
        const bytes: [*]u8 = @ptrCast(pointer);
        for (0..count) |index| {
            const chunk = bytes + index * layout.allocation_size;
            const page: *Page = @ptrCast(@alignCast(chunk + layout.page_offset));
            page.* = .{
                .key = 0,
                .data = chunk[0..self.page_size],
                .extra = chunk[layout.page_offset + @sizeOf(Page) ..][0..self.extra_size],
                .bulk_local = true,
                .bulk_next = self.bulk_free,
            };
            self.bulk_free = page;
        }
        return true;
    }

    fn releaseBulk(self: *Cache) void {
        const pointer = self.bulk_pointer orelse return;
        std.debug.assert(self.bulk_free_count == self.bulk_page_count);
        self.lifecycle.?.status_manager.?.free(pointer);
        self.bulk_pointer = null;
        self.bulk_size = 0;
        self.bulk_free = null;
        self.bulk_page_count = 0;
        self.bulk_free_count = 0;
    }

    fn createPage(self: *Cache, key: u32) Result {
        const layout = self.pageLayout();
        const page_offset = layout.page_offset;
        const allocation_size = layout.allocation_size;
        var page: *Page = undefined;
        var data: []u8 = undefined;
        var extra: []u8 = undefined;
        var static_slot: ?*anyopaque = null;
        var heap_words: ?[]u64 = null;
        var process_heap: ?*anyopaque = null;
        var process_heap_size: usize = 0;
        var bulk_local = false;
        if (self.bulk_free != null or (self.pages.count() == 0 and self.initializeBulk(layout))) {
            page = self.bulk_free.?;
            self.bulk_free = page.bulk_next;
            self.bulk_free_count -= 1;
            data = page.data;
            extra = page.extra;
            bulk_local = true;
        } else {
            if (self.lifecycle) |lifecycle| static_slot = lifecycle.allocateSlot(allocation_size);
            if (static_slot) |slot| {
                const bytes: [*]u8 = @ptrCast(slot);
                data = bytes[0..self.page_size];
                page = @ptrCast(@alignCast(bytes + page_offset));
                extra = bytes[page_offset + @sizeOf(Page) ..][0..self.extra_size];
            } else if (self.lifecycle != null and self.lifecycle.?.status_manager != null) {
                const allocation = self.lifecycle.?.allocateOverflow(allocation_size) orelse return .out_of_memory;
                process_heap = allocation.pointer;
                process_heap_size = allocation.size;
                const bytes: [*]u8 = @ptrCast(allocation.pointer);
                data = bytes[0..self.page_size];
                page = @ptrCast(@alignCast(bytes + page_offset));
                extra = bytes[page_offset + @sizeOf(Page) ..][0..self.extra_size];
            } else {
                const words = self.allocator.alloc(u64, (allocation_size + 7) / 8) catch return .out_of_memory;
                heap_words = words;
                const bytes: [*]u8 = @ptrCast(words.ptr);
                data = bytes[0..self.page_size];
                page = @ptrCast(@alignCast(bytes + page_offset));
                extra = bytes[page_offset + @sizeOf(Page) ..][0..self.extra_size];
            }
        }
        page.* = .{
            .key = key,
            .data = data,
            .extra = extra,
            .static_slot = static_slot,
            .heap_words = heap_words,
            .process_heap = process_heap,
            .process_heap_size = process_heap_size,
            .bulk_local = bulk_local,
            .owner = self,
        };
        self.initializeFetchedPage(page);
        if (self.purgeable) self.pageGroup().purgeable_pages += 1;
        self.pages.put(key, page) catch {
            if (self.purgeable) {
                std.debug.assert(self.pageGroup().purgeable_pages > 0);
                self.pageGroup().purgeable_pages -= 1;
            }
            if (page.bulk_local) {
                page.bulk_next = self.bulk_free;
                self.bulk_free = page;
                self.bulk_free_count += 1;
            } else if (static_slot) |slot| {
                std.debug.assert(self.lifecycle.?.freeSlot(slot));
            } else if (process_heap) |pointer| {
                self.lifecycle.?.freeOverflow(pointer, process_heap_size);
            } else {
                self.allocator.free(heap_words.?);
            }
            return .out_of_memory;
        };
        self.record(.create, page);
        return .ok;
    }

    /// Source `pcacheFetchFinishWithInit()`: initialize middleware state for a
    /// newly allocated lower-cache page and clear only the guaranteed first
    /// eight bytes of the caller-owned extra area.
    fn initializeFetchedPage(_: *Cache, page: *Page) void {
        @memset(page.data, 0);
        @memset(page.extra[0..@min(page.extra.len, 8)], 0);
        page.ref_count = 0;
        page.flags = .{};
        page.dirty_prev = null;
        page.dirty_next = null;
        page.sort_next = null;
        page.lru_stamp = 0;
        page.hash_next = null;
        page.lru_prev = null;
        page.lru_next = null;
        page.on_group_lru = false;
    }

    /// Source `sqlite3PcacheFetchFinish()`: publish one reference after lower
    /// cache lookup/allocation has completed.
    fn finishFetch(self: *Cache, page: *Page) void {
        page.ref_count += 1;
        self.ref_sum += 1;
    }

    fn destroyPage(self: *Cache, page: *Page) void {
        self.removeFromGroupLru(page);
        const owner = if (self.usesSharedGroup()) page.owner orelse self else self;
        if (owner.purgeable) {
            const group = owner.pageGroup();
            std.debug.assert(group.purgeable_pages > 0);
            group.purgeable_pages -= 1;
        }
        if (page.bulk_local) {
            page.bulk_next = self.bulk_free;
            self.bulk_free = page;
            self.bulk_free_count += 1;
            return;
        }
        if (page.static_slot) |slot| {
            std.debug.assert(self.lifecycle.?.freeSlot(slot));
            return;
        }
        if (page.process_heap) |pointer| {
            self.lifecycle.?.freeOverflow(pointer, page.process_heap_size);
            return;
        }
        self.allocator.free(page.heap_words.?);
    }

    fn removeDirty(self: *Cache, page: *Page) void {
        if (!page.flags.dirty) return;
        if (page.dirty_prev) |previous| previous.dirty_next = page.dirty_next else self.dirty_head = page.dirty_next;
        if (page.dirty_next) |next| next.dirty_prev = page.dirty_prev else self.dirty_tail = page.dirty_prev;
        page.dirty_prev = null;
        page.dirty_next = null;
        page.flags.dirty = false;
        if (self.dirty_head == null) {
            self.create_mode = .hard_create;
        }
        self.recomputeSynced();
    }

    fn insertDirtyFront(self: *Cache, page: *Page) void {
        std.debug.assert(!page.flags.dirty);
        if (self.dirty_head == null and self.purgeable) {
            self.create_mode = .soft_create;
        }
        page.flags.dirty = true;
        page.dirty_prev = null;
        page.dirty_next = self.dirty_head;
        if (self.dirty_head) |head| head.dirty_prev = page else self.dirty_tail = page;
        self.dirty_head = page;
        self.recomputeSynced();
    }

    fn recomputeSynced(self: *Cache) void {
        self.synced = null;
        var cursor = self.dirty_tail;
        while (cursor) |page| : (cursor = page.dirty_prev) {
            if (!page.flags.need_sync) {
                self.synced = page;
                break;
            }
        }
    }

    fn oldestUnpinnedClean(self: *Cache) ?*Page {
        var candidate: ?*Page = null;
        var iterator = self.pages.iterator();
        while (iterator.next()) |entry| {
            const page = entry.value_ptr.*;
            if (page.ref_count != 0 or page.flags.dirty) continue;
            if (candidate == null or page.lru_stamp < candidate.?.lru_stamp or
                (page.lru_stamp == candidate.?.lru_stamp and page.key < candidate.?.key)) candidate = page;
        }
        return candidate;
    }

    fn discard(self: *Cache, page: *Page, kind: TraceKind) void {
        self.record(kind, page);
        self.removeDirty(page);
        self.ref_sum -= page.ref_count;
        _ = self.pages.remove(page.key);
        self.destroyPage(page);
    }

    fn recyclePage(self: *Cache, victim: *Page, key: u32) Result {
        const old_owner = if (self.usesSharedGroup()) victim.owner orelse return .corrupt else self;
        self.pages.ensureUnusedCapacity(1) catch return .out_of_memory;
        old_owner.record(.evict, victim);
        old_owner.removeFromGroupLru(victim);
        std.debug.assert(victim.ref_count == 0 and !victim.flags.dirty);
        _ = old_owner.pages.remove(victim.key);
        const data = victim.data;
        const extra = victim.extra;
        const static_slot = victim.static_slot;
        const heap_words = victim.heap_words;
        const process_heap = victim.process_heap;
        const process_heap_size = victim.process_heap_size;
        const bulk_local = victim.bulk_local;
        victim.* = .{
            .key = key,
            .data = data,
            .extra = extra,
            .static_slot = static_slot,
            .heap_words = heap_words,
            .process_heap = process_heap,
            .process_heap_size = process_heap_size,
            .bulk_local = bulk_local,
            .owner = self,
        };
        self.initializeFetchedPage(victim);
        self.pages.putAssumeCapacity(key, victim);
        self.record(.create, victim);
        return .ok;
    }

    fn underMemoryPressure(self: *Cache) bool {
        const lifecycle = self.lifecycle orelse return false;
        return lifecycle.underMemoryPressure(self.page_size + self.extra_size);
    }

    fn pinnedAndRecyclable(self: *Cache) struct { pinned: usize, recyclable: usize } {
        var pinned: usize = 0;
        var recyclable: usize = 0;
        var iterator = self.pages.iterator();
        while (iterator.next()) |entry| {
            const page = entry.value_ptr.*;
            if (page.ref_count == 0 and !page.flags.dirty) recyclable += 1 else pinned += 1;
        }
        return .{ .pinned = pinned, .recyclable = recyclable };
    }

    const Room = struct { result: Result = .ok, page: ?*Page = null };

    /// Source `pcache1FetchStage2()`: enforce cache/group limits and recycle a
    /// compatible clean LRU page before allocating or spilling dirty pages.
    fn fetchStage2(self: *Cache, key: u32, under_pressure: bool) Room {
        const group = self.pageGroup();
        const cache_has_room = self.pages.count() + 1 < self.max_pages;
        const group_has_room = group.purgeable_pages < group.max_pages;
        if (!self.purgeable or (cache_has_room and group_has_room and !under_pressure)) return .{};
        if (group.lru_tail) |victim| {
            const old_owner = if (self.usesSharedGroup()) victim.owner orelse return .{ .result = .corrupt } else self;
            if (old_owner.pageLayout().allocation_size == self.pageLayout().allocation_size) {
                const result = self.recyclePage(victim, key);
                if (result == .ok) {
                    self.finishFetch(victim);
                }
                return .{ .result = result, .page = if (result == .ok) victim else null };
            }
            old_owner.discard(victim, .evict);
        }
        return .{};
    }

    /// Source `sqlite3PcacheFetchStress()` dirty-page spill stage.
    fn makeRoom(self: *Cache, key: u32, stress: ?Stress, under_pressure: bool) Room {
        const lower = self.fetchStage2(key, under_pressure);
        if (lower.result != .ok or lower.page != null) return lower;
        if (self.pages.count() <= self.spill_size) return .{};
        var dirty = self.synced orelse self.dirty_tail;
        while (dirty) |candidate| : (dirty = candidate.dirty_prev) {
            if (candidate.ref_count == 0) {
                if (stress) |handler| {
                    self.record(.stress, candidate);
                    // pcache.c invokes xStress after the lower pcache xFetch()
                    // has released the PGroup mutex. The callback may clean and
                    // unpin this same page, so retaining the mutex deadlocks.
                    const candidate_key = candidate.key;
                    self.leaveGroup();
                    const result = handler.callback(handler.context, candidate);
                    self.enterGroup();
                    if (result != .ok and result != .busy) return .{ .result = result };
                    // The callback may have cleaned and immediately freed the
                    // page because the unified group is over its limit.
                    if (self.pages.get(candidate_key)) |remaining| {
                        if (remaining == candidate and !remaining.flags.dirty) {
                            self.discard(remaining, .evict);
                            return .{};
                        }
                    } else {
                        return .{};
                    }
                }
                break;
            }
        }
        // Like SQLite's cache-size limit, max_pages is advisory while all
        // possible victims are pinned or a stress callback declines cleanup.
        return .{};
    }

    pub fn fetch(self: *Cache, key: u32, mode: FetchMode, stress: ?Stress) struct { result: Result, page: ?*Page } {
        self.enterGroup();
        defer self.leaveGroup();
        if (key == 0) return .{ .result = .corrupt, .page = null };
        if (self.pages.get(key)) |page| {
            self.removeFromGroupLru(page);
            self.finishFetch(page);
            self.record(.fetch_hit, page);
            return .{ .result = .ok, .page = page };
        }
        var phantom = Page{ .key = key, .data = &.{}, .extra = &.{} };
        self.record(.fetch_miss, &phantom);
        if (mode == .lookup) return .{ .result = .not_found, .page = null };
        const under_pressure = self.underMemoryPressure();
        const effective_mode = if (mode == .hard_create) self.create_mode else mode;
        if (effective_mode == .soft_create) {
            const counts = self.pinnedAndRecyclable();
            const ninety_percent = self.max_pages * 9 / 10;
            const soft_refused = counts.pinned >= self.pageGroup().max_pinned or counts.pinned >= ninety_percent or
                (under_pressure and counts.recyclable < counts.pinned);
            if (soft_refused and mode == .soft_create) return .{ .result = .busy, .page = null };
            // A middleware hard-create request first uses lower-cache soft
            // admission while dirty pages exist, then falls through to the
            // source stress path when that inexpensive attempt is refused.
        }
        const room = self.makeRoom(key, stress, under_pressure);
        if (room.result != .ok or room.page != null) return .{ .result = room.result, .page = room.page };
        const created = self.createPage(key);
        const page = if (created == .ok) self.pages.get(key).? else null;
        if (page) |created_page| {
            self.finishFetch(created_page);
        }
        return .{ .result = created, .page = page };
    }

    pub fn reference(self: *Cache, page: *Page) void {
        self.enterGroup();
        defer self.leaveGroup();
        self.removeFromGroupLru(page);
        page.ref_count += 1;
        self.ref_sum += 1;
        self.record(.reference, page);
    }

    pub fn release(self: *Cache, page: *Page) Result {
        self.enterGroup();
        defer self.leaveGroup();
        if (page.ref_count == 0) return .corrupt;
        page.ref_count -= 1;
        self.ref_sum -= 1;
        self.record(.release, page);
        if (page.ref_count == 0) {
            if (page.flags.dirty) {
                self.removeDirty(page);
                self.insertDirtyFront(page);
            } else {
                self.clock +%= 1;
                page.lru_stamp = self.clock;
                const group = self.pageGroup();
                if (self.purgeable and group.purgeable_pages > group.max_pages) {
                    self.discard(page, .evict);
                } else {
                    self.addToGroupLru(page);
                    self.record(.unpin, page);
                }
            }
        }
        return .ok;
    }

    pub fn pin(self: *Cache, page: *Page) void {
        self.enterGroup();
        defer self.leaveGroup();
        self.removeFromGroupLru(page);
        if (page.ref_count == 0) {
            page.ref_count = 1;
            self.ref_sum += 1;
        }
        self.record(.pin, page);
    }

    pub fn unpin(self: *Cache, page: *Page, discard_page: bool) Result {
        self.enterGroup();
        defer self.leaveGroup();
        if (page.ref_count != 0) return .busy;
        if (discard_page or (self.purgeable and self.pageGroup().purgeable_pages > self.pageGroup().max_pages)) {
            self.discard(page, if (discard_page) .drop else .evict);
        } else {
            self.clock +%= 1;
            page.lru_stamp = self.clock;
            self.addToGroupLru(page);
            self.record(.unpin, page);
        }
        return .ok;
    }

    pub fn drop(self: *Cache, page: *Page) Result {
        self.enterGroup();
        defer self.leaveGroup();
        if (page.ref_count != 1) return .corrupt;
        self.discard(page, .drop);
        return .ok;
    }

    pub fn makeDirty(self: *Cache, page: *Page) void {
        self.enterGroup();
        defer self.leaveGroup();
        self.removeFromGroupLru(page);
        page.flags.dont_write = false;
        if (!page.flags.dirty) self.insertDirtyFront(page);
        self.record(.dirty, page);
    }

    pub fn makeClean(self: *Cache, page: *Page) void {
        self.enterGroup();
        defer self.leaveGroup();
        self.removeDirty(page);
        page.flags.need_sync = false;
        page.flags.writeable = false;
        page.flags.dont_write = false;
        page.flags.wal_append = false;
        self.record(.clean, page);
        if (page.ref_count == 0 and self.purgeable and self.pageGroup().purgeable_pages > self.pageGroup().max_pages) {
            self.discard(page, .evict);
        } else {
            self.addToGroupLru(page);
        }
    }

    pub fn clearWritable(self: *Cache) void {
        var page = self.dirty_head;
        while (page) |current| : (page = current.dirty_next) {
            current.flags.writeable = false;
            current.flags.need_sync = false;
        }
        self.synced = self.dirty_tail;
    }

    pub fn clearSyncFlags(self: *Cache) void {
        var page = self.dirty_head;
        while (page) |current| : (page = current.dirty_next) current.flags.need_sync = false;
        self.recomputeSynced();
    }

    pub fn cleanAll(self: *Cache) void {
        while (self.dirty_head) |page| self.makeClean(page);
    }

    /// Source `sqlite3PcacheMove()`.
    pub fn move(self: *Cache, page: *Page, new_key: u32) Result {
        self.enterGroup();
        defer self.leaveGroup();
        if (new_key == 0) return .corrupt;
        if (self.pages.get(new_key)) |other| {
            if (other != page) {
                if (other.ref_count != 0) return .corrupt;
                self.discard(other, .drop);
            }
        }
        const old_key = page.key;
        if (old_key == new_key) return .ok;
        self.pages.rekey(page, old_key, new_key);
        if (page.flags.dirty and page.flags.need_sync) {
            self.removeDirty(page);
            self.insertDirtyFront(page);
        }
        self.record(.move, page);
        return .ok;
    }

    /// Source `sqlite3PcacheTruncate()` including retained page-1 zeroing.
    pub fn truncate(self: *Cache, maximum_key: u32) void {
        self.enterGroup();
        defer self.leaveGroup();
        var retained_page_one = false;
        if (maximum_key == 0 and self.ref_sum != 0) {
            if (self.pages.get(1)) |page_one| {
                @memset(page_one.data, 0);
                retained_page_one = true;
            }
        }
        while (true) {
            var candidate: ?*Page = null;
            var iterator = self.pages.iterator();
            while (iterator.next()) |entry| {
                const page = entry.value_ptr.*;
                const remove = page.key > maximum_key and !(retained_page_one and page.key == 1);
                if (remove and (candidate == null or page.key > candidate.?.key)) {
                    candidate = page;
                }
            }
            if (candidate) |page| self.discard(page, .truncate) else break;
        }
    }

    pub fn purge(self: *Cache, target_count: usize) usize {
        self.enterGroup();
        defer self.leaveGroup();
        if (!self.purgeable) return 0;
        var removed: usize = 0;
        while (self.pages.count() > target_count) {
            const victim = self.oldestUnpinnedClean() orelse break;
            self.discard(victim, .purge);
            removed += 1;
        }
        if (self.pages.count() == 0 and target_count == 0) self.releaseBulk();
        return removed;
    }

    pub fn shrink(self: *Cache) usize {
        self.enterGroup();
        defer self.leaveGroup();
        if (!self.purgeable) return 0;
        const group = self.pageGroup();
        const before = group.purgeable_pages;
        const saved = group.max_pages;
        group.max_pages = 0;
        self.enforceGroupMax();
        group.max_pages = saved;
        group.recomputeMaxPinned();
        if (self.pages.count() == 0) self.releaseBulk();
        return before - group.purgeable_pages;
    }
    pub fn ready(self: *const Cache) bool {
        return self.pages.ready();
    }
    pub fn pageCount(self: *const Cache) usize {
        const mutable: *Cache = @constCast(self);
        mutable.enterGroup();
        defer mutable.leaveGroup();
        return self.pages.count();
    }
    pub fn refCount(self: *const Cache) usize {
        return self.ref_sum;
    }
    pub fn isDirty(self: *const Cache) bool {
        return self.dirty_head != null;
    }

    pub fn percentDirty(self: *const Cache) usize {
        const configured = self.numberOfCachePages();
        if (configured == 0) return 0;
        var count: usize = 0;
        var page = self.dirty_head;
        while (page) |current| : (page = current.dirty_next) count += 1;
        return (count * 100) / configured;
    }

    fn enforceGroupMax(self: *Cache) void {
        const group = self.pageGroup();
        while (group.purgeable_pages > group.max_pages) {
            const victim = group.lru_tail orelse break;
            const owner = if (self.usesSharedGroup()) victim.owner orelse break else self;
            owner.discard(victim, .purge);
            if (owner.pages.count() == 0) owner.releaseBulk();
        }
    }

    /// Source `numberOfCachePages()`.
    fn numberOfCachePages(self: *const Cache) usize {
        if (self.configured_pages >= 0) return @intCast(self.configured_pages);
        const bytes: i128 = -1024 * @as(i128, self.configured_pages);
        const page_bytes = self.page_size + self.extra_size;
        if (page_bytes == 0) return 0;
        return @intCast(@min(@divTrunc(bytes, @as(i128, @intCast(page_bytes))), 1_000_000_000));
    }

    /// Source `pcache1Cachesize()` plus middleware signed-size conversion.
    pub fn setConfiguredCacheSize(self: *Cache, pages: i64) void {
        self.enterGroup();
        defer self.leaveGroup();
        self.configured_pages = pages;
        const requested = self.numberOfCachePages();
        var limit = @min(requested, 0x7fff_0000);
        const group = self.pageGroup();
        if (self.purgeable) {
            std.debug.assert(group.max_pages >= self.max_pages);
            const other_maximum = group.max_pages - self.max_pages;
            limit = @min(limit, 0x7fff_0000 -| other_maximum);
            group.max_pages = other_maximum + limit;
            group.recomputeMaxPinned();
        }
        self.max_pages = limit;
        self.enforceGroupMax();
        if (self.pages.count() == 0) self.releaseBulk();
    }

    pub fn setCacheSize(self: *Cache, pages: usize) void {
        self.setConfiguredCacheSize(@intCast(@min(pages, @as(usize, std.math.maxInt(i64)))));
    }

    /// Source `sqlite3PcacheSetSpillsize()`.
    pub fn setConfiguredSpillSize(self: *Cache, pages: i64) usize {
        if (pages != 0) {
            const requested = if (pages < 0) blk: {
                const page_bytes = self.page_size + self.extra_size;
                if (page_bytes == 0) break :blk 0;
                const bytes: i128 = -1024 * @as(i128, pages);
                const count = @divTrunc(bytes, @as(i128, @intCast(page_bytes)));
                break :blk @as(usize, @intCast(@min(count, std.math.maxInt(usize))));
            } else @as(usize, @intCast(pages));
            self.spill_size = requested;
        }
        return @max(self.numberOfCachePages(), self.spill_size);
    }

    pub fn setSpillSize(self: *Cache, pages: usize) void {
        _ = self.setConfiguredSpillSize(@intCast(@min(pages, @as(usize, std.math.maxInt(i64)))));
    }
    pub fn setPageSize(self: *Cache, page_size: usize) Result {
        self.enterGroup();
        defer self.leaveGroup();
        if (self.pages.count() != 0) return .busy;
        self.releaseBulk();
        self.page_size = page_size;
        var limit = @min(self.numberOfCachePages(), 0x7fff_0000);
        if (self.purgeable) {
            const group = self.pageGroup();
            std.debug.assert(group.max_pages >= self.max_pages);
            const other_maximum = group.max_pages - self.max_pages;
            limit = @min(limit, 0x7fff_0000 -| other_maximum);
            group.max_pages = other_maximum + limit;
            group.recomputeMaxPinned();
        }
        self.max_pages = limit;
        self.enforceGroupMax();
        return .ok;
    }
    pub fn clear(self: *Cache) void {
        self.truncate(0);
    }

    /// Source `pcacheMergeDirtyList()`: merge through the disposable sort
    /// linkage without touching the cache's LRU-ordered dirty linkage.
    fn mergeDirtyLists(first: *Page, second: *Page) *Page {
        var left: ?*Page = first;
        var right: ?*Page = second;
        var result: ?*Page = null;
        var tail: ?*Page = null;
        while (left != null and right != null) {
            const chosen = if (left.?.key < right.?.key) blk: {
                const value = left.?;
                left = value.sort_next;
                break :blk value;
            } else blk: {
                const value = right.?;
                right = value.sort_next;
                break :blk value;
            };
            chosen.sort_next = null;
            if (tail) |previous| {
                previous.sort_next = chosen;
            } else {
                result = chosen;
            }
            tail = chosen;
        }
        tail.?.sort_next = left orelse right;
        return result.?;
    }

    /// Source `pcacheSortDirtyList()`: fixed-bucket bottom-up merge sort. The
    /// source bound follows from SQLite's 2^31-page database limit.
    fn sortDirtyList(input_head: ?*Page) ?*Page {
        var buckets = [_]?*Page{null} ** 32;
        var input = input_head;
        while (input) |item| {
            input = item.sort_next;
            item.sort_next = null;
            var merged = item;
            var bucket: usize = 0;
            while (bucket < buckets.len - 1) : (bucket += 1) {
                const prior = buckets[bucket] orelse {
                    buckets[bucket] = merged;
                    break;
                };
                merged = mergeDirtyLists(prior, merged);
                buckets[bucket] = null;
            }
            if (bucket == buckets.len - 1) {
                if (buckets[bucket]) |prior| {
                    buckets[bucket] = mergeDirtyLists(prior, merged);
                } else {
                    buckets[bucket] = merged;
                }
            }
        }
        var result = buckets[0];
        for (buckets[1..]) |bucket| {
            if (bucket) |list| {
                if (result) |prior| {
                    result = mergeDirtyLists(prior, list);
                } else {
                    result = list;
                }
            }
        }
        return result;
    }

    /// Source `sqlite3PcacheDirtyList()`: return sorted dirty pages without an
    /// allocator dependency on the commit path.
    pub fn dirtyListHead(self: *Cache) ?*Page {
        self.enterGroup();
        defer self.leaveGroup();
        var page = self.dirty_head;
        while (page) |current| : (page = current.dirty_next) {
            current.sort_next = current.dirty_next;
        }
        return sortDirtyList(self.dirty_head);
    }

    pub fn dirtyList(self: *Cache, allocator: std.mem.Allocator) ![]*Page {
        var result = std.ArrayList(*Page).empty;
        errdefer result.deinit(allocator);
        var page = self.dirtyListHead();
        while (page) |current| : (page = current.sort_next) {
            try result.append(allocator, current);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn checkInvariants(self: *Cache) bool {
        self.enterGroup();
        defer self.leaveGroup();
        var refs: usize = 0;
        var dirty_count: usize = 0;
        var recyclable_count: usize = 0;
        var iterator = self.pages.iterator();
        while (iterator.next()) |entry| {
            const page = entry.value_ptr.*;
            if (entry.key_ptr.* != page.key or page.key == 0 or page.data.len != self.page_size or page.extra.len != self.extra_size) return false;
            if (self.usesSharedGroup()) {
                if (page.owner != self) return false;
            } else {
                page.owner = self;
            }
            refs += page.ref_count;
            if (page.flags.dirty) dirty_count += 1 else if (page.dirty_prev != null or page.dirty_next != null) return false;
            if (page.on_group_lru) {
                if (!self.purgeable or page.ref_count != 0 or page.flags.dirty) return false;
                recyclable_count += 1;
            } else if (self.purgeable and page.ref_count == 0 and !page.flags.dirty) return false;
        }
        if (refs != self.ref_sum or recyclable_count != self.recyclable_pages) return false;
        var listed: usize = 0;
        var previous: ?*Page = null;
        var cursor = self.dirty_head;
        while (cursor) |page| : (cursor = page.dirty_next) {
            if (!page.flags.dirty or page.dirty_prev != previous) return false;
            previous = page;
            listed += 1;
            if (listed > self.pages.count()) return false;
        }
        if (previous != self.dirty_tail or listed != dirty_count) return false;
        if (self.synced) |page| if (!page.flags.dirty or page.flags.need_sync) return false;
        return true;
    }
};

fn cleanStress(context: ?*anyopaque, page: *Page) Result {
    const cache: *Cache = @ptrCast(@alignCast(context.?));
    cache.makeClean(page);
    return .ok;
}

test "source-shaped cache owner precedes initial hash allocation" {
    var owner_failure = OneShotFailAllocator.init(std.testing.allocator, 0);
    try std.testing.expect(Cache.create(owner_failure.allocator(), 512, 16, true, 10, null) == null);
    try std.testing.expect(owner_failure.induced_failure);

    var hash_failure = OneShotFailAllocator.init(std.testing.allocator, 1);
    try std.testing.expect(Cache.create(hash_failure.allocator(), 512, 16, true, 10, null) == null);
    try std.testing.expect(hash_failure.induced_failure);

    const cache = Cache.create(std.testing.allocator, 512, 16, true, 10, null) orelse return error.OutOfMemory;
    try std.testing.expect(cache.ready());
    try std.testing.expect(cache.pageGroup() == &cache.private_group);
    cache.destroy();
}

test "source-shaped page hash initializes and treats later resize OOM as benign" {
    var initial_failure = OneShotFailAllocator.init(std.testing.allocator, 0);
    var unavailable = Cache.init(initial_failure.allocator(), 512, 16, true, 10);
    try std.testing.expect(!unavailable.ready());
    try std.testing.expectEqual(Result.out_of_memory, unavailable.fetch(1, .hard_create, null).result);
    unavailable.deinit();

    var resize_failure = OneShotFailAllocator.init(std.testing.allocator, 1);
    var table = PageTable.init(resize_failure.allocator());
    defer table.deinit();
    try std.testing.expect(table.ready());
    try std.testing.expectEqual(@as(usize, 256), table.buckets.?.len);
    table.page_count = 256;
    try table.ensureUnusedCapacity(1);
    try std.testing.expect(resize_failure.induced_failure);
    try std.testing.expectEqual(@as(usize, 256), table.buckets.?.len);
}

test "process lifecycle initializes static buffer and clears state" {
    var lifecycle = Lifecycle{};
    var storage: [2048]u8 align(8) = undefined;
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, &storage, 4));
    try std.testing.expect(lifecycle.initialized and lifecycle.separate_cache and lifecycle.static_mutexes);
    try std.testing.expectEqual(@as(c_int, 10), lifecycle.max_pinned);
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initial_pages);
    lifecycle.setupBuffer(&storage, 515, 4);
    try std.testing.expectEqual(@as(c_int, 512), lifecycle.slot_size);
    try std.testing.expectEqual(@as(c_int, 4), lifecycle.slot_count);
    try std.testing.expectEqual(@as(c_int, 1), lifecycle.reserve_count);
    try std.testing.expect(lifecycle.start == @as(*anyopaque, @ptrCast(&storage)));
    try std.testing.expect(@intFromPtr(lifecycle.end.?) - @intFromPtr(lifecycle.start.?) == 2048);
    var slots: usize = 0;
    var slot = lifecycle.free;
    while (slot) |value| : (slot = value.next) slots += 1;
    try std.testing.expectEqual(@as(usize, 4), slots);
    lifecycle.shutdown();
    try std.testing.expect(!lifecycle.initialized and lifecycle.start == null and lifecycle.free == null);
}

test "process lifecycle mode and null-buffer rules" {
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(false, null, -20));
    try std.testing.expect(lifecycle.separate_cache and !lifecycle.static_mutexes);
    try std.testing.expectEqual(@as(c_int, -20), lifecycle.initial_pages);
    lifecycle.setupBuffer(null, 512, 4);
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.slot_size);
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.slot_count);
    try std.testing.expectEqual(@as(c_int, 1), lifecycle.reserve_count);
    lifecycle.shutdown();

    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(false, @ptrFromInt(8), 4));
    try std.testing.expect(!lifecycle.separate_cache);
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initial_pages);
}

test "cache consumes and returns process static slots with heap fallback" {
    var lifecycle = Lifecycle{};
    var storage: [4096]u8 align(8) = undefined;
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, &storage, 4));
    lifecycle.setupBuffer(&storage, 1024, 4);
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    const direct_static = lifecycle.pageMalloc(512).?;
    try std.testing.expect(lifecycle.isStaticPointer(direct_static));
    lifecycle.pageFree(direct_static);
    try std.testing.expectEqual(@as(c_int, 4), lifecycle.free_slot_count);
    var cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 8, &lifecycle);
    var static_pages: [4]*Page = undefined;
    for (1..5) |key| {
        const fetched = cache.fetch(@intCast(key), .hard_create, null);
        try std.testing.expectEqual(Result.ok, fetched.result);
        const page = fetched.page.?;
        static_pages[key - 1] = page;
        try std.testing.expect(page.static_slot != null);
        try std.testing.expect(@intFromPtr(page.static_slot.?) >= @intFromPtr(&storage));
        try std.testing.expect(@intFromPtr(page.static_slot.?) < @intFromPtr(&storage) + storage.len);
    }
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.free_slot_count);
    try std.testing.expect(lifecycle.under_pressure);
    try std.testing.expectEqual(@as(i64, 4), manager.status(.pagecache_used, false).current);
    const overflow = cache.fetch(5, .hard_create, null);
    try std.testing.expectEqual(Result.ok, overflow.result);
    try std.testing.expectEqual(null, overflow.page.?.static_slot);
    try std.testing.expect(manager.status(.pagecache_overflow, false).current > 0);
    try std.testing.expect(manager.status(.memory_used, false).current > 0);
    for (static_pages) |page| {
        try std.testing.expectEqual(Result.ok, cache.release(page));
    }
    try std.testing.expectEqual(Result.ok, cache.release(overflow.page.?));
    cache.clear();
    try std.testing.expectEqual(@as(c_int, 4), lifecycle.free_slot_count);
    try std.testing.expect(!lifecycle.under_pressure);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_used, false).current);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_overflow, false).current);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    const direct_heap = lifecycle.pageMalloc(2048).?;
    try std.testing.expect(!lifecycle.isStaticPointer(direct_heap));
    try std.testing.expect(manager.status(.pagecache_overflow, false).current > 0);
    lifecycle.pageFree(direct_heap);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_overflow, false).current);
    cache.deinit();
    lifecycle.shutdown();
    manager.stop();
}

test "per-cache bulk pages precede PCache slots and release as one Manager allocation" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, null, 3));
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    var cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 5, &lifecycle);
    for (1..4) |key| {
        const fetched = cache.fetch(@intCast(key), .hard_create, null);
        try std.testing.expectEqual(Result.ok, fetched.result);
        try std.testing.expect(fetched.page.?.bulk_local);
        try std.testing.expectEqual(Result.ok, cache.release(fetched.page.?));
    }
    try std.testing.expectEqual(@as(usize, 3), cache.bulk_page_count);
    try std.testing.expectEqual(@as(usize, 0), cache.bulk_free_count);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_overflow, false).current);
    const overflow = cache.fetch(4, .hard_create, null);
    try std.testing.expectEqual(Result.ok, overflow.result);
    try std.testing.expect(!overflow.page.?.bulk_local and overflow.page.?.process_heap != null);
    try std.testing.expect(manager.status(.pagecache_overflow, false).current > 0);
    try std.testing.expectEqual(Result.ok, cache.release(overflow.page.?));
    cache.clear();
    try std.testing.expectEqual(@as(usize, 3), cache.bulk_free_count);
    try std.testing.expect(cache.bulk_pointer != null);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_overflow, false).current);
    try std.testing.expect(manager.status(.memory_used, false).current > 0);
    _ = cache.shrink();
    try std.testing.expect(cache.bulk_pointer == null);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    cache.deinit();
    lifecycle.shutdown();
    manager.stop();
}

test "bulk byte mode and cache-size cap preserve configured arithmetic" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());

    var byte_lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), byte_lifecycle.initialize(true, null, -2));
    byte_lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    var byte_cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 10, &byte_lifecycle);
    try std.testing.expectEqual(Result.ok, byte_cache.fetch(1, .hard_create, null).result);
    try std.testing.expectEqual(@as(usize, 2048), byte_cache.bulk_size);
    try std.testing.expectEqual(@as(usize, 2048) / byte_cache.pageLayout().allocation_size, byte_cache.bulk_page_count);
    byte_cache.deinit();
    byte_lifecycle.shutdown();

    var capped_lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), capped_lifecycle.initialize(true, null, 20));
    capped_lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    var capped_cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 3, &capped_lifecycle);
    try std.testing.expectEqual(Result.ok, capped_cache.fetch(1, .hard_create, null).result);
    try std.testing.expectEqual(@as(usize, 3), capped_cache.bulk_page_count);
    try std.testing.expectEqual(capped_cache.pageLayout().allocation_size * 3, capped_cache.bulk_size);
    capped_cache.deinit();
    capped_lifecycle.shutdown();
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    manager.stop();
}

test "bulk allocation OOM is benign before ordinary page fallback" {
    var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0 };
    var manager = memory.Manager.init(fault.backend());
    try std.testing.expectEqual(memory.ok, manager.start());
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, null, 4));
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    var cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 4, &lifecycle);
    const fetched = cache.fetch(1, .hard_create, null);
    try std.testing.expectEqual(Result.ok, fetched.result);
    try std.testing.expect(!fetched.page.?.bulk_local and fetched.page.?.process_heap != null);
    try std.testing.expect(cache.bulk_pointer == null);
    try std.testing.expectEqual(@as(usize, 2), fault.attempt_count);
    cache.deinit();
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    lifecycle.shutdown();
    manager.stop();
}

test "process heap OOM leaves PCache and Manager ownership unchanged" {
    var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = 0, .sticky = true };
    var manager = memory.Manager.init(fault.backend());
    try std.testing.expectEqual(memory.ok, manager.start());
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, null, 0));
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    var cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 4, &lifecycle);
    const fetched = cache.fetch(1, .hard_create, null);
    try std.testing.expectEqual(Result.out_of_memory, fetched.result);
    try std.testing.expectEqual(@as(usize, 0), cache.pageCount());
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_overflow, false).current);
    cache.deinit();
    lifecycle.shutdown();
    manager.stop();
}

test "concurrent direct page allocation preserves slots heap and status" {
    var storage: [8192]u8 align(8) = undefined;
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, &storage, 8));
    lifecycle.setupBuffer(&storage, 1024, 8);
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    const count = 16;
    var ready = std.atomic.Value(usize).init(0);
    var pointers: [count]?*anyopaque = .{null} ** count;
    const Worker = struct {
        fn run(owner: *Lifecycle, ready_count: *std.atomic.Value(usize), output: *?*anyopaque) void {
            output.* = owner.pageMalloc(512);
            _ = ready_count.fetchAdd(1, .acq_rel);
            while (ready_count.load(.acquire) != count) std.atomic.spinLoopHint();
            owner.pageFree(output.*);
        }
    };
    var threads: [count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &lifecycle, &ready, &pointers[index] });
    for (&threads) |*thread| thread.join();
    for (pointers) |pointer| try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(c_int, 8), lifecycle.free_slot_count);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_used, false).current);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.pagecache_overflow, false).current);
    try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
    lifecycle.shutdown();
    manager.stop();
}

test "unified PGroup recycles and enforces limits across caches" {
    var storage: [8192]u8 align(8) = undefined;
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(false, &storage, 8));
    try std.testing.expect(!lifecycle.separate_cache);
    lifecycle.setupBuffer(&storage, 1024, 8);
    lifecycle.attachInfrastructure(&manager, null, null);

    var first = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 3, &lifecycle);
    var second = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 3, &lifecycle);
    try std.testing.expectEqual(@as(usize, 6), lifecycle.shared_group.max_pages);
    try std.testing.expectEqual(@as(usize, 20), lifecycle.shared_group.min_pages);

    const first_one = first.fetch(1, .hard_create, null).page.?;
    const recycled_address = @intFromPtr(first_one);
    const recycled_slot = first_one.static_slot;
    const first_two = first.fetch(2, .hard_create, null).page.?;
    try std.testing.expectEqual(Result.ok, first.release(first_one));
    try std.testing.expectEqual(Result.ok, first.release(first_two));
    const second_ten = second.fetch(10, .hard_create, null).page.?;
    const second_eleven = second.fetch(11, .hard_create, null).page.?;
    try std.testing.expectEqual(Result.ok, second.release(second_ten));
    try std.testing.expectEqual(Result.ok, second.release(second_eleven));
    try std.testing.expectEqual(@as(usize, 4), lifecycle.shared_group.purgeable_pages);
    try std.testing.expectEqual(@as(c_int, 4), lifecycle.free_slot_count);

    const second_twelve = second.fetch(12, .hard_create, null).page.?;
    try std.testing.expectEqual(recycled_address, @intFromPtr(second_twelve));
    try std.testing.expectEqual(recycled_slot, second_twelve.static_slot);
    try std.testing.expect(first.pages.get(1) == null and first.pages.get(2) != null);
    try std.testing.expect(second.pages.get(12) == second_twelve);
    try std.testing.expectEqual(@as(usize, 4), lifecycle.shared_group.purgeable_pages);
    try std.testing.expectEqual(@as(c_int, 4), lifecycle.free_slot_count);
    try std.testing.expectEqual(Result.ok, second.release(second_twelve));
    try std.testing.expect(first.checkInvariants() and second.checkInvariants());

    first.setCacheSize(1);
    second.setCacheSize(1);
    try std.testing.expectEqual(@as(usize, 2), lifecycle.shared_group.max_pages);
    try std.testing.expectEqual(@as(usize, 2), lifecycle.shared_group.purgeable_pages);
    try std.testing.expectEqual(@as(usize, 0), first.pageCount());
    try std.testing.expectEqual(@as(usize, 2), second.pageCount());
    try std.testing.expectEqual(@as(usize, 2), first.shrink());
    try std.testing.expectEqual(@as(usize, 0), second.pageCount());
    try std.testing.expectEqual(@as(usize, 0), lifecycle.shared_group.purgeable_pages);
    try std.testing.expectEqual(@as(c_int, 8), lifecycle.free_slot_count);

    first.deinit();
    second.deinit();
    try std.testing.expectEqual(@as(usize, 0), lifecycle.shared_group.max_pages);
    try std.testing.expectEqual(@as(usize, 0), lifecycle.shared_group.min_pages);
    lifecycle.shutdown();
    manager.stop();
}

test "cache state references dirty list move truncate and invariants" {
    var cache = Cache.init(std.testing.allocator, 1024, 32, true, 4);
    defer cache.deinit();
    const one = cache.fetch(1, .hard_create, null).page.?;
    const three = cache.fetch(3, .hard_create, null).page.?;
    const two = cache.fetch(2, .hard_create, null).page.?;
    try std.testing.expectEqual(@as(usize, 3), cache.refCount());
    cache.makeDirty(three);
    three.flags.need_sync = true;
    cache.makeDirty(one);
    cache.makeDirty(two);
    const dirty = try cache.dirtyList(std.testing.allocator);
    defer std.testing.allocator.free(dirty);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &[_]u32{ dirty[0].key, dirty[1].key, dirty[2].key });
    try std.testing.expectEqual(.ok, cache.release(one));
    cache.reference(one);
    try std.testing.expectEqual(@as(u32, 1), one.ref_count);
    try std.testing.expectEqual(.ok, cache.move(two, 8));
    cache.clearSyncFlags();
    cache.clearWritable();
    cache.truncate(3);
    try std.testing.expect(cache.pages.get(8) == null);
    try std.testing.expect(cache.checkInvariants());
}

test "deterministic LRU eviction and stress cleanup" {
    var cache = Cache.init(std.testing.allocator, 512, 0, true, 2);
    defer cache.deinit();
    cache.setSpillSize(1);
    const one = cache.fetch(1, .hard_create, null).page.?;
    const two = cache.fetch(2, .hard_create, null).page.?;
    try std.testing.expectEqual(.ok, cache.release(one));
    try std.testing.expectEqual(.ok, cache.release(two));
    _ = cache.fetch(3, .hard_create, null);
    try std.testing.expect(cache.pages.get(1) == null);
    try std.testing.expect(cache.pages.get(2) != null);
    const page2 = cache.pages.get(2).?;
    cache.makeDirty(page2);
    _ = cache.fetch(2, .lookup, null);
    try std.testing.expectEqual(.ok, cache.release(page2));
    _ = cache.fetch(4, .hard_create, .{ .callback = cleanStress, .context = &cache });
    try std.testing.expect(cache.pages.get(2) == null);
    try std.testing.expect(cache.checkInvariants());
}

test "versioned eviction workload is deterministic and invariant-preserving" {
    var cache = Cache.init(std.testing.allocator, 256, 4, true, 3);
    defer cache.deinit();
    for (1..4) |key| {
        const page = cache.fetch(@intCast(key), .hard_create, null).page.?;
        try std.testing.expect(cache.checkInvariants());
        try std.testing.expectEqual(.ok, cache.release(page));
        try std.testing.expect(cache.checkInvariants());
    }
    const four = cache.fetch(4, .hard_create, null).page.?;
    try std.testing.expect(cache.checkInvariants());
    _ = cache.release(four);
    try std.testing.expectEqual(Result.not_found, cache.fetch(2, .lookup, null).result);
    const three = cache.fetch(3, .lookup, null).page.?;
    _ = cache.release(three);
    const five = cache.fetch(5, .hard_create, null).page.?;
    try std.testing.expect(cache.checkInvariants());
    _ = cache.release(five);
    const six = cache.fetch(6, .hard_create, null).page.?;
    _ = cache.release(six);
    try std.testing.expect(cache.checkInvariants());
    var evicted: [4]u32 = undefined;
    var count: usize = 0;
    for (cache.events.items) |event| if (event.kind == .evict) {
        if (count < evicted.len) evicted[count] = event.key;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 4, 3 }, &evicted);
}

test "page size changes only while empty" {
    var cache = Cache.init(std.testing.allocator, 256, 4, true, 2);
    defer cache.deinit();
    try std.testing.expectEqual(.ok, cache.setPageSize(1024));
    const page = cache.fetch(1, .hard_create, null).page.?;
    try std.testing.expectEqual(@as(usize, 1024), page.data.len);
    try std.testing.expectEqual(.busy, cache.setPageSize(512));
    try std.testing.expectEqual(Result.ok, cache.release(page));
    cache.clear();
    try std.testing.expectEqual(.ok, cache.setPageSize(512));
    try std.testing.expect(cache.checkInvariants());
}

test "static and heap pressure govern soft creation and recycling" {
    var storage: [2048]u8 align(8) = undefined;
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    var lifecycle = Lifecycle{};
    try std.testing.expectEqual(@as(c_int, 0), lifecycle.initialize(true, &storage, 2));
    lifecycle.setupBuffer(&storage, 1024, 2);
    lifecycle.attachInfrastructure(
        &manager,
        .{ .native = mutex.processStatic(.static_lru) },
        .{ .native = mutex.processStatic(.static_pmem) },
    );
    const held_a = lifecycle.pageMalloc(512).?;
    const held_b = lifecycle.pageMalloc(512).?;
    try std.testing.expect(lifecycle.underMemoryPressure(544));
    try std.testing.expect(!lifecycle.underMemoryPressure(2048));

    var cache = Cache.initWithLifecycle(std.testing.allocator, 512, 32, true, 10, &lifecycle);
    const pinned = cache.fetch(1, .hard_create, null).page.?;
    try std.testing.expectEqual(Result.busy, cache.fetch(2, .soft_create, null).result);
    try std.testing.expectEqual(Result.ok, cache.release(pinned));
    const recycled = cache.fetch(2, .soft_create, null);
    try std.testing.expectEqual(Result.ok, recycled.result);
    try std.testing.expectEqual(@as(usize, 1), cache.pageCount());
    try std.testing.expect(cache.pages.get(1) == null);

    _ = manager.setSoftLimit(1);
    try std.testing.expect(lifecycle.underMemoryPressure(2048));
    _ = manager.setSoftLimit(0);
    try std.testing.expectEqual(Result.ok, cache.release(recycled.page.?));
    cache.clear();
    lifecycle.pageFree(held_a);
    try std.testing.expect(!lifecycle.underMemoryPressure(544));
    lifecycle.pageFree(held_b);
    cache.deinit();
    lifecycle.shutdown();
    manager.stop();
}

test "soft fetch pressure purge and ownership" {
    var cache = Cache.init(std.testing.allocator, 256, 8, true, 1);
    defer cache.deinit();
    const one = cache.fetch(1, .hard_create, null).page.?;
    const soft = cache.fetch(2, .soft_create, null);
    try std.testing.expectEqual(Result.busy, soft.result);
    try std.testing.expectEqual(.ok, cache.release(one));
    try std.testing.expectEqual(Result.ok, cache.fetch(2, .hard_create, null).result);
    const two = cache.pages.get(2).?;
    try std.testing.expectEqual(.ok, cache.release(two));
    try std.testing.expectEqual(@as(usize, 1), cache.shrink());
    try std.testing.expectEqual(@as(usize, 0), cache.pageCount());
    try std.testing.expect(cache.checkInvariants());
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var cache = Cache.init(allocator, 128, 17, true, 3);
    defer cache.deinit();
    for (1..5) |key| {
        const fetched = cache.fetch(@intCast(key), .hard_create, .{ .callback = cleanStress, .context = &cache });
        if (fetched.result == .out_of_memory) return error.OutOfMemory;
        if (fetched.page) |page| {
            cache.makeDirty(page);
            cache.makeClean(page);
            if (key == 1 and cache.move(page, 101) == .out_of_memory) return error.OutOfMemory;
            _ = cache.release(page);
        }
    }
    const list = cache.dirtyList(allocator) catch return error.OutOfMemory;
    allocator.free(list);
}

test "bounded sticky and one-shot allocation failure and ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
    var completed = false;
    for (0..64) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        allocationExercise(failing.allocator()) catch |err| try std.testing.expect(err == error.OutOfMemory);
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}
