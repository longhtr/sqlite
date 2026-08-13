//! Bounded schema and mutation compiler behavior translated from SQLite.
const std = @import("std");
const query = @import("query_compiler.zig");
pub const Value = query.Value;
pub const Error = error{ Constraint, InvalidSchema, NoMemory, NotFound, ReadOnly, TooManyColumns, Unsupported };

pub const Affinity = enum { blob, text, numeric, integer, real };
pub const Conflict = enum { default, rollback, abort, fail, ignore, replace, update };
pub const Column = struct { name: []const u8, affinity: Affinity = .blob, not_null: bool = false, generated: ?*const fn ([]const Value) Value = null, default_value: Value = .null_, primary_key: bool = false };
pub const Index = struct { name: []const u8, columns: []const usize, unique: bool = false, primary: bool = false, partial: ?query.Predicate = null, rows: std.ArrayList([]Value) = .empty };
pub const ForeignKey = struct { from: []const usize, target_table: []const u8, target_columns: []const []const u8, on_delete: Conflict, on_update: Conflict };
pub const Table = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    columns: std.ArrayList(Column) = .empty,
    indexes: std.ArrayList(Index) = .empty,
    foreign_keys: std.ArrayList(ForeignKey) = .empty,
    rows: query.RowSet,
    integer_primary_key: ?usize = null,
    without_rowid: bool = false,
    strict: bool = false,
    is_view: bool = false,
    read_only: bool = false,
    autoincrement: bool = false,
    sequence: i64 = 0,
    root_page: u32 = 0,
    view_columns_loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Table {
        return .{ .allocator = allocator, .name = name, .rows = .{ .allocator = allocator } };
    }
    pub fn deinit(self: *Table) void {
        for (self.indexes.items) |*index| {
            for (index.rows.items) |row| self.allocator.free(row);
            index.rows.deinit(self.allocator);
        }
        self.indexes.deinit(self.allocator);
        self.foreign_keys.deinit(self.allocator);
        self.columns.deinit(self.allocator);
        self.rows.deinit();
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(Table) = .empty,
    schema_generation: u64 = 0,
    next_root_page: u32 = 2,
    temp_open: bool = false,
    verified: u64 = 0,
    statistics: std.StringHashMap(usize),
    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator, .statistics = std.StringHashMap(usize).init(allocator) };
    }
    pub fn deinit(self: *Catalog) void {
        for (self.tables.items) |*table| table.deinit();
        self.tables.deinit(self.allocator);
        self.statistics.deinit();
    }
};

pub const Operation = union(enum) { transaction: usize, verify_schema: usize, table_lock: struct { root: u32, write: bool }, create_root: u32, destroy_root: u32, schema_sql: []const u8, halt: struct { conflict: Conflict, message: []const u8 }, savepoint: struct { operation: u8, name: []const u8 }, insert: usize, delete: usize, update: usize };
pub const Program = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(Operation) = .empty,
    messages: std.ArrayList([]u8) = .empty,
    returning: query.RowSet,
    halted: bool = false,
    pub fn init(allocator: std.mem.Allocator) Program {
        return .{ .allocator = allocator, .returning = .{ .allocator = allocator } };
    }
    pub fn deinit(self: *Program) void {
        for (self.messages.items) |message| self.allocator.free(message);
        self.messages.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        self.returning.deinit();
    }
};
pub const Parse = struct { allocator: std.mem.Allocator, catalog: *Catalog, program: *Program, nested: usize = 0, errors: usize = 0, returning_columns: []const usize = &.{}, used_schemas: u64 = 0, write_schemas: u64 = 0, multi_write: bool = false, finished: bool = false };

fn findTable(catalog: *Catalog, name: []const u8) ?*Table {
    for (catalog.tables.items) |*table| {
        if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
    }
    return null;
}
fn affinityName(affinity: Affinity) []const u8 {
    return switch (affinity) {
        .blob => "",
        .text => " TEXT",
        .numeric => " NUM",
        .integer => " INT",
        .real => " REAL",
    };
}

/// Source `sqlite3FinishCoding()`.
pub fn finishCoding(parse: *Parse) Error!void {
    if (parse.nested != 0 or parse.errors != 0) return;
    for (0..@bitSizeOf(u64)) |database| {
        if (parse.used_schemas & (@as(u64, 1) << @intCast(database)) != 0) {
            parse.program.operations.append(parse.allocator, .{ .transaction = database }) catch return error.NoMemory;
            parse.program.operations.append(parse.allocator, .{ .verify_schema = database }) catch return error.NoMemory;
        }
    }
    for (parse.catalog.tables.items) |*table| {
        if (table.autoincrement) try beginAutoincrement(parse, table);
    }
    parse.finished = true;
}

pub const NestedCallback = *const fn (*Parse, []const u8) Error!void;
/// Source `sqlite3NestedParse()`.
pub fn nestedParse(parse: *Parse, sql: []const u8, callback: NestedCallback) Error!void {
    if (parse.errors != 0 or parse.nested >= 10) return error.InvalidSchema;
    parse.nested += 1;
    defer parse.nested -= 1;
    try callback(parse, sql);
}

/// Source `sqlite3StartTable()`.
pub fn startTable(parse: *Parse, name: []const u8, temporary: bool, view: bool, virtual: bool, if_not_exists: bool) Error!?*Table {
    _ = virtual;
    if (name.len == 0 or std.ascii.startsWithIgnoreCase(name, "sqlite_")) return error.InvalidSchema;
    if (findTable(parse.catalog, name)) |existing| {
        if (if_not_exists) return existing;
        return error.Constraint;
    }
    parse.catalog.tables.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    if (!view) parse.program.operations.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    var table = Table.init(parse.allocator, name);
    table.is_view = view;
    if (!view) {
        table.root_page = parse.catalog.next_root_page;
        parse.catalog.next_root_page += 1;
        parse.program.operations.appendAssumeCapacity(.{ .create_root = table.root_page });
    }
    parse.catalog.tables.appendAssumeCapacity(table);
    parse.used_schemas |= @as(u64, 1) << @intFromBool(temporary);
    parse.write_schemas |= @as(u64, 1) << @intFromBool(temporary);
    return &parse.catalog.tables.items[parse.catalog.tables.items.len - 1];
}

