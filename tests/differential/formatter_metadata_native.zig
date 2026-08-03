const std = @import("std");
const formatter = @import("formatter");

pub fn main() void {
    std.debug.print("CONST\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        formatter.flag_signed,
        formatter.flag_string,
        formatter.print_buffer_size,
        formatter.floating_precision_limit,
        formatter.max_log_message,
    });
    std.debug.print("DIGITS\t", .{});
    for (formatter.digits) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\nPREFIX\t", .{});
    for (formatter.prefixes[0..6]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
    for (formatter.format_info, 0..) |info, index| {
        std.debug.print("INFO\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            index,
            info.fmttype,
            info.base,
            info.flags,
            info.conversion_type,
            info.charset,
            info.prefix,
            info.iNxt,
        });
    }
    for (0..256) |raw| {
        const result = formatter.lookup(@intCast(raw));
        std.debug.print("LOOK\t{d}\t{d}\t{d}\n", .{ raw, result.info_index, result.conversion_type });
    }
}
