const std = @import("std");
const formatter = @import("formatter");

fn dump(name: []const u8, accumulator: *const formatter.Accumulator) void {
    std.debug.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t", .{
        name,
        accumulator.nAlloc,
        accumulator.mxAlloc,
        accumulator.nChar,
        accumulator.accError,
        accumulator.printfFlags,
        @intFromBool(formatter.isMalloced(accumulator)),
    });
    if (accumulator.zText) |text| {
        for (text[0..accumulator.nChar]) |byte| std.debug.print("{x:0>2}", .{byte});
    } else {
        std.debug.print("NULL", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var manager = formatter.memory.Manager.init(formatter.memory.systemBackend());
    if (manager.start() != formatter.memory.ok) return error.InitializeFailed;
    defer manager.stop();

    std.debug.print("LAYOUT\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @sizeOf(formatter.Accumulator),
        @alignOf(formatter.Accumulator),
        @offsetOf(formatter.Accumulator, "db"),
        @offsetOf(formatter.Accumulator, "zText"),
        @offsetOf(formatter.Accumulator, "nAlloc"),
        @offsetOf(formatter.Accumulator, "mxAlloc"),
        @offsetOf(formatter.Accumulator, "nChar"),
        @offsetOf(formatter.Accumulator, "accError"),
        @offsetOf(formatter.Accumulator, "printfFlags"),
    });

    var accumulator: formatter.Accumulator = undefined;
    var fixed: [8]u8 = undefined;
    var finish: [32]u8 = undefined;

    formatter.strAccumInit(&accumulator, null, &fixed, fixed.len, 0);
    dump("fixed-init", &accumulator);
    formatter.strAppend(&accumulator, &manager, "1234567");
    dump("fixed-full", &accumulator);
    formatter.strAppendChar(&accumulator, &manager, 1, '8');
    dump("fixed-toobig", &accumulator);
    formatter.strReset(&accumulator, &manager);
    dump("fixed-reset", &accumulator);

    formatter.strAccumInit(&accumulator, null, &fixed, fixed.len, 128);
    formatter.strAppend(&accumulator, &manager, "abc");
    formatter.strAppend(&accumulator, &manager, "defghijkl");
    dump("dynamic-grown", &accumulator);
    formatter.strTruncate(&accumulator, 5);
    dump("dynamic-truncated", &accumulator);
    _ = formatter.strAccumFinish(&accumulator, &manager);
    dump("dynamic-finished", &accumulator);
    formatter.strReset(&accumulator, &manager);
    dump("dynamic-reset", &accumulator);

    formatter.strAccumInit(&accumulator, null, &finish, finish.len, 128);
    formatter.strAppendAll(&accumulator, &manager, "hello");
    _ = formatter.strAccumFinish(&accumulator, &manager);
    dump("finish-reallocated", &accumulator);
    formatter.strReset(&accumulator, &manager);

    formatter.strAccumInit(&accumulator, null, null, 0, 10);
    formatter.strAppend(&accumulator, &manager, "01234567890123456789");
    dump("dynamic-toobig", &accumulator);

    formatter.strAccumInit(&accumulator, null, null, 0, 128);
    formatter.strAppend(&accumulator, &manager, "");
    dump("empty-allocation", &accumulator);
    formatter.strReset(&accumulator, &manager);
}
