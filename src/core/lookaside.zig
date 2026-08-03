//! Two-size per-connection lookaside allocator translated from `setupLookaside`
//! and the lookaside paths in `malloc.c`.

const std = @import("std");
const memory = @import("memory.zig");

pub const small_slot_size: usize = 128;

const Slot = extern struct { next: ?*Slot };

pub const ConfigureError = error{ Busy, OutOfMemory };
pub const Counter = enum { hit, miss_size, miss_full };
pub const Used = struct { current: usize, highwater: usize };

pub const Lookaside = struct {
    manager: *memory.Manager,
    start: ?[*]align(8) u8 = null,
    storage_len: usize = 0,
    middle_offset: usize = 0,
    end_offset: usize = 0,
    big_size: usize = 0,
    big_init: ?*Slot = null,
    big_free: ?*Slot = null,
    small_init: ?*Slot = null,
    small_free: ?*Slot = null,
    slot_count: usize = 0,
    current: usize = 0,
    highwater: usize = 0,
    counters: [3]u64 = .{ 0, 0, 0 },
    malloced: bool = false,
    disabled: bool = true,
    malloc_failed: bool = false,

    pub fn init(manager: *memory.Manager) Lookaside {
        return .{ .manager = manager };
    }

    pub fn deinit(self: *Lookaside) void {
        std.debug.assert(self.current == 0);
        self.releaseOwned();
        self.* = .{ .manager = self.manager };
    }

    fn releaseOwned(self: *Lookaside) void {
        if (self.malloced) {
            if (self.start) |pointer| self.manager.free(@ptrCast(pointer));
        }
    }

    fn push(head: *?*Slot, slot: *Slot) void {
        slot.next = head.*;
        head.* = slot;
    }

    fn pop(head: *?*Slot) ?*Slot {
        const slot = head.* orelse return null;
        head.* = slot.next;
        return slot;
    }

    pub fn configure(
        self: *Lookaside,
        external: ?[]align(8) u8,
        requested_size: i32,
        requested_count: i32,
    ) ConfigureError!void {
        if (self.current != 0) return error.Busy;
        self.releaseOwned();

        var slot_size: usize = if (requested_size > 0) @intCast(requested_size) else 0;
        slot_size &= ~@as(usize, 7);
        if (slot_size <= @sizeOf(?*Slot)) slot_size = 0;
        slot_size = @min(slot_size, 65_528);
        var count: usize = if (requested_count > 0) @intCast(requested_count) else 0;
        if (slot_size > 0 and count > 0x7fff0000 / slot_size) count = 0x7fff0000 / slot_size;
        var allocation_size = slot_size * count;

        var start: ?[*]align(8) u8 = null;
        var malloced = false;
        if (allocation_size != 0) {
            if (external) |buffer| {
                allocation_size = @min(allocation_size, buffer.len);
                start = buffer.ptr;
            } else {
                const raw = self.manager.alloc(allocation_size) orelse return error.OutOfMemory;
                start = @ptrCast(@alignCast(raw));
                allocation_size = self.manager.size(raw);
                malloced = true;
            }
        }

        self.start = start;
        self.storage_len = allocation_size;
        self.big_size = slot_size;
        self.big_init = null;
        self.big_free = null;
        self.small_init = null;
        self.small_free = null;
        self.current = 0;
        self.highwater = 0;
        self.counters = .{ 0, 0, 0 };
        self.malloced = malloced;
        self.malloc_failed = false;

        if (start == null or slot_size == 0) {
            self.disabled = true;
            self.slot_count = 0;
            self.middle_offset = 0;
            self.end_offset = 0;
            return;
        }

        var big_count: usize = undefined;
        var small_count: usize = undefined;
        if (slot_size >= small_slot_size * 3) {
            big_count = allocation_size / (3 * small_slot_size + slot_size);
            small_count = (allocation_size - slot_size * big_count) / small_slot_size;
        } else if (slot_size >= small_slot_size * 2) {
            big_count = allocation_size / (small_slot_size + slot_size);
            small_count = (allocation_size - slot_size * big_count) / small_slot_size;
        } else {
            big_count = allocation_size / slot_size;
            small_count = 0;
        }

        var offset: usize = 0;
        for (0..big_count) |_| {
            const slot: *Slot = @ptrCast(@alignCast(start.? + offset));
            push(&self.big_init, slot);
            offset += slot_size;
        }
        self.middle_offset = offset;
        for (0..small_count) |_| {
            const slot: *Slot = @ptrCast(@alignCast(start.? + offset));
            push(&self.small_init, slot);
            offset += small_slot_size;
        }
        self.end_offset = offset;
        self.slot_count = big_count + small_count;
        self.disabled = false;
    }

    fn take(self: *Lookaside, head_free: *?*Slot, head_init: *?*Slot) ?*anyopaque {
        const slot = pop(head_free) orelse pop(head_init) orelse return null;
        self.current += 1;
        self.highwater = @max(self.highwater, self.current);
        self.counters[@intFromEnum(Counter.hit)] += 1;
        return slot;
    }

    pub fn allocZero(self: *Lookaside, requested: usize) ?*anyopaque {
        const pointer = self.alloc(requested) orelse return null;
        @memset(@as([*]u8, @ptrCast(pointer))[0..requested], 0);
        return pointer;
    }

    pub fn alloc(self: *Lookaside, requested: usize) ?*anyopaque {
        if (!self.disabled and requested <= self.big_size) {
            if (requested <= small_slot_size) {
                if (self.take(&self.small_free, &self.small_init)) |pointer| return pointer;
            }
            if (self.take(&self.big_free, &self.big_init)) |pointer| return pointer;
            self.counters[@intFromEnum(Counter.miss_full)] += 1;
        } else {
            if (!self.disabled) self.counters[@intFromEnum(Counter.miss_size)] += 1;
            if (self.malloc_failed) return null;
        }
        const pointer = self.manager.alloc(requested);
        if (pointer == null) {
            self.malloc_failed = true;
            self.disabled = true;
        }
        return pointer;
    }

    fn offsetOf(self: *const Lookaside, pointer: *anyopaque) ?usize {
        const start = self.start orelse return null;
        const address = @intFromPtr(pointer);
        const first = @intFromPtr(start);
        if (address < first or address >= first + self.end_offset) return null;
        return address - first;
    }

    pub fn isLookaside(self: *const Lookaside, pointer: *anyopaque) bool {
        return self.offsetOf(pointer) != null;
    }

    pub fn allocationSize(self: *const Lookaside, pointer: *anyopaque) usize {
        if (self.offsetOf(pointer)) |offset| return if (offset >= self.middle_offset) small_slot_size else self.big_size;
        return self.manager.size(pointer);
    }

    pub fn free(self: *Lookaside, pointer: ?*anyopaque) void {
        const value = pointer orelse return;
        if (self.offsetOf(value)) |offset| {
            const slot: *Slot = @ptrCast(@alignCast(value));
            if (offset >= self.middle_offset) push(&self.small_free, slot) else push(&self.big_free, slot);
            std.debug.assert(self.current > 0);
            self.current -= 1;
            return;
        }
        self.manager.free(value);
    }

    pub fn realloc(self: *Lookaside, pointer: ?*anyopaque, requested: usize) ?*anyopaque {
        const value = pointer orelse return self.alloc(requested);
        if (self.offsetOf(value)) |_| {
            const old_size = self.allocationSize(value);
            if (requested <= old_size) return value;
            const replacement = self.alloc(requested) orelse return null;
            @memcpy(@as([*]u8, @ptrCast(replacement))[0..old_size], @as([*]const u8, @ptrCast(value))[0..old_size]);
            self.free(value);
            return replacement;
        }
        return self.manager.realloc(value, requested);
    }

    pub fn reallocOrFree(self: *Lookaside, pointer: ?*anyopaque, requested: usize) ?*anyopaque {
        const replacement = self.realloc(pointer, requested);
        if (replacement == null) self.free(pointer);
        return replacement;
    }

    pub fn clearOom(self: *Lookaside) void {
        self.malloc_failed = false;
        self.disabled = self.start == null;
    }

    pub fn used(self: *Lookaside, reset: bool) Used {
        const result = Used{ .current = self.current, .highwater = self.highwater };
        if (reset) self.highwater = self.current;
        return result;
    }

    pub fn counter(self: *Lookaside, which: Counter, reset: bool) u64 {
        const index = @intFromEnum(which);
        const result = self.counters[index];
        if (reset) self.counters[index] = 0;
        return result;
    }
};

