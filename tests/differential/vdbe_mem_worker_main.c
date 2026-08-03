#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int64_t probe_real_to_i64(uint64_t);
int probe_real_same_as_int(uint64_t, int64_t);
int probe_int_float_compare(int64_t, uint64_t);
uint32_t probe_serial_type_len(uint32_t);
uint8_t probe_one_byte_serial_type_len(uint8_t);
void probe_serial_get(const uint8_t*, uint32_t, uint16_t*, uint64_t*, int*, int*);
int64_t probe_int_value(uint16_t, uint64_t, uint8_t, uint8_t*, size_t);
int probe_integerify(uint16_t, uint64_t, uint8_t, uint8_t*, size_t, uint16_t*, uint64_t*);
void probe_integer_affinity(uint16_t, uint64_t, uint16_t*, uint64_t*);
uintptr_t probe_noop_destructor(uintptr_t);
void probe_mem_init(uint16_t, uintptr_t, uint8_t*);
void probe_db_allocator(unsigned, uint64_t[16]);
void probe_mem_lifecycle(unsigned, uint64_t[16]);

static int parse_u64(const char *text, uint64_t *value) {
  char *end = 0;
  *value = strtoull(text, &end, 16);
  return end != text && *end == 0;
}

static int parse_i64(const char *text, int64_t *value) {
  char *end = 0;
  *value = strtoll(text, &end, 10);
  return end != text && *end == 0;
}

static int nibble(char value) {
  if(value>='0' && value<='9') return value-'0';
  if(value>='a' && value<='f') return value-'a'+10;
  if(value>='A' && value<='F') return value-'A'+10;
  return -1;
}

static int parse_bytes(const char *text, uint8_t *output, size_t capacity) {
  size_t length = strlen(text), index;
  if((length&1) || length/2>capacity) return -1;
  for(index=0; index<length/2; index++) {
    int high=nibble(text[2*index]), low=nibble(text[2*index+1]);
    if(high<0 || low<0) return -1;
    output[index]=(uint8_t)((high<<4)|low);
  }
  return (int)(length/2);
}

