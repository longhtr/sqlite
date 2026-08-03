const std = @import("std");

pub const Profile = enum {
    development_aarch64_linux_btrfs,
    release_x86_64_linux_ext4,
};

pub fn isInitialArchitecture(arch: std.Target.Cpu.Arch) bool {
    return arch == .aarch64 or arch == .x86_64;
}
