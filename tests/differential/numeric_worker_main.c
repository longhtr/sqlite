#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int probe_atoi64(const uint8_t*, int, int64_t*, int);
int probe_dec_or_hex(const char*, int64_t*);
int probe_get_int32(const char*, int32_t*);
int32_t probe_atoi(const char*);
int probe_get_uint32(const char*, uint32_t*);
int probe_atof(const char*, double*);
int probe_format_i64(int64_t, char*);

static int nibble(char c){ return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1; }
static int hex(const char *z, uint8_t *out){ int n=(int)strlen(z),i; if(n&1||n>2048)return -1; for(i=0;i<n/2;i++){int a=nibble(z[2*i]),b=nibble(z[2*i+1]);if(a<0||b<0)return -1;out[i]=(uint8_t)(a*16+b);} return n/2; }
int main(int argc,char **argv){int i; for(i=1;i<argc;i++){
  if(argv[i][0]=='i'&&argv[i][1]==':'){char *e=argv[i]+2,*p=strchr(e,':');uint8_t b[1025];int n,enc,rc;int64_t v=0; if(!p)return 2;*p=0;enc=atoi(e);n=hex(p+1,b);if(n<0)return 3;rc=probe_atoi64(b,n,&v,enc);printf("I\t%d\t%d\t%" PRId64 "\n",enc,rc,v);}
  else if(argv[i][0]=='s'&&argv[i][1]==':'){uint8_t b[1025];int n=hex(argv[i]+2,b),rc64,rc32,rcu;int64_t v64=0;int32_t v32=0;uint32_t vu=0;if(n<0)return 4;b[n]=0;rc64=probe_dec_or_hex((char*)b,&v64);rc32=probe_get_int32((char*)b,&v32);rcu=probe_get_uint32((char*)b,&vu);{char formatted[22];int nf=probe_format_i64(v64,formatted);printf("S\t%d\t%" PRId64 "\t%d\t%" PRId32 "\t%" PRId32 "\t%d\t%" PRIu32 "\t%d\t%s\n",rc64,v64,rc32,v32,probe_atoi((char*)b),rcu,vu,nf,formatted);}}
  else if(argv[i][0]=='f'&&argv[i][1]==':'){uint8_t b[1025];int n=hex(argv[i]+2,b),rc;double value=0.0;uint64_t bits;if(n<0)return 5;b[n]=0;rc=probe_atof((char*)b,&value);memcpy(&bits,&value,8);printf("F\t%d\t%016" PRIx64 "\n",rc,bits);}
  else return 6;
}return 0;}
