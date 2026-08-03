#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static double from_bits(unsigned long long bits){ double value; memcpy(&value,&bits,8); return value; }
static void show(int id, StrAccum *acc){
  unsigned int i;
  sqlite3_str_value(acc);
  printf("%02d\t%d\t",id,acc->accError);
  for(i=0;i<acc->nChar;i++) printf("%02x",(unsigned char)acc->zText[i]);
  printf("\n");
}

int main(void){
  StrAccum acc;
  char base[512];
  char *owned;
  int count = -1;
  if(sqlite3_initialize()!=SQLITE_OK) return 2;
#define START() sqlite3StrAccumInit(&acc,0,base,sizeof(base),0)
  START(); sqlite3_str_appendf(&acc,"plain %% %d %+d % d",-12,7,7); show(1,&acc);
  START(); sqlite3_str_appendf(&acc,"%08d|%-6u|%,d",-42,9u,1234567); show(2,&acc);
  START(); sqlite3_str_appendf(&acc,"%#x|%#X|%#o|%p",0x2au,0x2au,9u,(void*)0x1234); show(3,&acc);
  START(); sqlite3_str_appendf(&acc,"%.5d|%10.5d|%r",12,12,22); show(4,&acc);
  START(); sqlite3_str_appendf(&acc,"%s|%.3s|%8s|%-8s","abcdef","abcdef","xy","xy"); show(5,&acc);
  START(); sqlite3_str_appendf(&acc,"%!5.2s","\xc3\xa9x"); show(6,&acc);
  START(); sqlite3_str_appendf(&acc,"%c|%.3c|%5c",0x20ac,0x20ac,0x20ac); show(7,&acc);
  START(); sqlite3_str_appendf(&acc,"%q|%Q|%w","a'b","a'b","a\"b"); show(8,&acc);
  START(); sqlite3_str_appendf(&acc,"%#q|%#Q","a\\\001b","a\\\001b"); show(9,&acc);
  START(); sqlite3_str_appendf(&acc,"%10q|%-10Q","a'b","a'b"); show(10,&acc);
  START(); sqlite3_str_appendf(&acc,"%*.*d|%*d",8,4,12,-6,9); show(11,&acc);
  START(); sqlite3_str_appendf(&acc,"abc%nXYZ",&count); show(12,&acc); printf("COUNT\t%d\n",count);
  START(); sqlite3_str_appendf(&acc,"%s|%q|%Q",(char*)0,(char*)0,(char*)0); show(13,&acc);
  START(); sqlite3_str_appendf(&acc,"trailing%"); show(14,&acc);
  START(); sqlite3_str_appendf(&acc,"%Q","''''''''''''''''''''''''''''''''''''''''"); show(15,&acc);
  sqlite3StrAccumInit(&acc,0,0,0,128); owned=sqlite3_mprintf("owned"); sqlite3_str_appendf(&acc,"%z",owned);
  printf("16\t%d\t%d\t%d\t",acc.accError,acc.zText==owned,isMalloced(&acc));
  { unsigned int i; for(i=0;i<acc.nChar;i++) printf("%02x",(unsigned char)acc.zText[i]); } printf("\n"); sqlite3_str_reset(&acc);
  START(); sqlite3_str_appendall(&acc,"x"); owned=sqlite3_mprintf("owned"); sqlite3_str_appendf(&acc,"%7z",owned); show(17,&acc);
  START(); sqlite3_str_appendf(&acc,"%f|%.2f|%+.0f",1.25,1.25,1.6); show(18,&acc);
  START(); sqlite3_str_appendf(&acc,"%e|%E|%.3e",123.0,0.00123,1.23456); show(19,&acc);
  START(); sqlite3_str_appendf(&acc,"%g|%.3g|%#g|%!g",123.45,123.45,123.45,49.47); show(20,&acc);
  START(); sqlite3_str_appendf(&acc,"%010.2f|%-10.2f|%,.2f",12.5,12.5,12345.5); show(21,&acc);
  START(); sqlite3_str_appendf(&acc,"%f|%f|%f",from_bits(0x7ff0000000000000ULL),from_bits(0xfff0000000000000ULL),from_bits(0x7ff8000000000001ULL)); show(22,&acc);
  START(); sqlite3_str_appendf(&acc,"%f|%#f|%+f",from_bits(0x8000000000000000ULL),from_bits(0x8000000000000000ULL),from_bits(0x8000000000000000ULL)); show(23,&acc);
  START(); sqlite3_str_appendf(&acc,"%.17g|%!.17g",49.47,49.47); show(24,&acc);
  START(); sqlite3_str_appendf(&acc,"%*.*f",10,3,1.25); show(25,&acc);
  { unsigned long long state=0xd1b54a32d192ed03ULL; double value;
    for(count=0;count<64;count++){ state^=state<<13; state^=state>>7; state^=state<<17; value=from_bits(state); START();
      switch(count&7){case 0:sqlite3_str_appendf(&acc,"%g",value);break;case 1:sqlite3_str_appendf(&acc,"%.17g",value);break;
      case 2:sqlite3_str_appendf(&acc,"%!.17g",value);break;case 3:sqlite3_str_appendf(&acc,"%.6e",value);break;
      case 4:sqlite3_str_appendf(&acc,"%.4f",value);break;case 5:sqlite3_str_appendf(&acc,"%#.0f",value);break;
      case 6:sqlite3_str_appendf(&acc,"%020.6g",value);break;default:sqlite3_str_appendf(&acc,"%,.2f",value);break;} show(100+count,&acc); }}
  { Token token={"token-bytes",5}; Expr expr; SrcItem item; Select select; Subquery subquery;
    START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%T",&token);show(200,&acc);
    memset(&expr,0,sizeof(expr));expr.u.zToken="expr";START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%#T",&expr);show(201,&acc);
    memset(&item,0,sizeof(item));item.zAlias="alias";item.zName="table";item.u4.zDatabase="main";
    START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%S",&item);show(202,&acc);
    START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%!S",&item);show(203,&acc);
    item.zAlias=0;START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%S",&item);show(204,&acc);
    memset(&select,0,sizeof(select));memset(&subquery,0,sizeof(subquery));subquery.pSelect=&select;memset(&item,0,sizeof(item));item.fg.isSubquery=1;item.u4.pSubq=&subquery;
    select.selFlags=SF_NestedFrom;select.selId=7;START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%S",&item);show(205,&acc);
    select.selFlags=SF_MultiValue;item.u1.nRow=3;START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%S",&item);show(206,&acc);
    select.selFlags=0;select.selId=9;START();acc.printfFlags|=SQLITE_PRINTF_INTERNAL;sqlite3_str_appendf(&acc,"%S",&item);show(207,&acc); }
  sqlite3_shutdown();
  return 0;
}
