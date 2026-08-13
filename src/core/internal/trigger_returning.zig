//! RETURNING-clause wildcard and correlated-subquery analysis from `trigger.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const db_allocator = @import("db_allocator.zig");
const ast_duplication = @import("ast_duplication.zig");
const schema_analysis = @import("schema_analysis.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const parse_types = @import("parse_types.zig");
const walker_api = @import("walker.zig");
const schema = @import("schema_types.zig");
const select_analysis = @import("select_analysis.zig");
const types = @import("vdbe_types.zig");

fn setError(parse: *parse_types.Parse, message: []const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `sqlite3DeleteTriggerStep()`.
pub fn deleteTriggerSteps(db: *types.Sqlite3, first: ?*parse_types.TriggerStep) void {
    var current = first;
    while (current) |step| {
        const next = step.next;
        compiler_ownership.deleteExpression(db, step.where);
        compiler_ownership.deleteExpressionList(db, step.expressions);
        compiler_ownership.deleteSelect(db, step.select);
        compiler_ownership.deleteIdentifierList(db, step.columns);
        compiler_ownership.deleteUpsert(db, step.upsert);
        compiler_ownership.deleteSourceList(db, step.sources);
        db_allocator.free(db, if (step.span) |span| @ptrCast(span) else null);
        db_allocator.freeNN(db, step);
        current = next;
    }
}

/// Source `triggerSpanDup()`.
pub fn duplicateTriggerSpan(db: *types.Sqlite3, start: [*]const u8, end: [*]const u8) ?[*:0]u8 {
    const result = db_allocator.spanDuplicate(db, start, end) orelse return null;
    for (std.mem.span(result)) |*byte| {
        if (std.ascii.isWhitespace(byte.*)) byte.* = ' ';
    }
    return result;
}

/// Source `triggerStepAllocate()`.
pub fn allocateTriggerStep(parse: *parse_types.Parse, operation: u8, table_list: *parse_types.SrcList, start: [*]const u8, end: [*]const u8) ?*parse_types.TriggerStep {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var result: ?*parse_types.TriggerStep = null;
    if (parse.nErr == 0) {
        if (parse.pNewTrigger != null and parse.pNewTrigger.?.schema != db.aDb.?[1].pSchema and table_list.items()[0].u4.zDatabase != null) {
            setError(parse, "qualified table names are not allowed on INSERT, UPDATE, and DELETE statements within triggers");
        } else if (db_allocator.mallocZero(db, @sizeOf(parse_types.TriggerStep))) |raw| {
            const step: *parse_types.TriggerStep = @ptrCast(@alignCast(raw));
            step.sources = ast_duplication.duplicateSourceList(db, table_list, true);
            step.operation = operation;
            step.span = duplicateTriggerSpan(db, start, end);
            result = step;
        }
    }
    compiler_ownership.deleteSourceList(db, table_list);
    return result;
}

/// Source `sqlite3TriggerInsertStep()`.
pub fn insertTriggerStep(parse: *parse_types.Parse, table_list: *parse_types.SrcList, columns: ?*parse_types.IdList, select_initial: ?*parse_types.Select, conflict_action: u8, upsert: ?*parse_types.Upsert, start: [*]const u8, end: [*]const u8) ?*parse_types.TriggerStep {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var select = select_initial;
    const result = allocateTriggerStep(parse, @intCast(tokens.tk_insert), table_list, start, end);
    if (result) |step| {
        if (parse.eParseMode >= 2) {
            step.select = select;
            select = null;
        } else step.select = ast_duplication.duplicateSelect(db, select, true);
        step.columns = columns;
        step.upsert = upsert;
        step.conflict_action = conflict_action;
        if (upsert) |present| _ = schema_analysis.hasExplicitNulls(parse, present.pUpsertTarget);
    } else {
        compiler_ownership.deleteIdentifierList(db, columns);
        compiler_ownership.deleteUpsert(db, upsert);
    }
    compiler_ownership.deleteSelect(db, select);
    return result;
}

/// Source `sqlite3TriggerUpdateStep()`.
pub fn updateTriggerStep(parse: *parse_types.Parse, table_list: *parse_types.SrcList, from_initial: ?*parse_types.SrcList, expressions_initial: ?*parse_types.ExprList, where_initial: ?*parse_types.Expr, conflict_action: u8, start: [*]const u8, end: [*]const u8) ?*parse_types.TriggerStep {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var from = from_initial;
    var expressions = expressions_initial;
    var where = where_initial;
    const result = allocateTriggerStep(parse, @intCast(tokens.tk_update), table_list, start, end);
    if (result) |step| {
        var from_duplicate: ?*parse_types.SrcList = null;
        if (parse.eParseMode >= 2) {
            step.expressions = expressions;
            step.where = where;
            from_duplicate = from;
            expressions = null;
            where = null;
            from = null;
        } else {
            step.expressions = ast_duplication.duplicateExpressionList(db, expressions, true);
            step.where = ast_duplication.duplicateExpression(db, where, true);
            from_duplicate = ast_duplication.duplicateSourceList(db, from, true);
        }
        step.conflict_action = conflict_action;
        if (from_duplicate != null and parse.eParseMode < 2) {
            const nested = select_analysis.newSelect(parse, null, from_duplicate, null, null, null, null, 0x0000_0800, null);
            var alias = parse_types.Token{ .z = null, .n = 0 };
            from_duplicate = select_analysis.appendSourceFromTerm(parse, null, null, null, &alias, nested, null);
        }
        if (from_duplicate != null and step.sources != null) step.sources = select_analysis.appendSourceLists(parse, step.sources.?, from_duplicate) else compiler_ownership.deleteSourceList(db, from_duplicate);
    }
    compiler_ownership.deleteExpressionList(db, expressions);
    compiler_ownership.deleteExpression(db, where);
    compiler_ownership.deleteSourceList(db, from);
    return result;
}

/// Source `sqlite3TriggerDeleteStep()`.
pub fn deleteTriggerStep(parse: *parse_types.Parse, table_list: *parse_types.SrcList, where_initial: ?*parse_types.Expr, start: [*]const u8, end: [*]const u8) ?*parse_types.TriggerStep {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var where = where_initial;
    const result = allocateTriggerStep(parse, @intCast(tokens.tk_delete), table_list, start, end);
    if (result) |step| {
        if (parse.eParseMode >= 2) {
            step.where = where;
            where = null;
        } else step.where = ast_duplication.duplicateExpression(db, where, true);
        step.conflict_action = 0;
    }
    compiler_ownership.deleteExpression(db, where);
    return result;
}

/// Source `sqlite3TriggerSelectStep()`.
pub fn selectTriggerStep(db: *types.Sqlite3, select: *parse_types.Select, start: [*]const u8, end: [*]const u8) ?*parse_types.TriggerStep {
    const raw = db_allocator.mallocZero(db, @sizeOf(parse_types.TriggerStep)) orelse {
        compiler_ownership.deleteSelect(db, select);
        return null;
    };
    const step: *parse_types.TriggerStep = @ptrCast(@alignCast(raw));
    step.operation = @intCast(tokens.tk_select);
    step.select = select;
    step.conflict_action = 0;
    step.span = duplicateTriggerSpan(db, start, end);
    return step;
}

/// Source `sqlite3DeleteTrigger()`.
pub fn deleteTrigger(db: *types.Sqlite3, trigger_optional: ?*parse_types.Trigger) void {
    const trigger = trigger_optional orelse return;
    if (trigger.returning != 0) return;
    deleteTriggerSteps(db, trigger.steps);
    db_allocator.free(db, if (trigger.name) |name| @ptrCast(name) else null);
    db_allocator.free(db, if (trigger.table_name) |name| @ptrCast(name) else null);
    compiler_ownership.deleteExpression(db, trigger.when);
    compiler_ownership.deleteIdentifierList(db, trigger.columns);
    db_allocator.freeNN(db, trigger);
}

/// Source `sqlite3UnlinkAndDeleteTrigger()`.
pub fn unlinkAndDeleteTrigger(db: *types.Sqlite3, database_index: c_int, name: [*:0]const u8) void {
    const owner = db.aDb.?[@intCast(database_index)].pSchema.?;
    const removed = owner.trigger_hash.insert(db_allocator.stdAllocator(db), name, null) orelse return;
    const trigger: *parse_types.Trigger = @ptrCast(@alignCast(removed));
    if (trigger.schema == trigger.table_schema) {
        const value = trigger.table_schema.?.table_hash.find(trigger.table_name.?);
        if (value) |opaque_table| {
            const table: *schema.Table = @ptrCast(@alignCast(opaque_table));
            var link = &table.triggers;
            while (link.*) |present| {
                if (present == trigger) {
                    link.* = present.next;
                    break;
                }
                link = &present.next;
            }
        }
    }
    deleteTrigger(db, trigger);
    db.mDbFlags |= types.database_flag.schema_change;
}

/// Source `sqlite3TriggerList()`.
pub fn triggerList(parse: *parse_types.Parse, table: *schema.Table) ?*parse_types.Trigger {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const temporary_schema = db.aDb.?[1].pSchema.?;
    var result = table.triggers;
    var element = temporary_schema.trigger_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const trigger: *parse_types.Trigger = @ptrCast(@alignCast(present.value().?));
        if (trigger.table_schema == table.schema and trigger.table_name != null and
            @import("../string.zig").compareInternal(trigger.table_name.?, table.name.?) == 0 and
            (trigger.table_schema != temporary_schema or trigger.returning != 0))
        {
            trigger.next = result;
            result = trigger;
        } else if (trigger.operation == tokens.tk_returning) {
            trigger.table_name = table.name;
            trigger.table_schema = table.schema;
            trigger.next = result;
            result = trigger;
        }
    }
    return result;
}

/// Source `triggersReallyExist()`.
pub fn triggersReallyExist(parse: *parse_types.Parse, table: *schema.Table, operation: c_int, changes: ?*parse_types.ExprList, mask_output: ?*c_int) ?*parse_types.Trigger {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var mask: c_int = 0;
    var result = triggerList(parse, table);
    var trigger = result;
    if (trigger != null and db.flags & types.connection_flag.enable_trigger == 0 and table.triggers != null and table.triggers.?.schema != db.aDb.?[1].pSchema) {
        if (result == table.triggers) {
            result = null;
            trigger = null;
        } else {
            while (trigger.?.next != null and trigger.?.next != table.triggers) trigger = trigger.?.next;
            trigger.?.next = null;
            trigger = result;
        }
    }
    while (trigger) |present| : (trigger = present.next) {
        if (present.operation == operation and columnsOverlap(present.columns, changes)) {
            mask |= present.timing;
        } else if (present.operation == tokens.tk_returning) {
            present.operation = @intCast(operation);
            if (table.kind == .virtual) {
                if (operation != tokens.tk_insert) setError(parse, if (operation == tokens.tk_delete) "DELETE RETURNING is not available on virtual tables" else "UPDATE RETURNING is not available on virtual tables");
                present.timing = 1;
            } else present.timing = 2;
            mask |= present.timing;
        } else if (present.returning != 0 and present.operation == tokens.tk_insert and operation == tokens.tk_update and parse.pToplevel == null) {
            mask |= present.timing;
        }
    }
    if (mask_output) |output| output.* = mask;
    return if (mask != 0) result else null;
}

/// Source `sqlite3TriggersExist()`.
pub fn triggersExist(parse: *parse_types.Parse, table: *schema.Table, operation: c_int, changes: ?*parse_types.ExprList, mask_output: ?*c_int) ?*parse_types.Trigger {
    if ((table.triggers == null and !temporaryTriggersExist(@ptrCast(@alignCast(parse.db.?)))) or parse.disableTriggers()) {
        if (mask_output) |output| output.* = 0;
        return null;
    }
    return triggersReallyExist(parse, table, operation, changes, mask_output);
}

/// Source `tempTriggersExist()`.
pub fn temporaryTriggersExist(db: *types.Sqlite3) bool {
    const schema_pointer = db.aDb.?[1].pSchema orelse return false;
    return schema_pointer.trigger_hash.first() != null;
}

/// Source `checkColumnOverlap()`.
pub fn columnsOverlap(identifiers: ?*parse_types.IdList, expressions: ?*parse_types.ExprList) bool {
    const list = identifiers orelse return true;
    const changes = expressions orelse return true;
    for (changes.items()) |item| if (select_analysis.identifierListIndex(list, item.zEName.?) >= 0) return true;
    return false;
}

/// Source `transferParseError()`.
pub fn transferParseError(destination: *parse_types.Parse, source: *parse_types.Parse) void {
    if (destination.nErr == 0) {
        destination.zErrMsg = source.zErrMsg;
        destination.nErr = source.nErr;
        destination.rc = source.rc;
    } else {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(source.db.?));
        db_allocator.free(db, if (source.zErrMsg) |message| @ptrCast(message) else null);
    }
}

