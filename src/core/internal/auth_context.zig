//! Authorization error and context-stack helpers from `auth.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const connection_names = @import("connection_names.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const types = @import("vdbe_types.zig");

pub const AuthContext = extern struct {
    context: ?[*:0]const u8,
    parse: ?*parse_types.Parse,
};

fn setMessage(parse: *parse_types.Parse, message: []const u8, code: c_int) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = code;
}

/// Source `sqliteAuthBadReturnCode()`.
pub fn badReturnCode(parse: *parse_types.Parse) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    _ = db;
    setMessage(parse, "authorizer malfunction", 1);
}

/// Source `sqlite3AuthReadCol()`.
pub fn authorizeReadColumn(
    parse: *parse_types.Parse,
    table: [*:0]const u8,
    column: [*:0]const u8,
    database_index: c_int,
) c_int {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    if (db.init.busy != 0) return 0;
    const database_name = db.aDb.?[@intCast(database_index)].zDbSName;
    const result = db.xAuth.?(db.pAuthArg, 20, table, column, database_name, parse.zAuthContext);
    if (result == 1) {
        var buffer: [512]u8 = undefined;
        const message = if (db.nDb > 2 or database_index != 0)
            std.fmt.bufPrint(&buffer, "access to {s}.{s}.{s} is prohibited", .{ database_name.?, table, column }) catch "access is prohibited"
        else
            std.fmt.bufPrint(&buffer, "access to {s}.{s} is prohibited", .{ table, column }) catch "access is prohibited";
        setMessage(parse, message, 23);
    } else if (result != 0 and result != 2) badReturnCode(parse);
    return result;
}

/// Source `sqlite3AuthRead()`.
pub fn authorizeRead(
    parse: *parse_types.Parse,
    expression: *parse_types.Expr,
    expression_schema: *schema.Schema,
    source_list: ?*parse_types.SrcList,
) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const database_index = connection_names.schemaToIndex(db, expression_schema);
    if (database_index < 0) return;
    var table: ?*schema.Table = null;
    if (expression.op == tokens.tk_trigger) {
        table = parse.pTriggerTab;
    } else if (source_list) |sources| {
        for (sources.items()) |*source| if (expression.iTable == source.cursor) {
            table = source.table;
            break;
        };
    }
    const present = table orelse return;
    const column_index = expression.iColumn;
    const column_name: [*:0]const u8 = if (column_index >= 0)
        @ptrCast(present.columns.?[@intCast(column_index)].name_and_metadata.?)
    else if (present.primary_key_column >= 0)
        @ptrCast(present.columns.?[@intCast(present.primary_key_column)].name_and_metadata.?)
    else
        "ROWID";
    if (authorizeReadColumn(parse, present.name.?, column_name, database_index) == 2) expression.op = @intCast(tokens.tk_null);
}

/// Source `sqlite3AuthCheck()`.
pub fn authorize(
    parse: *parse_types.Parse,
    code: c_int,
    first: ?[*:0]const u8,
    second: ?[*:0]const u8,
    third: ?[*:0]const u8,
) c_int {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const callback = db.xAuth orelse return 0;
    if (db.init.busy != 0 or parse.eParseMode != 0) return 0;
    var result = callback(db.pAuthArg, code, first, second, third, parse.zAuthContext);
    if (result == 1) {
        setMessage(parse, "not authorized", 23);
    } else if (result != 0 and result != 2) {
        result = 1;
        badReturnCode(parse);
    }
    return result;
}

/// Source `sqlite3AuthContextPush()`.
pub fn push(parse: *parse_types.Parse, context: *AuthContext, name: ?[*:0]const u8) void {
    context.parse = parse;
    context.context = parse.zAuthContext;
    parse.zAuthContext = name;
}

/// Source `sqlite3AuthContextPop()`.
pub fn pop(context: *AuthContext) void {
    if (context.parse) |parse| {
        parse.zAuthContext = context.context;
        context.parse = null;
    }
}
