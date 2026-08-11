//! SQLite B-tree traversal, records, and bounded table mutation.
//!
//! Fidelity sources are `src/btree.c`, `src/btreeInt.h`, and the record
//! serial routines in `src/vdbeaux.c` at the pinned SQLite check-in. The
//! implementation owns native Zig state and reaches storage only through the
//! Phase 8 pager. Phase 9 adds outcome-equivalent tree reconstruction for
//! mutation; custom collations, shared-cache, and WAL remain out of profile.

const std = @import("std");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const pager_module = @import("pager.zig");
const record_compare = @import("internal/record_compare.zig");
const Pager = pager_module.Pager;
const ResultCode = @import("result_code.zig").ResultCode;
pub const vfs = pager_module.vfs;

pub const maximum_depth: usize = 64;
pub const maximum_payload: u32 = 1_000_000_000;

pub const Encoding = enum(u32) {
    utf8 = 1,
    utf16le = 2,
    utf16be = 3,
};

pub const TreeKind = enum { table, index };

pub const Value = union(enum) {
    null_,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const IndexCollationCallback = *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int;

pub const IndexCollation = union(enum) {
    binary,
    nocase,
    rtrim,
    custom: struct { context: ?*anyopaque, callback: IndexCollationCallback },
};
pub const IndexSortOrder = enum { ascending, descending };
pub const IndexTransform = union(enum) {
    identity,
    numeric_negate,
    integer_add: i64,
    integer_multiply: i64,
};

pub fn transformIndexValue(transform: IndexTransform, value: Value) Value {
    return switch (transform) {
        .identity => value,
        .numeric_negate => switch (value) {
            .null_ => .null_,
            .integer => |integer| if (integer == std.math.minInt(i64)) .{ .real = -@as(f64, @floatFromInt(integer)) } else .{ .integer = -integer },
            .real => |real| .{ .real = -real },
            .text, .blob => .null_,
        },
        .integer_add => |addition| switch (value) {
            .null_ => .null_,
            .integer => |integer| .{ .integer = std.math.add(i64, integer, addition) catch return .{ .real = @as(f64, @floatFromInt(integer)) + @as(f64, @floatFromInt(addition)) } },
            .real => |real| .{ .real = real + @as(f64, @floatFromInt(addition)) },
            .text, .blob => .null_,
        },
        .integer_multiply => |factor| switch (value) {
            .null_ => .null_,
            .integer => |integer| .{ .integer = std.math.mul(i64, integer, factor) catch return .{ .real = @as(f64, @floatFromInt(integer)) * @as(f64, @floatFromInt(factor)) } },
            .real => |real| .{ .real = real * @as(f64, @floatFromInt(factor)) },
            .text, .blob => .null_,
        },
    };
}

pub const IndexPredicateOperation = enum { is_null, is_not_null, integer_eq, integer_ne, integer_lt, integer_le, integer_gt, integer_ge };

pub const IndexPredicate = struct {
    column_index: usize,
    integer_primary_key: bool,
    operation: IndexPredicateOperation,
    comparison_value: i64 = 0,
};

pub fn indexPredicateMatches(predicate: IndexPredicate, value: Value) bool {
    return switch (predicate.operation) {
        .is_null => switch (value) {
            .null_ => true,
            else => false,
        },
        .is_not_null => switch (value) {
            .null_ => false,
            else => true,
        },
        .integer_eq, .integer_ne, .integer_lt, .integer_le, .integer_gt, .integer_ge => {
            const order = switch (value) {
                .integer => |integer| std.math.order(integer, predicate.comparison_value),
                .real => |real| std.math.order(real, @as(f64, @floatFromInt(predicate.comparison_value))),
                else => return false,
            };
            return switch (predicate.operation) {
                .integer_eq => order == .eq,
                .integer_ne => order != .eq,
                .integer_lt => order == .lt,
                .integer_le => order != .gt,
                .integer_gt => order == .gt,
                .integer_ge => order != .lt,
                else => unreachable,
            };
        },
    };
}

pub const RecordView = struct {
    allocator: std.mem.Allocator,
    values: []Value,

    pub fn deinit(self: *RecordView) void {
        self.allocator.free(self.values);
        self.values = &.{};
    }
};

pub const RecordOutcome = struct {
    result: ResultCode,
    record: ?RecordView = null,
};

pub fn encodeRecord(allocator: std.mem.Allocator, values: []const Value) ![]u8 {
    var header_body: usize = 0;
    var payload_size: usize = 0;
    for (values) |value| {
        const serial: u64 = switch (value) {
            .null_ => 0,
            .integer => 6,
            .real => 7,
            .text => |bytes| 13 + 2 * bytes.len,
            .blob => |bytes| 12 + 2 * bytes.len,
        };
        header_body += varintLength(serial);
        payload_size += switch (value) {
            .null_ => 0,
            .integer, .real => 8,
            .text => |bytes| bytes.len,
            .blob => |bytes| bytes.len,
        };
    }
    var header_size = header_body + varintLength(header_body + 1);
    while (varintLength(header_size) + header_body != header_size) header_size = varintLength(header_size) + header_body;
    if (header_size + payload_size > maximum_payload) return error.TooBig;
    const output = try allocator.alloc(u8, header_size + payload_size);
    var offset = writeVarint(output, header_size);
    for (values) |value| {
        const serial: u64 = switch (value) {
            .null_ => 0,
            .integer => 6,
            .real => 7,
            .text => |bytes| 13 + 2 * bytes.len,
            .blob => |bytes| 12 + 2 * bytes.len,
        };
        offset += writeVarint(output[offset..], serial);
    }
    std.debug.assert(offset == header_size);
    for (values) |value| switch (value) {
        .null_ => {},
        .integer => |integer| {
            const bits: u64 = @bitCast(integer);
            for (0..8) |index| output[offset + index] = @truncate(bits >> @intCast((7 - index) * 8));
            offset += 8;
        },
        .real => |real| {
            const bits: u64 = @bitCast(real);
            for (0..8) |index| output[offset + index] = @truncate(bits >> @intCast((7 - index) * 8));
            offset += 8;
        },
        .text => |bytes| {
            @memcpy(output[offset..][0..bytes.len], bytes);
            offset += bytes.len;
        },
        .blob => |bytes| {
            @memcpy(output[offset..][0..bytes.len], bytes);
            offset += bytes.len;
        },
    };
    return output;
}

pub const Entry = struct {
    rowid: ?i64,
    payload: []u8,
};

pub const SeekOutcome = struct {
    result: ResultCode,
    found: bool = false,
};

const SavedCursorPosition = union(TreeKind) {
    table: i64,
    index: []u8,
};

pub const Cursor = struct {
    allocator: std.mem.Allocator,
    kind: TreeKind,
    entries: std.ArrayList(Entry) = .empty,
    position: ?usize = null,
    saved_position: ?SavedCursorPosition = null,

    pub fn deinit(self: *Cursor) void {
        if (self.saved_position) |saved| switch (saved) {
            .table => {},
            .index => |payload| self.allocator.free(payload),
        };
        for (self.entries.items) |entry| {
            self.allocator.free(entry.payload);
        }
        self.entries.deinit(self.allocator);
        self.position = null;
    }

    pub fn count(self: *const Cursor) usize {
        return self.entries.items.len;
    }

    /// Source `moveToRoot()`: position on the first or last logical entry in
    /// the materialized cursor view.
    pub fn moveToRoot(self: *Cursor, toward_last: bool) bool {
        if (self.entries.items.len == 0) {
            self.position = null;
            return false;
        }
        self.position = if (toward_last) self.entries.items.len - 1 else 0;
        return true;
    }

    pub fn first(self: *Cursor) bool {
        return self.moveToRoot(false);
    }

    pub fn last(self: *Cursor) bool {
        return self.moveToRoot(true);
    }

    /// Source `btreeNext()`: advance one ordered entry and invalidate the
    /// cursor after the logical end.
    fn btreeNext(self: *Cursor) bool {
        const position = self.position orelse return false;
        if (position + 1 >= self.entries.items.len) {
            self.position = null;
            return false;
        }
        self.position = position + 1;
        return true;
    }

    pub fn next(self: *Cursor) bool {
        return self.btreeNext();
    }

    /// Source `btreePrevious()`: move one ordered entry backward and
    /// invalidate the cursor before the logical beginning.
    fn btreePrevious(self: *Cursor) bool {
        const position = self.position orelse return false;
        if (position == 0) {
            self.position = null;
            return false;
        }
        self.position = position - 1;
        return true;
    }

    pub fn previous(self: *Cursor) bool {
        return self.btreePrevious();
    }

    /// Source `moveToChild()`: select a validated logical child position in
    /// the materialized ordered view.
    pub fn moveToChild(self: *Cursor, position: usize) bool {
        if (position >= self.entries.items.len) {
            self.position = null;
            return false;
        }
        self.position = position;
        return true;
    }

    pub fn current(self: *const Cursor) ?*const Entry {
        const position = self.position orelse return null;
        return &self.entries.items[position];
    }

    /// Source `accessPayload()`: copy a bounded range from the current cell
    /// payload and reject overflow or an unpositioned cursor.
    pub fn accessPayload(self: *const Cursor, offset: usize, output: []u8) ResultCode {
        const entry = self.current() orelse return .misuse;
        const end = std.math.add(usize, offset, output.len) catch return .corrupt;
        if (end > entry.payload.len) return .corrupt;
        @memcpy(output, entry.payload[offset..end]);
        return .ok;
    }

    /// Source `saveCursorPosition()`: retain the logical table rowid or an
    /// owned encoded index key across cursor reconstruction.
    pub fn saveCursorPosition(self: *Cursor) ResultCode {
        if (self.saved_position) |saved| switch (saved) {
            .table => {},
            .index => |payload| self.allocator.free(payload),
        };
        self.saved_position = null;
        const entry = self.current() orelse return .misuse;
        self.saved_position = switch (self.kind) {
            .table => .{ .table = entry.rowid orelse return .corrupt },
            .index => .{ .index = self.allocator.dupe(u8, entry.payload) catch return .no_memory },
        };
        return .ok;
    }

    /// Source `btreeRestoreCursorPosition()`: seek the saved logical key after
    /// entries have been rebuilt, then release saved-key ownership.
    pub fn restoreCursorPosition(self: *Cursor) ResultCode {
        const saved = self.saved_position orelse return .ok;
        self.saved_position = null;
        switch (saved) {
            .table => |rowid| {
                _ = self.seekTable(rowid);
            },
            .index => |payload| {
                defer self.allocator.free(payload);
                var lower: usize = 0;
                var upper = self.entries.items.len;
                while (lower < upper) {
                    const middle = lower + (upper - lower) / 2;
                    const compared = compareRecordPayloads(self.allocator, self.entries.items[middle].payload, payload);
                    if (compared.result != .ok) return compared.result;
                    if (compared.order == .lt) {
                        lower = middle + 1;
                    } else {
                        upper = middle;
                    }
                }
                self.position = if (lower < self.entries.items.len) lower else null;
            },
        }
        return .ok;
    }

    /// Equivalent bounded behavior to sqlite3BtreeTableMoveto(): position at
    /// the first rowid greater than or equal to `rowid` and report exactness.
    pub fn seekTable(self: *Cursor, rowid: i64) bool {
        if (self.kind != .table) {
            self.position = null;
            return false;
        }
        var lower: usize = 0;
        var upper = self.entries.items.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (self.entries.items[middle].rowid.? < rowid) lower = middle + 1 else upper = middle;
        }
        if (lower == self.entries.items.len) {
            self.position = null;
            return false;
        }
        self.position = lower;
        return self.entries.items[lower].rowid.? == rowid;
    }

    /// Position an index cursor at the first record greater than or equal to
    /// an unpacked key. The bounded Phase 7 profile uses ascending BINARY
    /// collation, matching every index in its versioned corpus.
    pub fn seekIndex(self: *Cursor, key: []const Value) SeekOutcome {
        if (self.kind != .index or key.len == 0) {
            self.position = null;
            return .{ .result = .misuse };
        }
        const key_context = RecordKeyContext{ .values = key };
        const search = record_compare.findIndexKey(self.entries.items.len, self, cursorRecordPayload, key.len, &key_context, recordKeyValue) catch {
            self.position = null;
            return .{ .result = .corrupt };
        };
        if (search.position == self.entries.items.len) {
            self.position = null;
            return .{ .result = .ok };
        }
        self.position = search.position;
        return .{ .result = .ok, .found = search.found };
    }

    pub fn record(self: *const Cursor) RecordOutcome {
        const entry = self.current() orelse return .{ .result = .misuse };
        return decodeRecord(self.allocator, entry.payload);
    }
};

pub const CursorOutcome = struct {
    result: ResultCode,
    cursor: ?Cursor = null,
};

pub const SchemaTable = struct {
    allocator: std.mem.Allocator,
    root_page: u32,
    sql: []u8,

    pub fn deinit(self: *SchemaTable) void {
        self.allocator.free(self.sql);
        self.sql = &.{};
    }
};

pub const SchemaTableOutcome = struct { result: ResultCode, table: ?SchemaTable = null };

pub const OpenOutcome = struct {
    result: ResultCode,
    database: ?Database = null,
};

const Cell = struct {
    child: ?u32 = null,
    rowid: ?i64 = null,
    payload_size: u32 = 0,
    local_size: u32 = 0,
    payload_offset: usize = 0,
    overflow_page: u32 = 0,
};

