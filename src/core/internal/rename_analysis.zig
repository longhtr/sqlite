//! Parse-tree token mappings used by ALTER TABLE from `alter.c`.

const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const types = @import("vdbe_types.zig");

/// Source `sqlite3RenameTokenMap()`.
pub fn mapToken(parse: *parse_types.Parse, pointer: ?*const anyopaque, token: *const parse_types.Token) ?*const anyopaque {
    if (parse.eParseMode != 3) {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        if (db_allocator.mallocZero(db, @sizeOf(parse_types.RenameToken))) |raw| {
            const mapping: *parse_types.RenameToken = @ptrCast(@alignCast(raw));
            mapping.pointer = pointer;
            mapping.token = token.*;
            mapping.next = parse.pRename;
            parse.pRename = mapping;
        }
    }
    return pointer;
}

/// Source `sqlite3RenameTokenRemap()`.
pub fn remapToken(parse: *parse_types.Parse, destination: ?*const anyopaque, source: ?*const anyopaque) void {
    var mapping = parse.pRename;
    while (mapping) |present| : (mapping = present.next) {
        if (present.pointer == source) {
            present.pointer = destination;
            break;
        }
    }
}
