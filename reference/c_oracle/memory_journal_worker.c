#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static unsigned hashBytes(const unsigned char *a, int n){
  unsigned h = 2166136261u;
  int i;
  for(i=0; i<n; i++){ h ^= a[i]; h *= 16777619u; }
  return h;
}

int main(void){
  sqlite3_vfs *vfs;
  sqlite3_file *file;
  unsigned char input[1600];
  unsigned char output[1100];
  sqlite3_int64 size = -1;
  int i, rc;
  const char *path = "/tmp/sqlite-zig-memory-journal-differential.journal";
  const int flags = SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_MAIN_JOURNAL;

  if( sqlite3_initialize()!=SQLITE_OK ) return 2;
  vfs = sqlite3_vfs_find(0);
  if( !vfs ) return 3;
  file = sqlite3_malloc64(sqlite3JournalSize(vfs));
  if( !file ) return 4;
  memset(file,0,sqlite3JournalSize(vfs));
  sqlite3MemJournalOpen(file);
  printf("open\t%d\t%d\n", file->pMethods!=0, sqlite3JournalIsInMemory(file));
  for(i=0; i<(int)sizeof(input); i++) input[i] = (unsigned char)(i*37 + 11);
  rc = file->pMethods->xWrite(file,input,sizeof(input),0);
  file->pMethods->xFileSize(file,&size);
  printf("write\t%d\t%lld\n",rc,(long long)size);
  memset(output,0,sizeof(output));
  rc = file->pMethods->xRead(file,output,sizeof(output),500);
  printf("read\t%d\t%u\t%u\t%u\n",rc,hashBytes(output,sizeof(output)),output[0],output[1099]);
  rc = file->pMethods->xRead(file,output,sizeof(output),501);
  printf("short\t%d\n",rc);
  rc = file->pMethods->xWrite(file,"HEADER",6,0);
  memset(output,0,6);
  file->pMethods->xRead(file,output,6,0);
  printf("header\t%d\t%u\n",rc,hashBytes(output,6));
  rc = file->pMethods->xTruncate(file,900);
  file->pMethods->xFileSize(file,&size);
  printf("truncate\t%d\t%lld\n",rc,(long long)size);
  rc = file->pMethods->xWrite(file,"TAIL",4,900);
  memset(output,0,4);
  file->pMethods->xRead(file,output,4,900);
  file->pMethods->xFileSize(file,&size);
  printf("append\t%d\t%lld\t%u\n",rc,(long long)size,hashBytes(output,4));
  printf("close\t%d\n",file->pMethods->xClose(file));
  sqlite3_free(file);

  remove(path);
  file = sqlite3_malloc64(sqlite3JournalSize(vfs));
  if( !file ) return 5;
  memset(file,0,sqlite3JournalSize(vfs));
  rc = sqlite3JournalOpen(vfs,path,file,flags,32);
  printf("spill-open\t%d\t%d\n",rc,sqlite3JournalIsInMemory(file));
  rc = file->pMethods->xWrite(file,"0123456789abcdef",16,0);
  printf("spill-first\t%d\t%d\n",rc,sqlite3JournalIsInMemory(file));
  rc = file->pMethods->xWrite(file,"0123456789abcdef0123",20,16);
  file->pMethods->xFileSize(file,&size);
  printf("spill-second\t%d\t%d\t%lld\n",rc,sqlite3JournalIsInMemory(file),(long long)size);
  memset(output,0,36);
  rc = file->pMethods->xRead(file,output,36,0);
  printf("spill-read\t%d\t%u\n",rc,hashBytes(output,36));
  printf("spill-sync\t%d\n",file->pMethods->xSync(file,SQLITE_SYNC_NORMAL));
  printf("spill-close\t%d\n",file->pMethods->xClose(file));
  sqlite3_free(file);
  remove(path);
  sqlite3_shutdown();
  return 0;
}
