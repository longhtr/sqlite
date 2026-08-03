//! Bounded handwritten SQL frontend and planner slices.
//! This is transitional and must be replaced by the generated Lemon actions and full compiler/planner.
//! Rowid predicates, ordering, and limits lower to native cursor programs.

const std = @import("std");
pub const global = @import("global.zig");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const tokenizer = @import("tokenizer.zig");
const complete = @import("complete.zig");
const tokens = tokenizer.token;
const vdbe = @import("vdbe.zig");
pub const btree = @import("btree.zig");
const unix_vfs = @import("unix_vfs.zig");
const public_api = @import("public_api.zig");
const mutex = @import("mutex.zig");
pub const statement = @import("statement.zig");
const ResultCode = @import("result_code.zig").ResultCode;

extern "c" fn dlopen(file: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn dlerror() ?[*:0]const u8;

pub const sqlite3 = opaque {};
pub const sqlite3_backup = opaque {};
pub const sqlite3_blob = opaque {};
const sqlite3_vtab = opaque {};
const sqlite3_vtab_cursor = opaque {};
const VtabHeader = extern struct { pModule: ?*const Module, nRef: c_int, zErrMsg: ?[*:0]u8 };
const Module = extern struct {
    iVersion: c_int,
    xCreate: ?*const anyopaque,
    xConnect: ?*const anyopaque,
    xBestIndex: ?*const anyopaque,
    xDisconnect: ?*const anyopaque,
    xDestroy: ?*const anyopaque,
    xOpen: ?*const anyopaque,
    xClose: ?*const anyopaque,
    xFilter: ?*const anyopaque,
    xNext: ?*const anyopaque,
    xEof: ?*const anyopaque,
    xColumn: ?*const anyopaque,
    xRowid: ?*const anyopaque,
    xUpdate: ?*const anyopaque,
    xBegin: ?*const anyopaque,
    xSync: ?*const anyopaque,
    xCommit: ?*const anyopaque,
    xRollback: ?*const anyopaque,
    xFindFunction: ?*const anyopaque,
    xRename: ?*const anyopaque,
    xSavepoint: ?*const anyopaque,
    xRelease: ?*const anyopaque,
    xRollbackTo: ?*const anyopaque,
    xShadowName: ?*const anyopaque,
    xIntegrity: ?*const anyopaque,
};
const VirtualTable = struct { connection: *Connection, name: [:0]u8, module: *const Module, instance: *sqlite3_vtab, columns: std.ArrayList([:0]u8) = .empty };
const VirtualPlan = struct { table: *VirtualTable, index_number: c_int = 0, index_string: ?[:0]u8 = null };
const VirtualHandle = struct { plan: *VirtualPlan, cursor: *sqlite3_vtab_cursor };
const IndexConstraint = extern struct { iColumn: c_int, op: u8, usable: u8, iTermOffset: c_int };
const IndexOrderBy = extern struct { iColumn: c_int, desc: u8 };
const IndexUsage = extern struct { argvIndex: c_int, omit: u8 };
const IndexInfo = extern struct { nConstraint: c_int, aConstraint: ?[*]IndexConstraint, nOrderBy: c_int, aOrderBy: ?[*]IndexOrderBy, aConstraintUsage: ?[*]IndexUsage, idxNum: c_int, idxStr: ?[*:0]u8, needToFreeIdxStr: c_int, orderByConsumed: c_int, estimatedCost: f64, estimatedRows: i64, idxFlags: c_int, colUsed: u64 };
const planning_magic: u64 = 0x5a56544142504c4e;
const PlanningContext = extern struct { public: IndexInfo, magic: u64 = planning_magic, distinct: c_int = 0 };
const connection_magic: u64 = 0x5a_53_51_4c_43_4f_4e_4e;

fn defaultDatabaseConfiguration() [24]u8 {
    var result = [_]u8{0} ** 24;
    for ([_]usize{ 3, 13, 14, 15, 17, 20, 21, 22 }) |index| result[index] = 1;
    return result;
}

pub const Connection = struct {
    magic: u64 = connection_magic,
    allocator: std.mem.Allocator,
    last_result: ResultCode = .ok,
    error_offset: c_int = -1,
    custom_error_message: ?[:0]u8 = null,
    database: ?*btree.Database = null,
    owned_database: bool = false,
    unix_backend: ?unix_vfs.UnixVfs = null,
    unix_adapter: ?unix_vfs.Adapter = null,
    memory_backend: ?btree.vfs.MemoryVfs = null,
    memory_adapter: ?btree.vfs.AbiAdapter = null,
    filename: ?[:0]u8 = null,
    active_statements: usize = 0,
    statement_head: ?*statement.Statement = null,
    active_blobs: usize = 0,
    deferred_close: bool = false,
    extended_codes: bool = false,
    last_insert_rowid: i64 = 0,
    changes: i64 = 0,
    total_changes: i64 = 0,
    interrupted: bool = false,
    busy_callback: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int = null,
    busy_context: ?*anyopaque = null,
    busy_calls: c_int = 0,
    busy_timeout_ms: c_int = 0,
    authorizer_callback: ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null,
    authorizer_context: ?*anyopaque = null,
    progress_callback: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    progress_context: ?*anyopaque = null,
    progress_interval: u64 = 0,
    commit_callback: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    commit_context: ?*anyopaque = null,
    rollback_callback: ?*const fn (?*anyopaque) callconv(.c) void = null,
    rollback_context: ?*anyopaque = null,
    update_callback: ?*const fn (?*anyopaque, c_int, [*:0]const u8, [*:0]const u8, i64) callconv(.c) void = null,
    update_context: ?*anyopaque = null,
    autovacuum_callback: ?*const fn (?*anyopaque, [*:0]const u8, c_uint, c_uint, c_uint) callconv(.c) c_uint = null,
    autovacuum_context: ?*anyopaque = null,
    autovacuum_destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    legacy_trace_callback: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void = null,
    legacy_trace_context: ?*anyopaque = null,
    legacy_profile_callback: ?*const fn (?*anyopaque, [*:0]const u8, u64) callconv(.c) void = null,
    legacy_profile_context: ?*anyopaque = null,
    trace_v2_callback: ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    trace_v2_context: ?*anyopaque = null,
    trace_v2_mask: c_uint = 0,
    wal_callback: ?*const fn (?*anyopaque, ?*sqlite3, [*:0]const u8, c_int) callconv(.c) c_int = null,
    wal_context: ?*anyopaque = null,
    wal_autocheckpoint_pages: c_int = 0,
    scalar_functions: std.ArrayList(*statement.FunctionDefinition) = .empty,
    collations: std.ArrayList(struct { name: [:0]u8, encoding: c_int, auxiliary: ?*anyopaque, compare: *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int, destroy: ?*const fn (?*anyopaque) callconv(.c) void }) = .empty,
    collation_needed_callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, [*:0]const u8) callconv(.c) void = null,
    collation_needed16_callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, *const anyopaque) callconv(.c) void = null,
    collation_needed_context: ?*anyopaque = null,
    vtab_declaration: ?[:0]u8 = null,
    database_configuration: [24]u8 = defaultDatabaseConfiguration(),
    load_extension_enabled: bool = false,
    modules: std.ArrayList(struct { name: [:0]u8, module: *const anyopaque, auxiliary: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void }) = .empty,
    virtual_tables: std.ArrayList(*VirtualTable) = .empty,
    connection_mutex: mutex.Mutex = .{ .kind = .recursive },
    client_data: std.ArrayList(struct { name: [:0]u8, value: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void }) = .empty,
    limits: [12]c_int = .{ 1_000_000_000, 1_000_000_000, 2000, 1000, 500, 250_000_000, 127, 10, 50_000, 999, 1000, 8 },

    pub fn create(allocator: std.mem.Allocator) !*Connection {
        const connection = try allocator.create(Connection);
        connection.* = .{ .allocator = allocator };
        return connection;
    }

    pub fn init(allocator: std.mem.Allocator, database: ?*btree.Database) Connection {
        return .{ .allocator = allocator, .database = database };
    }

    pub fn destroy(self: *Connection) void {
        if (self.autovacuum_destroy) |destroy_callback| destroy_callback(self.autovacuum_context);
        if (self.custom_error_message) |message| self.allocator.free(message);
        for (self.scalar_functions.items) |definition| {
            if (definition.destroy) |destroy_callback| destroy_callback(definition.user_data);
            self.allocator.free(definition.name);
            self.allocator.destroy(definition);
        }
        self.scalar_functions.deinit(self.allocator);
        for (self.collations.items) |collation| {
            if (collation.destroy) |destroy_callback| destroy_callback(collation.auxiliary);
            self.allocator.free(collation.name);
        }
        self.collations.deinit(self.allocator);
        if (self.vtab_declaration) |declaration| self.allocator.free(declaration);
        for (self.virtual_tables.items) |table| {
            if (table.module.xDisconnect) |raw| {
                const callback: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(raw));
                _ = callback(table.instance);
            }
            for (table.columns.items) |column| self.allocator.free(column);
            table.columns.deinit(self.allocator);
            self.allocator.free(table.name);
            self.allocator.destroy(table);
        }
        self.virtual_tables.deinit(self.allocator);
        for (self.modules.items) |module| {
            if (module.destroy) |destroy_callback| destroy_callback(module.auxiliary);
            self.allocator.free(module.name);
        }
        self.modules.deinit(self.allocator);
        for (self.client_data.items) |entry| {
            if (entry.destroy) |destroy_callback| destroy_callback(entry.value);
            self.allocator.free(entry.name);
        }
        self.client_data.deinit(self.allocator);
        self.magic = 0;
        self.allocator.destroy(self);
    }

    fn findScalar(self: *Connection, name: []const u8, argument_count: usize) ?*statement.FunctionDefinition {
        for (self.scalar_functions.items) |definition| if (std.ascii.eqlIgnoreCase(definition.name, name) and (definition.argument_count < 0 or definition.argument_count == argument_count)) return definition;
        return null;
    }

    fn finishClose(self: *Connection) ResultCode {
        if (self.owned_database) {
            if (self.database) |database| {
                const rc = database.close();
                if (rc != .ok) return rc;
                self.allocator.destroy(database);
                self.database = null;
            }
            if (self.memory_backend) |*memory| memory.deinit();
            if (self.filename) |name| self.allocator.free(name);
        }
        self.destroy();
        return .ok;
    }

    fn statementEvent(context: ?*anyopaque, prepared: *statement.Statement, event: c_uint) void {
        const self: *Connection = @ptrCast(@alignCast(context orelse return));
        const sql = if (prepared.sql_copy) |text| text.ptr else "";
        if (event == 1) if (self.legacy_trace_callback) |callback| callback(self.legacy_trace_context, sql);
        if (event == 2) if (self.legacy_profile_callback) |callback| callback(self.legacy_profile_context, sql, 0);
        if (self.trace_v2_callback) |callback| if (self.trace_v2_mask & event != 0) {
            var elapsed: u64 = 0;
            const detail: ?*anyopaque = if (event == 1) @ptrCast(@constCast(sql)) else if (event == 2) @ptrCast(&elapsed) else null;
            _ = callback(event, self.trace_v2_context, statement.toOpaque(prepared), detail);
        };
    }

    fn beforeWrite(self: *Connection) ResultCode {
        if (self.commit_callback) |callback| if (callback(self.commit_context) != 0) {
            if (self.rollback_callback) |rollback| rollback(self.rollback_context);
            return .constraint;
        };
        return .ok;
    }
    fn afterWrite(self: *Connection, rc: ResultCode, operation: ?c_int, table: []const u8, rowid: i64) ResultCode {
        if (rc == .ok) {
            if (operation) |code| if (self.update_callback) |callback| {
                const name = self.allocator.dupeZ(u8, table) catch return .no_memory;
                defer self.allocator.free(name);
                callback(self.update_context, code, "main", name.ptr, rowid);
            };
            if (self.database) |database| if (database.pager.isWalMode()) {
                if (self.wal_callback) |callback| _ = callback(self.wal_context, toOpaque(self), "main", 0);
                if (self.wal_autocheckpoint_pages > 0) _ = database.pager.checkpointWal();
            };
        } else if (self.rollback_callback) |callback| callback(self.rollback_context);
        return rc;
    }

    fn vmProgress(context: ?*anyopaque, _: u64) bool {
        const self: *Connection = @ptrCast(@alignCast(context orelse return false));
        return if (self.progress_callback) |callback| callback(self.progress_context) == 0 else true;
    }

    fn pagerBusy(context: ?*anyopaque) bool {
        const self: *Connection = @ptrCast(@alignCast(context orelse return false));
        if (self.busy_callback) |callback| {
            const call = self.busy_calls;
            self.busy_calls += 1;
            return callback(self.busy_context, call) != 0;
        }
        if (self.busy_timeout_ms > 0) {
            _ = public_api.sqlite3_sleep(self.busy_timeout_ms);
            self.busy_timeout_ms = 0;
            return true;
        }
        return false;
    }

    fn statementFinalized(context: ?*anyopaque, prepared: *statement.Statement) void {
        const self: *Connection = @ptrCast(@alignCast(context orelse return));
        if (prepared.connection_previous) |previous| previous.connection_next = prepared.connection_next else self.statement_head = prepared.connection_next;
        if (prepared.connection_next) |next| next.connection_previous = prepared.connection_previous;
        std.debug.assert(self.active_statements > 0);
        self.active_statements -= 1;
        if (self.active_statements == 0) self.interrupted = false;
        if (self.active_statements == 0 and self.active_blobs == 0 and self.deferred_close) _ = self.finishClose();
    }
};

pub fn toOpaque(connection: *Connection) *sqlite3 {
    return @ptrCast(connection);
}

fn asConnection(pointer: ?*sqlite3) ?*Connection {
    const connection: *Connection = if (pointer) |value| @ptrCast(@alignCast(value)) else return null;
    return if (connection.magic == connection_magic) connection else null;
}

fn emptyDatabaseHeader() [512]u8 {
    var bytes = [_]u8{0} ** 512;
    @memcpy(bytes[0..16], "SQLite format 3\x00");
    bytes[16] = 0x02;
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[20] = 0;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    bytes[27] = 1;
    bytes[31] = 1;
    bytes[43] = 1;
    bytes[47] = 4;
    bytes[59] = 1;
    const version: u32 = 3_053_004;
    bytes[92] = 0;
    bytes[93] = 0;
    bytes[94] = 0;
    bytes[95] = 1;
    bytes[96] = @truncate(version >> 24);
    bytes[97] = @truncate(version >> 16);
    bytes[98] = @truncate(version >> 8);
    bytes[99] = @truncate(version);
    bytes[100] = 0x0d;
    bytes[105] = 0x02;
    return bytes;
}

fn initializeEmptyUnix(connection: *Connection, path: []const u8) ResultCode {
    const backend = &(connection.unix_backend orelse return .misuse);
    const opened = backend.openFile(path, btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    if (opened.rc != btree.vfs.OK) return ResultCode.fromC(opened.rc);
    const file = opened.file.?;
    var size: i64 = 0;
    var rc = file.size(&size);
    if (rc == btree.vfs.OK and size == 0) {
        const header = emptyDatabaseHeader();
        rc = file.write(&header, 0);
        if (rc == btree.vfs.OK) rc = file.sync();
    }
    const close_rc = file.destroy();
    return ResultCode.fromC(if (rc == btree.vfs.OK) close_rc else rc);
}

fn initializeEmptyMemory(connection: *Connection, path: []const u8) ResultCode {
    const backend = &(connection.memory_backend orelse return .misuse);
    const opened = backend.open(path, btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    if (opened.rc != btree.vfs.OK) return ResultCode.fromC(opened.rc);
    const file = opened.file.?;
    var size: u64 = 0;
    var rc = file.fileSize(&size);
    if (rc == btree.vfs.OK and size == 0) {
        const header = emptyDatabaseHeader();
        rc = file.write(&header, 0);
        if (rc == btree.vfs.OK) rc = file.sync();
    }
    const close_rc = backend.closeAndDestroy(file);
    return ResultCode.fromC(if (rc == btree.vfs.OK) close_rc else rc);
}

fn openConnection(filename: []const u8, flags: c_int, vfs_name: ?[]const u8, output: ?*?*sqlite3) c_int {
    const init_result = global.initializeProcess();
    if (init_result != 0) return init_result;
    const out = output orelse return ResultCode.misuse.toC();
    out.* = null;
    if (filename.len == 0) return ResultCode.cannot_open.toC();
    const allocator = std.heap.c_allocator;
    const connection = allocator.create(Connection) catch return ResultCode.no_memory.toC();
    connection.* = .{ .allocator = allocator, .owned_database = true };
    connection.filename = allocator.dupeZ(u8, filename) catch {
        allocator.destroy(connection);
        return ResultCode.no_memory.toC();
    };
    out.* = toOpaque(connection);
    const writable = flags & 0x02 != 0;
    const use_memory = std.mem.eql(u8, filename, ":memory:") or (vfs_name != null and std.ascii.eqlIgnoreCase(vfs_name.?, "mem"));
    var abi_vfs: *btree.vfs.sqlite3_vfs = undefined;
    const storage_name = if (use_memory) "main" else filename;
    if (use_memory) {
        connection.memory_backend = btree.vfs.MemoryVfs.init(allocator);
        connection.memory_adapter = btree.vfs.AbiAdapter.init("zig-memory", &connection.memory_backend.?);
        abi_vfs = &connection.memory_adapter.?.abi;
        if (writable) {
            const rc = initializeEmptyMemory(connection, storage_name);
            if (rc != .ok) {
                connection.last_result = rc;
                return rc.toC();
            }
        }
    } else {
        if (vfs_name) |name| {
            if (!std.ascii.eqlIgnoreCase(name, "zig-unix")) {
                const terminated = allocator.dupeZ(u8, name) catch {
                    connection.last_result = .no_memory;
                    return ResultCode.no_memory.toC();
                };
                defer allocator.free(terminated);
                abi_vfs = public_api.sqlite3_vfs_find(terminated.ptr) orelse {
                    connection.last_result = .not_found;
                    return ResultCode.not_found.toC();
                };
            } else {
                connection.unix_backend = unix_vfs.UnixVfs.init(allocator);
                connection.unix_adapter = unix_vfs.Adapter.init("zig-unix", &connection.unix_backend.?);
                abi_vfs = &connection.unix_adapter.?.abi;
            }
        } else {
            connection.unix_backend = unix_vfs.UnixVfs.init(allocator);
            connection.unix_adapter = unix_vfs.Adapter.init("zig-unix", &connection.unix_backend.?);
            abi_vfs = &connection.unix_adapter.?.abi;
        }
        if (connection.unix_backend != null and writable and flags & 0x04 != 0) {
            const rc = initializeEmptyUnix(connection, storage_name);
            if (rc != .ok) {
                connection.last_result = rc;
                return rc.toC();
            }
        }
    }
    const opened = if (writable) btree.Database.openWritable(allocator, abi_vfs, storage_name) else btree.Database.open(allocator, abi_vfs, storage_name);
    connection.last_result = opened.result;
    if (opened.result != .ok) return opened.result.toC();
    const database = allocator.create(btree.Database) catch {
        var value = opened.database.?;
        _ = value.close();
        connection.last_result = .no_memory;
        return ResultCode.no_memory.toC();
    };
    database.* = opened.database.?;
    connection.database = database;
    const extension_rc = ResultCode.fromC(public_api.runAutoExtensions(toOpaque(connection)));
    if (extension_rc != .ok) {
        connection.last_result = extension_rc;
        return extension_rc.toC();
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_open(filename: ?[*:0]const u8, output: ?*?*sqlite3) callconv(.c) c_int {
    return openConnection(if (filename) |name| std.mem.span(name) else return ResultCode.misuse.toC(), 0x02 | 0x04, null, output);
}

pub export fn sqlite3_open_v2(filename: ?[*:0]const u8, output: ?*?*sqlite3, flags: c_int, vfs_pointer: ?[*:0]const u8) callconv(.c) c_int {
    if (flags & 0x03 == 0 or flags & 0x03 == 0x03) return ResultCode.misuse.toC();
    return openConnection(if (filename) |name| std.mem.span(name) else return ResultCode.misuse.toC(), flags, if (vfs_pointer) |name| std.mem.span(name) else null, output);
}

pub export fn sqlite3_open16(filename: ?*const anyopaque, output: ?*?*sqlite3) callconv(.c) c_int {
    const raw: [*]const u16 = if (filename) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    var length: usize = 0;
    while (raw[length] != 0) : (length += 1) {}
    const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.c_allocator, raw[0..length]) catch return ResultCode.no_memory.toC();
    defer std.heap.c_allocator.free(utf8);
    return openConnection(utf8, 0x02 | 0x04, null, output);
}

pub export fn sqlite3_close(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.ok.toC();
    if (connection.active_statements != 0 or connection.active_blobs != 0) return ResultCode.busy.toC();
    return connection.finishClose().toC();
}

pub export fn sqlite3_close_v2(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.ok.toC();
    if (connection.active_statements != 0 or connection.active_blobs != 0) {
        connection.deferred_close = true;
        return ResultCode.ok.toC();
    }
    return connection.finishClose().toC();
}

const ExtensionEntry = *const fn (?*sqlite3, *?[*:0]u8, ?*const anyopaque) callconv(.c) c_int;

fn setExtensionError(output: ?*?[*:0]u8, message: []const u8) void {
    const destination = output orelse return;
    destination.* = null;
    const allocation = public_api.sqlite3_malloc64(message.len + 1) orelse return;
    const bytes: [*]u8 = @ptrCast(allocation);
    @memcpy(bytes[0..message.len], message);
    bytes[message.len] = 0;
    destination.* = @ptrCast(bytes);
}

pub export fn zig_sqlite3_db_config_main_name(pointer: ?*sqlite3, _: ?[*:0]const u8) callconv(.c) c_int {
    _ = asConnection(pointer) orelse return ResultCode.misuse.toC();
    return ResultCode.error_.toC();
}

pub export fn zig_sqlite3_db_config_lookaside(pointer: ?*sqlite3, _: ?*anyopaque, _: c_int, _: c_int) callconv(.c) c_int {
    _ = asConnection(pointer) orelse return ResultCode.misuse.toC();
    return ResultCode.ok.toC();
}

pub export fn zig_sqlite3_db_config_flag(pointer: ?*sqlite3, operation: c_int, enabled: c_int, output: ?*c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    const index = operation - 1000;
    if (index < 2 or index >= @as(c_int, @intCast(connection.database_configuration.len))) return ResultCode.error_.toC();
    const slot: usize = @intCast(index);
    if (enabled >= 0) connection.database_configuration[slot] = @intFromBool(enabled != 0);
    if (operation == 1005) connection.load_extension_enabled = connection.database_configuration[slot] != 0;
    if (output) |result| result.* = connection.database_configuration[slot];
    return ResultCode.ok.toC();
}

pub export fn zig_sqlite3_vtab_config(pointer: ?*sqlite3, operation: c_int, _: c_int) callconv(.c) c_int {
    _ = asConnection(pointer) orelse return ResultCode.misuse.toC();
    return switch (operation) {
        1, 2, 3, 4 => ResultCode.ok.toC(),
        else => ResultCode.misuse.toC(),
    };
}

pub export fn sqlite3_enable_load_extension(pointer: ?*sqlite3, enabled: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.load_extension_enabled = enabled != 0;
    connection.database_configuration[5] = @intFromBool(enabled != 0);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_load_extension(
    pointer: ?*sqlite3,
    file: ?[*:0]const u8,
    entry_name: ?[*:0]const u8,
    error_message: ?*?[*:0]u8,
) callconv(.c) c_int {
    if (error_message) |output| output.* = null;
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    const path = file orelse return ResultCode.misuse.toC();
    if (!connection.load_extension_enabled) return ResultCode.error_.toC();

    const handle = dlopen(path, 0x02) orelse {
        const message = if (dlerror()) |value| std.mem.span(value) else "unable to load extension";
        setExtensionError(error_message, message);
        return ResultCode.error_.toC();
    };
    const name = entry_name orelse "sqlite3_extension_init";
    const raw_entry = dlsym(handle, name) orelse {
        setExtensionError(error_message, "extension entry point not found");
        _ = dlclose(handle);
        return ResultCode.error_.toC();
    };
    const entry: ExtensionEntry = @ptrCast(@alignCast(raw_entry));
    var extension_error: ?[*:0]u8 = null;
    const result = entry(pointer, &extension_error, public_api.extensionApi());
    if (result != ResultCode.ok.toC()) {
        if (error_message) |output| {
            output.* = extension_error;
        } else if (extension_error) |message| {
            public_api.sqlite3_free(message);
        }
        if (extension_error == null) setExtensionError(error_message, "extension initialization failed");
        _ = dlclose(handle);
        return result;
    }
    if (extension_error) |message| public_api.sqlite3_free(message);
    // Registered callbacks may point into the extension, so successful handles stay resident.
    return ResultCode.ok.toC();
}

fn resultMessage(result: ResultCode) [*:0]const u8 {
    return switch (result) {
        .ok => "not an error",
        .error_ => "SQL logic error",
        .busy => "database is locked",
        .no_memory => "out of memory",
        .read_only => "attempt to write a readonly database",
        .interrupt => "interrupted",
        .io_error => "disk I/O error",
        .corrupt => "database disk image is malformed",
        .not_found => "unknown operation",
        .cannot_open => "unable to open database file",
        .constraint => "constraint failed",
        .mismatch => "datatype mismatch",
        .misuse => "bad parameter or other API misuse",
        else => "unknown error",
    };
}
pub export fn sqlite3_errcode(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer)) |connection| @intFromEnum(connection.last_result) & 0xff else ResultCode.no_memory.toC();
}
pub export fn sqlite3_extended_errcode(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer)) |connection| connection.last_result.toC() else ResultCode.no_memory.toC();
}
pub export fn sqlite3_errmsg(pointer: ?*sqlite3) callconv(.c) [*:0]const u8 {
    if (asConnection(pointer)) |connection| {
        if (connection.custom_error_message) |message| return message.ptr;
        return resultMessage(connection.last_result);
    }
    return resultMessage(.no_memory);
}
pub export fn sqlite3_set_errmsg(pointer: ?*sqlite3, code: c_int, message: ?[*:0]const u8) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    if (connection.custom_error_message) |old| connection.allocator.free(old);
    connection.custom_error_message = null;
    connection.last_result = ResultCode.fromC(code);
    if (message) |text| connection.custom_error_message = connection.allocator.dupeZ(u8, std.mem.span(text)) catch {
        connection.last_result = .no_memory;
        return ResultCode.no_memory.toC();
    };
    return ResultCode.ok.toC();
}
threadlocal var error16_buffer: [128]u16 = undefined;
pub export fn sqlite3_errmsg16(pointer: ?*sqlite3) callconv(.c) *const anyopaque {
    const message = std.mem.span(sqlite3_errmsg(pointer));
    const count = @min(message.len, error16_buffer.len - 1);
    for (message[0..count], 0..) |byte, index| error16_buffer[index] = byte;
    error16_buffer[count] = 0;
    return @ptrCast(&error16_buffer);
}
pub export fn sqlite3_errstr(code: c_int) callconv(.c) [*:0]const u8 {
    return resultMessage(ResultCode.fromC(code));
}
pub export fn sqlite3_error_offset(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer)) |connection| connection.error_offset else -1;
}
pub export fn sqlite3_extended_result_codes(pointer: ?*sqlite3, enabled: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.extended_codes = enabled != 0;
    return ResultCode.ok.toC();
}
pub export fn sqlite3_db_mutex(pointer: ?*sqlite3) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    return &connection.connection_mutex;
}

