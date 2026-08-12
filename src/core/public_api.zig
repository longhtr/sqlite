//! Transitional C-shaped process utility, allocation, keyword, URI, and string APIs.
//! These bounded exports are migration evidence; the target public surface is Zig-native.
const std = @import("std");
const memory = @import("memory.zig");
const formatter = @import("formatter.zig");
const sqlite_random = @import("random.zig");
const keywords = @import("generated/keywords.zig");
const vfs = @import("vfs.zig");
const mutex = @import("mutex.zig");
const global = @import("global.zig");
const auto_extension = @import("auto_extension.zig");
const logging = @import("logging.zig");
const function_registry = @import("internal/function_registry.zig");
const pattern_match = @import("internal/pattern.zig");
const numeric = @import("numeric.zig");
const config_types = @import("internal/config_types.zig");
pub const sqlite3_str = opaque {};
const LogCallback = logging.Callback;

var configured_memory_methods: memory.MethodsBackend = undefined;

pub export fn zig_sqlite3_set_extension_api(pointer: ?*const anyopaque) callconv(.c) void {
    auto_extension.setApi(pointer);
}
pub fn extensionApi() ?*const anyopaque {
    return auto_extension.api();
}
pub fn runAutoExtensions(database: ?*anyopaque) c_int {
    return auto_extension.run(database);
}
pub export fn sqlite3_auto_extension(pointer: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    const rc = initializeProcess();
    if (rc != 0) return rc;
    return auto_extension.add(pointer);
}
pub export fn sqlite3_cancel_auto_extension(pointer: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    return auto_extension.cancel(pointer);
}
pub export fn sqlite3_reset_auto_extension() callconv(.c) void {
    auto_extension.reset();
}
extern "c" fn getrandom(*anyopaque, usize, c_uint) isize;
var random_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

fn initializeProcess() c_int {
    return global.initializeProcessWithBuiltins(&function_registry.resetAndRegisterPortedBuiltinFunctions);
}
fn ensure() void {
    _ = initializeProcess();
}
pub export fn sqlite3_initialize() callconv(.c) c_int {
    return initializeProcess();
}
pub export fn sqlite3_shutdown() callconv(.c) c_int {
    return global.shutdownProcess();
}
pub export fn sqlite3_os_init() callconv(.c) c_int {
    return global.initializeOs();
}
pub export fn sqlite3_os_end() callconv(.c) c_int {
    global.shutdownOs();
    return 0;
}
pub export fn zig_sqlite3_is_initialized() callconv(.c) c_int {
    return @intFromBool(memory.process_manager.started);
}
pub export fn zig_sqlite3_test_control_no_args(operation: c_int) callconv(.c) c_int {
    return switch (operation) {
        22 => 1234,
        23 => @intFromBool(memory.process_manager.started),
        else => 0,
    };
}
pub export fn zig_sqlite3_test_control_int(operation: c_int, value: c_int) callconv(.c) c_int {
    return switch (operation) {
        12, 13 => value,
        else => 0,
    };
}
pub export fn zig_sqlite3_config_no_args(operation: c_int) callconv(.c) c_int {
    const mode: mutex.Mode = switch (operation) {
        1 => .single_thread,
        2 => .multi_thread,
        3 => .serialized,
        else => return 1,
    };
    global.process_coordinator.configureMode(mode) catch return 21;
    return 0;
}
pub export fn zig_sqlite3_config_memstatus(enabled: c_int) callconv(.c) c_int {
    global.process_coordinator.configureMemoryStatus(enabled != 0) catch return 21;
    return 0;
}
pub export fn zig_sqlite3_config_malloc(methods: ?*const memory.MemMethods) callconv(.c) c_int {
    configured_memory_methods = memory.MethodsBackend.init(if (methods) |value| value.* else return 21);
    global.process_coordinator.configureBackend(configured_memory_methods.backend()) catch return 21;
    return 0;
}
pub export fn zig_sqlite3_config_log(callback: ?LogCallback, context: ?*anyopaque) callconv(.c) c_int {
    logging.configure(callback, context);
    return 0;
}
pub export fn zig_sqlite3_log_message(code: c_int, message: ?[*:0]const u8) callconv(.c) void {
    logging.message(code, message);
}

