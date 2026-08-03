#include <clang-c/Index.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *entity_kind(enum CXCursorKind kind) {
  switch (kind) {
    case CXCursor_FunctionDecl: return "function";
    case CXCursor_VarDecl: return "variable";
    case CXCursor_StructDecl: return "struct";
    case CXCursor_UnionDecl: return "union";
    case CXCursor_EnumDecl: return "enum";
    case CXCursor_EnumConstantDecl: return "enumerator";
    case CXCursor_FieldDecl: return "member";
    case CXCursor_TypedefDecl: return "typedef";
    case CXCursor_MacroDefinition: return "macro";
    default: return NULL;
  }
}

static int should_emit(CXCursor cursor) {
  enum CXCursorKind kind = clang_getCursorKind(cursor);
  switch (kind) {
    case CXCursor_FunctionDecl:
    case CXCursor_StructDecl:
    case CXCursor_UnionDecl:
    case CXCursor_EnumDecl:
      return clang_isCursorDefinition(cursor);
    case CXCursor_VarDecl:
      return clang_getCursorKind(clang_getCursorSemanticParent(cursor)) ==
             CXCursor_TranslationUnit;
    case CXCursor_EnumConstantDecl:
    case CXCursor_FieldDecl:
    case CXCursor_TypedefDecl:
    case CXCursor_MacroDefinition:
      return 1;
    default:
      return 0;
  }
}

static enum CXChildVisitResult visitor(CXCursor cursor, CXCursor parent,
                                        CXClientData data) {
  const char *kind = entity_kind(clang_getCursorKind(cursor));
  (void)parent;
  (void)data;
  if (kind != NULL && should_emit(cursor)) {
    CXString spelling = clang_getCursorSpelling(cursor);
    CXString presumed_file;
    unsigned line = 0;
    unsigned column = 0;
    unsigned physical_line = 0;
    unsigned physical_column = 0;
    unsigned physical_offset = 0;
    CXFile physical_file;
    CXString filename;
    CXCursor semantic_parent = clang_getCursorSemanticParent(cursor);
    CXString parent_spelling = clang_getCursorSpelling(semantic_parent);
    CXString parent_kind_spelling = clang_getCursorKindSpelling(
        clang_getCursorKind(semantic_parent));
    const char *name = clang_getCString(spelling);
    const char *file;
    const char *parent_name = clang_getCString(parent_spelling);
    const char *parent_kind = clang_getCString(parent_kind_spelling);
    CXSourceLocation location = clang_getCursorLocation(cursor);
    clang_getPresumedLocation(location, &presumed_file, &line, &column);
    clang_getFileLocation(location, &physical_file, &physical_line,
                          &physical_column, &physical_offset);
    filename = presumed_file;
    file = clang_getCString(filename);
    if (file != NULL && strncmp(file, "tsrc/", 5) == 0 && name != NULL &&
        name[0] != '\0') {
      printf("%s\t%s\t%u\t%u\t%s\t%s\t%s\n", kind, file + 5, line,
             physical_line, parent_kind != NULL ? parent_kind : "",
             parent_name != NULL ? parent_name : "", name);
    }
    clang_disposeString(parent_kind_spelling);
    clang_disposeString(parent_spelling);
    clang_disposeString(filename);
    clang_disposeString(spelling);
    if (clang_getCursorKind(cursor) == CXCursor_FunctionDecl)
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
    fprintf(stderr, "usage: clang_inventory SQLITE3_LINEMACRO_C\n");
    return 2;
  }
  index = clang_createIndex(0, 0);
  unit = clang_parseTranslationUnit(
      index, argv[1], arguments,
      (int)(sizeof(arguments) / sizeof(arguments[0])), NULL, 0,
      CXTranslationUnit_DetailedPreprocessingRecord);
  if (unit == NULL) {
    fprintf(stderr, "clang_inventory: unable to parse translation unit\n");
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
  clang_visitChildren(clang_getTranslationUnitCursor(unit), visitor, NULL);
  clang_disposeTranslationUnit(unit);
  clang_disposeIndex(index);
  return 0;
}
