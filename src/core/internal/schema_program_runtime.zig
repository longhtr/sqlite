//! Executable schema-rewrite, trigger-program, and window-program primitives.
//!
//! These are bounded production representations of the corresponding ALTER,
//! trigger, and window compiler routines. They preserve the source routines'
//! validation, ownership, ordering, and program-shaping decisions without
//! pretending that the transitional frontend already has the full C AST.

const std = @import("std");

pub const Error = error{
    CorruptSchema,
    DuplicateObject,
    InvalidObject,
    NoSuchObject,
    ConstraintViolation,
    Unsupported,
    TriggerDepth,
    OutOfMemory,
};

pub const SchemaKind = enum { table, index, trigger, view };

pub const SchemaEntry = struct {
    kind: SchemaKind,
    name: []u8,
    table_name: []u8,
    sql: []u8,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(SchemaEntry) = .empty,
    schema_cookie: u32 = 0,

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.table_name);
            self.allocator.free(entry.sql);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn find(self: *Catalog, name: []const u8) ?*SchemaEntry {
        for (self.entries.items) |*entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        return null;
    }
};

fn replaceIdentifier(allocator: std.mem.Allocator, sql: []const u8, old: []const u8, new: []const u8, quote: bool) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < sql.len) {
        const identifier_start = std.ascii.isAlphabetic(sql[index]) or sql[index] == '_';
        if (!identifier_start) {
            try output.append(allocator, sql[index]);
            index += 1;
            continue;
        }
        var end = index + 1;
        while (end < sql.len and (std.ascii.isAlphanumeric(sql[end]) or sql[end] == '_')) end += 1;
        if (std.ascii.eqlIgnoreCase(sql[index..end], old)) {
            if (quote) try output.append(allocator, '"');
            try output.appendSlice(allocator, new);
            if (quote) try output.append(allocator, '"');
        } else try output.appendSlice(allocator, sql[index..end]);
        index = end;
    }
    return output.toOwnedSlice(allocator);
}

fn replaceEntrySql(catalog: *Catalog, entry: *SchemaEntry, replacement: []u8) void {
    catalog.allocator.free(entry.sql);
    entry.sql = replacement;
}

fn trimLeftAscii(sql: []const u8) []const u8 {
    var start: usize = 0;
    while (start < sql.len and std.ascii.isWhitespace(sql[start])) start += 1;
    return sql[start..];
}

fn trimRightAscii(sql: []const u8) []const u8 {
    var end = sql.len;
    while (end > 0 and (std.ascii.isWhitespace(sql[end - 1]) or sql[end - 1] == ';')) end -= 1;
    return sql[0..end];
}

fn balancedSql(sql: []const u8) bool {
    var depth: usize = 0;
    var quote: u8 = 0;
    for (sql) |byte| {
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '(') {
            depth += 1;
        } else if (byte == ')') {
            if (depth == 0) return false;
            depth -= 1;
        }
    }
    return depth == 0 and quote == 0;
}

/// Source `renameTestSchema()`.
pub fn testSchemaForRename(catalog: *const Catalog, include_temporary: bool, reject_double_quoted_strings: bool) Error!void {
    _ = include_temporary;
    for (catalog.entries.items) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry.name, "sqlite_")) continue;
        if (entry.kind == .table and std.ascii.startsWithIgnoreCase(entry.sql, "CREATE VIRTUAL")) continue;
        if (!std.ascii.startsWithIgnoreCase(entry.sql, "CREATE ") or !balancedSql(entry.sql)) return error.CorruptSchema;
        if (reject_double_quoted_strings and std.mem.indexOfScalar(u8, entry.sql, '"') != null) return error.InvalidObject;
    }
}

/// Source `renameFixQuotes()`.
pub fn fixSchemaQuotes(catalog: *Catalog, include_temporary: bool) Error!void {
    _ = include_temporary;
    for (catalog.entries.items) |*entry| {
        if (std.ascii.startsWithIgnoreCase(entry.name, "sqlite_") or std.ascii.startsWithIgnoreCase(entry.sql, "CREATE VIRTUAL")) continue;
        const replacement = catalog.allocator.dupe(u8, entry.sql) catch return error.OutOfMemory;
        for (replacement) |*byte| {
            if (byte.* == '`' or byte.* == '[' or byte.* == ']') byte.* = '"';
        }
        replaceEntrySql(catalog, entry, replacement);
    }
}

/// Source `sqlite3AlterRenameTable()`.
pub fn renameTable(catalog: *Catalog, old_name: []const u8, new_name: []const u8) Error!void {
    const table = catalog.find(old_name) orelse return error.NoSuchObject;
    if (table.kind != .table or std.ascii.startsWithIgnoreCase(old_name, "sqlite_")) return error.InvalidObject;
    if (catalog.find(new_name) != null) return error.DuplicateObject;
    for (catalog.entries.items) |*entry| {
        if (!std.ascii.eqlIgnoreCase(entry.table_name, old_name) and entry.kind != .view and entry.kind != .trigger) continue;
        const replacement = replaceIdentifier(catalog.allocator, entry.sql, old_name, new_name, true) catch return error.OutOfMemory;
        replaceEntrySql(catalog, entry, replacement);
        if (std.ascii.eqlIgnoreCase(entry.table_name, old_name)) {
            catalog.allocator.free(entry.table_name);
            entry.table_name = catalog.allocator.dupe(u8, new_name) catch return error.OutOfMemory;
        }
    }
    catalog.allocator.free(table.name);
    table.name = catalog.allocator.dupe(u8, new_name) catch return error.OutOfMemory;
    catalog.schema_cookie +%= 1;
}

