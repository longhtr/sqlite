//! Expression and comparison affinity analysis from `expr.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const opcodes = @import("../generated/opcodes.zig");
const numeric = @import("../numeric.zig");
const sqlite_float = @import("../float.zig");
const sqlite_string = @import("../string.zig");
const db_allocator = @import("db_allocator.zig");
const parse_error = @import("parse_error.zig");
const function_registry = @import("function_registry.zig");
const collation_registry = @import("collation_registry.zig");
const collation = @import("collation.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const parse_types = @import("parse_types.zig");
const parse_cleanup = @import("parse_cleanup.zig");
const rename_analysis = @import("rename_analysis.zig");
const schema_analysis = @import("schema_analysis.zig");
const schema = @import("schema_types.zig");
const types = @import("vdbe_types.zig");
const vdbe_api = @import("vdbe_api.zig");
const vdbe_aux = @import("vdbe_aux.zig");
const mem = @import("vdbe_mem.zig");
const walker_api = @import("walker.zig");

/// Source `sqlite3ExprAddCollateToken()`.
pub fn addCollationToken(parse: *const parse_types.Parse, expression: *parse_types.Expr, collation_name: *const parse_types.Token, dequote: bool) *parse_types.Expr {
    if (collation_name.n == 0) return expression;
    const parse_db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const collate = allocateExpression(parse_db, @intCast(tokens.tk_collate), collation_name, dequote) orelse return expression;
    collate.pLeft = expression;
    collate.flags |= 0x0000_2200;
    return collate;
}

/// Source `sqlite3ExprCollSeq()`.
pub fn expressionCollation(parse: *parse_types.Parse, expression_initial: ?*const parse_types.Expr) ?*types.CollSeq {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var expression = expression_initial;
    var result: ?*types.CollSeq = null;
    while (expression) |present| {
        const operation = if (present.op == tokens.tk_register) present.op2 else present.op;
        if ((operation == tokens.tk_agg_column and present.y.pTab != null) or operation == tokens.tk_column or operation == tokens.tk_trigger) {
            if (present.iColumn >= 0) {
                const name = schema_analysis.columnCollation(&present.y.pTab.?.columns.?[@intCast(present.iColumn)]);
                result = collation_registry.findCollation(db, db.enc, name, false);
            }
            break;
        }
        if (operation == tokens.tk_cast or operation == tokens.tk_uplus) {
            expression = present.pLeft;
            continue;
        }
        if (operation == tokens.tk_vector or (operation == tokens.tk_function and present.affExpr == 0x58)) {
            expression = present.x.pList.?.items()[0].pExpr;
            continue;
        }
        if (operation == tokens.tk_collate) {
            result = collation_registry.getCollation(parse, db.enc, null, present.u.zToken.?);
            break;
        }
        if (present.flags & 0x0000_0200 == 0) break;
        if (present.pLeft != null and present.pLeft.?.flags & 0x0000_0200 != 0) {
            expression = present.pLeft;
        } else {
            var next = present.pRight;
            if (present.usesList() and present.x.pList != null and db.mallocFailed == 0) {
                for (present.x.pList.?.items()) |item| {
                    if (item.pExpr.?.flags & 0x0000_0200 != 0) {
                        next = item.pExpr;
                        break;
                    }
                }
            }
            expression = next;
        }
    }
    if (collation_registry.checkCollation(parse, result) != 0) return null;
    return result;
}

/// Source `sqlite3ExprNNCollSeq()`.
pub fn expressionNonNullCollation(parse: *parse_types.Parse, expression: *const parse_types.Expr) *types.CollSeq {
    return expressionCollation(parse, expression) orelse @as(*types.Sqlite3, @ptrCast(@alignCast(parse.db.?))).pDfltColl.?;
}

/// Source `sqlite3ExprCollSeqMatch()`.
pub fn expressionCollationsMatch(parse: *parse_types.Parse, first: *const parse_types.Expr, second: *const parse_types.Expr) bool {
    return sqlite_string.compareInternal(expressionNonNullCollation(parse, first).zName.?, expressionNonNullCollation(parse, second).zName.?) == 0;
}

/// Source `binaryCompareP5()`.
pub fn binaryCompareP5(first: *const parse_types.Expr, second: *const parse_types.Expr, jump_if_null: c_int) u8 {
    return @intCast(compareAffinity(first, expressionAffinity(second)) | @as(u8, @intCast(jump_if_null)));
}

/// Source `sqlite3BinaryCompareCollSeq()`.
pub fn binaryComparisonCollation(parse: *parse_types.Parse, left: *const parse_types.Expr, right: ?*const parse_types.Expr) ?*types.CollSeq {
    if (left.flags & 0x0000_0200 != 0) return expressionCollation(parse, left);
    if (right) |present| if (present.flags & 0x0000_0200 != 0) return expressionCollation(parse, present);
    return expressionCollation(parse, left) orelse expressionCollation(parse, right);
}

/// Source `sqlite3ExprCompareCollSeq()`.
pub fn expressionComparisonCollation(parse: *parse_types.Parse, expression: *const parse_types.Expr) ?*types.CollSeq {
    return if (expression.flags & 0x0000_0400 != 0)
        binaryComparisonCollation(parse, expression.pRight.?, expression.pLeft)
    else
        binaryComparisonCollation(parse, expression.pLeft.?, expression.pRight);
}

/// Source `codeCompare()`.
pub fn codeComparison(parse: *parse_types.Parse, left: *parse_types.Expr, right: *parse_types.Expr, opcode: opcodes.Opcode, first_register: c_int, second_register: c_int, destination: c_int, jump_if_null: c_int, commuted: bool) c_int {
    if (parse.nErr != 0) return 0;
    const machine: *types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    const collation_sequence = if (commuted) binaryComparisonCollation(parse, right, left) else binaryComparisonCollation(parse, left, right);
    const p5 = binaryCompareP5(left, right, jump_if_null);
    const address = vdbe_aux.addOperation4(machine, opcode, second_register, destination, first_register, if (collation_sequence) |collation_value| @ptrCast(collation_value) else null, types.p4.collseq);
    vdbe_aux.changeP5(machine, p5);
    return address;
}

/// Source `sqlite3ExprAffinity()`.
pub fn expressionAffinity(expression_initial: *const parse_types.Expr) u8 {
    var expression = expression_initial;
    var operation: u8 = expression.op;
    while (true) {
        if (operation == tokens.tk_column or (operation == tokens.tk_agg_column and expression.y.pTab != null)) {
            const table: *schema.Table = @ptrCast(@alignCast(expression.y.pTab.?));
            return schema_analysis.tableColumnAffinity(table, expression.iColumn);
        }
        if (operation == tokens.tk_select) return expressionAffinity(expression.x.pSelect.?.pEList.?.items()[0].pExpr.?);
        if (operation == tokens.tk_cast) return schema_analysis.affinityType(expression.u.zToken.?, null);
        if (operation == tokens.tk_select_column) return expressionAffinity(expression.pLeft.?.x.pSelect.?.pEList.?.items()[@intCast(expression.iColumn)].pExpr.?);
        if (operation == tokens.tk_vector or (operation == tokens.tk_function and expression.affExpr == 0x58)) return expressionAffinity(expression.x.pList.?.items()[0].pExpr.?);
        if (expression.flags & (0x002000 | 0x040000) != 0) {
            expression = expression.pLeft.?;
            operation = expression.op;
            continue;
        }
        if (operation != tokens.tk_register) break;
        operation = expression.op2;
        if (operation == tokens.tk_register) break;
    }
    return expression.affExpr;
}

/// Source `sqlite3ExprCheckHeight()`.
pub fn checkHeight(parse: *parse_types.Parse, height: c_int) bool {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const maximum = db.aLimit[3];
    if (height <= maximum) return false;
    var buffer: [96]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Expression tree is too large (maximum depth {d})", .{maximum}) catch "Expression tree is too large";
    setExpressionError(parse, message);
    return true;
}

/// Source `heightOfExpr()`.
pub fn heightOfExpression(expression: ?*const parse_types.Expr, height: *c_int) void {
    if (expression) |present| height.* = @max(height.*, present.nHeight);
}

/// Source `heightOfExprList()`.
pub fn heightOfExpressionList(list: ?*const parse_types.ExprList, height: *c_int) void {
    if (list) |present| for (@constCast(present).items()) |item| heightOfExpression(item.pExpr, height);
}

/// Source `heightOfSelect()`.
pub fn heightOfSelect(select_initial: ?*const parse_types.Select, height: *c_int) void {
    var select = select_initial;
    while (select) |present| : (select = present.pPrior) {
        heightOfExpression(present.pWhere, height);
        heightOfExpression(present.pHaving, height);
        heightOfExpression(present.pLimit, height);
        heightOfExpressionList(present.pEList, height);
        heightOfExpressionList(present.pGroupBy, height);
        heightOfExpressionList(present.pOrderBy, height);
    }
}

/// Source `exprSetHeight()`.
pub fn setHeight(expression: *parse_types.Expr) void {
    var height: c_int = if (expression.pLeft) |left| left.nHeight else 0;
    if (expression.pRight) |right| height = @max(height, right.nHeight);
    if (expression.usesSelect()) heightOfSelect(expression.x.pSelect, &height) else if (expression.x.pList) |list| {
        heightOfExpressionList(list, &height);
        expression.flags |= expressionListFlags(list) & 0x0040_0208;
    }
    expression.nHeight = height + 1;
}

/// Source `sqlite3ExprSetHeightAndFlags()`.
pub fn setHeightAndFlags(parse: *parse_types.Parse, expression: *parse_types.Expr) void {
    if (parse.nErr != 0) return;
    setHeight(expression);
    _ = checkHeight(parse, expression.nHeight);
}

/// Source `codeReal()`.
pub fn codeReal(machine: *types.Vdbe, text: [*:0]const u8, negate: bool, destination: c_int) void {
    var value = sqlite_float.parse(text).value;
    std.debug.assert(!std.math.isNan(value));
    if (negate) value = -value;
    _ = vdbe_aux.addOperation4Duplicate8(machine, .Real, 0, destination, 0, std.mem.asBytes(&value), types.p4.real);
}

/// Source `codeInteger()`.
pub fn codeInteger(parse: *parse_types.Parse, expression_node: *parse_types.Expr, negate: bool, destination: c_int) void {
    const machine: *types.Vdbe = @ptrCast(@alignCast(parse.pVdbe.?));
    if (expression_node.flags & 0x0000_0800 != 0) {
        const value = if (negate) -expression_node.u.iValue else expression_node.u.iValue;
        _ = vdbe_aux.addOperation2(machine, .Integer, value, destination);
        return;
    }
    const text = expression_node.u.zToken.?;
    const parsed = numeric.parseDecimalOrHex(text);
    if (parsed.code == 2 or (parsed.code == 3 and !negate) or (negate and parsed.value == std.math.minInt(i64))) {
        codeReal(machine, text, negate, destination);
        return;
    }
    const value: i64 = if (negate) if (parsed.code == 3) std.math.minInt(i64) else -parsed.value else parsed.value;
    _ = vdbe_aux.addOperation4Duplicate8(machine, .Int64, 0, destination, 0, std.mem.asBytes(&value), types.p4.int64);
}

/// Source `sqlite3SelectExprHeight()`.
pub fn selectExpressionHeight(select: *const parse_types.Select) c_int {
    var height: c_int = 0;
    heightOfSelect(select, &height);
    return height;
}

/// Source `sqlite3ExprAssignVarNumber()`.
pub fn assignVariableNumber(parse: *parse_types.Parse, expression_node: ?*parse_types.Expr, name_length: u32) void {
    const node = expression_node orelse return;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const name = node.u.zToken.?;
    var number: c_int = 0;
    var add_name = false;
    if (name[1] == 0) {
        parse.nVar += 1;
        number = parse.nVar;
    } else if (name[0] == '?') {
        const digits = name[1..name_length];
        number = std.fmt.parseInt(c_int, digits, 10) catch 0;
        const maximum = db.aLimit[9];
        if (number < 1 or number > maximum) {
            var buffer: [128]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "variable number must be between ?1 and ?{d}", .{maximum}) catch "variable number out of range";
            setExpressionError(parse, message);
            if (node.flags & 0x4000_0000 == 0) db.errByteOffset = node.w.iOfst;
            return;
        }
        if (number > parse.nVar) {
            parse.nVar = @intCast(number);
            add_name = true;
        } else if (vdbe_api.vlistNumberToName(if (parse.pVList) |list| @ptrCast(@alignCast(list)) else null, number) == null) add_name = true;
    } else {
        number = vdbe_api.vlistNameToNumber(if (parse.pVList) |list| @ptrCast(@alignCast(list)) else null, name, @intCast(name_length));
        if (number == 0) {
            parse.nVar += 1;
            number = parse.nVar;
            add_name = true;
        }
    }
    if (add_name) parse.pVList = if (vdbe_api.vlistAdd(db, if (parse.pVList) |list| @ptrCast(@alignCast(list)) else null, name, @intCast(name_length), number)) |list| @ptrCast(list) else parse.pVList;
    node.iColumn = @intCast(number);
    if (number > db.aLimit[9]) {
        setExpressionError(parse, "too many SQL variables");
        if (node.flags & 0x4000_0000 == 0) db.errByteOffset = node.w.iOfst;
    }
}

