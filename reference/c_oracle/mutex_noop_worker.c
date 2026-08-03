#define SQLITE_CORE 1
#include "sqlite3.c"
#include <stdio.h>
int main(void){const sqlite3_mutex_methods*m=sqlite3NoopMutex();sqlite3_mutex*a,*b;printf("1\t%zu\t%d\t%d\n",sizeof(*m),m->xMutexHeld==0,m->xMutexNotheld==0);printf("2\t%d\t%d\n",m->xMutexInit(),m->xMutexEnd());a=m->xMutexAlloc(0);b=m->xMutexAlloc(13);printf("3\t%ld\t%d\n",(long)(size_t)a,a==b);m->xMutexEnter(a);printf("4\t%d\n",m->xMutexTry(a));m->xMutexLeave(a);m->xMutexFree(a);printf("5\t%d\n",m==sqlite3NoopMutex());return 0;}
