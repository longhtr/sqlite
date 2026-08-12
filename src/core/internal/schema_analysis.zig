//! Schema column/index helpers from `build.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const tokenizer = @import("../tokenizer.zig");
const log_est = @import("../log_est.zig");
const sqlite_string = @import("../string.zig");
const db_allocator = @import("db_allocator.zig");
const connection_names = @import("connection_names.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const types = @import("vdbe_types.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");

/// Source `sqlite3UnlinkAndDeleteTable()`.
pub fn unlinkAndDeleteTable(db: *types.Sqlite3, database_index: c_int, name: [*:0]const u8) void {
    const schema_owner = db.aDb.?[@intCast(database_index)].pSchema.?;
    const removed = schema_owner.table_hash.insert(db_allocator.stdAllocator(db), name, null);
    if (removed) |opaque_table| compiler_ownership.deleteTable(db, @ptrCast(@alignCast(opaque_table)));
    db.mDbFlags |= types.database_flag.schema_change;
}

/// Source `sqlite3UnlinkAndDeleteIndex()`.
pub fn unlinkAndDeleteIndex(db: *types.Sqlite3, database_index: c_int, name: [*:0]const u8) void {
    const schema_owner = db.aDb.?[@intCast(database_index)].pSchema.?;
    const removed = schema_owner.index_hash.insert(db_allocator.stdAllocator(db), name, null) orelse return;
    const index: *schema.Index = @ptrCast(@alignCast(removed));
    if (index.table.?.indexes == index) {
        index.table.?.indexes = index.next;
    } else {
        var previous = index.table.?.indexes;
        while (previous != null and previous.?.next != index) previous = previous.?.next;
        if (previous) |present| present.next = index.next;
    }
    compiler_ownership.deleteIndex(db, index);
    db.mDbFlags |= types.database_flag.schema_change;
}

/// Source `sqlite3RootPageMoved()`.
pub fn rootPageMoved(db: *types.Sqlite3, database_index: c_int, from: u32, to: u32) void {
    const schema_owner = db.aDb.?[@intCast(database_index)].pSchema.?;
    var element = schema_owner.table_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const table: *schema.Table = @ptrCast(@alignCast(present.value().?));
        if (table.root_page == from) table.root_page = to;
    }
    element = schema_owner.index_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const index: *schema.Index = @ptrCast(@alignCast(present.value().?));
        if (index.root_page == from) index.root_page = to;
    }
}

/// Source `sqlite3TwoPartName()`.
pub fn twoPartName(parse: *parse_types.Parse, first: *const parse_types.Token, second: *const parse_types.Token, unqualified: **const parse_types.Token) c_int {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (second.n > 0) {
        if (db.init.busy != 0) {
            const message = "corrupt database";
            parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
            parse.nErr += 1;
            parse.rc = 1;
            return -1;
        }
        unqualified.* = second;
        const name = nameFromToken(db, first) orelse return -1;
        defer db_allocator.freeNN(db, name);
        const database_index = connection_names.findDatabaseName(db, name);
        if (database_index >= 0) return database_index;
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "unknown database {s}", .{name}) catch "unknown database";
        parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
        parse.nErr += 1;
        parse.rc = 1;
        return -1;
    }
    unqualified.* = first;
    return db.init.iDb;
}

/// Source `sqlite3PreferredTableName()`.
pub fn preferredTableName(name: [*:0]const u8) [*:0]const u8 {
    if (sqlite_string.compareInternal(name, "sqlite_master") == 0) return "sqlite_schema";
    if (sqlite_string.compareInternal(name, "sqlite_temp_master") == 0) return "sqlite_temp_schema";
    return name;
}

/// Source `sqlite3NameFromToken()`.
pub fn nameFromToken(db: *types.Sqlite3, token: ?*const parse_types.Token) ?[*:0]u8 {
    const present = token orelse return null;
    const result = db_allocator.stringNDuplicate(db, present.z, present.n) orelse return null;
    sqlite_string.dequote(result);
    return result;
}