const PageInfo = struct {
    leaf: bool,
    kind: TreeKind,
    cell_count: usize,
    pointer_offset: usize,
    right_child: u32,
    max_local: u32,
    min_local: u32,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    pager: Pager,
    encoding: Encoding,
    usable_size: u32,
    declared_pages: u32,
    writable: bool = false,
    mutation_batch_depth: usize = 0,
    mutation_batch_pages: u32 = 0,
    statement_batch_pages: u32 = 0,

    pub fn open(
        allocator: std.mem.Allocator,
        abi_vfs: *vfs.sqlite3_vfs,
        name: []const u8,
    ) OpenOutcome {
        return openMode(allocator, abi_vfs, name, false);
    }

    pub fn openWritable(
        allocator: std.mem.Allocator,
        abi_vfs: *vfs.sqlite3_vfs,
        name: []const u8,
    ) OpenOutcome {
        return openMode(allocator, abi_vfs, name, true);
    }

    fn openMode(
        allocator: std.mem.Allocator,
        abi_vfs: *vfs.sqlite3_vfs,
        name: []const u8,
        writable: bool,
    ) OpenOutcome {
        const pager_outcome = Pager.open(allocator, abi_vfs, name, .{ .writable = writable });
        if (pager_outcome.result != .ok) return .{ .result = pager_outcome.result };
        var pager = pager_outcome.pager.?;
        var rc = pager.beginRead();
        if (rc != .ok) {
            _ = pager.close();
            return .{ .result = rc };
        }
        if (pager.pageCount() == 0) {
            _ = pager.close();
            return .{ .result = .not_a_database };
        }
        const first = pager.getPage(1, false);
        if (first.result != .ok) {
            _ = pager.close();
            return .{ .result = first.result };
        }
        const bytes = first.page.?.data;
        if (bytes.len < 100) {
            _ = pager.release(first.page.?);
            _ = pager.close();
            return .{ .result = .corrupt };
        }
        const encoding_value = readU32(bytes, 56) orelse 0;
        const encoding: Encoding = switch (encoding_value) {
            0, 1 => .utf8,
            2 => .utf16le,
            3 => .utf16be,
            else => {
                _ = pager.release(first.page.?);
                _ = pager.close();
                return .{ .result = .corrupt };
            },
        };
        const declared_pages = readU32(bytes, 28) orelse 0;
        if (declared_pages == 0 or declared_pages > pager.pageCount()) {
            _ = pager.release(first.page.?);
            _ = pager.close();
            return .{ .result = .corrupt };
        }
        rc = pager.release(first.page.?);
        if (rc != .ok) {
            _ = pager.close();
            return .{ .result = rc };
        }
        return .{
            .result = .ok,
            .database = .{
                .allocator = allocator,
                .pager = pager,
                .encoding = encoding,
                .usable_size = pager.page_size - pager.reserved_bytes,
                .declared_pages = declared_pages,
                .writable = writable,
            },
        };
    }

    pub fn close(self: *Database) ResultCode {
        if (self.mutation_batch_depth != 0) {
            const rc = self.rollbackMutationBatch();
            if (rc != .ok) return rc;
        }
        return self.pager.close();
    }

    pub fn schemaVersion(self: *Database) struct { result: ResultCode, value: u32 = 0 } {
        const fetched = self.pager.getPage(1, false);
        if (fetched.result != .ok) return .{ .result = fetched.result };
        const page = fetched.page.?;
        const value = readU32(page.data, 40) orelse {
            _ = self.pager.release(page);
            return .{ .result = .corrupt };
        };
        const rc = self.pager.release(page);
        return .{ .result = rc, .value = value };
    }

    pub fn userVersion(self: *Database) struct { result: ResultCode, value: u32 = 0 } {
        const fetched = self.pager.getPage(1, false);
        if (fetched.result != .ok) return .{ .result = fetched.result };
        const page = fetched.page.?;
        const value = readU32(page.data, 60) orelse {
            _ = self.pager.release(page);
            return .{ .result = .corrupt };
        };
        const rc = self.pager.release(page);
        return .{ .result = rc, .value = value };
    }

    pub fn vacuumCompactNoop(self: *Database) ResultCode {
        if (!self.writable) return .read_only;
        const fetched = self.pager.getPage(1, false);
        if (fetched.result != .ok) return fetched.result;
        const page = fetched.page.?;
        const free_pages = readU32(page.data, 36) orelse {
            _ = self.pager.release(page);
            return .corrupt;
        };
        const rc = self.pager.release(page);
        if (rc != .ok) return rc;
        return if (free_pages == 0) .ok else .error_;
    }

    fn schemaObject(self: *Database, name: []const u8, object_type: []const u8) SchemaTableOutcome {
        const opened = self.openCursor(1, .table);
        if (opened.result != .ok) return .{ .result = opened.result };
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        for (cursor.entries.items) |entry| {
            const record = decodeRecord(self.allocator, entry.payload);
            if (record.result != .ok) return .{ .result = record.result };
            var view = record.record.?;
            defer view.deinit();
            if (view.values.len < 5 or !schemaTextEqual(view.values[0], object_type) or !schemaTextEqual(view.values[1], name)) continue;
            const root_page: u32 = switch (view.values[3]) {
                .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else return .{ .result = .corrupt },
                else => return .{ .result = .corrupt },
            };
            const sql = switch (view.values[4]) {
                .text => |bytes| self.allocator.dupe(u8, bytes) catch return .{ .result = .no_memory },
                else => return .{ .result = .corrupt },
            };
            return .{ .result = .ok, .table = .{ .allocator = self.allocator, .root_page = root_page, .sql = sql } };
        }
        return .{ .result = .not_found };
    }

    pub fn schemaTable(self: *Database, name: []const u8) SchemaTableOutcome {
        return self.schemaObject(name, "table");
    }

    pub fn schemaIndex(self: *Database, name: []const u8) SchemaTableOutcome {
        return self.schemaObject(name, "index");
    }

    pub fn schemaTableExists(self: *Database, name: []const u8) struct { result: ResultCode, found: bool = false } {
        const opened = self.openCursor(1, .table);
        if (opened.result != .ok) return .{ .result = opened.result };
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        for (cursor.entries.items) |entry| {
            const record = decodeRecord(self.allocator, entry.payload);
            if (record.result != .ok) return .{ .result = record.result };
            var view = record.record.?;
            defer view.deinit();
            if (view.values.len >= 2 and schemaTextEqual(view.values[0], "table") and schemaTextEqual(view.values[1], name))
                return .{ .result = .ok, .found = true };
        }
        return .{ .result = .ok };
    }

    /// Create an empty table root and its sqlite_schema row in one pager
    /// transaction. Phase 13 deliberately bounds this path to a leaf schema
    /// table and non-auto-vacuum databases; later schema slices remove those
    /// restrictions.
    pub fn createSchemaTable(self: *Database, name: []const u8, sql: []const u8, if_not_exists: bool) ResultCode {
        if (!self.writable) return .read_only;
        if (name.len == 0 or sql.len == 0) return .misuse;
        const opened = self.openCursor(1, .table);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var next_rowid: i64 = 1;
        for (cursor.entries.items) |entry| {
            next_rowid = @max(next_rowid, (entry.rowid orelse 0) + 1);
            const record = decodeRecord(self.allocator, entry.payload);
            if (record.result != .ok) return record.result;
            var view = record.record.?;
            defer view.deinit();
            if (view.values.len >= 2 and schemaTextEqual(view.values[0], "table") and schemaTextEqual(view.values[1], name))
                return if (if_not_exists) .ok else .error_;
        }
        const owns_transaction = self.mutation_batch_depth == 0;
        var rc: ResultCode = .ok;
        if (owns_transaction) {
            rc = self.pager.beginWrite();
            if (rc != .ok) return rc;
        }
        const planned = RebuildPlanner.init(self, 1, .table);
        if (planned.result != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return planned.result;
        }
        var planner = planned.planner.?;
        defer planner.deinit();
        if (planner.auto_vacuum) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return .error_;
        }
        const allocated = planner.allocate();
        if (allocated.result != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return allocated.result;
        }
        const root_page = allocated.page;
        rc = writeTableLeaf(&planner, root_page, &.{});
        if (rc == .ok) {
            const schema_payload = encodeSchemaRecord(self.allocator, "table", name, name, root_page, sql) catch |err| {
                if (owns_transaction) {
                    _ = self.pager.rollback();
                }
                return if (err == error.OutOfMemory) .no_memory else .too_big;
            };
            defer self.allocator.free(schema_payload);
            const copy = self.allocator.dupe(u8, schema_payload) catch {
                if (owns_transaction) {
                    _ = self.pager.rollback();
                }
                return .no_memory;
            };
            cursor.entries.append(self.allocator, .{ .rowid = next_rowid, .payload = copy }) catch {
                self.allocator.free(copy);
                if (owns_transaction) {
                    _ = self.pager.rollback();
                }
                return .no_memory;
            };
            if (!entriesFitLeaf(self, cursor.entries.items, 100)) rc = .too_big else rc = writeTableLeaf(&planner, 1, cursor.entries.items);
        }
        if (rc == .ok) rc = bumpSchemaCookie(&planner);
        if (rc == .ok) rc = planner.finishFreelist();
        if (rc == .ok and owns_transaction) {
            rc = self.pager.commit();
        }
        if (rc != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return rc;
        }
        self.declared_pages = planner.next_page;
        return .ok;
    }

    /// Bounded source `sqlite3CreateIndex()`/`sqlite3RefillIndex()` path for
    /// an ordinary application-defined index. Existing matching table rows
    /// are encoded with their trailing rowid before schema publication.
    pub fn createSchemaIndex(self: *Database, name: []const u8, table_name: []const u8, sql: []const u8, table_root: u32, column_indices: []const usize, integer_primary_key_position: ?usize, collations: []const IndexCollation, sort_orders: []const IndexSortOrder, transforms: []const IndexTransform, predicate: ?IndexPredicate, unique: bool, if_not_exists: bool) ResultCode {
        if (!self.writable) return .read_only;
        if (name.len == 0 or table_name.len == 0 or sql.len == 0 or column_indices.len == 0 or collations.len != column_indices.len or sort_orders.len != column_indices.len or transforms.len != column_indices.len) return .misuse;
        const table_opened = self.openCursor(table_root, .table);
        if (table_opened.result != .ok) return table_opened.result;
        var table_cursor = table_opened.cursor.?;
        defer table_cursor.deinit();
        var index_payloads = std.ArrayList([]u8).empty;
        defer {
            for (index_payloads.items) |payload| self.allocator.free(payload);
            index_payloads.deinit(self.allocator);
        }
        for (table_cursor.entries.items) |entry| {
            const rowid = entry.rowid orelse return .corrupt;
            const decoded = decodeRecord(self.allocator, entry.payload);
            if (decoded.result != .ok) return decoded.result;
            var record = decoded.record.?;
            defer record.deinit();
            if (predicate) |filter| {
                if (filter.column_index >= record.values.len) return .corrupt;
                const value: Value = if (filter.integer_primary_key) .{ .integer = rowid } else record.values[filter.column_index];
                if (!indexPredicateMatches(filter, value)) continue;
            }
            const key_values = self.allocator.alloc(Value, column_indices.len + 1) catch return .no_memory;
            defer self.allocator.free(key_values);
            for (column_indices, 0..) |column_index, index| {
                if (column_index >= record.values.len) return .corrupt;
                key_values[index] = transformIndexValue(transforms[index], if (integer_primary_key_position == index) .{ .integer = rowid } else record.values[column_index]);
            }
            key_values[column_indices.len] = .{ .integer = rowid };
            const payload = encodeRecord(self.allocator, key_values) catch |err| return if (err == error.OutOfMemory) .no_memory else .too_big;
            index_payloads.append(self.allocator, payload) catch {
                self.allocator.free(payload);
                return .no_memory;
            };
        }
        const opened = self.openCursor(1, .table);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var next_rowid: i64 = 1;
        for (cursor.entries.items) |entry| {
            next_rowid = @max(next_rowid, (entry.rowid orelse 0) + 1);
            const record = decodeRecord(self.allocator, entry.payload);
            if (record.result != .ok) return record.result;
            var view = record.record.?;
            defer view.deinit();
            if (view.values.len >= 2 and schemaTextEqual(view.values[1], name)) {
                const existing_is_index = view.values.len >= 1 and schemaTextEqual(view.values[0], "index");
                return if (if_not_exists and existing_is_index) .ok else .error_;
            }
        }

        const owns_transaction = self.mutation_batch_depth == 0;
        if (owns_transaction) {
            const begun = self.beginMutationBatch();
            if (begun != .ok) return begun;
        }
        var rc: ResultCode = .ok;
        const planned = RebuildPlanner.init(self, 1, .table);
        if (planned.result != .ok) {
            if (owns_transaction) {
                _ = self.rollbackMutationBatch();
            }
            return planned.result;
        }
        var planner = planned.planner.?;
        defer planner.deinit();
        if (planner.auto_vacuum) {
            if (owns_transaction) {
                _ = self.rollbackMutationBatch();
            }
            return .error_;
        }
        const allocated = planner.allocate();
        if (allocated.result != .ok) {
            if (owns_transaction) {
                _ = self.rollbackMutationBatch();
            }
            return allocated.result;
        }
        const root_page = allocated.page;
        rc = writeIndexLeaf(&planner, root_page, &.{});
        if (rc == .ok) {
            const schema_payload = encodeSchemaRecord(self.allocator, "index", name, table_name, root_page, sql) catch |err| {
                if (owns_transaction) {
                    _ = self.rollbackMutationBatch();
                }
                return if (err == error.OutOfMemory) .no_memory else .too_big;
            };
            defer self.allocator.free(schema_payload);
            const copy = self.allocator.dupe(u8, schema_payload) catch {
                if (owns_transaction) {
                    _ = self.rollbackMutationBatch();
                }
                return .no_memory;
            };
            cursor.entries.append(self.allocator, .{ .rowid = next_rowid, .payload = copy }) catch {
                self.allocator.free(copy);
                if (owns_transaction) {
                    _ = self.rollbackMutationBatch();
                }
                return .no_memory;
            };
            if (!entriesFitLeaf(self, cursor.entries.items, 100)) {
                rc = .too_big;
            } else {
                rc = writeTableLeaf(&planner, 1, cursor.entries.items);
            }
        }
        if (rc == .ok) {
            rc = bumpSchemaCookie(&planner);
        }
        if (rc == .ok) {
            rc = planner.finishFreelist();
        }
        if (rc == .ok) {
            self.declared_pages = planner.next_page;
            for (index_payloads.items) |payload| {
                rc = if (unique) self.insertUniqueIndexWithKeyInfo(root_page, payload, column_indices.len, collations, sort_orders) else self.insertIndexWithKeyInfo(root_page, payload, collations, sort_orders);
                if (rc != .ok) break;
            }
        }
        if (rc == .ok and owns_transaction) {
            rc = self.commitMutationBatch();
        }
        if (rc != .ok) {
            if (owns_transaction) {
                _ = self.rollbackMutationBatch();
            }
            return rc;
        }
        return .ok;
    }

    /// Source `sqlite3RefillIndex()` path used by REINDEX. Clear the existing
    /// root and repopulate it with the current key information atomically.
    pub fn refillSchemaIndex(self: *Database, root_page: u32, table_root: u32, column_indices: []const usize, integer_primary_key_position: ?usize, collations: []const IndexCollation, sort_orders: []const IndexSortOrder, transforms: []const IndexTransform, predicate: ?IndexPredicate, unique: bool) ResultCode {
        if (!self.writable) return .read_only;
        if (column_indices.len == 0 or collations.len != column_indices.len or sort_orders.len != column_indices.len or transforms.len != column_indices.len) return .misuse;
        const table_opened = self.openCursor(table_root, .table);
        if (table_opened.result != .ok) return table_opened.result;
        var table_cursor = table_opened.cursor.?;
        defer table_cursor.deinit();
        const cleared = rebuildIndex(self, root_page, &.{});
        if (cleared != .ok) return cleared;
        for (table_cursor.entries.items) |entry| {
            const rowid = entry.rowid orelse return .corrupt;
            const decoded = decodeRecord(self.allocator, entry.payload);
            if (decoded.result != .ok) return decoded.result;
            var record = decoded.record.?;
            defer record.deinit();
            if (predicate) |filter| {
                if (filter.column_index >= record.values.len) return .corrupt;
                const value: Value = if (filter.integer_primary_key) .{ .integer = rowid } else record.values[filter.column_index];
                if (!indexPredicateMatches(filter, value)) continue;
            }
            const key_values = self.allocator.alloc(Value, column_indices.len + 1) catch return .no_memory;
            defer self.allocator.free(key_values);
            for (column_indices, 0..) |column_index, index| {
                if (column_index >= record.values.len) return .corrupt;
                key_values[index] = transformIndexValue(transforms[index], if (integer_primary_key_position == index) .{ .integer = rowid } else record.values[column_index]);
            }
            key_values[column_indices.len] = .{ .integer = rowid };
            const payload = encodeRecord(self.allocator, key_values) catch |err| return if (err == error.OutOfMemory) .no_memory else .too_big;
            defer self.allocator.free(payload);
            const inserted = if (unique) self.insertUniqueIndexWithKeyInfo(root_page, payload, column_indices.len, collations, sort_orders) else self.insertIndexWithKeyInfo(root_page, payload, collations, sort_orders);
            if (inserted != .ok) return inserted;
        }
        return .ok;
    }

    pub fn dropSchemaTable(self: *Database, name: []const u8, if_exists: bool) ResultCode {
        if (!self.writable) return .read_only;
        const opened = self.openCursor(1, .table);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var found: ?usize = null;
        var root_page: u32 = 0;
        var index_positions = std.ArrayList(usize).empty;
        defer index_positions.deinit(self.allocator);
        var index_roots = std.ArrayList(u32).empty;
        defer index_roots.deinit(self.allocator);
        for (cursor.entries.items, 0..) |entry, index| {
            const record = decodeRecord(self.allocator, entry.payload);
            if (record.result != .ok) return record.result;
            var view = record.record.?;
            defer view.deinit();
            if (view.values.len < 4) continue;
            if (schemaTextEqual(view.values[0], "table") and schemaTextEqual(view.values[1], name)) {
                found = index;
                root_page = switch (view.values[3]) {
                    .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else 0,
                    else => 0,
                };
            } else if (schemaTextEqual(view.values[0], "index") and schemaTextEqual(view.values[2], name)) {
                const index_root: u32 = switch (view.values[3]) {
                    .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else return .corrupt,
                    else => return .corrupt,
                };
                index_positions.append(self.allocator, index) catch return .no_memory;
                index_roots.append(self.allocator, index_root) catch return .no_memory;
            }
        }
        const table_position = found orelse return if (if_exists) .ok else .error_;
        if (root_page <= 1 or root_page > self.declared_pages) return .corrupt;
        const owns_transaction = self.mutation_batch_depth == 0;
        var rc: ResultCode = .ok;
        if (owns_transaction) {
            rc = self.pager.beginWrite();
            if (rc != .ok) return rc;
        }
        const planned = RebuildPlanner.init(self, 1, .table);
        if (planned.result != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return planned.result;
        }
        var planner = planned.planner.?;
        defer planner.deinit();
        if (planner.auto_vacuum) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return .error_;
        }
        rc = planner.collectTree(root_page, 0);
        if (rc == .ok) {
            for (index_roots.items) |index_root| {
                rc = planner.collectTreeKind(index_root, 0, .index);
                if (rc != .ok) break;
            }
        }
        if (rc == .ok) {
            var position = cursor.entries.items.len;
            while (position != 0) {
                position -= 1;
                var remove = position == table_position;
                if (!remove) {
                    for (index_positions.items) |index_position| {
                        if (position == index_position) {
                            remove = true;
                            break;
                        }
                    }
                }
                if (remove) {
                    const removed = cursor.entries.orderedRemove(position);
                    self.allocator.free(removed.payload);
                }
            }
            rc = writeTableLeaf(&planner, 1, cursor.entries.items);
        }
        if (rc == .ok) {
            rc = bumpSchemaCookie(&planner);
        }
        if (rc == .ok) {
            rc = planner.finishFreelist();
        }
        if (rc == .ok and owns_transaction) {
            rc = self.pager.commit();
        }
        if (rc != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return rc;
        }
        self.declared_pages = planner.next_page;
        return .ok;
    }

    /// Drop one ordinary application-defined index and reclaim its tree.
    pub fn dropSchemaIndex(self: *Database, name: []const u8, if_exists: bool) ResultCode {
        if (!self.writable) return .read_only;
        const opened = self.openCursor(1, .table);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var found: ?usize = null;
        var root_page: u32 = 0;
        for (cursor.entries.items, 0..) |entry, index| {
            const record = decodeRecord(self.allocator, entry.payload);
            if (record.result != .ok) return record.result;
            var view = record.record.?;
            defer view.deinit();
            if (view.values.len >= 4 and schemaTextEqual(view.values[0], "index") and schemaTextEqual(view.values[1], name)) {
                found = index;
                root_page = switch (view.values[3]) {
                    .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else 0,
                    else => 0,
                };
                break;
            }
        }
        const index_position = found orelse return if (if_exists) .ok else .error_;
        if (root_page <= 1 or root_page > self.declared_pages) return .corrupt;
        const owns_transaction = self.mutation_batch_depth == 0;
        var rc: ResultCode = .ok;
        if (owns_transaction) {
            rc = self.pager.beginWrite();
            if (rc != .ok) return rc;
        }
        const planned = RebuildPlanner.init(self, 1, .table);
        if (planned.result != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return planned.result;
        }
        var planner = planned.planner.?;
        defer planner.deinit();
        if (planner.auto_vacuum) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return .error_;
        }
        rc = planner.collectTreeKind(root_page, 0, .index);
        if (rc == .ok) {
            const removed = cursor.entries.orderedRemove(index_position);
            self.allocator.free(removed.payload);
            rc = writeTableLeaf(&planner, 1, cursor.entries.items);
        }
        if (rc == .ok) {
            rc = bumpSchemaCookie(&planner);
        }
        if (rc == .ok) {
            rc = planner.finishFreelist();
        }
        if (rc == .ok and owns_transaction) {
            rc = self.pager.commit();
        }
        if (rc != .ok) {
            if (owns_transaction) {
                _ = self.pager.rollback();
            }
            return rc;
        }
        self.declared_pages = planner.next_page;
        return .ok;
    }

    pub fn openCursor(self: *Database, root_page: u32, kind: TreeKind) CursorOutcome {
        if (root_page == 0 or root_page > self.declared_pages) return .{ .result = .corrupt };
        var cursor = Cursor{ .allocator = self.allocator, .kind = kind };
        errdefer cursor.deinit();
        const visited = self.allocator.alloc(bool, self.declared_pages + 1) catch
            return .{ .result = .no_memory };
        defer self.allocator.free(visited);
        @memset(visited, false);
        const rc = self.collectPage(&cursor, root_page, kind, visited, 0);
        if (rc != .ok) {
            cursor.deinit();
            return .{ .result = rc };
        }
        return .{ .result = .ok, .cursor = cursor };
    }

    fn collectPage(
        self: *Database,
        cursor: *Cursor,
        page_number: u32,
        expected_kind: TreeKind,
        visited: []bool,
        depth: usize,
    ) ResultCode {
        if (depth >= maximum_depth or page_number == 0 or page_number > self.declared_pages)
            return .corrupt;
        if (visited[page_number]) return .corrupt;
        visited[page_number] = true;

        const fetched = self.pager.getPage(page_number, false);
        if (fetched.result != .ok) return fetched.result;
        const page = fetched.page.?;
        defer _ = self.pager.release(page);
        const info = self.parsePage(page.data, page_number) orelse return .corrupt;
        if (info.kind != expected_kind) return .corrupt;

        for (0..info.cell_count) |index| {
            const pointer = readU16(page.data, info.pointer_offset + index * 2) orelse return .corrupt;
            const cell = self.parseCell(page.data, pointer, info) orelse return .corrupt;
            if (!info.leaf) {
                const child = cell.child orelse return .corrupt;
                const child_rc = self.collectPage(cursor, child, expected_kind, visited, depth + 1);
                if (child_rc != .ok) return child_rc;
            }
            if (info.leaf or expected_kind == .index) {
                const payload = self.readPayload(page.data, cell) catch |err| return switch (err) {
                    error.OutOfMemory => .no_memory,
                    error.TooBig => .too_big,
                    else => .corrupt,
                };
                cursor.entries.append(self.allocator, .{ .rowid = cell.rowid, .payload = payload }) catch {
                    self.allocator.free(payload);
                    return .no_memory;
                };
            }
        }
        if (!info.leaf) {
            if (info.right_child == 0) return .corrupt;
            return self.collectPage(cursor, info.right_child, expected_kind, visited, depth + 1);
        }
        return .ok;
    }

    fn parsePage(self: *const Database, bytes: []const u8, page_number: u32) ?PageInfo {
        const header: usize = if (page_number == 1) 100 else 0;
        if (header + 8 > self.usable_size or self.usable_size > bytes.len) return null;
        const flag = bytes[header];
        const leaf = flag == 10 or flag == 13;
        const kind: TreeKind = switch (flag) {
            5, 13 => .table,
            2, 10 => .index,
            else => return null,
        };
        const header_size: usize = if (leaf) 8 else 12;
        const cell_count = readU16(bytes, header + 3) orelse return null;
        const pointer_offset = header + header_size;
        if (pointer_offset + @as(usize, cell_count) * 2 > self.usable_size) return null;
        const right_child = if (leaf) 0 else readU32(bytes, header + 8) orelse return null;
        const usable = self.usable_size;
        const min_local = ((usable - 12) * 32 / 255) - 23;
        const max_local = if (kind == .table and leaf)
            usable - 35
        else
            ((usable - 12) * 64 / 255) - 23;
        return .{
            .leaf = leaf,
            .kind = kind,
            .cell_count = cell_count,
            .pointer_offset = pointer_offset,
            .right_child = right_child,
            .max_local = max_local,
            .min_local = min_local,
        };
    }

    fn parseCell(self: *const Database, bytes: []const u8, pointer: u16, info: PageInfo) ?Cell {
        var offset: usize = pointer;
        if (offset >= bytes.len) return null;
        var cell = Cell{};
        if (!info.leaf) {
            cell.child = readU32(bytes, offset) orelse return null;
            offset += 4;
        }
        if (info.kind == .table and !info.leaf) {
            const key = readVarint(bytes, offset) orelse return null;
            cell.rowid = @bitCast(key.value);
            return cell;
        }
        const payload = readVarint(bytes, offset) orelse return null;
        if (payload.value > maximum_payload) return null;
        cell.payload_size = @intCast(payload.value);
        offset += payload.length;
        if (info.kind == .table) {
            const key = readVarint(bytes, offset) orelse return null;
            cell.rowid = @bitCast(key.value);
            offset += key.length;
        }
        cell.payload_offset = offset;
        cell.local_size = payloadLocal(cell.payload_size, info.min_local, info.max_local, self.usable_size);
        if (offset + cell.local_size > self.usable_size) return null;
        if (cell.local_size < cell.payload_size) {
            cell.overflow_page = readU32(bytes, offset + cell.local_size) orelse return null;
            if (cell.overflow_page == 0) return null;
        }
        return cell;
    }

    fn readPayload(self: *Database, cell_page: []const u8, cell: Cell) ![]u8 {
        const payload = try self.allocator.alloc(u8, cell.payload_size);
        errdefer self.allocator.free(payload);
        @memcpy(payload[0..cell.local_size], cell_page[cell.payload_offset..][0..cell.local_size]);
        var copied: usize = cell.local_size;
        var next = cell.overflow_page;
        var steps: u32 = 0;
        while (copied < payload.len) {
            if (next == 0 or next > self.declared_pages or steps >= self.declared_pages)
                return error.Corrupt;
            steps += 1;
            const fetched = self.pager.getPage(next, false);
            if (fetched.result == .no_memory) return error.OutOfMemory;
            if (fetched.result == .too_big) return error.TooBig;
            if (fetched.result != .ok) return error.Corrupt;
            const page = fetched.page.?;
            if (page.data.len < self.usable_size or self.usable_size < 4) {
                _ = self.pager.release(page);
                return error.Corrupt;
            }
            const following = readU32(page.data, 0) orelse {
                _ = self.pager.release(page);
                return error.Corrupt;
            };
            const count = @min(payload.len - copied, self.usable_size - 4);
            @memcpy(payload[copied..][0..count], page.data[4..][0..count]);
            copied += count;
            next = following;
            const release_rc = self.pager.release(page);
            if (release_rc != .ok) return error.Corrupt;
        }
        return payload;
    }

    pub fn beginMutationBatch(self: *Database) ResultCode {
        if (self.mutation_batch_depth == 0) {
            const rc = self.pager.beginWrite();
            if (rc != .ok) return rc;
            self.mutation_batch_pages = self.declared_pages;
        }
        self.mutation_batch_depth += 1;
        return .ok;
    }

    /// Source `sqlite3BtreeBeginStmt()`: nest one statement savepoint inside
    /// an explicit transaction, or use the ordinary outer mutation batch.
    pub fn beginStatementBatch(self: *Database) ResultCode {
        if (self.mutation_batch_depth == 0) return self.beginMutationBatch();
        const pages = self.declared_pages;
        self.mutation_batch_depth += 1;
        const opened = self.pager.openSavepoints(1);
        if (opened != .ok) {
            self.mutation_batch_depth -= 1;
            return opened;
        }
        self.statement_batch_pages = pages;
        return .ok;
    }

    pub fn commitStatementBatch(self: *Database) ResultCode {
        if (self.mutation_batch_depth <= 1) return self.commitMutationBatch();
        const released = self.pager.releaseSavepoint(0);
        if (released != .ok) return released;
        self.mutation_batch_depth -= 1;
        return .ok;
    }

    pub fn rollbackStatementBatch(self: *Database) ResultCode {
        if (self.mutation_batch_depth <= 1) return self.rollbackMutationBatch();
        const rolled_back = self.pager.rollbackSavepoint(0);
        if (rolled_back != .ok) return rolled_back;
        const released = self.pager.releaseSavepoint(0);
        if (released != .ok) return released;
        self.mutation_batch_depth -= 1;
        self.declared_pages = self.statement_batch_pages;
        return .ok;
    }

    pub fn commitMutationBatch(self: *Database) ResultCode {
        if (self.mutation_batch_depth == 0) return .misuse;
        self.mutation_batch_depth -= 1;
        if (self.mutation_batch_depth != 0) return .ok;
        const rc = self.pager.commit();
        if (rc != .ok) {
            if (self.pager.state != .reader) {
                _ = self.pager.rollback();
            }
            self.declared_pages = self.mutation_batch_pages;
        }
        return rc;
    }

    pub fn rollbackMutationBatch(self: *Database) ResultCode {
        if (self.mutation_batch_depth == 0) return .ok;
        self.mutation_batch_depth = 0;
        const rc = self.pager.rollback();
        self.declared_pages = self.mutation_batch_pages;
        return rc;
    }

    pub fn nextTableRowid(self: *Database, root_page: u32) struct { result: ResultCode, rowid: i64 = 0 } {
        const opened = self.openCursor(root_page, .table);
        if (opened.result != .ok) return .{ .result = opened.result };
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        if (cursor.entries.items.len == 0) return .{ .result = .ok, .rowid = 1 };
        const last = cursor.entries.items[cursor.entries.items.len - 1].rowid orelse return .{ .result = .corrupt };
        if (last == std.math.maxInt(i64)) return .{ .result = .full };
        return .{ .result = .ok, .rowid = last + 1 };
    }

    /// Insert or replace one raw table record and rebuild its table B-tree in
    /// a single rollback-journal transaction. The caller supplies canonical
    /// SQLite record bytes (the rowid remains the B-tree integer key).
    pub fn insertTable(
        self: *Database,
        root_page: u32,
        rowid: i64,
        payload: []const u8,
        replace: bool,
    ) ResultCode {
        if (!self.writable) return .read_only;
        const opened = self.openCursor(root_page, .table);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var lower: usize = 0;
        while (lower < cursor.entries.items.len and cursor.entries.items[lower].rowid.? < rowid) lower += 1;
        if (lower < cursor.entries.items.len and cursor.entries.items[lower].rowid.? == rowid) {
            if (!replace) return .constraint;
            const copy = self.allocator.dupe(u8, payload) catch return .no_memory;
            self.allocator.free(cursor.entries.items[lower].payload);
            cursor.entries.items[lower].payload = copy;
        } else {
            const copy = self.allocator.dupe(u8, payload) catch return .no_memory;
            cursor.entries.insert(self.allocator, lower, .{ .rowid = rowid, .payload = copy }) catch {
                self.allocator.free(copy);
                return .no_memory;
            };
        }
        return rebuildTable(self, root_page, cursor.entries.items);
    }

    pub fn deleteTable(self: *Database, root_page: u32, rowid: i64) ResultCode {
        if (!self.writable) return .read_only;
        const opened = self.openCursor(root_page, .table);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var lower: usize = 0;
        while (lower < cursor.entries.items.len and cursor.entries.items[lower].rowid.? < rowid) lower += 1;
        if (lower == cursor.entries.items.len or cursor.entries.items[lower].rowid.? != rowid) return .not_found;
        const removed = cursor.entries.orderedRemove(lower);
        self.allocator.free(removed.payload);
        return rebuildTable(self, root_page, cursor.entries.items);
    }

    pub fn insertIndex(self: *Database, root_page: u32, payload: []const u8) ResultCode {
        return self.insertIndexWithCollations(root_page, payload, &.{});
    }

    pub fn insertIndexWithCollations(self: *Database, root_page: u32, payload: []const u8, collations: []const IndexCollation) ResultCode {
        return self.insertIndexWithKeyInfo(root_page, payload, collations, &.{});
    }

    pub fn insertIndexWithKeyInfo(self: *Database, root_page: u32, payload: []const u8, collations: []const IndexCollation, sort_orders: []const IndexSortOrder) ResultCode {
        if (sort_orders.len != 0 and sort_orders.len != collations.len) return .misuse;
        if (!self.writable) return .read_only;
        const opened = self.openCursor(root_page, .index);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        var position: usize = 0;
        while (position < cursor.entries.items.len) : (position += 1) {
            const compared = compareIndexRecordPayloads(self.allocator, cursor.entries.items[position].payload, payload, collations, sort_orders);
            if (compared.result != .ok) return compared.result;
            if (compared.order != .lt) break;
        }
        if (position < cursor.entries.items.len and std.mem.eql(u8, cursor.entries.items[position].payload, payload))
            return .constraint;
        const copy = self.allocator.dupe(u8, payload) catch return .no_memory;
        cursor.entries.insert(self.allocator, position, .{ .rowid = null, .payload = copy }) catch {
            self.allocator.free(copy);
            return .no_memory;
        };
        return rebuildIndex(self, root_page, cursor.entries.items);
    }

    pub fn insertUniqueIndex(self: *Database, root_page: u32, payload: []const u8, key_count: usize) ResultCode {
        return self.insertUniqueIndexWithCollations(root_page, payload, key_count, &.{});
    }

    pub fn insertUniqueIndexWithCollations(self: *Database, root_page: u32, payload: []const u8, key_count: usize, collations: []const IndexCollation) ResultCode {
        return self.insertUniqueIndexWithKeyInfo(root_page, payload, key_count, collations, &.{});
    }

    pub fn insertUniqueIndexWithKeyInfo(self: *Database, root_page: u32, payload: []const u8, key_count: usize, collations: []const IndexCollation, sort_orders: []const IndexSortOrder) ResultCode {
        if (collations.len != 0 and collations.len != key_count) return .misuse;
        if (sort_orders.len != 0 and sort_orders.len != key_count) return .misuse;
        const candidate_outcome = decodeRecord(self.allocator, payload);
        if (candidate_outcome.result != .ok) return candidate_outcome.result;
        var candidate = candidate_outcome.record.?;
        defer candidate.deinit();
        if (key_count == 0 or candidate.values.len <= key_count) return .corrupt;
        for (candidate.values[0..key_count]) |value| {
            if (value == .null_) return self.insertIndexWithKeyInfo(root_page, payload, collations, sort_orders);
        }
        const opened = self.openCursor(root_page, .index);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        for (cursor.entries.items) |entry| {
            const existing_outcome = decodeRecord(self.allocator, entry.payload);
            if (existing_outcome.result != .ok) return existing_outcome.result;
            var existing = existing_outcome.record.?;
            defer existing.deinit();
            if (existing.values.len <= key_count) return .corrupt;
            var matches = true;
            for (existing.values[0..key_count], candidate.values[0..key_count], 0..) |left, right, index| {
                const collation: IndexCollation = if (collations.len == 0) .binary else collations[index];
                if (!indexValueEqual(left, right, collation)) {
                    matches = false;
                    break;
                }
            }
            if (matches) return .constraint;
        }
        return self.insertIndexWithKeyInfo(root_page, payload, collations, sort_orders);
    }

    pub fn deleteIndex(self: *Database, root_page: u32, payload: []const u8) ResultCode {
        if (!self.writable) return .read_only;
        const opened = self.openCursor(root_page, .index);
        if (opened.result != .ok) return opened.result;
        var cursor = opened.cursor.?;
        defer cursor.deinit();
        for (cursor.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.payload, payload)) continue;
            const removed = cursor.entries.orderedRemove(index);
            self.allocator.free(removed.payload);
            return rebuildIndex(self, root_page, cursor.entries.items);
        }
        return .not_found;
    }
};

