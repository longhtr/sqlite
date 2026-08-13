//! Schema reset and cache lifecycle from `callback.c` and `build.c`.

const std = @import("std");
const compiler_ownership = @import("compiler_ownership.zig");
const db_allocator = @import("db_allocator.zig");
const memory = @import("../memory.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const trigger_returning = @import("trigger_returning.zig");
const types = @import("vdbe_types.zig");

/// Source `sqlite3SchemaClear()`.
pub fn clearSchema(schema_owner: *schema.Schema) void {
    var temporary_database = std.mem.zeroes(types.Sqlite3);
    var table_hash = schema_owner.table_hash;
    var trigger_hash = schema_owner.trigger_hash;
    schema_owner.trigger_hash.initialize();
    schema_owner.index_hash.clear(memory.processAllocator());
    var element = trigger_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const trigger: *@import("parse_types.zig").Trigger = @ptrCast(@alignCast(present.value().?));
        trigger_returning.deleteTrigger(&temporary_database, trigger);
    }
    trigger_hash.clear(memory.processAllocator());
    schema_owner.table_hash.initialize();
    element = table_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const table: *schema.Table = @ptrCast(@alignCast(present.value().?));
        compiler_ownership.deleteTable(&temporary_database, table);
    }
    table_hash.clear(memory.processAllocator());
    schema_owner.foreign_key_hash.clear(memory.processAllocator());
    schema_owner.sequence_table = null;
    if (schema_owner.flags & types.schema_flag.loaded != 0) schema_owner.generation += 1;
    schema_owner.flags &= ~(types.schema_flag.loaded | types.schema_flag.reset_wanted);
}

pub const BtreeSchemaProvider = *const fn (*types.Btree, usize, *const fn (*schema.Schema) void) ?*schema.Schema;

/// Source `sqlite3SchemaGet()`. B-tree-owned schema storage is supplied by
/// the B-tree owner so this module retains no duplicate B-tree representation.
pub fn getSchema(db: *types.Sqlite3, btree: ?*types.Btree, provider: BtreeSchemaProvider) ?*schema.Schema {
    const owner = if (btree) |tree|
        provider(tree, @sizeOf(schema.Schema), clearSchema)
    else blk: {
        const raw = db_allocator.mallocZero(null, @sizeOf(schema.Schema)) orelse break :blk null;
        break :blk @as(*schema.Schema, @ptrCast(@alignCast(raw)));
    };
    const result = owner orelse {
        _ = db_allocator.oomFault(db);
        return null;
    };
    if (result.file_format == 0) {
        result.table_hash.initialize();
        result.index_hash.initialize();
        result.trigger_hash.initialize();
        result.foreign_key_hash.initialize();
        result.encoding = 1;
    }
    return result;
}

fn missingSchemaProvider(_: *types.Btree, _: usize, _: *const fn (*schema.Schema) void) ?*schema.Schema {
    return null;
}

test "standalone schema allocation initializes all source hash owners" {
    const started_here = !memory.process_manager.started;
    if (started_here) try std.testing.expectEqual(memory.ok, memory.process_manager.start());
    defer if (started_here) memory.process_manager.stop();
    var db = std.mem.zeroes(types.Sqlite3);
    const owner = getSchema(&db, null, missingSchemaProvider).?;
    defer db_allocator.freeNN(null, owner);
    try std.testing.expectEqual(@as(u8, 1), owner.encoding);
    try std.testing.expectEqual(@as(c_uint, 0), owner.table_hash.count());
    try std.testing.expectEqual(@as(c_uint, 0), owner.index_hash.count());
    try std.testing.expectEqual(@as(c_uint, 0), owner.trigger_hash.count());
    try std.testing.expectEqual(@as(c_uint, 0), owner.foreign_key_hash.count());
}

/// Source `sqlite3ResetOneSchema()`.
pub fn resetOneSchema(db: *types.Sqlite3, database_index: c_int) void {
    if (database_index >= 0) {
        db.aDb.?[@intCast(database_index)].pSchema.?.flags |= types.schema_flag.reset_wanted;
        db.aDb.?[1].pSchema.?.flags |= types.schema_flag.reset_wanted;
        db.mDbFlags &= ~types.database_flag.schema_known_ok;
    }
    if (db.nSchemaLock == 0) {
        for (db.aDb.?[0..@intCast(db.nDb)]) |attached| {
            if (attached.pSchema) |schema_owner| if (schema_owner.flags & types.schema_flag.reset_wanted != 0) clearSchema(schema_owner);
        }
    }
}

/// Source `sqlite3ResetAllSchemasOfConnection()`.
pub fn resetAllSchemas(db: *types.Sqlite3) void {
    for (db.aDb.?[0..@intCast(db.nDb)]) |attached| {
        if (attached.pSchema) |schema_owner| {
            if (db.nSchemaLock == 0) clearSchema(schema_owner) else schema_owner.flags |= types.schema_flag.reset_wanted;
        }
    }
    db.mDbFlags &= ~(types.database_flag.schema_change | types.database_flag.schema_known_ok);
    if (db.nSchemaLock == 0) schema_analysis.collapseDatabaseArray(db);
}

/// Source `sqlite3CommitInternalChanges()`.
pub fn commitInternalChanges(db: *types.Sqlite3) void {
    db.mDbFlags &= ~types.database_flag.schema_change;
}

/// Source `sqliteViewResetAll()`.
pub fn resetAllViews(db: *types.Sqlite3, database_index: c_int) void {
    const schema_owner = db.aDb.?[@intCast(database_index)].pSchema.?;
    if (schema_owner.flags & types.schema_flag.unreset_views == 0) return;
    var element = schema_owner.table_hash.first();
    while (element) |present| : (element = present.nextElement()) {
        const table: *schema.Table = @ptrCast(@alignCast(present.value().?));
        if (table.kind == .view) compiler_ownership.deleteColumnNames(db, table);
    }
    schema_owner.flags &= ~types.schema_flag.unreset_views;
}