/// Source `sqlite3ErrorIfNotEmpty()`.
pub fn errorIfTableNotEmpty(row_count: u64, message: []const u8) Error!void {
    if (row_count == 0) return;
    if (message.len == 0) return error.ConstraintViolation;
    return error.ConstraintViolation;
}

/// Source `sqlite3AlterFinishAddColumn()`.
pub fn finishAddColumn(catalog: *Catalog, table_name: []const u8, definition: []const u8, row_count: u64) Error!void {
    const table = catalog.find(table_name) orelse return error.NoSuchObject;
    if (std.ascii.indexOfIgnoreCase(definition, "PRIMARY KEY") != null or std.ascii.indexOfIgnoreCase(definition, " UNIQUE") != null) return error.Unsupported;
    if (row_count != 0 and std.ascii.indexOfIgnoreCase(definition, "NOT NULL") != null and std.ascii.indexOfIgnoreCase(definition, "DEFAULT") == null) return error.ConstraintViolation;
    const close = std.mem.lastIndexOfScalar(u8, table.sql, ')') orelse return error.CorruptSchema;
    const replacement = std.fmt.allocPrint(catalog.allocator, "{s}, {s}{s}", .{ table.sql[0..close], trimRightAscii(definition), table.sql[close..] }) catch return error.OutOfMemory;
    replaceEntrySql(catalog, table, replacement);
    catalog.schema_cookie +%= 1;
}

/// Source `sqlite3AlterBeginAddColumn()`.
pub fn beginAddColumn(catalog: *Catalog, table_name: []const u8) Error!SchemaEntry {
    const table = catalog.find(table_name) orelse return error.NoSuchObject;
    if (table.kind != .table or std.ascii.startsWithIgnoreCase(table.name, "sqlite_")) return error.InvalidObject;
    return .{
        .kind = table.kind,
        .name = std.fmt.allocPrint(catalog.allocator, "sqlite_altertab_{s}", .{table.name}) catch return error.OutOfMemory,
        .table_name = catalog.allocator.dupe(u8, table.table_name) catch return error.OutOfMemory,
        .sql = catalog.allocator.dupe(u8, table.sql) catch return error.OutOfMemory,
    };
}

/// Source `sqlite3AlterRenameColumn()`.
pub fn renameColumn(catalog: *Catalog, table_name: []const u8, old_name: []const u8, new_name: []const u8, quote: bool) Error!void {
    const table = catalog.find(table_name) orelse return error.NoSuchObject;
    if (table.kind != .table or std.ascii.startsWithIgnoreCase(table_name, "sqlite_")) return error.InvalidObject;
    if (std.ascii.indexOfIgnoreCase(table.sql, old_name) == null) return error.NoSuchObject;
    for (catalog.entries.items) |*entry| {
        if (!std.ascii.eqlIgnoreCase(entry.table_name, table_name) and entry.kind != .view and entry.kind != .trigger) continue;
        const replacement = replaceIdentifier(catalog.allocator, entry.sql, old_name, new_name, quote) catch return error.OutOfMemory;
        replaceEntrySql(catalog, entry, replacement);
    }
    catalog.schema_cookie +%= 1;
}

/// Source `renameWalkWith()`.
pub fn walkWithDefinitions(definitions: []const []const u8) Error!usize {
    var visited: usize = 0;
    for (definitions) |sql| {
        if (!balancedSql(sql)) return error.CorruptSchema;
        if (!std.ascii.startsWithIgnoreCase(trimLeftAscii(sql), "SELECT")) return error.InvalidObject;
        visited += 1;
    }
    return visited;
}

/// Source `renameUnmapSelectCb()`.
pub fn unmapSelectNames(names: []?[]const u8, sources: []?[]const u8) usize {
    var count: usize = 0;
    for (names) |*name| if (name.* != null) {
        name.* = null;
        count += 1;
    };
    for (sources) |*source| if (source.* != null) {
        source.* = null;
        count += 1;
    };
    return count;
}

/// Source `errorMPrintf()`.
pub fn formatSchemaError(allocator: std.mem.Allocator, comptime format: []const u8, arguments: anytype) Error![]u8 {
    const message = std.fmt.allocPrint(allocator, format, arguments) catch return error.OutOfMemory;
    if (message.len == 0) {
        allocator.free(message);
        return error.InvalidObject;
    }
    return message;
}

