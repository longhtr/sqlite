const std = @import("std");

const sqlite_c_flags = &.{
    "-std=c99",
    "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
    "-DSQLITE_ENABLE_PERCENTILE=1",
    "-DSQLITE_HAVE_ZLIB=1",
    "-DSQLITE_THREADSAFE=1",
};

fn nativeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const profile = b.createModule(.{
        .root_source_file = b.path("config/build_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_profile", .module = profile }},
    });
    if (target.result.os.tag == .linux) module.linkSystemLibrary("dl", .{});
    return module;
}

fn oracleModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("include"));
    module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/sqlite3.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        module.linkSystemLibrary("dl", .{});
    }
    return module;
}

fn boundedSystemCommandProfile(
    b: *std.Build,
    profile: []const u8,
    argv: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "python3", "tools/run_bounded.py", "--profile", profile, "--",
    });
    run.addArgs(argv);
    return run;
}

fn boundedSystemCommand(
    b: *std.Build,
    argv: []const []const u8,
) *std.Build.Step.Run {
    return boundedSystemCommandProfile(b, "tool", argv);
}

fn boundedRunArtifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "python3", "tools/run_bounded.py", "--profile", "worker", "--",
    });
    run.addArtifactArg(artifact);
    return run;
}

const ActivePortBatchStatus = enum { idle, active };

const ActivePortBatch = struct {
    schema_version: usize,
    status: ActivePortBatchStatus,
    completion_claim: bool,
    entries: []const std.json.Value,
};

fn enforcePortBatchManifest(b: *std.Build) void {
    const manifest_bytes = b.build_root.handle.readFileAlloc(b.graph.io, "upstream/active-port-batch.json", b.allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.panic("cannot read active port batch: {s}", .{@errorName(err)});
    };
    defer b.allocator.free(manifest_bytes);
    const parsed = std.json.parseFromSlice(ActivePortBatch, b.allocator, manifest_bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.panic("cannot parse active port batch: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != 2) {
        std.debug.panic("unsupported active port batch schema: {d}", .{parsed.value.schema_version});
    }
    if (parsed.value.completion_claim) {
        std.debug.panic("active port batch must not claim project completion", .{});
    }
    switch (parsed.value.status) {
        .idle => if (parsed.value.entries.len != 0) {
            std.debug.panic("idle active port batch contains entries", .{});
        },
        .active => if (parsed.value.entries.len == 0) {
            std.debug.panic("active port batch contains no entries", .{});
        },
    }
}

fn addRunStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = boundedRunArtifact(b, artifact);
    b.step(name, description).dependOn(&run.step);
    return run;
}

