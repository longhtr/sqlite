//! Source-corresponding small Btree accessors from `btree.c`.

pub const types = @import("vdbe_types.zig");

/// Source `sqlite3BtreeSharable()`.
pub fn sharable(tree: *const types.Btree) c_int {
    return tree.sharable;
}