/// Source `isCandidateForInOpt()`.
pub fn candidateForInOptimization(expression_node: *const parse_types.Expr) ?*parse_types.Select {
    if (!expression_node.usesSelect() or expression_node.flags & parse_types.expr_flag.variable_select != 0) return null;
    const select = expression_node.x.pSelect.?;
    if (select.pPrior != null or select.selFlags & 0x0000_0009 != 0 or select.pLimit != null or select.pWhere != null) return null;
    const sources = select.pSrc.?;
    if (sources.nSrc != 1 or sources.items()[0].fg.isSubquery or sources.items()[0].pSTab.?.kind == .virtual) return null;
    for (select.pEList.?.items()) |item| {
        const result = item.pExpr.?;
        if (result.op != tokens.tk_column or result.iTable != sources.items()[0].iCursor) return null;
    }
    return select;
}

fn expressionListAllocationSize(capacity: usize) usize {
    return @offsetOf(parse_types.ExprList, "a") + capacity * @sizeOf(parse_types.ExprListItem);
}

/// Source `sqlite3ExprListAppendNew()`.
pub fn appendNewExpressionList(db: *types.Sqlite3, expression: ?*parse_types.Expr) ?*parse_types.ExprList {
    const raw = db_allocator.mallocRawNN(db, expressionListAllocationSize(4)) orelse {
        compiler_ownership.deleteExpression(db, expression);
        return null;
    };
    const list: *parse_types.ExprList = @ptrCast(@alignCast(raw));
    list.nAlloc = 4;
    list.nExpr = 1;
    list.items()[0] = std.mem.zeroes(parse_types.ExprListItem);
    list.items()[0].pExpr = expression;
    return list;
}

/// Source `sqlite3ExprListAppendGrow()`.
pub fn growExpressionList(db: *types.Sqlite3, list_initial: *parse_types.ExprList, expression: ?*parse_types.Expr) ?*parse_types.ExprList {
    const capacity = list_initial.nAlloc * 2;
    const raw = db_allocator.realloc(db, list_initial, expressionListAllocationSize(@intCast(capacity))) orelse {
        compiler_ownership.deleteExpressionList(db, list_initial);
        compiler_ownership.deleteExpression(db, expression);
        return null;
    };
    const list: *parse_types.ExprList = @ptrCast(@alignCast(raw));
    list.nAlloc = capacity;
    const index: usize = @intCast(list.nExpr);
    list.nExpr += 1;
    list.items()[index] = std.mem.zeroes(parse_types.ExprListItem);
    list.items()[index].pExpr = expression;
    return list;
}

/// Source `sqlite3ExprListAppend()`.
pub fn appendExpressionList(parse: *parse_types.Parse, list_optional: ?*parse_types.ExprList, expression: ?*parse_types.Expr) ?*parse_types.ExprList {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const list = list_optional orelse return appendNewExpressionList(db, expression);
    if (list.nAlloc < list.nExpr + 1) return growExpressionList(db, list, expression);
    const index: usize = @intCast(list.nExpr);
    list.nExpr += 1;
    list.items()[index] = std.mem.zeroes(parse_types.ExprListItem);
    list.items()[index].pExpr = expression;
    return list;
}

/// Source `sqlite3ColumnSetExpr()`.
pub fn setColumnExpression(parse: *parse_types.Parse, table: *schema.Table, column: *schema.Column, expression: *parse_types.Expr) void {
    var list: ?*parse_types.ExprList = if (table.owner.ordinary.default_expressions) |present| @ptrCast(@alignCast(present)) else null;
    if (column.default_expression_index == 0 or list == null or list.?.nExpr < column.default_expression_index) {
        column.default_expression_index = if (list) |present| @intCast(present.nExpr + 1) else 1;
        list = appendExpressionList(parse, list, expression);
        table.owner.ordinary.default_expressions = if (list) |present| @ptrCast(present) else null;
    } else {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        const item = &list.?.items()[column.default_expression_index - 1];
        compiler_ownership.deleteExpression(db, item.pExpr);
        item.pExpr = expression;
    }
}

