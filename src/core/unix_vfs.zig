//! Linux/Unix native VFS for the Phase 15 bounded target profile.
const std = @import("std");
pub const vfs = @import("vfs.zig");
pub const pager = @import("pager.zig");

const O_RDONLY = 0;
const O_RDWR = 2;
const O_CREAT = 64;
const O_EXCL = 128;
const O_CLOEXEC = 524288;
const O_DIRECTORY = 65536;
const SEEK_END = 2;
const F_OFD_SETLK = 37;
const F_RDLCK: i16 = 0;
const F_WRLCK: i16 = 1;
const F_UNLCK: i16 = 2;
const PROT_READ = 1;
const PROT_WRITE = 2;
const MAP_SHARED = 1;
const PENDING: i64 = 0x40000000;
const RESERVED = PENDING + 1;
const SHARED = PENDING + 2;
const SHARED_LEN: i64 = 510;
const ENOENT = 2;
const EACCES = 13;
const EAGAIN = 11;
const EWOULDBLOCK = EAGAIN;
const ENOMEM = 12;
const EEXIST = 17;
const SC_PAGESIZE = 30;
const Flock = extern struct { l_type: i16, l_whence: i16, l_start: i64, l_len: i64, l_pid: i32 };
extern "c" fn open([*:0]const u8, c_int, ...) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn pread(c_int, *anyopaque, usize, i64) isize;
extern "c" fn pwrite(c_int, *const anyopaque, usize, i64) isize;
extern "c" fn fsync(c_int) c_int;
extern "c" fn ftruncate(c_int, i64) c_int;
extern "c" fn lseek(c_int, i64, c_int) i64;
extern "c" fn fcntl(c_int, c_int, ...) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn mkdir([*:0]const u8, c_uint) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn access([*:0]const u8, c_int) c_int;
extern "c" fn getcwd([*]u8, usize) ?[*]u8;
extern "c" fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
extern "c" fn munmap(*anyopaque, usize) c_int;
extern "c" fn sysconf(c_int) isize;
extern "c" fn getpid() c_int;
extern "c" fn getrandom(*anyopaque, usize, c_uint) isize;
extern "c" fn time(?*i64) i64;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn __errno_location() *c_int;

pub fn remove(path: [*:0]const u8) void {
    _ = unlink(path);
}

fn errno() c_int {
    return __errno_location().*;
}
fn ioCode(default: c_int) c_int {
    return switch (errno()) {
        ENOMEM => vfs.NOMEM,
        ENOENT => vfs.CANTOPEN,
        EACCES => vfs.CANTOPEN,
        else => default,
    };
}
fn lockRange(fd: c_int, typ: i16, start: i64, len: i64) c_int {
    var f = Flock{ .l_type = typ, .l_whence = 0, .l_start = start, .l_len = len, .l_pid = 0 };
    if (fcntl(fd, F_OFD_SETLK, &f) == 0) return vfs.OK;
    return if (errno() == EACCES or errno() == EAGAIN or errno() == EWOULDBLOCK) vfs.BUSY else vfs.IOERR;
}
fn decodeUri(allocator: std.mem.Allocator, input: []const u8) ![:0]u8 {
    var text = input;
    if (std.mem.startsWith(u8, text, "file:")) text = text[5..];
    if (std.mem.indexOfScalar(u8, text, '?')) |i| text = text[0..i];
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%' and i + 2 < text.len) {
            try out.append(allocator, std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.BadUri);
            i += 3;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
    return try allocator.dupeZ(u8, out.items);
}

pub const LockingMode = enum { posix, none, dotfile, exclusive };

