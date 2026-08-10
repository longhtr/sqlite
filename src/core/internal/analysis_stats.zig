//! sqlite_stat1 accumulation, ANALYZE routing, and planner-stat loading from `analyze.c`.

const std = @import("std");
const log_est = @import("../log_est.zig");

pub const Error = error{ OutOfMemory, InvalidArgument, NotFound };

pub const StatRow = struct {
    table_name: []u8,
    index_name: ?[]u8,
    stat: []u8,
};

pub const StatTable = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(StatRow) = .empty,

    pub fn init(allocator: std.mem.Allocator) StatTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StatTable) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.table_name);
            if (row.index_name) |name| self.allocator.free(name);
            self.allocator.free(row.stat);
        }
        self.rows.deinit(self.allocator);
    }
};

pub const StatAccumulator = struct {
    allocator: std.mem.Allocator,
    estimated_rows: u64,
    rows: u64 = 0,
    scan_limit: usize,
    column_count: usize,
    key_column_count: usize,
    skip_ahead: u8 = 0,
    distinct_less_than: []u64,
    equal: []u64,
};

pub const IndexInput = struct {
    name: []const u8,
    row_count: u64,
    distinct_prefixes: []const u64,
    unordered: bool = false,
    no_skip_scan: bool = false,
    row_size: usize = 0,
};

pub const TableInput = struct {
    name: []const u8,
    row_count: u64,
    indexes: []const IndexInput = &.{},
    ordinary: bool = true,
};

pub const DecodeFlags = struct {
    unordered: bool = false,
    no_skip_scan: bool = false,
    row_size: usize = 0,
};

pub const LoadedIndex = struct {
    allocator: std.mem.Allocator,
    table_name: []u8,
    index_name: ?[]u8,
    row_estimates: []u64,
    log_estimates: []i16,
    flags: DecodeFlags,
    samples: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *LoadedIndex) void {
        self.allocator.free(self.table_name);
        if (self.index_name) |name| self.allocator.free(name);
        self.allocator.free(self.row_estimates);
        self.allocator.free(self.log_estimates);
        deleteIndexSamples(self);
        self.samples.deinit(self.allocator);
    }
};

pub const LoadedAnalysis = struct {
    allocator: std.mem.Allocator,
    indexes: std.ArrayList(LoadedIndex) = .empty,

    pub fn init(allocator: std.mem.Allocator) LoadedAnalysis {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LoadedAnalysis) void {
        for (self.indexes.items) |*index| index.deinit();
        self.indexes.deinit(self.allocator);
    }
};

fn appendRow(table: *StatTable, table_name: []const u8, index_name: ?[]const u8, stat: []const u8) Error!void {
    const owned_table = table.allocator.dupe(u8, table_name) catch return error.OutOfMemory;
    errdefer table.allocator.free(owned_table);
    const owned_index = if (index_name) |name| table.allocator.dupe(u8, name) catch return error.OutOfMemory else null;
    errdefer if (owned_index) |name| table.allocator.free(name);
    const owned_stat = table.allocator.dupe(u8, stat) catch return error.OutOfMemory;
    errdefer table.allocator.free(owned_stat);
    table.rows.append(table.allocator, .{ .table_name = owned_table, .index_name = owned_index, .stat = owned_stat }) catch return error.OutOfMemory;
}

/// Source `openStatTable()`.
pub fn openStatisticsTable(table: *StatTable, where_name: ?[]const u8, match_index: bool) void {
    var output: usize = 0;
    for (table.rows.items) |row| {
        const remove = if (where_name) |name|
            if (match_index)
                row.index_name != null and std.ascii.eqlIgnoreCase(row.index_name.?, name)
            else
                std.ascii.eqlIgnoreCase(row.table_name, name)
        else
            true;
        if (remove) {
            table.allocator.free(row.table_name);
            if (row.index_name) |index_name| table.allocator.free(index_name);
            table.allocator.free(row.stat);
        } else {
            table.rows.items[output] = row;
            output += 1;
        }
    }
    table.rows.items.len = output;
}

/// Source `statAccumDestructor()`.
pub fn destroyAccumulator(accumulator: *StatAccumulator) void {
    const allocator = accumulator.allocator;
    allocator.free(accumulator.distinct_less_than);
    allocator.free(accumulator.equal);
    allocator.destroy(accumulator);
}

