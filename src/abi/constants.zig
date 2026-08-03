const profile = @import("build_profile");

pub const version = profile.sqlite_version;
pub const version_number: c_int = profile.sqlite_version_number;
pub const source_id = profile.sqlite_source_id;
pub const threadsafe: c_int = profile.threadsafe;