pub const UnixVfs = struct {
    allocator: std.mem.Allocator,
    locking_mode: LockingMode = .posix,
    temp_counter: usize = 0,
    open_override: ?*const fn ([*:0]const u8, c_int, c_int) callconv(.c) c_int = null,
    pread_override: ?*const fn (c_int, *anyopaque, usize, i64) callconv(.c) isize = null,
    pwrite_override: ?*const fn (c_int, *const anyopaque, usize, i64) callconv(.c) isize = null,
    fsync_override: ?*const fn (c_int) callconv(.c) c_int = null,
    pub fn init(a: std.mem.Allocator) UnixVfs {
        return initMode(a, .posix);
    }
    pub fn initMode(a: std.mem.Allocator, mode: LockingMode) UnixVfs {
        return .{ .allocator = a, .locking_mode = mode };
    }
    fn openFd(self: *UnixVfs, path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
        return if (self.open_override) |f| f(path, flags, mode) else open(path, flags, mode);
    }
    fn preadFd(self: *UnixVfs, fd: c_int, output: *anyopaque, count: usize, offset: i64) isize {
        return if (self.pread_override) |f| f(fd, output, count, offset) else pread(fd, output, count, offset);
    }
    fn pwriteFd(self: *UnixVfs, fd: c_int, input: *const anyopaque, count: usize, offset: i64) isize {
        return if (self.pwrite_override) |f| f(fd, input, count, offset) else pwrite(fd, input, count, offset);
    }
    fn fsyncFd(self: *UnixVfs, fd: c_int) c_int {
        return if (self.fsync_override) |f| f(fd) else fsync(fd);
    }
    fn makePath(self: *UnixVfs, name: ?[]const u8) ![:0]u8 {
        if (name) |n| return decodeUri(self.allocator, n);
        self.temp_counter += 1;
        return std.fmt.allocPrintSentinel(self.allocator, "/tmp/sqlite-zig-{d}-{d}", .{ getpid(), self.temp_counter }, 0);
    }
    pub fn openFile(self: *UnixVfs, name: ?[]const u8, flags: c_int) struct { rc: c_int, file: ?*UnixFile } {
        const path = self.makePath(name) catch return .{ .rc = vfs.NOMEM, .file = null };
        errdefer self.allocator.free(path);
        var oflags: c_int = O_CLOEXEC;
        if (flags & vfs.OPEN_READWRITE != 0) oflags |= O_RDWR else oflags |= O_RDONLY;
        if (flags & vfs.OPEN_CREATE != 0) oflags |= O_CREAT;
        var fd = self.openFd(path, oflags, 0o644);
        var readonly = false;
        if (fd < 0 and flags & vfs.OPEN_READWRITE != 0) {
            fd = self.openFd(path, O_RDONLY | O_CLOEXEC, 0);
            readonly = true;
        }
        if (fd < 0) {
            self.allocator.free(path);
            return .{ .rc = ioCode(vfs.CANTOPEN), .file = null };
        }
        const f = self.allocator.create(UnixFile) catch {
            _ = close(fd);
            self.allocator.free(path);
            return .{ .rc = vfs.NOMEM, .file = null };
        };
        var dotlock_path: ?[:0]u8 = null;
        if (self.locking_mode == .dotfile) {
            dotlock_path = std.fmt.allocPrintSentinel(self.allocator, "{s}.lock", .{path}, 0) catch {
                self.allocator.destroy(f);
                _ = close(fd);
                self.allocator.free(path);
                return .{ .rc = vfs.NOMEM, .file = null };
            };
        }
        f.* = .{ .owner = self, .fd = fd, .path = path, .readonly = readonly, .delete_on_close = flags & vfs.OPEN_DELETEONCLOSE != 0, .dotlock_path = dotlock_path };
        return .{ .rc = vfs.OK, .file = f };
    }
    pub fn delete(self: *UnixVfs, name: []const u8, sync_dir: bool) c_int {
        const p = decodeUri(self.allocator, name) catch return vfs.NOMEM;
        defer self.allocator.free(p);
        if (unlink(p) != 0 and errno() != ENOENT) return vfs.IOERR_DELETE;
        if (sync_dir) {
            const slash = std.mem.lastIndexOfScalar(u8, p, '/');
            const dir = if (slash) |i| if (i == 0) "/" else p[0..i] else ".";
            const z = self.allocator.dupeZ(u8, dir) catch return vfs.NOMEM;
            defer self.allocator.free(z);
            const fd = open(z, O_RDONLY | O_DIRECTORY | O_CLOEXEC, @as(c_int, 0));
            if (fd >= 0) {
                _ = fsync(fd);
                _ = close(fd);
            }
        }
        return vfs.OK;
    }
    pub fn accessPath(self: *UnixVfs, name: []const u8, mode: c_int, out: *c_int) c_int {
        const p = decodeUri(self.allocator, name) catch return vfs.NOMEM;
        defer self.allocator.free(p);
        const amode: c_int = if (mode == vfs.ACCESS_READWRITE) 6 else if (mode == vfs.ACCESS_READ) 4 else 0;
        out.* = @intFromBool(access(p, amode) == 0);
        return vfs.OK;
    }
    pub fn fullPath(self: *UnixVfs, name: []const u8, out: []u8) c_int {
        const p = decodeUri(self.allocator, name) catch return vfs.NOMEM;
        defer self.allocator.free(p);
        var buf: [4096]u8 = undefined;
        const full: []const u8 = p;
        if (p.len == 0 or p[0] != '/') {
            const got = getcwd(&buf, buf.len) orelse return vfs.CANTOPEN;
            const cwd = std.mem.span(@as([*:0]u8, @ptrCast(got)));
            if (cwd.len + 1 + p.len + 1 > out.len) return vfs.CANTOPEN;
            @memcpy(out[0..cwd.len], cwd);
            out[cwd.len] = '/';
            @memcpy(out[cwd.len + 1 ..][0..p.len], p);
            out[cwd.len + 1 + p.len] = 0;
            return vfs.OK;
        }
        if (full.len + 1 > out.len) return vfs.CANTOPEN;
        @memcpy(out[0..full.len], full);
        out[full.len] = 0;
        return vfs.OK;
    }
};

