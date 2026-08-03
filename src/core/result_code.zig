//! SQLite primary and extended result-code carrier.

pub const ResultCode = enum(c_int) {
    ok = 0,
    error_ = 1,
    internal = 2,
    perm = 3,
    abort = 4,
    busy = 5,
    locked = 6,
    no_memory = 7,
    read_only = 8,
    interrupt = 9,
    io_error = 10,
    corrupt = 11,
    not_found = 12,
    full = 13,
    cannot_open = 14,
    protocol = 15,
    empty = 16,
    schema = 17,
    too_big = 18,
    constraint = 19,
    mismatch = 20,
    misuse = 21,
    no_lfs = 22,
    auth = 23,
    format = 24,
    range = 25,
    not_a_database = 26,
    notice = 27,
    warning = 28,
    row = 100,
    done = 101,
    _,

    pub fn fromC(value: c_int) ResultCode {
        return @enumFromInt(value);
    }

    pub fn toC(self: ResultCode) c_int {
        return @intFromEnum(self);
    }

    pub fn primary(self: ResultCode) ResultCode {
        return @enumFromInt(self.toC() & 0xff);
    }
};
