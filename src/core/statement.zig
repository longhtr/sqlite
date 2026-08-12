//! Transitional C-shaped statement lifecycle over the bounded native VDBE.
//! SQL-to-program preparation still uses the handwritten frontend. These APIs
//! are migration paths, not the final Zig-native public surface.

const std = @import("std");
pub const vdbe = @import("vdbe.zig");
const ResultCode = @import("result_code.zig").ResultCode;
pub const public_api = @import("public_api.zig");
const tokenizer = @import("tokenizer.zig");
const vdbe_mem = @import("internal/vdbe_mem.zig");
const collation = @import("internal/collation.zig");
const vdbe_types = vdbe_mem.types;
pub const sqlite3_stmt = opaque {};
pub const sqlite3_value = opaque {};
pub const sqlite3_context = opaque {};

pub const Destructor = ?*const anyopaque;
const DestructorFunction = *const fn (?*anyopaque) callconv(.c) void;
pub const ColumnMetadata = struct { name: [:0]const u8 };
pub const ParameterMetadata = struct { name: ?[:0]const u8 = null };
pub const OwnerDestructor = *const fn (std.mem.Allocator, *anyopaque) void;

const Binding = struct {
    value: vdbe_types.Mem = std.mem.zeroes(vdbe_types.Mem),

    fn init(self: *Binding) void {
        vdbe_mem.init(&self.value, null, vdbe_types.mem_flag.null_);
    }

    fn clear(self: *Binding) void {
        vdbe_mem.release(&self.value);
        vdbe_mem.setNull(&self.value);
    }
};

pub const FunctionDefinition = struct {
    name: [:0]u8,
    argument_count: c_int,
    encoding: c_int = 1,
    callback: ?*const fn (?*sqlite3_context, c_int, [*]?*sqlite3_value) callconv(.c) void = null,
    step_callback: ?*const fn (?*sqlite3_context, c_int, [*]?*sqlite3_value) callconv(.c) void = null,
    final_callback: ?*const fn (?*sqlite3_context) callconv(.c) void = null,
    value_callback: ?*const fn (?*sqlite3_context) callconv(.c) void = null,
    inverse_callback: ?*const fn (?*sqlite3_context, c_int, [*]?*sqlite3_value) callconv(.c) void = null,
    user_data: ?*anyopaque,
    database: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

const NativeFunction = struct {
    func: vdbe_types.FuncDef,
    definition: *FunctionDefinition,
};

const ColumnCache = struct {
    name16: ?[:0]u16 = null,

    fn clear(self: *ColumnCache, allocator: std.mem.Allocator) void {
        if (self.name16) |units| allocator.free(units);
        self.* = .{};
    }
};

pub const Statement = struct {
    allocator: std.mem.Allocator,
    vm: vdbe.Vm,
    bindings: []Binding,
    parameters: []const ParameterMetadata,
    columns: []const ColumnMetadata,
    caches: []ColumnCache,
    last_result: ResultCode = .ok,
    started: bool = false,
    in_api: bool = false,
    owned_context: ?*anyopaque = null,
    owned_destructor: ?OwnerDestructor = null,
    readonly: bool = true,
    finalize_context: ?*anyopaque = null,
    finalize_callback: ?*const fn (?*anyopaque, *Statement) void = null,
    connection_previous: ?*Statement = null,
    connection_next: ?*Statement = null,
    interrupt_flag: ?*const bool = null,
    result_mask: ?*const c_int = null,
    sql_copy: ?[:0]u8 = null,
    event_context: ?*anyopaque = null,
    event_callback: ?*const fn (?*anyopaque, *Statement, c_uint) void = null,
    profile_emitted: bool = false,
    profile_start_ms: i64 = 0,
    variable_mask: u64 = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        program: *const vdbe.Program,
        parameters: []const ParameterMetadata,
        columns: []const ColumnMetadata,
    ) !*Statement {
        return createWithDatabase(allocator, program, parameters, columns, null);
    }

    pub fn createWithDatabase(
        allocator: std.mem.Allocator,
        program: *const vdbe.Program,
        parameters: []const ParameterMetadata,
        columns: []const ColumnMetadata,
        database: ?*vdbe.btree.Database,
    ) !*Statement {
        if (parameters.len > program.register_count or columns.len > program.register_count) return error.InvalidProgram;
        const statement = try allocator.create(Statement);
        errdefer allocator.destroy(statement);
        const bindings = try allocator.alloc(Binding, parameters.len);
        errdefer allocator.free(bindings);
        for (bindings) |*binding| {
            binding.init();
        }
        const caches = try allocator.alloc(ColumnCache, columns.len);
        errdefer allocator.free(caches);
        @memset(caches, .{});
        const vm = try vdbe.Vm.init(allocator, program, database);
        statement.* = .{
            .allocator = allocator,
            .vm = vm,
            .bindings = bindings,
            .parameters = parameters,
            .columns = columns,
            .caches = caches,
        };
        return statement;
    }

    pub fn adoptOwner(self: *Statement, context: *anyopaque, destructor: OwnerDestructor) void {
        std.debug.assert(self.owned_context == null);
        self.owned_context = context;
        self.owned_destructor = destructor;
    }

    pub fn markWritable(self: *Statement) void {
        self.readonly = false;
    }

    pub fn setSql(self: *Statement, sql: []const u8) !void {
        if (self.sql_copy) |old| self.allocator.free(old);
        self.sql_copy = try self.allocator.dupeZ(u8, sql);
    }

    pub fn setEventCallback(self: *Statement, context: ?*anyopaque, callback: *const fn (?*anyopaque, *Statement, c_uint) void) void {
        self.event_context = context;
        self.event_callback = callback;
    }

    pub fn onFinalize(self: *Statement, context: ?*anyopaque, callback: *const fn (?*anyopaque, *Statement) void, interrupt_flag: ?*const bool) void {
        self.finalize_context = context;
        self.finalize_callback = callback;
        self.interrupt_flag = interrupt_flag;
    }

    pub fn setResultMask(self: *Statement, result_mask: *const c_int) void {
        self.result_mask = result_mask;
    }

    fn resultMask(self: *const Statement) c_int {
        return if (self.result_mask) |mask| mask.* else 0xff;
    }

    fn clearCaches(self: *Statement) void {
        for (self.caches) |*cache| cache.clear(self.allocator);
    }

    fn destroy(self: *Statement) ResultCode {
        const result = if (self.last_result == .row or self.last_result == .done) ResultCode.ok else self.last_result;
        self.clearCaches();
        self.allocator.free(self.caches);
        for (self.bindings) |*binding| binding.clear();
        self.allocator.free(self.bindings);
        self.vm.deinit();
        if (self.owned_context) |context| self.owned_destructor.?(self.allocator, context);
        if (self.finalize_callback) |callback| callback(self.finalize_context, self);
        if (self.sql_copy) |sql| self.allocator.free(sql);
        const allocator = self.allocator;
        allocator.destroy(self);
        return result;
    }

    fn applyBindings(self: *Statement) ResultCode {
        for (self.bindings, 1..) |*binding, register_index| {
            const result = self.vm.assignRegister(register_index, &binding.value);
            if (result != .ok) return result;
        }
        return .ok;
    }

    fn step(self: *Statement) ResultCode {
        if (self.in_api) return .misuse;
        self.in_api = true;
        defer self.in_api = false;
        self.clearCaches();
        if (self.interrupt_flag) |flag| if (flag.*) {
            self.last_result = .interrupt;
            return .interrupt;
        };
        if (self.last_result == .no_memory) return .no_memory;
        if (!self.started) {
            if (self.event_callback) |callback| callback(self.event_context, self, 1);
            const result = self.applyBindings();
            if (result != .ok) {
                self.last_result = result;
                return result;
            }
            self.started = true;
        }
        const outcome = self.vm.step();
        self.last_result = outcome.result;
        if (outcome.result == .row) {
            if (self.event_callback) |callback| callback(self.event_context, self, 4);
        }
        if (outcome.result == .done and !self.profile_emitted) {
            self.profile_emitted = true;
            if (self.event_callback) |callback| callback(self.event_context, self, 2);
        }
        return outcome.result;
    }

    fn reset(self: *Statement) ResultCode {
        if (self.in_api) return .misuse;
        self.clearCaches();
        const previous = if (self.last_result == .row or self.last_result == .done) ResultCode.ok else self.last_result;
        self.vm.reset();
        self.started = false;
        self.profile_emitted = false;
        self.last_result = .ok;
        return previous;
    }

    /// Source `sqlite3VdbeSetVarmask()`: remember bound parameters used by
    /// variable-sensitive planning, saturating indices above the mask width.
    fn setVariableMask(self: *Statement, index: usize) void {
        if (index == 0) return;
        if (index > 64) {
            self.variable_mask = std.math.maxInt(u64);
        } else {
            self.variable_mask |= @as(u64, 1) << @intCast(index - 1);
        }
    }

    fn bindMem(self: *Statement, index_value: c_int, value: *vdbe_types.Mem) ResultCode {
        if (self.in_api or self.started) {
            vdbe_mem.release(value);
            return .misuse;
        }
        self.in_api = true;
        defer self.in_api = false;
        if (index_value <= 0 or @as(usize, @intCast(index_value)) > self.bindings.len) {
            vdbe_mem.release(value);
            return .range;
        }
        const index: usize = @intCast(index_value - 1);
        self.setVariableMask(index + 1);
        vdbe_mem.move(&self.bindings[index].value, value);
        self.bindings[index].value.flags |= vdbe_types.mem_flag.from_bind;
        return .ok;
    }

    fn currentColumn(self: *Statement, index_value: c_int) ?*const vdbe_types.Mem {
        if (self.vm.state != .row or index_value < 0) return null;
        const index: usize = @intCast(index_value);
        if (index >= self.columns.len or index >= self.vm.columnCount()) return null;
        return self.vm.column(index);
    }

    fn columnMem(self: *Statement, index_value: c_int) ?*vdbe_types.Mem {
        return @constCast(self.currentColumn(index_value) orelse return null);
    }

    fn text8(self: *Statement, index_value: c_int) ?[*:0]const u8 {
        const value = self.columnMem(index_value) orelse return null;
        return if (vdbe_mem.valueText(value, 1)) |text| @ptrCast(text) else null;
    }

    fn text16(self: *Statement, index_value: c_int) ?*const anyopaque {
        const value = self.columnMem(index_value) orelse return null;
        return if (vdbe_mem.valueText(value, 2)) |text| @ptrCast(text) else null;
    }
};

