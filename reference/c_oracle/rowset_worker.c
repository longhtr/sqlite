#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

static RowSet *new_set(sqlite3 *db){
  RowSet *p=sqlite3RowSetInit(db);
  if(!p){fprintf(stderr,"oom\n");exit(2);} return p;
}

int main(void){
  sqlite3 *db=0; RowSet *p; sqlite3_int64 v=0; int has; int i; long long sum; int count;
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 2;

  p=new_set(db);
  { sqlite3_int64 a[]={9,-3,9,2,1,-3,20,2};
    for(i=0;i<8;i++)sqlite3RowSetInsert(p,a[i]);
  }
  printf("1"); while(sqlite3RowSetNext(p,&v))printf("\t%lld",(long long)v); printf("\n");
  printf("2\t%d\n",sqlite3RowSetNext(p,&v));
  sqlite3RowSetDelete(p);

  p=new_set(db);
  for(i=99;i>=0;i--){sqlite3RowSetInsert(p,i);sqlite3RowSetInsert(p,i);}
  sum=0;count=0;while(sqlite3RowSetNext(p,&v)){sum+=v;count++;}
  printf("3\t%d\t%lld\n",count,sum); sqlite3RowSetDelete(p);

  p=new_set(db); sqlite3RowSetInsert(p,10); sqlite3RowSetInsert(p,20);
  printf("4\t%d",sqlite3RowSetTest(p,0,10));
  printf("\t%d",sqlite3RowSetTest(p,1,10));
  sqlite3RowSetInsert(p,30);
  printf("\t%d",sqlite3RowSetTest(p,1,30));
  printf("\t%d",sqlite3RowSetTest(p,2,30));
  printf("\t%d\n",sqlite3RowSetTest(p,2,10));

  for(i=0;i<18;i++){
    sqlite3RowSetInsert(p,100+i);
    if(!sqlite3RowSetTest(p,3+i,100+i)){fprintf(stderr,"freeze mismatch\n");return 3;}
  }
  count=0; for(i=0;i<18;i++)count+=sqlite3RowSetTest(p,20,100+i);
  printf("5\t%d\t%d\t%d\n",count,sqlite3RowSetTest(p,20,10),sqlite3RowSetTest(p,20,999));
  sqlite3RowSetInsert(p,777);
  printf("6\t%d\t%d\n",sqlite3RowSetTest(p,20,777),sqlite3RowSetTest(p,21,777));
  sqlite3RowSetClear(p); sqlite3RowSetInsert(p,-7); has=sqlite3RowSetNext(p,&v);
  printf("7\t%d\t%lld\t%d\n",has,(long long)v,sqlite3RowSetNext(p,&v));
  sqlite3RowSetDelete(p);

  sqlite3_close(db); return 0;
}
