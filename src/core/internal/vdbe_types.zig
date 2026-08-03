//! Source-faithful active-profile data types from `src/vdbe.h`.

const std = @import("std");
const canonical_opcode = @import("../generated/opcodes.zig");
const internal_hash = @import("../hash.zig");
const config_types = @import("config_types.zig");
const parse_types = @import("parse_types.zig");
pub const schema_types = @import("schema_types.zig");
const layout = @import("../generated/internal_vdbe_layout.zig");

pub const Bool = u32;
pub const YnVar = i16;
pub const DbMask = u32;
pub const display_p4 = true;
pub const Parse = parse_types.Parse;
pub const VList = opaque {};
pub const VTable = extern struct {
    db: ?*Sqlite3,
    pMod: ?*Module,
    pVtab: ?*PublicVtab,
    nRef: c_int,
    bConstraint: u8,
    bAllSchemas: u8,
    eVtabRisk: u8,
    iSavepoint: c_int,
    pNext: ?*VTable,
};
pub const Table = schema_types.Table;
pub const Index = schema_types.Index;
pub const VdbeSorter = opaque {};
pub const BtCursor = opaque {};
pub const BtShared = opaque {};
pub const BtLock = extern struct {
    pBtree: ?*Btree,
    iTable: u32,
    eLock: u8,
    pNext: ?*BtLock,
};
pub const Btree = extern struct {
    db: ?*Sqlite3,
    pBt: ?*BtShared,
    inTrans: u8,
    sharable: u8,
    locked: u8,
    hasIncrblobCur: u8,
    wantToLock: c_int,
    nBackup: c_int,
    iBDataVersion: u32,
    pNext: ?*Btree,
    pPrev: ?*Btree,
    lock: BtLock,
};
pub const VtabCursor = opaque {};
pub const Vfs = opaque {};
pub const Mutex = config_types.Mutex;
pub const PublicModule = extern struct {
    iVersion: c_int,
    xCreate: ?*const anyopaque,
    xConnect: ?*const anyopaque,
    xBestIndex: ?*const anyopaque,
    xDisconnect: ?*const fn (?*PublicVtab) callconv(.c) c_int,
    xDestroy: ?*const anyopaque,
    xOpen: ?*const anyopaque,
    xClose: ?*const anyopaque,
    xFilter: ?*const anyopaque,
    xNext: ?*const anyopaque,
    xEof: ?*const anyopaque,
    xColumn: ?*const anyopaque,
    xRowid: ?*const anyopaque,
    xUpdate: ?*const anyopaque,
    xBegin: ?*const anyopaque,
    xSync: ?*const anyopaque,
    xCommit: ?*const anyopaque,
    xRollback: ?*const anyopaque,
    xFindFunction: ?*const anyopaque,
    xRename: ?*const anyopaque,
    xSavepoint: ?*const anyopaque,
    xRelease: ?*const anyopaque,
    xRollbackTo: ?*const anyopaque,
    xShadowName: ?*const anyopaque,
    xIntegrity: ?*const anyopaque,
};
pub const PublicVtab = extern struct {
    pModule: ?*const PublicModule,
    nRef: c_int,
    zErrMsg: ?[*:0]u8,
};
pub const VtabCtx = opaque {};
pub const PcacheMethods2 = config_types.PcacheMethods2;
pub const Sqlite3Config = config_types.Sqlite3Config;

pub const BusyHandler = extern struct {
    xBusyHandler: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int,
    pBusyArg: ?*anyopaque,
    nBusy: c_int,
};

pub const Schema = schema_types.Schema;

pub const Db = extern struct {
    zDbSName: ?[*:0]u8,
    pBt: ?*Btree,
    safety_level: u8,
    bSyncSet: u8,
    pSchema: ?*Schema,
};

pub const schema_flag = struct {
    pub const loaded: u16 = 0x0001;
    pub const unreset_views: u16 = 0x0002;
    pub const reset_wanted: u16 = 0x0008;
};

pub const LookasideSlot = extern struct {
    pNext: ?*LookasideSlot,
};

pub const Lookaside = extern struct {
    bDisable: u32,
    sz: u16,
    szTrue: u16,
    bMalloced: u8,
    nSlot: u32,
    anStat: [3]u32,
    pInit: ?*LookasideSlot,
    pFree: ?*LookasideSlot,
    pSmallInit: ?*LookasideSlot,
    pSmallFree: ?*LookasideSlot,
    pMiddle: ?*anyopaque,
    pStart: ?*anyopaque,
    pEnd: ?*anyopaque,
    pTrueEnd: ?*anyopaque,
};

pub const lookaside_small: usize = 128;

pub const Sqlite3InitInfoFlags = packed struct(u16) {
    orphanTrigger: bool,
    imposterTable: u2,
    reopenMemdb: bool,
    padding: u12 = 0,
};

pub const Sqlite3InitInfo = extern struct {
    newTnum: u32,
    iDb: u8,
    busy: u8,
    flags: Sqlite3InitInfoFlags,
    azInit: ?[*]?[*:0]const u8,
};

pub const Sqlite3Trace = extern union {
    xLegacy: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) void,
    xV2: ?*const fn (u32, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
};

pub const Sqlite3Interrupt = extern union {
    isInterrupted: c_int,
    notUsed1: f64,
};

pub const Sqlite3Auth = *const fn (
    ?*anyopaque,
    c_int,
    ?[*:0]const u8,
    ?[*:0]const u8,
    ?[*:0]const u8,
    ?[*:0]const u8,
) callconv(.c) c_int;

pub const Sqlite3 = extern struct {
    pVfs: ?*Vfs,
    pVdbe: ?*Vdbe,
    pDfltColl: ?*CollSeq,
    mutex: ?*Mutex,
    aDb: ?[*]Db,
    nDb: c_int,
    mDbFlags: u32,
    flags: u64,
    lastRowid: i64,
    szMmap: i64,
    nSchemaLock: u32,
    openFlags: c_uint,
    errCode: c_int,
    errByteOffset: c_int,
    errMask: c_int,
    iSysErrno: c_int,
    dbOptFlags: u32,
    enc: u8,
    autoCommit: u8,
    temp_store: u8,
    mallocFailed: u8,
    bBenignMalloc: u8,
    dfltLockMode: u8,
    nextAutovac: i8,
    suppressErr: u8,
    vtabOnConflict: u8,
    isTransactionSavepoint: u8,
    mTrace: u8,
    noSharedCache: u8,
    nSqlExec: u8,
    eOpenState: u8,
    nFpDigit: u8,
    nextPagesize: c_int,
    nChange: i64,
    nTotalChange: i64,
    aLimit: [limit_count]c_int,
    nMaxSorterMmap: c_int,
    init: Sqlite3InitInfo,
    nVdbeActive: c_int,
    nVdbeRead: c_int,
    nVdbeWrite: c_int,
    nVdbeExec: c_int,
    nVDestroy: c_int,
    nExtension: c_int,
    aExtension: ?[*]?*anyopaque,
    trace: Sqlite3Trace,
    pTraceArg: ?*anyopaque,
    xProfile: ?*const fn (?*anyopaque, ?[*:0]const u8, u64) callconv(.c) void,
    pProfileArg: ?*anyopaque,
    pCommitArg: ?*anyopaque,
    xCommitCallback: ?*const fn (?*anyopaque) callconv(.c) c_int,
    pRollbackArg: ?*anyopaque,
    xRollbackCallback: ?*const fn (?*anyopaque) callconv(.c) void,
    pUpdateArg: ?*anyopaque,
    xUpdateCallback: ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, i64) callconv(.c) void,
    pAutovacPagesArg: ?*anyopaque,
    xAutovacDestr: ?*const fn (?*anyopaque) callconv(.c) void,
    xAutovacPages: ?*const fn (?*anyopaque, ?[*:0]const u8, u32, u32, u32) callconv(.c) c_uint,
    pParse: ?*Parse,
    xWalCallback: ?*const fn (?*anyopaque, ?*Sqlite3, ?[*:0]const u8, c_int) callconv(.c) c_int,
    pWalArg: ?*anyopaque,
    xCollNeeded: ?*const fn (?*anyopaque, ?*Sqlite3, c_int, ?[*:0]const u8) callconv(.c) void,
    xCollNeeded16: ?*const fn (?*anyopaque, ?*Sqlite3, c_int, ?*const anyopaque) callconv(.c) void,
    pCollNeededArg: ?*anyopaque,
    pErr: ?*Mem,
    u1: Sqlite3Interrupt,
    lookaside: Lookaside,
    xAuth: ?Sqlite3Auth,
    pAuthArg: ?*anyopaque,
    xProgress: ?*const fn (?*anyopaque) callconv(.c) c_int,
    pProgressArg: ?*anyopaque,
    nProgressOps: c_uint,
    nVTrans: c_int,
    aModule: internal_hash.Hash,
    pVtabCtx: ?*VtabCtx,
    aVTrans: ?[*]?*VTable,
    pDisconnect: ?*VTable,
    aFunc: internal_hash.Hash,
    aCollSeq: internal_hash.Hash,
    busyHandler: BusyHandler,
    aDbStatic: [2]Db,
    pSavepoint: ?*Savepoint,
    nAnalysisLimit: c_int,
    busyTimeout: c_int,
    nSavepoint: c_int,
    nStatement: c_int,
    nDeferredCons: i64,
    nDeferredImmCons: i64,
    pnBytesFreed: ?*c_int,
    pDbData: ?*DbClientData,
    nSpill: u64,
};

pub const limit_count: usize = 13;
pub const max_database_count: usize = 12;

pub const trace_flag = struct {
    pub const legacy: u8 = 0x40;
    pub const profile: u8 = 0x80;
    pub const nonlegacy_mask: u8 = 0x0f;
};

