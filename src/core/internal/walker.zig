//! Source-corresponding parse-tree walkers from `walker.c`.

const types = @import("parse_types.zig");

pub const continue_walk: c_int = 0;
pub const prune: c_int = 1;
pub const abort: c_int = 2;

/// Source `walkWindowList()`.
pub fn walkWindowList(walker: *types.Walker, first: ?*types.Window, one_only: bool) c_int {
    var current = first;
    while (current) |window| : (current = window.next) {
        if (walkExprList(walker, window.order_by) != continue_walk) return abort;
        if (walkExprList(walker, window.partition_by) != continue_walk) return abort;
        if (walkExpr(walker, window.filter) != continue_walk) return abort;
        if (walkExpr(walker, window.start) != continue_walk) return abort;
        if (walkExpr(walker, window.end) != continue_walk) return abort;
        if (one_only) break;
    }
    return continue_walk;
}

/// Source `sqlite3WalkExprNN()`.
pub fn walkExprNonNull(walker: *types.Walker, expression_initial: *types.Expr) c_int {
    var expression = expression_initial;
    while (true) {
        const callback_result = walker.xExprCallback.?(walker, expression);
        if (callback_result != continue_walk) return callback_result & abort;
        if (!expression.has(types.expr_flag.token_only | types.expr_flag.leaf)) {
            if (expression.pLeft) |left| {
                if (walkExprNonNull(walker, left) != continue_walk) return abort;
            }
            if (expression.pRight) |right| {
                expression = right;
                continue;
            } else if (expression.usesSelect()) {
                if (walkSelect(walker, expression.x.pSelect) != continue_walk) return abort;
            } else {
                if (walkExprList(walker, expression.x.pList) != continue_walk) return abort;
                if (expression.has(types.expr_flag.win_func) and
                    walkWindowList(walker, expression.y.pWin, true) != continue_walk)
                {
                    return abort;
                }
            }
        }
        break;
    }
    return continue_walk;
}

/// Source `sqlite3WalkExpr()`.
pub fn walkExpr(walker: *types.Walker, expression: ?*types.Expr) c_int {
    return if (expression) |present| walkExprNonNull(walker, present) else continue_walk;
}

/// Source `sqlite3WalkExprList()`.
pub fn walkExprList(walker: *types.Walker, list: ?*types.ExprList) c_int {
    const present = list orelse return continue_walk;
    for (present.items()) |*item| {
        if (walkExpr(walker, item.pExpr) != continue_walk) return abort;
    }
    return continue_walk;
}

/// Source `sqlite3WalkWinDefnDummyCallback()`.
pub fn walkWindowDefinitionDummy(_: *types.Walker, _: *types.Select) callconv(.c) void {}

/// Source `findRightmost()`.
pub fn findRightmost(select_initial: *types.Select) *types.Select {
    var select = select_initial;
    while (select.pNext) |next| select = next;
    return select;
}

/// Source `sqlite3SelectPopWith()`.
pub fn selectPopWith(walker: *types.Walker, select: *types.Select) callconv(.c) void {
    const parse = walker.pParse orelse return;
    if (parse.pWith != null and select.pPrior == null) {
        if (findRightmost(select).pWith) |with| {
            parse.pWith = with.pOuter;
        }
    }
}

/// Source `sqlite3WalkSelectExpr()`.
pub fn walkSelectExpressions(walker: *types.Walker, select: *types.Select) c_int {
    if (walkExprList(walker, select.pEList) != continue_walk) return abort;
    if (walkExpr(walker, select.pWhere) != continue_walk) return abort;
    if (walkExprList(walker, select.pGroupBy) != continue_walk) return abort;
    if (walkExpr(walker, select.pHaving) != continue_walk) return abort;
    if (walkExprList(walker, select.pOrderBy) != continue_walk) return abort;
    if (walkExpr(walker, select.pLimit) != continue_walk) return abort;
    if (select.pWinDefn != null) {
        const after = walker.xSelectCallback2;
        const rename_parse = if (walker.pParse) |parse| parse.eParseMode >= 2 else false;
        if (after == walkWindowDefinitionDummy or after == selectPopWith or rename_parse) {
            return walkWindowList(walker, select.pWinDefn, false);
        }
    }
    return continue_walk;
}

/// Source `sqlite3WalkSelectFrom()`.
pub fn walkSelectFrom(walker: *types.Walker, select: *types.Select) c_int {
    const source = select.pSrc orelse return continue_walk;
    for (source.items()) |*item| {
        if (item.fg.isSubquery) {
            const subquery = item.u4.pSubq orelse continue;
            if (walkSelect(walker, subquery.pSelect) != continue_walk) return abort;
        }
        if (item.fg.isTabFunc and walkExprList(walker, item.u1.pFuncArg) != continue_walk) return abort;
    }
    return continue_walk;
}

/// Source `sqlite3WalkSelect()`.
pub fn walkSelect(walker: *types.Walker, first: ?*types.Select) c_int {
    var select = first orelse return continue_walk;
    const before = walker.xSelectCallback orelse return continue_walk;
    while (true) {
        const callback_result = before(walker, select);
        if (callback_result != continue_walk) return callback_result & abort;
        if (walkSelectExpressions(walker, select) != continue_walk or
            walkSelectFrom(walker, select) != continue_walk)
        {
            return abort;
        }
        if (walker.xSelectCallback2) |after| after(walker, select);
        select = select.pPrior orelse break;
    }
    return continue_walk;
}

/// Source `sqlite3WalkerDepthIncrease()`.
pub fn depthIncrease(walker: *types.Walker, _: *types.Select) callconv(.c) c_int {
    walker.walkerDepth += 1;
    return continue_walk;
}

/// Source `sqlite3WalkerDepthDecrease()`.
pub fn depthDecrease(walker: *types.Walker, _: *types.Select) callconv(.c) void {
    walker.walkerDepth -= 1;
}

/// Source `sqlite3ExprWalkNoop()`.
pub fn exprNoop(_: *types.Walker, _: *types.Expr) callconv(.c) c_int {
    return continue_walk;
}

/// Source `sqlite3SelectWalkNoop()`.
pub fn selectNoop(_: *types.Walker, _: *types.Select) callconv(.c) c_int {
    return continue_walk;
}
