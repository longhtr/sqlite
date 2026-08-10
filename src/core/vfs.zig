//! Native VFS registry, in-memory durable/volatile store, fault injection, and
//! SQLite public-ABI adapters.

const std = @import("std");
const OneShotFailAllocator = @import("testing_one_shot_allocator.zig").OneShotFailAllocator;
const sqlite_mutex = @import("mutex.zig");
const memory = @import("memory.zig");

const LocalMutex = struct {
    inner: sqlite_mutex.Mutex = .{},
    fn lock(self: *LocalMutex) void {
        self.inner.enter();
    }
    fn unlock(self: *LocalMutex) void {
        self.inner.leave();
    }
    fn deinit(self: *LocalMutex) void {
        std.debug.assert(self.inner.depth == 0);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.inner.native) == .SUCCESS);
    }
};

const StoreMutex = union(enum) {
    none,
    local: LocalMutex,
    subsystem: struct {
        owner: *sqlite_mutex.Subsystem,
        handle: ?sqlite_mutex.Handle,
    },

    fn init(mutex_subsystem: ?*sqlite_mutex.Subsystem) error{OutOfMemory}!StoreMutex {
        const owner = mutex_subsystem orelse return .{ .local = .{} };
        return .{ .subsystem = .{ .owner = owner, .handle = try owner.allocHandle(.fast) } };
    }

    fn lock(self: *StoreMutex) void {
        switch (self.*) {
            .none => {},
            .local => |*value| value.lock(),
            .subsystem => |*value| if (value.handle) |*handle| handle.enter(),
        }
    }

    fn unlock(self: *StoreMutex) void {
        switch (self.*) {
            .none => {},
            .local => |*value| value.unlock(),
            .subsystem => |*value| if (value.handle) |*handle| handle.leave(),
        }
    }

    fn deinit(self: *StoreMutex) void {
        switch (self.*) {
            .none => {},
            .local => |*value| value.deinit(),
            .subsystem => |*value| value.owner.freeHandle(value.handle),
        }
        self.* = .none;
    }
};

pub const OK: c_int = 0;
pub const OK_SYMLINK: c_int = OK | (2 << 8);
pub const ERROR: c_int = 1;
pub const PERM: c_int = 3;
pub const READONLY: c_int = 8;
pub const CORRUPT: c_int = 11;
pub const FULL: c_int = 13;
pub const MISUSE: c_int = 21;
pub const BUSY: c_int = 5;
pub const NOMEM: c_int = 7;
pub const CANTOPEN: c_int = 14;
pub const NOTFOUND: c_int = 12;
pub const WARNING: c_int = 28;
pub const IOERR: c_int = 10;
pub const IOERR_READ: c_int = IOERR | (1 << 8);
pub const IOERR_SHORT_READ: c_int = IOERR | (2 << 8);
pub const IOERR_WRITE: c_int = IOERR | (3 << 8);
pub const IOERR_FSYNC: c_int = IOERR | (4 << 8);
pub const IOERR_DIR_FSYNC: c_int = IOERR | (5 << 8);
pub const IOERR_TRUNCATE: c_int = IOERR | (6 << 8);
pub const IOERR_FSTAT: c_int = IOERR | (7 << 8);
pub const IOERR_UNLOCK: c_int = IOERR | (8 << 8);
pub const IOERR_RDLOCK: c_int = IOERR | (9 << 8);
pub const IOERR_DELETE: c_int = IOERR | (10 << 8);
pub const IOERR_ACCESS: c_int = IOERR | (13 << 8);
pub const IOERR_CHECKRESERVEDLOCK: c_int = IOERR | (14 << 8);
pub const IOERR_LOCK: c_int = IOERR | (15 << 8);
pub const IOERR_CLOSE: c_int = IOERR | (16 << 8);
pub const IOERR_SHMOPEN: c_int = IOERR | (18 << 8);
pub const IOERR_SHMMAP: c_int = IOERR | (21 << 8);
pub const IOERR_SHMLOCK: c_int = IOERR | (20 << 8);
pub const IOERR_GETTEMPPATH: c_int = IOERR | (25 << 8);
pub const IOERR_DELETE_NOENT: c_int = IOERR | (23 << 8);
pub const IOERR_CORRUPTFS: c_int = IOERR | (33 << 8);
pub const IOERR_NOMEM: c_int = IOERR | (12 << 8);

pub const OPEN_READONLY: c_int = 0x00000001;
pub const OPEN_READWRITE: c_int = 0x00000002;
pub const OPEN_CREATE: c_int = 0x00000004;
pub const OPEN_DELETEONCLOSE: c_int = 0x00000008;
pub const OPEN_EXCLUSIVE: c_int = 0x00000010;
pub const OPEN_URI: c_int = 0x00000040;
pub const OPEN_MEMORY: c_int = 0x00000080;
pub const DESERIALIZE_FREEONCLOSE: c_uint = 0x001;
pub const DESERIALIZE_RESIZEABLE: c_uint = 0x002;
pub const DESERIALIZE_READONLY: c_uint = 0x004;
pub const OPEN_MAIN_DB: c_int = 0x00000100;
pub const OPEN_TEMP_DB: c_int = 0x00000200;
pub const OPEN_TRANSIENT_DB: c_int = 0x00000400;
pub const OPEN_MAIN_JOURNAL: c_int = 0x00000800;
pub const OPEN_TEMP_JOURNAL: c_int = 0x00001000;
pub const OPEN_SUBJOURNAL: c_int = 0x00002000;
pub const OPEN_WAL: c_int = 0x00080000;

pub const ACCESS_EXISTS: c_int = 0;
pub const ACCESS_READWRITE: c_int = 1;
pub const ACCESS_READ: c_int = 2;
pub const LOCK_NONE: c_int = 0;
pub const LOCK_SHARED: c_int = 1;
pub const LOCK_RESERVED: c_int = 2;
pub const LOCK_PENDING: c_int = 3;
pub const LOCK_EXCLUSIVE: c_int = 4;
pub const SHM_UNLOCK: c_int = 1;
pub const SHM_LOCK: c_int = 2;
pub const SHM_SHARED: c_int = 4;
pub const SHM_EXCLUSIVE: c_int = 8;
pub const SHM_REGION_SIZE: usize = 32_768;
pub const FCNTL_LOCKSTATE: c_int = 1;
pub const FCNTL_LAST_ERRNO: c_int = 4;
pub const FCNTL_SIZE_HINT: c_int = 5;
pub const FCNTL_CHUNK_SIZE: c_int = 6;
pub const FCNTL_PERSIST_WAL: c_int = 10;
pub const FCNTL_VFSNAME: c_int = 12;
pub const FCNTL_POWERSAFE_OVERWRITE: c_int = 13;
pub const FCNTL_TEMPFILENAME: c_int = 16;
pub const FCNTL_MMAP_SIZE: c_int = 18;
pub const FCNTL_HAS_MOVED: c_int = 20;
pub const FCNTL_SIZE_LIMIT: c_int = 36;
pub const FCNTL_EXTERNAL_READER: c_int = 40;
pub const FCNTL_NULL_IO: c_int = 43;

pub const FileKind = enum { database, journal, wal, temporary, other };
pub const Method = enum {
    open,
    delete,
    access,
    full_pathname,
    close,
    read,
    write,
    truncate,
    sync,
    file_size,
    lock,
    unlock,
    check_reserved,
    file_control,
    sector_size,
    device_characteristics,
    shm_map,
    shm_lock,
    shm_unmap,
    shm_barrier,
    randomness,
    sleep,
    current_time,
};
pub const FaultMode = enum { one_shot, sticky, short_operation };
pub const FaultRule = struct { method: Method, at: usize = 0, mode: FaultMode = .one_shot, code: c_int = IOERR };
pub const FaultAction = union(enum) { none, fail: c_int, short };

pub const FaultController = struct {
    rules: []const FaultRule,
    counts: [@typeInfo(Method).@"enum".fields.len]usize = .{0} ** @typeInfo(Method).@"enum".fields.len,
    fired: [@typeInfo(Method).@"enum".fields.len]usize = .{0} ** @typeInfo(Method).@"enum".fields.len,
    total_calls: usize = 0,
    hard_bound: usize = 100_000,

    pub fn check(self: *FaultController, method: Method) FaultAction {
        self.total_calls += 1;
        std.debug.assert(self.total_calls <= self.hard_bound);
        const index = @intFromEnum(method);
        const call = self.counts[index];
        self.counts[index] += 1;
        for (self.rules) |rule| {
            if (rule.method != method or call < rule.at) continue;
            if (rule.mode == .one_shot and self.fired[index] != 0) continue;
            self.fired[index] += 1;
            return if (rule.mode == .short_operation) .short else .{ .fail = rule.code };
        }
        return .none;
    }

    pub fn injectionWasTriggered(self: *const FaultController, method: Method) bool {
        return self.fired[@intFromEnum(method)] != 0;
    }
};

pub const Event = struct { method: Method, kind: FileKind };

const FileState = struct {
    name: []u8,
    mutex: StoreMutex = .none,
    volatile_data: std.ArrayList(u8) = .empty,
    durable: std.ArrayList(u8) = .empty,
    locks: [5]usize = .{0} ** 5,
    memdb_read_locks: usize = 0,
    memdb_write_lock: bool = false,
    memdb_mmap_count: usize = 0,
    memdb_resizable: bool = true,
    memdb_readonly: bool = false,
    external_data: ?[*]u8 = null,
    external_manager: ?*memory.Manager = null,
    external_size: usize = 0,
    external_capacity: usize = 0,
    external_flags: c_uint = 0,
    size_max: i64 = std.math.maxInt(i64),
    open_count: usize = 0,
    shm: std.ArrayList(u8) = .empty,
    shm_shared: [8]usize = .{0} ** 8,
    shm_exclusive: [8]bool = .{false} ** 8,

    fn data(self: *FileState) []u8 {
        if (self.external_data) |pointer| return pointer[0..self.external_size];
        return self.volatile_data.items;
    }

    fn capacity(self: *const FileState) usize {
        return if (self.external_data != null) self.external_capacity else self.volatile_data.capacity;
    }

    fn isMemdbStore(self: *const FileState, vfs_memdb_mode: bool) bool {
        return vfs_memdb_mode or self.external_data != null;
    }
};

