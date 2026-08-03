#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
long long probe_token(const unsigned char*,int*);
void probe_context(const unsigned char*,int*,int*,int*);
static int hx(int c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;}
int main(int argc,char**argv){for(int k=1;k<argc;k++){size_t n=strlen(argv[k]);if(n&1)return 2;unsigned char*b=malloc(n/2+4);if(!b)return 3;for(size_t i=0;i<n;i+=2){int a=hx(argv[k][i]),c=hx(argv[k][i+1]);if(a<0||c<0)return 4;b[i/2]=(unsigned char)((a<<4)|c);}n/=2;b[n]=b[n+1]=b[n+2]=b[n+3]=0;size_t p=0;printf("T");while(p<=n){int type=-1;long long z=probe_token(b+p,&type);printf("\t%d:%lld",type,z);if(z<=0)break;p+=(size_t)z;}int w,o,f;probe_context(b,&w,&o,&f);printf("\tC:%d,%d,%d\n",w,o,f);free(b);}return 0;}
