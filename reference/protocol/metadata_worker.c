#include "sqlite3.h"

#include <stdio.h>
#include <string.h>

#ifndef ENGINE_NAME
#define ENGINE_NAME "unknown"
#endif

int main(void) {
  char line[1024];
  while (fgets(line, sizeof(line), stdin) != NULL) {
    line[strcspn(line, "\r\n")] = '\0';
    if (strcmp(line, "HELLO\t1") == 0) {
      printf("OK\t1\t%s\n", ENGINE_NAME);
    } else if (strcmp(line, "VERSION") == 0) {
      printf("VERSION\t%s\t%d\t%d\t%s\n",
             sqlite3_libversion(),
             sqlite3_libversion_number(),
             sqlite3_threadsafe(),
             sqlite3_sourceid());
    } else if (strcmp(line, "QUIT") == 0) {
      puts("BYE");
      fflush(stdout);
      return 0;
    } else {
      puts("ERROR\tunknown-request");
    }
    fflush(stdout);
  }
  return ferror(stdin) ? 2 : 0;
}
