//! Built-in analytic window-function callback bodies from `window.c`.

const std = @import("std");
const tokens = @import("../generated/tokens.zig");
const sqlite_string = @import("../string.zig");
const db_allocator = @import("db_allocator.zig");
const compiler_ownership = @import("compiler_ownership.zig");
const expression_analysis = @import("expression_analysis.zig");
const mem = @import("vdbe_mem.zig");
const parse_types = @import("parse_types.zig");
const types = @import("vdbe_types.zig");

const CallbackContext = ?*types.Context;
const CallbackArguments = ?[*]?*types.Mem;

fn argument(arguments: CallbackArguments, index: usize) *types.Mem {
    return arguments.?[index].?;
}

fn setParseError(parse: *types.Parse, message: []const u8) void {
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    db_allocator.free(db, if (parse.zErrMsg) |old| @ptrCast(old) else null);
    parse.zErrMsg = db_allocator.stringNDuplicate(db, message.ptr, message.len);
    parse.nErr += 1;
    parse.rc = 1;
}

fn aggregate(comptime T: type, context: *types.Context, size: c_int) ?*T {
    const raw = mem.aggregateContext(context, size) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Source `sqlite3WindowExtraAggFuncDepth()`.
pub fn extraAggregateDepth(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_agg_function and expression.op2 >= walker.walkerDepth) expression.op2 += 1;
    return 0;
}

/// Source `disallowAggregatesInOrderByCb()`.
pub fn disallowOrderByAggregate(walker: *parse_types.Walker, expression: *parse_types.Expr) callconv(.c) c_int {
    if (expression.op == tokens.tk_agg_function and expression.pAggInfo == null) {
        var buffer: [256]u8 = undefined;
        const name = if (expression.u.zToken) |token| std.mem.span(token) else "";
        const message = std.fmt.bufPrint(&buffer, "misuse of aggregate: {s}()", .{name}) catch "misuse of aggregate";
        setParseError(walker.pParse.?, message);
    }
    return 0;
}

/// Source `sqlite3WindowAssemble()`.
pub fn assembleWindow(parse: *types.Parse, window_optional: ?*parse_types.Window, partition: ?*parse_types.ExprList, order_by: ?*parse_types.ExprList, base: ?*const parse_types.Token) ?*parse_types.Window {
    if (window_optional) |window| {
        window.partition_by = partition;
        window.order_by = order_by;
        if (base) |token| {
            const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
            window.base_name = db_allocator.stringNDuplicate(db, token.z, token.n);
        }
        return window;
    }
    const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
    compiler_ownership.deleteExpressionList(db, partition);
    compiler_ownership.deleteExpressionList(db, order_by);
    return null;
}

/// Source `sqlite3WindowAttach()`.
pub fn attachWindow(parse: *types.Parse, expression_optional: ?*parse_types.Expr, window: *parse_types.Window) void {
    if (expression_optional) |expression| {
        expression.y.pWin = window;
        expression.flags |= parse_types.expr_flag.win_func | 0x0002_0000;
        window.owner = expression;
        if (expression.flags & 0x0000_0004 != 0 and window.frame_type != tokens.tk_filter) setParseError(parse, "DISTINCT is not supported for window functions");
    } else {
        const db: *types.Sqlite3 = @ptrCast(@alignCast(parse.db.?));
        compiler_ownership.deleteWindow(db, window);
    }
}

/// Source `sqlite3WindowLink()`.
pub fn linkWindow(select_optional: ?*parse_types.Select, window: *parse_types.Window) void {
    const select = select_optional orelse return;
    if (select.pWin == null or expression_analysis.compareWindows(null, select.pWin, window, false) == 0) {
        window.next = select.pWin;
        if (select.pWin) |first| first.owner_link = &window.next;
        select.pWin = window;
        window.owner_link = &select.pWin;
    } else if (expression_analysis.compareExpressionLists(window.partition_by, select.pWin.?.partition_by, -1) != 0) {
        select.selFlags |= 0x0200_0000;
    }
}

/// Source `sqlite3WindowUnlinkFromSelect()`.
pub fn unlinkFromSelect(window: *parse_types.Window) void {
    if (window.owner_link) |owner_link| {
        owner_link.* = window.next;
        if (window.next) |next| next.owner_link = owner_link;
        window.owner_link = null;
    }
}

/// Source `windowArgCount()`.
pub fn argumentCount(window: *parse_types.Window) c_int {
    const list = window.owner.?.x.pList;
    return if (list) |present| present.nExpr else 0;
}