pub fn fromOpaque(pointer: ?*sqlite3_stmt) ?*Statement {
    return if (pointer) |value| @ptrCast(@alignCast(value)) else null;
}

const asStatement = fromOpaque;

pub fn toOpaque(statement: *Statement) *sqlite3_stmt {
    return @ptrCast(statement);
}

fn isTransient(destructor: Destructor) bool {
    const pointer = destructor orelse return false;
    return @intFromPtr(pointer) == std.math.maxInt(usize);
}

fn isCustomDestructor(destructor: Destructor) bool {
    return destructor != null and !isTransient(destructor);
}

fn invokeRejectedDestructor(destructor: Destructor, argument: ?*anyopaque) void {
    if (isCustomDestructor(destructor)) {
        const function: DestructorFunction = @ptrCast(@alignCast(destructor.?));
        function(argument);
    }
}

fn cLength(pointer: [*:0]const u8) usize {
    return std.mem.len(pointer);
}

fn bindBytes(
    pointer: ?*sqlite3_stmt,
    index: c_int,
    input_pointer: ?*const anyopaque,
    length_value: i64,
    destructor: Destructor,
    text: bool,
    negative_text_length: bool,
) c_int {
    const statement = asStatement(pointer) orelse {
        if (input_pointer != null) invokeRejectedDestructor(destructor, @constCast(input_pointer));
        return ResultCode.misuse.toC();
    };
    var value = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&value, null, vdbe_types.mem_flag.null_);
    if (input_pointer == null) return statement.bindMem(index, &value).toC();
    var length = length_value;
    if (length < 0) {
        if (!negative_text_length) {
            invokeRejectedDestructor(destructor, @constCast(input_pointer));
            return ResultCode.misuse.toC();
        }
        length = @intCast(cLength(@ptrCast(input_pointer.?)));
    }
    if (length > std.math.maxInt(c_int)) {
        invokeRejectedDestructor(destructor, @constCast(input_pointer));
        return ResultCode.too_big.toC();
    }
    const bytes: [*]const u8 = @ptrCast(input_pointer.?);
    const rc = vdbe_mem.setStr(&value, bytes, length, if (text) 1 else 0, ownership(destructor));
    if (rc != 0) return ResultCode.fromC(rc).toC();
    return statement.bindMem(index, &value).toC();
}

fn asValue(pointer: ?*const sqlite3_value) ?*vdbe_types.Mem {
    return if (pointer) |value| @ptrCast(@alignCast(@constCast(value))) else null;
}

pub export fn sqlite3_value_type(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return vdbe_mem.valueType(asValue(pointer) orelse return 5);
}
pub export fn sqlite3_value_int64(pointer: ?*const sqlite3_value) callconv(.c) i64 {
    return vdbe_mem.valueInt64(asValue(pointer) orelse return 0);
}
pub export fn sqlite3_value_int(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return vdbe_mem.valueInt(asValue(pointer) orelse return 0);
}
pub export fn sqlite3_value_double(pointer: ?*const sqlite3_value) callconv(.c) f64 {
    return vdbe_mem.valueDouble(asValue(pointer) orelse return 0);
}
pub export fn sqlite3_value_text(pointer: ?*const sqlite3_value) callconv(.c) ?[*:0]const u8 {
    return if (vdbe_mem.valueText(asValue(pointer), 1)) |text| @ptrCast(text) else null;
}
pub export fn sqlite3_value_text16(pointer: ?*const sqlite3_value) callconv(.c) ?*const anyopaque {
    return if (vdbe_mem.valueText(asValue(pointer), 2)) |text| @ptrCast(text) else null;
}
pub export fn sqlite3_value_text16le(pointer: ?*const sqlite3_value) callconv(.c) ?*const anyopaque {
    return sqlite3_value_text16(pointer);
}
pub export fn sqlite3_value_text16be(pointer: ?*const sqlite3_value) callconv(.c) ?*const anyopaque {
    return if (vdbe_mem.valueText(asValue(pointer), 3)) |text| @ptrCast(text) else null;
}
pub export fn sqlite3_value_pointer(pointer: ?*const sqlite3_value, type_pointer: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    return vdbe_mem.valuePointer(asValue(pointer) orelse return null, type_pointer);
}
pub export fn sqlite3_value_blob(pointer: ?*const sqlite3_value) callconv(.c) ?*const anyopaque {
    return if (vdbe_mem.valueBlob(asValue(pointer) orelse return null)) |blob| @ptrCast(blob) else null;
}
pub export fn sqlite3_value_bytes(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return vdbe_mem.valueBytes(asValue(pointer) orelse return 0, 1);
}
pub export fn sqlite3_value_bytes16(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return vdbe_mem.valueBytes(asValue(pointer) orelse return 0, 2);
}
pub export fn sqlite3_value_numeric_type(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return vdbe_mem.valueNumericType(asValue(pointer) orelse return 5);
}
pub export fn sqlite3_value_nochange(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return @intFromBool(vdbe_mem.valueNoChange(asValue(pointer) orelse return 0));
}
pub export fn sqlite3_value_frombind(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return @intFromBool(vdbe_mem.valueFromBind(asValue(pointer) orelse return 0));
}
pub export fn sqlite3_value_encoding(pointer: ?*const sqlite3_value) callconv(.c) c_int {
    return vdbe_mem.valueEncoding(asValue(pointer) orelse return 0);
}
pub export fn sqlite3_value_subtype(pointer: ?*const sqlite3_value) callconv(.c) c_uint {
    return vdbe_mem.valueSubtype(asValue(pointer) orelse return 0);
}
pub export fn sqlite3_value_dup(pointer: ?*const sqlite3_value) callconv(.c) ?*sqlite3_value {
    return if (vdbe_mem.valueDuplicate(asValue(pointer))) |value| @ptrCast(value) else null;
}
pub export fn sqlite3_value_free(pointer: ?*sqlite3_value) callconv(.c) void {
    vdbe_mem.valueFree(if (pointer) |value| @ptrCast(@alignCast(value)) else null);
}

