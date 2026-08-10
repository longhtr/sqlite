//! Source-corresponding SELECT resolution, WHERE code generation, and window
//! execution primitives. The structures here are native runtime plans used by
//! the transitional SQL frontend while the complete Parse/VDBE compiler is
//! being ported.

const std = @import("std");

pub const Error = error{
    AmbiguousName,
    InvalidFrame,
    InvalidLimit,
    NoSuchColumn,
    OutOfMemory,
    Range,
    Unsupported,
};

pub const Value = union(enum) {
    null_,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

fn valuesEqual(left: Value, right: Value) bool {
    return switch (left) {
        .null_ => right == .null_,
        .integer => |value| switch (right) {
            .integer => |other| value == other,
            .real => |other| @as(f64, @floatFromInt(value)) == other,
            else => false,
        },
        .real => |value| switch (right) {
            .integer => |other| value == @as(f64, @floatFromInt(other)),
            .real => |other| value == other,
            else => false,
        },
        .text => |value| switch (right) {
            .text => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .blob => |value| switch (right) {
            .blob => |other| std.mem.eql(u8, value, other),
            else => false,
        },
    };
}

fn tupleEqual(left: []const Value, right: []const Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!valuesEqual(a, b)) return false;
    }
    return true;
}

fn numeric(value: Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .real => |number| number,
        else => null,
    };
}

pub const WindowRow = struct {
    values: []const Value,
    partition: []const Value = &.{},
    order: []const Value = &.{},
};

pub const WindowFunction = enum {
    row_number,
    rank,
    dense_rank,
    percent_rank,
    cume_dist,
    ntile,
    first_value,
    last_value,
    nth_value,
    lead,
    lag,
};

pub const Boundary = enum { unbounded, preceding, current, following };
pub const FrameKind = enum { rows, range, groups };
pub const Exclude = enum { none, current, group, ties };

pub const WindowRequest = struct {
    function: WindowFunction,
    value_column: usize = 0,
    offset: i64 = 1,
    default_value: Value = .null_,
    frame_kind: FrameKind = .range,
    start: Boundary = .unbounded,
    end: Boundary = .current,
    start_offset: f64 = 0,
    end_offset: f64 = 0,
    exclude: Exclude = .none,
    descending: bool = false,
    big_null: bool = false,
};

pub const WindowState = struct {
    partition_start: usize = 0,
    partition_end: usize = 0,
    frame_start: usize = 0,
    frame_end: usize = 0,
    current: usize = 0,
    rank: usize = 1,
    dense_rank: usize = 1,
    peer_start: usize = 0,
    peer_end: usize = 0,
    accumulator_count: usize = 0,
};

/// Source `windowReadPeerValues()`.
pub fn readPeerValues(row: WindowRow, output: []Value) Error!void {
    if (output.len != row.order.len) return error.Range;
    @memcpy(output, row.order);
}

fn excluded(request: WindowRequest, rows: []const WindowRow, current: usize, candidate: usize) bool {
    const peer = tupleEqual(rows[current].order, rows[candidate].order);
    return switch (request.exclude) {
        .none => false,
        .current => candidate == current,
        .group => peer,
        .ties => peer and candidate != current,
    };
}

/// Source `windowFullScan()`.
pub fn fullWindowScan(rows: []const WindowRow, state: *WindowState, request: WindowRequest) usize {
    var count: usize = 0;
    var index = state.frame_start;
    while (index < state.frame_end) : (index += 1) {
        if (!excluded(request, rows, state.current, index)) {
            count += 1;
        }
    }
    state.accumulator_count = count;
    return count;
}

fn valueAt(rows: []const WindowRow, row: usize, column: usize) Value {
    if (row >= rows.len or column >= rows[row].values.len) return .null_;
    return rows[row].values[column];
}

/// Source `windowReturnOneRow()`.
pub fn returnWindowRow(rows: []const WindowRow, state: *WindowState, request: WindowRequest) Value {
    const partition_count = state.partition_end - state.partition_start;
    return switch (request.function) {
        .row_number => .{ .integer = @intCast(state.current - state.partition_start + 1) },
        .rank => .{ .integer = @intCast(state.rank) },
        .dense_rank => .{ .integer = @intCast(state.dense_rank) },
        .percent_rank => .{ .real = if (partition_count <= 1) 0 else @as(f64, @floatFromInt(state.rank - 1)) / @as(f64, @floatFromInt(partition_count - 1)) },
        .cume_dist => .{ .real = @as(f64, @floatFromInt(state.peer_end - state.partition_start)) / @as(f64, @floatFromInt(partition_count)) },
        .ntile => blk: {
            if (request.offset <= 0) break :blk .null_;
            const buckets: usize = @intCast(request.offset);
            const row = state.current - state.partition_start;
            const large = @mod(partition_count, buckets);
            const small_size = @divTrunc(partition_count, buckets);
            const split = large * (small_size + 1);
            const bucket = if (row < split) @divTrunc(row, small_size + 1) else large + @divTrunc(row - split, @max(small_size, 1));
            break :blk .{ .integer = @intCast(bucket + 1) };
        },
        .first_value => valueAt(rows, state.frame_start, request.value_column),
        .last_value => if (state.frame_end == state.frame_start) .null_ else valueAt(rows, state.frame_end - 1, request.value_column),
        .nth_value => blk: {
            if (request.offset <= 0) break :blk .null_;
            const target = state.frame_start + @as(usize, @intCast(request.offset - 1));
            break :blk if (target < state.frame_end) valueAt(rows, target, request.value_column) else .null_;
        },
        .lead, .lag => blk: {
            const signed_current: i64 = @intCast(state.current);
            const target = if (request.function == .lead) signed_current + request.offset else signed_current - request.offset;
            if (target < @as(i64, @intCast(state.partition_start)) or target >= @as(i64, @intCast(state.partition_end))) break :blk request.default_value;
            break :blk valueAt(rows, @intCast(target), request.value_column);
        },
    };
}

