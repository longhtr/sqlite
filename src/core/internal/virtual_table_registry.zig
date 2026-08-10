//! Virtual-table module registry, disconnection, declaration, and configuration.
const std = @import("std");

pub const Error = error{ OutOfMemory, Misuse, NotFound, Locked, Syntax, Constraint };
pub const Risk = enum { normal, low, high };
pub const ConfigOperation = enum { constraint_support, innocuous, direct_only, uses_all_schemas };
pub const DestroyAuxiliary = *const fn (?*anyopaque) void;
pub const Disconnect = *const fn (?*anyopaque) i32;

pub const Module = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    auxiliary: ?*anyopaque,
    destroy_auxiliary: ?DestroyAuxiliary,
    reference_count: usize = 1,
    eponymous_table: ?*Table = null,
};

pub const Instance = struct {
    module: *Module,
    context: ?*anyopaque = null,
    disconnect_callback: ?Disconnect = null,
    reference_count: usize = 1,
    constraint_support: bool = false,
    all_schemas: bool = false,
    writable: bool = false,
    risk: Risk = .normal,
};

pub const Column = struct { name: []u8, type_name: []u8, hidden: bool = false };
pub const Table = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    columns: std.ArrayList(Column) = .empty,
    instances: std.ArrayList(*Instance) = .empty,
    module_arguments: std.ArrayList([]u8) = .empty,
    without_rowid: bool = false,
    no_visible_rowid: bool = false,
    primary_key_columns: usize = 0,

    pub fn deinit(self: *Table) void {
        for (self.columns.items) |column| {
            self.allocator.free(column.name);
            self.allocator.free(column.type_name);
        }
        self.columns.deinit(self.allocator);
        for (self.module_arguments.items) |argument| self.allocator.free(argument);
        self.module_arguments.deinit(self.allocator);
        self.instances.deinit(self.allocator);
    }
};

pub const Construction = struct {
    table: *Table,
    instance: *Instance,
    declared: bool = false,
    prior: ?*Construction = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(*Module) = .empty,
    deferred_disconnects: std.ArrayList(*Instance) = .empty,
    construction: ?*Construction = null,
    conflict_mode: u3 = 2,
    last_error: ?Error = null,

    pub fn deinit(self: *Registry) void {
        for (self.deferred_disconnects.items) |instance| unlockInstance(self, instance);
        self.deferred_disconnects.deinit(self.allocator);
        for (self.modules.items) |module| destroyModule(module);
        self.modules.deinit(self.allocator);
    }
};

fn moduleIndex(registry: *const Registry, name: []const u8) ?usize {
    for (registry.modules.items, 0..) |module, index| {
        if (std.ascii.eqlIgnoreCase(module.name, name)) return index;
    }
    return null;
}

fn destroyModule(module: *Module) void {
    if (module.destroy_auxiliary) |destroy| destroy(module.auxiliary);
    module.allocator.free(module.name);
    module.allocator.destroy(module);
}

/// Source `sqlite3VtabCreateModule()`.
pub fn createModuleEntry(registry: *Registry, name: []const u8, auxiliary: ?*anyopaque, destroy_auxiliary: ?DestroyAuxiliary) Error!?*Module {
    var module: ?*Module = null;
    if (destroy_auxiliary != null or auxiliary != null) {
        const value = registry.allocator.create(Module) catch return error.OutOfMemory;
        errdefer registry.allocator.destroy(value);
        const owned_name = registry.allocator.dupe(u8, name) catch return error.OutOfMemory;
        value.* = .{ .allocator = registry.allocator, .name = owned_name, .auxiliary = auxiliary, .destroy_auxiliary = destroy_auxiliary };
        module = value;
    }
    if (moduleIndex(registry, name)) |index| {
        const previous = registry.modules.items[index];
        if (module) |replacement| {
            registry.modules.items[index] = replacement;
        } else {
            _ = registry.modules.orderedRemove(index);
        }
        destroyModule(previous);
    } else if (module) |value| {
        registry.modules.append(registry.allocator, value) catch {
            destroyModule(value);
            return error.OutOfMemory;
        };
    }
    return module;
}

/// Source `createModule()`.
pub fn registerModule(registry: *Registry, name: []const u8, auxiliary: ?*anyopaque, destroy_auxiliary: ?DestroyAuxiliary) Error!void {
    _ = createModuleEntry(registry, name, auxiliary, destroy_auxiliary) catch |failure| {
        if (destroy_auxiliary) |destroy| destroy(auxiliary);
        registry.last_error = failure;
        return failure;
    };
}