fn ownership(destructor: Destructor) vdbe_mem.StringOwnership {
    if (destructor == null) return .static;
    if (isTransient(destructor)) return .transient;
    const callback: DestructorFunction = @ptrCast(@alignCast(destructor.?));
    return .{ .custom = callback };
}

fn asContext(pointer: ?*sqlite3_context) ?*vdbe_types.Context {
    return if (pointer) |value| @ptrCast(@alignCast(value)) else null;
}

fn definitionFromContext(context: *vdbe_types.Context) *FunctionDefinition {
    const native: *NativeFunction = @fieldParentPtr("func", context.pFunc.?);
    return native.definition;
}

fn releaseInvocation(machine: *vdbe_types.Vdbe, accumulator: *vdbe_types.Mem, output: *vdbe_types.Mem) void {
    vdbe_mem.deleteAuxData(machine, -1, 0);
    accumulator.flags &= ~vdbe_types.mem_flag.aggregate;
    vdbe_mem.release(accumulator);
    vdbe_mem.release(output);
}

fn attachInvocationCollation(machine: *vdbe_types.Vdbe, operation: *vdbe_types.VdbeOp, sequence: *vdbe_types.CollSeq) void {
    sequence.* = std.mem.zeroes(vdbe_types.CollSeq);
    sequence.enc = 1;
    sequence.xCmp = collation.binary;
    operation.* = std.mem.zeroes(vdbe_types.VdbeOp);
    operation.p4.pColl = sequence;
    machine.aOp = @ptrCast(operation);
}

pub fn invokeScalar(context: ?*anyopaque, arguments: []vdbe_types.Mem, output: *vdbe_types.Mem, allocator: std.mem.Allocator) ResultCode {
    const definition: *FunctionDefinition = @ptrCast(@alignCast(context orelse return .misuse));
    const argument_pointers = allocator.alloc(?*vdbe_types.Mem, arguments.len) catch return .no_memory;
    defer allocator.free(argument_pointers);
    for (arguments, argument_pointers) |*mem, *pointer| {
        pointer.* = mem;
    }

    var result_mem = std.mem.zeroes(vdbe_types.Mem);
    var aggregate_mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&result_mem, null, vdbe_types.mem_flag.null_);
    vdbe_mem.init(&aggregate_mem, null, vdbe_types.mem_flag.null_);
    var machine = std.mem.zeroes(vdbe_types.Vdbe);
    var operation = std.mem.zeroes(vdbe_types.VdbeOp);
    var sequence = std.mem.zeroes(vdbe_types.CollSeq);
    attachInvocationCollation(&machine, &operation, &sequence);
    var native = NativeFunction{ .func = std.mem.zeroes(vdbe_types.FuncDef), .definition = definition };
    native.func.nArg = @intCast(definition.argument_count);
    native.func.pUserData = definition.user_data;
    native.func.zName = definition.name.ptr;
    var function_context = vdbe_types.Context{
        .pOut = &result_mem,
        .pFunc = &native.func,
        .pMem = &aggregate_mem,
        .pVdbe = &machine,
        .iOp = 1,
        .isError = 0,
        .enc = 1,
        .skipFlag = 0,
        .argc = @intCast(arguments.len),
        .argv = .{},
    };
    defer releaseInvocation(&machine, &aggregate_mem, &result_mem);
    const opaque_context: ?*sqlite3_context = @ptrCast(&function_context);
    const opaque_arguments: [*]?*sqlite3_value = @ptrCast(argument_pointers.ptr);
    if (definition.callback) |callback| {
        callback(opaque_context, @intCast(arguments.len), opaque_arguments);
    } else if (definition.step_callback) |step_callback| {
        aggregate_mem.n = 1;
        step_callback(opaque_context, @intCast(arguments.len), opaque_arguments);
        if (definition.value_callback) |value_callback| {
            value_callback(opaque_context);
            var saved = std.mem.zeroes(vdbe_types.Mem);
            vdbe_mem.init(&saved, null, vdbe_types.mem_flag.null_);
            if (vdbe_mem.copy(&saved, &result_mem) != 0) return .no_memory;
            defer vdbe_mem.release(&saved);
            if (definition.final_callback) |final_callback| final_callback(opaque_context);
            vdbe_mem.move(&result_mem, &saved);
        } else if (definition.final_callback) |final_callback| final_callback(opaque_context);
    } else return .misuse;
    if (function_context.isError > 0) return ResultCode.fromC(function_context.isError);
    vdbe_mem.move(output, &result_mem);
    return .ok;
}

/// Source `createAggContext()`: initialize one aggregate invocation context
/// around a persistent accumulator register and zeroed transient output.
pub fn invokeAggregateStep(context: ?*anyopaque, arguments: []vdbe_types.Mem, accumulator: *vdbe_types.Mem, allocator: std.mem.Allocator) ResultCode {
    const definition: *FunctionDefinition = @ptrCast(@alignCast(context orelse return .misuse));
    const step_callback = definition.step_callback orelse return .misuse;
    const argument_pointers = allocator.alloc(?*vdbe_types.Mem, arguments.len) catch return .no_memory;
    defer allocator.free(argument_pointers);
    for (arguments, argument_pointers) |*value, *pointer| {
        pointer.* = value;
    }
    var result_mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&result_mem, null, vdbe_types.mem_flag.null_);
    defer vdbe_mem.release(&result_mem);
    var machine = std.mem.zeroes(vdbe_types.Vdbe);
    var operation = std.mem.zeroes(vdbe_types.VdbeOp);
    var sequence = std.mem.zeroes(vdbe_types.CollSeq);
    attachInvocationCollation(&machine, &operation, &sequence);
    var native = NativeFunction{ .func = std.mem.zeroes(vdbe_types.FuncDef), .definition = definition };
    native.func.nArg = @intCast(definition.argument_count);
    native.func.pUserData = definition.user_data;
    native.func.zName = definition.name.ptr;
    var function_context = vdbe_types.Context{ .pOut = &result_mem, .pFunc = &native.func, .pMem = accumulator, .pVdbe = &machine, .iOp = 1, .isError = 0, .enc = 1, .skipFlag = 0, .argc = @intCast(arguments.len), .argv = .{} };
    accumulator.n += 1;
    step_callback(@ptrCast(&function_context), @intCast(arguments.len), @ptrCast(argument_pointers.ptr));
    vdbe_mem.deleteAuxData(&machine, -1, 0);
    return if (function_context.isError > 0) ResultCode.fromC(function_context.isError) else .ok;
}

/// Source `sqlite3VdbeMemFinalize()`: invoke an aggregate finalizer, transfer
/// its result, and release the persistent aggregate context exactly once.
pub fn finalizeAggregate(context: ?*anyopaque, accumulator: *vdbe_types.Mem, output: *vdbe_types.Mem, _: std.mem.Allocator) ResultCode {
    const definition: *FunctionDefinition = @ptrCast(@alignCast(context orelse return .misuse));
    const final_callback = definition.final_callback orelse return .misuse;
    var result_mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&result_mem, null, vdbe_types.mem_flag.null_);
    var machine = std.mem.zeroes(vdbe_types.Vdbe);
    var native = NativeFunction{ .func = std.mem.zeroes(vdbe_types.FuncDef), .definition = definition };
    native.func.nArg = @intCast(definition.argument_count);
    native.func.pUserData = definition.user_data;
    native.func.zName = definition.name.ptr;
    var function_context = vdbe_types.Context{ .pOut = &result_mem, .pFunc = &native.func, .pMem = accumulator, .pVdbe = &machine, .iOp = 0, .isError = 0, .enc = 1, .skipFlag = 0, .argc = 0, .argv = .{} };
    final_callback(@ptrCast(&function_context));
    vdbe_mem.deleteAuxData(&machine, -1, 0);
    accumulator.flags &= ~vdbe_types.mem_flag.aggregate;
    vdbe_mem.release(accumulator);
    vdbe_mem.init(accumulator, null, vdbe_types.mem_flag.null_);
    if (function_context.isError > 0) {
        vdbe_mem.release(&result_mem);
        return ResultCode.fromC(function_context.isError);
    }
    vdbe_mem.move(output, &result_mem);
    return .ok;
}