test "default profile partitions 1200x40 into big and small slots" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var lookaside = Lookaside.init(&manager);
    try lookaside.configure(null, 1200, 40);
    defer lookaside.deinit();
    // The system allocator's usable size can add slots; minimum documented counts hold.
    var big: usize = 0;
    var small: usize = 0;
    var p = lookaside.big_init;
    while (p) |slot| : (p = slot.next) big += 1;
    p = lookaside.small_init;
    while (p) |slot| : (p = slot.next) small += 1;
    try std.testing.expect(big >= 30);
    try std.testing.expect(small >= 90);
}

test "eligibility fallback statistics reconfiguration and content preservation" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var storage: [4096]u8 align(8) = undefined;
    var lookaside = Lookaside.init(&manager);
    try lookaside.configure(&storage, 512, 8);
    defer lookaside.deinit();
    const small = lookaside.alloc(64).?;
    const big = lookaside.alloc(400).?;
    try std.testing.expect(lookaside.isLookaside(small));
    try std.testing.expect(lookaside.isLookaside(big));
    try std.testing.expectError(error.Busy, lookaside.configure(null, 128, 2));
    @as([*]u8, @ptrCast(big))[0] = 0x7b;
    const grown = lookaside.realloc(big, 1000).?;
    try std.testing.expectEqual(@as(u8, 0x7b), @as([*]u8, @ptrCast(grown))[0]);
    lookaside.free(grown);
    lookaside.free(small);
    try std.testing.expectEqual(@as(usize, 0), lookaside.used(false).current);
    try std.testing.expectEqual(@as(u64, 2), lookaside.counter(.hit, false));
    try std.testing.expectEqual(@as(u64, 1), lookaside.counter(.miss_size, false));
    try lookaside.configure(null, 0, 0);
    try std.testing.expect(lookaside.disabled);
}

