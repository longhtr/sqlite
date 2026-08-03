//! Source-corresponding active-profile Parse, Expr, ExprList, and SrcList models.
//!
//! These are internal migration layouts, not a public C ABI. Pointer targets
//! that are not yet ported remain opaque, but ownership-bearing unions,
//! flexible-array headers, profile-selected fields, and flag storage match the
//! pinned SQLite source.

const facts = @import("../generated/internal_parse_layout.zig");
pub const schema_types = @import("schema_types.zig");

pub const Sqlite3 = opaque {};
pub const Vdbe = opaque {};
pub const AggInfo = opaque {};
pub const Table = schema_types.Table;
pub const Index = schema_types.Index;
pub const CteUse = opaque {};
pub const IndexedExpr = opaque {};
pub const TableLock = opaque {};
pub const AutoincInfo = opaque {};
pub const TriggerPrg = opaque {};
pub const Returning = opaque {};
pub const VList = opaque {};
pub const RenameToken = opaque {};
pub const FuncDef = opaque {};

pub const table_flag = struct {
    pub const without_rowid: u32 = @intCast(facts.constants.TF_WithoutRowid);
    pub const no_visible_rowid: u32 = @intCast(facts.constants.TF_NoVisibleRowid);
    pub const strict: u32 = @intCast(facts.constants.TF_Strict);
};

pub const conflict_action = struct {
    pub const rollback: c_int = facts.constants.OE_Rollback;
    pub const abort: c_int = facts.constants.OE_Abort;
    pub const fail: c_int = facts.constants.OE_Fail;
    pub const ignore: c_int = facts.constants.OE_Ignore;
    pub const replace: c_int = facts.constants.OE_Replace;
    pub const default: c_int = facts.constants.OE_Default;
};

pub const sort_order = struct {
    pub const ascending: c_int = facts.constants.SQLITE_SO_ASC;
    pub const descending: c_int = facts.constants.SQLITE_SO_DESC;
    pub const unspecified: c_int = facts.constants.SQLITE_SO_UNDEFINED;
};

pub const foreign_action = struct {
    pub const none: c_int = facts.constants.OE_None;
    pub const restrict: c_int = facts.constants.OE_Restrict;
    pub const set_null: c_int = facts.constants.OE_SetNull;
    pub const set_default: c_int = facts.constants.OE_SetDflt;
    pub const cascade: c_int = facts.constants.OE_Cascade;
};

pub const select_flag = struct {
    pub const distinct: c_int = facts.constants.SF_Distinct;
    pub const all: c_int = facts.constants.SF_All;
    pub const values: u32 = facts.constants.SF_Values;
    pub const multi_value: u32 = facts.constants.SF_MultiValue;
};

pub const join_type = struct {
    pub const inner: c_int = facts.constants.JT_INNER;
};

pub const materialized = struct {
    pub const yes: u8 = facts.constants.M10d_Yes;
    pub const any: u8 = facts.constants.M10d_Any;
    pub const no: u8 = facts.constants.M10d_No;
};

pub const Token = extern struct {
    z: ?[*]const u8,
    n: c_uint,
};

pub const ExprToken = extern union {
    zToken: ?[*:0]u8,
    iValue: c_int,
};

pub const ExprChildren = extern union {
    pList: ?*ExprList,
    pSelect: ?*Select,
};

pub const ExprOrigin = extern union {
    iJoin: c_int,
    iOfst: c_int,
};

pub const ExprSubroutine = extern struct {
    iAddr: c_int,
    regReturn: c_int,
};

pub const ExprAux = extern union {
    pTab: ?*Table,
    pWin: ?*Window,
    nReg: c_int,
    sub: ExprSubroutine,
};

pub const expr_flag = struct {
    pub const x_is_select: u32 = @intCast(facts.constants.EP_xIsSelect);
    pub const token_only: u32 = @intCast(facts.constants.EP_TokenOnly);
    pub const leaf: u32 = @intCast(facts.constants.EP_Leaf);
    pub const win_func: u32 = @intCast(facts.constants.EP_WinFunc);
    pub const static: u32 = @intCast(facts.constants.EP_Static);
};

pub const expression_opcode = struct {
    pub const select_column: u8 = @intCast(facts.constants.TK_SELECT_COLUMN);
    pub const function: u8 = @intCast(facts.constants.TK_FUNCTION);
};