/// Source `sqlite3AddReturning()`.
pub fn addReturning(parse: *Parse, columns: []const usize) Error!void {
    if (parse.returning_columns.len != 0) return error.Constraint;
    parse.returning_columns = columns;
    parse.program.returning.rows.clearRetainingCapacity();
}

/// Source `sqlite3AddColumn()`.
pub fn addColumn(parse: *Parse, table: *Table, column: Column, limit: usize) Error!void {
    if (table.columns.items.len >= limit) return error.TooManyColumns;
    for (table.columns.items) |prior| {
        if (std.ascii.eqlIgnoreCase(prior.name, column.name)) return error.Constraint;
    }
    table.columns.append(parse.allocator, column) catch return error.NoMemory;
}

/// Source `sqlite3AddPrimaryKey()`.
pub fn addPrimaryKey(table: *Table, columns: []const usize, conflict: Conflict, autoincrement: bool) Error!void {
    _ = conflict;
    for (table.columns.items) |column| {
        if (column.primary_key) return error.Constraint;
    }
    for (columns) |column| {
        if (column >= table.columns.items.len) return error.NotFound;
        table.columns.items[column].primary_key = true;
    }
    if (columns.len == 1 and table.columns.items[columns[0]].affinity == .integer and !table.without_rowid) table.integer_primary_key = columns[0] else if (autoincrement) return error.InvalidSchema;
    table.autoincrement = autoincrement;
}

/// Source `createTableStmt()`.
pub fn createTableStatement(allocator: std.mem.Allocator, table: *const Table) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    output.appendSlice(allocator, "CREATE TABLE \"") catch return error.NoMemory;
    output.appendSlice(allocator, table.name) catch return error.NoMemory;
    output.appendSlice(allocator, "\"(") catch return error.NoMemory;
    for (table.columns.items, 0..) |column, index| {
        if (index != 0) output.appendSlice(allocator, ",") catch return error.NoMemory;
        output.appendSlice(allocator, column.name) catch return error.NoMemory;
        output.appendSlice(allocator, affinityName(column.affinity)) catch return error.NoMemory;
    }
    output.append(allocator, ')') catch return error.NoMemory;
    return output.toOwnedSlice(allocator) catch return error.NoMemory;
}

/// Source `convertToWithoutRowidTable()`.
pub fn convertToWithoutRowidTable(table: *Table) Error!void {
    if (table.autoincrement) return error.InvalidSchema;
    var primary_count: usize = 0;
    for (table.columns.items) |*column| {
        if (column.primary_key) {
            column.not_null = true;
            primary_count += 1;
        }
    }
    if (primary_count == 0) return error.InvalidSchema;
    table.without_rowid = true;
    table.integer_primary_key = null;
}

/// Source `sqlite3EndTable()`.
pub fn endTable(parse: *Parse, table: *Table, strict: bool, without_rowid: bool) Error!void {
    if (table.columns.items.len == 0 and !table.is_view) return error.InvalidSchema;
    table.strict = strict;
    if (strict) {
        for (table.columns.items) |column| {
            if (column.affinity == .blob and column.name.len == 0) return error.InvalidSchema;
        }
    }
    if (without_rowid) try convertToWithoutRowidTable(table);
    const sql = try createTableStatement(parse.allocator, table);
    defer parse.allocator.free(sql);
    parse.program.operations.append(parse.allocator, .{ .schema_sql = table.name }) catch return error.NoMemory;
    parse.catalog.schema_generation += 1;
}

/// Source `sqlite3CreateView()`.
pub fn createView(parse: *Parse, name: []const u8, column_names: []const []const u8, if_not_exists: bool) Error!?*Table {
    const table = try startTable(parse, name, false, true, false, if_not_exists) orelse return null;
    if (table.columns.items.len == 0) {
        for (column_names) |column_name| try addColumn(parse, table, .{ .name = column_name }, 2000);
    }
    table.view_columns_loaded = column_names.len != 0;
    try endTable(parse, table, false, false);
    return table;
}

/// Source `viewGetColumnNames()`.
pub fn viewGetColumnNames(parse: *Parse, table: *Table, result_names: []const []const u8) Error!void {
    if (!table.is_view) return;
    if (table.view_columns_loaded) return;
    if (result_names.len == 0) return error.InvalidSchema;
    for (result_names) |name| try addColumn(parse, table, .{ .name = name }, 2000);
    table.view_columns_loaded = true;
}

/// Source `destroyRootPage()`.
pub fn destroyRootPage(parse: *Parse, root_page: u32) Error!void {
    if (root_page < 2) return error.InvalidSchema;
    parse.program.operations.append(parse.allocator, .{ .destroy_root = root_page }) catch return error.NoMemory;
}

/// Source `destroyTable()`.
pub fn destroyTable(parse: *Parse, table: *const Table) Error!void {
    var roots = std.ArrayList(u32).empty;
    defer roots.deinit(parse.allocator);
    if (table.root_page >= 2) roots.append(parse.allocator, table.root_page) catch return error.NoMemory;
    for (table.indexes.items) |index| {
        _ = index;
        roots.append(parse.allocator, table.root_page + @as(u32, @intCast(roots.items.len))) catch return error.NoMemory;
    }
    std.sort.heap(u32, roots.items, {}, struct {
        fn less(_: void, left: u32, right: u32) bool {
            return left > right;
        }
    }.less);
    for (roots.items) |root_page| try destroyRootPage(parse, root_page);
}

/// Source `sqlite3ClearStatTables()`.
pub fn clearStatTables(catalog: *Catalog, object_name: []const u8) void {
    _ = catalog.statistics.remove(object_name);
}

/// Source `sqlite3CodeDropTable()`.
pub fn codeDropTable(parse: *Parse, table: *const Table) Error!void {
    clearStatTables(parse.catalog, table.name);
    if (!table.is_view) try destroyTable(parse, table);
    parse.program.operations.append(parse.allocator, .{ .schema_sql = table.name }) catch return error.NoMemory;
    parse.catalog.schema_generation += 1;
}

