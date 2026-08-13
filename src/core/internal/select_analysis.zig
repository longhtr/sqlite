//! SELECT source-list and compound-query helpers from `select.c` and `build.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const opcodes = @import("../generated/opcodes.zig");
const sqlite_string = @import("../string.zig");
const expression_analysis = @import("expression_analysis.zig");
const db_allocator = @import("db_allocator.zig");
const collation_registry = @import("collation_registry.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const ast_duplication = @import("ast_duplication.zig");
const cte_analysis = @import("cte_analysis.zig");
const collation_analysis = @import("collation.zig");
const parse_types = @import("parse_types.zig");
const parse_cleanup = @import("parse_cleanup.zig");
const rename_analysis = @import("rename_analysis.zig");
const resolve_analysis = @import("resolve_analysis.zig");
const schema_analysis = @import("schema_analysis.zig");
const schema = @import("schema_types.zig");
const walker_api = @import("walker.zig");
const vdbe_types = @import("vdbe_types.zig");
const vdbe_aux = @import("vdbe_aux.zig");

/// Source `sqlite3KeyInfoAlloc()`.
pub fn allocateKeyInfo(db: *vdbe_types.Sqlite3, key_fields: c_int, extra_fields: c_int) ?*vdbe_types.KeyInfo {
    const field_count: usize = @intCast(key_fields + extra_fields);
    if (field_count > 0xffff) {
        _ = db_allocator.oomFault(db);
        return null;
    }
    const byte_count = vdbe_types.keyInfoSize(field_count) + field_count;
    const raw = db_allocator.mallocRawNN(db, byte_count) orelse return null;
    const info: *vdbe_types.KeyInfo = @ptrCast(@alignCast(raw));
    const collations: [*]?*vdbe_types.CollSeq = @ptrFromInt(@intFromPtr(info) + @offsetOf(vdbe_types.KeyInfo, "aColl"));
    info.aSortFlags = @ptrFromInt(@intFromPtr(collations) + field_count * @sizeOf(?*vdbe_types.CollSeq));
    info.nKeyField = @intCast(key_fields);
    info.nAllField = @intCast(field_count);
    info.enc = db.enc;
    info.db = db;
    info.nRef = 1;
    @memset(@as([*]u8, @ptrCast(collations))[0 .. field_count * @sizeOf(?*vdbe_types.CollSeq) + field_count], 0);
    return info;
}

/// Source `sqlite3KeyInfoUnref()`.
pub fn unreferenceKeyInfo(info_optional: ?*vdbe_types.KeyInfo) void {
    const info = info_optional orelse return;
    info.nRef -= 1;
    if (info.nRef == 0) db_allocator.freeNN(info.db.?, info);
}

/// Source `sqlite3KeyInfoRef()`.
pub fn referenceKeyInfo(info_optional: ?*vdbe_types.KeyInfo) ?*vdbe_types.KeyInfo {
    const info = info_optional orelse return null;
    info.nRef += 1;
    return info;
}

/// Source `sqlite3KeyInfoOfIndex()`.
pub fn keyInfoOfIndex(parse: *parse_types.Parse, index: *schema.Index) ?*vdbe_types.KeyInfo {
    if (parse.nErr != 0) return null;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const column_count: c_int = index.column_count;
    const key_count: c_int = index.key_column_count;
    const info = if (index.properties.unique_not_null)
        allocateKeyInfo(db, key_count, column_count - key_count)
    else
        allocateKeyInfo(db, column_count, 0);
    const result = info orelse return null;
    const collations: [*]?*vdbe_types.CollSeq = @ptrFromInt(@intFromPtr(result) + @offsetOf(vdbe_types.KeyInfo, "aColl"));
    for (0..@intCast(column_count)) |column| {
        const name = index.collations.?[column].?;
        collations[column] = if (sqlite_string.compareInternal(name, "BINARY") == 0) null else collation_registry.locateCollation(parse, name);
        result.aSortFlags.?[column] = index.sort_order.?[column];
    }
    if (parse.nErr != 0) {
        if (!index.properties.no_query and index.schema.?.index_hash.find(index.name.?) != null) {
            index.properties.no_query = true;
            parse.rc = 513;
        }
        unreferenceKeyInfo(result);
        return null;
    }
    return result;
}

/// Source `sqlite3VdbeSetP4KeyInfo()`: derive the Index KeyInfo and transfer
/// it to the most recently emitted operation when derivation succeeds.
pub fn setP4KeyInfo(parse: *parse_types.Parse, index: *schema.Index) void {
    const machine: *vdbe_types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    if (keyInfoOfIndex(parse, index)) |info| {
        vdbe_aux.appendP4(machine, info, vdbe_types.p4.keyinfo);
    }
}

test "source P4 KeyInfo attachment preserves parse-error operation" {
    var parse = std.mem.zeroes(parse_types.Parse);
    var index = std.mem.zeroes(schema.Index);
    var machine = std.mem.zeroes(vdbe_types.Vdbe);
    parse.pVdbe = @ptrCast(&machine);
    parse.nErr = 1;
    machine.nOp = 7;

    setP4KeyInfo(&parse, &index);

    try std.testing.expectEqual(@as(c_int, 7), machine.nOp);
}

/// Source `sqlite3KeyInfoFromExprList()`.
pub fn keyInfoFromExpressionList(parse: *parse_types.Parse, list: *parse_types.ExprList, start: c_int, extra_fields: c_int) ?*vdbe_types.KeyInfo {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const info = allocateKeyInfo(db, list.nExpr - start, extra_fields + 1) orelse return null;
    const collations: [*]?*vdbe_types.CollSeq = @ptrFromInt(@intFromPtr(info) + @offsetOf(vdbe_types.KeyInfo, "aColl"));
    for (list.items()[@intCast(start)..], 0..) |item, index| {
        collations[index] = expression_analysis.expressionNonNullCollation(parse, item.pExpr.?);
        info.aSortFlags.?[index] = item.fg.sortFlags;
    }
    return info;
}

pub const OnClauseCheckContext = struct {
    sources: *parse_types.SrcList,
    join_cursor: c_int = 0,
    function_argument: bool = false,
    parent: ?*OnClauseCheckContext = null,
};

fn setParseError(parse: *parse_types.Parse, message: []const u8) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `selectCheckOnClausesExpr()`.
pub fn checkOnClauseExpression(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    var context: ?*OnClauseCheckContext = @ptrCast(@alignCast(walker.u.pointer.?));
    const initial = context.?;
    if (expression_node.flags & 0x0000_0001 != 0 or
        (expression_node.flags & 0x0000_0002 != 0 and initial.sources.items()[0].fg.jointype & 0x40 != 0))
    {
        if (initial.join_cursor == 0) {
            initial.join_cursor = expression_node.w.iJoin;
            _ = walker_api.walkExprNonNull(walker, expression_node);
            initial.join_cursor = 0;
            return walker_api.prune;
        }
    }
    if (expression_node.op == tokens.tk_column) {
        while (context) |present| : (context = present.parent) {
            var found = false;
            for (present.sources.items()) |source| {
                if (source.iCursor == expression_node.iTable) {
                    found = true;
                    break;
                }
            }
            if (found) {
                if (present.join_cursor != 0 and expression_node.iTable > present.join_cursor) {
                    setParseError(walker.pParse.?, if (present.function_argument) "table-function argument references tables to its right" else "ON clause references tables to its right");
                    return walker_api.abort_walk;
                }
                break;
            }
        }
    }
    return walker_api.continue_walk;
}

/// Source `selectCheckOnClausesSelect()`.
pub fn checkOnClauseSelect(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    const context: *OnClauseCheckContext = @ptrCast(@alignCast(walker.u.pointer.?));
    if (select.pSrc == context.sources or select.pSrc.?.nSrc == 0) return walker_api.continue_walk;
    var nested = OnClauseCheckContext{ .sources = select.pSrc.?, .parent = context };
    walker.u.pointer = &nested;
    _ = walker_api.walkSelect(walker, select);
    walker.u.pointer = context;
    select.selFlags &= ~@as(u32, 0x4000_0000);
    return walker_api.prune;
}

/// Source `sqlite3SelectCheckOnClauses()`.
pub fn checkOnClauses(parse: *parse_types.Parse, select: *parse_types.Select) void {
    var context = OnClauseCheckContext{ .sources = select.pSrc.? };
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.pParse = parse;
    walker.xExprCallback = checkOnClauseExpression;
    walker.xSelectCallback = checkOnClauseSelect;
    walker.u.pointer = &context;
    _ = walker_api.walkExpr(&walker, select.pWhere);
    select.selFlags &= ~@as(u32, 0x4000_0000);
    context.function_argument = true;
    for (select.pSrc.?.items()) |*source| {
        if (source.fg.isTabFunc and source.fg.jointype & 0x20 != 0) {
            context.join_cursor = source.iCursor;
            _ = walker_api.walkExprList(&walker, source.u1.pFuncArg);
        }
    }
}

/// Source `sqlite3AddDefaultValue()`.
pub fn addDefaultValue(parse: *parse_types.Parse, expression: *parse_types.Expr, start: [*]const u8, end: [*]const u8) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (parse.pNewTable) |table| {
        const column = &table.columns.?[@intCast(table.column_count - 1)];
        if (!expression_analysis.isConstantOrFunction(expression, db.init.busy != 0 and db.init.iDb != 1)) {
            var buffer: [192]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "default value of column [{s}] is not constant", .{column.name_and_metadata.?}) catch "default value is not constant";
            setParseError(parse, message);
        } else if (column.flags & 0x0060 != 0) {
            setParseError(parse, "cannot use DEFAULT on a generated column");
        } else {
            var wrapper = std.mem.zeroes(parse_types.Expr);
            wrapper.op = @intCast(tokens.tk_span);
            wrapper.u.zToken = db_allocator.spanDuplicate(db, start, end);
            wrapper.pLeft = expression;
            wrapper.flags = 0x0000_0080;
            const copy = ast_duplication.duplicateExpression(db, &wrapper, true);
            db_allocator.free(db, if (wrapper.u.zToken) |token| @ptrCast(token) else null);
            if (copy) |present| expression_analysis.setColumnExpression(parse, table, column, present);
        }
    }
    compiler_ownership.deleteExpression(db, expression);
}

