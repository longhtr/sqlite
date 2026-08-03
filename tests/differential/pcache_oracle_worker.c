#include "sqliteInt.h"
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct Sqlite3Config sqlite3Config;
struct sqlite3_mutex { int unused; };
sqlite3_mutex *sqlite3MutexAlloc(int type){static sqlite3_mutex mutex;(void)type;return &mutex;}
void sqlite3_mutex_enter(sqlite3_mutex *mutex){(void)mutex;}
void sqlite3_mutex_leave(sqlite3_mutex *mutex){(void)mutex;}
typedef union AllocHeader { size_t size; long double align; void *pointer; } AllocHeader;
void *sqlite3Malloc(u64 n){ AllocHeader *h=(AllocHeader*)malloc(sizeof(*h)+(size_t)n);if(!h)return 0;h->size=(size_t)n;return h+1; }
void *sqlite3MallocZero(u64 n){void *p=sqlite3Malloc(n);if(p)memset(p,0,(size_t)n);return p;}
int sqlite3MallocSize(const void *p){return p?(int)(((const AllocHeader*)p)[-1].size):0;}
void sqlite3_free(void *p){if(p)free(((AllocHeader*)p)-1);}
int sqlite3HeapNearlyFull(void){return 0;}
void sqlite3StatusUp(int a,int b){(void)a;(void)b;}
void sqlite3StatusDown(int a,int b){(void)a;(void)b;}
void sqlite3StatusHighwater(int a,int b){(void)a;(void)b;}
void sqlite3BeginBenignMalloc(void){}
void sqlite3EndBenignMalloc(void){}
int sqlite3_config(int op,...){va_list ap;va_start(ap,op);if(op==SQLITE_CONFIG_PCACHE2){sqlite3_pcache_methods2 *p=va_arg(ap,sqlite3_pcache_methods2*);sqlite3Config.pcache2=*p;}va_end(ap);return SQLITE_OK;}

#include "pcache1.c"
#include "pcache.c"