/// Source `sqlite3StringToId()`.
pub fn stringToIdentifier(expression: *parse_types.Expr) void {
    if (expression.op == tokens.tk_string) expression.op = @intCast(tokens.tk_id) else if (expression.op == tokens.tk_collate and expression.pLeft.?.op == tokens.tk_string) expression.pLeft.?.op = @intCast(tokens.tk_id);
}

/// Source `identLength()`.
pub fn identifierLength(identifier: [*:0]const u8) i64 {
    var length: i64 = 2;
    for (std.mem.span(identifier)) |byte| length += if (byte == '\"') 2 else 1;
    return length;
}

/// Source `sqlite3WritableSchema()`.
pub fn writableSchema(db: *const types.Sqlite3) bool {
    const relevant = db.flags & (types.connection_flag.write_schema | types.connection_flag.defensive);
    return relevant == types.connection_flag.write_schema;
}

/// Source `sqlite3ReadOnlyShadowTables()`.
pub fn readOnlyShadowTables(db: *const types.Sqlite3) bool {
    const virtual_table_sync = db.nVTrans > 0 and db.aVTrans == null;
    return db.flags & types.connection_flag.defensive != 0 and db.pVtabCtx == null and db.nVdbeExec == 0 and !virtual_table_sync;
}

/// Source `tableMayNotBeDropped()`.
pub fn tableMayNotBeDropped(db: *const types.Sqlite3, table: *const schema.Table) bool {
    const name = table.name.?;
    if (sqlite_string.compareN(name, "sqlite_", 7) == 0) {
        if (sqlite_string.compareN(name + 7, "stat", 4) == 0 or sqlite_string.compareN(name + 7, "parameters", 10) == 0) return false;
        return true;
    }
    if (table.flags & 0x0000_1000 != 0 and readOnlyShadowTables(db)) return true;
    return table.flags & 0x0000_8000 != 0;
}

fn setParseError(parse: *parse_types.Parse, message: []const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `makeColumnPartOfPrimaryKey()`.
pub fn makeColumnPrimaryKey(parse: *parse_types.Parse, column: *schema.Column) void {
    column.flags |= 0x0001;
    if (column.flags & 0x0060 != 0) setParseError(parse, "generated columns cannot be part of the PRIMARY KEY");
}

/// Source `sqlite3HasExplicitNulls()`.
pub fn hasExplicitNulls(parse: *parse_types.Parse, list: ?*parse_types.ExprList) bool {
    const expressions = list orelse return false;
    for (expressions.items()) |item| {
        if (item.fg.bNulls) {
            const placement = if (item.fg.sortFlags == 0 or item.fg.sortFlags == 3) "FIRST" else "LAST";
            var buffer: [64]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "unsupported use of NULLS {s}", .{placement}) catch "unsupported use of NULLS";
            setParseError(parse, message);
            return true;
        }
    }
    return false;
}

pub const affinity = struct {
    pub const blob: u8 = 0x41;
    pub const text: u8 = 0x42;
    pub const numeric: u8 = 0x43;
    pub const integer: u8 = 0x44;
    pub const real: u8 = 0x45;
};

/// Source `sqlite3AffinityType()`.
pub fn affinityType(type_name: [*:0]const u8, column: ?*schema.Column) u8 {
    var hash: u32 = 0;
    var result: u8 = affinity.numeric;
    var size_start: ?[*:0]const u8 = null;
    var position: [*:0]const u8 = type_name;
    while (position[0] != 0) : (position += 1) {
        const byte = if (position[0] >= 'A' and position[0] <= 'Z') position[0] + 0x20 else position[0];
        hash = (hash << 8) +% byte;
        if (hash == 0x63686172) {
            result = affinity.text;
            size_start = position + 1;
        } else if (hash == 0x636c6f62 or hash == 0x74657874) result = affinity.text else if (hash == 0x626c6f62 and (result == affinity.numeric or result == affinity.real)) {
            result = affinity.blob;
            if (position[1] == '(') size_start = position + 1;
        } else if ((hash == 0x7265616c or hash == 0x666c6f61 or hash == 0x646f7562) and result == affinity.numeric) result = affinity.real else if (hash & 0x00ff_ffff == 0x0069_6e74) {
            result = affinity.integer;
            break;
        }
    }
    if (column) |present| {
        var size: c_int = 0;
        if (result < affinity.numeric) {
            if (size_start) |start| {
                var scan = start;
                while (scan[0] != 0 and !std.ascii.isDigit(scan[0])) scan += 1;
                while (std.ascii.isDigit(scan[0])) : (scan += 1) size = size * 10 + scan[0] - '0';
            } else size = 16;
        }
        present.estimated_size = @intCast(@min(@divTrunc(size, 4) + 1, 255));
    }
    return result;
}

