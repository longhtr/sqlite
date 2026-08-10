//! Foreign-key dependency analysis helpers from `fkey.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const sqlite_string = @import("../string.zig");
const expression_analysis = @import("expression_analysis.zig");
const db_allocator = @import("db_allocator.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const types = @import("vdbe_types.zig");

/// Source `fkTriggerDelete()`.
pub fn deleteForeignKeyTrigger(db: *types.Sqlite3, trigger_optional: ?*parse_types.Trigger) void {
    const trigger = trigger_optional orelse return;
    const step = trigger.steps.?;
    compiler_ownership.deleteSourceList(db, step.sources);
    compiler_ownership.deleteExpression(db, step.where);
    compiler_ownership.deleteExpressionList(db, step.expressions);
    compiler_ownership.deleteSelect(db, step.select);
    compiler_ownership.deleteExpression(db, trigger.when);
    db_allocator.freeNN(db, trigger);
}

/// Source `sqlite3FkClearTriggerCache()`.
pub fn clearTriggerCache(db: *types.Sqlite3, database_index: c_int) void {
    var element = db.aDb.?[@intCast(database_index)].pSchema.?.table_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const table: *schema.Table = @ptrCast(@alignCast(present.value().?));
        if (table.kind != .ordinary) continue;
        var foreign_key = table.owner.ordinary.foreign_keys;
        while (foreign_key) |key| : (foreign_key = key.next_from) {
            deleteForeignKeyTrigger(db, if (key.triggers[0]) |trigger| @ptrCast(@alignCast(trigger)) else null);
            deleteForeignKeyTrigger(db, if (key.triggers[1]) |trigger| @ptrCast(@alignCast(trigger)) else null);
            key.triggers = .{ null, null };
        }
    }
}

/// Source `exprTableRegister()`.
pub fn tableRegisterExpression(parse: *parse_types.Parse, table: *schema.Table, register_base: c_int, column_index: i16) ?*parse_types.Expr {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var result = expression_analysis.newExpression(db, @intCast(tokens.tk_register), null) orelse return null;
    if (column_index >= 0 and column_index != table.primary_key_column) {
        const column = &table.columns.?[@intCast(column_index)];
        result.iTable = register_base + schema_analysis.tableColumnToStorage(table, column_index) + 1;
        result.affExpr = column.affinity;
        const collation_name = schema_analysis.columnCollation(column) orelse db.pDfltColl.?.zName.?;
        var token = parse_types.Token{ .z = collation_name, .n = @intCast(std.mem.len(collation_name)) };
        result = expression_analysis.addCollationToken(parse, result, &token, false);
    } else {
        result.iTable = register_base;
        result.affExpr = schema_analysis.affinity.integer;
    }
    return result;
}

/// Source `exprTableColumn()`.
pub fn tableColumnExpression(db: *types.Sqlite3, table: *schema.Table, cursor: c_int, column: i16) ?*parse_types.Expr {
    const result = expression_analysis.newExpression(db, @intCast(tokens.tk_column), null) orelse return null;
    result.y.pTab = table;
    result.iTable = cursor;
    result.iColumn = column;
    return result;
}

/// Source `sqlite3DeferForeignKey()`.
pub fn deferMostRecentForeignKey(parse: *parse_types.Parse, deferred: bool) void {
    const table = parse.pNewTable orelse return;
    if (table.kind != .ordinary) return;
    const foreign_key = table.owner.ordinary.foreign_keys orelse return;
    foreign_key.deferred = @intFromBool(deferred);
}

/// Source `sqlite3FkDelete()`.
pub fn deleteForeignKeys(db: *types.Sqlite3, table: *schema.Table) void {
    var foreign_key = table.owner.ordinary.foreign_keys;
    while (foreign_key) |key| {
        const next = key.next_from;
        if (db.pnBytesFreed == null) {
            if (key.previous_to) |previous| {
                previous.next_to = key.next_to;
            } else {
                const name = if (key.next_to) |following| following.target_table.? else key.target_table.?;
                _ = table.schema.?.foreign_key_hash.insert(db_allocator.stdAllocator(db), name, if (key.next_to) |following| @ptrCast(following) else null);
            }
            if (key.next_to) |following| following.previous_to = key.previous_to;
        }
        deleteForeignKeyTrigger(db, if (key.triggers[0]) |trigger| @ptrCast(@alignCast(trigger)) else null);
        deleteForeignKeyTrigger(db, if (key.triggers[1]) |trigger| @ptrCast(@alignCast(trigger)) else null);
        db_allocator.freeNN(db, key);
        foreign_key = next;
    }
}