/// Source `windowInitAccum()`.
pub fn initializeWindowAccumulator(state: *WindowState, partition_start: usize, partition_end: usize) Error!void {
    if (partition_start > partition_end) return error.InvalidFrame;
    state.* = .{
        .partition_start = partition_start,
        .partition_end = partition_end,
        .frame_start = partition_start,
        .frame_end = partition_start,
        .current = partition_start,
        .peer_start = partition_start,
        .peer_end = partition_start,
    };
}

/// Source `windowCodeRangeTest()`.
pub fn rangeTest(left: Value, offset: f64, right: Value, descending: bool, big_null: bool, inclusive: bool) bool {
    if (left == .null_ or right == .null_) {
        if (left == .null_ and right == .null_) return inclusive;
        return if (big_null) left == .null_ else right != .null_;
    }
    const left_number = numeric(left) orelse return valuesEqual(left, right);
    const right_number = numeric(right) orelse return false;
    const adjusted = if (descending) left_number - offset else left_number + offset;
    return if (inclusive) adjusted >= right_number else adjusted > right_number;
}

pub const WindowOperation = enum { step, inverse, return_row };

/// Source `windowCodeOp()`.
pub fn codeWindowOperation(rows: []const WindowRow, state: *WindowState, request: WindowRequest, operation: WindowOperation) ?Value {
    switch (operation) {
        .step => {
            if (state.frame_end < state.partition_end) {
                state.frame_end += 1;
            }
            _ = fullWindowScan(rows, state, request);
            return null;
        },
        .inverse => {
            if (request.start != .unbounded and state.frame_start < state.frame_end) {
                state.frame_start += 1;
            }
            _ = fullWindowScan(rows, state, request);
            return null;
        },
        .return_row => return returnWindowRow(rows, state, request),
    }
}

/// Source `windowExprGtZero()`.
pub fn expressionGreaterThanZero(value: Value) bool {
    const number = numeric(value) orelse return false;
    return number > 0;
}

fn boundedRow(index: usize, boundary: Boundary, offset: f64, start: usize, end: usize, is_start: bool) usize {
    const amount: usize = @intFromFloat(@max(@trunc(offset), 0));
    return switch (boundary) {
        .unbounded => if (is_start) start else end,
        .current => if (is_start) index else @min(index + 1, end),
        .preceding => if (is_start) index -| amount else @min(index -| amount + 1, end),
        .following => if (is_start) @min(index + amount, end) else @min(index + amount + 1, end),
    };
}

/// Source `sqlite3WindowCodeStep()`.
pub fn codeWindowStep(allocator: std.mem.Allocator, rows: []const WindowRow, request: WindowRequest) Error![]Value {
    const output = allocator.alloc(Value, rows.len) catch return error.OutOfMemory;
    errdefer allocator.free(output);
    var partition_start: usize = 0;
    while (partition_start < rows.len) {
        var partition_end = partition_start + 1;
        while (partition_end < rows.len and tupleEqual(rows[partition_start].partition, rows[partition_end].partition)) : (partition_end += 1) {}
        var state = WindowState{};
        try initializeWindowAccumulator(&state, partition_start, partition_end);
        var dense_rank: usize = 1;
        var index = partition_start;
        while (index < partition_end) : (index += 1) {
            state.current = index;
            state.peer_start = index;
            while (state.peer_start > partition_start and tupleEqual(rows[index].order, rows[state.peer_start - 1].order)) {
                state.peer_start -= 1;
            }
            state.peer_end = index + 1;
            while (state.peer_end < partition_end and tupleEqual(rows[index].order, rows[state.peer_end].order)) {
                state.peer_end += 1;
            }
            if (index > partition_start and !tupleEqual(rows[index - 1].order, rows[index].order)) {
                dense_rank += 1;
            }
            state.rank = state.peer_start - partition_start + 1;
            state.dense_rank = dense_rank;
            if (request.frame_kind == .rows) {
                state.frame_start = boundedRow(index, request.start, request.start_offset, partition_start, partition_end, true);
                state.frame_end = boundedRow(index, request.end, request.end_offset, partition_start, partition_end, false);
            } else {
                state.frame_start = if (request.start == .current) state.peer_start else boundedRow(index, request.start, request.start_offset, partition_start, partition_end, true);
                state.frame_end = if (request.end == .current) state.peer_end else boundedRow(index, request.end, request.end_offset, partition_start, partition_end, false);
            }
            if (state.frame_start > state.frame_end) {
                state.frame_start = state.frame_end;
            }
            _ = fullWindowScan(rows, &state, request);
            output[index] = returnWindowRow(rows, &state, request);
        }
        partition_start = partition_end;
    }
    return output;
}

pub const Source = struct {
    database: []const u8 = "main",
    table: []const u8,
    alias: ?[]const u8 = null,
    columns: []const []const u8,
    cursor: usize,
    nullable: bool = false,
};

pub const ResolvedName = struct { source: usize, column: usize, cursor: usize, nullable: bool };

pub const Expression = struct {
    text: []const u8,
    alias: ?[]const u8 = null,
    resolved: ?ResolvedName = null,
    integer: ?i64 = null,
    aggregate: bool = false,
    window: bool = false,
    invalid: bool = false,
};

pub const NameContext = struct {
    sources: []const Source,
    aliases: []const Expression = &.{},
    outer: ?*NameContext = null,
    references: usize = 0,
    allow_aggregate: bool = true,
    allow_window: bool = true,
};

