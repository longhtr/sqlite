#include "parser_probe.h"

#include <stddef.h>

void *ProbeParserAlloc(void *(*mallocProc)(size_t));
void ProbeParser(void *parser, int major, int minor, int *result);
void ProbeParserFree(void *parser, void (*freeProc)(void *));
extern int sqlite_zig_parser_action_calls(void);
extern void sqlite_zig_parser_set_fail(ptrdiff_t);
extern void *sqlite_zig_parser_malloc(size_t);
extern void sqlite_zig_parser_free(void*);
extern size_t sqlite_zig_parser_outstanding(void);

int run_parser_probe(void) {
  int result = 0;
  sqlite_zig_parser_set_fail(-1);
  void *parser = ProbeParserAlloc(sqlite_zig_parser_malloc);
  if (parser == NULL) return 1;

  ProbeParser(parser, PROBE_INTEGER, 20, &result);
  ProbeParser(parser, PROBE_PLUS, 0, &result);
  ProbeParser(parser, PROBE_INTEGER, 22, &result);
  ProbeParser(parser, 0, 0, &result);
  ProbeParserFree(parser, sqlite_zig_parser_free);

  if (result != 42) return 2;
  if (sqlite_zig_parser_action_calls() != 1) return 3;

  result = 0;
  parser = ProbeParserAlloc(sqlite_zig_parser_malloc);
  if (parser == NULL) return 4;
  ProbeParser(parser, PROBE_PLUS, 0, &result);
  ProbeParser(parser, 0, 0, &result);
  ProbeParserFree(parser, sqlite_zig_parser_free);
  if (result != -100 && result != -200) return 5;
  if (sqlite_zig_parser_outstanding() != 0) return 6;

  sqlite_zig_parser_set_fail(0);
  parser = ProbeParserAlloc(sqlite_zig_parser_malloc);
  if (parser != NULL || sqlite_zig_parser_outstanding() != 0) return 7;
  sqlite_zig_parser_set_fail(-1);
  return 0;
}