pub const UnixFile = struct {
    owner: *UnixVfs,
    fd: c_int,
    path: [:0]u8,
    readonly: bool = false,
    delete_on_close: bool = false,
    lock_level: c_int = vfs.LOCK_NONE,
    shm_fd: c_int = -1,
    shm_path: ?[:0]u8 = null,
    shm_map: ?[]u8 = null,
    fetch_map: ?[]u8 = null,
    fetch_return: ?*anyopaque = null,
    dotlock_path: ?[:0]u8 = null,
    dotlock_held: bool = false,
    exclusive_process_lock: bool = false,
    pub fn destroy(self: *UnixFile) c_int {
        self.unmapAll();
        if (self.dotlock_held) _ = rmdir(self.dotlock_path.?.ptr);
        if (self.dotlock_path) |path| self.owner.allocator.free(path);
        _ = close(self.fd);
        if (self.delete_on_close) _ = unlink(self.path);
        self.owner.allocator.free(self.path);
        self.owner.allocator.destroy(self);
        return vfs.OK;
    }
    fn unmapAll(self: *UnixFile) void {
        if (self.fetch_map) |m| {
            _ = munmap(m.ptr, m.len);
            self.fetch_map = null;
        }
        if (self.shm_map) |m| {
            _ = munmap(m.ptr, m.len);
            self.shm_map = null;
        }
        if (self.shm_fd >= 0) {
            _ = close(self.shm_fd);
            self.shm_fd = -1;
        }
        if (self.shm_path) |p| {
            self.owner.allocator.free(p);
            self.shm_path = null;
        }
    }
    pub fn read(self: *UnixFile, out: []u8, off: i64) c_int {
        @memset(out, 0);
        const n = self.owner.preadFd(self.fd, out.ptr, out.len, off);
        if (n < 0) return vfs.IOERR;
        if (n == out.len) return vfs.OK;
        return vfs.IOERR_SHORT_READ;
    }
    pub fn write(self: *UnixFile, input: []const u8, off: i64) c_int {
        if (self.readonly) return vfs.IOERR_WRITE;
        var done: usize = 0;
        while (done < input.len) {
            const n = self.owner.pwriteFd(self.fd, input.ptr + done, input.len - done, off + @as(i64, @intCast(done)));
            if (n <= 0) return vfs.IOERR_WRITE;
            done += @intCast(n);
        }
        return vfs.OK;
    }
    fn truncate(self: *UnixFile, n: i64) c_int {
        return if (ftruncate(self.fd, n) == 0) vfs.OK else vfs.IOERR_TRUNCATE;
    }
    pub fn size(self: *UnixFile, out: *i64) c_int {
        const n = lseek(self.fd, 0, SEEK_END);
        if (n < 0) return vfs.IOERR;
        out.* = n;
        return vfs.OK;
    }
    pub fn sync(self: *UnixFile) c_int {
        return if (self.owner.fsyncFd(self.fd) == 0) vfs.OK else vfs.IOERR_FSYNC;
    }
    fn lock(self: *UnixFile, target: c_int) c_int {
        if (target <= self.lock_level) return vfs.OK;
        if (self.owner.locking_mode == .none) {
            self.lock_level = target;
            return vfs.OK;
        }
        if (self.owner.locking_mode == .dotfile) {
            if (!self.dotlock_held) {
                if (mkdir(self.dotlock_path.?.ptr, 0o777) != 0)
                    return if (errno() == EEXIST) vfs.BUSY else vfs.IOERR;
                self.dotlock_held = true;
            }
            self.lock_level = target;
            return vfs.OK;
        }
        if (self.owner.locking_mode == .exclusive and !self.readonly and !self.exclusive_process_lock) {
            const rc = lockRange(self.fd, F_WRLCK, 0, 0);
            if (rc != vfs.OK) return rc;
            self.exclusive_process_lock = true;
            self.lock_level = target;
            return vfs.OK;
        }
        var rc: c_int = vfs.OK;
        if (target >= vfs.LOCK_SHARED and self.lock_level < vfs.LOCK_SHARED) rc = lockRange(self.fd, F_RDLCK, SHARED, SHARED_LEN);
        if (rc == vfs.OK and target >= vfs.LOCK_RESERVED and self.lock_level < vfs.LOCK_RESERVED) rc = lockRange(self.fd, F_WRLCK, RESERVED, 1);
        if (rc == vfs.OK and target >= vfs.LOCK_PENDING and self.lock_level < vfs.LOCK_PENDING) rc = lockRange(self.fd, F_WRLCK, PENDING, 1);
        if (rc == vfs.OK and target >= vfs.LOCK_EXCLUSIVE) rc = lockRange(self.fd, F_WRLCK, SHARED, SHARED_LEN);
        if (rc == vfs.OK) self.lock_level = target;
        return rc;
    }
    fn unlock(self: *UnixFile, target: c_int) c_int {
        if (target >= self.lock_level) return vfs.OK;
        if (self.owner.locking_mode == .none or self.exclusive_process_lock) {
            self.lock_level = target;
            return vfs.OK;
        }
        if (self.owner.locking_mode == .dotfile) {
            if (target == vfs.LOCK_NONE and self.dotlock_held) {
                if (rmdir(self.dotlock_path.?.ptr) != 0) return vfs.IOERR;
                self.dotlock_held = false;
            }
            self.lock_level = target;
            return vfs.OK;
        }
        if (self.lock_level >= vfs.LOCK_EXCLUSIVE) _ = lockRange(self.fd, F_RDLCK, SHARED, SHARED_LEN);
        if (target < vfs.LOCK_PENDING) _ = lockRange(self.fd, F_UNLCK, PENDING, 1);
        if (target < vfs.LOCK_RESERVED) _ = lockRange(self.fd, F_UNLCK, RESERVED, 1);
        if (target < vfs.LOCK_SHARED) _ = lockRange(self.fd, F_UNLCK, SHARED, SHARED_LEN);
        self.lock_level = target;
        return vfs.OK;
    }
    fn reserved(self: *UnixFile, out: *c_int) c_int {
        if (self.owner.locking_mode == .none) {
            out.* = 0;
            return vfs.OK;
        }
        if (self.owner.locking_mode == .dotfile) {
            out.* = @intFromBool(access(self.dotlock_path.?.ptr, 0) == 0);
            return vfs.OK;
        }
        if (self.exclusive_process_lock or self.lock_level >= vfs.LOCK_RESERVED) {
            out.* = 1;
            return vfs.OK;
        }
        const rc = lockRange(self.fd, F_WRLCK, RESERVED, 1);
        if (rc == vfs.OK) {
            _ = lockRange(self.fd, F_UNLCK, RESERVED, 1);
            out.* = 0;
            return vfs.OK;
        }
        if (rc == vfs.BUSY) {
            out.* = 1;
            return vfs.OK;
        }
        return rc;
    }
    fn ensureShm(self: *UnixFile) !void {
        if (self.shm_map != null) return;
        const p = try std.fmt.allocPrintSentinel(self.owner.allocator, "{s}-shm", .{self.path}, 0);
        errdefer self.owner.allocator.free(p);
        const fd = open(p, O_RDWR | O_CREAT | O_CLOEXEC, @as(c_int, 0o644));
        if (fd < 0) return error.Open;
        errdefer _ = close(fd);
        const len = 4 * vfs.SHM_REGION_SIZE;
        if (ftruncate(fd, @intCast(len)) != 0) return error.Truncate;
        const raw = mmap(null, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) orelse return error.Map;
        if (@intFromPtr(raw) == std.math.maxInt(usize)) return error.Map;
        self.shm_fd = fd;
        self.shm_path = p;
        self.shm_map = @as([*]u8, @ptrCast(raw))[0..len];
    }
    fn shmMapRegion(self: *UnixFile, region: c_int, region_size: c_int, extend: c_int, out: *?*volatile anyopaque) c_int {
        if (region < 0 or region >= 4 or region_size != vfs.SHM_REGION_SIZE) return vfs.IOERR_SHMMAP;
        if (self.ensureShm()) |_| {} else |_| {
            if (extend == 0) {
                out.* = null;
                return vfs.OK;
            }
            return vfs.IOERR_SHMMAP;
        }
        out.* = @ptrCast(self.shm_map.?.ptr + @as(usize, @intCast(region)) * vfs.SHM_REGION_SIZE);
        return vfs.OK;
    }
    fn shmLock(self: *UnixFile, offset: c_int, count: c_int, flags: c_int) c_int {
        if (self.ensureShm()) |_| {} else |_| return vfs.IOERR_SHMLOCK;
        const typ: i16 = if (flags & vfs.SHM_UNLOCK != 0) F_UNLCK else if (flags & vfs.SHM_EXCLUSIVE != 0) F_WRLCK else F_RDLCK;
        return lockRange(self.shm_fd, typ, 120 + offset, count);
    }
    fn shmUnmap(self: *UnixFile, delete_flag: c_int) c_int {
        if (self.shm_map) |m| {
            _ = munmap(m.ptr, m.len);
            self.shm_map = null;
        }
        if (self.shm_fd >= 0) {
            _ = close(self.shm_fd);
            self.shm_fd = -1;
        }
        if (self.shm_path) |p| {
            if (delete_flag != 0) _ = unlink(p);
            self.owner.allocator.free(p);
            self.shm_path = null;
        }
        return vfs.OK;
    }
    fn fetch(self: *UnixFile, off: i64, n: c_int, out: *?*anyopaque) c_int {
        out.* = null;
        if (n <= 0) return vfs.OK;
        const page: isize = sysconf(SC_PAGESIZE);
        if (page <= 0) return vfs.OK;
        const aligned = off - @mod(off, @as(i64, @intCast(page)));
        const delta: usize = @intCast(off - aligned);
        const len = delta + @as(usize, @intCast(n));
        const raw = mmap(null, len, PROT_READ, MAP_SHARED, self.fd, aligned) orelse return vfs.OK;
        if (@intFromPtr(raw) == std.math.maxInt(usize)) return vfs.OK;
        const m = @as([*]u8, @ptrCast(raw))[0..len];
        self.fetch_map = m;
        self.fetch_return = @ptrCast(m.ptr + delta);
        out.* = self.fetch_return;
        return vfs.OK;
    }
    fn unfetch(self: *UnixFile, p: ?*anyopaque) c_int {
        if (p == null) return vfs.OK;
        if (self.fetch_map) |m| {
            _ = munmap(m.ptr, m.len);
            self.fetch_map = null;
            self.fetch_return = null;
        }
        return vfs.OK;
    }
};