fn splitName(name: []const u8) struct { database: ?[]const u8, table: ?[]const u8, column: []const u8 } {
    var pieces: [3][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, name, '.');
    while (iterator.next()) |piece| {
        if (count == pieces.len) return .{ .database = null, .table = null, .column = name };
        pieces[count] = piece;
        count += 1;
    }
    return switch (count) {
        3 => .{ .database = pieces[0], .table = pieces[1], .column = pieces[2] },
        2 => .{ .database = null, .table = pieces[0], .column = pieces[1] },
        else => .{ .database = null, .table = null, .column = pieces[0] },
    };
}

/// Source `lookupName()`.
pub fn lookupName(context_initial: *NameContext, name: []const u8) Error!ResolvedName {
    const qualified = splitName(name);
    var context: ?*NameContext = context_initial;
    while (context) |current| {
        var match: ?ResolvedName = null;
        for (current.sources, 0..) |source, source_index| {
            if (qualified.database) |database| {
                if (!std.ascii.eqlIgnoreCase(database, source.database)) continue;
            }
            if (qualified.table) |table| {
                const source_name = source.alias orelse source.table;
                if (!std.ascii.eqlIgnoreCase(table, source_name)) continue;
            }
            for (source.columns, 0..) |column, column_index| {
                if (!std.ascii.eqlIgnoreCase(qualified.column, column)) continue;
                if (match != null) return error.AmbiguousName;
                match = .{ .source = source_index, .column = column_index, .cursor = source.cursor, .nullable = source.nullable };
            }
        }
        if (match) |resolved| {
            var reference_context: ?*NameContext = context_initial;
            while (reference_context) |reference| {
                reference.references += 1;
                if (reference == current) break;
                reference_context = reference.outer;
            }
            return resolved;
        }
        if (qualified.table == null) {
            for (current.aliases, 0..) |expression, index| {
                if (expression.alias) |alias| {
                    if (std.ascii.eqlIgnoreCase(alias, qualified.column)) return .{ .source = std.math.maxInt(usize), .column = index, .cursor = std.math.maxInt(usize), .nullable = true };
                }
            }
        }
        context = current.outer;
    }
    return error.NoSuchColumn;
}

/// Source `resolveExprStep()`.
pub fn resolveExpressionStep(context: *NameContext, expression: *Expression) Error!void {
    if (expression.aggregate and !context.allow_aggregate) {
        expression.invalid = true;
        return error.Unsupported;
    }
    if (expression.window and !context.allow_window) {
        expression.invalid = true;
        return error.Unsupported;
    }
    if (std.fmt.parseInt(i64, expression.text, 10)) |integer| {
        expression.integer = integer;
        return;
    } else |_| {}
    expression.resolved = try lookupName(context, expression.text);
}

pub const OrderTerm = struct { expression: Expression, result_column: ?usize = null, descending: bool = false };

/// Source `resolveOrderByTermToExprList()`.
pub fn resolveOrderByTerm(results: []const Expression, term: *OrderTerm, context: *NameContext) Error!?usize {
    try resolveExpressionStep(context, &term.expression);
    for (results, 0..) |result, index| {
        if (std.ascii.eqlIgnoreCase(result.text, term.expression.text)) return index;
    }
    return null;
}

/// Source `resolveCompoundOrderBy()`.
pub fn resolveCompoundOrderBy(compounds: []const []const Expression, terms: []OrderTerm, context: *NameContext) Error!void {
    for (terms) |*term| {
        if (term.expression.integer) |position| {
            if (position <= 0 or compounds.len == 0 or position > compounds[0].len) return error.Range;
            term.result_column = @intCast(position - 1);
            continue;
        }
        for (compounds) |results| {
            if (try resolveOrderByTerm(results, term, context)) |column| {
                term.result_column = column;
                break;
            }
        }
        if (term.result_column == null) return error.NoSuchColumn;
    }
}

/// Source `sqlite3ResolveOrderGroupBy()`.
pub fn resolveOrderGroupByAliases(results: []const Expression, terms: []OrderTerm) Error!void {
    for (terms) |*term| {
        const column = term.result_column orelse continue;
        if (column >= results.len) return error.Range;
        term.expression = results[column];
    }
}

/// Source `resolveOrderGroupBy()`.
pub fn resolveOrderGroupBy(results: []const Expression, terms: []OrderTerm, context: *NameContext, group_by: bool) Error!void {
    for (terms) |*term| {
        if (!group_by) {
            for (results, 0..) |result, index| {
                if (result.alias != null and std.ascii.eqlIgnoreCase(result.alias.?, term.expression.text)) {
                    term.result_column = index;
                    break;
                }
            }
        }
        if (term.result_column == null) {
            if (std.fmt.parseInt(i64, term.expression.text, 10)) |position| {
                if (position <= 0 or position > results.len) return error.Range;
                term.result_column = @intCast(position - 1);
            } else |_| {
                _ = try resolveOrderByTerm(results, term, context);
            }
        }
    }
    try resolveOrderGroupByAliases(results, terms);
}

pub const SelectPlan = struct {
    results: []Expression,
    sources: []const Source,
    where_expression: ?Expression = null,
    having: ?Expression = null,
    order_by: []OrderTerm = &.{},
    group_by: []OrderTerm = &.{},
    resolved: bool = false,
    aggregate: bool = false,
};

