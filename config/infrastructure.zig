//! Phase 2 memory/mutex choices fixed by the core profile.

pub const threadsafe: u8 = 1;
pub const default_core_mutex = true;
pub const default_connection_mutex = true;
pub const default_memory_statistics = true;
pub const default_lookaside_slot_size: u16 = 1_200;
pub const default_lookaside_slot_count: u16 = 40;
pub const two_size_lookaside = true;
pub const dedicated_scratch_allocator = false;
pub const memory_management_release = false;
pub const system_allocator = true;