/// Zig-native typed sqlite3_log() responsibility.
pub fn logFormat(code: c_int, format: []const u8, arguments: []const formatter.FormatArgument) void {
    ensure();
    logging.format(code, format, arguments);
}

pub export fn sqlite3_malloc(n: c_int) callconv(.c) ?*anyopaque {
    if (n <= 0) return null;
    ensure();
    return memory.process_manager.alloc(@intCast(n));
}
pub export fn sqlite3_malloc64(n: u64) callconv(.c) ?*anyopaque {
    ensure();
    return memory.process_manager.alloc(n);
}
pub export fn sqlite3_realloc(p: ?*anyopaque, n: c_int) callconv(.c) ?*anyopaque {
    ensure();
    return memory.process_manager.realloc(p, if (n < 0) memory.max_allocation_size + 1 else @intCast(n));
}
pub export fn sqlite3_realloc64(p: ?*anyopaque, n: u64) callconv(.c) ?*anyopaque {
    ensure();
    return memory.process_manager.realloc(p, n);
}
pub export fn sqlite3_free(p: ?*anyopaque) callconv(.c) void {
    ensure();
    memory.process_manager.free(p);
}
pub export fn sqlite3_msize(p: ?*anyopaque) callconv(.c) u64 {
    return if (p) |q| memory.process_manager.size(q) else 0;
}
pub export fn sqlite3_memory_used() callconv(.c) i64 {
    ensure();
    return memory.process_manager.status(.memory_used, false).current;
}
pub export fn sqlite3_memory_highwater(reset: c_int) callconv(.c) i64 {
    ensure();
    return memory.process_manager.status(.memory_used, reset != 0).highwater;
}
pub export fn sqlite3_status64(operation: c_int, current: ?*i64, highwater: ?*i64, reset: c_int) callconv(.c) c_int {
    if (current == null or highwater == null or operation < 0 or operation > 9) return 21;
    ensure();
    const value = memory.process_manager.status(@enumFromInt(operation), reset != 0);
    current.?.* = value.current;
    highwater.?.* = value.highwater;
    return 0;
}
pub export fn sqlite3_status(operation: c_int, current: ?*c_int, highwater: ?*c_int, reset: c_int) callconv(.c) c_int {
    var now: i64 = 0;
    var high: i64 = 0;
    const rc = sqlite3_status64(operation, &now, &high, reset);
    if (rc != 0 or current == null or highwater == null) return if (rc != 0) rc else 21;
    current.?.* = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(now)))));
    highwater.?.* = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(high)))));
    return 0;
}
pub export fn sqlite3_soft_heap_limit64(n: i64) callconv(.c) i64 {
    ensure();
    return memory.process_manager.setSoftLimit(n);
}
pub export fn sqlite3_hard_heap_limit64(n: i64) callconv(.c) i64 {
    ensure();
    return memory.process_manager.setHardLimit(n);
}
pub export fn sqlite3_soft_heap_limit(n: c_int) callconv(.c) void {
    _ = sqlite3_soft_heap_limit64(n);
}
pub export fn sqlite3_release_memory(n: c_int) callconv(.c) c_int {
    return memory.releaseMemory(n);
}
pub export fn sqlite3_enable_shared_cache(enable: c_int) callconv(.c) c_int {
    config_types.global_config.sharedCacheEnabled = enable;
    return 0;
}
test "shared-cache enable stores the exact process setting" {
    const original = config_types.global_config.sharedCacheEnabled;
    defer config_types.global_config.sharedCacheEnabled = original;
    try std.testing.expectEqual(@as(c_int, 0), sqlite3_enable_shared_cache(7));
    try std.testing.expectEqual(@as(c_int, 7), config_types.global_config.sharedCacheEnabled);
}
pub export fn sqlite3_global_recover() callconv(.c) c_int {
    return 0;
}
pub export fn sqlite3_thread_cleanup() callconv(.c) void {}
pub export fn sqlite3_memory_alarm(_: ?*const anyopaque, _: ?*anyopaque, _: i64) callconv(.c) c_int {
    return memory.memoryAlarm();
}
/// Source `sqlite3_sleep()`: route millisecond sleeps through the active VFS
/// microsecond callback and return its measured duration in milliseconds.
fn sleepMilliseconds(milliseconds: c_int) c_int {
    const process_vfs = vfs.findProcessVfs(null) orelse return 0;
    const sleep = process_vfs.xSleep orelse return 0;
    const bounded = @max(milliseconds, 0);
    const microseconds = std.math.mul(c_int, bounded, 1000) catch std.math.maxInt(c_int);
    return @divTrunc(sleep(process_vfs, microseconds), 1000);
}