/// Source `windowFind()`.
pub fn findWindow(parse: *types.Parse, first: ?*parse_types.Window, name: [*:0]const u8) ?*parse_types.Window {
    var current = first;
    while (current) |window| : (current = window.next) {
        if (sqlite_string.compareInternal(window.name.?, name) == 0) return window;
    }
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "no such window: {s}", .{name}) catch "no such window";
    setParseError(parse, message);
    return null;
}

/// Source `windowCacheFrame()`.
pub fn cacheFrame(window_initial: *parse_types.Window) bool {
    if (window_initial.start_rowid_register != 0) return true;
    var current: ?*parse_types.Window = window_initial;
    while (current) |window| : (current = window.next) {
        if (window.function) |function| {
            const name = function.zName.?;
            if (sqlite_string.compareInternal(name, "nth_value") == 0 or
                sqlite_string.compareInternal(name, "first_value") == 0 or
                sqlite_string.compareInternal(name, "lead") == 0 or
                sqlite_string.compareInternal(name, "lag") == 0) return true;
        }
    }
    return false;
}

/// Source `row_numberStepFunc()`.
pub fn rowNumberStep(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const value = aggregate(i64, context_optional.?, @sizeOf(i64)) orelse return;
    value.* += 1;
}

/// Source `row_numberValueFunc()`.
pub fn rowNumberValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const value = aggregate(i64, context, @sizeOf(i64));
    mem.resultInt64(context, if (value) |present| present.* else 0);
}

const CallCount = extern struct { value: i64, step: i64, total: i64 };

/// Source `dense_rankStepFunc()`.
pub fn denseRankStep(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const count = aggregate(CallCount, context_optional.?, @sizeOf(CallCount)) orelse return;
    count.step = 1;
}

/// Source `dense_rankValueFunc()`.
pub fn denseRankValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const count = aggregate(CallCount, context, @sizeOf(CallCount)) orelse return;
    if (count.step != 0) {
        count.value += 1;
        count.step = 0;
    }
    mem.resultInt64(context, count.value);
}

const NthValueContext = extern struct { step: i64, value: ?*types.Mem };

/// Source `nth_valueStepFunc()`.
pub fn nthValueStep(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(NthValueContext, context, @sizeOf(NthValueContext)) orelse return;
    const position_value = argument(arguments, 1);
    const position_type = mem.valueNumericType(position_value);
    var position: i64 = undefined;
    switch (position_type) {
        1 => position = mem.valueInt64(position_value),
        2 => {
            const real = mem.valueDouble(position_value);
            position = mem.realToI64(real);
            if (@as(f64, @floatFromInt(position)) != real) {
                mem.resultError(context, "second argument to nth_value must be a positive integer", -1);
                return;
            }
        },
        else => {
            mem.resultError(context, "second argument to nth_value must be a positive integer", -1);
            return;
        },
    }
    if (position <= 0) {
        mem.resultError(context, "second argument to nth_value must be a positive integer", -1);
        return;
    }
    state.step += 1;
    if (position == state.step) {
        state.value = mem.valueDuplicate(argument(arguments, 0));
        if (state.value == null) mem.resultErrorNoMem(context);
    }
}

/// Source `nth_valueFinalizeFunc()`.
pub fn nthValueFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(NthValueContext, context, 0) orelse return;
    if (state.value) |value| {
        mem.resultValue(context, value);
        mem.valueFree(value);
        state.value = null;
    }
}

/// Source `noopStepFunc()`; this placeholder must never be invoked.
pub fn noOpStep(_: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    unreachable;
}

/// Source `noopValueFunc()`.
pub fn noOpValue(_: CallbackContext) callconv(.c) void {}

/// Source `first_valueStepFunc()`.
pub fn firstValueStep(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(NthValueContext, context, @sizeOf(NthValueContext)) orelse return;
    if (state.value == null) {
        state.value = mem.valueDuplicate(argument(arguments, 0));
        if (state.value == null) mem.resultErrorNoMem(context);
    }
}

/// Source `first_valueFinalizeFunc()`.
pub fn firstValueFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(NthValueContext, context, @sizeOf(NthValueContext)) orelse return;
    if (state.value) |value| {
        mem.resultValue(context, value);
        mem.valueFree(value);
        state.value = null;
    }
}

/// Source `rankStepFunc()`.
pub fn rankStep(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const count = aggregate(CallCount, context_optional.?, @sizeOf(CallCount)) orelse return;
    count.step += 1;
    if (count.value == 0) count.value = count.step;
}

