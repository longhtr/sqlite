#include "sqlite3.c"
#include <stddef.h>
#include <stdio.h>

#define TYPE(T) printf("TYPE\t%s\t%zu\t%zu\n", #T, sizeof(T), _Alignof(T))
#define FIELD(T, F) printf("FIELD\t%s\t%s\t%zu\t%zu\n", #T, #F, offsetof(T, F), sizeof(((T*)0)->F))
#define FIELD_N(T, N, F) printf("FIELD\t%s\t%s\t%zu\t%zu\n", #T, N, offsetof(T, F), sizeof(((T*)0)->F))
#define CONSTANT(C) printf("CONST\t%s\t%lld\n", #C, (long long)(C))

typedef __typeof__(((sqlite3*)0)->trace) Sqlite3Trace;
typedef __typeof__(((sqlite3*)0)->u1) Sqlite3Interrupt;

static void init_info_flag(const char *name, int flag) {
  struct sqlite3InitInfo info;
  unsigned char *bytes = (unsigned char*)&info;
  size_t i;
  memset(&info, 0, sizeof(info));
  switch(flag){
    case 0: info.orphanTrigger=1; break;
    case 1: info.imposterTable=3; break;
    case 2: info.reopenMemdb=1; break;
  }
  for(i=0; i<sizeof(info); i++) if(bytes[i]){
    printf("CONST\tINIT_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tINIT_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void cursor_flag(const char *name, int flag) {
  VdbeCursor cursor;
  unsigned char *bytes = (unsigned char*)&cursor;
  size_t i;
  memset(&cursor, 0, sizeof(cursor));
  switch(flag){
    case 0: cursor.isEphemeral=1; break;
    case 1: cursor.useRandomRowid=1; break;
    case 2: cursor.isOrdered=1; break;
    case 3: cursor.noReuse=1; break;
    case 4: cursor.colCache=1; break;
  }
  for(i=0; i<sizeof(cursor); i++) if(bytes[i]){
    printf("CONST\tCURSOR_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tCURSOR_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void cursor_semantics(void) {
  VdbeCursor cursor;
  memset(&cursor, 0, sizeof(cursor));
  cursor.eCurType = CURTYPE_PSEUDO;
  cursor.nullRow = 1;
  printf("CONST\tIS_NULL_CURSOR_TRUE\t%d\n", IsNullCursor(&cursor));
  cursor.eCurType = CURTYPE_BTREE;
  printf("CONST\tIS_NULL_CURSOR_WRONG_TYPE\t%d\n", IsNullCursor(&cursor));
  cursor.eCurType = CURTYPE_PSEUDO;
  cursor.nullRow = 0;
  printf("CONST\tIS_NULL_CURSOR_HAS_ROW\t%d\n", IsNullCursor(&cursor));
  cursor.nullRow = 1;
  cursor.seekResult = 1;
  printf("CONST\tIS_NULL_CURSOR_HAS_REGISTER\t%d\n", IsNullCursor(&cursor));
}

static void vdbe_flag(const char *name, int flag) {
  Vdbe vdbe;
  unsigned char *bytes = (unsigned char*)&vdbe;
  size_t i;
  memset(&vdbe, 0, sizeof(vdbe));
  switch(flag){
    case 0: vdbe.expired=3; break;
    case 1: vdbe.explain=3; break;
    case 2: vdbe.changeCntOn=1; break;
    case 3: vdbe.usesStmtJournal=1; break;
    case 4: vdbe.readOnly=1; break;
    case 5: vdbe.bIsReader=1; break;
    case 6: vdbe.haveEqpOps=1; break;
  }
  for(i=0; i<sizeof(vdbe); i++) if(bytes[i]){
    printf("CONST\tVDBE_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tVDBE_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void column_definition_flag(const char *name, int flag) {
  Column column;
  unsigned char *bytes = (unsigned char*)&column;
  size_t i;
  memset(&column, 0, sizeof(column));
  if(flag==0) column.notNull=1;
  else column.eCType=1;
  for(i=0; i<sizeof(column); i++) if(bytes[i]){
    printf("CONST\tCOLUMN_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tCOLUMN_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void index_flag(const char *name, int flag) {
  Index index;
  unsigned char *bytes = (unsigned char*)&index;
  size_t i;
  memset(&index, 0, sizeof(index));
  switch(flag){
    case 0: index.idxType=1; break;
    case 1: index.bUnordered=1; break;
    case 2: index.uniqNotNull=1; break;
    case 3: index.isResized=1; break;
    case 4: index.isCovering=1; break;
    case 5: index.noSkipScan=1; break;
    case 6: index.hasStat1=1; break;
    case 7: index.bNoQuery=1; break;
    case 8: index.bAscKeyBug=1; break;
    case 9: index.bHasVCol=1; break;
    case 10: index.bHasExpr=1; break;
  }
  for(i=0; i<sizeof(index); i++) if(bytes[i]){
    printf("CONST\tINDEX_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tINDEX_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void connection_semantics(void) {
  sqlite3 db;
  Db backends[2];
  Schema schema;
  memset(&db, 0, sizeof(db));
  memset(backends, 0, sizeof(backends));
  memset(&schema, 0, sizeof(schema));
  db.aDb = backends;
  backends[0].pSchema = &schema;
  schema.enc = 42;
  db.enc = 43;
  db.dbOptFlags = SQLITE_QueryFlattener;
  printf("CONST\tSCHEMA_ENC_RESULT\t%d\n", SCHEMA_ENC(&db));
  printf("CONST\tENC_RESULT\t%d\n", ENC(&db));
  printf("CONST\tOPT_DISABLED_SET\t%d\n", OptimizationDisabled(&db, SQLITE_QueryFlattener));
  printf("CONST\tOPT_ENABLED_SET\t%d\n", OptimizationEnabled(&db, SQLITE_QueryFlattener));
  printf("CONST\tOPT_DISABLED_CLEAR\t%d\n", OptimizationDisabled(&db, SQLITE_WindowFunc));
  printf("CONST\tOPT_ENABLED_CLEAR\t%d\n", OptimizationEnabled(&db, SQLITE_WindowFunc));
  printf("CONST\tHI_40\t%lld\n", (long long)HI(0x40));
}

static void lookaside_semantics(void) {
  sqlite3 object;
  sqlite3 *db = &object;
  memset(db, 0, sizeof(*db));
  db->lookaside.sz = 1200;
  db->lookaside.szTrue = 1200;
  DisableLookaside;
  printf("CONST\tLOOKASIDE_DISABLED_COUNT\t%u\n", db->lookaside.bDisable);
  printf("CONST\tLOOKASIDE_DISABLED_SIZE\t%u\n", db->lookaside.sz);
  DisableLookaside;
  EnableLookaside;
  printf("CONST\tLOOKASIDE_NESTED_COUNT\t%u\n", db->lookaside.bDisable);
  printf("CONST\tLOOKASIDE_NESTED_SIZE\t%u\n", db->lookaside.sz);
  EnableLookaside;
  printf("CONST\tLOOKASIDE_ENABLED_COUNT\t%u\n", db->lookaside.bDisable);
  printf("CONST\tLOOKASIDE_ENABLED_SIZE\t%u\n", db->lookaside.sz);
}

static void mem_macro_semantics(void) {
  Mem mem;
  VdbeFrame frame;
  memset(&mem, 0, sizeof(mem));
  printf("CONST\tVDBE_FRAME_MEM_OFFSET\t%lld\n",
         (long long)((u8*)VdbeFrameMem(&frame) - (u8*)&frame));
  printf("CONST\tVDBE_MEM_DYNAMIC_NONE\t%d\n", VdbeMemDynamic(&mem));
  mem.flags = MEM_Dyn;
  printf("CONST\tVDBE_MEM_DYNAMIC_DYN\t%d\n", VdbeMemDynamic(&mem));
  mem.flags = MEM_Agg;
  printf("CONST\tVDBE_MEM_DYNAMIC_AGG\t%d\n", VdbeMemDynamic(&mem));
  mem.flags = MEM_Static;
  printf("CONST\tVDBE_MEM_DYNAMIC_STATIC\t%d\n", VdbeMemDynamic(&mem));
  mem.flags = MEM_Str|MEM_Dyn|MEM_Zero|MEM_FromBind;
  MemSetTypeFlag(&mem, MEM_Int);
  printf("CONST\tMEM_SET_TYPE_RESULT\t%u\n", (unsigned)mem.flags);
  mem.flags = MEM_Null|MEM_Zero; mem.n = 0; mem.u.nZero = 0;
  printf("CONST\tMEM_NULL_NOCHNG_TRUE\t%d\n", MemNullNochng(&mem));
  mem.n = 1;
  printf("CONST\tMEM_NULL_NOCHNG_LENGTH\t%d\n", MemNullNochng(&mem));
  mem.n = 0; mem.u.nZero = 1;
  printf("CONST\tMEM_NULL_NOCHNG_ZEROS\t%d\n", MemNullNochng(&mem));
  mem.u.nZero = 0; mem.flags = MEM_Null;
  printf("CONST\tMEM_NULL_NOCHNG_FLAGS\t%d\n", MemNullNochng(&mem));
}

int main(void) {
  TYPE(VdbeCursor);
  FIELD(VdbeCursor, eCurType); FIELD(VdbeCursor, iDb); FIELD(VdbeCursor, nullRow);
  FIELD(VdbeCursor, deferredMoveto); FIELD(VdbeCursor, isTable); FIELD(VdbeCursor, seekHit);
  FIELD(VdbeCursor, ub); FIELD(VdbeCursor, seqCount); FIELD(VdbeCursor, cacheStatus);
  FIELD(VdbeCursor, seekResult); FIELD(VdbeCursor, pAltCursor); FIELD(VdbeCursor, uc);
  FIELD(VdbeCursor, pKeyInfo); FIELD(VdbeCursor, iHdrOffset); FIELD(VdbeCursor, pgnoRoot);
  FIELD(VdbeCursor, nField); FIELD(VdbeCursor, nHdrParsed); FIELD(VdbeCursor, movetoTarget);
  FIELD(VdbeCursor, aOffset); FIELD(VdbeCursor, aRow); FIELD(VdbeCursor, payloadSize);
  FIELD(VdbeCursor, szRow); FIELD(VdbeCursor, pCache);
  printf("FIELD\tVdbeCursor\taType\t%zu\t%zu\n", offsetof(VdbeCursor, aType), sizeof(u32));
  cursor_flag("ISEPHEMERAL",0); cursor_flag("USERANDOMROWID",1);
  cursor_flag("ISORDERED",2); cursor_flag("NOREUSE",3); cursor_flag("COLCACHE",4);
  cursor_semantics();

  TYPE(Vdbe);
  FIELD(Vdbe, db); FIELD(Vdbe, ppVPrev); FIELD(Vdbe, pVNext); FIELD(Vdbe, pParse);
  FIELD(Vdbe, nVar); FIELD(Vdbe, nMem); FIELD(Vdbe, nCursor); FIELD(Vdbe, cacheCtr);
  FIELD(Vdbe, pc); FIELD(Vdbe, rc); FIELD(Vdbe, nChange); FIELD(Vdbe, iStatement);
  FIELD(Vdbe, iCurrentTime); FIELD(Vdbe, nFkConstraint); FIELD(Vdbe, nStmtDefCons);
  FIELD(Vdbe, nStmtDefImmCons); FIELD(Vdbe, aMem); FIELD(Vdbe, apArg); FIELD(Vdbe, apCsr);
  FIELD(Vdbe, aVar); FIELD(Vdbe, aOp); FIELD(Vdbe, nOp); FIELD(Vdbe, nOpAlloc);
  FIELD(Vdbe, aColName); FIELD(Vdbe, pResultRow); FIELD(Vdbe, zErrMsg); FIELD(Vdbe, pVList);
  FIELD(Vdbe, startTime); FIELD(Vdbe, nResColumn); FIELD(Vdbe, nResAlloc);
  FIELD(Vdbe, errorAction); FIELD(Vdbe, minWriteFileFormat); FIELD(Vdbe, prepFlags);
  FIELD(Vdbe, eVdbeState); FIELD(Vdbe, btreeMask); FIELD(Vdbe, lockMask);
  FIELD(Vdbe, aCounter); FIELD(Vdbe, zSql); FIELD(Vdbe, pFree); FIELD(Vdbe, pFrame);
  FIELD(Vdbe, pDelFrame); FIELD(Vdbe, nFrame); FIELD(Vdbe, expmask); FIELD(Vdbe, pProgram);
  FIELD(Vdbe, pAuxData);
  vdbe_flag("EXPIRED",0); vdbe_flag("EXPLAIN",1); vdbe_flag("CHANGECNTON",2);
  vdbe_flag("USESSTMTJOURNAL",3); vdbe_flag("READONLY",4); vdbe_flag("BISREADER",5);
  vdbe_flag("HAVEEQPOPS",6);

  TYPE(sqlite3_pcache_methods2);
  FIELD(sqlite3_pcache_methods2, iVersion); FIELD(sqlite3_pcache_methods2, pArg);
  FIELD(sqlite3_pcache_methods2, xInit); FIELD(sqlite3_pcache_methods2, xShutdown);
  FIELD(sqlite3_pcache_methods2, xCreate); FIELD(sqlite3_pcache_methods2, xCachesize);
  FIELD(sqlite3_pcache_methods2, xPagecount); FIELD(sqlite3_pcache_methods2, xFetch);
  FIELD(sqlite3_pcache_methods2, xUnpin); FIELD(sqlite3_pcache_methods2, xRekey);
  FIELD(sqlite3_pcache_methods2, xTruncate); FIELD(sqlite3_pcache_methods2, xDestroy);
  FIELD(sqlite3_pcache_methods2, xShrink);

  TYPE(struct Sqlite3Config);
  FIELD(struct Sqlite3Config, bMemstat); FIELD(struct Sqlite3Config, bCoreMutex);
  FIELD(struct Sqlite3Config, bFullMutex); FIELD(struct Sqlite3Config, bOpenUri);
  FIELD(struct Sqlite3Config, bUseCis); FIELD(struct Sqlite3Config, bSmallMalloc);
  FIELD(struct Sqlite3Config, bExtraSchemaChecks); FIELD(struct Sqlite3Config, mxStrlen);
  FIELD(struct Sqlite3Config, neverCorrupt); FIELD(struct Sqlite3Config, szLookaside);
  FIELD(struct Sqlite3Config, nLookaside); FIELD(struct Sqlite3Config, nStmtSpill);
  FIELD(struct Sqlite3Config, m); FIELD(struct Sqlite3Config, mutex);
  FIELD(struct Sqlite3Config, pcache2); FIELD(struct Sqlite3Config, pHeap);
  FIELD(struct Sqlite3Config, nHeap); FIELD(struct Sqlite3Config, mnReq);
  FIELD(struct Sqlite3Config, mxReq); FIELD(struct Sqlite3Config, szMmap);
  FIELD(struct Sqlite3Config, mxMmap); FIELD(struct Sqlite3Config, pPage);
  FIELD(struct Sqlite3Config, szPage); FIELD(struct Sqlite3Config, nPage);
  FIELD(struct Sqlite3Config, mxParserStack); FIELD(struct Sqlite3Config, sharedCacheEnabled);
  FIELD(struct Sqlite3Config, szPma); FIELD(struct Sqlite3Config, isInit);
  FIELD(struct Sqlite3Config, inProgress); FIELD(struct Sqlite3Config, isMutexInit);
  FIELD(struct Sqlite3Config, isMallocInit); FIELD(struct Sqlite3Config, isPCacheInit);
  FIELD(struct Sqlite3Config, nRefInitMutex); FIELD(struct Sqlite3Config, pInitMutex);
  FIELD(struct Sqlite3Config, xLog); FIELD(struct Sqlite3Config, pLogArg);
  FIELD(struct Sqlite3Config, mxMemdbSize); FIELD(struct Sqlite3Config, xTestCallback);
  FIELD(struct Sqlite3Config, bLocaltimeFault); FIELD(struct Sqlite3Config, xAltLocaltime);
  FIELD(struct Sqlite3Config, iOnceResetThreshold); FIELD(struct Sqlite3Config, szSorterRef);
  FIELD(struct Sqlite3Config, iPrngSeed);

  TYPE(struct sqlite3InitInfo);
  FIELD(struct sqlite3InitInfo, newTnum); FIELD(struct sqlite3InitInfo, iDb);
  FIELD(struct sqlite3InitInfo, busy); FIELD(struct sqlite3InitInfo, azInit);
  init_info_flag("ORPHAN_TRIGGER",0); init_info_flag("IMPOSTER_TABLE",1);
  init_info_flag("REOPEN_MEMDB",2);

  TYPE(Sqlite3Trace);
  FIELD(Sqlite3Trace, xLegacy); FIELD(Sqlite3Trace, xV2);
  TYPE(Sqlite3Interrupt);
  FIELD(Sqlite3Interrupt, isInterrupted); FIELD(Sqlite3Interrupt, notUsed1);

  TYPE(sqlite3);
  FIELD(sqlite3, pVfs); FIELD(sqlite3, pVdbe); FIELD(sqlite3, pDfltColl);
  FIELD(sqlite3, mutex); FIELD(sqlite3, aDb); FIELD(sqlite3, nDb);
  FIELD(sqlite3, mDbFlags); FIELD(sqlite3, flags); FIELD(sqlite3, lastRowid);
  FIELD(sqlite3, szMmap); FIELD(sqlite3, nSchemaLock); FIELD(sqlite3, openFlags);
  FIELD(sqlite3, errCode); FIELD(sqlite3, errByteOffset); FIELD(sqlite3, errMask);
  FIELD(sqlite3, iSysErrno); FIELD(sqlite3, dbOptFlags); FIELD(sqlite3, enc);
  FIELD(sqlite3, autoCommit); FIELD(sqlite3, temp_store); FIELD(sqlite3, mallocFailed);
  FIELD(sqlite3, bBenignMalloc); FIELD(sqlite3, dfltLockMode); FIELD(sqlite3, nextAutovac);
  FIELD(sqlite3, suppressErr); FIELD(sqlite3, vtabOnConflict);
  FIELD(sqlite3, isTransactionSavepoint); FIELD(sqlite3, mTrace);
  FIELD(sqlite3, noSharedCache); FIELD(sqlite3, nSqlExec); FIELD(sqlite3, eOpenState);
  FIELD(sqlite3, nFpDigit); FIELD(sqlite3, nextPagesize); FIELD(sqlite3, nChange);
  FIELD(sqlite3, nTotalChange); FIELD(sqlite3, aLimit); FIELD(sqlite3, nMaxSorterMmap);
  FIELD(sqlite3, init); FIELD(sqlite3, nVdbeActive); FIELD(sqlite3, nVdbeRead);
  FIELD(sqlite3, nVdbeWrite); FIELD(sqlite3, nVdbeExec); FIELD(sqlite3, nVDestroy);
  FIELD(sqlite3, nExtension); FIELD(sqlite3, aExtension); FIELD(sqlite3, trace);
  FIELD(sqlite3, pTraceArg); FIELD(sqlite3, xProfile); FIELD(sqlite3, pProfileArg);
  FIELD(sqlite3, pCommitArg); FIELD(sqlite3, xCommitCallback); FIELD(sqlite3, pRollbackArg);
  FIELD(sqlite3, xRollbackCallback); FIELD(sqlite3, pUpdateArg);
  FIELD(sqlite3, xUpdateCallback); FIELD(sqlite3, pAutovacPagesArg);
  FIELD(sqlite3, xAutovacDestr); FIELD(sqlite3, xAutovacPages); FIELD(sqlite3, pParse);
  FIELD(sqlite3, xWalCallback); FIELD(sqlite3, pWalArg); FIELD(sqlite3, xCollNeeded);
  FIELD(sqlite3, xCollNeeded16); FIELD(sqlite3, pCollNeededArg); FIELD(sqlite3, pErr);
  FIELD(sqlite3, u1); FIELD(sqlite3, lookaside); FIELD(sqlite3, xAuth);
  FIELD(sqlite3, pAuthArg); FIELD(sqlite3, xProgress); FIELD(sqlite3, pProgressArg);
  FIELD(sqlite3, nProgressOps); FIELD(sqlite3, nVTrans); FIELD(sqlite3, aModule);
  FIELD(sqlite3, pVtabCtx); FIELD(sqlite3, aVTrans); FIELD(sqlite3, pDisconnect);
  FIELD(sqlite3, aFunc); FIELD(sqlite3, aCollSeq); FIELD(sqlite3, busyHandler);
  FIELD(sqlite3, aDbStatic); FIELD(sqlite3, pSavepoint); FIELD(sqlite3, nAnalysisLimit);
  FIELD(sqlite3, busyTimeout); FIELD(sqlite3, nSavepoint); FIELD(sqlite3, nStatement);
  FIELD(sqlite3, nDeferredCons); FIELD(sqlite3, nDeferredImmCons);
  FIELD(sqlite3, pnBytesFreed); FIELD(sqlite3, pDbData); FIELD(sqlite3, nSpill);

  TYPE(BusyHandler);
  FIELD(BusyHandler, xBusyHandler); FIELD(BusyHandler, pBusyArg); FIELD(BusyHandler, nBusy);

  TYPE(BtLock);
  FIELD(BtLock, pBtree); FIELD(BtLock, iTable); FIELD(BtLock, eLock); FIELD(BtLock, pNext);

  TYPE(BtreePayload);
  FIELD(BtreePayload, pKey); FIELD(BtreePayload, nKey); FIELD(BtreePayload, pData);
  FIELD(BtreePayload, aMem); FIELD(BtreePayload, nMem); FIELD(BtreePayload, nData); FIELD(BtreePayload, nZero);

  TYPE(Btree);
  FIELD(Btree, db); FIELD(Btree, pBt); FIELD(Btree, inTrans); FIELD(Btree, sharable);
  FIELD(Btree, locked); FIELD(Btree, hasIncrblobCur); FIELD(Btree, wantToLock);
  FIELD(Btree, nBackup); FIELD(Btree, iBDataVersion); FIELD(Btree, pNext);
  FIELD(Btree, pPrev); FIELD(Btree, lock);

  TYPE(Db);
  FIELD(Db, zDbSName); FIELD(Db, pBt); FIELD(Db, safety_level);
  FIELD(Db, bSyncSet); FIELD(Db, pSchema);

  TYPE(Schema);
  FIELD(Schema, schema_cookie); FIELD(Schema, iGeneration); FIELD(Schema, tblHash);
  FIELD(Schema, idxHash); FIELD(Schema, trigHash); FIELD(Schema, fkeyHash);
  FIELD(Schema, pSeqTab); FIELD(Schema, file_format); FIELD(Schema, enc);
  FIELD(Schema, schemaFlags); FIELD(Schema, cache_size);

  TYPE(Column);
  FIELD(Column, zCnName); FIELD(Column, affinity); FIELD(Column, szEst);
  FIELD(Column, hName); FIELD(Column, iDflt); FIELD(Column, colFlags);
  column_definition_flag("NOT_NULL",0); column_definition_flag("DECLARED_TYPE",1);

  TYPE(Table);
  FIELD(Table, zName); FIELD(Table, aCol); FIELD(Table, pIndex); FIELD(Table, zColAff);
  FIELD(Table, pCheck); FIELD(Table, tnum); FIELD(Table, nTabRef); FIELD(Table, tabFlags);
  FIELD(Table, iPKey); FIELD(Table, nCol); FIELD(Table, nNVCol); FIELD(Table, nRowLogEst);
  FIELD(Table, szTabRow); FIELD(Table, keyConf); FIELD(Table, eTabType); FIELD(Table, u);
  FIELD_N(Table, "u_tab_addColOffset", u.tab.addColOffset);
  FIELD_N(Table, "u_tab_pFKey", u.tab.pFKey);
  FIELD_N(Table, "u_tab_pDfltList", u.tab.pDfltList);
  FIELD_N(Table, "u_view_pSelect", u.view.pSelect);
  FIELD_N(Table, "u_vtab_nArg", u.vtab.nArg);
  FIELD_N(Table, "u_vtab_azArg", u.vtab.azArg);
  FIELD_N(Table, "u_vtab_p", u.vtab.p);
  FIELD(Table, pTrigger); FIELD(Table, pSchema); FIELD(Table, aHx);

  TYPE(Index);
  FIELD(Index, zName); FIELD(Index, aiColumn); FIELD(Index, aiRowLogEst); FIELD(Index, pTable);
  FIELD(Index, zColAff); FIELD(Index, pNext); FIELD(Index, pSchema); FIELD(Index, aSortOrder);
  FIELD(Index, azColl); FIELD(Index, pPartIdxWhere); FIELD(Index, aColExpr); FIELD(Index, tnum);
  FIELD(Index, szIdxRow); FIELD(Index, nKeyCol); FIELD(Index, nColumn); FIELD(Index, onError);
  FIELD(Index, colNotIdxed);
  index_flag("KIND",0); index_flag("UNORDERED",1); index_flag("UNIQUE_NOT_NULL",2);
  index_flag("RESIZED",3); index_flag("COVERING",4); index_flag("NO_SKIP_SCAN",5);
  index_flag("HAS_STATISTICS",6); index_flag("NO_QUERY",7); index_flag("ASCENDING_KEY_BUG",8);
  index_flag("HAS_VIRTUAL_COLUMN",9); index_flag("HAS_EXPRESSION",10);

  TYPE(FKey);
  FIELD(FKey, pFrom); FIELD(FKey, pNextFrom); FIELD(FKey, zTo); FIELD(FKey, pNextTo);
  FIELD(FKey, pPrevTo); FIELD(FKey, nCol); FIELD(FKey, isDeferred); FIELD(FKey, aAction);
  FIELD(FKey, apTrigger);
  printf("FIELD\tFKey\taCol\t%zu\t%zu\n", offsetof(FKey, aCol), sizeof(((FKey*)0)->aCol[0]));

  TYPE(struct _ht);
  FIELD(struct _ht, count); FIELD(struct _ht, chain);

  TYPE(HashElem);
  FIELD(HashElem, next); FIELD(HashElem, prev); FIELD(HashElem, data);
  FIELD(HashElem, pKey); FIELD(HashElem, h);

  TYPE(Hash);
  FIELD(Hash, htsize); FIELD(Hash, count); FIELD(Hash, first); FIELD(Hash, ht);

  TYPE(LookasideSlot);
  FIELD(LookasideSlot, pNext);

  TYPE(Lookaside);
  FIELD(Lookaside, bDisable); FIELD(Lookaside, sz); FIELD(Lookaside, szTrue);
  FIELD(Lookaside, bMalloced); FIELD(Lookaside, nSlot); FIELD(Lookaside, anStat);
  FIELD(Lookaside, pInit); FIELD(Lookaside, pFree); FIELD(Lookaside, pSmallInit);
  FIELD(Lookaside, pSmallFree); FIELD(Lookaside, pMiddle); FIELD(Lookaside, pStart);
  FIELD(Lookaside, pEnd); FIELD(Lookaside, pTrueEnd);

  TYPE(CollSeq);
  FIELD(CollSeq, zName); FIELD(CollSeq, enc); FIELD(CollSeq, pUser);
  FIELD(CollSeq, xCmp); FIELD(CollSeq, xDel);

  TYPE(FuncDestructor);
  FIELD(FuncDestructor, nRef); FIELD(FuncDestructor, xDestroy); FIELD(FuncDestructor, pUserData);

  TYPE(FuncDef);
  FIELD(FuncDef, nArg); FIELD(FuncDef, funcFlags); FIELD(FuncDef, pUserData);
  FIELD(FuncDef, pNext); FIELD(FuncDef, xSFunc); FIELD(FuncDef, xFinalize);
  FIELD(FuncDef, xValue); FIELD(FuncDef, xInverse); FIELD(FuncDef, zName); FIELD(FuncDef, u);

  TYPE(FuncDefHash);
  FIELD(FuncDefHash, a);

  TYPE(Savepoint);
  FIELD(Savepoint, zName); FIELD(Savepoint, nDeferredCons);
  FIELD(Savepoint, nDeferredImmCons); FIELD(Savepoint, pNext);

  TYPE(Module);
  FIELD(Module, pModule); FIELD(Module, zName); FIELD(Module, nRefModule);
  FIELD(Module, pAux); FIELD(Module, xDestroy); FIELD(Module, pEpoTab);

  TYPE(DbClientData);
  FIELD(DbClientData, pNext); FIELD(DbClientData, pData);
  FIELD(DbClientData, xDestructor);
  printf("FIELD\tDbClientData\tzName\t%zu\t%zu\n", offsetof(DbClientData, zName), sizeof(char));

  TYPE(KeyInfo);
  FIELD(KeyInfo, nRef); FIELD(KeyInfo, enc); FIELD(KeyInfo, nKeyField);
  FIELD(KeyInfo, nAllField); FIELD(KeyInfo, db); FIELD(KeyInfo, aSortFlags);
  printf("FIELD\tKeyInfo\taColl\t%zu\t%zu\n", offsetof(KeyInfo, aColl), sizeof(CollSeq*));

  TYPE(UnpackedRecord);
  FIELD(UnpackedRecord, pKeyInfo); FIELD(UnpackedRecord, aMem); FIELD(UnpackedRecord, u);
  FIELD(UnpackedRecord, n); FIELD(UnpackedRecord, nField); FIELD(UnpackedRecord, default_rc);
  FIELD(UnpackedRecord, errCode); FIELD(UnpackedRecord, r1); FIELD(UnpackedRecord, r2);
  FIELD(UnpackedRecord, eqSeen);

  TYPE(PreUpdate);
  FIELD(PreUpdate, v); FIELD(PreUpdate, pCsr); FIELD(PreUpdate, op);
  FIELD(PreUpdate, aRecord); FIELD(PreUpdate, pKeyinfo); FIELD(PreUpdate, pUnpacked);
  FIELD(PreUpdate, pNewUnpacked); FIELD(PreUpdate, iNewReg); FIELD(PreUpdate, iBlobWrite);
  FIELD(PreUpdate, iKey1); FIELD(PreUpdate, iKey2); FIELD(PreUpdate, oldipk);
  FIELD(PreUpdate, aNew); FIELD(PreUpdate, pTab); FIELD(PreUpdate, pPk);
  FIELD(PreUpdate, apDflt); FIELD(PreUpdate, uKey);
  printf("FIELD\tPreUpdate\tkeyinfoSpace\t%zu\t%zu\n",
         offsetof(PreUpdate, uKey.keyinfoSpace), sizeof(((PreUpdate*)0)->uKey.keyinfoSpace));

  TYPE(union MemValue);
  FIELD(union MemValue, r); FIELD(union MemValue, i); FIELD(union MemValue, nZero);
  FIELD(union MemValue, zPType); FIELD(union MemValue, pDef);

  TYPE(Mem);
  FIELD(Mem, u); FIELD(Mem, z); FIELD(Mem, n); FIELD(Mem, flags); FIELD(Mem, enc);
  FIELD(Mem, eSubtype); FIELD(Mem, db); FIELD(Mem, szMalloc); FIELD(Mem, uTemp);
  FIELD(Mem, zMalloc); FIELD(Mem, xDel);

  TYPE(VdbeTxtBlbCache);
  FIELD(VdbeTxtBlbCache, pCValue); FIELD(VdbeTxtBlbCache, iOffset);
  FIELD(VdbeTxtBlbCache, iCol); FIELD(VdbeTxtBlbCache, cacheStatus);
  FIELD(VdbeTxtBlbCache, colCacheCtr);

  TYPE(VdbeFrame);
  FIELD(VdbeFrame, v); FIELD(VdbeFrame, pParent); FIELD(VdbeFrame, aOp);
  FIELD(VdbeFrame, aMem); FIELD(VdbeFrame, apCsr); FIELD(VdbeFrame, aOnce);
  FIELD(VdbeFrame, token); FIELD(VdbeFrame, lastRowid); FIELD(VdbeFrame, pAuxData);
  FIELD(VdbeFrame, nCursor); FIELD(VdbeFrame, pc); FIELD(VdbeFrame, nOp);
  FIELD(VdbeFrame, nMem); FIELD(VdbeFrame, nChildMem); FIELD(VdbeFrame, nChildCsr);
  FIELD(VdbeFrame, nChange); FIELD(VdbeFrame, nDbChange);

  TYPE(AuxData);
  FIELD(AuxData, iAuxOp); FIELD(AuxData, iAuxArg); FIELD(AuxData, pAux);
  FIELD(AuxData, xDeleteAux); FIELD(AuxData, pNextAux);

  TYPE(sqlite3_context);
  FIELD(sqlite3_context, pOut); FIELD(sqlite3_context, pFunc); FIELD(sqlite3_context, pMem);
  FIELD(sqlite3_context, pVdbe); FIELD(sqlite3_context, iOp); FIELD(sqlite3_context, isError);
  FIELD(sqlite3_context, enc); FIELD(sqlite3_context, skipFlag); FIELD(sqlite3_context, argc);
  printf("FIELD\tsqlite3_context\targv\t%zu\t%zu\n", offsetof(sqlite3_context, argv), sizeof(sqlite3_value*));

  TYPE(ScanStatus);
  FIELD(ScanStatus, addrExplain); FIELD(ScanStatus, aAddrRange); FIELD(ScanStatus, addrLoop);
  FIELD(ScanStatus, addrVisit); FIELD(ScanStatus, iSelectID); FIELD(ScanStatus, nEst);
  FIELD(ScanStatus, zName);

  TYPE(DblquoteStr);
  FIELD(DblquoteStr, pNextStr); FIELD(DblquoteStr, z);

  TYPE(ValueList);
  FIELD(ValueList, pCsr); FIELD(ValueList, pOut);

  TYPE(SubrtnSig);
  FIELD(SubrtnSig, selId); FIELD(SubrtnSig, bComplete); FIELD(SubrtnSig, zAff);
  FIELD(SubrtnSig, iTable); FIELD(SubrtnSig, iAddr); FIELD(SubrtnSig, regReturn);

  TYPE(union p4union);
  FIELD(union p4union, i); FIELD(union p4union, p); FIELD(union p4union, z);
  FIELD(union p4union, pI64); FIELD(union p4union, pReal); FIELD(union p4union, pFunc);
  FIELD(union p4union, pCtx); FIELD(union p4union, pColl); FIELD(union p4union, pMem);
  FIELD(union p4union, pVtab); FIELD(union p4union, pKeyInfo); FIELD(union p4union, ai);
  FIELD(union p4union, pProgram); FIELD(union p4union, pTab); FIELD(union p4union, pSubrtnSig);
  FIELD(union p4union, pIdx);

  TYPE(VdbeOp);
  FIELD(VdbeOp, opcode); FIELD(VdbeOp, p4type); FIELD(VdbeOp, p5);
  FIELD(VdbeOp, p1); FIELD(VdbeOp, p2); FIELD(VdbeOp, p3); FIELD(VdbeOp, p4);

  TYPE(SubProgram);
  FIELD(SubProgram, aOp); FIELD(SubProgram, nOp); FIELD(SubProgram, nMem);
  FIELD(SubProgram, nCsr); FIELD(SubProgram, aOnce); FIELD(SubProgram, token);
  FIELD(SubProgram, pNext);

  TYPE(VdbeOpList);
  FIELD(VdbeOpList, opcode); FIELD(VdbeOpList, p1); FIELD(VdbeOpList, p2); FIELD(VdbeOpList, p3);

  CONSTANT(SQLITE_MAX_SCHEMA_RETRY);
  printf("CONST\tCONFIG_bMemstat\t%d\n", sqlite3Config.bMemstat);
  printf("CONST\tCONFIG_bCoreMutex\t%d\n", sqlite3Config.bCoreMutex);
  printf("CONST\tCONFIG_bFullMutex\t%d\n", sqlite3Config.bFullMutex);
  printf("CONST\tCONFIG_bOpenUri\t%d\n", sqlite3Config.bOpenUri);
  printf("CONST\tCONFIG_bUseCis\t%d\n", sqlite3Config.bUseCis);
  printf("CONST\tCONFIG_bSmallMalloc\t%d\n", sqlite3Config.bSmallMalloc);
  printf("CONST\tCONFIG_bExtraSchemaChecks\t%d\n", sqlite3Config.bExtraSchemaChecks);
  printf("CONST\tCONFIG_mxStrlen\t%d\n", sqlite3Config.mxStrlen);
  printf("CONST\tCONFIG_neverCorrupt\t%d\n", sqlite3Config.neverCorrupt);
  printf("CONST\tCONFIG_szLookaside\t%d\n", sqlite3Config.szLookaside);
  printf("CONST\tCONFIG_nLookaside\t%d\n", sqlite3Config.nLookaside);
  printf("CONST\tCONFIG_nStmtSpill\t%d\n", sqlite3Config.nStmtSpill);
  printf("CONST\tCONFIG_nHeap\t%d\n", sqlite3Config.nHeap);
  printf("CONST\tCONFIG_mnReq\t%d\n", sqlite3Config.mnReq);
  printf("CONST\tCONFIG_mxReq\t%d\n", sqlite3Config.mxReq);
  printf("CONST\tCONFIG_szMmap\t%lld\n", (long long)sqlite3Config.szMmap);
  printf("CONST\tCONFIG_mxMmap\t%lld\n", (long long)sqlite3Config.mxMmap);
  printf("CONST\tCONFIG_szPage\t%d\n", sqlite3Config.szPage);
  printf("CONST\tCONFIG_nPage\t%d\n", sqlite3Config.nPage);
  printf("CONST\tCONFIG_mxParserStack\t%d\n", sqlite3Config.mxParserStack);
  printf("CONST\tCONFIG_sharedCacheEnabled\t%d\n", sqlite3Config.sharedCacheEnabled);
  printf("CONST\tCONFIG_szPma\t%u\n", sqlite3Config.szPma);
  printf("CONST\tCONFIG_mxMemdbSize\t%lld\n", (long long)sqlite3Config.mxMemdbSize);
  printf("CONST\tCONFIG_bLocaltimeFault\t%d\n", sqlite3Config.bLocaltimeFault);
  printf("CONST\tCONFIG_iOnceResetThreshold\t%d\n", sqlite3Config.iOnceResetThreshold);
  printf("CONST\tCONFIG_szSorterRef\t%u\n", sqlite3Config.szSorterRef);
  printf("CONST\tCONFIG_iPrngSeed\t%u\n", sqlite3Config.iPrngSeed);
  printf("CONST\tCONFIG_ZERO_TABLES\t%d\n",
    sqlite3Config.m.xMalloc==0 && sqlite3Config.m.xFree==0 &&
    sqlite3Config.m.xRealloc==0 && sqlite3Config.m.xSize==0 &&
    sqlite3Config.m.xRoundup==0 && sqlite3Config.m.xInit==0 &&
    sqlite3Config.m.xShutdown==0 && sqlite3Config.m.pAppData==0 &&
    sqlite3Config.mutex.xMutexInit==0 && sqlite3Config.mutex.xMutexEnd==0 &&
    sqlite3Config.mutex.xMutexAlloc==0 && sqlite3Config.mutex.xMutexFree==0 &&
    sqlite3Config.mutex.xMutexEnter==0 && sqlite3Config.mutex.xMutexTry==0 &&
    sqlite3Config.mutex.xMutexLeave==0 && sqlite3Config.mutex.xMutexHeld==0 &&
    sqlite3Config.mutex.xMutexNotheld==0 && sqlite3Config.pcache2.iVersion==0 &&
    sqlite3Config.pcache2.pArg==0 && sqlite3Config.pcache2.xInit==0 &&
    sqlite3Config.pcache2.xShutdown==0 && sqlite3Config.pcache2.xCreate==0 &&
    sqlite3Config.pcache2.xCachesize==0 && sqlite3Config.pcache2.xPagecount==0 &&
    sqlite3Config.pcache2.xFetch==0 && sqlite3Config.pcache2.xUnpin==0 &&
    sqlite3Config.pcache2.xRekey==0 && sqlite3Config.pcache2.xTruncate==0 &&
    sqlite3Config.pcache2.xDestroy==0 && sqlite3Config.pcache2.xShrink==0 &&
    sqlite3Config.pHeap==0 && sqlite3Config.pPage==0);
  printf("CONST\tCONFIG_ZERO_TAIL\t%d\n",
    sqlite3Config.isInit==0 && sqlite3Config.inProgress==0 &&
    sqlite3Config.isMutexInit==0 && sqlite3Config.isMallocInit==0 &&
    sqlite3Config.isPCacheInit==0 && sqlite3Config.nRefInitMutex==0 &&
    sqlite3Config.pInitMutex==0 && sqlite3Config.xLog==0 &&
    sqlite3Config.pLogArg==0 && sqlite3Config.xTestCallback==0 &&
    sqlite3Config.xAltLocaltime==0);
  CONSTANT(SQLITE_N_LIMIT); CONSTANT(SQLITE_MAX_DB);
  CONSTANT(SQLITE_TRACE_LEGACY); CONSTANT(SQLITE_TRACE_XPROFILE);
  CONSTANT(SQLITE_TRACE_NONLEGACY_MASK);
  CONSTANT(SQLITE_WriteSchema); CONSTANT(SQLITE_LegacyFileFmt);
  CONSTANT(SQLITE_FullColNames); CONSTANT(SQLITE_FullFSync);
  CONSTANT(SQLITE_CkptFullFSync); CONSTANT(SQLITE_CacheSpill);
  CONSTANT(SQLITE_ShortColNames); CONSTANT(SQLITE_TrustedSchema);
  CONSTANT(SQLITE_NullCallback); CONSTANT(SQLITE_IgnoreChecks);
  CONSTANT(SQLITE_StmtScanStatus); CONSTANT(SQLITE_NoCkptOnClose);
  CONSTANT(SQLITE_ReverseOrder); CONSTANT(SQLITE_RecTriggers);
  CONSTANT(SQLITE_ForeignKeys); CONSTANT(SQLITE_AutoIndex);
  CONSTANT(SQLITE_LoadExtension); CONSTANT(SQLITE_LoadExtFunc);
  CONSTANT(SQLITE_EnableTrigger); CONSTANT(SQLITE_DeferFKs);
  CONSTANT(SQLITE_QueryOnly); CONSTANT(SQLITE_CellSizeCk);
  CONSTANT(SQLITE_Fts3Tokenizer); CONSTANT(SQLITE_EnableQPSG);
  CONSTANT(SQLITE_TriggerEQP); CONSTANT(SQLITE_ResetDatabase);
  CONSTANT(SQLITE_LegacyAlter); CONSTANT(SQLITE_NoSchemaError);
  CONSTANT(SQLITE_Defensive); CONSTANT(SQLITE_DqsDDL); CONSTANT(SQLITE_DqsDML);
  CONSTANT(SQLITE_EnableView); CONSTANT(SQLITE_CountRows);
  CONSTANT(SQLITE_CorruptRdOnly); CONSTANT(SQLITE_ReadUncommit);
  CONSTANT(SQLITE_FkNoAction); CONSTANT(SQLITE_AttachCreate);
  CONSTANT(SQLITE_AttachWrite); CONSTANT(SQLITE_Comments);
  CONSTANT(DBFLAG_SchemaChange); CONSTANT(DBFLAG_PreferBuiltin);
  CONSTANT(DBFLAG_Vacuum); CONSTANT(DBFLAG_VacuumInto);
  CONSTANT(DBFLAG_SchemaKnownOk); CONSTANT(DBFLAG_InternalFunc);
  CONSTANT(DBFLAG_EncodingFixed);
  CONSTANT(SQLITE_QueryFlattener); CONSTANT(SQLITE_WindowFunc);
  CONSTANT(SQLITE_GroupByOrder); CONSTANT(SQLITE_FactorOutConst);
  CONSTANT(SQLITE_DistinctOpt); CONSTANT(SQLITE_CoverIdxScan);
  CONSTANT(SQLITE_OrderByIdxJoin); CONSTANT(SQLITE_Transitive);
  CONSTANT(SQLITE_OmitNoopJoin); CONSTANT(SQLITE_CountOfView);
  CONSTANT(SQLITE_CursorHints); CONSTANT(SQLITE_Stat4); CONSTANT(SQLITE_PushDown);
  CONSTANT(SQLITE_SimplifyJoin); CONSTANT(SQLITE_SkipScan);
  CONSTANT(SQLITE_PropagateConst); CONSTANT(SQLITE_MinMaxOpt);
  CONSTANT(SQLITE_SeekScan); CONSTANT(SQLITE_OmitOrderBy);
  CONSTANT(SQLITE_BloomFilter); CONSTANT(SQLITE_BloomPulldown);
  CONSTANT(SQLITE_BalancedMerge); CONSTANT(SQLITE_ReleaseReg);
  CONSTANT(SQLITE_FlttnUnionAll); CONSTANT(SQLITE_IndexedExpr);
  CONSTANT(SQLITE_Coroutines); CONSTANT(SQLITE_NullUnusedCols);
  CONSTANT(SQLITE_OnePass); CONSTANT(SQLITE_OrderBySubq);
  CONSTANT(SQLITE_StarQuery); CONSTANT(SQLITE_ExistsToJoin); CONSTANT(SQLITE_AllOpts);
  CONSTANT(SQLITE_STATE_OPEN); CONSTANT(SQLITE_STATE_CLOSED);
  CONSTANT(SQLITE_STATE_SICK); CONSTANT(SQLITE_STATE_BUSY);
  CONSTANT(SQLITE_STATE_ERROR); CONSTANT(SQLITE_STATE_ZOMBIE);
  connection_semantics();
  CONSTANT(VDBE_DISPLAY_P4);
  CONSTANT(CURTYPE_BTREE); CONSTANT(CURTYPE_SORTER); CONSTANT(CURTYPE_VTAB);
  CONSTANT(CURTYPE_PSEUDO);
  printf("CONST\tSZ_VDBECURSOR_0\t%lld\n", (long long)SZ_VDBECURSOR(0));
  printf("CONST\tSZ_VDBECURSOR_1\t%lld\n", (long long)SZ_VDBECURSOR(1));
  printf("CONST\tSZ_VDBECURSOR_5\t%lld\n", (long long)SZ_VDBECURSOR(5));
  CONSTANT(CACHE_STALE); CONSTANT(SQLITE_FRAME_MAGIC);
  printf("CONST\tSZ_CONTEXT_0\t%lld\n", (long long)SZ_CONTEXT(0));
  CONSTANT(VDBE_INIT_STATE); CONSTANT(VDBE_READY_STATE); CONSTANT(VDBE_RUN_STATE);
  CONSTANT(VDBE_HALT_STATE);

  CONSTANT(MEM_Undefined); CONSTANT(MEM_Null); CONSTANT(MEM_Str); CONSTANT(MEM_Int);
  CONSTANT(MEM_Real); CONSTANT(MEM_Blob); CONSTANT(MEM_IntReal); CONSTANT(MEM_AffMask);
  CONSTANT(MEM_FromBind); CONSTANT(MEM_Cleared); CONSTANT(MEM_Term); CONSTANT(MEM_Zero);
  CONSTANT(MEM_Subtype); CONSTANT(MEM_TypeMask); CONSTANT(MEM_Dyn); CONSTANT(MEM_Static);
  CONSTANT(MEM_Ephem); CONSTANT(MEM_Agg); CONSTANT(MEMCELLSIZE);

  CONSTANT(P4_NOTUSED); CONSTANT(P4_TRANSIENT); CONSTANT(P4_STATIC); CONSTANT(P4_COLLSEQ);
  CONSTANT(P4_INT32); CONSTANT(P4_SUBPROGRAM); CONSTANT(P4_TABLE); CONSTANT(P4_INDEX);
  CONSTANT(P4_FREE_IF_LE); CONSTANT(P4_DYNAMIC); CONSTANT(P4_FUNCDEF); CONSTANT(P4_KEYINFO);
  CONSTANT(P4_EXPR); CONSTANT(P4_MEM); CONSTANT(P4_VTAB); CONSTANT(P4_REAL); CONSTANT(P4_INT64);
  CONSTANT(P4_INTARRAY); CONSTANT(P4_FUNCCTX); CONSTANT(P4_TABLEREF); CONSTANT(P4_SUBRTNSIG);
  CONSTANT(P5_ConstraintNotNull); CONSTANT(P5_ConstraintUnique); CONSTANT(P5_ConstraintCheck);
  CONSTANT(P5_ConstraintFK); CONSTANT(COLNAME_NAME); CONSTANT(COLNAME_DECLTYPE);
  CONSTANT(COLNAME_DATABASE); CONSTANT(COLNAME_TABLE); CONSTANT(COLNAME_COLUMN); CONSTANT(COLNAME_N);
  CONSTANT(SQLITE_PREPARE_SAVESQL); CONSTANT(SQLITE_PREPARE_MASK);
  printf("CONST\tADDR_NEG5\t%lld\n", (long long)ADDR(-5));
  printf("CONST\tSZ_KEYINFO_0\t%lld\n", (long long)SZ_KEYINFO_0);
  printf("CONST\tSZ_KEYINFO_5\t%lld\n", (long long)SZ_KEYINFO(5));
  CONSTANT(KEYINFO_ORDER_DESC); CONSTANT(KEYINFO_ORDER_BIGNULL);
  CONSTANT(SQLITE_FUNC_HASH_SZ);
  printf("CONST\tSQLITE_FUNC_HASH_a5\t%lld\n", (long long)SQLITE_FUNC_HASH('a',5));
  {
    int i, empty = 1;
    for(i=0; i<SQLITE_FUNC_HASH_SZ; i++) if(sqlite3BuiltinFunctions.a[i]) empty = 0;
    printf("CONST\tBUILTIN_FUNCTIONS_EMPTY\t%d\n", empty);
  }
  CONSTANT(SAVEPOINT_BEGIN); CONSTANT(SAVEPOINT_RELEASE); CONSTANT(SAVEPOINT_ROLLBACK);
  printf("CONST\tSZ_DBCLIENTDATA_0\t%lld\n", (long long)SZ_DBCLIENTDATA(0));
  printf("CONST\tSZ_DBCLIENTDATA_1\t%lld\n", (long long)SZ_DBCLIENTDATA(1));
  printf("CONST\tSZ_DBCLIENTDATA_17\t%lld\n", (long long)SZ_DBCLIENTDATA(17));
  CONSTANT(SQLITE_FUNC_ENCMASK); CONSTANT(SQLITE_FUNC_LIKE); CONSTANT(SQLITE_FUNC_CASE);
  CONSTANT(SQLITE_FUNC_EPHEM); CONSTANT(SQLITE_FUNC_NEEDCOLL); CONSTANT(SQLITE_FUNC_LENGTH);
  CONSTANT(SQLITE_FUNC_TYPEOF); CONSTANT(SQLITE_FUNC_BYTELEN); CONSTANT(SQLITE_FUNC_COUNT);
  CONSTANT(SQLITE_FUNC_UNLIKELY); CONSTANT(SQLITE_FUNC_CONSTANT); CONSTANT(SQLITE_FUNC_MINMAX);
  CONSTANT(SQLITE_FUNC_SLOCHNG); CONSTANT(SQLITE_FUNC_TEST); CONSTANT(SQLITE_FUNC_RUNONLY);
  CONSTANT(SQLITE_FUNC_WINDOW); CONSTANT(SQLITE_FUNC_INTERNAL); CONSTANT(SQLITE_FUNC_DIRECT);
  CONSTANT(SQLITE_FUNC_UNSAFE); CONSTANT(SQLITE_FUNC_INLINE); CONSTANT(SQLITE_FUNC_BUILTIN);
  CONSTANT(SQLITE_FUNC_ANYORDER);
  CONSTANT(INLINEFUNC_coalesce); CONSTANT(INLINEFUNC_implies_nonnull_row);
  CONSTANT(INLINEFUNC_expr_implies_expr); CONSTANT(INLINEFUNC_expr_compare);
  CONSTANT(INLINEFUNC_affinity); CONSTANT(INLINEFUNC_iif); CONSTANT(INLINEFUNC_sqlite_offset);
  CONSTANT(INLINEFUNC_unlikely);
  CONSTANT(SQLITE_SO_ASC); CONSTANT(SQLITE_SO_DESC); CONSTANT(SQLITE_SO_UNDEFINED);
  CONSTANT(DB_SchemaLoaded); CONSTANT(DB_UnresetViews); CONSTANT(DB_ResetWanted);
  CONSTANT(LOOKASIDE_SMALL);
  lookaside_semantics();
  mem_macro_semantics();
  return 0;
}
