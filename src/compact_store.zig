const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const page_bytes: usize = 4 * 1024 * 1024;
pub const max_candidates: usize = std.math.maxInt(u32);
const extended_len_tag: u8 = 0xff;

inline fn recordHasNonAscii(record: []const u8) bool {
    const word_bytes = @sizeOf(usize);
    const high_bits: usize = 0x80 * (std.math.maxInt(usize) / 0xff);
    var i: usize = 0;
    while (i + word_bytes <= record.len) : (i += word_bytes) {
        const word = @as(*align(1) const usize, @ptrCast(record.ptr + i)).*;
        if ((word & high_bits) != 0) return true;
    }
    for (record[i..]) |c| if (c >= 0x80) return true;
    return false;
}

fn recordHeaderLen(len: usize) usize {
    return if (len < extended_len_tag) 1 else 5;
}

fn readRecordLen(mem: []const u8, offset: u32, used: u32) ?struct { len: u32, header: u32 } {
    if (offset >= used) return null;
    const tag = mem[offset];
    if (tag != extended_len_tag) return .{ .len = tag, .header = 1 };
    if (@as(usize, offset) + 5 > used) return null;
    const p: *const [4]u8 = @ptrCast(mem.ptr + offset + 1);
    return .{ .len = std.mem.readInt(u32, p, .little), .header = 5 };
}

pub const RecordRef = struct {
    ptr: [*]const u8,
    len: u32,
    id: u32,

    pub fn text(self: RecordRef) []const u8 {
        return self.ptr[0..self.len];
    }
};

const Page = struct {
    mem: []u8,
    base_id: u32,
    used_local: u32 = 0,
    count_local: u32 = 0,
    published_used: std.atomic.Value(u32) = .init(0),
    published_count: std.atomic.Value(u32) = .init(0),
};

pub const Snapshot = struct {
    allocator: Allocator,
    pages: []PageView,
    count: u32,
    finished: bool,
    all_ascii: bool,

    const PageView = struct {
        page: *const Page,
        used: u32,
        count: u32,
    };

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.pages);
        self.* = undefined;
    }

    pub fn iterator(self: *const Snapshot) Iterator {
        return .{ .snapshot = self };
    }

    pub fn pageCount(self: *const Snapshot) usize {
        return self.pages.len;
    }

    pub fn pageBaseId(self: *const Snapshot, index: usize) u32 {
        return self.pages[index].page.base_id;
    }

    pub fn pageEndId(self: *const Snapshot, index: usize) u32 {
        const view = self.pages[index];
        return view.page.base_id + view.count;
    }

    pub fn pageRecordCount(self: *const Snapshot, index: usize) u32 {
        return self.pages[index].count;
    }

    pub fn pageIndexForId(self: *const Snapshot, id: u32) ?usize {
        for (self.pages, 0..) |view, i| if (id < view.page.base_id + view.count) return i;
        return null;
    }

    pub fn pageIterator(self: *const Snapshot, index: usize) Iterator {
        return .{ .snapshot = self, .page_index = index };
    }

    pub fn iteratorFrom(self: *const Snapshot, start_id: u32) Iterator {
        var it = Iterator{ .snapshot = self };
        while (it.page_index < self.pages.len) {
            const view = self.pages[it.page_index];
            const base = view.page.base_id;
            const end = base + view.count;
            if (start_id < end) {
                const skip = if (start_id > base) start_id - base else 0;
                var n: u32 = 0;
                while (n < skip and it.local_index < view.count) : (n += 1) {
                    const decoded = readRecordLen(view.page.mem, it.offset, view.used) orelse break;
                    it.offset += decoded.header + decoded.len;
                    it.local_index += 1;
                }
                break;
            }
            it.page_index += 1;
        }
        return it;
    }

    pub const Iterator = struct {
        snapshot: *const Snapshot,
        page_index: usize = 0,
        local_index: u32 = 0,
        offset: u32 = 0,

        pub fn next(self: *Iterator) ?RecordRef {
            while (self.page_index < self.snapshot.pages.len) {
                const view = self.snapshot.pages[self.page_index];
                if (self.local_index >= view.count) {
                    self.page_index += 1;
                    self.local_index = 0;
                    self.offset = 0;
                    continue;
                }
                const decoded = readRecordLen(view.page.mem, self.offset, view.used) orelse return null;
                const len = decoded.len;
                const start = self.offset + decoded.header;
                const end = start + len;
                if (end > view.used) return null;
                const id = view.page.base_id + self.local_index;
                self.local_index += 1;
                self.offset = end;
                return .{ .ptr = view.page.mem.ptr + start, .len = len, .id = id };
            }
            return null;
        }
    };
};

