//! PRAGMA dispatch and eponymous virtual-table execution from `pragma.c`.

const std = @import("std");
const pragma_values = @import("pragma_values.zig");

pub const Error = error{ OutOfMemory, Constraint, NotFound, TransactionActive, InvalidValue };

pub const Value = union(enum) {
    integer: i64,
    text: []const u8,
};

pub const Kind = enum {
    analysis_limit,
    busy_timeout,
    cache_size,
    cache_spill,
    foreign_keys,
    page_count,
    synchronous,
    temp_store,
    user_version,
};

pub const Definition = struct {
    name: []const u8,
    kind: Kind,
    column_names: []const []const u8,
    accepts_argument: bool = false,
    schema_argument: bool = false,
};

const value_column = [_][]const u8{"value"};
const definitions = [_]Definition{
    .{ .name = "analysis_limit", .kind = .analysis_limit, .column_names = &value_column, .accepts_argument = true },
    .{ .name = "busy_timeout", .kind = .busy_timeout, .column_names = &value_column, .accepts_argument = true },
    .{ .name = "cache_size", .kind = .cache_size, .column_names = &value_column, .accepts_argument = true, .schema_argument = true },
    .{ .name = "cache_spill", .kind = .cache_spill, .column_names = &value_column, .accepts_argument = true, .schema_argument = true },
    .{ .name = "foreign_keys", .kind = .foreign_keys, .column_names = &value_column, .accepts_argument = true },
    .{ .name = "page_count", .kind = .page_count, .column_names = &value_column, .schema_argument = true },
    .{ .name = "synchronous", .kind = .synchronous, .column_names = &value_column, .accepts_argument = true, .schema_argument = true },
    .{ .name = "temp_store", .kind = .temp_store, .column_names = &value_column, .accepts_argument = true },
    .{ .name = "user_version", .kind = .user_version, .column_names = &value_column, .accepts_argument = true, .schema_argument = true },
};

pub const State = struct {
    auto_commit: bool = true,
    temporary_open: bool = false,
    temporary_transaction: bool = false,
    schemas_invalidated: bool = false,
    temp_store: u8 = 0,
    database_flags: u64 = 0,
    pager_safety: u8 = 2,
    pager_flags: u8 = 0,
    analysis_limit: i64 = 0,
    busy_timeout: i64 = 0,
    cache_size: i64 = -2000,
    cache_spill: i64 = 0,
    foreign_keys: bool = false,
    page_count: i64 = 0,
    synchronous: i64 = 2,
    user_version: i64 = 0,
};

/// Source `invalidateTempStorage()`.
pub fn invalidateTemporaryStorage(state: *State) Error!void {
    if (!state.temporary_open) return;
    if (!state.auto_commit or state.temporary_transaction) return error.TransactionActive;
    state.temporary_open = false;
    state.temporary_transaction = false;
    state.schemas_invalidated = true;
}

/// Source `changeTempStorage()`.
pub fn changeTemporaryStorage(state: *State, storage: [*:0]const u8) Error!void {
    const next: u8 = @intCast(pragma_values.tempStore(storage));
    if (state.temp_store == next) return;
    try invalidateTemporaryStorage(state);
    state.temp_store = next;
}

/// Source `setPragmaResultColumnNames()`.
pub fn setResultColumnNames(definition: *const Definition) []const []const u8 {
    std.debug.assert(definition.column_names.len != 0);
    return definition.column_names;
}

/// Source `setAllPagerFlags()`.
pub fn applyPagerFlags(state: *State, pager_flags: []u8) void {
    if (!state.auto_commit) return;
    const combined = state.pager_safety | state.pager_flags | @as(u8, @truncate(state.database_flags));
    for (pager_flags) |*flags| {
        flags.* = combined;
    }
}

/// Source `pragmaLocate()`.
pub fn locatePragma(name: []const u8) ?*const Definition {
    var lower: usize = 0;
    var upper: usize = definitions.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        switch (std.ascii.orderIgnoreCase(name, definitions[middle].name)) {
            .eq => return &definitions[middle],
            .lt => upper = middle,
            .gt => lower = middle + 1,
        }
    }
    return null;
}

pub const FunctionInput = struct {
    name: []const u8,
    builtin: bool,
    argument_count: i16,
    encoding: []const u8 = "utf8",
    flags: u32 = 0,
    scalar: bool = true,
    aggregate: bool = false,
    window: bool = false,
    internal: bool = false,
};

pub const FunctionRow = struct {
    name: []const u8,
    builtin: bool,
    kind: u8,
    encoding: []const u8,
    argument_count: i16,
    flags: u32,
};