/// Source `sqlite3AddNotNull()`.
pub fn addNotNullConstraint(parse: *parse_types.Parse, conflict_action: c_int) void {
    const table = parse.pNewTable orelse return;
    if (table.column_count < 1) return;
    const column = &table.columns.?[@intCast(table.column_count - 1)];
    column.definition.not_null_action = @intCast(conflict_action);
    table.flags |= 0x0000_0800;
    if (column.flags & 0x0008 != 0) {
        var index = table.indexes;
        while (index) |present| : (index = present.next) {
            if (present.columns.?[0] == table.column_count - 1) present.properties.unique_not_null = true;
        }
    }
}

/// Source `sqlite3AddCollateType()`.
pub fn addColumnCollation(parse: *parse_types.Parse, token: *const parse_types.Token) void {
    const table = parse.pNewTable orelse return;
    if (parse.eParseMode >= 2) return;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const name = schema_analysis.nameFromToken(db, token) orelse return;
    defer db_allocator.freeNN(db, name);
    if (collation_registry.locateCollation(parse, name) == null) return;
    const column_number: i16 = table.column_count - 1;
    const column_index: usize = @intCast(column_number);
    schema_analysis.setColumnCollation(db, &table.columns.?[column_index], name);
    var index = table.indexes;
    while (index) |present| : (index = present.next) {
        if (present.columns.?[0] == column_number) present.collations.?[0] = schema_analysis.columnCollation(&table.columns.?[column_index]);
    }
}

/// Source `sqlite3ExprListCheckLength()`.
pub fn checkExpressionListLength(parse: *parse_types.Parse, list_optional: ?*parse_types.ExprList, object_name: [*:0]const u8) void {
    const list = list_optional orelse return;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (list.nExpr <= db.aLimit[2]) return;
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "too many columns in {s}", .{object_name}) catch "too many columns";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `bothImplyNotNullRow()`.
pub fn bothImplyNonNullRow(walker: *parse_types.Walker, first: ?*parse_types.Expr, second: ?*parse_types.Expr) void {
    if (walker.eCode != 0) return;
    _ = walker_api.walkExpr(walker, first);
    if (walker.eCode != 0) {
        walker.eCode = 0;
        _ = walker_api.walkExpr(walker, second);
    }
}

/// Source `impliesNotNullRow()`.
pub fn impliesNonNullRowCallback(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    if (expression_node.flags & 0x0000_0001 != 0) return walker_api.prune;
    if (expression_node.flags & 0x0000_0002 != 0 and walker.mWFlags != 0) return walker_api.prune;
    switch (expression_node.op) {
        tokens.tk_isnot, tokens.tk_isnull, tokens.tk_notnull, tokens.tk_is, tokens.tk_vector, tokens.tk_function, tokens.tk_truth, tokens.tk_case => return walker_api.prune,
        tokens.tk_column => {
            if (walker.u.counter == expression_node.iTable) {
                walker.eCode = 1;
                return walker_api.abort_walk;
            }
            return walker_api.prune;
        },
        tokens.tk_or, tokens.tk_and => {
            bothImplyNonNullRow(walker, expression_node.pLeft, expression_node.pRight);
            return walker_api.prune;
        },
        tokens.tk_in => {
            if (expression_node.usesList() and expression_node.x.pList.?.nExpr > 0) _ = walker_api.walkExpr(walker, expression_node.pLeft);
            return walker_api.prune;
        },
        tokens.tk_between => {
            _ = walker_api.walkExpr(walker, expression_node.pLeft);
            bothImplyNonNullRow(walker, expression_node.x.pList.?.items()[0].pExpr, expression_node.x.pList.?.items()[1].pExpr);
            return walker_api.prune;
        },
        tokens.tk_eq, tokens.tk_ne, tokens.tk_lt, tokens.tk_le, tokens.tk_gt, tokens.tk_ge => {
            const left = expression_node.pLeft.?;
            const right = expression_node.pRight.?;
            if ((left.op == tokens.tk_column and left.y.pTab != null and left.y.pTab.?.kind == .virtual) or
                (right.op == tokens.tk_column and right.y.pTab != null and right.y.pTab.?.kind == .virtual)) return walker_api.prune;
            return walker_api.continue_walk;
        },
        else => return walker_api.continue_walk,
    }
}

/// Source `sqlite3ExprImpliesNonNullRow()`.
pub fn expressionImpliesNonNullRow(expression_initial: ?*parse_types.Expr, table_cursor: c_int, right_join: bool) bool {
    var expression = skipCollationAndLikely(expression_initial) orelse return false;
    if (expression.op == tokens.tk_notnull) expression = expression.pLeft.? else {
        while (expression.op == tokens.tk_and) {
            if (expressionImpliesNonNullRow(expression.pLeft, table_cursor, right_join)) return true;
            expression = expression.pRight.?;
        }
    }
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = impliesNonNullRowCallback;
    walker.mWFlags = @intFromBool(right_join);
    walker.u.counter = table_cursor;
    _ = walker_api.walkExpr(&walker, expression);
    return walker.eCode != 0;
}

pub const ReferenceSourceContext = struct {
    db: *types.Sqlite3,
    references: ?*parse_types.SrcList,
    exclude_count: usize = 0,
    excluded: ?[*]c_int = null,
};

/// Source `selectRefEnter()`.
pub fn enterReferenceSelect(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    const context: *ReferenceSourceContext = @ptrCast(@alignCast(walker.u.pointer.?));
    const sources = select.pSrc.?;
    if (sources.nSrc == 0) return walker_api.continue_walk;
    const old_count = context.exclude_count;
    context.exclude_count += @intCast(sources.nSrc);
    const bytes = context.exclude_count * @sizeOf(c_int);
    const raw = db_allocator.realloc(context.db, if (context.excluded) |excluded| @ptrCast(excluded) else null, bytes) orelse {
        context.exclude_count = 0;
        return walker_api.abort_walk;
    };
    context.excluded = @ptrCast(@alignCast(raw));
    for (sources.items(), old_count..) |source, index| context.excluded.?[index] = source.iCursor;
    return walker_api.continue_walk;
}

fn leaveReferenceSelect(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) void {
    const context: *ReferenceSourceContext = @ptrCast(@alignCast(walker.u.pointer.?));
    if (context.exclude_count != 0) context.exclude_count -= @intCast(select.pSrc.?.nSrc);
}

