//! Built-in function hash registration and lookup from `callback.c` and `func.c`.

const std = @import("std");
const sqlite_string = @import("../string.zig");
const db_allocator = @import("db_allocator.zig");
const functions = @import("builtin_functions.zig");
const windows = @import("window_functions.zig");
const pattern = @import("pattern.zig");
const dates = @import("date_functions.zig");
const json = @import("json_functions.zig");
const types = @import("vdbe_types.zig");

const Scalar = *const fn (?*types.Context, c_int, ?[*]?*types.Mem) callconv(.c) void;
const Final = *const fn (?*types.Context) callconv(.c) void;
const base_scalar_flags = types.function_flag.builtin | types.function_flag.constant | 1;
const base_volatile_flags = types.function_flag.builtin | 1;
const base_aggregate_flags = types.function_flag.builtin | 1;

fn scalar(name: [*:0]const u8, argument_count: i16, callback: Scalar, flags: u32) types.FuncDef {
    return .{
        .nArg = argument_count,
        .funcFlags = flags,
        .pUserData = null,
        .pNext = null,
        .xSFunc = callback,
        .xFinalize = null,
        .xValue = null,
        .xInverse = null,
        .zName = name,
        .u = .{ .pHash = null },
    };
}

fn scalarWithPointer(name: [*:0]const u8, argument_count: i16, callback: Scalar, flags: u32, user_data: ?*const anyopaque) types.FuncDef {
    var definition = scalar(name, argument_count, callback, flags);
    definition.pUserData = if (user_data) |pointer| @constCast(pointer) else null;
    return definition;
}

fn scalarWithUserData(name: [*:0]const u8, argument_count: i16, callback: Scalar, flags: u32, user_data: usize) types.FuncDef {
    var definition = scalar(name, argument_count, callback, flags);
    definition.pUserData = if (user_data == 0) null else @ptrFromInt(user_data);
    return definition;
}

fn inlineFunction(name: [*:0]const u8, argument_count: i16, function_id: usize) types.FuncDef {
    return .{
        .nArg = argument_count,
        .funcFlags = base_scalar_flags | types.function_flag.inline_,
        .pUserData = @ptrFromInt(function_id),
        .pNext = null,
        .xSFunc = null,
        .xFinalize = null,
        .xValue = null,
        .xInverse = null,
        .zName = name,
        .u = .{ .pHash = null },
    };
}

fn aggregateWithUserData(
    name: [*:0]const u8,
    argument_count: i16,
    step: Scalar,
    final: Final,
    value: Final,
    inverse: ?Scalar,
    flags: u32,
    user_data: usize,
) types.FuncDef {
    var definition = aggregate(name, argument_count, step, final, value, inverse, flags);
    definition.pUserData = if (user_data == 0) null else @ptrFromInt(user_data);
    return definition;
}

fn aggregate(
    name: [*:0]const u8,
    argument_count: i16,
    step: Scalar,
    final: Final,
    value: Final,
    inverse: ?Scalar,
    flags: u32,
) types.FuncDef {
    return .{
        .nArg = argument_count,
        .funcFlags = base_aggregate_flags | flags,
        .pUserData = null,
        .pNext = null,
        .xSFunc = step,
        .xFinalize = final,
        .xValue = value,
        .xInverse = inverse,
        .zName = name,
        .u = .{ .pHash = null },
    };
}