/// Source `statInit()`.
pub fn initializeStatistics(allocator: std.mem.Allocator, column_count: usize, key_column_count: usize, estimated_rows: u64, scan_limit: usize) Error!*StatAccumulator {
    if (column_count == 0 or key_column_count == 0 or key_column_count > column_count) return error.InvalidArgument;
    const accumulator = allocator.create(StatAccumulator) catch return error.OutOfMemory;
    errdefer allocator.destroy(accumulator);
    const distinct = allocator.alloc(u64, column_count) catch return error.OutOfMemory;
    errdefer allocator.free(distinct);
    const equal = allocator.alloc(u64, column_count) catch return error.OutOfMemory;
    @memset(distinct, 0);
    @memset(equal, 0);
    accumulator.* = .{
        .allocator = allocator,
        .estimated_rows = estimated_rows,
        .scan_limit = scan_limit,
        .column_count = column_count,
        .key_column_count = key_column_count,
        .distinct_less_than = distinct,
        .equal = equal,
    };
    return accumulator;
}

/// Source `statPush()`.
pub fn pushStatistics(accumulator: *StatAccumulator, changed_column: usize) Error!?bool {
    if (changed_column >= accumulator.column_count) return error.InvalidArgument;
    if (accumulator.rows == 0) {
        @memset(accumulator.equal, 1);
    } else {
        for (0..changed_column) |index| accumulator.equal[index] += 1;
        for (changed_column..accumulator.column_count) |index| {
            accumulator.distinct_less_than[index] += 1;
            accumulator.equal[index] = 1;
        }
    }
    accumulator.rows += 1;
    if (accumulator.scan_limit != 0 and accumulator.rows > accumulator.scan_limit * (@as(u64, accumulator.skip_ahead) + 1)) {
        accumulator.skip_ahead +|= 1;
        return accumulator.distinct_less_than[0] > 0;
    }
    return null;
}

/// Source `statGet()`.
pub fn getStatistics(accumulator: *const StatAccumulator) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(accumulator.allocator);
    const total = if (accumulator.skip_ahead != 0) accumulator.estimated_rows else accumulator.rows;
    var buffer: [32]u8 = undefined;
    const first = std.fmt.bufPrint(&buffer, "{d}", .{total}) catch return error.OutOfMemory;
    output.appendSlice(accumulator.allocator, first) catch return error.OutOfMemory;
    for (0..accumulator.key_column_count) |index| {
        const distinct = accumulator.distinct_less_than[index] + 1;
        var estimate = if (distinct == 0) 0 else (accumulator.rows + distinct - 1) / distinct;
        if (estimate == 2 and accumulator.rows * 10 <= distinct * 11) estimate = 1;
        const rendered = std.fmt.bufPrint(&buffer, " {d}", .{estimate}) catch return error.OutOfMemory;
        output.appendSlice(accumulator.allocator, rendered) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice(accumulator.allocator) catch error.OutOfMemory;
}

