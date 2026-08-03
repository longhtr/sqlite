//! Transitional C-shaped metadata exports.
//!
//! The metadata values are fidelity-evidenced, but C ABI exposure is not part
//! of the target Zig-native product surface.

const constants = @import("constants.zig");

/// Upstream: src/main.c :: sqlite3_version (line 92)
/// Baseline: bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc
/// Port phase: fidelity
pub export const sqlite3_version: [constants.version.len:0]u8 = constants.version.*;
const sqlite3_source_id: [constants.source_id.len:0]u8 = constants.source_id.*;

/// Upstream: src/main.c :: sqlite3_libversion (line 98)
/// Obligation: return the stable address of sqlite3_version.
pub export fn sqlite3_libversion() callconv(.c) [*:0]const u8 {
    return &sqlite3_version;
}

/// Upstream: src/main.c :: sqlite3_sourceid (line 106)
/// Obligation: return the pinned source ID as a stable NUL-terminated string.
pub export fn sqlite3_sourceid() callconv(.c) [*:0]const u8 {
    return &sqlite3_source_id;
}

/// Upstream: src/main.c :: sqlite3_libversion_number (line 111)
pub export fn sqlite3_libversion_number() callconv(.c) c_int {
    return constants.version_number;
}

/// Upstream: src/main.c :: sqlite3_threadsafe (line 117)
/// Obligation: report the compile-time SQLITE_THREADSAFE value, not runtime mode.
pub export fn sqlite3_threadsafe() callconv(.c) c_int {
    return constants.threadsafe;
}