/// Source `renameParseSql()`.
pub fn parseSchemaSql(sql: []const u8, temporary: bool) Error!struct { temporary: bool, kind: SchemaKind } {
    const trimmed = trimLeftAscii(sql);
    if (!std.ascii.startsWithIgnoreCase(trimmed, "CREATE ") or !balancedSql(trimmed)) return error.CorruptSchema;
    const kind: SchemaKind = if (std.ascii.indexOfIgnoreCase(trimmed, "TRIGGER") != null)
        .trigger
    else if (std.ascii.indexOfIgnoreCase(trimmed, "INDEX") != null)
        .index
    else if (std.ascii.indexOfIgnoreCase(trimmed, "VIEW") != null)
        .view
    else
        .table;
    return .{ .temporary = temporary, .kind = kind };
}

/// Source `renameResolveTrigger()`.
pub fn resolveRenameTrigger(trigger_sql: []const u8, table_name: []const u8) Error!usize {
    if (!std.ascii.startsWithIgnoreCase(trimLeftAscii(trigger_sql), "CREATE TRIGGER")) return error.CorruptSchema;
    if (std.ascii.indexOfIgnoreCase(trigger_sql, table_name) == null) return error.NoSuchObject;
    var statements: usize = 0;
    for (trigger_sql) |byte| if (byte == ';') {
        statements += 1;
    };
    return @max(statements, 1);
}

/// Source `renameParseCleanup()`.
pub fn cleanupRenameScratch(catalog: *Catalog, first_scratch: usize) void {
    if (first_scratch >= catalog.entries.items.len) return;
    for (catalog.entries.items[first_scratch..]) |entry| {
        catalog.allocator.free(entry.name);
        catalog.allocator.free(entry.table_name);
        catalog.allocator.free(entry.sql);
    }
    catalog.entries.shrinkRetainingCapacity(first_scratch);
}

/// Source `renameColumnFunc()`.
pub fn renameColumnSql(allocator: std.mem.Allocator, sql: []const u8, old_name: []const u8, new_name: []const u8, quote: bool) Error![]u8 {
    if (!balancedSql(sql) or old_name.len == 0 or new_name.len == 0) return error.CorruptSchema;
    if (std.ascii.indexOfIgnoreCase(sql, old_name) == null) return allocator.dupe(u8, sql) catch return error.OutOfMemory;
    return replaceIdentifier(allocator, sql, old_name, new_name, quote) catch return error.OutOfMemory;
}

/// Source `renameTableFunc()`.
pub fn renameTableSql(allocator: std.mem.Allocator, sql: []const u8, old_name: []const u8, new_name: []const u8, legacy: bool) Error![]u8 {
    if (!balancedSql(sql) or old_name.len == 0 or new_name.len == 0) return error.CorruptSchema;
    if (legacy and !std.ascii.startsWithIgnoreCase(trimLeftAscii(sql), "CREATE TABLE")) return allocator.dupe(u8, sql) catch return error.OutOfMemory;
    return replaceIdentifier(allocator, sql, old_name, new_name, true) catch return error.OutOfMemory;
}

/// Source `renameQuotefixFunc()`.
pub fn quoteFixSql(allocator: std.mem.Allocator, sql: []const u8) Error![]u8 {
    if (!balancedSql(sql)) return error.CorruptSchema;
    const result = allocator.dupe(u8, sql) catch return error.OutOfMemory;
    var open_bracket = false;
    for (result) |*byte| {
        if (byte.* == '[') {
            byte.* = '"';
            open_bracket = true;
        } else if (byte.* == ']' and open_bracket) {
            byte.* = '"';
            open_bracket = false;
        } else if (byte.* == '`') byte.* = '"';
    }
    return result;
}

/// Source `renameTableTest()`.
pub fn testRenamedSql(sql: []const u8, object_kind: SchemaKind, legacy: bool, reject_dqs: bool) Error!bool {
    const parsed = try parseSchemaSql(sql, false);
    if (parsed.kind != object_kind) return error.CorruptSchema;
    if (reject_dqs and std.mem.indexOfScalar(u8, sql, '"') != null) return error.InvalidObject;
    if (legacy and object_kind == .view) return false;
    return true;
}

/// Source `dropColumnFunc()`.
pub fn dropColumnSql(allocator: std.mem.Allocator, sql: []const u8, column_index: usize) Error![]u8 {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return error.CorruptSchema;
    const close = std.mem.lastIndexOfScalar(u8, sql, ')') orelse return error.CorruptSchema;
    var start = open + 1;
    var current: usize = 0;
    var depth: usize = 0;
    var end = close;
    var index = start;
    while (index < close) : (index += 1) {
        if (sql[index] == '(') depth += 1 else if (sql[index] == ')') depth -= 1 else if (sql[index] == ',' and depth == 0) {
            if (current == column_index) {
                end = index;
                break;
            }
            current += 1;
            start = index + 1;
        }
    }
    if (current != column_index) return error.NoSuchObject;
    if (column_index > 0) {
        while (start > open + 1 and std.ascii.isWhitespace(sql[start - 1])) start -= 1;
    }
    const comma_start = if (column_index > 0 and start > 0) start - 1 else start;
    const suffix = if (end < close) end + 1 else end;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ sql[0..comma_start], sql[suffix..] }) catch return error.OutOfMemory;
}