/// Source `sqlite3VdbeMemAggValue()`: invoke a window aggregate xValue
/// callback without consuming or releasing its accumulator state.
pub fn valueAggregate(context: ?*anyopaque, accumulator: *vdbe_types.Mem, output: *vdbe_types.Mem, _: std.mem.Allocator) ResultCode {
    const definition: *FunctionDefinition = @ptrCast(@alignCast(context orelse return .misuse));
    const value_callback = definition.value_callback orelse return .misuse;
    var result_mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&result_mem, null, vdbe_types.mem_flag.null_);
    var machine = std.mem.zeroes(vdbe_types.Vdbe);
    var native = NativeFunction{ .func = std.mem.zeroes(vdbe_types.FuncDef), .definition = definition };
    native.func.nArg = @intCast(definition.argument_count);
    native.func.pUserData = definition.user_data;
    native.func.zName = definition.name.ptr;
    var function_context = vdbe_types.Context{ .pOut = &result_mem, .pFunc = &native.func, .pMem = accumulator, .pVdbe = &machine, .iOp = 0, .isError = 0, .enc = 1, .skipFlag = 0, .argc = 0, .argv = .{} };
    value_callback(@ptrCast(&function_context));
    vdbe_mem.deleteAuxData(&machine, -1, 0);
    if (function_context.isError > 0) {
        vdbe_mem.release(&result_mem);
        return ResultCode.fromC(function_context.isError);
    }
    vdbe_mem.move(output, &result_mem);
    return .ok;
}

pub fn invokeVirtualColumn(callback: *const fn (?*anyopaque, ?*sqlite3_context, c_int) callconv(.c) c_int, cursor: ?*anyopaque, index: usize, output: *vdbe_types.Mem) ResultCode {
    var definition: FunctionDefinition = .{ .name = @constCast("virtual-column"), .argument_count = 0, .user_data = null, .database = null };
    var result_mem = std.mem.zeroes(vdbe_types.Mem);
    var aggregate_mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&result_mem, null, vdbe_types.mem_flag.null_);
    vdbe_mem.init(&aggregate_mem, null, vdbe_types.mem_flag.null_);
    var machine = std.mem.zeroes(vdbe_types.Vdbe);
    var native = NativeFunction{ .func = std.mem.zeroes(vdbe_types.FuncDef), .definition = &definition };
    native.func.pUserData = cursor;
    native.func.zName = definition.name.ptr;
    var function_context = vdbe_types.Context{
        .pOut = &result_mem,
        .pFunc = &native.func,
        .pMem = &aggregate_mem,
        .pVdbe = &machine,
        .iOp = 0,
        .isError = 0,
        .enc = 1,
        .skipFlag = 0,
        .argc = 0,
        .argv = .{},
    };
    defer releaseInvocation(&machine, &aggregate_mem, &result_mem);
    const rc = ResultCode.fromC(callback(cursor, @ptrCast(&function_context), @intCast(index)));
    if (rc != .ok) return rc;
    if (function_context.isError > 0) return ResultCode.fromC(function_context.isError);
    vdbe_mem.move(output, &result_mem);
    return .ok;
}

pub export fn sqlite3_user_data(pointer: ?*sqlite3_context) callconv(.c) ?*anyopaque {
    return vdbe_mem.userData(asContext(pointer) orelse return null);
}
pub export fn sqlite3_context_db_handle(pointer: ?*sqlite3_context) callconv(.c) ?*anyopaque {
    return definitionFromContext(asContext(pointer) orelse return null).database;
}
pub export fn sqlite3_aggregate_count(pointer: ?*sqlite3_context) callconv(.c) c_int {
    return vdbe_mem.aggregateCount(asContext(pointer) orelse return 0);
}
pub export fn sqlite3_get_auxdata(pointer: ?*sqlite3_context, index: c_int) callconv(.c) ?*anyopaque {
    return vdbe_mem.getAuxData(asContext(pointer) orelse return null, index);
}
pub export fn sqlite3_set_auxdata(pointer: ?*sqlite3_context, index: c_int, value: ?*anyopaque, destructor: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) void {
    const context = asContext(pointer) orelse {
        if (destructor) |destroy| destroy(value);
        return;
    };
    if (index >= context.argc) {
        if (destructor) |destroy| destroy(value);
        return;
    }
    vdbe_mem.setAuxData(context, index, value, destructor);
}
pub export fn sqlite3_aggregate_context(pointer: ?*sqlite3_context, size: c_int) callconv(.c) ?*anyopaque {
    return vdbe_mem.aggregateContext(asContext(pointer) orelse return null, size);
}
pub export fn sqlite3_vtab_nochange(pointer: ?*sqlite3_context) callconv(.c) c_int {
    return @intFromBool(vdbe_mem.virtualTableNoChange(asContext(pointer) orelse return 0));
}

pub export fn sqlite3_result_pointer(pointer: ?*sqlite3_context, value: ?*anyopaque, type_pointer: ?[*:0]const u8, destructor: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) void {
    const context = asContext(pointer) orelse {
        if (destructor) |destroy| destroy(value);
        return;
    };
    vdbe_mem.resultPointer(context, value, type_pointer, destructor);
}
pub export fn sqlite3_result_null(pointer: ?*sqlite3_context) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultNull(context);
}
pub export fn sqlite3_result_int(pointer: ?*sqlite3_context, value: c_int) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultInt(context, value);
}
pub export fn sqlite3_result_int64(pointer: ?*sqlite3_context, value: i64) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultInt64(context, value);
}
pub export fn sqlite3_result_double(pointer: ?*sqlite3_context, value: f64) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultDouble(context, value);
}
pub export fn sqlite3_result_text(pointer: ?*sqlite3_context, input: ?[*:0]const u8, length: c_int, destructor: Destructor) callconv(.c) void {
    const context = asContext(pointer) orelse {
        if (input) |value| invokeRejectedDestructor(destructor, @ptrCast(@constCast(value)));
        return;
    };
    vdbe_mem.resultText(context, input, length, ownership(destructor));
}
pub export fn sqlite3_result_text16(pointer: ?*sqlite3_context, input: ?*const anyopaque, length: c_int, destructor: Destructor) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultText16(context, if (input) |value| @ptrCast(value) else null, length, 2, ownership(destructor));
}
pub export fn sqlite3_result_text16le(pointer: ?*sqlite3_context, input: ?*const anyopaque, length: c_int, destructor: Destructor) callconv(.c) void {
    sqlite3_result_text16(pointer, input, length, destructor);
}
pub export fn sqlite3_result_text16be(pointer: ?*sqlite3_context, input: ?*const anyopaque, length: c_int, destructor: Destructor) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultText16(context, if (input) |value| @ptrCast(value) else null, length, 3, ownership(destructor));
}

