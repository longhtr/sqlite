#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

static void show8(int id,const char *sql){printf("%d\t%d\n",id,sqlite3_complete(sql));}
static void show16(int id,const unsigned short *sql){printf("%d\t%d\n",id,sqlite3_complete16(sql));}
int main(void){
  static const unsigned short u1[]={'s','e','l','e','c','t',' ',0x20ac,';',0};
  static const unsigned short u2[]={'s','e','l','e','c','t',' ',0x20ac,0};
  static const unsigned short u3[]={'c','r','e','a','t','e',' ','t','r','i','g','g','e','r',' ','t',' ','b','e','g','i','n',' ','e','n','d',';',0};
  static const unsigned short u4[]={'c','r','e','a','t','e',' ','t','r','i','g','g','e','r',' ','t',' ','b','e','g','i','n',' ','e','n','d',';',' ', 'e','n','d',';',0};
  show8(1,"");show8(2,"  \n");show8(3,"select 1;");show8(4,"select ';'");
  show8(5,"select ';'; -- tail");show8(6,"select 1; /* tail */");show8(7,"select 1; /* tail");
  show8(8,"create table t(x);");show8(9,"create trigger t after insert on x begin select 1; end");
  show8(10,"create trigger t after insert on x begin select 1; end;");
  show8(11,"explain create temporary trigger t after insert on x begin select 1; end;");
  show8(12,"select [unterminated");show16(13,u1);show16(14,u2);show16(15,u3);show16(16,u4);
  sqlite3_shutdown();return 0;
}
