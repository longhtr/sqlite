//! Process logging state shared by public and built-in SQL APIs.

const formatter = @import("formatter.zig");
const memory = @import("memory.zig");

pub const Callback = *const fn (?*anyopaque, c_int, [*:0]const u8) callconv(.c) void;
var callback: ?Callback = null;
var callback_context: ?*anyopaque = null;

pub fn configure(new_callback: ?Callback, context: ?*anyopaque) void {
    callback = new_callback;
    callback_context = context;
}

pub fn message(code: c_int, text: ?[*:0]const u8) void {
    const present = callback orelse return;
    present(callback_context, code, text orelse return);
}

const Dispatch = struct { callback: Callback, context: ?*anyopaque };
fn dispatch(context: ?*anyopaque, code: c_int, text: []const u8) void {
    const state: *Dispatch = @ptrCast(@alignCast(context.?));
    state.callback(state.context, code, @ptrCast(text.ptr));
}

pub fn format(code: c_int, pattern: []const u8, arguments: []const formatter.FormatArgument) void {
    const present = callback orelse return;
    var state = Dispatch{ .callback = present, .context = callback_context };
    formatter.renderLogMessage(memory.processManager(), &state, dispatch, code, pattern, arguments);
}
