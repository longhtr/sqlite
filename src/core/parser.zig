//! Native Lemon parser state machine generated from the pinned SQLite grammar.
//!
//! This module currently recognizes grammar and exercises the exact generated
//! transition/reduction tables. The exact semantic-value union, generated
//! destructor routing, and initial typed action partitions exist, but the
//! parser is not yet connected to the SQLite compiler.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
pub const tables = @import("generated/parser_tables.zig");
pub const parse_types = @import("internal/parse_types.zig");
pub const SemanticValue = parse_types.SemanticValue;

const StackEntry = struct {
    state: u16,
    symbol: u16,
    minor: SemanticValue,
};

pub const SavepointOperation = enum { begin, release, rollback };

pub const table_flag = parse_types.table_flag;

pub const conflict_action = parse_types.conflict_action;
pub const sort_order = parse_types.sort_order;
pub const foreign_action = parse_types.foreign_action;
pub const select_flag = parse_types.select_flag;
pub const join_type = parse_types.join_type;
pub const materialized = parse_types.materialized;

pub const Action = union(enum) {
    explain: u8,
    finish_coding,
    begin_transaction: c_int,
    end_transaction: u16,
    savepoint: struct {
        operation: SavepointOperation,
        /// Borrowed from the SQL input and valid only for the callback.
        name: parse_types.Token,
    },
    start_table: struct {
        name: parse_types.Token,
        database: parse_types.Token,
        is_temporary: bool,
        if_not_exists: bool,
    },
    disable_lookaside,
    end_table: struct {
        constraint_start: parse_types.Token,
        end: parse_types.Token,
        flags: u32,
        select: ?*parse_types.Select,
    },
    unknown_table_option: parse_types.Token,
    add_column: struct {
        name: parse_types.Token,
        type_name: parse_types.Token,
    },
    set_constraint_name: parse_types.Token,
    clear_constraint_name,
    add_default: struct {
        /// Owned by the parser and valid only for the callback.
        expression: ?*parse_types.Expr,
        /// Exact SQL spelling passed as zStart/zEnd by SQLite.
        source: parse_types.Token,
    },
    add_not_null: c_int,
    add_primary_key: struct {
        columns: ?*parse_types.ExprList,
        conflict: c_int,
        autoincrement: bool,
        order: c_int,
    },
    create_unique: struct {
        columns: ?*parse_types.ExprList,
        conflict: c_int,
    },
    create_foreign_key: struct {
        from_columns: ?*parse_types.ExprList,
        table: parse_types.Token,
        to_columns: ?*parse_types.ExprList,
        actions: c_int,
    },
    defer_foreign_key: bool,
    add_collation: parse_types.Token,
    add_check: struct {
        /// Ownership transfers to the action callback.
        expression: ?*parse_types.Expr,
        open: parse_types.Token,
        close: parse_types.Token,
    },
    add_generated: struct {
        /// Ownership transfers to the action callback.
        expression: ?*parse_types.Expr,
        storage: ?parse_types.Token,
    },
    select_statement: ?*parse_types.Select,
    drop_table: struct {
        source: ?*parse_types.SrcList,
        is_view: bool,
        if_exists: bool,
    },
    add_returning: ?*parse_types.ExprList,
    delete_from: struct {
        source: ?*parse_types.SrcList,
        where: ?*parse_types.Expr,
    },
    update: struct {
        source: ?*parse_types.SrcList,
        changes: ?*parse_types.ExprList,
        from: ?*parse_types.SrcList,
        where: ?*parse_types.Expr,
        conflict: c_int,
    },
    insert: struct {
        source: ?*parse_types.SrcList,
        select: ?*parse_types.Select,
        columns: ?*parse_types.IdList,
        conflict: c_int,
        default_values: bool,
        upsert: ?*parse_types.Upsert,
    },
    create_index: struct {
        name: parse_types.Token,
        database: parse_types.Token,
        table: parse_types.Token,
        columns: ?*parse_types.ExprList,
        where: ?*parse_types.Expr,
        conflict: c_int,
        if_not_exists: bool,
    },
    drop_index: struct {
        source: ?*parse_types.SrcList,
        if_exists: bool,
    },
    vacuum: struct {
        schema: ?parse_types.Token,
        into: ?*parse_types.Expr,
    },
    pragma: struct {
        name: parse_types.Token,
        database: parse_types.Token,
        value: ?parse_types.Token,
        negative: bool,
    },
    attach: struct {
        filename: ?*parse_types.Expr,
        schema: ?*parse_types.Expr,
        key: ?*parse_types.Expr,
    },
    detach: ?*parse_types.Expr,
    reindex: struct { name: ?parse_types.Token, database: ?parse_types.Token },
    analyze: struct { name: ?parse_types.Token, database: ?parse_types.Token },
    alter_rename_table: struct { source: ?*parse_types.SrcList, new_name: parse_types.Token },
    alter_drop_column: struct { source: ?*parse_types.SrcList, column: parse_types.Token },
    alter_rename_column: struct { source: ?*parse_types.SrcList, old: parse_types.Token, new: parse_types.Token },
    alter_drop_constraint: struct { source: ?*parse_types.SrcList, name: parse_types.Token },
    alter_drop_not_null: struct { source: ?*parse_types.SrcList, column: parse_types.Token },
    alter_set_not_null: struct { source: ?*parse_types.SrcList, column: parse_types.Token, conflict: c_int },
    alter_begin_add_column: struct {
        source: ?*parse_types.SrcList,
        column: parse_types.Token,
        type_name: parse_types.Token,
    },
    alter_finish_add_column: parse_types.Token,
    alter_add_check: struct {
        source: ?*parse_types.SrcList,
        name: ?parse_types.Token,
        expression: ?*parse_types.Expr,
        open: parse_types.Token,
        close: parse_types.Token,
    },
    create_view: struct {
        name: parse_types.Token,
        database: parse_types.Token,
        columns: ?*parse_types.ExprList,
        select: ?*parse_types.Select,
        is_temporary: bool,
        if_not_exists: bool,
    },
    drop_trigger: struct { source: ?*parse_types.SrcList, if_exists: bool },
    vtab_begin: struct {
        name: parse_types.Token,
        database: parse_types.Token,
        module: parse_types.Token,
        if_not_exists: bool,
    },
    vtab_finish: ?parse_types.Token,
    vtab_arg_init,
    vtab_arg_extend: parse_types.Token,
};

pub const ActionCallback = *const fn (context: ?*anyopaque, action: Action) void;

/// Source-level expression constructors used by connected Lemon actions.
/// Constructors that attach children consume both child pointers even when
/// they return null. The destroy callback must accept null.
pub const ExpressionHooks = struct {
    context: ?*anyopaque,
    token_expr: *const fn (?*anyopaque, u16, parse_types.Token) ?*parse_types.Expr,
    integer_expr: *const fn (?*anyopaque, parse_types.Token) ?*parse_types.Expr,
    function_expr: *const fn (?*anyopaque, parse_types.Token, ?*parse_types.ExprList, c_int) ?*parse_types.Expr,
    ordered_function_expr: *const fn (?*anyopaque, parse_types.Token, ?*parse_types.ExprList, c_int, ?*parse_types.ExprList) ?*parse_types.Expr,
    variable_expr: *const fn (?*anyopaque, parse_types.Token, bool) ?*parse_types.Expr,
    qnumber_expr: *const fn (?*anyopaque, parse_types.Token) ?*parse_types.Expr,
    bare_expr: *const fn (?*anyopaque, u16) ?*parse_types.Expr,
    p_expr: *const fn (?*anyopaque, u16, ?*parse_types.Expr, ?*parse_types.Expr) ?*parse_types.Expr,
    and_expr: *const fn (?*anyopaque, ?*parse_types.Expr, ?*parse_types.Expr) ?*parse_types.Expr,
    collate_expr: *const fn (?*anyopaque, ?*parse_types.Expr, parse_types.Token) ?*parse_types.Expr,
    cast_expr: *const fn (?*anyopaque, ?*parse_types.Expr, parse_types.Token) ?*parse_types.Expr,
    is_null_expr: *const fn (?*anyopaque, u16, ?*parse_types.Expr) ?*parse_types.Expr,
    is_expr: *const fn (?*anyopaque, u16, ?*parse_types.Expr, ?*parse_types.Expr) ?*parse_types.Expr,
    between_expr: *const fn (?*anyopaque, ?*parse_types.Expr, ?*parse_types.ExprList, bool) ?*parse_types.Expr,
    in_list_expr: *const fn (?*anyopaque, ?*parse_types.Expr, ?*parse_types.ExprList, bool) ?*parse_types.Expr,
    select_expr: *const fn (?*anyopaque, u16, ?*parse_types.Select) ?*parse_types.Expr,
    in_select_expr: *const fn (?*anyopaque, ?*parse_types.Expr, ?*parse_types.Select, bool) ?*parse_types.Expr,
    case_expr: *const fn (?*anyopaque, ?*parse_types.Expr, ?*parse_types.ExprList, ?*parse_types.Expr) ?*parse_types.Expr,
    vector_expr: *const fn (?*anyopaque, ?*parse_types.ExprList) ?*parse_types.Expr,
    like_expr: *const fn (?*anyopaque, parse_types.Token, ?*parse_types.Expr, ?*parse_types.Expr, ?*parse_types.Expr, bool) ?*parse_types.Expr,
    in_table_expr: *const fn (?*anyopaque, ?*parse_types.Expr, parse_types.Token, parse_types.Token, ?*parse_types.ExprList, bool) ?*parse_types.Expr,
    raise_expr: *const fn (?*anyopaque, c_int, ?*parse_types.Expr) ?*parse_types.Expr,
    rename_token_remap: *const fn (?*anyopaque, *parse_types.Expr) void,
    id_to_true_false: *const fn (?*anyopaque, *parse_types.Expr) void,
    set_error_offset: *const fn (?*anyopaque, *parse_types.Expr, c_int) void,
    destroy_expr: *const fn (?*anyopaque, ?*parse_types.Expr) void,
};

/// Source-level ExprList ownership operations used by list grammar actions.
pub const ExpressionListHooks = struct {
    context: ?*anyopaque,
    append: *const fn (?*anyopaque, ?*parse_types.ExprList, ?*parse_types.Expr) ?*parse_types.ExprList,
    set_sort_order: *const fn (?*anyopaque, ?*parse_types.ExprList, c_int, c_int) void,
    set_name: *const fn (?*anyopaque, ?*parse_types.ExprList, parse_types.Token, bool) void,
    set_span: *const fn (?*anyopaque, ?*parse_types.ExprList, ?[*]const u8, ?[*]const u8) void,
    append_vector: *const fn (?*anyopaque, ?*parse_types.ExprList, ?*parse_types.IdList, ?*parse_types.Expr) ?*parse_types.ExprList,
    check_length: *const fn (?*anyopaque, ?*parse_types.ExprList, []const u8) void,
    append_id_term: *const fn (?*anyopaque, ?*parse_types.ExprList, parse_types.Token, c_int, c_int) ?*parse_types.ExprList,
    destroy: *const fn (?*anyopaque, ?*parse_types.ExprList) void,
};

pub const SourceListHooks = struct {
    context: ?*anyopaque,
    append_fullname: *const fn (
        ?*anyopaque,
        parse_types.Token,
        ?parse_types.Token,
    ) ?*parse_types.SrcList,
    set_alias: *const fn (?*anyopaque, ?*parse_types.SrcList, parse_types.Token, bool) void,
    append_from_term: *const fn (
        ?*anyopaque,
        ?*parse_types.SrcList,
        parse_types.Token,
        parse_types.Token,
        parse_types.Token,
        ?*parse_types.Select,
        parse_types.OnOrUsing,
    ) ?*parse_types.SrcList,
    nested_from: *const fn (
        ?*anyopaque,
        ?*parse_types.SrcList,
        ?*parse_types.SrcList,
        parse_types.Token,
        parse_types.OnOrUsing,
    ) ?*parse_types.SrcList,
    shift_join_types: *const fn (?*anyopaque, ?*parse_types.SrcList) void,
    set_last_join_type: *const fn (?*anyopaque, ?*parse_types.SrcList, c_int) void,
    indexed_by: *const fn (?*anyopaque, ?*parse_types.SrcList, parse_types.Token) void,
    function_args: *const fn (?*anyopaque, ?*parse_types.SrcList, ?*parse_types.ExprList) void,
    join_type: *const fn (?*anyopaque, parse_types.Token, ?parse_types.Token, ?parse_types.Token) c_int,
    destroy: *const fn (?*anyopaque, ?*parse_types.SrcList) void,
};

pub const IdentifierListHooks = struct {
    context: ?*anyopaque,
    append: *const fn (?*anyopaque, ?*parse_types.IdList, parse_types.Token) ?*parse_types.IdList,
    destroy: *const fn (?*anyopaque, ?*parse_types.IdList) void,
};

pub const TriggerHooks = struct {
    context: ?*anyopaque,
    begin: *const fn (
        ?*anyopaque,
        parse_types.Token,
        parse_types.Token,
        c_int,
        parse_types.TrigEvent,
        ?*parse_types.SrcList,
        ?*parse_types.Expr,
        bool,
        bool,
    ) void,
    finish: *const fn (?*anyopaque, ?*parse_types.TriggerStep, parse_types.Token) void,
    append_step: *const fn (?*anyopaque, ?*parse_types.TriggerStep, ?*parse_types.TriggerStep) ?*parse_types.TriggerStep,
    update_step: *const fn (?*anyopaque, ?*parse_types.SrcList, c_int, ?*parse_types.ExprList, ?*parse_types.SrcList, ?*parse_types.Expr, ?[*]const u8, ?[*]const u8) ?*parse_types.TriggerStep,
    insert_step: *const fn (?*anyopaque, ?*parse_types.SrcList, ?*parse_types.Select, ?*parse_types.IdList, c_int, ?*parse_types.Upsert, ?[*]const u8, ?[*]const u8) ?*parse_types.TriggerStep,
    delete_step: *const fn (?*anyopaque, ?*parse_types.SrcList, ?*parse_types.Expr, ?[*]const u8, ?[*]const u8) ?*parse_types.TriggerStep,
    select_step: *const fn (?*anyopaque, ?*parse_types.Select, ?[*]const u8, ?[*]const u8) ?*parse_types.TriggerStep,
    destroy: *const fn (?*anyopaque, ?*parse_types.TriggerStep) void,
};

pub const WindowHooks = struct {
    context: ?*anyopaque,
    chain: *const fn (?*anyopaque, ?*parse_types.Window, ?*parse_types.Window) ?*parse_types.Window,
    set_name: *const fn (?*anyopaque, ?*parse_types.Window, parse_types.Token) ?*parse_types.Window,
    assemble: *const fn (?*anyopaque, ?*parse_types.Window, ?*parse_types.ExprList, ?*parse_types.ExprList, ?parse_types.Token) ?*parse_types.Window,
    allocate: *const fn (?*anyopaque, c_int, parse_types.FrameBound, parse_types.FrameBound, u8) ?*parse_types.Window,
    attach_filter: *const fn (?*anyopaque, ?*parse_types.Window, ?*parse_types.Expr) ?*parse_types.Window,
    filter_only: *const fn (?*anyopaque, ?*parse_types.Expr) ?*parse_types.Window,
    named_over: *const fn (?*anyopaque, parse_types.Token) ?*parse_types.Window,
    attach_expression: *const fn (?*anyopaque, ?*parse_types.Expr, ?*parse_types.Window) void,
    set_select_definitions: *const fn (?*anyopaque, ?*parse_types.Select, ?*parse_types.Window) void,
    destroy: *const fn (?*anyopaque, ?*parse_types.Window) void,
};

pub const WithHooks = struct {
    context: ?*anyopaque,
    create_cte: *const fn (?*anyopaque, parse_types.Token, ?*parse_types.ExprList, ?*parse_types.Select, u8) ?*parse_types.Cte,
    add: *const fn (?*anyopaque, ?*parse_types.With, ?*parse_types.Cte) ?*parse_types.With,
    attach: *const fn (?*anyopaque, ?*parse_types.Select, ?*parse_types.With) ?*parse_types.Select,
    push: *const fn (?*anyopaque, ?*parse_types.With) void,
    mark_present: *const fn (?*anyopaque) void,
    destroy: *const fn (?*anyopaque, ?*parse_types.With) void,
};

pub const UpsertHooks = struct {
    context: ?*anyopaque,
    create: *const fn (
        ?*anyopaque,
        ?*parse_types.ExprList,
        ?*parse_types.Expr,
        ?*parse_types.ExprList,
        ?*parse_types.Expr,
        ?*parse_types.Upsert,
        bool,
    ) ?*parse_types.Upsert,
    destroy: *const fn (?*anyopaque, ?*parse_types.Upsert) void,
};

pub const SelectHooks = struct {
    context: ?*anyopaque,
    create: *const fn (
        ?*anyopaque,
        ?*parse_types.ExprList,
        ?*parse_types.SrcList,
        ?*parse_types.Expr,
        ?*parse_types.ExprList,
        ?*parse_types.Expr,
        ?*parse_types.ExprList,
        c_int,
        ?*parse_types.Expr,
    ) ?*parse_types.Select,
    compound: *const fn (?*anyopaque, ?*parse_types.Select, ?*parse_types.Select, c_int) ?*parse_types.Select,
    multi_values: *const fn (?*anyopaque, ?*parse_types.Select, ?*parse_types.ExprList) ?*parse_types.Select,
    multi_values_end: *const fn (?*anyopaque, ?*parse_types.Select) void,
    double_link: *const fn (?*anyopaque, *parse_types.Select) void,
    destroy: *const fn (?*anyopaque, ?*parse_types.Select) void,
};

pub const ActionOptions = struct {
    /// Mirrors `pParse->pReprepare!=0` for EXPLAIN side effects.
    is_reprepare: bool = false,
    /// Mirrors `pParse->db->init.busy` for the TEMP production.
    schema_init_busy: bool = false,
    /// Mirrors `IN_RENAME_OBJECT` for rename-token remapping actions.
    rename_mode: bool = false,
    nested_parse: bool = false,
    expression_hooks: ?ExpressionHooks = null,
    expression_list_hooks: ?ExpressionListHooks = null,
    source_list_hooks: ?SourceListHooks = null,
    identifier_list_hooks: ?IdentifierListHooks = null,
    trigger_hooks: ?TriggerHooks = null,
    window_hooks: ?WindowHooks = null,
    with_hooks: ?WithHooks = null,
    upsert_hooks: ?UpsertHooks = null,
    select_hooks: ?SelectHooks = null,
};

