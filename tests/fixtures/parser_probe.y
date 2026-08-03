%name ProbeParser
%token_prefix PROBE_
%token_type {int}
%default_type {int}
%extra_argument {int *result}
%include {
  #include <stddef.h>
  extern int sqlite_zig_parser_add(int, int);
}

input ::= INTEGER(A) PLUS INTEGER(B). {
  *result = sqlite_zig_parser_add(A, B);
}

%syntax_error {
  *result = -100;
}

%parse_failure {
  *result = -200;
}