pub export fn sqlite3_sleep(milliseconds: c_int) callconv(.c) c_int {
    return sleepMilliseconds(milliseconds);
}
pub export fn sqlite3_randomness(n: c_int, output: ?*anyopaque) callconv(.c) void {
    ensure();
    std.debug.assert(std.c.pthread_mutex_lock(&random_lock) == .SUCCESS);
    defer std.debug.assert(std.c.pthread_mutex_unlock(&random_lock) == .SUCCESS);
    if (n <= 0 or output == null) {
        sqlite_random.process_state.reset();
        return;
    }
    var entropy = [_]u8{0} ** 44;
    if (!sqlite_random.process_state.isInitialized()) {
        const count = getrandom(&entropy, entropy.len, 0);
        if (count < 0) @memset(&entropy, 0);
    }
    sqlite_random.process_state.fill(@as([*]u8, @ptrCast(output.?))[0..@intCast(n)], &entropy);
}

const options = [_][*:0]const u8{
    "THREADSAFE=1",
    "DEFAULT_PAGE_SIZE=4096",
    "DEFAULT_SYNCHRONOUS=2",
    "DEFAULT_WAL_SYNCHRONOUS=2",
    "ENABLE_MATH_FUNCTIONS",
    "ENABLE_PERCENTILE",
    "HAVE_ZLIB",
    "MAX_LENGTH=1000000000",
    "MAX_SQL_LENGTH=1000000000",
    "MAX_COLUMN=2000",
    "MAX_EXPR_DEPTH=1000",
    "MAX_COMPOUND_SELECT=500",
    "MAX_VDBE_OP=250000000",
    "MAX_FUNCTION_ARG=1000",
    "MAX_ATTACHED=10",
    "MAX_LIKE_PATTERN_LENGTH=50000",
    "MAX_VARIABLE_NUMBER=32766",
    "MAX_TRIGGER_DEPTH=1000",
    "MAX_WORKER_THREADS=8",
    "MAX_PARSER_DEPTH=2500",
};
pub export fn sqlite3_compileoption_get(index: c_int) callconv(.c) ?[*:0]const u8 {
    return if (index >= 0 and index < options.len) options[@intCast(index)] else null;
}
/// Source `sqlite3_compileoption_used()`: match the pinned option table with
/// optional SQLITE_ prefix and stop only at a non-identifier boundary.
fn compileOptionUsed(name_pointer: ?[*:0]const u8) c_int {
    const name = if (name_pointer) |pointer| std.mem.span(pointer) else return 0;
    const sought = if (std.ascii.startsWithIgnoreCase(name, "SQLITE_")) name[7..] else name;
    for (options) |option| {
        const candidate = std.mem.span(option);
        if (sought.len > candidate.len or !std.ascii.eqlIgnoreCase(sought, candidate[0..sought.len])) continue;
        if (sought.len == candidate.len or !(std.ascii.isAlphanumeric(candidate[sought.len]) or candidate[sought.len] == '_')) return 1;
    }
    return 0;
}

pub export fn sqlite3_compileoption_used(name_pointer: ?[*:0]const u8) callconv(.c) c_int {
    return compileOptionUsed(name_pointer);
}

pub export fn sqlite3_keyword_count() callconv(.c) c_int {
    return keywords.entries.len;
}
pub export fn sqlite3_keyword_name(index: c_int, name_out: ?*?[*]const u8, length_out: ?*c_int) callconv(.c) c_int {
    if (index < 0 or index >= keywords.entries.len or name_out == null or length_out == null) return 1;
    const name = keywords.entries[@intCast(index)].name;
    name_out.?.* = name.ptr;
    length_out.?.* = @intCast(name.len);
    return 0;
}
pub export fn sqlite3_keyword_check(pointer: ?[*]const u8, length: c_int) callconv(.c) c_int {
    if (pointer == null or length < 0) return 0;
    const word = pointer.?[0..@intCast(length)];
    for (keywords.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.name, word)) return 1;
    return 0;
}

