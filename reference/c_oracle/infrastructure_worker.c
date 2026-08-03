#include "sqlite3.c"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int probe_memory_trace(char *out,int cap){
  sqlite3_int64 cur=0,hi=0,u1,c1,rh1,u2,u0,c0; int rc,s1,s2,p1,p2,failed,mis,sd1,sd2,ip,is,ic,vp,vs,vc; void *p,*q;
  union { long long align; unsigned char bytes[2048]; } page;
  sqlite3_shutdown(); sqlite3_config(SQLITE_CONFIG_SERIALIZED); sqlite3_config(SQLITE_CONFIG_MEMSTATUS,1);
  sqlite3_config(SQLITE_CONFIG_PAGECACHE,page.bytes,511,4);
  rc=sqlite3_initialize(); ip=sqlite3GlobalConfig.pPage==0;is=sqlite3GlobalConfig.szPage;ic=sqlite3GlobalConfig.nPage;
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&cur,&hi,1);
  sqlite3_status64(SQLITE_STATUS_MALLOC_COUNT,&cur,&hi,1);
  sqlite3_status64(SQLITE_STATUS_MALLOC_SIZE,&cur,&hi,1);
  p=sqlite3_malloc64(17); s1=p?(int)sqlite3_msize(p):0;
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&u1,&hi,0);
  sqlite3_status64(SQLITE_STATUS_MALLOC_COUNT,&c1,&hi,0);
  sqlite3_status64(SQLITE_STATUS_MALLOC_SIZE,&cur,&rh1,0);
  if(p)((unsigned char*)p)[0]=0x5a;
  q=sqlite3_realloc64(p,257); if(q)p=q; s2=p?(int)sqlite3_msize(p):0; p1=p&&((unsigned char*)p)[0]==0x5a;
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&u2,&hi,0);
  sqlite3_hard_heap_limit64(u2+8);
  q=sqlite3_realloc64(p,4096); failed=q==0; if(q)p=q; p2=p&&((unsigned char*)p)[0]==0x5a;
  sqlite3_hard_heap_limit64(0); sqlite3_free(p);
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&u0,&hi,0); sqlite3_status64(SQLITE_STATUS_MALLOC_COUNT,&c0,&hi,0);
  mis=sqlite3_config(SQLITE_CONFIG_MEMSTATUS,0); sd1=sqlite3_shutdown(); sd2=sqlite3_shutdown();
  sqlite3_config(SQLITE_CONFIG_PAGECACHE,page.bytes,512,4);sqlite3_initialize();
  vp=sqlite3GlobalConfig.pPage==page.bytes;vs=sqlite3GlobalConfig.szPage;vc=sqlite3GlobalConfig.nPage;sqlite3_shutdown();sqlite3_config(SQLITE_CONFIG_PAGECACHE,0,0,0);
  return snprintf(out,cap,"M\t%d\t%d\t%lld\t%lld\t%lld\t%d\t%lld\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
    rc,s1,(long long)u1,(long long)c1,(long long)rh1,s2,(long long)u2,p1,failed,p2,(long long)u0,(long long)c0,mis,sd1,sd2,ip,is,ic,vp,vs,vc);
}

