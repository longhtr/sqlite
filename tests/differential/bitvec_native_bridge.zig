const std = @import("std");
const BitVec = @import("bitvec").BitVec;

const allocator = std.heap.c_allocator;

fn fromOpaque(handle: *anyopaque) *BitVec {
    return @ptrCast(@alignCast(handle));
}

pub export fn probe_initialize() callconv(.c) c_int {
    return 0;
}

pub export fn probe_shutdown() callconv(.c) void {}

pub export fn probe_bitvec_create(size: u32) callconv(.c) ?*anyopaque {
    return BitVec.create(allocator, size) catch null;
}

pub export fn probe_bitvec_destroy(handle: ?*anyopaque) callconv(.c) void {
    const pointer = handle orelse return;
    fromOpaque(pointer).destroy(allocator);
}

pub export fn probe_bitvec_set(handle: *anyopaque, index: u32) callconv(.c) c_int {
    fromOpaque(handle).set(allocator, index) catch return 7;
    return 0;
}

pub export fn probe_bitvec_clear(handle: *anyopaque, index: u32) callconv(.c) void {
    fromOpaque(handle).clear(index);
}

pub export fn probe_bitvec_test(handle: ?*anyopaque, index: u32) callconv(.c) c_int {
    const pointer = handle orelse return 0;
    return @intFromBool(fromOpaque(pointer).isSet(index));
}

pub export fn probe_bitvec_size(handle: *anyopaque) callconv(.c) u32 {
    return fromOpaque(handle).capacity();
}

pub export fn probe_bitvec_representation(handle: *anyopaque) callconv(.c) c_int {
    return @intFromEnum(fromOpaque(handle).representation());
}
