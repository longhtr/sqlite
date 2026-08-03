//! Source-faithful recursive compiler/schema ownership destruction.

const std = @import("std");
const ast = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const runtime = @import("vdbe_types.zig");
const db_allocator = @import("db_allocator.zig");
const memory = @import("../memory.zig");

fn free(db: *runtime.Sqlite3, pointer: anytype) void {
    if (pointer) |owned| db_allocator.freeNN(db, @ptrCast(owned));
}

pub fn deleteExpression(db: *runtime.Sqlite3, expression: ?*ast.Expr) void {
    if (expression) |owned| deleteExpressionRequired(db, owned);
}

fn deleteExpressionRequired(db: *runtime.Sqlite3, initial: *ast.Expr) void {
    var expression = initial;
    while (true) {
        std.debug.assert(!expression.has(ast.expr_flag.win_func) or expression.y.pWin != null or db.mallocFailed != 0);
        if (!expression.has(ast.expr_flag.token_only | ast.expr_flag.leaf)) {
            std.debug.assert((expression.usesList() and expression.x.pList == null) or expression.pRight == null);
            if (expression.pRight) |right| {
                std.debug.assert(!expression.has(ast.expr_flag.win_func));
                deleteExpressionRequired(db, right);
            } else if (expression.usesSelect()) {
                std.debug.assert(!expression.has(ast.expr_flag.win_func));
                deleteSelect(db, expression.x.pSelect);
            } else {
                deleteExpressionList(db, expression.x.pList);
                if (expression.has(ast.expr_flag.win_func)) deleteWindow(db, expression.y.pWin);
            }
            if (expression.pLeft) |left| {
                if (expression.op != ast.expression_opcode.select_column and
                    !expression.has(ast.expr_flag.static) and
                    !left.has(ast.expr_flag.static))
                {
                    db_allocator.freeNN(db, @ptrCast(expression));
                    expression = left;
                    continue;
                }
                if (expression.op != ast.expression_opcode.select_column) deleteExpressionRequired(db, left);
            }
        }
        if (!expression.has(ast.expr_flag.static)) db_allocator.freeNN(db, @ptrCast(expression));
        return;
    }
}

pub fn deleteExpressionList(db: *runtime.Sqlite3, list: ?*ast.ExprList) void {
    const owned = list orelse return;
    std.debug.assert(owned.nExpr > 0);
    for (owned.items()) |item| {
        deleteExpression(db, item.pExpr);
        free(db, item.zEName);
    }
    db_allocator.freeNN(db, @ptrCast(owned));
}

pub fn unlinkWindow(window: *ast.Window) void {
    if (window.owner_link) |link| {
        link.* = window.next;
        if (window.next) |next| next.owner_link = link;
        window.owner_link = null;
    }
}

pub fn deleteWindow(db: *runtime.Sqlite3, window_optional: ?*ast.Window) void {
    const window = window_optional orelse return;
    unlinkWindow(window);
    deleteExpression(db, window.filter);
    deleteExpressionList(db, window.partition_by);
    deleteExpressionList(db, window.order_by);
    deleteExpression(db, window.end);
    deleteExpression(db, window.start);
    free(db, window.name);
    free(db, window.base_name);
    db_allocator.freeNN(db, @ptrCast(window));
}

pub fn deleteWindowList(db: *runtime.Sqlite3, first: ?*ast.Window) void {
    var current = first;
    while (current) |window| {
        const next = window.next;
        deleteWindow(db, window);
        current = next;
    }
}

pub fn deleteIdentifierList(db: *runtime.Sqlite3, list_optional: ?*ast.IdList) void {
    const list = list_optional orelse return;
    for (list.items()) |item| free(db, item.zName);
    db_allocator.freeNN(db, @ptrCast(list));
}

fn clearCte(db: *runtime.Sqlite3, cte: *ast.Cte) void {
    deleteExpressionList(db, cte.pCols);
    deleteSelect(db, cte.pSelect);
    free(db, cte.zName);
}

pub fn deleteWith(db: *runtime.Sqlite3, with_optional: ?*ast.With) void {
    const with = with_optional orelse return;
    for (with.items()) |*cte| clearCte(db, cte);
    db_allocator.freeNN(db, @ptrCast(with));
}

pub fn deleteSelect(db: *runtime.Sqlite3, select_optional: ?*ast.Select) void {
    var current = select_optional;
    while (current) |select| {
        const prior = select.pPrior;
        deleteExpressionList(db, select.pEList);
        deleteSourceList(db, select.pSrc);
        deleteExpression(db, select.pWhere);
        deleteExpressionList(db, select.pGroupBy);
        deleteExpression(db, select.pHaving);
        deleteExpressionList(db, select.pOrderBy);
        deleteExpression(db, select.pLimit);
        deleteWith(db, select.pWith);
        deleteWindowList(db, select.pWinDefn);
        while (select.pWin) |window| {
            std.debug.assert(window.owner_link == &select.pWin);
            unlinkWindow(window);
        }
        db_allocator.freeNN(db, @ptrCast(select));
        current = prior;
    }
}

