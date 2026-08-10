//! In-memory and packed-memory-array VDBE sorter paths from `vdbesort.c`.

const std = @import("std");
const varint = @import("../varint.zig");
const threads = @import("threads.zig");

pub const Error = error{ OutOfMemory, EndOfFile, Malformed };
pub const Compare = *const fn ([]const u8, []const u8) i32;

pub const Record = struct {
    bytes: []u8,
    ordinal: u64,
};

pub const Sorter = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    compare_fn: Compare,
    sorted: bool = false,
    index: usize = 0,
    next_ordinal: u64 = 0,
    maximum_key_size: usize = 0,
    memory_limit: usize = 1024 * 1024,
    pmas: std.ArrayList([]u8) = .empty,
    tasks: std.ArrayList(SortSubtask) = .empty,
};

pub const PmaWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    start: usize = 0,
    spill: u64 = 0,
};

pub const PmaReader = struct {
    bytes: []const u8 = &.{},
    offset: usize = 0,
    end: usize = 0,
    key: []const u8 = &.{},
};

pub const MergeEngine = struct {
    allocator: std.mem.Allocator,
    readers: []PmaReader,
    tree: []usize,
    compare_fn: Compare,
    current: ?usize = null,
};

pub const IncrementalMerger = struct {
    allocator: std.mem.Allocator,
    engine: *MergeEngine,
    bytes: std.ArrayList(u8) = .empty,
    maximum_size: usize,
    eof: bool = false,
};

pub const SortSubtask = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    pma: std.ArrayList(u8) = .empty,
    compare_fn: ?Compare = null,
    thread: ?*threads.Handle = null,
    result: ?Error = null,
};

pub const PackedFile = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *PackedFile) void {
        self.bytes.deinit(self.allocator);
    }
};