pub const connection_flag = struct {
    pub const write_schema: u64 = 0x0000_0001;
    pub const legacy_file_format: u64 = 0x0000_0002;
    pub const full_column_names: u64 = 0x0000_0004;
    pub const full_fsync: u64 = 0x0000_0008;
    pub const checkpoint_full_fsync: u64 = 0x0000_0010;
    pub const cache_spill: u64 = 0x0000_0020;
    pub const short_column_names: u64 = 0x0000_0040;
    pub const trusted_schema: u64 = 0x0000_0080;
    pub const null_callback: u64 = 0x0000_0100;
    pub const ignore_checks: u64 = 0x0000_0200;
    pub const statement_scan_status: u64 = 0x0000_0400;
    pub const no_checkpoint_on_close: u64 = 0x0000_0800;
    pub const reverse_order: u64 = 0x0000_1000;
    pub const recursive_triggers: u64 = 0x0000_2000;
    pub const foreign_keys: u64 = 0x0000_4000;
    pub const automatic_index: u64 = 0x0000_8000;
    pub const load_extension: u64 = 0x0001_0000;
    pub const load_extension_function: u64 = 0x0002_0000;
    pub const enable_trigger: u64 = 0x0004_0000;
    pub const defer_foreign_keys: u64 = 0x0008_0000;
    pub const query_only: u64 = 0x0010_0000;
    pub const cell_size_check: u64 = 0x0020_0000;
    pub const fts3_tokenizer: u64 = 0x0040_0000;
    pub const enable_qpsg: u64 = 0x0080_0000;
    pub const trigger_eqp: u64 = 0x0100_0000;
    pub const reset_database: u64 = 0x0200_0000;
    pub const legacy_alter: u64 = 0x0400_0000;
    pub const no_schema_error: u64 = 0x0800_0000;
    pub const defensive: u64 = 0x1000_0000;
    pub const dqs_ddl: u64 = 0x2000_0000;
    pub const dqs_dml: u64 = 0x4000_0000;
    pub const enable_view: u64 = 0x8000_0000;
    pub const count_rows: u64 = 0x0000_0001_0000_0000;
    pub const corrupt_read_only: u64 = 0x0000_0002_0000_0000;
    pub const read_uncommitted: u64 = 0x0000_0004_0000_0000;
    pub const foreign_key_no_action: u64 = 0x0000_0008_0000_0000;
    pub const attach_create: u64 = 0x0000_0010_0000_0000;
    pub const attach_write: u64 = 0x0000_0020_0000_0000;
    pub const comments: u64 = 0x0000_0040_0000_0000;
};

pub const database_flag = struct {
    pub const schema_change: u32 = 0x0001;
    pub const prefer_builtin: u32 = 0x0002;
    pub const vacuum: u32 = 0x0004;
    pub const vacuum_into: u32 = 0x0008;
    pub const schema_known_ok: u32 = 0x0010;
    pub const internal_function: u32 = 0x0020;
    pub const encoding_fixed: u32 = 0x0040;
};

pub const optimization = struct {
    pub const query_flattener: u32 = 0x0000_0001;
    pub const window_function: u32 = 0x0000_0002;
    pub const group_by_order: u32 = 0x0000_0004;
    pub const factor_out_constants: u32 = 0x0000_0008;
    pub const distinct: u32 = 0x0000_0010;
    pub const covering_index_scan: u32 = 0x0000_0020;
    pub const order_by_index_join: u32 = 0x0000_0040;
    pub const transitive: u32 = 0x0000_0080;
    pub const omit_noop_join: u32 = 0x0000_0100;
    pub const count_of_view: u32 = 0x0000_0200;
    pub const cursor_hints: u32 = 0x0000_0400;
    pub const stat4: u32 = 0x0000_0800;
    pub const push_down: u32 = 0x0000_1000;
    pub const simplify_join: u32 = 0x0000_2000;
    pub const skip_scan: u32 = 0x0000_4000;
    pub const propagate_constants: u32 = 0x0000_8000;
    pub const min_max: u32 = 0x0001_0000;
    pub const seek_scan: u32 = 0x0002_0000;
    pub const omit_order_by: u32 = 0x0004_0000;
    pub const bloom_filter: u32 = 0x0008_0000;
    pub const bloom_pull_down: u32 = 0x0010_0000;
    pub const balanced_merge: u32 = 0x0020_0000;
    pub const release_register: u32 = 0x0040_0000;
    pub const flatten_union_all: u32 = 0x0080_0000;
    pub const indexed_expression: u32 = 0x0100_0000;
    pub const coroutines: u32 = 0x0200_0000;
    pub const null_unused_columns: u32 = 0x0400_0000;
    pub const one_pass: u32 = 0x0800_0000;
    pub const order_by_subquery: u32 = 0x1000_0000;
    pub const star_query: u32 = 0x2000_0000;
    pub const exists_to_join: u32 = 0x4000_0000;
    pub const all: u32 = 0xffff_ffff;
};

pub const connection_state = struct {
    pub const open: u8 = 0x76;
    pub const closed: u8 = 0xce;
    pub const sick: u8 = 0xba;
    pub const busy: u8 = 0x6d;
    pub const error_: u8 = 0xd5;
    pub const zombie: u8 = 0xa7;
};

pub fn schemaEncoding(db: *const Sqlite3) u8 {
    return db.aDb.?[0].pSchema.?.encoding;
}

pub fn encoding(db: *const Sqlite3) u8 {
    return db.enc;
}

pub fn highBits(value: u32) u64 {
    return @as(u64, value) << 32;
}

pub fn optimizationDisabled(db: *const Sqlite3, mask: u32) bool {
    return db.dbOptFlags & mask != 0;
}

pub fn optimizationEnabled(db: *const Sqlite3, mask: u32) bool {
    return db.dbOptFlags & mask == 0;
}

pub fn disableLookaside(lookaside: *Lookaside) void {
    lookaside.bDisable += 1;
    lookaside.sz = 0;
}

pub fn enableLookaside(lookaside: *Lookaside) void {
    lookaside.bDisable -= 1;
    lookaside.sz = if (lookaside.bDisable == 0) lookaside.szTrue else 0;
}

