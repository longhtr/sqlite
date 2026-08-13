//! Deep parse-tree duplication from `expr.c`, `window.c`, and `upsert.c`.

const std = @import("std");
const db_allocator = @import("db_allocator.zig");
const expression_analysis = @import("expression_analysis.zig");
const parse_types = @import("parse_types.zig");
const tokens = @import("../generated/tokens.zig");
const types = @import("vdbe_types.zig");
const walker_api = @import("walker.zig");
const window_functions = @import("window_functions.zig");

const DupBuffer = struct { cursor: [*]u8 };

fn roundEight(value: usize) usize {
    return (value + 7) & ~@as(usize, 7);
}

fn duplicateString(db: *types.Sqlite3, value: ?[*:0]const u8) ?[*:0]u8 {
    return db_allocator.stringDuplicate(db, value);
}

/// Source `exprDup()`.
pub fn duplicateExpressionInternal(db: *types.Sqlite3, source: *const parse_types.Expr, reduce: bool, supplied_buffer: ?*DupBuffer) ?*parse_types.Expr {
    var local_buffer: DupBuffer = undefined;
    const node_bytes: usize = @intCast(expression_analysis.duplicateExpressionStructSize(source, @intFromBool(reduce)) & 0x0fff);
    const token_bytes: usize = if (source.flags & 0x0000_0800 == 0 and source.u.zToken != null) std.mem.len(source.u.zToken.?) + 1 else 0;
    const static_flag: u32 = if (supplied_buffer != null) 0x0800_0000 else 0;
    if (supplied_buffer) |buffer| {
        local_buffer = buffer.*;
    } else {
        const allocation_bytes: usize = if (reduce)
            @intCast(expression_analysis.duplicateExpressionSize(source))
        else
            roundEight(@sizeOf(parse_types.Expr) + token_bytes);
        const raw = db_allocator.mallocRawNN(db, allocation_bytes) orelse return null;
        local_buffer.cursor = @ptrCast(raw);
    }
    const destination: *parse_types.Expr = @ptrCast(@alignCast(local_buffer.cursor));
    const source_bytes: [*]const u8 = @ptrCast(source);
    @memcpy(local_buffer.cursor[0..node_bytes], source_bytes[0..node_bytes]);
    if (!reduce and node_bytes < @sizeOf(parse_types.Expr)) @memset(local_buffer.cursor[node_bytes..@sizeOf(parse_types.Expr)], 0);
    destination.flags &= ~@as(u32, 0x0900_4000);
    destination.flags |= expression_analysis.duplicateExpressionStructSize(source, @intFromBool(reduce)) & 0x0001_4000;
    destination.flags |= static_flag;
    var consumed = node_bytes;
    if (token_bytes > 0) {
        const token_storage = local_buffer.cursor + node_bytes;
        @memcpy(token_storage[0..token_bytes], source.u.zToken.?[0..token_bytes]);
        destination.u.zToken = @ptrCast(token_storage);
        consumed += token_bytes;
    }
    local_buffer.cursor += roundEight(consumed);
    if (source.flags & (0x0001_0000 | 0x0080_0000) == 0) {
        if (source.usesSelect()) destination.x.pSelect = duplicateSelect(db, source.x.pSelect, reduce) else destination.x.pList = duplicateExpressionList(db, source.x.pList, if (source.op != tokens.tk_order) reduce else false);
        if (source.flags & parse_types.expr_flag.win_func != 0) destination.y.pWin = duplicateWindow(db, destination, source.y.pWin.?);
        if (source.op == tokens.tk_select_column) {
            destination.pLeft = source.pLeft;
        } else if (source.pLeft) |left| {
            destination.pLeft = if (reduce) duplicateExpressionInternal(db, left, true, &local_buffer) else duplicateExpression(db, left, false);
        }
        if (source.pRight) |right| destination.pRight = if (reduce) duplicateExpressionInternal(db, right, true, &local_buffer) else duplicateExpression(db, right, false);
    }
    if (supplied_buffer) |buffer| buffer.* = local_buffer;
    return destination;
}