pub const typed_action_contract_rule_count: u16 = 348;

fn hasTypedActionContract(rule_index: u16) bool {
    return rule_index < tables.rules_with_actions;
}

pub const DestructorCallback = *const fn (
    context: ?*anyopaque,
    kind: tables.DestructorKind,
    pointer: ?*anyopaque,
) void;

/// Route a live minor value exactly as generated by Lemon. The callback owns
/// the type-specific delete operation; this parser layer only selects the live
/// union member. Symbols without a destructor do not invoke the callback.
pub fn destroySymbol(
    symbol: u16,
    minor: *SemanticValue,
    context: ?*anyopaque,
    callback: DestructorCallback,
) void {
    std.debug.assert(symbol < tables.no_code);
    const kind = tables.destructors[symbol];
    const pointer: ?*anyopaque = switch (kind) {
        .none => return,
        .select => @ptrCast(minor.yy555),
        .expr => @ptrCast(minor.yy454),
        .expr_list => @ptrCast(minor.yy14),
        .src_list => @ptrCast(minor.yy203),
        .with => @ptrCast(minor.yy59),
        .window_list, .window => @ptrCast(minor.yy211),
        .id_list => @ptrCast(minor.yy132),
        .trigger_step => @ptrCast(minor.yy427),
        .trigger_event_id_list => @ptrCast(minor.yy286.b),
        .frame_bound_expr => @ptrCast(minor.yy509.pExpr),
    };
    callback(context, kind, pointer);
}

pub const Result = enum {
    accepted,
    syntax_error,
    out_of_memory,
};

const FeedResult = enum { shifted, accepted, syntax_error };

fn tokenSpanLength(first: parse_types.Token, last: parse_types.Token) c_uint {
    if (first.z == null or last.z == null) return 0;
    const start = @intFromPtr(first.z.?);
    const end = @intFromPtr(last.z.?) + last.n;
    if (end < start) return 0;
    return @intCast(end - start);
}