pub const Expr = extern struct {
    op: u8,
    affExpr: u8,
    op2: u8,
    _padding0: u8 = 0,
    flags: u32,
    u: ExprToken,
    pLeft: ?*Expr,
    pRight: ?*Expr,
    x: ExprChildren,
    nHeight: c_int,
    iTable: c_int,
    iColumn: i16,
    iAgg: i16,
    w: ExprOrigin,
    pAggInfo: ?*AggInfo,
    y: ExprAux,

    pub const full_size = facts.constants.EXPR_FULLSIZE;
    pub const reduced_size = facts.constants.EXPR_REDUCEDSIZE;
    pub const token_only_size = facts.constants.EXPR_TOKENONLYSIZE;

    pub fn has(self: *const Expr, mask: u32) bool {
        return self.flags & mask != 0;
    }
    pub fn usesSelect(self: *const Expr) bool {
        return self.has(expr_flag.x_is_select);
    }
    pub fn usesList(self: *const Expr) bool {
        return !self.usesSelect();
    }
};

pub const Window = extern struct {
    name: ?[*:0]u8,
    base_name: ?[*:0]u8,
    partition_by: ?*ExprList,
    order_by: ?*ExprList,
    frame_type: u8,
    start_type: u8,
    end_type: u8,
    implicit_frame: u8,
    exclusion: u8,
    _padding0: [3]u8 = .{0} ** 3,
    start: ?*Expr,
    end: ?*Expr,
    owner_link: ?*?*Window,
    next: ?*Window,
    filter: ?*Expr,
    function: ?*FuncDef,
    ephemeral_cursor: c_int,
    accumulator_register: c_int,
    result_register: c_int,
    application_cursor: c_int,
    application_register: c_int,
    partition_register: c_int,
    owner: ?*Expr,
    buffer_column_count: c_int,
    argument_column: c_int,
    one_register: c_int,
    start_rowid_register: c_int,
    end_rowid_register: c_int,
    expression_arguments: u8,
};

pub const Trigger = extern struct {
    name: ?[*:0]u8,
    table_name: ?[*:0]u8,
    operation: u8,
    timing: u8,
    returning: u8,
    _padding0: [5]u8 = .{0} ** 5,
    when: ?*Expr,
    columns: ?*IdList,
    schema: ?*schema_types.Schema,
    table_schema: ?*schema_types.Schema,
    steps: ?*TriggerStep,
    next: ?*Trigger,
};

pub const TriggerStep = extern struct {
    operation: u8,
    conflict_action: u8,
    _padding0: [6]u8 = .{0} ** 6,
    trigger: ?*Trigger,
    select: ?*Select,
    sources: ?*SrcList,
    where: ?*Expr,
    expressions: ?*ExprList,
    columns: ?*IdList,
    upsert: ?*Upsert,
    span: ?[*:0]u8,
    next: ?*TriggerStep,
    last: ?*TriggerStep,
};

pub const Cte = extern struct {
    zName: ?[*:0]u8,
    pCols: ?*ExprList,
    pSelect: ?*Select,
    zCteErr: ?[*:0]const u8,
    pUse: ?*CteUse,
    eM10d: u8,
};

pub const With = extern struct {
    nCte: c_int,
    bView: c_int,
    pOuter: ?*With,
    a: [0]Cte,

    pub fn items(self: *With) []Cte {
        const pointer: [*]Cte = @ptrCast(&self.a);
        return pointer[0..@intCast(self.nCte)];
    }
};

pub const Upsert = extern struct {
    pUpsertTarget: ?*ExprList,
    pUpsertTargetWhere: ?*Expr,
    pUpsertSet: ?*ExprList,
    pUpsertWhere: ?*Expr,
    pNextUpsert: ?*Upsert,
    isDoUpdate: u8,
    isDup: u8,
    _padding0: [6]u8 = .{0} ** 6,
    pToFree: ?*anyopaque,
    pUpsertIdx: ?*Index,
    pUpsertSrc: ?*SrcList,
    regData: c_int,
    iDataCur: c_int,
    iIdxCur: c_int,
};

