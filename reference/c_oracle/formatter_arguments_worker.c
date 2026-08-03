#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static unsigned long long double_bits(double value){
  unsigned long long bits;
  memcpy(&bits,&value,sizeof(bits));
  return bits;
}

int main(void){
  sqlite3_value *values[3];
  PrintfArguments args;
  sqlite3_int64 integer;
  double real;
  char *text;
  int i;
  if(sqlite3_initialize()!=SQLITE_OK) return 2;
  printf("LAYOUT\t%zu\t%zu\t%zu\t%zu\t%zu\n",sizeof(PrintfArguments),_Alignof(PrintfArguments),offsetof(PrintfArguments,nArg),offsetof(PrintfArguments,nUsed),offsetof(PrintfArguments,apArg));
  for(i=0;i<3;i++){
    values[i]=sqlite3ValueNew(0);
    if(!values[i]) return 3;
  }
  sqlite3VdbeMemSetInt64(values[0],(-9223372036854775807LL));
  sqlite3VdbeMemSetDouble(values[1],1.25);
  sqlite3ValueSetStr(values[2],-1,"hello",SQLITE_UTF8,SQLITE_STATIC);
  args.nArg=3; args.nUsed=0; args.apArg=values;
  integer=getIntArg(&args);
  printf("INT\t%lld\t%d\n",(long long)integer,args.nUsed);
  real=getDoubleArg(&args);
  printf("DOUBLE\t%016llx\t%d\n",double_bits(real),args.nUsed);
  text=getTextArg(&args);
  printf("TEXT\t%s\t%d\n",text?text:"NULL",args.nUsed);
  integer=getIntArg(&args);
  printf("EMPTY-INT\t%lld\t%d\n",(long long)integer,args.nUsed);
  real=getDoubleArg(&args);
  printf("EMPTY-DOUBLE\t%016llx\t%d\n",double_bits(real),args.nUsed);
  text=getTextArg(&args);
  printf("EMPTY-TEXT\t%s\t%d\n",text?"VALUE":"NULL",args.nUsed);
  printf("FINAL\t%d\n",args.nUsed);
  for(i=0;i<3;i++) sqlite3ValueFree(values[i]);
  sqlite3_shutdown();
  return 0;
}