var ported_definitions = [_]types.FuncDef{
    inlineFunction("iif", -4, types.inline_function.iif),
    inlineFunction("if", -4, types.inline_function.iif),
    scalarWithUserData("ltrim", 1, functions.trim, base_scalar_flags, 1),
    scalarWithUserData("ltrim", 2, functions.trim, base_scalar_flags, 1),
    scalarWithUserData("rtrim", 1, functions.trim, base_scalar_flags, 2),
    scalarWithUserData("rtrim", 2, functions.trim, base_scalar_flags, 2),
    scalarWithUserData("trim", 1, functions.trim, base_scalar_flags, 3),
    scalarWithUserData("trim", 2, functions.trim, base_scalar_flags, 3),
    scalarWithUserData("min", -3, functions.scalarMinMax, base_scalar_flags | types.function_flag.need_collation, 0),
    aggregateWithUserData("min", 1, functions.minMaxStep, functions.minMaxFinalize, functions.minMaxValue, null, types.function_flag.need_collation | types.function_flag.min_max | types.function_flag.any_order, 0),
    scalarWithUserData("max", -3, functions.scalarMinMax, base_scalar_flags | types.function_flag.need_collation, 1),
    aggregateWithUserData("max", 1, functions.minMaxStep, functions.minMaxFinalize, functions.minMaxValue, null, types.function_flag.need_collation | types.function_flag.min_max | types.function_flag.any_order, 1),
    scalar("nullif", 2, functions.nullIf, base_scalar_flags | types.function_flag.need_collation),
    scalar("typeof", 1, functions.typeOf, base_scalar_flags | types.function_flag.type_of),
    scalar("subtype", 1, functions.subtype, base_scalar_flags | types.function_flag.type_of | types.function_flag.subtype_argument),
    scalar("length", 1, functions.length, base_scalar_flags | types.function_flag.length),
    scalar("unicode", 1, functions.unicode, base_scalar_flags),
    scalar("instr", 2, functions.instruction, base_scalar_flags),
    scalar("printf", -1, functions.printFormat, base_scalar_flags),
    scalar("format", -1, functions.printFormat, base_scalar_flags),
    scalar("octet_length", 1, functions.byteLength, base_scalar_flags | types.function_flag.byte_length),
    scalar("abs", 1, functions.absolute, base_scalar_flags),
    scalar("round", 1, functions.round, base_scalar_flags),
    scalar("round", 2, functions.round, base_scalar_flags),
    scalar("upper", 1, functions.upper, base_scalar_flags),
    scalar("lower", 1, functions.lower, base_scalar_flags),
    scalar("char", -1, functions.characters, base_scalar_flags),
    scalar("unistr", 1, functions.unicodeEscapes, base_scalar_flags),
    scalarWithUserData("quote", 1, functions.quote, base_scalar_flags, 0),
    scalarWithUserData("unistr_quote", 1, functions.quote, base_scalar_flags, 1),
    scalar("hex", 1, functions.hexadecimal, base_scalar_flags),
    scalar("unhex", 1, functions.unhex, base_scalar_flags),
    scalar("unhex", 2, functions.unhex, base_scalar_flags),
    scalar("concat", -3, functions.concatenate, base_scalar_flags),
    scalar("concat_ws", -4, functions.concatenateWithSeparator, base_scalar_flags),
    scalar("replace", 3, functions.replace, base_scalar_flags),
    scalar("substr", 2, functions.substring, base_scalar_flags),
    scalar("substr", 3, functions.substring, base_scalar_flags),
    scalar("substring", 2, functions.substring, base_scalar_flags),
    scalar("substring", 3, functions.substring, base_scalar_flags),
    scalar("random", 0, functions.randomInteger, base_volatile_flags),
    scalar("randomblob", 1, functions.randomBlob, base_volatile_flags),
    scalar("sqlite_version", 0, functions.version, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("sqlite_source_id", 0, functions.sourceId, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("sqlite_compileoption_used", 1, functions.compileOptionUsed, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("sqlite_compileoption_get", 1, functions.compileOptionGet, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("sqlite_log", 2, functions.errorLog, base_scalar_flags),
    scalar("last_insert_rowid", 0, functions.lastInsertRowid, base_volatile_flags),
    scalar("changes", 0, functions.changes, base_volatile_flags),
    scalar("total_changes", 0, functions.totalChanges, base_volatile_flags),
    scalar("zeroblob", 1, functions.zeroBlob, base_scalar_flags),
    scalarWithPointer("glob", 2, pattern.like, base_scalar_flags | types.function_flag.like | types.function_flag.case_sensitive, @ptrCast(&pattern.glob_info)),
    scalarWithPointer("like", 2, pattern.like, base_scalar_flags | types.function_flag.like, @ptrCast(&pattern.like_info)),
    scalarWithPointer("like", 3, pattern.like, base_scalar_flags | types.function_flag.like, @ptrCast(&pattern.like_info)),
    scalarWithPointer("ceil", 1, functions.ceiling, base_scalar_flags, @ptrCast(&functions.ceilingValue)),
    scalarWithPointer("ceiling", 1, functions.ceiling, base_scalar_flags, @ptrCast(&functions.ceilingValue)),
    scalarWithPointer("floor", 1, functions.ceiling, base_scalar_flags, @ptrCast(&functions.floorValue)),
    scalarWithUserData("ln", 1, functions.logarithm, base_scalar_flags, 0),
    scalarWithUserData("log", 1, functions.logarithm, base_scalar_flags, 1),
    scalarWithUserData("log10", 1, functions.logarithm, base_scalar_flags, 1),
    scalarWithUserData("log2", 1, functions.logarithm, base_scalar_flags, 2),
    scalarWithUserData("log", 2, functions.logarithm, base_scalar_flags, 0),
    scalarWithPointer("exp", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.exponentialValue)),
    scalarWithPointer("pow", 2, functions.binaryMath, base_scalar_flags, @ptrCast(&functions.powerValue)),
    scalarWithPointer("power", 2, functions.binaryMath, base_scalar_flags, @ptrCast(&functions.powerValue)),
    scalarWithPointer("mod", 2, functions.binaryMath, base_scalar_flags, @ptrCast(&functions.moduloValue)),
    scalarWithPointer("acos", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.arcCosineValue)),
    scalarWithPointer("asin", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.arcSineValue)),
    scalarWithPointer("atan", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.arcTangentValue)),
    scalarWithPointer("atan2", 2, functions.binaryMath, base_scalar_flags, @ptrCast(&functions.arcTangent2Value)),
    scalarWithPointer("cos", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.cosineValue)),
    scalarWithPointer("sin", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.sineValue)),
    scalarWithPointer("tan", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.tangentValue)),
    scalarWithPointer("cosh", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.hyperbolicCosineValue)),
    scalarWithPointer("sinh", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.hyperbolicSineValue)),
    scalarWithPointer("tanh", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.hyperbolicTangentValue)),
    scalarWithPointer("acosh", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.inverseHyperbolicCosineValue)),
    scalarWithPointer("asinh", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.inverseHyperbolicSineValue)),
    scalarWithPointer("atanh", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.inverseHyperbolicTangentValue)),
    scalarWithPointer("sqrt", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.squareRootValue)),
    scalarWithPointer("radians", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.degreesToRadians)),
    scalarWithPointer("degrees", 1, functions.unaryMath, base_scalar_flags, @ptrCast(&functions.radiansToDegrees)),
    scalar("pi", 0, functions.pi, base_scalar_flags),
    scalar("sign", 1, functions.sign, base_scalar_flags),
    scalar("julianday", -1, dates.julianDay, base_scalar_flags | types.function_flag.slow_change),
    scalar("unixepoch", -1, dates.unixEpoch, base_scalar_flags | types.function_flag.slow_change),
    scalar("date", -1, dates.calendarDate, base_scalar_flags | types.function_flag.slow_change),
    scalar("time", -1, dates.time, base_scalar_flags | types.function_flag.slow_change),
    scalar("datetime", -1, dates.dateTime, base_scalar_flags | types.function_flag.slow_change),
    scalar("strftime", -1, dates.strftime, base_scalar_flags | types.function_flag.slow_change),
    scalar("timediff", 2, dates.timeDifference, base_scalar_flags | types.function_flag.slow_change),
    scalar("current_time", 0, dates.currentTime, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("current_date", 0, dates.currentDate, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("current_timestamp", 0, dates.currentTimestamp, types.function_flag.builtin | types.function_flag.slow_change | 1),
    scalar("json", 1, json.removeFunction, base_scalar_flags),
    scalar("json_array", -1, json.arrayFunction, base_scalar_flags | types.function_flag.subtype_argument),
    scalar("json_array_length", 1, json.arrayLengthFunction, base_scalar_flags),
    scalar("json_array_length", 2, json.arrayLengthFunction, base_scalar_flags),
    scalar("json_error_position", 1, json.errorPositionFunction, base_scalar_flags),
    scalar("json_extract", -1, json.extractFunction, base_scalar_flags),
    scalar("json_object", -1, json.objectFunction, base_scalar_flags | types.function_flag.subtype_argument),
    scalar("json_patch", 2, json.patchFunction, base_scalar_flags),
    scalar("json_pretty", 1, json.prettyFunction, base_scalar_flags),
    scalar("json_pretty", 2, json.prettyFunction, base_scalar_flags),
    scalar("json_quote", 1, json.quoteFunction, base_scalar_flags | types.function_flag.subtype_argument),
    scalar("json_remove", -1, json.removeFunction, base_scalar_flags),
    scalar("json_replace", -1, json.replaceFunction, base_scalar_flags | types.function_flag.subtype_argument),
    scalar("json_set", -1, json.setFunction, base_scalar_flags | types.function_flag.subtype_argument),
    scalar("json_type", 1, json.typeFunction, base_scalar_flags),
    scalar("json_type", 2, json.typeFunction, base_scalar_flags),
    scalar("json_valid", 1, json.validFunction, base_scalar_flags),
    scalar("json_valid", 2, json.validFunction, base_scalar_flags),
    aggregate("json_group_array", 1, json.arrayAggregateStep, json.arrayAggregateFinal, json.arrayAggregateValue, json.groupInverse, types.function_flag.subtype_argument),
    aggregate("json_group_object", 2, json.objectAggregateStep, json.objectAggregateFinal, json.objectAggregateValue, json.groupInverse, types.function_flag.subtype_argument),
    aggregate("sum", 1, functions.sumStep, functions.sumFinalize, functions.sumFinalize, functions.sumInverse, 0),
    aggregate("total", 1, functions.sumStep, functions.totalFinalize, functions.totalFinalize, functions.sumInverse, 0),
    aggregate("avg", 1, functions.sumStep, functions.averageFinalize, functions.averageFinalize, functions.sumInverse, 0),
    aggregate("count", 0, functions.countStep, functions.countFinalize, functions.countFinalize, functions.countInverse, types.function_flag.count | types.function_flag.any_order),
    aggregate("count", 1, functions.countStep, functions.countFinalize, functions.countFinalize, functions.countInverse, types.function_flag.any_order),
    aggregate("group_concat", 1, functions.groupConcatStep, functions.groupConcatFinalize, functions.groupConcatValue, functions.groupConcatInverse, 0),
    aggregate("group_concat", 2, functions.groupConcatStep, functions.groupConcatFinalize, functions.groupConcatValue, functions.groupConcatInverse, 0),
    aggregate("string_agg", 2, functions.groupConcatStep, functions.groupConcatFinalize, functions.groupConcatValue, functions.groupConcatInverse, 0),
    aggregateWithUserData("median", 1, functions.percentileStep, functions.percentileFinal, functions.percentileValue, functions.percentileInverse, 0, 0),
    aggregateWithUserData("percentile", 2, functions.percentileStep, functions.percentileFinal, functions.percentileValue, functions.percentileInverse, 0, 2),
    aggregateWithUserData("percentile_cont", 2, functions.percentileStep, functions.percentileFinal, functions.percentileValue, functions.percentileInverse, 0, 0),
    aggregateWithUserData("percentile_disc", 2, functions.percentileStep, functions.percentileFinal, functions.percentileValue, functions.percentileInverse, 0, 1),
    aggregate("row_number", 0, windows.rowNumberStep, windows.rowNumberValue, windows.rowNumberValue, windows.noOpStep, types.function_flag.window),
    aggregate("dense_rank", 0, windows.denseRankStep, windows.denseRankValue, windows.denseRankValue, windows.noOpStep, types.function_flag.window),
    aggregate("nth_value", 2, windows.nthValueStep, windows.nthValueFinalize, windows.noOpValue, windows.noOpStep, types.function_flag.window),
    aggregate("first_value", 1, windows.firstValueStep, windows.firstValueFinalize, windows.noOpValue, windows.noOpStep, types.function_flag.window),
    aggregate("rank", 0, windows.rankStep, windows.rankValue, windows.rankValue, windows.noOpStep, types.function_flag.window),
    aggregate("percent_rank", 0, windows.percentRankStep, windows.percentRankValue, windows.percentRankValue, windows.percentRankInverse, types.function_flag.window),
    aggregate("cume_dist", 0, windows.cumulativeDistributionStep, windows.cumulativeDistributionValue, windows.cumulativeDistributionValue, windows.cumulativeDistributionInverse, types.function_flag.window),
    aggregate("ntile", 1, windows.ntileStep, windows.ntileValue, windows.ntileValue, windows.ntileInverse, types.function_flag.window),
    aggregate("last_value", 1, windows.lastValueStep, windows.lastValueFinalize, windows.lastValueValue, windows.lastValueInverse, types.function_flag.window),
};

/// Source `matchQuality()`.
pub fn matchQuality(definition: *const types.FuncDef, requested_arguments: c_int, encoding: u8) c_int {
    if (definition.nArg != requested_arguments) {
        if (requested_arguments == -2) return if (definition.xSFunc == null) 0 else 6;
        if (definition.nArg >= 0) return 0;
        if (definition.nArg < -2 and requested_arguments < -2 - definition.nArg) return 0;
    }
    var match: c_int = if (definition.nArg == requested_arguments) 4 else 1;
    if (encoding == definition.funcFlags & types.function_flag.encoding_mask) {
        match += 2;
    } else if (encoding & definition.funcFlags & 2 != 0) {
        match += 1;
    }
    return match;
}

/// Source `sqlite3FunctionSearch()`.
pub fn functionSearch(hash: usize, name: [*:0]const u8) ?*types.FuncDef {
    var definition = types.builtin_functions.a[hash];
    while (definition) |present| : (definition = present.u.pHash) {
        if (sqlite_string.compareInternal(present.zName.?, name) == 0) return present;
    }
    return null;
}

/// Source `sqlite3InsertBuiltinFuncs()`.
pub fn insertBuiltinFunctions(definitions: []types.FuncDef) void {
    for (definitions) |*definition| {
        const name = definition.zName.?;
        const name_length = std.mem.len(name);
        const hash = types.functionHash(name[0], name_length);
        if (functionSearch(hash, name)) |other| {
            definition.pNext = other.pNext;
            other.pNext = definition;
        } else {
            definition.pNext = null;
            definition.u.pHash = types.builtin_functions.a[hash];
            types.builtin_functions.a[hash] = definition;
        }
    }
}

/// Source `sqlite3FindFunction()`.
pub fn findFunction(
    db: *types.Sqlite3,
    name: [*:0]const u8,
    argument_count: c_int,
    encoding: u8,
    create: bool,
) ?*types.FuncDef {
    const name_length = std.mem.len(name);
    var best: ?*types.FuncDef = null;
    var best_score: c_int = 0;
    var definition: ?*types.FuncDef = if (db.aFunc.find(name)) |pointer| @ptrCast(@alignCast(pointer)) else null;
    while (definition) |present| : (definition = present.pNext) {
        const score = matchQuality(present, argument_count, encoding);
        if (score > best_score) {
            best = present;
            best_score = score;
        }
    }
    if (!create and (best == null or db.mDbFlags & types.database_flag.prefer_builtin != 0)) {
        best_score = 0;
        const hash = types.functionHash(sqlite_string.foldByte(name[0]), name_length);
        definition = functionSearch(hash, name);
        while (definition) |present| : (definition = present.pNext) {
            const score = matchQuality(present, argument_count, encoding);
            if (score > best_score) {
                best = present;
                best_score = score;
            }
        }
    }
    if (create and best_score < 6) {
        const raw = db_allocator.mallocZero(db, @sizeOf(types.FuncDef) + name_length + 1) orelse return null;
        const created: *types.FuncDef = @ptrCast(@alignCast(raw));
        const name_storage: [*]u8 = @ptrFromInt(@intFromPtr(created) + @sizeOf(types.FuncDef));
        @memcpy(name_storage[0 .. name_length + 1], name[0 .. name_length + 1]);
        for (name_storage[0..name_length]) |*byte| {
            byte.* = sqlite_string.foldByte(byte.*);
        }
        created.zName = @ptrCast(name_storage);
        created.nArg = @intCast(argument_count);
        created.funcFlags = encoding;
        const replaced = db.aFunc.insert(db_allocator.stdAllocator(db), created.zName.?, created);
        if (replaced == created) {
            db_allocator.freeNN(db, created);
            _ = db_allocator.oomFault(db);
            return null;
        }
        created.pNext = if (replaced) |other| @ptrCast(@alignCast(other)) else null;
        best = created;
    }
    const result = best orelse return null;
    return if (result.xSFunc != null or create) result else null;
}

var registered = false;

/// Installs the source definitions that now have production Zig bodies.
pub fn registerPortedBuiltinFunctions() void {
    if (registered) return;
    insertBuiltinFunctions(&ported_definitions);
    registered = true;
}