pub export fn sqlite3_db_filename(pointer: ?*sqlite3, database_name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const connection = asConnection(pointer) orelse return null;
    if (database_name) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return null;
    return if (connection.filename) |name| name.ptr else null;
}
pub export fn sqlite3_db_name(pointer: ?*sqlite3, index: c_int) callconv(.c) ?[*:0]const u8 {
    _ = pointer;
    return if (index == 0) "main" else null;
}
pub export fn sqlite3_db_readonly(pointer: ?*sqlite3, database_name: ?[*:0]const u8) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return -1;
    _ = database_name;
    return if (connection.database) |database| @intFromBool(!database.writable) else -1;
}
pub export fn sqlite3_get_autocommit(pointer: ?*sqlite3) callconv(.c) c_int {
    return @intFromBool(asConnection(pointer) != null);
}
const ScalarCallback = *const fn (?*statement.sqlite3_context, c_int, [*]?*statement.sqlite3_value) callconv(.c) void;
const FinalCallback = *const fn (?*statement.sqlite3_context) callconv(.c) void;
fn registerFunction(connection: *Connection, name: []const u8, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback, value_callback: ?FinalCallback, inverse_callback: ?ScalarCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) ResultCode {
    if (name.len == 0 or name.len > 255 or argument_count < -1 or argument_count > 127 or encoding & 7 < 1 or encoding & 7 > 3) {
        if (destroy_callback) |destroy| destroy(user_data);
        return .misuse;
    }
    const deleting = callback == null and step_callback == null and final_callback == null and value_callback == null and inverse_callback == null;
    const scalar = callback != null and step_callback == null and final_callback == null and value_callback == null and inverse_callback == null;
    const aggregate = callback == null and step_callback != null and final_callback != null and value_callback == null and inverse_callback == null;
    const window = callback == null and step_callback != null and final_callback != null and value_callback != null and inverse_callback != null;
    if (!deleting and !scalar and !aggregate and !window) {
        if (destroy_callback) |destroy| destroy(user_data);
        return .misuse;
    }
    var index: usize = 0;
    while (index < connection.scalar_functions.items.len) {
        const existing = connection.scalar_functions.items[index];
        if (existing.argument_count == argument_count and std.ascii.eqlIgnoreCase(existing.name, name)) {
            _ = connection.scalar_functions.orderedRemove(index);
            if (existing.destroy) |destroy| destroy(existing.user_data);
            connection.allocator.free(existing.name);
            connection.allocator.destroy(existing);
            break;
        }
        index += 1;
    }
    if (deleting) {
        if (destroy_callback) |destroy| destroy(user_data);
        return .ok;
    }
    const definition = connection.allocator.create(statement.FunctionDefinition) catch {
        if (destroy_callback) |destroy| destroy(user_data);
        return .no_memory;
    };
    definition.* = .{ .name = connection.allocator.dupeZ(u8, name) catch {
        connection.allocator.destroy(definition);
        if (destroy_callback) |destroy| destroy(user_data);
        return .no_memory;
    }, .argument_count = argument_count, .callback = callback, .step_callback = step_callback, .final_callback = final_callback, .value_callback = value_callback, .inverse_callback = inverse_callback, .user_data = user_data, .database = connection, .destroy = destroy_callback };
    connection.scalar_functions.append(connection.allocator, definition) catch {
        connection.allocator.free(definition.name);
        connection.allocator.destroy(definition);
        if (destroy_callback) |destroy| destroy(user_data);
        return .no_memory;
    };
    return .ok;
}
pub export fn sqlite3_create_function_v2(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse {
        if (destroy_callback) |destroy| destroy(user_data);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |name| std.mem.span(name) else {
        if (destroy_callback) |destroy| destroy(user_data);
        return ResultCode.misuse.toC();
    };
    return registerFunction(connection, name, argument_count, encoding, user_data, callback, step_callback, final_callback, null, null, destroy_callback).toC();
}
pub export fn sqlite3_create_function(pointer: ?*sqlite3, name: ?[*:0]const u8, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback) callconv(.c) c_int {
    return sqlite3_create_function_v2(pointer, name, argument_count, encoding, user_data, callback, step_callback, final_callback, null);
}
pub export fn sqlite3_create_function16(pointer: ?*sqlite3, name_pointer: ?*const anyopaque, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback) callconv(.c) c_int {
    const units: [*]const u16 = if (name_pointer) |name| @ptrCast(@alignCast(name)) else return ResultCode.misuse.toC();
    var length: usize = 0;
    while (units[length] != 0) : (length += 1) {}
    const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.c_allocator, units[0..length]) catch return ResultCode.no_memory.toC();
    defer std.heap.c_allocator.free(utf8);
    const name = std.heap.c_allocator.dupeZ(u8, utf8) catch return ResultCode.no_memory.toC();
    defer std.heap.c_allocator.free(name);
    return sqlite3_create_function(pointer, name.ptr, argument_count, encoding, user_data, callback, step_callback, final_callback);
}

pub export fn sqlite3_create_window_function(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, step_callback: ?ScalarCallback, final_callback: ?FinalCallback, value_callback: ?FinalCallback, inverse_callback: ?ScalarCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse {
        if (destroy_callback) |destroy| destroy(user_data);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |value| std.mem.span(value) else {
        if (destroy_callback) |destroy| destroy(user_data);
        return ResultCode.misuse.toC();
    };
    return registerFunction(connection, name, argument_count, encoding, user_data, null, step_callback, final_callback, value_callback, inverse_callback, destroy_callback).toC();
}

const CollationCallback = *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int;
pub export fn sqlite3_create_collation_v2(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, encoding: c_int, auxiliary: ?*anyopaque, compare: ?CollationCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |value| std.mem.span(value) else {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.misuse.toC();
    };
    if (name.len > 255 or encoding & 7 < 1 or encoding & 7 > 3) {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.misuse.toC();
    }
    var index: usize = 0;
    while (index < connection.collations.items.len) : (index += 1) if (connection.collations.items[index].encoding == encoding and std.ascii.eqlIgnoreCase(connection.collations.items[index].name, name)) {
        const old = connection.collations.orderedRemove(index);
        if (old.destroy) |destroy| destroy(old.auxiliary);
        connection.allocator.free(old.name);
        break;
    };
    const callback = compare orelse {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.ok.toC();
    };
    const owned = connection.allocator.dupeZ(u8, name) catch {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.no_memory.toC();
    };
    connection.collations.append(connection.allocator, .{ .name = owned, .encoding = encoding, .auxiliary = auxiliary, .compare = callback, .destroy = destroy_callback }) catch {
        connection.allocator.free(owned);
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.no_memory.toC();
    };
    return ResultCode.ok.toC();
}
pub export fn sqlite3_create_collation(pointer: ?*sqlite3, name: ?[*:0]const u8, encoding: c_int, auxiliary: ?*anyopaque, compare: ?CollationCallback) callconv(.c) c_int {
    return sqlite3_create_collation_v2(pointer, name, encoding, auxiliary, compare, null);
}
pub export fn sqlite3_create_collation16(pointer: ?*sqlite3, name_pointer: ?*const anyopaque, encoding: c_int, auxiliary: ?*anyopaque, compare: ?CollationCallback) callconv(.c) c_int {
    const units: [*]const u16 = if (name_pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    var length: usize = 0;
    while (units[length] != 0) : (length += 1) {}
    const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.c_allocator, units[0..length]) catch return ResultCode.no_memory.toC();
    defer std.heap.c_allocator.free(utf8);
    const name = std.heap.c_allocator.dupeZ(u8, utf8) catch return ResultCode.no_memory.toC();
    defer std.heap.c_allocator.free(name);
    return sqlite3_create_collation(pointer, name.ptr, encoding, auxiliary, compare);
}
pub export fn sqlite3_collation_needed(pointer: ?*sqlite3, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, [*:0]const u8) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.collation_needed_context = context;
    connection.collation_needed_callback = callback;
    connection.collation_needed16_callback = null;
    return ResultCode.ok.toC();
}
pub export fn sqlite3_collation_needed16(pointer: ?*sqlite3, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, *const anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.collation_needed_context = context;
    connection.collation_needed_callback = null;
    connection.collation_needed16_callback = callback;
    return ResultCode.ok.toC();
}

fn overloadedFunction(context: ?*statement.sqlite3_context, _: c_int, _: [*]?*statement.sqlite3_value) callconv(.c) void {
    statement.sqlite3_result_error_code(context, ResultCode.error_.toC());
}
pub export fn sqlite3_declare_vtab(pointer: ?*sqlite3, sql_pointer: ?[*:0]const u8) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    const sql = if (sql_pointer) |value| std.mem.span(value) else return ResultCode.misuse.toC();
    var first: usize = 0;
    while (first < sql.len and std.ascii.isWhitespace(sql[first])) : (first += 1) {}
    if (!std.ascii.startsWithIgnoreCase(sql[first..], "CREATE TABLE")) return ResultCode.error_.toC();
    const copy = connection.allocator.dupeZ(u8, sql) catch return ResultCode.no_memory.toC();
    if (connection.vtab_declaration) |old| connection.allocator.free(old);
    connection.vtab_declaration = copy;
    return ResultCode.ok.toC();
}
pub export fn sqlite3_overload_function(pointer: ?*sqlite3, name: ?[*:0]const u8, argument_count: c_int) callconv(.c) c_int {
    return sqlite3_create_function(pointer, name, argument_count, 1, null, overloadedFunction, null, null);
}
pub export fn sqlite3_vtab_on_conflict(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer) != null) ResultCode.abort.toC() else ResultCode.abort.toC();
}
fn planningContext(pointer: ?*IndexInfo) ?*PlanningContext {
    const info = pointer orelse return null;
    const context: *PlanningContext = @fieldParentPtr("public", info);
    return if (context.magic == planning_magic) context else null;
}
pub export fn sqlite3_vtab_distinct(pointer: ?*IndexInfo) callconv(.c) c_int {
    return if (planningContext(pointer)) |context| context.distinct else 0;
}
pub export fn sqlite3_vtab_collation(pointer: ?*IndexInfo, constraint: c_int) callconv(.c) [*:0]const u8 {
    const context = planningContext(pointer) orelse return "BINARY";
    if (constraint < 0 or constraint >= context.public.nConstraint) return "BINARY";
    return "BINARY";
}
pub export fn sqlite3_vtab_in(pointer: ?*IndexInfo, constraint: c_int, handle: c_int) callconv(.c) c_int {
    const context = planningContext(pointer) orelse return -1;
    if (constraint < 0 or constraint >= context.public.nConstraint) return -1;
    _ = handle;
    return 0;
}
pub export fn sqlite3_vtab_rhs_value(pointer: ?*IndexInfo, constraint: c_int, output: ?*?*statement.sqlite3_value) callconv(.c) c_int {
    if (output) |value| value.* = null;
    const context = planningContext(pointer) orelse return ResultCode.not_found.toC();
    if (constraint < 0 or constraint >= context.public.nConstraint) return ResultCode.not_found.toC();
    return ResultCode.not_found.toC();
}
pub export fn sqlite3_vtab_in_first(input: ?*statement.sqlite3_value, output: ?*?*statement.sqlite3_value) callconv(.c) c_int {
    if (output) |value| value.* = null;
    return if (input == null) ResultCode.misuse.toC() else ResultCode.error_.toC();
}
pub export fn sqlite3_vtab_in_next(input: ?*statement.sqlite3_value, output: ?*?*statement.sqlite3_value) callconv(.c) c_int {
    if (output) |value| value.* = null;
    return if (input == null) ResultCode.misuse.toC() else ResultCode.error_.toC();
}

pub export fn sqlite3_create_module_v2(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, module: ?*const anyopaque, auxiliary: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |value| std.mem.span(value) else {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.misuse.toC();
    };
    var index: usize = 0;
    while (index < connection.modules.items.len) : (index += 1) if (std.ascii.eqlIgnoreCase(connection.modules.items[index].name, name)) {
        const old = connection.modules.orderedRemove(index);
        if (old.destroy) |destroy| destroy(old.auxiliary);
        connection.allocator.free(old.name);
        break;
    };
    const implementation = module orelse {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.ok.toC();
    };
    const owned = connection.allocator.dupeZ(u8, name) catch {
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.no_memory.toC();
    };
    connection.modules.append(connection.allocator, .{ .name = owned, .module = implementation, .auxiliary = auxiliary, .destroy = destroy_callback }) catch {
        connection.allocator.free(owned);
        if (destroy_callback) |destroy| destroy(auxiliary);
        return ResultCode.no_memory.toC();
    };
    return ResultCode.ok.toC();
}
pub export fn sqlite3_create_module(pointer: ?*sqlite3, name: ?[*:0]const u8, module: ?*const anyopaque, auxiliary: ?*anyopaque) callconv(.c) c_int {
    return sqlite3_create_module_v2(pointer, name, module, auxiliary, null);
}
pub export fn sqlite3_drop_modules(pointer: ?*sqlite3, keep_names: ?[*]?[*:0]const u8) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    var index: usize = 0;
    while (index < connection.modules.items.len) {
        var keep = false;
        if (keep_names) |names| {
            var at: usize = 0;
            while (names[at]) |name| : (at += 1) if (std.ascii.eqlIgnoreCase(connection.modules.items[index].name, std.mem.span(name))) {
                keep = true;
                break;
            };
        }
        if (keep) {
            index += 1;
            continue;
        }
        const old = connection.modules.orderedRemove(index);
        if (old.destroy) |destroy| destroy(old.auxiliary);
        connection.allocator.free(old.name);
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_get_clientdata(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const name = if (name_pointer) |value| std.mem.span(value) else return null;
    for (connection.client_data.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}
pub export fn sqlite3_set_clientdata(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, value: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse {
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |item| std.mem.span(item) else {
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.misuse.toC();
    };
    var index: usize = 0;
    while (index < connection.client_data.items.len) : (index += 1) if (std.mem.eql(u8, connection.client_data.items[index].name, name)) {
        const old = connection.client_data.orderedRemove(index);
        if (old.destroy) |destroy| destroy(old.value);
        connection.allocator.free(old.name);
        break;
    };
    if (value == null) {
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.ok.toC();
    }
    const owned = connection.allocator.dupeZ(u8, name) catch {
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.no_memory.toC();
    };
    connection.client_data.append(connection.allocator, .{ .name = owned, .value = value, .destroy = destroy_callback }) catch {
        connection.allocator.free(owned);
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.no_memory.toC();
    };
    return ResultCode.ok.toC();
}

pub export fn sqlite3_trace(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const previous: ?*anyopaque = if (connection.legacy_trace_callback) |value| @ptrCast(@constCast(value)) else null;
    connection.legacy_trace_callback = callback;
    connection.legacy_trace_context = context;
    connection.trace_v2_callback = null;
    connection.trace_v2_mask = 0;
    connection.legacy_profile_callback = null;
    return previous;
}
pub export fn sqlite3_profile(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, [*:0]const u8, u64) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const previous: ?*anyopaque = if (connection.legacy_profile_callback) |value| @ptrCast(@constCast(value)) else null;
    connection.legacy_profile_callback = callback;
    connection.legacy_profile_context = context;
    return previous;
}
pub export fn sqlite3_trace_v2(pointer: ?*sqlite3, mask: c_uint, callback: ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.trace_v2_callback = callback;
    connection.trace_v2_context = context;
    connection.trace_v2_mask = mask & 0x0f;
    connection.legacy_trace_callback = null;
    connection.legacy_profile_callback = null;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_autovacuum_pages(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, [*:0]const u8, c_uint, c_uint, c_uint) callconv(.c) c_uint, context: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse {
        if (destroy_callback) |destroy| destroy(context);
        return ResultCode.misuse.toC();
    };
    if (connection.autovacuum_destroy) |destroy| destroy(connection.autovacuum_context);
    connection.autovacuum_callback = callback;
    connection.autovacuum_context = context;
    connection.autovacuum_destroy = destroy_callback;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_commit_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const previous: ?*anyopaque = if (connection.commit_callback) |value| @ptrCast(@constCast(value)) else null;
    connection.commit_callback = callback;
    connection.commit_context = context;
    return previous;
}
pub export fn sqlite3_rollback_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const previous: ?*anyopaque = if (connection.rollback_callback) |value| @ptrCast(@constCast(value)) else null;
    connection.rollback_callback = callback;
    connection.rollback_context = context;
    return previous;
}
pub export fn sqlite3_update_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, c_int, [*:0]const u8, [*:0]const u8, i64) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const previous: ?*anyopaque = if (connection.update_callback) |value| @ptrCast(@constCast(value)) else null;
    connection.update_callback = callback;
    connection.update_context = context;
    return previous;
}

