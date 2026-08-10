//! Table writeability checks from `delete.c`.

const std = @import("std");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const types = @import("vdbe_types.zig");

fn setError(parse: *parse_types.Parse, pattern: []const u8, name: [*:0]const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, pattern, .{name}) catch "table may not be modified";
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `vtabIsReadOnly()`.
pub fn virtualTableIsReadOnly(parse: *parse_types.Parse, table: *schema.Table) bool {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const instance: *types.VTable = @ptrCast(@alignCast(table.owner.virtual.instances.?));
    if (instance.pMod.?.pModule.?.xUpdate == null) return true;
    if ((parse.pToplevel != null or parse.prepFlags & 0x20 != 0) and
        instance.eVtabRisk > @intFromBool(db.flags & types.connection_flag.trusted_schema != 0))
    {
        setError(parse, "unsafe use of virtual table \"{s}\"", table.name.?);
    }
    return false;
}

/// Source `tabIsReadOnly()`.
pub fn tableIsReadOnly(parse: *parse_types.Parse, table: *schema.Table) bool {
    if (table.kind == .virtual) return virtualTableIsReadOnly(parse, table);
    if (table.flags & (0x0000_0001 | 0x0000_1000) == 0) return false;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (table.flags & 0x0000_0001 != 0) return !schema_analysis.writableSchema(db) and parse.nested == 0;
    return schema_analysis.readOnlyShadowTables(db);
}

/// Source `sqlite3IsReadOnly()`.
pub fn isReadOnly(parse: *parse_types.Parse, table: *schema.Table, trigger: ?*parse_types.Trigger) bool {
    if (tableIsReadOnly(parse, table)) {
        setError(parse, "table {s} may not be modified", table.name.?);
        return true;
    }
    if (table.kind == .view and (trigger == null or (trigger.?.returning != 0 and trigger.?.next == null))) {
        setError(parse, "cannot modify {s} because it is a view", table.name.?);
        return true;
    }
    return false;
}
