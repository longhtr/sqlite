//! Bounded native SELECT/WHERE compiler behavior translated from SQLite.
const std = @import("std");
const execution = @import("query_execution.zig");
const mutex = @import("../mutex.zig");
pub const Value = execution.Value;
pub const Error = error{ Busy, InvalidQuery, NoSolution, OutOfMemory, Range, SchemaChanged, TooBig };

fn eq(a: Value, b: Value) bool {
    return switch (a) {
        .null_ => b == .null_,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .real => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .real => |x| switch (b) {
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            .real => |y| x == y,
            else => false,
        },
        .text => |x| switch (b) {
            .text => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .blob => |x| switch (b) {
            .blob => |y| std.mem.eql(u8, x, y),
            else => false,
        },
    };
}
fn cmp(a: Value, b: Value) std.math.Order {
    if (eq(a, b)) return .eq;
    return switch (a) {
        .null_ => .lt,
        .integer => |x| switch (b) {
            .integer => |y| std.math.order(x, y),
            .real => |y| std.math.order(@as(f64, @floatFromInt(x)), y),
            .null_ => .gt,
            else => .lt,
        },
        .real => |x| switch (b) {
            .integer => |y| std.math.order(x, @as(f64, @floatFromInt(y))),
            .real => |y| std.math.order(x, y),
            .null_ => .gt,
            else => .lt,
        },
        .text => |x| switch (b) {
            .text => |y| std.mem.order(u8, x, y),
            .blob => .lt,
            else => .gt,
        },
        .blob => |x| switch (b) {
            .blob => |y| std.mem.order(u8, x, y),
            else => .gt,
        },
    };
}
fn rowEq(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!eq(x, y)) return false;
    }
    return true;
}

pub const RowSet = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList([]Value) = .empty,
    pub fn deinit(s: *RowSet) void {
        for (s.rows.items) |r| s.allocator.free(r);
        s.rows.deinit(s.allocator);
    }
    pub fn append(s: *RowSet, r: []const Value) Error!void {
        const copy = s.allocator.dupe(Value, r) catch return error.OutOfMemory;
        errdefer s.allocator.free(copy);
        s.rows.append(s.allocator, copy) catch return error.OutOfMemory;
    }
};
pub const TableData = struct { name: []const u8, columns: []const []const u8, rows: []const []const Value };
pub const PredicateOp = enum { eq, ne, lt, le, gt, ge, is_null };
pub const Predicate = struct { column: usize, op: PredicateOp, value: Value = .null_ };
pub const OrderTerm = struct { column: usize, descending: bool = false };
pub const JoinKind = enum { inner, left, right, full };
pub const JoinSpec = struct { kind: JoinKind, left_column: usize, right_column: usize };
pub const CompoundOp = enum { all, union_, except_, intersect };
fn matches(r: []const Value, p: Predicate) bool {
    if (p.column >= r.len) return false;
    const o = cmp(r[p.column], p.value);
    return switch (p.op) {
        .eq => o == .eq,
        .ne => o != .eq,
        .lt => o == .lt,
        .le => o != .gt,
        .gt => o == .gt,
        .ge => o != .lt,
        .is_null => r[p.column] == .null_,
    };
}
pub const SelectModel = struct { columns: []const []const u8, rows: []const []const Value, projection: []const usize, predicates: []const Predicate = &.{}, order_by: []const OrderTerm = &.{}, distinct: bool = false, limit: ?usize = null, offset: usize = 0, expanded: bool = false, resolved: bool = false, typed: bool = false };

/// Source `sqlite3ProcessJoin()`.
pub fn processJoin(a: std.mem.Allocator, l: TableData, r: TableData, spec: JoinSpec) Error!RowSet {
    if (spec.left_column >= l.columns.len or spec.right_column >= r.columns.len) return error.Range;
    var out = RowSet{ .allocator = a };
    errdefer out.deinit();
    const width = l.columns.len + r.columns.len;
    const seen = a.alloc(bool, r.rows.len) catch return error.OutOfMemory;
    defer a.free(seen);
    @memset(seen, false);
    for (l.rows) |left| {
        var hit = false;
        for (r.rows, 0..) |right, i| {
            if (!eq(left[spec.left_column], right[spec.right_column])) continue;
            const row = a.alloc(Value, width) catch return error.OutOfMemory;
            defer a.free(row);
            @memcpy(row[0..left.len], left);
            @memcpy(row[left.len..], right);
            try out.append(row);
            hit = true;
            seen[i] = true;
        }
        if (!hit and (spec.kind == .left or spec.kind == .full)) {
            const row = a.alloc(Value, width) catch return error.OutOfMemory;
            defer a.free(row);
            @memcpy(row[0..left.len], left);
            @memset(row[left.len..], .null_);
            try out.append(row);
        }
    }
    if (spec.kind == .right or spec.kind == .full) {
        for (r.rows, seen) |right, hit| {
            if (hit) continue;
            const row = a.alloc(Value, width) catch return error.OutOfMemory;
            defer a.free(row);
            @memset(row[0..l.columns.len], .null_);
            @memcpy(row[l.columns.len..], right);
            try out.append(row);
        }
    }
    return out;
}
fn lessRows(terms: []const OrderTerm, a: []Value, b: []Value) bool {
    for (terms) |term| {
        const order = cmp(a[term.column], b[term.column]);
        if (order != .eq) return if (term.descending) order == .gt else order == .lt;
    }
    return false;
}

