//! Virtual-table construction and transaction lifecycle from `vtab.c`.

const std = @import("std");

pub const Error = error{ OutOfMemory, Locked, NotFound, ConstructorFailed, SchemaNotDeclared, Constraint };

pub const CallbackResult = struct { code: i32 = 0, message: ?[]const u8 = null };
pub const Constructor = *const fn (?*anyopaque, []const []const u8, *Instance) CallbackResult;
pub const Finalizer = *const fn (?*anyopaque) i32;
pub const SavepointCallback = *const fn (?*anyopaque, i32) i32;
pub const FindFunction = *const fn (?*anyopaque, i16, []const u8) ?FunctionOverride;

pub const FunctionOverride = struct { callback: *const anyopaque, user_data: ?*anyopaque };

pub const Module = struct {
    name: []const u8,
    auxiliary: ?*anyopaque = null,
    create: ?Constructor = null,
    connect: ?Constructor = null,
    destroy: ?Finalizer = null,
    disconnect: ?Finalizer = null,
    begin: ?Finalizer = null,
    sync: ?Finalizer = null,
    commit: ?Finalizer = null,
    rollback: ?Finalizer = null,
    savepoint: ?SavepointCallback = null,
    rollback_to: ?SavepointCallback = null,
    release: ?SavepointCallback = null,
    find_function: ?FindFunction = null,
    version: u8 = 1,
};

pub const ModuleHandle = struct {
    allocator: std.mem.Allocator,
    module: Module,
    reference_count: usize = 1,
    destroy_auxiliary: ?*const fn (?*anyopaque) void = null,
};

/// Source `sqlite3VtabModuleUnref()`.
pub fn unreferenceModule(handle: *ModuleHandle) bool {
    std.debug.assert(handle.reference_count > 0);
    handle.reference_count -= 1;
    if (handle.reference_count != 0) return false;
    if (handle.destroy_auxiliary) |destroy| destroy(handle.module.auxiliary);
    handle.allocator.destroy(handle);
    return true;
}

pub const Instance = struct {
    context: ?*anyopaque = null,
    declared: bool = false,
    reference_count: usize = 1,
    savepoint_depth: i32 = 0,
    in_transaction: bool = false,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    module_name: []u8,
    database_name: []u8,
    arguments: std.ArrayList([]u8) = .empty,
    declaration: ?[]u8 = null,
    instance: ?*Instance = null,
    eponymous: bool = false,
    writable: bool = false,

    pub fn deinit(self: *Table) void {
        for (self.arguments.items) |argument| self.allocator.free(argument);
        self.arguments.deinit(self.allocator);
        if (self.declaration) |declaration| self.allocator.free(declaration);
        if (self.instance) |instance| self.allocator.destroy(instance);
        self.allocator.free(self.name);
        self.allocator.free(self.module_name);
        self.allocator.free(self.database_name);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(*Table) = .empty,
    transactions: std.ArrayList(*Table) = .empty,
    writable_tables: std.ArrayList(*Table) = .empty,
    deferred_disconnects: std.ArrayList(*Table) = .empty,
    constructing: ?*Table = null,
    in_sync: bool = false,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        for (self.tables.items) |table| {
            table.deinit();
            self.allocator.destroy(table);
        }
        self.tables.deinit(self.allocator);
        self.transactions.deinit(self.allocator);
        self.writable_tables.deinit(self.allocator);
        self.deferred_disconnects.deinit(self.allocator);
    }
};

/// Source `sqlite3VtabUnlockList()`.
pub fn unlockDeferredTables(state: *State, modules: []const Module) void {
    for (state.deferred_disconnects.items) |table| {
        const instance = table.instance orelse continue;
        if (instance.reference_count > 0) instance.reference_count -= 1;
        if (instance.reference_count != 0) continue;
        for (modules) |*module| {
            if (!std.ascii.eqlIgnoreCase(module.name, table.module_name)) continue;
            if (module.disconnect) |disconnect| _ = disconnect(instance.context);
            break;
        }
        state.allocator.destroy(instance);
        table.instance = null;
    }
    state.deferred_disconnects.clearRetainingCapacity();
}