pub fn duplicateExpression(db: *types.Sqlite3, source: ?*const parse_types.Expr, reduce: bool) ?*parse_types.Expr {
    return duplicateExpressionInternal(db, source orelse return null, reduce, null);
}

fn withSize(count: usize) usize {
    return @offsetOf(parse_types.With, "a") + count * @sizeOf(parse_types.Cte);
}

/// Source `sqlite3WithDup()`.
pub fn duplicateWith(db: *types.Sqlite3, source_optional: ?*const parse_types.With) ?*parse_types.With {
    const source = source_optional orelse return null;
    const raw = db_allocator.mallocZero(db, withSize(@intCast(source.nCte))) orelse return null;
    const result: *parse_types.With = @ptrCast(@alignCast(raw));
    result.nCte = source.nCte;
    for (result.items(), @constCast(source).items()) |*destination, item| {
        destination.pSelect = duplicateSelect(db, item.pSelect, false);
        destination.pCols = duplicateExpressionList(db, item.pCols, false);
        destination.zName = duplicateString(db, item.zName);
        destination.eM10d = item.eM10d;
    }
    return result;
}

/// Source `gatherSelectWindowsCallback()`.
pub fn gatherSelectWindowsCallback(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_function and expression.flags & parse_types.expr_flag.win_func != 0) {
        const select: *parse_types.Select = @ptrCast(@alignCast(walker.u.pointer.?));
        window_functions.linkWindow(select, expression.y.pWin.?);
    }
    return walker_api.continue_walk;
}

/// Source `gatherSelectWindowsSelectCallback()`.
pub fn gatherSelectWindowsSelectCallback(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    return if (select == @as(*parse_types.Select, @ptrCast(@alignCast(walker.u.pointer.?)))) walker_api.continue_walk else walker_api.prune;
}

/// Source `gatherSelectWindows()`.
fn gatherSelectWindows(select: *parse_types.Select) void {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = gatherSelectWindowsCallback;
    walker.xSelectCallback = gatherSelectWindowsSelectCallback;
    walker.u.pointer = select;
    _ = walker_api.walkSelect(&walker, select);
}

fn expressionListSize(capacity: usize) usize {
    return @offsetOf(parse_types.ExprList, "a") + capacity * @sizeOf(parse_types.ExprListItem);
}

/// Source `sqlite3ExprListDup()`.
pub fn duplicateExpressionList(db: *types.Sqlite3, source_optional: ?*const parse_types.ExprList, reduce: bool) ?*parse_types.ExprList {
    const source = source_optional orelse return null;
    const raw = db_allocator.mallocRawNN(db, expressionListSize(@intCast(source.nAlloc))) orelse return null;
    const result: *parse_types.ExprList = @ptrCast(@alignCast(raw));
    result.nExpr = source.nExpr;
    result.nAlloc = source.nAlloc;
    var prior_old: ?*const parse_types.Expr = null;
    var prior_new: ?*parse_types.Expr = null;
    for (result.items(), @constCast(source).items()) |*destination, item| {
        destination.pExpr = duplicateExpression(db, item.pExpr, reduce);
        if (item.pExpr) |old_expression| {
            if (old_expression.op == tokens.tk_select_column and destination.pExpr != null) {
                const new_expression = destination.pExpr.?;
                if (new_expression.pRight) |right| {
                    prior_old = old_expression.pRight;
                    prior_new = right;
                    new_expression.pLeft = right;
                } else {
                    if (old_expression.pLeft != prior_old) {
                        prior_old = old_expression.pLeft;
                        prior_new = duplicateExpression(db, prior_old, reduce);
                        new_expression.pRight = prior_new;
                    }
                    new_expression.pLeft = prior_new;
                }
            }
        }
        destination.zEName = duplicateString(db, item.zEName);
        destination.fg = item.fg;
        destination.u = item.u;
    }
    return result;
}