/// Source `resolveSelectStep()`.
pub fn resolveSelectStep(plan: *SelectPlan, outer: ?*NameContext) Error!void {
    if (plan.resolved) return;
    var context = NameContext{ .sources = plan.sources, .aliases = plan.results, .outer = outer };
    try resolveExpressionListNames(&context, plan.results);
    for (plan.results) |result| {
        plan.aggregate = plan.aggregate or result.aggregate;
    }
    if (plan.having != null and !plan.aggregate) return error.Unsupported;
    if (plan.having) |*having| try resolveExpressionNames(&context, having);
    if (plan.where_expression) |*where_expression| {
        context.allow_aggregate = false;
        context.allow_window = false;
        try resolveExpressionNames(&context, where_expression);
        context.allow_aggregate = true;
        context.allow_window = true;
    }
    try resolveOrderGroupBy(plan.results, plan.order_by, &context, false);
    context.allow_window = false;
    try resolveOrderGroupBy(plan.results, plan.group_by, &context, true);
    plan.resolved = true;
}

/// Source `sqlite3ResolveExprNames()`.
pub fn resolveExpressionNames(context: *NameContext, expression: *Expression) Error!void {
    const saved_aggregate = context.allow_aggregate;
    const saved_window = context.allow_window;
    defer {
        context.allow_aggregate = saved_aggregate;
        context.allow_window = saved_window;
    }
    try resolveExpressionStep(context, expression);
}

/// Source `sqlite3ResolveExprListNames()`.
pub fn resolveExpressionListNames(context: *NameContext, expressions: []Expression) Error!void {
    for (expressions) |*expression| try resolveExpressionNames(context, expression);
}

/// Source `sqlite3ResolveSelectNames()`.
pub fn resolveSelectNames(plan: *SelectPlan, outer: ?*NameContext) Error!void {
    try resolveSelectStep(plan, outer);
}

/// Source `sqlite3ResolveSelfReference()`.
pub fn resolveSelfReference(source: Source, expressions: []Expression, kind_allows_functions: bool) Error!void {
    var sources = [_]Source{source};
    var context = NameContext{ .sources = &sources, .allow_aggregate = false, .allow_window = false };
    for (expressions) |*expression| {
        if (!kind_allows_functions and (expression.aggregate or expression.window)) return error.Unsupported;
        try resolveExpressionNames(&context, expression);
    }
}

pub const CompareOperator = enum { equal, is_, is_null, in, greater, less };
pub const WhereTerm = struct {
    column: usize,
    operator: CompareOperator,
    values: []const Value = &.{},
    coded: bool = false,
    like_condition: bool = false,
    parent: ?usize = null,
    children: usize = 0,
    prerequisite_mask: u64 = 0,
};

pub const IndexPlan = struct {
    name: []const u8,
    columns: []const []const u8,
    equality_count: usize = 0,
    skip_count: usize = 0,
    bottom_terms: usize = 0,
    top_terms: usize = 0,
    unique: bool = false,
    covering: bool = false,
    automatic: bool = false,
    partial: bool = false,
};

pub const PlanOperation = union(enum) {
    affinity: struct { base: usize, bytes: []const u8 },
    compare: struct { column: usize, operator: CompareOperator },
    copy: struct { source: usize, destination: usize },
    deferred_seek: struct { table_cursor: usize, index_cursor: usize },
    explain: []const u8,
    filter: struct { register: usize, fields: usize },
    make_record: struct { base: usize, count: usize, output: usize },
    null_: usize,
    open_ephemeral: struct { cursor: usize, columns: usize },
    value: struct { register: usize, value: Value },
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(PlanOperation) = .empty,
    next_register: usize = 1,

    pub fn deinit(self: *Program) void {
        for (self.operations.items) |operation| switch (operation) {
            .explain => |text| self.allocator.free(text),
            .affinity => |entry| self.allocator.free(entry.bytes),
            else => {},
        };
        self.operations.deinit(self.allocator);
    }
};

fn appendBytes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) Error!void {
    output.appendSlice(allocator, bytes) catch return error.OutOfMemory;
}

/// Source `explainAppendTerm()`.
pub fn explainAppendTerm(output: *std.ArrayList(u8), allocator: std.mem.Allocator, columns: []const []const u8, first: usize, count: usize, and_prefix: bool, operator: u8) Error!void {
    if (count == 0 or first + count > columns.len) return error.Range;
    if (and_prefix) try appendBytes(output, allocator, " AND ");
    if (count > 1) try output.append(allocator, '(');
    for (columns[first .. first + count], 0..) |column, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendBytes(output, allocator, column);
    }
    if (count > 1) try output.append(allocator, ')');
    try output.append(allocator, operator);
    if (count > 1) try output.append(allocator, '(');
    for (0..count) |index| {
        if (index != 0) try output.append(allocator, ',');
        try output.append(allocator, '?');
    }
    if (count > 1) try output.append(allocator, ')');
}

/// Source `explainIndexRange()`.
pub fn explainIndexRange(output: *std.ArrayList(u8), allocator: std.mem.Allocator, index: IndexPlan) Error!void {
    if (index.equality_count == 0 and index.bottom_terms == 0 and index.top_terms == 0) return;
    try appendBytes(output, allocator, " (");
    for (0..index.equality_count) |column| {
        if (column != 0) try appendBytes(output, allocator, " AND ");
        if (column < index.skip_count) try appendBytes(output, allocator, "ANY(");
        try appendBytes(output, allocator, index.columns[column]);
        if (column < index.skip_count) try output.append(allocator, ')') else try appendBytes(output, allocator, "=?");
    }
    const range_column = index.equality_count;
    if (index.bottom_terms != 0) try explainAppendTerm(output, allocator, index.columns, range_column, index.bottom_terms, index.equality_count != 0, '>');
    if (index.top_terms != 0) try explainAppendTerm(output, allocator, index.columns, range_column, index.top_terms, index.equality_count != 0 or index.bottom_terms != 0, '<');
    try output.append(allocator, ')');
}

pub const ScanPlan = struct { table: []const u8, index: ?IndexPlan = null, virtual_index: ?[]const u8 = null, left_join: bool = false, estimated_rows: u64 = 0 };