pub const CollSeq = extern struct {
    zName: ?[*:0]u8,
    enc: u8,
    pUser: ?*anyopaque,
    xCmp: ?*const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int,
    xDel: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub const sort_order = struct {
    pub const ascending: i8 = 0;
    pub const descending: i8 = 1;
    pub const undefined_: i8 = -1;
};

pub const KeyInfo = extern struct {
    nRef: u32,
    enc: u8,
    nKeyField: u16,
    nAllField: u16,
    db: ?*Sqlite3,
    aSortFlags: ?[*]u8,
    aColl: [0]?*CollSeq,
};

pub const key_info_order = struct {
    pub const descending: u8 = 0x01;
    pub const big_null: u8 = 0x02;
};

pub fn keyInfoSize(field_count: usize) usize {
    return @offsetOf(KeyInfo, "aColl") + field_count * @sizeOf(?*CollSeq);
}

pub const UnpackedValue = extern union {
    z: ?[*]u8,
    i: i64,
};

pub const UnpackedRecord = extern struct {
    pKeyInfo: ?*KeyInfo,
    aMem: ?[*]Mem,
    u: UnpackedValue,
    n: c_int,
    nField: u16,
    default_rc: i8,
    errCode: u8,
    r1: i8,
    r2: i8,
    eqSeen: u8,
};

pub const FuncDestructor = extern struct {
    nRef: c_int,
    xDestroy: ?*const fn (?*anyopaque) callconv(.c) void,
    pUserData: ?*anyopaque,
};

pub const FuncOwner = extern union {
    pHash: ?*FuncDef,
    pDestructor: ?*FuncDestructor,
};

pub const FuncDef = extern struct {
    nArg: i16,
    funcFlags: u32,
    pUserData: ?*anyopaque,
    pNext: ?*FuncDef,
    xSFunc: ?*const fn (?*Context, c_int, ?[*]?*Mem) callconv(.c) void,
    xFinalize: ?*const fn (?*Context) callconv(.c) void,
    xValue: ?*const fn (?*Context) callconv(.c) void,
    xInverse: ?*const fn (?*Context, c_int, ?[*]?*Mem) callconv(.c) void,
    zName: ?[*:0]const u8,
    u: FuncOwner,
};

pub const FuncDefHash = extern struct {
    a: [function_hash_size]?*FuncDef,
};

pub const initial_builtin_functions = FuncDefHash{
    .a = [_]?*FuncDef{null} ** function_hash_size,
};
pub var builtin_functions = initial_builtin_functions;

pub const Savepoint = extern struct {
    zName: ?[*:0]u8,
    nDeferredCons: i64,
    nDeferredImmCons: i64,
    pNext: ?*Savepoint,
};

pub const savepoint_operation = struct {
    pub const begin: c_int = 0;
    pub const release: c_int = 1;
    pub const rollback: c_int = 2;
};

pub const Module = extern struct {
    pModule: ?*const PublicModule,
    zName: ?[*:0]const u8,
    nRefModule: c_int,
    pAux: ?*anyopaque,
    xDestroy: ?*const fn (?*anyopaque) callconv(.c) void,
    pEpoTab: ?*Table,
};

pub const DbClientData = extern struct {
    pNext: ?*DbClientData,
    pData: ?*anyopaque,
    xDestructor: ?*const fn (?*anyopaque) callconv(.c) void,
    zName: [0]u8,
};

pub fn dbClientDataSize(name_length: usize) usize {
    return @offsetOf(DbClientData, "zName") + name_length;
}

pub const function_hash_size: usize = 23;

pub fn functionHash(first: u8, length: usize) usize {
    return (first + length) % function_hash_size;
}

pub const function_flag = struct {
    pub const encoding_mask: u32 = 0x0003;
    pub const like: u32 = 0x0004;
    pub const case_sensitive: u32 = 0x0008;
    pub const ephemeral: u32 = 0x0010;
    pub const need_collation: u32 = 0x0020;
    pub const length: u32 = 0x0040;
    pub const type_of: u32 = 0x0080;
    pub const byte_length: u32 = 0x00c0;
    pub const count: u32 = 0x0100;
    pub const unlikely: u32 = 0x0400;
    pub const constant: u32 = 0x0800;
    pub const min_max: u32 = 0x1000;
    pub const slow_change: u32 = 0x2000;
    pub const test_only: u32 = 0x4000;
    pub const run_only: u32 = 0x8000;
    pub const window: u32 = 0x0001_0000;
    pub const internal: u32 = 0x0004_0000;
    pub const direct: u32 = 0x0008_0000;
    pub const unsafe: u32 = 0x0020_0000;
    pub const inline_: u32 = 0x0040_0000;
    pub const builtin: u32 = 0x0080_0000;
    pub const any_order: u32 = 0x0800_0000;
};

pub const inline_function = struct {
    pub const coalesce: u8 = 0;
    pub const implies_nonnull_row: u8 = 1;
    pub const expression_implies_expression: u8 = 2;
    pub const expression_compare: u8 = 3;
    pub const affinity: u8 = 4;
    pub const iif: u8 = 5;
    pub const sqlite_offset: u8 = 6;
    pub const unlikely: u8 = 99;
};

pub const VdbeFlags = packed struct(u16) {
    expired: u2,
    explain: u2,
    changeCntOn: bool,
    usesStmtJournal: bool,
    readOnly: bool,
    bIsReader: bool,
    haveEqpOps: bool,
    padding: u7 = 0,
};

pub const max_schema_retry: c_int = 50;
pub const statement_status_reprepare: usize = 5;
pub const conflict_abort: u8 = 2;
pub const connection_state_open: u8 = 118;
pub const connection_state_zombie: u8 = 167;
pub const function_flag_ephemeral: u32 = 0x00000010;
pub const op_flag_typeof_argument: u16 = 0x80;
pub const result_ok: c_int = 0;
pub const result_error: c_int = 1;
pub const result_no_memory: c_int = 7;
pub const result_interrupt: c_int = 9;
pub const result_constraint_foreign_key: c_int = 787;
pub const key_info_zero_size: usize = keyInfoSize(0);

pub const Vdbe = extern struct {
    db: ?*Sqlite3,
    ppVPrev: ?*?*Vdbe,
    pVNext: ?*Vdbe,
    pParse: ?*Parse,
    nVar: YnVar,
    nMem: c_int,
    nCursor: c_int,
    cacheCtr: u32,
    pc: c_int,
    rc: c_int,
    nChange: i64,
    iStatement: c_int,
    iCurrentTime: i64,
    nFkConstraint: i64,
    nStmtDefCons: i64,
    nStmtDefImmCons: i64,
    aMem: ?[*]Mem,
    apArg: ?[*]?*Mem,
    apCsr: ?[*]?*VdbeCursor,
    aVar: ?[*]Mem,
    aOp: ?[*]VdbeOp,
    nOp: c_int,
    nOpAlloc: c_int,
    aColName: ?[*]Mem,
    pResultRow: ?*Mem,
    zErrMsg: ?[*:0]u8,
    pVList: ?*VList,
    startTime: i64,
    nResColumn: u16,
    nResAlloc: u16,
    errorAction: u8,
    minWriteFileFormat: u8,
    prepFlags: u8,
    eVdbeState: u8,
    flags: VdbeFlags,
    btreeMask: DbMask,
    lockMask: DbMask,
    aCounter: [9]u32,
    zSql: ?[*:0]u8,
    pFree: ?*anyopaque,
    pFrame: ?*VdbeFrame,
    pDelFrame: ?*VdbeFrame,
    nFrame: c_int,
    expmask: u32,
    pProgram: ?*SubProgram,
    pAuxData: ?*AuxData,
};

pub const PreUpdateKeyInfoStorage = extern struct {
    keyinfoSpace: [key_info_zero_size]u8,
};

pub const PreUpdate = extern struct {
    v: ?*Vdbe,
    pCsr: ?*VdbeCursor,
    op: c_int,
    aRecord: ?[*]u8,
    pKeyinfo: ?*KeyInfo,
    pUnpacked: ?*UnpackedRecord,
    pNewUnpacked: ?*UnpackedRecord,
    iNewReg: c_int,
    iBlobWrite: c_int,
    iKey1: i64,
    iKey2: i64,
    oldipk: Mem,
    aNew: ?[*]Mem,
    pTab: ?*Table,
    pPk: ?*Index,
    apDflt: ?[*]?*Mem,
    uKey: PreUpdateKeyInfoStorage,
};

pub const MemValue = extern union {
    r: f64,
    i: i64,
    nZero: c_int,
    zPType: ?[*:0]const u8,
    pDef: ?*FuncDef,
};

pub const Mem = extern struct {
    u: MemValue,
    z: ?[*]u8,
    n: c_int,
    flags: u16,
    enc: u8,
    eSubtype: u8,
    db: ?*Sqlite3,
    szMalloc: c_int,
    uTemp: u32,
    zMalloc: ?[*]u8,
    xDel: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub const mem_cell_prefix_size: usize = @offsetOf(Mem, "db");

pub const mem_flag = struct {
    pub const undefined_: u16 = 0x0000;
    pub const null_: u16 = 0x0001;
    pub const string: u16 = 0x0002;
    pub const integer: u16 = 0x0004;
    pub const real: u16 = 0x0008;
    pub const blob: u16 = 0x0010;
    pub const integer_real: u16 = 0x0020;
    pub const affinity_mask: u16 = 0x003f;
    pub const from_bind: u16 = 0x0040;
    pub const cleared: u16 = 0x0100;
    pub const terminated: u16 = 0x0200;
    pub const zero: u16 = 0x0400;
    pub const subtype: u16 = 0x0800;
    pub const type_mask: u16 = 0x0dbf;
    pub const dynamic: u16 = 0x1000;
    pub const static: u16 = 0x2000;
    pub const ephemeral: u16 = 0x4000;
    pub const aggregate: u16 = 0x8000;
};

pub fn memIsDynamic(mem: *const Mem) bool {
    return mem.flags & (mem_flag.aggregate | mem_flag.dynamic) != 0;
}

pub fn memSetTypeFlag(mem: *Mem, flags: u16) void {
    mem.flags = (mem.flags & ~(mem_flag.type_mask | mem_flag.zero)) | flags;
}

pub fn memIsNullNoChange(mem: *const Mem) bool {
    return (mem.flags & mem_flag.type_mask) == (mem_flag.null_ | mem_flag.zero) and
        mem.n == 0 and mem.u.nZero == 0;
}

pub const CursorFlags = packed struct(u8) {
    isEphemeral: bool,
    useRandomRowid: bool,
    isOrdered: bool,
    noReuse: bool,
    colCache: bool,
    padding: u3 = 0,
};

pub const CursorBtree = extern union {
    pBtx: ?*Btree,
    aAltMap: ?[*]u32,
};

pub const CursorImplementation = extern union {
    pCursor: ?*BtCursor,
    pVCur: ?*VtabCursor,
    pSorter: ?*VdbeSorter,
};

pub const VdbeCursor = extern struct {
    eCurType: u8,
    iDb: i8,
    nullRow: u8,
    deferredMoveto: u8,
    isTable: u8,
    flags: CursorFlags,
    seekHit: u16,
    ub: CursorBtree,
    seqCount: i64,
    cacheStatus: u32,
    seekResult: c_int,
    pAltCursor: ?*VdbeCursor,
    uc: CursorImplementation,
    pKeyInfo: ?*KeyInfo,
    iHdrOffset: u32,
    pgnoRoot: u32,
    nField: i16,
    nHdrParsed: u16,
    movetoTarget: i64,
    aOffset: ?[*]u32,
    aRow: ?[*]const u8,
    payloadSize: u32,
    szRow: u32,
    pCache: ?*VdbeTxtBlbCache,
    aType: [0]u32,
};

pub const cursor_type = struct {
    pub const btree: u8 = 0;
    pub const sorter: u8 = 1;
    pub const virtual_table: u8 = 2;
    pub const pseudo: u8 = 3;
};

pub fn cursorSize(field_count: usize) usize {
    return std.mem.alignForward(usize, @offsetOf(VdbeCursor, "aType"), 8) + (field_count + 1) * @sizeOf(u64);
}

pub fn isNullCursor(cursor: *const VdbeCursor) bool {
    return cursor.eCurType == cursor_type.pseudo and cursor.nullRow != 0 and cursor.seekResult == 0;
}

pub const frame_mem_offset: usize = std.mem.alignForward(usize, @sizeOf(VdbeFrame), 8);

pub fn frameMem(frame: *VdbeFrame) [*]Mem {
    const bytes: [*]u8 = @ptrCast(frame);
    return @ptrCast(@alignCast(bytes + frame_mem_offset));
}

pub const VdbeTxtBlbCache = extern struct {
    pCValue: ?[*]u8,
    iOffset: i64,
    iCol: c_int,
    cacheStatus: u32,
    colCacheCtr: u32,
};

pub const AuxData = extern struct {
    iAuxOp: c_int,
    iAuxArg: c_int,
    pAux: ?*anyopaque,
    xDeleteAux: ?*const fn (?*anyopaque) callconv(.c) void,
    pNextAux: ?*AuxData,
};

pub const VdbeFrame = extern struct {
    v: ?*Vdbe,
    pParent: ?*VdbeFrame,
    aOp: ?[*]VdbeOp,
    aMem: ?[*]Mem,
    apCsr: ?[*]?*VdbeCursor,
    aOnce: ?[*]u8,
    token: ?*anyopaque,
    lastRowid: i64,
    pAuxData: ?*AuxData,
    nCursor: c_int,
    pc: c_int,
    nOp: c_int,
    nMem: c_int,
    nChildMem: c_int,
    nChildCsr: c_int,
    nChange: i64,
    nDbChange: i64,
};

pub const Context = extern struct {
    pOut: ?*Mem,
    pFunc: ?*FuncDef,
    pMem: ?*Mem,
    pVdbe: ?*Vdbe,
    iOp: c_int,
    isError: c_int,
    enc: u8,
    skipFlag: u8,
    argc: u16,
    argv: [0]?*Mem,
};

pub const ScanStatus = extern struct {
    addrExplain: c_int,
    aAddrRange: [6]c_int,
    addrLoop: c_int,
    addrVisit: c_int,
    iSelectID: c_int,
    nEst: i16,
    zName: ?[*:0]u8,
};

pub const DblquoteStr = extern struct {
    pNextStr: ?*DblquoteStr,
    z: [8]u8,
};

pub const ValueList = extern struct {
    pCsr: ?*BtCursor,
    pOut: ?*Mem,
};

pub const cache_stale: u32 = 0;
pub const frame_magic: u32 = 0x879f_b71e;

pub const vdbe_state = struct {
    pub const init: u8 = 0;
    pub const ready: u8 = 1;
    pub const run: u8 = 2;
    pub const halt: u8 = 3;
};

pub fn contextSize(argument_count: usize) usize {
    return @offsetOf(Context, "argv") + argument_count * @sizeOf(?*Mem);
}

pub const SubrtnSig = extern struct {
    selId: c_int,
    bComplete: u8,
    zAff: ?[*:0]u8,
    iTable: c_int,
    iAddr: c_int,
    regReturn: c_int,
};

pub const P4Union = extern union {
    i: c_int,
    p: ?*anyopaque,
    z: ?[*:0]u8,
    pI64: ?*i64,
    pReal: ?*f64,
    pFunc: ?*FuncDef,
    pCtx: ?*Context,
    pColl: ?*CollSeq,
    pMem: ?*Mem,
    pVtab: ?*VTable,
    pKeyInfo: ?*KeyInfo,
    ai: ?*u32,
    pProgram: ?*SubProgram,
    pTab: ?*Table,
    pSubrtnSig: ?*SubrtnSig,
    pIdx: ?*Index,
};

pub const VdbeOp = extern struct {
    opcode: canonical_opcode.Opcode,
    p4type: i8,
    p5: u16,
    p1: c_int,
    p2: c_int,
    p3: c_int,
    p4: P4Union,
};

pub const Op = VdbeOp;

pub const SubProgram = extern struct {
    aOp: ?[*]VdbeOp,
    nOp: c_int,
    nMem: c_int,
    nCsr: c_int,
    aOnce: ?[*]u8,
    token: ?*anyopaque,
    pNext: ?*SubProgram,
};

pub const VdbeOpList = extern struct {
    opcode: canonical_opcode.Opcode,
    p1: i8,
    p2: i8,
    p3: i8,
};

pub const RecordCompare = *const fn (c_int, *const anyopaque, *UnpackedRecord) callconv(.c) c_int;

pub const p4 = struct {
    pub const not_used: i8 = 0;
    pub const transient: i8 = 0;
    pub const static: i8 = -1;
    pub const collseq: i8 = -2;
    pub const int32: i8 = -3;
    pub const subprogram: i8 = -4;
    pub const table: i8 = -5;
    pub const index: i8 = -6;
    pub const free_if_le: i8 = -7;
    pub const dynamic: i8 = -7;
    pub const funcdef: i8 = -8;
    pub const keyinfo: i8 = -9;
    pub const expr: i8 = -10;
    pub const mem: i8 = -11;
    pub const vtab: i8 = -12;
    pub const real: i8 = -13;
    pub const int64: i8 = -14;
    pub const intarray: i8 = -15;
    pub const funcctx: i8 = -16;
    pub const table_ref: i8 = -17;
    pub const subroutine_signature: i8 = -18;
};

pub const halt_constraint = struct {
    pub const not_null: u16 = 1;
    pub const unique: u16 = 2;
    pub const check: u16 = 3;
    pub const foreign_key: u16 = 4;
};

pub const column_name = struct {
    pub const name: usize = 0;
    pub const declared_type: usize = 1;
    pub const database: usize = 2;
    pub const table: usize = 3;
    pub const column: usize = 4;
    pub const count: usize = 2;
};

pub const prepare_save_sql: u8 = 0x80;
pub const prepare_mask: u8 = 0x3f;

pub fn labelAddress(label: c_int) c_int {
    return ~label;
}

fn checkType(comptime T: type, comptime Facts: type) void {
    if (@sizeOf(T) != Facts.size) @compileError(@typeName(T) ++ " size differs from pinned C profile");
    if (@alignOf(T) != Facts.alignment) @compileError(@typeName(T) ++ " alignment differs from pinned C profile");
}

comptime {
    checkType(Vdbe, layout.Vdbe);
    checkType(VdbeCursor, layout.VdbeCursor);
    checkType(PcacheMethods2, layout.PcacheMethods2);
    checkType(Sqlite3Config, layout.Sqlite3Config);
    checkType(Sqlite3InitInfo, layout.Sqlite3InitInfo);
    checkType(Sqlite3Trace, layout.Sqlite3Trace);
    checkType(Sqlite3Interrupt, layout.Sqlite3Interrupt);
    checkType(Sqlite3, layout.Sqlite3);
    checkType(BusyHandler, layout.BusyHandler);
    checkType(BtLock, layout.BtLock);
    checkType(Btree, layout.Btree);
    checkType(Db, layout.Db);
    checkType(Schema, layout.Schema);
    checkType(LookasideSlot, layout.LookasideSlot);
    checkType(Lookaside, layout.Lookaside);
    checkType(CollSeq, layout.CollSeq);
    checkType(FuncDestructor, layout.FuncDestructor);
    checkType(FuncDef, layout.FuncDef);
    checkType(FuncDefHash, layout.FuncDefHash);
    checkType(Savepoint, layout.Savepoint);
    checkType(Module, layout.Module);
    checkType(DbClientData, layout.DbClientData);
    checkType(KeyInfo, layout.KeyInfo);
    checkType(UnpackedRecord, layout.UnpackedRecord);
    checkType(PreUpdate, layout.PreUpdate);
    checkType(MemValue, layout.MemValue);
    checkType(Mem, layout.Mem);
    checkType(VdbeTxtBlbCache, layout.VdbeTxtBlbCache);
    checkType(VdbeFrame, layout.VdbeFrame);
    checkType(AuxData, layout.AuxData);
    checkType(Context, layout.Context);
    checkType(ScanStatus, layout.ScanStatus);
    checkType(DblquoteStr, layout.DblquoteStr);
    checkType(ValueList, layout.ValueList);
    checkType(SubrtnSig, layout.SubrtnSig);
    checkType(P4Union, layout.P4Union);
    checkType(VdbeOp, layout.VdbeOp);
    checkType(SubProgram, layout.SubProgram);
    checkType(VdbeOpList, layout.VdbeOpList);

    for (std.meta.fields(Vdbe)) |field| {
        if (std.mem.eql(u8, field.name, "flags")) continue;
        if (@offsetOf(Vdbe, field.name) != @field(layout.Vdbe, field.name ++ "_offset"))
            @compileError("Vdbe field offset differs from pinned C profile");
    }
    if (@offsetOf(Vdbe, "flags") != layout.constants.VDBE_EXPIRED_OFFSET)
        @compileError("Vdbe bitfield offset differs from pinned C profile");
    const vdbe_flag_masks = [_]u16{
        @bitCast(VdbeFlags{ .expired = 3, .explain = 0, .changeCntOn = false, .usesStmtJournal = false, .readOnly = false, .bIsReader = false, .haveEqpOps = false }),
        @bitCast(VdbeFlags{ .expired = 0, .explain = 3, .changeCntOn = false, .usesStmtJournal = false, .readOnly = false, .bIsReader = false, .haveEqpOps = false }),
        @bitCast(VdbeFlags{ .expired = 0, .explain = 0, .changeCntOn = true, .usesStmtJournal = false, .readOnly = false, .bIsReader = false, .haveEqpOps = false }),
        @bitCast(VdbeFlags{ .expired = 0, .explain = 0, .changeCntOn = false, .usesStmtJournal = true, .readOnly = false, .bIsReader = false, .haveEqpOps = false }),
        @bitCast(VdbeFlags{ .expired = 0, .explain = 0, .changeCntOn = false, .usesStmtJournal = false, .readOnly = true, .bIsReader = false, .haveEqpOps = false }),
        @bitCast(VdbeFlags{ .expired = 0, .explain = 0, .changeCntOn = false, .usesStmtJournal = false, .readOnly = false, .bIsReader = true, .haveEqpOps = false }),
        @bitCast(VdbeFlags{ .expired = 0, .explain = 0, .changeCntOn = false, .usesStmtJournal = false, .readOnly = false, .bIsReader = false, .haveEqpOps = true }),
    };
    const vdbe_flag_base = layout.constants.VDBE_EXPIRED_OFFSET;
    const oracle_vdbe_flag_masks = [_]u16{
        @intCast(layout.constants.VDBE_EXPIRED_MASK << @intCast(8 * (layout.constants.VDBE_EXPIRED_OFFSET - vdbe_flag_base))),
        @intCast(layout.constants.VDBE_EXPLAIN_MASK << @intCast(8 * (layout.constants.VDBE_EXPLAIN_OFFSET - vdbe_flag_base))),
        @intCast(layout.constants.VDBE_CHANGECNTON_MASK << @intCast(8 * (layout.constants.VDBE_CHANGECNTON_OFFSET - vdbe_flag_base))),
        @intCast(layout.constants.VDBE_USESSTMTJOURNAL_MASK << @intCast(8 * (layout.constants.VDBE_USESSTMTJOURNAL_OFFSET - vdbe_flag_base))),
        @intCast(layout.constants.VDBE_READONLY_MASK << @intCast(8 * (layout.constants.VDBE_READONLY_OFFSET - vdbe_flag_base))),
        @intCast(layout.constants.VDBE_BISREADER_MASK << @intCast(8 * (layout.constants.VDBE_BISREADER_OFFSET - vdbe_flag_base))),
        @intCast(layout.constants.VDBE_HAVEEQPOPS_MASK << @intCast(8 * (layout.constants.VDBE_HAVEEQPOPS_OFFSET - vdbe_flag_base))),
    };
    if (!std.mem.eql(u16, &vdbe_flag_masks, &oracle_vdbe_flag_masks))
        @compileError("Vdbe bit masks differ from pinned C profile");

    for (std.meta.fields(PcacheMethods2)) |field| {
        if (@offsetOf(PcacheMethods2, field.name) != @field(layout.PcacheMethods2, field.name ++ "_offset"))
            @compileError("sqlite3_pcache_methods2 field offset differs from pinned C profile");
    }
    for (std.meta.fields(Sqlite3Config)) |field| {
        if (@offsetOf(Sqlite3Config, field.name) != @field(layout.Sqlite3Config, field.name ++ "_offset"))
            @compileError("Sqlite3Config field offset differs from pinned C profile");
    }
    const initial = config_types.initial_config;
    const initial_values = [_]i64{
        initial.bMemstat,
        initial.bCoreMutex,
        initial.bFullMutex,
        initial.bOpenUri,
        initial.bUseCis,
        initial.bSmallMalloc,
        initial.bExtraSchemaChecks,
        initial.mxStrlen,
        initial.neverCorrupt,
        initial.szLookaside,
        initial.nLookaside,
        initial.nStmtSpill,
        initial.nHeap,
        initial.mnReq,
        initial.mxReq,
        initial.szMmap,
        initial.mxMmap,
        initial.szPage,
        initial.nPage,
        initial.mxParserStack,
        initial.sharedCacheEnabled,
        initial.szPma,
        initial.mxMemdbSize,
        initial.bLocaltimeFault,
        initial.iOnceResetThreshold,
        initial.szSorterRef,
        initial.iPrngSeed,
        @intFromBool(initial.m.xMalloc == null and initial.m.xFree == null and
            initial.m.xRealloc == null and initial.m.xSize == null and
            initial.m.xRoundup == null and initial.m.xInit == null and
            initial.m.xShutdown == null and initial.m.pAppData == null and
            initial.mutex.xMutexInit == null and initial.mutex.xMutexEnd == null and
            initial.mutex.xMutexAlloc == null and initial.mutex.xMutexFree == null and
            initial.mutex.xMutexEnter == null and initial.mutex.xMutexTry == null and
            initial.mutex.xMutexLeave == null and initial.mutex.xMutexHeld == null and
            initial.mutex.xMutexNotheld == null and initial.pcache2.iVersion == 0 and
            initial.pcache2.pArg == null and initial.pcache2.xInit == null and
            initial.pcache2.xShutdown == null and initial.pcache2.xCreate == null and
            initial.pcache2.xCachesize == null and initial.pcache2.xPagecount == null and
            initial.pcache2.xFetch == null and initial.pcache2.xUnpin == null and
            initial.pcache2.xRekey == null and initial.pcache2.xTruncate == null and
            initial.pcache2.xDestroy == null and initial.pcache2.xShrink == null and
            initial.pHeap == null and initial.pPage == null),
        @intFromBool(initial.isInit == 0 and initial.inProgress == 0 and
            initial.isMutexInit == 0 and initial.isMallocInit == 0 and
            initial.isPCacheInit == 0 and initial.nRefInitMutex == 0 and
            initial.pInitMutex == null and initial.xLog == null and
            initial.pLogArg == null and initial.xTestCallback == null and
            initial.xAltLocaltime == null),
    };
    const oracle_initial_values = [_]i64{
        layout.constants.CONFIG_bMemstat,
        layout.constants.CONFIG_bCoreMutex,
        layout.constants.CONFIG_bFullMutex,
        layout.constants.CONFIG_bOpenUri,
        layout.constants.CONFIG_bUseCis,
        layout.constants.CONFIG_bSmallMalloc,
        layout.constants.CONFIG_bExtraSchemaChecks,
        layout.constants.CONFIG_mxStrlen,
        layout.constants.CONFIG_neverCorrupt,
        layout.constants.CONFIG_szLookaside,
        layout.constants.CONFIG_nLookaside,
        layout.constants.CONFIG_nStmtSpill,
        layout.constants.CONFIG_nHeap,
        layout.constants.CONFIG_mnReq,
        layout.constants.CONFIG_mxReq,
        layout.constants.CONFIG_szMmap,
        layout.constants.CONFIG_mxMmap,
        layout.constants.CONFIG_szPage,
        layout.constants.CONFIG_nPage,
        layout.constants.CONFIG_mxParserStack,
        layout.constants.CONFIG_sharedCacheEnabled,
        layout.constants.CONFIG_szPma,
        layout.constants.CONFIG_mxMemdbSize,
        layout.constants.CONFIG_bLocaltimeFault,
        layout.constants.CONFIG_iOnceResetThreshold,
        layout.constants.CONFIG_szSorterRef,
        layout.constants.CONFIG_iPrngSeed,
        layout.constants.CONFIG_ZERO_TABLES,
        layout.constants.CONFIG_ZERO_TAIL,
    };
    if (!std.mem.eql(i64, &initial_values, &oracle_initial_values))
        @compileError("Sqlite3Config initializer differs from pinned C profile");
    for (std.meta.fields(Sqlite3InitInfo)) |field| {
        if (std.mem.eql(u8, field.name, "flags")) continue;
        if (@offsetOf(Sqlite3InitInfo, field.name) != @field(layout.Sqlite3InitInfo, field.name ++ "_offset"))
            @compileError("sqlite3InitInfo field offset differs from pinned C profile");
    }
    if (@offsetOf(Sqlite3InitInfo, "flags") != layout.constants.INIT_ORPHAN_TRIGGER_OFFSET)
        @compileError("sqlite3InitInfo bitfield offset differs from pinned C profile");
    const init_flag_masks = [_]u8{
        @truncate(@as(u16, @bitCast(Sqlite3InitInfoFlags{ .orphanTrigger = true, .imposterTable = 0, .reopenMemdb = false }))),
        @truncate(@as(u16, @bitCast(Sqlite3InitInfoFlags{ .orphanTrigger = false, .imposterTable = 3, .reopenMemdb = false }))),
        @truncate(@as(u16, @bitCast(Sqlite3InitInfoFlags{ .orphanTrigger = false, .imposterTable = 0, .reopenMemdb = true }))),
    };
    const oracle_init_flag_masks = [_]u8{
        @intCast(layout.constants.INIT_ORPHAN_TRIGGER_MASK),
        @intCast(layout.constants.INIT_IMPOSTER_TABLE_MASK),
        @intCast(layout.constants.INIT_REOPEN_MEMDB_MASK),
    };
    if (!std.mem.eql(u8, &init_flag_masks, &oracle_init_flag_masks))
        @compileError("sqlite3InitInfo bit masks differ from pinned C profile");
    for (std.meta.fields(Sqlite3Trace)) |field| {
        if (@field(layout.Sqlite3Trace, field.name ++ "_offset") != 0)
            @compileError("sqlite3 trace union offset differs from pinned C profile");
    }
    for (std.meta.fields(Sqlite3Interrupt)) |field| {
        if (@field(layout.Sqlite3Interrupt, field.name ++ "_offset") != 0)
            @compileError("sqlite3 interrupt union offset differs from pinned C profile");
    }
    for (std.meta.fields(Sqlite3)) |field| {
        if (@offsetOf(Sqlite3, field.name) != @field(layout.Sqlite3, field.name ++ "_offset"))
            @compileError("sqlite3 field offset differs from pinned C profile");
    }
    for (std.meta.fields(BusyHandler)) |field| {
        if (@offsetOf(BusyHandler, field.name) != @field(layout.BusyHandler, field.name ++ "_offset"))
            @compileError("BusyHandler field offset differs from pinned C profile");
    }
    for (std.meta.fields(BtLock)) |field| {
        if (@offsetOf(BtLock, field.name) != @field(layout.BtLock, field.name ++ "_offset"))
            @compileError("BtLock field offset differs from pinned C profile");
    }
    for (std.meta.fields(Btree)) |field| {
        if (@offsetOf(Btree, field.name) != @field(layout.Btree, field.name ++ "_offset"))
            @compileError("Btree field offset differs from pinned C profile");
    }
    for (std.meta.fields(Db)) |field| {
        if (@offsetOf(Db, field.name) != @field(layout.Db, field.name ++ "_offset"))
            @compileError("Db field offset differs from pinned C profile");
    }
    for (std.meta.fields(LookasideSlot)) |field| {
        if (@offsetOf(LookasideSlot, field.name) != @field(layout.LookasideSlot, field.name ++ "_offset"))
            @compileError("LookasideSlot field offset differs from pinned C profile");
    }
    for (std.meta.fields(Lookaside)) |field| {
        if (@offsetOf(Lookaside, field.name) != @field(layout.Lookaside, field.name ++ "_offset"))
            @compileError("Lookaside field offset differs from pinned C profile");
    }
    for (std.meta.fields(CollSeq)) |field| {
        if (@offsetOf(CollSeq, field.name) != @field(layout.CollSeq, field.name ++ "_offset"))
            @compileError("CollSeq field offset differs from pinned C profile");
    }
    for (std.meta.fields(FuncDestructor)) |field| {
        if (@offsetOf(FuncDestructor, field.name) != @field(layout.FuncDestructor, field.name ++ "_offset"))
            @compileError("FuncDestructor field offset differs from pinned C profile");
    }
    for (std.meta.fields(FuncDef)) |field| {
        if (@offsetOf(FuncDef, field.name) != @field(layout.FuncDef, field.name ++ "_offset"))
            @compileError("FuncDef field offset differs from pinned C profile");
    }
    for (std.meta.fields(FuncDefHash)) |field| {
        if (@offsetOf(FuncDefHash, field.name) != @field(layout.FuncDefHash, field.name ++ "_offset"))
            @compileError("FuncDefHash field offset differs from pinned C profile");
    }
    for (std.meta.fields(Savepoint)) |field| {
        if (@offsetOf(Savepoint, field.name) != @field(layout.Savepoint, field.name ++ "_offset"))
            @compileError("Savepoint field offset differs from pinned C profile");
    }
    for (std.meta.fields(Module)) |field| {
        if (@offsetOf(Module, field.name) != @field(layout.Module, field.name ++ "_offset"))
            @compileError("Module field offset differs from pinned C profile");
    }
    for (std.meta.fields(DbClientData)) |field| {
        if (@offsetOf(DbClientData, field.name) != @field(layout.DbClientData, field.name ++ "_offset"))
            @compileError("DbClientData field offset differs from pinned C profile");
    }
    for (std.meta.fields(KeyInfo)) |field| {
        if (@offsetOf(KeyInfo, field.name) != @field(layout.KeyInfo, field.name ++ "_offset"))
            @compileError("KeyInfo field offset differs from pinned C profile");
    }
    for (std.meta.fields(UnpackedRecord)) |field| {
        if (@offsetOf(UnpackedRecord, field.name) != @field(layout.UnpackedRecord, field.name ++ "_offset"))
            @compileError("UnpackedRecord field offset differs from pinned C profile");
    }
    for (std.meta.fields(PreUpdate)) |field| {
        if (@offsetOf(PreUpdate, field.name) != @field(layout.PreUpdate, field.name ++ "_offset"))
            @compileError("PreUpdate field offset differs from pinned C profile");
    }
    if (@offsetOf(PreUpdate, "uKey") + @offsetOf(PreUpdateKeyInfoStorage, "keyinfoSpace") != layout.PreUpdate.keyinfoSpace_offset or
        @sizeOf(PreUpdateKeyInfoStorage) != layout.PreUpdate.keyinfoSpace_size)
        @compileError("PreUpdate key-info storage differs from pinned C profile");

    for (std.meta.fields(VdbeCursor)) |field| {
        if (std.mem.eql(u8, field.name, "flags")) continue;
        if (@offsetOf(VdbeCursor, field.name) != @field(layout.VdbeCursor, field.name ++ "_offset"))
            @compileError("VdbeCursor field offset differs from pinned C profile");
    }
    if (@offsetOf(VdbeCursor, "flags") != layout.constants.CURSOR_ISEPHEMERAL_OFFSET)
        @compileError("VdbeCursor bitfield offset differs from pinned C profile");
    const cursor_flag_masks = [_]u8{
        @bitCast(CursorFlags{ .isEphemeral = true, .useRandomRowid = false, .isOrdered = false, .noReuse = false, .colCache = false }),
        @bitCast(CursorFlags{ .isEphemeral = false, .useRandomRowid = true, .isOrdered = false, .noReuse = false, .colCache = false }),
        @bitCast(CursorFlags{ .isEphemeral = false, .useRandomRowid = false, .isOrdered = true, .noReuse = false, .colCache = false }),
        @bitCast(CursorFlags{ .isEphemeral = false, .useRandomRowid = false, .isOrdered = false, .noReuse = true, .colCache = false }),
        @bitCast(CursorFlags{ .isEphemeral = false, .useRandomRowid = false, .isOrdered = false, .noReuse = false, .colCache = true }),
    };
    const oracle_cursor_flag_masks = [_]u8{
        layout.constants.CURSOR_ISEPHEMERAL_MASK,
        layout.constants.CURSOR_USERANDOMROWID_MASK,
        layout.constants.CURSOR_ISORDERED_MASK,
        layout.constants.CURSOR_NOREUSE_MASK,
        layout.constants.CURSOR_COLCACHE_MASK,
    };
    if (!std.mem.eql(u8, &cursor_flag_masks, &oracle_cursor_flag_masks))
        @compileError("VdbeCursor bit masks differ from pinned C profile");
    for (std.meta.fields(Mem)) |field| {
        if (@offsetOf(Mem, field.name) != @field(layout.Mem, field.name ++ "_offset"))
            @compileError("Mem field offset differs from pinned C profile");
    }
    for (std.meta.fields(VdbeTxtBlbCache)) |field| {
        if (@offsetOf(VdbeTxtBlbCache, field.name) != @field(layout.VdbeTxtBlbCache, field.name ++ "_offset"))
            @compileError("VdbeTxtBlbCache field offset differs from pinned C profile");
    }
    for (std.meta.fields(VdbeFrame)) |field| {
        if (@offsetOf(VdbeFrame, field.name) != @field(layout.VdbeFrame, field.name ++ "_offset"))
            @compileError("VdbeFrame field offset differs from pinned C profile");
    }
    for (std.meta.fields(AuxData)) |field| {
        if (@offsetOf(AuxData, field.name) != @field(layout.AuxData, field.name ++ "_offset"))
            @compileError("AuxData field offset differs from pinned C profile");
    }
    for (std.meta.fields(Context)) |field| {
        if (@offsetOf(Context, field.name) != @field(layout.Context, field.name ++ "_offset"))
            @compileError("Context field offset differs from pinned C profile");
    }
    for (std.meta.fields(ScanStatus)) |field| {
        if (@offsetOf(ScanStatus, field.name) != @field(layout.ScanStatus, field.name ++ "_offset"))
            @compileError("ScanStatus field offset differs from pinned C profile");
    }
    for (std.meta.fields(DblquoteStr)) |field| {
        if (@offsetOf(DblquoteStr, field.name) != @field(layout.DblquoteStr, field.name ++ "_offset"))
            @compileError("DblquoteStr field offset differs from pinned C profile");
    }
    for (std.meta.fields(ValueList)) |field| {
        if (@offsetOf(ValueList, field.name) != @field(layout.ValueList, field.name ++ "_offset"))
            @compileError("ValueList field offset differs from pinned C profile");
    }
    for (std.meta.fields(SubrtnSig)) |field| {
        if (@offsetOf(SubrtnSig, field.name) != @field(layout.SubrtnSig, field.name ++ "_offset"))
            @compileError("SubrtnSig field offset differs from pinned C profile");
    }
    for (std.meta.fields(VdbeOp)) |field| {
        if (@offsetOf(VdbeOp, field.name) != @field(layout.VdbeOp, field.name ++ "_offset"))
            @compileError("VdbeOp field offset differs from pinned C profile");
    }
    for (std.meta.fields(SubProgram)) |field| {
        if (@offsetOf(SubProgram, field.name) != @field(layout.SubProgram, field.name ++ "_offset"))
            @compileError("SubProgram field offset differs from pinned C profile");
    }
    for (std.meta.fields(VdbeOpList)) |field| {
        if (@offsetOf(VdbeOpList, field.name) != @field(layout.VdbeOpList, field.name ++ "_offset"))
            @compileError("VdbeOpList field offset differs from pinned C profile");
    }

    const function_values = [_]i64{
        function_hash_size,
        functionHash('a', 5),
        @intFromBool(for (initial_builtin_functions.a) |entry| {
            if (entry != null) break false;
        } else true),
        savepoint_operation.begin,
        savepoint_operation.release,
        savepoint_operation.rollback,
        dbClientDataSize(0),
        dbClientDataSize(1),
        dbClientDataSize(17),
        function_flag.encoding_mask,
        function_flag.like,
        function_flag.case_sensitive,
        function_flag.ephemeral,
        function_flag.need_collation,
        function_flag.length,
        function_flag.type_of,
        function_flag.byte_length,
        function_flag.count,
        function_flag.unlikely,
        function_flag.constant,
        function_flag.min_max,
        function_flag.slow_change,
        function_flag.test_only,
        function_flag.run_only,
        function_flag.window,
        function_flag.internal,
        function_flag.direct,
        function_flag.unsafe,
        function_flag.inline_,
        function_flag.builtin,
        function_flag.any_order,
        inline_function.coalesce,
        inline_function.implies_nonnull_row,
        inline_function.expression_implies_expression,
        inline_function.expression_compare,
        inline_function.affinity,
        inline_function.iif,
        inline_function.sqlite_offset,
        inline_function.unlikely,
    };
    const oracle_function_values = [_]i64{
        layout.constants.SQLITE_FUNC_HASH_SZ,
        layout.constants.SQLITE_FUNC_HASH_a5,
        layout.constants.BUILTIN_FUNCTIONS_EMPTY,
        layout.constants.SAVEPOINT_BEGIN,
        layout.constants.SAVEPOINT_RELEASE,
        layout.constants.SAVEPOINT_ROLLBACK,
        layout.constants.SZ_DBCLIENTDATA_0,
        layout.constants.SZ_DBCLIENTDATA_1,
        layout.constants.SZ_DBCLIENTDATA_17,
        layout.constants.SQLITE_FUNC_ENCMASK,
        layout.constants.SQLITE_FUNC_LIKE,
        layout.constants.SQLITE_FUNC_CASE,
        layout.constants.SQLITE_FUNC_EPHEM,
        layout.constants.SQLITE_FUNC_NEEDCOLL,
        layout.constants.SQLITE_FUNC_LENGTH,
        layout.constants.SQLITE_FUNC_TYPEOF,
        layout.constants.SQLITE_FUNC_BYTELEN,
        layout.constants.SQLITE_FUNC_COUNT,
        layout.constants.SQLITE_FUNC_UNLIKELY,
        layout.constants.SQLITE_FUNC_CONSTANT,
        layout.constants.SQLITE_FUNC_MINMAX,
        layout.constants.SQLITE_FUNC_SLOCHNG,
        layout.constants.SQLITE_FUNC_TEST,
        layout.constants.SQLITE_FUNC_RUNONLY,
        layout.constants.SQLITE_FUNC_WINDOW,
        layout.constants.SQLITE_FUNC_INTERNAL,
        layout.constants.SQLITE_FUNC_DIRECT,
        layout.constants.SQLITE_FUNC_UNSAFE,
        layout.constants.SQLITE_FUNC_INLINE,
        layout.constants.SQLITE_FUNC_BUILTIN,
        layout.constants.SQLITE_FUNC_ANYORDER,
        layout.constants.INLINEFUNC_coalesce,
        layout.constants.INLINEFUNC_implies_nonnull_row,
        layout.constants.INLINEFUNC_expr_implies_expr,
        layout.constants.INLINEFUNC_expr_compare,
        layout.constants.INLINEFUNC_affinity,
        layout.constants.INLINEFUNC_iif,
        layout.constants.INLINEFUNC_sqlite_offset,
        layout.constants.INLINEFUNC_unlikely,
    };
    if (!std.mem.eql(i64, &function_values, &oracle_function_values))
        @compileError("FuncDef constants differ from pinned C profile");

    var lookaside = Lookaside{
        .bDisable = 0,
        .sz = 1200,
        .szTrue = 1200,
        .bMalloced = 0,
        .nSlot = 0,
        .anStat = .{ 0, 0, 0 },
        .pInit = null,
        .pFree = null,
        .pSmallInit = null,
        .pSmallFree = null,
        .pMiddle = null,
        .pStart = null,
        .pEnd = null,
        .pTrueEnd = null,
    };
    disableLookaside(&lookaside);
    const disabled_count = lookaside.bDisable;
    const disabled_size = lookaside.sz;
    disableLookaside(&lookaside);
    enableLookaside(&lookaside);
    const nested_count = lookaside.bDisable;
    const nested_size = lookaside.sz;
    enableLookaside(&lookaside);
    const lookaside_values = [_]i64{
        lookaside_small,
        disabled_count,
        disabled_size,
        nested_count,
        nested_size,
        lookaside.bDisable,
        lookaside.sz,
    };
    const oracle_lookaside_values = [_]i64{
        layout.constants.LOOKASIDE_SMALL,
        layout.constants.LOOKASIDE_DISABLED_COUNT,
        layout.constants.LOOKASIDE_DISABLED_SIZE,
        layout.constants.LOOKASIDE_NESTED_COUNT,
        layout.constants.LOOKASIDE_NESTED_SIZE,
        layout.constants.LOOKASIDE_ENABLED_COUNT,
        layout.constants.LOOKASIDE_ENABLED_SIZE,
    };
    if (!std.mem.eql(i64, &lookaside_values, &oracle_lookaside_values))
        @compileError("Lookaside helper semantics differ from pinned C profile");

    const connection_values = [_]i64{
        limit_count,
        max_database_count,
        trace_flag.legacy,
        trace_flag.profile,
        trace_flag.nonlegacy_mask,
        connection_flag.write_schema,
        connection_flag.legacy_file_format,
        connection_flag.full_column_names,
        connection_flag.full_fsync,
        connection_flag.checkpoint_full_fsync,
        connection_flag.cache_spill,
        connection_flag.short_column_names,
        connection_flag.trusted_schema,
        connection_flag.null_callback,
        connection_flag.ignore_checks,
        connection_flag.statement_scan_status,
        connection_flag.no_checkpoint_on_close,
        connection_flag.reverse_order,
        connection_flag.recursive_triggers,
        connection_flag.foreign_keys,
        connection_flag.automatic_index,
        connection_flag.load_extension,
        connection_flag.load_extension_function,
        connection_flag.enable_trigger,
        connection_flag.defer_foreign_keys,
        connection_flag.query_only,
        connection_flag.cell_size_check,
        connection_flag.fts3_tokenizer,
        connection_flag.enable_qpsg,
        connection_flag.trigger_eqp,
        connection_flag.reset_database,
        connection_flag.legacy_alter,
        connection_flag.no_schema_error,
        connection_flag.defensive,
        connection_flag.dqs_ddl,
        connection_flag.dqs_dml,
        connection_flag.enable_view,
        connection_flag.count_rows,
        connection_flag.corrupt_read_only,
        connection_flag.read_uncommitted,
        connection_flag.foreign_key_no_action,
        connection_flag.attach_create,
        connection_flag.attach_write,
        connection_flag.comments,
        database_flag.schema_change,
        database_flag.prefer_builtin,
        database_flag.vacuum,
        database_flag.vacuum_into,
        database_flag.schema_known_ok,
        database_flag.internal_function,
        database_flag.encoding_fixed,
        optimization.query_flattener,
        optimization.window_function,
        optimization.group_by_order,
        optimization.factor_out_constants,
        optimization.distinct,
        optimization.covering_index_scan,
        optimization.order_by_index_join,
        optimization.transitive,
        optimization.omit_noop_join,
        optimization.count_of_view,
        optimization.cursor_hints,
        optimization.stat4,
        optimization.push_down,
        optimization.simplify_join,
        optimization.skip_scan,
        optimization.propagate_constants,
        optimization.min_max,
        optimization.seek_scan,
        optimization.omit_order_by,
        optimization.bloom_filter,
        optimization.bloom_pull_down,
        optimization.balanced_merge,
        optimization.release_register,
        optimization.flatten_union_all,
        optimization.indexed_expression,
        optimization.coroutines,
        optimization.null_unused_columns,
        optimization.one_pass,
        optimization.order_by_subquery,
        optimization.star_query,
        optimization.exists_to_join,
        optimization.all,
        connection_state.open,
        connection_state.closed,
        connection_state.sick,
        connection_state.busy,
        connection_state.error_,
        connection_state.zombie,
        highBits(0x40),
    };
    const connection_oracle = [_]i64{
        layout.constants.SQLITE_N_LIMIT,
        layout.constants.SQLITE_MAX_DB,
        layout.constants.SQLITE_TRACE_LEGACY,
        layout.constants.SQLITE_TRACE_XPROFILE,
        layout.constants.SQLITE_TRACE_NONLEGACY_MASK,
        layout.constants.SQLITE_WriteSchema,
        layout.constants.SQLITE_LegacyFileFmt,
        layout.constants.SQLITE_FullColNames,
        layout.constants.SQLITE_FullFSync,
        layout.constants.SQLITE_CkptFullFSync,
        layout.constants.SQLITE_CacheSpill,
        layout.constants.SQLITE_ShortColNames,
        layout.constants.SQLITE_TrustedSchema,
        layout.constants.SQLITE_NullCallback,
        layout.constants.SQLITE_IgnoreChecks,
        layout.constants.SQLITE_StmtScanStatus,
        layout.constants.SQLITE_NoCkptOnClose,
        layout.constants.SQLITE_ReverseOrder,
        layout.constants.SQLITE_RecTriggers,
        layout.constants.SQLITE_ForeignKeys,
        layout.constants.SQLITE_AutoIndex,
        layout.constants.SQLITE_LoadExtension,
        layout.constants.SQLITE_LoadExtFunc,
        layout.constants.SQLITE_EnableTrigger,
        layout.constants.SQLITE_DeferFKs,
        layout.constants.SQLITE_QueryOnly,
        layout.constants.SQLITE_CellSizeCk,
        layout.constants.SQLITE_Fts3Tokenizer,
        layout.constants.SQLITE_EnableQPSG,
        layout.constants.SQLITE_TriggerEQP,
        layout.constants.SQLITE_ResetDatabase,
        layout.constants.SQLITE_LegacyAlter,
        layout.constants.SQLITE_NoSchemaError,
        layout.constants.SQLITE_Defensive,
        layout.constants.SQLITE_DqsDDL,
        layout.constants.SQLITE_DqsDML,
        layout.constants.SQLITE_EnableView,
        layout.constants.SQLITE_CountRows,
        layout.constants.SQLITE_CorruptRdOnly,
        layout.constants.SQLITE_ReadUncommit,
        layout.constants.SQLITE_FkNoAction,
        layout.constants.SQLITE_AttachCreate,
        layout.constants.SQLITE_AttachWrite,
        layout.constants.SQLITE_Comments,
        layout.constants.DBFLAG_SchemaChange,
        layout.constants.DBFLAG_PreferBuiltin,
        layout.constants.DBFLAG_Vacuum,
        layout.constants.DBFLAG_VacuumInto,
        layout.constants.DBFLAG_SchemaKnownOk,
        layout.constants.DBFLAG_InternalFunc,
        layout.constants.DBFLAG_EncodingFixed,
        layout.constants.SQLITE_QueryFlattener,
        layout.constants.SQLITE_WindowFunc,
        layout.constants.SQLITE_GroupByOrder,
        layout.constants.SQLITE_FactorOutConst,
        layout.constants.SQLITE_DistinctOpt,
        layout.constants.SQLITE_CoverIdxScan,
        layout.constants.SQLITE_OrderByIdxJoin,
        layout.constants.SQLITE_Transitive,
        layout.constants.SQLITE_OmitNoopJoin,
        layout.constants.SQLITE_CountOfView,
        layout.constants.SQLITE_CursorHints,
        layout.constants.SQLITE_Stat4,
        layout.constants.SQLITE_PushDown,
        layout.constants.SQLITE_SimplifyJoin,
        layout.constants.SQLITE_SkipScan,
        layout.constants.SQLITE_PropagateConst,
        layout.constants.SQLITE_MinMaxOpt,
        layout.constants.SQLITE_SeekScan,
        layout.constants.SQLITE_OmitOrderBy,
        layout.constants.SQLITE_BloomFilter,
        layout.constants.SQLITE_BloomPulldown,
        layout.constants.SQLITE_BalancedMerge,
        layout.constants.SQLITE_ReleaseReg,
        layout.constants.SQLITE_FlttnUnionAll,
        layout.constants.SQLITE_IndexedExpr,
        layout.constants.SQLITE_Coroutines,
        layout.constants.SQLITE_NullUnusedCols,
        layout.constants.SQLITE_OnePass,
        layout.constants.SQLITE_OrderBySubq,
        layout.constants.SQLITE_StarQuery,
        layout.constants.SQLITE_ExistsToJoin,
        layout.constants.SQLITE_AllOpts,
        layout.constants.SQLITE_STATE_OPEN,
        layout.constants.SQLITE_STATE_CLOSED,
        layout.constants.SQLITE_STATE_SICK,
        layout.constants.SQLITE_STATE_BUSY,
        layout.constants.SQLITE_STATE_ERROR,
        layout.constants.SQLITE_STATE_ZOMBIE,
        layout.constants.HI_40,
    };
    if (!std.mem.eql(i64, &connection_values, &connection_oracle))
        @compileError("sqlite3 connection constants differ from pinned C profile");

    var connection: Sqlite3 = undefined;
    connection.dbOptFlags = optimization.query_flattener;
    if (!optimizationDisabled(&connection, optimization.query_flattener) or
        optimizationEnabled(&connection, optimization.query_flattener) or
        optimizationDisabled(&connection, optimization.window_function) or
        !optimizationEnabled(&connection, optimization.window_function))
        @compileError("sqlite3 optimization predicates differ from pinned source");

    const ported = [_]i64{
        schema_flag.loaded,
        schema_flag.unreset_views,
        schema_flag.reset_wanted,
        sort_order.ascending,
        sort_order.descending,
        sort_order.undefined_,
        max_schema_retry,
        @intFromBool(display_p4),
        cursor_type.btree,
        cursor_type.sorter,
        cursor_type.virtual_table,
        cursor_type.pseudo,
        cursorSize(0),
        cursorSize(1),
        cursorSize(5),
        keyInfoSize(0),
        keyInfoSize(5),
        key_info_order.descending,
        key_info_order.big_null,
        frame_mem_offset,
        cache_stale,
        frame_magic,
        contextSize(0),
        vdbe_state.init,
        vdbe_state.ready,
        vdbe_state.run,
        vdbe_state.halt,
        mem_flag.undefined_,
        mem_flag.null_,
        mem_flag.string,
        mem_flag.integer,
        mem_flag.real,
        mem_flag.blob,
        mem_flag.integer_real,
        mem_flag.affinity_mask,
        mem_flag.from_bind,
        mem_flag.cleared,
        mem_flag.terminated,
        mem_flag.zero,
        mem_flag.subtype,
        mem_flag.type_mask,
        mem_flag.dynamic,
        mem_flag.static,
        mem_flag.ephemeral,
        mem_flag.aggregate,
        mem_cell_prefix_size,
        p4.not_used,
        p4.transient,
        p4.static,
        p4.collseq,
        p4.int32,
        p4.subprogram,
        p4.table,
        p4.index,
        p4.free_if_le,
        p4.dynamic,
        p4.funcdef,
        p4.keyinfo,
        p4.expr,
        p4.mem,
        p4.vtab,
        p4.real,
        p4.int64,
        p4.intarray,
        p4.funcctx,
        p4.table_ref,
        p4.subroutine_signature,
        halt_constraint.not_null,
        halt_constraint.unique,
        halt_constraint.check,
        halt_constraint.foreign_key,
        column_name.name,
        column_name.declared_type,
        column_name.database,
        column_name.table,
        column_name.column,
        column_name.count,
        prepare_save_sql,
        prepare_mask,
        labelAddress(-5),
    };
    const oracle = [_]i64{
        layout.constants.DB_SchemaLoaded,
        layout.constants.DB_UnresetViews,
        layout.constants.DB_ResetWanted,
        layout.constants.SQLITE_SO_ASC,
        layout.constants.SQLITE_SO_DESC,
        layout.constants.SQLITE_SO_UNDEFINED,
        layout.constants.SQLITE_MAX_SCHEMA_RETRY,
        layout.constants.VDBE_DISPLAY_P4,
        layout.constants.CURTYPE_BTREE,
        layout.constants.CURTYPE_SORTER,
        layout.constants.CURTYPE_VTAB,
        layout.constants.CURTYPE_PSEUDO,
        layout.constants.SZ_VDBECURSOR_0,
        layout.constants.SZ_VDBECURSOR_1,
        layout.constants.SZ_VDBECURSOR_5,
        layout.constants.SZ_KEYINFO_0,
        layout.constants.SZ_KEYINFO_5,
        layout.constants.KEYINFO_ORDER_DESC,
        layout.constants.KEYINFO_ORDER_BIGNULL,
        layout.constants.VDBE_FRAME_MEM_OFFSET,
        layout.constants.CACHE_STALE,
        layout.constants.SQLITE_FRAME_MAGIC,
        layout.constants.SZ_CONTEXT_0,
        layout.constants.VDBE_INIT_STATE,
        layout.constants.VDBE_READY_STATE,
        layout.constants.VDBE_RUN_STATE,
        layout.constants.VDBE_HALT_STATE,
        layout.constants.MEM_Undefined,
        layout.constants.MEM_Null,
        layout.constants.MEM_Str,
        layout.constants.MEM_Int,
        layout.constants.MEM_Real,
        layout.constants.MEM_Blob,
        layout.constants.MEM_IntReal,
        layout.constants.MEM_AffMask,
        layout.constants.MEM_FromBind,
        layout.constants.MEM_Cleared,
        layout.constants.MEM_Term,
        layout.constants.MEM_Zero,
        layout.constants.MEM_Subtype,
        layout.constants.MEM_TypeMask,
        layout.constants.MEM_Dyn,
        layout.constants.MEM_Static,
        layout.constants.MEM_Ephem,
        layout.constants.MEM_Agg,
        layout.constants.MEMCELLSIZE,
        layout.constants.P4_NOTUSED,
        layout.constants.P4_TRANSIENT,
        layout.constants.P4_STATIC,
        layout.constants.P4_COLLSEQ,
        layout.constants.P4_INT32,
        layout.constants.P4_SUBPROGRAM,
        layout.constants.P4_TABLE,
        layout.constants.P4_INDEX,
        layout.constants.P4_FREE_IF_LE,
        layout.constants.P4_DYNAMIC,
        layout.constants.P4_FUNCDEF,
        layout.constants.P4_KEYINFO,
        layout.constants.P4_EXPR,
        layout.constants.P4_MEM,
        layout.constants.P4_VTAB,
        layout.constants.P4_REAL,
        layout.constants.P4_INT64,
        layout.constants.P4_INTARRAY,
        layout.constants.P4_FUNCCTX,
        layout.constants.P4_TABLEREF,
        layout.constants.P4_SUBRTNSIG,
        layout.constants.P5_ConstraintNotNull,
        layout.constants.P5_ConstraintUnique,
        layout.constants.P5_ConstraintCheck,
        layout.constants.P5_ConstraintFK,
        layout.constants.COLNAME_NAME,
        layout.constants.COLNAME_DECLTYPE,
        layout.constants.COLNAME_DATABASE,
        layout.constants.COLNAME_TABLE,
        layout.constants.COLNAME_COLUMN,
        layout.constants.COLNAME_N,
        layout.constants.SQLITE_PREPARE_SAVESQL,
        layout.constants.SQLITE_PREPARE_MASK,
        layout.constants.ADDR_NEG5,
    };
    if (!std.mem.eql(i64, &ported, &oracle)) @compileError("vdbe.h constants differ from pinned C profile");
}

test "active vdbe.h layout and constants" {
    try std.testing.expectEqual(@as(i8, -18), p4.subroutine_signature);
    try std.testing.expectEqual(@as(usize, 2), column_name.count);
    try std.testing.expectEqual(@as(c_int, 4), labelAddress(-5));
}

test "active sqlite3 connection macros" {
    var schema: Schema = undefined;
    schema.encoding = 42;
    var backends: [2]Db = undefined;
    backends[0].pSchema = &schema;
    var connection: Sqlite3 = undefined;
    connection.aDb = &backends;
    connection.enc = 43;
    connection.dbOptFlags = optimization.query_flattener;

    try std.testing.expectEqual(@as(u8, @intCast(layout.constants.SCHEMA_ENC_RESULT)), schemaEncoding(&connection));
    try std.testing.expectEqual(@as(u8, @intCast(layout.constants.ENC_RESULT)), encoding(&connection));
    try std.testing.expectEqual(layout.constants.OPT_DISABLED_SET != 0, optimizationDisabled(&connection, optimization.query_flattener));
    try std.testing.expectEqual(layout.constants.OPT_ENABLED_SET != 0, optimizationEnabled(&connection, optimization.query_flattener));
    try std.testing.expectEqual(layout.constants.OPT_DISABLED_CLEAR != 0, optimizationDisabled(&connection, optimization.window_function));
    try std.testing.expectEqual(layout.constants.OPT_ENABLED_CLEAR != 0, optimizationEnabled(&connection, optimization.window_function));
}

test "active Mem and frame macros" {
    var frame: VdbeFrame = undefined;
    try std.testing.expectEqual(
        @as(usize, @intCast(layout.constants.VDBE_FRAME_MEM_OFFSET)),
        @intFromPtr(frameMem(&frame)) - @intFromPtr(&frame),
    );

    var mem: Mem = undefined;
    mem.flags = 0;
    try std.testing.expectEqual(layout.constants.VDBE_MEM_DYNAMIC_NONE != 0, memIsDynamic(&mem));
    mem.flags = mem_flag.dynamic;
    try std.testing.expectEqual(layout.constants.VDBE_MEM_DYNAMIC_DYN != 0, memIsDynamic(&mem));
    mem.flags = mem_flag.aggregate;
    try std.testing.expectEqual(layout.constants.VDBE_MEM_DYNAMIC_AGG != 0, memIsDynamic(&mem));
    mem.flags = mem_flag.static;
    try std.testing.expectEqual(layout.constants.VDBE_MEM_DYNAMIC_STATIC != 0, memIsDynamic(&mem));

    mem.flags = mem_flag.string | mem_flag.dynamic | mem_flag.zero | mem_flag.from_bind;
    memSetTypeFlag(&mem, mem_flag.integer);
    try std.testing.expectEqual(@as(u16, @intCast(layout.constants.MEM_SET_TYPE_RESULT)), mem.flags);

    mem.flags = mem_flag.null_ | mem_flag.zero;
    mem.n = 0;
    mem.u.nZero = 0;
    try std.testing.expectEqual(layout.constants.MEM_NULL_NOCHNG_TRUE != 0, memIsNullNoChange(&mem));
    mem.n = 1;
    try std.testing.expectEqual(layout.constants.MEM_NULL_NOCHNG_LENGTH != 0, memIsNullNoChange(&mem));
    mem.n = 0;
    mem.u.nZero = 1;
    try std.testing.expectEqual(layout.constants.MEM_NULL_NOCHNG_ZEROS != 0, memIsNullNoChange(&mem));
    mem.u.nZero = 0;
    mem.flags = mem_flag.null_;
    try std.testing.expectEqual(layout.constants.MEM_NULL_NOCHNG_FLAGS != 0, memIsNullNoChange(&mem));
}

test "active VdbeCursor sizing and null predicate" {
    try std.testing.expectEqual(@as(usize, @intCast(layout.constants.SZ_VDBECURSOR_0)), cursorSize(0));
    try std.testing.expectEqual(@as(usize, @intCast(layout.constants.SZ_VDBECURSOR_1)), cursorSize(1));
    try std.testing.expectEqual(@as(usize, @intCast(layout.constants.SZ_VDBECURSOR_5)), cursorSize(5));

    var cursor: VdbeCursor = undefined;
    cursor.eCurType = cursor_type.pseudo;
    cursor.nullRow = 1;
    cursor.seekResult = 0;
    try std.testing.expectEqual(layout.constants.IS_NULL_CURSOR_TRUE != 0, isNullCursor(&cursor));
    cursor.eCurType = cursor_type.btree;
    try std.testing.expectEqual(layout.constants.IS_NULL_CURSOR_WRONG_TYPE != 0, isNullCursor(&cursor));
    cursor.eCurType = cursor_type.pseudo;
    cursor.nullRow = 0;
    try std.testing.expectEqual(layout.constants.IS_NULL_CURSOR_HAS_ROW != 0, isNullCursor(&cursor));
    cursor.nullRow = 1;
    cursor.seekResult = 1;
    try std.testing.expectEqual(layout.constants.IS_NULL_CURSOR_HAS_REGISTER != 0, isNullCursor(&cursor));
}
