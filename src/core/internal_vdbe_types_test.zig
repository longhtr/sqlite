const std = @import("std");
const vdbe = @import("internal/vdbe_types.zig");
const compiler_ownership = @import("internal/compiler_ownership.zig");

test "analyze all active internal VDBE declarations" {
    var db: vdbe.Sqlite3 = undefined;
    compiler_ownership.deleteExpression(&db, null);
    compiler_ownership.deleteExpressionList(&db, null);
    compiler_ownership.deleteWindow(&db, null);
    compiler_ownership.deleteWindowList(&db, null);
    compiler_ownership.deleteIdentifierList(&db, null);
    compiler_ownership.deleteWith(&db, null);
    compiler_ownership.deleteSelect(&db, null);
    compiler_ownership.deleteSourceList(&db, null);
    compiler_ownership.deleteTable(&db, null);
    comptime {
        for (std.meta.declarations(vdbe)) |declaration| {
            _ = @field(vdbe, declaration.name);
        }
    }
}