int probe_lookaside_trace(char *out,int cap){
  sqlite3 *db=0; int rc,busy,pSmall,pBig,pGrown,pC,preserve,used,usedhi,defaultSize,defaultSlots; sqlite3_int64 cur,hi,hit,missSize,missFull; void *a,*b,*c,*grown;
  union { long long align; unsigned char bytes[4096]; } storage;
  union { long long align; unsigned char bytes[256]; } storage2;
  sqlite3_shutdown(); sqlite3_config(SQLITE_CONFIG_SERIALIZED); sqlite3_initialize();
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return snprintf(out,cap,"L\tOPENFAIL\n");
  defaultSize=db->lookaside.szTrue;defaultSlots=db->lookaside.nSlot;
  rc=sqlite3_db_config(db,SQLITE_DBCONFIG_LOOKASIDE,storage.bytes,512,8);
  sqlite3_mutex_enter(db->mutex); a=sqlite3DbMallocRawNN(db,64); b=sqlite3DbMallocRawNN(db,400); pSmall=isLookaside(db,a);pBig=isLookaside(db,b); sqlite3_mutex_leave(db->mutex);
  busy=sqlite3_db_config(db,SQLITE_DBCONFIG_LOOKASIDE,0,128,2);
  ((unsigned char*)b)[0]=0x7b; sqlite3_mutex_enter(db->mutex); grown=sqlite3DbRealloc(db,b,1000); pGrown=isLookaside(db,grown); preserve=grown&&((unsigned char*)grown)[0]==0x7b; sqlite3DbFree(db,grown);sqlite3DbFree(db,a);sqlite3_mutex_leave(db->mutex);
  sqlite3_db_status64(db,SQLITE_DBSTATUS_LOOKASIDE_USED,&cur,&hi,0);used=(int)cur;usedhi=(int)hi;
  sqlite3_db_status64(db,SQLITE_DBSTATUS_LOOKASIDE_HIT,&cur,&hit,0);
  sqlite3_db_status64(db,SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE,&cur,&missSize,0);
  sqlite3_db_config(db,SQLITE_DBCONFIG_LOOKASIDE,storage2.bytes,128,2);
  sqlite3_mutex_enter(db->mutex);a=sqlite3DbMallocRawNN(db,100);b=sqlite3DbMallocRawNN(db,100);c=sqlite3DbMallocRawNN(db,100);pC=isLookaside(db,c);sqlite3DbFree(db,c);sqlite3DbFree(db,b);sqlite3DbFree(db,a);sqlite3_mutex_leave(db->mutex);
  sqlite3_db_status64(db,SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL,&cur,&missFull,0);
  sqlite3_close(db);sqlite3_shutdown();
  return snprintf(out,cap,"L\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%lld\t%d\t%lld\n",rc,defaultSize,defaultSlots,pSmall,pBig,busy,pGrown,preserve,used,usedhi,(long long)hit,(long long)missSize,pC,(long long)missFull);
}

struct MutexTry { sqlite3_mutex *mutex; int rc; };
static void *mutex_try_thread(void *arg){struct MutexTry *x=(struct MutexTry*)arg;x->rc=sqlite3_mutex_try(x->mutex);if(x->rc==SQLITE_OK)sqlite3_mutex_leave(x->mutex);return 0;}
int probe_mutex_trace(char *out,int cap){
  sqlite3_mutex *r,*s1,*s2;pthread_t t;struct MutexTry x;int cr,ir,tr,eq,busy,snull,mnonnull,sernonnull;
  sqlite3_shutdown();cr=sqlite3_config(SQLITE_CONFIG_SERIALIZED);ir=sqlite3_initialize();r=sqlite3_mutex_alloc(SQLITE_MUTEX_RECURSIVE);sqlite3_mutex_enter(r);tr=sqlite3_mutex_try(r);sqlite3_mutex_leave(r);sqlite3_mutex_leave(r);
  s1=sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_MEM);s2=sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_MEM);eq=s1==s2;
  sqlite3_mutex_enter(r);x.mutex=r;x.rc=-1;pthread_create(&t,0,mutex_try_thread,&x);pthread_join(t,0);busy=x.rc;sqlite3_mutex_leave(r);sqlite3_mutex_free(r);sqlite3_shutdown();
  sqlite3_config(SQLITE_CONFIG_SINGLETHREAD);sqlite3_initialize();snull=sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN)==0;sqlite3_shutdown();
  sqlite3_config(SQLITE_CONFIG_MULTITHREAD);sqlite3_initialize();mnonnull=sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN)!=0;sqlite3_shutdown();
  sqlite3_config(SQLITE_CONFIG_SERIALIZED);sqlite3_initialize();sernonnull=sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN)!=0;sqlite3_shutdown();
  return snprintf(out,cap,"X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",cr,ir,tr,eq,busy,snull,mnonnull,sernonnull);
}