pub const Select = extern struct {
    op: u8,
    _padding0: u8 = 0,
    nSelectRow: i16,
    selFlags: u32,
    iLimit: c_int,
    iOffset: c_int,
    selId: u32,
    pEList: ?*ExprList,
    pSrc: ?*SrcList,
    pWhere: ?*Expr,
    pGroupBy: ?*ExprList,
    pHaving: ?*Expr,
    pOrderBy: ?*ExprList,
    pPrior: ?*Select,
    pNext: ?*Select,
    pLimit: ?*Expr,
    pWith: ?*With,
    pWin: ?*Window,
    pWinDefn: ?*Window,
};

pub const IdListItem = extern struct {
    zName: ?[*:0]u8,
};

/// Header immediately followed by `nId` identifier items.
pub const IdList = extern struct {
    nId: c_int,
    a: [0]IdListItem,

    pub fn items(self: *IdList) []IdListItem {
        const pointer: [*]IdListItem = @ptrCast(&self.a);
        return pointer[0..@intCast(self.nId)];
    }
};

pub const ExprListFlags = packed struct(u32) {
    sortFlags: u8,
    eEName: u2,
    done: bool,
    reusable: bool,
    bSorterRef: bool,
    bNulls: bool,
    bUsed: bool,
    bUsingTerm: bool,
    bNoExpand: bool,
    _reserved: u15 = 0,
};

pub const ExprListOrder = extern struct {
    iOrderByCol: u16,
    iAlias: u16,
};

pub const ExprListItemValue = extern union {
    x: ExprListOrder,
    iConstExprReg: c_int,
};

pub const ExprListItem = extern struct {
    pExpr: ?*Expr,
    zEName: ?[*:0]u8,
    fg: ExprListFlags,
    u: ExprListItemValue,
};

/// Header immediately followed by storage for `nAlloc` `ExprListItem` values.
pub const ExprList = extern struct {
    nExpr: c_int,
    nAlloc: c_int,
    a: [0]ExprListItem,

    pub fn items(self: *ExprList) []ExprListItem {
        const pointer: [*]ExprListItem = @ptrCast(&self.a);
        return pointer[0..@intCast(self.nExpr)];
    }
};

pub const Subquery = extern struct {
    pSelect: ?*Select,
    addrFillSub: c_int,
    regReturn: c_int,
    regResult: c_int,
};

pub const OnOrUsing = extern struct {
    pOn: ?*Expr,
    pUsing: ?*IdList,
};

pub const TrigEvent = extern struct {
    a: c_int,
    b: ?*IdList,
};

pub const FrameBound = extern struct {
    eType: c_int,
    pExpr: ?*Expr,
};

pub const ValueMask = extern struct {
    value: c_int,
    mask: c_int,
};

/// Exact untagged Lemon minor-value union generated from the pinned grammar.
/// The stack symbol determines which member is live.
pub const SemanticValue = extern union {
    yyinit: c_int,
    yy0: Token,
    yy14: ?*ExprList,
    yy59: ?*With,
    yy67: ?*Cte,
    yy122: ?*Upsert,
    yy132: ?*IdList,
    yy144: c_int,
    yy168: ?[*]const u8,
    yy203: ?*SrcList,
    yy211: ?*Window,
    yy269: OnOrUsing,
    yy286: TrigEvent,
    yy383: ValueMask,
    yy391: u32,
    yy427: ?*TriggerStep,
    yy454: ?*Expr,
    yy462: u8,
    yy509: FrameBound,
    yy555: ?*Select,
};

pub const SrcFlags = packed struct(u32) {
    jointype: u8,
    notIndexed: bool,
    isIndexedBy: bool,
    isSubquery: bool,
    isTabFunc: bool,
    isCorrelated: bool,
    isMaterialized: bool,
    viaCoroutine: bool,
    isRecursive: bool,
    fromDDL: bool,
    isCte: bool,
    notCte: bool,
    isUsing: bool,
    isOn: bool,
    isSynthUsing: bool,
    isNestedFrom: bool,
    rowidUsed: bool,
    fixedSchema: bool,
    hadSchema: bool,
    fromExists: bool,
    _reserved: u5 = 0,
};

pub const SrcIndex = extern union {
    zIndexedBy: ?[*:0]u8,
    pFuncArg: ?*ExprList,
    nRow: u32,
};

pub const SrcIndexInfo = extern union {
    pIBIndex: ?*Index,
    pCteUse: ?*CteUse,
};