const AbiFile = extern struct { base: vfs.sqlite3_file, native: ?*UnixFile };
fn af(f: *vfs.sqlite3_file) *AbiFile {
    return @ptrCast(@alignCast(f));
}
fn av(v: *vfs.sqlite3_vfs) *UnixVfs {
    return @ptrCast(@alignCast(v.pAppData.?));
}
fn xClose(f: *vfs.sqlite3_file) callconv(.c) c_int {
    const n = af(f).native.?;
    af(f).native = null;
    f.pMethods = null;
    return n.destroy();
}
fn xRead(f: *vfs.sqlite3_file, p: *anyopaque, n: c_int, o: i64) callconv(.c) c_int {
    return af(f).native.?.read(@as([*]u8, @ptrCast(p))[0..@intCast(n)], o);
}
fn xWrite(f: *vfs.sqlite3_file, p: *const anyopaque, n: c_int, o: i64) callconv(.c) c_int {
    return af(f).native.?.write(@as([*]const u8, @ptrCast(p))[0..@intCast(n)], o);
}
fn xTruncate(f: *vfs.sqlite3_file, n: i64) callconv(.c) c_int {
    return af(f).native.?.truncate(n);
}
fn xSync(f: *vfs.sqlite3_file, _: c_int) callconv(.c) c_int {
    return af(f).native.?.sync();
}
fn xSize(f: *vfs.sqlite3_file, n: *i64) callconv(.c) c_int {
    return af(f).native.?.size(n);
}
fn xLock(f: *vfs.sqlite3_file, n: c_int) callconv(.c) c_int {
    return af(f).native.?.lock(n);
}
fn xUnlock(f: *vfs.sqlite3_file, n: c_int) callconv(.c) c_int {
    return af(f).native.?.unlock(n);
}
fn xReserved(f: *vfs.sqlite3_file, n: *c_int) callconv(.c) c_int {
    return af(f).native.?.reserved(n);
}
fn xControl(_: *vfs.sqlite3_file, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return vfs.NOTFOUND;
}
fn xSector(_: *vfs.sqlite3_file) callconv(.c) c_int {
    return 4096;
}
fn xDevice(_: *vfs.sqlite3_file) callconv(.c) c_int {
    return 0;
}
fn xShmMap(f: *vfs.sqlite3_file, r: c_int, s: c_int, e: c_int, p: *?*volatile anyopaque) callconv(.c) c_int {
    return af(f).native.?.shmMapRegion(r, s, e, p);
}
fn xShmLock(f: *vfs.sqlite3_file, o: c_int, n: c_int, fl: c_int) callconv(.c) c_int {
    return af(f).native.?.shmLock(o, n, fl);
}
var barrier_byte: u8 = 0;
fn xBarrier(_: *vfs.sqlite3_file) callconv(.c) void {
    _ = @atomicRmw(u8, &barrier_byte, .Add, 0, .seq_cst);
}
fn xShmUnmap(f: *vfs.sqlite3_file, d: c_int) callconv(.c) c_int {
    return af(f).native.?.shmUnmap(d);
}
fn xFetch(f: *vfs.sqlite3_file, o: i64, n: c_int, p: *?*anyopaque) callconv(.c) c_int {
    return af(f).native.?.fetch(o, n, p);
}
fn xUnfetch(f: *vfs.sqlite3_file, _: i64, p: ?*anyopaque) callconv(.c) c_int {
    return af(f).native.?.unfetch(p);
}
const methods = vfs.sqlite3_io_methods{ .iVersion = 3, .xClose = xClose, .xRead = xRead, .xWrite = xWrite, .xTruncate = xTruncate, .xSync = xSync, .xFileSize = xSize, .xLock = xLock, .xUnlock = xUnlock, .xCheckReservedLock = xReserved, .xFileControl = xControl, .xSectorSize = xSector, .xDeviceCharacteristics = xDevice, .xShmMap = xShmMap, .xShmLock = xShmLock, .xShmBarrier = xBarrier, .xShmUnmap = xShmUnmap, .xFetch = xFetch, .xUnfetch = xUnfetch };
const no_lock_methods = vfs.sqlite3_io_methods{ .iVersion = 3, .xClose = xClose, .xRead = xRead, .xWrite = xWrite, .xTruncate = xTruncate, .xSync = xSync, .xFileSize = xSize, .xLock = xLock, .xUnlock = xUnlock, .xCheckReservedLock = xReserved, .xFileControl = xControl, .xSectorSize = xSector, .xDeviceCharacteristics = xDevice, .xShmMap = null, .xShmLock = xShmLock, .xShmBarrier = xBarrier, .xShmUnmap = xShmUnmap, .xFetch = xFetch, .xUnfetch = xUnfetch };
const dot_lock_methods = vfs.sqlite3_io_methods{ .iVersion = 1, .xClose = xClose, .xRead = xRead, .xWrite = xWrite, .xTruncate = xTruncate, .xSync = xSync, .xFileSize = xSize, .xLock = xLock, .xUnlock = xUnlock, .xCheckReservedLock = xReserved, .xFileControl = xControl, .xSectorSize = xSector, .xDeviceCharacteristics = xDevice, .xShmMap = null, .xShmLock = xShmLock, .xShmBarrier = xBarrier, .xShmUnmap = xShmUnmap, .xFetch = xFetch, .xUnfetch = xUnfetch };
fn vOpen(v: *vfs.sqlite3_vfs, n: ?[*:0]const u8, f: *vfs.sqlite3_file, flags: c_int, out: ?*c_int) callconv(.c) c_int {
    af(f).* = .{ .base = .{ .pMethods = null }, .native = null };
    const r = av(v).openFile(if (n) |z| std.mem.span(z) else null, flags);
    if (r.file) |file| {
        af(f).native = file;
        f.pMethods = switch (file.owner.locking_mode) {
            .none => &no_lock_methods,
            .dotfile => &dot_lock_methods,
            .posix, .exclusive => &methods,
        };
        if (out) |o| o.* = if (file.readonly) (flags & ~vfs.OPEN_READWRITE) | vfs.OPEN_READONLY else flags;
    }
    return r.rc;
}
fn vDelete(v: *vfs.sqlite3_vfs, n: [*:0]const u8, s: c_int) callconv(.c) c_int {
    return av(v).delete(std.mem.span(n), s != 0);
}
fn vAccess(v: *vfs.sqlite3_vfs, n: [*:0]const u8, m: c_int, o: *c_int) callconv(.c) c_int {
    return av(v).accessPath(std.mem.span(n), m, o);
}
fn vFull(v: *vfs.sqlite3_vfs, n: [*:0]const u8, z: c_int, o: [*]u8) callconv(.c) c_int {
    return av(v).fullPath(std.mem.span(n), o[0..@intCast(z)]);
}
fn vRandom(_: *vfs.sqlite3_vfs, n: c_int, o: [*]u8) callconv(.c) c_int {
    const count: usize = @intCast(@max(n, 0));
    const got = getrandom(o, count, 0);
    if (got < 0) return 0;
    return @intCast(got);
}
fn vSleep(_: *vfs.sqlite3_vfs, n: c_int) callconv(.c) c_int {
    _ = usleep(@intCast(@max(n, 0)));
    return n;
}
fn vTime(_: *vfs.sqlite3_vfs, o: *f64) callconv(.c) c_int {
    o.* = 2440587.5 + @as(f64, @floatFromInt(time(null))) / 86400.0;
    return vfs.OK;
}
fn vTime64(_: *vfs.sqlite3_vfs, o: *i64) callconv(.c) c_int {
    o.* = 210866760000000 + time(null) * 1000;
    return vfs.OK;
}
fn vLast(_: *vfs.sqlite3_vfs, n: c_int, o: [*]u8) callconv(.c) c_int {
    if (n > 0) o[0] = 0;
    return errno();
}
const open_name: [*:0]const u8 = "open";
const pread_name: [*:0]const u8 = "pread";
const pwrite_name: [*:0]const u8 = "pwrite";
const fsync_name: [*:0]const u8 = "fsync";
fn vSet(v: *vfs.sqlite3_vfs, n: [*:0]const u8, p: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    const name = std.mem.span(n);
    if (std.mem.eql(u8, name, "open")) av(v).open_override = if (p) |q| @ptrCast(q) else null else if (std.mem.eql(u8, name, "pread")) av(v).pread_override = if (p) |q| @ptrCast(q) else null else if (std.mem.eql(u8, name, "pwrite")) av(v).pwrite_override = if (p) |q| @ptrCast(q) else null else if (std.mem.eql(u8, name, "fsync")) av(v).fsync_override = if (p) |q| @ptrCast(q) else null else return vfs.NOTFOUND;
    return vfs.OK;
}
fn vGet(v: *vfs.sqlite3_vfs, n: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    const name = std.mem.span(n);
    if (std.mem.eql(u8, name, "open")) return if (av(v).open_override) |p| @ptrCast(p) else @ptrCast(&open);
    if (std.mem.eql(u8, name, "pread")) return if (av(v).pread_override) |p| @ptrCast(p) else @ptrCast(&pread);
    if (std.mem.eql(u8, name, "pwrite")) return if (av(v).pwrite_override) |p| @ptrCast(p) else @ptrCast(&pwrite);
    if (std.mem.eql(u8, name, "fsync")) return if (av(v).fsync_override) |p| @ptrCast(p) else @ptrCast(&fsync);
    return null;
}
fn vNext(_: *vfs.sqlite3_vfs, n: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (n == null) return open_name;
    const name = std.mem.span(n.?);
    if (std.mem.eql(u8, name, "open")) return pread_name;
    if (std.mem.eql(u8, name, "pread")) return pwrite_name;
    if (std.mem.eql(u8, name, "pwrite")) return fsync_name;
    return null;
}
fn nullDlOpen(_: *vfs.sqlite3_vfs, _: [*:0]const u8) callconv(.c) ?*anyopaque {
    return null;
}
fn nullDlError(_: *vfs.sqlite3_vfs, n: c_int, o: [*]u8) callconv(.c) void {
    if (n > 0) o[0] = 0;
}
fn nullDlSym(_: *vfs.sqlite3_vfs, _: ?*anyopaque, _: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return null;
}
fn nullDlClose(_: *vfs.sqlite3_vfs, _: ?*anyopaque) callconv(.c) void {}
pub const Adapter = struct {
    abi: vfs.sqlite3_vfs,
    pub fn init(name: [*:0]const u8, native: *UnixVfs) Adapter {
        return .{ .abi = .{ .iVersion = 3, .szOsFile = @sizeOf(AbiFile), .mxPathname = 4096, .pNext = null, .zName = name, .pAppData = native, .xOpen = vOpen, .xDelete = vDelete, .xAccess = vAccess, .xFullPathname = vFull, .xDlOpen = nullDlOpen, .xDlError = nullDlError, .xDlSym = nullDlSym, .xDlClose = nullDlClose, .xRandomness = vRandom, .xSleep = vSleep, .xCurrentTime = vTime, .xGetLastError = vLast, .xCurrentTimeInt64 = vTime64, .xSetSystemCall = vSet, .xGetSystemCall = vGet, .xNextSystemCall = vNext } };
    }
};