/// Source `pushOntoSorter()`.
pub fn pushOntoSorter(out: *RowSet, rows: []const []const Value, terms: []const OrderTerm, limit: ?usize) Error!void {
    for (rows) |row| try out.append(row);
    for (terms) |term| {
        if (out.rows.items.len > 0 and term.column >= out.rows.items[0].len) return error.Range;
    }
    std.sort.block([]Value, out.rows.items, terms, lessRows);
    if (limit) |maximum| {
        while (out.rows.items.len > maximum) out.allocator.free(out.rows.pop().?);
    }
}
/// Source `selectInnerLoop()`.
pub fn selectInnerLoop(a: std.mem.Allocator, m: SelectModel) Error!RowSet {
    var out = RowSet{ .allocator = a };
    errdefer out.deinit();
    var skipped: usize = 0;
    for (m.rows) |row| {
        var hit = true;
        for (m.predicates) |predicate| {
            if (!matches(row, predicate)) {
                hit = false;
                break;
            }
        }
        if (!hit) continue;
        if (skipped < m.offset) {
            skipped += 1;
            continue;
        }
        const projected = a.alloc(Value, m.projection.len) catch return error.OutOfMemory;
        defer a.free(projected);
        for (m.projection, 0..) |column, i| {
            if (column >= row.len) return error.Range;
            projected[i] = row[column];
        }
        if (m.distinct) {
            var duplicate = false;
            for (out.rows.items) |prior| {
                if (rowEq(prior, projected)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
        }
        try out.append(projected);
        if (m.limit) |maximum| {
            if (out.rows.items.len >= maximum) break;
        }
    }
    return out;
}
/// Source `generateSortTail()`.
pub fn generateSortTail(a: std.mem.Allocator, input: *RowSet, terms: []const OrderTerm, offset: usize, limit: ?usize) Error!RowSet {
    var sorted = RowSet{ .allocator = a };
    defer sorted.deinit();
    try pushOntoSorter(&sorted, input.rows.items, terms, null);
    var out = RowSet{ .allocator = a };
    errdefer out.deinit();
    const end = if (limit) |n| @min(sorted.rows.items.len, offset + n) else sorted.rows.items.len;
    if (offset < end) {
        for (sorted.rows.items[offset..end]) |row| try out.append(row);
    }
    return out;
}
/// Source `sqlite3GenerateColumnNames()`.
pub fn generateColumnNames(a: std.mem.Allocator, sources: []const []const u8, projection: []const usize, aliases: []const ?[]const u8, full: bool, table: []const u8) Error![][]u8 {
    if (aliases.len != projection.len) return error.Range;
    const names = a.alloc([]u8, projection.len) catch return error.OutOfMemory;
    var n: usize = 0;
    errdefer {
        for (names[0..n]) |x| a.free(x);
        a.free(names);
    }
    for (projection, aliases, 0..) |c, alias, i| {
        if (c >= sources.len) return error.Range;
        names[i] = if (alias) |x| a.dupe(u8, x) catch return error.OutOfMemory else if (full) std.fmt.allocPrint(a, "{s}.{s}", .{ table, sources[c] }) catch return error.OutOfMemory else a.dupe(u8, sources[c]) catch return error.OutOfMemory;
        n += 1;
    }
    return names;
}
pub const ResultSchema = struct {
    names: [][]u8,
    affinities: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(s: *ResultSchema) void {
        for (s.names) |n| s.allocator.free(n);
        s.allocator.free(s.names);
        s.allocator.free(s.affinities);
    }
};
/// Source `sqlite3ResultSetOfSelect()`.
pub fn resultSetOfSelect(a: std.mem.Allocator, m: SelectModel, affinity: u8) Error!ResultSchema {
    const aliases = a.alloc(?[]const u8, m.projection.len) catch return error.OutOfMemory;
    defer a.free(aliases);
    @memset(aliases, null);
    const names = try generateColumnNames(a, m.columns, m.projection, aliases, false, "");
    errdefer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    const affinities = a.alloc(u8, names.len) catch return error.OutOfMemory;
    @memset(affinities, affinity);
    return .{ .names = names, .affinities = affinities, .allocator = a };
}
pub const RecursiveStep = *const fn (std.mem.Allocator, []const Value, *RowSet) Error!void;
/// Source `generateWithRecursiveQuery()`.
pub fn generateWithRecursiveQuery(a: std.mem.Allocator, seed: []const []const Value, step: RecursiveStep, distinct: bool, limit: ?usize) Error!RowSet {
    var out = RowSet{ .allocator = a };
    errdefer out.deinit();
    var queue = RowSet{ .allocator = a };
    defer queue.deinit();
    for (seed) |row| try queue.append(row);
    var i: usize = 0;
    while (i < queue.rows.items.len) : (i += 1) {
        const current = queue.rows.items[i];
        var duplicate = false;
        if (distinct) {
            for (out.rows.items) |row| {
                if (rowEq(row, current)) {
                    duplicate = true;
                    break;
                }
            }
        }
        if (duplicate) continue;
        try out.append(current);
        if (limit) |n| {
            if (out.rows.items.len >= n) break;
        }
        var generated = RowSet{ .allocator = a };
        defer generated.deinit();
        try step(a, current, &generated);
        for (generated.rows.items) |row| try queue.append(row);
    }
    return out;
}
/// Source `multiSelect()`.
pub fn multiSelect(a: std.mem.Allocator, left: []const []const Value, right: []const []const Value, op: CompoundOp) Error!RowSet {
    var out = RowSet{ .allocator = a };
    errdefer out.deinit();
    if (op == .all or op == .union_ or op == .except_) {
        for (left) |row| try out.append(row);
    }
    if (op == .all) {
        for (right) |row| try out.append(row);
    }
    if (op == .union_) {
        for (right) |row| {
            var found = false;
            for (out.rows.items) |prior| {
                if (rowEq(prior, row)) {
                    found = true;
                    break;
                }
            }
            if (!found) try out.append(row);
        }
    }
    if (op == .except_) {
        var i: usize = 0;
        while (i < out.rows.items.len) {
            var found = false;
            for (right) |row| {
                if (rowEq(out.rows.items[i], row)) {
                    found = true;
                    break;
                }
            }
            if (found) out.allocator.free(out.rows.orderedRemove(i)) else i += 1;
        }
    }
    if (op == .intersect) {
        for (left) |row| {
            var found = false;
            for (right) |other| {
                if (rowEq(row, other)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                var duplicate = false;
                for (out.rows.items) |prior| {
                    if (rowEq(prior, row)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try out.append(row);
            }
        }
    }
    return out;
}
/// Source `generateOutputSubroutine()`.
pub fn generateOutputSubroutine(out: *RowSet, row: []const Value, previous: ?[]const Value, offset: *usize, limit: *?usize) Error!bool {
    if (previous) |prior| {
        if (rowEq(prior, row)) return false;
    }
    if (offset.* > 0) {
        offset.* -= 1;
        return false;
    }
    if (limit.*) |remaining| {
        if (remaining == 0) return false;
        limit.* = remaining - 1;
    }
    try out.append(row);
    return true;
}
/// Source `multiSelectByMerge()`.
pub fn multiSelectByMerge(a: std.mem.Allocator, left: []const []const Value, right: []const []const Value, op: CompoundOp, terms: []const OrderTerm) Error!RowSet {
    var l = RowSet{ .allocator = a };
    defer l.deinit();
    var r = RowSet{ .allocator = a };
    defer r.deinit();
    try pushOntoSorter(&l, left, terms, null);
    try pushOntoSorter(&r, right, terms, null);
    return multiSelect(a, l.rows.items, r.rows.items, op);
}
/// Source `flattenSubquery()`.
pub fn flattenSubquery(a: std.mem.Allocator, parent: *SelectModel, child: SelectModel) Error!bool {
    if (parent.distinct or child.distinct or (parent.limit != null and child.limit != null) or (child.order_by.len > 0 and parent.order_by.len > 0)) return false;
    const projection = a.alloc(usize, parent.projection.len) catch return error.OutOfMemory;
    for (parent.projection, 0..) |c, i| {
        if (c >= child.projection.len) {
            a.free(projection);
            return error.Range;
        }
        projection[i] = child.projection[c];
    }
    parent.rows = child.rows;
    parent.columns = child.columns;
    parent.projection = projection;
    if (parent.limit == null) parent.limit = child.limit;
    return true;
}
/// Source `pushDownWhereTerms()`.
pub fn pushDownWhereTerms(parent: *SelectModel, child: *SelectModel) usize {
    if (child.limit != null) return 0;
    var moved: usize = 0;
    for (parent.predicates) |predicate| {
        if (std.mem.indexOfScalar(usize, child.projection, predicate.column) != null) moved += 1;
    }
    if (moved == parent.predicates.len) child.predicates = parent.predicates;
    return moved;
}
pub const Cte = struct { name: []const u8, model: SelectModel, materialized: bool = false, uses: usize = 0 };

/// Source `resolveFromTermToCte()`.
pub fn resolveFromTermToCte(name: []const u8, ctes: []Cte) ?*Cte {
    for (ctes) |*cte| {
        if (std.ascii.eqlIgnoreCase(name, cte.name)) {
            cte.uses += 1;
            return cte;
        }
    }
    return null;
}
/// Source `selectExpander()`.
pub fn selectExpander(a: std.mem.Allocator, m: *SelectModel, wildcard: bool) Error!void {
    if (m.expanded) return;
    if (wildcard) {
        const projection = a.alloc(usize, m.columns.len) catch return error.OutOfMemory;
        for (projection, 0..) |*column, i| column.* = i;
        m.projection = projection;
    }
    for (m.projection) |column| {
        if (column >= m.columns.len) return error.Range;
    }
    m.expanded = true;
}
/// Source `sqlite3SelectExpand()`.
pub fn selectExpand(a: std.mem.Allocator, m: *SelectModel) Error!void {
    try selectExpander(a, m, m.projection.len == 0);
    if (m.columns.len > 2000) return error.TooBig;
}
/// Source `sqlite3SelectAddTypeInfo()`.
pub fn selectAddTypeInfo(m: *SelectModel) Error!void {
    if (!m.expanded or !m.resolved) return error.InvalidQuery;
    for (m.rows) |row| {
        if (row.len < m.columns.len) return error.InvalidQuery;
    }
    m.typed = true;
}
/// Source `sqlite3SelectPrep()`.
pub fn selectPrep(a: std.mem.Allocator, m: *SelectModel) Error!void {
    if (m.typed) return;
    try selectExpand(a, m);
    for (m.predicates) |predicate| {
        if (predicate.column >= m.columns.len) return error.Range;
    }
    m.resolved = true;
    try selectAddTypeInfo(m);
}
/// Source `updateAccumulator()`.
pub fn updateAccumulator(sum: *f64, count: *usize, values: []const Value, distinct: bool) void {
    for (values, 0..) |value, i| {
        if (distinct) {
            var duplicate = false;
            for (values[0..i]) |prior| {
                if (eq(prior, value)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
        }
        switch (value) {
            .integer => |n| {
                sum.* += @floatFromInt(n);
                count.* += 1;
            },
            .real => |n| {
                sum.* += n;
                count.* += 1;
            },
            else => {},
        }
    }
}
/// Source `countOfViewOptimization()`.
pub fn countOfViewOptimization(arms: []const []const []const Value, union_all: bool) ?usize {
    if (!union_all or arms.len < 2) return null;
    var n: usize = 0;
    for (arms) |rows| n += rows.len;
    return n;
}
/// Source `sqlite3Select()`.
pub fn select(a: std.mem.Allocator, initial: SelectModel) Error!RowSet {
    var m = initial;
    try selectPrep(a, &m);
    var out = try selectInnerLoop(a, m);
    if (m.order_by.len > 0) {
        const sorted = try generateSortTail(a, &out, m.order_by, 0, null);
        out.deinit();
        out = sorted;
    }
    return out;
}

pub const PlannerTerm = struct { column: usize, op: PredicateOp, value: Value = .null_, prerequisite: u64 = 0, usable: bool = true };
pub const PlannerIndex = struct { name: []const u8, columns: []const usize, unique: bool = false, covering: bool = false, ordered: bool = true, row_estimate: u64 = 1000 };
pub const PlannerLoop = struct { table: usize, mask: u64, prerequisites: u64 = 0, index: ?*const PlannerIndex = null, setup_cost: i32 = 0, run_cost: i32 = 100, output_rows: i32 = 100, equality_count: usize = 0, reverse: bool = false, virtual: bool = false, automatic: bool = false, bloom: bool = false };
pub const PlannerInfo = struct {
    allocator: std.mem.Allocator,
    loops: std.ArrayList(PlannerLoop) = .empty,
    chosen: std.ArrayList(PlannerLoop) = .empty,
    ordered_terms: usize = 0,
    one_pass: u8 = 0,
    continue_label: usize = 0,
    break_label: usize = 0,
    pub fn deinit(s: *PlannerInfo) void {
        s.loops.deinit(s.allocator);
        s.chosen.deinit(s.allocator);
    }
};
/// Source `sqlite3WhereMinMaxOptEarlyOut()`.
pub fn minMaxEarlyOut(info: PlannerInfo, contains_in: bool) usize {
    if (info.ordered_terms == 0) return info.break_label;
    return if (contains_in) info.continue_label else info.break_label;
}
/// Source `sqlite3WhereOkOnePass()`.
pub fn whereOnePass(info: PlannerInfo, cursors: *[2]isize) u8 {
    cursors.* = .{ if (info.chosen.items.len > 0) @intCast(info.chosen.items[0].table) else -1, if (info.chosen.items.len > 0 and info.chosen.items[0].index != null) 1 else -1 };
    return info.one_pass;
}
pub const RuntimeOp = union(enum) { column: struct { cursor: usize, column: usize, output: usize }, rowid: struct { cursor: usize, output: usize }, copy: struct { source: usize, output: usize }, sequence: struct { cursor: usize, output: usize }, filter: usize };
/// Source `translateColumnToCopy()`.
pub fn translateColumnCopies(ops: []RuntimeOp, cursor: usize, first: usize, automatic: ?usize) void {
    for (ops) |*op| switch (op.*) {
        .column => |column| {
            if (column.cursor == cursor) op.* = .{ .copy = .{ .source = first + column.column, .output = column.output } };
        },
        .rowid => |rowid| {
            if (rowid.cursor == cursor) op.* = .{ .sequence = .{ .cursor = automatic orelse 0, .output = rowid.output } };
        },
        else => {},
    };
}
pub const AutoIndex = struct {
    allocator: std.mem.Allocator,
    columns: []usize,
    rows: RowSet,
    pub fn deinit(self: *AutoIndex) void {
        self.allocator.free(self.columns);
        self.rows.deinit();
    }
};

/// Source `constructAutomaticIndex()`.
pub fn constructAutomaticIndex(a: std.mem.Allocator, table: TableData, terms: []const PlannerTerm, used: []const usize) Error!AutoIndex {
    var columns = std.ArrayList(usize).empty;
    defer columns.deinit(a);
    for (terms) |term| {
        if (term.usable and term.op == .eq and std.mem.indexOfScalar(usize, columns.items, term.column) == null) columns.append(a, term.column) catch return error.OutOfMemory;
    }
    for (used) |column| {
        if (std.mem.indexOfScalar(usize, columns.items, column) == null) columns.append(a, column) catch return error.OutOfMemory;
    }
    if (columns.items.len == 0) return error.InvalidQuery;
    const owned = a.dupe(usize, columns.items) catch return error.OutOfMemory;
    errdefer a.free(owned);
    var rows = RowSet{ .allocator = a };
    errdefer rows.deinit();
    for (table.rows) |row| try rows.append(row);
    return .{ .allocator = a, .columns = owned, .rows = rows };
}
pub const Bloom = struct {
    bits: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Bloom) void {
        self.allocator.free(self.bits);
    }
    pub fn contains(self: Bloom, value: Value) bool {
        const bit = hashValue(value) % @as(u64, @intCast(self.bits.len * 8));
        return (self.bits[@intCast(bit / 8)] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
    }
};

fn hashValue(value: Value) u64 {
    var hash = std.hash.Wyhash.init(0);
    switch (value) {
        .null_ => hash.update(&.{0}),
        .integer => |number| hash.update(std.mem.asBytes(&number)),
        .real => |number| hash.update(std.mem.asBytes(&number)),
        .text => |text| hash.update(text),
        .blob => |blob| hash.update(blob),
    }
    return hash.final();
}

/// Source `sqlite3ConstructBloomFilter()`.
pub fn constructBloomFilter(a: std.mem.Allocator, rows: []const []const Value, column: usize) Error!Bloom {
    const bytes = @min(@max(rows.len * 2, 1250), 1250000);
    const bits = a.alloc(u8, bytes) catch return error.OutOfMemory;
    @memset(bits, 0);
    for (rows) |r| {
        if (column >= r.len) {
            a.free(bits);
            return error.Range;
        }
        const bit = hashValue(r[column]) % @as(u64, @intCast(bits.len * 8));
        bits[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
    }
    return .{ .bits = bits, .allocator = a };
}
pub const IndexInfo = struct {
    allocator: std.mem.Allocator,
    constraints: []PlannerTerm,
    order: []OrderTerm,
    estimated_rows: u64 = 25,
    estimated_cost: f64 = 1.0e99,
    consumed_order: bool = false,
    pub fn deinit(s: *IndexInfo) void {
        s.allocator.free(s.constraints);
        s.allocator.free(s.order);
    }
};
/// Source `allocateIndexInfo()`.
pub fn allocateIndexInfo(a: std.mem.Allocator, terms: []const PlannerTerm, order: []const OrderTerm, unusable: u64) Error!IndexInfo {
    var usable = std.ArrayList(PlannerTerm).empty;
    defer usable.deinit(a);
    for (terms) |term| {
        if (term.prerequisite & unusable == 0) usable.append(a, term) catch return error.OutOfMemory;
    }
    const constraints = a.dupe(PlannerTerm, usable.items) catch return error.OutOfMemory;
    errdefer a.free(constraints);
    const order_copy = a.dupe(OrderTerm, order) catch return error.OutOfMemory;
    return .{ .allocator = a, .constraints = constraints, .order = order_copy };
}
/// Source `freeIndexInfo()`.
pub fn freeIndexInfo(info: *IndexInfo) void {
    info.deinit();
    info.* = undefined;
}
pub const BestIndexCallback = *const fn (*IndexInfo) Error!void;
/// Source `vtabBestIndex()`.
pub fn virtualBestIndex(info: *IndexInfo, callback: BestIndexCallback) Error!void {
    try callback(info);
    if (!std.math.isFinite(info.estimated_cost) or info.estimated_rows == 0) return error.InvalidQuery;
    for (info.constraints) |term| {
        if (!term.usable) return error.InvalidQuery;
    }
}
/// Source `whereRangeScanEst()`.
pub fn estimateRangeScan(total: u64, lower: ?Value, upper: ?Value, likelihood: ?f64) u64 {
    var estimate = total;
    if (lower != null) estimate = @max(estimate / 4, 1);
    if (upper != null) estimate = @max(estimate / 4, 1);
    if (lower != null and upper != null) estimate = @max(estimate / 4, 1);
    if (likelihood) |p| estimate = @max(@as(u64, @intFromFloat(@as(f64, @floatFromInt(total)) * @max(0, @min(1, p)))), 1);
    return estimate;
}
/// Source `whereInfoFree()`.
pub fn whereInfoFree(info: *PlannerInfo) void {
    info.deinit();
    info.* = undefined;
}
/// Source `whereLoopInsert()`.
pub fn insertWhereLoop(info: *PlannerInfo, candidate: PlannerLoop) Error!bool {
    for (info.loops.items, 0..) |prior, i| {
        if (prior.table == candidate.table and prior.prerequisites == candidate.prerequisites and prior.index == candidate.index) {
            if (prior.setup_cost + prior.run_cost <= candidate.setup_cost + candidate.run_cost) return false;
            info.loops.items[i] = candidate;
            return true;
        }
    }
    info.loops.append(info.allocator, candidate) catch return error.OutOfMemory;
    return true;
}
fn logEstimate(value: u64) i32 {
    return if (value <= 1) 0 else @intCast(64 - @clz(value));
}

/// Source `whereLoopAddBtreeIndex()`.
pub fn addBtreeIndexLoop(info: *PlannerInfo, table: usize, index: *const PlannerIndex, terms: []const PlannerTerm, mask: u64) Error!void {
    var equalities: usize = 0;
    for (index.columns) |column| {
        var found = false;
        for (terms) |term| {
            if (term.column == column and term.usable and term.op == .eq) {
                found = true;
                break;
            }
        }
        if (!found) break;
        equalities += 1;
    }
    const output = @max(index.row_estimate >> @intCast(@min(equalities, @as(usize, 63))), 1);
    _ = try insertWhereLoop(info, .{ .table = table, .mask = mask, .index = index, .run_cost = logEstimate(output) + logEstimate(index.row_estimate), .output_rows = logEstimate(output), .equality_count = equalities });
}
/// Source `whereLoopAddBtree()`.
pub fn addBtreeLoops(info: *PlannerInfo, table: usize, indexes: []const PlannerIndex, terms: []const PlannerTerm, mask: u64, row_count: u64) Error!void {
    _ = try insertWhereLoop(info, .{ .table = table, .mask = mask, .run_cost = logEstimate(row_count) + 16, .output_rows = logEstimate(row_count) });
    for (indexes) |*index| try addBtreeIndexLoop(info, table, index, terms, mask);
    if (indexes.len == 0 and terms.len > 0) _ = try insertWhereLoop(info, .{ .table = table, .mask = mask, .setup_cost = logEstimate(row_count) * 2, .run_cost = logEstimate(row_count / 10 + 1), .output_rows = logEstimate(row_count / 10 + 1), .automatic = true });
}
/// Source `whereLoopAddVirtualOne()`.
pub fn addOneVirtualLoop(info: *PlannerInfo, table: usize, mask: u64, prerequisite: u64, index_info: *IndexInfo, callback: BestIndexCallback) Error!void {
    try virtualBestIndex(index_info, callback);
    _ = try insertWhereLoop(info, .{ .table = table, .mask = mask, .prerequisites = prerequisite, .run_cost = @intFromFloat(@log2(@max(index_info.estimated_cost, 1))), .output_rows = logEstimate(index_info.estimated_rows), .virtual = true });
}
/// Source `sqlite3VtabUsesAllSchemas()`.
pub fn virtualTableUsesAllSchemas(schema_count: usize, write_mask: u64, verify: []bool, write: []bool) Error!void {
    if (verify.len < schema_count or write.len < schema_count) return error.Range;
    for (0..schema_count) |i| {
        verify[i] = true;
        if (write_mask != 0) write[i] = true;
    }
}
/// Source `whereLoopAddVirtual()`.
pub fn addVirtualLoops(info: *PlannerInfo, table: usize, mask: u64, terms: []const PlannerTerm, order: []const OrderTerm, callback: BestIndexCallback) Error!void {
    var index_info = try allocateIndexInfo(info.allocator, terms, order, 0);
    defer index_info.deinit();
    try addOneVirtualLoop(info, table, mask, 0, &index_info, callback);
    var prerequisites: u64 = 0;
    for (terms) |t| prerequisites |= t.prerequisite;
    if (prerequisites != 0) try addOneVirtualLoop(info, table, mask, prerequisites, &index_info, callback);
}
/// Source `whereLoopAddOr()`.
pub fn addOrLoops(info: *PlannerInfo, table: usize, mask: u64, branches: []const []const PlannerLoop) Error!void {
    if (branches.len == 0) return;
    var cost: i32 = 0;
    var output: i32 = 0;
    var prerequisites: u64 = 0;
    for (branches) |branch| {
        if (branch.len == 0) return;
        var best = branch[0];
        for (branch[1..]) |loop| {
            if (loop.run_cost < best.run_cost) best = loop;
        }
        cost += best.run_cost;
        output += best.output_rows;
        prerequisites |= best.prerequisites;
    }
    _ = try insertWhereLoop(info, .{ .table = table, .mask = mask, .prerequisites = prerequisites, .run_cost = cost + 1, .output_rows = output });
}
/// Source `whereLoopAddAll()`.
pub fn addAllLoops(info: *PlannerInfo, tables: []const TableData, indexes: []const []const PlannerIndex, terms: []const []const PlannerTerm) Error!void {
    if (indexes.len != tables.len or terms.len != tables.len) return error.Range;
    var prior: u64 = 0;
    for (tables, indexes, terms, 0..) |table, table_indexes, table_terms, i| {
        const mask = @as(u64, 1) << @intCast(i);
        try addBtreeLoops(info, i, table_indexes, table_terms, mask, table.rows.len);
        for (info.loops.items) |*loop| {
            if (loop.table == i) loop.prerequisites |= prior;
        }
        prior |= mask;
    }
}
/// Source `wherePathSatisfiesOrderBy()`.
pub fn pathSatisfiesOrder(path: []const PlannerLoop, order: []const OrderTerm, reverse_mask: *u64) usize {
    var satisfied: usize = 0;
    reverse_mask.* = 0;
    for (path, 0..) |loop, i| {
        const index = loop.index orelse break;
        if (!index.ordered) break;
        for (index.columns) |column| {
            if (satisfied >= order.len or order[satisfied].column != column) break;
            satisfied += 1;
            if (order[satisfied - 1].descending) reverse_mask.* |= @as(u64, 1) << @intCast(i);
        }
    }
    return satisfied;
}
/// Source `computeMxChoice()`.
pub fn computePlannerChoice(table_count: usize, loops: []PlannerLoop) usize {
    if (table_count <= 1) return 1;
    if (table_count == 2) return 5;
    var dimensions: usize = 0;
    for (loops) |loop| {
        if (loop.prerequisites != 0 and loop.output_rows < 20) dimensions += 1;
    }
    return if (dimensions >= 3) 18 else 12;
}
const SolverState = struct { mask: u64, cost: i64, rows: i32, loops: std.ArrayList(PlannerLoop) = .empty };
fn lessSolverState(_: void, a: SolverState, b: SolverState) bool {
    return a.cost < b.cost;
}
/// Source `wherePathSolver()`.
pub fn solveWherePaths(info: *PlannerInfo, table_count: usize, order: []const OrderTerm) Error!void {
    info.chosen.clearRetainingCapacity();
    if (table_count == 0) return;
    const max_choice = computePlannerChoice(table_count, info.loops.items);
    var paths = std.ArrayList(SolverState).empty;
    defer {
        for (paths.items) |*path| path.loops.deinit(info.allocator);
        paths.deinit(info.allocator);
    }
    paths.append(info.allocator, .{ .mask = 0, .cost = 0, .rows = 0 }) catch return error.OutOfMemory;
    for (0..table_count) |_| {
        var next = std.ArrayList(SolverState).empty;
        errdefer {
            for (next.items) |*path| path.loops.deinit(info.allocator);
            next.deinit(info.allocator);
        }
        for (paths.items) |path| {
            for (info.loops.items) |loop| {
                if (path.mask & loop.mask != 0 or loop.prerequisites & ~path.mask != 0) continue;
                var candidate = SolverState{ .mask = path.mask | loop.mask, .cost = path.cost + loop.setup_cost + loop.run_cost + path.rows, .rows = path.rows + loop.output_rows };
                candidate.loops.appendSlice(info.allocator, path.loops.items) catch return error.OutOfMemory;
                candidate.loops.append(info.allocator, loop) catch {
                    candidate.loops.deinit(info.allocator);
                    return error.OutOfMemory;
                };
                var consumed = false;
                for (next.items) |*prior| {
                    if (prior.mask != candidate.mask) continue;
                    if (prior.cost <= candidate.cost) candidate.loops.deinit(info.allocator) else {
                        prior.loops.deinit(info.allocator);
                        prior.* = candidate;
                    }
                    consumed = true;
                    break;
                }
                if (!consumed) next.append(info.allocator, candidate) catch {
                    candidate.loops.deinit(info.allocator);
                    return error.OutOfMemory;
                };
            }
        }
        for (paths.items) |*path| path.loops.deinit(info.allocator);
        paths.deinit(info.allocator);
        paths = next;
        if (paths.items.len > max_choice) {
            std.sort.heap(SolverState, paths.items, {}, lessSolverState);
            while (paths.items.len > max_choice) {
                var removed = paths.pop().?;
                removed.loops.deinit(info.allocator);
            }
        }
    }
    if (paths.items.len == 0) return error.NoSolution;
    var best = &paths.items[0];
    for (paths.items[1..]) |*path| {
        if (path.cost < best.cost) best = path;
    }
    info.chosen.appendSlice(info.allocator, best.loops.items) catch return error.OutOfMemory;
    var reverse: u64 = 0;
    info.ordered_terms = pathSatisfiesOrder(info.chosen.items, order, &reverse);
    info.one_pass = if (table_count == 1 and info.chosen.items[0].output_rows == 0) 1 else 0;
}
/// Source `sqlite3WhereBegin()`.
pub fn beginWhere(a: std.mem.Allocator, tables: []const TableData, indexes: []const []const PlannerIndex, terms: []const []const PlannerTerm, order: []const OrderTerm) Error!PlannerInfo {
    if (tables.len > 63) return error.TooBig;
    var info = PlannerInfo{ .allocator = a, .continue_label = 1, .break_label = 2 };
    errdefer info.deinit();
    try addAllLoops(&info, tables, indexes, terms);
    try solveWherePaths(&info, tables.len, order);
    for (info.chosen.items) |*loop| {
        if (loop.output_rows > 20 and loop.index != null) loop.bloom = true;
    }
    return info;
}
/// Source `sqlite3WhereEnd()`.
pub fn endWhere(info: *PlannerInfo, operations: []RuntimeOp) void {
    for (info.chosen.items) |loop| {
        if (loop.index) |index| {
            if (index.covering) translateColumnCopies(operations, loop.table, loop.table * 64, null);
        }
    }
    info.deinit();
    info.* = undefined;
}
/// Source `sqlite3WhereCodeOneLoopStart()`.
pub fn codeWhereLoopStart(a: std.mem.Allocator, table: TableData, terms: []const PlannerTerm, loop: PlannerLoop, bloom: ?Bloom) Error!RowSet {
    var out = RowSet{ .allocator = a };
    errdefer out.deinit();
    for (table.rows) |row| {
        var hit = true;
        for (terms) |term| {
            if (term.prerequisite & ~loop.prerequisites != 0) continue;
            if (term.column >= row.len) return error.Range;
            if (!matches(row, .{ .column = term.column, .op = term.op, .value = term.value })) {
                hit = false;
                break;
            }
        }
        if (!hit) continue;
        if (bloom) |filter| {
            if (row.len == 0 or !filter.contains(row[0])) continue;
        }
        try out.append(row);
    }
    return out;
}

pub const PreparedText = struct { sql: []const u8, tail: usize, schema_generation: u64, persistent: bool };
pub const PrepareState = struct { guard: mutex.Mutex = .{}, schema_generation: u64 = 0, max_sql: usize = 1_000_000, retry_generation: ?u64 = null };
/// Source `sqlite3Prepare()`.
pub fn prepareSql(state: *PrepareState, sql: []const u8, persistent: bool) Error!PreparedText {
    if (sql.len > state.max_sql) return error.TooBig;
    var depth: usize = 0;
    var quote: u8 = 0;
    var tail = sql.len;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        const byte = sql[i];
        if (quote != 0) {
            if (byte == quote) {
                if (i + 1 < sql.len and sql[i + 1] == quote) {
                    i += 1;
                } else {
                    quote = 0;
                }
            }
            continue;
        }
        if (byte == '\'' or byte == '"' or byte == '`') {
            quote = byte;
            continue;
        }
        if (byte == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            i += 2;
            while (i < sql.len and sql[i] != '\n') : (i += 1) {}
            continue;
        }
        if (byte == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) : (i += 1) {}
            if (i + 1 >= sql.len) return error.InvalidQuery;
            i += 1;
            continue;
        }
        if (byte == '(') depth += 1 else if (byte == ')') {
            if (depth == 0) return error.InvalidQuery;
            depth -= 1;
        } else if (byte == ';') {
            tail = i + 1;
            break;
        }
    }
    if (depth != 0 or quote != 0) return error.InvalidQuery;
    const statement = std.mem.trim(u8, sql[0..tail], " \t\r\n;");
    if (statement.len == 0) return error.InvalidQuery;
    return .{ .sql = sql[0..tail], .tail = tail, .schema_generation = state.schema_generation, .persistent = persistent };
}
/// Source `sqlite3LockAndPrepare()`.
pub fn lockAndPrepare(state: *PrepareState, sql: []const u8, persistent: bool) Error!PreparedText {
    state.guard.enter();
    defer state.guard.leave();
    var attempts: u8 = 0;
    while (true) {
        const prepared = prepareSql(state, sql, persistent) catch |err| {
            if (err == error.SchemaChanged and attempts == 0) {
                attempts += 1;
                continue;
            }
            return err;
        };
        if (state.retry_generation) |generation| {
            state.retry_generation = null;
            if (generation != state.schema_generation and attempts == 0) {
                state.schema_generation = generation;
                attempts += 1;
                continue;
            }
        }
        return prepared;
    }
}
/// Source `sqlite3Reprepare()`.
pub fn reprepare(state: *PrepareState, old: PreparedText) Error!PreparedText {
    const fresh = try lockAndPrepare(state, old.sql, old.persistent);
    if (fresh.schema_generation < old.schema_generation) return error.SchemaChanged;
    return fresh;
}

pub const LockMode = enum { read, write };
pub const TableLock = struct { database: usize, root_page: u32, mode: LockMode, name: []const u8 };
pub const TransactionKind = enum { deferred, immediate, exclusive };
pub const TransactionOp = union(enum) { table_lock: TableLock, transaction: struct { database: usize, mode: u8 }, auto_commit: struct { enabled: bool, rollback: bool } };
pub const CompileProgram = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(TransactionOp) = .empty,
    pub fn deinit(s: *CompileProgram) void {
        s.operations.deinit(s.allocator);
    }
};
/// Source `codeTableLocks()`.
pub fn codeTableLocks(program: *CompileProgram, locks: []const TableLock) Error!void {
    for (locks) |lock| program.operations.append(program.allocator, .{ .table_lock = lock }) catch return error.OutOfMemory;
}
/// Source `sqlite3BeginTransaction()`.
pub fn beginTransaction(program: *CompileProgram, kind: TransactionKind, read_only: []const bool) Error!void {
    if (kind != .deferred) {
        for (read_only, 0..) |readonly, database| {
            program.operations.append(program.allocator, .{ .transaction = .{ .database = database, .mode = if (readonly) 0 else if (kind == .exclusive) 2 else 1 } }) catch return error.OutOfMemory;
        }
    }
    program.operations.append(program.allocator, .{ .auto_commit = .{ .enabled = false, .rollback = false } }) catch return error.OutOfMemory;
}
/// Source `sqlite3EndTransaction()`.
pub fn endTransaction(program: *CompileProgram, rollback: bool) Error!void {
    program.operations.append(program.allocator, .{ .auto_commit = .{ .enabled = true, .rollback = rollback } }) catch return error.OutOfMemory;
}

fn testRecursiveStep(_: std.mem.Allocator, row: []const Value, output: *RowSet) Error!void {
    const number = switch (row[0]) {
        .integer => |value| value,
        else => return error.InvalidQuery,
    };
    if (number < 3) try output.append(&.{.{ .integer = number + 1 }});
}

fn testBestIndex(info: *IndexInfo) Error!void {
    info.estimated_cost = 2;
    info.estimated_rows = 1;
    info.consumed_order = true;
}

test "select preparation and where planning execute bounded production paths" {
    const allocator = std.testing.allocator;
    const left_rows = [_][]const Value{ &.{ .{ .integer = 2 }, .{ .text = "b" } }, &.{ .{ .integer = 1 }, .{ .text = "a" } } };
    const right_rows = [_][]const Value{&.{ .{ .integer = 2 }, .{ .integer = 9 } }};
    const columns = [_][]const u8{ "id", "name" };
    var joined = try processJoin(allocator, .{ .name = "l", .columns = &columns, .rows = &left_rows }, .{ .name = "r", .columns = &columns, .rows = &right_rows }, .{ .kind = .left, .left_column = 0, .right_column = 0 });
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 2), joined.rows.items.len);

    var selected = try select(allocator, .{ .columns = &columns, .rows = &left_rows, .projection = &.{0}, .order_by = &.{.{ .column = 0 }} });
    defer selected.deinit();
    try std.testing.expectEqual(@as(i64, 1), selected.rows.items[0][0].integer);

    var recursive = try generateWithRecursiveQuery(allocator, &.{&.{.{ .integer = 1 }}}, testRecursiveStep, true, null);
    defer recursive.deinit();
    try std.testing.expectEqual(@as(usize, 3), recursive.rows.items.len);

    const table = TableData{ .name = "l", .columns = &columns, .rows = &left_rows };
    const planner_index = PlannerIndex{ .name = "l_id", .columns = &.{0}, .unique = true, .covering = true, .row_estimate = 2 };
    const planner_terms = [_]PlannerTerm{.{ .column = 0, .op = .eq, .value = .{ .integer = 1 } }};
    var info = try beginWhere(allocator, &.{table}, &.{&.{planner_index}}, &.{&planner_terms}, &.{.{ .column = 0 }});
    var operations = [_]RuntimeOp{.{ .column = .{ .cursor = 0, .column = 0, .output = 1 } }};
    endWhere(&info, &operations);
    try std.testing.expect(operations[0] == .copy);

    var virtual_info = try allocateIndexInfo(allocator, &planner_terms, &.{}, 0);
    defer virtual_info.deinit();
    try virtualBestIndex(&virtual_info, testBestIndex);

    var prepare_state = PrepareState{};
    const prepared = try lockAndPrepare(&prepare_state, "SELECT ';' /* ; */; SELECT 2", false);
    try std.testing.expectEqual(@as(usize, 19), prepared.tail);
    _ = try reprepare(&prepare_state, prepared);

    var program = CompileProgram{ .allocator = allocator };
    defer program.deinit();
    try codeTableLocks(&program, &.{.{ .database = 0, .root_page = 2, .mode = .read, .name = "l" }});
    try beginTransaction(&program, .immediate, &.{false});
    try endTransaction(&program, false);
    try std.testing.expectEqual(@as(usize, 4), program.operations.items.len);
}