/// Source `sqlite3_create_module()`.
pub fn createModule(registry: *Registry, name: []const u8, auxiliary: ?*anyopaque) Error!void {
    if (name.len == 0) return error.Misuse;
    try registerModule(registry, name, auxiliary, null);
}

/// Source `sqlite3_create_module_v2()`.
pub fn createModuleV2(registry: *Registry, name: []const u8, auxiliary: ?*anyopaque, destroy_auxiliary: ?DestroyAuxiliary) Error!void {
    if (name.len == 0) {
        if (destroy_auxiliary) |destroy| destroy(auxiliary);
        return error.Misuse;
    }
    try registerModule(registry, name, auxiliary, destroy_auxiliary);
}

/// Source `sqlite3_drop_modules()`.
pub fn dropModules(registry: *Registry, keep: ?[]const []const u8) void {
    var index = registry.modules.items.len;
    while (index > 0) {
        index -= 1;
        const module = registry.modules.items[index];
        var retained = false;
        if (keep) |names| {
            for (names) |name| {
                if (std.mem.eql(u8, name, module.name)) {
                    retained = true;
                    break;
                }
            }
        }
        if (!retained) {
            _ = registry.modules.orderedRemove(index);
            destroyModule(module);
        }
    }
}

/// Source `sqlite3VtabUnlock()`.
pub fn unlockInstance(registry: *Registry, instance: *Instance) void {
    std.debug.assert(instance.reference_count > 0);
    instance.reference_count -= 1;
    if (instance.reference_count != 0) return;
    if (instance.disconnect_callback) |disconnect_callback| {
        _ = disconnect_callback(instance.context);
    }
    if (instance.module.reference_count > 0) {
        instance.module.reference_count -= 1;
    }
    registry.allocator.destroy(instance);
}

/// Source `vtabDisconnectAll()`.
pub fn disconnectAll(registry: *Registry, table: *Table, retain: ?*Instance) Error!?*Instance {
    var retained: ?*Instance = null;
    var index = table.instances.items.len;
    while (index > 0) {
        index -= 1;
        const instance = table.instances.items[index];
        if (retain != null and instance == retain.?) {
            retained = instance;
            continue;
        }
        _ = table.instances.orderedRemove(index);
        registry.deferred_disconnects.append(registry.allocator, instance) catch return error.OutOfMemory;
    }
    return retained;
}

/// Source `sqlite3VtabDisconnect()`.
pub fn disconnect(registry: *Registry, table: *Table, instance: *Instance) void {
    for (table.instances.items, 0..) |candidate, index| {
        if (candidate == instance) {
            _ = table.instances.orderedRemove(index);
            unlockInstance(registry, candidate);
            return;
        }
    }
}

/// Source `sqlite3VtabClear()`.
pub fn clearTable(registry: *Registry, table: *Table, account_only: bool) void {
    if (!account_only) {
        _ = disconnectAll(registry, table, null) catch null;
    }
    for (table.module_arguments.items) |argument| table.allocator.free(argument);
    table.module_arguments.clearRetainingCapacity();
}

fn parseColumn(table: *Table, definition: []const u8) Error!void {
    const trimmed = std.mem.trim(u8, definition, " \t\r\n");
    if (trimmed.len == 0) return;
    const split = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    const name = table.allocator.dupe(u8, trimmed[0..split]) catch return error.OutOfMemory;
    errdefer table.allocator.free(name);
    var type_name = table.allocator.dupe(u8, std.mem.trim(u8, trimmed[split..], " \t\r\n")) catch return error.OutOfMemory;
    errdefer table.allocator.free(type_name);
    var hidden = false;
    var words = std.mem.tokenizeAny(u8, type_name, " \t\r\n");
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(table.allocator);
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "hidden")) {
            hidden = true;
            continue;
        }
        if (rebuilt.items.len != 0) rebuilt.append(table.allocator, ' ') catch return error.OutOfMemory;
        rebuilt.appendSlice(table.allocator, word) catch return error.OutOfMemory;
    }
    if (hidden) {
        table.allocator.free(type_name);
        type_name = rebuilt.toOwnedSlice(table.allocator) catch return error.OutOfMemory;
    }
    table.columns.append(table.allocator, .{ .name = name, .type_name = type_name, .hidden = hidden }) catch return error.OutOfMemory;
}

fn rollbackColumns(table: *Table, original_count: usize) void {
    while (table.columns.items.len > original_count) {
        const column = table.columns.pop().?;
        table.allocator.free(column.name);
        table.allocator.free(column.type_name);
    }
}

