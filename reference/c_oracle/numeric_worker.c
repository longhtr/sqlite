#include "sqlite3.c"
int probe_atoi64(const uint8_t*p,int n,int64_t*out,int enc){return sqlite3Atoi64((const char*)p,out,n,(u8)enc);}
int probe_dec_or_hex(const char*p,int64_t*out){return sqlite3DecOrHexToI64(p,out);}
int probe_get_int32(const char*p,int32_t*out){return sqlite3GetInt32(p,out);}
int32_t probe_atoi(const char*p){return sqlite3Atoi(p);}
int probe_get_uint32(const char*p,uint32_t*out){return sqlite3GetUInt32(p,out);}
int probe_atof(const char*p,double*out){return sqlite3AtoF(p,out);}
int probe_format_i64(int64_t value,char*out){return sqlite3Int64ToText(value,out);}
#include "../../tests/differential/numeric_worker_main.c"
