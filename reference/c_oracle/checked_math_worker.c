#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

static void op(int id,char kind,sqlite3_int64 a,sqlite3_int64 b){sqlite3_int64 value=a;int rc=kind=='A'?sqlite3AddInt64(&value,b):kind=='S'?sqlite3SubInt64(&value,b):sqlite3MulInt64(&value,b);printf("%d\t%c\t%lld\t%lld\t%d\t%lld\n",id,kind,(long long)a,(long long)b,rc,(long long)value);}
int main(void){
  union {sqlite3_uint64 u;double d;} value;
  static const sqlite3_uint64 bits[]={0,0x3ff0000000000000ULL,0x7fefffffffffffffULL,0x7ff0000000000000ULL,0xfff0000000000000ULL,0x7ff8000000000001ULL};
  int id=0,i;
  op(id++,'A',1,2);op(id++,'A',0x7fffffffffffffffLL,1);op(id++,'A',(-0x7fffffffffffffffLL-1),-1);op(id++,'A',-5,9);
  op(id++,'S',5,9);op(id++,'S',(-0x7fffffffffffffffLL-1),1);op(id++,'S',0,(-0x7fffffffffffffffLL-1));op(id++,'S',-1,(-0x7fffffffffffffffLL-1));
  op(id++,'M',7,-3);op(id++,'M',0x7fffffffffffffffLL,2);op(id++,'M',(-0x7fffffffffffffffLL-1),-1);op(id++,'M',0,(-0x7fffffffffffffffLL-1));
  printf("%d\tX\t%d\n",id++,sqlite3AbsInt32(0));printf("%d\tX\t%d\n",id++,sqlite3AbsInt32(-1));printf("%d\tX\t%d\n",id++,sqlite3AbsInt32(-2147483647));printf("%d\tX\t%d\n",id++,sqlite3AbsInt32((int)0x80000000));
  for(i=0;i<6;i++){value.u=bits[i];printf("%d\tF\t%d\t%d\n",id++,sqlite3IsNaN(value.d),sqlite3IsOverflow(value.d));}
  return 0;
}