pub export fn sqlite3_set_authorizer(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.authorizer_callback = callback;
    connection.authorizer_context = context;
    return ResultCode.ok.toC();
}
pub export fn sqlite3_progress_handler(pointer: ?*sqlite3, interval: c_int, callback: ?*const fn (?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) void {
    const connection = asConnection(pointer) orelse return;
    connection.progress_callback = if (interval > 0) callback else null;
    connection.progress_context = context;
    connection.progress_interval = if (interval > 0) @intCast(interval) else 0;
}

pub export fn sqlite3_busy_handler(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.busy_callback = callback;
    connection.busy_context = context;
    connection.busy_calls = 0;
    connection.busy_timeout_ms = 0;
    if (connection.database) |database| database.pager.setBusyHandler(if (callback != null) Connection.pagerBusy else null, connection);
    return ResultCode.ok.toC();
}
pub export fn sqlite3_busy_timeout(pointer: ?*sqlite3, milliseconds: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.busy_callback = null;
    connection.busy_timeout_ms = @max(milliseconds, 0);
    connection.busy_calls = 0;
    if (connection.database) |database| database.pager.setBusyHandler(if (milliseconds > 0) Connection.pagerBusy else null, connection);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_setlk_timeout(pointer: ?*sqlite3, milliseconds: c_int, flags: c_int) callconv(.c) c_int {
    _ = flags;
    return sqlite3_busy_timeout(pointer, milliseconds);
}

pub export fn sqlite3_interrupt(pointer: ?*sqlite3) callconv(.c) void {
    if (asConnection(pointer)) |connection| if (connection.active_statements != 0) {
        connection.interrupted = true;
    };
}
pub export fn sqlite3_is_interrupted(pointer: ?*sqlite3) callconv(.c) c_int {
    return @intFromBool(if (asConnection(pointer)) |connection| connection.interrupted else false);
}
pub export fn sqlite3_last_insert_rowid(pointer: ?*sqlite3) callconv(.c) i64 {
    return if (asConnection(pointer)) |connection| connection.last_insert_rowid else 0;
}
pub export fn sqlite3_set_last_insert_rowid(pointer: ?*sqlite3, value: i64) callconv(.c) void {
    if (asConnection(pointer)) |connection| connection.last_insert_rowid = value;
}
pub export fn sqlite3_changes(pointer: ?*sqlite3) callconv(.c) c_int {
    return @intCast(@min(if (asConnection(pointer)) |connection| connection.changes else 0, std.math.maxInt(c_int)));
}
pub export fn sqlite3_changes64(pointer: ?*sqlite3) callconv(.c) i64 {
    return if (asConnection(pointer)) |connection| connection.changes else 0;
}
pub export fn sqlite3_total_changes(pointer: ?*sqlite3) callconv(.c) c_int {
    return @intCast(@min(if (asConnection(pointer)) |connection| connection.total_changes else 0, std.math.maxInt(c_int)));
}
pub export fn sqlite3_total_changes64(pointer: ?*sqlite3) callconv(.c) i64 {
    return if (asConnection(pointer)) |connection| connection.total_changes else 0;
}
pub export fn sqlite3_unlock_notify(pointer: ?*sqlite3, callback: ?*const fn ([*]?*anyopaque, c_int) callconv(.c) void, argument: ?*anyopaque) callconv(.c) c_int {
    if (asConnection(pointer) == null) return ResultCode.misuse.toC();
    if (callback) |notify| {
        var arguments = [_]?*anyopaque{argument};
        notify(&arguments, 1);
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_next_stmt(pointer: ?*sqlite3, current: ?*statement.sqlite3_stmt) callconv(.c) ?*statement.sqlite3_stmt {
    const connection = asConnection(pointer) orelse return null;
    if (current) |handle| {
        const prepared = statement.fromOpaque(handle) orelse return null;
        return if (prepared.connection_next) |next| statement.toOpaque(next) else null;
    }
    return if (connection.statement_head) |head| statement.toOpaque(head) else null;
}

pub export fn sqlite3_limit(pointer: ?*sqlite3, category: c_int, value: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return -1;
    if (category < 0 or category >= connection.limits.len) return -1;
    const index: usize = @intCast(category);
    const previous = connection.limits[index];
    if (value >= 0) connection.limits[index] = value;
    return previous;
}
pub export fn sqlite3_db_handle(pointer: ?*statement.sqlite3_stmt) callconv(.c) ?*sqlite3 {
    const prepared = statement.fromOpaque(pointer) orelse return null;
    return if (prepared.finalize_context) |context| @ptrCast(@alignCast(context)) else null;
}

pub const ExecCallback = *const fn (?*anyopaque, c_int, [*]?[*:0]const u8, [*]?[*:0]const u8) callconv(.c) c_int;
pub export fn sqlite3_exec(database: ?*sqlite3, sql_pointer: ?[*:0]const u8, callback: ?ExecCallback, context: ?*anyopaque, error_message: ?*?[*:0]u8) callconv(.c) c_int {
    const connection = asConnection(database) orelse return ResultCode.misuse.toC();
    if (error_message) |output| output.* = null;
    const sql = sql_pointer orelse return ResultCode.misuse.toC();
    var position: usize = 0;
    while (position < std.mem.len(sql)) {
        var prepared: ?*statement.sqlite3_stmt = null;
        var tail: ?[*:0]const u8 = null;
        const rc = sqlite3_prepare_v2(database, sql + position, -1, &prepared, &tail);
        if (rc != ResultCode.ok.toC()) return rc;
        const advanced: usize = if (tail) |value| @intCast(@intFromPtr(value) - @intFromPtr(sql + position)) else 0;
        if (advanced == 0) return ResultCode.error_.toC();
        position += advanced;
        const handle = prepared orelse continue;
        while (true) {
            const step_rc = statement.sqlite3_step(handle);
            if (step_rc == ResultCode.row.toC()) {
                if (callback) |call| {
                    const count: usize = @intCast(statement.sqlite3_column_count(handle));
                    const values = connection.allocator.alloc(?[*:0]const u8, count) catch {
                        _ = statement.sqlite3_finalize(handle);
                        return ResultCode.no_memory.toC();
                    };
                    defer connection.allocator.free(values);
                    const names = connection.allocator.alloc(?[*:0]const u8, count) catch {
                        _ = statement.sqlite3_finalize(handle);
                        return ResultCode.no_memory.toC();
                    };
                    defer connection.allocator.free(names);
                    for (0..count) |index| {
                        values[index] = statement.sqlite3_column_text(handle, @intCast(index));
                        names[index] = statement.sqlite3_column_name(handle, @intCast(index));
                    }
                    if (call(context, @intCast(count), values.ptr, names.ptr) != 0) {
                        _ = statement.sqlite3_finalize(handle);
                        return ResultCode.abort.toC();
                    }
                }
                continue;
            }
            if (step_rc != ResultCode.done.toC()) {
                _ = statement.sqlite3_finalize(handle);
                return step_rc;
            }
            break;
        }
        const finalize_rc = statement.sqlite3_finalize(handle);
        if (finalize_rc != ResultCode.ok.toC()) return finalize_rc;
    }
    connection.last_result = .ok;
    return ResultCode.ok.toC();
}

const TableCollector = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(?[:0]u8) = .empty,
    columns: c_int = 0,
    failed: bool = false,

    fn callback(context: ?*anyopaque, count: c_int, row: [*]?[*:0]const u8, names: [*]?[*:0]const u8) callconv(.c) c_int {
        const self: *TableCollector = @ptrCast(@alignCast(context.?));
        if (self.columns == 0) {
            self.columns = count;
            for (0..@intCast(count)) |index| self.values.append(self.allocator, if (names[index]) |name| self.allocator.dupeZ(u8, std.mem.span(name)) catch {
                self.failed = true;
                return 1;
            } else null) catch {
                self.failed = true;
                return 1;
            };
        } else if (self.columns != count) return 1;
        for (0..@intCast(count)) |index| self.values.append(self.allocator, if (row[index]) |value| self.allocator.dupeZ(u8, std.mem.span(value)) catch {
            self.failed = true;
            return 1;
        } else null) catch {
            self.failed = true;
            return 1;
        };
        return 0;
    }
    fn deinit(self: *TableCollector) void {
        for (self.values.items) |value| if (value) |bytes| self.allocator.free(bytes);
        self.values.deinit(self.allocator);
    }
};

pub export fn sqlite3_get_table(database: ?*sqlite3, sql: ?[*:0]const u8, result_output: ?*?[*]?[*:0]u8, row_count: ?*c_int, column_count: ?*c_int, error_output: ?*?[*:0]u8) callconv(.c) c_int {
    if (result_output == null or row_count == null or column_count == null) return ResultCode.misuse.toC();
    result_output.?.* = null;
    row_count.?.* = 0;
    column_count.?.* = 0;
    if (error_output) |output| output.* = null;
    var collector = TableCollector{ .allocator = std.heap.c_allocator };
    defer collector.deinit();
    const rc = sqlite3_exec(database, sql, TableCollector.callback, &collector, error_output);
    if (rc != ResultCode.ok.toC()) return if (collector.failed) ResultCode.no_memory.toC() else rc;
    if (collector.columns == 0) return ResultCode.ok.toC();
    const pointer_count = collector.values.items.len;
    const raw = public_api.sqlite3_malloc64(2 * @sizeOf(usize) + pointer_count * @sizeOf(?[*:0]u8)) orelse return ResultCode.no_memory.toC();
    const words: [*]usize = @ptrCast(@alignCast(raw));
    words[0] = 0x5a5441424c45;
    words[1] = pointer_count;
    const pointers: [*]?[*:0]u8 = @ptrCast(words + 2);
    @memset(pointers[0..pointer_count], null);
    for (collector.values.items, 0..) |value, index| if (value) |bytes| {
        const copy = public_api.sqlite3_malloc64(bytes.len + 1) orelse {
            sqlite3_free_table(pointers);
            return ResultCode.no_memory.toC();
        };
        const target: [*]u8 = @ptrCast(copy);
        @memcpy(target[0..bytes.len], bytes);
        target[bytes.len] = 0;
        pointers[index] = @ptrCast(target);
    };
    result_output.?.* = pointers;
    column_count.?.* = collector.columns;
    row_count.?.* = @intCast(pointer_count / @as(usize, @intCast(collector.columns)) - 1);
    return ResultCode.ok.toC();
}
pub export fn sqlite3_free_table(result: ?[*]?[*:0]u8) callconv(.c) void {
    const pointers = result orelse return;
    const words: [*]usize = @ptrCast(@alignCast(pointers));
    const header = words - 2;
    if (header[0] != 0x5a5441424c45) return;
    for (pointers[0..header[1]]) |value| if (value) |bytes| public_api.sqlite3_free(bytes);
    public_api.sqlite3_free(header);
}

pub export fn sqlite3_complete16(sql_pointer: ?*const anyopaque) callconv(.c) c_int {
    const units: [*]const u16 = if (sql_pointer) |pointer| @ptrCast(@alignCast(pointer)) else return 0;
    var length: usize = 0;
    while (units[length] != 0) : (length += 1) {}
    return @intFromBool(complete.isCompleteUtf16(units[0..length]));
}

pub export fn sqlite3_complete(sql_pointer: ?[*:0]const u8) callconv(.c) c_int {
    const sql = if (sql_pointer) |value| std.mem.span(value) else return 0;
    return @intFromBool(complete.isComplete(sql));
}

threadlocal var metadata_type_buffer: [128]u8 = undefined;
fn hasAutoincrement(token_list: []const Token) bool {
    for (token_list) |token| if (token.typ == tokens.tk_autoincr) return true;
    return false;
}
pub export fn sqlite3_table_column_metadata(pointer: ?*sqlite3, database_name: ?[*:0]const u8, table_name: ?[*:0]const u8, column_name: ?[*:0]const u8, type_output: ?*?[*:0]const u8, collation_output: ?*?[*:0]const u8, not_null_output: ?*c_int, primary_key_output: ?*c_int, autoincrement_output: ?*c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    if (database_name) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return ResultCode.error_.toC();
    const table = if (table_name) |name| std.mem.span(name) else return ResultCode.misuse.toC();
    const column = if (column_name) |name| std.mem.span(name) else return ResultCode.misuse.toC();
    const database = connection.database orelse return ResultCode.misuse.toC();
    const schema_outcome = database.schemaTable(table);
    if (schema_outcome.result != .ok) return schema_outcome.result.toC();
    var schema = schema_outcome.table.?;
    defer schema.deinit();
    const resolved = resolveColumns(connection.allocator, schema.sql) catch return ResultCode.no_memory.toC();
    defer {
        connection.allocator.free(resolved.columns);
        connection.allocator.free(resolved.tokens);
        connection.allocator.free(resolved.source);
    }
    for (resolved.columns) |item| if (std.ascii.eqlIgnoreCase(item.name, column)) {
        if (type_output) |output| {
            const count = @min(item.declared_type.len, metadata_type_buffer.len - 1);
            @memcpy(metadata_type_buffer[0..count], item.declared_type[0..count]);
            metadata_type_buffer[count] = 0;
            output.* = @ptrCast(&metadata_type_buffer);
        }
        if (collation_output) |output| output.* = "BINARY";
        if (not_null_output) |output| output.* = @intFromBool(item.not_null);
        if (primary_key_output) |output| output.* = @intFromBool(item.integer_primary_key);
        if (autoincrement_output) |output| output.* = @intFromBool(item.integer_primary_key and hasAutoincrement(resolved.tokens));
        return ResultCode.ok.toC();
    };
    return ResultCode.error_.toC();
}

pub export fn sqlite3_db_status64(pointer: ?*sqlite3, operation: c_int, current: ?*i64, highwater: ?*i64, reset: c_int) callconv(.c) c_int {
    _ = reset;
    if (asConnection(pointer) == null or current == null or highwater == null or operation < 0 or operation > 13) return ResultCode.misuse.toC();
    current.?.* = 0;
    highwater.?.* = 0;
    return ResultCode.ok.toC();
}
pub export fn sqlite3_db_status(pointer: ?*sqlite3, operation: c_int, current: ?*c_int, highwater: ?*c_int, reset: c_int) callconv(.c) c_int {
    var now: i64 = 0;
    var high: i64 = 0;
    const rc = sqlite3_db_status64(pointer, operation, &now, &high, reset);
    if (rc == ResultCode.ok.toC()) {
        if (current) |value| value.* = @intCast(now);
        if (highwater) |value| value.* = @intCast(high);
    }
    return rc;
}
pub export fn sqlite3_file_control(pointer: ?*sqlite3, database_name: ?[*:0]const u8, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    _ = database_name;
    _ = operation;
    _ = argument;
    return if (asConnection(pointer) != null) ResultCode.not_found.toC() else ResultCode.misuse.toC();
}
pub export fn sqlite3_db_cacheflush(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer) != null) ResultCode.ok.toC() else ResultCode.misuse.toC();
}
pub export fn sqlite3_system_errno(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer) != null) 0 else 0;
}

pub export fn sqlite3_serialize(pointer: ?*sqlite3, schema: ?[*:0]const u8, size_output: ?*i64, flags: c_uint) callconv(.c) ?[*]u8 {
    const connection = asConnection(pointer) orelse return null;
    if (size_output) |output| output.* = -1;
    if (schema) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return null;
    if (connection.memory_backend) |*memory| {
        if (flags & 1 != 0) {
            const borrowed = memory.borrowVolatile("main") orelse return null;
            if (size_output) |output| output.* = @intCast(borrowed.len);
            return borrowed.ptr;
        }
        const bytes = memory.copyVolatile(connection.allocator, "main") catch return null;
        defer connection.allocator.free(bytes);
        const output = public_api.sqlite3_malloc64(bytes.len) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(output))[0..bytes.len], bytes);
        if (size_output) |size| size.* = @intCast(bytes.len);
        return @ptrCast(output);
    }
    if (connection.unix_backend) |*backend| {
        const filename = connection.filename orelse return null;
        const opened = backend.openFile(filename, btree.vfs.OPEN_READONLY | btree.vfs.OPEN_MAIN_DB);
        if (opened.rc != btree.vfs.OK) return null;
        const file = opened.file.?;
        defer _ = file.destroy();
        var length: i64 = 0;
        if (file.size(&length) != btree.vfs.OK or length < 0) return null;
        if (size_output) |output| output.* = length;
        if (flags & 1 != 0) return null;
        const output = public_api.sqlite3_malloc64(@intCast(length)) orelse return null;
        const bytes = @as([*]u8, @ptrCast(output))[0..@intCast(length)];
        if (file.read(bytes, 0) != btree.vfs.OK) {
            public_api.sqlite3_free(output);
            return null;
        }
        return @ptrCast(output);
    }
    return null;
}

pub export fn sqlite3_deserialize(pointer: ?*sqlite3, schema: ?[*:0]const u8, data: ?[*]u8, size: i64, buffer_size: i64, flags: c_uint) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    if (size < 0 or buffer_size < 0 or size > buffer_size or data == null) return ResultCode.misuse.toC();
    var transferred = false;
    defer if (!transferred and flags & btree.vfs.DESERIALIZE_FREEONCLOSE != 0) public_api.sqlite3_free(data);
    if (connection.active_statements != 0) return ResultCode.misuse.toC();
    if (schema) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return ResultCode.error_.toC();

    var replacement_name: ?[:0]u8 = null;
    if (connection.filename == null or !std.mem.eql(u8, connection.filename.?, ":memory:")) {
        replacement_name = connection.allocator.dupeZ(u8, ":memory:") catch return ResultCode.no_memory.toC();
    }
    defer if (replacement_name) |name| connection.allocator.free(name);
    if (connection.database) |database| {
        const rc = database.close();
        if (rc != .ok) return rc.toC();
        connection.allocator.destroy(database);
        connection.database = null;
    }
    if (connection.memory_backend) |*memory| memory.deinit();
    connection.memory_backend = btree.vfs.MemoryVfs.init(connection.allocator);
    connection.memory_adapter = btree.vfs.AbiAdapter.init("zig-deserialize", &connection.memory_backend.?);
    const opened_file = connection.memory_backend.?.open("main", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    if (opened_file.rc != btree.vfs.OK) return opened_file.rc;
    const file = opened_file.file.?;
    connection.memory_backend.?.adoptVolatileBuffer(file, data.?, @intCast(size), @intCast(buffer_size), flags);
    transferred = true;
    const close_rc = connection.memory_backend.?.closeAndDestroy(file);
    if (close_rc != btree.vfs.OK) return close_rc;
    const opened = if (flags & btree.vfs.DESERIALIZE_READONLY != 0) btree.Database.open(connection.allocator, &connection.memory_adapter.?.abi, "main") else btree.Database.openWritable(connection.allocator, &connection.memory_adapter.?.abi, "main");
    if (opened.result != .ok) return opened.result.toC();
    const database = connection.allocator.create(btree.Database) catch {
        var temporary = opened.database.?;
        _ = temporary.close();
        return ResultCode.no_memory.toC();
    };
    database.* = opened.database.?;
    connection.database = database;
    if (replacement_name) |name| {
        if (connection.filename) |old| connection.allocator.free(old);
        connection.filename = name;
        replacement_name = null;
    }
    return ResultCode.ok.toC();
}

const Blob = struct {
    connection: *Connection,
    root_page: u32,
    column: usize,
    rowid: i64,
    writable: bool,
};

fn validateBlob(blob: *Blob) ResultCode {
    const database = blob.connection.database orelse return .misuse;
    const opened = database.openCursor(blob.root_page, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    if (!cursor.seekTable(blob.rowid)) return .error_;
    const decoded = cursor.record();
    if (decoded.result != .ok) return decoded.result;
    var record = decoded.record.?;
    defer record.deinit();
    if (blob.column >= record.values.len) return .error_;
    return switch (record.values[blob.column]) {
        .blob, .text => .ok,
        else => .error_,
    };
}

pub export fn sqlite3_blob_open(database_pointer: ?*sqlite3, database_name: ?[*:0]const u8, table_name: ?[*:0]const u8, column_name: ?[*:0]const u8, rowid: i64, flags: c_int, output: ?*?*sqlite3_blob) callconv(.c) c_int {
    const connection = asConnection(database_pointer) orelse return ResultCode.misuse.toC();
    const out = output orelse return ResultCode.misuse.toC();
    out.* = null;
    if (database_name) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return ResultCode.error_.toC();
    const table = if (table_name) |name| std.mem.span(name) else return ResultCode.misuse.toC();
    const column = if (column_name) |name| std.mem.span(name) else return ResultCode.misuse.toC();
    const database = connection.database orelse return ResultCode.misuse.toC();
    const schema_outcome = database.schemaTable(table);
    if (schema_outcome.result != .ok) return schema_outcome.result.toC();
    var schema = schema_outcome.table.?;
    defer schema.deinit();
    const resolved = resolveColumns(connection.allocator, schema.sql) catch return ResultCode.no_memory.toC();
    defer {
        connection.allocator.free(resolved.columns);
        connection.allocator.free(resolved.tokens);
        connection.allocator.free(resolved.source);
    }
    var record_column: ?usize = null;
    for (resolved.columns) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, column) and !item.integer_primary_key) {
            record_column = item.record_index;
            break;
        }
    }
    const blob = connection.allocator.create(Blob) catch return ResultCode.no_memory.toC();
    blob.* = .{ .connection = connection, .root_page = schema.root_page, .column = record_column orelse {
        connection.allocator.destroy(blob);
        return ResultCode.error_.toC();
    }, .rowid = rowid, .writable = flags != 0 };
    const rc = validateBlob(blob);
    if (rc != .ok) {
        connection.allocator.destroy(blob);
        return rc.toC();
    }
    connection.active_blobs += 1;
    out.* = @ptrCast(blob);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_blob_reopen(pointer: ?*sqlite3_blob, rowid: i64) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    const previous = blob.rowid;
    blob.rowid = rowid;
    const rc = validateBlob(blob);
    if (rc != .ok) blob.rowid = previous;
    return rc.toC();
}

pub export fn sqlite3_blob_close(pointer: ?*sqlite3_blob) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.ok.toC();
    const connection = blob.connection;
    connection.allocator.destroy(blob);
    std.debug.assert(connection.active_blobs > 0);
    connection.active_blobs -= 1;
    if (connection.active_blobs == 0 and connection.active_statements == 0 and connection.deferred_close) _ = connection.finishClose();
    return ResultCode.ok.toC();
}

pub export fn sqlite3_blob_bytes(pointer: ?*sqlite3_blob) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return 0;
    const database = blob.connection.database orelse return 0;
    const opened = database.openCursor(blob.root_page, .table);
    if (opened.result != .ok) return 0;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    if (!cursor.seekTable(blob.rowid)) return 0;
    const decoded = cursor.record();
    if (decoded.result != .ok) return 0;
    var record = decoded.record.?;
    defer record.deinit();
    if (blob.column >= record.values.len) return 0;
    return @intCast(switch (record.values[blob.column]) {
        .blob => |value| value.len,
        .text => |value| value.len,
        else => 0,
    });
}

pub export fn sqlite3_blob_read(pointer: ?*sqlite3_blob, output: ?*anyopaque, amount: c_int, offset: c_int) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    if (amount < 0 or offset < 0 or (amount != 0 and output == null)) return ResultCode.misuse.toC();
    const database = blob.connection.database orelse return ResultCode.misuse.toC();
    const opened = database.openCursor(blob.root_page, .table);
    if (opened.result != .ok) return opened.result.toC();
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    if (!cursor.seekTable(blob.rowid)) return ResultCode.abort.toC();
    const decoded = cursor.record();
    if (decoded.result != .ok) return decoded.result.toC();
    var record = decoded.record.?;
    defer record.deinit();
    const bytes = switch (record.values[blob.column]) {
        .blob => |value| value,
        .text => |value| value,
        else => return ResultCode.error_.toC(),
    };
    const start: usize = @intCast(offset);
    const count: usize = @intCast(amount);
    if (start > bytes.len or count > bytes.len - start) return ResultCode.error_.toC();
    if (count != 0) @memcpy(@as([*]u8, @ptrCast(output.?))[0..count], bytes[start..][0..count]);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_blob_write(pointer: ?*sqlite3_blob, input: ?*const anyopaque, amount: c_int, offset: c_int) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    if (!blob.writable) return ResultCode.read_only.toC();
    if (amount < 0 or offset < 0 or (amount != 0 and input == null)) return ResultCode.misuse.toC();
    const database = blob.connection.database orelse return ResultCode.misuse.toC();
    const opened = database.openCursor(blob.root_page, .table);
    if (opened.result != .ok) return opened.result.toC();
    var cursor = opened.cursor.?;
    if (!cursor.seekTable(blob.rowid)) {
        cursor.deinit();
        return ResultCode.abort.toC();
    }
    const decoded = cursor.record();
    if (decoded.result != .ok) {
        cursor.deinit();
        return decoded.result.toC();
    }
    var record = decoded.record.?;
    const original_is_text = record.values[blob.column] == .text;
    const original = switch (record.values[blob.column]) {
        .blob => |value| value,
        .text => |value| value,
        else => {
            record.deinit();
            cursor.deinit();
            return ResultCode.error_.toC();
        },
    };
    const start: usize = @intCast(offset);
    const count: usize = @intCast(amount);
    if (start > original.len or count > original.len - start) {
        record.deinit();
        cursor.deinit();
        return ResultCode.error_.toC();
    }
    const replacement = blob.connection.allocator.dupe(u8, original) catch {
        record.deinit();
        cursor.deinit();
        return ResultCode.no_memory.toC();
    };
    defer blob.connection.allocator.free(replacement);
    if (count != 0) @memcpy(replacement[start..][0..count], @as([*]const u8, @ptrCast(input.?))[0..count]);
    const values = blob.connection.allocator.dupe(btree.Value, record.values) catch {
        record.deinit();
        cursor.deinit();
        return ResultCode.no_memory.toC();
    };
    defer blob.connection.allocator.free(values);
    values[blob.column] = if (original_is_text) .{ .text = replacement } else .{ .blob = replacement };
    const payload = btree.encodeRecord(blob.connection.allocator, values) catch {
        record.deinit();
        cursor.deinit();
        return ResultCode.no_memory.toC();
    };
    defer blob.connection.allocator.free(payload);
    record.deinit();
    cursor.deinit();
    return database.insertTable(blob.root_page, blob.rowid, payload, true).toC();
}

