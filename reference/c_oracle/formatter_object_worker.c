#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void show(int id, sqlite3_str *value){
  char *text=sqlite3_str_value(value);
  int i,n=sqlite3_str_length(value);
  printf("%d\t%d\t%d\t",id,sqlite3_str_errcode(value),n);
  if(text) for(i=0;i<n;i++)printf("%02x",(unsigned char)text[i]); else printf("NULL");
  printf("\n");
}
int main(void){
  sqlite3_str *value;
  sqlite3 *db=0;
  char *text;
  if(sqlite3_initialize()!=SQLITE_OK)return 2;
  value=sqlite3_str_new(0);show(1,value);
  sqlite3_str_appendall(value,"hello");show(2,value);
  text=sqlite3_str_finish(value);printf("3\t%d\t",text!=0);if(text){int i;for(i=0;text[i];i++)printf("%02x",(unsigned char)text[i]);sqlite3_free(text);}printf("\n");
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 3;sqlite3_limit(db,SQLITE_LIMIT_LENGTH,30);
  value=sqlite3_str_new(db);sqlite3_str_appendall(value,"1234567890123456789012345678901");show(4,value);
  text=sqlite3_str_finish(value);printf("5\t%d\n",text==0);sqlite3_free(text);
  value=sqlite3_str_new(0);sqlite3_str_appendall(value,"discard");sqlite3_str_free(value);
  sqlite3_close(db);sqlite3_shutdown();return 0;
}