/// Source `exprRefToSrcList()`.
pub fn expressionReferenceToSourceList(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_column or expression.op == tokens.tk_agg_column) {
        const context: *ReferenceSourceContext = @ptrCast(@alignCast(walker.u.pointer.?));
        if (context.references) |references| {
            for (references.items()) |source| {
                if (expression.iTable == source.iCursor) {
                    walker.eCode |= 1;
                    return walker_api.continue_walk;
                }
            }
        }
        var found = false;
        if (context.excluded) |excluded| {
            for (excluded[0..context.exclude_count]) |cursor| if (cursor == expression.iTable) {
                found = true;
                break;
            };
        }
        if (!found) walker.eCode |= 2;
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3ReferencesSrcList()`.
pub fn referencesSourceList(parse: *parse_types.Parse, expression: *parse_types.Expr, sources: ?*parse_types.SrcList) c_int {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var context = ReferenceSourceContext{ .db = db, .references = sources };
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = expressionReferenceToSourceList;
    walker.xSelectCallback = enterReferenceSelect;
    walker.xSelectCallback2 = leaveReferenceSelect;
    walker.u.pointer = &context;
    _ = walker_api.walkExprList(&walker, expression.x.pList);
    if (expression.pLeft) |order| _ = walker_api.walkExprList(&walker, order.x.pList);
    if (expression.flags & parse_types.expr_flag.win_func != 0) _ = walker_api.walkExpr(&walker, expression.y.pWin.?.filter);
    db_allocator.free(db, if (context.excluded) |excluded| @ptrCast(excluded) else null);
    if (walker.eCode & 1 != 0) return 1;
    if (walker.eCode != 0) return 0;
    return -1;
}

pub const IndexCoverage = struct {
    index: *schema.Index,
    cursor: c_int,
};

/// Source `exprIdxCover()`.
pub fn indexCoverageCallback(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    const coverage: *const IndexCoverage = @ptrCast(@alignCast(walker.u.pointer.?));
    if (expression_node.op == tokens.tk_column and expression_node.iTable == coverage.cursor and schema_analysis.tableColumnToIndex(coverage.index, expression_node.iColumn) < 0) {
        walker.eCode = 1;
        return walker_api.abort_walk;
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3ExprCoveredByIndex()`.
pub fn expressionCoveredByIndex(expression_node: *parse_types.Expr, cursor: c_int, index: *schema.Index) bool {
    var coverage = IndexCoverage{ .index = index, .cursor = cursor };
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = indexCoverageCallback;
    walker.u.pointer = &coverage;
    _ = walker_api.walkExpr(&walker, expression_node);
    return walker.eCode == 0;
}

/// Source `sqlite3ExprListSetName()`.
pub fn setExpressionListName(parse: *parse_types.Parse, list_optional: ?*parse_types.ExprList, name: *const parse_types.Token, dequote: bool) void {
    const list = list_optional orelse return;
    const item = &list.items()[@intCast(list.nExpr - 1)];
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    item.zEName = db_allocator.stringNDuplicate(db, name.z, @intCast(name.n));
    if (dequote and item.zEName != null) {
        sqlite_string.dequote(item.zEName);
        if (parse.eParseMode >= 2) _ = rename_analysis.mapToken(parse, item.zEName, name);
    }
}

/// Source `sqlite3ExprListSetSpan()`.
pub fn setExpressionListSpan(parse: *parse_types.Parse, list_optional: ?*parse_types.ExprList, start: [*]const u8, end: [*]const u8) void {
    const list = list_optional orelse return;
    const item = &list.items()[@intCast(list.nExpr - 1)];
    if (item.zEName == null) {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        item.zEName = db_allocator.spanDuplicate(db, start, end);
        item.fg.eEName = 2;
    }
}

/// Source `sqlite3ExprListSetSortOrder()`.
pub fn setExpressionListSortOrder(list_optional: ?*parse_types.ExprList, sort_order_initial: c_int, null_order: c_int) void {
    const list = list_optional orelse return;
    var sort_order = sort_order_initial;
    const item = &list.items()[@intCast(list.nExpr - 1)];
    if (sort_order < 0) sort_order = 0;
    item.fg.sortFlags = @intCast(sort_order);
    if (null_order >= 0) {
        item.fg.bNulls = true;
        if (sort_order != null_order) item.fg.sortFlags |= 0x02;
    }
}

/// Source `sqlite3ExprListFlags()`.
pub fn expressionListFlags(list: *parse_types.ExprList) u32 {
    var flags: u32 = 0;
    for (list.items()) |item| flags |= item.pExpr.?.flags;
    return flags;
}

/// Source `sqlite3ExprDataType()`.
pub fn expressionDataType(expression_optional: ?*const parse_types.Expr) c_int {
    var expression = expression_optional;
    while (expression) |present| {
        switch (present.op) {
            tokens.tk_collate, tokens.tk_if_null_row, tokens.tk_uplus => expression = present.pLeft,
            tokens.tk_null => expression = null,
            tokens.tk_string => return 0x02,
            tokens.tk_blob => return 0x04,
            tokens.tk_concat => return 0x06,
            tokens.tk_variable, tokens.tk_agg_function, tokens.tk_function => return 0x07,
            tokens.tk_column, tokens.tk_agg_column, tokens.tk_select, tokens.tk_cast, tokens.tk_select_column, tokens.tk_vector => {
                const value = expressionAffinity(present);
                if (value >= schema_analysis.affinity.numeric) return 0x05;
                if (value == schema_analysis.affinity.text) return 0x06;
                return 0x07;
            },
            tokens.tk_case => {
                const list = present.x.pList.?;
                var result: c_int = 0;
                var index: usize = 1;
                while (index < list.nExpr) : (index += 2) result |= expressionDataType(list.items()[index].pExpr);
                if (list.nExpr & 1 != 0) result |= expressionDataType(list.items()[@intCast(list.nExpr - 1)].pExpr);
                return result;
            },
            else => return 0x01,
        }
    }
    return 0;
}

/// Source `sqlite3ExprSkipCollate()`.
pub fn skipCollation(expression_initial: ?*parse_types.Expr) ?*parse_types.Expr {
    var expression = expression_initial;
    while (expression != null and expression.?.flags & 0x002000 != 0) expression = expression.?.pLeft;
    return expression;
}

/// Source `sqlite3ExprSkipCollateAndLikely()`.
pub fn skipCollationAndLikely(expression_initial: ?*parse_types.Expr) ?*parse_types.Expr {
    var expression = expression_initial;
    while (expression) |present| {
        if (present.flags & (0x002000 | 0x080000) == 0) break;
        if (present.flags & 0x080000 != 0) expression = present.x.pList.?.items()[0].pExpr else if (present.op == tokens.tk_collate) expression = present.pLeft else break;
    }
    return expression;
}

/// Source `sqlite3ExprIsVector()`.
pub fn isVector(expression: *const parse_types.Expr) bool {
    return vectorSize(expression) > 1;
}

/// Source `sqlite3ExprVectorSize()`.
pub fn vectorSize(expression: *const parse_types.Expr) c_int {
    const operation = if (expression.op == tokens.tk_register) expression.op2 else expression.op;
    if (operation == tokens.tk_vector) return expression.x.pList.?.nExpr;
    if (operation == tokens.tk_select) return expression.x.pSelect.?.pEList.?.nExpr;
    return 1;
}

/// Source `sqlite3VectorFieldSubexpr()`.
pub fn vectorFieldSubexpression(vector: *parse_types.Expr, index: c_int) *parse_types.Expr {
    if (isVector(vector)) {
        if (vector.op == tokens.tk_select or vector.op2 == tokens.tk_select) return vector.x.pSelect.?.pEList.?.items()[@intCast(index)].pExpr.?;
        return vector.x.pList.?.items()[@intCast(index)].pExpr.?;
    }
    return vector;
}

/// Source `exprImpliesNotNull()`.
pub fn impliesNotNull(parse: ?*const parse_types.Parse, expression: *const parse_types.Expr, nonnull: *const parse_types.Expr, table_cursor: c_int, seen_not_initial: bool) bool {
    if (compareExpressions(parse, expression, nonnull, table_cursor) == 0) return nonnull.op != tokens.tk_null;
    var seen_not = seen_not_initial;
    switch (expression.op) {
        tokens.tk_in => {
            if (seen_not and expression.usesSelect()) return false;
            return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, true);
        },
        tokens.tk_between => {
            if (seen_not) return false;
            const list = expression.x.pList.?;
            if (impliesNotNull(parse, list.items()[0].pExpr.?, nonnull, table_cursor, true) or impliesNotNull(parse, list.items()[1].pExpr.?, nonnull, table_cursor, true)) return true;
            return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, true);
        },
        tokens.tk_eq, tokens.tk_ne, tokens.tk_lt, tokens.tk_le, tokens.tk_gt, tokens.tk_ge, tokens.tk_plus, tokens.tk_minus, tokens.tk_bitor, tokens.tk_lshift, tokens.tk_rshift, tokens.tk_concat => {
            seen_not = true;
            if (impliesNotNull(parse, expression.pRight.?, nonnull, table_cursor, seen_not)) return true;
            return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, seen_not);
        },
        tokens.tk_star, tokens.tk_rem, tokens.tk_bitand, tokens.tk_slash => {
            if (impliesNotNull(parse, expression.pRight.?, nonnull, table_cursor, seen_not)) return true;
            return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, seen_not);
        },
        tokens.tk_span, tokens.tk_collate, tokens.tk_uplus, tokens.tk_uminus => return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, seen_not),
        tokens.tk_truth => {
            if (seen_not or expression.op2 != tokens.tk_is) return false;
            return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, true);
        },
        tokens.tk_bitnot, tokens.tk_not => return impliesNotNull(parse, expression.pLeft.?, nonnull, table_cursor, true),
        else => return false,
    }
}

/// Source `sqlite3ExprImpliesExpr()`.
pub fn expressionImpliesExpression(parse: ?*const parse_types.Parse, first: *const parse_types.Expr, second: *const parse_types.Expr, table_cursor: c_int) bool {
    if (compareExpressions(parse, first, second, table_cursor) == 0) return true;
    if (second.op == tokens.tk_or and (expressionImpliesExpression(parse, first, second.pLeft.?, table_cursor) or expressionImpliesExpression(parse, first, second.pRight.?, table_cursor))) return true;
    if (second.op == tokens.tk_notnull and impliesNotNull(parse, first, second.pLeft.?, table_cursor, false)) return true;
    if (parse != null and isIif(@ptrCast(@alignCast(parse.?.db.?)), first)) return expressionImpliesExpression(parse, first.x.pList.?.items()[0].pExpr.?, second, table_cursor);
    return false;
}