/// Source `sqlite3AddCheckConstraint()`.
pub fn addCheckConstraint(parse: *parse_types.Parse, expression: *parse_types.Expr, start_initial: [*]const u8, end_initial: [*]const u8) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const table = parse.pNewTable orelse {
        compiler_ownership.deleteExpression(db, expression);
        return;
    };
    table.checks = expression_analysis.appendExpressionList(parse, table.checks, expression);
    if (parse.u1.cr.constraintName.n != 0) {
        expression_analysis.setExpressionListName(parse, table.checks, &parse.u1.cr.constraintName, true);
    } else {
        var start = start_initial + 1;
        var end = end_initial;
        while (std.ascii.isWhitespace(start[0])) start += 1;
        while (std.ascii.isWhitespace((end - 1)[0])) {
            end -= 1;
        }
        var token = parse_types.Token{ .z = start, .n = @intCast(@intFromPtr(end) - @intFromPtr(start)) };
        expression_analysis.setExpressionListName(parse, table.checks, &token, true);
    }
}

/// Source `sqlite3AddGenerated()`.
pub fn addGeneratedColumn(parse: *parse_types.Parse, expression_initial: ?*parse_types.Expr, storage_type: ?*const parse_types.Token) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var expression = expression_initial;
    const table = parse.pNewTable orelse {
        compiler_ownership.deleteExpression(db, expression);
        return;
    };
    const column = &table.columns.?[@intCast(table.column_count - 1)];
    var generated_type: u32 = 0x0020;
    var valid = column.default_expression_index == 0;
    if (storage_type) |token| {
        if (token.n == 7 and sqlite_string.compareN(token.z.?, "virtual", 7) == 0) {} else if (token.n == 6 and sqlite_string.compareN(token.z.?, "stored", 6) == 0) generated_type = 0x0040 else valid = false;
    }
    if (!valid) {
        var buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "error in generated column \"{s}\"", .{column.name_and_metadata.?}) catch "error in generated column";
        setParseError(parse, message);
        compiler_ownership.deleteExpression(db, expression);
        return;
    }
    if (generated_type == 0x0020) table.non_virtual_column_count -= 1;
    column.flags |= generated_type;
    table.flags |= generated_type;
    if (column.flags & 0x0001 != 0) schema_analysis.makeColumnPrimaryKey(parse, column);
    if (expression != null and expression.?.op == tokens.tk_id) expression = expression_analysis.parsedExpression(parse, @intCast(tokens.tk_uplus), expression, null);
    if (expression != null and expression.?.op != tokens.tk_raise) expression.?.affExpr = column.affinity;
    if (expression) |present| expression_analysis.setColumnExpression(parse, table, column, present);
}

/// Source `sqlite3SelectNew()`.
pub fn newSelect(parse: *parse_types.Parse, expressions_initial: ?*parse_types.ExprList, sources_initial: ?*parse_types.SrcList, where: ?*parse_types.Expr, group_by: ?*parse_types.ExprList, having: ?*parse_types.Expr, order_by: ?*parse_types.ExprList, flags: u32, limit: ?*parse_types.Expr) ?*parse_types.Select {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocRawNN(db, @sizeOf(parse_types.Select)) orelse {
        compiler_ownership.deleteExpressionList(db, expressions_initial);
        compiler_ownership.deleteSourceList(db, sources_initial);
        compiler_ownership.deleteExpression(db, where);
        compiler_ownership.deleteExpressionList(db, group_by);
        compiler_ownership.deleteExpression(db, having);
        compiler_ownership.deleteExpressionList(db, order_by);
        compiler_ownership.deleteExpression(db, limit);
        return null;
    };
    const result: *parse_types.Select = @ptrCast(@alignCast(raw));
    result.* = std.mem.zeroes(parse_types.Select);
    var expressions = expressions_initial;
    if (expressions == null) expressions = expression_analysis.appendExpressionList(parse, null, expression_analysis.newExpression(db, @intCast(tokens.tk_asterisk), null));
    var sources = sources_initial;
    if (sources == null) {
        const source_raw = db_allocator.mallocZero(db, parse_types.SrcList.one_item_size);
        if (source_raw) |present| sources = @ptrCast(@alignCast(present));
    }
    result.pEList = expressions;
    result.op = @intCast(tokens.tk_select);
    result.selFlags = flags;
    parse.nSelect += 1;
    result.selId = @intCast(parse.nSelect);
    result.pSrc = sources;
    result.pWhere = where;
    result.pGroupBy = group_by;
    result.pHaving = having;
    result.pOrderBy = order_by;
    result.pLimit = limit;
    if (db.mallocFailed != 0) {
        compiler_ownership.deleteSelect(db, result);
        return null;
    }
    return result;
}

/// Source `sqlite3SrcItemAttachSubquery()`.
pub fn attachSubquery(parse: *parse_types.Parse, source: *parse_types.SrcItem, select_initial: *parse_types.Select, duplicate: bool) bool {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (source.fg.fixedSchema) {
        source.u4.pSchema = null;
        source.fg.fixedSchema = false;
    } else if (source.u4.zDatabase) |database| {
        db_allocator.freeNN(db, database);
        source.u4.zDatabase = null;
    }
    const select = if (duplicate) ast_duplication.duplicateSelect(db, select_initial, false) orelse return false else select_initial;
    const raw = db_allocator.mallocRawNN(db, @sizeOf(parse_types.Subquery)) orelse {
        compiler_ownership.deleteSelect(db, select);
        return false;
    };
    const subquery: *parse_types.Subquery = @ptrCast(@alignCast(raw));
    subquery.* = std.mem.zeroes(parse_types.Subquery);
    subquery.pSelect = select;
    source.u4.pSubq = subquery;
    source.fg.isSubquery = true;
    return true;
}

/// Source `sqlite3SrcListAppendFromTerm()`.
pub fn appendSourceFromTerm(parse: *parse_types.Parse, sources_initial: ?*parse_types.SrcList, table: ?*const parse_types.Token, database: ?*const parse_types.Token, alias: *const parse_types.Token, subquery: ?*parse_types.Select, on_or_using: ?*parse_types.OnOrUsing) ?*parse_types.SrcList {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (sources_initial == null and on_or_using != null and (on_or_using.?.pOn != null or on_or_using.?.pUsing != null)) {
        setParseError(parse, if (on_or_using.?.pOn != null) "a JOIN clause is required before ON" else "a JOIN clause is required before USING");
        if (on_or_using.?.pOn) |on| compiler_ownership.deleteExpression(db, on);
        if (on_or_using.?.pUsing) |using| compiler_ownership.deleteIdentifierList(db, using);
        compiler_ownership.deleteSelect(db, subquery);
        return null;
    }
    const sources = appendSourceList(parse, sources_initial, table, database) orelse {
        if (on_or_using) |constraint| {
            compiler_ownership.deleteExpression(db, constraint.pOn);
            compiler_ownership.deleteIdentifierList(db, constraint.pUsing);
        }
        compiler_ownership.deleteSelect(db, subquery);
        return null;
    };
    const source = &sources.items()[@intCast(sources.nSrc - 1)];
    if (alias.n != 0) source.zAlias = schema_analysis.nameFromToken(db, alias);
    if (subquery) |select| {
        if (attachSubquery(parse, source, select, false) and select.selFlags & 0x0000_0800 != 0) source.fg.isNestedFrom = true;
    }
    if (on_or_using == null) {
        source.u3.pOn = null;
    } else if (on_or_using.?.pUsing) |using| {
        source.fg.isUsing = true;
        source.u3.pUsing = using;
    } else source.u3.pOn = on_or_using.?.pOn;
    return sources;
}

pub const SelectDestination = extern struct {
    destination: u8,
    parameter: c_int,
    parameter_2: c_int,
    result_register: c_int,
    result_count: c_int,
    affinity: ?[*:0]u8,
    order_by: ?*parse_types.ExprList,
};

/// Source `minMaxQuery()`.
pub fn minMaxQuery(db: *vdbe_types.Sqlite3, function: *parse_types.Expr, order_by_output: *?*parse_types.ExprList) u8 {
    const arguments = function.x.pList orelse return 0;
    if (arguments.nExpr != 1 or function.flags & parse_types.expr_flag.win_func != 0 or !vdbe_types.optimizationEnabled(db, vdbe_types.optimization.min_max)) return 0;
    const name = function.u.zToken.?;
    var result: u8 = 0;
    var sort_flags: u8 = 0;
    if (sqlite_string.compareInternal(name, "min") == 0) {
        result = 1;
        if (expression_analysis.canBeNull(arguments.items()[0].pExpr.?)) sort_flags = 0x02;
    } else if (sqlite_string.compareInternal(name, "max") == 0) {
        result = 2;
        sort_flags = 0x01;
    } else return 0;
    order_by_output.* = ast_duplication.duplicateExpressionList(db, arguments, false);
    if (order_by_output.*) |order_by| order_by.items()[0].fg.sortFlags = sort_flags;
    return result;
}

/// Source `sqlite3IndexedByLookup()`.
pub fn indexedByLookup(parse: *parse_types.Parse, source: *parse_types.SrcItem) c_int {
    const name = source.u1.zIndexedBy.?;
    var index = source.pSTab.?.indexes;
    while (index) |present| : (index = present.next) {
        if (sqlite_string.compareInternal(present.name.?, name) == 0) {
            source.u2.pIBIndex = present;
            return 0;
        }
    }
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "no such index: {s}", .{name}) catch "no such index";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
    parse.flags0 |= 0x01;
    return 1;
}

