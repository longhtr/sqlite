//! ALTER TABLE rename-token and constraint-text processing from `alter.c`.

const std = @import("std");
const tokenizer = @import("../tokenizer.zig");
const tokens = @import("../generated/tokens.zig");
const sqlite_string = @import("../string.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const db_allocator = @import("db_allocator.zig");
const parse_types = @import("parse_types.zig");
const schema = @import("schema_types.zig");
const schema_analysis = @import("schema_analysis.zig");
const types = @import("vdbe_types.zig");
const walker_api = @import("walker.zig");
const vdbe_aux = @import("vdbe_aux.zig");

fn setAlterError(parse: *parse_types.Parse, message: []const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

/// Source `isAlterableTable()`.
pub fn isAlterableTable(parse: *parse_types.Parse, table: *schema.Table) bool {
    const name = table.name.?;
    if (sqlite_string.compareN(name, "sqlite_", 7) == 0 or table.flags & (0x0000_2000 | 0x0080_0000) != 0) {
        var buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "table {s} may not be altered", .{std.mem.span(name)}) catch "table may not be altered";
        setAlterError(parse, message);
        return false;
    }
    return true;
}

/// Source `isRealTable()`.
pub fn isRealTable(parse: *parse_types.Parse, table: *schema.Table, operation: c_int) bool {
    const kind: []const u8 = switch (table.kind) {
        .view => "view",
        .virtual => "virtual table",
        .ordinary => return true,
    };
    const actions = [_][]const u8{ "rename columns of", "drop column from", "edit constraints of" };
    var buffer: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "cannot {s} {s} \"{s}\"", .{ actions[@intCast(operation)], kind, std.mem.span(table.name.?) }) catch "cannot alter table";
    setAlterError(parse, message);
    return false;
}

pub const RenameContext = struct {
    list: ?*parse_types.RenameToken = null,
    count: c_int = 0,
    column: c_int = 0,
    table: ?*schema.Table = null,
    old_name: ?[*:0]const u8 = null,
};

/// Source `renameTokenFind()`.
pub fn findRenameToken(parse: *parse_types.Parse, context: ?*RenameContext, pointer: ?*const anyopaque) ?*parse_types.RenameToken {
    const target = pointer orelse return null;
    var link = &parse.pRename;
    while (link.*) |mapping| {
        if (mapping.pointer == target) {
            if (context) |owner| {
                link.* = mapping.next;
                mapping.next = owner.list;
                owner.list = mapping;
                owner.count += 1;
            }
            return mapping;
        }
        link = &mapping.next;
    }
    return null;
}

/// Source `renameColumnExprCb()`.
pub fn renameColumnExpression(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const context: *RenameContext = @ptrCast(@alignCast(walker.u.pointer.?));
    if (node.op == tokens.tk_trigger and node.iColumn == context.column and walker.pParse.?.pTriggerTab == context.table) {
        _ = findRenameToken(walker.pParse.?, context, node);
    } else if (node.op == tokens.tk_column and node.iColumn == context.column and node.y.pTab == context.table) {
        _ = findRenameToken(walker.pParse.?, context, node);
    }
    return walker_api.continue_walk;
}

/// Source `renameColumnTokenNext()`.
pub fn nextRenameColumnToken(context: *RenameContext) ?*parse_types.RenameToken {
    var best = context.list orelse return null;
    var current = best.next;
    while (current) |candidate| : (current = candidate.next) {
        if (@intFromPtr(candidate.token.z.?) > @intFromPtr(best.token.z.?)) {
            best = candidate;
        }
    }
    var link = &context.list;
    while (link.* != best) link = &link.*.?.next;
    link.* = best.next;
    best.next = null;
    return best;
}

/// Source `renameColumnElistNames()`.
pub fn collectExpressionListNames(parse: *parse_types.Parse, context: *RenameContext, list_optional: ?*const parse_types.ExprList, old_name: [*:0]const u8) void {
    const list = list_optional orelse return;
    for (@constCast(list).items()) |item| {
        if (item.zEName != null and item.fg.eEName == 0 and sqlite_string.compareInternal(item.zEName.?, old_name) == 0) _ = findRenameToken(parse, context, item.zEName);
    }
}

/// Source `renameColumnIdlistNames()`.
pub fn collectIdentifierListNames(parse: *parse_types.Parse, context: *RenameContext, list_optional: ?*const parse_types.IdList, old_name: [*:0]const u8) void {
    const list = list_optional orelse return;
    for (@constCast(list).items()) |item| {
        if (sqlite_string.compareInternal(item.zName.?, old_name) == 0) {
            _ = findRenameToken(parse, context, item.zName);
        }
    }
}