fn rtrimIndexText(value: []const u8) []const u8 {
    var end = value.len;
    while (end != 0 and value[end - 1] == ' ') end -= 1;
    return value[0..end];
}

fn compareIndexText(left: []const u8, right: []const u8, collation: IndexCollation) std.math.Order {
    return switch (collation) {
        .binary => std.mem.order(u8, left, right),
        .rtrim => std.mem.order(u8, rtrimIndexText(left), rtrimIndexText(right)),
        .nocase => blk: {
            const count = @min(left.len, right.len);
            for (left[0..count], right[0..count]) |left_byte, right_byte| {
                const folded_left = std.ascii.toLower(left_byte);
                const folded_right = std.ascii.toLower(right_byte);
                if (folded_left < folded_right) break :blk .lt;
                if (folded_left > folded_right) break :blk .gt;
            }
            break :blk std.math.order(left.len, right.len);
        },
        .custom => |custom| blk: {
            const result = custom.callback(custom.context, @intCast(left.len), left.ptr, @intCast(right.len), right.ptr);
            break :blk if (result < 0) .lt else if (result > 0) .gt else .eq;
        },
    };
}

fn compareIndexValues(left: Value, right: Value, collation: IndexCollation) std.math.Order {
    return switch (left) {
        .text => |left_text| switch (right) {
            .text => |right_text| compareIndexText(left_text, right_text, collation),
            else => compareValues(left, right),
        },
        else => compareValues(left, right),
    };
}