fn tokenEqualsAscii(token: parse_types.Token, expected: []const u8) bool {
    if (token.n != expected.len or token.z == null) return false;
    const actual = token.z.?[0..token.n];
    for (actual, expected) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

const Machine = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(StackEntry) = .empty,
    action_options: ActionOptions,
    action_context: ?*anyopaque,
    action_callback: ?ActionCallback,
    destructor_context: ?*anyopaque,
    destructor_callback: ?DestructorCallback,
    semantic_out_of_memory: bool = false,
    sql_origin: ?[*]const u8 = null,
    last_token: parse_types.Token = .{ .z = null, .n = 0 },

    fn init(
        allocator: std.mem.Allocator,
        action_options: ActionOptions,
        action_context: ?*anyopaque,
        action_callback: ?ActionCallback,
        destructor_context: ?*anyopaque,
        destructor_callback: ?DestructorCallback,
    ) !Machine {
        var result = Machine{
            .allocator = allocator,
            .action_options = action_options,
            .action_context = action_context,
            .action_callback = action_callback,
            .destructor_context = destructor_context,
            .destructor_callback = destructor_callback,
        };
        try result.stack.append(allocator, .{ .state = 0, .symbol = 0, .minor = .{ .yyinit = 0 } });
        return result;
    }

    fn destroyMinor(self: *Machine, symbol: u16, minor: *SemanticValue) void {
        if (tables.destructors[symbol] == .expr) {
            if (self.action_options.expression_hooks) |hooks| {
                hooks.destroy_expr(hooks.context, minor.yy454);
                return;
            }
        } else if (tables.destructors[symbol] == .expr_list) {
            if (self.action_options.expression_list_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy14);
                return;
            }
        } else if (tables.destructors[symbol] == .select) {
            if (self.action_options.select_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy555);
                return;
            }
        } else if (tables.destructors[symbol] == .src_list) {
            if (self.action_options.source_list_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy203);
                return;
            }
        } else if (tables.destructors[symbol] == .id_list) {
            if (self.action_options.identifier_list_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy132);
                return;
            }
        } else if (tables.destructors[symbol] == .with) {
            if (self.action_options.with_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy59);
                return;
            }
        } else if (tables.destructors[symbol] == .trigger_step) {
            if (self.action_options.trigger_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy427);
                return;
            }
        } else if (tables.destructors[symbol] == .window or
            tables.destructors[symbol] == .window_list)
        {
            if (self.action_options.window_hooks) |hooks| {
                hooks.destroy(hooks.context, minor.yy211);
                return;
            }
        }
        // Cte and Upsert values have no generated Lemon destructor. Once constructed,
        // ownership always moves into the enclosing upsert or INSERT action.
        if (self.destructor_callback) |callback| {
            destroySymbol(symbol, minor, self.destructor_context, callback);
        }
    }

    fn deinit(self: *Machine) void {
        while (self.stack.items.len > 1) {
            var entry = self.stack.pop().?;
            self.destroyMinor(entry.symbol, &entry.minor);
        }
        self.stack.deinit(self.allocator);
    }

    fn emit(self: *Machine, action: Action) void {
        if (self.action_callback) |callback| callback(self.action_context, action);
    }

    fn tokenExpr(self: *Machine, op: u16, token: parse_types.Token) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.token_expr(hooks.context, op, token);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn integerExpr(self: *Machine, token: parse_types.Token) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.integer_expr(hooks.context, token);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn functionExpr(
        self: *Machine,
        token: parse_types.Token,
        list: ?*parse_types.ExprList,
        distinct: c_int,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.function_expr(hooks.context, token, list, distinct);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn orderedFunctionExpr(
        self: *Machine,
        token: parse_types.Token,
        arguments: ?*parse_types.ExprList,
        distinct: c_int,
        order_by: ?*parse_types.ExprList,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.ordered_function_expr(
            hooks.context,
            token,
            arguments,
            distinct,
            order_by,
        );
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn variableExpr(self: *Machine, token: parse_types.Token) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.variable_expr(hooks.context, token, self.action_options.nested_parse);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn qnumberExpr(self: *Machine, token: parse_types.Token) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.qnumber_expr(hooks.context, token);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn bareExpr(self: *Machine, op: u16) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.bare_expr(hooks.context, op);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn pExpr(
        self: *Machine,
        op: u16,
        left: ?*parse_types.Expr,
        right: ?*parse_types.Expr,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.p_expr(hooks.context, op, left, right);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn andExpr(
        self: *Machine,
        left: ?*parse_types.Expr,
        right: ?*parse_types.Expr,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.and_expr(hooks.context, left, right);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn collateExpr(
        self: *Machine,
        expression: ?*parse_types.Expr,
        token: parse_types.Token,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.collate_expr(hooks.context, expression, token);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn castExpr(
        self: *Machine,
        expression: ?*parse_types.Expr,
        token: parse_types.Token,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.cast_expr(hooks.context, expression, token);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn isNullExpr(
        self: *Machine,
        op: u16,
        expression: ?*parse_types.Expr,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.is_null_expr(hooks.context, op, expression);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn isExpr(
        self: *Machine,
        op: u16,
        left: ?*parse_types.Expr,
        right: ?*parse_types.Expr,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.is_expr(hooks.context, op, left, right);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn betweenExpr(
        self: *Machine,
        expression: ?*parse_types.Expr,
        bounds: ?*parse_types.ExprList,
        negated: bool,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.between_expr(hooks.context, expression, bounds, negated);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn inListExpr(
        self: *Machine,
        expression: ?*parse_types.Expr,
        list: ?*parse_types.ExprList,
        negated: bool,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.in_list_expr(hooks.context, expression, list, negated);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn selectExpr(self: *Machine, op: u16, select: ?*parse_types.Select) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.select_expr(hooks.context, op, select);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn inSelectExpr(
        self: *Machine,
        expression: ?*parse_types.Expr,
        select: ?*parse_types.Select,
        negated: bool,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.in_select_expr(hooks.context, expression, select, negated);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn caseExpr(
        self: *Machine,
        operand: ?*parse_types.Expr,
        pairs: ?*parse_types.ExprList,
        else_expression: ?*parse_types.Expr,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.case_expr(hooks.context, operand, pairs, else_expression);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn vectorExpr(self: *Machine, list: ?*parse_types.ExprList) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.vector_expr(hooks.context, list);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn likeExpr(
        self: *Machine,
        token: parse_types.Token,
        left: ?*parse_types.Expr,
        right: ?*parse_types.Expr,
        escape: ?*parse_types.Expr,
        negated: bool,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.like_expr(hooks.context, token, left, right, escape, negated);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn inTableExpr(
        self: *Machine,
        expression: ?*parse_types.Expr,
        name: parse_types.Token,
        database: parse_types.Token,
        arguments: ?*parse_types.ExprList,
        negated: bool,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.in_table_expr(
            hooks.context,
            expression,
            name,
            database,
            arguments,
            negated,
        );
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn raiseExpr(
        self: *Machine,
        conflict: c_int,
        message: ?*parse_types.Expr,
    ) ?*parse_types.Expr {
        const hooks = self.action_options.expression_hooks orelse return null;
        const result = hooks.raise_expr(hooks.context, conflict, message);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn appendExprList(
        self: *Machine,
        list: ?*parse_types.ExprList,
        expression: ?*parse_types.Expr,
    ) ?*parse_types.ExprList {
        const hooks = self.action_options.expression_list_hooks orelse {
            if (self.action_options.expression_hooks) |expression_hooks|
                expression_hooks.destroy_expr(expression_hooks.context, expression);
            return null;
        };
        const result = hooks.append(hooks.context, list, expression);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn appendVector(
        self: *Machine,
        list: ?*parse_types.ExprList,
        identifiers: ?*parse_types.IdList,
        expression: ?*parse_types.Expr,
    ) ?*parse_types.ExprList {
        const hooks = self.action_options.expression_list_hooks orelse return null;
        const result = hooks.append_vector(hooks.context, list, identifiers, expression);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn appendIdTerm(
        self: *Machine,
        list: ?*parse_types.ExprList,
        token: parse_types.Token,
        collate: c_int,
        order: c_int,
    ) ?*parse_types.ExprList {
        const hooks = self.action_options.expression_list_hooks orelse return null;
        const result = hooks.append_id_term(hooks.context, list, token, collate, order);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn setSortOrder(
        self: *Machine,
        list: ?*parse_types.ExprList,
        order: c_int,
        nulls: c_int,
    ) void {
        if (self.action_options.expression_list_hooks) |hooks|
            hooks.set_sort_order(hooks.context, list, order, nulls);
    }

    fn setListName(self: *Machine, list: ?*parse_types.ExprList, token: parse_types.Token) void {
        if (self.action_options.expression_list_hooks) |hooks|
            hooks.set_name(hooks.context, list, token, true);
    }

    fn setListSpan(
        self: *Machine,
        list: ?*parse_types.ExprList,
        start: ?[*]const u8,
        end: ?[*]const u8,
    ) void {
        if (self.action_options.expression_list_hooks) |hooks|
            hooks.set_span(hooks.context, list, start, end);
    }

    fn setErrorOffset(self: *Machine, expression: ?*parse_types.Expr, token: parse_types.Token) void {
        if (expression == null or token.z == null or self.sql_origin == null) return;
        const token_address = @intFromPtr(token.z.?);
        const origin_address = @intFromPtr(self.sql_origin.?);
        if (token_address < origin_address) return;
        if (self.action_options.expression_hooks) |hooks|
            hooks.set_error_offset(hooks.context, expression.?, @intCast(token_address - origin_address));
    }

    fn appendIdentifier(
        self: *Machine,
        list: ?*parse_types.IdList,
        token: parse_types.Token,
    ) ?*parse_types.IdList {
        const hooks = self.action_options.identifier_list_hooks orelse return null;
        const result = hooks.append(hooks.context, list, token);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn appendFullname(
        self: *Machine,
        first: parse_types.Token,
        second: ?parse_types.Token,
    ) ?*parse_types.SrcList {
        const hooks = self.action_options.source_list_hooks orelse return null;
        const result = hooks.append_fullname(hooks.context, first, second);
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn emitDrop(self: *Machine, source: ?*parse_types.SrcList, is_view: bool, if_exists: bool) void {
        self.emit(.{ .drop_table = .{
            .source = source,
            .is_view = is_view,
            .if_exists = if_exists,
        } });
        if (self.action_options.source_list_hooks) |hooks| {
            hooks.destroy(hooks.context, source);
        } else if (self.destructor_callback) |callback| {
            callback(self.destructor_context, .src_list, @ptrCast(source));
        }
    }

    fn appendSourceTerm(
        self: *Machine,
        list: ?*parse_types.SrcList,
        name: parse_types.Token,
        database: parse_types.Token,
        alias: parse_types.Token,
        select: ?*parse_types.Select,
        on_using: parse_types.OnOrUsing,
    ) ?*parse_types.SrcList {
        const hooks = self.action_options.source_list_hooks orelse {
            if (select != null and self.action_options.select_hooks != null)
                self.action_options.select_hooks.?.destroy(self.action_options.select_hooks.?.context, select);
            if (on_using.pOn != null and self.action_options.expression_hooks != null)
                self.action_options.expression_hooks.?.destroy_expr(self.action_options.expression_hooks.?.context, on_using.pOn);
            return null;
        };
        const result = hooks.append_from_term(
            hooks.context,
            list,
            name,
            database,
            alias,
            select,
            on_using,
        );
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn createUpsert(
        self: *Machine,
        target: ?*parse_types.ExprList,
        target_where: ?*parse_types.Expr,
        changes: ?*parse_types.ExprList,
        where: ?*parse_types.Expr,
        next: ?*parse_types.Upsert,
        is_update: bool,
    ) ?*parse_types.Upsert {
        const hooks = self.action_options.upsert_hooks orelse return null;
        const result = hooks.create(
            hooks.context,
            target,
            target_where,
            changes,
            where,
            next,
            is_update,
        );
        if (result == null) self.semantic_out_of_memory = true;
        return result;
    }

    fn createSelect(
        self: *Machine,
        result: ?*parse_types.ExprList,
        source: ?*parse_types.SrcList,
        where: ?*parse_types.Expr,
        group_by: ?*parse_types.ExprList,
        having: ?*parse_types.Expr,
        order_by: ?*parse_types.ExprList,
        flags: c_int,
        limit: ?*parse_types.Expr,
    ) ?*parse_types.Select {
        const hooks = self.action_options.select_hooks orelse return null;
        const select = hooks.create(
            hooks.context,
            result,
            source,
            where,
            group_by,
            having,
            order_by,
            flags,
            limit,
        );
        if (select == null) self.semantic_out_of_memory = true;
        return select;
    }

    fn emitSelect(self: *Machine, select: ?*parse_types.Select) void {
        self.emit(.{ .select_statement = select });
        if (self.action_options.select_hooks) |hooks| {
            hooks.destroy(hooks.context, select);
        } else if (self.destructor_callback) |callback| {
            callback(self.destructor_context, .select, @ptrCast(select));
        }
    }

    fn emitTransferredExpr(self: *Machine, action: Action, expression: ?*parse_types.Expr) void {
        if (self.action_callback != null) {
            self.emit(action);
        } else if (self.action_options.expression_hooks) |hooks| {
            hooks.destroy_expr(hooks.context, expression);
        } else if (self.destructor_callback) |callback| {
            callback(self.destructor_context, .expr, @ptrCast(expression));
        }
    }

    fn emitDefault(
        self: *Machine,
        expression: ?*parse_types.Expr,
        source: parse_types.Token,
    ) void {
        self.emit(.{ .add_default = .{ .expression = expression, .source = source } });
        if (self.action_options.expression_hooks) |hooks| {
            hooks.destroy_expr(hooks.context, expression);
        } else if (self.destructor_callback) |callback| {
            callback(self.destructor_context, .expr, @ptrCast(expression));
        }
    }

    fn executeTypedActionContract(
        self: *Machine,
        rule_index: u16,
        rhs: []const StackEntry,
        lookahead: SemanticValue,
        lhs: *SemanticValue,
    ) void {
        switch (rule_index) {
            0 => if (!self.action_options.is_reprepare) self.emit(.{ .explain = 1 }),
            1 => if (!self.action_options.is_reprepare) self.emit(.{ .explain = 2 }),
            2 => self.emit(.finish_coding),
            3 => self.emit(.{ .begin_transaction = rhs[1].minor.yy144 }),
            4 => lhs.yy144 = tokenizer.token.tk_deferred,
            5, 6, 7 => lhs.yy144 = rhs[0].symbol,
            8, 9 => self.emit(.{ .end_transaction = rhs[0].symbol }),
            10 => self.emit(.{ .savepoint = .{ .operation = .begin, .name = rhs[1].minor.yy0 } }),
            11 => self.emit(.{ .savepoint = .{ .operation = .release, .name = rhs[2].minor.yy0 } }),
            12 => self.emit(.{ .savepoint = .{ .operation = .rollback, .name = rhs[4].minor.yy0 } }),
            13 => self.emit(.{ .start_table = .{
                .name = rhs[4].minor.yy0,
                .database = rhs[5].minor.yy0,
                .is_temporary = rhs[1].minor.yy144 != 0,
                .if_not_exists = rhs[3].minor.yy144 != 0,
            } }),
            14 => self.emit(.disable_lookaside),
            15, 18 => lhs.yy144 = 0,
            16 => lhs.yy144 = 1,
            17 => lhs.yy144 = @intFromBool(!self.action_options.schema_init_busy),
            19 => self.emit(.{ .end_table = .{
                .constraint_start = rhs[2].minor.yy0,
                .end = rhs[3].minor.yy0,
                .flags = rhs[4].minor.yy391,
                .select = null,
            } }),
            20 => {
                self.emit(.{ .end_table = .{
                    .constraint_start = .{ .z = null, .n = 0 },
                    .end = .{ .z = null, .n = 0 },
                    .flags = 0,
                    .select = rhs[1].minor.yy555,
                } });
                if (self.destructor_callback) |callback| {
                    var selected = rhs[1].minor;
                    destroySymbol(rhs[1].symbol, &selected, self.destructor_context, callback);
                }
            },
            21 => lhs.yy391 = 0,
            22 => lhs.yy391 = rhs[0].minor.yy391 | rhs[2].minor.yy391,
            23 => {
                if (tokenEqualsAscii(rhs[1].minor.yy0, "rowid")) {
                    lhs.yy391 = table_flag.without_rowid | table_flag.no_visible_rowid;
                } else {
                    lhs.yy391 = 0;
                    self.emit(.{ .unknown_table_option = rhs[1].minor.yy0 });
                }
            },
            24 => {
                if (tokenEqualsAscii(rhs[0].minor.yy0, "strict")) {
                    lhs.yy391 = table_flag.strict;
                } else {
                    lhs.yy391 = 0;
                    self.emit(.{ .unknown_table_option = rhs[0].minor.yy0 });
                }
            },
            25 => self.emit(.{ .add_column = .{
                .name = rhs[0].minor.yy0,
                .type_name = rhs[1].minor.yy0,
            } }),
            26 => lhs.yy0 = .{ .z = null, .n = 0 },
            27 => lhs.yy0.n = tokenSpanLength(rhs[0].minor.yy0, rhs[3].minor.yy0),
            28 => lhs.yy0.n = tokenSpanLength(rhs[0].minor.yy0, rhs[5].minor.yy0),
            29 => lhs.yy0.n = tokenSpanLength(rhs[0].minor.yy0, rhs[1].minor.yy0),
            30 => lhs.yy168 = lookahead.yy0.z,
            31 => lhs.yy0 = lookahead.yy0,
            32 => self.emit(.{ .set_constraint_name = rhs[1].minor.yy0 }),
            33 => self.emitDefault(rhs[2].minor.yy454, rhs[1].minor.yy0),
            34 => {
                const start = if (rhs[1].minor.yy0.z) |pointer| pointer + 1 else null;
                const end = rhs[3].minor.yy0.z;
                const length: c_uint = if (start != null and end != null and
                    @intFromPtr(end.?) >= @intFromPtr(start.?))
                    @intCast(@intFromPtr(end.?) - @intFromPtr(start.?))
                else
                    0;
                self.emitDefault(rhs[2].minor.yy454, .{ .z = start, .n = length });
            },
            35 => self.emitDefault(rhs[3].minor.yy454, .{
                .z = rhs[1].minor.yy0.z,
                .n = tokenSpanLength(rhs[1].minor.yy0, rhs[2].minor.yy0),
            }),
            36 => self.emitDefault(
                self.pExpr(tokenizer.token.tk_uminus, rhs[3].minor.yy454, null),
                .{
                    .z = rhs[1].minor.yy0.z,
                    .n = tokenSpanLength(rhs[1].minor.yy0, rhs[2].minor.yy0),
                },
            ),
            37 => {
                const expression = self.tokenExpr(tokenizer.token.tk_string, rhs[2].minor.yy0);
                if (expression) |pointer| {
                    if (self.action_options.expression_hooks) |hooks|
                        hooks.id_to_true_false(hooks.context, pointer);
                }
                self.emitDefault(expression, rhs[2].minor.yy0);
            },
            38 => self.emit(.{ .add_not_null = rhs[2].minor.yy144 }),
            39 => self.emit(.{ .add_primary_key = .{
                .columns = null,
                .conflict = rhs[3].minor.yy144,
                .autoincrement = rhs[4].minor.yy144 != 0,
                .order = rhs[2].minor.yy144,
            } }),
            40 => self.emit(.{ .create_unique = .{
                .columns = null,
                .conflict = rhs[1].minor.yy144,
            } }),
            41 => self.emitTransferredExpr(.{ .add_check = .{
                .expression = rhs[2].minor.yy454,
                .open = rhs[1].minor.yy0,
                .close = rhs[3].minor.yy0,
            } }, rhs[2].minor.yy454),
            42 => {
                self.emit(.{ .create_foreign_key = .{
                    .from_columns = null,
                    .table = rhs[1].minor.yy0,
                    .to_columns = rhs[2].minor.yy14,
                    .actions = rhs[3].minor.yy144,
                } });
                var columns = rhs[2].minor;
                self.destroyMinor(rhs[2].symbol, &columns);
            },
            43 => self.emit(.{ .defer_foreign_key = rhs[0].minor.yy144 != 0 }),
            44 => self.emit(.{ .add_collation = rhs[1].minor.yy0 }),
            45 => self.emitTransferredExpr(.{ .add_generated = .{
                .expression = rhs[1].minor.yy454,
                .storage = null,
            } }, rhs[1].minor.yy454),
            46 => self.emitTransferredExpr(.{ .add_generated = .{
                .expression = rhs[1].minor.yy454,
                .storage = rhs[3].minor.yy0,
            } }, rhs[1].minor.yy454),
            47, 62 => lhs.yy144 = 0,
            48 => lhs.yy144 = 1,
            49 => lhs.yy144 = foreign_action.none * 0x0101,
            50 => lhs.yy144 = (rhs[0].minor.yy144 & ~rhs[1].minor.yy383.mask) |
                rhs[1].minor.yy383.value,
            51, 52 => lhs.yy383 = .{ .value = 0, .mask = 0 },
            53 => lhs.yy383 = .{ .value = rhs[2].minor.yy144, .mask = 0x0000ff },
            54 => lhs.yy383 = .{ .value = rhs[2].minor.yy144 << 8, .mask = 0x00ff00 },
            55 => lhs.yy144 = foreign_action.set_null,
            56 => lhs.yy144 = foreign_action.set_default,
            57 => lhs.yy144 = foreign_action.cascade,
            58 => lhs.yy144 = foreign_action.restrict,
            59 => lhs.yy144 = foreign_action.none,
            60 => lhs.yy144 = 0,
            61 => lhs.yy144 = rhs[1].minor.yy144,
            63 => lhs.yy144 = 1,
            64 => lhs.yy144 = 0,
            65 => lhs.yy0 = .{ .z = null, .n = 0 },
            66 => self.emit(.clear_constraint_name),
            67 => self.emit(.{ .set_constraint_name = rhs[1].minor.yy0 }),
            68 => {
                self.emit(.{ .add_primary_key = .{
                    .columns = rhs[3].minor.yy14,
                    .conflict = rhs[6].minor.yy144,
                    .autoincrement = rhs[4].minor.yy144 != 0,
                    .order = sort_order.ascending,
                } });
                var columns = rhs[3].minor;
                self.destroyMinor(rhs[3].symbol, &columns);
            },
            69 => {
                self.emit(.{ .create_unique = .{
                    .columns = rhs[2].minor.yy14,
                    .conflict = rhs[4].minor.yy144,
                } });
                var columns = rhs[2].minor;
                self.destroyMinor(rhs[2].symbol, &columns);
            },
            70 => self.emitTransferredExpr(.{ .add_check = .{
                .expression = rhs[2].minor.yy454,
                .open = rhs[1].minor.yy0,
                .close = rhs[3].minor.yy0,
            } }, rhs[2].minor.yy454),
            71 => {
                self.emit(.{ .create_foreign_key = .{
                    .from_columns = rhs[3].minor.yy14,
                    .table = rhs[6].minor.yy0,
                    .to_columns = rhs[7].minor.yy14,
                    .actions = rhs[8].minor.yy144,
                } });
                var from_columns = rhs[3].minor;
                var to_columns = rhs[7].minor;
                self.destroyMinor(rhs[3].symbol, &from_columns);
                self.destroyMinor(rhs[7].symbol, &to_columns);
                self.emit(.{ .defer_foreign_key = rhs[9].minor.yy144 != 0 });
            },
            72 => lhs.yy144 = 0,
            73, 75 => lhs.yy144 = conflict_action.default,
            74 => lhs.yy144 = rhs[2].minor.yy144,
            76 => lhs.yy144 = rhs[1].minor.yy144,
            77 => lhs.yy144 = conflict_action.ignore,
            78 => lhs.yy144 = conflict_action.replace,
            79 => self.emitDrop(rhs[3].minor.yy203, false, rhs[2].minor.yy144 != 0),
            80 => lhs.yy144 = 1,
            81 => lhs.yy144 = 0,
            82 => self.emit(.{ .create_view = .{
                .name = rhs[4].minor.yy0,
                .database = rhs[5].minor.yy0,
                .columns = rhs[6].minor.yy14,
                .select = rhs[8].minor.yy555,
                .is_temporary = rhs[1].minor.yy144 != 0,
                .if_not_exists = rhs[3].minor.yy144 != 0,
            } }),
            83 => self.emitDrop(rhs[3].minor.yy203, true, rhs[2].minor.yy144 != 0),
            84 => self.emitSelect(rhs[0].minor.yy555),
            85 => {
                lhs.yy555 = null;
                if (self.action_options.with_hooks) |hooks|
                    lhs.yy555 = hooks.attach(hooks.context, rhs[2].minor.yy555, rhs[1].minor.yy59);
            },
            86 => {
                lhs.yy555 = null;
                if (self.action_options.with_hooks) |hooks|
                    lhs.yy555 = hooks.attach(hooks.context, rhs[3].minor.yy555, rhs[2].minor.yy59);
            },
            87 => {
                lhs.yy555 = rhs[0].minor.yy555;
                if (lhs.yy555) |select| {
                    if (self.action_options.select_hooks) |hooks|
                        hooks.double_link(hooks.context, select);
                }
            },
            88 => {
                lhs.yy555 = null;
                if (self.action_options.select_hooks) |hooks| {
                    lhs.yy555 = hooks.compound(
                        hooks.context,
                        rhs[0].minor.yy555,
                        rhs[2].minor.yy555,
                        rhs[1].minor.yy144,
                    );
                    if (lhs.yy555 == null) self.semantic_out_of_memory = true;
                }
            },
            89, 91 => lhs.yy144 = rhs[0].symbol,
            90 => lhs.yy144 = tokenizer.token.tk_all,
            92 => lhs.yy555 = self.createSelect(
                rhs[2].minor.yy14,
                rhs[3].minor.yy203,
                rhs[4].minor.yy454,
                rhs[5].minor.yy14,
                rhs[6].minor.yy454,
                rhs[7].minor.yy14,
                rhs[1].minor.yy144,
                rhs[8].minor.yy454,
            ),
            93 => {
                lhs.yy555 = self.createSelect(
                    rhs[2].minor.yy14,
                    rhs[3].minor.yy203,
                    rhs[4].minor.yy454,
                    rhs[5].minor.yy14,
                    rhs[6].minor.yy454,
                    rhs[8].minor.yy14,
                    rhs[1].minor.yy144,
                    rhs[9].minor.yy454,
                );
                if (self.action_options.window_hooks) |hooks|
                    hooks.set_select_definitions(hooks.context, lhs.yy555, rhs[7].minor.yy211);
            },
            94 => lhs.yy555 = self.createSelect(
                rhs[2].minor.yy14,
                null,
                null,
                null,
                null,
                null,
                @intCast(select_flag.values),
                null,
            ),
            95 => {
                lhs.yy555 = rhs[0].minor.yy555;
                if (self.action_options.select_hooks) |hooks|
                    hooks.multi_values_end(hooks.context, lhs.yy555);
            },
            96, 97 => {
                lhs.yy555 = null;
                if (self.action_options.select_hooks) |hooks| {
                    lhs.yy555 = hooks.multi_values(
                        hooks.context,
                        rhs[0].minor.yy555,
                        rhs[3].minor.yy14,
                    );
                    if (lhs.yy555 == null) self.semantic_out_of_memory = true;
                }
            },
            98 => lhs.yy144 = select_flag.distinct,
            99 => lhs.yy144 = select_flag.all,
            100 => lhs.yy144 = 0,
            101 => lhs.yy14 = null,
            102 => {
                lhs.yy14 = self.appendExprList(rhs[0].minor.yy14, rhs[2].minor.yy454);
                if (rhs[4].minor.yy0.n != 0) self.setListName(lhs.yy14, rhs[4].minor.yy0);
                self.setListSpan(lhs.yy14, rhs[1].minor.yy168, rhs[3].minor.yy168);
            },
            103 => {
                const expression = self.bareExpr(tokenizer.token.tk_asterisk);
                self.setErrorOffset(expression, rhs[2].minor.yy0);
                lhs.yy14 = self.appendExprList(rhs[0].minor.yy14, expression);
            },
            104 => {
                const right = self.pExpr(tokenizer.token.tk_asterisk, null, null);
                self.setErrorOffset(right, rhs[4].minor.yy0);
                const left = self.tokenExpr(tokenizer.token.tk_id, rhs[2].minor.yy0);
                lhs.yy14 = self.appendExprList(
                    rhs[0].minor.yy14,
                    self.pExpr(tokenizer.token.tk_dot, left, right),
                );
            },
            105 => lhs.yy0 = rhs[1].minor.yy0,
            106 => lhs.yy0 = .{ .z = null, .n = 0 },
            107, 110 => lhs.yy203 = null,
            108 => {
                lhs.yy203 = rhs[1].minor.yy203;
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.shift_join_types(hooks.context, lhs.yy203);
            },
            109 => {
                lhs.yy203 = rhs[0].minor.yy203;
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.set_last_join_type(hooks.context, lhs.yy203, rhs[1].minor.yy144);
            },
            111 => lhs.yy203 = self.appendSourceTerm(
                rhs[0].minor.yy203,
                rhs[1].minor.yy0,
                rhs[2].minor.yy0,
                rhs[3].minor.yy0,
                null,
                rhs[4].minor.yy269,
            ),
            112 => {
                lhs.yy203 = self.appendSourceTerm(
                    rhs[0].minor.yy203,
                    rhs[1].minor.yy0,
                    rhs[2].minor.yy0,
                    rhs[3].minor.yy0,
                    null,
                    rhs[5].minor.yy269,
                );
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.indexed_by(hooks.context, lhs.yy203, rhs[4].minor.yy0);
            },
            113 => {
                lhs.yy203 = self.appendSourceTerm(
                    rhs[0].minor.yy203,
                    rhs[1].minor.yy0,
                    rhs[2].minor.yy0,
                    rhs[6].minor.yy0,
                    null,
                    rhs[7].minor.yy269,
                );
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.function_args(hooks.context, lhs.yy203, rhs[4].minor.yy14);
            },
            114 => lhs.yy203 = self.appendSourceTerm(
                rhs[0].minor.yy203,
                .{ .z = null, .n = 0 },
                .{ .z = null, .n = 0 },
                rhs[4].minor.yy0,
                rhs[2].minor.yy555,
                rhs[5].minor.yy269,
            ),
            115 => {
                lhs.yy203 = null;
                if (self.action_options.source_list_hooks) |hooks| {
                    lhs.yy203 = hooks.nested_from(
                        hooks.context,
                        rhs[0].minor.yy203,
                        rhs[2].minor.yy203,
                        rhs[4].minor.yy0,
                        rhs[5].minor.yy269,
                    );
                    if (lhs.yy203 == null) self.semantic_out_of_memory = true;
                }
            },
            116 => lhs.yy0 = .{ .z = null, .n = 0 },
            117 => lhs.yy0 = rhs[1].minor.yy0,
            118, 120 => lhs.yy203 = self.appendFullname(rhs[0].minor.yy0, null),
            119, 121 => lhs.yy203 = self.appendFullname(rhs[0].minor.yy0, rhs[2].minor.yy0),
            122 => {
                lhs.yy203 = self.appendFullname(rhs[0].minor.yy0, null);
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.set_alias(hooks.context, lhs.yy203, rhs[2].minor.yy0, self.action_options.rename_mode);
            },
            123 => {
                lhs.yy203 = self.appendFullname(rhs[0].minor.yy0, rhs[2].minor.yy0);
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.set_alias(hooks.context, lhs.yy203, rhs[4].minor.yy0, self.action_options.rename_mode);
            },
            124 => lhs.yy144 = join_type.inner,
            125 => {
                lhs.yy144 = 0;
                if (self.action_options.source_list_hooks) |hooks|
                    lhs.yy144 = hooks.join_type(hooks.context, rhs[0].minor.yy0, null, null);
            },
            126 => {
                lhs.yy144 = 0;
                if (self.action_options.source_list_hooks) |hooks|
                    lhs.yy144 = hooks.join_type(
                        hooks.context,
                        rhs[0].minor.yy0,
                        rhs[1].minor.yy0,
                        null,
                    );
            },
            127 => {
                lhs.yy144 = 0;
                if (self.action_options.source_list_hooks) |hooks|
                    lhs.yy144 = hooks.join_type(
                        hooks.context,
                        rhs[0].minor.yy0,
                        rhs[1].minor.yy0,
                        rhs[2].minor.yy0,
                    );
            },
            128 => lhs.yy269 = .{ .pOn = rhs[1].minor.yy454, .pUsing = null },
            129 => lhs.yy269 = .{ .pOn = null, .pUsing = rhs[2].minor.yy132 },
            130 => lhs.yy269 = .{ .pOn = null, .pUsing = null },
            131 => lhs.yy0 = .{ .z = null, .n = 0 },
            132 => lhs.yy0 = rhs[2].minor.yy0,
            133 => lhs.yy0 = .{ .z = null, .n = 1 },
            134 => lhs.yy14 = null,
            135 => lhs.yy14 = rhs[2].minor.yy14,
            136 => {
                lhs.yy14 = self.appendExprList(rhs[0].minor.yy14, rhs[2].minor.yy454);
                self.setSortOrder(lhs.yy14, rhs[3].minor.yy144, rhs[4].minor.yy144);
            },
            137 => {
                lhs.yy14 = self.appendExprList(null, rhs[0].minor.yy454);
                self.setSortOrder(lhs.yy14, rhs[1].minor.yy144, rhs[2].minor.yy144);
            },
            138, 141 => lhs.yy144 = sort_order.ascending,
            139, 142 => lhs.yy144 = sort_order.descending,
            140, 143 => lhs.yy144 = sort_order.unspecified,
            144 => lhs.yy14 = null,
            145 => lhs.yy14 = rhs[2].minor.yy14,
            146 => lhs.yy454 = null,
            147 => lhs.yy454 = rhs[1].minor.yy454,
            148 => lhs.yy454 = null,
            149 => lhs.yy454 = self.pExpr(tokenizer.token.tk_limit, rhs[1].minor.yy454, null),
            150 => lhs.yy454 = self.pExpr(
                tokenizer.token.tk_limit,
                rhs[1].minor.yy454,
                rhs[3].minor.yy454,
            ),
            151 => lhs.yy454 = self.pExpr(
                tokenizer.token.tk_limit,
                rhs[3].minor.yy454,
                rhs[1].minor.yy454,
            ),
            152 => {
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.indexed_by(hooks.context, rhs[3].minor.yy203, rhs[4].minor.yy0);
                self.emit(.{ .delete_from = .{
                    .source = rhs[3].minor.yy203,
                    .where = rhs[5].minor.yy454,
                } });
            },
            153, 155 => lhs.yy454 = null,
            154, 156 => lhs.yy454 = rhs[1].minor.yy454,
            157 => {
                self.emit(.{ .add_returning = rhs[1].minor.yy14 });
                lhs.yy454 = null;
            },
            158 => {
                self.emit(.{ .add_returning = rhs[3].minor.yy14 });
                lhs.yy454 = rhs[1].minor.yy454;
            },
            159 => {
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.indexed_by(hooks.context, rhs[3].minor.yy203, rhs[4].minor.yy0);
                if (self.action_options.expression_list_hooks) |hooks|
                    hooks.check_length(hooks.context, rhs[6].minor.yy14, "set list");
                self.emit(.{ .update = .{
                    .source = rhs[3].minor.yy203,
                    .changes = rhs[6].minor.yy14,
                    .from = rhs[7].minor.yy203,
                    .where = rhs[8].minor.yy454,
                    .conflict = rhs[2].minor.yy144,
                } });
            },
            160 => {
                lhs.yy14 = self.appendExprList(rhs[0].minor.yy14, rhs[4].minor.yy454);
                self.setListName(lhs.yy14, rhs[2].minor.yy0);
            },
            161 => lhs.yy14 = self.appendVector(
                rhs[0].minor.yy14,
                rhs[3].minor.yy132,
                rhs[6].minor.yy454,
            ),
            162 => {
                lhs.yy14 = self.appendExprList(null, rhs[2].minor.yy454);
                self.setListName(lhs.yy14, rhs[0].minor.yy0);
            },
            163 => lhs.yy14 = self.appendVector(null, rhs[1].minor.yy132, rhs[4].minor.yy454),
            164 => self.emit(.{ .insert = .{
                .source = rhs[3].minor.yy203,
                .select = rhs[5].minor.yy555,
                .columns = rhs[4].minor.yy132,
                .conflict = rhs[1].minor.yy144,
                .default_values = false,
                .upsert = rhs[6].minor.yy122,
            } }),
            165 => self.emit(.{ .insert = .{
                .source = rhs[3].minor.yy203,
                .select = null,
                .columns = rhs[4].minor.yy132,
                .conflict = rhs[1].minor.yy144,
                .default_values = true,
                .upsert = null,
            } }),
            166 => lhs.yy122 = null,
            167 => {
                self.emit(.{ .add_returning = rhs[1].minor.yy14 });
                lhs.yy122 = null;
            },
            168 => lhs.yy122 = self.createUpsert(
                rhs[3].minor.yy14,
                rhs[5].minor.yy454,
                rhs[9].minor.yy14,
                rhs[10].minor.yy454,
                rhs[11].minor.yy122,
                true,
            ),
            169 => lhs.yy122 = self.createUpsert(
                rhs[3].minor.yy14,
                rhs[5].minor.yy454,
                null,
                null,
                rhs[8].minor.yy122,
                false,
            ),
            170 => lhs.yy122 = self.createUpsert(null, null, null, null, null, false),
            171 => lhs.yy122 = self.createUpsert(
                null,
                null,
                rhs[5].minor.yy14,
                rhs[6].minor.yy454,
                null,
                true,
            ),
            172 => self.emit(.{ .add_returning = rhs[1].minor.yy14 }),
            173 => lhs.yy144 = rhs[1].minor.yy144,
            174 => lhs.yy144 = conflict_action.replace,
            175 => lhs.yy132 = null,
            176 => lhs.yy132 = rhs[1].minor.yy132,
            177 => lhs.yy132 = self.appendIdentifier(rhs[0].minor.yy132, rhs[2].minor.yy0),
            178 => lhs.yy132 = self.appendIdentifier(null, rhs[0].minor.yy0),
            179 => lhs.yy454 = rhs[1].minor.yy454,
            180 => lhs.yy454 = self.tokenExpr(tokenizer.token.tk_id, rhs[0].minor.yy0),
            181 => lhs.yy454 = self.pExpr(
                tokenizer.token.tk_dot,
                self.tokenExpr(tokenizer.token.tk_id, rhs[0].minor.yy0),
                self.tokenExpr(tokenizer.token.tk_id, rhs[2].minor.yy0),
            ),
            182 => {
                const first = self.tokenExpr(tokenizer.token.tk_id, rhs[0].minor.yy0);
                const second = self.tokenExpr(tokenizer.token.tk_id, rhs[2].minor.yy0);
                const third = self.tokenExpr(tokenizer.token.tk_id, rhs[4].minor.yy0);
                const tail = self.pExpr(tokenizer.token.tk_dot, second, third);
                if (self.action_options.rename_mode and first != null) {
                    if (self.action_options.expression_hooks) |hooks|
                        hooks.rename_token_remap(hooks.context, first.?);
                }
                lhs.yy454 = self.pExpr(tokenizer.token.tk_dot, first, tail);
            },
            183, 184 => lhs.yy454 = self.tokenExpr(rhs[0].symbol, rhs[0].minor.yy0),
            185 => lhs.yy454 = self.integerExpr(rhs[0].minor.yy0),
            186 => lhs.yy454 = self.variableExpr(rhs[0].minor.yy0),
            187 => lhs.yy454 = self.collateExpr(rhs[0].minor.yy454, rhs[2].minor.yy0),
            188 => lhs.yy454 = self.castExpr(rhs[2].minor.yy454, rhs[4].minor.yy0),
            189 => lhs.yy454 = self.functionExpr(
                rhs[0].minor.yy0,
                rhs[3].minor.yy14,
                rhs[2].minor.yy144,
            ),
            190 => lhs.yy454 = self.orderedFunctionExpr(
                rhs[0].minor.yy0,
                rhs[3].minor.yy14,
                rhs[2].minor.yy144,
                rhs[6].minor.yy14,
            ),
            191 => lhs.yy454 = self.functionExpr(rhs[0].minor.yy0, null, 0),
            192 => {
                lhs.yy454 = self.functionExpr(rhs[0].minor.yy0, rhs[3].minor.yy14, rhs[2].minor.yy144);
                if (self.action_options.window_hooks) |hooks|
                    hooks.attach_expression(hooks.context, lhs.yy454, rhs[5].minor.yy211);
            },
            193 => {
                lhs.yy454 = self.orderedFunctionExpr(
                    rhs[0].minor.yy0,
                    rhs[3].minor.yy14,
                    rhs[2].minor.yy144,
                    rhs[6].minor.yy14,
                );
                if (self.action_options.window_hooks) |hooks|
                    hooks.attach_expression(hooks.context, lhs.yy454, rhs[8].minor.yy211);
            },
            194 => {
                lhs.yy454 = self.functionExpr(rhs[0].minor.yy0, null, 0);
                if (self.action_options.window_hooks) |hooks|
                    hooks.attach_expression(hooks.context, lhs.yy454, rhs[4].minor.yy211);
            },
            195 => lhs.yy454 = self.functionExpr(rhs[0].minor.yy0, null, 0),
            196 => {
                const list = self.appendExprList(rhs[1].minor.yy14, rhs[3].minor.yy454);
                lhs.yy454 = self.vectorExpr(list);
            },
            197 => lhs.yy454 = self.andExpr(rhs[0].minor.yy454, rhs[2].minor.yy454),
            198, 199, 200, 201, 202, 203, 204 => lhs.yy454 = self.pExpr(
                rhs[1].symbol,
                rhs[0].minor.yy454,
                rhs[2].minor.yy454,
            ),
            205 => {
                lhs.yy0 = rhs[1].minor.yy0;
                lhs.yy0.n |= 0x8000_0000;
            },
            206 => {
                var token = rhs[1].minor.yy0;
                const negated = (token.n & 0x8000_0000) != 0;
                token.n &= 0x7fff_ffff;
                lhs.yy454 = self.likeExpr(
                    token,
                    rhs[0].minor.yy454,
                    rhs[2].minor.yy454,
                    null,
                    negated,
                );
            },
            207 => {
                var token = rhs[1].minor.yy0;
                const negated = (token.n & 0x8000_0000) != 0;
                token.n &= 0x7fff_ffff;
                lhs.yy454 = self.likeExpr(
                    token,
                    rhs[0].minor.yy454,
                    rhs[2].minor.yy454,
                    rhs[4].minor.yy454,
                    negated,
                );
            },
            208 => lhs.yy454 = self.isNullExpr(rhs[1].symbol, rhs[0].minor.yy454),
            209 => lhs.yy454 = self.isNullExpr(tokenizer.token.tk_notnull, rhs[0].minor.yy454),
            210 => lhs.yy454 = self.isExpr(tokenizer.token.tk_is, rhs[0].minor.yy454, rhs[2].minor.yy454),
            211 => lhs.yy454 = self.isExpr(tokenizer.token.tk_isnot, rhs[0].minor.yy454, rhs[3].minor.yy454),
            212 => lhs.yy454 = self.isExpr(tokenizer.token.tk_is, rhs[0].minor.yy454, rhs[5].minor.yy454),
            213 => lhs.yy454 = self.isExpr(tokenizer.token.tk_isnot, rhs[0].minor.yy454, rhs[4].minor.yy454),
            214, 215 => lhs.yy454 = self.pExpr(rhs[0].symbol, rhs[1].minor.yy454, null),
            216 => {
                const expression = rhs[1].minor.yy454;
                const op: u16 = rhs[0].symbol + (tokenizer.token.tk_uplus - tokenizer.token.tk_plus);
                if (expression != null and expression.?.op == tokenizer.token.tk_uplus) {
                    expression.?.op = @truncate(op);
                    lhs.yy454 = expression;
                } else {
                    lhs.yy454 = self.pExpr(op, expression, null);
                }
            },
            217 => {
                var list = self.appendExprList(null, rhs[0].minor.yy454);
                list = self.appendExprList(list, rhs[2].minor.yy454);
                lhs.yy454 = self.functionExpr(rhs[1].minor.yy0, list, 0);
            },
            218, 221 => lhs.yy144 = 0,
            219, 222 => lhs.yy144 = 1,
            220 => {
                var bounds = self.appendExprList(null, rhs[2].minor.yy454);
                bounds = self.appendExprList(bounds, rhs[4].minor.yy454);
                lhs.yy454 = self.betweenExpr(rhs[0].minor.yy454, bounds, rhs[1].minor.yy144 != 0);
            },
            223 => lhs.yy454 = self.inListExpr(
                rhs[0].minor.yy454,
                rhs[3].minor.yy14,
                rhs[1].minor.yy144 != 0,
            ),
            224 => lhs.yy454 = self.selectExpr(tokenizer.token.tk_select, rhs[1].minor.yy555),
            225 => lhs.yy454 = self.inSelectExpr(
                rhs[0].minor.yy454,
                rhs[3].minor.yy555,
                rhs[1].minor.yy144 != 0,
            ),
            226 => lhs.yy454 = self.inTableExpr(
                rhs[0].minor.yy454,
                rhs[2].minor.yy0,
                rhs[3].minor.yy0,
                rhs[4].minor.yy14,
                rhs[1].minor.yy144 != 0,
            ),
            227 => lhs.yy454 = self.selectExpr(tokenizer.token.tk_exists, rhs[2].minor.yy555),
            228 => lhs.yy454 = self.caseExpr(
                rhs[1].minor.yy454,
                rhs[2].minor.yy14,
                rhs[3].minor.yy454,
            ),
            229 => {
                const list = self.appendExprList(rhs[0].minor.yy14, rhs[2].minor.yy454);
                lhs.yy14 = self.appendExprList(list, rhs[4].minor.yy454);
            },
            230 => {
                const list = self.appendExprList(null, rhs[1].minor.yy454);
                lhs.yy14 = self.appendExprList(list, rhs[3].minor.yy454);
            },
            231 => lhs.yy454 = rhs[1].minor.yy454,
            232, 233 => lhs.yy454 = null,
            234, 237, 242 => lhs.yy14 = null,
            235 => lhs.yy14 = self.appendExprList(rhs[0].minor.yy14, rhs[2].minor.yy454),
            236 => lhs.yy14 = self.appendExprList(null, rhs[0].minor.yy454),
            238, 243 => lhs.yy14 = rhs[1].minor.yy14,
            239 => self.emit(.{ .create_index = .{
                .name = rhs[4].minor.yy0,
                .database = rhs[5].minor.yy0,
                .table = rhs[7].minor.yy0,
                .columns = rhs[9].minor.yy14,
                .where = rhs[11].minor.yy454,
                .conflict = rhs[1].minor.yy144,
                .if_not_exists = rhs[3].minor.yy144 != 0,
            } }),
            240 => lhs.yy144 = conflict_action.abort,
            241 => lhs.yy144 = foreign_action.none,
            244 => lhs.yy14 = self.appendIdTerm(
                rhs[0].minor.yy14,
                rhs[2].minor.yy0,
                rhs[3].minor.yy144,
                rhs[4].minor.yy144,
            ),
            245 => lhs.yy14 = self.appendIdTerm(
                null,
                rhs[0].minor.yy0,
                rhs[1].minor.yy144,
                rhs[2].minor.yy144,
            ),
            246 => lhs.yy144 = 0,
            247 => lhs.yy144 = 1,
            248 => self.emit(.{ .drop_index = .{
                .source = rhs[3].minor.yy203,
                .if_exists = rhs[2].minor.yy144 != 0,
            } }),
            249 => self.emit(.{ .vacuum = .{ .schema = null, .into = rhs[1].minor.yy454 } }),
            250 => self.emit(.{ .vacuum = .{ .schema = rhs[1].minor.yy0, .into = rhs[2].minor.yy454 } }),
            251 => lhs.yy454 = rhs[1].minor.yy454,
            252 => lhs.yy454 = null,
            253 => self.emit(.{ .pragma = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
                .value = null,
                .negative = false,
            } }),
            254 => self.emit(.{ .pragma = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
                .value = rhs[4].minor.yy0,
                .negative = false,
            } }),
            255 => self.emit(.{ .pragma = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
                .value = rhs[4].minor.yy0,
                .negative = false,
            } }),
            256 => self.emit(.{ .pragma = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
                .value = rhs[4].minor.yy0,
                .negative = true,
            } }),
            257 => self.emit(.{ .pragma = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
                .value = rhs[4].minor.yy0,
                .negative = true,
            } }),
            258 => lhs.yy0 = rhs[1].minor.yy0,
            259 => lhs.yy0 = .{
                .z = rhs[0].minor.yy0.z,
                .n = tokenSpanLength(rhs[0].minor.yy0, rhs[1].minor.yy0),
            },
            260 => if (self.action_options.trigger_hooks) |hooks| {
                hooks.finish(hooks.context, rhs[3].minor.yy427, .{
                    .z = rhs[2].minor.yy0.z,
                    .n = tokenSpanLength(rhs[2].minor.yy0, rhs[4].minor.yy0),
                });
            },
            261 => {
                if (self.action_options.trigger_hooks) |hooks|
                    hooks.begin(
                        hooks.context,
                        rhs[3].minor.yy0,
                        rhs[4].minor.yy0,
                        rhs[5].minor.yy144,
                        rhs[6].minor.yy286,
                        rhs[8].minor.yy203,
                        rhs[10].minor.yy454,
                        rhs[0].minor.yy144 != 0,
                        rhs[2].minor.yy144 != 0,
                    );
                lhs.yy0 = if (rhs[4].minor.yy0.n == 0) rhs[3].minor.yy0 else rhs[4].minor.yy0;
            },
            262 => lhs.yy144 = rhs[0].symbol,
            263 => lhs.yy144 = tokenizer.token.tk_instead,
            264 => lhs.yy144 = tokenizer.token.tk_before,
            265, 266 => lhs.yy286 = .{ .a = rhs[0].symbol, .b = null },
            267 => lhs.yy286 = .{ .a = tokenizer.token.tk_update, .b = rhs[2].minor.yy132 },
            268 => lhs.yy454 = null,
            269 => lhs.yy454 = rhs[1].minor.yy454,
            270 => {
                lhs.yy427 = null;
                if (self.action_options.trigger_hooks) |hooks| {
                    lhs.yy427 = hooks.append_step(
                        hooks.context,
                        rhs[0].minor.yy427,
                        rhs[1].minor.yy427,
                    );
                    if (lhs.yy427 == null) self.semantic_out_of_memory = true;
                }
            },
            271 => {
                lhs.yy427 = null;
                if (self.action_options.trigger_hooks) |hooks| {
                    lhs.yy427 = hooks.append_step(hooks.context, null, rhs[0].minor.yy427);
                    if (lhs.yy427 == null) self.semantic_out_of_memory = true;
                }
            },
            272 => lhs.yy0 = rhs[2].minor.yy0,
            273 => lhs.yy0 = .{ .z = null, .n = 1 },
            274 => {
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.indexed_by(hooks.context, rhs[2].minor.yy203, rhs[3].minor.yy0);
                if (self.action_options.expression_list_hooks) |hooks|
                    hooks.check_length(hooks.context, rhs[5].minor.yy14, "set list");
                lhs.yy427 = null;
                if (self.action_options.trigger_hooks) |hooks| {
                    lhs.yy427 = hooks.update_step(
                        hooks.context,
                        rhs[2].minor.yy203,
                        rhs[1].minor.yy144,
                        rhs[5].minor.yy14,
                        rhs[6].minor.yy203,
                        rhs[7].minor.yy454,
                        rhs[0].minor.yy0.z,
                        rhs[8].minor.yy168,
                    );
                    if (lhs.yy427 == null) self.semantic_out_of_memory = true;
                }
            },
            275 => {
                lhs.yy427 = null;
                if (self.action_options.trigger_hooks) |hooks| {
                    lhs.yy427 = hooks.insert_step(
                        hooks.context,
                        rhs[3].minor.yy203,
                        rhs[5].minor.yy555,
                        rhs[4].minor.yy132,
                        rhs[1].minor.yy144,
                        rhs[6].minor.yy122,
                        rhs[0].minor.yy168,
                        rhs[7].minor.yy168,
                    );
                    if (lhs.yy427 == null) self.semantic_out_of_memory = true;
                }
            },
            276 => {
                if (self.action_options.source_list_hooks) |hooks|
                    hooks.indexed_by(hooks.context, rhs[2].minor.yy203, rhs[3].minor.yy0);
                lhs.yy427 = null;
                if (self.action_options.trigger_hooks) |hooks| {
                    lhs.yy427 = hooks.delete_step(
                        hooks.context,
                        rhs[2].minor.yy203,
                        rhs[4].minor.yy454,
                        rhs[0].minor.yy0.z,
                        rhs[5].minor.yy168,
                    );
                    if (lhs.yy427 == null) self.semantic_out_of_memory = true;
                }
            },
            277 => {
                lhs.yy427 = null;
                if (self.action_options.trigger_hooks) |hooks| {
                    lhs.yy427 = hooks.select_step(
                        hooks.context,
                        rhs[1].minor.yy555,
                        rhs[0].minor.yy168,
                        rhs[2].minor.yy168,
                    );
                    if (lhs.yy427 == null) self.semantic_out_of_memory = true;
                }
            },
            278 => lhs.yy454 = self.raiseExpr(conflict_action.ignore, null),
            279 => lhs.yy454 = self.raiseExpr(rhs[2].minor.yy144, rhs[4].minor.yy454),
            280 => lhs.yy144 = conflict_action.rollback,
            281 => lhs.yy144 = conflict_action.abort,
            282 => lhs.yy144 = conflict_action.fail,
            283 => self.emit(.{ .drop_trigger = .{
                .source = rhs[3].minor.yy203,
                .if_exists = rhs[2].minor.yy144 != 0,
            } }),
            284 => self.emit(.{ .attach = .{
                .filename = rhs[2].minor.yy454,
                .schema = rhs[4].minor.yy454,
                .key = rhs[5].minor.yy454,
            } }),
            285 => self.emit(.{ .detach = rhs[2].minor.yy454 }),
            286 => lhs.yy454 = null,
            287 => lhs.yy454 = rhs[1].minor.yy454,
            288 => self.emit(.{ .reindex = .{ .name = null, .database = null } }),
            289 => self.emit(.{ .reindex = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
            } }),
            290 => self.emit(.{ .analyze = .{ .name = null, .database = null } }),
            291 => self.emit(.{ .analyze = .{
                .name = rhs[1].minor.yy0,
                .database = rhs[2].minor.yy0,
            } }),
            292 => self.emit(.{ .alter_rename_table = .{
                .source = rhs[2].minor.yy203,
                .new_name = rhs[5].minor.yy0,
            } }),
            293 => {
                lhs.yy0.n = tokenSpanLength(lhs.yy0, self.last_token);
                self.emit(.{ .alter_finish_add_column = lhs.yy0 });
            },
            294 => {
                self.emit(.disable_lookaside);
                self.emit(.{ .alter_begin_add_column = .{
                    .source = rhs[2].minor.yy203,
                    .column = rhs[5].minor.yy0,
                    .type_name = rhs[6].minor.yy0,
                } });
                lhs.yy0 = rhs[5].minor.yy0;
            },
            295 => self.emit(.{ .alter_drop_column = .{
                .source = rhs[2].minor.yy203,
                .column = rhs[4].minor.yy0,
            } }),
            296 => self.emit(.{ .alter_rename_column = .{
                .source = rhs[2].minor.yy203,
                .old = rhs[5].minor.yy0,
                .new = rhs[7].minor.yy0,
            } }),
            297 => self.emit(.{ .alter_drop_constraint = .{
                .source = rhs[2].minor.yy203,
                .name = rhs[5].minor.yy0,
            } }),
            298 => self.emit(.{ .alter_drop_not_null = .{
                .source = rhs[2].minor.yy203,
                .column = rhs[5].minor.yy0,
            } }),
            299 => self.emit(.{ .alter_set_not_null = .{
                .source = rhs[2].minor.yy203,
                .column = rhs[5].minor.yy0,
                .conflict = rhs[9].minor.yy144,
            } }),
            300 => self.emit(.{ .alter_add_check = .{
                .source = rhs[2].minor.yy203,
                .name = rhs[5].minor.yy0,
                .expression = rhs[8].minor.yy454,
                .open = rhs[7].minor.yy0,
                .close = rhs[9].minor.yy0,
            } }),
            301 => self.emit(.{ .alter_add_check = .{
                .source = rhs[2].minor.yy203,
                .name = null,
                .expression = rhs[6].minor.yy454,
                .open = rhs[5].minor.yy0,
                .close = rhs[7].minor.yy0,
            } }),
            302 => self.emit(.{ .vtab_finish = null }),
            303 => self.emit(.{ .vtab_finish = rhs[3].minor.yy0 }),
            304 => self.emit(.{ .vtab_begin = .{
                .name = rhs[4].minor.yy0,
                .database = rhs[5].minor.yy0,
                .module = rhs[7].minor.yy0,
                .if_not_exists = rhs[3].minor.yy144 != 0,
            } }),
            305 => self.emit(.vtab_arg_init),
            306 => self.emit(.{ .vtab_arg_extend = rhs[0].minor.yy0 }),
            307 => self.emit(.{ .vtab_arg_extend = rhs[2].minor.yy0 }),
            308 => self.emit(.{ .vtab_arg_extend = rhs[0].minor.yy0 }),
            309 => if (self.action_options.with_hooks) |hooks|
                hooks.push(hooks.context, rhs[1].minor.yy59),
            310 => if (self.action_options.with_hooks) |hooks|
                hooks.push(hooks.context, rhs[2].minor.yy59),
            311 => lhs.yy462 = materialized.any,
            312 => lhs.yy462 = materialized.yes,
            313 => lhs.yy462 = materialized.no,
            314 => {
                lhs.yy67 = null;
                if (self.action_options.with_hooks) |hooks| {
                    lhs.yy67 = hooks.create_cte(
                        hooks.context,
                        rhs[0].minor.yy0,
                        rhs[1].minor.yy14,
                        rhs[4].minor.yy555,
                        rhs[2].minor.yy462,
                    );
                    if (lhs.yy67 == null) self.semantic_out_of_memory = true;
                }
            },
            315 => if (self.action_options.with_hooks) |hooks| hooks.mark_present(hooks.context),
            316 => {
                lhs.yy59 = null;
                if (self.action_options.with_hooks) |hooks| {
                    lhs.yy59 = hooks.add(hooks.context, null, rhs[0].minor.yy67);
                    if (lhs.yy59 == null) self.semantic_out_of_memory = true;
                }
            },
            317 => {
                lhs.yy59 = null;
                if (self.action_options.with_hooks) |hooks| {
                    lhs.yy59 = hooks.add(hooks.context, rhs[0].minor.yy59, rhs[2].minor.yy67);
                    if (lhs.yy59 == null) self.semantic_out_of_memory = true;
                }
            },
            318 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.chain(hooks.context, rhs[2].minor.yy211, rhs[0].minor.yy211);
            },
            319 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.set_name(hooks.context, rhs[3].minor.yy211, rhs[0].minor.yy0);
            },
            320 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.assemble(
                        hooks.context,
                        rhs[4].minor.yy211,
                        rhs[2].minor.yy14,
                        rhs[3].minor.yy14,
                        null,
                    );
            },
            321 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.assemble(
                        hooks.context,
                        rhs[5].minor.yy211,
                        rhs[3].minor.yy14,
                        rhs[4].minor.yy14,
                        rhs[0].minor.yy0,
                    );
            },
            322 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.assemble(
                        hooks.context,
                        rhs[3].minor.yy211,
                        null,
                        rhs[2].minor.yy14,
                        null,
                    );
            },
            323 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.assemble(
                        hooks.context,
                        rhs[4].minor.yy211,
                        null,
                        rhs[3].minor.yy14,
                        rhs[0].minor.yy0,
                    );
            },
            324 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.assemble(
                        hooks.context,
                        rhs[1].minor.yy211,
                        null,
                        null,
                        rhs[0].minor.yy0,
                    );
            },
            325 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.allocate(
                        hooks.context,
                        0,
                        .{ .eType = tokenizer.token.tk_unbounded, .pExpr = null },
                        .{ .eType = tokenizer.token.tk_current, .pExpr = null },
                        0,
                    );
            },
            326 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.allocate(
                        hooks.context,
                        rhs[0].minor.yy144,
                        rhs[1].minor.yy509,
                        .{ .eType = tokenizer.token.tk_current, .pExpr = null },
                        rhs[2].minor.yy462,
                    );
            },
            327 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.allocate(
                        hooks.context,
                        rhs[0].minor.yy144,
                        rhs[2].minor.yy509,
                        rhs[4].minor.yy509,
                        rhs[5].minor.yy462,
                    );
            },
            328 => lhs.yy144 = rhs[0].symbol,
            329, 331 => lhs.yy509 = rhs[0].minor.yy509,
            330, 332, 334 => lhs.yy509 = .{ .eType = rhs[0].symbol, .pExpr = null },
            333 => lhs.yy509 = .{ .eType = rhs[1].symbol, .pExpr = rhs[0].minor.yy454 },
            335 => lhs.yy462 = 0,
            336 => lhs.yy462 = rhs[1].minor.yy462,
            337, 338, 339 => lhs.yy462 = @truncate(rhs[0].symbol),
            340 => lhs.yy211 = rhs[1].minor.yy211,
            341 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.attach_filter(
                        hooks.context,
                        rhs[1].minor.yy211,
                        rhs[0].minor.yy454,
                    );
            },
            342 => lhs.yy211 = rhs[0].minor.yy211,
            343 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.filter_only(hooks.context, rhs[0].minor.yy454);
            },
            344 => lhs.yy211 = rhs[2].minor.yy211,
            345 => {
                lhs.yy211 = null;
                if (self.action_options.window_hooks) |hooks|
                    lhs.yy211 = hooks.named_over(hooks.context, rhs[1].minor.yy0);
            },
            346 => lhs.yy454 = rhs[3].minor.yy454,
            347 => lhs.yy454 = self.qnumberExpr(rhs[0].minor.yy0),
            else => {},
        }
    }

    fn reduce(self: *Machine, action: u16, lookahead: SemanticValue) !u16 {
        const rule_index = action - tables.min_reduce;
        const rule = tables.rules[rule_index];
        std.debug.assert(rule.rhs_count < self.stack.items.len);
        const base_index = self.stack.items.len - rule.rhs_count - 1;
        if (rule.rhs_count == 0) try self.stack.ensureUnusedCapacity(self.allocator, 1);
        const rhs = self.stack.items[base_index + 1 ..];
        // Lemon initializes the LHS from the first RHS value before running a
        // generated action. Only rules with a typed local-flow contract may
        // observe that inherited union value. A future generated action lacking
        // a contract remains inert so token bits cannot become owned pointers.
        const inherits_first_rhs = hasTypedActionContract(rule_index) or
            rule_index >= tables.rules_with_actions;
        var minor = if (inherits_first_rhs and rhs.len != 0)
            rhs[0].minor
        else
            SemanticValue{ .yyinit = 0 };
        self.executeTypedActionContract(rule_index, rhs, lookahead, &minor);
        if (self.semantic_out_of_memory) return error.OutOfMemory;
        const next = tables.reduceAction(self.stack.items[base_index].state, rule.lhs);
        std.debug.assert(!(next > tables.max_shift and next <= tables.max_shift_reduce));
        std.debug.assert(next != tables.error_action);
        self.stack.shrinkRetainingCapacity(base_index + 1);
        self.stack.appendAssumeCapacity(.{ .state = next, .symbol = rule.lhs, .minor = minor });
        return next;
    }

    fn feed(self: *Machine, token: u16, minor: SemanticValue) !FeedResult {
        var action = self.stack.items[self.stack.items.len - 1].state;
        while (true) {
            action = tables.shiftAction(action, token);
            if (action >= tables.min_reduce) {
                action = try self.reduce(action, minor);
                continue;
            }
            if (action <= tables.max_shift_reduce) {
                const state = if (action > tables.max_shift)
                    action + tables.min_reduce - tables.min_shift_reduce
                else
                    action;
                try self.stack.append(self.allocator, .{ .state = state, .symbol = token, .minor = minor });
                return .shifted;
            }
            if (action == tables.accept_action) {
                std.debug.assert(self.stack.items.len == 2);
                self.stack.shrinkRetainingCapacity(1);
                return .accepted;
            }
            std.debug.assert(action == tables.error_action);
            if (self.destructor_callback) |callback| {
                var rejected = minor;
                destroySymbol(token, &rejected, self.destructor_context, callback);
            }
            return .syntax_error;
        }
    }
};

pub fn recognizeWithHooks(
    allocator: std.mem.Allocator,
    sql: []const u8,
    action_options: ActionOptions,
    action_context: ?*anyopaque,
    action_callback: ?ActionCallback,
    destructor_context: ?*anyopaque,
    destructor_callback: ?DestructorCallback,
) Result {
    const terminated = allocator.dupeZ(u8, sql) catch return .out_of_memory;
    defer allocator.free(terminated);
    var machine = Machine.init(allocator, action_options, action_context, action_callback, destructor_context, destructor_callback) catch return .out_of_memory;
    defer machine.deinit();
    machine.sql_origin = terminated.ptr;

    var current: [*:0]const u8 = terminated.ptr;
    while (current[0] != 0) {
        const start = current;
        const token = tokenizer.get(current);
        if (token.length == 0) return .syntax_error;
        current += token.length;
        if (token.token_type == tokenizer.token.tk_space or
            token.token_type == tokenizer.token.tk_comment)
        {
            continue;
        }
        const minor = SemanticValue{ .yy0 = .{ .z = start, .n = @intCast(token.length) } };
        machine.last_token = minor.yy0;
        const result = machine.feed(token.token_type, minor) catch return .out_of_memory;
        if (result == .syntax_error) return .syntax_error;
    }
    return switch (machine.feed(0, .{ .yyinit = 0 }) catch return .out_of_memory) {
        .accepted => .accepted,
        .shifted, .syntax_error => .syntax_error,
    };
}

pub fn recognizeWithActions(
    allocator: std.mem.Allocator,
    sql: []const u8,
    action_options: ActionOptions,
    action_context: ?*anyopaque,
    action_callback: ?ActionCallback,
) Result {
    return recognizeWithHooks(allocator, sql, action_options, action_context, action_callback, null, null);
}

pub fn recognize(allocator: std.mem.Allocator, sql: []const u8) Result {
    return recognizeWithHooks(allocator, sql, .{}, null, null, null, null);
}

test "initial transaction semantic actions preserve values and callback order" {
    const Capture = struct {
        kinds: [8]std.meta.Tag(Action) = undefined,
        count: usize = 0,
        transaction_mode: c_int = -1,
        end_token: u16 = 0,
        savepoint_operation: SavepointOperation = .begin,
        savepoint_name: [16]u8 = undefined,
        savepoint_name_length: usize = 0,

        fn record(raw: ?*anyopaque, action: Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.kinds[self.count] = std.meta.activeTag(action);
            self.count += 1;
            switch (action) {
                .begin_transaction => |mode| self.transaction_mode = mode,
                .end_transaction => |token| self.end_token = token,
                .savepoint => |savepoint| {
                    self.savepoint_operation = savepoint.operation;
                    self.savepoint_name_length = savepoint.name.n;
                    @memcpy(self.savepoint_name[0..savepoint.name.n], savepoint.name.z.?[0..savepoint.name.n]);
                },
                else => {},
            }
        }
    };

    var capture = Capture{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "BEGIN IMMEDIATE;", .{}, &capture, Capture.record));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(std.meta.Tag(Action).begin_transaction, capture.kinds[0]);
    try std.testing.expectEqual(std.meta.Tag(Action).finish_coding, capture.kinds[1]);
    try std.testing.expectEqual(@as(c_int, tokenizer.token.tk_immediate), capture.transaction_mode);

    capture.count = 0;
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "ROLLBACK;", .{}, &capture, Capture.record));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(@as(u16, tokenizer.token.tk_rollback), capture.end_token);

    capture.count = 0;
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "SAVEPOINT alpha;", .{}, &capture, Capture.record));
    try std.testing.expectEqual(SavepointOperation.begin, capture.savepoint_operation);
    try std.testing.expectEqualStrings("alpha", capture.savepoint_name[0..capture.savepoint_name_length]);

    capture.count = 0;
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "EXPLAIN COMMIT;", .{}, &capture, Capture.record));
    try std.testing.expectEqual(std.meta.Tag(Action).explain, capture.kinds[0]);
    try std.testing.expectEqual(std.meta.Tag(Action).end_transaction, capture.kinds[1]);
    try std.testing.expectEqual(std.meta.Tag(Action).finish_coding, capture.kinds[2]);

    capture.count = 0;
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "EXPLAIN COMMIT;", .{ .is_reprepare = true }, &capture, Capture.record));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(std.meta.Tag(Action).end_transaction, capture.kinds[0]);
    try std.testing.expectEqual(std.meta.Tag(Action).finish_coding, capture.kinds[1]);
}