/// Source `renameSetENames()`.
pub fn setExpressionNameKinds(list_optional: ?*parse_types.ExprList, value: u2) void {
    const list = list_optional orelse return;
    for (list.items()) |*item| item.fg.eEName = value;
}

/// Source `renameTableExprCb()`.
pub fn renameTableExpression(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const context: *RenameContext = @ptrCast(@alignCast(walker.u.pointer.?));
    if (node.op == tokens.tk_column and node.y.pTab == context.table) _ = findRenameToken(walker.pParse.?, context, &node.y.pTab);
    return walker_api.continue_walk;
}

/// Source `renameTableSelectCb()`.
pub fn renameTableSelect(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    if (select.selFlags & (0x0000_0200 | 0x0000_0400) != 0) return walker_api.prune;
    const context: *RenameContext = @ptrCast(@alignCast(walker.u.pointer.?));
    const sources = select.pSrc orelse return walker_api.abort_walk;
    for (sources.items()) |item| {
        if (item.pSTab == context.table) {
            _ = findRenameToken(walker.pParse.?, context, item.zName);
        }
    }
    return walker_api.continue_walk;
}

/// Source `renameWalkTrigger()`.
pub fn walkTriggerForRename(walker: *parse_types.Walker, trigger: *parse_types.Trigger) void {
    _ = walker_api.walkExpr(walker, trigger.when);
    var step = trigger.steps;
    while (step) |present| : (step = present.next) {
        _ = walker_api.walkSelect(walker, present.select);
        _ = walker_api.walkExpr(walker, present.where);
        _ = walker_api.walkExprList(walker, present.expressions);
        if (present.upsert) |upsert| {
            _ = walker_api.walkExprList(walker, upsert.pUpsertTarget);
            _ = walker_api.walkExprList(walker, upsert.pUpsertSet);
            _ = walker_api.walkExpr(walker, upsert.pUpsertWhere);
            _ = walker_api.walkExpr(walker, upsert.pUpsertTargetWhere);
        }
        if (present.sources) |sources| {
            for (sources.items()) |item| {
                if (item.fg.isSubquery and item.u4.pSubq != null) {
                    _ = walker_api.walkSelect(walker, item.u4.pSubq.?.pSelect);
                }
            }
        }
    }
}

/// Source `renameUnmapExprCb()`.
pub fn unmapExpressionCallback(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const rename = @import("rename_analysis.zig");
    rename.remapToken(walker.pParse.?, null, node);
    rename.remapToken(walker.pParse.?, null, &node.y.pTab);
    return walker_api.continue_walk;
}

/// Source `unmapColumnIdlistNames()`.
pub fn unmapIdentifierNames(parse: *parse_types.Parse, list: *const parse_types.IdList) void {
    const rename = @import("rename_analysis.zig");
    for (@constCast(list).items()) |item| rename.remapToken(parse, null, item.zName);
}

fn unmapSelectCallback(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    if (walker.pParse.?.nErr != 0) return walker_api.abort_walk;
    if (select.selFlags & (0x0000_0200 | 0x0000_0400) != 0) return walker_api.prune;
    if (select.pEList) |list| {
        for (list.items()) |item| {
            if (item.zEName != null and item.fg.eEName == 0) {
                @import("rename_analysis.zig").remapToken(walker.pParse.?, null, item.zEName);
            }
        }
    }
    if (select.pSrc) |sources| for (sources.items()) |item| {
        @import("rename_analysis.zig").remapToken(walker.pParse.?, null, item.zName);
        if (item.fg.isUsing) {
            if (item.u3.pUsing) |using| unmapIdentifierNames(walker.pParse.?, using);
        } else _ = walker_api.walkExpr(walker, item.u3.pOn);
    };
    return walker_api.continue_walk;
}

/// Source `renameColumnSelectCb()`.
pub fn renameColumnSelectCallback(walker: *parse_types.Walker, select: *parse_types.Select) callconv(.c) c_int {
    if (select.selFlags & (0x0000_0200 | 0x0000_0400) != 0) return walker_api.prune;
    if (select.pWith) |with| {
        for (with.items()) |cte| {
            _ = walker_api.walkSelect(walker, cte.pSelect);
            unmapRenameExpressionList(walker.pParse.?, cte.pCols);
        }
    }
    return walker_api.continue_walk;
}