/// Source `sqlite3DropTable()`.
pub fn dropTable(parse: *Parse, name: []const u8, expect_view: bool, if_exists: bool) Error!void {
    var found: ?usize = null;
    for (parse.catalog.tables.items, 0..) |table, index| {
        if (std.ascii.eqlIgnoreCase(table.name, name)) {
            found = index;
            break;
        }
    }
    const index = found orelse {
        if (if_exists) {
            try codeVerifyNamedSchema(parse, null);
            return;
        }
        return error.NotFound;
    };
    if (parse.catalog.tables.items[index].is_view != expect_view) return error.InvalidSchema;
    if (parse.catalog.tables.items[index].read_only) return error.ReadOnly;
    try codeDropTable(parse, &parse.catalog.tables.items[index]);
    var removed = parse.catalog.tables.orderedRemove(index);
    removed.deinit();
}

/// Source `sqlite3CreateForeignKey()`.
pub fn createForeignKey(parse: *Parse, table: *Table, from: []const usize, target_table: []const u8, target_columns: []const []const u8, on_delete: Conflict, on_update: Conflict) Error!void {
    if (from.len == 0 or (target_columns.len != 0 and target_columns.len != from.len)) return error.InvalidSchema;
    for (from) |column| {
        if (column >= table.columns.items.len) return error.NotFound;
    }
    table.foreign_keys.append(parse.allocator, .{ .from = from, .target_table = target_table, .target_columns = target_columns, .on_delete = on_delete, .on_update = on_update }) catch return error.NoMemory;
}

fn indexRowsEqual(left: []const Value, right: []const Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!valueEqual(a, b)) return false;
    }
    return true;
}

/// Source `sqlite3RefillIndex()`.
pub fn refillIndex(parse: *Parse, table: *const Table, index: *Index) Error!void {
    for (index.rows.items) |row| parse.allocator.free(row);
    index.rows.clearRetainingCapacity();
    for (table.rows.rows.items) |row| {
        if (index.partial) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) continue;
        }
        const key = parse.allocator.alloc(Value, index.columns.len) catch return error.NoMemory;
        for (index.columns, 0..) |column, key_index| {
            if (column >= row.len) {
                parse.allocator.free(key);
                return error.InvalidSchema;
            }
            key[key_index] = row[column];
        }
        if (index.unique) {
            for (index.rows.items) |prior| {
                if (indexRowsEqual(prior, key)) {
                    parse.allocator.free(key);
                    return error.Constraint;
                }
            }
        }
        index.rows.append(parse.allocator, key) catch {
            parse.allocator.free(key);
            return error.NoMemory;
        };
    }
}

/// Source `sqlite3CreateIndex()`.
pub fn createIndex(parse: *Parse, table: *Table, name: []const u8, columns: []const usize, unique: bool, primary: bool, partial: ?query.Predicate, if_not_exists: bool) Error!void {
    if (columns.len == 0 or table.is_view) return error.InvalidSchema;
    for (columns) |column| {
        if (column >= table.columns.items.len) return error.NotFound;
    }
    for (table.indexes.items) |index| {
        if (std.ascii.eqlIgnoreCase(index.name, name)) {
            if (if_not_exists) return;
            return error.Constraint;
        }
    }
    var index = Index{ .name = name, .columns = columns, .unique = unique, .primary = primary, .partial = partial };
    errdefer {
        for (index.rows.items) |row| parse.allocator.free(row);
        index.rows.deinit(parse.allocator);
    }
    try refillIndex(parse, table, &index);
    table.indexes.append(parse.allocator, index) catch return error.NoMemory;
    parse.catalog.schema_generation += 1;
}

/// Source `sqlite3DropIndex()`.
pub fn dropIndex(parse: *Parse, table: *Table, name: []const u8, if_exists: bool) Error!void {
    var found: ?usize = null;
    for (table.indexes.items, 0..) |index, position| {
        if (std.ascii.eqlIgnoreCase(index.name, name)) {
            found = position;
            break;
        }
    }
    const position = found orelse {
        if (if_exists) {
            try codeVerifyNamedSchema(parse, null);
            return;
        }
        return error.NotFound;
    };
    if (table.indexes.items[position].primary) return error.Constraint;
    var removed = table.indexes.orderedRemove(position);
    for (removed.rows.items) |row| parse.allocator.free(row);
    removed.rows.deinit(parse.allocator);
    clearStatTables(parse.catalog, name);
    parse.catalog.schema_generation += 1;
}

/// Source `sqlite3Savepoint()`.
pub fn savepoint(parse: *Parse, operation: u8, name: []const u8) Error!void {
    if (operation > 2 or name.len == 0) return error.InvalidSchema;
    parse.program.operations.append(parse.allocator, .{ .savepoint = .{ .operation = operation, .name = name } }) catch return error.NoMemory;
}

/// Source `sqlite3OpenTempDatabase()`.
pub fn openTempDatabase(parse: *Parse, explain: bool) Error!void {
    if (!explain) parse.catalog.temp_open = true;
}

/// Source `sqlite3CodeVerifySchemaAtToplevel()`.
pub fn codeVerifySchemaAtToplevel(parse: *Parse, database: usize) Error!void {
    if (database >= @bitSizeOf(u64)) return error.InvalidSchema;
    const mask = @as(u64, 1) << @intCast(database);
    if (parse.used_schemas & mask == 0) {
        parse.used_schemas |= mask;
        parse.catalog.verified |= mask;
        if (database == 1) try openTempDatabase(parse, false);
    }
}

/// Source `sqlite3BeginWriteOperation()`.
pub fn beginWriteOperation(parse: *Parse, set_statement: bool, database: usize) Error!void {
    try codeVerifySchemaAtToplevel(parse, database);
    parse.write_schemas |= @as(u64, 1) << @intCast(database);
    parse.multi_write = parse.multi_write or set_statement;
}

/// Source `sqlite3CodeVerifyNamedSchema()`.
pub fn codeVerifyNamedSchema(parse: *Parse, database_name: ?[]const u8) Error!void {
    if (database_name == null or std.ascii.eqlIgnoreCase(database_name.?, "main")) try codeVerifySchemaAtToplevel(parse, 0);
    if (database_name == null or std.ascii.eqlIgnoreCase(database_name.?, "temp")) try codeVerifySchemaAtToplevel(parse, 1);
}