extern "c" fn fork() c_int;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn kill(c_int, c_int) c_int;
extern "c" fn pause() c_int;

fn removeTestArtifacts(path: [:0]const u8) void {
    _ = unlink(path);
    var journal: [4096]u8 = undefined;
    const j = std.fmt.bufPrintZ(&journal, "{s}-journal", .{path}) catch return;
    _ = unlink(j);
    const w = std.fmt.bufPrintZ(&journal, "{s}-wal", .{path}) catch return;
    _ = unlink(w);
    const s = std.fmt.bufPrintZ(&journal, "{s}-shm", .{path}) catch return;
    _ = unlink(s);
}

fn failingOpen(_: [*:0]const u8, _: c_int, _: c_int) callconv(.c) c_int {
    __errno_location().* = EACCES;
    return -1;
}
fn shortPread(fd: c_int, output: *anyopaque, count: usize, offset: i64) callconv(.c) isize {
    return pread(fd, output, @min(count, 4), offset);
}
fn failingFsync(_: c_int) callconv(.c) c_int {
    __errno_location().* = EACCES;
    return -1;
}

test "active Unix locking variants select source method tails and lock behavior" {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "/tmp/sqlite-zig-variants-{d}", .{getpid()}, 0);
    defer std.testing.allocator.free(path);
    remove(path);
    const open_flags = vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB;

    var none = UnixVfs.initMode(std.testing.allocator, .none);
    const none_a = none.openFile(path, open_flags).file.?;
    const none_b = none.openFile(path, open_flags).file.?;
    try std.testing.expectEqual(vfs.OK, none_a.lock(vfs.LOCK_EXCLUSIVE));
    try std.testing.expectEqual(vfs.OK, none_b.lock(vfs.LOCK_EXCLUSIVE));
    var reserved_out: c_int = -1;
    try std.testing.expectEqual(vfs.OK, none_b.reserved(&reserved_out));
    try std.testing.expectEqual(@as(c_int, 0), reserved_out);
    try std.testing.expectEqual(vfs.OK, none_a.destroy());
    try std.testing.expectEqual(vfs.OK, none_b.destroy());
    var none_adapter = Adapter.init("unix-none", &none);
    var none_abi: AbiFile = undefined;
    try std.testing.expectEqual(vfs.OK, none_adapter.abi.xOpen.?(&none_adapter.abi, path, @ptrCast(&none_abi), open_flags, null));
    try std.testing.expectEqual(@as(c_int, 3), none_abi.base.pMethods.?.iVersion);
    try std.testing.expect(none_abi.base.pMethods.?.xShmMap == null);
    try std.testing.expectEqual(vfs.OK, none_abi.base.pMethods.?.xClose.?(&none_abi.base));

    var dotfile = UnixVfs.initMode(std.testing.allocator, .dotfile);
    const dot_a = dotfile.openFile(path, open_flags).file.?;
    const dot_b = dotfile.openFile(path, open_flags).file.?;
    try std.testing.expectEqual(vfs.OK, dot_a.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.BUSY, dot_b.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, dot_b.reserved(&reserved_out));
    try std.testing.expectEqual(@as(c_int, 1), reserved_out);
    try std.testing.expectEqual(vfs.OK, dot_a.unlock(vfs.LOCK_NONE));
    try std.testing.expectEqual(vfs.OK, dot_b.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, dot_b.unlock(vfs.LOCK_NONE));
    try std.testing.expectEqual(vfs.OK, dot_a.destroy());
    try std.testing.expectEqual(vfs.OK, dot_b.destroy());
    var dot_adapter = Adapter.init("unix-dotfile", &dotfile);
    var dot_abi: AbiFile = undefined;
    try std.testing.expectEqual(vfs.OK, dot_adapter.abi.xOpen.?(&dot_adapter.abi, path, @ptrCast(&dot_abi), open_flags, null));
    try std.testing.expectEqual(@as(c_int, 1), dot_abi.base.pMethods.?.iVersion);
    try std.testing.expect(dot_abi.base.pMethods.?.xShmMap == null);
    try std.testing.expectEqual(vfs.OK, dot_abi.base.pMethods.?.xClose.?(&dot_abi.base));

    var exclusive = UnixVfs.initMode(std.testing.allocator, .exclusive);
    const exclusive_a = exclusive.openFile(path, open_flags).file.?;
    const exclusive_b = exclusive.openFile(path, open_flags).file.?;
    try std.testing.expectEqual(vfs.OK, exclusive_a.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, exclusive_a.unlock(vfs.LOCK_NONE));
    try std.testing.expectEqual(vfs.BUSY, exclusive_b.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, exclusive_a.destroy());
    try std.testing.expectEqual(vfs.OK, exclusive_b.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, exclusive_b.destroy());
    remove(path);
}