fn indexValueEqual(left: Value, right: Value, collation: IndexCollation) bool {
    return compareIndexValues(left, right, collation) == .eq;
}

fn compareIndexRecordPayloads(allocator: std.mem.Allocator, left_payload: []const u8, right_payload: []const u8, collations: []const IndexCollation, sort_orders: []const IndexSortOrder) CompareOutcome {
    const left_outcome = decodeRecord(allocator, left_payload);
    if (left_outcome.result != .ok) return .{ .result = left_outcome.result };
    var left = left_outcome.record.?;
    defer left.deinit();
    const right_outcome = decodeRecord(allocator, right_payload);
    if (right_outcome.result != .ok) return .{ .result = right_outcome.result };
    var right = right_outcome.record.?;
    defer right.deinit();
    const count = @min(left.values.len, right.values.len);
    for (left.values[0..count], right.values[0..count], 0..) |left_value, right_value, index| {
        const collation: IndexCollation = if (index < collations.len) collations[index] else .binary;
        var order = compareIndexValues(left_value, right_value, collation);
        if (index < sort_orders.len and sort_orders[index] == .descending) {
            order = switch (order) {
                .lt => .gt,
                .eq => .eq,
                .gt => .lt,
            };
        }
        if (order != .eq) return .{ .result = .ok, .order = order };
    }
    return .{ .result = .ok, .order = std.math.order(left.values.len, right.values.len) };
}

fn schemaTextEqual(value: Value, expected: []const u8) bool {
    const text = switch (value) {
        .text => |bytes| bytes,
        else => return false,
    };
    return std.ascii.eqlIgnoreCase(text, expected);
}

fn encodeSchemaRecord(allocator: std.mem.Allocator, object_type: []const u8, name: []const u8, table_name: []const u8, root_page: u32, sql: []const u8) ![]u8 {
    const fields = [_][]const u8{ object_type, name, table_name, sql };
    const serials = [_]u64{ 13 + 2 * fields[0].len, 13 + 2 * fields[1].len, 13 + 2 * fields[2].len, 6, 13 + 2 * fields[3].len };
    var header_body: usize = 0;
    for (serials) |serial| {
        header_body += varintLength(serial);
    }
    var header_size = header_body + 1;
    while (varintLength(header_size) + header_body != header_size) {
        header_size = varintLength(header_size) + header_body;
    }
    const payload_size = fields[0].len + fields[1].len + fields[2].len + 8 + fields[3].len;
    if (header_size + payload_size > maximum_payload) return error.TooBig;
    const output = try allocator.alloc(u8, header_size + payload_size);
    var offset = writeVarint(output, header_size);
    for (serials) |serial| offset += writeVarint(output[offset..], serial);
    std.debug.assert(offset == header_size);
    @memcpy(output[offset..][0..fields[0].len], fields[0]);
    offset += fields[0].len;
    @memcpy(output[offset..][0..fields[1].len], fields[1]);
    offset += fields[1].len;
    @memcpy(output[offset..][0..fields[2].len], fields[2]);
    offset += fields[2].len;
    for (0..8) |index| output[offset + index] = @truncate(@as(u64, root_page) >> @intCast((7 - index) * 8));
    offset += 8;
    @memcpy(output[offset..][0..fields[3].len], fields[3]);
    return output;
}

fn bumpSchemaCookie(planner: *RebuildPlanner) ResultCode {
    const fetched = planner.writablePage(1, false);
    if (fetched.result != .ok) return fetched.result;
    const page = fetched.page.?;
    const cookie = readU32(page.data, 40) orelse {
        _ = planner.database.pager.release(page);
        return .corrupt;
    };
    writeU32(page.data, 40, cookie +% 1);
    return planner.database.pager.release(page);
}