const Backup = struct { destination: *Connection, source: *Connection, remaining: c_int = 1, pages: c_int = 1, result: ResultCode = .ok };
pub export fn sqlite3_backup_init(destination_pointer: ?*sqlite3, destination_name: ?[*:0]const u8, source_pointer: ?*sqlite3, source_name: ?[*:0]const u8) callconv(.c) ?*sqlite3_backup {
    const destination = asConnection(destination_pointer) orelse return null;
    const source = asConnection(source_pointer) orelse return null;
    if (destination == source) {
        destination.last_result = .error_;
        return null;
    }
    if (destination_name) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return null;
    if (source_name) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return null;
    const backup = destination.allocator.create(Backup) catch {
        destination.last_result = .no_memory;
        return null;
    };
    backup.* = .{ .destination = destination, .source = source };
    return @ptrCast(backup);
}
pub export fn sqlite3_backup_step(pointer: ?*sqlite3_backup, pages: c_int) callconv(.c) c_int {
    _ = pages;
    const backup: *Backup = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    if (backup.remaining == 0) return ResultCode.done.toC();
    var size: i64 = 0;
    const bytes = sqlite3_serialize(toOpaque(backup.source), "main", &size, 0) orelse {
        backup.result = .error_;
        return backup.result.toC();
    };
    defer public_api.sqlite3_free(bytes);
    backup.pages = @intCast(@max(@divTrunc(size + 4095, 4096), 1));
    const rc = ResultCode.fromC(sqlite3_deserialize(toOpaque(backup.destination), "main", bytes, size, size, 0));
    backup.result = rc;
    if (rc == .ok) {
        backup.remaining = 0;
        return ResultCode.done.toC();
    }
    return rc.toC();
}
pub export fn sqlite3_backup_finish(pointer: ?*sqlite3_backup) callconv(.c) c_int {
    const backup: *Backup = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.ok.toC();
    const rc = backup.result;
    backup.destination.allocator.destroy(backup);
    return rc.toC();
}
pub export fn sqlite3_backup_remaining(pointer: ?*sqlite3_backup) callconv(.c) c_int {
    const backup: *Backup = if (pointer) |value| @ptrCast(@alignCast(value)) else return 0;
    return backup.remaining;
}
pub export fn sqlite3_backup_pagecount(pointer: ?*sqlite3_backup) callconv(.c) c_int {
    const backup: *Backup = if (pointer) |value| @ptrCast(@alignCast(value)) else return 0;
    return backup.pages;
}

pub export fn sqlite3_wal_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, ?*sqlite3, [*:0]const u8, c_int) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    const previous: ?*anyopaque = if (connection.wal_callback) |value| @ptrCast(@constCast(value)) else null;
    connection.wal_callback = callback;
    connection.wal_context = context;
    connection.wal_autocheckpoint_pages = 0;
    return previous;
}
pub export fn sqlite3_wal_autocheckpoint(pointer: ?*sqlite3, pages: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.wal_callback = null;
    connection.wal_autocheckpoint_pages = @max(pages, 0);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_wal_checkpoint_v2(pointer: ?*sqlite3, schema: ?[*:0]const u8, mode: c_int, log_frames: ?*c_int, checkpointed_frames: ?*c_int) callconv(.c) c_int {
    _ = mode;
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    if (schema) |name| if (!std.ascii.eqlIgnoreCase(std.mem.span(name), "main")) return ResultCode.error_.toC();
    const database = connection.database orelse return ResultCode.misuse.toC();
    const result = database.pager.checkpointWal();
    if (log_frames) |value| value.* = @intCast(result.frames);
    if (checkpointed_frames) |value| value.* = @intCast(result.frames);
    return result.result.toC();
}
pub export fn sqlite3_wal_checkpoint(pointer: ?*sqlite3, schema: ?[*:0]const u8) callconv(.c) c_int {
    return sqlite3_wal_checkpoint_v2(pointer, schema, 0, null, null);
}

pub export fn sqlite3_txn_state(pointer: ?*sqlite3, schema: ?[*:0]const u8) callconv(.c) c_int {
    _ = schema;
    return if (asConnection(pointer) != null) 0 else -1;
}

const Token = struct { typ: u16, text: []const u8, start: usize, end: usize };
const ParserError = error{ Syntax, TooBig, OutOfMemory };

fn virtualOpen(context: ?*anyopaque, output: *?*anyopaque) ResultCode {
    const plan: *VirtualPlan = @ptrCast(@alignCast(context orelse return .misuse));
    const table = plan.table;
    const raw = table.module.xOpen orelse return .error_;
    const callback: *const fn (*sqlite3_vtab, *?*sqlite3_vtab_cursor) callconv(.c) c_int = @ptrCast(@alignCast(raw));
    var cursor: ?*sqlite3_vtab_cursor = null;
    const rc = ResultCode.fromC(callback(table.instance, &cursor));
    if (rc != .ok) return rc;
    const handle = table.connection.allocator.create(VirtualHandle) catch {
        if (table.module.xClose) |close_raw| {
            const close: *const fn (*sqlite3_vtab_cursor) callconv(.c) c_int = @ptrCast(@alignCast(close_raw));
            _ = close(cursor.?);
        }
        return .no_memory;
    };
    handle.* = .{ .plan = plan, .cursor = cursor orelse {
        table.connection.allocator.destroy(handle);
        return .error_;
    } };
    output.* = handle;
    return .ok;
}
fn virtualClose(pointer: ?*anyopaque) void {
    const handle: *VirtualHandle = @ptrCast(@alignCast(pointer orelse return));
    if (handle.plan.table.module.xClose) |raw| {
        const callback: *const fn (*sqlite3_vtab_cursor) callconv(.c) c_int = @ptrCast(@alignCast(raw));
        _ = callback(handle.cursor);
    }
    handle.plan.table.connection.allocator.destroy(handle);
}
fn virtualFilter(pointer: ?*anyopaque) ResultCode {
    const handle: *VirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    const raw = handle.plan.table.module.xFilter orelse return .error_;
    const callback: *const fn (*sqlite3_vtab_cursor, c_int, ?[*:0]const u8, c_int, ?[*]?*statement.sqlite3_value) callconv(.c) c_int = @ptrCast(@alignCast(raw));
    return ResultCode.fromC(callback(handle.cursor, handle.plan.index_number, if (handle.plan.index_string) |value| value.ptr else null, 0, null));
}
fn virtualNext(pointer: ?*anyopaque) ResultCode {
    const handle: *VirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    const raw = handle.plan.table.module.xNext orelse return .error_;
    const callback: *const fn (*sqlite3_vtab_cursor) callconv(.c) c_int = @ptrCast(@alignCast(raw));
    return ResultCode.fromC(callback(handle.cursor));
}
fn virtualEof(pointer: ?*anyopaque) bool {
    const handle: *VirtualHandle = @ptrCast(@alignCast(pointer orelse return true));
    const raw = handle.plan.table.module.xEof orelse return true;
    const callback: *const fn (*sqlite3_vtab_cursor) callconv(.c) c_int = @ptrCast(@alignCast(raw));
    return callback(handle.cursor) != 0;
}
fn virtualColumn(pointer: ?*anyopaque, index: usize, output: *vdbe.Mem) ResultCode {
    const handle: *VirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    const raw = handle.plan.table.module.xColumn orelse return .error_;
    const callback: *const fn (?*anyopaque, ?*statement.sqlite3_context, c_int) callconv(.c) c_int = @ptrCast(@alignCast(raw));
    return statement.invokeVirtualColumn(callback, handle.cursor, index, output);
}
fn virtualRowid(pointer: ?*anyopaque, output: *i64) ResultCode {
    const handle: *VirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    const raw = handle.plan.table.module.xRowid orelse return .error_;
    const callback: *const fn (*sqlite3_vtab_cursor, *i64) callconv(.c) c_int = @ptrCast(@alignCast(raw));
    return ResultCode.fromC(callback(handle.cursor, output));
}
const virtual_source_template: vdbe.VirtualSource = .{ .context = null, .open = virtualOpen, .close = virtualClose, .filter = virtualFilter, .next = virtualNext, .eof = virtualEof, .column = virtualColumn, .rowid = virtualRowid };

const ProgramAction = union(enum) {
    create: struct { connection: *Connection, name: []const u8, sql: []const u8, if_not_exists: bool },
    virtual_create: struct { connection: *Connection, name: []const u8, module_name: []const u8 },
    virtual_drop: struct { connection: *Connection, name: []const u8 },
    drop: struct { connection: *Connection, name: []const u8, if_exists: bool },
    insert: struct { connection: *Connection, root_page: u32, table_name: []const u8, column_count: usize, integer_primary_key: ?usize, replace: bool, conflict_ignore: bool },
    update: struct { connection: *Connection, root_page: u32, table_name: []const u8, target_column: usize },
    delete: struct { connection: *Connection, root_page: u32, table_name: []const u8 },
    vacuum: struct { connection: *Connection },
};

const Owner = struct {
    source: [:0]u8,
    instructions: []vdbe.Instruction,
    parameters: []statement.ParameterMetadata,
    columns: []statement.ColumnMetadata,
    strings: std.ArrayList([]u8) = .empty,
    names: std.ArrayList([:0]u8) = .empty,
    action: ?ProgramAction = null,
    indices: []usize = &.{},
    functions: [1]vdbe.Function = undefined,
    dynamic_functions: []vdbe.Function = &.{},
    virtual_sources: []vdbe.VirtualSource = &.{},
    virtual_plan: ?*VirtualPlan = null,
    program: vdbe.Program,

    fn destroy(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(context));
        for (self.strings.items) |bytes| allocator.free(bytes);
        self.strings.deinit(allocator);
        for (self.names.items) |name| allocator.free(name);
        self.names.deinit(allocator);
        allocator.free(self.instructions);
        allocator.free(self.parameters);
        allocator.free(self.columns);
        allocator.free(self.indices);
        allocator.free(self.dynamic_functions);
        allocator.free(self.virtual_sources);
        if (self.virtual_plan) |plan| {
            if (plan.index_string) |value| allocator.free(value);
            allocator.destroy(plan);
        }
        allocator.free(self.source);
        allocator.destroy(self);
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    token_list: []const Token,
    position: usize = 0,
    instructions: std.ArrayList(vdbe.Instruction) = .empty,
    strings: std.ArrayList([]u8) = .empty,
    names: std.ArrayList([:0]u8) = .empty,
    parameter_names: std.ArrayList(?[:0]const u8) = .empty,
    named_parameters: std.StringHashMap(u16),
    next_register: u16,
    maximum_parameter: u16,
    connection: ?*Connection = null,
    functions: std.ArrayList(vdbe.Function) = .empty,
    error_offset: usize = 0,

    fn init(allocator: std.mem.Allocator, source: []const u8, token_list: []const Token, maximum_parameter: u16, connection: ?*Connection) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .token_list = token_list,
            .named_parameters = std.StringHashMap(u16).init(allocator),
            .next_register = maximum_parameter + 1,
            .maximum_parameter = maximum_parameter,
            .connection = connection,
        };
    }

    fn deinitFailure(self: *Parser) void {
        self.instructions.deinit(self.allocator);
        for (self.strings.items) |bytes| self.allocator.free(bytes);
        self.strings.deinit(self.allocator);
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
        self.parameter_names.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.named_parameters.deinit();
    }

    fn current(self: *const Parser) ?Token {
        return if (self.position < self.token_list.len) self.token_list[self.position] else null;
    }

    fn accept(self: *Parser, typ: u16) bool {
        if (self.current()) |token| {
            if (token.typ == typ) {
                self.position += 1;
                return true;
            }
        }
        return false;
    }

    fn require(self: *Parser, typ: u16) !Token {
        const token = self.current() orelse {
            self.error_offset = self.source.len;
            return error.Syntax;
        };
        if (token.typ != typ) {
            self.error_offset = token.start;
            return error.Syntax;
        }
        self.position += 1;
        return token;
    }

    fn allocateRegister(self: *Parser) !u16 {
        if (self.next_register == std.math.maxInt(u16)) return error.TooBig;
        const result = self.next_register;
        self.next_register += 1;
        return result;
    }

    fn emit(self: *Parser, instruction: vdbe.Instruction) !void {
        try self.instructions.append(self.allocator, instruction);
    }

    fn ownBytes(self: *Parser, bytes: []const u8) ![]u8 {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.strings.append(self.allocator, copy);
        return copy;
    }

    fn ownName(self: *Parser, bytes: []const u8) ![:0]u8 {
        const copy = try self.allocator.dupeZ(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.names.append(self.allocator, copy);
        return copy;
    }

    fn parameter(self: *Parser, token: Token) !u16 {
        if (token.text[0] == '?' and token.text.len > 1) {
            const index = std.fmt.parseInt(u16, token.text[1..], 10) catch return error.Syntax;
            if (index == 0 or index > self.maximum_parameter) return error.Syntax;
            return index;
        }
        if (token.text.len == 1 and token.text[0] == '?') {
            for (self.parameter_names.items, 0..) |name, index| if (name == null) return @intCast(index + 1);
            return error.Syntax;
        }
        if (self.named_parameters.get(token.text)) |index| return index;
        return error.Syntax;
    }

    fn primary(self: *Parser) ParserError!u16 {
        const token = self.current() orelse return error.Syntax;
        if (self.accept(tokens.tk_lp)) {
            const result = try self.expression(0);
            _ = try self.require(tokens.tk_rp);
            return result;
        }
        if (token.typ == tokens.tk_id and self.position + 1 < self.token_list.len and self.token_list[self.position + 1].typ == tokens.tk_lp) {
            const connection = self.connection orelse return error.Syntax;
            self.position += 2;
            var arguments = std.ArrayList(u16).empty;
            defer arguments.deinit(self.allocator);
            if (!self.accept(tokens.tk_rp)) {
                while (true) {
                    try arguments.append(self.allocator, try self.expression(0));
                    if (self.accept(tokens.tk_rp)) break;
                    _ = try self.require(tokens.tk_comma);
                }
            }
            const definition = connection.findScalar(token.text, arguments.items.len) orelse {
                self.error_offset = token.start;
                return error.Syntax;
            };
            var first: u16 = 0;
            for (arguments.items, 0..) |source, index| {
                const target = try self.allocateRegister();
                if (index == 0) first = target;
                try self.emit(.{ .opcode = .copy, .p1 = source, .p2 = target });
            }
            const output = try self.allocateRegister();
            const function_index = self.functions.items.len;
            try self.functions.append(self.allocator, .{ .callback = statement.invokeScalar, .context = definition });
            try self.emit(.{ .opcode = .function, .p1 = @intCast(arguments.items.len), .p2 = first, .p3 = output, .p4 = .{ .index = @intCast(function_index) } });
            return output;
        }
        if (self.accept(tokens.tk_null)) {
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .null_, .p2 = target });
            return target;
        }
        if (self.accept(tokens.tk_integer)) {
            const value = std.fmt.parseInt(i64, token.text, 10) catch return error.TooBig;
            const target = try self.allocateRegister();
            if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32))
                try self.emit(.{ .opcode = .integer, .p1 = @intCast(value), .p2 = target })
            else
                try self.emit(.{ .opcode = .int64, .p2 = target, .p4 = .{ .integer = value } });
            return target;
        }
        if (self.accept(tokens.tk_float)) {
            const value = std.fmt.parseFloat(f64, token.text) catch return error.Syntax;
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .real, .p2 = target, .p4 = .{ .real = value } });
            return target;
        }
        if (self.accept(tokens.tk_string)) {
            if (token.text.len < 2) return error.Syntax;
            var decoded = std.ArrayList(u8).empty;
            defer decoded.deinit(self.allocator);
            var index: usize = 1;
            while (index + 1 < token.text.len) : (index += 1) {
                if (token.text[index] == '\'' and index + 1 < token.text.len - 1 and token.text[index + 1] == '\'') index += 1;
                try decoded.append(self.allocator, token.text[index]);
            }
            const owned = try self.ownBytes(decoded.items);
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .string, .p2 = target, .p4 = .{ .bytes = owned } });
            return target;
        }
        if (self.accept(tokens.tk_blob)) {
            if (token.text.len < 3 or token.text.len % 2 == 0) return error.Syntax;
            const output = try self.allocator.alloc(u8, (token.text.len - 3) / 2);
            for (output, 0..) |*byte, index| byte.* = std.fmt.parseInt(u8, token.text[2 + index * 2 ..][0..2], 16) catch {
                self.allocator.free(output);
                return error.Syntax;
            };
            self.strings.append(self.allocator, output) catch {
                self.allocator.free(output);
                return error.OutOfMemory;
            };
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .blob, .p2 = target, .p4 = .{ .bytes = output } });
            return target;
        }
        if (self.accept(tokens.tk_variable)) return self.parameter(token);
        self.error_offset = token.start;
        return error.Syntax;
    }

    fn unary(self: *Parser) ParserError!u16 {
        if (self.accept(tokens.tk_plus)) return self.unary();
        if (self.accept(tokens.tk_minus)) {
            const source = try self.unary();
            const zero = try self.allocateRegister();
            try self.emit(.{ .opcode = .integer, .p1 = 0, .p2 = zero });
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .subtract, .p1 = source, .p2 = zero, .p3 = target });
            return target;
        }
        if (self.accept(tokens.tk_not)) {
            const source = try self.unary();
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .not, .p1 = source, .p2 = target });
            return target;
        }
        return self.primary();
    }

    fn precedence(typ: u16) u8 {
        return switch (typ) {
            tokens.tk_or => 1,
            tokens.tk_and => 2,
            tokens.tk_concat => 8,
            tokens.tk_plus, tokens.tk_minus => 6,
            tokens.tk_star, tokens.tk_slash, tokens.tk_rem => 7,
            else => 0,
        };
    }

    fn expression(self: *Parser, minimum: u8) ParserError!u16 {
        var left = try self.unary();
        while (self.current()) |operator| {
            const level = precedence(operator.typ);
            if (level == 0 or level < minimum) break;
            self.position += 1;
            const right = try self.expression(level + 1);
            const target = try self.allocateRegister();
            const opcode: vdbe.Opcode = switch (operator.typ) {
                tokens.tk_plus => .add,
                tokens.tk_minus => .subtract,
                tokens.tk_star => .multiply,
                tokens.tk_slash => .divide,
                tokens.tk_rem => .remainder,
                tokens.tk_concat => .concat,
                tokens.tk_and => .and_,
                tokens.tk_or => .or_,
                else => unreachable,
            };
            try self.emit(.{ .opcode = opcode, .p1 = right, .p2 = left, .p3 = target });
            left = target;
        }
        return left;
    }
};

const CompileOutcome = struct { result: ResultCode, statement: ?*statement.Statement = null, error_offset: c_int = -1, consumed: usize = 0 };

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) !struct { tokens: []Token, consumed: usize } {
    var list = std.ArrayList(Token).empty;
    errdefer list.deinit(allocator);
    var offset: usize = 0;
    var consumed = source.len;
    while (offset < source.len) {
        const result = tokenizer.get(source.ptr + offset);
        if (result.length == 0) return error.Syntax;
        const start = offset;
        offset += result.length;
        if (result.token_type == tokens.tk_space or result.token_type == tokens.tk_comment) continue;
        if (result.token_type == tokens.tk_semi) {
            consumed = offset;
            break;
        }
        if (result.token_type == tokens.tk_illegal) return error.Syntax;
        try list.append(allocator, .{ .typ = result.token_type, .text = source[start..offset], .start = start, .end = offset });
    }
    return .{ .tokens = try list.toOwnedSlice(allocator), .consumed = consumed };
}

fn scanParameters(allocator: std.mem.Allocator, token_list: []const Token) !struct { maximum: u16, names: []?[:0]const u8, owned: std.ArrayList([:0]u8), map: std.StringHashMap(u16) } {
    var maximum: u16 = 0;
    var next: u16 = 1;
    var owned = std.ArrayList([:0]u8).empty;
    errdefer {
        for (owned.items) |name| allocator.free(name);
        owned.deinit(allocator);
    }
    var map = std.StringHashMap(u16).init(allocator);
    errdefer map.deinit();
    for (token_list) |token| {
        if (token.typ != tokens.tk_variable) continue;
        var index: u16 = undefined;
        if (token.text[0] == '?' and token.text.len > 1) {
            index = std.fmt.parseInt(u16, token.text[1..], 10) catch return error.Syntax;
            if (index == 0) return error.Syntax;
        } else if (token.text.len == 1 and token.text[0] == '?') {
            index = next;
        } else if (map.get(token.text)) |existing| {
            index = existing;
        } else {
            index = next;
            const name = try allocator.dupeZ(u8, token.text);
            owned.append(allocator, name) catch {
                allocator.free(name);
                return error.OutOfMemory;
            };
            try map.put(name, index);
        }
        maximum = @max(maximum, index);
        next = @max(next, index + 1);
    }
    const names = try allocator.alloc(?[:0]const u8, maximum);
    errdefer allocator.free(names);
    @memset(names, null);
    for (token_list) |token| {
        if (token.typ != tokens.tk_variable) continue;
        const index: u16 = if (token.text[0] == '?' and token.text.len > 1)
            std.fmt.parseInt(u16, token.text[1..], 10) catch unreachable
        else if (token.text.len == 1 and token.text[0] == '?') blk: {
            var candidate: u16 = 1;
            while (candidate <= maximum and names[candidate - 1] != null) candidate += 1;
            break :blk candidate;
        } else map.get(token.text).?;
        if (names[index - 1] == null) {
            const name = try allocator.dupeZ(u8, token.text);
            owned.append(allocator, name) catch {
                allocator.free(name);
                return error.OutOfMemory;
            };
            names[index - 1] = name;
        }
    }
    return .{ .maximum = maximum, .names = names, .owned = owned, .map = map };
}