/// Source `sqlite3TableColumnAffinity()`.
pub fn tableColumnAffinity(table: *const schema.Table, column: c_int) u8 {
    if (column < 0 or column >= table.column_count) return affinity.integer;
    return table.columns.?[@intCast(column)].affinity;
}

/// Source `sqlite3ColumnIndex()`.
pub fn columnIndex(table: *const schema.Table, name: [*:0]const u8) c_int {
    const hash = sqlite_string.insensitiveHash(name);
    const columns = table.columns.?[0..@intCast(table.column_count)];
    const lucky = table.column_hash[hash % table.column_hash.len];
    if (lucky < columns.len and columns[lucky].name_hash == hash and sqlite_string.compareInternal(columns[lucky].name_and_metadata.?, name) == 0) return lucky;
    for (columns, 0..) |column, index| {
        if (column.name_hash == hash and sqlite_string.compareInternal(column.name_and_metadata.?, name) == 0) return @intCast(index);
    }
    return -1;
}

/// Source `sqlite3ColumnExpr()`.
pub fn columnExpression(table: *schema.Table, column: *schema.Column) ?*parse_types.Expr {
    if (column.default_expression_index == 0 or table.kind != .ordinary or table.owner.ordinary.default_expressions == null) return null;
    const expressions: *parse_types.ExprList = @ptrCast(@alignCast(table.owner.ordinary.default_expressions.?));
    if (expressions.nExpr < column.default_expression_index) return null;
    return expressions.items()[column.default_expression_index - 1].pExpr;
}

/// Source `sqlite3ColumnSetColl()`.
pub fn setColumnCollation(db: *types.Sqlite3, column: *schema.Column, collation: [*:0]const u8) void {
    var metadata_length = std.mem.len(column.name_and_metadata.?) + 1;
    if (column.flags & 0x0004 != 0) metadata_length += std.mem.len(column.name_and_metadata.? + metadata_length) + 1;
    const collation_length = std.mem.len(collation) + 1;
    const resized = db_allocator.realloc(db, column.name_and_metadata, metadata_length + collation_length) orelse return;
    const storage: [*]u8 = @ptrCast(resized);
    column.name_and_metadata = @ptrCast(storage);
    @memcpy(storage[metadata_length .. metadata_length + collation_length], collation[0..collation_length]);
    column.flags |= 0x0200;
}

/// Source `sqlite3ColumnColl()`.
pub fn columnCollation(column: *const schema.Column) ?[*:0]const u8 {
    if (column.flags & 0x0200 == 0) return null;
    var text: [*:0]const u8 = @ptrCast(column.name_and_metadata.?);
    text += std.mem.len(text) + 1;
    if (column.flags & 0x0004 != 0) text += std.mem.len(text) + 1;
    return text;
}

