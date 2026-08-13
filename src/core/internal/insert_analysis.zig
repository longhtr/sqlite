//! INSERT affinity and VALUES analysis from `insert.c`.

const std = @import("std");
const db_allocator = @import("db_allocator.zig");
const expression_analysis = @import("expression_analysis.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const types = @import("vdbe_types.zig");
const tokens = @import("../generated/tokens.zig");
const walker_api = @import("walker.zig");

/// Source `readsTable()`.
pub fn readsTable(parse: *parse_types.Parse, database_index: c_int, table: *schema.Table) bool {
    const machine: *types.Vdbe = @ptrCast(@alignCast(parse.pVdbe orelse return false));
    var index: usize = 1;
    while (index < machine.nOp) : (index += 1) {
        const operation = &machine.aOp.?[index];
        if (operation.opcode == .OpenRead and operation.p3 == database_index) {
            const root_page: u32 = @intCast(operation.p2);
            if (root_page == table.root_page) return true;
            var table_index = table.indexes;
            while (table_index) |present| : (table_index = present.next) if (root_page == present.root_page) return true;
        }
        if (table.kind == .virtual and operation.opcode == .VOpen and table.owner.virtual.instances != null and operation.p4.pVtab == @as(*types.VTable, @ptrCast(@alignCast(table.owner.virtual.instances.?))).pVtab) return true;
    }
    return false;
}

/// Source `exprColumnFlagUnion()`.
pub fn expressionColumnFlagUnion(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    if (node.op == tokens.tk_column and node.iColumn >= 0) {
        const table: *schema.Table = @ptrCast(@alignCast(walker.u.pointer.?));
        std.debug.assert(node.iColumn < table.column_count);
        walker.eCode |= table.columns.?[@intCast(node.iColumn)].flags;
    }
    return walker_api.continue_walk;
}

/// Source `computeIndexAffStr()`.
pub fn computeIndexAffinity(db: *types.Sqlite3, index: *schema.Index) ?[*:0]u8 {
    const raw = db_allocator.mallocRaw(null, @as(u64, index.column_count) + 1) orelse {
        _ = db_allocator.oomFault(db);
        return null;
    };
    const result: [*]u8 = @ptrCast(raw);
    index.column_affinities = @ptrCast(result);
    for (0..index.column_count) |position| {
        const column = index.columns.?[position];
        var affinity_value: u8 = if (column >= 0)
            index.table.?.columns.?[@intCast(column)].affinity
        else if (column == -1)
            schema_analysis.affinity.integer
        else
            expression_analysis.expressionAffinity((@as(*parse_types.ExprList, @ptrCast(@alignCast(index.column_expressions.?)))).items()[position].pExpr.?);
        affinity_value = @max(affinity_value, schema_analysis.affinity.blob);
        affinity_value = @min(affinity_value, schema_analysis.affinity.numeric);
        result[position] = affinity_value;
    }
    result[index.column_count] = 0;
    return @ptrCast(result);
}

/// Source `sqlite3TableAffinityStr()`.
pub fn tableAffinityString(db: ?*types.Sqlite3, table: *const schema.Table) ?[*:0]u8 {
    const raw = db_allocator.mallocRaw(db, @as(u64, @intCast(table.column_count)) + 1) orelse return null;
    const result: [*]u8 = @ptrCast(raw);
    var count: usize = 0;
    for (table.columns.?[0..@intCast(table.column_count)]) |column| {
        if (column.flags & 0x0020 == 0) {
            result[count] = column.affinity;
            count += 1;
        }
    }
    result[count] = 0;
    while (count > 0 and result[count - 1] <= schema_analysis.affinity.blob) {
        count -= 1;
        result[count] = 0;
    }
    return @ptrCast(result);
}

/// Source `exprListIsConstant()`.
pub fn expressionListIsConstant(parse: *parse_types.Parse, row: *parse_types.ExprList) bool {
    for (row.items()) |item| if (!expression_analysis.isConstant(parse, item.pExpr.?)) return false;
    return true;
}

/// Source `exprListIsNoAffinity()`.
pub fn expressionListHasNoAffinity(parse: *parse_types.Parse, row: *parse_types.ExprList) bool {
    if (!expressionListIsConstant(parse, row)) return false;
    for (row.items()) |item| if (expression_analysis.expressionAffinity(item.pExpr.?) != 0) return false;
    return true;
}