test "native Unix file URI short-read mmap and system-call override" {
    const path = "/tmp/sqlite-zig-unix-vfs-unit.db";
    removeTestArtifacts(path);
    defer removeTestArtifacts(path);
    var native = UnixVfs.init(std.testing.allocator);
    var adapter = Adapter.init("zig-unix", &native);
    const opened = native.openFile("file:/tmp/sqlite-zig-unix-vfs-unit.db?mode=rwc", vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB);
    try std.testing.expectEqual(vfs.OK, opened.rc);
    const file = opened.file.?;
    try std.testing.expectEqual(vfs.OK, file.write("abcdefgh", 0));
    try std.testing.expectEqual(vfs.OK, file.sync());
    var bytes: [12]u8 = undefined;
    try std.testing.expectEqual(vfs.IOERR_SHORT_READ, file.read(&bytes, 0));
    try std.testing.expectEqualStrings("abcdefgh", bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[8..]);
    var mapped: ?*anyopaque = null;
    try std.testing.expectEqual(vfs.OK, file.fetch(0, 8, &mapped));
    try std.testing.expect(mapped != null);
    try std.testing.expectEqualStrings("abcdefgh", @as([*]const u8, @ptrCast(mapped.?))[0..8]);
    try std.testing.expectEqual(vfs.OK, file.unfetch(mapped));
    const short_generic: *const fn () callconv(.c) void = @ptrCast(&shortPread);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "pread", short_generic));
    var exact: [8]u8 = undefined;
    try std.testing.expectEqual(vfs.IOERR_SHORT_READ, file.read(&exact, 0));
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "pread", null));
    const sync_generic: *const fn () callconv(.c) void = @ptrCast(&failingFsync);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "fsync", sync_generic));
    try std.testing.expectEqual(vfs.IOERR_FSYNC, file.sync());
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "fsync", null));
    try std.testing.expectEqual(vfs.OK, file.destroy());
    const generic: *const fn () callconv(.c) void = @ptrCast(&failingOpen);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "open", generic));
    var abi_file: AbiFile = undefined;
    try std.testing.expectEqual(vfs.CANTOPEN, adapter.abi.xOpen.?(&adapter.abi, path, @ptrCast(&abi_file), vfs.OPEN_READONLY, null));
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "open", null));
    try std.testing.expect(adapter.abi.xGetSystemCall.?(&adapter.abi, "open") != null);
    try std.testing.expectEqualStrings("open", std.mem.span(adapter.abi.xNextSystemCall.?(&adapter.abi, null).?));
}

