#include "sqlite3.c"
#include <stddef.h>
#include <stdio.h>

#define TYPE(T) printf("TYPE\t%s\t%zu\t%zu\n", #T, sizeof(T), _Alignof(T))
#define FIELD(T, F) printf("FIELD\t%s\t%s\t%zu\t%zu\n", #T, #F, offsetof(T, F), sizeof(((T*)0)->F))
#define FLEXFIELD(T, F) printf("FIELD\t%s\t%s\t%zu\t0\n", #T, #F, offsetof(T, F))
#define CONSTANT(C) printf("CONST\t%s\t%lld\n", #C, (long long)(C))

static void parse_flag(const char *name, int flag) {
  Parse value;
  unsigned char *bytes = (unsigned char*)&value;
  size_t i;
  memset(&value, 0, sizeof(value));
  switch(flag){
    case 0: value.disableTriggers=1; break;
    case 1: value.mayAbort=1; break;
    case 2: value.hasCompound=1; break;
    case 3: value.bReturning=1; break;
    case 4: value.bHasExists=1; break;
    case 5: value.colNamesSet=1; break;
    case 6: value.bHasWith=1; break;
    case 7: value.okConstFactor=1; break;
    case 8: value.checkSchema=1; break;
  }
  for(i=0; i<sizeof(value); i++) if(bytes[i]){
    printf("CONST\tPARSE_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tPARSE_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void expr_list_flag(const char *name, int flag) {
  struct ExprList_item value;
  unsigned char *bytes = (unsigned char*)&value;
  size_t i;
  memset(&value, 0, sizeof(value));
  switch(flag){
    case 0: value.fg.eEName=3; break;
    case 1: value.fg.done=1; break;
    case 2: value.fg.reusable=1; break;
    case 3: value.fg.bSorterRef=1; break;
    case 4: value.fg.bNulls=1; break;
    case 5: value.fg.bUsed=1; break;
    case 6: value.fg.bUsingTerm=1; break;
    case 7: value.fg.bNoExpand=1; break;
  }
  for(i=0; i<sizeof(value); i++) if(bytes[i]){
    printf("CONST\tEXPR_LIST_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tEXPR_LIST_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

static void src_flag(const char *name, int flag) {
  SrcItem value;
  unsigned char *bytes = (unsigned char*)&value;
  size_t i;
  memset(&value, 0, sizeof(value));
  switch(flag){
    case 0: value.fg.notIndexed=1; break;
    case 1: value.fg.isIndexedBy=1; break;
    case 2: value.fg.isSubquery=1; break;
    case 3: value.fg.isTabFunc=1; break;
    case 4: value.fg.isCorrelated=1; break;
    case 5: value.fg.isMaterialized=1; break;
    case 6: value.fg.viaCoroutine=1; break;
    case 7: value.fg.isRecursive=1; break;
    case 8: value.fg.fromDDL=1; break;
    case 9: value.fg.isCte=1; break;
    case 10: value.fg.notCte=1; break;
    case 11: value.fg.isUsing=1; break;
    case 12: value.fg.isOn=1; break;
    case 13: value.fg.isSynthUsing=1; break;
    case 14: value.fg.isNestedFrom=1; break;
    case 15: value.fg.rowidUsed=1; break;
    case 16: value.fg.fixedSchema=1; break;
    case 17: value.fg.hadSchema=1; break;
    case 18: value.fg.fromExists=1; break;
  }
  for(i=0; i<sizeof(value); i++) if(bytes[i]){
    printf("CONST\tSRC_%s_OFFSET\t%zu\n", name, i);
    printf("CONST\tSRC_%s_MASK\t%u\n", name, (unsigned)bytes[i]);
    return;
  }
}

int main(void) {
  TYPE(Token); FIELD(Token,z); FIELD(Token,n);
  TYPE(Expr); FIELD(Expr,op); FIELD(Expr,affExpr); FIELD(Expr,op2); FIELD(Expr,flags);
  FIELD(Expr,u); FIELD(Expr,pLeft); FIELD(Expr,pRight); FIELD(Expr,x); FIELD(Expr,nHeight);
  FIELD(Expr,iTable); FIELD(Expr,iColumn); FIELD(Expr,iAgg); FIELD(Expr,w); FIELD(Expr,pAggInfo); FIELD(Expr,y);
  CONSTANT(EXPR_FULLSIZE); CONSTANT(EXPR_REDUCEDSIZE); CONSTANT(EXPR_TOKENONLYSIZE);
  CONSTANT(EP_xIsSelect); CONSTANT(EP_TokenOnly); CONSTANT(EP_Leaf);
  CONSTANT(EP_WinFunc); CONSTANT(EP_Static); CONSTANT(TK_SELECT_COLUMN); CONSTANT(TK_FUNCTION);
  CONSTANT(TF_WithoutRowid); CONSTANT(TF_NoVisibleRowid); CONSTANT(TF_Strict);
  CONSTANT(OE_None); CONSTANT(OE_Rollback); CONSTANT(OE_Abort); CONSTANT(OE_Fail);
  CONSTANT(OE_Ignore); CONSTANT(OE_Replace); CONSTANT(OE_Default);
  CONSTANT(OE_Restrict); CONSTANT(OE_SetNull); CONSTANT(OE_SetDflt); CONSTANT(OE_Cascade);
  CONSTANT(SQLITE_SO_ASC); CONSTANT(SQLITE_SO_DESC); CONSTANT(SQLITE_SO_UNDEFINED);
  CONSTANT(SF_Distinct); CONSTANT(SF_All); CONSTANT(SF_Values); CONSTANT(SF_MultiValue);
  CONSTANT(JT_INNER);

  TYPE(Window); FIELD(Window,zName); FIELD(Window,zBase); FIELD(Window,pPartition); FIELD(Window,pOrderBy);
  FIELD(Window,eFrmType); FIELD(Window,eStart); FIELD(Window,eEnd); FIELD(Window,bImplicitFrame); FIELD(Window,eExclude);
  FIELD(Window,pStart); FIELD(Window,pEnd); FIELD(Window,ppThis); FIELD(Window,pNextWin); FIELD(Window,pFilter);
  FIELD(Window,pWFunc); FIELD(Window,iEphCsr); FIELD(Window,regAccum); FIELD(Window,regResult); FIELD(Window,csrApp);
  FIELD(Window,regApp); FIELD(Window,regPart); FIELD(Window,pOwner); FIELD(Window,nBufferCol); FIELD(Window,iArgCol);
  FIELD(Window,regOne); FIELD(Window,regStartRowid); FIELD(Window,regEndRowid); FIELD(Window,bExprArgs);

  TYPE(Trigger); FIELD(Trigger,zName); FIELD(Trigger,table); FIELD(Trigger,op); FIELD(Trigger,tr_tm);
  FIELD(Trigger,bReturning); FIELD(Trigger,pWhen); FIELD(Trigger,pColumns); FIELD(Trigger,pSchema);
  FIELD(Trigger,pTabSchema); FIELD(Trigger,step_list); FIELD(Trigger,pNext);
  TYPE(TriggerStep); FIELD(TriggerStep,op); FIELD(TriggerStep,orconf); FIELD(TriggerStep,pTrig);
  FIELD(TriggerStep,pSelect); FIELD(TriggerStep,pSrc); FIELD(TriggerStep,pWhere); FIELD(TriggerStep,pExprList);
  FIELD(TriggerStep,pIdList); FIELD(TriggerStep,pUpsert); FIELD(TriggerStep,zSpan); FIELD(TriggerStep,pNext); FIELD(TriggerStep,pLast);

  TYPE(Cte); FIELD(Cte,zName); FIELD(Cte,pCols); FIELD(Cte,pSelect); FIELD(Cte,zCteErr);
  FIELD(Cte,pUse); FIELD(Cte,eM10d);
  TYPE(With); FIELD(With,nCte); FIELD(With,bView); FIELD(With,pOuter); FLEXFIELD(With,a);
  CONSTANT(M10d_Yes); CONSTANT(M10d_Any); CONSTANT(M10d_No);

  TYPE(Upsert); FIELD(Upsert,pUpsertTarget); FIELD(Upsert,pUpsertTargetWhere);
  FIELD(Upsert,pUpsertSet); FIELD(Upsert,pUpsertWhere); FIELD(Upsert,pNextUpsert);
  FIELD(Upsert,isDoUpdate); FIELD(Upsert,isDup); FIELD(Upsert,pToFree); FIELD(Upsert,pUpsertIdx);
  FIELD(Upsert,pUpsertSrc); FIELD(Upsert,regData); FIELD(Upsert,iDataCur); FIELD(Upsert,iIdxCur);

  TYPE(Select); FIELD(Select,op); FIELD(Select,nSelectRow); FIELD(Select,selFlags);
  FIELD(Select,iLimit); FIELD(Select,iOffset); FIELD(Select,selId); FIELD(Select,pEList);
  FIELD(Select,pSrc); FIELD(Select,pWhere); FIELD(Select,pGroupBy); FIELD(Select,pHaving);
  FIELD(Select,pOrderBy); FIELD(Select,pPrior); FIELD(Select,pNext); FIELD(Select,pLimit);
  FIELD(Select,pWith); FIELD(Select,pWin); FIELD(Select,pWinDefn);

  TYPE(struct IdList_item); FIELD(struct IdList_item,zName);
  TYPE(IdList); FIELD(IdList,nId); FLEXFIELD(IdList,a);

  TYPE(struct ExprList_item); FIELD(struct ExprList_item,pExpr); FIELD(struct ExprList_item,zEName);
  FIELD(struct ExprList_item,fg); FIELD(struct ExprList_item,u);
  TYPE(ExprList); FIELD(ExprList,nExpr); FIELD(ExprList,nAlloc); FLEXFIELD(ExprList,a);
  TYPE(Subquery); FIELD(Subquery,pSelect); FIELD(Subquery,addrFillSub); FIELD(Subquery,regReturn); FIELD(Subquery,regResult);
  TYPE(OnOrUsing); FIELD(OnOrUsing,pOn); FIELD(OnOrUsing,pUsing);
  TYPE(struct TrigEvent); FIELD(struct TrigEvent,a); FIELD(struct TrigEvent,b);
  TYPE(struct FrameBound); FIELD(struct FrameBound,eType); FIELD(struct FrameBound,pExpr);
  TYPE(YYMINORTYPE); FIELD(YYMINORTYPE,yyinit); FIELD(YYMINORTYPE,yy0); FIELD(YYMINORTYPE,yy14);
  FIELD(YYMINORTYPE,yy59); FIELD(YYMINORTYPE,yy67); FIELD(YYMINORTYPE,yy122); FIELD(YYMINORTYPE,yy132);
  FIELD(YYMINORTYPE,yy144); FIELD(YYMINORTYPE,yy168); FIELD(YYMINORTYPE,yy203); FIELD(YYMINORTYPE,yy211);
  FIELD(YYMINORTYPE,yy269); FIELD(YYMINORTYPE,yy286); FIELD(YYMINORTYPE,yy383); FIELD(YYMINORTYPE,yy391);
  FIELD(YYMINORTYPE,yy427); FIELD(YYMINORTYPE,yy454); FIELD(YYMINORTYPE,yy462); FIELD(YYMINORTYPE,yy509);
  FIELD(YYMINORTYPE,yy555);

  TYPE(SrcItem); FIELD(SrcItem,zName); FIELD(SrcItem,zAlias); FIELD(SrcItem,pSTab); FIELD(SrcItem,fg);
  FIELD(SrcItem,iCursor); FIELD(SrcItem,colUsed); FIELD(SrcItem,u1); FIELD(SrcItem,u2); FIELD(SrcItem,u3); FIELD(SrcItem,u4);
  TYPE(SrcList); FIELD(SrcList,nSrc); FIELD(SrcList,nAlloc); FLEXFIELD(SrcList,a);
  CONSTANT(SZ_SRCLIST_1);

  TYPE(ParseCleanup); FIELD(ParseCleanup,pNext); FIELD(ParseCleanup,pPtr); FIELD(ParseCleanup,xCleanup);
  TYPE(Parse);
  FIELD(Parse,db); FIELD(Parse,zErrMsg); FIELD(Parse,pVdbe); FIELD(Parse,rc); FIELD(Parse,nQueryLoop);
  FIELD(Parse,nested); FIELD(Parse,nTempReg); FIELD(Parse,isMultiWrite); FIELD(Parse,disableLookaside);
  FIELD(Parse,prepFlags); FIELD(Parse,withinRJSubrtn); FIELD(Parse,mSubrtnSig); FIELD(Parse,eTriggerOp); FIELD(Parse,eOrconf);
  FIELD(Parse,nRangeReg); FIELD(Parse,iRangeReg); FIELD(Parse,nErr); FIELD(Parse,nTab); FIELD(Parse,nMem);
  FIELD(Parse,szOpAlloc); FIELD(Parse,iSelfTab); FIELD(Parse,nNestSel); FIELD(Parse,nLabel); FIELD(Parse,nLabelAlloc);
  FIELD(Parse,aLabel); FIELD(Parse,pConstExpr); FIELD(Parse,pIdxEpr); FIELD(Parse,pIdxPartExpr);
  FIELD(Parse,writeMask); FIELD(Parse,cookieMask); FIELD(Parse,nMaxArg); FIELD(Parse,nSelect); FIELD(Parse,nProgressSteps);
  FIELD(Parse,nTableLock); FIELD(Parse,aTableLock); FIELD(Parse,pAinc); FIELD(Parse,pToplevel); FIELD(Parse,pTriggerTab);
  FIELD(Parse,pTriggerPrg); FIELD(Parse,pCleanup); FIELD(Parse,aTempReg); FIELD(Parse,pOuterParse); FIELD(Parse,sNameToken);
  FIELD(Parse,oldmask); FIELD(Parse,newmask); FIELD(Parse,u1); FIELD(Parse,sLastToken); FIELD(Parse,nVar);
  FIELD(Parse,iPkSortOrder); FIELD(Parse,explain); FIELD(Parse,eParseMode); FIELD(Parse,nVtabLock); FIELD(Parse,nHeight);
  FIELD(Parse,addrExplain); FIELD(Parse,pVList); FIELD(Parse,pReprepare); FIELD(Parse,zTail); FIELD(Parse,pNewTable);
  FIELD(Parse,pNewIndex); FIELD(Parse,pNewTrigger); FIELD(Parse,zAuthContext); FIELD(Parse,sArg); FIELD(Parse,apVtabLock);
  FIELD(Parse,pWith); FIELD(Parse,pRename);
  CONSTANT(PARSE_HDR_SZ); CONSTANT(PARSE_RECURSE_SZ); CONSTANT(PARSE_TAIL_SZ);

  expr_list_flag("EENAME",0); expr_list_flag("DONE",1); expr_list_flag("REUSABLE",2);
  expr_list_flag("SORTER_REF",3); expr_list_flag("NULLS",4); expr_list_flag("USED",5);
  expr_list_flag("USING_TERM",6); expr_list_flag("NO_EXPAND",7);
  parse_flag("DISABLE_TRIGGERS",0); parse_flag("MAY_ABORT",1); parse_flag("HAS_COMPOUND",2);
  parse_flag("RETURNING",3); parse_flag("HAS_EXISTS",4); parse_flag("COL_NAMES_SET",5);
  parse_flag("HAS_WITH",6); parse_flag("OK_CONST_FACTOR",7); parse_flag("CHECK_SCHEMA",8);
  src_flag("NOT_INDEXED",0); src_flag("IS_INDEXED_BY",1); src_flag("IS_SUBQUERY",2);
  src_flag("IS_TAB_FUNC",3); src_flag("IS_CORRELATED",4); src_flag("IS_MATERIALIZED",5);
  src_flag("VIA_COROUTINE",6); src_flag("IS_RECURSIVE",7); src_flag("FROM_DDL",8);
  src_flag("IS_CTE",9); src_flag("NOT_CTE",10); src_flag("IS_USING",11); src_flag("IS_ON",12);
  src_flag("IS_SYNTH_USING",13); src_flag("IS_NESTED_FROM",14); src_flag("ROWID_USED",15);
  src_flag("FIXED_SCHEMA",16); src_flag("HAD_SCHEMA",17); src_flag("FROM_EXISTS",18);
  return 0;
}
