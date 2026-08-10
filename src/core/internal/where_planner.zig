//! WHERE-clause storage and loop-cost planning translated from `where.c` and `whereexpr.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const log_est = @import("../log_est.zig");
const sqlite_string = @import("../string.zig");
const ast_duplication = @import("ast_duplication.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const db_allocator = @import("db_allocator.zig");
const expression = @import("expression_analysis.zig");
const like_optimization = @import("like_optimization.zig");
const parse_cleanup = @import("parse_cleanup.zig");
const parse_types = @import("parse_types.zig");
const resolve_analysis = @import("resolve_analysis.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const types = @import("vdbe_types.zig");
const walker_api = @import("walker.zig");
const where_analysis = @import("where_analysis.zig");

pub const term_flag = struct {
    pub const dynamic: u16 = 0x0001;
    pub const virtual: u16 = 0x0002;
    pub const coded: u16 = 0x0004;
    pub const copied: u16 = 0x0008;
    pub const or_info: u16 = 0x0010;
    pub const and_info: u16 = 0x0020;
    pub const vnull: u16 = 0x0080;
    pub const heuristic_truth: u16 = 0x2000;
};

pub const operation = struct {
    pub const in: u16 = 0x0001;
    pub const eq: u16 = 0x0002;
    pub const aux: u16 = 0x0040;
    pub const is: u16 = 0x0080;
    pub const is_null: u16 = 0x0100;
    pub const or_op: u16 = 0x0200;
    pub const and_op: u16 = 0x0400;
    pub const equiv: u16 = 0x0800;
    pub const row_value: u16 = 0x2000;
};

pub const loop_flag = struct {
    pub const column_eq: u32 = 0x0000_0001;
    pub const column_range: u32 = 0x0000_0002;
    pub const column_in: u32 = 0x0000_0004;
    pub const column_null: u32 = 0x0000_0008;
    pub const index_only: u32 = 0x0000_0040;
    pub const ipk: u32 = 0x0000_0100;
    pub const indexed: u32 = 0x0000_0200;
    pub const virtual_table: u32 = 0x0000_0400;
    pub const one_row: u32 = 0x0000_1000;
    pub const auto_index: u32 = 0x0000_4000;
    pub const transitive: u32 = 0x0020_0000;
    pub const bloom_filter: u32 = 0x0040_0000;
    pub const self_cull: u32 = 0x0080_0000;
    pub const coroutine: u32 = 0x0200_0000;
    pub const expression_index: u32 = 0x0400_0000;
};

pub const WhereMemoryBlock = extern struct {
    next: ?*WhereMemoryBlock,
    size: u64,
    payload: [0]u8,
};

pub const WhereInfo = struct {
    parse: *parse_types.Parse,
    table_list: ?*parse_types.SrcList = null,
    order_by: ?*parse_types.ExprList = null,
    result_set: ?*parse_types.ExprList = null,
    select: ?*parse_types.Select = null,
    clause: ?*WhereClause = null,
    mask_set: where_analysis.MaskSet = .{ .variable_select = 0, .count = 0, .cursors = [_]c_int{0} ** 64 },
    levels: []WhereLevel = &.{},
    control_flags: u16 = 0,
    limit_estimate: i16 = 0,
    output_rows: i16 = 0,
    order_satisfied: i8 = 0,
    distinct_mode: u8 = 0,
    reverse_mask: u64 = 0,
    loops: ?*WhereLoop = null,
    memory: ?*WhereMemoryBlock = null,
};

pub const WhereTermColumn = extern struct {
    left_column: c_int,
    field: c_int,
};

pub const WhereTermAux = extern union {
    column: WhereTermColumn,
    or_clause: ?*WhereClause,
    and_clause: ?*WhereClause,
};

pub const WhereTerm = extern struct {
    expression: ?*parse_types.Expr,
    clause: ?*WhereClause,
    truth_probability: i16,
    flags: u16,
    operator: u16,
    child_count: u8,
    match_operator: u8,
    parent_index: c_int,
    left_cursor: c_int,
    aux: WhereTermAux,
    prerequisites_right: u64,
    prerequisites_all: u64,
};

pub const WhereClause = struct {
    info: *WhereInfo,
    outer: ?*WhereClause = null,
    split_operator: u8 = 0,
    has_or: bool = false,
    term_count: c_int = 0,
    slot_count: c_int = 8,
    base_count: c_int = 0,
    terms: [*]WhereTerm = undefined,
    static_terms: [8]WhereTerm = undefined,
};

pub const WhereLevel = struct {
    table_cursor: c_int = 0,
    loop: ?*WhereLoop = null,
};

pub const BtreeLoop = extern struct {
    equality_count: u16,
    bottom_count: u16,
    top_count: u16,
    distinct_columns: u16,
    index: ?*schema.Index,
    order_by: ?*parse_types.ExprList,
};

pub const VirtualLoop = extern struct {
    index_number: c_int,
    need_free: u8,
    omit_offset: u8,
    index_number_hex: u8,
    ordered: i8,
    omit_mask: u16,
    _padding: u16 = 0,
    index_string: ?[*:0]u8,
    handle_in_mask: u32,
};

pub const LoopChoice = extern union {
    btree: BtreeLoop,
    virtual_table: VirtualLoop,
};

pub const WhereLoop = struct {
    prerequisites: u64 = 0,
    self_mask: u64 = 0,
    table_index: u8 = 0,
    sort_index: u8 = 0,
    setup_cost: i16 = 0,
    run_cost: i16 = 0,
    output_rows: i16 = 0,
    choice: LoopChoice = undefined,
    flags: u32 = 0,
    term_count: u16 = 0,
    skip_count: u16 = 0,
    slot_count: u16 = 3,
    terms: [*]?*WhereTerm = undefined,
    next: ?*WhereLoop = null,
    static_terms: [3]?*WhereTerm = .{ null, null, null },
};

pub const WhereOrCost = extern struct {
    prerequisites: u64,
    run_cost: i16,
    output_rows: i16,
};

pub const WhereOrSet = struct {
    count: u16 = 0,
    costs: [3]WhereOrCost = undefined,
};

/// Source `whereOrInsert()`.
pub fn insertOrCost(set: *WhereOrSet, prerequisites: u64, run_cost: i16, output_rows: i16) bool {
    var replace: ?usize = null;
    for (set.costs[0..set.count], 0..) |cost, index| {
        if (run_cost <= cost.run_cost and prerequisites & cost.prerequisites == prerequisites) {
            replace = index;
            break;
        }
        if (cost.run_cost <= run_cost and cost.prerequisites & prerequisites == cost.prerequisites) return false;
    }
    if (replace == null) {
        if (set.count < set.costs.len) {
            replace = set.count;
            set.costs[set.count].output_rows = output_rows;
            set.count += 1;
        } else {
            var worst: usize = 0;
            for (set.costs[1..], 1..) |cost, index| if (set.costs[worst].run_cost > cost.run_cost) {
                worst = index;
            };
            if (set.costs[worst].run_cost <= run_cost) return false;
            replace = worst;
        }
    }
    const target = &set.costs[replace.?];
    target.prerequisites = prerequisites;
    target.run_cost = run_cost;
    target.output_rows = @min(target.output_rows, output_rows);
    return true;
}

/// Source `sqlite3WhereMalloc()`.
pub fn plannerAllocate(info: *WhereInfo, byte_count: u64) ?*anyopaque {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(info.parse.db.?));
    const total = std.math.add(usize, @sizeOf(WhereMemoryBlock), @intCast(byte_count)) catch {
        _ = db_allocator.oomFault(db);
        return null;
    };
    const raw = db_allocator.mallocRawNN(db, total) orelse return null;
    const block: *WhereMemoryBlock = @ptrCast(@alignCast(raw));
    block.next = info.memory;
    block.size = byte_count;
    info.memory = block;
    return @ptrFromInt(@intFromPtr(block) + @sizeOf(WhereMemoryBlock));
}

/// Source `sqlite3WhereRealloc()`.
pub fn plannerReallocate(info: *WhereInfo, old: ?*const anyopaque, byte_count: u64) ?*anyopaque {
    const new = plannerAllocate(info, byte_count) orelse return null;
    if (old) |present| {
        const header: *const WhereMemoryBlock = @ptrFromInt(@intFromPtr(present) - @sizeOf(WhereMemoryBlock));
        @memcpy(@as([*]u8, @ptrCast(new))[0..@intCast(header.size)], @as([*]const u8, @ptrCast(present))[0..@intCast(header.size)]);
    }
    return new;
}

/// Source `whereClauseInsert()`.
pub fn insertClauseTerm(clause: *WhereClause, expression_node: ?*parse_types.Expr, flags: u16) ?c_int {
    if (clause.term_count >= clause.slot_count) {
        const old = clause.terms;
        const bytes: u64 = @intCast(@sizeOf(WhereTerm) * @as(usize, @intCast(clause.slot_count * 2)));
        const raw = plannerAllocate(clause.info, bytes) orelse {
            if (flags & term_flag.dynamic != 0) {
                const db: *types.Sqlite3 = @ptrCast(@alignCast(clause.info.parse.db.?));
                compiler_ownership.deleteExpression(db, expression_node);
            }
            return null;
        };
        clause.terms = @ptrCast(@alignCast(raw));
        @memcpy(clause.terms[0..@intCast(clause.term_count)], old[0..@intCast(clause.term_count)]);
        clause.slot_count *= 2;
    }
    const index = clause.term_count;
    clause.term_count += 1;
    if (flags & term_flag.virtual == 0) clause.base_count = clause.term_count;
    const term = &clause.terms[@intCast(index)];
    term.* = std.mem.zeroes(WhereTerm);
    term.truth_probability = if (expression_node != null and expression_node.?.flags & 0x0004_0000 != 0)
        @as(i16, @intCast(expression_node.?.iTable)) - 270
    else
        1;
    term.expression = expression.skipCollationAndLikely(expression_node);
    term.flags = flags;
    term.clause = clause;
    term.parent_index = -1;
    return index;
}

/// Source `sqlite3WhereClauseInit()`.
pub fn initializeClause(clause: *WhereClause, info: *WhereInfo) void {
    clause.* = .{ .info = info };
    clause.terms = @ptrCast(&clause.static_terms);
}

/// Source `sqlite3WhereSplit()`.
pub fn splitClause(clause: *WhereClause, expression_node: ?*parse_types.Expr, split_operator: u8) void {
    clause.split_operator = split_operator;
    const node = expression.skipCollationAndLikely(expression_node) orelse return;
    if (node.op != split_operator) {
        _ = insertClauseTerm(clause, expression_node, 0);
        return;
    }
    splitClause(clause, node.pLeft, split_operator);
    splitClause(clause, node.pRight, split_operator);
}

fn clearNestedClause(db: *types.Sqlite3, nested: ?*WhereClause) void {
    const present = nested orelse return;
    clearClause(present);
    db_allocator.freeNN(db, present);
}

/// Source `sqlite3WhereClauseClear()`.
pub fn clearClause(clause: *WhereClause) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(clause.info.parse.db.?));
    for (clause.terms[0..@intCast(clause.term_count)]) |*term| {
        if (term.flags & term_flag.dynamic != 0) compiler_ownership.deleteExpression(db, term.expression);
        if (term.flags & term_flag.or_info != 0) clearNestedClause(db, term.aux.or_clause) else if (term.flags & term_flag.and_info != 0) clearNestedClause(db, term.aux.and_clause);
    }
    clause.term_count = 0;
    clause.base_count = 0;
}