/// Source `sqlite3ExprAddFunctionOrderBy()`.
pub fn addFunctionOrderBy(parse: *parse_types.Parse, function_optional: ?*parse_types.Expr, order_by: *parse_types.ExprList) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const function = function_optional orelse {
        compiler_ownership.deleteExpressionList(db, order_by);
        return;
    };
    if (function.x.pList == null or function.x.pList.?.nExpr == 0) {
        _ = parse_cleanup.add(parse, parse_cleanup.expressionListCallback, order_by);
        return;
    }
    if (function.flags & parse_types.expr_flag.win_func != 0) {
        setParseError(parse, "ORDER BY may not be used with non-aggregate function");
        compiler_ownership.deleteExpressionList(db, order_by);
        return;
    }
    if (order_by.nExpr > db.aLimit[2]) {
        setParseError(parse, "too many terms in ORDER BY clause");
        compiler_ownership.deleteExpressionList(db, order_by);
        return;
    }
    const order = expression_analysis.allocateExpression(db, @intCast(tokens.tk_order), null, false) orelse {
        compiler_ownership.deleteExpressionList(db, order_by);
        return;
    };
    order.x.pList = order_by;
    function.pLeft = order;
    order.flags |= 0x0002_0000;
}

/// Source `sqlite3ExprForVectorField()`.
pub fn expressionForVectorField(parse: *parse_types.Parse, vector_initial: *parse_types.Expr, field: c_int, field_count: c_int) ?*parse_types.Expr {
    var vector = vector_initial;
    if (vector.op == tokens.tk_select) {
        const result = expression_analysis.parsedExpression(parse, @intCast(tokens.tk_select_column), null, null) orelse return null;
        result.flags |= 0x0002_0000;
        result.iTable = field_count;
        result.iColumn = field;
        result.pLeft = vector;
        return result;
    }
    if (vector.op == tokens.tk_vector) {
        const pointer = &vector.x.pList.?.items()[@intCast(field)].pExpr;
        vector = pointer.*.?;
        if (parse.eParseMode >= 2) {
            pointer.* = null;
            return vector;
        }
    }
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    return ast_duplication.duplicateExpression(db, vector, false);
}

/// Source `sqlite3ExprListAppendVector()`.
pub fn appendExpressionVector(parse: *parse_types.Parse, list_initial: ?*parse_types.ExprList, columns: *parse_types.IdList, expression_initial: ?*parse_types.Expr) ?*parse_types.ExprList {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var list = list_initial;
    var expression = expression_initial orelse {
        compiler_ownership.deleteIdentifierList(db, columns);
        return list;
    };
    const first_index: c_int = if (list) |present| present.nExpr else 0;
    if (expression.op != tokens.tk_select and columns.nId != expression_analysis.vectorSize(expression)) {
        var buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{d} columns assigned {d} values", .{ columns.nId, expression_analysis.vectorSize(expression) }) catch "column/value count mismatch";
        setParseError(parse, message);
        compiler_ownership.deleteExpression(db, expression);
        compiler_ownership.deleteIdentifierList(db, columns);
        return list;
    }
    for (columns.items(), 0..) |*column, index| {
        const child = expressionForVectorField(parse, expression, @intCast(index), columns.nId) orelse continue;
        list = expression_analysis.appendExpressionList(parse, list, child);
        if (list) |present| {
            present.items()[@intCast(present.nExpr - 1)].zEName = column.zName;
            column.zName = null;
        }
    }
    if (db.mallocFailed == 0 and expression.op == tokens.tk_select and list != null) {
        const first = list.?.items()[@intCast(first_index)].pExpr.?;
        first.pRight = expression;
        expression = undefined;
        first.iTable = columns.nId;
        compiler_ownership.deleteIdentifierList(db, columns);
        return list;
    }
    compiler_ownership.deleteExpression(db, expression);
    compiler_ownership.deleteIdentifierList(db, columns);
    return list;
}

/// Source `sqlite3ExprListToValues()`.
pub fn expressionListToValues(parse: *parse_types.Parse, element_count: c_int, expression_list: *parse_types.ExprList) ?*parse_types.Select {
    var result: ?*parse_types.Select = null;
    for (expression_list.items()) |item| {
        const expression = item.pExpr.?;
        const actual_count: c_int = if (expression.op == tokens.tk_vector) expression.x.pList.?.nExpr else 1;
        if (actual_count != element_count) {
            var buffer: [128]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "IN(...) element has {d} term{s} - expected {d}", .{ actual_count, if (actual_count > 1) "s" else "", element_count }) catch "IN(...) element has wrong number of terms";
            setParseError(parse, message);
            break;
        }
        const select = newSelect(parse, expression.x.pList, null, null, null, null, null, parse_types.select_flag.values, null);
        expression.x.pList = null;
        if (select) |present| {
            if (result) |prior| {
                present.op = @intCast(tokens.tk_all);
                present.pPrior = prior;
            }
            result = present;
        }
    }
    if (result != null and result.?.pPrior != null) result.?.selFlags |= 0x0000_0400;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    compiler_ownership.deleteExpressionList(db, expression_list);
    return result;
}

/// Source `sqlite3WindowChain()`.
pub fn chainWindow(parse: *parse_types.Parse, window: *parse_types.Window, list: ?*parse_types.Window) void {
    const base_name = window.base_name orelse return;
    const existing = @import("window_functions.zig").findWindow(parse, list, base_name) orelse return;
    const error_clause: ?[]const u8 = if (window.partition_by != null)
        "PARTITION clause"
    else if (existing.order_by != null and window.order_by != null)
        "ORDER BY clause"
    else if (existing.implicit_frame == 0)
        "frame specification"
    else
        null;
    if (error_clause) |clause| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "cannot override {s} of window: {s}", .{ clause, base_name }) catch "cannot override window";
        setParseError(parse, message);
    } else {
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        window.partition_by = ast_duplication.duplicateExpressionList(db, existing.partition_by, false);
        if (existing.order_by != null) window.order_by = ast_duplication.duplicateExpressionList(db, existing.order_by, false);
        db_allocator.freeNN(db, base_name);
        window.base_name = null;
    }
}

/// Source `sqlite3WithPush()`.
pub fn pushWith(parse: *parse_types.Parse, with_initial: ?*parse_types.With, free_with_parse: bool) ?*parse_types.With {
    var with = with_initial orelse return null;
    if (free_with_parse) with = if (parse_cleanup.add(parse, cte_analysis.deleteWithCallback, with)) |present| @ptrCast(@alignCast(present)) else return null;
    if (parse.nErr == 0) {
        with.pOuter = parse.pWith;
        parse.pWith = with;
    }
    return with;
}

/// Source `searchWith()`.
pub fn searchWith(with_initial: ?*parse_types.With, source: *parse_types.SrcItem, context: **parse_types.With) ?*parse_types.Cte {
    var with = with_initial;
    while (with) |present| : (with = present.pOuter) {
        for (present.items()) |*cte| {
            if (sqlite_string.compareInternal(source.zName.?, cte.zName.?) == 0) {
                context.* = present;
                return cte;
            }
        }
        if (present.bView != 0) break;
    }
    return null;
}

/// Source `cannotBeFunction()`.
pub fn cannotBeFunction(parse: *parse_types.Parse, source: *parse_types.SrcItem) bool {
    if (!source.fg.isTabFunc) return false;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "'{s}' is not a function", .{source.zName.?}) catch "table is not a function";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
    return true;
}

/// Source `hasAnchor()`.
pub fn hasAnchor(select_initial: ?*parse_types.Select) bool {
    var select = select_initial;
    while (select != null and select.?.selFlags & parse_types.select_flag.recursive != 0) select = select.?.pPrior;
    return select != null;
}

/// Source `sqlite3GetVdbe()`.
pub fn getMachine(parse: *parse_types.Parse) ?*vdbe_types.Vdbe {
    if (parse.pVdbe) |existing| return @ptrCast(@alignCast(existing));
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (parse.pToplevel == null and vdbe_types.optimizationEnabled(db, vdbe_types.optimization.factor_out_constants)) parse.flags0 |= 0x80;
    return vdbe_aux.create(parse);
}

/// Source `sqlite3SelectDestInit()`.
pub fn initializeDestination(destination: *SelectDestination, kind: c_int, parameter: c_int) void {
    destination.* = .{ .destination = @intCast(kind), .parameter = parameter, .parameter_2 = 0, .result_register = 0, .result_count = 0, .affinity = null, .order_by = null };
}

fn sourceListAllocationSize(capacity: usize) usize {
    return @offsetOf(parse_types.SrcList, "a") + capacity * @sizeOf(parse_types.SrcItem);
}

/// Source `sqlite3SrcListEnlarge()`.
pub fn enlargeSourceList(parse: *parse_types.Parse, sources_initial: *parse_types.SrcList, extra_count: c_int, start: c_int) ?*parse_types.SrcList {
    var sources = sources_initial;
    if (@as(u32, @intCast(sources.nSrc + extra_count)) > sources.nAlloc) {
        var capacity: i64 = 2 * @as(i64, sources.nSrc) + extra_count;
        if (sources.nSrc + extra_count >= 200) {
            const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
            const message = "too many FROM clause terms, max: 200";
            db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
            parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
            parse.nErr += 1;
            parse.rc = 1;
            return null;
        }
        if (capacity > 200) capacity = 200;
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        const raw = db_allocator.realloc(db, sources, sourceListAllocationSize(@intCast(capacity))) orelse return null;
        sources = @ptrCast(@alignCast(raw));
        sources.nAlloc = @intCast(capacity);
    }
    var index: isize = sources.nSrc - 1;
    while (index >= start) : (index -= 1) sources.items()[@intCast(index + extra_count)] = sources.items()[@intCast(index)];
    sources.nSrc += extra_count;
    @memset(sources.items()[@intCast(start)..@intCast(start + extra_count)], std.mem.zeroes(parse_types.SrcItem));
    for (sources.items()[@intCast(start)..@intCast(start + extra_count)]) |*source| source.iCursor = -1;
    return sources;
}