/// Source `sqlite3HaltConstraint()`.
pub fn haltConstraint(parse: *Parse, conflict: Conflict, message: []const u8) Error!void {
    const owned = parse.allocator.dupe(u8, message) catch return error.NoMemory;
    errdefer parse.allocator.free(owned);
    parse.program.messages.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    parse.program.operations.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    parse.program.messages.appendAssumeCapacity(owned);
    parse.program.operations.appendAssumeCapacity(.{ .halt = .{ .conflict = conflict, .message = owned } });
    parse.program.halted = true;
}

/// Source `sqlite3UniqueConstraint()`.
pub fn uniqueConstraint(parse: *Parse, table: *const Table, index: *const Index, conflict: Conflict) Error!void {
    var message = std.ArrayList(u8).empty;
    defer message.deinit(parse.allocator);
    for (index.columns, 0..) |column, position| {
        if (position != 0) message.appendSlice(parse.allocator, ", ") catch return error.NoMemory;
        message.appendSlice(parse.allocator, table.name) catch return error.NoMemory;
        message.append(parse.allocator, '.') catch return error.NoMemory;
        message.appendSlice(parse.allocator, table.columns.items[column].name) catch return error.NoMemory;
    }
    try haltConstraint(parse, conflict, message.items);
}

/// Source `sqlite3RowidConstraint()`.
pub fn rowidConstraint(parse: *Parse, table: *const Table, conflict: Conflict) Error!void {
    const message = if (table.integer_primary_key) |column| table.columns.items[column].name else "rowid";
    try haltConstraint(parse, conflict, message);
}

/// Source `sqlite3Reindex()`.
pub fn reindex(parse: *Parse, object_name: ?[]const u8) Error!usize {
    var rebuilt: usize = 0;
    for (parse.catalog.tables.items) |*table| for (table.indexes.items) |*index| {
        if (object_name != null and !std.ascii.eqlIgnoreCase(object_name.?, table.name) and !std.ascii.eqlIgnoreCase(object_name.?, index.name)) continue;
        try refillIndex(parse, table, index);
        rebuilt += 1;
    };
    if (object_name != null and rebuilt == 0) return error.NotFound;
    return rebuilt;
}

fn applyAffinity(value: Value, affinity: Affinity) Value {
    return switch (value) {
        .text => |text| switch (affinity) {
            .integer => if (std.fmt.parseInt(i64, text, 10)) |number| .{ .integer = number } else |_| value,
            .real, .numeric => if (std.fmt.parseFloat(f64, text)) |number| .{ .real = number } else |_| value,
            else => value,
        },
        .integer => |number| if (affinity == .real) .{ .real = @floatFromInt(number) } else value,
        else => value,
    };
}

/// Source `sqlite3TableAffinity()`.
pub fn tableAffinity(table: *const Table, row: []Value) Error!void {
    if (row.len != table.columns.items.len) return error.InvalidSchema;
    for (table.columns.items, row) |column, *value| value.* = applyAffinity(value.*, column.affinity);
}

/// Source `sqlite3ComputeGeneratedColumns()`.
pub fn computeGeneratedColumns(table: *const Table, row: []Value) Error!void {
    if (row.len != table.columns.items.len) return error.InvalidSchema;
    var remaining: usize = 0;
    for (table.columns.items) |column| {
        if (column.generated != null) remaining += 1;
    }
    var passes: usize = 0;
    while (remaining != 0 and passes <= table.columns.items.len) : (passes += 1) {
        var progress: usize = 0;
        for (table.columns.items, row) |column, *value| {
            if (column.generated) |generate| {
                const computed = generate(row);
                if (!std.meta.eql(value.*, computed)) progress += 1;
                value.* = computed;
            }
        }
        if (progress == 0) break;
        remaining = if (passes == 0) remaining else 0;
    }
    if (passes > table.columns.items.len) return error.InvalidSchema;
}

/// Source `autoIncBegin()`.
pub fn autoIncBegin(parse: *Parse, table: *const Table) Error!i64 {
    if (!table.autoincrement) return 0;
    if (table.integer_primary_key == null) return error.InvalidSchema;
    _ = parse;
    return table.sequence;
}

/// Source `sqlite3AutoincrementBegin()`.
pub fn beginAutoincrement(parse: *Parse, table: *const Table) Error!void {
    if (!table.autoincrement) return;
    _ = try autoIncBegin(parse, table);
    parse.program.operations.append(parse.allocator, .{ .table_lock = .{ .root = table.root_page, .write = false } }) catch return error.NoMemory;
}

/// Source `autoIncrementEnd()`.
pub fn autoIncrementEnd(parse: *Parse, table: *Table, maximum_rowid: i64) Error!void {
    if (!table.autoincrement or maximum_rowid <= table.sequence) return;
    parse.program.operations.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    table.sequence = maximum_rowid;
    parse.program.operations.appendAssumeCapacity(.{ .table_lock = .{ .root = table.root_page, .write = true } });
}

pub const MultiValueState = struct {
    rows: query.RowSet,
    coroutine_open: bool,
    row_width: usize,
    pub fn deinit(self: *MultiValueState) void {
        self.rows.deinit();
    }
};

/// Source `sqlite3MultiValuesEnd()`.
pub fn multiValuesEnd(state: *MultiValueState) void {
    state.coroutine_open = false;
}

/// Source `sqlite3MultiValues()`.
pub fn multiValues(allocator: std.mem.Allocator, left: []const []const Value, row: []const Value) Error!MultiValueState {
    var output = query.RowSet{ .allocator = allocator };
    errdefer output.deinit();
    const width = if (left.len == 0) row.len else left[0].len;
    for (left) |prior| {
        if (prior.len != width) return error.InvalidSchema;
        output.append(prior) catch return error.NoMemory;
    }
    if (row.len != width) return error.InvalidSchema;
    output.append(row) catch return error.NoMemory;
    return .{ .rows = output, .coroutine_open = left.len != 0, .row_width = width };
}

