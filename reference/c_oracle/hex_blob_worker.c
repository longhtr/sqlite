#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void show(int id,sqlite3 *db,const char *text){int i,n=(int)strlen(text),out=(n-1)/2;unsigned char *bytes=sqlite3HexToBlob(db,text,n);printf("%d\t%d\t",id,out);for(i=0;i<out;i++)printf("%02x",bytes[i]);printf("\t%02x\n",bytes[out]);sqlite3DbFree(db,bytes);}
int main(void){sqlite3 *db=0;if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 2;show(1,db,"'");show(2,db,"00'");show(3,db,"4142'");show(4,db,"deadbeef'");show(5,db,"Ff'");sqlite3_close(db);return 0;}