/// Source `sqlite3SrcListAppend()`.
pub fn appendSourceList(parse: *parse_types.Parse, sources_optional: ?*parse_types.SrcList, table: ?*const parse_types.Token, database_initial: ?*const parse_types.Token) ?*parse_types.SrcList {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var sources = if (sources_optional) |present| enlargeSourceList(parse, present, 1, present.nSrc) orelse {
        compiler_ownership.deleteSourceList(db, present);
        return null;
    } else blk: {
        const raw = db_allocator.mallocRawNN(db, sourceListAllocationSize(1)) orelse return null;
        const created: *parse_types.SrcList = @ptrCast(@alignCast(raw));
        created.nAlloc = 1;
        created.nSrc = 1;
        created.items()[0] = std.mem.zeroes(parse_types.SrcItem);
        created.items()[0].iCursor = -1;
        break :blk created;
    };
    var database = database_initial;
    if (database != null and database.?.z == null) database = null;
    const source = &sources.items()[@intCast(sources.nSrc - 1)];
    if (database) |present| {
        source.zName = schema_analysis.nameFromToken(db, present);
        source.u4.zDatabase = schema_analysis.nameFromToken(db, table);
    } else {
        source.zName = schema_analysis.nameFromToken(db, table);
        source.u4.zDatabase = null;
    }
    return sources;
}

/// Source `lockTable()`.
pub fn recordTableLock(parse_initial: *parse_types.Parse, database_index: c_int, root_page: u32, write_lock: bool, name: [*:0]const u8) void {
    const parse = parse_initial.pToplevel orelse parse_initial;
    if (parse.aTableLock) |locks| {
        for (locks[0..@intCast(parse.nTableLock)]) |*lock| {
            if (lock.database_index == database_index and lock.root_page == root_page) {
                lock.write_lock = @intFromBool(lock.write_lock != 0 or write_lock);
                return;
            }
        }
    }
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const byte_count: u64 = @intCast(@sizeOf(parse_types.TableLock) * @as(usize, @intCast(parse.nTableLock + 1)));
    const raw = db_allocator.reallocOrFree(db, if (parse.aTableLock) |locks| @ptrCast(locks) else null, byte_count);
    parse.aTableLock = if (raw) |present| @ptrCast(@alignCast(present)) else null;
    if (parse.aTableLock) |locks| {
        locks[@intCast(parse.nTableLock)] = .{
            .database_index = database_index,
            .root_page = root_page,
            .write_lock = @intFromBool(write_lock),
            .name = name,
        };
        parse.nTableLock += 1;
    } else {
        parse.nTableLock = 0;
        _ = db_allocator.oomFault(db);
    }
}

/// Source `sqlite3SrcListAssignCursors()`.
pub fn assignSourceCursors(parse: *parse_types.Parse, sources_optional: ?*parse_types.SrcList) void {
    const sources = sources_optional orelse return;
    for (sources.items()) |*source| {
        if (source.iCursor >= 0) continue;
        source.iCursor = parse.nTab;
        parse.nTab += 1;
        if (source.fg.isSubquery) assignSourceCursors(parse, source.u4.pSubq.?.pSelect.?.pSrc);
    }
}

/// Source `sqlite3SubqueryDetach()`.
pub fn detachSubquery(db: *vdbe_types.Sqlite3, source: *parse_types.SrcItem) *parse_types.Select {
    const subquery = source.u4.pSubq.?;
    const select = subquery.pSelect.?;
    db_allocator.free(db, subquery);
    source.u4.pSubq = null;
    source.fg.isSubquery = false;
    return select;
}

/// Source `sqlite3SrcListIndexedBy()`.
pub fn setSourceIndexedBy(parse: *parse_types.Parse, sources_optional: ?*parse_types.SrcList, indexed_by: *const parse_types.Token) void {
    const sources = sources_optional orelse return;
    if (indexed_by.n == 0) return;
    const source = &sources.items()[@intCast(sources.nSrc - 1)];
    if (indexed_by.n == 1 and indexed_by.z == null) {
        source.fg.notIndexed = true;
    } else {
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        source.u1.zIndexedBy = schema_analysis.nameFromToken(db, indexed_by);
        source.fg.isIndexedBy = true;
    }
}

/// Source `sqlite3SrcListAppendList()`.
pub fn appendSourceLists(parse: *parse_types.Parse, first_initial: *parse_types.SrcList, second_optional: ?*parse_types.SrcList) ?*parse_types.SrcList {
    var first = first_initial;
    const second = second_optional orelse return first;
    const old_count = first.nSrc;
    first = enlargeSourceList(parse, first, second.nSrc, old_count) orelse {
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        compiler_ownership.deleteSourceList(db, second);
        return null;
    };
    @memcpy(first.items()[@intCast(old_count)..@intCast(old_count + second.nSrc)], second.items());
    first.items()[0].fg.jointype |= second.items()[0].fg.jointype & 0x40;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.freeNN(db, second);
    return first;
}

/// Source `sqlite3SrcListFuncArgs()`.
pub fn setSourceFunctionArguments(parse: *parse_types.Parse, sources_optional: ?*parse_types.SrcList, arguments: ?*parse_types.ExprList) void {
    if (sources_optional) |sources| {
        const source = &sources.items()[@intCast(sources.nSrc - 1)];
        source.u1.pFuncArg = arguments;
        source.fg.isTabFunc = true;
    } else {
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        compiler_ownership.deleteExpressionList(db, arguments);
    }
}

/// Source `sqlite3SrcListShiftJoinType()`.
pub fn shiftSourceJoinTypes(_: *parse_types.Parse, sources_optional: ?*parse_types.SrcList) void {
    const sources = sources_optional orelse return;
    if (sources.nSrc <= 1) return;
    var index: usize = @intCast(sources.nSrc - 1);
    var all_flags: u8 = 0;
    while (index > 0) : (index -= 1) {
        sources.items()[index].fg.jointype = sources.items()[index - 1].fg.jointype;
        all_flags |= sources.items()[index].fg.jointype;
    }
    sources.items()[0].fg.jointype = 0;
    if (all_flags & 0x10 != 0) {
        index = @intCast(sources.nSrc - 1);
        while (index > 0 and sources.items()[index].fg.jointype & 0x10 == 0) index -= 1;
        index -= 1;
        while (true) {
            sources.items()[index].fg.jointype |= 0x40;
            if (index == 0) break;
            index -= 1;
        }
    }
}

/// Source `sqlite3SrcItemColumnUsed()`.
pub fn markSourceColumnUsed(source: *parse_types.SrcItem, column: c_int) void {
    if (!source.fg.isNestedFrom) return;
    const results = source.u4.pSubq.?.pSelect.?.pEList.?;
    results.items()[@intCast(column)].fg.bUsed = true;
}

/// Source `tableAndColumnIndex()`.
pub fn tableAndColumnIndex(
    sources: *parse_types.SrcList,
    start: c_int,
    end: c_int,
    name: [*:0]const u8,
    table_index: ?*c_int,
    column_index: ?*c_int,
    ignore_hidden: bool,
) bool {
    var index = start;
    while (index <= end) : (index += 1) {
        const source = &sources.items()[@intCast(index)];
        const column = schema_analysis.columnIndex(source.pSTab.?, name);
        if (column >= 0 and (!ignore_hidden or source.pSTab.?.columns.?[@intCast(column)].flags & 0x0002 == 0)) {
            if (table_index) |table_output| {
                markSourceColumnUsed(source, column);
                table_output.* = index;
                column_index.?.* = column;
            }
            return true;
        }
    }
    return false;
}

/// Source `sqlite3IdListAppend()`.
pub fn appendIdentifier(parse: *parse_types.Parse, list_optional: ?*parse_types.IdList, token: *const parse_types.Token) ?*parse_types.IdList {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const old_count: usize = if (list_optional) |list| @intCast(list.nId) else 0;
    const byte_count = @offsetOf(parse_types.IdList, "a") + (old_count + 1) * @sizeOf(parse_types.IdListItem);
    const raw = if (list_optional) |list| db_allocator.realloc(db, list, byte_count) else db_allocator.mallocZero(db, byte_count);
    const list: *parse_types.IdList = if (raw) |present| @ptrCast(@alignCast(present)) else {
        compiler_ownership.deleteIdentifierList(db, list_optional);
        return null;
    };
    list.nId += 1;
    list.items()[old_count].zName = schema_analysis.nameFromToken(db, token);
    if (parse.eParseMode >= 2 and list.items()[old_count].zName != null) _ = rename_analysis.mapToken(parse, list.items()[old_count].zName, token);
    return list;
}

/// Source `sqlite3IdListIndex()`.
pub fn identifierListIndex(list: *parse_types.IdList, name: [*:0]const u8) c_int {
    for (list.items(), 0..) |item, index| if (sqlite_string.compareInternal(item.zName.?, name) == 0) return @intCast(index);
    return -1;
}

/// Source `recomputeColumnsUsedExpr()`.
pub fn recomputeColumnsUsedExpression(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    if (expression_node.op != tokens.tk_column or expression_node.iColumn < 0) return walker_api.continue_walk;
    const source: *parse_types.SrcItem = @ptrCast(@alignCast(walker.u.pointer.?));
    if (source.iCursor == expression_node.iTable) source.colUsed |= @as(u64, 1) << @intCast(@min(expression_node.iColumn, 63));
    return walker_api.continue_walk;
}

/// Source `recomputeColumnsUsed()`.
pub fn recomputeColumnsUsed(select: *parse_types.Select, source: *parse_types.SrcItem) void {
    if (source.pSTab == null) return;
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = recomputeColumnsUsedExpression;
    walker.xSelectCallback = walker_api.selectNoop;
    walker.u.pointer = source;
    source.colUsed = 0;
    _ = walker_api.walkSelect(&walker, select);
}

/// Source `srclistRenumberCursors()`.
pub fn renumberSourceCursors(parse: *parse_types.Parse, cursor_map: [*]c_int, sources: *parse_types.SrcList, except: c_int) void {
    for (sources.items(), 0..) |*source, index| {
        if (@as(c_int, @intCast(index)) == except) continue;
        const old_cursor = source.iCursor;
        if (!source.fg.isRecursive or cursor_map[@intCast(old_cursor + 1)] == 0) {
            cursor_map[@intCast(old_cursor + 1)] = parse.nTab;
            parse.nTab += 1;
        }
        source.iCursor = cursor_map[@intCast(old_cursor + 1)];
        if (source.fg.isSubquery) {
            var arm: ?*parse_types.Select = source.u4.pSubq.?.pSelect;
            while (arm) |present| : (arm = present.pPrior) renumberSourceCursors(parse, cursor_map, present.pSrc.?, -1);
        }
    }
}