/// Source `exprMightBeIndexed2()`.
pub fn expressionMightBeIndexedFrom(sources: *parse_types.SrcList, cursor_column: *[2]c_int, expression_node: *parse_types.Expr, start: c_int) bool {
    var source_index = start;
    while (source_index < sources.nSrc) : (source_index += 1) {
        const source = &sources.items()[@intCast(source_index)];
        var index = source.pSTab.?.indexes;
        while (index) |present| : (index = present.next) {
            const expressions: *parse_types.ExprList = if (present.column_expressions) |list| @ptrCast(@alignCast(list)) else continue;
            for (present.columns.?[0..present.key_column_count], 0..) |column, position| {
                if (column != -2) continue;
                const indexed = expressions.items()[position].pExpr.?;
                if (expression.compareExpressionsSkipCollation(expression_node, indexed, source.iCursor) == 0 and !expression.isConstant(null, indexed)) {
                    cursor_column.* = .{ source.iCursor, -2 };
                    return true;
                }
            }
        }
    }
    return false;
}

/// Source `exprMightBeIndexed()`.
pub fn expressionMightBeIndexed(sources: *parse_types.SrcList, cursor_column: *[2]c_int, expression_initial: *parse_types.Expr, operator: c_int) bool {
    var expression_node = expression_initial;
    if (expression_node.op == tokens.tk_vector and operator >= tokens.tk_gt and operator <= tokens.tk_ge) expression_node = expression_node.x.pList.?.items()[0].pExpr.?;
    if (expression_node.op == tokens.tk_column) {
        cursor_column.* = .{ expression_node.iTable, expression_node.iColumn };
        return true;
    }
    for (sources.items(), 0..) |source, source_index| {
        var index = source.pSTab.?.indexes;
        while (index) |present| : (index = present.next) if (present.column_expressions != null) return expressionMightBeIndexedFrom(sources, cursor_column, expression_node, @intCast(source_index));
    }
    return false;
}

/// Source `whereLoopInit()`.
pub fn initializeLoop(loop: *WhereLoop) void {
    loop.* = .{};
    loop.terms = @ptrCast(&loop.static_terms);
}

