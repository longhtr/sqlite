//! Linux/Unix native VFS for the Phase 15 bounded target profile.
const std = @import("std");
pub const vfs = @import("vfs.zig");
pub const pager = @import("pager.zig");
const logging = @import("logging.zig");
const sqlite_mutex = @import("mutex.zig");

const O_RDONLY = 0;
const O_RDWR = 2;
const O_CREAT = 64;
const O_EXCL = 128;
const O_CLOEXEC = 524288;
const O_DIRECTORY = 65536;
const O_NOFOLLOW = 131072;
const SEEK_END = 2;
const F_GETLK = 5;
const F_SETLK = 6;
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
const UNIX_SHM_BASE: i64 = 120;
const UNIX_SHM_DMS: i64 = 128;
const EPERM = 1;
const ENOENT = 2;
const EINTR = 4;
const EIO = 5;
const ENXIO = 6;
const EAGAIN = 11;
const ENOMEM = 12;
const EACCES = 13;
const EBUSY = 16;
const EEXIST = 17;
const EINVAL = 22;
const ENOSPC = 28;
const ERANGE = 34;
const ENOLCK = 37;
const ETIMEDOUT = 110;
const SQLITE_SYNC_NORMAL = 0x00002;
const SQLITE_SYNC_FULL = 0x00003;
const SQLITE_SYNC_DATAONLY = 0x00010;
const max_path_length: usize = 4096;
const max_symlinks: usize = 200;
const SC_PAGESIZE = 30;
const Flock = extern struct { l_type: i16, l_whence: i16, l_start: i64, l_len: i64, l_pid: i32 };
extern "c" fn open([*:0]const u8, c_int, ...) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn read(c_int, *anyopaque, usize) isize;
extern "c" fn pread(c_int, *anyopaque, usize, i64) isize;
extern "c" fn pwrite(c_int, *const anyopaque, usize, i64) isize;
extern "c" fn fsync(c_int) c_int;
extern "c" fn fdatasync(c_int) c_int;
extern "c" fn ftruncate(c_int, i64) c_int;
extern "c" fn posix_fallocate(c_int, i64, i64) c_int;
extern "c" fn fchmod(c_int, c_uint) c_int;
extern "c" fn fchown(c_int, c_uint, c_uint) c_int;
extern "c" fn lseek(c_int, i64, c_int) i64;
extern "c" fn fcntl(c_int, c_int, ...) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn mkdir([*:0]const u8, c_uint) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn access([*:0]const u8, c_int) c_int;
extern "c" fn getcwd([*]u8, usize) ?[*]u8;
extern "c" fn readlink([*:0]const u8, [*]u8, usize) isize;
extern "c" fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
extern "c" fn munmap(*anyopaque, usize) c_int;
extern "c" fn sysconf(c_int) isize;
extern "c" fn getpid() c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]u8;
extern "c" fn getrandom(*anyopaque, usize, c_uint) isize;
extern "c" fn time(?*i64) i64;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn nanosleep(*const Timespec, ?*Timespec) c_int;
extern "c" fn gettimeofday(*Timeval, ?*anyopaque) c_int;
extern "c" fn strerror_r(c_int, [*]u8, usize) ?[*:0]u8;
extern "c" fn statx(c_int, [*:0]const u8, c_int, c_uint, *Statx) c_int;
extern "c" fn dlopen([*:0]const u8, c_int) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
extern "c" fn dlsym(?*anyopaque, [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(?*anyopaque) c_int;
extern "c" fn __errno_location() *c_int;

const Timespec = extern struct { seconds: i64, nanoseconds: i64 };
const Timeval = extern struct { seconds: i64, microseconds: i64 };

const StatxTimestamp = extern struct {
    seconds: i64,
    nanoseconds: u32,
    reserved: i32,
};

const Statx = extern struct {
    mask: u32,
    block_size: u32,
    attributes: u64,
    link_count: u32,
    uid: u32,
    gid: u32,
    mode: u16,
    reserved0: u16,
    inode: u64,
    size: u64,
    blocks: u64,
    attributes_mask: u64,
    access_time: StatxTimestamp,
    birth_time: StatxTimestamp,
    change_time: StatxTimestamp,
    modification_time: StatxTimestamp,
    device_major: u32,
    device_minor: u32,
    filesystem_major: u32,
    filesystem_minor: u32,
    mount_id: u64,
    direct_io_memory_alignment: u32,
    direct_io_offset_alignment: u32,
    reserved: [12]u64,
};

const UnusedFd = struct {
    fd: c_int,
    flags: c_int,
    next: ?*UnusedFd = null,
};

const ShmNode = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    path: [:0]u8,
    map: ?[]u8 = null,
    reference_count: usize = 1,
    locks: [8]i16 = [_]i16{0} ** 8,
};

const InodeInfo = struct {
    inode: u64,
    device_major: u32,
    device_minor: u32,
    reference_count: usize = 1,
    active_lock_handles: usize = 0,
    lock_counts: [5]usize = [_]usize{0} ** 5,
    lock_level: c_int = vfs.LOCK_NONE,
    process_lock: bool = false,
    unused: ?*UnusedFd = null,
    shm_node: ?*ShmNode = null,
    next: ?*InodeInfo = null,
};

const ProcessMutex = struct {
    inner: sqlite_mutex.Mutex = .{ .kind = .recursive },

    fn lock(self: *ProcessMutex) void {
        self.inner.enter();
    }

    fn unlock(self: *ProcessMutex) void {
        self.inner.leave();
    }
};

var inode_mutex: ProcessMutex = .{};
var inode_head: ?*InodeInfo = null;

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

/// Source `unixLogErrorAtLine()`: preserve errno before formatting and route
/// the complete syscall, path, source-line, and strerror detail through the
/// process SQLite logging callback.
fn unixLogErrorAtLine(error_code: c_int, function_name: []const u8, path: ?[]const u8, source_line: c_int) c_int {
    const saved_errno = errno();
    var error_buffer: [80]u8 = [_]u8{0} ** 80;
    const error_pointer = strerror_r(saved_errno, &error_buffer, error_buffer.len - 1);
    const error_text = if (error_pointer) |text| std.mem.span(text) else error_buffer[0..std.mem.indexOfScalar(u8, &error_buffer, 0).?];
    logging.format(error_code, "os_unix.c:%d: (%d) %s(%s) - %s", &.{
        .{ .signed = source_line },
        .{ .signed = saved_errno },
        .{ .string = function_name },
        .{ .string = path orelse "" },
        .{ .string = error_text },
    });
    return error_code;
}

/// Source `sqliteErrorFromPosixError()`: translate retryable lock failures,
/// permission failures, and all remaining errors without losing the caller's
/// operation-specific extended I/O result.
fn sqliteErrorFromPosixError(posix_error: c_int, sqlite_io_error: c_int) c_int {
    std.debug.assert(sqlite_io_error == vfs.IOERR_LOCK or
        sqlite_io_error == vfs.IOERR_UNLOCK or
        sqlite_io_error == vfs.IOERR_RDLOCK or
        sqlite_io_error == vfs.IOERR_CHECKRESERVEDLOCK);
    if (posix_error == EACCES or posix_error == EAGAIN or
        posix_error == ETIMEDOUT or posix_error == EBUSY or
        posix_error == EINTR or posix_error == ENOLCK)
    {
        return vfs.BUSY;
    }
    if (posix_error == EPERM) return vfs.PERM;
    return sqlite_io_error;
}

fn lockFileRange(file: *UnixFile, typ: i16, start: i64, len: i64) c_int {
    var flock = Flock{ .l_type = typ, .l_whence = 0, .l_start = start, .l_len = len, .l_pid = 0 };
    return unixFileLock(file, &flock);
}

/// Source `unixFileLock()`: acquire the process-wide unix-excl lock once,
/// otherwise pass the requested advisory lock through to fcntl(F_SETLK).
fn unixFileLock(file: *UnixFile, flock: *Flock) c_int {
    const inode = file.inode_info orelse return vfs.IOERR_LOCK;
    if (file.owner.locking_mode == .exclusive and !file.readonly) {
        inode_mutex.lock();
        defer inode_mutex.unlock();
        if (inode.process_lock) return vfs.OK;
        var process_flock = Flock{
            .l_type = F_WRLCK,
            .l_whence = 0,
            .l_start = SHARED,
            .l_len = SHARED_LEN,
            .l_pid = 0,
        };
        if (fcntl(file.fd, F_SETLK, &process_flock) != 0) {
            file.last_errno = errno();
            return sqliteErrorFromPosixError(file.last_errno, vfs.IOERR_LOCK);
        }
        inode.process_lock = true;
        file.exclusive_process_lock = true;
        return vfs.OK;
    }
    if (fcntl(file.fd, F_SETLK, flock) == 0) return vfs.OK;
    file.last_errno = errno();
    return sqliteErrorFromPosixError(file.last_errno, if (flock.l_type == F_UNLCK) vfs.IOERR_UNLOCK else vfs.IOERR_LOCK);
}

/// Source `unixCheckReservedLock()`: consult this process's inode state, then
/// F_GETLK for a reserved-byte lock owned by another process.
fn unixCheckReservedLock(file: *UnixFile, output: *c_int) c_int {
    output.* = 0;
    const inode = file.inode_info orelse return vfs.IOERR_CHECKRESERVEDLOCK;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    if (inode.lock_level > vfs.LOCK_SHARED or inode.process_lock) {
        output.* = 1;
        return vfs.OK;
    }
    var flock = Flock{
        .l_type = F_WRLCK,
        .l_whence = 0,
        .l_start = RESERVED,
        .l_len = 1,
        .l_pid = 0,
    };
    if (fcntl(file.fd, F_GETLK, &flock) != 0) {
        file.last_errno = errno();
        return vfs.IOERR_CHECKRESERVEDLOCK;
    }
    output.* = @intFromBool(flock.l_type != F_UNLCK);
    return vfs.OK;
}

/// Source `dotlockCheckReservedLock()`: a held local dot lock excludes other
/// owners; without one, existence of the lock directory means reserved.
fn dotlockCheckReservedLock(file: *UnixFile, output: *c_int) c_int {
    output.* = if (file.lock_level >= vfs.LOCK_SHARED)
        0
    else
        @intFromBool(access(file.dotlock_path.?.ptr, 0) == 0);
    return vfs.OK;
}

/// Source `dotlockLock()`: collapse all SQLite lock levels into ownership of
/// the dot-lock directory while retaining the requested logical level.
fn dotlockLock(file: *UnixFile, target: c_int) c_int {
    if (file.lock_level > vfs.LOCK_NONE) {
        updateLockLevel(file, target);
        return vfs.OK;
    }
    if (mkdir(file.dotlock_path.?.ptr, 0o777) != 0) {
        const failure = errno();
        if (failure == EEXIST) return vfs.BUSY;
        file.last_errno = failure;
        return sqliteErrorFromPosixError(failure, vfs.IOERR_LOCK);
    }
    file.dotlock_held = true;
    updateLockLevel(file, target);
    return vfs.OK;
}

/// Source `dotlockUnlock()`: logical downgrade is in-memory; full unlock
/// removes the lock directory and tolerates an already-absent directory.
fn dotlockUnlock(file: *UnixFile, target: c_int) c_int {
    if (file.lock_level == target) return vfs.OK;
    if (target == vfs.LOCK_SHARED) {
        updateLockLevel(file, target);
        return vfs.OK;
    }
    std.debug.assert(target == vfs.LOCK_NONE);
    if (rmdir(file.dotlock_path.?.ptr) != 0 and errno() != ENOENT) {
        file.last_errno = errno();
        return vfs.IOERR_UNLOCK;
    }
    file.dotlock_held = false;
    updateLockLevel(file, target);
    return vfs.OK;
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

const DbPath = struct {
    rc: c_int = vfs.OK,
    symlink_count: usize = 0,
    output: []u8,
    used: usize = 0,
};

/// Source `appendOnePathElement()`: normalize one component and recursively
/// resolve relative or absolute symbolic-link targets.
fn appendOnePathElement(path: *DbPath, name: []const u8) void {
    std.debug.assert(name.len > 0);
    if (name[0] == '.') {
        if (name.len == 1) return;
        if (name.len == 2 and name[1] == '.') {
            if (path.used > 1) {
                std.debug.assert(path.output[0] == '/');
                path.used -= 1;
                while (path.output[path.used] != '/') {
                    path.used -= 1;
                }
            }
            return;
        }
    }
    if (path.used + name.len + 2 >= path.output.len) {
        path.rc = vfs.ERROR;
        return;
    }
    path.output[path.used] = '/';
    path.used += 1;
    @memcpy(path.output[path.used..][0..name.len], name);
    path.used += name.len;
    if (path.rc != vfs.OK) return;

    path.output[path.used] = 0;
    var target: [max_path_length + 2]u8 = undefined;
    const got = readlink(@ptrCast(path.output.ptr), &target, target.len - 2);
    if (got < 0) {
        const failure = errno();
        if (failure != ENOENT and failure != EINVAL) {
            path.rc = vfs.CANTOPEN;
        }
        return;
    }
    const target_length: usize = @intCast(got);
    if (target_length == 0 or target_length >= target.len - 2) {
        path.rc = vfs.CANTOPEN;
        return;
    }
    if (path.symlink_count > max_symlinks) {
        path.rc = vfs.CANTOPEN;
        return;
    }
    path.symlink_count += 1;
    if (target[0] == '/') {
        path.used = 0;
    } else {
        path.used -= name.len + 1;
    }
    appendAllPathElements(path, target[0..target_length]);
}

/// Source `appendAllPathElements()` component iteration.
fn appendAllPathElements(path: *DbPath, input: []const u8) void {
    var start: usize = 0;
    var end: usize = 0;
    while (true) {
        while (end < input.len and input[end] != '/') {
            end += 1;
        }
        if (end > start) appendOnePathElement(path, input[start..end]);
        if (end == input.len) break;
        end += 1;
        start = end;
    }
}

/// Source `unixFullPathname()`: anchor relative paths at cwd, normalize path
/// elements, preserve missing final paths, and report resolved symlinks.
fn unixFullPathname(input: []const u8, output: []u8) c_int {
    if (output.len == 0) return vfs.CANTOPEN;
    var path = DbPath{ .output = output };
    if (input.len == 0 or input[0] != '/') {
        var cwd: [max_path_length + 2]u8 = undefined;
        const got = getcwd(&cwd, cwd.len - 2) orelse return vfs.CANTOPEN;
        appendAllPathElements(&path, std.mem.span(@as([*:0]u8, @ptrCast(got))));
    }
    appendAllPathElements(&path, input);
    output[path.used] = 0;
    if (path.rc != vfs.OK or path.used < 2) return vfs.CANTOPEN;
    if (path.symlink_count != 0) return vfs.OK_SYMLINK;
    return vfs.OK;
}

/// Source `robust_ftruncate()` EINTR retry loop.
fn robustFtruncate(fd: c_int, size: i64) c_int {
    while (true) {
        const result = ftruncate(fd, size);
        if (result >= 0 or errno() != EINTR) return result;
    }
}

/// Source `seekAndRead()`: retry interrupted reads, accumulate partial reads,
/// advance both buffer and file offset, and preserve the terminal errno.
fn seekAndRead(file: *UnixFile, offset_initial: i64, output: []u8) isize {
    std.debug.assert(output.len <= 0x1ffff);
    std.debug.assert(file.fd > 2);
    var offset = offset_initial;
    var prior: usize = 0;
    while (prior < output.len) {
        const got = file.owner.preadFd(file.fd, output.ptr + prior, output.len - prior, offset);
        if (got == @as(isize, @intCast(output.len - prior))) return @intCast(output.len);
        if (got < 0) {
            if (errno() == EINTR) continue;
            file.last_errno = errno();
            return -1;
        }
        if (got == 0) break;
        prior += @intCast(got);
        offset += @intCast(got);
    }
    return @intCast(prior);
}

/// Source `seekAndWriteFd()`: one positioned write with EINTR retry and
/// explicit errno transfer to the owning Unix file state.
fn seekAndWriteFd(owner: *UnixVfs, fd: c_int, offset: i64, input: []const u8, error_out: *c_int) isize {
    std.debug.assert(input.len <= 0x1ffff);
    std.debug.assert(fd > 2);
    while (true) {
        const result = owner.pwriteFd(fd, input.ptr, input.len & 0x1ffff, offset);
        if (result < 0 and errno() == EINTR) continue;
        if (result < 0) error_out.* = errno();
        return result;
    }
}

/// Source `full_fsync()` for the pinned Linux profile. `fdatasync()` is
/// sufficient even when metadata is requested because SQLite only relies on
/// file-size durability, which Linux fdatasync preserves.
fn fullFsync(owner: *UnixVfs, fd: c_int, full_sync: bool, data_only: bool) c_int {
    _ = full_sync;
    _ = data_only;
    return owner.fdatasyncFd(fd);
}

/// Source `openDirectory()`: derive and robustly open the parent directory
/// used to make create/delete directory entries durable.
fn openDirectory(owner: *UnixVfs, filename: []const u8, fd_out: *c_int) c_int {
    var directory_buffer: [max_path_length + 1]u8 = undefined;
    const copied = @min(filename.len, max_path_length - 1);
    @memcpy(directory_buffer[0..copied], filename[0..copied]);
    directory_buffer[copied] = 0;
    var slash = copied;
    while (slash > 0 and directory_buffer[slash] != '/') {
        slash -= 1;
    }
    if (slash > 0) {
        directory_buffer[slash] = 0;
    } else {
        directory_buffer[0] = if (copied > 0 and directory_buffer[0] == '/') '/' else '.';
        directory_buffer[1] = 0;
    }
    const directory: [*:0]const u8 = @ptrCast(&directory_buffer);
    const fd = owner.robustOpen(directory, O_RDONLY, 0);
    fd_out.* = fd;
    if (fd >= 0) return vfs.OK;
    return unixLogErrorAtLine(vfs.CANTOPEN, "openDirectory", std.mem.span(directory), @intCast(@src().line));
}

const var_tmp: [*:0]const u8 = "/var/tmp";
const usr_tmp: [*:0]const u8 = "/usr/tmp";
const system_tmp: [*:0]const u8 = "/tmp";
const current_directory: [*:0]const u8 = ".";
const empty_path: [*:0]const u8 = "";

/// Source `unixTempFileDir()`: honor SQLite and process environment choices
/// before the fixed Unix fallback list, requiring a writable directory.
fn unixTempFileDir() ?[*:0]const u8 {
    const candidates = [_]?[*:0]const u8{
        if (getenv("SQLITE_TMPDIR")) |value| value else null,
        if (getenv("TMPDIR")) |value| value else null,
        var_tmp,
        usr_tmp,
        system_tmp,
        current_directory,
    };
    for (candidates) |candidate_optional| {
        const candidate = candidate_optional orelse continue;
        if (access(candidate, 3) != 0) continue;
        const directory_fd = open(candidate, O_RDONLY | O_DIRECTORY | O_CLOEXEC, @as(c_int, 0));
        if (directory_fd < 0) continue;
        _ = close(directory_fd);
        return candidate;
    }
    return null;
}

/// Source `unixGetTempname()`: generate collision-resistant SQLite temporary
/// names in the selected directory and preserve the ten-retry bound.
fn unixGetTempname(output: []u8) c_int {
    if (output.len < 3) return vfs.ERROR;
    output[0] = 0;
    const directory = unixTempFileDir() orelse return vfs.IOERR_GETTEMPPATH;
    var attempt: usize = 0;
    while (attempt <= 10) : (attempt += 1) {
        var random_value: u64 = undefined;
        if (getrandom(&random_value, @sizeOf(u64), 0) != @sizeOf(u64)) {
            random_value = @as(u64, @bitCast(time(null))) ^ @as(u64, @intCast(getpid())) ^ attempt;
        }
        const rendered = std.fmt.bufPrintZ(output, "{s}/etilqs_{x}", .{ std.mem.span(directory), random_value }) catch return vfs.ERROR;
        if (access(rendered, 0) != 0) return vfs.OK;
    }
    return vfs.ERROR;
}

/// Source `getFileMode()`: obtain the permission bits and ownership of an
/// existing file through Linux's architecture-stable statx ABI.
fn getFileMode(filename: [*:0]const u8, mode_out: *u32, uid_out: *u32, gid_out: *u32) c_int {
    var status: Statx = undefined;
    if (statx(-100, filename, 0, 0x7ff, &status) != 0) return vfs.IOERR_FSTAT;
    mode_out.* = status.mode & 0o777;
    uid_out.* = status.uid;
    gid_out.* = status.gid;
    return vfs.OK;
}

fn queryParameter(uri: []const u8, key: []const u8) ?[]const u8 {
    const question = std.mem.indexOfScalar(u8, uri, '?') orelse return null;
    var rest = uri[question + 1 ..];
    while (rest.len != 0) {
        const separator = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const parameter = rest[0..separator];
        if (std.mem.indexOfScalar(u8, parameter, '=')) |equals| {
            if (std.mem.eql(u8, parameter[0..equals], key)) return parameter[equals + 1 ..];
        }
        if (separator == rest.len) break;
        rest = rest[separator + 1 ..];
    }
    return null;
}

/// Source `findCreateFileMode()`: copy database ownership to WAL/journal
/// sidecars, force private delete-on-close files, and honor URI `modeof`.
fn findCreateFileMode(path: []const u8, flags: c_int, mode_out: *u32, uid_out: *u32, gid_out: *u32) c_int {
    mode_out.* = 0;
    uid_out.* = 0;
    gid_out.* = 0;
    if (flags & (vfs.OPEN_WAL | vfs.OPEN_MAIN_JOURNAL) != 0) {
        if (path.len == 0) return vfs.OK;
        var database_length = path.len - 1;
        while (database_length > 0 and path[database_length] != '.') : (database_length -= 1) {
            if (path[database_length] == '-') {
                var database_path: [max_path_length + 1]u8 = undefined;
                if (database_length >= database_path.len) return vfs.CANTOPEN;
                @memcpy(database_path[0..database_length], path[0..database_length]);
                database_path[database_length] = 0;
                return getFileMode(@ptrCast(&database_path), mode_out, uid_out, gid_out);
            }
        }
    } else if (flags & vfs.OPEN_DELETEONCLOSE != 0) {
        mode_out.* = 0o600;
    } else if (flags & vfs.OPEN_URI != 0) {
        if (queryParameter(path, "modeof")) |mode_path| {
            var terminated: [max_path_length + 1]u8 = undefined;
            if (mode_path.len >= terminated.len) return vfs.CANTOPEN;
            @memcpy(terminated[0..mode_path.len], mode_path);
            terminated[mode_path.len] = 0;
            return getFileMode(@ptrCast(&terminated), mode_out, uid_out, gid_out);
        }
    }
    return vfs.OK;
}

/// Source `unixFcntlExternalReader()`: query WAL read-lock bytes for locks
/// owned by another process.
fn unixFcntlExternalReader(file: *UnixFile, output: *c_int) c_int {
    output.* = 0;
    if (file.shm_fd < 0) return vfs.OK;
    var flock = Flock{
        .l_type = F_WRLCK,
        .l_whence = 0,
        .l_start = UNIX_SHM_BASE + 3,
        .l_len = 5,
        .l_pid = 0,
    };
    if (fcntl(file.shm_fd, F_GETLK, &flock) < 0) return vfs.IOERR_LOCK;
    output.* = @intFromBool(flock.l_type != F_UNLCK);
    return vfs.OK;
}

/// Source `unixIsSharingShmNode()`: probe the WAL dead-man-switch byte for
/// another process sharing the same shared-memory file.
fn unixIsSharingShmNode(file: *UnixFile) bool {
    if (file.shm_fd < 0 or file.owner.locking_mode == .exclusive) return false;
    var flock = Flock{
        .l_type = F_WRLCK,
        .l_whence = 0,
        .l_start = UNIX_SHM_DMS,
        .l_len = 1,
        .l_pid = 0,
    };
    if (fcntl(file.shm_fd, F_GETLK, &flock) < 0) return false;
    return flock.l_type != F_UNLCK;
}

/// Source `unixShmSystemLock()`: validate WAL lock ranges and apply one
/// non-blocking advisory lock operation to the shared-memory descriptor.
fn unixShmSystemLock(file: *UnixFile, lock_type: i16, offset: i64, count: c_int) c_int {
    std.debug.assert((offset == UNIX_SHM_DMS and count == 1) or
        (offset >= UNIX_SHM_BASE and offset + @as(i64, count) <= UNIX_SHM_BASE + 8));
    std.debug.assert(count == 1 or lock_type != F_RDLCK);
    std.debug.assert(count >= 1 and count <= 8);
    if (file.shm_fd < 0) return vfs.OK;
    var flock = Flock{
        .l_type = lock_type,
        .l_whence = 0,
        .l_start = offset,
        .l_len = @intCast(count),
        .l_pid = 0,
    };
    return if (fcntl(file.shm_fd, F_SETLK, &flock) == 0) vfs.OK else sqliteErrorFromPosixError(errno(), vfs.IOERR_SHMLOCK);
}

/// Source `unixLockSharedMemory()`: serialize first attachment with the DMS
/// byte, truncate stale shared memory, then retain a shared DMS lock.
fn unixLockSharedMemory(file: *UnixFile) c_int {
    std.debug.assert(file.shm_fd >= 0);
    var probe = Flock{
        .l_type = F_WRLCK,
        .l_whence = 0,
        .l_start = UNIX_SHM_DMS,
        .l_len = 1,
        .l_pid = 0,
    };
    if (fcntl(file.shm_fd, F_GETLK, &probe) != 0) return vfs.IOERR_LOCK;
    var result = vfs.OK;
    if (probe.l_type == F_UNLCK) {
        result = unixShmSystemLock(file, F_WRLCK, UNIX_SHM_DMS, 1);
        if (result == vfs.OK and robustFtruncate(file.shm_fd, 3) != 0) {
            result = unixLogErrorAtLine(vfs.IOERR_SHMOPEN, "ftruncate", if (file.shm_path) |path| path else null, @intCast(@src().line));
        }
    } else if (probe.l_type == F_WRLCK) {
        result = vfs.BUSY;
    }
    if (result == vfs.OK) result = unixShmSystemLock(file, F_RDLCK, UNIX_SHM_DMS, 1);
    return result;
}

/// Source `setDeviceCharacteristics()` for the pinned non-QNX profile.
fn setDeviceCharacteristics(file: *UnixFile) void {
    std.debug.assert(file.device_characteristics == 0 or file.sector_size != 0);
    if (file.sector_size != 0) return;
    if (file.powersafe_overwrite) file.device_characteristics |= 0x0000_1000;
    file.device_characteristics |= 0x0000_8000;
    file.sector_size = 4096;
}

fn captureFileIdentity(file: *UnixFile) void {
    var status: Statx = undefined;
    if (statx(file.fd, empty_path, 0x1000, 0x7ff, &status) != 0) return;
    file.inode = status.inode;
    file.device_major = status.device_major;
    file.device_minor = status.device_minor;
}

/// Source `closePendingFds()`: release every descriptor deferred while a
/// sibling handle retained process-level locks on the inode.
fn closePendingFds(file: *UnixFile, inode: *InodeInfo) void {
    var unused = inode.unused;
    while (unused) |entry| {
        const next = entry.next;
        if (close(entry.fd) != 0) {
            _ = unixLogErrorAtLine(vfs.IOERR_CLOSE, "close", file.path, @intCast(@src().line));
        }
        std.heap.c_allocator.destroy(entry);
        unused = next;
    }
    inode.unused = null;
}

/// Source `releaseInodeInfo()`: unlink and destroy an unreferenced inode
/// owner after draining deferred descriptors.
fn releaseInodeInfo(file: *UnixFile) void {
    const inode = file.inode_info orelse return;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    std.debug.assert(inode.reference_count > 0);
    inode.reference_count -= 1;
    if (inode.reference_count != 0) {
        file.inode_info = null;
        return;
    }
    closePendingFds(file, inode);
    var previous: ?*InodeInfo = null;
    var current = inode_head;
    while (current) |candidate| : (current = candidate.next) {
        if (candidate == inode) {
            if (previous) |prior| {
                prior.next = candidate.next;
            } else {
                inode_head = candidate.next;
            }
            break;
        }
        previous = candidate;
    }
    file.inode_info = null;
    std.heap.c_allocator.destroy(inode);
}

/// Source `findInodeInfo()`: attach a process-global owner keyed by device
/// and inode identity, creating it on first use.
fn findInodeInfo(file: *UnixFile) c_int {
    var status: Statx = undefined;
    if (statx(file.fd, empty_path, 0x1000, 0x7ff, &status) != 0) {
        file.last_errno = errno();
        return vfs.IOERR;
    }
    inode_mutex.lock();
    defer inode_mutex.unlock();
    var current = inode_head;
    while (current) |inode| : (current = inode.next) {
        if (inode.inode == status.inode and inode.device_major == status.device_major and inode.device_minor == status.device_minor) {
            inode.reference_count += 1;
            file.inode_info = inode;
            return vfs.OK;
        }
    }
    const inode = std.heap.c_allocator.create(InodeInfo) catch return vfs.NOMEM;
    inode.* = .{
        .inode = status.inode,
        .device_major = status.device_major,
        .device_minor = status.device_minor,
        .next = inode_head,
    };
    inode_head = inode;
    file.inode_info = inode;
    return vfs.OK;
}

/// Source `findReusableFd()`: detach a compatible deferred descriptor for
/// the same device/inode pair.
fn findReusableFd(path: [*:0]const u8, flags: c_int) ?*UnusedFd {
    var status: Statx = undefined;
    if (statx(-100, path, 0, 0x7ff, &status) != 0) return null;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    var inode = inode_head;
    while (inode) |candidate| : (inode = candidate.next) {
        if (candidate.inode != status.inode or candidate.device_major != status.device_major or candidate.device_minor != status.device_minor) continue;
        const wanted = flags & (vfs.OPEN_READONLY | vfs.OPEN_READWRITE);
        var previous: ?*UnusedFd = null;
        var unused = candidate.unused;
        while (unused) |entry| : (unused = entry.next) {
            if (entry.flags == wanted) {
                if (previous) |prior| {
                    prior.next = entry.next;
                } else {
                    candidate.unused = entry.next;
                }
                entry.next = null;
                return entry;
            }
            previous = entry;
        }
        break;
    }
    return null;
}

fn retireFileDescriptor(file: *UnixFile) void {
    const inode = file.inode_info orelse return;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    if (inode.active_lock_handles > 0 and file.fd >= 0) {
        const unused_optional = std.heap.c_allocator.create(UnusedFd) catch null;
        if (unused_optional) |unused| {
            unused.* = .{
                .fd = file.fd,
                .flags = if (file.readonly) vfs.OPEN_READONLY else vfs.OPEN_READWRITE,
                .next = inode.unused,
            };
            inode.unused = unused;
            file.fd = -1;
        }
    }
}

fn updateLockLevel(file: *UnixFile, target: c_int) void {
    const prior = file.lock_level;
    if (prior == target) return;
    if (file.inode_info) |inode| {
        inode_mutex.lock();
        defer inode_mutex.unlock();
        if (prior > vfs.LOCK_NONE) {
            const prior_index: usize = @intCast(prior);
            std.debug.assert(inode.lock_counts[prior_index] > 0);
            inode.lock_counts[prior_index] -= 1;
        }
        if (target > vfs.LOCK_NONE) {
            inode.lock_counts[@intCast(target)] += 1;
        }
        inode.active_lock_handles = 0;
        inode.lock_level = vfs.LOCK_NONE;
        var level: usize = 1;
        while (level < inode.lock_counts.len) : (level += 1) {
            inode.active_lock_handles += inode.lock_counts[level];
            if (inode.lock_counts[level] != 0) inode.lock_level = @intCast(level);
        }
        if (inode.active_lock_handles == 0) closePendingFds(file, inode);
    }
    file.lock_level = target;
}

/// Source `unixLock()`: preserve SQLite's pending-byte transition, process-
/// local inode conflict checks, shared-lock reference reuse, and the pending
/// state left behind when an exclusive upgrade remains busy.
fn unixLock(file: *UnixFile, target: c_int) c_int {
    if (target <= file.lock_level) return vfs.OK;
    std.debug.assert(file.lock_level != vfs.LOCK_NONE or target == vfs.LOCK_SHARED);
    std.debug.assert(target != vfs.LOCK_PENDING);
    std.debug.assert(target != vfs.LOCK_RESERVED or file.lock_level == vfs.LOCK_SHARED);
    const inode = file.inode_info orelse return vfs.IOERR_LOCK;
    inode_mutex.lock();
    defer inode_mutex.unlock();

    if (file.lock_level != inode.lock_level and
        (inode.lock_level >= vfs.LOCK_PENDING or target > vfs.LOCK_SHARED))
    {
        return vfs.BUSY;
    }
    if (target == vfs.LOCK_SHARED and
        (inode.lock_level == vfs.LOCK_SHARED or inode.lock_level == vfs.LOCK_RESERVED))
    {
        updateLockLevel(file, vfs.LOCK_SHARED);
        return vfs.OK;
    }

    var rc = vfs.OK;
    if (target == vfs.LOCK_SHARED or
        (target == vfs.LOCK_EXCLUSIVE and file.lock_level == vfs.LOCK_RESERVED))
    {
        const pending_type: i16 = if (target == vfs.LOCK_SHARED) F_RDLCK else F_WRLCK;
        rc = lockFileRange(file, pending_type, PENDING, 1);
        if (rc != vfs.OK) return rc;
        if (target == vfs.LOCK_EXCLUSIVE) updateLockLevel(file, vfs.LOCK_PENDING);
    }

    if (target == vfs.LOCK_SHARED) {
        rc = lockFileRange(file, F_RDLCK, SHARED, SHARED_LEN);
        const unlock_pending = lockFileRange(file, F_UNLCK, PENDING, 1);
        if (rc == vfs.OK and unlock_pending != vfs.OK) rc = vfs.IOERR_UNLOCK;
    } else if (target == vfs.LOCK_EXCLUSIVE and inode.active_lock_handles > 1) {
        rc = vfs.BUSY;
    } else if (target == vfs.LOCK_EXCLUSIVE and unixIsSharingShmNode(file)) {
        rc = vfs.BUSY;
    } else if (target == vfs.LOCK_RESERVED) {
        rc = lockFileRange(file, F_WRLCK, RESERVED, 1);
    } else if (target == vfs.LOCK_EXCLUSIVE) {
        rc = lockFileRange(file, F_WRLCK, SHARED, SHARED_LEN);
    } else {
        unreachable;
    }
    if (rc == vfs.OK) updateLockLevel(file, target);
    return rc;
}

/// Source `posixUnlock()`: downgrade exclusive locks before clearing pending
/// and reserved bytes, retain process-level shared locks for sibling handles,
/// and drain deferred descriptors after the final logical lock closes.
fn posixUnlock(file: *UnixFile, target: c_int) c_int {
    std.debug.assert(target == vfs.LOCK_NONE or target == vfs.LOCK_SHARED);
    if (file.lock_level <= target) return vfs.OK;
    const inode = file.inode_info orelse return vfs.IOERR_UNLOCK;
    inode_mutex.lock();
    defer inode_mutex.unlock();

    if (file.lock_level > vfs.LOCK_SHARED) {
        if (target == vfs.LOCK_SHARED) {
            const downgrade = lockFileRange(file, F_RDLCK, SHARED, SHARED_LEN);
            if (downgrade != vfs.OK) {
                file.last_errno = errno();
                return vfs.IOERR_RDLOCK;
            }
        }
        const release_pending = lockFileRange(file, F_UNLCK, PENDING, 2);
        if (release_pending != vfs.OK) return vfs.IOERR_UNLOCK;
    }
    if (target == vfs.LOCK_NONE and inode.active_lock_handles <= 1) {
        const release_all = lockFileRange(file, F_UNLCK, 0, 0);
        if (release_all != vfs.OK) return vfs.IOERR_UNLOCK;
        inode.process_lock = false;
        file.exclusive_process_lock = false;
    }
    updateLockLevel(file, target);
    return vfs.OK;
}

/// Source `fileHasMoved()`: compare the opened inode identity with the
/// current path after rename or unlink operations.
fn fileHasMoved(file: *UnixFile) bool {
    if (file.inode == 0) return false;
    var status: Statx = undefined;
    if (statx(-100, file.path, 0, 0x7ff, &status) != 0) return true;
    return status.inode != file.inode or status.device_major != file.device_major or status.device_minor != file.device_minor;
}

/// Source `verifyDbFile()`: warn for unlinked, multiply linked, or renamed
/// main database handles immediately before close.
fn verifyDbFile(file: *UnixFile) void {
    if (!file.is_database or file.owner.locking_mode == .none) return;
    var status: Statx = undefined;
    if (statx(file.fd, empty_path, 0x1000, 0x7ff, &status) != 0) {
        logging.format(vfs.WARNING, "cannot fstat db file %s", &.{.{ .string = file.path }});
        return;
    }
    if (status.link_count == 0) {
        logging.format(vfs.WARNING, "file unlinked while open: %s", &.{.{ .string = file.path }});
        return;
    }
    if (status.link_count > 1) {
        logging.format(vfs.WARNING, "multiple links to file: %s", &.{.{ .string = file.path }});
        return;
    }
    if (fileHasMoved(file)) {
        logging.format(vfs.WARNING, "file renamed while open: %s", &.{.{ .string = file.path }});
    }
}

/// Source `fcntlSizeHint()`: round growth to the configured chunk and use
/// Linux posix_fallocate without treating unsupported allocation as fatal.
fn fcntlSizeHint(file: *UnixFile, requested_size: i64) c_int {
    if (file.chunk_size > 0) {
        const current_size = lseek(file.fd, 0, SEEK_END);
        if (current_size < 0) return vfs.IOERR_FSTAT;
        const rounded_input = std.math.add(i64, requested_size, file.chunk_size - 1) catch return vfs.IOERR_WRITE;
        const allocation_size = @divTrunc(rounded_input, file.chunk_size) * file.chunk_size;
        if (allocation_size > current_size) {
            var failure: c_int = 0;
            while (true) {
                failure = posix_fallocate(file.fd, current_size, allocation_size - current_size);
                if (failure != EINTR) break;
            }
            if (failure != 0 and failure != EINVAL) return vfs.IOERR_WRITE;
        }
    }
    if (file.mmap_size_max > 0 and requested_size > file.mmap_size) {
        if (file.chunk_size <= 0 and robustFtruncate(file.fd, requested_size) != 0) {
            file.last_errno = errno();
            return unixLogErrorAtLine(vfs.IOERR_TRUNCATE, "ftruncate", file.path, @intCast(@src().line));
        }
    }
    return vfs.OK;
}

fn unixModeBit(value: *bool, argument: *c_int) void {
    if (argument.* < 0) {
        argument.* = @intFromBool(value.*);
    } else {
        value.* = argument.* != 0;
    }
}

/// Source `unixFileControl()` active-profile control surface.
fn unixFileControl(file: *UnixFile, operation: c_int, argument: ?*anyopaque) c_int {
    const raw = argument orelse return vfs.ERROR;
    if (operation == vfs.FCNTL_NULL_IO) {
        if (file.fd >= 0) _ = close(file.fd);
        file.fd = -1;
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_LOCKSTATE) {
        const output: *c_int = @ptrCast(@alignCast(raw));
        output.* = file.lock_level;
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_LAST_ERRNO) {
        const output: *c_int = @ptrCast(@alignCast(raw));
        output.* = file.last_errno;
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_CHUNK_SIZE) {
        const input: *c_int = @ptrCast(@alignCast(raw));
        file.chunk_size = input.*;
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_SIZE_HINT) {
        const input: *i64 = @ptrCast(@alignCast(raw));
        return fcntlSizeHint(file, input.*);
    }
    if (operation == vfs.FCNTL_PERSIST_WAL) {
        unixModeBit(&file.persist_wal, @ptrCast(@alignCast(raw)));
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_POWERSAFE_OVERWRITE) {
        unixModeBit(&file.powersafe_overwrite, @ptrCast(@alignCast(raw)));
        file.sector_size = 0;
        file.device_characteristics = 0;
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_VFSNAME) {
        const output: *?[*:0]u8 = @ptrCast(@alignCast(raw));
        const copy = file.owner.allocator.dupeZ(u8, std.mem.span(file.owner.vfs_name)) catch return vfs.NOMEM;
        output.* = copy.ptr;
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_TEMPFILENAME) {
        const output: *?[*:0]u8 = @ptrCast(@alignCast(raw));
        const buffer = file.owner.allocator.alloc(u8, max_path_length + 1) catch return vfs.NOMEM;
        if (unixGetTempname(buffer) != vfs.OK) {
            file.owner.allocator.free(buffer);
            return vfs.IOERR_GETTEMPPATH;
        }
        output.* = @ptrCast(buffer.ptr);
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_HAS_MOVED) {
        const output: *c_int = @ptrCast(@alignCast(raw));
        output.* = @intFromBool(fileHasMoved(file));
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_MMAP_SIZE) {
        const limit: *i64 = @ptrCast(@alignCast(raw));
        const requested = limit.*;
        limit.* = file.mmap_size_max;
        if (requested >= 0 and requested != file.mmap_size_max and file.fetch_count == 0) {
            file.mmap_size_max = requested;
            if (file.fetch_map) |mapping| {
                _ = munmap(mapping.ptr, mapping.len);
                file.fetch_map = null;
                file.fetch_return = null;
                file.mmap_size = 0;
            }
        }
        return vfs.OK;
    }
    if (operation == vfs.FCNTL_EXTERNAL_READER) {
        return unixFcntlExternalReader(file, @ptrCast(@alignCast(raw)));
    }
    return vfs.NOTFOUND;
}

/// Source `unixRead()`: satisfy mapped prefixes first, classify corrupt
/// filesystem read failures, and zero-fill short reads.
fn unixRead(file: *UnixFile, output_initial: []u8, offset_initial: i64) c_int {
    std.debug.assert(offset_initial >= 0 and output_initial.len > 0);
    var output = output_initial;
    var offset = offset_initial;
    if (file.fetch_map) |mapping| {
        if (offset < file.mmap_size) {
            const available: usize = @intCast(file.mmap_size - offset);
            const copied = @min(output.len, available);
            @memcpy(output[0..copied], mapping[@intCast(offset)..][0..copied]);
            if (copied == output.len) return vfs.OK;
            output = output[copied..];
            offset += @intCast(copied);
        }
    }
    const amount = seekAndRead(file, offset, output);
    if (amount == @as(isize, @intCast(output.len))) return vfs.OK;
    if (amount < 0) {
        return switch (file.last_errno) {
            ERANGE, EIO, ENXIO => vfs.IOERR_CORRUPTFS,
            else => vfs.IOERR_READ,
        };
    }
    file.last_errno = 0;
    @memset(output[@intCast(amount)..], 0);
    return vfs.IOERR_SHORT_READ;
}

/// Source `unixWrite()`: finish partial positioned writes and distinguish
/// ordinary I/O failures from disk-full or zero-progress writes.
fn unixWrite(file: *UnixFile, input_initial: []const u8, offset_initial: i64) c_int {
    std.debug.assert(input_initial.len > 0);
    if (file.readonly) return vfs.IOERR_WRITE;
    var input = input_initial;
    var offset = offset_initial;
    while (input.len > 0) {
        const amount = seekAndWriteFd(file.owner, file.fd, offset, input, &file.last_errno);
        if (amount < 0) {
            if (file.last_errno != ENOSPC) return vfs.IOERR_WRITE;
            file.last_errno = 0;
            return vfs.FULL;
        }
        if (amount == 0) {
            file.last_errno = 0;
            return vfs.FULL;
        }
        const written: usize = @intCast(amount);
        input = input[written..];
        offset += amount;
    }
    return vfs.OK;
}

/// Source `unixSync()`: honor full/data-only sync flags and perform the
/// one-shot containing-directory sync requested for newly created files.
fn unixSync(file: *UnixFile, flags: c_int) c_int {
    const kind = flags & 0x0f;
    std.debug.assert(kind == SQLITE_SYNC_NORMAL or kind == SQLITE_SYNC_FULL);
    const data_only = flags & SQLITE_SYNC_DATAONLY != 0;
    if (fullFsync(file.owner, file.fd, kind == SQLITE_SYNC_FULL, data_only) != 0) {
        file.last_errno = errno();
        return unixLogErrorAtLine(vfs.IOERR_FSYNC, "full_fsync", file.path, @intCast(@src().line));
    }
    if (file.directory_sync) {
        var directory_fd: c_int = -1;
        if (openDirectory(file.owner, file.path, &directory_fd) == vfs.OK and directory_fd >= 0) {
            _ = fullFsync(file.owner, directory_fd, false, false);
            _ = close(directory_fd);
        }
        file.directory_sync = false;
    }
    return vfs.OK;
}

/// Source `unixTruncate()`: round to the configured chunk size, preserve
/// errno on failure, and contract the effective mapping after success.
fn unixTruncate(file: *UnixFile, requested_size: i64) c_int {
    var size = requested_size;
    if (file.chunk_size > 0) {
        const rounded = std.math.add(i64, size, file.chunk_size - 1) catch return vfs.IOERR_TRUNCATE;
        size = @divTrunc(rounded, file.chunk_size) * file.chunk_size;
    }
    if (robustFtruncate(file.fd, size) != 0) {
        file.last_errno = errno();
        return unixLogErrorAtLine(vfs.IOERR_TRUNCATE, "ftruncate", file.path, @intCast(@src().line));
    }
    if (size < file.mmap_size) file.mmap_size = size;
    return vfs.OK;
}

/// Source `unixFileSize()`: use descriptor metadata, preserve fstat errno,
/// and hide the historical one-byte empty-database sentinel.
fn unixFileSize(file: *UnixFile, output: *i64) c_int {
    var status: Statx = undefined;
    if (statx(file.fd, empty_path, 0x1000, 0x7ff, &status) != 0) {
        file.last_errno = errno();
        return vfs.IOERR_FSTAT;
    }
    output.* = @intCast(status.size);
    if (output.* == 1) output.* = 0;
    return vfs.OK;
}

fn unixUnmapfile(file: *UnixFile) void {
    std.debug.assert(file.fetch_count == 0);
    if (file.fetch_map) |mapping| {
        _ = munmap(mapping.ptr, mapping.len);
        file.fetch_map = null;
    }
    file.fetch_return = null;
    file.mmap_size = 0;
}

/// Source `unixRemapfile()`: discard the old mapping, establish a full-file
/// replacement, and permanently disable mmap after a mapping failure.
fn unixRemapfile(file: *UnixFile, requested_size: i64) void {
    std.debug.assert(file.fetch_count == 0 and requested_size >= 0);
    unixUnmapfile(file);
    if (requested_size == 0) return;
    const protection: c_int = PROT_READ;
    const raw = mmap(null, @intCast(requested_size), protection, MAP_SHARED, file.fd, 0);
    if (raw == null or @intFromPtr(raw.?) == std.math.maxInt(usize)) {
        file.mmap_size_max = 0;
        _ = unixLogErrorAtLine(vfs.OK, "mmap", file.path, @intCast(@src().line));
        return;
    }
    file.fetch_map = @as([*]u8, @ptrCast(raw.?))[0..@intCast(requested_size)];
    file.mmap_size = requested_size;
}

/// Source `unixMapfile()`: map the requested or on-disk size, capped by the
/// per-file mmap limit, unless outstanding xFetch references pin it.
fn unixMapfile(file: *UnixFile, requested_size: i64) c_int {
    if (file.fetch_count > 0) return vfs.OK;
    var map_size = requested_size;
    if (map_size < 0) {
        var status: Statx = undefined;
        if (statx(file.fd, empty_path, 0x1000, 0x7ff, &status) != 0) return vfs.IOERR_FSTAT;
        map_size = @intCast(status.size);
    }
    map_size = @min(map_size, file.mmap_size_max);
    if (map_size != file.mmap_size) unixRemapfile(file, map_size);
    return vfs.OK;
}

/// Source `unixFetch()`: return only mapped ranges with SQLite's 256-byte
/// corruption-overread reserve and retain an outstanding mapping reference.
fn unixFetch(file: *UnixFile, offset: i64, amount: c_int, output: *?*anyopaque) c_int {
    output.* = null;
    if (offset < 0 or amount <= 0 or file.mmap_size_max <= 0) return vfs.OK;
    if (file.fetch_map == null) {
        const rc = unixMapfile(file, -1);
        if (rc != vfs.OK) return rc;
    }
    const end = std.math.add(i64, offset, amount) catch return vfs.OK;
    const reserved_end = std.math.add(i64, end, 256) catch return vfs.OK;
    if (file.fetch_map) |mapping| {
        if (reserved_end <= file.mmap_size) {
            output.* = @ptrCast(mapping.ptr + @as(usize, @intCast(offset)));
            file.fetch_count += 1;
        }
    }
    return vfs.OK;
}

/// Source `unixUnfetch()`: release one xFetch reference, or invalidate the
/// complete mapping when POSIX may have made it stale.
fn unixUnfetch(file: *UnixFile, offset: i64, pointer: ?*anyopaque) c_int {
    if (pointer) |returned| {
        std.debug.assert(file.fetch_count > 0);
        if (file.fetch_map) |mapping| {
            std.debug.assert(returned == @as(*anyopaque, @ptrCast(mapping.ptr + @as(usize, @intCast(offset)))));
        }
        file.fetch_count -= 1;
    } else {
        std.debug.assert(file.fetch_count == 0);
        unixUnmapfile(file);
    }
    return vfs.OK;
}

/// Source `unixShmPurge()`: destroy an unreferenced process-shared WAL node,
/// including all mappings, the descriptor, pathname, and inode linkage.
fn unixShmPurge(file: *UnixFile, node: *ShmNode) void {
    std.debug.assert(node.reference_count == 0);
    if (node.map) |mapping| {
        _ = munmap(mapping.ptr, mapping.len);
    }
    if (node.fd >= 0) {
        _ = close(node.fd);
    }
    const inode = file.inode_info orelse return;
    inode.shm_node = null;
    node.allocator.free(node.path);
    node.allocator.destroy(node);
}

/// Source `unixShmBarrier()`: provide both a sequentially-consistent compiler
/// barrier and the process-global Unix mutex round-trip used by SQLite.
fn unixShmBarrier(_: *UnixFile) void {
    _ = @atomicRmw(u8, &barrier_byte, .Add, 0, .seq_cst);
    inode_mutex.lock();
    inode_mutex.unlock();
}

/// Source `unixShmUnmap()`: detach one connection and purge or delete the
/// shared WAL node only after its final process-local reference closes.
fn unixShmUnmap(file: *UnixFile, delete_flag: bool) c_int {
    const node = file.shm_node orelse return vfs.OK;
    const inode = file.inode_info orelse return vfs.IOERR_SHMMAP;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    std.debug.assert(node.reference_count > 0 and inode.shm_node == node);
    node.reference_count -= 1;
    file.shm_node = null;
    file.shm_fd = -1;
    file.shm_path = null;
    file.shm_map = null;
    if (node.reference_count == 0) {
        if (delete_flag) {
            _ = unlink(node.path);
        }
        unixShmPurge(file, node);
    }
    return vfs.OK;
}

/// Source `closeUnixFile()`: unmap and close common resources, honor
/// delete-on-close, then release all connection-owned allocations.
fn closeUnixFile(file: *UnixFile) c_int {
    if (file.fetch_count == 0) unixUnmapfile(file);
    if (file.shm_node != null) _ = unixShmUnmap(file, false);
    if (file.fd >= 0 and close(file.fd) != 0) {
        _ = unixLogErrorAtLine(vfs.IOERR_CLOSE, "close", file.path, @intCast(@src().line));
    }
    if (file.delete_on_close) _ = unlink(file.path);
    if (file.dotlock_path) |path| {
        file.owner.allocator.free(path);
    }
    file.owner.allocator.free(file.path);
    const owner = file.owner;
    owner.allocator.destroy(file);
    return vfs.OK;
}

/// Source `unixClose()`: verify and unlock the database, defer descriptor
/// close while sibling POSIX locks survive, release the inode, then clean up.
fn unixClose(file: *UnixFile) c_int {
    verifyDbFile(file);
    std.debug.assert(file.fetch_count == 0);
    if (file.shm_node != null) _ = unixShmUnmap(file, false);
    const unlock_result = file.unlock(vfs.LOCK_NONE);
    if (unlock_result != vfs.OK) return unlock_result;
    retireFileDescriptor(file);
    releaseInodeInfo(file);
    return closeUnixFile(file);
}

pub const LockingMode = enum { posix, none, dotfile, exclusive };

/// Source `unixDelete()`: preserve the distinct no-entry result and, when
/// requested, durably sync the containing directory after unlink.
fn unixDelete(owner: *UnixVfs, name: []const u8, sync_directory: bool) c_int {
    const path = decodeUri(owner.allocator, name) catch return vfs.NOMEM;
    defer owner.allocator.free(path);
    if (unlink(path) != 0) {
        if (errno() == ENOENT) return vfs.IOERR_DELETE_NOENT;
        return unixLogErrorAtLine(vfs.IOERR_DELETE, "unlink", path, @intCast(@src().line));
    }
    if (sync_directory) {
        var directory_fd: c_int = -1;
        if (openDirectory(owner, path, &directory_fd) == vfs.OK and directory_fd >= 0) {
            if (fullFsync(owner, directory_fd, false, false) != 0) {
                _ = close(directory_fd);
                return unixLogErrorAtLine(vfs.IOERR_DIR_FSYNC, "fsync", path, @intCast(@src().line));
            }
            _ = close(directory_fd);
        }
    }
    return vfs.OK;
}

/// Source `unixAccess()`: existence excludes empty regular files, while the
/// read/write query delegates to the operating-system permission check.
fn unixAccess(owner: *UnixVfs, name: []const u8, mode: c_int, output: *c_int) c_int {
    const path = decodeUri(owner.allocator, name) catch return vfs.NOMEM;
    defer owner.allocator.free(path);
    output.* = 0;
    if (mode == vfs.ACCESS_EXISTS) {
        var status: Statx = undefined;
        if (statx(-100, path, 0, 0x7ff, &status) == 0) {
            const is_regular = status.mode & 0o170000 == 0o100000;
            output.* = @intFromBool(!is_regular or status.size > 0);
        }
    } else {
        output.* = @intFromBool(access(path, 6) == 0);
    }
    return vfs.OK;
}

/// Source `unixRandomness()`: initialize the complete buffer, read
/// `/dev/urandom` with EINTR handling, and fall back to time plus pid.
fn unixRandomness(owner: *UnixVfs, output: []u8) c_int {
    @memset(output, 0);
    if (output.len == 0) return 0;
    const random_fd = owner.robustOpen("/dev/urandom", O_RDONLY, 0);
    if (random_fd >= 0) {
        var got: isize = -1;
        while (got < 0) {
            got = read(random_fd, output.ptr, output.len);
            if (got < 0 and errno() != EINTR) break;
        }
        _ = close(random_fd);
        if (got >= 0) return @intCast(got);
    }
    const seconds = time(null);
    const process_id = getpid();
    const time_bytes = std.mem.asBytes(&seconds);
    const pid_bytes = std.mem.asBytes(&process_id);
    const time_count = @min(output.len, time_bytes.len);
    @memcpy(output[0..time_count], time_bytes[0..time_count]);
    const pid_count = @min(output.len - time_count, pid_bytes.len);
    @memcpy(output[time_count..][0..pid_count], pid_bytes[0..pid_count]);
    return @intCast(time_count + pid_count);
}

/// Source `unixSleep()`: request the exact microsecond interval through
/// nanosleep and report that requested duration.
fn unixSleep(microseconds: c_int) c_int {
    const nonnegative: i64 = @max(microseconds, 0);
    const interval = Timespec{
        .seconds = @divTrunc(nonnegative, 1_000_000),
        .nanoseconds = @mod(nonnegative, 1_000_000) * 1_000,
    };
    _ = nanosleep(&interval, null);
    return @intCast(nonnegative);
}

/// Source `unixCurrentTimeInt64()`: return Unix wall time converted to
/// milliseconds since SQLite's Julian epoch.
fn unixCurrentTimeInt64(output: *i64) c_int {
    const unix_epoch: i64 = 24405875 * 8_640_000;
    var now: Timeval = undefined;
    if (gettimeofday(&now, null) != 0) return vfs.ERROR;
    output.* = unix_epoch + now.seconds * 1_000 + @divTrunc(now.microseconds, 1_000);
    return vfs.OK;
}

/// Source `unixSetSystemCall()`: restore all overrides, restore one default,
/// or replace the named syscall while rejecting unknown names.
fn unixSetSystemCall(owner: *UnixVfs, name_pointer: ?[*:0]const u8, pointer: ?*const fn () callconv(.c) void) c_int {
    if (name_pointer == null) {
        owner.open_override = null;
        owner.pread_override = null;
        owner.pwrite_override = null;
        owner.fsync_override = null;
        owner.fdatasync_override = null;
        return vfs.OK;
    }
    const name = std.mem.span(name_pointer.?);
    if (std.mem.eql(u8, name, "open")) {
        owner.open_override = if (pointer) |value| @ptrCast(value) else null;
    } else if (std.mem.eql(u8, name, "pread")) {
        owner.pread_override = if (pointer) |value| @ptrCast(value) else null;
    } else if (std.mem.eql(u8, name, "pwrite")) {
        owner.pwrite_override = if (pointer) |value| @ptrCast(value) else null;
    } else if (std.mem.eql(u8, name, "fsync")) {
        owner.fsync_override = if (pointer) |value| @ptrCast(value) else null;
    } else if (std.mem.eql(u8, name, "fdatasync")) {
        owner.fdatasync_override = if (pointer) |value| @ptrCast(value) else null;
    } else {
        return vfs.NOTFOUND;
    }
    return vfs.OK;
}

/// Source `unixGetSystemCall()`: expose the current typed syscall pointer by
/// name, falling back to its compiled default.
fn unixGetSystemCall(owner: *UnixVfs, name_pointer: [*:0]const u8) ?*const fn () callconv(.c) void {
    const name = std.mem.span(name_pointer);
    if (std.mem.eql(u8, name, "open")) return if (owner.open_override) |value| @ptrCast(value) else @ptrCast(&open);
    if (std.mem.eql(u8, name, "pread")) return if (owner.pread_override) |value| @ptrCast(value) else @ptrCast(&pread);
    if (std.mem.eql(u8, name, "pwrite")) return if (owner.pwrite_override) |value| @ptrCast(value) else @ptrCast(&pwrite);
    if (std.mem.eql(u8, name, "fsync")) return if (owner.fsync_override) |value| @ptrCast(value) else @ptrCast(&fsync);
    if (std.mem.eql(u8, name, "fdatasync")) return if (owner.fdatasync_override) |value| @ptrCast(value) else @ptrCast(&fdatasync);
    return null;
}

/// Source `unixNextSystemCall()`: iterate the active syscall names and reject
/// unknown or terminal predecessor names.
fn unixNextSystemCall(name_pointer: ?[*:0]const u8) ?[*:0]const u8 {
    if (name_pointer == null) return open_name;
    const name = std.mem.span(name_pointer.?);
    if (std.mem.eql(u8, name, "open")) return pread_name;
    if (std.mem.eql(u8, name, "pread")) return pwrite_name;
    if (std.mem.eql(u8, name, "pwrite")) return fsync_name;
    if (std.mem.eql(u8, name, "fsync")) return fdatasync_name;
    return null;
}

/// Source `unixOpenSharedMemory()`: reuse the inode-owned WAL node or create,
/// DMS-lock, size, map, and publish one with complete failure cleanup.
fn unixOpenSharedMemory(file: *UnixFile) !void {
    if (file.shm_node != null) return;
    const inode = file.inode_info orelse return error.Open;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    if (inode.shm_node) |node| {
        node.reference_count += 1;
        file.shm_node = node;
        file.shm_fd = node.fd;
        file.shm_path = node.path;
        file.shm_map = node.map;
        return;
    }
    const path = std.fmt.allocPrintSentinel(file.owner.allocator, "{s}-shm", .{file.path}, 0) catch return error.OutOfMemory;
    const fd = file.owner.robustOpen(path, O_RDWR | O_CREAT, 0);
    if (fd < 0) {
        file.owner.allocator.free(path);
        return error.Open;
    }
    file.shm_fd = fd;
    file.shm_path = path;
    const lock_result = unixLockSharedMemory(file);
    if (lock_result != vfs.OK) {
        _ = close(fd);
        file.owner.allocator.free(path);
        file.shm_fd = -1;
        file.shm_path = null;
        return if (lock_result == vfs.BUSY) error.Busy else error.Lock;
    }
    const length: usize = 4 * vfs.SHM_REGION_SIZE;
    const current_size = lseek(fd, 0, SEEK_END);
    if (current_size < 0 or (current_size < @as(i64, @intCast(length)) and robustFtruncate(fd, @intCast(length)) != 0)) {
        _ = close(fd);
        file.owner.allocator.free(path);
        file.shm_fd = -1;
        file.shm_path = null;
        return error.Truncate;
    }
    const raw = mmap(null, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (raw == null or @intFromPtr(raw.?) == std.math.maxInt(usize)) {
        _ = close(fd);
        file.owner.allocator.free(path);
        file.shm_fd = -1;
        file.shm_path = null;
        return error.Map;
    }
    const mapping = @as([*]u8, @ptrCast(raw.?))[0..length];
    const node = file.owner.allocator.create(ShmNode) catch {
        _ = munmap(mapping.ptr, mapping.len);
        _ = close(fd);
        file.owner.allocator.free(path);
        file.shm_fd = -1;
        file.shm_path = null;
        return error.OutOfMemory;
    };
    node.* = .{ .allocator = file.owner.allocator, .fd = fd, .path = path, .map = mapping };
    inode.shm_node = node;
    file.shm_node = node;
    file.shm_map = mapping;
}

/// Source `unixShmMap()`: preserve no-extend probing, open the shared node on
/// demand, and return the exact requested 32KiB region from the shared map.
fn unixShmMap(file: *UnixFile, region: c_int, region_size: c_int, extend: bool, output: *?*volatile anyopaque) c_int {
    output.* = null;
    if (region < 0 or region >= 4 or region_size != vfs.SHM_REGION_SIZE) return vfs.IOERR_SHMMAP;
    const required_size = (@as(i64, region) + 1) * region_size;
    if (!extend and file.shm_node == null) {
        var path_buffer: [max_path_length + 1]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buffer, "{s}-shm", .{file.path}) catch return vfs.IOERR_SHMMAP;
        var status: Statx = undefined;
        if (statx(-100, path, 0, 0x7ff, &status) != 0 or status.size < required_size) return vfs.OK;
    }
    unixOpenSharedMemory(file) catch |failure| {
        if (failure == error.Busy) return vfs.BUSY;
        if (failure == error.OutOfMemory) return vfs.NOMEM;
        return vfs.IOERR_SHMMAP;
    };
    const mapping = file.shm_node.?.map orelse return vfs.IOERR_SHMMAP;
    if (required_size > mapping.len) return if (extend) vfs.IOERR_SHMMAP else vfs.OK;
    output.* = @ptrCast(mapping.ptr + @as(usize, @intCast(region)) * vfs.SHM_REGION_SIZE);
    return vfs.OK;
}

/// Source `unixShmLock()`: coordinate process-local shared/exclusive masks
/// before changing POSIX WAL byte-range locks, including shared unlock reuse.
fn unixShmLock(file: *UnixFile, offset: c_int, count: c_int, flags: c_int) c_int {
    const node = file.shm_node orelse return vfs.IOERR_SHMLOCK;
    if (offset < 0 or count < 1 or offset + count > node.locks.len) return vfs.IOERR_SHMLOCK;
    const lock_action = flags & vfs.SHM_LOCK != 0;
    const unlock_action = flags & vfs.SHM_UNLOCK != 0;
    const shared_action = flags & vfs.SHM_SHARED != 0;
    const exclusive_action = flags & vfs.SHM_EXCLUSIVE != 0;
    if (lock_action == unlock_action or shared_action == exclusive_action) return vfs.IOERR_SHMLOCK;
    if (count != 1 and !exclusive_action) return vfs.IOERR_SHMLOCK;
    const high_bit: u4 = @intCast(offset + count);
    const low_bit: u4 = @intCast(offset);
    const wide_mask: u16 = (@as(u16, 1) << high_bit) - (@as(u16, 1) << low_bit);
    const mask: u8 = @truncate(wide_mask);

    inode_mutex.lock();
    defer inode_mutex.unlock();
    if (unlock_action) {
        if (shared_action and file.shm_shared_mask & mask != 0 and node.locks[@intCast(offset)] > 1) {
            node.locks[@intCast(offset)] -= 1;
            file.shm_shared_mask &= ~mask;
            return vfs.OK;
        }
        const rc = unixShmSystemLock(file, F_UNLCK, UNIX_SHM_BASE + @as(i64, offset), count);
        if (rc == vfs.OK) {
            for (node.locks[@intCast(offset)..@intCast(offset + count)]) |*value| {
                value.* = 0;
            }
            file.shm_shared_mask &= ~mask;
            file.shm_exclusive_mask &= ~mask;
        }
        return rc;
    }
    if (shared_action) {
        if (file.shm_shared_mask & mask != 0) return vfs.OK;
        const lock_count = &node.locks[@intCast(offset)];
        if (lock_count.* < 0) return vfs.BUSY;
        if (lock_count.* == 0) {
            const rc = unixShmSystemLock(file, F_RDLCK, UNIX_SHM_BASE + @as(i64, offset), 1);
            if (rc != vfs.OK) return rc;
        }
        lock_count.* += 1;
        file.shm_shared_mask |= mask;
        return vfs.OK;
    }
    for (node.locks[@intCast(offset)..@intCast(offset + count)]) |value| {
        if (value != 0) return vfs.BUSY;
    }
    const rc = unixShmSystemLock(file, F_WRLCK, UNIX_SHM_BASE + @as(i64, offset), count);
    if (rc == vfs.OK) {
        for (node.locks[@intCast(offset)..@intCast(offset + count)]) |*value| {
            value.* = -1;
        }
        file.shm_exclusive_mask |= mask;
    }
    return rc;
}

pub const OpenResult = struct {
    rc: c_int,
    file: ?*UnixFile,
};

/// Source `fillInUnixFile()`: finalize the native handle's locking style,
/// inode ownership, source flags, identity, and device defaults after open.
fn fillInUnixFile(file: *UnixFile, flags: c_int) c_int {
    file.readonly = flags & vfs.OPEN_READONLY != 0;
    file.delete_on_close = flags & vfs.OPEN_DELETEONCLOSE != 0;
    file.directory_sync = flags & (vfs.OPEN_MAIN_JOURNAL | vfs.OPEN_WAL) != 0;
    file.is_database = flags & vfs.OPEN_MAIN_DB != 0;
    captureFileIdentity(file);
    if (file.is_database and (file.owner.locking_mode == .posix or file.owner.locking_mode == .exclusive)) {
        const rc = findInodeInfo(file);
        if (rc != vfs.OK) return rc;
    }
    setDeviceCharacteristics(file);
    verifyDbFile(file);
    return vfs.OK;
}

/// Source `unixOpen()`: validate and translate SQLite open flags, reuse safe
/// deferred descriptors, preserve sidecar ownership, fall back to read-only,
/// unlink delete-on-close files, and fully initialize the resulting handle.
fn unixOpen(owner: *UnixVfs, name: ?[]const u8, flags_initial: c_int) OpenResult {
    var flags = flags_initial;
    const readonly_requested = flags & vfs.OPEN_READONLY != 0;
    const readwrite_requested = flags & vfs.OPEN_READWRITE != 0;
    const create_requested = flags & vfs.OPEN_CREATE != 0;
    const exclusive_requested = flags & vfs.OPEN_EXCLUSIVE != 0;
    const delete_requested = flags & vfs.OPEN_DELETEONCLOSE != 0;
    if (readonly_requested == readwrite_requested or
        (create_requested and !readwrite_requested) or
        (exclusive_requested and !create_requested) or
        (delete_requested and !create_requested))
    {
        return .{ .rc = vfs.MISUSE, .file = null };
    }

    const path = owner.makePath(name) catch |failure| return .{
        .rc = if (failure == error.OutOfMemory)
            vfs.NOMEM
        else if (failure == error.TempPath)
            vfs.IOERR_GETTEMPPATH
        else
            vfs.CANTOPEN,
        .file = null,
    };
    var open_flags: c_int = O_CLOEXEC | O_NOFOLLOW;
    if (readwrite_requested) open_flags |= O_RDWR else open_flags |= O_RDONLY;
    if (create_requested) open_flags |= O_CREAT;
    if (exclusive_requested) open_flags |= O_EXCL;

    var create_mode: u32 = 0;
    var create_uid: u32 = 0;
    var create_gid: u32 = 0;
    const mode_source = name orelse path;
    const mode_result = findCreateFileMode(mode_source, flags, &create_mode, &create_uid, &create_gid);
    if (mode_result != vfs.OK) {
        owner.allocator.free(path);
        return .{ .rc = mode_result, .file = null };
    }
    const reusable = if (flags & vfs.OPEN_MAIN_DB != 0) findReusableFd(path, flags) else null;
    var fd = if (reusable) |entry| entry.fd else owner.robustOpen(path, open_flags, @intCast(create_mode));
    if (reusable) |entry| {
        std.heap.c_allocator.destroy(entry);
    }
    if (fd < 0 and readwrite_requested and errno() != 21) {
        flags &= ~(vfs.OPEN_READWRITE | vfs.OPEN_CREATE);
        flags |= vfs.OPEN_READONLY;
        const readonly_reusable = if (flags & vfs.OPEN_MAIN_DB != 0) findReusableFd(path, flags) else null;
        fd = if (readonly_reusable) |entry| entry.fd else owner.robustOpen(path, O_RDONLY | O_NOFOLLOW, @intCast(create_mode));
        if (readonly_reusable) |entry| {
            std.heap.c_allocator.destroy(entry);
        }
    }
    if (fd < 0) {
        owner.allocator.free(path);
        return .{ .rc = ioCode(vfs.CANTOPEN), .file = null };
    }
    if (create_mode != 0 and flags & (vfs.OPEN_WAL | vfs.OPEN_MAIN_JOURNAL) != 0) {
        _ = fchown(fd, create_uid, create_gid);
    }
    if (delete_requested) _ = unlink(path);

    const file = owner.allocator.create(UnixFile) catch {
        _ = close(fd);
        owner.allocator.free(path);
        return .{ .rc = vfs.NOMEM, .file = null };
    };
    var dotlock_path: ?[:0]u8 = null;
    if (owner.locking_mode == .dotfile and flags & vfs.OPEN_MAIN_DB != 0) {
        dotlock_path = std.fmt.allocPrintSentinel(owner.allocator, "{s}.lock", .{path}, 0) catch {
            owner.allocator.destroy(file);
            _ = close(fd);
            owner.allocator.free(path);
            return .{ .rc = vfs.NOMEM, .file = null };
        };
    }
    file.* = .{
        .owner = owner,
        .fd = fd,
        .path = path,
        .dotlock_path = dotlock_path,
    };
    const initialize_result = fillInUnixFile(file, flags);
    if (delete_requested) file.delete_on_close = false;
    if (initialize_result != vfs.OK) {
        _ = closeUnixFile(file);
        return .{ .rc = initialize_result, .file = null };
    }
    return .{ .rc = vfs.OK, .file = file };
}

pub const UnixVfs = struct {
    allocator: std.mem.Allocator,
    locking_mode: LockingMode = .posix,
    vfs_name: [*:0]const u8 = "unix",
    open_override: ?*const fn ([*:0]const u8, c_int, c_int) callconv(.c) c_int = null,
    pread_override: ?*const fn (c_int, *anyopaque, usize, i64) callconv(.c) isize = null,
    pwrite_override: ?*const fn (c_int, *const anyopaque, usize, i64) callconv(.c) isize = null,
    fsync_override: ?*const fn (c_int) callconv(.c) c_int = null,
    fdatasync_override: ?*const fn (c_int) callconv(.c) c_int = null,
    pub fn init(a: std.mem.Allocator) UnixVfs {
        return initMode(a, .posix);
    }
    pub fn initMode(a: std.mem.Allocator, mode: LockingMode) UnixVfs {
        return .{ .allocator = a, .locking_mode = mode };
    }
    fn syscallOpen(self: *UnixVfs, path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
        return if (self.open_override) |function| function(path, flags, mode) else open(path, flags, mode);
    }
    /// Source `robust_open()`: retry EINTR, reject stdio descriptors, reserve
    /// low descriptors through `/dev/null`, and apply explicit sidecar modes.
    fn robustOpen(self: *UnixVfs, path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
        const create_mode: c_int = if (mode != 0) mode else 0o644;
        var fd: c_int = -1;
        while (true) {
            fd = self.syscallOpen(path, flags | O_CLOEXEC, create_mode);
            if (fd < 0) {
                if (errno() == EINTR) continue;
                break;
            }
            if (fd >= 3) break;
            if ((flags & (O_EXCL | O_CREAT)) == (O_EXCL | O_CREAT)) {
                _ = unlink(path);
            }
            _ = close(fd);
            std.log.warn("attempt to open {s} as file descriptor {d}", .{ std.mem.span(path), fd });
            fd = -1;
            if (self.syscallOpen("/dev/null", O_RDONLY | O_CLOEXEC, mode) < 0) break;
        }
        if (fd >= 0 and mode != 0 and lseek(fd, 0, SEEK_END) == 0) {
            _ = fchmod(fd, @intCast(mode));
        }
        return fd;
    }
    fn preadFd(self: *UnixVfs, fd: c_int, output: *anyopaque, count: usize, offset: i64) isize {
        return if (self.pread_override) |f| f(fd, output, count, offset) else pread(fd, output, count, offset);
    }
    fn pwriteFd(self: *UnixVfs, fd: c_int, input: *const anyopaque, count: usize, offset: i64) isize {
        return if (self.pwrite_override) |f| f(fd, input, count, offset) else pwrite(fd, input, count, offset);
    }
    fn fsyncFd(self: *UnixVfs, fd: c_int) c_int {
        return if (self.fsync_override) |function| function(fd) else fsync(fd);
    }
    fn fdatasyncFd(self: *UnixVfs, fd: c_int) c_int {
        return if (self.fdatasync_override) |function| function(fd) else fdatasync(fd);
    }
    fn makePath(self: *UnixVfs, name: ?[]const u8) ![:0]u8 {
        if (name) |provided| {
            return decodeUri(self.allocator, provided);
        }
        var temporary_name: [max_path_length + 1]u8 = undefined;
        if (unixGetTempname(&temporary_name) != vfs.OK) return error.TempPath;
        return self.allocator.dupeZ(u8, std.mem.sliceTo(&temporary_name, 0));
    }
    pub fn openFile(self: *UnixVfs, name: ?[]const u8, flags: c_int) OpenResult {
        return unixOpen(self, name, flags);
    }
    pub fn delete(self: *UnixVfs, name: []const u8, sync_dir: bool) c_int {
        return unixDelete(self, name, sync_dir);
    }
    pub fn accessPath(self: *UnixVfs, name: []const u8, mode: c_int, out: *c_int) c_int {
        return unixAccess(self, name, mode, out);
    }
    pub fn fullPath(self: *UnixVfs, name: []const u8, out: []u8) c_int {
        const path = decodeUri(self.allocator, name) catch return vfs.NOMEM;
        defer self.allocator.free(path);
        return unixFullPathname(path, out);
    }
};

pub const UnixFile = struct {
    owner: *UnixVfs,
    fd: c_int,
    path: [:0]u8,
    readonly: bool = false,
    delete_on_close: bool = false,
    directory_sync: bool = false,
    last_errno: c_int = 0,
    sector_size: c_int = 0,
    device_characteristics: c_int = 0,
    powersafe_overwrite: bool = true,
    persist_wal: bool = false,
    chunk_size: i64 = 0,
    mmap_size_max: i64 = 1 << 30,
    mmap_size: i64 = 0,
    fetch_count: usize = 0,
    is_database: bool = false,
    inode: u64 = 0,
    inode_info: ?*InodeInfo = null,
    device_major: u32 = 0,
    device_minor: u32 = 0,
    lock_level: c_int = vfs.LOCK_NONE,
    shm_fd: c_int = -1,
    shm_path: ?[:0]u8 = null,
    shm_map: ?[]u8 = null,
    shm_node: ?*ShmNode = null,
    shm_shared_mask: u8 = 0,
    shm_exclusive_mask: u8 = 0,
    fetch_map: ?[]u8 = null,
    fetch_return: ?*anyopaque = null,
    dotlock_path: ?[:0]u8 = null,
    dotlock_held: bool = false,
    exclusive_process_lock: bool = false,
    pub fn destroy(self: *UnixFile) c_int {
        return unixClose(self);
    }
    pub fn read(self: *UnixFile, out: []u8, off: i64) c_int {
        return unixRead(self, out, off);
    }
    pub fn write(self: *UnixFile, input: []const u8, off: i64) c_int {
        return unixWrite(self, input, off);
    }
    fn truncate(self: *UnixFile, n: i64) c_int {
        return unixTruncate(self, n);
    }
    pub fn size(self: *UnixFile, out: *i64) c_int {
        return unixFileSize(self, out);
    }
    pub fn sync(self: *UnixFile) c_int {
        return unixSync(self, SQLITE_SYNC_NORMAL);
    }
    fn lock(self: *UnixFile, target: c_int) c_int {
        if (self.owner.locking_mode == .none) {
            updateLockLevel(self, target);
            return vfs.OK;
        }
        if (self.owner.locking_mode == .dotfile) return dotlockLock(self, target);
        return unixLock(self, target);
    }
    fn unlock(self: *UnixFile, target: c_int) c_int {
        if (self.owner.locking_mode == .none or (self.owner.locking_mode == .exclusive and !self.readonly)) {
            updateLockLevel(self, target);
            return vfs.OK;
        }
        if (self.owner.locking_mode == .dotfile) return dotlockUnlock(self, target);
        return posixUnlock(self, target);
    }
    fn reserved(self: *UnixFile, out: *c_int) c_int {
        if (self.owner.locking_mode == .none) {
            out.* = 0;
            return vfs.OK;
        }
        if (self.owner.locking_mode == .dotfile) return dotlockCheckReservedLock(self, out);
        return unixCheckReservedLock(self, out);
    }
    fn ensureShm(self: *UnixFile) !void {
        return unixOpenSharedMemory(self);
    }
    fn shmMapRegion(self: *UnixFile, region: c_int, region_size: c_int, extend: c_int, out: *?*volatile anyopaque) c_int {
        return unixShmMap(self, region, region_size, extend != 0, out);
    }
    fn shmLock(self: *UnixFile, offset: c_int, count: c_int, flags: c_int) c_int {
        return unixShmLock(self, offset, count, flags);
    }
    fn shmUnmap(self: *UnixFile, delete_flag: c_int) c_int {
        return unixShmUnmap(self, delete_flag != 0);
    }
    fn fetch(self: *UnixFile, off: i64, n: c_int, out: *?*anyopaque) c_int {
        return unixFetch(self, off, n, out);
    }
    fn unfetch(self: *UnixFile, off: i64, pointer: ?*anyopaque) c_int {
        return unixUnfetch(self, off, pointer);
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
fn xSync(f: *vfs.sqlite3_file, flags: c_int) callconv(.c) c_int {
    return unixSync(af(f).native.?, flags);
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
fn xControl(file: *vfs.sqlite3_file, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    return unixFileControl(af(file).native.?, operation, argument);
}
fn xSector(file: *vfs.sqlite3_file) callconv(.c) c_int {
    const native = af(file).native.?;
    setDeviceCharacteristics(native);
    return native.sector_size;
}
fn xDevice(file: *vfs.sqlite3_file) callconv(.c) c_int {
    const native = af(file).native.?;
    setDeviceCharacteristics(native);
    return native.device_characteristics;
}
fn xShmMap(f: *vfs.sqlite3_file, r: c_int, s: c_int, e: c_int, p: *?*volatile anyopaque) callconv(.c) c_int {
    return af(f).native.?.shmMapRegion(r, s, e, p);
}
fn xShmLock(f: *vfs.sqlite3_file, o: c_int, n: c_int, fl: c_int) callconv(.c) c_int {
    return af(f).native.?.shmLock(o, n, fl);
}
var barrier_byte: u8 = 0;
fn xBarrier(file: *vfs.sqlite3_file) callconv(.c) void {
    unixShmBarrier(af(file).native.?);
}
fn xShmUnmap(f: *vfs.sqlite3_file, d: c_int) callconv(.c) c_int {
    return af(f).native.?.shmUnmap(d);
}
fn xFetch(f: *vfs.sqlite3_file, o: i64, n: c_int, p: *?*anyopaque) callconv(.c) c_int {
    return af(f).native.?.fetch(o, n, p);
}
fn xUnfetch(f: *vfs.sqlite3_file, offset: i64, pointer: ?*anyopaque) callconv(.c) c_int {
    return af(f).native.?.unfetch(offset, pointer);
}
const methods = vfs.sqlite3_io_methods{ .iVersion = 3, .xClose = xClose, .xRead = xRead, .xWrite = xWrite, .xTruncate = xTruncate, .xSync = xSync, .xFileSize = xSize, .xLock = xLock, .xUnlock = xUnlock, .xCheckReservedLock = xReserved, .xFileControl = xControl, .xSectorSize = xSector, .xDeviceCharacteristics = xDevice, .xShmMap = xShmMap, .xShmLock = xShmLock, .xShmBarrier = xBarrier, .xShmUnmap = xShmUnmap, .xFetch = xFetch, .xUnfetch = xUnfetch };
const no_lock_methods = vfs.sqlite3_io_methods{ .iVersion = 3, .xClose = xClose, .xRead = xRead, .xWrite = xWrite, .xTruncate = xTruncate, .xSync = xSync, .xFileSize = xSize, .xLock = xLock, .xUnlock = xUnlock, .xCheckReservedLock = xReserved, .xFileControl = xControl, .xSectorSize = xSector, .xDeviceCharacteristics = xDevice, .xShmMap = null, .xShmLock = xShmLock, .xShmBarrier = xBarrier, .xShmUnmap = xShmUnmap, .xFetch = xFetch, .xUnfetch = xUnfetch };
const dot_lock_methods = vfs.sqlite3_io_methods{ .iVersion = 1, .xClose = xClose, .xRead = xRead, .xWrite = xWrite, .xTruncate = xTruncate, .xSync = xSync, .xFileSize = xSize, .xLock = xLock, .xUnlock = xUnlock, .xCheckReservedLock = xReserved, .xFileControl = xControl, .xSectorSize = xSector, .xDeviceCharacteristics = xDevice, .xShmMap = null, .xShmLock = xShmLock, .xShmBarrier = xBarrier, .xShmUnmap = xShmUnmap, .xFetch = xFetch, .xUnfetch = xUnfetch };
fn vOpen(v: *vfs.sqlite3_vfs, n: ?[*:0]const u8, f: *vfs.sqlite3_file, flags: c_int, out: ?*c_int) callconv(.c) c_int {
    af(f).* = .{ .base = .{ .pMethods = null }, .native = null };
    av(v).vfs_name = v.zName;
    const r = av(v).openFile(if (n) |z| std.mem.span(z) else null, flags);
    if (r.file) |file| {
        af(f).native = file;
        f.pMethods = switch (file.owner.locking_mode) {
            .none => &no_lock_methods,
            .dotfile => &dot_lock_methods,
            .posix, .exclusive => &methods,
        };
        if (out) |output| {
            output.* = if (file.readonly) (flags & ~vfs.OPEN_READWRITE) | vfs.OPEN_READONLY else flags;
        }
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
fn vRandom(v: *vfs.sqlite3_vfs, n: c_int, output: [*]u8) callconv(.c) c_int {
    return unixRandomness(av(v), output[0..@intCast(@max(n, 0))]);
}
fn vSleep(_: *vfs.sqlite3_vfs, microseconds: c_int) callconv(.c) c_int {
    return unixSleep(microseconds);
}
fn vTime(_: *vfs.sqlite3_vfs, output: *f64) callconv(.c) c_int {
    var milliseconds: i64 = 0;
    const rc = unixCurrentTimeInt64(&milliseconds);
    output.* = @as(f64, @floatFromInt(milliseconds)) / 86_400_000.0;
    return rc;
}
fn vTime64(_: *vfs.sqlite3_vfs, output: *i64) callconv(.c) c_int {
    return unixCurrentTimeInt64(output);
}
fn vLast(_: *vfs.sqlite3_vfs, n: c_int, o: [*]u8) callconv(.c) c_int {
    if (n > 0) o[0] = 0;
    return errno();
}
const open_name: [*:0]const u8 = "open";
const pread_name: [*:0]const u8 = "pread";
const pwrite_name: [*:0]const u8 = "pwrite";
const fsync_name: [*:0]const u8 = "fsync";
const fdatasync_name: [*:0]const u8 = "fdatasync";
fn vSet(v: *vfs.sqlite3_vfs, name: ?[*:0]const u8, pointer: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    return unixSetSystemCall(av(v), name, pointer);
}
fn vGet(v: *vfs.sqlite3_vfs, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return unixGetSystemCall(av(v), name);
}
fn vNext(_: *vfs.sqlite3_vfs, name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return unixNextSystemCall(name);
}
fn unixDlOpen(_: *vfs.sqlite3_vfs, filename: [*:0]const u8) callconv(.c) ?*anyopaque {
    return dlopen(filename, 2 | 0x100);
}

/// Source `unixDlError()`: serialize access to dlerror's process state and
/// copy a bounded, terminated diagnostic only when one is available.
fn unixDlError(_: *vfs.sqlite3_vfs, buffer_size: c_int, output: [*]u8) callconv(.c) void {
    if (buffer_size <= 0) return;
    inode_mutex.lock();
    defer inode_mutex.unlock();
    const error_pointer = dlerror() orelse return;
    const error_text = std.mem.span(error_pointer);
    const copied = @min(error_text.len, @as(usize, @intCast(buffer_size - 1)));
    @memcpy(output[0..copied], error_text[0..copied]);
    output[copied] = 0;
}

/// Source `unixDlSym()`: preserve the Unix dynamic-loader function-pointer
/// conversion behind the VFS ABI's generic entry-point type.
fn unixDlSym(_: *vfs.sqlite3_vfs, handle: ?*anyopaque, symbol: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    const pointer = dlsym(handle, symbol) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn unixDlClose(_: *vfs.sqlite3_vfs, handle: ?*anyopaque) callconv(.c) void {
    _ = dlclose(handle);
}
pub const Adapter = struct {
    abi: vfs.sqlite3_vfs,
    pub fn init(name: [*:0]const u8, native: *UnixVfs) Adapter {
        return .{ .abi = .{ .iVersion = 3, .szOsFile = @sizeOf(AbiFile), .mxPathname = 4096, .pNext = null, .zName = name, .pAppData = native, .xOpen = vOpen, .xDelete = vDelete, .xAccess = vAccess, .xFullPathname = vFull, .xDlOpen = unixDlOpen, .xDlError = unixDlError, .xDlSym = unixDlSym, .xDlClose = unixDlClose, .xRandomness = vRandom, .xSleep = vSleep, .xCurrentTime = vTime, .xGetLastError = vLast, .xCurrentTimeInt64 = vTime64, .xSetSystemCall = vSet, .xGetSystemCall = vGet, .xNextSystemCall = vNext } };
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

test "source Unix full pathname normalizes dot components and bounds output" {
    var output: [128]u8 = undefined;
    try std.testing.expectEqual(vfs.OK, unixFullPathname("/alpha/./beta/../gamma", &output));
    try std.testing.expectEqualStrings("/alpha/gamma", std.mem.sliceTo(&output, 0));

    var small: [8]u8 = undefined;
    try std.testing.expectEqual(vfs.CANTOPEN, unixFullPathname("/alpha/gamma", &small));
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
    try std.testing.expectEqual(vfs.OK, exclusive_b.lock(vfs.LOCK_SHARED));
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
    try std.testing.expect(mapped == null);
    try std.testing.expectEqual(vfs.OK, file.unfetch(0, null));
    try std.testing.expectEqual(vfs.OK, file.write(&[_]u8{0}, 511));
    try std.testing.expectEqual(vfs.OK, file.fetch(0, 8, &mapped));
    try std.testing.expect(mapped != null);
    try std.testing.expectEqualStrings("abcdefgh", @as([*]const u8, @ptrCast(mapped.?))[0..8]);
    try std.testing.expectEqual(vfs.OK, file.unfetch(0, mapped));
    try std.testing.expectEqual(vfs.OK, file.unfetch(0, null));
    const short_generic: *const fn () callconv(.c) void = @ptrCast(&shortPread);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "pread", short_generic));
    var exact: [8]u8 = undefined;
    try std.testing.expectEqual(vfs.OK, file.read(&exact, 0));
    try std.testing.expectEqualStrings("abcdefgh", &exact);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "pread", null));
    const sync_generic: *const fn () callconv(.c) void = @ptrCast(&failingFsync);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "fdatasync", sync_generic));
    try std.testing.expectEqual(vfs.IOERR_FSYNC, file.sync());
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "fdatasync", null));
    try std.testing.expectEqual(vfs.OK, file.destroy());
    const generic: *const fn () callconv(.c) void = @ptrCast(&failingOpen);
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "open", generic));
    var abi_file: AbiFile = undefined;
    try std.testing.expectEqual(vfs.CANTOPEN, adapter.abi.xOpen.?(&adapter.abi, path, @ptrCast(&abi_file), vfs.OPEN_READONLY, null));
    try std.testing.expectEqual(vfs.OK, adapter.abi.xSetSystemCall.?(&adapter.abi, "open", null));
    try std.testing.expect(adapter.abi.xGetSystemCall.?(&adapter.abi, "open") != null);
    try std.testing.expectEqualStrings("open", std.mem.span(adapter.abi.xNextSystemCall.?(&adapter.abi, null).?));
}

test "native Unix POSIX database and WAL locks contend across processes" {
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
        while (true) {
            _ = pause();
        }
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
        if (case[2]) {
            _ = database_pager.checkpointWal();
        }
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, database_pager.close());
        var reopened = Pager.open(std.testing.allocator, &adapter.abi, case[1], .{}).pager.?;
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, reopened.beginRead());
        const page_read = reopened.getPage(1, false);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, page_read.result);
        try std.testing.expectEqual(@as(u8, 0x5a), page_read.page.?.data[60]);
        _ = reopened.release(page_read.page.?);
        try std.testing.expectEqual(@import("result_code.zig").ResultCode.ok, reopened.close());
    }
}
