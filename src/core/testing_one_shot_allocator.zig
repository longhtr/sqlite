//! Test allocator that fails exactly one selected allocation attempt.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OneShotFailAllocator = struct {
    backing: Allocator,
    fail_index: usize,
    attempt_index: usize = 0,
    induced_failure: bool = false,

    pub fn init(backing: Allocator, fail_index: usize) OneShotFailAllocator {
        return .{ .backing = backing, .fail_index = fail_index };
    }

    pub fn allocator(self: *OneShotFailAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn shouldFail(self: *OneShotFailAllocator) bool {
        defer self.attempt_index += 1;
        if (!self.induced_failure and self.attempt_index == self.fail_index) {
            self.induced_failure = true;
            return true;
        }
        return false;
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(context));
        if (self.shouldFail()) return null;
        return self.backing.rawAlloc(length, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(context));
        if (self.shouldFail()) return false;
        return self.backing.rawResize(memory, alignment, new_length, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(context));
        if (self.shouldFail()) return null;
        return self.backing.rawRemap(memory, alignment, new_length, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};