/// Source `renumberCursorDoMapping()`.
pub fn renumberCursorMapping(walker: *parse_types.Walker, cursor: *c_int) void {
    const cursor_map: [*]c_int = @ptrCast(@alignCast(walker.u.pointer.?));
    if (cursor.* < cursor_map[0] and cursor_map[@intCast(cursor.* + 1)] > 0) cursor.* = cursor_map[@intCast(cursor.* + 1)];
}

/// Source `renumberCursorsCb()`.
pub fn renumberCursorsCallback(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    if (expression_node.op == tokens.tk_column or expression_node.op == tokens.tk_if_null_row) renumberCursorMapping(walker, &expression_node.iTable);
    if (expression_node.flags & 0x0000_0001 != 0) renumberCursorMapping(walker, &expression_node.w.iJoin);
    return walker_api.continue_walk;
}

/// Source `renumberCursors()`.
pub fn renumberCursors(parse: *parse_types.Parse, select: *parse_types.Select, except: c_int, cursor_map: [*]c_int) void {
    renumberSourceCursors(parse, cursor_map, select.pSrc.?, except);
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.u.pointer = @ptrCast(cursor_map);
    walker.xExprCallback = renumberCursorsCallback;
    walker.xSelectCallback = walker_api.selectNoop;
    _ = walker_api.walkSelect(&walker, select);
}

/// Source `sqlite3SetJoinExpr()`.
pub fn setJoinExpression(expression_initial: ?*parse_types.Expr, table_cursor: c_int, join_flag: u32) void {
    var expression = expression_initial;
    while (expression) |present| : (expression = present.pRight) {
        present.flags |= join_flag;
        present.w.iJoin = table_cursor;
        if (present.usesList()) if (present.x.pList) |list| for (list.items()) |item| setJoinExpression(item.pExpr, table_cursor, join_flag);
        setJoinExpression(present.pLeft, table_cursor, join_flag);
    }
}

/// Source `unsetJoinExpr()`.
pub fn unsetJoinExpression(expression_initial: ?*parse_types.Expr, table_cursor: c_int, nullable: bool) void {
    var expression = expression_initial;
    while (expression) |present| : (expression = present.pRight) {
        if (table_cursor < 0 or (present.flags & 0x0000_0001 != 0 and present.w.iJoin == table_cursor)) {
            present.flags &= ~@as(u32, 0x0000_0003);
            if (table_cursor >= 0) present.flags |= 0x0000_0002;
        }
        if (present.op == tokens.tk_column and present.iTable == table_cursor and !nullable) present.flags &= ~@as(u32, 0x0020_0000);
        if (present.op == tokens.tk_function) if (present.x.pList) |list| for (list.items()) |item| unsetJoinExpression(item.pExpr, table_cursor, nullable);
        unsetJoinExpression(present.pLeft, table_cursor, nullable);
    }
}

/// Source `multiSelectByMergeKeyInfo()`.
pub fn compoundMergeKeyInfo(parse: *parse_types.Parse, select: *parse_types.Select, extra_fields: c_int) ?*vdbe_types.KeyInfo {
    const order_by = select.pOrderBy;
    const order_count: c_int = if (order_by) |list| list.nExpr else 0;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const info = allocateKeyInfo(db, order_count + extra_fields, 1) orelse return null;
    const collations: [*]?*vdbe_types.CollSeq = @ptrFromInt(@intFromPtr(info) + @offsetOf(vdbe_types.KeyInfo, "aColl"));
    if (order_by) |list| {
        for (list.items(), 0..) |*item, index| {
            const collation = if (item.pExpr.?.flags & 0x0000_0200 != 0)
                expression_analysis.expressionCollation(parse, item.pExpr.?)
            else
                compoundSelectCollation(parse, select, @as(c_int, item.u.x.iOrderByCol) - 1) orelse db.pDfltColl;
            if (item.pExpr.?.flags & 0x0000_0200 == 0) {
                var token = parse_types.Token{ .z = collation.?.zName, .n = @intCast(std.mem.len(collation.?.zName.?)) };
                item.pExpr = expression_analysis.addCollationToken(parse, item.pExpr.?, &token, false);
            }
            collations[index] = collation;
            info.aSortFlags.?[index] = item.fg.sortFlags;
        }
    }
    return info;
}

/// Source `multiSelectCollSeq()`.
pub fn compoundSelectCollation(parse: *parse_types.Parse, select: *parse_types.Select, column: c_int) ?*vdbe_types.CollSeq {
    var result: ?*vdbe_types.CollSeq = if (select.pPrior) |prior| compoundSelectCollation(parse, prior, column) else null;
    if (result == null and column < select.pEList.?.nExpr) result = expression_analysis.expressionCollation(parse, select.pEList.?.items()[@intCast(column)].pExpr.?);
    return result;
}

/// Source `findLeftmostExprlist()`.
pub fn findLeftmostExpressionList(select_initial: *parse_types.Select) *parse_types.ExprList {
    var select = select_initial;
    while (select.pPrior) |prior| select = prior;
    return select.pEList.?;
}

/// Source `compoundHasDifferentAffinities()`.
pub fn compoundHasDifferentAffinities(select: *parse_types.Select) bool {
    const list = select.pEList.?;
    for (list.items(), 0..) |item, index| {
        const affinity = expression_analysis.expressionAffinity(item.pExpr.?);
        var prior = select.pPrior;
        while (prior) |arm| : (prior = arm.pPrior) {
            if (expression_analysis.expressionAffinity(arm.pEList.?.items()[index].pExpr.?) != affinity) return true;
        }
    }
    return false;
}

/// Source `inAnyUsingClause()`.
pub fn inAnyUsingClause(name: [*:0]const u8, base: [*]parse_types.SrcItem, count_initial: c_int) bool {
    var count = count_initial;
    var position: usize = 1;
    while (count > 0) : ({
        count -= 1;
        position += 1;
    }) {
        const source = &base[position];
        if (source.fg.isUsing and source.u3.pUsing != null and identifierListIndex(source.u3.pUsing.?, name) >= 0) return true;
    }
    return false;
}

fn optionalNameEqual(left: ?[*:0]const u8, right: ?[*:0]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return sqlite_string.compareInternal(left.?, right.?) == 0;
}

/// Source `fromClauseTermCanBeCoroutine()`.
pub fn sourceCanUseCoroutine(parse: *parse_types.Parse, sources: *parse_types.SrcList, source_index_initial: c_int, select_flags: u32) bool {
    var source_index = source_index_initial;
    var source = &sources.items()[@intCast(source_index)];
    if (source.fg.isCte) {
        const use = source.u2.pCteUse.?;
        if (use.materialization == 0 or (use.use_count >= 2 and use.materialization != 2)) return false;
    }
    if (sources.items()[0].fg.jointype & 0x40 != 0) return false;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (!vdbe_types.optimizationEnabled(db, vdbe_types.optimization.coroutines)) return false;
    if (selfJoinView(sources, source, source_index + 1, sources.nSrc) != null) return false;
    if (source_index == 0) {
        if (sources.nSrc == 1 or sources.items()[1].fg.jointype & 0x02 != 0) return true;
        return select_flags & 0x1000_0000 == 0;
    }
    if (select_flags & 0x1000_0000 != 0) return false;
    while (true) {
        if (source.fg.jointype & 0x22 != 0) return false;
        if (source_index == 0) break;
        source_index -= 1;
        source = &sources.items()[@intCast(source_index)];
        if (source.fg.isSubquery) return false;
    }
    return true;
}

/// Source `isSelfJoinView()`.
pub fn selfJoinView(sources: *parse_types.SrcList, target: *parse_types.SrcItem, start: c_int, end: c_int) ?*parse_types.SrcItem {
    const target_select = target.u4.pSubq.?.pSelect.?;
    if (target_select.selFlags & 0x0100_0000 != 0) return null;
    for (sources.items()[@intCast(start)..@intCast(end)]) |*source| {
        if (!source.fg.isSubquery or source.fg.viaCoroutine or source.zName == null) continue;
        if (source.pSTab.?.schema != target.pSTab.?.schema) continue;
        if (sqlite_string.compareInternal(source.zName.?, target.zName.?) != 0) continue;
        const source_select = source.u4.pSubq.?.pSelect.?;
        if (source.pSTab.?.schema == null and target_select.selId != source_select.selId) continue;
        if (source_select.selFlags & 0x0100_0000 != 0) continue;
        return source;
    }
    return null;
}

/// Source `sameSrcAlias()`.
pub fn sameSourceAlias(target: *parse_types.SrcItem, sources: *parse_types.SrcList) bool {
    for (sources.items()) |*source| {
        if (source == target) continue;
        if (target.pSTab == source.pSTab and optionalNameEqual(target.zAlias, source.zAlias)) return true;
        if (source.fg.isSubquery and source.u4.pSubq.?.pSelect.?.selFlags & 0x0000_0800 != 0 and sameSourceAlias(target, source.u4.pSubq.?.pSelect.?.pSrc.?)) return true;
    }
    return false;
}

/// Source `sqlite3CopySortOrder()`.
pub fn copySortOrder(destination: *parse_types.ExprList, source_optional: ?*parse_types.ExprList) bool {
    const source = source_optional orelse return false;
    if (destination.nExpr != source.nExpr) return false;
    for (destination.items(), source.items()) |*destination_item, source_item| destination_item.fg.sortFlags = source_item.fg.sortFlags & 0x01;
    return true;
}

pub const WhereConstantContext = struct {
    parse: *parse_types.Parse,
    count: usize = 0,
    changes: c_int = 0,
    has_blob_affinity: bool = false,
    exclude_on: u32 = 0,
    expressions: ?[*]*parse_types.Expr = null,
};