static int stress_count;
static Pgno stress_key;
static int stress(void *context,PgHdr *page){(void)context;stress_count++;stress_key=page->pgno;sqlite3PcacheMakeClean(page);return SQLITE_OK;}
static PgHdr *fetch(PCache *cache,Pgno key){sqlite3_pcache_page *raw=sqlite3PcacheFetch(cache,key,2);return raw?sqlite3PcacheFetchFinish(cache,key,raw):0;}
static void print_dirty(PCache *cache){PgHdr *p=sqlite3PcacheDirtyList(cache);printf("dirty");while(p){printf(" %u",p->pgno);p=p->pDirty;}putchar('\n');}
static PgHdr *sequence_fetch(PCache *cache,Pgno key){
 sqlite3_pcache_page *raw=sqlite3PcacheFetch(cache,key,2);
 if(!raw && sqlite3PcacheFetchStress(cache,key,&raw)!=SQLITE_OK)return 0;
 return raw?sqlite3PcacheFetchFinish(cache,key,raw):0;
}
static void print_state(PCache *cache,int sequence,int step){
 PgHdr *p=sqlite3PcacheDirtyList(cache);
 printf("state %d %d %d %lld dirty",sequence,step,sqlite3PcachePagecount(cache),(long long)sqlite3PcacheRefCount(cache));
 while(p){printf(" %u",p->pgno);p=p->pDirty;}
 putchar('\n');
}
static int run_sequences(void){
 FILE *input=fopen("tests/fixtures/pcache/state-sequences.txt","r");
 char line[128],op;int sequence=-1,step=0;unsigned a,b;PCache cache;int opened=0;
 if(!input)return 20;
 while(fgets(line,sizeof(line),input)){
  if(sscanf(line,"BEGIN %d",&sequence)==1){
   if(opened)return 21;
   if(sqlite3PcacheOpen(256,8,1,stress,0,&cache)!=SQLITE_OK)return 22;
   sqlite3PcacheSetCachesize(&cache,128);sqlite3PcacheSetSpillsize(&cache,64);opened=1;step=0;continue;
  }
  if(!strncmp(line,"END",3)){
   if(!opened)return 23;sqlite3PcacheClose(&cache);opened=0;continue;
  }
  if(!opened)return 24;
  op=line[0];a=b=0;(void)sscanf(line+1," %u %u",&a,&b);
  if(op=='F'){
   PgHdr *p=sequence_fetch(&cache,a);if(!p)return 25;sqlite3PcacheRelease(p);
  }else if(op=='D'){
   PgHdr *p=sequence_fetch(&cache,a);if(!p)return 26;sqlite3PcacheMakeDirty(p);sqlite3PcacheRelease(p);
  }else if(op=='C'){
   PgHdr *p=sequence_fetch(&cache,a);if(!p)return 27;sqlite3PcacheMakeClean(p);sqlite3PcacheRelease(p);
  }else if(op=='M'){
   PgHdr *p=sequence_fetch(&cache,a);if(!p)return 28;sqlite3PcacheMove(p,b);sqlite3PcacheRelease(p);
  }else if(op=='T'){
   sqlite3PcacheCleanAll(&cache);sqlite3PcacheTruncate(&cache,a);
  }else if(op=='A'){
   sqlite3PcacheCleanAll(&cache);
  }else if(op=='H'){
   sqlite3PcacheShrink(&cache);
  }else return 29;
  print_state(&cache,sequence,step++);
 }
 fclose(input);if(opened)return 30;return 0;
}
static int run_group(void){
 PCache first,second;PgHdr *a1,*a2,*b10,*b11,*b12;sqlite3_pcache_page *saved;PGroup *group;
 union { long long align; unsigned char bytes[8192]; } storage;
 memset(&sqlite3Config,0,sizeof(sqlite3Config));sqlite3Config.pPage=storage.bytes;sqlite3Config.szPage=1024;sqlite3Config.nPage=8;sqlite3PCacheSetDefault();
 if(sqlite3PcacheInitialize()!=SQLITE_OK)return 31;sqlite3PCacheBufferSetup(storage.bytes,1024,8);
 if(sqlite3PcacheOpen(512,16,1,stress,0,&first)!=SQLITE_OK)return 32;if(sqlite3PcacheOpen(512,16,1,stress,0,&second)!=SQLITE_OK)return 33;
 sqlite3PcacheSetCachesize(&first,3);sqlite3PcacheSetCachesize(&second,3);group=((PCache1*)first.pCache)->pGroup;
 a1=fetch(&first,1);a2=fetch(&first,2);if(!a1||!a2)return 34;saved=a1->pPage;sqlite3PcacheRelease(a1);sqlite3PcacheRelease(a2);
 b10=fetch(&second,10);b11=fetch(&second,11);if(!b10||!b11)return 35;sqlite3PcacheRelease(b10);sqlite3PcacheRelease(b11);
 printf("group %u %u %u %d\n",group->nPurgeable,group->nMaxPage,group->nMinPage,pcache1.nFreeSlot);
 b12=fetch(&second,12);if(!b12)return 36;printf("recycle %d %d %d %u %d\n",b12->pPage==saved,sqlite3PcachePagecount(&first),sqlite3PcachePagecount(&second),group->nPurgeable,pcache1.nFreeSlot);sqlite3PcacheRelease(b12);
 sqlite3PcacheSetCachesize(&first,1);sqlite3PcacheSetCachesize(&second,1);printf("limit %d %d %u %u %d\n",sqlite3PcachePagecount(&first),sqlite3PcachePagecount(&second),group->nPurgeable,group->nMaxPage,pcache1.nFreeSlot);
 sqlite3PcacheShrink(&first);printf("groupshrink %d %d %u %d\n",sqlite3PcachePagecount(&first),sqlite3PcachePagecount(&second),group->nPurgeable,pcache1.nFreeSlot);
 sqlite3PcacheClose(&first);sqlite3PcacheClose(&second);sqlite3PcacheShutdown();memset(&sqlite3Config,0,sizeof(sqlite3Config));return 0;
}

static int run_hash(void){
 PCache cache;PgHdr *pages[258];PCache1 *native;PgHdr1 *head;int i;
 memset(&sqlite3Config,0,sizeof(sqlite3Config));sqlite3PCacheSetDefault();if(sqlite3PcacheInitialize()!=SQLITE_OK)return 37;
 if(sqlite3PcacheOpen(512,16,1,stress,0,&cache)!=SQLITE_OK)return 38;sqlite3PcacheSetCachesize(&cache,600);
 for(i=0;i<257;i++){pages[i]=fetch(&cache,(Pgno)(i+1));if(!pages[i])return 39;}pages[257]=fetch(&cache,513);if(!pages[257])return 40;
 native=(PCache1*)cache.pCache;head=native->apHash[1];printf("hash %u %u %u %u\n",native->nHash,native->nPage,head->iKey,head->pNext->iKey);
 for(i=0;i<258;i++)sqlite3PcacheRelease(pages[i]);sqlite3PcacheClose(&cache);sqlite3PcacheShutdown();return 0;
}