test "create-table semantic actions preserve options and owner order" {
    const Capture = struct {
        kinds: [16]std.meta.Tag(Action) = undefined,
        count: usize = 0,
        is_temporary: bool = false,
        if_not_exists: bool = false,
        name: [16]u8 = undefined,
        name_length: usize = 0,
        column_type: [32]u8 = undefined,
        column_type_length: usize = 0,
        flags: u32 = 0,
        unknown_count: usize = 0,
        primary_key_conflict: c_int = -1,
        primary_key_order: c_int = 99,
        primary_key_autoincrement: bool = true,
        not_null_conflict: c_int = -1,
        unique_conflict: c_int = -1,
        foreign_actions: c_int = -1,
        foreign_table: [16]u8 = undefined,
        foreign_table_length: usize = 0,
        foreign_deferred: bool = false,
        collation: [16]u8 = undefined,
        collation_length: usize = 0,
        constraint_set_count: usize = 0,
        constraint_clear_count: usize = 0,

        fn copyToken(output: []u8, token: parse_types.Token) usize {
            const length: usize = token.n;
            if (length != 0) @memcpy(output[0..length], token.z.?[0..length]);
            return length;
        }

        fn record(raw: ?*anyopaque, action: Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.kinds[self.count] = std.meta.activeTag(action);
            self.count += 1;
            switch (action) {
                .start_table => |start| {
                    self.is_temporary = start.is_temporary;
                    self.if_not_exists = start.if_not_exists;
                    self.name_length = copyToken(&self.name, start.name);
                },
                .end_table => |end| self.flags = end.flags,
                .unknown_table_option => self.unknown_count += 1,
                .add_column => |column| self.column_type_length = copyToken(&self.column_type, column.type_name),
                .add_primary_key => |key| {
                    self.primary_key_conflict = key.conflict;
                    self.primary_key_order = key.order;
                    self.primary_key_autoincrement = key.autoincrement;
                },
                .add_not_null => |conflict| self.not_null_conflict = conflict,
                .create_unique => |unique| self.unique_conflict = unique.conflict,
                .create_foreign_key => |foreign| {
                    self.foreign_actions = foreign.actions;
                    self.foreign_table_length = copyToken(&self.foreign_table, foreign.table);
                },
                .defer_foreign_key => |deferred| self.foreign_deferred = deferred,
                .add_collation => |collation| self.collation_length = copyToken(&self.collation, collation),
                .set_constraint_name => self.constraint_set_count += 1,
                .clear_constraint_name => self.constraint_clear_count += 1,
                else => {},
            }
        }
    };

    var capture = Capture{};
    const sql = "CREATE TEMP TABLE IF NOT EXISTS t(a VARCHAR(10) PRIMARY KEY) WITHOUT ROWID, STRICT;";
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, sql, .{}, &capture, Capture.record));
    try std.testing.expectEqual(@as(usize, 6), capture.count);
    try std.testing.expectEqual(std.meta.Tag(Action).disable_lookaside, capture.kinds[0]);
    try std.testing.expectEqual(std.meta.Tag(Action).start_table, capture.kinds[1]);
    try std.testing.expectEqual(std.meta.Tag(Action).add_column, capture.kinds[2]);
    try std.testing.expectEqual(std.meta.Tag(Action).add_primary_key, capture.kinds[3]);
    try std.testing.expectEqual(std.meta.Tag(Action).end_table, capture.kinds[4]);
    try std.testing.expectEqual(std.meta.Tag(Action).finish_coding, capture.kinds[5]);
    try std.testing.expect(capture.is_temporary);
    try std.testing.expect(capture.if_not_exists);
    try std.testing.expectEqualStrings("t", capture.name[0..capture.name_length]);
    try std.testing.expectEqualStrings("VARCHAR(10)", capture.column_type[0..capture.column_type_length]);
    try std.testing.expectEqual(table_flag.without_rowid | table_flag.no_visible_rowid | table_flag.strict, capture.flags);
    try std.testing.expectEqual(conflict_action.default, capture.primary_key_conflict);
    try std.testing.expectEqual(sort_order.unspecified, capture.primary_key_order);
    try std.testing.expect(!capture.primary_key_autoincrement);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "CREATE TABLE t(a) strange;", .{}, &capture, Capture.record));
    try std.testing.expectEqual(@as(usize, 1), capture.unknown_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(std.testing.allocator, "CREATE TEMP TABLE t(a);", .{ .schema_init_busy = true }, &capture, Capture.record));
    try std.testing.expect(!capture.is_temporary);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE TABLE constraints(a INTEGER PRIMARY KEY DESC ON CONFLICT REPLACE AUTOINCREMENT, b NOT NULL ON CONFLICT IGNORE UNIQUE ON CONFLICT REPLACE);",
        .{},
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(conflict_action.replace, capture.primary_key_conflict);
    try std.testing.expectEqual(sort_order.descending, capture.primary_key_order);
    try std.testing.expect(capture.primary_key_autoincrement);
    try std.testing.expectEqual(conflict_action.ignore, capture.not_null_conflict);
    try std.testing.expectEqual(conflict_action.replace, capture.unique_conflict);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE TABLE refs(a REFERENCES parent(id) ON DELETE CASCADE ON UPDATE SET NULL DEFERRABLE INITIALLY DEFERRED COLLATE nocase);",
        .{},
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqualStrings("parent", capture.foreign_table[0..capture.foreign_table_length]);
    try std.testing.expectEqual(
        foreign_action.cascade | (foreign_action.set_null << 8),
        capture.foreign_actions,
    );
    try std.testing.expect(capture.foreign_deferred);
    try std.testing.expectEqualStrings("nocase", capture.collation[0..capture.collation_length]);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE TABLE table_keys(a,b, CONSTRAINT pk PRIMARY KEY(a,b) ON CONFLICT IGNORE, UNIQUE(b) ON CONFLICT REPLACE, FOREIGN KEY(b) REFERENCES p(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED);",
        .{},
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(conflict_action.ignore, capture.primary_key_conflict);
    try std.testing.expectEqual(sort_order.ascending, capture.primary_key_order);
    try std.testing.expect(!capture.primary_key_autoincrement);
    try std.testing.expectEqual(conflict_action.replace, capture.unique_conflict);
    try std.testing.expectEqualStrings("p", capture.foreign_table[0..capture.foreign_table_length]);
    try std.testing.expectEqual(foreign_action.restrict, capture.foreign_actions);
    try std.testing.expect(capture.foreign_deferred);
    try std.testing.expectEqual(@as(usize, 1), capture.constraint_set_count);
    try std.testing.expect(capture.constraint_clear_count >= 1);
}

