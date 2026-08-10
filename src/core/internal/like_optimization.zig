//! Per-connection LIKE registration and planner recognition from `func.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const sqlite_string = @import("../string.zig");
const expression_analysis = @import("expression_analysis.zig");
const schema_analysis = @import("schema_analysis.zig");
const function_registry = @import("function_registry.zig");
const parse_types = @import("parse_types.zig");
const pattern = @import("pattern.zig");
const types = @import("vdbe_types.zig");

/// Source `sqlite3ExprIsLikeOperator()`.
pub fn likeOperator(expression: *const parse_types.Expr) u8 {
    const operators = [_]struct { name: [*:0]const u8, value: u8 }{
        .{ .name = "match", .value = 64 },
        .{ .name = "glob", .value = 66 },
        .{ .name = "like", .value = 65 },
        .{ .name = "regexp", .value = 67 },
    };
    for (operators) |operator| {
        if (sqlite_string.compareInternal(expression.u.zToken.?, operator.name) == 0) return operator.value;
    }
    return 0;
}

/// Source `sqlite3RegisterLikeFunctions()`.
pub fn registerLikeFunctions(db: *types.Sqlite3, case_sensitive: bool) void {
    const info = if (case_sensitive) &pattern.like_sensitive_info else &pattern.like_info;
    const like_flags = types.function_flag.like | if (case_sensitive) types.function_flag.case_sensitive else 0;
    for ([_]c_int{ 2, 3 }) |argument_count| {
        const definition = function_registry.findFunction(db, "like", argument_count, 1, true) orelse continue;
        definition.pUserData = @ptrCast(@constCast(info));
        definition.xSFunc = pattern.like;
        definition.xFinalize = null;
        definition.xValue = null;
        definition.xInverse = null;
        definition.funcFlags |= like_flags;
        definition.funcFlags &= ~types.function_flag.unsafe;
    }
}

/// Source `sqlite3IsLikeFunction()`.
pub fn isLikeFunction(db: *types.Sqlite3, expression: *parse_types.Expr, no_case: *c_int, wildcards: *[4]u8) bool {
    if (!expression.usesList()) return false;
    const expressions = expression.x.pList orelse return false;
    const argument_count = expressions.nExpr;
    const definition = function_registry.findFunction(db, expression.u.zToken.?, argument_count, 1, false) orelse return false;
    if (definition.funcFlags & types.function_flag.like == 0) return false;
    const info: *const pattern.CompareInfo = @ptrCast(@alignCast(definition.pUserData.?));
    wildcards[0] = info.match_all;
    wildcards[1] = info.match_one;
    wildcards[2] = info.match_set;
    if (argument_count < 3) {
        wildcards[3] = 0;
    } else {
        const escape = expressions.items()[2].pExpr.?;
        if (escape.op != tokens.tk_string) return false;
        const text = escape.u.zToken orelse return false;
        if (text[0] == 0 or text[1] != 0 or text[0] == wildcards[0] or text[0] == wildcards[1]) return false;
        wildcards[3] = text[0];
    }
    no_case.* = @intFromBool(definition.funcFlags & types.function_flag.case_sensitive == 0);
    return true;
}

pub const LikePrefix = struct {
    expression: *parse_types.Expr,
    complete: bool,
    no_case: bool,
};

/// Source `isLikeOrGlob()`: recognize a literal LIKE/GLOB prefix that can
/// safely become planner range bounds, removing escape bytes in the copy.
pub fn likeOrGlobPrefix(parse: *parse_types.Parse, node: *parse_types.Expr) ?LikePrefix {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    var no_case: c_int = 0;
    var wildcards = [_]u8{0} ** 4;
    if (!isLikeFunction(db, node, &no_case, &wildcards)) return null;
    const arguments = node.x.pList orelse return null;
    const left = arguments.items()[1].pExpr orelse return null;
    if (left.op != tokens.tk_column or expression_analysis.expressionAffinity(left) != schema_analysis.affinity.text) return null;
    const right = expression_analysis.skipCollation(arguments.items()[0].pExpr) orelse return null;
    if (right.op != tokens.tk_string) return null;
    const pattern_text = right.u.zToken orelse return null;

    var prefix_bytes: usize = 0;
    while (pattern_text[prefix_bytes] != 0 and pattern_text[prefix_bytes] != wildcards[0] and
        pattern_text[prefix_bytes] != wildcards[1] and pattern_text[prefix_bytes] != wildcards[2])
    {
        const byte = pattern_text[prefix_bytes];
        prefix_bytes += 1;
        if (byte == wildcards[3] and pattern_text[prefix_bytes] != 0 and pattern_text[prefix_bytes] < 0x80) {
            prefix_bytes += 1;
        } else if (byte >= 0x80) {
            const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch {
                prefix_bytes -= 1;
                break;
            };
            var continuation: usize = 1;
            while (continuation < sequence_length and pattern_text[prefix_bytes] & 0xc0 == 0x80) : (continuation += 1) {
                prefix_bytes += 1;
            }
            if (continuation != sequence_length) {
                prefix_bytes -= 1;
                break;
            }
        }
    }
    if (prefix_bytes == 0 or (prefix_bytes == 1 and pattern_text[0] == wildcards[3]) or pattern_text[prefix_bytes - 1] == 0xff) return null;
    const complete = pattern_text[prefix_bytes] == wildcards[0] and pattern_text[prefix_bytes + 1] == 0;
    const prefix = expression_analysis.newExpression(db, @intCast(tokens.tk_string), pattern_text) orelse return null;
    const output: [*]u8 = @ptrCast(prefix.u.zToken.?);
    var source: usize = 0;
    var destination: usize = 0;
    while (source < prefix_bytes) : (source += 1) {
        if (output[source] == wildcards[3]) source += 1;
        output[destination] = output[source];
        destination += 1;
    }
    output[destination] = 0;
    return .{ .expression = prefix, .complete = complete, .no_case = no_case != 0 };
}
