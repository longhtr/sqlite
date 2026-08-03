//! Process-global public directory pointers cleared after allocator shutdown.

pub export var sqlite3_temp_directory: ?[*:0]u8 = null;
pub export var sqlite3_data_directory: ?[*:0]u8 = null;

pub fn clearShutdownDirectories() void {
    sqlite3_temp_directory = null;
    sqlite3_data_directory = null;
}