struct InitRace {int ok;};
static void *init_thread(void *arg){struct InitRace*x=(struct InitRace*)arg;for(int i=0;i<100;i++)if(sqlite3_initialize()!=SQLITE_OK)x->ok=0;return 0;}
static int lfMutexInitCount,lfMutexEndCount,lfPcacheInitCount,lfPcacheEndCount;
static int lfMutexInit(void){lfMutexInitCount++;return SQLITE_OK;}static int lfMutexEnd(void){lfMutexEndCount++;return SQLITE_OK;}
static sqlite3_mutex *lfMutexAlloc(int id){return (sqlite3_mutex*)(intptr_t)(id+1);}static void lfMutexFree(sqlite3_mutex*p){(void)p;}
static void lfMutexEnter(sqlite3_mutex*p){(void)p;}static int lfMutexTry(sqlite3_mutex*p){(void)p;return SQLITE_OK;}static void lfMutexLeave(sqlite3_mutex*p){(void)p;}
static int lfMutexHeld(sqlite3_mutex*p){(void)p;return 1;}static int lfMutexNotheld(sqlite3_mutex*p){(void)p;return 0;}
static int lfPcacheInit(void*p){(void)p;lfPcacheInitCount++;return lfPcacheInitCount==1?SQLITE_NOMEM:SQLITE_OK;}
static void lfPcacheEnd(void*p){(void)p;lfPcacheEndCount++;}
int probe_global_trace(char *out,int cap){
  int good=0,race=1,r1,r2,r3,r4,flags;pthread_t threads[8];struct InitRace args[8];
  sqlite3_mutex_methods xm={lfMutexInit,lfMutexEnd,lfMutexAlloc,lfMutexFree,lfMutexEnter,lfMutexTry,lfMutexLeave,lfMutexHeld,lfMutexNotheld};
  sqlite3_pcache_methods2 pm;memset(&pm,0,sizeof(pm));pm.iVersion=1;pm.xInit=lfPcacheInit;pm.xShutdown=lfPcacheEnd;
  for(int i=0;i<100;i++){
    sqlite3_shutdown();
    good += sqlite3_config((i&1)?SQLITE_CONFIG_MULTITHREAD:SQLITE_CONFIG_SERIALIZED)==SQLITE_OK;
    good += sqlite3_initialize()==SQLITE_OK;good += sqlite3_initialize()==SQLITE_OK;
    good += sqlite3_config(SQLITE_CONFIG_MEMSTATUS,1)==SQLITE_MISUSE;
    good += sqlite3_shutdown()==SQLITE_OK;good += sqlite3_shutdown()==SQLITE_OK;
  }
  sqlite3_config(SQLITE_CONFIG_SERIALIZED);
  for(int i=0;i<8;i++){args[i].ok=1;pthread_create(&threads[i],0,init_thread,&args[i]);}
  for(int i=0;i<8;i++){pthread_join(threads[i],0);race&=args[i].ok;}
  sqlite3_shutdown();
  lfMutexInitCount=lfMutexEndCount=lfPcacheInitCount=lfPcacheEndCount=0;
  sqlite3_config(SQLITE_CONFIG_MUTEX,&xm);sqlite3_config(SQLITE_CONFIG_PCACHE2,&pm);
  r1=sqlite3_initialize();flags=sqlite3GlobalConfig.isMutexInit|(sqlite3GlobalConfig.isMallocInit<<1)|(sqlite3GlobalConfig.isPCacheInit<<2)|(sqlite3GlobalConfig.isInit<<3);
  r2=sqlite3_initialize();r3=sqlite3_shutdown();r4=sqlite3_shutdown();
  memset(&sqlite3GlobalConfig.mutex,0,sizeof(sqlite3GlobalConfig.mutex));sqlite3PCacheSetDefault();
  return snprintf(out,cap,"G\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",good,race,r1,flags,lfMutexInitCount>1,lfPcacheInitCount,r2,r3,r4,lfMutexEndCount,lfPcacheEndCount,sqlite3GlobalConfig.isInit);
}