pub const Store = struct {
    allocator: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    pages: std.ArrayList(*Page) = .empty,
    current: ?*Page = null,
    total_count: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    has_non_ascii_local: bool = false,
    published_has_non_ascii: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, io: Io) Store {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        const pages = self.pages;
        self.pages = .empty;
        self.current = null;
        self.mutex.unlock(self.io);
        for (pages.items) |page| {
            std.heap.page_allocator.free(page.mem);
            self.allocator.destroy(page);
        }
        var owned = pages;
        owned.deinit(self.allocator);
        self.* = undefined;
    }

    fn allocPage(self: *Store, min_capacity: usize) !*Page {
        const page_size = std.heap.pageSize();
        const wanted = @max(page_bytes, std.mem.alignForward(usize, min_capacity, page_size));
        if (wanted > std.math.maxInt(u32)) return error.RecordTooLong;
        const mem = try std.heap.page_allocator.alloc(u8, wanted);
        errdefer std.heap.page_allocator.free(mem);
        const page = try self.allocator.create(Page);
        errdefer self.allocator.destroy(page);
        page.* = .{ .mem = mem, .base_id = self.total_count.load(.acquire) };
        try self.pages.append(self.allocator, page);
        self.current = page;
        return page;
    }

    pub fn observeBytes(self: *Store, bytes: []const u8) void {
        if (!self.has_non_ascii_local and recordHasNonAscii(bytes)) {
            self.has_non_ascii_local = true;
            self.published_has_non_ascii.store(true, .release);
        }
    }

    pub fn append(self: *Store, record: []const u8) !RecordRef {
        return self.appendImpl(record, false);
    }

    /// Append a record whose containing source bytes were already passed to
    /// observeBytes(). Debug/ReleaseSafe builds verify that a non-ASCII record
    /// cannot accidentally bypass classification; ReleaseFast pays no rescan.
    pub fn appendClassified(self: *Store, record: []const u8) !RecordRef {
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
            std.debug.assert(self.has_non_ascii_local or !recordHasNonAscii(record));
        return self.appendImpl(record, true);
    }

    /// Append one record. Store has a single producer; readers only observe
    /// published_* atomics. The page-list mutex is therefore needed only when
    /// a new mapping is linked, not for every candidate.
    fn appendImpl(self: *Store, record: []const u8, comptime classified: bool) !RecordRef {
        if (record.len > std.math.maxInt(u32)) return error.RecordTooLong;
        if (self.finished.load(.acquire)) return error.AlreadyFinished;
        const header_len = recordHeaderLen(record.len);
        const needed = record.len + header_len;
        const old_count = self.total_count.load(.monotonic);
        if (old_count == std.math.maxInt(u32)) return error.TooManyCandidates;
        if (!classified) self.observeBytes(record);

        var page = self.current;
        if (page == null or @as(usize, page.?.used_local) + needed > page.?.mem.len) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // Only the producer changes current, but re-read it after taking
            // the lock so this remains robust if page allocation is refactored.
            page = self.current;
            if (page == null or @as(usize, page.?.used_local) + needed > page.?.mem.len)
                page = try self.allocPage(needed);
        }
        const target = page.?;
        const offset = target.used_local;
        if (header_len == 1) {
            target.mem[offset] = @intCast(record.len);
        } else {
            target.mem[offset] = extended_len_tag;
            const len_ptr: *[4]u8 = @ptrCast(target.mem.ptr + offset + 1);
            std.mem.writeInt(u32, len_ptr, @intCast(record.len), .little);
        }
        const start = offset + @as(u32, @intCast(header_len));
        @memcpy(target.mem[start .. start + record.len], record);
        target.used_local = @intCast(@as(usize, start) + record.len);
        target.count_local += 1;
        // Publish record bytes before count/used become visible to search workers.
        target.published_used.store(target.used_local, .release);
        target.published_count.store(target.count_local, .release);
        self.total_count.store(old_count + 1, .release);
        return .{ .ptr = target.mem.ptr + start, .len = @intCast(record.len), .id = old_count };
    }

    pub fn markFinished(self: *Store) void {
        self.finished.store(true, .release);
    }

    pub fn count(self: *const Store) u32 {
        return self.total_count.load(.acquire);
    }

    pub fn isFinished(self: *const Store) bool {
        return self.finished.load(.acquire);
    }

    pub fn snapshot(self: *Store, allocator: Allocator) !Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const views = try allocator.alloc(Snapshot.PageView, self.pages.items.len);
        var total: u32 = 0;
        for (self.pages.items, 0..) |page, i| {
            const published_count = page.published_count.load(.acquire);
            views[i] = .{
                .page = page,
                .used = page.published_used.load(.acquire),
                .count = published_count,
            };
            total +%= published_count;
        }
        return .{
            .allocator = allocator,
            .pages = views,
            .count = total,
            .finished = self.finished.load(.acquire),
            .all_ascii = !self.published_has_non_ascii.load(.acquire),
        };
    }
};