/// Source `pragmaFunclistLine()`.
pub fn functionListRows(allocator: std.mem.Allocator, functions: []const FunctionInput, show_internal: bool) Error![]FunctionRow {
    var rows = std.ArrayList(FunctionRow).empty;
    errdefer rows.deinit(allocator);
    const public_mask: u32 = 0x0000_0800 | 0x0008_0000 | 0x0010_0000 | 0x0020_0000 | 0x0040_0000;
    for (functions) |function| {
        if (function.internal and !show_internal) continue;
        if (!function.scalar and !function.aggregate and !function.window) continue;
        const kind: u8 = if (function.window) 'w' else if (function.aggregate) 'a' else 's';
        rows.append(allocator, .{
            .name = function.name,
            .builtin = function.builtin,
            .kind = kind,
            .encoding = function.encoding,
            .argument_count = function.argument_count,
            .flags = if (show_internal) function.flags else function.flags & public_mask,
        }) catch return error.OutOfMemory;
    }
    return rows.toOwnedSlice(allocator) catch error.OutOfMemory;
}

pub const Request = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    schema_name: ?[]const u8 = null,
};

pub const Result = struct {
    definition: *const Definition,
    values: [1]Value,
};

fn parseNonnegative(value: []const u8) Error!i64 {
    const parsed = std.fmt.parseInt(i64, value, 0) catch return error.InvalidValue;
    return if (parsed < 0) error.InvalidValue else parsed;
}

fn terminatedValue(value: []const u8) Error![64:0]u8 {
    if (value.len > 64) return error.InvalidValue;
    var output = [_:0]u8{0} ** 64;
    @memcpy(output[0..value.len], value);
    return output;
}

/// Source `sqlite3Pragma()` for the production connection-level pragma set.
pub fn executePragma(state: *State, request: Request) Error!Result {
    const definition = locatePragma(request.name) orelse return error.NotFound;
    if (request.schema_name != null and !definition.schema_argument) return error.NotFound;
    if (request.value != null and !definition.accepts_argument) return error.InvalidValue;
    if (request.value) |text| switch (definition.kind) {
        .analysis_limit => state.analysis_limit = try parseNonnegative(text),
        .busy_timeout => state.busy_timeout = try parseNonnegative(text),
        .cache_size => state.cache_size = std.fmt.parseInt(i64, text, 0) catch return error.InvalidValue,
        .cache_spill => {
            state.cache_spill = std.fmt.parseInt(i64, text, 0) catch @intFromBool(std.ascii.eqlIgnoreCase(text, "on"));
            if (state.cache_spill != 0) state.database_flags |= 0x01 else state.database_flags &= ~@as(u64, 0x01);
        },
        .foreign_keys => state.foreign_keys = std.ascii.eqlIgnoreCase(text, "on") or std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true"),
        .page_count => unreachable,
        .synchronous => {
            const terminated = try terminatedValue(text);
            state.synchronous = pragma_values.safetyLevel(&terminated, false, 1);
            state.pager_safety = @intCast(state.synchronous + 1);
        },
        .temp_store => {
            const terminated = try terminatedValue(text);
            try changeTemporaryStorage(state, &terminated);
        },
        .user_version => state.user_version = std.fmt.parseInt(i64, text, 0) catch return error.InvalidValue,
    };
    const value: i64 = switch (definition.kind) {
        .analysis_limit => state.analysis_limit,
        .busy_timeout => state.busy_timeout,
        .cache_size => state.cache_size,
        .cache_spill => state.cache_spill,
        .foreign_keys => @intFromBool(state.foreign_keys),
        .page_count => state.page_count,
        .synchronous => state.synchronous,
        .temp_store => state.temp_store,
        .user_version => state.user_version,
    };
    return .{ .definition = definition, .values = .{.{ .integer = value }} };
}

pub const VirtualTable = struct {
    allocator: std.mem.Allocator,
    definition: *const Definition,
    declaration: []u8,
    hidden_start: usize,
    hidden_count: usize,

    pub fn deinit(self: *VirtualTable) void {
        self.allocator.free(self.declaration);
    }
};

/// Source `pragmaVtabConnect()`.
pub fn connectVirtualTable(allocator: std.mem.Allocator, module_name: []const u8) Error!VirtualTable {
    const prefix = "pragma_";
    if (!std.mem.startsWith(u8, module_name, prefix)) return error.NotFound;
    const definition = locatePragma(module_name[prefix.len..]) orelse return error.NotFound;
    var declaration = std.ArrayList(u8).empty;
    errdefer declaration.deinit(allocator);
    declaration.appendSlice(allocator, "CREATE TABLE x(") catch return error.OutOfMemory;
    const names = setResultColumnNames(definition);
    for (names, 0..) |name, index| {
        if (index != 0) declaration.append(allocator, ',') catch return error.OutOfMemory;
        declaration.writer(allocator).print("\"{s}\"", .{name}) catch return error.OutOfMemory;
    }
    const hidden_start = names.len;
    var hidden_count: usize = 0;
    if (definition.accepts_argument) {
        declaration.appendSlice(allocator, ",arg HIDDEN") catch return error.OutOfMemory;
        hidden_count += 1;
    }
    if (definition.schema_argument) {
        declaration.appendSlice(allocator, ",schema HIDDEN") catch return error.OutOfMemory;
        hidden_count += 1;
    }
    declaration.append(allocator, ')') catch return error.OutOfMemory;
    return .{
        .allocator = allocator,
        .definition = definition,
        .declaration = declaration.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .hidden_start = hidden_start,
        .hidden_count = hidden_count,
    };
}

