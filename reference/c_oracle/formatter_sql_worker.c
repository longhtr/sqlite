#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <stdarg.h>

static void append_sql(StrAccum *acc, const char *format, ...){
  va_list ap;
  va_start(ap,format);
  sqlite3_str_vappendf(acc,format,ap);
  va_end(ap);
}
static void show(int id, StrAccum *acc, PrintfArguments *args){
  unsigned int i;
  sqlite3_str_value(acc);
  printf("%d\t%d\t%d\t",id,acc->accError,args->nUsed);
  for(i=0;i<acc->nChar;i++) printf("%02x",(unsigned char)acc->zText[i]);
  printf("\n");
}
static void init_acc(StrAccum *acc, char *base, int size){
  sqlite3StrAccumInit(acc,0,base,size,0);
  acc->printfFlags |= SQLITE_PRINTF_SQLFUNC;
}
int main(void){
  sqlite3_value *values[7];
  PrintfArguments args;
  StrAccum acc;
  char base[256];
  sqlite3_context context;
  sqlite3 *db = 0;
  Mem output;
  int i;
  if(sqlite3_initialize()!=SQLITE_OK) return 2;
  for(i=0;i<7;i++){ values[i]=sqlite3ValueNew(0); if(!values[i]) return 3; }
  sqlite3VdbeMemSetInt64(values[0],-42); sqlite3VdbeMemSetDouble(values[1],1.25);
  sqlite3ValueSetStr(values[2],-1,"a'b",SQLITE_UTF8,SQLITE_STATIC);
  sqlite3ValueSetStr(values[3],-1,"\xc3\xa9x",SQLITE_UTF8,SQLITE_STATIC);
  sqlite3ValueSetStr(values[4],-1,"dyn",SQLITE_UTF8,SQLITE_STATIC);
  sqlite3VdbeMemSetInt64(values[5],5); sqlite3VdbeMemSetInt64(values[6],9);
  args.nArg=7;args.nUsed=0;args.apArg=values;init_acc(&acc,base,sizeof(base));
  append_sql(&acc,"%08d|%.2f|%Q|%.2c|%z|%n|%*d",&args);show(1,&acc,&args);
  args.nArg=0;args.nUsed=0;init_acc(&acc,base,sizeof(base));
  append_sql(&acc,"%d|%f|%s|%Q|%c",&args);show(2,&acc,&args);
  sqlite3ValueSetStr(values[0],-1,"42",SQLITE_UTF8,SQLITE_STATIC);
  sqlite3ValueSetStr(values[1],-1,"1.5",SQLITE_UTF8,SQLITE_STATIC);sqlite3VdbeMemSetInt64(values[2],99);
  args.nArg=3;args.nUsed=0;init_acc(&acc,base,sizeof(base));
  append_sql(&acc,"%d|%.1f|%s",&args);show(3,&acc,&args);
  sqlite3ValueSetStr(values[0],-1,"borrowed",SQLITE_UTF8,SQLITE_STATIC);sqlite3VdbeMemSetInt64(values[1],7);
  args.nArg=2;args.nUsed=0;init_acc(&acc,base,sizeof(base));
  append_sql(&acc,"%z|%n|%d",&args);show(4,&acc,&args);
  sqlite3VdbeMemSetInt64(values[0],-6);sqlite3VdbeMemSetInt64(values[1],3);sqlite3VdbeMemSetInt64(values[2],12);
  args.nArg=3;args.nUsed=0;init_acc(&acc,base,sizeof(base));
  append_sql(&acc,"%*.*d",&args);show(5,&acc,&args);
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK) return 4;
  memset(&context,0,sizeof(context));sqlite3VdbeMemInit(&output,db,MEM_Null);context.pOut=&output;context.enc=SQLITE_UTF8;
  sqlite3StrAccumInit(&acc,0,base,8,0);sqlite3ResultStrAccum(&context,&acc);
  printf("6\t%d\t%u\t%d\t%u\t%d\n",context.isError,output.flags,output.n,acc.nChar,acc.zText==0);sqlite3VdbeMemRelease(&output);
  sqlite3VdbeMemInit(&output,db,MEM_Null);context.pOut=&output;context.isError=0;sqlite3StrAccumInit(&acc,0,0,0,128);sqlite3_str_appendall(&acc,"hello");sqlite3ResultStrAccum(&context,&acc);
  printf("7\t%d\t%u\t%d\t",context.isError,output.flags,output.n);for(i=0;i<output.n;i++)printf("%02x",(unsigned char)output.z[i]);printf("\n");sqlite3VdbeMemRelease(&output);
  sqlite3VdbeMemInit(&output,db,MEM_Null);context.pOut=&output;context.isError=0;sqlite3StrAccumInit(&acc,0,base,8,0);sqlite3_str_appendall(&acc,"12345678");sqlite3ResultStrAccum(&context,&acc);
  printf("8\t%d\t%u\t%d\t%u\t%d\n",context.isError,output.flags,output.n,acc.nChar,acc.zText==0);sqlite3VdbeMemRelease(&output);
  sqlite3_close(db);for(i=0;i<7;i++) sqlite3ValueFree(values[i]);
  sqlite3_shutdown();
  return 0;
}