const PageAllocation = struct { result: ResultCode, page: u32 = 0 };
const PlannerOutcome = struct { result: ResultCode, planner: ?RebuildPlanner = null };

const RebuildPlanner = struct {
    database: *Database,
    root_page: u32,
    kind: TreeKind,
    available: std.ArrayList(u32) = .empty,
    seen: std.AutoHashMap(u32, void),
    next_page: u32,
    auto_vacuum: bool = false,

    fn init(database: *Database, root_page: u32, kind: TreeKind) PlannerOutcome {
        var planner = RebuildPlanner{
            .database = database,
            .root_page = root_page,
            .kind = kind,
            .seen = std.AutoHashMap(u32, void).init(database.allocator),
            .next_page = database.declared_pages,
        };
        const free_rc = planner.collectFreelist();
        if (free_rc != .ok) {
            planner.deinit();
            return .{ .result = free_rc };
        }
        const old_rc = planner.collectTree(root_page, 0);
        if (old_rc != .ok) {
            planner.deinit();
            return .{ .result = old_rc };
        }
        std.mem.sort(u32, planner.available.items, {}, struct {
            fn before(_: void, left: u32, right: u32) bool {
                return left > right;
            }
        }.before);
        return .{ .result = .ok, .planner = planner };
    }

    fn deinit(self: *RebuildPlanner) void {
        self.available.deinit(self.database.allocator);
        self.seen.deinit();
    }

    fn offer(self: *RebuildPlanner, page_number: u32) ResultCode {
        if (page_number == 0 or page_number > self.database.declared_pages or page_number == self.root_page)
            return .corrupt;
        const slot = self.seen.getOrPut(page_number) catch return .no_memory;
        if (!slot.found_existing) self.available.append(self.database.allocator, page_number) catch return .no_memory;
        return .ok;
    }

    fn collectFreelist(self: *RebuildPlanner) ResultCode {
        const first = self.database.pager.getPage(1, false);
        if (first.result != .ok) return first.result;
        const header = first.page.?;
        const trunk_start = readU32(header.data, 32) orelse 0;
        const expected_count = readU32(header.data, 36) orelse 0;
        self.auto_vacuum = (readU32(header.data, 52) orelse 0) != 0;
        _ = self.database.pager.release(header);
        var trunk = trunk_start;
        var count: u32 = 0;
        while (trunk != 0) {
            if (count >= self.database.declared_pages) return .corrupt;
            const fetched = self.database.pager.getPage(trunk, false);
            if (fetched.result != .ok) return fetched.result;
            const page = fetched.page.?;
            const next = readU32(page.data, 0) orelse {
                _ = self.database.pager.release(page);
                return .corrupt;
            };
            const leaves = readU32(page.data, 4) orelse {
                _ = self.database.pager.release(page);
                return .corrupt;
            };
            if (leaves > (self.database.usable_size / 4) - 2) {
                _ = self.database.pager.release(page);
                return .corrupt;
            }
            var rc = self.offer(trunk);
            if (rc == .ok) count += 1;
            for (0..leaves) |index| {
                if (rc != .ok) break;
                const leaf = readU32(page.data, 8 + index * 4) orelse {
                    rc = .corrupt;
                    break;
                };
                rc = self.offer(leaf);
                if (rc == .ok) count += 1;
            }
            _ = self.database.pager.release(page);
            if (rc != .ok) return rc;
            trunk = next;
        }
        return if (count == expected_count) .ok else .corrupt;
    }

    fn collectOverflow(self: *RebuildPlanner, start: u32) ResultCode {
        var page_number = start;
        var steps: u32 = 0;
        while (page_number != 0) {
            if (steps >= self.database.declared_pages) return .corrupt;
            steps += 1;
            const fetched = self.database.pager.getPage(page_number, false);
            if (fetched.result != .ok) return fetched.result;
            const page = fetched.page.?;
            const next = readU32(page.data, 0) orelse {
                _ = self.database.pager.release(page);
                return .corrupt;
            };
            _ = self.database.pager.release(page);
            const rc = self.offer(page_number);
            if (rc != .ok) return rc;
            page_number = next;
        }
        return .ok;
    }

    fn collectTree(self: *RebuildPlanner, page_number: u32, depth: usize) ResultCode {
        return self.collectTreeKind(page_number, depth, self.kind);
    }

    fn collectTreeKind(self: *RebuildPlanner, page_number: u32, depth: usize, expected_kind: TreeKind) ResultCode {
        if (depth >= maximum_depth) return .corrupt;
        const fetched = self.database.pager.getPage(page_number, false);
        if (fetched.result != .ok) return fetched.result;
        const page = fetched.page.?;
        const info = self.database.parsePage(page.data, page_number) orelse {
            _ = self.database.pager.release(page);
            return .corrupt;
        };
        if (info.kind != expected_kind) {
            _ = self.database.pager.release(page);
            return .misuse;
        }
        var children = std.ArrayList(u32).empty;
        defer children.deinit(self.database.allocator);
        var rc: ResultCode = .ok;
        for (0..info.cell_count) |index| {
            const pointer = readU16(page.data, info.pointer_offset + index * 2) orelse {
                rc = .corrupt;
                break;
            };
            const cell = self.database.parseCell(page.data, pointer, info) orelse {
                rc = .corrupt;
                break;
            };
            if (cell.overflow_page != 0) {
                rc = self.collectOverflow(cell.overflow_page);
                if (rc != .ok) break;
            }
            if (cell.child) |child| children.append(self.database.allocator, child) catch {
                rc = .no_memory;
                break;
            };
        }
        if (rc == .ok and !info.leaf) {
            children.append(self.database.allocator, info.right_child) catch {
                rc = .no_memory;
            };
        }
        _ = self.database.pager.release(page);
        if (rc != .ok) return rc;
        if (page_number != self.root_page) {
            rc = self.offer(page_number);
            if (rc != .ok) return rc;
        }
        for (children.items) |child| {
            rc = self.collectTreeKind(child, depth + 1, expected_kind);
            if (rc != .ok) return rc;
        }
        return .ok;
    }

    fn ptrmapPage(self: *const RebuildPlanner, key: u32) u32 {
        const per_map = self.database.usable_size / 5 + 1;
        var result = ((key - 2) / per_map) * per_map + 2;
        const locking_page: u32 = @intCast(pager_module.pending_byte / self.database.pager.page_size + 1);
        if (result == locking_page) result += 1;
        return result;
    }

    fn isPtrmapPage(self: *const RebuildPlanner, page_number: u32) bool {
        return self.auto_vacuum and page_number >= 2 and self.ptrmapPage(page_number + 1) == page_number;
    }

    fn ptrmapPut(self: *RebuildPlanner, key: u32, kind: u8, parent: u32) ResultCode {
        if (!self.auto_vacuum or key < 3 or self.isPtrmapPage(key)) return .ok;
        const map_page = self.ptrmapPage(key);
        const offset: usize = @as(usize, key - map_page - 1) * 5;
        if (offset + 5 > self.database.usable_size) return .corrupt;
        const fetched = self.writablePage(map_page, false);
        if (fetched.result != .ok) return fetched.result;
        const page = fetched.page.?;
        page.data[offset] = kind;
        writeU32(page.data, offset + 1, parent);
        return self.database.pager.release(page);
    }

    fn allocate(self: *RebuildPlanner) PageAllocation {
        if (self.available.pop()) |page_number| return .{ .result = .ok, .page = page_number };
        while (true) {
            if (self.next_page >= pager_module.maximum_page_count) return .{ .result = .full };
            self.next_page += 1;
            const locking_page: u32 = @intCast(pager_module.pending_byte / self.database.pager.page_size + 1);
            if (self.next_page == locking_page or self.isPtrmapPage(self.next_page)) continue;
            return .{ .result = .ok, .page = self.next_page };
        }
    }

    fn writablePage(self: *RebuildPlanner, page_number: u32, clear: bool) pager_module.PageOutcome {
        const existing = page_number <= self.database.declared_pages;
        const fetched = self.database.pager.getPage(page_number, !existing);
        if (fetched.result != .ok) return fetched;
        const rc = self.database.pager.makeWritable(fetched.page.?);
        if (rc != .ok) {
            _ = self.database.pager.release(fetched.page.?);
            return .{ .result = rc };
        }
        if (clear) @memset(fetched.page.?.data, 0);
        fetched.page.?.extra[0] = 1;
        return fetched;
    }

    fn finishFreelist(self: *RebuildPlanner) ResultCode {
        const capacity: usize = self.database.usable_size / 4 - 2;
        var cursor: usize = 0;
        while (cursor < self.available.items.len) {
            const trunk_index = cursor;
            cursor += 1;
            const leaf_count = @min(capacity, self.available.items.len - cursor);
            const next_index = cursor + leaf_count;
            const next_trunk: u32 = if (next_index < self.available.items.len) self.available.items[next_index] else 0;
            const fetched = self.writablePage(self.available.items[trunk_index], true);
            if (fetched.result != .ok) return fetched.result;
            const page = fetched.page.?;
            writeU32(page.data, 0, next_trunk);
            writeU32(page.data, 4, @intCast(leaf_count));
            for (0..leaf_count) |index| {
                writeU32(page.data, 8 + index * 4, self.available.items[cursor + index]);
            }
            const rc = self.database.pager.release(page);
            if (rc != .ok) return rc;
            cursor = next_index;
        }
        if (self.auto_vacuum) {
            for (self.available.items) |page_number| {
                const map_rc = self.ptrmapPut(page_number, 2, 0);
                if (map_rc != .ok) return map_rc;
            }
            const root_rc = self.ptrmapPut(self.root_page, 1, 0);
            if (root_rc != .ok) return root_rc;
        }
        const first = self.writablePage(1, false);
        if (first.result != .ok) return first.result;
        const page = first.page.?;
        writeU32(page.data, 28, self.next_page);
        writeU32(page.data, 32, if (self.available.items.len == 0) 0 else self.available.items[0]);
        writeU32(page.data, 36, @intCast(self.available.items.len));
        return self.database.pager.release(page);
    }
};

const TableNode = struct { page: u32, maximum_key: i64 };

fn varintLength(value: u64) usize {
    if (value > 0x00ff_ffff_ffff_ffff) return 9;
    var length: usize = 1;
    var remaining = value;
    while (remaining > 0x7f) : (remaining >>= 7) length += 1;
    return length;
}

fn writeVarint(output: []u8, value: u64) usize {
    const length = varintLength(value);
    if (length == 9) {
        output[8] = @truncate(value);
        var shifted = value >> 8;
        var index: usize = 8;
        while (index > 0) {
            index -= 1;
            output[index] = @truncate((shifted & 0x7f) | 0x80);
            shifted >>= 7;
        }
        return 9;
    }
    var shifted = value;
    var index = length;
    while (index > 0) {
        index -= 1;
        output[index] = @truncate(shifted & 0x7f);
        if (index + 1 < length) output[index] |= 0x80;
        shifted >>= 7;
    }
    return length;
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}

fn tableLeafCellSize(database: *const Database, entry: Entry) usize {
    const usable = database.usable_size;
    const min_local = ((usable - 12) * 32 / 255) - 23;
    const max_local = usable - 35;
    const payload_size: u32 = @intCast(entry.payload.len);
    const local = payloadLocal(payload_size, min_local, max_local, usable);
    return varintLength(payload_size) + varintLength(@bitCast(entry.rowid.?)) + local + @as(usize, @intFromBool(local < payload_size)) * 4;
}

fn entriesFitLeaf(database: *const Database, entries: []const Entry, header_offset: usize) bool {
    var used: usize = header_offset + 8;
    for (entries) |entry| used += 2 + tableLeafCellSize(database, entry);
    return used <= database.usable_size;
}

fn writeOverflow(planner: *RebuildPlanner, payload: []const u8, owner_page: u32) struct { result: ResultCode, first: u32 = 0 } {
    if (payload.len == 0) return .{ .result = .ok };
    const chunk_size: usize = planner.database.usable_size - 4;
    const count = (payload.len + chunk_size - 1) / chunk_size;
    const pages = planner.database.allocator.alloc(u32, count) catch return .{ .result = .no_memory };
    defer planner.database.allocator.free(pages);
    for (pages) |*page_number| {
        const allocated = planner.allocate();
        if (allocated.result != .ok) return .{ .result = allocated.result };
        page_number.* = allocated.page;
    }
    var copied: usize = 0;
    for (pages, 0..) |page_number, index| {
        const fetched = planner.writablePage(page_number, true);
        if (fetched.result != .ok) return .{ .result = fetched.result };
        const page = fetched.page.?;
        writeU32(page.data, 0, if (index + 1 < pages.len) pages[index + 1] else 0);
        const amount = @min(chunk_size, payload.len - copied);
        @memcpy(page.data[4..][0..amount], payload[copied..][0..amount]);
        copied += amount;
        var rc = planner.database.pager.release(page);
        if (rc == .ok) rc = planner.ptrmapPut(page_number, if (index == 0) 3 else 4, if (index == 0) owner_page else pages[index - 1]);
        if (rc != .ok) return .{ .result = rc };
    }
    return .{ .result = .ok, .first = pages[0] };
}