pub export fn sqlite3_stricmp(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) c_int {
    return compare(if (a) |p| std.mem.span(p) else "", if (b) |p| std.mem.span(p) else "", null);
}
pub export fn sqlite3_strnicmp(a: ?[*:0]const u8, b: ?[*:0]const u8, n: c_int) callconv(.c) c_int {
    return compare(if (a) |p| std.mem.span(p) else "", if (b) |p| std.mem.span(p) else "", if (n < 0) 0 else @intCast(n));
}
fn compare(a: []const u8, b: []const u8, limit: ?usize) c_int {
    const n = @min(@min(a.len, b.len), limit orelse std.math.maxInt(usize));
    for (0..n) |i| {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y) return @as(c_int, x) - @as(c_int, y);
    }
    if (limit != null and n == limit.?) return 0;
    return if (a.len < b.len) -1 else if (a.len > b.len) 1 else 0;
}
pub export fn sqlite3_strglob(pattern: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) c_int {
    return pattern_match.stringGlob(pattern, text);
}
pub export fn sqlite3_strlike(pattern: ?[*:0]const u8, text: ?[*:0]const u8, escape: c_uint) callconv(.c) c_int {
    return pattern_match.stringLike(pattern, text, escape);
}

const CreatedFilename = struct {
    database: [*:0]u8,
    allocation: *anyopaque,
    allocation_end: [*]u8,
};
const CreatedLayout = struct { parameters: [*:0]u8, journal: [*:0]u8, wal: [*:0]u8 };
var created_filenames: [64]?CreatedFilename = [_]?CreatedFilename{null} ** 64;
var filename_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

fn createdFilename(pointer: [*:0]const u8) ?CreatedFilename {
    std.debug.assert(std.c.pthread_mutex_lock(&filename_lock) == .SUCCESS);
    defer std.debug.assert(std.c.pthread_mutex_unlock(&filename_lock) == .SUCCESS);
    for (created_filenames) |record| {
        const present = record orelse continue;
        if (@intFromPtr(present.database) == @intFromPtr(pointer)) return present;
    }
    return null;
}

fn registerCreatedFilename(record: CreatedFilename) bool {
    std.debug.assert(std.c.pthread_mutex_lock(&filename_lock) == .SUCCESS);
    defer std.debug.assert(std.c.pthread_mutex_unlock(&filename_lock) == .SUCCESS);
    for (&created_filenames) |*slot| {
        if (slot.* == null) {
            slot.* = record;
            return true;
        }
    }
    return false;
}

fn createdFilenameLayout(pointer: [*:0]const u8) ?CreatedLayout {
    const record = createdFilename(pointer) orelse return null;
    var next: [*:0]u8 = record.database + std.mem.len(record.database) + 1;
    while (next[0] != 0) {
        next += std.mem.len(next) + 1;
        next += std.mem.len(next) + 1;
    }
    const journal: [*:0]u8 = next + 1;
    const wal: [*:0]u8 = journal + std.mem.len(journal) + 1;
    if (@intFromPtr(wal) >= @intFromPtr(record.allocation_end)) return null;
    return .{ .parameters = record.database + std.mem.len(record.database) + 1, .journal = journal, .wal = wal };
}