test "compact store packs records and snapshots append-only pages" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(a, io);
    defer store.deinit();
    const a_ref = try store.append("alpha");
    const b_ref = try store.append("beta");
    try std.testing.expectEqual(@as(u32, 0), a_ref.id);
    try std.testing.expectEqualStrings("alpha", a_ref.text());
    try std.testing.expectEqual(@as(u32, 1), b_ref.id);
    try std.testing.expectEqualStrings("beta", b_ref.text());
    var snapshot = try store.snapshot(a);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 2), snapshot.count);
    var it = snapshot.iterator();
    try std.testing.expectEqualStrings("alpha", it.next().?.text());
    try std.testing.expectEqualStrings("beta", it.next().?.text());
    try std.testing.expect(it.next() == null);
}

test "compact store uses one byte of persistent metadata per short record" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(a, io);
    defer store.deinit();
    var expected_used: usize = 0;
    for (0..10_000) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "item-{d}", .{i});
        _ = try store.append(line);
        expected_used += line.len + 1;
    }
    var snapshot = try store.snapshot(a);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 10_000), snapshot.count);
    // Short records use exactly one persistent length byte; no per-entry slice/struct array exists.
    try std.testing.expectEqual(@as(usize, 1), snapshot.pages.len);
    try std.testing.expectEqual(expected_used, @as(usize, snapshot.pages[0].used));
}

test "compact store extended length escape preserves long records" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(a, io);
    defer store.deinit();
    var long: [300]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @intCast(i % 251);
    _ = try store.append("");
    _ = try store.append("short");
    _ = try store.append(&long);
    var snapshot = try store.snapshot(a);
    defer snapshot.deinit();
    var it = snapshot.iterator();
    try std.testing.expectEqualStrings("", it.next().?.text());
    try std.testing.expectEqualStrings("short", it.next().?.text());
    try std.testing.expectEqualSlices(u8, &long, it.next().?.text());
    try std.testing.expect(it.next() == null);
}

