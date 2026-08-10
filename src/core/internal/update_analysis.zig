//! UPDATE dependency analysis for expressions and indexes from `insert.c` and `update.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const walker_api = @import("walker.zig");

pub const IndexListTerm = extern struct { index: ?*schema.Index, original_position: c_int };
pub const IndexIterator = extern struct {
    list_type: c_int,
    position: c_int,
    data: extern union {
        linked: extern struct { index: ?*schema.Index },
        array: extern struct { count: c_int, items: ?[*]IndexListTerm },
    },
};

/// Source `indexIteratorFirst()`.
pub fn indexIteratorFirst(iterator: *IndexIterator, original_position: *c_int) ?*schema.Index {
    if (iterator.list_type != 0) {
        original_position.* = iterator.data.array.items.?[0].original_position;
        return iterator.data.array.items.?[0].index;
    }
    original_position.* = 0;
    return iterator.data.linked.index;
}

/// Source `indexIteratorNext()`.
pub fn indexIteratorNext(iterator: *IndexIterator, original_position: *c_int) ?*schema.Index {
    if (iterator.list_type != 0) {
        iterator.position += 1;
        if (iterator.position >= iterator.data.array.count) {
            original_position.* = iterator.position;
            return null;
        }
        const term = iterator.data.array.items.?[@intCast(iterator.position)];
        original_position.* = term.original_position;
        return term.index;
    }
    original_position.* += 1;
    iterator.data.linked.index = iterator.data.linked.index.?.next;
    return iterator.data.linked.index;
}

/// Source `checkConstraintExprNode()`.
pub fn checkConstraintExpression(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_column) {
        if (expression.iColumn >= 0) {
            const changes: [*]const c_int = @ptrCast(@alignCast(walker.u.pointer.?));
            if (changes[@intCast(expression.iColumn)] >= 0) walker.eCode |= 0x01;
        } else walker.eCode |= 0x02;
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3ExprReferencesUpdatedColumn()`.
pub fn expressionReferencesUpdatedColumn(expression: *parse_types.Expr, changes: [*]const c_int, rowid_changed: bool) bool {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = checkConstraintExpression;
    walker.u.pointer = @ptrCast(@constCast(changes));
    _ = walker_api.walkExpr(&walker, expression);
    if (!rowid_changed) walker.eCode &= ~@as(u16, 0x02);
    return walker.eCode != 0;
}

/// Source `indexColumnIsBeingUpdated()`.
pub fn indexColumnIsBeingUpdated(index: *schema.Index, column_position: c_int, changes: [*]const c_int, rowid_changed: bool) bool {
    const column = index.columns.?[@intCast(column_position)];
    if (column >= 0) return changes[@intCast(column)] >= 0;
    const expressions: *parse_types.ExprList = @ptrCast(@alignCast(index.column_expressions.?));
    return expressionReferencesUpdatedColumn(expressions.items()[@intCast(column_position)].pExpr.?, changes, rowid_changed);
}

/// Source `indexWhereClauseMightChange()`.
pub fn indexWhereClauseMightChange(index: *schema.Index, changes: [*]const c_int, rowid_changed: bool) bool {
    const predicate_opaque = index.partial_predicate orelse return false;
    const predicate: *parse_types.Expr = @ptrCast(@alignCast(predicate_opaque));
    return expressionReferencesUpdatedColumn(predicate, changes, rowid_changed);
}
