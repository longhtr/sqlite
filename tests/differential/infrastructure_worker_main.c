#include <stdio.h>
#include <string.h>

int probe_memory_trace(char*,int);
int probe_allocator_trace(char*,int);
int probe_lookaside_trace(char*,int);
int probe_mutex_trace(char*,int);
int probe_global_trace(char*,int);
int probe_methods_trace(char*,int);
int probe_memdb_trace(char*,int);

int main(int argc,char **argv){
  char out[2048];
  for(int i=1;i<argc;i++){
    int n=-1;
    if(strcmp(argv[i],"memory")==0)n=probe_memory_trace(out,sizeof(out));
    else if(strcmp(argv[i],"allocator")==0)n=probe_allocator_trace(out,sizeof(out));
    else if(strcmp(argv[i],"lookaside")==0)n=probe_lookaside_trace(out,sizeof(out));
    else if(strcmp(argv[i],"mutex")==0)n=probe_mutex_trace(out,sizeof(out));
    else if(strcmp(argv[i],"global")==0)n=probe_global_trace(out,sizeof(out));
    else if(strcmp(argv[i],"methods")==0)n=probe_methods_trace(out,sizeof(out));
    else if(strcmp(argv[i],"memdb")==0)n=probe_memdb_trace(out,sizeof(out));
    else return 2;
    if(n<0 || n>=(int)sizeof(out))return 3;
    fwrite(out,1,(size_t)n,stdout);
  }
  return 0;
}