int main(void){
 PCache cache,purge_cache,bulk_cache;PgHdr *p1,*p2,*p3,*p4,*pa,*pb,*ba,*bb,*bc,*bd;sqlite3_pcache_page *raw;void *sa,*sb,*sc;PCache1 *bulk_native;
 union { long long align; unsigned char bytes[2048]; } slots;
 memset(&sqlite3Config,0,sizeof(sqlite3Config));sqlite3PCacheSetDefault();
 if(sqlite3PcacheInitialize()!=SQLITE_OK)return 1;
 sqlite3PCacheBufferSetup(slots.bytes,1024,2);sa=sqlite3PageMalloc(512);sb=sqlite3PageMalloc(512);sc=sqlite3PageMalloc(512);
 printf("slots %d %d %d %d %d\n",SQLITE_WITHIN(sa,slots.bytes,slots.bytes+2048),SQLITE_WITHIN(sb,slots.bytes,slots.bytes+2048),SQLITE_WITHIN(sc,slots.bytes,slots.bytes+2048),pcache1.nFreeSlot,pcache1.bUnderPressure);
 { PCache1 pressure_cache;memset(&pressure_cache,0,sizeof(pressure_cache));pressure_cache.szPage=512;pressure_cache.szExtra=16;printf("pressure %d",pcache1UnderMemoryPressure(&pressure_cache));pressure_cache.szPage=2048;printf(" %d\n",pcache1UnderMemoryPressure(&pressure_cache)); }
 sqlite3PageFree(sa);sqlite3PageFree(sb);sqlite3PageFree(sc);printf("slotfree %d %d\n",pcache1.nFreeSlot,pcache1.bUnderPressure);sqlite3PCacheBufferSetup(0,0,0);
 pcache1.nInitPage=3;if(sqlite3PcacheOpen(512,16,1,stress,0,&bulk_cache)!=SQLITE_OK)return 8;sqlite3PcacheSetCachesize(&bulk_cache,5);
 ba=fetch(&bulk_cache,1);bb=fetch(&bulk_cache,2);bc=fetch(&bulk_cache,3);if(!ba||!bb||!bc)return 9;bulk_native=(PCache1*)bulk_cache.pCache;
 printf("bulk %d %d %d %d %d\n",bulk_native->pBulk!=0,bulk_native->pFree==0,((PgHdr1*)ba->pPage)->isBulkLocal,((PgHdr1*)bb->pPage)->isBulkLocal,((PgHdr1*)bc->pPage)->isBulkLocal);
 bd=fetch(&bulk_cache,4);if(!bd)return 10;printf("bulkoverflow %d\n",((PgHdr1*)bd->pPage)->isBulkLocal);sqlite3PcacheRelease(ba);sqlite3PcacheRelease(bb);sqlite3PcacheRelease(bc);sqlite3PcacheRelease(bd);sqlite3PcacheShrink(&bulk_cache);printf("bulkfree %d\n",bulk_native->pBulk==0);sqlite3PcacheClose(&bulk_cache);pcache1.nInitPage=0;
 if(sqlite3PcacheOpen(512,16,1,stress,0,&cache)!=SQLITE_OK)return 2;
 sqlite3PcacheSetCachesize(&cache,3);sqlite3PcacheSetSpillsize(&cache,1);
 p3=fetch(&cache,3);p1=fetch(&cache,1);p2=fetch(&cache,2);if(!p1||!p2||!p3)return 3;
 sqlite3PcacheMakeDirty(p3);sqlite3PcacheMakeDirty(p1);sqlite3PcacheMakeDirty(p2);
 print_dirty(&cache);printf("refs %lld\n",(long long)sqlite3PcacheRefCount(&cache));
 sqlite3PcacheRelease(p1);sqlite3PcacheRelease(p2);sqlite3PcacheRelease(p3);printf("refs %lld\n",(long long)sqlite3PcacheRefCount(&cache));
 raw=sqlite3PcacheFetch(&cache,4,1);if(raw==0){if(sqlite3PcacheFetchStress(&cache,4,&raw)!=SQLITE_OK||!raw)return 4;}p4=sqlite3PcacheFetchFinish(&cache,4,raw);
 printf("stress %d %u\n",stress_count,stress_key);printf("pages %d\n",sqlite3PcachePagecount(&cache));print_dirty(&cache);
 sqlite3PcacheMakeClean(p4);sqlite3PcacheMove(p4,8);sqlite3PcacheRelease(p4);sqlite3PcacheCleanAll(&cache);sqlite3PcacheTruncate(&cache,3);printf("pages %d\n",sqlite3PcachePagecount(&cache));
 sqlite3PcacheClose(&cache);
 if(sqlite3PcacheOpen(512,16,1,stress,0,&purge_cache)!=SQLITE_OK)return 5;sqlite3PcacheSetCachesize(&purge_cache,4);
 pa=fetch(&purge_cache,11);pb=fetch(&purge_cache,12);if(!pa||!pb)return 6;sqlite3PcacheRelease(pa);sqlite3PcacheRelease(pb);
 printf("purge %d",sqlite3PcachePagecount(&purge_cache));sqlite3PcacheShrink(&purge_cache);printf(" %d\n",sqlite3PcachePagecount(&purge_cache));
 sqlite3PcacheClose(&purge_cache);if(run_sequences()!=0)return 7;sqlite3PcacheShutdown();{int rc=run_group();if(rc)return rc;}return run_hash();
}
