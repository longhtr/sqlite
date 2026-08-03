BEGIN;
CREATE TABLE symbol(
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  isTerminal BOOLEAN NOT NULL,
  fallback INTEGER REFERENCES symbol DEFERRABLE INITIALLY DEFERRED
);
INSERT INTO symbol(id,name,isTerminal,fallback)VALUES(0,'$',TRUE,NULL);
INSERT INTO symbol(id,name,isTerminal,fallback)VALUES(1,'INTEGER',TRUE,NULL);
INSERT INTO symbol(id,name,isTerminal,fallback)VALUES(2,'PLUS',TRUE,NULL);
INSERT INTO symbol(id,name,isTerminal,fallback)VALUES(3,'input',FALSE,NULL);
CREATE TABLE rule(
  ruleid INTEGER PRIMARY KEY,
  lhs INTEGER REFERENCES symbol(id),
  txt TEXT
);
CREATE TABLE rulerhs(
  ruleid INTEGER REFERENCES rule(ruleid),
  pos INTEGER,
  sym INTEGER REFERENCES symbol(id)
);
INSERT INTO rule(ruleid,lhs,txt)VALUES(0,3,'input ::= INTEGER PLUS INTEGER');
INSERT INTO rulerhs(ruleid,pos,sym)VALUES(0,0,1);
INSERT INTO rulerhs(ruleid,pos,sym)VALUES(0,1,2);
INSERT INTO rulerhs(ruleid,pos,sym)VALUES(0,2,1);
COMMIT;
