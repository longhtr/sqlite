const random = @import("sqlite_random");

var state = random.State{};
var saved = random.State{};
var entropy: [44]u8 = undefined;

pub export fn probe_random_initialize(seed: *const [44]u8) callconv(.c) c_int {
    entropy = seed.*;
    state = .{};
    saved = .{};
    return 0;
}

pub export fn probe_random_shutdown() callconv(.c) void {}

pub export fn probe_random_bytes(count: c_int, output: [*]u8) callconv(.c) void {
    state.fill(output[0..@intCast(count)], &entropy);
}

pub export fn probe_random_reset() callconv(.c) void {
    state.reset();
}

pub export fn probe_random_save() callconv(.c) void {
    saved = state.save();
}

pub export fn probe_random_restore() callconv(.c) void {
    state.restore(&saved);
}