const ResolvedColumn = struct { name: []const u8, declared_type: []const u8, record_index: usize, integer_primary_key: bool, not_null: bool };

fn resolveColumns(allocator: std.mem.Allocator, sql: []const u8) !struct { source: [:0]u8, tokens: []Token, columns: []ResolvedColumn } {
    const source = try allocator.dupeZ(u8, sql);
    errdefer allocator.free(source);
    const parsed = try tokenize(allocator, source);
    errdefer allocator.free(parsed.tokens);
    var columns = std.ArrayList(ResolvedColumn).empty;
    errdefer columns.deinit(allocator);
    var position: usize = 0;
    while (position < parsed.tokens.len and parsed.tokens[position].typ != tokens.tk_lp) : (position += 1) {}
    if (position == parsed.tokens.len) return error.Syntax;
    position += 1;
    var record_index: usize = 0;
    while (position < parsed.tokens.len and parsed.tokens[position].typ != tokens.tk_rp) {
        if (parsed.tokens[position].typ != tokens.tk_id) return error.Syntax;
        const name = parsed.tokens[position].text;
        const start = position;
        var depth: usize = 0;
        while (position < parsed.tokens.len) : (position += 1) {
            const typ = parsed.tokens[position].typ;
            if (typ == tokens.tk_lp) depth += 1;
            if (typ == tokens.tk_rp) {
                if (depth == 0) break;
                depth -= 1;
            }
            if (typ == tokens.tk_comma and depth == 0) break;
        }
        const declared_type = if (start + 1 < position) parsed.tokens[start + 1].text else "";
        var primary = false;
        var not_null = false;
        var index = start + 1;
        while (index + 1 < position) : (index += 1) {
            if (parsed.tokens[index].typ == tokens.tk_primary and parsed.tokens[index + 1].typ == tokens.tk_key) primary = true;
            if (parsed.tokens[index].typ == tokens.tk_not and parsed.tokens[index + 1].typ == tokens.tk_null) not_null = true;
        }
        try columns.append(allocator, .{ .name = name, .declared_type = declared_type, .record_index = record_index, .integer_primary_key = primary, .not_null = not_null });
        record_index += 1;
        if (position < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_comma) position += 1;
    }
    return .{ .source = source, .tokens = parsed.tokens, .columns = try columns.toOwnedSlice(allocator) };
}

const ScanPlan = struct {
    predicate: ?struct { opcode: vdbe.Opcode, value: i64 } = null,
    descending: bool = false,
    limit: ?i64 = null,
};

fn buildPlannedTableScan(connection: *Connection, source: [:0]u8, root_page: u32, index_scan: bool, selected: []const ResolvedColumn, plan: ScanPlan) !*statement.Statement {
    const allocator = connection.allocator;
    const database = connection.database orelse return error.Misuse;
    if (selected.len > std.math.maxInt(u16) - 3) return error.TooBig;
    const owner = allocator.create(Owner) catch |err| {
        allocator.free(source);
        return err;
    };
    owner.* = .{ .source = source, .instructions = &.{}, .parameters = &.{}, .columns = &.{}, .program = .{ .instructions = &.{}, .register_count = @intCast(selected.len + 3), .cursor_count = 1 } };
    errdefer Owner.destroy(allocator, owner);
    var code = std.ArrayList(vdbe.Instruction).empty;
    defer code.deinit(allocator);
    const parameters = try allocator.alloc(statement.ParameterMetadata, 0);
    owner.parameters = parameters;
    const columns = try allocator.alloc(statement.ColumnMetadata, selected.len);
    owner.columns = columns;
    try code.append(allocator, .{ .opcode = .open_read, .p1 = 0, .p2 = @intCast(root_page), .p3 = @intFromBool(index_scan) });
    const predicate_register: i32 = @intCast(selected.len + 1);
    const rowid_register: i32 = @intCast(selected.len + 2);
    const limit_register: i32 = @intCast(selected.len + 3);
    if (plan.predicate) |predicate| try code.append(allocator, .{ .opcode = .integer, .p1 = @intCast(predicate.value), .p2 = predicate_register });
    if (plan.limit) |limit| try code.append(allocator, .{ .opcode = .integer, .p1 = @intCast(limit), .p2 = limit_register });
    if (plan.limit == 0) {
        try code.append(allocator, .{ .opcode = .halt });
    } else if (plan.predicate != null and plan.predicate.?.opcode == .eq) {
        const seek_index = code.items.len;
        try code.append(allocator, .{ .opcode = .seek_rowid, .p1 = 0, .p3 = predicate_register });
        for (selected, 0..) |column, index| try code.append(allocator, if (column.integer_primary_key) .{ .opcode = .rowid, .p1 = 0, .p2 = @intCast(index + 1) } else .{ .opcode = .column, .p1 = 0, .p2 = @intCast(column.record_index), .p3 = @intCast(index + 1) });
        try code.append(allocator, .{ .opcode = .result_row, .p1 = 1, .p2 = @intCast(selected.len) });
        const halt_index = code.items.len;
        try code.append(allocator, .{ .opcode = .halt });
        code.items[seek_index].p2 = @intCast(halt_index);
    } else {
        const position_index = code.items.len;
        try code.append(allocator, .{ .opcode = if (plan.descending) .last else .rewind, .p1 = 0 });
        const loop_index = code.items.len;
        var reject_index: ?usize = null;
        if (plan.predicate) |predicate| {
            try code.append(allocator, .{ .opcode = .rowid, .p1 = 0, .p2 = rowid_register });
            reject_index = code.items.len;
            const inverse: vdbe.Opcode = switch (predicate.opcode) {
                .eq => .ne,
                .ne => .eq,
                .lt => .ge,
                .le => .gt,
                .gt => .le,
                .ge => .lt,
                else => unreachable,
            };
            try code.append(allocator, .{ .opcode = inverse, .p1 = predicate_register, .p3 = rowid_register });
        }
        for (selected, 0..) |column, index| try code.append(allocator, if (column.integer_primary_key) .{ .opcode = .rowid, .p1 = 0, .p2 = @intCast(index + 1) } else .{ .opcode = .column, .p1 = 0, .p2 = @intCast(column.record_index), .p3 = @intCast(index + 1) });
        try code.append(allocator, .{ .opcode = .result_row, .p1 = 1, .p2 = @intCast(selected.len) });
        var limit_index: ?usize = null;
        if (plan.limit != null) {
            limit_index = code.items.len;
            try code.append(allocator, .{ .opcode = .decr_jump_zero, .p1 = limit_register });
        }
        const advance_index = code.items.len;
        try code.append(allocator, .{ .opcode = if (plan.descending) .prev else .next, .p1 = 0, .p2 = @intCast(loop_index) });
        const halt_index = code.items.len;
        try code.append(allocator, .{ .opcode = .halt });
        code.items[position_index].p2 = @intCast(halt_index);
        if (reject_index) |index| code.items[index].p2 = @intCast(advance_index);
        if (limit_index) |index| code.items[index].p2 = @intCast(halt_index);
    }
    for (selected, 0..) |column, index| {
        const name = try allocator.dupeZ(u8, column.name);
        owner.names.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
        columns[index] = .{ .name = name };
    }
    const instructions = try code.toOwnedSlice(allocator);
    owner.instructions = instructions;
    owner.program.instructions = instructions;
    const prepared = try statement.Statement.createWithDatabase(allocator, &owner.program, parameters, columns, database);
    prepared.adoptOwner(owner, Owner.destroy);
    return prepared;
}

fn compilePlannedTableScan(connection: *Connection, source: [:0]u8, consumed: usize, root_page: u32, index_scan: bool, selected: []const ResolvedColumn, plan: ScanPlan) CompileOutcome {
    const prepared = buildPlannedTableScan(connection, source, root_page, index_scan, selected, plan) catch |err| {
        return .{ .result = switch (err) {
            error.OutOfMemory => .no_memory,
            error.TooBig => .too_big,
            error.Misuse => .misuse,
            else => .error_,
        }, .consumed = consumed };
    };
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compileVirtualScan(connection: *Connection, table: *VirtualTable, source: [:0]u8, token_list: []const Token, consumed: usize, from_position: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (from_position + 2 != token_list.len) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var selected = std.ArrayList(usize).empty;
    defer selected.deinit(allocator);
    if (from_position == 2 and token_list[1].typ == tokens.tk_star) {
        for (0..table.columns.items.len) |index| selected.append(allocator, index) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
    } else {
        var position: usize = 1;
        while (position < from_position) {
            if (token_list[position].typ != tokens.tk_id) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            var found: ?usize = null;
            for (table.columns.items, 0..) |name, index| if (std.ascii.eqlIgnoreCase(name, token_list[position].text)) {
                found = index;
                break;
            };
            selected.append(allocator, found orelse {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }) catch {
                allocator.free(source);
                return .{ .result = .no_memory, .consumed = consumed };
            };
            position += 1;
            if (position == from_position) break;
            if (token_list[position].typ != tokens.tk_comma) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            position += 1;
        }
    }
    if (selected.items.len == 0) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const owner = allocator.create(Owner) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instruction_count = selected.items.len + 5;
    const instructions = allocator.alloc(vdbe.Instruction, instruction_count) catch {
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, selected.items.len) catch {
        allocator.free(parameters);
        allocator.free(instructions);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const sources = allocator.alloc(vdbe.VirtualSource, 1) catch {
        allocator.free(columns);
        allocator.free(parameters);
        allocator.free(instructions);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    sources[0] = virtual_source_template;
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .virtual_sources = sources, .program = .{ .instructions = instructions, .register_count = @intCast(selected.items.len), .cursor_count = 1, .virtual_sources = sources } };
    const plan = allocator.create(VirtualPlan) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    plan.* = .{ .table = table };
    owner.virtual_plan = plan;
    sources[0].context = plan;
    var planning: PlanningContext = .{ .public = .{ .nConstraint = 0, .aConstraint = null, .nOrderBy = 0, .aOrderBy = null, .aConstraintUsage = null, .idxNum = 0, .idxStr = null, .needToFreeIdxStr = 0, .orderByConsumed = 0, .estimatedCost = 1.0e99, .estimatedRows = 25, .idxFlags = 0, .colUsed = if (table.columns.items.len >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(table.columns.items.len)) - 1 } };
    const best_raw = table.module.xBestIndex orelse {
        Owner.destroy(allocator, owner);
        return .{ .result = .error_, .consumed = consumed };
    };
    const best: *const fn (*sqlite3_vtab, *IndexInfo) callconv(.c) c_int = @ptrCast(@alignCast(best_raw));
    const best_rc = ResultCode.fromC(best(table.instance, &planning.public));
    if (best_rc != .ok) {
        if (planning.public.needToFreeIdxStr != 0 and planning.public.idxStr != null) public_api.sqlite3_free(planning.public.idxStr);
        Owner.destroy(allocator, owner);
        return .{ .result = best_rc, .consumed = consumed };
    }
    plan.index_number = planning.public.idxNum;
    if (planning.public.idxStr) |text| {
        plan.index_string = allocator.dupeZ(u8, std.mem.span(text)) catch {
            if (planning.public.needToFreeIdxStr != 0) public_api.sqlite3_free(text);
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        if (planning.public.needToFreeIdxStr != 0) public_api.sqlite3_free(text);
    }
    instructions[0] = .{ .opcode = .open_virtual, .p1 = 0, .p2 = 0 };
    instructions[1] = .{ .opcode = .rewind, .p1 = 0, .p2 = @intCast(instruction_count - 1) };
    for (selected.items, 0..) |column_index, index| {
        instructions[2 + index] = .{ .opcode = .column, .p1 = 0, .p2 = @intCast(column_index), .p3 = @intCast(index + 1) };
        const name = owner.names.addOne(allocator) catch {
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        name.* = allocator.dupeZ(u8, table.columns.items[column_index]) catch {
            _ = owner.names.pop();
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        columns[index] = .{ .name = name.* };
    }
    instructions[instruction_count - 3] = .{ .opcode = .result_row, .p1 = 1, .p2 = @intCast(selected.items.len) };
    instructions[instruction_count - 2] = .{ .opcode = .next, .p1 = 0, .p2 = 2 };
    instructions[instruction_count - 1] = .{ .opcode = .halt };
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compileTableScan(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize, from_position: usize) CompileOutcome {
    const allocator = connection.allocator;
    const database = connection.database orelse {
        allocator.free(source);
        return .{ .result = .misuse, .consumed = consumed };
    };
    if (from_position + 1 >= token_list.len or token_list[from_position + 1].typ != tokens.tk_id) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    for (connection.virtual_tables.items) |table| if (std.ascii.eqlIgnoreCase(table.name, token_list[from_position + 1].text)) return compileVirtualScan(connection, table, source, token_list, consumed, from_position);
    const indexed = from_position + 5 == token_list.len and token_list[from_position + 2].typ == tokens.tk_indexed and token_list[from_position + 3].typ == tokens.tk_by and token_list[from_position + 4].typ == tokens.tk_id;
    const joined = from_position + 8 == token_list.len and token_list[from_position + 2].typ == tokens.tk_join and token_list[from_position + 3].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(token_list[from_position + 1].text, token_list[from_position + 3].text) and token_list[from_position + 4].typ == tokens.tk_using and token_list[from_position + 5].typ == tokens.tk_lp and token_list[from_position + 6].typ == tokens.tk_id and token_list[from_position + 7].typ == tokens.tk_rp;
    const schema_outcome = if (indexed) database.schemaIndex(token_list[from_position + 4].text) else database.schemaTable(token_list[from_position + 1].text);
    if (schema_outcome.result != .ok) {
        allocator.free(source);
        return .{ .result = if (schema_outcome.result == .not_found) .error_ else schema_outcome.result, .consumed = consumed };
    }
    var schema = schema_outcome.table.?;
    defer schema.deinit();
    const resolved = resolveColumns(allocator, schema.sql) catch |err| {
        allocator.free(source);
        return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
    };
    defer {
        allocator.free(resolved.columns);
        allocator.free(resolved.tokens);
        allocator.free(resolved.source);
    }
    var selected = std.ArrayList(ResolvedColumn).empty;
    defer selected.deinit(allocator);
    if (from_position == 2 and token_list[1].typ == tokens.tk_star) {
        selected.appendSlice(allocator, resolved.columns) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
    } else {
        var position: usize = 1;
        while (position < from_position) {
            if (token_list[position].typ != tokens.tk_id) {
                const offset = token_list[position].start;
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = consumed };
            }
            var found: ?ResolvedColumn = null;
            for (resolved.columns) |column| if (std.ascii.eqlIgnoreCase(column.name, token_list[position].text)) {
                found = column;
                break;
            };
            selected.append(allocator, found orelse {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
            }) catch {
                allocator.free(source);
                return .{ .result = .no_memory, .consumed = consumed };
            };
            position += 1;
            if (position == from_position) break;
            if (token_list[position].typ != tokens.tk_comma) {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
            }
            position += 1;
        }
    }
    if (selected.items.len == 0 or selected.items.len > std.math.maxInt(u16)) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    if (!indexed and !joined and from_position + 2 < token_list.len) {
        var plan: ScanPlan = .{};
        var position = from_position + 2;
        if (token_list[position].typ == tokens.tk_order and position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_by and token_list[position + 2].typ == tokens.tk_id) {
            const order_column = token_list[position + 2].text;
            var ordered_is_primary = false;
            for (resolved.columns) |column| if (column.integer_primary_key and std.ascii.eqlIgnoreCase(column.name, order_column)) {
                ordered_is_primary = true;
                break;
            };
            if (!ordered_is_primary) {
                position += 3;
                if (position < token_list.len and (token_list[position].typ == tokens.tk_asc or token_list[position].typ == tokens.tk_desc)) {
                    plan.descending = token_list[position].typ == tokens.tk_desc;
                    position += 1;
                }
                if (position < token_list.len and token_list[position].typ == tokens.tk_limit) {
                    if (position + 1 >= token_list.len or token_list[position + 1].typ != tokens.tk_integer) {
                        allocator.free(source);
                        return .{ .result = .error_, .consumed = consumed };
                    }
                    plan.limit = std.fmt.parseInt(i32, token_list[position + 1].text, 10) catch {
                        allocator.free(source);
                        return .{ .result = .error_, .consumed = consumed };
                    };
                    position += 2;
                }
                if (position != token_list.len) {
                    allocator.free(source);
                    return .{ .result = .error_, .consumed = consumed };
                }
                const index_name = std.fmt.allocPrint(allocator, "{s}_{s}", .{ token_list[from_position + 1].text, order_column }) catch {
                    allocator.free(source);
                    return .{ .result = .no_memory, .consumed = consumed };
                };
                defer allocator.free(index_name);
                const index_outcome = database.schemaIndex(index_name);
                if (index_outcome.result != .ok) {
                    allocator.free(source);
                    return .{ .result = if (index_outcome.result == .no_memory) .no_memory else .error_, .consumed = consumed };
                }
                var index_schema = index_outcome.table.?;
                defer index_schema.deinit();
                const table_cursor_outcome = database.openCursor(schema.root_page, .table);
                if (table_cursor_outcome.result != .ok) {
                    allocator.free(source);
                    return .{ .result = table_cursor_outcome.result, .consumed = consumed };
                }
                var table_cursor = table_cursor_outcome.cursor.?;
                defer table_cursor.deinit();
                const index_cursor_outcome = database.openCursor(index_schema.root_page, .index);
                if (index_cursor_outcome.result != .ok) {
                    allocator.free(source);
                    return .{ .result = index_cursor_outcome.result, .consumed = consumed };
                }
                var index_cursor = index_cursor_outcome.cursor.?;
                defer index_cursor.deinit();
                if (index_cursor.count() != table_cursor.count()) {
                    allocator.free(source);
                    return .{ .result = .error_, .consumed = consumed };
                }
                const index_resolved = resolveColumns(allocator, index_schema.sql) catch |err| {
                    allocator.free(source);
                    return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
                };
                defer {
                    allocator.free(index_resolved.columns);
                    allocator.free(index_resolved.tokens);
                    allocator.free(index_resolved.source);
                }
                var index_selected = std.ArrayList(ResolvedColumn).empty;
                defer index_selected.deinit(allocator);
                for (selected.items) |wanted| {
                    var found: ?ResolvedColumn = null;
                    for (index_resolved.columns) |column| if (std.ascii.eqlIgnoreCase(column.name, wanted.name)) {
                        found = column;
                        break;
                    };
                    index_selected.append(allocator, found orelse {
                        allocator.free(source);
                        return .{ .result = .error_, .consumed = consumed };
                    }) catch {
                        allocator.free(source);
                        return .{ .result = .no_memory, .consumed = consumed };
                    };
                }
                return compilePlannedTableScan(connection, source, consumed, index_schema.root_page, true, index_selected.items, plan);
            }
        }
        position = from_position + 2;
        var primary_key: ?ResolvedColumn = null;
        for (resolved.columns) |column| if (column.integer_primary_key) {
            primary_key = column;
            break;
        };
        const pk = primary_key orelse {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        };
        if (position < token_list.len and token_list[position].typ == tokens.tk_where) {
            if (position + 3 >= token_list.len or token_list[position + 1].typ != tokens.tk_id or !std.ascii.eqlIgnoreCase(token_list[position + 1].text, pk.name) or token_list[position + 3].typ != tokens.tk_integer) {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
            }
            const opcode: vdbe.Opcode = switch (token_list[position + 2].typ) {
                tokens.tk_eq => .eq,
                tokens.tk_ne => .ne,
                tokens.tk_lt => .lt,
                tokens.tk_le => .le,
                tokens.tk_gt => .gt,
                tokens.tk_ge => .ge,
                else => {
                    allocator.free(source);
                    return .{ .result = .error_, .error_offset = @intCast(token_list[position + 2].start), .consumed = consumed };
                },
            };
            const value = std.fmt.parseInt(i32, token_list[position + 3].text, 10) catch {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position + 3].start), .consumed = consumed };
            };
            plan.predicate = .{ .opcode = opcode, .value = value };
            position += 4;
        }
        if (position < token_list.len and token_list[position].typ == tokens.tk_order) {
            if (position + 2 >= token_list.len or token_list[position + 1].typ != tokens.tk_by or token_list[position + 2].typ != tokens.tk_id or !std.ascii.eqlIgnoreCase(token_list[position + 2].text, pk.name)) {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
            }
            position += 3;
            if (position < token_list.len and (token_list[position].typ == tokens.tk_asc or token_list[position].typ == tokens.tk_desc)) {
                plan.descending = token_list[position].typ == tokens.tk_desc;
                position += 1;
            }
        }
        if (position < token_list.len and token_list[position].typ == tokens.tk_limit) {
            if (position + 1 >= token_list.len or token_list[position + 1].typ != tokens.tk_integer) {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
            }
            plan.limit = std.fmt.parseInt(i32, token_list[position + 1].text, 10) catch {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[position + 1].start), .consumed = consumed };
            };
            position += 2;
        }
        if (position != token_list.len) {
            allocator.free(source);
            return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
        }
        return compilePlannedTableScan(connection, source, consumed, schema.root_page, false, selected.items, plan);
    }
    if (!indexed and !joined and from_position + 2 != token_list.len) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const owner = allocator.create(Owner) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instruction_count = selected.items.len + 4;
    const instructions = allocator.alloc(vdbe.Instruction, instruction_count) catch {
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, selected.items.len) catch {
        allocator.free(parameters);
        allocator.free(instructions);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    owner.* = .{
        .source = source,
        .instructions = instructions,
        .parameters = parameters,
        .columns = columns,
        .program = .{ .instructions = instructions, .register_count = @intCast(selected.items.len), .cursor_count = 1 },
    };
    instructions[0] = .{ .opcode = .open_read, .p1 = 0, .p2 = @intCast(schema.root_page), .p3 = @intFromBool(indexed) };
    instructions[1] = .{ .opcode = .rewind, .p1 = 0, .p2 = @intCast(instruction_count - 1) };
    for (selected.items, 0..) |column, index| {
        instructions[2 + index] = if (column.integer_primary_key)
            .{ .opcode = .rowid, .p1 = 0, .p2 = @intCast(index + 1) }
        else
            .{ .opcode = .column, .p1 = 0, .p2 = @intCast(column.record_index), .p3 = @intCast(index + 1) };
        const name = owner.names.addOne(allocator) catch {
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        name.* = allocator.dupeZ(u8, column.name) catch {
            _ = owner.names.pop();
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        columns[index] = .{ .name = name.* };
    }
    instructions[instruction_count - 2] = .{ .opcode = .result_row, .p1 = 1, .p2 = @intCast(selected.items.len) };
    // Resume at the first column extraction after each cursor advance.
    instructions[instruction_count - 1] = .{ .opcode = .next, .p1 = 0, .p2 = 2 };
    // Rewind's empty target and NEXT fallthrough need a terminal instruction.
    const expanded = allocator.realloc(instructions, instruction_count + 1) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    owner.instructions = expanded;
    owner.program.instructions = expanded;
    expanded[instruction_count] = .{ .opcode = .halt };
    expanded[1].p2 = @intCast(instruction_count);
    const prepared = statement.Statement.createWithDatabase(allocator, &owner.program, parameters, columns, database) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn memToBtreeValue(value: *vdbe.Mem) ?btree.Value {
    return switch (vdbe.vdbe_mem.valueType(value)) {
        1 => .{ .integer = vdbe.vdbe_mem.valueInt64(value) },
        2 => .{ .real = vdbe.vdbe_mem.valueDouble(value) },
        3 => text: {
            const bytes = vdbe.vdbe_mem.valueText(value, 1) orelse return null;
            break :text .{ .text = bytes[0..@intCast(value.n)] };
        },
        4 => blob: {
            const bytes = vdbe.vdbe_mem.valueBlob(value) orelse return .{ .blob = &.{} };
            break :blob .{ .blob = bytes[0..@intCast(value.n)] };
        },
        else => .null_,
    };
}

fn programActionCallback(context: ?*anyopaque, arguments: []vdbe.Mem, output: *vdbe.Mem, allocator: std.mem.Allocator) ResultCode {
    const owner: *Owner = @ptrCast(@alignCast(context orelse return .misuse));
    vdbe.vdbe_mem.setNull(output);
    return switch (owner.action orelse return .misuse) {
        .virtual_create => |action| blk: {
            var registered: ?@TypeOf(action.connection.modules.items[0]) = null;
            for (action.connection.modules.items) |module| if (std.ascii.eqlIgnoreCase(module.name, action.module_name)) {
                registered = module;
                break;
            };
            const module_entry = registered orelse break :blk .error_;
            const module: *const Module = @ptrCast(@alignCast(module_entry.module));
            const raw = module.xCreate orelse module.xConnect orelse break :blk .error_;
            const callback: *const fn (?*sqlite3, ?*anyopaque, c_int, [*]const [*:0]const u8, *?*sqlite3_vtab, *?[*:0]u8) callconv(.c) c_int = @ptrCast(@alignCast(raw));
            if (action.connection.vtab_declaration) |old| {
                action.connection.allocator.free(old);
                action.connection.vtab_declaration = null;
            }
            const table_name = action.connection.allocator.dupeZ(u8, action.name) catch break :blk .no_memory;
            var table_name_adopted = false;
            defer if (!table_name_adopted) action.connection.allocator.free(table_name);
            const module_name = action.connection.allocator.dupeZ(u8, action.module_name) catch break :blk .no_memory;
            defer action.connection.allocator.free(module_name);
            const module_arguments = [_][*:0]const u8{ module_name.ptr, "main", table_name.ptr };
            var instance: ?*sqlite3_vtab = null;
            var error_message: ?[*:0]u8 = null;
            const rc = ResultCode.fromC(callback(toOpaque(action.connection), module_entry.auxiliary, module_arguments.len, &module_arguments, &instance, &error_message));
            if (error_message) |message| public_api.sqlite3_free(message);
            if (rc != .ok) break :blk rc;
            if (instance == null) break :blk .error_;
            const header: *VtabHeader = @ptrCast(@alignCast(instance.?));
            header.pModule = module;
            const declaration = action.connection.vtab_declaration orelse {
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk .error_;
            };
            const resolved = resolveColumns(action.connection.allocator, declaration) catch |err| {
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk if (err == error.OutOfMemory) .no_memory else .error_;
            };
            defer {
                action.connection.allocator.free(resolved.columns);
                action.connection.allocator.free(resolved.tokens);
                action.connection.allocator.free(resolved.source);
            }
            const table = action.connection.allocator.create(VirtualTable) catch {
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk .no_memory;
            };
            table.* = .{ .connection = action.connection, .name = table_name, .module = module, .instance = instance.? };
            var failed = false;
            for (resolved.columns) |column| {
                const copy = action.connection.allocator.dupeZ(u8, column.name) catch {
                    failed = true;
                    break;
                };
                table.columns.append(action.connection.allocator, copy) catch {
                    action.connection.allocator.free(copy);
                    failed = true;
                    break;
                };
            }
            if (failed) {
                for (table.columns.items) |column| action.connection.allocator.free(column);
                table.columns.deinit(action.connection.allocator);
                action.connection.allocator.destroy(table);
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk .no_memory;
            }
            action.connection.virtual_tables.append(action.connection.allocator, table) catch {
                for (table.columns.items) |column| action.connection.allocator.free(column);
                table.columns.deinit(action.connection.allocator);
                action.connection.allocator.destroy(table);
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk .no_memory;
            };
            table_name_adopted = true;
            break :blk .ok;
        },
        .virtual_drop => |action| blk: {
            var index: usize = 0;
            while (index < action.connection.virtual_tables.items.len) : (index += 1) {
                if (!std.ascii.eqlIgnoreCase(action.connection.virtual_tables.items[index].name, action.name)) continue;
                const table = action.connection.virtual_tables.items[index];
                const raw = table.module.xDestroy orelse table.module.xDisconnect;
                if (raw) |callback_raw| {
                    const callback: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(callback_raw));
                    const rc = ResultCode.fromC(callback(table.instance));
                    if (rc != .ok) break :blk rc;
                }
                _ = action.connection.virtual_tables.orderedRemove(index);
                for (table.columns.items) |column| action.connection.allocator.free(column);
                table.columns.deinit(action.connection.allocator);
                action.connection.allocator.free(table.name);
                action.connection.allocator.destroy(table);
                break :blk .ok;
            }
            break :blk .error_;
        },
        .create => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            break :blk action.connection.afterWrite(database.createSchemaTable(action.name, action.sql, action.if_not_exists), null, action.name, 0);
        },
        .drop => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            break :blk action.connection.afterWrite(database.dropSchemaTable(action.name, action.if_exists), null, action.name, 0);
        },
        .vacuum => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            if (action.connection.autovacuum_callback) |callback| _ = callback(action.connection.autovacuum_context, "main", 0, 0, 4096);
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            break :blk action.connection.afterWrite(database.vacuumCompactNoop(), null, "", 0);
        },
        .update => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            if (arguments.len != 2) break :blk .corrupt;
            if (vdbe.vdbe_mem.valueType(&arguments[1]) != 1) break :blk .mismatch;
            const rowid = vdbe.vdbe_mem.valueInt64(&arguments[1]);
            const opened = database.openCursor(action.root_page, .table);
            if (opened.result != .ok) break :blk opened.result;
            var cursor = opened.cursor.?;
            defer cursor.deinit();
            if (!cursor.seekTable(rowid)) {
                action.connection.changes = 0;
                break :blk .ok;
            }
            const decoded = cursor.record();
            if (decoded.result != .ok) break :blk decoded.result;
            var record = decoded.record.?;
            defer record.deinit();
            if (action.target_column >= record.values.len) break :blk .corrupt;
            const values = allocator.dupe(btree.Value, record.values) catch break :blk .no_memory;
            defer allocator.free(values);
            values[action.target_column] = memToBtreeValue(&arguments[0]) orelse break :blk .no_memory;
            const payload = btree.encodeRecord(allocator, values) catch |err| break :blk if (err == error.OutOfMemory) .no_memory else .too_big;
            defer allocator.free(payload);
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const rc = database.insertTable(action.root_page, rowid, payload, true);
            if (rc == .ok) {
                action.connection.changes = 1;
                action.connection.total_changes += 1;
            }
            break :blk action.connection.afterWrite(rc, 23, action.table_name, rowid);
        },
        .delete => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            if (arguments.len != 1) break :blk .corrupt;
            if (vdbe.vdbe_mem.valueType(&arguments[0]) != 1) break :blk .mismatch;
            const rowid = vdbe.vdbe_mem.valueInt64(&arguments[0]);
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const rc = database.deleteTable(action.root_page, rowid);
            if (rc == .not_found) {
                action.connection.changes = 0;
                break :blk .ok;
            }
            if (rc == .ok) {
                action.connection.changes = 1;
                action.connection.total_changes += 1;
            }
            break :blk action.connection.afterWrite(rc, 9, action.table_name, rowid);
        },
        .insert => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            if (arguments.len != owner.indices.len) break :blk .corrupt;
            const values = allocator.alloc(btree.Value, action.column_count) catch break :blk .no_memory;
            defer allocator.free(values);
            @memset(values, .null_);
            for (arguments, owner.indices) |*argument, column| values[column] = memToBtreeValue(argument) orelse break :blk .no_memory;
            var rowid: i64 = 0;
            if (action.integer_primary_key) |column| {
                rowid = switch (values[column]) {
                    .integer => |value| value,
                    .null_ => value: {
                        const next = database.nextTableRowid(action.root_page);
                        if (next.result != .ok) break :blk next.result;
                        break :value next.rowid;
                    },
                    else => break :blk .mismatch,
                };
                values[column] = .null_;
            } else {
                const next = database.nextTableRowid(action.root_page);
                if (next.result != .ok) break :blk next.result;
                rowid = next.rowid;
            }
            const payload = btree.encodeRecord(allocator, values) catch |err| break :blk if (err == error.OutOfMemory) .no_memory else .too_big;
            defer allocator.free(payload);
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const rc = database.insertTable(action.root_page, rowid, payload, action.replace);
            if (rc == .constraint and action.conflict_ignore) {
                action.connection.changes = 0;
                break :blk .ok;
            }
            if (rc == .ok) {
                action.connection.changes = 1;
                action.connection.total_changes += 1;
                action.connection.last_insert_rowid = rowid;
            }
            break :blk action.connection.afterWrite(rc, 18, action.table_name, rowid);
        },
    };
}

