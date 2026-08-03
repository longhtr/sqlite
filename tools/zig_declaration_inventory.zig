//! Emit an AST-derived inventory of declarations in Zig source files.
//!
//! Output is tab-separated: file, kind, qualified name, visibility, line,
//! byte start, byte end. The companion Python generator turns this stream into
//! the committed JSON inventory used to validate source-ledger targets.

const std = @import("std");
const Ast = std.zig.Ast;

const InventoryError = error{InvalidZigSource};

fn emit(
    tree: Ast,
    path: []const u8,
    kind: []const u8,
    qualified: []const u8,
    public: bool,
    token: Ast.TokenIndex,
    node: Ast.Node.Index,
) void {
    const location = tree.tokenLocation(0, token);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    std.debug.print("{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n", .{
        path,
        kind,
        qualified,
        if (public) "public" else "private",
        location.line + 1,
        start,
        end,
    });
}

fn qualifiedName(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, name });
}

fn walkMembers(
    allocator: std.mem.Allocator,
    tree: Ast,
    path: []const u8,
    members: []const Ast.Node.Index,
    prefix: []const u8,
    enum_fields: bool,
) !void {
    for (members) |node| {
        var fn_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_buffer, node)) |function| {
            const name_token = function.name_token orelse continue;
            const name = tree.tokenSlice(name_token);
            const qualified = try qualifiedName(allocator, prefix, name);
            defer allocator.free(qualified);
            emit(tree, path, "function", qualified, function.visib_token != null, name_token, node);
            continue;
        }

        if (tree.fullVarDecl(node)) |variable| {
            const name_token = variable.ast.mut_token + 1;
            if (tree.tokenTag(name_token) != .identifier) continue;
            const name = tree.tokenSlice(name_token);
            const qualified = try qualifiedName(allocator, prefix, name);
            defer allocator.free(qualified);
            const kind = switch (tree.tokenTag(variable.ast.mut_token)) {
                .keyword_const => "constant",
                .keyword_var => "variable",
                else => continue,
            };
            emit(tree, path, kind, qualified, variable.visib_token != null, name_token, node);

            if (variable.ast.init_node.unwrap()) |init_node| {
                var container_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&container_buffer, init_node)) |container| {
                    try walkMembers(
                        allocator,
                        tree,
                        path,
                        container.ast.members,
                        qualified,
                        tree.tokenTag(container.ast.main_token) == .keyword_enum,
                    );
                }
            }
            continue;
        }

        if (tree.fullContainerField(node)) |field| {
            if (field.ast.tuple_like and !enum_fields) continue;
            const name_token = field.ast.main_token;
            if (tree.tokenTag(name_token) != .identifier) continue;
            const name = tree.tokenSlice(name_token);
            const qualified = try qualifiedName(allocator, prefix, name);
            defer allocator.free(qualified);
            emit(tree, path, if (enum_fields) "enum-field" else "field", qualified, false, name_token, node);
        }
    }
}

fn inventoryFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        std.debug.print("zig-declaration-inventory: {s}: {d} parse errors\n", .{ path, tree.errors.len });
        return InventoryError.InvalidZigSource;
    }
    try walkMembers(allocator, tree, path, tree.rootDecls(), "", false);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    var count: usize = 0;
    while (args.next()) |path| {
        try inventoryFile(init.gpa, init.io, path);
        count += 1;
    }
    if (count == 0) {
        std.debug.print("usage: zig_declaration_inventory FILE...\n", .{});
        return error.MissingSourceFile;
    }
}