fn valueIsNull(value: Value) bool {
    return value == .null_;
}
fn valueEqual(left: Value, right: Value) bool {
    return switch (left) {
        .null_ => right == .null_,
        .integer => |number| switch (right) {
            .integer => |other| number == other,
            .real => |other| @as(f64, @floatFromInt(number)) == other,
            else => false,
        },
        .real => |number| switch (right) {
            .integer => |other| number == @as(f64, @floatFromInt(other)),
            .real => |other| number == other,
            else => false,
        },
        .text => |text| switch (right) {
            .text => |other| std.mem.eql(u8, text, other),
            else => false,
        },
        .blob => |blob| switch (right) {
            .blob => |other| std.mem.eql(u8, blob, other),
            else => false,
        },
    };
}
fn compareValue(left: Value, right: Value) std.math.Order {
    if (valueEqual(left, right)) return .eq;
    return switch (left) {
        .null_ => .lt,
        .integer => |number| switch (right) {
            .integer => |other| std.math.order(number, other),
            .real => |other| std.math.order(@as(f64, @floatFromInt(number)), other),
            .null_ => .gt,
            else => .lt,
        },
        .real => |number| switch (right) {
            .integer => |other| std.math.order(number, @as(f64, @floatFromInt(other))),
            .real => |other| std.math.order(number, other),
            .null_ => .gt,
            else => .lt,
        },
        .text => |text| switch (right) {
            .text => |other| std.mem.order(u8, text, other),
            .blob => .lt,
            else => .gt,
        },
        .blob => |blob| switch (right) {
            .blob => |other| std.mem.order(u8, blob, other),
            else => .gt,
        },
    };
}
fn rowMatchesPredicate(row: []const Value, predicate: query.Predicate) bool {
    if (predicate.column >= row.len) return false;
    const order = compareValue(row[predicate.column], predicate.value);
    return switch (predicate.op) {
        .eq => order == .eq,
        .ne => order != .eq,
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
        .is_null => row[predicate.column] == .null_,
    };
}

/// Source `sqlite3GenerateConstraintChecks()`.
pub fn generateConstraintChecks(parse: *Parse, table: *const Table, row: []const Value, conflict_override: Conflict) Error!Conflict {
    if (row.len != table.columns.items.len) return error.InvalidSchema;
    for (table.columns.items, row) |column, value| {
        if (column.not_null and valueIsNull(value)) {
            if (conflict_override == .ignore) return .ignore;
            if (conflict_override == .replace and !valueIsNull(column.default_value)) continue;
            try haltConstraint(parse, if (conflict_override == .default) .abort else conflict_override, column.name);
            return error.Constraint;
        }
    }
    for (table.indexes.items) |index| {
        if (!index.unique) continue;
        if (index.partial) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) continue;
        }
        for (index.rows.items) |prior| {
            var equal = true;
            for (index.columns, 0..) |column, key_index| {
                if (valueIsNull(row[column]) or !valueEqual(row[column], prior[key_index])) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                const resolution = if (conflict_override == .default) .abort else conflict_override;
                if (resolution == .ignore or resolution == .replace or resolution == .update) return resolution;
                try uniqueConstraint(parse, table, &index, resolution);
                return error.Constraint;
            }
        }
    }
    return .default;
}

const PendingIndex = struct { index: *Index, key: []Value };
/// Source `sqlite3CompleteInsertion()`.
pub fn completeInsertion(parse: *Parse, table: *Table, row: []const Value) Error!void {
    parse.program.operations.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    table.rows.rows.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    var pending = std.ArrayList(PendingIndex).empty;
    defer pending.deinit(parse.allocator);
    errdefer {
        for (pending.items) |item| parse.allocator.free(item.key);
    }
    for (table.indexes.items) |*index| {
        if (index.partial) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) continue;
        }
        index.rows.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
        const key = parse.allocator.alloc(Value, index.columns.len) catch return error.NoMemory;
        for (index.columns, 0..) |column, key_index| key[key_index] = row[column];
        pending.append(parse.allocator, .{ .index = index, .key = key }) catch {
            parse.allocator.free(key);
            return error.NoMemory;
        };
    }
    const owned_row = parse.allocator.dupe(Value, row) catch return error.NoMemory;
    table.rows.rows.appendAssumeCapacity(owned_row);
    for (pending.items) |item| item.index.rows.appendAssumeCapacity(item.key);
    parse.program.operations.appendAssumeCapacity(.{ .insert = table.rows.rows.items.len - 1 });
}

/// Source `sqlite3Insert()`.
pub fn insertRows(parse: *Parse, table: *Table, input: []const []const Value, columns: ?[]const usize, conflict: Conflict) Error!usize {
    if (table.read_only or table.is_view) return error.ReadOnly;
    var inserted: usize = 0;
    var maximum_rowid = table.sequence;
    for (input) |source| {
        const row = parse.allocator.alloc(Value, table.columns.items.len) catch return error.NoMemory;
        defer parse.allocator.free(row);
        for (table.columns.items, row) |column, *value| value.* = column.default_value;
        if (columns) |mapping| {
            if (mapping.len != source.len) return error.InvalidSchema;
            for (mapping, source) |column, value| {
                if (column >= row.len or table.columns.items[column].generated != null) return error.InvalidSchema;
                row[column] = value;
            }
        } else {
            if (source.len != row.len) return error.InvalidSchema;
            @memcpy(row, source);
        }
        if (table.integer_primary_key) |primary| {
            if (valueIsNull(row[primary])) {
                maximum_rowid += 1;
                row[primary] = .{ .integer = maximum_rowid };
            }
        }
        try computeGeneratedColumns(table, row);
        try tableAffinity(table, row);
        const resolution = try generateConstraintChecks(parse, table, row, conflict);
        if (resolution == .ignore) continue;
        var result: ?[]Value = null;
        var result_attached = false;
        errdefer if (!result_attached) {
            if (result) |owned| parse.allocator.free(owned);
        };
        if (parse.returning_columns.len != 0) {
            parse.program.returning.rows.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
            result = parse.allocator.alloc(Value, parse.returning_columns.len) catch return error.NoMemory;
            for (parse.returning_columns, 0..) |column, position| {
                if (column >= row.len) return error.InvalidSchema;
                result.?[position] = row[column];
            }
        }
        if (resolution == .replace) try deleteConflictingRows(parse, table, row);
        try completeInsertion(parse, table, row);
        if (result) |owned| {
            parse.program.returning.rows.appendAssumeCapacity(owned);
            result_attached = true;
        }
        inserted += 1;
    }
    try autoIncrementEnd(parse, table, maximum_rowid);
    return inserted;
}

