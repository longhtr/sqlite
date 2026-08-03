//! Source-shaped B-tree interface constants and payload representation.

const std = @import("std");
const Mem = @import("vdbe_mem.zig").Mem;
const layout = @import("../generated/internal_vdbe_layout.zig");

pub const Btree = opaque {};
pub const BtCursor = opaque {};
pub const BtShared = opaque {};

pub const SQLITE_BTREE_H = true;
pub const SQLITE_N_BTREE_META: c_int = 16;
pub const SQLITE_DEFAULT_AUTOVACUUM: c_int = 0;

pub const BTREE_AUTOVACUUM_NONE: c_int = 0;
pub const BTREE_AUTOVACUUM_FULL: c_int = 1;
pub const BTREE_AUTOVACUUM_INCR: c_int = 2;
pub const BTREE_OMIT_JOURNAL: c_int = 1;
pub const BTREE_MEMORY: c_int = 2;
pub const BTREE_SINGLE: c_int = 4;
pub const BTREE_UNORDERED: c_int = 8;
pub const BTREE_INTKEY: c_int = 1;
pub const BTREE_BLOBKEY: c_int = 2;
pub const BTREE_FREE_PAGE_COUNT: c_int = 0;
pub const BTREE_SCHEMA_VERSION: c_int = 1;
pub const BTREE_FILE_FORMAT: c_int = 2;
pub const BTREE_DEFAULT_CACHE_SIZE: c_int = 3;
pub const BTREE_LARGEST_ROOT_PAGE: c_int = 4;
pub const BTREE_TEXT_ENCODING: c_int = 5;
pub const BTREE_USER_VERSION: c_int = 6;
pub const BTREE_INCR_VACUUM: c_int = 7;
pub const BTREE_APPLICATION_ID: c_int = 8;
pub const BTREE_DATA_VERSION: c_int = 15;
pub const BTREE_HINT_RANGE: c_int = 0;
pub const BTREE_BULKLOAD: c_int = 0x0000_0001;
pub const BTREE_SEEK_EQ: c_int = 0x0000_0002;
pub const BTREE_WRCSR: c_int = 0x0000_0004;
pub const BTREE_FORDELETE: c_int = 0x0000_0008;
pub const BTREE_SAVEPOSITION: c_int = 0x02;
pub const BTREE_AUXDELETE: c_int = 0x04;
pub const BTREE_APPEND: c_int = 0x08;
pub const BTREE_PREFORMAT: c_int = 0x80;

pub const BtreePayload = extern struct {
    pKey: ?*const anyopaque,
    nKey: i64,
    pData: ?*const anyopaque,
    aMem: ?[*]Mem,
    nMem: u16,
    nData: c_int,
    nZero: c_int,
};

/// Active non-debug expansion of `sqlite3BtreeSeekCount(X)`.
pub fn seekCount(_: ?*Btree) u64 {
    return 0;
}

comptime {
    if (@sizeOf(BtreePayload) != layout.BtreePayload.size or
        @alignOf(BtreePayload) != layout.BtreePayload.alignment)
        @compileError("BtreePayload layout differs from pinned C profile");
    for (std.meta.fields(BtreePayload)) |field| {
        if (@offsetOf(BtreePayload, field.name) != @field(layout.BtreePayload, field.name ++ "_offset"))
            @compileError("BtreePayload field offset differs from pinned C profile");
        if (@sizeOf(field.type) != @field(layout.BtreePayload, field.name ++ "_size"))
            @compileError("BtreePayload field size differs from pinned C profile");
    }
}

test "active B-tree interface constants and payload" {
    try std.testing.expectEqual(@as(c_int, 16), SQLITE_N_BTREE_META);
    try std.testing.expectEqual(@as(c_int, 15), BTREE_DATA_VERSION);
    try std.testing.expectEqual(@as(c_int, 0x80), BTREE_PREFORMAT);
    try std.testing.expectEqual(@as(u64, 0), seekCount(null));
}
