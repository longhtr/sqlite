//! Pinned limits and defaults for the initial SQLite core profile.
//! Values are checked against the production-oracle preprocessor.

pub const minimum_database_page_size: u32 = 512;
pub const maximum_database_page_size: u32 = 65_536;
pub const max_length: u32 = 1_000_000_000;
pub const min_length: u32 = 30;
pub const max_allocation_size: u32 = 2_147_483_391;
pub const max_column: u32 = 2_000;
pub const max_sql_length: u32 = 1_000_000_000;
pub const max_expr_depth: u32 = 1_000;
pub const max_parser_depth: u32 = 2_500;
pub const max_compound_select: u32 = 500;
pub const max_vdbe_op: u32 = 250_000_000;
pub const max_function_arg: u32 = 1_000;
pub const default_cache_size: i32 = -2_000;
pub const default_wal_autocheckpoint: u32 = 1_000;
pub const max_attached: u32 = 10;
pub const max_variable_number: u32 = 32_766;
pub const max_page_size: u32 = 65_536;
pub const default_page_size: u32 = 4_096;
pub const max_default_page_size: u32 = 8_192;
pub const max_page_count: u32 = 0xffff_fffe;
pub const max_like_pattern_length: u32 = 50_000;
pub const max_trigger_depth: u32 = 1_000;
pub const default_memstatus: bool = true;
pub const default_synchronous: u8 = 2;
pub const default_wal_synchronous: u8 = 2;
pub const default_recursive_triggers: bool = false;
pub const max_worker_threads: u8 = 8;
pub const default_worker_threads: u8 = 0;
pub const default_pcache_initial_size: u8 = 20;
pub const default_mmap_size: u64 = 0;

test "cross-limit invariants" {
    const std = @import("std");
    try std.testing.expect(min_length == 30);
    try std.testing.expect(max_length <= @as(u32, std.math.maxInt(i32)));
    try std.testing.expect(max_allocation_size <= 2_147_483_391);
    try std.testing.expect(max_column <= 32_767);
    try std.testing.expect(max_attached <= 125);
    try std.testing.expect(max_page_size == 65_536);
    try std.testing.expect(default_page_size <= max_default_page_size);
    try std.testing.expect(max_default_page_size <= max_page_size);
    try std.testing.expect(default_worker_threads <= max_worker_threads);
    try std.testing.expect(max_sql_length <= max_length);
    try std.testing.expect(max_allocation_size < @as(u32, std.math.maxInt(i32)));
}