/// Source `isAsteriskTerm()`.
pub fn isAsteriskTerm(parse: *parse_types.Parse, expression: *parse_types.Expr) bool {
    if (expression.op == tokens.tk_asterisk) return true;
    if (expression.op != tokens.tk_dot or expression.pRight == null or expression.pLeft == null) return false;
    if (expression.pRight.?.op != tokens.tk_asterisk) return false;
    setError(parse, "RETURNING may not use \"TABLE.*\" wildcards");
    return true;
}

/// Source `sqlite3ReturningSubqueryVarSelect()`.
pub fn markVariableSelect(_: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.usesSelect() and expression.x.pSelect != null and expression.x.pSelect.?.selFlags & parse_types.select_flag.correlated != 0) {
        expression.flags |= parse_types.expr_flag.variable_select;
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3ReturningSubqueryCorrelated()`.
pub fn markCorrelated(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    const table: *schema.Table = @ptrCast(@alignCast(walker.u.pointer.?));
    const sources = select.pSrc.?;
    for (sources.items()) |*item| {
        if (item.table == table) {
            select.selFlags |= parse_types.select_flag.correlated;
            walker.eCode = 1;
            break;
        }
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3ProcessReturningSubqueries()`.
pub fn processReturningSubqueries(expressions: ?*parse_types.ExprList, table: *schema.Table) void {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = walker_api.exprNoop;
    walker.xSelectCallback = markCorrelated;
    walker.u.pointer = table;
    _ = walker_api.walkExprList(&walker, expressions);
    if (walker.eCode != 0) {
        walker.xExprCallback = markVariableSelect;
        walker.xSelectCallback = walker_api.selectNoop;
        _ = walker_api.walkExprList(&walker, expressions);
    }
}