pub export fn sqlite3_result_text64(pointer: ?*sqlite3_context, input: ?[*:0]const u8, length: u64, destructor: Destructor, encoding: u8) callconv(.c) void {
    const context = asContext(pointer) orelse {
        if (input) |value| invokeRejectedDestructor(destructor, @ptrCast(@constCast(value)));
        return;
    };
    vdbe_mem.resultText64(context, input, length, encoding, ownership(destructor));
}
pub export fn sqlite3_result_blob(pointer: ?*sqlite3_context, input: ?*const anyopaque, length: c_int, destructor: Destructor) callconv(.c) void {
    const context = asContext(pointer) orelse {
        if (input != null) invokeRejectedDestructor(destructor, @constCast(input));
        return;
    };
    if (length < 0) {
        if (input != null) invokeRejectedDestructor(destructor, @constCast(input));
        vdbe_mem.resultErrorTooBig(context);
        return;
    }
    vdbe_mem.resultBlob(context, if (input) |value| @ptrCast(value) else null, length, ownership(destructor));
}
pub export fn sqlite3_result_blob64(pointer: ?*sqlite3_context, input: ?*const anyopaque, length: u64, destructor: Destructor) callconv(.c) c_int {
    const context = asContext(pointer) orelse {
        if (input != null) invokeRejectedDestructor(destructor, @constCast(input));
        return ResultCode.misuse.toC();
    };
    vdbe_mem.resultBlob64(context, if (input) |value| @ptrCast(value) else null, length, ownership(destructor));
    return if (context.isError > 0) context.isError else ResultCode.ok.toC();
}
pub export fn sqlite3_result_zeroblob(pointer: ?*sqlite3_context, length: c_int) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultZeroBlob(context, length);
}
pub export fn sqlite3_result_zeroblob64(pointer: ?*sqlite3_context, length: u64) callconv(.c) c_int {
    return vdbe_mem.resultZeroBlob64(asContext(pointer) orelse return ResultCode.misuse.toC(), length);
}
pub export fn sqlite3_result_value(pointer: ?*sqlite3_context, value: ?*const sqlite3_value) callconv(.c) void {
    const context = asContext(pointer) orelse return;
    if (asValue(value)) |mem| vdbe_mem.resultValue(context, mem) else vdbe_mem.resultNull(context);
}
pub export fn sqlite3_result_error_code(pointer: ?*sqlite3_context, code: c_int) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultErrorCode(context, code);
}
pub export fn sqlite3_result_error_nomem(pointer: ?*sqlite3_context) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultErrorNoMem(context);
}
pub export fn sqlite3_result_error_toobig(pointer: ?*sqlite3_context) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultErrorTooBig(context);
}
pub export fn sqlite3_result_error16(pointer: ?*sqlite3_context, input: ?*const anyopaque, length: c_int) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultError16(context, if (input) |value| @ptrCast(value) else null, length);
}
pub export fn sqlite3_result_error(pointer: ?*sqlite3_context, input: ?[*:0]const u8, length: c_int) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultError(context, input, length);
}
pub export fn sqlite3_result_subtype(pointer: ?*sqlite3_context, subtype: c_uint) callconv(.c) void {
    if (asContext(pointer)) |context| vdbe_mem.resultSubtype(context, subtype);
}

pub export fn sqlite3_step(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    return statement.step().toC() & statement.resultMask();
}

pub export fn sqlite3_reset(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    return statement.reset().toC() & statement.resultMask();
}

pub export fn sqlite3_finalize(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.ok.toC();
    if (statement.in_api) return ResultCode.misuse.toC();
    statement.in_api = true;
    const result_mask = statement.resultMask();
    return statement.destroy().toC() & result_mask;
}

pub export fn sqlite3_clear_bindings(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    if (statement.started or statement.in_api) return ResultCode.misuse.toC();
    statement.in_api = true;
    defer statement.in_api = false;
    for (statement.bindings) |*binding| binding.clear();
    return ResultCode.ok.toC();
}

pub export fn sqlite3_bind_parameter_count(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    return @intCast(statement.bindings.len);
}

pub export fn sqlite3_bind_parameter_name(pointer: ?*sqlite3_stmt, index_value: c_int) callconv(.c) ?[*:0]const u8 {
    const statement = asStatement(pointer) orelse return null;
    if (index_value <= 0 or @as(usize, @intCast(index_value)) > statement.parameters.len) return null;
    return if (statement.parameters[@intCast(index_value - 1)].name) |name| name.ptr else null;
}

pub export fn sqlite3_bind_parameter_index(pointer: ?*sqlite3_stmt, name_pointer: ?[*:0]const u8) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    const name = name_pointer orelse return 0;
    const bytes = std.mem.span(name);
    for (statement.parameters, 1..) |parameter, index| {
        if (parameter.name) |candidate| if (std.mem.eql(u8, candidate, bytes)) return @intCast(index);
    }
    return 0;
}

pub export fn sqlite3_bind_pointer(pointer: ?*sqlite3_stmt, index: c_int, value: ?*anyopaque, type_pointer: ?[*:0]const u8, destructor: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int {
    const prepared = asStatement(pointer) orelse {
        if (destructor) |destroy| destroy(value);
        return ResultCode.misuse.toC();
    };
    if (type_pointer == null) {
        if (destructor) |destroy| destroy(value);
        return ResultCode.misuse.toC();
    }
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    vdbe_mem.setPointer(&mem, value, type_pointer, destructor);
    return prepared.bindMem(index, &mem).toC();
}

pub export fn sqlite3_bind_value(pointer: ?*sqlite3_stmt, index: c_int, value_pointer: ?*const sqlite3_value) callconv(.c) c_int {
    const value = asValue(value_pointer) orelse return sqlite3_bind_null(pointer, index);
    return switch (vdbe_mem.valueType(value)) {
        1 => sqlite3_bind_int64(pointer, index, value.u.i),
        2 => sqlite3_bind_double(pointer, index, if (value.flags & vdbe_types.mem_flag.real != 0) value.u.r else @floatFromInt(value.u.i)),
        3 => bindBytes(pointer, index, if (value.z) |text| @ptrCast(text) else null, value.n, @ptrFromInt(std.math.maxInt(usize)), true, false),
        4 => if (value.flags & vdbe_types.mem_flag.zero != 0 and value.n == 0)
            sqlite3_bind_zeroblob(pointer, index, value.u.nZero)
        else
            bindBytes(pointer, index, if (value.z) |blob| @ptrCast(blob) else null, value.n, @ptrFromInt(std.math.maxInt(usize)), false, false),
        else => sqlite3_bind_null(pointer, index),
    };
}

pub export fn sqlite3_bind_null(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    return statement.bindMem(index, &mem).toC();
}

pub export fn sqlite3_bind_int(pointer: ?*sqlite3_stmt, index: c_int, value: c_int) callconv(.c) c_int {
    return sqlite3_bind_int64(pointer, index, value);
}

pub export fn sqlite3_bind_int64(pointer: ?*sqlite3_stmt, index: c_int, value: i64) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    vdbe_mem.setInt64(&mem, value);
    return statement.bindMem(index, &mem).toC();
}

pub export fn sqlite3_bind_double(pointer: ?*sqlite3_stmt, index: c_int, value: f64) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    vdbe_mem.setDouble(&mem, value);
    return statement.bindMem(index, &mem).toC();
}

pub export fn sqlite3_bind_text(pointer: ?*sqlite3_stmt, index: c_int, input: ?[*:0]const u8, length: c_int, destructor: Destructor) callconv(.c) c_int {
    return bindBytes(pointer, index, if (input) |value| @ptrCast(value) else null, length, destructor, true, true);
}

pub export fn sqlite3_bind_blob(pointer: ?*sqlite3_stmt, index: c_int, input: ?*const anyopaque, length: c_int, destructor: Destructor) callconv(.c) c_int {
    return bindBytes(pointer, index, input, length, destructor, false, false);
}

pub export fn sqlite3_bind_blob64(pointer: ?*sqlite3_stmt, index: c_int, input: ?*const anyopaque, length: u64, destructor: Destructor) callconv(.c) c_int {
    if (length > std.math.maxInt(i64)) {
        if (input != null) invokeRejectedDestructor(destructor, @constCast(input));
        return ResultCode.too_big.toC();
    }
    return bindBytes(pointer, index, input, @intCast(length), destructor, false, false);
}

