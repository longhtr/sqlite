#define SQLITE_CORE 1
#include "sqlite3.c"
#include <float.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static double from_bits(unsigned long long bits){ double value; memcpy(&value,&bits,8); return value; }
static unsigned long long bits_of(double value){ unsigned long long bits; memcpy(&bits,&value,8); return bits; }
static void show_decode(int id, double value, int round, int maximum){
  FpDecode decoded;
  int i;
  sqlite3FpDecode(&decoded,value,round,maximum);
  printf("D%02d\t%016llx\t%d\t%d\t%d\t%c\t%d\t",id,bits_of(value),round,maximum,decoded.n,decoded.sign,decoded.isSpecial);
  for(i=0;i<decoded.n;i++) putchar(decoded.z[i]);
  printf("\t%d\n",decoded.iDP);
}
int main(void){
  static const int powers[] = {-348,-324,-27,-1,0,26,27,347};
  static const struct { unsigned long long a,b; } products[] = {
    {1,1},{0xffffffffffffffffULL,0xffffffffffffffffULL},{0x8123456789abcdefULL,0xfedcba9876543210ULL}
  };
  static const struct { unsigned long long a; unsigned int lo; unsigned long long b; } wide[] = {
    {1,1,1},{0xffffffffffffffffULL,0xffffffffU,0xffffffffffffffffULL},{0x8123456789abcdefULL,0x76543210U,0xfedcba9876543210ULL}
  };
  int i;
  printf("LAYOUT\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\n",sizeof(FpDecode),_Alignof(FpDecode),offsetof(FpDecode,n),offsetof(FpDecode,iDP),offsetof(FpDecode,z),offsetof(FpDecode,zBuf),offsetof(FpDecode,sign),offsetof(FpDecode,isSpecial));
  for(i=0;i<3;i++){ u64 lo,hi=sqlite3Multiply128(products[i].a,products[i].b,&lo); printf("M128-%d\t%016llx\t%016llx\n",i,(unsigned long long)hi,(unsigned long long)lo); }
  for(i=0;i<3;i++){ u32 lo; u64 hi=sqlite3Multiply160(wide[i].a,wide[i].lo,wide[i].b,&lo); printf("M160-%d\t%016llx\t%08x\n",i,(unsigned long long)hi,lo); }
  for(i=0;i<8;i++){ u32 lo; u64 hi=powerOfTen(powers[i],&lo); printf("P10-%d\t%d\t%016llx\t%08x\n",i,powers[i],(unsigned long long)hi,lo); }
  printf("RATIO\t%d\t%d\t%d\t%d\n",pwr10to2(-348),pwr10to2(347),pwr2to10(-1074),pwr2to10(1023));
  { static const struct { u64 m; int e,n; } x[]={{0x8000000000000000ULL,-1086,18},{0xa000000000000000ULL,-66,16},{0xffffffffffffffffULL,-100,7},{0x8000000000000000ULL,960,18}};
    for(i=0;i<4;i++){u64 d;int p;sqlite3Fp2Convert10(x[i].m,x[i].e,x[i].n,&d,&p);printf("B2D-%d\t%llu\t%d\n",i,(unsigned long long)d,p);}}
  { static const struct { u64 d; int p; } x[]={{1,-348},{1,-324},{1,-1},{4947,-2},{3141592653589793ULL,-15},{1,347}};
    for(i=0;i<6;i++) printf("D2B-%d\t%016llx\n",i,bits_of(sqlite3Fp10Convert2(x[i].d,x[i].p))); }
  show_decode(0,0.0,6,16); show_decode(1,from_bits(0x8000000000000000ULL),6,16);
  show_decode(2,1.0,6,16); show_decode(3,-1.0,6,16); show_decode(4,1.25,-6,16);
  show_decode(5,49.47,17,20); show_decode(6,0.1,16,16); show_decode(7,DBL_MIN,16,16);
  show_decode(8,from_bits(1),16,16); show_decode(9,DBL_MAX,16,16);
  show_decode(10,from_bits(0x7ff0000000000000ULL),6,16); show_decode(11,from_bits(0xfff0000000000000ULL),6,16);
  show_decode(12,from_bits(0x7ff8000000000001ULL),6,16); show_decode(13,3.141592653589793,-6,16);
  show_decode(14,9.999,3,16); show_decode(15,999.5,3,16);
  { unsigned long long state=0x9e3779b97f4a7c15ULL; static const int rounds[]={-20,-6,0,1,6,16,17,30};
    for(i=0;i<256;i++){ state^=state<<13; state^=state>>7; state^=state<<17; show_decode(100+i,from_bits(state),rounds[i&7],(i&1)?20:16); }}
  return 0;
}
