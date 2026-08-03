#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void hex_line(int id, const char *text){
  int i, n = text ? (int)strlen(text) : -1;
  printf("%d\t%d\t",id,n);
  if(text) for(i=0;i<n;i++) printf("%02x",(unsigned char)text[i]);
  printf("\n");
}
static void log_callback(void *context, int code, const char *message){
  (void)context;
  printf("8\t%d\t",code);
  while(*message) printf("%02x",(unsigned char)*message++);
  printf("\n");
}
int main(void){
  char *text;
  char buffer[16];
  sqlite3 *db = 0;
  Token token = {"token-bytes",5};
  if(sqlite3_config(SQLITE_CONFIG_LOG,log_callback,0)!=SQLITE_OK) return 2;
  text=sqlite3_mprintf("%d|%Q|%.2f",7,"a'b",1.25);hex_line(1,text);sqlite3_free(text);
  text=sqlite3_mprintf("");hex_line(2,text);sqlite3_free(text);
  text=sqlite3_mprintf("%#q","a\\\001b");hex_line(3,text);sqlite3_free(text);
  memset(buffer,0x7f,sizeof(buffer));sqlite3_snprintf(8,buffer,"abcdefghi");hex_line(4,buffer);
  memset(buffer,0x7f,sizeof(buffer));sqlite3_snprintf(1,buffer,"x");hex_line(5,buffer);
  memset(buffer,0x7f,sizeof(buffer));printf("6\t%d\t%02x\n",sqlite3_snprintf(0,buffer,"x")==buffer,(unsigned char)buffer[0]);
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK) return 3;
  text=sqlite3MPrintf(db,"%T",&token);hex_line(7,text);sqlite3DbFree(db,text);sqlite3_close(db);
  sqlite3_log(17,"error %d",9);
  sqlite3_shutdown();
  return 0;
}
