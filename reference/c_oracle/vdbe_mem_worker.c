#include "sqlite3.c"
#include <stdint.h>
#include <string.h>

int64_t probe_real_to_i64(uint64_t bits) {
  double value;
  memcpy(&value, &bits, sizeof(value));
  return sqlite3RealToI64(value);
}

int probe_real_same_as_int(uint64_t bits, int64_t integer) {
  double value;
  memcpy(&value, &bits, sizeof(value));
  return sqlite3RealSameAsInt(value, integer);
}

int probe_int_float_compare(int64_t integer, uint64_t bits) {
  double value;
  memcpy(&value, &bits, sizeof(value));
  return sqlite3IntFloatCompare(integer, value);
}

uint32_t probe_serial_type_len(uint32_t serial_type) {
  return sqlite3VdbeSerialTypeLen(serial_type);
}

uint8_t probe_one_byte_serial_type_len(uint8_t serial_type) {
  return sqlite3VdbeOneByteSerialTypeLen(serial_type);
}

void probe_serial_get(const uint8_t *bytes, uint32_t serial_type,
                      uint16_t *output_flags, uint64_t *output_union,
                      int *output_length, int *output_alias) {
  Mem value;
  memset(&value, 0xa5, sizeof(value));
  sqlite3VdbeSerialGet(bytes, serial_type, &value);
  *output_flags = value.flags;
  memcpy(output_union, &value.u, sizeof(*output_union));
  *output_length = value.n;
  *output_alias = value.z == (char*)bytes;
}

static Mem input_mem(uint16_t flags, uint64_t union_bits, uint8_t encoding,
                     uint8_t *data, size_t length) {
  Mem value;
  memset(&value, 0, sizeof(value));
  value.flags = flags;
  memcpy(&value.u, &union_bits, sizeof(union_bits));
  value.enc = encoding;
  value.z = (char*)data;
  value.n = (int)length;
  return value;
}

int64_t probe_int_value(uint16_t flags, uint64_t union_bits, uint8_t encoding,
                        uint8_t *data, size_t length) {
  Mem value = input_mem(flags, union_bits, encoding, data, length);
  return sqlite3VdbeIntValue(&value);
}

int probe_integerify(uint16_t flags, uint64_t union_bits, uint8_t encoding,
                     uint8_t *data, size_t length, uint16_t *output_flags,
                     uint64_t *output_union) {
  Mem value = input_mem(flags, union_bits, encoding, data, length);
  int result = sqlite3VdbeMemIntegerify(&value);
  *output_flags = value.flags;
  memcpy(output_union, &value.u, sizeof(*output_union));
  return result;
}

void probe_integer_affinity(uint16_t flags, uint64_t union_bits,
                            uint16_t *output_flags, uint64_t *output_union) {
  Mem value = input_mem(flags, union_bits, 0, 0, 0);
  sqlite3VdbeIntegerAffinity(&value);
  *output_flags = value.flags;
  memcpy(output_union, &value.u, sizeof(*output_union));
}

uintptr_t probe_noop_destructor(uintptr_t address) {
  sqlite3NoopDestructor((void*)address);
  return address;
}

void probe_mem_init(uint16_t flags, uintptr_t db_address, uint8_t *output) {
  Mem value;
  memset(&value, 0xa5, sizeof(value));
  sqlite3VdbeMemInit(&value, (sqlite3*)db_address, flags);
  memcpy(output, &value, sizeof(value));
}

static void allocator_db(sqlite3 *db);
static int lifecycle_destructor_count;
static void lifecycle_destructor(void *p) {
  if( p ) lifecycle_destructor_count++;
}
static void lifecycle_finalize(sqlite3_context *ctx) {
  ctx->pOut->u.i = 77;
  ctx->pOut->flags = MEM_Int;
  ctx->isError = 19;
}
static void lifecycle_value(sqlite3_context *ctx) {
  ctx->pOut->u.i = 88;
  ctx->pOut->flags = MEM_Int;
  ctx->isError = 23;
}
static int lifecycle_compare(void *unused, int n1, const void *v1, int n2, const void *v2) {
  int common=n1<n2?n1:n2, result;
  (void)unused;
  result=memcmp(v1,v2,(size_t)common);
  return result ? result : n1-n2;
}