fn sourceListSize(count: usize) usize {
    return @offsetOf(parse_types.SrcList, "a") + count * @sizeOf(parse_types.SrcItem);
}

/// Source `sqlite3SrcListDup()`.
pub fn duplicateSourceList(db: *types.Sqlite3, source_optional: ?*const parse_types.SrcList, reduce: bool) ?*parse_types.SrcList {
    const source = source_optional orelse return null;
    const raw = db_allocator.mallocRawNN(db, sourceListSize(@intCast(source.nSrc))) orelse return null;
    const result: *parse_types.SrcList = @ptrCast(@alignCast(raw));
    result.nSrc = source.nSrc;
    result.nAlloc = @intCast(source.nSrc);
    for (result.items(), @constCast(source).items()) |*destination, item| {
        destination.* = std.mem.zeroes(parse_types.SrcItem);
        destination.fg = item.fg;
        if (item.fg.isSubquery) {
            const subquery_raw = db_allocator.mallocRaw(db, @sizeOf(parse_types.Subquery));
            if (subquery_raw) |present| {
                const subquery: *parse_types.Subquery = @ptrCast(@alignCast(present));
                subquery.* = item.u4.pSubq.?.*;
                subquery.pSelect = duplicateSelect(db, subquery.pSelect, reduce);
                if (subquery.pSelect == null) {
                    db_allocator.freeNN(db, subquery);
                    destination.fg.isSubquery = false;
                    destination.u4.pSubq = null;
                } else destination.u4.pSubq = subquery;
            } else {
                destination.fg.isSubquery = false;
                destination.u4.pSubq = null;
            }
        } else if (item.fg.fixedSchema) destination.u4.pSchema = item.u4.pSchema else destination.u4.zDatabase = duplicateString(db, item.u4.zDatabase);
        destination.zName = duplicateString(db, item.zName);
        destination.zAlias = duplicateString(db, item.zAlias);
        destination.iCursor = item.iCursor;
        if (item.fg.isIndexedBy) destination.u1.zIndexedBy = duplicateString(db, item.u1.zIndexedBy) else if (item.fg.isTabFunc) destination.u1.pFuncArg = duplicateExpressionList(db, item.u1.pFuncArg, reduce) else destination.u1.nRow = item.u1.nRow;
        destination.u2 = item.u2;
        if (item.fg.isCte) destination.u2.pCteUse.?.use_count += 1;
        destination.pSTab = item.pSTab;
        if (destination.pSTab) |table| table.reference_count += 1;
        if (item.fg.isUsing) destination.u3.pUsing = duplicateIdentifierList(db, item.u3.pUsing) else destination.u3.pOn = duplicateExpression(db, item.u3.pOn, reduce);
        destination.colUsed = item.colUsed;
    }
    return result;
}

fn identifierListSize(count: usize) usize {
    return @offsetOf(parse_types.IdList, "a") + count * @sizeOf(parse_types.IdListItem);
}

/// Source `sqlite3IdListDup()`.
pub fn duplicateIdentifierList(db: *types.Sqlite3, source_optional: ?*const parse_types.IdList) ?*parse_types.IdList {
    const source = source_optional orelse return null;
    const raw = db_allocator.mallocRawNN(db, identifierListSize(@intCast(source.nId))) orelse return null;
    const result: *parse_types.IdList = @ptrCast(@alignCast(raw));
    result.nId = source.nId;
    for (result.items(), @constCast(source).items()) |*destination, item| destination.zName = duplicateString(db, item.zName);
    return result;
}