pub fn deleteSourceList(db: *runtime.Sqlite3, list_optional: ?*ast.SrcList) void {
    const list = list_optional orelse return;
    for (list.items()) |*item| {
        std.debug.assert(!item.fg.isIndexedBy or !item.fg.isTabFunc);
        std.debug.assert(!item.fg.isCte or !item.fg.isIndexedBy);
        std.debug.assert(!item.fg.fixedSchema or !item.fg.isSubquery);
        free(db, item.zName);
        free(db, item.zAlias);
        if (item.fg.isSubquery) {
            const subquery = item.u4.pSubq.?;
            deleteSelect(db, subquery.pSelect);
            db_allocator.freeNN(db, @ptrCast(subquery));
        } else if (!item.fg.fixedSchema) {
            free(db, item.u4.zDatabase);
        }
        if (item.fg.isIndexedBy) free(db, item.u1.zIndexedBy);
        if (item.fg.isTabFunc) deleteExpressionList(db, item.u1.pFuncArg);
        deleteTable(db, if (item.pSTab) |table| @ptrCast(table) else null);
        if (item.fg.isUsing) deleteIdentifierList(db, item.u3.pUsing) else deleteExpression(db, item.u3.pOn);
    }
    db_allocator.freeNN(db, @ptrCast(list));
}

pub fn deleteTable(db: *runtime.Sqlite3, table_optional: ?*schema.Table) void {
    const table = table_optional orelse return;
    if (db.pnBytesFreed == null) {
        std.debug.assert(table.reference_count > 0);
        table.reference_count -= 1;
        if (table.reference_count > 0) return;
    }

    deleteIndexes(db, table);
    switch (table.kind) {
        .ordinary => deleteForeignKeys(db, table),
        .virtual => clearVirtualTable(db, table),
        .view => deleteSelect(db, if (table.owner.view.query) |query| @ptrCast(@alignCast(query)) else null),
    }
    deleteColumns(db, table);
    free(db, table.name);
    free(db, table.column_affinities);
    deleteExpressionList(db, if (table.checks) |checks| @ptrCast(@alignCast(checks)) else null);
    db_allocator.freeNN(db, @ptrCast(table));
}

fn deleteIndexes(db: *runtime.Sqlite3, table: *schema.Table) void {
    var current = table.indexes;
    while (current) |index| {
        const next = index.next;
        if (db.pnBytesFreed == null and table.kind != .virtual) {
            const owner = index.schema.?;
            _ = owner.index_hash.insert(memory.processAllocator(), index.name.?, null);
        }
        deleteExpression(db, if (index.partial_predicate) |expression| @ptrCast(@alignCast(expression)) else null);
        deleteExpressionList(db, if (index.column_expressions) |expressions| @ptrCast(@alignCast(expressions)) else null);
        free(db, index.column_affinities);
        if (index.isResized()) free(db, index.collations);
        db_allocator.freeNN(db, @ptrCast(index));
        current = next;
    }
}

fn deleteForeignKeys(db: *runtime.Sqlite3, table: *schema.Table) void {
    var current = table.owner.ordinary.foreign_keys;
    while (current) |foreign_key| {
        const next = foreign_key.next_from;
        if (db.pnBytesFreed == null) {
            if (foreign_key.previous_to) |previous| {
                previous.next_to = foreign_key.next_to;
            } else {
                const key = if (foreign_key.next_to) |following| following.target_table.? else foreign_key.target_table.?;
                const replacement: ?*anyopaque = if (foreign_key.next_to) |following| @ptrCast(following) else null;
                _ = table.schema.?.foreign_key_hash.insert(memory.processAllocator(), key, replacement);
            }
            if (foreign_key.next_to) |following| following.previous_to = foreign_key.previous_to;
        }
        deleteForeignKeyTrigger(db, foreign_key.triggers[0]);
        deleteForeignKeyTrigger(db, foreign_key.triggers[1]);
        db_allocator.freeNN(db, @ptrCast(foreign_key));
        current = next;
    }
}

fn deleteForeignKeyTrigger(db: *runtime.Sqlite3, trigger_optional: ?*schema.Trigger) void {
    const opaque_trigger = trigger_optional orelse return;
    const trigger: *ast.Trigger = @ptrCast(@alignCast(opaque_trigger));
    const step = trigger.steps.?;
    deleteSourceList(db, step.sources);
    deleteExpression(db, step.where);
    deleteExpressionList(db, step.expressions);
    deleteSelect(db, step.select);
    deleteExpression(db, trigger.when);
    db_allocator.freeNN(db, @ptrCast(trigger));
}

fn disconnectVirtualTables(table: *schema.Table) void {
    var current: ?*runtime.VTable = if (table.owner.virtual.instances) |first| @ptrCast(@alignCast(first)) else null;
    table.owner.virtual.instances = null;
    while (current) |virtual_table| {
        const next = virtual_table.pNext;
        const db = virtual_table.db.?;
        virtual_table.pNext = db.pDisconnect;
        db.pDisconnect = virtual_table;
        current = next;
    }
}

fn clearVirtualTable(db: *runtime.Sqlite3, table: *schema.Table) void {
    if (db.pnBytesFreed == null) disconnectVirtualTables(table);
    if (table.owner.virtual.arguments) |arguments| {
        for (arguments[0..@intCast(table.owner.virtual.argument_count)], 0..) |argument, index| {
            if (index != 1) free(db, argument);
        }
        db_allocator.freeNN(db, @ptrCast(arguments));
    }
}

fn deleteColumns(db: *runtime.Sqlite3, table: *schema.Table) void {
    if (table.columns) |columns| {
        for (columns[0..@intCast(table.column_count)]) |column| free(db, column.name_and_metadata);
        db_allocator.freeNN(db, @ptrCast(columns));
        if (table.kind == .ordinary) deleteExpressionList(db, if (table.owner.ordinary.default_expressions) |expressions| @ptrCast(@alignCast(expressions)) else null);
        if (db.pnBytesFreed == null) {
            table.columns = null;
            table.column_count = 0;
            if (table.kind == .ordinary) table.owner.ordinary.default_expressions = null;
        }
    }
}