pub fn build(b: *std.Build) void {
    enforcePortBatchManifest(b);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const direct_build_profile = b.createModule(.{
        .root_source_file = b.path("config/build_profile.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("sqlite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{
            .name = "build_profile",
            .module = direct_build_profile,
        }},
    });

    const native_static = b.addLibrary(.{
        .name = "sqlite_zig",
        .linkage = .static,
        .root_module = nativeModule(b, target, optimize),
    });
    const native_shared = b.addLibrary(.{
        .name = "sqlite_zig",
        .linkage = .dynamic,
        .root_module = nativeModule(b, target, optimize),
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
    });
    b.installArtifact(native_static);
    b.installArtifact(native_shared);

    const native_tests = b.addTest(.{
        .root_module = nativeModule(b, target, optimize),
    });
    const run_native_tests = boundedRunArtifact(b, native_tests);

    const abi_client_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_client_module.addIncludePath(b.path("include"));
    abi_client_module.addCSourceFile(.{
        .file = b.path("tests/api/version_client.c"),
        .flags = &.{"-std=c99"},
    });
    abi_client_module.linkLibrary(native_static);
    const abi_client = b.addExecutable(.{
        .name = "transitional-c-metadata-test",
        .root_module = abi_client_module,
    });
    const run_abi_client = addRunStep(
        b,
        "abi-test",
        "Run the historical C-header metadata test",
        abi_client,
    );

    const oracle_static = b.addLibrary(.{
        .name = "sqlite3_oracle",
        .linkage = .static,
        .root_module = oracleModule(b, target, optimize),
    });
    const oracle_shared = b.addLibrary(.{
        .name = "sqlite3_oracle",
        .linkage = .dynamic,
        .root_module = oracleModule(b, target, optimize),
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
    });
    const oracle_step = b.step("oracle", "Build and install the pinned C oracle");
    oracle_step.dependOn(&b.addInstallArtifact(oracle_static, .{}).step);
    oracle_step.dependOn(&b.addInstallArtifact(oracle_shared, .{}).step);

    const native_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_worker_module.addIncludePath(b.path("include"));
    native_worker_module.addCSourceFile(.{
        .file = b.path("reference/protocol/metadata_worker.c"),
        .flags = &.{ "-std=c99", "-DENGINE_NAME=\"native\"" },
    });
    native_worker_module.linkLibrary(native_static);
    const native_worker = b.addExecutable(.{
        .name = "sqlite3-native-worker",
        .root_module = native_worker_module,
    });

    const oracle_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_worker_module.addIncludePath(b.path("include"));
    oracle_worker_module.addCSourceFile(.{
        .file = b.path("reference/protocol/metadata_worker.c"),
        .flags = &.{ "-std=c99", "-DENGINE_NAME=\"oracle\"" },
    });
    oracle_worker_module.linkLibrary(oracle_static);
    const oracle_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-worker",
        .root_module = oracle_worker_module,
    });

    const differential_probe = boundedSystemCommand(b, &.{ "python3", "tools/differential_probe.py" });
    differential_probe.addArtifactArg(oracle_worker);
    differential_probe.addArtifactArg(native_worker);
    b.step("differential", "Run the isolated-worker metadata differential probe")
        .dependOn(&differential_probe.step);

    const bitvec_module = b.createModule(.{
        .root_source_file = b.path("src/core/bitvec.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_bitvec_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/bitvec_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "bitvec", .module = bitvec_module }},
    });
    const native_bitvec_bridge = b.addObject(.{
        .name = "sqlite3-native-bitvec-bridge",
        .root_module = native_bitvec_bridge_module,
    });
    const native_bitvec_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_bitvec_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/bitvec_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_bitvec_worker_module.addObject(native_bitvec_bridge);
    const native_bitvec_worker = b.addExecutable(.{
        .name = "sqlite3-native-bitvec-worker",
        .root_module = native_bitvec_worker_module,
    });

    const oracle_bitvec_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_bitvec_worker_module.addIncludePath(b.path("include"));
    oracle_bitvec_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_bitvec_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/bitvec_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_bitvec_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_bitvec_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_bitvec_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-bitvec-worker",
        .root_module = oracle_bitvec_worker_module,
    });

    const bitvec_differential = boundedSystemCommand(b, &.{ "python3", "tools/bitvec_differential.py" });
    bitvec_differential.addArtifactArg(oracle_bitvec_worker);
    bitvec_differential.addArtifactArg(native_bitvec_worker);
    b.step("bitvec-differential", "Compare native and oracle BitVec operation traces")
        .dependOn(&bitvec_differential.step);

    const native_bitvec_builtin_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/bitvec_builtin_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "bitvec", .module = bitvec_module }},
    });
    const native_bitvec_builtin = b.addExecutable(.{ .name = "sqlite3-native-bitvec-builtin", .root_module = native_bitvec_builtin_module });
    const oracle_bitvec_builtin_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_bitvec_builtin_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_bitvec_builtin_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/bitvec_builtin_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_bitvec_builtin_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_bitvec_builtin_module.linkSystemLibrary("dl", .{});
    const oracle_bitvec_builtin = b.addExecutable(.{ .name = "sqlite3-oracle-bitvec-builtin", .root_module = oracle_bitvec_builtin_module });
    const bitvec_builtin_differential = boundedSystemCommand(b, &.{ "python3", "tools/bitvec_builtin_differential.py" });
    bitvec_builtin_differential.addArtifactArg(oracle_bitvec_builtin);
    bitvec_builtin_differential.addArtifactArg(native_bitvec_builtin);
    b.step("bitvec-builtin-differential", "Compare SQLite mutable Bitvec built-in test interpreter")
        .dependOn(&bitvec_builtin_differential.step);

    const hash_module = b.createModule(.{
        .root_source_file = b.path("src/core/hash.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_hash_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/hash_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "hash", .module = hash_module }},
    });
    const native_hash_bridge = b.addObject(.{
        .name = "sqlite3-native-hash-bridge",
        .root_module = native_hash_bridge_module,
    });
    const native_hash_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_hash_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/hash_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_hash_worker_module.addObject(native_hash_bridge);
    const native_hash_worker = b.addExecutable(.{
        .name = "sqlite3-native-hash-worker",
        .root_module = native_hash_worker_module,
    });

    const oracle_hash_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_hash_worker_module.addIncludePath(b.path("include"));
    oracle_hash_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_hash_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/hash_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_hash_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_hash_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_hash_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-hash-worker",
        .root_module = oracle_hash_worker_module,
    });

    const hash_differential = boundedSystemCommand(b, &.{ "python3", "tools/hash_differential.py" });
    hash_differential.addArtifactArg(oracle_hash_worker);
    hash_differential.addArtifactArg(native_hash_worker);
    b.step("hash-differential", "Compare native and oracle Hash operation traces")
        .dependOn(&hash_differential.step);

    const varint_module = b.createModule(.{
        .root_source_file = b.path("src/core/varint.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_varint_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/varint_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "varint", .module = varint_module }},
    });
    const native_varint_bridge = b.addObject(.{
        .name = "sqlite3-native-varint-bridge",
        .root_module = native_varint_bridge_module,
    });
    const native_varint_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_varint_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/varint_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_varint_worker_module.addObject(native_varint_bridge);
    const native_varint_worker = b.addExecutable(.{
        .name = "sqlite3-native-varint-worker",
        .root_module = native_varint_worker_module,
    });

    const oracle_varint_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_varint_worker_module.addIncludePath(b.path("include"));
    oracle_varint_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_varint_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/varint_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_varint_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_varint_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_varint_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-varint-worker",
        .root_module = oracle_varint_worker_module,
    });

    const varint_differential = boundedSystemCommand(b, &.{ "python3", "tools/varint_differential.py" });
    varint_differential.addArtifactArg(oracle_varint_worker);
    varint_differential.addArtifactArg(native_varint_worker);
    b.step("varint-differential", "Compare native and oracle varint traces")
        .dependOn(&varint_differential.step);

    const byteorder_module = b.createModule(.{
        .root_source_file = b.path("src/core/byteorder.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_byteorder_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/byteorder_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "byteorder", .module = byteorder_module }},
    });
    const native_byteorder_bridge = b.addObject(.{
        .name = "sqlite3-native-byteorder-bridge",
        .root_module = native_byteorder_bridge_module,
    });
    const native_byteorder_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_byteorder_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/byteorder_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_byteorder_worker_module.addObject(native_byteorder_bridge);
    const native_byteorder_worker = b.addExecutable(.{
        .name = "sqlite3-native-byteorder-worker",
        .root_module = native_byteorder_worker_module,
    });

    const oracle_byteorder_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_byteorder_worker_module.addIncludePath(b.path("include"));
    oracle_byteorder_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_byteorder_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/byteorder_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_byteorder_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_byteorder_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_byteorder_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-byteorder-worker",
        .root_module = oracle_byteorder_worker_module,
    });

    const byteorder_differential = boundedSystemCommand(b, &.{ "python3", "tools/byteorder_differential.py" });
    byteorder_differential.addArtifactArg(oracle_byteorder_worker);
    byteorder_differential.addArtifactArg(native_byteorder_worker);
    b.step("byteorder-differential", "Compare native and oracle big-endian helpers")
        .dependOn(&byteorder_differential.step);

    const string_module = b.createModule(.{
        .root_source_file = b.path("src/core/string.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_string_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/string_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlite_string", .module = string_module }},
    });
    const native_string_bridge = b.addObject(.{
        .name = "sqlite3-native-string-bridge",
        .root_module = native_string_bridge_module,
    });
    const native_string_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_string_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/string_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_string_worker_module.addObject(native_string_bridge);
    const native_string_worker = b.addExecutable(.{
        .name = "sqlite3-native-string-worker",
        .root_module = native_string_worker_module,
    });

    const oracle_string_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_string_worker_module.addIncludePath(b.path("include"));
    oracle_string_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_string_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/string_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_string_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_string_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_string_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-string-worker",
        .root_module = oracle_string_worker_module,
    });

    const string_differential = boundedSystemCommand(b, &.{ "python3", "tools/string_differential.py" });
    string_differential.addArtifactArg(oracle_string_worker);
    string_differential.addArtifactArg(native_string_worker);
    b.step("string-differential", "Compare native and oracle string primitives")
        .dependOn(&string_differential.step);

    const native_dequote_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/dequote_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "sqlite_string", .module = string_module }},
    });
    const native_dequote = b.addExecutable(.{ .name = "sqlite3-native-dequote", .root_module = native_dequote_module });
    const oracle_dequote_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_dequote_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_dequote_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/dequote_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_dequote_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_dequote_module.linkSystemLibrary("dl", .{});
    const oracle_dequote = b.addExecutable(.{ .name = "sqlite3-oracle-dequote", .root_module = oracle_dequote_module });
    const dequote_differential = boundedSystemCommand(b, &.{ "python3", "tools/dequote_differential.py" });
    dequote_differential.addArtifactArg(oracle_dequote);
    dequote_differential.addArtifactArg(native_dequote);
    b.step("dequote-differential", "Compare SQLite string and Token dequoting")
        .dependOn(&dequote_differential.step);

    const utf_module = b.createModule(.{
        .root_source_file = b.path("src/core/utf.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_utf_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/utf_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utf", .module = utf_module }},
    });
    const native_utf_bridge = b.addObject(.{
        .name = "sqlite3-native-utf-bridge",
        .root_module = native_utf_bridge_module,
    });
    const native_utf_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_utf_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/utf_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_utf_worker_module.addObject(native_utf_bridge);
    const native_utf_worker = b.addExecutable(.{
        .name = "sqlite3-native-utf-worker",
        .root_module = native_utf_worker_module,
    });

    const oracle_utf_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_utf_worker_module.addIncludePath(b.path("include"));
    oracle_utf_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_utf_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/utf_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_utf_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_utf_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_utf_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-utf-worker",
        .root_module = oracle_utf_worker_module,
    });

    const utf_differential = boundedSystemCommand(b, &.{ "python3", "tools/utf_differential.py" });
    utf_differential.addArtifactArg(oracle_utf_worker);
    utf_differential.addArtifactArg(native_utf_worker);
    b.step("utf-differential", "Compare native and oracle pure UTF primitives")
        .dependOn(&utf_differential.step);

    const random_module = b.createModule(.{
        .root_source_file = b.path("src/core/random.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_random_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/random_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlite_random", .module = random_module }},
    });
    const native_random_bridge = b.addObject(.{
        .name = "sqlite3-native-random-bridge",
        .root_module = native_random_bridge_module,
    });
    const native_random_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_random_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/random_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_random_worker_module.addObject(native_random_bridge);
    const native_random_worker = b.addExecutable(.{
        .name = "sqlite3-native-random-worker",
        .root_module = native_random_worker_module,
    });

    const oracle_random_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_random_worker_module.addIncludePath(b.path("include"));
    oracle_random_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_random_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/random_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) {
        oracle_random_worker_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .linux) {
        oracle_random_worker_module.linkSystemLibrary("dl", .{});
    }
    const oracle_random_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-random-worker",
        .root_module = oracle_random_worker_module,
    });

    const random_differential = boundedSystemCommand(b, &.{ "python3", "tools/random_differential.py" });
    random_differential.addArtifactArg(oracle_random_worker);
    random_differential.addArtifactArg(native_random_worker);
    b.step("random-differential", "Compare injected native and oracle PRNG traces")
        .dependOn(&random_differential.step);

    const random_process_module = b.createModule(.{
        .root_source_file = b.path("src/core/random_process_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    random_process_module.addImport("build_profile", direct_build_profile);
    const native_random_process_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/random_process_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "random_process", .module = random_process_module }},
    });
    const native_random_process = b.addExecutable(.{
        .name = "sqlite3-native-random-process",
        .root_module = native_random_process_module,
    });
    const oracle_random_process_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_random_process_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_random_process_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/random_process_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_random_process_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_random_process_module.linkSystemLibrary("dl", .{});
    const oracle_random_process = b.addExecutable(.{
        .name = "sqlite3-oracle-random-process",
        .root_module = oracle_random_process_module,
    });
    const random_process_differential = boundedSystemCommand(b, &.{ "python3", "tools/random_process_differential.py" });
    random_process_differential.addArtifactArg(oracle_random_process);
    random_process_differential.addArtifactArg(native_random_process);
    b.step("random-process-differential", "Compare SQLite process PRNG lifecycle and buffering")
        .dependOn(&random_process_differential.step);

    const numeric_module = b.createModule(.{ .root_source_file = b.path("src/core/numeric.zig"), .target = target, .optimize = optimize });
    const float_module = b.createModule(.{ .root_source_file = b.path("src/core/float.zig"), .target = target, .optimize = optimize });
    const native_numeric_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/numeric_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "numeric", .module = numeric_module },
            .{ .name = "sqlite_float", .module = float_module },
        },
    });
    const native_numeric_bridge = b.addObject(.{ .name = "sqlite3-native-numeric-bridge", .root_module = native_numeric_bridge_module });
    const native_numeric_worker_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    native_numeric_worker_module.addCSourceFile(.{ .file = b.path("tests/differential/numeric_worker_main.c"), .flags = &.{"-std=c99"} });
    native_numeric_worker_module.addObject(native_numeric_bridge);
    const native_numeric_worker = b.addExecutable(.{ .name = "sqlite3-native-numeric-worker", .root_module = native_numeric_worker_module });
    const oracle_numeric_worker_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_numeric_worker_module.addIncludePath(b.path("include"));
    oracle_numeric_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_numeric_worker_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/numeric_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_numeric_worker_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_numeric_worker_module.linkSystemLibrary("dl", .{});
    const oracle_numeric_worker = b.addExecutable(.{ .name = "sqlite3-oracle-numeric-worker", .root_module = oracle_numeric_worker_module });
    const numeric_differential = boundedSystemCommand(b, &.{ "python3", "tools/numeric_differential.py" });
    numeric_differential.addArtifactArg(oracle_numeric_worker);
    numeric_differential.addArtifactArg(native_numeric_worker);
    b.step("numeric-differential", "Compare native and oracle numeric parsing traces").dependOn(&numeric_differential.step);

    const native_hex_blob_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/hex_blob_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "numeric", .module = numeric_module }},
    });
    const native_hex_blob = b.addExecutable(.{ .name = "sqlite3-native-hex-blob", .root_module = native_hex_blob_module });
    const oracle_hex_blob_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_hex_blob_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_hex_blob_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/hex_blob_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_hex_blob_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_hex_blob_module.linkSystemLibrary("dl", .{});
    const oracle_hex_blob = b.addExecutable(.{ .name = "sqlite3-oracle-hex-blob", .root_module = oracle_hex_blob_module });
    const hex_blob_differential = boundedSystemCommand(b, &.{ "python3", "tools/hex_blob_differential.py" });
    hex_blob_differential.addArtifactArg(oracle_hex_blob);
    hex_blob_differential.addArtifactArg(native_hex_blob);
    b.step("hex-blob-differential", "Compare SQLite hex-literal allocation and decoding")
        .dependOn(&hex_blob_differential.step);

    const log_est_module = b.createModule(.{ .root_source_file = b.path("src/core/log_est.zig"), .target = target, .optimize = optimize });
    const native_log_est_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/log_est_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "log_est", .module = log_est_module }},
    });
    const native_log_est = b.addExecutable(.{ .name = "sqlite3-native-log-est", .root_module = native_log_est_module });
    const oracle_log_est_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_log_est_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_log_est_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/log_est_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_log_est_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_log_est_module.linkSystemLibrary("dl", .{});
    const oracle_log_est = b.addExecutable(.{ .name = "sqlite3-oracle-log-est", .root_module = oracle_log_est_module });
    const log_est_differential = boundedSystemCommand(b, &.{ "python3", "tools/log_est_differential.py" });
    log_est_differential.addArtifactArg(oracle_log_est);
    log_est_differential.addArtifactArg(native_log_est);
    const log_est_tests = b.addTest(.{ .root_module = log_est_module });
    const run_log_est_tests = boundedRunArtifact(b, log_est_tests);
    const log_est_step = b.step("log-est-differential", "Compare SQLite LogEst arithmetic");
    log_est_step.dependOn(&log_est_differential.step);
    log_est_step.dependOn(&run_log_est_tests.step);

    const checked_math_module = b.createModule(.{ .root_source_file = b.path("src/core/checked_math.zig"), .target = target, .optimize = optimize });
    const native_checked_math_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/checked_math_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "checked_math", .module = checked_math_module }},
    });
    const native_checked_math = b.addExecutable(.{ .name = "sqlite3-native-checked-math", .root_module = native_checked_math_module });
    const oracle_checked_math_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_checked_math_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_checked_math_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/checked_math_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_checked_math_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_checked_math_module.linkSystemLibrary("dl", .{});
    const oracle_checked_math = b.addExecutable(.{ .name = "sqlite3-oracle-checked-math", .root_module = oracle_checked_math_module });
    const checked_math_differential = boundedSystemCommand(b, &.{ "python3", "tools/checked_math_differential.py" });
    checked_math_differential.addArtifactArg(oracle_checked_math);
    checked_math_differential.addArtifactArg(native_checked_math);
    const checked_math_tests = b.addTest(.{ .root_module = checked_math_module });
    const run_checked_math_tests = boundedRunArtifact(b, checked_math_tests);
    const checked_math_step = b.step("checked-math-differential", "Compare SQLite checked arithmetic and floating classification");
    checked_math_step.dependOn(&checked_math_differential.step);
    checked_math_step.dependOn(&run_checked_math_tests.step);

    const vlist_module = b.createModule(.{ .root_source_file = b.path("src/core/vlist.zig"), .target = target, .optimize = optimize });
    const native_vlist_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/vlist_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vlist", .module = vlist_module }},
    });
    const native_vlist = b.addExecutable(.{ .name = "sqlite3-native-vlist", .root_module = native_vlist_module });
    const oracle_vlist_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_vlist_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_vlist_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/vlist_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_vlist_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_vlist_module.linkSystemLibrary("dl", .{});
    const oracle_vlist = b.addExecutable(.{ .name = "sqlite3-oracle-vlist", .root_module = oracle_vlist_module });
    const vlist_differential = boundedSystemCommand(b, &.{ "python3", "tools/vlist_differential.py" });
    vlist_differential.addArtifactArg(oracle_vlist);
    vlist_differential.addArtifactArg(native_vlist);
    const vlist_tests = b.addTest(.{ .root_module = vlist_module });
    const run_vlist_tests = boundedRunArtifact(b, vlist_tests);
    const vlist_step = b.step("vlist-differential", "Compare SQLite packed variable-name/number list");
    vlist_step.dependOn(&vlist_differential.step);
    vlist_step.dependOn(&run_vlist_tests.step);

    const rowset_module = b.createModule(.{ .root_source_file = b.path("src/core/rowset.zig"), .target = target, .optimize = optimize });
    const native_rowset_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/rowset_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "rowset", .module = rowset_module }},
    });
    const native_rowset = b.addExecutable(.{ .name = "sqlite3-native-rowset", .root_module = native_rowset_module });
    const oracle_rowset_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_rowset_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_rowset_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/rowset_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_rowset_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_rowset_module.linkSystemLibrary("dl", .{});
    const oracle_rowset = b.addExecutable(.{ .name = "sqlite3-oracle-rowset", .root_module = oracle_rowset_module });
    const rowset_differential = boundedSystemCommand(b, &.{ "python3", "tools/rowset_differential.py" });
    rowset_differential.addArtifactArg(oracle_rowset);
    rowset_differential.addArtifactArg(native_rowset);
    const rowset_tests = b.addTest(.{ .root_module = rowset_module });
    const run_rowset_tests = boundedRunArtifact(b, rowset_tests);
    const rowset_step = b.step("rowset-differential", "Compare SQLite RowSet sorting and batch semantics");
    rowset_step.dependOn(&rowset_differential.step);
    rowset_step.dependOn(&run_rowset_tests.step);

    const benign_fault_module = b.createModule(.{ .root_source_file = b.path("src/core/benign_fault.zig"), .target = target, .optimize = optimize });
    const native_benign_fault_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/benign_fault_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "benign_fault", .module = benign_fault_module }},
    });
    const native_benign_fault = b.addExecutable(.{ .name = "sqlite3-native-benign-fault", .root_module = native_benign_fault_module });
    const oracle_benign_fault_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_benign_fault_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_benign_fault_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/benign_fault_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_benign_fault_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_benign_fault_module.linkSystemLibrary("dl", .{});
    const oracle_benign_fault = b.addExecutable(.{ .name = "sqlite3-oracle-benign-fault", .root_module = oracle_benign_fault_module });
    const benign_fault_differential = boundedSystemCommand(b, &.{ "python3", "tools/benign_fault_differential.py" });
    benign_fault_differential.addArtifactArg(oracle_benign_fault);
    benign_fault_differential.addArtifactArg(native_benign_fault);
    const benign_fault_tests = b.addTest(.{ .root_module = benign_fault_module });
    const run_benign_fault_tests = boundedRunArtifact(b, benign_fault_tests);
    const benign_fault_step = b.step("benign-fault-differential", "Compare SQLite benign allocation-failure hooks");
    benign_fault_step.dependOn(&benign_fault_differential.step);
    benign_fault_step.dependOn(&run_benign_fault_tests.step);

    const native_float_decode_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/float_decode_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlite_float", .module = float_module }},
    });
    const native_float_decode = b.addExecutable(.{
        .name = "sqlite3-native-float-decode",
        .root_module = native_float_decode_module,
    });
    const oracle_float_decode_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_float_decode_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_float_decode_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/float_decode_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_float_decode_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_float_decode_module.linkSystemLibrary("dl", .{});
    const oracle_float_decode = b.addExecutable(.{
        .name = "sqlite3-oracle-float-decode",
        .root_module = oracle_float_decode_module,
    });
    const float_decode_differential = boundedSystemCommand(b, &.{ "python3", "tools/float_decode_differential.py" });
    float_decode_differential.addArtifactArg(oracle_float_decode);
    float_decode_differential.addArtifactArg(native_float_decode);
    b.step("float-decode-differential", "Compare SQLite floating decimal decode and scaling")
        .dependOn(&float_decode_differential.step);

    const formatter_module = b.createModule(.{
        .root_source_file = b.path("src/core/formatter.zig"),
        .target = target,
        .optimize = optimize,
    });
    formatter_module.addImport("build_profile", direct_build_profile);
    const native_formatter_metadata_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_metadata_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "formatter", .module = formatter_module }},
    });
    const native_formatter_metadata = b.addExecutable(.{
        .name = "sqlite3-native-formatter-metadata",
        .root_module = native_formatter_metadata_module,
    });
    const oracle_formatter_metadata_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_metadata_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_metadata_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_metadata_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_metadata_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_metadata_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_metadata = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-metadata",
        .root_module = oracle_formatter_metadata_module,
    });
    const formatter_metadata_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_metadata_differential.py" });
    formatter_metadata_differential.addArtifactArg(oracle_formatter_metadata);
    formatter_metadata_differential.addArtifactArg(native_formatter_metadata);
    b.step("formatter-metadata-differential", "Compare SQLite formatter metadata and hash lookup")
        .dependOn(&formatter_metadata_differential.step);

    const native_formatter_accumulator_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_accumulator_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "formatter", .module = formatter_module }},
    });
    const native_formatter_accumulator = b.addExecutable(.{
        .name = "sqlite3-native-formatter-accumulator",
        .root_module = native_formatter_accumulator_module,
    });
    const oracle_formatter_accumulator_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_accumulator_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_accumulator_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_accumulator_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_accumulator_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_accumulator_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_accumulator = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-accumulator",
        .root_module = oracle_formatter_accumulator_module,
    });
    const formatter_accumulator_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_accumulator_differential.py" });
    formatter_accumulator_differential.addArtifactArg(oracle_formatter_accumulator);
    formatter_accumulator_differential.addArtifactArg(native_formatter_accumulator);
    b.step("formatter-accumulator-differential", "Compare SQLite StrAccum state transitions")
        .dependOn(&formatter_accumulator_differential.step);

    const native_formatter_object_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_object_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "formatter", .module = formatter_module }},
    });
    const native_formatter_object = b.addExecutable(.{
        .name = "sqlite3-native-formatter-object",
        .root_module = native_formatter_object_module,
    });
    const oracle_formatter_object_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_object_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_object_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_object_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_object_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_object_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_object = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-object",
        .root_module = oracle_formatter_object_module,
    });
    const formatter_object_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_object_differential.py" });
    formatter_object_differential.addArtifactArg(oracle_formatter_object);
    formatter_object_differential.addArtifactArg(native_formatter_object);
    b.step("formatter-object-differential", "Compare SQLite dynamic string object ownership and limits")
        .dependOn(&formatter_object_differential.step);

    const native_formatter_rcstr_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_rcstr_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "formatter", .module = formatter_module }},
    });
    const native_formatter_rcstr = b.addExecutable(.{
        .name = "sqlite3-native-formatter-rcstr",
        .root_module = native_formatter_rcstr_module,
    });
    const oracle_formatter_rcstr_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_rcstr_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_rcstr_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_rcstr_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_rcstr_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_rcstr_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_rcstr = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-rcstr",
        .root_module = oracle_formatter_rcstr_module,
    });
    const formatter_rcstr_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_rcstr_differential.py" });
    formatter_rcstr_differential.addArtifactArg(oracle_formatter_rcstr);
    formatter_rcstr_differential.addArtifactArg(native_formatter_rcstr);
    b.step("formatter-rcstr-differential", "Compare SQLite reference-counted string ownership")
        .dependOn(&formatter_rcstr_differential.step);

    const native_formatter_render_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_render_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "formatter", .module = formatter_module }},
    });
    const native_formatter_render = b.addExecutable(.{
        .name = "sqlite3-native-formatter-render",
        .root_module = native_formatter_render_module,
    });
    const oracle_formatter_render_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_render_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_render_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_render_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_render_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_render_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_render = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-render",
        .root_module = oracle_formatter_render_module,
    });
    const formatter_render_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_render_differential.py" });
    formatter_render_differential.addArtifactArg(oracle_formatter_render);
    formatter_render_differential.addArtifactArg(native_formatter_render);
    b.step("formatter-render-differential", "Compare SQLite typed formatter rendering")
        .dependOn(&formatter_render_differential.step);

    const formatter_callers_module = b.createModule(.{
        .root_source_file = b.path("src/core/formatter_callers_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    formatter_callers_module.addImport("build_profile", direct_build_profile);
    const native_formatter_callers_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_callers_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "caller", .module = formatter_callers_module }},
    });
    const native_formatter_callers = b.addExecutable(.{
        .name = "sqlite3-native-formatter-callers",
        .root_module = native_formatter_callers_module,
    });
    const oracle_formatter_callers_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_callers_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_callers_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_callers_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_callers_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_callers_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_callers = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-callers",
        .root_module = oracle_formatter_callers_module,
    });
    const formatter_callers_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_callers_differential.py" });
    formatter_callers_differential.addArtifactArg(oracle_formatter_callers);
    formatter_callers_differential.addArtifactArg(native_formatter_callers);
    b.step("formatter-callers-differential", "Compare SQLite allocation, fixed-buffer, and logging formatter callers")
        .dependOn(&formatter_callers_differential.step);

    const error_offset_module = b.createModule(.{
        .root_source_file = b.path("src/core/error_offset.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_error_offset_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/error_offset_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "error_offset", .module = error_offset_module }},
    });
    const native_error_offset = b.addExecutable(.{
        .name = "sqlite3-native-error-offset",
        .root_module = native_error_offset_module,
    });
    const oracle_error_offset_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_error_offset_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_error_offset_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/error_offset_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_error_offset_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_error_offset_module.linkSystemLibrary("dl", .{});
    const oracle_error_offset = b.addExecutable(.{
        .name = "sqlite3-oracle-error-offset",
        .root_module = oracle_error_offset_module,
    });
    const error_offset_differential = boundedSystemCommand(b, &.{ "python3", "tools/error_offset_differential.py" });
    error_offset_differential.addArtifactArg(oracle_error_offset);
    error_offset_differential.addArtifactArg(native_error_offset);
    const error_offset_tests = b.addTest(.{ .root_module = error_offset_module });
    const run_error_offset_tests = boundedRunArtifact(b, error_offset_tests);
    const error_offset_step = b.step("error-offset-differential", "Compare SQLite parser and expression error-offset recording");
    error_offset_step.dependOn(&error_offset_differential.step);
    error_offset_step.dependOn(&run_error_offset_tests.step);

    const vdbe_mem_module = b.createModule(.{
        .root_source_file = b.path("src/core/internal_vdbe_mem_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vdbe_mem_module.addImport("build_profile", direct_build_profile);
    const native_vdbe_mem_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/vdbe_mem_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vdbe_mem", .module = vdbe_mem_module }},
    });
    const native_vdbe_mem_bridge = b.addObject(.{
        .name = "sqlite3-native-vdbe-mem-bridge",
        .root_module = native_vdbe_mem_bridge_module,
    });
    const native_vdbe_mem_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_vdbe_mem_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/vdbe_mem_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_vdbe_mem_worker_module.addObject(native_vdbe_mem_bridge);
    const native_vdbe_mem_worker = b.addExecutable(.{
        .name = "sqlite3-native-vdbe-mem-worker",
        .root_module = native_vdbe_mem_worker_module,
    });
    const oracle_vdbe_mem_worker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_vdbe_mem_worker_module.addIncludePath(b.path("include"));
    oracle_vdbe_mem_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_vdbe_mem_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/vdbe_mem_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_vdbe_mem_worker_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_vdbe_mem_worker_module.linkSystemLibrary("dl", .{});
    const oracle_vdbe_mem_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-vdbe-mem-worker",
        .root_module = oracle_vdbe_mem_worker_module,
    });
    const vdbe_mem_differential = boundedSystemCommand(b, &.{ "python3", "tools/vdbe_mem_differential.py" });
    vdbe_mem_differential.addArtifactArg(oracle_vdbe_mem_worker);
    vdbe_mem_differential.addArtifactArg(native_vdbe_mem_worker);
    const vdbe_mem_tests = b.addTest(.{ .root_module = vdbe_mem_module });
    const run_vdbe_mem_tests = boundedRunArtifact(b, vdbe_mem_tests);
    const vdbe_mem_differential_step = b.step(
        "vdbe-mem-differential",
        "Compare native and oracle pure VDBE Mem primitives",
    );
    vdbe_mem_differential_step.dependOn(&vdbe_mem_differential.step);
    vdbe_mem_differential_step.dependOn(&run_vdbe_mem_tests.step);

    const vdbe_builder_module = b.createModule(.{
        .root_source_file = b.path("src/core/internal_vdbe_mem_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vdbe_builder_module.addImport("build_profile", direct_build_profile);
    const native_vdbe_builder_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/vdbe_builder_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vdbe_builder", .module = vdbe_builder_module }},
    });
    const native_vdbe_builder = b.addExecutable(.{
        .name = "sqlite3-native-vdbe-builder",
        .root_module = native_vdbe_builder_module,
    });
    const oracle_vdbe_builder_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_vdbe_builder_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_vdbe_builder_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/vdbe_builder_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_vdbe_builder_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_vdbe_builder_module.linkSystemLibrary("dl", .{});
    const oracle_vdbe_builder = b.addExecutable(.{
        .name = "sqlite3-oracle-vdbe-builder",
        .root_module = oracle_vdbe_builder_module,
    });
    const vdbe_builder_differential = boundedSystemCommand(b, &.{ "python3", "tools/vdbe_builder_differential.py" });
    vdbe_builder_differential.addArtifactArg(oracle_vdbe_builder);
    vdbe_builder_differential.addArtifactArg(native_vdbe_builder);
    vdbe_builder_differential.addFileArg(b.path("tests/fixtures/vdbe-builder/operations.txt"));
    const vdbe_builder_step = b.step(
        "vdbe-builder-differential",
        "Compare source VDBE operation-array append traces",
    );
    vdbe_builder_step.dependOn(&vdbe_builder_differential.step);

    const native_utf16to8_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/utf16to8_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vdbe_mem", .module = vdbe_mem_module }},
    });
    const native_utf16to8 = b.addExecutable(.{
        .name = "sqlite3-native-utf16to8",
        .root_module = native_utf16to8_module,
    });
    const oracle_utf16to8_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_utf16to8_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_utf16to8_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/utf16to8_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_utf16to8_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_utf16to8_module.linkSystemLibrary("dl", .{});
    const oracle_utf16to8 = b.addExecutable(.{
        .name = "sqlite3-oracle-utf16to8",
        .root_module = oracle_utf16to8_module,
    });
    const utf16to8_differential = boundedSystemCommand(b, &.{ "python3", "tools/utf16to8_differential.py" });
    utf16to8_differential.addArtifactArg(oracle_utf16to8);
    utf16to8_differential.addArtifactArg(native_utf16to8);
    b.step("utf16to8-differential", "Compare SQLite connection-allocated UTF-16 to UTF-8 conversion")
        .dependOn(&utf16to8_differential.step);

    const native_formatter_arguments_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_arguments_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vdbe_mem", .module = vdbe_mem_module }},
    });
    const native_formatter_arguments = b.addExecutable(.{
        .name = "sqlite3-native-formatter-arguments",
        .root_module = native_formatter_arguments_module,
    });
    const oracle_formatter_arguments_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_arguments_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_arguments_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_arguments_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_arguments_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_arguments_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_arguments = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-arguments",
        .root_module = oracle_formatter_arguments_module,
    });
    const formatter_arguments_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_arguments_differential.py" });
    formatter_arguments_differential.addArtifactArg(oracle_formatter_arguments);
    formatter_arguments_differential.addArtifactArg(native_formatter_arguments);
    b.step("formatter-arguments-differential", "Compare SQLite SQL-formatter argument consumption")
        .dependOn(&formatter_arguments_differential.step);

    const formatter_sql_module = b.createModule(.{
        .root_source_file = b.path("src/core/internal_formatter_sql_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    formatter_sql_module.addImport("build_profile", direct_build_profile);
    const native_formatter_sql_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/formatter_sql_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "formatter_sql", .module = formatter_sql_module }},
    });
    const native_formatter_sql = b.addExecutable(.{
        .name = "sqlite3-native-formatter-sql",
        .root_module = native_formatter_sql_module,
    });
    const oracle_formatter_sql_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_formatter_sql_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_formatter_sql_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/formatter_sql_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_formatter_sql_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_formatter_sql_module.linkSystemLibrary("dl", .{});
    const oracle_formatter_sql = b.addExecutable(.{
        .name = "sqlite3-oracle-formatter-sql",
        .root_module = oracle_formatter_sql_module,
    });
    const formatter_sql_differential = boundedSystemCommand(b, &.{ "python3", "tools/formatter_sql_differential.py" });
    formatter_sql_differential.addArtifactArg(oracle_formatter_sql);
    formatter_sql_differential.addArtifactArg(native_formatter_sql);
    const formatter_sql_tests = b.addTest(.{ .root_module = formatter_sql_module });
    const run_formatter_sql_tests = boundedRunArtifact(b, formatter_sql_tests);
    const formatter_sql_step = b.step("formatter-sql-differential", "Compare SQLite Mem-backed SQL formatter integration");
    formatter_sql_step.dependOn(&formatter_sql_differential.step);
    formatter_sql_step.dependOn(&run_formatter_sql_tests.step);

    const infrastructure_module = b.createModule(.{
        .root_source_file = b.path("src/core/global.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    infrastructure_module.addImport("build_profile", direct_build_profile);
    const native_infrastructure_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/infrastructure_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "infrastructure", .module = infrastructure_module }},
    });
    const native_infrastructure_bridge = b.addObject(.{
        .name = "sqlite3-native-infrastructure-bridge",
        .root_module = native_infrastructure_bridge_module,
    });
    const native_infrastructure_worker_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    native_infrastructure_worker_module.addCSourceFile(.{
        .file = b.path("tests/differential/infrastructure_worker_main.c"),
        .flags = &.{"-std=c99"},
    });
    native_infrastructure_worker_module.addObject(native_infrastructure_bridge);
    const native_infrastructure_worker = b.addExecutable(.{
        .name = "sqlite3-native-infrastructure-worker",
        .root_module = native_infrastructure_worker_module,
    });
    const oracle_infrastructure_worker_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_infrastructure_worker_module.addIncludePath(b.path("include"));
    oracle_infrastructure_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_infrastructure_worker_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/infrastructure_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_infrastructure_worker_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_infrastructure_worker_module.linkSystemLibrary("dl", .{});
    const oracle_infrastructure_worker = b.addExecutable(.{
        .name = "sqlite3-oracle-infrastructure-worker",
        .root_module = oracle_infrastructure_worker_module,
    });
    const infrastructure_differential = boundedSystemCommand(b, &.{ "python3", "tools/infrastructure_differential.py" });
    infrastructure_differential.addArtifactArg(oracle_infrastructure_worker);
    infrastructure_differential.addArtifactArg(native_infrastructure_worker);
    b.step("infrastructure-differential", "Compare native and oracle memory/mutex infrastructure traces")
        .dependOn(&infrastructure_differential.step);

    const mutex_noop_module = b.createModule(.{ .root_source_file = b.path("src/core/mutex.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const native_mutex_noop_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/mutex_noop_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "mutex", .module = mutex_noop_module }},
    });
    const native_mutex_noop = b.addExecutable(.{ .name = "sqlite3-native-mutex-noop", .root_module = native_mutex_noop_module });
    const oracle_mutex_noop_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_mutex_noop_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_mutex_noop_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/mutex_noop_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_mutex_noop_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_mutex_noop_module.linkSystemLibrary("dl", .{});
    const oracle_mutex_noop = b.addExecutable(.{ .name = "sqlite3-oracle-mutex-noop", .root_module = oracle_mutex_noop_module });
    const mutex_noop_differential = boundedSystemCommand(b, &.{ "python3", "tools/mutex_noop_differential.py" });
    mutex_noop_differential.addArtifactArg(oracle_mutex_noop);
    mutex_noop_differential.addArtifactArg(native_mutex_noop);
    b.step("mutex-noop-differential", "Compare SQLite no-op mutex method table")
        .dependOn(&mutex_noop_differential.step);

    const tokenizer_module = b.createModule(.{ .root_source_file = b.path("src/core/tokenizer.zig"), .target = target, .optimize = optimize });
    const native_tokenizer_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/tokenizer_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tokenizer", .module = tokenizer_module }},
    });
    const native_tokenizer_bridge = b.addObject(.{ .name = "sqlite3-native-tokenizer-bridge", .root_module = native_tokenizer_bridge_module });
    const native_tokenizer_worker_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    native_tokenizer_worker_module.addCSourceFile(.{ .file = b.path("tests/differential/tokenizer_worker_main.c"), .flags = &.{"-std=c99"} });
    native_tokenizer_worker_module.addObject(native_tokenizer_bridge);
    const native_tokenizer_worker = b.addExecutable(.{ .name = "sqlite3-native-tokenizer-worker", .root_module = native_tokenizer_worker_module });
    const oracle_tokenizer_worker_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_tokenizer_worker_module.addIncludePath(b.path("include"));
    oracle_tokenizer_worker_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_tokenizer_worker_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/tokenizer_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_tokenizer_worker_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_tokenizer_worker_module.linkSystemLibrary("dl", .{});
    const oracle_tokenizer_worker = b.addExecutable(.{ .name = "sqlite3-oracle-tokenizer-worker", .root_module = oracle_tokenizer_worker_module });
    const tokenizer_differential = boundedSystemCommand(b, &.{ "python3", "tools/tokenizer_differential.py" });
    tokenizer_differential.addArtifactArg(oracle_tokenizer_worker);
    tokenizer_differential.addArtifactArg(native_tokenizer_worker);
    b.step("tokenizer-differential", "Compare native and oracle SQL token streams").dependOn(&tokenizer_differential.step);

    const complete_module = b.createModule(.{
        .root_source_file = b.path("src/core/complete.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_complete_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/complete_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "complete", .module = complete_module }},
    });
    const native_complete = b.addExecutable(.{ .name = "sqlite3-native-complete", .root_module = native_complete_module });
    const oracle_complete_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_complete_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_complete_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/complete_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) oracle_complete_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_complete_module.linkSystemLibrary("dl", .{});
    const oracle_complete = b.addExecutable(.{ .name = "sqlite3-oracle-complete", .root_module = oracle_complete_module });
    const complete_differential = boundedSystemCommand(b, &.{ "python3", "tools/complete_differential.py" });
    complete_differential.addArtifactArg(oracle_complete);
    complete_differential.addArtifactArg(native_complete);
    const complete_tests = b.addTest(.{ .root_module = complete_module });
    const run_complete_tests = boundedRunArtifact(b, complete_tests);
    const complete_step = b.step("complete-differential", "Compare SQLite trigger-aware SQL completeness");
    complete_step.dependOn(&complete_differential.step);
    complete_step.dependOn(&run_complete_tests.step);

    const generate_token_metadata = boundedSystemCommand(b, &.{ "python3", "tools/generate_token_metadata.py" });
    b.step("generate-token-metadata", "Regenerate native token, keyword, and fallback metadata")
        .dependOn(&generate_token_metadata.step);

    const make_hybrid_parser = boundedSystemCommand(b, &.{ "python3", "tools/make_hybrid_parser.py" });
    make_hybrid_parser.addFileArg(b.path("reference/c_oracle/sqlite3.c"));
    const hybrid_parser_source = make_hybrid_parser.addOutputFileArg("sqlite3-hybrid-tokenizer.c");
    const oracle_parser_accept_module = oracleModule(b, target, optimize);
    oracle_parser_accept_module.addCSourceFile(.{ .file = b.path("tests/differential/parser_accept_worker.c"), .flags = &.{"-std=c99"} });
    const oracle_parser_accept = b.addExecutable(.{ .name = "sqlite3-oracle-parser-accept-worker", .root_module = oracle_parser_accept_module });
    const hybrid_parser_accept_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    hybrid_parser_accept_module.addIncludePath(b.path("include"));
    hybrid_parser_accept_module.addIncludePath(b.path("reference/c_oracle"));
    hybrid_parser_accept_module.addCSourceFile(.{ .file = hybrid_parser_source, .flags = sqlite_c_flags });
    hybrid_parser_accept_module.addCSourceFile(.{ .file = b.path("tests/differential/parser_accept_worker.c"), .flags = &.{"-std=c99"} });
    hybrid_parser_accept_module.addObject(native_tokenizer_bridge);
    if (target.result.os.tag != .windows) hybrid_parser_accept_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) hybrid_parser_accept_module.linkSystemLibrary("dl", .{});
    const hybrid_parser_accept = b.addExecutable(.{ .name = "sqlite3-hybrid-parser-accept-worker", .root_module = hybrid_parser_accept_module });
    const parser_accept_differential = boundedSystemCommand(b, &.{ "python3", "tools/parser_accept_differential.py" });
    parser_accept_differential.addArtifactArg(oracle_parser_accept);
    parser_accept_differential.addArtifactArg(hybrid_parser_accept);
    b.step("parser-accept-differential", "Compare C and Zig-tokenizer/C-parser prepare acceptance")
        .dependOn(&parser_accept_differential.step);

    const oracle_smoke_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_smoke_module.addIncludePath(b.path("include"));
    oracle_smoke_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/oracle_smoke.c"),
        .flags = &.{"-std=c99"},
    });
    oracle_smoke_module.linkLibrary(oracle_static);
    const oracle_smoke = b.addExecutable(.{
        .name = "sqlite3-oracle-smoke",
        .root_module = oracle_smoke_module,
    });
    const run_oracle_smoke = addRunStep(
        b,
        "oracle-smoke",
        "Run the pinned C oracle smoke test",
        oracle_smoke,
    );

    const rollback_trace_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rollback_trace_module.addIncludePath(b.path("include"));
    rollback_trace_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/rollback_trace.c"),
        .flags = &.{"-std=c99"},
    });
    rollback_trace_module.linkLibrary(oracle_static);
    const rollback_trace = b.addExecutable(.{
        .name = "sqlite3-oracle-rollback-trace",
        .root_module = rollback_trace_module,
    });
    const run_rollback_trace = addRunStep(
        b,
        "rollback-trace",
        "Capture and validate the oracle DELETE/FULL commit trace",
        rollback_trace,
    );

    const variadic_module = b.createModule(.{
        .root_source_file = b.path("tests/toolchain/variadic_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    variadic_module.addCSourceFile(.{
        .file = b.path("tests/toolchain/variadic_probe.c"),
        .flags = &.{"-std=c99"},
    });
    const variadic_probe = b.addExecutable(.{
        .name = "variadic-abi-probe",
        .root_module = variadic_module,
    });
    const run_variadic = addRunStep(
        b,
        "variadic-spike",
        "Run the C-varargs to typed-Zig ABI feasibility probe",
        variadic_probe,
    );

    const hybrid_module = b.createModule(.{
        .root_source_file = b.path("reference/hybrid_probe/hybrid_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hybrid_module.addIncludePath(b.path("include"));
    hybrid_module.addCSourceFile(.{
        .file = b.path("reference/hybrid_probe/vfs_bridge.c"),
        .flags = &.{"-std=c99"},
    });
    hybrid_module.linkLibrary(oracle_static);
    const hybrid_probe = b.addExecutable(.{
        .name = "hybrid-vfs-callback-probe",
        .root_module = hybrid_module,
    });
    const run_hybrid = addRunStep(
        b,
        "hybrid-spike",
        "Run the stateful VFS and stateless callback hybrid probe",
        hybrid_probe,
    );
    b.step("hybrid", "Run the historical hybrid feasibility probe")
        .dependOn(&run_hybrid.step);

    const vfs_module = b.createModule(.{ .root_source_file = b.path("src/core/vfs.zig"), .target = target, .optimize = optimize, .link_libc = true });
    vfs_module.addImport("build_profile", direct_build_profile);
    const memory_vfs_probe_module = b.createModule(.{
        .root_source_file = b.path("tests/vfs/memory_vfs_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vfs", .module = vfs_module }},
    });
    memory_vfs_probe_module.addIncludePath(b.path("include"));
    memory_vfs_probe_module.addCSourceFile(.{ .file = b.path("tests/vfs/memory_vfs_probe.c"), .flags = &.{"-std=c99"} });
    memory_vfs_probe_module.linkLibrary(oracle_static);
    const memory_vfs_probe = b.addExecutable(.{ .name = "sqlite3-memory-vfs-probe", .root_module = memory_vfs_probe_module });
    const run_memory_vfs = addRunStep(b, "vfs-test", "Run SQLite core file tests on the native in-memory VFS", memory_vfs_probe);
    const vfs_trace_differential = boundedSystemCommand(b, &.{ "python3", "tools/vfs_trace_differential.py" });
    vfs_trace_differential.addArtifactArg(rollback_trace);
    vfs_trace_differential.addArtifactArg(memory_vfs_probe);
    b.step("vfs-differential", "Compare normalized oracle and in-memory VFS durability traces")
        .dependOn(&vfs_trace_differential.step);

    const memory_journal_module = b.createModule(.{
        .root_source_file = b.path("src/core/memory_journal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    memory_journal_module.addImport("build_profile", direct_build_profile);
    const native_memory_journal_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/memory_journal_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "memory_journal", .module = memory_journal_module }},
    });
    const native_memory_journal = b.addExecutable(.{
        .name = "sqlite3-native-memory-journal",
        .root_module = native_memory_journal_module,
    });
    const oracle_memory_journal_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    oracle_memory_journal_module.addIncludePath(b.path("reference/c_oracle"));
    oracle_memory_journal_module.addCSourceFile(.{
        .file = b.path("reference/c_oracle/memory_journal_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) oracle_memory_journal_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) oracle_memory_journal_module.linkSystemLibrary("dl", .{});
    const oracle_memory_journal = b.addExecutable(.{
        .name = "sqlite3-oracle-memory-journal",
        .root_module = oracle_memory_journal_module,
    });
    const memory_journal_differential = boundedSystemCommand(b, &.{ "python3", "tools/memory_journal_differential.py" });
    memory_journal_differential.addArtifactArg(oracle_memory_journal);
    memory_journal_differential.addArtifactArg(native_memory_journal);
    const memory_journal_differential_step = b.step(
        "memory-journal-differential",
        "Compare source and native in-memory journal traces",
    );
    memory_journal_differential_step.dependOn(&memory_journal_differential.step);

    const pcache_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    pcache_oracle_module.addIncludePath(b.path("upstream/sqlite/src"));
    pcache_oracle_module.addIncludePath(b.path("tests/differential/pcache_include"));
    pcache_oracle_module.addIncludePath(b.path("generated/parser"));
    pcache_oracle_module.addIncludePath(b.path("include"));
    pcache_oracle_module.addCSourceFile(.{
        .file = b.path("tests/differential/pcache_oracle_worker.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_CORE=1", "-DSQLITE_THREADSAFE=1" },
    });
    const pcache_oracle = b.addExecutable(.{ .name = "sqlite3-pcache-oracle", .root_module = pcache_oracle_module });
    const page_cache_module = b.createModule(.{ .root_source_file = b.path("src/core/page_cache.zig"), .target = target, .optimize = optimize, .link_libc = true });
    page_cache_module.addImport("build_profile", direct_build_profile);
    const pcache_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/pcache_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "page_cache", .module = page_cache_module }},
    });
    const pcache_native = b.addExecutable(.{ .name = "sqlite3-pcache-native", .root_module = pcache_native_module });
    const pcache_differential = boundedSystemCommand(b, &.{ "python3", "tools/pcache_differential.py" });
    pcache_differential.addArtifactArg(pcache_oracle);
    pcache_differential.addArtifactArg(pcache_native);
    b.step("pcache-differential", "Compare cache state, dirty, stress, and purge traces")
        .dependOn(&pcache_differential.step);
    const generate_pcache_sequences = boundedSystemCommand(b, &.{ "python3", "tools/generate_pcache_sequences.py" });
    b.step("generate-pcache-sequences", "Regenerate deterministic bounded cache state sequences")
        .dependOn(&generate_pcache_sequences.step);

    const pager_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    pager_oracle_module.addIncludePath(b.path("reference/c_oracle"));
    pager_oracle_module.addIncludePath(b.path("include"));
    pager_oracle_module.addCSourceFile(.{
        .file = b.path("tests/differential/pager_oracle_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) pager_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) pager_oracle_module.linkSystemLibrary("dl", .{});
    const pager_oracle = b.addExecutable(.{ .name = "sqlite3-pager-oracle", .root_module = pager_oracle_module });

    const pager_module = b.createModule(.{
        .root_source_file = b.path("src/core/pager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pager_module.addImport("build_profile", direct_build_profile);
    const pager_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/pager_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "pager", .module = pager_module }},
    });
    const pager_native = b.addExecutable(.{ .name = "sqlite3-pager-native", .root_module = pager_native_module });
    const pager_differential = boundedSystemCommand(b, &.{ "python3", "tools/pager_differential.py" });
    pager_differential.addArtifactArg(pager_oracle);
    pager_differential.addArtifactArg(pager_native);
    b.step("pager-differential", "Compare read-only pager fixtures, pages, cache, and transactions")
        .dependOn(&pager_differential.step);

    const generate_pager_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_pager_fixtures.py" });
    b.step("generate-pager-fixtures", "Regenerate the deterministic bounded pager corpus")
        .dependOn(&generate_pager_fixtures.step);

    const rollback_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    rollback_oracle_module.addIncludePath(b.path("reference/c_oracle"));
    rollback_oracle_module.addIncludePath(b.path("include"));
    rollback_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/rollback_oracle_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) rollback_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) rollback_oracle_module.linkSystemLibrary("dl", .{});
    const rollback_oracle = b.addExecutable(.{ .name = "sqlite3-rollback-oracle", .root_module = rollback_oracle_module });
    const rollback_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/rollback_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "pager", .module = pager_module }},
    });
    const rollback_native = b.addExecutable(.{ .name = "sqlite3-rollback-native", .root_module = rollback_native_module });
    const rollback_differential = boundedSystemCommand(b, &.{ "python3", "tools/rollback_differential.py" });
    rollback_differential.addArtifactArg(rollback_oracle);
    rollback_differential.addArtifactArg(rollback_native);
    b.step("rollback-differential", "Compare bounded rollback writes, hot recovery, and continuation")
        .dependOn(&rollback_differential.step);
    const generate_rollback_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_rollback_fixtures.py" });
    b.step("generate-rollback-fixtures", "Regenerate the deterministic bounded rollback corpus")
        .dependOn(&generate_rollback_fixtures.step);

    const sql_frontend_module = b.createModule(.{
        .root_source_file = b.path("src/core/sql_frontend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sql_frontend_module.addImport("build_profile", direct_build_profile);
    const sql_expression_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/sql_expression_native_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "frontend", .module = sql_frontend_module }},
    });
    sql_expression_bridge_module.addAnonymousImport("ddl_fixture", .{ .root_source_file = b.path("tests/fixtures/btree-mutation/none-512.db") });
    sql_expression_bridge_module.addAnonymousImport("index_fixture", .{ .root_source_file = b.path("tests/fixtures/btree-mutation/index-without-rowid-1024.db") });
    const sql_expression_bridge = b.addObject(.{ .name = "sqlite3-sql-expression-bridge", .root_module = sql_expression_bridge_module });
    const sql_expression_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_expression_native_module.addIncludePath(b.path("include"));
    sql_expression_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_expression_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_expression_native_module.addObject(sql_expression_bridge);
    const sql_expression_native = b.addExecutable(.{ .name = "sqlite3-sql-expression-native", .root_module = sql_expression_native_module });
    const sql_expression_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_expression_oracle_module.addIncludePath(b.path("include"));
    sql_expression_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_expression_client.c"), .flags = &.{"-std=c11"} });
    sql_expression_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_expression_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_expression_oracle_module.linkSystemLibrary("dl", .{});
    const sql_expression_oracle = b.addExecutable(.{ .name = "sqlite3-sql-expression-oracle", .root_module = sql_expression_oracle_module });
    const sql_expression_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_expression_differential.py" });
    sql_expression_differential.addArtifactArg(sql_expression_oracle);
    sql_expression_differential.addArtifactArg(sql_expression_native);
    b.step("sql-expression-differential", "Compare the bounded expression SQL/codegen slice").dependOn(&sql_expression_differential.step);
    const sql_schema_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_schema_native_module.addIncludePath(b.path("include"));
    sql_schema_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_schema_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_schema_native_module.addObject(sql_expression_bridge);
    const sql_schema_native = b.addExecutable(.{ .name = "sqlite3-sql-schema-native", .root_module = sql_schema_native_module });
    const sql_schema_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_schema_oracle_module.addIncludePath(b.path("include"));
    sql_schema_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_schema_client.c"), .flags = &.{"-std=c11"} });
    sql_schema_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_schema_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_schema_oracle_module.linkSystemLibrary("dl", .{});
    const sql_schema_oracle = b.addExecutable(.{ .name = "sqlite3-sql-schema-oracle", .root_module = sql_schema_oracle_module });
    const sql_schema_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_schema_differential.py" });
    sql_schema_differential.addArtifactArg(sql_schema_oracle);
    sql_schema_differential.addArtifactArg(sql_schema_native);
    b.step("sql-schema-differential", "Compare the bounded schema/simple-DDL slice").dependOn(&sql_schema_differential.step);
    const sql_table_scan_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_table_scan_native_module.addIncludePath(b.path("include"));
    sql_table_scan_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_table_scan_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_table_scan_native_module.addObject(sql_expression_bridge);
    const sql_table_scan_native = b.addExecutable(.{ .name = "sqlite3-sql-table-scan-native", .root_module = sql_table_scan_native_module });
    const sql_table_scan_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_table_scan_oracle_module.addIncludePath(b.path("include"));
    sql_table_scan_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_table_scan_client.c"), .flags = &.{"-std=c11"} });
    sql_table_scan_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_table_scan_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_table_scan_oracle_module.linkSystemLibrary("dl", .{});
    const sql_table_scan_oracle = b.addExecutable(.{ .name = "sqlite3-sql-table-scan-oracle", .root_module = sql_table_scan_oracle_module });
    const sql_table_scan_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_table_scan_differential.py" });
    sql_table_scan_differential.addArtifactArg(sql_table_scan_oracle);
    sql_table_scan_differential.addArtifactArg(sql_table_scan_native);
    b.step("sql-table-scan-differential", "Compare the bounded table-scan SELECT slice").dependOn(&sql_table_scan_differential.step);
    const sql_insert_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_insert_native_module.addIncludePath(b.path("include"));
    sql_insert_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_insert_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_insert_native_module.addObject(sql_expression_bridge);
    const sql_insert_native = b.addExecutable(.{ .name = "sqlite3-sql-insert-native", .root_module = sql_insert_native_module });
    const sql_insert_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_insert_oracle_module.addIncludePath(b.path("include"));
    sql_insert_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_insert_client.c"), .flags = &.{"-std=c11"} });
    sql_insert_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_insert_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_insert_oracle_module.linkSystemLibrary("dl", .{});
    const sql_insert_oracle = b.addExecutable(.{ .name = "sqlite3-sql-insert-oracle", .root_module = sql_insert_oracle_module });
    const sql_insert_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_insert_differential.py" });
    sql_insert_differential.addArtifactArg(sql_insert_oracle);
    sql_insert_differential.addArtifactArg(sql_insert_native);
    b.step("sql-insert-differential", "Compare the bounded generated INSERT slice").dependOn(&sql_insert_differential.step);
    const sql_update_delete_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_update_delete_native_module.addIncludePath(b.path("include"));
    sql_update_delete_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_update_delete_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_update_delete_native_module.addObject(sql_expression_bridge);
    const sql_update_delete_native = b.addExecutable(.{ .name = "sqlite3-sql-update-delete-native", .root_module = sql_update_delete_native_module });
    const sql_update_delete_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_update_delete_oracle_module.addIncludePath(b.path("include"));
    sql_update_delete_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_update_delete_client.c"), .flags = &.{"-std=c11"} });
    sql_update_delete_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_update_delete_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_update_delete_oracle_module.linkSystemLibrary("dl", .{});
    const sql_update_delete_oracle = b.addExecutable(.{ .name = "sqlite3-sql-update-delete-oracle", .root_module = sql_update_delete_oracle_module });
    const sql_update_delete_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_update_delete_differential.py" });
    sql_update_delete_differential.addArtifactArg(sql_update_delete_oracle);
    sql_update_delete_differential.addArtifactArg(sql_update_delete_native);
    b.step("sql-update-delete-differential", "Compare bounded generated UPDATE and DELETE").dependOn(&sql_update_delete_differential.step);
    const sql_index_join_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_index_join_native_module.addIncludePath(b.path("include"));
    sql_index_join_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_index_join_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_index_join_native_module.addObject(sql_expression_bridge);
    const sql_index_join_native = b.addExecutable(.{ .name = "sqlite3-sql-index-join-native", .root_module = sql_index_join_native_module });
    const sql_index_join_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_index_join_oracle_module.addIncludePath(b.path("include"));
    sql_index_join_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_index_join_client.c"), .flags = &.{"-std=c11"} });
    sql_index_join_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_index_join_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_index_join_oracle_module.linkSystemLibrary("dl", .{});
    const sql_index_join_oracle = b.addExecutable(.{ .name = "sqlite3-sql-index-join-oracle", .root_module = sql_index_join_oracle_module });
    const sql_index_join_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_index_join_differential.py" });
    sql_index_join_differential.addArtifactArg(sql_index_join_oracle);
    sql_index_join_differential.addArtifactArg(sql_index_join_native);
    b.step("sql-index-join-differential", "Compare the bounded index-scan and join slice").dependOn(&sql_index_join_differential.step);
    const sql_advanced_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_advanced_native_module.addIncludePath(b.path("include"));
    sql_advanced_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_advanced_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_advanced_native_module.addObject(sql_expression_bridge);
    const sql_advanced_native = b.addExecutable(.{ .name = "sqlite3-sql-advanced-native", .root_module = sql_advanced_native_module });
    const sql_advanced_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_advanced_oracle_module.addIncludePath(b.path("include"));
    sql_advanced_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_advanced_client.c"), .flags = &.{"-std=c11"} });
    sql_advanced_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_advanced_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_advanced_oracle_module.linkSystemLibrary("dl", .{});
    const sql_advanced_oracle = b.addExecutable(.{ .name = "sqlite3-sql-advanced-oracle", .root_module = sql_advanced_oracle_module });
    const sql_advanced_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_advanced_differential.py" });
    sql_advanced_differential.addArtifactArg(sql_advanced_oracle);
    sql_advanced_differential.addArtifactArg(sql_advanced_native);
    b.step("sql-advanced-differential", "Compare scoped bounded advanced SQL families").dependOn(&sql_advanced_differential.step);
    const sql_planner_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_planner_native_module.addIncludePath(b.path("include"));
    sql_planner_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_planner_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_planner_native_module.addObject(sql_expression_bridge);
    const sql_planner_native = b.addExecutable(.{ .name = "sqlite3-sql-planner-native", .root_module = sql_planner_native_module });
    const sql_planner_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_planner_oracle_module.addIncludePath(b.path("include"));
    sql_planner_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_planner_client.c"), .flags = &.{"-std=c11"} });
    sql_planner_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_planner_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_planner_oracle_module.linkSystemLibrary("dl", .{});
    const sql_planner_oracle = b.addExecutable(.{ .name = "sqlite3-sql-planner-oracle", .root_module = sql_planner_oracle_module });
    const sql_planner_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_planner_differential.py" });
    sql_planner_differential.addArtifactArg(sql_planner_oracle);
    sql_planner_differential.addArtifactArg(sql_planner_native);
    b.step("sql-planner-differential", "Compare bounded rowid predicates, ordering, and limits").dependOn(&sql_planner_differential.step);
    const sql_index_planner_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_index_planner_native_module.addIncludePath(b.path("include"));
    sql_index_planner_native_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_index_planner_client.c"), .flags = &.{ "-std=c11", "-DNATIVE_ENGINE=1" } });
    sql_index_planner_native_module.addObject(sql_expression_bridge);
    const sql_index_planner_native = b.addExecutable(.{ .name = "sqlite3-sql-index-planner-native", .root_module = sql_index_planner_native_module });
    const sql_index_planner_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sql_index_planner_oracle_module.addIncludePath(b.path("include"));
    sql_index_planner_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/sql_index_planner_client.c"), .flags = &.{"-std=c11"} });
    sql_index_planner_oracle_module.addCSourceFile(.{ .file = b.path("reference/c_oracle/sqlite3.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) sql_index_planner_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) sql_index_planner_oracle_module.linkSystemLibrary("dl", .{});
    const sql_index_planner_oracle = b.addExecutable(.{ .name = "sqlite3-sql-index-planner-oracle", .root_module = sql_index_planner_oracle_module });
    const sql_index_planner_differential = boundedSystemCommand(b, &.{ "python3", "tools/sql_index_planner_differential.py" });
    sql_index_planner_differential.addArtifactArg(sql_index_planner_oracle);
    sql_index_planner_differential.addArtifactArg(sql_index_planner_native);
    b.step("sql-index-planner-differential", "Compare bounded automatic covering-order selection").dependOn(&sql_index_planner_differential.step);
    const generate_sql_planner_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_planner_fixtures.py" });
    b.step("generate-sql-planner-fixtures", "Regenerate the Phase 14 rowid planner corpus").dependOn(&generate_sql_planner_fixtures.step);
    const generate_sql_index_planner_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_index_planner_fixtures.py" });
    b.step("generate-sql-index-planner-fixtures", "Regenerate the Phase 14 index planner corpus").dependOn(&generate_sql_index_planner_fixtures.step);
    const generate_sql_index_join_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_index_join_fixtures.py" });
    b.step("generate-sql-index-join-fixtures", "Regenerate the Phase 13 index/join corpus").dependOn(&generate_sql_index_join_fixtures.step);
    const generate_sql_advanced_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_advanced_fixtures.py" });
    b.step("generate-sql-advanced-fixtures", "Regenerate the scoped Phase 13 advanced corpus").dependOn(&generate_sql_advanced_fixtures.step);
    const generate_sql_update_delete_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_update_delete_fixtures.py" });
    b.step("generate-sql-update-delete-fixtures", "Regenerate the Phase 13 UPDATE/DELETE corpus")
        .dependOn(&generate_sql_update_delete_fixtures.step);
    const generate_sql_insert_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_insert_fixtures.py" });
    b.step("generate-sql-insert-fixtures", "Regenerate the Phase 13 INSERT corpus")
        .dependOn(&generate_sql_insert_fixtures.step);
    const generate_sql_table_scan_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_table_scan_fixtures.py" });
    b.step("generate-sql-table-scan-fixtures", "Regenerate the Phase 13 table-scan corpus")
        .dependOn(&generate_sql_table_scan_fixtures.step);
    const generate_sql_schema_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_schema_fixtures.py" });
    b.step("generate-sql-schema-fixtures", "Regenerate the Phase 13 schema/simple-DDL corpus")
        .dependOn(&generate_sql_schema_fixtures.step);
    const generate_sql_expression_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_sql_expression_fixtures.py" });
    b.step("generate-sql-expression-fixtures", "Regenerate the Phase 13 expression SELECT corpus")
        .dependOn(&generate_sql_expression_fixtures.step);

    const statement_module = b.createModule(.{
        .root_source_file = b.path("src/core/statement.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    statement_module.addImport("build_profile", direct_build_profile);
    const statement_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/api/statement_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "statement", .module = statement_module }},
    });
    const statement_bridge = b.addObject(.{ .name = "sqlite3-statement-bridge", .root_module = statement_bridge_module });
    const statement_client_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    statement_client_module.addIncludePath(b.path("include"));
    statement_client_module.addCSourceFile(.{ .file = b.path("tests/api/statement_client.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    statement_client_module.addObject(statement_bridge);
    const statement_client = b.addExecutable(.{ .name = "statement-api-client", .root_module = statement_client_module });
    const run_statement_client = boundedRunArtifact(b, statement_client);
    b.step("statement-api-client", "Run the canonical-header Phase 12 statement lifecycle client").dependOn(&run_statement_client.step);
    const phase17_connection_client_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    phase17_connection_client_module.addIncludePath(b.path("include"));
    phase17_connection_client_module.addCSourceFile(.{ .file = b.path("tests/api/phase17_connection_client.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    phase17_connection_client_module.addCSourceFile(.{ .file = b.path("tests/legacy_c_abi/variadic_shims.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    phase17_connection_client_module.linkLibrary(native_static);
    const phase17_extension_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    phase17_extension_module.addIncludePath(b.path("include"));
    phase17_extension_module.addCSourceFile(.{ .file = b.path("tests/api/phase17_extension.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC" } });
    const phase17_extension = b.addLibrary(.{ .name = "phase17-extension", .linkage = .dynamic, .root_module = phase17_extension_module });
    const phase17_connection_client = b.addExecutable(.{ .name = "phase17-connection-client", .root_module = phase17_connection_client_module });
    const run_phase17_connection_client = boundedRunArtifact(b, phase17_connection_client);
    run_phase17_connection_client.addArtifactArg(phase17_extension);
    b.step("phase17-connection-client", "Run canonical-header Phase 17 connection and utility APIs").dependOn(&run_phase17_connection_client.step);
    const generate_phase17_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_phase17_fixtures.py" });
    b.step("generate-phase17-fixtures", "Regenerate the Phase 17 public API profile").dependOn(&generate_phase17_fixtures.step);
    const generate_statement_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_statement_fixtures.py" });
    b.step("generate-statement-fixtures", "Regenerate the deterministic Phase 12 statement corpus")
        .dependOn(&generate_statement_fixtures.step);

    const vdbe_module = b.createModule(.{
        .root_source_file = b.path("src/core/vdbe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vdbe_module.addImport("build_profile", direct_build_profile);
    const vdbe_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    vdbe_oracle_module.addIncludePath(b.path("reference/c_oracle"));
    vdbe_oracle_module.addIncludePath(b.path("include"));
    vdbe_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/vdbe_oracle_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) vdbe_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) vdbe_oracle_module.linkSystemLibrary("dl", .{});
    const vdbe_oracle = b.addExecutable(.{ .name = "sqlite3-vdbe-oracle", .root_module = vdbe_oracle_module });
    const vdbe_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/vdbe_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vdbe", .module = vdbe_module }},
    });
    const vdbe_native = b.addExecutable(.{ .name = "sqlite3-vdbe-native", .root_module = vdbe_native_module });
    const vdbe_differential = boundedSystemCommand(b, &.{ "python3", "tools/vdbe_differential.py" });
    vdbe_differential.addArtifactArg(vdbe_oracle);
    vdbe_differential.addArtifactArg(vdbe_native);
    b.step("vdbe-differential", "Compare bounded VDBE programs, rows, callbacks, and halt state")
        .dependOn(&vdbe_differential.step);
    const generate_vdbe_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_vdbe_fixtures.py" });
    b.step("generate-vdbe-fixtures", "Regenerate the deterministic Phase 11 VDBE corpus")
        .dependOn(&generate_vdbe_fixtures.step);

    const wal_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    wal_oracle_module.addIncludePath(b.path("reference/c_oracle"));
    wal_oracle_module.addIncludePath(b.path("include"));
    wal_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/wal_oracle_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) wal_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) wal_oracle_module.linkSystemLibrary("dl", .{});
    const wal_oracle = b.addExecutable(.{ .name = "sqlite3-wal-oracle", .root_module = wal_oracle_module });
    const wal_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/wal_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "pager", .module = pager_module }},
    });
    const wal_native = b.addExecutable(.{ .name = "sqlite3-wal-native", .root_module = wal_native_module });
    const wal_differential = boundedSystemCommand(b, &.{ "python3", "tools/wal_differential.py" });
    wal_differential.addArtifactArg(wal_oracle);
    wal_differential.addArtifactArg(wal_native);
    b.step("wal-differential", "Compare bounded WAL read/write/recovery/checkpoint interoperability")
        .dependOn(&wal_differential.step);
    const wal_unix_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/wal_unix_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "pager", .module = pager_module }},
    });
    const wal_unix_bridge = b.addObject(.{ .name = "sqlite3-wal-unix-bridge", .root_module = wal_unix_bridge_module });
    const wal_unix_hybrid_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    wal_unix_hybrid_module.addIncludePath(b.path("reference/c_oracle"));
    wal_unix_hybrid_module.addIncludePath(b.path("include"));
    wal_unix_hybrid_module.addCSourceFile(.{ .file = b.path("tests/differential/wal_unix_hybrid.c"), .flags = sqlite_c_flags });
    wal_unix_hybrid_module.addObject(wal_unix_bridge);
    if (target.result.os.tag != .windows) wal_unix_hybrid_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) wal_unix_hybrid_module.linkSystemLibrary("dl", .{});
    const wal_unix_hybrid = b.addExecutable(.{ .name = "sqlite3-wal-unix-hybrid", .root_module = wal_unix_hybrid_module });
    const run_wal_unix_hybrid = boundedRunArtifact(b, wal_unix_hybrid);
    run_wal_unix_hybrid.addArg("tests/fixtures/wal/base-4096.db");
    b.step("wal-unix-hybrid", "Run cross-process WAL locks through the upstream Unix VFS").dependOn(&run_wal_unix_hybrid.step);
    const unix_vfs_module = b.createModule(.{ .root_source_file = b.path("src/core/unix_vfs.zig"), .target = target, .optimize = optimize, .link_libc = true });
    unix_vfs_module.addImport("build_profile", direct_build_profile);
    const unix_vfs_tests = b.addTest(.{ .root_module = unix_vfs_module });
    const run_unix_vfs_tests = boundedRunArtifact(b, unix_vfs_tests);
    b.step("unix-vfs-test", "Run native Unix VFS file, lock, mmap, URI, override, and pager tests").dependOn(&run_unix_vfs_tests.step);
    const wal_unix_native_bridge_module = b.createModule(.{ .root_source_file = b.path("tests/differential/wal_unix_native_bridge.zig"), .target = target, .optimize = optimize, .link_libc = true });
    wal_unix_native_bridge_module.addImport("unix_vfs", unix_vfs_module);
    const wal_unix_native_bridge = b.addObject(.{ .name = "sqlite3-wal-unix-native-bridge", .root_module = wal_unix_native_bridge_module });
    const wal_unix_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    wal_unix_native_module.addIncludePath(b.path("reference/c_oracle"));
    wal_unix_native_module.addIncludePath(b.path("include"));
    wal_unix_native_module.addCSourceFile(.{ .file = b.path("tests/differential/wal_unix_native.c"), .flags = sqlite_c_flags });
    wal_unix_native_module.addObject(wal_unix_native_bridge);
    if (target.result.os.tag != .windows) wal_unix_native_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) wal_unix_native_module.linkSystemLibrary("dl", .{});
    const wal_unix_native = b.addExecutable(.{ .name = "sqlite3-wal-unix-native", .root_module = wal_unix_native_module });
    const run_wal_unix_native = boundedRunArtifact(b, wal_unix_native);
    run_wal_unix_native.addArg("tests/fixtures/wal/base-4096.db");
    b.step("wal-unix-native", "Run cross-process WAL interoperability through the native Unix VFS").dependOn(&run_wal_unix_native.step);
    const rollback_unix_native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    rollback_unix_native_module.addIncludePath(b.path("reference/c_oracle"));
    rollback_unix_native_module.addIncludePath(b.path("include"));
    rollback_unix_native_module.addCSourceFile(.{ .file = b.path("tests/differential/rollback_unix_native.c"), .flags = sqlite_c_flags });
    rollback_unix_native_module.addObject(wal_unix_native_bridge);
    if (target.result.os.tag != .windows) rollback_unix_native_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) rollback_unix_native_module.linkSystemLibrary("dl", .{});
    const rollback_unix_native = b.addExecutable(.{ .name = "sqlite3-rollback-unix-native", .root_module = rollback_unix_native_module });
    const run_rollback_unix_native = boundedRunArtifact(b, rollback_unix_native);
    run_rollback_unix_native.addArg("tests/fixtures/btree-mutation/none-512.db");
    b.step("rollback-unix-native", "Run cross-process rollback interoperability through the native Unix VFS").dependOn(&run_rollback_unix_native.step);
    const generate_unix_vfs_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_unix_vfs_fixtures.py" });
    b.step("generate-unix-vfs-fixtures", "Regenerate the Phase 15 native Unix VFS profile").dependOn(&generate_unix_vfs_fixtures.step);
    const generate_wal_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_wal_fixtures.py" });
    b.step("generate-wal-fixtures", "Regenerate the deterministic Phase 10 WAL corpus")
        .dependOn(&generate_wal_fixtures.step);

    const btree_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    btree_oracle_module.addIncludePath(b.path("reference/c_oracle"));
    btree_oracle_module.addIncludePath(b.path("include"));
    btree_oracle_module.addCSourceFile(.{
        .file = b.path("tests/differential/btree_oracle_worker.c"),
        .flags = sqlite_c_flags,
    });
    if (target.result.os.tag != .windows) btree_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) btree_oracle_module.linkSystemLibrary("dl", .{});
    const btree_oracle = b.addExecutable(.{ .name = "sqlite3-btree-oracle", .root_module = btree_oracle_module });

    const btree_module = b.createModule(.{
        .root_source_file = b.path("src/core/btree.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    btree_module.addImport("build_profile", direct_build_profile);
    const btree_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/btree_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "btree", .module = btree_module }},
    });
    const btree_native = b.addExecutable(.{ .name = "sqlite3-btree-native", .root_module = btree_native_module });
    const btree_mutation_native_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/btree_mutation_native_worker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "btree", .module = btree_module }},
    });
    const btree_mutation_native = b.addExecutable(.{ .name = "sqlite3-btree-mutation-native", .root_module = btree_mutation_native_module });
    const install_btree_mutation_native = b.addInstallArtifact(btree_mutation_native, .{});
    b.step("btree-mutation-native", "Build the Phase 9 native mutation worker").dependOn(&install_btree_mutation_native.step);
    const btree_mutation_oracle_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    btree_mutation_oracle_module.addIncludePath(b.path("reference/c_oracle"));
    btree_mutation_oracle_module.addIncludePath(b.path("include"));
    btree_mutation_oracle_module.addCSourceFile(.{ .file = b.path("tests/differential/btree_mutation_oracle_worker.c"), .flags = sqlite_c_flags });
    if (target.result.os.tag != .windows) btree_mutation_oracle_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) btree_mutation_oracle_module.linkSystemLibrary("dl", .{});
    const btree_mutation_oracle = b.addExecutable(.{ .name = "sqlite3-btree-mutation-oracle", .root_module = btree_mutation_oracle_module });
    const btree_mutation_differential = boundedSystemCommand(b, &.{ "python3", "tools/btree_mutation_differential.py" });
    btree_mutation_differential.addArtifactArg(btree_mutation_oracle);
    btree_mutation_differential.addArtifactArg(btree_mutation_native);
    b.step("btree-mutation-differential", "Compare bounded B-tree mutation and continuation observations")
        .dependOn(&btree_mutation_differential.step);
    const generate_btree_mutation_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_btree_mutation_fixtures.py" });
    b.step("generate-btree-mutation-fixtures", "Regenerate the deterministic Phase 9 mutation corpus")
        .dependOn(&generate_btree_mutation_fixtures.step);
    const btree_differential = boundedSystemCommand(b, &.{ "python3", "tools/btree_differential.py" });
    btree_differential.addArtifactArg(btree_oracle);
    btree_differential.addArtifactArg(btree_native);
    b.step("btree-differential", "Compare read-only B-tree traversal, records, seeks, and overflow")
        .dependOn(&btree_differential.step);

    const btree_hybrid_bridge_module = b.createModule(.{
        .root_source_file = b.path("tests/differential/btree_hybrid_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "btree", .module = btree_module }},
    });
    const btree_hybrid_bridge = b.addObject(.{ .name = "sqlite3-btree-hybrid-bridge", .root_module = btree_hybrid_bridge_module });
    const btree_hybrid_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    btree_hybrid_module.addIncludePath(b.path("reference/c_oracle"));
    btree_hybrid_module.addIncludePath(b.path("include"));
    btree_hybrid_module.addCSourceFile(.{ .file = b.path("tests/differential/btree_hybrid_select.c"), .flags = sqlite_c_flags });
    btree_hybrid_module.addObject(btree_hybrid_bridge);
    if (target.result.os.tag != .windows) btree_hybrid_module.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) btree_hybrid_module.linkSystemLibrary("dl", .{});
    const btree_hybrid = b.addExecutable(.{ .name = "sqlite3-btree-hybrid-select", .root_module = btree_hybrid_module });
    const run_btree_hybrid = addRunStep(b, "btree-hybrid-select", "Run public SELECT through the Zig B-tree storage path", btree_hybrid);

    const generate_btree_fixtures = boundedSystemCommand(b, &.{ "python3", "tools/generate_btree_fixtures.py" });
    b.step("generate-btree-fixtures", "Regenerate the deterministic Phase 7 B-tree corpus")
        .dependOn(&generate_btree_fixtures.step);

    const parser_module = b.createModule(.{
        .root_source_file = b.path("tests/toolchain/parser_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    parser_module.addIncludePath(b.path("generated/parser"));
    parser_module.addCSourceFiles(.{
        .files = &.{
            "generated/parser/parser_probe.c",
            "tests/toolchain/parser_probe_runner.c",
        },
        .flags = &.{"-std=c99"},
    });
    const parser_probe = b.addExecutable(.{
        .name = "lemon-zig-action-probe",
        .root_module = parser_module,
    });
    const run_parser = addRunStep(
        b,
        "parser-spike",
        "Run the deterministic Lemon and Zig semantic-action probe",
        parser_probe,
    );

    const durability_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/durability_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_durability = boundedRunArtifact(b, durability_tests);
    b.step("durability-spike", "Run the bounded rollback durability probe")
        .dependOn(&run_durability.step);

    const generate_api = boundedSystemCommand(b, &.{ "python3", "tools/generate_api_manifest.py" });
    b.step("api-manifest", "Regenerate the pinned public API inventory")
        .dependOn(&generate_api.step);
    const generate_source_inventory = boundedSystemCommand(b, &.{ "python3", "tools/generate_source_inventory.py" });
    generate_source_inventory.addFileArg(b.path("reference/c_oracle/sqlite3-lines.c"));
    b.step("source-inventory", "Regenerate the canonical C source-entity inventory")
        .dependOn(&generate_source_inventory.step);

    const generate_source_dependencies = boundedSystemCommand(b, &.{ "python3", "tools/generate_source_dependencies.py" });
    b.step("source-dependencies", "Regenerate the active source-file dependency graph")
        .dependOn(&generate_source_dependencies.step);

    const verify_source_dependencies = boundedSystemCommand(b, &.{
        "python3", "tools/generate_source_dependencies.py", "--check",
    });
    b.step("source-dependencies-test", "Verify active source-file dependency graph")
        .dependOn(&verify_source_dependencies.step);

    const generate_zig_inventory = boundedSystemCommand(b, &.{ "python3", "tools/generate_zig_declaration_inventory.py" });
    b.step("zig-declaration-inventory", "Regenerate the AST-derived Zig declaration inventory")
        .dependOn(&generate_zig_inventory.step);

    const verify_zig_inventory = boundedSystemCommand(b, &.{
        "python3", "tools/generate_zig_declaration_inventory.py", "--check",
    });
    const generate_behavioral_inventory = boundedSystemCommand(b, &.{
        "python3", "tools/generate_behavioral_inventory.py",
    });
    b.step("behavioral-inventory", "Regenerate active control-flow and assertion block inventory")
        .dependOn(&generate_behavioral_inventory.step);
    const verify_behavioral_inventory = boundedSystemCommand(b, &.{
        "python3", "tools/generate_behavioral_inventory.py", "--check",
    });
    b.step("behavioral-inventory-test", "Verify active control-flow and assertion block inventory")
        .dependOn(&verify_behavioral_inventory.step);
    const verify_port_batch = boundedSystemCommand(b, &.{ "python3", "tools/verify_port_batch.py" });
    const port_batch_audit_step = b.step("port-batch-audit", "Validate active, historical, and checkpoint translation tracking");
    port_batch_audit_step.dependOn(&verify_port_batch.step);
    const promote_port_batch = boundedSystemCommand(b, &.{
        "python3", "tools/verify_port_batch.py", "--require-threshold",
    });
    const port_batch_checkpoint_step = b.step("port-batch-checkpoint", "Require a fully reconciled translation batch at its promotion threshold");
    port_batch_checkpoint_step.dependOn(&promote_port_batch.step);
    const test_port_batch = boundedSystemCommand(b, &.{ "python3", "tools/test_port_batch_gate.py" });
    const port_batch_gate_test_step = b.step("port-batch-gate-test", "Mutation-test translation tracking and promotion controls");
    port_batch_gate_test_step.dependOn(&test_port_batch.step);
    b.getInstallStep().dependOn(&verify_port_batch.step);

    const verify_source_ledger = boundedSystemCommand(b, &.{ "python3", "tools/verify_source_ledger.py" });
    verify_source_ledger.step.dependOn(&verify_port_batch.step);
    verify_source_ledger.step.dependOn(&verify_zig_inventory.step);
    verify_source_ledger.step.dependOn(&verify_source_dependencies.step);
    verify_source_ledger.step.dependOn(&verify_behavioral_inventory.step);
    const verify_atomic_units = boundedSystemCommand(b, &.{ "python3", "tools/verify_atomic_units.py" });
    verify_atomic_units.step.dependOn(&verify_source_ledger.step);
    promote_port_batch.step.dependOn(&verify_atomic_units.step);
    const atomic_unit_step = b.step("atomic-unit-audit", "Validate atomic-unit dossiers and evidence-state boundaries");
    atomic_unit_step.dependOn(&verify_atomic_units.step);
    const source_ledger_step = b.step("source-ledger", "Validate source classifications and Zig declaration targets");
    source_ledger_step.dependOn(&verify_source_ledger.step);

    const verify_opcode_coverage = boundedSystemCommand(b, &.{
        "python3", "tools/generate_vdbe_opcode_coverage.py", "--check",
    });
    const verify_parser_action_coverage = boundedSystemCommand(b, &.{
        "python3", "tools/generate_parser_action_coverage.py", "--check",
    });
    const verify_public_responsibilities = boundedSystemCommand(b, &.{
        "python3", "tools/generate_public_responsibility_inventory.py", "--check",
    });
    verify_public_responsibilities.step.dependOn(&verify_zig_inventory.step);
    const generate_public_responsibilities = boundedSystemCommand(b, &.{
        "python3", "tools/generate_public_responsibility_inventory.py",
    });
    b.step("public-responsibility-inventory", "Regenerate the Zig public responsibility inventory")
        .dependOn(&generate_public_responsibilities.step);
    b.step("public-responsibility-test", "Verify the Zig public responsibility inventory")
        .dependOn(&verify_public_responsibilities.step);
    const port_audit = boundedSystemCommand(b, &.{ "python3", "tools/port_audit.py" });
    port_audit.step.dependOn(&verify_source_ledger.step);
    port_audit.step.dependOn(&verify_opcode_coverage.step);
    port_audit.step.dependOn(&verify_parser_action_coverage.step);
    port_audit.step.dependOn(&verify_public_responsibilities.step);
    port_audit.step.dependOn(&verify_behavioral_inventory.step);
    port_audit.step.dependOn(&verify_atomic_units.step);
    const port_audit_step = b.step("port-audit", "Verify the honest whole-port status summary");
    port_audit_step.dependOn(&port_audit.step);

    const verify_config = boundedSystemCommand(b, &.{ "python3", "tools/verify_config.py" });
    verify_config.step.dependOn(&verify_port_batch.step);
    verify_config.step.dependOn(&port_audit.step);
    b.step("verify-config", "Verify pinned source, generated artifacts, profile, and port status")
        .dependOn(&verify_config.step);

    const verify_limits = boundedSystemCommand(b, &.{ "python3", "tools/verify_limits.py" });
    b.step("limits-test", "Verify native limits and features against the C profile")
        .dependOn(&verify_limits.step);

    const verify_exports = boundedSystemCommand(b, &.{ "python3", "tools/verify_exports.py" });
    verify_exports.step.dependOn(b.getInstallStep());
    b.step("verify-exports", "Inventory the transitional Zig-defined C-shaped exports")
        .dependOn(&verify_exports.step);

    const native_c_audit = boundedSystemCommand(b, &.{ "python3", "tools/native_c_audit.py" });
    native_c_audit.addFileArg(native_static.getEmittedBin());
    b.step("native-c-audit", "Require zero C objects in the production Zig library")
        .dependOn(&native_c_audit.step);

    const verify_abi_layout = boundedSystemCommand(b, &.{ "python3", "tools/verify_abi_layout.py" });
    b.step("abi-layout", "Verify target-native C ABI layout facts")
        .dependOn(&verify_abi_layout.step);

    const generate_parser_probe = boundedSystemCommand(b, &.{ "python3", "tools/generate_parser_probe.py" });
    b.step("generate-parser-probe", "Regenerate the test-only Lemon oracle bridge")
        .dependOn(&generate_parser_probe.step);

    const generate_parser = boundedSystemCommand(b, &.{ "python3", "tools/generate_sqlite_parser.py" });
    b.step("generate-parser", "Regenerate the pinned SQLite Lemon parser inventory")
        .dependOn(&generate_parser.step);

    const generate_parser_tables = boundedSystemCommand(b, &.{ "python3", "tools/generate_parser_tables.py" });
    b.step("generate-parser-tables", "Regenerate native Zig Lemon parser tables")
        .dependOn(&generate_parser_tables.step);
    const verify_parser_tables = boundedSystemCommand(b, &.{ "python3", "tools/generate_parser_tables.py", "--check" });
    b.step("parser-tables-test", "Verify native Zig Lemon tables and rule metadata")
        .dependOn(&verify_parser_tables.step);
    const generate_parser_action_coverage = boundedSystemCommand(b, &.{
        "python3", "tools/generate_parser_action_coverage.py",
    });
    b.step("generate-parser-action-coverage", "Regenerate Lemon typed action-contract scaffold ledger")
        .dependOn(&generate_parser_action_coverage.step);
    b.step("parser-action-coverage-test", "Verify Lemon typed action-contract scaffold ledger")
        .dependOn(&verify_parser_action_coverage.step);

    const generate_internal_vdbe_layout = boundedSystemCommand(b, &.{ "python3", "tools/generate_internal_vdbe_layout.py" });
    b.step("generate-internal-vdbe-layout", "Regenerate active C VDBE layout facts")
        .dependOn(&generate_internal_vdbe_layout.step);
    const verify_internal_vdbe_layout = boundedSystemCommand(b, &.{
        "python3", "tools/generate_internal_vdbe_layout.py", "--check",
    });
    const internal_vdbe_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/internal_vdbe_types_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    internal_vdbe_test_module.addImport("build_profile", direct_build_profile);
    const internal_vdbe_tests = b.addTest(.{ .root_module = internal_vdbe_test_module });
    const run_internal_vdbe_tests = boundedRunArtifact(b, internal_vdbe_tests);
    const internal_vdbe_layout_test = b.step(
        "internal-vdbe-layout-test",
        "Verify source-faithful active VDBE layouts",
    );
    internal_vdbe_layout_test.dependOn(&verify_internal_vdbe_layout.step);
    internal_vdbe_layout_test.dependOn(&run_internal_vdbe_tests.step);

    const generate_internal_parse_layout = boundedSystemCommand(b, &.{ "python3", "tools/generate_internal_parse_layout.py" });
    b.step("generate-internal-parse-layout", "Regenerate active C Parse/Expr/SrcList layout facts")
        .dependOn(&generate_internal_parse_layout.step);
    const verify_internal_parse_layout = boundedSystemCommand(b, &.{
        "python3", "tools/generate_internal_parse_layout.py", "--check",
    });
    const internal_parse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/internal_parse_types_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_internal_parse_tests = boundedRunArtifact(b, internal_parse_tests);
    const internal_parse_layout_test = b.step(
        "internal-parse-layout-test",
        "Verify source-faithful active Parse, Expr, and SrcList layouts",
    );
    internal_parse_layout_test.dependOn(&verify_internal_parse_layout.step);
    internal_parse_layout_test.dependOn(&run_internal_parse_tests.step);

    const generate_opcodes = boundedSystemCommand(b, &.{ "python3", "tools/generate_opcodes.py" });
    b.step("generate-opcodes", "Regenerate canonical SQLite opcode identities and properties")
        .dependOn(&generate_opcodes.step);
    const verify_opcodes = boundedSystemCommand(b, &.{ "python3", "tools/generate_opcodes.py", "--check" });
    b.step("opcodes-test", "Verify canonical opcode identities and properties")
        .dependOn(&verify_opcodes.step);
    const generate_opcode_coverage = boundedSystemCommand(b, &.{
        "python3", "tools/generate_vdbe_opcode_coverage.py",
    });
    b.step("generate-opcode-coverage", "Regenerate bounded VDBE name-mapping scaffold ledger")
        .dependOn(&generate_opcode_coverage.step);
    b.step("opcode-coverage-test", "Verify bounded VDBE name-mapping scaffold ledger")
        .dependOn(&verify_opcode_coverage.step);

    const verify_docs = boundedSystemCommand(b, &.{ "python3", "tools/verify_docs.py" });
    b.step("docs-test", "Verify maintained documentation and JSON manifests")
        .dependOn(&verify_docs.step);
    const verify_tooling = boundedSystemCommand(b, &.{ "python3", "tools/verify_tooling.py" });
    b.step("tooling-audit", "Verify every script purpose and bounded child execution")
        .dependOn(&verify_tooling.step);
    const ci_quick = boundedSystemCommandProfile(b, "build", &.{ "python3", "tools/ci_quick.py" });
    b.step("ci-quick", "Run formatting, three-mode regressions, artifact audit, and status report")
        .dependOn(&ci_quick.step);

    const upstream_tests = boundedSystemCommandProfile(b, "upstream", &.{ "python3", "tools/test_upstream.py" });
    b.step("test-upstream", "Build testfixture and run the pinned upstream test partition")
        .dependOn(&upstream_tests.step);

    const sanitized_oracle = boundedSystemCommandProfile(b, "sanitizer", &.{ "python3", "tools/test_oracle_sanitized.py" });
    b.step("oracle-sanitized", "Build and run the Clang ASan/UBSan oracle smoke test")
        .dependOn(&sanitized_oracle.step);

    const verify_upstream_step = b.step("verify-upstream", "Verify the pinned upstream source and generated artifacts");
    verify_upstream_step.dependOn(&verify_config.step);

    const fault_step = b.step("fault-test", "Run currently implemented bounded fault-model tests");
    fault_step.dependOn(&run_durability.step);
    const crash_step = b.step("crash-test", "Run currently implemented bounded crash-model tests");
    crash_step.dependOn(&run_durability.step);
    crash_step.dependOn(&run_rollback_trace.step);

    const test_step = b.step("test", "Run the current bounded regression gates (not full port completion)");
    test_step.dependOn(&run_native_tests.step);
    test_step.dependOn(&run_abi_client.step);
    test_step.dependOn(&differential_probe.step);
    test_step.dependOn(&bitvec_differential.step);
    test_step.dependOn(&bitvec_builtin_differential.step);
    test_step.dependOn(&hash_differential.step);
    test_step.dependOn(&varint_differential.step);
    test_step.dependOn(&byteorder_differential.step);
    test_step.dependOn(&string_differential.step);
    test_step.dependOn(&dequote_differential.step);
    test_step.dependOn(&utf_differential.step);
    test_step.dependOn(&random_differential.step);
    test_step.dependOn(&random_process_differential.step);
    test_step.dependOn(&numeric_differential.step);
    test_step.dependOn(&hex_blob_differential.step);
    test_step.dependOn(log_est_step);
    test_step.dependOn(checked_math_step);
    test_step.dependOn(vlist_step);
    test_step.dependOn(rowset_step);
    test_step.dependOn(benign_fault_step);
    test_step.dependOn(&float_decode_differential.step);
    test_step.dependOn(&formatter_metadata_differential.step);
    test_step.dependOn(&formatter_accumulator_differential.step);
    test_step.dependOn(&formatter_object_differential.step);
    test_step.dependOn(&formatter_rcstr_differential.step);
    test_step.dependOn(&formatter_render_differential.step);
    test_step.dependOn(&formatter_callers_differential.step);
    test_step.dependOn(error_offset_step);
    test_step.dependOn(vdbe_mem_differential_step);
    test_step.dependOn(vdbe_builder_step);
    test_step.dependOn(memory_journal_differential_step);
    test_step.dependOn(&utf16to8_differential.step);
    test_step.dependOn(&formatter_arguments_differential.step);
    test_step.dependOn(formatter_sql_step);
    test_step.dependOn(&infrastructure_differential.step);
    test_step.dependOn(&mutex_noop_differential.step);
    test_step.dependOn(&tokenizer_differential.step);
    test_step.dependOn(complete_step);
    test_step.dependOn(&parser_accept_differential.step);
    test_step.dependOn(&run_oracle_smoke.step);
    test_step.dependOn(&run_rollback_trace.step);
    test_step.dependOn(&run_variadic.step);
    test_step.dependOn(&run_hybrid.step);
    test_step.dependOn(&run_memory_vfs.step);
    test_step.dependOn(&vfs_trace_differential.step);
    test_step.dependOn(&pcache_differential.step);
    test_step.dependOn(&pager_differential.step);
    test_step.dependOn(&rollback_differential.step);
    test_step.dependOn(&btree_differential.step);
    test_step.dependOn(&btree_mutation_differential.step);
    test_step.dependOn(&wal_differential.step);
    test_step.dependOn(&run_wal_unix_hybrid.step);
    test_step.dependOn(&run_wal_unix_native.step);
    test_step.dependOn(&run_rollback_unix_native.step);
    test_step.dependOn(&run_unix_vfs_tests.step);
    test_step.dependOn(&vdbe_differential.step);
    test_step.dependOn(&run_statement_client.step);
    test_step.dependOn(&run_phase17_connection_client.step);
    test_step.dependOn(&sql_expression_differential.step);
    test_step.dependOn(&sql_schema_differential.step);
    test_step.dependOn(&sql_table_scan_differential.step);
    test_step.dependOn(&sql_insert_differential.step);
    test_step.dependOn(&sql_update_delete_differential.step);
    test_step.dependOn(&sql_index_join_differential.step);
    test_step.dependOn(&sql_advanced_differential.step);
    test_step.dependOn(&sql_planner_differential.step);
    test_step.dependOn(&sql_index_planner_differential.step);
    test_step.dependOn(&run_btree_hybrid.step);
    test_step.dependOn(&run_parser.step);
    test_step.dependOn(&run_durability.step);
    test_step.dependOn(&verify_config.step);
    test_step.dependOn(&test_port_batch.step);
    test_step.dependOn(&native_c_audit.step);
    test_step.dependOn(&verify_parser_tables.step);
    test_step.dependOn(&verify_parser_action_coverage.step);
    test_step.dependOn(internal_vdbe_layout_test);
    test_step.dependOn(internal_parse_layout_test);
    test_step.dependOn(&verify_opcodes.step);
    test_step.dependOn(&verify_opcode_coverage.step);
    test_step.dependOn(&verify_public_responsibilities.step);
    test_step.dependOn(&verify_limits.step);
    test_step.dependOn(&verify_abi_layout.step);
    test_step.dependOn(&verify_docs.step);
    test_step.dependOn(&verify_tooling.step);
    test_step.dependOn(&sanitized_oracle.step);
    promote_port_batch.step.dependOn(test_step);

    const report = boundedSystemCommand(b, &.{ "python3", "tools/compatibility_report.py" });
    report.step.dependOn(test_step);
    report.step.dependOn(&verify_exports.step);
    b.step("compatibility-report", "Run regressions and emit the honest incomplete-port report")
        .dependOn(&report.step);
}
