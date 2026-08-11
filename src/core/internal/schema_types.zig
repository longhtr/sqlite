//! Active-profile schema types shared by parser, VDBE, and P4 ownership.
//!
//! These preserve the source storage and ownership topology needed by the
//! fidelity translation. Handwritten Zig uses idiomatic field names; generated
//! oracle facts retain the corresponding C identities and offsets.

const std = @import("std");
const layout = @import("../generated/internal_vdbe_layout.zig");
const internal_hash = @import("../hash.zig");

pub const Expr = opaque {};
pub const ExprList = opaque {};
pub const Select = opaque {};
pub const Trigger = opaque {};
pub const VTable = opaque {};

pub const ColumnDefinition = packed struct(u8) {
    not_null_action: u4,
    declared_type: u4,
};

pub const Column = extern struct {
    name_and_metadata: ?[*:0]u8,
    definition: ColumnDefinition,
    affinity: u8,
    estimated_size: u8,
    name_hash: u8,
    default_expression_index: u16,
    flags: u16,
};

pub const ForeignKeyColumn = extern struct {
    source_column: c_int,
    _padding: c_int = 0,
    target_column: ?[*:0]u8,
};

/// Header immediately followed by `column_count` mappings.
pub const ForeignKeyActions = extern struct {
    on_delete: u8,
    on_update: u8,
};

pub const ForeignKey = extern struct {
    source_table: ?*Table,
    next_from: ?*ForeignKey,
    target_table: ?[*:0]u8,
    next_to: ?*ForeignKey,
    previous_to: ?*ForeignKey,
    column_count: c_int,
    deferred: u8,
    actions: ForeignKeyActions,
    _padding: u8 = 0,
    triggers: [2]?*Trigger,

    pub fn columns(self: *ForeignKey) []ForeignKeyColumn {
        const first: [*]ForeignKeyColumn = @ptrFromInt(@intFromPtr(self) + layout.FKey.aCol_offset);
        return first[0..@intCast(self.column_count)];
    }
};

pub const TableOrdinary = extern struct {
    add_column_offset: c_int,
    _padding: c_int = 0,
    foreign_keys: ?*ForeignKey,
    default_expressions: ?*ExprList,
};

pub const TableView = extern struct {
    query: ?*Select,
    _padding: [16]u8 = [_]u8{0} ** 16,
};

pub const TableVirtual = extern struct {
    argument_count: c_int,
    _padding: c_int = 0,
    arguments: ?[*]?[*:0]u8,
    instances: ?*VTable,
};

pub const TableOwner = extern union {
    ordinary: TableOrdinary,
    view: TableView,
    virtual: TableVirtual,
};

pub const TableKind = enum(u8) {
    ordinary = 0,
    virtual = 1,
    view = 2,
};

pub const Table = extern struct {
    name: ?[*:0]u8,
    columns: ?[*]Column,
    indexes: ?*Index,
    column_affinities: ?[*:0]u8,
    checks: ?*ExprList,
    root_page: u32,
    reference_count: u32,
    flags: u32,
    primary_key_column: i16,
    column_count: i16,
    non_virtual_column_count: i16,
    row_log_estimate: i16,
    row_size_estimate: i16,
    key_conflict_action: u8,
    kind: TableKind,
    owner: TableOwner,
    triggers: ?*Trigger,
    schema: ?*Schema,
    column_hash: [16]u8,
};

pub const IndexProperties = packed struct(u16) {
    kind: u2,
    unordered: bool,
    unique_not_null: bool,
    resized: bool,
    covering: bool,
    no_skip_scan: bool,
    has_statistics: bool,
    no_query: bool,
    ascending_key_bug: bool,
    has_virtual_column: bool,
    has_expression: bool,
    _reserved: u4 = 0,
};

pub const Index = extern struct {
    name: ?[*:0]u8,
    columns: ?[*]i16,
    row_log_estimates: ?[*]i16,
    table: ?*Table,
    column_affinities: ?[*:0]u8,
    next: ?*Index,
    schema: ?*Schema,
    sort_order: ?[*]u8,
    collations: ?[*]?[*:0]const u8,
    partial_predicate: ?*Expr,
    column_expressions: ?*ExprList,
    root_page: u32,
    row_size_estimate: i16,
    key_column_count: u16,
    column_count: u16,
    conflict_action: u8,
    properties: IndexProperties align(1),
    _padding: [3]u8 = [_]u8{0} ** 3,
    columns_not_indexed: u64,

    pub fn isResized(self: *const Index) bool {
        return self.properties.resized;
    }
};