/// Source `constInsert()`.
pub fn insertWhereConstant(context: *WhereConstantContext, column: *parse_types.Expr, value: *parse_types.Expr, equality: *parse_types.Expr) void {
    if (column.flags & 0x0000_0020 != 0 or expression_analysis.expressionAffinity(value) != 0) return;
    const comparison_collation = expression_analysis.expressionComparisonCollation(context.parse, equality) orelse return;
    if (!collation_analysis.isBinary(comparison_collation)) return;
    if (context.expressions) |expressions| {
        var index: usize = 0;
        while (index < context.count) : (index += 1) {
            const existing = expressions[index * 2];
            if (existing.iTable == column.iTable and existing.iColumn == column.iColumn) return;
        }
    }
    if (expression_analysis.expressionAffinity(column) <= schema_analysis.affinity.blob) context.has_blob_affinity = true;
    const old_count = context.count;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(context.parse.db.?));
    const old_pointer = if (context.expressions) |expressions| @as(?*anyopaque, @ptrCast(expressions)) else null;
    const raw = db_allocator.realloc(db, old_pointer, (old_count + 1) * 2 * @sizeOf(*parse_types.Expr)) orelse {
        db_allocator.free(db, old_pointer);
        context.expressions = null;
        context.count = 0;
        return;
    };
    context.expressions = @ptrCast(@alignCast(raw));
    context.expressions.?[old_count * 2] = column;
    context.expressions.?[old_count * 2 + 1] = value;
    context.count += 1;
}

/// Source `findConstInWhere()`.
pub fn findConstantsInWhere(context: *WhereConstantContext, expression: ?*parse_types.Expr) void {
    const present = expression orelse return;
    if (present.flags & context.exclude_on != 0) return;
    if (present.op == tokens.tk_and) {
        findConstantsInWhere(context, present.pRight);
        findConstantsInWhere(context, present.pLeft);
        return;
    }
    if (present.op != tokens.tk_eq) return;
    const right = present.pRight.?;
    const left = present.pLeft.?;
    if (right.op == tokens.tk_column and expression_analysis.isConstant(context.parse, left)) insertWhereConstant(context, right, left, present);
    if (left.op == tokens.tk_column and expression_analysis.isConstant(context.parse, right)) insertWhereConstant(context, left, right, present);
}

/// Source `propagateConstantExprRewriteOne()`.
pub fn rewriteOneConstant(context: *WhereConstantContext, expression: *parse_types.Expr, ignore_blob_affinity: bool) c_int {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(context.parse.db.?));
    if (db.mallocFailed != 0) return walker_api.prune;
    if (expression.op != tokens.tk_column) return walker_api.continue_walk;
    if (expression.flags & (0x0000_0020 | context.exclude_on) != 0) return walker_api.continue_walk;
    if (context.expressions) |expressions| {
        var index: usize = 0;
        while (index < context.count) : (index += 1) {
            const column = expressions[index * 2];
            if (column == expression or column.iTable != expression.iTable or column.iColumn != expression.iColumn) continue;
            if (ignore_blob_affinity and expression_analysis.expressionAffinity(column) <= schema_analysis.affinity.blob) break;
            context.changes += 1;
            expression.flags &= ~@as(u32, 0x0080_0000);
            expression.flags |= 0x0000_0020;
            expression.pLeft = ast_duplication.duplicateExpression(db, expressions[index * 2 + 1], false);
            break;
        }
    }
    return walker_api.prune;
}

/// Source `propagateConstantExprRewrite()`.
pub fn rewriteConstants(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    const context: *WhereConstantContext = @ptrCast(@alignCast(walker.u.pointer.?));
    if (context.has_blob_affinity and ((expression.op >= tokens.tk_eq and expression.op <= tokens.tk_ge) or expression.op == tokens.tk_is)) {
        _ = rewriteOneConstant(context, expression.pLeft.?, false);
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(context.parse.db.?));
        if (db.mallocFailed != 0) return walker_api.prune;
        if (expression_analysis.expressionAffinity(expression.pLeft.?) != schema_analysis.affinity.text) _ = rewriteOneConstant(context, expression.pRight.?, false);
    }
    return rewriteOneConstant(context, expression, context.has_blob_affinity);
}

/// Source `propagateConstants()`.
pub fn propagateConstants(parse: *parse_types.Parse, select: *parse_types.Select) c_int {
    var total_changes: c_int = 0;
    var changed: c_int = 0;
    while (true) {
        var context = WhereConstantContext{ .parse = parse };
        if (select.pSrc != null and select.pSrc.?.nSrc > 0 and select.pSrc.?.items()[0].fg.jointype & 0x40 != 0) context.exclude_on = 0x0000_0003 else context.exclude_on = 0x0000_0001;
        findConstantsInWhere(&context, select.pWhere);
        if (context.count != 0) {
            var walker = std.mem.zeroes(parse_types.Walker);
            walker.pParse = parse;
            walker.xExprCallback = rewriteConstants;
            walker.xSelectCallback = walker_api.selectNoop;
            walker.u.pointer = &context;
            _ = walker_api.walkExpr(&walker, select.pWhere);
            const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
            db_allocator.free(db, if (context.expressions) |expressions| @ptrCast(expressions) else null);
            total_changes += context.changes;
        }
        changed = context.changes;
        if (changed == 0) break;
    }
    return total_changes;
}

/// Source `pushDownWindowCheck()`.
pub fn pushDownWindowCheck(parse: *parse_types.Parse, subquery: *parse_types.Select, expression_node: *parse_types.Expr) bool {
    const window = subquery.pWin.?;
    std.debug.assert(window.partition_by != null);
    std.debug.assert(subquery.pPrior == null);
    return expression_analysis.isConstantOrGroupBy(parse, expression_node, window.partition_by.?);
}

/// Source `havingToWhereExprCb()`.
pub fn havingToWhereCallback(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    if (expression_node.op == tokens.tk_and) return walker_api.continue_walk;
    const select: *parse_types.Select = @ptrCast(@alignCast(walker.u.pointer.?));
    if (expression_analysis.isConstantOrGroupBy(walker.pParse.?, expression_node, select.pGroupBy.?) and
        expression_node.flags & 0x2000_0000 == 0 and expression_node.pAggInfo == null)
    {
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(walker.pParse.?.db.?));
        if (expression_analysis.integerExpression(db, 1)) |moved| {
            const where = select.pWhere;
            std.mem.swap(parse_types.Expr, moved, expression_node);
            select.pWhere = expression_analysis.andExpression(walker.pParse.?, where, moved);
            walker.eCode = 1;
        }
    }
    return walker_api.prune;
}

/// Source `havingToWhere()`.
pub fn havingToWhere(parse: *parse_types.Parse, select: *parse_types.Select) void {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.pParse = parse;
    walker.xExprCallback = havingToWhereCallback;
    walker.u.pointer = select;
    _ = walker_api.walkExpr(&walker, select.pHaving);
}

/// Source `sqlite3SelectWrongNumTermsError()`.
pub fn wrongNumberOfTermsError(parse: *parse_types.Parse, select: *parse_types.Select) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var buffer: [256]u8 = undefined;
    const message = if (select.selFlags & parse_types.select_flag.values != 0)
        "all VALUES must have the same number of terms"
    else
        std.fmt.bufPrint(&buffer, "SELECTs to the left and right of {s} do not have the same number of result columns", .{selectOperationName(select.op)}) catch "compound SELECTs have different numbers of result columns";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `sqlite3SelectOpName()`.
pub fn selectOperationName(operation: c_int) [*:0]const u8 {
    return switch (operation) {
        tokens.tk_all => "UNION ALL",
        tokens.tk_intersect => "INTERSECT",
        tokens.tk_except => "EXCEPT",
        else => "UNION",
    };
}

/// Source `sqlite3JoinType()`.
pub fn joinType(parse: *parse_types.Parse, first: ?*const parse_types.Token, second: ?*const parse_types.Token, third: ?*const parse_types.Token) u8 {
    const Keyword = struct { name: []const u8, mask: u8 };
    const keywords = [_]Keyword{
        .{ .name = "natural", .mask = 0x04 }, .{ .name = "left", .mask = 0x28 },
        .{ .name = "outer", .mask = 0x20 },   .{ .name = "right", .mask = 0x30 },
        .{ .name = "full", .mask = 0x38 },    .{ .name = "inner", .mask = 0x01 },
        .{ .name = "cross", .mask = 0x03 },
    };
    var result: u8 = 0;
    for ([_]?*const parse_types.Token{ first, second, third }) |token_optional| {
        const token = token_optional orelse continue;
        var found = false;
        for (keywords) |keyword| if (token.n == keyword.name.len and sqlite_string.compareN(token.z.?, keyword.name.ptr, @intCast(token.n)) == 0) {
            result |= keyword.mask;
            found = true;
            break;
        };
        if (!found) {
            result |= 0x80;
            break;
        }
    }
    if (result & 0x21 == 0x21 or result & 0x80 != 0 or result & 0x38 == 0x20) {
        setParseError(parse, "unknown join type");
        return 0x01;
    }
    return result;
}