fn statText(allocator: std.mem.Allocator, index: IndexInput) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var buffer: [48]u8 = undefined;
    var rendered = std.fmt.bufPrint(&buffer, "{d}", .{index.row_count}) catch return error.OutOfMemory;
    output.appendSlice(allocator, rendered) catch return error.OutOfMemory;
    for (index.distinct_prefixes) |distinct| {
        const estimate = if (distinct == 0) index.row_count else (index.row_count + distinct - 1) / distinct;
        rendered = std.fmt.bufPrint(&buffer, " {d}", .{estimate}) catch return error.OutOfMemory;
        output.appendSlice(allocator, rendered) catch return error.OutOfMemory;
    }
    if (index.unordered) output.appendSlice(allocator, " unordered") catch return error.OutOfMemory;
    if (index.no_skip_scan) output.appendSlice(allocator, " noskipscan") catch return error.OutOfMemory;
    if (index.row_size > 0) {
        rendered = std.fmt.bufPrint(&buffer, " sz={d}", .{@max(index.row_size, 2)}) catch return error.OutOfMemory;
        output.appendSlice(allocator, rendered) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Source `analyzeOneTable()`.
pub fn analyzeOneTable(output: *StatTable, table: TableInput, only_index: ?[]const u8) Error!void {
    if (!table.ordinary or std.mem.startsWith(u8, table.name, "sqlite_")) return;
    var analyzed_index = false;
    for (table.indexes) |index| {
        if (only_index) |name| if (!std.ascii.eqlIgnoreCase(index.name, name)) continue;
        const stat = try statText(output.allocator, index);
        defer output.allocator.free(stat);
        try appendRow(output, table.name, index.name, stat);
        analyzed_index = true;
    }
    if (only_index == null and (!analyzed_index or table.indexes.len == 0)) {
        var buffer: [32]u8 = undefined;
        const stat = std.fmt.bufPrint(&buffer, "{d}", .{table.row_count}) catch return error.OutOfMemory;
        try appendRow(output, table.name, null, stat);
    }
}

/// Source `analyzeDatabase()`.
pub fn analyzeDatabase(output: *StatTable, tables: []const TableInput) Error!void {
    openStatisticsTable(output, null, false);
    for (tables) |table| try analyzeOneTable(output, table, null);
}

/// Source `analyzeTable()`.
pub fn analyzeTable(output: *StatTable, table: TableInput, only_index: ?[]const u8) Error!void {
    openStatisticsTable(output, only_index orelse table.name, only_index != null);
    try analyzeOneTable(output, table, only_index);
}

/// Source `sqlite3Analyze()`.
pub fn analyzeRequest(output: *StatTable, tables: []const TableInput, first_name: ?[]const u8, second_name: ?[]const u8) Error!void {
    if (first_name == null) return analyzeDatabase(output, tables);
    const requested = second_name orelse first_name.?;
    for (tables) |table| {
        if (std.ascii.eqlIgnoreCase(table.name, requested)) return analyzeTable(output, table, null);
        for (table.indexes) |index| if (std.ascii.eqlIgnoreCase(index.name, requested)) return analyzeTable(output, table, index.name);
    }
    return error.NotFound;
}

/// Source `decodeIntArray()`.
pub fn decodeIntegerArray(text: []const u8, output: []u64, logarithms: ?[]i16, flags: *DecodeFlags) void {
    @memset(output, 0);
    if (logarithms) |values| @memset(values, 0);
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < text.len and index < output.len) : (index += 1) {
        var value: u64 = 0;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {
            value = value *| 10 +| text[cursor] - '0';
        }
        output[index] = value;
        if (logarithms) |values| {
            if (index < values.len) values[index] = log_est.fromInt(value);
        }
        while (cursor < text.len and text[cursor] == ' ') cursor += 1;
        if (cursor < text.len and !std.ascii.isDigit(text[cursor])) break;
    }
    while (cursor < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, cursor, ' ') orelse text.len;
        const token = text[cursor..end];
        if (std.mem.eql(u8, token, "unordered")) flags.unordered = true else if (std.mem.eql(u8, token, "noskipscan")) flags.no_skip_scan = true else if (std.mem.startsWith(u8, token, "sz=")) flags.row_size = @max(2, std.fmt.parseInt(usize, token[3..], 10) catch 2);
        cursor = end;
        while (cursor < text.len and text[cursor] == ' ') cursor += 1;
    }
}

/// Source `analysisLoader()`.
pub fn loadAnalysisRow(analysis: *LoadedAnalysis, row: StatRow) Error!void {
    var count: usize = 0;
    while (count < row.stat.len and (std.ascii.isDigit(row.stat[count]) or row.stat[count] == ' ')) : (count += 1) {}
    var number_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < count) {
        while (cursor < count and row.stat[cursor] == ' ') cursor += 1;
        if (cursor >= count) break;
        number_count += 1;
        while (cursor < count and std.ascii.isDigit(row.stat[cursor])) cursor += 1;
    }
    const estimates = analysis.allocator.alloc(u64, number_count) catch return error.OutOfMemory;
    errdefer analysis.allocator.free(estimates);
    const logs = analysis.allocator.alloc(i16, number_count) catch return error.OutOfMemory;
    errdefer analysis.allocator.free(logs);
    var flags: DecodeFlags = .{};
    decodeIntegerArray(row.stat, estimates, logs, &flags);
    const table_name = analysis.allocator.dupe(u8, row.table_name) catch return error.OutOfMemory;
    errdefer analysis.allocator.free(table_name);
    const index_name = if (row.index_name) |name| analysis.allocator.dupe(u8, name) catch return error.OutOfMemory else null;
    errdefer if (index_name) |name| analysis.allocator.free(name);
    analysis.indexes.append(analysis.allocator, .{ .allocator = analysis.allocator, .table_name = table_name, .index_name = index_name, .row_estimates = estimates, .log_estimates = logs, .flags = flags }) catch return error.OutOfMemory;
}

/// Source `sqlite3DeleteIndexSamples()`.
pub fn deleteIndexSamples(index: *LoadedIndex) void {
    for (index.samples.items) |sample| index.allocator.free(sample);
    index.samples.clearRetainingCapacity();
}

/// Source `sqlite3AnalysisLoad()`.
pub fn loadAnalysis(allocator: std.mem.Allocator, table: *const StatTable) Error!LoadedAnalysis {
    var analysis = LoadedAnalysis.init(allocator);
    errdefer analysis.deinit();
    for (table.rows.items) |row| try loadAnalysisRow(&analysis, row);
    return analysis;
}
