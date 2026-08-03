//! SQLite's ChaCha20 PRNG core translated from `src/random.c`.
//!
//! VFS entropy acquisition, global mutex ownership, and auto-initialization are
//! intentionally outside this pure slice. The 44-byte entropy input is
//! explicit and injectable; output buffering order matches `sqlite3_randomness`.

const std = @import("std");

const initial_words = [4]u32{ 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 };

fn rotateLeft(value: u32, amount: u5) u32 {
    return (value << amount) | (value >> @intCast(32 - @as(u6, amount)));
}

fn quarterRound(a: *u32, b: *u32, c: *u32, d: *u32) void {
    a.* +%= b.*;
    d.* ^= a.*;
    d.* = rotateLeft(d.*, 16);
    c.* +%= d.*;
    b.* ^= c.*;
    b.* = rotateLeft(b.*, 12);
    a.* +%= b.*;
    d.* ^= a.*;
    d.* = rotateLeft(d.*, 8);
    c.* +%= d.*;
    b.* ^= c.*;
    b.* = rotateLeft(b.*, 7);
}

/// Upstream: chacha_block (line 39).
fn chachaBlock(output: *[64]u8, input: *const [16]u32) void {
    var working = input.*;
    for (0..10) |_| {
        quarterRound(&working[0], &working[4], &working[8], &working[12]);
        quarterRound(&working[1], &working[5], &working[9], &working[13]);
        quarterRound(&working[2], &working[6], &working[10], &working[14]);
        quarterRound(&working[3], &working[7], &working[11], &working[15]);
        quarterRound(&working[0], &working[5], &working[10], &working[15]);
        quarterRound(&working[1], &working[6], &working[11], &working[12]);
        quarterRound(&working[2], &working[7], &working[8], &working[13]);
        quarterRound(&working[3], &working[4], &working[9], &working[14]);
    }
    for (0..16) |index| {
        std.mem.writeInt(u32, output[index * 4 ..][0..4], working[index] +% input[index], .little);
    }
}

/// Upstream: sqlite3PrngType (line 24).
pub const State = extern struct {
    words: [16]u32 = [_]u32{0} ** 16,
    output: [64]u8 = [_]u8{0} ** 64,
    remaining: u8 = 0,

    pub fn isInitialized(self: *const State) bool {
        return self.words[0] != 0;
    }

    /// Initialize with the 44 bytes normally supplied by the selected VFS.
    pub fn initialize(self: *State, entropy: *const [44]u8) void {
        self.words[0..4].* = initial_words;
        for (0..11) |index| {
            self.words[index + 4] = std.mem.readInt(u32, entropy[index * 4 ..][0..4], .little);
        }
        self.words[15] = self.words[12];
        self.words[12] = 0;
        self.remaining = 0;
    }

    /// Upstream: sqlite3_randomness (line 59), after entropy injection and
    /// mutex acquisition. `entropy` is consulted only when state is reset.
    pub fn fill(self: *State, destination: []u8, entropy: *const [44]u8) void {
        if (destination.len == 0) {
            self.reset();
            return;
        }
        if (!self.isInitialized()) self.initialize(entropy);

        var unwritten = destination;
        while (true) {
            if (unwritten.len <= self.remaining) {
                const start = @as(usize, self.remaining) - unwritten.len;
                @memcpy(unwritten, self.output[start..][0..unwritten.len]);
                self.remaining -= @intCast(unwritten.len);
                break;
            }
            if (self.remaining > 0) {
                const count: usize = self.remaining;
                @memcpy(unwritten[0..count], self.output[0..count]);
                unwritten = unwritten[count..];
            }
            self.words[12] +%= 1;
            chachaBlock(&self.output, &self.words);
            self.remaining = 64;
        }
    }

    /// `sqlite3_randomness(0, 0)` reset semantics.
    pub fn reset(self: *State) void {
        self.words[0] = 0;
    }

    /// Upstream test-control save/restore is a byte-for-byte state copy.
    pub fn save(self: *const State) State {
        return self.*;
    }

    pub fn restore(self: *State, saved: *const State) void {
        self.* = saved.*;
    }
};

pub var process_state = State{};
pub var saved_state = State{};

pub fn saveProcessState() void {
    saved_state = process_state.save();
}

pub fn restoreProcessState() void {
    process_state.restore(&saved_state);
}

test "RFC 8439 ChaCha block core" {
    const input = [16]u32{
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        0x03020100, 0x07060504, 0x0b0a0908, 0x0f0e0d0c,
        0x13121110, 0x17161514, 0x1b1a1918, 0x1f1e1d1c,
        1,          0x09000000, 0x4a000000, 0,
    };
    var output: [64]u8 = undefined;
    chachaBlock(&output, &input);
    const expected = "10f1e7e4d13b5915500fdd1fa32071c4" ++
        "c7d1f4c733c068030422aa9ac3d46c4e" ++
        "d2826446079faa0914c2d705d98b02a2" ++
        "b5129cd1de164eb9cbd083e8a2503c4e";
    var expected_bytes: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_bytes, expected);
    try std.testing.expectEqual(expected_bytes, output);
}

test "buffer consumption reset and state restoration" {
    var entropy: [44]u8 = undefined;
    for (&entropy, 0..) |*byte, index| byte.* = @intCast(index);
    var state = State{};
    var first: [17]u8 = undefined;
    state.fill(&first, &entropy);
    const saved = state.save();
    var second: [100]u8 = undefined;
    state.fill(&second, &entropy);
    state.restore(&saved);
    var repeated: [100]u8 = undefined;
    state.fill(&repeated, &entropy);
    try std.testing.expectEqual(second, repeated);

    state.fill(&.{}, &entropy);
    try std.testing.expect(!state.isInitialized());
    var reset_first: [17]u8 = undefined;
    state.fill(&reset_first, &entropy);
    try std.testing.expectEqual(first, reset_first);
}

test "chunk boundaries preserve SQLite output order" {
    const entropy = [_]u8{0xa5} ** 44;
    var one = State{};
    var split = State{};
    var whole: [160]u8 = undefined;
    one.fill(&whole, &entropy);

    var chunks: [160]u8 = undefined;
    split.fill(chunks[0..13], &entropy);
    split.fill(chunks[13..64], &entropy);
    split.fill(chunks[64..65], &entropy);
    split.fill(chunks[65..], &entropy);
    // Request boundaries affect SQLite's reverse consumption of each block,
    // so only identical request sequences are stream-equivalent.
    try std.testing.expect(!std.mem.eql(u8, &whole, &chunks));

    split.reset();
    var chunks_again: [160]u8 = undefined;
    split.fill(chunks_again[0..13], &entropy);
    split.fill(chunks_again[13..64], &entropy);
    split.fill(chunks_again[64..65], &entropy);
    split.fill(chunks_again[65..], &entropy);
    try std.testing.expectEqual(chunks, chunks_again);
}
