#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static sqlite3_mem_methods baseMethods;
static int failNextAllocation = 0;
static int failAllocationCountdown = 0;
static int failStickyAllocation = 0;
static int progressReturn = 0;
static int progressCalls = 0;
static int vtabDisconnectCalls = 0;
static int moduleDestroyCalls = 0;
static int testVtabDisconnect(sqlite3_vtab *p){ (void)p; vtabDisconnectCalls++; return SQLITE_OK; }
static void testModuleDestroy(void *p){ (void)p; moduleDestroyCalls++; }
static VdbeOp *detachedOperations = 0;
static int detachedOperationCount = 0;
static int progressCallback(void *p){ (void)p; progressCalls++; return progressReturn; }

static int shouldFail(void){
  if( failStickyAllocation ) return 1;
  if( failAllocationCountdown>0 && --failAllocationCountdown==0 ) return 1;
  if( failNextAllocation ){
    failNextAllocation = 0;
    return 1;
  }
  return 0;
}
static void *faultMalloc(int n){
  return shouldFail() ? 0 : baseMethods.xMalloc(n);
}
static void faultFree(void *p){ baseMethods.xFree(p); }
static void *faultRealloc(void *p, int n){
  return shouldFail() ? 0 : baseMethods.xRealloc(p,n);
}
static int faultSize(void *p){ return baseMethods.xSize(p); }
static int faultRoundup(int n){ return baseMethods.xRoundup(n); }
static int faultInit(void *p){
  (void)p;
  return baseMethods.xInit ? baseMethods.xInit(baseMethods.pAppData) : SQLITE_OK;
}
static void faultShutdown(void *p){
  (void)p;
  if( baseMethods.xShutdown ) baseMethods.xShutdown(baseMethods.pAppData);
}

static int lookasideContains(sqlite3 *db, void *p){
  LookasideSlot *slot; int guard=0;
  for(slot=db->lookaside.pFree;slot && guard++<1000;slot=slot->pNext) if((void*)slot==p)return 1;
  guard=0; for(slot=db->lookaside.pSmallFree;slot && guard++<1000;slot=slot->pNext) if((void*)slot==p)return 1;
  return 0;
}

static int opcode(const char *z){
  if( strcmp(z,"Init")==0 ) return OP_Init;
  if( strcmp(z,"Integer")==0 ) return OP_Integer;
  if( strcmp(z,"Goto")==0 ) return OP_Goto;
  if( strcmp(z,"Add")==0 ) return OP_Add;
  if( strcmp(z,"OpenRead")==0 ) return OP_OpenRead;
  if( strcmp(z,"Transaction")==0 ) return OP_Transaction;
  if( strcmp(z,"VFilter")==0 ) return OP_VFilter;
  if( strcmp(z,"VUpdate")==0 ) return OP_VUpdate;
  if( strcmp(z,"Column")==0 ) return OP_Column;
  if( strcmp(z,"Once")==0 ) return OP_Once;
  if( strcmp(z,"Noop")==0 ) return OP_Noop;
  return -1;
}

static void clearCreated(sqlite3 *db){
  while( db->pVdbe ) sqlite3VdbeDelete(db->pVdbe);
}

static void clearMachine(sqlite3 *db, Parse *pParse, Vdbe *v){
  clearCreated(db);
  if( detachedOperations ) vdbeFreeOpArray(db,detachedOperations,detachedOperationCount);
  detachedOperations=0; detachedOperationCount=0;
  if( db->mallocFailed ) sqlite3OomClear(db);
  vdbeFreeOpArray(db,v->aOp,v->nOp);
  sqlite3DbFree(db,v->zErrMsg);
  sqlite3DbFree(db,pParse->aLabel);
  db->xProgress=0; db->pProgressArg=0; db->nProgressOps=0;
  AtomicStore(&db->u1.isInterrupted,0);
  progressReturn=0; progressCalls=0;
  failNextAllocation=0; failAllocationCountdown=0; failStickyAllocation=0;
  db->lookaside.bDisable=0; db->lookaside.sz=db->lookaside.szTrue;
  memset(pParse,0,sizeof(*pParse));
  memset(v,0,sizeof(*v));
  pParse->db=db;
  db->pParse=pParse;
  v->db=db;
  v->pParse=pParse;
}

static void observation(const char *zCase, int i, int addr, int nOpBefore, Vdbe *v, Parse *pParse){
  if( v->nOp==nOpBefore+1 && addr==nOpBefore ){
    VdbeOp *p=&v->aOp[addr];
    int p4 = p->p4type==P4_INT32 ? p->p4.i : 0;
    printf("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
      zCase,i,addr,v->nOp,v->nOpAlloc,pParse->szOpAlloc,v->db->mallocFailed,
      pParse->nErr,pParse->rc,v->db->errByteOffset,
      p->opcode,p->p1,p->p2,p->p3,p->p5,p->p4type,p4);
  }else{
    printf("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\tNONE\n",
      zCase,i,addr,v->nOp,v->nOpAlloc,pParse->szOpAlloc,v->db->mallocFailed,
      pParse->nErr,pParse->rc,v->db->errByteOffset);
  }
}