fn compileVirtualDrop(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    const owner = allocator.create(Owner) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instructions = allocator.alloc(vdbe.Instruction, 2) catch {
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, 0) catch unreachable;
    instructions[0] = .{ .opcode = .function, .p1 = 0, .p2 = 1, .p3 = 1, .p4 = .{ .index = 0 } };
    instructions[1] = .{ .opcode = .halt };
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = .{ .virtual_drop = .{ .connection = connection, .name = token_list[2].text } }, .program = .{ .instructions = instructions, .register_count = 1 } };
    owner.functions[0] = .{ .callback = programActionCallback, .context = owner };
    owner.program.functions = owner.functions[0..];
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    prepared.markWritable();
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compileVirtualSchema(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (token_list.len != 6 or token_list[0].typ != tokens.tk_create or token_list[1].typ != tokens.tk_virtual or token_list[2].typ != tokens.tk_table or token_list[3].typ != tokens.tk_id or token_list[4].typ != tokens.tk_using or token_list[5].typ != tokens.tk_id) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    for (connection.virtual_tables.items) |table| if (std.ascii.eqlIgnoreCase(table.name, token_list[3].text)) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    };
    var module_found = false;
    for (connection.modules.items) |module| if (std.ascii.eqlIgnoreCase(module.name, token_list[5].text)) {
        module_found = true;
        break;
    };
    if (!module_found) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const owner = allocator.create(Owner) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instructions = allocator.alloc(vdbe.Instruction, 2) catch {
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, 0) catch unreachable;
    instructions[0] = .{ .opcode = .function, .p1 = 0, .p2 = 1, .p3 = 1, .p4 = .{ .index = 0 } };
    instructions[1] = .{ .opcode = .halt };
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = .{ .virtual_create = .{ .connection = connection, .name = token_list[3].text, .module_name = token_list[5].text } }, .program = .{ .instructions = instructions, .register_count = 1 } };
    owner.functions[0] = .{ .callback = programActionCallback, .context = owner };
    owner.program.functions = owner.functions[0..];
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    prepared.markWritable();
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compileSchema(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (connection.database == null) {
        allocator.free(source);
        return .{ .result = .misuse, .consumed = consumed };
    }
    if (token_list.len > 1 and token_list[0].typ == tokens.tk_create and token_list[1].typ == tokens.tk_virtual) return compileVirtualSchema(connection, source, token_list, consumed);
    if (token_list.len == 3 and token_list[0].typ == tokens.tk_drop and token_list[1].typ == tokens.tk_table and token_list[2].typ == tokens.tk_id) for (connection.virtual_tables.items) |table| if (std.ascii.eqlIgnoreCase(table.name, token_list[2].text)) return compileVirtualDrop(connection, source, token_list, consumed);
    var position: usize = 0;
    const creating = token_list[position].typ == tokens.tk_create;
    const dropping = token_list[position].typ == tokens.tk_drop;
    if (!creating and !dropping) unreachable;
    position += 1;
    if (position >= token_list.len or token_list[position].typ != tokens.tk_table) {
        const offset = if (position < token_list.len) token_list[position].start else source.len;
        allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = consumed };
    }
    position += 1;
    var conditional = false;
    if (position + 1 < token_list.len and token_list[position].typ == tokens.tk_if) {
        if ((creating and token_list[position + 1].typ == tokens.tk_not and position + 2 < token_list.len and token_list[position + 2].typ == tokens.tk_exists) or
            (dropping and token_list[position + 1].typ == tokens.tk_exists))
        {
            conditional = true;
            position += if (creating) 3 else 2;
        }
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_id) {
        const offset = if (position < token_list.len) token_list[position].start else source.len;
        allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = consumed };
    }
    const name = token_list[position].text;
    position += 1;
    if (creating) {
        if (position >= token_list.len or token_list[position].typ != tokens.tk_lp or token_list[token_list.len - 1].typ != tokens.tk_rp or position + 2 > token_list.len) {
            allocator.free(source);
            return .{ .result = .error_, .error_offset = @intCast(if (position < token_list.len) token_list[position].start else source.len), .consumed = consumed };
        }
        var depth: usize = 0;
        for (token_list[position..], position..) |token, index| {
            if (token.typ == tokens.tk_lp) depth += 1;
            if (token.typ == tokens.tk_rp) {
                if (depth == 0) {
                    allocator.free(source);
                    return .{ .result = .error_, .error_offset = @intCast(token.start), .consumed = consumed };
                }
                depth -= 1;
                if (depth == 0 and index + 1 != token_list.len) {
                    allocator.free(source);
                    return .{ .result = .error_, .error_offset = @intCast(token.end), .consumed = consumed };
                }
            }
        }
        if (depth != 0 or position + 1 == token_list.len) {
            allocator.free(source);
            return .{ .result = .error_, .error_offset = @intCast(source.len), .consumed = consumed };
        }
    } else if (position != token_list.len) {
        const offset = token_list[position].start;
        allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = consumed };
    }
    const existence = connection.database.?.schemaTableExists(name);
    if (existence.result != .ok) {
        allocator.free(source);
        return .{ .result = existence.result, .consumed = consumed };
    }
    if ((creating and existence.found and !conditional) or (dropping and !existence.found and !conditional)) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const owner = allocator.create(Owner) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instructions = allocator.alloc(vdbe.Instruction, 2) catch {
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, 0) catch unreachable;
    instructions[0] = .{ .opcode = .function, .p1 = 0, .p2 = 1, .p3 = 1, .p4 = .{ .index = 0 } };
    instructions[1] = .{ .opcode = .halt };
    owner.* = .{
        .source = source,
        .instructions = instructions,
        .parameters = parameters,
        .columns = columns,
        .action = if (creating)
            .{ .create = .{ .connection = connection, .name = name, .sql = std.mem.trim(u8, source[0..token_list[token_list.len - 1].end], " \t\r\n"), .if_not_exists = conditional } }
        else
            .{ .drop = .{ .connection = connection, .name = name, .if_exists = conditional } },
        .program = .{ .instructions = instructions, .register_count = 1 },
    };
    owner.functions[0] = .{ .callback = programActionCallback, .context = owner };
    owner.program.functions = owner.functions[0..];
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    prepared.markWritable();
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn buildInsert(connection: *Connection, source: [:0]u8, token_list: []const Token) !*statement.Statement {
    const allocator = connection.allocator;
    const database = connection.database orelse return error.Misuse;
    var position: usize = 1;
    var replace = false;
    if (position + 1 < token_list.len and token_list[position].typ == tokens.tk_or and token_list[position + 1].typ == tokens.tk_replace) {
        replace = true;
        position += 2;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_into) return error.Syntax;
    position += 1;
    if (position >= token_list.len or token_list[position].typ != tokens.tk_id) return error.Syntax;
    const table_name = token_list[position].text;
    const schema_outcome = database.schemaTable(table_name);
    if (schema_outcome.result == .no_memory) return error.OutOfMemory;
    if (schema_outcome.result != .ok) return error.Syntax;
    var schema = schema_outcome.table.?;
    defer schema.deinit();
    const resolved = try resolveColumns(allocator, schema.sql);
    defer {
        allocator.free(resolved.columns);
        allocator.free(resolved.tokens);
        allocator.free(resolved.source);
    }
    position += 1;
    var mappings = std.ArrayList(usize).empty;
    defer mappings.deinit(allocator);
    if (position < token_list.len and token_list[position].typ == tokens.tk_lp) {
        position += 1;
        while (true) {
            if (position >= token_list.len or token_list[position].typ != tokens.tk_id) return error.Syntax;
            var found: ?usize = null;
            for (resolved.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, token_list[position].text)) {
                found = index;
                break;
            };
            const column_index = found orelse return error.Syntax;
            for (mappings.items) |prior| if (prior == column_index) return error.Syntax;
            try mappings.append(allocator, column_index);
            position += 1;
            if (position < token_list.len and token_list[position].typ == tokens.tk_comma) {
                position += 1;
                continue;
            }
            if (position >= token_list.len or token_list[position].typ != tokens.tk_rp) return error.Syntax;
            position += 1;
            break;
        }
    } else {
        for (resolved.columns, 0..) |_, index| try mappings.append(allocator, index);
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_values) return error.Syntax;
    position += 1;
    if (position >= token_list.len or token_list[position].typ != tokens.tk_lp) return error.Syntax;
    position += 1;
    const scanned = try scanParameters(allocator, token_list);
    var parser = Parser.init(allocator, source, token_list, scanned.maximum, null);
    var parser_live = true;
    defer if (parser_live) parser.deinitFailure();
    parser.parameter_names.appendSlice(allocator, scanned.names) catch {
        allocator.free(scanned.names);
        var owned = scanned.owned;
        for (owned.items) |name| allocator.free(name);
        owned.deinit(allocator);
        var map = scanned.map;
        map.deinit();
        return error.OutOfMemory;
    };
    allocator.free(scanned.names);
    parser.names = scanned.owned;
    parser.named_parameters.deinit();
    parser.named_parameters = scanned.map;
    parser.position = position;
    var value_registers = std.ArrayList(u16).empty;
    defer value_registers.deinit(allocator);
    while (true) {
        try value_registers.append(allocator, try parser.expression(0));
        if (parser.accept(tokens.tk_comma)) continue;
        _ = try parser.require(tokens.tk_rp);
        break;
    }
    var conflict_ignore = false;
    if (parser.position != token_list.len) {
        if (parser.position + 4 != token_list.len or token_list[parser.position].typ != tokens.tk_on or token_list[parser.position + 1].typ != tokens.tk_conflict or token_list[parser.position + 2].typ != tokens.tk_do or token_list[parser.position + 3].typ != tokens.tk_nothing) return error.Syntax;
        conflict_ignore = true;
        parser.position = token_list.len;
    }
    if (value_registers.items.len != mappings.items.len) return error.Syntax;
    const argument_first = parser.next_register;
    for (value_registers.items) |value_register| {
        const target = try parser.allocateRegister();
        try parser.emit(.{ .opcode = .copy, .p1 = value_register, .p2 = target });
    }
    const output = try parser.allocateRegister();
    try parser.emit(.{ .opcode = .function, .p1 = @intCast(mappings.items.len), .p2 = argument_first, .p3 = output, .p4 = .{ .index = 0 } });
    try parser.emit(.{ .opcode = .halt });
    const owner = try allocator.create(Owner);
    errdefer allocator.destroy(owner);
    const instructions = try parser.instructions.toOwnedSlice(allocator);
    parser.instructions = .empty;
    errdefer allocator.free(instructions);
    const parameters = try allocator.alloc(statement.ParameterMetadata, parser.maximum_parameter);
    errdefer allocator.free(parameters);
    for (parameters, 0..) |*parameter, index| parameter.* = .{ .name = parser.parameter_names.items[index] };
    const columns = try allocator.alloc(statement.ColumnMetadata, 0);
    errdefer allocator.free(columns);
    const indices = try allocator.dupe(usize, mappings.items);
    errdefer allocator.free(indices);
    var integer_primary_key: ?usize = null;
    for (resolved.columns, 0..) |column, index| if (column.integer_primary_key) {
        integer_primary_key = index;
        break;
    };
    parser.parameter_names.deinit(allocator);
    parser.parameter_names = .empty;
    parser.named_parameters.deinit();
    parser.named_parameters = std.StringHashMap(u16).init(allocator);
    owner.* = .{
        .source = source,
        .instructions = instructions,
        .parameters = parameters,
        .columns = columns,
        .strings = parser.strings,
        .names = parser.names,
        .action = .{ .insert = .{ .connection = connection, .root_page = schema.root_page, .table_name = table_name, .column_count = resolved.columns.len, .integer_primary_key = integer_primary_key, .replace = replace, .conflict_ignore = conflict_ignore } },
        .indices = indices,
        .program = .{ .instructions = instructions, .register_count = parser.next_register - 1 },
    };
    owner.functions[0] = .{ .callback = programActionCallback, .context = owner };
    owner.program.functions = owner.functions[0..];
    const prepared = try statement.Statement.create(allocator, &owner.program, parameters, columns);
    parser_live = false;
    prepared.adoptOwner(owner, Owner.destroy);
    prepared.markWritable();
    return prepared;
}