fn parseColumnList(table: *Table, source: []const u8) Error!void {
    var start: usize = 0;
    var depth: usize = 0;
    var quote: u8 = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        const byte = if (index == source.len) ',' else source[index];
        if (quote != 0) {
            if (byte == quote) {
                if (index + 1 < source.len and source[index + 1] == quote) {
                    index += 1;
                } else quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"' or byte == '`') {
            quote = byte;
        } else if (byte == '[') {
            quote = ']';
        } else if (byte == '(') {
            depth += 1;
        } else if (byte == ')') {
            if (depth == 0) return error.Syntax;
            depth -= 1;
        } else if (byte == ',' and depth == 0) {
            try parseColumn(table, source[start..index]);
            start = index + 1;
        }
    }
    if (quote != 0 or depth != 0) return error.Syntax;
}

/// Source `sqlite3_declare_vtab()`: validate CREATE TABLE tokens, parse a
/// complete nested/quoted column list atomically, and transfer WITHOUT ROWID
/// and primary-key properties to the virtual table.
pub fn declareVirtualTable(registry: *Registry, sql: []const u8) Error!void {
    const construction = registry.construction orelse return error.Misuse;
    if (construction.declared) return error.Misuse;
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "CREATE")) return error.Syntax;
    var token_end: usize = 6;
    while (token_end < trimmed.len and std.ascii.isWhitespace(trimmed[token_end])) {
        token_end += 1;
    }
    if (token_end + 5 > trimmed.len or !std.ascii.eqlIgnoreCase(trimmed[token_end .. token_end + 5], "TABLE")) return error.Syntax;
    const open_position = std.mem.indexOfScalarPos(u8, trimmed, token_end + 5, '(') orelse return error.Syntax;
    const close_position = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return error.Syntax;
    if (close_position <= open_position) return error.Syntax;
    const original_count = construction.table.columns.items.len;
    errdefer rollbackColumns(construction.table, original_count);
    try parseColumnList(construction.table, trimmed[open_position + 1 .. close_position]);
    if (construction.table.columns.items.len == original_count) return error.Syntax;
    const suffix = std.mem.trim(u8, trimmed[close_position + 1 ..], " \t\r\n;");
    const without_rowid = suffix.len != 0 and std.ascii.eqlIgnoreCase(suffix, "WITHOUT ROWID");
    if (suffix.len != 0 and !without_rowid) return error.Syntax;
    var primary_keys: usize = 0;
    for (construction.table.columns.items[original_count..]) |column| {
        if (std.ascii.indexOfIgnoreCase(column.type_name, "PRIMARY KEY") != null) primary_keys += 1;
    }
    if (without_rowid and construction.instance.writable and primary_keys != 1) return error.Constraint;
    construction.table.without_rowid = without_rowid;
    construction.table.no_visible_rowid = without_rowid;
    construction.table.primary_key_columns = primary_keys;
    construction.declared = true;
}

/// Source `sqlite3_vtab_on_conflict()`.
pub fn conflictMode(registry: *const Registry) u8 {
    const map = [_]u8{ 1, 2, 3, 4, 5 };
    std.debug.assert(registry.conflict_mode >= 1 and registry.conflict_mode <= 5);
    return map[registry.conflict_mode - 1];
}

/// Source `sqlite3_vtab_config()`.
pub fn configure(registry: *Registry, operation: ConfigOperation, value: bool) Error!void {
    const construction = registry.construction orelse return error.Misuse;
    switch (operation) {
        .constraint_support => construction.instance.constraint_support = value,
        .innocuous => construction.instance.risk = .low,
        .direct_only => construction.instance.risk = .high,
        .uses_all_schemas => construction.instance.all_schemas = true,
    }
}

test "checkpoint batch virtual table declaration parses quoted nested columns and WITHOUT ROWID" {
    var module = Module{ .allocator = std.testing.allocator, .name = @constCast("module"), .auxiliary = null, .destroy_auxiliary = null };
    var instance = Instance{ .module = &module, .writable = true };
    var table = Table{ .allocator = std.testing.allocator, .name = "sample" };
    defer table.deinit();
    var construction = Construction{ .table = &table, .instance = &instance };
    var registry = Registry{ .allocator = std.testing.allocator, .construction = &construction };
    try declareVirtualTable(&registry, "CREATE TABLE x(\"a,b\" TEXT, id INTEGER PRIMARY KEY, amount DECIMAL(10,2)) WITHOUT ROWID");
    try std.testing.expect(construction.declared);
    try std.testing.expect(table.without_rowid and table.no_visible_rowid);
    try std.testing.expectEqual(@as(usize, 3), table.columns.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.primary_key_columns);
    try std.testing.expectEqualStrings("DECIMAL(10,2)", table.columns.items[2].type_name);
}
