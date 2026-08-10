//! Name-resolution helpers from `resolve.c`.

const std = @import("std");
const sqlite_float = @import("../float.zig");
const sqlite_string = @import("../string.zig");
const ast_duplication = @import("ast_duplication.zig");
const db_allocator = @import("db_allocator.zig");
const expression = @import("expression_analysis.zig");
const parse_cleanup = @import("parse_cleanup.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const types = @import("vdbe_types.zig");
const tokens = @import("../generated/tokens.zig");
const walker_api = @import("walker.zig");
const window_functions = @import("window_functions.zig");

fn componentMatches(span: [*]const u8, length: usize, expected: ?[*:0]const u8) bool {
    const text = expected orelse return true;
    return sqlite_string.compareN(span, text, @intCast(length)) == 0 and text[length] == 0;
}

/// Source `areDoubleQuotedStringsEnabled()`.
pub fn doubleQuotedStringsEnabled(db: *types.Sqlite3, name_context_flags: u32) bool {
    if (db.init.busy != 0) return true;
    if (name_context_flags & 0x0001_0000 != 0) {
        if (schema_analysis.writableSchema(db) and db.flags & types.connection_flag.dqs_dml != 0) return true;
        return db.flags & types.connection_flag.dqs_ddl != 0;
    }
    return db.flags & types.connection_flag.dqs_dml != 0;
}

fn setResolveError(parse: *parse_types.Parse, message: []const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

pub const NameContext = struct {
    parse: *parse_types.Parse,
    sources: ?*parse_types.SrcList = null,
    result_list: ?*parse_types.ExprList = null,
    next: ?*NameContext = null,
    flags: u32 = 0,
    references: c_int = 0,
    errors: c_int = 0,
};

fn incrementAggregateDepth(node_optional: ?*parse_types.Expr, amount: c_int) void {
    const node = node_optional orelse return;
    if (node.op == tokens.tk_agg_function) node.op2 +%= @intCast(amount);
    if (node.flags & parse_types.expr_flag.token_only != 0) return;
    incrementAggregateDepth(node.pLeft, amount);
    incrementAggregateDepth(node.pRight, amount);
    if (node.usesSelect()) {
        var select = node.x.pSelect;
        while (select) |present| : (select = present.pPrior) {
            if (present.pEList) |list| for (list.items()) |item| incrementAggregateDepth(item.pExpr, amount);
        }
    } else if (node.x.pList) |list| for (list.items()) |item| incrementAggregateDepth(item.pExpr, amount);
}

/// Source `resolveAlias()`.
pub fn resolveAlias(parse: *parse_types.Parse, result_list: *parse_types.ExprList, column: c_int, target: *parse_types.Expr, subquery_depth: c_int) void {
    if (target.pAggInfo != null) return;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var duplicate = ast_duplication.duplicateExpression(db, result_list.items()[@intCast(column)].pExpr, false) orelse return;
    incrementAggregateDepth(duplicate, subquery_depth);
    if (target.op == tokens.tk_collate) {
        var token = parse_types.Token{ .z = target.u.zToken, .n = @intCast(std.mem.len(target.u.zToken.?)) };
        duplicate = expression.addCollationToken(parse, duplicate, &token, false);
    }
    const saved = duplicate.*;
    duplicate.* = target.*;
    target.* = saved;
    if (target.flags & parse_types.expr_flag.win_func != 0 and target.y.pWin != null) target.y.pWin.?.owner = target;
    _ = parse_cleanup.add(parse, parse_cleanup.expressionCallback, duplicate);
}

/// Source `extendFJMatch()`.
pub fn extendFullJoinMatch(parse: *parse_types.Parse, list: *?*parse_types.ExprList, source: *parse_types.SrcItem, column: i16) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const node = expression.newExpression(db, @intCast(tokens.tk_column), null) orelse return;
    node.iTable = source.iCursor;
    node.iColumn = column;
    node.y.pTab = source.pSTab;
    node.flags |= 0x0000_4000;
    list.* = expression.appendExpressionList(parse, list.*, node);
}

/// Source `sqlite3CreateColumnExpr()`.
pub fn createColumnExpression(db: *types.Sqlite3, sources: *parse_types.SrcList, source_index: c_int, column_index: c_int) ?*parse_types.Expr {
    const node = expression.newExpression(db, @intCast(tokens.tk_column), null) orelse return null;
    const source = &sources.items()[@intCast(source_index)];
    const table = source.pSTab.?;
    node.y.pTab = table;
    node.iTable = source.iCursor;
    if (table.primary_key_column == column_index) {
        node.iColumn = -1;
    } else {
        node.iColumn = @intCast(column_index);
        if (table.flags & 0x0000_0060 != 0 and table.columns.?[@intCast(column_index)].flags & 0x0060 != 0) {
            source.colUsed = if (table.column_count >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(table.column_count)) - 1;
        } else source.colUsed |= @as(u64, 1) << @intCast(@min(column_index, 63));
    }
    return node;
}

/// Source `notValidImpl()`.
pub fn reportInvalidExpression(parse: *parse_types.Parse, context: *const NameContext, message_kind: []const u8, expression_to_invalidate: ?*parse_types.Expr, error_expression: ?*parse_types.Expr) void {
    const location: []const u8 = if (context.flags & 0x0000_0020 != 0)
        "index expressions"
    else if (context.flags & 0x0000_0004 != 0)
        "CHECK constraints"
    else if (context.flags & 0x0000_0008 != 0)
        "generated columns"
    else
        "partial index WHERE clauses";
    var buffer: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{s} prohibited in {s}", .{ message_kind, location }) catch "expression prohibited in schema definition";
    setResolveError(parse, message);
    if (expression_to_invalidate) |node| node.op = @intCast(tokens.tk_null);
    var node = error_expression;
    while (node) |present| : (node = present.pLeft) {
        if (present.flags & 0x0000_0003 == 0 and present.w.iOfst > 0) {
            if (present.flags & 0x4000_0000 == 0) {
                const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
                db.errByteOffset = present.w.iOfst;
            }
            break;
        }
    }
}

/// Source `resolveOutOfRangeError()`.
pub fn outOfRangeError(parse: *parse_types.Parse, clause: []const u8, index: c_int, maximum: c_int, error_expression: *parse_types.Expr) void {
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{d} {s} BY term out of range - should be between 1 and {d}", .{ index, clause, maximum }) catch "ORDER BY term out of range";
    setResolveError(parse, message);
    var expression_node: ?*parse_types.Expr = error_expression;
    while (expression_node) |present| {
        if (present.flags & 0x0000_0003 == 0 and present.w.iOfst > 0) {
            if (present.flags & 0x4000_0000 == 0) {
                const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
                db.errByteOffset = present.w.iOfst;
            }
            break;
        }
        expression_node = present.pLeft;
    }
}

/// Source `resolveRemoveWindowsCb()`.
pub fn removeWindowsCallback(_: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    if (expression_node.flags & parse_types.expr_flag.win_func != 0) window_functions.unlinkFromSelect(expression_node.y.pWin.?);
    return walker_api.continue_walk;
}

/// Source `windowRemoveExprFromSelect()`.
pub fn removeExpressionWindows(select: *parse_types.Select, expression_node: *parse_types.Expr) void {
    if (select.pWin == null) return;
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = removeWindowsCallback;
    _ = walker_api.walkExpr(&walker, expression_node);
}

/// Source `resolveAsName()`.
pub fn resolveAsName(_: *parse_types.Parse, list: *parse_types.ExprList, expression_node: *parse_types.Expr) c_int {
    if (expression_node.op != tokens.tk_id) return 0;
    const name = expression_node.u.zToken.?;
    for (list.items(), 0..) |item, index| {
        if (item.fg.eEName == 1 and sqlite_string.compareInternal(item.zEName.?, name) == 0) return @intCast(index + 1);
    }
    return 0;
}

/// Source `sqlite3MatchEName()`.
pub fn matchExpressionName(
    item: *const parse_types.ExprListItem,
    column: ?[*:0]const u8,
    table: ?[*:0]const u8,
    database: ?[*:0]const u8,
    rowid: ?*c_int,
) bool {
    const name_kind = item.fg.eEName;
    if (name_kind != 2 and (name_kind != 3 or rowid == null)) return false;
    var span: [*:0]const u8 = @ptrCast(item.zEName.?);
    var length: usize = 0;
    while (span[length] != 0 and span[length] != '.') : (length += 1) {}
    if (!componentMatches(span, length, database)) return false;
    span += length + 1;
    length = 0;
    while (span[length] != 0 and span[length] != '.') : (length += 1) {}
    if (!componentMatches(span, length, table)) return false;
    span += length + 1;
    if (column) |name| {
        if (name_kind == 2 and sqlite_string.compareInternal(span, name) != 0) return false;
        if (name_kind == 3 and !expression.isRowid(name)) return false;
    }
    if (name_kind == 3) rowid.?.* = 1;
    return true;
}

/// Source `sqlite3ExprColUsed()`.
pub fn expressionColumnUsed(expression_node: *parse_types.Expr) u64 {
    var column = expression_node.iColumn;
    const table = expression_node.y.pTab.?;
    if (table.flags & 0x0000_0060 != 0 and table.columns.?[@intCast(column)].flags & 0x0060 != 0) {
        return if (table.column_count >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(table.column_count)) - 1;
    }
    if (column >= 64) column = 63;
    return @as(u64, 1) << @intCast(column);
}

/// Source `isValidSchemaTableName()`.
pub fn isValidSchemaTableName(name: [*:0]const u8, table: *schema.Table, database: ?[*:0]const u8) bool {
    if (sqlite_string.compareN(name, "sqlite_", 7) != 0) return false;
    const legacy = table.name.?;
    if (sqlite_string.compareInternal(legacy + 7, "temp_master") == 0) {
        if (sqlite_string.compareInternal(name + 7, "temp_schema") == 0) return true;
        if (database == null) return false;
        return sqlite_string.compareInternal(name + 7, "master") == 0 or sqlite_string.compareInternal(name + 7, "schema") == 0;
    }
    return sqlite_string.compareInternal(name + 7, "schema") == 0;
}

/// Source `exprProbability()`.
pub fn expressionProbability(expression_node: *parse_types.Expr) c_int {
    if (expression_node.op != tokens.tk_float) return -1;
    const parsed = sqlite_float.parse(expression_node.u.zToken.?);
    if (parsed.code <= 0 or parsed.value < 0 or parsed.value > 1) return -1;
    return @intFromFloat(parsed.value * 134_217_728.0);
}

/// Source `resolveSetExprSubtypeArg()`.
pub fn setExpressionSubtypeArgument(list_optional: ?*parse_types.ExprList) void {
    const list = list_optional orelse return;
    for (list.items()) |item| {
        var expression_node = item.pExpr.?;
        while (true) {
            expression_node.flags |= 0x8000_0000;
            if (expression_node.op == tokens.tk_select) {
                setExpressionSubtypeArgument(expression_node.x.pSelect.?.pEList);
                break;
            }
            if (expression_node.op != tokens.tk_uplus) break;
            expression_node = expression_node.pLeft.?;
        }
    }
}
