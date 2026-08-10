//! Aggregate expression ownership and indexing analysis from `expr.c` and `select.c`.

const std = @import("std");
const ast_duplication = @import("ast_duplication.zig");
const db_allocator = @import("db_allocator.zig");
const expression_analysis = @import("expression_analysis.zig");
const function_registry = @import("function_registry.zig");
const parse_cleanup = @import("parse_cleanup.zig");
const parse_types = @import("parse_types.zig");
const tokens = @import("../generated/tokens.zig");
const types = @import("vdbe_types.zig");
const walker_api = @import("walker.zig");

pub const AggregateContext = struct {
    parse: *parse_types.Parse,
    sources: *parse_types.SrcList,
    info: *parse_types.AggInfo,
    in_function: bool = false,
};

fn appendColumn(db: *types.Sqlite3, info: *parse_types.AggInfo) ?c_int {
    const old_count = info.column_count;
    const raw = db_allocator.realloc(db, if (info.columns) |columns| @ptrCast(columns) else null, @as(usize, @intCast(old_count + 1)) * @sizeOf(parse_types.AggInfoColumn)) orelse return null;
    info.columns = @ptrCast(@alignCast(raw));
    info.columns.?[@intCast(old_count)] = std.mem.zeroes(parse_types.AggInfoColumn);
    info.column_count += 1;
    return old_count;
}

fn appendFunction(db: *types.Sqlite3, info: *parse_types.AggInfo) ?c_int {
    const old_count = info.function_count;
    const raw = db_allocator.realloc(db, if (info.functions) |functions| @ptrCast(functions) else null, @as(usize, @intCast(old_count + 1)) * @sizeOf(parse_types.AggInfoFunction)) orelse return null;
    info.functions = @ptrCast(@alignCast(raw));
    info.functions.?[@intCast(old_count)] = std.mem.zeroes(parse_types.AggInfoFunction);
    info.function_count += 1;
    return old_count;
}

/// Source `agginfoPersistExprCb()`.
pub fn persistAggregateExpression(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const info = node.pAggInfo orelse return walker_api.continue_walk;
    const index: usize = @intCast(node.iAgg);
    const parse = walker.pParse.?;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (node.op != tokens.tk_agg_function) {
        if (index < info.column_count and info.columns.?[index].expression == node) {
            const duplicate = ast_duplication.duplicateExpression(db, node, false) orelse return walker_api.continue_walk;
            if (parse_cleanup.add(parse, parse_cleanup.expressionCallback, duplicate) != null) info.columns.?[index].expression = duplicate;
        }
    } else if (index < info.function_count and info.functions.?[index].expression == node) {
        const duplicate = ast_duplication.duplicateExpression(db, node, false) orelse return walker_api.continue_walk;
        if (parse_cleanup.add(parse, parse_cleanup.expressionCallback, duplicate) != null) info.functions.?[index].expression = duplicate;
    }
    return walker_api.continue_walk;
}

/// Source `findOrCreateAggInfoColumn()`.
pub fn findOrCreateAggregateColumn(parse: *parse_types.Parse, info: *parse_types.AggInfo, node: *parse_types.Expr) void {
    var index: c_int = 0;
    while (index < info.column_count) : (index += 1) {
        const column = &info.columns.?[@intCast(index)];
        if (column.expression == node) return;
        if (column.table_cursor == node.iTable and column.column == node.iColumn and node.op != tokens.tk_if_null_row) break;
    }
    if (index == info.column_count) {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        index = appendColumn(db, info) orelse return;
        const column = &info.columns.?[@intCast(index)];
        column.table = node.y.pTab;
        column.table_cursor = node.iTable;
        column.column = node.iColumn;
        column.sorter_column = -1;
        column.expression = node;
        if (info.group_by) |group_by| if (node.op != tokens.tk_if_null_row) {
            for (group_by.items(), 0..) |item, group_index| {
                const group = item.pExpr.?;
                if (group.op == tokens.tk_column and group.iTable == node.iTable and group.iColumn == node.iColumn) {
                    column.sorter_column = @intCast(group_index);
                    break;
                }
            }
        };
        if (column.sorter_column < 0) {
            column.sorter_column = @intCast(info.sorting_column_count);
            info.sorting_column_count += 1;
        }
    }
    node.flags |= 0x0000_1000;
    node.pAggInfo = info;
    if (node.op == tokens.tk_column) node.op = @intCast(tokens.tk_agg_column);
    node.iAgg = @intCast(index);
}