/// Source `renameQuotefixExprCb()`.
pub fn renameQuoteFixExpressionCallback(walker: *parse_types.Walker, node: *parse_types.Expr) callconv(.c) c_int {
    const double_quoted: u32 = 0x0000_0080;
    if (node.op == tokens.tk_string and node.flags & double_quoted != 0) {
        const context: *RenameContext = @ptrCast(@alignCast(walker.u.pointer.?));
        _ = findRenameToken(walker.pParse.?, context, node);
    }
    return walker_api.continue_walk;
}

/// Source `sqlite3RenameExprUnmap()`.
pub fn unmapRenameExpression(parse: *parse_types.Parse, node: ?*parse_types.Expr) void {
    const saved = parse.eParseMode;
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.pParse = parse;
    walker.xExprCallback = unmapExpressionCallback;
    walker.xSelectCallback = unmapSelectCallback;
    parse.eParseMode = 3;
    _ = walker_api.walkExpr(&walker, node);
    parse.eParseMode = saved;
}

/// Source `renameTokenFree()`.
pub fn freeRenameTokens(db: *types.Sqlite3, first: ?*parse_types.RenameToken) void {
    var current = first;
    while (current) |token| {
        const next = token.next;
        db_allocator.free(db, token);
        current = next;
    }
}

/// Source `sqlite3RenameExprlistUnmap()`.
pub fn unmapRenameExpressionList(parse: *parse_types.Parse, list_optional: ?*parse_types.ExprList) void {
    const list = list_optional orelse return;
    var walker = std.mem.zeroes(parse_types.Walker);
    walker.pParse = parse;
    walker.xExprCallback = unmapExpressionCallback;
    _ = walker_api.walkExprList(&walker, list);
    for (list.items()) |item| {
        if (item.fg.eEName == 0) {
            @import("rename_analysis.zig").remapToken(parse, null, item.zEName);
        }
    }
}

/// Source `renameReloadSchema()`.
pub fn reloadRenamedSchema(parse: *parse_types.Parse, database_index: c_int, flags: u16) void {
    const machine = parse.pVdbe orelse return;
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const database = db.aDb.?[@intCast(database_index)];
    const current_cookie = database.pSchema.?.cookie;
    _ = vdbe_aux.addOperation3(machine, .SetCookie, database_index, 1, current_cookie +% 1);
    vdbe_aux.addParseSchemaOperation(machine, database_index, null, flags);
    if (database_index != 1) vdbe_aux.addParseSchemaOperation(machine, 1, null, flags);
}

pub const ConstraintToken = struct { length: usize, token_type: u16 };

/// Source `getConstraintToken()`.
pub fn constraintToken(text: [*:0]const u8) ConstraintToken {
    var offset: usize = 0;
    var result: tokenizer.Result = undefined;
    while (true) {
        result = tokenizer.get(text + offset);
        offset += result.length;
        if (result.token_type != tokens.tk_space and result.token_type != tokens.tk_comment) break;
    }
    if (result.token_type == tokens.tk_lp) {
        var nesting: usize = 1;
        while (nesting > 0) {
            result = tokenizer.get(text + offset);
            offset += result.length;
            if (result.token_type == tokens.tk_lp) nesting += 1 else if (result.token_type == tokens.tk_rp) {
                result.token_type = tokens.tk_lp;
                nesting -= 1;
            } else if (result.token_type == tokens.tk_illegal) break;
        }
    }
    return .{ .length = offset, .token_type = result.token_type };
}

/// Source `getWhitespace()`.
pub fn whitespaceLength(text: [*:0]const u8) usize {
    var offset: usize = 0;
    while (true) {
        const token = tokenizer.get(text + offset);
        if (token.token_type != tokens.tk_space and token.token_type != tokens.tk_comment) return offset;
        offset += token.length;
    }
}

/// Source `getConstraint()`.
pub fn constraintLength(text: [*:0]const u8) usize {
    var offset: usize = 0;
    while (true) {
        const token = constraintToken(text + offset);
        switch (token.token_type) {
            tokens.tk_constraint, tokens.tk_primary, tokens.tk_not, tokens.tk_unique, tokens.tk_check, tokens.tk_default, tokens.tk_collate, tokens.tk_references, tokens.tk_foreign, tokens.tk_rp, tokens.tk_comma, tokens.tk_illegal, tokens.tk_as, tokens.tk_generated => return offset,
            else => offset += token.length,
        }
    }
}

