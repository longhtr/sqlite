#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

int main(void){
  static const sqlite3_uint64 ints[]={0,1,2,3,7,8,15,16,255,256,2000000000ULL,0xffffffffffffffffULL};
  static const int adds[][2]={{0,0},{100,100},{100,99},{100,69},{100,68},{100,40}};
  static const double doubles[]={0.5,1.0,3.5,2000000001.0,1.0e100};
  static const int estimates[]={0,10,33,100,609,610};
  int id=0,i;
  for(i=0;i<(int)(sizeof(ints)/sizeof(ints[0]));i++)printf("%d\tI\t%llu\t%d\n",id++,(unsigned long long)ints[i],sqlite3LogEst(ints[i]));
  for(i=0;i<(int)(sizeof(adds)/sizeof(adds[0]));i++)printf("%d\tA\t%d\t%d\t%d\n",id++,adds[i][0],adds[i][1],sqlite3LogEstAdd(adds[i][0],adds[i][1]));
  for(i=0;i<(int)(sizeof(doubles)/sizeof(doubles[0]));i++)printf("%d\tD\t%d\n",id++,sqlite3LogEstFromDouble(doubles[i]));
  for(i=0;i<(int)(sizeof(estimates)/sizeof(estimates[0]));i++)printf("%d\tT\t%d\t%llu\n",id++,estimates[i],(unsigned long long)sqlite3LogEstToInt(estimates[i]));
  return 0;
}