/// Source `sqlite3OpenTableAndIndices()`.
pub fn openTableAndIndices(parse: *Parse, table: *const Table, write: bool) Error!usize {
    parse.program.operations.append(parse.allocator, .{ .table_lock = .{ .root = table.root_page, .write = write } }) catch return error.NoMemory;
    for (table.indexes.items, 0..) |_, index| parse.program.operations.append(parse.allocator, .{ .table_lock = .{ .root = table.root_page + @as(u32, @intCast(index + 1)), .write = write } }) catch return error.NoMemory;
    return table.indexes.items.len;
}

/// Source `xferCompatibleIndex()`.
pub fn transferCompatibleIndex(destination: *const Index, source: *const Index) bool {
    if (destination.unique != source.unique or destination.columns.len != source.columns.len) return false;
    return std.mem.eql(usize, destination.columns, source.columns) and std.meta.eql(destination.partial, source.partial);
}

/// Source `xferOptimization()`.
pub fn transferOptimization(parse: *Parse, destination: *Table, source: *const Table, conflict: Conflict) Error!bool {
    if (destination == source or destination.columns.items.len != source.columns.items.len or destination.without_rowid != source.without_rowid) return false;
    for (destination.columns.items, source.columns.items) |left, right| {
        if (left.affinity != right.affinity or left.generated != right.generated or (left.not_null and !right.not_null)) return false;
    }
    for (destination.indexes.items) |destination_index| {
        var compatible = false;
        for (source.indexes.items) |source_index| {
            if (transferCompatibleIndex(&destination_index, &source_index)) {
                compatible = true;
                break;
            }
        }
        if (!compatible) return false;
    }
    _ = try insertRows(parse, destination, source.rows.rows.items, null, conflict);
    return true;
}

pub const RowTrigger = *const fn (?[]const Value, ?[]const Value) Error!void;

pub const SourceItem = struct { name: []const u8, table: ?*Table = null, not_cte: bool = false, indexed_columns: []const usize = &.{} };

/// Source `sqlite3SrcListLookup()`.
pub fn sourceListLookup(parse: *Parse, source: *SourceItem) Error!*Table {
    const table = findTable(parse.catalog, source.name) orelse return error.NotFound;
    for (source.indexed_columns) |column| {
        if (column >= table.columns.items.len) return error.NotFound;
    }
    source.table = table;
    source.not_cte = true;
    return table;
}

/// Source `sqlite3MaterializeView()`.
pub fn materializeView(allocator: std.mem.Allocator, table: *const Table, predicates: []const query.Predicate, order: []const query.OrderTerm, limit: ?usize) Error!query.RowSet {
    var model = query.SelectModel{ .columns = &.{}, .rows = table.rows.rows.items, .projection = &.{}, .predicates = predicates, .order_by = order, .limit = limit, .expanded = true, .resolved = true, .typed = true };
    const projection = allocator.alloc(usize, table.columns.items.len) catch return error.NoMemory;
    defer allocator.free(projection);
    for (projection, 0..) |*column, index| column.* = index;
    model.projection = projection;
    return query.select(allocator, model) catch |failure| switch (failure) {
        error.OutOfMemory => error.NoMemory,
        else => error.InvalidSchema,
    };
}

/// Source `sqlite3GenerateIndexKey()`.
pub fn generateIndexKey(allocator: std.mem.Allocator, index: *const Index, row: []const Value, prefix_only: bool) Error![]Value {
    const count = if (prefix_only and index.unique) index.columns.len else index.columns.len;
    const key = allocator.alloc(Value, count) catch return error.NoMemory;
    errdefer allocator.free(key);
    for (index.columns[0..count], 0..) |column, position| {
        if (column >= row.len) return error.InvalidSchema;
        key[position] = row[column];
    }
    return key;
}

/// Source `sqlite3GenerateRowIndexDelete()`.
pub fn generateRowIndexDelete(parse: *Parse, table: *Table, row: []const Value) Error!void {
    for (table.indexes.items) |*index| {
        if (index.partial) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) continue;
        }
        var found: ?usize = null;
        for (index.rows.items, 0..) |stored, position| {
            var equal = stored.len == index.columns.len;
            for (index.columns, 0..) |column, key_position| {
                if (!equal or column >= row.len or !valueEqual(stored[key_position], row[column])) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                found = position;
                break;
            }
        }
        if (found) |position| parse.allocator.free(index.rows.orderedRemove(position));
    }
}

/// Source `sqlite3GenerateRowDelete()`.
pub fn generateRowDelete(parse: *Parse, table: *Table, position: usize, before: ?RowTrigger, after: ?RowTrigger, count_change: bool) Error!void {
    if (position >= table.rows.rows.items.len) return error.NotFound;
    parse.program.operations.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
    const row = table.rows.rows.items[position];
    if (before) |trigger| try trigger(row, null);
    try generateRowIndexDelete(parse, table, row);
    const removed = table.rows.rows.orderedRemove(position);
    if (after) |trigger| try trigger(removed, null);
    parse.allocator.free(removed);
    parse.program.operations.append(parse.allocator, .{ .delete = position }) catch return error.NoMemory;
    _ = count_change;
}

/// Source `sqlite3DeleteFrom()`.
pub fn deleteFrom(parse: *Parse, table: *Table, predicates: []const query.Predicate, limit: ?usize, before: ?RowTrigger, after: ?RowTrigger) Error!usize {
    if (table.read_only) return error.ReadOnly;
    var positions = std.ArrayList(usize).empty;
    defer positions.deinit(parse.allocator);
    for (table.rows.rows.items, 0..) |row, position| {
        var matches = true;
        for (predicates) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        positions.append(parse.allocator, position) catch return error.NoMemory;
        if (limit) |maximum| {
            if (positions.items.len >= maximum) break;
        }
    }
    var deleted: usize = 0;
    while (positions.pop()) |position| {
        try generateRowDelete(parse, table, position, before, after, true);
        deleted += 1;
    }
    return deleted;
}