pub const SrcConstraint = extern union {
    pOn: ?*Expr,
    pUsing: ?*IdList,
};

pub const SrcSchema = extern union {
    pSchema: ?*anyopaque,
    zDatabase: ?[*:0]u8,
    pSubq: ?*Subquery,
};

pub const SrcItem = extern struct {
    zName: ?[*:0]u8,
    zAlias: ?[*:0]u8,
    pSTab: ?*Table,
    fg: SrcFlags,
    iCursor: c_int,
    colUsed: u64,
    u1: SrcIndex,
    u2: SrcIndexInfo,
    u3: SrcConstraint,
    u4: SrcSchema,
};

/// Header immediately followed by storage for `nAlloc` `SrcItem` values.
pub const SrcList = extern struct {
    nSrc: c_int,
    nAlloc: u32,
    a: [0]SrcItem,

    pub const one_item_size = facts.constants.SZ_SRCLIST_1;

    pub fn items(self: *SrcList) []SrcItem {
        const pointer: [*]SrcItem = @ptrCast(&self.a);
        return pointer[0..@intCast(self.nSrc)];
    }
};

pub const ParseCleanup = extern struct {
    pNext: ?*ParseCleanup,
    pPtr: ?*anyopaque,
    xCleanup: ?*const fn (?*Sqlite3, ?*anyopaque) callconv(.c) void,
};

pub const ParseCreateState = extern struct {
    addrCrTab: c_int,
    regRowid: c_int,
    regRoot: c_int,
    constraintName: Token,
};

pub const ParseOtherState = extern struct {
    pReturning: ?*Returning,
};

pub const ParseStatementState = extern union {
    cr: ParseCreateState,
    d: ParseOtherState,
};

pub const Parse = extern struct {
    db: ?*Sqlite3,
    zErrMsg: ?[*:0]u8,
    pVdbe: ?*Vdbe,
    rc: c_int,
    nQueryLoop: i16,
    nested: u8,
    nTempReg: u8,
    isMultiWrite: u8,
    disableLookaside: u8,
    prepFlags: u8,
    withinRJSubrtn: u8,
    mSubrtnSig: u8,
    eTriggerOp: u8,
    eOrconf: u8,
    flags0: u8,
    flags1: u8,
    _flag_padding: [3]u8 = .{ 0, 0, 0 },
    nRangeReg: c_int,
    iRangeReg: c_int,
    nErr: c_int,
    nTab: c_int,
    nMem: c_int,
    szOpAlloc: c_int,
    iSelfTab: c_int,
    nNestSel: c_int,
    nLabel: c_int,
    nLabelAlloc: c_int,
    aLabel: ?[*]c_int,
    pConstExpr: ?*ExprList,
    pIdxEpr: ?*IndexedExpr,
    pIdxPartExpr: ?*IndexedExpr,
    writeMask: u32,
    cookieMask: u32,
    nMaxArg: c_int,
    nSelect: c_int,
    nProgressSteps: u32,
    nTableLock: c_int,
    aTableLock: ?*TableLock,
    pAinc: ?*AutoincInfo,
    pToplevel: ?*Parse,
    pTriggerTab: ?*Table,
    pTriggerPrg: ?*TriggerPrg,
    pCleanup: ?*ParseCleanup,
    aTempReg: [8]c_int,
    pOuterParse: ?*Parse,
    sNameToken: Token,
    oldmask: u32,
    newmask: u32,
    u1: ParseStatementState,
    sLastToken: Token,
    nVar: i16,
    iPkSortOrder: u8,
    explain: u8,
    eParseMode: u8,
    _padding1: [3]u8 = .{ 0, 0, 0 },
    nVtabLock: c_int,
    nHeight: c_int,
    addrExplain: c_int,
    _padding2: u32 = 0,
    pVList: ?*VList,
    pReprepare: ?*Vdbe,
    zTail: ?[*]const u8,
    pNewTable: ?*Table,
    pNewIndex: ?*Index,
    pNewTrigger: ?*Trigger,
    zAuthContext: ?[*:0]const u8,
    sArg: Token,
    apVtabLock: ?[*]?*Table,
    pWith: ?*With,
    pRename: ?*RenameToken,

    pub const header_size = facts.constants.PARSE_HDR_SZ;
    pub const recursive_offset = facts.constants.PARSE_RECURSE_SZ;
    pub const tail_size = facts.constants.PARSE_TAIL_SZ;

    pub fn disableTriggers(self: *const Parse) bool {
        return self.flags0 & 0x01 != 0;
    }

    pub fn setDisableTriggers(self: *Parse, enabled: bool) void {
        if (enabled) self.flags0 |= 0x01 else self.flags0 &= ~@as(u8, 0x01);
    }

    pub fn checkSchema(self: *const Parse) bool {
        return self.flags1 & 0x01 != 0;
    }

    pub fn setCheckSchema(self: *Parse, enabled: bool) void {
        if (enabled) self.flags1 |= 0x01 else self.flags1 &= ~@as(u8, 0x01);
    }
};