pub export fn sqlite3_bind_text64(pointer: ?*sqlite3_stmt, index: c_int, input: ?[*]const u8, length_argument: u64, destructor: Destructor, encoding_argument: u8) callconv(.c) c_int {
    const raw: ?*const anyopaque = if (input) |value| @ptrCast(value) else null;
    const statement = asStatement(pointer) orelse {
        if (raw != null) invokeRejectedDestructor(destructor, @constCast(raw));
        return ResultCode.misuse.toC();
    };
    var encoding = encoding_argument;
    if (encoding == 4) encoding = 2;
    if (encoding != 1 and encoding != 2 and encoding != 3 and encoding != 16) {
        if (raw != null) invokeRejectedDestructor(destructor, @constCast(raw));
        return ResultCode.misuse.toC();
    }
    var length = length_argument;
    if (encoding != 1 and encoding != 16) length &= ~@as(u64, 1);
    if (length > std.math.maxInt(c_int)) {
        if (raw != null) invokeRejectedDestructor(destructor, @constCast(raw));
        return ResultCode.too_big.toC();
    }
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    const rc = if (encoding == 16) blk: {
        const result = vdbe_mem.setStr(&mem, input, @intCast(length), 1, ownership(destructor));
        mem.flags |= vdbe_types.mem_flag.terminated;
        break :blk result;
    } else vdbe_mem.setStr(&mem, input, @intCast(length), encoding, ownership(destructor));
    if (rc != 0) return ResultCode.fromC(rc).toC();
    return statement.bindMem(index, &mem).toC();
}

pub export fn sqlite3_bind_text16(pointer: ?*sqlite3_stmt, index: c_int, input: ?*const anyopaque, length_value: c_int, destructor: Destructor) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse {
        if (input != null) invokeRejectedDestructor(destructor, @constCast(input));
        return ResultCode.misuse.toC();
    };
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    const bytes: ?[*]const u8 = if (input) |value| @ptrCast(value) else null;
    const rc = vdbe_mem.setStr(&mem, bytes, length_value, 2, ownership(destructor));
    if (rc != 0) return ResultCode.fromC(rc).toC();
    return statement.bindMem(index, &mem).toC();
}

pub export fn sqlite3_bind_zeroblob(pointer: ?*sqlite3_stmt, index: c_int, length: c_int) callconv(.c) c_int {
    if (length < 0) return ResultCode.misuse.toC();
    return sqlite3_bind_zeroblob64(pointer, index, @intCast(length));
}

pub export fn sqlite3_bind_zeroblob64(pointer: ?*sqlite3_stmt, index: c_int, length: u64) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return ResultCode.misuse.toC();
    if (length > std.math.maxInt(c_int)) return ResultCode.too_big.toC();
    var mem = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&mem, null, vdbe_types.mem_flag.null_);
    vdbe_mem.setZeroBlob(&mem, @intCast(length));
    return statement.bindMem(index, &mem).toC();
}

pub export fn sqlite3_column_value(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) ?*sqlite3_value {
    const statement = asStatement(pointer) orelse return null;
    return if (statement.columnMem(index)) |value| @ptrCast(value) else null;
}

pub export fn sqlite3_column_count(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    return @intCast(statement.columns.len);
}

pub export fn sqlite3_data_count(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    return if (statement.vm.state == .row) @intCast(statement.vm.columnCount()) else 0;
}

pub export fn sqlite3_column_type(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 5;
    return vdbe_mem.valueType(statement.columnMem(index) orelse return 5);
}

pub export fn sqlite3_column_int64(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) i64 {
    const statement = asStatement(pointer) orelse return 0;
    return vdbe_mem.valueInt64(statement.columnMem(index) orelse return 0);
}

pub export fn sqlite3_column_int(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) c_int {
    return @truncate(sqlite3_column_int64(pointer, index));
}

pub export fn sqlite3_column_double(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) f64 {
    const statement = asStatement(pointer) orelse return 0;
    return vdbe_mem.valueDouble(statement.columnMem(index) orelse return 0);
}

pub export fn sqlite3_column_text(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) ?[*:0]const u8 {
    const statement = asStatement(pointer) orelse return null;
    return statement.text8(index);
}

pub export fn sqlite3_column_text16(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) ?*const anyopaque {
    const statement = asStatement(pointer) orelse return null;
    return statement.text16(index);
}

pub export fn sqlite3_column_blob(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) ?*const anyopaque {
    const statement = asStatement(pointer) orelse return null;
    return if (vdbe_mem.valueBlob(statement.columnMem(index) orelse return null)) |blob| @ptrCast(blob) else null;
}

pub export fn sqlite3_column_bytes(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    return vdbe_mem.valueBytes(statement.columnMem(index) orelse return 0, 1);
}

pub export fn sqlite3_column_bytes16(pointer: ?*sqlite3_stmt, index: c_int) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    return vdbe_mem.valueBytes(statement.columnMem(index) orelse return 0, 2);
}

pub export fn sqlite3_column_name16(pointer: ?*sqlite3_stmt, index_value: c_int) callconv(.c) ?*const anyopaque {
    const statement = asStatement(pointer) orelse return null;
    if (index_value < 0 or @as(usize, @intCast(index_value)) >= statement.columns.len) return null;
    const cache = &statement.caches[@intCast(index_value)];
    if (cache.name16 == null) cache.name16 = std.unicode.utf8ToUtf16LeAllocZ(statement.allocator, statement.columns[@intCast(index_value)].name) catch return null;
    return @ptrCast(cache.name16.?.ptr);
}
pub export fn sqlite3_column_database_name(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}
pub export fn sqlite3_column_database_name16(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}
pub export fn sqlite3_column_table_name(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}
pub export fn sqlite3_column_table_name16(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}
pub export fn sqlite3_column_origin_name(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}
pub export fn sqlite3_column_origin_name16(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}
pub export fn sqlite3_column_decltype(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}
pub export fn sqlite3_column_decltype16(_: ?*sqlite3_stmt, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_column_name(pointer: ?*sqlite3_stmt, index_value: c_int) callconv(.c) ?[*:0]const u8 {
    const statement = asStatement(pointer) orelse return null;
    if (index_value < 0 or @as(usize, @intCast(index_value)) >= statement.columns.len) return null;
    return statement.columns[@intCast(index_value)].name.ptr;
}

pub export fn sqlite3_stmt_busy(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const statement = asStatement(pointer) orelse return 0;
    return @intFromBool(statement.started and statement.vm.state != .halted and statement.vm.state != .failed);
}

pub export fn sqlite3_stmt_readonly(pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const prepared = asStatement(pointer) orelse return 0;
    return @intFromBool(prepared.readonly);
}

pub export fn sqlite3_sql(pointer: ?*sqlite3_stmt) callconv(.c) ?[*:0]const u8 {
    const self = asStatement(pointer) orelse return null;
    return if (self.sql_copy) |sql| sql.ptr else null;
}
/// Source `sqlite3VdbeGetBoundValue()`: duplicate one bound parameter into an
/// independently owned Mem cell for planning or expanded-SQL consumers.
fn getBoundValue(statement: *Statement, parameter: usize) !?*vdbe_types.Mem {
    if (parameter == 0 or parameter > statement.bindings.len) return null;
    const value = try statement.allocator.create(vdbe_types.Mem);
    vdbe_mem.init(value, null, vdbe_types.mem_flag.null_);
    errdefer statement.allocator.destroy(value);
    if (vdbe_mem.copy(value, &statement.bindings[parameter - 1].value) != 0) return error.OutOfMemory;
    value.flags &= ~vdbe_types.mem_flag.from_bind;
    return value;
}

fn freeBoundValue(statement: *Statement, value: *vdbe_types.Mem) void {
    vdbe_mem.release(value);
    statement.allocator.destroy(value);
}

fn appendExpandedValue(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: *const vdbe_types.Mem) !void {
    if (value.flags & vdbe_types.mem_flag.null_ != 0) return output.appendSlice(allocator, "NULL");
    if (value.flags & vdbe_types.mem_flag.integer != 0) {
        var buffer: [32]u8 = undefined;
        return output.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{d}", .{value.u.i}));
    }
    if (value.flags & vdbe_types.mem_flag.real != 0) {
        var buffer: [64]u8 = undefined;
        return output.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{d}", .{value.u.r}));
    }
    const count: usize = @intCast(@max(value.n, 0));
    const bytes: []const u8 = if (value.z) |pointer| pointer[0..count] else &.{};
    if (value.flags & vdbe_types.mem_flag.string != 0) {
        try output.append(allocator, '\'');
        for (bytes) |byte| {
            try output.append(allocator, byte);
            if (byte == '\'') try output.append(allocator, '\'');
        }
        return output.append(allocator, '\'');
    }
    if (value.flags & vdbe_types.mem_flag.zero != 0 and count == 0) {
        var buffer: [48]u8 = undefined;
        return output.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "zeroblob({d})", .{value.u.nZero}));
    }
    try output.appendSlice(allocator, "x'");
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        try output.append(allocator, digits[byte >> 4]);
        try output.append(allocator, digits[byte & 0x0f]);
    }
    return output.append(allocator, '\'');
}