/// Source `whereLoopClearUnion()`.
pub fn clearLoopChoice(db: *types.Sqlite3, loop: *WhereLoop) void {
    if (loop.flags & loop_flag.virtual_table != 0 and loop.choice.virtual_table.need_free != 0) {
        db_allocator.free(db, if (loop.choice.virtual_table.index_string) |text| @ptrCast(text) else null);
        loop.choice.virtual_table.need_free = 0;
        loop.choice.virtual_table.index_string = null;
    } else if (loop.flags & loop_flag.auto_index != 0) {
        if (loop.choice.btree.index) |index| {
            db_allocator.free(db, if (index.column_affinities) |text| @ptrCast(text) else null);
            db_allocator.freeNN(db, index);
            loop.choice.btree.index = null;
        }
    }
}

/// Source `whereLoopClear()`.
pub fn clearLoop(db: *types.Sqlite3, loop: *WhereLoop) void {
    const inline_terms: [*]?*WhereTerm = @ptrCast(&loop.static_terms);
    if (loop.terms != inline_terms) db_allocator.freeNN(db, loop.terms);
    clearLoopChoice(db, loop);
    loop.terms = inline_terms;
    loop.slot_count = loop.static_terms.len;
    loop.term_count = 0;
    loop.flags = 0;
}

/// Source `whereLoopResize()`.
pub fn resizeLoop(db: *types.Sqlite3, loop: *WhereLoop, requested: c_int) c_int {
    if (loop.slot_count >= requested) return 0;
    const capacity: usize = @intCast((requested + 7) & ~@as(c_int, 7));
    const raw = db_allocator.mallocRawNN(db, capacity * @sizeOf(?*WhereTerm)) orelse return 7;
    const terms: [*]?*WhereTerm = @ptrCast(@alignCast(raw));
    @memcpy(terms[0..loop.slot_count], loop.terms[0..loop.slot_count]);
    const inline_terms: [*]?*WhereTerm = @ptrCast(&loop.static_terms);
    if (loop.terms != inline_terms) db_allocator.freeNN(db, loop.terms);
    loop.terms = terms;
    loop.slot_count = @intCast(capacity);
    return 0;
}

/// Source `whereLoopXfer()`.
pub fn transferLoop(db: *types.Sqlite3, destination: *WhereLoop, source: *WhereLoop) c_int {
    clearLoopChoice(db, destination);
    if (source.term_count > destination.slot_count and resizeLoop(db, destination, source.term_count) != 0) {
        destination.prerequisites = 0;
        destination.self_mask = 0;
        destination.flags = 0;
        return 7;
    }
    const terms = destination.terms;
    const slots = destination.slot_count;
    const inline_storage = destination.static_terms;
    destination.* = source.*;
    destination.terms = terms;
    destination.slot_count = slots;
    destination.static_terms = inline_storage;
    @memcpy(destination.terms[0..destination.term_count], source.terms[0..source.term_count]);
    if (source.flags & loop_flag.virtual_table != 0) source.choice.virtual_table.need_free = 0 else if (source.flags & loop_flag.auto_index != 0) source.choice.btree.index = null;
    return 0;
}