/// Source `sqlite3WindowCompare()`.
pub fn compareWindows(parse: ?*const parse_types.Parse, first: ?*const parse_types.Window, second: ?*const parse_types.Window, compare_filter: bool) c_int {
    const left = first orelse return 1;
    const right = second orelse return 1;
    if (left.frame_type != right.frame_type or left.start_type != right.start_type or left.end_type != right.end_type or left.exclusion != right.exclusion) return 1;
    if (compareExpressions(parse, left.start, right.start, -1) != 0) return 1;
    if (compareExpressions(parse, left.end, right.end, -1) != 0) return 1;
    var result = compareExpressionLists(left.partition_by, right.partition_by, -1);
    if (result != 0) return result;
    result = compareExpressionLists(left.order_by, right.order_by, -1);
    if (result != 0) return result;
    if (compare_filter) return compareExpressions(parse, left.filter, right.filter, -1);
    return 0;
}

/// Source `sqlite3ExprCompare()`.
pub fn compareExpressions(parse: ?*const parse_types.Parse, first_optional: ?*const parse_types.Expr, second_optional: ?*const parse_types.Expr, table_cursor: c_int) c_int {
    const first = first_optional orelse return if (second_optional == null) 0 else 2;
    const second = second_optional orelse return 2;
    if (parse != null and first.op == tokens.tk_variable) return 2;
    const combined_flags = first.flags | second.flags;
    if (combined_flags & 0x0000_0800 != 0) {
        if (first.flags & second.flags & 0x0000_0800 != 0 and first.u.iValue == second.u.iValue) return 0;
        return 2;
    }
    if (first.op != second.op or first.op == tokens.tk_raise) {
        if (first.op == tokens.tk_collate and compareExpressions(parse, first.pLeft, second, table_cursor) < 2) return 1;
        if (second.op == tokens.tk_collate and compareExpressions(parse, first, second.pLeft, table_cursor) < 2) return 1;
        if (!(first.op == tokens.tk_agg_column and second.op == tokens.tk_column and second.iTable < 0 and first.iTable == table_cursor)) return 2;
    }
    if (first.u.zToken) |first_token| {
        if (first.op == tokens.tk_function or first.op == tokens.tk_agg_function) {
            const second_token = second.u.zToken orelse return 2;
            if (sqlite_string.compareInternal(first_token, second_token) != 0) return 2;
            if ((first.flags & parse_types.expr_flag.win_func != 0) != (second.flags & parse_types.expr_flag.win_func != 0)) return 2;
            if (first.flags & parse_types.expr_flag.win_func != 0 and compareWindows(parse, first.y.pWin, second.y.pWin, true) != 0) return 2;
        } else if (first.op == tokens.tk_null) return 0 else if (first.op == tokens.tk_collate) {
            if (second.u.zToken == null or sqlite_string.compareInternal(first_token, second.u.zToken.?) != 0) return 2;
        } else if (second.u.zToken != null and first.op != tokens.tk_column and first.op != tokens.tk_agg_column and !std.mem.eql(u8, std.mem.span(first_token), std.mem.span(second.u.zToken.?))) return 2;
    }
    if (first.flags & 0x0000_0404 != second.flags & 0x0000_0404) return 2;
    if (combined_flags & 0x0001_0000 == 0) {
        if (combined_flags & 0x0000_1000 != 0) return 2;
        if (combined_flags & 0x0000_0020 == 0 and compareExpressions(parse, first.pLeft, second.pLeft, table_cursor) != 0) return 2;
        if (compareExpressions(parse, first.pRight, second.pRight, table_cursor) != 0) return 2;
        if (compareExpressionLists(first.x.pList, second.x.pList, table_cursor) != 0) return 2;
        if (first.op != tokens.tk_string and first.op != tokens.tk_truefalse and combined_flags & 0x0000_4000 == 0) {
            if (first.iColumn != second.iColumn) return 2;
            if (first.op == tokens.tk_truth and first.op2 != second.op2) return 2;
            if (first.op != tokens.tk_in and first.iTable != second.iTable and first.iTable != table_cursor) return 2;
        }
    }
    return 0;
}

/// Source `sqlite3ExprListCompare()`.
pub fn compareExpressionLists(first_optional: ?*const parse_types.ExprList, second_optional: ?*const parse_types.ExprList, table_cursor: c_int) c_int {
    if (first_optional == null and second_optional == null) return 0;
    const first = first_optional orelse return 1;
    const second = second_optional orelse return 1;
    if (first.nExpr != second.nExpr) return 1;
    for (@constCast(first).items(), @constCast(second).items()) |left, right| {
        if (left.fg.sortFlags != right.fg.sortFlags) return 1;
        const result = compareExpressions(null, left.pExpr, right.pExpr, table_cursor);
        if (result != 0) return result;
    }
    return 0;
}

/// Source `sqlite3ExprCompareSkip()`.
pub fn compareExpressionsSkipCollation(first: *parse_types.Expr, second: *parse_types.Expr, table_cursor: c_int) c_int {
    return compareExpressions(null, skipCollation(first), skipCollation(second), table_cursor);
}

/// Source `sqlite3ExprFunctionUsable()`.
pub fn checkFunctionUsable(parse: *parse_types.Parse, expression_node: *const parse_types.Expr, definition: *const types.FuncDef) void {
    if (expression_node.flags & parse_types.expr_flag.from_ddl == 0 and parse.prepFlags & 0x20 == 0) return;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (definition.funcFlags & types.function_flag.direct == 0 and db.flags & types.connection_flag.trusted_schema != 0) return;
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "unsafe use of {s}()", .{expression_node.u.zToken.?}) catch "unsafe use of function";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `sqlite3ExprAttachSubtrees()`.
pub fn attachExpressionSubtrees(db: *types.Sqlite3, root_optional: ?*parse_types.Expr, left: ?*parse_types.Expr, right: ?*parse_types.Expr) void {
    const root = root_optional orelse {
        compiler_ownership.deleteExpression(db, left);
        compiler_ownership.deleteExpression(db, right);
        return;
    };
    if (right) |present| {
        root.pRight = present;
        root.flags |= present.flags & 0x0040_0208;
        root.nHeight = present.nHeight + 1;
    } else root.nHeight = 1;
    if (left) |present| {
        root.pLeft = present;
        root.flags |= present.flags & 0x0040_0208;
        if (present.nHeight >= root.nHeight) root.nHeight = present.nHeight + 1;
    }
}

/// Source `sqlite3PExpr()`.
/// Source `sqlite3ExprToRegister()`.
pub fn expressionToRegister(expression_node: *parse_types.Expr, register: c_int) void {
    const node = skipCollationAndLikely(expression_node) orelse return;
    if (node.op == tokens.tk_register) {
        std.debug.assert(node.iTable == register);
        return;
    }
    node.op2 = node.op;
    node.op = @intCast(tokens.tk_register);
    node.iTable = register;
    node.flags &= ~@as(u32, 0x0020_0000);
}

pub fn parsedExpression(parse: *parse_types.Parse, operation: c_int, left: ?*parse_types.Expr, right: ?*parse_types.Expr) ?*parse_types.Expr {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocRawNN(db, @sizeOf(parse_types.Expr)) orelse {
        compiler_ownership.deleteExpression(db, left);
        compiler_ownership.deleteExpression(db, right);
        return null;
    };
    const result: *parse_types.Expr = @ptrCast(@alignCast(raw));
    result.* = std.mem.zeroes(parse_types.Expr);
    result.op = @intCast(operation & 0xff);
    result.iAgg = -1;
    attachExpressionSubtrees(db, result, left, right);
    _ = checkHeight(parse, result.nHeight);
    return result;
}

/// Source `sqlite3PExprAddSelect()`.
pub fn addSelectToExpression(parse: *parse_types.Parse, expression_optional: ?*parse_types.Expr, select: ?*parse_types.Select) void {
    if (expression_optional) |expression| {
        expression.x.pSelect = select;
        expression.flags |= 0x0040_1000;
        setHeightAndFlags(parse, expression);
    } else {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        compiler_ownership.deleteSelect(db, select);
    }
}