/// Source `quotedCompare()`.
pub fn quotedConstraintNameEqual(allocator: std.mem.Allocator, token_type: u16, quoted: []const u8, comparison: []const u8) !bool {
    if (token_type == tokens.tk_illegal) return false;
    const copy = try allocator.allocSentinel(u8, quoted.len, 0);
    defer allocator.free(copy);
    @memcpy(copy[0..quoted.len], quoted);
    sqlite_string.dequote(copy.ptr);
    return std.ascii.eqlIgnoreCase(std.mem.span(copy.ptr), comparison);
}

/// Source `skipCreateTable()`.
pub fn createTableBodyOffset(sql: [*:0]const u8) !usize {
    var offset: usize = 0;
    while (true) {
        const token = tokenizer.get(sql + offset);
        offset += token.length;
        if (token.token_type == tokens.tk_lp) return offset;
        if (token.token_type == tokens.tk_illegal) return error.CorruptSchema;
    }
}

/// Source `alterRtrimConstraint()`.
pub fn trimmedConstraintLength(allocator: std.mem.Allocator, constraint: []const u8) !usize {
    const copy = try allocator.allocSentinel(u8, constraint.len, 0);
    defer allocator.free(copy);
    @memcpy(copy[0..constraint.len], constraint);
    var offset: usize = 0;
    var end: usize = 0;
    while (true) {
        const token = tokenizer.get(copy.ptr + offset);
        if (token.token_type == tokens.tk_illegal) break;
        if (token.token_type != tokens.tk_space and (token.token_type != tokens.tk_comment or copy[offset] != '-')) end = offset + token.length;
        offset += token.length;
    }
    return end;
}

/// Source `findConstraintFunc()`.
pub fn containsNamedConstraint(allocator: std.mem.Allocator, sql: [*:0]const u8, name: []const u8) !bool {
    var offset: usize = 0;
    var token_type: u16 = 0;
    while (token_type != tokens.tk_lp and token_type != tokens.tk_illegal) {
        const token = tokenizer.get(sql + offset);
        offset += token.length;
        token_type = token.token_type;
    }
    while (true) {
        const token = constraintToken(sql + offset);
        offset += token.length;
        if (token.token_type == tokens.tk_constraint) {
            offset += whitespaceLength(sql + offset);
            const candidate = constraintToken(sql + offset);
            if (try quotedConstraintNameEqual(allocator, candidate.token_type, sql[offset .. offset + candidate.length], name)) return true;
        } else if (token.token_type == tokens.tk_illegal) return false;
    }
}

/// Source `addConstraintFunc()`.
pub fn addConstraintText(allocator: std.mem.Allocator, sql: [*:0]const u8, constraint: []const u8, target_column: c_int) ![:0]u8 {
    var offset = try createTableBodyOffset(sql);
    var token_type: u16 = 0;
    var column: c_int = 0;
    while (column <= target_column or (target_column < 0 and token_type != tokens.tk_rp)) : (column += 1) {
        offset += constraintToken(sql + offset).length;
        while (true) {
            const token = constraintToken(sql + offset);
            token_type = token.token_type;
            if (token_type == tokens.tk_comma or token_type == tokens.tk_rp) break;
            if (token_type == tokens.tk_illegal) return error.CorruptSchema;
            offset += token.length;
        }
    }
    offset += whitespaceLength(sql + offset);
    const prefix = std.mem.span(sql)[0..offset];
    return if (target_column < 0)
        std.fmt.allocPrintSentinel(allocator, "{s}, {s}{s}", .{ prefix, constraint, std.mem.span(sql + offset) }, 0)
    else
        std.fmt.allocPrintSentinel(allocator, "{s} {s}{s}", .{ prefix, constraint, std.mem.span(sql + offset) }, 0);
}