/// Source `sqlite3FindTable()`.
pub fn findTable(db: *types.Sqlite3, name: [*:0]const u8, database_name: ?[*:0]const u8) ?*schema.Table {
    if (database_name) |requested| {
        const database_index = connection_names.findDatabaseName(db, requested);
        if (database_index < 0) return null;
        const database_schema = db.aDb.?[@intCast(database_index)].pSchema.?;
        if (database_schema.table_hash.find(name)) |found| return @ptrCast(@alignCast(found));
        if (sqlite_string.compareN(name, "sqlite_", 7) == 0) {
            const suffix = name + 7;
            const legacy_name: ?[*:0]const u8 = if (database_index == 1 and
                (sqlite_string.compareInternal(suffix, "temp_schema") == 0 or sqlite_string.compareInternal(suffix, "schema") == 0 or sqlite_string.compareInternal(suffix, "master") == 0))
                "sqlite_temp_master"
            else if (database_index != 1 and sqlite_string.compareInternal(suffix, "schema") == 0)
                "sqlite_master"
            else
                null;
            if (legacy_name) |legacy| {
                if (database_schema.table_hash.find(legacy)) |found| return @ptrCast(@alignCast(found));
            }
        }
        return null;
    }
    const order = [_]c_int{ 1, 0 };
    for (order) |database_index| {
        if (db.aDb.?[@intCast(database_index)].pSchema.?.table_hash.find(name)) |found| return @ptrCast(@alignCast(found));
    }
    var database_index: c_int = 2;
    while (database_index < db.nDb) : (database_index += 1) {
        if (db.aDb.?[@intCast(database_index)].pSchema.?.table_hash.find(name)) |found| return @ptrCast(@alignCast(found));
    }
    if (sqlite_string.compareN(name, "sqlite_", 7) == 0) {
        const suffix = name + 7;
        if (sqlite_string.compareInternal(suffix, "schema") == 0) return if (db.aDb.?[0].pSchema.?.table_hash.find("sqlite_master")) |found| @ptrCast(@alignCast(found)) else null;
        if (sqlite_string.compareInternal(suffix, "temp_schema") == 0) return if (db.aDb.?[1].pSchema.?.table_hash.find("sqlite_temp_master")) |found| @ptrCast(@alignCast(found)) else null;
    }
    return null;
}

fn shadowCallback(db: *types.Sqlite3, table: *schema.Table) ?*const fn ([*:0]const u8) callconv(.c) c_int {
    if (table.kind != .virtual) return null;
    const module_name = table.owner.virtual.arguments.?[0] orelse return null;
    const module: *types.Module = @ptrCast(@alignCast(db.aModule.find(module_name) orelse return null));
    const public = module.pModule orelse return null;
    if (public.iVersion < 3) return null;
    return if (public.xShadowName) |raw| @ptrCast(@alignCast(raw)) else null;
}

/// Source `sqlite3IsShadowTableOf()`.
pub fn isShadowTableOf(db: *types.Sqlite3, table: *schema.Table, name: [*:0]const u8) bool {
    const table_name = table.name.?;
    const length = std.mem.len(table_name);
    if (sqlite_string.compareN(name, table_name, @intCast(length)) != 0 or name[length] != '_') return false;
    const callback = shadowCallback(db, table) orelse return false;
    return callback(name + length + 1) != 0;
}

/// Source `sqlite3MarkAllShadowTablesOf()`.
pub fn markAllShadowTablesOf(db: *types.Sqlite3, table: *schema.Table) void {
    const callback = shadowCallback(db, table) orelse return;
    const table_name = table.name.?;
    const length = std.mem.len(table_name);
    var element = table.schema.?.table_hash.first_entry;
    while (element) |present| : (element = present.nextElement()) {
        const other: *schema.Table = @ptrCast(@alignCast(present.value().?));
        if (other.kind != .ordinary or other.flags & 0x0000_1000 != 0) continue;
        if (sqlite_string.compareN(other.name.?, table_name, @intCast(length)) == 0 and other.name.?[length] == '_' and callback(other.name.? + length + 1) != 0) other.flags |= 0x0000_1000;
    }
}

/// Source `sqlite3ShadowTableName()`.
pub fn shadowTableName(db: *types.Sqlite3, name: [*:0]const u8) bool {
    const text = std.mem.span(name);
    const separator = std.mem.lastIndexOfScalar(u8, text, '_') orelse return false;
    const prefix = db_allocator.stringNDuplicate(db, name, separator) orelse return false;
    defer db_allocator.free(db, prefix);
    const table = findTable(db, prefix, null) orelse return false;
    return isShadowTableOf(db, table, name);
}

/// Source `sqlite3FindIndex()`.
pub fn findIndex(db: *types.Sqlite3, name: [*:0]const u8, database_name: ?[*:0]const u8) ?*schema.Index {
    var index: c_int = 0;
    while (index < db.nDb) : (index += 1) {
        const database_index: c_int = if (index < 2) index ^ 1 else index;
        if (database_name) |requested| {
            if (!connection_names.databaseIsNamed(db, database_index, requested)) continue;
        }
        const database_schema = db.aDb.?[@intCast(database_index)].pSchema.?;
        if (database_schema.index_hash.find(name)) |found| return @ptrCast(@alignCast(found));
    }
    return null;
}