static int cmInitCount,cmShutdownCount,cxInitCount,cxEndCount;
static void *cmMalloc(int n){sqlite3_int64 *p=(sqlite3_int64*)malloc((size_t)n+8);if(!p)return 0;p[0]=n;return p+1;}
static void cmFree(void *v){if(v)free(((sqlite3_int64*)v)-1);}
static void *cmRealloc(void *v,int n){sqlite3_int64 *p=((sqlite3_int64*)v)-1;p=(sqlite3_int64*)realloc(p,(size_t)n+8);if(!p)return 0;p[0]=n;return p+1;}
static int cmSize(void *v){return (int)(((sqlite3_int64*)v)[-1]);}
static int cmRound(int n){return (n+7)&~7;}
static int cmInit(void *p){(void)p;cmInitCount++;return SQLITE_OK;}
static void cmShutdown(void *p){(void)p;cmShutdownCount++;}
static int cxInit(void){cxInitCount++;return SQLITE_OK;} static int cxEnd(void){cxEndCount++;return SQLITE_OK;}
static sqlite3_mutex *cxAlloc(int id){(void)id;return (sqlite3_mutex*)8;}static void cxFree(sqlite3_mutex*p){(void)p;}
static void cxEnter(sqlite3_mutex*p){(void)p;}static int cxTry(sqlite3_mutex*p){(void)p;return SQLITE_OK;}static void cxLeave(sqlite3_mutex*p){(void)p;}
static int cxHeld(sqlite3_mutex*p){(void)p;return 1;}static int cxNotheld(sqlite3_mutex*p){(void)p;return 0;}
int probe_methods_trace(char*out,int cap){
  sqlite3_mem_methods mm={cmMalloc,cmFree,cmRealloc,cmSize,cmRound,cmInit,cmShutdown,0};
  sqlite3_mutex_methods xm={cxInit,cxEnd,cxAlloc,cxFree,cxEnter,cxTry,cxLeave,cxHeld,cxNotheld};
  void*p;int s1,s2,tr;sqlite3_mutex*x;
  sqlite3_shutdown();cmInitCount=cmShutdownCount=cxInitCount=cxEndCount=0;
  sqlite3_config(SQLITE_CONFIG_MALLOC,&mm);sqlite3_config(SQLITE_CONFIG_MUTEX,&xm);mm.xMalloc=0;xm.xMutexAlloc=0;
  sqlite3_initialize();p=sqlite3_malloc(17);s1=(int)sqlite3_msize(p);p=sqlite3_realloc(p,257);s2=(int)sqlite3_msize(p);sqlite3_free(p);
  x=sqlite3_mutex_alloc(SQLITE_MUTEX_RECURSIVE);sqlite3_mutex_enter(x);tr=sqlite3_mutex_try(x);sqlite3_mutex_leave(x);sqlite3_mutex_leave(x);sqlite3_mutex_free(x);sqlite3_shutdown();
  memset(&sqlite3GlobalConfig.mutex,0,sizeof(sqlite3GlobalConfig.mutex));sqlite3MemSetDefault();
  return snprintf(out,cap,"D\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",cmInitCount,cmShutdownCount,s1,s2,cxInitCount>0,cxEndCount,tr);
}