fn buildRowMutation(connection: *Connection, source: [:0]u8, token_list: []const Token, updating: bool) !*statement.Statement {
    const allocator = connection.allocator;
    const database = connection.database orelse return error.Misuse;
    var position: usize = 1;
    if (!updating) {
        if (position >= token_list.len or token_list[position].typ != tokens.tk_from) return error.Syntax;
        position += 1;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_id) return error.Syntax;
    const table_name = token_list[position].text;
    const schema_outcome = database.schemaTable(table_name);
    if (schema_outcome.result == .no_memory) return error.OutOfMemory;
    if (schema_outcome.result != .ok) return error.Syntax;
    var schema = schema_outcome.table.?;
    defer schema.deinit();
    const resolved = try resolveColumns(allocator, schema.sql);
    defer {
        allocator.free(resolved.columns);
        allocator.free(resolved.tokens);
        allocator.free(resolved.source);
    }
    var primary_key: ?usize = null;
    for (resolved.columns, 0..) |column, index| if (column.integer_primary_key) {
        primary_key = index;
        break;
    };
    const pk = primary_key orelse return error.Syntax;
    position += 1;
    var target_column: usize = 0;
    if (updating) {
        if (position >= token_list.len or token_list[position].typ != tokens.tk_set) return error.Syntax;
        position += 1;
        if (position >= token_list.len or token_list[position].typ != tokens.tk_id) return error.Syntax;
        var found: ?usize = null;
        for (resolved.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, token_list[position].text)) {
            found = index;
            break;
        };
        target_column = found orelse return error.Syntax;
        if (target_column == pk) return error.Syntax;
        position += 1;
        if (position >= token_list.len or token_list[position].typ != tokens.tk_eq) return error.Syntax;
        position += 1;
    } else {
        if (position >= token_list.len or token_list[position].typ != tokens.tk_where) return error.Syntax;
        position += 1;
        if (position >= token_list.len or token_list[position].typ != tokens.tk_id or !std.ascii.eqlIgnoreCase(resolved.columns[pk].name, token_list[position].text)) return error.Syntax;
        position += 1;
        if (position >= token_list.len or token_list[position].typ != tokens.tk_eq) return error.Syntax;
        position += 1;
    }
    const scanned = try scanParameters(allocator, token_list);
    var parser = Parser.init(allocator, source, token_list, scanned.maximum, null);
    var parser_live = true;
    defer if (parser_live) parser.deinitFailure();
    parser.parameter_names.appendSlice(allocator, scanned.names) catch {
        allocator.free(scanned.names);
        var owned = scanned.owned;
        for (owned.items) |name| allocator.free(name);
        owned.deinit(allocator);
        var map = scanned.map;
        map.deinit();
        return error.OutOfMemory;
    };
    allocator.free(scanned.names);
    parser.names = scanned.owned;
    parser.named_parameters.deinit();
    parser.named_parameters = scanned.map;
    parser.position = position;
    var value_registers: [2]u16 = undefined;
    var value_count: usize = 0;
    if (updating) {
        value_registers[0] = try parser.expression(0);
        value_count = 1;
        _ = try parser.require(tokens.tk_where);
        const where_column = try parser.require(tokens.tk_id);
        if (!std.ascii.eqlIgnoreCase(where_column.text, resolved.columns[pk].name)) return error.Syntax;
        _ = try parser.require(tokens.tk_eq);
    }
    value_registers[value_count] = try parser.expression(0);
    value_count += 1;
    if (parser.position != token_list.len) return error.Syntax;
    const argument_first = parser.next_register;
    for (value_registers[0..value_count]) |value_register| {
        const target = try parser.allocateRegister();
        try parser.emit(.{ .opcode = .copy, .p1 = value_register, .p2 = target });
    }
    const output = try parser.allocateRegister();
    try parser.emit(.{ .opcode = .function, .p1 = @intCast(value_count), .p2 = argument_first, .p3 = output, .p4 = .{ .index = 0 } });
    try parser.emit(.{ .opcode = .halt });
    const owner = try allocator.create(Owner);
    errdefer allocator.destroy(owner);
    const instructions = try parser.instructions.toOwnedSlice(allocator);
    parser.instructions = .empty;
    errdefer allocator.free(instructions);
    const parameters = try allocator.alloc(statement.ParameterMetadata, parser.maximum_parameter);
    errdefer allocator.free(parameters);
    for (parameters, 0..) |*parameter, index| parameter.* = .{ .name = parser.parameter_names.items[index] };
    const columns = try allocator.alloc(statement.ColumnMetadata, 0);
    errdefer allocator.free(columns);
    parser.parameter_names.deinit(allocator);
    parser.parameter_names = .empty;
    parser.named_parameters.deinit();
    parser.named_parameters = std.StringHashMap(u16).init(allocator);
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .strings = parser.strings, .names = parser.names, .action = if (updating) .{ .update = .{ .connection = connection, .root_page = schema.root_page, .table_name = table_name, .target_column = target_column } } else .{ .delete = .{ .connection = connection, .root_page = schema.root_page, .table_name = table_name } }, .program = .{ .instructions = instructions, .register_count = parser.next_register - 1 } };
    owner.functions[0] = .{ .callback = programActionCallback, .context = owner };
    owner.program.functions = owner.functions[0..];
    const prepared = try statement.Statement.create(allocator, &owner.program, parameters, columns);
    parser_live = false;
    prepared.adoptOwner(owner, Owner.destroy);
    prepared.markWritable();
    return prepared;
}

fn compileRowMutation(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize, updating: bool) CompileOutcome {
    const prepared = buildRowMutation(connection, source, token_list, updating) catch |err| {
        connection.allocator.free(source);
        return .{ .result = switch (err) {
            error.OutOfMemory => .no_memory,
            error.TooBig => .too_big,
            error.Misuse => .misuse,
            else => .error_,
        }, .consumed = consumed };
    };
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compileInsert(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const prepared = buildInsert(connection, source, token_list) catch |err| {
        connection.allocator.free(source);
        return .{ .result = switch (err) {
            error.OutOfMemory => .no_memory,
            error.TooBig => .too_big,
            error.Misuse => .misuse,
            else => .error_,
        }, .consumed = consumed };
    };
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compileAdvanced(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    const is_vacuum = token_list.len == 1 and token_list[0].typ == tokens.tk_vacuum;
    const is_pragma = token_list.len == 2 and token_list[0].typ == tokens.tk_pragma and token_list[1].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(token_list[1].text, "user_version");
    const is_window = token_list.len == 7 and token_list[0].typ == tokens.tk_select and token_list[1].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(token_list[1].text, "row_number") and token_list[2].typ == tokens.tk_lp and token_list[3].typ == tokens.tk_rp and token_list[4].typ == tokens.tk_over and token_list[5].typ == tokens.tk_lp and token_list[6].typ == tokens.tk_rp;
    if (!is_vacuum and !is_pragma and !is_window) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const database = connection.database orelse {
        allocator.free(source);
        return .{ .result = .misuse, .consumed = consumed };
    };
    var value: i32 = 1;
    if (is_pragma) {
        const read = database.userVersion();
        if (read.result != .ok or read.value > std.math.maxInt(i32)) {
            allocator.free(source);
            return .{ .result = if (read.result == .ok) .too_big else read.result, .consumed = consumed };
        }
        value = @intCast(read.value);
    }
    const instruction_count: usize = if (is_vacuum) 2 else 3;
    const owner = allocator.create(Owner) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instructions = allocator.alloc(vdbe.Instruction, instruction_count) catch {
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, if (is_vacuum) 0 else 1) catch {
        allocator.free(parameters);
        allocator.free(instructions);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = if (is_vacuum) .{ .vacuum = .{ .connection = connection } } else null, .program = .{ .instructions = instructions, .register_count = 1 } };
    if (is_vacuum) {
        instructions[0] = .{ .opcode = .function, .p1 = 0, .p2 = 1, .p3 = 1, .p4 = .{ .index = 0 } };
        instructions[1] = .{ .opcode = .halt };
        owner.functions[0] = .{ .callback = programActionCallback, .context = owner };
        owner.program.functions = owner.functions[0..];
    } else {
        instructions[0] = .{ .opcode = .integer, .p1 = value, .p2 = 1 };
        instructions[1] = .{ .opcode = .result_row, .p1 = 1, .p2 = 1 };
        instructions[2] = .{ .opcode = .halt };
        const name = allocator.dupeZ(u8, if (is_pragma) "user_version" else "row_number() OVER ()") catch {
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        owner.names.append(allocator, name) catch {
            allocator.free(name);
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        columns[0] = .{ .name = name };
    }
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    if (is_vacuum) prepared.markWritable();
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn compile(connection: *Connection, source_bytes: []const u8) CompileOutcome {
    const allocator = connection.allocator;
    const source = allocator.dupeZ(u8, source_bytes) catch return .{ .result = .no_memory };
    const tokenized = tokenize(allocator, source) catch |err| {
        allocator.free(source);
        return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .error_offset = 0 };
    };
    defer allocator.free(tokenized.tokens);
    if (tokenized.tokens.len == 0) {
        allocator.free(source);
        return .{ .result = .ok, .consumed = tokenized.consumed };
    }
    if (tokenized.tokens[0].typ == tokens.tk_pragma or tokenized.tokens[0].typ == tokens.tk_vacuum or
        (tokenized.tokens[0].typ == tokens.tk_select and tokenized.tokens.len > 1 and tokenized.tokens[1].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(tokenized.tokens[1].text, "row_number")))
        return compileAdvanced(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_create or tokenized.tokens[0].typ == tokens.tk_drop)
        return compileSchema(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_insert)
        return compileInsert(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_update or tokenized.tokens[0].typ == tokens.tk_delete)
        return compileRowMutation(connection, source, tokenized.tokens, tokenized.consumed, tokenized.tokens[0].typ == tokens.tk_update);
    if (tokenized.tokens[0].typ != tokens.tk_select) {
        allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(tokenized.tokens[0].start), .consumed = tokenized.consumed };
    }
    var depth: usize = 0;
    for (tokenized.tokens[1..], 1..) |token, position| {
        if (token.typ == tokens.tk_lp) depth += 1;
        if (token.typ == tokens.tk_rp and depth > 0) depth -= 1;
        if (token.typ == tokens.tk_from and depth == 0)
            return compileTableScan(connection, source, tokenized.tokens, tokenized.consumed, position);
    }
    const scanned = scanParameters(allocator, tokenized.tokens) catch |err| {
        allocator.free(source);
        return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .error_offset = 0, .consumed = tokenized.consumed };
    };
    var parser = Parser.init(allocator, source, tokenized.tokens, scanned.maximum, connection);
    parser.parameter_names.appendSlice(allocator, scanned.names) catch {
        allocator.free(scanned.names);
        var owned = scanned.owned;
        for (owned.items) |name| allocator.free(name);
        owned.deinit(allocator);
        var map = scanned.map;
        map.deinit();
        parser.deinitFailure();
        allocator.free(source);
        return .{ .result = .no_memory };
    };
    allocator.free(scanned.names);
    parser.names = scanned.owned;
    parser.named_parameters.deinit();
    parser.named_parameters = scanned.map;
    parser.position = 1;
    var results = std.ArrayList(u16).empty;
    defer results.deinit(allocator);
    var ranges = std.ArrayList(struct { usize, usize }).empty;
    defer ranges.deinit(allocator);
    while (true) {
        const start = if (parser.current()) |token| token.start else source.len;
        const result = parser.expression(0) catch |err| {
            const offset = parser.error_offset;
            parser.deinitFailure();
            allocator.free(source);
            return .{ .result = if (err == error.OutOfMemory) .no_memory else if (err == error.TooBig) .too_big else .error_, .error_offset = @intCast(offset), .consumed = tokenized.consumed };
        };
        const end = if (parser.position == 0) start else parser.token_list[parser.position - 1].end;
        results.append(allocator, result) catch {
            parser.deinitFailure();
            allocator.free(source);
            return .{ .result = .no_memory };
        };
        ranges.append(allocator, .{ start, end }) catch {
            parser.deinitFailure();
            allocator.free(source);
            return .{ .result = .no_memory };
        };
        if (!parser.accept(tokens.tk_comma)) break;
    }
    if (parser.position != parser.token_list.len) {
        const offset = parser.current().?.start;
        parser.deinitFailure();
        allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = tokenized.consumed };
    }
    const output_first = parser.next_register;
    for (results.items, 0..) |result, index| {
        const output = parser.allocateRegister() catch {
            parser.deinitFailure();
            allocator.free(source);
            return .{ .result = .too_big };
        };
        parser.emit(.{ .opcode = .copy, .p1 = result, .p2 = output }) catch {
            parser.deinitFailure();
            allocator.free(source);
            return .{ .result = .no_memory };
        };
        _ = index;
    }
    parser.emit(.{ .opcode = .result_row, .p1 = output_first, .p2 = @intCast(results.items.len) }) catch {
        parser.deinitFailure();
        allocator.free(source);
        return .{ .result = .no_memory };
    };
    parser.emit(.{ .opcode = .halt }) catch {
        parser.deinitFailure();
        allocator.free(source);
        return .{ .result = .no_memory };
    };
    const owner = allocator.create(Owner) catch {
        parser.deinitFailure();
        allocator.free(source);
        return .{ .result = .no_memory };
    };
    errdefer allocator.destroy(owner);
    const instructions = parser.instructions.toOwnedSlice(allocator) catch {
        parser.deinitFailure();
        allocator.free(source);
        allocator.destroy(owner);
        return .{ .result = .no_memory };
    };
    parser.instructions = .empty;
    const parameters = allocator.alloc(statement.ParameterMetadata, parser.maximum_parameter) catch {
        allocator.free(instructions);
        parser.deinitFailure();
        allocator.free(source);
        allocator.destroy(owner);
        return .{ .result = .no_memory };
    };
    for (parameters, 0..) |*parameter, index| parameter.* = .{ .name = parser.parameter_names.items[index] };
    const columns = allocator.alloc(statement.ColumnMetadata, results.items.len) catch {
        allocator.free(parameters);
        allocator.free(instructions);
        parser.deinitFailure();
        allocator.free(source);
        allocator.destroy(owner);
        return .{ .result = .no_memory };
    };
    for (columns, ranges.items) |*column, range| {
        const name = parser.ownName(std.mem.trim(u8, source[range[0]..range[1]], " \t\r\n")) catch {
            allocator.free(columns);
            allocator.free(parameters);
            allocator.free(instructions);
            parser.deinitFailure();
            allocator.free(source);
            allocator.destroy(owner);
            return .{ .result = .no_memory };
        };
        column.* = .{ .name = name };
    }
    const dynamic_functions = parser.functions.toOwnedSlice(allocator) catch {
        allocator.free(columns);
        allocator.free(parameters);
        allocator.free(instructions);
        parser.deinitFailure();
        allocator.free(source);
        allocator.destroy(owner);
        return .{ .result = .no_memory };
    };
    parser.functions = .empty;
    parser.parameter_names.deinit(allocator);
    parser.named_parameters.deinit();
    owner.* = .{
        .source = source,
        .instructions = instructions,
        .parameters = parameters,
        .columns = columns,
        .strings = parser.strings,
        .names = parser.names,
        .dynamic_functions = dynamic_functions,
        .program = .{ .instructions = instructions, .register_count = parser.next_register - 1, .functions = dynamic_functions },
    };
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch {
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory };
    };
    prepared.adoptOwner(owner, Owner.destroy);
    return .{ .result = .ok, .statement = prepared, .consumed = tokenized.consumed };
}

fn inputLength(sql: [*:0]const u8, byte_count: c_int) usize {
    if (byte_count < 0) return std.mem.len(sql);
    const maximum: usize = @intCast(byte_count);
    var length: usize = 0;
    while (length < maximum and sql[length] != 0) length += 1;
    return length;
}

fn prepareUtf8(
    database: ?*sqlite3,
    sql_pointer: ?[*:0]const u8,
    byte_count: c_int,
    statement_output: ?*?*statement.sqlite3_stmt,
    tail_output: ?*?[*:0]const u8,
) c_int {
    const connection = asConnection(database) orelse return ResultCode.misuse.toC();
    const output = statement_output orelse return ResultCode.misuse.toC();
    output.* = null;
    const sql = sql_pointer orelse return ResultCode.misuse.toC();
    const length = inputLength(sql, byte_count);
    if (connection.authorizer_callback) |callback| {
        var first: usize = 0;
        while (first < length and std.ascii.isWhitespace(sql[first])) : (first += 1) {}
        const source = sql[first..length];
        const action: c_int = if (std.ascii.startsWithIgnoreCase(source, "SELECT")) 21 else if (std.ascii.startsWithIgnoreCase(source, "INSERT")) 18 else if (std.ascii.startsWithIgnoreCase(source, "UPDATE")) 23 else if (std.ascii.startsWithIgnoreCase(source, "DELETE")) 9 else if (std.ascii.startsWithIgnoreCase(source, "CREATE TABLE")) 2 else if (std.ascii.startsWithIgnoreCase(source, "DROP TABLE")) 11 else if (std.ascii.startsWithIgnoreCase(source, "PRAGMA")) 19 else 0;
        if (action != 0 and callback(connection.authorizer_context, action, null, null, "main", null) != 0) {
            connection.last_result = .auth;
            connection.error_offset = 0;
            return ResultCode.auth.toC();
        }
    }
    const outcome = compile(connection, sql[0..length]);
    connection.last_result = outcome.result;
    connection.error_offset = outcome.error_offset;
    if (tail_output) |tail| tail.* = sql + outcome.consumed;
    if (outcome.statement) |prepared| {
        prepared.setSql(sql[0..outcome.consumed]) catch {
            _ = statement.sqlite3_finalize(statement.toOpaque(prepared));
            connection.last_result = .no_memory;
            return ResultCode.no_memory.toC();
        };
        if (connection.progress_callback != null) prepared.vm.setProgressHandler(connection.progress_interval, Connection.vmProgress, connection);
        if (connection.legacy_trace_callback != null or connection.legacy_profile_callback != null or connection.trace_v2_callback != null) prepared.setEventCallback(connection, Connection.statementEvent);
        prepared.connection_next = connection.statement_head;
        if (connection.statement_head) |head| head.connection_previous = prepared;
        connection.statement_head = prepared;
        connection.active_statements += 1;
        prepared.onFinalize(connection, Connection.statementFinalized, &connection.interrupted);
        output.* = statement.toOpaque(prepared);
    }
    return outcome.result.toC();
}

pub export fn sqlite3_prepare(database: ?*sqlite3, sql: ?[*:0]const u8, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?[*:0]const u8) callconv(.c) c_int {
    return prepareUtf8(database, sql, byte_count, output, tail);
}

pub export fn sqlite3_prepare_v2(database: ?*sqlite3, sql: ?[*:0]const u8, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?[*:0]const u8) callconv(.c) c_int {
    return prepareUtf8(database, sql, byte_count, output, tail);
}

pub export fn sqlite3_prepare_v3(database: ?*sqlite3, sql: ?[*:0]const u8, byte_count: c_int, flags: u32, output: ?*?*statement.sqlite3_stmt, tail: ?*?[*:0]const u8) callconv(.c) c_int {
    if (flags & ~@as(u32, 0x0f) != 0) return ResultCode.misuse.toC();
    return prepareUtf8(database, sql, byte_count, output, tail);
}

fn prepareUtf16(database: ?*sqlite3, sql_pointer: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail_output: ?*?*const anyopaque, flags: u32) c_int {
    const connection = asConnection(database) orelse return ResultCode.misuse.toC();
    const statement_pointer = output orelse return ResultCode.misuse.toC();
    statement_pointer.* = null;
    const raw = sql_pointer orelse return ResultCode.misuse.toC();
    const bytes: [*]const u8 = @ptrCast(@alignCast(raw));
    var length: usize = if (byte_count < 0) 0 else @intCast(byte_count & ~@as(c_int, 1));
    if (byte_count < 0) {
        while (bytes[length] != 0 or bytes[length + 1] != 0) : (length += 2) {}
    }
    const units = connection.allocator.alloc(u16, length / 2) catch return ResultCode.no_memory.toC();
    defer connection.allocator.free(units);
    for (units, 0..) |*unit, index| unit.* = @as(u16, bytes[index * 2]) | (@as(u16, bytes[index * 2 + 1]) << 8);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(connection.allocator, units) catch return ResultCode.no_memory.toC();
    defer connection.allocator.free(utf8);
    if (flags & ~@as(u32, 0x0f) != 0) return ResultCode.misuse.toC();
    const source = connection.allocator.dupeZ(u8, utf8) catch return ResultCode.no_memory.toC();
    defer connection.allocator.free(source);
    var utf8_tail: ?[*:0]const u8 = null;
    const rc = prepareUtf8(database, source.ptr, @intCast(source.len), output, &utf8_tail);
    if (tail_output) |tail| {
        const consumed_utf8: usize = if (utf8_tail) |value| @intCast(@intFromPtr(value) - @intFromPtr(source.ptr)) else source.len;
        const view = std.unicode.Utf8View.init(source[0..consumed_utf8]) catch {
            tail.* = @ptrCast(bytes + length);
            return rc;
        };
        var iterator = view.iterator();
        var unit_count: usize = 0;
        while (iterator.nextCodepoint()) |codepoint| unit_count += if (codepoint > 0xffff) 2 else 1;
        tail.* = @ptrCast(bytes + unit_count * 2);
    }
    return rc;
}

pub export fn sqlite3_prepare16(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepareUtf16(database, sql, byte_count, output, tail, 0);
}

pub export fn sqlite3_prepare16_v2(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepareUtf16(database, sql, byte_count, output, tail, 0);
}

pub export fn sqlite3_prepare16_v3(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, flags: u32, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepareUtf16(database, sql, byte_count, output, tail, flags);
}

test "expression SELECT prepare bind step reset tail and syntax errors" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    const sql: [:0]const u8 = "SELECT ?1 + 2, 'a' || :name, NULL, -5; SELECT 9";
    var prepared: ?*statement.sqlite3_stmt = null;
    var tail: ?[*:0]const u8 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), sql.ptr, -1, &prepared, &tail));
    try std.testing.expect(prepared != null);
    try std.testing.expectEqualStrings(" SELECT 9", std.mem.span(tail.?));
    try std.testing.expectEqual(@as(c_int, 2), statement.sqlite3_bind_parameter_count(prepared));
    try std.testing.expectEqual(@as(c_int, 1), statement.sqlite3_bind_parameter_index(prepared, "?1"));
    try std.testing.expectEqual(@as(c_int, 2), statement.sqlite3_bind_parameter_index(prepared, ":name"));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_bind_int(prepared, 1, 40));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_bind_text(prepared, 2, "bc", 2, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqualStrings("abc", std.mem.span(statement.sqlite3_column_text(prepared, 1).?));
    try std.testing.expectEqual(@as(c_int, 5), statement.sqlite3_column_type(prepared, 2));
    try std.testing.expectEqual(@as(i64, -5), statement.sqlite3_column_int64(prepared, 3));
    try std.testing.expectEqualStrings("?1 + 2", std.mem.span(statement.sqlite3_column_name(prepared, 0).?));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_reset(prepared));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));

    prepared = @ptrFromInt(1);
    try std.testing.expectEqual(ResultCode.error_.toC(), sqlite3_prepare_v2(toOpaque(connection), "SELECT )", -1, &prepared, null));
    try std.testing.expectEqual(@as(?*statement.sqlite3_stmt, null), prepared);
    try std.testing.expect(connection.error_offset >= 0);
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_prepare_v3(toOpaque(connection), "SELECT 1", -1, 0x8000_0000, &prepared, null));
}

test "UTF-16 prepare executes expression SELECT" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    const sql = [_:0]u16{ 'S', 'E', 'L', 'E', 'C', 'T', ' ', '6', '*', '7', 0 };
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare16_v2(toOpaque(connection), &sql, -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

fn sqlAllocationExercise(allocator: std.mem.Allocator) !void {
    const connection = Connection.create(allocator) catch return error.OutOfMemory;
    defer connection.destroy();
    var prepared: ?*statement.sqlite3_stmt = null;
    const rc = sqlite3_prepare_v2(toOpaque(connection), "SELECT ?1*2, 'allocation'||:name, x'00ff'", -1, &prepared, null);
    if (rc == ResultCode.no_memory.toC()) return error.OutOfMemory;
    if (rc != ResultCode.ok.toC()) return error.UnexpectedResult;
    const handle = prepared.?;
    const bind_rc = statement.sqlite3_bind_text(handle, 2, "value", -1, null);
    if (bind_rc == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(handle);
        return error.OutOfMemory;
    }
    if (bind_rc != ResultCode.ok.toC()) return error.UnexpectedResult;
    if (statement.sqlite3_bind_int(handle, 1, 21) != ResultCode.ok.toC()) return error.UnexpectedResult;
    const step_rc = statement.sqlite3_step(handle);
    if (step_rc == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(handle);
        return error.OutOfMemory;
    }
    if (step_rc != ResultCode.row.toC()) return error.UnexpectedResult;
    if (statement.sqlite3_finalize(handle) != ResultCode.ok.toC()) return error.UnexpectedResult;
}

test "SQL expression preparation survives every bounded allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sqlAllocationExercise, .{});
}

