/* Emit active-profile control-flow and assertion cursors for the behavioral ledger. */
#include <clang-c/Index.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct FunctionContext FunctionContext;
struct FunctionContext {
  const char *function_name;
};

static const char *behavior_kind(enum CXCursorKind kind) {
  switch (kind) {
    case CXCursor_IfStmt: return "if";
    case CXCursor_SwitchStmt: return "switch";
    case CXCursor_CaseStmt: return "case";
    case CXCursor_DefaultStmt: return "default";
    case CXCursor_ConditionalOperator: return "conditional";
    case CXCursor_ForStmt: return "for";
    case CXCursor_WhileStmt: return "while";
    case CXCursor_DoStmt: return "do";
    case CXCursor_GotoStmt: return "goto";
    case CXCursor_LabelStmt: return "label";
    case CXCursor_ReturnStmt: return "return";
    case CXCursor_BreakStmt: return "break";
    case CXCursor_ContinueStmt: return "continue";
    default: return NULL;
  }
}

static void emit_behavior(CXCursor cursor, const char *kind,
                          const char *function_name) {
  CXSourceRange range = clang_getCursorExtent(cursor);
  CXSourceLocation start = clang_getRangeStart(range);
  CXSourceLocation end = clang_getRangeEnd(range);
  CXString start_file;
  CXString end_file;
  CXFile physical_file;
  unsigned start_line = 0, start_column = 0;
  unsigned end_line = 0, end_column = 0;
  unsigned physical_line = 0, physical_column = 0, physical_offset = 0;
  CXString spelling = clang_getCursorSpelling(cursor);
  const char *label = clang_getCString(spelling);
  const char *filename;

  clang_getPresumedLocation(start, &start_file, &start_line, &start_column);
  clang_getPresumedLocation(end, &end_file, &end_line, &end_column);
  clang_getFileLocation(start, &physical_file, &physical_line,
                        &physical_column, &physical_offset);
  filename = clang_getCString(start_file);
  if (filename != NULL && strncmp(filename, "tsrc/", 5) == 0) {
    printf("%s\t%s\t%u\t%u\t%u\t%u\t%u\t%s\t%s\n", kind,
           filename + 5, start_line, start_column, end_line, end_column,
           physical_line, function_name, label != NULL ? label : "");
  }
  clang_disposeString(spelling);
  clang_disposeString(end_file);
  clang_disposeString(start_file);
}

static enum CXChildVisitResult function_visitor(CXCursor cursor,
                                                 CXCursor parent,
                                                 CXClientData raw_context) {
  FunctionContext *context = (FunctionContext *)raw_context;
  enum CXCursorKind cursor_kind = clang_getCursorKind(cursor);
  const char *kind = behavior_kind(cursor_kind);
  (void)parent;
  if (kind != NULL) emit_behavior(cursor, kind, context->function_name);
  return CXChildVisit_Recurse;
}

static enum CXChildVisitResult translation_unit_visitor(CXCursor cursor,
                                                         CXCursor parent,
                                                         CXClientData raw_unit) {
  (void)parent;
  (void)raw_unit;
  if (clang_getCursorKind(cursor) == CXCursor_MacroExpansion) {
    CXString spelling = clang_getCursorSpelling(cursor);
    const char *name = clang_getCString(spelling);
    if (name != NULL && strcmp(name, "assert") == 0) {
      emit_behavior(cursor, "assert", "");
    }
    clang_disposeString(spelling);
    return CXChildVisit_Continue;
  }
  if (clang_getCursorKind(cursor) == CXCursor_FunctionDecl &&
      clang_isCursorDefinition(cursor)) {
    CXString spelling = clang_getCursorSpelling(cursor);
    const char *name = clang_getCString(spelling);
    if (name != NULL && name[0] != '\0') {
      FunctionContext context;
      context.function_name = name;
      clang_visitChildren(cursor, function_visitor, &context);
    }
    clang_disposeString(spelling);
    return CXChildVisit_Continue;
  }
  return CXChildVisit_Recurse;
}

int main(int argc, char **argv) {
  static const char *arguments[] = {
      "-std=c99",
      "-resource-dir=/usr/lib/clang/21",
      "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
      "-DSQLITE_ENABLE_PERCENTILE=1",
      "-DSQLITE_HAVE_ZLIB=1",
      "-DSQLITE_THREADSAFE=1",
  };
  CXIndex index;
  CXTranslationUnit unit;
  unsigned diagnostics;
  unsigned i;

  if (argc != 2) {
    fprintf(stderr, "usage: clang_behavior SQLITE3_LINEMACRO_C\n");
    return 2;
  }
  index = clang_createIndex(0, 0);
  unit = clang_parseTranslationUnit(
      index, argv[1], arguments,
      (int)(sizeof(arguments) / sizeof(arguments[0])), NULL, 0,
      CXTranslationUnit_DetailedPreprocessingRecord);
  if (unit == NULL) {
    fprintf(stderr, "clang_behavior: unable to parse translation unit\n");
    clang_disposeIndex(index);
    return 3;
  }
  diagnostics = clang_getNumDiagnostics(unit);
  for (i = 0; i < diagnostics; ++i) {
    CXDiagnostic diagnostic = clang_getDiagnostic(unit, i);
    enum CXDiagnosticSeverity severity = clang_getDiagnosticSeverity(diagnostic);
    if (severity >= CXDiagnostic_Error) {
      CXString text = clang_formatDiagnostic(
          diagnostic, clang_defaultDiagnosticDisplayOptions());
      fprintf(stderr, "%s\n", clang_getCString(text));
      clang_disposeString(text);
      clang_disposeDiagnostic(diagnostic);
      clang_disposeTranslationUnit(unit);
      clang_disposeIndex(index);
      return 4;
    }
    clang_disposeDiagnostic(diagnostic);
  }
  clang_visitChildren(clang_getTranslationUnitCursor(unit),
                      translation_unit_visitor, unit);
  clang_disposeTranslationUnit(unit);
  clang_disposeIndex(index);
  return 0;
}