static char amEvents[256];static int amEventCount;
static void amEvent(char c){if(amEventCount<(int)sizeof(amEvents)-1)amEvents[amEventCount++]=c;amEvents[amEventCount]=0;}
static void amReset(void){amEventCount=0;amEvents[0]=0;}
static void *amMalloc(int n){sqlite3_int64*p;amEvent('A');p=(sqlite3_int64*)malloc((size_t)n+8);if(!p)return 0;p[0]=n;return p+1;}
static void amFree(void*v){amEvent('F');if(v)free(((sqlite3_int64*)v)-1);}
static void *amRealloc(void*v,int n){sqlite3_int64*p;amEvent('X');p=((sqlite3_int64*)v)-1;p=(sqlite3_int64*)realloc(p,(size_t)n+8);if(!p)return 0;p[0]=n;return p+1;}
static int amSize(void*v){amEvent('S');return (int)(((sqlite3_int64*)v)[-1]);}
static int amRound(int n){amEvent('R');return (n+7)&~7;}
static int amMemInit(void*p){(void)p;return SQLITE_OK;}static void amMemEnd(void*p){(void)p;}
static int amMutexInit(void){return SQLITE_OK;}static int amMutexEnd(void){return SQLITE_OK;}
static sqlite3_mutex *amMutexAlloc(int id){return (sqlite3_mutex*)(intptr_t)(id+1);}
static void amMutexFree(sqlite3_mutex*p){(void)p;}
static void amMutexEnter(sqlite3_mutex*p){(void)p;amEvent('E');}
static int amMutexTry(sqlite3_mutex*p){(void)p;amEvent('T');return SQLITE_OK;}
static void amMutexLeave(sqlite3_mutex*p){(void)p;amEvent('L');}
static int amMutexHeld(sqlite3_mutex*p){(void)p;return 1;}static int amMutexNotheld(sqlite3_mutex*p){(void)p;return 0;}
int probe_allocator_trace(char*out,int cap){
  sqlite3_mem_methods mm={amMalloc,amFree,amRealloc,amSize,amRound,amMemInit,amMemEnd,0};
  sqlite3_mutex_methods xm={amMutexInit,amMutexEnd,amMutexAlloc,amMutexFree,amMutexEnter,amMutexTry,amMutexLeave,amMutexHeld,amMutexNotheld};
  sqlite3_int64 base,baseCount,used,usedEnd,countEnd,cur,high;void*p,*q,*r;int s1,s2,near,failed,preserve,n;char events[256];
  sqlite3_shutdown();sqlite3_config(SQLITE_CONFIG_MALLOC,&mm);sqlite3_config(SQLITE_CONFIG_MUTEX,&xm);sqlite3_config(SQLITE_CONFIG_MEMSTATUS,1);sqlite3_initialize();
  base=sqlite3StatusValue(SQLITE_STATUS_MEMORY_USED);baseCount=sqlite3StatusValue(SQLITE_STATUS_MALLOC_COUNT);sqlite3_status64(SQLITE_STATUS_MALLOC_SIZE,&cur,&high,1);mem0.alarmThreshold=base+64;mem0.hardLimit=0;amReset();
  p=sqlite3Malloc(17);s1=sqlite3MallocSize(p);((unsigned char*)p)[0]=0x5a;q=sqlite3Malloc(33);s2=sqlite3MallocSize(q);used=sqlite3StatusValue(SQLITE_STATUS_MEMORY_USED)-base;near=AtomicLoad(&mem0.nearlyFull);
  mem0.hardLimit=sqlite3StatusValue(SQLITE_STATUS_MEMORY_USED)+8;r=sqlite3Realloc(p,80);failed=r==0;preserve=p&&((unsigned char*)p)[0]==0x5a;sqlite3_free(p);sqlite3_free(q);
  usedEnd=sqlite3StatusValue(SQLITE_STATUS_MEMORY_USED)-base;countEnd=sqlite3StatusValue(SQLITE_STATUS_MALLOC_COUNT)-baseCount;strcpy(events,amEvents);sqlite3_status64(SQLITE_STATUS_MALLOC_SIZE,&cur,&high,0);
  n=snprintf(out,cap,"A\t%s\t%d\t%d\t%lld\t%d\t%d\t%d\t%lld\t%lld\t%lld\n",events,s1,s2,(long long)used,near,failed,preserve,(long long)usedEnd,(long long)countEnd,(long long)high);
  sqlite3_shutdown();memset(&sqlite3GlobalConfig.mutex,0,sizeof(sqlite3GlobalConfig.mutex));sqlite3MemSetDefault();return n;
}

