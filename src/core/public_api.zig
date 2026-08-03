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
pub const sqlite3_str = opaque {};
const LogCallback = *const fn (?*anyopaque, c_int, [*:0]const u8) callconv(.c) void;
var configured_log: ?LogCallback = null;
var configured_log_context: ?*anyopaque = null;

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
    return auto_extension.add(pointer);
}
pub export fn sqlite3_cancel_auto_extension(pointer: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    return auto_extension.cancel(pointer);
}
pub export fn sqlite3_reset_auto_extension() callconv(.c) void {
    auto_extension.reset();
}
extern "c" fn getrandom(*anyopaque, usize, c_uint) isize;
extern "c" fn usleep(c_uint) c_int;
var random_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

fn ensure() void {
    _ = global.initializeProcess();
}
pub export fn sqlite3_initialize() callconv(.c) c_int {
    return global.initializeProcess();
}
pub export fn sqlite3_shutdown() callconv(.c) c_int {
    return global.shutdownProcess();
}
pub export fn sqlite3_os_init() callconv(.c) c_int {
    return 0;
}
pub export fn sqlite3_os_end() callconv(.c) c_int {
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
pub export fn zig_sqlite3_config_log(callback: ?LogCallback, context: ?*anyopaque) callconv(.c) c_int {
    configured_log = callback;
    configured_log_context = context;
    return 0;
}
pub export fn zig_sqlite3_log_message(code: c_int, message: ?[*:0]const u8) callconv(.c) void {
    const callback = configured_log orelse return;
    callback(configured_log_context, code, message orelse return);
}

const TypedLogDispatch = struct {
    callback: LogCallback,
    context: ?*anyopaque,
};

fn dispatchTypedLog(context: ?*anyopaque, code: c_int, message: []const u8) void {
    const dispatch: *TypedLogDispatch = @ptrCast(@alignCast(context.?));
    dispatch.callback(dispatch.context, code, @ptrCast(message.ptr));
}

/// Zig-native typed sqlite3_log() responsibility.
pub fn logFormat(code: c_int, format: []const u8, arguments: []const formatter.FormatArgument) void {
    const callback = configured_log orelse return;
    ensure();
    var dispatch = TypedLogDispatch{ .callback = callback, .context = configured_log_context };
    formatter.renderLogMessage(&memory.process_manager, &dispatch, dispatchTypedLog, code, format, arguments);
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
    current.?.* = @intCast(std.math.clamp(now, std.math.minInt(c_int), std.math.maxInt(c_int)));
    highwater.?.* = @intCast(std.math.clamp(high, std.math.minInt(c_int), std.math.maxInt(c_int)));
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
pub export fn sqlite3_db_release_memory(database: ?*anyopaque) callconv(.c) c_int {
    return if (database != null) 0 else 21;
}
pub export fn sqlite3_enable_shared_cache(_: c_int) callconv(.c) c_int {
    return 0;
}
pub export fn sqlite3_global_recover() callconv(.c) c_int {
    return 0;
}
pub export fn sqlite3_thread_cleanup() callconv(.c) void {}
pub export fn sqlite3_memory_alarm(_: ?*const anyopaque, _: ?*anyopaque, _: i64) callconv(.c) c_int {
    return memory.memoryAlarm();
}
pub export fn sqlite3_sleep(milliseconds: c_int) callconv(.c) c_int {
    if (milliseconds <= 0) return 0;
    _ = usleep(@intCast(@as(i64, milliseconds) * 1000));
    return milliseconds;
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

const options = [_][*:0]const u8{ "THREADSAFE=1", "DEFAULT_PAGE_SIZE=4096", "DEFAULT_SYNCHRONOUS=2", "DEFAULT_WAL_SYNCHRONOUS=1", "MAX_VARIABLE_NUMBER=32766" };
pub export fn sqlite3_compileoption_get(index: c_int) callconv(.c) ?[*:0]const u8 {
    return if (index >= 0 and index < options.len) options[@intCast(index)] else null;
}
pub export fn sqlite3_compileoption_used(name_pointer: ?[*:0]const u8) callconv(.c) c_int {
    const name = if (name_pointer) |p| std.mem.span(p) else return 0;
    const stripped = if (std.ascii.startsWithIgnoreCase(name, "SQLITE_")) name[7..] else name;
    for (options) |option| {
        const text = std.mem.span(option);
        const base = text[0..(std.mem.indexOfScalar(u8, text, '=') orelse text.len)];
        if (std.ascii.eqlIgnoreCase(base, stripped)) return 1;
    }
    return 0;
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
fn wildcard(pattern: []const u8, text: []const u8, many: u8, one: u8, fold: bool) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == one or (if (fold) std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t]) else pattern[p] == text[t]))) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == many) {
            star = p;
            p += 1;
            retry = t;
        } else if (star != null) {
            p = star.? + 1;
            retry += 1;
            t = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == many) p += 1;
    return p == pattern.len;
}
pub export fn sqlite3_strglob(pattern: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) c_int {
    return if (pattern != null and text != null and wildcard(std.mem.span(pattern.?), std.mem.span(text.?), '*', '?', false)) 0 else 1;
}
pub export fn sqlite3_strlike(pattern: ?[*:0]const u8, text: ?[*:0]const u8, escape: c_uint) callconv(.c) c_int {
    _ = escape;
    return if (pattern != null and text != null and wildcard(std.mem.span(pattern.?), std.mem.span(text.?), '%', '_', true)) 0 else 1;
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
    if (filename == null or key == null) return null;
    const value = uriValue(std.mem.span(filename.?), std.mem.span(key.?)) orelse return null;
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
pub export fn sqlite3_uri_key(filename: ?[*:0]const u8, index: c_int) callconv(.c) ?[*:0]const u8 {
    if (filename == null or index < 0) return null;
    const text = std.mem.span(filename.?);
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
pub export fn sqlite3_uri_int64(filename: ?[*:0]const u8, key: ?[*:0]const u8, default_value: i64) callconv(.c) i64 {
    const p = sqlite3_uri_parameter(filename, key) orelse return default_value;
    return std.fmt.parseInt(i64, std.mem.span(p), 10) catch default_value;
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
    return filenameWithSuffix(filename, "");
}
pub export fn sqlite3_filename_journal(filename: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return filenameWithSuffix(filename, "-journal");
}
pub export fn sqlite3_filename_wal(filename: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return filenameWithSuffix(filename, "-wal");
}
pub export fn sqlite3_create_filename(database: ?[*:0]const u8, journal: ?[*:0]const u8, wal: ?[*:0]const u8, parameter_count: c_int, parameters: ?[*]?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    _ = journal;
    _ = wal;
    const base = if (database) |value| std.mem.span(value) else return null;
    if (parameter_count < 0 or (parameter_count > 0 and parameters == null)) return null;
    var total = base.len;
    for (0..@intCast(parameter_count * 2)) |index| total += if (parameters.?[index]) |value| std.mem.len(value) else 0;
    if (parameter_count > 0) total += @intCast(parameter_count * 2);
    const allocation = sqlite3_malloc64(total + 1) orelse return null;
    const output: [*]u8 = @ptrCast(allocation);
    var position: usize = 0;
    @memcpy(output[position..][0..base.len], base);
    position += base.len;
    for (0..@intCast(parameter_count)) |index| {
        output[position] = if (index == 0) '?' else '&';
        position += 1;
        const key = if (parameters.?[index * 2]) |value| std.mem.span(value) else "";
        @memcpy(output[position..][0..key.len], key);
        position += key.len;
        output[position] = '=';
        position += 1;
        const value = if (parameters.?[index * 2 + 1]) |item| std.mem.span(item) else "";
        @memcpy(output[position..][0..value.len], value);
        position += value.len;
    }
    output[position] = 0;
    return @ptrCast(output);
}
pub export fn sqlite3_free_filename(filename: ?[*:0]u8) callconv(.c) void {
    sqlite3_free(if (filename) |value| @ptrCast(value) else null);
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
    if (global.initializeProcess() != 0) return null;
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