fn roundEight(value: usize) usize {
    return (value + 7) & ~@as(usize, 7);
}

/// Source `sqlite3AllocateIndexObject()`.
pub fn allocateIndex(db: *types.Sqlite3, column_count: c_int, extra_bytes: c_int, extra_output: *[*]u8) ?*schema.Index {
    const count: usize = @intCast(column_count);
    const index_bytes = roundEight(@sizeOf(schema.Index));
    const collation_bytes = roundEight(@sizeOf(?[*:0]const u8) * count);
    const arrays_bytes = roundEight(@sizeOf(i16) * (count + 1) + @sizeOf(i16) * count + count);
    const byte_count = index_bytes + collation_bytes + arrays_bytes;
    const raw = db_allocator.mallocZero(db, byte_count + @as(usize, @intCast(extra_bytes))) orelse return null;
    const index: *schema.Index = @ptrCast(@alignCast(raw));
    var extra: [*]u8 = @ptrFromInt(@intFromPtr(index) + index_bytes);
    index.collations = @ptrCast(@alignCast(extra));
    extra += collation_bytes;
    index.row_log_estimates = @ptrCast(@alignCast(extra));
    extra += @sizeOf(i16) * (count + 1);
    index.columns = @ptrCast(@alignCast(extra));
    extra += @sizeOf(i16) * count;
    index.sort_order = extra;
    index.column_count = @intCast(column_count);
    index.key_column_count = @intCast(column_count - 1);
    extra_output.* = @ptrFromInt(@intFromPtr(index) + byte_count);
    return index;
}

/// Source `sqlite3CollapseDatabaseArray()`.
pub fn collapseDatabaseArray(db: *types.Sqlite3) void {
    var destination: usize = 2;
    for (db.aDb.?[2..@intCast(db.nDb)]) |attached| {
        if (attached.pBt == null) {
            db_allocator.free(db, if (attached.zDbSName) |name| @ptrCast(name) else null);
            continue;
        }
        db.aDb.?[destination] = attached;
        destination += 1;
    }
    db.nDb = @intCast(destination);
    const static_pointer: [*]types.Db = @ptrCast(&db.aDbStatic);
    if (db.nDb <= 2 and db.aDb != static_pointer) {
        @memcpy(db.aDbStatic[0..2], db.aDb.?[0..2]);
        db_allocator.freeNN(db, db.aDb.?);
        db.aDb = static_pointer;
    }
}

/// Source `resizeIndexObject()`.
pub fn resizeIndex(parse: *parse_types.Parse, index: *schema.Index, column_count: c_int) c_int {
    if (index.column_count >= column_count) return 0;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const count: usize = @intCast(column_count);
    const byte_count = (@sizeOf(?[*:0]const u8) + @sizeOf(i16) + @sizeOf(i16) + 1) * count;
    const raw = db_allocator.mallocZero(db, byte_count) orelse return 7;
    var extra: [*]u8 = @ptrCast(raw);
    const collations: [*]?[*:0]const u8 = @ptrCast(@alignCast(extra));
    @memcpy(collations[0..index.column_count], index.collations.?[0..index.column_count]);
    index.collations = collations;
    extra += @sizeOf(?[*:0]const u8) * count;
    const estimates: [*]i16 = @ptrCast(@alignCast(extra));
    @memcpy(estimates[0 .. index.key_column_count + 1], index.row_log_estimates.?[0 .. index.key_column_count + 1]);
    index.row_log_estimates = estimates;
    extra += @sizeOf(i16) * count;
    const columns: [*]i16 = @ptrCast(@alignCast(extra));
    @memcpy(columns[0..index.column_count], index.columns.?[0..index.column_count]);
    index.columns = columns;
    extra += @sizeOf(i16) * count;
    @memcpy(extra[0..index.column_count], index.sort_order.?[0..index.column_count]);
    index.sort_order = extra;
    index.column_count = @intCast(column_count);
    index.properties.resized = true;
    return 0;
}