int main(int argc, char **argv) {
  int index;
  for(index=1; index<argc; index++) {
    char *operation = argv[index];
    if(operation[0]=='t' && operation[1]==':') {
      uint64_t bits;
      if(!parse_u64(operation+2, &bits)) return 2;
      printf("T\t%" PRId64 "\n", probe_real_to_i64(bits));
    } else if(operation[0]=='s' && operation[1]==':') {
      char *integer_text = strchr(operation+2, ':');
      uint64_t bits;
      int64_t integer;
      if(!integer_text) return 3;
      *integer_text++ = 0;
      if(!parse_u64(operation+2, &bits) || !parse_i64(integer_text, &integer)) return 4;
      printf("S\t%d\n", probe_real_same_as_int(bits, integer));
    } else if(operation[0]=='c' && operation[1]==':') {
      char *bits_text = strchr(operation+2, ':');
      uint64_t bits;
      int64_t integer;
      if(!bits_text) return 5;
      *bits_text++ = 0;
      if(!parse_i64(operation+2, &integer) || !parse_u64(bits_text, &bits)) return 6;
      printf("C\t%d\n", probe_int_float_compare(integer, bits));
    } else if(operation[0]=='l' && operation[1]==':') {
      uint64_t serial_type;
      if(!parse_u64(operation+2,&serial_type) || serial_type>0xffffffffU) return 15;
      printf("L\t%" PRIu32,probe_serial_type_len((uint32_t)serial_type));
      if(serial_type<128) printf("\t%u",(unsigned)probe_one_byte_serial_type_len((uint8_t)serial_type));
      printf("\n");
    } else if(operation[0]=='g' && operation[1]==':') {
      char *data_text=strchr(operation+2,':');
      uint64_t serial_type, output_union;
      uint8_t data[512];
      uint16_t output_flags;
      int length, output_length, output_alias;
      if(!data_text) return 16;
      *data_text++=0;
      if(!parse_u64(operation+2,&serial_type) || serial_type>0xffffffffU) return 17;
      length=parse_bytes(data_text,data,sizeof(data));
      if(length<8) return 18;
      probe_serial_get(data,(uint32_t)serial_type,&output_flags,&output_union,&output_length,&output_alias);
      printf("G\t%u\t%016" PRIx64 "\t%d\t%d\n",(unsigned)output_flags,output_union,output_length,output_alias);
    } else if(operation[0]=='v' && operation[1]==':') {
      char *parts[5], *cursor=operation+2, *separator;
      uint64_t flags, union_bits, encoding, has_data;
      uint8_t data[512], *pointer;
      uint16_t output_flags;
      uint64_t output_union;
      int length, result;
      int64_t value;
      int part;
      for(part=0; part<4; part++) {
        parts[part]=cursor;
        separator=strchr(cursor, ':');
        if(!separator) return 7;
        *separator=0;
        cursor=separator+1;
      }
      parts[4]=cursor;
      if(!parse_u64(parts[0],&flags) || flags>0xffff ||
         !parse_u64(parts[1],&union_bits) || !parse_u64(parts[2],&encoding) || encoding>255 ||
         !parse_u64(parts[3],&has_data) || has_data>1) return 8;
      length=parse_bytes(parts[4],data,sizeof(data));
      if(length<0) return 9;
      pointer=has_data?data:0;
      value=probe_int_value((uint16_t)flags,union_bits,(uint8_t)encoding,pointer,(size_t)length);
      result=probe_integerify((uint16_t)flags,union_bits,(uint8_t)encoding,pointer,(size_t)length,&output_flags,&output_union);
      printf("V\t%" PRId64 "\t%d\t%u\t%016" PRIx64 "\n",value,result,(unsigned)output_flags,output_union);
    } else if(operation[0]=='a' && operation[1]==':') {
      char *bits_text=strchr(operation+2,':');
      uint64_t flags, union_bits, output_union;
      uint16_t output_flags;
      if(!bits_text) return 13;
      *bits_text++=0;
      if(!parse_u64(operation+2,&flags) || flags>0xffff || !parse_u64(bits_text,&union_bits)) return 14;
      probe_integer_affinity((uint16_t)flags,union_bits,&output_flags,&output_union);
      printf("A\t%u\t%016" PRIx64 "\n",(unsigned)output_flags,output_union);
    } else if(operation[0]=='n' && operation[1]==':') {
      uint64_t address;
      if(!parse_u64(operation+2, &address)) return 7;
      printf("N\t%" PRIxPTR "\n", probe_noop_destructor((uintptr_t)address));
    } else if(operation[0]=='r' && operation[1]==':') {
      uint64_t scenario, output[16];
      size_t output_index;
      if(!parse_u64(operation+2,&scenario) || scenario>0xffffffffU) return 20;
      probe_mem_lifecycle((unsigned)scenario,output);
      printf("R");
      for(output_index=0; output_index<16; output_index++) printf("\t%016" PRIx64,output[output_index]);
      printf("\n");
    } else if(operation[0]=='d' && operation[1]==':') {
      uint64_t scenario, output[16];
      size_t output_index;
      if(!parse_u64(operation+2,&scenario) || scenario>0xffffffffU) return 19;
      probe_db_allocator((unsigned)scenario,output);
      printf("D");
      for(output_index=0; output_index<16; output_index++) printf("\t%016" PRIx64,output[output_index]);
      printf("\n");
    } else if(operation[0]=='m' && operation[1]==':') {
      char *db_text = strchr(operation+2, ':');
      uint64_t flags, db;
      uint8_t bytes[56];
      size_t byte_index;
      if(!db_text) return 10;
      *db_text++ = 0;
      if(!parse_u64(operation+2, &flags) || flags>0xffff || !parse_u64(db_text, &db)) return 11;
      probe_mem_init((uint16_t)flags, (uintptr_t)db, bytes);
      printf("M\t");
      for(byte_index=0; byte_index<sizeof(bytes); byte_index++) printf("%02x", bytes[byte_index]);
      printf("\n");
    } else {
      return 12;
    }
  }
  return 0;
}
