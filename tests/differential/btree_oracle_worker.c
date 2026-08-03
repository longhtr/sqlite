#include "sqlite3.c"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t hash_bytes(uint64_t h, const void *data, size_t length){
  const unsigned char *p = (const unsigned char*)data;
  size_t i;
  for(i=0; i<length; i++){
    h ^= p[i];
    h *= UINT64_C(1099511628211);
  }
  return h;
}
static uint64_t hash_u32(uint64_t h, uint32_t v){
  unsigned char b[4] = {(unsigned char)(v>>24),(unsigned char)(v>>16),(unsigned char)(v>>8),(unsigned char)v};
  return hash_bytes(h,b,4);
}
static uint64_t hash_u64(uint64_t h, uint64_t v){
  unsigned char b[8]; int i;
  for(i=0;i<8;i++) b[i]=(unsigned char)(v>>(56-8*i));
  return hash_bytes(h,b,8);
}
static uint64_t digest_payload(const unsigned char *data, int length){
  return hash_bytes(UINT64_C(14695981039346656037),data,(size_t)length);
}

static int scan_tree(sqlite3 *db, const char *fixture, const char *name, int root, int table){
  Btree *bt = db->aDb[0].pBt;
  BtCursor *cur = 0;
  KeyInfo *key_info = 0;
  unsigned char *payload = 0;
  uint64_t hash = UINT64_C(14695981039346656037);
  int count = 0, empty = 0, rc;
  rc = sqlite3BtreeBeginTrans(bt,0,0);
  if( rc!=SQLITE_OK ) return rc;
  cur = sqlite3_malloc(sqlite3BtreeCursorSize());
  if( !cur ) return SQLITE_NOMEM;
  sqlite3BtreeCursorZero(cur);
  if( !table ){
    int i;
    key_info = sqlite3KeyInfoAlloc(db,3,0);
    if( !key_info ){ sqlite3_free(cur); return SQLITE_NOMEM; }
    for(i=0;i<3;i++) key_info->aColl[i] = sqlite3FindCollSeq(db, db->enc, sqlite3StrBINARY, 0);
  }
  rc = sqlite3BtreeCursor(bt,(Pgno)root,0,key_info,cur);
  if( rc==SQLITE_OK ) rc = sqlite3BtreeFirst(cur,&empty);
  while( rc==SQLITE_OK && !empty ){
    u32 length = sqlite3BtreePayloadSize(cur);
    payload = sqlite3_malloc64(length ? length : 1);
    if( !payload ){ rc=SQLITE_NOMEM; break; }
    rc = sqlite3BtreePayload(cur,0,length,payload);
    if( rc!=SQLITE_OK ) break;
    hash = hash_bytes(hash,table ? "T" : "I",1);
    if( table ) hash = hash_u64(hash,(uint64_t)sqlite3BtreeIntegerKey(cur));
    hash = hash_u32(hash,length);
    hash = hash_bytes(hash,payload,length);
    sqlite3_free(payload); payload=0;
    count++;
    rc = sqlite3BtreeNext(cur,0);
    if( rc==SQLITE_DONE ){ rc=SQLITE_OK; break; }
  }
  sqlite3_free(payload);
  if( cur ) sqlite3BtreeCloseCursor(cur);
  sqlite3_free(cur);
  sqlite3KeyInfoUnref(key_info);
  printf("tree\t%s\t%s\t%d\t%d\t%016llx\n",fixture,name,rc,count,(unsigned long long)hash);
  return rc;
}

static void print_hex(const unsigned char *data, int length){
  static const char hex[]="0123456789abcdef"; int i;
  for(i=0;i<length;i++){ putchar(hex[data[i]>>4]); putchar(hex[data[i]&15]); }
}
static int selected_values(sqlite3 *db, const char *fixture){
  sqlite3_stmt *s = 0; int rc, step_rc = SQLITE_DONE, column;
  rc = sqlite3_prepare_v2(db,
    "SELECT id,i,r,t,b,z FROM items WHERE id IN(1,250,500,1099511627776) ORDER BY id",-1,&s,0);
  while( rc==SQLITE_OK && (step_rc=sqlite3_step(s))==SQLITE_ROW ){
    printf("record\t%s",fixture);
    for(column=0;column<6;column++){
      int type=sqlite3_column_type(s,column); putchar('\t');
      if(type==SQLITE_NULL){ putchar('N'); }
      else if(type==SQLITE_INTEGER){ printf("I%lld",(long long)sqlite3_column_int64(s,column)); }
      else if(type==SQLITE_FLOAT){
        double d=sqlite3_column_double(s,column); uint64_t bits; memcpy(&bits,&d,8);
        printf("R%016llx",(unsigned long long)bits);
      }else if(type==SQLITE_TEXT){
        const unsigned char *p=sqlite3_column_text(s,column); int n=sqlite3_column_bytes(s,column);
        putchar('T'); print_hex(p,n);
      }else{
        const unsigned char *p=sqlite3_column_blob(s,column); int n=sqlite3_column_bytes(s,column);
        putchar('B'); print_hex(p,n);
      }
    }
    putchar('\n');
  }
  if( rc==SQLITE_OK && step_rc!=SQLITE_DONE ) rc=step_rc;
  sqlite3_finalize(s);
  return rc;
}