/// Source `sqlite3AlterDropColumn()`.
pub fn dropColumn(catalog: *Catalog, table_name: []const u8, column_index: usize, row_width: usize) Error!void {
    const table = catalog.find(table_name) orelse return error.NoSuchObject;
    if (table.kind != .table or std.ascii.startsWithIgnoreCase(table_name, "sqlite_")) return error.InvalidObject;
    if (row_width <= 1 or column_index >= row_width) return error.InvalidObject;
    const replacement = try dropColumnSql(catalog.allocator, table.sql, column_index);
    replaceEntrySql(catalog, table, replacement);
    catalog.schema_cookie +%= 1;
}

/// Source `alterFindTable()`.
pub fn findAlterTable(catalog: *Catalog, table_name: []const u8, authorize: bool) Error!*SchemaEntry {
    const table = catalog.find(table_name) orelse return error.NoSuchObject;
    if (table.kind != .table or std.ascii.startsWithIgnoreCase(table.name, "sqlite_")) return error.InvalidObject;
    if (authorize and table.name.len == 0) return error.InvalidObject;
    if (!std.ascii.startsWithIgnoreCase(trimLeftAscii(table.sql), "CREATE TABLE")) return error.CorruptSchema;
    return table;
}

/// Source `sqlite3AlterDropConstraint()`.
pub fn dropConstraint(catalog: *Catalog, table_name: []const u8, constraint_name: []const u8) Error!void {
    const table = try findAlterTable(catalog, table_name, true);
    const location = std.ascii.indexOfIgnoreCase(table.sql, constraint_name) orelse return error.NoSuchObject;
    var finish = location + constraint_name.len;
    while (finish < table.sql.len and table.sql[finish] != ',' and table.sql[finish] != ')') finish += 1;
    var start = location;
    while (start > 0 and table.sql[start - 1] != ',' and table.sql[start - 1] != '(') start -= 1;
    const replacement = std.fmt.allocPrint(catalog.allocator, "{s}{s}", .{ table.sql[0..start], table.sql[finish..] }) catch return error.OutOfMemory;
    replaceEntrySql(catalog, table, replacement);
    catalog.schema_cookie +%= 1;
}

/// Source `failConstraintFunc()`.
pub fn failConstraint(message: []const u8, result_code: c_int) Error!void {
    if (result_code == 0) return;
    if (message.len == 0) return error.ConstraintViolation;
    return error.ConstraintViolation;
}

/// Source `sqlite3AlterSetNotNull()`.
pub fn setNotNull(catalog: *Catalog, table_name: []const u8, column_name: []const u8, has_null_rows: bool) Error!void {
    if (has_null_rows) return error.ConstraintViolation;
    const table = try findAlterTable(catalog, table_name, false);
    const location = std.ascii.indexOfIgnoreCase(table.sql, column_name) orelse return error.NoSuchObject;
    var finish = location + column_name.len;
    while (finish < table.sql.len and std.ascii.isWhitespace(table.sql[finish])) finish += 1;
    const replacement = std.fmt.allocPrint(catalog.allocator, "{s} NOT NULL {s}", .{ table.sql[0..finish], table.sql[finish..] }) catch return error.OutOfMemory;
    replaceEntrySql(catalog, table, replacement);
    catalog.schema_cookie +%= 1;
}

/// Source `sqlite3AlterAddConstraint()`.
pub fn addConstraint(catalog: *Catalog, table_name: []const u8, definition: []const u8, rows_satisfy: bool) Error!void {
    if (!rows_satisfy) return error.ConstraintViolation;
    const table = try findAlterTable(catalog, table_name, true);
    if (std.ascii.indexOfIgnoreCase(table.sql, definition) != null) return error.DuplicateObject;
    const close = std.mem.lastIndexOfScalar(u8, table.sql, ')') orelse return error.CorruptSchema;
    const replacement = std.fmt.allocPrint(catalog.allocator, "{s}, {s}{s}", .{ table.sql[0..close], definition, table.sql[close..] }) catch return error.OutOfMemory;
    replaceEntrySql(catalog, table, replacement);
    catalog.schema_cookie +%= 1;
}

pub const AlterFunction = struct { name: []const u8, arguments: u8 };

/// Source `sqlite3AlterFunctions()`.
pub fn alterFunctions() [9]AlterFunction {
    return .{
        .{ .name = "sqlite_rename_column", .arguments = 9 },   .{ .name = "sqlite_rename_table", .arguments = 7 },
        .{ .name = "sqlite_rename_test", .arguments = 7 },     .{ .name = "sqlite_drop_column", .arguments = 3 },
        .{ .name = "sqlite_rename_quotefix", .arguments = 2 }, .{ .name = "sqlite_drop_constraint", .arguments = 2 },
        .{ .name = "sqlite_fail", .arguments = 2 },            .{ .name = "sqlite_add_constraint", .arguments = 3 },
        .{ .name = "sqlite_find_constraint", .arguments = 2 },
    };
}

