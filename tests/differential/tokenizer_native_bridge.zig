const tokenizer = @import("tokenizer");
pub export fn probe_token(input: [*:0]const u8, token_type: *c_int) callconv(.c) i64 {
    return sqlite3GetToken(input, token_type);
}

pub export fn probe_context(input: [*:0]const u8, window: *c_int, over: *c_int, filter: *c_int) callconv(.c) void {
    window.* = tokenizer.analyzeWindow(input);
    over.* = tokenizer.analyzeOver(input, tokenizer.token.tk_rp);
    filter.* = tokenizer.analyzeFilter(input, tokenizer.token.tk_rp);
}

pub export fn sqlite3GetToken(input: [*:0]const u8, token_type: *c_int) callconv(.c) i64 {
    const result = tokenizer.get(input);
    token_type.* = result.token_type;
    return @intCast(result.length);
}
