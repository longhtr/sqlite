//! Bounded handwritten SQL frontend and planner slices.
//! This is transitional and must be replaced by the generated Lemon actions and full compiler/planner.
//! Rowid predicates, ordering, and limits lower to native cursor programs.

const std = @import("std");
const builtin = @import("builtin");
const profile_limits = @import("build_profile").limits;
pub const global = @import("global.zig");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const tokenizer = @import("tokenizer.zig");
const complete = @import("complete.zig");
const tokens = tokenizer.token;
const vdbe = @import("vdbe.zig");
const wal = @import("wal.zig");
pub const btree = @import("btree.zig");
const unix_vfs = @import("unix_vfs.zig");
const memdb = @import("memdb.zig");
const page_cache = @import("page_cache.zig");
const public_api = @import("public_api.zig");
const mutex = @import("mutex.zig");
const lookaside = @import("lookaside.zig");
pub const statement = @import("statement.zig");
const json_functions = @import("internal/json_functions.zig");
const builtin_functions = @import("internal/builtin_functions.zig");
const date_functions = @import("internal/date_functions.zig");
const json_vtable = @import("internal/json_vtable.zig");
const analysis_stats = @import("internal/analysis_stats.zig");
const pragma_runtime = @import("internal/pragma_runtime.zig");
const schema_initialization = @import("internal/schema_initialization.zig");
const virtual_table_lifecycle = @import("internal/virtual_table_lifecycle.zig");
const schema_program_runtime = @import("internal/schema_program_runtime.zig");
const query_execution = @import("internal/query_execution.zig");
const query_compiler = @import("internal/query_compiler.zig");
const attachment_runtime = @import("internal/attachment_runtime.zig");
const vdbe_explain = @import("internal/vdbe_explain.zig");
const ResultCode = @import("result_code.zig").ResultCode;

extern "c" fn dlopen(file: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn dlerror() ?[*:0]const u8;
extern "c" fn gettimeofday(*ProfileTimeval, ?*anyopaque) c_int;

const ProfileTimeval = extern struct {
    seconds: i64,
    microseconds: i64,
};

fn profileTimeMilliseconds() i64 {
    var value: ProfileTimeval = undefined;
    if (gettimeofday(&value, null) != 0) return 0;
    return value.seconds * 1000 + @divTrunc(value.microseconds, 1000);
}

pub const sqlite3 = opaque {};
pub const sqlite3_backup = opaque {};
pub const sqlite3_blob = opaque {};

const PublicScalarCallback = *const fn (?*statement.sqlite3_context, c_int, [*]?*statement.sqlite3_value) callconv(.c) void;
const PublicFinalCallback = *const fn (?*statement.sqlite3_context) callconv(.c) void;
fn jsonScalar(comptime callback: anytype) PublicScalarCallback {
    return @ptrCast(&callback);
}
fn jsonFinal(comptime callback: anytype) PublicFinalCallback {
    return @ptrCast(&callback);
}
var core_scalar_functions = [_]statement.FunctionDefinition{
    .{ .name = @constCast("typeof"), .argument_count = 1, .callback = jsonScalar(builtin_functions.typeOf), .user_data = null, .database = null },
    .{ .name = @constCast("subtype"), .argument_count = 1, .callback = jsonScalar(builtin_functions.subtype), .user_data = null, .database = null },
    .{ .name = @constCast("length"), .argument_count = 1, .callback = jsonScalar(builtin_functions.length), .user_data = null, .database = null },
    .{ .name = @constCast("unicode"), .argument_count = 1, .callback = jsonScalar(builtin_functions.unicode), .user_data = null, .database = null },
    .{ .name = @constCast("instr"), .argument_count = 2, .callback = jsonScalar(builtin_functions.instruction), .user_data = null, .database = null },
    .{ .name = @constCast("abs"), .argument_count = 1, .callback = jsonScalar(builtin_functions.absolute), .user_data = null, .database = null },
    .{ .name = @constCast("round"), .argument_count = 1, .callback = jsonScalar(builtin_functions.round), .user_data = null, .database = null },
    .{ .name = @constCast("round"), .argument_count = 2, .callback = jsonScalar(builtin_functions.round), .user_data = null, .database = null },
    .{ .name = @constCast("random"), .argument_count = 0, .callback = jsonScalar(builtin_functions.randomInteger), .user_data = null, .database = null },
    .{ .name = @constCast("sqlite_version"), .argument_count = 0, .callback = jsonScalar(builtin_functions.version), .user_data = null, .database = null },
    .{ .name = @constCast("sqlite_source_id"), .argument_count = 0, .callback = jsonScalar(builtin_functions.sourceId), .user_data = null, .database = null },
    .{ .name = @constCast("sign"), .argument_count = 1, .callback = jsonScalar(builtin_functions.sign), .user_data = null, .database = null },
    .{ .name = @constCast("zeroblob"), .argument_count = 1, .callback = jsonScalar(builtin_functions.zeroBlob), .user_data = null, .database = null },
    .{ .name = @constCast("count"), .argument_count = 0, .step_callback = jsonScalar(builtin_functions.countStep), .final_callback = jsonFinal(builtin_functions.countFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("count"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.countStep), .final_callback = jsonFinal(builtin_functions.countFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("sum"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.sumStep), .final_callback = jsonFinal(builtin_functions.sumFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("total"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.sumStep), .final_callback = jsonFinal(builtin_functions.totalFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("avg"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.sumStep), .final_callback = jsonFinal(builtin_functions.averageFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("min"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.minMaxStep), .final_callback = jsonFinal(builtin_functions.minMaxFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("max"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.minMaxStep), .final_callback = jsonFinal(builtin_functions.minMaxFinalize), .user_data = @ptrFromInt(1), .database = null },
    .{ .name = @constCast("group_concat"), .argument_count = 1, .step_callback = jsonScalar(builtin_functions.groupConcatStep), .final_callback = jsonFinal(builtin_functions.groupConcatFinalize), .user_data = null, .database = null },
    .{ .name = @constCast("group_concat"), .argument_count = 2, .step_callback = jsonScalar(builtin_functions.groupConcatStep), .final_callback = jsonFinal(builtin_functions.groupConcatFinalize), .user_data = null, .database = null },
};

var date_scalar_functions = [_]statement.FunctionDefinition{
    .{ .name = @constCast("julianday"), .argument_count = -1, .callback = jsonScalar(date_functions.julianDay), .user_data = null, .database = null },
    .{ .name = @constCast("unixepoch"), .argument_count = -1, .callback = jsonScalar(date_functions.unixEpoch), .user_data = null, .database = null },
    .{ .name = @constCast("date"), .argument_count = -1, .callback = jsonScalar(date_functions.calendarDate), .user_data = null, .database = null },
    .{ .name = @constCast("time"), .argument_count = -1, .callback = jsonScalar(date_functions.time), .user_data = null, .database = null },
    .{ .name = @constCast("datetime"), .argument_count = -1, .callback = jsonScalar(date_functions.dateTime), .user_data = null, .database = null },
    .{ .name = @constCast("strftime"), .argument_count = -1, .callback = jsonScalar(date_functions.strftime), .user_data = null, .database = null },
    .{ .name = @constCast("timediff"), .argument_count = 2, .callback = jsonScalar(date_functions.timeDifference), .user_data = null, .database = null },
};

var jsonb_scalar_functions = [_]statement.FunctionDefinition{
    .{ .name = @constCast("jsonb"), .argument_count = 1, .callback = jsonScalar(json_functions.removeFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_array"), .argument_count = -1, .callback = jsonScalar(json_functions.arrayFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_object"), .argument_count = -1, .callback = jsonScalar(json_functions.objectFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_extract"), .argument_count = -1, .callback = jsonScalar(json_functions.extractFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_set"), .argument_count = -1, .callback = jsonScalar(json_functions.setFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_replace"), .argument_count = -1, .callback = jsonScalar(json_functions.replaceFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_remove"), .argument_count = -1, .callback = jsonScalar(json_functions.removeFunction), .user_data = @ptrFromInt(0x10), .database = null },
    .{ .name = @constCast("jsonb_patch"), .argument_count = 2, .callback = jsonScalar(json_functions.patchFunction), .user_data = @ptrFromInt(0x10), .database = null },
};

var json_scalar_functions = [_]statement.FunctionDefinition{
    .{ .name = @constCast("json"), .argument_count = 1, .callback = jsonScalar(json_functions.removeFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_array"), .argument_count = -1, .callback = jsonScalar(json_functions.arrayFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_array_length"), .argument_count = 1, .callback = jsonScalar(json_functions.arrayLengthFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_array_length"), .argument_count = 2, .callback = jsonScalar(json_functions.arrayLengthFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_error_position"), .argument_count = 1, .callback = jsonScalar(json_functions.errorPositionFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_extract"), .argument_count = -1, .callback = jsonScalar(json_functions.extractFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_object"), .argument_count = -1, .callback = jsonScalar(json_functions.objectFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_patch"), .argument_count = 2, .callback = jsonScalar(json_functions.patchFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_pretty"), .argument_count = 1, .callback = jsonScalar(json_functions.prettyFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_pretty"), .argument_count = 2, .callback = jsonScalar(json_functions.prettyFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_quote"), .argument_count = 1, .callback = jsonScalar(json_functions.quoteFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_remove"), .argument_count = -1, .callback = jsonScalar(json_functions.removeFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_replace"), .argument_count = -1, .callback = jsonScalar(json_functions.replaceFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_set"), .argument_count = -1, .callback = jsonScalar(json_functions.setFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_type"), .argument_count = 1, .callback = jsonScalar(json_functions.typeFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_type"), .argument_count = 2, .callback = jsonScalar(json_functions.typeFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_valid"), .argument_count = 1, .callback = jsonScalar(json_functions.validFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_valid"), .argument_count = 2, .callback = jsonScalar(json_functions.validFunction), .user_data = null, .database = null },
    .{ .name = @constCast("json_group_array"), .argument_count = 1, .step_callback = jsonScalar(json_functions.arrayAggregateStep), .final_callback = jsonFinal(json_functions.arrayAggregateFinal), .value_callback = jsonFinal(json_functions.arrayAggregateValue), .inverse_callback = jsonScalar(json_functions.groupInverse), .user_data = null, .database = null },
    .{ .name = @constCast("json_group_object"), .argument_count = 2, .step_callback = jsonScalar(json_functions.objectAggregateStep), .final_callback = jsonFinal(json_functions.objectAggregateFinal), .value_callback = jsonFinal(json_functions.objectAggregateValue), .inverse_callback = jsonScalar(json_functions.groupInverse), .user_data = null, .database = null },
};
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
const VirtualTable = struct { connection: *Connection, schema_name: [:0]u8, name: [:0]u8, module: *const Module, instance: *sqlite3_vtab, columns: std.ArrayList([:0]u8) = .empty };
const VirtualPlan = struct { table: *VirtualTable, index_number: c_int = 0, index_string: ?[:0]u8 = null };
const VirtualHandle = struct { plan: *VirtualPlan, cursor: *sqlite3_vtab_cursor };
const JsonVirtualPlan = struct {
    allocator: std.mem.Allocator,
    connection: json_vtable.Connection,
    input: []u8,
    input_is_blob: bool,
    root: ?[]u8,
};
const JsonVirtualHandle = struct { plan: *JsonVirtualPlan, cursor: *json_vtable.Cursor };
const IndexConstraint = extern struct { iColumn: c_int, op: u8, usable: u8, iTermOffset: c_int };
const IndexOrderBy = extern struct { iColumn: c_int, desc: u8 };
const IndexUsage = extern struct { argvIndex: c_int, omit: u8 };
const IndexInfo = extern struct { nConstraint: c_int, aConstraint: ?[*]IndexConstraint, nOrderBy: c_int, aOrderBy: ?[*]IndexOrderBy, aConstraintUsage: ?[*]IndexUsage, idxNum: c_int, idxStr: ?[*:0]u8, needToFreeIdxStr: c_int, orderByConsumed: c_int, estimatedCost: f64, estimatedRows: i64, idxFlags: c_int, colUsed: u64 };
const planning_magic: u64 = 0x5a56544142504c4e;
const PlanningContext = extern struct { public: IndexInfo, magic: u64 = planning_magic, distinct: c_int = 0 };
const connection_magic: u64 = 0x5a_53_51_4c_43_4f_4e_4e;

const PendingForeignKeyParent = struct {
    table_name: []const u8,
    old_rowid: i64,
    new_rowid: i64,
    new_values: ?[]const btree.Value,
};

fn defaultDatabaseConfiguration() [24]u8 {
    var result = [_]u8{0} ** 24;
    for ([_]usize{ 3, 13, 14, 15, 17, 20, 21, 22 }) |index| result[index] = 1;
    return result;
}

const AttachedDatabase = struct {
    allocator: std.mem.Allocator,
    memory_backend: btree.vfs.MemoryVfs,
    memory_adapter: btree.vfs.AbiAdapter = undefined,
    database: ?btree.Database = null,
    pending_deserialize_readonly: ?bool = null,
    active_blobs: usize = 0,
    active_backups: usize = 0,

    fn createMemory(allocator: std.mem.Allocator) ?*AttachedDatabase {
        const attached = allocator.create(AttachedDatabase) catch return null;
        attached.* = .{ .allocator = allocator, .memory_backend = btree.vfs.MemoryVfs.init(allocator) };
        const initialized = initializeEmptyMemory(&attached.memory_backend, "main");
        if (initialized != .ok) {
            attached.memory_backend.deinit();
            allocator.destroy(attached);
            return null;
        }
        attached.memory_adapter = btree.vfs.AbiAdapter.init("zig-attached-memory", &attached.memory_backend);
        const opened = btree.Database.openWritable(allocator, &attached.memory_adapter.abi, "main");
        if (opened.result != .ok) {
            attached.memory_backend.deinit();
            allocator.destroy(attached);
            return null;
        }
        attached.database = opened.database.?;
        return attached;
    }

    fn destroy(self: *AttachedDatabase) void {
        if (self.database) |*database| _ = database.close();
        self.memory_backend.deinit();
        self.allocator.destroy(self);
    }
};

pub const Connection = struct {
    magic: u64 = connection_magic,
    allocator: std.mem.Allocator,
    last_result: ResultCode = .ok,
    error_offset: c_int = -1,
    system_errno: c_int = 0,
    custom_error_message: ?[:0]u8 = null,
    database: ?*btree.Database = null,
    owned_database: bool = false,
    unix_backend: ?unix_vfs.UnixVfs = null,
    unix_adapter: ?unix_vfs.Adapter = null,
    memory_backend: ?btree.vfs.MemoryVfs = null,
    memory_adapter: ?btree.vfs.AbiAdapter = null,
    pending_deserialize_readonly: ?bool = null,
    attachments: ?attachment_runtime.Connection = null,
    temp_database: ?*AttachedDatabase = null,
    shared_memdb: ?*memdb.Shared = null,
    filename: ?[:0]u8 = null,
    main_schema_name: ?[:0]u8 = null,
    active_statements: usize = 0,
    statement_head: ?*statement.Statement = null,
    active_blobs: usize = 0,
    active_backups: usize = 0,
    active_source_backups: usize = 0,
    deferred_close: bool = false,
    error_mask: c_int = 0xff,
    last_insert_rowid: i64 = 0,
    changes: i64 = 0,
    total_changes: i64 = 0,
    explicit_transaction: bool = false,
    transaction_databases: std.ArrayList(*btree.Database) = .empty,
    interrupted: bool = false,
    busy_callback: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int = null,
    busy_context: ?*anyopaque = null,
    busy_calls: c_int = 0,
    busy_timeout_ms: c_int = 0,
    setlk_timeout_ms: c_int = 0,
    setlk_flags: c_int = 0,
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
    builtin_functions_registered: bool = false,
    date_time_functions_registered: bool = false,
    json_functions_registered: bool = false,
    json_vtables_registered: bool = false,
    load_extension_function: statement.FunctionDefinition = .{ .name = @constCast("load_extension"), .argument_count = -1, .callback = loadExtensionSqlFunction, .user_data = null, .database = null },
    collations: std.ArrayList(struct { name: [:0]u8, encoding: c_int, auxiliary: ?*anyopaque, compare: *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int, destroy: ?*const fn (?*anyopaque) callconv(.c) void }) = .empty,
    collation_needed_callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, [*:0]const u8) callconv(.c) void = null,
    collation_needed16_callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, *const anyopaque) callconv(.c) void = null,
    collation_needed_context: ?*anyopaque = null,
    vtab_declaration: ?[:0]u8 = null,
    database_configuration: [24]u8 = defaultDatabaseConfiguration(),
    load_extension_enabled: bool = false,
    extension_handles: std.ArrayList(*anyopaque) = .empty,
    modules: std.ArrayList(struct { name: [:0]u8, module: *const anyopaque, auxiliary: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void }) = .empty,
    virtual_tables: std.ArrayList(*VirtualTable) = .empty,
    virtual_tables_disconnected: bool = false,
    statistics: ?*analysis_stats.StatTable = null,
    loaded_analysis: ?*analysis_stats.LoadedAnalysis = null,
    pragma_state: pragma_runtime.State = .{},
    schema_model: schema_initialization.Schema,
    virtual_table_state: ?*virtual_table_lifecycle.State = null,
    connection_mutex: mutex.Mutex = .{ .kind = .recursive },
    lookaside_allocator: ?lookaside.Lookaside = null,
    prepare_state: query_compiler.PrepareState = .{},
    client_data: std.ArrayList(struct { name: [:0]u8, value: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void }) = .empty,
    pending_foreign_key_parents: std.ArrayList(PendingForeignKeyParent) = .empty,
    foreign_key_action_allocations: std.ArrayList([]u8) = .empty,
    foreign_key_action_depth: usize = 0,
    limits: [13]c_int = .{ 1_000_000_000, 1_000_000_000, 2000, 1000, 500, 250_000_000, 1000, 10, 50_000, 32_766, 1000, 0, 2500 },

    pub fn create(allocator: std.mem.Allocator) !*Connection {
        const connection = try allocator.create(Connection);
        connection.* = .{ .allocator = allocator, .schema_model = schema_initialization.Schema.init(allocator, "main") };
        connection.registerBuiltinFunctions();
        return connection;
    }

    pub fn init(allocator: std.mem.Allocator, database: ?*btree.Database) Connection {
        var connection = Connection{ .allocator = allocator, .database = database, .schema_model = schema_initialization.Schema.init(allocator, "main") };
        connection.registerBuiltinFunctions();
        return connection;
    }

    pub fn destroy(self: *Connection) void {
        if (self.autovacuum_destroy) |destroy_callback| destroy_callback(self.autovacuum_context);
        if (self.custom_error_message) |message| self.allocator.free(message);
        if (self.main_schema_name) |name| self.allocator.free(name);
        if (self.attachments) |*attachments| attachments.deinit();
        if (self.temp_database) |temporary| temporary.destroy();
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
        disconnectAllVirtualTables(self);
        for (self.virtual_tables.items) |table| {
            for (table.columns.items) |column| self.allocator.free(column);
            table.columns.deinit(self.allocator);
            self.allocator.free(table.schema_name);
            self.allocator.free(table.name);
            self.allocator.destroy(table);
        }
        self.virtual_tables.deinit(self.allocator);
        if (self.statistics) |statistics| {
            statistics.deinit();
            self.allocator.destroy(statistics);
        }
        if (self.loaded_analysis) |analysis| {
            analysis.deinit();
            self.allocator.destroy(analysis);
        }
        self.schema_model.deinit();
        if (self.virtual_table_state) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
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
        self.pending_foreign_key_parents.deinit(self.allocator);
        for (self.foreign_key_action_allocations.items) |allocation| {
            self.allocator.free(allocation);
        }
        self.foreign_key_action_allocations.deinit(self.allocator);
        for (self.transaction_databases.items) |database| {
            _ = database.rollbackMutationBatch();
        }
        self.transaction_databases.deinit(self.allocator);
        if (self.lookaside_allocator) |*allocator| allocator.deinit();
        for (self.extension_handles.items) |handle| {
            _ = dlclose(handle);
        }
        self.extension_handles.deinit(self.allocator);
        self.magic = 0;
        self.allocator.destroy(self);
    }

    /// Source `sqlite3RegisterDateTimeFunctions()`: activate the statically
    /// defined date/time function table for this native connection.
    fn registerDateTimeFunctions(self: *Connection) void {
        self.date_time_functions_registered = true;
    }

    /// Source `sqlite3JsonVtabRegister()`: activate the built-in json_each and
    /// json_tree eponymous table configurations for this connection.
    fn registerJsonVirtualTables(self: *Connection) void {
        self.json_vtables_registered = true;
    }

    /// Source `sqlite3RegisterJsonFunctions()`: activate JSON text and JSONB
    /// scalar definitions together with their eponymous table functions.
    fn registerJsonFunctions(self: *Connection) void {
        self.json_functions_registered = true;
        self.registerJsonVirtualTables();
    }

    /// Source `sqlite3RegisterBuiltinFunctions()`: publish the core scalar
    /// table and its date/time companions to prepared SQL lookup.
    fn registerBuiltinFunctions(self: *Connection) void {
        self.builtin_functions_registered = true;
        self.registerDateTimeFunctions();
        self.registerJsonFunctions();
    }

    fn findScalar(self: *Connection, name: []const u8, argument_count: usize) ?*statement.FunctionDefinition {
        for (self.scalar_functions.items) |definition| if (std.ascii.eqlIgnoreCase(definition.name, name) and (definition.argument_count < 0 or definition.argument_count == argument_count)) return definition;
        if (self.json_functions_registered) {
            for (&json_scalar_functions) |*definition| {
                if (std.ascii.eqlIgnoreCase(definition.name, name) and (definition.argument_count < 0 or definition.argument_count == argument_count)) return definition;
            }
            for (&jsonb_scalar_functions) |*definition| {
                if (std.ascii.eqlIgnoreCase(definition.name, name) and (definition.argument_count < 0 or definition.argument_count == argument_count)) return definition;
            }
        }
        if (self.builtin_functions_registered) {
            for (&core_scalar_functions) |*definition| {
                if (std.ascii.eqlIgnoreCase(definition.name, name) and (definition.argument_count < 0 or definition.argument_count == argument_count)) return definition;
            }
        }
        if (self.date_time_functions_registered) {
            for (&date_scalar_functions) |*definition| {
                if (std.ascii.eqlIgnoreCase(definition.name, name) and (definition.argument_count < 0 or definition.argument_count == argument_count)) return definition;
            }
        }
        if (std.ascii.eqlIgnoreCase(name, "load_extension") and (argument_count == 1 or argument_count == 2)) {
            self.load_extension_function.user_data = self;
            return &self.load_extension_function;
        }
        return null;
    }

    fn finishClose(self: *Connection) ResultCode {
        if (self.owned_database) {
            rollbackAll(self, .abort);
            if (self.database) |database| {
                const rc = database.close();
                if (rc != .ok) return rc;
                self.allocator.destroy(database);
                self.database = null;
            }
            if (self.memory_backend) |*memory| memory.deinit();
            if (self.shared_memdb) |shared| {
                memdb.close(shared);
                self.shared_memdb = null;
            }
            if (self.filename) |name| self.allocator.free(name);
        }
        self.destroy();
        return .ok;
    }

    fn statementEvent(context: ?*anyopaque, prepared: *statement.Statement, event: c_uint) void {
        const self: *Connection = @ptrCast(@alignCast(context orelse return));
        const sql = if (prepared.sql_copy) |text| text.ptr else "";
        if (event == 1) {
            prepared.profile_start_ms = profileTimeMilliseconds();
            if (self.legacy_trace_callback) |callback| callback(self.legacy_trace_context, sql);
        }
        if (event == 2) {
            invokeProfileCallback(self, prepared);
            return;
        }
        if (self.trace_v2_callback) |callback| {
            if (self.trace_v2_mask & event != 0) {
                const detail: ?*anyopaque = if (event == 1) @ptrCast(@constCast(sql)) else null;
                _ = callback(event, self.trace_v2_context, statement.toOpaque(prepared), detail);
            }
        }
    }

    fn beforeWrite(self: *Connection) ResultCode {
        if (self.explicit_transaction) return .ok;
        if (self.commit_callback) |callback| if (callback(self.commit_context) != 0) {
            if (self.rollback_callback) |rollback| rollback(self.rollback_context);
            return .constraint;
        };
        return .ok;
    }
    fn afterWrite(self: *Connection, rc: ResultCode, operation: ?c_int, schema_name: []const u8, table: []const u8, rowid: i64) ResultCode {
        if (rc == .ok) {
            if (operation) |code| if (self.update_callback) |callback| {
                const name = self.allocator.dupeZ(u8, table) catch return .no_memory;
                defer self.allocator.free(name);
                const schema = self.allocator.dupeZ(u8, schema_name) catch return .no_memory;
                defer self.allocator.free(schema);
                callback(self.update_context, code, schema.ptr, name.ptr, rowid);
            };
            if (self.explicit_transaction) return .ok;
            const wal_result = doWalCallbacks(self);
            if (wal_result != .ok) return wal_result;
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
        if (!connectionIsBusy(self) and self.deferred_close) {
            _ = self.finishClose();
        }
    }
};

/// Source `disconnectAllVtab()`: disconnect every connection-owned virtual
/// table exactly once before module destructors or connection storage release.
fn disconnectAllVirtualTables(connection: *Connection) void {
    if (connection.virtual_tables_disconnected) return;
    for (connection.virtual_tables.items) |table| {
        if (table.module.xDisconnect) |raw| {
            const callback: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(raw));
            _ = callback(table.instance);
        }
    }
    connection.virtual_tables_disconnected = true;
}

/// Source schema reset during DETACH disconnects only virtual-table instances
/// owned by that Db before its B-tree and schema storage are released.
fn disconnectVirtualTablesInSchema(connection: *Connection, schema_name: []const u8) void {
    var index: usize = 0;
    while (index < connection.virtual_tables.items.len) {
        const table = connection.virtual_tables.items[index];
        if (!virtualSchemaMatches(connection, table.schema_name, schema_name)) {
            index += 1;
            continue;
        }
        if (table.module.xDisconnect) |raw| {
            const callback: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(raw));
            _ = callback(table.instance);
        }
        _ = connection.virtual_tables.orderedRemove(index);
        for (table.columns.items) |column| {
            connection.allocator.free(column);
        }
        table.columns.deinit(connection.allocator);
        connection.allocator.free(table.schema_name);
        connection.allocator.free(table.name);
        connection.allocator.destroy(table);
    }
}

/// Source `invokeProfileCallback()`: compute elapsed wall-clock microseconds
/// once and deliver the same value to legacy and TRACE_PROFILE callbacks.
fn invokeProfileCallback(connection: *Connection, prepared: *statement.Statement) void {
    if (prepared.profile_start_ms == 0) return;
    const now = profileTimeMilliseconds();
    const elapsed_ms = @max(now - prepared.profile_start_ms, 0);
    var elapsed_ns: u64 = @intCast(elapsed_ms * 1_000_000);
    const sql = if (prepared.sql_copy) |text| text.ptr else "";
    if (connection.legacy_profile_callback) |callback| callback(connection.legacy_profile_context, sql, elapsed_ns);
    if (connection.trace_v2_callback) |callback| {
        if (connection.trace_v2_mask & 2 != 0) {
            _ = callback(2, connection.trace_v2_context, statement.toOpaque(prepared), @ptrCast(&elapsed_ns));
        }
    }
    prepared.profile_start_ms = 0;
}

pub fn toOpaque(connection: *Connection) *sqlite3 {
    return @ptrCast(connection);
}

/// Source `sqlite3SafetyCheckSickOrOk()`: accept live and deferred-close
/// connection objects while rejecting null, closed, and foreign pointers.
fn safetyCheckSickOrOk(pointer: ?*sqlite3) ?*Connection {
    const connection: *Connection = if (pointer) |value| @ptrCast(@alignCast(value)) else return null;
    return if (connection.magic == connection_magic) connection else null;
}

/// Source `sqlite3SafetyCheckOk()`: deferred-close zombies remain valid for
/// cleanup APIs but are not valid for new database operations.
fn safetyCheckOk(pointer: ?*sqlite3) ?*Connection {
    const connection = safetyCheckSickOrOk(pointer) orelse return null;
    return if (!connection.deferred_close) connection else null;
}

fn asConnection(pointer: ?*sqlite3) ?*Connection {
    return safetyCheckSickOrOk(pointer);
}

fn emptyDatabaseHeader() [profile_limits.default_page_size]u8 {
    var bytes = [_]u8{0} ** profile_limits.default_page_size;
    @memcpy(bytes[0..16], "SQLite format 3\x00");
    bytes[16] = @truncate(profile_limits.default_page_size >> 8);
    bytes[17] = @truncate(profile_limits.default_page_size);
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
    bytes[105] = @truncate(profile_limits.default_page_size >> 8);
    bytes[106] = @truncate(profile_limits.default_page_size);
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

fn initializeEmptyMemory(backend: *btree.vfs.MemoryVfs, path: []const u8) ResultCode {
    const opened = backend.open(path, btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB);
    if (opened.rc != btree.vfs.OK) return ResultCode.fromC(opened.rc);
    const file = opened.file.?;
    var size: u64 = 0;
    var rc = file.fileSize(&size);
    if (rc == btree.vfs.OK and size == 0) {
        const header = emptyDatabaseHeader();
        rc = if (backend.memdb_mode) memdb.write(backend, path, &header, 0) else file.write(&header, 0);
        if (rc == btree.vfs.OK) rc = file.sync();
    }
    const close_rc = backend.closeAndDestroy(file);
    return ResultCode.fromC(if (rc == btree.vfs.OK) close_rc else rc);
}

const UriOption = struct {
    name: [:0]u8,
    value: [:0]u8,
};

const ParsedUri = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    flags: c_int,
    vfs_name: ?[:0]u8,

    fn deinit(self: *ParsedUri) void {
        self.allocator.free(self.path);
        if (self.vfs_name) |name| self.allocator.free(name);
    }
};

const UriParseResult = struct {
    result: ResultCode,
    parsed: ?ParsedUri = null,
};

fn decodeUriPart(allocator: std.mem.Allocator, source: []const u8) ![:0]u8 {
    var decoded = std.ArrayList(u8).empty;
    defer decoded.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '%' and index + 2 < source.len and std.ascii.isHex(source[index + 1]) and std.ascii.isHex(source[index + 2])) {
            const byte = try std.fmt.parseInt(u8, source[index + 1 .. index + 3], 16);
            index += 3;
            if (byte == 0) break;
            try decoded.append(allocator, byte);
        } else {
            try decoded.append(allocator, source[index]);
            index += 1;
        }
    }
    return allocator.dupeZ(u8, decoded.items);
}

/// Source `uriParameter()`: locate the first case-sensitive option name and
/// return its decoded value.
fn uriParameter(options: []const UriOption, key: []const u8) ?[]const u8 {
    for (options) |option| {
        if (std.mem.eql(u8, option.name, key)) return option.value;
    }
    return null;
}

/// Source `sqlite3ParseUri()`: decode file URIs, validate authorities, apply
/// access/cache modes, honor an explicit VFS, and return an owned VFS filename.
fn parseUri(allocator: std.mem.Allocator, filename: []const u8, initial_flags: c_int, default_vfs: ?[]const u8) UriParseResult {
    var flags = initial_flags;
    var selected_vfs = default_vfs;
    if (initial_flags & 0x40 == 0 or !std.mem.startsWith(u8, filename, "file:")) {
        const path = allocator.dupeZ(u8, filename) catch return .{ .result = .no_memory };
        const vfs_copy = if (selected_vfs) |name| allocator.dupeZ(u8, name) catch {
            allocator.free(path);
            return .{ .result = .no_memory };
        } else null;
        return .{ .result = .ok, .parsed = .{ .allocator = allocator, .path = path, .flags = flags & ~@as(c_int, 0x40), .vfs_name = vfs_copy } };
    }

    flags |= 0x40;
    var path_start: usize = 5;
    if (filename.len >= 7 and std.mem.eql(u8, filename[5..7], "//")) {
        const authority_end = std.mem.indexOfScalarPos(u8, filename, 7, '/') orelse filename.len;
        const authority = filename[7..authority_end];
        if (authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost")) return .{ .result = .error_ };
        path_start = authority_end;
    }
    const fragment = std.mem.indexOfScalarPos(u8, filename, path_start, '#') orelse filename.len;
    const question = std.mem.indexOfScalarPos(u8, filename, path_start, '?');
    const path_end = if (question) |position| @min(position, fragment) else fragment;
    const path = decodeUriPart(allocator, filename[path_start..path_end]) catch return .{ .result = .no_memory };
    var path_owned = true;
    defer if (path_owned) allocator.free(path);

    var options = std.ArrayList(UriOption).empty;
    defer {
        for (options.items) |option| {
            allocator.free(option.name);
            allocator.free(option.value);
        }
        options.deinit(allocator);
    }
    if (question) |query_start| {
        if (query_start < fragment) {
            var iterator = std.mem.splitScalar(u8, filename[query_start + 1 .. fragment], '&');
            while (iterator.next()) |raw_option| {
                const separator = std.mem.indexOfScalar(u8, raw_option, '=') orelse raw_option.len;
                if (separator == 0) continue;
                const name = decodeUriPart(allocator, raw_option[0..separator]) catch return .{ .result = .no_memory };
                const value = decodeUriPart(allocator, if (separator < raw_option.len) raw_option[separator + 1 ..] else "") catch {
                    allocator.free(name);
                    return .{ .result = .no_memory };
                };
                options.append(allocator, .{ .name = name, .value = value }) catch {
                    allocator.free(name);
                    allocator.free(value);
                    return .{ .result = .no_memory };
                };
            }
        }
    }

    if (uriParameter(options.items, "vfs")) |name| {
        selected_vfs = name;
    }
    if (uriParameter(options.items, "cache")) |mode| {
        const shared: c_int = 0x00020000;
        const private: c_int = 0x00040000;
        flags &= ~(shared | private);
        if (std.mem.eql(u8, mode, "shared")) {
            flags |= shared;
        } else if (std.mem.eql(u8, mode, "private")) {
            flags |= private;
        } else {
            return .{ .result = .error_ };
        }
    }
    if (uriParameter(options.items, "mode")) |mode| {
        const access_mask: c_int = 0x01 | 0x02 | 0x04 | 0x80;
        const requested: c_int = if (std.mem.eql(u8, mode, "ro"))
            0x01
        else if (std.mem.eql(u8, mode, "rw"))
            0x02
        else if (std.mem.eql(u8, mode, "rwc"))
            0x02 | 0x04
        else if (std.mem.eql(u8, mode, "memory"))
            0x02 | 0x04 | 0x80
        else {
            return .{ .result = .error_ };
        };
        if (requested & 0x02 != 0 and initial_flags & 0x02 == 0) {
            return .{ .result = .read_only };
        }
        if (requested & 0x04 != 0 and requested & 0x80 == 0 and initial_flags & 0x04 == 0) {
            return .{ .result = .read_only };
        }
        flags = (flags & ~access_mask) | requested;
    }

    const vfs_copy = if (selected_vfs) |name| allocator.dupeZ(u8, name) catch {
        return .{ .result = .no_memory };
    } else null;
    path_owned = false;
    return .{ .result = .ok, .parsed = .{ .allocator = allocator, .path = path, .flags = flags, .vfs_name = vfs_copy } };
}

fn openConnection(filename: []const u8, flags_initial: c_int, vfs_name_initial: ?[]const u8, output: ?*?*sqlite3) c_int {
    const init_result = public_api.sqlite3_initialize();
    if (init_result != 0) return init_result;
    const out = output orelse return ResultCode.misuse.toC();
    out.* = null;
    if (filename.len == 0) return ResultCode.cannot_open.toC();
    const allocator = std.heap.c_allocator;
    const parsed_result = parseUri(allocator, filename, flags_initial, vfs_name_initial);
    if (parsed_result.result != .ok) return parsed_result.result.toC();
    var parsed = parsed_result.parsed.?;
    defer parsed.deinit();
    const flags = parsed.flags;
    const vfs_name: ?[]const u8 = parsed.vfs_name;
    const open_filename: []const u8 = parsed.path;
    const connection = allocator.create(Connection) catch return ResultCode.no_memory.toC();
    connection.* = .{ .allocator = allocator, .owned_database = true, .schema_model = schema_initialization.Schema.init(allocator, "main") };
    connection.registerBuiltinFunctions();
    connection.filename = allocator.dupeZ(u8, open_filename) catch {
        allocator.destroy(connection);
        return ResultCode.no_memory.toC();
    };
    out.* = toOpaque(connection);
    const writable = flags & 0x02 != 0;
    const use_memory = flags & 0x80 != 0 or std.mem.eql(u8, open_filename, ":memory:") or (vfs_name != null and std.ascii.eqlIgnoreCase(vfs_name.?, "mem"));
    const shared_memory = use_memory and flags & 0x0002_0000 != 0 and !std.mem.eql(u8, open_filename, ":memory:");
    var abi_vfs: *btree.vfs.sqlite3_vfs = undefined;
    const storage_name = if (shared_memory) "/main" else if (use_memory) "main" else open_filename;
    if (shared_memory) {
        const shared_name = memdb.fullPathname(allocator, open_filename) catch {
            connection.last_result = .no_memory;
            return ResultCode.no_memory.toC();
        };
        defer allocator.free(shared_name);
        const shared_outcome = memdb.open(shared_name) catch |err| {
            connection.last_result = if (err == error.OutOfMemory) .no_memory else .cannot_open;
            return connection.last_result.toC();
        };
        connection.shared_memdb = shared_outcome.shared;
        connection.memory_adapter = btree.vfs.AbiAdapter.init("memdb", &shared_outcome.shared.backend);
        abi_vfs = &connection.memory_adapter.?.abi;
        if (writable and shared_outcome.created) {
            const rc = initializeEmptyMemory(&shared_outcome.shared.backend, storage_name);
            if (rc != .ok) {
                connection.last_result = rc;
                return rc.toC();
            }
        }
    } else if (use_memory) {
        connection.memory_backend = btree.vfs.MemoryVfs.init(allocator);
        connection.memory_adapter = btree.vfs.AbiAdapter.init("zig-memory", &connection.memory_backend.?);
        abi_vfs = &connection.memory_adapter.?.abi;
        if (writable) {
            const rc = initializeEmptyMemory(&connection.memory_backend.?, storage_name);
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
    if (opened.result != .ok) {
        systemError(connection, opened.result.toC());
        return opened.result.toC();
    }
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

fn utf16NativeToUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var endian = builtin.target.cpu.arch.endian();
    var start: usize = 0;
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe) {
        endian = .little;
        start = 2;
    } else if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) {
        endian = .big;
        start = 2;
    }
    const units = try allocator.alloc(u16, (bytes.len - start) / 2);
    defer allocator.free(units);
    for (units, 0..) |*unit, index| {
        const first = bytes[start + index * 2];
        const second = bytes[start + index * 2 + 1];
        unit.* = if (endian == .little) @as(u16, first) | (@as(u16, second) << 8) else (@as(u16, first) << 8) | @as(u16, second);
    }
    return std.unicode.utf16LeToUtf8Alloc(allocator, units);
}

/// Source `sqlite3_open16()`: convert native-endian UTF-16, honor BOM byte
/// order, initialize output deterministically, and open the UTF-8 filename.
fn openConnection16(filename: ?*const anyopaque, output: ?*?*sqlite3) c_int {
    const destination = output orelse return ResultCode.misuse.toC();
    destination.* = null;
    const bytes: [*]const u8 = if (filename) |value| @ptrCast(@alignCast(value)) else @ptrCast(&[_]u16{0});
    var length: usize = 0;
    while (bytes[length] != 0 or bytes[length + 1] != 0) : (length += 2) {}
    const utf8 = utf16NativeToUtf8(std.heap.c_allocator, bytes[0..length]) catch return ResultCode.no_memory.toC();
    defer std.heap.c_allocator.free(utf8);
    return openConnection(utf8, 0x02 | 0x04, null, output);
}

pub export fn sqlite3_open16(filename: ?*const anyopaque, output: ?*?*sqlite3) callconv(.c) c_int {
    return openConnection16(filename, output);
}

/// Source `connectionIsBusy()`: a connection remains live while any prepared
/// statement, incremental blob cursor, or backup endpoint owns native state.
fn connectionIsBusy(connection: *const Connection) bool {
    return connection.active_statements != 0 or connection.active_blobs != 0 or connection.active_backups != 0;
}

/// Source `sqlite3RollbackAll()`: roll back the connection pager, preserve the
/// first rollback failure, trip subsequent work with the requested result,
/// and invoke the rollback hook only for an active write transaction.
fn rollbackAll(connection: *Connection, trip_code: ResultCode) void {
    const database = connection.database orelse return;
    const state = database.pager.state;
    const was_writing = state == .writer_locked or state == .writer_cache_modified or
        state == .writer_database_modified or state == .writer_finished;
    const result = database.pager.rollback();
    if (result != .ok) {
        connection.last_result = result;
    } else if (trip_code != .ok and was_writing) {
        connection.last_result = trip_code;
    }
    if (was_writing) {
        if (connection.rollback_callback) |callback| callback(connection.rollback_context);
    }
}

pub export fn sqlite3_close(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.ok.toC();
    if (connectionIsBusy(connection)) return ResultCode.busy.toC();
    return connection.finishClose().toC();
}

pub export fn sqlite3_close_v2(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.ok.toC();
    if (connectionIsBusy(connection)) {
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

/// Source `sqlite3_db_config()`: serialize per-connection main-schema,
/// lookaside, and boolean option changes through one operation dispatcher.
fn configureDatabase(connection: *Connection, operation: c_int, pointer: ?*anyopaque, first: c_int, second: c_int, output: ?*c_int) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    switch (operation) {
        1000 => {
            const raw_name: [*:0]const u8 = if (pointer) |value| @ptrCast(value) else return ResultCode.misuse.toC();
            const replacement = connection.allocator.dupeZ(u8, std.mem.span(raw_name)) catch return ResultCode.no_memory.toC();
            if (connection.main_schema_name) |old| connection.allocator.free(old);
            connection.main_schema_name = replacement;
        },
        1001 => {
            if (first < 0 or second < 0) return ResultCode.misuse.toC();
            if (connection.lookaside_allocator == null) {
                connection.lookaside_allocator = lookaside.Lookaside.init(&global.memory.process_manager);
            }
            const byte_count = std.math.mul(usize, @intCast(first), @intCast(second)) catch return ResultCode.misuse.toC();
            const external: ?[]align(8) u8 = if (pointer) |raw| @as([*]align(8) u8, @ptrCast(@alignCast(raw)))[0..byte_count] else null;
            connection.lookaside_allocator.?.configure(external, first, second) catch |failure| return switch (failure) {
                error.Busy => ResultCode.busy.toC(),
                error.OutOfMemory => ResultCode.no_memory.toC(),
            };
        },
        else => {
            const index = operation - 1000;
            if (index < 2 or index >= @as(c_int, @intCast(connection.database_configuration.len))) return ResultCode.error_.toC();
            const slot: usize = @intCast(index);
            if (first >= 0) {
                connection.database_configuration[slot] = @intFromBool(first != 0);
            }
            if (operation == 1005) {
                connection.load_extension_enabled = connection.database_configuration[slot] != 0;
            }
            if (output) |result| {
                result.* = connection.database_configuration[slot];
            }
        },
    }
    return ResultCode.ok.toC();
}

pub export fn zig_sqlite3_db_config_main_name(pointer: ?*sqlite3, name: ?[*:0]const u8) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureDatabase(connection, 1000, if (name) |value| @ptrCast(@constCast(value)) else null, 0, 0, null);
}

pub export fn zig_sqlite3_db_config_lookaside(pointer: ?*sqlite3, storage: ?*anyopaque, slot_size: c_int, slot_count: c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureDatabase(connection, 1001, storage, slot_size, slot_count, null);
}

pub export fn zig_sqlite3_db_config_flag(pointer: ?*sqlite3, operation: c_int, enabled: c_int, output: ?*c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureDatabase(connection, operation, null, enabled, 0, output);
}

pub export fn zig_sqlite3_vtab_config(pointer: ?*sqlite3, operation: c_int, _: c_int) callconv(.c) c_int {
    _ = asConnection(pointer) orelse return ResultCode.misuse.toC();
    return switch (operation) {
        1, 2, 3, 4 => ResultCode.ok.toC(),
        else => ResultCode.misuse.toC(),
    };
}

/// Source `sqlite3_enable_load_extension()`: atomically toggle both the C API
/// loader and SQL load_extension permission represented by configuration 1005.
fn enableLoadExtension(connection: *Connection, enabled: bool) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.load_extension_enabled = enabled;
    connection.database_configuration[5] = @intFromBool(enabled);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_enable_load_extension(pointer: ?*sqlite3, enabled: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    return enableLoadExtension(connection, enabled != 0);
}

fn derivedExtensionEntry(path: []const u8, include_digits: bool, buffer: []u8) [:0]const u8 {
    const prefix = "sqlite3_";
    @memcpy(buffer[0..prefix.len], prefix);
    var output_index = prefix.len;
    var input_index = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    if (path.len - input_index >= 3 and std.ascii.eqlIgnoreCase(path[input_index .. input_index + 3], "lib")) {
        input_index += 3;
    }
    while (input_index < path.len and path[input_index] != '.') : (input_index += 1) {
        const byte = path[input_index];
        if (std.ascii.isAlphabetic(byte) or (include_digits and std.ascii.isDigit(byte))) {
            buffer[output_index] = std.ascii.toLower(byte);
            output_index += 1;
        }
    }
    const suffix = "_init";
    @memcpy(buffer[output_index .. output_index + suffix.len], suffix);
    output_index += suffix.len;
    buffer[output_index] = 0;
    return buffer[0..output_index :0];
}

/// Source `sqlite3LoadExtension()`: enforce opt-in and pathname limits, try
/// the platform suffix and derived entry names, preserve initializer errors,
/// and retain successful handles until the connection is destroyed.
fn loadExtension(connection: *Connection, path_pointer: [*:0]const u8, entry_name: ?[*:0]const u8, error_message: ?*?[*:0]u8) c_int {
    if (error_message) |output| output.* = null;
    if (!connection.load_extension_enabled) {
        setExtensionError(error_message, "not authorized");
        return ResultCode.error_.toC();
    }
    const path = std.mem.span(path_pointer);
    if (path.len == 0 or path.len > 4096) {
        setExtensionError(error_message, "unable to open shared library");
        return ResultCode.error_.toC();
    }

    var handle = dlopen(path_pointer, 0x02);
    if (handle == null and path.len + 3 <= 4096) {
        const alternate = std.fmt.allocPrintSentinel(connection.allocator, "{s}.so", .{path}, 0) catch return ResultCode.no_memory.toC();
        defer connection.allocator.free(alternate);
        handle = dlopen(alternate, 0x02);
    }
    const loaded = handle orelse {
        const message = if (dlerror()) |value| std.mem.span(value) else "unable to open shared library";
        setExtensionError(error_message, message);
        return ResultCode.error_.toC();
    };

    var entry_pointer = if (entry_name) |name| dlsym(loaded, name) else dlsym(loaded, "sqlite3_extension_init");
    var derived_buffer: [4128]u8 = undefined;
    var selected_name: []const u8 = if (entry_name) |name| std.mem.span(name) else "sqlite3_extension_init";
    if (entry_pointer == null and entry_name == null) {
        const letters = derivedExtensionEntry(path, false, &derived_buffer);
        selected_name = letters;
        entry_pointer = dlsym(loaded, letters);
        if (entry_pointer == null) {
            const alphanumeric = derivedExtensionEntry(path, true, &derived_buffer);
            selected_name = alphanumeric;
            entry_pointer = dlsym(loaded, alphanumeric);
        }
    }
    const raw_entry = entry_pointer orelse {
        var message_buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "no entry point [{s}] in shared library [{s}]", .{ selected_name, path }) catch "extension entry point not found";
        setExtensionError(error_message, message);
        _ = dlclose(loaded);
        return ResultCode.error_.toC();
    };
    const entry: ExtensionEntry = @ptrCast(@alignCast(raw_entry));
    var extension_error: ?[*:0]u8 = null;
    const result = entry(toOpaque(connection), &extension_error, public_api.extensionApi());
    if (result != ResultCode.ok.toC()) {
        if (result == 256) {
            if (extension_error) |message| public_api.sqlite3_free(message);
            return ResultCode.ok.toC();
        }
        if (error_message) |output| {
            if (extension_error) |message| {
                const detail = std.mem.span(message);
                var message_buffer: [512]u8 = undefined;
                const formatted = std.fmt.bufPrint(&message_buffer, "error during initialization: {s}", .{detail}) catch detail;
                setExtensionError(output, formatted);
                public_api.sqlite3_free(message);
            } else {
                setExtensionError(output, "extension initialization failed");
            }
        } else if (extension_error) |message| {
            public_api.sqlite3_free(message);
        }
        _ = dlclose(loaded);
        return ResultCode.error_.toC();
    }
    if (extension_error) |message| public_api.sqlite3_free(message);
    connection.extension_handles.append(connection.allocator, loaded) catch return ResultCode.no_memory.toC();
    return ResultCode.ok.toC();
}

pub export fn sqlite3_load_extension(
    pointer: ?*sqlite3,
    file: ?[*:0]const u8,
    entry_name: ?[*:0]const u8,
    error_message: ?*?[*:0]u8,
) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    const path = file orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return loadExtension(connection, path, entry_name, error_message);
}

/// Source `loadExt()`: SQL-facing extension loading with opt-in enforcement
/// and extension-owned error propagation.
fn loadExtensionSqlFunction(context: ?*statement.sqlite3_context, argument_count: c_int, arguments: [*]?*statement.sqlite3_value) callconv(.c) void {
    if (argument_count != 1 and argument_count != 2) {
        statement.sqlite3_result_error_code(context, ResultCode.misuse.toC());
        return;
    }
    const connection: *Connection = @ptrCast(@alignCast(statement.sqlite3_user_data(context) orelse {
        statement.sqlite3_result_error_code(context, ResultCode.misuse.toC());
        return;
    }));
    const path = statement.sqlite3_value_text(arguments[0]) orelse return;
    const entry = if (argument_count == 2) statement.sqlite3_value_text(arguments[1]) else null;
    var message: ?[*:0]u8 = null;
    const rc = loadExtension(connection, path, entry, &message);
    if (rc != ResultCode.ok.toC()) {
        if (message) |text| {
            statement.sqlite3_result_error(context, text, -1);
            public_api.sqlite3_free(text);
        } else {
            statement.sqlite3_result_error_code(context, rc);
        }
    }
}

/// Source `sqlite3ErrStr()`: retain the two execution-result messages and the
/// rollback-specific extended abort before mapping primary result codes.
fn errorString(code: c_int) [*:0]const u8 {
    if (code == 516) return "abort due to ROLLBACK";
    if (code == 100) return "another row available";
    if (code == 101) return "no more rows available";
    return switch (code & 0xff) {
        0 => "not an error",
        1 => "SQL logic error",
        3 => "access permission denied",
        4 => "query aborted",
        5 => "database is locked",
        6 => "database table is locked",
        7 => "out of memory",
        8 => "attempt to write a readonly database",
        9 => "interrupted",
        10 => "disk I/O error",
        11 => "database disk image is malformed",
        12 => "unknown operation",
        13 => "database or disk is full",
        14 => "unable to open database file",
        15 => "locking protocol",
        17 => "database schema has changed",
        18 => "string or blob too big",
        19 => "constraint failed",
        20 => "datatype mismatch",
        21 => "bad parameter or other API misuse",
        23 => "authorization denied",
        25 => "column index out of range",
        26 => "file is not a database",
        27 => "notification message",
        28 => "warning message",
        else => "unknown error",
    };
}

fn resultMessage(result: ResultCode) [*:0]const u8 {
    return errorString(result.toC());
}

/// Sources `sqlite3_errcode()` and `sqlite3_extended_errcode()`: validate and
/// serialize access to the connection error, applying the configured primary
/// result-code mask only for the non-extended query.
fn connectionErrorCode(connection: *Connection, extended: bool) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const code = connection.last_result.toC();
    return if (extended) code else code & connection.error_mask;
}

pub export fn sqlite3_errcode(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = safetyCheckSickOrOk(pointer) orelse return ResultCode.no_memory.toC();
    return connectionErrorCode(connection, false);
}
pub export fn sqlite3_extended_errcode(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = safetyCheckSickOrOk(pointer) orelse return ResultCode.no_memory.toC();
    return connectionErrorCode(connection, true);
}

/// Source `sqlite3_errmsg()`: return the connection-owned diagnostic or the
/// stable result-code text under the recursive connection mutex.
fn connectionErrorMessage(connection: *Connection) [*:0]const u8 {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    if (connection.custom_error_message) |message| return message.ptr;
    return resultMessage(connection.last_result);
}

pub export fn sqlite3_errmsg(pointer: ?*sqlite3) callconv(.c) [*:0]const u8 {
    const connection = safetyCheckSickOrOk(pointer) orelse return resultMessage(.no_memory);
    return connectionErrorMessage(connection);
}
/// Source `sqlite3SystemError()`: retain the VFS errno only for CANTOPEN and
/// IOERR primary results, excluding allocator-originated IOERR_NOMEM.
fn systemError(connection: *Connection, code: c_int) void {
    if (code == btree.vfs.IOERR_NOMEM) return;
    const primary = code & 0xff;
    if (primary != btree.vfs.CANTOPEN and primary != btree.vfs.IOERR) return;
    const database = connection.database orelse return;
    const get_last_error = database.pager.abi_vfs.xGetLastError orelse return;
    var buffer: [1]u8 = .{0};
    connection.system_errno = get_last_error(database.pager.abi_vfs, buffer.len, &buffer);
}

/// Source `sqlite3ErrorWithMsg()`: replace the connection error code and owned
/// UTF-8 diagnostic together, preserving system errno for OS failures.
fn errorWithMessage(connection: *Connection, code: c_int, message: ?[]const u8) c_int {
    if (connection.custom_error_message) |old| connection.allocator.free(old);
    connection.custom_error_message = null;
    connection.last_result = ResultCode.fromC(code);
    systemError(connection, code);
    if (message) |text| {
        connection.custom_error_message = connection.allocator.dupeZ(u8, text) catch {
            connection.last_result = .no_memory;
            return ResultCode.no_memory.toC();
        };
    }
    return ResultCode.ok.toC();
}

/// Source `sqlite3_set_errmsg()`: serialize extension-provided error state and
/// preserve the source API's OK return unless allocation itself fails.
fn setErrorMessage(connection: *Connection, code: c_int, message: ?[*:0]const u8) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return errorWithMessage(connection, code, if (message) |text| std.mem.span(text) else null);
}

pub export fn sqlite3_set_errmsg(pointer: ?*sqlite3, code: c_int, message: ?[*:0]const u8) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return setErrorMessage(connection, code, message);
}
threadlocal var error16_buffer: [128]u16 = undefined;

/// Source `sqlite3_errmsg16()`: validate the connection and transcode its
/// current UTF-8 diagnostic into native-endian UTF-16, including surrogate
/// pairs instead of widening individual UTF-8 bytes.
fn errorMessage16(pointer: ?*sqlite3) *const anyopaque {
    const message = std.mem.span(sqlite3_errmsg(pointer));
    const view = std.unicode.Utf8View.init(message) catch {
        error16_buffer[0] = 0xfffd;
        error16_buffer[1] = 0;
        return @ptrCast(&error16_buffer);
    };
    var iterator = view.iterator();
    var count: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            if (count + 1 >= error16_buffer.len) break;
            error16_buffer[count] = @intCast(codepoint);
            count += 1;
        } else {
            if (count + 2 >= error16_buffer.len) break;
            const adjusted = codepoint - 0x10000;
            error16_buffer[count] = @intCast(0xd800 + (adjusted >> 10));
            error16_buffer[count + 1] = @intCast(0xdc00 + (adjusted & 0x3ff));
            count += 2;
        }
    }
    error16_buffer[count] = 0;
    return @ptrCast(&error16_buffer);
}

pub export fn sqlite3_errmsg16(pointer: ?*sqlite3) callconv(.c) *const anyopaque {
    return errorMessage16(pointer);
}
pub export fn sqlite3_errstr(code: c_int) callconv(.c) [*:0]const u8 {
    return errorString(code);
}
/// Source `sqlite3_error_offset()`: expose an offset only while a connection
/// error is present, under the connection mutex.
fn connectionErrorOffset(connection: *Connection) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return if (connection.last_result != .ok) connection.error_offset else -1;
}

pub export fn sqlite3_error_offset(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = safetyCheckSickOrOk(pointer) orelse return -1;
    return connectionErrorOffset(connection);
}
pub export fn sqlite3_extended_result_codes(pointer: ?*sqlite3, enabled: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.error_mask = if (enabled != 0) -1 else 0xff;
    return ResultCode.ok.toC();
}
pub export fn sqlite3_db_mutex(pointer: ?*sqlite3) callconv(.c) ?*anyopaque {
    const connection = asConnection(pointer) orelse return null;
    return &connection.connection_mutex;
}

fn openAttachedDatabase(context: ?*anyopaque, filename: []const u8, allow_create: bool, allow_write: bool) ?*anyopaque {
    _ = allow_create;
    _ = allow_write;
    const connection: *Connection = @ptrCast(@alignCast(context orelse return null));
    if (filename.len != 0 and !std.mem.eql(u8, filename, ":memory:")) return null;
    return AttachedDatabase.createMemory(connection.allocator);
}

fn closeAttachedDatabase(_: ?*anyopaque, native: *anyopaque) void {
    const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
    attached.destroy();
}

fn ensureAttachmentCatalog(connection: *Connection) attachment_runtime.Error!*attachment_runtime.Connection {
    if (connection.attachments == null) {
        connection.attachments = try attachment_runtime.initializeConnection(
            connection.allocator,
            if (connection.filename) |filename| filename else "",
            connection,
            openAttachedDatabase,
            closeAttachedDatabase,
        );
        connection.attachments.?.maximum_attached = @intCast(@max(connection.limits[7], 0));
    }
    return &connection.attachments.?;
}

fn schemaSliceMatches(connection: *const Connection, requested: ?[]const u8) bool {
    const name = requested orelse return true;
    const expected = if (connection.main_schema_name) |main_name| main_name else "main";
    return std.ascii.eqlIgnoreCase(name, expected) or std.ascii.eqlIgnoreCase(name, "main");
}

fn schemaNameMatches(connection: *const Connection, database_name: ?[*:0]const u8) bool {
    return schemaSliceMatches(connection, if (database_name) |name| std.mem.span(name) else null);
}

fn attachedDatabaseByName(connection: *Connection, database_name: ?[*:0]const u8) ?*AttachedDatabase {
    const requested = if (database_name) |name| std.mem.span(name) else return null;
    const attachments = if (connection.attachments) |*catalog| catalog else return null;
    const entry = attachment_runtime.findDatabase(attachments, requested) orelse return null;
    const native = entry.native_context orelse return null;
    return @ptrCast(@alignCast(native));
}

/// Source `sqlite3_db_filename()`: resolve the selected schema and return the
/// canonical filename owned by its native pager.
fn databaseFilename(connection: *Connection, database_name: ?[*:0]const u8) ?[*:0]const u8 {
    if (schemaNameMatches(connection, database_name)) {
        if (connection.database == null and connection.pending_deserialize_readonly == null) return null;
        return if (connection.filename) |filename| filename.ptr else null;
    }
    const requested = if (database_name) |name| std.mem.span(name) else return null;
    const attachments = if (connection.attachments) |*catalog| catalog else return null;
    const entry = attachment_runtime.findDatabase(attachments, requested) orelse return null;
    if (entry.native_context == null) return null;
    return entry.filename.ptr;
}

pub export fn sqlite3_db_filename(pointer: ?*sqlite3, database_name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const connection = safetyCheckOk(pointer) orelse return null;
    return databaseFilename(connection, database_name);
}
/// Source `sqlite3_db_name()`: return the configured name of the selected
/// attached schema and reject out-of-range indexes.
fn databaseName(connection: *Connection, index: c_int) ?[*:0]const u8 {
    if (index < 0) return null;
    if (index == 0) return if (connection.main_schema_name) |name| name.ptr else "main";
    if (index == 1) return "temp";
    const attachments = if (connection.attachments) |*catalog| catalog else return null;
    const position: usize = @intCast(index);
    if (position >= attachments.databases.items.len) return null;
    return @ptrCast(attachments.databases.items[position].name.ptr);
}

pub export fn sqlite3_db_name(pointer: ?*sqlite3, index: c_int) callconv(.c) ?[*:0]const u8 {
    const connection = safetyCheckSickOrOk(pointer) orelse return null;
    return databaseName(connection, index);
}
/// Source `sqlite3_db_readonly()`: distinguish a missing schema from a valid
/// read-only or writable native B-tree.
fn databaseReadonly(connection: *Connection, database_name: ?[*:0]const u8) c_int {
    if (schemaNameMatches(connection, database_name)) {
        if (connection.database) |database| return @intFromBool(!database.writable);
        if (connection.pending_deserialize_readonly != null) return 0;
        return -1;
    }
    const attached = attachedDatabaseByName(connection, database_name) orelse return -1;
    if (attached.database) |database| return @intFromBool(!database.writable);
    if (attached.pending_deserialize_readonly != null) return 0;
    return -1;
}

pub export fn sqlite3_db_readonly(pointer: ?*sqlite3, database_name: ?[*:0]const u8) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return -1;
    return databaseReadonly(connection, database_name);
}

/// Source `sqlite3_get_autocommit()`: autocommit is disabled precisely while
/// the native pager owns a write transaction.
fn getAutocommit(connection: *Connection) c_int {
    if (connection.explicit_transaction) return 0;
    const database = connection.database orelse return 1;
    return switch (database.pager.state) {
        .writer_locked, .writer_cache_modified, .writer_database_modified, .writer_finished => 0,
        .open, .reader, .error_, .closed => 1,
    };
}

pub export fn sqlite3_get_autocommit(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return 0;
    return getAutocommit(connection);
}
const ScalarCallback = *const fn (?*statement.sqlite3_context, c_int, [*]?*statement.sqlite3_value) callconv(.c) void;
const FinalCallback = *const fn (?*statement.sqlite3_context) callconv(.c) void;
/// Source `sqlite3CreateFunc()`: validate callback families, normalize the
/// requested encoding, block replacement while statements are active, and
/// transfer function/destructor ownership into the connection registry.
fn createFunction(connection: *Connection, name: []const u8, argument_count: c_int, encoding_argument: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback, value_callback: ?FinalCallback, inverse_callback: ?ScalarCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) ResultCode {
    if (name.len == 0 or name.len > 255 or argument_count < -1 or argument_count > 127) {
        if (destroy_callback) |destroy| destroy(user_data);
        return .misuse;
    }
    var encoding = encoding_argument & 7;
    if (encoding == 4 or encoding == 5) {
        encoding = 1;
    }
    if (encoding < 1 or encoding > 3) {
        encoding = 1;
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
        if (existing.argument_count == argument_count and existing.encoding == encoding and std.ascii.eqlIgnoreCase(existing.name, name)) {
            if (connection.active_statements != 0) {
                if (destroy_callback) |destroy| destroy(user_data);
                connection.last_result = .busy;
                return .busy;
            }
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
    }, .argument_count = argument_count, .encoding = encoding, .callback = callback, .step_callback = step_callback, .final_callback = final_callback, .value_callback = value_callback, .inverse_callback = inverse_callback, .user_data = user_data, .database = connection, .destroy = destroy_callback };
    connection.scalar_functions.append(connection.allocator, definition) catch {
        connection.allocator.free(definition.name);
        connection.allocator.destroy(definition);
        if (destroy_callback) |destroy| destroy(user_data);
        return .no_memory;
    };
    return .ok;
}

/// Source `createFunctionApi()`: serialize registry mutation and funnel scalar,
/// aggregate, and window callbacks through the common ownership path.
fn createFunctionApi(connection: *Connection, name: []const u8, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback, value_callback: ?FinalCallback, inverse_callback: ?ScalarCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return createFunction(connection, name, argument_count, encoding, user_data, callback, step_callback, final_callback, value_callback, inverse_callback, destroy_callback).toC();
}

pub export fn sqlite3_create_function_v2(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, argument_count: c_int, encoding: c_int, user_data: ?*anyopaque, callback: ?ScalarCallback, step_callback: ?ScalarCallback, final_callback: ?FinalCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse {
        if (destroy_callback) |destroy| destroy(user_data);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |name| std.mem.span(name) else {
        if (destroy_callback) |destroy| destroy(user_data);
        return ResultCode.misuse.toC();
    };
    return createFunctionApi(connection, name, argument_count, encoding, user_data, callback, step_callback, final_callback, null, null, destroy_callback);
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
    return createFunctionApi(connection, name, argument_count, encoding, user_data, null, step_callback, final_callback, value_callback, inverse_callback, destroy_callback);
}

const CollationCallback = *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int;

/// Source `createCollation()`: normalize UTF-16-native encodings, refuse to
/// replace a collation while statements are active, release the old owner,
/// and install or delete the exact name/encoding entry.
fn createCollation(connection: *Connection, name: []const u8, encoding_argument: c_int, auxiliary: ?*anyopaque, compare: ?CollationCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) ResultCode {
    if (name.len == 0 or name.len > 255) return .misuse;
    var base_encoding = encoding_argument & 7;
    if (base_encoding == 4 or encoding_argument == 8) {
        base_encoding = if (builtin.target.cpu.arch.endian() == .little) 2 else 3;
    }
    if (base_encoding < 1 or base_encoding > 3) return .misuse;
    const encoding = base_encoding | (encoding_argument & 8);

    var existing_index: ?usize = null;
    for (connection.collations.items, 0..) |collation, index| {
        if (collation.encoding == encoding and std.ascii.eqlIgnoreCase(collation.name, name)) {
            existing_index = index;
            break;
        }
    }
    if (existing_index != null and connection.active_statements != 0) {
        connection.last_result = .busy;
        return .busy;
    }
    if (existing_index) |index| {
        const old = connection.collations.orderedRemove(index);
        if (old.destroy) |destroy| destroy(old.auxiliary);
        connection.allocator.free(old.name);
    }
    const callback = compare orelse return .ok;
    const owned = connection.allocator.dupeZ(u8, name) catch return .no_memory;
    connection.collations.append(connection.allocator, .{ .name = owned, .encoding = encoding, .auxiliary = auxiliary, .compare = callback, .destroy = destroy_callback }) catch {
        connection.allocator.free(owned);
        return .no_memory;
    };
    connection.last_result = .ok;
    return .ok;
}

pub export fn sqlite3_create_collation_v2(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, encoding: c_int, auxiliary: ?*anyopaque, compare: ?CollationCallback, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    const name = if (name_pointer) |value| std.mem.span(value) else return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return createCollation(connection, name, encoding, auxiliary, compare, destroy_callback).toC();
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
/// Source `sqlite3_collation_needed()`: atomically replace the UTF-8 factory
/// and disable the mutually exclusive UTF-16 factory.
fn configureCollationNeeded(connection: *Connection, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, [*:0]const u8) callconv(.c) void) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.collation_needed_context = context;
    connection.collation_needed_callback = callback;
    connection.collation_needed16_callback = null;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_collation_needed(pointer: ?*sqlite3, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, [*:0]const u8) callconv(.c) void) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureCollationNeeded(connection, context, callback);
}

/// Source `sqlite3_collation_needed16()`: atomically replace the UTF-16
/// factory and disable the mutually exclusive UTF-8 factory.
fn configureCollationNeeded16(connection: *Connection, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, *const anyopaque) callconv(.c) void) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.collation_needed_context = context;
    connection.collation_needed_callback = null;
    connection.collation_needed16_callback = callback;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_collation_needed16(pointer: ?*sqlite3, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, ?*sqlite3, c_int, *const anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureCollationNeeded16(connection, context, callback);
}

/// Source `sqlite3InvalidFunction()`: retain an overload placeholder for name
/// resolution but report the overloaded function's name if it executes.
fn invalidFunction(context: ?*statement.sqlite3_context, _: c_int, _: [*]?*statement.sqlite3_value) callconv(.c) void {
    const raw_name = statement.sqlite3_user_data(context) orelse {
        statement.sqlite3_result_error_code(context, ResultCode.error_.toC());
        return;
    };
    const name: [*:0]const u8 = @ptrCast(raw_name);
    var buffer: [384]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buffer, "unable to use function {s} in the requested context", .{std.mem.span(name)}) catch "unable to use overloaded function in the requested context";
    statement.sqlite3_result_error(context, message, -1);
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
/// Source `sqlite3_overload_function()`: retain an existing global function or
/// install an owned invalid-function placeholder for virtual-table overloads.
fn overloadFunction(connection: *Connection, name_pointer: [*:0]const u8, argument_count: c_int) c_int {
    if (argument_count < -2) return ResultCode.misuse.toC();
    const name = std.mem.span(name_pointer);
    connection.connection_mutex.enter();
    const found = if (argument_count >= 0) connection.findScalar(name, @intCast(argument_count)) != null else blk: {
        for (connection.scalar_functions.items) |definition| {
            if (std.ascii.eqlIgnoreCase(definition.name, name)) break :blk true;
        }
        break :blk false;
    };
    connection.connection_mutex.leave();
    if (found) return ResultCode.ok.toC();
    const allocation = public_api.sqlite3_malloc64(name.len + 1) orelse return ResultCode.no_memory.toC();
    const copy: [*]u8 = @ptrCast(allocation);
    @memcpy(copy[0..name.len], name);
    copy[name.len] = 0;
    return sqlite3_create_function_v2(toOpaque(connection), name_pointer, argument_count, 1, allocation, invalidFunction, null, null, &public_api.sqlite3_free);
}

pub export fn sqlite3_overload_function(pointer: ?*sqlite3, name: ?[*:0]const u8, argument_count: c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return overloadFunction(connection, name orelse return ResultCode.misuse.toC(), argument_count);
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
    while (index < connection.modules.items.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(connection.modules.items[index].name, name)) {
            const old = connection.modules.orderedRemove(index);
            if (old.destroy) |destroy| destroy(old.auxiliary);
            connection.allocator.free(old.name);
            break;
        }
    }
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
            while (names[at]) |name| : (at += 1) {
                if (std.ascii.eqlIgnoreCase(connection.modules.items[index].name, std.mem.span(name))) {
                    keep = true;
                    break;
                }
            }
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

/// Source `sqlite3_get_clientdata()`.
fn getClientData(connection: *Connection, name: []const u8) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    for (connection.client_data.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

pub export fn sqlite3_get_clientdata(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return getClientData(connection, if (name_pointer) |value| std.mem.span(value) else return null);
}

/// Source `sqlite3_set_clientdata()`: replace or unlink named client state,
/// invoking old and rejected-value destructors with source ownership semantics.
fn setClientData(connection: *Connection, name: []const u8, value: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    for (connection.client_data.items, 0..) |*entry, index| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (entry.destroy) |destroy| destroy(entry.value);
        if (value == null) {
            const removed = connection.client_data.orderedRemove(index);
            connection.allocator.free(removed.name);
            return ResultCode.ok.toC();
        }
        entry.value = value;
        entry.destroy = destroy_callback;
        return ResultCode.ok.toC();
    }
    if (value == null) return ResultCode.ok.toC();
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

pub export fn sqlite3_set_clientdata(pointer: ?*sqlite3, name_pointer: ?[*:0]const u8, value: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse {
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.misuse.toC();
    };
    const name = if (name_pointer) |item| std.mem.span(item) else {
        if (destroy_callback) |destroy| destroy(value);
        return ResultCode.misuse.toC();
    };
    return setClientData(connection, name, value, destroy_callback);
}

/// Source `sqlite3_trace()`: replace the legacy statement trace under the
/// connection mutex and return the previous callback context.
fn configureLegacyTrace(connection: *Connection, callback: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, context: ?*anyopaque) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const previous = connection.legacy_trace_context;
    connection.legacy_trace_callback = callback;
    connection.legacy_trace_context = context;
    connection.trace_v2_callback = null;
    connection.trace_v2_mask = 0;
    connection.legacy_profile_callback = null;
    return previous;
}

pub export fn sqlite3_trace(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return configureLegacyTrace(connection, callback, context);
}

/// Source `sqlite3_profile()`: replace the legacy profile callback and return
/// its previous context without conflating the callback pointer with pArg.
fn configureProfile(connection: *Connection, callback: ?*const fn (?*anyopaque, [*:0]const u8, u64) callconv(.c) void, context: ?*anyopaque) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const previous = connection.legacy_profile_context;
    connection.legacy_profile_callback = callback;
    connection.legacy_profile_context = context;
    return previous;
}

pub export fn sqlite3_profile(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, [*:0]const u8, u64) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return configureProfile(connection, callback, context);
}

/// Source `sqlite3_trace_v2()`: normalize callback/mask disabling and replace
/// legacy trace modes atomically with the version-2 registration.
fn configureTraceV2(connection: *Connection, requested_mask: c_uint, callback: ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const mask = if (callback == null) 0 else requested_mask & 0x0f;
    connection.trace_v2_callback = if (mask == 0) null else callback;
    connection.trace_v2_context = context;
    connection.trace_v2_mask = mask;
    connection.legacy_trace_callback = null;
    connection.legacy_profile_callback = null;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_trace_v2(pointer: ?*sqlite3, mask: c_uint, callback: ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureTraceV2(connection, mask, callback, context);
}

/// Source `sqlite3_autovacuum_pages()`: destroy the previous context before
/// atomically installing its replacement hook and ownership callback.
fn configureAutovacuumPages(connection: *Connection, callback: ?*const fn (?*anyopaque, [*:0]const u8, c_uint, c_uint, c_uint) callconv(.c) c_uint, context: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    if (connection.autovacuum_destroy) |destroy| destroy(connection.autovacuum_context);
    connection.autovacuum_callback = callback;
    connection.autovacuum_context = context;
    connection.autovacuum_destroy = destroy_callback;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_autovacuum_pages(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, [*:0]const u8, c_uint, c_uint, c_uint) callconv(.c) c_uint, context: ?*anyopaque, destroy_callback: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse {
        if (destroy_callback) |destroy| destroy(context);
        return ResultCode.misuse.toC();
    };
    return configureAutovacuumPages(connection, callback, context, destroy_callback);
}

/// Source `sqlite3_commit_hook()`.
fn configureCommitHook(connection: *Connection, callback: ?*const fn (?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const previous = connection.commit_context;
    connection.commit_callback = callback;
    connection.commit_context = context;
    return previous;
}

pub export fn sqlite3_commit_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return configureCommitHook(connection, callback, context);
}

/// Source `sqlite3_rollback_hook()`.
fn configureRollbackHook(connection: *Connection, callback: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const previous = connection.rollback_context;
    connection.rollback_callback = callback;
    connection.rollback_context = context;
    return previous;
}

pub export fn sqlite3_rollback_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return configureRollbackHook(connection, callback, context);
}

/// Source `sqlite3_update_hook()`.
fn configureUpdateHook(connection: *Connection, callback: ?*const fn (?*anyopaque, c_int, [*:0]const u8, [*:0]const u8, i64) callconv(.c) void, context: ?*anyopaque) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const previous = connection.update_context;
    connection.update_callback = callback;
    connection.update_context = context;
    return previous;
}

pub export fn sqlite3_update_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, c_int, [*:0]const u8, [*:0]const u8, i64) callconv(.c) void, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return configureUpdateHook(connection, callback, context);
}

pub export fn sqlite3_set_authorizer(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.authorizer_callback = callback;
    connection.authorizer_context = context;
    return ResultCode.ok.toC();
}
/// Source `sqlite3_progress_handler()`.
fn configureProgressHandler(connection: *Connection, interval: c_int, callback: ?*const fn (?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) void {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    if (interval > 0) {
        connection.progress_callback = callback;
        connection.progress_context = context;
        connection.progress_interval = @intCast(interval);
    } else {
        connection.progress_callback = null;
        connection.progress_context = null;
        connection.progress_interval = 0;
    }
}

pub export fn sqlite3_progress_handler(pointer: ?*sqlite3, interval: c_int, callback: ?*const fn (?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) void {
    const connection = safetyCheckOk(pointer) orelse return;
    configureProgressHandler(connection, interval, callback, context);
}

/// Source `sqlite3_busy_handler()`: reset callback invocation state, timeout,
/// and set-lock timeout whenever the application replaces the handler.
fn configureBusyHandler(connection: *Connection, callback: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int, context: ?*anyopaque) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.busy_callback = callback;
    connection.busy_context = context;
    connection.busy_calls = 0;
    connection.busy_timeout_ms = 0;
    connection.setlk_timeout_ms = 0;
    if (connection.database) |database| database.pager.setBusyHandler(if (callback != null) Connection.pagerBusy else null, connection);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_busy_handler(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureBusyHandler(connection, callback, context);
}

/// Source `sqlite3_busy_timeout()`: install or remove the default sleeping
/// busy handler and synchronize the set-lock timeout with it.
fn configureBusyTimeout(connection: *Connection, milliseconds: c_int) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.busy_callback = null;
    connection.busy_context = null;
    connection.busy_timeout_ms = @max(milliseconds, 0);
    connection.setlk_timeout_ms = if (milliseconds > 0) milliseconds else 0;
    connection.busy_calls = 0;
    if (connection.database) |database| database.pager.setBusyHandler(if (milliseconds > 0) Connection.pagerBusy else null, connection);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_busy_timeout(pointer: ?*sqlite3, milliseconds: c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureBusyTimeout(connection, milliseconds);
}

/// Source `sqlite3_setlk_timeout()`: retain the blocking-lock timeout/flags
/// and signal BLOCK_ON_CONNECT through the database VFS file control.
fn setLockTimeout(connection: *Connection, milliseconds: c_int, flags: c_int) c_int {
    if (milliseconds < -1) return ResultCode.range.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.setlk_timeout_ms = milliseconds;
    connection.setlk_flags = flags;
    if (connection.database) |database| {
        if (database.pager.file.pMethods) |methods| {
            if (methods.xFileControl) |control| {
                var block_on_connect: c_int = @intFromBool(flags & 1 != 0);
                _ = control(database.pager.file, 44, @ptrCast(&block_on_connect));
            }
        }
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_setlk_timeout(pointer: ?*sqlite3, milliseconds: c_int, flags: c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return setLockTimeout(connection, milliseconds, flags);
}

/// Source `sqlite3_interrupt()`: set the pending interrupt regardless of the
/// current statement count so active or concurrently-starting work observes it.
fn interruptConnection(connection: *Connection) void {
    connection.interrupted = true;
}

pub export fn sqlite3_interrupt(pointer: ?*sqlite3) callconv(.c) void {
    const connection = asConnection(pointer) orelse return;
    interruptConnection(connection);
}
/// Source `sqlite3_is_interrupted()`.
fn isConnectionInterrupted(connection: *Connection) c_int {
    return @intFromBool(connection.interrupted);
}

pub export fn sqlite3_is_interrupted(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return 0;
    return isConnectionInterrupted(connection);
}
/// Source `sqlite3_last_insert_rowid()`.
fn lastInsertRowid(connection: *Connection) i64 {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return connection.last_insert_rowid;
}

pub export fn sqlite3_last_insert_rowid(pointer: ?*sqlite3) callconv(.c) i64 {
    const connection = safetyCheckOk(pointer) orelse return 0;
    return lastInsertRowid(connection);
}

/// Source `sqlite3_set_last_insert_rowid()`.
fn setLastInsertRowid(connection: *Connection, value: i64) void {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.last_insert_rowid = value;
}

pub export fn sqlite3_set_last_insert_rowid(pointer: ?*sqlite3, value: i64) callconv(.c) void {
    const connection = safetyCheckOk(pointer) orelse return;
    setLastInsertRowid(connection, value);
}

/// Source `sqlite3_changes64()`.
fn connectionChanges64(connection: *Connection) i64 {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return connection.changes;
}

pub export fn sqlite3_changes(pointer: ?*sqlite3) callconv(.c) c_int {
    return @intCast(@min(sqlite3_changes64(pointer), std.math.maxInt(c_int)));
}
pub export fn sqlite3_changes64(pointer: ?*sqlite3) callconv(.c) i64 {
    const connection = safetyCheckOk(pointer) orelse return 0;
    return connectionChanges64(connection);
}

/// Source `sqlite3_total_changes64()`.
fn connectionTotalChanges64(connection: *Connection) i64 {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return connection.total_changes;
}

pub export fn sqlite3_total_changes(pointer: ?*sqlite3) callconv(.c) c_int {
    return @intCast(@min(sqlite3_total_changes64(pointer), std.math.maxInt(c_int)));
}
pub export fn sqlite3_total_changes64(pointer: ?*sqlite3) callconv(.c) i64 {
    const connection = safetyCheckOk(pointer) orelse return 0;
    return connectionTotalChanges64(connection);
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

const hard_limits = [13]c_int{
    @intCast(profile_limits.max_length),
    @intCast(profile_limits.max_sql_length),
    @intCast(profile_limits.max_column),
    @intCast(profile_limits.max_expr_depth),
    @intCast(profile_limits.max_compound_select),
    @intCast(profile_limits.max_vdbe_op),
    @intCast(profile_limits.max_function_arg),
    @intCast(profile_limits.max_attached),
    @intCast(profile_limits.max_like_pattern_length),
    @intCast(profile_limits.max_variable_number),
    @intCast(profile_limits.max_trigger_depth),
    @intCast(profile_limits.max_worker_threads),
    @intCast(profile_limits.max_parser_depth),
};

/// Source `sqlite3_limit()`: serialize updates and clamp each run-time value
/// to its compile-time hard bound, including the minimum length limit.
fn connectionLimit(connection: *Connection, category: c_int, value: c_int) c_int {
    if (category < 0 or category >= connection.limits.len) return -1;
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const index: usize = @intCast(category);
    const previous = connection.limits[index];
    if (value >= 0) {
        var replacement = @min(value, hard_limits[index]);
        if (index == 0) {
            replacement = @max(replacement, @as(c_int, @intCast(profile_limits.min_length)));
        }
        connection.limits[index] = replacement;
    }
    return previous;
}

pub export fn sqlite3_limit(pointer: ?*sqlite3, category: c_int, value: c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return -1;
    return connectionLimit(connection, category, value);
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
    incompatible: bool = false,

    fn deinit(self: *TableCollector) void {
        for (self.values.items) |value| {
            if (value) |bytes| {
                self.allocator.free(bytes);
            }
        }
        self.values.deinit(self.allocator);
    }
};

/// Source `sqlite3_get_table_cb()`: reserve column names on the first row,
/// reject incompatible statements in a multi-statement input, preserve SQL
/// NULL pointers, and retain every copied value in row-major order.
fn getTableCallback(context: ?*anyopaque, count: c_int, row: [*]?[*:0]const u8, names: [*]?[*:0]const u8) callconv(.c) c_int {
    const collector: *TableCollector = @ptrCast(@alignCast(context orelse return 1));
    if (collector.columns == 0) {
        collector.columns = count;
        for (0..@intCast(count)) |index| {
            const name = if (names[index]) |value| collector.allocator.dupeZ(u8, std.mem.span(value)) catch {
                collector.failed = true;
                return 1;
            } else null;
            collector.values.append(collector.allocator, name) catch {
                if (name) |bytes| collector.allocator.free(bytes);
                collector.failed = true;
                return 1;
            };
        }
    } else if (collector.columns != count) {
        collector.incompatible = true;
        return 1;
    }
    for (0..@intCast(count)) |index| {
        const value = if (row[index]) |bytes| collector.allocator.dupeZ(u8, std.mem.span(bytes)) catch {
            collector.failed = true;
            return 1;
        } else null;
        collector.values.append(collector.allocator, value) catch {
            if (value) |bytes| collector.allocator.free(bytes);
            collector.failed = true;
            return 1;
        };
    }
    return 0;
}

pub export fn sqlite3_get_table(database: ?*sqlite3, sql: ?[*:0]const u8, result_output: ?*?[*]?[*:0]u8, row_count: ?*c_int, column_count: ?*c_int, error_output: ?*?[*:0]u8) callconv(.c) c_int {
    if (result_output == null or row_count == null or column_count == null) return ResultCode.misuse.toC();
    result_output.?.* = null;
    row_count.?.* = 0;
    column_count.?.* = 0;
    if (error_output) |output| output.* = null;
    var collector = TableCollector{ .allocator = std.heap.c_allocator };
    defer collector.deinit();
    const rc = sqlite3_exec(database, sql, getTableCallback, &collector, error_output);
    if (rc != ResultCode.ok.toC()) {
        if (collector.failed) return ResultCode.no_memory.toC();
        if (collector.incompatible) {
            if (error_output) |output| {
                if (output.*) |old| public_api.sqlite3_free(old);
                setExtensionError(output, "sqlite3_get_table() called with two or more incompatible queries");
            }
            return ResultCode.error_.toC();
        }
        return rc;
    }
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
threadlocal var metadata_collation_buffer: [128]u8 = undefined;
fn hasAutoincrement(token_list: []const Token) bool {
    for (token_list) |token| if (token.typ == tokens.tk_autoincr) return true;
    return false;
}
/// Source `sqlite3_table_column_metadata()`: resolve a table column under the
/// connection mutex and return declared type, collation, constraints, and
/// autoincrement metadata from its stored CREATE TABLE statement.
fn tableColumnMetadata(connection: *Connection, database_name: ?[*:0]const u8, table_name: [*:0]const u8, column_name: ?[*:0]const u8, type_output: ?*?[*:0]const u8, collation_output: ?*?[*:0]const u8, not_null_output: ?*c_int, primary_key_output: ?*c_int, autoincrement_output: ?*c_int) c_int {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    if (type_output) |output| output.* = null;
    if (collation_output) |output| output.* = null;
    if (not_null_output) |output| output.* = 0;
    if (primary_key_output) |output| output.* = 0;
    if (autoincrement_output) |output| output.* = 0;
    const requested_database = if (database_name) |name| std.mem.span(name) else "main";
    const located = locateDatabase(connection, if (schemaNameMatches(connection, database_name)) null else requested_database);
    if (located.result != .ok) return (if (located.result == .not_found) ResultCode.error_ else located.result).toC();
    const schema_outcome = located.database.?.schemaTable(std.mem.span(table_name));
    if (schema_outcome.result != .ok) return schema_outcome.result.toC();
    var schema = schema_outcome.table.?;
    defer schema.deinit();
    if (column_name == null) return ResultCode.ok.toC();
    const resolved = resolveColumns(connection.allocator, schema.sql) catch return ResultCode.no_memory.toC();
    defer {
        connection.allocator.free(resolved.columns);
        connection.allocator.free(resolved.tokens);
        connection.allocator.free(resolved.source);
    }
    const requested_column = std.mem.span(column_name.?);
    var rowid_alias = std.ascii.eqlIgnoreCase(requested_column, "rowid") or std.ascii.eqlIgnoreCase(requested_column, "oid") or std.ascii.eqlIgnoreCase(requested_column, "_rowid_");
    for (resolved.columns) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, requested_column) and !(rowid_alias and item.integer_primary_key)) continue;
        rowid_alias = false;
        if (type_output) |output| {
            const count = @min(item.declared_type.len, metadata_type_buffer.len - 1);
            @memcpy(metadata_type_buffer[0..count], item.declared_type[0..count]);
            metadata_type_buffer[count] = 0;
            output.* = @ptrCast(&metadata_type_buffer);
        }
        if (collation_output) |output| {
            const count = @min(item.collation.len, metadata_collation_buffer.len - 1);
            @memcpy(metadata_collation_buffer[0..count], item.collation[0..count]);
            metadata_collation_buffer[count] = 0;
            output.* = @ptrCast(&metadata_collation_buffer);
        }
        if (not_null_output) |output| output.* = @intFromBool(item.not_null);
        if (primary_key_output) |output| output.* = @intFromBool(item.primary_key);
        if (autoincrement_output) |output| output.* = @intFromBool(item.integer_primary_key and hasAutoincrement(resolved.tokens));
        return ResultCode.ok.toC();
    }
    if (rowid_alias) {
        if (type_output) |output| output.* = "INTEGER";
        if (collation_output) |output| output.* = "BINARY";
        if (primary_key_output) |output| output.* = 1;
        return ResultCode.ok.toC();
    }
    return ResultCode.error_.toC();
}

pub export fn sqlite3_table_column_metadata(pointer: ?*sqlite3, database_name: ?[*:0]const u8, table_name: ?[*:0]const u8, column_name: ?[*:0]const u8, type_output: ?*?[*:0]const u8, collation_output: ?*?[*:0]const u8, not_null_output: ?*c_int, primary_key_output: ?*c_int, autoincrement_output: ?*c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return tableColumnMetadata(connection, database_name, table_name orelse return ResultCode.misuse.toC(), column_name, type_output, collation_output, not_null_output, primary_key_output, autoincrement_output);
}

/// Source `sqlite3LookasideUsed()`: return outstanding lookaside slots and
/// optionally expose/reset the connection highwater mark.
fn lookasideUsed(connection: *Connection, highwater: *i64, reset: bool) i64 {
    if (connection.lookaside_allocator) |*allocator| {
        const usage = allocator.used(reset);
        highwater.* = @intCast(usage.highwater);
        return @intCast(usage.current);
    }
    highwater.* = 0;
    return 0;
}

fn schemaMemoryUsed(connection: *const Connection) i64 {
    var total: usize = @sizeOf(schema_initialization.Schema) +
        connection.schema_model.objects.capacity * @sizeOf(schema_initialization.CatalogObject);
    for (connection.schema_model.objects.items) |object| {
        total += object.object_type.len + object.name.len + object.table_name.len;
        if (object.sql) |sql| {
            total += sql.len;
        }
    }
    return @intCast(@min(total, @as(usize, std.math.maxInt(i64))));
}

fn statementMemoryUsed(connection: *const Connection) i64 {
    var total: usize = 0;
    var prepared = connection.statement_head;
    while (prepared) |item| : (prepared = item.connection_next) {
        total += @sizeOf(statement.Statement) +
            item.bindings.len * @sizeOf(vdbe.Mem) +
            item.parameters.len * @sizeOf(statement.ParameterMetadata) +
            item.columns.len * @sizeOf(statement.ColumnMetadata);
        if (item.sql_copy) |sql| {
            total += sql.len + 1;
        }
    }
    return @intCast(@min(total, @as(usize, std.math.maxInt(i64))));
}

fn addDatabaseStatus(current: *i64, database: *btree.Database, operation: c_int, reset: bool) void {
    const value: u64 = switch (operation) {
        1, 11 => value: {
            const per_page = @as(usize, database.pager.page_size) + @sizeOf(page_cache.Page);
            const bytes = std.math.mul(usize, database.pager.cache.pageCount(), per_page) catch std.math.maxInt(usize);
            break :value @intCast(bytes);
        },
        7 => database.pager.stats.cache_hits,
        8 => database.pager.stats.cache_misses,
        9 => database.pager.stats.database_writes,
        12 => database.pager.stats.cache_spills,
        else => unreachable,
    };
    const bounded: i64 = @intCast(@min(value, @as(u64, std.math.maxInt(i64))));
    current.* = std.math.add(i64, current.*, bounded) catch std.math.maxInt(i64);
    if (reset) {
        switch (operation) {
            7 => database.pager.stats.cache_hits = 0,
            8 => database.pager.stats.cache_misses = 0,
            9 => database.pager.stats.database_writes = 0,
            12 => database.pager.stats.cache_spills = 0,
            1, 11 => {},
            else => unreachable,
        }
    }
}

fn addAllDatabaseStatus(connection: *Connection, operation: c_int, reset: bool, current: *i64) void {
    if (connection.database) |database| {
        addDatabaseStatus(current, database, operation, reset);
    }
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |entry| {
            const native = entry.native_context orelse continue;
            const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
            if (attached.database) |*database| {
                addDatabaseStatus(current, database, operation, reset);
            }
        }
    }
}

/// Source `sqlite3_db_status64()`: report connection-local lookaside, pager
/// cache, schema, statement, cache-hit/miss, spill, and deferred-FK status,
/// resetting cumulative pager values only when requested.
fn databaseStatus64(connection: *Connection, operation: c_int, current: *i64, highwater: *i64, reset: bool) c_int {
    current.* = 0;
    highwater.* = 0;
    switch (operation) {
        0 => current.* = lookasideUsed(connection, highwater, reset),
        1, 11 => addAllDatabaseStatus(connection, operation, false, current),
        2 => current.* = schemaMemoryUsed(connection),
        3 => current.* = statementMemoryUsed(connection),
        4, 5, 6 => {}, // Lookaside hit/miss counters remain zero without lookaside.
        7, 8, 9, 12 => addAllDatabaseStatus(connection, operation, reset, current),
        13 => {}, // Temporary buffers are not separately metered.
        10 => {}, // Foreign-key enforcement has no unresolved deferred set.
        else => return ResultCode.error_.toC(),
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_db_status64(pointer: ?*sqlite3, operation: c_int, current: ?*i64, highwater: ?*i64, reset: c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    const now = current orelse return ResultCode.misuse.toC();
    const maximum = highwater orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return databaseStatus64(connection, operation, now, maximum, reset != 0);
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
/// Source `sqlite3_file_control()`: expose core pager/VFS pointers and state,
/// handle reserve/cache controls locally, and dispatch all other operations to
/// the selected database file's xFileControl method.
fn fileControl(connection: *Connection, database_name: ?[*:0]const u8, operation: c_int, argument: ?*anyopaque) c_int {
    const requested_database = if (database_name) |name| std.mem.span(name) else "main";
    const main_database = schemaNameMatches(connection, database_name);
    const located = locateDatabase(connection, if (main_database) null else requested_database);
    if (located.result != .ok) return (if (located.result == .not_found) ResultCode.error_ else located.result).toC();
    const database = located.database.?;
    const raw = argument orelse return ResultCode.misuse.toC();
    switch (operation) {
        7 => {
            const output: *?*btree.vfs.sqlite3_file = @ptrCast(@alignCast(raw));
            output.* = database.pager.file;
            return ResultCode.ok.toC();
        },
        27 => {
            const output: *?*btree.vfs.sqlite3_vfs = @ptrCast(@alignCast(raw));
            output.* = database.pager.abi_vfs;
            return ResultCode.ok.toC();
        },
        28 => {
            const output: *?*btree.vfs.sqlite3_file = @ptrCast(@alignCast(raw));
            output.* = database.pager.journalFile();
            return ResultCode.ok.toC();
        },
        35 => {
            const output: *c_uint = @ptrCast(@alignCast(raw));
            output.* = @truncate(database.pager.stats.database_reads + database.pager.stats.database_writes);
            return ResultCode.ok.toC();
        },
        36 => {
            const limit: *i64 = @ptrCast(@alignCast(raw));
            const store = (if (main_database)
                memdb.fromSchema(if (connection.memory_backend) |*memory| memory else null, connection.shared_memdb, "main")
            else attached: {
                const owner = attachedDatabaseByName(connection, database_name) orelse return ResultCode.error_.toC();
                break :attached memdb.fromSchema(&owner.memory_backend, null, "main");
            }) orelse return ResultCode.not_found.toC();
            limit.* = memdb.fileControl(store.backend, if (store.allow_no_copy) "main" else "/main", limit.*);
            return ResultCode.ok.toC();
        },
        38 => {
            const reserve: *c_int = @ptrCast(@alignCast(raw));
            const requested = reserve.*;
            reserve.* = @intCast(database.pager.reserved_bytes);
            if (requested >= 0 and requested <= 255) {
                database.pager.reserved_bytes = @intCast(requested);
            }
            return ResultCode.ok.toC();
        },
        42 => {
            if (database.pager.cache.refCount() != 0) return ResultCode.busy.toC();
            database.pager.cache.clear();
            return ResultCode.ok.toC();
        },
        else => {
            return btree.vfs.osFileControl(database.pager.file, operation, argument);
        },
    }
}

pub export fn sqlite3_file_control(pointer: ?*sqlite3, database_name: ?[*:0]const u8, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return fileControl(connection, database_name, operation, argument);
}
/// Source `sqlite3_db_release_memory()`: discard every unreferenced clean page
/// owned by the connection pager without changing transaction state.
fn releaseDatabaseMemory(connection: *Connection) c_int {
    if (connection.database) |database| {
        _ = database.pager.cache.shrink();
    }
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |entry| {
            const native = entry.native_context orelse continue;
            const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
            if (attached.database) |*database| {
                _ = database.pager.cache.shrink();
            }
        }
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_db_release_memory(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return releaseDatabaseMemory(connection);
}

/// Source `sqlite3_db_cacheflush()`: flush every unreferenced dirty page in
/// the connection pager while preserving BUSY if WAL or page references block
/// a safe spill.
fn flushDatabaseCache(connection: *Connection) c_int {
    var result = if (connection.database) |database| database.pager.flushUnreferencedDirty() else ResultCode.ok;
    var saw_busy = result == .busy;
    if (saw_busy) result = .ok;
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |entry| {
            if (result != .ok) break;
            const native = entry.native_context orelse continue;
            const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
            const database = if (attached.database) |*database| database else continue;
            const attached_result = database.pager.flushUnreferencedDirty();
            if (attached_result == .busy) {
                saw_busy = true;
            } else if (attached_result != .ok) {
                result = attached_result;
            }
        }
    }
    return (if (result == .ok and saw_busy) ResultCode.busy else result).toC();
}

pub export fn sqlite3_db_cacheflush(pointer: ?*sqlite3) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return flushDatabaseCache(connection);
}
pub export fn sqlite3_system_errno(pointer: ?*sqlite3) callconv(.c) c_int {
    return if (asConnection(pointer)) |connection| connection.system_errno else 0;
}

fn serializeMemoryStore(connection: *Connection, store: memdb.SchemaStore, size_output: ?*i64, flags: c_uint) ?[*]u8 {
    const store_name = if (store.allow_no_copy) "main" else "/main";
    const image = store.backend.borrowVolatile(store_name) orelse return null;
    if (size_output) |output| output.* = @intCast(image.len);
    const serialization_optional = memdb.serialize(connection.allocator, store, store_name, flags & 1 != 0) catch return null;
    const serialization = serialization_optional orelse return null;
    switch (serialization) {
        .borrowed => |bytes| {
            if (size_output) |output| output.* = @intCast(bytes.len);
            return bytes.ptr;
        },
        .owned => |bytes| {
            defer connection.allocator.free(bytes);
            const output = public_api.sqlite3_malloc64(bytes.len) orelse return null;
            @memcpy(@as([*]u8, @ptrCast(output))[0..bytes.len], bytes);
            if (size_output) |output_size| output_size.* = @intCast(bytes.len);
            return @ptrCast(output);
        },
    }
}

pub export fn sqlite3_serialize(pointer: ?*sqlite3, schema: ?[*:0]const u8, size_output: ?*i64, flags: c_uint) callconv(.c) ?[*]u8 {
    const connection = safetyCheckOk(pointer) orelse return null;
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    if (size_output) |output| output.* = -1;
    if (!schemaNameMatches(connection, schema)) {
        const attached = attachedDatabaseByName(connection, schema) orelse return null;
        const store = memdb.fromSchema(&attached.memory_backend, null, "main") orelse return null;
        return serializeMemoryStore(connection, store, size_output, flags);
    }
    if (memdb.fromSchema(if (connection.memory_backend) |*memory| memory else null, connection.shared_memdb, "main")) |store| {
        return serializeMemoryStore(connection, store, size_output, flags);
    }
    if (connection.unix_backend != null) {
        const database = connection.database orelse return null;
        const page_count: usize = database.pager.pageCount();
        const page_size: usize = database.pager.pageSize();
        const length = std.math.mul(usize, page_count, page_size) catch return null;
        if (length > @as(usize, std.math.maxInt(i64))) return null;
        if (size_output) |output| output.* = @intCast(length);
        if (flags & 1 != 0) return null;
        const output = public_api.sqlite3_malloc64(length) orelse return null;
        const bytes = @as([*]u8, @ptrCast(output))[0..length];
        for (1..page_count + 1) |page_number| {
            const start = (page_number - 1) * page_size;
            const target = bytes[start..][0..page_size];
            const fetched = database.pager.getPage(@intCast(page_number), false);
            if (fetched.result == .ok) {
                const page = fetched.page.?;
                @memcpy(target, page.data);
                _ = database.pager.release(page);
            } else {
                @memset(target, 0);
            }
        }
        return @ptrCast(output);
    }
    return null;
}

fn openPendingDeserializedDatabase(connection: *Connection) ResultCode {
    if (connection.database != null) return .ok;
    _ = connection.pending_deserialize_readonly orelse return .misuse;
    const adapter = if (connection.memory_adapter) |*memory_adapter| memory_adapter else return .misuse;
    const opened = btree.Database.openWritable(connection.allocator, &adapter.abi, "main");
    if (opened.result != .ok) return opened.result;
    const database = connection.allocator.create(btree.Database) catch {
        var temporary = opened.database.?;
        _ = temporary.close();
        return .no_memory;
    };
    database.* = opened.database.?;
    connection.database = database;
    connection.pending_deserialize_readonly = null;
    return .ok;
}

fn openPendingAttachedDatabase(attached: *AttachedDatabase) ResultCode {
    if (attached.database != null) return .ok;
    _ = attached.pending_deserialize_readonly orelse return .misuse;
    const opened = btree.Database.openWritable(attached.allocator, &attached.memory_adapter.abi, "main");
    if (opened.result != .ok) return opened.result;
    attached.database = opened.database.?;
    attached.pending_deserialize_readonly = null;
    return .ok;
}

pub export fn sqlite3_deserialize(pointer: ?*sqlite3, schema: ?[*:0]const u8, data: ?[*]u8, size: i64, buffer_size: i64, flags: c_uint) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    if (size < 0 or buffer_size < 0 or size > buffer_size or data == null) return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    var transferred = false;
    defer if (!transferred and flags & btree.vfs.DESERIALIZE_FREEONCLOSE != 0) public_api.sqlite3_free(data);
    if (connection.active_statements != 0) return ResultCode.misuse.toC();
    const attached: ?*AttachedDatabase = if (schemaNameMatches(connection, schema)) null else attachedDatabaseByName(connection, schema) orelse return ResultCode.error_.toC();
    if (attached) |target| {
        if (target.active_blobs != 0 or target.active_backups != 0) return ResultCode.busy.toC();
        if (target.pending_deserialize_readonly != null) {
            const pending_result = openPendingAttachedDatabase(target);
            if (pending_result != .ok) return pending_result.toC();
        }
    } else if (connection.active_blobs != 0 or connection.active_source_backups != 0) {
        return ResultCode.busy.toC();
    } else if (connection.pending_deserialize_readonly != null) {
        const pending_result = openPendingDeserializedDatabase(connection);
        if (pending_result != .ok) return pending_result.toC();
    }

    var replacement_name: ?[:0]u8 = null;
    if (attached == null and (connection.filename == null or !std.mem.eql(u8, connection.filename.?, ":memory:"))) {
        replacement_name = connection.allocator.dupeZ(u8, ":memory:") catch return ResultCode.no_memory.toC();
    }
    defer if (replacement_name) |name| connection.allocator.free(name);
    var replacement = memdb.deserialize(
        connection.allocator,
        data.?,
        @intCast(size),
        @intCast(buffer_size),
        flags,
        global.process_mem_vfs.memdb_max_size,
    ) catch |err| return switch (err) {
        error.InvalidSize => ResultCode.misuse.toC(),
        error.OutOfMemory => ResultCode.no_memory.toC(),
        error.OpenFailed => ResultCode.cannot_open.toC(),
    };
    transferred = true;
    if (flags & btree.vfs.DESERIALIZE_READONLY == 0) {
        const truncate_result = memdb.truncate(&replacement, "main", @intCast(size));
        if (truncate_result != btree.vfs.OK) {
            replacement.deinit();
            return truncate_result;
        }
    }
    if (attached) |target| {
        if (target.database) |*database| {
            const rc = database.close();
            if (rc != .ok) {
                replacement.deinit();
                return rc.toC();
            }
            target.database = null;
        }
        target.memory_backend.deinit();
        target.memory_backend = replacement;
        target.memory_adapter = btree.vfs.AbiAdapter.init("zig-attached-deserialize", &target.memory_backend);
        target.pending_deserialize_readonly = flags & btree.vfs.DESERIALIZE_READONLY != 0;
        return ResultCode.ok.toC();
    }
    if (connection.database) |database| {
        const rc = database.close();
        if (rc != .ok) {
            replacement.deinit();
            return rc.toC();
        }
        connection.allocator.destroy(database);
        connection.database = null;
    }
    if (connection.memory_backend) |*memory| memory.deinit();
    if (connection.shared_memdb) |shared| {
        memdb.close(shared);
        connection.shared_memdb = null;
    }
    connection.memory_backend = replacement;
    connection.memory_adapter = btree.vfs.AbiAdapter.init("zig-deserialize", &connection.memory_backend.?);
    connection.pending_deserialize_readonly = flags & btree.vfs.DESERIALIZE_READONLY != 0;
    if (replacement_name) |name| {
        if (connection.filename) |old| connection.allocator.free(old);
        connection.filename = name;
        replacement_name = null;
    }
    return ResultCode.ok.toC();
}

const Blob = struct {
    connection: *Connection,
    database: *btree.Database,
    attached: ?*AttachedDatabase,
    root_page: u32,
    column: usize,
    rowid: i64,
    writable: bool,
    cursor: ?btree.Cursor = null,
    byte_count: usize = 0,
    invalidated: bool = false,

    fn invalidate(self: *Blob) void {
        if (self.cursor) |*cursor| cursor.deinit();
        self.cursor = null;
        self.byte_count = 0;
        self.invalidated = true;
    }
};

/// Source `blobSeekToRow()`: keep the incremental-blob cursor positioned on
/// its row, cache the fixed byte length, and permanently invalidate the handle
/// after a missing row, non-blob value, or cursor error.
fn blobSeekToRow(blob: *Blob, rowid: i64) ResultCode {
    if (blob.invalidated) return .abort;
    if (blob.cursor == null) {
        const opened = blob.database.openCursor(blob.root_page, .table);
        if (opened.result != .ok) {
            blob.invalidate();
            return opened.result;
        }
        blob.cursor = opened.cursor.?;
    }
    const cursor = &blob.cursor.?;
    if (!cursor.seekTable(rowid)) {
        blob.invalidate();
        return .error_;
    }
    const decoded = cursor.record();
    if (decoded.result != .ok) {
        blob.invalidate();
        return decoded.result;
    }
    var record = decoded.record.?;
    defer record.deinit();
    if (blob.column >= record.values.len) {
        blob.invalidate();
        return .error_;
    }
    blob.byte_count = switch (record.values[blob.column]) {
        .blob => |value| value.len,
        .text => |value| value.len,
        else => {
            blob.invalidate();
            return .error_;
        },
    };
    blob.rowid = rowid;
    return .ok;
}

const IndexedColumnOutcome = struct {
    result: ResultCode,
    found: bool = false,
};

fn secondaryIndexContainsColumn(connection: *Connection, database: *btree.Database, table_name: []const u8, column_name: []const u8) IndexedColumnOutcome {
    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return .{ .result = opened.result };
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    for (cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return .{ .result = decoded.result };
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len < 5) continue;
        const object_type = schemaEntryText(record.values[0]) orelse continue;
        const indexed_table = schemaEntryText(record.values[2]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index") or !std.ascii.eqlIgnoreCase(indexed_table, table_name)) continue;
        const sql = schemaEntryText(record.values[4]) orelse return .{ .result = .error_ };
        const resolved = resolveColumns(connection.allocator, sql) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_ };
        defer {
            connection.allocator.free(resolved.columns);
            connection.allocator.free(resolved.tokens);
            connection.allocator.free(resolved.source);
        }
        for (resolved.columns) |index_column| {
            if (std.ascii.eqlIgnoreCase(index_column.name, column_name)) return .{ .result = .ok, .found = true };
        }
    }
    return .{ .result = .ok };
}

pub export fn sqlite3_blob_open(database_pointer: ?*sqlite3, database_name: ?[*:0]const u8, table_name: ?[*:0]const u8, column_name: ?[*:0]const u8, rowid: i64, flags: c_int, output: ?*?*sqlite3_blob) callconv(.c) c_int {
    const connection = asConnection(database_pointer) orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const out = output orelse return ResultCode.misuse.toC();
    out.* = null;
    const requested_database = if (database_name) |name| std.mem.span(name) else "main";
    const located_database = locateDatabase(connection, if (schemaNameMatches(connection, database_name)) null else requested_database);
    if (located_database.result != .ok) return (if (located_database.result == .not_found) ResultCode.error_ else located_database.result).toC();
    const database = located_database.database.?;
    const attached = if (schemaNameMatches(connection, database_name)) null else attachedDatabaseByName(connection, database_name) orelse return ResultCode.error_.toC();
    const table = if (table_name) |name| std.mem.span(name) else return ResultCode.misuse.toC();
    const column = if (column_name) |name| std.mem.span(name) else return ResultCode.misuse.toC();
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
    var declared_column: ?usize = null;
    for (resolved.columns, 0..) |item, index| {
        if (std.ascii.eqlIgnoreCase(item.name, column) and !item.integer_primary_key) {
            record_column = item.record_index;
            declared_column = index;
            break;
        }
    }
    if (flags != 0 and declared_column != null) {
        const indexed = secondaryIndexContainsColumn(connection, database, table, column);
        if (indexed.result != .ok) return indexed.result.toC();
        if (indexed.found) return ResultCode.error_.toC();
        const foreign_keys = resolveForeignKeys(connection.allocator, schema.sql, resolved.columns) catch |err| return (if (err == error.OutOfMemory) ResultCode.no_memory else ResultCode.error_).toC();
        var keys = foreign_keys;
        defer keys.deinit();
        for (keys.mappings) |mapping| {
            if (mapping.child_column == declared_column.?) return ResultCode.error_.toC();
        }
    }
    const blob = connection.allocator.create(Blob) catch return ResultCode.no_memory.toC();
    blob.* = .{ .connection = connection, .database = database, .attached = attached, .root_page = schema.root_page, .column = record_column orelse {
        connection.allocator.destroy(blob);
        return ResultCode.error_.toC();
    }, .rowid = rowid, .writable = flags != 0 };
    const rc = blobSeekToRow(blob, rowid);
    if (rc != .ok) {
        connection.allocator.destroy(blob);
        return rc.toC();
    }
    connection.active_blobs += 1;
    if (attached) |owner| owner.active_blobs += 1;
    out.* = @ptrCast(blob);
    return ResultCode.ok.toC();
}

pub export fn sqlite3_blob_reopen(pointer: ?*sqlite3_blob, rowid: i64) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    blob.connection.connection_mutex.enter();
    defer blob.connection.connection_mutex.leave();
    return blobSeekToRow(blob, rowid).toC();
}

pub export fn sqlite3_blob_close(pointer: ?*sqlite3_blob) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.ok.toC();
    const connection = blob.connection;
    if (blob.cursor) |*cursor| cursor.deinit();
    if (blob.attached) |owner| {
        std.debug.assert(owner.active_blobs > 0);
        owner.active_blobs -= 1;
    }
    connection.allocator.destroy(blob);
    std.debug.assert(connection.active_blobs > 0);
    connection.active_blobs -= 1;
    if (!connectionIsBusy(connection) and connection.deferred_close) {
        _ = connection.finishClose();
    }
    return ResultCode.ok.toC();
}

pub export fn sqlite3_blob_bytes(pointer: ?*sqlite3_blob) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return 0;
    if (blob.invalidated) return 0;
    return @intCast(@min(blob.byte_count, @as(usize, std.math.maxInt(c_int))));
}

/// Source `blobReadWrite()`: validate the fixed blob range, reject invalidated
/// handles, operate through the positioned cursor, and invalidate an aborted
/// write while preserving the handle for transient range errors.
fn blobReadWrite(blob: *Blob, buffer: ?*anyopaque, amount: c_int, offset: c_int, writing: bool) ResultCode {
    if (amount < 0 or offset < 0 or (amount != 0 and buffer == null)) return .misuse;
    if (writing and !blob.writable) return .read_only;
    blob.connection.connection_mutex.enter();
    defer blob.connection.connection_mutex.leave();
    if (blob.invalidated or blob.cursor == null) return .abort;
    const start: usize = @intCast(offset);
    const count: usize = @intCast(amount);
    if (start > blob.byte_count or count > blob.byte_count - start) return .error_;

    const cursor = &blob.cursor.?;
    const decoded = cursor.record();
    if (decoded.result != .ok) {
        if (decoded.result == .abort) blob.invalidate();
        return decoded.result;
    }
    var record = decoded.record.?;
    defer record.deinit();
    if (blob.column >= record.values.len) {
        blob.invalidate();
        return .abort;
    }
    const original_is_text = record.values[blob.column] == .text;
    const original = switch (record.values[blob.column]) {
        .blob => |value| value,
        .text => |value| value,
        else => {
            blob.invalidate();
            return .abort;
        },
    };
    if (original.len != blob.byte_count) {
        blob.invalidate();
        return .abort;
    }
    if (!writing) {
        if (count != 0) @memcpy(@as([*]u8, @ptrCast(buffer.?))[0..count], original[start..][0..count]);
        return .ok;
    }

    const replacement = blob.connection.allocator.dupe(u8, original) catch return .no_memory;
    defer blob.connection.allocator.free(replacement);
    if (count != 0) @memcpy(replacement[start..][0..count], @as([*]const u8, @ptrCast(buffer.?))[0..count]);
    const values = blob.connection.allocator.dupe(btree.Value, record.values) catch return .no_memory;
    defer blob.connection.allocator.free(values);
    values[blob.column] = if (original_is_text) .{ .text = replacement } else .{ .blob = replacement };
    const payload = btree.encodeRecord(blob.connection.allocator, values) catch return .no_memory;
    defer blob.connection.allocator.free(payload);
    const result = blob.database.insertTable(blob.root_page, blob.rowid, payload, true);
    if (result != .ok) {
        if (result == .abort) blob.invalidate();
        return result;
    }
    blob.cursor.?.deinit();
    blob.cursor = null;
    return blobSeekToRow(blob, blob.rowid);
}

pub export fn sqlite3_blob_read(pointer: ?*sqlite3_blob, output: ?*anyopaque, amount: c_int, offset: c_int) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    return blobReadWrite(blob, output, amount, offset, false).toC();
}

pub export fn sqlite3_blob_write(pointer: ?*sqlite3_blob, input: ?*const anyopaque, amount: c_int, offset: c_int) callconv(.c) c_int {
    const blob: *Blob = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    return blobReadWrite(blob, @constCast(input), amount, offset, true).toC();
}

const Backup = struct {
    destination: *Connection,
    source: *Connection,
    source_database: *btree.Database,
    destination_name: [:0]u8,
    source_name: [:0]u8,
    source_attached: ?*AttachedDatabase,
    source_page_size: u32,
    source_writes: u64 = 0,
    image: ?[*]u8 = null,
    image_size: i64 = 0,
    image_capacity: i64 = 0,
    remaining: c_int = 0,
    pages: c_int = 0,
    result: ResultCode = .ok,
};
pub export fn sqlite3_backup_init(destination_pointer: ?*sqlite3, destination_name: ?[*:0]const u8, source_pointer: ?*sqlite3, source_name: ?[*:0]const u8) callconv(.c) ?*sqlite3_backup {
    const destination = asConnection(destination_pointer) orelse return null;
    const source = asConnection(source_pointer) orelse return null;
    if (destination == source) {
        destination.last_result = .error_;
        return null;
    }
    const destination_schema = if (destination_name) |name| std.mem.span(name) else "main";
    const source_schema = if (source_name) |name| std.mem.span(name) else "main";
    const located_destination = locateDatabase(destination, if (schemaNameMatches(destination, destination_name)) null else destination_schema);
    const located_source = locateDatabase(source, if (schemaNameMatches(source, source_name)) null else source_schema);
    if (located_destination.result != .ok or located_source.result != .ok) {
        destination.last_result = .error_;
        return null;
    }
    const destination_copy = destination.allocator.dupeZ(u8, destination_schema) catch {
        destination.last_result = .no_memory;
        return null;
    };
    const source_copy = destination.allocator.dupeZ(u8, source_schema) catch {
        destination.allocator.free(destination_copy);
        destination.last_result = .no_memory;
        return null;
    };
    const backup = destination.allocator.create(Backup) catch {
        destination.allocator.free(destination_copy);
        destination.allocator.free(source_copy);
        destination.last_result = .no_memory;
        return null;
    };
    const source_attached = if (schemaNameMatches(source, source_name)) null else attachedDatabaseByName(source, source_name) orelse {
        destination.allocator.destroy(backup);
        destination.allocator.free(destination_copy);
        destination.allocator.free(source_copy);
        destination.last_result = .error_;
        return null;
    };
    backup.* = .{ .destination = destination, .source = source, .source_database = located_source.database.?, .destination_name = destination_copy, .source_name = source_copy, .source_attached = source_attached, .source_page_size = located_source.database.?.pager.page_size };
    destination.active_backups += 1;
    source.active_backups += 1;
    source.active_source_backups += 1;
    if (source_attached) |owner| owner.active_backups += 1;
    return @ptrCast(backup);
}
pub export fn sqlite3_backup_step(pointer: ?*sqlite3_backup, pages: c_int) callconv(.c) c_int {
    const backup: *Backup = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.misuse.toC();
    if (backup.result != .ok) return backup.result.toC();
    if (backup.image != null and backup.source_database.pager.stats.database_writes != backup.source_writes) {
        public_api.sqlite3_free(backup.image.?);
        backup.image = null;
        backup.remaining = 0;
        backup.pages = 0;
    }
    if (backup.image == null) {
        var size: i64 = 0;
        const bytes = sqlite3_serialize(toOpaque(backup.source), backup.source_name.ptr, &size, 0) orelse {
            backup.result = .error_;
            return backup.result.toC();
        };
        backup.image = bytes;
        backup.source_writes = backup.source_database.pager.stats.database_writes;
        backup.image_size = size;
        backup.image_capacity = @intCast(public_api.sqlite3_msize(bytes));
        const page_size: i64 = @intCast(backup.source_page_size);
        const rounded_size = std.math.add(i64, size, page_size - 1) catch {
            backup.result = .too_big;
            return backup.result.toC();
        };
        backup.pages = std.math.cast(c_int, @max(@divTrunc(rounded_size, page_size), 1)) orelse {
            backup.result = .too_big;
            return backup.result.toC();
        };
        backup.remaining = backup.pages;
    }
    if (pages >= 0 and pages < backup.remaining) {
        backup.remaining -= pages;
        return ResultCode.ok.toC();
    }
    const bytes = backup.image.?;
    backup.image = null;
    const rc = ResultCode.fromC(sqlite3_deserialize(toOpaque(backup.destination), backup.destination_name.ptr, bytes, backup.image_size, backup.image_capacity, btree.vfs.DESERIALIZE_FREEONCLOSE));
    backup.result = rc;
    if (rc == .ok) {
        backup.result = .done;
        backup.remaining = 0;
        return ResultCode.done.toC();
    }
    return rc.toC();
}
pub export fn sqlite3_backup_finish(pointer: ?*sqlite3_backup) callconv(.c) c_int {
    const backup: *Backup = if (pointer) |value| @ptrCast(@alignCast(value)) else return ResultCode.ok.toC();
    const rc = if (backup.result == .done) ResultCode.ok else backup.result;
    const destination = backup.destination;
    const source = backup.source;
    if (backup.image) |image| {
        public_api.sqlite3_free(image);
    }
    if (backup.source_attached) |owner| {
        std.debug.assert(owner.active_backups > 0);
        owner.active_backups -= 1;
    }
    destination.allocator.free(backup.destination_name);
    destination.allocator.free(backup.source_name);
    destination.allocator.destroy(backup);
    std.debug.assert(destination.active_backups > 0 and source.active_backups > 0 and source.active_source_backups > 0);
    destination.active_backups -= 1;
    source.active_backups -= 1;
    source.active_source_backups -= 1;
    const close_destination = !connectionIsBusy(destination) and destination.deferred_close;
    const close_source = !connectionIsBusy(source) and source.deferred_close;
    if (close_destination) {
        _ = destination.finishClose();
    }
    if (close_source) {
        _ = source.finishClose();
    }
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

/// Source `doWalCallbacks()`: obtain the committed WAL frame count and return
/// the first hook failure instead of discarding it after a successful commit.
fn doWalCallbacks(connection: *Connection) ResultCode {
    const database = connection.database orelse return .ok;
    if (!database.pager.isWalMode()) return .ok;
    const frame_count: c_int = if (database.pager.wal_state) |*state| @intCast(state.frame_count) else 0;
    if (frame_count <= 0) return .ok;
    const callback = connection.wal_callback orelse return .ok;
    return ResultCode.fromC(callback(connection.wal_context, toOpaque(connection), "main", frame_count));
}

/// Source `sqlite3WalDefaultHook()`: checkpoint only after the committed WAL
/// frame count reaches the configured threshold.
fn walDefaultHook(context: ?*anyopaque, database: ?*sqlite3, schema: [*:0]const u8, frames: c_int) callconv(.c) c_int {
    const threshold: c_int = if (context) |pointer| @intCast(@intFromPtr(pointer)) else 0;
    if (threshold > 0 and frames >= threshold) return sqlite3_wal_checkpoint(database, schema);
    return ResultCode.ok.toC();
}

/// Source `sqlite3_wal_hook()`: replace the WAL callback atomically, return
/// its former context, and disable the default autocheckpoint hook.
fn configureWalHook(connection: *Connection, callback: ?*const fn (?*anyopaque, ?*sqlite3, [*:0]const u8, c_int) callconv(.c) c_int, context: ?*anyopaque) ?*anyopaque {
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    const previous = connection.wal_context;
    connection.wal_callback = callback;
    connection.wal_context = context;
    connection.wal_autocheckpoint_pages = 0;
    return previous;
}

pub export fn sqlite3_wal_hook(pointer: ?*sqlite3, callback: ?*const fn (?*anyopaque, ?*sqlite3, [*:0]const u8, c_int) callconv(.c) c_int, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const connection = safetyCheckOk(pointer) orelse return null;
    return configureWalHook(connection, callback, context);
}
/// Source `sqlite3_wal_autocheckpoint()`: replace any application WAL hook
/// with the default threshold callback, or disable WAL callbacks entirely.
fn configureWalAutocheckpoint(connection: *Connection, pages: c_int) c_int {
    const threshold = @max(pages, 0);
    _ = configureWalHook(connection, if (threshold > 0) &walDefaultHook else null, if (threshold > 0) @ptrFromInt(@as(usize, @intCast(threshold))) else null);
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    connection.wal_autocheckpoint_pages = threshold;
    return ResultCode.ok.toC();
}

pub export fn sqlite3_wal_autocheckpoint(pointer: ?*sqlite3, pages: c_int) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return ResultCode.misuse.toC();
    return configureWalAutocheckpoint(connection, pages);
}

/// Source `sqlite3Checkpoint()`: dispatch one validated checkpoint mode to
/// the selected pager and preserve separate log and backfill counts.
fn checkpoint(database: *btree.Database, mode: wal.CheckpointMode, log_frames: ?*c_int, checkpointed_frames: ?*c_int) c_int {
    if (!database.pager.isWalMode()) return ResultCode.ok.toC();
    const result = database.pager.checkpointWalMode(mode);
    if (log_frames) |value| {
        value.* = @intCast(result.frames);
    }
    if (checkpointed_frames) |value| {
        value.* = @intCast(result.checkpointed);
    }
    return result.result.toC();
}

/// Source `sqlite3_wal_checkpoint_v2()`: validate the checkpoint mode and
/// schema, initialize outputs, and clear an idle connection's interrupt.
fn checkpointConnection(connection: *Connection, schema: ?[*:0]const u8, mode: c_int, log_frames: ?*c_int, checkpointed_frames: ?*c_int) c_int {
    if (log_frames) |value| {
        value.* = -1;
    }
    if (checkpointed_frames) |value| {
        value.* = -1;
    }
    if (mode < -1 or mode > 3) return ResultCode.misuse.toC();
    const checkpoint_mode: wal.CheckpointMode = @enumFromInt(mode);
    var result = ResultCode.ok.toC();
    const schema_name = if (schema) |name| std.mem.span(name) else "";
    if (schema_name.len != 0) {
        const located = locateDatabase(connection, if (schemaNameMatches(connection, schema)) null else schema_name);
        if (located.result != .ok) return (if (located.result == .not_found) ResultCode.error_ else located.result).toC();
        result = checkpoint(located.database.?, checkpoint_mode, log_frames, checkpointed_frames);
    } else {
        const main_database = connection.database orelse return ResultCode.misuse.toC();
        result = checkpoint(main_database, checkpoint_mode, log_frames, checkpointed_frames);
        if (result == ResultCode.ok.toC()) {
            if (connection.attachments) |*attachments| {
                for (attachments.databases.items[2..]) |entry| {
                    const native = entry.native_context orelse continue;
                    const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
                    const database = if (attached.database) |*database| database else continue;
                    const attached_result = checkpoint(database, checkpoint_mode, null, null);
                    if (attached_result != ResultCode.ok.toC()) {
                        result = attached_result;
                        break;
                    }
                }
            }
        }
    }
    if (connection.active_statements == 0) {
        connection.interrupted = false;
    }
    return result;
}

pub export fn sqlite3_wal_checkpoint_v2(pointer: ?*sqlite3, schema: ?[*:0]const u8, mode: c_int, log_frames: ?*c_int, checkpointed_frames: ?*c_int) callconv(.c) c_int {
    const connection = asConnection(pointer) orelse return ResultCode.misuse.toC();
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return checkpointConnection(connection, schema, mode, log_frames, checkpointed_frames);
}
pub export fn sqlite3_wal_checkpoint(pointer: ?*sqlite3, schema: ?[*:0]const u8) callconv(.c) c_int {
    return sqlite3_wal_checkpoint_v2(pointer, schema, 0, null, null);
}

/// Source `sqlite3_txn_state()`: report NONE, READ, or WRITE from the native
/// pager state for the selected schema.
fn databaseTransactionState(database: *const btree.Database) c_int {
    return switch (database.pager.state) {
        .open, .reader => 0,
        .writer_locked, .writer_cache_modified, .writer_database_modified, .writer_finished => 2,
        .error_, .closed => 0,
    };
}

fn transactionState(connection: *Connection, schema: ?[*:0]const u8) c_int {
    if (schema) |name| {
        if (schemaNameMatches(connection, schema)) return if (connection.database) |database| databaseTransactionState(database) else 0;
        const attached = attachedDatabaseByName(connection, name) orelse return -1;
        return if (attached.database) |*database| databaseTransactionState(database) else 0;
    }
    var result = if (connection.database) |database| databaseTransactionState(database) else 0;
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |entry| {
            const native = entry.native_context orelse continue;
            const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
            const state = if (attached.database) |*database| databaseTransactionState(database) else 0;
            result = @max(result, state);
        }
    }
    return result;
}

pub export fn sqlite3_txn_state(pointer: ?*sqlite3, schema: ?[*:0]const u8) callconv(.c) c_int {
    const connection = safetyCheckOk(pointer) orelse return -1;
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    return transactionState(connection, schema);
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

fn jsonVirtualOpen(context: ?*anyopaque, output: *?*anyopaque) ResultCode {
    const plan: *JsonVirtualPlan = @ptrCast(@alignCast(context orelse return .misuse));
    const cursor = json_vtable.open(plan.allocator, plan.connection) catch return .no_memory;
    const handle = plan.allocator.create(JsonVirtualHandle) catch {
        json_vtable.close(cursor);
        return .no_memory;
    };
    handle.* = .{ .plan = plan, .cursor = cursor };
    output.* = handle;
    return .ok;
}
fn jsonVirtualClose(pointer: ?*anyopaque) void {
    const handle: *JsonVirtualHandle = @ptrCast(@alignCast(pointer orelse return));
    json_vtable.close(handle.cursor);
    handle.plan.allocator.destroy(handle);
}
fn jsonVirtualFilter(pointer: ?*anyopaque) ResultCode {
    const handle: *JsonVirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    json_vtable.filter(handle.cursor, handle.plan.input, handle.plan.input_is_blob, handle.plan.root) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    return .ok;
}
fn jsonVirtualNext(pointer: ?*anyopaque) ResultCode {
    const handle: *JsonVirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    json_vtable.next(handle.cursor) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    return .ok;
}
fn jsonVirtualEof(pointer: ?*anyopaque) bool {
    const handle: *JsonVirtualHandle = @ptrCast(@alignCast(pointer orelse return true));
    return json_vtable.eof(handle.cursor);
}
fn jsonVirtualColumn(pointer: ?*anyopaque, index: usize, output: *vdbe.Mem) ResultCode {
    const handle: *JsonVirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    const callback: *const fn (?*anyopaque, ?*statement.sqlite3_context, c_int) callconv(.c) c_int = @ptrCast(&json_vtable.columnCallback);
    return statement.invokeVirtualColumn(callback, handle.cursor, index, output);
}
fn jsonVirtualRowid(pointer: ?*anyopaque, output: *i64) ResultCode {
    const handle: *JsonVirtualHandle = @ptrCast(@alignCast(pointer orelse return .misuse));
    output.* = json_vtable.rowid(handle.cursor);
    return .ok;
}
const json_virtual_source_template: vdbe.VirtualSource = .{ .context = null, .open = jsonVirtualOpen, .close = jsonVirtualClose, .filter = jsonVirtualFilter, .next = jsonVirtualNext, .eof = jsonVirtualEof, .column = jsonVirtualColumn, .rowid = jsonVirtualRowid };

const TransactionOperation = enum { begin, commit, rollback };
const ReindexTarget = enum { index, table, collation, expressions, all };

const ProgramAction = union(enum) {
    attach_database: struct { connection: *Connection, filename: []const u8, name: []const u8 },
    detach_database: struct { connection: *Connection, name: []const u8 },
    create: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, name: []const u8, sql: []const u8, if_not_exists: bool },
    create_index: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, name: []const u8, table_name: []const u8, sql: []const u8, table_root: u32, integer_primary_key_position: ?usize, predicate: ?btree.IndexPredicate, unique: bool, if_not_exists: bool },
    virtual_create: struct { connection: *Connection, schema_name: []const u8, name: []const u8, module_name: []const u8 },
    virtual_drop: struct { connection: *Connection, schema_name: []const u8, name: []const u8 },
    drop: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, name: []const u8, if_exists: bool },
    drop_index: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, name: []const u8, if_exists: bool },
    reindex: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, name: []const u8, target: ReindexTarget },
    insert: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, root_page: u32, table_name: []const u8, column_count: usize, integer_primary_key: ?usize, replace: bool, conflict_ignore: bool },
    update: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, root_page: u32, table_name: []const u8, target_column: usize, target_integer_primary_key: bool, foreign_key_old_mask: u32 },
    delete: struct { connection: *Connection, database: *btree.Database, schema_name: []const u8, root_page: u32, table_name: []const u8, foreign_key_old_mask: u32 },
    vacuum: struct { connection: *Connection },
    analyze: struct { connection: *Connection, table_name: ?[]const u8 },
    transaction: struct { connection: *Connection, operation: TransactionOperation },
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
    index_collations: []btree.IndexCollation = &.{},
    index_sort_orders: []btree.IndexSortOrder = &.{},
    index_transforms: []btree.IndexTransform = &.{},
    functions: [1]vdbe.Function = undefined,
    dynamic_functions: []vdbe.Function = &.{},
    dynamic_collations: []vdbe.Collation = &.{},
    virtual_sources: []vdbe.VirtualSource = &.{},
    virtual_plan: ?*VirtualPlan = null,
    json_virtual_plan: ?*JsonVirtualPlan = null,
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
        allocator.free(self.index_collations);
        allocator.free(self.index_sort_orders);
        allocator.free(self.index_transforms);
        allocator.free(self.dynamic_functions);
        allocator.free(self.dynamic_collations);
        allocator.free(self.virtual_sources);
        if (self.virtual_plan) |plan| {
            if (plan.index_string) |value| allocator.free(value);
            allocator.destroy(plan);
        }
        if (self.json_virtual_plan) |plan| {
            allocator.free(plan.input);
            if (plan.root) |root| allocator.free(root);
            allocator.destroy(plan);
        }
        allocator.free(self.source);
        allocator.destroy(self);
    }
};

const VectorRange = struct { first: u16, count: u16 };
const SubqueryCache = struct { start: usize, end: usize, first_register: u16 };

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
    vectors: [32]VectorRange = undefined,
    vector_count: u8 = 0,
    subqueries: [16]SubqueryCache = undefined,
    subquery_count: u8 = 0,
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

    fn patchJump(self: *Parser, address: usize, destination: usize) void {
        std.debug.assert(address < self.instructions.items.len);
        self.instructions.items[address].p2 = @intCast(destination);
    }

    /// Runtime-code counterpart of source `sqlite3ExprIfTrue()` for an
    /// already-evaluated bounded expression register.
    fn expressionIfTrue(self: *Parser, source: u16, destination: i32, jump_if_null: bool) !usize {
        const address = self.instructions.items.len;
        try self.emit(.{ .opcode = .if_, .p1 = source, .p2 = destination, .p3 = @intFromBool(jump_if_null) });
        return address;
    }

    /// Runtime-code counterpart of source `sqlite3ExprIfFalse()` for an
    /// already-evaluated bounded expression register.
    fn expressionIfFalse(self: *Parser, source: u16, destination: i32, jump_if_null: bool) !usize {
        const address = self.instructions.items.len;
        try self.emit(.{ .opcode = .if_not, .p1 = source, .p2 = destination, .p3 = @intFromBool(jump_if_null) });
        return address;
    }

    fn vectorLength(self: *const Parser, first: u16) u16 {
        var index: usize = 0;
        while (index < self.vector_count) : (index += 1) {
            if (self.vectors[index].first == first) return self.vectors[index].count;
        }
        return 1;
    }

    /// Source `exprVectorRegister()`: resolve one field from a contiguous
    /// row-value register range.
    fn expressionVectorRegister(self: *const Parser, first: u16, field: u16) !u16 {
        const count = self.vectorLength(first);
        if (field >= count) return error.Syntax;
        return first + field;
    }

    /// Source `exprCodeVector()`: copy scalar results into a stable contiguous
    /// register range and retain its width for comparison code generation.
    fn expressionCodeVector(self: *Parser, values: []const u16) ParserError!u16 {
        if (values.len == 0) return error.Syntax;
        if (values.len == 1) return values[0];
        if (values.len > 32 or @as(usize, self.vector_count) == self.vectors.len) return error.TooBig;
        const first = self.next_register;
        for (values) |source| {
            const target = try self.allocateRegister();
            try self.emit(.{ .opcode = .copy, .p1 = source, .p2 = target });
        }
        self.vectors[@intCast(self.vector_count)] = .{ .first = first, .count = @intCast(values.len) };
        self.vector_count += 1;
        return first;
    }

    fn codeScalarCompare(self: *Parser, left: u16, right: u16, opcode: vdbe.Opcode) !u16 {
        const target = try self.allocateRegister();
        try self.emit(.{ .opcode = .null_, .p2 = target });
        const compare_address = self.instructions.items.len;
        try self.emit(.{ .opcode = opcode, .p1 = right, .p3 = left });
        const left_null_address = self.instructions.items.len;
        try self.emit(.{ .opcode = .is_null, .p1 = left });
        const right_null_address = self.instructions.items.len;
        try self.emit(.{ .opcode = .is_null, .p1 = right });
        try self.emit(.{ .opcode = .integer, .p1 = 0, .p2 = target });
        const false_done_address = self.instructions.items.len;
        try self.emit(.{ .opcode = .goto });
        const true_address = self.instructions.items.len;
        try self.emit(.{ .opcode = .integer, .p1 = 1, .p2 = target });
        const done = self.instructions.items.len;
        self.patchJump(compare_address, true_address);
        self.patchJump(left_null_address, done);
        self.patchJump(right_null_address, done);
        self.patchJump(false_done_address, done);
        return target;
    }

    /// Source `codeVectorCompare()`: materialize scalar or row-value
    /// comparisons with left-to-right NULL and lexicographic semantics.
    fn codeVectorCompare(self: *Parser, left: u16, right: u16, opcode: vdbe.Opcode) ParserError!u16 {
        const left_count = self.vectorLength(left);
        const right_count = self.vectorLength(right);
        if (left_count != right_count) return error.Syntax;
        if (left_count == 1) return self.codeScalarCompare(left, right, opcode);

        if (opcode == .eq or opcode == .ne) {
            var result = try self.allocateRegister();
            try self.emit(.{ .opcode = .integer, .p1 = 1, .p2 = result });
            var field: u16 = 0;
            while (field < left_count) : (field += 1) {
                const left_field = try self.expressionVectorRegister(left, field);
                const right_field = try self.expressionVectorRegister(right, field);
                const equal = try self.codeScalarCompare(left_field, right_field, .eq);
                const combined = try self.allocateRegister();
                try self.emit(.{ .opcode = .and_, .p1 = equal, .p2 = result, .p3 = combined });
                result = combined;
            }
            if (opcode == .ne) {
                const inverted = try self.allocateRegister();
                try self.emit(.{ .opcode = .not, .p1 = result, .p2 = inverted });
                return inverted;
            }
            return result;
        }

        const strict_opcode: vdbe.Opcode = switch (opcode) {
            .lt, .le => .lt,
            .gt, .ge => .gt,
            else => return error.Syntax,
        };
        const target = try self.allocateRegister();
        try self.emit(.{ .opcode = .null_, .p2 = target });
        var done_jumps: [32]usize = undefined;
        var null_jumps: [32]usize = undefined;
        var jump_count: usize = 0;
        var field: u16 = 0;
        while (field < left_count) : (field += 1) {
            const left_field = try self.expressionVectorRegister(left, field);
            const right_field = try self.expressionVectorRegister(right, field);
            const equal = try self.codeScalarCompare(left_field, right_field, .eq);
            const equal_branch = try self.expressionIfTrue(equal, 0, false);
            null_jumps[jump_count] = self.instructions.items.len;
            try self.emit(.{ .opcode = .is_null, .p1 = equal });
            const decisive = try self.codeScalarCompare(left_field, right_field, strict_opcode);
            try self.emit(.{ .opcode = .copy, .p1 = decisive, .p2 = target });
            done_jumps[jump_count] = self.instructions.items.len;
            try self.emit(.{ .opcode = .goto });
            jump_count += 1;
            self.patchJump(equal_branch, self.instructions.items.len);
        }
        try self.emit(.{ .opcode = .integer, .p1 = @intFromBool(opcode == .le or opcode == .ge), .p2 = target });
        const done = self.instructions.items.len;
        for (done_jumps[0..jump_count]) |address| {
            self.patchJump(address, done);
        }
        for (null_jumps[0..jump_count]) |address| {
            self.patchJump(address, done);
        }
        return target;
    }

    fn codeNullPredicate(self: *Parser, source: u16, not_null: bool) !u16 {
        const target = try self.allocateRegister();
        try self.emit(.{ .opcode = .integer, .p1 = @intFromBool(not_null), .p2 = target });
        const branch = self.instructions.items.len;
        try self.emit(.{ .opcode = .is_null, .p1 = source });
        const done_jump = self.instructions.items.len;
        try self.emit(.{ .opcode = .goto });
        const null_address = self.instructions.items.len;
        try self.emit(.{ .opcode = .integer, .p1 = @intFromBool(!not_null), .p2 = target });
        const done = self.instructions.items.len;
        self.patchJump(branch, null_address);
        self.patchJump(done_jump, done);
        return target;
    }

    /// Source `exprCodeTargetAndOr()`: branch around an operand only when the
    /// first value fully determines the result, while preserving NULL logic.
    fn expressionCodeTargetAndOr(self: *Parser, left: u16, operator: u16, right_precedence: u8) ParserError!u16 {
        const target = try self.allocateRegister();
        const branch = if (operator == tokens.tk_and)
            try self.expressionIfFalse(left, 0, true)
        else
            try self.expressionIfTrue(left, 0, false);
        const right = try self.expression(right_precedence);
        try self.emit(.{ .opcode = if (operator == tokens.tk_and) .and_ else .or_, .p1 = right, .p2 = left, .p3 = target });
        const done_jump = self.instructions.items.len;
        try self.emit(.{ .opcode = .goto });
        const short_circuit = self.instructions.items.len;
        try self.emit(.{ .opcode = .or_, .p1 = left, .p2 = left, .p3 = target });
        const done = self.instructions.items.len;
        self.patchJump(branch, short_circuit);
        self.patchJump(done_jump, done);
        return target;
    }

    /// Source `exprCodeBetween()`: evaluate the common LHS once and combine
    /// the lower and upper comparisons using SQLite three-valued AND.
    fn expressionCodeBetween(self: *Parser, value: u16, right_precedence: u8) ParserError!u16 {
        const lower = try self.expression(right_precedence);
        _ = try self.require(tokens.tk_and);
        const upper = try self.expression(right_precedence);
        const lower_result = try self.codeVectorCompare(value, lower, .ge);
        const upper_result = try self.codeVectorCompare(value, upper, .le);
        const target = try self.allocateRegister();
        try self.emit(.{ .opcode = .and_, .p1 = upper_result, .p2 = lower_result, .p3 = target });
        return target;
    }

    fn subqueryClosingToken(self: *const Parser) ?usize {
        var depth: usize = 1;
        var index = self.position;
        while (index < self.token_list.len) : (index += 1) {
            if (self.token_list[index].typ == tokens.tk_lp) depth += 1;
            if (self.token_list[index].typ == tokens.tk_rp) {
                depth -= 1;
                if (depth == 0) return index;
            }
        }
        return null;
    }

    fn subqueryHasVariable(self: *const Parser, closing: usize) bool {
        for (self.token_list[self.position..closing]) |token| {
            if (token.typ == tokens.tk_variable) return true;
        }
        return false;
    }

    /// Source `findCompatibleInRhsSubrtn()`: reuse an already materialized,
    /// uncorrelated subquery with the same normalized token bytes.
    fn findCompatibleInRhsSubroutine(self: *const Parser, start: usize, end: usize) ?u16 {
        var index: usize = 0;
        while (index < self.subquery_count) : (index += 1) {
            const cached = self.subqueries[index];
            if (std.mem.eql(u8, self.source[start..end], self.source[cached.start..cached.end])) return cached.first_register;
        }
        return null;
    }

    fn rememberSubquery(self: *Parser, start: usize, end: usize, first_register: u16) !void {
        if (@as(usize, self.subquery_count) == self.subqueries.len) return error.TooBig;
        self.subqueries[@intCast(self.subquery_count)] = .{ .start = start, .end = end, .first_register = first_register };
        self.subquery_count += 1;
    }

    /// Source `sqlite3CodeSubselect()`: compile a bounded scalar SELECT into a
    /// stable result register and reuse identical uncorrelated subqueries.
    fn expressionCodeSubselect(self: *Parser) ParserError!u16 {
        const closing = self.subqueryClosingToken() orelse return error.Syntax;
        const start = self.token_list[self.position].start;
        const end = self.token_list[closing].end;
        const reusable = !self.subqueryHasVariable(closing);
        if (reusable) {
            if (self.findCompatibleInRhsSubroutine(start, end)) |register| {
                self.position = closing + 1;
                return register;
            }
        }
        _ = try self.require(tokens.tk_select);
        const value = try self.expression(0);
        _ = try self.require(tokens.tk_rp);
        const stable = try self.allocateRegister();
        try self.emit(.{ .opcode = .copy, .p1 = value, .p2 = stable });
        if (reusable) try self.rememberSubquery(start, end, stable);
        return stable;
    }

    /// Source `sqlite3CodeRhsOfIN()`: materialize the scalar SELECT RHS of an
    /// IN operator once and compare it using the normal three-valued path.
    fn expressionCodeRhsOfIn(self: *Parser, value: u16, negated: bool) ParserError!u16 {
        const candidate = try self.expressionCodeSubselect();
        var result = try self.codeVectorCompare(value, candidate, .eq);
        if (negated) {
            const inverted = try self.allocateRegister();
            try self.emit(.{ .opcode = .not, .p1 = result, .p2 = inverted });
            result = inverted;
        }
        return result;
    }

    /// Source `sqlite3FindInIndex()` bounded ephemeral-index path. Constant
    /// integer lists large enough to justify indexing use a RowSet probe;
    /// smaller or dynamic lists fall back to comparison code.
    fn findInIndex(self: *Parser, value: u16, negated: bool) ParserError!?u16 {
        const closing = self.subqueryClosingToken() orelse return error.Syntax;
        var scan = self.position;
        var count: usize = 0;
        var expect_value = true;
        while (scan < closing) : (scan += 1) {
            const token = self.token_list[scan];
            if (expect_value) {
                if (token.typ != tokens.tk_integer) return null;
                count += 1;
            } else if (token.typ != tokens.tk_comma) return null;
            expect_value = !expect_value;
        }
        if (expect_value or count < 3) return null;

        const set_register = try self.allocateRegister();
        var item: usize = 0;
        while (item < count) : (item += 1) {
            const token = try self.require(tokens.tk_integer);
            const integer = std.fmt.parseInt(i64, token.text, 10) catch return error.TooBig;
            const candidate = try self.allocateRegister();
            if (integer >= std.math.minInt(i32) and integer <= std.math.maxInt(i32)) {
                try self.emit(.{ .opcode = .integer, .p1 = @intCast(integer), .p2 = candidate });
            } else {
                try self.emit(.{ .opcode = .int64, .p2 = candidate, .p4 = .{ .integer = integer } });
            }
            try self.emit(.{ .opcode = .row_set_add, .p1 = set_register, .p2 = candidate });
            if (item + 1 < count) _ = try self.require(tokens.tk_comma);
        }
        _ = try self.require(tokens.tk_rp);

        const result = try self.allocateRegister();
        try self.emit(.{ .opcode = .null_, .p2 = result });
        const null_jump = self.instructions.items.len;
        try self.emit(.{ .opcode = .is_null, .p1 = value });
        try self.emit(.{ .opcode = .integer, .p1 = 0, .p2 = result });
        const found_jump = self.instructions.items.len;
        try self.emit(.{ .opcode = .row_set_test, .p1 = set_register, .p3 = value, .p4 = .{ .integer = -1 } });
        const done_jump = self.instructions.items.len;
        try self.emit(.{ .opcode = .goto });
        const found = self.instructions.items.len;
        try self.emit(.{ .opcode = .integer, .p1 = 1, .p2 = result });
        const done = self.instructions.items.len;
        self.patchJump(null_jump, done);
        self.patchJump(found_jump, found);
        self.patchJump(done_jump, done);
        if (negated) {
            const inverted = try self.allocateRegister();
            try self.emit(.{ .opcode = .not, .p1 = result, .p2 = inverted });
            return inverted;
        }
        return result;
    }

    /// Source `sqlite3ExprCodeIN()` list path. The OR reduction retains NULL
    /// whenever no equality is true but either side of a comparison is NULL.
    fn expressionCodeIn(self: *Parser, value: u16, negated: bool) ParserError!u16 {
        _ = try self.require(tokens.tk_lp);
        if (self.current()) |token| {
            if (token.typ == tokens.tk_select) return self.expressionCodeRhsOfIn(value, negated);
        }
        if (try self.findInIndex(value, negated)) |indexed| return indexed;
        var result = try self.allocateRegister();
        try self.emit(.{ .opcode = .integer, .p1 = 0, .p2 = result });
        if (!self.accept(tokens.tk_rp)) {
            while (true) {
                const candidate = try self.expression(0);
                const equal = try self.codeVectorCompare(value, candidate, .eq);
                const combined = try self.allocateRegister();
                try self.emit(.{ .opcode = .or_, .p1 = equal, .p2 = result, .p3 = combined });
                result = combined;
                if (self.accept(tokens.tk_rp)) break;
                _ = try self.require(tokens.tk_comma);
            }
        }
        if (negated) {
            const inverted = try self.allocateRegister();
            try self.emit(.{ .opcode = .not, .p1 = result, .p2 = inverted });
            return inverted;
        }
        return result;
    }

    /// Source `exprCodeInlineFunction()`: compile COALESCE/IFNULL and IIF as
    /// lazy control flow so unselected arguments are never evaluated.
    fn expressionCodeInlineFunction(self: *Parser, name: []const u8) ParserError!u16 {
        const target = try self.allocateRegister();
        if (std.ascii.eqlIgnoreCase(name, "coalesce") or std.ascii.eqlIgnoreCase(name, "ifnull")) {
            var branches: [32]usize = undefined;
            var branch_count: usize = 0;
            var argument_count: usize = 0;
            while (true) {
                const value = try self.expression(0);
                argument_count += 1;
                try self.emit(.{ .opcode = .copy, .p1 = value, .p2 = target });
                if (self.accept(tokens.tk_rp)) break;
                if (branch_count == branches.len) return error.TooBig;
                branches[branch_count] = self.instructions.items.len;
                branch_count += 1;
                try self.emit(.{ .opcode = .not_null, .p1 = target });
                _ = try self.require(tokens.tk_comma);
            }
            if (argument_count < 2 or (std.ascii.eqlIgnoreCase(name, "ifnull") and argument_count != 2)) return error.Syntax;
            const done = self.instructions.items.len;
            for (branches[0..branch_count]) |address| {
                self.patchJump(address, done);
            }
            return target;
        }

        var done_jumps: [32]usize = undefined;
        var done_count: usize = 0;
        var pending_false: ?usize = null;
        while (true) {
            const candidate_start = self.instructions.items.len;
            if (pending_false) |address| self.patchJump(address, candidate_start);
            const candidate = try self.expression(0);
            if (self.accept(tokens.tk_rp)) {
                try self.emit(.{ .opcode = .copy, .p1 = candidate, .p2 = target });
                break;
            }
            _ = try self.require(tokens.tk_comma);
            const false_branch = try self.expressionIfFalse(candidate, 0, false);
            const value = try self.expression(0);
            try self.emit(.{ .opcode = .copy, .p1 = value, .p2 = target });
            if (done_count == done_jumps.len) return error.TooBig;
            done_jumps[done_count] = self.instructions.items.len;
            done_count += 1;
            try self.emit(.{ .opcode = .goto });
            if (self.accept(tokens.tk_rp)) {
                self.patchJump(false_branch, self.instructions.items.len);
                try self.emit(.{ .opcode = .null_, .p2 = target });
                break;
            }
            _ = try self.require(tokens.tk_comma);
            pending_false = false_branch;
        }
        const done = self.instructions.items.len;
        for (done_jumps[0..done_count]) |address| {
            self.patchJump(address, done);
        }
        return target;
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
            if (self.current()) |current_token| {
                if (current_token.typ == tokens.tk_select) return self.expressionCodeSubselect();
            }
            var values = std.ArrayList(u16).empty;
            defer values.deinit(self.allocator);
            try values.append(self.allocator, try self.expression(0));
            while (self.accept(tokens.tk_comma)) {
                try values.append(self.allocator, try self.expression(0));
            }
            _ = try self.require(tokens.tk_rp);
            return self.expressionCodeVector(values.items);
        }
        if (token.typ == tokens.tk_id and self.position + 1 < self.token_list.len and self.token_list[self.position + 1].typ == tokens.tk_lp) {
            self.position += 2;
            if (std.ascii.eqlIgnoreCase(token.text, "coalesce") or std.ascii.eqlIgnoreCase(token.text, "ifnull") or std.ascii.eqlIgnoreCase(token.text, "iif")) {
                if (self.accept(tokens.tk_rp)) return error.Syntax;
                return self.expressionCodeInlineFunction(token.text);
            }
            const connection = self.connection orelse return error.Syntax;
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
            tokens.tk_between,
            tokens.tk_in,
            tokens.tk_isnull,
            tokens.tk_notnull,
            tokens.tk_eq,
            tokens.tk_ne,
            tokens.tk_lt,
            tokens.tk_le,
            tokens.tk_gt,
            tokens.tk_ge,
            => 3,
            tokens.tk_plus, tokens.tk_minus => 6,
            tokens.tk_star, tokens.tk_slash, tokens.tk_rem => 7,
            tokens.tk_concat => 8,
            else => 0,
        };
    }

    fn expression(self: *Parser, minimum: u8) ParserError!u16 {
        var left = try self.unary();
        while (self.current()) |operator| {
            var operator_type = operator.typ;
            var negated_in = false;
            if (operator_type == tokens.tk_not and self.position + 1 < self.token_list.len and self.token_list[self.position + 1].typ == tokens.tk_in) {
                operator_type = tokens.tk_in;
                negated_in = true;
            }
            const level = precedence(operator_type);
            if (level == 0 or level < minimum) break;
            self.position += if (negated_in) 2 else 1;
            if (operator_type == tokens.tk_and or operator_type == tokens.tk_or) {
                left = try self.expressionCodeTargetAndOr(left, operator_type, level + 1);
                continue;
            }
            if (operator_type == tokens.tk_between) {
                left = try self.expressionCodeBetween(left, level + 1);
                continue;
            }
            if (operator_type == tokens.tk_in) {
                left = try self.expressionCodeIn(left, negated_in);
                continue;
            }
            if (operator_type == tokens.tk_isnull or operator_type == tokens.tk_notnull) {
                left = try self.codeNullPredicate(left, operator_type == tokens.tk_notnull);
                continue;
            }
            const right = try self.expression(level + 1);
            if (operator_type == tokens.tk_eq or operator_type == tokens.tk_ne or
                operator_type == tokens.tk_lt or operator_type == tokens.tk_le or
                operator_type == tokens.tk_gt or operator_type == tokens.tk_ge)
            {
                const comparison: vdbe.Opcode = switch (operator_type) {
                    tokens.tk_eq => .eq,
                    tokens.tk_ne => .ne,
                    tokens.tk_lt => .lt,
                    tokens.tk_le => .le,
                    tokens.tk_gt => .gt,
                    tokens.tk_ge => .ge,
                    else => unreachable,
                };
                left = try self.codeVectorCompare(left, right, comparison);
                continue;
            }
            const target = try self.allocateRegister();
            const opcode: vdbe.Opcode = switch (operator_type) {
                tokens.tk_plus => .add,
                tokens.tk_minus => .subtract,
                tokens.tk_star => .multiply,
                tokens.tk_slash => .divide,
                tokens.tk_rem => .remainder,
                tokens.tk_concat => .concat,
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

const ResolvedColumn = struct {
    name: []const u8,
    declared_type: []const u8,
    collation: []const u8,
    explicit_collation: bool,
    descending: bool,
    record_index: usize,
    integer_primary_key: bool,
    primary_key: bool,
    unique: bool,
    not_null: bool,
    default_start: ?usize,
    default_end: usize,
    generated_start: ?usize,
    generated_end: usize,
    generated_virtual: bool,
    scan_expression: bool,
    index_transform: btree.IndexTransform,
};

fn isTableConstraintStart(token_type: u16) bool {
    return token_type == tokens.tk_constraint or token_type == tokens.tk_primary or
        token_type == tokens.tk_unique or token_type == tokens.tk_check or
        token_type == tokens.tk_foreign;
}

const IntegerInIndexExpression = struct { first: i64, second: i64, is_not: bool, consumed: usize };

fn resolveIntegerInIndexExpression(token_list: []const Token, position: usize) ?IntegerInIndexExpression {
    if (position >= token_list.len) return null;
    const is_not = token_list[position].typ == tokens.tk_not;
    const in_position = position + @intFromBool(is_not);
    if (in_position + 1 >= token_list.len or token_list[in_position].typ != tokens.tk_in or token_list[in_position + 1].typ != tokens.tk_lp) return null;
    const first = resolveSignedIndexOperand(token_list, in_position + 2) orelse return null;
    const comma_position = in_position + 2 + first.consumed;
    if (comma_position >= token_list.len or token_list[comma_position].typ != tokens.tk_comma) return null;
    const second = resolveSignedIndexOperand(token_list, comma_position + 1) orelse return null;
    const close_position = comma_position + 1 + second.consumed;
    if (close_position >= token_list.len or token_list[close_position].typ != tokens.tk_rp) return null;
    return .{ .first = first.value, .second = second.value, .is_not = is_not, .consumed = close_position + 1 - position };
}

const IntegerBetweenIndexExpression = struct { low: i64, high: i64, is_not: bool, consumed: usize };

fn resolveIntegerBetweenIndexExpression(token_list: []const Token, position: usize) ?IntegerBetweenIndexExpression {
    if (position >= token_list.len) return null;
    const is_not = token_list[position].typ == tokens.tk_not;
    const between_position = position + @intFromBool(is_not);
    if (between_position >= token_list.len or token_list[between_position].typ != tokens.tk_between) return null;
    const low = resolveSignedIndexOperand(token_list, between_position + 1) orelse return null;
    const and_position = between_position + 1 + low.consumed;
    if (and_position >= token_list.len or token_list[and_position].typ != tokens.tk_and) return null;
    const high = resolveSignedIndexOperand(token_list, and_position + 1) orelse return null;
    return .{ .low = low.value, .high = high.value, .is_not = is_not, .consumed = and_position + 1 + high.consumed - position };
}

const RealInIndexExpression = struct { first: f64, second: f64, is_not: bool, consumed: usize };

fn resolveRealInIndexExpression(token_list: []const Token, position: usize) ?RealInIndexExpression {
    if (position >= token_list.len) return null;
    const is_not = token_list[position].typ == tokens.tk_not;
    const in_position = position + @intFromBool(is_not);
    if (in_position + 1 >= token_list.len or token_list[in_position].typ != tokens.tk_in or token_list[in_position + 1].typ != tokens.tk_lp) return null;
    const first_position = in_position + 2;
    const first_is_float = resolveSignedFloatIndexOperand(token_list, first_position) != null;
    const first = resolveSignedNumericIndexOperand(token_list, first_position) orelse return null;
    const comma_position = first_position + first.consumed;
    if (comma_position >= token_list.len or token_list[comma_position].typ != tokens.tk_comma) return null;
    const second_position = comma_position + 1;
    const second_is_float = resolveSignedFloatIndexOperand(token_list, second_position) != null;
    const second = resolveSignedNumericIndexOperand(token_list, second_position) orelse return null;
    const close_position = second_position + second.consumed;
    if (close_position >= token_list.len or token_list[close_position].typ != tokens.tk_rp or (!first_is_float and !second_is_float)) return null;
    return .{ .first = first.value, .second = second.value, .is_not = is_not, .consumed = close_position + 1 - position };
}

const RealBetweenIndexExpression = struct { low: f64, high: f64, is_not: bool, consumed: usize };

fn resolveRealBetweenIndexExpression(token_list: []const Token, position: usize) ?RealBetweenIndexExpression {
    if (position >= token_list.len) return null;
    const is_not = token_list[position].typ == tokens.tk_not;
    const between_position = position + @intFromBool(is_not);
    if (between_position >= token_list.len or token_list[between_position].typ != tokens.tk_between) return null;
    const low_position = between_position + 1;
    const low_is_float = resolveSignedFloatIndexOperand(token_list, low_position) != null;
    const low = resolveSignedNumericIndexOperand(token_list, low_position) orelse return null;
    const and_position = low_position + low.consumed;
    if (and_position >= token_list.len or token_list[and_position].typ != tokens.tk_and) return null;
    const high_position = and_position + 1;
    const high_is_float = resolveSignedFloatIndexOperand(token_list, high_position) != null;
    const high = resolveSignedNumericIndexOperand(token_list, high_position) orelse return null;
    if (!low_is_float and !high_is_float) return null;
    return .{ .low = low.value, .high = high.value, .is_not = is_not, .consumed = high_position + high.consumed - position };
}

const IfnullIndexExpression = struct {
    column_name: []const u8,
    replacement: i64,
    null_if: bool,
    column_first: bool,
    consumed: usize,
};

const SignedIndexOperand = struct { value: i64, consumed: usize };
const SignedFloatIndexOperand = struct { value: f64, consumed: usize };

fn resolveSignedFloatIndexOperand(token_list: []const Token, position: usize) ?SignedFloatIndexOperand {
    if (position >= token_list.len) return null;
    const negative = token_list[position].typ == tokens.tk_minus;
    const signed = negative or token_list[position].typ == tokens.tk_plus;
    const literal_position = position + @intFromBool(signed);
    if (literal_position >= token_list.len or token_list[literal_position].typ != tokens.tk_float) return null;
    var value = std.fmt.parseFloat(f64, token_list[literal_position].text) catch return null;
    if (negative) value = -value;
    return .{ .value = value, .consumed = literal_position + 1 - position };
}

fn resolveSignedIndexOperand(token_list: []const Token, position: usize) ?SignedIndexOperand {
    if (position >= token_list.len) return null;
    const negative = token_list[position].typ == tokens.tk_minus;
    const signed = negative or token_list[position].typ == tokens.tk_plus;
    const literal_position = position + @intFromBool(signed);
    if (literal_position >= token_list.len or token_list[literal_position].typ != tokens.tk_integer) return null;
    var value = std.fmt.parseInt(i64, token_list[literal_position].text, 10) catch return null;
    if (negative) value = -value;
    return .{ .value = value, .consumed = literal_position + 1 - position };
}

const SignedNumericIndexOperand = struct { value: f64, consumed: usize };

fn resolveSignedNumericIndexOperand(token_list: []const Token, position: usize) ?SignedNumericIndexOperand {
    if (resolveSignedFloatIndexOperand(token_list, position)) |operand| {
        return .{ .value = operand.value, .consumed = operand.consumed };
    }
    const operand = resolveSignedIndexOperand(token_list, position) orelse return null;
    return .{ .value = @floatFromInt(operand.value), .consumed = operand.consumed };
}

const SignedOffsetIndexOperand = struct { value: i64, consumed: usize };

fn resolveSignedOffsetIndexOperand(token_list: []const Token, position: usize) ?SignedOffsetIndexOperand {
    if (resolveSignedIndexOperand(token_list, position)) |operand| {
        return .{ .value = operand.value, .consumed = operand.consumed };
    }
    const operand = resolveSignedFloatIndexOperand(token_list, position) orelse return null;
    if (!std.math.isFinite(operand.value) or operand.value < -9223372036854775808.0 or operand.value >= 9223372036854775808.0) return null;
    return .{ .value = @intFromFloat(operand.value), .consumed = operand.consumed };
}

const NullBinaryFunctionIndexExpression = struct { column_name: []const u8, constant_null: bool, consumed: usize };

fn resolveNullBinaryFunctionIndexExpression(token_list: []const Token, position: usize) ?NullBinaryFunctionIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "ifnull") and !std.ascii.eqlIgnoreCase(token_list[position].text, "coalesce") and !std.ascii.eqlIgnoreCase(token_list[position].text, "nullif") and !std.ascii.eqlIgnoreCase(token_list[position].text, "min") and !std.ascii.eqlIgnoreCase(token_list[position].text, "max") and !std.ascii.eqlIgnoreCase(token_list[position].text, "pow") and !std.ascii.eqlIgnoreCase(token_list[position].text, "power") and !std.ascii.eqlIgnoreCase(token_list[position].text, "mod") and !std.ascii.eqlIgnoreCase(token_list[position].text, "atan2") and !std.ascii.eqlIgnoreCase(token_list[position].text, "log") and !std.ascii.eqlIgnoreCase(token_list[position].text, "round") and !std.ascii.eqlIgnoreCase(token_list[position].text, "trim") and !std.ascii.eqlIgnoreCase(token_list[position].text, "ltrim") and !std.ascii.eqlIgnoreCase(token_list[position].text, "rtrim")) or token_list[position + 1].typ != tokens.tk_lp or token_list[position + 3].typ != tokens.tk_comma or token_list[position + 5].typ != tokens.tk_rp) return null;
    const null_first = token_list[position + 2].typ == tokens.tk_null and token_list[position + 4].typ == tokens.tk_id;
    const null_second = token_list[position + 2].typ == tokens.tk_id and token_list[position + 4].typ == tokens.tk_null;
    if (!null_first and !null_second) return null;
    return .{
        .column_name = token_list[if (null_first) position + 4 else position + 2].text,
        .constant_null = std.ascii.eqlIgnoreCase(token_list[position].text, "min") or std.ascii.eqlIgnoreCase(token_list[position].text, "max") or std.ascii.eqlIgnoreCase(token_list[position].text, "pow") or std.ascii.eqlIgnoreCase(token_list[position].text, "power") or std.ascii.eqlIgnoreCase(token_list[position].text, "mod") or std.ascii.eqlIgnoreCase(token_list[position].text, "atan2") or std.ascii.eqlIgnoreCase(token_list[position].text, "log") or std.ascii.eqlIgnoreCase(token_list[position].text, "round") or std.ascii.eqlIgnoreCase(token_list[position].text, "trim") or std.ascii.eqlIgnoreCase(token_list[position].text, "ltrim") or std.ascii.eqlIgnoreCase(token_list[position].text, "rtrim") or (null_first and std.ascii.eqlIgnoreCase(token_list[position].text, "nullif")),
        .consumed = 6,
    };
}

const RealIfnullIndexExpression = struct { column_name: []const u8, replacement: f64, null_if: bool, column_first: bool, consumed: usize };

fn resolveRealIfnullIndexExpression(token_list: []const Token, position: usize) ?RealIfnullIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "ifnull") and !std.ascii.eqlIgnoreCase(token_list[position].text, "coalesce") and !std.ascii.eqlIgnoreCase(token_list[position].text, "nullif")) or token_list[position + 1].typ != tokens.tk_lp) return null;
    const null_if = std.ascii.eqlIgnoreCase(token_list[position].text, "nullif");
    if (token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_comma) {
        const replacement = resolveSignedFloatIndexOperand(token_list, position + 4) orelse return null;
        const end_position = position + 4 + replacement.consumed;
        if (end_position >= token_list.len or token_list[end_position].typ != tokens.tk_rp) return null;
        return .{ .column_name = token_list[position + 2].text, .replacement = replacement.value, .null_if = null_if, .column_first = true, .consumed = end_position + 1 - position };
    }
    const replacement = resolveSignedFloatIndexOperand(token_list, position + 2) orelse return null;
    const comma_position = position + 2 + replacement.consumed;
    if (comma_position + 2 >= token_list.len or token_list[comma_position].typ != tokens.tk_comma or token_list[comma_position + 1].typ != tokens.tk_id or token_list[comma_position + 2].typ != tokens.tk_rp) return null;
    return .{ .column_name = token_list[comma_position + 1].text, .replacement = replacement.value, .null_if = null_if, .column_first = false, .consumed = comma_position + 3 - position };
}

fn resolveIfnullIndexExpression(token_list: []const Token, position: usize) ?IfnullIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "ifnull") and !std.ascii.eqlIgnoreCase(token_list[position].text, "coalesce") and !std.ascii.eqlIgnoreCase(token_list[position].text, "nullif")) or token_list[position + 1].typ != tokens.tk_lp) return null;
    const null_if = std.ascii.eqlIgnoreCase(token_list[position].text, "nullif");
    if (token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_comma) {
        const replacement = resolveSignedIndexOperand(token_list, position + 4) orelse return null;
        const end_position = position + 4 + replacement.consumed;
        if (end_position >= token_list.len or token_list[end_position].typ != tokens.tk_rp) return null;
        return .{ .column_name = token_list[position + 2].text, .replacement = replacement.value, .null_if = null_if, .column_first = true, .consumed = end_position + 1 - position };
    }
    const replacement = resolveSignedIndexOperand(token_list, position + 2) orelse return null;
    const comma_position = position + 2 + replacement.consumed;
    if (comma_position + 2 >= token_list.len or token_list[comma_position].typ != tokens.tk_comma or token_list[comma_position + 1].typ != tokens.tk_id or token_list[comma_position + 2].typ != tokens.tk_rp) return null;
    return .{ .column_name = token_list[comma_position + 1].text, .replacement = replacement.value, .null_if = null_if, .column_first = false, .consumed = comma_position + 3 - position };
}

fn resolveUnaryMathIndexOperation(name: []const u8) ?btree.IndexUnaryMath {
    const mappings = [_]struct { name: []const u8, operation: btree.IndexUnaryMath }{
        .{ .name = "sqrt", .operation = .square_root },
        .{ .name = "exp", .operation = .exponential },
        .{ .name = "ln", .operation = .natural_log },
        .{ .name = "log", .operation = .common_log },
        .{ .name = "log10", .operation = .common_log },
        .{ .name = "log2", .operation = .binary_log },
        .{ .name = "acos", .operation = .arc_cosine },
        .{ .name = "asin", .operation = .arc_sine },
        .{ .name = "atan", .operation = .arc_tangent },
        .{ .name = "cos", .operation = .cosine },
        .{ .name = "sin", .operation = .sine },
        .{ .name = "tan", .operation = .tangent },
        .{ .name = "cosh", .operation = .hyperbolic_cosine },
        .{ .name = "sinh", .operation = .hyperbolic_sine },
        .{ .name = "tanh", .operation = .hyperbolic_tangent },
        .{ .name = "acosh", .operation = .inverse_hyperbolic_cosine },
        .{ .name = "asinh", .operation = .inverse_hyperbolic_sine },
        .{ .name = "atanh", .operation = .inverse_hyperbolic_tangent },
        .{ .name = "radians", .operation = .radians },
        .{ .name = "degrees", .operation = .degrees },
    };
    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(name, mapping.name)) return mapping.operation;
    }
    return null;
}

const BinaryMathIndexExpression = struct { column_name: []const u8, operation: btree.IndexBinaryMath, operand: f64, column_first: bool, consumed: usize };

fn resolveBinaryMathIndexExpression(token_list: []const Token, position: usize) ?BinaryMathIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or token_list[position + 1].typ != tokens.tk_lp) return null;
    const operation: btree.IndexBinaryMath = if (std.ascii.eqlIgnoreCase(token_list[position].text, "pow") or std.ascii.eqlIgnoreCase(token_list[position].text, "power"))
        .power
    else if (std.ascii.eqlIgnoreCase(token_list[position].text, "mod"))
        .modulo
    else if (std.ascii.eqlIgnoreCase(token_list[position].text, "atan2"))
        .arc_tangent_two
    else if (std.ascii.eqlIgnoreCase(token_list[position].text, "log"))
        .logarithm
    else
        return null;
    if (token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_comma) {
        const operand = resolveSignedNumericIndexOperand(token_list, position + 4) orelse return null;
        const end_position = position + 4 + operand.consumed;
        if (end_position >= token_list.len or token_list[end_position].typ != tokens.tk_rp) return null;
        return .{ .column_name = token_list[position + 2].text, .operation = operation, .operand = operand.value, .column_first = true, .consumed = end_position + 1 - position };
    }
    const operand = resolveSignedNumericIndexOperand(token_list, position + 2) orelse return null;
    const comma_position = position + 2 + operand.consumed;
    if (comma_position + 2 >= token_list.len or token_list[comma_position].typ != tokens.tk_comma or token_list[comma_position + 1].typ != tokens.tk_id or token_list[comma_position + 2].typ != tokens.tk_rp) return null;
    return .{ .column_name = token_list[comma_position + 1].text, .operation = operation, .operand = operand.value, .column_first = false, .consumed = comma_position + 3 - position };
}

const RealMinMaxIndexExpression = struct { column_name: []const u8, comparison: f64, maximum: bool, column_first: bool, consumed: usize };

fn resolveRealMinMaxIndexExpression(token_list: []const Token, position: usize) ?RealMinMaxIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "min") and !std.ascii.eqlIgnoreCase(token_list[position].text, "max")) or token_list[position + 1].typ != tokens.tk_lp) return null;
    const maximum = std.ascii.eqlIgnoreCase(token_list[position].text, "max");
    if (token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_comma) {
        const comparison = resolveSignedFloatIndexOperand(token_list, position + 4) orelse return null;
        const end_position = position + 4 + comparison.consumed;
        if (end_position >= token_list.len or token_list[end_position].typ != tokens.tk_rp) return null;
        return .{ .column_name = token_list[position + 2].text, .comparison = comparison.value, .maximum = maximum, .column_first = true, .consumed = end_position + 1 - position };
    }
    const comparison = resolveSignedFloatIndexOperand(token_list, position + 2) orelse return null;
    const comma_position = position + 2 + comparison.consumed;
    if (comma_position + 2 >= token_list.len or token_list[comma_position].typ != tokens.tk_comma or token_list[comma_position + 1].typ != tokens.tk_id or token_list[comma_position + 2].typ != tokens.tk_rp) return null;
    return .{ .column_name = token_list[comma_position + 1].text, .comparison = comparison.value, .maximum = maximum, .column_first = false, .consumed = comma_position + 3 - position };
}

const MinMaxIndexExpression = struct { column_name: []const u8, comparison: i64, maximum: bool, column_first: bool, consumed: usize };

fn resolveMinMaxIndexExpression(token_list: []const Token, position: usize) ?MinMaxIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "min") and !std.ascii.eqlIgnoreCase(token_list[position].text, "max")) or token_list[position + 1].typ != tokens.tk_lp) return null;
    const maximum = std.ascii.eqlIgnoreCase(token_list[position].text, "max");
    if (token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_comma) {
        const comparison = resolveSignedIndexOperand(token_list, position + 4) orelse return null;
        const end_position = position + 4 + comparison.consumed;
        if (end_position >= token_list.len or token_list[end_position].typ != tokens.tk_rp) return null;
        return .{ .column_name = token_list[position + 2].text, .comparison = comparison.value, .maximum = maximum, .column_first = true, .consumed = end_position + 1 - position };
    }
    const comparison = resolveSignedIndexOperand(token_list, position + 2) orelse return null;
    const comma_position = position + 2 + comparison.consumed;
    if (comma_position + 2 >= token_list.len or token_list[comma_position].typ != tokens.tk_comma or token_list[comma_position + 1].typ != tokens.tk_id or token_list[comma_position + 2].typ != tokens.tk_rp) return null;
    return .{ .column_name = token_list[comma_position + 1].text, .comparison = comparison.value, .maximum = maximum, .column_first = false, .consumed = comma_position + 3 - position };
}

const ReversedRealIndexExpression = struct { column_name: []const u8, transform: btree.IndexTransform, consumed: usize };

fn resolveReversedRealIndexExpression(token_list: []const Token, position: usize) ?ReversedRealIndexExpression {
    const operand = resolveSignedFloatIndexOperand(token_list, position) orelse return null;
    const operation_position = position + operand.consumed;
    if (operation_position >= token_list.len) return null;
    if (token_list[operation_position].typ == tokens.tk_is) {
        const is_suffix = resolveIndexIsSuffix(token_list, operation_position + 1);
        const column_position = operation_position + 1 + is_suffix.consumed;
        if (column_position >= token_list.len or token_list[column_position].typ != tokens.tk_id) return null;
        return .{ .column_name = token_list[column_position].text, .transform = .{ .real_is = .{ .value = operand.value, .is_not = is_suffix.is_not } }, .consumed = column_position + 1 - position };
    }
    if (operation_position + 1 >= token_list.len or token_list[operation_position + 1].typ != tokens.tk_id) return null;
    const arithmetic: ?btree.IndexRealArithmeticOperation = switch (token_list[operation_position].typ) {
        tokens.tk_plus => .add,
        tokens.tk_minus => .subtract,
        tokens.tk_star => .multiply,
        tokens.tk_slash => .divide,
        else => null,
    };
    if (arithmetic) |operation| {
        return .{ .column_name = token_list[operation_position + 1].text, .transform = .{ .real_arithmetic = .{ .operation = operation, .value = operand.value, .column_first = false } }, .consumed = operation_position + 2 - position };
    }
    const operation: btree.IndexComparisonOperation = switch (token_list[operation_position].typ) {
        tokens.tk_eq => .eq,
        tokens.tk_ne => .ne,
        tokens.tk_lt => .gt,
        tokens.tk_le => .ge,
        tokens.tk_gt => .lt,
        tokens.tk_ge => .le,
        else => return null,
    };
    return .{ .column_name = token_list[operation_position + 1].text, .transform = .{ .real_compare = .{ .operation = operation, .value = operand.value } }, .consumed = operation_position + 2 - position };
}

const ReversedIntegerIndexExpression = struct { column_name: []const u8, transform: btree.IndexTransform, consumed: usize };

fn resolveReversedIntegerIndexExpression(token_list: []const Token, position: usize) ?ReversedIntegerIndexExpression {
    const operand = resolveSignedIndexOperand(token_list, position) orelse return null;
    const operation_position = position + operand.consumed;
    if (operation_position + 1 >= token_list.len) return null;
    if (token_list[operation_position].typ == tokens.tk_is) {
        const is_suffix = resolveIndexIsSuffix(token_list, operation_position + 1);
        const column_position = operation_position + 1 + is_suffix.consumed;
        if (column_position >= token_list.len or token_list[column_position].typ != tokens.tk_id) return null;
        return .{ .column_name = token_list[column_position].text, .transform = .{ .integer_is = .{ .value = operand.value, .is_not = is_suffix.is_not } }, .consumed = column_position + 1 - position };
    }
    if (token_list[operation_position + 1].typ != tokens.tk_id) return null;
    const arithmetic: ?btree.IndexTransform = switch (token_list[operation_position].typ) {
        tokens.tk_plus => .{ .integer_add = operand.value },
        tokens.tk_minus => .{ .integer_reverse_subtract = operand.value },
        tokens.tk_star => .{ .integer_multiply = operand.value },
        tokens.tk_slash => .{ .integer_reverse_divide = operand.value },
        tokens.tk_rem => .{ .integer_reverse_remainder = operand.value },
        tokens.tk_bitand => .{ .integer_bit_and = operand.value },
        tokens.tk_bitor => .{ .integer_bit_or = operand.value },
        tokens.tk_lshift => .{ .integer_reverse_shift_left = operand.value },
        tokens.tk_rshift => .{ .integer_reverse_shift_right = operand.value },
        else => null,
    };
    if (arithmetic) |transform| {
        return .{ .column_name = token_list[operation_position + 1].text, .transform = transform, .consumed = operation_position + 2 - position };
    }
    const operation: btree.IndexComparisonOperation = switch (token_list[operation_position].typ) {
        tokens.tk_eq => .eq,
        tokens.tk_ne => .ne,
        tokens.tk_lt => .gt,
        tokens.tk_le => .ge,
        tokens.tk_gt => .lt,
        tokens.tk_ge => .le,
        else => return null,
    };
    return .{ .column_name = token_list[operation_position + 1].text, .transform = .{ .integer_compare = .{ .operation = operation, .value = operand.value } }, .consumed = operation_position + 2 - position };
}

const NullOperatorIndexExpression = struct { column_name: []const u8, consumed: usize };

fn resolveNullOperatorIndexExpression(token_list: []const Token, position: usize) ?NullOperatorIndexExpression {
    if (position + 2 >= token_list.len) return null;
    switch (token_list[position + 1].typ) {
        tokens.tk_plus, tokens.tk_minus, tokens.tk_star, tokens.tk_slash, tokens.tk_rem, tokens.tk_bitand, tokens.tk_bitor, tokens.tk_lshift, tokens.tk_rshift, tokens.tk_concat, tokens.tk_eq, tokens.tk_ne, tokens.tk_lt, tokens.tk_le, tokens.tk_gt, tokens.tk_ge => {},
        else => return null,
    }
    if (token_list[position].typ == tokens.tk_id and token_list[position + 2].typ == tokens.tk_null) {
        return .{ .column_name = token_list[position].text, .consumed = 3 };
    }
    if (token_list[position].typ == tokens.tk_null and token_list[position + 2].typ == tokens.tk_id) {
        return .{ .column_name = token_list[position + 2].text, .consumed = 3 };
    }
    return null;
}

const ConcatIndexExpression = struct { column_name: []const u8, constant_null: bool = false, consumed: usize };

fn resolveConcatIndexExpression(token_list: []const Token, position: usize) ?ConcatIndexExpression {
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_concat) {
        if (token_list[position].typ == tokens.tk_id and token_list[position + 2].typ == tokens.tk_null) {
            return .{ .column_name = token_list[position].text, .constant_null = true, .consumed = 3 };
        }
        if (token_list[position].typ == tokens.tk_null and token_list[position + 2].typ == tokens.tk_id) {
            return .{ .column_name = token_list[position + 2].text, .constant_null = true, .consumed = 3 };
        }
    }
    if (position + 3 >= token_list.len or token_list[position].typ != tokens.tk_id or !std.ascii.eqlIgnoreCase(token_list[position].text, "concat") or token_list[position + 1].typ != tokens.tk_lp) return null;
    var cursor = position + 2;
    var column_name: ?[]const u8 = null;
    while (cursor < token_list.len and token_list[cursor].typ != tokens.tk_rp) {
        if (token_list[cursor].typ == tokens.tk_id and column_name == null) {
            column_name = token_list[cursor].text;
        } else if (token_list[cursor].typ != tokens.tk_null) {
            return null;
        }
        cursor += 1;
        if (cursor < token_list.len and token_list[cursor].typ == tokens.tk_comma) {
            cursor += 1;
            if (cursor >= token_list.len or token_list[cursor].typ == tokens.tk_rp) return null;
        } else if (cursor >= token_list.len or token_list[cursor].typ != tokens.tk_rp) {
            return null;
        }
    }
    if (cursor >= token_list.len or token_list[cursor].typ != tokens.tk_rp or column_name == null) return null;
    return .{ .column_name = column_name.?, .consumed = cursor + 1 - position };
}

const NullSubstringIndexExpression = struct { column_name: []const u8, consumed: usize };

fn resolveNullSubstringIndexExpression(token_list: []const Token, position: usize) ?NullSubstringIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "substr") and !std.ascii.eqlIgnoreCase(token_list[position].text, "substring")) or token_list[position + 1].typ != tokens.tk_lp) return null;
    var cursor = position + 2;
    var argument_count: usize = 0;
    var column_name: ?[]const u8 = null;
    var have_null = false;
    while (cursor < token_list.len and token_list[cursor].typ != tokens.tk_rp) {
        if (token_list[cursor].typ == tokens.tk_id and column_name == null) {
            column_name = token_list[cursor].text;
            cursor += 1;
        } else if (token_list[cursor].typ == tokens.tk_null) {
            have_null = true;
            cursor += 1;
        } else if (resolveSignedNumericIndexOperand(token_list, cursor)) |operand| {
            cursor += operand.consumed;
        } else {
            return null;
        }
        argument_count += 1;
        if (cursor < token_list.len and token_list[cursor].typ == tokens.tk_comma) {
            cursor += 1;
            if (cursor >= token_list.len or token_list[cursor].typ == tokens.tk_rp) return null;
        } else if (cursor >= token_list.len or token_list[cursor].typ != tokens.tk_rp) {
            return null;
        }
    }
    if (cursor >= token_list.len or token_list[cursor].typ != tokens.tk_rp or column_name == null or !have_null or (argument_count != 2 and argument_count != 3)) return null;
    return .{ .column_name = column_name.?, .consumed = cursor + 1 - position };
}

const RealComparisonIndexExpression = struct { transform: btree.IndexTransform, consumed: usize };

fn resolveRealComparisonIndexExpression(token_list: []const Token, position: usize) ?RealComparisonIndexExpression {
    if (position >= token_list.len) return null;
    const operand = resolveSignedFloatIndexOperand(token_list, position + 1) orelse return null;
    const transform: btree.IndexTransform = switch (token_list[position].typ) {
        tokens.tk_eq => .{ .real_compare = .{ .operation = .eq, .value = operand.value } },
        tokens.tk_ne => .{ .real_compare = .{ .operation = .ne, .value = operand.value } },
        tokens.tk_lt => .{ .real_compare = .{ .operation = .lt, .value = operand.value } },
        tokens.tk_le => .{ .real_compare = .{ .operation = .le, .value = operand.value } },
        tokens.tk_gt => .{ .real_compare = .{ .operation = .gt, .value = operand.value } },
        tokens.tk_ge => .{ .real_compare = .{ .operation = .ge, .value = operand.value } },
        tokens.tk_plus => .{ .real_arithmetic = .{ .operation = .add, .value = operand.value, .column_first = true } },
        tokens.tk_minus => .{ .real_arithmetic = .{ .operation = .subtract, .value = operand.value, .column_first = true } },
        tokens.tk_star => .{ .real_arithmetic = .{ .operation = .multiply, .value = operand.value, .column_first = true } },
        tokens.tk_slash => .{ .real_arithmetic = .{ .operation = .divide, .value = operand.value, .column_first = true } },
        else => return null,
    };
    return .{ .transform = transform, .consumed = 1 + operand.consumed };
}

const SubstringIndexExpression = struct { column_name: []const u8, start: i64, count: ?i64, consumed: usize };

fn resolveSubstringIndexExpression(token_list: []const Token, position: usize) ?SubstringIndexExpression {
    if (position + 5 >= token_list.len or token_list[position].typ != tokens.tk_id or (!std.ascii.eqlIgnoreCase(token_list[position].text, "substr") and !std.ascii.eqlIgnoreCase(token_list[position].text, "substring")) or token_list[position + 1].typ != tokens.tk_lp or token_list[position + 2].typ != tokens.tk_id or token_list[position + 3].typ != tokens.tk_comma) return null;
    const start = resolveSignedOffsetIndexOperand(token_list, position + 4) orelse return null;
    var end_position = position + 4 + start.consumed;
    if (end_position >= token_list.len) return null;
    var count: ?i64 = null;
    if (token_list[end_position].typ == tokens.tk_comma) {
        const resolved_count = resolveSignedOffsetIndexOperand(token_list, end_position + 1) orelse return null;
        count = resolved_count.value;
        end_position += 1 + resolved_count.consumed;
    }
    if (end_position >= token_list.len or token_list[end_position].typ != tokens.tk_rp) return null;
    return .{ .column_name = token_list[position + 2].text, .start = start.value, .count = count, .consumed = end_position + 1 - position };
}

fn resolveColumns(allocator: std.mem.Allocator, sql: []const u8) !struct { source: [:0]u8, tokens: []Token, columns: []ResolvedColumn } {
    const source = try allocator.dupeZ(u8, sql);
    errdefer allocator.free(source);
    const parsed = try tokenize(allocator, source);
    errdefer allocator.free(parsed.tokens);
    var columns = std.ArrayList(ResolvedColumn).empty;
    errdefer columns.deinit(allocator);
    const schema_is_index = parsed.tokens.len > 1 and parsed.tokens[0].typ == tokens.tk_create and (parsed.tokens[1].typ == tokens.tk_index or parsed.tokens[1].typ == tokens.tk_unique);
    var position: usize = 0;
    while (position < parsed.tokens.len and parsed.tokens[position].typ != tokens.tk_lp) : (position += 1) {}
    if (position == parsed.tokens.len) return error.Syntax;
    position += 1;
    var record_index: usize = 0;
    while (position < parsed.tokens.len and parsed.tokens[position].typ != tokens.tk_rp) {
        if (isTableConstraintStart(parsed.tokens[position].typ)) {
            var constraint_depth: usize = 0;
            while (position < parsed.tokens.len) : (position += 1) {
                const constraint_type = parsed.tokens[position].typ;
                if (constraint_type == tokens.tk_lp) {
                    constraint_depth += 1;
                }
                if (constraint_type == tokens.tk_rp) {
                    if (constraint_depth == 0) break;
                    constraint_depth -= 1;
                }
                if (constraint_type == tokens.tk_comma and constraint_depth == 0) break;
            }
            if (position < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_comma) {
                position += 1;
            }
            continue;
        }
        const wrapped_expression = schema_is_index and parsed.tokens[position].typ == tokens.tk_lp;
        if (wrapped_expression) position += 1;
        var scan_expression = false;
        var index_transform: btree.IndexTransform = .identity;
        var name: []const u8 = undefined;
        var start = position;
        if (if (schema_is_index) resolveNullOperatorIndexExpression(parsed.tokens, position) else null) |null_operator_expression| {
            scan_expression = true;
            index_transform = .constant_null;
            name = null_operator_expression.column_name;
        } else if (if (schema_is_index) resolveConcatIndexExpression(parsed.tokens, position) else null) |concat_expression| {
            scan_expression = true;
            index_transform = if (concat_expression.constant_null) .constant_null else .concat_single;
            name = concat_expression.column_name;
        } else if (if (schema_is_index) resolveReversedRealIndexExpression(parsed.tokens, position) else null) |reversed_real_expression| {
            scan_expression = true;
            index_transform = reversed_real_expression.transform;
            name = reversed_real_expression.column_name;
        } else if (if (schema_is_index) resolveReversedIntegerIndexExpression(parsed.tokens, position) else null) |reversed_expression| {
            scan_expression = true;
            index_transform = reversed_expression.transform;
            name = reversed_expression.column_name;
        } else if (if (schema_is_index) resolveBinaryMathIndexExpression(parsed.tokens, position) else null) |binary_math_expression| {
            scan_expression = true;
            index_transform = .{ .binary_math = .{ .operation = binary_math_expression.operation, .operand = binary_math_expression.operand, .column_first = binary_math_expression.column_first } };
            name = binary_math_expression.column_name;
        } else if (schema_is_index and position + 3 < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_id and resolveUnaryMathIndexOperation(parsed.tokens[position].text) != null and parsed.tokens[position + 1].typ == tokens.tk_lp and parsed.tokens[position + 2].typ == tokens.tk_id and parsed.tokens[position + 3].typ == tokens.tk_rp) {
            scan_expression = true;
            index_transform = .{ .unary_math = resolveUnaryMathIndexOperation(parsed.tokens[position].text).? };
            name = parsed.tokens[position + 2].text;
        } else if (if (schema_is_index) resolveRealMinMaxIndexExpression(parsed.tokens, position) else null) |real_min_max_expression| {
            scan_expression = true;
            index_transform = if (real_min_max_expression.maximum) .{ .scalar_max_real = .{ .comparison = real_min_max_expression.comparison, .column_first = real_min_max_expression.column_first } } else .{ .scalar_min_real = .{ .comparison = real_min_max_expression.comparison, .column_first = real_min_max_expression.column_first } };
            name = real_min_max_expression.column_name;
        } else if (if (schema_is_index) resolveMinMaxIndexExpression(parsed.tokens, position) else null) |min_max_expression| {
            scan_expression = true;
            index_transform = if (min_max_expression.maximum) .{ .scalar_max_integer = .{ .comparison = min_max_expression.comparison, .column_first = min_max_expression.column_first } } else .{ .scalar_min_integer = .{ .comparison = min_max_expression.comparison, .column_first = min_max_expression.column_first } };
            name = min_max_expression.column_name;
        } else if (if (schema_is_index) resolveNullSubstringIndexExpression(parsed.tokens, position) else null) |null_substring_expression| {
            scan_expression = true;
            index_transform = .constant_null;
            name = null_substring_expression.column_name;
        } else if (if (schema_is_index) resolveSubstringIndexExpression(parsed.tokens, position) else null) |substring_expression| {
            scan_expression = true;
            index_transform = .{ .substring = .{ .start = substring_expression.start, .count = substring_expression.count } };
            name = substring_expression.column_name;
        } else if (if (schema_is_index) resolveNullBinaryFunctionIndexExpression(parsed.tokens, position) else null) |null_expression| {
            scan_expression = true;
            index_transform = if (null_expression.constant_null) .constant_null else .identity;
            name = null_expression.column_name;
        } else if (if (schema_is_index) resolveRealIfnullIndexExpression(parsed.tokens, position) else null) |real_ifnull_expression| {
            scan_expression = true;
            index_transform = if (real_ifnull_expression.null_if)
                if (real_ifnull_expression.column_first) .{ .null_if_real = real_ifnull_expression.replacement } else .{ .reverse_null_if_real = real_ifnull_expression.replacement }
            else if (real_ifnull_expression.column_first)
                .{ .null_coalesce_real = real_ifnull_expression.replacement }
            else
                .{ .constant_real = real_ifnull_expression.replacement };
            name = real_ifnull_expression.column_name;
        } else if (if (schema_is_index) resolveIfnullIndexExpression(parsed.tokens, position) else null) |ifnull_expression| {
            scan_expression = true;
            index_transform = if (ifnull_expression.null_if)
                if (ifnull_expression.column_first) .{ .null_if_integer = ifnull_expression.replacement } else .{ .reverse_null_if_integer = ifnull_expression.replacement }
            else if (ifnull_expression.column_first)
                .{ .null_coalesce_integer = ifnull_expression.replacement }
            else
                .{ .constant_integer = ifnull_expression.replacement };
            name = ifnull_expression.column_name;
        } else if (schema_is_index and position + 5 < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "likelihood") and parsed.tokens[position + 1].typ == tokens.tk_lp and parsed.tokens[position + 2].typ == tokens.tk_id and parsed.tokens[position + 3].typ == tokens.tk_comma and (parsed.tokens[position + 4].typ == tokens.tk_integer or parsed.tokens[position + 4].typ == tokens.tk_float) and parsed.tokens[position + 5].typ == tokens.tk_rp) {
            const probability = std.fmt.parseFloat(f64, parsed.tokens[position + 4].text) catch return error.Syntax;
            if (probability < 0 or probability > 1) return error.Syntax;
            scan_expression = true;
            name = parsed.tokens[position + 2].text;
        } else if (schema_is_index and position + 3 < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_id and (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "abs") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "sign") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "round") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "ceil") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "ceiling") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "floor") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "trunc") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "typeof") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "octet_length") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "length") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "unicode") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "trim") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "ltrim") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "rtrim") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "concat") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "likely") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "unlikely")) and parsed.tokens[position + 1].typ == tokens.tk_lp and parsed.tokens[position + 2].typ == tokens.tk_id and parsed.tokens[position + 3].typ == tokens.tk_rp) {
            scan_expression = true;
            index_transform = if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "sign")) .numeric_sign else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "round")) .numeric_round else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "ceil") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "ceiling")) .numeric_ceil else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "floor")) .numeric_floor else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "trunc")) .numeric_trunc else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "typeof")) .storage_type else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "octet_length")) .octet_length else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "length")) .text_length else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "unicode")) .unicode_value else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "trim")) .text_trim else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "ltrim")) .text_ltrim else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "rtrim")) .text_rtrim else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "concat")) .concat_single else if (std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "likely") or std.ascii.eqlIgnoreCase(parsed.tokens[position].text, "unlikely")) .identity else .numeric_abs;
            name = parsed.tokens[position + 2].text;
        } else {
            if (schema_is_index and (parsed.tokens[position].typ == tokens.tk_plus or parsed.tokens[position].typ == tokens.tk_minus or parsed.tokens[position].typ == tokens.tk_bitnot or parsed.tokens[position].typ == tokens.tk_not) and position + 1 < parsed.tokens.len and parsed.tokens[position + 1].typ == tokens.tk_id) {
                scan_expression = true;
                if (parsed.tokens[position].typ == tokens.tk_minus) {
                    index_transform = .numeric_negate;
                } else if (parsed.tokens[position].typ == tokens.tk_bitnot) {
                    index_transform = .integer_bit_not;
                } else if (parsed.tokens[position].typ == tokens.tk_not) {
                    index_transform = .numeric_not;
                }
                position += 1;
            }
            if (parsed.tokens[position].typ != tokens.tk_id) return error.Syntax;
            name = parsed.tokens[position].text;
            start = position;
        }
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
        var unique = false;
        var not_null = false;
        var collation: []const u8 = "BINARY";
        var explicit_collation = false;
        var descending = false;
        var default_start: ?usize = null;
        var default_end = position;
        var generated_start: ?usize = null;
        var generated_end = position;
        var generated_virtual = false;
        var index = start + 1;
        while (index < position) : (index += 1) {
            if (index + 1 < position and parsed.tokens[index].typ == tokens.tk_primary and parsed.tokens[index + 1].typ == tokens.tk_key) {
                primary = true;
            }
            if (parsed.tokens[index].typ == tokens.tk_unique) {
                unique = true;
            }
            if (parsed.tokens[index].typ == tokens.tk_desc) {
                descending = true;
            }
            if (index + 1 < position and parsed.tokens[index].typ == tokens.tk_not and parsed.tokens[index + 1].typ == tokens.tk_null) {
                not_null = true;
            }
            if (index + 1 < position and parsed.tokens[index].typ == tokens.tk_collate) {
                collation = parsed.tokens[index + 1].text;
                explicit_collation = true;
            }
            if (parsed.tokens[index].typ == tokens.tk_default and index + 1 < position and default_start == null) {
                default_start = index + 1;
                default_end = index + 2;
                if (parsed.tokens[index + 1].typ == tokens.tk_lp) {
                    var default_depth: usize = 1;
                    while (default_end < position and default_depth != 0) : (default_end += 1) {
                        if (parsed.tokens[default_end].typ == tokens.tk_lp) {
                            default_depth += 1;
                        }
                        if (parsed.tokens[default_end].typ == tokens.tk_rp) {
                            default_depth -= 1;
                        }
                    }
                } else if ((parsed.tokens[index + 1].typ == tokens.tk_plus or parsed.tokens[index + 1].typ == tokens.tk_minus) and default_end < position) {
                    default_end += 1;
                }
            }
            if (parsed.tokens[index].typ == tokens.tk_as and index + 2 < position and parsed.tokens[index + 1].typ == tokens.tk_lp and generated_start == null) {
                generated_start = index + 2;
                generated_end = generated_start.?;
                var generated_depth: usize = 1;
                while (generated_end < position and generated_depth != 0) : (generated_end += 1) {
                    if (parsed.tokens[generated_end].typ == tokens.tk_lp) {
                        generated_depth += 1;
                    }
                    if (parsed.tokens[generated_end].typ == tokens.tk_rp) {
                        generated_depth -= 1;
                    }
                }
                if (generated_depth != 0) return error.Syntax;
                generated_end -= 1;
                const storage_position = generated_end + 1;
                generated_virtual = storage_position >= position or parsed.tokens[storage_position].typ == tokens.tk_virtual or !std.ascii.eqlIgnoreCase(parsed.tokens[storage_position].text, "stored");
            }
        }
        if (schema_is_index and start + 2 == position and (parsed.tokens[start + 1].typ == tokens.tk_isnull or parsed.tokens[start + 1].typ == tokens.tk_notnull)) {
            scan_expression = true;
            index_transform = if (parsed.tokens[start + 1].typ == tokens.tk_notnull) .is_not_null else .is_null;
        } else if (schema_is_index and start + 2 < position and parsed.tokens[start + 1].typ == tokens.tk_is) {
            const is_suffix = resolveIndexIsSuffix(parsed.tokens, start + 2);
            const operand_position = start + 2 + is_suffix.consumed;
            if (operand_position < position and parsed.tokens[operand_position].typ == tokens.tk_null and operand_position + 1 == position) {
                scan_expression = true;
                index_transform = if (is_suffix.is_not) .is_not_null else .is_null;
            } else if (resolveSignedFloatIndexOperand(parsed.tokens, operand_position)) |resolved_operand| {
                if (operand_position + resolved_operand.consumed == position) {
                    scan_expression = true;
                    index_transform = .{ .real_is = .{ .value = resolved_operand.value, .is_not = is_suffix.is_not } };
                }
            } else if (resolveSignedIndexOperand(parsed.tokens, operand_position)) |resolved_operand| {
                if (operand_position + resolved_operand.consumed == position) {
                    scan_expression = true;
                    index_transform = .{ .integer_is = .{ .value = resolved_operand.value, .is_not = is_suffix.is_not } };
                }
            }
        }
        if (schema_is_index and !scan_expression) {
            if (resolveRealInIndexExpression(parsed.tokens, start + 1)) |in_expression| {
                if (start + 1 + in_expression.consumed == position) {
                    scan_expression = true;
                    index_transform = .{ .real_in = .{ .first = in_expression.first, .second = in_expression.second, .is_not = in_expression.is_not } };
                }
            }
        }
        if (schema_is_index and !scan_expression) {
            if (resolveIntegerInIndexExpression(parsed.tokens, start + 1)) |in_expression| {
                if (start + 1 + in_expression.consumed == position) {
                    scan_expression = true;
                    index_transform = .{ .integer_in = .{ .first = in_expression.first, .second = in_expression.second, .is_not = in_expression.is_not } };
                }
            }
        }
        if (schema_is_index and !scan_expression) {
            if (resolveRealBetweenIndexExpression(parsed.tokens, start + 1)) |between_expression| {
                if (start + 1 + between_expression.consumed == position) {
                    scan_expression = true;
                    index_transform = .{ .real_between = .{ .low = between_expression.low, .high = between_expression.high, .is_not = between_expression.is_not } };
                }
            }
        }
        if (schema_is_index and !scan_expression) {
            if (resolveIntegerBetweenIndexExpression(parsed.tokens, start + 1)) |between_expression| {
                if (start + 1 + between_expression.consumed == position) {
                    scan_expression = true;
                    index_transform = .{ .integer_between = .{ .low = between_expression.low, .high = between_expression.high, .is_not = between_expression.is_not } };
                }
            }
        }
        if (schema_is_index and !scan_expression) {
            if (resolveRealComparisonIndexExpression(parsed.tokens, start + 1)) |real_comparison| {
                if (start + 1 + real_comparison.consumed == position) {
                    scan_expression = true;
                    index_transform = real_comparison.transform;
                }
            }
        }
        if (schema_is_index and start + 2 < position and (parsed.tokens[start + 1].typ == tokens.tk_plus or parsed.tokens[start + 1].typ == tokens.tk_minus or parsed.tokens[start + 1].typ == tokens.tk_star or parsed.tokens[start + 1].typ == tokens.tk_slash or parsed.tokens[start + 1].typ == tokens.tk_rem or parsed.tokens[start + 1].typ == tokens.tk_bitand or parsed.tokens[start + 1].typ == tokens.tk_bitor or parsed.tokens[start + 1].typ == tokens.tk_lshift or parsed.tokens[start + 1].typ == tokens.tk_rshift or parsed.tokens[start + 1].typ == tokens.tk_eq or parsed.tokens[start + 1].typ == tokens.tk_ne or parsed.tokens[start + 1].typ == tokens.tk_lt or parsed.tokens[start + 1].typ == tokens.tk_le or parsed.tokens[start + 1].typ == tokens.tk_gt or parsed.tokens[start + 1].typ == tokens.tk_ge)) {
            if (resolveSignedIndexOperand(parsed.tokens, start + 2)) |resolved_operand| {
                if (start + 2 + resolved_operand.consumed == position) {
                    var operand = resolved_operand.value;
                    scan_expression = true;
                    if (parsed.tokens[start + 1].typ == tokens.tk_eq or parsed.tokens[start + 1].typ == tokens.tk_ne or parsed.tokens[start + 1].typ == tokens.tk_lt or parsed.tokens[start + 1].typ == tokens.tk_le or parsed.tokens[start + 1].typ == tokens.tk_gt or parsed.tokens[start + 1].typ == tokens.tk_ge) {
                        const operation: btree.IndexComparisonOperation = switch (parsed.tokens[start + 1].typ) {
                            tokens.tk_eq => .eq,
                            tokens.tk_ne => .ne,
                            tokens.tk_lt => .lt,
                            tokens.tk_le => .le,
                            tokens.tk_gt => .gt,
                            tokens.tk_ge => .ge,
                            else => unreachable,
                        };
                        index_transform = .{ .integer_compare = .{ .operation = operation, .value = operand } };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_star) {
                        index_transform = .{ .integer_multiply = operand };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_slash) {
                        index_transform = .{ .integer_divide = operand };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_rem) {
                        index_transform = .{ .integer_remainder = operand };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_bitand) {
                        index_transform = .{ .integer_bit_and = operand };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_bitor) {
                        index_transform = .{ .integer_bit_or = operand };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_lshift) {
                        index_transform = .{ .integer_shift_left = operand };
                    } else if (parsed.tokens[start + 1].typ == tokens.tk_rshift) {
                        index_transform = .{ .integer_shift_right = operand };
                    } else {
                        if (parsed.tokens[start + 1].typ == tokens.tk_minus) operand = -operand;
                        index_transform = .{ .integer_add = operand };
                    }
                }
            }
        }
        try columns.append(allocator, .{ .name = name, .declared_type = declared_type, .collation = collation, .explicit_collation = explicit_collation, .descending = descending, .record_index = record_index, .integer_primary_key = primary and std.ascii.eqlIgnoreCase(declared_type, "INTEGER"), .primary_key = primary, .unique = unique or primary, .not_null = not_null, .default_start = default_start, .default_end = default_end, .generated_start = generated_start, .generated_end = generated_end, .generated_virtual = generated_virtual, .scan_expression = scan_expression, .index_transform = index_transform });
        if (!generated_virtual) {
            record_index += 1;
        }
        if (wrapped_expression) {
            if (position >= parsed.tokens.len or parsed.tokens[position].typ != tokens.tk_rp) return error.Syntax;
            position += 1;
        }
        if (position < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_comma) position += 1;
    }
    return .{ .source = source, .tokens = parsed.tokens, .columns = try columns.toOwnedSlice(allocator) };
}

const ForeignKeyAction = enum(u8) {
    no_action,
    restrict,
    cascade,
    set_null,
    set_default,
};

const ForeignKeyMapping = struct {
    child_column: usize,
    parent_column: ?[]const u8,
};

const ForeignKeyDefinition = struct {
    parent_table: []const u8,
    mapping_start: usize,
    mapping_count: usize,
    on_delete: ForeignKeyAction = .no_action,
    on_update: ForeignKeyAction = .no_action,
    deferred: bool = false,
};

const ForeignKeyDefinitions = struct {
    allocator: std.mem.Allocator,
    source: [:0]u8,
    tokens: []Token,
    keys: []ForeignKeyDefinition,
    mappings: []ForeignKeyMapping,

    fn deinit(self: *ForeignKeyDefinitions) void {
        self.allocator.free(self.mappings);
        self.allocator.free(self.keys);
        self.allocator.free(self.tokens);
        self.allocator.free(self.source);
        self.* = undefined;
    }

    fn keyMappings(self: *const ForeignKeyDefinitions, key: ForeignKeyDefinition) []const ForeignKeyMapping {
        return self.mappings[key.mapping_start..][0..key.mapping_count];
    }
};

fn resolvedColumnIndex(columns: []const ResolvedColumn, name: []const u8) ?usize {
    for (columns, 0..) |column, index| {
        if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
    }
    return null;
}

fn parseForeignKeyColumnList(token_list: []const Token, position: *usize, end: usize, output: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    if (position.* >= end or token_list[position.*].typ != tokens.tk_lp) return error.Syntax;
    position.* += 1;
    while (position.* < end) {
        if (token_list[position.*].typ != tokens.tk_id) return error.Syntax;
        try output.append(allocator, token_list[position.*].text);
        position.* += 1;
        if (position.* < end and token_list[position.*].typ == tokens.tk_comma) {
            position.* += 1;
            continue;
        }
        if (position.* >= end or token_list[position.*].typ != tokens.tk_rp) return error.Syntax;
        position.* += 1;
        return;
    }
    return error.Syntax;
}

fn parseForeignKeyAction(token_list: []const Token, position: *usize, end: usize) !ForeignKeyAction {
    if (position.* >= end) return error.Syntax;
    const first = token_list[position.*].typ;
    position.* += 1;
    if (first == tokens.tk_cascade) return .cascade;
    if (first == tokens.tk_restrict) return .restrict;
    if (first == tokens.tk_no) {
        if (position.* >= end or token_list[position.*].typ != tokens.tk_action) return error.Syntax;
        position.* += 1;
        return .no_action;
    }
    if (first == tokens.tk_set) {
        if (position.* >= end) return error.Syntax;
        const second = token_list[position.*].typ;
        position.* += 1;
        if (second == tokens.tk_null) return .set_null;
        if (second == tokens.tk_default) return .set_default;
    }
    return error.Syntax;
}

fn appendForeignKeySegment(
    allocator: std.mem.Allocator,
    token_list: []const Token,
    segment_start: usize,
    segment_end: usize,
    columns: []const ResolvedColumn,
    keys: *std.ArrayList(ForeignKeyDefinition),
    mappings: *std.ArrayList(ForeignKeyMapping),
) !void {
    var position = segment_start;
    if (position >= segment_end) return;
    if (token_list[position].typ == tokens.tk_constraint) {
        if (position + 1 >= segment_end or token_list[position + 1].typ != tokens.tk_id) return error.Syntax;
        position += 2;
    }

    var child_names = std.ArrayList([]const u8).empty;
    defer child_names.deinit(allocator);
    if (position < segment_end and token_list[position].typ == tokens.tk_foreign) {
        position += 1;
        if (position >= segment_end or token_list[position].typ != tokens.tk_key) return error.Syntax;
        position += 1;
        try parseForeignKeyColumnList(token_list, &position, segment_end, &child_names, allocator);
        if (position >= segment_end or token_list[position].typ != tokens.tk_references) return error.Syntax;
    } else {
        if (token_list[segment_start].typ != tokens.tk_id) return;
        try child_names.append(allocator, token_list[segment_start].text);
        position = segment_start + 1;
        while (position < segment_end and token_list[position].typ != tokens.tk_references) : (position += 1) {}
        if (position == segment_end) return;
    }
    position += 1;
    if (position >= segment_end or token_list[position].typ != tokens.tk_id) return error.Syntax;
    const parent_table = token_list[position].text;
    position += 1;

    var parent_names = std.ArrayList([]const u8).empty;
    defer parent_names.deinit(allocator);
    if (position < segment_end and token_list[position].typ == tokens.tk_lp) {
        try parseForeignKeyColumnList(token_list, &position, segment_end, &parent_names, allocator);
        if (parent_names.items.len != child_names.items.len) return error.Syntax;
    }

    var definition = ForeignKeyDefinition{
        .parent_table = parent_table,
        .mapping_start = mappings.items.len,
        .mapping_count = child_names.items.len,
    };
    for (child_names.items, 0..) |child_name, index| {
        const child_column = resolvedColumnIndex(columns, child_name) orelse return error.Syntax;
        try mappings.append(allocator, .{
            .child_column = child_column,
            .parent_column = if (parent_names.items.len == 0) null else parent_names.items[index],
        });
    }
    errdefer mappings.shrinkRetainingCapacity(definition.mapping_start);

    while (position < segment_end) {
        if (token_list[position].typ == tokens.tk_on) {
            if (position + 1 >= segment_end) return error.Syntax;
            const event = token_list[position + 1].typ;
            position += 2;
            const action = try parseForeignKeyAction(token_list, &position, segment_end);
            if (event == tokens.tk_delete) {
                definition.on_delete = action;
            } else if (event == tokens.tk_update) {
                definition.on_update = action;
            } else {
                return error.Syntax;
            }
            continue;
        }
        if (token_list[position].typ == tokens.tk_initially) {
            if (position + 1 >= segment_end) return error.Syntax;
            definition.deferred = token_list[position + 1].typ == tokens.tk_deferred;
            position += 2;
            continue;
        }
        position += 1;
    }
    try keys.append(allocator, definition);
}

fn resolveForeignKeys(allocator: std.mem.Allocator, sql: []const u8, columns: []const ResolvedColumn) !ForeignKeyDefinitions {
    const source = try allocator.dupeZ(u8, sql);
    errdefer allocator.free(source);
    const parsed = try tokenize(allocator, source);
    errdefer allocator.free(parsed.tokens);
    var keys = std.ArrayList(ForeignKeyDefinition).empty;
    errdefer keys.deinit(allocator);
    var mappings = std.ArrayList(ForeignKeyMapping).empty;
    errdefer mappings.deinit(allocator);

    var position: usize = 0;
    while (position < parsed.tokens.len and parsed.tokens[position].typ != tokens.tk_lp) : (position += 1) {}
    if (position == parsed.tokens.len) return error.Syntax;
    position += 1;
    while (position < parsed.tokens.len and parsed.tokens[position].typ != tokens.tk_rp) {
        const segment_start = position;
        var depth: usize = 0;
        while (position < parsed.tokens.len) : (position += 1) {
            const token_type = parsed.tokens[position].typ;
            if (token_type == tokens.tk_lp) depth += 1;
            if (token_type == tokens.tk_rp) {
                if (depth == 0) break;
                depth -= 1;
            }
            if (token_type == tokens.tk_comma and depth == 0) break;
        }
        try appendForeignKeySegment(allocator, parsed.tokens, segment_start, position, columns, &keys, &mappings);
        if (position < parsed.tokens.len and parsed.tokens[position].typ == tokens.tk_comma) position += 1;
    }
    return .{
        .allocator = allocator,
        .source = source,
        .tokens = parsed.tokens,
        .keys = try keys.toOwnedSlice(allocator),
        .mappings = try mappings.toOwnedSlice(allocator),
    };
}

fn tableKeyConstraintMatches(allocator: std.mem.Allocator, token_list: []const Token, columns: []const ResolvedColumn, requested: []const ForeignKeyMapping, primary_only: bool) !bool {
    var position: usize = 0;
    while (position < token_list.len and token_list[position].typ != tokens.tk_lp) : (position += 1) {}
    if (position == token_list.len) return error.Syntax;
    position += 1;
    while (position < token_list.len and token_list[position].typ != tokens.tk_rp) {
        const segment_start = position;
        var depth: usize = 0;
        while (position < token_list.len) : (position += 1) {
            const token_type = token_list[position].typ;
            if (token_type == tokens.tk_lp) depth += 1;
            if (token_type == tokens.tk_rp) {
                if (depth == 0) break;
                depth -= 1;
            }
            if (token_type == tokens.tk_comma and depth == 0) break;
        }
        var cursor = segment_start;
        if (cursor < position and token_list[cursor].typ == tokens.tk_constraint) {
            cursor += 2;
        }
        const primary = cursor + 1 < position and token_list[cursor].typ == tokens.tk_primary and token_list[cursor + 1].typ == tokens.tk_key;
        const unique = cursor < position and token_list[cursor].typ == tokens.tk_unique;
        if (primary or (!primary_only and unique)) {
            cursor += if (primary) 2 else 1;
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(allocator);
            try parseForeignKeyColumnList(token_list, &cursor, position, &names, allocator);
            if (names.items.len == requested.len) {
                var matched = true;
                for (requested) |mapping| {
                    const parent_name = mapping.parent_column orelse {
                        matched = false;
                        break;
                    };
                    var found = false;
                    for (names.items) |name| {
                        if (std.ascii.eqlIgnoreCase(name, parent_name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found or resolvedColumnIndex(columns, parent_name) == null) {
                        matched = false;
                        break;
                    }
                }
                if (matched) return true;
            }
        }
        if (position < token_list.len and token_list[position].typ == tokens.tk_comma) position += 1;
    }
    return false;
}

/// Runtime counterpart of source `sqlite3FkLocateIndex()`. The bounded
/// frontend has no CREATE INDEX path yet, so eligible parent keys are inline
/// UNIQUE/PRIMARY KEY declarations or table-level UNIQUE/PRIMARY KEY clauses.
fn locateForeignKeyIndex(
    allocator: std.mem.Allocator,
    database: *btree.Database,
    parent_table_name: []const u8,
    parent_columns: []const ResolvedColumn,
    parent_tokens: []const Token,
    mappings: []const ForeignKeyMapping,
) ![]usize {
    if (mappings.len == 0) return error.ForeignKeyMismatch;
    const result = try allocator.alloc(usize, mappings.len);
    errdefer allocator.free(result);

    if (mappings[0].parent_column == null) {
        for (mappings) |mapping| {
            if (mapping.parent_column != null) return error.ForeignKeyMismatch;
        }
        if (mappings.len == 1) {
            for (parent_columns, 0..) |column, index| {
                if (column.primary_key) {
                    result[0] = index;
                    return result;
                }
            }
        }
        var primary_mappings = std.ArrayList(ForeignKeyMapping).empty;
        defer primary_mappings.deinit(allocator);
        var position: usize = 0;
        while (position < parent_tokens.len and parent_tokens[position].typ != tokens.tk_primary) : (position += 1) {}
        while (position + 2 < parent_tokens.len) : (position += 1) {
            if (parent_tokens[position].typ != tokens.tk_primary or parent_tokens[position + 1].typ != tokens.tk_key or parent_tokens[position + 2].typ != tokens.tk_lp) continue;
            var cursor = position + 2;
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(allocator);
            try parseForeignKeyColumnList(parent_tokens, &cursor, parent_tokens.len, &names, allocator);
            if (names.items.len != mappings.len) return error.ForeignKeyMismatch;
            for (names.items, 0..) |name, index| {
                result[index] = resolvedColumnIndex(parent_columns, name) orelse return error.ForeignKeyMismatch;
            }
            return result;
        }
        return error.ForeignKeyMismatch;
    }

    for (mappings, 0..) |mapping, index| {
        const parent_name = mapping.parent_column orelse return error.ForeignKeyMismatch;
        result[index] = resolvedColumnIndex(parent_columns, parent_name) orelse return error.ForeignKeyMismatch;
    }
    if (mappings.len == 1 and parent_columns[result[0]].unique) return result;
    if (try tableKeyConstraintMatches(allocator, parent_tokens, parent_columns, mappings, false)) return result;

    const opened = database.openCursor(1, .table);
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.ForeignKeyMismatch;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    for (cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(allocator, entry.payload);
        if (decoded.result == .no_memory) return error.OutOfMemory;
        if (decoded.result != .ok) return error.ForeignKeyMismatch;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len < 5) continue;
        const object_type = schemaEntryText(record.values[0]) orelse continue;
        const indexed_table = schemaEntryText(record.values[2]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index") or !std.ascii.eqlIgnoreCase(indexed_table, parent_table_name)) continue;
        const sql = schemaEntryText(record.values[4]) orelse continue;
        const index_columns = resolveColumns(allocator, sql) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.ForeignKeyMismatch;
        defer {
            allocator.free(index_columns.columns);
            allocator.free(index_columns.tokens);
            allocator.free(index_columns.source);
        }
        if (index_columns.tokens.len <= 1 or index_columns.tokens[1].typ != tokens.tk_unique or index_columns.columns.len != mappings.len) continue;
        const partial = resolveIndexPredicate(index_columns.tokens, parent_columns) catch return error.ForeignKeyMismatch;
        if (partial != null) continue;
        var matches = true;
        for (mappings, index_columns.columns, 0..) |mapping, index_column, index| {
            if (index_column.scan_expression) {
                matches = false;
                break;
            }
            const parent_name = mapping.parent_column orelse {
                matches = false;
                break;
            };
            if (!std.ascii.eqlIgnoreCase(parent_name, index_column.name)) {
                matches = false;
                break;
            }
            const effective_collation = if (index_column.explicit_collation) index_column.collation else parent_columns[result[index]].collation;
            if (!std.ascii.eqlIgnoreCase(effective_collation, parent_columns[result[index]].collation)) {
                matches = false;
                break;
            }
        }
        if (matches) return result;
    }
    return error.ForeignKeyMismatch;
}

const ForeignKeyLookupOutcome = struct { result: ResultCode, found: bool = false };

fn foreignKeyValueIsNull(value: btree.Value) bool {
    return switch (value) {
        .null_ => true,
        else => false,
    };
}

fn foreignKeyValueEqual(parent: btree.Value, child: btree.Value) bool {
    return switch (parent) {
        .null_ => foreignKeyValueIsNull(child),
        .integer => |left| switch (child) {
            .integer => |right| left == right,
            .real => |right| @as(f64, @floatFromInt(left)) == right,
            else => false,
        },
        .real => |left| switch (child) {
            .integer => |right| left == @as(f64, @floatFromInt(right)),
            .real => |right| left == right,
            else => false,
        },
        .text => |left| switch (child) {
            .text => |right| std.mem.eql(u8, left, right),
            else => false,
        },
        .blob => |left| switch (child) {
            .blob => |right| std.mem.eql(u8, left, right),
            else => false,
        },
    };
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

const ForeignKeyAffinity = enum { blob, text, numeric, integer, real };

fn foreignKeyAffinity(column: ResolvedColumn) ForeignKeyAffinity {
    if (containsAsciiIgnoreCase(column.declared_type, "INT")) return .integer;
    if (containsAsciiIgnoreCase(column.declared_type, "CHAR") or containsAsciiIgnoreCase(column.declared_type, "CLOB") or containsAsciiIgnoreCase(column.declared_type, "TEXT")) return .text;
    if (column.declared_type.len == 0 or containsAsciiIgnoreCase(column.declared_type, "BLOB")) return .blob;
    if (containsAsciiIgnoreCase(column.declared_type, "REAL") or containsAsciiIgnoreCase(column.declared_type, "FLOA") or containsAsciiIgnoreCase(column.declared_type, "DOUB")) return .real;
    return .numeric;
}

const ForeignKeyNumeric = union(enum) { integer: i64, real: f64 };

fn foreignKeyNumeric(value: btree.Value) ?ForeignKeyNumeric {
    return switch (value) {
        .integer => |integer| .{ .integer = integer },
        .real => |real| .{ .real = real },
        .text => |text| blk: {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (std.fmt.parseInt(i64, trimmed, 10)) |integer| break :blk .{ .integer = integer } else |_| {}
            if (std.fmt.parseFloat(f64, trimmed)) |real| break :blk .{ .real = real } else |_| return null;
        },
        else => null,
    };
}

fn foreignKeyNumericEqual(left: ForeignKeyNumeric, right: ForeignKeyNumeric) bool {
    return switch (left) {
        .integer => |left_integer| switch (right) {
            .integer => |right_integer| left_integer == right_integer,
            .real => |right_real| @as(f64, @floatFromInt(left_integer)) == right_real,
        },
        .real => |left_real| switch (right) {
            .integer => |right_integer| left_real == @as(f64, @floatFromInt(right_integer)),
            .real => |right_real| left_real == right_real,
        },
    };
}

fn trimForeignKeySpaces(value: []const u8) []const u8 {
    var end = value.len;
    while (end != 0 and value[end - 1] == ' ') {
        end -= 1;
    }
    return value[0..end];
}

fn foreignKeyTextEqual(collation: []const u8, left: []const u8, right: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(collation, "NOCASE")) return std.ascii.eqlIgnoreCase(left, right);
    if (std.ascii.eqlIgnoreCase(collation, "RTRIM")) return std.mem.eql(u8, trimForeignKeySpaces(left), trimForeignKeySpaces(right));
    return std.mem.eql(u8, left, right);
}

fn foreignKeyValueText(value: btree.Value, buffer: []u8) ?[]const u8 {
    return switch (value) {
        .text => |text| text,
        .integer => |integer| std.fmt.bufPrint(buffer, "{d}", .{integer}) catch null,
        .real => |real| std.fmt.bufPrint(buffer, "{d}", .{real}) catch null,
        else => null,
    };
}

fn foreignKeyTextValueEqual(column: ResolvedColumn, parent: btree.Value, child: btree.Value) bool {
    var parent_buffer: [128]u8 = undefined;
    var child_buffer: [128]u8 = undefined;
    const parent_text = foreignKeyValueText(parent, &parent_buffer) orelse return false;
    const child_text = foreignKeyValueText(child, &child_buffer) orelse return false;
    return foreignKeyTextEqual(column.collation, parent_text, child_text);
}

fn foreignKeyColumnValueEqual(column: ResolvedColumn, parent: btree.Value, child: btree.Value) bool {
    return switch (foreignKeyAffinity(column)) {
        .integer, .numeric, .real => {
            const left = foreignKeyNumeric(parent) orelse return foreignKeyValueEqual(parent, child);
            const right = foreignKeyNumeric(child) orelse return false;
            return foreignKeyNumericEqual(left, right);
        },
        .text => foreignKeyTextValueEqual(column, parent, child),
        .blob => foreignKeyValueEqual(parent, child),
    };
}

fn foreignKeyRowValue(column: ResolvedColumn, rowid: i64, record_values: []const btree.Value) ?btree.Value {
    if (column.integer_primary_key) return .{ .integer = rowid };
    if (column.record_index >= record_values.len) return null;
    return record_values[column.record_index];
}

fn proposedForeignKeyValue(column: ResolvedColumn, rowid: i64, values: []const btree.Value) ?btree.Value {
    if (column.integer_primary_key) return .{ .integer = rowid };
    if (column.record_index >= values.len) return null;
    return values[column.record_index];
}

fn foreignKeyValuesMatch(
    parent_columns: []const ResolvedColumn,
    parent_indices: []const usize,
    parent_rowid: i64,
    parent_values: []const btree.Value,
    child_values: []const btree.Value,
    mappings: []const ForeignKeyMapping,
) bool {
    for (mappings, parent_indices) |mapping, parent_index| {
        const child = child_values[mapping.child_column];
        const parent = foreignKeyRowValue(parent_columns[parent_index], parent_rowid, parent_values) orelse return false;
        if (!foreignKeyColumnValueEqual(parent_columns[parent_index], parent, child)) return false;
    }
    return true;
}

fn pendingParentRowIsReplaced(connection: *const Connection, table_name: []const u8, rowid: i64) bool {
    for (connection.pending_foreign_key_parents.items) |pending| {
        if (pending.old_rowid == rowid and std.ascii.eqlIgnoreCase(pending.table_name, table_name)) return true;
    }
    return false;
}

/// Runtime counterpart of source `fkLookupParent()`. Pending parent changes
/// are searched before the on-disk tree so cascaded updates see the NEW parent
/// key and never mistake the OLD key for a surviving row.
fn lookupForeignKeyParent(
    connection: *Connection,
    database: *btree.Database,
    parent_table_name: []const u8,
    parent_root_page: u32,
    parent_columns: []const ResolvedColumn,
    parent_indices: []const usize,
    child_values: []const btree.Value,
    mappings: []const ForeignKeyMapping,
    self_rowid: ?i64,
) ForeignKeyLookupOutcome {
    for (mappings) |mapping| {
        if (foreignKeyValueIsNull(child_values[mapping.child_column])) return .{ .result = .ok, .found = true };
    }
    if (self_rowid) |rowid| {
        var self_matches = true;
        for (mappings, parent_indices) |mapping, parent_index| {
            const parent = proposedForeignKeyValue(parent_columns[parent_index], rowid, child_values) orelse {
                self_matches = false;
                break;
            };
            if (!foreignKeyColumnValueEqual(parent_columns[parent_index], parent, child_values[mapping.child_column])) {
                self_matches = false;
                break;
            }
        }
        if (self_matches) return .{ .result = .ok, .found = true };
    }
    for (connection.pending_foreign_key_parents.items) |pending| {
        if (!std.ascii.eqlIgnoreCase(pending.table_name, parent_table_name)) continue;
        const pending_values = pending.new_values orelse continue;
        if (foreignKeyValuesMatch(parent_columns, parent_indices, pending.new_rowid, pending_values, child_values, mappings)) {
            return .{ .result = .ok, .found = true };
        }
    }
    const opened = database.openCursor(parent_root_page, .table);
    if (opened.result != .ok) return .{ .result = opened.result };
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    if (parent_indices.len == 1 and parent_columns[parent_indices[0]].integer_primary_key) {
        const child = child_values[mappings[0].child_column];
        const rowid = switch (child) {
            .integer => |value| value,
            else => return .{ .result = .ok },
        };
        if (pendingParentRowIsReplaced(connection, parent_table_name, rowid)) return .{ .result = .ok };
        return .{ .result = .ok, .found = cursor.seekTable(rowid) };
    }
    if (!cursor.first()) return .{ .result = .ok };
    while (true) {
        const entry = cursor.current() orelse return .{ .result = .corrupt };
        const rowid = entry.rowid orelse return .{ .result = .corrupt };
        if (!pendingParentRowIsReplaced(connection, parent_table_name, rowid) and (self_rowid == null or self_rowid.? != rowid)) {
            const decoded = cursor.record();
            if (decoded.result != .ok) return .{ .result = decoded.result };
            var record = decoded.record.?;
            defer record.deinit();
            if (foreignKeyValuesMatch(parent_columns, parent_indices, rowid, record.values, child_values, mappings)) {
                return .{ .result = .ok, .found = true };
            }
        }
        if (!cursor.next()) break;
    }
    return .{ .result = .ok };
}

fn checkChildForeignKeyParentsMode(connection: *Connection, database: *btree.Database, table_name: []const u8, rowid: i64, values: []const btree.Value, allow_deferred: bool) ResultCode {
    if (connection.database_configuration[2] == 0) return .ok;
    const child_schema_outcome = database.schemaTable(table_name);
    if (child_schema_outcome.result != .ok) return child_schema_outcome.result;
    var child_schema = child_schema_outcome.table.?;
    defer child_schema.deinit();
    const child_columns = resolveColumns(connection.allocator, child_schema.sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    defer {
        connection.allocator.free(child_columns.columns);
        connection.allocator.free(child_columns.tokens);
        connection.allocator.free(child_columns.source);
    }
    var foreign_keys = resolveForeignKeys(connection.allocator, child_schema.sql, child_columns.columns) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    defer foreign_keys.deinit();
    for (foreign_keys.keys) |key| {
        const parent_schema_outcome = database.schemaTable(key.parent_table);
        if (parent_schema_outcome.result != .ok) return if (parent_schema_outcome.result == .no_memory) .no_memory else .error_;
        var parent_schema = parent_schema_outcome.table.?;
        defer parent_schema.deinit();
        const parent_columns = resolveColumns(connection.allocator, parent_schema.sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
        defer {
            connection.allocator.free(parent_columns.columns);
            connection.allocator.free(parent_columns.tokens);
            connection.allocator.free(parent_columns.source);
        }
        const mappings = foreign_keys.keyMappings(key);
        const parent_indices = locateForeignKeyIndex(connection.allocator, database, key.parent_table, parent_columns.columns, parent_columns.tokens, mappings) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
        defer connection.allocator.free(parent_indices);
        const same_table = std.ascii.eqlIgnoreCase(table_name, key.parent_table);
        const lookup = lookupForeignKeyParent(connection, database, key.parent_table, parent_schema.root_page, parent_columns.columns, parent_indices, values, mappings, if (same_table) rowid else null);
        if (lookup.result != .ok) return lookup.result;
        if (!lookup.found) {
            if (allow_deferred and key.deferred and connection.explicit_transaction) continue;
            return ResultCode.fromC(ResultCode.constraint.toC() | (3 << 8));
        }
    }
    return .ok;
}

fn checkChildForeignKeyParents(connection: *Connection, database: *btree.Database, table_name: []const u8, rowid: i64, values: []const btree.Value) ResultCode {
    return checkChildForeignKeyParentsMode(connection, database, table_name, rowid, values, true);
}

fn childRowMatchesParent(
    child_columns: []const ResolvedColumn,
    child_rowid: i64,
    child_values: []const btree.Value,
    mappings: []const ForeignKeyMapping,
    parent_columns: []const ResolvedColumn,
    parent_indices: []const usize,
    parent_rowid: i64,
    parent_values: []const btree.Value,
) bool {
    for (mappings, parent_indices) |mapping, parent_index| {
        const child = foreignKeyRowValue(child_columns[mapping.child_column], child_rowid, child_values) orelse return false;
        if (foreignKeyValueIsNull(child)) return false;
        const parent = foreignKeyRowValue(parent_columns[parent_index], parent_rowid, parent_values) orelse return false;
        if (!foreignKeyColumnValueEqual(parent_columns[parent_index], parent, child)) return false;
    }
    return true;
}

/// Runtime counterpart of source `fkScanChildren()`: scan every child row
/// matching the OLD parent key. The caller either raises a constraint or
/// applies the configured action to the collected rowids.
fn scanForeignKeyChildren(
    database: *btree.Database,
    child_root_page: u32,
    child_columns: []const ResolvedColumn,
    mappings: []const ForeignKeyMapping,
    parent_columns: []const ResolvedColumn,
    parent_indices: []const usize,
    parent_rowid: i64,
    parent_values: []const btree.Value,
    ignored_rowid: ?i64,
    rowids: *std.ArrayList(i64),
) ResultCode {
    const opened = database.openCursor(child_root_page, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    if (!cursor.first()) return .ok;
    while (true) {
        const entry = cursor.current() orelse return .corrupt;
        const child_rowid = entry.rowid orelse return .corrupt;
        if (ignored_rowid == null or child_rowid != ignored_rowid.?) {
            const decoded = cursor.record();
            if (decoded.result != .ok) return decoded.result;
            var record = decoded.record.?;
            defer record.deinit();
            if (childRowMatchesParent(child_columns, child_rowid, record.values, mappings, parent_columns, parent_indices, parent_rowid, parent_values)) {
                rowids.append(database.allocator, child_rowid) catch return .no_memory;
            }
        }
        if (!cursor.next()) break;
    }
    return .ok;
}

const ForeignKeyDefaultOutcome = struct {
    result: ResultCode,
    value: btree.Value = .null_,
    owned: ?[]u8 = null,
};

fn foreignKeyDefaultValue(allocator: std.mem.Allocator, token_list: []const Token, column: ResolvedColumn) ForeignKeyDefaultOutcome {
    var start = column.default_start orelse return .{ .result = .ok };
    var end = @min(column.default_end, token_list.len);
    while (end > start + 1 and token_list[start].typ == tokens.tk_lp and token_list[end - 1].typ == tokens.tk_rp) {
        start += 1;
        end -= 1;
    }
    if (start >= end) return .{ .result = .error_ };
    var negative = false;
    if (token_list[start].typ == tokens.tk_plus or token_list[start].typ == tokens.tk_minus) {
        negative = token_list[start].typ == tokens.tk_minus;
        start += 1;
        if (start >= end) return .{ .result = .error_ };
    }
    const token = token_list[start];
    if (token.typ == tokens.tk_null) return .{ .result = .ok };
    if (token.typ == tokens.tk_integer) {
        const magnitude = std.fmt.parseInt(u64, token.text, 10) catch return .{ .result = .too_big };
        const value: i64 = if (negative) blk: {
            const minimum_magnitude: u64 = @as(u64, std.math.maxInt(i64)) + 1;
            if (magnitude > minimum_magnitude) return .{ .result = .too_big };
            if (magnitude == minimum_magnitude) break :blk std.math.minInt(i64);
            break :blk -@as(i64, @intCast(magnitude));
        } else std.math.cast(i64, magnitude) orelse return .{ .result = .too_big };
        return .{ .result = .ok, .value = .{ .integer = value } };
    }
    if (token.typ == tokens.tk_float) {
        var value = std.fmt.parseFloat(f64, token.text) catch return .{ .result = .error_ };
        if (negative) {
            value = -value;
        }
        return .{ .result = .ok, .value = .{ .real = value } };
    }
    if (negative) return .{ .result = .error_ };
    if (token.typ == tokens.tk_truefalse) {
        return .{ .result = .ok, .value = .{ .integer = @intFromBool(std.ascii.eqlIgnoreCase(token.text, "true")) } };
    }
    if (token.typ == tokens.tk_string) {
        if (token.text.len < 2) return .{ .result = .error_ };
        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(allocator);
        var index: usize = 1;
        while (index + 1 < token.text.len) : (index += 1) {
            if (token.text[index] == '\'' and index + 1 < token.text.len - 1 and token.text[index + 1] == '\'') index += 1;
            decoded.append(allocator, token.text[index]) catch return .{ .result = .no_memory };
        }
        const owned = decoded.toOwnedSlice(allocator) catch return .{ .result = .no_memory };
        return .{ .result = .ok, .value = .{ .text = owned }, .owned = owned };
    }
    if (token.typ == tokens.tk_blob) {
        if (token.text.len < 3 or token.text.len % 2 == 0) return .{ .result = .error_ };
        const owned = allocator.alloc(u8, (token.text.len - 3) / 2) catch return .{ .result = .no_memory };
        for (owned, 0..) |*byte, index| {
            byte.* = std.fmt.parseInt(u8, token.text[2 + index * 2 ..][0..2], 16) catch {
                allocator.free(owned);
                return .{ .result = .error_ };
            };
        }
        return .{ .result = .ok, .value = .{ .blob = owned }, .owned = owned };
    }
    return .{ .result = .error_ };
}

fn assignForeignKeyActionValue(database: *btree.Database, root_page: u32, column: ResolvedColumn, value: btree.Value, rowid: *i64, values: []btree.Value) ResultCode {
    if (column.integer_primary_key) {
        rowid.* = switch (value) {
            .null_ => blk: {
                const next = database.nextTableRowid(root_page);
                if (next.result != .ok) return next.result;
                break :blk next.rowid;
            },
            .integer => |integer| integer,
            else => return .mismatch,
        };
        return .ok;
    }
    if (column.record_index >= values.len) return .corrupt;
    values[column.record_index] = value;
    return .ok;
}

const IndexMutationRow = struct {
    rowid: i64,
    values: []const btree.Value,
};

fn registeredIndexCollation(connection: *Connection, name: []const u8) ?btree.IndexCollation {
    for (connection.collations.items) |collation| {
        if (collation.encoding & 7 == 1 and std.ascii.eqlIgnoreCase(collation.name, name)) {
            return .{ .custom = .{ .context = collation.auxiliary, .callback = collation.compare } };
        }
    }
    return null;
}

fn utf8CollationNameToUtf16(name: []const u8, output: []u16) ?usize {
    var source: usize = 0;
    var destination: usize = 0;
    while (source < name.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(name[source]) catch return null;
        if (source + sequence_length > name.len) return null;
        const codepoint: u21 = std.unicode.utf8Decode(name[source..][0..sequence_length]) catch return null;
        source += sequence_length;
        if (codepoint <= 0xffff) {
            if (codepoint >= 0xd800 and codepoint <= 0xdfff) return null;
            if (destination >= output.len) return null;
            output[destination] = @intCast(codepoint);
            destination += 1;
        } else {
            if (destination + 1 >= output.len) return null;
            const adjusted = codepoint - 0x10000;
            output[destination] = @intCast(0xd800 + (adjusted >> 10));
            output[destination + 1] = @intCast(0xdc00 + (adjusted & 0x3ff));
            destination += 2;
        }
    }
    return destination;
}

fn indexCollation(connection: *Connection, name: []const u8) ?btree.IndexCollation {
    if (std.ascii.eqlIgnoreCase(name, "BINARY")) return .binary;
    if (std.ascii.eqlIgnoreCase(name, "NOCASE")) return .nocase;
    if (std.ascii.eqlIgnoreCase(name, "RTRIM")) return .rtrim;
    if (registeredIndexCollation(connection, name)) |collation| return collation;
    if (connection.collation_needed_callback) |needed| {
        if (name.len > 255) return null;
        var terminated: [256]u8 = undefined;
        @memcpy(terminated[0..name.len], name);
        terminated[name.len] = 0;
        needed(connection.collation_needed_context, toOpaque(connection), 1, @ptrCast(&terminated));
    } else if (connection.collation_needed16_callback) |needed| {
        var terminated: [256]u16 = undefined;
        const length = utf8CollationNameToUtf16(name, terminated[0 .. terminated.len - 1]) orelse return null;
        terminated[length] = 0;
        needed(connection.collation_needed_context, toOpaque(connection), 1, @ptrCast(&terminated));
    }
    return registeredIndexCollation(connection, name);
}

const IndexIsSuffix = struct { is_not: bool, consumed: usize };

fn resolveIndexIsSuffix(token_list: []const Token, position: usize) IndexIsSuffix {
    if (position < token_list.len and token_list[position].typ == tokens.tk_not) {
        if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_distinct and token_list[position + 2].typ == tokens.tk_from) return .{ .is_not = false, .consumed = 3 };
        return .{ .is_not = true, .consumed = 1 };
    }
    if (position + 1 < token_list.len and token_list[position].typ == tokens.tk_distinct and token_list[position + 1].typ == tokens.tk_from) return .{ .is_not = true, .consumed = 2 };
    return .{ .is_not = false, .consumed = 0 };
}

fn resolveIndexPredicateFloat(token_list: []const Token, position: *usize) error{Syntax}!f64 {
    const negative = position.* < token_list.len and token_list[position.*].typ == tokens.tk_minus;
    if (position.* < token_list.len and (negative or token_list[position.*].typ == tokens.tk_plus)) {
        position.* += 1;
    }
    if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_float) return error.Syntax;
    var value = std.fmt.parseFloat(f64, token_list[position.*].text) catch return error.Syntax;
    if (negative) value = -value;
    position.* += 1;
    return value;
}

const IndexPredicateNumeric = union(enum) { integer: i64, real: f64 };

fn resolveIndexPredicateNumeric(token_list: []const Token, position: *usize) error{Syntax}!IndexPredicateNumeric {
    const literal_position = position.* + @intFromBool(position.* < token_list.len and (token_list[position.*].typ == tokens.tk_minus or token_list[position.*].typ == tokens.tk_plus));
    if (literal_position >= token_list.len) return error.Syntax;
    if (token_list[literal_position].typ == tokens.tk_float) return .{ .real = try resolveIndexPredicateFloat(token_list, position) };
    return .{ .integer = try resolveIndexPredicateInteger(token_list, position) };
}

fn indexPredicateNumericReal(numeric: IndexPredicateNumeric) f64 {
    return switch (numeric) {
        .integer => |integer| @floatFromInt(integer),
        .real => |real| real,
    };
}

fn resolveIndexPredicateInteger(token_list: []const Token, position: *usize) error{Syntax}!i64 {
    const negative = position.* < token_list.len and token_list[position.*].typ == tokens.tk_minus;
    if (position.* < token_list.len and (negative or token_list[position.*].typ == tokens.tk_plus)) {
        position.* += 1;
    }
    if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_integer) return error.Syntax;
    var value = std.fmt.parseInt(i64, token_list[position.*].text, 10) catch return error.Syntax;
    if (negative) value = -value;
    position.* += 1;
    return value;
}

fn resolveIndexPredicateTermInner(token_list: []const Token, columns: []const ResolvedColumn, position: *usize) error{Syntax}!btree.IndexPredicateTerm {
    if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_null) {
        position.* += 1;
        if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_is) return error.Syntax;
        position.* += 1;
        const is_suffix = resolveIndexIsSuffix(token_list, position.*);
        position.* += is_suffix.consumed;
        if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_id) return error.Syntax;
        var selected: ?usize = null;
        for (columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, token_list[position.*].text)) {
                selected = index;
                break;
            }
        }
        const column_index = selected orelse return error.Syntax;
        position.* += 1;
        return .{ .column_index = column_index, .integer_primary_key = columns[column_index].integer_primary_key, .operation = if (is_suffix.is_not) .is_not_null else .is_null };
    }
    if (position.* < token_list.len and (token_list[position.*].typ == tokens.tk_float or ((token_list[position.*].typ == tokens.tk_minus or token_list[position.*].typ == tokens.tk_plus) and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_float))) {
        const comparison_real = try resolveIndexPredicateFloat(token_list, position);
        if (position.* >= token_list.len) return error.Syntax;
        const is_suffix = if (token_list[position.*].typ == tokens.tk_is) resolveIndexIsSuffix(token_list, position.* + 1) else IndexIsSuffix{ .is_not = false, .consumed = 0 };
        const column_position = position.* + 1 + is_suffix.consumed;
        if (column_position >= token_list.len or token_list[column_position].typ != tokens.tk_id) return error.Syntax;
        const operation: btree.IndexPredicateOperation = switch (token_list[position.*].typ) {
            tokens.tk_eq => .real_eq,
            tokens.tk_ne => .real_ne,
            tokens.tk_lt => .real_gt,
            tokens.tk_le => .real_ge,
            tokens.tk_gt => .real_lt,
            tokens.tk_ge => .real_le,
            tokens.tk_is => if (is_suffix.is_not) .real_is_not else .real_is,
            else => return error.Syntax,
        };
        position.* = column_position;
        var selected: ?usize = null;
        for (columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, token_list[position.*].text)) {
                selected = index;
                break;
            }
        }
        const column_index = selected orelse return error.Syntax;
        if (!columns[column_index].integer_primary_key and !std.ascii.eqlIgnoreCase(columns[column_index].declared_type, "INTEGER")) return error.Syntax;
        position.* += 1;
        return .{ .column_index = column_index, .integer_primary_key = columns[column_index].integer_primary_key, .operation = operation, .comparison_real = comparison_real };
    }
    if (position.* < token_list.len and (token_list[position.*].typ == tokens.tk_integer or token_list[position.*].typ == tokens.tk_minus)) {
        const comparison_value = try resolveIndexPredicateInteger(token_list, position);
        if (position.* >= token_list.len) return error.Syntax;
        const is_suffix = if (token_list[position.*].typ == tokens.tk_is) resolveIndexIsSuffix(token_list, position.* + 1) else IndexIsSuffix{ .is_not = false, .consumed = 0 };
        const column_position = position.* + 1 + is_suffix.consumed;
        if (column_position >= token_list.len or token_list[column_position].typ != tokens.tk_id) return error.Syntax;
        const operation: btree.IndexPredicateOperation = switch (token_list[position.*].typ) {
            tokens.tk_eq => .integer_eq,
            tokens.tk_ne => .integer_ne,
            tokens.tk_lt => .integer_gt,
            tokens.tk_le => .integer_ge,
            tokens.tk_gt => .integer_lt,
            tokens.tk_ge => .integer_le,
            tokens.tk_is => if (is_suffix.is_not) .integer_is_not else .integer_is,
            else => return error.Syntax,
        };
        position.* = column_position;
        var selected: ?usize = null;
        for (columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, token_list[position.*].text)) {
                selected = index;
                break;
            }
        }
        const column_index = selected orelse return error.Syntax;
        if (!columns[column_index].integer_primary_key and !std.ascii.eqlIgnoreCase(columns[column_index].declared_type, "INTEGER")) return error.Syntax;
        position.* += 1;
        return .{ .column_index = column_index, .integer_primary_key = columns[column_index].integer_primary_key, .operation = operation, .comparison_value = comparison_value };
    }
    if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_string) {
        const comparison_text = token_list[position.*].text;
        position.* += 1;
        var literal_collation: ?btree.IndexPredicateTextCollation = null;
        if (position.* + 1 < token_list.len and token_list[position.*].typ == tokens.tk_collate) {
            const explicit_name = token_list[position.* + 1].text;
            literal_collation = if (std.ascii.eqlIgnoreCase(explicit_name, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(explicit_name, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(explicit_name, "RTRIM")) .rtrim else return error.Syntax;
            position.* += 2;
        }
        if (position.* >= token_list.len) return error.Syntax;
        const is_suffix = if (token_list[position.*].typ == tokens.tk_is) resolveIndexIsSuffix(token_list, position.* + 1) else IndexIsSuffix{ .is_not = false, .consumed = 0 };
        const column_position = position.* + 1 + is_suffix.consumed;
        if (column_position >= token_list.len or token_list[column_position].typ != tokens.tk_id) return error.Syntax;
        const operation: btree.IndexPredicateOperation = switch (token_list[position.*].typ) {
            tokens.tk_eq => .text_eq,
            tokens.tk_ne => .text_ne,
            tokens.tk_lt => .text_gt,
            tokens.tk_le => .text_ge,
            tokens.tk_gt => .text_lt,
            tokens.tk_ge => .text_le,
            tokens.tk_is => if (is_suffix.is_not) .text_is_not else .text_is,
            else => return error.Syntax,
        };
        position.* = column_position;
        var selected: ?usize = null;
        for (columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, token_list[position.*].text)) {
                selected = index;
                break;
            }
        }
        const column_index = selected orelse return error.Syntax;
        var text_collation: ?btree.IndexPredicateTextCollation = literal_collation orelse if (std.ascii.eqlIgnoreCase(columns[column_index].collation, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(columns[column_index].collation, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(columns[column_index].collation, "RTRIM")) .rtrim else null;
        if (!std.ascii.eqlIgnoreCase(columns[column_index].declared_type, "TEXT") or text_collation == null) return error.Syntax;
        position.* += 1;
        if (position.* + 1 < token_list.len and token_list[position.*].typ == tokens.tk_collate) {
            const explicit_name = token_list[position.* + 1].text;
            const column_collation: btree.IndexPredicateTextCollation = if (std.ascii.eqlIgnoreCase(explicit_name, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(explicit_name, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(explicit_name, "RTRIM")) .rtrim else return error.Syntax;
            if (literal_collation == null) {
                text_collation = column_collation;
            }
            position.* += 2;
        }
        return .{ .column_index = column_index, .integer_primary_key = false, .operation = operation, .comparison_text = comparison_text, .text_collation = text_collation.? };
    }
    var boolean_negated = false;
    if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_not) {
        boolean_negated = true;
        position.* += 1;
    }
    if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_id) return error.Syntax;
    var column_index: ?usize = null;
    for (columns, 0..) |column, index| {
        if (std.ascii.eqlIgnoreCase(column.name, token_list[position.*].text)) {
            column_index = index;
            break;
        }
    }
    const selected = column_index orelse return error.Syntax;
    position.* += 1;
    const integer_column = columns[selected].integer_primary_key or std.ascii.eqlIgnoreCase(columns[selected].declared_type, "INTEGER");
    const text_column = std.ascii.eqlIgnoreCase(columns[selected].declared_type, "TEXT");
    var text_collation: ?btree.IndexPredicateTextCollation = if (std.ascii.eqlIgnoreCase(columns[selected].collation, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(columns[selected].collation, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(columns[selected].collation, "RTRIM")) .rtrim else null;
    var explicit_column_collation = false;
    if (text_column and position.* + 1 < token_list.len and token_list[position.*].typ == tokens.tk_collate) {
        const explicit_name = token_list[position.* + 1].text;
        text_collation = if (std.ascii.eqlIgnoreCase(explicit_name, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(explicit_name, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(explicit_name, "RTRIM")) .rtrim else return error.Syntax;
        explicit_column_collation = true;
        position.* += 2;
    }
    if (position.* < token_list.len and (token_list[position.*].typ == tokens.tk_isnull or token_list[position.*].typ == tokens.tk_notnull)) {
        const is_not_null = token_list[position.*].typ == tokens.tk_notnull;
        position.* += 1;
        return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (is_not_null) .is_not_null else .is_null };
    }
    const text_not_between = position.* < token_list.len and token_list[position.*].typ == tokens.tk_not and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_between;
    if (!boolean_negated and text_column and text_collation != null and position.* < token_list.len and (token_list[position.*].typ == tokens.tk_between or text_not_between)) {
        position.* += if (text_not_between) 2 else 1;
        if (position.* + 2 >= token_list.len or token_list[position.*].typ != tokens.tk_string or token_list[position.* + 1].typ != tokens.tk_and or token_list[position.* + 2].typ != tokens.tk_string) return error.Syntax;
        const low_text = token_list[position.*].text;
        const high_text = token_list[position.* + 2].text;
        position.* += 3;
        return .{ .column_index = selected, .integer_primary_key = false, .operation = if (text_not_between) .text_not_between else .text_between, .comparison_text = low_text, .comparison_text_high = high_text, .text_collation = text_collation.? };
    }
    const text_not_in = position.* < token_list.len and token_list[position.*].typ == tokens.tk_not and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_in;
    if (!boolean_negated and text_column and text_collation != null and position.* < token_list.len and (token_list[position.*].typ == tokens.tk_in or text_not_in)) {
        position.* += if (text_not_in) 2 else 1;
        if (position.* + 4 >= token_list.len or token_list[position.*].typ != tokens.tk_lp or token_list[position.* + 1].typ != tokens.tk_string or token_list[position.* + 2].typ != tokens.tk_comma or token_list[position.* + 3].typ != tokens.tk_string or token_list[position.* + 4].typ != tokens.tk_rp) return error.Syntax;
        const first_text = token_list[position.* + 1].text;
        const second_text = token_list[position.* + 3].text;
        position.* += 5;
        return .{ .column_index = selected, .integer_primary_key = false, .operation = if (text_not_in) .text_not_in else .text_in, .comparison_text = first_text, .comparison_text_high = second_text, .text_collation = text_collation.? };
    }
    if (!boolean_negated and text_column and text_collation != null and position.* + 1 < token_list.len and (token_list[position.*].typ == tokens.tk_eq or token_list[position.*].typ == tokens.tk_ne or token_list[position.*].typ == tokens.tk_lt or token_list[position.*].typ == tokens.tk_le or token_list[position.*].typ == tokens.tk_gt or token_list[position.*].typ == tokens.tk_ge) and token_list[position.* + 1].typ == tokens.tk_string) {
        const operation: btree.IndexPredicateOperation = switch (token_list[position.*].typ) {
            tokens.tk_eq => .text_eq,
            tokens.tk_ne => .text_ne,
            tokens.tk_lt => .text_lt,
            tokens.tk_le => .text_le,
            tokens.tk_gt => .text_gt,
            tokens.tk_ge => .text_ge,
            else => unreachable,
        };
        const comparison_text = token_list[position.* + 1].text;
        position.* += 2;
        if (position.* + 1 < token_list.len and token_list[position.*].typ == tokens.tk_collate) {
            const explicit_name = token_list[position.* + 1].text;
            const literal_collation: btree.IndexPredicateTextCollation = if (std.ascii.eqlIgnoreCase(explicit_name, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(explicit_name, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(explicit_name, "RTRIM")) .rtrim else return error.Syntax;
            if (!explicit_column_collation) {
                text_collation = literal_collation;
            }
            position.* += 2;
        }
        return .{ .column_index = selected, .integer_primary_key = false, .operation = operation, .comparison_text = comparison_text, .text_collation = text_collation.? };
    }
    if (integer_column and (position.* == token_list.len or token_list[position.*].typ == tokens.tk_and or token_list[position.*].typ == tokens.tk_or or token_list[position.*].typ == tokens.tk_rp)) {
        return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (boolean_negated) .integer_eq else .integer_ne, .comparison_value = 0 };
    }
    if (boolean_negated or position.* >= token_list.len) return error.Syntax;
    if (integer_column and position.* + 1 < token_list.len and (token_list[position.*].typ == tokens.tk_eq or token_list[position.*].typ == tokens.tk_ne or token_list[position.*].typ == tokens.tk_lt or token_list[position.*].typ == tokens.tk_le or token_list[position.*].typ == tokens.tk_gt or token_list[position.*].typ == tokens.tk_ge) and (token_list[position.* + 1].typ == tokens.tk_float or ((token_list[position.* + 1].typ == tokens.tk_minus or token_list[position.* + 1].typ == tokens.tk_plus) and position.* + 2 < token_list.len and token_list[position.* + 2].typ == tokens.tk_float))) {
        const operation: btree.IndexPredicateOperation = switch (token_list[position.*].typ) {
            tokens.tk_eq => .real_eq,
            tokens.tk_ne => .real_ne,
            tokens.tk_lt => .real_lt,
            tokens.tk_le => .real_le,
            tokens.tk_gt => .real_gt,
            tokens.tk_ge => .real_ge,
            else => unreachable,
        };
        position.* += 1;
        const comparison_real = try resolveIndexPredicateFloat(token_list, position);
        return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = operation, .comparison_real = comparison_real };
    }
    var operation: btree.IndexPredicateOperation = undefined;
    var comparison_value: i64 = 0;
    if (token_list[position.*].typ == tokens.tk_is) {
        position.* += 1;
        const is_suffix = resolveIndexIsSuffix(token_list, position.*);
        const is_not = is_suffix.is_not;
        position.* += is_suffix.consumed;
        if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_null) {
            operation = if (is_not) .is_not_null else .is_null;
            position.* += 1;
        } else if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_string and text_column and text_collation != null) {
            const comparison_text = token_list[position.*].text;
            position.* += 1;
            if (position.* + 1 < token_list.len and token_list[position.*].typ == tokens.tk_collate) {
                const explicit_name = token_list[position.* + 1].text;
                const literal_collation: btree.IndexPredicateTextCollation = if (std.ascii.eqlIgnoreCase(explicit_name, "BINARY")) .binary else if (std.ascii.eqlIgnoreCase(explicit_name, "NOCASE")) .nocase else if (std.ascii.eqlIgnoreCase(explicit_name, "RTRIM")) .rtrim else return error.Syntax;
                if (!explicit_column_collation) {
                    text_collation = literal_collation;
                }
                position.* += 2;
            }
            return .{ .column_index = selected, .integer_primary_key = false, .operation = if (is_not) .text_is_not else .text_is, .comparison_text = comparison_text, .text_collation = text_collation.? };
        } else if (integer_column and position.* < token_list.len and (token_list[position.*].typ == tokens.tk_float or ((token_list[position.*].typ == tokens.tk_minus or token_list[position.*].typ == tokens.tk_plus) and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_float))) {
            const comparison_real = try resolveIndexPredicateFloat(token_list, position);
            return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (is_not) .real_is_not else .real_is, .comparison_real = comparison_real };
        } else {
            if (!integer_column) return error.Syntax;
            operation = if (is_not) .integer_is_not else .integer_is;
            comparison_value = try resolveIndexPredicateInteger(token_list, position);
        }
    } else {
        if (!integer_column) return error.Syntax;
        const not_in = token_list[position.*].typ == tokens.tk_not and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_in;
        if (token_list[position.*].typ == tokens.tk_in or not_in) {
            position.* += if (not_in) 2 else 1;
            if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_lp) return error.Syntax;
            position.* += 1;
            const first_numeric = try resolveIndexPredicateNumeric(token_list, position);
            if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_comma) return error.Syntax;
            position.* += 1;
            const second_numeric = try resolveIndexPredicateNumeric(token_list, position);
            if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_rp) return error.Syntax;
            position.* += 1;
            const have_real = switch (first_numeric) {
                .real => true,
                .integer => false,
            } or switch (second_numeric) {
                .real => true,
                .integer => false,
            };
            if (have_real) {
                return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (not_in) .real_not_in else .real_in, .comparison_real = indexPredicateNumericReal(first_numeric), .comparison_real_high = indexPredicateNumericReal(second_numeric) };
            }
            return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (not_in) .integer_not_in else .integer_in, .comparison_value = first_numeric.integer, .comparison_value_high = second_numeric.integer };
        }
        const not_between = token_list[position.*].typ == tokens.tk_not and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_between;
        if (token_list[position.*].typ == tokens.tk_between or not_between) {
            position.* += if (not_between) 2 else 1;
            const low_numeric = try resolveIndexPredicateNumeric(token_list, position);
            if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_and) return error.Syntax;
            position.* += 1;
            const high_numeric = try resolveIndexPredicateNumeric(token_list, position);
            const have_real = switch (low_numeric) {
                .real => true,
                .integer => false,
            } or switch (high_numeric) {
                .real => true,
                .integer => false,
            };
            if (have_real) {
                return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (not_between) .real_not_between else .real_between, .comparison_real = indexPredicateNumericReal(low_numeric), .comparison_real_high = indexPredicateNumericReal(high_numeric) };
            }
            return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = if (not_between) .integer_not_between else .integer_between, .comparison_value = low_numeric.integer, .comparison_value_high = high_numeric.integer };
        }
        operation = switch (token_list[position.*].typ) {
            tokens.tk_eq => .integer_eq,
            tokens.tk_ne => .integer_ne,
            tokens.tk_lt => .integer_lt,
            tokens.tk_le => .integer_le,
            tokens.tk_gt => .integer_gt,
            tokens.tk_ge => .integer_ge,
            else => return error.Syntax,
        };
        position.* += 1;
        comparison_value = try resolveIndexPredicateInteger(token_list, position);
    }
    return .{ .column_index = selected, .integer_primary_key = columns[selected].integer_primary_key, .operation = operation, .comparison_value = comparison_value };
}

const IndexPredicateParseError = error{Syntax};

fn resolveNullComparisonPredicate(token_list: []const Token, columns: []const ResolvedColumn, position: usize) ?usize {
    if (position + 2 >= token_list.len) return null;
    const null_first = token_list[position].typ == tokens.tk_null;
    const column_position = if (null_first) position + 2 else position;
    const null_position = if (null_first) position else position + 2;
    if (token_list[column_position].typ != tokens.tk_id or token_list[null_position].typ != tokens.tk_null) return null;
    const operation_position = position + 1;
    switch (token_list[operation_position].typ) {
        tokens.tk_eq, tokens.tk_ne, tokens.tk_lt, tokens.tk_le, tokens.tk_gt, tokens.tk_ge => {},
        else => return null,
    }
    for (columns) |column| {
        if (std.ascii.eqlIgnoreCase(column.name, token_list[column_position].text)) return 3;
    }
    return null;
}

fn appendIndexPredicateNode(predicate: *btree.IndexPredicate, node_count: *usize, node: btree.IndexPredicateNode) IndexPredicateParseError!void {
    if (node_count.* == predicate.nodes.len) return error.Syntax;
    predicate.nodes[node_count.*] = node;
    node_count.* += 1;
}

fn resolveIndexPredicatePrimary(token_list: []const Token, columns: []const ResolvedColumn, position: *usize, predicate: *btree.IndexPredicate, node_count: *usize, term_count: *usize) IndexPredicateParseError!void {
    if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_not) {
        position.* += 1;
        try resolveIndexPredicatePrimary(token_list, columns, position, predicate, node_count, term_count);
        try appendIndexPredicateNode(predicate, node_count, .not_);
        return;
    }
    if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_lp) {
        position.* += 1;
        try resolveIndexPredicateOr(token_list, columns, position, predicate, node_count, term_count);
        if (position.* >= token_list.len or token_list[position.*].typ != tokens.tk_rp) return error.Syntax;
        position.* += 1;
        return;
    }
    if (term_count.* == 8) return error.Syntax;
    if (resolveNullComparisonPredicate(token_list, columns, position.*)) |consumed| {
        position.* += consumed;
        try appendIndexPredicateNode(predicate, node_count, .{ .constant = .null_ });
        term_count.* += 1;
        return;
    }
    if (position.* < token_list.len and (token_list[position.*].typ == tokens.tk_float or ((token_list[position.*].typ == tokens.tk_minus or token_list[position.*].typ == tokens.tk_plus) and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_float))) {
        const negative = token_list[position.*].typ == tokens.tk_minus;
        const signed = negative or token_list[position.*].typ == tokens.tk_plus;
        const literal_position = position.* + @intFromBool(signed);
        const probe_position = literal_position + 1;
        if (probe_position == token_list.len or token_list[probe_position].typ == tokens.tk_and or token_list[probe_position].typ == tokens.tk_or or token_list[probe_position].typ == tokens.tk_rp) {
            var constant = std.fmt.parseFloat(f64, token_list[literal_position].text) catch return error.Syntax;
            if (negative) constant = -constant;
            position.* = probe_position;
            try appendIndexPredicateNode(predicate, node_count, .{ .constant = if (constant != 0 and !std.math.isNan(constant)) .true_ else .false_ });
            term_count.* += 1;
            return;
        }
    }
    if (position.* < token_list.len and (token_list[position.*].typ == tokens.tk_integer or ((token_list[position.*].typ == tokens.tk_minus or token_list[position.*].typ == tokens.tk_plus) and position.* + 1 < token_list.len and token_list[position.* + 1].typ == tokens.tk_integer))) {
        var probe_position = position.*;
        const constant = try resolveIndexPredicateInteger(token_list, &probe_position);
        if (probe_position == token_list.len or token_list[probe_position].typ == tokens.tk_and or token_list[probe_position].typ == tokens.tk_or or token_list[probe_position].typ == tokens.tk_rp) {
            position.* = probe_position;
            try appendIndexPredicateNode(predicate, node_count, .{ .constant = if (constant != 0) .true_ else .false_ });
            term_count.* += 1;
            return;
        }
    }
    if (position.* < token_list.len and token_list[position.*].typ == tokens.tk_null and (position.* + 1 == token_list.len or token_list[position.* + 1].typ == tokens.tk_and or token_list[position.* + 1].typ == tokens.tk_or or token_list[position.* + 1].typ == tokens.tk_rp)) {
        position.* += 1;
        try appendIndexPredicateNode(predicate, node_count, .{ .constant = .null_ });
        term_count.* += 1;
        return;
    }
    const term = try resolveIndexPredicateTermInner(token_list, columns, position);
    try appendIndexPredicateNode(predicate, node_count, .{ .term = term });
    term_count.* += 1;
}

fn resolveIndexPredicateAnd(token_list: []const Token, columns: []const ResolvedColumn, position: *usize, predicate: *btree.IndexPredicate, node_count: *usize, term_count: *usize) IndexPredicateParseError!void {
    try resolveIndexPredicatePrimary(token_list, columns, position, predicate, node_count, term_count);
    while (position.* < token_list.len and token_list[position.*].typ == tokens.tk_and) {
        position.* += 1;
        try resolveIndexPredicatePrimary(token_list, columns, position, predicate, node_count, term_count);
        try appendIndexPredicateNode(predicate, node_count, .and_);
    }
}

fn resolveIndexPredicateOr(token_list: []const Token, columns: []const ResolvedColumn, position: *usize, predicate: *btree.IndexPredicate, node_count: *usize, term_count: *usize) IndexPredicateParseError!void {
    try resolveIndexPredicateAnd(token_list, columns, position, predicate, node_count, term_count);
    while (position.* < token_list.len and token_list[position.*].typ == tokens.tk_or) {
        position.* += 1;
        try resolveIndexPredicateAnd(token_list, columns, position, predicate, node_count, term_count);
        try appendIndexPredicateNode(predicate, node_count, .or_);
    }
}

fn resolveIndexPredicate(token_list: []const Token, columns: []const ResolvedColumn) IndexPredicateParseError!?btree.IndexPredicate {
    var position: usize = 0;
    while (position < token_list.len and token_list[position].typ != tokens.tk_where) : (position += 1) {}
    if (position == token_list.len) return null;
    position += 1;
    var predicate = btree.IndexPredicate{};
    var node_count: usize = 0;
    var term_count: usize = 0;
    try resolveIndexPredicateOr(token_list, columns, &position, &predicate, &node_count, &term_count);
    if (position != token_list.len or term_count == 0) return error.Syntax;
    return predicate;
}

fn indexPredicateRowMatches(predicate: ?btree.IndexPredicate, row: IndexMutationRow) error{Corrupt}!bool {
    const filter = predicate orelse return true;
    return btree.indexPredicateRecordMatches(filter, row.values, row.rowid) orelse error.Corrupt;
}

/// Bounded source `sqlite3GenerateIndexKey()` mutation owner for ordinary
/// indexes created by `compileIndexSchema()`.
fn maintainSecondaryIndexes(connection: *Connection, database: *btree.Database, table_name: []const u8, old_row: ?IndexMutationRow, new_row: ?IndexMutationRow) ResultCode {
    const table_outcome = database.schemaTable(table_name);
    if (table_outcome.result != .ok) return table_outcome.result;
    var table = table_outcome.table.?;
    defer table.deinit();
    const table_columns = resolveColumns(connection.allocator, table.sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    defer {
        connection.allocator.free(table_columns.columns);
        connection.allocator.free(table_columns.tokens);
        connection.allocator.free(table_columns.source);
    }
    const schema_outcome = database.openCursor(1, .table);
    if (schema_outcome.result != .ok) return schema_outcome.result;
    var schema_cursor = schema_outcome.cursor.?;
    defer schema_cursor.deinit();
    for (schema_cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return decoded.result;
        var schema_record = decoded.record.?;
        defer schema_record.deinit();
        if (schema_record.values.len < 5) continue;
        const object_type = schemaEntryText(schema_record.values[0]) orelse continue;
        const indexed_table = schemaEntryText(schema_record.values[2]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index") or !std.ascii.eqlIgnoreCase(indexed_table, table_name)) continue;
        const root_page = schemaEntryRoot(schema_record.values[3]) orelse return .corrupt;
        const index_sql = schemaEntryText(schema_record.values[4]) orelse continue;
        const index_columns = resolveColumns(connection.allocator, index_sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
        defer {
            connection.allocator.free(index_columns.columns);
            connection.allocator.free(index_columns.tokens);
            connection.allocator.free(index_columns.source);
        }
        if (index_columns.columns.len == 0) continue;
        const predicate = resolveIndexPredicate(index_columns.tokens, table_columns.columns) catch return .corrupt;
        const unique = index_columns.tokens.len > 1 and index_columns.tokens[0].typ == tokens.tk_create and index_columns.tokens[1].typ == tokens.tk_unique;
        const selected = connection.allocator.alloc(usize, index_columns.columns.len) catch return .no_memory;
        defer connection.allocator.free(selected);
        const selected_collations = connection.allocator.alloc(btree.IndexCollation, index_columns.columns.len) catch return .no_memory;
        defer connection.allocator.free(selected_collations);
        const selected_sort_orders = connection.allocator.alloc(btree.IndexSortOrder, index_columns.columns.len) catch return .no_memory;
        defer connection.allocator.free(selected_sort_orders);
        const selected_transforms = connection.allocator.alloc(btree.IndexTransform, index_columns.columns.len) catch return .no_memory;
        defer connection.allocator.free(selected_transforms);
        var integer_primary_key_position: ?usize = null;
        for (index_columns.columns, 0..) |index_column, selected_position| {
            var found: ?usize = null;
            for (table_columns.columns, 0..) |column, index| {
                if (std.ascii.eqlIgnoreCase(column.name, index_column.name)) {
                    found = index;
                    if (column.integer_primary_key) integer_primary_key_position = selected_position;
                    break;
                }
            }
            selected[selected_position] = found orelse return .corrupt;
            const table_column = table_columns.columns[selected[selected_position]];
            const collation_name = if (index_column.explicit_collation) index_column.collation else table_column.collation;
            selected_collations[selected_position] = indexCollation(connection, collation_name) orelse return .error_;
            selected_sort_orders[selected_position] = if (index_column.descending) .descending else .ascending;
            selected_transforms[selected_position] = index_column.index_transform;
        }
        if (old_row) |row| {
            const matches = indexPredicateRowMatches(predicate, row) catch return .corrupt;
            if (matches) {
                const key_values = connection.allocator.alloc(btree.Value, selected.len + 1) catch return .no_memory;
                defer connection.allocator.free(key_values);
                for (selected, 0..) |column_index, index| {
                    if (column_index >= row.values.len) return .corrupt;
                    key_values[index] = btree.transformIndexValue(selected_transforms[index], if (integer_primary_key_position == index) .{ .integer = row.rowid } else row.values[column_index]);
                }
                key_values[selected.len] = .{ .integer = row.rowid };
                const payload = btree.encodeRecord(connection.allocator, key_values) catch |err| return if (err == error.OutOfMemory) .no_memory else .too_big;
                defer connection.allocator.free(payload);
                const deleted = database.deleteIndex(root_page, payload);
                if (deleted != .ok) return if (deleted == .not_found) .corrupt else deleted;
            }
        }
        if (new_row) |row| {
            const matches = indexPredicateRowMatches(predicate, row) catch return .corrupt;
            if (matches) {
                const key_values = connection.allocator.alloc(btree.Value, selected.len + 1) catch return .no_memory;
                defer connection.allocator.free(key_values);
                for (selected, 0..) |column_index, index| {
                    if (column_index >= row.values.len) return .corrupt;
                    key_values[index] = btree.transformIndexValue(selected_transforms[index], if (integer_primary_key_position == index) .{ .integer = row.rowid } else row.values[column_index]);
                }
                key_values[selected.len] = .{ .integer = row.rowid };
                const payload = btree.encodeRecord(connection.allocator, key_values) catch |err| return if (err == error.OutOfMemory) .no_memory else .too_big;
                defer connection.allocator.free(payload);
                const inserted = if (unique) database.insertUniqueIndexWithKeyInfo(root_page, payload, selected.len, selected_collations, selected_sort_orders) else database.insertIndexWithKeyInfo(root_page, payload, selected_collations, selected_sort_orders);
                if (inserted != .ok) return inserted;
            }
        }
    }
    return .ok;
}

fn reindexSecondaryIndex(connection: *Connection, database: *btree.Database, name: []const u8) ResultCode {
    const index_outcome = database.schemaIndex(name);
    if (index_outcome.result != .ok) return index_outcome.result;
    var index_schema = index_outcome.table.?;
    defer index_schema.deinit();
    const index_columns = resolveColumns(connection.allocator, index_schema.sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    defer {
        connection.allocator.free(index_columns.columns);
        connection.allocator.free(index_columns.tokens);
        connection.allocator.free(index_columns.source);
    }
    var on_position: usize = 0;
    while (on_position < index_columns.tokens.len and index_columns.tokens[on_position].typ != tokens.tk_on) : (on_position += 1) {}
    if (on_position + 1 >= index_columns.tokens.len or index_columns.tokens[on_position + 1].typ != tokens.tk_id) return .corrupt;
    const table_name = index_columns.tokens[on_position + 1].text;
    const table_outcome = database.schemaTable(table_name);
    if (table_outcome.result != .ok) return table_outcome.result;
    var table = table_outcome.table.?;
    defer table.deinit();
    const table_columns = resolveColumns(connection.allocator, table.sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    defer {
        connection.allocator.free(table_columns.columns);
        connection.allocator.free(table_columns.tokens);
        connection.allocator.free(table_columns.source);
    }
    const selected = connection.allocator.alloc(usize, index_columns.columns.len) catch return .no_memory;
    defer connection.allocator.free(selected);
    const collations = connection.allocator.alloc(btree.IndexCollation, index_columns.columns.len) catch return .no_memory;
    defer connection.allocator.free(collations);
    const sort_orders = connection.allocator.alloc(btree.IndexSortOrder, index_columns.columns.len) catch return .no_memory;
    defer connection.allocator.free(sort_orders);
    const transforms = connection.allocator.alloc(btree.IndexTransform, index_columns.columns.len) catch return .no_memory;
    defer connection.allocator.free(transforms);
    var integer_primary_key_position: ?usize = null;
    for (index_columns.columns, 0..) |index_column, selected_position| {
        const column_index = resolvedColumnIndex(table_columns.columns, index_column.name) orelse return .corrupt;
        selected[selected_position] = column_index;
        const table_column = table_columns.columns[column_index];
        if (table_column.integer_primary_key) integer_primary_key_position = selected_position;
        const collation_name = if (index_column.explicit_collation) index_column.collation else table_column.collation;
        collations[selected_position] = indexCollation(connection, collation_name) orelse return .error_;
        sort_orders[selected_position] = if (index_column.descending) .descending else .ascending;
        transforms[selected_position] = index_column.index_transform;
    }
    const predicate = resolveIndexPredicate(index_columns.tokens, table_columns.columns) catch return .corrupt;
    const unique = index_columns.tokens.len > 1 and index_columns.tokens[1].typ == tokens.tk_unique;
    return database.refillSchemaIndex(index_schema.root_page, table.root_page, selected, integer_primary_key_position, collations, sort_orders, transforms, predicate, unique);
}

fn reindexTableIndexes(connection: *Connection, database: *btree.Database, table_name: []const u8) ResultCode {
    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    var matched = false;
    for (cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return decoded.result;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len < 3) continue;
        const object_type = schemaEntryText(record.values[0]) orelse continue;
        const name = schemaEntryText(record.values[1]) orelse continue;
        const owner = schemaEntryText(record.values[2]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index") or !std.ascii.eqlIgnoreCase(owner, table_name)) continue;
        const refilled = reindexSecondaryIndex(connection, database, name);
        if (refilled != .ok) return refilled;
        matched = true;
    }
    return if (matched) .ok else .error_;
}

const IndexCollationMatchOutcome = struct { result: ResultCode, matches: bool = false };

fn indexSchemaUsesCollation(connection: *Connection, database: *btree.Database, sql: []const u8, wanted: []const u8) IndexCollationMatchOutcome {
    const index_columns = resolveColumns(connection.allocator, sql) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .corrupt };
    defer {
        connection.allocator.free(index_columns.columns);
        connection.allocator.free(index_columns.tokens);
        connection.allocator.free(index_columns.source);
    }
    var on_position: usize = 0;
    while (on_position < index_columns.tokens.len and index_columns.tokens[on_position].typ != tokens.tk_on) : (on_position += 1) {}
    if (on_position + 1 >= index_columns.tokens.len or index_columns.tokens[on_position + 1].typ != tokens.tk_id) return .{ .result = .corrupt };
    const table_outcome = database.schemaTable(index_columns.tokens[on_position + 1].text);
    if (table_outcome.result != .ok) return .{ .result = table_outcome.result };
    var table = table_outcome.table.?;
    defer table.deinit();
    const table_columns = resolveColumns(connection.allocator, table.sql) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .corrupt };
    defer {
        connection.allocator.free(table_columns.columns);
        connection.allocator.free(table_columns.tokens);
        connection.allocator.free(table_columns.source);
    }
    for (index_columns.columns) |index_column| {
        const column_index = resolvedColumnIndex(table_columns.columns, index_column.name) orelse return .{ .result = .corrupt };
        const effective = if (index_column.explicit_collation) index_column.collation else table_columns.columns[column_index].collation;
        if (std.ascii.eqlIgnoreCase(effective, wanted)) return .{ .result = .ok, .matches = true };
    }
    return .{ .result = .ok };
}

fn reindexCollationDatabase(connection: *Connection, database: *btree.Database, collation_name: []const u8) ResultCode {
    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    for (cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return decoded.result;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len < 5) continue;
        const object_type = schemaEntryText(record.values[0]) orelse continue;
        const name = schemaEntryText(record.values[1]) orelse continue;
        const sql = schemaEntryText(record.values[4]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index")) continue;
        const matches = indexSchemaUsesCollation(connection, database, sql, collation_name);
        if (matches.result != .ok) return matches.result;
        if (!matches.matches) continue;
        const refilled = reindexSecondaryIndex(connection, database, name);
        if (refilled != .ok) return refilled;
    }
    return .ok;
}

fn reindexAllDatabase(connection: *Connection, database: *btree.Database) ResultCode {
    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    for (cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return decoded.result;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len < 2) continue;
        const object_type = schemaEntryText(record.values[0]) orelse continue;
        const name = schemaEntryText(record.values[1]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index")) continue;
        const refilled = reindexSecondaryIndex(connection, database, name);
        if (refilled != .ok) return refilled;
    }
    return .ok;
}

fn reindexExpressionDatabase(connection: *Connection, database: *btree.Database) ResultCode {
    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    for (cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return decoded.result;
        var record = decoded.record.?;
        defer record.deinit();
        if (record.values.len < 5) continue;
        const object_type = schemaEntryText(record.values[0]) orelse continue;
        const name = schemaEntryText(record.values[1]) orelse continue;
        const sql = schemaEntryText(record.values[4]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(object_type, "index")) continue;
        const columns = resolveColumns(connection.allocator, sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .corrupt;
        defer {
            connection.allocator.free(columns.columns);
            connection.allocator.free(columns.tokens);
            connection.allocator.free(columns.source);
        }
        var expression = false;
        for (columns.columns) |column| {
            if (column.scan_expression) {
                expression = true;
                break;
            }
        }
        if (!expression) continue;
        const refilled = reindexSecondaryIndex(connection, database, name);
        if (refilled != .ok) return refilled;
    }
    return .ok;
}

fn reindexCollationInDatabase(connection: *Connection, database: *btree.Database, name: []const u8) ResultCode {
    const enlisted = enlistTransactionDatabase(connection, database);
    if (enlisted != .ok) return enlisted;
    const begun = database.beginStatementBatch();
    if (begun != .ok) return begun;
    var batch_active = true;
    defer if (batch_active) {
        _ = database.rollbackStatementBatch();
    };
    const refilled = reindexCollationDatabase(connection, database, name);
    if (refilled != .ok) return refilled;
    const committed = database.commitStatementBatch();
    batch_active = false;
    return committed;
}

fn reindexCollationConnection(connection: *Connection, name: []const u8) ResultCode {
    if (connection.database) |database| {
        const result = reindexCollationInDatabase(connection, database, name);
        if (result != .ok) return result;
    }
    if (connection.temp_database) |temporary| {
        if (temporary.database) |*database| {
            const result = reindexCollationInDatabase(connection, database, name);
            if (result != .ok) return result;
        }
    }
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |attached| {
            const located = locateDatabase(connection, attached.name);
            if (located.result != .ok) return located.result;
            const result = reindexCollationInDatabase(connection, located.database.?, name);
            if (result != .ok) return result;
        }
    }
    return .ok;
}

fn reindexAllInDatabase(connection: *Connection, database: *btree.Database) ResultCode {
    const enlisted = enlistTransactionDatabase(connection, database);
    if (enlisted != .ok) return enlisted;
    const begun = database.beginStatementBatch();
    if (begun != .ok) return begun;
    var batch_active = true;
    defer if (batch_active) {
        _ = database.rollbackStatementBatch();
    };
    const refilled = reindexAllDatabase(connection, database);
    if (refilled != .ok) return refilled;
    const committed = database.commitStatementBatch();
    batch_active = false;
    return committed;
}

fn reindexAllConnection(connection: *Connection) ResultCode {
    if (connection.database) |database| {
        const result = reindexAllInDatabase(connection, database);
        if (result != .ok) return result;
    }
    if (connection.temp_database) |temporary| {
        if (temporary.database) |*database| {
            const result = reindexAllInDatabase(connection, database);
            if (result != .ok) return result;
        }
    }
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |attached| {
            const located = locateDatabase(connection, attached.name);
            if (located.result != .ok) return located.result;
            const result = reindexAllInDatabase(connection, located.database.?);
            if (result != .ok) return result;
        }
    }
    return .ok;
}

fn reindexExpressionsInDatabase(connection: *Connection, database: *btree.Database) ResultCode {
    const enlisted = enlistTransactionDatabase(connection, database);
    if (enlisted != .ok) return enlisted;
    const begun = database.beginStatementBatch();
    if (begun != .ok) return begun;
    var batch_active = true;
    defer if (batch_active) {
        _ = database.rollbackStatementBatch();
    };
    const refilled = reindexExpressionDatabase(connection, database);
    if (refilled != .ok) return refilled;
    const committed = database.commitStatementBatch();
    batch_active = false;
    return committed;
}

fn reindexExpressionsConnection(connection: *Connection) ResultCode {
    if (connection.database) |database| {
        const result = reindexExpressionsInDatabase(connection, database);
        if (result != .ok) return result;
    }
    if (connection.temp_database) |temporary| {
        if (temporary.database) |*database| {
            const result = reindexExpressionsInDatabase(connection, database);
            if (result != .ok) return result;
        }
    }
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |attached| {
            const located = locateDatabase(connection, attached.name);
            if (located.result != .ok) return located.result;
            const result = reindexExpressionsInDatabase(connection, located.database.?);
            if (result != .ok) return result;
        }
    }
    return .ok;
}

fn clearForeignKeyActionAllocations(connection: *Connection) void {
    for (connection.foreign_key_action_allocations.items) |allocation| {
        connection.allocator.free(allocation);
    }
    connection.foreign_key_action_allocations.deinit(connection.allocator);
    connection.foreign_key_action_allocations = .empty;
}

fn notifyForeignKeyMutation(connection: *Connection, schema_name: []const u8, operation: c_int, table_name: []const u8, rowid: i64) ResultCode {
    connection.total_changes += 1;
    if (connection.update_callback) |callback| {
        const name = connection.allocator.dupeZ(u8, table_name) catch return .no_memory;
        defer connection.allocator.free(name);
        const schema = connection.allocator.dupeZ(u8, schema_name) catch return .no_memory;
        defer connection.allocator.free(schema);
        callback(connection.update_context, operation, schema.ptr, name.ptr, rowid);
    }
    return .ok;
}

/// Runtime action program synthesized from source `fkActionTrigger()`.
fn foreignKeyActionTrigger(
    connection: *Connection,
    database: *btree.Database,
    schema_name: []const u8,
    child_table_name: []const u8,
    child_root_page: u32,
    child_columns: []const ResolvedColumn,
    child_tokens: []const Token,
    mappings: []const ForeignKeyMapping,
    parent_columns: []const ResolvedColumn,
    parent_indices: []const usize,
    parent_table_name: []const u8,
    parent_rowid: i64,
    parent_new_rowid: i64,
    parent_new_values: ?[]btree.Value,
    child_rowid: i64,
    action: ForeignKeyAction,
) ResultCode {
    const opened = database.openCursor(child_root_page, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    defer cursor.deinit();
    if (!cursor.seekTable(child_rowid)) return .ok;
    const decoded = cursor.record();
    if (decoded.result != .ok) return decoded.result;
    var record = decoded.record.?;
    defer record.deinit();

    if (action == .cascade and parent_new_values == null) {
        const checked = checkForeignKeys(connection, database, schema_name, child_table_name, child_rowid, .{ .parent_delete = .{ .old_values = record.values } });
        if (checked != .ok) return checked;
        const nested = applyForeignKeyActions(connection, database, schema_name, child_table_name, child_rowid, child_rowid, record.values, null, null);
        if (nested != .ok) return nested;
        const deleted = database.deleteTable(child_root_page, child_rowid);
        if (deleted == .not_found) return .ok;
        if (deleted != .ok) return deleted;
        const indexed = maintainSecondaryIndexes(connection, database, child_table_name, .{ .rowid = child_rowid, .values = record.values }, null);
        if (indexed != .ok) return indexed;
        return notifyForeignKeyMutation(connection, schema_name, 9, child_table_name, child_rowid);
    }

    const self_update = std.ascii.eqlIgnoreCase(child_table_name, parent_table_name) and child_rowid == parent_rowid and parent_new_values != null;
    const base_values = if (self_update) parent_new_values.? else record.values;
    const values = connection.allocator.dupe(btree.Value, base_values) catch return .no_memory;
    defer connection.allocator.free(values);
    var new_rowid = child_rowid;
    for (mappings, parent_indices) |mapping, parent_index| {
        const value = switch (action) {
            .cascade => proposedForeignKeyValue(parent_columns[parent_index], parent_new_rowid, parent_new_values.?) orelse return .corrupt,
            .set_null => @as(btree.Value, .null_),
            .set_default => blk: {
                const default = foreignKeyDefaultValue(connection.allocator, child_tokens, child_columns[mapping.child_column]);
                if (default.result != .ok) return default.result;
                if (default.owned) |owned| connection.foreign_key_action_allocations.append(connection.allocator, owned) catch {
                    connection.allocator.free(owned);
                    return .no_memory;
                };
                break :blk default.value;
            },
            else => return .constraint,
        };
        const assigned = assignForeignKeyActionValue(database, child_root_page, child_columns[mapping.child_column], value, &new_rowid, values);
        if (assigned != .ok) return assigned;
    }

    if (self_update) {
        if (new_rowid != child_rowid or parent_new_values.?.len != values.len) return .error_;
        @memcpy(parent_new_values.?, values);
        return .ok;
    }

    const checked = checkForeignKeys(connection, database, schema_name, child_table_name, child_rowid, .{ .parent_update = .{ .old_values = record.values, .new_rowid = new_rowid, .new_values = values } });
    if (checked != .ok) return checked;
    const nested = applyForeignKeyActions(connection, database, schema_name, child_table_name, child_rowid, new_rowid, record.values, values, null);
    if (nested != .ok) return nested;
    const child_check = checkForeignKeys(connection, database, schema_name, child_table_name, new_rowid, .{ .child_insert = .{ .values = values } });
    if (child_check != .ok) return child_check;
    const payload = btree.encodeRecord(connection.allocator, values) catch |err| return if (err == error.OutOfMemory) .no_memory else .too_big;
    defer connection.allocator.free(payload);
    if (new_rowid != child_rowid) {
        const destination = database.openCursor(child_root_page, .table);
        if (destination.result != .ok) return destination.result;
        var destination_cursor = destination.cursor.?;
        defer destination_cursor.deinit();
        if (destination_cursor.seekTable(new_rowid)) return .constraint;
        const deleted = database.deleteTable(child_root_page, child_rowid);
        if (deleted != .ok) return deleted;
        const inserted = database.insertTable(child_root_page, new_rowid, payload, false);
        if (inserted != .ok) return inserted;
    } else {
        const inserted = database.insertTable(child_root_page, child_rowid, payload, true);
        if (inserted != .ok) return inserted;
    }
    const indexed = maintainSecondaryIndexes(connection, database, child_table_name, .{ .rowid = child_rowid, .values = record.values }, .{ .rowid = new_rowid, .values = values });
    if (indexed != .ok) return indexed;
    return notifyForeignKeyMutation(connection, schema_name, 23, child_table_name, new_rowid);
}

fn schemaEntryText(value: btree.Value) ?[]const u8 {
    return switch (value) {
        .text => |text| text,
        else => null,
    };
}

fn schemaEntryRoot(value: btree.Value) ?u32 {
    return switch (value) {
        .integer => |root| if (root > 0 and root <= std.math.maxInt(u32)) @intCast(root) else null,
        else => null,
    };
}

fn parentKeyChanged(
    parent_columns: []const ResolvedColumn,
    parent_indices: []const usize,
    old_rowid: i64,
    new_rowid: i64,
    old_values: []const btree.Value,
    new_values: []const btree.Value,
) bool {
    for (parent_indices) |parent_index| {
        const old = foreignKeyRowValue(parent_columns[parent_index], old_rowid, old_values) orelse return true;
        const new = proposedForeignKeyValue(parent_columns[parent_index], new_rowid, new_values) orelse return true;
        if (!foreignKeyColumnValueEqual(parent_columns[parent_index], old, new)) return true;
    }
    return false;
}

fn processParentForeignKeys(
    connection: *Connection,
    database: *btree.Database,
    schema_name: []const u8,
    parent_table_name: []const u8,
    parent_columns: []const ResolvedColumn,
    parent_tokens: []const Token,
    parent_rowid: i64,
    parent_new_rowid: i64,
    old_values: []const btree.Value,
    new_values: ?[]btree.Value,
    dropping_table: ?[]const u8,
    apply_actions: bool,
) ResultCode {
    if (connection.database_configuration[2] == 0) return .ok;
    if (connection.foreign_key_action_depth >= @as(usize, @intCast(@max(connection.limits[10], 0)))) return .error_;
    connection.pending_foreign_key_parents.append(connection.allocator, .{
        .table_name = parent_table_name,
        .old_rowid = parent_rowid,
        .new_rowid = parent_new_rowid,
        .new_values = new_values,
    }) catch return .no_memory;
    defer {
        _ = connection.pending_foreign_key_parents.pop();
        if (connection.pending_foreign_key_parents.items.len == 0) {
            connection.pending_foreign_key_parents.deinit(connection.allocator);
            connection.pending_foreign_key_parents = .empty;
        }
    }
    connection.foreign_key_action_depth += 1;
    defer connection.foreign_key_action_depth -= 1;

    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return opened.result;
    var schema_cursor = opened.cursor.?;
    defer schema_cursor.deinit();
    for (schema_cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return decoded.result;
        var schema_record = decoded.record.?;
        defer schema_record.deinit();
        if (schema_record.values.len < 5) continue;
        const object_type = schemaEntryText(schema_record.values[0]) orelse continue;
        if (!std.mem.eql(u8, object_type, "table")) continue;
        const child_table_name = schemaEntryText(schema_record.values[1]) orelse continue;
        if (dropping_table) |dropped| {
            if (std.ascii.eqlIgnoreCase(child_table_name, dropped)) continue;
        }
        const child_root_page = schemaEntryRoot(schema_record.values[3]) orelse continue;
        const child_sql = schemaEntryText(schema_record.values[4]) orelse continue;
        const child_columns = resolveColumns(connection.allocator, child_sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
        defer {
            connection.allocator.free(child_columns.columns);
            connection.allocator.free(child_columns.tokens);
            connection.allocator.free(child_columns.source);
        }
        var foreign_keys = resolveForeignKeys(connection.allocator, child_sql, child_columns.columns) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
        defer foreign_keys.deinit();
        for (foreign_keys.keys) |key| {
            if (!std.ascii.eqlIgnoreCase(key.parent_table, parent_table_name)) continue;
            const mappings = foreign_keys.keyMappings(key);
            const parent_indices = locateForeignKeyIndex(connection.allocator, database, parent_table_name, parent_columns, parent_tokens, mappings) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
            defer connection.allocator.free(parent_indices);
            if (new_values) |new| {
                if (!parentKeyChanged(parent_columns, parent_indices, parent_rowid, parent_new_rowid, old_values, new)) continue;
            }
            var rowids = std.ArrayList(i64).empty;
            defer rowids.deinit(connection.allocator);
            const same_table = std.ascii.eqlIgnoreCase(child_table_name, parent_table_name);
            const collected = scanForeignKeyChildren(database, child_root_page, child_columns.columns, mappings, parent_columns, parent_indices, parent_rowid, old_values, if (same_table and new_values == null) parent_rowid else null, &rowids);
            if (collected != .ok) return collected;
            if (rowids.items.len == 0) continue;
            const action = if (new_values == null) key.on_delete else key.on_update;
            if (!apply_actions) {
                if (action == .no_action and key.deferred and connection.explicit_transaction) continue;
                if (action == .no_action or action == .restrict) return ResultCode.fromC(ResultCode.constraint.toC() | (3 << 8));
                continue;
            }
            if (action == .no_action or action == .restrict) continue;
            for (rowids.items) |child_rowid| {
                const mutated = foreignKeyActionTrigger(connection, database, schema_name, child_table_name, child_root_page, child_columns.columns, child_columns.tokens, mappings, parent_columns, parent_indices, parent_table_name, parent_rowid, parent_new_rowid, new_values, child_rowid, action);
                if (mutated != .ok) return mutated;
            }
        }
    }
    return .ok;
}

fn processParentTableForeignKeys(connection: *Connection, database: *btree.Database, schema_name: []const u8, table_name: []const u8, rowid: i64, new_rowid: i64, old_values: []const btree.Value, new_values: ?[]btree.Value, dropping_table: ?[]const u8, apply_actions: bool) ResultCode {
    if (connection.database_configuration[2] == 0) return .ok;
    const schema_outcome = database.schemaTable(table_name);
    if (schema_outcome.result != .ok) return schema_outcome.result;
    var table_schema = schema_outcome.table.?;
    defer table_schema.deinit();
    const columns = resolveColumns(connection.allocator, table_schema.sql) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
    defer {
        connection.allocator.free(columns.columns);
        connection.allocator.free(columns.tokens);
        connection.allocator.free(columns.source);
    }
    return processParentForeignKeys(connection, database, schema_name, table_name, columns.columns, columns.tokens, rowid, new_rowid, old_values, new_values, dropping_table, apply_actions);
}

const ForeignKeyOldMaskOutcome = struct { result: ResultCode, mask: u32 = 0 };

fn foreignKeyColumnMask(index: usize) u32 {
    return if (index > 31) std.math.maxInt(u32) else @as(u32, 1) << @intCast(index);
}

/// Runtime counterpart of source `sqlite3FkOldmask()`.
fn foreignKeyOldMask(connection: *Connection, database: *btree.Database, table_name: []const u8, table_columns: []const ResolvedColumn, table_tokens: []const Token) ForeignKeyOldMaskOutcome {
    if (connection.database_configuration[2] == 0) return .{ .result = .ok };
    var mask: u32 = 0;
    const table_schema = database.schemaTable(table_name);
    if (table_schema.result != .ok) return .{ .result = table_schema.result };
    var table = table_schema.table.?;
    defer table.deinit();
    var own_keys = resolveForeignKeys(connection.allocator, table.sql, table_columns) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_ };
    defer own_keys.deinit();
    for (own_keys.mappings) |mapping| {
        mask |= foreignKeyColumnMask(mapping.child_column);
    }

    const opened = database.openCursor(1, .table);
    if (opened.result != .ok) return .{ .result = opened.result };
    var schema_cursor = opened.cursor.?;
    defer schema_cursor.deinit();
    for (schema_cursor.entries.items) |entry| {
        const decoded = btree.decodeRecord(connection.allocator, entry.payload);
        if (decoded.result != .ok) return .{ .result = decoded.result };
        var schema_record = decoded.record.?;
        defer schema_record.deinit();
        if (schema_record.values.len < 5 or !std.mem.eql(u8, schemaEntryText(schema_record.values[0]) orelse continue, "table")) continue;
        const child_sql = schemaEntryText(schema_record.values[4]) orelse continue;
        const child_columns = resolveColumns(connection.allocator, child_sql) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_ };
        defer {
            connection.allocator.free(child_columns.columns);
            connection.allocator.free(child_columns.tokens);
            connection.allocator.free(child_columns.source);
        }
        var keys = resolveForeignKeys(connection.allocator, child_sql, child_columns.columns) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_ };
        defer keys.deinit();
        for (keys.keys) |key| {
            if (!std.ascii.eqlIgnoreCase(key.parent_table, table_name)) continue;
            const mappings = keys.keyMappings(key);
            const indices = locateForeignKeyIndex(connection.allocator, database, table_name, table_columns, table_tokens, mappings) catch |err| return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_ };
            defer connection.allocator.free(indices);
            for (indices) |index| {
                mask |= foreignKeyColumnMask(index);
            }
        }
    }
    return .{ .result = .ok, .mask = mask };
}

fn foreignKeyOldValuesAvailable(mask: u32, value_count: usize) bool {
    if (mask == 0) return true;
    if (value_count >= 32) return true;
    const available: u32 = if (value_count == 0) 0 else (@as(u32, 1) << @intCast(value_count)) - 1;
    return mask & ~available == 0;
}

const ForeignKeyCheckOperation = union(enum) {
    child_insert: struct { values: []const btree.Value },
    parent_delete: struct { old_values: []const btree.Value, dropping_table: ?[]const u8 = null },
    parent_update: struct { old_values: []const btree.Value, new_rowid: i64, new_values: []btree.Value },
};

/// Runtime counterpart of source `sqlite3FkCheck()`.
fn checkForeignKeys(connection: *Connection, database: *btree.Database, schema_name: []const u8, table_name: []const u8, rowid: i64, operation: ForeignKeyCheckOperation) ResultCode {
    return switch (operation) {
        .child_insert => |insert| checkChildForeignKeyParents(connection, database, table_name, rowid, insert.values),
        .parent_delete => |delete| processParentTableForeignKeys(connection, database, schema_name, table_name, rowid, rowid, delete.old_values, null, delete.dropping_table, false),
        .parent_update => |update| processParentTableForeignKeys(connection, database, schema_name, table_name, rowid, update.new_rowid, update.old_values, update.new_values, null, false),
    };
}

/// Runtime counterpart of source `sqlite3FkActions()`.
fn applyForeignKeyActions(connection: *Connection, database: *btree.Database, schema_name: []const u8, table_name: []const u8, rowid: i64, new_rowid: i64, old_values: []const btree.Value, new_values: ?[]btree.Value, dropping_table: ?[]const u8) ResultCode {
    return processParentTableForeignKeys(connection, database, schema_name, table_name, rowid, new_rowid, old_values, new_values, dropping_table, true);
}

const ScanPlan = struct {
    predicate: ?struct { opcode: vdbe.Opcode, value: i64 } = null,
    descending: bool = false,
    limit: ?i64 = null,
};

/// Source `sqlite3OpenTable()`: select table or primary-index cursor form and
/// construct the bounded open instruction shared by scan code generators.
fn openTable(root_page: u32, index_scan: bool, writable: bool) vdbe.Instruction {
    std.debug.assert(!writable);
    return .{
        .opcode = .open_read,
        .p1 = 0,
        .p2 = @intCast(root_page),
        .p3 = @intFromBool(index_scan),
    };
}

fn schemaWithoutRowid(token_list: []const Token) bool {
    var index: usize = 0;
    while (index + 1 < token_list.len) : (index += 1) {
        if (token_list[index].typ == tokens.tk_without and token_list[index + 1].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(token_list[index + 1].text, "rowid")) return true;
    }
    return false;
}

const EncodedColumnDefault = struct {
    p4: vdbe.P4 = .none,
    p5: u16 = 0,
};

fn realColumnAffinity(declared_type: []const u8) bool {
    const markers = [_][]const u8{ "REAL", "FLOA", "DOUB" };
    for (markers) |marker| {
        if (declared_type.len < marker.len) continue;
        for (0..declared_type.len - marker.len + 1) |offset| {
            if (std.ascii.eqlIgnoreCase(declared_type[offset..][0..marker.len], marker)) return true;
        }
    }
    return false;
}

/// Source `sqlite3ColumnDefault()`: encode literal ALTER TABLE defaults as
/// OP_Column P4 values and preserve text versus blob storage class in P5.
fn columnDefault(allocator: std.mem.Allocator, owner: *Owner, column: ResolvedColumn, token_list: []const Token) !EncodedColumnDefault {
    var position = column.default_start orelse return .{};
    var end = column.default_end;
    while (position < end and token_list[position].typ == tokens.tk_lp) {
        position += 1;
    }
    while (end > position and token_list[end - 1].typ == tokens.tk_rp) {
        end -= 1;
    }
    if (position >= end) return .{};
    var negative = false;
    if (token_list[position].typ == tokens.tk_plus or token_list[position].typ == tokens.tk_minus) {
        negative = token_list[position].typ == tokens.tk_minus;
        position += 1;
    }
    if (position + 1 != end) return .{};
    const token = token_list[position];
    return switch (token.typ) {
        tokens.tk_null => .{},
        tokens.tk_integer => result: {
            var value = std.fmt.parseInt(i128, token.text, 0) catch return error.Syntax;
            if (negative) {
                value = -value;
            }
            if (value < std.math.minInt(i64) or value > std.math.maxInt(i64)) return error.Syntax;
            break :result .{ .p4 = .{ .integer = @intCast(value) } };
        },
        tokens.tk_float => result: {
            var value = std.fmt.parseFloat(f64, token.text) catch return error.Syntax;
            if (negative) {
                value = -value;
            }
            break :result .{ .p4 = .{ .real = value } };
        },
        tokens.tk_string, tokens.tk_blob => result: {
            if (negative) return error.Syntax;
            const decoded = try decodeSqlToken(allocator, token);
            errdefer allocator.free(decoded.bytes);
            try owner.strings.append(allocator, decoded.bytes);
            break :result .{ .p4 = .{ .bytes = decoded.bytes }, .p5 = if (decoded.blob) vdbe.column_default_blob else 0 };
        },
        else => .{},
    };
}

/// Source `sqlite3ExprCodeGetColumnOfTable()`: emit rowid or record-column
/// extraction, including literal defaults and REAL affinity correction.
fn expressionCodeGetColumnOfTable(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, column: ResolvedColumn, token_list: []const Token, cursor: i32, output: i32, index_scan: bool) !void {
    if (column.integer_primary_key and !index_scan) {
        try code.append(allocator, .{ .opcode = .rowid, .p1 = cursor, .p2 = output });
        return;
    }
    const fallback = try columnDefault(allocator, owner, column, token_list);
    try code.append(allocator, .{ .opcode = .column, .p1 = cursor, .p2 = @intCast(column.record_index), .p3 = output, .p4 = fallback.p4, .p5 = fallback.p5 });
    if (realColumnAffinity(column.declared_type)) {
        try code.append(allocator, .{ .opcode = .real_affinity, .p1 = output });
    }
}

/// Source `sqlite3ExprCodeGetColumn()`: apply caller P5 flags to the column
/// extraction generated for an open table cursor.
fn expressionCodeGetColumn(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, column: ResolvedColumn, token_list: []const Token, cursor: i32, output: i32, p5: u16) !void {
    const operation_index = code.items.len;
    try expressionCodeGetColumnOfTable(code, allocator, owner, column, token_list, cursor, output, false);
    if (operation_index < code.items.len and code.items[operation_index].opcode == .column) {
        code.items[operation_index].p5 |= p5;
    }
}

/// Source `sqlite3ExprCodeLoadIndexColumn()`: load a covering-index field
/// without applying the ordinary table's INTEGER PRIMARY KEY rowid alias.
fn expressionCodeLoadIndexColumn(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, column: ResolvedColumn, token_list: []const Token, cursor: i32, output: i32) !void {
    try expressionCodeGetColumnOfTable(code, allocator, owner, column, token_list, cursor, output, true);
}

/// Source `sqlite3VdbeGetOp()`: return a mutable instruction after validating
/// its address against the current program.
fn getOperation(code: *std.ArrayList(vdbe.Instruction), address: usize) !*vdbe.Instruction {
    if (address >= code.items.len) return error.InvalidOperationAddress;
    return &code.items[address];
}

/// Source `sqlite3VdbeChangeToNoop()`: discard all operands and P4 state while
/// replacing one instruction with OP_Noop.
fn changeOperationToNoop(code: *std.ArrayList(vdbe.Instruction), address: usize) !void {
    const operation = try getOperation(code, address);
    operation.* = .{ .opcode = .noop };
}

/// Source `sqlite3VdbeJumpHereOrPopInst()`: remove a trailing no-op jump or
/// bind an earlier jump to the next instruction.
fn jumpHereOrPopOperation(code: *std.ArrayList(vdbe.Instruction), address: usize) !void {
    const operation = try getOperation(code, address);
    if (address + 1 == code.items.len and (operation.opcode == .once or operation.opcode == .if_)) {
        _ = code.pop();
        return;
    }
    operation.p2 = @intCast(code.items.len);
}

/// Source `sqlite3ExprCodeRunJustOnce()`: retain OP_Once around scalar
/// expressions that do not acquire a dependency on the current cursor row.
fn expressionCodeRunJustOnce(code: *std.ArrayList(vdbe.Instruction), once_index: usize, referenced_before: bool, referenced_after: bool) void {
    std.debug.assert(once_index < code.items.len);
    const operation = getOperation(code, once_index) catch unreachable;
    std.debug.assert(operation.opcode == .once);
    if (referenced_before != referenced_after) {
        changeOperationToNoop(code, once_index) catch unreachable;
        return;
    }
    jumpHereOrPopOperation(code, once_index) catch unreachable;
}

const GeneratedColumnError = error{ Syntax, TooBig, OutOfMemory, GeneratedColumnLoop };

fn binaryExpressionCollation(_: ?*anyopaque, left: []const u8, right: []const u8) i32 {
    const order = std.mem.order(u8, left, right);
    return if (order == .lt) -1 else if (order == .gt) 1 else 0;
}

fn noCaseExpressionCollation(_: ?*anyopaque, left: []const u8, right: []const u8) i32 {
    const common = @min(left.len, right.len);
    for (left[0..common], right[0..common]) |left_byte, right_byte| {
        const folded_left = std.ascii.toLower(left_byte);
        const folded_right = std.ascii.toLower(right_byte);
        if (folded_left != folded_right) return if (folded_left < folded_right) -1 else 1;
    }
    return if (left.len < right.len) -1 else if (left.len > right.len) 1 else 0;
}

fn rtrimExpressionCollation(_: ?*anyopaque, left: []const u8, right: []const u8) i32 {
    var left_end = left.len;
    while (left_end != 0 and left[left_end - 1] == ' ') {
        left_end -= 1;
    }
    var right_end = right.len;
    while (right_end != 0 and right[right_end - 1] == ' ') {
        right_end -= 1;
    }
    return binaryExpressionCollation(null, left[0..left_end], right[0..right_end]);
}

const GeneratedColumnCompiler = struct {
    allocator: std.mem.Allocator,
    owner: *Owner,
    code: *std.ArrayList(vdbe.Instruction),
    token_list: []const Token,
    column_tokens: []const Token,
    columns: []const ResolvedColumn,
    position: usize,
    end: usize,
    next_register: *u16,
    cursor: i32,
    index_scan: bool,
    qualifier: ?[]const u8 = null,
    connection: *Connection,
    functions: *std.ArrayList(vdbe.Function),
    collations: *std.ArrayList(vdbe.Collation),
    pending_collation: ?u16 = null,
    references_columns: bool = false,

    fn allocateRegister(self: *GeneratedColumnCompiler) GeneratedColumnError!u16 {
        if (self.next_register.* == std.math.maxInt(u16)) return error.TooBig;
        const result = self.next_register.*;
        self.next_register.* += 1;
        return result;
    }

    fn primary(self: *GeneratedColumnCompiler) GeneratedColumnError!u16 {
        if (self.position >= self.end) return error.Syntax;
        const token = self.token_list[self.position];
        if (token.typ == tokens.tk_lp) {
            self.position += 1;
            const result = try self.expression(0);
            if (self.position >= self.end or self.token_list[self.position].typ != tokens.tk_rp) return error.Syntax;
            self.position += 1;
            return result;
        }
        if (token.typ == tokens.tk_id and self.position + 1 < self.end and self.token_list[self.position + 1].typ == tokens.tk_lp) {
            self.position += 2;
            const once_index = self.code.items.len;
            try self.code.append(self.allocator, .{ .opcode = .once });
            const referenced_before = self.references_columns;
            var arguments = std.ArrayList(u16).empty;
            defer arguments.deinit(self.allocator);
            if (self.position < self.end and self.token_list[self.position].typ == tokens.tk_rp) {
                self.position += 1;
            } else {
                while (true) {
                    try arguments.append(self.allocator, try self.expression(0));
                    if (self.position >= self.end) return error.Syntax;
                    if (self.token_list[self.position].typ == tokens.tk_rp) {
                        self.position += 1;
                        break;
                    }
                    if (self.token_list[self.position].typ != tokens.tk_comma) return error.Syntax;
                    self.position += 1;
                }
            }
            const definition = self.connection.findScalar(token.text, arguments.items.len) orelse return error.Syntax;
            var first_argument: u16 = 0;
            for (arguments.items, 0..) |source, index| {
                const destination = try self.allocateRegister();
                if (index == 0) {
                    first_argument = destination;
                }
                try self.code.append(self.allocator, .{ .opcode = .copy, .p1 = source, .p2 = destination });
            }
            const output = try self.allocateRegister();
            const function_index = self.functions.items.len;
            try self.functions.append(self.allocator, .{ .callback = statement.invokeScalar, .context = definition });
            try self.code.append(self.allocator, .{ .opcode = .function, .p1 = @intCast(arguments.items.len), .p2 = first_argument, .p3 = output, .p4 = .{ .index = @intCast(function_index) } });
            expressionCodeRunJustOnce(self.code, once_index, referenced_before, self.references_columns);
            return output;
        }
        if (token.typ == tokens.tk_id) {
            self.position += 1;
            var column_name = token.text;
            if (self.position + 1 < self.end and self.token_list[self.position].typ == tokens.tk_dot and self.token_list[self.position + 1].typ == tokens.tk_id) {
                const qualifier = self.qualifier orelse return error.Syntax;
                if (!std.ascii.eqlIgnoreCase(column_name, qualifier)) return error.Syntax;
                column_name = self.token_list[self.position + 1].text;
                self.position += 2;
            }
            const column_index = resolvedColumnIndex(self.columns, column_name) orelse return error.Syntax;
            self.references_columns = true;
            const column = self.columns[column_index];
            if (column.generated_start != null) return error.GeneratedColumnLoop;
            const output = try self.allocateRegister();
            if (self.index_scan) {
                try expressionCodeLoadIndexColumn(self.code, self.allocator, self.owner, column, self.column_tokens, self.cursor, output);
            } else {
                try expressionCodeGetColumn(self.code, self.allocator, self.owner, column, self.column_tokens, self.cursor, output, 0);
            }
            return output;
        }
        if (token.typ == tokens.tk_integer) {
            self.position += 1;
            const value = std.fmt.parseInt(i64, token.text, 0) catch return error.Syntax;
            const output = try self.allocateRegister();
            if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                try self.code.append(self.allocator, .{ .opcode = .integer, .p1 = @intCast(value), .p2 = output });
            } else {
                try self.code.append(self.allocator, .{ .opcode = .int64, .p2 = output, .p4 = .{ .integer = value } });
            }
            return output;
        }
        if (token.typ == tokens.tk_float) {
            self.position += 1;
            const value = std.fmt.parseFloat(f64, token.text) catch return error.Syntax;
            const output = try self.allocateRegister();
            try self.code.append(self.allocator, .{ .opcode = .real, .p2 = output, .p4 = .{ .real = value } });
            return output;
        }
        if (token.typ == tokens.tk_string or token.typ == tokens.tk_blob) {
            self.position += 1;
            const decoded = try decodeSqlToken(self.allocator, token);
            self.owner.strings.append(self.allocator, decoded.bytes) catch |err| {
                self.allocator.free(decoded.bytes);
                return err;
            };
            const output = try self.allocateRegister();
            try self.code.append(self.allocator, .{ .opcode = if (decoded.blob) .blob else .string, .p2 = output, .p4 = .{ .bytes = decoded.bytes } });
            return output;
        }
        return error.Syntax;
    }

    fn unary(self: *GeneratedColumnCompiler) GeneratedColumnError!u16 {
        if (self.position < self.end and self.token_list[self.position].typ == tokens.tk_plus) {
            self.position += 1;
            return self.unary();
        }
        if (self.position < self.end and self.token_list[self.position].typ == tokens.tk_minus) {
            self.position += 1;
            const source = try self.unary();
            const zero = try self.allocateRegister();
            try self.code.append(self.allocator, .{ .opcode = .integer, .p1 = 0, .p2 = zero });
            const output = try self.allocateRegister();
            try self.code.append(self.allocator, .{ .opcode = .subtract, .p1 = source, .p2 = zero, .p3 = output });
            return output;
        }
        return self.primary();
    }

    /// Source `sqlite3ExprAddCollateString()`: resolve a postfix collation
    /// name and attach its VDBE callback to the next comparison operation.
    fn addCollationString(self: *GeneratedColumnCompiler, name: []const u8) GeneratedColumnError!void {
        const callback: vdbe.CollationCallback = if (std.ascii.eqlIgnoreCase(name, "BINARY"))
            binaryExpressionCollation
        else if (std.ascii.eqlIgnoreCase(name, "NOCASE"))
            noCaseExpressionCollation
        else if (std.ascii.eqlIgnoreCase(name, "RTRIM"))
            rtrimExpressionCollation
        else
            return error.Syntax;
        if (self.collations.items.len == std.math.maxInt(u16)) return error.TooBig;
        self.pending_collation = @intCast(self.collations.items.len);
        try self.collations.append(self.allocator, .{ .callback = callback });
    }

    fn consumeCollation(self: *GeneratedColumnCompiler) GeneratedColumnError!void {
        while (self.position + 1 < self.end and self.token_list[self.position].typ == tokens.tk_collate) {
            if (self.token_list[self.position + 1].typ != tokens.tk_id) return error.Syntax;
            try self.addCollationString(self.token_list[self.position + 1].text);
            self.position += 2;
        }
    }

    fn precedence(token_type: u16) u8 {
        return switch (token_type) {
            tokens.tk_eq, tokens.tk_ne, tokens.tk_lt, tokens.tk_le, tokens.tk_gt, tokens.tk_ge => 1,
            tokens.tk_plus, tokens.tk_minus => 2,
            tokens.tk_star, tokens.tk_slash, tokens.tk_rem => 3,
            tokens.tk_concat => 4,
            else => 0,
        };
    }

    /// Source `exprComputeOperands()`: compile the right operand at the next
    /// precedence level and reserve a distinct result register.
    fn computeOperands(self: *GeneratedColumnCompiler, level: u8) GeneratedColumnError!struct { right: u16, output: u16 } {
        const right = try self.expression(level + 1);
        const output = try self.allocateRegister();
        if (right == output) return error.Syntax;
        return .{ .right = right, .output = output };
    }

    fn expression(self: *GeneratedColumnCompiler, minimum: u8) GeneratedColumnError!u16 {
        var left = try self.unary();
        try self.consumeCollation();
        while (self.position < self.end) {
            const operation_token = self.token_list[self.position].typ;
            const level = precedence(operation_token);
            if (level == 0 or level < minimum) break;
            self.position += 1;
            const operands = try self.computeOperands(level);
            const right = operands.right;
            const output = operands.output;
            const operation: vdbe.Opcode = switch (operation_token) {
                tokens.tk_eq => .eq,
                tokens.tk_ne => .ne,
                tokens.tk_lt => .lt,
                tokens.tk_le => .le,
                tokens.tk_gt => .gt,
                tokens.tk_ge => .ge,
                tokens.tk_plus => .add,
                tokens.tk_minus => .subtract,
                tokens.tk_star => .multiply,
                tokens.tk_slash => .divide,
                tokens.tk_rem => .remainder,
                tokens.tk_concat => .concat,
                else => unreachable,
            };
            if (level == 1) {
                try self.code.append(self.allocator, .{ .opcode = .integer, .p1 = 0, .p2 = output });
                const comparison_index = self.code.items.len;
                const p4: vdbe.P4 = if (self.pending_collation) |index| .{ .collation = index } else .none;
                try self.code.append(self.allocator, .{ .opcode = operation, .p1 = right, .p3 = left, .p4 = p4 });
                const end_index = self.code.items.len;
                try self.code.append(self.allocator, .{ .opcode = .goto });
                const true_index = self.code.items.len;
                try self.code.append(self.allocator, .{ .opcode = .integer, .p1 = 1, .p2 = output });
                self.code.items[comparison_index].p2 = @intCast(true_index);
                self.code.items[end_index].p2 = @intCast(self.code.items.len);
                self.pending_collation = null;
            } else {
                try self.code.append(self.allocator, .{ .opcode = operation, .p1 = right, .p2 = left, .p3 = output });
            }
            left = output;
        }
        return left;
    }
};

/// Source `sqlite3ExprCodeGeneratedColumn()`: compile a virtual generated
/// column expression against the current row and materialize its affinity.
fn expressionCodeGeneratedColumn(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, connection: *Connection, functions: *std.ArrayList(vdbe.Function), collations: *std.ArrayList(vdbe.Collation), column: ResolvedColumn, columns: []const ResolvedColumn, token_list: []const Token, cursor: i32, output: i32, index_scan: bool, next_register: *u16) !void {
    var compiler: GeneratedColumnCompiler = .{ .allocator = allocator, .owner = owner, .code = code, .token_list = token_list, .column_tokens = token_list, .columns = columns, .position = column.generated_start orelse return error.Syntax, .end = column.generated_end, .next_register = next_register, .cursor = cursor, .index_scan = index_scan, .connection = connection, .functions = functions, .collations = collations };
    const result = try compiler.expression(0);
    if (compiler.position != compiler.end) return error.Syntax;
    if (result != output) {
        try code.append(allocator, .{ .opcode = .copy, .p1 = result, .p2 = output });
    }
    if (realColumnAffinity(column.declared_type)) {
        try code.append(allocator, .{ .opcode = .real_affinity, .p1 = output });
    }
}

/// Source `sqlite3ExprCodeTarget()`: evaluate a table-scan expression into
/// its designated result register using the current cursor row.
fn expressionCodeTarget(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, connection: *Connection, functions: *std.ArrayList(vdbe.Function), collations: *std.ArrayList(vdbe.Collation), expression_column: ResolvedColumn, columns: []const ResolvedColumn, expression_tokens: []const Token, column_tokens: []const Token, qualifier: []const u8, output: i32, index_scan: bool, next_register: *u16) !void {
    var compiler: GeneratedColumnCompiler = .{ .allocator = allocator, .owner = owner, .code = code, .token_list = expression_tokens, .column_tokens = column_tokens, .columns = columns, .position = expression_column.generated_start orelse return error.Syntax, .end = expression_column.generated_end, .next_register = next_register, .cursor = 0, .index_scan = index_scan, .qualifier = qualifier, .connection = connection, .functions = functions, .collations = collations };
    const result = try compiler.expression(0);
    if (compiler.position != compiler.end) return error.Syntax;
    if (result != output) {
        try code.append(allocator, .{ .opcode = .copy, .p1 = result, .p2 = output });
    }
}

fn expressionCodeResultColumn(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, connection: *Connection, functions: *std.ArrayList(vdbe.Function), collations: *std.ArrayList(vdbe.Collation), column: ResolvedColumn, all_columns: []const ResolvedColumn, schema_tokens: []const Token, expression_tokens: []const Token, qualifier: []const u8, index_scan: bool, output: i32, next_register: *u16) !void {
    if (column.scan_expression) {
        return expressionCodeTarget(code, allocator, owner, connection, functions, collations, column, all_columns, expression_tokens, schema_tokens, qualifier, output, index_scan, next_register);
    }
    if (column.generated_start != null and column.generated_virtual) {
        return expressionCodeGeneratedColumn(code, allocator, owner, connection, functions, collations, column, all_columns, schema_tokens, 0, output, index_scan, next_register);
    }
    if (index_scan) {
        return expressionCodeLoadIndexColumn(code, allocator, owner, column, schema_tokens, 0, output);
    }
    return expressionCodeGetColumn(code, allocator, owner, column, schema_tokens, 0, output, 0);
}

const IndexedExpression = struct { start: usize, end: usize, register: u16 };

/// Source `exprCompareVariable()`: compare tokenized expressions while
/// requiring parameter tokens to retain the same spelling and position.
fn expressionCompareVariable(token_list: []const Token, first_start: usize, first_end: usize, second_start: usize, second_end: usize) bool {
    if (first_end - first_start != second_end - second_start) return false;
    for (token_list[first_start..first_end], token_list[second_start..second_end]) |first, second| {
        if (first.typ != second.typ) return false;
        if (first.typ == tokens.tk_variable) {
            if (!std.mem.eql(u8, first.text, second.text)) return false;
        } else if (first.typ == tokens.tk_id) {
            if (!std.ascii.eqlIgnoreCase(first.text, second.text)) return false;
        } else if (!std.mem.eql(u8, first.text, second.text)) return false;
    }
    return true;
}

/// Source `sqlite3IndexedExprLookup()`: find an already coded equivalent
/// result expression so duplicate projection terms can reuse its register.
fn indexedExpressionLookup(cache: []const IndexedExpression, column: ResolvedColumn, token_list: []const Token) ?u16 {
    const start = column.generated_start orelse return null;
    for (cache) |entry| {
        if (expressionCompareVariable(token_list, entry.start, entry.end, start, column.generated_end)) return entry.register;
    }
    return null;
}

/// Source `exprPartidxExprLookup()`: resolve a simple expression column by
/// schema identity for covering-index projection.
fn partialIndexExpressionLookup(columns: []const ResolvedColumn, name: []const u8) ?usize {
    for (columns, 0..) |column, index| {
        if (column.scan_expression) continue;
        if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
    }
    return null;
}

/// Source `sqlite3ExprCodeExprList()`: emit each scan result expression into
/// a contiguous register range while sharing temporary-register ownership.
fn expressionCodeExpressionList(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, owner: *Owner, connection: *Connection, functions: *std.ArrayList(vdbe.Function), collations: *std.ArrayList(vdbe.Collation), selected: []const ResolvedColumn, all_columns: []const ResolvedColumn, schema_tokens: []const Token, expression_tokens: []const Token, qualifier: []const u8, index_scan: bool, first_output: i32, next_register: *u16) !void {
    var cache = std.ArrayList(IndexedExpression).empty;
    defer cache.deinit(allocator);
    for (selected, 0..) |column, index| {
        const output: u16 = @intCast(first_output + @as(i32, @intCast(index)));
        if (column.scan_expression) {
            if (indexedExpressionLookup(cache.items, column, expression_tokens)) |prior| {
                try code.append(allocator, .{ .opcode = .copy, .p1 = prior, .p2 = output });
                continue;
            }
        }
        try expressionCodeResultColumn(code, allocator, owner, connection, functions, collations, column, all_columns, schema_tokens, expression_tokens, qualifier, index_scan, output, next_register);
        if (column.scan_expression) {
            try cache.append(allocator, .{ .start = column.generated_start.?, .end = column.generated_end, .register = output });
        }
    }
}

/// Source `sqlite3VdbeSetNumCols()`: allocate the statement's result-column
/// metadata array before names are attached.
fn setResultColumnCount(allocator: std.mem.Allocator, owner: *Owner, count: usize) ![]statement.ColumnMetadata {
    if (count > std.math.maxInt(u16)) return error.TooBig;
    const columns = try allocator.alloc(statement.ColumnMetadata, count);
    for (columns) |*column| {
        column.* = .{ .name = "" };
    }
    owner.columns = columns;
    return columns;
}

/// Source `sqlite3VdbeSetColName()`: transfer one owned result-column name to
/// both statement metadata and owner cleanup tracking.
fn setResultColumnName(allocator: std.mem.Allocator, owner: *Owner, columns: []statement.ColumnMetadata, index: usize, name_text: []const u8) !void {
    if (index >= columns.len) return error.InvalidColumn;
    const name = try allocator.dupeZ(u8, name_text);
    owner.names.append(allocator, name) catch |err| {
        allocator.free(name);
        return err;
    };
    columns[index] = .{ .name = name };
}

/// Source `sqlite3ExprNullRegisterRange()`: initialize a contiguous register
/// range to NULL with one VDBE operation.
fn expressionNullRegisterRange(code: *std.ArrayList(vdbe.Instruction), allocator: std.mem.Allocator, first: u16, last: u16) !void {
    if (first == 0 or last < first) return error.InvalidRegisterRange;
    try code.append(allocator, .{ .opcode = .null_, .p2 = first, .p3 = last });
}

fn buildAggregateTableScan(connection: *Connection, database: *btree.Database, source: [:0]u8, root_page: u32, index_scan: bool, selected: []const ResolvedColumn, all_columns: []const ResolvedColumn, schema_tokens: []const Token, expression_tokens: []const Token, qualifier: []const u8, analysis: *const AggregateAnalysis) !*statement.Statement {
    const allocator = connection.allocator;
    if (selected.len == 0 or selected.len > std.math.maxInt(u16) - 8) return error.TooBig;
    const owner = allocator.create(Owner) catch |err| {
        allocator.free(source);
        return err;
    };
    owner.* = .{ .source = source, .instructions = &.{}, .parameters = &.{}, .columns = &.{}, .program = .{ .instructions = &.{}, .register_count = @intCast(selected.len + 3), .cursor_count = 1 } };
    errdefer Owner.destroy(allocator, owner);
    var code = std.ArrayList(vdbe.Instruction).empty;
    defer code.deinit(allocator);
    var functions = std.ArrayList(vdbe.Function).empty;
    defer functions.deinit(allocator);
    var collations = std.ArrayList(vdbe.Collation).empty;
    defer collations.deinit(allocator);
    var accumulators = std.ArrayList(u16).empty;
    defer accumulators.deinit(allocator);
    var aggregate_functions = std.ArrayList(u16).empty;
    defer aggregate_functions.deinit(allocator);
    const parameters = try allocator.alloc(statement.ParameterMetadata, 0);
    owner.parameters = parameters;
    const columns = try setResultColumnCount(allocator, owner, selected.len);
    try code.append(allocator, openTable(root_page, index_scan, false));
    var next_register: u16 = @intCast(selected.len + 1);
    for (analysis.functions.items) |_| {
        try accumulators.append(allocator, next_register);
        next_register += 1;
    }
    try expressionNullRegisterRange(&code, allocator, accumulators.items[0], accumulators.items[accumulators.items.len - 1]);
    const rewind_index = code.items.len;
    try code.append(allocator, .{ .opcode = .rewind, .p1 = 0 });
    const loop_index = code.items.len;
    for (analysis.functions.items, accumulators.items) |term, accumulator| {
        var argument_results: [4]u16 = undefined;
        for (term.arguments[0..term.argument_count], 0..) |argument, argument_index| {
            const destination = next_register;
            next_register += 1;
            const expression_column = scanExpressionColumn(source, expression_tokens, argument.start, argument.end);
            try expressionCodeTarget(&code, allocator, owner, connection, &functions, &collations, expression_column, all_columns, expression_tokens, schema_tokens, qualifier, destination, index_scan, &next_register);
            argument_results[argument_index] = destination;
        }
        var first_argument: u16 = 1;
        if (term.argument_count != 0) {
            first_argument = next_register;
            for (argument_results[0..term.argument_count]) |argument_result| {
                const destination = next_register;
                next_register += 1;
                try code.append(allocator, .{ .opcode = .copy, .p1 = argument_result, .p2 = destination });
            }
        }
        const function_index = functions.items.len;
        try aggregate_functions.append(allocator, @intCast(function_index));
        try functions.append(allocator, .{ .aggregate_step = statement.invokeAggregateStep, .aggregate_final = statement.finalizeAggregate, .context = term.definition });
        try code.append(allocator, .{ .opcode = .agg_step, .p1 = @intCast(term.argument_count), .p2 = first_argument, .p3 = accumulator, .p4 = .{ .index = @intCast(function_index) } });
    }
    try code.append(allocator, .{ .opcode = .next, .p1 = 0, .p2 = @intCast(loop_index) });
    const final_index = code.items.len;
    code.items[rewind_index].p2 = @intCast(final_index);
    for (analysis.functions.items, accumulators.items, aggregate_functions.items, 0..) |_, accumulator, function_index, index| {
        try code.append(allocator, .{ .opcode = .agg_final, .p2 = accumulator, .p3 = @intCast(index + 1), .p4 = .{ .index = function_index } });
    }
    try code.append(allocator, .{ .opcode = .result_row, .p1 = 1, .p2 = @intCast(selected.len) });
    try code.append(allocator, .{ .opcode = .halt });
    for (selected, 0..) |column, index| {
        try setResultColumnName(allocator, owner, columns, index, column.name);
    }
    const instructions = try code.toOwnedSlice(allocator);
    owner.instructions = instructions;
    owner.program.instructions = instructions;
    owner.program.register_count = @max(owner.program.register_count, next_register - 1);
    const dynamic_functions = try functions.toOwnedSlice(allocator);
    functions = .empty;
    owner.dynamic_functions = dynamic_functions;
    owner.program.functions = dynamic_functions;
    const dynamic_collations = try collations.toOwnedSlice(allocator);
    collations = .empty;
    owner.dynamic_collations = dynamic_collations;
    owner.program.collations = dynamic_collations;
    const prepared = try statement.Statement.createWithDatabase(allocator, &owner.program, parameters, columns, database);
    prepared.adoptOwner(owner, Owner.destroy);
    return prepared;
}

fn buildPlannedTableScan(connection: *Connection, database: *btree.Database, source: [:0]u8, root_page: u32, index_scan: bool, selected: []const ResolvedColumn, all_columns: []const ResolvedColumn, schema_tokens: []const Token, expression_tokens: []const Token, qualifier: []const u8, plan: ScanPlan) !*statement.Statement {
    const allocator = connection.allocator;
    if (selected.len > std.math.maxInt(u16) - 8) return error.TooBig;
    const owner = allocator.create(Owner) catch |err| {
        allocator.free(source);
        return err;
    };
    owner.* = .{ .source = source, .instructions = &.{}, .parameters = &.{}, .columns = &.{}, .program = .{ .instructions = &.{}, .register_count = @intCast(selected.len + 3), .cursor_count = 1 } };
    errdefer Owner.destroy(allocator, owner);
    var code = std.ArrayList(vdbe.Instruction).empty;
    defer code.deinit(allocator);
    var functions = std.ArrayList(vdbe.Function).empty;
    defer functions.deinit(allocator);
    var collations = std.ArrayList(vdbe.Collation).empty;
    defer collations.deinit(allocator);
    const parameters = try allocator.alloc(statement.ParameterMetadata, 0);
    owner.parameters = parameters;
    const columns = try setResultColumnCount(allocator, owner, selected.len);
    try code.append(allocator, openTable(root_page, index_scan, false));
    const predicate_register: i32 = @intCast(selected.len + 1);
    const rowid_register: i32 = @intCast(selected.len + 2);
    const limit_register: i32 = @intCast(selected.len + 3);
    var next_register: u16 = @intCast(selected.len + 4);
    if (plan.predicate) |predicate| {
        try code.append(allocator, .{ .opcode = .integer, .p1 = @intCast(predicate.value), .p2 = predicate_register });
    }
    if (plan.limit) |limit| {
        try code.append(allocator, .{ .opcode = .integer, .p1 = @intCast(limit), .p2 = limit_register });
    }
    if (plan.limit == 0) {
        try code.append(allocator, .{ .opcode = .halt });
    } else if (!index_scan and plan.predicate != null and plan.predicate.?.opcode == .eq) {
        const seek_index = code.items.len;
        try code.append(allocator, .{ .opcode = .seek_rowid, .p1 = 0, .p3 = predicate_register });
        try expressionCodeExpressionList(&code, allocator, owner, connection, &functions, &collations, selected, all_columns, schema_tokens, expression_tokens, qualifier, index_scan, 1, &next_register);
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
        try expressionCodeExpressionList(&code, allocator, owner, connection, &functions, &collations, selected, all_columns, schema_tokens, expression_tokens, qualifier, index_scan, 1, &next_register);
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
        if (reject_index) |index| {
            code.items[index].p2 = @intCast(advance_index);
        }
        if (limit_index) |index| {
            code.items[index].p2 = @intCast(halt_index);
        }
    }
    for (selected, 0..) |column, index| {
        try setResultColumnName(allocator, owner, columns, index, column.name);
    }
    const instructions = try code.toOwnedSlice(allocator);
    owner.instructions = instructions;
    owner.program.instructions = instructions;
    owner.program.register_count = @max(owner.program.register_count, next_register - 1);
    const dynamic_functions = try functions.toOwnedSlice(allocator);
    functions = .empty;
    owner.dynamic_functions = dynamic_functions;
    owner.program.functions = dynamic_functions;
    const dynamic_collations = try collations.toOwnedSlice(allocator);
    collations = .empty;
    owner.dynamic_collations = dynamic_collations;
    owner.program.collations = dynamic_collations;
    const prepared = try statement.Statement.createWithDatabase(allocator, &owner.program, parameters, columns, database);
    prepared.adoptOwner(owner, Owner.destroy);
    return prepared;
}

fn compilePlannedTableScan(connection: *Connection, database: *btree.Database, source: [:0]u8, consumed: usize, root_page: u32, index_scan: bool, selected: []const ResolvedColumn, all_columns: []const ResolvedColumn, schema_tokens: []const Token, expression_tokens: []const Token, qualifier: []const u8, plan: ScanPlan) CompileOutcome {
    const prepared = buildPlannedTableScan(connection, database, source, root_page, index_scan, selected, all_columns, schema_tokens, expression_tokens, qualifier, plan) catch |err| {
        return .{ .result = switch (err) {
            error.OutOfMemory => .no_memory,
            error.TooBig => .too_big,
            else => .error_,
        }, .consumed = consumed };
    };
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

/// Source virtual-table lookup is scoped by the owning `Db` schema, so equal
/// table names in main and an attached database retain distinct instances.
fn virtualSchemaMatches(connection: *Connection, stored: []const u8, requested: []const u8) bool {
    if (schemaSliceMatches(connection, stored)) return schemaSliceMatches(connection, requested);
    return std.ascii.eqlIgnoreCase(stored, requested);
}

fn findVirtualTable(connection: *Connection, schema_name: []const u8, table_name: []const u8) ?*VirtualTable {
    for (connection.virtual_tables.items) |table| {
        if (virtualSchemaMatches(connection, table.schema_name, schema_name) and std.ascii.eqlIgnoreCase(table.name, table_name)) return table;
    }
    return null;
}

fn compileVirtualScan(connection: *Connection, table: *VirtualTable, source: [:0]u8, token_list: []const Token, consumed: usize, from_position: usize, after_table: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (after_table != token_list.len) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var selected = std.ArrayList(usize).empty;
    defer selected.deinit(allocator);
    if (from_position == 2 and token_list[1].typ == tokens.tk_star) {
        for (0..table.columns.items.len) |index| {
            selected.append(allocator, index) catch {
                allocator.free(source);
                return .{ .result = .no_memory, .consumed = consumed };
            };
        }
    } else {
        var position: usize = 1;
        while (position < from_position) {
            if (token_list[position].typ != tokens.tk_id) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            var found: ?usize = null;
            for (table.columns.items, 0..) |name, index| {
                if (std.ascii.eqlIgnoreCase(name, token_list[position].text)) {
                    found = index;
                    break;
                }
            }
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

fn decodeSqlToken(allocator: std.mem.Allocator, token: Token) ParserError!struct { bytes: []u8, blob: bool } {
    if (token.typ == tokens.tk_string) {
        if (token.text.len < 2) return error.Syntax;
        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(allocator);
        var index: usize = 1;
        while (index + 1 < token.text.len) : (index += 1) {
            if (token.text[index] == '\'' and index + 1 < token.text.len - 1 and token.text[index + 1] == '\'') index += 1;
            try decoded.append(allocator, token.text[index]);
        }
        return .{ .bytes = try decoded.toOwnedSlice(allocator), .blob = false };
    }
    if (token.typ == tokens.tk_blob) {
        if (token.text.len < 3 or token.text.len % 2 == 0) return error.Syntax;
        const output = try allocator.alloc(u8, (token.text.len - 3) / 2);
        errdefer allocator.free(output);
        for (output, 0..) |*byte, index| {
            byte.* = std.fmt.parseInt(u8, token.text[2 + index * 2 ..][0..2], 16) catch return error.Syntax;
        }
        return .{ .bytes = output, .blob = true };
    }
    return error.Syntax;
}

fn compileJsonVirtualScan(connection: *Connection, configuration: json_vtable.Connection, source: [:0]u8, token_list: []const Token, consumed: usize, from_position: usize) CompileOutcome {
    const allocator = connection.allocator;
    const argument_position = from_position + 3;
    if (argument_position + 1 >= token_list.len or token_list[from_position + 2].typ != tokens.tk_lp) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const decoded = decodeSqlToken(allocator, token_list[argument_position]) catch |err| {
        allocator.free(source);
        return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
    };
    var root: ?[]u8 = null;
    var closing = argument_position + 1;
    if (closing < token_list.len and token_list[closing].typ == tokens.tk_comma) {
        if (closing + 2 >= token_list.len) {
            allocator.free(decoded.bytes);
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        const decoded_root = decodeSqlToken(allocator, token_list[closing + 1]) catch |err| {
            allocator.free(decoded.bytes);
            allocator.free(source);
            return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
        };
        if (decoded_root.blob) {
            allocator.free(decoded_root.bytes);
            allocator.free(decoded.bytes);
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        root = decoded_root.bytes;
        closing += 2;
    }
    if (closing >= token_list.len or token_list[closing].typ != tokens.tk_rp or closing + 1 != token_list.len) {
        if (root) |value| allocator.free(value);
        allocator.free(decoded.bytes);
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const column_names = [_][]const u8{ "key", "value", "type", "atom", "id", "parent", "fullkey", "path", "json", "root" };
    var selected = std.ArrayList(usize).empty;
    defer selected.deinit(allocator);
    if (from_position == 2 and token_list[1].typ == tokens.tk_star) {
        for (0..8) |index| {
            selected.append(allocator, index) catch {
                if (root) |value| allocator.free(value);
                allocator.free(decoded.bytes);
                allocator.free(source);
                return .{ .result = .no_memory, .consumed = consumed };
            };
        }
    } else {
        var position: usize = 1;
        while (position < from_position) {
            var found: ?usize = null;
            for (&column_names, 0..) |name, index| {
                if (std.ascii.eqlIgnoreCase(name, token_list[position].text)) {
                    found = index;
                    break;
                }
            }
            selected.append(allocator, found orelse {
                if (root) |value| allocator.free(value);
                allocator.free(decoded.bytes);
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }) catch {
                if (root) |value| allocator.free(value);
                allocator.free(decoded.bytes);
                allocator.free(source);
                return .{ .result = .no_memory, .consumed = consumed };
            };
            position += 1;
            if (position == from_position) break;
            if (token_list[position].typ != tokens.tk_comma) {
                if (root) |value| allocator.free(value);
                allocator.free(decoded.bytes);
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            position += 1;
        }
    }
    if (selected.items.len == 0) {
        if (root) |value| allocator.free(value);
        allocator.free(decoded.bytes);
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    _ = json_vtable.bestIndex(&.{.{ .column = 8, .equal = true, .usable = true }}, false) catch unreachable;
    const owner = allocator.create(Owner) catch {
        if (root) |value| allocator.free(value);
        allocator.free(decoded.bytes);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const plan = allocator.create(JsonVirtualPlan) catch {
        allocator.destroy(owner);
        if (root) |value| allocator.free(value);
        allocator.free(decoded.bytes);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    plan.* = .{ .allocator = allocator, .connection = configuration, .input = decoded.bytes, .input_is_blob = decoded.blob, .root = root };
    const instruction_count = selected.items.len + 5;
    const instructions = allocator.alloc(vdbe.Instruction, instruction_count) catch {
        allocator.free(plan.input);
        if (plan.root) |value| allocator.free(value);
        allocator.destroy(plan);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const parameters = allocator.alloc(statement.ParameterMetadata, 0) catch unreachable;
    const columns = allocator.alloc(statement.ColumnMetadata, selected.items.len) catch {
        allocator.free(instructions);
        allocator.free(plan.input);
        if (plan.root) |value| allocator.free(value);
        allocator.destroy(plan);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const sources = allocator.alloc(vdbe.VirtualSource, 1) catch {
        allocator.free(columns);
        allocator.free(parameters);
        allocator.free(instructions);
        allocator.free(plan.input);
        if (plan.root) |value| allocator.free(value);
        allocator.destroy(plan);
        allocator.destroy(owner);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    sources[0] = json_virtual_source_template;
    sources[0].context = plan;
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .virtual_sources = sources, .json_virtual_plan = plan, .program = .{ .instructions = instructions, .register_count = @intCast(selected.items.len), .cursor_count = 1, .virtual_sources = sources } };
    instructions[0] = .{ .opcode = .open_virtual, .p1 = 0, .p2 = 0 };
    instructions[1] = .{ .opcode = .rewind, .p1 = 0, .p2 = @intCast(instruction_count - 1) };
    for (selected.items, 0..) |column_index, index| {
        instructions[2 + index] = .{ .opcode = .column, .p1 = 0, .p2 = @intCast(column_index), .p3 = @intCast(index + 1) };
        const name = owner.names.addOne(allocator) catch {
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        name.* = allocator.dupeZ(u8, column_names[column_index]) catch {
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

const LocatedTableItem = struct {
    database: *btree.Database,
    table: btree.SchemaTable,
    table_name: []const u8,
    qualifier: []const u8,
    after: usize,
};

const LocateTableItemOutcome = struct {
    result: ResultCode,
    item: ?LocatedTableItem = null,
    error_offset: c_int = -1,
};

const LocatedDatabaseOutcome = struct {
    result: ResultCode,
    database: ?*btree.Database = null,
};

const LocatedTableOutcome = struct {
    result: ResultCode,
    database: ?*btree.Database = null,
    schema_name: []const u8 = "",
    table: ?btree.SchemaTable = null,
};

const LocatedIndexOutcome = struct {
    result: ResultCode,
    database: ?*btree.Database = null,
    schema_name: []const u8 = "",
    index: ?btree.SchemaTable = null,
};

fn locateDatabase(connection: *Connection, database_name: ?[]const u8) LocatedDatabaseOutcome {
    if (database_name) |name| {
        if (std.ascii.eqlIgnoreCase(name, "temp")) {
            if (connection.temp_database == null) {
                connection.temp_database = AttachedDatabase.createMemory(connection.allocator) orelse return .{ .result = .no_memory };
            }
            const temporary = connection.temp_database.?;
            const database = if (temporary.database) |*opened| opened else return .{ .result = .misuse };
            return .{ .result = .ok, .database = database };
        }
    }
    if (schemaSliceMatches(connection, database_name)) {
        if (connection.pending_deserialize_readonly != null) {
            const opened = openPendingDeserializedDatabase(connection);
            if (opened != .ok) return .{ .result = opened };
        }
        return .{ .result = .ok, .database = connection.database orelse return .{ .result = .misuse } };
    }
    const attachments = if (connection.attachments) |*catalog| catalog else return .{ .result = .not_found };
    const entry = attachment_runtime.findDatabase(attachments, database_name.?) orelse return .{ .result = .not_found };
    const native = entry.native_context orelse return .{ .result = .not_found };
    const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
    if (attached.pending_deserialize_readonly != null) {
        const opened = openPendingAttachedDatabase(attached);
        if (opened != .ok) return .{ .result = opened };
    }
    const database = if (attached.database) |*opened| opened else return .{ .result = .misuse };
    return .{ .result = .ok, .database = database };
}

fn locateTableWithDatabase(connection: *Connection, name: []const u8, database_name: ?[]const u8) LocatedTableOutcome {
    if (database_name) |schema_name| {
        const located_database = locateDatabase(connection, schema_name);
        if (located_database.result != .ok) {
            return .{ .result = located_database.result };
        }
        const table = located_database.database.?.schemaTable(name);
        return .{ .result = table.result, .database = located_database.database, .schema_name = schema_name, .table = table.table };
    }
    if (connection.temp_database) |temporary| {
        if (temporary.database) |*database| {
            const table = database.schemaTable(name);
            if (table.result == .ok) {
                return .{ .result = .ok, .database = database, .schema_name = "temp", .table = table.table };
            }
            if (table.result != .not_found) {
                return .{ .result = table.result };
            }
        }
    }
    const main_database = locateDatabase(connection, null);
    if (main_database.result != .ok) {
        return .{ .result = main_database.result };
    }
    const main_table = main_database.database.?.schemaTable(name);
    if (main_table.result == .ok) {
        return .{ .result = .ok, .database = main_database.database, .schema_name = "main", .table = main_table.table };
    }
    if (main_table.result != .not_found) {
        return .{ .result = main_table.result };
    }
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |attached| {
            const located_database = locateDatabase(connection, attached.name);
            if (located_database.result != .ok) {
                return .{ .result = located_database.result };
            }
            const table = located_database.database.?.schemaTable(name);
            if (table.result == .ok) {
                return .{ .result = .ok, .database = located_database.database, .schema_name = attached.name, .table = table.table };
            }
            if (table.result != .not_found) {
                return .{ .result = table.result };
            }
        }
    }
    return .{ .result = .not_found };
}

/// Source `sqlite3FindIndex()`: resolve TEMP, main, then attached schemas for
/// an unqualified index name, or restrict lookup to the selected database.
fn locateIndexWithDatabase(connection: *Connection, name: []const u8, database_name: ?[]const u8) LocatedIndexOutcome {
    if (database_name) |schema_name| {
        const located_database = locateDatabase(connection, schema_name);
        if (located_database.result != .ok) return .{ .result = located_database.result };
        const index = located_database.database.?.schemaIndex(name);
        return .{ .result = index.result, .database = located_database.database, .schema_name = schema_name, .index = index.table };
    }
    if (connection.temp_database) |temporary| {
        if (temporary.database) |*database| {
            const index = database.schemaIndex(name);
            if (index.result == .ok) return .{ .result = .ok, .database = database, .schema_name = "temp", .index = index.table };
            if (index.result != .not_found) return .{ .result = index.result };
        }
    }
    const main_database = locateDatabase(connection, null);
    if (main_database.result != .ok) return .{ .result = main_database.result };
    const main_index = main_database.database.?.schemaIndex(name);
    if (main_index.result == .ok) return .{ .result = .ok, .database = main_database.database, .schema_name = "main", .index = main_index.table };
    if (main_index.result != .not_found) return .{ .result = main_index.result };
    if (connection.attachments) |*attachments| {
        for (attachments.databases.items[2..]) |attached| {
            const located_database = locateDatabase(connection, attached.name);
            if (located_database.result != .ok) return .{ .result = located_database.result };
            const index = located_database.database.?.schemaIndex(name);
            if (index.result == .ok) return .{ .result = .ok, .database = located_database.database, .schema_name = attached.name, .index = index.table };
            if (index.result != .not_found) return .{ .result = index.result };
        }
    }
    return .{ .result = .not_found };
}

/// Source `sqlite3LocateTable()`: resolve TEMP, main, then attached schemas
/// for an unqualified name, or restrict lookup to the explicitly selected Db.
fn locateTable(connection: *Connection, name: []const u8, database_name: ?[]const u8) btree.SchemaTableOutcome {
    const located = locateTableWithDatabase(connection, name, database_name);
    return .{ .result = located.result, .table = located.table };
}

/// Source `sqlite3LocateTableItem()`: parse an optionally schema-qualified
/// FROM item, apply AS or bare aliases, and restrict lookup to its schema.
fn schemaIdentifierToken(token: Token) bool {
    return token.typ == tokens.tk_id or token.typ == tokens.tk_temp;
}

fn locateTableItem(connection: *Connection, token_list: []const Token, from_position: usize) LocateTableItemOutcome {
    var position = from_position + 1;
    if (position >= token_list.len or !schemaIdentifierToken(token_list[position])) {
        return .{ .result = .error_, .error_offset = if (position < token_list.len) @intCast(token_list[position].start) else -1 };
    }
    var database_name: ?[]const u8 = null;
    var table_name = token_list[position].text;
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_dot and token_list[position + 2].typ == tokens.tk_id) {
        database_name = table_name;
        table_name = token_list[position + 2].text;
        position += 3;
    } else {
        position += 1;
    }
    var qualifier = table_name;
    if (position + 1 < token_list.len and token_list[position].typ == tokens.tk_as and token_list[position + 1].typ == tokens.tk_id) {
        qualifier = token_list[position + 1].text;
        position += 2;
    } else if (position < token_list.len and token_list[position].typ == tokens.tk_id) {
        qualifier = token_list[position].text;
        position += 1;
    }
    const located = locateTableWithDatabase(connection, table_name, database_name);
    if (located.result != .ok) return .{ .result = located.result, .error_offset = @intCast(token_list[from_position + 1].start) };
    return .{ .result = .ok, .item = .{ .database = located.database.?, .table = located.table.?, .table_name = table_name, .qualifier = qualifier, .after = position } };
}

fn selectedColumnToken(token_list: []const Token, position: usize, limit: usize, qualifier: []const u8) ?struct { token: Token, next: usize } {
    if (position >= limit or token_list[position].typ != tokens.tk_id) return null;
    if (position + 2 < limit and token_list[position + 1].typ == tokens.tk_dot) {
        if (!std.ascii.eqlIgnoreCase(token_list[position].text, qualifier) or token_list[position + 2].typ != tokens.tk_id) return null;
        return .{ .token = token_list[position + 2], .next = position + 3 };
    }
    return .{ .token = token_list[position], .next = position + 1 };
}

fn scanExpressionColumn(source: []const u8, token_list: []const Token, start: usize, end: usize) ResolvedColumn {
    const first = token_list[start].start;
    const last = token_list[end - 1];
    return .{
        .name = source[first .. last.start + last.text.len],
        .declared_type = "",
        .collation = "BINARY",
        .explicit_collation = false,
        .descending = false,
        .record_index = 0,
        .integer_primary_key = false,
        .primary_key = false,
        .unique = false,
        .not_null = false,
        .default_start = null,
        .default_end = 0,
        .generated_start = start,
        .generated_end = end,
        .generated_virtual = true,
        .scan_expression = true,
        .index_transform = .identity,
    };
}

const AggregateArgument = struct { start: usize, end: usize };
const AggregateTerm = struct {
    definition: *statement.FunctionDefinition,
    arguments: [4]AggregateArgument = undefined,
    argument_count: usize = 0,
};
const AggregateAnalysis = struct {
    functions: std.ArrayList(AggregateTerm) = .empty,
    columns: std.ArrayList(usize) = .empty,

    fn deinit(self: *AggregateAnalysis, allocator: std.mem.Allocator) void {
        self.functions.deinit(allocator);
        self.columns.deinit(allocator);
    }
};

/// Source `addAggInfoColumn()`: add a unique source-column dependency to the
/// aggregate analysis arrays and return its stable slot.
fn aggregateAddColumn(allocator: std.mem.Allocator, analysis: *AggregateAnalysis, column_index: usize) !usize {
    for (analysis.columns.items, 0..) |existing, index| {
        if (existing == column_index) return index;
    }
    const index = analysis.columns.items.len;
    try analysis.columns.append(allocator, column_index);
    return index;
}

/// Source `addAggInfoFunc()`: append one resolved aggregate function and its
/// bounded argument ranges to the aggregate analysis.
fn aggregateAddFunction(allocator: std.mem.Allocator, analysis: *AggregateAnalysis, definition: *statement.FunctionDefinition, arguments: []const AggregateArgument) !void {
    if (arguments.len > 4) return error.TooManyArguments;
    var term = AggregateTerm{ .definition = definition };
    term.argument_count = arguments.len;
    for (arguments, 0..) |argument, index| {
        term.arguments[index] = argument;
    }
    try analysis.functions.append(allocator, term);
}

/// Source `sqlite3ExprAnalyzeAggregates()`: recognize top-level aggregate
/// result expressions, resolve their argument columns, and build AggInfo-like
/// function and column arrays for table-scan code generation.
fn expressionAnalyzeAggregates(allocator: std.mem.Allocator, connection: *Connection, selected: []const ResolvedColumn, columns: []const ResolvedColumn, token_list: []const Token, qualifier: []const u8) !?AggregateAnalysis {
    var analysis = AggregateAnalysis{};
    var transferred = false;
    defer if (!transferred) analysis.deinit(allocator);
    for (selected) |column| {
        if (!column.scan_expression) return null;
        const start = column.generated_start orelse return null;
        const end = column.generated_end;
        if (end < start + 3 or token_list[start].typ != tokens.tk_id or token_list[start + 1].typ != tokens.tk_lp or token_list[end - 1].typ != tokens.tk_rp) return null;
        const definition = connection.findScalar(token_list[start].text, 0) orelse connection.findScalar(token_list[start].text, 1) orelse connection.findScalar(token_list[start].text, 2) orelse return null;
        if (definition.step_callback == null or definition.final_callback == null) return null;
        var arguments: [4]AggregateArgument = undefined;
        var argument_count: usize = 0;
        var position = start + 2;
        if (position + 2 == end and token_list[position].typ == tokens.tk_star) {
            if (!std.ascii.eqlIgnoreCase(definition.name, "count")) return null;
        } else if (position != end - 1) {
            while (position < end - 1) {
                if (argument_count == arguments.len) return error.TooManyArguments;
                const argument_start = position;
                var depth: usize = 0;
                while (position < end - 1) : (position += 1) {
                    if (token_list[position].typ == tokens.tk_lp) {
                        depth += 1;
                    } else if (token_list[position].typ == tokens.tk_rp) {
                        if (depth == 0) return error.Syntax;
                        depth -= 1;
                    } else if (token_list[position].typ == tokens.tk_comma and depth == 0) break;
                }
                if (position == argument_start or depth != 0) return error.Syntax;
                arguments[argument_count] = .{ .start = argument_start, .end = position };
                argument_count += 1;
                if (position < end - 1) {
                    position += 1;
                }
            }
        }
        const exact_definition = connection.findScalar(token_list[start].text, argument_count) orelse return null;
        if (exact_definition != definition and (exact_definition.step_callback == null or exact_definition.final_callback == null)) return null;
        try aggregateAddFunction(allocator, &analysis, exact_definition, arguments[0..argument_count]);
        for (arguments[0..argument_count]) |argument| {
            var token_index = argument.start;
            while (token_index < argument.end) : (token_index += 1) {
                var name = token_list[token_index].text;
                if (token_index + 2 < argument.end and token_list[token_index + 1].typ == tokens.tk_dot) {
                    if (!std.ascii.eqlIgnoreCase(name, qualifier)) return error.Syntax;
                    name = token_list[token_index + 2].text;
                    token_index += 2;
                }
                if (token_list[token_index].typ != tokens.tk_id) continue;
                if (resolvedColumnIndex(columns, name)) |column_index| {
                    _ = try aggregateAddColumn(allocator, &analysis, column_index);
                }
            }
        }
    }
    if (analysis.functions.items.len == 0) return null;
    transferred = true;
    return analysis;
}

fn compileTableScan(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize, from_position: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (from_position + 1 >= token_list.len or !schemaIdentifierToken(token_list[from_position + 1])) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var virtual_schema_name: []const u8 = "main";
    var virtual_table_name = token_list[from_position + 1].text;
    var virtual_after_table = from_position + 2;
    if (virtual_after_table + 1 < token_list.len and token_list[virtual_after_table].typ == tokens.tk_dot and token_list[virtual_after_table + 1].typ == tokens.tk_id) {
        virtual_schema_name = virtual_table_name;
        virtual_table_name = token_list[virtual_after_table + 1].text;
        virtual_after_table += 2;
    }
    if (findVirtualTable(connection, virtual_schema_name, virtual_table_name)) |table| {
        return compileVirtualScan(connection, table, source, token_list, consumed, from_position, virtual_after_table);
    }
    if (virtual_after_table == from_position + 2 and connection.json_vtables_registered) {
        if (json_vtable.connect(token_list[from_position + 1].text)) |configuration| return compileJsonVirtualScan(connection, configuration, source, token_list, consumed, from_position);
    }
    const located_outcome = locateTableItem(connection, token_list, from_position);
    if (located_outcome.result != .ok) {
        allocator.free(source);
        return .{ .result = if (located_outcome.result == .not_found) .error_ else located_outcome.result, .error_offset = located_outcome.error_offset, .consumed = consumed };
    }
    const located = located_outcome.item.?;
    const database = located.database;
    const after_table = located.after;
    const indexed = after_table + 3 == token_list.len and token_list[after_table].typ == tokens.tk_indexed and token_list[after_table + 1].typ == tokens.tk_by and token_list[after_table + 2].typ == tokens.tk_id;
    const joined = after_table + 6 == token_list.len and token_list[after_table].typ == tokens.tk_join and token_list[after_table + 1].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(located.table_name, token_list[after_table + 1].text) and token_list[after_table + 2].typ == tokens.tk_using and token_list[after_table + 3].typ == tokens.tk_lp and token_list[after_table + 4].typ == tokens.tk_id and token_list[after_table + 5].typ == tokens.tk_rp;
    var schema = located.table;
    if (indexed) {
        const index_outcome = database.schemaIndex(token_list[after_table + 2].text);
        if (index_outcome.result != .ok) {
            schema.deinit();
            allocator.free(source);
            return .{ .result = if (index_outcome.result == .not_found) .error_ else index_outcome.result, .consumed = consumed };
        }
        schema.deinit();
        schema = index_outcome.table.?;
    }
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
    const table_without_rowid = schemaWithoutRowid(resolved.tokens);
    var selected = std.ArrayList(ResolvedColumn).empty;
    defer selected.deinit(allocator);
    const unqualified_star = from_position == 2 and token_list[1].typ == tokens.tk_star;
    const qualified_star = from_position == 4 and token_list[1].typ == tokens.tk_id and token_list[2].typ == tokens.tk_dot and token_list[3].typ == tokens.tk_star and std.ascii.eqlIgnoreCase(token_list[1].text, located.qualifier);
    if (unqualified_star or qualified_star) {
        selected.appendSlice(allocator, resolved.columns) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
    } else {
        var position: usize = 1;
        while (position < from_position) {
            const segment_start = position;
            var depth: usize = 0;
            while (position < from_position) : (position += 1) {
                const token_type = token_list[position].typ;
                if (token_type == tokens.tk_lp) {
                    depth += 1;
                } else if (token_type == tokens.tk_rp) {
                    if (depth == 0) {
                        allocator.free(source);
                        return .{ .result = .error_, .error_offset = @intCast(token_list[position].start), .consumed = consumed };
                    }
                    depth -= 1;
                } else if (token_type == tokens.tk_comma and depth == 0) break;
            }
            if (position == segment_start or depth != 0) {
                allocator.free(source);
                return .{ .result = .error_, .error_offset = @intCast(token_list[segment_start].start), .consumed = consumed };
            }
            const segment_end = position;
            if (selectedColumnToken(token_list, segment_start, segment_end, located.qualifier)) |reference| {
                if (reference.next == segment_end) {
                    var found: ?ResolvedColumn = null;
                    for (resolved.columns) |column| {
                        if (std.ascii.eqlIgnoreCase(column.name, reference.token.text)) {
                            found = column;
                            break;
                        }
                    }
                    selected.append(allocator, found orelse {
                        allocator.free(source);
                        return .{ .result = .error_, .error_offset = @intCast(reference.token.start), .consumed = consumed };
                    }) catch {
                        allocator.free(source);
                        return .{ .result = .no_memory, .consumed = consumed };
                    };
                } else {
                    selected.append(allocator, scanExpressionColumn(source, token_list, segment_start, segment_end)) catch {
                        allocator.free(source);
                        return .{ .result = .no_memory, .consumed = consumed };
                    };
                }
            } else {
                selected.append(allocator, scanExpressionColumn(source, token_list, segment_start, segment_end)) catch {
                    allocator.free(source);
                    return .{ .result = .no_memory, .consumed = consumed };
                };
            }
            if (position < from_position) {
                position += 1;
            }
        }
    }
    if (selected.items.len == 0 or selected.items.len > std.math.maxInt(u16)) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var selected_has_expressions = false;
    for (selected.items) |column| {
        if (column.scan_expression) {
            selected_has_expressions = true;
            break;
        }
    }
    if (!indexed and !joined and after_table == token_list.len) {
        var aggregate_analysis = expressionAnalyzeAggregates(allocator, connection, selected.items, resolved.columns, token_list, located.qualifier) catch |err| {
            allocator.free(source);
            return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
        };
        defer if (aggregate_analysis) |*analysis| analysis.deinit(allocator);
        if (aggregate_analysis) |*analysis| {
            const prepared = buildAggregateTableScan(connection, database, source, schema.root_page, table_without_rowid, selected.items, resolved.columns, resolved.tokens, token_list, located.qualifier, analysis) catch |err| {
                return .{ .result = switch (err) {
                    error.OutOfMemory => .no_memory,
                    error.TooBig => .too_big,
                    else => .error_,
                }, .consumed = consumed };
            };
            return .{ .result = .ok, .statement = prepared, .consumed = consumed };
        }
    }
    if (!indexed and !joined and after_table < token_list.len) {
        var plan: ScanPlan = .{};
        var position = after_table;
        if (!selected_has_expressions and token_list[position].typ == tokens.tk_order and position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_by and token_list[position + 2].typ == tokens.tk_id) {
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
                const index_name = std.fmt.allocPrint(allocator, "{s}_{s}", .{ located.table_name, order_column }) catch {
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
                    const found = if (partialIndexExpressionLookup(index_resolved.columns, wanted.name)) |index| index_resolved.columns[index] else null;
                    index_selected.append(allocator, found orelse {
                        allocator.free(source);
                        return .{ .result = .error_, .consumed = consumed };
                    }) catch {
                        allocator.free(source);
                        return .{ .result = .no_memory, .consumed = consumed };
                    };
                }
                return compilePlannedTableScan(connection, database, source, consumed, index_schema.root_page, true, index_selected.items, index_resolved.columns, index_resolved.tokens, token_list, located.qualifier, plan);
            }
        }
        position = after_table;
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
        if (table_without_rowid and plan.predicate != null) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        return compilePlannedTableScan(connection, database, source, consumed, schema.root_page, table_without_rowid, selected.items, resolved.columns, resolved.tokens, token_list, located.qualifier, plan);
    }
    if (!indexed and !joined and after_table != token_list.len) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const cursor_is_index = indexed or table_without_rowid;
    return compilePlannedTableScan(connection, database, source, consumed, schema.root_page, cursor_is_index, selected.items, resolved.columns, resolved.tokens, token_list, located.qualifier, .{});
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

/// Runtime counterpart of source `sqlite3FkDropTable()`.
fn dropTableForeignKeyActions(connection: *Connection, database: *btree.Database, schema_name: []const u8, table_name: []const u8) ResultCode {
    if (connection.database_configuration[2] == 0) return .ok;
    const schema = database.schemaTable(table_name);
    if (schema.result == .not_found) return .ok;
    if (schema.result != .ok) return schema.result;
    var table = schema.table.?;
    defer table.deinit();
    const opened = database.openCursor(table.root_page, .table);
    if (opened.result != .ok) return opened.result;
    var cursor = opened.cursor.?;
    var rowids = std.ArrayList(i64).empty;
    defer rowids.deinit(connection.allocator);
    for (cursor.entries.items) |entry| {
        rowids.append(connection.allocator, entry.rowid orelse {
            cursor.deinit();
            return .corrupt;
        }) catch {
            cursor.deinit();
            return .no_memory;
        };
    }
    cursor.deinit();
    for (rowids.items) |rowid| {
        const current = database.openCursor(table.root_page, .table);
        if (current.result != .ok) return current.result;
        var current_cursor = current.cursor.?;
        if (!current_cursor.seekTable(rowid)) {
            current_cursor.deinit();
            continue;
        }
        const decoded = current_cursor.record();
        if (decoded.result != .ok) {
            current_cursor.deinit();
            return decoded.result;
        }
        var record = decoded.record.?;
        current_cursor.deinit();
        defer record.deinit();
        const checked = checkForeignKeys(connection, database, schema_name, table_name, rowid, .{ .parent_delete = .{ .old_values = record.values, .dropping_table = table_name } });
        if (checked != .ok) return checked;
        const actions = applyForeignKeyActions(connection, database, schema_name, table_name, rowid, rowid, record.values, null, table_name);
        if (actions != .ok) return actions;
        const deleted = database.deleteTable(table.root_page, rowid);
        if (deleted != .ok and deleted != .not_found) return deleted;
    }
    return .ok;
}

fn reloadAnalysis(connection: *Connection) ResultCode {
    const statistics = connection.statistics orelse return .misuse;
    const loaded = connection.allocator.create(analysis_stats.LoadedAnalysis) catch return .no_memory;
    loaded.* = analysis_stats.loadAnalysis(connection.allocator, statistics) catch |err| {
        connection.allocator.destroy(loaded);
        return if (err == error.OutOfMemory) .no_memory else .error_;
    };
    if (connection.loaded_analysis) |prior| {
        prior.deinit();
        connection.allocator.destroy(prior);
    }
    connection.loaded_analysis = loaded;
    return .ok;
}

fn runAnalyze(connection: *Connection, table_name: ?[]const u8) ResultCode {
    const database = connection.database orelse return .misuse;
    if (connection.statistics == null) {
        const statistics = connection.allocator.create(analysis_stats.StatTable) catch return .no_memory;
        statistics.* = analysis_stats.StatTable.init(connection.allocator);
        connection.statistics = statistics;
    }
    const statistics = connection.statistics.?;
    if (table_name) |name| {
        const schema_outcome = database.schemaTable(name);
        if (schema_outcome.result != .ok) return schema_outcome.result;
        var schema = schema_outcome.table.?;
        defer schema.deinit();
        const cursor_outcome = database.openCursor(schema.root_page, .table);
        if (cursor_outcome.result != .ok) return cursor_outcome.result;
        var cursor = cursor_outcome.cursor.?;
        defer cursor.deinit();
        analysis_stats.analyzeTable(statistics, .{ .name = name, .row_count = cursor.count() }, null) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
        return reloadAnalysis(connection);
    }

    analysis_stats.openStatisticsTable(statistics, null, false);
    const schema_outcome = database.openCursor(1, .table);
    if (schema_outcome.result != .ok) return schema_outcome.result;
    var schema_cursor = schema_outcome.cursor.?;
    defer schema_cursor.deinit();
    if (schema_cursor.first()) {
        while (true) {
            const decoded = schema_cursor.record();
            if (decoded.result != .ok) return decoded.result;
            var record = decoded.record.?;
            defer record.deinit();
            if (record.values.len >= 4) {
                const object_type = switch (record.values[0]) {
                    .text => |text| text,
                    else => &.{},
                };
                const name = switch (record.values[1]) {
                    .text => |text| text,
                    else => &.{},
                };
                const root_page: ?u32 = switch (record.values[3]) {
                    .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else null,
                    else => null,
                };
                if (std.ascii.eqlIgnoreCase(object_type, "table") and root_page != null) {
                    const cursor_outcome = database.openCursor(root_page.?, .table);
                    if (cursor_outcome.result != .ok) return cursor_outcome.result;
                    var table_cursor = cursor_outcome.cursor.?;
                    defer table_cursor.deinit();
                    analysis_stats.analyzeOneTable(statistics, .{ .name = name, .row_count = table_cursor.count() }, null) catch |err| return if (err == error.OutOfMemory) .no_memory else .error_;
                }
            }
            if (!schema_cursor.next()) break;
        }
    }
    return reloadAnalysis(connection);
}

fn enlistTransactionDatabase(connection: *Connection, database: *btree.Database) ResultCode {
    if (!connection.explicit_transaction) return .ok;
    for (connection.transaction_databases.items) |existing| {
        if (existing == database) {
            return .ok;
        }
    }
    const begun = database.beginMutationBatch();
    if (begun != .ok) return begun;
    connection.transaction_databases.append(connection.allocator, database) catch {
        _ = database.rollbackMutationBatch();
        return .no_memory;
    };
    return .ok;
}

fn validateDeferredForeignKeys(connection: *Connection, database: *btree.Database) ResultCode {
    if (connection.database_configuration[2] == 0) return .ok;
    const opened_schema = database.openCursor(1, .table);
    if (opened_schema.result != .ok) return opened_schema.result;
    var schema_cursor = opened_schema.cursor.?;
    defer schema_cursor.deinit();
    for (schema_cursor.entries.items) |schema_entry| {
        const decoded_schema = btree.decodeRecord(connection.allocator, schema_entry.payload);
        if (decoded_schema.result != .ok) return decoded_schema.result;
        var schema_record = decoded_schema.record.?;
        defer schema_record.deinit();
        if (schema_record.values.len < 5) continue;
        const object_type = schemaEntryText(schema_record.values[0]) orelse continue;
        if (!std.mem.eql(u8, object_type, "table")) continue;
        const table_name = schemaEntryText(schema_record.values[1]) orelse continue;
        const root_page = schemaEntryRoot(schema_record.values[3]) orelse continue;
        const opened_table = database.openCursor(root_page, .table);
        if (opened_table.result != .ok) return opened_table.result;
        var table_cursor = opened_table.cursor.?;
        defer table_cursor.deinit();
        for (table_cursor.entries.items) |entry| {
            const rowid = entry.rowid orelse return .corrupt;
            const decoded = btree.decodeRecord(connection.allocator, entry.payload);
            if (decoded.result != .ok) return decoded.result;
            var record = decoded.record.?;
            defer record.deinit();
            const checked = checkChildForeignKeyParentsMode(connection, database, table_name, rowid, record.values, false);
            if (checked != .ok) return checked;
        }
    }
    return .ok;
}

fn finishExplicitTransaction(connection: *Connection, rollback: bool) ResultCode {
    if (!connection.explicit_transaction) return .error_;
    if (!rollback) {
        for (connection.transaction_databases.items) |database| {
            const checked = validateDeferredForeignKeys(connection, database);
            if (checked != .ok) return checked;
        }
        if (connection.commit_callback) |callback| {
            if (callback(connection.commit_context) != 0) {
                _ = finishExplicitTransaction(connection, true);
                return .constraint;
            }
        }
    }
    var result: ResultCode = .ok;
    for (connection.transaction_databases.items) |database| {
        const current = if (rollback) database.rollbackMutationBatch() else database.commitMutationBatch();
        if (result == .ok and current != .ok) {
            result = current;
        }
    }
    connection.transaction_databases.clearRetainingCapacity();
    connection.explicit_transaction = false;
    if (rollback) {
        if (connection.rollback_callback) |callback| callback(connection.rollback_context);
        return if (result == .ok) .ok else result;
    }
    if (result == .ok) {
        return doWalCallbacks(connection);
    }
    return result;
}

fn programActionCallback(context: ?*anyopaque, arguments: []vdbe.Mem, output: *vdbe.Mem, allocator: std.mem.Allocator) ResultCode {
    const owner: *Owner = @ptrCast(@alignCast(context orelse return .misuse));
    vdbe.vdbe_mem.setNull(output);
    return switch (owner.action orelse return .misuse) {
        .transaction => |action| switch (action.operation) {
            .begin => blk: {
                if (action.connection.explicit_transaction) break :blk .error_;
                action.connection.explicit_transaction = true;
                break :blk .ok;
            },
            .commit => finishExplicitTransaction(action.connection, false),
            .rollback => finishExplicitTransaction(action.connection, true),
        },
        .attach_database => |action| blk: {
            const attachments = ensureAttachmentCatalog(action.connection) catch break :blk .no_memory;
            attachment_runtime.attachFunction(attachments, action.filename, action.name) catch |failure| break :blk switch (failure) {
                error.OutOfMemory => .no_memory,
                error.TooMany => .error_,
                error.Duplicate => .error_,
                error.Open => .cannot_open,
                else => .error_,
            };
            break :blk .ok;
        },
        .detach_database => |action| blk: {
            const attachments = ensureAttachmentCatalog(action.connection) catch break :blk .no_memory;
            if (attachment_runtime.findDatabase(attachments, action.name)) |entry| {
                if (entry.native_context) |native| {
                    const attached: *AttachedDatabase = @ptrCast(@alignCast(native));
                    if (attached.active_blobs != 0 or attached.active_backups != 0) break :blk .error_;
                }
            }
            disconnectVirtualTablesInSchema(action.connection, action.name);
            attachment_runtime.detachFunction(attachments, action.name) catch |failure| break :blk switch (failure) {
                error.OutOfMemory => .no_memory,
                error.Locked => .busy,
                else => .error_,
            };
            break :blk .ok;
        },
        .virtual_create => |action| blk: {
            // Source `vtabCallConstructor()` installs the selected Db schema
            // name as argv[1] before invoking xCreate/xConnect.
            if (action.connection.virtual_table_state == null) {
                const state = action.connection.allocator.create(virtual_table_lifecycle.State) catch break :blk .no_memory;
                state.* = virtual_table_lifecycle.State.init(action.connection.allocator);
                action.connection.virtual_table_state = state;
            }
            const lifecycle_table = virtual_table_lifecycle.beginVirtualParse(action.connection.allocator, action.schema_name, action.name, action.module_name, @intCast(action.connection.limits[2])) catch |err| break :blk if (err == error.OutOfMemory) .no_memory else .error_;
            var lifecycle_adopted = false;
            defer if (!lifecycle_adopted) {
                lifecycle_table.deinit();
                action.connection.allocator.destroy(lifecycle_table);
            };
            action.connection.virtual_tables.ensureUnusedCapacity(action.connection.allocator, 1) catch break :blk .no_memory;
            var registered: ?@TypeOf(action.connection.modules.items[0]) = null;
            for (action.connection.modules.items) |module| {
                if (std.ascii.eqlIgnoreCase(module.name, action.module_name)) {
                    registered = module;
                    break;
                }
            }
            const module_entry = registered orelse break :blk .error_;
            const module: *const Module = @ptrCast(@alignCast(module_entry.module));
            const raw = module.xCreate orelse module.xConnect orelse break :blk .error_;
            const callback: *const fn (?*sqlite3, ?*anyopaque, c_int, [*]const [*:0]const u8, *?*sqlite3_vtab, *?[*:0]u8) callconv(.c) c_int = @ptrCast(@alignCast(raw));
            if (action.connection.vtab_declaration) |old| {
                action.connection.allocator.free(old);
                action.connection.vtab_declaration = null;
            }
            const schema_name = action.connection.allocator.dupeZ(u8, action.schema_name) catch break :blk .no_memory;
            var schema_name_adopted = false;
            defer if (!schema_name_adopted) {
                action.connection.allocator.free(schema_name);
            };
            const table_name = action.connection.allocator.dupeZ(u8, action.name) catch break :blk .no_memory;
            var table_name_adopted = false;
            defer if (!table_name_adopted) {
                action.connection.allocator.free(table_name);
            };
            const module_name = action.connection.allocator.dupeZ(u8, action.module_name) catch break :blk .no_memory;
            defer action.connection.allocator.free(module_name);
            const module_arguments = [_][*:0]const u8{ module_name.ptr, schema_name.ptr, table_name.ptr };
            var instance: ?*sqlite3_vtab = null;
            var error_message: ?[*:0]u8 = null;
            const rc = ResultCode.fromC(callback(toOpaque(action.connection), module_entry.auxiliary, module_arguments.len, &module_arguments, &instance, &error_message));
            if (error_message) |message| {
                public_api.sqlite3_free(message);
            }
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
            table.* = .{ .connection = action.connection, .schema_name = schema_name, .name = table_name, .module = module, .instance = instance.? };
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
                for (table.columns.items) |column| {
                    action.connection.allocator.free(column);
                }
                table.columns.deinit(action.connection.allocator);
                action.connection.allocator.destroy(table);
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk .no_memory;
            }
            virtual_table_lifecycle.finishVirtualParse(action.connection.virtual_table_state.?, lifecycle_table, owner.source) catch |err| {
                for (table.columns.items) |column| {
                    action.connection.allocator.free(column);
                }
                table.columns.deinit(action.connection.allocator);
                action.connection.allocator.destroy(table);
                if (module.xDisconnect) |disconnect_raw| {
                    const disconnect: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(disconnect_raw));
                    _ = disconnect(instance.?);
                }
                break :blk if (err == error.OutOfMemory) .no_memory else .error_;
            };
            lifecycle_adopted = true;
            action.connection.virtual_tables.appendAssumeCapacity(table);
            schema_name_adopted = true;
            table_name_adopted = true;
            break :blk .ok;
        },
        .virtual_drop => |action| blk: {
            var index: usize = 0;
            while (index < action.connection.virtual_tables.items.len) : (index += 1) {
                if (!virtualSchemaMatches(action.connection, action.connection.virtual_tables.items[index].schema_name, action.schema_name) or !std.ascii.eqlIgnoreCase(action.connection.virtual_tables.items[index].name, action.name)) {
                    continue;
                }
                const table = action.connection.virtual_tables.items[index];
                const raw = table.module.xDestroy orelse table.module.xDisconnect;
                if (raw) |callback_raw| {
                    const callback: *const fn (*sqlite3_vtab) callconv(.c) c_int = @ptrCast(@alignCast(callback_raw));
                    const rc = ResultCode.fromC(callback(table.instance));
                    if (rc != .ok) break :blk rc;
                }
                _ = action.connection.virtual_tables.orderedRemove(index);
                for (table.columns.items) |column| {
                    action.connection.allocator.free(column);
                }
                table.columns.deinit(action.connection.allocator);
                action.connection.allocator.free(table.schema_name);
                action.connection.allocator.free(table.name);
                action.connection.allocator.destroy(table);
                break :blk .ok;
            }
            break :blk .error_;
        },
        .create => |action| blk: {
            const database = action.database;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) {
                    _ = database.rollbackStatementBatch();
                }
            }
            const created = database.createSchemaTable(action.name, action.sql, action.if_not_exists);
            if (created != .ok) break :blk created;
            const committed = database.commitStatementBatch();
            batch_active = false;
            break :blk action.connection.afterWrite(committed, null, action.schema_name, action.name, 0);
        },
        .create_index => |action| blk: {
            const database = action.database;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) {
                    _ = database.rollbackStatementBatch();
                }
            }
            const created = database.createSchemaIndex(action.name, action.table_name, action.sql, action.table_root, owner.indices, action.integer_primary_key_position, owner.index_collations, owner.index_sort_orders, owner.index_transforms, action.predicate, action.unique, action.if_not_exists);
            if (created != .ok) break :blk created;
            const committed = database.commitStatementBatch();
            batch_active = false;
            break :blk action.connection.afterWrite(committed, null, action.schema_name, action.name, 0);
        },
        .drop => |action| blk: {
            std.debug.assert(action.connection.foreign_key_action_allocations.items.len == 0);
            defer clearForeignKeyActionAllocations(action.connection);
            const database = action.database;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) {
                    _ = database.rollbackStatementBatch();
                }
            }
            const cleared = dropTableForeignKeyActions(action.connection, database, action.schema_name, action.name);
            if (cleared != .ok) break :blk cleared;
            const dropped = database.dropSchemaTable(action.name, action.if_exists);
            if (dropped != .ok) break :blk dropped;
            const committed = database.commitStatementBatch();
            batch_active = false;
            break :blk action.connection.afterWrite(committed, null, action.schema_name, action.name, 0);
        },
        .drop_index => |action| blk: {
            const database = action.database;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) {
                    _ = database.rollbackStatementBatch();
                }
            }
            const dropped = database.dropSchemaIndex(action.name, action.if_exists);
            if (dropped != .ok) break :blk dropped;
            const committed = database.commitStatementBatch();
            batch_active = false;
            break :blk action.connection.afterWrite(committed, null, action.schema_name, action.name, 0);
        },
        .reindex => |action| blk: {
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            if (action.target == .collation or action.target == .expressions or action.target == .all) {
                const refilled = if (action.target == .all) reindexAllConnection(action.connection) else if (action.target == .expressions) reindexExpressionsConnection(action.connection) else reindexCollationConnection(action.connection, action.name);
                break :blk action.connection.afterWrite(refilled, null, action.schema_name, action.name, 0);
            }
            const enlisted = enlistTransactionDatabase(action.connection, action.database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = action.database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer if (batch_active) {
                _ = action.database.rollbackStatementBatch();
            };
            const refilled = switch (action.target) {
                .index => reindexSecondaryIndex(action.connection, action.database, action.name),
                .table => reindexTableIndexes(action.connection, action.database, action.name),
                .collation, .expressions, .all => unreachable,
            };
            if (refilled != .ok) break :blk refilled;
            const committed = action.database.commitStatementBatch();
            batch_active = false;
            break :blk action.connection.afterWrite(committed, null, action.schema_name, action.name, 0);
        },
        .vacuum => |action| blk: {
            const database = action.connection.database orelse break :blk .misuse;
            if (action.connection.autovacuum_callback) |callback| _ = callback(action.connection.autovacuum_context, "main", 0, 0, 4096);
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            break :blk action.connection.afterWrite(database.vacuumCompactNoop(), null, "main", "", 0);
        },
        .analyze => |action| runAnalyze(action.connection, action.table_name),
        .update => |action| blk: {
            std.debug.assert(action.connection.foreign_key_action_allocations.items.len == 0);
            defer clearForeignKeyActionAllocations(action.connection);
            const database = action.database;
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
            if (!foreignKeyOldValuesAvailable(action.foreign_key_old_mask, record.values.len)) break :blk .corrupt;
            if (action.target_column >= record.values.len) break :blk .corrupt;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) _ = database.rollbackStatementBatch();
            }
            const values = allocator.dupe(btree.Value, record.values) catch break :blk .no_memory;
            defer allocator.free(values);
            var new_rowid = rowid;
            if (action.target_integer_primary_key) {
                if (vdbe.vdbe_mem.valueType(&arguments[0]) != 1) break :blk .mismatch;
                new_rowid = vdbe.vdbe_mem.valueInt64(&arguments[0]);
                if (new_rowid != rowid) {
                    const destination = database.openCursor(action.root_page, .table);
                    if (destination.result != .ok) break :blk destination.result;
                    var destination_cursor = destination.cursor.?;
                    defer destination_cursor.deinit();
                    if (destination_cursor.seekTable(new_rowid)) break :blk .constraint;
                }
            } else {
                values[action.target_column] = memToBtreeValue(&arguments[0]) orelse break :blk .no_memory;
            }
            const parent_foreign_key_result = checkForeignKeys(action.connection, database, action.schema_name, action.table_name, rowid, .{ .parent_update = .{ .old_values = record.values, .new_rowid = new_rowid, .new_values = values } });
            if (parent_foreign_key_result != .ok) break :blk parent_foreign_key_result;
            const actions = applyForeignKeyActions(action.connection, database, action.schema_name, action.table_name, rowid, new_rowid, record.values, values, null);
            if (actions != .ok) break :blk actions;
            const child_foreign_key_result = checkForeignKeys(action.connection, database, action.schema_name, action.table_name, new_rowid, .{ .child_insert = .{ .values = values } });
            if (child_foreign_key_result != .ok) break :blk child_foreign_key_result;
            const payload = btree.encodeRecord(allocator, values) catch |err| break :blk if (err == error.OutOfMemory) .no_memory else .too_big;
            defer allocator.free(payload);
            if (new_rowid != rowid) {
                const deleted = database.deleteTable(action.root_page, rowid);
                if (deleted != .ok) break :blk deleted;
            }
            const rc = database.insertTable(action.root_page, new_rowid, payload, new_rowid == rowid);
            if (rc != .ok) break :blk rc;
            const indexed = maintainSecondaryIndexes(action.connection, database, action.table_name, .{ .rowid = rowid, .values = record.values }, .{ .rowid = new_rowid, .values = values });
            if (indexed != .ok) break :blk indexed;
            const committed = database.commitStatementBatch();
            batch_active = false;
            if (committed == .ok) {
                action.connection.changes = 1;
                action.connection.total_changes += 1;
            }
            break :blk action.connection.afterWrite(committed, 23, action.schema_name, action.table_name, new_rowid);
        },
        .delete => |action| blk: {
            std.debug.assert(action.connection.foreign_key_action_allocations.items.len == 0);
            defer clearForeignKeyActionAllocations(action.connection);
            const database = action.database;
            if (arguments.len != 1) break :blk .corrupt;
            if (vdbe.vdbe_mem.valueType(&arguments[0]) != 1) break :blk .mismatch;
            const rowid = vdbe.vdbe_mem.valueInt64(&arguments[0]);
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
            if (!foreignKeyOldValuesAvailable(action.foreign_key_old_mask, record.values.len)) break :blk .corrupt;
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) _ = database.rollbackStatementBatch();
            }
            const foreign_key_result = checkForeignKeys(action.connection, database, action.schema_name, action.table_name, rowid, .{ .parent_delete = .{ .old_values = record.values } });
            if (foreign_key_result != .ok) break :blk foreign_key_result;
            const actions = applyForeignKeyActions(action.connection, database, action.schema_name, action.table_name, rowid, rowid, record.values, null, null);
            if (actions != .ok) break :blk actions;
            const rc = database.deleteTable(action.root_page, rowid);
            if (rc == .not_found) {
                action.connection.changes = 0;
                break :blk .ok;
            }
            if (rc != .ok) break :blk rc;
            const indexed = maintainSecondaryIndexes(action.connection, database, action.table_name, .{ .rowid = rowid, .values = record.values }, null);
            if (indexed != .ok) break :blk indexed;
            const committed = database.commitStatementBatch();
            batch_active = false;
            if (committed == .ok) {
                action.connection.changes = 1;
                action.connection.total_changes += 1;
            }
            break :blk action.connection.afterWrite(committed, 9, action.schema_name, action.table_name, rowid);
        },
        .insert => |action| blk: {
            std.debug.assert(action.connection.foreign_key_action_allocations.items.len == 0);
            defer clearForeignKeyActionAllocations(action.connection);
            const database = action.database;
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
            const permission = action.connection.beforeWrite();
            if (permission != .ok) break :blk permission;
            const enlisted = enlistTransactionDatabase(action.connection, database);
            if (enlisted != .ok) break :blk enlisted;
            const begin = database.beginStatementBatch();
            if (begin != .ok) break :blk begin;
            var batch_active = true;
            defer {
                if (batch_active) _ = database.rollbackStatementBatch();
            }
            if (action.replace) {
                const existing = database.openCursor(action.root_page, .table);
                if (existing.result != .ok) break :blk existing.result;
                var existing_cursor = existing.cursor.?;
                if (existing_cursor.seekTable(rowid)) {
                    const decoded = existing_cursor.record();
                    if (decoded.result != .ok) {
                        existing_cursor.deinit();
                        break :blk decoded.result;
                    }
                    var old_record = decoded.record.?;
                    existing_cursor.deinit();
                    defer old_record.deinit();
                    const replaced = checkForeignKeys(action.connection, database, action.schema_name, action.table_name, rowid, .{ .parent_delete = .{ .old_values = old_record.values } });
                    if (replaced != .ok) break :blk replaced;
                    const actions = applyForeignKeyActions(action.connection, database, action.schema_name, action.table_name, rowid, rowid, old_record.values, null, null);
                    if (actions != .ok) break :blk actions;
                    const indexed = maintainSecondaryIndexes(action.connection, database, action.table_name, .{ .rowid = rowid, .values = old_record.values }, null);
                    if (indexed != .ok) break :blk indexed;
                } else {
                    existing_cursor.deinit();
                }
            }
            const foreign_key_result = checkForeignKeys(action.connection, database, action.schema_name, action.table_name, rowid, .{ .child_insert = .{ .values = values } });
            if (foreign_key_result != .ok) break :blk foreign_key_result;
            const payload = btree.encodeRecord(allocator, values) catch |err| break :blk if (err == error.OutOfMemory) .no_memory else .too_big;
            defer allocator.free(payload);
            const rc = database.insertTable(action.root_page, rowid, payload, action.replace);
            if (rc == .constraint and action.conflict_ignore) {
                const rolled_back = database.rollbackStatementBatch();
                batch_active = false;
                action.connection.changes = 0;
                break :blk rolled_back;
            }
            if (rc != .ok) break :blk rc;
            const indexed = maintainSecondaryIndexes(action.connection, database, action.table_name, null, .{ .rowid = rowid, .values = values });
            if (indexed != .ok) break :blk indexed;
            const committed = database.commitStatementBatch();
            batch_active = false;
            if (committed == .ok) {
                action.connection.changes = 1;
                action.connection.total_changes += 1;
                action.connection.last_insert_rowid = rowid;
            }
            break :blk action.connection.afterWrite(committed, 18, action.schema_name, action.table_name, rowid);
        },
    };
}

/// Bounded `sqlite3VtabCallDestroy()` path for a schema-qualified instance.
fn compileVirtualDrop(connection: *Connection, source: [:0]u8, consumed: usize, schema_name: []const u8, table_name: []const u8) CompileOutcome {
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
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = .{ .virtual_drop = .{ .connection = connection, .schema_name = schema_name, .name = table_name } }, .program = .{ .instructions = instructions, .register_count = 1 } };
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

/// Bounded `sqlite3VtabBeginParse()`/`sqlite3VtabFinishParse()` path. Preserve
/// the selected schema for constructor argv[1], duplicate detection, and drop.
fn compileVirtualSchema(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (token_list.len != 6 and token_list.len != 8) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    if (token_list[0].typ != tokens.tk_create or token_list[1].typ != tokens.tk_virtual or token_list[2].typ != tokens.tk_table or !schemaIdentifierToken(token_list[3])) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var schema_name: []const u8 = "main";
    var table_name = token_list[3].text;
    var using_position: usize = 4;
    if (token_list.len == 8) {
        if (token_list[4].typ != tokens.tk_dot or token_list[5].typ != tokens.tk_id) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        schema_name = table_name;
        table_name = token_list[5].text;
        using_position = 6;
    }
    if (token_list[using_position].typ != tokens.tk_using or token_list[using_position + 1].typ != tokens.tk_id) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const located_database = locateDatabase(connection, schema_name);
    if (located_database.result != .ok) {
        allocator.free(source);
        return .{ .result = if (located_database.result == .not_found) .error_ else located_database.result, .consumed = consumed };
    }
    if (findVirtualTable(connection, schema_name, table_name) != null) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const module_name = token_list[using_position + 1].text;
    var module_found = false;
    for (connection.modules.items) |module| {
        if (std.ascii.eqlIgnoreCase(module.name, module_name)) {
            module_found = true;
            break;
        }
    }
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
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = .{ .virtual_create = .{ .connection = connection, .schema_name = schema_name, .name = table_name, .module_name = module_name } }, .program = .{ .instructions = instructions, .register_count = 1 } };
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

/// Bounded source `sqlite3BeginTransaction()`/`sqlite3EndTransaction()` owner.
fn compileTransaction(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    const first = token_list[0].typ;
    const operation: TransactionOperation = if (first == tokens.tk_begin) .begin else if (first == tokens.tk_rollback) .rollback else .commit;
    var position: usize = 1;
    if (operation == .begin and position < token_list.len and (token_list[position].typ == tokens.tk_deferred or token_list[position].typ == tokens.tk_immediate or token_list[position].typ == tokens.tk_exclusive)) {
        position += 1;
    }
    if (position < token_list.len and token_list[position].typ == tokens.tk_transaction) {
        position += 1;
    }
    if (position != token_list.len) {
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
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = .{ .transaction = .{ .connection = connection, .operation = operation } }, .program = .{ .instructions = instructions, .register_count = 1 } };
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

/// Bounded application-defined subset of source `sqlite3CreateIndex()` and
/// `sqlite3RefillIndex()`: ordinary columns, optional schema-qualified index
/// name, optional IF NOT EXISTS, and ASC/DESC syntax.
fn compileIndexSchema(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    var position: usize = 1;
    const unique = position < token_list.len and token_list[position].typ == tokens.tk_unique;
    if (unique) {
        position += 1;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_index) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    position += 1;
    var if_not_exists = false;
    if (position + 2 < token_list.len and token_list[position].typ == tokens.tk_if and token_list[position + 1].typ == tokens.tk_not and token_list[position + 2].typ == tokens.tk_exists) {
        if_not_exists = true;
        position += 3;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_id) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var schema_name: ?[]const u8 = null;
    var index_name = token_list[position].text;
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_dot and token_list[position + 2].typ == tokens.tk_id) {
        schema_name = index_name;
        index_name = token_list[position + 2].text;
        position += 3;
    } else {
        position += 1;
    }
    if (position + 3 >= token_list.len or token_list[position].typ != tokens.tk_on or token_list[position + 1].typ != tokens.tk_id or token_list[position + 2].typ != tokens.tk_lp) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const table_name = token_list[position + 1].text;
    position += 3;
    var column_names = std.ArrayList([]const u8).empty;
    defer column_names.deinit(allocator);
    var specified_collations = std.ArrayList(?[]const u8).empty;
    defer specified_collations.deinit(allocator);
    var specified_sort_orders = std.ArrayList(btree.IndexSortOrder).empty;
    defer specified_sort_orders.deinit(allocator);
    var specified_transforms = std.ArrayList(btree.IndexTransform).empty;
    defer specified_transforms.deinit(allocator);
    while (true) {
        const wrapped_expression = position < token_list.len and token_list[position].typ == tokens.tk_lp;
        if (wrapped_expression) position += 1;
        var transform: btree.IndexTransform = .identity;
        var column_name: []const u8 = undefined;
        if (resolveNullOperatorIndexExpression(token_list, position)) |null_operator_expression| {
            transform = .constant_null;
            column_name = null_operator_expression.column_name;
            position += null_operator_expression.consumed;
        } else if (resolveConcatIndexExpression(token_list, position)) |concat_expression| {
            transform = if (concat_expression.constant_null) .constant_null else .concat_single;
            column_name = concat_expression.column_name;
            position += concat_expression.consumed;
        } else if (resolveReversedRealIndexExpression(token_list, position)) |reversed_real_expression| {
            transform = reversed_real_expression.transform;
            column_name = reversed_real_expression.column_name;
            position += reversed_real_expression.consumed;
        } else if (resolveReversedIntegerIndexExpression(token_list, position)) |reversed_expression| {
            transform = reversed_expression.transform;
            column_name = reversed_expression.column_name;
            position += reversed_expression.consumed;
        } else if (resolveBinaryMathIndexExpression(token_list, position)) |binary_math_expression| {
            transform = .{ .binary_math = .{ .operation = binary_math_expression.operation, .operand = binary_math_expression.operand, .column_first = binary_math_expression.column_first } };
            column_name = binary_math_expression.column_name;
            position += binary_math_expression.consumed;
        } else if (position + 3 < token_list.len and token_list[position].typ == tokens.tk_id and resolveUnaryMathIndexOperation(token_list[position].text) != null and token_list[position + 1].typ == tokens.tk_lp and token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_rp) {
            transform = .{ .unary_math = resolveUnaryMathIndexOperation(token_list[position].text).? };
            column_name = token_list[position + 2].text;
            position += 4;
        } else if (resolveRealMinMaxIndexExpression(token_list, position)) |real_min_max_expression| {
            transform = if (real_min_max_expression.maximum) .{ .scalar_max_real = .{ .comparison = real_min_max_expression.comparison, .column_first = real_min_max_expression.column_first } } else .{ .scalar_min_real = .{ .comparison = real_min_max_expression.comparison, .column_first = real_min_max_expression.column_first } };
            column_name = real_min_max_expression.column_name;
            position += real_min_max_expression.consumed;
        } else if (resolveMinMaxIndexExpression(token_list, position)) |min_max_expression| {
            transform = if (min_max_expression.maximum) .{ .scalar_max_integer = .{ .comparison = min_max_expression.comparison, .column_first = min_max_expression.column_first } } else .{ .scalar_min_integer = .{ .comparison = min_max_expression.comparison, .column_first = min_max_expression.column_first } };
            column_name = min_max_expression.column_name;
            position += min_max_expression.consumed;
        } else if (resolveNullSubstringIndexExpression(token_list, position)) |null_substring_expression| {
            transform = .constant_null;
            column_name = null_substring_expression.column_name;
            position += null_substring_expression.consumed;
        } else if (resolveSubstringIndexExpression(token_list, position)) |substring_expression| {
            transform = .{ .substring = .{ .start = substring_expression.start, .count = substring_expression.count } };
            column_name = substring_expression.column_name;
            position += substring_expression.consumed;
        } else if (resolveNullBinaryFunctionIndexExpression(token_list, position)) |null_expression| {
            transform = if (null_expression.constant_null) .constant_null else .identity;
            column_name = null_expression.column_name;
            position += null_expression.consumed;
        } else if (resolveRealIfnullIndexExpression(token_list, position)) |real_ifnull_expression| {
            transform = if (real_ifnull_expression.null_if)
                if (real_ifnull_expression.column_first) .{ .null_if_real = real_ifnull_expression.replacement } else .{ .reverse_null_if_real = real_ifnull_expression.replacement }
            else if (real_ifnull_expression.column_first)
                .{ .null_coalesce_real = real_ifnull_expression.replacement }
            else
                .{ .constant_real = real_ifnull_expression.replacement };
            column_name = real_ifnull_expression.column_name;
            position += real_ifnull_expression.consumed;
        } else if (resolveIfnullIndexExpression(token_list, position)) |ifnull_expression| {
            transform = if (ifnull_expression.null_if)
                if (ifnull_expression.column_first) .{ .null_if_integer = ifnull_expression.replacement } else .{ .reverse_null_if_integer = ifnull_expression.replacement }
            else if (ifnull_expression.column_first)
                .{ .null_coalesce_integer = ifnull_expression.replacement }
            else
                .{ .constant_integer = ifnull_expression.replacement };
            column_name = ifnull_expression.column_name;
            position += ifnull_expression.consumed;
        } else if (position + 5 < token_list.len and token_list[position].typ == tokens.tk_id and std.ascii.eqlIgnoreCase(token_list[position].text, "likelihood") and token_list[position + 1].typ == tokens.tk_lp and token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_comma and (token_list[position + 4].typ == tokens.tk_integer or token_list[position + 4].typ == tokens.tk_float) and token_list[position + 5].typ == tokens.tk_rp) {
            const probability = std.fmt.parseFloat(f64, token_list[position + 4].text) catch {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            };
            if (probability < 0 or probability > 1) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            column_name = token_list[position + 2].text;
            position += 6;
        } else if (position + 3 < token_list.len and token_list[position].typ == tokens.tk_id and (std.ascii.eqlIgnoreCase(token_list[position].text, "abs") or std.ascii.eqlIgnoreCase(token_list[position].text, "sign") or std.ascii.eqlIgnoreCase(token_list[position].text, "round") or std.ascii.eqlIgnoreCase(token_list[position].text, "ceil") or std.ascii.eqlIgnoreCase(token_list[position].text, "ceiling") or std.ascii.eqlIgnoreCase(token_list[position].text, "floor") or std.ascii.eqlIgnoreCase(token_list[position].text, "trunc") or std.ascii.eqlIgnoreCase(token_list[position].text, "typeof") or std.ascii.eqlIgnoreCase(token_list[position].text, "octet_length") or std.ascii.eqlIgnoreCase(token_list[position].text, "length") or std.ascii.eqlIgnoreCase(token_list[position].text, "unicode") or std.ascii.eqlIgnoreCase(token_list[position].text, "trim") or std.ascii.eqlIgnoreCase(token_list[position].text, "ltrim") or std.ascii.eqlIgnoreCase(token_list[position].text, "rtrim") or std.ascii.eqlIgnoreCase(token_list[position].text, "concat") or std.ascii.eqlIgnoreCase(token_list[position].text, "likely") or std.ascii.eqlIgnoreCase(token_list[position].text, "unlikely")) and token_list[position + 1].typ == tokens.tk_lp and token_list[position + 2].typ == tokens.tk_id and token_list[position + 3].typ == tokens.tk_rp) {
            transform = if (std.ascii.eqlIgnoreCase(token_list[position].text, "sign")) .numeric_sign else if (std.ascii.eqlIgnoreCase(token_list[position].text, "round")) .numeric_round else if (std.ascii.eqlIgnoreCase(token_list[position].text, "ceil") or std.ascii.eqlIgnoreCase(token_list[position].text, "ceiling")) .numeric_ceil else if (std.ascii.eqlIgnoreCase(token_list[position].text, "floor")) .numeric_floor else if (std.ascii.eqlIgnoreCase(token_list[position].text, "trunc")) .numeric_trunc else if (std.ascii.eqlIgnoreCase(token_list[position].text, "typeof")) .storage_type else if (std.ascii.eqlIgnoreCase(token_list[position].text, "octet_length")) .octet_length else if (std.ascii.eqlIgnoreCase(token_list[position].text, "length")) .text_length else if (std.ascii.eqlIgnoreCase(token_list[position].text, "unicode")) .unicode_value else if (std.ascii.eqlIgnoreCase(token_list[position].text, "trim")) .text_trim else if (std.ascii.eqlIgnoreCase(token_list[position].text, "ltrim")) .text_ltrim else if (std.ascii.eqlIgnoreCase(token_list[position].text, "rtrim")) .text_rtrim else if (std.ascii.eqlIgnoreCase(token_list[position].text, "concat")) .concat_single else if (std.ascii.eqlIgnoreCase(token_list[position].text, "likely") or std.ascii.eqlIgnoreCase(token_list[position].text, "unlikely")) .identity else .numeric_abs;
            column_name = token_list[position + 2].text;
            position += 4;
        } else {
            if (position < token_list.len and (token_list[position].typ == tokens.tk_plus or token_list[position].typ == tokens.tk_minus or token_list[position].typ == tokens.tk_bitnot or token_list[position].typ == tokens.tk_not)) {
                if (token_list[position].typ == tokens.tk_minus) {
                    transform = .numeric_negate;
                } else if (token_list[position].typ == tokens.tk_bitnot) {
                    transform = .integer_bit_not;
                } else if (token_list[position].typ == tokens.tk_not) {
                    transform = .numeric_not;
                }
                position += 1;
            }
            if (position >= token_list.len or token_list[position].typ != tokens.tk_id) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            column_name = token_list[position].text;
            position += 1;
        }
        column_names.append(allocator, column_name) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        if ((switch (transform) {
            .identity => true,
            else => false,
        }) and position < token_list.len and (token_list[position].typ == tokens.tk_isnull or token_list[position].typ == tokens.tk_notnull)) {
            transform = if (token_list[position].typ == tokens.tk_notnull) .is_not_null else .is_null;
            position += 1;
        }
        if ((switch (transform) {
            .identity => true,
            else => false,
        }) and position + 1 < token_list.len and token_list[position].typ == tokens.tk_is) {
            const is_suffix = resolveIndexIsSuffix(token_list, position + 1);
            const operand_position = position + 1 + is_suffix.consumed;
            if (operand_position < token_list.len and token_list[operand_position].typ == tokens.tk_null) {
                transform = if (is_suffix.is_not) .is_not_null else .is_null;
                position = operand_position + 1;
            } else if (resolveSignedFloatIndexOperand(token_list, operand_position)) |resolved_operand| {
                transform = .{ .real_is = .{ .value = resolved_operand.value, .is_not = is_suffix.is_not } };
                position = operand_position + resolved_operand.consumed;
            } else if (resolveSignedIndexOperand(token_list, operand_position)) |resolved_operand| {
                transform = .{ .integer_is = .{ .value = resolved_operand.value, .is_not = is_suffix.is_not } };
                position = operand_position + resolved_operand.consumed;
            }
        }
        if (switch (transform) {
            .identity => true,
            else => false,
        }) {
            if (resolveRealInIndexExpression(token_list, position)) |in_expression| {
                transform = .{ .real_in = .{ .first = in_expression.first, .second = in_expression.second, .is_not = in_expression.is_not } };
                position += in_expression.consumed;
            }
        }
        if (switch (transform) {
            .identity => true,
            else => false,
        }) {
            if (resolveIntegerInIndexExpression(token_list, position)) |in_expression| {
                transform = .{ .integer_in = .{ .first = in_expression.first, .second = in_expression.second, .is_not = in_expression.is_not } };
                position += in_expression.consumed;
            }
        }
        if (switch (transform) {
            .identity => true,
            else => false,
        }) {
            if (resolveRealBetweenIndexExpression(token_list, position)) |between_expression| {
                transform = .{ .real_between = .{ .low = between_expression.low, .high = between_expression.high, .is_not = between_expression.is_not } };
                position += between_expression.consumed;
            }
        }
        if (switch (transform) {
            .identity => true,
            else => false,
        }) {
            if (resolveIntegerBetweenIndexExpression(token_list, position)) |between_expression| {
                transform = .{ .integer_between = .{ .low = between_expression.low, .high = between_expression.high, .is_not = between_expression.is_not } };
                position += between_expression.consumed;
            }
        }
        if (switch (transform) {
            .identity => true,
            else => false,
        }) {
            if (resolveRealComparisonIndexExpression(token_list, position)) |real_comparison| {
                transform = real_comparison.transform;
                position += real_comparison.consumed;
            }
        }
        if ((switch (transform) {
            .identity => true,
            else => false,
        }) and position < token_list.len and (token_list[position].typ == tokens.tk_plus or token_list[position].typ == tokens.tk_minus or token_list[position].typ == tokens.tk_star or token_list[position].typ == tokens.tk_slash or token_list[position].typ == tokens.tk_rem or token_list[position].typ == tokens.tk_bitand or token_list[position].typ == tokens.tk_bitor or token_list[position].typ == tokens.tk_lshift or token_list[position].typ == tokens.tk_rshift or token_list[position].typ == tokens.tk_eq or token_list[position].typ == tokens.tk_ne or token_list[position].typ == tokens.tk_lt or token_list[position].typ == tokens.tk_le or token_list[position].typ == tokens.tk_gt or token_list[position].typ == tokens.tk_ge)) {
            if (resolveSignedIndexOperand(token_list, position + 1)) |resolved_operand| {
                var operand = resolved_operand.value;
                if (token_list[position].typ == tokens.tk_eq or token_list[position].typ == tokens.tk_ne or token_list[position].typ == tokens.tk_lt or token_list[position].typ == tokens.tk_le or token_list[position].typ == tokens.tk_gt or token_list[position].typ == tokens.tk_ge) {
                    const operation: btree.IndexComparisonOperation = switch (token_list[position].typ) {
                        tokens.tk_eq => .eq,
                        tokens.tk_ne => .ne,
                        tokens.tk_lt => .lt,
                        tokens.tk_le => .le,
                        tokens.tk_gt => .gt,
                        tokens.tk_ge => .ge,
                        else => unreachable,
                    };
                    transform = .{ .integer_compare = .{ .operation = operation, .value = operand } };
                } else if (token_list[position].typ == tokens.tk_star) {
                    transform = .{ .integer_multiply = operand };
                } else if (token_list[position].typ == tokens.tk_slash) {
                    transform = .{ .integer_divide = operand };
                } else if (token_list[position].typ == tokens.tk_rem) {
                    transform = .{ .integer_remainder = operand };
                } else if (token_list[position].typ == tokens.tk_bitand) {
                    transform = .{ .integer_bit_and = operand };
                } else if (token_list[position].typ == tokens.tk_bitor) {
                    transform = .{ .integer_bit_or = operand };
                } else if (token_list[position].typ == tokens.tk_lshift) {
                    transform = .{ .integer_shift_left = operand };
                } else if (token_list[position].typ == tokens.tk_rshift) {
                    transform = .{ .integer_shift_right = operand };
                } else {
                    if (token_list[position].typ == tokens.tk_minus) operand = -operand;
                    transform = .{ .integer_add = operand };
                }
                position += 1 + resolved_operand.consumed;
            }
        }
        if (wrapped_expression) {
            if (position >= token_list.len or token_list[position].typ != tokens.tk_rp) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            position += 1;
        }
        var specified_collation: ?[]const u8 = null;
        if (position < token_list.len and token_list[position].typ == tokens.tk_collate) {
            if (position + 1 >= token_list.len or token_list[position + 1].typ != tokens.tk_id) {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            }
            specified_collation = token_list[position + 1].text;
            position += 2;
        }
        specified_collations.append(allocator, specified_collation) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        var sort_order: btree.IndexSortOrder = .ascending;
        if (position < token_list.len and (token_list[position].typ == tokens.tk_asc or token_list[position].typ == tokens.tk_desc)) {
            sort_order = if (token_list[position].typ == tokens.tk_desc) .descending else .ascending;
            position += 1;
        }
        specified_sort_orders.append(allocator, sort_order) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        specified_transforms.append(allocator, transform) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        if (position < token_list.len and token_list[position].typ == tokens.tk_comma) {
            position += 1;
            continue;
        }
        break;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_rp) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    position += 1;
    if (position < token_list.len and token_list[position].typ != tokens.tk_where) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const located = locateTableWithDatabase(connection, table_name, schema_name);
    if (located.result != .ok) {
        allocator.free(source);
        return .{ .result = if (located.result == .not_found) .error_ else located.result, .consumed = consumed };
    }
    var table = located.table.?;
    defer table.deinit();
    const resolved = resolveColumns(allocator, table.sql) catch |err| {
        allocator.free(source);
        return .{ .result = if (err == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
    };
    defer {
        allocator.free(resolved.columns);
        allocator.free(resolved.tokens);
        allocator.free(resolved.source);
    }
    var selected_indices = std.ArrayList(usize).empty;
    defer selected_indices.deinit(allocator);
    var selected_collations = std.ArrayList(btree.IndexCollation).empty;
    defer selected_collations.deinit(allocator);
    var integer_primary_key_position: ?usize = null;
    for (column_names.items, 0..) |column_name, selected_position| {
        var found: ?usize = null;
        for (resolved.columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, column_name)) {
                found = index;
                if (column.integer_primary_key) integer_primary_key_position = selected_position;
                break;
            }
        }
        const selected = found orelse {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        };
        const numeric_transform = switch (specified_transforms.items[selected_position]) {
            .identity, .storage_type, .octet_length, .text_length, .unicode_value, .text_trim, .text_ltrim, .text_rtrim, .concat_single, .substring, .is_null, .is_not_null, .constant_null, .constant_integer, .constant_real, .null_coalesce_integer, .null_coalesce_real, .null_if_integer, .null_if_real, .reverse_null_if_integer, .reverse_null_if_real => false,
            .numeric_negate, .numeric_abs, .numeric_sign, .numeric_round, .numeric_ceil, .numeric_floor, .numeric_trunc, .numeric_not, .integer_bit_not, .integer_add, .integer_reverse_subtract, .integer_multiply, .integer_divide, .integer_reverse_divide, .integer_remainder, .integer_reverse_remainder, .integer_bit_and, .integer_bit_or, .integer_shift_left, .integer_shift_right, .integer_reverse_shift_left, .integer_reverse_shift_right, .integer_compare, .real_compare, .real_arithmetic, .real_is, .integer_is, .integer_between, .real_between, .integer_in, .real_in, .scalar_min_integer, .scalar_max_integer, .scalar_min_real, .scalar_max_real, .unary_math, .binary_math => true,
        };
        if (numeric_transform and !resolved.columns[selected].integer_primary_key and !std.ascii.eqlIgnoreCase(resolved.columns[selected].declared_type, "INTEGER")) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        if ((switch (specified_transforms.items[selected_position]) {
            .octet_length, .text_length, .unicode_value, .substring => true,
            else => false,
        }) and !std.ascii.eqlIgnoreCase(resolved.columns[selected].declared_type, "TEXT") and !std.ascii.eqlIgnoreCase(resolved.columns[selected].declared_type, "BLOB")) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        if ((switch (specified_transforms.items[selected_position]) {
            .text_trim, .text_ltrim, .text_rtrim, .concat_single => true,
            else => false,
        }) and !std.ascii.eqlIgnoreCase(resolved.columns[selected].declared_type, "TEXT")) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        selected_indices.append(allocator, selected) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        const collation_name = specified_collations.items[selected_position] orelse resolved.columns[selected].collation;
        selected_collations.append(allocator, indexCollation(connection, collation_name) orelse {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        };
    }
    const predicate = resolveIndexPredicate(token_list, resolved.columns) catch {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    };
    const owned_indices = selected_indices.toOwnedSlice(allocator) catch {
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const owned_collations = selected_collations.toOwnedSlice(allocator) catch {
        allocator.free(owned_indices);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const owned_sort_orders = specified_sort_orders.toOwnedSlice(allocator) catch {
        allocator.free(owned_collations);
        allocator.free(owned_indices);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const owned_transforms = specified_transforms.toOwnedSlice(allocator) catch {
        allocator.free(owned_sort_orders);
        allocator.free(owned_collations);
        allocator.free(owned_indices);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const owner = allocator.create(Owner) catch {
        allocator.free(owned_transforms);
        allocator.free(owned_sort_orders);
        allocator.free(owned_collations);
        allocator.free(owned_indices);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instructions = allocator.alloc(vdbe.Instruction, 2) catch {
        allocator.destroy(owner);
        allocator.free(owned_transforms);
        allocator.free(owned_sort_orders);
        allocator.free(owned_collations);
        allocator.free(owned_indices);
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
        .indices = owned_indices,
        .index_collations = owned_collations,
        .index_sort_orders = owned_sort_orders,
        .index_transforms = owned_transforms,
        .action = .{ .create_index = .{
            .connection = connection,
            .database = located.database.?,
            .schema_name = located.schema_name,
            .name = index_name,
            .table_name = table_name,
            .sql = source,
            .table_root = table.root_page,
            .integer_primary_key_position = integer_primary_key_position,
            .predicate = predicate,
            .unique = unique,
            .if_not_exists = if_not_exists,
        } },
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

fn compileReindexProgram(connection: *Connection, source: [:0]u8, consumed: usize, database: *btree.Database, schema_name: []const u8, name: []const u8, target: ReindexTarget) CompileOutcome {
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
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .action = .{ .reindex = .{ .connection = connection, .database = database, .schema_name = schema_name, .name = name, .target = target } }, .program = .{ .instructions = instructions, .register_count = 1 } };
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

fn compileReindex(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (token_list.len == 1) {
        const main = locateDatabase(connection, null);
        if (main.result != .ok) {
            allocator.free(source);
            return .{ .result = main.result, .consumed = consumed };
        }
        return compileReindexProgram(connection, source, consumed, main.database.?, "main", "", .all);
    }
    if (token_list.len != 2 and token_list.len != 4) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var requested_schema: ?[]const u8 = null;
    var index_name = token_list[1].text;
    if (token_list.len == 4) {
        if (token_list[1].typ != tokens.tk_id or token_list[2].typ != tokens.tk_dot or token_list[3].typ != tokens.tk_id) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
        requested_schema = index_name;
        index_name = token_list[3].text;
    } else if (token_list[1].typ != tokens.tk_id) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    if (requested_schema == null and std.ascii.eqlIgnoreCase(index_name, "EXPRESSIONS")) {
        const main = locateDatabase(connection, null);
        if (main.result != .ok) {
            allocator.free(source);
            return .{ .result = main.result, .consumed = consumed };
        }
        return compileReindexProgram(connection, source, consumed, main.database.?, "main", index_name, .expressions);
    }
    const located = locateIndexWithDatabase(connection, index_name, requested_schema);
    var database: *btree.Database = undefined;
    var schema_name: []const u8 = undefined;
    var target: ReindexTarget = .index;
    if (located.result == .ok) {
        database = located.database.?;
        schema_name = located.schema_name;
        var schema_index = located.index.?;
        schema_index.deinit();
    } else if (located.result == .not_found) {
        const table = locateTableWithDatabase(connection, index_name, requested_schema);
        if (table.result == .ok) {
            database = table.database.?;
            schema_name = table.schema_name;
            var schema_table = table.table.?;
            schema_table.deinit();
            target = .table;
        } else if (table.result == .not_found and requested_schema == null and indexCollation(connection, index_name) != null) {
            const main = locateDatabase(connection, null);
            if (main.result != .ok) {
                allocator.free(source);
                return .{ .result = main.result, .consumed = consumed };
            }
            database = main.database.?;
            schema_name = "main";
            target = .collation;
        } else {
            allocator.free(source);
            return .{ .result = if (table.result == .not_found) .error_ else table.result, .consumed = consumed };
        }
    } else {
        allocator.free(source);
        return .{ .result = located.result, .consumed = consumed };
    }
    return compileReindexProgram(connection, source, consumed, database, schema_name, index_name, target);
}

fn compileDropIndex(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    var position: usize = 2;
    var if_exists = false;
    if (position + 1 < token_list.len and token_list[position].typ == tokens.tk_if and token_list[position + 1].typ == tokens.tk_exists) {
        if_exists = true;
        position += 2;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_id) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    var requested_schema: ?[]const u8 = null;
    var index_name = token_list[position].text;
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_dot and token_list[position + 2].typ == tokens.tk_id) {
        requested_schema = index_name;
        index_name = token_list[position + 2].text;
        position += 3;
    } else {
        position += 1;
    }
    if (position != token_list.len) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const located_index = locateIndexWithDatabase(connection, index_name, requested_schema);
    var database: *btree.Database = undefined;
    var schema_name: []const u8 = undefined;
    if (located_index.result == .ok) {
        database = located_index.database.?;
        schema_name = located_index.schema_name;
        var schema_index = located_index.index.?;
        schema_index.deinit();
    } else if (located_index.result == .not_found) {
        const located_database = locateDatabase(connection, requested_schema);
        if (located_database.result != .ok) {
            allocator.free(source);
            return .{ .result = if (located_database.result == .not_found) .error_ else located_database.result, .consumed = consumed };
        }
        database = located_database.database.?;
        schema_name = requested_schema orelse "main";
    } else {
        allocator.free(source);
        return .{ .result = located_index.result, .consumed = consumed };
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
        .action = .{ .drop_index = .{ .connection = connection, .database = database, .schema_name = schema_name, .name = index_name, .if_exists = if_exists } },
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

fn compileSchema(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (token_list.len > 1 and token_list[0].typ == tokens.tk_create and token_list[1].typ == tokens.tk_virtual) return compileVirtualSchema(connection, source, token_list, consumed);
    if (token_list.len > 1 and token_list[0].typ == tokens.tk_create and (token_list[1].typ == tokens.tk_index or token_list[1].typ == tokens.tk_unique)) return compileIndexSchema(connection, source, token_list, consumed);
    if (token_list[0].typ == tokens.tk_reindex) return compileReindex(connection, source, token_list, consumed);
    if (token_list.len > 1 and token_list[0].typ == tokens.tk_drop and token_list[1].typ == tokens.tk_index) return compileDropIndex(connection, source, token_list, consumed);
    if ((token_list.len == 3 or token_list.len == 5) and token_list[0].typ == tokens.tk_drop and token_list[1].typ == tokens.tk_table and schemaIdentifierToken(token_list[2])) {
        var virtual_schema_name: []const u8 = "main";
        var virtual_table_name = token_list[2].text;
        if (token_list.len == 5) {
            if (token_list[3].typ == tokens.tk_dot and token_list[4].typ == tokens.tk_id) {
                virtual_schema_name = virtual_table_name;
                virtual_table_name = token_list[4].text;
            }
        }
        if (findVirtualTable(connection, virtual_schema_name, virtual_table_name) != null) {
            return compileVirtualDrop(connection, source, consumed, virtual_schema_name, virtual_table_name);
        }
    }
    var position: usize = 0;
    const creating = token_list[position].typ == tokens.tk_create;
    const dropping = token_list[position].typ == tokens.tk_drop;
    if (!creating and !dropping) unreachable;
    position += 1;
    var temporary = false;
    if (creating and position < token_list.len and token_list[position].typ == tokens.tk_temp) {
        temporary = true;
        position += 1;
    }
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
    if (position >= token_list.len or !schemaIdentifierToken(token_list[position])) {
        const offset = if (position < token_list.len) token_list[position].start else source.len;
        allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = consumed };
    }
    var schema_name: []const u8 = if (temporary) "temp" else "main";
    var name = token_list[position].text;
    var name_start = token_list[position].start;
    var qualified = false;
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_dot and token_list[position + 2].typ == tokens.tk_id) {
        schema_name = name;
        name = token_list[position + 2].text;
        name_start = token_list[position + 2].start;
        position += 3;
        qualified = true;
        if (temporary and !std.ascii.eqlIgnoreCase(schema_name, "temp")) {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        }
    } else {
        position += 1;
    }
    if (dropping and !qualified) {
        if (connection.temp_database) |temporary_database| {
            if (temporary_database.database) |*temporary_btree| {
                const exists = temporary_btree.schemaTableExists(name);
                if (exists.result != .ok) {
                    allocator.free(source);
                    return .{ .result = exists.result, .consumed = consumed };
                }
                if (exists.found) {
                    schema_name = "temp";
                }
            }
        }
    }
    const located_database = locateDatabase(connection, schema_name);
    if (located_database.result != .ok) {
        allocator.free(source);
        return .{ .result = if (located_database.result == .not_found) .error_ else located_database.result, .consumed = consumed };
    }
    const database = located_database.database.?;
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
    const existence = database.schemaTableExists(name);
    if (existence.result != .ok) {
        allocator.free(source);
        return .{ .result = existence.result, .consumed = consumed };
    }
    if ((creating and existence.found and !conditional) or (dropping and !existence.found and !conditional)) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const normalized_sql: ?[]u8 = if (creating and (qualified or temporary))
        std.fmt.allocPrint(allocator, "CREATE TABLE {s}", .{source[name_start..token_list[token_list.len - 1].end]}) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        }
    else
        null;
    var normalized_adopted = false;
    defer if (!normalized_adopted) {
        if (normalized_sql) |sql| {
            allocator.free(sql);
        }
    };
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
            .{ .create = .{ .connection = connection, .database = database, .schema_name = schema_name, .name = name, .sql = if (normalized_sql) |sql| sql else std.mem.trim(u8, source[0..token_list[token_list.len - 1].end], " \t\r\n"), .if_not_exists = conditional } }
        else
            .{ .drop = .{ .connection = connection, .database = database, .schema_name = schema_name, .name = name, .if_exists = conditional } },
        .program = .{ .instructions = instructions, .register_count = 1 },
    };
    if (normalized_sql) |sql| {
        owner.strings.append(allocator, sql) catch {
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        };
        normalized_adopted = true;
    }
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
    var position: usize = 1;
    var replace = false;
    if (position + 1 < token_list.len and token_list[position].typ == tokens.tk_or and token_list[position + 1].typ == tokens.tk_replace) {
        replace = true;
        position += 2;
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_into) return error.Syntax;
    position += 1;
    if (position >= token_list.len or !schemaIdentifierToken(token_list[position])) return error.Syntax;
    var requested_schema: ?[]const u8 = null;
    var table_name = token_list[position].text;
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_dot and token_list[position + 2].typ == tokens.tk_id) {
        requested_schema = table_name;
        table_name = token_list[position + 2].text;
        position += 3;
    } else {
        position += 1;
    }
    const located = locateTableWithDatabase(connection, table_name, requested_schema);
    if (located.result == .no_memory) return error.OutOfMemory;
    if (located.result != .ok) return error.Syntax;
    const database = located.database.?;
    const schema_name = located.schema_name;
    var schema = located.table.?;
    defer schema.deinit();
    const resolved = try resolveColumns(allocator, schema.sql);
    defer {
        allocator.free(resolved.columns);
        allocator.free(resolved.tokens);
        allocator.free(resolved.source);
    }
    var mappings = std.ArrayList(usize).empty;
    defer mappings.deinit(allocator);
    if (position < token_list.len and token_list[position].typ == tokens.tk_lp) {
        position += 1;
        while (true) {
            if (position >= token_list.len or token_list[position].typ != tokens.tk_id) return error.Syntax;
            var found: ?usize = null;
            for (resolved.columns, 0..) |column, index| {
                if (std.ascii.eqlIgnoreCase(column.name, token_list[position].text)) {
                    found = index;
                    break;
                }
            }
            const column_index = found orelse return error.Syntax;
            for (mappings.items) |prior| {
                if (prior == column_index) return error.Syntax;
            }
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
        for (resolved.columns, 0..) |_, index| {
            try mappings.append(allocator, index);
        }
    }
    if (position >= token_list.len or token_list[position].typ != tokens.tk_values) return error.Syntax;
    position += 1;
    if (position >= token_list.len or token_list[position].typ != tokens.tk_lp) return error.Syntax;
    position += 1;
    const scanned = try scanParameters(allocator, token_list);
    var parser = Parser.init(allocator, source, token_list, scanned.maximum, null);
    var parser_live = true;
    defer if (parser_live) {
        parser.deinitFailure();
    };
    parser.parameter_names.appendSlice(allocator, scanned.names) catch {
        allocator.free(scanned.names);
        var owned = scanned.owned;
        for (owned.items) |name| {
            allocator.free(name);
        }
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
        if (parser.accept(tokens.tk_comma)) {
            continue;
        }
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
    for (parameters, 0..) |*parameter, index| {
        parameter.* = .{ .name = parser.parameter_names.items[index] };
    }
    const columns = try allocator.alloc(statement.ColumnMetadata, 0);
    errdefer allocator.free(columns);
    const indices = try allocator.dupe(usize, mappings.items);
    errdefer allocator.free(indices);
    var integer_primary_key: ?usize = null;
    for (resolved.columns, 0..) |column, index| {
        if (column.integer_primary_key) {
            integer_primary_key = index;
            break;
        }
    }
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
        .action = .{ .insert = .{ .connection = connection, .database = database, .schema_name = schema_name, .root_page = schema.root_page, .table_name = table_name, .column_count = resolved.columns.len, .integer_primary_key = integer_primary_key, .replace = replace, .conflict_ignore = conflict_ignore } },
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
    var position: usize = 1;
    if (!updating) {
        if (position >= token_list.len or token_list[position].typ != tokens.tk_from) return error.Syntax;
        position += 1;
    }
    if (position >= token_list.len or !schemaIdentifierToken(token_list[position])) return error.Syntax;
    var requested_schema: ?[]const u8 = null;
    var table_name = token_list[position].text;
    if (position + 2 < token_list.len and token_list[position + 1].typ == tokens.tk_dot and token_list[position + 2].typ == tokens.tk_id) {
        requested_schema = table_name;
        table_name = token_list[position + 2].text;
        position += 3;
    } else {
        position += 1;
    }
    const located = locateTableWithDatabase(connection, table_name, requested_schema);
    if (located.result == .no_memory) return error.OutOfMemory;
    if (located.result != .ok) return error.Syntax;
    const database = located.database.?;
    const schema_name = located.schema_name;
    var schema = located.table.?;
    defer schema.deinit();
    const resolved = try resolveColumns(allocator, schema.sql);
    defer {
        allocator.free(resolved.columns);
        allocator.free(resolved.tokens);
        allocator.free(resolved.source);
    }
    const old_mask = foreignKeyOldMask(connection, database, table_name, resolved.columns, resolved.tokens);
    if (old_mask.result == .no_memory) return error.OutOfMemory;
    if (old_mask.result != .ok) return error.Syntax;
    var primary_key: ?usize = null;
    for (resolved.columns, 0..) |column, index| {
        if (column.integer_primary_key) {
            primary_key = index;
            break;
        }
    }
    const pk = primary_key orelse return error.Syntax;
    var target_column: usize = 0;
    if (updating) {
        if (position >= token_list.len or token_list[position].typ != tokens.tk_set) return error.Syntax;
        position += 1;
        if (position >= token_list.len or token_list[position].typ != tokens.tk_id) return error.Syntax;
        var found: ?usize = null;
        for (resolved.columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, token_list[position].text)) {
                found = index;
                break;
            }
        }
        target_column = found orelse return error.Syntax;
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
    defer if (parser_live) {
        parser.deinitFailure();
    };
    parser.parameter_names.appendSlice(allocator, scanned.names) catch {
        allocator.free(scanned.names);
        var owned = scanned.owned;
        for (owned.items) |name| {
            allocator.free(name);
        }
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
    for (parameters, 0..) |*parameter, index| {
        parameter.* = .{ .name = parser.parameter_names.items[index] };
    }
    const columns = try allocator.alloc(statement.ColumnMetadata, 0);
    errdefer allocator.free(columns);
    parser.parameter_names.deinit(allocator);
    parser.parameter_names = .empty;
    parser.named_parameters.deinit();
    parser.named_parameters = std.StringHashMap(u16).init(allocator);
    owner.* = .{ .source = source, .instructions = instructions, .parameters = parameters, .columns = columns, .strings = parser.strings, .names = parser.names, .action = if (updating) .{ .update = .{ .connection = connection, .database = database, .schema_name = schema_name, .root_page = schema.root_page, .table_name = table_name, .target_column = target_column, .target_integer_primary_key = resolved.columns[target_column].integer_primary_key, .foreign_key_old_mask = old_mask.mask } } else .{ .delete = .{ .connection = connection, .database = database, .schema_name = schema_name, .root_page = schema.root_page, .table_name = table_name, .foreign_key_old_mask = old_mask.mask } }, .program = .{ .instructions = instructions, .register_count = parser.next_register - 1 } };
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
            else => .error_,
        }, .consumed = consumed };
    };
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn decodeAttachmentToken(allocator: std.mem.Allocator, token: Token) error{ OutOfMemory, Syntax }![]u8 {
    if (token.typ == tokens.tk_id) return allocator.dupe(u8, token.text) catch error.OutOfMemory;
    if (token.typ != tokens.tk_string or token.text.len < 2) return error.Syntax;
    var decoded = std.ArrayList(u8).empty;
    defer decoded.deinit(allocator);
    var index: usize = 1;
    while (index + 1 < token.text.len) : (index += 1) {
        if (token.text[index] == '\'' and index + 1 < token.text.len - 1 and token.text[index + 1] == '\'') index += 1;
        decoded.append(allocator, token.text[index]) catch return error.OutOfMemory;
    }
    return decoded.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn compileAttachment(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    const attaching = token_list[0].typ == tokens.tk_attach;
    var position: usize = 1;
    if (position < token_list.len and token_list[position].typ == tokens.tk_database) position += 1;
    const filename_token: ?Token = if (attaching and position < token_list.len) token_list[position] else null;
    if (attaching) position += 1;
    if (attaching and (position >= token_list.len or token_list[position].typ != tokens.tk_as)) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    if (attaching) position += 1;
    if (position >= token_list.len or position + 1 != token_list.len) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const name = decodeAttachmentToken(allocator, token_list[position]) catch |failure| {
        allocator.free(source);
        return .{ .result = if (failure == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
    };
    var filename: ?[]u8 = null;
    if (filename_token) |token| {
        filename = decodeAttachmentToken(allocator, token) catch |failure| {
            allocator.free(name);
            allocator.free(source);
            return .{ .result = if (failure == error.OutOfMemory) .no_memory else .error_, .consumed = consumed };
        };
    }
    const owner = allocator.create(Owner) catch {
        if (filename) |value| allocator.free(value);
        allocator.free(name);
        allocator.free(source);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    const instructions = allocator.alloc(vdbe.Instruction, 2) catch {
        allocator.destroy(owner);
        if (filename) |value| allocator.free(value);
        allocator.free(name);
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
        .action = if (attaching)
            .{ .attach_database = .{ .connection = connection, .filename = filename.?, .name = name } }
        else
            .{ .detach_database = .{ .connection = connection, .name = name } },
        .program = .{ .instructions = instructions, .register_count = 1 },
    };
    owner.strings.append(allocator, name) catch {
        if (filename) |value| allocator.free(value);
        allocator.free(name);
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
    };
    if (filename) |value| owner.strings.append(allocator, value) catch {
        allocator.free(value);
        Owner.destroy(allocator, owner);
        return .{ .result = .no_memory, .consumed = consumed };
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

fn compileAnalyze(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    if (connection.database == null or token_list.len > 4 or
        (token_list.len == 2 and token_list[1].typ != tokens.tk_id) or
        (token_list.len > 2 and (token_list.len != 4 or token_list[1].typ != tokens.tk_id or token_list[2].typ != tokens.tk_dot or token_list[3].typ != tokens.tk_id)))
    {
        allocator.free(source);
        return .{ .result = if (connection.database == null) .misuse else .error_, .consumed = consumed };
    }
    const table_name: ?[]const u8 = if (token_list.len == 1 or
        (token_list.len == 2 and std.ascii.eqlIgnoreCase(token_list[1].text, "main")))
        null
    else if (token_list.len == 2)
        token_list[1].text
    else if (std.ascii.eqlIgnoreCase(token_list[1].text, "main"))
        token_list[3].text
    else {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    };
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
        .action = .{ .analyze = .{ .connection = connection, .table_name = table_name } },
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

fn evaluateSingleRowWindow(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?i32 {
    const function: query_execution.WindowFunction = if (std.ascii.eqlIgnoreCase(name, "row_number"))
        .row_number
    else if (std.ascii.eqlIgnoreCase(name, "dense_rank"))
        .dense_rank
    else if (std.ascii.eqlIgnoreCase(name, "rank"))
        .rank
    else if (std.ascii.eqlIgnoreCase(name, "percent_rank"))
        .percent_rank
    else if (std.ascii.eqlIgnoreCase(name, "cume_dist"))
        .cume_dist
    else
        return null;
    const rows = [_]query_execution.WindowRow{.{ .values = &.{} }};
    const values = query_execution.codeWindowStep(allocator, &rows, .{ .function = function }) catch return error.OutOfMemory;
    defer allocator.free(values);
    return switch (values[0]) {
        .integer => |value| std.math.cast(i32, value),
        .real => |value| if (std.math.isFinite(value) and value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) @intFromFloat(value) else null,
        else => null,
    };
}

fn compileAdvanced(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    const allocator = connection.allocator;
    const is_vacuum = token_list.len == 1 and token_list[0].typ == tokens.tk_vacuum;
    const is_pragma = token_list.len == 2 and token_list[0].typ == tokens.tk_pragma and token_list[1].typ == tokens.tk_id and pragma_runtime.locatePragma(token_list[1].text) != null;
    const window_value = if (token_list.len == 7 and token_list[0].typ == tokens.tk_select and token_list[1].typ == tokens.tk_id and token_list[2].typ == tokens.tk_lp and token_list[3].typ == tokens.tk_rp and token_list[4].typ == tokens.tk_over and token_list[5].typ == tokens.tk_lp and token_list[6].typ == tokens.tk_rp)
        evaluateSingleRowWindow(allocator, token_list[1].text) catch {
            allocator.free(source);
            return .{ .result = .no_memory, .consumed = consumed };
        }
    else
        null;
    const is_window = window_value != null;
    if (!is_vacuum and !is_pragma and !is_window) {
        allocator.free(source);
        return .{ .result = .error_, .consumed = consumed };
    }
    const database = connection.database orelse {
        allocator.free(source);
        return .{ .result = .misuse, .consumed = consumed };
    };
    var value: i32 = window_value orelse 1;
    var pragma_definition: ?*const pragma_runtime.Definition = null;
    if (is_pragma) {
        pragma_definition = pragma_runtime.locatePragma(token_list[1].text).?;
        if (pragma_definition.?.kind == .user_version) {
            const read = database.userVersion();
            if (read.result != .ok) {
                allocator.free(source);
                return .{ .result = read.result, .consumed = consumed };
            }
            connection.pragma_state.user_version = read.value;
        } else if (pragma_definition.?.kind == .page_count) {
            connection.pragma_state.page_count = database.declared_pages;
        }
        const result = pragma_runtime.executePragma(&connection.pragma_state, .{ .name = token_list[1].text }) catch {
            allocator.free(source);
            return .{ .result = .error_, .consumed = consumed };
        };
        value = switch (result.values[0]) {
            .integer => |integer| std.math.cast(i32, integer) orelse {
                allocator.free(source);
                return .{ .result = .too_big, .consumed = consumed };
            },
            .text => {
                allocator.free(source);
                return .{ .result = .error_, .consumed = consumed };
            },
        };
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
        const window_name = if (is_window) std.fmt.allocPrint(allocator, "{s}() OVER ()", .{token_list[1].text}) catch {
            Owner.destroy(allocator, owner);
            return .{ .result = .no_memory, .consumed = consumed };
        } else null;
        defer if (window_name) |name| allocator.free(name);
        const name = allocator.dupeZ(u8, if (pragma_definition) |definition| definition.column_names[0] else window_name.?) catch {
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

fn createExplainStatement(allocator: std.mem.Allocator, source: [:0]u8, program: *const vdbe.Program) !*statement.Statement {
    const rows = try vdbe_explain.list(allocator, program);
    defer vdbe_explain.deinitRows(allocator, rows);
    var parser = Parser.init(allocator, source, &.{}, 0, null);
    errdefer parser.deinitFailure();
    parser.next_register = 9;
    for (rows) |row| {
        const address = std.math.cast(i32, row.address) orelse return error.TooBig;
        const opcode = try parser.ownBytes(row.opcode);
        const p4 = try parser.ownBytes(row.p4);
        try parser.emit(.{ .opcode = .integer, .p1 = address, .p2 = 1 });
        try parser.emit(.{ .opcode = .string, .p2 = 2, .p4 = .{ .bytes = opcode } });
        try parser.emit(.{ .opcode = .integer, .p1 = row.p1, .p2 = 3 });
        try parser.emit(.{ .opcode = .integer, .p1 = row.p2, .p2 = 4 });
        try parser.emit(.{ .opcode = .integer, .p1 = row.p3, .p2 = 5 });
        try parser.emit(.{ .opcode = .string, .p2 = 6, .p4 = .{ .bytes = p4 } });
        try parser.emit(.{ .opcode = .integer, .p1 = row.p5, .p2 = 7 });
        try parser.emit(.{ .opcode = .null_, .p2 = 8 });
        try parser.emit(.{ .opcode = .result_row, .p1 = 1, .p2 = 8 });
    }
    try parser.emit(.{ .opcode = .halt });

    const owner = try allocator.create(Owner);
    var transferred = false;
    errdefer {
        if (!transferred) allocator.destroy(owner);
    }
    const instructions = try parser.instructions.toOwnedSlice(allocator);
    parser.instructions = .empty;
    errdefer {
        if (!transferred) allocator.free(instructions);
    }
    const parameters = try allocator.alloc(statement.ParameterMetadata, 0);
    errdefer {
        if (!transferred) allocator.free(parameters);
    }
    const columns = try allocator.alloc(statement.ColumnMetadata, 8);
    errdefer {
        if (!transferred) allocator.free(columns);
    }
    const column_names = [_][]const u8{ "addr", "opcode", "p1", "p2", "p3", "p4", "p5", "comment" };
    for (columns, column_names) |*column, name| {
        column.* = .{ .name = try parser.ownName(name) };
    }
    const dynamic_functions = try parser.functions.toOwnedSlice(allocator);
    parser.functions = .empty;
    errdefer {
        if (!transferred) allocator.free(dynamic_functions);
    }
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
        .dynamic_functions = dynamic_functions,
        .program = .{ .instructions = instructions, .register_count = 8, .functions = dynamic_functions },
    };
    parser.strings = .empty;
    parser.names = .empty;
    transferred = true;
    const prepared = statement.Statement.create(allocator, &owner.program, parameters, columns) catch |err| {
        for (owner.strings.items) |bytes| allocator.free(bytes);
        owner.strings.deinit(allocator);
        for (owner.names.items) |name| allocator.free(name);
        owner.names.deinit(allocator);
        allocator.free(owner.instructions);
        allocator.free(owner.parameters);
        allocator.free(owner.columns);
        allocator.free(owner.dynamic_functions);
        allocator.destroy(owner);
        return err;
    };
    parser.deinitFailure();
    prepared.adoptOwner(owner, Owner.destroy);
    return prepared;
}

fn compileExplain(connection: *Connection, source: [:0]u8, token_list: []const Token, consumed: usize) CompileOutcome {
    if (token_list.len < 2 or token_list[1].typ == tokens.tk_query) {
        const offset = if (token_list.len < 2) source.len else token_list[1].start;
        connection.allocator.free(source);
        return .{ .result = .error_, .error_offset = @intCast(offset), .consumed = consumed };
    }
    const inner = compile(connection, source[token_list[1].start..]);
    const explained = inner.statement orelse {
        connection.allocator.free(source);
        return .{ .result = inner.result, .error_offset = inner.error_offset, .consumed = consumed };
    };
    defer _ = statement.sqlite3_finalize(statement.toOpaque(explained));
    const prepared = createExplainStatement(connection.allocator, source, explained.vm.program) catch |err| {
        connection.allocator.free(source);
        return .{ .result = if (err == error.TooBig) .too_big else .no_memory, .consumed = consumed };
    };
    return .{ .result = .ok, .statement = prepared, .consumed = consumed };
}

fn ensureSchemaModel(connection: *Connection) ResultCode {
    const database = connection.database orelse return .ok;
    const version = database.schemaVersion();
    if (version.result != .ok) return version.result;
    const model = &connection.schema_model;
    if (model.loaded and schema_initialization.validateSchemaCookies(&.{model}, &.{version.value})) return .ok;
    var known_ok = false;
    const metadata = schema_initialization.Metadata{
        .schema_cookie = version.value,
        .file_format = 1,
        .cache_size = -2000,
        .encoding = 1,
        .maximum_page = database.declared_pages,
    };
    const no_rows: []const schema_initialization.CatalogRow = &.{};
    schema_initialization.readSchema(&.{model}, &.{metadata}, &.{no_rows}, false, &known_ok) catch |err| return switch (err) {
        error.OutOfMemory => .no_memory,
        error.Corrupt => .corrupt,
        else => .error_,
    };
    return if (known_ok) .ok else .error_;
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
    if (tokenized.tokens[0].typ == tokens.tk_explain)
        return compileExplain(connection, source, tokenized.tokens, tokenized.consumed);
    const schema_result = ensureSchemaModel(connection);
    if (schema_result != .ok) {
        allocator.free(source);
        return .{ .result = schema_result, .consumed = tokenized.consumed };
    }
    if (tokenized.tokens[0].typ == tokens.tk_attach or tokenized.tokens[0].typ == tokens.tk_detach)
        return compileAttachment(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_begin or tokenized.tokens[0].typ == tokens.tk_commit or tokenized.tokens[0].typ == tokens.tk_end or tokenized.tokens[0].typ == tokens.tk_rollback)
        return compileTransaction(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_analyze)
        return compileAnalyze(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_pragma or tokenized.tokens[0].typ == tokens.tk_vacuum or
        (tokenized.tokens[0].typ == tokens.tk_select and tokenized.tokens.len > 1 and tokenized.tokens[1].typ == tokens.tk_id and schema_program_runtime.singleRowWindowValue(tokenized.tokens[1].text) != null))
        return compileAdvanced(connection, source, tokenized.tokens, tokenized.consumed);
    if (tokenized.tokens[0].typ == tokens.tk_create or tokenized.tokens[0].typ == tokens.tk_drop or tokenized.tokens[0].typ == tokens.tk_reindex)
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
    const bounded_sql = sql[0..length];
    const has_sql = std.mem.trim(u8, bounded_sql, " \t\r\n;").len != 0;
    connection.connection_mutex.enter();
    defer connection.connection_mutex.leave();
    if (has_sql and connection.pending_deserialize_readonly != null) {
        const open_result = openPendingDeserializedDatabase(connection);
        if (open_result != .ok) {
            connection.last_result = open_result;
            return open_result.toC();
        }
    }
    if (has_sql) {
        connection.prepare_state.max_sql = @intCast(@max(connection.limits[1], 0));
        _ = query_compiler.lockAndPrepare(&connection.prepare_state, bounded_sql, false) catch |err| {
            connection.last_result = if (err == error.TooBig) .too_big else .error_;
            connection.error_offset = 0;
            if (tail_output) |tail| tail.* = sql;
            return connection.last_result.toC();
        };
    }
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
        prepared.setResultMask(&connection.error_mask);
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
    const maximum: ?usize = if (byte_count < 0) null else @intCast(byte_count & ~@as(c_int, 1));
    var length: usize = 0;
    while ((maximum == null or length < maximum.?) and (bytes[length] != 0 or bytes[length + 1] != 0)) : (length += 2) {}
    const utf8 = utf16NativeToUtf8(connection.allocator, bytes[0..length]) catch return ResultCode.no_memory.toC();
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
        while (iterator.nextCodepoint()) |codepoint| {
            unit_count += if (codepoint > 0xffff) 2 else 1;
        }
        tail.* = @ptrCast(bytes + unit_count * 2);
    }
    return rc;
}

/// Source `sqlite3_prepare16()`.
fn prepare16Legacy(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) c_int {
    return prepareUtf16(database, sql, byte_count, output, tail, 0);
}

pub export fn sqlite3_prepare16(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepare16Legacy(database, sql, byte_count, output, tail);
}

/// Source `sqlite3_prepare16_v2()`.
fn prepare16Saved(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) c_int {
    return prepareUtf16(database, sql, byte_count, output, tail, 0);
}

pub export fn sqlite3_prepare16_v2(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepare16Saved(database, sql, byte_count, output, tail);
}

/// Source `sqlite3_prepare16_v3()`.
fn prepare16WithFlags(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, flags: u32, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) c_int {
    return prepareUtf16(database, sql, byte_count, output, tail, flags & 0x0f);
}

pub export fn sqlite3_prepare16_v3(database: ?*sqlite3, sql: ?*const anyopaque, byte_count: c_int, flags: u32, output: ?*?*statement.sqlite3_stmt, tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepare16WithFlags(database, sql, byte_count, flags, output, tail);
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
    try std.testing.expectEqual(@as(c_int, 1_000_000_000), sqlite3_limit(toOpaque(connection), 1, 8));
    try std.testing.expectEqual(ResultCode.too_big.toC(), sqlite3_prepare_v2(toOpaque(connection), "SELECT 123", -1, &prepared, null));
    try std.testing.expectEqual(@as(c_int, 8), sqlite3_limit(toOpaque(connection), 1, 1_000_000_000));
}

test "EXPLAIN lists bounded VDBE instructions" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), "EXPLAIN SELECT 1+2", -1, &prepared, null));
    var row_count: usize = 0;
    var saw_add = false;
    while (statement.sqlite3_step(prepared) == ResultCode.row.toC()) {
        try std.testing.expect(statement.sqlite3_column_text(prepared, 1) != null);
        if (std.mem.eql(u8, std.mem.span(statement.sqlite3_column_text(prepared, 1).?), "add")) saw_add = true;
        row_count += 1;
    }
    try std.testing.expect(row_count > 0);
    try std.testing.expect(saw_add);
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

test "comparison row value BETWEEN IN and lazy inline expressions execute" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), "SELECT 2<3,3 BETWEEN 2 AND 4,4 IN(1,4,NULL),5 NOT IN(1,4),NULL IN(1,2,NULL),(1,2)<(1,3),(1,NULL)=(1,NULL),coalesce(NULL,7,8),iif(0,11,22),(SELECT 6)+1,4 IN(SELECT 4),(SELECT 6),(SELECT 6),7 IN(1,7,9),NULL IN(1,2,3)", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    const expected = [_]?i64{ 1, 1, 1, 1, null, 1, null, 7, 22, 7, 1, 6, 6, 1, null };
    for (expected, 0..) |value, index| {
        if (value) |integer| {
            try std.testing.expectEqual(integer, statement.sqlite3_column_int64(prepared, @intCast(index)));
        } else {
            try std.testing.expectEqual(@as(c_int, 5), statement.sqlite3_column_type(prepared, @intCast(index)));
        }
    }
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

test "registered JSON functions execute through prepared SQL" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    const cases = [_]struct { sql: [:0]const u8, expected: []const u8 }{
        .{ .sql = "SELECT json('{a:\"x\",b:[1,2,]/*c*/}')", .expected = "{\"a\":\"x\",\"b\":[1,2]}" },
        .{ .sql = "SELECT json_array(1,'x',null)", .expected = "[1,\"x\",null]" },
        .{ .sql = "SELECT json_extract('{\"a\":[10,20]}','$.a[1]')", .expected = "20" },
        .{ .sql = "SELECT json_remove('{\"a\":1,\"b\":2}','$.a')", .expected = "{\"b\":2}" },
        .{ .sql = "SELECT json_set('{}','$.a',json_array(1,2))", .expected = "{\"a\":[1,2]}" },
        .{ .sql = "SELECT json_patch('{\"a\":{\"x\":1,\"y\":2}}','{\"a\":{\"x\":null,\"z\":3}}')", .expected = "{\"a\":{\"y\":2,\"z\":3}}" },
        .{ .sql = "SELECT json_group_array(7)", .expected = "[7]" },
        .{ .sql = "SELECT json_group_object('a',7)", .expected = "{\"a\":7}" },
    };
    for (cases) |case| {
        var prepared: ?*statement.sqlite3_stmt = null;
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), case.sql.ptr, -1, &prepared, null));
        try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
        try std.testing.expectEqualStrings(case.expected, std.mem.span(statement.sqlite3_column_text(prepared, 0).?));
        try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    }
}

test "registered core scalar functions execute through prepared SQL" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), "SELECT length('hé'),abs(-5),round(1.6),unicode('A'),instr('abc','b'),typeof(1),sign(-9),sqlite_version()", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 2), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(@as(i64, 5), statement.sqlite3_column_int64(prepared, 1));
    try std.testing.expectEqual(@as(f64, 2), statement.sqlite3_column_double(prepared, 2));
    try std.testing.expectEqual(@as(i64, 65), statement.sqlite3_column_int64(prepared, 3));
    try std.testing.expectEqual(@as(i64, 2), statement.sqlite3_column_int64(prepared, 4));
    try std.testing.expectEqualStrings("integer", std.mem.span(statement.sqlite3_column_text(prepared, 5).?));
    try std.testing.expectEqual(@as(i64, -1), statement.sqlite3_column_int64(prepared, 6));
    try std.testing.expect(std.mem.span(statement.sqlite3_column_text(prepared, 7).?).len > 0);
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

test "registered date and time functions execute through prepared SQL" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    const cases = [_]struct { sql: [:0]const u8, expected: []const u8 }{
        .{ .sql = "SELECT date('2000-01-02 03:04:05')", .expected = "2000-01-02" },
        .{ .sql = "SELECT time('2000-01-02 03:04:05')", .expected = "03:04:05" },
        .{ .sql = "SELECT datetime('2000-01-02 03:04:05')", .expected = "2000-01-02 03:04:05" },
        .{ .sql = "SELECT strftime('%Y-%m','2000-01-02')", .expected = "2000-01" },
    };
    for (cases) |case| {
        var prepared: ?*statement.sqlite3_stmt = null;
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), case.sql.ptr, -1, &prepared, null));
        try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
        try std.testing.expectEqualStrings(case.expected, std.mem.span(statement.sqlite3_column_text(prepared, 0).?));
        try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    }
}

test "SQL load_extension function enforces connection opt-in" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), "SELECT load_extension('missing-extension')", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.error_.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.error_.toC(), statement.sqlite3_finalize(prepared));
}

test "JSON table-valued cursors execute through prepared SQL" {
    const connection = try Connection.create(std.testing.allocator);
    defer connection.destroy();
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(connection), "SELECT key,value,type,atom,fullkey,path FROM json_each('[10,20]')", -1, &prepared, null));
    for (0..2) |index| {
        try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
        try std.testing.expectEqual(@as(i64, @intCast(index)), statement.sqlite3_column_int64(prepared, 0));
        try std.testing.expectEqual(@as(i64, @intCast(10 + index * 10)), statement.sqlite3_column_int64(prepared, 1));
        try std.testing.expectEqualStrings("integer", std.mem.span(statement.sqlite3_column_text(prepared, 2).?));
        try std.testing.expectEqual(@as(i64, @intCast(10 + index * 10)), statement.sqlite3_column_int64(prepared, 3));
        try std.testing.expectEqualStrings(if (index == 0) "$[0]" else "$[1]", std.mem.span(statement.sqlite3_column_text(prepared, 4).?));
        try std.testing.expectEqualStrings("$", std.mem.span(statement.sqlite3_column_text(prepared, 5).?));
    }
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
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

test "table scans apply literal defaults to records created before added columns" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/pager/valid-empty-4096.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("column-default.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-column-default", &memory);
    var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "column-default.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "CREATE TABLE defaults(a INTEGER, b TEXT DEFAULT 'later', c BLOB DEFAULT X'0102', r REAL DEFAULT 2, g REAL AS (a * 1.5 + 1) VIRTUAL)", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    var schema = database.schemaTable("defaults").table.?;
    defer schema.deinit();
    const payload = try btree.encodeRecord(std.testing.allocator, &.{.{ .integer = 7 }});
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(ResultCode.ok, database.insertTable(schema.root_page, 1, payload, false));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT b,c,r,g FROM defaults", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqualStrings("later", std.mem.span(statement.sqlite3_column_text(prepared, 0).?));
    try std.testing.expectEqual(@as(c_int, 2), statement.sqlite3_column_bytes(prepared, 1));
    try std.testing.expectEqual(@as(f64, 2.0), statement.sqlite3_column_double(prepared, 2));
    try std.testing.expectEqual(@as(f64, 11.5), statement.sqlite3_column_double(prepared, 3));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

test "foreign keys enforce composite parents and execute update delete and drop actions" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/pager/valid-empty-4096.db", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var memory = btree.vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    const file = memory.open("foreign-key.db", btree.vfs.OPEN_READWRITE | btree.vfs.OPEN_CREATE | btree.vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(btree.vfs.OK, file.write(bytes, 0));
    try std.testing.expectEqual(btree.vfs.OK, file.sync());
    try std.testing.expectEqual(btree.vfs.OK, memory.closeAndDestroy(file));
    var adapter = btree.vfs.AbiAdapter.init("sql-foreign-key", &memory);
    var database = btree.Database.openWritable(std.testing.allocator, &adapter.abi, "foreign-key.db").database.?;
    var connection = Connection.init(std.testing.allocator, &database);
    connection.database_configuration[2] = 1;
    const handle = toOpaque(&connection);

    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(handle, "CREATE TABLE parent(id INTEGER PRIMARY KEY, k INTEGER UNIQUE); CREATE TABLE cascaded(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent(k) ON UPDATE CASCADE ON DELETE CASCADE); CREATE TABLE nulled(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent(k) ON UPDATE SET NULL ON DELETE SET NULL); CREATE TABLE defaulted(id INTEGER PRIMARY KEY, pid INTEGER DEFAULT 20 REFERENCES parent(k) ON UPDATE SET DEFAULT ON DELETE SET DEFAULT)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(handle, "INSERT INTO parent VALUES(1,10); INSERT INTO parent VALUES(2,20); INSERT INTO cascaded VALUES(1,10); INSERT INTO nulled VALUES(1,10); INSERT INTO defaulted VALUES(1,10)", null, null, null));
    var violating: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(handle, "INSERT INTO cascaded VALUES(2,99)", -1, &violating, null));
    try std.testing.expectEqual(ResultCode.constraint.toC(), statement.sqlite3_step(violating));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_extended_result_codes(handle, 1));
    try std.testing.expectEqual(ResultCode.constraint.toC() | (3 << 8), statement.sqlite3_reset(violating));
    try std.testing.expectEqual(ResultCode.constraint.toC() | (3 << 8), statement.sqlite3_step(violating));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_extended_result_codes(handle, 0));
    try std.testing.expectEqual(ResultCode.constraint.toC(), statement.sqlite3_finalize(violating));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(handle, "UPDATE parent SET k=11 WHERE id=1", null, null, null));

    var cascaded_schema = database.schemaTable("cascaded").table.?;
    defer cascaded_schema.deinit();
    var cursor = database.openCursor(cascaded_schema.root_page, .table).cursor.?;
    try std.testing.expect(cursor.seekTable(1));
    var record = cursor.record().record.?;
    try std.testing.expectEqual(@as(i64, 11), record.values[1].integer);
    record.deinit();
    cursor.deinit();

    var nulled_schema = database.schemaTable("nulled").table.?;
    defer nulled_schema.deinit();
    cursor = database.openCursor(nulled_schema.root_page, .table).cursor.?;
    try std.testing.expect(cursor.seekTable(1));
    record = cursor.record().record.?;
    try std.testing.expect(foreignKeyValueIsNull(record.values[1]));
    record.deinit();
    cursor.deinit();

    var defaulted_schema = database.schemaTable("defaulted").table.?;
    defer defaulted_schema.deinit();
    cursor = database.openCursor(defaulted_schema.root_page, .table).cursor.?;
    try std.testing.expect(cursor.seekTable(1));
    record = cursor.record().record.?;
    try std.testing.expectEqual(@as(i64, 20), record.values[1].integer);
    record.deinit();
    cursor.deinit();

    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(handle, "DELETE FROM parent WHERE id=1", null, null, null));
    cursor = database.openCursor(cascaded_schema.root_page, .table).cursor.?;
    try std.testing.expect(!cursor.seekTable(1));
    cursor.deinit();

    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(handle, "CREATE TABLE composite_parent(a INTEGER, b TEXT, UNIQUE(a,b)); CREATE TABLE composite_child(x INTEGER, y TEXT, FOREIGN KEY(x,y) REFERENCES composite_parent(a,b)); INSERT INTO composite_parent VALUES(7,'seven'); INSERT INTO composite_child VALUES(7,'seven')", null, null, null));
    try std.testing.expectEqual(ResultCode.constraint.toC(), sqlite3_exec(handle, "INSERT INTO composite_child VALUES(7,'missing')", null, null, null));
    try std.testing.expectEqual(ResultCode.constraint.toC(), sqlite3_exec(handle, "DROP TABLE parent", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(handle, "DELETE FROM defaulted WHERE id=1; DROP TABLE parent", null, null, null));
    try std.testing.expectEqual(ResultCode.not_found, database.schemaTable("parent").result);
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
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT x.id,x.v FROM main.t AS x", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 1), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expect(statement.sqlite3_column_bytes(prepared, 1) > 0);
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT x.id*2+1,x.v||'!' FROM main.t AS x LIMIT 1", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 3), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expect(statement.sqlite3_column_bytes(prepared, 1) > 1);
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT length(x.v),abs(x.id-3) FROM t x LIMIT 1", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expect(statement.sqlite3_column_int64(prepared, 0) > 0);
    try std.testing.expectEqual(@as(i64, 2), statement.sqlite3_column_int64(prepared, 1));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(toOpaque(&connection), "SELECT count(*),sum(x.id),avg(x.id),min(x.id),max(x.id),total(x.id) FROM t x", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 300), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(@as(i64, 45150), statement.sqlite3_column_int64(prepared, 1));
    try std.testing.expectApproxEqAbs(@as(f64, 150.5), statement.sqlite3_column_double(prepared, 2), 0.0001);
    try std.testing.expectEqual(@as(i64, 1), statement.sqlite3_column_int64(prepared, 3));
    try std.testing.expectEqual(@as(i64, 300), statement.sqlite3_column_int64(prepared, 4));
    try std.testing.expectApproxEqAbs(@as(f64, 45150), statement.sqlite3_column_double(prepared, 5), 0.0001);
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(prepared));
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
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_extended_result_codes(toOpaque(&connection), 1));
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
        try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_extended_result_codes(toOpaque(&connection), 1));
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

test "memory ATTACH and DETACH maintain the connection schema catalog" {
    var database: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &database));
    defer _ = sqlite3_close(database);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(database, "ATTACH DATABASE ':memory:' AS aux", null, null, null));
    try std.testing.expectEqualStrings("main", std.mem.span(sqlite3_db_name(database, 0).?));
    try std.testing.expectEqualStrings("temp", std.mem.span(sqlite3_db_name(database, 1).?));
    try std.testing.expectEqualStrings("aux", std.mem.span(sqlite3_db_name(database, 2).?));
    try std.testing.expectEqual(null, sqlite3_db_name(database, 3));
    try std.testing.expectEqual(ResultCode.error_.toC(), sqlite3_exec(database, "ATTACH ':memory:' AS aux", null, null, null));
    try std.testing.expectEqual(ResultCode.error_.toC(), sqlite3_exec(database, "DETACH main", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(database, "DETACH DATABASE aux", null, null, null));
    try std.testing.expectEqual(null, sqlite3_db_name(database, 2));
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

test "named memory URI cache is shared until the final connection closes" {
    var first: ?*sqlite3 = null;
    var second: ?*sqlite3 = null;
    const flags = 0x02 | 0x04 | 0x40;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open_v2("file:shared-cache?mode=memory&cache=shared", &first, flags, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(first, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open_v2("file:shared-cache?mode=memory&cache=shared", &second, flags, null));
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(second, "SELECT x FROM t", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
    try std.testing.expect(memdb.access("shared-cache"));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close(first));
    try std.testing.expect(memdb.access("shared-cache"));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close(second));
    try std.testing.expect(!memdb.access("shared-cache"));
}

test "ordinary database serialization copies the live pager image page by page" {
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "tmp");
    const path = "tmp/serialize-pager.db";
    unix_vfs.remove(path);
    defer unix_vfs.remove(path);
    var source: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(path, &source));
    defer _ = sqlite3_close(source);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(source, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", null, null, null));

    const source_connection = asConnection(source).?;
    const expected_size = @as(i64, @intCast(source_connection.database.?.pager.pageCount())) * @as(i64, @intCast(source_connection.database.?.pager.pageSize()));
    var size: i64 = -1;
    const image = sqlite3_serialize(source, "main", &size, 0) orelse return error.TestUnexpectedResult;
    defer public_api.sqlite3_free(image);
    try std.testing.expectEqual(expected_size, size);
    try std.testing.expectEqualSlices(u8, "SQLite format 3\x00", image[0..16]);
    var no_copy_size: i64 = -1;
    try std.testing.expectEqual(null, sqlite3_serialize(source, "main", &no_copy_size, 1));
    try std.testing.expectEqual(size, no_copy_size);

    var clone: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &clone));
    defer _ = sqlite3_close(clone);
    const capacity: i64 = @intCast(public_api.sqlite3_msize(image));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_deserialize(clone, "main", image, size, capacity, 0));
    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(clone, "SELECT x FROM t", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

test "attached schema serialize and deserialize preserve image ownership" {
    var source: ?*sqlite3 = null;
    var target: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &source));
    defer _ = sqlite3_close(source);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &target));
    defer _ = sqlite3_close(target);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(source, "CREATE TABLE t(id INTEGER PRIMARY KEY, x); INSERT INTO t VALUES(1,42)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "ATTACH ':memory:' AS aux", null, null, null));
    var size: i64 = -1;
    const image = sqlite3_serialize(source, "main", &size, 0) orelse return error.TestUnexpectedResult;
    const capacity: i64 = @intCast(public_api.sqlite3_msize(image));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_deserialize(target, "aux", image, size, capacity, btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_RESIZEABLE));
    var attached_size: i64 = -1;
    const borrowed = sqlite3_serialize(target, "aux", &attached_size, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(image), @intFromPtr(borrowed));
    try std.testing.expectEqual(size, attached_size);
    try std.testing.expectEqual(@as(c_int, 0), sqlite3_db_readonly(target, "aux"));
    try std.testing.expectEqualStrings("aux", std.mem.span(sqlite3_db_name(target, 2).?));
    var statement_pointer: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(target, "SELECT x FROM aux.t", -1, &statement_pointer, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(statement_pointer));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(statement_pointer, 0));
    try std.testing.expectEqual(ResultCode.done.toC(), statement.sqlite3_step(statement_pointer));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(statement_pointer));
    statement_pointer = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "INSERT INTO aux.t VALUES(2,43)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "UPDATE aux.t SET x=44 WHERE id=2", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "DELETE FROM aux.t WHERE id=1", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(target, "SELECT x FROM aux.t WHERE id=2", -1, &statement_pointer, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(statement_pointer));
    try std.testing.expectEqual(@as(i64, 44), statement.sqlite3_column_int64(statement_pointer, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(statement_pointer));
    statement_pointer = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "CREATE TABLE aux.created(id INTEGER PRIMARY KEY, value)", null, null, null));
    const target_connection = asConnection(target).?;
    const attached_owner = attachedDatabaseByName(target_connection, "aux").?;
    const created_schema_outcome = attached_owner.database.?.schemaTable("created");
    try std.testing.expectEqual(ResultCode.ok, created_schema_outcome.result);
    var created_schema = created_schema_outcome.table.?;
    defer created_schema.deinit();
    try std.testing.expectEqualStrings("CREATE TABLE created(id INTEGER PRIMARY KEY, value)", created_schema.sql);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "INSERT INTO aux.created VALUES(1,99)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(target, "SELECT value FROM aux.created", -1, &statement_pointer, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(statement_pointer));
    try std.testing.expectEqual(@as(i64, 99), statement.sqlite3_column_int64(statement_pointer, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(statement_pointer));
    statement_pointer = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "DROP TABLE aux.created", null, null, null));
    try std.testing.expectEqual(ResultCode.error_.toC(), sqlite3_prepare_v2(target, "SELECT value FROM aux.created", -1, &statement_pointer, null));
    target_connection.database_configuration[2] = 1;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "CREATE TABLE aux.parent(id INTEGER PRIMARY KEY)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "CREATE TABLE aux.child(id INTEGER PRIMARY KEY, parent_id REFERENCES parent(id) ON DELETE CASCADE)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "INSERT INTO aux.parent VALUES(1)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "INSERT INTO aux.child VALUES(1,1)", null, null, null));
    try std.testing.expectEqual(ResultCode.constraint.toC(), sqlite3_exec(target, "INSERT INTO aux.child VALUES(2,99)", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "DELETE FROM aux.parent WHERE id=1", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(target, "SELECT count(*) FROM aux.child", -1, &statement_pointer, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(statement_pointer));
    try std.testing.expectEqual(@as(i64, 0), statement.sqlite3_column_int64(statement_pointer, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(statement_pointer));
    statement_pointer = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "DROP TABLE aux.child", null, null, null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(target, "DROP TABLE aux.parent", null, null, null));

    var malformed: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &malformed));
    defer _ = sqlite3_close(malformed);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(malformed, "ATTACH ':memory:' AS aux", null, null, null));
    const bad = public_api.sqlite3_malloc64(512) orelse return error.TestUnexpectedResult;
    @memset(@as([*]u8, @ptrCast(bad))[0..512], 0xa5);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_deserialize(malformed, "aux", @ptrCast(bad), 512, 512, btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_RESIZEABLE));
    var bad_size: i64 = -1;
    const bad_borrow = sqlite3_serialize(malformed, "aux", &bad_size, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(bad), @intFromPtr(bad_borrow));
    try std.testing.expectEqual(@as(i64, 512), bad_size);
    const replacement = sqlite3_serialize(source, "main", &size, 0) orelse return error.TestUnexpectedResult;
    const replacement_size: i64 = @intCast(public_api.sqlite3_msize(replacement));
    try std.testing.expectEqual(ResultCode.not_a_database.toC(), sqlite3_deserialize(malformed, "aux", replacement, size, replacement_size, btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_RESIZEABLE));
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

test "deserialize allocation failure preserves the existing database and frees transferred input" {
    var database: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &database));
    defer _ = sqlite3_close(database);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(database, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", null, null, null));
    var size: i64 = -1;
    const image = sqlite3_serialize(database, "main", &size, 0) orelse return error.TestUnexpectedResult;
    const capacity: i64 = @intCast(public_api.sqlite3_msize(image));
    const memory_before_failure = global.memory.process_manager.statusValue(.memory_used);
    const connection = asConnection(database).?;
    const original_allocator = connection.allocator;
    var failing = OneShotFailAllocator.init(std.testing.allocator, 0);
    connection.allocator = failing.allocator();
    const rc = sqlite3_deserialize(database, "main", image, size, capacity, btree.vfs.DESERIALIZE_FREEONCLOSE);
    connection.allocator = original_allocator;
    try std.testing.expectEqual(ResultCode.no_memory.toC(), rc);
    try std.testing.expectEqual(memory_before_failure - capacity, global.memory.process_manager.statusValue(.memory_used));

    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_prepare_v2(database, "SELECT x FROM t", -1, &prepared, null));
    try std.testing.expectEqual(ResultCode.row.toC(), statement.sqlite3_step(prepared));
    try std.testing.expectEqual(@as(i64, 42), statement.sqlite3_column_int64(prepared, 0));
    try std.testing.expectEqual(ResultCode.ok.toC(), statement.sqlite3_finalize(prepared));
}

test "malformed deserialize publishes ownership and preserves source continuation" {
    var source: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &source));
    defer _ = sqlite3_close(source);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_exec(source, "CREATE TABLE t(x); INSERT INTO t VALUES(42)", null, null, null));
    var valid_size: i64 = -1;
    const valid_image = sqlite3_serialize(source, "main", &valid_size, 0) orelse return error.TestUnexpectedResult;
    const valid_capacity: i64 = @intCast(public_api.sqlite3_msize(valid_image));

    const malformed = public_api.sqlite3_malloc64(512) orelse return error.OutOfMemory;
    @memset(@as([*]u8, @ptrCast(malformed))[0..512], 0);
    @memcpy(@as([*]u8, @ptrCast(malformed))[0..14], "not-a-database");
    var database: ?*sqlite3 = null;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_open(":memory:", &database));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_deserialize(database, "main", @ptrCast(malformed), 512, @intCast(public_api.sqlite3_msize(malformed)), btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_RESIZEABLE));
    var malformed_size: i64 = -1;
    const borrowed = sqlite3_serialize(database, "main", &malformed_size, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(malformed), @intFromPtr(borrowed));
    try std.testing.expectEqual(@as(i64, 512), malformed_size);

    var prepared: ?*statement.sqlite3_stmt = null;
    try std.testing.expectEqual(ResultCode.not_a_database.toC(), sqlite3_prepare_v2(database, "SELECT 1", -1, &prepared, null));
    try std.testing.expectEqual(null, prepared);
    const memory_before_replacement = global.memory.process_manager.statusValue(.memory_used);
    try std.testing.expectEqual(ResultCode.not_a_database.toC(), sqlite3_deserialize(database, "main", valid_image, valid_size, valid_capacity, btree.vfs.DESERIALIZE_FREEONCLOSE | btree.vfs.DESERIALIZE_RESIZEABLE));
    try std.testing.expectEqual(memory_before_replacement - valid_capacity, global.memory.process_manager.statusValue(.memory_used));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_close(database));
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
    try std.testing.expectEqual(@as(c_int, 0), sqlite3_db_readonly(readonly, "main"));
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