test "lexical term constructors feed DEFAULT owner actions" {
    const Factory = struct {
        arena: std.heap.ArenaAllocator,
        destroy_count: usize = 0,
        truth_conversion_count: usize = 0,
        rename_remap_count: usize = 0,
        list_destroy_count: usize = 0,
        last_list_count: usize = 0,
        last_list_order: c_int = 99,
        last_list_nulls: c_int = 99,
        function_call_count: usize = 0,
        last_function_arg_count: usize = 0,
        last_function_distinct: c_int = -1,
        error_offset_count: usize = 0,
        list_name_count: usize = 0,
        list_span_count: usize = 0,
        list_vector_count: usize = 0,
        list_check_count: usize = 0,
        list_id_term_count: usize = 0,
        cte_create_count: usize = 0,
        with_add_count: usize = 0,
        with_attach_count: usize = 0,
        with_push_count: usize = 0,
        with_mark_count: usize = 0,
        with_destroy_count: usize = 0,
        last_materialized: u8 = 99,
        window_allocate_count: usize = 0,
        window_assemble_count: usize = 0,
        window_chain_count: usize = 0,
        window_expression_count: usize = 0,
        window_select_definition_count: usize = 0,
        window_destroy_count: usize = 0,
        trigger_begin_count: usize = 0,
        trigger_finish_count: usize = 0,
        trigger_update_step_count: usize = 0,
        trigger_insert_step_count: usize = 0,
        trigger_delete_step_count: usize = 0,
        trigger_select_step_count: usize = 0,
        trigger_destroy_count: usize = 0,
        upsert_create_count: usize = 0,
        upsert_destroy_count: usize = 0,
        last_upsert_is_update: bool = false,
        select_create_count: usize = 0,
        select_compound_count: usize = 0,
        select_multi_values_count: usize = 0,
        select_multi_values_end_count: usize = 0,
        select_double_link_count: usize = 0,
        select_destroy_count: usize = 0,
        last_select_result_count: usize = 0,
        last_select_source_count: usize = 0,
        last_select_flags: c_int = -1,
        last_select_where_op: u8 = 0,
        last_select_limit_op: u8 = 0,
        select_expr_count: usize = 0,
        in_select_expr_count: usize = 0,
        case_expr_count: usize = 0,
        source_fullname_count: usize = 0,
        source_alias_count: usize = 0,
        source_shift_count: usize = 0,
        source_join_set_count: usize = 0,
        source_indexed_count: usize = 0,
        source_function_args_count: usize = 0,
        source_subquery_count: usize = 0,
        source_nested_count: usize = 0,
        source_using_count: usize = 0,
        identifier_destroy_count: usize = 0,
        last_identifier_count: usize = 0,
        source_destroy_count: usize = 0,
        last_source_join_type: c_int = -1,
        last_source_on_op: u8 = 0,
        fail_allocation: bool = false,

        const TestList = struct {
            count: usize = 0,
            order: c_int = 99,
            nulls: c_int = 99,
        };

        const TestSource = struct {
            count: usize = 0,
            last_join_type: c_int = -1,
        };

        const TestIdentifiers = struct {
            count: usize = 0,
        };

        const TestWith = struct {
            count: usize = 0,
        };

        const TestWindow = struct {
            marker: u8 = 0,
        };

        const TestTriggerStep = struct {
            count: usize = 1,
        };

        fn node(self: *@This(), op: u16) ?*parse_types.Expr {
            if (self.fail_allocation) return null;
            const expression = self.arena.allocator().create(parse_types.Expr) catch return null;
            expression.* = std.mem.zeroes(parse_types.Expr);
            expression.op = @truncate(op);
            return expression;
        }

        fn token(raw: ?*anyopaque, op: u16, _: parse_types.Token) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(op);
        }

        fn integer(raw: ?*anyopaque, _: parse_types.Token) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_integer);
        }

        fn function(
            raw: ?*anyopaque,
            _: parse_types.Token,
            list: ?*parse_types.ExprList,
            distinct: c_int,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.function_call_count += 1;
            self.last_function_arg_count = if (list) |pointer|
                @as(*TestList, @ptrCast(@alignCast(pointer))).count
            else
                0;
            self.last_function_distinct = distinct;
            return self.node(tokenizer.token.tk_function);
        }

        fn orderedFunction(
            raw: ?*anyopaque,
            _: parse_types.Token,
            _: ?*parse_types.ExprList,
            _: c_int,
            _: ?*parse_types.ExprList,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_function);
        }

        fn variable(
            raw: ?*anyopaque,
            _: parse_types.Token,
            _: bool,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_variable);
        }

        fn qnumber(raw: ?*anyopaque, _: parse_types.Token) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_qnumber);
        }

        fn bareExpr(raw: ?*anyopaque, op: u16) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(op);
        }

        fn pExpr(
            raw: ?*anyopaque,
            op: u16,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(op);
        }

        fn andExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_and);
        }

        fn collateExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: parse_types.Token,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_collate);
        }

        fn castExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: parse_types.Token,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_cast);
        }

        fn isNullExpr(
            raw: ?*anyopaque,
            op: u16,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(op);
        }

        fn isExpr(
            raw: ?*anyopaque,
            op: u16,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(op);
        }

        fn betweenExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: ?*parse_types.ExprList,
            negated: bool,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(if (negated) tokenizer.token.tk_not else tokenizer.token.tk_between);
        }

        fn inListExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: ?*parse_types.ExprList,
            negated: bool,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(if (negated) tokenizer.token.tk_not else tokenizer.token.tk_in);
        }

        fn selectExpr(
            raw: ?*anyopaque,
            op: u16,
            _: ?*parse_types.Select,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.select_expr_count += 1;
            return self.node(op);
        }

        fn inSelectExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Select,
            negated: bool,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.in_select_expr_count += 1;
            return self.node(if (negated) tokenizer.token.tk_not else tokenizer.token.tk_in);
        }

        fn caseExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: ?*parse_types.ExprList,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.case_expr_count += 1;
            return self.node(tokenizer.token.tk_case);
        }

        fn vectorExpr(raw: ?*anyopaque, _: ?*parse_types.ExprList) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_vector);
        }

        fn likeExpr(
            raw: ?*anyopaque,
            _: parse_types.Token,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Expr,
            negated: bool,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(if (negated) tokenizer.token.tk_not else tokenizer.token.tk_function);
        }

        fn inTableExpr(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: parse_types.Token,
            _: parse_types.Token,
            _: ?*parse_types.ExprList,
            negated: bool,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(if (negated) tokenizer.token.tk_not else tokenizer.token.tk_in);
        }

        fn raiseExpr(
            raw: ?*anyopaque,
            _: c_int,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Expr {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.node(tokenizer.token.tk_raise);
        }

        fn renameTokenRemap(raw: ?*anyopaque, _: *parse_types.Expr) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.rename_remap_count += 1;
        }

        fn idToTrueFalse(raw: ?*anyopaque, _: *parse_types.Expr) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.truth_conversion_count += 1;
        }

        fn setErrorOffset(raw: ?*anyopaque, _: *parse_types.Expr, _: c_int) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.error_offset_count += 1;
        }

        fn destroy(raw: ?*anyopaque, _: ?*parse_types.Expr) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.destroy_count += 1;
        }

        fn appendList(
            raw: ?*anyopaque,
            list: ?*parse_types.ExprList,
            _: ?*parse_types.Expr,
        ) ?*parse_types.ExprList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const result: *TestList = if (list) |pointer|
                @ptrCast(@alignCast(pointer))
            else
                self.arena.allocator().create(TestList) catch return null;
            if (list == null) result.* = .{};
            result.count += 1;
            return @ptrCast(result);
        }

        fn setListSortOrder(
            _: ?*anyopaque,
            list: ?*parse_types.ExprList,
            order: c_int,
            nulls: c_int,
        ) void {
            const result: *TestList = @ptrCast(@alignCast(list.?));
            result.order = order;
            result.nulls = nulls;
        }

        fn setListName(
            raw: ?*anyopaque,
            _: ?*parse_types.ExprList,
            _: parse_types.Token,
            _: bool,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.list_name_count += 1;
        }

        fn setListSpan(
            raw: ?*anyopaque,
            _: ?*parse_types.ExprList,
            _: ?[*]const u8,
            _: ?[*]const u8,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.list_span_count += 1;
        }

        fn appendListVector(
            raw: ?*anyopaque,
            list: ?*parse_types.ExprList,
            _: ?*parse_types.IdList,
            _: ?*parse_types.Expr,
        ) ?*parse_types.ExprList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.list_vector_count += 1;
            return appendList(raw, list, null);
        }

        fn checkListLength(raw: ?*anyopaque, _: ?*parse_types.ExprList, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.list_check_count += 1;
        }

        fn appendListIdTerm(
            raw: ?*anyopaque,
            list: ?*parse_types.ExprList,
            _: parse_types.Token,
            _: c_int,
            _: c_int,
        ) ?*parse_types.ExprList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.list_id_term_count += 1;
            return appendList(raw, list, null);
        }

        fn destroyList(raw: ?*anyopaque, list: ?*parse_types.ExprList) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (list) |pointer| {
                const result: *TestList = @ptrCast(@alignCast(pointer));
                self.last_list_count = result.count;
                self.last_list_order = result.order;
                self.last_list_nulls = result.nulls;
            }
            self.list_destroy_count += 1;
        }

        fn appendIdentifier(
            raw: ?*anyopaque,
            list: ?*parse_types.IdList,
            _: parse_types.Token,
        ) ?*parse_types.IdList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const result: *TestIdentifiers = if (list) |pointer|
                @ptrCast(@alignCast(pointer))
            else
                self.arena.allocator().create(TestIdentifiers) catch return null;
            if (list == null) result.* = .{};
            result.count += 1;
            return @ptrCast(result);
        }

        fn destroyIdentifiers(raw: ?*anyopaque, list: ?*parse_types.IdList) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (list) |pointer|
                self.last_identifier_count = @as(*TestIdentifiers, @ptrCast(@alignCast(pointer))).count;
            self.identifier_destroy_count += 1;
        }

        fn appendFullname(
            raw: ?*anyopaque,
            _: parse_types.Token,
            _: ?parse_types.Token,
        ) ?*parse_types.SrcList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const result = self.arena.allocator().create(TestSource) catch return null;
            result.* = .{ .count = 1 };
            self.source_fullname_count += 1;
            return @ptrCast(result);
        }

        fn setSourceAlias(
            raw: ?*anyopaque,
            _: ?*parse_types.SrcList,
            _: parse_types.Token,
            _: bool,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.source_alias_count += 1;
        }

        fn appendSourceTerm(
            raw: ?*anyopaque,
            list: ?*parse_types.SrcList,
            _: parse_types.Token,
            _: parse_types.Token,
            _: parse_types.Token,
            select: ?*parse_types.Select,
            on_using: parse_types.OnOrUsing,
        ) ?*parse_types.SrcList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const result: *TestSource = if (list) |pointer|
                @ptrCast(@alignCast(pointer))
            else
                self.arena.allocator().create(TestSource) catch return null;
            if (list == null) result.* = .{};
            result.count += 1;
            self.source_subquery_count += @intFromBool(select != null);
            self.source_using_count += @intFromBool(on_using.pUsing != null);
            if (on_using.pUsing) |identifiers|
                self.last_identifier_count = @as(*TestIdentifiers, @ptrCast(@alignCast(identifiers))).count;
            if (on_using.pOn) |expression| self.last_source_on_op = expression.op;
            return @ptrCast(result);
        }

        fn nestedSource(
            raw: ?*anyopaque,
            prefix: ?*parse_types.SrcList,
            nested: ?*parse_types.SrcList,
            _: parse_types.Token,
            _: parse_types.OnOrUsing,
        ) ?*parse_types.SrcList {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.source_nested_count += 1;
            if (prefix) |pointer| return pointer;
            return nested;
        }

        fn shiftJoinTypes(raw: ?*anyopaque, _: ?*parse_types.SrcList) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.source_shift_count += 1;
        }

        fn setLastJoinType(raw: ?*anyopaque, list: ?*parse_types.SrcList, value: c_int) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const source: *TestSource = @ptrCast(@alignCast(list.?));
            source.last_join_type = value;
            self.last_source_join_type = value;
            self.source_join_set_count += 1;
        }

        fn indexedBy(raw: ?*anyopaque, _: ?*parse_types.SrcList, _: parse_types.Token) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.source_indexed_count += 1;
        }

        fn sourceFunctionArgs(
            raw: ?*anyopaque,
            _: ?*parse_types.SrcList,
            _: ?*parse_types.ExprList,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.source_function_args_count += 1;
        }

        fn sourceJoinType(
            _: ?*anyopaque,
            _: parse_types.Token,
            _: ?parse_types.Token,
            _: ?parse_types.Token,
        ) c_int {
            return join_type.inner;
        }

        fn destroySource(raw: ?*anyopaque, _: ?*parse_types.SrcList) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.source_destroy_count += 1;
        }

        fn newTriggerStep(self: *@This()) ?*parse_types.TriggerStep {
            if (self.fail_allocation) return null;
            const step = self.arena.allocator().create(TestTriggerStep) catch return null;
            step.* = .{};
            return @ptrCast(step);
        }

        fn beginTrigger(
            raw: ?*anyopaque,
            _: parse_types.Token,
            _: parse_types.Token,
            _: c_int,
            _: parse_types.TrigEvent,
            _: ?*parse_types.SrcList,
            _: ?*parse_types.Expr,
            _: bool,
            _: bool,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_begin_count += 1;
        }

        fn finishTrigger(
            raw: ?*anyopaque,
            _: ?*parse_types.TriggerStep,
            _: parse_types.Token,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_finish_count += 1;
        }

        fn appendTriggerStep(
            _: ?*anyopaque,
            list: ?*parse_types.TriggerStep,
            step: ?*parse_types.TriggerStep,
        ) ?*parse_types.TriggerStep {
            return list orelse step;
        }

        fn updateTriggerStep(
            raw: ?*anyopaque,
            _: ?*parse_types.SrcList,
            _: c_int,
            _: ?*parse_types.ExprList,
            _: ?*parse_types.SrcList,
            _: ?*parse_types.Expr,
            _: ?[*]const u8,
            _: ?[*]const u8,
        ) ?*parse_types.TriggerStep {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_update_step_count += 1;
            return self.newTriggerStep();
        }

        fn insertTriggerStep(
            raw: ?*anyopaque,
            _: ?*parse_types.SrcList,
            _: ?*parse_types.Select,
            _: ?*parse_types.IdList,
            _: c_int,
            _: ?*parse_types.Upsert,
            _: ?[*]const u8,
            _: ?[*]const u8,
        ) ?*parse_types.TriggerStep {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_insert_step_count += 1;
            return self.newTriggerStep();
        }

        fn deleteTriggerStep(
            raw: ?*anyopaque,
            _: ?*parse_types.SrcList,
            _: ?*parse_types.Expr,
            _: ?[*]const u8,
            _: ?[*]const u8,
        ) ?*parse_types.TriggerStep {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_delete_step_count += 1;
            return self.newTriggerStep();
        }

        fn selectTriggerStep(
            raw: ?*anyopaque,
            _: ?*parse_types.Select,
            _: ?[*]const u8,
            _: ?[*]const u8,
        ) ?*parse_types.TriggerStep {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_select_step_count += 1;
            return self.newTriggerStep();
        }

        fn destroyTriggerSteps(raw: ?*anyopaque, _: ?*parse_types.TriggerStep) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.trigger_destroy_count += 1;
        }

        fn newWindow(self: *@This()) ?*parse_types.Window {
            if (self.fail_allocation) return null;
            const window = self.arena.allocator().create(TestWindow) catch return null;
            window.* = .{};
            return @ptrCast(window);
        }

        fn chainWindow(
            raw: ?*anyopaque,
            current: ?*parse_types.Window,
            _: ?*parse_types.Window,
        ) ?*parse_types.Window {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.window_chain_count += 1;
            return current;
        }

        fn nameWindow(
            _: ?*anyopaque,
            window: ?*parse_types.Window,
            _: parse_types.Token,
        ) ?*parse_types.Window {
            return window;
        }

        fn assembleWindow(
            raw: ?*anyopaque,
            frame: ?*parse_types.Window,
            _: ?*parse_types.ExprList,
            _: ?*parse_types.ExprList,
            _: ?parse_types.Token,
        ) ?*parse_types.Window {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.window_assemble_count += 1;
            return frame;
        }

        fn allocateWindow(
            raw: ?*anyopaque,
            _: c_int,
            _: parse_types.FrameBound,
            _: parse_types.FrameBound,
            _: u8,
        ) ?*parse_types.Window {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.window_allocate_count += 1;
            return self.newWindow();
        }

        fn attachWindowFilter(
            _: ?*anyopaque,
            window: ?*parse_types.Window,
            _: ?*parse_types.Expr,
        ) ?*parse_types.Window {
            return window;
        }

        fn filterOnlyWindow(raw: ?*anyopaque, _: ?*parse_types.Expr) ?*parse_types.Window {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.newWindow();
        }

        fn namedWindow(raw: ?*anyopaque, _: parse_types.Token) ?*parse_types.Window {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.newWindow();
        }

        fn attachWindowExpression(
            raw: ?*anyopaque,
            _: ?*parse_types.Expr,
            _: ?*parse_types.Window,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.window_expression_count += 1;
        }

        fn setSelectWindowDefinitions(
            raw: ?*anyopaque,
            _: ?*parse_types.Select,
            _: ?*parse_types.Window,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.window_select_definition_count += 1;
        }

        fn destroyWindow(raw: ?*anyopaque, _: ?*parse_types.Window) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.window_destroy_count += 1;
        }

        fn createCte(
            raw: ?*anyopaque,
            _: parse_types.Token,
            columns: ?*parse_types.ExprList,
            select: ?*parse_types.Select,
            mode: u8,
        ) ?*parse_types.Cte {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const cte = self.arena.allocator().create(parse_types.Cte) catch return null;
            cte.* = std.mem.zeroes(parse_types.Cte);
            cte.pCols = columns;
            cte.pSelect = select;
            cte.eM10d = mode;
            self.cte_create_count += 1;
            self.last_materialized = mode;
            return cte;
        }

        fn addWith(
            raw: ?*anyopaque,
            with: ?*parse_types.With,
            _: ?*parse_types.Cte,
        ) ?*parse_types.With {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const result: *TestWith = if (with) |pointer|
                @ptrCast(@alignCast(pointer))
            else
                self.arena.allocator().create(TestWith) catch return null;
            if (with == null) result.* = .{};
            result.count += 1;
            self.with_add_count += 1;
            return @ptrCast(result);
        }

        fn attachWith(
            raw: ?*anyopaque,
            select: ?*parse_types.Select,
            with: ?*parse_types.With,
        ) ?*parse_types.Select {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (select) |result| result.pWith = with;
            self.with_attach_count += 1;
            return select;
        }

        fn pushWith(raw: ?*anyopaque, _: ?*parse_types.With) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.with_push_count += 1;
        }

        fn markWith(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.with_mark_count += 1;
        }

        fn destroyWith(raw: ?*anyopaque, _: ?*parse_types.With) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.with_destroy_count += 1;
        }

        fn createUpsert(
            raw: ?*anyopaque,
            target: ?*parse_types.ExprList,
            target_where: ?*parse_types.Expr,
            changes: ?*parse_types.ExprList,
            where: ?*parse_types.Expr,
            next: ?*parse_types.Upsert,
            is_update: bool,
        ) ?*parse_types.Upsert {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const upsert = self.arena.allocator().create(parse_types.Upsert) catch return null;
            upsert.* = std.mem.zeroes(parse_types.Upsert);
            upsert.pUpsertTarget = target;
            upsert.pUpsertTargetWhere = target_where;
            upsert.pUpsertSet = changes;
            upsert.pUpsertWhere = where;
            upsert.pNextUpsert = next;
            upsert.isDoUpdate = @intFromBool(is_update);
            self.upsert_create_count += 1;
            self.last_upsert_is_update = is_update;
            return upsert;
        }

        fn destroyUpsert(raw: ?*anyopaque, _: ?*parse_types.Upsert) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.upsert_destroy_count += 1;
        }

        fn createSelect(
            raw: ?*anyopaque,
            result_list: ?*parse_types.ExprList,
            source: ?*parse_types.SrcList,
            where: ?*parse_types.Expr,
            _: ?*parse_types.ExprList,
            _: ?*parse_types.Expr,
            _: ?*parse_types.ExprList,
            flags: c_int,
            limit: ?*parse_types.Expr,
        ) ?*parse_types.Select {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail_allocation) return null;
            const select = self.arena.allocator().create(parse_types.Select) catch return null;
            select.* = std.mem.zeroes(parse_types.Select);
            select.pEList = result_list;
            select.pSrc = source;
            select.pWhere = where;
            select.selFlags = @bitCast(flags);
            select.pLimit = limit;
            self.select_create_count += 1;
            self.last_select_result_count = if (result_list) |pointer|
                @as(*TestList, @ptrCast(@alignCast(pointer))).count
            else
                0;
            self.last_select_source_count = if (source) |pointer|
                @as(*TestSource, @ptrCast(@alignCast(pointer))).count
            else
                0;
            self.last_select_flags = flags;
            self.last_select_where_op = if (where) |expression| expression.op else 0;
            self.last_select_limit_op = if (limit) |expression| expression.op else 0;
            return select;
        }

        fn compoundSelect(
            raw: ?*anyopaque,
            left: ?*parse_types.Select,
            right: ?*parse_types.Select,
            op: c_int,
        ) ?*parse_types.Select {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const result = right orelse return null;
            result.op = @intCast(op);
            result.pPrior = left;
            self.select_compound_count += 1;
            return result;
        }

        fn multiValues(
            raw: ?*anyopaque,
            select: ?*parse_types.Select,
            _: ?*parse_types.ExprList,
        ) ?*parse_types.Select {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.select_multi_values_count += 1;
            return select;
        }

        fn multiValuesEnd(raw: ?*anyopaque, _: ?*parse_types.Select) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.select_multi_values_end_count += 1;
        }

        fn doubleLinkSelect(raw: ?*anyopaque, _: *parse_types.Select) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.select_double_link_count += 1;
        }

        fn destroySelect(raw: ?*anyopaque, _: ?*parse_types.Select) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.select_destroy_count += 1;
        }

        fn hooks(self: *@This()) ExpressionHooks {
            return .{
                .context = self,
                .token_expr = token,
                .bare_expr = bareExpr,
                .integer_expr = integer,
                .function_expr = function,
                .ordered_function_expr = orderedFunction,
                .variable_expr = variable,
                .qnumber_expr = qnumber,
                .p_expr = pExpr,
                .and_expr = andExpr,
                .collate_expr = collateExpr,
                .cast_expr = castExpr,
                .is_null_expr = isNullExpr,
                .is_expr = isExpr,
                .between_expr = betweenExpr,
                .in_list_expr = inListExpr,
                .select_expr = selectExpr,
                .in_select_expr = inSelectExpr,
                .case_expr = caseExpr,
                .vector_expr = vectorExpr,
                .like_expr = likeExpr,
                .in_table_expr = inTableExpr,
                .raise_expr = raiseExpr,
                .rename_token_remap = renameTokenRemap,
                .id_to_true_false = idToTrueFalse,
                .set_error_offset = setErrorOffset,
                .destroy_expr = destroy,
            };
        }

        fn listHooks(self: *@This()) ExpressionListHooks {
            return .{
                .context = self,
                .append = appendList,
                .set_sort_order = setListSortOrder,
                .set_name = setListName,
                .set_span = setListSpan,
                .append_vector = appendListVector,
                .check_length = checkListLength,
                .append_id_term = appendListIdTerm,
                .destroy = destroyList,
            };
        }

        fn sourceHooks(self: *@This()) SourceListHooks {
            return .{
                .context = self,
                .append_fullname = appendFullname,
                .set_alias = setSourceAlias,
                .append_from_term = appendSourceTerm,
                .nested_from = nestedSource,
                .shift_join_types = shiftJoinTypes,
                .set_last_join_type = setLastJoinType,
                .indexed_by = indexedBy,
                .function_args = sourceFunctionArgs,
                .join_type = sourceJoinType,
                .destroy = destroySource,
            };
        }

        fn identifierHooks(self: *@This()) IdentifierListHooks {
            return .{
                .context = self,
                .append = appendIdentifier,
                .destroy = destroyIdentifiers,
            };
        }

        fn triggerHooks(self: *@This()) TriggerHooks {
            return .{
                .context = self,
                .begin = beginTrigger,
                .finish = finishTrigger,
                .append_step = appendTriggerStep,
                .update_step = updateTriggerStep,
                .insert_step = insertTriggerStep,
                .delete_step = deleteTriggerStep,
                .select_step = selectTriggerStep,
                .destroy = destroyTriggerSteps,
            };
        }

        fn windowHooks(self: *@This()) WindowHooks {
            return .{
                .context = self,
                .chain = chainWindow,
                .set_name = nameWindow,
                .assemble = assembleWindow,
                .allocate = allocateWindow,
                .attach_filter = attachWindowFilter,
                .filter_only = filterOnlyWindow,
                .named_over = namedWindow,
                .attach_expression = attachWindowExpression,
                .set_select_definitions = setSelectWindowDefinitions,
                .destroy = destroyWindow,
            };
        }

        fn withHooks(self: *@This()) WithHooks {
            return .{
                .context = self,
                .create_cte = createCte,
                .add = addWith,
                .attach = attachWith,
                .push = pushWith,
                .mark_present = markWith,
                .destroy = destroyWith,
            };
        }

        fn upsertHooks(self: *@This()) UpsertHooks {
            return .{
                .context = self,
                .create = createUpsert,
                .destroy = destroyUpsert,
            };
        }

        fn selectHooks(self: *@This()) SelectHooks {
            return .{
                .context = self,
                .create = createSelect,
                .compound = compoundSelect,
                .multi_values = multiValues,
                .multi_values_end = multiValuesEnd,
                .double_link = doubleLinkSelect,
                .destroy = destroySelect,
            };
        }
    };

    const Capture = struct {
        constraint_name: [16]u8 = undefined,
        constraint_name_length: usize = 0,
        default_ops: [28]u8 = undefined,
        default_sources: [28][32]u8 = undefined,
        default_lengths: [28]usize = undefined,
        default_count: usize = 0,
        check_count: usize = 0,
        generated_count: usize = 0,
        generated_storage: [8]u8 = undefined,
        generated_storage_length: usize = 0,
        select_statement_count: usize = 0,
        drop_table_count: usize = 0,
        drop_view_count: usize = 0,
        last_drop_if_exists: bool = false,
        returning_count: usize = 0,
        delete_count: usize = 0,
        update_count: usize = 0,
        insert_count: usize = 0,
        default_insert_count: usize = 0,
        upsert_insert_count: usize = 0,
        create_index_count: usize = 0,
        drop_index_count: usize = 0,
        last_index_conflict: c_int = -1,
        last_index_if_not_exists: bool = false,
        vacuum_count: usize = 0,
        pragma_count: usize = 0,
        negative_pragma_count: usize = 0,
        attach_count: usize = 0,
        detach_count: usize = 0,
        reindex_count: usize = 0,
        analyze_count: usize = 0,
        alter_count: usize = 0,
        create_view_count: usize = 0,
        drop_trigger_count: usize = 0,
        vtab_begin_count: usize = 0,
        vtab_finish_count: usize = 0,
        vtab_arg_init_count: usize = 0,
        vtab_arg_extend_count: usize = 0,
        last_dml_conflict: c_int = -1,

        fn record(raw: ?*anyopaque, action: Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            switch (action) {
                .set_constraint_name => |name| {
                    self.constraint_name_length = name.n;
                    @memcpy(self.constraint_name[0..name.n], name.z.?[0..name.n]);
                },
                .add_default => |default| {
                    const index = self.default_count;
                    self.default_ops[index] = default.expression.?.op;
                    self.default_lengths[index] = default.source.n;
                    @memcpy(
                        self.default_sources[index][0..default.source.n],
                        default.source.z.?[0..default.source.n],
                    );
                    self.default_count += 1;
                },
                .add_check => |check| {
                    std.debug.assert(check.expression.?.op == tokenizer.token.tk_and);
                    std.debug.assert(check.open.z.?[0] == '(' and check.close.z.?[0] == ')');
                    self.check_count += 1;
                },
                .add_generated => |generated| {
                    std.debug.assert(generated.expression.?.op == tokenizer.token.tk_integer);
                    if (generated.storage) |storage| {
                        self.generated_storage_length = storage.n;
                        @memcpy(
                            self.generated_storage[0..storage.n],
                            storage.z.?[0..storage.n],
                        );
                    }
                    self.generated_count += 1;
                },
                .select_statement => self.select_statement_count += 1,
                .drop_table => |drop| {
                    self.drop_table_count += @intFromBool(!drop.is_view);
                    self.drop_view_count += @intFromBool(drop.is_view);
                    self.last_drop_if_exists = drop.if_exists;
                },
                .add_returning => self.returning_count += 1,
                .delete_from => self.delete_count += 1,
                .update => |update| {
                    self.update_count += 1;
                    self.last_dml_conflict = update.conflict;
                },
                .insert => |insert| {
                    self.insert_count += 1;
                    self.default_insert_count += @intFromBool(insert.default_values);
                    self.upsert_insert_count += @intFromBool(insert.upsert != null);
                    self.last_dml_conflict = insert.conflict;
                },
                .create_index => |index| {
                    self.create_index_count += 1;
                    self.last_index_conflict = index.conflict;
                    self.last_index_if_not_exists = index.if_not_exists;
                },
                .drop_index => self.drop_index_count += 1,
                .vacuum => self.vacuum_count += 1,
                .pragma => |pragma| {
                    self.pragma_count += 1;
                    self.negative_pragma_count += @intFromBool(pragma.negative);
                },
                .attach => self.attach_count += 1,
                .detach => self.detach_count += 1,
                .reindex => self.reindex_count += 1,
                .analyze => self.analyze_count += 1,
                .alter_rename_table,
                .alter_begin_add_column,
                .alter_finish_add_column,
                .alter_drop_column,
                .alter_rename_column,
                .alter_drop_constraint,
                .alter_drop_not_null,
                .alter_set_not_null,
                .alter_add_check,
                => self.alter_count += 1,
                .create_view => self.create_view_count += 1,
                .drop_trigger => self.drop_trigger_count += 1,
                .vtab_begin => self.vtab_begin_count += 1,
                .vtab_finish => self.vtab_finish_count += 1,
                .vtab_arg_init => self.vtab_arg_init_count += 1,
                .vtab_arg_extend => self.vtab_arg_extend_count += 1,
                else => {},
            }
        }
    };

    var factory = Factory{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer factory.arena.deinit();
    var capture = Capture{};
    const sql = "CREATE TABLE t(a CONSTRAINT named DEFAULT 12, b DEFAULT 'x', c DEFAULT NULL, d DEFAULT (34), e DEFAULT +56, f DEFAULT -78, g DEFAULT TRUE, h CHECK(90 AND 1), i INTEGER GENERATED ALWAYS AS (91) STORED, j DEFAULT (-4), k DEFAULT (1+2*3), l DEFAULT (schema.value), m DEFAULT (db.schema.value), n DEFAULT (abs(5)), o DEFAULT (count(*)), p DEFAULT (fn(DISTINCT 6)), q DEFAULT (fn(ALL 7)), r DEFAULT (5 COLLATE nocase), s DEFAULT (CAST(6 AS TEXT)), t DEFAULT (5 ISNULL), u DEFAULT (5 NOT NULL), v DEFAULT (5 IS 5), w DEFAULT (5 IS NOT 5), x DEFAULT (5 IS NOT DISTINCT FROM 5), y DEFAULT (5 IS DISTINCT FROM 5), z DEFAULT ('x' -> 'y'), aa DEFAULT (5 BETWEEN 1 AND 9), ab DEFAULT (5 NOT BETWEEN 1 AND 9), ac DEFAULT (5 IN (1,2)), ad DEFAULT (5 NOT IN (1,2)), PRIMARY KEY(m DESC NULLS LAST));";
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        sql,
        .{
            .rename_mode = true,
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqualStrings("named", capture.constraint_name[0..capture.constraint_name_length]);
    try std.testing.expectEqual(@as(usize, 28), capture.default_count);
    try std.testing.expectEqualSlices(u8, &.{
        @truncate(tokenizer.token.tk_integer),
        @truncate(tokenizer.token.tk_string),
        @truncate(tokenizer.token.tk_null),
        @truncate(tokenizer.token.tk_integer),
        @truncate(tokenizer.token.tk_integer),
        @truncate(tokenizer.token.tk_uminus),
        @truncate(tokenizer.token.tk_string),
        @truncate(tokenizer.token.tk_uminus),
        @truncate(tokenizer.token.tk_plus),
        @truncate(tokenizer.token.tk_dot),
        @truncate(tokenizer.token.tk_dot),
        @truncate(tokenizer.token.tk_function),
        @truncate(tokenizer.token.tk_function),
        @truncate(tokenizer.token.tk_function),
        @truncate(tokenizer.token.tk_function),
        @truncate(tokenizer.token.tk_collate),
        @truncate(tokenizer.token.tk_cast),
        @truncate(tokenizer.token.tk_isnull),
        @truncate(tokenizer.token.tk_notnull),
        @truncate(tokenizer.token.tk_is),
        @truncate(tokenizer.token.tk_isnot),
        @truncate(tokenizer.token.tk_is),
        @truncate(tokenizer.token.tk_isnot),
        @truncate(tokenizer.token.tk_function),
        @truncate(tokenizer.token.tk_between),
        @truncate(tokenizer.token.tk_not),
        @truncate(tokenizer.token.tk_in),
        @truncate(tokenizer.token.tk_not),
    }, &capture.default_ops);
    const expected_sources = [_][]const u8{
        "12", "'x'", "NULL", "34", "+56", "-78", "TRUE", "-4", "1+2*3", "schema.value", "db.schema.value", "abs(5)", "count(*)", "fn(DISTINCT 6)", "fn(ALL 7)", "5 COLLATE nocase", "CAST(6 AS TEXT)", "5 ISNULL", "5 NOT NULL", "5 IS 5", "5 IS NOT 5", "5 IS NOT DISTINCT FROM 5", "5 IS DISTINCT FROM 5", "'x' -> 'y'", "5 BETWEEN 1 AND 9", "5 NOT BETWEEN 1 AND 9", "5 IN (1,2)", "5 NOT IN (1,2)",
    };
    for (expected_sources, 0..) |expected, index| {
        try std.testing.expectEqualStrings(
            expected,
            capture.default_sources[index][0..capture.default_lengths[index]],
        );
    }
    try std.testing.expectEqual(@as(usize, 28), factory.destroy_count);
    try std.testing.expectEqual(@as(usize, 1), factory.truth_conversion_count);
    try std.testing.expectEqual(@as(usize, 1), factory.rename_remap_count);
    try std.testing.expectEqual(@as(usize, 1), capture.check_count);
    try std.testing.expectEqual(@as(usize, 1), capture.generated_count);
    try std.testing.expectEqualStrings(
        "STORED",
        capture.generated_storage[0..capture.generated_storage_length],
    );
    try std.testing.expectEqual(@as(usize, 1), factory.list_destroy_count);
    try std.testing.expectEqual(@as(usize, 1), factory.last_list_count);
    try std.testing.expectEqual(sort_order.descending, factory.last_list_order);
    try std.testing.expectEqual(sort_order.descending, factory.last_list_nulls);
    try std.testing.expectEqual(@as(usize, 5), factory.function_call_count);
    try std.testing.expectEqual(@as(usize, 2), factory.last_function_arg_count);
    try std.testing.expectEqual(@as(c_int, 0), factory.last_function_distinct);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT DISTINCT x.a AS one, u.b, x.* FROM t AS x JOIN u INDEXED BY idx ON 1 WHERE 3 GROUP BY 4 HAVING 5 ORDER BY 6 DESC NULLS LAST LIMIT 7 OFFSET 8;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 1), factory.select_create_count);
    try std.testing.expectEqual(@as(usize, 1), factory.select_double_link_count);
    try std.testing.expectEqual(@as(usize, 1), factory.select_destroy_count);
    try std.testing.expectEqual(@as(usize, 3), factory.last_select_result_count);
    try std.testing.expectEqual(@as(usize, 2), factory.last_select_source_count);
    try std.testing.expectEqual(select_flag.distinct, factory.last_select_flags);
    try std.testing.expectEqual(@as(u8, @truncate(tokenizer.token.tk_integer)), factory.last_select_where_op);
    try std.testing.expectEqual(@as(u8, @truncate(tokenizer.token.tk_limit)), factory.last_select_limit_op);
    try std.testing.expectEqual(@as(usize, 1), factory.list_name_count);
    try std.testing.expectEqual(@as(usize, 2), factory.list_span_count);
    try std.testing.expectEqual(@as(usize, 1), factory.error_offset_count);
    try std.testing.expectEqual(@as(usize, 1), factory.source_shift_count);
    try std.testing.expectEqual(@as(usize, 1), factory.source_join_set_count);
    try std.testing.expectEqual(join_type.inner, factory.last_source_join_type);
    try std.testing.expectEqual(@as(usize, 1), factory.source_indexed_count);
    try std.testing.expectEqual(@as(u8, @truncate(tokenizer.token.tk_integer)), factory.last_source_on_op);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT * FROM tabfn(1,2) AS f, (SELECT 3) AS s;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 3), factory.select_create_count);
    try std.testing.expectEqual(@as(usize, 3), factory.select_double_link_count);
    try std.testing.expectEqual(@as(usize, 2), factory.select_destroy_count);
    try std.testing.expectEqual(@as(usize, 2), factory.last_select_source_count);
    try std.testing.expectEqual(@as(usize, 1), factory.source_function_args_count);
    try std.testing.expectEqual(@as(usize, 1), factory.source_subquery_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT * FROM (t JOIN u ON 1) AS nested;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 1), factory.source_nested_count);
    try std.testing.expectEqual(@as(usize, 2), factory.last_select_source_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT * FROM t JOIN u USING(id, other);",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .identifier_list_hooks = factory.identifierHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 1), factory.source_using_count);
    try std.testing.expectEqual(@as(usize, 2), factory.last_identifier_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT 1 UNION ALL SELECT 2; VALUES(3,4),(5,6);",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 2), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 1), factory.select_compound_count);
    try std.testing.expectEqual(@as(usize, 1), factory.select_multi_values_count);
    try std.testing.expectEqual(@as(usize, 1), factory.select_multi_values_end_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT (SELECT 1), EXISTS(SELECT 2), 3 IN (SELECT 3), 4 NOT IN (SELECT 4), CASE 5 WHEN 5 THEN 6 ELSE 7 END, CASE WHEN 1 THEN 2 END;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 2), factory.select_expr_count);
    try std.testing.expectEqual(@as(usize, 2), factory.in_select_expr_count);
    try std.testing.expectEqual(@as(usize, 2), factory.case_expr_count);
    try std.testing.expectEqual(@as(usize, 6), factory.last_select_result_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT ?1, fn(1 ORDER BY 2), (1,2), 'a' LIKE 'b', 'a' NOT LIKE 'b' ESCAPE '!', 1 IN tab(2), RAISE(IGNORE), RAISE(FAIL,'x');",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 8), factory.last_select_result_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "WITH a(x) AS MATERIALIZED (SELECT 1), b AS NOT MATERIALIZED (SELECT 2) SELECT * FROM a;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .with_hooks = factory.withHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 2), factory.cte_create_count);
    try std.testing.expectEqual(@as(usize, 2), factory.with_add_count);
    try std.testing.expectEqual(@as(usize, 1), factory.with_attach_count);
    try std.testing.expectEqual(@as(usize, 2), factory.with_mark_count);
    try std.testing.expectEqual(materialized.no, factory.last_materialized);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "SELECT sum(x) FILTER (WHERE x>0) OVER (PARTITION BY y ORDER BY z ROWS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES), count(*) OVER named FROM t WINDOW named AS (ORDER BY x RANGE UNBOUNDED PRECEDING), named2 AS (named PARTITION BY y ROWS CURRENT ROW);",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .window_hooks = factory.windowHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.select_statement_count);
    try std.testing.expectEqual(@as(usize, 2), factory.window_expression_count);
    try std.testing.expectEqual(@as(usize, 1), factory.window_select_definition_count);
    try std.testing.expect(factory.window_allocate_count >= 3);
    try std.testing.expect(factory.window_assemble_count >= 3);
    try std.testing.expectEqual(@as(usize, 1), factory.window_chain_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE TEMP VIEW IF NOT EXISTS v(a) AS SELECT 1; DROP TRIGGER IF EXISTS tr; CREATE VIRTUAL TABLE IF NOT EXISTS vt USING mod(a, nested(b));",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.create_view_count);
    try std.testing.expectEqual(@as(usize, 1), capture.drop_trigger_count);
    try std.testing.expectEqual(@as(usize, 1), capture.vtab_begin_count);
    try std.testing.expectEqual(@as(usize, 1), capture.vtab_finish_count);
    try std.testing.expect(capture.vtab_arg_init_count >= 1);
    try std.testing.expect(capture.vtab_arg_extend_count >= 1);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE TEMP TRIGGER IF NOT EXISTS tr BEFORE UPDATE OF a,b ON t WHEN 1 BEGIN UPDATE OR REPLACE t SET a=2 WHERE 3; INSERT INTO t(a) SELECT 4; DELETE FROM t WHERE 5; SELECT 6; END;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .identifier_list_hooks = factory.identifierHooks(),
            .trigger_hooks = factory.triggerHooks(),
            .upsert_hooks = factory.upsertHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), factory.trigger_begin_count);
    try std.testing.expectEqual(@as(usize, 1), factory.trigger_finish_count);
    try std.testing.expectEqual(@as(usize, 1), factory.trigger_update_step_count);
    try std.testing.expectEqual(@as(usize, 1), factory.trigger_insert_step_count);
    try std.testing.expectEqual(@as(usize, 1), factory.trigger_delete_step_count);
    try std.testing.expectEqual(@as(usize, 1), factory.trigger_select_step_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "DROP TABLE main.old; DROP VIEW IF EXISTS old_view;",
        .{ .source_list_hooks = factory.sourceHooks() },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.drop_table_count);
    try std.testing.expectEqual(@as(usize, 1), capture.drop_view_count);
    try std.testing.expect(capture.last_drop_if_exists);
    try std.testing.expectEqual(@as(usize, 7), factory.source_fullname_count);
    try std.testing.expectEqual(@as(usize, 2), factory.source_destroy_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE TABLE fk(a,b, FOREIGN KEY(a,b) REFERENCES parent(x,y));",
        .{ .expression_list_hooks = factory.listHooks() },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 6), factory.list_id_term_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "CREATE UNIQUE INDEX IF NOT EXISTS main.idx ON t(a COLLATE nocase DESC,b) WHERE 1; DROP INDEX IF EXISTS main.idx;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.create_index_count);
    try std.testing.expectEqual(@as(usize, 1), capture.drop_index_count);
    try std.testing.expectEqual(conflict_action.abort, capture.last_index_conflict);
    try std.testing.expect(capture.last_index_if_not_exists);
    try std.testing.expectEqual(@as(usize, 6), factory.list_id_term_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "VACUUM main INTO 'copy.db'; PRAGMA main.cache_size=-2000; PRAGMA user_version(3);",
        .{ .expression_hooks = factory.hooks() },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.vacuum_count);
    try std.testing.expectEqual(@as(usize, 2), capture.pragma_count);
    try std.testing.expectEqual(@as(usize, 1), capture.negative_pragma_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "ATTACH 'a.db' AS aux KEY 'k'; DETACH aux; REINDEX; REINDEX main.idx; ANALYZE; ANALYZE main.t; ALTER TABLE t RENAME TO t2; ALTER TABLE t ADD COLUMN c TEXT NOT NULL; ALTER TABLE t DROP COLUMN a; ALTER TABLE t RENAME COLUMN a TO b; ALTER TABLE t DROP CONSTRAINT c; ALTER TABLE t ALTER COLUMN a DROP NOT NULL; ALTER TABLE t ALTER COLUMN a SET NOT NULL ON CONFLICT REPLACE; ALTER TABLE t ADD CONSTRAINT c CHECK(1); ALTER TABLE t ADD CHECK(2);",
        .{
            .expression_hooks = factory.hooks(),
            .source_list_hooks = factory.sourceHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.attach_count);
    try std.testing.expectEqual(@as(usize, 1), capture.detach_count);
    try std.testing.expectEqual(@as(usize, 2), capture.reindex_count);
    try std.testing.expectEqual(@as(usize, 2), capture.analyze_count);
    try std.testing.expectEqual(@as(usize, 10), capture.alter_count);

    capture = .{};
    try std.testing.expectEqual(Result.accepted, recognizeWithActions(
        std.testing.allocator,
        "DELETE FROM t INDEXED BY idx WHERE 1 RETURNING 2; UPDATE OR REPLACE t SET a=3, (b,c)=4 WHERE 5 RETURNING 6; INSERT OR IGNORE INTO t(a,b) SELECT 7,8; REPLACE INTO t DEFAULT VALUES RETURNING 9; INSERT INTO t(a) SELECT 10 WHERE 1 ON CONFLICT(a) DO UPDATE SET a=11 WHERE 12 RETURNING 13;",
        .{
            .expression_hooks = factory.hooks(),
            .expression_list_hooks = factory.listHooks(),
            .source_list_hooks = factory.sourceHooks(),
            .identifier_list_hooks = factory.identifierHooks(),
            .upsert_hooks = factory.upsertHooks(),
            .select_hooks = factory.selectHooks(),
        },
        &capture,
        Capture.record,
    ));
    try std.testing.expectEqual(@as(usize, 4), capture.returning_count);
    try std.testing.expectEqual(@as(usize, 1), capture.delete_count);
    try std.testing.expectEqual(@as(usize, 1), capture.update_count);
    try std.testing.expectEqual(@as(usize, 3), capture.insert_count);
    try std.testing.expectEqual(@as(usize, 1), capture.default_insert_count);
    try std.testing.expectEqual(@as(usize, 1), capture.upsert_insert_count);
    try std.testing.expectEqual(conflict_action.default, capture.last_dml_conflict);
    try std.testing.expectEqual(@as(usize, 1), factory.upsert_create_count);
    try std.testing.expect(factory.last_upsert_is_update);
    try std.testing.expectEqual(@as(usize, 1), factory.list_vector_count);
    try std.testing.expectEqual(@as(usize, 2), factory.list_check_count);

    factory.fail_allocation = true;
    try std.testing.expectEqual(Result.out_of_memory, recognizeWithActions(
        std.testing.allocator,
        "CREATE TABLE failed(a DEFAULT 1);",
        .{ .expression_hooks = factory.hooks() },
        null,
        null,
    ));
}

