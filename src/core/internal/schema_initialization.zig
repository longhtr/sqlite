//! Schema-catalog initialization and cookie validation from `prepare.c`.

const std = @import("std");

pub const Error = error{ OutOfMemory, Corrupt, UnsupportedFormat, EncodingMismatch };

pub const CatalogRow = struct {
    object_type: []const u8,
    name: ?[]const u8,
    table_name: ?[]const u8,
    root_page: ?u32,
    sql: ?[]const u8,
};

pub const CatalogObject = struct {
    allocator: std.mem.Allocator,
    object_type: []u8,
    name: []u8,
    table_name: []u8,
    root_page: u32,
    sql: ?[]u8,

    pub fn deinit(self: *CatalogObject) void {
        self.allocator.free(self.object_type);
        self.allocator.free(self.name);
        self.allocator.free(self.table_name);
        if (self.sql) |sql| self.allocator.free(sql);
    }
};

pub const Schema = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    loaded: bool = false,
    schema_cookie: u32 = 0,
    file_format: u8 = 1,
    encoding: u8 = 1,
    cache_size: i32 = -2000,
    maximum_page: u32 = 0,
    objects: std.ArrayList(CatalogObject) = .empty,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Schema {
        return .{ .allocator = allocator, .name = name };
    }

    pub fn clear(self: *Schema) void {
        for (self.objects.items) |*object| object.deinit();
        self.objects.clearRetainingCapacity();
        self.loaded = false;
    }

    pub fn deinit(self: *Schema) void {
        self.clear();
        self.objects.deinit(self.allocator);
    }
};

pub const Metadata = struct {
    schema_cookie: u32,
    file_format: u8,
    cache_size: i32,
    encoding: u8,
    maximum_page: u32,
};

pub const InitContext = struct {
    allocator: std.mem.Allocator,
    schema: *Schema,
    write_schema: bool = false,
    alter_operation: ?[]const u8 = null,
    malloc_failed: bool = false,
    result: Error!void = {},
    message: ?[]u8 = null,
    row_count: usize = 0,

    pub fn deinit(self: *InitContext) void {
        if (self.message) |message| self.allocator.free(message);
    }
};

/// Source `corruptSchema()`.
pub fn reportCorruptSchema(context: *InitContext, row: CatalogRow, extra: ?[]const u8) void {
    if (context.malloc_failed) {
        context.result = error.OutOfMemory;
        return;
    }
    if (context.message != null) return;
    if (context.alter_operation) |operation| {
        context.message = std.fmt.allocPrint(context.allocator, "error in {s} {s} after {s}: {s}", .{
            row.object_type,
            row.name orelse "?",
            operation,
            extra orelse "malformed definition",
        }) catch {
            context.malloc_failed = true;
            context.result = error.OutOfMemory;
            return;
        };
        context.result = error.Corrupt;
    } else if (context.write_schema) {
        context.result = error.Corrupt;
    } else {
        context.message = std.fmt.allocPrint(context.allocator, "malformed database schema ({s}){s}{s}", .{
            row.name orelse "?",
            if (extra != null) " - " else "",
            extra orelse "",
        }) catch {
            context.malloc_failed = true;
            context.result = error.OutOfMemory;
            return;
        };
        context.result = error.Corrupt;
    }
}

fn appendObject(context: *InitContext, row: CatalogRow) Error!void {
    const name = row.name orelse return error.Corrupt;
    const table_name = row.table_name orelse name;
    const object_type = context.allocator.dupe(u8, row.object_type) catch return error.OutOfMemory;
    errdefer context.allocator.free(object_type);
    const owned_name = context.allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer context.allocator.free(owned_name);
    const owned_table = context.allocator.dupe(u8, table_name) catch return error.OutOfMemory;
    errdefer context.allocator.free(owned_table);
    const sql = if (row.sql) |text| context.allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (sql) |text| context.allocator.free(text);
    context.schema.objects.append(context.allocator, .{
        .allocator = context.allocator,
        .object_type = object_type,
        .name = owned_name,
        .table_name = owned_table,
        .root_page = row.root_page orelse 0,
        .sql = sql,
    }) catch return error.OutOfMemory;
}