test "native Unix OFD database and WAL locks contend across processes" {
    const path = "/tmp/sqlite-zig-unix-vfs-lock.db";
    removeTestArtifacts(path);
    defer removeTestArtifacts(path);
    var native = UnixVfs.init(std.testing.allocator);
    const parent = native.openFile(path, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB).file.?;
    defer _ = parent.destroy();
    try std.testing.expectEqual(vfs.OK, parent.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, parent.lock(vfs.LOCK_RESERVED));
    const pid = fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        var child_vfs = UnixVfs.init(std.heap.c_allocator);
        const child = child_vfs.openFile(path, vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB);
        if (child.rc != vfs.OK) _exit(2);
        const f = child.file.?;
        const shared_rc = f.lock(vfs.LOCK_SHARED);
        const reserved_rc = f.lock(vfs.LOCK_RESERVED);
        _ = f.destroy();
        _exit(if (shared_rc == vfs.OK and reserved_rc == vfs.BUSY) 0 else 3);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(pid, waitpid(pid, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    var pointer: ?*volatile anyopaque = null;
    try std.testing.expectEqual(vfs.OK, parent.shmMapRegion(0, vfs.SHM_REGION_SIZE, 1, &pointer));
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(vfs.OK, parent.shmLock(0, 1, vfs.SHM_LOCK | vfs.SHM_EXCLUSIVE));
    try std.testing.expectEqual(vfs.OK, parent.shmLock(0, 1, vfs.SHM_UNLOCK | vfs.SHM_EXCLUSIVE));
    try std.testing.expectEqual(vfs.OK, parent.shmUnmap(1));
}

test "native Unix process death releases file locks" {
    const path = "/tmp/sqlite-zig-unix-vfs-death.db";
    removeTestArtifacts(path);
    defer removeTestArtifacts(path);
    var parent_vfs = UnixVfs.init(std.testing.allocator);
    const seed = parent_vfs.openFile(path, vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(vfs.OK, seed.destroy());
    const pid = fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        var child_vfs = UnixVfs.init(std.heap.c_allocator);
        const child = child_vfs.openFile(path, vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB).file.?;
        if (child.lock(vfs.LOCK_SHARED) != vfs.OK or child.lock(vfs.LOCK_EXCLUSIVE) != vfs.OK) _exit(4);
        while (true) _ = pause();
    }
    _ = usleep(100_000);
    try std.testing.expectEqual(@as(c_int, 0), kill(pid, 9));
    var status: c_int = 0;
    try std.testing.expectEqual(pid, waitpid(pid, &status, 0));
    const after = parent_vfs.openFile(path, vfs.OPEN_READWRITE | vfs.OPEN_MAIN_DB).file.?;
    defer _ = after.destroy();
    try std.testing.expectEqual(vfs.OK, after.lock(vfs.LOCK_SHARED));
    try std.testing.expectEqual(vfs.OK, after.lock(vfs.LOCK_EXCLUSIVE));
}

test "native Unix VFS runs rollback and WAL pager durability paths" {
    const Pager = pager.Pager;
    const rollback_path = "/tmp/sqlite-zig-unix-rollback.db";
    const wal_path = "/tmp/sqlite-zig-unix-wal.db";
    removeTestArtifacts(rollback_path);
    removeTestArtifacts(wal_path);
    defer removeTestArtifacts(rollback_path);
    defer removeTestArtifacts(wal_path);
    var native = UnixVfs.init(std.testing.allocator);
    var adapter = Adapter.init("zig-unix-pager", &native);
    inline for (.{ .{ "tests/fixtures/pager/valid-two-page-4096.db", rollback_path, false }, .{ "tests/fixtures/wal/base-4096.db", wal_path, true } }) |case| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, case[0], std.testing.allocator, .limited(2 * 1024 * 1024));
        defer std.testing.allocator.free(bytes);
        const installed = native.openFile(case[1], vfs.OPEN_READWRITE | vfs.OPEN_CREATE | vfs.OPEN_MAIN_DB).file.?;
        try std.testing.expectEqual(vfs.OK, installed.truncate(0));
        try std.testing.expectEqual(vfs.OK, installed.write(bytes, 0));
        try std.testing.expectEqual(vfs.OK, installed.sync());
        try std.testing.expectEqual(vfs.OK, installed.destroy());
        var database_pager = Pager.open(std.testing.allocator, &adapter.abi, case[1], .{ .writable = true }).pager.?;
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, database_pager.beginRead());
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, database_pager.beginWrite());
        const got = database_pager.getPage(1, false);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, got.result);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, database_pager.makeWritable(got.page.?));
        got.page.?.data[60] = 0x5a;
        _ = database_pager.release(got.page.?);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, database_pager.commit());
        if (case[2]) _ = database_pager.checkpointWal();
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, database_pager.close());
        var reopened = Pager.open(std.testing.allocator, &adapter.abi, case[1], .{}).pager.?;
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, reopened.beginRead());
        const read = reopened.getPage(1, false);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, read.result);
        try std.testing.expectEqual(@as(u8, 0x5a), read.page.?.data[60]);
        _ = reopened.release(read.page.?);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, reopened.close());
    }
}