fn checkUpdateConstraints(parse: *Parse, table: *const Table, row: []const Value, excluded_position: usize, conflict: Conflict) Error!Conflict {
    for (table.columns.items, row) |column, value| {
        if (column.not_null and valueIsNull(value)) {
            if (conflict == .ignore) return .ignore;
            try haltConstraint(parse, if (conflict == .default) .abort else conflict, column.name);
            return error.Constraint;
        }
    }
    for (table.indexes.items) |index| {
        if (!index.unique) continue;
        for (table.rows.rows.items, 0..) |prior, position| {
            if (position == excluded_position) continue;
            var equal = true;
            for (index.columns) |column| {
                if (valueIsNull(row[column]) or !valueEqual(row[column], prior[column])) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                const resolution = if (conflict == .default) .abort else conflict;
                if (resolution == .ignore or resolution == .replace) return resolution;
                try uniqueConstraint(parse, table, &index, resolution);
                return error.Constraint;
            }
        }
    }
    return .default;
}

fn replaceStoredRow(parse: *Parse, table: *Table, position: usize, replacement: []const Value) Error![]Value {
    var keys = std.ArrayList([]Value).empty;
    defer keys.deinit(parse.allocator);
    errdefer for (keys.items) |key| parse.allocator.free(key);
    for (table.indexes.items) |*index| {
        index.rows.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
        const key = try generateIndexKey(parse.allocator, index, replacement, false);
        keys.append(parse.allocator, key) catch {
            parse.allocator.free(key);
            return error.NoMemory;
        };
    }
    const owned = parse.allocator.dupe(Value, replacement) catch return error.NoMemory;
    errdefer parse.allocator.free(owned);
    const old = table.rows.rows.items[position];
    try generateRowIndexDelete(parse, table, old);
    table.rows.rows.items[position] = owned;
    for (table.indexes.items, keys.items) |*index, key| index.rows.appendAssumeCapacity(key);
    return old;
}

/// Source `updateFromSelect()`.
pub fn updateFromSelect(allocator: std.mem.Allocator, table: *const Table, predicates: []const query.Predicate, changes: []const usize) Error!query.RowSet {
    var output = query.RowSet{ .allocator = allocator };
    errdefer output.deinit();
    for (table.rows.rows.items) |row| {
        var matches = true;
        for (predicates) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        const selected = allocator.alloc(Value, changes.len + 1) catch return error.NoMemory;
        defer allocator.free(selected);
        selected[0] = if (table.integer_primary_key) |column| row[column] else .{ .integer = @intCast(output.rows.items.len) };
        for (changes, 0..) |column, position| {
            if (column >= row.len) return error.InvalidSchema;
            selected[position + 1] = row[column];
        }
        output.append(selected) catch return error.NoMemory;
    }
    return output;
}