pub const ConstraintInput = struct { column: usize, equal: bool, usable: bool };
pub const ConstraintUsage = struct { constraint: usize, argument: usize };
pub const VirtualPlan = struct {
    usages: [2]?ConstraintUsage = .{ null, null },
    estimated_cost: f64 = 1,
    estimated_rows: i64 = 1,
};

/// Source `pragmaVtabBestIndex()`.
pub fn virtualBestIndex(table: *const VirtualTable, constraints: []const ConstraintInput) Error!VirtualPlan {
    var plan = VirtualPlan{};
    if (table.hidden_count == 0) return plan;
    var seen: [2]?usize = .{ null, null };
    for (constraints, 0..) |constraint, index| {
        if (constraint.column < table.hidden_start or !constraint.equal) continue;
        if (!constraint.usable) return error.Constraint;
        const hidden = constraint.column - table.hidden_start;
        if (hidden < seen.len) seen[hidden] = index;
    }
    if (table.definition.accepts_argument and seen[0] == null) {
        plan.estimated_cost = 2_147_483_647;
        plan.estimated_rows = 2_147_483_647;
        return plan;
    }
    var argument: usize = 1;
    for (seen, 0..) |constraint, hidden| {
        if (constraint) |index| {
            plan.usages[hidden] = .{ .constraint = index, .argument = argument };
            argument += 1;
        }
    }
    plan.estimated_cost = 20;
    plan.estimated_rows = 20;
    return plan;
}

pub const VirtualCursor = struct {
    allocator: std.mem.Allocator,
    table: *const VirtualTable,
    state: *State,
    argument: ?[]u8 = null,
    schema_name: ?[]u8 = null,
    row: ?Result = null,
    rowid: i64 = 0,
    exhausted: bool = true,

    pub fn init(allocator: std.mem.Allocator, table: *const VirtualTable, state: *State) VirtualCursor {
        return .{ .allocator = allocator, .table = table, .state = state };
    }

    pub fn deinit(self: *VirtualCursor) void {
        clearVirtualCursor(self);
    }
};

/// Source `pragmaVtabCursorClear()`.
pub fn clearVirtualCursor(cursor: *VirtualCursor) void {
    if (cursor.argument) |argument| cursor.allocator.free(argument);
    if (cursor.schema_name) |schema_name| cursor.allocator.free(schema_name);
    cursor.argument = null;
    cursor.schema_name = null;
    cursor.row = null;
    cursor.rowid = 0;
    cursor.exhausted = true;
}

/// Source `pragmaVtabNext()`.
pub fn virtualNext(cursor: *VirtualCursor) Error!void {
    if (cursor.exhausted) return;
    cursor.rowid += 1;
    cursor.row = null;
    cursor.exhausted = true;
}

/// Source `pragmaVtabFilter()`.
pub fn virtualFilter(cursor: *VirtualCursor, arguments: []const []const u8) Error!void {
    clearVirtualCursor(cursor);
    var index: usize = 0;
    if (cursor.table.definition.accepts_argument and index < arguments.len) {
        cursor.argument = cursor.allocator.dupe(u8, arguments[index]) catch return error.OutOfMemory;
        index += 1;
    }
    if (cursor.table.definition.schema_argument and index < arguments.len) {
        cursor.schema_name = cursor.allocator.dupe(u8, arguments[index]) catch return error.OutOfMemory;
        index += 1;
    }
    if (index != arguments.len) return error.Constraint;
    cursor.row = try executePragma(cursor.state, .{
        .name = cursor.table.definition.name,
        .value = cursor.argument,
        .schema_name = cursor.schema_name,
    });
    cursor.rowid = 1;
    cursor.exhausted = false;
}

/// Source `pragmaVtabColumn()`.
pub fn virtualColumn(cursor: *const VirtualCursor, column: usize) Error!Value {
    if (cursor.exhausted) return error.NotFound;
    if (column < cursor.table.hidden_start) return cursor.row.?.values[column];
    var hidden = column - cursor.table.hidden_start;
    if (cursor.table.definition.accepts_argument) {
        if (hidden == 0) return .{ .text = cursor.argument orelse "" };
        hidden -= 1;
    }
    if (cursor.table.definition.schema_argument and hidden == 0) return .{ .text = cursor.schema_name orelse "" };
    return error.NotFound;
}
