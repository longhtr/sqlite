//! Cross-database schema-reference fixation from `attach.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const connection_names = @import("connection_names.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const walker_api = @import("walker.zig");
const types = @import("vdbe_types.zig");

pub const DatabaseFixer = extern struct {
    parse: *parse_types.Parse,
    walker: parse_types.Walker,
    schema: ?*parse_types.schema_types.Schema,
    temporary: u8,
    database_name: [*:0]const u8,
    object_type: [*:0]const u8,
    object_name: *const parse_types.Token,
};

fn database(parse: *parse_types.Parse) *types.Sqlite3 {
    return @ptrCast(@alignCast(parse.db.?));
}

fn fixer(walker: *parse_types.Walker) *DatabaseFixer {
    return @ptrCast(@alignCast(walker.u.pointer.?));
}

fn setError(fix: *DatabaseFixer, suffix: []const u8) void {
    const db = database(fix.parse);
    var buffer: [512]u8 = undefined;
    const object_name = if (fix.object_name.z) |name| name[0..fix.object_name.n] else "";
    const message = std.fmt.bufPrint(&buffer, "{s} {s} {s}", .{ fix.object_type, object_name, suffix }) catch suffix;
    db_allocator.free(db, if (fix.parse.zErrMsg) |old| @ptrCast(old) else null);
    fix.parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    fix.parse.nErr += 1;
    fix.parse.rc = 1;
}

/// Source `fixExprCb()`.
pub fn fixExpressionCallback(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    const fix = fixer(walker);
    if (fix.temporary == 0) expression.flags |= parse_types.expr_flag.from_ddl;
    if (expression.op == tokens.tk_variable) {
        if (database(fix.parse).init.busy != 0) {
            expression.op = @intCast(tokens.tk_null);
        } else {
            setError(fix, "cannot use variables");
            return walker_api.abort;
        }
    }
    return walker_api.continue_walk;
}

/// Source `fixSelectCb()`.
pub fn fixSelectCallback(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    const fix = fixer(walker);
    const db = database(fix.parse);
    const required_database = connection_names.findDatabaseName(db, fix.database_name);
    const sources = select.pSrc orelse return walker_api.continue_walk;
    for (sources.items()) |*item| {
        if (fix.temporary == 0 and !item.fg.isSubquery) {
            if (!item.fg.fixedSchema and item.u4.zDatabase != null) {
                if (required_database != connection_names.findDatabaseName(db, item.u4.zDatabase)) {
                    var suffix_buffer: [256]u8 = undefined;
                    const suffix = std.fmt.bufPrint(&suffix_buffer, "cannot reference objects in database {s}", .{item.u4.zDatabase.?}) catch "cannot reference another database";
                    setError(fix, suffix);
                    return walker_api.abort;
                }
                db_allocator.freeNN(db, item.u4.zDatabase.?);
                item.fg.notCte = true;
                item.fg.hadSchema = true;
            }
            item.u4.pSchema = if (fix.schema) |schema| @ptrCast(schema) else null;
            item.fg.fromDDL = true;
            item.fg.fixedSchema = true;
        }
        if (!item.fg.isUsing and walker_api.walkExpr(&fix.walker, item.u3.pOn) != walker_api.continue_walk) return walker_api.abort;
    }
    if (select.pWith) |with| {
        for (with.items()) |*cte| {
            if (walker_api.walkSelect(walker, cte.pSelect) != walker_api.continue_walk) return walker_api.abort;
        }
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3FixInit()`.
pub fn initialize(
    fix: *DatabaseFixer,
    parse: *parse_types.Parse,
    database_index: c_int,
    object_type: [*:0]const u8,
    object_name: *const parse_types.Token,
) void {
    const db = database(parse);
    const attached = &db.aDb.?[@intCast(database_index)];
    fix.* = .{
        .parse = parse,
        .walker = .{
            .pParse = parse,
            .xExprCallback = fixExpressionCallback,
            .xSelectCallback = fixSelectCallback,
            .xSelectCallback2 = walker_api.walkWindowDefinitionDummy,
            .walkerDepth = 0,
            .eCode = 0,
            .mWFlags = 0,
            .u = .{ .pointer = fix },
        },
        .schema = attached.pSchema,
        .temporary = @intFromBool(database_index == 1),
        .database_name = attached.zDbSName.?,
        .object_type = object_type,
        .object_name = object_name,
    };
}

/// Source `sqlite3FixSrcList()`.
pub fn fixSourceList(fix: *DatabaseFixer, sources: ?*parse_types.SrcList) c_int {
    const present = sources orelse return 0;
    var select = std.mem.zeroes(parse_types.Select);
    select.pSrc = present;
    return walker_api.walkSelect(&fix.walker, &select);
}

/// Source `sqlite3FixSelect()`.
pub fn fixSelect(fix: *DatabaseFixer, select: ?*parse_types.Select) c_int {
    return walker_api.walkSelect(&fix.walker, select);
}

/// Source `sqlite3FixExpr()`.
pub fn fixExpression(fix: *DatabaseFixer, expression: ?*parse_types.Expr) c_int {
    return walker_api.walkExpr(&fix.walker, expression);
}

/// Source `sqlite3FixTriggerStep()`.
pub fn fixTriggerSteps(fix: *DatabaseFixer, first: ?*parse_types.TriggerStep) c_int {
    var step = first;
    while (step) |present| : (step = present.next) {
        if (walker_api.walkSelect(&fix.walker, present.select) != 0 or
            walker_api.walkExpr(&fix.walker, present.where) != 0 or
            walker_api.walkExprList(&fix.walker, present.expressions) != 0 or
            fixSourceList(fix, present.sources) != 0) return 1;
        var upsert = present.upsert;
        while (upsert) |item| : (upsert = item.pNextUpsert) {
            if (walker_api.walkExprList(&fix.walker, item.pUpsertTarget) != 0 or
                walker_api.walkExpr(&fix.walker, item.pUpsertTargetWhere) != 0 or
                walker_api.walkExprList(&fix.walker, item.pUpsertSet) != 0 or
                walker_api.walkExpr(&fix.walker, item.pUpsertWhere) != 0) return 1;
        }
    }
    return 0;
}
