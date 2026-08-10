//! Temporary VDBE register allocation from `expr.c`.

const parse_types = @import("parse_types.zig");

/// Source `sqlite3GetTempReg()`.
pub fn getTemporaryRegister(parse: *parse_types.Parse) c_int {
    if (parse.nTempReg == 0) {
        parse.nMem += 1;
        return parse.nMem;
    }
    parse.nTempReg -= 1;
    return parse.aTempReg[@intCast(parse.nTempReg)];
}

/// Source `sqlite3ReleaseTempReg()`.
pub fn releaseTemporaryRegister(parse: *parse_types.Parse, register: c_int) void {
    if (register == 0) return;
    if (parse.nTempReg < parse.aTempReg.len) {
        parse.aTempReg[@intCast(parse.nTempReg)] = register;
        parse.nTempReg += 1;
    }
}

/// Source `sqlite3GetTempRange()`.
pub fn getTemporaryRange(parse: *parse_types.Parse, register_count: c_int) c_int {
    if (register_count == 1) return getTemporaryRegister(parse);
    const first = parse.iRangeReg;
    if (register_count <= parse.nRangeReg) {
        parse.iRangeReg += register_count;
        parse.nRangeReg -= register_count;
        return first;
    }
    const allocated = parse.nMem + 1;
    parse.nMem += register_count;
    return allocated;
}

/// Source `sqlite3ReleaseTempRange()`.
pub fn releaseTemporaryRange(parse: *parse_types.Parse, first: c_int, register_count: c_int) void {
    if (register_count == 1) {
        releaseTemporaryRegister(parse, first);
        return;
    }
    if (register_count > parse.nRangeReg) {
        parse.nRangeReg = register_count;
        parse.iRangeReg = first;
    }
}

/// Source `sqlite3ClearTempRegCache()`.
pub fn clearTemporaryRegisterCache(parse: *parse_types.Parse) void {
    parse.nTempReg = 0;
    parse.nRangeReg = 0;
}

/// Source `sqlite3TouchRegister()`.
pub fn touchRegister(parse: *parse_types.Parse, register: c_int) void {
    if (parse.nMem < register) parse.nMem = register;
}
