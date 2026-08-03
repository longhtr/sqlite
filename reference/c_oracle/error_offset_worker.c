#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

int main(void){
  sqlite3 db;
  Parse parse;
  Expr leaf, parent;
  char sql[]="select token";
  char outside[]="outside";
  memset(&db,0,sizeof(db));memset(&parse,0,sizeof(parse));
  db.errByteOffset=-2;db.pParse=&parse;parse.zTail=sql;
  sqlite3RecordErrorByteOffset(&db,sql+7);printf("1\t%d\n",db.errByteOffset);
  sqlite3RecordErrorByteOffset(&db,sql+2);printf("2\t%d\n",db.errByteOffset);
  db.errByteOffset=-2;sqlite3RecordErrorByteOffset(&db,outside);printf("3\t%d\n",db.errByteOffset);
  db.errByteOffset=-2;db.pParse=0;sqlite3RecordErrorByteOffset(&db,sql+1);printf("4\t%d\n",db.errByteOffset);
  db.errByteOffset=-2;db.pParse=&parse;sqlite3RecordErrorByteOffset(&db,sql+strlen(sql));printf("5\t%d\n",db.errByteOffset);
  memset(&leaf,0,sizeof(leaf));leaf.w.iOfst=7;db.errByteOffset=-2;sqlite3RecordErrorOffsetOfExpr(&db,&leaf);printf("6\t%d\n",db.errByteOffset);
  memset(&parent,0,sizeof(parent));parent.w.iOfst=0;parent.pLeft=&leaf;db.errByteOffset=-2;sqlite3RecordErrorOffsetOfExpr(&db,&parent);printf("7\t%d\n",db.errByteOffset);
  memset(&parent,0,sizeof(parent));parent.flags=EP_OuterON;parent.w.iOfst=3;parent.pLeft=&leaf;db.errByteOffset=-2;sqlite3RecordErrorOffsetOfExpr(&db,&parent);printf("8\t%d\n",db.errByteOffset);
  memset(&leaf,0,sizeof(leaf));leaf.flags=EP_FromDDL;leaf.w.iOfst=4;db.errByteOffset=-2;sqlite3RecordErrorOffsetOfExpr(&db,&leaf);printf("9\t%d\n",db.errByteOffset);
  db.errByteOffset=-2;sqlite3RecordErrorOffsetOfExpr(&db,0);printf("10\t%d\n",db.errByteOffset);
  return 0;
}