fn checkPackedFlag(
    comptime T: type,
    comptime field: []const u8,
    comptime base_offset: usize,
    comptime c_offset: usize,
    comptime c_mask: usize,
) void {
    const bit_offset = @bitOffsetOf(T, field);
    const bit_size = @bitSizeOf(@FieldType(T, field));
    const zig_offset = base_offset + bit_offset / 8;
    const zig_mask = ((@as(usize, 1) << bit_size) - 1) << @intCast(bit_offset % 8);
    if (zig_offset != c_offset or zig_mask != c_mask)
        @compileError(@typeName(T) ++ "." ++ field ++ " bit layout differs from pinned C profile");
}

fn checkMappedLayout(comptime T: type, comptime F: type, comptime fields: anytype) void {
    if (@sizeOf(T) != F.size or @alignOf(T) != F.alignment)
        @compileError(@typeName(T) ++ " layout differs from pinned C profile");
    inline for (fields) |field| {
        if (@offsetOf(T, field[0]) != @field(F, field[1] ++ "_offset"))
            @compileError(@typeName(T) ++ "." ++ field[0] ++ " offset differs from pinned C profile");
        if (@sizeOf(@FieldType(T, field[0])) != @field(F, field[1] ++ "_size"))
            @compileError(@typeName(T) ++ "." ++ field[0] ++ " size differs from pinned C profile");
    }
}

fn checkUnionLayout(comptime T: type, comptime F: type, comptime fields: []const []const u8) void {
    if (@sizeOf(T) != F.size) @compileError(@typeName(T) ++ " size differs from pinned C profile");
    if (@alignOf(T) != F.alignment) @compileError(@typeName(T) ++ " alignment differs from pinned C profile");
    inline for (fields) |field| {
        if (@field(F, field ++ "_offset") != 0)
            @compileError(@typeName(T) ++ "." ++ field ++ " C union offset is not zero");
        if (@sizeOf(@FieldType(T, field)) != @field(F, field ++ "_size"))
            @compileError(@typeName(T) ++ "." ++ field ++ " size differs from pinned C profile");
    }
}

fn checkLayout(comptime T: type, comptime F: type, comptime fields: []const []const u8) void {
    if (@sizeOf(T) != F.size) @compileError(@typeName(T) ++ " size differs from pinned C profile");
    if (@alignOf(T) != F.alignment) @compileError(@typeName(T) ++ " alignment differs from pinned C profile");
    inline for (fields) |field| {
        if (@offsetOf(T, field) != @field(F, field ++ "_offset"))
            @compileError(@typeName(T) ++ "." ++ field ++ " offset differs from pinned C profile");
        if (@sizeOf(@FieldType(T, field)) != @field(F, field ++ "_size"))
            @compileError(@typeName(T) ++ "." ++ field ++ " size differs from pinned C profile");
    }
}