/// Source `whereLoopCheaperProperSubset()`.
pub fn loopIsCheaperProperSubset(first: *const WhereLoop, second: *const WhereLoop) bool {
    if (first.run_cost > second.run_cost and first.output_rows > second.output_rows) return false;
    if (first.choice.btree.equality_count < second.choice.btree.equality_count and first.choice.btree.index == second.choice.btree.index and first.skip_count == 0 and second.skip_count == 0) return true;
    if (first.term_count - first.skip_count >= second.term_count - second.skip_count or second.skip_count > first.skip_count) return false;
    for (first.terms[0..first.term_count]) |candidate| {
        const present = candidate orelse continue;
        var found = false;
        for (second.terms[0..second.term_count]) |other| if (other == present) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return first.flags & loop_flag.index_only == 0 or second.flags & loop_flag.index_only != 0;
}

/// Source `whereLoopAdjustCost()`.
pub fn adjustLoopCost(loops: ?*const WhereLoop, template: *WhereLoop) void {
    if (template.flags & loop_flag.indexed == 0) return;
    var loop = loops;
    while (loop) |present| : (loop = present.next) {
        if (present.table_index != template.table_index or present.flags & loop_flag.indexed == 0) continue;
        if (loopIsCheaperProperSubset(present, template)) {
            template.run_cost = @min(present.run_cost, template.run_cost);
            template.output_rows = @min(present.output_rows - 1, template.output_rows);
        } else if (loopIsCheaperProperSubset(template, present)) {
            template.run_cost = @max(present.run_cost, template.run_cost);
            template.output_rows = @max(present.output_rows + 1, template.output_rows);
        }
    }
}

/// Source `whereLoopFindLesser()`.
pub fn findLesserLoop(link_initial: **?*WhereLoop, template: *const WhereLoop) ?**?*WhereLoop {
    var link = link_initial;
    while (link.*) |present| {
        if (present.table_index != template.table_index or present.sort_index != template.sort_index) {
            link = &present.next;
            continue;
        }
        if (present.flags & loop_flag.auto_index != 0 and template.skip_count == 0 and template.flags & (loop_flag.indexed | loop_flag.column_eq) == (loop_flag.indexed | loop_flag.column_eq) and present.prerequisites & template.prerequisites == template.prerequisites) break;
        if (present.prerequisites & template.prerequisites == present.prerequisites and present.setup_cost <= template.setup_cost and present.run_cost <= template.run_cost and present.output_rows <= template.output_rows) return null;
        if (present.prerequisites & template.prerequisites == template.prerequisites and present.run_cost >= template.run_cost and present.output_rows >= template.output_rows) break;
        link = &present.next;
    }
    return link;
}

/// Source `indexMightHelpWithOrderBy()`.
pub fn indexMightHelpOrderBy(order_by_optional: ?*parse_types.ExprList, index: *schema.Index, cursor: c_int) bool {
    if (index.properties.unordered) return false;
    const order_by = order_by_optional orelse return false;
    const indexed_expressions: ?*parse_types.ExprList = if (index.column_expressions) |list| @ptrCast(@alignCast(list)) else null;
    for (order_by.items()) |item| {
        const candidate = expression.skipCollationAndLikely(item.pExpr) orelse continue;
        if ((candidate.op == tokens.tk_column or candidate.op == tokens.tk_agg_column) and candidate.iTable == cursor) {
            if (candidate.iColumn < 0) return true;
            for (index.columns.?[0..index.key_column_count]) |column| if (candidate.iColumn == column) return true;
        } else if (indexed_expressions) |list| {
            for (index.columns.?[0..index.key_column_count], 0..) |column, position| if (column == -2 and expression.compareExpressionsSkipCollation(candidate, list.items()[position].pExpr.?, cursor) == 0) return true;
        }
    }
    return false;
}

/// Source `whereRangeAdjust()`.
pub fn adjustRangeEstimate(term: ?*const WhereTerm, new_rows: i16) i16 {
    const present = term orelse return new_rows;
    if (present.truth_probability <= 0) return new_rows + present.truth_probability;
    if (present.flags & term_flag.vnull == 0) return new_rows - 20;
    return new_rows;
}

/// Source `whereReverseScanOrder()`.
pub fn reverseScanOrder(info: *WhereInfo) void {
    const sources = info.table_list orelse return;
    for (sources.items(), 0..) |source, index| {
        const materialized_order = source.fg.isCte and source.u2.pCteUse != null and
            source.u2.pCteUse.?.materialization == parse_types.materialized.yes and source.fg.isSubquery and
            source.u4.pSubq != null and source.u4.pSubq.?.pSelect != null and source.u4.pSubq.?.pSelect.?.pOrderBy != null;
        if (!materialized_order) info.reverse_mask |= @as(u64, 1) << @intCast(index);
    }
}

/// Source `constraintCompatibleWithOuterJoin()`.
pub fn constraintCompatibleWithOuterJoin(term: *const WhereTerm, source: *const parse_types.SrcItem) bool {
    const node = term.expression orelse return false;
    if (node.flags & 0x0000_0003 == 0 or node.w.iJoin != source.iCursor) return false;
    if (source.fg.jointype & (0x08 | 0x10) != 0 and node.flags & 0x0000_0002 != 0) return false;
    return true;
}

/// Source `termCanDriveIndex()`.
pub fn termCanDriveIndex(term: *const WhereTerm, source: *const parse_types.SrcItem, not_ready: u64) bool {
    if (term.left_cursor != source.iCursor or term.operator & (operation.eq | operation.is) == 0) return false;
    if (source.fg.jointype & (0x08 | 0x40 | 0x10) != 0 and !constraintCompatibleWithOuterJoin(term, source)) return false;
    if (term.prerequisites_right & not_ready != 0) return false;
    const column = term.aux.column.left_column;
    if (column < 0) return false;
    const table = source.pSTab.?;
    if (!expression.indexAffinityOk(term.expression.?, table.columns.?[@intCast(column)].affinity)) return false;
    return where_analysis.columnIsGoodIndexCandidate(table, column);
}

/// Source `indexInAffinityOk()`.
pub fn indexInAffinityCollation(parse: *parse_types.Parse, term: *WhereTerm, index_affinity: u8) ?[*:0]const u8 {
    var comparison = term.expression.?;
    var vector_comparison = std.mem.zeroes(parse_types.Expr);
    if (expression.vectorSize(comparison.pLeft.?) > 1) {
        const field: usize = @intCast(term.aux.column.field - 1);
        vector_comparison.op = @intCast(tokens.tk_eq);
        vector_comparison.pLeft = comparison.pLeft.?.x.pList.?.items()[field].pExpr;
        vector_comparison.pRight = comparison.x.pSelect.?.pEList.?.items()[field].pExpr;
        comparison = &vector_comparison;
    }
    if (!expression.indexAffinityOk(comparison, index_affinity)) return null;
    const collation = expression.expressionComparisonCollation(parse, comparison);
    return if (collation) |present| present.zName else "BINARY";
}

pub const WhereScan = struct {
    original_clause: *WhereClause,
    clause: *WhereClause,
    collation_name: ?[*:0]const u8 = null,
    index_expression: ?*parse_types.Expr = null,
    next_index: c_int = 0,
    operator_mask: u32,
    index_affinity: u8 = 0,
    equivalence_index: u8 = 1,
    equivalence_count: u8 = 1,
    cursors: [11]c_int = undefined,
    columns: [11]i16 = undefined,
};

/// Source `whereScanNext()`.
pub fn nextWhereTerm(scan: *WhereScan) ?*WhereTerm {
    var clause = scan.clause;
    var term_index = scan.next_index;
    while (true) {
        const column = scan.columns[scan.equivalence_index - 1];
        const cursor = scan.cursors[scan.equivalence_index - 1];
        while (true) {
            while (term_index < clause.term_count) : (term_index += 1) {
                const term = &clause.terms[@intCast(term_index)];
                if (term.left_cursor != cursor or term.aux.column.left_column != column) continue;
                if (column == -2 and expression.compareExpressionsSkipCollation(term.expression.?.pLeft.?, scan.index_expression.?, cursor) != 0) continue;
                if (scan.equivalence_index > 1 and term.expression.?.flags & 0x0000_0001 != 0) continue;
                if (term.operator & operation.equiv != 0 and scan.equivalence_count < scan.cursors.len) {
                    if (where_analysis.rightSubexpressionIsColumn(term.expression.?)) |right| {
                        var known = false;
                        for (scan.cursors[0..scan.equivalence_count], scan.columns[0..scan.equivalence_count]) |known_cursor, known_column| {
                            if (known_cursor == right.iTable and known_column == right.iColumn) {
                                known = true;
                                break;
                            }
                        }
                        if (!known) {
                            scan.cursors[scan.equivalence_count] = right.iTable;
                            scan.columns[scan.equivalence_count] = right.iColumn;
                            scan.equivalence_count += 1;
                        }
                    }
                }
                if (term.operator & scan.operator_mask == 0) continue;
                if (scan.collation_name != null and term.operator & operation.is_null == 0) {
                    const actual = if (term.operator & operation.in != 0)
                        indexInAffinityCollation(clause.info.parse, term, scan.index_affinity) orelse continue
                    else blk: {
                        if (!expression.indexAffinityOk(term.expression.?, scan.index_affinity)) continue;
                        break :blk if (expression.expressionComparisonCollation(clause.info.parse, term.expression.?)) |collation| collation.zName.? else "BINARY";
                    };
                    if (sqlite_string.compareInternal(actual, scan.collation_name.?) != 0) continue;
                }
                const right = term.expression.?.pRight;
                if (term.operator & (operation.eq | operation.is) != 0 and right != null and right.?.op == tokens.tk_column and right.?.iTable == scan.cursors[0] and right.?.iColumn == scan.columns[0]) continue;
                scan.clause = clause;
                scan.next_index = term_index + 1;
                return term;
            }
            clause = clause.outer orelse break;
            term_index = 0;
        }
        if (scan.equivalence_index >= scan.equivalence_count) return null;
        clause = scan.original_clause;
        term_index = 0;
        scan.equivalence_index += 1;
    }
}

/// Source `whereScanInit()`.
pub fn initializeWhereScan(scan: *WhereScan, clause: *WhereClause, cursor: c_int, column_initial: c_int, operator_mask: u32, index: ?*schema.Index) ?*WhereTerm {
    scan.* = .{ .original_clause = clause, .clause = clause, .operator_mask = operator_mask };
    scan.cursors[0] = cursor;
    var column = column_initial;
    if (index) |present| {
        const position: usize = @intCast(column);
        column = present.columns.?[position];
        if (column == present.table.?.primary_key_column) {
            column = -1;
        } else if (column >= 0) {
            scan.index_affinity = present.table.?.columns.?[@intCast(column)].affinity;
            scan.collation_name = present.collations.?[position];
        } else if (column == -2) {
            const expressions: *parse_types.ExprList = @ptrCast(@alignCast(present.column_expressions.?));
            scan.index_expression = expressions.items()[position].pExpr;
            scan.collation_name = present.collations.?[position];
            scan.columns[0] = -2;
            scan.index_affinity = expression.expressionAffinity(scan.index_expression.?);
            return nextWhereTerm(scan);
        }
    } else if (column == -2) return null;
    scan.columns[0] = @intCast(column);
    return nextWhereTerm(scan);
}

/// Source `sqlite3WhereFindTerm()`.
pub fn findWhereTerm(clause: *WhereClause, cursor: c_int, column: c_int, not_ready: u64, operator_mask_initial: u32, index: ?*schema.Index) ?*WhereTerm {
    var scan: WhereScan = undefined;
    var term = initializeWhereScan(&scan, clause, cursor, column, operator_mask_initial, index);
    const preferred_mask = operator_mask_initial & (operation.eq | operation.is);
    var result: ?*WhereTerm = null;
    while (term) |present| : (term = nextWhereTerm(&scan)) {
        if (present.prerequisites_right & not_ready != 0) continue;
        if (present.prerequisites_right == 0 and present.operator & preferred_mask != 0) return present;
        if (result == null) result = present;
    }
    return result;
}

/// Source `isDistinctRedundant()`.
pub fn distinctIsRedundant(parse: *parse_types.Parse, sources: *parse_types.SrcList, clause: *WhereClause, distinct: *parse_types.ExprList) bool {
    if (sources.nSrc != 1) return false;
    const source = &sources.items()[0];
    for (distinct.items()) |item| {
        const node = expression.skipCollationAndLikely(item.pExpr) orelse continue;
        if ((node.op == tokens.tk_column or node.op == tokens.tk_agg_column) and node.iTable == source.iCursor and node.iColumn < 0) return true;
    }
    var index = source.pSTab.?.indexes;
    while (index) |present| : (index = present.next) {
        if (!present.properties.unique_not_null or present.partial_predicate != null) continue;
        var column: c_int = 0;
        while (column < present.key_column_count) : (column += 1) {
            if (findWhereTerm(clause, source.iCursor, column, ~@as(u64, 0), operation.eq, present) == null) {
                if (where_analysis.findIndexColumn(parse, distinct, source.iCursor, present, column) < 0) break;
                if (!where_analysis.indexColumnNotNull(present, column)) break;
            }
        }
        if (column == present.key_column_count) return true;
    }
    return false;
}

/// Source `whereRangeVectorLen()`.
pub fn rangeVectorLength(parse: *parse_types.Parse, cursor: c_int, index: *schema.Index, equal_count: c_int, term: *WhereTerm) c_int {
    const count = @min(expression.vectorSize(term.expression.?.pLeft.?), @as(c_int, index.column_count) - equal_count);
    var position: c_int = 1;
    while (position < count) : (position += 1) {
        const left = term.expression.?.pLeft.?.x.pList.?.items()[@intCast(position)].pExpr.?;
        const right_container = term.expression.?.pRight.?;
        var right = if (right_container.usesSelect()) right_container.x.pSelect.?.pEList.?.items()[@intCast(position)].pExpr.? else right_container.x.pList.?.items()[@intCast(position)].pExpr.?;
        const index_position: usize = @intCast(position + equal_count);
        if (left.op != tokens.tk_column or left.iTable != cursor or left.iColumn != index.columns.?[index_position] or index.sort_order.?[index_position] != index.sort_order.?[@intCast(equal_count)]) break;
        const comparison_affinity = expression.compareAffinity(right, expression.expressionAffinity(left));
        const index_affinity = index.table.?.columns.?[@intCast(left.iColumn)].affinity;
        if (comparison_affinity != index_affinity) break;
        var comparison_left = left;
        if (term.expression.?.flags & 0x0000_0400 != 0) std.mem.swap(*parse_types.Expr, &comparison_left, &right);
        const collation = expression.binaryComparisonCollation(parse, comparison_left, right) orelse break;
        if (sqlite_string.compareInternal(collation.zName.?, index.collations.?[index_position].?) != 0) break;
    }
    return position;
}

/// Source `whereLoopIsNoBetter()`.
pub fn loopIsNoBetter(candidate: *const WhereLoop, baseline: *const WhereLoop) bool {
    if (candidate.flags & loop_flag.indexed == 0 or baseline.flags & loop_flag.indexed == 0) return true;
    return candidate.choice.btree.index.?.row_size_estimate >= baseline.choice.btree.index.?.row_size_estimate;
}

/// Source `whereSortingCost()`.
pub fn sortingCost(info: *WhereInfo, rows_initial: i16, order_count: c_int, sorted_count: c_int) i16 {
    const result_count = info.select.?.pEList.?.nExpr;
    var rows = rows_initial;
    var result = rows + log_est.fromInt(@intCast(@divTrunc(result_count + 59, 30)));
    if (sorted_count > 0) result += log_est.fromInt(@intCast(@divTrunc((order_count - sorted_count) * 100, order_count))) - 66;
    if (info.control_flags & 0x4000 != 0) {
        result += 10;
        if (sorted_count != 0) result += 6;
        rows = @min(rows, info.limit_estimate);
    } else if (info.control_flags & 0x0100 != 0 and rows > 10) rows -= 10;
    result += if (rows <= 10) 0 else log_est.fromInt(@intCast(rows)) - 33;
    return result;
}

pub const ConstraintUsage = extern struct {
    argument_index: c_int,
    omit: u8,
};

/// Source `allConstraintsUsed()`.
pub fn allConstraintsUsed(usages: []const ConstraintUsage) bool {
    for (usages) |usage| if (usage.argument_index <= 0) return false;
    return true;
}

fn setPlannerError(parse: *parse_types.Parse, message: []const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `sqlite3WhereTabFuncArgs()`.
pub fn addTableFunctionArguments(parse: *parse_types.Parse, source: *parse_types.SrcItem, clause: *WhereClause) void {
    if (!source.fg.isTabFunc) return;
    const arguments = source.u1.pFuncArg orelse return;
    const table = source.pSTab.?;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var column: usize = 0;
    for (arguments.items(), 0..) |argument, argument_index| {
        while (column < @as(usize, @intCast(table.column_count)) and table.columns.?[column].flags & 0x0002 == 0) column += 1;
        if (column >= table.column_count) {
            var buffer: [160]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "too many arguments on {s}() - max {d}", .{ table.name.?, argument_index }) catch "too many table-function arguments";
            setPlannerError(parse, message);
            return;
        }
        const column_reference = expression.newExpression(db, @intCast(tokens.tk_column), null) orelse return;
        column_reference.iTable = source.iCursor;
        column_reference.iColumn = @intCast(column);
        column_reference.y.pTab = table;
        column += 1;
        source.colUsed |= resolve_analysis.expressionColumnUsed(column_reference);
        const duplicate = ast_duplication.duplicateExpression(db, argument.pExpr, false);
        const positive = expression.parsedExpression(parse, @intCast(tokens.tk_uplus), duplicate, null);
        const comparison = expression.parsedExpression(parse, @intCast(tokens.tk_eq), column_reference, positive) orelse return;
        comparison.flags |= if (source.fg.jointype & (0x08 | 0x10) != 0) @as(u32, 0x0000_0001) else @as(u32, 0x0000_0002);
        comparison.w.iJoin = source.iCursor;
        _ = insertClauseTerm(clause, comparison, term_flag.dynamic);
    }
}

/// Source `whereAddLimitExpr()`.
pub fn addLimitExpression(clause: *WhereClause, register: c_int, limit_expression: *parse_types.Expr, cursor: c_int, match_operator: u8) void {
    const parse = clause.info.parse;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var integer: c_int = 0;
    const value = if (expression.isInteger(limit_expression, &integer, parse) and integer >= 0)
        expression.integerExpression(db, integer)
    else blk: {
        const register_expression = expression.newExpression(db, @intCast(tokens.tk_register), null) orelse return;
        register_expression.iTable = register;
        break :blk register_expression;
    };
    const match = expression.parsedExpression(parse, @intCast(tokens.tk_match), null, value) orelse return;
    const term_index = insertClauseTerm(clause, match, term_flag.dynamic | term_flag.virtual) orelse return;
    const term = &clause.terms[@intCast(term_index)];
    term.left_cursor = cursor;
    term.operator = operation.aux;
    term.match_operator = match_operator;
}

/// Source `sqlite3WhereAddLimit()`.
pub fn addSelectLimitTerms(clause: *WhereClause, select: *parse_types.Select) void {
    if (select.pGroupBy != null or select.selFlags & (0x0000_0001 | 0x0000_0020) != 0 or select.pSrc.?.nSrc != 1 or select.pSrc.?.items()[0].pSTab.?.kind != .virtual) return;
    const cursor = select.pSrc.?.items()[0].iCursor;
    for (clause.terms[0..@intCast(clause.term_count)]) |*term| {
        if (term.flags & term_flag.coded != 0) continue;
        if (term.child_count != 0) continue;
        if (term.left_cursor == cursor and term.prerequisites_right == 0) continue;
        if (term.parent_index >= 0) {
            const parent = &clause.terms[@intCast(term.parent_index)];
            if (parent.left_cursor == cursor and parent.prerequisites_right == 0 and parent.child_count == 1) continue;
        }
        return;
    }
    if (select.pOrderBy) |order_by| for (order_by.items()) |item| {
        const node = item.pExpr.?;
        if (node.op != tokens.tk_column or node.iTable != cursor or item.fg.sortFlags & 0x02 != 0) return;
    };
    if (select.iOffset != 0 and select.selFlags & 0x0000_0100 == 0) addLimitExpression(clause, select.iOffset, select.pLimit.?.pRight.?, cursor, 74);
    if (select.iOffset == 0 or select.selFlags & 0x0000_0100 == 0) addLimitExpression(clause, select.iLimit, select.pLimit.?.pLeft.?, cursor, 73);
}

/// Source `whereLoopOutputAdjust()`.
pub fn adjustLoopOutput(clause: *WhereClause, loop: *WhereLoop, table_rows: i16) void {
    const not_allowed = ~(loop.prerequisites | loop.self_mask);
    var reduction: i16 = 0;
    for (clause.terms[0..@intCast(clause.base_count)]) |*term| {
        if (term.prerequisites_all & not_allowed != 0 or term.prerequisites_all & loop.self_mask == 0 or term.flags & term_flag.virtual != 0) continue;
        var used = false;
        for (loop.terms[0..loop.term_count]) |loop_term| if (loop_term) |present| {
            if (present == term or (present.parent_index >= 0 and &clause.terms[@intCast(present.parent_index)] == term)) {
                used = true;
                break;
            }
        };
        if (used) continue;
        if (loop.self_mask == term.prerequisites_all and (term.operator & 0x3f != 0 or clause.info.table_list.?.items()[loop.table_index].fg.jointype & (0x08 | 0x40) == 0)) loop.flags |= loop_flag.self_cull;
        if (term.truth_probability <= 0) {
            loop.output_rows += term.truth_probability;
            continue;
        }
        loop.output_rows -= 1;
        const node = term.expression.?;
        if (term.operator & (operation.eq | operation.is) != 0) {
            var integer: c_int = 0;
            const small = expression.isInteger(node.pRight, &integer, null) and integer >= -1 and integer <= 1;
            const candidate: i16 = if (small) 10 else 20;
            if (reduction < candidate) {
                term.flags |= term_flag.heuristic_truth;
                reduction = candidate;
            }
        } else if (node.op == tokens.tk_function and node.x.pList != null) {
            if (like_optimization.likeOrGlobPrefix(clause.info.parse, node)) |prefix| {
                const db: *types.Sqlite3 = @ptrCast(@alignCast(clause.info.parse.db.?));
                defer compiler_ownership.deleteExpression(db, prefix.expression);
                const byte_count = std.mem.len(prefix.expression.u.zToken.?);
                const prefix_reduction: i16 = @intCast(@min(byte_count, 20));
                loop.output_rows -= prefix_reduction * 2 + @intFromBool(prefix.complete);
            } else {
                const operator = like_optimization.likeOperator(node);
                if (operator != 0) {
                    const pattern = node.x.pList.?.items()[0].pExpr.?;
                    loop.output_rows -= where_analysis.estimateLikePatternLength(pattern, operator == 65) * 2;
                }
            }
        }
    }
    loop.output_rows = @min(loop.output_rows, table_rows - reduction);
}

/// Source `whereInterstageHeuristic()`.
pub fn applyInterstageHeuristic(info: *WhereInfo) void {
    for (info.levels) |level| {
        const chosen = level.loop orelse break;
        if (chosen.flags & loop_flag.virtual_table != 0) break;
        if (chosen.flags & (loop_flag.column_eq | loop_flag.column_null | loop_flag.column_in) == 0) break;
        var candidate = info.loops;
        while (candidate) |loop| : (candidate = loop.next) {
            if (loop.table_index != chosen.table_index) continue;
            if (loop.flags & (0x0000_000f | loop_flag.auto_index) != 0) continue;
            loop.prerequisites = ~@as(u64, 0);
        }
    }
}

/// Source `whereCheckIfBloomFilterIsUseful()`.
pub fn markUsefulBloomFilters(info: *WhereInfo) void {
    var searches: i16 = 0;
    for (info.levels, 0..) |level, level_index| {
        const loop = level.loop.?;
        const table = info.table_list.?.items()[loop.table_index].pSTab.?;
        if (table.flags & 0x0000_0010 == 0) break;
        table.flags |= 0x0000_0100;
        if (level_index >= 1 and loop.flags & (loop_flag.self_cull | loop_flag.column_eq) == (loop_flag.self_cull | loop_flag.column_eq) and searches > table.row_log_estimate) {
            loop.flags |= loop_flag.bloom_filter;
            loop.flags &= ~loop_flag.index_only;
        }
        searches += loop.output_rows;
    }
}

pub const CoveringIndexCheck = struct {
    index: *schema.Index,
    table_cursor: c_int,
    uses_expression: bool = false,
    uses_unindexed: bool = false,
};

fn expressionCoveredByIndex(node: *parse_types.Expr, index: *schema.Index, cursor: c_int) bool {
    const list: *parse_types.ExprList = if (index.column_expressions) |present| @ptrCast(@alignCast(present)) else return false;
    for (index.columns.?[0..index.column_count], 0..) |column, position| if (column == -2 and expression.compareExpressions(null, node, list.items()[position].pExpr, cursor) == 0) return true;
    return false;
}

/// Source `whereIsCoveringIndexWalkCallback()`.
pub fn coveringIndexExpression(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const check: *CoveringIndexCheck = @ptrCast(@alignCast(walker.u.pointer.?));
    if (node.op == tokens.tk_column or node.op == tokens.tk_agg_column) {
        if (node.iTable != check.table_cursor) return walker_api.continue_walk;
        for (check.index.columns.?[0..check.index.column_count]) |column| {
            if (column == node.iColumn) return walker_api.continue_walk;
        }
        check.uses_unindexed = true;
        return walker_api.abort_walk;
    }
    if (check.index.properties.has_expression and expressionCoveredByIndex(node, check.index, check.table_cursor)) {
        check.uses_expression = true;
        return walker_api.prune;
    }
    return walker_api.continue_walk;
}

fn coveringSelectContinue(_: *parse_types.Walker, _: *parse_types.Select) callconv(.c) c_int {
    return walker_api.continue_walk;
}

/// Source `whereIsCoveringIndex()`.
pub fn coveringIndexKind(info: *WhereInfo, index: *schema.Index, table_cursor: c_int) u32 {
    if (info.select == null) return 0;
    if (!index.properties.has_expression) {
        var high_column = false;
        for (index.columns.?[0..index.column_count]) |column| if (column >= 63) {
            high_column = true;
            break;
        };
        if (!high_column) return 0;
    }
    var check = CoveringIndexCheck{ .index = index, .table_cursor = table_cursor };
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.xExprCallback = coveringIndexExpression;
    walker.xSelectCallback = coveringSelectContinue;
    walker.u.pointer = &check;
    _ = walker_api.walkSelect(&walker, info.select);
    if (check.uses_unindexed) return 0;
    return if (check.uses_expression) loop_flag.expression_index else loop_flag.index_only;
}

/// Source `wherePathMatchSubqueryOB()`.
pub fn pathMatchesSubqueryOrder(info: *WhereInfo, loop: *WhereLoop, loop_index: c_int, cursor: c_int, order_by: *parse_types.ExprList, reverse_mask: *u64, satisfied: *u64) bool {
    const subquery_order = loop.choice.btree.order_by.?;
    var outer_index: usize = 0;
    while (satisfied.* & (@as(u64, 1) << @intCast(outer_index)) != 0) outer_index += 1;
    var reversed: u8 = 0;
    var subquery_index: usize = 0;
    while (subquery_index < subquery_order.nExpr and outer_index < order_by.nExpr) : ({
        subquery_index += 1;
        outer_index += 1;
    }) {
        const sub_item = subquery_order.items()[subquery_index];
        if (sub_item.u.x.iOrderByCol == 0) break;
        const outer_item = order_by.items()[outer_index];
        const node = outer_item.pExpr.?;
        if ((node.op != tokens.tk_column and node.op != tokens.tk_agg_column) or node.iTable != cursor or node.iColumn != sub_item.u.x.iOrderByCol - 1) break;
        if (info.control_flags & 0x0040 == 0) {
            if (sub_item.fg.sortFlags & 0x02 != outer_item.fg.sortFlags & 0x02) break;
            const sub_direction = sub_item.fg.sortFlags & 0x01;
            if (subquery_index > 0) {
                if (reversed ^ sub_direction != outer_item.fg.sortFlags & 0x01) break;
            } else {
                reversed = sub_direction ^ (outer_item.fg.sortFlags & 0x01);
                if (reversed != 0) {
                    if (loop.flags & loop_flag.coroutine != 0) break;
                    reverse_mask.* |= @as(u64, 1) << @intCast(loop_index);
                }
            }
        }
        satisfied.* |= @as(u64, 1) << @intCast(outer_index);
    }
    return subquery_index > 0;
}

/// Source `whereShortCut()`.
pub fn shortcutSingleTable(info: *WhereInfo, template: *WhereLoop) bool {
    if (info.control_flags & 0x0040_0000 != 0 or info.table_list.?.nSrc < 1) return false;
    const source = &info.table_list.?.items()[0];
    if (source.pSTab.?.kind == .virtual or source.fg.isIndexedBy or source.fg.notIndexed) return false;
    const clause = info.clause.?;
    template.flags = 0;
    template.skip_count = 0;
    var scan: WhereScan = undefined;
    var term = initializeWhereScan(&scan, clause, source.iCursor, -1, operation.eq | operation.is, null);
    while (term != null and term.?.prerequisites_right != 0) term = nextWhereTerm(&scan);
    if (term) |present| {
        template.flags = loop_flag.column_eq | loop_flag.ipk | loop_flag.one_row;
        template.terms[0] = present;
        template.term_count = 1;
        template.choice.btree.equality_count = 1;
        template.run_cost = 33;
    } else {
        var index = source.pSTab.?.indexes;
        while (index) |present| : (index = present.next) {
            if (present.conflict_action == 0 or present.partial_predicate != null or present.key_column_count > template.static_terms.len) continue;
            const operator_mask: u32 = if (present.properties.unique_not_null) operation.eq | operation.is else operation.eq;
            var column: usize = 0;
            while (column < present.key_column_count) : (column += 1) {
                term = initializeWhereScan(&scan, clause, source.iCursor, @intCast(column), operator_mask, present);
                while (term != null and term.?.prerequisites_right != 0) term = nextWhereTerm(&scan);
                if (term == null) break;
                template.terms[column] = term;
            }
            if (column != present.key_column_count) continue;
            template.flags = loop_flag.column_eq | loop_flag.one_row | loop_flag.indexed;
            if (present.properties.covering or source.colUsed & present.columns_not_indexed == 0) template.flags |= loop_flag.index_only;
            template.term_count = @intCast(column);
            template.choice.btree.equality_count = @intCast(column);
            template.choice.btree.index = present;
            template.run_cost = 39;
            break;
        }
    }
    if (template.flags == 0) return false;
    template.output_rows = 1;
    template.self_mask = 1;
    info.levels[0].loop = template;
    info.levels[0].table_cursor = source.iCursor;
    info.output_rows = 1;
    if (info.order_by) |order| info.order_satisfied = @intCast(order.nExpr);
    if (info.control_flags & 0x0100 != 0) info.distinct_mode = 2;
    if (scan.equivalence_index > 1) template.flags |= loop_flag.transitive;
    return true;
}

/// Source `whereOmitNoopJoin()`.
pub fn omitNoopJoins(info: *WhereInfo, not_ready_initial: u64) u64 {
    var not_ready = not_ready_initial;
    var used = where_analysis.expressionListUsage(&info.mask_set, info.result_set);
    used |= where_analysis.expressionListUsage(&info.mask_set, info.order_by);
    const has_right_join = info.table_list.?.items()[0].fg.jointype & 0x40 != 0;
    var level_index = info.levels.len;
    while (level_index > 1) {
        level_index -= 1;
        const loop = info.levels[level_index].loop.?;
        const source = &info.table_list.?.items()[loop.table_index];
        if (source.fg.jointype & (0x08 | 0x10) != 0x08) continue;
        if (info.control_flags & 0x0100 == 0 and loop.flags & loop_flag.one_row == 0) continue;
        if (used & loop.self_mask != 0) continue;
        var blocked = false;
        for (info.clause.?.terms[0..@intCast(info.clause.?.term_count)]) |term| {
            if (term.prerequisites_all & loop.self_mask != 0 and (term.expression.?.flags & 0x0000_0001 == 0 or term.expression.?.w.iJoin != source.iCursor)) {
                blocked = true;
                break;
            }
            if (has_right_join and term.expression.?.flags & 0x0000_0002 != 0 and term.expression.?.w.iJoin == source.iCursor) {
                blocked = true;
                break;
            }
        }
        if (blocked) continue;
        const lower_mask = (@as(u64, 1) << @intCast(level_index)) - 1;
        info.reverse_mask = lower_mask & info.reverse_mask | (info.reverse_mask >> 1) & ~lower_mask;
        not_ready &= ~loop.self_mask;
        for (info.clause.?.terms[0..@intCast(info.clause.?.term_count)]) |*term| if (term.prerequisites_all & loop.self_mask != 0) {
            term.flags |= term_flag.coded;
            term.prerequisites_all = 0;
        };
        std.mem.copyForwards(WhereLevel, info.levels[level_index .. info.levels.len - 1], info.levels[level_index + 1 ..]);
        info.levels = info.levels[0 .. info.levels.len - 1];
    }
    return not_ready;
}

fn indexedExpressionCleanup(db_opaque: ?*parse_types.Sqlite3, pointer: ?*anyopaque) callconv(.c) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(db_opaque.?));
    const link: *?*parse_types.IndexedExpr = @ptrCast(@alignCast(pointer.?));
    while (link.*) |entry| {
        link.* = entry.next;
        compiler_ownership.deleteExpression(db, entry.expression);
        db_allocator.freeNN(db, entry);
    }
}