/// Source `sqlite3IndexHasDuplicateRootPage()`: detect a sibling index on the
/// same table that aliases the target index root page.
pub fn indexHasDuplicateRootPage(index: *Index) bool {
    var sibling = index.table.?.indexes;
    while (sibling) |candidate| : (sibling = candidate.next) {
        if (candidate.root_page == index.root_page and candidate != index) {
            return true;
        }
    }
    return false;
}

pub const Schema = extern struct {
    cookie: c_int,
    generation: c_int,
    table_hash: internal_hash.Hash,
    index_hash: internal_hash.Hash,
    trigger_hash: internal_hash.Hash,
    foreign_key_hash: internal_hash.Hash,
    sequence_table: ?*Table,
    file_format: u8,
    encoding: u8,
    flags: u16,
    cache_size: c_int,
};

pub const table_flag = struct {
    pub const ephemeral: u32 = 0x0000_4000;
};

fn expectOffset(comptime Type: type, comptime field: []const u8, expected: usize) !void {
    try std.testing.expectEqual(expected, @offsetOf(Type, field));
}

test "source index duplicate root page checks sibling identity" {
    var table = std.mem.zeroes(Table);
    var first = std.mem.zeroes(Index);
    var target = std.mem.zeroes(Index);
    var last = std.mem.zeroes(Index);
    first.table = &table;
    target.table = &table;
    last.table = &table;
    first.root_page = 2;
    target.root_page = 5;
    last.root_page = 5;
    first.next = &target;
    target.next = &last;
    table.indexes = &first;
    try std.testing.expect(indexHasDuplicateRootPage(&target));
    last.root_page = 7;
    try std.testing.expect(!indexHasDuplicateRootPage(&target));
}