/// Source `sqlite3FkReferences()`.
pub fn references(table: *schema.Table) ?*schema.ForeignKey {
    const result = table.schema.?.foreign_key_hash.find(table.name.?) orelse return null;
    return @ptrCast(@alignCast(result));
}

/// Source `fkChildIsModified()`.
pub fn childIsModified(table: *schema.Table, foreign_key: *schema.ForeignKey, changes: [*]const c_int, rowid_changed: bool) bool {
    for (foreign_key.columns()) |column| {
        const child_column = column.source_column;
        if (changes[@intCast(child_column)] >= 0) return true;
        if (child_column == table.primary_key_column and rowid_changed) return true;
    }
    return false;
}

/// Source `fkParentIsModified()`.
pub fn parentIsModified(table: *schema.Table, foreign_key: *schema.ForeignKey, changes: [*]const c_int, rowid_changed: bool) bool {
    for (foreign_key.columns()) |foreign_column| {
        for (table.columns.?[0..@intCast(table.column_count)], 0..) |*column, index| {
            const is_rowid_alias = table.primary_key_column >= 0 and index == @as(usize, @intCast(table.primary_key_column));
            if (changes[index] < 0 and !(is_rowid_alias and rowid_changed)) continue;
            if (foreign_column.target_column) |target| {
                if (sqlite_string.compareInternal(column.name_and_metadata.?, target) == 0) return true;
            } else if (column.flags & 0x0001 != 0) return true;
        }
    }
    return false;
}

const TriggerProgramPrefix = extern struct { trigger: ?*parse_types.Trigger };

/// Source `isSetNullAction()`.
pub fn isSetNullAction(parse_initial: *parse_types.Parse, foreign_key: *schema.ForeignKey) bool {
    const parse = parse_initial.pToplevel orelse parse_initial;
    const program_opaque = parse.pTriggerPrg orelse return false;
    const program: *TriggerProgramPrefix = @ptrCast(@alignCast(program_opaque));
    const trigger_address = if (program.trigger) |trigger| @intFromPtr(trigger) else 0;
    return (foreign_key.triggers[0] != null and @intFromPtr(foreign_key.triggers[0].?) == trigger_address and foreign_key.actions.on_delete == parse_types.foreign_action.set_null) or
        (foreign_key.triggers[1] != null and @intFromPtr(foreign_key.triggers[1].?) == trigger_address and foreign_key.actions.on_update == parse_types.foreign_action.set_null);
}

/// Source `sqlite3FkRequired()`.
pub fn required(
    db: *types.Sqlite3,
    table: *schema.Table,
    changes: ?[*]const c_int,
    rowid_changed: bool,
) c_int {
    if (db.flags & types.connection_flag.foreign_keys == 0 or table.kind != .ordinary) return 0;
    if (changes == null) return if (references(table) != null or table.owner.ordinary.foreign_keys != null) 1 else 0;
    var have_foreign_key = false;
    var result: c_int = 1;
    var foreign_key = table.owner.ordinary.foreign_keys;
    while (foreign_key) |key| : (foreign_key = key.next_from) {
        if (childIsModified(table, key, changes.?, rowid_changed)) {
            if (sqlite_string.compareInternal(table.name.?, key.target_table.?) == 0) result = 2;
            have_foreign_key = true;
        }
    }
    foreign_key = references(table);
    while (foreign_key) |key| : (foreign_key = key.next_to) {
        if (parentIsModified(table, key, changes.?, rowid_changed)) {
            if (db.flags & types.connection_flag.foreign_key_no_action == 0 and key.actions.on_update != 0) return 2;
            have_foreign_key = true;
        }
    }
    return if (have_foreign_key) result else 0;
}