fn writeTableLeaf(planner: *RebuildPlanner, page_number: u32, entries: []const Entry) ResultCode {
    const fetched = planner.writablePage(page_number, page_number != 1);
    if (fetched.result != .ok) return fetched.result;
    const page = fetched.page.?;
    const header: usize = if (page_number == 1) 100 else 0;
    if (page_number == 1) @memset(page.data[100..], 0);
    page.data[header] = 13;
    writeU16(page.data, header + 1, 0);
    writeU16(page.data, header + 3, @intCast(entries.len));
    page.data[header + 7] = 0;
    const usable = planner.database.usable_size;
    const min_local = ((usable - 12) * 32 / 255) - 23;
    const max_local = usable - 35;
    var content: usize = usable;
    var rc: ResultCode = .ok;
    var reverse = entries.len;
    while (reverse > 0) {
        reverse -= 1;
        const entry = entries[reverse];
        const payload_size: u32 = @intCast(entry.payload.len);
        const local: usize = payloadLocal(payload_size, min_local, max_local, usable);
        const size = tableLeafCellSize(planner.database, entry);
        content -= size;
        var offset = content;
        offset += writeVarint(page.data[offset..], payload_size);
        offset += writeVarint(page.data[offset..], @bitCast(entry.rowid.?));
        @memcpy(page.data[offset..][0..local], entry.payload[0..local]);
        offset += local;
        if (local < entry.payload.len) {
            const overflow = writeOverflow(planner, entry.payload[local..], page_number);
            if (overflow.result != .ok) {
                rc = overflow.result;
                break;
            }
            writeU32(page.data, offset, overflow.first);
        }
        writeU16(page.data, header + 8 + reverse * 2, if (content == 65_536) 0 else @intCast(content));
    }
    if (rc == .ok) writeU16(page.data, header + 5, if (content == 65_536) 0 else @intCast(content));
    const release_rc = planner.database.pager.release(page);
    return if (rc != .ok) rc else release_rc;
}

fn interiorFits(database: *const Database, children: []const TableNode, header_offset: usize) bool {
    if (children.len == 0) return false;
    var used: usize = header_offset + 12;
    for (children[0 .. children.len - 1]) |child| used += 2 + 4 + varintLength(@bitCast(child.maximum_key));
    return used <= database.usable_size;
}

fn writeTableInterior(planner: *RebuildPlanner, page_number: u32, children: []const TableNode) ResultCode {
    if (children.len < 2) return .corrupt;
    const fetched = planner.writablePage(page_number, page_number != 1);
    if (fetched.result != .ok) return fetched.result;
    const page = fetched.page.?;
    const header: usize = if (page_number == 1) 100 else 0;
    if (page_number == 1) @memset(page.data[100..], 0);
    page.data[header] = 5;
    writeU16(page.data, header + 1, 0);
    writeU16(page.data, header + 3, @intCast(children.len - 1));
    page.data[header + 7] = 0;
    writeU32(page.data, header + 8, children[children.len - 1].page);
    var content: usize = planner.database.usable_size;
    var reverse = children.len - 1;
    while (reverse > 0) {
        reverse -= 1;
        const child = children[reverse];
        const size = 4 + varintLength(@bitCast(child.maximum_key));
        content -= size;
        writeU32(page.data, content, child.page);
        _ = writeVarint(page.data[content + 4 ..], @bitCast(child.maximum_key));
        writeU16(page.data, header + 12 + reverse * 2, if (content == 65_536) 0 else @intCast(content));
    }
    writeU16(page.data, header + 5, if (content == 65_536) 0 else @intCast(content));
    var rc: ResultCode = .ok;
    for (children) |child| {
        rc = planner.ptrmapPut(child.page, 5, page_number);
        if (rc != .ok) break;
    }
    const release_rc = planner.database.pager.release(page);
    return if (rc != .ok) rc else release_rc;
}

fn rebuildTable(database: *Database, root_page: u32, entries: []const Entry) ResultCode {
    if (root_page == 1) return .misuse;
    const owns_transaction = database.mutation_batch_depth == 0;
    var rc: ResultCode = .ok;
    if (owns_transaction) {
        rc = database.pager.beginWrite();
        if (rc != .ok) return rc;
    }
    const planned = RebuildPlanner.init(database, root_page, .table);
    if (planned.result != .ok) {
        if (owns_transaction) {
            _ = database.pager.rollback();
        }
        return planned.result;
    }
    var planner = planned.planner.?;
    defer planner.deinit();

    if (entriesFitLeaf(database, entries, 0)) {
        rc = writeTableLeaf(&planner, root_page, entries);
    } else {
        var leaves = std.ArrayList(TableNode).empty;
        defer leaves.deinit(database.allocator);
        var start: usize = 0;
        while (start < entries.len and rc == .ok) {
            var end = start + 1;
            while (end <= entries.len and entriesFitLeaf(database, entries[start..end], 0)) end += 1;
            end -= 1;
            if (end == start) {
                rc = .too_big;
                break;
            }
            const allocated = planner.allocate();
            if (allocated.result != .ok) {
                rc = allocated.result;
                break;
            }
            rc = writeTableLeaf(&planner, allocated.page, entries[start..end]);
            if (rc == .ok) {
                leaves.append(database.allocator, .{
                    .page = allocated.page,
                    .maximum_key = entries[end - 1].rowid.?,
                }) catch {
                    rc = .no_memory;
                };
            }
            start = end;
        }
        var level = leaves;
        leaves = .empty;
        defer level.deinit(database.allocator);
        var depth: usize = 1;
        while (rc == .ok and !interiorFits(database, level.items, 0)) {
            if (depth >= maximum_depth) {
                rc = .corrupt;
                break;
            }
            depth += 1;
            var parents = std.ArrayList(TableNode).empty;
            var child_start: usize = 0;
            while (child_start < level.items.len and rc == .ok) {
                if (level.items.len - child_start < 2) {
                    rc = .corrupt;
                    break;
                }
                var child_end = child_start + 2;
                while (child_end <= level.items.len and interiorFits(database, level.items[child_start..child_end], 0)) {
                    child_end += 1;
                }
                child_end -= 1;
                if (level.items.len - child_end == 1 and child_end - child_start > 2) child_end -= 1;
                const allocated = planner.allocate();
                if (allocated.result != .ok) {
                    rc = allocated.result;
                    break;
                }
                rc = writeTableInterior(&planner, allocated.page, level.items[child_start..child_end]);
                if (rc == .ok) {
                    parents.append(database.allocator, .{
                        .page = allocated.page,
                        .maximum_key = level.items[child_end - 1].maximum_key,
                    }) catch {
                        rc = .no_memory;
                    };
                }
                child_start = child_end;
            }
            if (rc != .ok) {
                parents.deinit(database.allocator);
                break;
            }
            level.deinit(database.allocator);
            level = parents;
        }
        if (rc == .ok) rc = writeTableInterior(&planner, root_page, level.items);
    }
    if (rc == .ok) rc = planner.finishFreelist();
    if (rc == .ok and owns_transaction) {
        rc = database.pager.commit();
    }
    if (rc != .ok) {
        if (owns_transaction and database.pager.state != .reader) {
            _ = database.pager.rollback();
        }
        return rc;
    }
    database.declared_pages = planner.next_page;
    return .ok;
}

fn indexCellSize(database: *const Database, entry: Entry, interior: bool) usize {
    const usable = database.usable_size;
    const min_local = ((usable - 12) * 32 / 255) - 23;
    const max_local = ((usable - 12) * 64 / 255) - 23;
    const payload_size: u32 = @intCast(entry.payload.len);
    const local = payloadLocal(payload_size, min_local, max_local, usable);
    return @as(usize, @intFromBool(interior)) * 4 + varintLength(payload_size) + local +
        @as(usize, @intFromBool(local < payload_size)) * 4;
}

fn indexEntriesFit(database: *const Database, entries: []const Entry, interior: bool) bool {
    var used: usize = if (interior) 12 else 8;
    for (entries) |entry| used += 2 + indexCellSize(database, entry, interior);
    return used <= database.usable_size;
}

fn writeIndexLeaf(planner: *RebuildPlanner, page_number: u32, entries: []const Entry) ResultCode {
    const fetched = planner.writablePage(page_number, true);
    if (fetched.result != .ok) return fetched.result;
    const page = fetched.page.?;
    const header: usize = if (page_number == 1) 100 else 0;
    page.data[header] = 10;
    writeU16(page.data, header + 3, @intCast(entries.len));
    const usable = planner.database.usable_size;
    const min_local = ((usable - 12) * 32 / 255) - 23;
    const max_local = ((usable - 12) * 64 / 255) - 23;
    var content: usize = usable;
    var rc: ResultCode = .ok;
    var reverse = entries.len;
    while (reverse > 0) {
        reverse -= 1;
        const entry = entries[reverse];
        const payload_size: u32 = @intCast(entry.payload.len);
        const local: usize = payloadLocal(payload_size, min_local, max_local, usable);
        content -= indexCellSize(planner.database, entry, false);
        var offset = content;
        offset += writeVarint(page.data[offset..], payload_size);
        @memcpy(page.data[offset..][0..local], entry.payload[0..local]);
        offset += local;
        if (local < entry.payload.len) {
            const overflow = writeOverflow(planner, entry.payload[local..], page_number);
            if (overflow.result != .ok) {
                rc = overflow.result;
                break;
            }
            writeU32(page.data, offset, overflow.first);
        }
        writeU16(page.data, header + 8 + reverse * 2, if (content == 65_536) 0 else @intCast(content));
    }
    if (rc == .ok) writeU16(page.data, header + 5, if (content == 65_536) 0 else @intCast(content));
    const release_rc = planner.database.pager.release(page);
    return if (rc != .ok) rc else release_rc;
}

fn writeIndexInterior(
    planner: *RebuildPlanner,
    page_number: u32,
    separators: []const Entry,
    children: []const u32,
) ResultCode {
    if (children.len != separators.len + 1) return .corrupt;
    const fetched = planner.writablePage(page_number, true);
    if (fetched.result != .ok) return fetched.result;
    const page = fetched.page.?;
    const header: usize = if (page_number == 1) 100 else 0;
    page.data[header] = 2;
    writeU16(page.data, header + 3, @intCast(separators.len));
    writeU32(page.data, header + 8, children[children.len - 1]);
    const usable = planner.database.usable_size;
    const min_local = ((usable - 12) * 32 / 255) - 23;
    const max_local = ((usable - 12) * 64 / 255) - 23;
    var content: usize = usable;
    var rc: ResultCode = .ok;
    var reverse = separators.len;
    while (reverse > 0) {
        reverse -= 1;
        const entry = separators[reverse];
        const payload_size: u32 = @intCast(entry.payload.len);
        const local: usize = payloadLocal(payload_size, min_local, max_local, usable);
        content -= indexCellSize(planner.database, entry, true);
        writeU32(page.data, content, children[reverse]);
        var offset = content + 4;
        offset += writeVarint(page.data[offset..], payload_size);
        @memcpy(page.data[offset..][0..local], entry.payload[0..local]);
        offset += local;
        if (local < entry.payload.len) {
            const overflow = writeOverflow(planner, entry.payload[local..], page_number);
            if (overflow.result != .ok) {
                rc = overflow.result;
                break;
            }
            writeU32(page.data, offset, overflow.first);
        }
        writeU16(page.data, header + 12 + reverse * 2, if (content == 65_536) 0 else @intCast(content));
    }
    if (rc == .ok) {
        writeU16(page.data, header + 5, if (content == 65_536) 0 else @intCast(content));
        for (children) |child| {
            rc = planner.ptrmapPut(child, 5, page_number);
            if (rc != .ok) break;
        }
    }
    const release_rc = planner.database.pager.release(page);
    return if (rc != .ok) rc else release_rc;
}

fn rebuildIndex(database: *Database, root_page: u32, entries: []const Entry) ResultCode {
    if (root_page == 1) return .misuse;
    const owns_transaction = database.mutation_batch_depth == 0;
    var rc: ResultCode = .ok;
    if (owns_transaction) {
        rc = database.pager.beginWrite();
        if (rc != .ok) return rc;
    }
    const planned = RebuildPlanner.init(database, root_page, .index);
    if (planned.result != .ok) {
        if (owns_transaction) {
            _ = database.pager.rollback();
        }
        return planned.result;
    }
    var planner = planned.planner.?;
    defer planner.deinit();
    if (indexEntriesFit(database, entries, false)) {
        rc = writeIndexLeaf(&planner, root_page, entries);
    } else {
        var child_pages = std.ArrayList(u32).empty;
        defer child_pages.deinit(database.allocator);
        var separators = std.ArrayList(Entry).empty;
        defer separators.deinit(database.allocator);
        var start: usize = 0;
        while (start < entries.len and rc == .ok) {
            var end = start + 1;
            while (end <= entries.len and indexEntriesFit(database, entries[start..end], false)) end += 1;
            end -= 1;
            if (end == start) {
                rc = .too_big;
                break;
            }
            if (entries.len - end == 1 and end - start > 1) end -= 1;
            const allocated = planner.allocate();
            if (allocated.result != .ok) {
                rc = allocated.result;
                break;
            }
            rc = writeIndexLeaf(&planner, allocated.page, entries[start..end]);
            if (rc == .ok) {
                child_pages.append(database.allocator, allocated.page) catch {
                    rc = .no_memory;
                };
            }
            if (rc != .ok or end == entries.len) break;
            separators.append(database.allocator, entries[end]) catch {
                rc = .no_memory;
                break;
            };
            start = end + 1;
        }
        if (rc == .ok and child_pages.items.len != separators.items.len + 1) rc = .corrupt;
        var depth: usize = 1;
        while (rc == .ok and !indexEntriesFit(database, separators.items, true)) {
            if (depth >= maximum_depth) {
                rc = .corrupt;
                break;
            }
            depth += 1;
            var parent_pages = std.ArrayList(u32).empty;
            var promoted = std.ArrayList(Entry).empty;
            var child_start: usize = 0;
            while (child_start < child_pages.items.len and rc == .ok) {
                if (child_pages.items.len - child_start < 2) {
                    rc = .corrupt;
                    break;
                }
                var child_end = child_start + 2;
                while (child_end <= child_pages.items.len and
                    indexEntriesFit(database, separators.items[child_start .. child_end - 1], true))
                    child_end += 1;
                child_end -= 1;
                if (child_pages.items.len - child_end == 1 and child_end - child_start > 2) child_end -= 1;
                const allocated = planner.allocate();
                if (allocated.result != .ok) {
                    rc = allocated.result;
                    break;
                }
                rc = writeIndexInterior(
                    &planner,
                    allocated.page,
                    separators.items[child_start .. child_end - 1],
                    child_pages.items[child_start..child_end],
                );
                if (rc == .ok) {
                    parent_pages.append(database.allocator, allocated.page) catch {
                        rc = .no_memory;
                    };
                }
                if (rc == .ok and child_end < child_pages.items.len) {
                    promoted.append(database.allocator, separators.items[child_end - 1]) catch {
                        rc = .no_memory;
                    };
                }
                child_start = child_end;
            }
            if (rc != .ok) {
                parent_pages.deinit(database.allocator);
                promoted.deinit(database.allocator);
                break;
            }
            child_pages.deinit(database.allocator);
            separators.deinit(database.allocator);
            child_pages = parent_pages;
            separators = promoted;
        }
        if (rc == .ok) {
            rc = writeIndexInterior(&planner, root_page, separators.items, child_pages.items);
        }
    }
    if (rc == .ok) {
        rc = planner.finishFreelist();
    }
    if (rc == .ok and owns_transaction) {
        rc = database.pager.commit();
    }
    if (rc != .ok) {
        if (owns_transaction and database.pager.state != .reader) {
            _ = database.pager.rollback();
        }
        return rc;
    }
    database.declared_pages = planner.next_page;
    return .ok;
}