/// Source `sqlite3WhereAddExplainText()`.
pub fn addWhereExplainText(allocator: std.mem.Allocator, scan: ScanPlan) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const searching = scan.index != null and (scan.index.?.equality_count != 0 or scan.index.?.bottom_terms != 0 or scan.index.?.top_terms != 0);
    try appendBytes(&output, allocator, if (searching) "SEARCH " else "SCAN ");
    try appendBytes(&output, allocator, scan.table);
    if (scan.index) |index| {
        try appendBytes(&output, allocator, if (index.covering) " USING COVERING INDEX " else " USING INDEX ");
        try appendBytes(&output, allocator, index.name);
        try explainIndexRange(&output, allocator, index);
    } else if (scan.virtual_index) |virtual_index| {
        try appendBytes(&output, allocator, " VIRTUAL TABLE INDEX ");
        try appendBytes(&output, allocator, virtual_index);
    }
    if (scan.left_join) try appendBytes(&output, allocator, " LEFT-JOIN");
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Source `sqlite3WhereExplainOneScan()`.
pub fn explainOneScan(program: *Program, scan: ScanPlan, enabled: bool) Error!?usize {
    if (!enabled) return null;
    const text = try addWhereExplainText(program.allocator, scan);
    errdefer program.allocator.free(text);
    const address = program.operations.items.len;
    program.operations.append(program.allocator, .{ .explain = text }) catch return error.OutOfMemory;
    return address;
}

/// Source `sqlite3WhereExplainBloomFilter()`.
pub fn explainBloomFilter(program: *Program, table: []const u8, columns: []const []const u8) Error!usize {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(program.allocator);
    try appendBytes(&text, program.allocator, "BLOOM FILTER ON ");
    try appendBytes(&text, program.allocator, table);
    try appendBytes(&text, program.allocator, " (");
    for (columns, 0..) |column, index| {
        if (index != 0) try appendBytes(&text, program.allocator, " AND ");
        try appendBytes(&text, program.allocator, column);
        try appendBytes(&text, program.allocator, "=?");
    }
    try text.append(program.allocator, ')');
    const owned = text.toOwnedSlice(program.allocator) catch return error.OutOfMemory;
    errdefer program.allocator.free(owned);
    const address = program.operations.items.len;
    program.operations.append(program.allocator, .{ .explain = owned }) catch return error.OutOfMemory;
    return address;
}

/// Source `disableTerm()`.
pub fn disableWhereTerm(terms: []WhereTerm, level_not_ready: u64, left_join: bool, index_initial: usize) void {
    var index = index_initial;
    var depth: usize = 0;
    while (!terms[index].coded and (!left_join or terms[index].prerequisite_mask == 0) and terms[index].prerequisite_mask & level_not_ready == 0) {
        if (depth != 0 and terms[index].like_condition) {
            terms[index].like_condition = true;
        } else {
            terms[index].coded = true;
        }
        const parent = terms[index].parent orelse break;
        if (terms[parent].children != 0) {
            terms[parent].children -= 1;
        }
        if (terms[parent].children != 0) break;
        index = parent;
        depth += 1;
    }
}

/// Source `codeApplyAffinity()`.
pub fn codeApplyAffinities(program: *Program, base_initial: usize, affinities_initial: []const u8) Error!void {
    var base = base_initial;
    var affinities = affinities_initial;
    while (affinities.len != 0 and affinities[0] <= 'B') {
        affinities = affinities[1..];
        base += 1;
    }
    while (affinities.len > 1 and affinities[affinities.len - 1] <= 'B') {
        affinities = affinities[0 .. affinities.len - 1];
    }
    if (affinities.len == 0) return;
    const owned = program.allocator.dupe(u8, affinities) catch return error.OutOfMemory;
    errdefer program.allocator.free(owned);
    program.operations.append(program.allocator, .{ .affinity = .{ .base = base, .bytes = owned } }) catch return error.OutOfMemory;
}

/// Source `updateRangeAffinityStr()`.
pub fn updateRangeAffinity(values: []const Value, affinities: []u8) Error!void {
    if (values.len > affinities.len) return error.Range;
    for (values, 0..) |value, index| {
        const compatible = switch (value) {
            .null_, .blob => false,
            .integer, .real => affinities[index] == 'C' or affinities[index] == 'D' or affinities[index] == 'E',
            .text => affinities[index] == 'A' or affinities[index] == 'B',
        };
        if (!compatible) {
            affinities[index] = 'B';
        }
    }
}

/// Source `adjustOrderByCol()`.
pub fn adjustOrderByColumns(order: []?usize, projection: []const ?usize) void {
    for (order) |*column| {
        const wanted = column.* orelse continue;
        column.* = null;
        for (projection, 0..) |original, index| {
            if (original != null and original.? == wanted) {
                column.* = index;
                break;
            }
        }
    }
}

/// Source `removeUnindexableInClauseTerms()`.
pub fn removeUnindexableInTerms(allocator: std.mem.Allocator, values: []const Value, used_fields: []const usize, order_columns: []?usize) Error![]Value {
    const output = allocator.alloc(Value, used_fields.len) catch return error.OutOfMemory;
    errdefer allocator.free(output);
    for (used_fields, 0..) |field, index| {
        if (field >= values.len) return error.Range;
        output[index] = values[field];
    }
    var mapping = allocator.alloc(?usize, used_fields.len) catch return error.OutOfMemory;
    defer allocator.free(mapping);
    for (used_fields, 0..) |field, index| mapping[index] = field;
    adjustOrderByColumns(order_columns, mapping);
    return output;
}

