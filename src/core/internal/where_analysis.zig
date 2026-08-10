//! WHERE-clause expression helpers from `whereexpr.c` and `where.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const sqlite_string = @import("../string.zig");
const expression_analysis = @import("expression_analysis.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const walker_api = @import("walker.zig");
const types = @import("vdbe_types.zig");

pub const MaskSet = extern struct {
    variable_select: c_int,
    count: c_int,
    cursors: [64]c_int,
};

/// Source `createMask()`.
pub fn createMask(set: *MaskSet, cursor: c_int) void {
    set.cursors[@intCast(set.count)] = cursor;
    set.count += 1;
}

/// Source `sqlite3WhereGetMask()`.
pub fn getMask(set: *const MaskSet, cursor: c_int) u64 {
    for (set.cursors[0..@intCast(set.count)], 0..) |candidate, index| if (candidate == cursor) return @as(u64, 1) << @intCast(index);
    return 0;
}

/// Source `exprSelectUsage()`.
pub fn selectUsage(set: *MaskSet, select_initial: ?*parse_types.Select) u64 {
    var mask: u64 = 0;
    var select = select_initial;
    while (select) |present| : (select = present.pPrior) {
        mask |= expressionListUsage(set, present.pEList);
        mask |= expressionListUsage(set, present.pGroupBy);
        mask |= expressionListUsage(set, present.pOrderBy);
        mask |= expressionUsage(set, present.pWhere);
        mask |= expressionUsage(set, present.pHaving);
        if (present.pSrc) |sources| {
            for (sources.items()) |source| {
                if (source.fg.isSubquery) mask |= selectUsage(set, source.u4.pSubq.?.pSelect);
                if (!source.fg.isUsing) mask |= expressionUsage(set, source.u3.pOn);
                if (source.fg.isTabFunc) mask |= expressionListUsage(set, source.u1.pFuncArg);
            }
        }
    }
    return mask;
}

/// Source `sqlite3WhereExprUsageFull()`.
pub fn expressionUsageFull(set: *MaskSet, expression: *parse_types.Expr) u64 {
    var mask: u64 = if (expression.op == tokens.tk_if_null_row) getMask(set, expression.iTable) else 0;
    if (expression.pLeft) |left| mask |= expressionUsageNotNull(set, left);
    if (expression.pRight) |right| {
        mask |= expressionUsageNotNull(set, right);
    } else if (expression.usesSelect()) {
        if (expression.flags & parse_types.expr_flag.variable_select != 0) set.variable_select = 1;
        mask |= selectUsage(set, expression.x.pSelect);
    } else if (expression.x.pList) |list| mask |= expressionListUsage(set, list);
    if ((expression.op == tokens.tk_function or expression.op == tokens.tk_agg_function) and expression.flags & parse_types.expr_flag.win_func != 0) {
        const window = expression.y.pWin.?;
        mask |= expressionListUsage(set, window.partition_by);
        mask |= expressionListUsage(set, window.order_by);
        mask |= expressionUsage(set, window.filter);
    }
    return mask;
}

/// Source `sqlite3WhereExprUsageNN()`.
pub fn expressionUsageNotNull(set: *MaskSet, expression: *parse_types.Expr) u64 {
    if (expression.op == tokens.tk_column and expression.flags & 0x0000_0020 == 0) return getMask(set, expression.iTable);
    if (expression.flags & (0x0001_0000 | 0x0080_0000) != 0) return 0;
    return expressionUsageFull(set, expression);
}

/// Source `sqlite3WhereExprUsage()`.
pub fn expressionUsage(set: *MaskSet, expression: ?*parse_types.Expr) u64 {
    return if (expression) |present| expressionUsageNotNull(set, present) else 0;
}

/// Source `sqlite3WhereExprListUsage()`.
pub fn expressionListUsage(set: *MaskSet, list_optional: ?*parse_types.ExprList) u64 {
    const list = list_optional orelse return 0;
    var mask: u64 = 0;
    for (list.items()) |item| mask |= expressionUsage(set, item.pExpr);
    return mask;
}

/// Source `sqlite3ExprIsLikeOperator()`.
pub fn likeOperator(expression: *const parse_types.Expr) u8 {
    std.debug.assert(expression.op == tokens.tk_function);
    const name = expression.u.zToken orelse return 0;
    const operators = [_]struct { name: [*:0]const u8, constraint: u8 }{
        .{ .name = "match", .constraint = 64 },
        .{ .name = "glob", .constraint = 66 },
        .{ .name = "like", .constraint = 65 },
        .{ .name = "regexp", .constraint = 67 },
    };
    for (operators) |operator| {
        if (sqlite_string.compareInternal(name, operator.name) == 0) return operator.constraint;
    }
    return 0;
}

test "LIKE-family virtual-table operators use pinned constraint codes" {
    var expression = std.mem.zeroes(parse_types.Expr);
    expression.op = tokens.tk_function;
    expression.u.zToken = @constCast("LiKe");
    try std.testing.expectEqual(@as(u8, 65), likeOperator(&expression));
    expression.u.zToken = @constCast("glob");
    try std.testing.expectEqual(@as(u8, 66), likeOperator(&expression));
    expression.u.zToken = @constCast("ordinary");
    try std.testing.expectEqual(@as(u8, 0), likeOperator(&expression));
}

/// Source `columnIsGoodIndexCandidate()`.
pub fn columnIsGoodIndexCandidate(table: *const schema.Table, column: c_int) bool {
    var index = table.indexes;
    while (index) |present| : (index = present.next) {
        for (present.columns.?[0..present.key_column_count], 0..) |indexed_column, position| {
            if (indexed_column != column) continue;
            if (position == 0) return false;
            if (present.properties.has_statistics and present.row_log_estimates.?[position + 1] > 20) return false;
            break;
        }
    }
    return true;
}

/// Source `findIndexCol()`.
pub fn findIndexColumn(parse: *parse_types.Parse, list: *parse_types.ExprList, base_cursor: c_int, index: *schema.Index, index_column: c_int) c_int {
    const expected_collation = index.collations.?[@intCast(index_column)].?;
    for (list.items(), 0..) |item, position| {
        const candidate = expression_analysis.skipCollationAndLikely(item.pExpr) orelse continue;
        if ((candidate.op == tokens.tk_column or candidate.op == tokens.tk_agg_column) and
            candidate.iColumn == index.columns.?[@intCast(index_column)] and candidate.iTable == base_cursor)
        {
            const actual = expression_analysis.expressionNonNullCollation(parse, item.pExpr.?);
            if (sqlite_string.compareInternal(actual.zName.?, expected_collation) == 0) return @intCast(position);
        }
    }
    return -1;
}

/// Source `indexColumnNotNull()`.
pub fn indexColumnNotNull(index: *schema.Index, column: c_int) bool {
    const table_column = index.columns.?[@intCast(column)];
    if (table_column >= 0) return index.table.?.columns.?[@intCast(table_column)].definition.not_null_action != 0;
    return table_column == -1;
}

/// Source `allowedOp()`.
pub fn allowedOperation(operation: c_int) bool {
    if (operation > tokens.tk_ge) return false;
    if (operation >= tokens.tk_eq) return true;
    return operation == tokens.tk_in or operation == tokens.tk_isnull or operation == tokens.tk_is;
}

/// Source `exprCommute()`.
pub fn commuteExpression(parse: *parse_types.Parse, expression: *parse_types.Expr) u16 {
    if (expression.pLeft.?.op == tokens.tk_vector or expression.pRight.?.op == tokens.tk_vector or
        expression_analysis.binaryComparisonCollation(parse, expression.pLeft.?, expression.pRight) !=
            expression_analysis.binaryComparisonCollation(parse, expression.pRight.?, expression.pLeft))
    {
        expression.flags ^= 0x0000_0400;
    }
    const left = expression.pLeft;
    expression.pLeft = expression.pRight;
    expression.pRight = left;
    if (expression.op >= tokens.tk_gt) expression.op = @intCast(((expression.op - tokens.tk_gt) ^ 2) + tokens.tk_gt);
    return 0;
}

/// Source `operatorMask()`.
pub fn operationMask(operation: c_int) u16 {
    if (operation >= tokens.tk_eq) return @as(u16, 0x0002) << @intCast(operation - tokens.tk_eq);
    if (operation == tokens.tk_in) return 0x0001;
    if (operation == tokens.tk_isnull) return 0x0100;
    return 0x0080;
}

/// Source `termIsEquivalence()`.
pub fn termIsEquivalence(parse: *parse_types.Parse, expression: *parse_types.Expr, sources: *parse_types.SrcList) bool {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (!types.optimizationEnabled(db, types.optimization.transitive)) return false;
    if (expression.op != tokens.tk_eq and expression.op != tokens.tk_is) return false;
    if (expression.flags & (0x0000_0001 | 0x0000_0200) != 0) return false;
    if (expression.op == tokens.tk_is and sources.nSrc >= 2 and sources.items()[0].fg.jointype & 0x40 != 0) return false;
    const first_affinity = expression_analysis.expressionAffinity(expression.pLeft.?);
    const second_affinity = expression_analysis.expressionAffinity(expression.pRight.?);
    if (first_affinity != second_affinity and (!expression_analysis.numericAffinity(first_affinity) or !expression_analysis.numericAffinity(second_affinity))) return false;
    return expression_analysis.expressionCollationsMatch(parse, expression.pLeft.?, expression.pRight.?);
}

/// Source `transferJoinMarkings()`.
pub fn transferJoinMarkings(derived: ?*parse_types.Expr, base: *const parse_types.Expr) void {
    const output = derived orelse return;
    if (base.flags & 0x0000_0003 == 0) return;
    output.flags |= base.flags & 0x0000_0003;
    output.w.iJoin = base.w.iJoin;
}

/// Source `whereRightSubexprIsColumn()`.
pub fn rightSubexpressionIsColumn(expression: *parse_types.Expr) ?*parse_types.Expr {
    const right = expression_analysis.skipCollationAndLikely(expression.pRight) orelse return null;
    return if (right.op == tokens.tk_column and right.flags & 0x0000_0020 == 0) right else null;
}

/// Source `exprNodePatternLengthEst()`.
pub fn patternLengthNode(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op != tokens.tk_string) return walker_api.continue_walk;
    const text = expression.u.zToken.?;
    const many: u8 = if (walker.eCode != 0) '%' else '*';
    const one: u8 = if (walker.eCode != 0) '_' else '?';
    const set: u8 = if (walker.eCode != 0) 0 else '[';
    var size: c_int = 0;
    var position: usize = 0;
    while (text[position] != 0) : (position += 1) {
        const character = text[position];
        if (character == set) {
            if (text[position + 1] != 0) position += 1;
            while (text[position] != 0 and text[position] != ']') position += 1;
        } else if (character != many and character != one) size += 1;
    }
    walker.u.counter = @max(walker.u.counter, size);
    return walker_api.continue_walk;
}

/// Source `estLikePatternLength()`.
pub fn estimateLikePatternLength(expression: *parse_types.Expr, like: bool) c_int {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.u.counter = 0;
    walker.eCode = @intFromBool(like);
    walker.xExprCallback = patternLengthNode;
    walker.xSelectCallback = selectWalkFail;
    _ = walker_api.walkExpr(&walker, expression);
    return walker.u.counter;
}

/// Source `sqlite3SelectWalkFail()`.
pub fn selectWalkFail(walker: *parse_types.Walker, _: *parse_types.Select) callconv(.c) c_int {
    walker.eCode = 0;
    return walker_api.abort_walk;
}

/// Source `exprNodeIsDeterministic()`.
pub fn deterministicExpressionNode(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_function and expression.flags & 0x0010_0000 == 0) {
        walker.eCode = 0;
        return walker_api.abort_walk;
    }
    return walker_api.continue_walk;
}

/// Source `exprIsDeterministic()`.
pub fn expressionIsDeterministic(expression: *parse_types.Expr) bool {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.eCode = 1;
    walker.xExprCallback = deterministicExpressionNode;
    walker.xSelectCallback = selectWalkFail;
    _ = walker_api.walkExpr(&walker, expression);
    return walker.eCode != 0;
}