pub const MemoryFile = struct {
    vfs: *MemoryVfs,
    state: *FileState,
    kind: FileKind,
    lock_level: c_int = LOCK_NONE,
    delete_on_close: bool = false,
    closed: bool = false,
    shm_shared_mask: u8 = 0,
    shm_exclusive_mask: u8 = 0,
    private_state: bool = false,
    mmap_count: usize = 0,

    pub fn close(self: *MemoryFile) c_int {
        if (self.closed) return OK;
        const fault_rc = self.vfs.fault(.close);
        self.state.mutex.lock();
        if (self.lock_level > LOCK_NONE) {
            if (self.vfs.memdb_mode) {
                if (self.lock_level > LOCK_SHARED) self.state.memdb_write_lock = false;
                std.debug.assert(self.state.memdb_read_locks > 0);
                self.state.memdb_read_locks -= 1;
            } else {
                self.state.locks[@intCast(self.lock_level)] -= 1;
            }
            self.lock_level = LOCK_NONE;
            self.vfs.record(.unlock, self.kind);
        }
        for (0..8) |index| {
            const bit: u8 = @as(u8, 1) << @intCast(index);
            if (self.shm_shared_mask & bit != 0) self.state.shm_shared[index] -= 1;
            if (self.shm_exclusive_mask & bit != 0) self.state.shm_exclusive[index] = false;
        }
        self.shm_shared_mask = 0;
        self.shm_exclusive_mask = 0;
        self.state.open_count -= 1;
        self.closed = true;
        self.state.mutex.unlock();
        if (self.delete_on_close) _ = self.vfs.delete(self.state.name, false);
        return fault_rc orelse OK;
    }

    pub fn read(self: *MemoryFile, output: []u8, offset: u64) c_int {
        const action = self.vfs.action(.read);
        if (action == .fail) return action.fail;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        @memset(output, 0);
        const bytes = self.state.data();
        const start = std.math.cast(usize, offset) orelse return IOERR_SHORT_READ;
        if (start >= bytes.len) return IOERR_SHORT_READ;
        var count = @min(output.len, bytes.len - start);
        if (action == .short and count > 0) count = @max(@as(usize, 1), count / 2);
        @memcpy(output[0..count], bytes[start..][0..count]);
        return if (count == output.len) OK else IOERR_SHORT_READ;
    }

    pub fn write(self: *MemoryFile, input: []const u8, offset: u64) c_int {
        const action = self.vfs.action(.write);
        if (action == .fail) return action.fail;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        var count = input.len;
        if (action == .short and count > 0) count = @max(@as(usize, 1), count / 2);
        const memdb_store = self.state.isMemdbStore(self.vfs.memdb_mode);
        const start = std.math.cast(usize, offset) orelse return if (memdb_store) FULL else NOMEM;
        const end = std.math.add(usize, start, count) catch return if (memdb_store) FULL else NOMEM;
        if (memdb_store and self.state.memdb_readonly) return IOERR_WRITE;
        const old_length = self.state.data().len;
        if (end > old_length) {
            if (memdb_store and end > self.state.capacity()) {
                const maximum = std.math.cast(usize, self.state.size_max) orelse return FULL;
                if (!self.state.memdb_resizable or self.state.memdb_mmap_count > 0 or end > maximum) return FULL;
                const capacity = if (end > maximum / 2) maximum else end * 2;
                if (self.state.external_data) |old_pointer| {
                    const manager = self.state.external_manager orelse unreachable;
                    const allocation = manager.realloc(@ptrCast(old_pointer), capacity) orelse return IOERR_NOMEM;
                    self.state.external_data = @ptrCast(allocation);
                    self.state.external_capacity = capacity;
                } else {
                    self.state.volatile_data.ensureTotalCapacityPrecise(self.vfs.allocator, capacity) catch return IOERR_NOMEM;
                }
            }
            if (self.state.external_data != null) {
                self.state.external_size = end;
            } else {
                self.state.volatile_data.resize(self.vfs.allocator, end) catch return if (memdb_store) IOERR_NOMEM else NOMEM;
            }
            @memset(self.state.data()[old_length..end], 0);
        }
        @memcpy(self.state.data()[start..end], input[0..count]);
        self.vfs.record(.write, self.kind);
        return if (count == input.len) OK else IOERR_WRITE;
    }

    pub fn truncate(self: *MemoryFile, size: u64) c_int {
        if (self.vfs.fault(.truncate)) |rc| return rc;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        const old_length = self.state.data().len;
        const memdb_store = self.state.isMemdbStore(self.vfs.memdb_mode);
        if (memdb_store and size > old_length) return CORRUPT;
        if (self.state.external_data != null) {
            self.state.external_size = @intCast(size);
        } else {
            self.state.volatile_data.resize(self.vfs.allocator, @intCast(size)) catch return NOMEM;
            if (size > @as(u64, @intCast(old_length))) @memset(self.state.volatile_data.items[old_length..@intCast(size)], 0);
        }
        self.vfs.record(.truncate, self.kind);
        return OK;
    }

    pub fn sync(self: *MemoryFile) c_int {
        if (self.vfs.fault(.sync)) |rc| return rc;
        if (self.state.isMemdbStore(self.vfs.memdb_mode)) return OK;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        self.state.durable.clearRetainingCapacity();
        self.state.durable.appendSlice(self.vfs.allocator, self.state.data()) catch return NOMEM;
        self.vfs.record(.sync, self.kind);
        return OK;
    }

    pub fn fileSize(self: *MemoryFile, output: *u64) c_int {
        if (self.vfs.fault(.file_size)) |rc| return rc;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        output.* = self.state.data().len;
        return OK;
    }

    pub fn lock(self: *MemoryFile, target: c_int) c_int {
        if (self.vfs.fault(.lock)) |rc| return rc;
        if (target <= self.lock_level) return OK;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        if (self.vfs.memdb_mode) {
            if (target > LOCK_SHARED and self.state.memdb_readonly) return READONLY;
            switch (target) {
                LOCK_SHARED => {
                    if (self.state.memdb_write_lock) return BUSY;
                    self.state.memdb_read_locks += 1;
                },
                LOCK_RESERVED, LOCK_PENDING => {
                    if (self.lock_level == LOCK_SHARED) {
                        if (self.state.memdb_write_lock) return BUSY;
                        self.state.memdb_write_lock = true;
                    }
                },
                LOCK_EXCLUSIVE => {
                    if (self.state.memdb_read_locks > 1) return BUSY;
                    if (self.lock_level == LOCK_SHARED) self.state.memdb_write_lock = true;
                },
                else => return ERROR,
            }
            self.lock_level = target;
            self.vfs.record(.lock, self.kind);
            return OK;
        }
        if (target == LOCK_SHARED and self.state.locks[LOCK_EXCLUSIVE] != 0) return BUSY;
        if (target == LOCK_RESERVED and (self.state.locks[LOCK_RESERVED] != 0 or self.state.locks[LOCK_EXCLUSIVE] != 0)) return BUSY;
        if (target >= LOCK_EXCLUSIVE) {
            const mine: usize = if (self.lock_level > LOCK_NONE) 1 else 0;
            var total: usize = 0;
            for (self.state.locks[1..]) |count| total += count;
            if (total > mine) return BUSY;
        }
        if (self.lock_level > LOCK_NONE) self.state.locks[@intCast(self.lock_level)] -= 1;
        self.lock_level = target;
        self.state.locks[@intCast(target)] += 1;
        self.vfs.record(.lock, self.kind);
        return OK;
    }

    pub fn unlock(self: *MemoryFile, target: c_int) c_int {
        if (self.vfs.fault(.unlock)) |rc| return rc;
        if (target >= self.lock_level) return OK;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        if (self.vfs.memdb_mode) {
            if (target != LOCK_SHARED and target != LOCK_NONE) return ERROR;
            if (target == LOCK_SHARED) {
                if (self.lock_level > LOCK_SHARED) self.state.memdb_write_lock = false;
            } else {
                if (self.lock_level > LOCK_SHARED) self.state.memdb_write_lock = false;
                std.debug.assert(self.state.memdb_read_locks > 0);
                self.state.memdb_read_locks -= 1;
            }
            self.lock_level = target;
            self.vfs.record(.unlock, self.kind);
            return OK;
        }
        self.state.locks[@intCast(self.lock_level)] -= 1;
        self.lock_level = target;
        if (target > LOCK_NONE) self.state.locks[@intCast(target)] += 1;
        self.vfs.record(.unlock, self.kind);
        return OK;
    }

    pub fn checkReserved(self: *MemoryFile, output: *c_int) c_int {
        if (self.vfs.fault(.check_reserved)) |rc| return rc;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        output.* = if (self.vfs.memdb_mode) @intFromBool(self.state.memdb_write_lock) else @intFromBool(self.state.locks[LOCK_RESERVED] != 0 or self.state.locks[LOCK_PENDING] != 0 or self.state.locks[LOCK_EXCLUSIVE] != 0);
        return OK;
    }

    pub fn shmMap(self: *MemoryFile, region: c_int, region_size: c_int, extend: c_int, output: *?*volatile anyopaque) c_int {
        if (self.vfs.fault(.shm_map)) |rc| return rc;
        if (region < 0 or region_size != SHM_REGION_SIZE or region >= 4) return IOERR_SHMMAP;
        const needed = (@as(usize, @intCast(region)) + 1) * SHM_REGION_SIZE;
        if (self.state.shm.items.len < needed) {
            if (extend == 0) {
                output.* = null;
                return OK;
            }
            const old = self.state.shm.items.len;
            self.state.shm.resize(self.vfs.allocator, 4 * SHM_REGION_SIZE) catch return NOMEM;
            @memset(self.state.shm.items[old..], 0);
        }
        output.* = @ptrCast(self.state.shm.items.ptr + @as(usize, @intCast(region)) * SHM_REGION_SIZE);
        return OK;
    }

    pub fn shmLock(self: *MemoryFile, offset: c_int, count: c_int, flags: c_int) c_int {
        if (self.vfs.fault(.shm_lock)) |rc| return rc;
        if (offset < 0 or count <= 0 or offset + count > 8) return IOERR_SHMLOCK;
        const locking = flags & SHM_LOCK != 0;
        const exclusive = flags & SHM_EXCLUSIVE != 0;
        if (locking) {
            for (@as(usize, @intCast(offset))..@as(usize, @intCast(offset + count))) |index| {
                const bit: u8 = @as(u8, 1) << @intCast(index);
                const mine_shared: usize = if (self.shm_shared_mask & bit != 0) 1 else 0;
                if (exclusive) {
                    if (self.state.shm_exclusive[index] or self.state.shm_shared[index] > mine_shared) return BUSY;
                } else if (self.state.shm_exclusive[index] and self.shm_exclusive_mask & bit == 0) return BUSY;
            }
            for (@as(usize, @intCast(offset))..@as(usize, @intCast(offset + count))) |index| {
                const bit: u8 = @as(u8, 1) << @intCast(index);
                if (exclusive) {
                    self.state.shm_exclusive[index] = true;
                    self.shm_exclusive_mask |= bit;
                } else if (self.shm_shared_mask & bit == 0) {
                    self.state.shm_shared[index] += 1;
                    self.shm_shared_mask |= bit;
                }
            }
        } else {
            for (@as(usize, @intCast(offset))..@as(usize, @intCast(offset + count))) |index| {
                const bit: u8 = @as(u8, 1) << @intCast(index);
                if (flags & SHM_SHARED != 0 and self.shm_shared_mask & bit != 0) {
                    self.state.shm_shared[index] -= 1;
                    self.shm_shared_mask &= ~bit;
                }
                if (exclusive and self.shm_exclusive_mask & bit != 0) {
                    self.state.shm_exclusive[index] = false;
                    self.shm_exclusive_mask &= ~bit;
                }
            }
        }
        self.vfs.record(.shm_lock, self.kind);
        return OK;
    }

    pub fn fetch(self: *MemoryFile, offset: i64, amount: c_int, output: *?*anyopaque) c_int {
        output.* = null;
        if (offset < 0 or amount < 0) return IOERR;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        const start: usize = @intCast(offset);
        const count: usize = @intCast(amount);
        const bytes = self.state.data();
        if (start > bytes.len or count > bytes.len - start) return OK;
        const memdb_store = self.state.isMemdbStore(self.vfs.memdb_mode);
        if (memdb_store and self.state.memdb_resizable) return OK;
        if (memdb_store) self.state.memdb_mmap_count += 1 else self.mmap_count += 1;
        output.* = bytes.ptr + start;
        return OK;
    }

    pub fn unfetch(self: *MemoryFile) c_int {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        if (self.state.isMemdbStore(self.vfs.memdb_mode)) {
            if (self.state.memdb_mmap_count > 0) self.state.memdb_mmap_count -= 1;
        } else if (self.mmap_count > 0) self.mmap_count -= 1;
        return OK;
    }

    pub fn fileControl(self: *MemoryFile, operation: c_int, argument: ?*anyopaque) c_int {
        if (self.vfs.fault(.file_control)) |rc| return rc;
        if (!self.vfs.memdb_mode) return NOTFOUND;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        switch (operation) {
            FCNTL_VFSNAME => {
                const raw = argument orelse return ERROR;
                const output: *?[*:0]u8 = @ptrCast(@alignCast(raw));
                var temporary: [128]u8 = undefined;
                const text = std.fmt.bufPrint(&temporary, "memdb(0x{x},{d})", .{ @intFromPtr(self.state.data().ptr), self.state.data().len }) catch return NOMEM;
                if (self.vfs.vfs_name_manager) |manager| {
                    const allocation = manager.alloc(text.len + 1) orelse return NOMEM;
                    const bytes = @as([*]u8, @ptrCast(allocation))[0 .. text.len + 1];
                    @memcpy(bytes[0..text.len], text);
                    bytes[text.len] = 0;
                    output.* = @ptrCast(bytes.ptr);
                } else {
                    const name = self.vfs.allocator.dupeZ(u8, text) catch return NOMEM;
                    output.* = name.ptr;
                }
                return OK;
            },
            FCNTL_SIZE_LIMIT => {
                const raw = argument orelse return ERROR;
                const limit: *i64 = @ptrCast(@alignCast(raw));
                var value = limit.*;
                const size: i64 = @intCast(self.state.data().len);
                if (value < size) value = if (value < 0) self.state.size_max else size;
                self.state.size_max = value;
                limit.* = value;
                return OK;
            },
            else => return NOTFOUND,
        }
    }

    pub fn shmUnmap(self: *MemoryFile, delete_flag: c_int) c_int {
        if (self.vfs.fault(.shm_unmap)) |rc| return rc;
        if (delete_flag != 0) {
            self.state.shm.clearRetainingCapacity();
            @memset(&self.state.shm_shared, 0);
            @memset(&self.state.shm_exclusive, false);
        }
        return OK;
    }
};