void probe_mem_lifecycle(unsigned scenario, uint64_t output[16]) {
  sqlite3 db;
  Mem value, other;
  FuncDef function;
  uint8_t bytes[32];
  memset(output,0,16*sizeof(output[0]));
  memset(&db,0,sizeof(db));
  memset(&value,0,sizeof(value));
  memset(&other,0,sizeof(other));
  memset(&function,0,sizeof(function));
  memset(bytes,0,sizeof(bytes));
  lifecycle_destructor_count = 0;
  sqlite3_initialize();
  if( scenario==0 ){
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    sqlite3VdbeMemSetNull(&value);
    output[0]=lifecycle_destructor_count; output[1]=value.flags;
  }else if( scenario==1 ){
    sqlite3_int64 before=sqlite3_memory_used();
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    value.zMalloc=sqlite3_malloc(17); value.szMalloc=(int)sqlite3_msize(value.zMalloc);
    sqlite3VdbeMemRelease(&value);
    output[0]=lifecycle_destructor_count; output[1]=value.flags;
    output[2]=value.szMalloc; output[3]=value.z==0;
    output[4]=sqlite3_memory_used()==before;
  }else if( scenario==2 ){
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    sqlite3VdbeMemSetZeroBlob(&value,12);
    output[0]=lifecycle_destructor_count; output[1]=value.flags;
    output[2]=value.n; output[3]=value.u.nZero; output[4]=value.enc; output[5]=value.z==0;
  }else if( scenario==3 ){
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    sqlite3VdbeMemSetInt64(&value,-42);
    output[0]=lifecycle_destructor_count; output[1]=value.flags;
    memcpy(&output[2],&value.u.i,8);
  }else if( scenario==4 ){
    double real=4.5, nanValue;
    uint64_t nanBits=UINT64_C(0x7ff8000000000001);
    value.flags=MEM_Null;
    sqlite3VdbeMemSetDouble(&value,real);
    output[0]=value.flags; memcpy(&output[1],&value.u.r,8);
    memcpy(&nanValue,&nanBits,8);
    sqlite3VdbeMemSetDouble(&value,nanValue);
    output[2]=value.flags;
  }else if( scenario==5 ){
    value.flags=MEM_Null;
    sqlite3VdbeMemSetPointer(&value,bytes,"probe",lifecycle_destructor);
    output[0]=value.flags; output[1]=value.eSubtype;
    output[2]=strcmp(value.u.zPType,"probe")==0; output[3]=value.z==(char*)bytes;
    sqlite3VdbeMemSetNull(&value);
    output[4]=lifecycle_destructor_count; output[5]=value.flags;
  }else if( scenario==6 ){
    value.flags=MEM_Null; value.db=0;
    other.flags=MEM_Str|MEM_Dyn; other.z=(char*)bytes; other.n=7; other.db=0;
    sqlite3VdbeMemShallowCopy(&value,&other,MEM_Ephem);
    output[0]=value.flags; output[1]=value.z==(char*)bytes; output[2]=value.n;
  }else if( scenario==7 ){
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    other.flags=MEM_Int; other.u.i=123; other.db=0;
    sqlite3VdbeMemMove(&value,&other);
    output[0]=lifecycle_destructor_count; output[1]=value.flags; output[2]=value.u.i;
    output[3]=other.flags; output[4]=other.szMalloc;
  }else if( scenario==8 ){
    db.aLimit[SQLITE_LIMIT_LENGTH]=5;
    value.db=&db; value.flags=MEM_Blob|MEM_Zero; value.n=4; value.u.nZero=3;
    output[0]=sqlite3VdbeMemTooBig(&value);
    value.u.nZero=1;
    output[1]=sqlite3VdbeMemTooBig(&value);
  }else if( scenario==9 ){
    db.enc=SQLITE_UTF8;
    function.xFinalize=lifecycle_finalize;
    value.db=&db; value.flags=MEM_Agg; value.u.pDef=&function;
    output[0]=sqlite3VdbeMemFinalize(&value,&function);
    output[1]=value.flags; output[2]=value.u.i;
  }else if( scenario==10 ){
    db.enc=SQLITE_UTF8;
    function.xValue=lifecycle_value;
    value.db=&db; value.flags=MEM_Agg; value.u.pDef=&function;
    other.db=&db; other.flags=MEM_Null;
    output[0]=sqlite3VdbeMemAggValue(&value,&other,&function);
    output[1]=other.flags; output[2]=other.u.i;
  }else if( scenario==11 ){
    memcpy(bytes,"abc",3);
    value.flags=MEM_Str|MEM_Ephem; value.z=(char*)bytes; value.n=3;
    output[0]=sqlite3VdbeMemGrow(&value,16,1); output[1]=value.flags;
    output[2]=value.z==value.zMalloc; output[3]=value.szMalloc>=16;
    output[4]=memcmp(value.z,"abc",3)==0;
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==12 ){
    memcpy(bytes,"abc",3);
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.n=3; value.xDel=lifecycle_destructor;
    output[0]=sqlite3VdbeMemGrow(&value,16,1); output[1]=lifecycle_destructor_count;
    output[2]=value.flags; output[3]=memcmp(value.z,"abc",3)==0;
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==13 ){
    value.zMalloc=sqlite3_malloc(32); value.szMalloc=(int)sqlite3_msize(value.zMalloc);
    value.flags=MEM_Int|MEM_Str; value.u.i=44;
    output[0]=sqlite3VdbeMemClearAndResize(&value,16); output[1]=value.flags;
    output[2]=value.z==value.zMalloc; output[3]=value.u.i;
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==14 ){
    memcpy(bytes,"abc",3);
    value.flags=MEM_Str|MEM_Ephem; value.z=(char*)bytes; value.n=3; value.enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeMemNulTerminate(&value); output[1]=value.flags;
    output[2]=value.z==value.zMalloc; output[3]=value.z[3]; output[4]=value.z[4];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==15 ){
    value.zMalloc=sqlite3_malloc(8); value.z=value.zMalloc;
    value.szMalloc=(int)sqlite3_msize(value.zMalloc); value.n=3; value.enc=SQLITE_UTF8;
    value.flags=MEM_Str; memcpy(value.z,"abc",3);
    output[0]=sqlite3VdbeMemZeroTerminateIfAble(&value); output[1]=value.flags;
    output[2]=value.z[3];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==16 ){
    memcpy(bytes,"ab",2);
    value.flags=MEM_Blob|MEM_Zero|MEM_Ephem; value.z=(char*)bytes; value.n=2; value.u.nZero=3;
    output[0]=sqlite3VdbeMemExpandBlob(&value); output[1]=value.flags; output[2]=value.n;
    output[3]=value.z[0]; output[4]=value.z[1]; output[5]=value.z[2]; output[6]=value.z[4];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==17 ){
    memcpy(bytes,"abc",3);
    value.flags=MEM_Str|MEM_Ephem; value.z=(char*)bytes; value.n=3; value.enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeMemMakeWriteable(&value); output[1]=value.flags;
    output[2]=value.z==value.zMalloc; output[3]=value.z[3];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==18 ){
    sqlite3_int64 used=sqlite3_memory_used();
    sqlite3_hard_heap_limit64(used+1);
    allocator_db(&db);
    memcpy(bytes,"abc",3);
    value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)bytes; value.n=3;
    output[0]=sqlite3VdbeMemGrow(&value,4096,1); output[1]=value.flags;
    output[2]=value.szMalloc; output[3]=value.z==0; output[4]=db.mallocFailed;
    sqlite3_hard_heap_limit64(0);
    sqlite3OomClear(&db);
  }else if( scenario==19 ){
    uint8_t sourceBytes[8]="copy";
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    value.zMalloc=sqlite3_malloc(16); value.szMalloc=(int)sqlite3_msize(value.zMalloc);
    other.flags=MEM_Str|MEM_Ephem; other.z=(char*)sourceBytes; other.n=4; other.enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeMemCopy(&value,&other); output[1]=lifecycle_destructor_count;
    output[2]=value.flags; output[3]=value.z==value.zMalloc;
    output[4]=memcmp(value.z,"copy",4)==0; output[5]=value.z[4];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==20 ){
    allocator_db(&db);
    value.db=&db; value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    output[0]=sqlite3VdbeMemSetText(&value,0,0,SQLITE_TRANSIENT);
    output[1]=lifecycle_destructor_count; output[2]=value.flags;
  }else if( scenario==21 ){
    uint8_t sourceBytes[8]="text";
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetText(&value,(char*)sourceBytes,-1,SQLITE_TRANSIENT);
    output[1]=value.flags; output[2]=value.n; output[3]=value.enc;
    output[4]=value.z==value.zMalloc; output[5]=memcmp(value.z,"text",5)==0;
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==22 ){
    uint8_t sourceBytes[8]="value";
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetText(&value,(char*)sourceBytes,3,SQLITE_TRANSIENT);
    output[1]=value.flags; output[2]=value.n; output[3]=value.z[3];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==23 ){
    uint8_t sourceBytes[8]="alias";
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetText(&value,(char*)sourceBytes,5,SQLITE_STATIC);
    output[1]=value.flags; output[2]=value.z==(char*)sourceBytes; output[3]=value.n;
  }else if( scenario==24 ){
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; memcpy(bytes,"owned",5); value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetText(&value,(char*)bytes,5,lifecycle_destructor);
    output[1]=value.flags; sqlite3VdbeMemRelease(&value);
    output[2]=lifecycle_destructor_count; output[3]=value.z==0;
  }else if( scenario==25 ){
    char *owned;
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    owned=sqlite3DbMallocRawNN(&db,12); memcpy(owned,"dynamic",7);
    output[0]=sqlite3VdbeMemSetText(&value,owned,7,SQLITE_DYNAMIC);
    output[1]=value.flags; output[2]=value.z==value.zMalloc; output[3]=value.szMalloc>=12;
    sqlite3VdbeMemRelease(&value); output[4]=value.z==0;
  }else if( scenario==26 ){
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=3;
    memcpy(bytes,"large",5); value.db=&db; value.flags=MEM_Int; value.u.i=1;
    output[0]=sqlite3VdbeMemSetText(&value,(char*)bytes,5,lifecycle_destructor);
    output[1]=lifecycle_destructor_count; output[2]=value.flags;
  }else if( scenario==27 ){
    sqlite3_int64 used;
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    used=sqlite3_memory_used(); sqlite3_hard_heap_limit64(used+1);
    output[0]=sqlite3VdbeMemSetText(&value,"oom",3,SQLITE_TRANSIENT);
    output[1]=value.flags; output[2]=value.szMalloc; output[3]=value.z==0; output[4]=db.mallocFailed;
    sqlite3_hard_heap_limit64(0); sqlite3OomClear(&db);
  }else if( scenario==28 ){
    uint8_t sourceBytes[8]={0x41,0xe2,0x82,0xac,0xf0,0x9f,0x98,0x80}; int i;
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=8; value.enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeMemTranslate(&value,SQLITE_UTF16LE); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    for(i=0;i<value.n && i<10;i++) output[4+i]=(unsigned char)value.z[i];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==29 ){
    uint8_t sourceBytes[8]={0x41,0,0xac,0x20,0x3d,0xd8,0,0xde}; int i;
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=8; value.enc=SQLITE_UTF16LE;
    output[0]=sqlite3VdbeMemTranslate(&value,SQLITE_UTF8); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    for(i=0;i<value.n && i<10;i++) output[4+i]=(unsigned char)value.z[i];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==30 ){
    uint8_t sourceBytes[4]={0x41,0,0xac,0x20};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=4; value.enc=SQLITE_UTF16LE;
    output[0]=sqlite3VdbeMemTranslate(&value,SQLITE_UTF16BE); output[1]=value.flags; output[2]=value.enc;
    output[3]=(unsigned char)value.z[0]; output[4]=(unsigned char)value.z[1]; output[5]=(unsigned char)value.z[2]; output[6]=(unsigned char)value.z[3];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==31 ){
    value.flags=MEM_Int; value.enc=SQLITE_UTF8; value.u.i=9;
    output[0]=sqlite3VdbeChangeEncoding(&value,SQLITE_UTF16BE); output[1]=value.flags; output[2]=value.enc; output[3]=value.u.i;
  }else if( scenario==32 ){
    uint8_t sourceBytes[6]={0xfe,0xff,0,0x41,0,0};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Static; value.z=(char*)sourceBytes; value.n=4; value.enc=SQLITE_UTF16LE;
    output[0]=sqlite3VdbeMemHandleBom(&value); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    output[4]=(unsigned char)value.z[0]; output[5]=(unsigned char)value.z[1]; output[6]=value.z==value.zMalloc;
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==33 ){
    uint8_t sourceBytes[4]={1,2,3,0};
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetStr(&value,(char*)sourceBytes,3,0,SQLITE_TRANSIENT); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    output[4]=(unsigned char)value.z[0]; output[5]=(unsigned char)value.z[2];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==34 ){
    uint8_t sourceBytes[6]={0xff,0xfe,0x41,0,0,0};
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetStr(&value,(char*)sourceBytes,-1,SQLITE_UTF16LE,SQLITE_TRANSIENT); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    output[4]=(unsigned char)value.z[0]; output[5]=(unsigned char)value.z[1];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==35 ){
    uint8_t sourceBytes[4]={0,0x41,0,0x42};
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    output[0]=sqlite3VdbeMemSetStr(&value,(char*)sourceBytes,4,SQLITE_UTF16BE,lifecycle_destructor); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    sqlite3VdbeMemRelease(&value); output[4]=lifecycle_destructor_count;
  }else if( scenario==36 ){
    sqlite3_int64 used; uint8_t sourceBytes[3]={'a','b','c'};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=3; value.enc=SQLITE_UTF8;
    used=sqlite3_memory_used(); sqlite3_hard_heap_limit64(used+1);
    output[0]=sqlite3VdbeMemTranslate(&value,SQLITE_UTF16LE); output[1]=value.flags; output[2]=value.enc; output[3]=value.z==(char*)sourceBytes; output[4]=db.mallocFailed;
    sqlite3_hard_heap_limit64(0); sqlite3OomClear(&db);
  }else if( scenario==37 ){
    double real; uint8_t sourceBytes[10]=" 1.25e2 ";
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Term|MEM_Static; value.z=(char*)sourceBytes; value.n=9; value.enc=SQLITE_UTF8;
    output[0]=(uint32_t)sqlite3MemRealValueRC(&value,&real); memcpy(&output[1],&real,8);
  }else if( scenario==38 ){
    double real; uint8_t sourceBytes[4]={'4','.','5','x'};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=4; value.enc=SQLITE_UTF8;
    output[0]=(uint32_t)sqlite3MemRealValueRC(&value,&real); memcpy(&output[1],&real,8); output[2]=value.flags;
  }else if( scenario==39 ){
    double real; uint8_t sourceBytes[6]={'4',0,'.',0,'5',0};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=6; value.enc=SQLITE_UTF16LE;
    output[0]=(uint32_t)sqlite3MemRealValueRC(&value,&real); memcpy(&output[1],&real,8);
  }else if( scenario==40 ){
    double real; uint8_t sourceBytes[4]={'4',1,'2',0};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=4; value.enc=SQLITE_UTF16LE;
    output[0]=(uint32_t)sqlite3MemRealValueRC(&value,&real); memcpy(&output[1],&real,8);
  }else if( scenario==41 ){
    value.flags=MEM_Int; value.u.i=9007199254740991LL;
    { double real=sqlite3VdbeRealValue(&value); memcpy(&output[0],&real,8); }
  }else if( scenario==42 ){
    uint8_t sourceBytes[2]={'0',0};
    value.flags=MEM_Null; output[0]=sqlite3VdbeBooleanValue(&value,7);
    value.flags=MEM_Str|MEM_Term|MEM_Static; value.z=(char*)sourceBytes; value.n=1; value.enc=SQLITE_UTF8;
    output[1]=sqlite3VdbeBooleanValue(&value,7); sourceBytes[0]='2'; output[2]=sqlite3VdbeBooleanValue(&value,7);
  }else if( scenario==43 ){
    uint8_t sourceBytes[4]={'4','.','5',0};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Term|MEM_Static; value.z=(char*)sourceBytes; value.n=3; value.enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeMemRealify(&value); output[1]=value.flags; memcpy(&output[2],&value.u.r,8);
  }else if( scenario>=44 && scenario<=47 ){
    static const char *texts[]={"42x","4.5","4.0","abc"}; const char *text=texts[scenario-44];
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Term|MEM_Static; value.z=(char*)text; value.n=(int)strlen(text); value.enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeMemNumerify(&value); output[1]=value.flags; memcpy(&output[2],&value.u,8);
  }else if( scenario==48 ){
    uint8_t sourceBytes[4]={'4',0,'2',0};
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Ephem; value.z=(char*)sourceBytes; value.n=4; value.enc=SQLITE_UTF16LE;
    output[0]=sqlite3VdbeMemNumerify(&value); output[1]=value.flags; memcpy(&output[2],&value.u,8);
  }else if( scenario>=49 && scenario<=54 ){
    static const double reals[]={4.5,1.0,1e100,1.2345678901234567}; int i;
    allocator_db(&db); db.nFpDigit=17; value.db=&db;
    if( scenario==49 ){ value.flags=MEM_Int; value.u.i=-9223372036854775807LL; }
    else if( scenario==50 ){ value.flags=MEM_IntReal; value.u.i=42; }
    else { value.flags=MEM_Real; value.u.r=reals[scenario-51]; }
    output[0]=sqlite3VdbeMemStringify(&value,SQLITE_UTF8,scenario==54); output[1]=value.flags; output[2]=value.enc; output[3]=value.n;
    for(i=0;i<=value.n && i<12;i++) output[4+i]=(unsigned char)value.z[i];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==55 ){
    const unsigned char *text;
    allocator_db(&db); db.nFpDigit=17; value.db=&db; value.flags=MEM_Int; value.u.i=42;
    text=sqlite3ValueText(&value,SQLITE_UTF8); output[0]=text!=0; output[1]=value.flags; output[2]=value.n; output[3]=text[0]; output[4]=text[1]; output[5]=text[2];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==56 ){
    const unsigned char *text; uint8_t sourceBytes[2]={'a','b'};
    allocator_db(&db); value.db=&db; value.flags=MEM_Blob|MEM_Zero|MEM_Ephem; value.z=(char*)sourceBytes; value.n=2; value.u.nZero=3; value.enc=SQLITE_UTF8;
    text=sqlite3ValueText(&value,SQLITE_UTF8); output[0]=text!=0; output[1]=value.flags; output[2]=value.n; output[3]=text[0]; output[4]=text[1]; output[5]=text[2]; output[6]=text[4]; output[7]=text[5];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==57 ){
    uint8_t sourceBytes[4]={'a',0,'b',0};
    value.flags=MEM_Str|MEM_Static; value.z=(char*)sourceBytes; value.n=4; value.enc=SQLITE_UTF16LE;
    output[0]=sqlite3ValueBytes(&value,SQLITE_UTF16BE); output[1]=value.enc; output[2]=value.flags;
  }else if( scenario==58 ){
    value.flags=MEM_Blob|MEM_Zero; value.n=2; value.u.nZero=5;
    output[0]=sqlite3ValueBytes(&value,SQLITE_UTF8);
  }else if( scenario==59 ){
    sqlite3_int64 before=sqlite3_memory_used(); Mem *created;
    allocator_db(&db); created=sqlite3ValueNew(&db); output[0]=created!=0; output[1]=created->flags; output[2]=created->db==&db;
    sqlite3ValueFree(created); output[3]=sqlite3_memory_used()==before;
  }else if( scenario==60 ){
    value.flags=MEM_Str|MEM_Dyn; value.z=(char*)bytes; value.xDel=lifecycle_destructor;
    output[0]=sqlite3ValueIsOfClass(&value,lifecycle_destructor); output[1]=sqlite3ValueIsOfClass(&value,sqlite3_free);
  }else if( scenario==61 ){
    uint8_t sourceBytes[4]={'x','y','z',0};
    allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null;
    sqlite3ValueSetStr(&value,3,sourceBytes,SQLITE_UTF8,SQLITE_TRANSIENT); output[0]=value.flags; output[1]=value.n; output[2]=value.z[0]; output[3]=value.z[2];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==62 || scenario==63 ){
    char *text=scenario==62?"48.00":"x";
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Term|MEM_Static; value.z=text; value.n=(int)strlen(text); value.enc=SQLITE_UTF8;
    sqlite3ValueApplyAffinity(&value,SQLITE_AFF_NUMERIC,SQLITE_UTF8); output[0]=value.flags; memcpy(&output[1],&value.u,8);
  }else if( scenario==64 ){
    allocator_db(&db); db.nFpDigit=17; value.db=&db; value.flags=MEM_Int; value.u.i=42;
    sqlite3ValueApplyAffinity(&value,SQLITE_AFF_TEXT,SQLITE_UTF8); output[0]=value.flags; output[1]=value.n; output[2]=value.z[0]; output[3]=value.z[1];
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==65 ){
    value.flags=MEM_Real; value.u.r=4.0; sqlite3ValueApplyAffinity(&value,SQLITE_AFF_REAL,SQLITE_UTF8);
    output[0]=value.flags; memcpy(&output[1],&value.u,8);
  }else if( scenario>=66 && scenario<=71 ){
    static const char *texts[]={0,"48.00","4.5","4.5","ab",0}; int rc;
    allocator_db(&db); db.nFpDigit=17; value.db=&db;
    if( scenario==66 ){ value.flags=MEM_Int; value.u.i=42; }
    else if( scenario==71 ){ value.flags=MEM_Null; }
    else { value.flags=(scenario==70?MEM_Blob:MEM_Str)|MEM_Term|MEM_Static; value.z=(char*)texts[scenario-66]; value.n=(int)strlen(texts[scenario-66]); value.enc=SQLITE_UTF8; }
    rc=sqlite3VdbeMemCast(&value,(u8[]){SQLITE_AFF_BLOB,SQLITE_AFF_NUMERIC,SQLITE_AFF_INTEGER,SQLITE_AFF_REAL,SQLITE_AFF_TEXT,SQLITE_AFF_TEXT}[scenario-66],scenario==70?SQLITE_UTF16LE:SQLITE_UTF8);
    output[0]=rc; output[1]=value.flags; output[2]=value.enc; output[3]=value.n; memcpy(&output[4],&value.u,8);
    if(value.z && (value.flags&(MEM_Str|MEM_Blob))){ output[5]=(unsigned char)value.z[0]; output[6]=(unsigned char)value.z[1]; }
    sqlite3VdbeMemRelease(&value);
  }else if( scenario==72 ){
    Mem array[3]; memset(array,0xa5,sizeof(array)); allocator_db(&db);
    initMemArray(array,3,&db,MEM_Null); output[0]=array[0].flags; output[1]=array[1].flags; output[2]=array[2].flags;
    output[3]=array[0].db==&db; output[4]=array[2].db==&db; output[5]=array[0].szMalloc; output[6]=array[2].szMalloc;
  }else if( scenario==73 ){
    Mem array[3]; sqlite3_int64 before;
    memset(array,0,sizeof(array)); allocator_db(&db); before=sqlite3_memory_used();
    array[0].db=&db; array[0].flags=MEM_Str|MEM_Dyn; array[0].z=(char*)bytes; array[0].xDel=lifecycle_destructor;
    array[1].db=&db; array[1].flags=MEM_Str; array[1].zMalloc=sqlite3DbMallocRawNN(&db,16); array[1].z=array[1].zMalloc; array[1].szMalloc=sqlite3DbMallocSize(&db,array[1].zMalloc);
    array[2].db=&db; array[2].flags=MEM_Int; array[2].u.i=7;
    releaseMemArray(array,3); output[0]=lifecycle_destructor_count; output[1]=array[0].flags; output[2]=array[1].flags; output[3]=array[1].szMalloc; output[4]=array[2].flags; output[5]=sqlite3_memory_used()==before;
  }else if( scenario==74 ){
    Mem array[1]; int measured=0; void *allocation;
    memset(array,0,sizeof(array)); allocator_db(&db); allocation=sqlite3DbMallocRawNN(&db,17);
    array[0].db=&db; array[0].flags=MEM_Str; array[0].zMalloc=allocation; array[0].z=allocation; array[0].szMalloc=sqlite3DbMallocSize(&db,allocation);
    db.pnBytesFreed=&measured; releaseMemArray(array,1); output[0]=measured; output[1]=array[0].flags; output[2]=array[0].szMalloc;
    db.pnBytesFreed=0; sqlite3DbFreeNN(&db,allocation);
  }else if( scenario==75 ){
    value.flags=MEM_Null; other.flags=MEM_Null; output[0]=(uint32_t)sqlite3MemCompare(&value,&other,0);
    other.flags=MEM_Int; other.u.i=0; output[1]=(uint32_t)sqlite3MemCompare(&value,&other,0); output[2]=(uint32_t)sqlite3MemCompare(&other,&value,0);
  }else if( scenario==76 ){
    value.flags=MEM_Int; value.u.i=-5; other.flags=MEM_IntReal; other.u.i=7;
    output[0]=(uint32_t)sqlite3MemCompare(&value,&other,0); output[1]=(uint32_t)sqlite3MemCompare(&other,&value,0); other.u.i=-5; output[2]=(uint32_t)sqlite3MemCompare(&value,&other,0);
  }else if( scenario==77 ){
    value.flags=MEM_Int; value.u.i=9007199254740993LL; other.flags=MEM_Real; other.u.r=9007199254740992.0;
    output[0]=(uint32_t)sqlite3MemCompare(&value,&other,0); output[1]=(uint32_t)sqlite3MemCompare(&other,&value,0);
  }else if( scenario==78 ){
    value.flags=MEM_Real; value.u.r=-1.5; other.flags=MEM_Real; other.u.r=2.0;
    output[0]=(uint32_t)sqlite3MemCompare(&value,&other,0); other.u.r=-1.5; output[1]=(uint32_t)sqlite3MemCompare(&value,&other,0);
  }else if( scenario==79 ){
    value.flags=MEM_Int; value.u.i=9; other.flags=MEM_Str|MEM_Static; other.z="0"; other.n=1; other.enc=SQLITE_UTF8;
    output[0]=(uint32_t)sqlite3MemCompare(&value,&other,0); output[1]=(uint32_t)sqlite3MemCompare(&other,&value,0);
  }else if( scenario==80 ){
    value.flags=MEM_Str|MEM_Static; value.z="z"; value.n=1; value.enc=SQLITE_UTF8;
    other.flags=MEM_Blob|MEM_Static; other.z="a"; other.n=1;
    output[0]=(uint32_t)sqlite3MemCompare(&value,&other,0); output[1]=(uint32_t)sqlite3MemCompare(&other,&value,0);
  }else if( scenario==81 ){
    value.flags=MEM_Blob|MEM_Static; value.z="abc"; value.n=3; other.flags=MEM_Blob|MEM_Static; other.z="abd"; other.n=3;
    output[0]=(uint32_t)sqlite3BlobCompare(&value,&other); other.z="abcx"; other.n=4; output[1]=(uint32_t)sqlite3BlobCompare(&value,&other);
  }else if( scenario==82 ){
    uint8_t zeros[3]={0,0,0}, mixed[3]={0,1,0};
    value.flags=MEM_Blob|MEM_Zero; value.n=0; value.u.nZero=3; other.flags=MEM_Blob|MEM_Zero; other.n=0; other.u.nZero=5;
    output[0]=(uint32_t)sqlite3BlobCompare(&value,&other); other.flags=MEM_Blob|MEM_Static; other.z=(char*)zeros; other.n=3; output[1]=(uint32_t)sqlite3BlobCompare(&value,&other);
    other.z=(char*)mixed; output[2]=(uint32_t)sqlite3BlobCompare(&value,&other);
  }else if( scenario==83 || scenario==84 ){
    CollSeq coll; uint8_t first16[2]={'a',0}, second16[2]={'b',0};
    memset(&coll,0,sizeof(coll)); allocator_db(&db); coll.enc=scenario==83?SQLITE_UTF8:SQLITE_UTF16LE; coll.xCmp=lifecycle_compare;
    value.db=&db; other.db=&db; value.flags=other.flags=MEM_Str|MEM_Static;
    if(scenario==83){value.z="abc";value.n=3;other.z="abd";other.n=3;value.enc=other.enc=SQLITE_UTF8;}
    else{value.z="a";value.n=1;other.z="b";other.n=1;value.enc=other.enc=SQLITE_UTF8;}
    output[0]=(uint32_t)sqlite3MemCompare(&value,&other,&coll); output[1]=value.flags; output[2]=other.flags;
    (void)first16;(void)second16;
  }else if( scenario==85 ){
    uint8_t data[8]={0xfe,0xff,0x7f,0xff,0xff,0xff,0xff,0xff};
    output[0]=(uint64_t)vdbeRecordDecodeInt(1,data); output[1]=(uint64_t)vdbeRecordDecodeInt(2,data); output[2]=(uint64_t)vdbeRecordDecodeInt(6,data); output[3]=(uint64_t)vdbeRecordDecodeInt(8,data); output[4]=(uint64_t)vdbeRecordDecodeInt(9,data);
  }else if( scenario==86 ){
    KeyInfo info; UnpackedRecord *record; uintptr_t offset;
    memset(&info,0,sizeof(info)); allocator_db(&db); info.db=&db; info.nKeyField=2;
    record=sqlite3VdbeAllocUnpackedRecord(&info); offset=(uintptr_t)record->aMem-(uintptr_t)record;
    output[0]=record!=0; output[1]=record->pKeyInfo==&info; output[2]=record->nField; output[3]=offset; output[4]=(offset&7)==0;
    sqlite3DbFreeNN(&db,record);
  }else if( scenario==87 ){
    KeyInfo info; UnpackedRecord *record; uint8_t key[6]={4,1,15,0,0xfe,'x'};
    memset(&info,0,sizeof(info)); allocator_db(&db); info.db=&db; info.nKeyField=2; info.enc=SQLITE_UTF8;
    record=sqlite3VdbeAllocUnpackedRecord(&info); sqlite3VdbeRecordUnpack(6,key,record);
    output[0]=record->default_rc; output[1]=record->nField; output[2]=record->aMem[0].flags; output[3]=(uint64_t)record->aMem[0].u.i;
    output[4]=record->aMem[1].flags; output[5]=record->aMem[1].n; output[6]=(unsigned char)record->aMem[1].z[0]; output[7]=record->aMem[2].flags;
    sqlite3DbFreeNN(&db,record);
  }else if( scenario==88 ){
    uint8_t normal[8]={0x3f,0xf0,0,0,0,0,0,0}; uint8_t nanValue[8]={0x7f,0xf8,0,0,0,0,0,1};
    output[0]=serialGet7(normal,&value); output[1]=value.flags; memcpy(&output[2],&value.u,8);
    output[3]=serialGet7(nanValue,&value); output[4]=value.flags; memcpy(&output[5],&value.u,8);
  }else if( scenario>=89 && scenario<=96 ){
    union { uint64_t align; unsigned char bytes[sizeof(KeyInfo)+sizeof(CollSeq*)*2]; } keyStorage; KeyInfo *keyInfo=(KeyInfo*)keyStorage.bytes; Mem rhs[2]; UnpackedRecord record; uint8_t sortFlags[2]={0,0};
    uint8_t key[5]={3,1,15,5,'b'}; RecordCompare comparison; int result;
    memset(&keyStorage,0,sizeof(keyStorage)); memset(rhs,0,sizeof(rhs)); memset(&record,0,sizeof(record)); allocator_db(&db);
    keyInfo->db=&db; keyInfo->enc=SQLITE_UTF8; keyInfo->nKeyField=2; keyInfo->nAllField=2; keyInfo->aSortFlags=sortFlags;
    rhs[0].db=rhs[1].db=&db; rhs[0].flags=MEM_Int; rhs[0].u.i=(scenario==89||scenario==90)?7:5;
    rhs[1].flags=MEM_Str|MEM_Static; rhs[1].z=scenario==93?"b":"a"; rhs[1].n=1; rhs[1].enc=SQLITE_UTF8;
    record.pKeyInfo=keyInfo; record.aMem=rhs; record.nField=2; record.default_rc=scenario==93?-1:0;
    if(scenario==90) sortFlags[0]=KEYINFO_ORDER_DESC;
    if(scenario==92) result=sqlite3VdbeRecordCompareWithSkip(5,key,&record,1);
    else if(scenario==94){ record.nField=1; rhs[0].flags=MEM_Null; sortFlags[0]=KEYINFO_ORDER_BIGNULL; result=sqlite3VdbeRecordCompare(5,key,&record); }
    else if(scenario==95){ result=sqlite3VdbeRecordCompare(4,key,&record); }
    else if(scenario==96){ record.nField=1; rhs[0].u.i=7; comparison=sqlite3VdbeFindCompare(&record); result=comparison(5,key,&record); output[3]=comparison==vdbeRecordCompareInt; output[4]=record.r1; output[5]=record.r2; output[6]=(uint64_t)record.u.i; }
    else result=sqlite3VdbeRecordCompare(5,key,&record);
    output[0]=(uint32_t)result; output[1]=record.errCode; output[2]=record.eqSeen;
  }else if( scenario==97 ){
    uint8_t source[2]={'a','b'}; const uint8_t *result;
    allocator_db(&db); value.db=&db; value.flags=MEM_Blob|MEM_Zero|MEM_Ephem; value.z=(char*)source; value.n=2; value.u.nZero=2;
    result=sqlite3_value_blob(&value); output[0]=result!=0; output[1]=value.flags; output[2]=value.n; output[3]=result[0]; output[4]=result[3]; sqlite3VdbeMemRelease(&value);
  }else if( scenario==98 ){
    value.flags=MEM_Int; value.u.i=0x1234567887654321LL;
    output[0]=(uint32_t)sqlite3_value_int(&value); output[1]=(uint64_t)sqlite3_value_int64(&value); {double r=sqlite3_value_double(&value);memcpy(&output[2],&r,8);}
  }else if( scenario==99 ){
    char marker; value.flags=MEM_Null|MEM_Term|MEM_Subtype|MEM_Static; value.eSubtype='p'; value.u.zPType="kind"; value.z=&marker;
    output[0]=sqlite3_value_subtype(&value); output[1]=sqlite3_value_pointer(&value,"kind")==&marker; output[2]=sqlite3_value_pointer(&value,"other")==0;
  }else if( scenario==100 ){
    uint16_t flags[]={MEM_Null,MEM_Int,MEM_Real,MEM_Str,MEM_Blob,MEM_IntReal}; int i;
    for(i=0;i<6;i++){value.flags=flags[i];output[i]=sqlite3_value_type(&value);}
  }else if( scenario==101 ){
    value.enc=SQLITE_UTF16BE; value.flags=MEM_Null|MEM_Zero|MEM_FromBind;
    output[0]=sqlite3_value_encoding(&value); output[1]=sqlite3_value_nochange(&value); output[2]=sqlite3_value_frombind(&value);
  }else if( scenario==102 ){
    allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Term|MEM_Static; value.z="48.0"; value.n=4; value.enc=SQLITE_UTF8;
    output[0]=sqlite3_value_numeric_type(&value); output[1]=value.flags; memcpy(&output[2],&value.u,8);
  }else if( scenario==103 ){
    sqlite3_value *duplicate; sqlite3_int64 before=sqlite3_memory_used();
    value.flags=MEM_Str|MEM_Static; value.z="abc"; value.n=3; value.enc=SQLITE_UTF8;
    duplicate=sqlite3_value_dup(&value); output[0]=duplicate!=0; output[1]=duplicate->flags; output[2]=duplicate->db==0; output[3]=duplicate->z!=value.z; output[4]=duplicate->z[1];
    sqlite3_value_free(duplicate); output[5]=sqlite3_memory_used()==before;
  }else if( scenario==104 ){
    sqlite3_value *duplicate; char marker;
    value.flags=MEM_Null|MEM_Term|MEM_Subtype|MEM_Static; value.eSubtype='p'; value.u.zPType="kind"; value.z=&marker;
    duplicate=sqlite3_value_dup(&value); output[0]=duplicate!=0; output[1]=duplicate->flags; output[2]=sqlite3_value_pointer(duplicate,"kind")==0; sqlite3_value_free(duplicate);
  }else if( scenario==105 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); value.db=&db; context.pOut=&value;
    sqlite3_result_int(&context,-7); output[0]=value.flags; output[1]=(uint64_t)value.u.i;
    sqlite3_result_int64(&context,0x1234567887654321LL); output[2]=value.flags; output[3]=(uint64_t)value.u.i;
    sqlite3_result_double(&context,4.5); output[4]=value.flags; memcpy(&output[5],&value.u.r,8);
    sqlite3_result_null(&context); output[6]=value.flags;
  }else if( scenario==106 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); value.flags=MEM_Int; value.u.i=3; context.pOut=&value;
    sqlite3_result_subtype(&context,0x123); output[0]=value.flags; output[1]=value.eSubtype;
  }else if( scenario==107 ){
    sqlite3_context context; uint8_t source[2]={'a','b'};
    memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); memset(&other,0,sizeof(other)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000;
    value.db=&db; other.db=&db; value.flags=MEM_Null; other.flags=MEM_Str|MEM_Ephem; other.z=(char*)source; other.n=2; other.enc=SQLITE_UTF8; context.pOut=&value; context.enc=SQLITE_UTF16LE;
    sqlite3_result_value(&context,&other); output[0]=context.isError; output[1]=value.flags; output[2]=value.enc; output[3]=value.n; output[4]=(unsigned char)value.z[0]; output[5]=(unsigned char)value.z[1]; output[6]=value.z!=(char*)source; sqlite3VdbeMemRelease(&value);
  }else if( scenario==108 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=10; value.db=&db; value.flags=MEM_Null; context.pOut=&value;
    output[0]=sqlite3_result_zeroblob64(&context,7); output[1]=value.flags; output[2]=value.n; output[3]=value.u.nZero;
    output[4]=sqlite3_result_zeroblob64(&context,11); output[5]=context.isError;
  }else if( scenario==109 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null; context.pOut=&value; context.enc=SQLITE_UTF16LE;
    sqlite3_result_text(&context,"ab",2,SQLITE_TRANSIENT); output[0]=context.isError; output[1]=value.flags; output[2]=value.enc; output[3]=value.n; output[4]=(unsigned char)value.z[0]; output[5]=(unsigned char)value.z[1]; sqlite3VdbeMemRelease(&value);
  }else if( scenario==110 ){
    sqlite3_context context; uint8_t source[3]={1,2,3}; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null; context.pOut=&value; context.enc=SQLITE_UTF8;
    sqlite3_result_blob(&context,source,3,SQLITE_TRANSIENT); output[0]=context.isError; output[1]=value.flags; output[2]=value.n; output[3]=(unsigned char)value.z[0]; output[4]=(unsigned char)value.z[2]; sqlite3VdbeMemRelease(&value);
  }else if( scenario==111 ){
    sqlite3_context context; uint8_t source[5]={'a',0,'b',0,9}; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null; context.pOut=&value; context.enc=SQLITE_UTF8;
    sqlite3_result_text64(&context,(char*)source,5,SQLITE_TRANSIENT,SQLITE_UTF16); output[0]=context.isError; output[1]=value.flags; output[2]=value.enc; output[3]=value.n; output[4]=(unsigned char)value.z[0]; output[5]=(unsigned char)value.z[1]; sqlite3VdbeMemRelease(&value);
  }else if( scenario==112 ){
    sqlite3_context context; uint8_t source16[4]={'e',0,'r',0}; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null; context.pOut=&value;
    sqlite3_result_error(&context,"bad",3); output[0]=context.isError; output[1]=value.flags; output[2]=value.n; sqlite3_result_error16(&context,source16,4); output[3]=context.isError; output[4]=value.enc; output[5]=value.n; sqlite3VdbeMemRelease(&value);
  }else if( scenario==113 ){
    sqlite3_context context; char marker; memset(&context,0,sizeof(context)); memset(&value,0,sizeof(value)); allocator_db(&db); value.db=&db; value.flags=MEM_Int; value.u.i=2; context.pOut=&value;
    sqlite3_result_pointer(&context,&marker,"kind",lifecycle_destructor); output[0]=value.flags; output[1]=value.eSubtype; output[2]=sqlite3_value_pointer(&value,"kind")==&marker; sqlite3VdbeMemRelease(&value); output[3]=lifecycle_destructor_count;
  }else if( scenario==114 ){
    sqlite3_context context; FuncDef function; char user; memset(&context,0,sizeof(context)); memset(&function,0,sizeof(function)); allocator_db(&db); value.db=&db; value.flags=MEM_Null|MEM_Zero; function.pUserData=&user; context.pOut=&value; context.pFunc=&function;
    output[0]=sqlite3_user_data(&context)==&user; output[1]=sqlite3_context_db_handle(&context)==&db; output[2]=sqlite3_vtab_nochange(&context);
  }else if( scenario==115 || scenario==116 ){
    sqlite3_context context; FuncDef function; void *first,*second; memset(&context,0,sizeof(context)); memset(&function,0,sizeof(function)); memset(&value,0,sizeof(value)); allocator_db(&db); value.db=&db; value.flags=MEM_Null; function.xFinalize=lifecycle_finalize; context.pOut=&other; context.pMem=&value; context.pFunc=&function;
    first=sqlite3_aggregate_context(&context,scenario==115?12:0); second=sqlite3_aggregate_context(&context,20); output[0]=first!=0; output[1]=first==second; output[2]=value.flags; if(first){output[3]=((unsigned char*)first)[0];output[4]=((unsigned char*)first)[11];} sqlite3VdbeMemRelease(&value);
  }else if( scenario==117 ){
    sqlite3_context context; Vdbe machine; char first,second; AuxData *aux;
    memset(&context,0,sizeof(context)); memset(&machine,0,sizeof(machine)); allocator_db(&db); machine.db=&db; context.pOut=&value; context.pVdbe=&machine; context.iOp=5;
    sqlite3_set_auxdata(&context,2,&first,lifecycle_destructor); output[0]=context.isError; output[1]=sqlite3_get_auxdata(&context,2)==&first;
    sqlite3_set_auxdata(&context,2,&second,lifecycle_destructor); output[2]=lifecycle_destructor_count; output[3]=sqlite3_get_auxdata(&context,2)==&second; context.iOp=6; output[4]=sqlite3_get_auxdata(&context,2)==0;
    aux=machine.pAuxData; if(aux->xDeleteAux)aux->xDeleteAux(aux->pAux); sqlite3DbFreeNN(&db,aux); output[5]=lifecycle_destructor_count;
  }else if( scenario==118 || scenario==119 ){
    char text[]="48.00"; sqlite3_int64 integer=0; double real=48.0; allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Static|MEM_Term; value.z=text; value.n=5; value.enc=SQLITE_UTF8;
    if(scenario==118){output[0]=alsoAnInt(&value,real,&integer);output[1]=(uint64_t)integer;}
    else{applyNumericAffinity(&value,1);output[0]=value.flags;output[1]=(uint64_t)value.u.i;}
  }else if( scenario==120 ){
    value.flags=MEM_Real; value.u.r=4.0; applyAffinity(&value,SQLITE_AFF_INTEGER,SQLITE_UTF8); output[0]=value.flags; output[1]=(uint64_t)value.u.i;
  }else if( scenario==121 || scenario==122 ){
    char integer[]="42"; char real[]="4.5"; char *text=scenario==121?integer:real; allocator_db(&db); value.db=&db; value.flags=MEM_Str|MEM_Static|MEM_Term; value.z=text; value.n=(int)strlen(text); value.enc=SQLITE_UTF8;
    output[0]=computeNumericType(&value); output[1]=value.flags; memcpy(&output[2],&value.u,8);
  }else if( scenario==123 ){
    value.flags=MEM_IntReal; value.u.i=9; output[0]=numericType(&value); output[1]=value.flags; output[2]=(uint64_t)value.u.i;
  }else if( scenario==124 ){
    Vdbe machine; VdbeOp op; Mem registers[2]; memset(&machine,0,sizeof(machine)); memset(&op,0,sizeof(op)); memset(registers,0,sizeof(registers)); machine.aMem=registers; machine.nMem=1; op.p2=1;
    registers[1].flags=MEM_Str|MEM_Dyn; registers[1].z=(char*)bytes; registers[1].xDel=lifecycle_destructor; output[0]=out2Prerelease(&machine,&op)==&registers[1]; output[1]=registers[1].flags; output[2]=lifecycle_destructor_count;
    registers[1].flags=MEM_Null; output[3]=out2Prerelease(&machine,&op)==&registers[1]; output[4]=registers[1].flags;
  }else if( scenario==125 ){
    VdbeOp op; Mem registers[5]; memset(&op,0,sizeof(op)); memset(registers,0,sizeof(registers)); op.p3=0; op.p4type=P4_INT32; op.p4.i=5;
    registers[0].flags=MEM_Int; registers[0].u.i=-2; registers[1].flags=MEM_Real; registers[1].u.r=3.9; registers[2].flags=MEM_Str; registers[3].flags=MEM_Blob; registers[4].flags=MEM_Null;
    output[0]=filterHash(registers,&op);
  }else if( scenario==126 ){
    const char *name; unsigned i; uint16_t flags[5]={MEM_Int,MEM_Real,MEM_Str,MEM_Blob,MEM_Null};
    for(i=0;i<5;i++){value.flags=flags[i];name=vdbeMemTypeName(&value);output[i]=(unsigned char)name[0]+(unsigned char)name[1]+(unsigned char)name[2];}
  }else if( scenario==127 || scenario==128 ){
    sqlite3_context context; int code=scenario==127?SQLITE_CONSTRAINT:SQLITE_OK; memset(&context,0,sizeof(context)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null; context.pOut=&value; context.enc=SQLITE_UTF8;
    sqlite3_result_error_code(&context,code); output[0]=(uint64_t)context.isError; output[1]=value.flags; output[2]=value.n; output[3]=(unsigned char)value.z[0]+(unsigned char)value.z[value.n-1];
  }else if( scenario==129 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; value.db=&db; value.flags=MEM_Null; context.pOut=&value;
    sqlite3_result_error_toobig(&context); output[0]=context.isError; output[1]=value.flags; output[2]=value.n; output[3]=(unsigned char)value.z[0]+(unsigned char)value.z[value.n-1];
  }else if( scenario==130 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); value.flags=MEM_Int; value.u.i=42; context.pOut=&value; sqlite3ResultIntReal(&context); output[0]=value.flags; output[1]=(uint64_t)value.u.i;
  }else if( scenario==131 ){
    sqlite3_context context; memset(&context,0,sizeof(context)); allocator_db(&db); value.db=&db; value.flags=MEM_Int; value.u.i=42; context.pOut=&value; sqlite3_result_error_nomem(&context); output[0]=context.isError; output[1]=value.flags; output[2]=db.mallocFailed; output[3]=db.lookaside.bDisable;
  }else if( scenario==132 ){
    sqlite3_context context; FuncDef function; const char *name; memset(&context,0,sizeof(context)); memset(&function,0,sizeof(function)); function.zName="percentile"; context.pFunc=&function; name=sqlite3VdbeFuncName(&context); output[0]=(unsigned char)name[0]+(unsigned char)name[1]+(unsigned char)name[2];
  }else if( scenario==133 ){
    allocator_db(&db); db.nTotalChange=10; sqlite3VdbeSetChanges(&db,4); output[0]=db.nChange; output[1]=db.nTotalChange;
  }else if( scenario==134 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); sqlite3VdbeCountChanges(&machine); output[0]=machine.changeCntOn;
  }else if( scenario==135 ){
    Vdbe first,second; memset(&first,0,sizeof(first)); memset(&second,0,sizeof(second)); allocator_db(&db); db.pVdbe=&first; first.pVNext=&second; sqlite3ExpirePreparedStatements(&db,1); output[0]=first.expired; output[1]=second.expired;
  }else if( scenario==136 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); allocator_db(&db); machine.db=&db; output[0]=sqlite3VdbeDb(&machine)==&db;
  }else if( scenario==137 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); machine.prepFlags=0xa5; output[0]=sqlite3VdbePrepareFlags(&machine);
  }else if( scenario==138 ){
    Vdbe machine; VdbeOp operations[3]; memset(&machine,0,sizeof(machine)); memset(operations,0,sizeof(operations)); allocator_db(&db); machine.db=&db; machine.aOp=operations; machine.nOp=3;
    output[0]=sqlite3VdbeCurrentAddr(&machine); output[1]=sqlite3VdbeGetOp(&machine,1)==&operations[1]; output[2]=sqlite3VdbeGetLastOp(&machine)==&operations[2];
    sqlite3VdbeChangeOpcode(&machine,1,OP_Integer); sqlite3VdbeChangeP1(&machine,1,11); sqlite3VdbeChangeP2(&machine,1,22); sqlite3VdbeChangeP3(&machine,1,33); sqlite3VdbeChangeP5(&machine,44);
    output[3]=operations[1].opcode; output[4]=operations[1].p1; output[5]=operations[1].p2; output[6]=operations[1].p3; output[7]=operations[2].p5;
  }else if( scenario==139 ){
    Vdbe machine; VdbeOp operations[3]; memset(&machine,0,sizeof(machine)); memset(operations,0,sizeof(operations)); allocator_db(&db); machine.db=&db; machine.aOp=operations; machine.nOp=3; operations[2].opcode=OP_Once;
    sqlite3VdbeJumpHere(&machine,0); output[0]=operations[0].p2; sqlite3VdbeJumpHereOrPopInst(&machine,2); output[1]=machine.nOp; sqlite3VdbeJumpHereOrPopInst(&machine,0); output[2]=operations[0].p2;
  }else if( scenario==140 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); allocator_db(&db); db.mallocFailed=1; machine.db=&db; output[0]=sqlite3VdbeGetOp(&machine,99)->opcode;
  }else if( scenario==141 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); machine.pParse=(Parse*)(uintptr_t)8; output[0]=sqlite3VdbeParser(&machine)==(Parse*)(uintptr_t)8;
  }else if( scenario==142 ){
    Vdbe first,second,next1,next2; Vdbe *previous1=&first,*previous2=&second; char sql1[]="first",sql2[]="second";
    memset(&first,0,sizeof(first)); memset(&second,0,sizeof(second)); memset(&next1,0,sizeof(next1)); memset(&next2,0,sizeof(next2)); allocator_db(&db);
    first.db=second.db=&db; first.pVNext=&next1; second.pVNext=&next2; first.ppVPrev=&previous1; second.ppVPrev=&previous2; first.zSql=sql1; second.zSql=sql2;
    first.pc=11; second.pc=22; first.expmask=101; second.expmask=202; first.prepFlags=3; second.prepFlags=4; first.aCounter[5]=6; second.aCounter[5]=7;
    sqlite3VdbeSwap(&first,&second); output[0]=first.pc; output[1]=second.pc; output[2]=first.pVNext==&next1; output[3]=second.pVNext==&next2;
    output[4]=first.ppVPrev==&previous1; output[5]=second.ppVPrev==&previous2; output[6]=first.zSql==sql1; output[7]=second.zSql==sql2;
    output[8]=first.expmask; output[9]=second.expmask; output[10]=first.prepFlags; output[11]=second.prepFlags; output[12]=first.aCounter[5]; output[13]=second.aCounter[5];
  }else if( scenario==143 ){
    Vdbe machine; VdbeOp operations[2]; memset(&machine,0,sizeof(machine)); memset(operations,0,sizeof(operations)); allocator_db(&db); machine.db=&db; machine.aOp=operations; machine.nOp=2;
    operations[1].opcode=OP_Column; operations[1].p3=7; operations[1].p5=1; sqlite3VdbeTypeofColumn(&machine,7); output[0]=operations[1].p5;
    operations[1].p5=2; sqlite3VdbeTypeofColumn(&machine,8); output[1]=operations[1].p5; operations[1].opcode=OP_Integer; sqlite3VdbeTypeofColumn(&machine,7); output[2]=operations[1].p5;
  }else if( scenario==144 ){
    Vdbe machine; SubProgram first,second; memset(&machine,0,sizeof(machine)); memset(&first,0,sizeof(first)); memset(&second,0,sizeof(second));
    output[0]=sqlite3VdbeHasSubProgram(&machine); sqlite3VdbeLinkSubProgram(&machine,&first); sqlite3VdbeLinkSubProgram(&machine,&second);
    output[1]=sqlite3VdbeHasSubProgram(&machine); output[2]=machine.pProgram==&second; output[3]=second.pNext==&first; output[4]=first.pNext==0;
  }else if( scenario==145 ){
    Vdbe machine; VdbeFrame first,second; memset(&machine,0,sizeof(machine)); memset(&first,0,sizeof(first)); memset(&second,0,sizeof(second));
    first.v=&machine; second.v=&machine; sqlite3VdbeFrameMemDel(&first); sqlite3VdbeFrameMemDel(&second); output[0]=machine.pDelFrame==&second; output[1]=second.pParent==&first; output[2]=first.pParent==0;
  }else if( scenario==146 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); machine.eVdbeState=VDBE_HALT_STATE; machine.nOp=1; machine.pc=9; machine.rc=SQLITE_ERROR; machine.errorAction=OE_Rollback;
    machine.nChange=33; machine.cacheCtr=55; machine.minWriteFileFormat=4; machine.iStatement=8; machine.nFkConstraint=13; sqlite3VdbeRewind(&machine);
    output[0]=machine.eVdbeState; output[1]=(uint64_t)machine.pc; output[2]=machine.rc; output[3]=machine.errorAction; output[4]=machine.nChange; output[5]=machine.cacheCtr;
    output[6]=machine.minWriteFileFormat; output[7]=machine.iStatement; output[8]=machine.nFkConstraint;
  }else if( scenario==147 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); machine.rc=SQLITE_BUSY; sqlite3VdbeResetStepResult(&machine); output[0]=machine.rc;
  }else if( scenario==148 || scenario==149 ){
    Vdbe machine; char sql[]="select 42"; memset(&machine,0,sizeof(machine)); allocator_db(&db); machine.db=&db; machine.expmask=0x12345678;
    sqlite3VdbeSetSql(&machine,sql,9,scenario==149?SQLITE_PREPARE_SAVESQL:3); output[0]=machine.prepFlags; output[1]=machine.expmask; output[2]=machine.zSql!=sql;
    output[3]=strcmp(machine.zSql,sql)==0; sqlite3DbFree(&db,machine.zSql);
  }else if( scenario==150 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); sqlite3VdbeSetVarmask(&machine,1); output[0]=machine.expmask; sqlite3VdbeSetVarmask(&machine,31); output[1]=machine.expmask;
    sqlite3VdbeSetVarmask(&machine,32); output[2]=machine.expmask; sqlite3VdbeSetVarmask(&machine,47); output[3]=machine.expmask;
  }else if( scenario==151 ){
    Vdbe machine; Mem variables[2]; sqlite3_value *result; char text[]="42"; memset(&machine,0,sizeof(machine)); memset(variables,0,sizeof(variables)); allocator_db(&db); machine.db=&db; machine.aVar=variables;
    variables[0].flags=MEM_Null; variables[1].db=&db; variables[1].flags=MEM_Str|MEM_Static|MEM_Term; variables[1].z=text; variables[1].n=2; variables[1].enc=SQLITE_UTF8;
    output[0]=sqlite3VdbeGetBoundValue(&machine,1,SQLITE_AFF_INTEGER)==0; result=sqlite3VdbeGetBoundValue(&machine,2,SQLITE_AFF_INTEGER); output[1]=result!=0;
    if(result){output[2]=result->flags; output[3]=(uint64_t)result->u.i; output[4]=result->db==&db; output[5]=result->z!=text; sqlite3ValueFree(result);}
  }else if( scenario==152 ){
    Vdbe machine; Mem variable; sqlite3_int64 used; memset(&machine,0,sizeof(machine)); memset(&variable,0,sizeof(variable)); allocator_db(&db); machine.db=&db; machine.aVar=&variable; variable.db=&db; variable.flags=MEM_Int; variable.u.i=7;
    used=sqlite3_memory_used(); sqlite3_hard_heap_limit64(used+1); output[0]=sqlite3VdbeGetBoundValue(&machine,1,SQLITE_AFF_INTEGER)==0; output[1]=db.mallocFailed;
    sqlite3_hard_heap_limit64(0); sqlite3OomClear(&db);
  }else if( scenario==153 ){
    Vdbe machine; char sql[]="select 42"; sqlite3_int64 used; memset(&machine,0,sizeof(machine)); allocator_db(&db); machine.db=&db; used=sqlite3_memory_used(); sqlite3_hard_heap_limit64(used+1);
    sqlite3VdbeSetSql(&machine,sql,9,SQLITE_PREPARE_SAVESQL); output[0]=machine.zSql==0; output[1]=db.mallocFailed; output[2]=machine.prepFlags;
    sqlite3_hard_heap_limit64(0); sqlite3OomClear(&db);
  }else if( scenario==154 ){
    Vdbe machine; int i; char name[]="answer"; memset(&machine,0,sizeof(machine)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; machine.db=&db; sqlite3VdbeSetNumCols(&machine,3);
    output[0]=machine.nResColumn; output[1]=machine.nResAlloc; output[2]=machine.aColName!=0;
    for(i=0;i<3*COLNAME_N;i++){output[3]+=machine.aColName[i].flags==MEM_Null; output[4]+=machine.aColName[i].db==&db;}
    output[5]=sqlite3VdbeSetColName(&machine,1,COLNAME_NAME,name,SQLITE_TRANSIENT); output[6]=machine.aColName[1].flags; output[7]=machine.aColName[1].n;
    output[8]=strcmp(machine.aColName[1].z,name)==0; output[9]=machine.aColName[1].z!=name; output[10]=machine.aColName[1].z[6]; sqlite3VdbeSetNumCols(&machine,1);
    output[11]=machine.nResColumn; output[12]=machine.nResAlloc; output[13]=machine.aColName!=0; releaseMemArray(machine.aColName,COLNAME_N); sqlite3DbFree(&db,machine.aColName);
  }else if( scenario==155 ){
    Vdbe machine; char name[]="static"; memset(&machine,0,sizeof(machine)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; machine.db=&db; sqlite3VdbeSetNumCols(&machine,1);
    output[0]=sqlite3VdbeSetColName(&machine,0,COLNAME_NAME,name,SQLITE_STATIC); output[1]=machine.aColName[0].z==name; output[2]=machine.aColName[0].flags; releaseMemArray(machine.aColName,COLNAME_N); sqlite3DbFree(&db,machine.aColName);
  }else if( scenario==156 ){
    Vdbe machine; sqlite3_int64 used; memset(&machine,0,sizeof(machine)); allocator_db(&db); machine.db=&db; used=sqlite3_memory_used(); sqlite3_hard_heap_limit64(used+1);
    sqlite3VdbeSetNumCols(&machine,3); output[0]=machine.nResColumn; output[1]=machine.nResAlloc; output[2]=machine.aColName==0; output[3]=db.mallocFailed;
    sqlite3_hard_heap_limit64(0); sqlite3OomClear(&db);
  }else if( scenario==157 ){
    Vdbe machine; memset(&machine,0,sizeof(machine)); allocator_db(&db); db.pErr=sqlite3ValueNew(&db); db.pErr->flags=MEM_Int; db.pErr->u.i=42; machine.db=&db; machine.rc=SQLITE_BUSY;
    output[0]=sqlite3VdbeTransferError(&machine); output[1]=db.errCode; output[2]=(uint64_t)db.errByteOffset; output[3]=db.pErr->flags; sqlite3ValueFree(db.pErr);
  }else if( scenario==158 ){
    Vdbe machine; char message[]="failure"; memset(&machine,0,sizeof(machine)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; machine.db=&db; machine.rc=SQLITE_ERROR; machine.zErrMsg=message;
    output[0]=sqlite3VdbeTransferError(&machine); output[1]=db.errCode; output[2]=(uint64_t)db.errByteOffset; output[3]=db.pErr!=0; output[4]=db.bBenignMalloc;
    if(db.pErr){output[5]=db.pErr->flags; output[6]=db.pErr->n; output[7]=strcmp(db.pErr->z,message)==0; output[8]=db.pErr->z!=message; sqlite3ValueFree(db.pErr);}
  }else if( scenario==159 ){
    Vdbe machine; char message[]="failure"; sqlite3_int64 used; memset(&machine,0,sizeof(machine)); allocator_db(&db); db.aLimit[SQLITE_LIMIT_LENGTH]=1000000; machine.db=&db; machine.rc=SQLITE_ERROR; machine.zErrMsg=message;
    used=sqlite3_memory_used(); sqlite3_hard_heap_limit64(used+1); output[0]=sqlite3VdbeTransferError(&machine); output[1]=db.pErr==0; output[2]=db.mallocFailed; output[3]=db.bBenignMalloc;
    sqlite3_hard_heap_limit64(0);
  }
}

static void allocator_db(sqlite3 *db) {
  memset(db, 0, sizeof(*db));
  db->lookaside.bDisable = 1;
  db->lookaside.sz = 0;
  db->lookaside.szTrue = 0;
}

void probe_db_allocator(unsigned scenario, uint64_t output[16]) {
  sqlite3 db;
  union { uint64_t align; uint8_t bytes[640]; } arena;
  void *p, *q;
  memset(output, 0, 16*sizeof(output[0]));
  memset(&arena, 0, sizeof(arena));
  allocator_db(&db);
  sqlite3_initialize();
  if( scenario==0 ){
    LookasideSlot *big = (LookasideSlot*)&arena.bytes[0];
    LookasideSlot *small = (LookasideSlot*)&arena.bytes[512];
    db.lookaside.bDisable = 0;
    db.lookaside.sz = db.lookaside.szTrue = 512;
    db.lookaside.pStart = arena.bytes;
    db.lookaside.pMiddle = &arena.bytes[512];
    db.lookaside.pEnd = db.lookaside.pTrueEnd = &arena.bytes[640];
    db.lookaside.pInit = big;
    db.lookaside.pSmallInit = small;
    p = sqlite3DbMallocRawNN(&db,32);
    q = sqlite3DbMallocRawNN(&db,400);
    output[0] = (uintptr_t)p-(uintptr_t)arena.bytes;
    output[1] = (uintptr_t)q-(uintptr_t)arena.bytes;
    output[2] = sqlite3DbMallocSize(&db,p);
    output[3] = sqlite3DbMallocSize(&db,q);
    output[4] = db.lookaside.anStat[0];
    output[5] = db.lookaside.anStat[1];
    output[6] = db.lookaside.anStat[2];
    sqlite3DbFreeNN(&db,p);
    sqlite3DbFreeNN(&db,q);
    output[7] = db.lookaside.pSmallFree==small;
    output[8] = db.lookaside.pFree==big;
  }else if( scenario==1 ){
    p = sqlite3DbMallocRawNN(&db,17);
    output[0] = p!=0;
    output[1] = p ? sqlite3DbMallocSize(&db,p) : 0;
    if( p ) ((uint8_t*)p)[0] = 0x5a;
    q = sqlite3DbRealloc(&db,p,100);
    output[2] = q!=0;
    output[3] = q ? ((uint8_t*)q)[0] : 0;
    output[4] = q ? sqlite3DbMallocSize(&db,q) : 0;
    output[5] = db.mallocFailed;
    sqlite3DbFree(&db,q);
  }else if( scenario==2 ){
    int measured = 0;
    p = sqlite3DbMallocRawNN(&db,33);
    output[0] = p ? sqlite3DbMallocSize(&db,p) : 0;
    db.pnBytesFreed = &measured;
    sqlite3DbFreeNN(&db,p);
    output[1] = measured;
    db.pnBytesFreed = 0;
    sqlite3DbFreeNN(&db,p);
  }else if( scenario==3 ){
    char *a = sqlite3DbStrDup(&db,"sqlite");
    char *b = sqlite3DbStrNDup(&db,"abcdef",3);
    output[0] = a!=0;
    output[1] = b!=0;
    output[2] = a ? strlen(a) : 0;
    output[3] = b ? strlen(b) : 0;
    output[4] = a ? (unsigned char)a[0]+(unsigned char)a[5] : 0;
    output[5] = b ? (unsigned char)b[0]+(unsigned char)b[2] : 0;
    sqlite3DbFree(&db,a);
    sqlite3DbFree(&db,b);
  }else if( scenario==4 ){
    sqlite3_int64 used = sqlite3_memory_used();
    sqlite3_hard_heap_limit64(used+1);
    db.lookaside.szTrue = 1200;
    p = sqlite3DbMallocRawNN(&db,4096);
    output[0] = p==0;
    output[1] = db.mallocFailed;
    output[2] = db.lookaside.bDisable;
    output[3] = db.lookaside.sz;
    db.nVdbeExec = 1;
    sqlite3OomClear(&db);
    output[4] = db.mallocFailed;
    db.nVdbeExec = 0;
    sqlite3OomClear(&db);
    output[5] = db.mallocFailed;
    output[6] = db.lookaside.bDisable;
    output[7] = db.lookaside.sz;
    sqlite3_hard_heap_limit64(0);
  }
}

#include "../../tests/differential/vdbe_mem_worker_main.c"