/// Source `dropConstraintFunc()`.
pub fn dropConstraintText(allocator: std.mem.Allocator, sql: [*:0]const u8, named: ?[]const u8, not_null_column: c_int) ![:0]u8 {
    var offset = try createTableBodyOffset(sql);
    var start: usize = 0;
    var end: ?usize = null;
    var column: c_int = 0;
    while (end == null) : (column += 1) {
        while (true) {
            start = offset;
            const token = constraintToken(sql + offset);
            offset += token.length;
            if (token.token_type == tokens.tk_constraint and (named != null or not_null_column == column)) {
                offset += whitespaceLength(sql + offset);
                const name_token = constraintToken(sql + offset);
                const matches = if (named) |name| try quotedConstraintNameEqual(allocator, name_token.token_type, sql[offset .. offset + name_token.length], name) else false;
                offset += name_token.length;
                const kind = constraintToken(sql + offset);
                var kind_type = kind.token_type;
                if (kind_type == tokens.tk_constraint or kind_type == tokens.tk_default or kind_type == tokens.tk_collate or kind_type == tokens.tk_comma or kind_type == tokens.tk_rp or kind_type == tokens.tk_generated or kind_type == tokens.tk_as) {
                    kind_type = tokens.tk_check;
                } else {
                    offset += kind.length;
                    offset += constraintLength(sql + offset);
                }
                if (matches or (not_null_column >= 0 and kind_type == tokens.tk_not)) {
                    if (kind_type != tokens.tk_not and kind_type != tokens.tk_check) return error.ConstraintMayNotBeDropped;
                    end = offset;
                    break;
                }
            } else if (token.token_type == tokens.tk_not and not_null_column == column) {
                end = offset + constraintLength(sql + offset);
                break;
            } else if (token.token_type == tokens.tk_rp or token.token_type == tokens.tk_illegal) return error.NoSuchConstraint else if (token.token_type == tokens.tk_comma) break;
        }
    }
    const finish = end.? + whitespaceLength(sql + end.?);
    const after = tokenizer.get(sql + finish).token_type;
    var space: []const u8 = " ";
    if (after == tokens.tk_rp or after == tokens.tk_comma) {
        space = "";
        if (start > 0 and sql[start - 1] == ',') start -= 1;
    }
    return std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ std.mem.span(sql)[0..start], space, std.mem.span(sql + finish) }, 0);
}

/// Source `alterFindCol()`.
pub fn findAlterColumn(parse: *parse_types.Parse, table: *schema.Table, token: *const parse_types.Token, output: *c_int) c_int {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    const name = db_allocator.stringNDuplicate(db, token.z, token.n) orelse return 7;
    defer db_allocator.freeNN(db, name);
    output.* = schema_analysis.columnIndex(table, name);
    if (output.* >= 0) return 0;
    var buffer: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "no such column: {s}", .{std.mem.span(name)}) catch "no such column";
    setAlterError(parse, message);
    return 1;
}

/// Source `renameEditSql()`.
pub fn editRenameSql(allocator: std.mem.Allocator, db: *types.Sqlite3, context: *RenameContext, sql: [*:0]const u8, new_name: ?[]const u8, always_quote: bool) ![:0]u8 {
    var output = try allocator.dupeZ(u8, std.mem.span(sql));
    while (nextRenameColumnToken(context)) |mapping| {
        defer db_allocator.freeNN(db, mapping);
        const start: usize = @intCast(@intFromPtr(mapping.token.z.?) - @intFromPtr(sql));
        const replacement = if (new_name) |name| blk: {
            if (!always_quote and (std.ascii.isAlphanumeric(mapping.token.z.?[0]) or mapping.token.z.?[0] == '_')) break :blk try allocator.dupe(u8, name);
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
        } else blk: {
            const temporary = try allocator.allocSentinel(u8, mapping.token.n, 0);
            @memcpy(temporary[0..mapping.token.n], mapping.token.z.?[0..mapping.token.n]);
            sqlite_string.dequote(temporary.ptr);
            const quoted = try std.fmt.allocPrint(allocator, "'{s}'", .{std.mem.span(temporary.ptr)});
            allocator.free(temporary);
            break :blk quoted;
        };
        defer allocator.free(replacement);
        const old_length: usize = mapping.token.n;
        const resized = try allocator.allocSentinel(u8, output.len - old_length + replacement.len, 0);
        @memcpy(resized[0..start], output[0..start]);
        @memcpy(resized[start .. start + replacement.len], replacement);
        @memcpy(resized[start + replacement.len ..], output[start + old_length ..]);
        allocator.free(output);
        output = resized;
    }
    return output;
}

/// Source `renameColumnParseError()`.
pub fn renameColumnParseError(allocator: std.mem.Allocator, when: []const u8, object_type: []const u8, object_name: []const u8, parse: *const parse_types.Parse) ![:0]u8 {
    const separator: []const u8 = if (when.len == 0) "" else " ";
    const detail = if (parse.zErrMsg) |message| std.mem.span(message) else "unknown schema error";
    return std.fmt.allocPrintSentinel(allocator, "error in {s} {s}{s}{s}: {s}", .{ object_type, object_name, separator, when, detail }, 0);
}
