#include "sqlite3.c"
long long probe_token(const unsigned char*z,int*t){return (long long)sqlite3GetToken(z,t);}
void probe_context(const unsigned char*z,int*w,int*o,int*f){*w=analyzeWindowKeyword(z);*o=analyzeOverKeyword(z,TK_RP);*f=analyzeFilterKeyword(z,TK_RP);}
#include "../../tests/differential/tokenizer_worker_main.c"
