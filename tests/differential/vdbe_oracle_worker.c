#include "sqlite3.c"
#include <stdio.h>
#include <string.h>

static void field(sqlite3_stmt*s,int i){int t=sqlite3_column_type(s,i),j,n;const unsigned char*z;if(t==SQLITE_NULL){printf("\tN");return;}if(t==SQLITE_INTEGER){printf("\tI:%lld",sqlite3_column_int64(s,i));return;}if(t==SQLITE_FLOAT){printf("\tR:%.15g",sqlite3_column_double(s,i));return;}z=sqlite3_column_blob(s,i);n=sqlite3_column_bytes(s,i);printf("\t%c:",t==SQLITE_TEXT?'T':'B');for(j=0;j<n;j++)printf("%02x",z[j]);}
static int record_program(void){sqlite3*db=0;Parse p;Vdbe*v;double real=3.5;static const unsigned char blob[]={0,255};int rc,i;Mem*m;if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;memset(&p,0,sizeof(p));p.db=db;v=sqlite3VdbeCreate(&p);p.nMem=6;sqlite3VdbeAddOp2(v,OP_Integer,42,1);sqlite3VdbeAddOp4(v,OP_String8,0,2,0,"hi",P4_STATIC);sqlite3VdbeAddOp2(v,OP_Null,0,3);sqlite3VdbeAddOp4Dup8(v,OP_Real,0,4,0,(const u8*)&real,P4_REAL);sqlite3VdbeAddOp4(v,OP_Blob,2,5,0,(const char*)blob,P4_STATIC);sqlite3VdbeAddOp3(v,OP_MakeRecord,1,5,6);sqlite3VdbeAddOp2(v,OP_ResultRow,6,1);sqlite3VdbeAddOp0(v,OP_Halt);sqlite3VdbeMakeReady(v,&p);rc=sqlite3_step((sqlite3_stmt*)v);if(rc!=SQLITE_ROW)return 1;m=&v->pResultRow[0];printf("record\trow:0\tB:");for(i=0;i<m->n;i++)printf("%02x",(unsigned char)m->z[i]);printf("\nrecord\tregisters:0\tB:");for(i=0;i<m->n;i++)printf("%02x",(unsigned char)m->z[i]);printf("\n");rc=sqlite3_step((sqlite3_stmt*)v);printf("record\tdone\t%d\t3\n",rc);sqlite3_finalize((sqlite3_stmt*)v);sqlite3_close(db);return rc==SQLITE_DONE?0:1;}
static int finish_rowset_program(const char *name,sqlite3 *db,Vdbe *v,Parse *p){
  int rc,row=0; sqlite3VdbeMakeReady(v,p);
  while((rc=sqlite3_step((sqlite3_stmt*)v))==SQLITE_ROW){
    sqlite3_int64 x=v->pResultRow[0].u.i;
    printf("%s\trow:%d\tI:%lld\n",name,row,(long long)x);
    printf("%s\tregisters:%d\tI:%lld\n",name,row,(long long)x); row++;
  }
  printf("%s\tdone\t%d\t3\n",name,rc);
  sqlite3_finalize((sqlite3_stmt*)v); sqlite3_close(db);
  return rc==SQLITE_DONE?0:1;
}
static int rowset_program(void){
  sqlite3 *db=0; Parse p; Vdbe *v; int addrRead,addrDone;
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;
  memset(&p,0,sizeof(p)); p.db=db; v=sqlite3VdbeCreate(&p); p.nMem=3;
  sqlite3VdbeAddOp2(v,OP_Integer,9,2);
  sqlite3VdbeAddOp2(v,OP_RowSetAdd,1,2);
  sqlite3VdbeAddOp2(v,OP_Integer,3,2);
  sqlite3VdbeAddOp2(v,OP_RowSetAdd,1,2);
  sqlite3VdbeAddOp2(v,OP_Integer,9,2);
  sqlite3VdbeAddOp2(v,OP_RowSetAdd,1,2);
  addrRead=sqlite3VdbeAddOp3(v,OP_RowSetRead,1,0,3);
  sqlite3VdbeAddOp2(v,OP_ResultRow,3,1);
  sqlite3VdbeAddOp2(v,OP_Goto,0,addrRead);
  addrDone=sqlite3VdbeAddOp0(v,OP_Halt);
  sqlite3VdbeChangeP2(v,addrRead,addrDone);
  return finish_rowset_program("rowset",db,v,&p);
}
static int rowset_test_program(void){
  sqlite3 *db=0; Parse p; Vdbe *v; int addrTest,addrGoto,addrHit,addrResult;
  if(sqlite3_open(":memory:",&db)!=SQLITE_OK)return 1;
  memset(&p,0,sizeof(p)); p.db=db; v=sqlite3VdbeCreate(&p); p.nMem=3;
  sqlite3VdbeAddOp2(v,OP_Integer,10,2);
  sqlite3VdbeAddOp4Int(v,OP_RowSetTest,1,0,2,0);
  sqlite3VdbeAddOp2(v,OP_Integer,10,2);
  addrTest=sqlite3VdbeAddOp4Int(v,OP_RowSetTest,1,0,2,1);
  sqlite3VdbeAddOp2(v,OP_Integer,0,3);
  addrGoto=sqlite3VdbeAddOp2(v,OP_Goto,0,0);
  addrHit=sqlite3VdbeAddOp2(v,OP_Integer,1,3);
  addrResult=sqlite3VdbeAddOp2(v,OP_ResultRow,3,1);
  sqlite3VdbeAddOp0(v,OP_Halt);
  sqlite3VdbeChangeP2(v,addrTest,addrHit);
  sqlite3VdbeChangeP2(v,addrGoto,addrResult);
  return finish_rowset_program("rowset_test",db,v,&p);
}
int main(int n,char**a){if(n!=2)return 2;if(!strcmp(a[1],"record"))return record_program();if(!strcmp(a[1],"rowset"))return rowset_program();if(!strcmp(a[1],"rowset_test"))return rowset_test_program();if(!strcmp(a[1],"error")){sqlite3*e=0;sqlite3_open(":memory:",&e);sqlite3_exec(e,"CREATE TABLE q(x UNIQUE);INSERT INTO q VALUES(1)",0,0,0);int erc=sqlite3_exec(e,"INSERT INTO q VALUES(1)",0,0,0);printf("error\tdone\t%d\t4\n",erc);sqlite3_close(e);return erc==SQLITE_CONSTRAINT?0:1;}const char*sql=0;if(!strcmp(a[1],"scalar"))sql="SELECT 7+5,7-5,7*5,7/5,7%5,'ab'||'cd',NOT 0,NULL AND 0,NULL OR 1";else if(!strcmp(a[1],"cursor"))sql="WITH t(id,v) AS (VALUES(1,'one'),(3,'three'),(5,'five')) SELECT id,v FROM t ORDER BY id";else if(!strcmp(a[1],"function"))sql="SELECT abs(-9),length('zig'),NULL,coalesce(NULL,'fallback')";else if(!strcmp(a[1],"frame"))sql="SELECT 42,42+8";else if(!strcmp(a[1],"comparison"))sql="SELECT 7=7,7>5,NULL";else if(!strcmp(a[1],"cast"))sql="SELECT CAST('42' AS TEXT),CAST('42' AS REAL),CAST('42' AS BLOB)";else if(!strcmp(a[1],"seek"))sql="WITH t(id,v) AS (VALUES(1,'one'),(3,'three'),(5,'five')) SELECT id,v,(SELECT count(*) FROM t) FROM t WHERE id=3";else if(!strcmp(a[1],"coroutine"))sql="SELECT 10 UNION ALL SELECT 20";else if(!strcmp(a[1],"extended"))sql="SELECT ~5,NULL IS TRUE,NULL IS NOT TRUE,CAST('42' AS INTEGER)";else if(!strcmp(a[1],"cursor_state"))sql="SELECT a.x,b.y FROM (SELECT 1 x UNION ALL SELECT 2 ORDER BY x) a LEFT JOIN (SELECT 1 x,'one' y) b ON a.x=b.x ORDER BY a.x";else if(!strcmp(a[1],"variable"))sql="SELECT ?1,?2,?3";else return 2;sqlite3*db=0;sqlite3_stmt*s=0;int rc=sqlite3_open(":memory:",&db);if(rc==SQLITE_OK)rc=sqlite3_prepare_v2(db,sql,-1,&s,0);int row=0;if(rc==SQLITE_OK&&!strcmp(a[1],"variable")){sqlite3_bind_text(s,1,"bound",-1,SQLITE_STATIC);sqlite3_bind_int64(s,2,42);sqlite3_bind_null(s,3);}if(rc==SQLITE_OK)while((rc=sqlite3_step(s))==SQLITE_ROW){printf("%s\trow:%d",a[1],row++);for(int i=0;i<sqlite3_column_count(s);i++)field(s,i);printf("\n%s\tregisters:%d",a[1],row-1);for(int i=0;i<sqlite3_column_count(s);i++)field(s,i);printf("\n");}if(rc==SQLITE_DONE)printf("%s\tdone\t101\t3\n",a[1]);else fprintf(stderr,"oracle rc=%d %s\n",rc,sqlite3_errmsg(db));sqlite3_finalize(s);sqlite3_close(db);return rc==SQLITE_DONE?0:rc;}