/// Source `sqlite3ColumnsFromExprList()`.
pub fn columnsFromExpressionList(parse: *parse_types.Parse, list_optional: ?*parse_types.ExprList, column_count: *i16, columns: *?[*]schema.Column) c_int {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const list = list_optional orelse {
        column_count.* = 0;
        columns.* = null;
        return 0;
    };
    const count: usize = @min(@as(usize, @intCast(list.nExpr)), 32767);
    const raw = db_allocator.mallocZero(db, count * @sizeOf(schema.Column)) orelse {
        column_count.* = 0;
        columns.* = null;
        return 7;
    };
    const result: [*]schema.Column = @ptrCast(@alignCast(raw));
    column_count.* = @intCast(count);
    columns.* = result;
    for (list.items()[0..count], 0..) |item, index| {
        var name: ?[*:0]const u8 = null;
        if (item.zEName != null and item.fg.eEName == 0) {
            name = item.zEName;
        } else {
            var node = expression_analysis.skipCollationAndLikely(item.pExpr);
            while (node != null and node.?.op == tokens.tk_dot) node = node.?.pRight;
            if (node != null and node.?.op == tokens.tk_column and node.?.y.pTab != null) {
                var column = node.?.iColumn;
                if (column < 0) column = node.?.y.pTab.?.primary_key_column;
                name = if (column >= 0) node.?.y.pTab.?.columns.?[@intCast(column)].name_and_metadata else "rowid";
            } else if (node != null and node.?.op == tokens.tk_id) {
                name = node.?.u.zToken;
            } else name = item.zEName;
        }
        var generated: [128]u8 = undefined;
        const base = name orelse blk: {
            const text = std.fmt.bufPrintZ(&generated, "column{d}", .{index + 1}) catch "column";
            break :blk text.ptr;
        };
        var duplicate = db_allocator.stringDuplicate(db, base) orelse break;
        var suffix: u32 = 0;
        while (true) {
            var collision = false;
            for (result[0..index]) |prior| if (sqlite_string.compareInternal(prior.name_and_metadata.?, duplicate) == 0) {
                collision = true;
                if (item.fg.bUsingTerm) result[index].flags |= 0x0400;
                break;
            };
            if (!collision) break;
            suffix += 1;
            db_allocator.freeNN(db, duplicate);
            const base_span = std.mem.span(base);
            const text = std.fmt.bufPrintZ(&generated, "{s}:{d}", .{ base_span, suffix }) catch "column";
            duplicate = db_allocator.stringDuplicate(db, text.ptr) orelse break;
        }
        result[index].name_and_metadata = duplicate;
        result[index].name_hash = sqlite_string.insensitiveHash(duplicate);
        if (item.fg.bNoExpand) result[index].flags |= 0x0400;
    }
    if (parse.nErr == 0 and db.mallocFailed == 0) return 0;
    for (result[0..count]) |column| db_allocator.free(db, if (column.name_and_metadata) |name| @ptrCast(name) else null);
    db_allocator.freeNN(db, result);
    column_count.* = 0;
    columns.* = null;
    return if (parse.rc != 0) parse.rc else 7;
}

/// Source `sqlite3ExpandSubquery()`.
pub fn expandSubquery(parse: *parse_types.Parse, source: *parse_types.SrcItem) c_int {
    var select = source.u4.pSubq.?.pSelect.?;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocZero(db, @sizeOf(schema.Table)) orelse return 7;
    const table: *schema.Table = @ptrCast(@alignCast(raw));
    source.pSTab = table;
    table.reference_count = 1;
    table.name = db_allocator.stringDuplicate(db, source.zAlias orelse source.zName orelse "subquery");
    while (select.pPrior) |prior| {
        select = prior;
    }
    const rc = columnsFromExpressionList(parse, select.pEList, &table.column_count, &table.columns);
    table.primary_key_column = -1;
    table.kind = .view;
    table.row_log_estimate = 200;
    table.flags |= schema.table_flag.ephemeral | parse_types.table_flag.no_visible_rowid;
    return if (rc != 0 or parse.nErr != 0) if (rc != 0) rc else 1 else 0;
}

/// Source `disableUnusedSubqueryResultColumns()`.
pub fn disableUnusedSubqueryResultColumns(source: *parse_types.SrcItem) c_int {
    if (source.fg.isCorrelated or source.fg.isCte) return 0;
    const subquery = source.u4.pSubq.?.pSelect.?;
    var arm: ?*parse_types.Select = subquery;
    while (arm) |present| : (arm = present.pPrior) {
        if (present.selFlags & 0x0000_0009 != 0 or (present.pPrior != null and present.op != tokens.tk_all) or present.pWin != null) return 0;
    }
    var used = source.colUsed;
    if (subquery.pOrderBy) |order_by| for (order_by.items()) |item| if (item.u.x.iOrderByCol > 0) {
        const column = item.u.x.iOrderByCol - 1;
        used |= @as(u64, 1) << @intCast(@min(column, 63));
    };
    var changed: c_int = 0;
    for (0..@intCast(source.pSTab.?.column_count)) |column| {
        if (used & (@as(u64, 1) << @intCast(@min(column, 63))) != 0) continue;
        arm = subquery;
        while (arm) |present| : (arm = present.pPrior) {
            const node = present.pEList.?.items()[column].pExpr.?;
            if (node.op == tokens.tk_null) continue;
            node.op = @intCast(tokens.tk_null);
            node.flags &= ~@as(u32, 0x0008_2000);
            present.selFlags |= 0x0100_0000;
            changed += 1;
        }
    }
    return changed;
}

fn selectDeleteCallback(db_opaque: ?*parse_types.Sqlite3, pointer: ?*anyopaque) callconv(.c) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(db_opaque.?));
    compiler_ownership.deleteSelect(db, if (pointer) |present| @ptrCast(@alignCast(present)) else null);
}

/// Source `existsToJoin()`.
pub fn convertExistsToJoin(parse: *parse_types.Parse, select: *parse_types.Select, where_optional: ?*parse_types.Expr) void {
    const where = where_optional orelse return;
    if (parse.nErr != 0 or where.flags & 0x0000_0003 != 0 or select.pSrc == null or select.pSrc.?.nSrc >= 64 or (select.pLimit != null and select.pLimit.?.pRight != null)) return;
    if (where.op == tokens.tk_and) {
        const right = where.pRight;
        convertExistsToJoin(parse, select, where.pLeft);
        convertExistsToJoin(parse, select, right);
        return;
    }
    if (where.op != tokens.tk_exists) return;
    const subquery = where.x.pSelect.?;
    const sub_where = subquery.pWhere;
    if (subquery.pSrc.?.nSrc != 1 or subquery.selFlags & 0x0000_0008 != 0 or subquery.pSrc.?.items()[0].fg.isSubquery or subquery.pLimit != null or subquery.pPrior != null) return;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const map_raw = db_allocator.mallocZero(db, @as(usize, @intCast(parse.nTab + 2)) * @sizeOf(c_int)) orelse return;
    const cursor_map: [*]c_int = @ptrCast(@alignCast(map_raw));
    cursor_map[0] = parse.nTab + 1;
    renumberCursors(parse, subquery, -1, cursor_map);
    db_allocator.freeNN(db, cursor_map);
    where.* = std.mem.zeroes(parse_types.Expr);
    where.op = @intCast(tokens.tk_integer);
    where.u.iValue = 1;
    where.flags = 0x0000_0800;
    subquery.pSrc.?.items()[0].fg.fromExists = true;
    select.pSrc = appendSourceLists(parse, select.pSrc.?, subquery.pSrc);
    if (sub_where != null) {
        select.pWhere = expression_analysis.andExpression(parse, select.pWhere, sub_where);
        subquery.pWhere = null;
    }
    subquery.pSrc = null;
    _ = parse_cleanup.add(parse, selectDeleteCallback, subquery);
}

pub const SubstitutionContext = struct {
    parse: *parse_types.Parse,
    table_cursor: c_int,
    new_table_cursor: c_int,
    outer_join: bool,
    select_depth: c_int = 0,
    expressions: *parse_types.ExprList,
    collations: *parse_types.ExprList,
};

/// Source `substExpr()`.
pub fn substituteExpression(context: *SubstitutionContext, expression_optional: ?*parse_types.Expr) ?*parse_types.Expr {
    var node = expression_optional orelse return null;
    if (node.flags & 0x0000_0003 != 0 and node.w.iJoin == context.table_cursor) node.w.iJoin = context.new_table_cursor;
    if (node.op == tokens.tk_column and node.iTable == context.table_cursor and node.flags & 0x0000_0020 == 0) {
        if (node.iColumn < 0) {
            node.op = @intCast(tokens.tk_null);
            return node;
        }
        const position: usize = @intCast(node.iColumn);
        var source = context.expressions.items()[position].pExpr.?;
        if (expression_analysis.vectorSize(source) > 1) {
            var buffer: [96]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "row value misused", .{}) catch "row value misused";
            setParseError(context.parse, message);
            return node;
        }
        var null_wrapper = std.mem.zeroes(parse_types.Expr);
        if (context.outer_join and (source.op != tokens.tk_column or source.iTable != context.new_table_cursor)) {
            null_wrapper.op = @intCast(tokens.tk_if_null_row);
            null_wrapper.pLeft = source;
            null_wrapper.iTable = context.new_table_cursor;
            null_wrapper.iColumn = -99;
            null_wrapper.flags = 0x0080_0000;
            source = &null_wrapper;
        }
        const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(context.parse.db.?));
        var replacement = ast_duplication.duplicateExpression(db, source, false) orelse return node;
        if (context.outer_join) replacement.flags |= 0x0000_4000;
        if (replacement.op == tokens.tk_truefalse) {
            replacement.u.iValue = @intFromBool(expression_analysis.truthValue(replacement));
            replacement.op = @intCast(tokens.tk_integer);
            replacement.flags |= 0x0000_0800;
        }
        const natural = expression_analysis.expressionCollation(context.parse, replacement);
        const wanted = expression_analysis.expressionCollation(context.parse, context.collations.items()[position].pExpr.?);
        if (natural != wanted or (replacement.op != tokens.tk_column and replacement.op != tokens.tk_collate)) {
            var token = parse_types.Token{ .z = (if (wanted) |collation| collation.zName.? else "BINARY"), .n = @intCast(std.mem.len(if (wanted) |collation| collation.zName.? else "BINARY")) };
            replacement = expression_analysis.addCollationToken(context.parse, replacement, &token, false);
        }
        replacement.flags &= ~@as(u32, 0x0000_0200);
        if (node.flags & 0x0000_0003 != 0) {
            replacement.flags |= node.flags & 0x0000_0003;
            replacement.w.iJoin = node.w.iJoin;
        }
        compiler_ownership.deleteExpression(db, node);
        return replacement;
    }
    if (node.op == tokens.tk_if_null_row and node.iTable == context.table_cursor) node.iTable = context.new_table_cursor;
    if (node.op == tokens.tk_agg_function and node.op2 >= context.select_depth) node.op2 -= 1;
    node.pLeft = substituteExpression(context, node.pLeft);
    node.pRight = substituteExpression(context, node.pRight);
    if (node.usesSelect()) substituteSelect(context, node.x.pSelect, true) else substituteExpressionList(context, node.x.pList);
    if (node.flags & parse_types.expr_flag.win_func != 0) {
        const window = node.y.pWin.?;
        window.filter = substituteExpression(context, window.filter);
        substituteExpressionList(context, window.partition_by);
        substituteExpressionList(context, window.order_by);
    }
    return node;
}