/// Source `sqlite3InitCallback()`.
pub fn initializeSchemaRow(context: *InitContext, row: CatalogRow) bool {
    context.row_count += 1;
    if (context.malloc_failed) {
        reportCorruptSchema(context, row, null);
        return false;
    }
    const root = row.root_page orelse {
        reportCorruptSchema(context, row, "invalid rootpage");
        return false;
    };
    if (root > context.schema.maximum_page and context.schema.maximum_page != 0) {
        reportCorruptSchema(context, row, "invalid rootpage");
        return false;
    }
    if (row.sql) |sql| {
        if (sql.len < 2 or !std.ascii.eqlIgnoreCase(sql[0..2], "cr")) {
            reportCorruptSchema(context, row, null);
            return false;
        }
    } else if (!std.ascii.eqlIgnoreCase(row.object_type, "index")) {
        reportCorruptSchema(context, row, null);
        return false;
    }
    appendObject(context, row) catch |err| {
        context.result = err;
        if (err == error.OutOfMemory) context.malloc_failed = true;
        return false;
    };
    return true;
}

/// Source `sqlite3InitOne()`.
pub fn initializeOneSchema(schema: *Schema, metadata: Metadata, rows: []const CatalogRow, main_encoding: ?u8) Error!void {
    schema.clear();
    schema.maximum_page = metadata.maximum_page;
    schema.schema_cookie = metadata.schema_cookie;
    schema.file_format = if (metadata.file_format == 0) 1 else metadata.file_format;
    if (schema.file_format > 4) return error.UnsupportedFormat;
    if (main_encoding) |encoding| {
        if (metadata.encoding != 0 and metadata.encoding != encoding) return error.EncodingMismatch;
        schema.encoding = encoding;
    } else {
        schema.encoding = if (metadata.encoding == 0) 1 else metadata.encoding;
    }
    schema.cache_size = if (metadata.cache_size == 0) -2000 else @intCast(@abs(metadata.cache_size));
    var context = InitContext{ .allocator = schema.allocator, .schema = schema };
    defer context.deinit();
    for (rows) |row| {
        if (!initializeSchemaRow(&context, row)) return context.result;
    }
    schema.loaded = true;
}

/// Source `sqlite3Init()`.
pub fn initializeSchemas(schemas: []const *Schema, metadata: []const Metadata, rows: []const []const CatalogRow) Error!void {
    if (schemas.len == 0 or schemas.len != metadata.len or schemas.len != rows.len) return error.Corrupt;
    if (!schemas[0].loaded) try initializeOneSchema(schemas[0], metadata[0], rows[0], null);
    const encoding = schemas[0].encoding;
    var index = schemas.len;
    while (index > 1) {
        index -= 1;
        if (!schemas[index].loaded) try initializeOneSchema(schemas[index], metadata[index], rows[index], encoding);
    }
    if (schemas.len > 1 and !schemas[1].loaded) try initializeOneSchema(schemas[1], metadata[1], rows[1], encoding);
}

/// Source `sqlite3ReadSchema()`.
pub fn readSchema(schemas: []const *Schema, metadata: []const Metadata, rows: []const []const CatalogRow, initialization_busy: bool, known_ok: *bool) Error!void {
    if (initialization_busy) return;
    initializeSchemas(schemas, metadata, rows) catch |err| {
        known_ok.* = false;
        return err;
    };
    known_ok.* = true;
}

/// Source `schemaIsValid()`.
pub fn validateSchemaCookies(schemas: []const *Schema, disk_cookies: []const u32) bool {
    if (schemas.len != disk_cookies.len) return false;
    var valid = true;
    for (schemas, disk_cookies) |schema, cookie| {
        if (!schema.loaded or schema.schema_cookie == cookie) continue;
        schema.clear();
        valid = false;
    }
    return valid;
}

pub const Cleanup = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,
};

pub const ParseObject = struct {
    allocator: std.mem.Allocator,
    cleanups: std.ArrayList(Cleanup) = .empty,
    labels: ?[]i32 = null,
    constant_expressions: ?[]u8 = null,
    lookaside_disable_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ParseObject {
        return .{ .allocator = allocator };
    }
};

/// Source `sqlite3ParseObjectReset()`.
pub fn resetParseObject(parse: *ParseObject, connection_lookaside_disable: *usize) void {
    while (parse.cleanups.pop()) |cleanup| cleanup.callback(cleanup.context);
    parse.cleanups.deinit(parse.allocator);
    parse.cleanups = .empty;
    if (parse.labels) |labels| parse.allocator.free(labels);
    if (parse.constant_expressions) |expressions| parse.allocator.free(expressions);
    parse.labels = null;
    parse.constant_expressions = null;
    std.debug.assert(connection_lookaside_disable.* >= parse.lookaside_disable_count);
    connection_lookaside_disable.* -= parse.lookaside_disable_count;
    parse.lookaside_disable_count = 0;
}