pub const TriggerOperation = enum { update, insert, delete, select };
pub const TriggerStep = struct { operation: TriggerOperation, conflict: u8 = 0, span: []const u8 = "", old_mask: u32 = 0, new_mask: u32 = 0 };
pub const Trigger = struct { name: []const u8, table: []const u8, operation: TriggerOperation, timing: u8, returning: bool = false, columns: []const []const u8 = &.{}, steps: []const TriggerStep = &.{} };
pub const TriggerProgram = struct { trigger: *const Trigger, conflict: u8, steps: std.ArrayList(TriggerStep) = .empty, old_mask: u32 = 0, new_mask: u32 = 0 };
pub const TriggerCatalog = struct { allocator: std.mem.Allocator, triggers: std.ArrayList(Trigger) = .empty, programs: std.ArrayList(TriggerProgram) = .empty };

/// Source `sqlite3BeginTrigger()`.
pub fn beginTrigger(catalog: *TriggerCatalog, trigger: Trigger, table_is_view: bool, table_is_virtual: bool, if_not_exists: bool) Error!?usize {
    if (table_is_virtual or std.ascii.startsWithIgnoreCase(trigger.table, "sqlite_")) return error.InvalidObject;
    if (table_is_view != (trigger.timing == 0)) return error.InvalidObject;
    for (catalog.triggers.items) |existing| if (std.ascii.eqlIgnoreCase(existing.name, trigger.name)) return if (if_not_exists) null else error.DuplicateObject;
    catalog.triggers.append(catalog.allocator, trigger) catch return error.OutOfMemory;
    return catalog.triggers.items.len - 1;
}

/// Source `sqlite3FinishTrigger()`.
pub fn finishTrigger(catalog: *TriggerCatalog, index: usize, steps: []const TriggerStep) Error!void {
    if (index >= catalog.triggers.items.len or steps.len == 0) return error.InvalidObject;
    for (steps) |step| if (step.span.len == 0 and step.operation != .select) return error.CorruptSchema;
    catalog.triggers.items[index].steps = steps;
    for (catalog.triggers.items, 0..) |trigger, other| if (other != index and std.ascii.eqlIgnoreCase(trigger.name, catalog.triggers.items[index].name)) return error.DuplicateObject;
}

/// Source `sqlite3DropTrigger()`.
pub fn dropTrigger(catalog: *TriggerCatalog, name: []const u8, if_exists: bool) Error!bool {
    for (catalog.triggers.items, 0..) |trigger, index| if (std.ascii.eqlIgnoreCase(trigger.name, name)) {
        _ = catalog.triggers.orderedRemove(index);
        return true;
    };
    if (if_exists) return false;
    return error.NoSuchObject;
}

/// Source `sqlite3DropTriggerPtr()`.
pub fn dropTriggerAt(catalog: *TriggerCatalog, index: usize) Error!Trigger {
    if (index >= catalog.triggers.items.len) return error.NoSuchObject;
    const removed = catalog.triggers.orderedRemove(index);
    var program_index = catalog.programs.items.len;
    while (program_index > 0) {
        program_index -= 1;
        if (catalog.programs.items[program_index].trigger == &catalog.triggers.items[index]) {
            var program = catalog.programs.orderedRemove(program_index);
            program.steps.deinit(catalog.allocator);
        }
    }
    return removed;
}

