#include <clang-c/Index.h>

#include <stdio.h>
#include <string.h>

struct function_context {
  CXCursor caller;
};

static int source_location(CXCursor cursor, CXString *file_string,
                           const char **file, unsigned *line) {
  unsigned column = 0;
  CXSourceLocation location = clang_getCursorLocation(cursor);
  clang_getPresumedLocation(location, file_string, line, &column);
  *file = clang_getCString(*file_string);
  return *file != NULL && strncmp(*file, "tsrc/", 5) == 0;
}

static enum CXChildVisitResult reference_visitor(CXCursor cursor,
                                                  CXCursor parent,
                                                  CXClientData data) {
  struct function_context *context = (struct function_context *)data;
  enum CXCursorKind kind = clang_getCursorKind(cursor);
  const char *edge_kind = NULL;
  CXCursor referenced;
  CXString caller_file_string;
  CXString callee_file_string;
  CXString caller_name_string;
  CXString callee_name_string;
  const char *caller_file;
  const char *callee_file;
  const char *caller_name;
  const char *callee_name;
  unsigned caller_line = 0;
  unsigned callee_line = 0;
  (void)parent;

  if (kind == CXCursor_CallExpr) {
    edge_kind = "call";
  } else if (kind == CXCursor_DeclRefExpr) {
    CXCursor candidate = clang_getCursorReferenced(cursor);
    if (clang_getCursorKind(candidate) == CXCursor_VarDecl &&
        clang_getCursorKind(clang_getCursorSemanticParent(candidate)) ==
            CXCursor_TranslationUnit) {
      edge_kind = "global";
    }
  } else if (kind == CXCursor_TypeRef) {
    edge_kind = "type";
  }
  if (edge_kind == NULL) return CXChildVisit_Recurse;

  referenced = clang_getCursorReferenced(cursor);
  if (clang_Cursor_isNull(referenced)) return CXChildVisit_Recurse;
  if (!source_location(context->caller, &caller_file_string, &caller_file,
                       &caller_line)) {
    clang_disposeString(caller_file_string);
    return CXChildVisit_Recurse;
  }
  if (!source_location(referenced, &callee_file_string, &callee_file,
                       &callee_line)) {
    clang_disposeString(caller_file_string);
    clang_disposeString(callee_file_string);
    return CXChildVisit_Recurse;
  }

  caller_name_string = clang_getCursorSpelling(context->caller);
  callee_name_string = clang_getCursorSpelling(referenced);
  caller_name = clang_getCString(caller_name_string);
  callee_name = clang_getCString(callee_name_string);
  if (caller_name != NULL && caller_name[0] != '\0' && callee_name != NULL &&
      callee_name[0] != '\0') {
    printf("%s\t%s\t%s\t%u\t%s\t%s\t%u\n", edge_kind, caller_file + 5,
           caller_name, caller_line, callee_file + 5, callee_name, callee_line);
  }
  clang_disposeString(caller_name_string);
  clang_disposeString(callee_name_string);
  clang_disposeString(caller_file_string);
  clang_disposeString(callee_file_string);
  return CXChildVisit_Recurse;
}

static enum CXChildVisitResult top_visitor(CXCursor cursor, CXCursor parent,
                                            CXClientData data) {
  (void)parent;
  (void)data;
  if (clang_getCursorKind(cursor) == CXCursor_FunctionDecl &&
      clang_isCursorDefinition(cursor)) {
    struct function_context context = {cursor};
    clang_visitChildren(cursor, reference_visitor, &context);
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
    fprintf(stderr, "usage: clang_dependency SQLITE3_LINEMACRO_C\n");
    return 2;
  }
  index = clang_createIndex(0, 0);
  unit = clang_parseTranslationUnit(
      index, argv[1], arguments,
      (int)(sizeof(arguments) / sizeof(arguments[0])), NULL, 0,
      CXTranslationUnit_None);
  if (unit == NULL) {
    fprintf(stderr, "clang_dependency: unable to parse translation unit\n");
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
  clang_visitChildren(clang_getTranslationUnitCursor(unit), top_visitor, NULL);
  clang_disposeTranslationUnit(unit);
  clang_disposeIndex(index);
  return 0;
}