/// Source `vdbeSorterCompareTail()`.
pub fn compareTail(left: []const u8, right: []const u8, skip: usize) i32 {
    const left_tail = left[@min(skip, left.len)..];
    const right_tail = right[@min(skip, right.len)..];
    const order = std.mem.order(u8, left_tail, right_tail);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Source `vdbeSorterCompare()`.
pub fn compareRecords(left: []const u8, right: []const u8) i32 {
    const order = std.mem.order(u8, left, right);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

const FirstField = struct { serial: u32, payload: []const u8 };

fn firstField(record: []const u8) ?FirstField {
    if (record.len < 2) return null;
    const header_size = varint.get(record.ptr);
    if (header_size.value > record.len or header_size.length >= record.len) return null;
    const serial = varint.get(record.ptr + header_size.length);
    const payload_start: usize = @intCast(header_size.value);
    if (payload_start > record.len) return null;
    return .{ .serial = @intCast(serial.value), .payload = record[payload_start..] };
}

/// Source `vdbeSorterCompareText()`.
pub fn compareText(left: []const u8, right: []const u8) i32 {
    const first = firstField(left) orelse return compareRecords(left, right);
    const second = firstField(right) orelse return compareRecords(left, right);
    if (first.serial < 13 or second.serial < 13 or first.serial & 1 == 0 or second.serial & 1 == 0) return compareRecords(left, right);
    const first_length: usize = @intCast((first.serial - 13) / 2);
    const second_length: usize = @intCast((second.serial - 13) / 2);
    const a = first.payload[0..@min(first_length, first.payload.len)];
    const b = second.payload[0..@min(second_length, second.payload.len)];
    const primary = compareRecords(a, b);
    return if (primary != 0) primary else compareTail(left, right, @min(left.len, right.len));
}

fn integerPayloadLength(serial: u32) usize {
    return switch (serial) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 => 8,
        8, 9 => 0,
        else => 0,
    };
}

fn decodeInteger(field: FirstField) ?i64 {
    if (field.serial == 8) return 0;
    if (field.serial == 9) return 1;
    const length = integerPayloadLength(field.serial);
    if (length == 0 or field.payload.len < length) return null;
    var bits: u64 = if (field.payload[0] & 0x80 != 0) std.math.maxInt(u64) else 0;
    for (field.payload[0..length]) |byte| bits = (bits << 8) | byte;
    return @bitCast(bits);
}

/// Source `vdbeSorterCompareInt()`.
pub fn compareInteger(left: []const u8, right: []const u8) i32 {
    const first = decodeInteger(firstField(left) orelse return compareRecords(left, right)) orelse return compareRecords(left, right);
    const second = decodeInteger(firstField(right) orelse return compareRecords(left, right)) orelse return compareRecords(left, right);
    if (first < second) return -1;
    if (first > second) return 1;
    return compareRecords(left, right);
}

fn less(compare_fn: Compare, left: Record, right: Record) bool {
    const order = compare_fn(left.bytes, right.bytes);
    return order < 0 or (order == 0 and left.ordinal < right.ordinal);
}

/// Source `vdbeSorterMerge()`.
pub fn mergeRecords(allocator: std.mem.Allocator, compare_fn: Compare, first: []const Record, second: []const Record) Error![]Record {
    const merged = allocator.alloc(Record, first.len + second.len) catch return error.OutOfMemory;
    var left: usize = 0;
    var right: usize = 0;
    var output: usize = 0;
    while (left < first.len and right < second.len) : (output += 1) {
        if (less(compare_fn, first[left], second[right])) {
            merged[output] = first[left];
            left += 1;
        } else {
            merged[output] = second[right];
            right += 1;
        }
    }
    @memcpy(merged[output .. output + first.len - left], first[left..]);
    output += first.len - left;
    @memcpy(merged[output .. output + second.len - right], second[right..]);
    return merged;
}

/// Source `vdbeSorterSort()`.
pub fn sortRecords(allocator: std.mem.Allocator, records: []Record, compare_fn: Compare) Error!void {
    if (records.len < 2) return;
    var width: usize = 1;
    const scratch = allocator.alloc(Record, records.len) catch return error.OutOfMemory;
    defer allocator.free(scratch);
    var source = records;
    var destination = scratch;
    while (width < records.len) : (width *= 2) {
        var start: usize = 0;
        while (start < records.len) : (start += width * 2) {
            const middle = @min(start + width, records.len);
            const end = @min(start + width * 2, records.len);
            var left = start;
            var right = middle;
            var output = start;
            while (left < middle and right < end) : (output += 1) {
                if (less(compare_fn, source[left], source[right])) {
                    destination[output] = source[left];
                    left += 1;
                } else {
                    destination[output] = source[right];
                    right += 1;
                }
            }
            @memcpy(destination[output .. output + middle - left], source[left..middle]);
            output += middle - left;
            @memcpy(destination[output .. output + end - right], source[right..end]);
        }
        const swap = source;
        source = destination;
        destination = swap;
    }
    if (source.ptr != records.ptr) @memcpy(records, source);
}

/// Source `sqlite3VdbeSorterInit()`.
pub fn init(allocator: std.mem.Allocator, compare_fn: Compare) Error!*Sorter {
    const sorter = allocator.create(Sorter) catch return error.OutOfMemory;
    sorter.* = .{ .allocator = allocator, .compare_fn = compare_fn };
    errdefer allocator.destroy(sorter);
    sorter.tasks.append(allocator, .{ .allocator = allocator }) catch return error.OutOfMemory;
    return sorter;
}

/// Source `sqlite3VdbeSorterReset()`.
pub fn reset(sorter: *Sorter) void {
    joinAllSorterThreads(sorter.tasks.items) catch {};
    for (sorter.tasks.items) |*task| {
        for (task.records.items) |record| task.allocator.free(record.bytes);
        task.records.clearRetainingCapacity();
        task.pma.clearRetainingCapacity();
        task.result = null;
    }
    for (sorter.records.items) |record| sorter.allocator.free(record.bytes);
    sorter.records.clearRetainingCapacity();
    for (sorter.pmas.items) |pma| sorter.allocator.free(pma);
    sorter.pmas.clearRetainingCapacity();
    sorter.sorted = false;
    sorter.index = 0;
    sorter.next_ordinal = 0;
    sorter.maximum_key_size = 0;
}

/// Source `sqlite3VdbeSorterClose()`.
pub fn close(sorter: *Sorter) void {
    const allocator = sorter.allocator;
    reset(sorter);
    sorter.records.deinit(allocator);
    for (sorter.tasks.items) |*task| subtaskCleanup(task);
    sorter.tasks.deinit(allocator);
    sorter.pmas.deinit(allocator);
    allocator.destroy(sorter);
}

/// Source `sqlite3VdbeSorterWrite()`.
pub fn write(sorter: *Sorter, key: []const u8) Error!void {
    if (sorter.sorted) return error.Malformed;
    var memory_used: usize = 0;
    for (sorter.records.items) |record| memory_used += record.bytes.len + @sizeOf(Record);
    if (sorter.records.items.len > 0 and memory_used + key.len + @sizeOf(Record) > sorter.memory_limit) try flushPma(sorter);
    const copy = sorter.allocator.dupe(u8, key) catch return error.OutOfMemory;
    errdefer sorter.allocator.free(copy);
    sorter.records.append(sorter.allocator, .{ .bytes = copy, .ordinal = sorter.next_ordinal }) catch return error.OutOfMemory;
    sorter.next_ordinal += 1;
    sorter.maximum_key_size = @max(sorter.maximum_key_size, key.len + varintLength(key.len));
}

/// Source `sqlite3VdbeSorterRewind()`.
pub fn rewind(sorter: *Sorter) Error!bool {
    for (sorter.tasks.items) |*task| try collectSortSubtask(sorter, task);
    if (sorter.pmas.items.len > 0) {
        if (sorter.records.items.len > 0) {
            try flushPma(sorter);
            for (sorter.tasks.items) |*task| {
                try collectSortSubtask(sorter, task);
            }
        }
        const engine = try sorterSetupMerge(sorter.allocator, sorter.pmas.items, sorter.compare_fn);
        defer mergeEngineFree(engine);
        while (engine.current) |selected| {
            const key = engine.readers[selected].key;
            const copy = sorter.allocator.dupe(u8, key) catch return error.OutOfMemory;
            errdefer sorter.allocator.free(copy);
            sorter.records.append(sorter.allocator, .{ .bytes = copy, .ordinal = sorter.next_ordinal }) catch return error.OutOfMemory;
            sorter.next_ordinal += 1;
            if (try mergeEngineStep(engine)) break;
        }
        for (sorter.pmas.items) |pma| sorter.allocator.free(pma);
        sorter.pmas.clearRetainingCapacity();
    } else if (!sorter.sorted) {
        try sortRecords(sorter.allocator, sorter.records.items, sorter.compare_fn);
    }
    sorter.sorted = true;
    sorter.index = 0;
    return sorter.records.items.len == 0;
}

/// Source `sqlite3VdbeSorterNext()`.
pub fn next(sorter: *Sorter) Error!bool {
    if (!sorter.sorted) return error.Malformed;
    if (sorter.index < sorter.records.items.len) sorter.index += 1;
    return sorter.index >= sorter.records.items.len;
}

/// Source `vdbeSorterRowkey()`.
pub fn currentRowKey(sorter: *const Sorter) ?[]const u8 {
    if (!sorter.sorted or sorter.index >= sorter.records.items.len) return null;
    return sorter.records.items[sorter.index].bytes;
}

/// Source `sqlite3VdbeSorterRowkey()`.
pub fn rowKey(sorter: *const Sorter, allocator: std.mem.Allocator) Error![]u8 {
    const current = currentRowKey(sorter) orelse return error.EndOfFile;
    return allocator.dupe(u8, current) catch error.OutOfMemory;
}

/// Source `sqlite3VdbeSorterCompare()`.
pub fn compareCurrent(sorter: *const Sorter, candidate: []const u8) Error!i32 {
    const current = currentRowKey(sorter) orelse return error.EndOfFile;
    return sorter.compare_fn(candidate, current);
}

fn varintLength(value: usize) usize {
    var buffer: [9]u8 = undefined;
    return varint.put(&buffer, value);
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) Error!void {
    var buffer: [9]u8 = undefined;
    const count = varint.put(&buffer, value);
    list.appendSlice(allocator, buffer[0..count]) catch return error.OutOfMemory;
}

/// Source `vdbeSorterExtendFile()`.
pub fn extendSorterFile(file: *PackedFile, size: usize) Error!void {
    if (size <= file.bytes.items.len) return;
    const old_length = file.bytes.items.len;
    file.bytes.resize(file.allocator, size) catch return error.OutOfMemory;
    @memset(file.bytes.items[old_length..], 0);
}

/// Source `vdbeSorterOpenTempFile()`.
pub fn openSorterTempFile(allocator: std.mem.Allocator, extended_size: usize) Error!*PackedFile {
    const file = allocator.create(PackedFile) catch return error.OutOfMemory;
    file.* = .{ .allocator = allocator };
    errdefer allocator.destroy(file);
    if (extended_size > 0) try extendSorterFile(file, extended_size);
    return file;
}

/// Source `vdbeSorterMapFile()`.
pub fn mapSorterFile(file: *const PackedFile, maximum_mapping: usize) ?[]const u8 {
    if (file.bytes.items.len > maximum_mapping) return null;
    return file.bytes.items;
}

fn runSortSubtask(context: ?*anyopaque) ?*anyopaque {
    const task: *SortSubtask = @ptrCast(@alignCast(context orelse return null));
    const encoded = listToPma(task.allocator, task.records.items, task.compare_fn.?) catch |err| {
        task.result = err;
        return null;
    };
    defer task.allocator.free(encoded);
    task.pma.appendSlice(task.allocator, encoded) catch {
        task.result = error.OutOfMemory;
        return null;
    };
    for (task.records.items) |record| task.allocator.free(record.bytes);
    task.records.clearRetainingCapacity();
    return null;
}

fn collectSortSubtask(sorter: *Sorter, task: *SortSubtask) Error!void {
    try joinSorterThread(task);
    task.records.deinit(task.allocator);
    task.records = .empty;
    if (task.pma.items.len == 0) return;
    sorter.pmas.ensureUnusedCapacity(sorter.allocator, 1) catch return error.OutOfMemory;
    const pma = task.pma.toOwnedSlice(task.allocator) catch return error.OutOfMemory;
    task.pma = .empty;
    sorter.pmas.appendAssumeCapacity(pma);
}

/// Source `vdbeSorterFlushPMA()` with the source worker-thread lifecycle.
pub fn flushPma(sorter: *Sorter) Error!void {
    if (sorter.records.items.len == 0) return;
    const task = &sorter.tasks.items[0];
    try collectSortSubtask(sorter, task);
    std.debug.assert(task.records.items.len == 0 and task.thread == null);
    task.records = sorter.records;
    sorter.records = .empty;
    task.compare_fn = sorter.compare_fn;
    task.result = null;
    task.thread = threads.create(sorter.allocator, runSortSubtask, task, false) catch return error.OutOfMemory;
}

/// Source `vdbePmaWriterInit()`.
pub fn pmaWriterInit(allocator: std.mem.Allocator, start: usize) PmaWriter {
    return .{ .allocator = allocator, .start = start };
}

/// Source `vdbePmaWriteBlob()`.
pub fn pmaWriteBlob(writer: *PmaWriter, bytes: []const u8) Error!void {
    writer.bytes.appendSlice(writer.allocator, bytes) catch return error.OutOfMemory;
    writer.spill += bytes.len;
}

/// Source `vdbePmaWriterFinish()`.
pub fn pmaWriterFinish(writer: *PmaWriter) Error![]u8 {
    const output = writer.bytes.toOwnedSlice(writer.allocator) catch return error.OutOfMemory;
    writer.bytes = .empty;
    return output;
}

/// Source `vdbeSorterListToPMA()`.
pub fn listToPma(allocator: std.mem.Allocator, records: []Record, compare_fn: Compare) Error![]u8 {
    try sortRecords(allocator, records, compare_fn);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    for (records) |record| {
        try appendVarint(&payload, allocator, record.bytes.len);
        payload.appendSlice(allocator, record.bytes) catch return error.OutOfMemory;
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try appendVarint(&output, allocator, payload.items.len);
    output.appendSlice(allocator, payload.items) catch return error.OutOfMemory;
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Source `vdbePmaReadBlob()`.
pub fn pmaReadBlob(reader: *PmaReader, count: usize) Error![]const u8 {
    if (reader.offset + count > reader.end) return error.EndOfFile;
    const result = reader.bytes[reader.offset .. reader.offset + count];
    reader.offset += count;
    return result;
}

/// Source `vdbePmaReadVarint()`.
pub fn pmaReadVarint(reader: *PmaReader) Error!u64 {
    if (reader.offset >= reader.end) return error.EndOfFile;
    var temporary: [9]u8 = .{0} ** 9;
    const available = @min(9, reader.end - reader.offset);
    @memcpy(temporary[0..available], reader.bytes[reader.offset .. reader.offset + available]);
    const decoded = varint.get(&temporary);
    if (decoded.length > available) return error.Malformed;
    reader.offset += decoded.length;
    return decoded.value;
}

/// Source `vdbePmaReaderSeek()`.
pub fn pmaReaderSeek(reader: *PmaReader, bytes: []const u8, offset: usize, end: usize) Error!void {
    if (offset > end or end > bytes.len) return error.Malformed;
    reader.* = .{ .bytes = bytes, .offset = offset, .end = end };
}

/// Source `vdbePmaReaderNext()`.
pub fn pmaReaderNext(reader: *PmaReader) Error!bool {
    if (reader.offset >= reader.end) {
        reader.key = &.{};
        return true;
    }
    const count = try pmaReadVarint(reader);
    if (count > std.math.maxInt(usize)) return error.Malformed;
    reader.key = try pmaReadBlob(reader, @intCast(count));
    return false;
}

/// Source `vdbePmaReaderInit()`.
pub fn pmaReaderInit(reader: *PmaReader, bytes: []const u8, start: usize) Error!void {
    try pmaReaderSeek(reader, bytes, start, bytes.len);
    const payload = try pmaReadVarint(reader);
    if (payload > reader.end - reader.offset) return error.Malformed;
    reader.end = reader.offset + @as(usize, @intCast(payload));
    _ = try pmaReaderNext(reader);
}

/// Source `vdbeMergeEngineNew()`.
pub fn mergeEngineNew(allocator: std.mem.Allocator, reader_count: usize, compare_fn: Compare) Error!*MergeEngine {
    var count: usize = 2;
    while (count < reader_count) {
        count *= 2;
    }
    const engine = allocator.create(MergeEngine) catch return error.OutOfMemory;
    errdefer allocator.destroy(engine);
    const readers = allocator.alloc(PmaReader, count) catch return error.OutOfMemory;
    errdefer allocator.free(readers);
    const tree = allocator.alloc(usize, count) catch return error.OutOfMemory;
    @memset(readers, .{});
    @memset(tree, 0);
    engine.* = .{ .allocator = allocator, .readers = readers, .tree = tree, .compare_fn = compare_fn };
    return engine;
}

pub fn mergeEngineFree(engine: *MergeEngine) void {
    const allocator = engine.allocator;
    allocator.free(engine.readers);
    allocator.free(engine.tree);
    allocator.destroy(engine);
}

/// Source `vdbeMergeEngineCompare()`.
pub fn mergeEngineCompare(engine: *MergeEngine, output_index: usize) void {
    const half = engine.readers.len / 2;
    const pair = if (output_index >= half)
        .{ (output_index - half) * 2, (output_index - half) * 2 + 1 }
    else
        .{ engine.tree[output_index * 2], engine.tree[output_index * 2 + 1] };
    const first_eof = engine.readers[pair[0]].key.len == 0;
    const second_eof = engine.readers[pair[1]].key.len == 0;
    engine.tree[output_index] = if (first_eof)
        pair[1]
    else if (second_eof)
        pair[0]
    else if (engine.compare_fn(engine.readers[pair[0]].key, engine.readers[pair[1]].key) <= 0)
        pair[0]
    else
        pair[1];
}

/// Source `vdbeMergeEngineInit()`.
pub fn mergeEngineInit(engine: *MergeEngine) Error!bool {
    for (engine.readers) |*reader| {
        if (reader.key.len == 0 and reader.offset < reader.end) _ = try pmaReaderNext(reader);
    }
    var index = engine.tree.len - 1;
    while (index > 0) : (index -= 1) {
        mergeEngineCompare(engine, index);
    }
    const selected = engine.tree[1];
    engine.current = if (engine.readers[selected].key.len == 0) null else selected;
    return engine.current == null;
}

/// Source `vdbeMergeEngineStep()`.
pub fn mergeEngineStep(engine: *MergeEngine) Error!bool {
    const selected = engine.current orelse return true;
    _ = try pmaReaderNext(&engine.readers[selected]);
    var index = (engine.tree.len + selected) / 2;
    while (index > 0) : (index /= 2) {
        mergeEngineCompare(engine, index);
    }
    const next_index = engine.tree[1];
    engine.current = if (engine.readers[next_index].key.len == 0) null else next_index;
    return engine.current == null;
}

/// Source `vdbeMergeEngineLevel0()`.
pub fn mergeEngineLevel0(allocator: std.mem.Allocator, pmas: []const []const u8, compare_fn: Compare) Error!*MergeEngine {
    const engine = try mergeEngineNew(allocator, pmas.len, compare_fn);
    errdefer mergeEngineFree(engine);
    for (pmas, 0..) |pma, index| {
        try pmaReaderInit(&engine.readers[index], pma, 0);
    }
    _ = try mergeEngineInit(engine);
    return engine;
}

/// Source `vdbeIncrFree()`.
pub fn incrementalFree(merger: *IncrementalMerger) void {
    const allocator = merger.allocator;
    mergeEngineFree(merger.engine);
    merger.bytes.deinit(allocator);
    allocator.destroy(merger);
}

/// Source `vdbeIncrPopulate()`.
pub fn incrementalPopulate(merger: *IncrementalMerger) Error!void {
    merger.bytes.clearRetainingCapacity();
    while (merger.engine.current) |selected| {
        const key = merger.engine.readers[selected].key;
        const required = varintLength(key.len) + key.len;
        if (merger.bytes.items.len > 0 and merger.bytes.items.len + required > merger.maximum_size) break;
        try appendVarint(&merger.bytes, merger.allocator, key.len);
        merger.bytes.appendSlice(merger.allocator, key) catch return error.OutOfMemory;
        if (try mergeEngineStep(merger.engine)) {
            merger.eof = true;
            break;
        }
    }
}

/// Source `vdbeIncrSwap()`.
pub fn incrementalSwap(merger: *IncrementalMerger, reader: *PmaReader) Error!void {
    try incrementalPopulate(merger);
    try pmaReaderSeek(reader, merger.bytes.items, 0, merger.bytes.items.len);
    _ = try pmaReaderNext(reader);
}

/// Source `vdbeIncrMergerNew()`.
pub fn incrementalMergerNew(allocator: std.mem.Allocator, engine: *MergeEngine, maximum_size: usize) Error!*IncrementalMerger {
    const merger = allocator.create(IncrementalMerger) catch {
        mergeEngineFree(engine);
        return error.OutOfMemory;
    };
    merger.* = .{ .allocator = allocator, .engine = engine, .maximum_size = maximum_size };
    return merger;
}

/// Source `vdbePmaReaderIncrInit()`.
pub fn pmaReaderIncrementalInit(reader: *PmaReader, merger_optional: ?*IncrementalMerger) Error!void {
    const merger = merger_optional orelse return;
    try pmaReaderIncrementalMergeInit(reader, merger);
}

/// Source `vdbePmaReaderIncrMergeInit()`.
pub fn pmaReaderIncrementalMergeInit(reader: *PmaReader, merger: *IncrementalMerger) Error!void {
    if (merger.engine.current == null) _ = try mergeEngineInit(merger.engine);
    try incrementalSwap(merger, reader);
}

/// Source `vdbeSorterTreeDepth()`.
pub fn sorterTreeDepth(pma_count: usize) usize {
    var depth: usize = 0;
    var divisor: usize = 16;
    while (divisor < pma_count) : (divisor *= 16) depth += 1;
    return depth;
}

/// Source `vdbeSorterAddToTree()`.
pub fn sorterAddToTree(root: *MergeEngine, leaf: *MergeEngine, sequence: usize) Error!void {
    if (root.readers.len == 0 or leaf.current == null) return error.Malformed;
    const destination = sequence % root.readers.len;
    const selected = leaf.current.?;
    root.readers[destination] = leaf.readers[selected];
    leaf.readers[selected] = .{};
}

/// Source `vdbeSorterMergeTreeBuild()`.
pub fn sorterMergeTreeBuild(allocator: std.mem.Allocator, pmas: []const []const u8, compare_fn: Compare) Error!*MergeEngine {
    const root = try mergeEngineLevel0(allocator, pmas, compare_fn);
    if (root.current == null) _ = try mergeEngineInit(root);
    return root;
}

/// Source `vdbeSorterSetupMerge()`.
pub fn sorterSetupMerge(allocator: std.mem.Allocator, pmas: []const []const u8, compare_fn: Compare) Error!*MergeEngine {
    const engine = try sorterMergeTreeBuild(allocator, pmas, compare_fn);
    if (engine.current == null) _ = try mergeEngineInit(engine);
    return engine;
}

/// Source `vdbeSorterJoinThread()`.
pub fn joinSorterThread(task: *SortSubtask) Error!void {
    if (task.thread) |thread| {
        var output: ?*anyopaque = null;
        threads.join(thread, &output);
        task.thread = null;
    }
    if (task.result) |result| {
        task.result = null;
        return result;
    }
}

/// Source `vdbeSorterJoinAll()`.
pub fn joinAllSorterThreads(tasks: []SortSubtask) Error!void {
    var first_error: ?Error = null;
    var index = tasks.len;
    while (index > 0) {
        index -= 1;
        joinSorterThread(&tasks[index]) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

/// Source `vdbeSortSubtaskCleanup()`.
pub fn subtaskCleanup(task: *SortSubtask) void {
    for (task.records.items) |record| task.allocator.free(record.bytes);
    task.records.deinit(task.allocator);
    task.pma.deinit(task.allocator);
    task.* = .{ .allocator = task.allocator };
}

test "sorter spills bounded runs and merges them in order" {
    const sorter = try init(std.testing.allocator, compareRecords);
    defer close(sorter);
    sorter.memory_limit = 1;
    try write(sorter, "c");
    try write(sorter, "a");
    try write(sorter, "b");
    try std.testing.expect(!(try rewind(sorter)));
    for ([_][]const u8{ "a", "b", "c" }) |expected| {
        try std.testing.expectEqualStrings(expected, currentRowKey(sorter).?);
        _ = try next(sorter);
    }
}

test "PMA readers writers and merge engine preserve sorted records" {
    const allocator = std.testing.allocator;
    var records = [_]Record{
        .{ .bytes = try allocator.dupe(u8, "c"), .ordinal = 0 },
        .{ .bytes = try allocator.dupe(u8, "a"), .ordinal = 1 },
        .{ .bytes = try allocator.dupe(u8, "b"), .ordinal = 2 },
    };
    defer {
        for (&records) |record| allocator.free(record.bytes);
    }
    const pma = try listToPma(allocator, &records, compareRecords);
    defer allocator.free(pma);
    var reader = PmaReader{};
    try pmaReaderInit(&reader, pma, 0);
    try std.testing.expectEqualStrings("a", reader.key);
    try std.testing.expect(!(try pmaReaderNext(&reader)));
    try std.testing.expectEqualStrings("b", reader.key);
    try std.testing.expect(!(try pmaReaderNext(&reader)));
    try std.testing.expectEqualStrings("c", reader.key);
    try std.testing.expect(try pmaReaderNext(&reader));

    const pmas = [_][]const u8{ pma, pma };
    const engine = try mergeEngineLevel0(allocator, &pmas, compareRecords);
    defer mergeEngineFree(engine);
    try std.testing.expect(engine.current != null);
    try std.testing.expectEqualStrings("a", engine.readers[engine.current.?].key);
    _ = try mergeEngineStep(engine);
    try std.testing.expectEqualStrings("a", engine.readers[engine.current.?].key);
    const setup = try sorterSetupMerge(allocator, &pmas, compareRecords);
    defer mergeEngineFree(setup);
    try std.testing.expect(setup.current != null);
}

test "incremental merger and sorter helper ownership" {
    const allocator = std.testing.allocator;
    var writer = pmaWriterInit(allocator, 0);
    try pmaWriteBlob(&writer, "abc");
    const written = try pmaWriterFinish(&writer);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("abc", written);

    const first = [_]Record{.{ .bytes = @constCast("a"), .ordinal = 0 }};
    const second = [_]Record{.{ .bytes = @constCast("b"), .ordinal = 1 }};
    const merged = try mergeRecords(allocator, compareRecords, &first, &second);
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("a", merged[0].bytes);
    try std.testing.expect(compareTail("prefix-a", "prefix-b", 7) < 0);
    try std.testing.expect(compareText("a", "b") < 0);
    try std.testing.expect(compareInteger("a", "b") < 0);
    try std.testing.expectEqual(@as(usize, 1), sorterTreeDepth(17));

    var pma_records = [_]Record{.{ .bytes = @constCast("x"), .ordinal = 0 }};
    const pma = try listToPma(allocator, &pma_records, compareRecords);
    defer allocator.free(pma);
    const engine = try mergeEngineLevel0(allocator, &.{pma}, compareRecords);
    const incremental = try incrementalMergerNew(allocator, engine, 64);
    defer incrementalFree(incremental);
    var incremental_reader = PmaReader{};
    try pmaReaderIncrementalInit(&incremental_reader, incremental);
    try std.testing.expectEqualStrings("x", incremental_reader.key);

    var task = SortSubtask{ .allocator = allocator };
    try task.records.append(allocator, .{ .bytes = try allocator.dupe(u8, "owned"), .ordinal = 0 });
    try task.pma.appendSlice(allocator, "pma");
    subtaskCleanup(&task);
}
