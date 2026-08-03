#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void show(int id, sqlite3 *db, const unsigned char *input, int bytes, int encoding){
  char *text=sqlite3Utf16to8(db,input,bytes,encoding);
  int i,n=text?(int)strlen(text):-1;
  printf("%d\t%d\t",id,n);
  if(text){for(i=0;i<n;i++)printf("%02x",(unsigned char)text[i]);sqlite3DbFree(db,text);}else printf("NULL");
  printf("\n");
}
int main(void){
  sqlite3 *db=0;
  static const unsigned char le1[]={'h',0,'e',0,'l',0,'l',0,'o',0,0,0};
  static const unsigned char be1[]={0,'h',0,'i',0,0};
  static const unsigned char euro_le[]={0xac,0x20,0,0};
  static const unsigned char smile_le[]={0x3d,0xd8,0,0xde,0,0};
  static const unsigned char bounded[]={ 'a',0,'b',0,'c',0,0,0 };
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 2;
  show(1,db,le1,-1,SQLITE_UTF16LE);
  show(2,db,be1,-1,SQLITE_UTF16BE);
  show(3,db,euro_le,-1,SQLITE_UTF16LE);
  show(4,db,smile_le,-1,SQLITE_UTF16LE);
  show(5,db,bounded,4,SQLITE_UTF16LE);
  sqlite3_close(db);return 0;
}