fn payloadLocal(payload_size: u32, min_local: u32, max_local: u32, usable_size: u32) u32 {
    if (payload_size <= max_local) return payload_size;
    const surplus = min_local + (payload_size - min_local) % (usable_size - 4);
    return if (surplus <= max_local) surplus else min_local;
}

const DecodedVarint = struct { value: u64, length: usize };

fn readVarint(bytes: []const u8, offset: usize) ?DecodedVarint {
    if (offset >= bytes.len) return null;
    var value: u64 = 0;
    for (0..8) |index| {
        if (offset + index >= bytes.len) return null;
        const byte = bytes[offset + index];
        value = (value << 7) | (byte & 0x7f);
        if ((byte & 0x80) == 0) return .{ .value = value, .length = index + 1 };
    }
    if (offset + 8 >= bytes.len) return null;
    return .{ .value = (value << 8) | bytes[offset + 8], .length = 9 };
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn serialLength(serial_type: u64) ?usize {
    return switch (serial_type) {
        0, 8, 9, 10, 11 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6, 7 => 8,
        else => if (serial_type >= 12) @intCast((serial_type - 12) / 2) else null,
    };
}

fn signedInteger(bytes: []const u8) i64 {
    var value: u64 = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    if (bytes.len < 8 and bytes.len > 0 and (bytes[0] & 0x80) != 0) {
        const shift: u6 = @intCast(bytes.len * 8);
        value |= @as(u64, std.math.maxInt(u64)) << shift;
    }
    return @bitCast(value);
}

/// Decode the SQLite record format while retaining text/blob slices into the
/// caller-owned payload. Only the Value array is allocated.
pub fn decodeRecord(
    allocator: std.mem.Allocator,
    payload: []const u8,
) RecordOutcome {
    const header = readVarint(payload, 0) orelse return .{ .result = .corrupt };
    if (header.value < header.length or header.value > payload.len) return .{ .result = .corrupt };
    const header_end: usize = @intCast(header.value);
    var serials = std.ArrayList(u64).empty;
    defer serials.deinit(allocator);
    var offset = header.length;
    while (offset < header_end) {
        const serial = readVarint(payload[0..header_end], offset) orelse return .{ .result = .corrupt };
        serials.append(allocator, serial.value) catch return .{ .result = .no_memory };
        offset += serial.length;
    }
    if (offset != header_end) return .{ .result = .corrupt };
    const values = allocator.alloc(Value, serials.items.len) catch return .{ .result = .no_memory };
    errdefer allocator.free(values);
    var data_offset = header_end;
    for (serials.items, 0..) |serial, index| {
        const length = serialLength(serial) orelse return .{ .result = .corrupt };
        if (length > payload.len - data_offset) return .{ .result = .corrupt };
        const data = payload[data_offset..][0..length];
        values[index] = switch (serial) {
            0, 10, 11 => .null_,
            1, 2, 3, 4, 5, 6 => .{ .integer = signedInteger(data) },
            7 => blk: {
                var bits: u64 = 0;
                for (data) |byte| bits = (bits << 8) | byte;
                const real: f64 = @bitCast(bits);
                break :blk if (std.math.isNan(real)) .null_ else .{ .real = real };
            },
            8 => .{ .integer = 0 },
            9 => .{ .integer = 1 },
            else => if ((serial & 1) == 0) .{ .blob = data } else .{ .text = data },
        };
        data_offset += length;
    }
    return .{ .result = .ok, .record = .{ .allocator = allocator, .values = values } };
}

const CompareOutcome = struct {
    result: ResultCode,
    order: std.math.Order = .eq,
};

fn valueClass(value: Value) u8 {
    return switch (value) {
        .null_ => 0,
        .integer, .real => 1,
        .text => 2,
        .blob => 3,
    };
}

fn compareValues(left: Value, right: Value) std.math.Order {
    const left_class = valueClass(left);
    const right_class = valueClass(right);
    if (left_class != right_class) return if (left_class < right_class) .lt else .gt;
    return switch (left) {
        .null_ => .eq,
        .integer => |left_integer| switch (right) {
            .integer => |right_integer| std.math.order(left_integer, right_integer),
            .real => |right_real| std.math.order(@as(f64, @floatFromInt(left_integer)), right_real),
            else => unreachable,
        },
        .real => |left_real| switch (right) {
            .integer => |right_integer| std.math.order(left_real, @as(f64, @floatFromInt(right_integer))),
            .real => |right_real| std.math.order(left_real, right_real),
            else => unreachable,
        },
        .text => |left_text| std.mem.order(u8, left_text, right.text),
        .blob => |left_blob| std.mem.order(u8, left_blob, right.blob),
    };
}

fn compareRecordPayloads(_: std.mem.Allocator, left_payload: []const u8, right_payload: []const u8) CompareOutcome {
    const order = record_compare.compareRecords(left_payload, right_payload) catch return .{ .result = .corrupt };
    return .{ .result = .ok, .order = order };
}

const RecordKeyContext = struct { values: []const Value };

fn cursorRecordPayload(context: ?*const anyopaque, index: usize) []const u8 {
    const cursor: *const Cursor = @ptrCast(@alignCast(context.?));
    return cursor.entries.items[index].payload;
}

fn recordKeyValue(context: ?*const anyopaque, index: usize) record_compare.Value {
    const key: *const RecordKeyContext = @ptrCast(@alignCast(context.?));
    return switch (key.values[index]) {
        .null_ => .null_,
        .integer => |value| .{ .integer = value },
        .real => |value| .{ .real = value },
        .text => |value| .{ .text = value },
        .blob => |value| .{ .blob = value },
    };
}

fn compareRecordToKey(_: std.mem.Allocator, payload: []const u8, key: []const Value) CompareOutcome {
    const context = RecordKeyContext{ .values = key };
    const order = record_compare.indexKeyCompare(payload, key.len, &context, recordKeyValue) catch return .{ .result = .corrupt };
    return .{ .result = .ok, .order = order };
}

pub fn textToUtf8(
    allocator: std.mem.Allocator,
    text: []const u8,
    encoding: Encoding,
) ![]u8 {
    if (encoding == .utf8) return allocator.dupe(u8, text);
    if ((text.len & 1) != 0) return error.InvalidEncoding;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var offset: usize = 0;
    while (offset < text.len) {
        var first: u32 = if (encoding == .utf16le)
            @as(u32, text[offset]) | (@as(u32, text[offset + 1]) << 8)
        else
            (@as(u32, text[offset]) << 8) | text[offset + 1];
        offset += 2;
        if (first >= 0xd800 and first <= 0xdbff and offset + 2 <= text.len) {
            const second: u32 = if (encoding == .utf16le)
                @as(u32, text[offset]) | (@as(u32, text[offset + 1]) << 8)
            else
                (@as(u32, text[offset]) << 8) | text[offset + 1];
            if (second >= 0xdc00 and second <= 0xdfff) {
                first = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00;
                offset += 2;
            }
        }
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(@intCast(first), &encoded) catch {
            const replacement: [3]u8 = .{ 0xef, 0xbf, 0xbd };
            try output.appendSlice(allocator, &replacement);
            continue;
        };
        try output.appendSlice(allocator, encoded[0..count]);
    }
    return output.toOwnedSlice(allocator);
}

fn installFile(memory: *vfs.MemoryVfs, name: []const u8, data: []const u8) !void {
    const opened = memory.open(name, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    if (opened.rc != vfs.OK) return error.Open;
    const file = opened.file.?;
    if (file.write(data, 0) != vfs.OK) return error.Write;
    if (file.sync() != vfs.OK) return error.Sync;
    if (memory.closeAndDestroy(file) != vfs.OK) return error.Close;
}

fn readFixture(name: []const u8) ![]u8 {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "tests/fixtures/btree/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024));
}

fn readMutationFixture(name: []const u8) ![]u8 {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "tests/fixtures/btree-mutation/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024));
}

test "record decoder covers every serial storage class" {
    const payload = [_]u8{
        7,    0,    1,    2,    7,    15,   16,
        0xfe, 0xff, 0x00, 0x3f, 0xf0, 0,    0,
        0,    0,    0,    0,    'x',  0xaa, 0xbb,
    };
    const outcome = decodeRecord(std.testing.allocator, &payload);
    try std.testing.expectEqual(ResultCode.ok, outcome.result);
    var record = outcome.record.?;
    defer record.deinit();
    try std.testing.expectEqual(@as(usize, 6), record.values.len);
    try std.testing.expect(record.values[0] == .null_);
    try std.testing.expectEqual(@as(i64, -2), record.values[1].integer);
    try std.testing.expectEqual(@as(i64, -256), record.values[2].integer);
    try std.testing.expectEqual(@as(f64, 1.0), record.values[3].real);
    try std.testing.expectEqualStrings("x", record.values[4].text);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, record.values[5].blob);
}

test "table traversal seek record and overflow read through native pager" {
    const bytes = try readFixture("core-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "core.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-unit", &memory);
    const opened = Database.open(std.testing.allocator, &adapter.abi, "core.db");
    try std.testing.expectEqual(ResultCode.ok, opened.result);
    var database = opened.database.?;
    defer _ = database.close();
    const cursor_outcome = database.openCursor(2, .table);
    try std.testing.expectEqual(ResultCode.ok, cursor_outcome.result);
    var cursor = cursor_outcome.cursor.?;
    defer cursor.deinit();
    try std.testing.expectEqual(@as(usize, 701), cursor.count());
    try std.testing.expect(cursor.seekTable(1));
    var first_record = cursor.record().record.?;
    defer first_record.deinit();
    try std.testing.expect(first_record.values[0] == .null_);
    try std.testing.expectEqual(@as(i64, 17), first_record.values[1].integer);
    try std.testing.expect(cursor.seekTable(1 << 40));
    try std.testing.expect(cursor.current().?.payload.len > 20_000);
    var overflow_record = cursor.record().record.?;
    defer overflow_record.deinit();
    try std.testing.expect(overflow_record.values[3].text.len > 10_000);
    try std.testing.expectEqual(@as(usize, 12_000), overflow_record.values[4].blob.len);
}

test "index and WITHOUT ROWID trees traverse in key order" {
    const bytes = try readFixture("core-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "index.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-index", &memory);
    var database = Database.open(std.testing.allocator, &adapter.abi, "index.db").database.?;
    defer _ = database.close();
    var index_cursor = database.openCursor(3, .index).cursor.?;
    defer index_cursor.deinit();
    try std.testing.expectEqual(@as(usize, 701), index_cursor.count());
    try std.testing.expect(index_cursor.first());
    var previous: ?[]const u8 = null;
    var checked: usize = 0;
    while (index_cursor.current()) |entry| {
        var record = decodeRecord(std.testing.allocator, entry.payload).record.?;
        defer record.deinit();
        const text = record.values[0].text;
        if (previous) |prior| try std.testing.expect(std.mem.order(u8, prior, text) != .gt);
        previous = text;
        checked += 1;
        if (!index_cursor.next()) break;
    }
    try std.testing.expectEqual(index_cursor.count(), checked);
    index_cursor.position = index_cursor.count() / 2;
    var target = index_cursor.record().record.?;
    defer target.deinit();
    const seek = index_cursor.seekIndex(target.values);
    try std.testing.expectEqual(ResultCode.ok, seek.result);
    try std.testing.expect(seek.found);
    try std.testing.expect(index_cursor.current() != null);
    var wr_cursor = database.openCursor(4, .index).cursor.?;
    defer wr_cursor.deinit();
    try std.testing.expectEqual(@as(usize, 700), wr_cursor.count());
}

fn allocationExercise(allocator: std.mem.Allocator, adapter: *vfs.AbiAdapter) !void {
    const opened = Database.open(allocator, &adapter.abi, "oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer {
        if (database.pager.state != .closed) _ = database.close();
    }
    const cursor_outcome = database.openCursor(1, .table);
    if (cursor_outcome.result == .no_memory) return error.OutOfMemory;
    if (cursor_outcome.result != .ok) return error.UnexpectedResult;
    var cursor = cursor_outcome.cursor.?;
    cursor.deinit();
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "table rebuild inserts deletes splits overflow and reuses pages" {
    const bytes = try readFixture("core-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "mutate.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-mutate", &memory);
    var database = Database.openWritable(std.testing.allocator, &adapter.abi, "mutate.db").database.?;
    defer _ = database.close();
    var original = database.openCursor(2, .table).cursor.?;
    try std.testing.expect(original.seekTable(1));
    const payload = try std.testing.allocator.dupe(u8, original.current().?.payload);
    defer std.testing.allocator.free(payload);
    original.deinit();

    try std.testing.expectEqual(ResultCode.ok, database.deleteTable(2, 2));
    try std.testing.expectEqual(ResultCode.not_found, database.deleteTable(2, 2));
    try std.testing.expectEqual(ResultCode.ok, database.insertTable(2, 999_999, payload, false));
    try std.testing.expectEqual(ResultCode.constraint, database.insertTable(2, 999_999, payload, false));
    try std.testing.expectEqual(ResultCode.ok, database.insertTable(2, 999_999, payload, true));
    var changed = database.openCursor(2, .table).cursor.?;
    defer changed.deinit();
    try std.testing.expectEqual(@as(usize, 701), changed.count());
    try std.testing.expect(!changed.seekTable(2));
    try std.testing.expect(changed.seekTable(999_999));
    try std.testing.expect(database.pager.cache.checkInvariants());
}

test "index and WITHOUT ROWID rebuild preserve ordered records" {
    const bytes = try readFixture("core-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "index-mutate.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-index-mutate", &memory);
    var database = Database.openWritable(std.testing.allocator, &adapter.abi, "index-mutate.db").database.?;
    defer _ = database.close();
    inline for (.{ @as(u32, 3), @as(u32, 4) }) |root_page| {
        var original = database.openCursor(root_page, .index).cursor.?;
        try std.testing.expect(original.first());
        const payload = try std.testing.allocator.dupe(u8, original.current().?.payload);
        const original_count = original.count();
        original.deinit();
        defer std.testing.allocator.free(payload);
        try std.testing.expectEqual(ResultCode.ok, database.deleteIndex(root_page, payload));
        try std.testing.expectEqual(ResultCode.not_found, database.deleteIndex(root_page, payload));
        try std.testing.expectEqual(ResultCode.ok, database.insertIndex(root_page, payload));
        try std.testing.expectEqual(ResultCode.constraint, database.insertIndex(root_page, payload));
        var rebuilt = database.openCursor(root_page, .index).cursor.?;
        try std.testing.expectEqual(original_count, rebuilt.count());
        try std.testing.expect(rebuilt.first());
        try std.testing.expectEqualSlices(u8, payload, rebuilt.current().?.payload);
        rebuilt.deinit();

        try std.testing.expectEqual(ResultCode.ok, database.beginMutationBatch());
        try std.testing.expectEqual(ResultCode.ok, database.beginStatementBatch());
        try std.testing.expectEqual(ResultCode.ok, database.deleteIndex(root_page, payload));
        try std.testing.expectEqual(ResultCode.ok, database.rollbackStatementBatch());
        try std.testing.expectEqual(ResultCode.ok, database.commitMutationBatch());
        var restored = database.openCursor(root_page, .index).cursor.?;
        try std.testing.expectEqual(original_count, restored.count());
        try std.testing.expect(restored.first());
        try std.testing.expectEqualSlices(u8, payload, restored.current().?.payload);
        restored.deinit();
    }
}

fn mutationAllocationExercise(allocator: std.mem.Allocator, adapter: *vfs.AbiAdapter) !void {
    const opened = Database.openWritable(allocator, &adapter.abi, "mutation-oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer {
        if (database.pager.state != .closed) _ = database.close();
    }
    const rc = database.deleteTable(2, 2);
    if (rc == .no_memory) return error.OutOfMemory;
    if (rc != .ok) return error.UnexpectedResult;
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "B-tree mutation commits and checkpoints through WAL" {
    const source = try readMutationFixture("none-512.db");
    defer std.testing.allocator.free(source);
    const bytes = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(bytes);
    bytes[18] = 2;
    bytes[19] = 2;
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "btree-wal.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-wal", &memory);
    var writer = Database.openWritable(std.testing.allocator, &adapter.abi, "btree-wal.db").database.?;
    try std.testing.expectEqual(ResultCode.ok, writer.deleteTable(2, 2));
    var reader = Database.open(std.testing.allocator, &adapter.abi, "btree-wal.db").database.?;
    var snapshot = reader.openCursor(2, .table).cursor.?;
    try std.testing.expect(!snapshot.seekTable(2));
    snapshot.deinit();
    try std.testing.expectEqual(ResultCode.ok, reader.close());
    try std.testing.expectEqual(ResultCode.ok, writer.pager.checkpointWal().result);
    try std.testing.expectEqual(ResultCode.ok, writer.close());
}

test "bounded mutation allocation failures preserve transaction ownership" {
    const bytes = try readMutationFixture("none-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "mutation-oom.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-mutation-oom", &memory);
    var completed = false;
    for (0..1024) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        mutationAllocationExercise(failing.allocator(), &adapter) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
        };
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
        // Restore the deterministic input after successful or failed commits.
        const replacement = memory.open("mutation-oom.db", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(vfs.OK, replacement.truncate(0));
        try std.testing.expectEqual(vfs.OK, replacement.write(bytes, 0));
        try std.testing.expectEqual(vfs.OK, replacement.sync());
        try std.testing.expectEqual(vfs.OK, memory.closeAndDestroy(replacement));
    }
    try std.testing.expect(completed);
}

test "mutation VFS faults roll back logical content and permit continuation" {
    const bytes = try readFixture("core-512.db");
    defer std.testing.allocator.free(bytes);
    const cases = [_]struct { vfs.Method, c_int }{
        .{ .open, vfs.IOERR },
        .{ .lock, vfs.IOERR },
        .{ .read, vfs.IOERR },
        .{ .write, vfs.IOERR_WRITE },
        .{ .sync, vfs.IOERR_FSYNC },
        .{ .truncate, vfs.IOERR_TRUNCATE },
        .{ .delete, vfs.IOERR_DELETE },
    };
    for (cases, 0..) |case, index| {
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "mutation-fault-{d}.db", .{index});
        try installFile(&memory, name, bytes);
        var adapter = vfs.AbiAdapter.init("btree-mutation-fault", &memory);
        var database = Database.openWritable(std.testing.allocator, &adapter.abi, name).database.?;
        var rules = [_]vfs.FaultRule{.{ .method = case[0], .code = case[1] }};
        var faults = vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        try std.testing.expectEqual(ResultCode.fromC(case[1]), database.deleteTable(2, 2));
        memory.faults = null;
        var unchanged = database.openCursor(2, .table).cursor.?;
        try std.testing.expect(unchanged.seekTable(2));
        unchanged.deinit();
        try std.testing.expectEqual(ResultCode.ok, database.deleteTable(2, 2));
        var changed = database.openCursor(2, .table).cursor.?;
        try std.testing.expect(!changed.seekTable(2));
        changed.deinit();
        try std.testing.expectEqual(ResultCode.ok, database.close());
    }
}

test "bounded allocation failures preserve B-tree ownership" {
    const bytes = try readFixture("core-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "oom.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-oom", &memory);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationExercise,
        .{&adapter},
    );
}

test "malformed page and VFS read faults preserve ownership" {
    const source = try readFixture("core-512.db");
    defer std.testing.allocator.free(source);
    const malformed = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(malformed);
    malformed[512] = 0xff;
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "bad.db", malformed);
    var adapter = vfs.AbiAdapter.init("btree-bad", &memory);
    var database = Database.open(std.testing.allocator, &adapter.abi, "bad.db").database.?;
    try std.testing.expectEqual(ResultCode.corrupt, database.openCursor(2, .table).result);
    try std.testing.expectEqual(ResultCode.ok, database.close());

    try installFile(&memory, "fault.db", source);
    const fault_opened = Database.open(std.testing.allocator, &adapter.abi, "fault.db");
    var fault_database = fault_opened.database.?;
    var rules = [_]vfs.FaultRule{.{ .method = .read, .code = vfs.IOERR }};
    var faults = vfs.FaultController{ .rules = &rules };
    memory.faults = &faults;
    try std.testing.expectEqual(ResultCode.io_error, fault_database.openCursor(2, .table).result);
    try std.testing.expectEqual(@as(usize, 0), fault_database.pager.cacheReferences());
    try std.testing.expect(fault_database.pager.cache.checkInvariants());
    memory.faults = null;
    try std.testing.expectEqual(ResultCode.ok, fault_database.close());
}

test "schema DDL creates and drops table roots atomically" {
    const bytes = try readMutationFixture("none-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "schema.db", bytes);
    var adapter = vfs.AbiAdapter.init("btree-schema-ddl", &memory);
    var database = Database.openWritable(std.testing.allocator, &adapter.abi, "schema.db").database.?;
    try std.testing.expectEqual(ResultCode.ok, database.createSchemaTable("created", "CREATE TABLE created(x INTEGER, y TEXT)", false));
    try std.testing.expectEqual(ResultCode.error_, database.createSchemaTable("created", "CREATE TABLE created(x)", false));
    try std.testing.expectEqual(ResultCode.ok, database.createSchemaTable("created", "CREATE TABLE created(x)", true));
    var schema = database.openCursor(1, .table).cursor.?;
    var created_root: u32 = 0;
    for (schema.entries.items) |entry| {
        var record = decodeRecord(std.testing.allocator, entry.payload).record.?;
        defer record.deinit();
        if (schemaTextEqual(record.values[1], "created")) created_root = @intCast(record.values[3].integer);
    }
    schema.deinit();
    try std.testing.expect(created_root > 1);
    var created = database.openCursor(created_root, .table).cursor.?;
    try std.testing.expectEqual(@as(usize, 0), created.count());
    created.deinit();
    try std.testing.expectEqual(ResultCode.ok, database.close());

    database = Database.openWritable(std.testing.allocator, &adapter.abi, "schema.db").database.?;
    try std.testing.expectEqual(ResultCode.ok, database.dropSchemaTable("created", false));
    try std.testing.expectEqual(ResultCode.error_, database.dropSchemaTable("created", false));
    try std.testing.expectEqual(ResultCode.ok, database.dropSchemaTable("created", true));
    schema = database.openCursor(1, .table).cursor.?;
    defer schema.deinit();
    for (schema.entries.items) |entry| {
        var record = decodeRecord(std.testing.allocator, entry.payload).record.?;
        defer record.deinit();
        try std.testing.expect(!schemaTextEqual(record.values[1], "created"));
    }
    try std.testing.expectEqual(ResultCode.ok, database.close());
}

test "schema DDL faults roll back catalog and allow continuation" {
    const bytes = try readMutationFixture("none-512.db");
    defer std.testing.allocator.free(bytes);
    const cases = [_]struct { vfs.Method, c_int }{
        .{ .open, vfs.IOERR },       .{ .lock, vfs.IOERR },          .{ .write, vfs.IOERR_WRITE },
        .{ .sync, vfs.IOERR_FSYNC }, .{ .delete, vfs.IOERR_DELETE },
    };
    for (cases, 0..) |case, index| {
        var memory = vfs.MemoryVfs.init(std.testing.allocator);
        defer memory.deinit();
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "schema-fault-{d}.db", .{index});
        try installFile(&memory, name, bytes);
        var adapter = vfs.AbiAdapter.init("schema-ddl-fault", &memory);
        var database = Database.openWritable(std.testing.allocator, &adapter.abi, name).database.?;
        var rules = [_]vfs.FaultRule{.{ .method = case[0], .code = case[1] }};
        var faults = vfs.FaultController{ .rules = &rules };
        memory.faults = &faults;
        try std.testing.expectEqual(ResultCode.fromC(case[1]), database.createSchemaTable("faulted", "CREATE TABLE faulted(x)", false));
        memory.faults = null;
        try std.testing.expect(!database.schemaTableExists("faulted").found);
        try std.testing.expectEqual(ResultCode.ok, database.createSchemaTable("faulted", "CREATE TABLE faulted(x)", false));
        try std.testing.expect(database.schemaTableExists("faulted").found);
        try std.testing.expectEqual(ResultCode.ok, database.close());
    }
}

test "schema DDL commits and checkpoints through WAL" {
    const source = try readMutationFixture("none-512.db");
    defer std.testing.allocator.free(source);
    const bytes = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(bytes);
    bytes[18] = 2;
    bytes[19] = 2;
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "schema-wal.db", bytes);
    var adapter = vfs.AbiAdapter.init("schema-ddl-wal", &memory);
    var writer = Database.openWritable(std.testing.allocator, &adapter.abi, "schema-wal.db").database.?;
    try std.testing.expectEqual(ResultCode.ok, writer.createSchemaTable("wal_created", "CREATE TABLE wal_created(x)", false));
    var reader = Database.open(std.testing.allocator, &adapter.abi, "schema-wal.db").database.?;
    try std.testing.expect(reader.schemaTableExists("wal_created").found);
    try std.testing.expectEqual(ResultCode.ok, reader.close());
    try std.testing.expectEqual(ResultCode.ok, writer.pager.checkpointWal().result);
    try std.testing.expectEqual(ResultCode.ok, writer.close());
}

fn schemaDdlAllocationExercise(allocator: std.mem.Allocator, adapter: *vfs.AbiAdapter) !void {
    const opened = Database.openWritable(allocator, &adapter.abi, "schema-oom.db");
    if (opened.result == .no_memory) return error.OutOfMemory;
    if (opened.result != .ok) return error.UnexpectedResult;
    var database = opened.database.?;
    defer {
        if (database.pager.state != .closed) _ = database.close();
    }
    const rc = database.createSchemaTable("oom_created", "CREATE TABLE oom_created(x INTEGER, y TEXT)", false);
    if (rc == .no_memory) return error.OutOfMemory;
    if (rc != .ok) return error.UnexpectedResult;
    if (database.close() != .ok) return error.UnexpectedResult;
}

test "schema DDL bounded allocation failures preserve ownership" {
    const bytes = try readMutationFixture("none-512.db");
    defer std.testing.allocator.free(bytes);
    var memory = vfs.MemoryVfs.init(std.testing.allocator);
    defer memory.deinit();
    try installFile(&memory, "schema-oom.db", bytes);
    var adapter = vfs.AbiAdapter.init("schema-ddl-oom", &memory);
    var completed = false;
    for (0..1024) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        schemaDdlAllocationExercise(failing.allocator(), &adapter) catch |err| try std.testing.expect(err == error.OutOfMemory);
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
        const replacement = memory.open("schema-oom.db", vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(vfs.OK, replacement.truncate(0));
        try std.testing.expectEqual(vfs.OK, replacement.write(bytes, 0));
        try std.testing.expectEqual(vfs.OK, replacement.sync());
        try std.testing.expectEqual(vfs.OK, memory.closeAndDestroy(replacement));
    }
    try std.testing.expect(completed);
}
