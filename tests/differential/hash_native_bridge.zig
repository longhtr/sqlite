const std = @import("std");
const native_hash = @import("hash");
const Hash = native_hash.Hash;
const HashElem = native_hash.HashElem;

const allocator = std.heap.c_allocator;

fn hashFromOpaque(handle: *anyopaque) *Hash {
    return @ptrCast(@alignCast(handle));
}

fn hashFromConstOpaque(handle: *const anyopaque) *const Hash {
    return @ptrCast(@alignCast(handle));
}

fn elementFromOpaque(handle: *const anyopaque) *const HashElem {
    return @ptrCast(@alignCast(handle));
}

fn dataFromInteger(value: usize) ?*anyopaque {
    return if (value == 0) null else @ptrFromInt(value);
}

fn integerFromData(data: ?*anyopaque) usize {
    return if (data) |pointer| @intFromPtr(pointer) else 0;
}

pub export fn probe_initialize() callconv(.c) c_int {
    return 0;
}

pub export fn probe_shutdown() callconv(.c) void {}

pub export fn probe_hash_create() callconv(.c) ?*anyopaque {
    const result = allocator.create(Hash) catch return null;
    result.* = Hash.init();
    return result;
}

pub export fn probe_hash_destroy(handle: ?*anyopaque) callconv(.c) void {
    const pointer = handle orelse return;
    const hash = hashFromOpaque(pointer);
    hash.clear(allocator);
    allocator.destroy(hash);
}

pub export fn probe_hash_insert(
    handle: *anyopaque,
    key: [*:0]const u8,
    value: usize,
) callconv(.c) usize {
    return integerFromData(hashFromOpaque(handle).insert(
        allocator,
        key,
        dataFromInteger(value),
    ));
}

pub export fn probe_hash_delete(
    handle: *anyopaque,
    key: [*:0]const u8,
) callconv(.c) usize {
    return integerFromData(hashFromOpaque(handle).insert(allocator, key, null));
}

pub export fn probe_hash_find(
    handle: *const anyopaque,
    key: [*:0]const u8,
) callconv(.c) usize {
    return integerFromData(hashFromConstOpaque(handle).find(key));
}

pub export fn probe_hash_count(handle: *const anyopaque) callconv(.c) u32 {
    return hashFromConstOpaque(handle).count();
}

pub export fn probe_hash_bucket_count(handle: *const anyopaque) callconv(.c) u32 {
    return hashFromConstOpaque(handle).bucket_count;
}

pub export fn probe_hash_first(handle: *const anyopaque) callconv(.c) ?*const anyopaque {
    return hashFromConstOpaque(handle).first();
}

pub export fn probe_hash_next(handle: *const anyopaque) callconv(.c) ?*const anyopaque {
    return elementFromOpaque(handle).next;
}

pub export fn probe_hash_element_key(handle: *const anyopaque) callconv(.c) [*:0]const u8 {
    return elementFromOpaque(handle).key;
}

pub export fn probe_hash_element_data(handle: *const anyopaque) callconv(.c) usize {
    return integerFromData(elementFromOpaque(handle).data);
}

pub export fn probe_hash_element_hash(handle: *const anyopaque) callconv(.c) u32 {
    return elementFromOpaque(handle).hash_value;
}