/// Source `whereAddIndexedExpr()`.
pub fn addIndexedExpressions(parse: *parse_types.Parse, index: *schema.Index, index_cursor: c_int, source: *parse_types.SrcItem) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const expressions: ?*parse_types.ExprList = if (index.column_expressions) |present| @ptrCast(@alignCast(present)) else null;
    for (index.columns.?[0..index.column_count], 0..) |column, position| {
        const indexed = if (column == -2)
            expressions.?.items()[position].pExpr
        else if (column >= 0 and index.table.?.columns.?[@intCast(column)].flags & 0x0020 != 0)
            schema_analysis.columnExpression(index.table.?, &index.table.?.columns.?[@intCast(column)])
        else
            continue;
        if (expression.isConstant(null, indexed.?)) continue;
        const raw = db_allocator.mallocRaw(db, @sizeOf(parse_types.IndexedExpr)) orelse break;
        const entry: *parse_types.IndexedExpr = @ptrCast(@alignCast(raw));
        entry.* = .{
            .expression = ast_duplication.duplicateExpression(db, indexed, false),
            .data_cursor = source.iCursor,
            .index_cursor = index_cursor,
            .index_column = @intCast(position),
            .maybe_null_row = @intFromBool(source.fg.jointype & (0x08 | 0x40 | 0x10) != 0),
            .affinity = if (index.column_affinities) |affinities| affinities[position] else expression.expressionAffinity(indexed.?),
            .next = parse.pIdxEpr,
        };
        parse.pIdxEpr = entry;
        if (entry.next == null) _ = parse_cleanup.add(parse, indexedExpressionCleanup, &parse.pIdxEpr);
    }
}

