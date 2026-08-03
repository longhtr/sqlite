#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void show(int id,char *text){int i,n;sqlite3Dequote(text);n=(int)strlen(text);printf("%d\tD\t%d\t",id,n);for(i=0;i<n;i++)printf("%02x",(unsigned char)text[i]);printf("\n");}
static void token(int id,const char *text){Token value={text,(unsigned int)strlen(text)};sqlite3DequoteToken(&value);printf("%d\tT\t%ld\t%u\n",id,(long)(value.z-text),value.n);}
static void expression(int id,char *text){Expr value;memset(&value,0,sizeof(value));value.u.zToken=text;sqlite3DequoteExpr(&value);printf("%d\tE\t%u\t%s\n",id,value.flags&(EP_Quoted|EP_DblQuoted),value.u.zToken);}
static void number(int id,sqlite3 *db,char *text){Parse parse;Expr value;memset(&parse,0,sizeof(parse));memset(&value,0,sizeof(value));parse.db=db;value.op=TK_QNUMBER;value.u.zToken=text;sqlite3DequoteNumber(&parse,&value);printf("%d\tN\t%c\t%d\t%d\t%d\t%s\n",id,value.op==TK_INTEGER?'I':'F',(value.flags&EP_IntValue)!=0,(value.flags&EP_IntValue)?value.u.iValue:0,parse.nErr,value.flags&EP_IntValue?"":value.u.zToken);sqlite3DbFree(db,parse.zErrMsg);}
int main(void){
  char a[]="'a''b'",b[]="[a-b]",c[]="`a``b`",d[]="plain",e[]="\"a\"\"b\"";
  char ex1[]="\"name\"",ex2[]="'value'",n1[]="1_23",n2[]="1_2.5e+1",n3[]="1_.2",n4[]="0x7fff_ffff";
  sqlite3 *db=0;Token initialized;show(1,a);show(2,b);show(3,c);show(4,d);show(5,e);
  token(6,"\"abc\"");token(7,"\"ab\"\"cd\"");token(8,"\"\"");
  sqlite3TokenInit(&initialized,"token");printf("9\tI\t%u\n",initialized.n);
  expression(10,ex1);expression(11,ex2);if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 2;
  number(12,db,n1);number(13,db,n2);number(14,db,n3);number(15,db,n4);sqlite3_close(db);return 0;
}