test "escaped literals comments duplicate parameters and explicit byte bounds" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    const sql: [:0]const u8 = " /* lead */ SELECT :x + :x, 'it''s'; ignored";
    var prepared: ?*statement.sqlite3_stmt = null;
    var tail: ?[*:0]const u8 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v3(toOpaque(connection), sql.ptr, @intCast(sql.len), 0, &prepared, &tail));
    try std.testing.expectEqual(@as(c_int, 1), statement.sqlite3_bind_parameter_count(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_bind_int(prepared, 1, 4));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 8), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqualStrings("it's", std.mem.span(statement.sqlite3_column_text(prepared, 1).?));
    try std.testing.expectEqualStrings(" ignored", std.mem.span(tail.?));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

test "schema DDL prepare creates and drops a durable table" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const opened_file = memory.open("ddl.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(btree.vfs.OK, opened_file.rc);
    try std.testing.expectEqual(btree.vfs.OK, opened_file.file.?.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, opened_file.file.?.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(opened_file.file.?));
    var adapter = btree.vfs.AbiAdapter.init("sql-schema-ddl", &memory);
    var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "ddl.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "CREATE TABLE IF NOT EXISTS created(x INTEGER, y TEXT)", -1, &prepared, null));
    try std.testing.expectEqual(@as(c_int, 0), statement.sqlite3_stmt_readonly(prepared));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    var schema = database.openCursor(1, .table).cursor.?;
    try std.testing.expectEqual(@as(usize, 2), schema.count());
    schema.deinit();
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "DROP TABLE created", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    schema = database.openCursor(1, .table).cursor.?;
    try std.testing.expectEqual(@as(usize, 1), schema.count());
    schema.deinit();
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

test "table scan SELECT resolves schema columns and emits B-tree cursor loop" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const opened_file = memory.open("scan.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(btree.vfs.OK, opened_file.rc);
    try std.testing.expectEqual(btree.vfs.OK, opened_file.file.?.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, opened_file.file.?.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(opened_file.file.?));
    var adapter = btree.vfs.AbiAdapter.init("sql-table-scan", &memory);
    var database = btree.Database.open(std.testing.allocator, &adapter.abi, "scan.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT v,id FROM t", -1, &prepared, null));
    try std.testing.expectEqual(@as(c_int, 2), statement.sqlite3_column_count(prepared));
    try std.testing.expectEqualStrings("v", std.mem.span(statement.sqlite3_column_name(prepared, 0).?));
    try std.testing.expectEqualStrings("id", std.mem.span(statement.sqlite3_column_name(prepared, 1).?));
    var rows: usize = 0;
    while (statement.sqlite3_step(prepared) == ResultCode.row.toC()) {
        rows += 1;
        try std.testing.expectEqual(@as(i64, @intCast(rows)), statement.sqlite3_column_int64(prepared, 1));
        try std.testing.expect(statement.sqlite3_column_bytes(prepared, 0) > 0);
    }
    try std.testing.expectEqual(@as(usize, 300), rows);
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT * FROM t", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 1), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

fn tableScanAllocationExercise(allocator: std.mem.Allocator, adapter: *btree.vfs.AbiAdapter) !void {
    const opened = btree.Database.open(allocator, &adapter.abi, "scan-oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer if (database.pager.state != .closed) {
        _ = database.close();
    };
    var connection = Connection.init(allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    const prepare_rc = sqlite3_prepare_v2(toOpaque(&connection), "SELECT id,v FROM t WHERE id >= 298 ORDER BY id DESC LIMIT 2", -1, &prepared, null);
    if (prepare_rc == ResultCode.no_memory.toC()) return error.OutOfMemory;
    if (prepare_rc != ResultCode.ok.toC()) return error.UnexpectedResult;
    const step_rc = statement.sqlite3_step(prepared);
    if (step_rc == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(prepared);
        return error.OutOfMemory;
    }
    if (step_rc != ResultCode.row.toC()) return error.UnexpectedResult;
    if (statement.sqlite3_finalize(prepared) != ResultCode.ok.toC()) return error.UnexpectedResult;
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "planned table scan preparation and first row survive every bounded allocation failure" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const opened_file = memory.open("scan-oom.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(btree.vfs.OK, opened_file.rc);
    try std.testing.expectEqual(btree.vfs.OK, opened_file.file.?.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, opened_file.file.?.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(opened_file.file.?));
    var adapter = btree.vfs.AbiAdapter.init("sql-table-scan-oom", &memory);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, tableScanAllocationExercise, .{&adapter});
}

test "INSERT generates values and atomic B-tree mutation" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("insert.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-insert", &memory);
    var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "insert.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(1000,x'aabb')", -1, &prepared, null));
    try std.testing.expectEqual(@as(c_int, 0), statement.sqlite3_stmt_readonly(prepared));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(1000,x'cc')", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.constraint.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.constraint.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT OR REPLACE INTO t(id,v) VALUES(1000,x'cc')", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(v) VALUES(?1)", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_bind_text(prepared, 1, "bound", -1, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    var cursor = database.openCursor(2, .table).cursor.?;
    defer cursor.deinit();
    try std.testing.expect(cursor.seekTable(1000));
    var record = cursor.record().record.?;
    try std.testing.expectEqualSlices(u8, &.{0xcc}, record.values[1].blob);
    record.deinit();
    try std.testing.expect(cursor.seekTable(1001));
    record = cursor.record().record.?;
    try std.testing.expectEqualStrings("bound", record.values[1].text);
    record.deinit();
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

fn insertAllocationExercise(allocator: std.mem.Allocator, adapter: *btree.vfs.AbiAdapter) !void {
    const opened = btree.Database.openWritable(allocator, &adapter.abi, "insert-oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer if (database.pager.state != .closed) {
        _ = database.close();
    };
    var connection = Connection.init(allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    const prepare_rc = sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(2000,?1)", -1, &prepared, null);
    if (prepare_rc == ResultCode.no_memory.toC()) return error.OutOfMemory;
    if (prepare_rc != ResultCode.ok.toC()) return error.UnexpectedResult;
    const bind_rc = statement.sqlite3_bind_text(prepared, 1, "oom", -1, null);
    if (bind_rc == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(prepared);
        return error.OutOfMemory;
    }
    const step_rc = statement.sqlite3_step(prepared);
    if (step_rc == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(prepared);
        return error.OutOfMemory;
    }
    if (step_rc != ResultCode.done.toC()) return error.UnexpectedResult;
    if (statement.sqlite3_finalize(prepared) != ResultCode.ok.toC()) return error.UnexpectedResult;
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "generated INSERT survives every bounded allocation failure" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const initial = memory.open("insert-oom.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, initial.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, initial.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(initial));
    var adapter = btree.vfs.AbiAdapter.init("sql-insert-oom", &memory);
    var completed = false;
    for (0..2048) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        insertAllocationExercise(failing.allocator(), &adapter) catch |err| try std.testing.expect(err == error.OutOfMemory);
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
        const replacement = memory.open("insert-oom.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(btree.vfs.OK, replacement.truncate(0));
        try std.testing.expectEqual(btree.vfs.OK, replacement.write(bytes, 0));
        try std.testing.expectEqual(btree.vfs.OK, replacement.sync());
        try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(replacement));
    }
    try std.testing.expect(completed);
}

test "generated INSERT rolls back VFS faults and continues" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    const cases = [_]struct { btree.vfs.Method, c_int }{ .{ .open, btree.vfs.IOERR }, .{ .lock, btree.vfs.IOERR }, .{ .write, btree.vfs.IOERR_WRITE }, .{ .sync, btree.vfs.IOERR_FSYNC }, .{ .delete, btree.vfs.IOERR_DELETE } };
    for (cases, 0..) |case, index| {
        var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "insert-fault-{d}.db", .{index});
        const file = memory.open(name, btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
        try std.testing.expectEqual(btree.vfs.OK, file.sync());
        try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
        var adapter = btree.vfs.AbiAdapter.init("sql-insert-fault", &memory);
        var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, name).database.?;
        var connection = Connection.init(std.testing.allocator, &database);
        var prepared: ?*statement.sqlite3_stmt = null;
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(2000,x'01')", -1, &prepared, null));
        var rules = [_]btree.vfs.FaultRule{.{ .method = case[0], .code = case[1] }};
        var faults = btree.vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        try std.testing.expectEqual(ResultCode.fromC(case[1]).toC(), statement.sqlite3_step(prepared));
        _ = statement.sqlite3_finalize(prepared);
        memory.faults = null;
        var cursor = database.openCursor(2, .table).cursor.?;
        try std.testing.expect(!cursor.seekTable(2000));
        cursor.deinit();
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(2000,x'01')", -1, &prepared, null));
        try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
        try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
        try std.testing.expectEqual(ResultCode.ok, database.close());
    }
}

test "generated INSERT commits through WAL" {
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(source_bytes);
    const bytes = try std.testing.allocator.dupe(u8, source_bytes);
    defer std.testing.allocator.free(bytes);
    bytes[18] = 2;
    bytes[19] = 2;
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("insert-wal.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-insert-wal", &memory);
    var writer = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "insert-wal.db").database.?;
    var connection = Connection.init(std.testing.allocator, &writer);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(2000,x'02')", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    var reader = btree.Database.open(std.testing.allocator, &adapter.abi, "insert-wal.db").database.?;
    var cursor = reader.openCursor(2, .table).cursor.?;
    try std.testing.expect(cursor.seekTable(2000));
    cursor.deinit();
    try std.testing.expectEqual(ResultCode.ok, reader.close());
    try std.testing.expectEqual(ResultCode.ok, writer.pager.checkpointWal().result);
    try std.testing.expectEqual(ResultCode.ok, writer.close());
}

test "UPDATE and DELETE generate bounded rowid mutations" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("update-delete.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-update-delete", &memory);
    var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "update-delete.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "UPDATE t SET v='updated' WHERE id=2", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    var cursor = database.openCursor(2, .table).cursor.?;
    try std.testing.expect(cursor.seekTable(2));
    var record = cursor.record().record.?;
    try std.testing.expectEqualStrings("updated", record.values[1].text);
    record.deinit();
    cursor.deinit();
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "DELETE FROM t WHERE id=?1", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_bind_int(prepared, 1, 2));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    cursor = database.openCursor(2, .table).cursor.?;
    try std.testing.expect(!cursor.seekTable(2));
    try std.testing.expectEqual(@as(usize, 299), cursor.count());
    cursor.deinit();
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "DELETE FROM t WHERE id=9999", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

fn rowMutationAllocationExercise(allocator: std.mem.Allocator, adapter: *btree.vfs.AbiAdapter) !void {
    const opened = btree.Database.openWritable(allocator, &adapter.abi, "row-mutation-oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer if (database.pager.state != .closed) {
        _ = database.close();
    };
    var connection = Connection.init(allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    const p = sqlite3_prepare_v2(toOpaque(&connection), "UPDATE t SET v=?1 WHERE id=2", -1, &prepared, null);
    if (p == ResultCode.no_memory.toC()) return error.OutOfMemory;
    if (p != ResultCode.ok.toC()) return error.UnexpectedResult;
    const b = statement.sqlite3_bind_text(prepared, 1, "oom-update", -1, null);
    if (b == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(prepared);
        return error.OutOfMemory;
    }
    const step = statement.sqlite3_step(prepared);
    if (step == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(prepared);
        return error.OutOfMemory;
    }
    if (step != ResultCode.done.toC()) return error.UnexpectedResult;
    if (statement.sqlite3_finalize(prepared) != ResultCode.ok.toC()) return error.UnexpectedResult;
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "generated UPDATE survives every bounded allocation failure" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const initial = memory.open("row-mutation-oom.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, initial.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, initial.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(initial));
    var adapter = btree.vfs.AbiAdapter.init("sql-row-mutation-oom", &memory);
    var completed = false;
    for (0..2048) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        rowMutationAllocationExercise(failing.allocator(), &adapter) catch |err| try std.testing.expect(err == error.OutOfMemory);
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
        const replacement = memory.open("row-mutation-oom.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(btree.vfs.OK, replacement.truncate(0));
        try std.testing.expectEqual(btree.vfs.OK, replacement.write(bytes, 0));
        try std.testing.expectEqual(btree.vfs.OK, replacement.sync());
        try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(replacement));
    }
    try std.testing.expect(completed);
}

test "generated UPDATE DELETE rollback faults and WAL continuation" {
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(source_bytes);
    inline for (.{ btree.vfs.Method.write, btree.vfs.Method.sync }) |method| {
        var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        const name = if (method == .write) "row-write.db" else "row-sync.db";
        const file = memory.open(name, btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(btree.vfs.OK, file.write(source_bytes, 0));
        try std.testing.expectEqual(btree.vfs.OK, file.sync());
        try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
        var adapter = btree.vfs.AbiAdapter.init("sql-row-fault", &memory);
        var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, name).database.?;
        var connection = Connection.init(std.testing.allocator, &database);
        var prepared: ?*statement.sqlite3_stmt = null;
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "DELETE FROM t WHERE id=2", -1, &prepared, null));
        const code = if (method == .write) btree.vfs.IOERR_WRITE else btree.vfs.IOERR_FSYNC;
        var rules = [_]btree.vfs.FaultRule{.{ .method = method, .code = code }};
        var faults = btree.vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        try std.testing.expectEqual(ResultCode.fromC(code).toC(), statement.sqlite3_step(prepared));
        _ = statement.sqlite3_finalize(prepared);
        memory.faults = null;
        var cursor = database.openCursor(2, .table).cursor.?;
        try std.testing.expect(cursor.seekTable(2));
        cursor.deinit();
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "DELETE FROM t WHERE id=2", -1, &prepared, null));
        try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
        try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
        try std.testing.expectEqual(ResultCode.ok, database.close());
    }
    const wal_bytes = try std.testing.allocator.dupe(u8, source_bytes);
    defer std.testing.allocator.free(wal_bytes);
    wal_bytes[18] = 2;
    wal_bytes[19] = 2;
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("row-wal.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(wal_bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-row-wal", &memory);
    var writer = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "row-wal.db").database.?;
    var connection = Connection.init(std.testing.allocator, &writer);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "UPDATE t SET v='wal' WHERE id=2", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    var reader = btree.Database.open(std.testing.allocator, &adapter.abi, "row-wal.db").database.?;
    var cursor = reader.openCursor(2, .table).cursor.?;
    try std.testing.expect(cursor.seekTable(2));
    var record = cursor.record().record.?;
    try std.testing.expectEqualStrings("wal", record.values[1].text);
    record.deinit();
    cursor.deinit();
    try std.testing.expectEqual(ResultCode.ok, reader.close());
    try std.testing.expectEqual(ResultCode.ok, writer.close());
}

test "INDEXED BY scan and primary-key self join generate native cursor programs" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/index-without-rowid-1024.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("index-join.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-index-join", &memory);
    var database = btree.Database.open(std.testing.allocator, &adapter.abi, "index-join.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT v,id FROM t INDEXED BY t_v", -1, &prepared, null));
    var rows: usize = 0;
    while (statement.sqlite3_step(prepared) == ResultCode.row.toC()) {
        rows += 1;
        try std.testing.expectEqual(@as(i64, @intCast(rows)), statement.sqlite3_column_int64(prepared, 1));
    }
    try std.testing.expectEqual(@as(usize, 300), rows);
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT v,id FROM t ORDER BY v DESC LIMIT 2", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 300), statement.sqlite3_column_int64(prepared, 1));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 299), statement.sqlite3_column_int64(prepared, 1));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT id,id FROM t JOIN t USING(id)", -1, &prepared, null));
    rows = 0;
    while (statement.sqlite3_step(prepared) == ResultCode.row.toC()) {
        rows += 1;
        try std.testing.expectEqual(statement.sqlite3_column_int64(prepared, 0), statement.sqlite3_column_int64(prepared, 1));
    }
    try std.testing.expectEqual(@as(usize, 300), rows);
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

test "scoped UPSERT window PRAGMA and VACUUM advanced families execute" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("advanced.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-advanced", &memory);
    var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "advanced.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "INSERT INTO t(id,v) VALUES(1,'ignored') ON CONFLICT DO NOTHING", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT row_number() OVER ()", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 1), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "PRAGMA user_version", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 0), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "VACUUM", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

test "rowid predicates reverse order and limits generate planned cursor programs" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/none-512.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("planner.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-planner", &memory);
    var database = btree.Database.open(std.testing.allocator, &adapter.abi, "planner.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT id,v FROM t WHERE id = 42", -1, &prepared, null));
    const equality_statement: *statement.Statement = @ptrCast(@alignCast(prepared.?));
    try std.testing.expectEqual(vdbe.Opcode.seek_rowid, equality_statement.vm.program.instructions[2].opcode);
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT id,v FROM t WHERE id >= 298 ORDER BY id DESC LIMIT 2", -1, &prepared, null));
    const range_statement: *statement.Statement = @ptrCast(@alignCast(prepared.?));
    const range_code = range_statement.vm.program.instructions;
    try std.testing.expectEqual(vdbe.Opcode.last, range_code[3].opcode);
    try std.testing.expectEqual(vdbe.Opcode.decr_jump_zero, range_code[9].opcode);
    try std.testing.expectEqual(vdbe.Opcode.prev, range_code[10].opcode);
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 300), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 299), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT id FROM t ORDER BY id DESC LIMIT 0", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

fn indexPlannerAllocationExercise(allocator: std.mem.Allocator, adapter: *btree.vfs.AbiAdapter) !void {
    const opened = btree.Database.open(allocator, &adapter.abi, "index-plan-oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer if (database.pager.state != .closed) {
        _ = database.close();
    };
    var connection = Connection.init(allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    const rc = sqlite3_prepare_v2(toOpaque(&connection), "SELECT v,id FROM t ORDER BY v DESC LIMIT 4", -1, &prepared, null);
    if (rc == ResultCode.no_memory.toC()) return error.OutOfMemory;
    if (rc != ResultCode.ok.toC()) return error.UnexpectedResult;
    const step_rc = statement.sqlite3_step(prepared);
    if (step_rc == ResultCode.no_memory.toC()) {
        _ = statement.sqlite3_finalize(prepared);
        return error.OutOfMemory;
    }
    if (step_rc != ResultCode.row.toC()) return error.UnexpectedResult;
    if (statement.sqlite3_finalize(prepared) != ResultCode.ok.toC()) return error.UnexpectedResult;
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "automatic covering-index planning survives every bounded allocation failure" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/btree-mutation/index-without-rowid-1024.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const opened = memory.open("index-plan-oom.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(btree.vfs.OK, opened.rc);
    try std.testing.expectEqual(btree.vfs.OK, opened.file.?.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, opened.file.?.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(opened.file.?));
    var adapter = btree.vfs.AbiAdapter.init("sql-index-plan-oom", &memory);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, indexPlannerAllocationExercise, .{&adapter});
}

test "serialize NOCOPY nullable size and deserialize armor preserve source contracts" {
    var database: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &database));
    defer _ = sqlite3_close(database);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(database, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", null, null, null));

    const copied = sqlite3_serialize(database, null, null, 0) orelse return error.TestUnexpectedResult;
    public_api.sqlite3_free(copied);
    var size: i64 = -1;
    const borrowed = sqlite3_serialize(database, "main", &size, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(size >= 512);
    const connection = asConnection(database).?;
    const native = connection.memory_backend.?.borrowVolatile("main").?;
    try std.testing.expectEqual(@intFromPtr(native.ptr), @intFromPtr(borrowed));
    try std.testing.expectEqual(@as(usize, @intCast(size)), native.len);
    size = 99;
    try std.testing.expectEqual(null, sqlite3_serialize(database, "missing", &size, 0));
    try std.testing.expectEqual(@as(i64, -1), size);
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_deserialize(database, "main", borrowed, size, -1, 0));
}

test "deserialize adopts caller storage and preserves resize ownership and readonly flags" {
    var source: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &source));
    defer _ = sqlite3_close(source);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(source, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", null, null, null));

    var size: i64 = -1;
    const image = sqlite3_serialize(source, "main", &size, 0) orelse return error.TestUnexpectedResult;
    var clone: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &clone));
    const capacity: i64 = @intCast(public_api.sqlite3_msize(image));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_deserialize(clone, "main", image, size, capacity, btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_RESIZEABLE));
    var clone_size: i64 = -1;
    const adopted = sqlite3_serialize(clone, "main", &clone_size, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(image), @intFromPtr(adopted));
    try std.testing.expectEqual(size, clone_size);
    const clone_connection = asConnection(clone).?;
    const growth_open = clone_connection.memory_backend.?.open("main", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(btree.vfs.OK, growth_open.rc);
    const growth_file = growth_open.file.?;
    try std.testing.expectEqual(btree.vfs.OK, growth_file.write(&.{0}, @intCast(capacity)));
    var grown_size: u64 = 0;
    try std.testing.expectEqual(btree.vfs.OK, growth_file.fileSize(&grown_size));
    try std.testing.expectEqual(@as(u64, @intCast(capacity + 1)), grown_size);
    try std.testing.expectEqual(btree.vfs.OK, growth_file.truncate(@intCast(size)));
    try std.testing.expectEqual(btree.vfs.OK, clone_connection.memory_backend.?.closeAndDestroy(growth_file));
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(clone, "SELECT x FROM t", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(clone, "INSERT INTO t VALUES(43)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close(clone));

    const readonly_image = sqlite3_serialize(source, "main", &size, 0) orelse return error.TestUnexpectedResult;
    var readonly: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &readonly));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_deserialize(readonly, null, readonly_image, size, @intCast(public_api.sqlite3_msize(readonly_image)), btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_READONLY));
    try std.testing.expectEqual(@as(c_int, 1), sqlite3_db_readonly(readonly, "main"));
    try std.testing.expectEqual(ResultCode.read_only.toC(), sqlite3_exec(readonly, "INSERT INTO t VALUES(99)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close(readonly));
}

test "public open close error and deferred statement lifecycle" {
    var database: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &database));
    try std.testing.expect(database != null);
    try std.testing.expectEqualStrings(":memory:", std.mem.span(sqlite3_db_filename(database, "main").?));
    try std.testing.expectEqual(@as(c_int, 0), sqlite3_db_readonly(database, "main"));
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(database, "SELECT 40+2", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.busy.toC(), sqlite3_close(database));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close_v2(database));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    database = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open_v2("/tmp/sqlite-zig-open-api.db", &database, 0x02 | 0x04, "zig-unix"));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close(database));
    unix_vfs.remove("/tmp/sqlite-zig-open-api.db");
}