fn uriValue(filename: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, filename, '?') orelse return null;
    var it = std.mem.splitScalar(u8, filename[q + 1 ..], '&');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        if (std.mem.eql(u8, part[0..eq], key)) return if (eq < part.len) part[eq + 1 ..] else "";
    }
    return null;
}
threadlocal var uri_buffer: [1024]u8 = undefined;
pub export fn sqlite3_uri_parameter(filename: ?[*:0]const u8, key: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const filename_pointer = filename orelse return null;
    const key_pointer = key orelse return null;
    if (createdFilenameLayout(filename_pointer)) |layout| {
        var parameter = layout.parameters;
        while (parameter[0] != 0) {
            const value = parameter + std.mem.len(parameter) + 1;
            if (std.mem.eql(u8, std.mem.span(parameter), std.mem.span(key_pointer))) return value;
            parameter = value + std.mem.len(value) + 1;
        }
        return null;
    }
    const value = uriValue(std.mem.span(filename_pointer), std.mem.span(key_pointer)) orelse return null;
    if (value.len >= uri_buffer.len) return null;
    var source: usize = 0;
    var target: usize = 0;
    while (source < value.len) {
        if (value[source] == '%' and source + 2 < value.len) {
            uri_buffer[target] = std.fmt.parseInt(u8, value[source + 1 .. source + 3], 16) catch return null;
            source += 3;
        } else {
            uri_buffer[target] = value[source];
            source += 1;
        }
        target += 1;
    }
    uri_buffer[target] = 0;
    return @ptrCast(&uri_buffer);
}

/// Source `sqlite3_uri_key()`: walk encoded key/value pairs or a plain URI
/// and return the requested key without decoding its value.
pub export fn sqlite3_uri_key(filename: ?[*:0]const u8, index: c_int) callconv(.c) ?[*:0]const u8 {
    const filename_pointer = filename orelse return null;
    if (index < 0) return null;
    if (createdFilenameLayout(filename_pointer)) |layout| {
        var parameter = layout.parameters;
        var current: c_int = 0;
        while (parameter[0] != 0) {
            if (current == index) return parameter;
            const value = parameter + std.mem.len(parameter) + 1;
            parameter = value + std.mem.len(value) + 1;
            current += 1;
        }
        return null;
    }
    const text = std.mem.span(filename_pointer);
    const question = std.mem.indexOfScalar(u8, text, '?') orelse return null;
    var iterator = std.mem.splitScalar(u8, text[question + 1 ..], '&');
    var current: c_int = 0;
    while (iterator.next()) |part| {
        if (current == index) {
            const end = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
            if (end >= uri_buffer.len) return null;
            @memcpy(uri_buffer[0..end], part[0..end]);
            uri_buffer[end] = 0;
            return @ptrCast(&uri_buffer);
        }
        current += 1;
    }
    return null;
}

pub export fn sqlite3_uri_boolean(filename: ?[*:0]const u8, key: ?[*:0]const u8, default_value: c_int) callconv(.c) c_int {
    const p = sqlite3_uri_parameter(filename, key) orelse return default_value;
    const v = std.mem.span(p);
    if (std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "1")) return 1;
    if (std.ascii.eqlIgnoreCase(v, "no") or std.ascii.eqlIgnoreCase(v, "false") or std.mem.eql(u8, v, "0")) return 0;
    return default_value;
}

/// Source `sqlite3_uri_int64()`: accept SQLite decimal and hexadecimal integer
/// syntax and preserve the caller default for absent or malformed values.
pub export fn sqlite3_uri_int64(filename: ?[*:0]const u8, key: ?[*:0]const u8, default_value: i64) callconv(.c) i64 {
    const value = sqlite3_uri_parameter(filename, key) orelse return default_value;
    const parsed = numeric.parseDecimalOrHex(value);
    return if (parsed.code == 0) parsed.value else default_value;
}

threadlocal var filename_buffer: [4096]u8 = undefined;
fn filenameWithSuffix(filename: ?[*:0]const u8, suffix: []const u8) ?[*:0]const u8 {
    const input = if (filename) |value| std.mem.span(value) else return null;
    var base: []const u8 = input;
    if (std.mem.endsWith(u8, base, "-journal")) base = base[0 .. base.len - 8] else if (std.mem.endsWith(u8, base, "-wal")) base = base[0 .. base.len - 4];
    if (base.len + suffix.len >= filename_buffer.len) return null;
    @memcpy(filename_buffer[0..base.len], base);
    @memcpy(filename_buffer[base.len..][0..suffix.len], suffix);
    filename_buffer[base.len + suffix.len] = 0;
    return @ptrCast(&filename_buffer);
}
pub export fn sqlite3_filename_database(filename: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const pointer = filename orelse return null;
    return if (createdFilename(pointer) != null) pointer else filenameWithSuffix(pointer, "");
}