/// Source `codeINTerm()`.
pub fn codeInTerm(program: *Program, term: *WhereTerm, target_register: usize, reverse: bool) Error!usize {
    if (term.operator != .in) return error.Unsupported;
    var register = target_register;
    if (reverse) {
        var index = term.values.len;
        while (index > 0) {
            index -= 1;
            program.operations.append(program.allocator, .{ .value = .{ .register = register, .value = term.values[index] } }) catch return error.OutOfMemory;
            register += 1;
        }
    } else {
        for (term.values) |value| {
            program.operations.append(program.allocator, .{ .value = .{ .register = register, .value = value } }) catch return error.OutOfMemory;
            register += 1;
        }
    }
    term.coded = true;
    return register - target_register;
}

/// Source `codeEqualityTerm()`.
pub fn codeEqualityTerm(program: *Program, term: *WhereTerm, target_register: usize, reverse: bool) Error!usize {
    switch (term.operator) {
        .equal, .is_ => {
            const value = if (term.values.len == 0) Value.null_ else term.values[0];
            program.operations.append(program.allocator, .{ .value = .{ .register = target_register, .value = value } }) catch return error.OutOfMemory;
        },
        .is_null => program.operations.append(program.allocator, .{ .null_ = target_register }) catch return error.OutOfMemory,
        .in => _ = try codeInTerm(program, term, target_register, reverse),
        else => return error.Unsupported,
    }
    term.coded = true;
    return target_register;
}

/// Source `codeAllEqualityTerms()`.
pub fn codeAllEqualityTerms(program: *Program, terms: []WhereTerm, equality_count: usize, skip_count: usize, affinities: []u8, reverse: bool) Error!usize {
    if (equality_count > terms.len or equality_count > affinities.len or skip_count > equality_count) return error.Range;
    const base = program.next_register;
    program.next_register += equality_count;
    for (skip_count..equality_count) |index| {
        _ = try codeEqualityTerm(program, &terms[index], base + index, reverse);
        if (terms[index].values.len == 0 or std.meta.activeTag(terms[index].values[0]) == .null_) {
            affinities[index] = 'B';
        }
    }
    return base;
}

/// Source `whereLikeOptimizationStringFixup()`.
pub fn fixLikeString(operation: *PlanOperation, counter_register: usize, descending: bool) Error!void {
    if (std.meta.activeTag(operation.*) != .value) return error.Unsupported;
    operation.value.register = counter_register;
    if (descending and operation.value.value == .text) {
        const text = operation.value.value.text;
        operation.value.value = .{ .text = text };
    }
}

/// Source `codeDeferredSeek()`.
pub fn codeDeferredSeek(program: *Program, table_cursor: usize, index_cursor: usize, column_map: []?usize) Error!void {
    if (index_cursor == 0) return error.Range;
    for (column_map) |column| {
        if (column) |mapped| {
            if (mapped >= column_map.len) return error.Range;
        }
    }
    program.operations.append(program.allocator, .{ .deferred_seek = .{ .table_cursor = table_cursor, .index_cursor = index_cursor } }) catch return error.OutOfMemory;
}

/// Source `codeExprOrVector()`.
pub fn codeExpressionOrVector(program: *Program, values: []const Value, first_register: usize, register_count: usize) Error!void {
    if (values.len != register_count or register_count == 0) return error.Range;
    for (values, 0..) |value, index| {
        program.operations.append(program.allocator, .{ .value = .{ .register = first_register + index, .value = value } }) catch return error.OutOfMemory;
    }
}

/// Source `whereApplyPartialIndexConstraints()`.
pub fn applyPartialIndexConstraints(terms: []WhereTerm, truth_columns: []const usize) void {
    for (truth_columns) |column| {
        for (terms) |*term| {
            if (!term.coded and term.column == column and term.operator == .equal) {
                term.coded = true;
            }
        }
    }
}

pub const FilterLevel = struct { register: usize = 0, skip_count: usize = 0, prerequisites: u64 = 0, equality_count: usize = 0 };

/// Source `filterPullDown()`.
pub fn pullDownFilter(program: *Program, levels: []FilterLevel, start_level: usize, not_ready: u64) Error!usize {
    var emitted: usize = 0;
    if (start_level >= levels.len) return emitted;
    for (levels[start_level + 1 ..]) |*level| {
        if (level.register == 0 or level.skip_count != 0 or level.prerequisites & not_ready == 0) continue;
        program.operations.append(program.allocator, .{ .filter = .{ .register = level.register, .fields = level.equality_count } }) catch return error.OutOfMemory;
        level.register = 0;
        emitted += 1;
    }
    return emitted;
}

/// Source `whereLoopIsOneRow()`.
pub fn loopIsOneRow(index: IndexPlan, terms: []const WhereTerm) bool {
    if (!index.unique or index.skip_count != 0 or index.equality_count != index.columns.len or terms.len < index.equality_count) return false;
    for (terms[0..index.equality_count]) |term| {
        if (term.operator == .is_ or term.operator == .is_null) return false;
    }
    return true;
}

/// Source `sqlite3WhereRightJoinLoop()`.
pub fn codeRightJoinLoop(program: *Program, matched_keys: []const Value, right_rows: []const []const Value, key_column: usize, output_rows: *std.ArrayList([]const Value)) Error!void {
    for (right_rows) |row| {
        if (key_column >= row.len) return error.Range;
        var matched = false;
        for (matched_keys) |key| {
            if (valuesEqual(key, row[key_column])) {
                matched = true;
                break;
            }
        }
        if (!matched) output_rows.append(program.allocator, row) catch return error.OutOfMemory;
    }
    program.operations.append(program.allocator, .{ .filter = .{ .register = 0, .fields = 1 } }) catch return error.OutOfMemory;
}