/// Source `analyzeAggregate()`.
pub fn analyzeAggregate(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const context: *AggregateContext = @ptrCast(@alignCast(walker.u.pointer.?));
    const info = context.info;
    switch (node.op) {
        tokens.tk_column, tokens.tk_agg_column, tokens.tk_if_null_row => {
            for (context.sources.items()) |source| if (node.iTable == source.iCursor) {
                findOrCreateAggregateColumn(context.parse, info, node);
                break;
            };
            return walker_api.continue_walk;
        },
        tokens.tk_agg_function => {
            if (context.in_function or walker.walkerDepth != node.op2 or node.pAggInfo != null) return walker_api.continue_walk;
            var index: c_int = 0;
            while (index < info.function_count) : (index += 1) {
                const existing = info.functions.?[@intCast(index)].expression.?;
                if (existing == node or expression_analysis.compareExpressions(null, existing, node, -1) == 0) break;
            }
            if (index == info.function_count) {
                const db: *types.Sqlite3 = @ptrCast(@alignCast(context.parse.db.?));
                index = appendFunction(db, info) orelse return walker_api.abort_walk;
                const item = &info.functions.?[@intCast(index)];
                item.expression = node;
                const argument_count = if (node.x.pList) |arguments| arguments.nExpr else 0;
                item.function = @ptrCast(function_registry.findFunction(db, node.u.zToken.?, argument_count, db.enc, false));
                if (node.pLeft != null and item.function != null and @as(*types.FuncDef, @ptrCast(@alignCast(item.function.?))).funcFlags & types.function_flag.need_collation == 0) {
                    item.order_cursor = context.parse.nTab;
                    context.parse.nTab += 1;
                    const order_by = node.pLeft.?.x.pList.?;
                    if (order_by.nExpr == 1 and argument_count == 1 and expression_analysis.compareExpressions(null, order_by.items()[0].pExpr, node.x.pList.?.items()[0].pExpr, 0) == 0) {
                        item.order_payload = 0;
                        item.order_unique = @intFromBool(node.flags & 0x0000_0008 != 0);
                    } else item.order_payload = 1;
                    item.use_subtype = @intFromBool(@as(*types.FuncDef, @ptrCast(@alignCast(item.function.?))).funcFlags & types.function_flag.result_subtype != 0);
                } else item.order_cursor = -1;
                if (node.flags & 0x0000_0008 != 0 and item.order_unique == 0) {
                    item.distinct_cursor = context.parse.nTab;
                    context.parse.nTab += 1;
                } else item.distinct_cursor = -1;
            }
            node.flags |= 0x0000_1000;
            node.iAgg = @intCast(index);
            node.pAggInfo = info;
            return walker_api.prune;
        },
        else => {
            if (!context.in_function or context.parse.pIdxEpr == null) return walker_api.continue_walk;
            var indexed = context.parse.pIdxEpr;
            while (indexed) |entry| : (indexed = entry.next) {
                if (entry.data_cursor < 0 or expression_analysis.compareExpressions(null, node, entry.expression, entry.data_cursor) != 0) continue;
                var source_found = false;
                for (context.sources.items()) |source| {
                    if (source.iCursor == entry.data_cursor) {
                        source_found = true;
                        break;
                    }
                }
                if (!source_found or node.pAggInfo != null or context.parse.nErr != 0) continue;
                var temporary = std.mem.zeroes(parse_types.Expr);
                temporary.op = @intCast(tokens.tk_agg_column);
                temporary.iTable = entry.index_cursor;
                temporary.iColumn = @intCast(entry.index_column);
                findOrCreateAggregateColumn(context.parse, info, &temporary);
                info.columns.?[@intCast(temporary.iAgg)].expression = node;
                node.pAggInfo = info;
                node.iAgg = temporary.iAgg;
                return walker_api.prune;
            }
            return walker_api.continue_walk;
        },
    }
}

/// Source `analyzeAggFuncArgs()`.
pub fn analyzeAggregateFunctionArguments(info: *parse_types.AggInfo, context: *AggregateContext) void {
    context.in_function = true;
    defer context.in_function = false;
    for (info.functions.?[0..@intCast(info.function_count)]) |item| {
        const node = item.expression.?;
        var walker = std.mem.zeroes(parse_types.Walker);
        walker.pParse = context.parse;
        walker.xExprCallback = analyzeAggregate;
        walker.xSelectCallback = walker_api.depthIncrease;
        walker.xSelectCallback2 = walker_api.depthDecrease;
        walker.u.pointer = context;
        _ = walker_api.walkExprList(&walker, node.x.pList);
        if (node.pLeft) |order| _ = walker_api.walkExprList(&walker, order.x.pList);
        if (node.flags & parse_types.expr_flag.win_func != 0) _ = walker_api.walkExpr(&walker, node.y.pWin.?.filter);
    }
}

/// Source `aggregateIdxEprRefToColCallback()`.
pub fn aggregateIndexedExpressionToColumn(_: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const info = node.pAggInfo orelse return walker_api.continue_walk;
    if (node.op == tokens.tk_agg_column or node.op == tokens.tk_agg_function or node.op == tokens.tk_if_null_row) return walker_api.continue_walk;
    if (node.iAgg < 0 or node.iAgg >= info.column_count) return walker_api.continue_walk;
    const column = info.columns.?[@intCast(node.iAgg)];
    node.op = @intCast(tokens.tk_agg_column);
    node.iTable = column.table_cursor;
    node.iColumn = @intCast(column.column);
    node.flags &= ~@as(u32, 0x0008_2200);
    return walker_api.prune;
}

/// Source `optimizeAggregateUseOfIndexedExpr()`.
pub fn optimizeAggregateIndexedExpressions(parse: *parse_types.Parse, select: *parse_types.Select, info: *parse_types.AggInfo, context: *AggregateContext) void {
    info.column_count = info.accumulator_count;
    if (info.sorting_column_count > 0) {
        var maximum: c_int = select.pGroupBy.?.nExpr - 1;
        for (info.columns.?[0..@intCast(info.column_count)]) |column| {
            maximum = @max(maximum, column.sorter_column);
        }
        info.sorting_column_count = @intCast(maximum + 1);
    }
    analyzeAggregateFunctionArguments(info, context);
    _ = parse;
}