/// Source `addModuleArgument()`.
pub fn addModuleArgument(table: *Table, argument: []const u8, column_limit: usize) Error!void {
    if (table.arguments.items.len + 3 >= column_limit) return error.Constraint;
    const owned = table.allocator.dupe(u8, argument) catch return error.OutOfMemory;
    errdefer table.allocator.free(owned);
    table.arguments.append(table.allocator, owned) catch return error.OutOfMemory;
}

/// Source `sqlite3VtabBeginParse()`.
pub fn beginVirtualParse(allocator: std.mem.Allocator, database_name: []const u8, table_name: []const u8, module_name: []const u8, column_limit: usize) Error!*Table {
    const table = allocator.create(Table) catch return error.OutOfMemory;
    errdefer allocator.destroy(table);
    const name = allocator.dupe(u8, table_name) catch return error.OutOfMemory;
    errdefer allocator.free(name);
    const module = allocator.dupe(u8, module_name) catch return error.OutOfMemory;
    errdefer allocator.free(module);
    const database = allocator.dupe(u8, database_name) catch return error.OutOfMemory;
    errdefer allocator.free(database);
    table.* = .{ .allocator = allocator, .name = name, .module_name = module, .database_name = database };
    errdefer table.deinit();
    try addModuleArgument(table, module_name, column_limit);
    try addModuleArgument(table, database_name, column_limit);
    try addModuleArgument(table, table_name, column_limit);
    return table;
}

/// Source `sqlite3VtabFinishParse()`.
pub fn finishVirtualParse(state: *State, table: *Table, statement: []const u8) Error!void {
    if (!std.ascii.startsWithIgnoreCase(statement, "create virtual table")) return error.Constraint;
    table.declaration = state.allocator.dupe(u8, statement) catch return error.OutOfMemory;
    state.tables.append(state.allocator, table) catch {
        state.allocator.free(table.declaration.?);
        table.declaration = null;
        return error.OutOfMemory;
    };
}

/// Source `addArgumentToVtab()`: append an accumulated non-empty argument to
/// the table and transfer the duplicated bytes into table ownership.
pub fn addAccumulatedVirtualArgument(table: *Table, argument: []const u8, column_limit: usize) Error!void {
    if (argument.len == 0) return;
    try addModuleArgument(table, argument, column_limit);
}

/// Source `sqlite3VtabArgInit()`: finish the prior accumulated argument before
/// the parser begins collecting the next one.
pub fn initializeVirtualArgument(table: *Table, accumulated: *std.ArrayList(u8), column_limit: usize) Error!void {
    try addAccumulatedVirtualArgument(table, accumulated.items, column_limit);
    accumulated.clearRetainingCapacity();
}

/// Source `sqlite3VtabArgExtend()`.
pub fn extendVirtualArgument(table: *Table, tokens: []const []const u8, column_limit: usize) Error!void {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(table.allocator);
    for (tokens, 0..) |token, index| {
        if (index != 0) joined.append(table.allocator, ' ') catch return error.OutOfMemory;
        joined.appendSlice(table.allocator, token) catch return error.OutOfMemory;
    }
    try addModuleArgument(table, joined.items, column_limit);
}

fn findTable(state: *State, name: []const u8) ?*Table {
    for (state.tables.items) |table| if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
    return null;
}

test "virtual table parser accumulation transfers each argument once" {
    const table = try beginVirtualParse(std.testing.allocator, "main", "items", "module", 32);
    defer {
        table.deinit();
        std.testing.allocator.destroy(table);
    }
    var accumulated = std.ArrayList(u8).empty;
    defer accumulated.deinit(std.testing.allocator);
    try accumulated.appendSlice(std.testing.allocator, "first value");
    try initializeVirtualArgument(table, &accumulated, 32);
    try std.testing.expectEqual(@as(usize, 0), accumulated.items.len);
    try std.testing.expectEqualStrings("first value", table.arguments.items[3]);
    try initializeVirtualArgument(table, &accumulated, 32);
    try std.testing.expectEqual(@as(usize, 4), table.arguments.items.len);
}

