#include <stdint.h>
#include <stdio.h>

typedef void (*TopologyVisitor)(int, const char *, int, uint32_t, uintptr_t);
void native_builtin_registry_dump(TopologyVisitor);

static void emit(int bucket, const char *name, int narg, uint32_t flags, uintptr_t user_data){
  if( user_data>255 ) user_data = 0;
  printf("%d\t%s\t%d\t%08x\t%llu\n", bucket, name, narg, flags,
         (unsigned long long)user_data);
}

int main(void){
  native_builtin_registry_dump(emit);
  return 0;
}