pub const MemoryVfs = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(*FileState),
    faults: ?*FaultController = null,
    events: std.ArrayList(Event) = .empty,
    temp_counter: usize = 0,
    memdb_mode: bool = false,
    memdb_max_size: i64 = 1_073_741_824,
    vfs_name_manager: ?*memory.Manager = null,
    memdb_mutex_subsystem: ?*sqlite_mutex.Subsystem = null,
    registry_mutex: LocalMutex = .{},
    event_mutex: LocalMutex = .{},

    pub fn init(allocator: std.mem.Allocator) MemoryVfs {
        return .{ .allocator = allocator, .files = std.StringHashMap(*FileState).init(allocator) };
    }

    pub fn initMemdb(allocator: std.mem.Allocator) MemoryVfs {
        return .{ .allocator = allocator, .files = std.StringHashMap(*FileState).init(allocator), .memdb_mode = true };
    }

    pub fn deinit(self: *MemoryVfs) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| self.destroyState(entry.value_ptr.*);
        self.files.deinit();
        self.events.deinit(self.allocator);
        self.registry_mutex.deinit();
        self.event_mutex.deinit();
    }

    fn destroyState(self: *MemoryVfs, state: *FileState) void {
        state.mutex.deinit();
        if (state.external_data) |pointer| {
            if (state.external_flags & DESERIALIZE_FREEONCLOSE != 0) {
                const manager = state.external_manager orelse unreachable;
                manager.free(@ptrCast(pointer));
            }
        }
        state.volatile_data.deinit(self.allocator);
        state.durable.deinit(self.allocator);
        state.shm.deinit(self.allocator);
        self.allocator.free(state.name);
        self.allocator.destroy(state);
    }

    pub fn action(self: *MemoryVfs, method: Method) FaultAction {
        return if (self.faults) |faults| faults.check(method) else .none;
    }
    fn fault(self: *MemoryVfs, method: Method) ?c_int {
        const result = self.action(method);
        return if (result == .fail) result.fail else null;
    }
    pub fn record(self: *MemoryVfs, method: Method, kind: FileKind) void {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        self.events.append(self.allocator, .{ .method = method, .kind = kind }) catch {};
    }

    pub fn setMemdbMaxSize(self: *MemoryVfs, maximum: i64) void {
        std.debug.assert(self.memdb_mode);
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        self.memdb_max_size = maximum;
    }

    pub fn attachMemdbMutexSubsystem(self: *MemoryVfs, subsystem: *sqlite_mutex.Subsystem) void {
        std.debug.assert(self.memdb_mode and subsystem.initialized);
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        std.debug.assert(self.files.count() == 0);
        self.memdb_mutex_subsystem = subsystem;
    }

    fn classify(flags: c_int) FileKind {
        if (flags & OPEN_MAIN_DB != 0) return .database;
        if (flags & OPEN_MAIN_JOURNAL != 0) return .journal;
        if (flags & OPEN_WAL != 0) return .wal;
        if (flags & (OPEN_TEMP_DB | OPEN_TEMP_JOURNAL | OPEN_TRANSIENT_DB | OPEN_SUBJOURNAL) != 0) return .temporary;
        return .other;
    }

    pub fn open(self: *MemoryVfs, supplied_name: ?[]const u8, flags: c_int) struct { rc: c_int, file: ?*MemoryFile } {
        if (self.fault(.open)) |rc| return .{ .rc = rc, .file = null };
        var temp: [64]u8 = undefined;
        const name = supplied_name orelse std.fmt.bufPrint(&temp, "sqlite-temp-{d}", .{self.temp_counter}) catch unreachable;
        if (supplied_name == null) self.temp_counter += 1;
        const shared_memdb = self.memdb_mode and name.len > 1 and (name[0] == '/' or name[0] == '\\');
        const private_state = self.memdb_mode and !shared_memdb;
        if (shared_memdb) self.registry_mutex.lock();
        defer if (shared_memdb) self.registry_mutex.unlock();
        var state = if (private_state) null else self.files.get(name);
        if (state == null) {
            if (!self.memdb_mode and flags & OPEN_CREATE == 0 and supplied_name != null) return .{ .rc = CANTOPEN, .file = null };
            const created = self.allocator.create(FileState) catch return .{ .rc = NOMEM, .file = null };
            created.* = .{ .name = self.allocator.dupe(u8, name) catch {
                self.allocator.destroy(created);
                return .{ .rc = NOMEM, .file = null };
            }, .size_max = if (self.memdb_mode) self.memdb_max_size else std.math.maxInt(i64) };
            if (shared_memdb) {
                created.mutex = StoreMutex.init(self.memdb_mutex_subsystem) catch {
                    self.destroyState(created);
                    return .{ .rc = NOMEM, .file = null };
                };
            } else if (!self.memdb_mode) {
                created.mutex = .{ .local = .{} };
            }
            if (!private_state) self.files.put(created.name, created) catch {
                self.destroyState(created);
                return .{ .rc = NOMEM, .file = null };
            };
            state = created;
        }
        const handle = self.allocator.create(MemoryFile) catch {
            if (private_state) self.destroyState(state.?);
            return .{ .rc = NOMEM, .file = null };
        };
        handle.* = .{ .vfs = self, .state = state.?, .kind = classify(flags), .delete_on_close = !self.memdb_mode and flags & OPEN_DELETEONCLOSE != 0, .private_state = private_state };
        state.?.mutex.lock();
        state.?.open_count += 1;
        state.?.mutex.unlock();
        self.record(.open, handle.kind);
        return .{ .rc = OK, .file = handle };
    }

    pub fn closeAndDestroy(self: *MemoryVfs, file: *MemoryFile) c_int {
        const state = file.state;
        const private_state = file.private_state;
        if (self.memdb_mode and !private_state) self.registry_mutex.lock();
        const rc = file.close();
        state.mutex.lock();
        const last_close = state.open_count == 0;
        state.mutex.unlock();
        if (self.memdb_mode and last_close and !private_state) _ = self.files.remove(state.name);
        if (self.memdb_mode and !private_state) self.registry_mutex.unlock();
        if (file.closed) {
            self.allocator.destroy(file);
            if (self.memdb_mode and last_close) self.destroyState(state);
        }
        return rc;
    }

    pub fn delete(self: *MemoryVfs, name: []const u8, sync_directory: bool) c_int {
        if (self.fault(.delete)) |rc| return rc;
        if (self.files.fetchRemove(name)) |entry| {
            if (entry.value.open_count != 0) {
                self.files.put(entry.key, entry.value) catch {};
                return BUSY;
            }
            self.record(.delete, classify(if (std.mem.endsWith(u8, name, "-journal")) OPEN_MAIN_JOURNAL else 0));
            self.destroyState(entry.value);
        }
        _ = sync_directory;
        return OK;
    }

    pub fn access(self: *MemoryVfs, name: []const u8, _: c_int, output: *c_int) c_int {
        if (self.fault(.access)) |rc| return rc;
        output.* = @intFromBool(self.files.contains(name));
        return OK;
    }

    pub fn fullPathname(self: *MemoryVfs, name: []const u8, output: []u8) c_int {
        if (self.fault(.full_pathname)) |rc| return rc;
        if (name.len + 1 > output.len) return CANTOPEN;
        @memcpy(output[0..name.len], name);
        output[name.len] = 0;
        return OK;
    }

    pub fn adoptVolatileBuffer(self: *MemoryVfs, file: *MemoryFile, data: [*]u8, size: usize, capacity: usize, flags: c_uint) void {
        self.adoptVolatileBufferWithManager(file, data, size, capacity, flags, &memory.process_manager);
    }

    /// Source deserialized buffers retain the allocator domain used by
    /// sqlite3_realloc64() and sqlite3_free() for growth and final ownership.
    pub fn adoptVolatileBufferWithManager(self: *MemoryVfs, file: *MemoryFile, data: [*]u8, size: usize, capacity: usize, flags: c_uint, manager: *memory.Manager) void {
        std.debug.assert(file.vfs == self and size <= capacity and manager.started);
        const state = file.state;
        state.mutex.lock();
        defer state.mutex.unlock();
        std.debug.assert(state.external_data == null);
        state.volatile_data.deinit(self.allocator);
        state.volatile_data = .empty;
        state.external_data = data;
        state.external_manager = manager;
        state.external_size = size;
        state.external_capacity = capacity;
        state.external_flags = flags;
        state.memdb_resizable = flags & DESERIALIZE_RESIZEABLE != 0;
        state.memdb_readonly = flags & DESERIALIZE_READONLY != 0;
        state.size_max = @max(@as(i64, @intCast(capacity)), self.memdb_max_size);
    }

    pub fn borrowVolatile(self: *MemoryVfs, name: []const u8) ?[]u8 {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        const state = self.files.get(name) orelse return null;
        state.mutex.lock();
        defer state.mutex.unlock();
        return state.data();
    }

    pub fn copyVolatile(self: *const MemoryVfs, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const state = self.files.get(name) orelse return error.FileNotFound;
        return allocator.dupe(u8, state.data());
    }

    pub fn copyDurable(self: *const MemoryVfs, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const state = self.files.get(name) orelse return error.FileNotFound;
        return allocator.dupe(u8, state.durable.items);
    }

    pub fn recoverRollback(self: *MemoryVfs, database_name: []const u8, journal_name: []const u8) c_int {
        const journal = self.files.get(journal_name) orelse return OK;
        const database = self.files.get(database_name) orelse return CANTOPEN;
        database.durable.clearRetainingCapacity();
        database.durable.appendSlice(self.allocator, journal.durable.items) catch return NOMEM;
        database.volatile_data.clearRetainingCapacity();
        database.volatile_data.appendSlice(self.allocator, journal.durable.items) catch return NOMEM;
        return self.delete(journal_name, true);
    }

    pub fn crash(self: *MemoryVfs) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            const state = entry.value_ptr.*;
            state.volatile_data.clearRetainingCapacity();
            state.volatile_data.appendSlice(self.allocator, state.durable.items) catch unreachable;
        }
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*MemoryVfs),
    default_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .entries = std.StringHashMap(*MemoryVfs).init(allocator) };
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit();
    }
    pub fn register(self: *Registry, name: []const u8, vfs: *MemoryVfs, make_default: bool) c_int {
        if (self.entries.contains(name)) return BUSY;
        self.entries.put(name, vfs) catch return NOMEM;
        if (make_default or self.default_name == null) self.default_name = name;
        return OK;
    }
    pub fn unregister(self: *Registry, name: []const u8) c_int {
        if (!self.entries.remove(name)) return NOTFOUND;
        if (self.default_name != null and std.mem.eql(u8, self.default_name.?, name)) self.default_name = null;
        return OK;
    }
    pub fn find(self: *Registry, name: ?[]const u8) ?*MemoryVfs {
        return self.entries.get(name orelse self.default_name orelse return null);
    }
};