/// Source `sqlite3ExprFunction()`.
pub fn functionExpression(parse: *parse_types.Parse, arguments: ?*parse_types.ExprList, token: *const parse_types.Token, distinct: c_int) ?*parse_types.Expr {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const expression = allocateExpression(db, @intCast(tokens.tk_function), token, true) orelse {
        compiler_ownership.deleteExpressionList(db, arguments);
        return null;
    };
    expression.w.iOfst = @intCast(@intFromPtr(token.z.?) - @intFromPtr(parse.zTail.?));
    if (arguments != null and arguments.?.nExpr > db.aLimit[6] and parse.nested == 0) {
        var buffer: [256]u8 = undefined;
        const name = expression.u.zToken.?;
        const message = std.fmt.bufPrint(&buffer, "too many arguments on function {s}", .{name}) catch "too many arguments on function";
        db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
        parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
        parse.nErr += 1;
        parse.rc = 1;
    }
    expression.x.pList = arguments;
    expression.flags |= 0x0000_0008;
    setHeightAndFlags(parse, expression);
    if (distinct == 1) expression.flags |= 0x0000_0004;
    return expression;
}

/// Source `sqlite3ExprDeferredDelete()`.
pub fn deferExpressionDelete(parse: *parse_types.Parse, expression: *parse_types.Expr) bool {
    return parse_cleanup.add(parse, parse_cleanup.expressionCallback, expression) == null;
}

/// Source `sqlite3ExprAnd()`.
pub fn andExpression(parse: *parse_types.Parse, left_optional: ?*parse_types.Expr, right_optional: ?*parse_types.Expr) ?*parse_types.Expr {
    const left = left_optional orelse return right_optional;
    const right = right_optional orelse return left;
    const flags = left.flags | right.flags;
    if (flags & 0x2000_000b == 0x2000_0000 and parse.eParseMode < 2) {
        _ = deferExpressionDelete(parse, left);
        _ = deferExpressionDelete(parse, right);
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        return integerExpression(db, 0);
    }
    return parsedExpression(parse, @intCast(tokens.tk_and), left, right);
}

/// Source `sqlite3ExprSetErrorOffset()`.
pub fn setErrorOffset(expression: ?*parse_types.Expr, offset: c_int) void {
    const present = expression orelse return;
    if (present.flags & 0x0000_0003 != 0) return;
    present.w.iOfst = offset;
}

/// Source `sqlite3ExprAlloc()`.
pub fn allocateExpression(db: *types.Sqlite3, operation: c_int, token: ?*const parse_types.Token, dequote: bool) ?*parse_types.Expr {
    const extra: usize = if (token) |present| @as(usize, present.n) + 1 else 0;
    const raw = db_allocator.mallocRawNN(db, @sizeOf(parse_types.Expr) + extra) orelse return null;
    const expression: *parse_types.Expr = @ptrCast(@alignCast(raw));
    expression.* = std.mem.zeroes(parse_types.Expr);
    expression.op = @intCast(operation);
    expression.iAgg = -1;
    if (token) |present| {
        const storage: [*]u8 = @ptrFromInt(@intFromPtr(expression) + @sizeOf(parse_types.Expr));
        const length: usize = @intCast(present.n);
        if (length > 0) @memcpy(storage[0..length], present.z.?[0..length]);
        storage[length] = 0;
        expression.u.zToken = @ptrCast(storage);
        if (dequote and (storage[0] == '\'' or storage[0] == '\"' or storage[0] == '`' or storage[0] == '[')) {
            var view = sqlite_string.ExpressionTokenView{ .text = @ptrCast(storage), .flags = expression.flags };
            sqlite_string.dequoteExpression(&view);
            expression.flags = view.flags;
        }
    }
    expression.nHeight = 1;
    return expression;
}

/// Source `sqlite3Expr()` forwarding constructor used by internal source owners.
pub fn newExpression(db: *types.Sqlite3, operation: c_int, token_text: ?[*:0]const u8) ?*parse_types.Expr {
    var token = parse_types.Token{ .z = if (token_text) |text| text else null, .n = if (token_text) |text| @intCast(std.mem.len(text)) else 0 };
    return allocateExpression(db, operation, &token, false);
}

/// Source `exprStructSize()`.
pub fn expressionStructSize(expression: *const parse_types.Expr) c_int {
    if (expression.flags & 0x0001_0000 != 0) return parse_types.Expr.token_only_size;
    if (expression.flags & 0x0000_4000 != 0) return parse_types.Expr.reduced_size;
    return parse_types.Expr.full_size;
}

/// Source `dupedExprStructSize()`.
pub fn duplicateExpressionStructSize(expression: *const parse_types.Expr, flags: c_int) c_int {
    if (flags == 0 or expression.flags & 0x0002_0000 != 0) return parse_types.Expr.full_size;
    if (expression.pLeft != null or (expression.usesList() and expression.x.pList != null)) return parse_types.Expr.reduced_size | 0x0000_4000;
    return parse_types.Expr.token_only_size | 0x0001_0000;
}

fn roundEight(value: c_int) c_int {
    return (value + 7) & ~@as(c_int, 7);
}

/// Source `dupedExprNodeSize()`.
pub fn duplicateExpressionNodeSize(expression: *const parse_types.Expr, flags: c_int) c_int {
    var bytes = duplicateExpressionStructSize(expression, flags) & 0x0fff;
    if (expression.flags & 0x0000_0800 == 0) {
        if (expression.u.zToken) |token| bytes += @intCast(std.mem.len(token) + 1);
    }
    return roundEight(bytes);
}

/// Source `dupedExprSize()`.
pub fn duplicateExpressionSize(expression: *const parse_types.Expr) c_int {
    var bytes = duplicateExpressionNodeSize(expression, 1);
    if (expression.pLeft) |left| bytes += duplicateExpressionSize(left);
    if (expression.pRight) |right| bytes += duplicateExpressionSize(right);
    return bytes;
}

/// Source `exprEvalRhsFirst()`.
pub fn evaluateRightHandSideFirst(expression: *const parse_types.Expr) bool {
    return expression.pLeft.?.flags & 0x0040_0000 != 0 and expression.pRight.?.flags & 0x0040_0000 == 0;
}

/// Source `sqlite3ExprInt32()`.
pub fn integerExpression(db: *types.Sqlite3, value: c_int) ?*parse_types.Expr {
    const storage = db_allocator.mallocRawNN(db, @sizeOf(parse_types.Expr)) orelse return null;
    const expression: *parse_types.Expr = @ptrCast(@alignCast(storage));
    expression.* = std.mem.zeroes(parse_types.Expr);
    expression.op = @intCast(tokens.tk_integer);
    expression.iAgg = -1;
    expression.flags = 0x0000_0800 | 0x0080_0000 | if (value != 0) @as(u32, 0x1000_0000) else 0x2000_0000;
    expression.u.iValue = value;
    expression.nHeight = 1;
    return expression;
}

fn alwaysTrue(expression: *const parse_types.Expr) bool {
    return expression.flags & (0x0000_0001 | 0x1000_0000) == 0x1000_0000;
}
fn alwaysFalse(expression: *const parse_types.Expr) bool {
    return expression.flags & (0x0000_0001 | 0x2000_0000) == 0x2000_0000;
}

/// Source `sqlite3ExprSimplifiedAndOr()`.
pub fn simplifiedAndOr(expression: *parse_types.Expr) *parse_types.Expr {
    if (expression.op == tokens.tk_and or expression.op == tokens.tk_or) {
        const right = simplifiedAndOr(expression.pRight.?);
        const left = simplifiedAndOr(expression.pLeft.?);
        if (alwaysTrue(left) or alwaysFalse(right)) return if (expression.op == tokens.tk_and) right else left;
        if (alwaysTrue(right) or alwaysFalse(left)) return if (expression.op == tokens.tk_and) left else right;
    }
    return expression;
}

/// Source `sqlite3IsTrueOrFalse()`.
pub fn isTrueOrFalse(text: [*:0]const u8) u32 {
    if (sqlite_string.compareInternal(text, "true") == 0) return 0x1000_0000;
    if (sqlite_string.compareInternal(text, "false") == 0) return 0x2000_0000;
    return 0;
}

/// Source `sqlite3ExprIdToTrueFalse()`.
pub fn identifierToTrueFalse(expression: *parse_types.Expr) bool {
    if (expression.flags & (0x0008_00 | 0x0400_0000) != 0) return false;
    const flags = isTrueOrFalse(expression.u.zToken.?);
    if (flags == 0) return false;
    expression.op = @intCast(tokens.tk_truefalse);
    expression.flags |= flags;
    return true;
}

/// Source `sqlite3ExprTruthValue()`.
pub fn truthValue(expression_initial: *parse_types.Expr) bool {
    const expression = skipCollationAndLikely(expression_initial).?;
    return expression.u.zToken.?[4] == 0;
}