test "parser finalization destroys remaining owned semantic values in reverse" {
    const Capture = struct {
        kinds: [2]tables.DestructorKind = undefined,
        count: usize = 0,

        fn record(raw: ?*anyopaque, kind: tables.DestructorKind, _: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.kinds[self.count] = kind;
            self.count += 1;
        }
    };
    const expr_symbol = for (tables.destructors, 0..) |kind, symbol| {
        if (kind == .expr) break @as(u16, @intCast(symbol));
    } else unreachable;
    const list_symbol = for (tables.destructors, 0..) |kind, symbol| {
        if (kind == .expr_list) break @as(u16, @intCast(symbol));
    } else unreachable;

    var capture = Capture{};
    var marker: usize = 0;
    var machine = try Machine.init(std.testing.allocator, .{}, null, null, &capture, Capture.record);
    try machine.stack.append(std.testing.allocator, .{ .state = 1, .symbol = expr_symbol, .minor = .{ .yy454 = @ptrCast(&marker) } });
    try machine.stack.append(std.testing.allocator, .{ .state = 1, .symbol = list_symbol, .minor = .{ .yy14 = @ptrCast(&marker) } });
    machine.deinit();
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(tables.DestructorKind.expr_list, capture.kinds[0]);
    try std.testing.expectEqual(tables.DestructorKind.expr, capture.kinds[1]);
}