/// Source `vtabCallConstructor()`.
pub fn callConstructor(state: *State, table: *Table, module: *const Module, constructor: Constructor) Error!void {
    if (state.constructing == table) return error.Locked;
    const instance = state.allocator.create(Instance) catch return error.OutOfMemory;
    errdefer state.allocator.destroy(instance);
    instance.* = .{};
    state.constructing = table;
    defer state.constructing = null;
    const result = constructor(module.auxiliary, table.arguments.items, instance);
    if (result.code != 0) return error.ConstructorFailed;
    if (!instance.declared) return error.SchemaNotDeclared;
    table.instance = instance;
}

/// Source `sqlite3VtabCallConnect()`.
pub fn connectVirtualTable(state: *State, table: *Table, modules: []const Module) Error!void {
    if (table.instance != null) return;
    for (modules) |*module| {
        if (!std.ascii.eqlIgnoreCase(module.name, table.module_name)) continue;
        const constructor = module.connect orelse return error.NotFound;
        return callConstructor(state, table, module, constructor);
    }
    return error.NotFound;
}

/// Source `growVTrans()`.
pub fn growVirtualTransactions(state: *State) Error!void {
    if (state.transactions.items.len % 5 != 0) return;
    state.transactions.ensureUnusedCapacity(state.allocator, 5) catch return error.OutOfMemory;
}

/// Source `sqlite3VtabCallCreate()`.
pub fn createVirtualTable(state: *State, table_name: []const u8, modules: []const Module) Error!void {
    const table = findTable(state, table_name) orelse return error.NotFound;
    for (modules) |*module| {
        if (!std.ascii.eqlIgnoreCase(module.name, table.module_name)) continue;
        const constructor = module.create orelse return error.NotFound;
        if (module.destroy == null) return error.NotFound;
        try callConstructor(state, table, module, constructor);
        try growVirtualTransactions(state);
        state.transactions.appendAssumeCapacity(table);
        table.instance.?.reference_count += 1;
        return;
    }
    return error.NotFound;
}

/// Source `sqlite3VtabCallDestroy()`.
pub fn destroyVirtualTable(state: *State, table_name: []const u8, modules: []const Module) Error!void {
    const table = findTable(state, table_name) orelse return error.NotFound;
    const instance = table.instance orelse return;
    if (instance.reference_count > 1) return error.Locked;
    for (modules) |*module| {
        if (!std.ascii.eqlIgnoreCase(module.name, table.module_name)) continue;
        const callback = module.destroy orelse module.disconnect orelse return error.NotFound;
        if (callback(instance.context) != 0) return error.ConstructorFailed;
        state.allocator.destroy(instance);
        table.instance = null;
        return;
    }
    return error.NotFound;
}

pub const FinalizerKind = enum { commit, rollback };

/// Source `callFinaliser()`.
pub fn callFinalizer(state: *State, modules: []const Module, kind: FinalizerKind) void {
    for (state.transactions.items) |table| {
        const instance = table.instance orelse continue;
        for (modules) |*module| {
            if (!std.ascii.eqlIgnoreCase(module.name, table.module_name)) continue;
            const callback = if (kind == .commit) module.commit else module.rollback;
            if (callback) |function| _ = function(instance.context);
            instance.savepoint_depth = 0;
            instance.in_transaction = false;
            if (instance.reference_count > 0) instance.reference_count -= 1;
            break;
        }
    }
    state.transactions.clearRetainingCapacity();
}

/// Source `sqlite3VtabSync()`.
pub fn syncVirtualTables(state: *State, modules: []const Module) Error!void {
    state.in_sync = true;
    defer state.in_sync = false;
    for (state.transactions.items) |table| {
        const instance = table.instance orelse continue;
        for (modules) |*module| {
            if (!std.ascii.eqlIgnoreCase(module.name, table.module_name)) continue;
            if (module.sync) |callback| if (callback(instance.context) != 0) return error.ConstructorFailed;
            break;
        }
    }
}