// Public SQLite ABI layouts.
pub const sqlite3_file = extern struct { pMethods: ?*const sqlite3_io_methods };
pub const sqlite3_io_methods = extern struct {
    iVersion: c_int,
    xClose: ?*const fn (*sqlite3_file) callconv(.c) c_int,
    xRead: ?*const fn (*sqlite3_file, *anyopaque, c_int, i64) callconv(.c) c_int,
    xWrite: ?*const fn (*sqlite3_file, *const anyopaque, c_int, i64) callconv(.c) c_int,
    xTruncate: ?*const fn (*sqlite3_file, i64) callconv(.c) c_int,
    xSync: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xFileSize: ?*const fn (*sqlite3_file, *i64) callconv(.c) c_int,
    xLock: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xUnlock: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xCheckReservedLock: ?*const fn (*sqlite3_file, *c_int) callconv(.c) c_int,
    xFileControl: ?*const fn (*sqlite3_file, c_int, ?*anyopaque) callconv(.c) c_int,
    xSectorSize: ?*const fn (*sqlite3_file) callconv(.c) c_int,
    xDeviceCharacteristics: ?*const fn (*sqlite3_file) callconv(.c) c_int,
    xShmMap: ?*const fn (*sqlite3_file, c_int, c_int, c_int, *?*volatile anyopaque) callconv(.c) c_int,
    xShmLock: ?*const fn (*sqlite3_file, c_int, c_int, c_int) callconv(.c) c_int,
    xShmBarrier: ?*const fn (*sqlite3_file) callconv(.c) void,
    xShmUnmap: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xFetch: ?*const fn (*sqlite3_file, i64, c_int, *?*anyopaque) callconv(.c) c_int,
    xUnfetch: ?*const fn (*sqlite3_file, i64, ?*anyopaque) callconv(.c) c_int,
};
pub const sqlite3_vfs = extern struct {
    iVersion: c_int,
    szOsFile: c_int,
    mxPathname: c_int,
    pNext: ?*sqlite3_vfs,
    zName: [*:0]const u8,
    pAppData: ?*anyopaque,
    xOpen: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, *sqlite3_file, c_int, ?*c_int) callconv(.c) c_int,
    xDelete: ?*const fn (*sqlite3_vfs, [*:0]const u8, c_int) callconv(.c) c_int,
    xAccess: ?*const fn (*sqlite3_vfs, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
    xFullPathname: ?*const fn (*sqlite3_vfs, [*:0]const u8, c_int, [*]u8) callconv(.c) c_int,
    xDlOpen: ?*const fn (*sqlite3_vfs, [*:0]const u8) callconv(.c) ?*anyopaque,
    xDlError: ?*const fn (*sqlite3_vfs, c_int, [*]u8) callconv(.c) void,
    xDlSym: ?*const fn (*sqlite3_vfs, ?*anyopaque, [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void,
    xDlClose: ?*const fn (*sqlite3_vfs, ?*anyopaque) callconv(.c) void,
    xRandomness: ?*const fn (*sqlite3_vfs, c_int, [*]u8) callconv(.c) c_int,
    xSleep: ?*const fn (*sqlite3_vfs, c_int) callconv(.c) c_int,
    xCurrentTime: ?*const fn (*sqlite3_vfs, *f64) callconv(.c) c_int,
    xGetLastError: ?*const fn (*sqlite3_vfs, c_int, [*]u8) callconv(.c) c_int,
    xCurrentTimeInt64: ?*const fn (*sqlite3_vfs, *i64) callconv(.c) c_int,
    xSetSystemCall: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, ?*const fn () callconv(.c) void) callconv(.c) c_int,
    xGetSystemCall: ?*const fn (*sqlite3_vfs, [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void,
    xNextSystemCall: ?*const fn (*sqlite3_vfs, ?[*:0]const u8) callconv(.c) ?[*:0]const u8,
};

/// Source `sqlite3OsFileControl()`.
pub fn osFileControl(file: *sqlite3_file, operation: c_int, argument: ?*anyopaque) c_int {
    const methods = file.pMethods orelse return NOTFOUND;
    const control = methods.xFileControl orelse return NOTFOUND;
    return control(file, operation, argument);
}

/// Source `sqlite3OsShmMap()`.
pub fn osShmMap(file: *sqlite3_file, page: c_int, page_size: c_int, extend: c_int, output: *?*volatile anyopaque) c_int {
    const methods = file.pMethods orelse return IOERR_SHMMAP;
    const map = methods.xShmMap orelse return IOERR_SHMMAP;
    return map(file, page, page_size, extend, output);
}

/// Source `sqlite3OsOpen()`: mask connection-only flags before dispatching to
/// the VFS and require failed opens to leave no live method table.
pub fn osOpen(filesystem: *sqlite3_vfs, path: ?[*:0]const u8, file: *sqlite3_file, flags: c_int, output_flags: ?*c_int) c_int {
    const open = filesystem.xOpen orelse return CANTOPEN;
    const rc = open(filesystem, path, file, flags & 0x1087f7f, output_flags);
    std.debug.assert(rc == OK or file.pMethods == null);
    return rc;
}

pub const AlignedFileStorage = []align(@alignOf(sqlite3_file)) u8;
pub const AllocatedOpenResult = struct {
    result: c_int,
    file: ?*sqlite3_file = null,
    storage: ?AlignedFileStorage = null,
};

/// Source `sqlite3OsOpenMalloc()`: allocate zeroed VFS file storage and free it
/// atomically when xOpen fails.
pub fn osOpenAllocated(allocator: std.mem.Allocator, filesystem: *sqlite3_vfs, path: ?[*:0]const u8, flags: c_int, output_flags: ?*c_int) AllocatedOpenResult {
    if (filesystem.szOsFile < @sizeOf(sqlite3_file)) return .{ .result = CANTOPEN };
    const storage = allocator.alignedAlloc(u8, .of(sqlite3_file), @intCast(filesystem.szOsFile)) catch return .{ .result = NOMEM };
    @memset(storage, 0);
    const file: *sqlite3_file = @ptrCast(storage.ptr);
    const rc = osOpen(filesystem, path, file, flags, output_flags);
    if (rc != OK) {
        allocator.free(storage);
        return .{ .result = rc };
    }
    return .{ .result = OK, .file = file, .storage = storage };
}

/// Source `sqlite3OsFullPathname()`.
pub fn osFullPathname(filesystem: *sqlite3_vfs, path: [*:0]const u8, output: []u8) c_int {
    if (output.len == 0 or output.len > std.math.maxInt(c_int)) return CANTOPEN;
    output[0] = 0;
    const full_path = filesystem.xFullPathname orelse return CANTOPEN;
    return full_path(filesystem, path, @intCast(output.len), output.ptr);
}

/// Source `sqlite3OsRandomness()`.
pub fn osRandomness(filesystem: *sqlite3_vfs, output: []u8) c_int {
    if (output.len > std.math.maxInt(c_int)) return IOERR;
    const randomness = filesystem.xRandomness orelse return 0;
    return randomness(filesystem, @intCast(output.len), output.ptr);
}

/// Source `sqlite3OsCurrentTimeInt64()`: prefer the version-2 integer method
/// and otherwise convert Julian days from xCurrentTime to milliseconds.
pub fn osCurrentTimeInt64(filesystem: *sqlite3_vfs, output: *i64) c_int {
    if (filesystem.iVersion >= 2) {
        if (filesystem.xCurrentTimeInt64) |current_time| return current_time(filesystem, output);
    }
    const current_time = filesystem.xCurrentTime orelse return ERROR;
    var julian_days: f64 = 0;
    const rc = current_time(filesystem, &julian_days);
    const milliseconds = julian_days * 86_400_000.0;
    output.* = if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        std.math.maxInt(i64)
    else if (milliseconds <= @as(f64, @floatFromInt(std.math.minInt(i64))))
        std.math.minInt(i64)
    else
        @intFromFloat(milliseconds);
    return rc;
}

pub var process_vfs_head: ?*sqlite3_vfs = null;
var process_vfs_mutex: LocalMutex = .{};

/// Source `vfsUnlink()`: remove one exact VFS object from the process list
/// without disturbing registrations that merely share its name.
fn vfsUnlink(value: *sqlite3_vfs) void {
    var previous: ?*sqlite3_vfs = null;
    var current = process_vfs_head;
    while (current) |entry| : (current = entry.pNext) {
        if (entry == value) {
            if (previous) |before| {
                before.pNext = entry.pNext;
            } else {
                process_vfs_head = entry.pNext;
            }
            entry.pNext = null;
            return;
        }
        previous = entry;
    }
}

/// Source `sqlite3_vfs_find()` registry lookup under the process mutex.
pub fn findProcessVfs(name: ?[]const u8) ?*sqlite3_vfs {
    process_vfs_mutex.lock();
    defer process_vfs_mutex.unlock();
    if (name == null) return process_vfs_head;
    var current = process_vfs_head;
    while (current) |item| : (current = item.pNext) {
        if (std.mem.eql(u8, std.mem.span(item.zName), name.?)) return item;
    }
    return null;
}

/// Source `sqlite3_vfs_unregister()` after public auto-initialization.
pub fn unregisterProcessVfs(value: *sqlite3_vfs) void {
    process_vfs_mutex.lock();
    defer process_vfs_mutex.unlock();
    vfsUnlink(value);
}

/// Source `sqlite3_vfs_register()`; non-default registrations are placed
/// immediately after the current default just like the pinned list owner.
pub fn registerProcessVfs(value: *sqlite3_vfs, make_default: bool) void {
    process_vfs_mutex.lock();
    defer process_vfs_mutex.unlock();
    vfsUnlink(value);
    if (make_default or process_vfs_head == null) {
        value.pNext = process_vfs_head;
        process_vfs_head = value;
    } else {
        value.pNext = process_vfs_head.?.pNext;
        process_vfs_head.?.pNext = value;
    }
}

const AbiFile = extern struct { base: sqlite3_file, native: ?*MemoryFile, owner: ?*MemoryVfs };

fn abiFile(file: *sqlite3_file) *AbiFile {
    return @ptrCast(@alignCast(file));
}
fn app(vfs: *sqlite3_vfs) *MemoryVfs {
    return @ptrCast(@alignCast(vfs.pAppData.?));
}
fn spanZ(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}

fn axClose(file: *sqlite3_file) callconv(.c) c_int {
    const a = abiFile(file);
    const rc = a.owner.?.closeAndDestroy(a.native.?);
    a.native = null;
    a.base.pMethods = null;
    return rc;
}
fn axRead(file: *sqlite3_file, out: *anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    return abiFile(file).native.?.read(@as([*]u8, @ptrCast(out))[0..@intCast(n)], @intCast(off));
}
fn axWrite(file: *sqlite3_file, input: *const anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    return abiFile(file).native.?.write(@as([*]const u8, @ptrCast(input))[0..@intCast(n)], @intCast(off));
}
fn axTruncate(file: *sqlite3_file, n: i64) callconv(.c) c_int {
    return abiFile(file).native.?.truncate(@intCast(n));
}
fn axSync(file: *sqlite3_file, _: c_int) callconv(.c) c_int {
    return abiFile(file).native.?.sync();
}
fn axSize(file: *sqlite3_file, out: *i64) callconv(.c) c_int {
    var n: u64 = 0;
    const rc = abiFile(file).native.?.fileSize(&n);
    out.* = @intCast(n);
    return rc;
}
fn axLock(file: *sqlite3_file, n: c_int) callconv(.c) c_int {
    return abiFile(file).native.?.lock(n);
}
fn axUnlock(file: *sqlite3_file, n: c_int) callconv(.c) c_int {
    return abiFile(file).native.?.unlock(n);
}
fn axReserved(file: *sqlite3_file, out: *c_int) callconv(.c) c_int {
    return abiFile(file).native.?.checkReserved(out);
}
fn axControl(file: *sqlite3_file, operation: c_int, argument: ?*anyopaque) callconv(.c) c_int {
    return abiFile(file).native.?.fileControl(operation, argument);
}
fn axSector(file: *sqlite3_file) callconv(.c) c_int {
    if (abiFile(file).owner.?.fault(.sector_size)) |rc| return rc;
    return 4096;
}
fn axDevice(file: *sqlite3_file) callconv(.c) c_int {
    if (abiFile(file).owner.?.fault(.device_characteristics)) |rc| return rc;
    return 0;
}
fn axShmMap(file: *sqlite3_file, region: c_int, size: c_int, extend: c_int, out: *?*volatile anyopaque) callconv(.c) c_int {
    return abiFile(file).native.?.shmMap(region, size, extend, out);
}
fn axShmLock(file: *sqlite3_file, offset: c_int, count: c_int, flags: c_int) callconv(.c) c_int {
    return abiFile(file).native.?.shmLock(offset, count, flags);
}
var shm_barrier_byte: u8 = 0;
fn axShmBarrier(file: *sqlite3_file) callconv(.c) void {
    const native = abiFile(file).native.?;
    _ = native.vfs.fault(.shm_barrier);
    native.vfs.record(.shm_barrier, native.kind);
    _ = @atomicRmw(u8, &shm_barrier_byte, .Add, 0, .seq_cst);
}
fn axShmUnmap(file: *sqlite3_file, delete_flag: c_int) callconv(.c) c_int {
    return abiFile(file).native.?.shmUnmap(delete_flag);
}
fn axFetch(_: *sqlite3_file, _: i64, _: c_int, out: *?*anyopaque) callconv(.c) c_int {
    out.* = null;
    return OK;
}
fn axUnfetch(_: *sqlite3_file, _: i64, _: ?*anyopaque) callconv(.c) c_int {
    return OK;
}
const io_methods = sqlite3_io_methods{ .iVersion = 3, .xClose = axClose, .xRead = axRead, .xWrite = axWrite, .xTruncate = axTruncate, .xSync = axSync, .xFileSize = axSize, .xLock = axLock, .xUnlock = axUnlock, .xCheckReservedLock = axReserved, .xFileControl = axControl, .xSectorSize = axSector, .xDeviceCharacteristics = axDevice, .xShmMap = axShmMap, .xShmLock = axShmLock, .xShmBarrier = axShmBarrier, .xShmUnmap = axShmUnmap, .xFetch = axFetch, .xUnfetch = axUnfetch };
fn memdbDevice(_: *sqlite3_file) callconv(.c) c_int {
    return 0x0001 | 0x0200 | 0x0400 | 0x1000;
}
fn memdbFetch(file: *sqlite3_file, offset: i64, amount: c_int, out: *?*anyopaque) callconv(.c) c_int {
    return abiFile(file).native.?.fetch(offset, amount, out);
}
fn memdbUnfetch(file: *sqlite3_file, _: i64, _: ?*anyopaque) callconv(.c) c_int {
    return abiFile(file).native.?.unfetch();
}
const memdb_io_methods = sqlite3_io_methods{ .iVersion = 3, .xClose = axClose, .xRead = axRead, .xWrite = axWrite, .xTruncate = axTruncate, .xSync = axSync, .xFileSize = axSize, .xLock = axLock, .xUnlock = axUnlock, .xCheckReservedLock = null, .xFileControl = axControl, .xSectorSize = null, .xDeviceCharacteristics = memdbDevice, .xShmMap = null, .xShmLock = null, .xShmBarrier = null, .xShmUnmap = null, .xFetch = memdbFetch, .xUnfetch = memdbUnfetch };

fn avOpen(v: *sqlite3_vfs, name: ?[*:0]const u8, file: *sqlite3_file, flags: c_int, out: ?*c_int) callconv(.c) c_int {
    const a = abiFile(file);
    a.* = .{ .base = .{ .pMethods = null }, .native = null, .owner = app(v) };
    const r = app(v).open(if (name) |n| spanZ(n) else null, flags);
    if (r.file) |f| {
        a.native = f;
        a.base.pMethods = &io_methods;
        if (out) |o| o.* = flags;
    }
    return r.rc;
}
pub const MemdbContext = struct {
    native: *MemoryVfs,
    original: *sqlite3_vfs,
};
fn memdbContext(v: *sqlite3_vfs) *MemdbContext {
    return @ptrCast(@alignCast(v.pAppData.?));
}
fn memdbOpen(v: *sqlite3_vfs, name: ?[*:0]const u8, file: *sqlite3_file, flags: c_int, out: ?*c_int) callconv(.c) c_int {
    const native = memdbContext(v).native;
    const a = abiFile(file);
    a.* = .{ .base = .{ .pMethods = null }, .native = null, .owner = native };
    const r = native.open(if (name) |n| spanZ(n) else null, flags);
    if (r.file) |f| {
        a.native = f;
        a.base.pMethods = &memdb_io_methods;
        if (out) |o| o.* = flags | OPEN_MEMORY;
    }
    return r.rc;
}
fn avDelete(v: *sqlite3_vfs, name: [*:0]const u8, sync: c_int) callconv(.c) c_int {
    return app(v).delete(spanZ(name), sync != 0);
}
fn avAccess(v: *sqlite3_vfs, name: [*:0]const u8, flags: c_int, out: *c_int) callconv(.c) c_int {
    return app(v).access(spanZ(name), flags, out);
}
fn memdbAccess(_: *sqlite3_vfs, _: [*:0]const u8, _: c_int, out: *c_int) callconv(.c) c_int {
    out.* = 0;
    return OK;
}
fn memdbFull(_: *sqlite3_vfs, name: [*:0]const u8, n: c_int, out: [*]u8) callconv(.c) c_int {
    const source = spanZ(name);
    const count: usize = @intCast(@max(n, 0));
    if (count == 0) return OK;
    const copied = @min(source.len, count - 1);
    @memcpy(out[0..copied], source[0..copied]);
    out[copied] = 0;
    return OK;
}
fn memdbDlOpen(v: *sqlite3_vfs, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    const original = memdbContext(v).original;
    return if (original.xDlOpen) |callback| callback(original, name) else null;
}
fn memdbDlError(v: *sqlite3_vfs, n: c_int, out: [*]u8) callconv(.c) void {
    const original = memdbContext(v).original;
    if (original.xDlError) |callback| callback(original, n, out) else if (n > 0) out[0] = 0;
}
fn memdbDlSym(v: *sqlite3_vfs, handle: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    const original = memdbContext(v).original;
    return if (original.xDlSym) |callback| callback(original, handle, name) else null;
}
fn memdbDlClose(v: *sqlite3_vfs, handle: ?*anyopaque) callconv(.c) void {
    const original = memdbContext(v).original;
    if (original.xDlClose) |callback| callback(original, handle);
}
fn memdbRandom(v: *sqlite3_vfs, n: c_int, out: [*]u8) callconv(.c) c_int {
    const original = memdbContext(v).original;
    return if (original.xRandomness) |callback| callback(original, n, out) else 0;
}
fn memdbSleep(v: *sqlite3_vfs, n: c_int) callconv(.c) c_int {
    const original = memdbContext(v).original;
    return if (original.xSleep) |callback| callback(original, n) else n;
}
fn memdbLast(v: *sqlite3_vfs, n: c_int, out: [*]u8) callconv(.c) c_int {
    const original = memdbContext(v).original;
    return if (original.xGetLastError) |callback| callback(original, n, out) else 0;
}
fn memdbTime64(v: *sqlite3_vfs, out: *i64) callconv(.c) c_int {
    const original = memdbContext(v).original;
    return if (original.xCurrentTimeInt64) |callback| callback(original, out) else ERROR;
}
fn avFull(v: *sqlite3_vfs, name: [*:0]const u8, n: c_int, out: [*]u8) callconv(.c) c_int {
    return app(v).fullPathname(spanZ(name), out[0..@intCast(n)]);
}
fn avDlOpen(_: *sqlite3_vfs, _: [*:0]const u8) callconv(.c) ?*anyopaque {
    return null;
}
fn avDlError(_: *sqlite3_vfs, n: c_int, out: [*]u8) callconv(.c) void {
    if (n > 0) out[0] = 0;
}
fn avDlSym(_: *sqlite3_vfs, _: ?*anyopaque, _: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return null;
}
fn avDlClose(_: *sqlite3_vfs, _: ?*anyopaque) callconv(.c) void {}
fn avRandom(v: *sqlite3_vfs, n: c_int, out: [*]u8) callconv(.c) c_int {
    if (app(v).fault(.randomness)) |rc| return rc;
    for (out[0..@intCast(n)], 0..) |*b, i| b.* = @truncate(0xa5 +% i);
    return n;
}
fn avSleep(v: *sqlite3_vfs, n: c_int) callconv(.c) c_int {
    if (app(v).fault(.sleep)) |rc| return rc;
    return n;
}
fn avTime(v: *sqlite3_vfs, out: *f64) callconv(.c) c_int {
    if (app(v).fault(.current_time)) |rc| return rc;
    out.* = 2440587.5;
    return OK;
}
fn avLast(_: *sqlite3_vfs, n: c_int, out: [*]u8) callconv(.c) c_int {
    if (n > 0) out[0] = 0;
    return 0;
}
fn avTime64(v: *sqlite3_vfs, out: *i64) callconv(.c) c_int {
    if (app(v).fault(.current_time)) |rc| return rc;
    out.* = 210866760000000;
    return OK;
}
fn avSet(_: *sqlite3_vfs, _: ?[*:0]const u8, _: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    return NOTFOUND;
}
fn avGet(_: *sqlite3_vfs, _: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return null;
}
fn avNext(_: *sqlite3_vfs, _: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return null;
}

pub const AbiAdapter = struct {
    abi: sqlite3_vfs,
    pub fn init(name: [*:0]const u8, native: *MemoryVfs) AbiAdapter {
        return .{ .abi = .{ .iVersion = 3, .szOsFile = @sizeOf(AbiFile), .mxPathname = 1024, .pNext = null, .zName = name, .pAppData = native, .xOpen = avOpen, .xDelete = avDelete, .xAccess = avAccess, .xFullPathname = avFull, .xDlOpen = avDlOpen, .xDlError = avDlError, .xDlSym = avDlSym, .xDlClose = avDlClose, .xRandomness = avRandom, .xSleep = avSleep, .xCurrentTime = avTime, .xGetLastError = avLast, .xCurrentTimeInt64 = avTime64, .xSetSystemCall = avSet, .xGetSystemCall = avGet, .xNextSystemCall = avNext } };
    }
};

pub const MemdbAdapter = struct {
    abi: sqlite3_vfs,
    pub fn init(context: *MemdbContext) MemdbAdapter {
        return .{ .abi = .{ .iVersion = 2, .szOsFile = @sizeOf(AbiFile), .mxPathname = 1024, .pNext = null, .zName = "memdb", .pAppData = context, .xOpen = memdbOpen, .xDelete = null, .xAccess = memdbAccess, .xFullPathname = memdbFull, .xDlOpen = memdbDlOpen, .xDlError = memdbDlError, .xDlSym = memdbDlSym, .xDlClose = memdbDlClose, .xRandomness = memdbRandom, .xSleep = memdbSleep, .xCurrentTime = null, .xGetLastError = memdbLast, .xCurrentTimeInt64 = memdbTime64, .xSetSystemCall = null, .xGetSystemCall = null, .xNextSystemCall = null } };
    }
};

pub fn isMemdbVfs(candidate: *const sqlite3_vfs) bool {
    return candidate.xOpen == memdbOpen;
}

test "memdb adapter preserves shared/private lifetime locks and ABI tails" {
    var native = MemoryVfs.initMemdb(std.testing.allocator);
    defer native.deinit();
    var original_native = MemoryVfs.init(std.testing.allocator);
    defer original_native.deinit();
    var original_adapter = AbiAdapter.init("original", &original_native);
    var context = MemdbContext{ .native = &native, .original = &original_adapter.abi };
    var adapter = MemdbAdapter.init(&context);
    try std.testing.expectEqual(@as(c_int, 2), adapter.abi.iVersion);
    try std.testing.expect(adapter.abi.xDelete == null and adapter.abi.xCurrentTime == null);
    try std.testing.expect(adapter.abi.xSetSystemCall == null and adapter.abi.xGetSystemCall == null and adapter.abi.xNextSystemCall == null);
    try std.testing.expect(isMemdbVfs(&adapter.abi));
    try std.testing.expect(!isMemdbVfs(&original_adapter.abi));

    var shared_a: AbiFile = undefined;
    var shared_b: AbiFile = undefined;
    const flags = OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB;
    try std.testing.expectEqual(OK, adapter.abi.xOpen.?(&adapter.abi, "/shared", @ptrCast(&shared_a), flags, null));
    try std.testing.expectEqual(OK, adapter.abi.xOpen.?(&adapter.abi, "/shared", @ptrCast(&shared_b), flags, null));
    const methods = shared_a.base.pMethods.?;
    try std.testing.expectEqual(@as(c_int, 3), methods.iVersion);
    try std.testing.expect(methods.xCheckReservedLock == null and methods.xSectorSize == null);
    try std.testing.expect(methods.xShmMap == null and methods.xShmLock == null and methods.xShmBarrier == null and methods.xShmUnmap == null);
    try std.testing.expect(methods.xFetch != null and methods.xUnfetch != null);
    try std.testing.expectEqual(OK, methods.xWrite.?(&shared_a.base, "abc".ptr, 3, 0));
    var bytes: [3]u8 = undefined;
    try std.testing.expectEqual(OK, methods.xRead.?(&shared_b.base, &bytes, bytes.len, 0));
    try std.testing.expectEqualStrings("abc", &bytes);
    try std.testing.expectEqual(OK, methods.xLock.?(&shared_a.base, LOCK_SHARED));
    try std.testing.expectEqual(OK, methods.xLock.?(&shared_b.base, LOCK_SHARED));
    try std.testing.expectEqual(OK, methods.xLock.?(&shared_a.base, LOCK_RESERVED));
    try std.testing.expectEqual(BUSY, methods.xLock.?(&shared_b.base, LOCK_RESERVED));
    try std.testing.expectEqual(BUSY, methods.xLock.?(&shared_a.base, LOCK_EXCLUSIVE));
    try std.testing.expectEqual(OK, methods.xUnlock.?(&shared_b.base, LOCK_NONE));
    try std.testing.expectEqual(OK, methods.xLock.?(&shared_a.base, LOCK_EXCLUSIVE));
    var fetched: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(OK, methods.xFetch.?(&shared_a.base, 0, 3, &fetched));
    try std.testing.expectEqual(null, fetched);
    try std.testing.expectEqual(CORRUPT, methods.xTruncate.?(&shared_a.base, 4));
    try std.testing.expectEqual(OK, methods.xSync.?(&shared_a.base, 0));
    try std.testing.expect(native.files.contains("/shared"));
    try std.testing.expectEqual(OK, methods.xClose.?(&shared_b.base));
    try std.testing.expect(native.files.contains("/shared"));
    try std.testing.expectEqual(OK, methods.xClose.?(&shared_a.base));
    try std.testing.expect(!native.files.contains("/shared"));

    var private_a: AbiFile = undefined;
    var private_b: AbiFile = undefined;
    try std.testing.expectEqual(OK, adapter.abi.xOpen.?(&adapter.abi, "private", @ptrCast(&private_a), flags, null));
    try std.testing.expectEqual(OK, adapter.abi.xOpen.?(&adapter.abi, "private", @ptrCast(&private_b), flags, null));
    try std.testing.expectEqual(OK, private_a.base.pMethods.?.xWrite.?(&private_a.base, "x".ptr, 1, 0));
    var private_byte: [1]u8 = undefined;
    try std.testing.expectEqual(IOERR_SHORT_READ, private_b.base.pMethods.?.xRead.?(&private_b.base, &private_byte, 1, 0));
    try std.testing.expect(!native.files.contains("private"));
    try std.testing.expectEqual(OK, private_a.base.pMethods.?.xClose.?(&private_a.base));
    try std.testing.expectEqual(OK, private_b.base.pMethods.?.xClose.?(&private_b.base));
    var exists: c_int = 1;
    try std.testing.expectEqual(OK, adapter.abi.xAccess.?(&adapter.abi, "/shared", ACCESS_EXISTS, &exists));
    try std.testing.expectEqual(@as(c_int, 0), exists);
}

test "memdb doubled growth size controls OOM and source result codes" {
    var native = MemoryVfs.initMemdb(std.testing.allocator);
    defer native.deinit();
    const file = native.open("growth", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(OK, file.write("abc", 0));
    try std.testing.expectEqual(@as(usize, 6), file.state.volatile_data.capacity);

    var limit: i64 = 4;
    try std.testing.expectEqual(OK, file.fileControl(FCNTL_SIZE_LIMIT, &limit));
    try std.testing.expectEqual(@as(i64, 4), limit);
    try std.testing.expectEqual(OK, file.write("def", 3));
    try std.testing.expectEqual(FULL, file.write("g", 6));
    try std.testing.expectEqual(@as(usize, 6), file.state.volatile_data.items.len);
    limit = 2;
    try std.testing.expectEqual(OK, file.fileControl(FCNTL_SIZE_LIMIT, &limit));
    try std.testing.expectEqual(@as(i64, 6), limit);
    limit = -1;
    try std.testing.expectEqual(OK, file.fileControl(FCNTL_SIZE_LIMIT, &limit));
    try std.testing.expectEqual(@as(i64, 6), limit);

    var vfs_name: ?[*:0]u8 = null;
    try std.testing.expectEqual(OK, file.fileControl(FCNTL_VFSNAME, @ptrCast(&vfs_name)));
    const allocated_name = std.mem.span(vfs_name.?);
    try std.testing.expect(std.mem.startsWith(u8, allocated_name, "memdb(0x"));
    try std.testing.expect(std.mem.endsWith(u8, allocated_name, ",6)"));
    native.allocator.free(allocated_name);
    try std.testing.expectEqual(NOTFOUND, file.fileControl(9999, null));
    try std.testing.expectEqual(OK, native.closeAndDestroy(file));

    const oom_file = native.open("oom", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(OK, oom_file.write("abc", 0));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    native.allocator = failing.allocator();
    try std.testing.expectEqual(IOERR_NOMEM, oom_file.write("g", 6));
    try std.testing.expectEqual(@as(usize, 3), oom_file.state.volatile_data.items.len);
    native.allocator = std.testing.allocator;
    try std.testing.expectEqual(OK, native.closeAndDestroy(oom_file));
}

test "deserialized resize OOM preserves external pointer content and size" {
    var fault = memory.FaultingBackend{ .inner = memory.systemBackend() };
    var manager = memory.Manager.init(fault.backend());
    try std.testing.expectEqual(memory.ok, manager.start());
    defer manager.stop();
    const allocation = manager.alloc(16) orelse return error.OutOfMemory;
    const original = @as([*]u8, @ptrCast(allocation))[0..16];
    @memset(original, 0x5a);

    var native = MemoryVfs.init(std.testing.allocator);
    defer native.deinit();
    const opened = native.open("main", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB);
    try std.testing.expectEqual(OK, opened.rc);
    const file = opened.file.?;
    native.adoptVolatileBufferWithManager(file, original.ptr, original.len, original.len, DESERIALIZE_FREEONCLOSE | DESERIALIZE_RESIZEABLE, &manager);
    const pointer_before = @intFromPtr(native.borrowVolatile("main").?.ptr);
    fault.fail_at = fault.attempt_count;
    try std.testing.expectEqual(IOERR_NOMEM, file.write(&.{0xff}, original.len));
    try std.testing.expect(fault.fired);
    const after = native.borrowVolatile("main").?;
    try std.testing.expectEqual(pointer_before, @intFromPtr(after.ptr));
    try std.testing.expectEqual(@as(usize, 16), after.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 16), after);
    try std.testing.expectEqual(OK, native.closeAndDestroy(file));
}

test "shared memdb uses configured dynamic mutex allocation and fails open atomically" {
    const Probe = struct {
        var fail_allocation = true;
        var allocations: usize = 0;
        var frees: usize = 0;
        var enters: usize = 0;
        var leaves: usize = 0;
        fn alloc(kind: c_int) callconv(.c) ?*anyopaque {
            std.debug.assert(kind == @intFromEnum(sqlite_mutex.Kind.fast));
            allocations += 1;
            return if (fail_allocation) null else @ptrFromInt(16);
        }
        fn free(_: ?*anyopaque) callconv(.c) void {
            frees += 1;
        }
        fn enter(_: ?*anyopaque) callconv(.c) void {
            enters += 1;
        }
        fn leave(_: ?*anyopaque) callconv(.c) void {
            leaves += 1;
        }
    };
    Probe.fail_allocation = true;
    Probe.allocations = 0;
    Probe.frees = 0;
    Probe.enters = 0;
    Probe.leaves = 0;
    var methods = sqlite_mutex.noop_methods;
    methods.xMutexAlloc = Probe.alloc;
    methods.xMutexFree = Probe.free;
    methods.xMutexEnter = Probe.enter;
    methods.xMutexLeave = Probe.leave;
    var mutexes = sqlite_mutex.Subsystem.init(std.testing.allocator);
    try mutexes.configureMethods(methods);
    try std.testing.expectEqual(@as(c_int, 0), mutexes.startLifecycle());
    defer _ = mutexes.stopLifecycle();
    var native = MemoryVfs.initMemdb(std.testing.allocator);
    defer native.deinit();
    native.attachMemdbMutexSubsystem(&mutexes);

    const failed = native.open("/configured", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB);
    try std.testing.expectEqual(NOMEM, failed.rc);
    try std.testing.expectEqual(null, failed.file);
    try std.testing.expect(!native.files.contains("/configured"));

    const private = native.open("private", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(@as(usize, 1), Probe.allocations);
    try std.testing.expectEqual(OK, native.closeAndDestroy(private));

    Probe.fail_allocation = false;
    const shared = native.open("/configured", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB).file.?;
    try std.testing.expectEqual(@as(usize, 2), Probe.allocations);
    try std.testing.expectEqual(OK, shared.write("x", 0));
    try std.testing.expectEqual(OK, native.closeAndDestroy(shared));
    try std.testing.expectEqual(@as(usize, 1), Probe.frees);
    try std.testing.expect(Probe.enters > 0 and Probe.enters == Probe.leaves);
}

test "shared memdb serializes concurrent open growth and last close" {
    var native = MemoryVfs.initMemdb(std.testing.allocator);
    defer native.deinit();
    const anchor = native.open("/concurrent", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB).file.?;
    const Worker = struct {
        vfs: *MemoryVfs,
        index: usize,
        ok: bool = false,
        fn run(context: *@This()) void {
            const opened = context.vfs.open("/concurrent", OPEN_READWRITE | OPEN_CREATE | OPEN_MAIN_DB);
            const file = opened.file orelse return;
            defer _ = context.vfs.closeAndDestroy(file);
            if (file.lock(LOCK_SHARED) != OK) return;
            var bytes: [32]u8 = undefined;
            @memset(&bytes, @intCast(context.index + 1));
            if (file.write(&bytes, context.index * bytes.len) != OK) return;
            if (file.unlock(LOCK_NONE) != OK) return;
            context.ok = true;
        }
    };
    var contexts: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &contexts, 0..) |*thread, *context, index| {
        context.* = .{ .vfs = &native, .index = index };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (&threads) |*thread| thread.join();
    for (&contexts) |*context| try std.testing.expect(context.ok);
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqual(OK, anchor.read(&bytes, 0));
    for (0..8) |index| for (bytes[index * 32 ..][0..32]) |byte| try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte);
    try std.testing.expect(native.files.contains("/concurrent"));
    try std.testing.expectEqual(OK, native.closeAndDestroy(anchor));
    try std.testing.expect(!native.files.contains("/concurrent"));
}

test "registry, durable store, locks, and crash" {
    var vfs = MemoryVfs.init(std.testing.allocator);
    defer vfs.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(OK, registry.register("mem", &vfs, true));
    try std.testing.expect(registry.find(null) == &vfs);
    try std.testing.expectEqual(BUSY, registry.register("mem", &vfs, false));
    const opened = vfs.open("db", OPEN_CREATE | OPEN_MAIN_DB);
    try std.testing.expectEqual(OK, opened.rc);
    const file = opened.file.?;
    try std.testing.expectEqual(OK, file.write("old", 0));
    try std.testing.expectEqual(OK, file.sync());
    try std.testing.expectEqual(OK, file.write("new", 0));
    vfs.crash();
    var out: [3]u8 = undefined;
    try std.testing.expectEqual(OK, file.read(&out, 0));
    try std.testing.expectEqualStrings("old", &out);
    try std.testing.expectEqual(OK, vfs.closeAndDestroy(file));
    try std.testing.expectEqual(OK, registry.unregister("mem"));
}

test "durable and volatile rollback recovery model" {
    var vfs = MemoryVfs.init(std.testing.allocator);
    defer vfs.deinit();
    const db = vfs.open("db", OPEN_CREATE | OPEN_MAIN_DB).file.?;
    const journal = vfs.open("db-journal", OPEN_CREATE | OPEN_MAIN_JOURNAL).file.?;
    try std.testing.expectEqual(OK, db.write("old", 0));
    try std.testing.expectEqual(OK, db.sync());
    try std.testing.expectEqual(OK, journal.write("old", 0));
    try std.testing.expectEqual(OK, journal.sync());
    try std.testing.expectEqual(OK, db.write("new", 0));
    try std.testing.expectEqual(OK, db.sync());
    try std.testing.expectEqual(OK, vfs.closeAndDestroy(journal));
    vfs.crash();
    try std.testing.expectEqual(OK, vfs.recoverRollback("db", "db-journal"));
    var output: [3]u8 = undefined;
    try std.testing.expectEqual(OK, db.read(&output, 0));
    try std.testing.expectEqualStrings("old", &output);
    try std.testing.expectEqual(OK, db.write("new", 0));
    try std.testing.expectEqual(OK, db.sync());
    try std.testing.expectEqual(OK, vfs.delete("db-journal", true));
    vfs.crash();
    try std.testing.expectEqual(OK, db.read(&output, 0));
    try std.testing.expectEqualStrings("new", &output);
    try std.testing.expectEqual(OK, vfs.closeAndDestroy(db));
}

test "named one-shot sticky short and compound faults are bounded" {
    const methods = std.meta.tags(Method);
    for (methods) |method| {
        var rules = [_]FaultRule{.{ .method = method, .at = 0, .mode = .one_shot, .code = IOERR }};
        var f = FaultController{ .rules = &rules, .hard_bound = 4 };
        _ = f.check(method);
        _ = f.check(method);
        try std.testing.expect(f.injectionWasTriggered(method));
        try std.testing.expect(f.total_calls <= f.hard_bound);
        var sticky_rules = [_]FaultRule{.{ .method = method, .at = 0, .mode = .sticky, .code = IOERR }};
        var sticky = FaultController{ .rules = &sticky_rules, .hard_bound = 4 };
        try std.testing.expect(sticky.check(method) == .fail);
        try std.testing.expect(sticky.check(method) == .fail);
    }
    var compound = [_]FaultRule{ .{ .method = .write, .mode = .short_operation }, .{ .method = .sync, .mode = .sticky, .code = IOERR_FSYNC } };
    var f = FaultController{ .rules = &compound };
    try std.testing.expect(f.check(.write) == .short);
    try std.testing.expect(f.check(.sync) == .fail);
    try std.testing.expect(f.check(.sync) == .fail);
}

test "every applicable VFS method dispatches named faults" {
    for (std.meta.tags(Method)) |method| {
        var vfs = MemoryVfs.init(std.testing.allocator);
        defer vfs.deinit();
        var opened = vfs.open("fault-file", OPEN_CREATE | OPEN_MAIN_DB);
        var file = opened.file.?;
        if (method == .delete) {
            try std.testing.expectEqual(OK, vfs.closeAndDestroy(file));
            opened.file = null;
        }
        var rules = [_]FaultRule{.{ .method = method, .code = IOERR }};
        var faults = FaultController{ .rules = &rules, .hard_bound = 8 };
        vfs.faults = &faults;
        var bytes: [8]u8 = undefined;
        var integer: c_int = 0;
        var size: u64 = 0;
        const adapter = AbiAdapter.init("fault", &vfs);
        var abi_file = AbiFile{ .base = .{ .pMethods = &io_methods }, .native = file, .owner = &vfs };
        switch (method) {
            .open => _ = vfs.open("other", OPEN_CREATE),
            .delete => _ = vfs.delete("fault-file", true),
            .access => _ = vfs.access("fault-file", ACCESS_EXISTS, &integer),
            .full_pathname => _ = vfs.fullPathname("fault-file", &bytes),
            .close => _ = file.close(),
            .read => _ = file.read(&bytes, 0),
            .write => _ = file.write("x", 0),
            .truncate => _ = file.truncate(0),
            .sync => _ = file.sync(),
            .file_size => _ = file.fileSize(&size),
            .lock => _ = file.lock(LOCK_SHARED),
            .unlock => {
                file.lock_level = LOCK_SHARED;
                file.state.locks[LOCK_SHARED] = 1;
                _ = file.unlock(LOCK_NONE);
            },
            .check_reserved => _ = file.checkReserved(&integer),
            .file_control => _ = axControl(@ptrCast(&abi_file), 0, null),
            .sector_size => _ = axSector(@ptrCast(&abi_file)),
            .device_characteristics => _ = axDevice(@ptrCast(&abi_file)),
            .shm_map => {
                var pointer: ?*volatile anyopaque = null;
                _ = file.shmMap(0, SHM_REGION_SIZE, 1, &pointer);
            },
            .shm_lock => _ = file.shmLock(0, 1, SHM_LOCK | SHM_EXCLUSIVE),
            .shm_unmap => _ = file.shmUnmap(0),
            .shm_barrier => axShmBarrier(@ptrCast(&abi_file)),
            .randomness => _ = avRandom(@constCast(&adapter.abi), @intCast(bytes.len), &bytes),
            .sleep => _ = avSleep(@constCast(&adapter.abi), 1),
            .current_time => {
                var time: f64 = 0;
                _ = avTime(@constCast(&adapter.abi), &time);
            },
        }
        try std.testing.expect(faults.injectionWasTriggered(method));
        try std.testing.expect(faults.total_calls <= faults.hard_bound);
        vfs.faults = null;
        if (opened.file != null) {
            if (!file.closed) try std.testing.expectEqual(OK, vfs.closeAndDestroy(file)) else vfs.allocator.destroy(file);
        }
    }
}

test "short and compound faults affect real file operations" {
    var vfs = MemoryVfs.init(std.testing.allocator);
    defer vfs.deinit();
    const file = vfs.open("fault-file", OPEN_CREATE | OPEN_MAIN_DB).file.?;
    defer _ = vfs.closeAndDestroy(file);
    var rules = [_]FaultRule{
        .{ .method = .write, .mode = .short_operation },
        .{ .method = .sync, .mode = .sticky, .code = IOERR_FSYNC },
    };
    var faults = FaultController{ .rules = &rules };
    vfs.faults = &faults;
    try std.testing.expectEqual(IOERR_WRITE, file.write("abcdefgh", 0));
    try std.testing.expectEqual(IOERR_FSYNC, file.sync());
    try std.testing.expectEqual(IOERR_FSYNC, file.sync());
    vfs.faults = null;
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var vfs = MemoryVfs.init(allocator);
    defer vfs.deinit();
    const opened = vfs.open("allocation-file", OPEN_CREATE | OPEN_MAIN_DB);
    if (opened.rc == NOMEM) return error.OutOfMemory;
    const file = opened.file.?;
    defer {
        if (!file.closed) _ = vfs.closeAndDestroy(file);
    }
    if (file.write("0123456789", 32) == NOMEM) return error.OutOfMemory;
    if (file.sync() == NOMEM) return error.OutOfMemory;
    const second = vfs.open("allocation-file", OPEN_MAIN_DB);
    if (second.rc == NOMEM) return error.OutOfMemory;
    if (second.file) |other| if (vfs.closeAndDestroy(other) != OK) return error.Unexpected;
}

test "VFS allocation sites have sticky and one-shot OOM coverage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
    var completed = false;
    for (0..32) |index| {
        var failing = OneShotFailAllocator.init(std.testing.allocator, index);
        allocationExercise(failing.allocator()) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
        };
        if (!failing.induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}

test "ABI layouts and version tails match first target" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(sqlite3_file));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(sqlite3_io_methods));
    try std.testing.expectEqual(@as(usize, 168), @sizeOf(sqlite3_vfs));
    var vfs = MemoryVfs.init(std.testing.allocator);
    defer vfs.deinit();
    const adapter = AbiAdapter.init("mem", &vfs);
    try std.testing.expectEqual(@as(c_int, 3), adapter.abi.iVersion);
    try std.testing.expect(adapter.abi.xCurrentTimeInt64 != null);
    try std.testing.expect(io_methods.xFetch != null);
}
