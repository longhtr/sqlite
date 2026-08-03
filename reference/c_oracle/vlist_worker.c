#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

int main(void){
  sqlite3 *db=0;VList *list=0;const char *name;
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 2;
  printf("1\t%d\t%d\n",sqlite3VListNameToNum(list,"x",1),sqlite3VListNumToName(list,1)==0);
  list=sqlite3VListAdd(db,list,"a",1,1);printf("2\t%d\t%d\n",list[0],list[1]);
  list=sqlite3VListAdd(db,list,"longname",8,7);printf("3\t%d\t%d\n",list[0],list[1]);
  printf("4\t%d\t%d\n",sqlite3VListNameToNum(list,"a",1),sqlite3VListNameToNum(list,"longname",8));
  list=sqlite3VListAdd(db,list,"third-long-name",15,9);printf("5\t%d\t%d\n",list[0],list[1]);
  name=sqlite3VListNumToName(list,9);printf("6\t%s\n",name?name:"NULL");
  printf("7\t%d\t%d\n",sqlite3VListNameToNum(list,"missing",7),sqlite3VListNumToName(list,99)==0);
  printf("8\t%d\n",sqlite3VListNameToNum(list,"long",4));
  sqlite3DbFree(db,list);sqlite3_close(db);return 0;
}