test "bounded one-shot and sticky faults preserve lookaside ownership" {
    inline for ([_]bool{ false, true }) |sticky| {
        var completed = false;
        for (0..10) |fail_index| {
            var fault = memory.FaultingBackend{ .inner = memory.systemBackend(), .fail_at = fail_index, .sticky = sticky };
            var manager = memory.Manager.init(fault.backend());
            try std.testing.expectEqual(memory.ok, manager.start());
            var arena = Lookaside.init(&manager);
            if (arena.configure(null, 512, 8)) |_| {
                var first = arena.alloc(64);
                const second = arena.alloc(1000);
                if (first) |pointer| {
                    if (arena.realloc(pointer, 2000)) |replacement| first = replacement;
                }
                arena.free(second);
                arena.free(first);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
            arena.deinit();
            try std.testing.expectEqual(@as(i64, 0), manager.status(.memory_used, false).current);
            manager.stop();
            if (!fault.fired) {
                completed = true;
                break;
            }
        }
        try std.testing.expect(completed);
    }
}

test "full lookaside falls back and records miss" {
    var manager = memory.Manager.init(memory.systemBackend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    var storage: [256]u8 align(8) = undefined;
    var lookaside = Lookaside.init(&manager);
    try lookaside.configure(&storage, 128, 2);
    defer lookaside.deinit();
    const a = lookaside.alloc(100).?;
    const b = lookaside.alloc(100).?;
    const c = lookaside.alloc(100).?;
    try std.testing.expect(!lookaside.isLookaside(c));
    try std.testing.expectEqual(@as(u64, 1), lookaside.counter(.miss_full, false));
    lookaside.free(c);
    lookaside.free(b);
    lookaside.free(a);
}
