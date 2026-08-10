//! UPSERT allocation and ownership from `upsert.c`.

const compiler_ownership = @import("compiler_ownership.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const types = @import("vdbe_types.zig");

/// Source `sqlite3UpsertNextIsIPK()`.
pub fn nextTargetsIntegerPrimaryKey(upsert: *parse_types.Upsert) bool {
    var next = upsert.pNextUpsert;
    while (next) |present| {
        if (present.pUpsertTarget == null or present.pUpsertIdx == null) return true;
        if (present.isDup == 0) return false;
        next = present.pNextUpsert;
    }
    return true;
}

/// Source `sqlite3UpsertOfIndex()`.
pub fn forIndex(upsert_initial: ?*parse_types.Upsert, index: ?*parse_types.Index) ?*parse_types.Upsert {
    var upsert = upsert_initial;
    while (upsert != null and upsert.?.pUpsertTarget != null and upsert.?.pUpsertIdx != index) upsert = upsert.?.pNextUpsert;
    return upsert;
}

/// Source `upsertDelete()`.
pub fn deleteUpsertList(db: *types.Sqlite3, first: *parse_types.Upsert) void {
    var current: ?*parse_types.Upsert = first;
    while (current) |upsert| {
        const next = upsert.pNextUpsert;
        compiler_ownership.deleteExpressionList(db, upsert.pUpsertTarget);
        compiler_ownership.deleteExpression(db, upsert.pUpsertTargetWhere);
        compiler_ownership.deleteExpressionList(db, upsert.pUpsertSet);
        compiler_ownership.deleteExpression(db, upsert.pUpsertWhere);
        db_allocator.free(db, upsert.pToFree);
        db_allocator.freeNN(db, upsert);
        current = next;
    }
}

/// Source `sqlite3UpsertNew()`.
pub fn newUpsert(
    db: *types.Sqlite3,
    target: ?*parse_types.ExprList,
    target_where: ?*parse_types.Expr,
    assignments: ?*parse_types.ExprList,
    where: ?*parse_types.Expr,
    next: ?*parse_types.Upsert,
) ?*parse_types.Upsert {
    const raw = db_allocator.mallocZero(db, @sizeOf(parse_types.Upsert)) orelse {
        compiler_ownership.deleteExpressionList(db, target);
        compiler_ownership.deleteExpression(db, target_where);
        compiler_ownership.deleteExpressionList(db, assignments);
        compiler_ownership.deleteExpression(db, where);
        if (next) |present| deleteUpsertList(db, present);
        return null;
    };
    const result: *parse_types.Upsert = @ptrCast(@alignCast(raw));
    result.pUpsertTarget = target;
    result.pUpsertTargetWhere = target_where;
    result.pUpsertSet = assignments;
    result.pUpsertWhere = where;
    result.isDoUpdate = @intFromBool(assignments != null);
    result.pNextUpsert = next;
    return result;
}