/// Source `sqlite3ExprIsInteger()`.
pub fn isInteger(expression_optional: ?*const parse_types.Expr, output: *c_int, parse: ?*parse_types.Parse) bool {
    const expression = expression_optional orelse return false;
    if (expression.flags & 0x0000_0800 != 0) {
        output.* = expression.u.iValue;
        return true;
    }
    switch (expression.op) {
        tokens.tk_uplus => return isInteger(expression.pLeft, output, null),
        tokens.tk_uminus => {
            var value: c_int = 0;
            if (!isInteger(expression.pLeft, &value, null)) return false;
            output.* = -value;
            return true;
        },
        tokens.tk_variable => {
            const parse_present = parse orelse return false;
            const machine_opaque = parse_present.pVdbe orelse return false;
            const db: *types.Sqlite3 = @ptrCast(@alignCast(parse_present.db.?));
            if (db.flags & types.connection_flag.enable_qpsg != 0) return false;
            const machine: *types.Vdbe = @ptrCast(@alignCast(machine_opaque));
            vdbe_aux.setVariableMask(machine, expression.iColumn);
            const reprepare: ?*types.Vdbe = if (parse_present.pReprepare) |pointer| @ptrCast(@alignCast(pointer)) else null;
            const value = vdbe_aux.getBoundValue(reprepare, expression.iColumn, schema_analysis.affinity.blob) orelse return false;
            defer mem.valueFree(value);
            if (mem.valueType(value) != 1) return false;
            const integer = mem.valueInt64(value);
            if (integer != (integer & 0x7fff_ffff)) return false;
            output.* = @intCast(integer);
            return true;
        },
        else => return false,
    }
}

/// Source `sqlite3ExprIsNotTrue()`.
pub fn isNotTrue(expression: *parse_types.Expr) bool {
    if (expression.op == tokens.tk_null) return true;
    if (expression.op == tokens.tk_truefalse and !truthValue(expression)) return true;
    var value: c_int = 1;
    return isInteger(expression, &value, null) and value == 0;
}

/// Source `sqlite3ExprIsIIF()`.
pub fn isIif(db: *types.Sqlite3, expression: *const parse_types.Expr) bool {
    if (expression.op == tokens.tk_function) {
        const name = expression.u.zToken.?;
        if (name[0] != 'i' and name[0] != 'I') return false;
        const arguments = expression.x.pList orelse return false;
        const definition = function_registry.findFunction(db, name, arguments.nExpr, 1, false) orelse return false;
        if (definition.funcFlags & types.function_flag.inline_ == 0 or @intFromPtr(definition.pUserData orelse return false) != types.inline_function.iif) return false;
    } else if (expression.op == tokens.tk_case) {
        if (expression.pLeft != null) return false;
    } else return false;
    const arguments = expression.x.pList.?;
    if (arguments.nExpr == 2) return true;
    return arguments.nExpr == 3 and isNotTrue(arguments.items()[2].pExpr.?);
}

/// Source `sqlite3ExprCanBeNull()`.
pub fn canBeNull(expression_initial: *const parse_types.Expr) bool {
    var expression = expression_initial;
    while (expression.op == tokens.tk_uplus or expression.op == tokens.tk_uminus) {
        expression = expression.pLeft.?;
    }
    const operation = if (expression.op == tokens.tk_register) expression.op2 else expression.op;
    return switch (operation) {
        tokens.tk_integer, tokens.tk_string, tokens.tk_float, tokens.tk_blob => false,
        tokens.tk_column => expression.flags & 0x0020_0000 != 0 or expression.y.pTab == null or
            (expression.iColumn >= 0 and expression.y.pTab.?.columns != null and
                expression.iColumn < expression.y.pTab.?.column_count and
                expression.y.pTab.?.columns.?[@intCast(expression.iColumn)].definition.not_null_action == 0),
        else => true,
    };
}

/// Source `sqlite3ExprNeedsNoAffinityChange()`.
pub fn needsNoAffinityChange(expression_initial: *const parse_types.Expr, affinity: u8) bool {
    if (affinity == schema_analysis.affinity.blob) return true;
    var expression = expression_initial;
    var unary_minus = false;
    while (expression.op == tokens.tk_uplus or expression.op == tokens.tk_uminus) {
        if (expression.op == tokens.tk_uminus) unary_minus = true;
        expression = expression.pLeft.?;
    }
    const operation = if (expression.op == tokens.tk_register) expression.op2 else expression.op;
    return switch (operation) {
        tokens.tk_integer, tokens.tk_float => affinity >= schema_analysis.affinity.numeric,
        tokens.tk_string => !unary_minus and affinity == schema_analysis.affinity.text,
        tokens.tk_blob => !unary_minus,
        tokens.tk_column => affinity >= schema_analysis.affinity.numeric and expression.iColumn < 0,
        else => false,
    };
}

/// Source `sqlite3IsRowid()`.
pub fn isRowid(text: [*:0]const u8) bool {
    return sqlite_string.compareInternal(text, "_ROWID_") == 0 or sqlite_string.compareInternal(text, "ROWID") == 0 or sqlite_string.compareInternal(text, "OID") == 0;
}

/// Source `sqlite3RowidAlias()`.
pub fn rowidAlias(table: *const schema.Table) ?[*:0]const u8 {
    const aliases = [_][*:0]const u8{ "_ROWID_", "ROWID", "OID" };
    for (aliases) |alias| if (schema_analysis.columnIndex(table, alias) < 0) return alias;
    return null;
}

fn setExpressionError(parse: *parse_types.Parse, message: []const u8) void {
    parse_error.report(parse, message);
}

/// Source `exprINAffinity()`.
pub fn inExpressionAffinity(parse: *parse_types.Parse, expression: *const parse_types.Expr) ?[*:0]u8 {
    const left = expression.pLeft.?;
    const count = vectorSize(left);
    const select = if (expression.usesSelect()) expression.x.pSelect else null;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const raw = db_allocator.mallocRaw(db, @intCast(count + 1)) orelse return null;
    const result: [*]u8 = @ptrCast(raw);
    for (0..@intCast(count)) |index| {
        const left_field = vectorFieldSubexpression(@constCast(left), @intCast(index));
        const left_affinity = expressionAffinity(left_field);
        result[index] = if (select) |present| compareAffinity(present.pEList.?.items()[index].pExpr.?, left_affinity) else left_affinity;
    }
    result[@intCast(count)] = 0;
    return @ptrCast(result);
}

/// Source `sqlite3SubselectError()`.
pub fn subselectError(parse: *parse_types.Parse, actual: c_int, expected: c_int) void {
    if (parse.nErr != 0) return;
    var buffer: [96]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "sub-select returns {d} columns - expected {d}", .{ actual, expected }) catch "sub-select column count mismatch";
    setExpressionError(parse, message);
}

/// Source `sqlite3VectorErrorMsg()`.
pub fn vectorError(parse: *parse_types.Parse, expression: *parse_types.Expr) void {
    if (expression.usesSelect()) subselectError(parse, expression.x.pSelect.?.pEList.?.nExpr, 1) else setExpressionError(parse, "row value misused");
}

/// Source `sqlite3ExprCheckIN()`.
pub fn checkInExpression(parse: *parse_types.Parse, expression: *parse_types.Expr) bool {
    const vector_size = vectorSize(expression.pLeft.?);
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (expression.usesSelect() and db.mallocFailed == 0) {
        const actual = expression.x.pSelect.?.pEList.?.nExpr;
        if (vector_size != actual) {
            subselectError(parse, actual, vector_size);
            return true;
        }
    } else if (vector_size != 1) {
        vectorError(parse, expression.pLeft.?);
        return true;
    }
    return false;
}