/// Source `sqlite3_filename_journal()`: locate the journal name embedded after
/// the encoded URI key/value list produced by `sqlite3_create_filename()`.
pub export fn sqlite3_filename_journal(filename: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const pointer = filename orelse return null;
    return if (createdFilenameLayout(pointer)) |layout| layout.journal else filenameWithSuffix(pointer, "-journal");
}

/// Source `sqlite3_filename_wal()`: locate the WAL name following the journal
/// name in the source-compatible encoded filename allocation.
pub export fn sqlite3_filename_wal(filename: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const pointer = filename orelse return null;
    return if (createdFilenameLayout(pointer)) |layout| layout.wal else filenameWithSuffix(pointer, "-wal");
}

fn appendFilenameText(output: [*]u8, position: *usize, text: []const u8) void {
    @memcpy(output[position.*..][0..text.len], text);
    position.* += text.len;
    output[position.*] = 0;
    position.* += 1;
}

/// Source `sqlite3_create_filename()`: allocate the pager-compatible database,
/// URI pair, journal, and WAL string layout with the required sentinels.
pub export fn sqlite3_create_filename(database: ?[*:0]const u8, journal: ?[*:0]const u8, wal: ?[*:0]const u8, parameter_count: c_int, parameters: ?[*]?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const database_text = if (database) |value| std.mem.span(value) else return null;
    const journal_text = if (journal) |value| std.mem.span(value) else return null;
    const wal_text = if (wal) |value| std.mem.span(value) else return null;
    if (parameter_count < 0 or (parameter_count > 0 and parameters == null)) return null;
    const count: usize = @intCast(parameter_count);
    const item_count = std.math.mul(usize, count, 2) catch return null;
    var total: usize = 10;
    total = std.math.add(usize, total, database_text.len) catch return null;
    total = std.math.add(usize, total, journal_text.len) catch return null;
    total = std.math.add(usize, total, wal_text.len) catch return null;
    for (0..item_count) |index| {
        const length = if (parameters.?[index]) |value| std.mem.len(value) else 0;
        const terminated_length = std.math.add(usize, length, 1) catch return null;
        total = std.math.add(usize, total, terminated_length) catch return null;
    }
    const allocation = sqlite3_malloc64(total) orelse return null;
    const output: [*]u8 = @ptrCast(allocation);
    @memset(output[0..total], 0);
    var position: usize = 4;
    appendFilenameText(output, &position, database_text);
    for (0..item_count) |index| {
        appendFilenameText(output, &position, if (parameters.?[index]) |value| std.mem.span(value) else "");
    }
    position += 1;
    appendFilenameText(output, &position, journal_text);
    appendFilenameText(output, &position, wal_text);
    position += 2;
    std.debug.assert(position == total);
    const result: [*:0]u8 = @ptrCast(output + 4);
    if (!registerCreatedFilename(.{ .database = result, .allocation = allocation, .allocation_end = output + total })) {
        sqlite3_free(allocation);
        return null;
    }
    return result;
}

pub export fn sqlite3_free_filename(filename: ?[*:0]u8) callconv(.c) void {
    const pointer = filename orelse return;
    var allocation: ?*anyopaque = null;
    std.debug.assert(std.c.pthread_mutex_lock(&filename_lock) == .SUCCESS);
    for (&created_filenames) |*slot| {
        if (slot.*) |record| {
            if (@intFromPtr(record.database) == @intFromPtr(pointer)) {
                allocation = record.allocation;
                slot.* = null;
                break;
            }
        }
    }
    std.debug.assert(std.c.pthread_mutex_unlock(&filename_lock) == .SUCCESS);
    sqlite3_free(allocation orelse @ptrCast(pointer));
}
pub export fn sqlite3_database_file_object(_: ?[*:0]const u8) callconv(.c) ?*vfs.sqlite3_file {
    return null;
}