/// Source `wherePartIdxExpr()`.
pub fn applyPartialIndexConstants(parse: *parse_types.Parse, index: *schema.Index, predicate_initial: *parse_types.Expr, column_mask: ?*u64, index_cursor: c_int, source: ?*parse_types.SrcItem) void {
    var predicate = predicate_initial;
    if (predicate.op == tokens.tk_and) {
        applyPartialIndexConstants(parse, index, predicate.pRight.?, column_mask, index_cursor, source);
        predicate = predicate.pLeft.?;
    }
    if (predicate.op != tokens.tk_eq and predicate.op != tokens.tk_is) return;
    const left = predicate.pLeft.?;
    const right = predicate.pRight.?;
    if (left.op != tokens.tk_column or !expression.isConstant(null, right)) return;
    if (expression.expressionComparisonCollation(parse, predicate)) |collation| if (sqlite_string.compareInternal(collation.zName.?, "BINARY") != 0) return;
    if (left.iColumn < 0) return;
    const affinity = index.table.?.columns.?[@intCast(left.iColumn)].affinity;
    if (affinity < schema_analysis.affinity.text) return;
    if (source) |item| {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        const raw = db_allocator.mallocRaw(db, @sizeOf(parse_types.IndexedExpr)) orelse return;
        const entry: *parse_types.IndexedExpr = @ptrCast(@alignCast(raw));
        entry.* = .{
            .expression = ast_duplication.duplicateExpression(db, right, false),
            .data_cursor = item.iCursor,
            .index_cursor = index_cursor,
            .index_column = left.iColumn,
            .maybe_null_row = @intFromBool(item.fg.jointype & (0x08 | 0x40) != 0),
            .affinity = affinity,
            .next = parse.pIdxPartExpr,
        };
        parse.pIdxPartExpr = entry;
        if (entry.next == null) _ = parse_cleanup.add(parse, indexedExpressionCleanup, &parse.pIdxPartExpr);
    } else if (left.iColumn < 63) column_mask.?.* &= ~(@as(u64, 1) << @intCast(left.iColumn));
}

/// Source `whereUsablePartialIndex()`.
pub fn partialIndexIsUsable(table_cursor: c_int, join_type: u8, clause: *WhereClause, predicate_initial: *parse_types.Expr) bool {
    if (join_type & 0x40 != 0) return false;
    var predicate = predicate_initial;
    while (predicate.op == tokens.tk_and) {
        if (!partialIndexIsUsable(table_cursor, join_type, clause, predicate.pLeft.?)) return false;
        predicate = predicate.pRight.?;
    }
    for (clause.terms[0..@intCast(clause.term_count)]) |term| {
        const candidate = term.expression.?;
        if ((candidate.flags & 0x0000_0001 == 0 or candidate.w.iJoin == table_cursor) and
            (join_type & 0x20 == 0 or candidate.flags & 0x0000_0001 != 0) and
            expression.expressionImpliesExpression(clause.info.parse, candidate, predicate, table_cursor) and
            !expression.expressionImpliesExpression(clause.info.parse, candidate, predicate, -1) and
            term.flags & term_flag.vnull == 0) return true;
    }
    return false;
}
