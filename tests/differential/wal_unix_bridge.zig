const std = @import("std");
const pager_module = @import("pager");
const Pager = pager_module.Pager;
const vfs = pager_module.vfs;
export fn sqlite3_phase10_wal_hybrid(v: *vfs.sqlite3_vfs, path: [*:0]const u8, value: u32, operation: c_int) c_int {
    var pager = Pager.open(std.heap.c_allocator, v, std.mem.span(path), .{ .writable = true, .wal_external_index = true }).pager orelse return 14;
    var rc = pager.beginRead();
    if (rc != .ok) {
        _ = pager.close();
        return rc.toC();
    }
    if (operation == 0) {
        rc = pager.beginWrite();
        if (rc == .ok) {
            const got = pager.getPage(1, false);
            rc = got.result;
            if (rc == .ok) {
                const p = got.page.?;
                rc = pager.makeWritable(p);
                if (rc == .ok) {
                    p.data[60] = @truncate(value >> 24);
                    p.data[61] = @truncate(value >> 16);
                    p.data[62] = @truncate(value >> 8);
                    p.data[63] = @truncate(value);
                }
                _ = pager.release(p);
            }
        }
        if (rc == .ok) rc = pager.commit();
    } else if (operation == 1) rc = pager.checkpointWal().result else rc = .misuse;
    const close_rc = pager.close();
    if (rc == .ok) rc = close_rc;
    return rc.toC();
}