/// Source `findNextHostParameter()`: return the tokenized SQL prefix before
/// the next host parameter and publish that parameter token's byte length.
fn findNextHostParameter(sql: [*:0]const u8, token_length: *usize) usize {
    token_length.* = 0;
    var total: usize = 0;
    while (sql[total] != 0) {
        const result = tokenizer.get(sql + total);
        std.debug.assert(result.length > 0 and result.token_type != tokenizer.token.tk_illegal);
        if (result.token_type == tokenizer.token.tk_variable) {
            token_length.* = result.length;
            break;
        }
        total += result.length;
    }
    return total;
}

/// Source `sqlite3_expanded_sql()`: substitute bound values into saved SQL,
/// preserving quoted literals/comments and allocating the result with
/// sqlite3_malloc() for caller ownership.
fn expandedSql(statement: *Statement) ?[*:0]u8 {
    const sql = if (statement.sql_copy) |saved| saved else return null;
    var expanded = std.ArrayList(u8).empty;
    defer expanded.deinit(statement.allocator);
    var index: usize = 0;
    var next_parameter: usize = 1;
    while (index < sql.len) {
        var token_length: usize = 0;
        const prefix_length = findNextHostParameter(@ptrCast(sql.ptr + index), &token_length);
        expanded.appendSlice(statement.allocator, sql[index .. index + prefix_length]) catch return null;
        index += prefix_length;
        if (token_length == 0) break;

        const end = index + token_length;
        const token = sql[index..end];
        var parameter_index: ?usize = null;
        if (token[0] == '?' and token.len > 1) {
            parameter_index = std.fmt.parseInt(usize, token[1..], 10) catch null;
        } else if (token.len == 1 and token[0] == '?') {
            parameter_index = next_parameter;
        } else {
            for (statement.parameters, 1..) |parameter, candidate| {
                if (parameter.name) |name| {
                    if (std.mem.eql(u8, name, token)) {
                        parameter_index = candidate;
                        break;
                    }
                }
            }
        }
        if (parameter_index) |parameter| {
            next_parameter = @max(next_parameter, parameter + 1);
            if (parameter > 0 and parameter <= statement.bindings.len) {
                const bound_optional = getBoundValue(statement, parameter) catch return null;
                const bound = bound_optional orelse return null;
                defer freeBoundValue(statement, bound);
                appendExpandedValue(&expanded, statement.allocator, bound) catch return null;
                index = end;
                continue;
            }
        }
        expanded.appendSlice(statement.allocator, token) catch return null;
        index = end;
    }
    const allocation = public_api.sqlite3_malloc64(expanded.items.len + 1) orelse return null;
    const output: [*]u8 = @ptrCast(allocation);
    @memcpy(output[0..expanded.items.len], expanded.items);
    output[expanded.items.len] = 0;
    return @ptrCast(output);
}

pub export fn sqlite3_expanded_sql(pointer: ?*sqlite3_stmt) callconv(.c) ?[*:0]u8 {
    return expandedSql(asStatement(pointer) orelse return null);
}

pub export fn sqlite3_expired(_: ?*sqlite3_stmt) callconv(.c) c_int {
    return 0;
}
pub export fn sqlite3_transfer_bindings(source_pointer: ?*sqlite3_stmt, destination_pointer: ?*sqlite3_stmt) callconv(.c) c_int {
    const source = asStatement(source_pointer) orelse return ResultCode.misuse.toC();
    const destination = asStatement(destination_pointer) orelse return ResultCode.misuse.toC();
    if (source.bindings.len != destination.bindings.len or source.started or destination.started) return ResultCode.error_.toC();
    for (source.bindings, destination.bindings) |*from, *to| {
        if (vdbe_mem.copy(&to.value, &from.value) != 0) return ResultCode.no_memory.toC();
        from.clear();
    }
    return ResultCode.ok.toC();
}
pub export fn sqlite3_stmt_explain(pointer: ?*sqlite3_stmt, mode: c_int) callconv(.c) c_int {
    if (asStatement(pointer) == null or mode < 0 or mode > 2) return ResultCode.misuse.toC();
    return if (mode == 0) ResultCode.ok.toC() else ResultCode.error_.toC();
}

pub export fn sqlite3_stmt_status(pointer: ?*sqlite3_stmt, operation: c_int, reset: c_int) callconv(.c) c_int {
    _ = operation;
    _ = reset;
    return if (asStatement(pointer) != null) 0 else 0;
}

pub export fn sqlite3_stmt_isexplain(_: ?*sqlite3_stmt) callconv(.c) c_int {
    return 0;
}

const test_statement_ops = [_]vdbe.Instruction{
    .{ .opcode = .result_row, .p1 = 1, .p2 = 4 },
    .{ .opcode = .halt },
};
const test_statement_program = vdbe.Program{ .instructions = &test_statement_ops, .register_count = 4 };
const test_parameters = [_]ParameterMetadata{
    .{ .name = ":integer" }, .{ .name = "@text" }, .{ .name = "$blob" }, .{ .name = "?4" },
};
const test_columns = [_]ColumnMetadata{
    .{ .name = "integer" }, .{ .name = "text" }, .{ .name = "blob" }, .{ .name = "utf16" },
};
var test_destructor_calls: usize = 0;
fn testDestructor(_: ?*anyopaque) callconv(.c) void {
    test_destructor_calls += 1;
}
fn transientDestructor() Destructor {
    return @ptrFromInt(std.math.maxInt(usize));
}

test "source host parameter scan skips quoted text and comments" {
    const sql = "SELECT '?', /* ? */ :name, ?2";
    var token_length: usize = 99;
    const prefix_length = findNextHostParameter(sql, &token_length);
    try std.testing.expectEqual(@as(usize, 20), prefix_length);
    try std.testing.expectEqual(@as(usize, 5), token_length);

    const remainder: [*:0]const u8 = @ptrCast(sql.ptr + prefix_length + token_length);
    try std.testing.expectEqual(@as(usize, 2), findNextHostParameter(remainder, &token_length));
    try std.testing.expectEqual(@as(usize, 2), token_length);
    try std.testing.expectEqual(@as(usize, 8), findNextHostParameter("SELECT 1", &token_length));
    try std.testing.expectEqual(@as(usize, 0), token_length);
}