/// Source `sqlite3DefaultRowEst()`.
pub fn defaultRowEstimates(index: *schema.Index) void {
    const defaults = [_]i16{ 33, 32, 30, 28, 26 };
    const estimates = index.row_log_estimates.?;
    var table_estimate = index.table.?.row_log_estimate;
    if (table_estimate < 99) {
        table_estimate = 99;
        index.table.?.row_log_estimate = table_estimate;
    }
    if (index.partial_predicate != null) table_estimate -= 10;
    estimates[0] = table_estimate;
    const copied: usize = @min(defaults.len, @as(usize, index.key_column_count));
    @memcpy(estimates[1 .. copied + 1], defaults[0..copied]);
    for (copied + 1..@as(usize, index.key_column_count) + 1) |position| estimates[position] = 23;
    if (index.conflict_action != 0) estimates[index.key_column_count] = 0;
}

/// Source `sqlite3CheckObjectName()`.
pub fn checkObjectName(parse: *parse_types.Parse, name: [*:0]const u8, object_type: [*:0]const u8, table_name: [*:0]const u8) c_int {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (writableSchema(db) or db.init.flags.imposterTable != 0) return 0;
    if (db.init.busy != 0) {
        const expected = db.init.azInit.?;
        if (sqlite_string.compareInternal(object_type, expected[0].?) != 0 or sqlite_string.compareInternal(name, expected[1].?) != 0 or sqlite_string.compareInternal(table_name, expected[2].?) != 0) {
            parse.zErrMsg = db_allocator.stringNDuplicate(db, "".ptr, 0);
            parse.nErr += 1;
            parse.rc = 1;
            return 1;
        }
    } else if ((parse.nested == 0 and sqlite_string.compareN(name, "sqlite_", 7) == 0) or (readOnlyShadowTables(db) and shadowTableName(db, name))) {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "object name reserved for internal use: {s}", .{name}) catch "object name reserved for internal use";
        parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
        parse.nErr += 1;
        parse.rc = 1;
        return 1;
    }
    return 0;
}

/// Source `sqlite3PrimaryKeyIndex()`.
pub fn primaryKeyIndex(table: *schema.Table) ?*schema.Index {
    var index = table.indexes;
    while (index) |present| : (index = present.next) if (present.properties.kind == 2) return present;
    return null;
}

/// Source `sqlite3TableColumnToIndex()`.
pub fn tableColumnToIndex(index: *const schema.Index, column: c_int) c_int {
    for (index.columns.?[0..index.column_count], 0..) |indexed_column, position| if (indexed_column == column) return @intCast(position);
    return -1;
}

/// Source `sqlite3StorageColumnToTable()`.
pub fn storageColumnToTable(table: *const schema.Table, column_initial: i16) i16 {
    var column = column_initial;
    if (table.flags & 0x0000_0020 != 0) {
        var position: i16 = 0;
        while (position <= column) : (position += 1) {
            if (table.columns.?[@intCast(position)].flags & 0x0020 != 0) column += 1;
        }
    }
    return column;
}

/// Source `sqlite3TableColumnToStorage()`.
pub fn tableColumnToStorage(table: *const schema.Table, column: i16) i16 {
    if (table.flags & 0x0000_0020 == 0 or column < 0) return column;
    var stored_before: i16 = 0;
    for (table.columns.?[0..@intCast(column)]) |candidate| {
        if (candidate.flags & 0x0020 == 0) stored_before += 1;
    }
    return if (table.columns.?[@intCast(column)].flags & 0x0020 != 0)
        table.non_virtual_column_count + column - stored_before
    else
        stored_before;
}

/// Source `identPut()`.
pub fn putIdentifier(output: [*]u8, offset: *c_int, identifier: [*:0]const u8) void {
    const text = std.mem.span(identifier);
    var valid_length: usize = 0;
    while (valid_length < text.len and (std.ascii.isAlphanumeric(text[valid_length]) or text[valid_length] == '_')) : (valid_length += 1) {}
    const quote = text.len == 0 or std.ascii.isDigit(text[0]) or valid_length != text.len or tokenizer.keywordCode(text) != tokens.tk_id;
    var position: usize = @intCast(offset.*);
    if (quote) {
        output[position] = '\"';
        position += 1;
    }
    for (text) |byte| {
        output[position] = byte;
        position += 1;
        if (byte == '\"') {
            output[position] = '\"';
            position += 1;
        }
    }
    if (quote) {
        output[position] = '\"';
        position += 1;
    }
    output[position] = 0;
    offset.* = @intCast(position);
}