pub const Change = struct { column: usize, value: Value };
/// Source `sqlite3Update()`.
pub fn updateRows(parse: *Parse, table: *Table, predicates: []const query.Predicate, changes: []const Change, conflict: Conflict, before: ?RowTrigger, after: ?RowTrigger) Error!usize {
    if (table.read_only) return error.ReadOnly;
    var updated: usize = 0;
    var position: usize = 0;
    while (position < table.rows.rows.items.len) : (position += 1) {
        const old = table.rows.rows.items[position];
        var matches = true;
        for (predicates) |predicate| {
            if (!rowMatchesPredicate(old, predicate)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        const candidate = parse.allocator.dupe(Value, old) catch return error.NoMemory;
        defer parse.allocator.free(candidate);
        for (changes) |change| {
            if (change.column >= candidate.len or table.columns.items[change.column].generated != null) return error.InvalidSchema;
            candidate[change.column] = change.value;
        }
        try computeGeneratedColumns(table, candidate);
        try tableAffinity(table, candidate);
        if (before) |trigger| try trigger(old, candidate);
        const resolution = try checkUpdateConstraints(parse, table, candidate, position, conflict);
        if (resolution == .ignore) continue;
        var target_position = position;
        if (resolution == .replace) target_position = try deleteConflictingRowsExcept(parse, table, candidate, position);
        parse.program.operations.ensureUnusedCapacity(parse.allocator, 1) catch return error.NoMemory;
        const removed = try replaceStoredRow(parse, table, target_position, candidate);
        defer parse.allocator.free(removed);
        if (after) |trigger| try trigger(removed, candidate);
        parse.program.operations.appendAssumeCapacity(.{ .update = target_position });
        position = target_position;
        updated += 1;
    }
    return updated;
}

pub const VirtualUpdate = *const fn (?Value, ?Value, []const Value, Conflict) Error!void;
/// Source `updateVirtualTable()`.
pub fn updateVirtualTable(parse: *Parse, table: *const Table, predicates: []const query.Predicate, changes: []const Change, conflict: Conflict, callback: VirtualUpdate) Error!usize {
    var updated: usize = 0;
    for (table.rows.rows.items) |row| {
        var matches = true;
        for (predicates) |predicate| {
            if (!rowMatchesPredicate(row, predicate)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        const candidate = parse.allocator.dupe(Value, row) catch return error.NoMemory;
        defer parse.allocator.free(candidate);
        for (changes) |change| {
            if (change.column >= candidate.len) return error.InvalidSchema;
            candidate[change.column] = change.value;
        }
        const old_rowid: ?Value = if (table.integer_primary_key) |column| row[column] else null;
        const new_rowid: ?Value = if (table.integer_primary_key) |column| candidate[column] else null;
        try callback(old_rowid, new_rowid, candidate, if (conflict == .default) .abort else conflict);
        parse.program.operations.append(parse.allocator, .{ .update = updated }) catch return error.NoMemory;
        updated += 1;
    }
    return updated;
}

fn deleteConflictingRowsExcept(parse: *Parse, table: *Table, row: []const Value, excluded: ?usize) Error!usize {
    var adjusted = excluded orelse 0;
    var position = table.rows.rows.items.len;
    while (position != 0) {
        position -= 1;
        if (excluded != null and position == excluded.?) continue;
        var conflict = false;
        for (table.indexes.items) |index| {
            if (!index.unique) continue;
            var equal = true;
            for (index.columns) |column| {
                if (valueIsNull(row[column]) or !valueEqual(row[column], table.rows.rows.items[position][column])) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                conflict = true;
                break;
            }
        }
        if (conflict) {
            try generateRowDelete(parse, table, position, null, null, false);
            if (excluded != null and position < adjusted) adjusted -= 1;
        }
    }
    return adjusted;
}

fn deleteConflictingRows(parse: *Parse, table: *Table, row: []const Value) Error!void {
    _ = try deleteConflictingRowsExcept(parse, table, row, null);
}

fn testNested(_: *Parse, sql: []const u8) Error!void {
    if (sql.len == 0) return error.InvalidSchema;
}

fn testVirtualUpdate(_: ?Value, _: ?Value, values: []const Value, _: Conflict) Error!void {
    if (values.len == 0) return error.InvalidSchema;
}

fn testGenerated(values: []const Value) Value {
    return values[0];
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    var program = Program.init(allocator);
    defer program.deinit();
    var parse = Parse{ .allocator = allocator, .catalog = &catalog, .program = &program };
    const table = startTable(&parse, "faults", false, false, false, false) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
    addColumn(&parse, table.?, .{ .name = "id", .affinity = .integer }, 8) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
    createIndex(&parse, table.?, "fault_index", &.{0}, true, false, null, false) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
    const row = [_]Value{.{ .integer = 1 }};
    _ = insertRows(&parse, table.?, &.{&row}, null, .abort) catch |failure| return if (failure == error.NoMemory) error.OutOfMemory else failure;
}

test "schema and mutation compiler survives each bounded allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "schema and mutation compiler executes create insert update delete and transfer paths" {
    const allocator = std.testing.allocator;
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    var program = Program.init(allocator);
    defer program.deinit();
    var parse = Parse{ .allocator = allocator, .catalog = &catalog, .program = &program };

    var table = (try startTable(&parse, "items", false, false, false, false)).?;
    try addColumn(&parse, table, .{ .name = "id", .affinity = .integer }, 16);
    try addColumn(&parse, table, .{ .name = "name", .affinity = .text }, 16);
    try addColumn(&parse, table, .{ .name = "copy", .affinity = .integer, .generated = &testGenerated }, 16);
    try addPrimaryKey(table, &.{0}, .abort, true);
    try endTable(&parse, table, true, false);
    try createIndex(&parse, table, "items_name", &.{1}, true, false, null, false);
    try createForeignKey(&parse, table, &.{0}, "parents", &.{"id"}, .abort, .abort);

    const first = [_]Value{ .null_, .{ .text = "alpha" }, .null_ };
    const second = [_]Value{ .null_, .{ .text = "beta" }, .null_ };
    try addReturning(&parse, &.{ 0, 1 });
    try std.testing.expectEqual(@as(usize, 2), try insertRows(&parse, table, &.{ &first, &second }, null, .abort));
    try std.testing.expectEqual(@as(usize, 2), program.returning.rows.items.len);
    try std.testing.expectEqual(@as(i64, 2), table.sequence);

    const id_one = query.Predicate{ .column = 0, .op = .eq, .value = .{ .integer = 1 } };
    var selected = try materializeView(allocator, table, &.{id_one}, &.{}, null);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.rows.items.len);
    var update_source = try updateFromSelect(allocator, table, &.{id_one}, &.{1});
    defer update_source.deinit();
    try std.testing.expectEqual(@as(usize, 1), update_source.rows.items.len);

    try std.testing.expectEqual(@as(usize, 1), try updateRows(&parse, table, &.{id_one}, &.{.{ .column = 1, .value = .{ .text = "gamma" } }}, .abort, null, null));
    try std.testing.expectEqual(@as(usize, 1), try updateVirtualTable(&parse, table, &.{id_one}, &.{.{ .column = 1, .value = .{ .text = "virtual" } }}, .abort, testVirtualUpdate));
    const id_two = query.Predicate{ .column = 0, .op = .eq, .value = .{ .integer = 2 } };
    try std.testing.expectEqual(@as(usize, 1), try deleteFrom(&parse, table, &.{id_two}, null, null, null));

    const key = try generateIndexKey(allocator, &table.indexes.items[0], table.rows.rows.items[0], false);
    defer allocator.free(key);
    try std.testing.expectEqual(@as(usize, 1), key.len);
    try std.testing.expectEqual(@as(usize, 1), try openTableAndIndices(&parse, table, true));
    try std.testing.expectEqual(@as(usize, 1), try reindex(&parse, "items"));

    var values = try multiValues(allocator, table.rows.rows.items, &.{ .{ .integer = 9 }, .{ .text = "extra" }, .{ .integer = 9 } });
    defer values.deinit();
    multiValuesEnd(&values);
    try std.testing.expect(!values.coroutine_open);

    try nestedParse(&parse, "SELECT 1", testNested);
    try savepoint(&parse, 0, "s1");
    try codeVerifyNamedSchema(&parse, null);
    try openTempDatabase(&parse, false);
    try std.testing.expect(catalog.temp_open);

    _ = try createView(&parse, "item_view", &.{ "id", "name" }, false);
    const unloaded = (try startTable(&parse, "lazy_view", false, true, false, false)).?;
    try viewGetColumnNames(&parse, unloaded, &.{"value"});
    try dropTable(&parse, "lazy_view", true, false);

    var source_item = SourceItem{ .name = "items", .indexed_columns = &.{0} };
    table = try sourceListLookup(&parse, &source_item);
    try std.testing.expect(source_item.not_cte);
    const destination = (try startTable(&parse, "items_copy", false, false, false, false)).?;
    try addColumn(&parse, destination, .{ .name = "id", .affinity = .integer }, 16);
    try addColumn(&parse, destination, .{ .name = "name", .affinity = .text }, 16);
    try addColumn(&parse, destination, .{ .name = "copy", .affinity = .integer, .generated = &testGenerated }, 16);
    try addPrimaryKey(destination, &.{0}, .abort, false);
    try endTable(&parse, destination, true, false);
    try createIndex(&parse, destination, "copy_name", &.{1}, true, false, null, false);
    source_item.table = null;
    table = try sourceListLookup(&parse, &source_item);
    try std.testing.expect(transferCompatibleIndex(&destination.indexes.items[0], &table.indexes.items[0]));
    try std.testing.expect(try transferOptimization(&parse, destination, table, .abort));

    clearStatTables(&catalog, "items");
    try finishCoding(&parse);
    try std.testing.expect(parse.finished);
}