test "statement bind step columns reset clear finalize and destructors" {
    test_destructor_calls = 0;
    const statement = try Statement.create(std.testing.allocator, &test_statement_program, &test_parameters, &test_columns);
    const handle = toOpaque(statement);
    try std.testing.expect(sqlite3_expanded_sql(null) == null);
    try std.testing.expectEqual(@as(c_int, 4), sqlite3_bind_parameter_count(handle));
    try std.testing.expectEqual(@as(c_int, 2), sqlite3_bind_parameter_index(handle, "@text"));
    try std.testing.expectEqualStrings("$blob", std.mem.span(sqlite3_bind_parameter_name(handle, 3).?));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_int64(handle, 1, 9_007_199_254_740_993));
    var custom_text: [5:0]u8 = "hello".*;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_text(handle, 2, &custom_text, -1, @ptrCast(&testDestructor)));
    const blob = [_]u8{ 0, 1, 2, 255 };
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_blob(handle, 3, &blob, blob.len, transientDestructor()));
    const utf16 = [_:0]u16{ 'h', 0x00e9, 0 };
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_text16(handle, 4, &utf16, -1, null));
    statement.setSql("SELECT :integer, @text, $blob, ?4") catch return error.OutOfMemory;
    const expanded = sqlite3_expanded_sql(handle) orelse return error.TestUnexpectedResult;
    defer public_api.sqlite3_free(expanded);
    try std.testing.expectEqualStrings("SELECT 9007199254740993, 'hello', x'000102ff', 'hé'", std.mem.span(expanded));
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(handle));
    try std.testing.expectEqual(@as(c_int, 4), sqlite3_data_count(handle));
    try std.testing.expectEqual(@as(c_int, 4), sqlite3_column_count(handle));
    try std.testing.expectEqual(@as(i64, 9_007_199_254_740_993), sqlite3_column_int64(handle, 0));
    try std.testing.expectEqual(@as(c_int, 1), sqlite3_column_type(handle, 0));
    try std.testing.expectEqualStrings("hello", std.mem.span(sqlite3_column_text(handle, 1).?));
    try std.testing.expectEqual(@as(c_int, 5), sqlite3_column_bytes(handle, 1));
    try std.testing.expectEqualSlices(u8, &blob, @as([*]const u8, @ptrCast(sqlite3_column_blob(handle, 2).?))[0..4]);
    try std.testing.expectEqual(@as(c_int, 4), sqlite3_column_bytes(handle, 2));
    try std.testing.expectEqual(@as(c_int, 4), sqlite3_column_bytes16(handle, 3));
    try std.testing.expectEqualStrings("text", std.mem.span(sqlite3_column_name(handle, 1).?));
    try std.testing.expectEqual(@as(c_int, 1), sqlite3_stmt_busy(handle));
    try std.testing.expectEqual(ResultCode.done.toC(), sqlite3_step(handle));
    try std.testing.expectEqual(@as(c_int, 0), sqlite3_stmt_busy(handle));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_reset(handle));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_text(handle, 2, "again", 5, null));
    try std.testing.expectEqual(@as(usize, 1), test_destructor_calls);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_clear_bindings(handle));
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(handle));
    for (0..4) |index| try std.testing.expectEqual(@as(c_int, 5), sqlite3_column_type(handle, @intCast(index)));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(handle));
    try std.testing.expectEqual(@as(usize, 1), test_destructor_calls);
}

test "sqlite values duplicate independently and bind through source Mem" {
    const first = try Statement.create(std.testing.allocator, &test_statement_program, &test_parameters, &test_columns);
    const first_handle = toOpaque(first);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_text(first_handle, 1, "SEVEN", 5, transientDestructor()));
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(first_handle));
    const borrowed = sqlite3_column_value(first_handle, 0).?;
    try std.testing.expectEqual(@as(c_int, 5), sqlite3_value_bytes(borrowed));
    try std.testing.expectEqualStrings("SEVEN", std.mem.span(sqlite3_value_text(borrowed).?));
    const duplicate = sqlite3_value_dup(borrowed).?;
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(first_handle));

    const second = try Statement.create(std.testing.allocator, &test_statement_program, &test_parameters, &test_columns);
    const second_handle = toOpaque(second);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_value(second_handle, 1, duplicate));
    sqlite3_value_free(duplicate);
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(second_handle));
    try std.testing.expectEqualStrings("SEVEN", std.mem.span(sqlite3_column_text(second_handle, 0).?));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(second_handle));
}

test "bind value snapshots static text and text64 normalizes native UTF16" {
    var source: [6:0]u8 = "static".*;
    var value = std.mem.zeroes(vdbe_types.Mem);
    vdbe_mem.init(&value, null, vdbe_types.mem_flag.null_);
    try std.testing.expectEqual(@as(c_int, 0), vdbe_mem.setStr(&value, &source, 6, 1, .static));

    const statement = try Statement.create(std.testing.allocator, &test_statement_program, &test_parameters, &test_columns);
    const handle = toOpaque(statement);
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_value(handle, 1, @ptrCast(&value)));
    source[0] = 'X';
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(handle));
    try std.testing.expectEqualStrings("static", std.mem.span(sqlite3_column_text(handle, 0).?));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(handle));
    vdbe_mem.release(&value);

    const utf16_statement = try Statement.create(std.testing.allocator, &test_statement_program, &test_parameters, &test_columns);
    const utf16_handle = toOpaque(utf16_statement);
    const native = [_]u8{ 'A', 0, 'B', 0, 0 };
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_bind_text64(utf16_handle, 1, &native, native.len, transientDestructor(), 4));
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(utf16_handle));
    try std.testing.expectEqualStrings("AB", std.mem.span(sqlite3_column_text(utf16_handle, 0).?));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(utf16_handle));
}

test "result APIs destroy rejected owned inputs" {
    test_destructor_calls = 0;
    const text: [1:0]u8 = "x".*;
    sqlite3_result_text(null, &text, 1, @ptrCast(&testDestructor));
    const blob = [_]u8{1};
    _ = sqlite3_result_blob64(null, &blob, 1, @ptrCast(&testDestructor));
    try std.testing.expectEqual(@as(usize, 2), test_destructor_calls);
}

test "statement misuse range negative lengths and error lifecycle return exact codes" {
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_step(null));
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_reset(null));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(null));
    const statement = try Statement.create(std.testing.allocator, &test_statement_program, &test_parameters, &test_columns);
    const handle = toOpaque(statement);
    try std.testing.expectEqual(ResultCode.range.toC(), sqlite3_bind_int(handle, 0, 1));
    try std.testing.expectEqual(ResultCode.range.toC(), sqlite3_bind_int(handle, 5, 1));
    const byte: u8 = 1;
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_bind_blob(handle, 1, &byte, -1, null));
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_bind_zeroblob(handle, 1, -1));
    try std.testing.expectEqual(ResultCode.row.toC(), sqlite3_step(handle));
    try std.testing.expectEqual(ResultCode.misuse.toC(), sqlite3_bind_int(handle, 1, 2));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(handle));

    const error_ops = [_]vdbe.Instruction{.{ .opcode = .halt, .p1 = 19 }};
    const error_program = vdbe.Program{ .instructions = &error_ops, .register_count = 1 };
    const error_columns = [_]ColumnMetadata{};
    const failed = try Statement.create(std.testing.allocator, &error_program, &.{}, &error_columns);
    const failed_opaque = toOpaque(failed);
    try std.testing.expectEqual(ResultCode.constraint.toC(), sqlite3_step(failed_opaque));
    try std.testing.expectEqual(ResultCode.constraint.toC(), sqlite3_reset(failed_opaque));
    try std.testing.expectEqual(ResultCode.ok.toC(), sqlite3_finalize(failed_opaque));
}

fn statementAllocationExercise(allocator: std.mem.Allocator) !void {
    const statement = Statement.create(allocator, &test_statement_program, &test_parameters, &test_columns) catch return error.OutOfMemory;
    const handle = toOpaque(statement);
    const result = sqlite3_bind_text(handle, 2, "allocation", -1, transientDestructor());
    if (result == ResultCode.no_memory.toC()) {
        _ = sqlite3_finalize(handle);
        return error.OutOfMemory;
    }
    if (result != ResultCode.ok.toC()) return error.UnexpectedResult;
    const step_result = sqlite3_step(handle);
    if (step_result == ResultCode.no_memory.toC()) {
        _ = sqlite3_finalize(handle);
        return error.OutOfMemory;
    }
    if (step_result != ResultCode.row.toC()) return error.UnexpectedResult;
    if (sqlite3_column_text(handle, 1) == null and statement.last_result == .no_memory) {
        _ = sqlite3_finalize(handle);
        return error.OutOfMemory;
    }
    if (sqlite3_finalize(handle) != ResultCode.ok.toC()) return error.UnexpectedResult;
}

test "statement allocation sites preserve binding and VM ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, statementAllocationExercise, .{});
}