fn asString(pointer: ?*sqlite3_str) ?*formatter.Accumulator {
    return if (pointer) |value| @ptrCast(@alignCast(value)) else null;
}
pub export fn sqlite3_str_new(database: ?*anyopaque) callconv(.c) ?*sqlite3_str {
    ensure();
    return @ptrCast(formatter.stringObjectNew(&memory.process_manager, database, 1_000_000_000));
}
pub export fn sqlite3_str_append(pointer: ?*sqlite3_str, input: ?[*]const u8, length: c_int) callconv(.c) void {
    const accumulator = asString(pointer) orelse return;
    if (input == null or length < 0) return;
    formatter.strAppend(accumulator, &memory.process_manager, input.?[0..@intCast(length)]);
}
pub export fn sqlite3_str_appendall(pointer: ?*sqlite3_str, input: ?[*:0]const u8) callconv(.c) void {
    const accumulator = asString(pointer) orelse return;
    if (input) |text| formatter.strAppendAll(accumulator, &memory.process_manager, std.mem.span(text));
}
pub export fn sqlite3_str_appendchar(pointer: ?*sqlite3_str, count: c_int, character: u8) callconv(.c) void {
    const accumulator = asString(pointer) orelse return;
    formatter.strAppendChar(accumulator, &memory.process_manager, count, character);
}
pub export fn sqlite3_str_reset(pointer: ?*sqlite3_str) callconv(.c) void {
    const accumulator = asString(pointer) orelse return;
    formatter.strReset(accumulator, &memory.process_manager);
}
pub export fn sqlite3_str_truncate(pointer: ?*sqlite3_str, length: c_int) callconv(.c) void {
    const accumulator = asString(pointer) orelse return;
    formatter.strTruncate(accumulator, length);
}
pub export fn sqlite3_str_errcode(pointer: ?*sqlite3_str) callconv(.c) c_int {
    return formatter.strErrorCode(asString(pointer));
}
pub export fn sqlite3_str_length(pointer: ?*sqlite3_str) callconv(.c) c_int {
    return formatter.strLength(asString(pointer));
}
pub export fn sqlite3_str_value(pointer: ?*sqlite3_str) callconv(.c) ?[*:0]const u8 {
    return formatter.strValue(asString(pointer));
}
pub export fn sqlite3_str_finish(pointer: ?*sqlite3_str) callconv(.c) ?[*:0]u8 {
    return formatter.stringObjectFinish(&memory.process_manager, asString(pointer));
}
pub export fn sqlite3_str_free(pointer: ?*sqlite3_str) callconv(.c) void {
    formatter.stringObjectFree(&memory.process_manager, asString(pointer));
}

pub export fn sqlite3_vfs_find(name_pointer: ?[*:0]const u8) callconv(.c) ?*vfs.sqlite3_vfs {
    return vfs.findProcessVfs(if (name_pointer) |name| std.mem.span(name) else null);
}
pub export fn sqlite3_vfs_register(item: ?*vfs.sqlite3_vfs, make_default: c_int) callconv(.c) c_int {
    const value = item orelse return 21;
    vfs.registerProcessVfs(value, make_default != 0);
    return 0;
}
pub export fn sqlite3_vfs_unregister(item: ?*vfs.sqlite3_vfs) callconv(.c) c_int {
    const value = item orelse return 21;
    vfs.unregisterProcessVfs(value);
    return 0;
}

pub export fn sqlite3_mutex_alloc(kind_value: c_int) callconv(.c) ?*anyopaque {
    if (kind_value < 0 or kind_value > 13) return null;
    if (initializeProcess() != 0) return null;
    return global.process_mutex_subsystem.allocOpaque(@enumFromInt(kind_value));
}
pub export fn sqlite3_mutex_free(pointer: ?*anyopaque) callconv(.c) void {
    global.process_mutex_subsystem.freeOpaque(pointer);
}
pub export fn sqlite3_mutex_enter(pointer: ?*anyopaque) callconv(.c) void {
    global.process_mutex_subsystem.enterOpaque(pointer);
}
pub export fn sqlite3_mutex_try(pointer: ?*anyopaque) callconv(.c) c_int {
    return global.process_mutex_subsystem.tryOpaque(pointer);
}
pub export fn sqlite3_mutex_leave(pointer: ?*anyopaque) callconv(.c) void {
    global.process_mutex_subsystem.leaveOpaque(pointer);
}
pub export fn sqlite3_mutex_held(pointer: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(global.process_mutex_subsystem.heldOpaque(pointer));
}
pub export fn sqlite3_mutex_notheld(pointer: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(global.process_mutex_subsystem.notHeldOpaque(pointer));
}

comptime {
    _ = vfs.OK;
}
