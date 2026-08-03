//! Semantic feature choices for the initial core profile.
//! Exact C definitions remain in upstream/SQLITE_BUILD_PROFILE.json.

pub const loadable_extensions = true;
pub const json = true;
pub const math_functions = true;
pub const percentile = true;
pub const zlib = true;
pub const fts3 = false;
pub const fts4 = false;
pub const fts5 = false;
pub const rtree = false;
pub const geopoly = false;
pub const session = false;
pub const carray = false;
pub const dbpage = false;
pub const dbstat = false;