/// Source `sqlite3VtabBegin()`.
pub fn beginVirtualTransaction(state: *State, table: ?*Table, modules: []const Module, savepoint_depth: i32) Error!void {
    if (state.in_sync) return error.Locked;
    const selected = table orelse return;
    const instance = selected.instance orelse return;
    if (instance.in_transaction) return;
    for (modules) |*module| {
        if (!std.ascii.eqlIgnoreCase(module.name, selected.module_name)) continue;
        const callback = module.begin orelse return;
        try growVirtualTransactions(state);
        if (callback(instance.context) != 0) return error.ConstructorFailed;
        state.transactions.appendAssumeCapacity(selected);
        instance.in_transaction = true;
        instance.reference_count += 1;
        if (savepoint_depth > 0 and module.savepoint != null) {
            instance.savepoint_depth = savepoint_depth;
            if (module.savepoint.?(instance.context, savepoint_depth - 1) != 0) return error.ConstructorFailed;
        }
        return;
    }
}

pub const SavepointOperation = enum { begin, rollback, release };

/// Source `sqlite3VtabSavepoint()`.
pub fn virtualSavepoint(state: *State, modules: []const Module, operation: SavepointOperation, savepoint: i32) Error!void {
    for (state.transactions.items) |table| {
        const instance = table.instance orelse continue;
        for (modules) |*module| {
            if (!std.ascii.eqlIgnoreCase(module.name, table.module_name) or module.version < 2) continue;
            const callback = switch (operation) {
                .begin => module.savepoint,
                .rollback => module.rollback_to,
                .release => module.release,
            };
            if (operation == .begin) instance.savepoint_depth = savepoint + 1;
            if (callback != null and instance.savepoint_depth > savepoint and callback.?(instance.context, savepoint) != 0) return error.ConstructorFailed;
            break;
        }
    }
}

pub const FunctionDefinition = struct {
    name: []const u8,
    argument_count: i16,
    callback: ?*const anyopaque = null,
    user_data: ?*anyopaque = null,
    ephemeral: bool = false,
};

/// Source `sqlite3VtabOverloadFunction()`.
pub fn overloadVirtualFunction(base: FunctionDefinition, table: ?*Table, modules: []const Module) FunctionDefinition {
    const selected = table orelse return base;
    const instance = selected.instance orelse return base;
    for (modules) |*module| {
        if (!std.ascii.eqlIgnoreCase(module.name, selected.module_name)) continue;
        const finder = module.find_function orelse return base;
        const found = finder(instance.context, base.argument_count, base.name) orelse return base;
        var result = base;
        result.callback = found.callback;
        result.user_data = found.user_data;
        result.ephemeral = true;
        return result;
    }
    return base;
}

/// Source `sqlite3VtabMakeWritable()`.
pub fn makeVirtualWritable(state: *State, table: *Table) Error!void {
    for (state.writable_tables.items) |existing| if (existing == table) return;
    state.writable_tables.append(state.allocator, table) catch return error.OutOfMemory;
    table.writable = true;
}

/// Source `sqlite3VtabEponymousTableInit()`.
pub fn initializeEponymousTable(state: *State, module: *const Module, column_limit: usize) Error!?*Table {
    for (state.tables.items) |table| if (table.eponymous and std.ascii.eqlIgnoreCase(table.name, module.name)) return table;
    if (module.create != null and module.create != module.connect) return null;
    const constructor = module.connect orelse return null;
    const table = try beginVirtualParse(state.allocator, "main", module.name, module.name, column_limit);
    errdefer {
        table.deinit();
        state.allocator.destroy(table);
    }
    table.eponymous = true;
    try callConstructor(state, table, module, constructor);
    state.tables.append(state.allocator, table) catch return error.OutOfMemory;
    return table;
}

/// Source `sqlite3VtabEponymousTableClear()`.
pub fn clearEponymousTable(state: *State, module_name: []const u8, modules: []const Module) void {
    var index: usize = 0;
    while (index < state.tables.items.len) : (index += 1) {
        const table = state.tables.items[index];
        if (!table.eponymous or !std.ascii.eqlIgnoreCase(table.module_name, module_name)) continue;
        if (table.instance) |instance| {
            for (modules) |*module| {
                if (!std.ascii.eqlIgnoreCase(module.name, module_name)) continue;
                if (module.disconnect) |disconnect| _ = disconnect(instance.context);
                break;
            }
        }
        _ = state.tables.orderedRemove(index);
        table.deinit();
        state.allocator.destroy(table);
        return;
    }
}