test "active schema storage topology matches the pinned profile" {
    inline for (.{
        .{ Column, layout.Column },
        .{ Table, layout.Table },
        .{ Index, layout.Index },
        .{ ForeignKey, layout.FKey },
        .{ Schema, layout.Schema },
    }) |pair| {
        try std.testing.expectEqual(pair[1].size, @sizeOf(pair[0]));
        try std.testing.expectEqual(pair[1].alignment, @alignOf(pair[0]));
    }

    try expectOffset(Column, "name_and_metadata", layout.Column.zCnName_offset);
    try expectOffset(Column, "definition", layout.Column.zCnName_offset + layout.Column.zCnName_size);
    try expectOffset(Column, "affinity", layout.Column.affinity_offset);
    try expectOffset(Column, "estimated_size", layout.Column.szEst_offset);
    try expectOffset(Column, "name_hash", layout.Column.hName_offset);
    try expectOffset(Column, "default_expression_index", layout.Column.iDflt_offset);
    try expectOffset(Column, "flags", layout.Column.colFlags_offset);
    const not_null = ColumnDefinition{ .not_null_action = 1, .declared_type = 0 };
    const declared_type = ColumnDefinition{ .not_null_action = 0, .declared_type = 1 };
    try std.testing.expectEqual(layout.constants.COLUMN_NOT_NULL_OFFSET, @offsetOf(Column, "definition"));
    try std.testing.expectEqual(@as(u8, @intCast(layout.constants.COLUMN_NOT_NULL_MASK)), @as(u8, @bitCast(not_null)));
    try std.testing.expectEqual(@as(u8, @intCast(layout.constants.COLUMN_DECLARED_TYPE_MASK)), @as(u8, @bitCast(declared_type)));

    try expectOffset(Table, "name", layout.Table.zName_offset);
    try expectOffset(Table, "columns", layout.Table.aCol_offset);
    try expectOffset(Table, "indexes", layout.Table.pIndex_offset);
    try expectOffset(Table, "column_affinities", layout.Table.zColAff_offset);
    try expectOffset(Table, "checks", layout.Table.pCheck_offset);
    try expectOffset(Table, "root_page", layout.Table.tnum_offset);
    try expectOffset(Table, "reference_count", layout.Table.nTabRef_offset);
    try expectOffset(Table, "flags", layout.Table.tabFlags_offset);
    try expectOffset(Table, "primary_key_column", layout.Table.iPKey_offset);
    try expectOffset(Table, "column_count", layout.Table.nCol_offset);
    try expectOffset(Table, "non_virtual_column_count", layout.Table.nNVCol_offset);
    try expectOffset(Table, "row_log_estimate", layout.Table.nRowLogEst_offset);
    try expectOffset(Table, "row_size_estimate", layout.Table.szTabRow_offset);
    try expectOffset(Table, "key_conflict_action", layout.Table.keyConf_offset);
    try expectOffset(Table, "kind", layout.Table.eTabType_offset);
    try expectOffset(Table, "owner", layout.Table.u_offset);
    try expectOffset(Table, "triggers", layout.Table.pTrigger_offset);
    try expectOffset(Table, "schema", layout.Table.pSchema_offset);
    try expectOffset(Table, "column_hash", layout.Table.aHx_offset);
    try std.testing.expectEqual(layout.Table.u_tab_pFKey_offset, @offsetOf(Table, "owner") + @offsetOf(TableOrdinary, "foreign_keys"));
    try std.testing.expectEqual(layout.Table.u_view_pSelect_offset, @offsetOf(Table, "owner") + @offsetOf(TableView, "query"));

    try expectOffset(Index, "name", layout.Index.zName_offset);
    try expectOffset(Index, "columns", layout.Index.aiColumn_offset);
    try expectOffset(Index, "row_log_estimates", layout.Index.aiRowLogEst_offset);
    try expectOffset(Index, "table", layout.Index.pTable_offset);
    try expectOffset(Index, "column_affinities", layout.Index.zColAff_offset);
    try expectOffset(Index, "next", layout.Index.pNext_offset);
    try expectOffset(Index, "schema", layout.Index.pSchema_offset);
    try expectOffset(Index, "sort_order", layout.Index.aSortOrder_offset);
    try expectOffset(Index, "collations", layout.Index.azColl_offset);
    try expectOffset(Index, "partial_predicate", layout.Index.pPartIdxWhere_offset);
    try expectOffset(Index, "column_expressions", layout.Index.aColExpr_offset);
    try expectOffset(Index, "root_page", layout.Index.tnum_offset);
    try expectOffset(Index, "row_size_estimate", layout.Index.szIdxRow_offset);
    try expectOffset(Index, "key_column_count", layout.Index.nKeyCol_offset);
    try expectOffset(Index, "column_count", layout.Index.nColumn_offset);
    try expectOffset(Index, "conflict_action", layout.Index.onError_offset);
    try expectOffset(Index, "properties", layout.Index.onError_offset + layout.Index.onError_size);
    try expectOffset(Index, "columns_not_indexed", layout.Index.colNotIdxed_offset);
    var properties: IndexProperties = @bitCast(@as(u16, 0));
    properties.resized = true;
    properties.has_expression = true;
    const property_bytes: [2]u8 = @bitCast(properties);
    try std.testing.expectEqual(@as(u8, @intCast(layout.constants.INDEX_RESIZED_MASK)), property_bytes[layout.constants.INDEX_RESIZED_OFFSET - layout.constants.INDEX_KIND_OFFSET]);
    try std.testing.expectEqual(@as(u8, @intCast(layout.constants.INDEX_HAS_EXPRESSION_MASK)), property_bytes[layout.constants.INDEX_HAS_EXPRESSION_OFFSET - layout.constants.INDEX_KIND_OFFSET]);

    try expectOffset(ForeignKey, "source_table", layout.FKey.pFrom_offset);
    try expectOffset(ForeignKey, "next_from", layout.FKey.pNextFrom_offset);
    try expectOffset(ForeignKey, "target_table", layout.FKey.zTo_offset);
    try expectOffset(ForeignKey, "next_to", layout.FKey.pNextTo_offset);
    try expectOffset(ForeignKey, "previous_to", layout.FKey.pPrevTo_offset);
    try expectOffset(ForeignKey, "column_count", layout.FKey.nCol_offset);
    try expectOffset(ForeignKey, "deferred", layout.FKey.isDeferred_offset);
    try expectOffset(ForeignKey, "actions", layout.FKey.aAction_offset);
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(ForeignKeyActions));
    try expectOffset(ForeignKey, "triggers", layout.FKey.apTrigger_offset);
    try std.testing.expectEqual(layout.FKey.aCol_offset, @sizeOf(ForeignKey));
    try std.testing.expectEqual(layout.FKey.aCol_size, @sizeOf(ForeignKeyColumn));

    try expectOffset(Schema, "cookie", layout.Schema.schema_cookie_offset);
    try expectOffset(Schema, "generation", layout.Schema.iGeneration_offset);
    try expectOffset(Schema, "table_hash", layout.Schema.tblHash_offset);
    try expectOffset(Schema, "index_hash", layout.Schema.idxHash_offset);
    try expectOffset(Schema, "trigger_hash", layout.Schema.trigHash_offset);
    try expectOffset(Schema, "foreign_key_hash", layout.Schema.fkeyHash_offset);
    try expectOffset(Schema, "sequence_table", layout.Schema.pSeqTab_offset);
    try expectOffset(Schema, "file_format", layout.Schema.file_format_offset);
    try expectOffset(Schema, "encoding", layout.Schema.enc_offset);
    try expectOffset(Schema, "flags", layout.Schema.schemaFlags_offset);
    try expectOffset(Schema, "cache_size", layout.Schema.cache_size_offset);
}