/// Source `substExprList()`.
pub fn substituteExpressionList(context: *SubstitutionContext, list_optional: ?*parse_types.ExprList) void {
    const list = list_optional orelse return;
    for (list.items()) |*item| item.pExpr = substituteExpression(context, item.pExpr);
}

/// Source `substSelect()`.
pub fn substituteSelect(context: *SubstitutionContext, select_optional: ?*parse_types.Select, include_prior: bool) void {
    var select = select_optional orelse return;
    context.select_depth += 1;
    defer context.select_depth -= 1;
    while (true) {
        substituteExpressionList(context, select.pEList);
        substituteExpressionList(context, select.pGroupBy);
        substituteExpressionList(context, select.pOrderBy);
        select.pHaving = substituteExpression(context, select.pHaving);
        select.pWhere = substituteExpression(context, select.pWhere);
        for (select.pSrc.?.items()) |*source| {
            if (source.fg.isSubquery) substituteSelect(context, source.u4.pSubq.?.pSelect, true);
            if (source.fg.isTabFunc) substituteExpressionList(context, source.u1.pFuncArg);
        }
        if (!include_prior or select.pPrior == null) break;
        select = select.pPrior.?;
    }
}

/// Source `convertCompoundSelectToSubquery()`.
pub fn convertCompoundSelectToSubquery(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    if (select.pPrior == null or select.pOrderBy == null) return walker_api.continue_walk;
    var arm: ?*parse_types.Select = select;
    while (arm != null and (arm.?.op == tokens.tk_all or arm.?.op == tokens.tk_select)) arm = arm.?.pPrior;
    if (arm == null or select.pOrderBy.?.items()[0].u.x.iOrderByCol != 0) return walker_api.continue_walk;
    var has_collation = false;
    for (select.pOrderBy.?.items()) |item| if (item.pExpr.?.flags & 0x0000_0200 != 0) {
        has_collation = true;
        break;
    };
    if (!has_collation) return walker_api.continue_walk;
    const parse = walker.pParse.?;
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocZero(db, @sizeOf(parse_types.Select)) orelse return walker_api.abort_walk;
    const inner: *parse_types.Select = @ptrCast(@alignCast(raw));
    var dummy = parse_types.Token{ .z = null, .n = 0 };
    const sources = appendSourceFromTerm(parse, null, null, null, &dummy, inner, null) orelse return walker_api.abort_walk;
    inner.* = select.*;
    select.pSrc = sources;
    select.pEList = expression_analysis.appendExpressionList(parse, null, expression_analysis.newExpression(db, @intCast(tokens.tk_asterisk), null));
    select.op = @intCast(tokens.tk_select);
    select.pWhere = null;
    inner.pGroupBy = null;
    inner.pHaving = null;
    inner.pOrderBy = null;
    select.pPrior = null;
    select.pNext = null;
    select.pWith = null;
    select.pWinDefn = null;
    select.selFlags &= ~@as(u32, 0x0000_0100);
    select.selFlags |= 0x0008_0000;
    inner.pPrior.?.pNext = inner;
    inner.pLimit = null;
    return walker_api.continue_walk;
}

/// Source `columnTypeImpl()`.
pub fn expressionColumnType(context_initial: ?*resolve_analysis.NameContext, expression_node: *parse_types.Expr) ?[*:0]const u8 {
    var context = context_initial;
    switch (expression_node.op) {
        tokens.tk_column => {
            while (context) |present| : (context = present.next) {
                const sources = present.sources orelse continue;
                for (sources.items()) |source| {
                    if (source.iCursor != expression_node.iTable) continue;
                    const table = source.pSTab.?;
                    const column = expression_node.iColumn;
                    if (source.fg.isSubquery) {
                        const select = source.u4.pSubq.?.pSelect.?;
                        if (column >= 0 and column < select.pEList.?.nExpr) {
                            var nested = resolve_analysis.NameContext{ .parse = present.parse, .sources = select.pSrc, .next = context };
                            return expressionColumnType(&nested, select.pEList.?.items()[@intCast(column)].pExpr.?);
                        }
                        return null;
                    }
                    if (column < 0) return "INTEGER";
                    return schema_analysis.schemaColumnType(&table.columns.?[@intCast(column)], null);
                }
            }
            return null;
        },
        tokens.tk_select => {
            const select = expression_node.x.pSelect.?;
            var nested = resolve_analysis.NameContext{ .parse = context_initial.?.parse, .sources = select.pSrc, .next = context_initial };
            return expressionColumnType(&nested, select.pEList.?.items()[0].pExpr.?);
        },
        else => return null,
    }
}

/// Source `sqlite3SubqueryColumnTypes()`.
pub fn setSubqueryColumnTypes(parse: *parse_types.Parse, table: *schema.Table, select_initial: *parse_types.Select, default_affinity: u8) void {
    const db: *vdbe_types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (db.mallocFailed != 0 or parse.eParseMode != 0) return;
    var select = select_initial;
    while (select.pPrior) |prior| {
        select = prior;
    }
    var context = resolve_analysis.NameContext{ .parse = parse, .sources = select.pSrc };
    for (table.columns.?[0..@intCast(table.column_count)], 0..) |*column, index| {
        var arm = select;
        const node = select.pEList.?.items()[index].pExpr.?;
        column.affinity = expression_analysis.expressionAffinity(node);
        var data_types: c_int = 0;
        while (column.affinity <= 0x40 and arm.pNext != null) {
            data_types |= expression_analysis.expressionDataType(arm.pEList.?.items()[index].pExpr);
            arm = arm.pNext.?;
            column.affinity = expression_analysis.expressionAffinity(arm.pEList.?.items()[index].pExpr.?);
        }
        if (column.affinity <= 0x40) column.affinity = default_affinity;
        if (column.affinity >= schema_analysis.affinity.text and (arm.pNext != null or arm != select)) {
            var following = arm.pNext;
            while (following) |present| : (following = present.pNext) {
                data_types |= expression_analysis.expressionDataType(present.pEList.?.items()[index].pExpr);
            }
            if (column.affinity == schema_analysis.affinity.text and data_types & 0x01 != 0) {
                column.affinity = schema_analysis.affinity.blob;
            } else if (column.affinity >= schema_analysis.affinity.numeric and data_types & 0x02 != 0) {
                column.affinity = schema_analysis.affinity.blob;
            }
            if (column.affinity >= schema_analysis.affinity.numeric and node.op == tokens.tk_cast) column.affinity = 0x46;
        }
        var type_name = expressionColumnType(&context, node);
        if (type_name == null or (column.affinity > 0x40 and schema_analysis.affinityType(type_name.?, null) != column.affinity)) {
            type_name = switch (column.affinity) {
                schema_analysis.affinity.text => "TEXT",
                schema_analysis.affinity.integer => "INT",
                schema_analysis.affinity.real => "REAL",
                schema_analysis.affinity.numeric => "NUM",
                else => null,
            };
        }
        if (type_name) |name| {
            const old_name: [*:0]const u8 = @ptrCast(column.name_and_metadata.?);
            const name_length = std.mem.len(old_name) + 1;
            const type_length = std.mem.len(name) + 1;
            const resized = db_allocator.realloc(db, column.name_and_metadata, name_length + type_length) orelse continue;
            const bytes: [*]u8 = @ptrCast(resized);
            column.name_and_metadata = @ptrCast(bytes);
            @memcpy(bytes[name_length .. name_length + type_length], name[0..type_length]);
            column.flags = (column.flags & ~@as(u16, 0x0204)) | 0x0004;
        }
        if (expression_analysis.expressionCollation(parse, node)) |collation| schema_analysis.setColumnCollation(db, column, collation.zName.?);
    }
    table.row_size_estimate = 1;
}

/// Source `selectAddSubqueryTypeInfo()`.
pub fn addSubqueryTypeInfo(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) void {
    if (select.selFlags & 0x0000_2000 != 0) return;
    select.selFlags |= 0x0000_2000;
    for (select.pSrc.?.items()) |source| {
        if (source.pSTab.?.flags & schema.table_flag.ephemeral != 0 and source.fg.isSubquery) {
            setSubqueryColumnTypes(walker.pParse.?, source.pSTab.?, source.u4.pSubq.?.pSelect.?, 0x40);
        }
    }
}

/// Source `generateColumnTypes()`.
pub fn generateColumnTypes(parse: *parse_types.Parse, sources: *parse_types.SrcList, expressions: *parse_types.ExprList) void {
    const machine: *vdbe_types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    var context = resolve_analysis.NameContext{ .parse = parse, .sources = sources };
    for (expressions.items(), 0..) |item, index| {
        const type_name = expressionColumnType(&context, item.pExpr.?);
        _ = vdbe_aux.setColumnName(machine, @intCast(index), vdbe_types.column_name.declared_type, if (type_name) |name| name else null, .transient);
    }
}

/// Source `isSimpleCount()`.
pub fn simpleCountTable(select: *parse_types.Select, info: *parse_types.AggInfo) ?*schema.Table {
    if (select.pWhere != null or select.pEList.?.nExpr != 1 or select.pSrc.?.nSrc != 1 or select.pSrc.?.items()[0].fg.isSubquery or info.function_count != 1 or select.pHaving != null) return null;
    const table = select.pSrc.?.items()[0].pSTab.?;
    if (table.kind != .ordinary) return null;
    const node = select.pEList.?.items()[0].pExpr.?;
    if (node.op != tokens.tk_agg_function or node.pAggInfo != info) return null;
    const function: *vdbe_types.FuncDef = @ptrCast(@alignCast(info.functions.?[0].function orelse return null));
    if (function.funcFlags & vdbe_types.function_flag.count == 0 or node.flags & (0x0000_0008 | parse_types.expr_flag.win_func) != 0) return null;
    return table;
}

/// Source `codeOffset()`.
pub fn codeOffset(machine: *vdbe_types.Vdbe, offset_register: c_int, continue_address: c_int) void {
    if (offset_register <= 0) return;
    _ = vdbe_aux.addOperation3(machine, opcodes.Opcode.IfPos, offset_register, continue_address, 1);
}
