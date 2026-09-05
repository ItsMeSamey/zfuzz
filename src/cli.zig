const std = @import("std");
const builtin = @import("builtin");
const fuzzy = @import("fuzzy");
const fuzzy_engine = @import("engine");
const listen = @import("listen.zig");
const compact_store = @import("compact_store.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const esc = "\x1b[";

const Layout = enum { default, reverse };

fn logicalVerticalDelta(layout: Layout, visual_delta: isize) isize {
    return if (layout == .default) -visual_delta else visual_delta;
}

fn stableResultFocus(focus: usize, result_len: usize) usize {
    return if (result_len == 0) 0 else @min(focus, result_len - 1);
}

const LazyFocusState = struct { focus: usize, hint: usize };

fn refreshLazyFocus(previous_len: usize, previous_focus: usize, focus_hint: usize, result_len: usize) LazyFocusState {
    var hint = focus_hint;
    if (previous_len != 0) hint = previous_focus;
    if (result_len == 0) return .{ .focus = 0, .hint = hint };
    const focus = stableResultFocus(hint, result_len);
    return .{ .focus = focus, .hint = focus };
}

const lazy_first_publish_max_scan_count: usize = 4 * 1024;
const lazy_progress_publish_interval_ms: u64 = 20;
const lazy_parallel_min_candidates: u32 = 64 * 1024;
const lazy_frontier_depth: usize = 3;
const lazy_max_workers: usize = 64;

fn lazyWorkerCountForCores(cores: usize) usize {
    return @max(@as(usize, 1), @min(lazy_max_workers, (cores * 2) / 3));
}

fn lazyDefaultWorkerCount() usize {
    return lazyWorkerCountForCores(std.Thread.getCpuCount() catch 1);
}

fn lazyShouldPublishFirst(scanned: usize, retained: usize, top_k: usize) bool {
    return (top_k != 0 and retained >= top_k) or scanned >= lazy_first_publish_max_scan_count;
}

fn effectiveScrollOff(visible: usize, configured: usize) usize {
    if (visible == 0) return 0;
    return @min((visible - 1) / 2, configured);
}

const CaseMode = enum { smart, ignore, respect };
const Scheme = enum { default, path, history };
const Algorithm = enum { v2, v1, heuristic };
const PreviewPosition = enum { right, left, up, down };
const TieBreak = enum { length, chunk, pathname, begin, end };
const StylePreset = enum { default, minimal, full };
const BorderStyle = enum { none, rounded, sharp, bold, double, dashed, horizontal, vertical, top, bottom, left, right };
const InfoStyle = enum { default, right, hidden, inline_left, inline_right };

const SizeSpec = struct {
    value: u16 = 0,
    percent: bool = false,
};

const Insets = struct {
    top: SizeSpec = .{},
    right: SizeSpec = .{},
    bottom: SizeSpec = .{},
    left: SizeSpec = .{},
};

const LabelPosition = struct {
    column: i16 = 0,
    bottom: bool = false,
};

const Color = union(enum) {
    ansi: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

const RoleStyle = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strike: bool = false,
};

const Theme = struct {
    enabled: bool = true,
    normal: RoleStyle = .{},
    current: RoleStyle = .{ .reverse = true },
    highlight: RoleStyle = .{ .fg = .{ .ansi = 14 }, .bold = true },
    highlight_current: RoleStyle = .{ .fg = .{ .ansi = 14 }, .bold = true },
    info: RoleStyle = .{ .dim = true },
    border: RoleStyle = .{ .fg = .{ .ansi = 8 }, .dim = true },
    preview_border: RoleStyle = .{ .fg = .{ .ansi = 8 }, .dim = true },
    prompt: RoleStyle = .{ .fg = .{ .ansi = 14 }, .bold = true },
    pointer: RoleStyle = .{ .fg = .{ .ansi = 14 }, .bold = true },
    marker: RoleStyle = .{ .fg = .{ .ansi = 11 }, .bold = true },
    header: RoleStyle = .{ .fg = .{ .ansi = 10 } },
    footer: RoleStyle = .{ .fg = .{ .ansi = 10 } },
    query: RoleStyle = .{},
};

const PreviewOptions = struct {
    command: ?[]const u8 = null,
    position: PreviewPosition = .right,
    percent: u8 = 50,
    hidden: bool = false,
    wrap: bool = true,
    border_style: BorderStyle = .rounded,
    label: ?[]const u8 = null,
    label_pos: LabelPosition = .{},
};

const Action = union(enum) {
    ignore,
    up,
    down,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
    offset_up,
    offset_down,
    offset_middle,
    beginning_of_line,
    end_of_line,
    backward_char,
    forward_char,
    backward_delete_char,
    backward_delete_char_eof,
    delete_char,
    delete_char_eof,
    backward_word,
    forward_word,
    backward_subword,
    forward_subword,
    backward_kill_word,
    kill_word,
    backward_kill_subword,
    kill_subword,
    kill_line,
    unix_line_discard,
    unix_word_rubout,
    yank,
    cancel,
    print_query,
    accept_non_empty,
    accept_or_print_query,
    replace_query,
    put: []const u8,
    first,
    last,
    position: []const u8,
    toggle,
    toggle_up,
    toggle_down,
    toggle_in,
    toggle_out,
    toggle_all,
    select,
    deselect,
    select_all,
    deselect_all,
    clear_query,
    clear_screen,
    close,
    bell,
    accept,
    abort,
    toggle_preview,
    show_preview,
    hide_preview,
    refresh_preview,
    toggle_preview_wrap,
    toggle_wrap,
    toggle_raw,
    enable_raw,
    disable_raw,
    down_match,
    up_match,
    best,
    exclude,
    exclude_multi,
    toggle_input,
    show_input,
    hide_input,
    toggle_header,
    show_header,
    hide_header,
    wait,
    preview_top,
    preview_bottom,
    preview_up,
    preview_down,
    preview_page_up,
    preview_page_down,
    preview_half_page_up,
    preview_half_page_down,
    prev_selected,
    next_selected,
    toggle_sort,
    enable_search,
    disable_search,
    toggle_search,
    toggle_track,
    track_current,
    untrack_current,
    toggle_track_current,
    prev_history,
    next_history,
    change_query: []const u8,
    search: []const u8,
    change_nth: []const u8,
    change_with_nth: []const u8,
    change_multi: []const u8,
    change_prompt: []const u8,
    change_ghost: []const u8,
    change_pointer: []const u8,
    change_border_label: []const u8,
    change_preview_label: []const u8,
    change_header: []const u8,
    change_footer: []const u8,
    change_preview: []const u8,
    preview: []const u8,
    transform: []const u8,
    transform_query: []const u8,
    transform_search: []const u8,
    transform_nth: []const u8,
    transform_with_nth: []const u8,
    transform_prompt: []const u8,
    transform_ghost: []const u8,
    transform_pointer: []const u8,
    transform_border_label: []const u8,
    transform_preview_label: []const u8,
    transform_header: []const u8,
    transform_footer: []const u8,
    transform_preview: []const u8,
    bg_transform: []const u8,
    bg_transform_query: []const u8,
    bg_transform_search: []const u8,
    bg_transform_nth: []const u8,
    bg_transform_with_nth: []const u8,
    bg_transform_prompt: []const u8,
    bg_transform_ghost: []const u8,
    bg_transform_pointer: []const u8,
    bg_transform_border_label: []const u8,
    bg_transform_preview_label: []const u8,
    bg_transform_header: []const u8,
    bg_transform_footer: []const u8,
    bg_transform_preview: []const u8,
    bg_cancel,
    print: []const u8,
    reload: []const u8,
    reload_sync: []const u8,
    execute: []const u8,
    execute_multi: []const u8,
    execute_silent: []const u8,
    become: []const u8,
    unbind: []const u8,
    rebind: []const u8,
    toggle_bind: []const u8,
};

const Binding = struct {
    trigger: []const u8,
    name: []const u8,
    action: Action,
    enabled: bool = true,
    owned_payload: ?[]u8 = null,
};

const WalkerOptions = struct {
    file: bool = true,
    dir: bool = false,
    follow: bool = true,
    hidden: bool = true,
};

const Options = struct {
    query: []const u8 = "",
    filter: ?[]const u8 = null,
    prompt: []const u8 = "> ",
    no_input: bool = false,
    pointer: []const u8 = "▌",
    marker: []const u8 = "┃",
    header: ?[]const u8 = null,
    header_lines: usize = 0,
    header_first: bool = false,
    footer: ?[]const u8 = null,
    layout: Layout = .default,
    multi: bool = false,
    multi_max: ?usize = null,
    read0: bool = false,
    print0: bool = false,
    ansi: bool = false,
    cycle: bool = false,
    filepath_word: bool = false,
    scroll_off: usize = 3,
    wrap: bool = false,
    raw: bool = false,
    select_1: bool = false,
    exit_0: bool = false,
    print_query: bool = false,
    no_sort: bool = false,
    tiebreaks: [3]TieBreak = .{ .length, .length, .length },
    tiebreak_count: u2 = 1,
    disabled: bool = false,
    extended: bool = true,
    exact: bool = false,
    case_mode: CaseMode = .smart,
    literal: bool = false,
    scheme: Scheme = .default,
    algorithm: Algorithm = .v2,
    temp_dir: []const u8 = "",
    tac: bool = false,
    tail: ?usize = null,
    sync: bool = false,
    walker: WalkerOptions = .{},
    walker_roots: std.ArrayList([]const u8) = .empty,
    walker_skip: []const u8 = ".git,node_modules",
    history_file: ?[]const u8 = null,
    history_size: usize = 1000,
    track: bool = false,
    id_nth: ?[]const u8 = null,
    listen_addr: ?[]const u8 = null,
    listen_unsafe: bool = false,
    mouse: bool = true,
    style_preset: StylePreset = .default,
    border: bool = false,
    border_style: BorderStyle = .none,
    border_label: ?[]const u8 = null,
    border_label_pos: LabelPosition = .{},
    bold: bool = true,
    theme: Theme = .{},
    info_style: InfoStyle = .default,
    info_prefix: []const u8 = " < ",
    separator: ?[]const u8 = "─",
    ghost: ?[]const u8 = null,
    margin: Insets = .{},
    padding: Insets = .{},
    height_percent: u8 = 100,
    preview: PreviewOptions = .{},
    delimiter: ?[]const u8 = null,
    nth: ?[]const u8 = null,
    with_nth: ?[]const u8 = null,
    accept_nth: ?[]const u8 = null,
    expect: std.ArrayList([]const u8) = .empty,
    bindings: std.ArrayList(Binding) = .empty,

    fn deinit(self: *Options, allocator: Allocator) void {
        self.expect.deinit(allocator);
        for (self.bindings.items) |binding| if (binding.owned_payload) |value| allocator.free(value);
        self.bindings.deinit(allocator);
        self.walker_roots.deinit(allocator);
    }
};

const MultiMode = struct {
    enabled: bool,
    max: ?usize,
};

fn parseMultiMode(value: []const u8) ?MultiMode {
    if (value.len == 0) return .{ .enabled = true, .max = null };
    const max = std.fmt.parseInt(usize, value, 10) catch return null;
    return .{ .enabled = max != 0, .max = if (max == 0) null else max };
}

fn parseCliMultiMode(value: []const u8) ?MultiMode {
    if (value.len == 0) return .{ .enabled = true, .max = null };
    const max = std.fmt.parseInt(isize, value, 10) catch return null;
    if (max <= 0) return .{ .enabled = false, .max = null };
    return .{ .enabled = true, .max = @intCast(max) };
}

const CandidateSet = struct {
    blob: []u8,
    header: [][]const u8,
    output: [][]const u8,
    display: [][]const u8,
    search: [][]const u8,
    owned_display: bool,
    owned_search: bool,
    has_non_ascii: bool,

    fn deinit(self: *CandidateSet, allocator: Allocator) void {
        if (self.owned_search) {
            for (self.search) |line| allocator.free(line);
            allocator.free(self.search);
        }
        if (self.owned_display) {
            for (self.display) |line| allocator.free(line);
            allocator.free(self.display);
        }
        allocator.free(self.header);
        allocator.free(self.output);
        allocator.free(self.blob);
    }
};

fn candidatesFromLazyRanks(allocator: Allocator, ranks: []const LazyRank) !CandidateSet {
    const blob = try allocator.alloc(u8, 0);
    errdefer allocator.free(blob);
    const header = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(header);
    const output = try allocator.alloc([]const u8, ranks.len);
    errdefer allocator.free(output);
    var has_non_ascii = false;
    for (ranks, 0..) |rank, i| {
        const text = rank.record.text();
        output[i] = text;
        has_non_ascii = has_non_ascii or fuzzy_engine.cliTextHasNonAscii(text);
    }
    return .{
        .blob = blob,
        .header = header,
        .output = output,
        .display = output,
        .search = output,
        .owned_display = false,
        .owned_search = false,
        .has_non_ascii = has_non_ascii,
    };
}

const StreamUpdate = struct {
    changed: bool = false,
    eof_became: bool = false,
};

const StreamInput = struct {
    allocator: Allocator,
    delim: u8,
    tail: ?usize,
    header_limit: usize,
    headers: std.ArrayList([]u8) = .empty,
    records: std.ArrayList([]u8) = .empty,
    head: usize = 0,
    partial: std.ArrayList(u8) = .empty,
    eof: bool = false,

    fn init(allocator: Allocator, delim: u8, tail: ?usize, header_limit: usize) StreamInput {
        return .{ .allocator = allocator, .delim = delim, .tail = tail, .header_limit = header_limit };
    }

    fn deinit(self: *StreamInput) void {
        for (self.headers.items) |record| self.allocator.free(record);
        self.headers.deinit(self.allocator);
        for (self.records.items[self.head..]) |record| self.allocator.free(record);
        self.records.deinit(self.allocator);
        self.partial.deinit(self.allocator);
    }

    fn activeRecords(self: *const StreamInput) []const []u8 {
        return self.records.items[self.head..];
    }

    fn pushRecord(self: *StreamInput, record: []const u8) !void {
        if (self.headers.items.len < self.header_limit) {
            const owned = try self.allocator.dupe(u8, record);
            errdefer self.allocator.free(owned);
            try self.headers.append(self.allocator, owned);
            return;
        }
        if (self.tail) |limit| {
            if (limit == 0) return;
            while (self.records.items.len - self.head >= limit) {
                self.allocator.free(self.records.items[self.head]);
                self.head += 1;
            }
        }
        const owned = try self.allocator.dupe(u8, record);
        errdefer self.allocator.free(owned);
        try self.records.append(self.allocator, owned);
        if (self.head >= 4096 and self.head * 2 >= self.records.items.len) {
            const active = self.records.items[self.head..];
            std.mem.copyForwards([]u8, self.records.items[0..active.len], active);
            self.records.shrinkRetainingCapacity(active.len);
            self.head = 0;
        }
    }

    fn consume(self: *StreamInput, bytes: []const u8) !bool {
        var changed = false;
        for (bytes) |byte| {
            if (byte == self.delim) {
                try self.pushRecord(self.partial.items);
                self.partial.clearRetainingCapacity();
                changed = true;
            } else {
                try self.partial.append(self.allocator, byte);
            }
        }
        return changed;
    }

    fn finish(self: *StreamInput) !bool {
        if (self.eof) return false;
        self.eof = true;
        if (self.partial.items.len == 0) return false;
        try self.pushRecord(self.partial.items);
        self.partial.clearRetainingCapacity();
        return true;
    }

    fn readAvailable(self: *StreamInput) !StreamUpdate {
        // Zig 0.16 has no portable zero-timeout stdin-pipe readiness probe on Windows.
        // Windows therefore uses normal batch stdin instead of live pipe refresh.
        if (comptime builtin.os.tag == .windows) return .{};
        if (self.eof) return .{};
        var update: StreamUpdate = .{};
        var buffer: [64 * 1024]u8 = undefined;
        var bytes_this_tick: usize = 0;
        while (bytes_this_tick < 1024 * 1024) {
            var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = try std.posix.poll(&fds, 0);
            if (ready == 0) break;
            const revents = fds[0].revents;
            if ((revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) == 0) break;
            const n = std.c.read(std.posix.STDIN_FILENO, &buffer, buffer.len);
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == @intFromEnum(std.posix.E.INTR)) continue;
                return error.ReadFailed;
            }
            if (n == 0) {
                update.changed = (try self.finish()) or update.changed;
                update.eof_became = true;
                break;
            }
            const count: usize = @intCast(n);
            bytes_this_tick += count;
            update.changed = (try self.consume(buffer[0..count])) or update.changed;
        }
        return update;
    }

    fn materializeBlob(self: *const StreamInput) ![]u8 {
        const records = self.activeRecords();
        var len: usize = self.headers.items.len + records.len;
        for (self.headers.items) |record| len += record.len;
        for (records) |record| len += record.len;
        const blob = try self.allocator.alloc(u8, len);
        var at: usize = 0;
        for (self.headers.items) |record| {
            @memcpy(blob[at .. at + record.len], record);
            at += record.len;
            blob[at] = self.delim;
            at += 1;
        }
        for (records) |record| {
            @memcpy(blob[at .. at + record.len], record);
            at += record.len;
            blob[at] = self.delim;
            at += 1;
        }
        return blob;
    }
};

const TerminalSize = struct { rows: usize, cols: usize };
const TerminalOriginal = if (builtin.os.tag == .windows) void else std.posix.termios;

const Terminal = struct {
    file: Io.File,
    original: TerminalOriginal,
    active: bool = false,
    mouse: bool,
    inline_mode: bool,
    height_percent: u8,
    inline_rows: usize = 0,

    fn open(io: Io, mouse: bool, height_percent: u8) !Terminal {
        if (comptime builtin.os.tag == .windows) return error.UnsupportedTerminal;
        var file = try Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        errdefer file.close(io);
        const original = try std.posix.tcgetattr(file.handle);
        // Opening /dev/tty can succeed even when this process is in an orphaned
        // background process group. In that state tcsetattr fails with EIO, so
        // probe the operation before committing to interactive mode and let the
        // caller fall back to non-interactive filtering instead.
        try std.posix.tcsetattr(file.handle, .NOW, original);
        return .{ .file = file, .original = original, .mouse = mouse, .inline_mode = height_percent < 100, .height_percent = height_percent };
    }

    fn enter(self: *Terminal) !void {
        if (comptime builtin.os.tag == .windows) return error.UnsupportedTerminal;
        var raw = self.original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(self.file.handle, .FLUSH, raw);
        self.active = true;
        if (self.inline_mode) {
            const physical = self.physicalSize();
            self.inline_rows = std.math.clamp(physical.rows * self.height_percent / 100, @as(usize, 3), physical.rows);
            try self.write("\x1b[?25l");
            var i: usize = 1;
            while (i < self.inline_rows) : (i += 1) try self.write("\r\n");
            if (self.inline_rows > 1) {
                var buf: [32]u8 = undefined;
                const up = try std.fmt.bufPrint(&buf, "\x1b[{d}A", .{self.inline_rows - 1});
                try self.write(up);
            }
            try self.write("\r\x1b7");
        } else {
            try self.write("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        }
        if (self.mouse) try self.write("\x1b[?1000h\x1b[?1006h");
    }

    fn leave(self: *Terminal) void {
        if (comptime builtin.os.tag == .windows) {
            self.active = false;
            return;
        }
        if (!self.active) return;
        if (self.mouse) self.write("\x1b[?1000l\x1b[?1006l") catch {};
        if (self.inline_mode) {
            self.write("\x1b8") catch {};
            var i: usize = 0;
            while (i < self.inline_rows) : (i += 1) {
                self.write("\r\x1b[2K") catch {};
                if (i + 1 < self.inline_rows) self.write("\x1b[1B") catch {};
            }
            self.write("\x1b8\r\x1b[?25h") catch {};
        } else {
            self.write("\x1b[?25h\x1b[?1049l") catch {};
        }
        std.posix.tcsetattr(self.file.handle, .FLUSH, self.original) catch {};
        self.active = false;
    }

    fn close(self: *Terminal, io: Io) void {
        self.leave();
        self.file.close(io);
    }

    fn write(self: *Terminal, bytes: []const u8) !void {
        if (comptime builtin.os.tag == .windows) return error.UnsupportedTerminal;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.file.handle, bytes.ptr + off, bytes.len - off);
            if (n < 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn readByteTimeout(self: *Terminal, timeout_ms: i32) error{ UnsupportedTerminal, Timeout, ReadFailed }!u8 {
        if (comptime builtin.os.tag == .windows) return error.UnsupportedTerminal;
        var b: [1]u8 = undefined;
        while (true) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, timeout_ms) catch return error.ReadFailed;
            if (ready == 0) return error.Timeout;
            const n = std.c.read(self.file.handle, &b, 1);
            if (n == 1) return b[0];
            if (n == 0) continue;
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.posix.E.INTR)) continue;
            return error.ReadFailed;
        }
    }

    fn readByteTimeoutWithWake(self: *Terminal, wake_fd: i32, timeout_ms: i32) error{ UnsupportedTerminal, Timeout, Wake, ReadFailed }!u8 {
        if (comptime builtin.os.tag != .linux) return self.readByteTimeout(timeout_ms);
        if (wake_fd < 0) return self.readByteTimeout(timeout_ms);
        var b: [1]u8 = undefined;
        while (true) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.file.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = @intCast(wake_fd), .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, timeout_ms) catch return error.ReadFailed;
            if (ready == 0) return error.Timeout;
            // Input wins when both descriptors become ready together.
            if (fds[0].revents != 0) {
                const n = std.c.read(self.file.handle, &b, 1);
                if (n == 1) return b[0];
                if (n < 0) {
                    const e = std.c._errno().*;
                    if (e == @intFromEnum(std.posix.E.INTR)) continue;
                    return error.ReadFailed;
                }
            }
            if (fds[1].revents != 0) {
                var count: u64 = 0;
                _ = std.c.read(@intCast(wake_fd), @ptrCast(&count), @sizeOf(u64));
                return error.Wake;
            }
        }
    }

    fn readByte(self: *Terminal) error{ UnsupportedTerminal, Timeout, ReadFailed }!u8 {
        return self.readByteTimeout(40);
    }

    fn physicalSize(self: *Terminal) TerminalSize {
        if (comptime builtin.os.tag == .windows) return .{ .rows = 24, .cols = 80 };
        var ws: std.posix.winsize = undefined;
        const rc = std.c.ioctl(self.file.handle, std.c.T.IOCGWINSZ, &ws);
        if (rc != 0 or ws.row == 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    fn size(self: *Terminal) TerminalSize {
        const physical = self.physicalSize();
        if (!self.inline_mode) return physical;
        const rows = if (self.inline_rows != 0) self.inline_rows else std.math.clamp(physical.rows * self.height_percent / 100, @as(usize, 3), physical.rows);
        return .{ .rows = rows, .cols = physical.cols };
    }
};

const Key = union(enum) {
    byte: u8,
    alt_byte: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    word_left,
    word_right,
    paste_start,
    paste_end,
    delete,
    shift_tab,
    mouse: Mouse,
    unknown,
};

const Mouse = struct {
    button: usize,
    x: usize,
    y: usize,
    release: bool,
};

const Pane = struct {
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
};

const PaneGeometry = struct {
    main: Pane,
    preview: ?Pane,
};

const RenderGeometryKey = struct {
    rows: usize,
    cols: usize,
    main: Pane,
    content: Pane,
    preview: ?Pane,
    border: bool,
    border_style: BorderStyle,
    preview_border_style: BorderStyle,
};

const QueryHistory = struct {
    allocator: Allocator,
    io: Io,
    path: []const u8,
    max_size: usize,
    lines: std.ArrayList([]u8) = .empty,
    edits: []?[]u8 = &.{},
    cursor: usize = 0,

    fn init(allocator: Allocator, io: Io, path: []const u8, max_size: usize, initial_query: []const u8) !QueryHistory {
        var self = QueryHistory{ .allocator = allocator, .io = io, .path = path, .max_size = max_size };
        errdefer self.deinit();

        const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (file) |f| {
            defer f.close(io);
            var buffer: [8192]u8 = undefined;
            var reader = f.reader(io, &buffer);
            const bytes = try reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
            defer allocator.free(bytes);
            var parts = std.mem.splitScalar(u8, bytes, '\n');
            while (parts.next()) |raw| {
                const line = if (raw.len != 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
                if (line.len == 0) continue;
                try self.lines.append(allocator, try allocator.dupe(u8, line));
            }
        }
        if (self.lines.items.len > max_size) {
            const drop = self.lines.items.len - max_size;
            for (self.lines.items[0..drop]) |line| allocator.free(line);
            std.mem.copyForwards([]u8, self.lines.items[0 .. self.lines.items.len - drop], self.lines.items[drop..]);
            self.lines.items.len -= drop;
        }
        self.cursor = self.lines.items.len;
        self.edits = try allocator.alloc(?[]u8, self.lines.items.len + 1);
        @memset(self.edits, null);
        self.edits[self.cursor] = try allocator.dupe(u8, initial_query);
        return self;
    }

    fn deinit(self: *QueryHistory) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        for (self.edits) |edit| if (edit) |value| self.allocator.free(value);
        if (self.edits.len != 0) self.allocator.free(self.edits);
        self.edits = &.{};
    }

    fn remember(self: *QueryHistory, query: []const u8) !void {
        if (self.edits[self.cursor]) |old| self.allocator.free(old);
        self.edits[self.cursor] = try self.allocator.dupe(u8, query);
    }

    fn move(self: *QueryHistory, delta: isize, query: []const u8) !?[]const u8 {
        try self.remember(query);
        const old = self.cursor;
        if (delta < 0) {
            if (self.cursor != 0) self.cursor -= 1;
        } else if (delta > 0) {
            if (self.cursor < self.lines.items.len) self.cursor += 1;
        }
        if (self.cursor == old) return null;
        if (self.edits[self.cursor]) |edit| return edit;
        if (self.cursor < self.lines.items.len) return self.lines.items[self.cursor];
        return "";
    }

    fn save(self: *QueryHistory, query: []const u8) !void {
        if (query.len == 0) return;
        var start: usize = 0;
        if (self.lines.items.len != 0 and std.mem.eql(u8, self.lines.items[self.lines.items.len - 1], query)) return;
        if (self.lines.items.len >= self.max_size) start = self.lines.items.len - self.max_size + 1;

        var file = try Io.Dir.cwd().createFile(self.io, self.path, .{ .truncate = true });
        defer file.close(self.io);
        var buffer: [8192]u8 = undefined;
        var writer = file.writerStreaming(self.io, &buffer);
        for (self.lines.items[start..]) |line| {
            try writer.interface.writeAll(line);
            try writer.interface.writeByte('\n');
        }
        try writer.interface.writeAll(query);
        try writer.interface.writeByte('\n');
        try writer.flush();
    }
};

const BackgroundKind = enum { actions, query, search, nth, with_nth, prompt, ghost, pointer, border_label, preview_label, header, footer, preview, preview_content, reload };

const BackgroundResult = struct {
    kind: BackgroundKind,
    output: []u8,
    generation: u64,
    binding_slot: ?usize = null,
};

const BackgroundQueue = struct {
    allocator: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    results: std.ArrayList(BackgroundResult) = .empty,
    running_pgroups: std.ArrayList(i64) = .empty,
    cancel_generation: u64 = 0,
    active: usize = 0,
    alive: bool = true,

    fn create(allocator: Allocator, io: Io) !*BackgroundQueue {
        const self = try allocator.create(BackgroundQueue);
        self.* = .{ .allocator = allocator, .io = io };
        return self;
    }

    fn begin(self: *BackgroundQueue) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.alive) return null;
        self.active += 1;
        return self.cancel_generation;
    }

    fn registerProcess(self: *BackgroundQueue, cancel_generation: u64, pgid: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.alive or cancel_generation != self.cancel_generation) return false;
        try self.running_pgroups.append(self.allocator, pgid);
        return true;
    }

    fn unregisterProcess(self: *BackgroundQueue, pgid: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.running_pgroups.items, 0..) |value, i| {
            if (value == pgid) {
                _ = self.running_pgroups.swapRemove(i);
                return;
            }
        }
    }

    fn cancel(self: *BackgroundQueue) void {
        self.mutex.lockUncancelable(self.io);
        self.cancel_generation +%= 1;
        var keep: usize = 0;
        for (self.results.items) |result| {
            if (result.kind == .reload) {
                self.results.items[keep] = result;
                keep += 1;
            } else {
                self.allocator.free(result.output);
            }
        }
        self.results.items.len = keep;
        for (self.running_pgroups.items) |pgid| killBackgroundProcessGroup(pgid);
        self.mutex.unlock(self.io);
    }

    fn finish(self: *BackgroundQueue, kind: BackgroundKind, output: ?[]u8, generation: u64, binding_slot: ?usize, cancel_generation: u64) void {
        self.mutex.lockUncancelable(self.io);
        const current = kind == .reload or cancel_generation == self.cancel_generation;
        if (self.alive and current) {
            if (output) |value| {
                self.results.append(self.allocator, .{ .kind = kind, .output = value, .generation = generation, .binding_slot = binding_slot }) catch self.allocator.free(value);
            }
        } else if (output) |value| {
            self.allocator.free(value);
        }
        self.active -= 1;
        const should_destroy = !self.alive and self.active == 0;
        self.mutex.unlock(self.io);
        if (should_destroy) self.destroy();
    }

    fn takeAll(self: *BackgroundQueue) std.ArrayList(BackgroundResult) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = self.results;
        self.results = .empty;
        return out;
    }

    fn close(self: *BackgroundQueue) void {
        self.mutex.lockUncancelable(self.io);
        self.alive = false;
        self.cancel_generation +%= 1;
        for (self.running_pgroups.items) |pgid| killBackgroundProcessGroup(pgid);
        for (self.results.items) |result| self.allocator.free(result.output);
        self.results.deinit(self.allocator);
        self.results = .empty;
        const should_destroy = self.active == 0;
        self.mutex.unlock(self.io);
        if (should_destroy) self.destroy();
    }

    fn destroy(self: *BackgroundQueue) void {
        const allocator = self.allocator;
        self.running_pgroups.deinit(allocator);
        allocator.destroy(self);
    }
};

const ExpandedCommand = struct {
    allocator: Allocator,
    io: Io,
    text: []u8,
    temp_files: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ExpandedCommand) void {
        for (self.temp_files.items) |path| {
            Io.Dir.deleteFileAbsolute(self.io, path) catch {};
            self.allocator.free(path);
        }
        self.temp_files.deinit(self.allocator);
        self.allocator.free(self.text);
    }
};

const BackgroundContext = struct {
    queue: *BackgroundQueue,
    allocator: Allocator,
    io: Io,
    kind: BackgroundKind,
    generation: u64,
    binding_slot: ?usize,
    cancel_generation: u64,
    expanded: ExpandedCommand,
    env: std.process.Environ.Map,
};

fn firstCommandOutputLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[0..end], "\r");
}

const EffectiveSearch = struct {
    query: []const u8,
    disabled: bool,
};

fn resolveEffectiveSearch(visible_query: []const u8, disabled: bool, search_override: ?[]const u8) EffectiveSearch {
    if (search_override) |query| return .{ .query = query, .disabled = false };
    if (disabled) return .{ .query = "", .disabled = true };
    return .{ .query = visible_query, .disabled = false };
}

fn killBackgroundProcessGroup(pgid: i64) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const pid: std.posix.pid_t = @intCast(pgid);
    std.posix.kill(-pid, .KILL) catch {};
}

fn runCancellableBackground(ctx: *BackgroundContext, max_stdout: usize) !std.process.RunResult {
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ "/bin/sh", "-c", ctx.expanded.text },
        .environ_map = &ctx.env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) null else 0,
    });
    defer child.kill(ctx.io);

    const pgid: i64 = switch (builtin.os.tag) {
        .windows, .wasi => 0,
        else => @intCast(child.id.?),
    };
    const registered = if (pgid == 0) false else ctx.queue.registerProcess(ctx.cancel_generation, pgid) catch |err| {
        killBackgroundProcessGroup(pgid);
        return err;
    };
    if (pgid != 0 and !registered) killBackgroundProcessGroup(pgid);
    defer if (registered) ctx.queue.unregisterProcess(pgid);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(ctx.allocator, ctx.io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > max_stdout or stderr_reader.buffered().len > 1024 * 1024) {
            if (pgid != 0) killBackgroundProcessGroup(pgid);
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| {
            if (pgid != 0) killBackgroundProcessGroup(pgid);
            return e;
        },
    }
    multi_reader.checkAnyError() catch |err| {
        if (pgid != 0) killBackgroundProcessGroup(pgid);
        return err;
    };

    const term = try child.wait(ctx.io);
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer ctx.allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout_slice, .stderr = stderr_slice };
}

fn backgroundTransformThread(ctx: *BackgroundContext) void {
    const allocator = ctx.allocator;
    defer {
        ctx.expanded.deinit();
        ctx.env.deinit();
        allocator.destroy(ctx);
    }
    const max_stdout: usize = switch (ctx.kind) {
        .reload => 64 * 1024 * 1024,
        .preview_content => 512 * 1024,
        else => 1024 * 1024,
    };
    const result = if (ctx.kind == .reload)
        std.process.run(allocator, ctx.io, .{
            .argv = &.{ "/bin/sh", "-c", ctx.expanded.text },
            .environ_map = &ctx.env,
            .stdout_limit = .limited(max_stdout),
            .stderr_limit = .limited(1024 * 1024),
        }) catch {
            ctx.queue.finish(ctx.kind, null, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
            return;
        }
    else
        runCancellableBackground(ctx, max_stdout) catch {
            ctx.queue.finish(ctx.kind, null, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
            return;
        };
    if (ctx.kind == .reload) {
        allocator.free(result.stderr);
        ctx.queue.finish(ctx.kind, result.stdout, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
        return;
    }
    if (ctx.kind == .preview_content) {
        const output = allocator.alloc(u8, result.stdout.len + result.stderr.len) catch {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            ctx.queue.finish(ctx.kind, null, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
            return;
        };
        @memcpy(output[0..result.stdout.len], result.stdout);
        @memcpy(output[result.stdout.len..], result.stderr);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        ctx.queue.finish(ctx.kind, output, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
        return;
    }
    allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    const text = switch (ctx.kind) {
        .query, .search, .nth, .with_nth, .prompt, .ghost, .pointer, .border_label, .preview_label => firstCommandOutputLine(trimmed),
        else => trimmed,
    };
    const output = allocator.dupe(u8, text) catch {
        ctx.queue.finish(ctx.kind, null, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
        return;
    };
    ctx.queue.finish(ctx.kind, output, ctx.generation, ctx.binding_slot, ctx.cancel_generation);
}

fn lazyAcceptNeedsWait(has_backend: bool, applied_generation: u64, generation: u64, result_len: usize, selected_count: usize, search_complete: bool) bool {
    if (!has_backend) return false;
    if (applied_generation != generation) return true;
    return result_len == 0 and selected_count == 0 and !search_complete;
}

const Ui = struct {
    allocator: Allocator,
    io: Io,
    options: *Options,
    candidates: *CandidateSet,
    index: *fuzzy.Index,
    terminal: *Terminal,
    stream: ?*StreamInput,
    server: ?*listen.Server,
    child_env: *const std.process.Environ.Map,
    lazy_backend: ?*LazyBackend,
    lazy_generation: u64 = 0,
    lazy_applied_generation: u64 = 0,
    lazy_pending_accept: bool = false,
    lazy_top_k: usize = 0,
    lazy_total_count: u32 = 0,
    lazy_match_count: u32 = 0,
    lazy_scanned_count: u32 = 0,
    lazy_search_complete: bool = false,
    lazy_input_finished: bool = false,
    bg_queue: *BackgroundQueue,
    preview_queue: *BackgroundQueue,
    history: ?QueryHistory = null,
    track_once: bool = false,
    pending_track_key: ?[]u8 = null,
    query: std.ArrayList(u8) = .empty,
    yanked: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    results: []usize,
    match_results: []usize,
    extended_ranks: []ExtendedRank,
    result_len: usize = 0,
    match_len: usize = 0,
    match_flags: []bool,
    best_match_idx: ?usize = null,
    result_cap: usize = 0,
    focus: usize = 0,
    scroll: usize = 0,
    lazy_focus_hint: usize = 0,
    selected: []bool,
    selection_order: std.ArrayList(usize) = .empty,
    selected_count: usize = 0,
    dirty_search: bool = true,
    preview_cache_key: ?usize = null,
    preview_cache_query_hash: u64 = 0,
    preview_forced: bool = false,
    preview_text: []u8 = &.{},
    preview_offset: usize = 0,
    last_frame: []u8 = &.{},
    last_list_frame: []u8 = &.{},
    last_render_geometry: ?RenderGeometryKey = null,
    accepted_key: ?[]const u8 = null,
    change_event_pending: bool = false,
    load_event_pending: bool = false,
    result_event_pending: bool = false,
    result_final_event_pending: bool = false,
    zero_event_pending: bool = false,
    one_event_pending: bool = false,
    focus_event_pending: bool = false,
    owned_prompt: ?[]u8 = null,
    owned_search_override: ?[]u8 = null,
    owned_nth: ?[]u8 = null,
    owned_with_nth: ?[]u8 = null,
    nth_default: ?[]const u8 = null,
    with_nth_default: ?[]const u8 = null,
    with_nth_enabled: bool = false,
    owned_ghost: ?[]u8 = null,
    owned_pointer: ?[]u8 = null,
    owned_border_label: ?[]u8 = null,
    owned_preview_label: ?[]u8 = null,
    owned_header: ?[]u8 = null,
    owned_footer: ?[]u8 = null,
    owned_preview: ?[]u8 = null,
    print_queue: std.ArrayList([]u8) = .empty,
    input_hidden: bool = false,
    header_hidden: bool = false,
    last_action: []const u8 = "",
    last_action_buf: [64]u8 = [_]u8{0} ** 64,
    last_key: []const u8 = "",
    timer_last_ms: []u64 = &.{},
    last_activity_ms: u64 = 0,
    reload_generation: u64 = 0,
    preview_generation: u64 = 0,

    fn init(
        allocator: Allocator,
        io: Io,
        options: *Options,
        candidates: *CandidateSet,
        index: *fuzzy.Index,
        terminal: *Terminal,
        stream: ?*StreamInput,
        server: ?*listen.Server,
        child_env: *const std.process.Environ.Map,
        lazy_backend: ?*LazyBackend,
    ) !Ui {
        var query: std.ArrayList(u8) = .empty;
        try query.appendSlice(allocator, options.query);
        const results = try allocator.alloc(usize, candidates.display.len);
        errdefer allocator.free(results);
        const match_results = try allocator.alloc(usize, candidates.display.len);
        errdefer allocator.free(match_results);
        const extended_ranks = try allocator.alloc(ExtendedRank, candidates.display.len);
        errdefer allocator.free(extended_ranks);
        const selected = try allocator.alloc(bool, candidates.display.len);
        @memset(selected, false);
        const match_flags = try allocator.alloc(bool, candidates.display.len);
        errdefer allocator.free(match_flags);
        @memset(match_flags, false);
        var history: ?QueryHistory = null;
        if (options.history_file) |path| history = try QueryHistory.init(allocator, io, path, options.history_size, options.query);
        errdefer if (history) |*value| value.deinit();
        const timer_last_ms = try allocator.alloc(u64, options.bindings.items.len);
        errdefer allocator.free(timer_last_ms);
        const now_ms = monotonicMilliseconds(io);
        @memset(timer_last_ms, now_ms);
        const bg_queue = try BackgroundQueue.create(allocator, io);
        errdefer bg_queue.close();
        const preview_queue = try BackgroundQueue.create(allocator, io);
        errdefer preview_queue.close();
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .candidates = candidates,
            .index = index,
            .terminal = terminal,
            .stream = stream,
            .server = server,
            .child_env = child_env,
            .lazy_backend = lazy_backend,
            .bg_queue = bg_queue,
            .preview_queue = preview_queue,
            .history = history,
            .nth_default = options.nth,
            .with_nth_default = options.with_nth,
            .with_nth_enabled = options.with_nth != null,
            .query = query,
            .cursor = options.query.len,
            .results = results,
            .match_results = match_results,
            .extended_ranks = extended_ranks,
            .selected = selected,
            .match_flags = match_flags,
            .timer_last_ms = timer_last_ms,
            .input_hidden = options.no_input,
            .last_activity_ms = now_ms,
        };
    }

    fn deinit(self: *Ui) void {
        self.preview_queue.close();
        self.bg_queue.close();
        if (self.history) |*history| history.deinit();
        if (self.pending_track_key) |key| self.allocator.free(key);
        self.query.deinit(self.allocator);
        self.yanked.deinit(self.allocator);
        self.allocator.free(self.results);
        self.allocator.free(self.match_results);
        self.allocator.free(self.extended_ranks);
        self.allocator.free(self.selected);
        self.allocator.free(self.match_flags);
        self.selection_order.deinit(self.allocator);
        if (self.preview_text.len != 0) self.allocator.free(self.preview_text);
        if (self.last_frame.len != 0) self.allocator.free(self.last_frame);
        if (self.last_list_frame.len != 0) self.allocator.free(self.last_list_frame);
        if (self.owned_prompt) |value| self.allocator.free(value);
        if (self.owned_search_override) |value| self.allocator.free(value);
        if (self.owned_nth) |value| self.allocator.free(value);
        if (self.owned_with_nth) |value| self.allocator.free(value);
        if (self.owned_ghost) |value| self.allocator.free(value);
        if (self.owned_pointer) |value| self.allocator.free(value);
        if (self.owned_border_label) |value| self.allocator.free(value);
        if (self.owned_preview_label) |value| self.allocator.free(value);
        if (self.owned_header) |value| self.allocator.free(value);
        if (self.owned_footer) |value| self.allocator.free(value);
        if (self.owned_preview) |value| self.allocator.free(value);
        for (self.print_queue.items) |value| self.allocator.free(value);
        self.print_queue.deinit(self.allocator);
        if (self.timer_last_ms.len != 0) self.allocator.free(self.timer_last_ms);
    }

    fn run(self: *Ui) !u8 {
        try self.refreshSearch(true);
        const input_complete = if (self.lazy_backend != null)
            self.lazy_input_finished and self.lazy_search_complete
        else
            self.stream == null or self.stream.?.eof;
        if (input_complete and self.options.select_1 and self.reportedMatchCount() == 1) {
            self.focusCandidate(self.match_results[0]);
            try self.emitSelection(null);
            return 0;
        }
        if (input_complete and self.options.exit_0 and self.reportedMatchCount() == 0) return 1;

        try self.terminal.enter();
        defer self.terminal.leave();

        if (try self.fireEvent("start")) |code| return code;
        self.load_event_pending = input_complete;
        while (true) {
            var stream_finished = false;
            if (self.stream) |stream| {
                const update = try stream.readAvailable();
                if (update.changed) try self.refreshFromStream();
                if (update.eof_became) {
                    self.load_event_pending = true;
                    self.result_final_event_pending = true;
                    stream_finished = true;
                }
            }
            if (try self.processLazyResults()) |code| return code;
            if (self.load_event_pending) {
                self.load_event_pending = false;
                if (try self.fireEvent("load")) |code| return code;
            }
            if (self.change_event_pending) {
                self.change_event_pending = false;
                if (try self.fireEvent("change")) |code| return code;
            }
            if (self.dirty_search) try self.refreshSearch(false);
            if (stream_finished) {
                if (self.options.select_1 and self.reportedMatchCount() == 1) {
                    self.focusCandidate(self.match_results[0]);
                    try self.emitSelection(null);
                    return 0;
                }
                if (self.options.exit_0 and self.reportedMatchCount() == 0) return 1;
            }
            if (self.result_event_pending) {
                self.result_event_pending = false;
                if (try self.fireEvent("result")) |code| return code;
            }
            if (self.zero_event_pending) {
                self.zero_event_pending = false;
                if (try self.fireEvent("zero")) |code| return code;
            }
            if (self.one_event_pending) {
                self.one_event_pending = false;
                if (try self.fireEvent("one")) |code| return code;
            }
            if (self.result_final_event_pending) {
                self.result_final_event_pending = false;
                if (try self.fireEvent("result-final")) |code| return code;
            }
            if (self.focus_event_pending) {
                self.focus_event_pending = false;
                if (try self.fireEvent("focus")) |code| return code;
            }
            if (try self.fireTimers()) |code| return code;
            if (try self.processServerRequests()) |code| return code;
            if (try self.processBackgroundResults()) |code| return code;
            self.processPreviewResults();
            try self.render();
            const wake_fd = if (self.lazy_backend) |backend| backend.ui_wake_fd else -1;
            const key = try readKey(self.terminal, wake_fd);
            if (key != .unknown) self.last_activity_ms = monotonicMilliseconds(self.io);
            if (try self.handleKey(key)) |code| return code;
        }
    }

    fn refreshSearch(self: *Ui, force_all_for_auto: bool) !void {
        if (self.lazy_backend) |backend| {
            const size = self.terminal.size();
            if (self.lazy_top_k == 0) self.lazy_top_k = @max(@as(usize, 128), size.rows * 4);
            const effective = resolveEffectiveSearch(self.query.items, self.options.disabled, self.owned_search_override);
            var search_options = self.options.*;
            search_options.disabled = effective.disabled;
            self.lazy_generation = try backend.submit(effective.query, &search_options, self.lazy_top_k);
            // Counts belong to a search generation. Never render the previous
            // generation's progress next to a newly edited query.
            self.lazy_match_count = 0;
            self.lazy_scanned_count = 0;
            self.lazy_search_complete = false;
            self.dirty_search = false;
            return;
        }
        const n = self.candidates.display.len;
        var track_key = self.pending_track_key;
        self.pending_track_key = null;
        if (track_key == null and self.trackingActive()) track_key = try self.captureCurrentTrackKey();
        defer if (track_key) |key| self.allocator.free(key);

        const size = self.terminal.size();
        const base_cap = @min(n, @max(@as(usize, 256), size.rows * 8));
        if (self.result_cap == 0) self.result_cap = base_cap;
        if (force_all_for_auto and (self.options.select_1 or self.options.exit_0)) self.result_cap = n;
        if (self.options.no_sort or track_key != null or self.options.raw) self.result_cap = n;

        const effective = resolveEffectiveSearch(self.query.items, self.options.disabled, self.owned_search_override);
        var search_options = self.options.*;
        search_options.disabled = effective.disabled;
        const old_focus_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        const found = try searchCandidates(self.index, self.candidates, &search_options, effective.query, self.match_results, self.extended_ranks, self.result_cap);
        self.match_len = found.len;
        self.best_match_idx = if (found.len == 0) null else found[0];
        @memset(self.match_flags, false);
        for (found) |idx| self.match_flags[idx] = true;

        if (self.options.raw) {
            for (self.results[0..n], 0..) |*slot, idx| slot.* = idx;
            self.result_len = n;
        } else {
            @memcpy(self.results[0..found.len], found);
            self.result_len = found.len;
            if (self.options.no_sort) std.mem.sort(usize, self.results[0..self.result_len], {}, comptime std.sort.asc(usize));
        }

        const tracked_pos = if (track_key) |key| try self.findTrackedResult(key) else null;
        if (self.result_len == 0) {
            self.focus = 0;
            self.scroll = 0;
        } else if (tracked_pos) |pos| {
            self.focus = pos;
            self.ensureVisible();
        } else {
            if (track_key != null and self.track_once and !self.options.track) self.track_once = false;
            if (self.focus >= self.result_len) self.focus = self.result_len - 1;
            self.ensureVisible();
        }
        self.dirty_search = false;
        self.preview_cache_key = null;
        self.result_event_pending = true;
        self.zero_event_pending = self.match_len == 0;
        self.one_event_pending = self.match_len == 1;
        self.result_final_event_pending = self.stream == null or self.stream.?.eof;
        const new_focus_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        if (old_focus_idx != new_focus_idx) self.focus_event_pending = true;
    }

    fn canGrowResults(self: *const Ui) bool {
        if (self.lazy_backend != null) {
            if (self.lazy_top_k == 0 or self.result_len < self.lazy_top_k) return false;
            return !self.lazy_search_complete or self.lazy_match_count > self.result_len;
        }
        return self.result_len == self.result_cap and self.result_cap < self.candidates.display.len;
    }

    fn growResults(self: *Ui) !void {
        if (self.lazy_backend != null) {
            if (!self.canGrowResults()) return;
            const grown = @max(self.lazy_top_k +| 1, self.lazy_top_k *| 2);
            self.lazy_top_k = @min(grown, @as(usize, std.math.maxInt(u32)));
            self.dirty_search = true;
            try self.refreshSearch(false);
            return;
        }
        if (self.result_cap >= self.candidates.display.len) return;
        self.result_cap = @min(self.candidates.display.len, @max(self.result_cap + 1, self.result_cap * 2));
        self.dirty_search = true;
        try self.refreshSearch(false);
    }

    fn paneGeometry(self: *Ui, size: anytype) PaneGeometry {
        const full = Pane{ .row = 1, .col = 1, .rows = size.rows, .cols = size.cols };
        const area = insetPane(full, self.options.margin);
        var main_pane = area;
        const preview_active = (self.options.preview.command != null or self.preview_forced) and !self.options.preview.hidden;
        if (!preview_active) return .{ .main = main_pane, .preview = null };

        switch (self.options.preview.position) {
            .left, .right => {
                if (area.cols < 40) return .{ .main = main_pane, .preview = null };
                var width = area.cols * self.options.preview.percent / 100;
                width = std.math.clamp(width, 12, area.cols - 20);
                if (self.options.preview.position == .left) {
                    main_pane.col = area.col + width + 1;
                    main_pane.cols = area.cols - width - 1;
                    return .{ .main = main_pane, .preview = .{ .row = area.row, .col = area.col, .rows = area.rows, .cols = width } };
                }
                main_pane.cols = area.cols - width - 1;
                return .{ .main = main_pane, .preview = .{ .row = area.row, .col = main_pane.col + main_pane.cols + 1, .rows = area.rows, .cols = width } };
            },
            .up, .down => {
                if (area.rows < 8) return .{ .main = main_pane, .preview = null };
                var height = area.rows * self.options.preview.percent / 100;
                height = std.math.clamp(height, 3, area.rows - 4);
                if (self.options.preview.position == .up) {
                    main_pane.row = area.row + height + 1;
                    main_pane.rows = area.rows - height - 1;
                    return .{ .main = main_pane, .preview = .{ .row = area.row, .col = area.col, .rows = height, .cols = area.cols } };
                }
                main_pane.rows = area.rows - height - 1;
                return .{ .main = main_pane, .preview = .{ .row = main_pane.row + main_pane.rows + 1, .col = area.col, .rows = height, .cols = area.cols } };
            },
        }
    }

    fn contentPane(self: *Ui, pane: Pane) Pane {
        var content = pane;
        if (self.options.border and self.options.border_style != .none) {
            const sides = borderSides(self.options.border_style);
            const border_insets = Insets{
                .top = .{ .value = @intFromBool(sides.top) },
                .right = .{ .value = @intFromBool(sides.right) },
                .bottom = .{ .value = @intFromBool(sides.bottom) },
                .left = .{ .value = @intFromBool(sides.left) },
            };
            content = insetPane(content, border_insets);
        }
        return insetPane(content, self.options.padding);
    }

    fn headerRowCount(self: *const Ui) usize {
        if (self.header_hidden) return 0;
        var count = self.candidates.header.len;
        if (self.options.header) |text| {
            if (text.len != 0) {
                count += 1;
                for (text) |byte| if (byte == '\n') {
                    count += 1;
                };
            }
        }
        return count;
    }

    fn renderHeaderBlock(self: *Ui, w: anytype, start_row: usize, content: Pane) !usize {
        if (self.header_hidden) return start_row;
        var row = start_row;
        if (self.options.header) |text| {
            if (text.len != 0) {
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |line| {
                    try self.renderPlainLine(w, row, content.col, line, content.cols, self.options.theme.header);
                    row += 1;
                }
            }
        }
        for (self.candidates.header) |line| {
            try self.renderPlainLine(w, row, content.col, line, content.cols, self.options.theme.header);
            row += 1;
        }
        return row;
    }

    fn visibleListRows(self: *Ui) usize {
        const geom = self.paneGeometry(self.terminal.size());
        return self.listRows(self.contentPane(geom.main).rows);
    }

    fn ensureVisible(self: *Ui) void {
        const rows = self.visibleListRows();
        if (rows == 0 or self.result_len == 0) return;
        const visible = @min(rows, self.result_len);
        const max_scroll = self.result_len - visible;
        const scroll_off = effectiveScrollOff(visible, self.options.scroll_off);

        // fzf first constrains the viewport so the current item is visible, then
        // reserves up to --scroll-off rows on each side unless a list boundary
        // makes that impossible. In the single-line list model this reduces to
        // a closed interval for the logical scroll offset.
        const min_visible_scroll = self.focus -| (visible - 1);
        const max_visible_scroll = @min(max_scroll, self.focus);
        const min_margin_scroll = self.focus -| (visible - 1 - scroll_off);
        const max_margin_scroll = self.focus -| scroll_off;
        const lower = @min(max_visible_scroll, @max(min_visible_scroll, min_margin_scroll));
        const upper = @max(min_visible_scroll, @min(max_visible_scroll, max_margin_scroll));
        self.scroll = std.math.clamp(self.scroll, lower, upper);
    }

    fn listRows(self: *Ui, rows: usize) usize {
        var fixed: usize = @intFromBool(!self.input_hidden);
        if (self.options.info_style == .default or self.options.info_style == .right) fixed += 1;
        fixed += self.headerRowCount();
        if (self.options.footer != null) fixed += 1;
        const effective = @max(@as(usize, 3), rows);
        return if (effective > fixed) effective - fixed else 1;
    }

    fn setLastAction(self: *Ui, name: []const u8) void {
        const len = @min(name.len, self.last_action_buf.len);
        for (name[0..len], 0..) |c, i| self.last_action_buf[i] = std.ascii.toLower(c);
        self.last_action = self.last_action_buf[0..len];
    }

    fn handleKey(self: *Ui, key: Key) !?u8 {
        switch (key) {
            .paste_start => {
                try self.readBracketedPaste();
                return null;
            },
            .paste_end => return null,
            else => {},
        }
        var binding_handled = false;
        for (self.options.bindings.items, 0..) |binding, binding_slot| {
            if (!binding.enabled) continue;
            if (std.ascii.eqlIgnoreCase(binding.trigger, "start") or std.ascii.eqlIgnoreCase(binding.trigger, "load") or
                std.ascii.eqlIgnoreCase(binding.trigger, "change") or std.ascii.eqlIgnoreCase(binding.trigger, "result") or
                std.ascii.eqlIgnoreCase(binding.trigger, "result-final") or std.ascii.eqlIgnoreCase(binding.trigger, "zero") or
                std.ascii.eqlIgnoreCase(binding.trigger, "one") or std.ascii.eqlIgnoreCase(binding.trigger, "focus")) continue;
            if (!keyMatchesName(key, binding.trigger)) continue;
            binding_handled = true;
            self.setLastAction(binding.name);
            self.last_key = binding.trigger;
            if (try self.runAction(binding.action, binding_slot)) |code| return code;
        }
        if (binding_handled) return null;
        for (self.options.expect.items) |expected| {
            if (keyMatchesName(key, expected)) {
                self.accepted_key = expected;
                if (lazyAcceptNeedsWait(self.lazy_backend != null, self.lazy_applied_generation, self.lazy_generation, self.result_len, self.selected_count, self.lazy_search_complete)) {
                    self.lazy_pending_accept = true;
                    return null;
                }
                if (self.result_len == 0 and self.selected_count == 0) return 1;
                try self.emitSelection(expected);
                return 0;
            }
        }
        switch (key) {
            .up => self.moveVisual(-1),
            .down => self.moveVisual(1),
            .page_up => self.page(-1),
            .page_down => self.page(1),
            .word_left => self.cursor = self.queryWordBoundaryBackward(),
            .word_right => self.cursor = self.queryWordBoundaryForward(),
            .home => self.cursor = 0,
            .end => self.cursor = self.query.items.len,
            .left => self.cursor = prevUtf8Boundary(self.query.items, self.cursor),
            .right => self.cursor = nextUtf8Boundary(self.query.items, self.cursor),
            .delete => _ = try self.deleteCharForward(),
            .shift_tab => if (self.options.multi) {
                if (try self.toggleCurrent()) self.moveVisual(-1);
            },
            .mouse => |m| try self.handleMouse(m),
            .byte => |b| switch (b) {
                3, 7, 27 => return 130,
                13 => {
                    if (lazyAcceptNeedsWait(self.lazy_backend != null, self.lazy_applied_generation, self.lazy_generation, self.result_len, self.selected_count, self.lazy_search_complete)) {
                        self.lazy_pending_accept = true;
                        return null;
                    }
                    if (self.result_len == 0 and self.selected_count == 0) return 1;
                    try self.emitSelection(self.accepted_key);
                    return 0;
                },
                10 => self.moveVisual(1),
                9 => if (self.options.multi) {
                    if (try self.toggleCurrent()) self.moveVisual(1);
                },
                127, 8 => _ = try self.deleteCharBackward(),
                1 => self.cursor = 0,
                2 => self.cursor = prevUtf8Boundary(self.query.items, self.cursor),
                4 => if (!try self.deleteCharForward() and self.cursor == 0) return 130,
                5 => self.cursor = self.query.items.len,
                6 => self.cursor = nextUtf8Boundary(self.query.items, self.cursor),
                11 => self.moveVisual(-1),
                16 => if (self.history != null) try self.navigateHistory(-1) else self.moveVisual(-1),
                14 => if (self.history != null) try self.navigateHistory(1) else self.moveVisual(1),
                21 => _ = try self.unixLineDiscard(),
                23 => _ = try self.killWordBackward(),
                25 => _ = try self.yankQuery(),
                12 => {},
                else => {
                    if (b >= 32) {
                        try self.query.insertSlice(self.allocator, self.cursor, &.{b});
                        self.cursor += 1;
                        self.markQueryChanged();
                    }
                },
            },
            .alt_byte => |b| switch (b) {
                'b' => self.cursor = self.queryWordBoundaryBackward(),
                'f' => self.cursor = self.queryWordBoundaryForward(),
                'd' => _ = try self.killWordForward(),
                127 => _ = try self.killWordBackward(),
                8 => {},
                else => {},
            },
            .paste_start, .paste_end => unreachable,
            .unknown => {},
        }
        return null;
    }

    fn readBracketedPaste(self: *Ui) !void {
        const end_marker = "\x1b[201~";
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        var matched: usize = 0;
        var idle_timeouts: usize = 0;

        while (true) {
            const b = self.terminal.readByte() catch |err| switch (err) {
                error.Timeout => {
                    idle_timeouts += 1;
                    if (idle_timeouts < 50) continue;
                    if (matched != 0) try appendPastedBytes(self.allocator, &bytes, end_marker[0..matched]);
                    break;
                },
                else => return err,
            };
            idle_timeouts = 0;

            if (b == end_marker[matched]) {
                matched += 1;
                if (matched == end_marker.len) break;
                continue;
            }
            if (matched != 0) {
                try appendPastedBytes(self.allocator, &bytes, end_marker[0..matched]);
                matched = 0;
                if (b == end_marker[0]) {
                    matched = 1;
                    continue;
                }
            }
            try appendPastedByte(self.allocator, &bytes, b);
        }

        if (bytes.items.len != 0) {
            try self.query.insertSlice(self.allocator, self.cursor, bytes.items);
            self.cursor += bytes.items.len;
            self.markQueryChanged();
        }
    }

    fn markQueryChanged(self: *Ui) void {
        self.clearSearchOverride();
        self.dirty_search = true;
        self.change_event_pending = true;
        self.preview_cache_key = null;
    }

    fn clearSearchOverride(self: *Ui) void {
        if (self.owned_search_override) |value| self.allocator.free(value);
        self.owned_search_override = null;
    }

    fn setSearchOverrideOwned(self: *Ui, value: []u8) void {
        self.clearSearchOverride();
        self.owned_search_override = value;
        self.dirty_search = true;
        self.preview_cache_key = null;
    }

    fn setSearchOverride(self: *Ui, value: []const u8) !void {
        self.setSearchOverrideOwned(try self.allocator.dupe(u8, value));
    }

    fn navigateHistory(self: *Ui, delta: isize) !void {
        const history = if (self.history) |*value| value else return;
        const next = try history.move(delta, self.query.items) orelse return;
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, next);
        self.cursor = self.query.items.len;
        self.markQueryChanged();
    }

    fn trackingActive(self: *const Ui) bool {
        return self.options.track or self.track_once;
    }

    fn clearPendingTrackKey(self: *Ui) void {
        if (self.pending_track_key) |key| self.allocator.free(key);
        self.pending_track_key = null;
    }

    fn cancelOneShotTracking(self: *Ui) void {
        if (self.options.track) return;
        self.track_once = false;
        self.clearPendingTrackKey();
    }

    fn candidateIdentity(self: *Ui, candidates: *const CandidateSet, idx: usize) ![]u8 {
        const line = candidates.output[idx];
        const spec = self.options.id_nth orelse return self.allocator.dupe(u8, line);
        const trimmed = std.mem.trim(u8, spec, " \t");
        if (std.mem.eql(u8, trimmed, "..")) return self.allocator.dupe(u8, line);
        return transformFields(self.allocator, line, self.options.delimiter, spec, idx);
    }

    fn captureCurrentTrackKey(self: *Ui) !?[]u8 {
        if (self.result_len == 0) return null;
        return try self.candidateIdentity(self.candidates, self.results[self.focus]);
    }

    fn findTrackedResult(self: *Ui, key: []const u8) !?usize {
        const spec = self.options.id_nth;
        const direct = spec == null or std.mem.eql(u8, std.mem.trim(u8, spec.?, " \t"), "..");
        for (self.results[0..self.result_len], 0..) |idx, pos| {
            if (direct) {
                if (std.mem.eql(u8, self.candidates.output[idx], key)) return pos;
                continue;
            }
            const candidate_key = try self.candidateIdentity(self.candidates, idx);
            defer self.allocator.free(candidate_key);
            if (std.mem.eql(u8, candidate_key, key)) return pos;
        }
        return null;
    }

    fn processServerRequests(self: *Ui) !?u8 {
        const server = self.server orelse return null;
        while (server.takeRequest()) |request| {
            switch (request) {
                .post => |body| {
                    defer self.allocator.free(body);
                    var actions: std.ArrayList(Binding) = .empty;
                    defer actions.deinit(self.allocator);
                    appendBindingActions(self.allocator, &actions, "http", body) catch continue;
                    for (actions.items) |binding| {
                        self.setLastAction(binding.name);
                        self.last_key = "";
                        if (try self.runAction(binding.action, null)) |code| return code;
                    }
                },
                .get => |waiter| {
                    const response = self.dumpStatus(waiter.params) catch null;
                    server.completeGet(waiter, response orelse try self.allocator.dupe(u8, "{\"error\":\"status\"}"));
                },
            }
        }
        return null;
    }

    fn applyLazyResult(self: *Ui, result: *const LazyResult) !void {
        // Compact-store pages never move while the backend is alive, so the UI
        // can borrow the retained record text directly instead of copying and
        // reparsing the top-K into a fresh blob for every progress publication.
        var new_candidates = try candidatesFromLazyRanks(self.allocator, result.ranks);
        errdefer new_candidates.deinit(self.allocator);
        // LazyBackend owns matching over the compact store. The initial empty
        // fuzzy index is intentionally left untouched; rebuilding an index for
        // the transient display window on every partial only stalls the UI.
        const n = new_candidates.display.len;
        const next_focus = refreshLazyFocus(self.result_len, self.focus, self.lazy_focus_hint, n);
        const new_results = try self.allocator.alloc(usize, n);
        errdefer self.allocator.free(new_results);
        for (new_results, 0..) |*slot, i| slot.* = i;

        self.candidates.deinit(self.allocator);
        self.allocator.free(self.results);
        self.candidates.* = new_candidates;
        self.results = new_results;
        self.lazy_applied_generation = result.generation;
        self.result_len = n;
        self.match_len = n;
        self.best_match_idx = if (n == 0) null else 0;
        self.result_cap = n;
        // Keep the cursor at the same logical result position while partial
        // rankings evolve. A transient empty partial must not erase that row:
        // save it as a hint and restore it when a later partial has results.
        self.focus = next_focus.focus;
        self.lazy_focus_hint = next_focus.hint;
        if (n == 0) {
            self.scroll = 0;
        } else {
            self.ensureVisible();
        }
        self.dirty_search = false;
        self.preview_cache_key = null;
    }

    fn processLazyResults(self: *Ui) !?u8 {
        const backend = self.lazy_backend orelse return null;
        var newest: ?*LazyResult = null;
        while (backend.takeResult()) |result| {
            if (result.generation != self.lazy_generation) {
                result.deinit();
                continue;
            }
            if (newest) |old| old.deinit();
            newest = result;
        }
        const result = newest orelse return null;
        defer result.deinit();
        try self.applyLazyResult(result);
        self.lazy_total_count = result.total_count;
        self.lazy_match_count = result.match_count;
        self.lazy_scanned_count = result.scanned_count;
        const became_finished = result.input_finished and !self.lazy_input_finished;
        self.lazy_input_finished = result.input_finished;
        self.lazy_search_complete = result.search_complete;
        self.result_event_pending = true;
        self.zero_event_pending = result.search_complete and result.match_count == 0;
        self.one_event_pending = result.search_complete and result.match_count == 1;
        self.result_final_event_pending = result.search_complete;
        if (became_finished) self.load_event_pending = true;
        if (self.lazy_pending_accept and (self.result_len != 0 or result.search_complete)) {
            self.lazy_pending_accept = false;
            if (self.result_len == 0 and self.selected_count == 0) return 1;
            try self.emitSelection(self.accepted_key);
            return 0;
        }
        if (result.search_complete) {
            if (self.options.select_1 and result.match_count == 1 and self.result_len == 1) {
                self.focusCandidate(self.results[0]);
                try self.emitSelection(null);
                return 0;
            }
            if (self.options.exit_0 and result.match_count == 0) return 1;
        }
        return null;
    }

    fn processPreviewResults(self: *Ui) void {
        var results = self.preview_queue.takeAll();
        defer results.deinit(self.allocator);
        for (results.items) |result| {
            defer self.allocator.free(result.output);
            if (result.kind != .preview_content or result.generation != self.preview_generation) continue;
            self.clearPreviewText();
            if (result.output.len != 0) self.preview_text = self.allocator.dupe(u8, result.output) catch &.{};
            self.preview_offset = 0;
        }
    }

    fn processBackgroundResults(self: *Ui) !?u8 {
        var results = self.bg_queue.takeAll();
        defer results.deinit(self.allocator);
        for (results.items) |result| {
            var owned: ?[]u8 = result.output;
            defer if (owned) |value| self.allocator.free(value);
            switch (result.kind) {
                .actions => {
                    if (result.output.len == 0) continue;
                    var actions: std.ArrayList(Binding) = .empty;
                    defer actions.deinit(self.allocator);
                    try appendBindingActions(self.allocator, &actions, "bg-transform", result.output);
                    for (actions.items) |binding| {
                        self.setLastAction(binding.name);
                        if (try self.runAction(binding.action, null)) |code| return code;
                    }
                },
                .query => {
                    self.query.clearRetainingCapacity();
                    try self.query.appendSlice(self.allocator, result.output);
                    self.cursor = self.query.items.len;
                    self.markQueryChanged();
                },
                .search => {
                    self.setSearchOverrideOwned(result.output);
                    owned = null;
                },
                .nth => try self.applyNthAction(result.output, result.binding_slot),
                .with_nth => try self.applyWithNthAction(result.output, result.binding_slot),
                .prompt => {
                    self.replaceOwnedText(&self.owned_prompt, &self.options.prompt, result.output);
                    owned = null;
                },
                .ghost => {
                    self.replaceOwnedOptionalText(&self.owned_ghost, &self.options.ghost, result.output);
                    owned = null;
                },
                .pointer => {
                    self.replaceOwnedText(&self.owned_pointer, &self.options.pointer, result.output);
                    owned = null;
                },
                .border_label => {
                    self.replaceOwnedOptionalText(&self.owned_border_label, &self.options.border_label, result.output);
                    owned = null;
                },
                .preview_label => {
                    self.replaceOwnedOptionalText(&self.owned_preview_label, &self.options.preview.label, result.output);
                    owned = null;
                },
                .header => {
                    self.replaceOwnedOptionalText(&self.owned_header, &self.options.header, result.output);
                    owned = null;
                },
                .footer => {
                    self.replaceOwnedOptionalText(&self.owned_footer, &self.options.footer, result.output);
                    owned = null;
                },
                .preview => {
                    self.replaceOwnedOptionalText(&self.owned_preview, &self.options.preview.command, result.output);
                    self.options.preview.hidden = false;
                    self.preview_cache_key = null;
                    self.preview_offset = 0;
                    owned = null;
                },
                .preview_content => continue,
                .reload => {
                    if (result.generation != self.reload_generation) continue;
                    var new_candidates = try candidatesFromOwnedBlob(self.allocator, result.output, self.options);
                    owned = null;
                    errdefer new_candidates.deinit(self.allocator);
                    var new_index = try fuzzy.init(self.allocator, new_candidates.search);
                    errdefer new_index.deinit();
                    try self.replaceCandidates(new_candidates, new_index, true);
                },
            }
        }
        return null;
    }

    fn dumpStatus(self: *Ui, params: listen.GetParams) ![]u8 {
        const StatusItem = struct {
            index: usize,
            text: []const u8,
        };
        const start = @min(params.offset, self.match_len);
        const match_count = @min(params.limit, self.match_len - start);
        const matches = try self.allocator.alloc(StatusItem, match_count);
        defer self.allocator.free(matches);
        for (matches, 0..) |*item, i| {
            const idx = self.match_results[start + i];
            item.* = .{ .index = idx, .text = self.candidates.output[idx] };
        }

        var selected_indices: std.ArrayList(usize) = .empty;
        defer selected_indices.deinit(self.allocator);
        for (self.selection_order.items) |idx| if (idx < self.selected.len and self.selected[idx]) try selected_indices.append(self.allocator, idx);
        const selected_start = @min(params.offset, selected_indices.items.len);
        const selected_count = @min(params.limit, selected_indices.items.len - selected_start);
        const selected = try self.allocator.alloc(StatusItem, selected_count);
        defer self.allocator.free(selected);
        for (selected, 0..) |*item, i| {
            const idx = selected_indices.items[selected_start + i];
            item.* = .{ .index = idx, .text = self.candidates.output[idx] };
        }

        const current: ?StatusItem = if (self.result_len == 0) null else blk: {
            const idx = self.results[self.focus];
            break :blk .{ .index = idx, .text = self.candidates.output[idx] };
        };
        const Status = struct {
            reading: bool,
            progress: u8,
            query: []const u8,
            position: usize,
            sort: bool,
            totalCount: usize,
            matchCount: usize,
            current: ?StatusItem,
            matches: []const StatusItem,
            selected: []const StatusItem,
        };
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(Status{
            .reading = self.stream != null and !self.stream.?.eof,
            .progress = if (self.stream != null and !self.stream.?.eof) 0 else 100,
            .query = self.query.items,
            .position = self.focus,
            .sort = !self.options.no_sort,
            .totalCount = self.candidates.display.len,
            .matchCount = self.match_len,
            .current = current,
            .matches = matches,
            .selected = selected,
        }, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn fireEvent(self: *Ui, event: []const u8) !?u8 {
        for (self.options.bindings.items, 0..) |binding, binding_slot| {
            if (!binding.enabled) continue;
            if (!std.ascii.eqlIgnoreCase(binding.trigger, event)) continue;
            self.setLastAction(binding.name);
            self.last_key = "";
            if (try self.runAction(binding.action, binding_slot)) |code| return code;
        }
        return null;
    }

    fn fireTimers(self: *Ui) !?u8 {
        const now_ms = monotonicMilliseconds(self.io);
        for (self.options.bindings.items, 0..) |binding, i| {
            if (!binding.enabled) continue;
            const interval_ms = everyIntervalMilliseconds(binding.trigger) orelse continue;
            if (now_ms -| self.timer_last_ms[i] < interval_ms) continue;
            self.timer_last_ms[i] = now_ms;
            self.setLastAction(binding.name);
            self.last_key = "";
            if (try self.runAction(binding.action, i)) |code| return code;
        }
        return null;
    }

    fn runAction(self: *Ui, action: Action, binding_slot: ?usize) anyerror!?u8 {
        switch (action) {
            .ignore => {},
            .up => self.moveVisual(-1),
            .down => self.moveVisual(1),
            .page_up => self.page(-1),
            .page_down => self.page(1),
            .half_page_up => self.halfPage(-1),
            .half_page_down => self.halfPage(1),
            .offset_up => self.offsetViewport(.up),
            .offset_down => self.offsetViewport(.down),
            .offset_middle => self.offsetViewportMiddle(),
            .beginning_of_line => self.cursor = 0,
            .end_of_line => self.cursor = self.query.items.len,
            .backward_char => self.cursor = prevUtf8Boundary(self.query.items, self.cursor),
            .forward_char => self.cursor = nextUtf8Boundary(self.query.items, self.cursor),
            .backward_delete_char => _ = try self.deleteCharBackward(),
            .backward_delete_char_eof => {
                if (self.query.items.len == 0) return 130;
                _ = try self.deleteCharBackward();
            },
            .delete_char => _ = try self.deleteCharForward(),
            .delete_char_eof => if (!try self.deleteCharForward() and self.cursor == 0) return 130,
            .up_match => self.moveMatch(self.visualDelta(-1)),
            .down_match => self.moveMatch(self.visualDelta(1)),
            .best => self.focusBestMatch(),
            .backward_word => self.cursor = self.queryWordBoundaryBackward(),
            .forward_word => self.cursor = self.queryWordBoundaryForward(),
            .backward_subword => self.cursor = subwordBoundaryBackward(self.query.items, self.cursor),
            .forward_subword => self.cursor = subwordBoundaryForward(self.query.items, self.cursor),
            .backward_kill_word => _ = try self.killWordBackward(),
            .kill_word => _ = try self.killWordForward(),
            .backward_kill_subword => _ = try self.killSubwordBackward(),
            .kill_subword => _ = try self.killSubwordForward(),
            .kill_line => _ = try self.killLine(),
            .unix_line_discard => _ = try self.unixLineDiscard(),
            .unix_word_rubout => _ = try self.unixWordRubout(),
            .yank => _ = try self.yankQuery(),
            .cancel => {
                if (self.query.items.len == 0) return 130;
                try self.setYanked(self.query.items);
                self.query.clearRetainingCapacity();
                self.cursor = 0;
                self.markQueryChanged();
            },
            .print_query => {
                try self.emitQueryOnly();
                return 0;
            },
            .accept_non_empty => {
                const input_complete = self.stream == null or self.stream.?.eof;
                if (self.selected_count != 0 or self.result_len != 0 or (input_complete and self.candidates.display.len == 0)) {
                    try self.emitSelection(null);
                    return 0;
                }
            },
            .accept_or_print_query => {
                if (self.selected_count != 0 or self.result_len != 0) {
                    try self.emitSelection(null);
                } else {
                    try self.emitQueryOnly();
                }
                return 0;
            },
            .replace_query => try self.replaceQueryWithCurrentDisplay(),
            .put => |value| {
                if (value.len != 0) {
                    try self.query.insertSlice(self.allocator, self.cursor, value);
                    self.cursor += value.len;
                    self.markQueryChanged();
                }
            },
            .first => if (self.result_len != 0) self.setFocus(0),
            .last => if (self.result_len != 0) {
                try self.ensureAllResults();
                self.setFocus(self.result_len - 1);
            },
            .position => |value| try self.setFocusPosition(value),
            .toggle => _ = try self.toggleCurrent(),
            .select => try self.selectCurrent(),
            .deselect => self.deselectCurrent(),
            .toggle_up => if (try self.toggleCurrent()) self.moveVisual(-1),
            .toggle_down => if (try self.toggleCurrent()) self.moveVisual(1),
            .toggle_in => if (try self.toggleCurrent()) self.moveVisual(-1),
            .toggle_out => if (try self.toggleCurrent()) self.moveVisual(1),
            .toggle_all => try self.toggleAll(),
            .select_all => {
                if (self.options.multi) {
                    try self.ensureAllResults();
                    for (self.results[0..self.result_len]) |idx| {
                        if (self.selected[idx]) continue;
                        if (self.options.multi_max) |max| if (self.selected_count >= max) break;
                        self.selected[idx] = true;
                        try self.selection_order.append(self.allocator, idx);
                        self.selected_count += 1;
                    }
                }
            },
            .deselect_all => {
                @memset(self.selected, false);
                self.selection_order.clearRetainingCapacity();
                self.selected_count = 0;
            },
            .clear_query => {
                self.query.clearRetainingCapacity();
                self.cursor = 0;
                self.markQueryChanged();
            },
            .clear_screen => {}, // Every action frame is already a full redraw.
            .bell => try self.terminal.write("\x07"),
            .close => {
                if (self.paneGeometry(self.terminal.size()).preview != null) {
                    self.options.preview.hidden = true;
                    self.preview_forced = false;
                    self.preview_cache_key = null;
                } else return 130;
            },
            .accept => {
                if (self.result_len == 0 and self.selected_count == 0) return 1;
                try self.emitSelection(null);
                return 0;
            },
            .abort => return 130,
            .toggle_preview => {
                const active = (self.options.preview.command != null or self.preview_forced) and !self.options.preview.hidden;
                if (active or self.options.preview.command != null) {
                    self.options.preview.hidden = !active;
                    self.preview_forced = false;
                    self.preview_cache_key = null;
                }
            },
            .show_preview => {
                const active = (self.options.preview.command != null or self.preview_forced) and !self.options.preview.hidden;
                if (!active and self.options.preview.command != null) {
                    self.options.preview.hidden = false;
                    self.preview_forced = false;
                    self.preview_cache_key = null;
                }
            },
            .hide_preview => {
                const active = (self.options.preview.command != null or self.preview_forced) and !self.options.preview.hidden;
                if (active) {
                    self.options.preview.hidden = true;
                    self.preview_forced = false;
                }
            },
            .refresh_preview => {
                self.preview_cache_key = null;
                self.preview_offset = 0;
            },
            .toggle_preview_wrap => self.options.preview.wrap = !self.options.preview.wrap,
            .toggle_wrap => self.options.wrap = !self.options.wrap,
            .toggle_input => self.input_hidden = !self.input_hidden,
            .show_input => self.input_hidden = false,
            .hide_input => self.input_hidden = true,
            .toggle_header => self.header_hidden = !self.header_hidden,
            .show_header => self.header_hidden = false,
            .hide_header => self.header_hidden = true,
            .wait => try self.waitForSearch(),
            .preview_top => self.preview_offset = 0,
            .preview_bottom => self.preview_offset = self.previewMaxOffset(),
            .preview_up => self.scrollPreview(-1),
            .preview_down => self.scrollPreview(1),
            .preview_page_up => self.scrollPreview(-@as(isize, @intCast(self.previewContentRows()))),
            .preview_page_down => self.scrollPreview(@intCast(self.previewContentRows())),
            .preview_half_page_up => self.scrollPreview(-@as(isize, @intCast(@max(@as(usize, 1), self.previewContentRows() / 2)))),
            .preview_half_page_down => self.scrollPreview(@intCast(@max(@as(usize, 1), self.previewContentRows() / 2))),
            .prev_selected => self.moveSelected(-1),
            .next_selected => self.moveSelected(1),
            .toggle_sort => {
                self.options.no_sort = !self.options.no_sort;
                self.dirty_search = true;
            },
            .toggle_raw => self.setRaw(!self.options.raw),
            .enable_raw => self.setRaw(true),
            .disable_raw => self.setRaw(false),
            .exclude => try self.excludeCurrent(),
            .exclude_multi => try self.excludeMulti(),
            .enable_search => {
                if (self.options.disabled) {
                    self.options.disabled = false;
                    self.dirty_search = true;
                }
            },
            .disable_search => {
                if (!self.options.disabled) {
                    self.options.disabled = true;
                    self.dirty_search = true;
                }
            },
            .toggle_search => {
                self.options.disabled = !self.options.disabled;
                self.dirty_search = true;
            },
            .toggle_track => {
                self.options.track = !self.options.track;
                self.track_once = false;
                self.clearPendingTrackKey();
            },
            .track_current => if (!self.options.track) {
                self.track_once = true;
                self.clearPendingTrackKey();
            },
            .untrack_current => if (!self.options.track) {
                self.track_once = false;
                self.clearPendingTrackKey();
            },
            .toggle_track_current => if (!self.options.track) {
                self.track_once = !self.track_once;
                self.clearPendingTrackKey();
            },
            .prev_history => try self.navigateHistory(-1),
            .next_history => try self.navigateHistory(1),
            .change_query => |value| {
                self.query.clearRetainingCapacity();
                try self.query.appendSlice(self.allocator, value);
                self.cursor = self.query.items.len;
                self.markQueryChanged();
            },
            .search => |value| try self.setSearchOverride(value),
            .change_nth => |value| try self.applyNthAction(self.bindingPayload(binding_slot, value), binding_slot),
            .change_with_nth => |value| if (self.with_nth_enabled) try self.applyWithNthAction(self.bindingPayload(binding_slot, value), binding_slot),
            .change_multi => |value| self.applyMultiAction(value),
            .change_prompt => |value| self.options.prompt = value,
            .change_ghost => |value| self.options.ghost = value,
            .change_pointer => |value| self.options.pointer = value,
            .change_border_label => |value| self.options.border_label = value,
            .change_preview_label => |value| self.options.preview.label = value,
            .change_header => |value| self.options.header = value,
            .change_footer => |value| self.options.footer = value,
            .change_preview => |value| {
                self.options.preview.command = value;
                self.options.preview.hidden = false;
                self.preview_forced = false;
                self.preview_cache_key = null;
                self.preview_offset = 0;
            },
            .preview => |cmd| try self.runPreviewAction(cmd),
            .transform => |cmd| return try self.runTransformActions(cmd),
            .transform_query => |cmd| {
                const value = try self.runTransformCommandFirstLine(cmd);
                defer self.allocator.free(value);
                self.query.clearRetainingCapacity();
                try self.query.appendSlice(self.allocator, value);
                self.cursor = self.query.items.len;
                self.markQueryChanged();
            },
            .transform_search => |cmd| self.setSearchOverrideOwned(try self.runTransformCommandFirstLine(cmd)),
            .transform_nth => |cmd| {
                const value = try self.runTransformCommandFirstLine(self.bindingPayload(binding_slot, cmd));
                defer self.allocator.free(value);
                try self.applyNthAction(value, binding_slot);
            },
            .transform_with_nth => |cmd| if (self.with_nth_enabled) {
                const value = try self.runTransformCommandFirstLine(self.bindingPayload(binding_slot, cmd));
                defer self.allocator.free(value);
                try self.applyWithNthAction(value, binding_slot);
            },
            .transform_prompt => |cmd| {
                const value = try self.runTransformCommandFirstLine(cmd);
                self.replaceOwnedText(&self.owned_prompt, &self.options.prompt, value);
            },
            .transform_ghost => |cmd| {
                const value = try self.runTransformCommandFirstLine(cmd);
                self.replaceOwnedOptionalText(&self.owned_ghost, &self.options.ghost, value);
            },
            .transform_pointer => |cmd| {
                const value = try self.runTransformCommandFirstLine(cmd);
                self.replaceOwnedText(&self.owned_pointer, &self.options.pointer, value);
            },
            .transform_border_label => |cmd| {
                const value = try self.runTransformCommandFirstLine(cmd);
                self.replaceOwnedOptionalText(&self.owned_border_label, &self.options.border_label, value);
            },
            .transform_preview_label => |cmd| {
                const value = try self.runTransformCommandFirstLine(cmd);
                self.replaceOwnedOptionalText(&self.owned_preview_label, &self.options.preview.label, value);
            },
            .transform_header => |cmd| {
                const value = try self.runTransformCommand(cmd);
                self.replaceOwnedOptionalText(&self.owned_header, &self.options.header, value);
            },
            .transform_footer => |cmd| {
                const value = try self.runTransformCommand(cmd);
                self.replaceOwnedOptionalText(&self.owned_footer, &self.options.footer, value);
            },
            .transform_preview => |cmd| {
                const value = try self.runTransformCommand(cmd);
                self.replaceOwnedOptionalText(&self.owned_preview, &self.options.preview.command, value);
                self.options.preview.hidden = false;
                self.preview_cache_key = null;
                self.preview_offset = 0;
            },
            .bg_transform => |cmd| try self.launchBackgroundTransform(.actions, cmd),
            .bg_transform_query => |cmd| try self.launchBackgroundTransform(.query, cmd),
            .bg_transform_search => |cmd| try self.launchBackgroundTransform(.search, cmd),
            .bg_transform_nth => |cmd| try self.launchBackgroundCommand(.nth, self.bindingPayload(binding_slot, cmd), 0, binding_slot),
            .bg_transform_with_nth => |cmd| if (self.with_nth_enabled) try self.launchBackgroundCommand(.with_nth, self.bindingPayload(binding_slot, cmd), 0, binding_slot),
            .bg_transform_prompt => |cmd| try self.launchBackgroundTransform(.prompt, cmd),
            .bg_transform_ghost => |cmd| try self.launchBackgroundTransform(.ghost, cmd),
            .bg_transform_pointer => |cmd| try self.launchBackgroundTransform(.pointer, cmd),
            .bg_transform_border_label => |cmd| try self.launchBackgroundTransform(.border_label, cmd),
            .bg_transform_preview_label => |cmd| try self.launchBackgroundTransform(.preview_label, cmd),
            .bg_transform_header => |cmd| try self.launchBackgroundTransform(.header, cmd),
            .bg_transform_footer => |cmd| try self.launchBackgroundTransform(.footer, cmd),
            .bg_transform_preview => |cmd| try self.launchBackgroundTransform(.preview, cmd),
            .bg_cancel => self.bg_queue.cancel(),
            .print => |value| try self.print_queue.append(self.allocator, try self.allocator.dupe(u8, value)),
            .reload => |cmd| try self.launchAsyncReload(cmd),
            .reload_sync => |cmd| try self.reloadFromCommand(cmd),
            .execute => |cmd| try self.executeCommand(cmd, false, false),
            .execute_multi => |cmd| try self.executeCommand(cmd, false, true),
            .execute_silent => |cmd| try self.executeCommand(cmd, true, false),
            .become => |cmd| return try self.becomeCommand(cmd),
            .unbind => |targets| self.setBindingsEnabled(targets, .disable),
            .rebind => |targets| self.setBindingsEnabled(targets, .enable),
            .toggle_bind => |targets| self.setBindingsEnabled(targets, .toggle),
        }
        return null;
    }

    fn replaceQueryWithCurrentDisplay(self: *Ui) !void {
        if (self.result_len == 0) return;
        const idx = self.results[self.focus];
        var source = self.candidates.display[idx];
        var stripped: ?[]const u8 = null;
        defer if (stripped) |owned| self.allocator.free(owned);
        if (self.options.ansi) {
            const owned = try stripAnsi(self.allocator, source);
            stripped = owned;
            source = owned;
        }
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, source);
        self.cursor = self.query.items.len;
        self.markQueryChanged();
    }

    fn applyMultiAction(self: *Ui, value: []const u8) void {
        const mode = parseMultiMode(value) orelse return;
        const max_changed = if (mode.max) |max|
            self.options.multi_max == null or self.options.multi_max.? != max
        else
            self.options.multi_max != null;
        if (mode.enabled == self.options.multi and !max_changed) return;

        // fzf clears the whole selection set whenever an already-enabled
        // multi mode changes, even when the new limit could retain entries.
        if (self.options.multi) {
            @memset(self.selected, false);
            self.selection_order.clearRetainingCapacity();
            self.selected_count = 0;
        }

        self.options.multi = mode.enabled;
        self.options.multi_max = mode.max;
    }

    fn bindingPayload(self: *Ui, binding_slot: ?usize, fallback: []const u8) []const u8 {
        const slot = binding_slot orelse return fallback;
        if (slot >= self.options.bindings.items.len) return fallback;
        return self.options.bindings.items[slot].owned_payload orelse fallback;
    }

    fn rotateBindingPayload(self: *Ui, binding_slot: ?usize, payload: []const u8) !void {
        const slot = binding_slot orelse return;
        if (slot >= self.options.bindings.items.len) return;
        const bar = std.mem.indexOfScalar(u8, payload, '|') orelse return;
        var rotated: std.ArrayList(u8) = .empty;
        errdefer rotated.deinit(self.allocator);
        try rotated.appendSlice(self.allocator, payload[bar + 1 ..]);
        try rotated.append(self.allocator, '|');
        try rotated.appendSlice(self.allocator, payload[0..bar]);
        const value = try rotated.toOwnedSlice(self.allocator);
        const binding = &self.options.bindings.items[slot];
        if (binding.owned_payload) |old| self.allocator.free(old);
        binding.owned_payload = value;
    }

    fn optionalTextEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn nthSpecValid(spec: []const u8) bool {
        const trimmed = std.mem.trim(u8, spec, " \t");
        return trimmed.len != 0 and placeholderRangesValid(trimmed);
    }

    fn withNthSpecValid(spec: []const u8) bool {
        if (spec.len == 0) return true;
        if (std.mem.indexOfScalar(u8, spec, '{') == null) return nthSpecValid(spec);
        var i: usize = 0;
        while (i < spec.len) {
            if (spec[i] != '{') {
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, spec, i + 1, '}') orelse return false;
            const expr = spec[i + 1 .. close];
            if (!std.mem.eql(u8, expr, "n") and !placeholderRangesValid(expr)) return false;
            i = close + 1;
        }
        return true;
    }

    fn setNthSpec(self: *Ui, spec: ?[]const u8) !void {
        if (optionalTextEql(self.options.nth, spec)) return;
        var replacement: ?[]u8 = null;
        if (spec) |value| replacement = try self.allocator.dupe(u8, value);
        if (self.owned_nth) |old| self.allocator.free(old);
        self.owned_nth = replacement;
        self.options.nth = if (replacement) |value| value else null;
        try self.rebuildFieldTransforms();
    }

    fn setWithNthSpec(self: *Ui, spec: ?[]const u8) !void {
        if (optionalTextEql(self.options.with_nth, spec)) return;
        var replacement: ?[]u8 = null;
        if (spec) |value| replacement = try self.allocator.dupe(u8, value);
        if (self.owned_with_nth) |old| self.allocator.free(old);
        self.owned_with_nth = replacement;
        self.options.with_nth = if (replacement) |value| value else null;
        try self.rebuildFieldTransforms();
    }

    fn applyNthAction(self: *Ui, payload: []const u8, binding_slot: ?usize) !void {
        var tokens = std.mem.splitScalar(u8, payload, '|');
        const expr = tokens.next() orelse "";
        if (payload.len == 0) {
            try self.setNthSpec(null);
        } else if (nthSpecValid(expr)) {
            try self.setNthSpec(std.mem.trim(u8, expr, " \t"));
        } else {
            try self.setNthSpec(self.nth_default);
        }
        try self.rotateBindingPayload(binding_slot, payload);
    }

    fn applyWithNthAction(self: *Ui, payload: []const u8, binding_slot: ?usize) !void {
        if (!self.with_nth_enabled) return;
        var tokens = std.mem.splitScalar(u8, payload, '|');
        const expr = tokens.next() orelse "";
        var owned_expr: ?[]u8 = null;
        defer if (owned_expr) |value| self.allocator.free(value);
        const target: ?[]const u8 = if (expr.len == 0)
            self.with_nth_default
        else if (withNthSpecValid(expr)) blk: {
            owned_expr = try self.allocator.dupe(u8, expr);
            break :blk owned_expr.?;
        } else null;
        try self.rotateBindingPayload(binding_slot, payload);
        if (expr.len != 0 and target == null) return;
        try self.setWithNthSpec(target);
    }

    fn rebuildFieldTransforms(self: *Ui) !void {
        const blob = try self.allocator.dupe(u8, self.candidates.blob);
        errdefer self.allocator.free(blob);
        var new_candidates = try candidatesFromOwnedBlob(self.allocator, blob, self.options);
        errdefer new_candidates.deinit(self.allocator);
        var new_index = try fuzzy.init(self.allocator, new_candidates.search);
        errdefer new_index.deinit();
        try self.replaceCandidates(new_candidates, new_index, false);
    }

    const BindingStateChange = enum { disable, enable, toggle };

    fn setBindingsEnabled(self: *Ui, targets: []const u8, change: BindingStateChange) void {
        var target_it = std.mem.splitScalar(u8, targets, ',');
        while (target_it.next()) |raw_target| {
            const target = std.mem.trim(u8, raw_target, " \t");
            if (target.len == 0) continue;
            for (self.options.bindings.items) |*binding| {
                if (!triggerNamesEquivalent(binding.trigger, target)) continue;
                binding.enabled = switch (change) {
                    .disable => false,
                    .enable => true,
                    .toggle => !binding.enabled,
                };
            }
        }
    }

    fn commandEnvironment(self: *Ui) !std.process.Environ.Map {
        var env = try self.child_env.clone(self.allocator);
        errdefer env.deinit();
        try env.put("FZF_QUERY", self.query.items);
        try env.put("FZF_ACTION", self.last_action);
        try env.put("FZF_KEY", self.last_key);
        try env.put("FZF_INPUT_STATE", if (self.input_hidden) "hidden" else "enabled");
        try env.put("FZF_DIRECTION", if (self.options.layout == .reverse) "down" else "up");
        try env.put("FZF_PROMPT", self.options.prompt);
        var total_buf: [32]u8 = undefined;
        var match_buf: [32]u8 = undefined;
        var select_buf: [32]u8 = undefined;
        var pos_buf: [32]u8 = undefined;
        try env.put("FZF_TOTAL_COUNT", try std.fmt.bufPrint(&total_buf, "{d}", .{self.candidates.display.len}));
        try env.put("FZF_MATCH_COUNT", try std.fmt.bufPrint(&match_buf, "{d}", .{self.match_len}));
        try env.put("FZF_SELECT_COUNT", try std.fmt.bufPrint(&select_buf, "{d}", .{self.selected_count}));
        try env.put("FZF_POS", try std.fmt.bufPrint(&pos_buf, "{d}", .{if (self.result_len == 0) @as(usize, 0) else self.focus + 1}));
        const item = self.currentItem();
        if (item.len <= 64 * 1024 and std.mem.indexOfScalar(u8, item, 0) == null) try env.put("FZF_CURRENT_ITEM", item);
        if (self.options.border_label) |value| try env.put("FZF_BORDER_LABEL", value);
        if (self.options.preview.label) |value| try env.put("FZF_PREVIEW_LABEL", value);
        if (self.options.nth) |value| if (value.len != 0) {
            if (nthSpecValid(value)) {
                const canonical = try canonicalNthSpec(self.allocator, value);
                defer self.allocator.free(canonical);
                try env.put("FZF_NTH", canonical);
            } else {
                try env.put("FZF_NTH", value);
            }
        };
        if (self.options.with_nth) |value| if (value.len != 0) try env.put("FZF_WITH_NTH", value);
        const idle_ms = monotonicMilliseconds(self.io) -| self.last_activity_ms;
        var idle_ms_buf: [32]u8 = undefined;
        var idle_s_buf: [32]u8 = undefined;
        try env.put("FZF_IDLE_TIME_MS", try std.fmt.bufPrint(&idle_ms_buf, "{d}", .{idle_ms}));
        try env.put("FZF_IDLE_TIME", try std.fmt.bufPrint(&idle_s_buf, "{d}", .{idle_ms / 1000}));
        return env;
    }

    fn launchBackgroundCommandOn(self: *Ui, queue: *BackgroundQueue, kind: BackgroundKind, command: []const u8, generation: u64, binding_slot: ?usize) !void {
        var expanded = try self.expandedCommand(command);
        errdefer expanded.deinit();
        var env = try self.commandEnvironment();
        errdefer env.deinit();
        const cancel_generation = queue.begin() orelse {
            expanded.deinit();
            env.deinit();
            return;
        };
        const ctx = self.allocator.create(BackgroundContext) catch |err| {
            queue.finish(kind, null, generation, binding_slot, cancel_generation);
            return err;
        };
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .queue = queue,
            .allocator = self.allocator,
            .io = self.io,
            .kind = kind,
            .generation = generation,
            .binding_slot = binding_slot,
            .cancel_generation = cancel_generation,
            .expanded = expanded,
            .env = env,
        };
        const thread = std.Thread.spawn(.{}, backgroundTransformThread, .{ctx}) catch |err| {
            queue.finish(kind, null, generation, binding_slot, cancel_generation);
            return err;
        };
        thread.detach();
    }

    fn launchBackgroundCommand(self: *Ui, kind: BackgroundKind, command: []const u8, generation: u64, binding_slot: ?usize) !void {
        try self.launchBackgroundCommandOn(self.bg_queue, kind, command, generation, binding_slot);
    }

    fn launchBackgroundTransform(self: *Ui, kind: BackgroundKind, command: []const u8) !void {
        try self.launchBackgroundCommand(kind, command, 0, null);
    }

    fn launchAsyncReload(self: *Ui, command: []const u8) !void {
        self.stream = null;
        self.reload_generation +%= 1;
        try self.launchBackgroundCommand(.reload, command, self.reload_generation, null);
    }

    fn runTransformCommand(self: *Ui, command: []const u8) ![]u8 {
        var expanded = try self.expandedCommand(command);
        defer expanded.deinit();
        var env = try self.commandEnvironment();
        defer env.deinit();
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded.text },
            .environ_map = &env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        const text = std.mem.trimEnd(u8, result.stdout, "\r\n");
        return try self.allocator.dupe(u8, text);
    }

    fn runTransformCommandFirstLine(self: *Ui, command: []const u8) ![]u8 {
        const output = try self.runTransformCommand(command);
        defer self.allocator.free(output);
        return try self.allocator.dupe(u8, firstCommandOutputLine(output));
    }

    fn runTransformActions(self: *Ui, command: []const u8) anyerror!?u8 {
        const text = try self.runTransformCommand(command);
        defer self.allocator.free(text);
        if (text.len == 0) return null;
        var actions: std.ArrayList(Binding) = .empty;
        defer actions.deinit(self.allocator);
        try appendBindingActions(self.allocator, &actions, "transform", text);
        for (actions.items) |binding| {
            self.setLastAction(binding.name);
            if (try self.runAction(binding.action, null)) |code| return code;
        }
        return null;
    }

    fn replaceOwnedText(self: *Ui, storage: *?[]u8, target: *[]const u8, value: []u8) void {
        if (storage.*) |old| self.allocator.free(old);
        storage.* = value;
        target.* = value;
    }

    fn replaceOwnedOptionalText(self: *Ui, storage: *?[]u8, target: *?[]const u8, value: []u8) void {
        if (storage.*) |old| self.allocator.free(old);
        storage.* = value;
        target.* = value;
    }

    fn currentItem(self: *Ui) []const u8 {
        if (self.result_len == 0) return "";
        return self.candidates.output[self.results[self.focus]];
    }

    fn expandedCommand(self: *Ui, command: []const u8) !ExpandedCommand {
        return self.expandedCommandWithForcePlus(command, false);
    }

    fn expandedCommandWithForcePlus(self: *Ui, command: []const u8, force_plus: bool) !ExpandedCommand {
        const current_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        var temp_files: std.ArrayList([]u8) = .empty;
        errdefer {
            for (temp_files.items) |path| {
                Io.Dir.deleteFileAbsolute(self.io, path) catch {};
                self.allocator.free(path);
            }
            temp_files.deinit(self.allocator);
        }
        const text = try expandCommandImplWithForcePlus(
            self.allocator,
            command,
            self.query.items,
            self.candidates,
            self.options,
            current_idx,
            self.selection_order.items,
            self.selected,
            self.results[0..self.result_len],
            self.last_action,
            self.options.prompt,
            self.io,
            &temp_files,
            force_plus,
        );
        return .{ .allocator = self.allocator, .io = self.io, .text = text, .temp_files = temp_files };
    }

    fn replaceCandidates(self: *Ui, new_candidates: CandidateSet, new_index: fuzzy.Index, mark_load: bool) !void {
        var track_key = self.pending_track_key;
        self.pending_track_key = null;
        if (track_key == null and self.trackingActive()) track_key = try self.captureCurrentTrackKey();
        errdefer if (track_key) |key| self.allocator.free(key);

        const new_results = try self.allocator.alloc(usize, new_candidates.display.len);
        errdefer self.allocator.free(new_results);
        const new_match_results = try self.allocator.alloc(usize, new_candidates.display.len);
        errdefer self.allocator.free(new_match_results);
        const new_extended_ranks = try self.allocator.alloc(ExtendedRank, new_candidates.display.len);
        errdefer self.allocator.free(new_extended_ranks);
        const new_selected = try self.allocator.alloc(bool, new_candidates.display.len);
        errdefer self.allocator.free(new_selected);
        @memset(new_selected, false);
        const new_match_flags = try self.allocator.alloc(bool, new_candidates.display.len);
        errdefer self.allocator.free(new_match_flags);
        @memset(new_match_flags, false);

        var new_order: std.ArrayList(usize) = .empty;
        errdefer new_order.deinit(self.allocator);
        for (self.selection_order.items) |old_idx| {
            if (old_idx >= self.candidates.output.len or !self.selected[old_idx]) continue;
            if (self.options.id_nth == null) {
                const old_value = self.candidates.output[old_idx];
                for (new_candidates.output, 0..) |new_value, new_idx| {
                    if (new_selected[new_idx]) continue;
                    if (std.mem.eql(u8, old_value, new_value)) {
                        new_selected[new_idx] = true;
                        try new_order.append(self.allocator, new_idx);
                        break;
                    }
                }
                continue;
            }

            const old_key = try self.candidateIdentity(self.candidates, old_idx);
            defer self.allocator.free(old_key);
            for (new_candidates.output, 0..) |_, new_idx| {
                if (new_selected[new_idx]) continue;
                const new_key = try self.candidateIdentity(&new_candidates, new_idx);
                defer self.allocator.free(new_key);
                if (std.mem.eql(u8, old_key, new_key)) {
                    new_selected[new_idx] = true;
                    try new_order.append(self.allocator, new_idx);
                    break;
                }
            }
        }

        self.index.deinit();
        self.candidates.deinit(self.allocator);
        self.allocator.free(self.results);
        self.allocator.free(self.match_results);
        self.allocator.free(self.extended_ranks);
        self.allocator.free(self.selected);
        self.allocator.free(self.match_flags);
        self.selection_order.deinit(self.allocator);

        self.candidates.* = new_candidates;
        self.index.* = new_index;
        self.results = new_results;
        self.match_results = new_match_results;
        self.extended_ranks = new_extended_ranks;
        self.selected = new_selected;
        self.match_flags = new_match_flags;
        self.selection_order = new_order;
        self.selected_count = self.selection_order.items.len;
        self.result_len = 0;
        self.match_len = 0;
        self.best_match_idx = null;
        self.result_cap = 0;
        self.pending_track_key = track_key;
        track_key = null;
        self.focus = 0;
        self.scroll = 0;
        self.dirty_search = true;
        self.preview_cache_key = null;
        if (mark_load) self.load_event_pending = true;
        self.focus_event_pending = true;
    }

    fn refreshFromStream(self: *Ui) !void {
        const stream = self.stream orelse return;
        const blob = try stream.materializeBlob();
        var new_candidates = try candidatesFromOwnedBlob(self.allocator, blob, self.options);
        errdefer new_candidates.deinit(self.allocator);
        var new_index = try fuzzy.init(self.allocator, new_candidates.search);
        errdefer new_index.deinit();
        try self.replaceCandidates(new_candidates, new_index, false);
    }

    fn reloadFromCommand(self: *Ui, command: []const u8) !void {
        self.stream = null;
        var expanded = try self.expandedCommand(command);
        defer expanded.deinit();
        var env = try self.commandEnvironment();
        defer env.deinit();
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded.text },
            .environ_map = &env,
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer self.allocator.free(result.stderr);
        var new_candidates = try candidatesFromOwnedBlob(self.allocator, result.stdout, self.options);
        errdefer new_candidates.deinit(self.allocator);
        var new_index = try fuzzy.init(self.allocator, new_candidates.search);
        errdefer new_index.deinit();
        try self.replaceCandidates(new_candidates, new_index, true);
    }

    fn executeCommand(self: *Ui, command: []const u8, silent: bool, force_plus: bool) !void {
        var expanded = try self.expandedCommandWithForcePlus(command, force_plus);
        defer expanded.deinit();
        var env = try self.commandEnvironment();
        defer env.deinit();
        if (silent) {
            const result = try std.process.run(self.allocator, self.io, .{
                .argv = &.{ "/bin/sh", "-c", expanded.text },
                .environ_map = &env,
                .stdout_limit = .limited(1024 * 1024),
                .stderr_limit = .limited(1024 * 1024),
            });
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            return;
        }
        self.terminal.leave();
        defer self.terminal.enter() catch {};
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded.text },
            .environ_map = &env,
            .stdin = .{ .file = self.terminal.file },
            .stdout = .{ .file = self.terminal.file },
            .stderr = .{ .file = self.terminal.file },
        });
        _ = try child.wait(self.io);
        self.preview_cache_key = null;
    }

    fn becomeCommand(self: *Ui, command: []const u8) !u8 {
        var expanded = try self.expandedCommand(command);
        defer expanded.deinit();
        var env = try self.commandEnvironment();
        defer env.deinit();
        self.terminal.leave();
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded.text },
            .environ_map = &env,
            .stdin = .{ .file = self.terminal.file },
            .stdout = .{ .file = self.terminal.file },
            .stderr = .{ .file = self.terminal.file },
        });
        const term = try child.wait(self.io);
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    }

    fn handleMouse(self: *Ui, m: Mouse) !void {
        if (m.release) return;
        if (m.button == 64) {
            self.moveVisual(-3);
            return;
        }
        if (m.button == 65) {
            self.moveVisual(3);
            return;
        }
        if (m.button != 0) return;
        const geom = self.paneGeometry(self.terminal.size());
        const content = self.contentPane(geom.main);
        const rows = self.listRows(content.rows);
        const list_start = if (self.options.layout == .reverse)
            content.row + 1 + @intFromBool(self.options.info_style == .default or self.options.info_style == .right) + self.headerRowCount()
        else
            content.row;
        if (m.y < list_start or m.y >= list_start + rows) return;
        if (m.x < content.col or m.x >= content.col + content.cols) return;
        const rel = m.y - list_start;
        const item = if (self.options.layout == .reverse) self.scroll + rel else self.scroll + (rows - 1 - rel);
        if (item < self.result_len) {
            if (self.focus != item) {
                self.focus_event_pending = true;
                self.cancelOneShotTracking();
            }
            self.focus = item;
            self.ensureVisible();
            self.preview_cache_key = null;
        }
    }

    fn setFocus(self: *Ui, target: usize) void {
        if (self.focus != target) {
            self.focus_event_pending = true;
            self.cancelOneShotTracking();
        }
        self.focus = target;
        self.ensureVisible();
        self.preview_cache_key = null;
    }

    fn setFocusPosition(self: *Ui, value: []const u8) !void {
        var target = std.fmt.parseInt(isize, value, 10) catch return;
        if (self.result_len == 0) return;
        try self.ensureAllResults();
        if (target > 0) {
            target -= 1;
        } else if (target < 0) {
            target += @as(isize, @intCast(self.result_len));
        }
        target = std.math.clamp(target, 0, @as(isize, @intCast(self.result_len - 1)));
        self.setFocus(@intCast(target));
    }

    fn move(self: *Ui, delta: isize) void {
        if (self.result_len == 0) return;
        const old_focus = self.focus;
        if (delta < 0) {
            const amount: usize = @intCast(-delta);
            if (amount > self.focus) {
                self.focus = if (self.options.cycle) self.result_len - 1 else 0;
            } else self.focus -= amount;
        } else {
            const amount: usize = @intCast(delta);
            if (self.focus + amount >= self.result_len) {
                if (self.canGrowResults()) self.growResults() catch {};
                self.focus = if (self.options.cycle) 0 else self.result_len - 1;
            } else self.focus += amount;
        }
        self.ensureVisible();
        self.preview_cache_key = null;
        if (self.focus != old_focus) {
            self.focus_event_pending = true;
            self.cancelOneShotTracking();
        }
    }

    fn visualDelta(self: *const Ui, delta: isize) isize {
        return logicalVerticalDelta(self.options.layout, delta);
    }

    fn moveVisual(self: *Ui, delta: isize) void {
        self.move(self.visualDelta(delta));
    }

    fn focusCandidate(self: *Ui, candidate_idx: usize) void {
        for (self.results[0..self.result_len], 0..) |idx, pos| {
            if (idx != candidate_idx) continue;
            if (self.focus != pos) {
                self.focus = pos;
                self.ensureVisible();
                self.preview_cache_key = null;
                self.focus_event_pending = true;
                self.cancelOneShotTracking();
            }
            return;
        }
    }

    fn moveMatch(self: *Ui, direction: isize) void {
        if (!self.options.raw) {
            self.move(direction);
            return;
        }
        if (self.result_len == 0 or self.match_len == 0) return;
        var pos = self.focus;
        var scanned: usize = 0;
        while (scanned < self.result_len) : (scanned += 1) {
            if (direction < 0) {
                if (pos == 0) {
                    if (!self.options.cycle) return;
                    pos = self.result_len - 1;
                } else pos -= 1;
            } else {
                if (pos + 1 >= self.result_len) {
                    if (!self.options.cycle) return;
                    pos = 0;
                } else pos += 1;
            }
            const idx = self.results[pos];
            if (!self.match_flags[idx]) continue;
            self.focusCandidate(idx);
            return;
        }
    }

    fn setRaw(self: *Ui, enabled: bool) void {
        if (self.options.raw == enabled) return;
        if (!self.options.track) self.track_once = true;
        self.options.raw = enabled;
        self.result_cap = 0;
        self.dirty_search = true;
    }

    fn focusBestMatch(self: *Ui) void {
        if (!self.options.raw) {
            if (self.result_len != 0) self.focusCandidate(self.results[0]);
            return;
        }
        if (self.best_match_idx) |idx| self.focusCandidate(idx);
    }

    fn page(self: *Ui, delta: isize) void {
        const rows = @max(@as(usize, 1), self.visibleListRows());
        self.moveVisual(delta * @as(isize, @intCast(rows)));
    }

    fn halfPage(self: *Ui, delta: isize) void {
        const rows = @max(@as(usize, 1), self.visibleListRows() / 2);
        self.moveVisual(delta * @as(isize, @intCast(rows)));
    }

    const OffsetDirection = enum { up, down };

    fn offsetViewport(self: *Ui, direction: OffsetDirection) void {
        if (self.result_len == 0) return;
        const rows = @max(@as(usize, 1), self.visibleListRows());

        // fzf's offset direction is visual. Its logical offset advances in the
        // default (bottom-up) layout and retreats in reverse (top-down) layout.
        const logical_delta: isize = switch (direction) {
            .up => if (self.options.layout == .default) 1 else -1,
            .down => if (self.options.layout == .default) -1 else 1,
        };
        self.shiftViewport(logical_delta, rows);
    }

    fn shiftViewport(self: *Ui, delta: isize, rows: usize) void {
        if (delta == 0 or self.result_len == 0) return;
        const old_focus = self.focus;
        var visible = @min(rows, self.result_len);
        var max_scroll = self.result_len - visible;

        if (delta > 0) {
            const amount: usize = @intCast(delta);
            if (self.scroll +| amount > max_scroll and self.canGrowResults()) {
                self.growResults() catch {};
                visible = @min(rows, self.result_len);
                max_scroll = self.result_len - visible;
            }
            const target_scroll = @min(max_scroll, self.scroll +| amount);
            if (target_scroll == self.scroll) return;
            self.scroll = target_scroll;
            const scroll_off = effectiveScrollOff(visible, self.options.scroll_off);
            if (self.focus < self.scroll + scroll_off) {
                self.focus = @min(self.result_len - 1, self.focus +| amount);
            }
        } else {
            const amount: usize = @intCast(-delta);
            const target_scroll = self.scroll -| amount;
            if (target_scroll == self.scroll) return;
            self.scroll = target_scroll;
            const scroll_off = effectiveScrollOff(visible, self.options.scroll_off);
            const high_margin = self.scroll + visible - 1 - scroll_off;
            if (self.focus > high_margin) self.focus -|= amount;
        }

        if (self.focus != old_focus) {
            self.focus_event_pending = true;
            self.cancelOneShotTracking();
            self.preview_cache_key = null;
        }
    }

    fn offsetViewportMiddle(self: *Ui) void {
        if (self.result_len == 0) return;
        const rows = @max(@as(usize, 1), self.visibleListRows());
        const max_scroll = self.result_len -| @min(rows, self.result_len);
        const half = rows / 2;
        self.scroll = @min(max_scroll, self.focus -| half);
    }

    fn moveSelected(self: *Ui, direction: isize) void {
        if (self.result_len == 0 or self.selected_count == 0) return;
        var pos = self.focus;
        var scanned: usize = 0;
        while (scanned < self.result_len) : (scanned += 1) {
            if (direction < 0) {
                pos = if (pos == 0) self.result_len - 1 else pos - 1;
            } else {
                pos = if (pos + 1 == self.result_len) 0 else pos + 1;
            }
            if (!self.selected[self.results[pos]]) continue;
            if (pos != self.focus) {
                self.focus = pos;
                self.ensureVisible();
                self.preview_cache_key = null;
                self.focus_event_pending = true;
                self.cancelOneShotTracking();
            }
            return;
        }
    }

    fn previewContentRows(self: *Ui) usize {
        const preview = self.paneGeometry(self.terminal.size()).preview orelse return 1;
        var rows = preview.rows;
        if (self.options.preview.border_style != .none) {
            const sides = borderSides(self.options.preview.border_style);
            rows -|= @intFromBool(sides.top);
            rows -|= @intFromBool(sides.bottom);
        }
        return @max(@as(usize, 1), rows);
    }

    fn previewLineCount(self: *Ui) usize {
        if (self.preview_text.len == 0) return 0;
        var count: usize = 1;
        for (self.preview_text) |byte| if (byte == '\n') {
            count += 1;
        };
        return count;
    }

    fn previewMaxOffset(self: *Ui) usize {
        const count = self.previewLineCount();
        const rows = self.previewContentRows();
        return if (count > rows) count - rows else 0;
    }

    fn scrollPreview(self: *Ui, delta: isize) void {
        const max_offset = self.previewMaxOffset();
        if (delta < 0) {
            const amount: usize = @intCast(-delta);
            self.preview_offset -|= amount;
        } else {
            const amount: usize = @intCast(delta);
            self.preview_offset = @min(max_offset, self.preview_offset +| amount);
        }
    }

    fn ensureAllResults(self: *Ui) !void {
        if (self.result_cap >= self.candidates.display.len) return;
        self.result_cap = self.candidates.display.len;
        self.dirty_search = true;
        try self.refreshSearch(false);
    }

    fn compactSelectionOrder(self: *Ui) void {
        var write: usize = 0;
        for (self.selection_order.items) |idx| {
            if (idx >= self.selected.len or !self.selected[idx]) continue;
            self.selection_order.items[write] = idx;
            write += 1;
        }
        self.selection_order.shrinkRetainingCapacity(write);
    }

    fn selectIndex(self: *Ui, idx: usize) !bool {
        if (!self.options.multi or idx >= self.selected.len or self.selected[idx]) return false;
        if (self.options.multi_max) |max| if (self.selected_count >= max) return false;
        self.selected[idx] = true;
        try self.selection_order.append(self.allocator, idx);
        self.selected_count += 1;
        return true;
    }

    fn deselectIndex(self: *Ui, idx: usize) bool {
        if (!self.options.multi or idx >= self.selected.len or !self.selected[idx]) return false;
        self.selected[idx] = false;
        self.selected_count -= 1;
        if (std.mem.indexOfScalar(usize, self.selection_order.items, idx)) |pos| _ = self.selection_order.orderedRemove(pos);
        return true;
    }

    fn selectCurrent(self: *Ui) !void {
        if (self.result_len == 0) return;
        _ = try self.selectIndex(self.results[self.focus]);
    }

    fn deselectCurrent(self: *Ui) void {
        if (self.result_len == 0) return;
        _ = self.deselectIndex(self.results[self.focus]);
    }

    fn waitForSearch(self: *Ui) !void {
        while (true) {
            if (self.stream) |stream| {
                if (!stream.eof) {
                    const update = try stream.readAvailable();
                    if (update.changed) try self.refreshFromStream();
                    if (update.eof_became) {
                        self.load_event_pending = true;
                        self.result_final_event_pending = true;
                    }
                    if (self.dirty_search) try self.refreshSearch(false);
                    if (!stream.eof) {
                        self.io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
                        continue;
                    }
                }
            }
            if (self.dirty_search) try self.refreshSearch(false);
            return;
        }
    }

    fn toggleCurrent(self: *Ui) !bool {
        if (!self.options.multi or self.result_len == 0) return false;
        const idx = self.results[self.focus];
        if (self.selected[idx]) return self.deselectIndex(idx);
        return try self.selectIndex(idx);
    }

    fn toggleAll(self: *Ui) !void {
        if (!self.options.multi or self.result_len == 0) return;
        try self.ensureAllResults();
        const was_selected = try self.allocator.alloc(bool, self.result_len);
        defer self.allocator.free(was_selected);
        for (self.results[0..self.result_len], 0..) |idx, pos| {
            was_selected[pos] = self.selected[idx];
            if (!was_selected[pos]) continue;
            self.selected[idx] = false;
            self.selected_count -= 1;
        }
        self.compactSelectionOrder();
        for (self.results[0..self.result_len], 0..) |idx, pos| {
            if (was_selected[pos]) continue;
            if (!try self.selectIndex(idx)) break;
        }
    }

    fn excludeCandidates(self: *Ui, remove: []const bool) !void {
        if (remove.len != self.candidates.output.len) return;

        // Keep the live stream alive by removing the corresponding source records.
        // StreamInput has already applied --tail; --tac only changes the CandidateSet view.
        if (self.stream) |stream| {
            const active_len = stream.activeRecords().len;
            var positions: std.ArrayList(usize) = .empty;
            defer positions.deinit(self.allocator);
            for (remove, 0..) |flag, idx| {
                if (!flag or idx >= active_len) continue;
                const source_pos = if (self.options.tac) active_len - 1 - idx else idx;
                try positions.append(self.allocator, source_pos);
            }
            std.mem.sort(usize, positions.items, {}, comptime std.sort.desc(usize));
            for (positions.items) |source_pos| {
                const absolute = stream.head + source_pos;
                if (absolute >= stream.records.items.len) continue;
                const record = stream.records.orderedRemove(absolute);
                self.allocator.free(record);
            }
            try self.refreshFromStream();
            if (self.dirty_search) try self.refreshSearch(false);
            return;
        }

        const delim: u8 = if (self.options.read0) 0 else '\n';
        var len: usize = 0;
        for (self.candidates.header) |line| len += line.len + 1;
        for (self.candidates.output, 0..) |line, idx| {
            if (!remove[idx]) len += line.len + 1;
        }
        const blob = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(blob);
        var at: usize = 0;
        for (self.candidates.header) |line| {
            @memcpy(blob[at .. at + line.len], line);
            at += line.len;
            blob[at] = delim;
            at += 1;
        }
        for (self.candidates.output, 0..) |line, idx| {
            if (remove[idx]) continue;
            @memcpy(blob[at .. at + line.len], line);
            at += line.len;
            blob[at] = delim;
            at += 1;
        }

        // output[] is already in the current visible input order, so do not apply
        // --tac or --tail a second time when rebuilding the active revision.
        var parse_options = self.options.*;
        parse_options.tac = false;
        parse_options.tail = null;
        parse_options.header_lines = self.candidates.header.len;
        var new_candidates = try candidatesFromOwnedBlob(self.allocator, blob, &parse_options);
        errdefer new_candidates.deinit(self.allocator);
        var new_index = try fuzzy.init(self.allocator, new_candidates.search);
        errdefer new_index.deinit();
        try self.replaceCandidates(new_candidates, new_index, false);
        if (self.dirty_search) try self.refreshSearch(false);
    }

    fn excludeCurrent(self: *Ui) !void {
        if (self.result_len == 0) return;
        const idx = self.results[self.focus];
        var remove = try self.allocator.alloc(bool, self.candidates.output.len);
        defer self.allocator.free(remove);
        @memset(remove, false);
        remove[idx] = true;
        if (self.selected[idx]) {
            self.selected[idx] = false;
            self.selected_count -|= 1;
        }
        try self.excludeCandidates(remove);
    }

    fn excludeMulti(self: *Ui) !void {
        if (self.result_len == 0 and self.selected_count == 0) return;
        var remove = try self.allocator.alloc(bool, self.candidates.output.len);
        defer self.allocator.free(remove);
        @memset(remove, false);
        if (self.selected_count != 0) {
            for (self.selection_order.items) |idx| {
                if (idx < self.selected.len and self.selected[idx]) remove[idx] = true;
            }
            @memset(self.selected, false);
            self.selection_order.clearRetainingCapacity();
            self.selected_count = 0;
        } else if (self.result_len != 0) {
            remove[self.results[self.focus]] = true;
        }
        try self.excludeCandidates(remove);
    }

    fn deleteCharBackward(self: *Ui) !bool {
        if (self.cursor == 0) return false;
        const prev = prevUtf8Boundary(self.query.items, self.cursor);
        try self.query.replaceRange(self.allocator, prev, self.cursor - prev, &.{});
        self.cursor = prev;
        self.markQueryChanged();
        return true;
    }

    fn deleteCharForward(self: *Ui) !bool {
        if (self.cursor >= self.query.items.len) return false;
        const next = nextUtf8Boundary(self.query.items, self.cursor);
        try self.query.replaceRange(self.allocator, self.cursor, next - self.cursor, &.{});
        self.markQueryChanged();
        return true;
    }

    fn setYanked(self: *Ui, text: []const u8) !void {
        self.yanked.clearRetainingCapacity();
        try self.yanked.appendSlice(self.allocator, text);
    }

    fn queryWordBoundaryBackward(self: *Ui) usize {
        return if (self.options.filepath_word)
            filepathWordBoundaryBackward(self.query.items, self.cursor)
        else
            wordBoundaryBackward(self.query.items, self.cursor);
    }

    fn queryWordBoundaryForward(self: *Ui) usize {
        return if (self.options.filepath_word)
            filepathWordBoundaryForward(self.query.items, self.cursor)
        else
            wordBoundaryForward(self.query.items, self.cursor);
    }

    fn killWordBackward(self: *Ui) !bool {
        if (self.cursor == 0) return false;
        const begin = self.queryWordBoundaryBackward();
        if (begin == self.cursor) return false;
        try self.setYanked(self.query.items[begin..self.cursor]);
        try self.query.replaceRange(self.allocator, begin, self.cursor - begin, &.{});
        self.cursor = begin;
        self.markQueryChanged();
        return true;
    }

    fn unixWordRubout(self: *Ui) !bool {
        if (self.cursor == 0) return false;
        const begin = unixWordBoundaryBackward(self.query.items, self.cursor);
        if (begin == self.cursor) return false;
        try self.setYanked(self.query.items[begin..self.cursor]);
        try self.query.replaceRange(self.allocator, begin, self.cursor - begin, &.{});
        self.cursor = begin;
        self.markQueryChanged();
        return true;
    }

    fn killWordForward(self: *Ui) !bool {
        const end = self.queryWordBoundaryForward();
        if (end == self.cursor) return false;
        try self.setYanked(self.query.items[self.cursor..end]);
        try self.query.replaceRange(self.allocator, self.cursor, end - self.cursor, &.{});
        self.markQueryChanged();
        return true;
    }

    fn killSubwordBackward(self: *Ui) !bool {
        if (self.cursor == 0) return false;
        const begin = subwordBoundaryBackward(self.query.items, self.cursor);
        if (begin == self.cursor) return false;
        try self.setYanked(self.query.items[begin..self.cursor]);
        try self.query.replaceRange(self.allocator, begin, self.cursor - begin, &.{});
        self.cursor = begin;
        self.markQueryChanged();
        return true;
    }

    fn killSubwordForward(self: *Ui) !bool {
        const end = subwordBoundaryForward(self.query.items, self.cursor);
        if (end == self.cursor) return false;
        try self.setYanked(self.query.items[self.cursor..end]);
        try self.query.replaceRange(self.allocator, self.cursor, end - self.cursor, &.{});
        self.markQueryChanged();
        return true;
    }

    fn killLine(self: *Ui) !bool {
        if (self.cursor >= self.query.items.len) return false;
        try self.setYanked(self.query.items[self.cursor..]);
        self.query.shrinkRetainingCapacity(self.cursor);
        self.markQueryChanged();
        return true;
    }

    fn unixLineDiscard(self: *Ui) !bool {
        if (self.cursor == 0) return false;
        try self.setYanked(self.query.items[0..self.cursor]);
        try self.query.replaceRange(self.allocator, 0, self.cursor, &.{});
        self.cursor = 0;
        self.markQueryChanged();
        return true;
    }

    fn yankQuery(self: *Ui) !bool {
        if (self.yanked.items.len == 0) return false;
        try self.query.insertSlice(self.allocator, self.cursor, self.yanked.items);
        self.cursor += self.yanked.items.len;
        self.markQueryChanged();
        return true;
    }

    fn emitQueryOnly(self: *Ui) !void {
        const sep: []const u8 = if (self.options.print0) "\x00" else "\n";
        var stdout_buffer: [8192]u8 = undefined;
        var writer = Io.File.stdout().writerStreaming(self.io, &stdout_buffer);
        try writer.interface.writeAll(self.query.items);
        try writer.interface.writeAll(sep);
        try writer.flush();
    }

    fn emitSelection(self: *Ui, expect_key: ?[]const u8) !void {
        if (self.history) |*history| try history.save(self.query.items);
        const sep: []const u8 = if (self.options.print0) "\x00" else "\n";
        var stdout_buffer: [8192]u8 = undefined;
        var writer = Io.File.stdout().writerStreaming(self.io, &stdout_buffer);
        const w = &writer.interface;
        if (self.options.print_query) {
            try w.writeAll(self.query.items);
            try w.writeAll(sep);
        }
        if (self.options.expect.items.len != 0) {
            if (expect_key) |k| try w.writeAll(k);
            try w.writeAll(sep);
        }
        for (self.print_queue.items) |value| {
            try w.writeAll(value);
            try w.writeAll(sep);
        }
        if (self.selected_count != 0) {
            for (self.selection_order.items) |idx| {
                if (!self.selected[idx]) continue;
                try self.writeAccepted(w, idx);
                try w.writeAll(sep);
            }
        } else if (self.result_len != 0) {
            const idx = self.results[self.focus];
            try self.writeAccepted(w, idx);
            try w.writeAll(sep);
        }
        try writer.flush();
    }

    fn writeAccepted(self: *Ui, w: anytype, idx: usize) !void {
        if (self.options.accept_nth) |spec| {
            const transformed = try transformFields(self.allocator, self.candidates.output[idx], self.options.delimiter, spec, idx);
            defer self.allocator.free(transformed);
            try w.writeAll(transformed);
        } else {
            try w.writeAll(self.candidates.output[idx]);
        }
    }

    fn render(self: *Ui) !void {
        const size = self.terminal.size();
        const geom = self.paneGeometry(size);
        const content = self.contentPane(geom.main);
        const geometry_key = RenderGeometryKey{
            .rows = size.rows,
            .cols = size.cols,
            .main = geom.main,
            .content = content,
            .preview = geom.preview,
            .border = self.options.border,
            .border_style = self.options.border_style,
            .preview_border_style = self.options.preview.border_style,
        };
        const previous_geometry = self.last_render_geometry;
        const geometry_changed = if (previous_geometry) |old| !std.meta.eql(old, geometry_key) else false;
        if (geometry_changed) {
            if (self.terminal.inline_mode) {
                var cleanup: Io.Writer.Allocating = .init(self.allocator);
                defer cleanup.deinit();
                const old_rows = previous_geometry.?.rows;
                var clear_row: usize = 1;
                while (clear_row <= @max(old_rows, size.rows)) : (clear_row += 1) {
                    try cursorTo(&cleanup.writer, clear_row, 1, true);
                    try cleanup.writer.writeAll("\x1b[2K");
                }
                try self.terminal.write(cleanup.written());
            } else {
                try self.terminal.write("\x1b[H\x1b[2J");
            }
        }
        self.last_render_geometry = geometry_key;

        var frame: Io.Writer.Allocating = .init(self.allocator);
        defer frame.deinit();
        const w = &frame.writer;
        // Synchronized output keeps a multi-row redraw from becoming visible
        // half-written on terminals that implement DEC mode 2026. Unsupported
        // terminals simply ignore the private mode. Do not clear the whole
        // screen on every frame: each rendered row erases only its own pane
        // cells before overwriting them, avoiding a visible blank-frame flash.
        try w.writeAll("\x1b[?2026h");

        if (self.options.border) {
            try drawPaneBorder(w, geom.main, self.terminal.inline_mode, self.options.border_style, self.options.theme.border, self.options.theme.enabled, self.options.bold);
            if (self.options.border_label) |label| try drawBorderLabel(w, geom.main, self.terminal.inline_mode, self.options.border_style, label, self.options.border_label_pos, self.options.theme.border, self.options.theme.enabled, self.options.bold);
        }
        var row = content.row;
        if (self.options.layout == .reverse) {
            if (self.options.header_first) row = try self.renderHeaderBlock(w, row, content);
            if (!self.input_hidden) {
                try self.renderPrompt(w, row, content.col, content.cols);
                row += 1;
            }
            if (self.options.info_style == .default or self.options.info_style == .right) {
                try self.renderInfo(w, row, content.col, content.cols);
                row += 1;
            }
            if (!self.options.header_first) row = try self.renderHeaderBlock(w, row, content);
            row = try self.renderListCached(w, row, content, true, geometry_changed);
            if (self.options.footer) |f| try self.renderPlainLine(w, row, content.col, f, content.cols, self.options.theme.footer);
        } else {
            row = try self.renderListCached(w, row, content, false, geometry_changed);
            row = try self.renderHeaderBlock(w, row, content);
            if (self.options.info_style == .default or self.options.info_style == .right) {
                try self.renderInfo(w, row, content.col, content.cols);
                row += 1;
            }
            if (!self.input_hidden) {
                try self.renderPrompt(w, row, content.col, content.cols);
                row += 1;
            }
            if (self.options.footer) |f| try self.renderPlainLine(w, row, content.col, f, content.cols, self.options.theme.footer);
        }

        if (geom.preview) |preview| {
            try self.ensurePreview();
            try self.renderPreviewOverlay(&frame, size, geom, preview);
        }

        try w.writeAll("\x1b[?2026l");
        const rendered = frame.written();
        if (!geometry_changed and std.mem.eql(u8, rendered, self.last_frame)) return;
        const cached = try self.allocator.dupe(u8, rendered);
        if (self.last_frame.len != 0) self.allocator.free(self.last_frame);
        self.last_frame = cached;
        try self.terminal.write(rendered);
    }

    fn totalCandidateCount(self: *const Ui) usize {
        if (self.lazy_backend) |backend| return backend.store.count();
        return self.candidates.display.len;
    }

    fn reportedMatchCount(self: *const Ui) usize {
        if (self.lazy_backend != null) {
            const effective = resolveEffectiveSearch(self.query.items, self.options.disabled, self.owned_search_override);
            if (effective.disabled or effective.query.len == 0) return self.totalCandidateCount();
            return self.lazy_match_count;
        }
        return self.match_len;
    }

    fn statusText(self: *Ui) ![]u8 {
        if (self.lazy_backend != null) {
            const total = self.totalCandidateCount();
            const matches = self.reportedMatchCount();
            if (self.lazy_search_complete and self.lazy_input_finished) {
                if (self.options.multi) return try std.fmt.allocPrint(self.allocator, "{d}/{d} ({d})", .{ matches, total, self.selected_count });
                return try std.fmt.allocPrint(self.allocator, "{d}/{d}", .{ matches, total });
            }
            if (self.options.multi) return try std.fmt.allocPrint(self.allocator, "{d}/{d} [{d} scanned] ({d})", .{ matches, total, self.lazy_scanned_count, self.selected_count });
            return try std.fmt.allocPrint(self.allocator, "{d}/{d} [{d} scanned]", .{ matches, total, self.lazy_scanned_count });
        }
        if (self.match_len == self.result_cap and self.result_cap < self.candidates.display.len) {
            if (self.options.multi) return try std.fmt.allocPrint(self.allocator, "{d}+/{d} ({d})", .{ self.match_len, self.candidates.display.len, self.selected_count });
            return try std.fmt.allocPrint(self.allocator, "{d}+/{d}", .{ self.match_len, self.candidates.display.len });
        }
        if (self.options.multi) return try std.fmt.allocPrint(self.allocator, "{d}/{d} ({d})", .{ self.match_len, self.candidates.display.len, self.selected_count });
        return try std.fmt.allocPrint(self.allocator, "{d}/{d}", .{ self.match_len, self.candidates.display.len });
    }

    fn renderInfo(self: *Ui, w: anytype, row: usize, col: usize, cols: usize) !void {
        if (self.options.info_style == .hidden or self.options.info_style == .inline_left or self.options.info_style == .inline_right) return;
        const status = try self.statusText();
        defer self.allocator.free(status);
        try prepareRenderRow(w, row, col, cols, self.terminal.inline_mode);
        try writeRoleStyle(w, self.options.theme.info, self.options.theme.enabled, self.options.bold);
        if (self.options.info_style == .right) {
            const offset = if (cols > status.len) cols - status.len else 0;
            try cursorTo(w, row, col + offset, self.terminal.inline_mode);
            try writeTruncated(w, status, cols, false, "");
        } else {
            try cursorTo(w, row, col, self.terminal.inline_mode);
            const lead: usize = @min(@as(usize, 2), cols);
            if (lead != 0) try w.writeAll("  "[0..lead]);
            const available = cols - lead;
            try writeTruncated(w, status, available, false, "");
            if (self.options.separator) |sep| {
                if (sep.len != 0 and available > status.len + 1) {
                    try w.writeAll(" ");
                    var used = lead + status.len + 1;
                    while (used < cols) : (used += 1) try w.writeAll(sep);
                }
            }
        }
        try writeReset(w);
    }

    fn renderPrompt(self: *Ui, w: anytype, row: usize, col: usize, cols: usize) !void {
        try prepareRenderRow(w, row, col, cols, self.terminal.inline_mode);
        try writeRoleStyle(w, self.options.theme.prompt, self.options.theme.enabled, self.options.bold);
        try w.writeAll(self.options.prompt);
        try writeReset(w);
        try writeRoleStyle(w, self.options.theme.query, self.options.theme.enabled, self.options.bold);
        try w.writeAll(self.query.items[0..self.cursor]);
        if (self.cursor < self.query.items.len) {
            const next = nextUtf8Boundary(self.query.items, self.cursor);
            try w.writeAll("\x1b[7m");
            try w.writeAll(self.query.items[self.cursor..next]);
            try writeReset(w);
            try writeRoleStyle(w, self.options.theme.query, self.options.theme.enabled, self.options.bold);
            try w.writeAll(self.query.items[next..]);
        } else {
            try w.writeAll("\x1b[7m \x1b[27m");
            if (self.query.items.len == 0) {
                if (self.options.ghost) |ghost| {
                    try writeRoleStyle(w, self.options.theme.info, self.options.theme.enabled, self.options.bold);
                    const available = if (cols > self.options.prompt.len + 1) cols - self.options.prompt.len - 1 else 0;
                    try writeTruncated(w, ghost, available, false, "");
                }
            }
        }
        try writeReset(w);
        if (self.options.info_style == .inline_left or self.options.info_style == .inline_right) {
            const status = try self.statusText();
            defer self.allocator.free(status);
            const total_len = self.options.info_prefix.len + status.len;
            if (self.options.info_style == .inline_right and cols > total_len) {
                try cursorTo(w, row, col + cols - total_len, self.terminal.inline_mode);
            }
            try writeRoleStyle(w, self.options.theme.info, self.options.theme.enabled, self.options.bold);
            try w.writeAll(self.options.info_prefix);
            try w.writeAll(status);
            try writeReset(w);
        }
    }

    fn renderPlainLine(self: *Ui, w: anytype, row: usize, col: usize, text: []const u8, cols: usize, style: RoleStyle) !void {
        try prepareRenderRow(w, row, col, cols, self.terminal.inline_mode);
        try writeRoleStyle(w, style, self.options.theme.enabled, self.options.bold);
        try writeTruncated(w, text, cols, false, "");
        try writeReset(w);
    }

    fn renderListCached(self: *Ui, w: anytype, start_row: usize, content: Pane, top_down: bool, force: bool) !usize {
        if (self.lazy_backend == null) return self.renderList(w, start_row, content, top_down);
        var section: Io.Writer.Allocating = .init(self.allocator);
        defer section.deinit();
        const end_row = try self.renderList(&section.writer, start_row, content, top_down);
        const rendered = section.written();
        if (force or !std.mem.eql(u8, rendered, self.last_list_frame)) {
            try w.writeAll(rendered);
            const cached = try self.allocator.dupe(u8, rendered);
            if (self.last_list_frame.len != 0) self.allocator.free(self.last_list_frame);
            self.last_list_frame = cached;
        }
        return end_row;
    }

    fn renderList(self: *Ui, w: anytype, start_row: usize, content: Pane, top_down: bool) !usize {
        const rows = self.listRows(content.rows);
        var line: usize = 0;
        while (line < rows) : (line += 1) {
            const row = start_row + line;
            if (row >= content.row + content.rows) break;
            try prepareRenderRow(w, row, content.col, content.cols, self.terminal.inline_mode);
            const logical = if (top_down) self.scroll + line else self.scroll + (rows - 1 - line);
            if (logical >= self.result_len) continue;
            const idx = self.results[logical];
            const focused = logical == self.focus;
            const marked = self.options.multi and self.selected[idx];
            const dimmed = self.options.raw and !self.match_flags[idx];
            try writeRoleStyle(w, if (focused) self.options.theme.current else self.options.theme.normal, self.options.theme.enabled, self.options.bold);
            if (dimmed and self.options.theme.enabled) try w.writeAll("\x1b[2m");
            if (focused) try writeRoleStyleOverlay(w, self.options.theme.pointer, self.options.theme.enabled, self.options.bold);
            try w.writeAll(self.options.pointer);
            try writeRoleStyle(w, if (focused) self.options.theme.current else self.options.theme.normal, self.options.theme.enabled, self.options.bold);
            try w.writeAll(" ");
            if (self.options.multi) {
                if (marked) {
                    try writeRoleStyleOverlay(w, self.options.theme.marker, self.options.theme.enabled, self.options.bold);
                    try w.writeAll(self.options.marker);
                    try writeRoleStyle(w, if (focused) self.options.theme.current else self.options.theme.normal, self.options.theme.enabled, self.options.bold);
                } else try w.writeAll(" ");
                try w.writeAll(" ");
            }
            if (dimmed and self.options.theme.enabled) try w.writeAll("\x1b[2m");
            const prefix_cols: usize = if (self.options.multi) 4 else 2;
            try writeHighlighted(w, self.candidates.display[idx], if (dimmed) "" else self.query.items, content.cols -| prefix_cols, self.options.wrap, self.options.ansi, &self.options.theme, focused, self.options.bold);
            try writeReset(w);
        }
        return start_row + rows;
    }

    fn clearPreviewText(self: *Ui) void {
        if (self.preview_text.len != 0) self.allocator.free(self.preview_text);
        self.preview_text = &.{};
        self.preview_offset = 0;
    }

    fn cachePreviewForCurrent(self: *Ui) void {
        self.preview_cache_key = if (self.result_len == 0) null else self.results[self.focus];
        self.preview_cache_query_hash = std.hash.Wyhash.hash(0, self.query.items);
        self.preview_offset = 0;
    }

    fn previewTemplateRunnable(self: *Ui, command: []const u8) bool {
        const flags = previewTemplateFlags(command);
        return !flags.slot or flags.force_update or flags.asterisk or
            (flags.plus and self.selected_count != 0) or self.result_len != 0;
    }

    fn schedulePreviewTemplate(self: *Ui, command: []const u8) !void {
        if (!self.previewTemplateRunnable(command)) {
            self.preview_queue.cancel();
            self.preview_generation +%= 1;
            self.clearPreviewText();
            self.cachePreviewForCurrent();
            return;
        }
        self.preview_queue.cancel();
        self.preview_generation +%= 1;
        self.clearPreviewText();
        // Cache the request at launch time so idle render ticks do not spawn
        // duplicate previews while the process is still running.
        self.cachePreviewForCurrent();
        try self.launchBackgroundCommandOn(self.preview_queue, .preview_content, command, self.preview_generation, null);
    }

    fn runPreviewAction(self: *Ui, command: []const u8) !void {
        self.preview_forced = true;
        self.options.preview.hidden = false;
        if (command.len != 0) try self.schedulePreviewTemplate(command);
    }

    fn ensurePreview(self: *Ui) !void {
        const cmd_template = self.options.preview.command orelse return;
        if (self.result_len == 0) return;
        const idx = self.results[self.focus];
        const qhash = std.hash.Wyhash.hash(0, self.query.items);
        if (self.preview_cache_key == idx and self.preview_cache_query_hash == qhash) return;
        try self.schedulePreviewTemplate(cmd_template);
    }

    fn renderPreviewOverlay(self: *Ui, frame: *Io.Writer.Allocating, size: anytype, geom: PaneGeometry, preview: Pane) !void {
        _ = size;
        _ = geom;
        const w = &frame.writer;
        var content = preview;
        if (self.options.preview.border_style != .none) {
            try drawPaneBorder(w, preview, self.terminal.inline_mode, self.options.preview.border_style, self.options.theme.preview_border, self.options.theme.enabled, self.options.bold);
            if (self.options.preview.label) |label| try drawBorderLabel(w, preview, self.terminal.inline_mode, self.options.preview.border_style, label, self.options.preview.label_pos, self.options.theme.preview_border, self.options.theme.enabled, self.options.bold);
            const sides = borderSides(self.options.preview.border_style);
            content = insetPane(content, .{
                .top = .{ .value = @intFromBool(sides.top) },
                .right = .{ .value = @intFromBool(sides.right) },
                .bottom = .{ .value = @intFromBool(sides.bottom) },
                .left = .{ .value = @intFromBool(sides.left) },
            });
        }

        var lines = std.mem.splitScalar(u8, self.preview_text, '\n');
        var skipped: usize = 0;
        while (skipped < self.preview_offset and lines.next() != null) : (skipped += 1) {}
        var row: usize = 0;
        while (row < content.rows) : (row += 1) {
            try prepareRenderRow(w, content.row + row, content.col, content.cols, self.terminal.inline_mode);
            const line = lines.next() orelse continue;
            try writeTruncated(w, line, content.cols, self.options.preview.wrap, "");
        }
    }
};

fn eraseRenderCells(w: anytype, cols: usize) !void {
    if (cols == 0) return;
    // ECH erases in place without moving the cursor. Restricting the erase
    // to the pane width preserves borders and avoids full-screen flashes.
    try w.print("\x1b[{d}X", .{cols});
}

fn prepareRenderRow(w: anytype, row: usize, col: usize, cols: usize, inline_mode: bool) !void {
    try cursorTo(w, row, col, inline_mode);
    try eraseRenderCells(w, cols);
}

fn cursorTo(w: anytype, row: usize, col: usize, inline_mode: bool) !void {
    if (!inline_mode) {
        try w.print("\x1b[{d};{d}H", .{ row, col });
        return;
    }
    try w.writeAll("\x1b8");
    if (row > 1) try w.print("\x1b[{d}B", .{row - 1});
    try w.print("\x1b[{d}G", .{col});
}

const BorderGlyphs = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    h: []const u8,
    v: []const u8,
};

fn borderGlyphs(style: BorderStyle) BorderGlyphs {
    return switch (style) {
        .double => .{ .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .h = "═", .v = "║" },
        .bold => .{ .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛", .h = "━", .v = "┃" },
        .sharp, .horizontal, .vertical, .top, .bottom, .left, .right => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" },
        .dashed => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "┄", .v = "┆" },
        else => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .v = "│" },
    };
}

fn borderSides(style: BorderStyle) struct { top: bool, bottom: bool, left: bool, right: bool } {
    return switch (style) {
        .none => .{ .top = false, .bottom = false, .left = false, .right = false },
        .horizontal => .{ .top = true, .bottom = true, .left = false, .right = false },
        .vertical => .{ .top = false, .bottom = false, .left = true, .right = true },
        .top => .{ .top = true, .bottom = false, .left = false, .right = false },
        .bottom => .{ .top = false, .bottom = true, .left = false, .right = false },
        .left => .{ .top = false, .bottom = false, .left = true, .right = false },
        .right => .{ .top = false, .bottom = false, .left = false, .right = true },
        else => .{ .top = true, .bottom = true, .left = true, .right = true },
    };
}

fn drawPaneBorder(w: anytype, pane: Pane, inline_mode: bool, style: BorderStyle, role: RoleStyle, colors: bool, bold_enabled: bool) !void {
    if (style == .none or pane.rows < 2 or pane.cols < 2) return;
    const g = borderGlyphs(style);
    const sides = borderSides(style);
    try writeRoleStyle(w, role, colors, bold_enabled);
    if (sides.top) {
        try cursorTo(w, pane.row, pane.col, inline_mode);
        if (sides.left) try w.writeAll(g.tl);
        var i: usize = if (sides.left) 1 else 0;
        const end = pane.cols - @intFromBool(sides.right);
        while (i < end) : (i += 1) try w.writeAll(g.h);
        if (sides.right) try w.writeAll(g.tr);
    }
    var r: usize = if (sides.top) 1 else 0;
    const row_end = pane.rows - @intFromBool(sides.bottom);
    while (r < row_end) : (r += 1) {
        if (sides.left) {
            try cursorTo(w, pane.row + r, pane.col, inline_mode);
            try w.writeAll(g.v);
        }
        if (sides.right) {
            try cursorTo(w, pane.row + r, pane.col + pane.cols - 1, inline_mode);
            try w.writeAll(g.v);
        }
    }
    if (sides.bottom) {
        try cursorTo(w, pane.row + pane.rows - 1, pane.col, inline_mode);
        if (sides.left) try w.writeAll(g.bl);
        var i: usize = if (sides.left) 1 else 0;
        const end = pane.cols - @intFromBool(sides.right);
        while (i < end) : (i += 1) try w.writeAll(g.h);
        if (sides.right) try w.writeAll(g.br);
    }
    try writeReset(w);
}

fn drawBorderLabel(w: anytype, pane: Pane, inline_mode: bool, style: BorderStyle, label: []const u8, pos: LabelPosition, role: RoleStyle, colors: bool, bold_enabled: bool) !void {
    if (label.len == 0 or pane.cols < 3 or style == .none) return;
    const sides = borderSides(style);
    if (pos.bottom) {
        if (!sides.bottom) return;
    } else if (!sides.top) return;
    const max_len = pane.cols - 2;
    const shown = label[0..@min(label.len, max_len)];
    const inner_start = pane.col + 1;
    const inner_end = pane.col + pane.cols - 1;
    var col: usize = undefined;
    if (pos.column == 0) {
        col = pane.col + (pane.cols - shown.len) / 2;
    } else if (pos.column > 0) {
        col = pane.col + @as(usize, @intCast(pos.column));
    } else {
        const from_right: usize = @intCast(-@as(i32, pos.column));
        col = if (inner_end > shown.len + from_right) inner_end - shown.len - from_right else inner_start;
    }
    col = std.math.clamp(col, inner_start, @max(inner_start, inner_end - shown.len));
    const row = if (pos.bottom) pane.row + pane.rows - 1 else pane.row;
    try cursorTo(w, row, col, inline_mode);
    try writeRoleStyle(w, role, colors, bold_enabled);
    try w.writeAll(shown);
    try writeReset(w);
}

fn writeReset(w: anytype) !void {
    try w.writeAll("\x1b[0m");
}

fn writeColor(w: anytype, color: Color, background: bool) !void {
    switch (color) {
        .ansi => |n| {
            if (n < 8) {
                try w.print("\x1b[{d}m", .{(if (background) @as(u16, 40) else 30) + n});
            } else if (n < 16) {
                try w.print("\x1b[{d}m", .{(if (background) @as(u16, 100) else 90) + (n - 8)});
            } else {
                try w.print("\x1b[{d};5;{d}m", .{ if (background) @as(u8, 48) else 38, n });
            }
        },
        .rgb => |rgb| try w.print("\x1b[{d};2;{d};{d};{d}m", .{ if (background) @as(u8, 48) else 38, rgb.r, rgb.g, rgb.b }),
    }
}

fn writeRoleStyleOverlay(w: anytype, style: RoleStyle, colors: bool, bold_enabled: bool) !void {
    if (style.bold and bold_enabled) try w.writeAll("\x1b[1m");
    if (style.dim) try w.writeAll("\x1b[2m");
    if (style.italic) try w.writeAll("\x1b[3m");
    if (style.underline) try w.writeAll("\x1b[4m");
    if (style.reverse) try w.writeAll("\x1b[7m");
    if (style.strike) try w.writeAll("\x1b[9m");
    if (colors) {
        if (style.fg) |fg| try writeColor(w, fg, false);
        if (style.bg) |bg| try writeColor(w, bg, true);
    }
}

fn writeRoleStyle(w: anytype, style: RoleStyle, colors: bool, bold_enabled: bool) !void {
    try writeReset(w);
    try writeRoleStyleOverlay(w, style, colors, bold_enabled);
}

fn namedAnsiColor(name: []const u8) ?u8 {
    const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "bright-black", "bright-red", "bright-green", "bright-yellow", "bright-blue", "bright-magenta", "bright-cyan", "bright-white" };
    for (names, 0..) |candidate, i| if (std.ascii.eqlIgnoreCase(name, candidate)) return @intCast(i);
    return null;
}

fn parseColor(value: []const u8) !?Color {
    if (std.mem.eql(u8, value, "-1") or std.ascii.eqlIgnoreCase(value, "default")) return null;
    if (namedAnsiColor(value)) |ansi| return .{ .ansi = ansi };
    if (value.len == 7 and value[0] == '#') {
        return .{ .rgb = .{
            .r = try std.fmt.parseInt(u8, value[1..3], 16),
            .g = try std.fmt.parseInt(u8, value[3..5], 16),
            .b = try std.fmt.parseInt(u8, value[5..7], 16),
        } };
    }
    return .{ .ansi = try std.fmt.parseInt(u8, value, 10) };
}

fn applyAttribute(style: *RoleStyle, attr: []const u8) !void {
    if (attr.len == 0) return;
    if (std.ascii.eqlIgnoreCase(attr, "regular")) {
        style.bold = false;
        style.dim = false;
        style.italic = false;
        style.underline = false;
        style.reverse = false;
        style.strike = false;
    } else if (std.ascii.eqlIgnoreCase(attr, "bold")) style.bold = true else if (std.ascii.eqlIgnoreCase(attr, "dim")) style.dim = true else if (std.ascii.eqlIgnoreCase(attr, "italic")) style.italic = true else if (std.ascii.eqlIgnoreCase(attr, "underline")) style.underline = true else if (std.ascii.eqlIgnoreCase(attr, "reverse")) style.reverse = true else if (std.ascii.eqlIgnoreCase(attr, "strikethrough") or std.ascii.eqlIgnoreCase(attr, "strike")) style.strike = true else return error.InvalidColorAttribute;
}

fn themeRole(theme: *Theme, name: []const u8) ?*RoleStyle {
    if (std.mem.eql(u8, name, "fg") or std.mem.eql(u8, name, "bg")) return &theme.normal;
    if (std.mem.eql(u8, name, "fg+") or std.mem.eql(u8, name, "bg+")) return &theme.current;
    if (std.mem.eql(u8, name, "hl")) return &theme.highlight;
    if (std.mem.eql(u8, name, "hl+")) return &theme.highlight_current;
    if (std.mem.eql(u8, name, "info")) return &theme.info;
    if (std.mem.eql(u8, name, "border") or std.mem.eql(u8, name, "separator")) return &theme.border;
    if (std.mem.eql(u8, name, "preview-border")) return &theme.preview_border;
    if (std.mem.eql(u8, name, "prompt")) return &theme.prompt;
    if (std.mem.eql(u8, name, "pointer") or std.mem.eql(u8, name, "gutter")) return &theme.pointer;
    if (std.mem.eql(u8, name, "marker")) return &theme.marker;
    if (std.mem.eql(u8, name, "header")) return &theme.header;
    if (std.mem.eql(u8, name, "footer")) return &theme.footer;
    if (std.mem.eql(u8, name, "query")) return &theme.query;
    return null;
}

fn applyBaseTheme(theme: *Theme, name: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(name, "bw")) {
        theme.enabled = false;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "dark") or std.ascii.eqlIgnoreCase(name, "base16") or std.mem.eql(u8, name, "16")) {
        theme.* = .{};
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "light")) {
        theme.* = .{};
        theme.normal.fg = .{ .ansi = 0 };
        theme.normal.bg = .{ .ansi = 15 };
        theme.current.fg = .{ .ansi = 0 };
        theme.current.bg = .{ .ansi = 7 };
        theme.current.reverse = false;
        theme.highlight.fg = .{ .ansi = 4 };
        theme.highlight_current.fg = .{ .ansi = 4 };
        theme.border.fg = .{ .ansi = 8 };
        theme.preview_border.fg = .{ .ansi = 8 };
        theme.prompt.fg = .{ .ansi = 4 };
        theme.pointer.fg = .{ .ansi = 5 };
        theme.marker.fg = .{ .ansi = 1 };
        theme.header.fg = .{ .ansi = 2 };
        theme.footer.fg = .{ .ansi = 2 };
        return true;
    }
    return false;
}

fn parseColorSpec(theme: *Theme, spec: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, spec, ", \t\r\n");
    while (it.next()) |token| {
        if (try applyBaseTheme(theme, token)) continue;
        var fields = std.mem.splitScalar(u8, token, ':');
        const name = fields.next() orelse continue;
        const style = themeRole(theme, name) orelse return error.InvalidColorName;
        if (fields.next()) |color_text| {
            const color = try parseColor(color_text);
            if (std.mem.eql(u8, name, "bg") or std.mem.eql(u8, name, "bg+")) style.bg = color else style.fg = color;
            if ((std.mem.eql(u8, name, "fg+") or std.mem.eql(u8, name, "bg+")) and color != null) style.reverse = false;
        }
        while (fields.next()) |attr| try applyAttribute(style, attr);
        theme.enabled = true;
    }
}

fn parseBorderStyle(text: []const u8) !BorderStyle {
    inline for (@typeInfo(BorderStyle).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
    }
    if (std.ascii.eqlIgnoreCase(text, "line")) return .sharp;
    if (std.ascii.eqlIgnoreCase(text, "block") or std.ascii.eqlIgnoreCase(text, "thinblock")) return .bold;
    return error.InvalidBorderStyle;
}

fn parseSizeSpec(text: []const u8) !SizeSpec {
    if (text.len == 0) return error.InvalidSize;
    if (text[text.len - 1] == '%') {
        const value = try std.fmt.parseInt(u16, text[0 .. text.len - 1], 10);
        if (value > 100) return error.InvalidSize;
        return .{ .value = value, .percent = true };
    }
    return .{ .value = try std.fmt.parseInt(u16, text, 10) };
}

fn parseInsets(text: []const u8) !Insets {
    var values: [4]SizeSpec = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        if (count == values.len) return error.InvalidInsets;
        values[count] = try parseSizeSpec(std.mem.trim(u8, part, " \t"));
        count += 1;
    }
    if (count == 0) return error.InvalidInsets;
    return switch (count) {
        1 => .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] },
        2 => .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] },
        3 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] },
        4 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
        else => unreachable,
    };
}

fn parseLabelPosition(text: []const u8) !LabelPosition {
    var out: LabelPosition = .{};
    var it = std.mem.tokenizeAny(u8, text, ":,");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, "center")) out.column = 0 else if (std.ascii.eqlIgnoreCase(part, "bottom")) out.bottom = true else if (std.ascii.eqlIgnoreCase(part, "top")) out.bottom = false else out.column = try std.fmt.parseInt(i16, part, 10);
    }
    return out;
}

fn parseInfoOption(options: *Options, text: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(text, "default")) {
        options.info_style = .default;
        options.info_prefix = " < ";
        return;
    }
    if (std.ascii.eqlIgnoreCase(text, "right")) {
        options.info_style = .right;
        options.info_prefix = " < ";
        return;
    }
    if (std.ascii.eqlIgnoreCase(text, "hidden")) {
        options.info_style = .hidden;
        return;
    }
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const mode = if (colon) |at| text[0..at] else text;
    const prefix = if (colon) |at| text[at + 1 ..] else if (std.ascii.eqlIgnoreCase(mode, "inline")) " < " else "";
    if (std.ascii.eqlIgnoreCase(mode, "inline")) options.info_style = .inline_left else if (std.ascii.eqlIgnoreCase(mode, "inline-right")) options.info_style = .inline_right else return error.InvalidInfoStyle;
    options.info_prefix = prefix;
}

fn resolveSize(spec: SizeSpec, total: usize) usize {
    return if (spec.percent) total * spec.value / 100 else spec.value;
}

fn insetPane(pane: Pane, insets: Insets) Pane {
    if (pane.rows == 0 or pane.cols == 0) return pane;
    const top = @min(resolveSize(insets.top, pane.rows), pane.rows - 1);
    const bottom = @min(resolveSize(insets.bottom, pane.rows), pane.rows - top - 1);
    const left = @min(resolveSize(insets.left, pane.cols), pane.cols - 1);
    const right = @min(resolveSize(insets.right, pane.cols), pane.cols - left - 1);
    return .{
        .row = pane.row + top,
        .col = pane.col + left,
        .rows = pane.rows - top - bottom,
        .cols = pane.cols - left - right,
    };
}

fn applyStylePreset(options: *Options, text: []const u8) !void {
    var parts = std.mem.splitScalar(u8, text, ':');
    const preset = parts.next() orelse return error.InvalidStylePreset;
    if (std.ascii.eqlIgnoreCase(preset, "default")) {
        options.style_preset = .default;
        options.border = false;
        options.border_style = .none;
        options.preview.border_style = .rounded;
    } else if (std.ascii.eqlIgnoreCase(preset, "minimal")) {
        options.style_preset = .minimal;
        options.border = false;
        options.border_style = .none;
        options.preview.border_style = .none;
    } else if (std.ascii.eqlIgnoreCase(preset, "full")) {
        options.style_preset = .full;
        options.border = true;
        options.border_style = .rounded;
        options.preview.border_style = .rounded;
    } else return error.InvalidStylePreset;
    if (parts.next()) |border| {
        options.border_style = try parseBorderStyle(border);
        options.border = options.border_style != .none;
    }
    if (parts.next() != null) return error.InvalidStylePreset;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    var options: Options = .{};
    defer options.deinit(allocator);
    if (init.environ_map.get("NO_COLOR") != null) options.theme.enabled = false;
    var file_default_args: ?[][]const u8 = null;
    defer if (file_default_args) |parsed| freeShellArgs(allocator, parsed);
    if (init.environ_map.get("FZF_DEFAULT_OPTS_FILE")) |path| {
        if (path.len != 0) {
            const defaults_text = try readOptionsFile(allocator, init.io, path);
            defer allocator.free(defaults_text);
            file_default_args = try shellSplitArgs(allocator, defaults_text);
            try parseOptionsInto(allocator, init.io, &options, file_default_args.?, 0);
        }
    }
    var env_default_args: ?[][]const u8 = null;
    defer if (env_default_args) |parsed| freeShellArgs(allocator, parsed);
    if (init.environ_map.get("FZF_DEFAULT_OPTS")) |defaults_text| {
        env_default_args = try shellSplitArgs(allocator, defaults_text);
        try parseOptionsInto(allocator, init.io, &options, env_default_args.?, 0);
    }
    try parseOptionsInto(allocator, init.io, &options, args, 1);

    var fallback_temp_dir: ?[:0]u8 = null;
    defer if (fallback_temp_dir) |path| allocator.free(path);
    if (builtin.os.tag == .windows) {
        options.temp_dir = init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse "";
    } else {
        options.temp_dir = init.environ_map.get("TMPDIR") orelse "/tmp";
    }
    if (options.temp_dir.len == 0) {
        fallback_temp_dir = try std.process.currentPathAlloc(init.io, allocator);
        options.temp_dir = fallback_temp_dir.?;
    }

    if (hasArg(args, "--help") or hasArg(args, "-h")) {
        try Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }
    if (hasArg(args, "--version")) {
        try Io.File.stdout().writeStreamingAll(init.io, "zfuzz 0.3.0\n");
        return;
    }
    if (hasArg(args, "--bash")) {
        try Io.File.stdout().writeStreamingAll(init.io, @embedFile("shell/zfuzz.bash"));
        return;
    }
    if (hasArg(args, "--zsh")) {
        try Io.File.stdout().writeStreamingAll(init.io, @embedFile("shell/zfuzz.zsh"));
        return;
    }
    if (hasArg(args, "--fish")) {
        try Io.File.stdout().writeStreamingAll(init.io, @embedFile("shell/zfuzz.fish"));
        return;
    }

    var child_env = try init.environ_map.clone(allocator);
    defer child_env.deinit();
    var server: ?*listen.Server = null;
    if (options.listen_addr) |address| {
        server = try listen.Server.start(allocator, init.io, .{
            .address = address,
            .unsafe_remote_exec = options.listen_unsafe,
            .api_key = init.environ_map.get("FZF_API_KEY") orelse "",
            .validate_actions = validateActionSequence,
        });
        if (server.?.port != 0) {
            var port_buf: [16]u8 = undefined;
            const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{server.?.port});
            try child_env.put("FZF_PORT", port_text);
        }
    }
    defer if (server) |value| value.deinit();

    var terminal_opt: ?Terminal = if (options.filter == null)
        Terminal.open(init.io, options.mouse, options.height_percent) catch null
    else
        null;
    defer if (terminal_opt) |*terminal| terminal.close(init.io);

    const stdin_is_tty = Io.File.stdin().isTty(init.io) catch false;
    const use_lazy = terminal_opt != null and options.filter == null and lazyInteractiveEligible(&options);
    const live_stdin = !use_lazy and builtin.os.tag != .windows and terminal_opt != null and !stdin_is_tty and !options.sync;
    var stream_input: ?StreamInput = if (live_stdin)
        StreamInput.init(allocator, if (options.read0) 0 else '\n', options.tail, options.header_lines)
    else
        null;
    defer if (stream_input) |*stream| stream.deinit();

    var candidates = if (use_lazy) blk: {
        const blob = try allocator.alloc(u8, 0);
        break :blk try candidatesFromOwnedBlob(allocator, blob, &options);
    } else if (stream_input) |*stream| blk: {
        _ = try stream.readAvailable();
        const blob = try stream.materializeBlob();
        break :blk try candidatesFromOwnedBlob(allocator, blob, &options);
    } else try readCandidates(allocator, init.io, &options, init.environ_map.get("FZF_DEFAULT_COMMAND"), init.environ_map.get("COMSPEC"));
    defer candidates.deinit(allocator);

    var index = try fuzzy.init(allocator, candidates.search);
    defer index.deinit();

    if (options.filter) |filter| {
        try filterMode(allocator, init.io, &index, &candidates, &options, filter);
        return;
    }

    const terminal = if (terminal_opt) |*value| value else {
        // No controlling terminal: behave like --filter with the initial query.
        try filterMode(allocator, init.io, &index, &candidates, &options, options.query);
        return;
    };

    var lazy_backend: ?*LazyBackend = null;
    defer if (lazy_backend) |backend| backend.destroy();
    if (use_lazy) {
        const backend = try LazyBackend.create(allocator, init.io);
        errdefer backend.destroy();
        try backend.startSource(&options, stdin_is_tty, init.environ_map.get("FZF_DEFAULT_COMMAND"));
        lazy_backend = backend;
    }

    var ui = try Ui.init(allocator, init.io, &options, &candidates, &index, terminal, if (stream_input) |*stream| stream else null, server, &child_env, lazy_backend);
    defer ui.deinit();
    const code = try ui.run();
    if (code != 0) {
        if (server) |value| {
            value.deinit();
            server = null;
        }
        std.process.exit(code);
    }
}

fn freeShellArgs(allocator: Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn readOptionsFile(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
}

fn shellSplitArgs(allocator: Allocator, text: []const u8) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);
    var quote: u8 = 0;
    var escaped = false;
    var comment = false;
    var have = false;
    for (text) |c| {
        if (comment) {
            if (c == '\n') comment = false;
            continue;
        }
        if (escaped) {
            try token.append(allocator, c);
            escaped = false;
            have = true;
            continue;
        }
        if (c == '\\' and quote != '\'') {
            escaped = true;
            have = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0 else try token.append(allocator, c);
            have = true;
            continue;
        }
        if (c == '#' and token.items.len == 0) {
            comment = true;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            have = true;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (have) {
                try args.append(allocator, try allocator.dupe(u8, token.items));
                token.clearRetainingCapacity();
                have = false;
            }
            continue;
        }
        try token.append(allocator, c);
        have = true;
    }
    if (escaped) try token.append(allocator, '\\');
    if (quote != 0) return error.UnterminatedQuote;
    if (have) try args.append(allocator, try allocator.dupe(u8, token.items));
    return try args.toOwnedSlice(allocator);
}

fn validateListenAddress(address: []const u8) !void {
    if (std.mem.endsWith(u8, address, ".sock")) return;
    const colon = std.mem.indexOfScalar(u8, address, ':');
    const port_text = if (colon) |pos| blk: {
        if (std.mem.indexOfScalarPos(u8, address, pos + 1, ':') != null) return error.InvalidListenAddress;
        break :blk address[pos + 1 ..];
    } else address;
    if (port_text.len == 0) return error.InvalidListenAddress;
    _ = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidListenAddress;
}

fn firstLine(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, '\n') orelse value.len;
    return value[0..end];
}

fn parseOptions(allocator: Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    errdefer o.deinit(allocator);
    try parseOptionsInto(allocator, std.testing.io, &o, args, 1);
    return o;
}

fn walkerPathIsDir(io: Io, path: []const u8) bool {
    const dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn parseWalkerRoots(allocator: Allocator, io: Io, options: *Options, args: []const []const u8, index: *usize, inline_root: ?[]const u8) !void {
    const begin = index.* + 1;
    var end = begin;
    while (end < args.len and walkerPathIsDir(io, args[end])) : (end += 1) {}
    if (inline_root == null and end == begin) return error.NoDirectorySpecified;

    options.walker_roots.clearRetainingCapacity();
    if (inline_root) |root| try options.walker_roots.append(allocator, root);
    try options.walker_roots.appendSlice(allocator, args[begin..end]);
    if (end != begin) index.* = end - 1;
}

fn parseOptionsInto(allocator: Allocator, io: Io, o: *Options, args: []const []const u8, start_index: usize) !void {
    var i: usize = start_index;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "--version") or
            std.mem.eql(u8, a, "--bash") or std.mem.eql(u8, a, "--zsh") or std.mem.eql(u8, a, "--fish")) continue;
        if (std.mem.eql(u8, a, "--sync")) {
            o.*.sync = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-sync") or std.mem.eql(u8, a, "--async")) {
            o.*.sync = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--listen") or std.mem.eql(u8, a, "--listen-unsafe")) {
            const unsafe = std.mem.eql(u8, a, "--listen-unsafe");
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-") and !std.mem.startsWith(u8, args[i + 1], "+")) {
                i += 1;
                try validateListenAddress(args[i]);
                o.*.listen_addr = args[i];
            } else {
                o.*.listen_addr = "";
            }
            o.*.listen_unsafe = unsafe;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-listen") or std.mem.eql(u8, a, "--no-listen-unsafe")) {
            o.*.listen_addr = null;
            o.*.listen_unsafe = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--listen=")) {
            try validateListenAddress(a[9..]);
            o.*.listen_addr = a[9..];
            o.*.listen_unsafe = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--listen-unsafe=")) {
            try validateListenAddress(a[16..]);
            o.*.listen_addr = a[16..];
            o.*.listen_unsafe = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--walker=")) {
            o.*.walker = try parseWalkerOptions(a[9..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--walker")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.walker = try parseWalkerOptions(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--walker-root=")) {
            try parseWalkerRoots(allocator, io, o, args, &i, a[14..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--walker-root")) {
            try parseWalkerRoots(allocator, io, o, args, &i, null);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--walker-skip=")) {
            o.*.walker_skip = a[14..];
            continue;
        }
        if (std.mem.eql(u8, a, "--walker-skip")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.walker_skip = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--history=")) {
            o.*.history_file = a[10..];
            continue;
        }
        if (std.mem.eql(u8, a, "--history")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.history_file = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-history")) {
            o.*.history_file = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--history-size=")) {
            const value = try std.fmt.parseInt(usize, a[15..], 10);
            if (value == 0) return error.InvalidHistorySize;
            o.*.history_size = value;
            continue;
        }
        if (std.mem.eql(u8, a, "--history-size")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            const value = try std.fmt.parseInt(usize, args[i], 10);
            if (value == 0) return error.InvalidHistorySize;
            o.*.history_size = value;
            continue;
        }
        if (std.mem.eql(u8, a, "--track")) {
            o.*.track = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-track")) {
            o.*.track = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--id-nth=")) {
            o.*.id_nth = a[9..];
            continue;
        }
        if (std.mem.eql(u8, a, "--id-nth")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.id_nth = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-id-nth")) {
            o.*.id_nth = null;
            continue;
        }
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--multi")) {
            var mode: MultiMode = .{ .enabled = true, .max = null };
            if (i + 1 < args.len and args[i + 1].len > 0 and std.ascii.isDigit(args[i + 1][0])) {
                i += 1;
                mode = parseCliMultiMode(args[i]) orelse return error.InvalidMultiLimit;
            }
            o.*.multi = mode.enabled;
            o.*.multi_max = mode.max;
            continue;
        }
        if (std.mem.eql(u8, a, "+m") or std.mem.eql(u8, a, "--no-multi")) {
            o.*.multi = false;
            o.*.multi_max = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--multi=")) {
            const mode = parseCliMultiMode(a[8..]) orelse return error.InvalidMultiLimit;
            o.*.multi = mode.enabled;
            o.*.multi_max = mode.max;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
            const mode = parseCliMultiMode(a[2..]) orelse return error.InvalidMultiLimit;
            o.*.multi = mode.enabled;
            o.*.multi_max = mode.max;
            continue;
        }
        if (std.mem.eql(u8, a, "--read0")) {
            o.*.read0 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-read0")) {
            o.*.read0 = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--print0")) {
            o.*.print0 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-print0")) {
            o.*.print0 = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--ansi")) {
            o.*.ansi = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-ansi")) {
            o.*.ansi = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--cycle")) {
            o.*.cycle = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-cycle")) {
            o.*.cycle = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-input")) {
            o.*.no_input = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--filepath-word")) {
            o.*.filepath_word = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-filepath-word")) {
            o.*.filepath_word = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--scroll-off=")) {
            o.*.scroll_off = try std.fmt.parseInt(usize, a[13..], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--scroll-off")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.scroll_off = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--wrap")) {
            o.*.wrap = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-wrap")) {
            o.*.wrap = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--raw")) {
            o.*.raw = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-raw")) {
            o.*.raw = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--select-1") or std.mem.eql(u8, a, "-1")) {
            o.*.select_1 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "+1") or std.mem.eql(u8, a, "--no-select-1")) {
            o.*.select_1 = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--exit-0") or std.mem.eql(u8, a, "-0")) {
            o.*.exit_0 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "+0") or std.mem.eql(u8, a, "--no-exit-0")) {
            o.*.exit_0 = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--print-query")) {
            o.*.print_query = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-print-query")) {
            o.*.print_query = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-sort") or std.mem.eql(u8, a, "+s")) {
            o.*.no_sort = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--toggle-sort=")) {
            try setToggleSortBinding(allocator, o, a[14..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--toggle-sort")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try setToggleSortBinding(allocator, o, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--sort=")) {
            const value = try std.fmt.parseInt(isize, a[7..], 10);
            o.*.no_sort = value <= 0;
            continue;
        }
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--sort")) {
            var value: isize = 1;
            if (i + 1 < args.len and args[i + 1].len != 0 and std.ascii.isDigit(args[i + 1][0])) {
                i += 1;
                value = try std.fmt.parseInt(isize, args[i], 10);
            }
            o.*.no_sort = value <= 0;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-s") and a.len > 2) {
            o.*.no_sort = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--disabled") or std.mem.eql(u8, a, "--phony")) {
            o.*.disabled = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--enabled") or std.mem.eql(u8, a, "--no-phony")) {
            o.*.disabled = false;
            continue;
        }
        if (std.mem.eql(u8, a, "-x") or std.mem.eql(u8, a, "--extended")) {
            o.*.extended = true;
            continue;
        }
        if (std.mem.eql(u8, a, "+x") or std.mem.eql(u8, a, "--no-extended")) {
            o.*.extended = false;
            continue;
        }
        if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--exact")) {
            o.*.exact = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--extended-exact")) {
            o.*.exact = true;
            o.*.extended = true;
            continue;
        }
        if (std.mem.eql(u8, a, "+e") or std.mem.eql(u8, a, "--no-exact")) {
            o.*.exact = false;
            continue;
        }
        if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) {
            o.*.case_mode = .ignore;
            continue;
        }
        if (std.mem.eql(u8, a, "+i") or std.mem.eql(u8, a, "--no-ignore-case")) {
            o.*.case_mode = .respect;
            continue;
        }
        if (std.mem.eql(u8, a, "--smart-case")) {
            o.*.case_mode = .smart;
            continue;
        }
        if (std.mem.eql(u8, a, "--literal")) {
            o.*.literal = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-literal")) {
            o.*.literal = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--algo=")) {
            o.*.algorithm = try parseAlgorithm(a[7..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--algo")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.algorithm = try parseAlgorithm(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--scheme=")) {
            try applyScheme(o, a[9..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--scheme")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try applyScheme(o, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--tiebreak=")) {
            try parseTiebreaks(o, a[11..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--tiebreak")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try parseTiebreaks(o, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--tail=")) {
            const value = try std.fmt.parseInt(usize, a[7..], 10);
            if (value == 0) return error.InvalidTailCount;
            o.*.tail = value;
            continue;
        }
        if (std.mem.eql(u8, a, "--tail")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            const value = try std.fmt.parseInt(usize, args[i], 10);
            if (value == 0) return error.InvalidTailCount;
            o.*.tail = value;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-tail")) {
            o.*.tail = null;
            continue;
        }
        if (std.mem.eql(u8, a, "--tac")) {
            o.*.tac = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-tac")) {
            o.*.tac = false;
            continue;
        }
        if (std.mem.eql(u8, a, "+c") or std.mem.eql(u8, a, "--no-color")) {
            o.*.theme.enabled = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--color=")) {
            try parseColorSpec(&o.*.theme, a[8..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--color")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try parseColorSpec(&o.*.theme, args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-bold")) {
            o.*.bold = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--bold")) {
            o.*.bold = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--style=")) {
            try applyStylePreset(o, a[8..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--style")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try applyStylePreset(o, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--info=")) {
            try parseInfoOption(o, a[7..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--info")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try parseInfoOption(o, args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-info")) {
            o.*.info_style = .hidden;
            continue;
        }
        if (std.mem.eql(u8, a, "--inline-info")) {
            o.*.info_style = .inline_left;
            o.*.info_prefix = " < ";
            continue;
        }
        if (std.mem.eql(u8, a, "--no-inline-info")) {
            o.*.info_style = .default;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--separator=")) {
            o.*.separator = a[12..];
            continue;
        }
        if (std.mem.eql(u8, a, "--separator")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.separator = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-separator")) {
            o.*.separator = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--ghost=")) {
            o.*.ghost = a[8..];
            continue;
        }
        if (std.mem.eql(u8, a, "--ghost")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.ghost = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--margin=")) {
            o.*.margin = try parseInsets(a[9..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--margin")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.margin = try parseInsets(args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-margin")) {
            o.*.margin = .{};
            continue;
        }
        if (std.mem.startsWith(u8, a, "--padding=")) {
            o.*.padding = try parseInsets(a[10..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--padding")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.padding = try parseInsets(args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-padding")) {
            o.*.padding = .{};
            continue;
        }
        if (std.mem.eql(u8, a, "--no-mouse")) {
            o.*.mouse = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--border")) {
            o.*.border = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-") and !std.mem.startsWith(u8, args[i + 1], "+")) {
                i += 1;
                o.*.border_style = try parseBorderStyle(args[i]);
                o.*.border = o.*.border_style != .none;
            } else if (o.*.border_style == .none) {
                o.*.border_style = .rounded;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--border=")) {
            o.*.border_style = try parseBorderStyle(a[9..]);
            o.*.border = o.*.border_style != .none;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-border")) {
            o.*.border = false;
            o.*.border_style = .none;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--border-label=")) {
            o.*.border_label = a[15..];
            continue;
        }
        if (std.mem.eql(u8, a, "--border-label")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.border_label = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-border-label")) {
            o.*.border_label = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--border-label-pos=")) {
            o.*.border_label_pos = try parseLabelPosition(a[19..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--border-label-pos")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.border_label_pos = try parseLabelPosition(args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--reverse") or std.mem.eql(u8, a, "--layout=reverse")) {
            o.*.layout = .reverse;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-reverse")) {
            o.*.layout = .default;
            continue;
        }
        if (std.mem.eql(u8, a, "--layout=default")) {
            o.*.layout = .default;
            continue;
        }

        if (std.mem.startsWith(u8, a, "--query=")) {
            o.*.query = a[8..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "-q") and a.len > 2) {
            o.*.query = a[2..];
            continue;
        }
        if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--query")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.query = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--filter=")) {
            o.*.filter = a[9..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "-f") and a.len > 2) {
            o.*.filter = a[2..];
            continue;
        }
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.filter = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--prompt=")) {
            o.*.prompt = a[9..];
            continue;
        }
        if (std.mem.eql(u8, a, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.prompt = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--pointer=")) {
            o.*.pointer = firstLine(a[10..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--pointer")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.pointer = firstLine(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--marker=")) {
            o.*.marker = firstLine(a[9..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--marker")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.marker = firstLine(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--header=")) {
            o.*.header = a[9..];
            continue;
        }
        if (std.mem.eql(u8, a, "--header")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.header = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-header")) {
            o.*.header = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--header-lines=")) {
            o.*.header_lines = try std.fmt.parseInt(usize, a[15..], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--header-lines")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.header_lines = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-header-lines")) {
            o.*.header_lines = 0;
            continue;
        }
        if (std.mem.eql(u8, a, "--header-first")) {
            o.*.header_first = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-header-first")) {
            o.*.header_first = false;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--footer=")) {
            o.*.footer = a[9..];
            continue;
        }
        if (std.mem.eql(u8, a, "--footer")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.footer = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-footer")) {
            o.*.footer = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--height=")) {
            o.*.height_percent = parsePercent(a[9..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--height")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.height_percent = parsePercent(args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-height")) {
            o.*.height_percent = 100;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--preview=")) {
            o.*.preview.command = a[10..];
            continue;
        }
        if (std.mem.eql(u8, a, "--preview")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.preview.command = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-preview")) {
            o.*.preview.command = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--preview-window=")) {
            parsePreviewWindow(&o.*.preview, a[17..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--preview-window")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            parsePreviewWindow(&o.*.preview, args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--preview-border")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-") and !std.mem.startsWith(u8, args[i + 1], "+")) {
                i += 1;
                o.*.preview.border_style = try parseBorderStyle(args[i]);
            } else {
                o.*.preview.border_style = .rounded;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--preview-border=")) {
            o.*.preview.border_style = try parseBorderStyle(a[17..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-preview-border")) {
            o.*.preview.border_style = .none;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--preview-label=")) {
            o.*.preview.label = a[16..];
            continue;
        }
        if (std.mem.eql(u8, a, "--preview-label")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.preview.label = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--no-preview-label")) {
            o.*.preview.label = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--preview-label-pos=")) {
            o.*.preview.label_pos = try parseLabelPosition(a[20..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--preview-label-pos")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.preview.label_pos = try parseLabelPosition(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--delimiter=")) {
            o.*.delimiter = a[12..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "-d") and a.len > 2) {
            o.*.delimiter = a[2..];
            continue;
        }
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--delimiter")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.delimiter = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--nth=")) {
            o.*.nth = a[6..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "-n") and a.len > 2) {
            o.*.nth = a[2..];
            continue;
        }
        if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--nth")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.nth = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--with-nth=")) {
            o.*.with_nth = a[11..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--accept-nth=")) {
            o.*.accept_nth = a[13..];
            continue;
        }
        if (std.mem.eql(u8, a, "--with-nth")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.with_nth = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--accept-nth")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            o.*.accept_nth = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--expect=")) {
            try appendExpectedKeys(allocator, &o.*.expect, a[9..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--expect")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try appendExpectedKeys(allocator, &o.*.expect, args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--no-expect")) {
            o.*.expect.clearRetainingCapacity();
            continue;
        }
        if (std.mem.startsWith(u8, a, "--bind=")) {
            try parseBindings(allocator, &o.*.bindings, a[7..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--bind")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try parseBindings(allocator, &o.*.bindings, args[i]);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) continue;
        return error.UnknownOption;
    }
    return;
}

fn appendExpectedKeys(allocator: Allocator, out: *std.ArrayList([]const u8), spec: []const u8) !void {
    const masked = try allocator.dupe(u8, spec);
    defer allocator.free(masked);

    var i: usize = 0;
    while (i + 5 <= masked.len) {
        if (std.ascii.eqlIgnoreCase(masked[i .. i + 4], "alt-") and masked[i + 4] == ',') {
            masked[i + 4] = 1;
            i += 5;
        } else i += 1;
    }

    var start: usize = 0;
    i = 0;
    while (i <= masked.len) : (i += 1) {
        if (i != masked.len and masked[i] != ',') continue;
        if (i != start) try appendExpectedKey(allocator, out, spec[start..i]);
        start = i + 1;
    }

    const literal_comma = std.mem.eql(u8, masked, ",") or std.mem.startsWith(u8, masked, ",,") or
        std.mem.endsWith(u8, masked, ",,") or std.mem.indexOf(u8, masked, ",,,") != null;
    if (literal_comma) try appendExpectedKey(allocator, out, ",");
}

fn appendExpectedKey(allocator: Allocator, out: *std.ArrayList([]const u8), key: []const u8) !void {
    var i: usize = 0;
    while (i < out.items.len) {
        if (triggerNamesEquivalent(out.items[i], key)) {
            _ = out.orderedRemove(i);
        } else i += 1;
    }
    try out.append(allocator, key);
}

fn setToggleSortBinding(allocator: Allocator, options: *Options, key_spec: []const u8) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    try appendExpectedKeys(allocator, &keys, key_spec);
    if (keys.items.len == 0) return error.InvalidBinding;
    if (keys.items.len != 1) return error.MultipleKeysSpecified;
    try applyBindingSpec(allocator, &options.bindings, keys.items[0], "toggle-sort");
}

fn parseAlgorithm(spec: []const u8) !Algorithm {
    if (std.ascii.eqlIgnoreCase(spec, "v2")) return .v2;
    if (std.ascii.eqlIgnoreCase(spec, "v1")) return .v1;
    if (std.ascii.eqlIgnoreCase(spec, "heuristic")) return .heuristic;
    return error.InvalidAlgorithm;
}

fn parseScheme(spec: []const u8) !Scheme {
    if (std.ascii.eqlIgnoreCase(spec, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(spec, "path")) return .path;
    if (std.ascii.eqlIgnoreCase(spec, "history")) return .history;
    return error.InvalidScheme;
}

fn applyScheme(options: *Options, spec: []const u8) !void {
    options.scheme = try parseScheme(spec);
    switch (options.scheme) {
        .default => {
            options.tiebreaks[0] = .length;
            options.tiebreak_count = 1;
        },
        .path => {
            options.tiebreaks[0] = .pathname;
            options.tiebreaks[1] = .length;
            options.tiebreak_count = 2;
        },
        .history => options.tiebreak_count = 0,
    }
}

fn parseTiebreaks(options: *Options, spec: []const u8) !void {
    var seen_length = false;
    var seen_chunk = false;
    var seen_pathname = false;
    var seen_begin = false;
    var seen_end = false;
    var seen_index = false;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len == 0) return error.InvalidSortCriterion;
        if (seen_index) return error.IndexMustBeLastCriterion;
        if (std.ascii.eqlIgnoreCase(token, "index")) {
            if (seen_index) return error.DuplicateSortCriterion;
            seen_index = true;
            continue;
        }
        if (count == options.tiebreaks.len) return error.TooManySortCriteria;
        const kind: TieBreak = if (std.ascii.eqlIgnoreCase(token, "length")) blk: {
            if (seen_length) return error.DuplicateSortCriterion;
            seen_length = true;
            break :blk .length;
        } else if (std.ascii.eqlIgnoreCase(token, "chunk")) blk: {
            if (seen_chunk) return error.DuplicateSortCriterion;
            seen_chunk = true;
            break :blk .chunk;
        } else if (std.ascii.eqlIgnoreCase(token, "pathname")) blk: {
            if (seen_pathname) return error.DuplicateSortCriterion;
            seen_pathname = true;
            break :blk .pathname;
        } else if (std.ascii.eqlIgnoreCase(token, "begin")) blk: {
            if (seen_begin) return error.DuplicateSortCriterion;
            seen_begin = true;
            break :blk .begin;
        } else if (std.ascii.eqlIgnoreCase(token, "end")) blk: {
            if (seen_end) return error.DuplicateSortCriterion;
            seen_end = true;
            break :blk .end;
        } else return error.InvalidSortCriterion;
        options.tiebreaks[count] = kind;
        count += 1;
    }
    options.tiebreak_count = @intCast(count);
}

fn monotonicMilliseconds(io: Io) u64 {
    const ms = Io.Clock.awake.now(io).toMilliseconds();
    return if (ms <= 0) 0 else @intCast(ms);
}

fn everyIntervalMilliseconds(trigger: []const u8) ?u64 {
    if (!asciiStartsWithIgnoreCase(trigger, "every(") or trigger.len < 8 or trigger[trigger.len - 1] != ')') return null;
    const secs = std.fmt.parseFloat(f64, trigger[6 .. trigger.len - 1]) catch return null;
    if (!std.math.isFinite(secs) or secs <= 0) return null;
    const ms_f = secs * 1000.0;
    if (ms_f < 1.0 or ms_f >= 2147483648.0) return null;
    return @intFromFloat(ms_f);
}

fn asciiStartsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

const KeyNameIdentity = struct {
    kind: enum { literal, alt_literal, named },
    value: u16,
};

fn keyNameIdentity(name: []const u8) ?KeyNameIdentity {
    if (name.len == 1) return .{ .kind = .literal, .value = name[0] };
    if (std.ascii.eqlIgnoreCase(name, "space")) return .{ .kind = .literal, .value = ' ' };
    if (name.len == 5 and asciiStartsWithIgnoreCase(name, "alt-")) return .{ .kind = .alt_literal, .value = name[4] };
    if (std.ascii.eqlIgnoreCase(name, "alt-space")) return .{ .kind = .alt_literal, .value = ' ' };

    const named: u16 = if (std.ascii.eqlIgnoreCase(name, "up")) 1 else if (std.ascii.eqlIgnoreCase(name, "down")) 2 else if (std.ascii.eqlIgnoreCase(name, "left")) 3 else if (std.ascii.eqlIgnoreCase(name, "right")) 4 else if (std.ascii.eqlIgnoreCase(name, "home")) 5 else if (std.ascii.eqlIgnoreCase(name, "end")) 6 else if (std.ascii.eqlIgnoreCase(name, "page-up") or std.ascii.eqlIgnoreCase(name, "pgup")) 7 else if (std.ascii.eqlIgnoreCase(name, "page-down") or std.ascii.eqlIgnoreCase(name, "pgdn")) 8 else if (std.ascii.eqlIgnoreCase(name, "delete") or std.ascii.eqlIgnoreCase(name, "del")) 9 else if (std.ascii.eqlIgnoreCase(name, "shift-tab") or std.ascii.eqlIgnoreCase(name, "btab")) 10 else if (std.ascii.eqlIgnoreCase(name, "enter") or std.ascii.eqlIgnoreCase(name, "return") or std.ascii.eqlIgnoreCase(name, "ctrl-m")) 11 else if (std.ascii.eqlIgnoreCase(name, "tab") or std.ascii.eqlIgnoreCase(name, "ctrl-i")) 12 else if (std.ascii.eqlIgnoreCase(name, "esc")) 13 else if (std.ascii.eqlIgnoreCase(name, "backspace") or std.ascii.eqlIgnoreCase(name, "bspace") or std.ascii.eqlIgnoreCase(name, "bs")) 14 else if (std.ascii.eqlIgnoreCase(name, "ctrl-bs") or std.ascii.eqlIgnoreCase(name, "ctrl-bspace") or std.ascii.eqlIgnoreCase(name, "ctrl-backspace") or
        (builtin.os.tag != .windows and std.ascii.eqlIgnoreCase(name, "ctrl-h"))) 22 else if (std.ascii.eqlIgnoreCase(name, "ctrl-space")) 15 else if (std.ascii.eqlIgnoreCase(name, "ctrl-^") or std.ascii.eqlIgnoreCase(name, "ctrl-6")) 16 else if (std.ascii.eqlIgnoreCase(name, "ctrl-/") or std.ascii.eqlIgnoreCase(name, "ctrl-_")) 17 else if (std.ascii.eqlIgnoreCase(name, "ctrl-\\")) 18 else if (std.ascii.eqlIgnoreCase(name, "ctrl-]")) 19 else if (std.ascii.eqlIgnoreCase(name, "alt-enter") or std.ascii.eqlIgnoreCase(name, "alt-return")) 20 else if (std.ascii.eqlIgnoreCase(name, "alt-bs") or std.ascii.eqlIgnoreCase(name, "alt-bspace") or std.ascii.eqlIgnoreCase(name, "alt-backspace")) 21 else if (std.ascii.eqlIgnoreCase(name, "ctrl-alt-bs") or std.ascii.eqlIgnoreCase(name, "ctrl-alt-bspace") or std.ascii.eqlIgnoreCase(name, "ctrl-alt-backspace") or
        (builtin.os.tag != .windows and std.ascii.eqlIgnoreCase(name, "ctrl-alt-h"))) 23 else if (name.len == 10 and asciiStartsWithIgnoreCase(name, "ctrl-alt-") and std.ascii.isAlphabetic(name[9]))
    blk: {
        const letter = std.ascii.toLower(name[9]);
        if (letter == 'm') break :blk 20;
        if (builtin.os.tag != .windows and letter == 'h') break :blk 23;
        break :blk 200 + @as(u16, letter - 'a');
    } else if (name.len == 6 and asciiStartsWithIgnoreCase(name, "ctrl-") and std.ascii.isAlphabetic(name[5]))
        100 + @as(u16, std.ascii.toLower(name[5]) - 'a')
    else
        return null;
    return .{ .kind = .named, .value = named };
}

fn triggerNamesEquivalent(a: []const u8, b: []const u8) bool {
    const ai = keyNameIdentity(a);
    const bi = keyNameIdentity(b);
    if (ai != null or bi != null) {
        if (ai == null or bi == null) return false;
        return ai.?.kind == bi.?.kind and ai.?.value == bi.?.value;
    }
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isArgumentActionName(name: []const u8) bool {
    const exact = [_][]const u8{
        "become",       "execute",   "execute-multi",         "execute-silent", "reload",       "reload-sync", "preview",
        "bg-transform", "transform", "change-preview-window", "change-preview", "change-multi", "rebind",      "unbind",
        "toggle-bind",  "pos",       "put",                   "print",          "search",       "trigger",
    };
    for (exact) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;

    const suffixes = [_][]const u8{
        "query",        "prompt",       "border-label", "list-label", "preview-label", "input-label", "header-label",
        "footer-label", "header-lines", "header",       "footer",     "search",        "with-nth",    "nth",
        "pointer",      "ghost",
    };
    const prefixes = [_][]const u8{ "change-", "transform-", "bg-transform-" };
    for (prefixes) |prefix| {
        if (!asciiStartsWithIgnoreCase(name, prefix)) continue;
        const suffix = name[prefix.len..];
        for (suffixes) |candidate| if (std.ascii.eqlIgnoreCase(suffix, candidate)) return true;
    }
    return false;
}

fn actionDelimiterClose(open: u8) ?u8 {
    return switch (open) {
        '(' => ')',
        '{' => '}',
        '[' => ']',
        '<' => '>',
        '~', '!', '@', '#', '$', '%', '^', '&', '*', ';', '/', '|' => open,
        else => null,
    };
}

fn actionNameEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (!(std.ascii.isAlphabetic(c) or c == '-')) break;
    }
    return i;
}

fn replaceSameLength(bytes: []u8, needle: []const u8, replacement: []const u8) void {
    std.debug.assert(needle.len == replacement.len and needle.len != 0);
    var i: usize = 0;
    while (i + needle.len <= bytes.len) {
        if (std.mem.eql(u8, bytes[i .. i + needle.len], needle)) {
            @memcpy(bytes[i .. i + replacement.len], replacement);
            i += needle.len;
        } else i += 1;
    }
}

fn maskActionContents(allocator: Allocator, text: []const u8) ![]u8 {
    const masked = try allocator.dupe(u8, text);
    var search: usize = 0;
    while (search < text.len) {
        var found = false;
        var name_end: usize = 0;
        var i = search;
        while (i < text.len) : (i += 1) {
            if (text[i] != ':' and text[i] != '+') continue;
            const begin = i + 1;
            const end = actionNameEnd(text, begin);
            if (end == begin or !isArgumentActionName(text[begin..end])) continue;
            found = true;
            name_end = end;
            break;
        }
        if (!found) break;
        if (name_end >= text.len) break;

        const open = text[name_end];
        if (open == ':') {
            @memset(masked[name_end..], ' ');
            break;
        }
        const close = actionDelimiterClose(open) orelse {
            search = name_end;
            continue;
        };

        var close_index: ?usize = null;
        i = name_end + 1;
        while (i < text.len) : (i += 1) {
            if (text[i] != close) continue;
            if (i + 1 == text.len or text[i + 1] == '+' or text[i + 1] == ',') {
                close_index = i;
                break;
            }
        }
        const finish = close_index orelse break;
        @memset(masked[name_end .. finish + 1], ' ');
        search = finish + 1;
    }
    replaceSameLength(masked, ",,,", &.{ ',', 1, ',' });
    replaceSameLength(masked, ",:,", &.{ ',', 0, ',' });
    replaceSameLength(masked, "::", &.{ 0, ':' });
    replaceSameLength(masked, ",:", &.{ 1, ':' });
    replaceSameLength(masked, "+:", &.{ 2, ':' });
    return masked;
}

fn maskActionListContents(allocator: Allocator, text: []const u8) ![]u8 {
    const prefixed = try allocator.alloc(u8, text.len + 1);
    defer allocator.free(prefixed);
    prefixed[0] = ':';
    @memcpy(prefixed[1..], text);
    return maskActionContents(allocator, prefixed);
}

fn parseBindings(allocator: Allocator, out: *std.ArrayList(Binding), spec: []const u8) !void {
    const masked = try maskActionContents(allocator, spec);
    defer allocator.free(masked);
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) : (i += 1) {
        const at_end = i == spec.len;
        if (!at_end and masked[i] != ',') continue;
        const raw_part = spec[start..i];
        const masked_part_raw = masked[start..i];
        start = i + 1;
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) return error.InvalidBinding;
        const leading = @intFromPtr(part.ptr) - @intFromPtr(raw_part.ptr);
        const masked_part = masked_part_raw[leading .. leading + part.len];
        const colon = std.mem.indexOfScalar(u8, masked_part, ':');
        if (colon == null) {
            if (asciiStartsWithIgnoreCase(part, "every(") and everyIntervalMilliseconds(part) == null) return error.InvalidEveryEvent;
            try pending.append(allocator, part);
            continue;
        }

        const trigger = std.mem.trim(u8, part[0..colon.?], " \t");
        if (trigger.len == 0) return error.InvalidBinding;
        if (asciiStartsWithIgnoreCase(trigger, "every(") and everyIntervalMilliseconds(trigger) == null) return error.InvalidEveryEvent;
        const action_text = std.mem.trim(u8, part[colon.? + 1 ..], " \t");
        for (pending.items) |pending_trigger| try applyBindingSpec(allocator, out, pending_trigger, action_text);
        try applyBindingSpec(allocator, out, trigger, action_text);
        pending.clearRetainingCapacity();
    }
    if (pending.items.len != 0) return error.InvalidBinding;
}

fn applyBindingSpec(allocator: Allocator, out: *std.ArrayList(Binding), trigger: []const u8, action_text: []const u8) !void {
    if (action_text.len != 0 and action_text[0] != '+') removeBindingsForTrigger(out, trigger);
    try appendBindingActions(allocator, out, trigger, action_text);
}

fn removeBindingsForTrigger(out: *std.ArrayList(Binding), trigger: []const u8) void {
    var i: usize = 0;
    while (i < out.items.len) {
        if (triggerNamesEquivalent(out.items[i].trigger, trigger)) {
            _ = out.orderedRemove(i);
        } else i += 1;
    }
}

fn appendBindingActions(allocator: Allocator, out: *std.ArrayList(Binding), trigger: []const u8, text: []const u8) !void {
    const masked = try maskActionListContents(allocator, text);
    defer allocator.free(masked);
    const action_mask = masked[1..];

    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        if (!at_end and action_mask[i] != '+') continue;
        const action_text = std.mem.trim(u8, text[start..i], " \t");
        start = i + 1;
        if (action_text.len == 0) continue;
        try out.append(allocator, .{ .trigger = trigger, .name = actionName(action_text), .action = try parseAction(action_text) });
    }
}

fn actionName(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c != ':' and actionDelimiterClose(c) == null) continue;
        const candidate = std.mem.trim(u8, trimmed[0..i], " \t");
        if (isArgumentActionName(candidate)) return candidate;
    }
    return trimmed;
}

fn validateActionSequence(text: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const masked = maskActionListContents(allocator, text) catch return false;
    defer allocator.free(masked);
    const action_mask = masked[1..];

    var start: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        if (!at_end and action_mask[i] != '+') continue;
        const action_text = std.mem.trim(u8, text[start..i], " \t");
        start = i + 1;
        if (action_text.len == 0) continue;
        _ = parseAction(action_text) catch return false;
        count += 1;
    }
    return count != 0;
}

fn parseAction(s: []const u8) !Action {
    if (std.ascii.eqlIgnoreCase(s, "ignore")) return .ignore;
    if (std.ascii.eqlIgnoreCase(s, "up")) return .up;
    if (std.ascii.eqlIgnoreCase(s, "down")) return .down;
    if (std.ascii.eqlIgnoreCase(s, "page-up")) return .page_up;
    if (std.ascii.eqlIgnoreCase(s, "page-down")) return .page_down;
    if (std.ascii.eqlIgnoreCase(s, "half-page-up")) return .half_page_up;
    if (std.ascii.eqlIgnoreCase(s, "half-page-down")) return .half_page_down;
    if (std.ascii.eqlIgnoreCase(s, "offset-up")) return .offset_up;
    if (std.ascii.eqlIgnoreCase(s, "offset-down")) return .offset_down;
    if (std.ascii.eqlIgnoreCase(s, "offset-middle")) return .offset_middle;
    if (std.ascii.eqlIgnoreCase(s, "beginning-of-line")) return .beginning_of_line;
    if (std.ascii.eqlIgnoreCase(s, "end-of-line")) return .end_of_line;
    if (std.ascii.eqlIgnoreCase(s, "backward-char")) return .backward_char;
    if (std.ascii.eqlIgnoreCase(s, "forward-char")) return .forward_char;
    if (std.ascii.eqlIgnoreCase(s, "backward-delete-char")) return .backward_delete_char;
    if (std.ascii.eqlIgnoreCase(s, "backward-delete-char/eof")) return .backward_delete_char_eof;
    if (std.ascii.eqlIgnoreCase(s, "delete-char")) return .delete_char;
    if (std.ascii.eqlIgnoreCase(s, "delete-char/eof")) return .delete_char_eof;
    if (std.ascii.eqlIgnoreCase(s, "backward-word")) return .backward_word;
    if (std.ascii.eqlIgnoreCase(s, "forward-word")) return .forward_word;
    if (std.ascii.eqlIgnoreCase(s, "backward-subword")) return .backward_subword;
    if (std.ascii.eqlIgnoreCase(s, "forward-subword")) return .forward_subword;
    if (std.ascii.eqlIgnoreCase(s, "backward-kill-word")) return .backward_kill_word;
    if (std.ascii.eqlIgnoreCase(s, "kill-word")) return .kill_word;
    if (std.ascii.eqlIgnoreCase(s, "backward-kill-subword")) return .backward_kill_subword;
    if (std.ascii.eqlIgnoreCase(s, "kill-subword")) return .kill_subword;
    if (std.ascii.eqlIgnoreCase(s, "kill-line")) return .kill_line;
    if (std.ascii.eqlIgnoreCase(s, "unix-line-discard") or std.ascii.eqlIgnoreCase(s, "line-discard")) return .unix_line_discard;
    if (std.ascii.eqlIgnoreCase(s, "unix-word-rubout") or std.ascii.eqlIgnoreCase(s, "word-rubout")) return .unix_word_rubout;
    if (std.ascii.eqlIgnoreCase(s, "yank")) return .yank;
    if (std.ascii.eqlIgnoreCase(s, "cancel")) return .cancel;
    if (std.ascii.eqlIgnoreCase(s, "print-query")) return .print_query;
    if (std.ascii.eqlIgnoreCase(s, "accept-non-empty")) return .accept_non_empty;
    if (std.ascii.eqlIgnoreCase(s, "accept-or-print-query")) return .accept_or_print_query;
    if (std.ascii.eqlIgnoreCase(s, "replace-query")) return .replace_query;
    if (commandAction(s, "put")) |value| return .{ .put = value };
    if (std.ascii.eqlIgnoreCase(s, "first") or std.ascii.eqlIgnoreCase(s, "top")) return .first;
    if (std.ascii.eqlIgnoreCase(s, "last")) return .last;
    if (commandAction(s, "pos")) |value| return .{ .position = value };
    if (std.ascii.eqlIgnoreCase(s, "toggle")) return .toggle;
    if (std.ascii.eqlIgnoreCase(s, "select")) return .select;
    if (std.ascii.eqlIgnoreCase(s, "deselect")) return .deselect;
    if (std.ascii.eqlIgnoreCase(s, "toggle-up")) return .toggle_up;
    if (std.ascii.eqlIgnoreCase(s, "toggle-down")) return .toggle_down;
    if (std.ascii.eqlIgnoreCase(s, "toggle-in")) return .toggle_in;
    if (std.ascii.eqlIgnoreCase(s, "toggle-out")) return .toggle_out;
    if (std.ascii.eqlIgnoreCase(s, "toggle-all")) return .toggle_all;
    if (std.ascii.eqlIgnoreCase(s, "select-all")) return .select_all;
    if (std.ascii.eqlIgnoreCase(s, "deselect-all")) return .deselect_all;
    if (std.ascii.eqlIgnoreCase(s, "clear-selection") or std.ascii.eqlIgnoreCase(s, "clear-multi")) return .deselect_all;
    if (std.ascii.eqlIgnoreCase(s, "clear-query")) return .clear_query;
    if (std.ascii.eqlIgnoreCase(s, "clear-screen")) return .clear_screen;
    if (std.ascii.eqlIgnoreCase(s, "close")) return .close;
    if (std.ascii.eqlIgnoreCase(s, "bell")) return .bell;
    if (std.ascii.eqlIgnoreCase(s, "accept")) return .accept;
    if (std.ascii.eqlIgnoreCase(s, "abort")) return .abort;
    if (std.ascii.eqlIgnoreCase(s, "toggle-preview")) return .toggle_preview;
    if (std.ascii.eqlIgnoreCase(s, "show-preview")) return .show_preview;
    if (std.ascii.eqlIgnoreCase(s, "hide-preview")) return .hide_preview;
    if (std.ascii.eqlIgnoreCase(s, "refresh-preview")) return .refresh_preview;
    if (std.ascii.eqlIgnoreCase(s, "toggle-preview-wrap")) return .toggle_preview_wrap;
    if (std.ascii.eqlIgnoreCase(s, "toggle-wrap")) return .toggle_wrap;
    if (std.ascii.eqlIgnoreCase(s, "toggle-raw")) return .toggle_raw;
    if (std.ascii.eqlIgnoreCase(s, "enable-raw")) return .enable_raw;
    if (std.ascii.eqlIgnoreCase(s, "disable-raw")) return .disable_raw;
    if (std.ascii.eqlIgnoreCase(s, "down-match")) return .down_match;
    if (std.ascii.eqlIgnoreCase(s, "up-match")) return .up_match;
    if (std.ascii.eqlIgnoreCase(s, "best")) return .best;
    if (std.ascii.eqlIgnoreCase(s, "exclude")) return .exclude;
    if (std.ascii.eqlIgnoreCase(s, "exclude-multi")) return .exclude_multi;
    if (std.ascii.eqlIgnoreCase(s, "toggle-input")) return .toggle_input;
    if (std.ascii.eqlIgnoreCase(s, "show-input")) return .show_input;
    if (std.ascii.eqlIgnoreCase(s, "hide-input")) return .hide_input;
    if (std.ascii.eqlIgnoreCase(s, "toggle-header")) return .toggle_header;
    if (std.ascii.eqlIgnoreCase(s, "show-header")) return .show_header;
    if (std.ascii.eqlIgnoreCase(s, "hide-header")) return .hide_header;
    if (std.ascii.eqlIgnoreCase(s, "wait")) return .wait;
    if (std.ascii.eqlIgnoreCase(s, "preview-top")) return .preview_top;
    if (std.ascii.eqlIgnoreCase(s, "preview-bottom")) return .preview_bottom;
    if (std.ascii.eqlIgnoreCase(s, "preview-up")) return .preview_up;
    if (std.ascii.eqlIgnoreCase(s, "preview-down")) return .preview_down;
    if (std.ascii.eqlIgnoreCase(s, "preview-page-up")) return .preview_page_up;
    if (std.ascii.eqlIgnoreCase(s, "preview-page-down")) return .preview_page_down;
    if (std.ascii.eqlIgnoreCase(s, "preview-half-page-up")) return .preview_half_page_up;
    if (std.ascii.eqlIgnoreCase(s, "preview-half-page-down")) return .preview_half_page_down;
    if (std.ascii.eqlIgnoreCase(s, "up-selected") or std.ascii.eqlIgnoreCase(s, "prev-selected")) return .prev_selected;
    if (std.ascii.eqlIgnoreCase(s, "down-selected") or std.ascii.eqlIgnoreCase(s, "next-selected")) return .next_selected;
    if (std.ascii.eqlIgnoreCase(s, "toggle-sort")) return .toggle_sort;
    if (std.ascii.eqlIgnoreCase(s, "enable-search")) return .enable_search;
    if (std.ascii.eqlIgnoreCase(s, "disable-search")) return .disable_search;
    if (std.ascii.eqlIgnoreCase(s, "toggle-search")) return .toggle_search;
    if (std.ascii.eqlIgnoreCase(s, "toggle-track")) return .toggle_track;
    if (std.ascii.eqlIgnoreCase(s, "track") or std.ascii.eqlIgnoreCase(s, "track-current")) return .track_current;
    if (std.ascii.eqlIgnoreCase(s, "untrack-current")) return .untrack_current;
    if (std.ascii.eqlIgnoreCase(s, "toggle-track-current")) return .toggle_track_current;
    if (std.ascii.eqlIgnoreCase(s, "prev-history") or std.ascii.eqlIgnoreCase(s, "previous-history")) return .prev_history;
    if (std.ascii.eqlIgnoreCase(s, "next-history")) return .next_history;
    if (commandAction(s, "change-query")) |value| return .{ .change_query = value };
    if (commandAction(s, "search")) |value| return .{ .search = value };
    if (commandAction(s, "change-nth")) |value| return .{ .change_nth = value };
    if (commandAction(s, "change-with-nth")) |value| return .{ .change_with_nth = value };
    if (std.ascii.eqlIgnoreCase(s, "change-multi")) return .{ .change_multi = "" };
    if (commandAction(s, "change-multi")) |value| return .{ .change_multi = value };
    if (commandAction(s, "change-prompt")) |value| return .{ .change_prompt = value };
    if (commandAction(s, "change-ghost")) |value| return .{ .change_ghost = value };
    if (commandAction(s, "change-pointer")) |value| return .{ .change_pointer = value };
    if (commandAction(s, "change-border-label")) |value| return .{ .change_border_label = value };
    if (commandAction(s, "change-preview-label")) |value| return .{ .change_preview_label = value };
    if (commandAction(s, "change-header")) |value| return .{ .change_header = value };
    if (commandAction(s, "change-footer")) |value| return .{ .change_footer = value };
    if (commandAction(s, "change-preview")) |value| return .{ .change_preview = value };
    if (commandAction(s, "preview")) |cmd| return .{ .preview = cmd };
    if (commandAction(s, "transform-query")) |cmd| return .{ .transform_query = cmd };
    if (commandAction(s, "transform-search")) |cmd| return .{ .transform_search = cmd };
    if (commandAction(s, "transform-nth")) |cmd| return .{ .transform_nth = cmd };
    if (commandAction(s, "transform-with-nth")) |cmd| return .{ .transform_with_nth = cmd };
    if (commandAction(s, "transform-prompt")) |cmd| return .{ .transform_prompt = cmd };
    if (commandAction(s, "transform-ghost")) |cmd| return .{ .transform_ghost = cmd };
    if (commandAction(s, "transform-pointer")) |cmd| return .{ .transform_pointer = cmd };
    if (commandAction(s, "transform-border-label")) |cmd| return .{ .transform_border_label = cmd };
    if (commandAction(s, "transform-preview-label")) |cmd| return .{ .transform_preview_label = cmd };
    if (commandAction(s, "transform-header")) |cmd| return .{ .transform_header = cmd };
    if (commandAction(s, "transform-footer")) |cmd| return .{ .transform_footer = cmd };
    if (commandAction(s, "transform-preview")) |cmd| return .{ .transform_preview = cmd };
    if (commandAction(s, "bg-transform-query")) |cmd| return .{ .bg_transform_query = cmd };
    if (commandAction(s, "bg-transform-search")) |cmd| return .{ .bg_transform_search = cmd };
    if (commandAction(s, "bg-transform-nth")) |cmd| return .{ .bg_transform_nth = cmd };
    if (commandAction(s, "bg-transform-with-nth")) |cmd| return .{ .bg_transform_with_nth = cmd };
    if (commandAction(s, "bg-transform-prompt")) |cmd| return .{ .bg_transform_prompt = cmd };
    if (commandAction(s, "bg-transform-ghost")) |cmd| return .{ .bg_transform_ghost = cmd };
    if (commandAction(s, "bg-transform-pointer")) |cmd| return .{ .bg_transform_pointer = cmd };
    if (commandAction(s, "bg-transform-border-label")) |cmd| return .{ .bg_transform_border_label = cmd };
    if (commandAction(s, "bg-transform-preview-label")) |cmd| return .{ .bg_transform_preview_label = cmd };
    if (commandAction(s, "bg-transform-header")) |cmd| return .{ .bg_transform_header = cmd };
    if (commandAction(s, "bg-transform-footer")) |cmd| return .{ .bg_transform_footer = cmd };
    if (commandAction(s, "bg-transform-preview")) |cmd| return .{ .bg_transform_preview = cmd };
    if (commandAction(s, "bg-transform")) |cmd| return .{ .bg_transform = cmd };
    if (std.ascii.eqlIgnoreCase(s, "bg-cancel")) return .bg_cancel;
    if (commandAction(s, "transform")) |cmd| return .{ .transform = cmd };
    if (commandAction(s, "print")) |value| return .{ .print = value };
    if (commandAction(s, "reload-sync")) |cmd| return .{ .reload_sync = cmd };
    if (commandAction(s, "reload")) |cmd| return .{ .reload = cmd };
    if (commandAction(s, "execute-multi")) |cmd| return .{ .execute_multi = cmd };
    if (commandAction(s, "execute-silent")) |cmd| return .{ .execute_silent = cmd };
    if (commandAction(s, "execute")) |cmd| return .{ .execute = cmd };
    if (commandAction(s, "become")) |cmd| return .{ .become = cmd };
    if (commandAction(s, "unbind")) |targets| return .{ .unbind = targets };
    if (commandAction(s, "rebind")) |targets| return .{ .rebind = targets };
    if (commandAction(s, "toggle-bind")) |targets| return .{ .toggle_bind = targets };
    return error.UnsupportedBindingAction;
}

fn commandAction(s: []const u8, name: []const u8) ?[]const u8 {
    if (!asciiStartsWithIgnoreCase(s, name)) return null;
    const rest = s[name.len..];
    if (rest.len >= 1 and rest[0] == ':') return rest[1..];
    if (rest.len < 2) return null;
    const close = actionDelimiterClose(rest[0]) orelse return null;
    if (rest[rest.len - 1] != close) return null;
    return rest[1 .. rest.len - 1];
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

fn parsePercent(s: []const u8) u8 {
    const trimmed = if (s.len != 0 and s[s.len - 1] == '%') s[0 .. s.len - 1] else s;
    return std.math.clamp(std.fmt.parseInt(u8, trimmed, 10) catch 100, 10, 100);
}

fn parsePreviewWindow(p: *PreviewOptions, spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "right")) p.position = .right else if (std.mem.eql(u8, part, "left")) p.position = .left else if (std.mem.eql(u8, part, "up")) p.position = .up else if (std.mem.eql(u8, part, "down")) p.position = .down else if (std.mem.eql(u8, part, "hidden")) p.hidden = true else if (std.mem.eql(u8, part, "nohidden")) p.hidden = false else if (std.mem.eql(u8, part, "wrap")) p.wrap = true else if (std.mem.eql(u8, part, "nowrap")) p.wrap = false else if (std.mem.startsWith(u8, part, "border-")) p.border_style = parseBorderStyle(part[7..]) catch p.border_style else if (std.mem.endsWith(u8, part, "%")) p.percent = parsePercent(part);
    }
}

fn parseWalkerOptions(spec: []const u8) !WalkerOptions {
    var out: WalkerOptions = .{ .file = false, .follow = false, .hidden = false };
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, "file")) out.file = true else if (std.ascii.eqlIgnoreCase(part, "dir")) out.dir = true else if (std.ascii.eqlIgnoreCase(part, "follow")) out.follow = true else if (std.ascii.eqlIgnoreCase(part, "hidden")) out.hidden = true else return error.InvalidWalkerOption;
    }
    if (!out.file and !out.dir) return error.InvalidWalkerOption;
    return out;
}

fn walkerTrimRoot(root: []const u8) []const u8 {
    var out = root;
    while (out.len > 1 and out[0] == '.' and std.fs.path.isSep(out[1])) out = out[2..];
    if (out.len == 0) return ".";
    return out;
}

fn walkerSkipHasSeparator(skip: []const u8) bool {
    for (skip) |byte| if (std.fs.path.isSep(byte)) return true;
    return false;
}

fn walkerLogicalPath(root: []const u8, relative: []const u8, buffer: []u8) ?[]const u8 {
    const label = walkerTrimRoot(root);
    var at: usize = 0;
    if (!std.mem.eql(u8, label, ".")) {
        if (label.len > buffer.len) return null;
        @memcpy(buffer[0..label.len], label);
        at = label.len;
        if (at != 0 and !std.fs.path.isSep(buffer[at - 1])) {
            if (at == buffer.len) return null;
            buffer[at] = std.fs.path.sep;
            at += 1;
        }
    }
    if (relative.len > buffer.len - at) return null;
    @memcpy(buffer[at .. at + relative.len], relative);
    return buffer[0 .. at + relative.len];
}

fn walkerPathSuffixMatch(path: []const u8, suffix: []const u8) bool {
    if (std.mem.eql(u8, path, suffix)) return true;
    if (path.len <= suffix.len or !std.mem.endsWith(u8, path, suffix)) return false;
    return std.fs.path.isSep(path[path.len - suffix.len - 1]);
}

fn walkerDirSkipped(options: *const Options, root_label: []const u8, relative: []const u8, basename: []const u8) bool {
    if (!options.walker.hidden and basename.len != 0 and basename[0] == '.') return true;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const logical_path = walkerLogicalPath(root_label, relative, &path_buf) orelse return false;
    var it = std.mem.splitScalar(u8, options.walker_skip, ',');
    while (it.next()) |skip| {
        if (skip.len == 0) continue;
        if (!walkerSkipHasSeparator(skip)) {
            if (std.mem.eql(u8, basename, skip)) return true;
            continue;
        }
        if (std.fs.path.isSep(skip[0])) {
            if (std.mem.endsWith(u8, logical_path, skip)) return true;
        } else if (walkerPathSuffixMatch(logical_path, skip)) {
            return true;
        }
    }
    return false;
}

fn walkerAppendPath(out: *std.ArrayList(u8), allocator: Allocator, root: []const u8, relative: []const u8, is_dir: bool, delim: u8) !void {
    const label = walkerTrimRoot(root);
    if (!std.mem.eql(u8, label, ".")) {
        try out.appendSlice(allocator, label);
        if (label.len != 0 and !std.fs.path.isSep(label[label.len - 1])) try out.append(allocator, std.fs.path.sep);
    }
    try out.appendSlice(allocator, relative);
    if (is_dir and (out.items.len == 0 or !std.fs.path.isSep(out.items[out.items.len - 1]))) try out.append(allocator, std.fs.path.sep);
    try out.append(allocator, delim);
}

fn walkerAncestorContains(ancestors: []const Io.File.INode, inode: Io.File.INode) bool {
    for (ancestors) |ancestor| if (ancestor == inode) return true;
    return false;
}

fn walkerPathEqual(a: []const u8, b: []const u8) bool {
    return if (comptime builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn walkerPathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    return if (comptime builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)
    else
        std.mem.eql(u8, path[0..prefix.len], prefix);
}

fn walkerSymlinkTargetIsRootAncestor(root_real: []const u8, target_real: []const u8) bool {
    if (walkerPathEqual(root_real, target_real)) return true;
    if (target_real.len == 0 or target_real.len >= root_real.len) return false;
    if (!walkerPathHasPrefix(root_real, target_real)) return false;
    if (std.fs.path.isSep(target_real[target_real.len - 1])) return true;
    return std.fs.path.isSep(root_real[target_real.len]);
}

fn walkNativeDir(
    allocator: Allocator,
    io: Io,
    options: *const Options,
    root_label: []const u8,
    root_real: []const u8,
    dir: Io.Dir,
    relative: *std.ArrayList(u8),
    ancestors: *std.ArrayList(Io.File.INode),
    out: *std.ArrayList(u8),
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const old_len = relative.items.len;
        defer relative.shrinkRetainingCapacity(old_len);
        if (old_len != 0) try relative.append(allocator, std.fs.path.sep);
        try relative.appendSlice(allocator, entry.name);

        const is_symlink = entry.kind == .sym_link;
        var kind = entry.kind;
        var is_dir_symlink = false;
        if (is_symlink) {
            const followed = dir.statFile(io, entry.name, .{ .follow_symlinks = true }) catch null;
            is_dir_symlink = if (followed) |stat| stat.kind == .directory else false;
            if (is_dir_symlink) {
                if (!options.walker.follow) continue;
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_len = dir.realPathFile(io, entry.name, &target_buf) catch continue;
                if (walkerSymlinkTargetIsRootAncestor(root_real, target_buf[0..target_len])) continue;
                kind = .directory;
            } else {
                // fzf treats non-directory symlinks, including dangling links, as file entries.
                kind = .file;
            }
        } else if (kind == .unknown) {
            const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            kind = stat.kind;
        }

        if (kind == .directory) {
            if (walkerDirSkipped(options, root_label, relative.items, entry.name)) continue;
            if (options.walker.dir) try walkerAppendPath(out, allocator, root_label, relative.items, true, if (options.read0) 0 else '\n');

            var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer child.close(io);
            const child_stat = child.stat(io) catch continue;
            if (walkerAncestorContains(ancestors.items, child_stat.inode)) continue;
            try ancestors.append(allocator, child_stat.inode);
            defer _ = ancestors.pop();
            try walkNativeDir(allocator, io, options, root_label, root_real, child, relative, ancestors, out);
        } else if (kind == .file and options.walker.file) {
            try walkerAppendPath(out, allocator, root_label, relative.items, false, if (options.read0) 0 else '\n');
        }
    }
}

fn appendNativeWalkerRoot(allocator: Allocator, io: Io, options: *const Options, root_label: []const u8, root: Io.Dir, out: *std.ArrayList(u8)) !void {
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(allocator);
    var ancestors: std.ArrayList(Io.File.INode) = .empty;
    defer ancestors.deinit(allocator);
    var root_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_real_len = try root.realPath(io, &root_real_buf);
    const root_real = root_real_buf[0..root_real_len];
    const root_stat = try root.stat(io);
    try ancestors.append(allocator, root_stat.inode);
    try walkNativeDir(allocator, io, options, root_label, root_real, root, &relative, &ancestors, out);
}

const ProcessStdout = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

fn runProcessStdout(allocator: Allocator, io: Io, argv: []const []const u8) !ProcessStdout {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const stdout = try reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(stdout);
    return .{ .term = try child.wait(io), .stdout = stdout };
}

fn runWalkerRoot(allocator: Allocator, io: Io, options: *const Options, root_path: []const u8, explicit: bool, out: *std.ArrayList(u8)) !void {
    const label = walkerTrimRoot(root_path);
    if (explicit and !std.mem.eql(u8, label, ".")) {
        const basename = std.fs.path.basename(label);
        if (walkerDirSkipped(options, ".", label, basename)) return;
        if (options.walker.dir) try walkerAppendPath(out, allocator, ".", label, true, if (options.read0) 0 else '\n');
    }
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    try appendNativeWalkerRoot(allocator, io, options, root_path, root, out);
}

fn runWalker(allocator: Allocator, io: Io, options: *const Options) ![]u8 {
    if (!options.walker.file and !options.walker.dir) return try allocator.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (options.walker_roots.items.len == 0) {
        try runWalkerRoot(allocator, io, options, ".", false, &out);
    } else {
        for (options.walker_roots.items) |root_path| try runWalkerRoot(allocator, io, options, root_path, true, &out);
    }
    return try out.toOwnedSlice(allocator);
}

fn lazySourceNotifyAfterPush(backend: *LazyBackend, since_notify: *usize) void {
    since_notify.* += 1;
    const count = backend.store.count();
    if ((count <= 4096 and since_notify.* >= 128) or since_notify.* >= 4096) {
        since_notify.* = 0;
        backend.notifyData();
    }
}

fn lazyWalkerAppendPath(
    backend: *LazyBackend,
    root: []const u8,
    relative: []const u8,
    is_dir: bool,
    since_notify: *usize,
) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = walkerLogicalPath(root, relative, buf[0..std.fs.max_path_bytes]) orelse return error.NameTooLong;
    var len = path.len;
    if (is_dir and (len == 0 or !std.fs.path.isSep(path[len - 1]))) {
        if (len == buf.len) return error.NameTooLong;
        buf[len] = std.fs.path.sep;
        len += 1;
    }
    _ = try backend.store.append(buf[0..len]);
    lazySourceNotifyAfterPush(backend, since_notify);
}

fn lazyWalkNativeDir(
    allocator: Allocator,
    io: Io,
    backend: *LazyBackend,
    options: *const Options,
    root_label: []const u8,
    root_real: []const u8,
    dir: Io.Dir,
    relative: *std.ArrayList(u8),
    ancestors: *std.ArrayList(Io.File.INode),
    since_notify: *usize,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (backend.stop.load(.acquire)) return error.Canceled;
        const old_len = relative.items.len;
        defer relative.shrinkRetainingCapacity(old_len);
        if (old_len != 0) try relative.append(allocator, std.fs.path.sep);
        try relative.appendSlice(allocator, entry.name);

        const is_symlink = entry.kind == .sym_link;
        var kind = entry.kind;
        var is_dir_symlink = false;
        if (is_symlink) {
            const followed = dir.statFile(io, entry.name, .{ .follow_symlinks = true }) catch null;
            is_dir_symlink = if (followed) |stat| stat.kind == .directory else false;
            if (is_dir_symlink) {
                if (!options.walker.follow) continue;
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_len = dir.realPathFile(io, entry.name, &target_buf) catch continue;
                if (walkerSymlinkTargetIsRootAncestor(root_real, target_buf[0..target_len])) continue;
                kind = .directory;
            } else {
                kind = .file;
            }
        } else if (kind == .unknown) {
            const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            kind = stat.kind;
        }

        if (kind == .directory) {
            if (walkerDirSkipped(options, root_label, relative.items, entry.name)) continue;
            if (options.walker.dir) try lazyWalkerAppendPath(backend, root_label, relative.items, true, since_notify);
            var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer child.close(io);
            const child_stat = child.stat(io) catch continue;
            if (walkerAncestorContains(ancestors.items, child_stat.inode)) continue;
            try ancestors.append(allocator, child_stat.inode);
            defer _ = ancestors.pop();
            try lazyWalkNativeDir(allocator, io, backend, options, root_label, root_real, child, relative, ancestors, since_notify);
        } else if (kind == .file and options.walker.file) {
            try lazyWalkerAppendPath(backend, root_label, relative.items, false, since_notify);
        }
    }
}

fn lazyRunWalkerRoot(backend: *LazyBackend, options: *const Options, root_path: []const u8, explicit: bool, since_notify: *usize) !void {
    const label = walkerTrimRoot(root_path);
    if (explicit and !std.mem.eql(u8, label, ".")) {
        const basename = std.fs.path.basename(label);
        if (walkerDirSkipped(options, ".", label, basename)) return;
        if (options.walker.dir) try lazyWalkerAppendPath(backend, ".", label, true, since_notify);
    }
    var root = try Io.Dir.cwd().openDir(backend.io, root_path, .{ .iterate = true });
    defer root.close(backend.io);
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(backend.allocator);
    var ancestors: std.ArrayList(Io.File.INode) = .empty;
    defer ancestors.deinit(backend.allocator);
    var root_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_real_len = try root.realPath(backend.io, &root_real_buf);
    const root_real = root_real_buf[0..root_real_len];
    const root_stat = try root.stat(backend.io);
    try ancestors.append(backend.allocator, root_stat.inode);
    try lazyWalkNativeDir(backend.allocator, backend.io, backend, options, root_path, root_real, root, &relative, &ancestors, since_notify);
}

fn lazyRunWalker(backend: *LazyBackend, options: *const Options) !void {
    if (!options.walker.file and !options.walker.dir) return;
    var since_notify: usize = 0;
    if (options.walker_roots.items.len == 0) {
        try lazyRunWalkerRoot(backend, options, ".", false, &since_notify);
    } else {
        for (options.walker_roots.items) |root_path| try lazyRunWalkerRoot(backend, options, root_path, true, &since_notify);
    }
    if (since_notify != 0) backend.notifyData();
}

fn lazyPushDelimitedRecord(backend: *LazyBackend, record: []const u8, delim: u8, since_notify: *usize) !void {
    var line = record;
    if (delim == '\n' and line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    _ = try backend.store.appendClassified(line);
    lazySourceNotifyAfterPush(backend, since_notify);
}

fn lazyFeedFd(backend: *LazyBackend, fd: std.posix.fd_t, delim: u8) !void {
    var buffer: [128 * 1024]u8 = undefined;
    var partial: std.ArrayList(u8) = .empty;
    defer partial.deinit(backend.allocator);
    var since_notify: usize = 0;
    while (!backend.stop.load(.acquire)) {
        const rc = std.c.read(fd, &buffer, buffer.len);
        if (rc < 0) {
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.posix.E.INTR)) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break;
        const n: usize = @intCast(rc);
        // Classify the source buffer once, before publishing any record from it.
        // All records and partial records assembled from observed chunks are then
        // safe to append without rescanning each short candidate.
        backend.store.observeBytes(buffer[0..n]);
        var at: usize = 0;
        while (at < n) {
            const pos = std.mem.indexOfScalarPos(u8, buffer[0..n], at, delim) orelse {
                try partial.appendSlice(backend.allocator, buffer[at..n]);
                break;
            };
            if (partial.items.len == 0) {
                try lazyPushDelimitedRecord(backend, buffer[at..pos], delim, &since_notify);
            } else {
                try partial.appendSlice(backend.allocator, buffer[at..pos]);
                try lazyPushDelimitedRecord(backend, partial.items, delim, &since_notify);
                partial.clearRetainingCapacity();
            }
            at = pos + 1;
        }
    }
    if (partial.items.len != 0 and !backend.stop.load(.acquire)) try lazyPushDelimitedRecord(backend, partial.items, delim, &since_notify);
    if (since_notify != 0) backend.notifyData();
}

fn lazyRunCommandSource(backend: *LazyBackend, command: []const u8, delim: u8) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.UnsupportedTerminal;
    var child = try std.process.spawn(backend.io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer child.kill(backend.io);
    const pgid: i64 = @intCast(child.id.?);
    backend.source_child_pgid.store(pgid, .release);
    defer backend.source_child_pgid.store(0, .release);
    try lazyFeedFd(backend, child.stdout.?.handle, delim);
    _ = try child.wait(backend.io);
}

fn lazySourceThread(backend: *LazyBackend) void {
    defer backend.finishInput();
    const options = backend.source_options orelse return;
    const delim: u8 = if (options.read0) 0 else '\n';
    switch (backend.source_kind) {
        .stdin => if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            lazyFeedFd(backend, std.posix.STDIN_FILENO, delim) catch {};
        },
        .walker => lazyRunWalker(backend, options) catch {},
        .command => if (backend.source_command) |command| lazyRunCommandSource(backend, command, delim) catch {},
        .none => {},
    }
}

fn runDefaultCommand(allocator: Allocator, io: Io, command: []const u8, windows_shell: ?[]const u8) ![]u8 {
    const result = if (comptime builtin.os.tag == .windows)
        try runProcessStdout(allocator, io, &.{ windows_shell orelse "cmd.exe", "/d", "/s", "/c", command })
    else
        try runProcessStdout(allocator, io, &.{ "/bin/sh", "-c", command });
    return result.stdout;
}

fn filterUsesStreamingPath(options: *const Options) bool {
    return options.filter != null and options.no_sort and !options.tac and !options.sync;
}

fn lazyInteractiveEligible(options: *const Options) bool {
    // Keep whole-corpus transformation/state modes on the mature synchronous
    // path until their incremental equivalents are implemented. The normal
    // interactive search path must never materialize or index the full input.
    return !options.sync and
        options.tail == null and
        options.header_lines == 0 and
        options.nth == null and
        options.with_nth == null and
        !options.ansi and
        !options.tac and
        !options.multi and
        !options.raw and
        !options.track and
        options.listen_addr == null and
        options.bindings.items.len == 0;
}

fn readCandidates(allocator: Allocator, io: Io, options: *const Options, default_command: ?[]const u8, windows_shell: ?[]const u8) !CandidateSet {
    if (Io.File.stdin().isTty(io) catch false) {
        const blob = if (default_command) |command| blk: {
            if (command.len == 0) break :blk try runWalker(allocator, io, options);
            break :blk try runDefaultCommand(allocator, io, command, windows_shell);
        } else try runWalker(allocator, io, options);
        return candidatesFromOwnedBlob(allocator, blob, options);
    }
    if (!filterUsesStreamingPath(options)) {
        if (options.tail) |tail| {
            const empty_filter_trim = if (options.filter) |filter| filter.len == 0 else false;
            const body_tail = if (empty_filter_trim) tail -| options.header_lines else tail;
            const blob = try readTailBlobStdin(allocator, io, body_tail, options.header_lines, if (options.read0) 0 else '\n');
            return candidatesFromOwnedBlob(allocator, blob, options);
        }
    }
    var buffer: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buffer);
    const blob = try reader.interface.allocRemaining(allocator, .unlimited);
    return candidatesFromOwnedBlob(allocator, blob, options);
}

const TailRing = struct {
    allocator: Allocator,
    slots: []?[]u8,
    total: usize = 0,

    fn push(self: *TailRing, record: []const u8) !void {
        if (self.slots.len == 0) {
            self.total += 1;
            return;
        }
        const owned = try self.allocator.dupe(u8, record);
        const slot = self.total % self.slots.len;
        if (self.slots[slot]) |old| self.allocator.free(old);
        self.slots[slot] = owned;
        self.total += 1;
    }

    fn deinit(self: *TailRing) void {
        for (self.slots) |record| if (record) |owned| self.allocator.free(owned);
        self.allocator.free(self.slots);
    }
};

fn readTailBlobStdin(allocator: Allocator, io: Io, body_tail: usize, header_lines: usize, delim: u8) ![]u8 {
    const slots = try allocator.alloc(?[]u8, body_tail);
    @memset(slots, null);
    var ring = TailRing{ .allocator = allocator, .slots = slots };
    defer ring.deinit();

    var headers: std.ArrayList([]u8) = .empty;
    defer {
        for (headers.items) |line| allocator.free(line);
        headers.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var buffer: [64 * 1024]u8 = undefined;
    var reader_buffer: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().readerStreaming(io, &reader_buffer);
    var saw_any = false;
    var last_was_delim = false;
    while (true) {
        const count = stdin_reader.interface.readSliceShort(&buffer) catch return error.ReadFailed;
        if (count == 0) break;
        saw_any = true;
        for (buffer[0..count]) |byte| {
            if (byte == delim) {
                if (headers.items.len < header_lines) {
                    try headers.append(allocator, try allocator.dupe(u8, current.items));
                } else {
                    try ring.push(current.items);
                }
                current.clearRetainingCapacity();
                last_was_delim = true;
            } else {
                try current.append(allocator, byte);
                last_was_delim = false;
            }
        }
    }
    if (saw_any and !last_was_delim) {
        if (headers.items.len < header_lines) {
            try headers.append(allocator, try allocator.dupe(u8, current.items));
        } else {
            try ring.push(current.items);
        }
    }

    const kept = @min(ring.total, body_tail);
    const first = if (body_tail != 0 and ring.total > body_tail) ring.total % body_tail else 0;
    var bytes: usize = headers.items.len + kept;
    for (headers.items) |line| bytes += line.len;
    for (0..kept) |i| bytes += ring.slots[(first + i) % body_tail].?.len;
    if (bytes == 0) return try allocator.alloc(u8, 0);
    const blob = try allocator.alloc(u8, bytes);
    var at: usize = 0;
    for (headers.items) |line| {
        @memcpy(blob[at .. at + line.len], line);
        at += line.len;
        blob[at] = delim;
        at += 1;
    }
    for (0..kept) |i| {
        const record = ring.slots[(first + i) % body_tail].?;
        @memcpy(blob[at .. at + record.len], record);
        at += record.len;
        blob[at] = delim;
        at += 1;
    }
    return blob;
}

fn anyNonAscii(lines: []const []const u8) bool {
    for (lines) |line| if (fuzzy_engine.cliTextHasNonAscii(line)) return true;
    return false;
}

fn candidatesFromOwnedBlob(allocator: Allocator, blob: []u8, options: *const Options) !CandidateSet {
    errdefer allocator.free(blob);
    const delim: u8 = if (options.read0) 0 else '\n';
    var total_count: usize = 0;
    if (blob.len != 0) {
        var it_count = std.mem.splitScalar(u8, blob, delim);
        while (it_count.next()) |part| {
            if (part.len == 0 and it_count.index == null and blob[blob.len - 1] == delim) break;
            total_count += 1;
        }
    }
    const header_count = @min(total_count, options.header_lines);
    const body_count = total_count - header_count;
    const apply_tail = !filterUsesStreamingPath(options);
    const keep_count = if (apply_tail) (if (options.tail) |tail| blk: {
        const empty_filter_trim = if (options.filter) |filter| filter.len == 0 else false;
        const body_tail = if (empty_filter_trim) tail -| header_count else tail;
        break :blk @min(body_count, body_tail);
    } else body_count) else body_count;
    const skip_body = body_count - keep_count;
    const header = try allocator.alloc([]const u8, header_count);
    errdefer allocator.free(header);
    const output = try allocator.alloc([]const u8, keep_count);
    errdefer allocator.free(output);
    var it = std.mem.splitScalar(u8, blob, delim);
    var source_index: usize = 0;
    var header_index: usize = 0;
    var body_index: usize = 0;
    var n: usize = 0;
    while (it.next()) |part| {
        if (source_index >= total_count) break;
        const line = if (!options.read0 and part.len != 0 and part[part.len - 1] == '\r') part[0 .. part.len - 1] else part;
        if (source_index < header_count) {
            header[header_index] = line;
            header_index += 1;
        } else {
            if (body_index >= skip_body and n < keep_count) {
                output[n] = line;
                n += 1;
            }
            body_index += 1;
        }
        source_index += 1;
    }
    const count = keep_count;
    if (options.tac) std.mem.reverse([]const u8, output);

    var display: [][]const u8 = output;
    var owned_display = false;
    if (options.with_nth) |spec| {
        display = try allocator.alloc([]const u8, count);
        errdefer allocator.free(display);
        var built: usize = 0;
        errdefer for (display[0..built]) |line| allocator.free(line);
        for (output, 0..) |line, idx| {
            display[idx] = try transformWithNth(allocator, line, options.delimiter, spec, idx);
            built += 1;
        }
        owned_display = true;
    }

    // fzf applies --with-nth first. --nth then retokenizes that transformed
    // presentation, including delimiters retained by numeric --with-nth.
    const base_search = if (options.with_nth != null) display else output;
    if (options.nth == null and !options.ansi) {
        return .{ .blob = blob, .header = header, .output = output, .display = display, .search = base_search, .owned_display = owned_display, .owned_search = false, .has_non_ascii = anyNonAscii(base_search) };
    }

    const search = try allocator.alloc([]const u8, count);
    errdefer allocator.free(search);
    var built_search: usize = 0;
    errdefer for (search[0..built_search]) |line| allocator.free(line);
    for (base_search, 0..) |line, idx| {
        var transformed: ?[]u8 = null;
        const scoped: []const u8 = if (options.nth) |spec| blk: {
            const tmp = try transformNthSearch(allocator, line, options.delimiter, spec, idx);
            transformed = tmp;
            break :blk tmp;
        } else line;
        if (options.ansi) {
            search[idx] = try stripAnsi(allocator, scoped);
            if (transformed) |tmp| allocator.free(tmp);
        } else {
            search[idx] = transformed.?;
        }
        built_search += 1;
    }
    return .{ .blob = blob, .header = header, .output = output, .display = display, .search = search, .owned_display = owned_display, .owned_search = true, .has_non_ascii = anyNonAscii(search) };
}

const TermKind = enum { fuzzy, exact, prefix, suffix, boundary_exact, equal };

const QueryTerm = struct {
    text: []const u8,
    kind: TermKind,
    inverse: bool,
    clause: u16,
};

const ParsedQuery = struct {
    terms: []QueryTerm,
    clause_count: usize,
    driver: ?[]const u8,
    direct: ?[]const u8,
    sortable: bool,
};

const CandidateScore = struct {
    score: i32 = 0,
    min_begin: usize = std.math.maxInt(usize),
    min_end: usize = std.math.maxInt(usize),
    max_end: usize = 0,
    valid_offset: bool = false,
    rune_offsets: bool = false,

    fn add(self: *CandidateScore, matched: fuzzy_engine.CliMatch) void {
        self.score += matched.score;
        if (matched.start < matched.end) {
            self.min_begin = @min(self.min_begin, matched.start);
            self.min_end = @min(self.min_end, matched.end);
            self.max_end = @max(self.max_end, matched.end);
            self.valid_offset = true;
        }
    }
};

const ExtendedRank = struct {
    entry: usize,
    score: CandidateScore,
};

const RankContext = struct {
    candidates: *const CandidateSet,
    options: *const Options,
};

fn trimLength(line: []const u8) usize {
    var start: usize = 0;
    var end = line.len;
    while (start < end and std.ascii.isWhitespace(line[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(line[end - 1])) end -= 1;
    return end - start;
}

fn runeTrimLength(line: []const u8) usize {
    var it = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
    var count: usize = 0;
    var leading: usize = 0;
    var last_non_white: ?usize = null;
    var still_leading = true;
    while (it.nextCodepoint()) |cp| : (count += 1) {
        const white = fuzzy_engine.cliRuneIsWhitespace(cp);
        if (still_leading and white) leading += 1 else still_leading = false;
        if (!white) last_non_white = count;
    }
    const end = if (last_non_white) |last| last + 1 else leading;
    return end -| leading;
}

fn runeChunkLength(line: []const u8, begin_match: usize, end_match: usize) usize {
    var it = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
    var rune_index: usize = 0;
    var chunk_begin: usize = 0;
    var chunk_end: ?usize = null;
    var last_white_end: usize = 0;
    while (it.nextCodepoint()) |cp| : (rune_index += 1) {
        const white = fuzzy_engine.cliRuneIsWhitespace(cp);
        if (rune_index < begin_match and white) last_white_end = rune_index + 1;
        if (rune_index >= end_match and white and chunk_end == null) chunk_end = rune_index;
    }
    chunk_begin = last_white_end;
    return (chunk_end orelse rune_index) - chunk_begin;
}

fn runeLastPathDelimiter(line: []const u8) ?usize {
    var it = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
    var rune_index: usize = 0;
    var last: ?usize = null;
    while (it.nextCodepoint()) |cp| : (rune_index += 1) {
        if (cp == '/' or cp == '\\') last = rune_index;
    }
    return last;
}

fn runeWhitePrefix(line: []const u8, match_begin: usize) usize {
    var it = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
    var rune_index: usize = 0;
    while (it.nextCodepoint()) |cp| : (rune_index += 1) {
        if (rune_index == match_begin or !fuzzy_engine.cliRuneIsWhitespace(cp)) return rune_index;
    }
    return rune_index;
}

fn runeTiebreakValue(kind: TieBreak, line: []const u8, score: CandidateScore) usize {
    const invalid = std.math.maxInt(usize);
    return switch (kind) {
        .length => runeTrimLength(line),
        .chunk => if (!score.valid_offset) invalid else runeChunkLength(line, score.min_begin, score.max_end),
        .pathname => blk: {
            if (!score.valid_offset) break :blk invalid;
            if (runeLastPathDelimiter(line)) |delim| {
                if (delim > score.min_begin) break :blk invalid;
                break :blk score.min_begin - delim;
            }
            break :blk score.min_begin + 1;
        },
        .begin => blk: {
            if (!score.valid_offset) break :blk invalid;
            break :blk score.min_end -| runeWhitePrefix(line, score.min_begin);
        },
        .end => blk: {
            if (!score.valid_offset) break :blk invalid;
            const white_prefix = runeWhitePrefix(line, score.min_begin);
            const trimmed = runeTrimLength(line);
            const span = score.max_end -| white_prefix;
            break :blk std.math.maxInt(u16) - (@as(usize, std.math.maxInt(u16)) * span / (trimmed + 1));
        },
    };
}

fn tiebreakValue(kind: TieBreak, line: []const u8, score: CandidateScore) usize {
    if (score.rune_offsets) return runeTiebreakValue(kind, line, score);
    const invalid = std.math.maxInt(usize);
    return switch (kind) {
        .length => trimLength(line),
        .chunk => blk: {
            if (!score.valid_offset) break :blk invalid;
            var begin = score.min_begin;
            var end = score.max_end;
            while (begin > 0 and !std.ascii.isWhitespace(line[begin - 1])) begin -= 1;
            while (end < line.len and !std.ascii.isWhitespace(line[end])) end += 1;
            break :blk end - begin;
        },
        .pathname => blk: {
            if (!score.valid_offset) break :blk invalid;
            var last_delim: ?usize = null;
            var i = line.len;
            while (i > 0) {
                i -= 1;
                if (line[i] == '/' or line[i] == '\\') {
                    last_delim = i;
                    break;
                }
            }
            if (last_delim) |delim| {
                if (delim > score.min_begin) break :blk invalid;
                break :blk score.min_begin - delim;
            }
            // fzf models a missing delimiter as position -1.
            break :blk score.min_begin + 1;
        },
        .begin => blk: {
            if (!score.valid_offset) break :blk invalid;
            var white_prefix: usize = 0;
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                white_prefix = i;
                if (i == score.min_begin or !std.ascii.isWhitespace(line[i])) break;
            }
            break :blk score.min_end -| white_prefix;
        },
        .end => blk: {
            if (!score.valid_offset) break :blk invalid;
            var white_prefix: usize = 0;
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                white_prefix = i;
                if (i == score.min_begin or !std.ascii.isWhitespace(line[i])) break;
            }
            const trimmed = trimLength(line);
            const span = score.max_end -| white_prefix;
            // Same monotonic integer metric as fzf's uint16 rank formula.
            break :blk std.math.maxInt(u16) - (@as(usize, std.math.maxInt(u16)) * span / (trimmed + 1));
        },
    };
}

fn betterExtended(ctx: RankContext, a: ExtendedRank, b: ExtendedRank) bool {
    if (a.score.score != b.score.score) return a.score.score > b.score.score;
    var i: usize = 0;
    while (i < ctx.options.tiebreak_count) : (i += 1) {
        const kind = ctx.options.tiebreaks[i];
        const av = tiebreakValue(kind, ctx.candidates.search[a.entry], a.score);
        const bv = tiebreakValue(kind, ctx.candidates.search[b.entry], b.score);
        if (av != bv) return av < bv;
    }
    return a.entry < b.entry;
}

fn bubbleWorstExtended(heap: []ExtendedRank, ctx: RankContext, start: usize) void {
    var child = start;
    while (child != 0) {
        const parent = (child - 1) / 2;
        if (!betterExtended(ctx, heap[parent], heap[child])) break;
        std.mem.swap(ExtendedRank, &heap[parent], &heap[child]);
        child = parent;
    }
}

fn siftWorstExtended(heap: []ExtendedRank, ctx: RankContext, start: usize) void {
    var parent = start;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= heap.len) break;
        const right = left + 1;
        var worse_child = left;
        if (right < heap.len and betterExtended(ctx, heap[left], heap[right])) worse_child = right;
        if (!betterExtended(ctx, heap[parent], heap[worse_child])) break;
        std.mem.swap(ExtendedRank, &heap[parent], &heap[worse_child]);
        parent = worse_child;
    }
}

fn selectTopExtended(ranks: []ExtendedRank, limit: usize, ctx: RankContext) []ExtendedRank {
    const take = @min(limit, ranks.len);
    if (take == 0) return ranks[0..0];

    var heap_len: usize = 0;
    for (0..ranks.len) |i| {
        const item = ranks[i];
        if (heap_len < take) {
            ranks[heap_len] = item;
            bubbleWorstExtended(ranks[0 .. heap_len + 1], ctx, heap_len);
            heap_len += 1;
        } else if (betterExtended(ctx, item, ranks[0])) {
            ranks[0] = item;
            siftWorstExtended(ranks[0..heap_len], ctx, 0);
        }
    }
    std.mem.sort(ExtendedRank, ranks[0..heap_len], ctx, betterExtended);
    return ranks[0..heap_len];
}

fn searchCandidates(
    index: *fuzzy.Index,
    candidates: *const CandidateSet,
    options: *const Options,
    query: []const u8,
    out: []usize,
    rank_scratch: []ExtendedRank,
    limit: usize,
) ![]usize {
    const cap = @min(limit, out.len);
    if (cap == 0) return out[0..0];
    if (options.disabled or query.len == 0) {
        const found = try index.search("", out[0..cap]);
        return found;
    }

    var term_buf: [512]QueryTerm = undefined;
    const parsed = try parseQuery(query, options, &term_buf);
    const heuristic_ascii = options.algorithm == .heuristic and !fuzzy_engine.cliTextHasNonAscii(query);
    var heuristic_term_buf: [512][]const u8 = undefined;
    const heuristic_terms = if (heuristic_ascii and parsed.direct == null) heuristicPureAndTerms(parsed, options.case_mode, &heuristic_term_buf) else null;

    if (parsed.direct) |direct| {
        const fast_direct = !candidates.has_non_ascii and !fuzzy_engine.cliTextHasNonAscii(direct) and options.scheme == .default and !termCaseSensitive(options.case_mode, direct) and options.tiebreak_count == 1 and options.tiebreaks[0] == .length;
        if (fast_direct and (options.algorithm == .v2 or options.algorithm == .heuristic)) return try index.search(direct, out[0..cap]);
    }

    // fzf does not sort inverse-only extended queries. --no-sort likewise
    // preserves input order after filtering.
    if (options.no_sort or !parsed.sortable) {
        var write: usize = 0;
        if (heuristic_terms) |terms| {
            if (!candidates.has_non_ascii) {
                var source = fuzzy_engine.cliCollectMayMatchAllFoldedAscii(index, terms, out);
                source = heuristicFilterPureAndAscii(candidates, source, terms);
                return source[0..@min(cap, source.len)];
            }
        }
        for (candidates.search, 0..) |line, idx| {
            if (heuristic_ascii and heuristicHasPresenceClause(parsed) and !fuzzy_engine.cliTextHasNonAscii(line) and !heuristicPresenceClausesMatch(index, parsed, idx)) continue;
            if (scoreParsedCandidate(index, parsed, line, idx, options.case_mode, !options.literal, options.scheme, options.algorithm) == null) continue;
            out[write] = idx;
            write += 1;
            if (write == cap) break;
        }
        return out[0..write];
    }

    if (heuristic_terms) |terms| {
        if (options.scheme == .default and heuristicScoreOnlyTiebreakSafe(options)) {
            var source = fuzzy_engine.cliCollectMayMatchAllFoldedAscii(index, terms, out);
            source = heuristicFilterPureAndAscii(candidates, source, terms);

            var rank_len = source.len;
            for (source, 0..) |idx, i| rank_scratch[i] = .{ .entry = idx, .score = .{} };
            for (terms) |term| {
                const prepared = fuzzy_engine.prepareFoldedForCli(index, term);
                var keep: usize = 0;
                for (rank_scratch[0..rank_len]) |rank| {
                    const term_score = fuzzy_engine.scorePreparedFoldedForCli(index, &prepared, rank.entry) orelse continue;
                    var next = rank;
                    next.score.score += term_score;
                    rank_scratch[keep] = next;
                    keep += 1;
                }
                rank_len = keep;
                if (rank_len == 0) break;
            }
            if (candidates.has_non_ascii) {
                for (candidates.search, 0..) |line, idx| {
                    if (!fuzzy_engine.cliTextHasNonAscii(line)) continue;
                    const score = scoreParsedCandidate(index, parsed, line, idx, options.case_mode, !options.literal, options.scheme, options.algorithm) orelse continue;
                    rank_scratch[rank_len] = .{ .entry = idx, .score = score };
                    rank_len += 1;
                }
            }
            const top = selectTopExtended(rank_scratch[0..rank_len], cap, .{ .candidates = candidates, .options = options });
            for (top, 0..) |rank, i| out[i] = rank.entry;
            return out[0..top.len];
        }
    }

    var source: []usize = out;
    const heuristic_source = heuristic_ascii and parsed.direct == null and heuristicHasPresenceClause(parsed);
    if (heuristic_terms) |terms| {
        source = fuzzy_engine.cliCollectMayMatchAllFoldedAscii(index, terms, out);
        source = heuristicFilterPureAndAscii(candidates, source, terms);
    } else if (heuristic_source) {
        var source_len: usize = 0;
        for (candidates.search, 0..) |line, idx| {
            if (!fuzzy_engine.cliTextHasNonAscii(line) and !heuristicPresenceClausesMatch(index, parsed, idx)) continue;
            out[source_len] = idx;
            source_len += 1;
        }
        source = out[0..source_len];
    } else if (parsed.driver) |driver| {
        // The byte index is not a sound prefilter when Unicode folding or fzf
        // normalization can make a non-ASCII candidate match an ASCII query.
        if (!candidates.has_non_ascii and !fuzzy_engine.cliTextHasNonAscii(driver)) {
            if (options.algorithm == .heuristic) {
                const one = [_][]const u8{driver};
                source = fuzzy_engine.cliCollectMayMatchAllFoldedAscii(index, &one, out);
            } else source = try index.search(driver, out);
        } else {
            const count = @min(out.len, candidates.search.len);
            for (out[0..count], 0..) |*slot, i| slot.* = i;
            source = out[0..count];
        }
    } else {
        const count = @min(out.len, candidates.search.len);
        for (out[0..count], 0..) |*slot, i| slot.* = i;
        source = out[0..count];
    }

    var rank_len: usize = 0;
    for (source) |idx| {
        const score = scoreParsedCandidate(index, parsed, candidates.search[idx], idx, options.case_mode, !options.literal, options.scheme, options.algorithm) orelse continue;
        rank_scratch[rank_len] = .{ .entry = idx, .score = score };
        rank_len += 1;
    }
    std.mem.sort(ExtendedRank, rank_scratch[0..rank_len], RankContext{ .candidates = candidates, .options = options }, betterExtended);

    const take = @min(cap, rank_len);
    for (rank_scratch[0..take], 0..) |rank, i| out[i] = rank.entry;
    return out[0..take];
}

fn scoreParsedCandidate(index: *fuzzy.Index, parsed: ParsedQuery, line: []const u8, entry_index: usize, mode: CaseMode, normalize_enabled: bool, scheme: Scheme, algorithm: Algorithm) ?CandidateScore {
    if (parsed.terms.len == 0) return .{};
    var total: CandidateScore = .{ .rune_offsets = fuzzy_engine.cliTextHasNonAscii(line) and std.unicode.utf8ValidateSlice(line) };
    var clause: usize = 0;
    while (clause < parsed.clause_count) : (clause += 1) {
        var matched = false;
        var contribution: ?fuzzy_engine.CliMatch = null;
        for (parsed.terms) |term| {
            if (term.clause != clause) continue;
            const term_match = scoreTerm(index, term, line, entry_index, mode, normalize_enabled, scheme, algorithm);
            if (term_match) |value| {
                if (term.inverse) continue;
                contribution = value;
                matched = true;
                break;
            } else if (term.inverse) {
                contribution = null;
                matched = true;
                // fzf keeps checking later OR alternatives, allowing a later
                // positive term to contribute its score and offsets.
                continue;
            }
        }
        if (!matched) return null;
        if (contribution) |value| total.add(value);
    }
    return total;
}

fn scoreTerm(index: *fuzzy.Index, term: QueryTerm, line: []const u8, entry_index: usize, mode: CaseMode, normalize_enabled: bool, scheme: Scheme, algorithm: Algorithm) ?fuzzy_engine.CliMatch {
    const sensitive = termCaseSensitive(mode, term.text);
    const normalize = fuzzy_engine.cliNormalizeTerm(term.text, normalize_enabled);
    const cli_scheme: fuzzy_engine.CliScheme = switch (scheme) {
        .default => .default,
        .path => .path,
        .history => .history,
    };
    const unicode_path = (fuzzy_engine.cliTextHasNonAscii(term.text) or fuzzy_engine.cliTextHasNonAscii(line)) and
        std.unicode.utf8ValidateSlice(term.text) and std.unicode.utf8ValidateSlice(line);
    if (unicode_path) return switch (term.kind) {
        .fuzzy => if (algorithm == .v1)
            fuzzy_engine.matchFuzzyUnicodeV1ForCliScheme(index, term.text, line, sensitive, normalize, cli_scheme)
        else
            fuzzy_engine.matchFuzzyUnicodeForCliScheme(index, term.text, line, sensitive, normalize, cli_scheme),
        .exact => fuzzy_engine.scoreExactUnicodeForCliScheme(index, term.text, line, sensitive, normalize, false, cli_scheme),
        .boundary_exact => fuzzy_engine.scoreExactUnicodeForCliScheme(index, term.text, line, sensitive, normalize, true, cli_scheme),
        .prefix => fuzzy_engine.scorePrefixUnicodeForCliScheme(index, term.text, line, sensitive, normalize, cli_scheme),
        .suffix => fuzzy_engine.scoreSuffixUnicodeForCliScheme(index, term.text, line, sensitive, normalize, cli_scheme),
        .equal => fuzzy_engine.scoreEqualUnicodeForCliScheme(index, term.text, line, sensitive, normalize, cli_scheme),
    };
    return switch (term.kind) {
        .fuzzy => switch (algorithm) {
            .v2 => fuzzy_engine.matchFuzzyForCliScheme(index, term.text, line, entry_index, sensitive, cli_scheme),
            .v1 => fuzzy_engine.matchFuzzyV1ForCliScheme(index, term.text, line, entry_index, sensitive, cli_scheme),
            .heuristic => fuzzy_engine.matchFuzzyForCliScheme(index, term.text, line, entry_index, sensitive, cli_scheme),
        },
        .exact => fuzzy_engine.scoreExactForCliScheme(index, term.text, line, entry_index, sensitive, false, cli_scheme),
        .boundary_exact => fuzzy_engine.scoreExactForCliScheme(index, term.text, line, entry_index, sensitive, true, cli_scheme),
        .prefix => fuzzy_engine.scorePrefixForCliScheme(index, term.text, line, entry_index, sensitive, cli_scheme),
        .suffix => fuzzy_engine.scoreSuffixForCliScheme(index, term.text, line, entry_index, sensitive, cli_scheme),
        .equal => fuzzy_engine.scoreEqualForCliScheme(index, term.text, line, entry_index, sensitive, cli_scheme),
    };
}

const RawTermPlan = struct {
    term: QueryTerm,
    sensitive: bool,
    normalize: bool,
    has_non_ascii: bool,
    valid_utf8: bool,
};

const RawQueryPlan = struct {
    parsed: ParsedQuery,
    terms: []const RawTermPlan,
    cli_scheme: fuzzy_engine.CliScheme,
    algorithm: Algorithm,
    simple_positive: bool,
    query_has_valid_non_ascii: bool,
    ascii_fuzzy_needs_scratch: bool,
    max_term_bytes: usize,
};

fn prepareRawQuery(
    parsed: ParsedQuery,
    mode: CaseMode,
    normalize_enabled: bool,
    scheme: Scheme,
    algorithm: Algorithm,
    storage: *[512]RawTermPlan,
) RawQueryPlan {
    var query_has_valid_non_ascii = false;
    var ascii_fuzzy_needs_scratch = false;
    var max_term_bytes: usize = 0;
    for (parsed.terms, 0..) |term, i| {
        max_term_bytes = @max(max_term_bytes, term.text.len);
        const has_non_ascii = fuzzy_engine.cliTextHasNonAscii(term.text);
        const valid_utf8 = std.unicode.utf8ValidateSlice(term.text);
        storage[i] = .{
            .term = term,
            .sensitive = termCaseSensitive(mode, term.text),
            .normalize = fuzzy_engine.cliNormalizeTerm(term.text, normalize_enabled),
            .has_non_ascii = has_non_ascii,
            .valid_utf8 = valid_utf8,
        };
        query_has_valid_non_ascii = query_has_valid_non_ascii or (has_non_ascii and valid_utf8);
        ascii_fuzzy_needs_scratch = ascii_fuzzy_needs_scratch or
            (term.kind == .fuzzy and algorithm != .v1 and term.text.len > 6 and term.text.len <= 1000);
    }
    return .{
        .parsed = parsed,
        .terms = storage[0..parsed.terms.len],
        .cli_scheme = switch (scheme) {
            .default => .default,
            .path => .path,
            .history => .history,
        },
        .algorithm = algorithm,
        .simple_positive = parsed.terms.len == 1 and parsed.clause_count == 1 and !parsed.terms[0].inverse,
        .query_has_valid_non_ascii = query_has_valid_non_ascii,
        .ascii_fuzzy_needs_scratch = ascii_fuzzy_needs_scratch,
        .max_term_bytes = max_term_bytes,
    };
}

fn scoreSimplePositiveCandidateRaw(
    scratch: *fuzzy_engine.CliScratch,
    plan: RawQueryPlan,
    line: []const u8,
) std.mem.Allocator.Error!?CandidateScore {
    const line_has_non_ascii = fuzzy_engine.cliTextHasNonAscii(line);
    const line_valid_utf8 = !line_has_non_ascii or std.unicode.utf8ValidateSlice(line);
    if (line_has_non_ascii or plan.query_has_valid_non_ascii or plan.ascii_fuzzy_needs_scratch)
        try scratch.ensure(@max(line.len, plan.max_term_bytes));

    const term_plan = plan.terms[0];
    // The overwhelmingly common lazy query is one positive ASCII fuzzy term.
    // For an ASCII candidate this can go straight to the raw V2/heuristic
    // scorer; the generic dispatcher otherwise carries every Unicode and
    // exact-mode branch in one large function. Preserve the generic path for
    // non-ASCII/invalid-UTF8 candidates and V1 exactly as before.
    const matched: fuzzy_engine.CliMatch = if (!line_has_non_ascii and !term_plan.has_non_ascii and term_plan.term.kind == .fuzzy and plan.algorithm != .v1)
        (fuzzy_engine.matchFuzzyRawForCliScheme(scratch, term_plan.term.text, line, term_plan.sensitive, plan.cli_scheme) orelse return null)
    else
        (scoreTermRaw(scratch, term_plan, line, line_has_non_ascii, line_valid_utf8, plan.cli_scheme, plan.algorithm) orelse return null);
    var total: CandidateScore = .{ .rune_offsets = line_has_non_ascii and line_valid_utf8 };
    total.add(matched);
    return total;
}

fn scoreSimplePositiveCandidateRawKnownAscii(
    scratch: *fuzzy_engine.CliScratch,
    plan: RawQueryPlan,
    line: []const u8,
) std.mem.Allocator.Error!?CandidateScore {
    const term_plan = plan.terms[0];
    if (plan.query_has_valid_non_ascii or plan.ascii_fuzzy_needs_scratch)
        try scratch.ensure(@max(line.len, plan.max_term_bytes));
    const matched: fuzzy_engine.CliMatch = if (!term_plan.has_non_ascii and term_plan.term.kind == .fuzzy and plan.algorithm != .v1)
        (fuzzy_engine.matchFuzzyRawForCliScheme(scratch, term_plan.term.text, line, term_plan.sensitive, plan.cli_scheme) orelse return null)
    else
        (scoreTermRaw(scratch, term_plan, line, false, true, plan.cli_scheme, plan.algorithm) orelse return null);
    var total: CandidateScore = .{};
    total.add(matched);
    return total;
}

fn scoreParsedCandidateRaw(
    scratch: *fuzzy_engine.CliScratch,
    plan: RawQueryPlan,
    line: []const u8,
) std.mem.Allocator.Error!?CandidateScore {
    if (plan.terms.len == 0) return .{};
    if (plan.simple_positive) return scoreSimplePositiveCandidateRaw(scratch, plan, line);
    const line_has_non_ascii = fuzzy_engine.cliTextHasNonAscii(line);
    const line_valid_utf8 = !line_has_non_ascii or std.unicode.utf8ValidateSlice(line);
    if (line_has_non_ascii or plan.query_has_valid_non_ascii or plan.ascii_fuzzy_needs_scratch)
        try scratch.ensure(@max(line.len, plan.max_term_bytes));

    var total: CandidateScore = .{ .rune_offsets = line_has_non_ascii and line_valid_utf8 };

    var clause: usize = 0;
    while (clause < plan.parsed.clause_count) : (clause += 1) {
        var matched = false;
        var contribution: ?fuzzy_engine.CliMatch = null;
        for (plan.terms) |term_plan| {
            const term = term_plan.term;
            if (term.clause != clause) continue;
            const term_match = scoreTermRaw(scratch, term_plan, line, line_has_non_ascii, line_valid_utf8, plan.cli_scheme, plan.algorithm);
            if (term_match) |value| {
                if (term.inverse) continue;
                contribution = value;
                matched = true;
                break;
            } else if (term.inverse) {
                contribution = null;
                matched = true;
                continue;
            }
        }
        if (!matched) return null;
        if (contribution) |value| total.add(value);
    }
    return total;
}

fn scoreTermRaw(
    scratch: *fuzzy_engine.CliScratch,
    plan: RawTermPlan,
    line: []const u8,
    line_has_non_ascii: bool,
    line_valid_utf8: bool,
    cli_scheme: fuzzy_engine.CliScheme,
    algorithm: Algorithm,
) ?fuzzy_engine.CliMatch {
    const term = plan.term;
    const unicode_path = (plan.has_non_ascii or line_has_non_ascii) and plan.valid_utf8 and line_valid_utf8;
    if (unicode_path) return switch (term.kind) {
        .fuzzy => if (algorithm == .v1)
            fuzzy_engine.matchFuzzyUnicodeV1RawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, cli_scheme)
        else
            fuzzy_engine.matchFuzzyUnicodeRawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, cli_scheme),
        .exact => fuzzy_engine.scoreExactUnicodeRawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, false, cli_scheme),
        .boundary_exact => fuzzy_engine.scoreExactUnicodeRawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, true, cli_scheme),
        .prefix => fuzzy_engine.scorePrefixUnicodeRawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, cli_scheme),
        .suffix => fuzzy_engine.scoreSuffixUnicodeRawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, cli_scheme),
        .equal => fuzzy_engine.scoreEqualUnicodeRawForCliScheme(scratch, term.text, line, plan.sensitive, plan.normalize, cli_scheme),
    };
    return switch (term.kind) {
        .fuzzy => if (algorithm == .v1)
            fuzzy_engine.matchFuzzyV1RawForCliScheme(term.text, line, plan.sensitive, cli_scheme)
        else
            fuzzy_engine.matchFuzzyRawForCliScheme(scratch, term.text, line, plan.sensitive, cli_scheme),
        .exact => fuzzy_engine.scoreExactRawForCliScheme(term.text, line, plan.sensitive, false, cli_scheme),
        .boundary_exact => fuzzy_engine.scoreExactRawForCliScheme(term.text, line, plan.sensitive, true, cli_scheme),
        .prefix => fuzzy_engine.scorePrefixRawForCliScheme(term.text, line, plan.sensitive, cli_scheme),
        .suffix => fuzzy_engine.scoreSuffixRawForCliScheme(term.text, line, plan.sensitive, cli_scheme),
        .equal => fuzzy_engine.scoreEqualRawForCliScheme(term.text, line, plan.sensitive, cli_scheme),
    };
}

const LazySearchConfig = struct {
    extended: bool,
    exact: bool,
    case_mode: CaseMode,
    literal: bool,
    scheme: Scheme,
    algorithm: Algorithm,
    no_sort: bool,
    tiebreaks: [3]TieBreak,
    tiebreak_count: u2,
    disabled: bool,

    fn fromOptions(options: *const Options) LazySearchConfig {
        return .{
            .extended = options.extended,
            .exact = options.exact,
            .case_mode = options.case_mode,
            .literal = options.literal,
            .scheme = options.scheme,
            .algorithm = options.algorithm,
            .no_sort = options.no_sort,
            .tiebreaks = options.tiebreaks,
            .tiebreak_count = options.tiebreak_count,
            .disabled = options.disabled,
        };
    }

    fn parseOptions(self: LazySearchConfig) Options {
        var out: Options = .{};
        out.extended = self.extended;
        out.exact = self.exact;
        out.case_mode = self.case_mode;
        out.literal = self.literal;
        out.scheme = self.scheme;
        out.algorithm = self.algorithm;
        out.no_sort = self.no_sort;
        out.tiebreaks = self.tiebreaks;
        out.tiebreak_count = self.tiebreak_count;
        out.disabled = self.disabled;
        return out;
    }
};

const LazyRank = struct {
    record: compact_store.RecordRef,
    score: CandidateScore,
    tiebreak_values: [3]u32 = .{ 0, 0, 0 },
};

const LazyRankContext = struct {
    config: LazySearchConfig,
};

const LazyFrontierPage = struct {
    page_index: usize,
    record_count: u32,
    stores_matches: bool = true,
    sparse_mode: bool = false,
    bits: []u64 = &.{},
    sparse: []compact_store.RecordRef = &.{},

    fn deinit(self: *LazyFrontierPage, allocator: Allocator) void {
        if (self.sparse_mode) {
            if (self.sparse.len != 0) allocator.free(self.sparse);
        } else if (self.bits.len != 0) allocator.free(self.bits);
        self.* = undefined;
    }
};

const LazyShardFrontier = struct {
    allocator: Allocator,
    query: []u8,
    config: LazySearchConfig,
    sensitive: bool,
    normalize: bool,
    snapshot_count: u32,
    pages: []LazyFrontierPage,

    fn deinit(self: *LazyShardFrontier) void {
        for (self.pages) |*page| page.deinit(self.allocator);
        self.allocator.free(self.pages);
        self.allocator.free(self.query);
        self.* = undefined;
    }
};

const LazyShardCache = struct {
    entries: [lazy_frontier_depth]?LazyShardFrontier = @splat(null),
    next_slot: usize = 0,

    fn deinit(self: *LazyShardCache) void {
        for (&self.entries) |*entry| if (entry.*) |*frontier| frontier.deinit();
        self.* = .{};
    }

    fn store(self: *LazyShardCache, frontier: LazyShardFrontier) void {
        if (self.entries[self.next_slot]) |*old| old.deinit();
        self.entries[self.next_slot] = frontier;
        self.next_slot = (self.next_slot + 1) % lazy_frontier_depth;
    }
};

fn lazyRawPlanCacheable(query: []const u8, raw_plan: RawQueryPlan) bool {
    if (!raw_plan.simple_positive or raw_plan.terms.len != 1) return false;
    const term = raw_plan.terms[0];
    return term.term.kind == .fuzzy and !term.term.inverse and !term.has_non_ascii and !fuzzy_engine.cliTextHasNonAscii(query);
}

fn lazyFrontierCanRefine(frontier: *const LazyShardFrontier, query: []const u8, config: LazySearchConfig, raw_plan: RawQueryPlan, snapshot_count: u32) bool {
    if (frontier.snapshot_count > snapshot_count) return false;
    if (!std.meta.eql(frontier.config, config)) return false;
    if (!lazyRawPlanCacheable(query, raw_plan)) return false;
    const term = raw_plan.terms[0];
    if (fuzzy_engine.cliTextHasNonAscii(frontier.query)) return false;
    if (frontier.sensitive != term.sensitive or frontier.normalize != term.normalize) return false;
    if (frontier.query.len > query.len) return false;
    return std.mem.startsWith(u8, query, frontier.query);
}

fn lazyBestFrontier(cache: *const LazyShardCache, query: []const u8, config: LazySearchConfig, raw_plan: RawQueryPlan, snapshot_count: u32) ?*const LazyShardFrontier {
    var best: ?*const LazyShardFrontier = null;
    for (&cache.entries) |*entry| {
        const frontier = if (entry.*) |*value| value else continue;
        if (!lazyFrontierCanRefine(frontier, query, config, raw_plan, snapshot_count)) continue;
        if (best == null or frontier.query.len > best.?.query.len) best = frontier;
    }
    return best;
}

fn lazyBestFrontierPage(cache: *const LazyShardCache, query: []const u8, config: LazySearchConfig, raw_plan: RawQueryPlan, snapshot_count: u32, page_index: usize) ?LazyFrontierPage {
    var best_page: ?LazyFrontierPage = null;
    var best_query_len: usize = 0;
    for (&cache.entries) |*entry| {
        const frontier = if (entry.*) |*value| value else continue;
        if (!lazyFrontierCanRefine(frontier, query, config, raw_plan, snapshot_count)) continue;
        var candidate_page: ?LazyFrontierPage = null;
        for (frontier.pages) |page| {
            if (page.page_index < page_index) continue;
            if (page.page_index == page_index) candidate_page = page;
            break;
        }
        const page = candidate_page orelse continue;
        if (best_page == null or frontier.query.len > best_query_len or
            (frontier.query.len == best_query_len and page.record_count > best_page.?.record_count))
        {
            best_page = page;
            best_query_len = frontier.query.len;
        }
    }
    return best_page;
}

fn lazyFrontierBitSet(page: LazyFrontierPage, local_index: u32) bool {
    if (page.sparse_mode or local_index >= page.record_count) return false;
    const word: usize = @intCast(local_index / 64);
    const bit: u6 = @intCast(local_index % 64);
    return (page.bits[word] & (@as(u64, 1) << bit)) != 0;
}

fn lazySetFrontierBit(bits: []u64, local_index: u32) void {
    const word: usize = @intCast(local_index / 64);
    const bit: u6 = @intCast(local_index % 64);
    bits[word] |= @as(u64, 1) << bit;
}

fn lazyCacheStoresMatches(matches: u32, scanned: u32) bool {
    if (scanned == 0) return true;
    return @as(u64, matches) * 2 <= scanned;
}

fn lazyCacheStoresSparse(matches: u32, scanned: u32) bool {
    return scanned != 0 and @as(u64, matches) * 128 <= scanned;
}

fn lazyFrontierCanSkip(page: LazyFrontierPage, local_index: u32) bool {
    if (page.sparse_mode or local_index >= page.record_count) return false;
    const set = lazyFrontierBitSet(page, local_index);
    return if (page.stores_matches) !set else set;
}

fn prepareLazyRankTiebreaks(ctx: LazyRankContext, rank: *LazyRank) void {
    var i: usize = 0;
    while (i < ctx.config.tiebreak_count) : (i += 1) {
        const value = tiebreakValue(ctx.config.tiebreaks[i], rank.record.text(), rank.score);
        rank.tiebreak_values[i] = if (value == std.math.maxInt(usize))
            std.math.maxInt(u32)
        else
            @intCast(value);
    }
}

fn betterLazyRank(ctx: LazyRankContext, a: LazyRank, b: LazyRank) bool {
    if (a.score.score != b.score.score) return a.score.score > b.score.score;
    var i: usize = 0;
    while (i < ctx.config.tiebreak_count) : (i += 1) {
        const av = a.tiebreak_values[i];
        const bv = b.tiebreak_values[i];
        if (av != bv) return av < bv;
    }
    return a.record.id < b.record.id;
}

fn lazySiftWorst(heap: []LazyRank, ctx: LazyRankContext, start: usize) void {
    var parent = start;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= heap.len) break;
        const right = left + 1;
        var worse_child = left;
        if (right < heap.len and betterLazyRank(ctx, heap[left], heap[right])) worse_child = right;
        if (!betterLazyRank(ctx, heap[parent], heap[worse_child])) break;
        std.mem.swap(LazyRank, &heap[parent], &heap[worse_child]);
        parent = worse_child;
    }
}

fn lazyHeapifyWorst(heap: []LazyRank, ctx: LazyRankContext) void {
    var parent = heap.len / 2;
    while (parent != 0) {
        parent -= 1;
        lazySiftWorst(heap, ctx, parent);
    }
}

const LazyResult = struct {
    allocator: Allocator,
    generation: u64,
    ranks: []LazyRank,
    total_count: u32,
    match_count: u32,
    scanned_count: u32,
    input_finished: bool,
    search_complete: bool,

    fn deinit(self: *LazyResult) void {
        self.allocator.free(self.ranks);
        self.allocator.destroy(self);
    }
};

const LazyPending = struct {
    generation: u64,
    query: []u8,
    config: LazySearchConfig,
    top_k: usize,
};

const LazyActive = struct {
    generation: u64,
    query: []u8,
    config: LazySearchConfig,
    top_k: usize,
    scanned_count: u32 = 0,
    match_count: u32 = 0,
    published_partial: bool = false,
    ranks: std.ArrayList(LazyRank) = .empty,

    fn deinit(self: *LazyActive, allocator: Allocator) void {
        allocator.free(self.query);
        self.ranks.deinit(allocator);
        self.* = undefined;
    }
};

const LazyBackend = struct {
    allocator: Allocator,
    io: Io,
    store: compact_store.Store,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    stop: std.atomic.Value(bool) = .init(false),
    latest_generation: std.atomic.Value(u64) = .init(0),
    data_epoch: u64 = 0,
    pending: ?LazyPending = null,
    result: ?*LazyResult = null,
    search_thread: ?std.Thread = null,
    source_thread: ?std.Thread = null,
    source_child_pgid: std.atomic.Value(i64) = .init(0),
    source_options: ?*const Options = null,
    source_command: ?[]u8 = null,
    source_kind: enum { none, stdin, walker, command } = .none,
    ui_wake_fd: i32 = -1,
    worker_count: usize = 1,
    shard_caches: []LazyShardCache = &.{},

    fn create(allocator: Allocator, io: Io) !*LazyBackend {
        const self = try allocator.create(LazyBackend);
        const worker_count = lazyDefaultWorkerCount();
        const shard_caches = try allocator.alloc(LazyShardCache, worker_count);
        errdefer allocator.free(shard_caches);
        for (shard_caches) |*cache| cache.* = .{};
        self.* = .{
            .allocator = allocator,
            .io = io,
            .store = compact_store.Store.init(allocator, io),
            .worker_count = worker_count,
            .shard_caches = shard_caches,
        };
        if (comptime builtin.os.tag == .linux) {
            const fd = std.c.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
            if (fd >= 0) self.ui_wake_fd = fd;
        }
        errdefer {
            if (comptime builtin.os.tag == .linux) {
                if (self.ui_wake_fd >= 0) _ = std.c.close(self.ui_wake_fd);
            }
            self.store.deinit();
            allocator.destroy(self);
        }
        self.search_thread = try std.Thread.spawn(.{}, lazySearchThread, .{self});
        return self;
    }

    fn destroy(self: *LazyBackend) void {
        self.stop.store(true, .release);
        const pgid = self.source_child_pgid.load(.acquire);
        if (pgid != 0 and builtin.os.tag != .windows and builtin.os.tag != .wasi) killBackgroundProcessGroup(pgid);
        if (self.source_kind == .stdin and !self.store.isFinished() and builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            _ = std.c.close(std.posix.STDIN_FILENO);
        }
        self.mutex.lockUncancelable(self.io);
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.source_thread) |thread| thread.join();
        if (self.search_thread) |thread| thread.join();
        if (comptime builtin.os.tag == .linux) {
            if (self.ui_wake_fd >= 0) _ = std.c.close(self.ui_wake_fd);
        }
        if (self.pending) |pending| self.allocator.free(pending.query);
        if (self.result) |result| result.deinit();
        if (self.source_command) |command| self.allocator.free(command);
        for (self.shard_caches) |*cache| cache.deinit();
        self.allocator.free(self.shard_caches);
        self.store.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn startSource(self: *LazyBackend, options: *const Options, stdin_is_tty: bool, default_command: ?[]const u8) !void {
        self.source_options = options;
        if (!stdin_is_tty) {
            self.source_kind = .stdin;
        } else if (default_command) |command| {
            if (command.len == 0) {
                self.source_kind = .walker;
            } else {
                self.source_kind = .command;
                self.source_command = try self.allocator.dupe(u8, command);
            }
        } else {
            self.source_kind = .walker;
        }
        self.source_thread = try std.Thread.spawn(.{}, lazySourceThread, .{self});
    }

    fn submit(self: *LazyBackend, query: []const u8, options: *const Options, top_k: usize) !u64 {
        const owned = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending) |pending| self.allocator.free(pending.query);
        const generation = self.latest_generation.load(.monotonic) +% 1;
        // A result that was published before this submit is stale by
        // definition. Drop it here so consumers never have to drain an old
        // generation after the new generation has been announced.
        if (self.result) |old_result| {
            old_result.deinit();
            self.result = null;
        }
        self.pending = .{
            .generation = generation,
            .query = owned,
            .config = .fromOptions(options),
            .top_k = @max(@as(usize, 1), top_k),
        };
        self.latest_generation.store(generation, .release);
        self.condition.signal(self.io);
        return generation;
    }

    fn notifyData(self: *LazyBackend) void {
        self.mutex.lockUncancelable(self.io);
        self.data_epoch +%= 1;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn finishInput(self: *LazyBackend) void {
        self.store.markFinished();
        self.notifyData();
    }

    fn wakeUi(self: *LazyBackend) void {
        if (comptime builtin.os.tag != .linux) return;
        if (self.ui_wake_fd < 0) return;
        var one: u64 = 1;
        // Nonblocking eventfd: EAGAIN only means a wake is already pending.
        _ = std.c.write(self.ui_wake_fd, @ptrCast(&one), @sizeOf(u64));
    }

    fn takeResult(self: *LazyBackend) ?*LazyResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result;
        self.result = null;
        return result;
    }

    fn takePending(self: *LazyBackend) ?LazyPending {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    fn waitForWork(self: *LazyBackend, seen_epoch: *u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.stop.load(.acquire) and self.pending == null and self.data_epoch == seen_epoch.*) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        seen_epoch.* = self.data_epoch;
    }

    fn publish(self: *LazyBackend, active: *const LazyActive, total_count: u32, input_finished: bool, search_complete: bool) !void {
        if (self.latest_generation.load(.acquire) != active.generation) return;
        const ranks = try self.allocator.alloc(LazyRank, active.ranks.items.len);
        @memcpy(ranks, active.ranks.items);
        // betterLazyRank has a total order (record id is the final tie-break),
        // so stable ordering cannot affect observable ranking. PDQ avoids the
        // substantially heavier stable block-sort on every partial publish.
        if (!active.config.no_sort) std.mem.sortUnstable(LazyRank, ranks, LazyRankContext{ .config = active.config }, betterLazyRank);
        const result = try self.allocator.create(LazyResult);
        errdefer self.allocator.destroy(result);
        result.* = .{
            .allocator = self.allocator,
            .generation = active.generation,
            .ranks = ranks,
            .total_count = total_count,
            .match_count = active.match_count,
            .scanned_count = active.scanned_count,
            .input_finished = input_finished,
            .search_complete = search_complete,
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.latest_generation.load(.acquire) != active.generation) {
            result.deinit();
            return;
        }
        if (self.result) |old| old.deinit();
        self.result = result;
        self.wakeUi();
    }
};

fn lazyInsertRank(active: *LazyActive, allocator: Allocator, incoming: LazyRank, sortable: bool) !void {
    var rank = incoming;
    if (active.ranks.items.len < active.top_k) {
        if (active.ranks.items.len == 0 and active.ranks.capacity < active.top_k)
            try active.ranks.ensureTotalCapacity(allocator, active.top_k);
        if (sortable) prepareLazyRankTiebreaks(.{ .config = active.config }, &rank);
        try active.ranks.append(allocator, rank);
        if (sortable and active.ranks.items.len == active.top_k)
            lazyHeapifyWorst(active.ranks.items, .{ .config = active.config });
        return;
    }
    if (!sortable) return;

    const worst = active.ranks.items[0];
    if (rank.score.score < worst.score.score) return;
    const ctx = LazyRankContext{ .config = active.config };
    prepareLazyRankTiebreaks(ctx, &rank);
    if (betterLazyRank(ctx, rank, worst)) {
        active.ranks.items[0] = rank;
        lazySiftWorst(active.ranks.items, ctx, 0);
    }
}

const LazyShardWorker = struct {
    allocator: Allocator,
    snapshot: *const compact_store.Snapshot,
    raw_plan: RawQueryPlan,
    config: LazySearchConfig,
    latest_generation: *const std.atomic.Value(u64),
    stop: *const std.atomic.Value(bool),
    generation: u64,
    top_k: usize,
    shard_index: usize,
    shard_count: usize,
    sortable: bool,
    cache_frontier: bool,
    cache_matches: bool,
    cache_sparse: bool,
    query: []const u8,
    reuse_cache: ?*const LazyShardCache = null,
    match_count: u32 = 0,
    ranks: std.ArrayList(LazyRank) = .empty,
    frontier_pages: std.ArrayList(LazyFrontierPage) = .empty,
    failed: bool = false,
    canceled: bool = false,
    completed: bool = false,

    fn deinit(self: *LazyShardWorker) void {
        self.ranks.deinit(self.allocator);
        for (self.frontier_pages.items) |*page| page.deinit(self.allocator);
        self.frontier_pages.deinit(self.allocator);
    }
};

fn lazyShardInsertRank(worker: *LazyShardWorker, incoming: LazyRank) !void {
    var rank = incoming;
    if (worker.ranks.items.len < worker.top_k) {
        if (worker.sortable) prepareLazyRankTiebreaks(.{ .config = worker.config }, &rank);
        try worker.ranks.append(worker.allocator, rank);
        if (worker.sortable and worker.ranks.items.len == worker.top_k)
            lazyHeapifyWorst(worker.ranks.items, .{ .config = worker.config });
        return;
    }
    if (!worker.sortable) return;
    const worst = worker.ranks.items[0];
    if (rank.score.score < worst.score.score) return;
    const ctx = LazyRankContext{ .config = worker.config };
    prepareLazyRankTiebreaks(ctx, &rank);
    if (betterLazyRank(ctx, rank, worst)) {
        worker.ranks.items[0] = rank;
        lazySiftWorst(worker.ranks.items, ctx, 0);
    }
}

const LazyPageFrontierBuilder = struct {
    allocator: Allocator,
    page_index: usize,
    page_base: u32,
    record_count: u32,
    mode: enum { none, bits, sparse } = .none,
    stores_matches: bool = true,
    bits: []u64 = &.{},
    sparse: std.ArrayList(compact_store.RecordRef) = .empty,
    sparse_limit: usize = 0,

    fn init(worker: *const LazyShardWorker, page_index: usize, page_base: u32, record_count: u32, force_sparse: bool) !LazyPageFrontierBuilder {
        var self = LazyPageFrontierBuilder{
            .allocator = worker.allocator,
            .page_index = page_index,
            .page_base = page_base,
            .record_count = record_count,
            .stores_matches = worker.cache_matches,
        };
        if (!worker.cache_frontier) return self;
        const words: usize = @intCast((record_count + 63) / 64);
        if (worker.cache_sparse or force_sparse) {
            self.mode = .sparse;
            self.sparse_limit = (words * @sizeOf(u64)) / @sizeOf(compact_store.RecordRef);
        } else {
            self.mode = .bits;
            self.bits = try worker.allocator.alloc(u64, words);
            @memset(self.bits, 0);
        }
        return self;
    }

    fn deinit(self: *LazyPageFrontierBuilder) void {
        if (self.bits.len != 0) self.allocator.free(self.bits);
        self.sparse.deinit(self.allocator);
        self.* = undefined;
    }

    fn observe(self: *LazyPageFrontierBuilder, record: compact_store.RecordRef, matched: bool) !void {
        switch (self.mode) {
            .none => {},
            .bits => if (matched == self.stores_matches) {
                lazySetFrontierBit(self.bits, record.id - self.page_base);
            },
            .sparse => if (matched) {
                if (self.sparse.items.len >= self.sparse_limit) {
                    self.sparse.deinit(self.allocator);
                    self.sparse = .empty;
                    self.mode = .none;
                    return;
                }
                try self.sparse.append(self.allocator, record);
            },
        }
    }

    fn finish(self: *LazyPageFrontierBuilder, worker: *LazyShardWorker) !void {
        switch (self.mode) {
            .none => {},
            .bits => {
                const bits = self.bits;
                self.bits = &.{};
                errdefer if (bits.len != 0) self.allocator.free(bits);
                try worker.frontier_pages.append(worker.allocator, .{
                    .page_index = self.page_index,
                    .record_count = self.record_count,
                    .stores_matches = self.stores_matches,
                    .bits = bits,
                });
            },
            .sparse => {
                const refs = try self.sparse.toOwnedSlice(self.allocator);
                errdefer if (refs.len != 0) self.allocator.free(refs);
                try worker.frontier_pages.append(worker.allocator, .{
                    .page_index = self.page_index,
                    .record_count = self.record_count,
                    .sparse_mode = true,
                    .sparse = refs,
                });
            },
        }
        self.mode = .none;
    }
};

fn lazyShardCheckCanceled(worker: *LazyShardWorker) bool {
    if (worker.stop.load(.acquire) or worker.latest_generation.load(.acquire) != worker.generation) {
        worker.canceled = true;
        return true;
    }
    return false;
}

fn lazyShardScoreRecord(worker: *LazyShardWorker, scratch: *fuzzy_engine.CliScratch, builder: *LazyPageFrontierBuilder, record: compact_store.RecordRef) bool {
    const scored = (if (worker.snapshot.all_ascii and worker.raw_plan.simple_positive)
        scoreSimplePositiveCandidateRawKnownAscii(scratch, worker.raw_plan, record.text())
    else
        scoreParsedCandidateRaw(scratch, worker.raw_plan, record.text())) catch {
        worker.failed = true;
        return false;
    };
    builder.observe(record, scored != null) catch {
        worker.failed = true;
        return false;
    };
    if (scored) |score| {
        worker.match_count +%= 1;
        lazyShardInsertRank(worker, .{ .record = record, .score = score }) catch {
            worker.failed = true;
            return false;
        };
    }
    return true;
}

fn lazyShardScanWorker(worker: *LazyShardWorker) Io.Cancelable!void {
    var scratch = fuzzy_engine.CliScratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    var page_index = worker.shard_index;
    while (page_index < worker.snapshot.pageCount()) : (page_index += worker.shard_count) {
        if (lazyShardCheckCanceled(worker)) return;
        const page_base = worker.snapshot.pageBaseId(page_index);
        const page_count = worker.snapshot.pageRecordCount(page_index);
        const end_id = page_base + page_count;
        const reuse_page = if (worker.reuse_cache) |cache|
            lazyBestFrontierPage(cache, worker.query, worker.config, worker.raw_plan, worker.snapshot.count, page_index)
        else
            null;
        var builder = LazyPageFrontierBuilder.init(worker, page_index, page_base, page_count, if (reuse_page) |page| page.sparse_mode else false) catch {
            worker.failed = true;
            return;
        };
        defer builder.deinit();

        if (reuse_page) |page| sparse: {
            if (!page.sparse_mode) break :sparse;
            var since_cancel_check: usize = 0;
            for (page.sparse) |record| {
                since_cancel_check += 1;
                if (since_cancel_check >= 256) {
                    since_cancel_check = 0;
                    if (lazyShardCheckCanceled(worker)) return;
                }
                if (!lazyShardScoreRecord(worker, &scratch, &builder, record)) return;
            }
            // A cached tail page may have grown after the frontier was built.
            // Direct refs cover the immutable prefix; only the appended suffix
            // must be decoded from compact storage.
            if (page.record_count < page_count) {
                var iterator = worker.snapshot.iteratorFrom(page_base + page.record_count);
                while (iterator.next()) |record| {
                    if (record.id >= end_id) break;
                    since_cancel_check += 1;
                    if (since_cancel_check >= 256) {
                        since_cancel_check = 0;
                        if (lazyShardCheckCanceled(worker)) return;
                    }
                    if (!lazyShardScoreRecord(worker, &scratch, &builder, record)) return;
                }
            }
            builder.finish(worker) catch {
                worker.failed = true;
                return;
            };
            continue;
        }

        var iterator = worker.snapshot.pageIterator(page_index);
        var since_cancel_check: usize = 0;
        while (iterator.next()) |record| {
            if (record.id >= end_id) break;
            since_cancel_check += 1;
            if (since_cancel_check >= 256) {
                since_cancel_check = 0;
                if (lazyShardCheckCanceled(worker)) return;
            }
            if (reuse_page) |page| {
                // Cached nonmatches in the covered prefix cannot match a
                // monotone refinement. Observe the rejection so a rejection-
                // oriented output bitmap can preserve it without rescoring.
                if (lazyFrontierCanSkip(page, record.id - page_base)) {
                    builder.observe(record, false) catch {
                        worker.failed = true;
                        return;
                    };
                    continue;
                }
            }
            if (!lazyShardScoreRecord(worker, &scratch, &builder, record)) return;
        }
        // Only a fully processed page becomes reusable. Cancellation above
        // drops the builder, so a partial bitmap/ref vector is never exposed.
        builder.finish(worker) catch {
            worker.failed = true;
            return;
        };
    }
    worker.completed = true;
}

fn lazyMergeShardTopK(state: *LazyActive, allocator: Allocator, workers: []LazyShardWorker) bool {
    const ctx = LazyRankContext{ .config = state.config };
    for (workers) |*worker| std.mem.sortUnstable(LazyRank, worker.ranks.items, ctx, betterLazyRank);

    var sources: [lazy_max_workers][]const LazyRank = undefined;
    var offsets: [lazy_max_workers]usize = @splat(0);
    var source_count: usize = 0;
    for (workers) |*worker| {
        if (worker.ranks.items.len == 0) continue;
        sources[source_count] = worker.ranks.items;
        source_count += 1;
    }

    var merged: std.ArrayList(LazyRank) = .empty;
    errdefer merged.deinit(allocator);
    merged.ensureTotalCapacity(allocator, state.top_k) catch return false;
    while (merged.items.len < state.top_k) {
        var best_source: ?usize = null;
        var best: LazyRank = undefined;
        for (0..source_count) |source_index| {
            const at = offsets[source_index];
            if (at >= sources[source_index].len) continue;
            const candidate = sources[source_index][at];
            if (best_source == null or betterLazyRank(ctx, candidate, best)) {
                best_source = source_index;
                best = candidate;
            }
        }
        const source_index = best_source orelse break;
        merged.appendAssumeCapacity(best);
        offsets[source_index] += 1;
    }
    state.ranks.deinit(allocator);
    state.ranks = merged;
    return true;
}

fn lazyCommitShardFrontier(self: *LazyBackend, state: *const LazyActive, raw_plan: RawQueryPlan, snapshot_count: u32, worker: *LazyShardWorker) void {
    if (worker.frontier_pages.items.len == 0 or !lazyRawPlanCacheable(state.query, raw_plan)) return;
    const pages = worker.frontier_pages.toOwnedSlice(self.allocator) catch return;
    worker.frontier_pages = .empty;
    const query = self.allocator.dupe(u8, state.query) catch {
        for (pages) |*page| page.deinit(self.allocator);
        self.allocator.free(pages);
        return;
    };
    const term = raw_plan.terms[0];
    self.shard_caches[worker.shard_index].store(.{
        .allocator = self.allocator,
        .query = query,
        .config = state.config,
        .sensitive = term.sensitive,
        .normalize = term.normalize,
        .snapshot_count = snapshot_count,
        .pages = pages,
    });
}

fn lazyParallelScanCompletedCorpus(
    self: *LazyBackend,
    state: *LazyActive,
    snapshot: *const compact_store.Snapshot,
    raw_plan: RawQueryPlan,
    sortable: bool,
) bool {
    if (!snapshot.finished or !sortable) return false;
    if (snapshot.count < lazy_parallel_min_candidates) return false;
    // A full shard pass deliberately rechecks the tiny prefix used for the first
    // partial so every completed shard owns a complete reusable frontier. Avoid
    // doing that after a long streaming scan has already consumed the corpus.
    if (state.scanned_count > lazy_first_publish_max_scan_count) return false;
    if (self.worker_count < 2 or snapshot.pageCount() < 2) return false;

    const workers = self.allocator.alloc(LazyShardWorker, self.worker_count) catch return false;
    var initialized: usize = 0;
    defer {
        for (workers[0..initialized]) |*worker| worker.deinit();
        self.allocator.free(workers);
    }
    for (workers, 0..) |*worker, shard_index| {
        worker.* = .{
            .allocator = self.allocator,
            .snapshot = snapshot,
            .raw_plan = raw_plan,
            .config = state.config,
            .latest_generation = &self.latest_generation,
            .stop = &self.stop,
            .generation = state.generation,
            .top_k = state.top_k,
            .shard_index = shard_index,
            .shard_count = self.worker_count,
            .sortable = sortable,
            .cache_frontier = lazyRawPlanCacheable(state.query, raw_plan),
            .cache_matches = lazyCacheStoresMatches(state.match_count, state.scanned_count),
            .cache_sparse = lazyCacheStoresSparse(state.match_count, state.scanned_count),
            .query = state.query,
            .reuse_cache = &self.shard_caches[shard_index],
        };
        worker.ranks.ensureTotalCapacity(self.allocator, state.top_k) catch return false;
        initialized += 1;
    }

    var group: Io.Group = .init;
    for (workers) |*worker| group.concurrent(self.io, lazyShardScanWorker, .{worker}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => lazyShardScanWorker(worker) catch {},
    };
    group.await(self.io) catch return false;

    // A keypress may make the global generation stale while some shards have
    // already completed. Those completed frontiers are still exact for the old
    // query and are intentionally retained for monotone refinement by the next
    // generation. Canceled/incomplete shards commit nothing.
    for (workers) |*worker| lazyCommitShardFrontier(self, state, raw_plan, snapshot.count, worker);

    if (self.latest_generation.load(.acquire) != state.generation or self.stop.load(.acquire)) return false;
    for (workers) |*worker| if (worker.canceled or worker.failed or !worker.completed) return false;

    state.match_count = 0;
    for (workers) |*worker| state.match_count +%= worker.match_count;
    if (!lazyMergeShardTopK(state, self.allocator, workers)) return false;
    state.scanned_count = snapshot.count;
    return true;
}

fn lazySearchThread(self: *LazyBackend) void {
    var scratch = fuzzy_engine.CliScratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    var active: ?LazyActive = null;
    defer if (active) |*value| value.deinit(self.allocator);
    var seen_epoch: u64 = 0;

    while (!self.stop.load(.acquire)) {
        if (self.takePending()) |pending| {
            if (active) |*old| old.deinit(self.allocator);
            active = .{
                .generation = pending.generation,
                .query = pending.query,
                .config = pending.config,
                .top_k = pending.top_k,
            };
        }
        if (active == null) {
            self.waitForWork(&seen_epoch);
            continue;
        }
        var state = &active.?;
        if (self.latest_generation.load(.acquire) != state.generation) continue;

        var snapshot = self.store.snapshot(std.heap.page_allocator) catch {
            self.waitForWork(&seen_epoch);
            continue;
        };
        defer snapshot.deinit();

        var parse_options = state.config.parseOptions();
        var term_buf: [512]QueryTerm = undefined;
        const parsed = parseQuery(state.query, &parse_options, &term_buf) catch {
            state.scanned_count = snapshot.count;
            state.match_count = 0;
            state.ranks.clearRetainingCapacity();
            self.publish(state, snapshot.count, snapshot.finished, snapshot.finished) catch {};
            self.waitForWork(&seen_epoch);
            continue;
        };
        const sortable = !state.config.no_sort and parsed.sortable;
        var raw_term_buf: [512]RawTermPlan = undefined;
        const raw_plan = prepareRawQuery(parsed, state.config.case_mode, !state.config.literal, state.config.scheme, state.config.algorithm, &raw_term_buf);

        if (state.config.disabled or state.query.len == 0) {
            if (state.ranks.items.len < state.top_k) {
                var it = snapshot.iteratorFrom(state.scanned_count);
                while (it.next()) |record| {
                    if (state.ranks.items.len < state.top_k) {
                        var rank = LazyRank{ .record = record, .score = .{} };
                        if (sortable) prepareLazyRankTiebreaks(.{ .config = state.config }, &rank);
                        state.ranks.append(self.allocator, rank) catch break;
                    }
                }
            }
            state.scanned_count = snapshot.count;
            state.match_count = snapshot.count;
            self.publish(state, snapshot.count, snapshot.finished, snapshot.finished) catch {};
            if (snapshot.finished) self.waitForWork(&seen_epoch) else if (self.store.count() == state.scanned_count) self.waitForWork(&seen_epoch);
            continue;
        }

        // Keep the first partial single-threaded. Once the UI has something to
        // draw, fan the remaining finished corpus across stable page shards.
        if (state.published_partial and lazyParallelScanCompletedCorpus(self, state, &snapshot, raw_plan, sortable)) {
            self.publish(state, snapshot.count, snapshot.finished, true) catch {};
            self.waitForWork(&seen_epoch);
            continue;
        }
        if (self.latest_generation.load(.acquire) != state.generation) continue;

        const first_publish_base = state.scanned_count;
        var iterator = snapshot.iteratorFrom(state.scanned_count);
        var since_cancel_check: usize = 0;
        var since_publish: usize = 0;
        var last_publish_ms: u64 = if (state.published_partial) monotonicMilliseconds(self.io) else 0;
        var canceled = false;
        var parallel_complete = false;
        while (iterator.next()) |record| {
            state.scanned_count = record.id + 1;
            since_cancel_check += 1;
            since_publish += 1;
            if (since_cancel_check >= 256) {
                since_cancel_check = 0;
                if (self.stop.load(.acquire) or self.latest_generation.load(.acquire) != state.generation) {
                    canceled = true;
                    break;
                }
            }
            if ((scoreParsedCandidateRaw(&scratch, raw_plan, record.text()) catch null)) |score| {
                state.match_count +%= 1;
                lazyInsertRank(state, self.allocator, .{ .record = record, .score = score }, sortable) catch {
                    canceled = true;
                    break;
                };
            }
            if (since_publish >= 1024) {
                // Publish the first useful result set by scan progress, not by a
                // wall-clock delay. At 120 Hz an 8 ms first-result timer lands
                // just before the next key; a small scan threshold makes the
                // current generation visible much earlier without increasing
                // its number of pre-cancel result frames. Later progress stays
                // display-cadenced and polls the clock only once per scan batch.
                since_publish = 0;
                if (!state.published_partial and lazyShouldPublishFirst(state.scanned_count -| first_publish_base, state.ranks.items.len, state.top_k)) {
                    self.publish(state, snapshot.count, snapshot.finished, false) catch {};
                    state.published_partial = true;
                    last_publish_ms = monotonicMilliseconds(self.io);
                    if (lazyParallelScanCompletedCorpus(self, state, &snapshot, raw_plan, sortable)) {
                        parallel_complete = true;
                        break;
                    } else if (self.latest_generation.load(.acquire) != state.generation) {
                        canceled = true;
                        break;
                    }
                } else if (state.published_partial) {
                    const now = monotonicMilliseconds(self.io);
                    if (now -| last_publish_ms >= lazy_progress_publish_interval_ms) {
                        self.publish(state, snapshot.count, snapshot.finished, false) catch {};
                        last_publish_ms = now;
                    }
                }
            }
        }
        if (canceled) continue;
        if (parallel_complete) {
            self.publish(state, snapshot.count, snapshot.finished, true) catch {};
            self.waitForWork(&seen_epoch);
            continue;
        }
        const caught_up = state.scanned_count >= snapshot.count;
        const complete = caught_up and snapshot.finished;
        self.publish(state, snapshot.count, snapshot.finished, complete) catch {};
        if (!complete) state.published_partial = true;
        if (complete or self.store.count() == state.scanned_count) self.waitForWork(&seen_epoch);
    }
}

fn parseQuery(query: []const u8, options: *const Options, storage: *[512]QueryTerm) !ParsedQuery {
    if (!options.extended) {
        if (storage.len == 0) return error.TooManyTerms;
        storage[0] = .{
            .text = query,
            .kind = if (options.exact) .exact else .fuzzy,
            .inverse = false,
            .clause = 0,
        };
        return .{
            .terms = storage[0..1],
            .clause_count = 1,
            .driver = if (!options.exact) query else null,
            .direct = if (!options.exact) query else null,
            .sortable = true,
        };
    }

    var count: usize = 0;
    var clause: usize = 0;
    var have_term = false;
    var join_next = false;
    var i: usize = 0;
    while (i < query.len) {
        while (i < query.len and std.ascii.isWhitespace(query[i])) i += 1;
        if (i >= query.len) break;
        const start = i;
        while (i < query.len and !std.ascii.isWhitespace(query[i])) i += 1;
        const token = query[start..i];
        if (std.mem.eql(u8, token, "|")) {
            if (have_term) join_next = true;
            continue;
        }
        if (count >= storage.len) return error.TooManyTerms;
        if (have_term and !join_next) clause += 1;
        join_next = false;
        storage[count] = parseTerm(token, options.exact, @intCast(clause));
        count += 1;
        have_term = true;
    }

    if (count == 0) return .{ .terms = storage[0..0], .clause_count = 0, .driver = null, .direct = "", .sortable = false };

    var driver: ?[]const u8 = null;
    var driver_len: usize = 0;
    var c: usize = 0;
    while (c <= clause) : (c += 1) {
        var terms_in_clause: usize = 0;
        var only: ?QueryTerm = null;
        for (storage[0..count]) |term| {
            if (term.clause != c) continue;
            terms_in_clause += 1;
            only = term;
        }
        if (terms_in_clause == 1) {
            const term = only.?;
            if (!term.inverse and term.kind == .fuzzy and term.text.len > driver_len) {
                driver = term.text;
                driver_len = term.text.len;
            }
        }
    }

    const direct: ?[]const u8 = if (count == 1 and storage[0].kind == .fuzzy and !storage[0].inverse) storage[0].text else null;
    var sortable = false;
    for (storage[0..count]) |term| {
        if (!term.inverse) {
            sortable = true;
            break;
        }
    }
    return .{ .terms = storage[0..count], .clause_count = clause + 1, .driver = driver, .direct = direct, .sortable = sortable };
}

fn parseTerm(raw: []const u8, exact_mode: bool, clause: u16) QueryTerm {
    var text = raw;
    var inverse = false;
    var kind: TermKind = if (exact_mode) .exact else .fuzzy;

    if (text.len > 1 and text[0] == '!') {
        inverse = true;
        kind = .exact;
        text = text[1..];
    }

    if (text.len > 1 and text[text.len - 1] == '$') {
        text = text[0 .. text.len - 1];
        kind = .suffix;
    }

    if (text.len > 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
        text = text[1 .. text.len - 1];
        kind = .boundary_exact;
    } else if (text.len > 1 and text[0] == '\'') {
        text = text[1..];
        kind = if (!exact_mode and !inverse) .exact else .fuzzy;
    } else if (text.len > 1 and text[0] == '^') {
        text = text[1..];
        kind = if (kind == .suffix) .equal else .prefix;
    }

    return .{ .text = text, .kind = kind, .inverse = inverse, .clause = clause };
}

fn heuristicPureAndTerms(parsed: ParsedQuery, mode: CaseMode, storage: *[512][]const u8) ?[]const []const u8 {
    if (parsed.clause_count == 0 or parsed.terms.len != parsed.clause_count) return null;
    for (parsed.terms, 0..) |term, i| {
        if (term.inverse or term.kind != .fuzzy or termCaseSensitive(mode, term.text)) return null;
        storage[i] = term.text;
    }
    return storage[0..parsed.terms.len];
}

fn heuristicScoreOnlyTiebreakSafe(options: *const Options) bool {
    var i: usize = 0;
    while (i < options.tiebreak_count) : (i += 1) {
        if (options.tiebreaks[i] != .length) return false;
    }
    return true;
}

fn heuristicFilterPureAndAscii(candidates: *const CandidateSet, source: []usize, terms: []const []const u8) []usize {
    var keep: usize = 0;
    for (source) |idx| {
        if (fuzzy_engine.cliTextHasNonAscii(candidates.search[idx])) continue;
        var matched = true;
        for (terms) |term| {
            if (!fuzzySubsequence(candidates.search[idx], term, false)) {
                matched = false;
                break;
            }
        }
        if (!matched) continue;
        source[keep] = idx;
        keep += 1;
    }
    return source[0..keep];
}

fn heuristicHasPresenceClause(parsed: ParsedQuery) bool {
    var clause: usize = 0;
    while (clause < parsed.clause_count) : (clause += 1) {
        var seen = false;
        var usable = true;
        for (parsed.terms) |term| {
            if (term.clause != clause) continue;
            seen = true;
            if (term.kind != .fuzzy or term.inverse) usable = false;
        }
        if (seen and usable) return true;
    }
    return false;
}

fn heuristicPresenceClausesMatch(index: *const fuzzy.Index, parsed: ParsedQuery, entry_index: usize) bool {
    var clause: usize = 0;
    while (clause < parsed.clause_count) : (clause += 1) {
        var seen = false;
        var usable = true;
        var possible = false;
        for (parsed.terms) |term| {
            if (term.clause != clause) continue;
            seen = true;
            if (term.kind != .fuzzy or term.inverse) {
                usable = false;
                continue;
            }
            possible = possible or fuzzy_engine.cliMayContainFoldedAscii(index, entry_index, term.text);
        }
        if (seen and usable and !possible) return false;
    }
    return true;
}

fn queryMatches(parsed: ParsedQuery, line: []const u8, mode: CaseMode) bool {
    if (parsed.terms.len == 0) return true;
    var clause: usize = 0;
    while (clause < parsed.clause_count) : (clause += 1) {
        var any = false;
        for (parsed.terms) |term| {
            if (term.clause != clause) continue;
            var matched = termMatches(term, line, mode);
            if (term.inverse) matched = !matched;
            if (matched) {
                any = true;
                break;
            }
        }
        if (!any) return false;
    }
    return true;
}

fn termMatches(term: QueryTerm, line: []const u8, mode: CaseMode) bool {
    const sensitive = termCaseSensitive(mode, term.text);
    return switch (term.kind) {
        .fuzzy => fuzzySubsequence(line, term.text, sensitive),
        .exact => containsText(line, term.text, sensitive),
        .prefix => startsWithText(line, term.text, sensitive),
        .suffix => endsWithText(line, term.text, sensitive),
        .boundary_exact => containsBoundaryText(line, term.text, sensitive),
        .equal => equalText(line, term.text, sensitive),
    };
}

fn equalText(line: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len == 0) return false;
    var start: usize = 0;
    var end = line.len;
    if (!std.ascii.isWhitespace(needle[0])) {
        while (start < end and std.ascii.isWhitespace(line[start])) start += 1;
    }
    if (!std.ascii.isWhitespace(needle[needle.len - 1])) {
        while (end > start and std.ascii.isWhitespace(line[end - 1])) end -= 1;
    }
    if (end - start != needle.len) return false;
    for (needle, 0..) |c, i| if (!byteEq(line[start + i], c, sensitive)) return false;
    return true;
}

fn termCaseSensitive(mode: CaseMode, text: []const u8) bool {
    return switch (mode) {
        .ignore => false,
        .respect => true,
        .smart => fuzzy_engine.cliSmartCaseSensitive(text),
    };
}

fn foldAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn byteEq(a: u8, b: u8, sensitive: bool) bool {
    return if (sensitive) a == b else foldAscii(a) == foldAscii(b);
}

fn fuzzySubsequence(line: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len == 0) return true;
    var j: usize = 0;
    for (line) |c| {
        if (byteEq(c, needle[j], sensitive)) {
            j += 1;
            if (j == needle.len) return true;
        }
    }
    return false;
}

fn containsText(line: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len == 0) return true;
    if (needle.len > line.len) return false;
    var i: usize = 0;
    while (i + needle.len <= line.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and byteEq(line[i + j], needle[j], sensitive)) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn startsWithText(line: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len > line.len) return false;
    for (needle, 0..) |c, i| if (!byteEq(line[i], c, sensitive)) return false;
    return true;
}

fn endsWithText(line: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len > line.len) return false;
    const start = line.len - needle.len;
    for (needle, 0..) |c, i| if (!byteEq(line[start + i], c, sensitive)) return false;
    return true;
}

fn containsBoundaryText(line: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len == 0) return true;
    if (needle.len > line.len) return false;
    var i: usize = 0;
    while (i + needle.len <= line.len) : (i += 1) {
        if (i != 0 and isWordByte(line[i - 1])) continue;
        if (i + needle.len < line.len and isWordByte(line[i + needle.len])) continue;
        var j: usize = 0;
        while (j < needle.len and byteEq(line[i + j], needle[j], sensitive)) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn filterMode(allocator: Allocator, io: Io, index: *fuzzy.Index, candidates: *const CandidateSet, options: *const Options, query: []const u8) !void {
    // fzf's --filter path always performs matching even when --disabled/--phony
    // is present. With --no-sort it streams directly only when neither --sync
    // nor --tac forces a snapshot; snapshot filtering still ranks a non-empty
    // query (the matcher sorts within its chunk even with global sorting off).
    var filter_options = options.*;
    filter_options.disabled = false;
    if (options.no_sort and !filterUsesStreamingPath(options) and query.len != 0) filter_options.no_sort = false;

    const out = try allocator.alloc(usize, candidates.display.len);
    defer allocator.free(out);
    const ranks = try allocator.alloc(ExtendedRank, candidates.display.len);
    defer allocator.free(ranks);
    const found = try searchCandidates(index, candidates, &filter_options, query, out, ranks, out.len);
    if (filter_options.no_sort) std.mem.sort(usize, found, {}, comptime std.sort.asc(usize));
    var stdout_buffer: [8192]u8 = undefined;
    var writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const sep: []const u8 = if (options.print0) "\x00" else "\n";
    if (options.print_query) {
        try writer.interface.writeAll(query);
        try writer.interface.writeAll(sep);
    }
    for (found) |idx| {
        if (options.accept_nth) |spec| {
            const transformed = try transformFields(allocator, candidates.output[idx], options.delimiter, spec, idx);
            defer allocator.free(transformed);
            try writer.interface.writeAll(transformed);
        } else {
            try writer.interface.writeAll(candidates.output[idx]);
        }
        try writer.interface.writeAll(sep);
    }
    try writer.flush();
    if (found.len == 0) std.process.exit(1);
}

fn canonicalNthSpec(allocator: Allocator, spec: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var terms = std.mem.splitScalar(u8, spec, ',');
    var first = true;
    while (terms.next()) |term| {
        const range = parsePlaceholderRange(term) orelse return error.InvalidNth;
        if (!first) try out.append(allocator, ',');
        first = false;
        if (range.begin == 0 and range.end == 0) {
            try out.appendSlice(allocator, "..");
            continue;
        }
        if (range.begin == range.end) {
            var buf: [32]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{range.begin}));
            continue;
        }
        if (range.begin != 0) {
            var buf: [32]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{range.begin}));
        }
        if (range.begin != -1) {
            try out.appendSlice(allocator, "..");
            if (range.end != 0) {
                var buf: [32]u8 = undefined;
                try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{range.end}));
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn nthSpecNumeric(spec: []const u8) bool {
    if (spec.len == 0) return false;
    for (spec) |c| switch (c) {
        '0'...'9', '-', '.', ',' => {},
        else => return false,
    };
    return true;
}

fn splitNthTokens(allocator: Allocator, out: *std.ArrayList([]const u8), line: []const u8, delimiter: ?[]const u8) !void {
    if (delimiter) |d| {
        if (d.len == 0) {
            try out.append(allocator, line);
            return;
        }
        var start: usize = 0;
        while (start < line.len) {
            if (std.mem.indexOfPos(u8, line, start, d)) |pos| {
                try out.append(allocator, line[start .. pos + d.len]);
                start = pos + d.len;
                if (start == line.len) try out.append(allocator, line[start..start]);
            } else {
                try out.append(allocator, line[start..]);
                start = line.len;
            }
        }
        if (line.len == 0) try out.append(allocator, line);
        return;
    }

    // fzf's AWK-style tokenizer keeps trailing whitespace on each token and
    // ignores leading whitespace before the first token.
    var state: enum { none, black, white } = .none;
    var begin: usize = 0;
    var end: usize = 0;
    for (line, 0..) |c, idx| {
        const white = c == ' ' or c == '\t' or c == '\n';
        switch (state) {
            .none => if (!white) {
                state = .black;
                begin = idx;
                end = idx + 1;
            },
            .black => {
                end = idx + 1;
                if (white) state = .white;
            },
            .white => if (white) {
                end = idx + 1;
            } else {
                try out.append(allocator, line[begin..end]);
                state = .black;
                begin = idx;
                end = idx + 1;
            },
        }
    }
    if (begin < end) try out.append(allocator, line[begin..end]);
}

fn appendNthRange(allocator: Allocator, out: *std.ArrayList(u8), tokens: []const []const u8, range: PlaceholderRange) !void {
    const n: isize = @intCast(tokens.len);
    if (range.begin == range.end) {
        if (range.begin == 0) {
            for (tokens) |token| try out.appendSlice(allocator, token);
            return;
        }
        var idx = range.begin;
        if (idx < 0) idx += n + 1;
        if (idx >= 1 and idx <= n) try out.appendSlice(allocator, tokens[@intCast(idx - 1)]);
        return;
    }

    var begin: isize = undefined;
    var end: isize = undefined;
    if (range.begin == 0) {
        begin = 1;
        end = range.end;
        if (end < 0) end += n + 1;
    } else if (range.end == 0) {
        begin = range.begin;
        end = n;
        if (begin < 0) begin += n + 1;
    } else {
        begin = range.begin;
        end = range.end;
        if (begin < 0) begin += n + 1;
        if (end < 0) end += n + 1;
    }
    var idx = begin;
    while (idx <= end) : (idx += 1) {
        if (idx >= 1 and idx <= n) try out.appendSlice(allocator, tokens[@intCast(idx - 1)]);
    }
}

fn stripNthLastDelimiter(bytes: []u8, delimiter: ?[]const u8) []u8 {
    if (delimiter) |d| {
        if (d.len != 0 and std.mem.endsWith(u8, bytes, d)) return bytes[0 .. bytes.len - d.len];
        return bytes;
    }
    var end = bytes.len;
    while (end != 0 and std.ascii.isWhitespace(bytes[end - 1])) end -= 1;
    return bytes[0..end];
}

fn transformNthNumeric(allocator: Allocator, line: []const u8, delimiter: ?[]const u8, spec: []const u8, strip_last: bool) ![]u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    try splitNthTokens(allocator, &tokens, line, delimiter);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var terms = std.mem.splitScalar(u8, spec, ',');
    while (terms.next()) |term_raw| {
        const term = std.mem.trim(u8, term_raw, " \t");
        if (term.len == 0) continue;
        const range = parsePlaceholderRange(term) orelse continue;
        try appendNthRange(allocator, &out, tokens.items, range);
    }
    if (strip_last) {
        const stripped = stripNthLastDelimiter(out.items, delimiter);
        out.shrinkRetainingCapacity(stripped.len);
    }
    return try out.toOwnedSlice(allocator);
}

fn transformWithNth(allocator: Allocator, line: []const u8, delimiter: ?[]const u8, spec: []const u8, ordinal: usize) ![]u8 {
    if (nthSpecNumeric(spec)) return transformNthNumeric(allocator, line, delimiter, spec, false);
    return transformFields(allocator, line, delimiter, spec, ordinal);
}

fn transformNthSearch(allocator: Allocator, line: []const u8, delimiter: ?[]const u8, spec: []const u8, ordinal: usize) ![]u8 {
    if (nthSpecNumeric(spec)) return transformNthNumeric(allocator, line, delimiter, spec, true);
    return transformFields(allocator, line, delimiter, spec, ordinal);
}

fn transformFields(allocator: Allocator, line: []const u8, delimiter: ?[]const u8, spec: []const u8, ordinal: usize) ![]u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(allocator);
    try splitFields(allocator, &fields, line, delimiter);
    const joiner = delimiter orelse " ";

    if (std.mem.indexOfScalar(u8, spec, '{') != null) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < spec.len) {
            if (spec[i] != '{') {
                try out.append(allocator, spec[i]);
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, spec, i + 1, '}') orelse {
                try out.append(allocator, spec[i]);
                i += 1;
                continue;
            };
            const expr = spec[i + 1 .. close];
            if (std.mem.eql(u8, expr, "n")) {
                const ordinal_text = try std.fmt.allocPrint(allocator, "{d}", .{ordinal});
                defer allocator.free(ordinal_text);
                try out.appendSlice(allocator, ordinal_text);
            } else {
                try appendFieldExpr(allocator, &out, fields.items, joiner, expr, false);
            }
            i = close + 1;
        }
        return try out.toOwnedSlice(allocator);
    }

    if (nthSpecNumeric(spec)) return transformNthNumeric(allocator, line, delimiter, spec, true);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    var terms = std.mem.splitScalar(u8, spec, ',');
    while (terms.next()) |term_raw| {
        const term = std.mem.trim(u8, term_raw, " \t");
        if (term.len == 0) continue;
        const before = out.items.len;
        try appendFieldExpr(allocator, &out, fields.items, joiner, term, true);
        if (out.items.len != before) {
            if (!first and before == 0) unreachable;
            first = false;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn splitFields(allocator: Allocator, out: *std.ArrayList([]const u8), line: []const u8, delimiter: ?[]const u8) !void {
    if (delimiter) |d| {
        if (d.len == 0) {
            try out.append(allocator, line);
            return;
        }
        var start: usize = 0;
        while (true) {
            if (std.mem.indexOfPos(u8, line, start, d)) |pos| {
                try out.append(allocator, line[start..pos]);
                start = pos + d.len;
            } else {
                try out.append(allocator, line[start..]);
                break;
            }
        }
        return;
    }
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
        if (i >= line.len) break;
        const start = i;
        while (i < line.len and !std.ascii.isWhitespace(line[i])) i += 1;
        try out.append(allocator, line[start..i]);
    }
}

fn appendFieldExpr(allocator: Allocator, out: *std.ArrayList(u8), fields: []const []const u8, joiner: []const u8, expr: []const u8, join_existing: bool) !void {
    if (fields.len == 0) return;
    const dots = std.mem.indexOf(u8, expr, "..");
    var first_index: isize = 1;
    var last_index: isize = @intCast(fields.len);
    if (dots) |pos| {
        if (pos != 0) first_index = std.fmt.parseInt(isize, expr[0..pos], 10) catch return;
        if (pos + 2 < expr.len) last_index = std.fmt.parseInt(isize, expr[pos + 2 ..], 10) catch return;
    } else {
        const one = std.fmt.parseInt(isize, expr, 10) catch return;
        first_index = one;
        last_index = one;
    }
    const a = resolveFieldIndex(first_index, fields.len) orelse return;
    const b = resolveFieldIndex(last_index, fields.len) orelse return;
    const lo = @min(a, b);
    const hi = @max(a, b);
    var j = lo;
    while (j <= hi) : (j += 1) {
        if ((join_existing and out.items.len != 0) or j != lo) try out.appendSlice(allocator, joiner);
        try out.appendSlice(allocator, fields[j]);
    }
}

fn resolveFieldIndex(index: isize, len: usize) ?usize {
    if (index == 0) return null;
    if (index > 0) {
        const i: usize = @intCast(index - 1);
        return if (i < len) i else null;
    }
    const back: usize = @intCast(-index);
    if (back > len) return null;
    return len - back;
}

fn stripAnsi(allocator: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len) : (i += 1) {
                if (s[i] >= 0x40 and s[i] <= 0x7e) {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn readKey(t: *Terminal, wake_fd: i32) !Key {
    // Lazy result publication wakes the same poll as terminal input on Linux;
    // other targets keep the frame-scale timeout fallback. Escape-sequence
    // continuation bytes still use the longer terminal-only readByte timeout.
    const b = t.readByteTimeoutWithWake(wake_fd, 4) catch |err| switch (err) {
        error.Timeout, error.Wake => return .unknown,
        else => return err,
    };
    if (b != 0x1b) return .{ .byte = b };
    const b2 = t.readByte() catch |err| switch (err) {
        error.Timeout => return .{ .byte = 27 },
        else => return err,
    };
    if (b2 != '[') return .{ .alt_byte = b2 };
    const first = t.readByte() catch |err| switch (err) {
        error.Timeout => return .unknown,
        else => return err,
    };
    if (first == '<') return try readMouse(t);

    var params_buf: [48]u8 = undefined;
    var len: usize = 0;
    var c = first;
    while (true) {
        if (c >= 0x40 and c <= 0x7e) return decodeCsi(params_buf[0..len], c);
        if (len < params_buf.len) {
            params_buf[len] = c;
            len += 1;
        }
        c = t.readByte() catch |err| switch (err) {
            error.Timeout => return .unknown,
            else => return err,
        };
    }
}

fn decodeCsi(params: []const u8, final: u8) Key {
    if (params.len == 0) return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        else => .unknown,
    };

    var pieces = std.mem.splitScalar(u8, params, ';');
    const first_text = pieces.next() orelse "";
    const first = std.fmt.parseInt(usize, first_text, 10) catch 0;
    const modifier = if (pieces.next()) |text| std.fmt.parseInt(usize, text, 10) catch 0 else 0;
    if ((final == 'C' or final == 'D') and first == 1 and (modifier == 3 or modifier == 5)) {
        return if (final == 'C') .word_right else .word_left;
    }
    if (final == '~') return switch (first) {
        1, 7 => .home,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        200 => .paste_start,
        201 => .paste_end,
        else => .unknown,
    };
    return .unknown;
}

fn readMouse(t: *Terminal) !Key {
    var fields: [3]usize = .{ 0, 0, 0 };
    var field: usize = 0;
    var value: usize = 0;
    while (field < 3) {
        const b = try t.readByte();
        if (b >= '0' and b <= '9') {
            value = value * 10 + b - '0';
            continue;
        }
        if (b == ';') {
            fields[field] = value;
            field += 1;
            value = 0;
            continue;
        }
        if (b == 'M' or b == 'm') {
            fields[field] = value;
            return .{ .mouse = .{
                .button = fields[0],
                .x = if (fields[1] > 0) fields[1] - 1 else 0,
                .y = if (fields[2] > 0) fields[2] - 1 else 0,
                .release = b == 'm',
            } };
        }
        return .unknown;
    }
    return .unknown;
}

fn appendPastedBytes(allocator: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |b| try appendPastedByte(allocator, out, b);
}

fn appendPastedByte(allocator: Allocator, out: *std.ArrayList(u8), b: u8) !void {
    if (b >= 32 or b >= 128) {
        try out.append(allocator, b);
    } else if (b == '\r' or b == '\n' or b == '\t') {
        try out.append(allocator, ' ');
    }
}

fn asciiWordAlnum(b: u8) bool {
    return std.ascii.isAlphabetic(b) or std.ascii.isDigit(b);
}

fn wordBoundaryBackward(s: []const u8, pos: usize) usize {
    const end = @min(pos, s.len);
    if (end == 0) return 0;
    if (!std.unicode.utf8ValidateSlice(s[0..end])) {
        var last: usize = 0;
        var i: usize = 1;
        while (i < end) : (i += 1) {
            if (!asciiWordAlnum(s[i - 1]) and asciiWordAlnum(s[i])) last = i;
        }
        return last;
    }

    var it = std.unicode.Utf8Iterator{ .bytes = s[0..end], .i = 0 };
    var left = it.nextCodepoint() orelse return 0;
    var last: usize = 0;
    while (it.i < end) {
        const boundary = it.i;
        const right = it.nextCodepoint() orelse break;
        if (!subwordAlnum(left) and subwordAlnum(right)) last = boundary;
        left = right;
    }
    return last;
}

fn wordBoundaryForward(s: []const u8, pos: usize) usize {
    const start = @min(pos, s.len);
    if (start >= s.len) return s.len;
    if (!std.unicode.utf8ValidateSlice(s[start..])) {
        var i = start + 1;
        while (i < s.len) : (i += 1) {
            if (asciiWordAlnum(s[i - 1]) and !asciiWordAlnum(s[i])) return i;
        }
        return s.len;
    }

    var it = std.unicode.Utf8Iterator{ .bytes = s[start..], .i = 0 };
    var left = it.nextCodepoint() orelse return s.len;
    while (it.i < s.len - start) {
        const boundary = start + it.i;
        const right = it.nextCodepoint() orelse break;
        if (subwordAlnum(left) and !subwordAlnum(right)) return boundary;
        left = right;
    }
    return s.len;
}

fn fzfUnixWhitespace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0c;
}

fn unixWordBoundaryBackward(s: []const u8, pos: usize) usize {
    const end = @min(pos, s.len);
    var last: usize = 0;
    var i: usize = 1;
    while (i < end) : (i += 1) {
        if (fzfUnixWhitespace(s[i - 1]) and !fzfUnixWhitespace(s[i])) last = i;
    }
    return last;
}

fn filepathWordBoundaryBackward(s: []const u8, pos: usize) usize {
    const end = @min(pos, s.len);
    var last: usize = 0;
    var i: usize = 1;
    while (i < end) : (i += 1) {
        if (s[i - 1] == '/' and s[i] != '/') last = i;
    }
    return last;
}

fn filepathWordBoundaryForward(s: []const u8, pos: usize) usize {
    const start = @min(pos, s.len);
    if (start >= s.len) return s.len;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        if (s[i - 1] != '/' and s[i] == '/') return i;
    }
    return s.len;
}

fn subwordAlnum(cp: u21) bool {
    return fuzzy_engine.cliRuneIsLetterOrNumber(cp);
}

fn subwordCamelBoundary(left: u21, right: u21) bool {
    return left >= 'a' and left <= 'z' and right >= 'A' and right <= 'Z';
}

fn subwordBoundaryForward(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    if (!std.unicode.utf8ValidateSlice(s)) return wordBoundaryForward(s, pos);
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = pos };
    var left = it.nextCodepoint() orelse return s.len;
    while (it.i < s.len) {
        const boundary = it.i;
        const right = it.nextCodepoint() orelse return s.len;
        if (subwordCamelBoundary(left, right) or (subwordAlnum(left) and !subwordAlnum(right))) return boundary;
        left = right;
    }
    return s.len;
}

fn subwordBoundaryBackward(s: []const u8, pos: usize) usize {
    const end = @min(pos, s.len);
    if (end == 0) return 0;
    if (!std.unicode.utf8ValidateSlice(s)) return wordBoundaryBackward(s, end);
    var it = std.unicode.Utf8Iterator{ .bytes = s[0..end], .i = 0 };
    var left = it.nextCodepoint() orelse return 0;
    var last: usize = 0;
    while (it.i < end) {
        const boundary = it.i;
        const right = it.nextCodepoint() orelse break;
        if (subwordCamelBoundary(left, right) or (!subwordAlnum(left) and subwordAlnum(right))) last = boundary;
        left = right;
    }
    return last;
}

fn prevUtf8Boundary(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and (s[p] & 0xc0) == 0x80) p -= 1;
    return p;
}

fn nextUtf8Boundary(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var p = pos + 1;
    while (p < s.len and (s[p] & 0xc0) == 0x80) p += 1;
    return p;
}

const DisplayRune = struct {
    bytes: []const u8,
    cp: u21,
};

fn nextDisplayRune(text: []const u8, at: *usize) DisplayRune {
    const start = at.*;
    const first = text[start];
    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
        at.* += 1;
        return .{ .bytes = text[start .. start + 1], .cp = first };
    };
    const len: usize = seq_len;
    if (start + len > text.len) {
        at.* += 1;
        return .{ .bytes = text[start .. start + 1], .cp = first };
    }
    const bytes = text[start .. start + len];
    const cp = std.unicode.utf8Decode(bytes) catch {
        at.* += 1;
        return .{ .bytes = text[start .. start + 1], .cp = first };
    };
    at.* += len;
    return .{ .bytes = bytes, .cp = cp };
}

fn runeCellWidth(cp: u21) usize {
    if (cp == 0 or cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    // Common combining marks, variation selectors and joiners occupy no cell.
    if ((cp >= 0x0300 and cp <= 0x036f) or (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x0591 and cp <= 0x05bd) or (cp >= 0x05bf and cp <= 0x05bf) or
        (cp >= 0x05c1 and cp <= 0x05c2) or (cp >= 0x05c4 and cp <= 0x05c5) or
        (cp >= 0x0610 and cp <= 0x061a) or (cp >= 0x064b and cp <= 0x065f) or
        (cp >= 0x0670 and cp <= 0x0670) or (cp >= 0x06d6 and cp <= 0x06ed) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or (cp >= 0xfe00 and cp <= 0xfe0f) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or (cp >= 0xe0100 and cp <= 0xe01ef) or
        cp == 0x200b or cp == 0x200c or cp == 0x200d) return 0;
    // East Asian wide/full-width ranges and emoji presentation blocks.
    if ((cp >= 0x1100 and cp <= 0x115f) or cp == 0x2329 or cp == 0x232a or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe19) or (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

fn visibleTextWidth(text: []const u8, ansi: bool) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (ansi and text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len) : (i += 1) if (text[i] >= 0x40 and text[i] <= 0x7e) {
                i += 1;
                break;
            };
            continue;
        }
        const r = nextDisplayRune(text, &i);
        width += runeCellWidth(r.cp);
    }
    return width;
}

fn runeFoldEq(a: u21, b: u21) bool {
    if (a < 128 and b < 128) return std.ascii.toLower(@intCast(a)) == std.ascii.toLower(@intCast(b));
    return a == b;
}

fn writeHighlighted(w: anytype, text: []const u8, query: []const u8, cols: usize, wrap: bool, ansi: bool, theme: *const Theme, focused: bool, bold_enabled: bool) !void {
    var qi: usize = 0;
    var printed: usize = 0;
    var i: usize = 0;
    const base = if (focused) theme.current else theme.normal;
    const highlight = if (focused) theme.highlight_current else theme.highlight;
    const truncated = !wrap and visibleTextWidth(text, ansi) > cols;
    const content_limit = if (truncated and cols > 0) cols - 1 else cols;
    while (i < text.len) {
        if (ansi and text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            const esc_start = i;
            i += 2;
            while (i < text.len) : (i += 1) {
                if (text[i] >= 0x40 and text[i] <= 0x7e) {
                    i += 1;
                    break;
                }
            }
            try w.writeAll(text[esc_start..i]);
            continue;
        }
        const before = i;
        const r = nextDisplayRune(text, &i);
        const width = runeCellWidth(r.cp);
        if (!wrap and printed + width > content_limit) {
            i = before;
            break;
        }
        var match = false;
        if (qi < query.len) {
            var qnext = qi;
            const qr = nextDisplayRune(query, &qnext);
            match = runeFoldEq(r.cp, qr.cp);
            if (match) qi = qnext;
        }
        if (match) {
            try writeRoleStyleOverlay(w, highlight, theme.enabled, bold_enabled);
            try w.writeAll(r.bytes);
            try writeRoleStyle(w, base, theme.enabled, bold_enabled);
        } else try w.writeAll(r.bytes);
        printed += width;
    }
    if (truncated and cols != 0) try w.writeAll("…");
}

fn keyMatchesName(key: Key, name: []const u8) bool {
    const identity = keyNameIdentity(name) orelse return false;
    return switch (key) {
        .up => identity.kind == .named and identity.value == 1,
        .down => identity.kind == .named and identity.value == 2,
        .left => identity.kind == .named and identity.value == 3,
        .right => identity.kind == .named and identity.value == 4,
        .home => identity.kind == .named and identity.value == 5,
        .end => identity.kind == .named and identity.value == 6,
        .page_up => identity.kind == .named and identity.value == 7,
        .page_down => identity.kind == .named and identity.value == 8,
        .delete => identity.kind == .named and identity.value == 9,
        .shift_tab => identity.kind == .named and identity.value == 10,
        .alt_byte => |b| (identity.kind == .alt_literal and identity.value == b) or
            (identity.kind == .named and ((identity.value == 20 and b == 13) or
                (identity.value == 21 and b == 127) or (identity.value == 23 and b == 8) or
                (identity.value >= 200 and identity.value < 226 and b == identity.value - 199))),
        .byte => |b| blk: {
            if (identity.kind == .literal) break :blk identity.value == b;
            if (identity.kind != .named) break :blk false;
            if (identity.value == 11) break :blk b == 13;
            if (identity.value == 12) break :blk b == 9;
            if (identity.value == 13) break :blk b == 27;
            if (identity.value == 14) break :blk b == 127;
            if (identity.value == 22) break :blk b == 8;
            if (identity.value == 15) break :blk b == 0;
            if (identity.value == 16) break :blk b == 30;
            if (identity.value == 17) break :blk b == 31;
            if (identity.value == 18) break :blk b == 28;
            if (identity.value == 19) break :blk b == 29;
            if (identity.value >= 100 and identity.value < 126) break :blk b == identity.value - 99;
            break :blk false;
        },
        else => false,
    };
}

fn writeTruncated(w: anytype, text: []const u8, cols: usize, wrap: bool, prefix: []const u8) !void {
    try w.writeAll(prefix);
    if (wrap) return w.writeAll(text);
    const total = visibleTextWidth(text, false);
    if (total <= cols) return w.writeAll(text);
    if (cols == 0) return;
    const limit = cols - 1;
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const before = i;
        const r = nextDisplayRune(text, &i);
        const width = runeCellWidth(r.cp);
        if (used + width > limit) {
            i = before;
            break;
        }
        try w.writeAll(r.bytes);
        used += width;
    }
    try w.writeAll("…");
}

fn expandPreviewCommand(allocator: Allocator, template: []const u8, item: []const u8, query: []const u8) ![]u8 {
    const items = [_][]const u8{item};
    return expandCommandSimple(allocator, template, query, &items, 0);
}

fn expandCommandSimple(allocator: Allocator, template: []const u8, query: []const u8, items: []const []const u8, current: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const item = if (items.len == 0) "" else items[@min(current, items.len - 1)];
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{q}")) {
            const q = try shellQuote(allocator, query);
            defer allocator.free(q);
            try out.appendSlice(allocator, q);
            i += 3;
        } else if (std.mem.startsWith(u8, template[i..], "{}")) {
            const q = try shellQuote(allocator, item);
            defer allocator.free(q);
            try out.appendSlice(allocator, q);
            i += 2;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn expandCommand(
    allocator: Allocator,
    template: []const u8,
    query: []const u8,
    candidates: *const CandidateSet,
    options: *const Options,
    current_idx: ?usize,
    selection_order: []const usize,
    selected: []const bool,
    matched: []const usize,
) ![]u8 {
    return expandCommandImpl(allocator, template, query, candidates, options, current_idx, selection_order, selected, matched, "", options.prompt, null, null);
}

const PlaceholderFlags = struct {
    plus: bool = false,
    asterisk: bool = false,
    preserve_space: bool = false,
    file: bool = false,
    raw: bool = false,
    number: bool = false,
};

const PlaceholderKind = enum {
    item,
    fields,
    query,
    query_fields,
    fzf_query,
    fzf_action,
    fzf_prompt,
};

const PreviewTemplateFlags = struct {
    slot: bool = false,
    plus: bool = false,
    asterisk: bool = false,
    force_update: bool = false,
};

fn previewTemplateFlags(template: []const u8) PreviewTemplateFlags {
    var flags: PreviewTemplateFlags = .{};
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '\\' and i + 1 < template.len and template[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i + 2, '}')) |close| {
                if (parsePlaceholderExpr(template[i + 2 .. close]) != null) {
                    i = close + 1;
                    continue;
                }
            }
        }
        if (template[i] != '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
            i += 1;
            continue;
        };
        const spec = parsePlaceholderExpr(template[i + 1 .. close]) orelse {
            i = close + 1;
            continue;
        };
        flags.slot = true;
        switch (spec.kind) {
            .query, .query_fields, .fzf_query, .fzf_action, .fzf_prompt => flags.force_update = true,
            .item, .fields => {
                flags.plus = flags.plus or spec.flags.plus;
                flags.asterisk = flags.asterisk or spec.flags.asterisk;
            },
        }
        i = close + 1;
    }
    return flags;
}

const PlaceholderSpec = struct {
    kind: PlaceholderKind,
    flags: PlaceholderFlags = .{},
    fields: []const u8 = "",
};

fn parsePlaceholderExpr(expr: []const u8) ?PlaceholderSpec {
    if (std.mem.eql(u8, expr, "q")) return .{ .kind = .query };
    if (std.mem.startsWith(u8, expr, "q:")) {
        var body = expr[2..];
        var preserve_space = false;
        if (body.len != 0 and body[0] == 's') {
            preserve_space = true;
            body = body[1..];
        }
        if (body.len == 0 or !isPlaceholderFieldSyntax(body) or !placeholderRangesValid(body)) return null;
        return .{ .kind = .query_fields, .flags = .{ .preserve_space = preserve_space }, .fields = body };
    }
    if (std.mem.eql(u8, expr, "fzf:query")) return .{ .kind = .fzf_query };
    if (std.mem.eql(u8, expr, "fzf:action")) return .{ .kind = .fzf_action };
    if (std.mem.eql(u8, expr, "fzf:prompt")) return .{ .kind = .fzf_prompt };

    // Item-number placeholders are the one form that allows `f` on either
    // side of `n`: {n}, {fn}, {nf}, {+nf}, {*fn}, ...
    var number_flags: PlaceholderFlags = .{};
    var number_pos: usize = 0;
    if (number_pos < expr.len and (expr[number_pos] == '+' or expr[number_pos] == '*')) {
        if (expr[number_pos] == '+') number_flags.plus = true else number_flags.asterisk = true;
        number_pos += 1;
    }
    if (number_pos < expr.len and expr[number_pos] == 'f') {
        number_flags.file = true;
        number_pos += 1;
    }
    if (number_pos < expr.len and expr[number_pos] == 'n') {
        number_flags.number = true;
        number_pos += 1;
        if (number_pos < expr.len and expr[number_pos] == 'f') {
            number_flags.file = true;
            number_pos += 1;
        }
        if (number_pos == expr.len) return .{ .kind = .item, .flags = number_flags };
    }

    // fzf's token-placeholder regexp accepts an arbitrary sequence of the
    // +, *, s, f, r flags followed by a (possibly empty) field expression.
    var flags: PlaceholderFlags = .{};
    var pos: usize = 0;
    while (pos < expr.len) : (pos += 1) {
        switch (expr[pos]) {
            '+' => flags.plus = true,
            '*' => flags.asterisk = true,
            's' => flags.preserve_space = true,
            'f' => flags.file = true,
            'r' => flags.raw = true,
            else => break,
        }
    }
    const fields = expr[pos..];
    if (!isPlaceholderFieldSyntax(fields) or (fields.len != 0 and !placeholderRangesValid(fields))) return null;
    return .{ .kind = if (fields.len == 0) .item else .fields, .flags = flags, .fields = fields };
}

fn isPlaceholderFieldSyntax(expr: []const u8) bool {
    for (expr) |c| switch (c) {
        '0'...'9', '-', '.', ',' => {},
        else => return false,
    };
    return true;
}

const PlaceholderRange = struct {
    begin: isize,
    end: isize,
};

fn placeholderRange(begin_value: isize, end_value: isize) PlaceholderRange {
    var begin = begin_value;
    var end = end_value;
    if (begin == 1 and end != 1) begin = 0;
    if (end == -1) end = 0;
    return .{ .begin = begin, .end = end };
}

fn parsePlaceholderRange(text: []const u8) ?PlaceholderRange {
    if (std.mem.eql(u8, text, "..")) return placeholderRange(0, 0);
    if (std.mem.startsWith(u8, text, "..")) {
        const end = std.fmt.parseInt(isize, text[2..], 10) catch return null;
        if (end == 0) return null;
        return placeholderRange(0, end);
    }
    if (std.mem.endsWith(u8, text, "..")) {
        const begin = std.fmt.parseInt(isize, text[0 .. text.len - 2], 10) catch return null;
        if (begin == 0) return null;
        return placeholderRange(begin, 0);
    }
    if (std.mem.indexOf(u8, text, "..")) |dots| {
        if (std.mem.indexOfPos(u8, text, dots + 2, "..") != null) return null;
        const begin = std.fmt.parseInt(isize, text[0..dots], 10) catch return null;
        const end = std.fmt.parseInt(isize, text[dots + 2 ..], 10) catch return null;
        if (begin == 0 or end == 0 or (begin < 0 and end > 0)) return null;
        return placeholderRange(begin, end);
    }
    const one = std.fmt.parseInt(isize, text, 10) catch return null;
    if (one == 0) return null;
    return placeholderRange(one, one);
}

fn placeholderRangesValid(spec: []const u8) bool {
    var terms = std.mem.splitScalar(u8, spec, ',');
    var count: usize = 0;
    while (terms.next()) |term| {
        if (term.len == 0 or parsePlaceholderRange(term) == null) return false;
        count += 1;
    }
    return count != 0;
}

fn expandCommandImpl(
    allocator: Allocator,
    template: []const u8,
    query: []const u8,
    candidates: *const CandidateSet,
    options: *const Options,
    current_idx: ?usize,
    selection_order: []const usize,
    selected: []const bool,
    matched: []const usize,
    action: []const u8,
    prompt: []const u8,
    io: ?Io,
    temp_files: ?*std.ArrayList([]u8),
) ![]u8 {
    return expandCommandImplWithForcePlus(allocator, template, query, candidates, options, current_idx, selection_order, selected, matched, action, prompt, io, temp_files, false);
}

fn expandCommandImplWithForcePlus(
    allocator: Allocator,
    template: []const u8,
    query: []const u8,
    candidates: *const CandidateSet,
    options: *const Options,
    current_idx: ?usize,
    selection_order: []const usize,
    selected: []const bool,
    matched: []const usize,
    action: []const u8,
    prompt: []const u8,
    io: ?Io,
    temp_files: ?*std.ArrayList([]u8),
    force_plus: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '\\' and i + 1 < template.len and template[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i + 2, '}')) |close| {
                const expr = template[i + 2 .. close];
                if (parsePlaceholderExpr(expr) != null) {
                    try out.appendSlice(allocator, template[i + 1 .. close + 1]);
                    i = close + 1;
                    continue;
                }
            }
        }
        if (template[i] != '{') {
            try out.append(allocator, template[i]);
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
            try out.append(allocator, template[i]);
            i += 1;
            continue;
        };
        const expr = template[i + 1 .. close];
        const spec = parsePlaceholderExpr(expr) orelse {
            try out.appendSlice(allocator, template[i .. close + 1]);
            i = close + 1;
            continue;
        };
        switch (spec.kind) {
            .query, .fzf_query => try appendShellQuoted(allocator, &out, query),
            .fzf_action => try appendShellQuoted(allocator, &out, action),
            .fzf_prompt => try appendShellQuoted(allocator, &out, prompt),
            .query_fields => {
                const transformed = try transformPlaceholderFields(allocator, query, null, spec.fields, spec.flags.preserve_space);
                defer allocator.free(transformed);
                try appendShellQuoted(allocator, &out, transformed);
            },
            .item, .fields => {
                if (spec.flags.file) {
                    const actual_io = io orelse return error.FilePlaceholderUnavailable;
                    const files = temp_files orelse return error.FilePlaceholderUnavailable;
                    try appendFilePlaceholder(allocator, &out, actual_io, files, spec, candidates, options, current_idx, selection_order, selected, matched, force_plus);
                } else {
                    try appendItemPlaceholder(allocator, &out, spec, candidates, options, current_idx, selection_order, selected, matched, force_plus);
                }
            },
        }
        i = close + 1;
    }
    return try out.toOwnedSlice(allocator);
}

var placeholder_file_counter: std.atomic.Value(u32) = .init(0);

fn appendFilePlaceholder(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    io: Io,
    temp_files: *std.ArrayList([]u8),
    spec: PlaceholderSpec,
    candidates: *const CandidateSet,
    options: *const Options,
    current_idx: ?usize,
    selection_order: []const usize,
    selected: []const bool,
    matched: []const usize,
    force_plus: bool,
) !void {
    var fallback_temp_dir: ?[:0]u8 = null;
    defer if (fallback_temp_dir) |value| allocator.free(value);
    const temp_dir = if (options.temp_dir.len != 0) options.temp_dir else blk: {
        fallback_temp_dir = try std.process.currentPathAlloc(io, allocator);
        break :blk fallback_temp_dir.?;
    };

    var path: ?[]u8 = null;
    var file: ?Io.File = null;
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const serial = placeholder_file_counter.fetchAdd(1, .monotonic);
        const process_id: u64 = if (builtin.os.tag == .windows)
            @intCast(std.os.windows.GetCurrentProcessId())
        else
            @intCast(std.c.getpid());
        const filename = try std.fmt.allocPrint(allocator, "zfuzz-{d}-{d}.tmp", .{ process_id, serial });
        defer allocator.free(filename);
        const candidate_path = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        const opened = Io.Dir.createFileAbsolute(io, candidate_path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate_path);
                continue;
            },
            else => {
                allocator.free(candidate_path);
                return err;
            },
        };
        path = candidate_path;
        file = opened;
        break;
    }
    const file_path = path orelse return error.TemporaryFileUnavailable;
    var owned_by_list = false;
    errdefer if (!owned_by_list) {
        if (file) |opened| opened.close(io);
        Io.Dir.deleteFileAbsolute(io, file_path) catch {};
        allocator.free(file_path);
    };

    var buffer: [8192]u8 = undefined;
    var writer = file.?.writerStreaming(io, &buffer);
    const sep: []const u8 = if (options.print0) "\x00" else "\n";
    var wrote = false;

    if (spec.flags.asterisk) {
        for (matched) |idx_value| {
            if (idx_value >= candidates.output.len) continue;
            try writePlaceholderValue(allocator, &writer.interface, spec, candidates, options, idx_value);
            try writer.interface.writeAll(sep);
            wrote = true;
        }
    } else if (spec.flags.plus or force_plus) {
        for (selection_order) |idx_value| {
            if (idx_value >= selected.len or !selected[idx_value]) continue;
            try writePlaceholderValue(allocator, &writer.interface, spec, candidates, options, idx_value);
            try writer.interface.writeAll(sep);
            wrote = true;
        }
    }
    if (!wrote and !spec.flags.asterisk) if (current_idx) |idx_value| {
        try writePlaceholderValue(allocator, &writer.interface, spec, candidates, options, idx_value);
        try writer.interface.writeAll(sep);
    };
    try writer.flush();
    file.?.close(io);
    file = null;

    try temp_files.append(allocator, file_path);
    owned_by_list = true;
    try appendShellQuoted(allocator, out, file_path);
}

fn writePlaceholderValue(
    allocator: Allocator,
    writer: *Io.Writer,
    spec: PlaceholderSpec,
    candidates: *const CandidateSet,
    options: *const Options,
    idx: usize,
) !void {
    if (spec.flags.number) {
        var buf: [32]u8 = undefined;
        return writer.writeAll(try std.fmt.bufPrint(&buf, "{d}", .{idx}));
    }
    var source = candidates.output[idx];
    var stripped: ?[]const u8 = null;
    defer if (stripped) |owned| allocator.free(owned);
    if (options.ansi) {
        const owned = try stripAnsi(allocator, source);
        stripped = owned;
        source = owned;
    }
    if (spec.kind == .item) return writer.writeAll(source);
    const transformed = try transformPlaceholderFields(allocator, source, options.delimiter, spec.fields, spec.flags.preserve_space);
    defer allocator.free(transformed);
    try writer.writeAll(transformed);
}

fn appendItemPlaceholder(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    spec: PlaceholderSpec,
    candidates: *const CandidateSet,
    options: *const Options,
    current_idx: ?usize,
    selection_order: []const usize,
    selected: []const bool,
    matched: []const usize,
    force_plus: bool,
) !void {
    var wrote = false;
    if (spec.flags.asterisk) {
        for (matched) |idx| {
            if (idx >= candidates.output.len) continue;
            if (wrote) try out.append(allocator, ' ');
            try appendPlaceholderValue(allocator, out, spec, candidates, options, idx);
            wrote = true;
        }
        return;
    }
    if (spec.flags.plus or force_plus) {
        for (selection_order) |idx| {
            if (idx >= selected.len or !selected[idx]) continue;
            if (wrote) try out.append(allocator, ' ');
            try appendPlaceholderValue(allocator, out, spec, candidates, options, idx);
            wrote = true;
        }
    }
    if (wrote) return;
    if (current_idx) |idx| try appendPlaceholderValue(allocator, out, spec, candidates, options, idx);
}

fn appendPlaceholderValue(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    spec: PlaceholderSpec,
    candidates: *const CandidateSet,
    options: *const Options,
    idx: usize,
) !void {
    if (spec.flags.number) return appendDecimal(allocator, out, idx);
    var source = candidates.output[idx];
    var stripped: ?[]const u8 = null;
    defer if (stripped) |owned| allocator.free(owned);
    if (options.ansi) {
        const owned = try stripAnsi(allocator, source);
        stripped = owned;
        source = owned;
    }
    if (spec.kind == .item) {
        if (spec.flags.raw) return out.appendSlice(allocator, source);
        return appendShellQuoted(allocator, out, source);
    }
    const transformed = try transformPlaceholderFields(allocator, source, options.delimiter, spec.fields, spec.flags.preserve_space);
    defer allocator.free(transformed);
    if (spec.flags.raw) return out.appendSlice(allocator, transformed);
    try appendShellQuoted(allocator, out, transformed);
}

fn transformPlaceholderFields(
    allocator: Allocator,
    line: []const u8,
    delimiter: ?[]const u8,
    spec: []const u8,
    preserve_space: bool,
) ![]u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    try tokenizePlaceholderFields(allocator, &tokens, line, delimiter);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var terms = std.mem.splitScalar(u8, spec, ',');
    while (terms.next()) |term| {
        const range = parsePlaceholderRange(term) orelse return error.InvalidPlaceholderRange;
        try appendPlaceholderRange(allocator, &out, tokens.items, range);
    }
    if (delimiter) |d| {
        if (d.len != 0 and std.mem.endsWith(u8, out.items, d)) out.shrinkRetainingCapacity(out.items.len - d.len);
    }
    const transformed = try out.toOwnedSlice(allocator);
    if (preserve_space) return transformed;
    const trimmed = trimUnicodeWhitespaceSlice(transformed);
    if (trimmed.len == transformed.len) return transformed;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(transformed);
    return result;
}

fn tokenizePlaceholderFields(allocator: Allocator, out: *std.ArrayList([]const u8), line: []const u8, delimiter: ?[]const u8) !void {
    if (delimiter) |d| {
        if (d.len == 0) return out.append(allocator, line);
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, d)) |pos| {
            const end = pos + d.len;
            try out.append(allocator, line[start..end]);
            start = end;
        }
        if (start < line.len or line.len == 0 or std.mem.endsWith(u8, line, d)) try out.append(allocator, line[start..]);
        return;
    }

    var i: usize = 0;
    while (i < line.len and isAwkPlaceholderWhitespace(line[i])) i += 1;
    while (i < line.len) {
        const start = i;
        while (i < line.len and !isAwkPlaceholderWhitespace(line[i])) i += 1;
        while (i < line.len and isAwkPlaceholderWhitespace(line[i])) i += 1;
        try out.append(allocator, line[start..i]);
    }
}

fn isAwkPlaceholderWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn appendPlaceholderRange(allocator: Allocator, out: *std.ArrayList(u8), tokens: []const []const u8, range: PlaceholderRange) !void {
    const count: isize = @intCast(tokens.len);
    if (range.begin == range.end) {
        if (range.begin == 0) {
            for (tokens) |token| try out.appendSlice(allocator, token);
            return;
        }
        var idx = range.begin;
        if (idx < 0) idx += count + 1;
        if (idx >= 1 and idx <= count) try out.appendSlice(allocator, tokens[@intCast(idx - 1)]);
        return;
    }

    var begin: isize = undefined;
    var end: isize = undefined;
    if (range.begin == 0) {
        begin = 1;
        end = range.end;
        if (end < 0) end += count + 1;
    } else if (range.end == 0) {
        begin = range.begin;
        if (begin < 0) begin += count + 1;
        end = count;
    } else {
        begin = range.begin;
        end = range.end;
        if (begin < 0) begin += count + 1;
        if (end < 0) end += count + 1;
    }
    if (begin > end) return;
    var idx = begin;
    while (idx <= end) : (idx += 1) {
        if (idx >= 1 and idx <= count) try out.appendSlice(allocator, tokens[@intCast(idx - 1)]);
        if (idx == std.math.maxInt(isize)) break;
    }
}

fn trimUnicodeWhitespaceSlice(s: []const u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(s)) return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var first_non_white: ?usize = null;
    var last_non_white_end: usize = 0;
    while (it.i < s.len) {
        const start = it.i;
        const cp = it.nextCodepoint() orelse break;
        if (!fuzzy_engine.cliRuneIsWhitespace(cp)) {
            if (first_non_white == null) first_non_white = start;
            last_non_white_end = it.i;
        }
    }
    const start = first_non_white orelse return s[s.len..];
    return s[start..last_non_white_end];
}

fn appendShellQuoted(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const quoted = try shellQuote(allocator, s);
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
}

fn appendDecimal(allocator: Allocator, out: *std.ArrayList(u8), n: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{n});
    try out.appendSlice(allocator, text);
}

fn shellQuote(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

const usage =
    \\Usage: zfuzz [OPTIONS]
    \\
    \\Interactive fuzzy finder backed by zig_fuzzy's exact fzf-V2 ranking core.
    \\
    \\Search
    \\  -e, --exact / +e, --no-exact
    \\                           enable / disable exact-match mode
    \\  -i, --ignore-case        force case-insensitive matching
    \\  +i, --no-ignore-case     force case-sensitive matching
    \\      --smart-case         smart-case matching (default)
    \\      --literal            disable Unicode normalization
    \\  +x, --no-extended        disable extended query grammar
    \\  -q, --query=STR          start with query
    \\  -f, --filter=STR         non-interactive filter mode
    \\  -1, --select-1 / +1, --no-select-1
    \\                           enable / disable single-match auto-accept
    \\  -0, --exit-0 / +0, --no-exit-0
    \\                           enable / disable no-match auto-exit
    \\  -s, --sort[=N]        enable sorting when N > 0 (default 1)
    \\      --no-sort            preserve input order after filtering
    \\      --raw                show non-matching items dimmed alongside matches
    \\      --tiebreak=CRI       score tie-breaks: length/chunk/pathname/begin/end/index
    \\      --algo=ALGO          fuzzy algorithm: v2 (default), v1, heuristic (exact V2 ranking)
    \\      --scheme=SCHEME      ranking scheme: default/path/history
    \\      --tail=N             keep only the last N input items in memory
    \\      --track              keep current item focused across result updates
    \\      --id-nth=EXPR / --no-id-nth
    \\                           set / clear identity fields for tracking/reload
    \\      --history=FILE / --no-history
    \\                           enable / disable persisted query history
    \\      --history-size=N     cap persisted history entries (default 1000)
    \\  -d, --delimiter=STR      literal field delimiter
    \\  -n, --nth=EXPR           limit searchable fields
    \\      --with-nth=EXPR      transform displayed fields
    \\      --accept-nth=EXPR    transform accepted output
    \\      --disabled, --phony  do not filter; useful with reload bindings
    \\      --enabled, --no-phony
    \\                           re-enable filtering (last option wins)
    \\
    \\Selection and I/O
    \\  -m, --multi[=MAX]        multi-select; Tab / Shift-Tab toggle
    \\  +m, --no-multi          disable multi-select
    \\      --read0 / --no-read0 NUL / newline-delimited input
    \\      --print0 / --no-print0
    \\                           NUL / newline-delimited output
    \\      --print-query / --no-print-query
    \\                           enable / disable query output before selection
    \\      --expect=KEYS        print accepted key field
    \\      --bind=SPEC          key/event actions: reload/execute/become/toggle...
    \\                           includes dynamic multi/field, raw/match, and exclusion actions
    \\      --ansi / --no-ansi   enable / disable ANSI processing
    \\      --sync / --no-sync, --async
    \\                           enable / disable synchronous input search
    \\      --tac / --no-tac     enable / disable reversed input order
    \\
    \\UI
    \\  +c, --no-color          disable color styling
    \\      --reverse / --no-reverse
    \\                           top-down / default layout
    \\      --height=N%          constrain rendered height
    \\      --cycle / --no-cycle enable / disable cyclic navigation
    \\      --filepath-word      word actions respect path separators
    \\      --scroll-off=N       keep N rows around the current item (source default: 3)
    \\      --wrap / --no-wrap    enable / disable long-item wrapping
    \\      --no-input           start with the input section hidden
    \\      --prompt=STR         prompt string
    \\      --pointer=STR        current-item pointer
    \\      --marker=STR         selected-item marker
    \\      --header=STR / --no-header
    \\                           set / clear header text
    \\      --header-lines=N / --no-header-lines
    \\                           set / clear non-selectable input header lines
    \\      --header-first       print header before prompt in reverse layout
    \\      --footer=STR / --no-footer
    \\                           set / clear footer text
    \\      --border-label=STR / --no-border-label
    \\                           set / clear outer border label
    \\      --no-border          disable border reservation
    \\      --no-mouse           disable xterm mouse tracking
    \\
    \\Preview
    \\      --preview=COMMAND / --no-preview
    \\                           set / clear focused-item preview command
    \\      --preview-label=STR / --no-preview-label
    \\                           set / clear preview border label
    \\      --preview-window=OPT right/left/up/down, SIZE%, hidden, wrap/nowrap
    \\                           {}, {+}, {*}, {1}, {q}, {q:2..}, {n}
    \\                           flags: r raw, s preserve-space, f temp-file
    \\                           prefix a valid placeholder with a backslash to escape it
    \\
    \\Keys
    \\  Enter accept, Esc/Ctrl-C abort, arrows/Ctrl-J/Ctrl-K move,
    \\  Ctrl-P/N history when --history is active, Tab toggle,
    \\  Ctrl-A/E line edges, Ctrl-U clear, Ctrl-W erase word.
;

test "vertical navigation follows visual layout direction" {
    try std.testing.expectEqual(@as(isize, 1), logicalVerticalDelta(.default, -1));
    try std.testing.expectEqual(@as(isize, -1), logicalVerticalDelta(.default, 1));
    try std.testing.expectEqual(@as(isize, -1), logicalVerticalDelta(.reverse, -1));
    try std.testing.expectEqual(@as(isize, 1), logicalVerticalDelta(.reverse, 1));
}

test "partial result refresh keeps cursor position stable" {
    try std.testing.expectEqual(@as(usize, 0), stableResultFocus(0, 512));
    try std.testing.expectEqual(@as(usize, 17), stableResultFocus(17, 512));
    try std.testing.expectEqual(@as(usize, 17), stableResultFocus(17, 64));
    try std.testing.expectEqual(@as(usize, 7), stableResultFocus(17, 8));
    try std.testing.expectEqual(@as(usize, 0), stableResultFocus(17, 0));
}

test "empty lazy partial preserves cursor hint" {
    const empty = refreshLazyFocus(512, 17, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.focus);
    try std.testing.expectEqual(@as(usize, 17), empty.hint);
    const restored = refreshLazyFocus(0, empty.focus, empty.hint, 512);
    try std.testing.expectEqual(@as(usize, 17), restored.focus);
    try std.testing.expectEqual(@as(usize, 17), restored.hint);
    const clamped = refreshLazyFocus(0, 0, restored.hint, 8);
    try std.testing.expectEqual(@as(usize, 7), clamped.focus);
    try std.testing.expectEqual(@as(usize, 7), clamped.hint);
}

test "lazy partial publishing fills the display or reaches the scan fallback" {
    try std.testing.expect(!lazyShouldPublishFirst(1024, 511, 512));
    try std.testing.expect(lazyShouldPublishFirst(1024, 512, 512));
    try std.testing.expect(!lazyShouldPublishFirst(4095, 3, 512));
    try std.testing.expect(lazyShouldPublishFirst(4096, 0, 512));
    try std.testing.expectEqual(@as(u64, 20), lazy_progress_publish_interval_ms);
}

test "scroll-off viewport constraint matches single-line fzf semantics" {
    try std.testing.expectEqual(@as(usize, 2), effectiveScrollOff(6, 3));
    try std.testing.expectEqual(@as(usize, 0), effectiveScrollOff(1, 3));
    // 20 visible rows, default scroll-off 3: keep the cursor three rows
    // from either edge once list boundaries no longer make that impossible.
    const rows: usize = 20;
    const off: usize = 3;
    const count: usize = 100;
    const cases = [_]struct { focus: usize, prior: usize, expected: usize }{
        .{ .focus = 0, .prior = 0, .expected = 0 },
        .{ .focus = 3, .prior = 0, .expected = 0 },
        .{ .focus = 16, .prior = 0, .expected = 0 },
        .{ .focus = 17, .prior = 0, .expected = 1 },
        .{ .focus = 50, .prior = 1, .expected = 34 },
        .{ .focus = 98, .prior = 80, .expected = 80 },
        .{ .focus = 99, .prior = 80, .expected = 80 },
    };
    for (cases) |case| {
        const visible = @min(rows, count);
        const max_scroll = count - visible;
        const scroll_off = effectiveScrollOff(visible, off);
        const base_min = case.focus -| (visible - 1);
        const base_max = @min(max_scroll, case.focus);
        const lower = @min(base_max, @max(base_min, case.focus -| (visible - 1 - scroll_off)));
        const upper = @max(base_min, @min(base_max, case.focus -| scroll_off));
        try std.testing.expectEqual(case.expected, std.math.clamp(case.prior, lower, upper));
    }
}

test "filepath word boundaries match fzf path separators" {
    const q = "--/foo bar/foo-bar/baz";
    var cursor: usize = q.len;
    cursor = filepathWordBoundaryBackward(q, cursor);
    try std.testing.expectEqual(@as(usize, 19), cursor);
    cursor = filepathWordBoundaryBackward(q, cursor);
    try std.testing.expectEqual(@as(usize, 11), cursor);
    cursor = filepathWordBoundaryBackward(q, cursor);
    try std.testing.expectEqual(@as(usize, 3), cursor);
    try std.testing.expectEqual(@as(usize, 10), filepathWordBoundaryForward(q, 3));
    try std.testing.expectEqual(q.len, filepathWordBoundaryForward(q, 18));
    try std.testing.expectEqual(@as(usize, 0), filepathWordBoundaryBackward("foo/bar", 3));
}

test "query history preserves edited navigation slots" {
    const a = std.testing.allocator;
    const path = "/tmp/zfuzz-history-navigation-test";
    Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "first\nsecond\n" }) catch {};
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var history = try QueryHistory.init(a, std.testing.io, path, 1000, "draft");
    defer history.deinit();
    try std.testing.expectEqualStrings("second", (try history.move(-1, "draft")).?);
    try std.testing.expectEqualStrings("first", (try history.move(-1, "second-edit")).?);
    try std.testing.expectEqualStrings("second-edit", (try history.move(1, "first")).?);
    try std.testing.expectEqualStrings("draft", (try history.move(1, "second-edit")).?);
}

test "walker options match fzf defaults and parse explicit modes" {
    const default: WalkerOptions = .{};
    try std.testing.expect(default.file);
    try std.testing.expect(!default.dir);
    try std.testing.expect(default.follow);
    try std.testing.expect(default.hidden);

    const dirs = try parseWalkerOptions("DIR,FoLlOw");
    try std.testing.expect(!dirs.file);
    try std.testing.expect(dirs.dir);
    try std.testing.expect(dirs.follow);
    try std.testing.expect(!dirs.hidden);
    try std.testing.expectError(error.InvalidWalkerOption, parseWalkerOptions("file,bogus"));
    try std.testing.expectError(error.InvalidWalkerOption, parseWalkerOptions("follow,hidden"));
    try std.testing.expectError(error.InvalidWalkerOption, parseWalkerOptions(""));
}

fn testWalkerHasRecord(blob: []const u8, delim: u8, expected: []const u8) bool {
    var it = std.mem.splitScalar(u8, blob, delim);
    while (it.next()) |record| if (std.mem.eql(u8, record, expected)) return true;
    return false;
}

test "default command uses the platform shell and streams stdout" {
    const a = std.testing.allocator;
    const command = if (builtin.os.tag == .windows) "echo beta" else "printf 'beta\\n'";
    const got = try runDefaultCommand(a, std.testing.io, command, null);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "beta") != null);
}

test "walker platform implementation enumerates an explicit root" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "needle.txt", .data = "" });

    const root_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(root_path);
    var options: Options = .{ .walker = .{ .file = true, .dir = false, .follow = true, .hidden = true } };
    defer options.deinit(a);
    try options.walker_roots.append(a, root_path);

    const blob = try runWalker(a, std.testing.io, &options);
    defer a.free(blob);
    const expected = try std.fs.path.join(a, &.{ root_path, "needle.txt" });
    defer a.free(expected);
    try std.testing.expect(testWalkerHasRecord(blob, '\n', expected));
}

test "native walker recurses and honors skip hidden and record delimiter" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var visible = try tmp.dir.createDirPathOpen(std.testing.io, "visible", .{});
    visible.close(std.testing.io);
    var skipped = try tmp.dir.createDirPathOpen(std.testing.io, "node_modules", .{});
    skipped.close(std.testing.io);
    var hidden = try tmp.dir.createDirPathOpen(std.testing.io, ".hidden-dir", .{});
    hidden.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "top.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden-file", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "visible/keep.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/skip.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden-dir/skip.txt", .data = "" });

    var options: Options = .{ .walker = .{ .file = true, .dir = true, .follow = false, .hidden = false } };
    defer options.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &out);

    const sep = std.fs.path.sep_str;
    const top = try std.mem.concat(a, u8, &.{ "ROOT", sep, "top.txt" });
    defer a.free(top);
    const hidden_file = try std.mem.concat(a, u8, &.{ "ROOT", sep, ".hidden-file" });
    defer a.free(hidden_file);
    const visible_dir = try std.mem.concat(a, u8, &.{ "ROOT", sep, "visible", sep });
    defer a.free(visible_dir);
    const keep = try std.mem.concat(a, u8, &.{ "ROOT", sep, "visible", sep, "keep.txt" });
    defer a.free(keep);
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', top));
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', hidden_file));
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', visible_dir));
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', keep));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "node_modules") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".hidden-dir") == null);

    options.read0 = true;
    var nul_out: std.ArrayList(u8) = .empty;
    defer nul_out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &nul_out);
    try std.testing.expect(testWalkerHasRecord(nul_out.items, 0, keep));
    try std.testing.expect(std.mem.indexOfScalar(u8, nul_out.items, '\n') == null);
}

fn testWalkerRecordCount(blob: []const u8, delim: u8, expected: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, blob, delim);
    while (it.next()) |record| {
        if (std.mem.eql(u8, record, expected)) count += 1;
    }
    return count;
}

test "walker skip policy matches exact names and hidden directory mode" {
    var options: Options = .{};
    defer options.deinit(std.testing.allocator);
    options.walker_skip = "cache,,node_modules";
    options.walker.hidden = false;
    try std.testing.expect(walkerDirSkipped(&options, ".", ".hidden", ".hidden"));
    try std.testing.expect(walkerDirSkipped(&options, ".", "cache", "cache"));
    try std.testing.expect(walkerDirSkipped(&options, ".", "node_modules", "node_modules"));
    try std.testing.expect(!walkerDirSkipped(&options, ".", "cache2", "cache2"));
    try std.testing.expect(!walkerDirSkipped(&options, ".", "src", "src"));
    options.walker_skip = "foo/bar,/deep/cache";
    try std.testing.expect(walkerDirSkipped(&options, ".", "x/foo/bar", "bar"));
    try std.testing.expect(!walkerDirSkipped(&options, ".", "deep/cache", "cache"));
    try std.testing.expect(walkerDirSkipped(&options, ".", "a/deep/cache", "cache"));
    try std.testing.expect(!walkerDirSkipped(&options, ".", "xfoo/bar", "bar"));
    try std.testing.expect(!walkerDirSkipped(&options, ".", "foo/bar2", "bar2"));

    options.walker_skip = "cache";
    options.walker.hidden = true;
    try std.testing.expect(!walkerDirSkipped(&options, ".", ".hidden", ".hidden"));
    try std.testing.expect(walkerDirSkipped(&options, ".", "cache", "cache"));
}

test "walker path assembly avoids duplicate separators and supports NUL" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try walkerAppendPath(&out, a, ".", "one", false, '\n');
    const rooted = try std.mem.concat(a, u8, &.{ ".", std.fs.path.sep_str, "ROOT", std.fs.path.sep_str });
    defer a.free(rooted);
    try walkerAppendPath(&out, a, rooted, "two", true, 0);
    const expected = try std.mem.concat(a, u8, &.{ "one\nROOT", std.fs.path.sep_str, "two", std.fs.path.sep_str, "\x00" });
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, out.items);
}

test "native walker keeps file and directory selection distinct" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var child = try tmp.dir.createDirPathOpen(std.testing.io, "dir", .{});
    child.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "top.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dir/nested.txt", .data = "" });

    const dir_path = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "dir", std.fs.path.sep_str });
    defer a.free(dir_path);
    const top_path = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "top.txt" });
    defer a.free(top_path);
    const nested_path = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "dir", std.fs.path.sep_str, "nested.txt" });
    defer a.free(nested_path);

    var files: Options = .{ .walker = .{ .file = true, .dir = false, .follow = false, .hidden = true }, .walker_skip = "" };
    defer files.deinit(a);
    var file_out: std.ArrayList(u8) = .empty;
    defer file_out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &files, "ROOT", tmp.dir, &file_out);
    try std.testing.expect(testWalkerHasRecord(file_out.items, '\n', top_path));
    try std.testing.expect(testWalkerHasRecord(file_out.items, '\n', nested_path));
    try std.testing.expect(!testWalkerHasRecord(file_out.items, '\n', dir_path));

    var dirs: Options = .{ .walker = .{ .file = false, .dir = true, .follow = false, .hidden = true }, .walker_skip = "" };
    defer dirs.deinit(a);
    var dir_out: std.ArrayList(u8) = .empty;
    defer dir_out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &dirs, "ROOT", tmp.dir, &dir_out);
    try std.testing.expect(testWalkerHasRecord(dir_out.items, '\n', dir_path));
    try std.testing.expect(!testWalkerHasRecord(dir_out.items, '\n', top_path));
    try std.testing.expect(!testWalkerHasRecord(dir_out.items, '\n', nested_path));
}

fn testWalkerNonEmptyRecordCount(blob: []const u8, delim: u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, blob, delim);
    while (it.next()) |record| {
        if (record.len != 0) count += 1;
    }
    return count;
}

fn testWalkerNativeExpectedPath(allocator: Allocator, rel: []const u8, is_dir: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "ROOT");
    try out.append(allocator, std.fs.path.sep);
    for (rel) |byte| try out.append(allocator, if (byte == '/') std.fs.path.sep else byte);
    if (is_dir) try out.append(allocator, std.fs.path.sep);
    return try out.toOwnedSlice(allocator);
}

test "native walker exhaustively covers mode follow hidden delimiter and skip combinations" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    inline for (.{ "vis", "vis/keepdir", "skip", "vis/skip", ".hid" }) |name| {
        var dir = try tmp.dir.createDirPathOpen(std.testing.io, name, .{});
        dir.close(std.testing.io);
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "top.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".dotfile", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vis/a.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skip/s.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vis/skip/n.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hid/h.txt", .data = "" });

    const FileCase = struct { rel: []const u8, hidden_dir: bool = false, skipped: bool = false };
    const DirCase = struct { rel: []const u8, hidden_dir: bool = false, skipped: bool = false };
    const file_cases = [_]FileCase{
        .{ .rel = "top.txt" },
        .{ .rel = ".dotfile" },
        .{ .rel = "vis/a.txt" },
        .{ .rel = "skip/s.txt", .skipped = true },
        .{ .rel = "vis/skip/n.txt", .skipped = true },
        .{ .rel = ".hid/h.txt", .hidden_dir = true },
    };
    const dir_cases = [_]DirCase{
        .{ .rel = "vis" },
        .{ .rel = "vis/keepdir" },
        .{ .rel = "skip", .skipped = true },
        .{ .rel = "vis/skip", .skipped = true },
        .{ .rel = ".hid", .hidden_dir = true },
    };
    const modes = [_]WalkerOptions{
        .{ .file = true, .dir = false, .follow = false, .hidden = false },
        .{ .file = false, .dir = true, .follow = false, .hidden = false },
        .{ .file = true, .dir = true, .follow = false, .hidden = false },
    };

    var combination_count: usize = 0;
    for (modes) |base_mode| {
        for ([_]bool{ false, true }) |follow| {
            for ([_]bool{ false, true }) |hidden| {
                for ([_]bool{ false, true }) |read0| {
                    for ([_]bool{ false, true }) |with_skip| {
                        var options: Options = .{
                            .walker = .{ .file = base_mode.file, .dir = base_mode.dir, .follow = follow, .hidden = hidden },
                            .walker_skip = if (with_skip) "skip" else "",
                            .read0 = read0,
                        };
                        defer options.deinit(a);
                        var out: std.ArrayList(u8) = .empty;
                        defer out.deinit(a);
                        try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &out);
                        const delim: u8 = if (read0) 0 else '\n';
                        var expected_count: usize = 0;
                        for (file_cases) |case| {
                            const should = base_mode.file and (!case.hidden_dir or hidden) and (!case.skipped or !with_skip);
                            const path = try testWalkerNativeExpectedPath(a, case.rel, false);
                            defer a.free(path);
                            try std.testing.expectEqual(should, testWalkerHasRecord(out.items, delim, path));
                            if (should) expected_count += 1;
                        }
                        for (dir_cases) |case| {
                            const should = base_mode.dir and (!case.hidden_dir or hidden) and (!case.skipped or !with_skip);
                            const path = try testWalkerNativeExpectedPath(a, case.rel, true);
                            defer a.free(path);
                            try std.testing.expectEqual(should, testWalkerHasRecord(out.items, delim, path));
                            if (should) expected_count += 1;
                        }
                        try std.testing.expectEqual(expected_count, testWalkerNonEmptyRecordCount(out.items, delim));
                        combination_count += 1;
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 48), combination_count);
}

test "native walker traverses hidden directories when enabled and prunes custom skips" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var hidden = try tmp.dir.createDirPathOpen(std.testing.io, ".hidden", .{});
    hidden.close(std.testing.io);
    var cache = try tmp.dir.createDirPathOpen(std.testing.io, "cache", .{});
    cache.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden/keep.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cache/drop.txt", .data = "" });

    var options: Options = .{ .walker = .{ .file = true, .dir = false, .follow = false, .hidden = true }, .walker_skip = "cache" };
    defer options.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &out);
    const keep = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, ".hidden", std.fs.path.sep_str, "keep.txt" });
    defer a.free(keep);
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', keep));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "cache") == null);
}

test "native walker symlink semantics match fzf and terminate ancestor cycles" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(std.testing.io, "dir", .{});
    dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dir/keep.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "" });
    try tmp.dir.symLink(std.testing.io, "..", "dir/loop", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "plain.txt", "file-link", .{});
    try tmp.dir.symLink(std.testing.io, "missing-target", "dangling", .{});

    var options: Options = .{ .walker = .{ .file = true, .dir = false, .follow = true, .hidden = true }, .walker_skip = "" };
    defer options.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &out);
    const keep = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "dir", std.fs.path.sep_str, "keep.txt" });
    defer a.free(keep);
    const file_link = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "file-link" });
    defer a.free(file_link);
    const dangling = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "dangling" });
    defer a.free(dangling);
    try std.testing.expectEqual(@as(usize, 1), testWalkerRecordCount(out.items, '\n', keep));
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', file_link));
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', dangling));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "loop") == null);

    options.walker.follow = false;
    var no_follow: std.ArrayList(u8) = .empty;
    defer no_follow.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &no_follow);
    try std.testing.expect(testWalkerHasRecord(no_follow.items, '\n', file_link));
    try std.testing.expect(testWalkerHasRecord(no_follow.items, '\n', dangling));
    try std.testing.expect(std.mem.indexOf(u8, no_follow.items, "loop") == null);
}

test "native walker prunes followed directory symlinks to root ancestors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.txt", .data = "" });
    try tmp.dir.symLink(std.testing.io, std.fs.path.sep_str, "escape-to-root", .{ .is_directory = true });

    var options: Options = .{ .walker = .{ .file = true, .dir = true, .follow = true, .hidden = true }, .walker_skip = "" };
    defer options.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendNativeWalkerRoot(a, std.testing.io, &options, "ROOT", tmp.dir, &out);
    const keep = try std.mem.concat(a, u8, &.{ "ROOT", std.fs.path.sep_str, "keep.txt" });
    defer a.free(keep);
    try std.testing.expect(testWalkerHasRecord(out.items, '\n', keep));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "escape-to-root") == null);
    try std.testing.expectEqual(@as(usize, 1), testWalkerNonEmptyRecordCount(out.items, '\n'));
}

test "walker platform implementation supports multiple roots and NUL records" {
    const a = std.testing.allocator;
    var first = std.testing.tmpDir(.{ .iterate = true });
    defer first.cleanup();
    var second = std.testing.tmpDir(.{ .iterate = true });
    defer second.cleanup();
    try first.dir.writeFile(std.testing.io, .{ .sub_path = "one.txt", .data = "" });
    try second.dir.writeFile(std.testing.io, .{ .sub_path = "two.txt", .data = "" });

    const first_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &first.sub_path });
    defer a.free(first_root);
    const second_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &second.sub_path });
    defer a.free(second_root);
    var options: Options = .{ .walker = .{ .file = true, .dir = false, .follow = true, .hidden = true }, .walker_skip = "", .read0 = true };
    defer options.deinit(a);
    try options.walker_roots.appendSlice(a, &.{ first_root, second_root });

    const blob = try runWalker(a, std.testing.io, &options);
    defer a.free(blob);
    const one = try std.fs.path.join(a, &.{ first_root, "one.txt" });
    defer a.free(one);
    const two = try std.fs.path.join(a, &.{ second_root, "two.txt" });
    defer a.free(two);
    try std.testing.expect(testWalkerHasRecord(blob, 0, one));
    try std.testing.expect(testWalkerHasRecord(blob, 0, two));
    try std.testing.expect(std.mem.indexOfScalar(u8, blob, '\n') == null);
}

test "default command streams across multiple reader buffers" {
    const a = std.testing.allocator;
    const command = if (builtin.os.tag == .windows)
        "for /L %i in (1,1,5000) do @echo 0123456789abcdef"
    else
        "i=0; while [ $i -lt 5000 ]; do printf '0123456789abcdef\\n'; i=$((i + 1)); done";
    const got = try runDefaultCommand(a, std.testing.io, command, null);
    defer a.free(got);
    try std.testing.expect(got.len > 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, got, "0123456789abcdef") != null);
}

test "default command keeps stderr out of candidates" {
    const a = std.testing.allocator;
    const command = if (builtin.os.tag == .windows)
        "echo stdout-line & echo stderr-line 1>&2"
    else
        "printf 'stdout-line\\n'; printf 'stderr-line\\n' >&2";
    const got = try runDefaultCommand(a, std.testing.io, command, null);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "stdout-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "stderr-line") == null);
}

test "default command preserves stdout even when command exits nonzero" {
    const a = std.testing.allocator;
    const command = if (builtin.os.tag == .windows)
        "echo before-failure & exit /b 7"
    else
        "printf 'before-failure\\n'; exit 7";
    const got = try runDefaultCommand(a, std.testing.io, command, null);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "before-failure") != null);
}

test "walker root option consumes directories and replaces prior roots" {
    const a = std.testing.allocator;

    const args = [_][]const u8{ "zfuzz", "--walker-root=not-required-to-exist", "--walker-root", "src", "tests", "--no-sort" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), options.walker_roots.items.len);
    try std.testing.expectEqualStrings("src", options.walker_roots.items[0]);
    try std.testing.expectEqualStrings("tests", options.walker_roots.items[1]);
    try std.testing.expect(options.no_sort);

    try std.testing.expectError(error.NoDirectorySpecified, parseOptions(a, &.{ "zfuzz", "--walker-root", "__zfuzz_missing_walker_root__" }));
}

test "stream input retains bounded tail across partial records" {
    const a = std.testing.allocator;
    var stream = StreamInput.init(a, '\n', 2, 0);
    defer stream.deinit();
    try std.testing.expect(try stream.consume("a\nb\nc\n"));
    var blob = try stream.materializeBlob();
    try std.testing.expectEqualStrings("b\nc\n", blob);
    a.free(blob);
    try std.testing.expect(!(try stream.consume("d")));
    try std.testing.expect(try stream.finish());
    blob = try stream.materializeBlob();
    defer a.free(blob);
    try std.testing.expectEqualStrings("c\nd\n", blob);
}

test "header lines remain outside bounded tail except empty filter snapshot" {
    const a = std.testing.allocator;
    var options: Options = .{ .header_lines = 1, .tail = 2 };
    defer options.deinit(a);
    const blob = try a.dupe(u8, "HEADER\none\ntwo\nthree\n");
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), candidates.header.len);
    try std.testing.expectEqualStrings("HEADER", candidates.header[0]);
    try std.testing.expectEqual(@as(usize, 2), candidates.output.len);
    try std.testing.expectEqualStrings("two", candidates.output[0]);
    try std.testing.expectEqualStrings("three", candidates.output[1]);

    var stream = StreamInput.init(a, '\n', 2, 1);
    defer stream.deinit();
    try std.testing.expect(try stream.consume("HEADER\none\ntwo\nthree\n"));
    const streamed = try stream.materializeBlob();
    defer a.free(streamed);
    try std.testing.expectEqualStrings("HEADER\ntwo\nthree\n", streamed);

    var filter_options: Options = .{ .header_lines = 1, .tail = 2, .filter = "" };
    defer filter_options.deinit(a);
    const filter_blob = try a.dupe(u8, "HEADER\none\ntwo\nthree\n");
    var filtered = try candidatesFromOwnedBlob(a, filter_blob, &filter_options);
    defer filtered.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), filtered.output.len);
    try std.testing.expectEqualStrings("three", filtered.output[0]);
}

test "tail retains last records and empty input stays empty" {
    const a = std.testing.allocator;
    var options: Options = .{ .tail = 2 };
    defer options.deinit(a);
    const blob = try a.dupe(u8, "one\ntwo\nthree\nfour\n");
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), candidates.output.len);
    try std.testing.expectEqualStrings("three", candidates.output[0]);
    try std.testing.expectEqualStrings("four", candidates.output[1]);

    var empty_options: Options = .{};
    defer empty_options.deinit(a);
    const empty_blob = try a.alloc(u8, 0);
    var empty = try candidatesFromOwnedBlob(a, empty_blob, &empty_options);
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.output.len);
}

test "height and border option forms" {
    const a = std.testing.allocator;
    var options: Options = .{};
    defer options.deinit(a);
    const args = [_][]const u8{ "zfuzz", "--height", "40%", "--border", "--sync" };
    try parseOptionsInto(a, std.testing.io, &options, &args, 1);
    try std.testing.expectEqual(@as(u8, 40), options.height_percent);
    try std.testing.expect(options.border);
    try std.testing.expect(options.sync);
    const reset = [_][]const u8{ "zfuzz", "--no-height", "--no-border" };
    try parseOptionsInto(a, std.testing.io, &options, &reset, 1);
    try std.testing.expectEqual(@as(u8, 100), options.height_percent);
    try std.testing.expect(!options.border);
}

test "strip ANSI CSI" {
    const a = std.testing.allocator;
    const got = try stripAnsi(a, "a\x1b[31mred\x1b[0mz");
    defer a.free(got);
    try std.testing.expectEqualStrings("aredz", got);
}

test "preview placeholder quoting" {
    const a = std.testing.allocator;
    const got = try expandPreviewCommand(a, "echo {} {q}", "a'b", "x y");
    defer a.free(got);
    try std.testing.expectEqualStrings("echo 'a'\\''b' 'x y'", got);
}

test "selected and field command placeholders" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "one,two\nthree,four\n");
    var options: Options = .{ .delimiter = "," };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    const selected = [_]bool{ true, true };
    const order = [_]usize{ 1, 0 };
    const matched = [_]usize{ 0, 1 };
    const got = try expandCommand(a, "echo {n} {1} {+} {+2} {q}", "x y", &candidates, &options, 0, &order, &selected, &matched);
    defer a.free(got);
    try std.testing.expectEqualStrings("echo 0 'one' 'three,four' 'one,two' 'four' 'two' 'x y'", got);
}

test "execute-multi force-plus placeholders" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "one,two\nthree,four\n");
    var options: Options = .{ .delimiter = "," };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    const selected = [_]bool{ true, true };
    const order = [_]usize{ 1, 0 };
    const matched = [_]usize{ 0, 1 };

    const got = try expandCommandImplWithForcePlus(a, "echo {}|{2}|{n}|{q}|{*1}", "x y", &candidates, &options, 0, &order, &selected, &matched, "execute-multi", options.prompt, null, null, true);
    defer a.free(got);
    try std.testing.expectEqualStrings("echo 'three,four' 'one,two'|'four' 'two'|1 0|'x y'|'one' 'three'", got);

    const none = [_]bool{ false, false };
    const fallback = try expandCommandImplWithForcePlus(a, "echo {}|{2}|{n}", "", &candidates, &options, 1, &.{}, &none, &matched, "execute-multi", options.prompt, null, null, true);
    defer a.free(fallback);
    try std.testing.expectEqualStrings("echo 'three,four'|'four'|1", fallback);
}

test "file placeholders materialize selected fields" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "one,two\nthree,four\n");
    var options: Options = .{ .delimiter = "," };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    const selected = [_]bool{ true, true };
    const order = [_]usize{ 1, 0 };
    var temp_files: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_files.items) |path| {
            Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
            a.free(path);
        }
        temp_files.deinit(a);
    }

    const matched = [_]usize{ 0, 1 };
    const got = try expandCommandImpl(a, "cat {+f1}", "", &candidates, &options, 0, &order, &selected, &matched, "", options.prompt, std.testing.io, &temp_files);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), temp_files.items.len);
    try std.testing.expect(std.fs.path.isAbsolute(temp_files.items[0]));
    const temp_name = std.fs.path.basename(temp_files.items[0]);
    try std.testing.expect(std.mem.startsWith(u8, temp_name, "zfuzz-"));
    try std.testing.expect(std.mem.endsWith(u8, temp_name, ".tmp"));
    try std.testing.expect(std.mem.indexOf(u8, got, temp_files.items[0]) != null);

    const file = try Io.Dir.openFileAbsolute(std.testing.io, temp_files.items[0], .{});
    defer file.close(std.testing.io);
    var buffer: [256]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const contents = try reader.interface.allocRemaining(a, .unlimited);
    defer a.free(contents);
    try std.testing.expectEqualStrings("three\none\n", contents);
}

test "execute-multi force-plus file placeholders" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "one,two\nthree,four\n");
    var options: Options = .{ .delimiter = "," };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    const selected = [_]bool{ true, true };
    const order = [_]usize{ 1, 0 };
    const matched = [_]usize{ 0, 1 };
    var temp_files: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_files.items) |file_path| {
            Io.Dir.deleteFileAbsolute(std.testing.io, file_path) catch {};
            a.free(file_path);
        }
        temp_files.deinit(a);
    }

    const got = try expandCommandImplWithForcePlus(a, "cat {f1}", "", &candidates, &options, 0, &order, &selected, &matched, "execute-multi", options.prompt, std.testing.io, &temp_files, true);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), temp_files.items.len);
    const file = try Io.Dir.openFileAbsolute(std.testing.io, temp_files.items[0], .{});
    defer file.close(std.testing.io);
    var buffer: [256]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const contents = try reader.interface.allocRemaining(a, .unlimited);
    defer a.free(contents);
    try std.testing.expectEqualStrings("three\none\n", contents);
}

test "fzf placeholder flags matched items and escaping" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "  one ,two  \nthree , four\n");
    var options: Options = .{ .delimiter = ",", .prompt = "pick> " };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);

    const selected = [_]bool{ true, false };
    const order = [_]usize{0};
    const matched = [_]usize{ 1, 0 };
    const got = try expandCommandImpl(
        a,
        "echo {1}|{s1}|{r1}|{r}|{*1}|{*n}|{q:2..}|{fzf:query}|{fzf:action}|{fzf:prompt}|\\{}|{n.t}",
        "alpha   beta gamma",
        &candidates,
        &options,
        0,
        &order,
        &selected,
        &matched,
        "execute-silent",
        options.prompt,
        null,
        null,
    );
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "echo 'one'|'  one '|one|  one ,two  |'three' 'one'|1 0|'beta gamma'|'alpha   beta gamma'|'execute-silent'|'pick> '|{}|{n.t}",
        got,
    );
}

test "matched file placeholder materializes transformed values" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "  one ,two  \nthree , four\n");
    var options: Options = .{ .delimiter = "," };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    const selected = [_]bool{ false, false };
    const matched = [_]usize{ 1, 0 };
    var temp_files: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_files.items) |path| {
            Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
            a.free(path);
        }
        temp_files.deinit(a);
    }

    const got = try expandCommandImpl(a, "cat {*f1}", "", &candidates, &options, 0, &.{}, &selected, &matched, "", options.prompt, std.testing.io, &temp_files);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), temp_files.items.len);
    try std.testing.expect(std.fs.path.isAbsolute(temp_files.items[0]));
    const temp_name = std.fs.path.basename(temp_files.items[0]);
    try std.testing.expect(std.mem.startsWith(u8, temp_name, "zfuzz-"));
    try std.testing.expect(std.mem.endsWith(u8, temp_name, ".tmp"));
    try std.testing.expect(std.mem.indexOf(u8, got, temp_files.items[0]) != null);

    const file = try Io.Dir.openFileAbsolute(std.testing.io, temp_files.items[0], .{});
    defer file.close(std.testing.io);
    var buffer: [256]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const contents = try reader.interface.allocRemaining(a, .unlimited);
    defer a.free(contents);
    try std.testing.expectEqualStrings("three\none\n", contents);
}

test "placeholder field transforms follow fzf token ranges" {
    const a = std.testing.allocator;

    const one = try transformPlaceholderFields(a, "  foo'bar baz", null, "1", false);
    defer a.free(one);
    try std.testing.expectEqualStrings("foo'bar", one);

    const reversed = try transformPlaceholderFields(a, "  foo'bar baz", null, "2,1", false);
    defer a.free(reversed);
    try std.testing.expectEqualStrings("bazfoo'bar", reversed);

    const all = try transformPlaceholderFields(a, "  foo'bar baz", null, "..", false);
    defer a.free(all);
    try std.testing.expectEqualStrings("foo'bar baz", all);

    const preserve = try transformPlaceholderFields(a, "1a 1b 1c 1d 1e 1f", null, "1", true);
    defer a.free(preserve);
    try std.testing.expectEqualStrings("1a ", preserve);

    const multiple = try transformPlaceholderFields(a, "1a 1b 1c 1d 1e 1f", null, "1,2,4", false);
    defer a.free(multiple);
    try std.testing.expectEqualStrings("1a 1b 1d", multiple);

    const overlapping = try transformPlaceholderFields(a, "1a 1b 1c 1d 1e 1f", null, "1..2,-4..-3", false);
    defer a.free(overlapping);
    try std.testing.expectEqualStrings("1a 1b 1c 1d", overlapping);

    const descending = try transformPlaceholderFields(a, "1a 1b 1c", null, "3..1", false);
    defer a.free(descending);
    try std.testing.expectEqualStrings("", descending);

    const string_delim = try transformPlaceholderFields(a, "  foo'bar baz", "'", "1", false);
    defer a.free(string_delim);
    try std.testing.expectEqualStrings("foo", string_delim);

    const string_delim_preserve = try transformPlaceholderFields(a, "  foo'bar baz", "'", "1", true);
    defer a.free(string_delim_preserve);
    try std.testing.expectEqualStrings("  foo", string_delim_preserve);
}

test "placeholder validation and ansi stripping match fzf" {
    const a = std.testing.allocator;
    const blob = try a.dupe(u8, "\x1b[31mred\x1b[0m blue\n");
    var options: Options = .{ .ansi = true };
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &options);
    defer candidates.deinit(a);
    const selected = [_]bool{false};
    const matched = [_]usize{0};

    const got = try expandCommand(a, "echo {} {r1} {0} {1...2}", "", &candidates, &options, 0, &.{}, &selected, &matched);
    defer a.free(got);
    try std.testing.expectEqualStrings("echo 'red blue' red {0} {1...2}", got);
}

test "query field placeholders preserve token spacing with s flag" {
    const a = std.testing.allocator;
    const plain = try transformPlaceholderFields(a, "alpha beta   gamma", null, "2", false);
    defer a.free(plain);
    try std.testing.expectEqualStrings("beta", plain);
    const preserved = try transformPlaceholderFields(a, "alpha beta   gamma", null, "2", true);
    defer a.free(preserved);
    try std.testing.expectEqualStrings("beta   ", preserved);
}

test "placeholder grammar accepts fzf 0.74 forms and rejects invalid ranges" {
    const valid = [_][]const u8{
        "",       "+",       "*",        "n",         "+n",         "*n",
        "f",      "fn",      "nf",       "+f",        "+fn",        "+nf",
        "*f",     "*fn",     "*nf",      "1",         "1..",        "..2",
        "-1",     "1,2",     "+1",       "+-1",       "s1",         "f1",
        "+s1..2", "r",       "r..",      "q",         "q:1",        "q:2..",
        "q:..",   "q:2..-1", "q:s2..-1", "fzf:query", "fzf:action", "fzf:prompt",
    };
    for (valid) |expr| try std.testing.expect(parsePlaceholderExpr(expr) != null);

    const invalid = [_][]const u8{
        "n.t",
        "0",
        "1..0",
        "-1..2",
        "q:",
        "q:s",
        "abc",
        "1,,2",
        "1...2",
    };
    for (invalid) |expr| try std.testing.expect(parsePlaceholderExpr(expr) == null);
}

test "field transforms" {
    const a = std.testing.allocator;
    const x = try transformFields(a, "one,two,three", ",", "2..", 7);
    defer a.free(x);
    try std.testing.expectEqualStrings("two,three", x);
    const y = try transformFields(a, "one,two,three", ",", "{n}:{3}:{1}", 7);
    defer a.free(y);
    try std.testing.expectEqualStrings("7:three:one", y);
    const z = try transformFields(a, "one two three", null, "-1", 0);
    defer a.free(z);
    try std.testing.expectEqualStrings("three", z);
}

test "extended query syntax" {
    var storage: [512]QueryTerm = undefined;
    var options: Options = .{};
    defer options.deinit(std.testing.allocator);
    const parsed = try parseQuery("^core go$ | rb$ | py$ !fire", &options, &storage);
    try std.testing.expectEqual(@as(usize, 3), parsed.clause_count);
    try std.testing.expect(queryMatches(parsed, "core-tool.py", .smart));
    try std.testing.expect(!queryMatches(parsed, "core-fire.py", .smart));
    try std.testing.expect(!queryMatches(parsed, "other-tool.py", .smart));
}

test "exact inverse boundary and smart case" {
    var storage: [512]QueryTerm = undefined;
    var options: Options = .{};
    defer options.deinit(std.testing.allocator);
    var parsed = try parseQuery("'foo' !bar", &options, &storage);
    try std.testing.expect(queryMatches(parsed, "xx foo yy", .smart));
    try std.testing.expect(!queryMatches(parsed, "xx foobar yy", .smart));
    try std.testing.expect(!queryMatches(parsed, "xx foo BAR yy", .ignore));

    parsed = try parseQuery("Foo", &options, &storage);
    try std.testing.expect(queryMatches(parsed, "xxFoo", .smart));
    try std.testing.expect(!queryMatches(parsed, "xxfoo", .smart));
    try std.testing.expect(queryMatches(parsed, "xxfoo", .ignore));
}

test "exact mode quote flips back to fuzzy" {
    var storage: [512]QueryTerm = undefined;
    var options: Options = .{ .exact = true };
    defer options.deinit(std.testing.allocator);
    const exact = try parseQuery("abc", &options, &storage);
    try std.testing.expect(queryMatches(exact, "xxabcxx", .smart));
    try std.testing.expect(!queryMatches(exact, "axbyc", .smart));
    const fuzzy_term = try parseQuery("'abc", &options, &storage);
    try std.testing.expect(queryMatches(fuzzy_term, "axbyc", .smart));
}

test "shell option splitting" {
    const a = std.testing.allocator;
    const args = try shellSplitArgs(a, "--reverse --prompt='pick > ' --bind=ctrl-r:reload\\(echo\\ x\\)");
    defer {
        for (args) |arg| a.free(arg);
        a.free(args);
    }
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("--prompt=pick > ", args[1]);
    try std.testing.expectEqualStrings("--bind=ctrl-r:reload(echo x)", args[2]);

    const commented = try shellSplitArgs(a, "# defaults\n--exact # trailing\n--prompt='pick # > ' foo#bar");
    defer freeShellArgs(a, commented);
    try std.testing.expectEqual(@as(usize, 3), commented.len);
    try std.testing.expectEqualStrings("--exact", commented[0]);
    try std.testing.expectEqualStrings("--prompt=pick # > ", commented[1]);
    try std.testing.expectEqualStrings("foo#bar", commented[2]);
}

test "default options file accepts shell-word options" {
    const a = std.testing.allocator;
    const path = "/tmp/zfuzz-default-options-file-test";
    Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "# managed fzf defaults\n--exact # keep exact matching\n--filter='file value'\n" }) catch {};
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const text = try readOptionsFile(a, std.testing.io, path);
    defer a.free(text);
    const args = try shellSplitArgs(a, text);
    defer freeShellArgs(a, args);
    var options: Options = .{};
    defer options.deinit(a);
    try parseOptionsInto(a, std.testing.io, &options, args, 0);
    try std.testing.expect(options.exact);
    try std.testing.expectEqualStrings("file value", options.filter.?);
}

test "multi modes match fzf zero and unlimited semantics" {
    const unlimited = parseMultiMode("").?;
    try std.testing.expect(unlimited.enabled);
    try std.testing.expect(unlimited.max == null);

    const limited = parseMultiMode("2").?;
    try std.testing.expect(limited.enabled);
    try std.testing.expectEqual(@as(?usize, 2), limited.max);

    const disabled = parseMultiMode("0").?;
    try std.testing.expect(!disabled.enabled);
    try std.testing.expect(disabled.max == null);
    try std.testing.expect(parseMultiMode("nope") == null);

    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--multi=0" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expect(!options.multi);
    try std.testing.expect(options.multi_max == null);

    const separate_args = [_][]const u8{ "zfuzz", "--multi", "2" };
    var separate = try parseOptions(a, &separate_args);
    defer separate.deinit(a);
    try std.testing.expect(separate.multi);
    try std.testing.expectEqual(@as(?usize, 2), separate.multi_max);

    const short_separate_args = [_][]const u8{ "zfuzz", "-m", "3" };
    var short_separate = try parseOptions(a, &short_separate_args);
    defer short_separate.deinit(a);
    try std.testing.expect(short_separate.multi);
    try std.testing.expectEqual(@as(?usize, 3), short_separate.multi_max);

    const compact_args = [_][]const u8{ "zfuzz", "-m4" };
    var compact = try parseOptions(a, &compact_args);
    defer compact.deinit(a);
    try std.testing.expect(compact.multi);
    try std.testing.expectEqual(@as(?usize, 4), compact.multi_max);

    const separate_zero_args = [_][]const u8{ "zfuzz", "--multi", "0" };
    var separate_zero = try parseOptions(a, &separate_zero_args);
    defer separate_zero.deinit(a);
    try std.testing.expect(!separate_zero.multi);
    try std.testing.expect(separate_zero.multi_max == null);

    const negative_equals_args = [_][]const u8{ "zfuzz", "--multi=-1" };
    var negative_equals = try parseOptions(a, &negative_equals_args);
    defer negative_equals.deinit(a);
    try std.testing.expect(!negative_equals.multi);
    try std.testing.expect(negative_equals.multi_max == null);

    const negative_compact_args = [_][]const u8{ "zfuzz", "-m-1" };
    var negative_compact = try parseOptions(a, &negative_compact_args);
    defer negative_compact.deinit(a);
    try std.testing.expect(!negative_compact.multi);
    try std.testing.expect(negative_compact.multi_max == null);
}

test "legacy toggle-sort option installs one fzf key binding" {
    const a = std.testing.allocator;

    const args = [_][]const u8{ "zfuzz", "--bind=a:up", "--toggle-sort", "a" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), options.bindings.items.len);
    try std.testing.expectEqualStrings("a", options.bindings.items[0].trigger);
    try std.testing.expect(options.bindings.items[0].action == .toggle_sort);

    const equals_args = [_][]const u8{ "zfuzz", "--toggle-sort=return" };
    var equals = try parseOptions(a, &equals_args);
    defer equals.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), equals.bindings.items.len);
    try std.testing.expectEqualStrings("return", equals.bindings.items[0].trigger);
    try std.testing.expect(equals.bindings.items[0].action == .toggle_sort);

    try std.testing.expectError(error.MultipleKeysSpecified, parseOptions(a, &.{ "zfuzz", "--toggle-sort=a,b" }));
    try std.testing.expectError(error.InvalidBinding, parseOptions(a, &.{ "zfuzz", "--toggle-sort=" }));
}

test "sort option forms match fzf numeric semantics" {
    const a = std.testing.allocator;

    const bare_args = [_][]const u8{ "zfuzz", "--no-sort", "--sort" };
    var bare = try parseOptions(a, &bare_args);
    defer bare.deinit(a);
    try std.testing.expect(!bare.no_sort);

    const short_args = [_][]const u8{ "zfuzz", "+s", "-s" };
    var short = try parseOptions(a, &short_args);
    defer short.deinit(a);
    try std.testing.expect(!short.no_sort);

    const zero_args = [_][]const u8{ "zfuzz", "--sort=0" };
    var zero = try parseOptions(a, &zero_args);
    defer zero.deinit(a);
    try std.testing.expect(zero.no_sort);

    const negative_args = [_][]const u8{ "zfuzz", "--sort=-2" };
    var negative = try parseOptions(a, &negative_args);
    defer negative.deinit(a);
    try std.testing.expect(negative.no_sort);

    const positive_args = [_][]const u8{ "zfuzz", "--sort=2" };
    var positive = try parseOptions(a, &positive_args);
    defer positive.deinit(a);
    try std.testing.expect(!positive.no_sort);

    const separate_zero_args = [_][]const u8{ "zfuzz", "--sort", "0" };
    var separate_zero = try parseOptions(a, &separate_zero_args);
    defer separate_zero.deinit(a);
    try std.testing.expect(separate_zero.no_sort);

    const separate_positive_args = [_][]const u8{ "zfuzz", "--sort", "3" };
    var separate_positive = try parseOptions(a, &separate_positive_args);
    defer separate_positive.deinit(a);
    try std.testing.expect(!separate_positive.no_sort);

    const compact_zero_args = [_][]const u8{ "zfuzz", "+s", "-s0" };
    var compact_zero = try parseOptions(a, &compact_zero_args);
    defer compact_zero.deinit(a);
    try std.testing.expect(!compact_zero.no_sort);

    const compact_negative_args = [_][]const u8{ "zfuzz", "+s", "-s-1" };
    var compact_negative = try parseOptions(a, &compact_negative_args);
    defer compact_negative.deinit(a);
    try std.testing.expect(!compact_negative.no_sort);

    const compact_text_args = [_][]const u8{ "zfuzz", "+s", "-sanything" };
    var compact_text = try parseOptions(a, &compact_text_args);
    defer compact_text.deinit(a);
    try std.testing.expect(!compact_text.no_sort);

    const separate_negative_args = [_][]const u8{ "zfuzz", "+s", "--sort", "-1" };
    var separate_negative = try parseOptions(a, &separate_negative_args);
    defer separate_negative.deinit(a);
    try std.testing.expect(!separate_negative.no_sort);
    try std.testing.expect(separate_negative.select_1);
}

test "compact query filter and nth options match fzf" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "-qNeedle", "-fMatch", "-n2.." };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqualStrings("Needle", options.query);
    try std.testing.expectEqualStrings("Match", options.filter.?);
    try std.testing.expectEqualStrings("2..", options.nth.?);

    const dash_values = [_][]const u8{ "zfuzz", "-q-x", "-f-y", "-n-1" };
    var dashed = try parseOptions(a, &dash_values);
    defer dashed.deinit(a);
    try std.testing.expectEqualStrings("-x", dashed.query);
    try std.testing.expectEqualStrings("-y", dashed.filter.?);
    try std.testing.expectEqualStrings("-1", dashed.nth.?);
}

test "bare double dash is ignored without ending fzf option parsing" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--", "--filter=needle", "--exact" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqualStrings("needle", options.filter.?);
    try std.testing.expect(options.exact);
}

test "no-input option starts the existing input visibility state hidden" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--no-input" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expect(options.no_input);
}

test "scroll-off option uses fzf source default and accepts overrides" {
    const a = std.testing.allocator;
    const defaults = [_][]const u8{"zfuzz"};
    var default_options = try parseOptions(a, &defaults);
    defer default_options.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), default_options.scroll_off);

    const equals_args = [_][]const u8{ "zfuzz", "--scroll-off=0" };
    var equals_options = try parseOptions(a, &equals_args);
    defer equals_options.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), equals_options.scroll_off);

    const separate_args = [_][]const u8{ "zfuzz", "--scroll-off", "7" };
    var separate_options = try parseOptions(a, &separate_args);
    defer separate_options.deinit(a);
    try std.testing.expectEqual(@as(usize, 7), separate_options.scroll_off);
}

test "border and preview layout accept separated values" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--border", "sharp", "--preview-border", "dashed", "--preview-window", "left,40%,hidden" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expect(options.border);
    try std.testing.expectEqual(BorderStyle.sharp, options.border_style);
    try std.testing.expectEqual(BorderStyle.dashed, options.preview.border_style);
    try std.testing.expectEqual(PreviewPosition.left, options.preview.position);
    try std.testing.expectEqual(@as(u8, 40), options.preview.percent);
    try std.testing.expect(options.preview.hidden);
}

test "optional borders do not consume plus options" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--no-border", "--border", "+s", "-1", "--no-preview-border", "--preview-border", "+1" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expect(options.border);
    try std.testing.expectEqual(BorderStyle.rounded, options.border_style);
    try std.testing.expectEqual(BorderStyle.rounded, options.preview.border_style);
    try std.testing.expect(options.no_sort);
    try std.testing.expect(!options.select_1);
}

test "prompt pointer and marker accept separate arguments" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--prompt", "pick> ", "--pointer", ">>", "--marker", "**" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqualStrings("pick> ", options.prompt);
    try std.testing.expectEqualStrings(">>", options.pointer);
    try std.testing.expectEqualStrings("**", options.marker);
}

test "pointer and marker use only the first fzf line" {
    const a = std.testing.allocator;

    const separate_args = [_][]const u8{ "zfuzz", "--pointer", "A\r\nignored", "--marker", "B\nignored" };
    var separate = try parseOptions(a, &separate_args);
    defer separate.deinit(a);
    try std.testing.expectEqualStrings("A\r", separate.pointer);
    try std.testing.expectEqualStrings("B", separate.marker);

    const inline_args = [_][]const u8{ "zfuzz", "--pointer=X\nignored", "--marker=Y\r\nignored" };
    var inline_options = try parseOptions(a, &inline_args);
    defer inline_options.deinit(a);
    try std.testing.expectEqualStrings("X", inline_options.pointer);
    try std.testing.expectEqualStrings("Y\r", inline_options.marker);
}

test "preview and label reset options are last-one-wins" {
    const a = std.testing.allocator;

    const preview_args = [_][]const u8{ "zfuzz", "--preview=first", "--no-preview", "--preview", "second" };
    var preview = try parseOptions(a, &preview_args);
    defer preview.deinit(a);
    try std.testing.expectEqualStrings("second", preview.preview.command.?);

    const preview_clear_args = [_][]const u8{ "zfuzz", "--preview=first", "--no-preview" };
    var preview_clear = try parseOptions(a, &preview_clear_args);
    defer preview_clear.deinit(a);
    try std.testing.expect(preview_clear.preview.command == null);

    const border_label_args = [_][]const u8{ "zfuzz", "--border-label=first", "--no-border-label", "--border-label", "second" };
    var border_label = try parseOptions(a, &border_label_args);
    defer border_label.deinit(a);
    try std.testing.expectEqualStrings("second", border_label.border_label.?);

    const preview_label_args = [_][]const u8{ "zfuzz", "--preview-label=first", "--no-preview-label" };
    var preview_label = try parseOptions(a, &preview_label_args);
    defer preview_label.deinit(a);
    try std.testing.expect(preview_label.preview.label == null);
}

test "header footer and color reset forms are last-one-wins" {
    const a = std.testing.allocator;

    const header_args = [_][]const u8{ "zfuzz", "--header", "first", "--no-header", "--header=second" };
    var header = try parseOptions(a, &header_args);
    defer header.deinit(a);
    try std.testing.expectEqualStrings("second", header.header.?);

    const header_lines_args = [_][]const u8{ "zfuzz", "--header-lines=2", "--no-header-lines" };
    var header_lines = try parseOptions(a, &header_lines_args);
    defer header_lines.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), header_lines.header_lines);

    const footer_args = [_][]const u8{ "zfuzz", "--footer=first", "--no-footer", "--footer", "second" };
    var footer = try parseOptions(a, &footer_args);
    defer footer.deinit(a);
    try std.testing.expectEqualStrings("second", footer.footer.?);

    const color_args = [_][]const u8{ "zfuzz", "--color=dark", "+c" };
    var color = try parseOptions(a, &color_args);
    defer color.deinit(a);
    try std.testing.expect(!color.theme.enabled);

    const base16_args = [_][]const u8{ "zfuzz", "--color=base16" };
    var base16 = try parseOptions(a, &base16_args);
    defer base16.deinit(a);
    const numeric16_args = [_][]const u8{ "zfuzz", "--color=light", "--color=16" };
    var numeric16 = try parseOptions(a, &numeric16_args);
    defer numeric16.deinit(a);
    try std.testing.expectEqualDeep(base16.theme, numeric16.theme);
}

test "search and io reset aliases are last-one-wins" {
    const a = std.testing.allocator;

    const exact_args = [_][]const u8{ "zfuzz", "--exact", "--no-exact", "-e", "+e" };
    var exact = try parseOptions(a, &exact_args);
    defer exact.deinit(a);
    try std.testing.expect(!exact.exact);

    const io_args = [_][]const u8{ "zfuzz", "--read0", "--no-read0", "--print0", "--no-print0", "--print-query", "--no-print-query" };
    var io = try parseOptions(a, &io_args);
    defer io.deinit(a);
    try std.testing.expect(!io.read0);
    try std.testing.expect(!io.print0);
    try std.testing.expect(!io.print_query);

    const auto_args = [_][]const u8{ "zfuzz", "-1", "+1", "-0", "+0" };
    var auto = try parseOptions(a, &auto_args);
    defer auto.deinit(a);
    try std.testing.expect(!auto.select_1);
    try std.testing.expect(!auto.exit_0);

    const sync_args = [_][]const u8{ "zfuzz", "--sync", "--async", "--sync", "--no-sync" };
    var sync = try parseOptions(a, &sync_args);
    defer sync.deinit(a);
    try std.testing.expect(!sync.sync);

    const state_args = [_][]const u8{ "zfuzz", "--history=x", "--no-history", "--id-nth=1", "--no-id-nth", "--tac", "--no-tac" };
    var state = try parseOptions(a, &state_args);
    defer state.deinit(a);
    try std.testing.expect(state.history_file == null);
    try std.testing.expect(state.id_nth == null);
    try std.testing.expect(!state.tac);
}

test "inverse option aliases reset existing state with last-one-wins semantics" {
    const a = std.testing.allocator;

    const multi_args = [_][]const u8{ "zfuzz", "--multi=3", "--no-multi" };
    var multi = try parseOptions(a, &multi_args);
    defer multi.deinit(a);
    try std.testing.expect(!multi.multi);
    try std.testing.expect(multi.multi_max == null);

    const plus_multi_args = [_][]const u8{ "zfuzz", "--multi=2", "+m", "--multi" };
    var plus_multi = try parseOptions(a, &plus_multi_args);
    defer plus_multi.deinit(a);
    try std.testing.expect(plus_multi.multi);
    try std.testing.expect(plus_multi.multi_max == null);

    const ansi_args = [_][]const u8{ "zfuzz", "--ansi", "--no-ansi" };
    var ansi = try parseOptions(a, &ansi_args);
    defer ansi.deinit(a);
    try std.testing.expect(!ansi.ansi);

    const cycle_args = [_][]const u8{ "zfuzz", "--cycle", "--no-cycle" };
    var cycle = try parseOptions(a, &cycle_args);
    defer cycle.deinit(a);
    try std.testing.expect(!cycle.cycle);

    const wrap_args = [_][]const u8{ "zfuzz", "--wrap", "--no-wrap" };
    var wrap = try parseOptions(a, &wrap_args);
    defer wrap.deinit(a);
    try std.testing.expect(!wrap.wrap);

    const reverse_args = [_][]const u8{ "zfuzz", "--reverse", "--no-reverse" };
    var reverse = try parseOptions(a, &reverse_args);
    defer reverse.deinit(a);
    try std.testing.expectEqual(Layout.default, reverse.layout);
}

test "search enable and phony aliases are last-one-wins" {
    const a = std.testing.allocator;

    const phony_args = [_][]const u8{ "zfuzz", "--phony" };
    var phony = try parseOptions(a, &phony_args);
    defer phony.deinit(a);
    try std.testing.expect(phony.disabled);

    const enabled_args = [_][]const u8{ "zfuzz", "--disabled", "--enabled" };
    var enabled = try parseOptions(a, &enabled_args);
    defer enabled.deinit(a);
    try std.testing.expect(!enabled.disabled);

    const disabled_last_args = [_][]const u8{ "zfuzz", "--enabled", "--phony" };
    var disabled_last = try parseOptions(a, &disabled_last_args);
    defer disabled_last.deinit(a);
    try std.testing.expect(disabled_last.disabled);

    const no_phony_args = [_][]const u8{ "zfuzz", "--phony", "--no-phony" };
    var no_phony = try parseOptions(a, &no_phony_args);
    defer no_phony.deinit(a);
    try std.testing.expect(!no_phony.disabled);
}

test "preview action placeholder classification" {
    const plain = previewTemplateFlags("printf ready");
    try std.testing.expect(!plain.slot);
    const current = previewTemplateFlags("echo {} {2} {n}");
    try std.testing.expect(current.slot and !current.plus and !current.asterisk and !current.force_update);
    const selected = previewTemplateFlags("echo {+} {+2}");
    try std.testing.expect(selected.slot and selected.plus and !selected.asterisk);
    const matched = previewTemplateFlags("echo {*} {*2}");
    try std.testing.expect(matched.slot and matched.asterisk);
    const query = previewTemplateFlags("echo {q} {fzf:action}");
    try std.testing.expect(query.slot and query.force_update);
    const escaped = previewTemplateFlags("echo \\{} \\{q}");
    try std.testing.expect(!escaped.slot);
}

test "stateful binding actions parse" {
    try std.testing.expect((try parseAction("toggle-sort")) == .toggle_sort);
    try std.testing.expect((try parseAction("ToGgLe-SoRt")) == .toggle_sort);
    const mixed_execute = try parseAction("Execute-Silent(printf MiXeD)");
    try std.testing.expectEqualStrings("printf MiXeD", mixed_execute.execute_silent);
    const mixed_execute_multi = try parseAction("Execute-Multi@printf multi@");
    try std.testing.expectEqualStrings("printf multi", mixed_execute_multi.execute_multi);
    const mixed_preview = try parseAction("PrEvIeW(printf preview)");
    try std.testing.expectEqualStrings("printf preview", mixed_preview.preview);
    try std.testing.expect((try parseAction("enable-search")) == .enable_search);
    const q = try parseAction("change-query(foo bar)");
    try std.testing.expectEqualStrings("foo bar", q.change_query);
    const h = try parseAction("change-header:ready");
    try std.testing.expectEqualStrings("ready", h.change_header);
    const tq = try parseAction("transform-query(printf beta)");
    try std.testing.expectEqualStrings("printf beta", tq.transform_query);
    const t = try parseAction("transform(printf 'down+accept')");
    try std.testing.expectEqualStrings("printf 'down+accept'", t.transform);
    try std.testing.expect((try parseAction("wait")) == .wait);
    try std.testing.expect((try parseAction("select")) == .select);
    try std.testing.expect((try parseAction("toggle-down")) == .toggle_down);
    try std.testing.expect((try parseAction("toggle-in")) == .toggle_in);
    try std.testing.expect((try parseAction("toggle-out")) == .toggle_out);
    try std.testing.expect((try parseAction("toggle-all")) == .toggle_all);
    try std.testing.expect((try parseAction("top")) == .first);
    const pos_forward = try parseAction("pos(3)");
    try std.testing.expectEqualStrings("3", pos_forward.position);
    const pos_backward = try parseAction("pos:-3");
    try std.testing.expectEqualStrings("-3", pos_backward.position);
    try std.testing.expect((try parseAction("half-page-up")) == .half_page_up);
    try std.testing.expect((try parseAction("half-page-down")) == .half_page_down);
    try std.testing.expect((try parseAction("offset-up")) == .offset_up);
    try std.testing.expect((try parseAction("offset-down")) == .offset_down);
    try std.testing.expect((try parseAction("offset-middle")) == .offset_middle);
    try std.testing.expect((try parseAction("clear-screen")) == .clear_screen);
    try std.testing.expect((try parseAction("close")) == .close);
    try std.testing.expect((try parseAction("bell")) == .bell);
    try std.testing.expect((try parseAction("beginning-of-line")) == .beginning_of_line);
    try std.testing.expect((try parseAction("end-of-line")) == .end_of_line);
    try std.testing.expect((try parseAction("backward-char")) == .backward_char);
    try std.testing.expect((try parseAction("forward-char")) == .forward_char);
    try std.testing.expect((try parseAction("backward-delete-char")) == .backward_delete_char);
    try std.testing.expect((try parseAction("backward-delete-char/eof")) == .backward_delete_char_eof);
    try std.testing.expect((try parseAction("delete-char")) == .delete_char);
    try std.testing.expect((try parseAction("delete-char/eof")) == .delete_char_eof);
    try std.testing.expect((try parseAction("ignore")) == .ignore);
    try std.testing.expect((try parseAction("kill-line")) == .kill_line);
    try std.testing.expect((try parseAction("unix-line-discard")) == .unix_line_discard);
    try std.testing.expect((try parseAction("line-discard")) == .unix_line_discard);
    try std.testing.expect((try parseAction("unix-word-rubout")) == .unix_word_rubout);
    try std.testing.expect((try parseAction("word-rubout")) == .unix_word_rubout);
    try std.testing.expect((try parseAction("backward-subword")) == .backward_subword);
    try std.testing.expect((try parseAction("forward-subword")) == .forward_subword);
    try std.testing.expect((try parseAction("backward-kill-subword")) == .backward_kill_subword);
    try std.testing.expect((try parseAction("kill-subword")) == .kill_subword);
    try std.testing.expect((try parseAction("yank")) == .yank);
    try std.testing.expect((try parseAction("cancel")) == .cancel);
    try std.testing.expect((try parseAction("clear-selection")) == .deselect_all);
    try std.testing.expect((try parseAction("clear-multi")) == .deselect_all);
    try std.testing.expect((try parseAction("print-query")) == .print_query);
    try std.testing.expect((try parseAction("accept-non-empty")) == .accept_non_empty);
    try std.testing.expect((try parseAction("accept-or-print-query")) == .accept_or_print_query);
    try std.testing.expect((try parseAction("replace-query")) == .replace_query);
    const put = try parseAction("put(λx)");
    try std.testing.expectEqualStrings("λx", put.put);
    const printed = try parseAction("print(ctrl-y)");
    try std.testing.expectEqualStrings("ctrl-y", printed.print);

    const multi_unlimited = try parseAction("change-multi");
    try std.testing.expectEqualStrings("", multi_unlimited.change_multi);
    const multi_limit = try parseAction("change-multi(2)");
    try std.testing.expectEqualStrings("2", multi_limit.change_multi);
    const multi_disable = try parseAction("change-multi:0");
    try std.testing.expectEqualStrings("0", multi_disable.change_multi);
}

test "search override actions parse" {
    const direct = try parseAction("search(foo bar)");
    try std.testing.expectEqualStrings("foo bar", direct.search);
    const transformed = try parseAction("transform-search:printf beta");
    try std.testing.expectEqualStrings("printf beta", transformed.transform_search);
    const background = try parseAction("bg-transform-search(printf gamma)");
    try std.testing.expectEqualStrings("printf gamma", background.bg_transform_search);
}

test "dynamic nth actions parse and validate fzf expressions" {
    const change_nth = try parseAction("change-nth(2|3..|-1)");
    try std.testing.expectEqualStrings("2|3..|-1", change_nth.change_nth);
    const change_with = try parseAction("change-with-nth({2}:{1}|)");
    try std.testing.expectEqualStrings("{2}:{1}|", change_with.change_with_nth);
    const transform_nth = try parseAction("transform-nth:printf 2");
    try std.testing.expectEqualStrings("printf 2", transform_nth.transform_nth);
    const transform_with = try parseAction("transform-with-nth(printf '{2}:{1}')");
    try std.testing.expectEqualStrings("printf '{2}:{1}'", transform_with.transform_with_nth);
    const bg_nth = try parseAction("bg-transform-nth(printf 3)");
    try std.testing.expectEqualStrings("printf 3", bg_nth.bg_transform_nth);
    const bg_with = try parseAction("bg-transform-with-nth(printf 1)");
    try std.testing.expectEqualStrings("printf 1", bg_with.bg_transform_with_nth);

    try std.testing.expect(Ui.nthSpecValid("1,2..4,-1"));
    try std.testing.expect(Ui.nthSpecValid("..2"));
    try std.testing.expect(!Ui.nthSpecValid("0"));
    try std.testing.expect(!Ui.nthSpecValid("-2..3"));
    try std.testing.expect(Ui.withNthSpecValid("{2}:{1}"));
    try std.testing.expect(Ui.withNthSpecValid("2.."));
    try std.testing.expect(!Ui.withNthSpecValid("{0}"));
    try std.testing.expect(!Ui.withNthSpecValid("{2"));

    const canonical = try canonicalNthSpec(std.testing.allocator, "1..,-1,-3..-1,..2");
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("..,-1,-3..,..2", canonical);
}

test "dynamic visual actions parse" {
    const change_ghost = try parseAction("change-ghost(type here)");
    try std.testing.expectEqualStrings("type here", change_ghost.change_ghost);
    const transform_ghost = try parseAction("transform-ghost:printf ghost");
    try std.testing.expectEqualStrings("printf ghost", transform_ghost.transform_ghost);
    const bg_ghost = try parseAction("bg-transform-ghost(printf ghost)");
    try std.testing.expectEqualStrings("printf ghost", bg_ghost.bg_transform_ghost);

    const change_pointer = try parseAction("change-pointer(>>)");
    try std.testing.expectEqualStrings(">>", change_pointer.change_pointer);
    const transform_pointer = try parseAction("transform-pointer:printf '>>'");
    try std.testing.expectEqualStrings("printf '>>'", transform_pointer.transform_pointer);
    const bg_pointer = try parseAction("bg-transform-pointer(printf '>')");
    try std.testing.expectEqualStrings("printf '>'", bg_pointer.bg_transform_pointer);

    const change_border = try parseAction("change-border-label(repo)");
    try std.testing.expectEqualStrings("repo", change_border.change_border_label);
    const transform_border = try parseAction("transform-border-label:printf repo");
    try std.testing.expectEqualStrings("printf repo", transform_border.transform_border_label);
    const bg_border = try parseAction("bg-transform-border-label(printf repo)");
    try std.testing.expectEqualStrings("printf repo", bg_border.bg_transform_border_label);

    const change_preview = try parseAction("change-preview-label(details)");
    try std.testing.expectEqualStrings("details", change_preview.change_preview_label);
    const transform_preview = try parseAction("transform-preview-label:printf details");
    try std.testing.expectEqualStrings("printf details", transform_preview.transform_preview_label);
    const bg_preview = try parseAction("bg-transform-preview-label(printf details)");
    try std.testing.expectEqualStrings("printf details", bg_preview.bg_transform_preview_label);
}

test "background cancellation invalidates transforms but preserves reload" {
    const a = std.testing.allocator;
    const queue = try BackgroundQueue.create(a, std.testing.io);
    defer queue.close();

    const stale_generation = queue.begin().?;
    queue.cancel();
    queue.finish(.query, try a.dupe(u8, "stale"), 0, null, stale_generation);

    const queued_generation = queue.begin().?;
    queue.finish(.prompt, try a.dupe(u8, "queued-stale"), 0, null, queued_generation);
    const reload_generation = queue.begin().?;
    queue.finish(.reload, try a.dupe(u8, "reload"), 1, null, reload_generation);
    queue.cancel();

    const fresh_generation = queue.begin().?;
    queue.finish(.query, try a.dupe(u8, "fresh"), 0, null, fresh_generation);

    var results = queue.takeAll();
    defer {
        for (results.items) |result| a.free(result.output);
        results.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expect(results.items[0].kind == .reload);
    try std.testing.expectEqualStrings("reload", results.items[0].output);
    try std.testing.expect(results.items[1].kind == .query);
    try std.testing.expectEqualStrings("fresh", results.items[1].output);
}

test "transform first-line capture matches fzf" {
    try std.testing.expectEqualStrings("alpha", firstCommandOutputLine("alpha\nbeta"));
    try std.testing.expectEqualStrings("alpha", firstCommandOutputLine("alpha\r\nbeta"));
    try std.testing.expectEqualStrings("alpha  ", firstCommandOutputLine("alpha  \nbeta"));
    try std.testing.expectEqualStrings("alpha", firstCommandOutputLine("alpha"));
}

test "search override bypasses disabled without changing visible query" {
    const normal = resolveEffectiveSearch("alpha", false, null);
    try std.testing.expectEqualStrings("alpha", normal.query);
    try std.testing.expect(!normal.disabled);

    const disabled = resolveEffectiveSearch("alpha", true, null);
    try std.testing.expectEqualStrings("", disabled.query);
    try std.testing.expect(disabled.disabled);

    const overridden = resolveEffectiveSearch("alpha", true, "beta");
    try std.testing.expectEqualStrings("beta", overridden.query);
    try std.testing.expect(!overridden.disabled);

    const empty_override = resolveEffectiveSearch("alpha", true, "");
    try std.testing.expectEqualStrings("", empty_override.query);
    try std.testing.expect(!empty_override.disabled);
}

test "last action name is case normalized" {
    var ui: Ui = undefined;
    ui.last_action_buf = [_]u8{0} ** 64;
    ui.setLastAction("Change-Query");
    try std.testing.expectEqualStrings("change-query", ui.last_action);
}

test "binding parser" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);
    try parseBindings(a, &bindings, "ctrl-r:reload(printf 'a,b')+change-header(ready),enter:accept");
    try std.testing.expectEqual(@as(usize, 3), bindings.items.len);
    try std.testing.expectEqualStrings("ctrl-r", bindings.items[0].trigger);
    try std.testing.expectEqualStrings("reload", bindings.items[0].name);
    try std.testing.expectEqualStrings("printf 'a,b'", bindings.items[0].action.reload);
    try std.testing.expectEqualStrings("ready", bindings.items[1].action.change_header);
    try std.testing.expect(bindings.items[2].action == .accept);
}

test "repeated fzf bindings replace unless action list starts with plus" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);

    try parseBindings(a, &bindings, "a:up,a:down");
    try std.testing.expectEqual(@as(usize, 1), bindings.items.len);
    try std.testing.expect(bindings.items[0].action == .down);

    try parseBindings(a, &bindings, "a:+accept");
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);
    try std.testing.expect(bindings.items[0].action == .down);
    try std.testing.expect(bindings.items[1].action == .accept);

    try parseBindings(a, &bindings, "a:");
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);

    var aliases: std.ArrayList(Binding) = .empty;
    defer aliases.deinit(a);
    try parseBindings(a, &aliases, "return:up,enter:down");
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("enter", aliases.items[0].trigger);
    try std.testing.expect(aliases.items[0].action == .down);
    try parseBindings(a, &aliases, "ctrl-m:accept");
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("ctrl-m", aliases.items[0].trigger);
    try std.testing.expect(aliases.items[0].action == .accept);

    aliases.clearRetainingCapacity();
    try parseBindings(a, &aliases, "tab:up,Ctrl-I:down");
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("Ctrl-I", aliases.items[0].trigger);
    try std.testing.expect(aliases.items[0].action == .down);
}

test "binding parser groups pending fzf keys" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);

    try parseBindings(a, &bindings, "a,b:accept");
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);
    try std.testing.expectEqualStrings("a", bindings.items[0].trigger);
    try std.testing.expectEqualStrings("b", bindings.items[1].trigger);
    try std.testing.expect(bindings.items[0].action == .accept);
    try std.testing.expect(bindings.items[1].action == .accept);

    try parseBindings(a, &bindings, "a:up,b:down,a,b:accept");
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);
    try std.testing.expect(bindings.items[0].action == .accept);
    try std.testing.expect(bindings.items[1].action == .accept);

    var pending_only: std.ArrayList(Binding) = .empty;
    defer pending_only.deinit(a);
    try std.testing.expectError(error.InvalidBinding, parseBindings(a, &pending_only, "a,b"));
    try std.testing.expectError(error.InvalidBinding, parseBindings(a, &pending_only, "a,,b:accept"));
}

test "binding parser accepts fzf action argument delimiters" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);

    try parseBindings(
        a,
        &bindings,
        "a:execute/echo a+b,c/+down,b:execute[echo 'x+y,z']+up,c:change-query@foo+bar,baz@+accept",
    );
    try std.testing.expectEqual(@as(usize, 6), bindings.items.len);
    try std.testing.expectEqualStrings("a", bindings.items[0].trigger);
    try std.testing.expectEqualStrings("echo a+b,c", bindings.items[0].action.execute);
    try std.testing.expect(bindings.items[1].action == .down);
    try std.testing.expectEqualStrings("b", bindings.items[2].trigger);
    try std.testing.expectEqualStrings("echo 'x+y,z'", bindings.items[2].action.execute);
    try std.testing.expect(bindings.items[3].action == .up);
    try std.testing.expectEqualStrings("foo+bar,baz", bindings.items[4].action.change_query);
    try std.testing.expect(bindings.items[5].action == .accept);

    const empty_query = try parseAction("change-query:");
    try std.testing.expectEqualStrings("", empty_query.change_query);

    const cases = [_]struct { text: []const u8, payload: []const u8 }{
        .{ .text = "execute(echo p)", .payload = "echo p" },
        .{ .text = "execute[echo b]", .payload = "echo b" },
        .{ .text = "execute{echo c}", .payload = "echo c" },
        .{ .text = "execute<echo a>", .payload = "echo a" },
        .{ .text = "execute/echo slash/", .payload = "echo slash" },
        .{ .text = "execute@echo at@", .payload = "echo at" },
        .{ .text = "execute;echo semi;", .payload = "echo semi" },
        .{ .text = "execute|echo pipe|", .payload = "echo pipe" },
        .{ .text = "execute!echo bang!", .payload = "echo bang" },
    };
    for (cases) |case| {
        const action = try parseAction(case.text);
        try std.testing.expectEqualStrings(case.payload, action.execute);
    }

    try std.testing.expectEqualStrings("delete-char/eof", actionName("delete-char/eof"));
    try std.testing.expectEqualStrings("Execute", actionName("Execute/foo/"));
}

test "colon action argument consumes remaining binding text" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);
    try parseBindings(a, &bindings, "x:execute:printf a+b,y:accept");
    try std.testing.expectEqual(@as(usize, 1), bindings.items.len);
    try std.testing.expectEqualStrings("printf a+b,y:accept", bindings.items[0].action.execute);
}

test "binding parser accepts comma colon and plus keys" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);

    try parseBindings(a, &bindings, "a:up,,:abort,::accept,+:clear-query");
    try std.testing.expectEqual(@as(usize, 4), bindings.items.len);
    try std.testing.expectEqualStrings("a", bindings.items[0].trigger);
    try std.testing.expectEqualStrings(",", bindings.items[1].trigger);
    try std.testing.expect(bindings.items[1].action == .abort);
    try std.testing.expectEqualStrings(":", bindings.items[2].trigger);
    try std.testing.expect(bindings.items[2].action == .accept);
    try std.testing.expectEqualStrings("+", bindings.items[3].trigger);
    try std.testing.expect(bindings.items[3].action == .clear_query);

    var leading_comma: std.ArrayList(Binding) = .empty;
    defer leading_comma.deinit(a);
    try parseBindings(a, &leading_comma, ",:last");
    try std.testing.expectEqual(@as(usize, 1), leading_comma.items.len);
    try std.testing.expectEqualStrings(",", leading_comma.items[0].trigger);
    try std.testing.expect(leading_comma.items[0].action == .last);
}

test "reload actions distinguish async and sync variants" {
    const asynchronous = try parseAction("reload(echo async)");
    try std.testing.expect(std.mem.eql(u8, asynchronous.reload, "echo async"));
    const synchronous = try parseAction("reload-sync(echo sync)");
    try std.testing.expect(std.mem.eql(u8, synchronous.reload_sync, "echo sync"));
}

test "raw and exclusion actions parse" {
    try std.testing.expect((try parseAction("toggle-raw")) == .toggle_raw);
    try std.testing.expect((try parseAction("enable-raw")) == .enable_raw);
    try std.testing.expect((try parseAction("disable-raw")) == .disable_raw);
    try std.testing.expect((try parseAction("down-match")) == .down_match);
    try std.testing.expect((try parseAction("up-match")) == .up_match);
    try std.testing.expect((try parseAction("best")) == .best);
    try std.testing.expect((try parseAction("exclude")) == .exclude);
    try std.testing.expect((try parseAction("exclude-multi")) == .exclude_multi);
}

test "background transform actions parse command payloads" {
    const generic = try parseAction("bg-transform(echo accept)");
    try std.testing.expect(std.mem.eql(u8, generic.bg_transform, "echo accept"));
    try std.testing.expect((try parseAction("bg-cancel")) == .bg_cancel);
    const prompt = try parseAction("bg-transform-prompt:echo ready");
    try std.testing.expect(std.mem.eql(u8, prompt.bg_transform_prompt, "echo ready"));
}

test "binding control actions parse target chord lists" {
    const unbind = try parseAction("unbind(ctrl-a,ctrl-b)");
    try std.testing.expect(std.mem.eql(u8, unbind.unbind, "ctrl-a,ctrl-b"));
    const rebind = try parseAction("rebind(ctrl-a)");
    try std.testing.expect(std.mem.eql(u8, rebind.rebind, "ctrl-a"));
    const toggle = try parseAction("toggle-bind(ctrl-a)");
    try std.testing.expect(std.mem.eql(u8, toggle.toggle_bind, "ctrl-a"));
}

test "CSI decoder consumes modified keys and bracketed paste markers" {
    try std.testing.expect(decodeCsi("1;3", 'D') == .word_left);
    try std.testing.expect(decodeCsi("1;5", 'C') == .word_right);
    try std.testing.expect(decodeCsi("200", '~') == .paste_start);
    try std.testing.expect(decodeCsi("201", '~') == .paste_end);
    try std.testing.expect(decodeCsi("?2004;1$", 'y') == .unknown);
}

test "word boundaries match fzf letter number and unix semantics" {
    try std.testing.expectEqual(@as(usize, 4), wordBoundaryBackward("foo-bar", "foo-bar".len));
    try std.testing.expectEqual(@as(usize, 3), wordBoundaryForward("foo-bar", 0));
    try std.testing.expectEqual(@as(usize, 4), wordBoundaryBackward("foo bar baz", 7));
    try std.testing.expectEqual(@as(usize, 7), wordBoundaryForward("foo bar baz", 4));
    try std.testing.expectEqual(@as(usize, "αβ-".len), wordBoundaryBackward("αβ-γδ", "αβ-γδ".len));
    try std.testing.expectEqual(@as(usize, "αβ".len), wordBoundaryForward("αβ-γδ", 0));
    try std.testing.expectEqual(@as(usize, 1), wordBoundaryBackward("_foo", "_foo".len));

    try std.testing.expectEqual(@as(usize, 0), unixWordBoundaryBackward("foo-bar", "foo-bar".len));
    try std.testing.expectEqual(@as(usize, 8), unixWordBoundaryBackward("foo-bar baz", "foo-bar baz".len));

    try std.testing.expectEqual(@as(usize, 5), filepathWordBoundaryBackward("foo//bar", "foo//bar".len));
    try std.testing.expectEqual(@as(usize, 0), filepathWordBoundaryBackward("foo//", "foo//".len));
    try std.testing.expectEqual(@as(usize, 3), filepathWordBoundaryForward("foo//bar", 0));
    try std.testing.expectEqual(@as(usize, "foo//bar".len), filepathWordBoundaryForward("foo//bar", 3));
}

test "every event interval parsing" {
    try std.testing.expectEqual(@as(?u64, 200), everyIntervalMilliseconds("every(0.2)"));
    try std.testing.expectEqual(@as(?u64, 200), everyIntervalMilliseconds("EvErY(0.2)"));
    try std.testing.expectEqual(@as(?u64, 2000), everyIntervalMilliseconds("every(2)"));
    try std.testing.expect(everyIntervalMilliseconds("every(0)") == null);
    try std.testing.expect(everyIntervalMilliseconds("every(-1)") == null);
    try std.testing.expect(everyIntervalMilliseconds("every(abc)") == null);
    try std.testing.expect(everyIntervalMilliseconds("every(2147484)") == null);
}

test "key names follow fzf case semantics" {
    try std.testing.expect(keyMatchesName(.up, "UP"));
    try std.testing.expect(keyMatchesName(.page_up, "PgUp"));
    try std.testing.expect(keyMatchesName(.{ .byte = 18 }, "CTRL-R"));
    try std.testing.expect(keyMatchesName(.{ .byte = 'A' }, "A"));
    try std.testing.expect(!keyMatchesName(.{ .byte = 'A' }, "a"));
    try std.testing.expect(keyMatchesName(.{ .byte = 'a' }, "a"));
    try std.testing.expect(!keyMatchesName(.{ .byte = 'a' }, "A"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 'A' }, "AlT-A"));
    try std.testing.expect(!keyMatchesName(.{ .alt_byte = 'A' }, "alt-a"));
    try std.testing.expect(triggerNamesEquivalent("CTRL-R", "ctrl-r"));
    try std.testing.expect(triggerNamesEquivalent("LoAd", "load"));
    try std.testing.expect(!triggerNamesEquivalent("A", "a"));
    try std.testing.expect(triggerNamesEquivalent("AlT-A", "alt-A"));
    try std.testing.expect(!triggerNamesEquivalent("alt-A", "alt-a"));
    try std.testing.expect(keyMatchesName(.{ .byte = 13 }, "RETURN"));
    try std.testing.expect(!keyMatchesName(.{ .byte = 10 }, "enter"));
    try std.testing.expect(keyMatchesName(.{ .byte = 10 }, "ctrl-j"));
    try std.testing.expect(keyMatchesName(.{ .byte = ' ' }, "space"));
    try std.testing.expect(keyMatchesName(.delete, "DEL"));
    try std.testing.expect(keyMatchesName(.{ .byte = 127 }, "bs"));
    try std.testing.expect(!keyMatchesName(.{ .byte = 8 }, "backspace"));
    try std.testing.expect(keyMatchesName(.{ .byte = 8 }, "ctrl-backspace"));
    if (builtin.os.tag != .windows) try std.testing.expect(triggerNamesEquivalent("ctrl-h", "ctrl-backspace"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = ' ' }, "Alt-Space"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 13 }, "alt-return"));
    try std.testing.expect(!keyMatchesName(.{ .alt_byte = 10 }, "alt-enter"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 127 }, "alt-backspace"));
    try std.testing.expect(!keyMatchesName(.{ .alt_byte = 8 }, "alt-backspace"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 8 }, "ctrl-alt-backspace"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 10 }, "ctrl-alt-j"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 10 }, "CTRL-ALT-J"));
    try std.testing.expect(triggerNamesEquivalent("ctrl-alt-m", "alt-enter"));
    try std.testing.expect(keyMatchesName(.{ .alt_byte = 13 }, "ctrl-alt-m"));
    if (builtin.os.tag != .windows) try std.testing.expect(triggerNamesEquivalent("ctrl-alt-h", "ctrl-alt-backspace"));
    try std.testing.expect(keyMatchesName(.{ .byte = 30 }, "ctrl-6"));
    try std.testing.expect(keyMatchesName(.{ .byte = 31 }, "ctrl-_"));
    try std.testing.expect(triggerNamesEquivalent("enter", "return"));
    try std.testing.expect(triggerNamesEquivalent("enter", "ctrl-m"));
    try std.testing.expect(triggerNamesEquivalent("tab", "Ctrl-I"));
    try std.testing.expect(keyMatchesName(.{ .byte = 13 }, "ctrl-m"));
    try std.testing.expect(keyMatchesName(.{ .byte = 9 }, "Ctrl-I"));
    try std.testing.expect(triggerNamesEquivalent("backspace", "bspace"));
    try std.testing.expect(triggerNamesEquivalent("delete", "del"));
    try std.testing.expect(triggerNamesEquivalent("space", " "));
    try std.testing.expect(triggerNamesEquivalent("alt-enter", "alt-return"));
}

test "fzf parser equal inverse fuzzy and boundary exact" {
    var storage: [512]QueryTerm = undefined;
    var options: Options = .{};
    defer options.deinit(std.testing.allocator);

    var parsed = try parseQuery("^foo$", &options, &storage);
    try std.testing.expectEqual(TermKind.equal, parsed.terms[0].kind);
    try std.testing.expect(queryMatches(parsed, "  foo  ", .smart));
    try std.testing.expect(!queryMatches(parsed, "foo bar", .smart));

    parsed = try parseQuery("!'fb", &options, &storage);
    try std.testing.expect(parsed.terms[0].inverse);
    try std.testing.expectEqual(TermKind.fuzzy, parsed.terms[0].kind);
    try std.testing.expect(!queryMatches(parsed, "fuzzy-blurry", .smart));
    try std.testing.expect(queryMatches(parsed, "bar", .smart));

    options.exact = true;
    parsed = try parseQuery("'foo'", &options, &storage);
    try std.testing.expectEqual(TermKind.boundary_exact, parsed.terms[0].kind);
    try std.testing.expect(queryMatches(parsed, "x foo y", .smart));
    try std.testing.expect(!queryMatches(parsed, "x foobar y", .smart));
}

test "Unicode normalization and literal mode match fzf filter semantics" {
    const a = std.testing.allocator;
    const input = "Só Danço Samba\nDanço\nDANCO\nplain\n";

    var options: Options = .{};
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, try a.dupe(u8, input), &options);
    defer candidates.deinit(a);
    try std.testing.expect(candidates.has_non_ascii);
    var index = try fuzzy.init(a, candidates.search);
    defer index.deinit();
    const out = try a.alloc(usize, candidates.search.len);
    defer a.free(out);
    const ranks = try a.alloc(ExtendedRank, candidates.search.len);
    defer a.free(ranks);

    const normalized = try searchCandidates(&index, &candidates, &options, "danco", out, ranks, out.len);
    try std.testing.expectEqual(@as(usize, 3), normalized.len);
    try std.testing.expectEqualStrings("Danço", candidates.output[normalized[0]]);
    try std.testing.expectEqualStrings("DANCO", candidates.output[normalized[1]]);
    try std.testing.expectEqualStrings("Só Danço Samba", candidates.output[normalized[2]]);

    options.literal = true;
    const literal = try searchCandidates(&index, &candidates, &options, "danco", out, ranks, out.len);
    try std.testing.expectEqual(@as(usize, 1), literal.len);
    try std.testing.expectEqualStrings("DANCO", candidates.output[literal[0]]);
}

test "Unicode query normalization policy and fullwidth folding match fzf" {
    const a = std.testing.allocator;
    const input = "é\ne\nｆｕｌｌ\nfull\n";

    var options: Options = .{};
    defer options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, try a.dupe(u8, input), &options);
    defer candidates.deinit(a);
    var index = try fuzzy.init(a, candidates.search);
    defer index.deinit();
    const out_buf = try a.alloc(usize, candidates.search.len);
    defer a.free(out_buf);
    const ranks = try a.alloc(ExtendedRank, candidates.search.len);
    defer a.free(ranks);

    // fzf disables normalization when the query itself would normalize.
    const accented = try searchCandidates(&index, &candidates, &options, "é", out_buf, ranks, out_buf.len);
    try std.testing.expectEqual(@as(usize, 1), accented.len);
    try std.testing.expectEqualStrings("é", candidates.output[accented[0]]);

    const folded = try searchCandidates(&index, &candidates, &options, "full", out_buf, ranks, out_buf.len);
    try std.testing.expectEqual(@as(usize, 2), folded.len);
    options.literal = true;
    const literal = try searchCandidates(&index, &candidates, &options, "full", out_buf, ranks, out_buf.len);
    try std.testing.expectEqual(@as(usize, 1), literal.len);
    try std.testing.expectEqualStrings("full", candidates.output[literal[0]]);
}

test "Unicode smart case recognizes non-ASCII uppercase" {
    try std.testing.expect(termCaseSensitive(.smart, "ẞ"));
    try std.testing.expect(!termCaseSensitive(.smart, "ß"));
    try std.testing.expect(termCaseSensitive(.smart, "Δ"));
    try std.testing.expect(!termCaseSensitive(.smart, "δ"));
}

test "scheme rankings match upstream fzf boundary fixture" {
    const a = std.testing.allocator;
    const input = "xxyzx\n-xxyz\nxyzx-\n_xyz_\n_xyz-\n-xyz_\n[xyz]\n-xyz-\n xyz \n/xyz/\n";
    const expected = [_][]const []const u8{
        &.{ " xyz ", "/xyz/", "[xyz]", "-xyz-", "-xyz_", "_xyz-", "_xyz_" },
        &.{ "/xyz/", " xyz ", "[xyz]", "-xyz-", "-xyz_", "_xyz-", "_xyz_" },
        &.{ "[xyz]", "-xyz-", " xyz ", "/xyz/", "-xyz_", "_xyz-", "_xyz_" },
    };
    const schemes = [_]Scheme{ .default, .path, .history };

    for (schemes, expected) |scheme, want| {
        var options: Options = .{};
        defer options.deinit(a);
        try applyScheme(&options, @tagName(scheme));
        const blob = try a.dupe(u8, input);
        var candidates = try candidatesFromOwnedBlob(a, blob, &options);
        defer candidates.deinit(a);
        var index = try fuzzy.init(a, candidates.search);
        defer index.deinit();
        const out = try a.alloc(usize, candidates.search.len);
        defer a.free(out);
        const ranks = try a.alloc(ExtendedRank, candidates.search.len);
        defer a.free(ranks);
        const found = try searchCandidates(&index, &candidates, &options, "'xyz'", out, ranks, out.len);
        try std.testing.expectEqual(want.len, found.len);
        for (want, found) |line, idx| try std.testing.expectEqualStrings(line, candidates.output[idx]);
    }
}

test "scheme parser accepts fzf schemes" {
    try std.testing.expectEqual(Scheme.default, try parseScheme("default"));
    try std.testing.expectEqual(Scheme.path, try parseScheme("PATH"));
    try std.testing.expectEqual(Scheme.history, try parseScheme("history"));
    try std.testing.expectError(error.InvalidScheme, parseScheme("bogus"));

    var options: Options = .{};
    defer options.deinit(std.testing.allocator);
    try applyScheme(&options, "path");
    try std.testing.expectEqual(@as(u2, 2), options.tiebreak_count);
    try std.testing.expectEqual(TieBreak.pathname, options.tiebreaks[0]);
    try std.testing.expectEqual(TieBreak.length, options.tiebreaks[1]);
    try applyScheme(&options, "history");
    try std.testing.expectEqual(@as(u2, 0), options.tiebreak_count);
}

test "tiebreak parser matches fzf constraints" {
    var options: Options = .{};
    defer options.deinit(std.testing.allocator);
    try parseTiebreaks(&options, "chunk,begin,index");
    try std.testing.expectEqual(@as(u2, 2), options.tiebreak_count);
    try std.testing.expectEqual(TieBreak.chunk, options.tiebreaks[0]);
    try std.testing.expectEqual(TieBreak.begin, options.tiebreaks[1]);
    try std.testing.expectError(error.IndexMustBeLastCriterion, parseTiebreaks(&options, "index,length"));
    try std.testing.expectError(error.DuplicateSortCriterion, parseTiebreaks(&options, "length,length"));
    try std.testing.expectError(error.TooManySortCriteria, parseTiebreaks(&options, "length,chunk,begin,end"));
}

test "fzf tiebreak values use match bounds" {
    const score = CandidateScore{ .score = 42, .min_begin = 3, .min_end = 5, .max_end = 7, .valid_offset = true };
    try std.testing.expectEqual(@as(usize, 7), tiebreakValue(.length, "  abcdefg  ", score));
    try std.testing.expectEqual(@as(usize, 7), tiebreakValue(.chunk, "  abcdefg  ", score));
    try std.testing.expectEqual(@as(usize, 1), tiebreakValue(.pathname, "xx/abcdefg", score));
}

test "style color and border option forms" {
    const a = std.testing.allocator;
    const args = [_][]const u8{
        "zfuzz",
        "--style=full:double",
        "--color=fg:252,bg+:236,hl:#719872:bold,prompt:red:underline",
        "--no-bold",
    };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(StylePreset.full, options.style_preset);
    try std.testing.expect(options.border);
    try std.testing.expectEqual(BorderStyle.double, options.border_style);
    try std.testing.expect(!options.bold);
    try std.testing.expect(options.theme.enabled);
    switch (options.theme.normal.fg.?) {
        .ansi => |n| try std.testing.expectEqual(@as(u8, 252), n),
        else => return error.TestUnexpectedResult,
    }
    switch (options.theme.current.bg.?) {
        .ansi => |n| try std.testing.expectEqual(@as(u8, 236), n),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!options.theme.current.reverse);
    switch (options.theme.highlight.fg.?) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0x71), rgb.r);
            try std.testing.expectEqual(@as(u8, 0x98), rgb.g);
            try std.testing.expectEqual(@as(u8, 0x72), rgb.b);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(options.theme.highlight.bold);
    try std.testing.expect(options.theme.prompt.underline);
}

test "minimal style and no color disable decoration" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--style=minimal", "--no-color" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(StylePreset.minimal, options.style_preset);
    try std.testing.expect(!options.border);
    try std.testing.expectEqual(BorderStyle.none, options.border_style);
    try std.testing.expect(!options.theme.enabled);
}

test "info margin and padding option forms" {
    const a = std.testing.allocator;
    const args = [_][]const u8{
        "zfuzz",
        "--info=inline-right: / ",
        "--separator=.",
        "--ghost=type to search",
        "--margin=1,2%,3,4%",
        "--padding=5,6",
    };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(InfoStyle.inline_right, options.info_style);
    try std.testing.expectEqualStrings(" / ", options.info_prefix);
    try std.testing.expectEqualStrings(".", options.separator.?);
    try std.testing.expectEqualStrings("type to search", options.ghost.?);
    try std.testing.expectEqual(@as(u16, 1), options.margin.top.value);
    try std.testing.expectEqual(@as(u16, 2), options.margin.right.value);
    try std.testing.expect(options.margin.right.percent);
    try std.testing.expectEqual(@as(u16, 3), options.margin.bottom.value);
    try std.testing.expectEqual(@as(u16, 4), options.margin.left.value);
    try std.testing.expect(options.margin.left.percent);
    try std.testing.expectEqual(@as(u16, 5), options.padding.top.value);
    try std.testing.expectEqual(@as(u16, 6), options.padding.right.value);
    try std.testing.expectEqual(@as(u16, 5), options.padding.bottom.value);
    try std.testing.expectEqual(@as(u16, 6), options.padding.left.value);
}

test "inset pane resolves absolute and percentage margins" {
    const pane = Pane{ .row = 1, .col = 1, .rows = 20, .cols = 100 };
    const insets = Insets{
        .top = .{ .value = 10, .percent = true },
        .right = .{ .value = 5 },
        .bottom = .{ .value = 20, .percent = true },
        .left = .{ .value = 10 },
    };
    const out = insetPane(pane, insets);
    try std.testing.expectEqual(@as(usize, 3), out.row);
    try std.testing.expectEqual(@as(usize, 11), out.col);
    try std.testing.expectEqual(@as(usize, 14), out.rows);
    try std.testing.expectEqual(@as(usize, 85), out.cols);
}

test "finder and preview border labels parse" {
    const a = std.testing.allocator;
    const args = [_][]const u8{
        "zfuzz",
        "--border=double",
        "--border-label= finder ",
        "--border-label-pos=-2:bottom",
        "--preview-border=sharp",
        "--preview-label= preview ",
        "--preview-label-pos=3:top",
        "--preview-window=left,40%,border-dashed",
    };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(BorderStyle.double, options.border_style);
    try std.testing.expectEqualStrings(" finder ", options.border_label.?);
    try std.testing.expectEqual(@as(i16, -2), options.border_label_pos.column);
    try std.testing.expect(options.border_label_pos.bottom);
    try std.testing.expectEqualStrings(" preview ", options.preview.label.?);
    try std.testing.expectEqual(@as(i16, 3), options.preview.label_pos.column);
    try std.testing.expect(!options.preview.label_pos.bottom);
    try std.testing.expectEqual(PreviewPosition.left, options.preview.position);
    try std.testing.expectEqual(@as(u8, 40), options.preview.percent);
    try std.testing.expectEqual(BorderStyle.dashed, options.preview.border_style);
}

test "listen option forms and action validation" {
    const a = std.testing.allocator;

    const unsafe_resets_address = [_][]const u8{ "zfuzz", "--listen", "6266", "--listen-unsafe" };
    var unsafe_default = try parseOptions(a, &unsafe_resets_address);
    defer unsafe_default.deinit(a);
    try std.testing.expectEqualStrings("", unsafe_default.listen_addr.?);
    try std.testing.expect(unsafe_default.listen_unsafe);

    const safe_resets_address = [_][]const u8{ "zfuzz", "--listen-unsafe=6266", "--listen" };
    var safe_default = try parseOptions(a, &safe_resets_address);
    defer safe_default.deinit(a);
    try std.testing.expectEqualStrings("", safe_default.listen_addr.?);
    try std.testing.expect(!safe_default.listen_unsafe);

    const unsafe_port = [_][]const u8{ "zfuzz", "--listen-unsafe", "6267" };
    var with_unsafe_port = try parseOptions(a, &unsafe_port);
    defer with_unsafe_port.deinit(a);
    try std.testing.expectEqualStrings("6267", with_unsafe_port.listen_addr.?);
    try std.testing.expect(with_unsafe_port.listen_unsafe);

    const unsafe_equals = [_][]const u8{ "zfuzz", "--listen-unsafe=localhost:6268" };
    var with_unsafe_equals = try parseOptions(a, &unsafe_equals);
    defer with_unsafe_equals.deinit(a);
    try std.testing.expectEqualStrings("localhost:6268", with_unsafe_equals.listen_addr.?);
    try std.testing.expect(with_unsafe_equals.listen_unsafe);

    const args_ephemeral = [_][]const u8{ "zfuzz", "--listen", "--height=20%" };
    var ephemeral = try parseOptions(a, &args_ephemeral);
    defer ephemeral.deinit(a);
    try std.testing.expectEqualStrings("", ephemeral.listen_addr.?);
    try std.testing.expect(!ephemeral.listen_unsafe);

    const plus_is_option = [_][]const u8{ "zfuzz", "--listen-unsafe", "+s" };
    var before_plus = try parseOptions(a, &plus_is_option);
    defer before_plus.deinit(a);
    try std.testing.expectEqualStrings("", before_plus.listen_addr.?);
    try std.testing.expect(before_plus.listen_unsafe);
    try std.testing.expect(before_plus.no_sort);

    const args_disabled = [_][]const u8{ "zfuzz", "--listen-unsafe=6267", "--no-listen-unsafe" };
    var disabled = try parseOptions(a, &args_disabled);
    defer disabled.deinit(a);
    try std.testing.expect(disabled.listen_addr == null);
    try std.testing.expect(!disabled.listen_unsafe);

    try std.testing.expectError(error.InvalidListenAddress, parseOptions(a, &.{ "zfuzz", "--listen=" }));
    try std.testing.expectError(error.InvalidListenAddress, parseOptions(a, &.{ "zfuzz", "--listen=localhost:nope" }));
    try std.testing.expectError(error.InvalidListenAddress, parseOptions(a, &.{ "zfuzz", "--listen=a:b:6269" }));

    try std.testing.expect(validateActionSequence("change-query(foo)+down"));
    try std.testing.expect(validateActionSequence("execute/printf a+b,c/+down"));
    try std.testing.expect(validateActionSequence("execute-silent(true)"));
    try std.testing.expect(!validateActionSequence("not-a-real-action"));
}

test "extended-exact alias restores both exact and extended search" {
    const a = std.testing.allocator;

    const args = [_][]const u8{ "zfuzz", "--exact", "--no-exact", "--no-extended", "--extended-exact" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expect(options.exact);
    try std.testing.expect(options.extended);

    const reset_args = [_][]const u8{ "zfuzz", "--extended-exact", "--no-exact", "--no-extended" };
    var reset = try parseOptions(a, &reset_args);
    defer reset.deinit(a);
    try std.testing.expect(!reset.exact);
    try std.testing.expect(!reset.extended);
}

test "legacy inline info aliases match fzf ordering" {
    const a = std.testing.allocator;

    const enable_args = [_][]const u8{ "zfuzz", "--info=inline-right:custom", "--inline-info" };
    var enabled = try parseOptions(a, &enable_args);
    defer enabled.deinit(a);
    try std.testing.expectEqual(InfoStyle.inline_left, enabled.info_style);
    try std.testing.expectEqualStrings(" < ", enabled.info_prefix);

    const disable_args = [_][]const u8{ "zfuzz", "--inline-info", "--info=inline-right:custom", "--no-inline-info" };
    var disabled = try parseOptions(a, &disable_args);
    defer disabled.deinit(a);
    try std.testing.expectEqual(InfoStyle.default, disabled.info_style);
    try std.testing.expectEqualStrings("custom", disabled.info_prefix);

    const right_args = [_][]const u8{ "zfuzz", "--info=inline-right" };
    var right = try parseOptions(a, &right_args);
    defer right.deinit(a);
    try std.testing.expectEqual(InfoStyle.inline_right, right.info_style);
    try std.testing.expectEqualStrings("", right.info_prefix);
}

test "expect preserves fzf comma key chords" {
    const a = std.testing.allocator;

    const comma_args = [_][]const u8{ "zfuzz", "--expect=," };
    var comma = try parseOptions(a, &comma_args);
    defer comma.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), comma.expect.items.len);
    try std.testing.expectEqualStrings(",", comma.expect.items[0]);

    const alt_args = [_][]const u8{ "zfuzz", "--expect", "AlT-," };
    var alt = try parseOptions(a, &alt_args);
    defer alt.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), alt.expect.items.len);
    try std.testing.expectEqualStrings("AlT-,", alt.expect.items[0]);

    const list_args = [_][]const u8{ "zfuzz", "--expect=a,,,b" };
    var list = try parseOptions(a, &list_args);
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), list.expect.items.len);
    try std.testing.expectEqualStrings("a", list.expect.items[0]);
    try std.testing.expectEqualStrings("b", list.expect.items[1]);
    try std.testing.expectEqualStrings(",", list.expect.items[2]);
}

test "expect aliases keep the last fzf spelling per event" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--expect=return,enter,ctrl-m,bspace,backspace,del,delete,space,tab,Ctrl-I" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), options.expect.items.len);
    try std.testing.expectEqualStrings("ctrl-m", options.expect.items[0]);
    try std.testing.expectEqualStrings("backspace", options.expect.items[1]);
    try std.testing.expectEqualStrings("delete", options.expect.items[2]);
    try std.testing.expectEqualStrings("space", options.expect.items[3]);
    try std.testing.expectEqualStrings("Ctrl-I", options.expect.items[4]);

    if (builtin.os.tag != .windows) {
        const backspace_args = [_][]const u8{ "zfuzz", "--expect=ctrl-h,ctrl-backspace,backspace" };
        var backspaces = try parseOptions(a, &backspace_args);
        defer backspaces.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), backspaces.expect.items.len);
        try std.testing.expectEqualStrings("ctrl-backspace", backspaces.expect.items[0]);
        try std.testing.expectEqualStrings("backspace", backspaces.expect.items[1]);
    }

    const ctrl_alt_args = [_][]const u8{ "zfuzz", "--expect=alt-enter,ctrl-alt-m,ctrl-alt-j" };
    var ctrl_alt = try parseOptions(a, &ctrl_alt_args);
    defer ctrl_alt.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), ctrl_alt.expect.items.len);
    try std.testing.expectEqualStrings("ctrl-alt-m", ctrl_alt.expect.items[0]);
    try std.testing.expectEqualStrings("ctrl-alt-j", ctrl_alt.expect.items[1]);

    const repeated_args = [_][]const u8{ "zfuzz", "--expect=return", "--expect=ENTER" };
    var repeated = try parseOptions(a, &repeated_args);
    defer repeated.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), repeated.expect.items.len);
    try std.testing.expectEqualStrings("ENTER", repeated.expect.items[0]);
}

test "fzf parser reset options are last-one-wins" {
    const a = std.testing.allocator;
    const args = [_][]const u8{
        "zfuzz",
        "--filepath-word",
        "--no-filepath-word",
        "--margin=1,2,3,4",
        "--no-margin",
        "--padding=4,3,2,1",
        "--no-padding",
        "--expect=ctrl-a,ctrl-b",
        "--no-expect",
        "--filepath-word",
        "--margin=5",
        "--padding=6",
        "--expect=enter",
    };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);

    try std.testing.expect(options.filepath_word);
    try std.testing.expectEqual(@as(usize, 1), options.expect.items.len);
    try std.testing.expectEqualStrings("enter", options.expect.items[0]);
    inline for (.{ options.margin.top, options.margin.right, options.margin.bottom, options.margin.left }) |side| {
        try std.testing.expectEqual(@as(u16, 5), side.value);
        try std.testing.expect(!side.percent);
    }
    inline for (.{ options.padding.top, options.padding.right, options.padding.bottom, options.padding.left }) |side| {
        try std.testing.expectEqual(@as(u16, 6), side.value);
        try std.testing.expect(!side.percent);
    }

    const reset_args = [_][]const u8{
        "zfuzz",
        "--filepath-word",
        "--no-filepath-word",
        "--margin=1%",
        "--no-margin",
        "--padding=2%",
        "--no-padding",
        "--expect=ctrl-a",
        "--no-expect",
    };
    var reset = try parseOptions(a, &reset_args);
    defer reset.deinit(a);
    try std.testing.expect(!reset.filepath_word);
    try std.testing.expectEqual(@as(usize, 0), reset.expect.items.len);
    inline for (.{ reset.margin.top, reset.margin.right, reset.margin.bottom, reset.margin.left }) |side| {
        try std.testing.expectEqual(@as(u16, 0), side.value);
        try std.testing.expect(!side.percent);
    }
    inline for (.{ reset.padding.top, reset.padding.right, reset.padding.bottom, reset.padding.left }) |side| {
        try std.testing.expectEqual(@as(u16, 0), side.value);
        try std.testing.expect(!side.percent);
    }
}

test "literal option toggles match fzf" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zfuzz", "--literal", "--no-literal", "--literal" };
    var options = try parseOptions(a, &args);
    defer options.deinit(a);
    try std.testing.expect(options.literal);
}

test "Unicode tiebreak lengths use rune offsets and Unicode whitespace" {
    try std.testing.expectEqual(@as(usize, 3), runeTrimLength("　éab　"));

    const score: CandidateScore = .{
        .min_begin = 1,
        .min_end = 2,
        .max_end = 2,
        .valid_offset = true,
        .rune_offsets = true,
    };
    try std.testing.expectEqual(@as(usize, 3), tiebreakValue(.length, "　éab　", score));
    try std.testing.expectEqual(@as(usize, 1), tiebreakValue(.begin, "　éab　", score));
}

test "subword boundary helpers match fzf fixtures" {
    const q = "foo bar foo-bar fooFooBar";
    try std.testing.expectEqual(@as(usize, 3), subwordBoundaryForward(q, 0));
    try std.testing.expectEqual(@as(usize, q.len - 3), subwordBoundaryBackward(q, q.len));
    try std.testing.expectEqual(@as(usize, "αβ".len), subwordBoundaryForward("αβ-γδ", 0));
    try std.testing.expectEqual(@as(usize, "αβ-".len), subwordBoundaryBackward("αβ-γδ", "αβ-γδ".len));
}

test "algorithm option accepts v1 v2 and heuristic" {
    const a = std.testing.allocator;
    const v2_args = [_][]const u8{ "zfuzz", "--algo=v2" };
    var v2 = try parseOptions(a, &v2_args);
    defer v2.deinit(a);
    try std.testing.expectEqual(Algorithm.v2, v2.algorithm);

    const v1_args = [_][]const u8{ "zfuzz", "--algo=v1" };
    var v1 = try parseOptions(a, &v1_args);
    defer v1.deinit(a);
    try std.testing.expectEqual(Algorithm.v1, v1.algorithm);

    const heuristic_args = [_][]const u8{ "zfuzz", "--algo", "heuristic" };
    var heuristic = try parseOptions(a, &heuristic_args);
    defer heuristic.deinit(a);
    try std.testing.expectEqual(Algorithm.heuristic, heuristic.algorithm);

    const bad_args = [_][]const u8{ "zfuzz", "--algo=nope" };
    try std.testing.expectError(error.InvalidAlgorithm, parseOptions(a, &bad_args));
}

test "heuristic mixed Unicode top-k is identical to v2" {
    const a = std.testing.allocator;
    const input =
        "src/group7/needle3\n" ++
        "Só Danço Samba source group7 needle3\n" ++
        "source group7 needle3\n" ++
        "é foo_bar source\n" ++
        "é FooBar source\n" ++
        "é f---b source\n" ++
        "café module target\n" ++
        "CAFÉ module target\n" ++
        "other\n";
    var build_options: Options = .{};
    defer build_options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, try a.dupe(u8, input), &build_options);
    defer candidates.deinit(a);
    try std.testing.expect(candidates.has_non_ascii);
    var v2_index = try fuzzy.init(a, candidates.search);
    defer v2_index.deinit();
    var heuristic_index = try fuzzy.init(a, candidates.search);
    defer heuristic_index.deinit();
    var v2_options: Options = .{};
    defer v2_options.deinit(a);
    var heuristic_options: Options = .{ .algorithm = .heuristic };
    defer heuristic_options.deinit(a);
    var v2_out: [16]usize = undefined;
    var heuristic_out: [16]usize = undefined;
    var v2_ranks: [16]ExtendedRank = undefined;
    var heuristic_ranks: [16]ExtendedRank = undefined;
    const queries = [_][]const u8{
        "source group7 needle3",
        "fb source",
        "cafe module",
        "café target",
    };
    for (queries) |query| {
        const expected = try searchCandidates(&v2_index, &candidates, &v2_options, query, &v2_out, &v2_ranks, v2_out.len);
        const got = try searchCandidates(&heuristic_index, &candidates, &heuristic_options, query, &heuristic_out, &heuristic_ranks, heuristic_out.len);
        try std.testing.expectEqualSlices(usize, expected, got);
    }
}

test "heuristic algorithm is randomized top-k identical to v2" {
    const a = std.testing.allocator;
    var blob_builder: std.ArrayList(u8) = .empty;
    defer blob_builder.deinit(a);
    var line_buf: [128]u8 = undefined;
    for (0..1280) |i| {
        const line = try std.fmt.bufPrint(&line_buf, "src/group{d}/module{d}/item-{d}-needle{d}", .{ i % 17, i % 23, i, i % 11 });
        try blob_builder.appendSlice(a, line);
        try blob_builder.append(a, '\n');
    }
    const blob = try blob_builder.toOwnedSlice(a);
    var build_options: Options = .{};
    defer build_options.deinit(a);
    var candidates = try candidatesFromOwnedBlob(a, blob, &build_options);
    defer candidates.deinit(a);

    var v2_index = try fuzzy.init(a, candidates.search);
    defer v2_index.deinit();
    var heuristic_index = try fuzzy.init(a, candidates.search);
    defer heuristic_index.deinit();
    var v2_options: Options = .{};
    defer v2_options.deinit(a);
    var heuristic_options: Options = .{ .algorithm = .heuristic };
    defer heuristic_options.deinit(a);
    var v2_out: [1280]usize = undefined;
    var heuristic_out: [1280]usize = undefined;
    var v2_ranks: [1280]ExtendedRank = undefined;
    var heuristic_ranks: [1280]ExtendedRank = undefined;
    var query_buf: [96]u8 = undefined;
    for (0..600) |trial| {
        const query = switch (trial % 3) {
            0 => try std.fmt.bufPrint(&query_buf, "src group{d} needle{d}", .{ trial % 17, trial % 11 }),
            1 => try std.fmt.bufPrint(&query_buf, "module{d} item needle{d}", .{ trial % 23, (trial * 7) % 11 }),
            else => try std.fmt.bufPrint(&query_buf, "group{d} | needle{d}", .{ trial % 17, (trial * 5) % 11 }),
        };
        const limit = 16 + trial % 128;
        const expected = try searchCandidates(&v2_index, &candidates, &v2_options, query, &v2_out, &v2_ranks, limit);
        const got = try searchCandidates(&heuristic_index, &candidates, &heuristic_options, query, &heuristic_out, &heuristic_ranks, limit);
        try std.testing.expectEqualSlices(usize, expected, got);
    }
}

test "lazy candidate view borrows compact-store records" {
    const a = std.testing.allocator;
    var store = compact_store.Store.init(a, std.testing.io);
    defer store.deinit();
    const alpha = try store.append("alpha");
    const unicode = try store.append("βeta");
    const ranks = [_]LazyRank{
        .{ .record = alpha, .score = .{} },
        .{ .record = unicode, .score = .{} },
    };
    var candidates = try candidatesFromLazyRanks(a, &ranks);
    defer candidates.deinit(a);
    try std.testing.expectEqual(alpha.ptr, candidates.output[0].ptr);
    try std.testing.expectEqual(unicode.ptr, candidates.output[1].ptr);
    try std.testing.expectEqualStrings("alpha", candidates.display[0]);
    try std.testing.expectEqualStrings("βeta", candidates.search[1]);
    try std.testing.expect(candidates.has_non_ascii);
}

test "lazy rank cached tiebreaks preserve comparator order" {
    const a = std.testing.allocator;
    var store = compact_store.Store.init(a, std.testing.io);
    defer store.deinit();
    const long = try store.append("longest");
    const short = try store.append("x");
    const mid0 = try store.append("mid");
    const mid1 = try store.append("zzz");
    var options: Options = .{};
    const ctx = LazyRankContext{ .config = LazySearchConfig.fromOptions(&options) };
    var ranks = [_]LazyRank{
        .{ .record = long, .score = .{} },
        .{ .record = mid1, .score = .{} },
        .{ .record = short, .score = .{} },
        .{ .record = mid0, .score = .{} },
    };
    for (&ranks) |*rank| prepareLazyRankTiebreaks(ctx, rank);
    std.mem.sort(LazyRank, &ranks, ctx, betterLazyRank);
    try std.testing.expectEqualSlices(u32, &.{ short.id, mid0.id, mid1.id, long.id }, &.{ ranks[0].record.id, ranks[1].record.id, ranks[2].record.id, ranks[3].record.id });
}

test "lazy top-k heap matches full ranking" {
    const a = std.testing.allocator;
    var store = compact_store.Store.init(a, std.testing.io);
    defer store.deinit();
    const texts = [_][]const u8{ "aaaa", "b", "ccc", "dd", "eeeee", "f", "gg", "hhh" };
    const scores = [_]i32{ 10, 30, 20, 30, 25, 30, 5, 27 };
    var options: Options = .{};
    const config = LazySearchConfig.fromOptions(&options);
    const ctx = LazyRankContext{ .config = config };
    var active = LazyActive{
        .generation = 1,
        .query = try a.dupe(u8, "x"),
        .config = config,
        .top_k = 3,
    };
    defer active.deinit(a);
    var all: [texts.len]LazyRank = undefined;
    for (texts, scores, 0..) |text, score, i| {
        const record = try store.append(text);
        all[i] = .{ .record = record, .score = .{ .score = score } };
        prepareLazyRankTiebreaks(ctx, &all[i]);
        try lazyInsertRank(&active, a, .{ .record = record, .score = .{ .score = score } }, true);
    }
    std.mem.sort(LazyRank, &all, ctx, betterLazyRank);
    const retained = try a.dupe(LazyRank, active.ranks.items);
    defer a.free(retained);
    std.mem.sort(LazyRank, retained, ctx, betterLazyRank);
    try std.testing.expectEqual(@as(usize, 3), retained.len);
    for (retained, 0..) |rank, i| try std.testing.expectEqual(all[i].record.id, rank.record.id);
}

test "lazy worker count leaves one third of logical CPUs free" {
    try std.testing.expectEqual(@as(usize, 1), lazyWorkerCountForCores(1));
    try std.testing.expectEqual(@as(usize, 1), lazyWorkerCountForCores(2));
    try std.testing.expectEqual(@as(usize, 2), lazyWorkerCountForCores(3));
    try std.testing.expectEqual(@as(usize, 8), lazyWorkerCountForCores(12));
    try std.testing.expectEqual(lazy_max_workers, lazyWorkerCountForCores(192));
}

test "lazy frontier refinement only reuses monotone compatible fuzzy queries" {
    const a = std.testing.allocator;
    var options: Options = .{};
    const config = LazySearchConfig.fromOptions(&options);

    var parse_options = config.parseOptions();
    var old_terms: [512]QueryTerm = undefined;
    const old_parsed = try parseQuery("a", &parse_options, &old_terms);
    var old_raw_terms: [512]RawTermPlan = undefined;
    const old_plan = prepareRawQuery(old_parsed, config.case_mode, !config.literal, config.scheme, config.algorithm, &old_raw_terms);
    var frontier = LazyShardFrontier{
        .allocator = a,
        .query = try a.dupe(u8, "a"),
        .config = config,
        .sensitive = old_plan.terms[0].sensitive,
        .normalize = old_plan.terms[0].normalize,
        .snapshot_count = 1234,
        .pages = try a.alloc(LazyFrontierPage, 0),
    };
    defer frontier.deinit();

    parse_options = config.parseOptions();
    var refined_terms: [512]QueryTerm = undefined;
    const refined_parsed = try parseQuery("ab", &parse_options, &refined_terms);
    var refined_raw_terms: [512]RawTermPlan = undefined;
    const refined_plan = prepareRawQuery(refined_parsed, config.case_mode, !config.literal, config.scheme, config.algorithm, &refined_raw_terms);
    try std.testing.expect(lazyFrontierCanRefine(&frontier, "ab", config, refined_plan, 1234));
    try std.testing.expect(lazyFrontierCanRefine(&frontier, "ab", config, refined_plan, 1235));
    try std.testing.expect(!lazyFrontierCanRefine(&frontier, "ab", config, refined_plan, 1233));

    parse_options = config.parseOptions();
    var upper_terms: [512]QueryTerm = undefined;
    const upper_parsed = try parseQuery("aB", &parse_options, &upper_terms);
    var upper_raw_terms: [512]RawTermPlan = undefined;
    const upper_plan = prepareRawQuery(upper_parsed, config.case_mode, !config.literal, config.scheme, config.algorithm, &upper_raw_terms);
    try std.testing.expect(!lazyFrontierCanRefine(&frontier, "aB", config, upper_plan, 1234));
}

test "lazy frontier bitmap stores the minority side" {
    try std.testing.expect(!lazyCacheStoresMatches(750, 1000));
    try std.testing.expect(lazyCacheStoresMatches(250, 1000));
    try std.testing.expect(lazyCacheStoresMatches(0, 0));

    var bits = [_]u64{0};
    lazySetFrontierBit(&bits, 3);
    const survivors = LazyFrontierPage{ .page_index = 0, .record_count = 8, .stores_matches = true, .bits = &bits };
    const rejects = LazyFrontierPage{ .page_index = 0, .record_count = 8, .stores_matches = false, .bits = &bits };
    try std.testing.expect(!lazyFrontierCanSkip(survivors, 3));
    try std.testing.expect(lazyFrontierCanSkip(survivors, 2));
    try std.testing.expect(lazyFrontierCanSkip(rejects, 3));
    try std.testing.expect(!lazyFrontierCanSkip(rejects, 2));
}

test "lazy frontier bitset records shard-local survivors" {
    var bits = [_]u64{ 0, 0 };
    lazySetFrontierBit(&bits, 0);
    lazySetFrontierBit(&bits, 63);
    lazySetFrontierBit(&bits, 64);
    const page = LazyFrontierPage{ .page_index = 7, .record_count = 65, .stores_matches = true, .bits = &bits };
    try std.testing.expect(lazyFrontierBitSet(page, 0));
    try std.testing.expect(!lazyFrontierBitSet(page, 1));
    try std.testing.expect(lazyFrontierBitSet(page, 63));
    try std.testing.expect(lazyFrontierBitSet(page, 64));
    try std.testing.expect(!lazyFrontierBitSet(page, 65));
    try std.testing.expect(lazyFrontierCanSkip(page, 1));
    try std.testing.expect(!lazyFrontierCanSkip(page, 0));
    // Index 65 did not exist when this frontier was built. It must be scored
    // if the page later grows rather than being treated as an old nonmatch.
    try std.testing.expect(!lazyFrontierCanSkip(page, 65));
}

test "page frontier falls back independently across recent query generations" {
    const a = std.testing.allocator;
    var options: Options = .{};
    const config = LazySearchConfig.fromOptions(&options);
    var parse_options = config.parseOptions();
    var term_buf: [512]QueryTerm = undefined;
    const parsed = try parseQuery("abc", &parse_options, &term_buf);
    var raw_term_buf: [512]RawTermPlan = undefined;
    const raw_plan = prepareRawQuery(parsed, config.case_mode, !config.literal, config.scheme, config.algorithm, &raw_term_buf);
    const sensitive = raw_plan.terms[0].sensitive;
    const normalize = raw_plan.terms[0].normalize;

    var cache: LazyShardCache = .{};
    defer cache.deinit();

    const a_pages = try a.alloc(LazyFrontierPage, 2);
    const a_bits0 = try a.alloc(u64, 1);
    const a_bits1 = try a.alloc(u64, 1);
    a_bits0[0] = 1;
    a_bits1[0] = 1;
    a_pages[0] = .{ .page_index = 0, .record_count = 2, .stores_matches = true, .bits = a_bits0 };
    a_pages[1] = .{ .page_index = 1, .record_count = 2, .stores_matches = true, .bits = a_bits1 };
    cache.store(.{
        .allocator = a,
        .query = try a.dupe(u8, "a"),
        .config = config,
        .sensitive = sensitive,
        .normalize = normalize,
        .snapshot_count = 4,
        .pages = a_pages,
    });

    const ab_pages = try a.alloc(LazyFrontierPage, 1);
    const ab_bits0 = try a.alloc(u64, 1);
    ab_bits0[0] = 2;
    ab_pages[0] = .{ .page_index = 0, .record_count = 2, .stores_matches = true, .bits = ab_bits0 };
    cache.store(.{
        .allocator = a,
        .query = try a.dupe(u8, "ab"),
        .config = config,
        .sensitive = sensitive,
        .normalize = normalize,
        .snapshot_count = 4,
        .pages = ab_pages,
    });

    const page0 = lazyBestFrontierPage(&cache, "abc", config, raw_plan, 4, 0) orelse return error.TestUnexpectedResult;
    const page1 = lazyBestFrontierPage(&cache, "abc", config, raw_plan, 4, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!lazyFrontierBitSet(page0, 0));
    try std.testing.expect(lazyFrontierBitSet(page0, 1));
    try std.testing.expect(lazyFrontierBitSet(page1, 0));
}

test "completed shard frontier survives a stale global generation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const backend = try LazyBackend.create(a, io);
    defer backend.destroy();
    _ = try backend.store.append("alpha");
    backend.finishInput();
    var snapshot = try backend.store.snapshot(a);
    defer snapshot.deinit();

    var options: Options = .{};
    const config = LazySearchConfig.fromOptions(&options);
    var parse_options = config.parseOptions();
    var term_buf: [512]QueryTerm = undefined;
    const parsed = try parseQuery("a", &parse_options, &term_buf);
    var raw_term_buf: [512]RawTermPlan = undefined;
    const raw_plan = prepareRawQuery(parsed, config.case_mode, !config.literal, config.scheme, config.algorithm, &raw_term_buf);
    var state = LazyActive{
        .generation = 1,
        .query = try a.dupe(u8, "a"),
        .config = config,
        .top_k = 8,
    };
    defer state.deinit(a);
    var worker = LazyShardWorker{
        .allocator = a,
        .snapshot = &snapshot,
        .raw_plan = raw_plan,
        .config = config,
        .latest_generation = &backend.latest_generation,
        .stop = &backend.stop,
        .generation = 1,
        .top_k = 8,
        .shard_index = 0,
        .shard_count = backend.worker_count,
        .sortable = true,
        .cache_frontier = true,
        .cache_matches = true,
        .cache_sparse = false,
        .query = state.query,
        .reuse_cache = &backend.shard_caches[0],
        .completed = true,
    };
    defer worker.deinit();
    const bits = try a.alloc(u64, 1);
    bits[0] = 1;
    try worker.frontier_pages.append(a, .{ .page_index = 0, .record_count = 1, .stores_matches = true, .bits = bits });

    // Simulate a keypress arriving after this shard finished but before the
    // other shards did. The completed old-generation shard is still reusable.
    backend.latest_generation.store(2, .release);
    lazyCommitShardFrontier(backend, &state, raw_plan, snapshot.count, &worker);

    parse_options = config.parseOptions();
    var refined_terms: [512]QueryTerm = undefined;
    const refined = try parseQuery("ab", &parse_options, &refined_terms);
    var refined_raw_terms: [512]RawTermPlan = undefined;
    const refined_plan = prepareRawQuery(refined, config.case_mode, !config.literal, config.scheme, config.algorithm, &refined_raw_terms);
    try std.testing.expect(lazyBestFrontier(&backend.shard_caches[0], "ab", config, refined_plan, snapshot.count) != null);
    try std.testing.expectEqual(@as(usize, 0), worker.frontier_pages.items.len);
}

test "lazy backend retains completed shard frontier for appended query" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const backend = try LazyBackend.create(a, io);
    defer backend.destroy();
    const total: usize = 100_000;
    var expected_ab: u32 = 0;
    for (0..total) |i| {
        var buf: [128]u8 = undefined;
        const line = if (i % 4 == 0) blk: {
            expected_ab += 1;
            break :blk try std.fmt.bufPrint(&buf, "alpha beta target row {d:0>6} ........................................................", .{i});
        } else try std.fmt.bufPrint(&buf, "alpha ordinary row {d:0>6} ............................................................", .{i});
        _ = try backend.store.append(line);
    }
    backend.finishInput();
    var options: Options = .{};
    const first_generation = try backend.submit("a", &options, 64);
    var spins: usize = 0;
    while (spins < 4_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            const complete = candidate.generation == first_generation and candidate.search_complete;
            candidate.deinit();
            if (complete) break;
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(spins < 4_000_000);

    const config = LazySearchConfig.fromOptions(&options);
    var parse_options = config.parseOptions();
    var term_buf: [512]QueryTerm = undefined;
    const parsed = try parseQuery("ab", &parse_options, &term_buf);
    var raw_term_buf: [512]RawTermPlan = undefined;
    const raw_plan = prepareRawQuery(parsed, config.case_mode, !config.literal, config.scheme, config.algorithm, &raw_term_buf);
    var reusable: usize = 0;
    for (backend.shard_caches) |*cache| if (lazyBestFrontier(cache, "ab", config, raw_plan, @intCast(total)) != null) {
        reusable += 1;
    };
    var cache_snapshot = try backend.store.snapshot(a);
    defer cache_snapshot.deinit();
    try std.testing.expectEqual(@min(backend.worker_count, cache_snapshot.pageCount()), reusable);

    const second_generation = try backend.submit("ab", &options, 64);
    var final: ?*LazyResult = null;
    spins = 0;
    while (spins < 4_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            if (candidate.generation == second_generation and candidate.search_complete) {
                final = candidate;
                break;
            }
            candidate.deinit();
        }
        std.Thread.yield() catch {};
    }
    const got = final orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expectEqual(expected_ab, got.match_count);
    try std.testing.expectEqual(@as(u32, @intCast(total)), got.scanned_count);
    for (got.ranks) |rank| try std.testing.expect(std.mem.indexOf(u8, rank.record.text(), "beta") != null);
}

test "lazy backend scans compact store asynchronously with exact full count" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const backend = try LazyBackend.create(a, io);
    defer backend.destroy();
    var expected_matches: u32 = 0;
    for (0..10_000) |i| {
        var buf: [96]u8 = undefined;
        const line = if (i % 7 == 0) blk: {
            expected_matches += 1;
            break :blk try std.fmt.bufPrint(&buf, "row-{d:0>5}-needle-target", .{i});
        } else try std.fmt.bufPrint(&buf, "row-{d:0>5}-ordinary", .{i});
        _ = try backend.store.append(line);
    }
    backend.finishInput();
    var options: Options = .{};
    const generation = try backend.submit("needle", &options, 64);
    var result: ?*LazyResult = null;
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            if (candidate.generation == generation and candidate.search_complete) {
                result = candidate;
                break;
            }
            candidate.deinit();
        }
        std.Thread.yield() catch {};
    }
    const final = result orelse return error.TestUnexpectedResult;
    defer final.deinit();
    try std.testing.expectEqual(@as(u32, 10_000), final.total_count);
    try std.testing.expectEqual(expected_matches, final.match_count);
    try std.testing.expectEqual(@as(u32, 10_000), final.scanned_count);
    try std.testing.expectEqual(@as(usize, 64), final.ranks.len);
    for (final.ranks) |rank| try std.testing.expect(std.mem.indexOf(u8, rank.record.text(), "needle") != null);
}

test "terminal cell width handles wide combining and invalid UTF-8" {
    try std.testing.expectEqual(@as(usize, 3), visibleTextWidth("A你", false));
    try std.testing.expectEqual(@as(usize, 3), visibleTextWidth("A🙂", false));
    try std.testing.expectEqual(@as(usize, 1), visibleTextWidth("e\u{301}", false));
    try std.testing.expectEqual(@as(usize, 1), visibleTextWidth(&.{0xff}, false));
    try std.testing.expectEqual(@as(usize, 1), visibleTextWidth("\x1b[31mX\x1b[0m", true));
}

test "terminal truncation preserves UTF-8 cell boundaries" {
    const a = std.testing.allocator;
    var plain: Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    try writeTruncated(&plain.writer, "你好吗", 3, false, "");
    try std.testing.expectEqualStrings("你…", plain.written());

    var highlighted: Io.Writer.Allocating = .init(a);
    defer highlighted.deinit();
    var theme: Theme = .{};
    theme.enabled = false;
    try writeHighlighted(&highlighted.writer, "你好吗", "", 3, false, false, &theme, false, false);
    try std.testing.expectEqualStrings("你…", highlighted.written());
}

test "lazy backend publishes zero-match progress before input completion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const backend = try LazyBackend.create(a, io);
    defer backend.destroy();
    for (0..20_000) |i| {
        var buf: [48]u8 = undefined;
        _ = try backend.store.append(try std.fmt.bufPrint(&buf, "ordinary-{d}", .{i}));
    }
    var options: Options = .{};
    const generation = try backend.submit("~", &options, 32);
    backend.notifyData();
    var partial: ?*LazyResult = null;
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            if (candidate.generation == generation and candidate.scanned_count == 20_000 and !candidate.search_complete) {
                partial = candidate;
                break;
            }
            candidate.deinit();
        }
        std.Thread.yield() catch {};
    }
    const got = partial orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expectEqual(@as(u32, 0), got.match_count);
    try std.testing.expectEqual(@as(usize, 0), got.ranks.len);
    try std.testing.expectEqual(@as(u32, 20_000), got.total_count);
}

test "lazy backend newest query generation replaces older work" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const backend = try LazyBackend.create(a, io);
    defer backend.destroy();
    for (0..30_000) |i| {
        var buf: [64]u8 = undefined;
        const line = if (i % 3 == 0)
            try std.fmt.bufPrint(&buf, "alpha-{d}", .{i})
        else
            try std.fmt.bufPrint(&buf, "beta-{d}", .{i});
        _ = try backend.store.append(line);
    }
    backend.finishInput();
    var options: Options = .{};
    _ = try backend.submit("alpha", &options, 64);
    const newest = try backend.submit("beta", &options, 64);
    var final: ?*LazyResult = null;
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            if (candidate.generation == newest and candidate.search_complete) {
                final = candidate;
                break;
            }
            candidate.deinit();
        }
        std.Thread.yield() catch {};
    }
    const got = final orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expectEqual(@as(u32, 20_000), got.match_count);
    for (got.ranks) |rank| try std.testing.expect(std.mem.startsWith(u8, rank.record.text(), "beta-"));
}

test "lazy accept waits for current generation and incomplete empty results" {
    try std.testing.expect(!lazyAcceptNeedsWait(false, 1, 2, 0, 0, false));
    try std.testing.expect(lazyAcceptNeedsWait(true, 1, 2, 1, 0, false));
    try std.testing.expect(lazyAcceptNeedsWait(true, 2, 2, 0, 0, false));
    try std.testing.expect(!lazyAcceptNeedsWait(true, 2, 2, 1, 0, false));
    try std.testing.expect(!lazyAcceptNeedsWait(true, 2, 2, 0, 1, false));
    try std.testing.expect(!lazyAcceptNeedsWait(true, 2, 2, 0, 0, true));
}

test "lazy backend cancels a running generation without later stale publication" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const backend = try LazyBackend.create(a, io);
    defer backend.destroy();
    const total: usize = 200_000;
    for (0..total) |i| {
        var buf: [80]u8 = undefined;
        const line = if (i % 2 == 0)
            try std.fmt.bufPrint(&buf, "alpha alphabetic candidate row {d}", .{i})
        else
            try std.fmt.bufPrint(&buf, "beta betatron candidate row {d}", .{i});
        _ = try backend.store.append(line);
    }
    backend.finishInput();

    var options: Options = .{ .exact = true };
    const old_generation = try backend.submit("alpha", &options, 64);
    var saw_running_old = false;
    var spins: usize = 0;
    while (spins < 4_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            defer candidate.deinit();
            if (candidate.generation == old_generation and candidate.scanned_count > 0 and !candidate.search_complete) {
                saw_running_old = true;
                break;
            }
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(saw_running_old);

    const newest = try backend.submit("beta", &options, 64);
    var final: ?*LazyResult = null;
    spins = 0;
    while (spins < 4_000_000) : (spins += 1) {
        if (backend.takeResult()) |candidate| {
            if (candidate.generation != newest) {
                candidate.deinit();
                return error.TestUnexpectedResult;
            }
            if (candidate.search_complete) {
                final = candidate;
                break;
            }
            candidate.deinit();
        }
        std.Thread.yield() catch {};
    }
    const got = final orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expectEqual(@as(u32, @intCast(total / 2)), got.match_count);
    try std.testing.expectEqual(@as(u32, @intCast(total)), got.scanned_count);
}

test "lazy interactive eligibility keeps whole-corpus modes on fallback" {
    var options: Options = .{};
    try std.testing.expect(lazyInteractiveEligible(&options));
    options.tail = 5;
    try std.testing.expect(!lazyInteractiveEligible(&options));
    options.tail = null;
    options.header_lines = 1;
    try std.testing.expect(!lazyInteractiveEligible(&options));
    options.header_lines = 0;
    options.ansi = true;
    try std.testing.expect(!lazyInteractiveEligible(&options));
    options.ansi = false;
    options.multi = true;
    try std.testing.expect(!lazyInteractiveEligible(&options));
    options.multi = false;
    options.track = true;
    try std.testing.expect(!lazyInteractiveEligible(&options));
    options.track = false;
    options.listen_addr = "";
    try std.testing.expect(!lazyInteractiveEligible(&options));
}
