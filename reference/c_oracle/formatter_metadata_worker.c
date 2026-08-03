#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>

int main(void){
  unsigned int c;
  int i;
  printf("CONST\t%d\t%d\t%d\t%d\t%d\n",FLAG_SIGNED,FLAG_STRING,SQLITE_PRINT_BUF_SIZE,SQLITE_FP_PRECISION_LIMIT,SQLITE_MAX_LOG_MESSAGE);
  printf("DIGITS\t");
  for(i=0; aDigits[i]; i++) printf("%02x",(unsigned char)aDigits[i]);
  printf("\nPREFIX\t");
  for(i=0; i<6; i++) printf("%02x",(unsigned char)aPrefix[i]);
  printf("\n");
  for(i=0; i<23; i++){
    const et_info *p=&fmtinfo[i];
    printf("INFO\t%d\t%u\t%u\t%u\t%u\t%u\t%u\t%u\n",i,(unsigned char)p->fmttype,p->base,p->flags,p->type,p->charset,p->prefix,(unsigned char)p->iNxt);
  }
  for(c=0; c<256; c++){
    int idx=(int)(c%23);
    int xtype=etINVALID;
    if((unsigned char)fmtinfo[idx].fmttype==c || (idx=(unsigned char)fmtinfo[idx].iNxt,(unsigned char)fmtinfo[idx].fmttype==c)){
      xtype=fmtinfo[idx].type;
    }else{
      idx=0;
    }
    printf("LOOK\t%u\t%d\t%d\n",c,idx,xtype);
  }
  return 0;
}