pub const CompiledSelect = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList([]Value) = .empty,
    operations: std.ArrayList(PlanOperation) = .empty,
    limit: ?usize = null,
    offset: usize = 0,

    pub fn deinit(self: *CompiledSelect) void {
        for (self.rows.items) |row| self.allocator.free(row);
        self.rows.deinit(self.allocator);
        self.operations.deinit(self.allocator);
    }
};

/// Source `clearSelect()`.
pub fn clearSelect(select: *CompiledSelect, free_storage: bool) void {
    for (select.rows.items) |row| select.allocator.free(row);
    select.rows.clearRetainingCapacity();
    select.operations.clearRetainingCapacity();
    select.limit = null;
    select.offset = 0;
    if (free_storage) {
        select.rows.deinit(select.allocator);
        select.operations.deinit(select.allocator);
        select.rows = .empty;
        select.operations = .empty;
    }
}

/// Source `innerLoopLoadRow()`.
pub fn loadInnerLoopRow(destination: []Value, expressions: []const Value, extra: []const Value) Error!void {
    if (destination.len != expressions.len + extra.len) return error.Range;
    @memcpy(destination[0..expressions.len], expressions);
    @memcpy(destination[expressions.len..], extra);
}

/// Source `makeSorterRecord()`.
pub fn makeSorterRecord(program: *Program, register_base: usize, field_count: usize, satisfied_order_terms: usize) Error!usize {
    if (satisfied_order_terms > field_count) return error.Range;
    const output = program.next_register;
    program.next_register += 1;
    program.operations.append(program.allocator, .{ .make_record = .{ .base = register_base + satisfied_order_terms, .count = field_count - satisfied_order_terms, .output = output } }) catch return error.OutOfMemory;
    return output;
}

pub const DistinctMode = enum { unordered, ordered, unique };

/// Source `codeDistinct()`.
pub fn codeDistinct(allocator: std.mem.Allocator, rows: []const []const Value, mode: DistinctMode) Error![]bool {
    const keep = allocator.alloc(bool, rows.len) catch return error.OutOfMemory;
    errdefer allocator.free(keep);
    @memset(keep, true);
    if (mode == .unique) return keep;
    for (rows, 0..) |row, index| {
        const start: usize = if (mode == .ordered and index != 0) index - 1 else 0;
        for (rows[start..index]) |prior| {
            if (tupleEqual(row, prior)) {
                keep[index] = false;
                break;
            }
        }
    }
    return keep;
}

/// Source `fixDistinctOpenEph()`.
pub fn fixDistinctOpenEphemeral(operations: []PlanOperation, mode: DistinctMode, value_register: usize, open_address: usize) Error!void {
    if (open_address >= operations.len) return error.Range;
    if (mode == .unordered) return;
    operations[open_address] = if (mode == .ordered) .{ .null_ = value_register } else .{ .copy = .{ .source = value_register, .destination = value_register } };
    if (open_address + 1 < operations.len and std.meta.activeTag(operations[open_address + 1]) == .explain) {
        operations[open_address + 1] = .{ .null_ = 0 };
    }
}

pub const LimitRegisters = struct { limit: ?usize = null, offset: ?usize = null };

/// Source `computeLimitRegisters()`.
pub fn computeLimitRegisters(program: *Program, limit_value: ?i64, offset_value: ?i64, estimated_rows: *u64) Error!LimitRegisters {
    var result = LimitRegisters{};
    if (limit_value) |limit| {
        if (limit == 0) {
            estimated_rows.* = 0;
        }
        if (limit > 0) {
            estimated_rows.* = @min(estimated_rows.*, @as(u64, @intCast(limit)));
        }
        result.limit = program.next_register;
        program.next_register += 1;
        program.operations.append(program.allocator, .{ .value = .{ .register = result.limit.?, .value = .{ .integer = limit } } }) catch return error.OutOfMemory;
    }
    if (offset_value) |offset| {
        if (offset < 0) return error.InvalidLimit;
        result.offset = program.next_register;
        program.next_register += 2;
        program.operations.append(program.allocator, .{ .value = .{ .register = result.offset.?, .value = .{ .integer = offset } } }) catch return error.OutOfMemory;
    }
    return result;
}

/// Source `multiSelectValues()`.
pub fn multiSelectValues(select: *CompiledSelect, rows: []const []const Value, show_all: bool) Error!usize {
    const count = if (show_all) rows.len else @min(rows.len, 1);
    for (rows[0..count]) |row| {
        const copy = select.allocator.dupe(Value, row) catch return error.OutOfMemory;
        errdefer select.allocator.free(copy);
        select.rows.append(select.allocator, copy) catch return error.OutOfMemory;
    }
    return count;
}

pub const AggregatePlan = struct { argument_count: usize, distinct_cursor: ?usize = null, order_cursor: ?usize = null, accumulator_register: usize = 0, ordered_values: std.ArrayList(Value) = .empty };

/// Source `resetAccumulator()`.
pub fn resetAccumulator(program: *Program, aggregates: []AggregatePlan) Error!void {
    for (aggregates) |*aggregate| {
        aggregate.accumulator_register = program.next_register;
        program.next_register += 1;
        program.operations.append(program.allocator, .{ .null_ = aggregate.accumulator_register }) catch return error.OutOfMemory;
        if (aggregate.distinct_cursor) |cursor| {
            program.operations.append(program.allocator, .{ .open_ephemeral = .{ .cursor = cursor, .columns = 1 } }) catch return error.OutOfMemory;
        }
        if (aggregate.order_cursor) |cursor| {
            program.operations.append(program.allocator, .{ .open_ephemeral = .{ .cursor = cursor, .columns = aggregate.argument_count } }) catch return error.OutOfMemory;
        }
        aggregate.ordered_values.clearRetainingCapacity();
    }
}