int probe_memdb_trace(char*out,int cap){
  sqlite3_vfs*v;sqlite3_file*a,*b,*pa,*pb,*fresh;int flags=SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_MAIN_DB,of=0;
  int iov,tail,dev,wr,rr,packed,la,lb,lar,lbr,laxb,ub,lax,fr,fn,tr,sr,c4,w6,wf,c2,cq,nr,np,ar,ao,pw,pr,pz,alive,reopen;
  sqlite3_int64 size=0,limit;void*fetch=(void*)1;char z[3]={0},q[1]={1};char*name=0;
  sqlite3_shutdown();sqlite3_config(SQLITE_CONFIG_SERIALIZED);sqlite3_initialize();v=sqlite3_vfs_find("memdb");
  a=(sqlite3_file*)calloc(1,v->szOsFile);b=(sqlite3_file*)calloc(1,v->szOsFile);
  v->xOpen(v,"/shared",a,flags,&of);v->xOpen(v,"/shared",b,flags,0);
  iov=a->pMethods->iVersion;tail=(a->pMethods->xCheckReservedLock==0?1:0)|(a->pMethods->xSectorSize==0?2:0)|(a->pMethods->xShmMap==0?4:0)|(a->pMethods->xShmLock==0?8:0)|(a->pMethods->xShmBarrier==0?16:0)|(a->pMethods->xShmUnmap==0?32:0)|(a->pMethods->xFetch!=0?64:0)|(a->pMethods->xUnfetch!=0?128:0);
  dev=a->pMethods->xDeviceCharacteristics(a);wr=a->pMethods->xWrite(a,"abc",3,0);rr=b->pMethods->xRead(b,z,3,0);packed=((unsigned char)z[0]<<16)|((unsigned char)z[1]<<8)|(unsigned char)z[2];
  la=a->pMethods->xLock(a,SQLITE_LOCK_SHARED);lb=b->pMethods->xLock(b,SQLITE_LOCK_SHARED);lar=a->pMethods->xLock(a,SQLITE_LOCK_RESERVED);lbr=b->pMethods->xLock(b,SQLITE_LOCK_RESERVED);laxb=a->pMethods->xLock(a,SQLITE_LOCK_EXCLUSIVE);ub=b->pMethods->xUnlock(b,SQLITE_LOCK_NONE);lax=a->pMethods->xLock(a,SQLITE_LOCK_EXCLUSIVE);
  fr=a->pMethods->xFetch(a,0,3,&fetch);fn=fetch==0;tr=a->pMethods->xTruncate(a,4);sr=a->pMethods->xSync(a,0);
  limit=4;c4=a->pMethods->xFileControl(a,SQLITE_FCNTL_SIZE_LIMIT,&limit);w6=a->pMethods->xWrite(a,"def",3,3);a->pMethods->xFileSize(a,&size);wf=a->pMethods->xWrite(a,"g",1,6);a->pMethods->xFileSize(a,&size);
  limit=2;c2=a->pMethods->xFileControl(a,SQLITE_FCNTL_SIZE_LIMIT,&limit);
  {sqlite3_int64 query=-1;cq=a->pMethods->xFileControl(a,SQLITE_FCNTL_SIZE_LIMIT,&query);nr=a->pMethods->xFileControl(a,SQLITE_FCNTL_VFSNAME,&name);np=name&&strncmp(name,"memdb(",6)==0&&strstr(name,",6)")!=0;sqlite3_free(name);ar=v->xAccess(v,"/shared",SQLITE_ACCESS_EXISTS,&ao);
   pa=(sqlite3_file*)calloc(1,v->szOsFile);pb=(sqlite3_file*)calloc(1,v->szOsFile);v->xOpen(v,"private",pa,flags,0);v->xOpen(v,"private",pb,flags,0);pw=pa->pMethods->xWrite(pa,"x",1,0);pr=pb->pMethods->xRead(pb,q,1,0);pz=q[0]==0;pa->pMethods->xClose(pa);pb->pMethods->xClose(pb);free(pa);free(pb);
   b->pMethods->xClose(b);alive=a->pMethods->xRead(a,z,3,0);a->pMethods->xClose(a);free(a);free(b);fresh=(sqlite3_file*)calloc(1,v->szOsFile);v->xOpen(v,"/shared",fresh,flags,0);reopen=fresh->pMethods->xRead(fresh,q,1,0);fresh->pMethods->xClose(fresh);free(fresh);
   sqlite3_shutdown();return snprintf(out,cap,"Q\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%lld\t%d\t%lld\t%d\t%lld\t%d\t%lld\t%d\t%lld\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",v->iVersion,(of&SQLITE_OPEN_MEMORY)!=0,iov,tail,dev,wr,rr,packed,la,lb,lar,lbr,laxb,ub,lax,fr,fn,tr,sr,c4,(long long)4,w6,(long long)6,wf,(long long)size,c2,(long long)limit,cq,(long long)query,nr,np,ar,ao,pw,pr,pz,alive,reopen);}
}

#include "../../tests/differential/infrastructure_worker_main.c"