test "absent semantic owner hooks cannot reinterpret token bits as owned pointers" {
    const Capture = struct {
        calls: usize = 0,
        non_null_calls: usize = 0,

        fn record(raw: ?*anyopaque, _: tables.DestructorKind, pointer: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.non_null_calls += @intFromBool(pointer != null);
        }
    };

    var capture = Capture{};
    // Without concrete expression owners, typed contracts reduce INTEGER
    // storage through owned Expr symbols as null. Syntax-error cleanup must
    // never reinterpret bytes from the SQL input as pointers.
    try std.testing.expectEqual(Result.syntax_error, recognizeWithHooks(
        std.testing.allocator,
        "SELECT 1 FROM (",
        .{},
        null,
        null,
        &capture,
        Capture.record,
    ));
    try std.testing.expect(capture.calls != 0);
    try std.testing.expectEqual(@as(usize, 0), capture.non_null_calls);
}

test "generated destructor routing selects live semantic members" {
    const Capture = struct {
        calls: usize = 0,
        kind: tables.DestructorKind = .none,
        pointer: ?*anyopaque = null,

        fn record(raw: ?*anyopaque, kind: tables.DestructorKind, pointer: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.kind = kind;
            self.pointer = pointer;
        }
    };

    var capture = Capture{};
    var marker: usize = 0;
    var value = SemanticValue{ .yy454 = @ptrCast(&marker) };
    const expr_symbol = for (tables.destructors, 0..) |kind, symbol| {
        if (kind == .expr) break @as(u16, @intCast(symbol));
    } else unreachable;
    destroySymbol(expr_symbol, &value, &capture, Capture.record);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(tables.DestructorKind.expr, capture.kind);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&marker)), capture.pointer);

    const no_destructor = for (tables.destructors, 0..) |kind, symbol| {
        if (kind == .none) break @as(u16, @intCast(symbol));
    } else unreachable;
    destroySymbol(no_destructor, &value, &capture, Capture.record);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    var routed: usize = 0;
    for (tables.destructors) |kind| routed += @intFromBool(kind != .none);
    try std.testing.expectEqual(@as(usize, 50), routed);
}

comptime {
    var contracted: u16 = 0;
    for (tables.rules, 0..) |rule, rule_index| {
        if (hasTypedActionContract(@intCast(rule_index))) {
            contracted += 1;
            if (!rule.has_action) @compileError("typed parser contract has no generated action");
        }
    }
    if (contracted != typed_action_contract_rule_count)
        @compileError("typed parser action-contract count is stale");
}

test "canonical Lemon tables recognize representative grammar" {
    const valid = [_][]const u8{
        "SELECT 1;",
        "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);",
        "INSERT INTO t VALUES(1, 'one');",
        "UPDATE t SET b='two' WHERE a=1;",
        "WITH c(x) AS (SELECT 1) SELECT x FROM c;",
        "BEGIN; SAVEPOINT s; RELEASE s; COMMIT;",
    };
    for (valid) |sql| try std.testing.expectEqual(Result.accepted, recognize(std.testing.allocator, sql));

    const invalid = [_][]const u8{
        "SELEC 1;",
        "SELECT FROM;",
        "CREATE TABLE;",
    };
    for (invalid) |sql| try std.testing.expectEqual(Result.syntax_error, recognize(std.testing.allocator, sql));
}