/// Source `finalizeAggFunctions()`.
pub fn finalizeAggregateFunctions(program: *Program, aggregates: []AggregatePlan) Error![]Value {
    const results = program.allocator.alloc(Value, aggregates.len) catch return error.OutOfMemory;
    errdefer program.allocator.free(results);
    for (aggregates, 0..) |*aggregate, index| {
        if (aggregate.order_cursor != null) std.sort.heap(Value, aggregate.ordered_values.items, {}, struct {
            fn lessThan(_: void, left: Value, right: Value) bool {
                const a = numeric(left) orelse return false;
                const b = numeric(right) orelse return true;
                return a < b;
            }
        }.lessThan);
        results[index] = .{ .integer = @intCast(aggregate.ordered_values.items.len) };
        program.operations.append(program.allocator, .{ .copy = .{ .source = aggregate.accumulator_register, .destination = aggregate.accumulator_register } }) catch return error.OutOfMemory;
    }
    return results;
}

/// Source `explainSimpleCount()`.
pub fn explainSimpleCount(program: *Program, table: []const u8, index: ?[]const u8, explain: bool) Error!void {
    if (!explain) return;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(program.allocator);
    try appendBytes(&output, program.allocator, "SCAN ");
    try appendBytes(&output, program.allocator, table);
    if (index) |name| {
        try appendBytes(&output, program.allocator, " USING COVERING INDEX ");
        try appendBytes(&output, program.allocator, name);
    }
    const owned = output.toOwnedSlice(program.allocator) catch return error.OutOfMemory;
    errdefer program.allocator.free(owned);
    program.operations.append(program.allocator, .{ .explain = owned }) catch return error.OutOfMemory;
}

pub const WhereLevel = struct { next_address: usize, right_join: bool = false };

/// Source `sqlite3WhereOrderByLimitOptLabel()`.
pub fn orderByLimitLabel(ordered_inner_loop: bool, continue_address: usize, levels: []const WhereLevel) usize {
    if (!ordered_inner_loop or levels.len == 0) return continue_address;
    const inner = levels[levels.len - 1];
    return if (inner.right_join) continue_address else inner.next_address;
}

test "window execution preserves peer ranks and cumulative distribution" {
    const partition = [_]Value{.{ .integer = 1 }};
    const order_a = [_]Value{.{ .integer = 10 }};
    const order_b = [_]Value{.{ .integer = 20 }};
    const rows = [_]WindowRow{
        .{ .values = &order_a, .partition = &partition, .order = &order_a },
        .{ .values = &order_a, .partition = &partition, .order = &order_a },
        .{ .values = &order_b, .partition = &partition, .order = &order_b },
    };
    const ranks = try codeWindowStep(std.testing.allocator, &rows, .{ .function = .rank });
    defer std.testing.allocator.free(ranks);
    try std.testing.expectEqual(@as(i64, 1), ranks[0].integer);
    try std.testing.expectEqual(@as(i64, 1), ranks[1].integer);
    try std.testing.expectEqual(@as(i64, 3), ranks[2].integer);
    const distribution = try codeWindowStep(std.testing.allocator, &rows, .{ .function = .cume_dist });
    defer std.testing.allocator.free(distribution);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), distribution[0].real, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), distribution[2].real, 0.000001);
}

test "name resolution handles qualification aliases and ambiguity" {
    const columns = [_][]const u8{ "id", "value" };
    const sources = [_]Source{.{ .table = "items", .alias = "i", .columns = &columns, .cursor = 4 }};
    var context = NameContext{ .sources = &sources };
    var expression = Expression{ .text = "i.value" };
    try resolveExpressionNames(&context, &expression);
    try std.testing.expectEqual(@as(usize, 1), expression.resolved.?.column);
    try std.testing.expectEqual(@as(usize, 4), expression.resolved.?.cursor);
    try std.testing.expectEqual(@as(usize, 1), context.references);
}

test "where explanation and distinct filtering retain source semantics" {
    const columns = [_][]const u8{ "a", "b" };
    const explanation = try addWhereExplainText(std.testing.allocator, .{
        .table = "t",
        .index = .{ .name = "t_ab", .columns = &columns, .equality_count = 1, .top_terms = 1, .covering = true },
    });
    defer std.testing.allocator.free(explanation);
    try std.testing.expectEqualStrings("SEARCH t USING COVERING INDEX t_ab (a=? AND b<?)", explanation);

    const first = [_]Value{.{ .integer = 1 }};
    const second = [_]Value{.{ .integer = 2 }};
    const rows = [_][]const Value{ &first, &first, &second };
    const keep = try codeDistinct(std.testing.allocator, &rows, .unordered);
    defer std.testing.allocator.free(keep);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, keep);
}

test "select values limits and ORDER BY LIMIT labels build executable plans" {
    var select = CompiledSelect{ .allocator = std.testing.allocator };
    defer select.deinit();
    const first = [_]Value{.{ .integer = 7 }};
    const second = [_]Value{.{ .integer = 8 }};
    const rows = [_][]const Value{ &first, &second };
    try std.testing.expectEqual(@as(usize, 2), try multiSelectValues(&select, &rows, true));

    var program = Program{ .allocator = std.testing.allocator };
    defer program.deinit();
    var estimate: u64 = 100;
    const registers = try computeLimitRegisters(&program, 5, 2, &estimate);
    try std.testing.expect(registers.limit != null and registers.offset != null);
    try std.testing.expectEqual(@as(u64, 5), estimate);
    const levels = [_]WhereLevel{.{ .next_address = 19 }};
    try std.testing.expectEqual(@as(usize, 19), orderByLimitLabel(true, 7, &levels));
}