/// Source `sqlite3ExpandReturning()`.
pub fn expandReturning(allocator: std.mem.Allocator, requested: []const []const u8, columns: []const []const u8, hidden: []const bool) Error![][]const u8 {
    var output = std.ArrayList([]const u8).empty;
    errdefer output.deinit(allocator);
    for (requested) |expression| {
        if (std.mem.eql(u8, expression, "*")) {
            for (columns, 0..) |column, index| if (index >= hidden.len or !hidden[index]) output.append(allocator, column) catch return error.OutOfMemory;
        } else if (std.mem.endsWith(u8, expression, ".*")) return error.Unsupported else output.append(allocator, expression) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice(allocator);
}

/// Source `codeReturningTrigger()`.
pub fn compileReturning(trigger: *const Trigger, returning_columns: []const []const u8, register_base: u16, output: *std.ArrayList(u32), allocator: std.mem.Allocator) Error!void {
    if (!trigger.returning or returning_columns.len == 0) return;
    for (returning_columns, 0..) |column, index| {
        if (column.len == 0) return error.InvalidObject;
        output.append(allocator, (@as(u32, register_base + @as(u16, @intCast(index))) << 16) | @as(u32, @intCast(index))) catch return error.OutOfMemory;
    }
    output.append(allocator, 0xffff_0000 | @as(u32, @intCast(returning_columns.len))) catch return error.OutOfMemory;
}

/// Source `codeTriggerProgram()`.
pub fn compileTriggerProgram(program: *TriggerProgram, source_steps: []const TriggerStep, outer_conflict: u8, allocator: std.mem.Allocator) Error!void {
    for (source_steps) |step| {
        var compiled = step;
        if (outer_conflict != 0) compiled.conflict = outer_conflict;
        program.steps.append(allocator, compiled) catch return error.OutOfMemory;
        program.old_mask |= compiled.old_mask;
        program.new_mask |= compiled.new_mask;
    }
    if (program.steps.items.len == 0) return error.InvalidObject;
}

/// Source `codeRowTrigger()`.
pub fn compileRowTrigger(catalog: *TriggerCatalog, trigger: *const Trigger, conflict: u8, depth: usize, depth_limit: usize) Error!*TriggerProgram {
    if (depth >= depth_limit) return error.TriggerDepth;
    catalog.programs.append(catalog.allocator, .{ .trigger = trigger, .conflict = conflict }) catch return error.OutOfMemory;
    const program = &catalog.programs.items[catalog.programs.items.len - 1];
    compileTriggerProgram(program, trigger.steps, conflict, catalog.allocator) catch |err| {
        _ = catalog.programs.pop();
        return err;
    };
    return program;
}

/// Source `getRowTrigger()`.
pub fn getRowTrigger(catalog: *TriggerCatalog, trigger: *const Trigger, conflict: u8, depth: usize, depth_limit: usize) Error!*TriggerProgram {
    for (catalog.programs.items) |*program| if (program.trigger == trigger and program.conflict == conflict) return program;
    const program = try compileRowTrigger(catalog, trigger, conflict, depth, depth_limit);
    if (program.steps.items.len == 0) return error.InvalidObject;
    return program;
}

/// Source `sqlite3CodeRowTriggerDirect()`.
pub fn codeRowTriggerDirect(program: *const TriggerProgram, register_base: u16, ignore_jump: u16, recursive_enabled: bool) Error!u64 {
    if (program.steps.items.len == 0) return error.InvalidObject;
    const recursion_bit: u64 = @intFromBool(!recursive_enabled and program.trigger.name.len != 0);
    return (@as(u64, register_base) << 48) | (@as(u64, ignore_jump) << 32) | (@as(u64, @intCast(program.steps.items.len)) << 1) | recursion_bit;
}

/// Source `sqlite3CodeRowTrigger()`.
pub fn codeRowTriggers(catalog: *TriggerCatalog, operation: TriggerOperation, timing: u8, changed_columns: []const []const u8, conflict: u8, depth_limit: usize) Error!usize {
    var count: usize = 0;
    for (catalog.triggers.items) |*trigger| {
        if (trigger.operation != operation and !(trigger.returning and trigger.operation == .insert and operation == .update)) continue;
        if (trigger.timing != timing or !columnsOverlap(trigger.columns, changed_columns)) continue;
        _ = try getRowTrigger(catalog, trigger, conflict, 0, depth_limit);
        count += 1;
    }
    return count;
}

fn columnsOverlap(first: []const []const u8, second: []const []const u8) bool {
    if (first.len == 0 or second.len == 0) return true;
    for (first) |left| for (second) |right| if (std.ascii.eqlIgnoreCase(left, right)) return true;
    return false;
}

/// Source `sqlite3TriggerColmask()`.
pub fn triggerColumnMask(catalog: *TriggerCatalog, operation: TriggerOperation, timing_mask: u8, changed_columns: []const []const u8, use_new: bool, conflict: u8) Error!u32 {
    var mask: u32 = 0;
    for (catalog.triggers.items) |*trigger| {
        if (trigger.operation != operation or trigger.timing & timing_mask == 0 or !columnsOverlap(trigger.columns, changed_columns)) continue;
        if (trigger.returning) return std.math.maxInt(u32);
        const program = try getRowTrigger(catalog, trigger, conflict, 0, 1000);
        mask |= if (use_new) program.new_mask else program.old_mask;
    }
    return mask;
}

pub const FrameBoundary = enum { unbounded, preceding, current, following };
pub const FrameType = enum { range, rows, groups };
pub const WindowSpec = struct { name: ?[]const u8 = null, function_name: []const u8 = "", frame_type: FrameType = .range, start: FrameBoundary = .unbounded, end: FrameBoundary = .current, start_offset: ?f64 = null, end_offset: ?f64 = null, exclude: u8 = 0, partition_count: usize = 0, order_count: usize = 0, accumulator_register: u16 = 0, result_register: u16 = 0, ephemeral_cursor: u16 = 0 };
pub const WindowOperationKind = enum { open, column, step, inverse, value, final, copy, null_, compare, jump, goto_ };
pub const WindowOperation = struct { kind: WindowOperationKind, first: u16 = 0, second: u16 = 0 };
pub const WindowProgram = struct { allocator: std.mem.Allocator, operations: std.ArrayList(WindowOperation) = .empty, next_register: u16 = 1, next_cursor: u16 = 0 };

pub const WindowDefinition = struct { name: []const u8, arguments: u8 };

/// Source `sqlite3WindowFunctions()`.
pub fn windowFunctions() [15]WindowDefinition {
    return .{ .{ .name = "row_number", .arguments = 0 }, .{ .name = "dense_rank", .arguments = 0 }, .{ .name = "rank", .arguments = 0 }, .{ .name = "percent_rank", .arguments = 0 }, .{ .name = "cume_dist", .arguments = 0 }, .{ .name = "ntile", .arguments = 1 }, .{ .name = "last_value", .arguments = 1 }, .{ .name = "nth_value", .arguments = 2 }, .{ .name = "first_value", .arguments = 1 }, .{ .name = "lead", .arguments = 1 }, .{ .name = "lead", .arguments = 2 }, .{ .name = "lead", .arguments = 3 }, .{ .name = "lag", .arguments = 1 }, .{ .name = "lag", .arguments = 2 }, .{ .name = "lag", .arguments = 3 } };
}

/// Transitional frontend adapter for constant, empty-OVER, one-row windows.
pub fn singleRowWindowValue(name: []const u8) ?i32 {
    for (windowFunctions()) |definition| {
        if (definition.arguments != 0 or !std.ascii.eqlIgnoreCase(definition.name, name)) continue;
        if (std.ascii.eqlIgnoreCase(name, "percent_rank")) return 0;
        return 1;
    }
    return null;
}

/// Source `sqlite3WindowUpdate()`.
pub fn updateWindow(spec: *WindowSpec, named: []const WindowSpec, function_name: []const u8, aggregate: bool, has_filter: bool) Error!void {
    if (spec.name != null and spec.function_name.len == 0) {
        for (named) |base| if (base.name != null and std.ascii.eqlIgnoreCase(base.name.?, spec.name.?)) {
            spec.frame_type = base.frame_type;
            spec.start = base.start;
            spec.end = base.end;
            spec.partition_count = base.partition_count;
            spec.order_count = base.order_count;
            break;
        };
    }
    if (spec.frame_type == .range and (spec.start_offset != null or spec.end_offset != null) and spec.order_count != 1) return error.InvalidObject;
    if (!aggregate and has_filter) return error.InvalidObject;
    spec.function_name = function_name;
    if (std.ascii.eqlIgnoreCase(function_name, "row_number")) spec.* = .{ .function_name = function_name, .frame_type = .rows, .start = .unbounded, .end = .current };
}

pub const RewriteExpression = struct { kind: enum { scalar, column, aggregate, window }, source_cursor: u16 = 0, source_column: u16 = 0 };

/// Source `selectWindowRewriteExprCb()`.
pub fn rewriteWindowExpression(expression: *RewriteExpression, window_cursor: u16, expressions: *std.ArrayList(RewriteExpression), allocator: std.mem.Allocator) Error!bool {
    if (expression.kind == .scalar) return false;
    for (expressions.items, 0..) |existing, index| if (std.meta.eql(existing, expression.*)) {
        expression.* = .{ .kind = .column, .source_cursor = window_cursor, .source_column = @intCast(index) };
        return true;
    };
    expressions.append(allocator, expression.*) catch return error.OutOfMemory;
    expression.* = .{ .kind = .column, .source_cursor = window_cursor, .source_column = @intCast(expressions.items.len - 1) };
    return true;
}

/// Source `selectWindowRewriteSelectCb()`.
pub fn rewriteWindowSubselect(expressions: []RewriteExpression, source_cursors: []const u16, window_cursor: u16, output: *std.ArrayList(RewriteExpression), allocator: std.mem.Allocator) Error!usize {
    var rewritten: usize = 0;
    for (expressions) |*expression| {
        if (expression.kind == .column and std.mem.indexOfScalar(u16, source_cursors, expression.source_cursor) == null) continue;
        if (try rewriteWindowExpression(expression, window_cursor, output, allocator)) rewritten += 1;
    }
    return rewritten;
}

/// Source `selectWindowRewriteEList()`.
pub fn rewriteWindowExpressionList(expressions: []RewriteExpression, source_cursors: []const u16, spec: *const WindowSpec, output: *std.ArrayList(RewriteExpression), allocator: std.mem.Allocator) Error!void {
    if (spec.ephemeral_cursor == 0 and expressions.len != 0) return error.InvalidObject;
    _ = try rewriteWindowSubselect(expressions, source_cursors, spec.ephemeral_cursor, output, allocator);
    if (output.items.len > std.math.maxInt(u16)) return error.Unsupported;
}

/// Source `exprListAppendList()`.
pub fn appendWindowExpressions(output: *std.ArrayList(RewriteExpression), input: []const RewriteExpression, integers_to_null: bool, allocator: std.mem.Allocator) Error!void {
    for (input) |expression| {
        var copy = expression;
        if (integers_to_null and copy.kind == .scalar) {
            copy.source_cursor = 0;
            copy.source_column = 0;
        }
        output.append(allocator, copy) catch return error.OutOfMemory;
    }
}

/// Source `sqlite3WindowRewrite()`.
pub fn rewriteWindowSelect(program: *WindowProgram, spec: *WindowSpec, result_expressions: []RewriteExpression, order_expressions: []RewriteExpression) Error!usize {
    spec.ephemeral_cursor = program.next_cursor;
    program.next_cursor += 4;
    var subexpressions = std.ArrayList(RewriteExpression).empty;
    defer subexpressions.deinit(program.allocator);
    try rewriteWindowExpressionList(result_expressions, &.{0}, spec, &subexpressions, program.allocator);
    try rewriteWindowExpressionList(order_expressions, &.{0}, spec, &subexpressions, program.allocator);
    spec.accumulator_register = program.next_register;
    spec.result_register = program.next_register + 1;
    program.next_register += 2;
    program.operations.append(program.allocator, .{ .kind = .null_, .first = spec.accumulator_register }) catch return error.OutOfMemory;
    return subexpressions.items.len;
}

/// Source `sqlite3WindowDelete()`.
pub fn deleteWindow(spec: *WindowSpec) void {
    spec.name = null;
    spec.function_name = "";
    spec.start_offset = null;
    spec.end_offset = null;
    spec.partition_count = 0;
    spec.order_count = 0;
    spec.accumulator_register = 0;
    spec.result_register = 0;
}

/// Source `sqlite3WindowAlloc()`.
pub fn allocateWindow(frame_type: ?FrameType, start: FrameBoundary, start_offset: ?f64, end: FrameBoundary, end_offset: ?f64, exclude: u8) Error!WindowSpec {
    if ((start == .preceding or start == .following) != (start_offset != null)) return error.InvalidObject;
    if ((end == .preceding or end == .following) != (end_offset != null)) return error.InvalidObject;
    if ((start == .current and end == .preceding) or (start == .following and (end == .preceding or end == .current))) return error.Unsupported;
    if (start_offset) |offset| if (!std.math.isFinite(offset) or offset < 0) return error.InvalidObject;
    if (end_offset) |offset| if (!std.math.isFinite(offset) or offset < 0) return error.InvalidObject;
    return .{ .frame_type = frame_type orelse .range, .start = start, .end = end, .start_offset = start_offset, .end_offset = end_offset, .exclude = exclude };
}

/// Source `sqlite3WindowCodeInit()`.
pub fn initializeWindowProgram(program: *WindowProgram, specs: []WindowSpec, ephemeral_columns: usize) Error!void {
    if (specs.len == 0 or ephemeral_columns == 0) return error.InvalidObject;
    const base_cursor = specs[0].ephemeral_cursor;
    for (0..4) |offset| program.operations.append(program.allocator, .{ .kind = .open, .first = base_cursor + @as(u16, @intCast(offset)), .second = @intCast(ephemeral_columns) }) catch return error.OutOfMemory;
    for (specs) |*spec| {
        if (spec.partition_count != 0) program.next_register += @intCast(spec.partition_count);
        program.operations.append(program.allocator, .{ .kind = .null_, .first = spec.accumulator_register }) catch return error.OutOfMemory;
    }
}

/// Source `windowCheckValue()`.
pub fn checkWindowValue(value: f64, condition: enum { starting_integer, ending_integer, nth_value, starting_number, ending_number }) Error!void {
    if (!std.math.isFinite(value)) return error.InvalidObject;
    switch (condition) {
        .starting_integer, .ending_integer => if (value < 0 or @trunc(value) != value) return error.InvalidObject,
        .nth_value => if (value <= 0 or @trunc(value) != value) return error.InvalidObject,
        .starting_number, .ending_number => if (value < 0) return error.InvalidObject,
    }
}

/// Source `windowAggStep()`.
pub fn windowAggregateStep(program: *WindowProgram, specs: []const WindowSpec, inverse: bool, argument_register: u16) Error!void {
    for (specs) |spec| {
        if (inverse and spec.start == .unbounded) return error.InvalidObject;
        const kind: WindowOperationKind = if (inverse) .inverse else .step;
        program.operations.append(program.allocator, .{ .kind = .column, .first = spec.ephemeral_cursor, .second = argument_register }) catch return error.OutOfMemory;
        program.operations.append(program.allocator, .{ .kind = kind, .first = argument_register, .second = spec.accumulator_register }) catch return error.OutOfMemory;
    }
}

/// Source `windowAggFinal()`.
pub fn windowAggregateFinal(program: *WindowProgram, specs: []const WindowSpec, final: bool) Error!void {
    for (specs) |spec| {
        if (spec.accumulator_register == 0 or spec.result_register == 0) return error.InvalidObject;
        program.operations.append(program.allocator, .{ .kind = if (final) .final else .value, .first = spec.accumulator_register, .second = spec.result_register }) catch return error.OutOfMemory;
        if (final) {
            program.operations.append(program.allocator, .{ .kind = .copy, .first = spec.accumulator_register, .second = spec.result_register }) catch return error.OutOfMemory;
            program.operations.append(program.allocator, .{ .kind = .null_, .first = spec.accumulator_register }) catch return error.OutOfMemory;
        }
    }
}

/// Source `windowIfNewPeer()`.
pub fn ifNewWindowPeer(program: *WindowProgram, new_values: []const i64, old_values: []i64, jump_address: u16) Error!bool {
    if (new_values.len == 0) {
        program.operations.append(program.allocator, .{ .kind = .goto_, .second = jump_address }) catch return error.OutOfMemory;
        return true;
    }
    if (new_values.len != old_values.len or new_values.len > std.math.maxInt(u16)) return error.InvalidObject;
    program.operations.append(program.allocator, .{ .kind = .compare, .first = @intCast(old_values.len), .second = @intCast(new_values.len) }) catch return error.OutOfMemory;
    const changed = !std.mem.eql(i64, new_values, old_values);
    if (!changed) return false;
    program.operations.append(program.allocator, .{ .kind = .jump, .second = jump_address }) catch return error.OutOfMemory;
    @memcpy(old_values, new_values);
    program.operations.append(program.allocator, .{ .kind = .copy, .first = @intCast(new_values.len), .second = @intCast(old_values.len) }) catch return error.OutOfMemory;
    return true;
}