test "compact store one-byte and extended length boundary" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(a, io);
    defer store.deinit();
    var a254: [254]u8 = undefined;
    var a255: [255]u8 = undefined;
    @memset(&a254, 'a');
    @memset(&a255, 'b');
    _ = try store.append(&a254);
    _ = try store.append(&a255);
    var snapshot = try store.snapshot(a);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 254 + 1 + 255 + 5), @as(usize, snapshot.pages[0].used));
    const short_header = readRecordLen(snapshot.pages[0].page.mem, 0, snapshot.pages[0].used).?;
    try std.testing.expectEqual(@as(u32, 254), short_header.len);
    try std.testing.expectEqual(@as(u32, 1), short_header.header);
    const long_header = readRecordLen(snapshot.pages[0].page.mem, 255, snapshot.pages[0].used).?;
    try std.testing.expectEqual(@as(u32, 255), long_header.len);
    try std.testing.expectEqual(@as(u32, 5), long_header.header);
    var it = snapshot.iterator();
    try std.testing.expectEqualSlices(u8, &a254, it.next().?.text());
    try std.testing.expectEqualSlices(u8, &a255, it.next().?.text());
    try std.testing.expect(it.next() == null);
}

test "compact result reference is sixteen bytes on 64-bit" {
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 16), @sizeOf(RecordRef));
}

test "compact snapshot page iteration exposes stable record domains" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(a, io);
    defer store.deinit();
    var payload: [300]u8 = undefined;
    @memset(&payload, 'x');
    for (0..15_000) |i| {
        payload[0] = @intCast(i % 251);
        _ = try store.append(&payload);
    }
    var snapshot = try store.snapshot(a);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.pageCount() >= 2);
    var summed: u32 = 0;
    for (0..snapshot.pageCount()) |page_index| summed += snapshot.pageRecordCount(page_index);
    try std.testing.expectEqual(snapshot.count, summed);
    const second_base = snapshot.pageBaseId(1);
    try std.testing.expectEqual(snapshot.pageEndId(0), second_base);
    try std.testing.expectEqual(@as(?usize, 1), snapshot.pageIndexForId(second_base));
    var page_it = snapshot.pageIterator(1);
    try std.testing.expectEqual(second_base, page_it.next().?.id);
    var from_it = snapshot.iteratorFrom(second_base);
    try std.testing.expectEqual(second_base, from_it.next().?.id);
}

test "compact snapshot tracks whether all published records are ASCII" {
    const a = std.testing.allocator;
    var store = Store.init(a, std.testing.io);
    defer store.deinit();
    _ = try store.append("alpha");
    var ascii = try store.snapshot(a);
    try std.testing.expect(ascii.all_ascii);
    ascii.deinit();
    _ = try store.append("βeta");
    var mixed = try store.snapshot(a);
    defer mixed.deinit();
    try std.testing.expect(!mixed.all_ascii);
}

test "compact classified append follows observed source bytes" {
    const a = std.testing.allocator;
    var store = Store.init(a, std.testing.io);
    defer store.deinit();
    store.observeBytes("alpha\nbeta\n");
    _ = try store.appendClassified("alpha");
    var ascii = try store.snapshot(a);
    try std.testing.expect(ascii.all_ascii);
    ascii.deinit();
    store.observeBytes("Danço\n");
    _ = try store.appendClassified("Danço");
    var mixed = try store.snapshot(a);
    defer mixed.deinit();
    try std.testing.expect(!mixed.all_ascii);
}

test "compact non-ASCII detector covers word boundaries and tails" {
    var buf: [40]u8 = @splat('a');
    try std.testing.expect(!recordHasNonAscii(&buf));
    for (0..buf.len) |index| {
        buf[index] = 0x80;
        try std.testing.expect(recordHasNonAscii(&buf));
        buf[index] = 'a';
    }
    for (0..@sizeOf(usize)) |offset| {
        const slice = buf[offset .. buf.len - (@sizeOf(usize) - 1 - offset)];
        try std.testing.expect(!recordHasNonAscii(slice));
        if (slice.len != 0) {
            buf[offset + slice.len - 1] = 0xff;
            try std.testing.expect(recordHasNonAscii(slice));
            buf[offset + slice.len - 1] = 'a';
        }
    }
}