/// Source `exprNodeCanReturnSubtype()`.
pub fn nodeCanReturnSubtype(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_case or expression.op == tokens.tk_uplus or expression.op == tokens.tk_collate or expression.op == tokens.tk_cast) return walker_api.continue_walk;
    if (expression.op != tokens.tk_function) return walker_api.prune;
    const parse = walker.pParse.?;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const argument_count = if (expression.x.pList) |list| list.nExpr else 0;
    const definition = function_registry.findFunction(db, expression.u.zToken.?, argument_count, 1, false);
    if (definition == null or definition.?.funcFlags & types.function_flag.result_subtype != 0) {
        walker.eCode = 1;
        return walker_api.abort_walk;
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3ExprCanReturnSubtype()`.
pub fn canReturnSubtype(parse: *parse_types.Parse, expression: *parse_types.Expr) bool {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.pParse = parse;
    walker.xExprCallback = nodeCanReturnSubtype;
    _ = walker_api.walkExpr(&walker, expression);
    return walker.eCode != 0;
}

/// Source `exprNodeIsConstantOrGroupBy()`.
pub fn constantOrGroupByNode(walker: *parse_types.Walker, expression_node: *parse_types.Expr) callconv(.c) c_int {
    const group_by: *parse_types.ExprList = @ptrCast(@alignCast(walker.u.pointer.?));
    for (group_by.items()) |item| {
        if (compareExpressions(null, expression_node, item.pExpr, -1) < 2 and collation.isBinary(expressionNonNullCollation(walker.pParse.?, item.pExpr.?))) return walker_api.prune;
    }
    if (expression_node.usesSelect()) {
        walker.eCode = 0;
        return walker_api.abort_walk;
    }
    return constantExpressionNode(walker, expression_node);
}

/// Source `sqlite3ExprIsConstantOrGroupBy()`.
pub fn isConstantOrGroupBy(parse: *parse_types.Parse, expression_node: *parse_types.Expr, group_by: *parse_types.ExprList) bool {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.eCode = 1;
    walker.xExprCallback = constantOrGroupByNode;
    walker.pParse = parse;
    walker.u.pointer = group_by;
    _ = walker_api.walkExpr(&walker, expression_node);
    return walker.eCode != 0;
}

/// Source `exprNodeIsConstantFunction()`.
pub fn constantFunctionNode(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    const arguments = if (expression.flags & 0x0001_0000 != 0) null else expression.x.pList;
    const argument_count: c_int = if (arguments) |list| list.nExpr else 0;
    if (arguments) |list| {
        _ = walker_api.walkExprList(walker, list);
        if (walker.eCode == 0) return walker_api.abort_walk;
    }
    const parse = walker.pParse.?;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const definition = function_registry.findFunction(db, expression.u.zToken.?, argument_count, 1, false);
    if (definition == null or definition.?.xFinalize != null or
        definition.?.funcFlags & (types.function_flag.constant | types.function_flag.slow_change) == 0 or
        expression.flags & parse_types.expr_flag.win_func != 0)
    {
        walker.eCode = 0;
        return walker_api.abort_walk;
    }
    return walker_api.prune;
}

/// Source `exprNodeIsConstant()`.
pub fn constantExpressionNode(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (walker.eCode == 2 and expression.flags & 0x0000_0001 != 0) {
        walker.eCode = 0;
        return walker_api.abort_walk;
    }
    switch (expression.op) {
        tokens.tk_function => {
            if ((walker.eCode >= 4 or expression.flags & 0x0010_0000 != 0) and expression.flags & parse_types.expr_flag.win_func == 0) {
                if (walker.eCode == 5) expression.flags |= parse_types.expr_flag.from_ddl;
                return walker_api.continue_walk;
            }
            if (walker.pParse != null) return constantFunctionNode(walker, expression);
            walker.eCode = 0;
            return walker_api.abort_walk;
        },
        tokens.tk_id => {
            if (identifierToTrueFalse(expression)) return walker_api.prune;
            walker.eCode = 0;
            return walker_api.abort_walk;
        },
        tokens.tk_column, tokens.tk_agg_function, tokens.tk_agg_column => {
            if (expression.flags & 0x0000_0020 != 0 and walker.eCode != 2) return walker_api.continue_walk;
            if (walker.eCode == 3 and expression.iTable == walker.u.counter) return walker_api.continue_walk;
            walker.eCode = 0;
            return walker_api.abort_walk;
        },
        tokens.tk_if_null_row, tokens.tk_register, tokens.tk_dot, tokens.tk_raise => {
            walker.eCode = 0;
            return walker_api.abort_walk;
        },
        tokens.tk_variable => {
            if (walker.eCode == 5) expression.op = @intCast(tokens.tk_null) else if (walker.eCode == 4) {
                walker.eCode = 0;
                return walker_api.abort_walk;
            }
            return walker_api.continue_walk;
        },
        else => return walker_api.continue_walk,
    }
}

fn constantSelectFail(walker: *parse_types.Walker, _: *parse_types.Select) callconv(.c) c_int {
    walker.eCode = 0;
    return walker_api.abort_walk;
}

/// Source `exprIsConst()`.
pub fn isConstantMode(parse: ?*parse_types.Parse, expression: *parse_types.Expr, mode: u16) u16 {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.eCode = mode;
    walker.pParse = parse;
    walker.xExprCallback = constantExpressionNode;
    walker.xSelectCallback = constantSelectFail;
    _ = walker_api.walkExpr(&walker, expression);
    return walker.eCode;
}

/// Source `sqlite3ExprIsConstant()`.
pub fn isConstant(parse: ?*parse_types.Parse, expression: *parse_types.Expr) bool {
    return isConstantMode(parse, expression, 1) != 0;
}

/// Source `sqlite3ExprIsConstantNotJoin()`.
pub fn isConstantNotJoin(parse: *parse_types.Parse, expression: *parse_types.Expr) bool {
    return isConstantMode(parse, expression, 2) != 0;
}

/// Source `exprSelectWalkTableConstant()`.
pub fn selectWalkTableConstant(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    if (select.selFlags & parse_types.select_flag.correlated != 0) {
        walker.eCode = 0;
        return walker_api.abort_walk;
    }
    return walker_api.prune;
}

/// Source `sqlite3ExprIsTableConstant()`.
pub fn isTableConstant(expression: *parse_types.Expr, cursor: c_int, allow_subquery: bool) bool {
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.eCode = 3;
    walker.xExprCallback = constantExpressionNode;
    walker.xSelectCallback = if (allow_subquery) selectWalkTableConstant else constantSelectFail;
    walker.u.counter = cursor;
    _ = walker_api.walkExpr(&walker, expression);
    return walker.eCode != 0;
}

/// Source `sqlite3InRhsIsConstant()`.
pub fn inRightHandSideIsConstant(parse: *parse_types.Parse, expression: *parse_types.Expr) bool {
    const left = expression.pLeft;
    expression.pLeft = null;
    defer expression.pLeft = left;
    return isConstant(parse, expression);
}

/// Source `sqlite3ExprIsSingleTableConstraint()`.
pub fn isSingleTableConstraint(expression: *parse_types.Expr, sources: *const parse_types.SrcList, source_index: c_int, allow_subquery: bool) bool {
    const mutable_sources = @constCast(sources);
    const source = &mutable_sources.items()[@intCast(source_index)];
    if (source.fg.jointype & 0x40 != 0) return false;
    if (source.fg.jointype & 0x08 != 0) {
        if (expression.flags & 0x0000_0001 == 0 or expression.w.iJoin != source.iCursor) return false;
    } else if (expression.flags & 0x0000_0001 != 0) return false;
    if (expression.flags & 0x0000_0003 != 0 and mutable_sources.items()[0].fg.jointype & 0x40 != 0) {
        for (mutable_sources.items()[0..@intCast(source_index)]) |prior| {
            if (expression.w.iJoin == prior.iCursor and prior.fg.jointype & 0x40 != 0) return false;
        }
    }
    return isTableConstant(expression, source.iCursor, allow_subquery);
}

/// Source `sqlite3ExprIsConstantOrFunction()`.
pub fn isConstantOrFunction(expression: *parse_types.Expr, initialization: bool) bool {
    return isConstantMode(null, expression, 4 + @intFromBool(initialization)) != 0;
}

pub fn numericAffinity(value: u8) bool {
    return value >= schema_analysis.affinity.numeric and value <= schema_analysis.affinity.real;
}

/// Source `sqlite3CompareAffinity()`.
pub fn compareAffinity(expression: *const parse_types.Expr, other_affinity: u8) u8 {
    const first = expressionAffinity(expression);
    if (first > 0x40 and other_affinity > 0x40) {
        return if (numericAffinity(first) or numericAffinity(other_affinity)) schema_analysis.affinity.numeric else schema_analysis.affinity.blob;
    }
    return (if (first <= 0x40) other_affinity else first) | 0x40;
}

/// Source `comparisonAffinity()`.
pub fn comparisonAffinity(expression: *const parse_types.Expr) u8 {
    var result = expressionAffinity(expression.pLeft.?);
    if (expression.pRight) |right| result = compareAffinity(right, result) else if (expression.usesSelect()) result = compareAffinity(expression.x.pSelect.?.pEList.?.items()[0].pExpr.?, result) else if (result == 0) result = schema_analysis.affinity.blob;
    return result;
}

/// Source `sqlite3IndexAffinityOk()`.
pub fn indexAffinityOk(expression: *const parse_types.Expr, index_affinity: u8) bool {
    const comparison = comparisonAffinity(expression);
    if (comparison < schema_analysis.affinity.text) return true;
    if (comparison == schema_analysis.affinity.text) return index_affinity == schema_analysis.affinity.text;
    return numericAffinity(index_affinity);
}