/// Source `rankValueFunc()`.
pub fn rankValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const count = aggregate(CallCount, context, @sizeOf(CallCount)) orelse return;
    mem.resultInt64(context, count.value);
    count.value = 0;
}

/// Source `percent_rankStepFunc()`.
pub fn percentRankStep(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const count = aggregate(CallCount, context_optional.?, @sizeOf(CallCount)) orelse return;
    count.total += 1;
}

/// Source `percent_rankInvFunc()`.
pub fn percentRankInverse(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const count = aggregate(CallCount, context_optional.?, @sizeOf(CallCount)) orelse return;
    count.step += 1;
}

/// Source `percent_rankValueFunc()`.
pub fn percentRankValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const count = aggregate(CallCount, context, @sizeOf(CallCount)) orelse return;
    count.value = count.step;
    const result = if (count.total > 1)
        @as(f64, @floatFromInt(count.value)) / @as(f64, @floatFromInt(count.total - 1))
    else
        0;
    mem.resultDouble(context, result);
}

/// Source `cume_distStepFunc()`.
pub fn cumulativeDistributionStep(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const count = aggregate(CallCount, context_optional.?, @sizeOf(CallCount)) orelse return;
    count.total += 1;
}

/// Source `cume_distInvFunc()`.
pub fn cumulativeDistributionInverse(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const count = aggregate(CallCount, context_optional.?, @sizeOf(CallCount)) orelse return;
    count.step += 1;
}

/// Source `cume_distValueFunc()`.
pub fn cumulativeDistributionValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const count = aggregate(CallCount, context, 0) orelse return;
    mem.resultDouble(context, @as(f64, @floatFromInt(count.step)) / @as(f64, @floatFromInt(count.total)));
}

const NtileContext = extern struct { total: i64, parameter: i64, row: i64 };

/// Source `ntileStepFunc()`.
pub fn ntileStep(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(NtileContext, context, @sizeOf(NtileContext)) orelse return;
    if (state.total == 0) {
        state.parameter = mem.valueInt64(argument(arguments, 0));
        if (state.parameter <= 0) mem.resultError(context, "argument of ntile must be a positive integer", -1);
    }
    state.total += 1;
}

/// Source `ntileInvFunc()`.
pub fn ntileInverse(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const state = aggregate(NtileContext, context_optional.?, @sizeOf(NtileContext)) orelse return;
    state.row += 1;
}

/// Source `ntileValueFunc()`.
pub fn ntileValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(NtileContext, context, @sizeOf(NtileContext)) orelse return;
    if (state.parameter <= 0) return;
    const size = @divTrunc(state.total, state.parameter);
    if (size == 0) {
        mem.resultInt64(context, state.row + 1);
    } else {
        const large = state.total - state.parameter * size;
        const small_start = large * (size + 1);
        if (state.row < small_start) {
            mem.resultInt64(context, 1 + @divTrunc(state.row, size + 1));
        } else {
            mem.resultInt64(context, 1 + large + @divTrunc(state.row - small_start, size));
        }
    }
}

const LastValueContext = extern struct { value: ?*types.Mem, count: c_int };

/// Source `last_valueStepFunc()`.
pub fn lastValueStep(context_optional: CallbackContext, _: c_int, arguments: CallbackArguments) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(LastValueContext, context, @sizeOf(LastValueContext)) orelse return;
    mem.valueFree(state.value);
    state.value = mem.valueDuplicate(argument(arguments, 0));
    if (state.value == null) mem.resultErrorNoMem(context) else state.count += 1;
}

/// Source `last_valueInvFunc()`.
pub fn lastValueInverse(context_optional: CallbackContext, _: c_int, _: CallbackArguments) callconv(.c) void {
    const state = aggregate(LastValueContext, context_optional.?, @sizeOf(LastValueContext)) orelse return;
    state.count -= 1;
    if (state.count == 0) {
        mem.valueFree(state.value);
        state.value = null;
    }
}

/// Source `last_valueValueFunc()`.
pub fn lastValueValue(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(LastValueContext, context, 0) orelse return;
    if (state.value) |value| mem.resultValue(context, value);
}

/// Source `last_valueFinalizeFunc()`.
pub fn lastValueFinalize(context_optional: CallbackContext) callconv(.c) void {
    const context = context_optional.?;
    const state = aggregate(LastValueContext, context, @sizeOf(LastValueContext)) orelse return;
    if (state.value) |value| {
        mem.resultValue(context, value);
        mem.valueFree(value);
        state.value = null;
    }
}