/// Source `sqlite3SelectDup()`.
pub fn duplicateSelect(db: *types.Sqlite3, source_initial: ?*const parse_types.Select, reduce: bool) ?*parse_types.Select {
    var source = source_initial;
    var result: ?*parse_types.Select = null;
    var destination_link = &result;
    var next: ?*parse_types.Select = null;
    while (source) |item| : (source = item.pPrior) {
        const raw = db_allocator.mallocRawNN(db, @sizeOf(parse_types.Select)) orelse break;
        const destination: *parse_types.Select = @ptrCast(@alignCast(raw));
        destination.* = std.mem.zeroes(parse_types.Select);
        destination.pEList = duplicateExpressionList(db, item.pEList, reduce);
        destination.pSrc = duplicateSourceList(db, item.pSrc, reduce);
        destination.pWhere = duplicateExpression(db, item.pWhere, reduce);
        destination.pGroupBy = duplicateExpressionList(db, item.pGroupBy, reduce);
        destination.pHaving = duplicateExpression(db, item.pHaving, reduce);
        destination.pOrderBy = duplicateExpressionList(db, item.pOrderBy, reduce);
        destination.op = item.op;
        destination.pNext = next;
        destination.pLimit = duplicateExpression(db, item.pLimit, reduce);
        destination.selFlags = item.selFlags;
        destination.nSelectRow = item.nSelectRow;
        destination.pWith = duplicateWith(db, item.pWith);
        destination.pWinDefn = duplicateWindowList(db, item.pWinDefn);
        if (item.pWin != null and db.mallocFailed == 0) gatherSelectWindows(destination);
        destination.selId = item.selId;
        if (db.mallocFailed != 0) {
            destination.pNext = null;
            @import("compiler_ownership.zig").deleteSelect(db, destination);
            break;
        }
        destination_link.* = destination;
        destination_link = &destination.pPrior;
        next = destination;
    }
    return result;
}

/// Source `sqlite3WindowDup()`.
pub fn duplicateWindow(db: *types.Sqlite3, owner: ?*parse_types.Expr, source: *const parse_types.Window) ?*parse_types.Window {
    const raw = db_allocator.mallocZero(db, @sizeOf(parse_types.Window)) orelse return null;
    const result: *parse_types.Window = @ptrCast(@alignCast(raw));
    result.name = duplicateString(db, source.name);
    result.base_name = duplicateString(db, source.base_name);
    result.filter = duplicateExpression(db, source.filter, false);
    result.function = source.function;
    result.partition_by = duplicateExpressionList(db, source.partition_by, false);
    result.order_by = duplicateExpressionList(db, source.order_by, false);
    result.frame_type = source.frame_type;
    result.end_type = source.end_type;
    result.start_type = source.start_type;
    result.exclusion = source.exclusion;
    result.result_register = source.result_register;
    result.accumulator_register = source.accumulator_register;
    result.argument_column = source.argument_column;
    result.ephemeral_cursor = source.ephemeral_cursor;
    result.expression_arguments = source.expression_arguments;
    result.start = duplicateExpression(db, source.start, false);
    result.end = duplicateExpression(db, source.end, false);
    result.owner = owner;
    result.implicit_frame = source.implicit_frame;
    return result;
}

/// Source `sqlite3WindowListDup()`.
pub fn duplicateWindowList(db: *types.Sqlite3, source_initial: ?*const parse_types.Window) ?*parse_types.Window {
    var source = source_initial;
    var result: ?*parse_types.Window = null;
    var link = &result;
    while (source) |item| : (source = item.next) {
        link.* = duplicateWindow(db, null, item);
        if (link.* == null) break;
        link = &link.*.?.next;
    }
    return result;
}

/// Source `sqlite3UpsertDup()`.
pub fn duplicateUpsert(db: *types.Sqlite3, source_optional: ?*const parse_types.Upsert) ?*parse_types.Upsert {
    const source = source_optional orelse return null;
    return @import("upsert_analysis.zig").newUpsert(db, duplicateExpressionList(db, source.pUpsertTarget, false), duplicateExpression(db, source.pUpsertTargetWhere, false), duplicateExpressionList(db, source.pUpsertSet, false), duplicateExpression(db, source.pUpsertWhere, false), duplicateUpsert(db, source.pNextUpsert));
}
