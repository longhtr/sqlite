#include <stdarg.h>
#include <stdint.h>

extern int sqlite_zig_variadic_dispatch(
    int op,
    int int_arg,
    void *ptr_arg,
    int64_t i64_arg,
    double double_arg);

static int probe_config_shape(int op, ...) {
  int int_arg = 0;
  void *ptr_arg = 0;
  int64_t i64_arg = 0;
  double double_arg = 0.0;
  va_list args;
  va_start(args, op);
  switch (op) {
    case 0:
      break;
    case 1:
      int_arg = va_arg(args, int);
      break;
    case 2:
      ptr_arg = va_arg(args, void *);
      int_arg = va_arg(args, int);
      break;
    case 3:
      i64_arg = va_arg(args, int64_t);
      double_arg = va_arg(args, double);
      break;
    default:
      va_end(args);
      return -1;
  }
  va_end(args);
  return sqlite_zig_variadic_dispatch(
      op, int_arg, ptr_arg, i64_arg, double_arg);
}

int run_variadic_probe(void) {
  int marker = 9;
  if (probe_config_shape(0) != 100) return 1;
  if (probe_config_shape(1, 42) != 142) return 2;
  if (probe_config_shape(2, &marker, 7) != 207) return 3;
  if (probe_config_shape(3, INT64_C(0x102030405060708), 2.5) != 325) return 4;
  return 0;
}