static int index_seek(sqlite3 *db, const char *fixture){
  sqlite3_stmt *s=0; int rc;
  rc=sqlite3_prepare_v2(db,
    "SELECT id FROM items INDEXED BY items_t_i WHERE t='key-00250-x' AND i=4250",-1,&s,0);
  if(rc==SQLITE_OK){
    rc=sqlite3_step(s);
    if(rc==SQLITE_ROW){ printf("indexseek\t%s\t%lld\n",fixture,(long long)sqlite3_column_int64(s,0)); rc=SQLITE_OK; }
    else if(rc==SQLITE_DONE) rc=SQLITE_NOTFOUND;
  }
  sqlite3_finalize(s); return rc;
}

static int run_fixture(const char *fixture){
  sqlite3 *db=0; sqlite3_stmt *s=0; char path[256],uri[320]; int rc, step_rc=SQLITE_DONE;
  sqlite3_snprintf(sizeof(path),path,"tests/fixtures/btree/%s",fixture);
  sqlite3_snprintf(sizeof(uri),uri,"file:%s?immutable=1",path);
  rc=sqlite3_open_v2(uri,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_URI,0);
  if(rc!=SQLITE_OK) return rc;
  rc=sqlite3_prepare_v2(db,
    "SELECT type,name,rootpage FROM sqlite_schema WHERE type IN('table','index') "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",-1,&s,0);
  while(rc==SQLITE_OK && (step_rc=sqlite3_step(s))==SQLITE_ROW){
    const char *type=(const char*)sqlite3_column_text(s,0);
    const char *name=(const char*)sqlite3_column_text(s,1);
    int root=sqlite3_column_int(s,2);
    printf("root\t%s\t%s\t%s\t%d\n",fixture,type,name,root);
  }
  if(rc==SQLITE_OK && step_rc!=SQLITE_DONE) rc=step_rc;
  sqlite3_finalize(s); s=0;
  if(rc!=SQLITE_OK) goto done;
  rc=sqlite3_prepare_v2(db,
    "SELECT type,name,rootpage FROM sqlite_schema WHERE type IN('table','index') "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",-1,&s,0);
  while(rc==SQLITE_OK && (step_rc=sqlite3_step(s))==SQLITE_ROW){
    const char *type=(const char*)sqlite3_column_text(s,0);
    const char *name=(const char*)sqlite3_column_text(s,1);
    int root=sqlite3_column_int(s,2);
    rc=scan_tree(db,fixture,name,root,strcmp(type,"table")==0 && strcmp(name,"wr")!=0);
  }
  if(rc==SQLITE_OK && step_rc!=SQLITE_DONE) rc=step_rc;
  sqlite3_finalize(s); s=0;
  if(rc==SQLITE_OK) rc=selected_values(db,fixture);
  if(rc==SQLITE_OK) rc=index_seek(db,fixture);
 done:
  sqlite3_close(db);
  return rc;
}

int main(void){
  static const char *fixtures[]={
    "core-512.db","utf16le-1024.db","utf16be-2048.db","autovacuum-4096.db",
    "autovacuum-full-8192.db","core-16384.db","core-32768.db","wide-65536.db"
  };
  size_t i; int rc=sqlite3_initialize();
  for(i=0;rc==SQLITE_OK && i<sizeof(fixtures)/sizeof(fixtures[0]);i++) rc=run_fixture(fixtures[i]);
  if(rc!=SQLITE_OK) fprintf(stderr,"btree oracle rc=%d\n",rc);
  sqlite3_shutdown();
  return rc;
}