int main(int argc, char **argv){
  sqlite3 *db=0; Parse parse; Vdbe v; FILE *in; char line[256]; char zCase[64]="none"; int seq=0;
  int labels[256]; int nLabels=0;
  Parse createParse[2]; KeyInfo *keyInfo=0; sqlite3_vtab publicVtab; Db testDbs[3]; Btree testBtrees[3];
  sqlite3_mem_methods faultMethods;
  if( argc!=2 ) return 2;
  in=fopen(argv[1],"rb"); if( in==0 ) return 3;
  if( sqlite3_config(SQLITE_CONFIG_GETMALLOC,&baseMethods)!=SQLITE_OK ) return 4;
  faultMethods=baseMethods;
  faultMethods.xMalloc=faultMalloc; faultMethods.xFree=faultFree;
  faultMethods.xRealloc=faultRealloc; faultMethods.xSize=faultSize;
  faultMethods.xRoundup=faultRoundup; faultMethods.xInit=faultInit;
  faultMethods.xShutdown=faultShutdown; faultMethods.pAppData=0;
  if( sqlite3_config(SQLITE_CONFIG_MALLOC,&faultMethods)!=SQLITE_OK ) return 5;
  if( sqlite3_open(":memory:",&db)!=SQLITE_OK ) return 6;
  memset(&parse,0,sizeof(parse)); memset(&v,0,sizeof(v)); memset(createParse,0,sizeof(createParse)); memset(&publicVtab,0,sizeof(publicVtab)); memset(testDbs,0,sizeof(testDbs)); memset(testBtrees,0,sizeof(testBtrees)); parse.db=db; db->pParse=&parse; v.db=db; v.pParse=&parse;
  while( fgets(line,sizeof(line),in) ){
    char command[32], name[64]; int a=0,b=0,c=0,d=0,n=0,addr=-1,op=-1,before;
    if( sscanf(line,"%31s",command)!=1 ) continue;
    if( strcmp(command,"CASE")==0 ){
      while(keyInfo) { if(keyInfo->nRef==1){ sqlite3KeyInfoUnref(keyInfo); keyInfo=0; }else sqlite3KeyInfoUnref(keyInfo); }
      sqlite3_free(publicVtab.zErrMsg); publicVtab.zErrMsg=0;
      clearMachine(db,&parse,&v); memset(createParse,0,sizeof(createParse)); sscanf(line,"%*s %63s",zCase); seq=0; nLabels=0; continue;
    }
    if( strcmp(command,"LIMIT")==0 ){
      sscanf(line,"%*s %d",&n); db->aLimit[SQLITE_LIMIT_VDBE_OP]=n;
      printf("%s\t%d\tLIMIT\t%d\n",zCase,seq++,n); continue;
    }
    if( strcmp(command,"FAILNEXT")==0 ){
      failNextAllocation=1;
      printf("%s\t%d\tFAILNEXT\n",zCase,seq++); continue;
    }
    if( strcmp(command,"FAILIN")==0 ){
      sscanf(line,"%*s %d",&n); failAllocationCountdown=n;
      printf("%s\t%d\tFAILIN\t%d\n",zCase,seq++,n); continue;
    }
    if( strcmp(command,"FAILSTICKY")==0 ){
      failStickyAllocation=1;
      printf("%s\t%d\tFAILSTICKY\n",zCase,seq++); continue;
    }
    if( strcmp(command,"CLEARFAULT")==0 ){
      failNextAllocation=0; failAllocationCountdown=0; failStickyAllocation=0;
      if( db->mallocFailed ) sqlite3OomClear(db);
      printf("%s\t%d\tCLEARFAULT\n",zCase,seq++); continue;
    }
    if( strcmp(command,"LOOKASIDE")==0 ){
      sscanf(line,"%*s %d",&n);
      db->lookaside.bDisable=(u8)n; db->lookaside.sz=n?0:db->lookaside.szTrue;
      printf("%s\t%d\tLOOKASIDE\t%d\n",zCase,seq++,n); continue;
    }
    if( strcmp(command,"CREATE")==0 ){
      Vdbe *oldHead, *made; int hasInit=-1, initOpcode=-1, initP1=-1, initP2=-1;
      sscanf(line,"%*s %d",&n); if(n<0 || n>=2)return 9;
      createParse[n].db=db; db->pParse=&createParse[n]; oldHead=db->pVdbe;
      made=sqlite3VdbeCreate(&createParse[n]);
      if( made && made->nOp>0 ){
        hasInit=1; initOpcode=made->aOp[0].opcode; initP1=made->aOp[0].p1; initP2=made->aOp[0].p2;
      }else if( made ) hasInit=0;
      printf("%s\t%d\tCREATE\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        zCase,seq++,n,made!=0,db->pVdbe==made,createParse[n].pVdbe==made,made && sqlite3VdbeParser(made)==&createParse[n],
        made?made->nOp:-1,made?made->nOpAlloc:-1,hasInit,initOpcode,initP1,initP2,made?made->eVdbeState:-1,
        made?made->pVNext==oldHead:0,made?made->ppVPrev==&db->pVdbe:0,oldHead?oldHead->ppVPrev==&made->pVNext:1,
        db->mallocFailed,createParse[n].nErr,createParse[n].rc);
      continue;
    }
    if( strcmp(command,"READY")==0 ){
      Vdbe *made; int nv,nm,nc,na,multi,mayAbort,explain,hasList,csrNull=1;
      sscanf(line,"%*s %d %d %d %d %d %d %d %d %d",&n,&nv,&nm,&nc,&na,&multi,&mayAbort,&explain,&hasList);
      if(n<0 || n>=2 || createParse[n].pVdbe==0)return 10;
      made=createParse[n].pVdbe; createParse[n].nVar=(ynVar)nv; createParse[n].nMem=nm; createParse[n].nTab=nc;
      createParse[n].nMaxArg=na; createParse[n].isMultiWrite=(u8)multi; createParse[n].mayAbort=mayAbort; createParse[n].explain=(u8)explain;
      if(hasList) createParse[n].pVList=sqlite3DbMallocRawNN(db,8);
      sqlite3VdbeMakeReady(made,&createParse[n]);
      for(a=0;a<made->nCursor;a++) if(made->apCsr[a]) csrNull=0;
      printf("%s\t%d\tREADY\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        zCase,seq++,n,made->nVar,made->nMem,made->nCursor,made->aMem!=0,made->aVar!=0,made->apArg!=0,made->apCsr!=0,made->pFree!=0,
        made->eVdbeState,made->pc,made->rc,(long long)made->nChange,made->errorAction,made->cacheCtr,made->minWriteFileFormat,(long long)made->nFkConstraint,
        made->iStatement,made->usesStmtJournal,made->explain,made->nResColumn,made->expired,
        made->nVar?made->aVar[0].flags:-1,made->nVar?made->aVar[0].db==db:0,made->nVar?made->aVar[0].szMalloc:-1,
        made->nMem?made->aMem[0].flags:-1,made->nMem?made->aMem[0].db==db:0,made->nMem?made->aMem[0].szMalloc:-1,
        csrNull,made->readOnly,made->bIsReader,db->mallocFailed,createParse[n].nLabel,createParse[n].aLabel!=0,made->pVList!=0,createParse[n].pVList!=0);
      continue;
    }
    if( strcmp(command,"FILL")==0 ){
      sscanf(line,"%*s %d %63s",&n,name); op=opcode(name); if(op<0)return 7;
      for(a=0;a<n;a++){
        int before=v.nOp;
        addr=sqlite3VdbeAddOp0(&v,op);
        observation(zCase,seq++,addr,before,&v,&parse);
      }
      continue;
    }
    if( strcmp(command,"MAKELABELS")==0 ){
      sscanf(line,"%*s %d",&n);
      for(a=0;a<n;a++) labels[nLabels++]=sqlite3VdbeMakeLabel(&parse);
      printf("%s\t%d\tMAKELABELS\t%d\t%d\t%d\n",zCase,seq++,nLabels,labels[nLabels-1],parse.nLabelAlloc);
      continue;
    }
    if( strcmp(command,"RESOLVE")==0 ){
      sscanf(line,"%*s %d",&a); sqlite3VdbeResolveLabel(&v,labels[a]);
      b=(parse.aLabel && parse.nLabelAlloc>ADDR(labels[a])) ? parse.aLabel[ADDR(labels[a])] : -999;
      printf("%s\t%d\tRESOLVE\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,v.nOp,parse.nLabel,parse.nLabelAlloc,parse.aLabel!=0,b,db->mallocFailed,parse.nErr,parse.rc,parse.nProgressSteps);
      continue;
    }
    if( strcmp(command,"PROGRESS")==0 ){
      sscanf(line,"%*s %d %d",&a,&b); db->nProgressOps=a; progressReturn=b; progressCalls=0; db->xProgress=progressCallback;
      printf("%s\t%d\tPROGRESS\t%d\t%d\n",zCase,seq++,a,b); continue;
    }
    if( strcmp(command,"INTERRUPT")==0 ){
      sscanf(line,"%*s %d",&a); AtomicStore(&db->u1.isInterrupted,a);
      printf("%s\t%d\tINTERRUPT\t%d\n",zCase,seq++,a); continue;
    }
    if( strcmp(command,"REUSABLE")==0 ){
      sqlite3VdbeReusable(&v);
      printf("%s\t%d\tREUSABLE\t%d\n",zCase,seq++,v.nOp>1?v.aOp[1].opcode:-1); continue;
    }
    if( strcmp(command,"GOTO")==0 ){
      sscanf(line,"%*s %d",&a); before=v.nOp; addr=sqlite3VdbeGoto(&v,a); observation(zCase,seq++,addr,before,&v,&parse); continue;
    }
    if( strcmp(command,"EXPLAINPARENT")==0 ){
      sscanf(line,"%*s %d %d",&a,&b); parse.addrExplain=0; c=sqlite3VdbeExplainParent(&parse); v.aOp[a].p2=b; parse.pVdbe=&v; parse.addrExplain=a; d=sqlite3VdbeExplainParent(&parse); sqlite3VdbeExplainPop(&parse);
      printf("%s\t%d\tEXPLAINPARENT\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,b,c,d,parse.addrExplain); continue;
    }
    if( strcmp(command,"CURRENT")==0 ){
      printf("%s\t%d\tCURRENT\t%d\n",zCase,seq++,sqlite3VdbeCurrentAddr(&v)); continue;
    }
    if( strcmp(command,"GET")==0 ){
      VdbeOp *got; sscanf(line,"%*s %d",&a); got=sqlite3VdbeGetOp(&v,a);
      printf("%s\t%d\tGET\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,got->opcode,got->p1,got->p2,got->p3,got->p5,got->p4type,v.aOp && a>=0 && a<v.nOp && got==&v.aOp[a]); continue;
    }
    if( strcmp(command,"MUTATE")==0 ){
      sscanf(line,"%*s %d %63s %d %d %d",&a,name,&b,&c,&d); op=opcode(name);
      sqlite3VdbeChangeOpcode(&v,a,op); sqlite3VdbeChangeP1(&v,a,b); sqlite3VdbeChangeP2(&v,a,c); sqlite3VdbeChangeP3(&v,a,d);
      printf("%s\t%d\tMUTATE\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,v.aOp[a].opcode,v.aOp[a].p1,v.aOp[a].p2,v.aOp[a].p3); continue;
    }
    if( strcmp(command,"P5")==0 ){
      sscanf(line,"%*s %d",&a); sqlite3VdbeChangeP5(&v,(u16)a);
      printf("%s\t%d\tP5\t%d\t%d\n",zCase,seq++,a,v.nOp?v.aOp[v.nOp-1].p5:-1); continue;
    }
    if( strcmp(command,"TYPEOF")==0 ){
      sscanf(line,"%*s %d",&a); sqlite3VdbeTypeofColumn(&v,a);
      printf("%s\t%d\tTYPEOF\t%d\t%d\n",zCase,seq++,a,v.aOp[v.nOp-1].p5); continue;
    }
    if( strcmp(command,"JUMPHERE")==0 ){
      sscanf(line,"%*s %d",&a); sqlite3VdbeJumpHere(&v,a);
      printf("%s\t%d\tJUMPHERE\t%d\t%d\n",zCase,seq++,a,v.aOp[a].p2); continue;
    }
    if( strcmp(command,"JUMPPOP")==0 ){
      sscanf(line,"%*s %d",&a); sqlite3VdbeJumpHereOrPopInst(&v,a);
      printf("%s\t%d\tJUMPPOP\t%d\t%d\t%d\n",zCase,seq++,a,v.nOp,a<v.nOp?v.aOp[a].p2:-1); continue;
    }
    if( strcmp(command,"OOMFAULT")==0 ){
      sqlite3OomFault(db); printf("%s\t%d\tOOMFAULT\t%d\n",zCase,seq++,db->mallocFailed); continue;
    }
    if( strcmp(command,"BIND")==0 ){
      Vdbe *made; sscanf(line,"%*s %d %d %d",&a,&b,&c); made=createParse[a].pVdbe; if(!made || b<1 || b>made->nVar)return 16;
      if(c) sqlite3VdbeMemSetInt64(&made->aVar[b-1],c); else sqlite3VdbeMemSetNull(&made->aVar[b-1]);
      printf("%s\t%d\tBIND\t%d\t%d\t%d\t%d\n",zCase,seq++,a,b,made->aVar[b-1].flags,c); continue;
    }
    if( strcmp(command,"BOUND")==0 ){
      Vdbe *made; sqlite3_value *value; sscanf(line,"%*s %d %d",&a,&b); made=createParse[a].pVdbe; if(!made)return 17;
      value=sqlite3VdbeGetBoundValue(made,b,SQLITE_AFF_INTEGER);
      printf("%s\t%d\tBOUND\t%d\t%d\t%d\t%d\t%lld\t%d\n",zCase,seq++,a,b,value!=0,value?((Mem*)value)->flags:-1,value?(long long)((Mem*)value)->u.i:0,db->mallocFailed);
      sqlite3ValueFree(value); continue;
    }
    if( strcmp(command,"VARMASK")==0 ){
      Vdbe *made; sscanf(line,"%*s %d %d",&a,&b); made=createParse[a].pVdbe; if(!made)return 18; sqlite3VdbeSetVarmask(made,b);
      printf("%s\t%d\tVARMASK\t%d\t%d\t%u\n",zCase,seq++,a,b,made->expmask); continue;
    }
    if( strcmp(command,"USEBTREE")==0 ){
      Db *savedDbs=db->aDb; int savedNDb=db->nDb; sscanf(line,"%*s %d %d",&a,&b); db->aDb=testDbs; db->nDb=3; testDbs[a].pBt=&testBtrees[a]; testBtrees[a].db=db; testBtrees[a].sharable=(u8)b;
      c=sqlite3BtreeSharable(&testBtrees[a]); sqlite3VdbeUsesBtree(&v,a); db->aDb=savedDbs; db->nDb=savedNDb;
      printf("%s\t%d\tUSEBTREE\t%d\t%d\t%d\t%u\t%u\n",zCase,seq++,a,b,c,(unsigned)v.btreeMask,(unsigned)v.lockMask); continue;
    }
    if( strcmp(command,"UNPACKALLOC")==0 ){
      KeyInfo info; UnpackedRecord *record; memset(&info,0,sizeof(info)); sscanf(line,"%*s %d",&a); info.db=db; info.nKeyField=(u16)a; record=sqlite3VdbeAllocUnpackedRecord(&info);
      printf("%s\t%d\tUNPACKALLOC\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,record!=0,record?record->nField:-1,record&&record->pKeyInfo==&info,record&&record->aMem==(Mem*)&((char*)record)[ROUND8P(sizeof(UnpackedRecord))],db->mallocFailed); sqlite3DbFree(db,record); continue;
    }
    if( strcmp(command,"UNPACK")==0 ){
      static const unsigned char recordBytes[9]={5,1,2,15,0,0xff,0x80,0x01,'A'}; KeyInfo info; UnpackedRecord *record; u64 r0=0,r1=0,r2=0,r3=0; memset(&info,0,sizeof(info)); info.db=db; info.enc=SQLITE_UTF8; info.nKeyField=3; record=sqlite3VdbeAllocUnpackedRecord(&info); if(!record)return 19; sqlite3VdbeRecordUnpack(9,recordBytes,record); memcpy(&r0,&record->aMem[0].u,8);memcpy(&r1,&record->aMem[1].u,8);memcpy(&r2,&record->aMem[2].u,8);memcpy(&r3,&record->aMem[3].u,8);
      printf("%s\t%d\tUNPACK\t%d\t%d\t%d\t%llu\t%d\t%llu\t%d\t%d\t%llu\t%d\t%d\t%llu\n",zCase,seq++,record->nField,record->default_rc,record->aMem[0].flags,(unsigned long long)r0,record->aMem[1].flags,(unsigned long long)r1,record->aMem[2].flags,record->aMem[2].n,(unsigned long long)r2,record->aMem[3].flags,record->aMem[2].z==(char*)&recordBytes[8],(unsigned long long)r3); sqlite3DbFree(db,record); continue;
    }
    if( strcmp(command,"UNPACKTRUNC")==0 ){
      static const unsigned char recordBytes[11]={3,6,1,0x80,1,2,3,4,5,6,7}; KeyInfo info; UnpackedRecord *record; memset(&info,0,sizeof(info)); info.db=db; info.enc=SQLITE_UTF8; info.nKeyField=2; record=sqlite3VdbeAllocUnpackedRecord(&info); if(!record)return 20; sqlite3VdbeRecordUnpack(4,recordBytes,record);
      printf("%s\t%d\tUNPACKTRUNC\t%d\t%d\t%d\t%d\n",zCase,seq++,record->nField,record->default_rc,record->aMem[0].flags,record->aMem[0].szMalloc); sqlite3DbFree(db,record); continue;
    }
    if( strcmp(command,"SERIAL")==0 ){
      static const unsigned char bytes[8]={0x80,0x01,0x02,0x03,0x04,0x05,0x06,0x07}; Mem value; u64 raw=0; memset(&value,0,sizeof(value)); sscanf(line,"%*s %d",&a);
      sqlite3VdbeSerialGet(bytes,(u32)a,&value); memcpy(&raw,&value.u,8);
      printf("%s\t%d\tSERIAL\t%d\t%u\t%d\t%d\t%d\t%llu\t%d\n",zCase,seq++,a,sqlite3VdbeSerialTypeLen((u32)a),a<128?sqlite3VdbeOneByteSerialTypeLen((u8)a):-1,value.flags,value.n,(unsigned long long)raw,value.z==(char*)bytes); continue;
    }
    if( strcmp(command,"SERIAL7")==0 ){
      static const unsigned char finite[8]={0x3f,0xf0,0,0,0,0,0,0}; static const unsigned char nan[8]={0x7f,0xf8,0,0,0,0,0,1}; Mem value; u64 raw=0; const unsigned char *bytes; memset(&value,0,sizeof(value)); sscanf(line,"%*s %d",&a); bytes=a?nan:finite; b=serialGet7(bytes,&value); memcpy(&raw,&value.u,8);
      printf("%s\t%d\tSERIAL7\t%d\t%d\t%d\t%llu\n",zCase,seq++,a,b,value.flags,(unsigned long long)raw); continue;
    }
    if( strcmp(command,"FKSTATE")==0 ){
      sqlite3DbFree(db,v.zErrMsg); v.zErrMsg=sqlite3DbStrDup(db,"prior-error"); v.rc=55; v.errorAction=7;
      printf("%s\t%d\tFKSTATE\t%d\t%d\t%d\n",zCase,seq++,v.rc,v.errorAction,v.zErrMsg&&strcmp(v.zErrMsg,"prior-error")==0); continue;
    }
    if( strcmp(command,"FKCHECK")==0 ){
      sscanf(line,"%*s %63s %d %d %d",name,&a,&b,&c); v.prepFlags=(u8)c;
      if(name[0]=='I'){v.nFkConstraint=a; d=sqlite3VdbeCheckFkImmediate(&v);}else{db->nDeferredCons=a;db->nDeferredImmCons=b;d=sqlite3VdbeCheckFkDeferred(&v);}
      printf("%s\t%d\tFKCHECK\t%c\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,name[0],a,b,c,d,v.rc,v.errorAction,v.zErrMsg&&strcmp(v.zErrMsg,"FOREIGN KEY constraint failed")==0,db->mallocFailed); continue;
    }
    if( strcmp(command,"VERRSET")==0 ){
      sscanf(line,"%*s %d",&a); sqlite3_free(publicVtab.zErrMsg); publicVtab.zErrMsg=0; sqlite3DbFree(db,v.zErrMsg); v.zErrMsg=sqlite3DbStrDup(db,"old-error"); if(a)publicVtab.zErrMsg=sqlite3_mprintf("%s","new-error");
      printf("%s\t%d\tVERRSET\t%d\t%d\t%d\n",zCase,seq++,a,v.zErrMsg!=0,publicVtab.zErrMsg!=0); continue;
    }
    if( strcmp(command,"VIMPORT")==0 ){
      char *old=v.zErrMsg; sqlite3VtabImportErrmsg(&v,&publicVtab);
      printf("%s\t%d\tVIMPORT\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,publicVtab.zErrMsg==0,v.zErrMsg!=0,v.zErrMsg&&strcmp(v.zErrMsg,"new-error")==0,v.zErrMsg&&strcmp(v.zErrMsg,"old-error")==0,old!=v.zErrMsg&&lookasideContains(db,old)); continue;
    }
    if( strcmp(command,"COLCOUNT")==0 ){
      Vdbe *made; sscanf(line,"%*s %d %d",&a,&b); made=createParse[a].pVdbe; if(!made)return 14; sqlite3VdbeSetNumCols(made,b);
      printf("%s\t%d\tCOLCOUNT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,b,made->nResColumn,made->nResAlloc,made->aColName!=0,made->aColName?made->aColName[0].flags:-1,made->aColName?made->aColName[0].db==db:0,db->mallocFailed); continue;
    }
    if( strcmp(command,"COLNAME")==0 ){
      Vdbe *made; Mem *cell=0; const char *text=0; void (*destroy)(void*)=SQLITE_STATIC; char *dynamic=0;
      sscanf(line,"%*s %d %d %d %d",&a,&b,&c,&d); made=createParse[a].pVdbe; if(!made)return 15;
      if(d==0){text="alpha";destroy=SQLITE_STATIC;}else if(d==1){text="beta";destroy=SQLITE_TRANSIENT;}else{dynamic=sqlite3DbStrDup(db,"gamma");text=dynamic;destroy=SQLITE_DYNAMIC;}
      n=sqlite3VdbeSetColName(made,b,c,text,destroy); if(made->aColName)cell=&made->aColName[b+c*made->nResAlloc];
      printf("%s\t%d\tCOLNAME\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,b,c,d,n,cell?cell->flags:-1,cell&&cell->z?strcmp(cell->z,d==0?"alpha":d==1?"beta":"gamma")==0:0,cell?cell->z==(char*)text:0,cell&&cell->szMalloc?cell->zMalloc!=0:0); continue;
    }
    if( strcmp(command,"METADATA")==0 ){
      Vdbe *machineA=createParse[0].pVdbe,*machineB=createParse[1].pVdbe; i64 totalBefore=db->nTotalChange; if(!machineA || !machineB)return 13;
      sqlite3VdbeSetChanges(db,7); sqlite3VdbeCountChanges(machineA); sqlite3ExpirePreparedStatements(db,0); a=machineA->expired; b=machineB->expired;
      sqlite3ExpirePreparedStatements(db,1); machineA->prepFlags=37; machineA->rc=SQLITE_INTERRUPT; sqlite3VdbeResetStepResult(machineA);
      printf("%s\t%d\tMETADATA\t%lld\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,(long long)db->nChange,(long long)(db->nTotalChange-totalBefore),machineA->changeCntOn,a,b,machineA->expired,machineB->expired,sqlite3VdbeDb(machineA)==db,sqlite3VdbePrepareFlags(machineA),machineA->rc); continue;
    }
    if( strcmp(command,"APICOLUMNS")==0 ){
      Mem row[2]; const unsigned char *text; const void *blob; const void *text16; sqlite3_value *value; int countNull,countLive,dataNull,dataLive,integer,bytes,textType,bytes16,invalid,invalidCode;
      memset(row,0,sizeof(row)); sqlite3VdbeMemInit(&row[0],db,MEM_Null); sqlite3VdbeMemInit(&row[1],db,MEM_Null); sqlite3VdbeMemSetInt64(&row[0],42); sqlite3VdbeMemSetStr(&row[1],"text",4,SQLITE_UTF8,SQLITE_STATIC);
      v.pResultRow=row; v.nResColumn=2; countNull=sqlite3_column_count(0); countLive=sqlite3_column_count((sqlite3_stmt*)&v); dataNull=sqlite3_data_count(0); dataLive=sqlite3_data_count((sqlite3_stmt*)&v);
      integer=sqlite3_column_int((sqlite3_stmt*)&v,0); value=sqlite3_column_value((sqlite3_stmt*)&v,0); textType=sqlite3_column_type((sqlite3_stmt*)&v,1); text=sqlite3_column_text((sqlite3_stmt*)&v,1); bytes=sqlite3_column_bytes((sqlite3_stmt*)&v,1); blob=sqlite3_column_blob((sqlite3_stmt*)&v,1); text16=sqlite3_column_text16((sqlite3_stmt*)&v,1); bytes16=sqlite3_column_bytes16((sqlite3_stmt*)&v,1); invalid=sqlite3_column_int((sqlite3_stmt*)&v,9); invalidCode=db->errCode;
      printf("%s\t%d\tAPICOLUMNS\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,countNull,countLive,dataNull,dataLive,integer,value==&row[0],textType,text&&memcmp(text,"text",4)==0,bytes,blob!=0,text16!=0,bytes16,invalid,invalidCode);
      sqlite3VdbeMemRelease(&row[0]); sqlite3VdbeMemRelease(&row[1]); v.pResultRow=0; v.nResColumn=0; continue;
    }
    if( strcmp(command,"APIVLIST")==0 ){
      VList *list=0; const char *firstName; int firstIndex,secondIndex,missing;
      list=sqlite3VListAdd(db,list,":alpha",6,1); list=sqlite3VListAdd(db,list,"@beta",5,2); v.pVList=list; v.nVar=2;
      firstName=sqlite3_bind_parameter_name((sqlite3_stmt*)&v,1); firstIndex=sqlite3_bind_parameter_index((sqlite3_stmt*)&v,":alpha"); secondIndex=sqlite3VdbeParameterIndex(&v,"@beta",5); missing=sqlite3VdbeParameterIndex(&v,"$missing",8);
      printf("%s\t%d\tAPIVLIST\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,sqlite3_bind_parameter_count((sqlite3_stmt*)&v),firstName&&strcmp(firstName,":alpha")==0,firstIndex,secondIndex,missing,list!=0);
      sqlite3DbFree(db,list); v.pVList=0; v.nVar=0; continue;
    }
    if( strcmp(command,"APIVLISTOOM")==0 ){
      VList *list=0,*before; int retained,missing,oomState;
      db->lookaside.bDisable=1; db->lookaside.sz=0; list=sqlite3VListAdd(db,list,"alpha",5,1); list=sqlite3VListAdd(db,list,"beta",4,2); before=list; failNextAllocation=1; list=sqlite3VListAdd(db,list,"01234567890123456789",20,3);
      retained=list==before; missing=sqlite3VListNameToNum(list,"01234567890123456789",20); oomState=db->mallocFailed; if(db->mallocFailed)sqlite3OomClear(db); failNextAllocation=0;
      printf("%s\t%d\tAPIVLISTOOM\t%d\t%d\t%d\n",zCase,seq++,retained,missing,oomState); sqlite3DbFree(db,list); db->lookaside.bDisable=0; db->lookaside.sz=db->lookaside.szTrue; continue;
    }
    if( strcmp(command,"APIBINDINGS")==0 ){
      Vdbe from,to; Mem fromValues[2],toValues[2]; int directResult,deprecatedResult,clearResult;
      memset(&from,0,sizeof(from)); memset(&to,0,sizeof(to)); memset(fromValues,0,sizeof(fromValues)); memset(toValues,0,sizeof(toValues)); from.db=db; to.db=db; from.nVar=2; to.nVar=2; from.aVar=fromValues; to.aVar=toValues; from.prepFlags=SQLITE_PREPARE_SAVESQL; to.prepFlags=SQLITE_PREPARE_SAVESQL;
      sqlite3VdbeMemInit(&fromValues[0],db,MEM_Null); sqlite3VdbeMemInit(&fromValues[1],db,MEM_Null); sqlite3VdbeMemInit(&toValues[0],db,MEM_Null); sqlite3VdbeMemInit(&toValues[1],db,MEM_Null); sqlite3VdbeMemSetInt64(&fromValues[0],11); sqlite3VdbeMemSetInt64(&fromValues[1],22);
      directResult=sqlite3TransferBindings((sqlite3_stmt*)&from,(sqlite3_stmt*)&to); sqlite3VdbeMemSetInt64(&fromValues[0],33); sqlite3VdbeMemSetInt64(&fromValues[1],44); from.expmask=1; to.expmask=1; deprecatedResult=sqlite3_transfer_bindings((sqlite3_stmt*)&from,(sqlite3_stmt*)&to); clearResult=sqlite3_clear_bindings((sqlite3_stmt*)&to);
      printf("%s\t%d\tAPIBINDINGS\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,directResult,deprecatedResult,clearResult,from.expired,to.expired,fromValues[0].flags,toValues[0].flags,toValues[1].flags,to.expmask); continue;
    }
    if( strcmp(command,"APIMETA")==0 ){
      Vdbe second,finalized; const char *sqlText; int counterBefore,counterAfter;
      memset(&second,0,sizeof(second)); memset(&finalized,0,sizeof(finalized)); second.db=db; v.pVNext=&second; db->pVdbe=&v; v.readOnly=1; v.explain=2; v.eVdbeState=VDBE_RUN_STATE; v.expired=2; v.zSql="select 1"; v.aCounter[3]=17;
      counterBefore=sqlite3_stmt_status((sqlite3_stmt*)&v,3,1); counterAfter=sqlite3_stmt_status((sqlite3_stmt*)&v,3,0); sqlText=sqlite3_sql((sqlite3_stmt*)&v);
      printf("%s\t%d\tAPIMETA\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,sqlite3_expired((sqlite3_stmt*)&v),sqlite3_db_handle((sqlite3_stmt*)&v)==db,sqlite3_stmt_readonly((sqlite3_stmt*)&v),sqlite3_stmt_isexplain((sqlite3_stmt*)&v),sqlite3_stmt_busy((sqlite3_stmt*)&v),sqlite3_next_stmt(db,0)==&v,sqlite3_next_stmt(db,(sqlite3_stmt*)&v)==(sqlite3_stmt*)&second,counterBefore,counterAfter,sqlText&&strcmp(sqlText,"select 1")==0,vdbeSafety(&v),vdbeSafety(&finalized),vdbeSafetyNotNull(0));
      db->pVdbe=0; v.pVNext=0; v.readOnly=0; v.explain=0; v.expired=0; v.eVdbeState=VDBE_INIT_STATE; v.zSql=0; continue;
    }
    if( strcmp(command,"APIMEMUSED")==0 ){
      Parse ownerParse; Vdbe *owned; int measured,stillLinked;
      memset(&ownerParse,0,sizeof(ownerParse)); ownerParse.db=db; owned=sqlite3VdbeCreate(&ownerParse); sqlite3VdbeAddOp0(owned,OP_Noop); measured=sqlite3_stmt_status((sqlite3_stmt*)owned,SQLITE_STMTSTATUS_MEMUSED,0); stillLinked=db->pVdbe==owned&&owned->db==db;
      printf("%s\t%d\tAPIMEMUSED\t%d\t%d\n",zCase,seq++,measured>0,stillLinked); sqlite3VdbeDelete(owned); continue;
    }
    if( strcmp(command,"APIEXIT")==0 ){
      int masked,oomResult,oomState,errorCode; db->errMask=0xff; masked=sqlite3ApiExit(db,0x1234); sqlite3OomFault(db); oomResult=sqlite3ApiExit(db,0); oomState=db->mallocFailed; errorCode=db->errCode;
      printf("%s\t%d\tAPIEXIT\t%d\t%d\t%d\t%d\n",zCase,seq++,masked,oomResult,oomState,errorCode); continue;
    }
    if( strcmp(command,"SETSQLNULL")==0 ){
      sqlite3VdbeSetSql(0,"ignored",7,3); printf("%s\t%d\tSETSQLNULL\n",zCase,seq++); continue;
    }
    if( strcmp(command,"SETSQL")==0 ){
      Vdbe *made; sscanf(line,"%*s %d",&a); made=createParse[a].pVdbe; if(!made)return 12; made->expmask=55;
      sqlite3VdbeSetSql(made,"gamma",5,3); printf("%s\t%d\tSETSQL\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,made->prepFlags,made->zSql!=0,made->expmask,db->mallocFailed); continue;
    }
    if( strcmp(command,"SWAP")==0 ){
      Vdbe *machineA=createParse[0].pVdbe,*machineB=createParse[1].pVdbe; if(!machineA || !machineB)return 11;
      sqlite3VdbeSetSql(machineA,"alpha",5,3); sqlite3VdbeSetSql(machineB,"beta",4,4);
      machineA->aOp[0].p1=101; machineB->aOp[0].p1=202; machineA->expmask=11; machineB->expmask=22;
      machineA->aCounter[0]=10; machineA->aCounter[SQLITE_STMTSTATUS_REPREPARE]=1; machineB->aCounter[0]=20; machineB->aCounter[SQLITE_STMTSTATUS_REPREPARE]=2;
      sqlite3VdbeSwap(machineA,machineB);
      printf("%s\t%d\tSWAP\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,machineA->aOp[0].p1,machineB->aOp[0].p1,strcmp(machineA->zSql,"alpha")==0,strcmp(machineB->zSql,"beta")==0,machineA->expmask,machineB->expmask,machineA->prepFlags,machineB->prepFlags,machineA->aCounter[0],machineB->aCounter[0],machineA->aCounter[5],machineB->aCounter[5],db->pVdbe==machineB,machineB->pVNext==machineA,machineA->pVNext==0,machineA->pParse==&createParse[1],machineB->pParse==&createParse[0]); continue;
    }
    if( strcmp(command,"HASSUB")==0 ){
      printf("%s\t%d\tHASSUB\t%d\n",zCase,seq++,sqlite3VdbeHasSubProgram(&v)); continue;
    }
    if( strcmp(command,"LINKSUB")==0 ){
      SubProgram *first=sqlite3DbMallocRawNN(db,sizeof(SubProgram)); SubProgram *second=sqlite3DbMallocRawNN(db,sizeof(SubProgram));
      memset(first,0,sizeof(*first)); memset(second,0,sizeof(*second)); sqlite3VdbeLinkSubProgram(&v,first); sqlite3VdbeLinkSubProgram(&v,second);
      printf("%s\t%d\tLINKSUB\t%d\t%d\t%d\t%d\n",zCase,seq++,sqlite3VdbeHasSubProgram(&v),v.pProgram==second,second->pNext==first,first->pNext==0);
      v.pProgram=0; sqlite3DbNNFreeNN(db,second); sqlite3DbNNFreeNN(db,first); continue;
    }
    if( strcmp(command,"VTABOWNER")==0 ){
      int hasPublic,hasDestroy,moduleRefs,moduleFreed,moduleRefsAfter; sqlite3_module *publicModule; sqlite3_vtab *publicTable; Module *module; VTable *table;
      sscanf(line,"%*s %d %d %d",&hasPublic,&hasDestroy,&moduleRefs);
      publicModule=sqlite3DbMallocRawNN(db,sizeof(sqlite3_module)); publicTable=sqlite3DbMallocRawNN(db,sizeof(sqlite3_vtab));
      module=sqlite3DbMallocRawNN(db,sizeof(Module)); table=sqlite3DbMallocRawNN(db,sizeof(VTable));
      memset(publicModule,0,sizeof(*publicModule)); memset(publicTable,0,sizeof(*publicTable)); memset(module,0,sizeof(*module)); memset(table,0,sizeof(*table));
      publicModule->xDisconnect=testVtabDisconnect; publicTable->pModule=publicModule; module->pModule=publicModule; module->nRefModule=moduleRefs; if(hasDestroy)module->xDestroy=testModuleDestroy;
      table->db=db; table->pMod=module; if(hasPublic)table->pVtab=publicTable; table->nRef=1; vtabDisconnectCalls=0; moduleDestroyCalls=0;
      sqlite3VtabLock(table); a=table->nRef; sqlite3VtabUnlock(table); b=table->nRef; c=vtabDisconnectCalls; sqlite3VtabUnlock(table);
      moduleFreed=lookasideContains(db,module); moduleRefsAfter=moduleFreed?0:module->nRefModule;
      printf("%s\t%d\tVTABOWNER\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,hasPublic,hasDestroy,moduleRefs,a,b,c,vtabDisconnectCalls,moduleDestroyCalls,moduleFreed,moduleRefsAfter,lookasideContains(db,table));
      if(!moduleFreed)sqlite3VtabModuleUnref(db,module);
      sqlite3DbNNFreeNN(db,publicTable); sqlite3DbNNFreeNN(db,publicModule); continue;
    }
    if( strcmp(command,"FUNCFREE")==0 ){
      FuncDef *function; sscanf(line,"%*s %d",&a); function=sqlite3DbMallocRawNN(db,sizeof(FuncDef)); memset(function,0,sizeof(FuncDef));
      if(a) function->funcFlags|=SQLITE_FUNC_EPHEM; freeEphemeralFunction(db,function); b=lookasideContains(db,function);
      printf("%s\t%d\tFUNCFREE\t%d\t%d\n",zCase,seq++,a,b); if(!a)sqlite3DbNNFreeNN(db,function); continue;
    }
    if( strcmp(command,"FUNCCTXFREE")==0 ){
      FuncDef *function; sqlite3_context *context; sscanf(line,"%*s %d",&a);
      function=sqlite3DbMallocRawNN(db,sizeof(FuncDef)); context=sqlite3DbMallocRawNN(db,SZ_CONTEXT(0));
      memset(function,0,sizeof(FuncDef)); memset(context,0,SZ_CONTEXT(0)); if(a)function->funcFlags=SQLITE_FUNC_EPHEM; context->pFunc=function;
      freeP4FuncCtx(db,context); printf("%s\t%d\tFUNCCTXFREE\t%d\t%d\t%d\n",zCase,seq++,a,lookasideContains(db,function),lookasideContains(db,context));
      if(!a)sqlite3DbNNFreeNN(db,function); continue;
    }
    if( strcmp(command,"P4MEMFREE")==0 ){
      Mem *value; char *allocation=0; sscanf(line,"%*s %d",&a);
      value=sqlite3DbMallocRawNN(db,sizeof(Mem)); memset(value,0,sizeof(Mem));
      if(a){ allocation=sqlite3DbMallocRawNN(db,32); value->szMalloc=32; value->zMalloc=allocation; }
      freeP4Mem(db,value); printf("%s\t%d\tP4MEMFREE\t%d\t%d\t%d\n",zCase,seq++,a,lookasideContains(db,value),lookasideContains(db,allocation)); continue;
    }
    if( strcmp(command,"P4DYNAMIC")==0 ){
      void *owner=sqlite3DbMallocRawNN(db,32); freeP4(db,P4_DYNAMIC,owner);
      printf("%s\t%d\tP4DYNAMIC\t%d\n",zCase,seq++,lookasideContains(db,owner)); continue;
    }
    if( strcmp(command,"P4TABREF")==0 ){
      Table *table=sqlite3DbMallocZero(db,sizeof(Table)); int firstRef,firstFreed;
      table->nTabRef=2; freeP4(db,P4_TABLEREF,table); firstRef=table->nTabRef; firstFreed=lookasideContains(db,table); freeP4(db,P4_TABLEREF,table);
      printf("%s\t%d\tP4TABREF\t%d\t%d\t%d\n",zCase,seq++,firstRef,firstFreed,lookasideContains(db,table)); continue;
    }
    if( strcmp(command,"P4TABLEINDEX")==0 ){
      Schema schemaOwner; Table *table=sqlite3DbMallocZero(db,sizeof(Table)); Index *index=sqlite3DbMallocZero(db,sizeof(Index)); static char indexName[]="owned_idx";
      memset(&schemaOwner,0,sizeof(schemaOwner)); sqlite3HashInit(&schemaOwner.idxHash); table->nTabRef=1; table->pSchema=&schemaOwner; table->pIndex=index; index->zName=indexName; index->pTable=table; index->pSchema=&schemaOwner; sqlite3HashInsert(&schemaOwner.idxHash,indexName,index);
      freeP4(db,P4_TABLEREF,table); printf("%s\t%d\tP4TABLEINDEX\t%d\t%d\t%u\n",zCase,seq++,lookasideContains(db,index),lookasideContains(db,table),sqliteHashCount(&schemaOwner.idxHash)); sqlite3HashClear(&schemaOwner.idxHash); continue;
    }
    if( strcmp(command,"P4SUBSIG")==0 ){
      SubrtnSig *signature=sqlite3DbMallocZero(db,sizeof(SubrtnSig)); char *affinity=sqlite3DbMallocRawNN(db,16); signature->zAff=affinity;
      freeP4(db,P4_SUBRTNSIG,signature); printf("%s\t%d\tP4SUBSIG\t%d\t%d\n",zCase,seq++,lookasideContains(db,affinity),lookasideContains(db,signature)); continue;
    }
    if( strcmp(command,"P4NOOP")==0 ){
      void *owner=sqlite3DbMallocRawNN(db,32); int address=sqlite3VdbeAddOp0(&v,OP_Noop); v.aOp[address].p4type=P4_DYNAMIC; v.aOp[address].p4.p=owner;
      a=sqlite3VdbeChangeToNoop(&v,address); printf("%s\t%d\tP4NOOP\t%d\t%d\t%d\t%d\n",zCase,seq++,a,lookasideContains(db,owner),v.aOp[address].opcode,v.aOp[address].p4type); continue;
    }
    if( strcmp(command,"P4CHANGE")==0 ){
      static char staticText[]="stable"; void *dynamicOwner; void *oomOwner; int address; int oomAddress; int staticIdentity; int intValue; int dynamicType; int dynamicText; int dynamicDistinct; int dynamicFreed; int oomOwnerFreed; int oomOperationType; int oomState;
      address=sqlite3VdbeAddOp0(&v,OP_Noop); sqlite3VdbeChangeP4(&v,address,staticText,P4_STATIC); staticIdentity=v.aOp[address].p4.z==staticText;
      sqlite3VdbeChangeP4(&v,address,SQLITE_INT_TO_PTR(123456),P4_INT32); intValue=v.aOp[address].p4.i;
      sqlite3VdbeChangeP4(&v,-1,"alphabet",5); dynamicOwner=v.aOp[address].p4.p; dynamicType=v.aOp[address].p4type; dynamicText=strcmp(v.aOp[address].p4.z,"alpha")==0; dynamicDistinct=v.aOp[address].p4.z!=staticText;
      sqlite3VdbeChangeToNoop(&v,address); dynamicFreed=lookasideContains(db,dynamicOwner);
      oomAddress=sqlite3VdbeAddOp0(&v,OP_Noop); oomOwner=sqlite3DbMallocRawNN(db,32); sqlite3OomFault(db); sqlite3VdbeChangeP4(&v,oomAddress,oomOwner,P4_DYNAMIC);
      oomOwnerFreed=lookasideContains(db,oomOwner); oomOperationType=v.aOp[oomAddress].p4type; oomState=db->mallocFailed; sqlite3OomClear(db);
      printf("%s\t%d\tP4CHANGE\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,staticIdentity,intValue,dynamicType,dynamicText,dynamicDistinct,dynamicFreed,oomOwnerFreed,oomOperationType,oomState); continue;
    }
    if( strcmp(command,"P4CHANGEVTAB")==0 ){
      VTable table; int address; int afterLock; int pointerIdentity; int ownerType; int afterRelease;
      memset(&table,0,sizeof(table)); table.db=db; table.nRef=1; address=sqlite3VdbeAddOp0(&v,OP_Noop);
      sqlite3VdbeChangeP4(&v,address,(char*)&table,P4_VTAB); afterLock=table.nRef; pointerIdentity=v.aOp[address].p4.p==&table; ownerType=v.aOp[address].p4type;
      sqlite3VdbeChangeToNoop(&v,address); afterRelease=table.nRef;
      printf("%s\t%d\tP4CHANGEVTAB\t%d\t%d\t%d\t%d\n",zCase,seq++,afterLock,pointerIdentity,ownerType,afterRelease); continue;
    }
    if( strcmp(command,"P4APPEND")==0 ){
      void *normalOwner; void *oomOwner; int address; int oomAddress; int pointerIdentity; int ownerType; int normalFreed; int oomFreed; int oomOperationType; int oomState;
      address=sqlite3VdbeAddOp0(&v,OP_Noop); normalOwner=sqlite3DbMallocRawNN(db,32); sqlite3VdbeAppendP4(&v,normalOwner,P4_DYNAMIC);
      pointerIdentity=v.aOp[address].p4.p==normalOwner; ownerType=v.aOp[address].p4type; sqlite3VdbeChangeToNoop(&v,address); normalFreed=lookasideContains(db,normalOwner);
      oomAddress=sqlite3VdbeAddOp0(&v,OP_Noop); oomOwner=sqlite3DbMallocRawNN(db,32); sqlite3OomFault(db); sqlite3VdbeAppendP4(&v,oomOwner,P4_DYNAMIC);
      oomFreed=lookasideContains(db,oomOwner); oomOperationType=v.aOp[oomAddress].p4type; oomState=db->mallocFailed; sqlite3OomClear(db);
      printf("%s\t%d\tP4APPEND\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,pointerIdentity,ownerType,normalFreed,oomFreed,oomOperationType,oomState); continue;
    }
    if( strcmp(command,"P4FREEOPS")==0 ){
      Op *operations=sqlite3DbMallocZero(db,2*sizeof(Op)); void *first=sqlite3DbMallocRawNN(db,32); void *second=sqlite3DbMallocRawNN(db,32);
      operations[0].p4type=P4_DYNAMIC; operations[0].p4.p=first; operations[1].p4type=P4_DYNAMIC; operations[1].p4.p=second;
      vdbeFreeOpArray(db,operations,2); printf("%s\t%d\tP4FREEOPS\t%d\t%d\t%d\n",zCase,seq++,lookasideContains(db,first),lookasideContains(db,second),lookasideContains(db,operations)); continue;
    }
    if( strcmp(command,"VDBEDELETE")==0 ){
      Parse ownerParse; Vdbe *machine; void *p4Owner; void *operationArray; memset(&ownerParse,0,sizeof(ownerParse)); ownerParse.db=db;
      machine=sqlite3VdbeCreate(&ownerParse); a=sqlite3VdbeAddOp0(machine,OP_Noop); p4Owner=sqlite3DbMallocRawNN(db,32); machine->aOp[a].p4type=P4_DYNAMIC; machine->aOp[a].p4.p=p4Owner; operationArray=machine->aOp;
      sqlite3VdbeDelete(machine); printf("%s\t%d\tVDBEDELETE\t%d\t%d\t%d\t%d\n",zCase,seq++,lookasideContains(db,p4Owner),lookasideContains(db,operationArray),lookasideContains(db,machine),db->pVdbe==0); continue;
    }
    if( strcmp(command,"KEYNEW")==0 ){
      keyInfo=sqlite3DbMallocRawNN(db,SZ_KEYINFO(0)); if(keyInfo){ memset(keyInfo,0,SZ_KEYINFO(0)); keyInfo->nRef=1; keyInfo->db=db; }
      printf("%s\t%d\tKEYNEW\t%d\t%d\t%d\n",zCase,seq++,keyInfo!=0,keyInfo?keyInfo->nRef:0,keyInfo?keyInfo->db==db:0); continue;
    }
    if( strcmp(command,"KEYREF")==0 ){
      KeyInfo *before=keyInfo,*result=sqlite3KeyInfoRef(keyInfo);
      printf("%s\t%d\tKEYREF\t%d\t%d\t%d\n",zCase,seq++,result!=0,result==before,result?result->nRef:0); continue;
    }
    if( strcmp(command,"KEYUNREF")==0 ){
      int before=keyInfo?keyInfo->nRef:0; if(keyInfo){ if(before==1){sqlite3KeyInfoUnref(keyInfo);keyInfo=0;}else sqlite3KeyInfoUnref(keyInfo); }
      printf("%s\t%d\tKEYUNREF\t%d\t%d\t%d\n",zCase,seq++,before,keyInfo?keyInfo->nRef:0,keyInfo!=0); continue;
    }
    if( strcmp(command,"KEYNULL")==0 ){
      sqlite3KeyInfoUnref(0); printf("%s\t%d\tKEYNULL\t%d\n",zCase,seq++,sqlite3KeyInfoRef(0)!=0); continue;
    }
    if( strcmp(command,"FINALIZE")==0 ){
      sscanf(line,"%*s %d %d",&a,&b); resolveP2Values(&v,&a);
      printf("%s\t%d\tFINALIZE\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,b,v.aOp[b].p2,v.readOnly,v.bIsReader,parse.nLabel,parse.aLabel!=0);
      continue;
    }
    if( strcmp(command,"TAKE")==0 ){
      VdbeOp *beforeArray=v.aOp;
      sscanf(line,"%*s %d %d",&a,&b); detachedOperations=sqlite3VdbeTakeOpArray(&v,&detachedOperationCount,&a);
      printf("%s\t%d\tTAKE\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",zCase,seq++,a,b,detachedOperationCount,v.aOp==0,detachedOperations==beforeArray,detachedOperations[b].p2,parse.nLabel,parse.aLabel!=0);
      continue;
    }
    if( strcmp(command,"ADDLIST")==0 ){
      static const VdbeOpList list[]={{OP_Integer,7,0,1},{OP_Goto,0,1,0},{OP_Noop,0,0,0}};
      int base=v.nOp; VdbeOp *first=sqlite3VdbeAddOpList(&v,3,list,100);
      printf("%s\t%d\tADDLIST\t%d\t%d\t%d\t%d",zCase,seq++,first!=0,v.nOp,v.nOpAlloc,first && first==&v.aOp[base]);
      for(a=0;a<3;a++){
        if(first) printf("\t%d\t%d\t%d\t%d\t%d\t%d",first[a].opcode,first[a].p1,first[a].p2,first[a].p3,first[a].p4type,first[a].p5);
        else printf("\t-1\t-1\t-1\t-1\t-1\t-1");
      }
      printf("\n"); continue;
    }
    before=v.nOp;
    if( strcmp(command,"RUNONCE")==0 ){
      sqlite3VdbeRunOnlyOnce(&v); addr=before; op=OP_Expire;
    }else
    if( strcmp(command,"ADD0")==0 ){
      sscanf(line,"%*s %63s",name); op=opcode(name); addr=sqlite3VdbeAddOp0(&v,op);
    }else if( strcmp(command,"ADD1")==0 ){
      sscanf(line,"%*s %63s %d",name,&a); op=opcode(name); addr=sqlite3VdbeAddOp1(&v,op,a);
    }else if( strcmp(command,"ADD2")==0 ){
      sscanf(line,"%*s %63s %d %d",name,&a,&b); op=opcode(name); addr=sqlite3VdbeAddOp2(&v,op,a,b);
    }else if( strcmp(command,"ADD3")==0 ){
      sscanf(line,"%*s %63s %d %d %d",name,&a,&b,&c); op=opcode(name); addr=sqlite3VdbeAddOp3(&v,op,a,b,c);
    }else if( strcmp(command,"ADD4INT")==0 ){
      sscanf(line,"%*s %63s %d %d %d %d",name,&a,&b,&c,&d); op=opcode(name); addr=sqlite3VdbeAddOp4Int(&v,op,a,b,c,d);
    }else return 8;
    if(op<0)return 7; observation(zCase,seq++,addr,before,&v,&parse);
  }
  while(keyInfo) { if(keyInfo->nRef==1){sqlite3KeyInfoUnref(keyInfo);keyInfo=0;}else sqlite3KeyInfoUnref(keyInfo); }
  sqlite3_free(publicVtab.zErrMsg);
  clearMachine(db,&parse,&v); db->pParse=0; sqlite3_close(db); fclose(in); return 0;
}