comptime {
    checkLayout(Token, facts.Token, &.{ "z", "n" });
    checkLayout(Expr, facts.Expr, &.{ "op", "affExpr", "op2", "flags", "u", "pLeft", "pRight", "x", "nHeight", "iTable", "iColumn", "iAgg", "w", "pAggInfo", "y" });
    checkMappedLayout(Window, facts.Window, .{
        .{ "name", "zName" },                    .{ "base_name", "zBase" },                    .{ "partition_by", "pPartition" },        .{ "order_by", "pOrderBy" },
        .{ "frame_type", "eFrmType" },           .{ "start_type", "eStart" },                  .{ "end_type", "eEnd" },                  .{ "implicit_frame", "bImplicitFrame" },
        .{ "exclusion", "eExclude" },            .{ "start", "pStart" },                       .{ "end", "pEnd" },                       .{ "owner_link", "ppThis" },
        .{ "next", "pNextWin" },                 .{ "filter", "pFilter" },                     .{ "function", "pWFunc" },                .{ "ephemeral_cursor", "iEphCsr" },
        .{ "accumulator_register", "regAccum" }, .{ "result_register", "regResult" },          .{ "application_cursor", "csrApp" },      .{ "application_register", "regApp" },
        .{ "partition_register", "regPart" },    .{ "owner", "pOwner" },                       .{ "buffer_column_count", "nBufferCol" }, .{ "argument_column", "iArgCol" },
        .{ "one_register", "regOne" },           .{ "start_rowid_register", "regStartRowid" }, .{ "end_rowid_register", "regEndRowid" }, .{ "expression_arguments", "bExprArgs" },
    });
    checkMappedLayout(Trigger, facts.Trigger, .{
        .{ "name", "zName" }, .{ "table_name", "table" }, .{ "operation", "op" },   .{ "timing", "tr_tm" },            .{ "returning", "bReturning" },
        .{ "when", "pWhen" }, .{ "columns", "pColumns" }, .{ "schema", "pSchema" }, .{ "table_schema", "pTabSchema" }, .{ "steps", "step_list" },
        .{ "next", "pNext" },
    });
    checkMappedLayout(TriggerStep, facts.TriggerStep, .{
        .{ "operation", "op" }, .{ "conflict_action", "orconf" }, .{ "trigger", "pTrig" },   .{ "select", "pSelect" }, .{ "sources", "pSrc" },
        .{ "where", "pWhere" }, .{ "expressions", "pExprList" },  .{ "columns", "pIdList" }, .{ "upsert", "pUpsert" }, .{ "span", "zSpan" },
        .{ "next", "pNext" },   .{ "last", "pLast" },
    });
    checkLayout(Cte, facts.Cte, &.{ "zName", "pCols", "pSelect", "zCteErr", "pUse", "eM10d" });
    checkLayout(With, facts.With, &.{ "nCte", "bView", "pOuter", "a" });
    checkLayout(Upsert, facts.Upsert, &.{ "pUpsertTarget", "pUpsertTargetWhere", "pUpsertSet", "pUpsertWhere", "pNextUpsert", "isDoUpdate", "isDup", "pToFree", "pUpsertIdx", "pUpsertSrc", "regData", "iDataCur", "iIdxCur" });
    checkLayout(Select, facts.Select, &.{ "op", "nSelectRow", "selFlags", "iLimit", "iOffset", "selId", "pEList", "pSrc", "pWhere", "pGroupBy", "pHaving", "pOrderBy", "pPrior", "pNext", "pLimit", "pWith", "pWin", "pWinDefn" });
    checkLayout(IdListItem, facts.IdListItem, &.{"zName"});
    checkLayout(IdList, facts.IdList, &.{ "nId", "a" });
    checkLayout(ExprListItem, facts.ExprListItem, &.{ "pExpr", "zEName", "fg", "u" });
    checkLayout(ExprList, facts.ExprList, &.{ "nExpr", "nAlloc", "a" });
    checkLayout(Subquery, facts.Subquery, &.{ "pSelect", "addrFillSub", "regReturn", "regResult" });
    checkLayout(OnOrUsing, facts.OnOrUsing, &.{ "pOn", "pUsing" });
    checkLayout(TrigEvent, facts.TrigEvent, &.{ "a", "b" });
    checkLayout(FrameBound, facts.FrameBound, &.{ "eType", "pExpr" });
    checkUnionLayout(SemanticValue, facts.SemanticValue, &.{ "yyinit", "yy0", "yy14", "yy59", "yy67", "yy122", "yy132", "yy144", "yy168", "yy203", "yy211", "yy269", "yy286", "yy383", "yy391", "yy427", "yy454", "yy462", "yy509", "yy555" });
    checkLayout(SrcItem, facts.SrcItem, &.{ "zName", "zAlias", "pSTab", "fg", "iCursor", "colUsed", "u1", "u2", "u3", "u4" });
    checkLayout(SrcList, facts.SrcList, &.{ "nSrc", "nAlloc", "a" });
    checkLayout(ParseCleanup, facts.ParseCleanup, &.{ "pNext", "pPtr", "xCleanup" });
    checkLayout(Parse, facts.Parse, &.{ "db", "zErrMsg", "pVdbe", "rc", "nQueryLoop", "nested", "nTempReg", "isMultiWrite", "disableLookaside", "prepFlags", "withinRJSubrtn", "mSubrtnSig", "eTriggerOp", "eOrconf", "nRangeReg", "iRangeReg", "nErr", "nTab", "nMem", "szOpAlloc", "iSelfTab", "nNestSel", "nLabel", "nLabelAlloc", "aLabel", "pConstExpr", "pIdxEpr", "pIdxPartExpr", "writeMask", "cookieMask", "nMaxArg", "nSelect", "nProgressSteps", "nTableLock", "aTableLock", "pAinc", "pToplevel", "pTriggerTab", "pTriggerPrg", "pCleanup", "aTempReg", "pOuterParse", "sNameToken", "oldmask", "newmask", "u1", "sLastToken", "nVar", "iPkSortOrder", "explain", "eParseMode", "nVtabLock", "nHeight", "addrExplain", "pVList", "pReprepare", "zTail", "pNewTable", "pNewIndex", "pNewTrigger", "zAuthContext", "sArg", "apVtabLock", "pWith", "pRename" });
    checkPackedFlag(ExprListFlags, "eEName", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_EENAME_OFFSET, facts.constants.EXPR_LIST_EENAME_MASK);
    checkPackedFlag(ExprListFlags, "done", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_DONE_OFFSET, facts.constants.EXPR_LIST_DONE_MASK);
    checkPackedFlag(ExprListFlags, "reusable", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_REUSABLE_OFFSET, facts.constants.EXPR_LIST_REUSABLE_MASK);
    checkPackedFlag(ExprListFlags, "bSorterRef", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_SORTER_REF_OFFSET, facts.constants.EXPR_LIST_SORTER_REF_MASK);
    checkPackedFlag(ExprListFlags, "bNulls", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_NULLS_OFFSET, facts.constants.EXPR_LIST_NULLS_MASK);
    checkPackedFlag(ExprListFlags, "bUsed", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_USED_OFFSET, facts.constants.EXPR_LIST_USED_MASK);
    checkPackedFlag(ExprListFlags, "bUsingTerm", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_USING_TERM_OFFSET, facts.constants.EXPR_LIST_USING_TERM_MASK);
    checkPackedFlag(ExprListFlags, "bNoExpand", facts.ExprListItem.fg_offset, facts.constants.EXPR_LIST_NO_EXPAND_OFFSET, facts.constants.EXPR_LIST_NO_EXPAND_MASK);

    checkPackedFlag(SrcFlags, "notIndexed", facts.SrcItem.fg_offset, facts.constants.SRC_NOT_INDEXED_OFFSET, facts.constants.SRC_NOT_INDEXED_MASK);
    checkPackedFlag(SrcFlags, "isIndexedBy", facts.SrcItem.fg_offset, facts.constants.SRC_IS_INDEXED_BY_OFFSET, facts.constants.SRC_IS_INDEXED_BY_MASK);
    checkPackedFlag(SrcFlags, "isSubquery", facts.SrcItem.fg_offset, facts.constants.SRC_IS_SUBQUERY_OFFSET, facts.constants.SRC_IS_SUBQUERY_MASK);
    checkPackedFlag(SrcFlags, "isTabFunc", facts.SrcItem.fg_offset, facts.constants.SRC_IS_TAB_FUNC_OFFSET, facts.constants.SRC_IS_TAB_FUNC_MASK);
    checkPackedFlag(SrcFlags, "isCorrelated", facts.SrcItem.fg_offset, facts.constants.SRC_IS_CORRELATED_OFFSET, facts.constants.SRC_IS_CORRELATED_MASK);
    checkPackedFlag(SrcFlags, "isMaterialized", facts.SrcItem.fg_offset, facts.constants.SRC_IS_MATERIALIZED_OFFSET, facts.constants.SRC_IS_MATERIALIZED_MASK);
    checkPackedFlag(SrcFlags, "viaCoroutine", facts.SrcItem.fg_offset, facts.constants.SRC_VIA_COROUTINE_OFFSET, facts.constants.SRC_VIA_COROUTINE_MASK);
    checkPackedFlag(SrcFlags, "isRecursive", facts.SrcItem.fg_offset, facts.constants.SRC_IS_RECURSIVE_OFFSET, facts.constants.SRC_IS_RECURSIVE_MASK);
    checkPackedFlag(SrcFlags, "fromDDL", facts.SrcItem.fg_offset, facts.constants.SRC_FROM_DDL_OFFSET, facts.constants.SRC_FROM_DDL_MASK);
    checkPackedFlag(SrcFlags, "isCte", facts.SrcItem.fg_offset, facts.constants.SRC_IS_CTE_OFFSET, facts.constants.SRC_IS_CTE_MASK);
    checkPackedFlag(SrcFlags, "notCte", facts.SrcItem.fg_offset, facts.constants.SRC_NOT_CTE_OFFSET, facts.constants.SRC_NOT_CTE_MASK);
    checkPackedFlag(SrcFlags, "isUsing", facts.SrcItem.fg_offset, facts.constants.SRC_IS_USING_OFFSET, facts.constants.SRC_IS_USING_MASK);
    checkPackedFlag(SrcFlags, "isOn", facts.SrcItem.fg_offset, facts.constants.SRC_IS_ON_OFFSET, facts.constants.SRC_IS_ON_MASK);
    checkPackedFlag(SrcFlags, "isSynthUsing", facts.SrcItem.fg_offset, facts.constants.SRC_IS_SYNTH_USING_OFFSET, facts.constants.SRC_IS_SYNTH_USING_MASK);
    checkPackedFlag(SrcFlags, "isNestedFrom", facts.SrcItem.fg_offset, facts.constants.SRC_IS_NESTED_FROM_OFFSET, facts.constants.SRC_IS_NESTED_FROM_MASK);
    checkPackedFlag(SrcFlags, "rowidUsed", facts.SrcItem.fg_offset, facts.constants.SRC_ROWID_USED_OFFSET, facts.constants.SRC_ROWID_USED_MASK);
    checkPackedFlag(SrcFlags, "fixedSchema", facts.SrcItem.fg_offset, facts.constants.SRC_FIXED_SCHEMA_OFFSET, facts.constants.SRC_FIXED_SCHEMA_MASK);
    checkPackedFlag(SrcFlags, "hadSchema", facts.SrcItem.fg_offset, facts.constants.SRC_HAD_SCHEMA_OFFSET, facts.constants.SRC_HAD_SCHEMA_MASK);
    checkPackedFlag(SrcFlags, "fromExists", facts.SrcItem.fg_offset, facts.constants.SRC_FROM_EXISTS_OFFSET, facts.constants.SRC_FROM_EXISTS_MASK);

    if (@offsetOf(Parse, "flags0") != facts.constants.PARSE_DISABLE_TRIGGERS_OFFSET or facts.constants.PARSE_DISABLE_TRIGGERS_MASK != 0x01 or facts.constants.PARSE_OK_CONST_FACTOR_MASK != 0x80)
        @compileError("Parse low bitfield storage differs from pinned C profile");
    if (@offsetOf(Parse, "flags1") != facts.constants.PARSE_CHECK_SCHEMA_OFFSET or facts.constants.PARSE_CHECK_SCHEMA_MASK != 0x01)
        @compileError("Parse high bitfield storage differs from pinned C profile");
}

test "source layout and flag accessors" {
    var parse: Parse = undefined;
    parse.flags0 = 0;
    parse.flags1 = 0;
    parse.setDisableTriggers(true);
    parse.setCheckSchema(true);
    try @import("std").testing.expect(parse.disableTriggers());
    try @import("std").testing.expect(parse.checkSchema());

    var expression: Expr = undefined;
    expression.flags = expr_flag.leaf | expr_flag.x_is_select;
    try @import("std").testing.expect(expression.has(expr_flag.leaf));
    try @import("std").testing.expect(expression.usesSelect());
    expression.flags &= ~expr_flag.x_is_select;
    try @import("std").testing.expect(expression.usesList());

    var src: SrcFlags = @bitCast(@as(u32, 0));
    src.jointype = 0x08;
    src.isUsing = true;
    try @import("std").testing.expectEqual(@as(u32, 0x00080008), @as(u32, @bitCast(src)));
}