/// Source `isDupColumn()`.
pub fn isDuplicateColumn(index: *schema.Index, key_count: c_int, primary: *schema.Index, primary_column: c_int) bool {
    const table_column = primary.columns.?[@intCast(primary_column)];
    for (index.columns.?[0..@intCast(key_count)], index.collations.?[0..@intCast(key_count)]) |column, collation| {
        if (column == table_column and sqlite_string.compareInternal(collation.?, primary.collations.?[@intCast(primary_column)].?) == 0) return true;
    }
    return false;
}

/// Source `estimateTableWidth()`.
pub fn estimateTableWidth(table: *schema.Table) void {
    var width: u64 = 0;
    for (table.columns.?[0..@intCast(table.column_count)]) |column| width += column.estimated_size;
    if (table.primary_key_column < 0) width += 1;
    table.row_size_estimate = log_est.fromInt(width * 4);
}

/// Source `estimateIndexWidth()`.
pub fn estimateIndexWidth(index: *schema.Index) void {
    var width: u64 = 0;
    const table = index.table.?;
    for (index.columns.?[0..index.column_count]) |column| {
        width += if (column < 0) 1 else table.columns.?[@intCast(column)].estimated_size;
    }
    index.row_size_estimate = log_est.fromInt(width * 4);
}

/// Source `hasColumn()`.
pub fn hasColumn(columns: [*]const i16, column_count: c_int, target: c_int) bool {
    for (columns[0..@intCast(column_count)]) |column| if (column == target) return true;
    return false;
}

/// Source `collationMatch()`.
pub fn collationMatch(collation: [*:0]const u8, index: *const schema.Index) bool {
    for (index.collations.?[0..index.column_count]) |candidate| if (sqlite_string.compareInternal(candidate.?, collation) == 0) return true;
    return false;
}

/// Source `sqlite3ColumnType()`: resolve a custom type stored after the column
/// name, a compact standard type code, or the caller's fallback.
pub fn schemaColumnType(column: *const schema.Column, fallback: ?[*:0]const u8) ?[*:0]const u8 {
    if (column.flags & 0x0004 != 0) {
        const name: [*:0]const u8 = @ptrCast(column.name_and_metadata.?);
        return name + std.mem.len(name) + 1;
    }
    const standard_types = [_][*:0]const u8{ "ANY", "BLOB", "INT", "INTEGER", "REAL", "TEXT" };
    const standard = column.definition.declared_type;
    if (standard != 0) {
        std.debug.assert(standard <= standard_types.len);
        return standard_types[standard - 1];
    }
    return fallback;
}

test "column type resolves custom compact standard and fallback representations" {
    var storage = [_:0]u8{ 'x', 0, 'C', 'U', 'S', 'T', 'O', 'M', 0 };
    var column = std.mem.zeroes(schema.Column);
    column.name_and_metadata = &storage;
    column.flags = 0x0004;
    try std.testing.expectEqualStrings("CUSTOM", std.mem.span(schemaColumnType(&column, "fallback").?));
    column.flags = 0;
    column.definition.declared_type = 4;
    try std.testing.expectEqualStrings("INTEGER", std.mem.span(schemaColumnType(&column, "fallback").?));
    column.definition.declared_type = 0;
    try std.testing.expectEqualStrings("fallback", std.mem.span(schemaColumnType(&column, "fallback").?));
    try std.testing.expect(schemaColumnType(&column, null) == null);
}

/// Source `recomputeColumnsNotIndexed()`.
pub fn recomputeColumnsNotIndexed(index: *schema.Index) void {
    var mask: u64 = 0;
    const table = index.table.?;
    for (index.columns.?[0..index.column_count]) |column| {
        if (column >= 0 and table.columns.?[@intCast(column)].flags & 0x0020 == 0 and column < 63) mask |= @as(u64, 1) << @intCast(column);
    }
    index.columns_not_indexed = ~mask;
}
