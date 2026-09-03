const std = @import("std");
const fuzzy = @import("fuzzy");
const fuzzy_engine = @import("engine");
const listen = @import("listen.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const esc = "\x1b[";

const Layout = enum { default, reverse };
const CaseMode = enum { smart, ignore, respect };
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
    up,
    down,
    page_up,
    page_down,
    backward_word,
    forward_word,
    backward_kill_word,
    kill_word,
    first,
    last,
    toggle,
    toggle_up,
    select,
    deselect,
    select_all,
    deselect_all,
    clear_query,
    accept,
    abort,
    toggle_preview,
    show_preview,
    hide_preview,
    refresh_preview,
    toggle_preview_wrap,
    toggle_wrap,
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
    change_prompt: []const u8,
    change_header: []const u8,
    change_footer: []const u8,
    change_preview: []const u8,
    transform: []const u8,
    transform_query: []const u8,
    transform_prompt: []const u8,
    transform_header: []const u8,
    transform_footer: []const u8,
    transform_preview: []const u8,
    print: []const u8,
    reload: []const u8,
    execute: []const u8,
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
    pointer: []const u8 = ">",
    marker: []const u8 = ">",
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
    wrap: bool = false,
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
    border: bool = true,
    border_style: BorderStyle = .rounded,
    border_label: ?[]const u8 = null,
    border_label_pos: LabelPosition = .{},
    bold: bool = true,
    theme: Theme = .{},
    info_style: InfoStyle = .default,
    info_prefix: []const u8 = " < ",
    separator: ?[]const u8 = "─",
    ghost: ?[]const u8 = null,
    margin: Insets = .{},
    padding: Insets = .{ .right = .{ .value = 1 }, .left = .{ .value = 1 } },
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
        self.bindings.deinit(allocator);
        self.walker_roots.deinit(allocator);
    }
};

const CandidateSet = struct {
    blob: []u8,
    header: [][]const u8,
    output: [][]const u8,
    display: [][]const u8,
    search: [][]const u8,
    owned_display: bool,
    owned_search: bool,

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

const Terminal = struct {
    file: Io.File,
    original: std.posix.termios,
    active: bool = false,
    mouse: bool,
    inline_mode: bool,
    height_percent: u8,
    inline_rows: usize = 0,

    fn open(io: Io, mouse: bool, height_percent: u8) !Terminal {
        var file = try Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        errdefer file.close(io);
        const original = try std.posix.tcgetattr(file.handle);
        return .{ .file = file, .original = original, .mouse = mouse, .inline_mode = height_percent < 100, .height_percent = height_percent };
    }

    fn enter(self: *Terminal) !void {
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
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
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
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.file.handle, bytes.ptr + off, bytes.len - off);
            if (n < 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn readByte(self: *Terminal) !u8 {
        var b: [1]u8 = undefined;
        while (true) {
            const n = std.c.read(self.file.handle, &b, 1);
            if (n == 1) return b[0];
            if (n == 0) return error.Timeout;
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.posix.E.INTR)) continue;
            return error.ReadFailed;
        }
    }

    fn physicalSize(self: *Terminal) TerminalSize {
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
    history: ?QueryHistory = null,
    track_once: bool = false,
    pending_track_key: ?[]u8 = null,
    query: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    results: []usize,
    extended_ranks: []ExtendedRank,
    result_len: usize = 0,
    result_cap: usize = 0,
    focus: usize = 0,
    scroll: usize = 0,
    selected: []bool,
    selection_order: std.ArrayList(usize) = .empty,
    selected_count: usize = 0,
    dirty_search: bool = true,
    preview_cache_key: ?usize = null,
    preview_cache_query_hash: u64 = 0,
    preview_text: []u8 = &.{},
    preview_offset: usize = 0,
    accepted_key: ?[]const u8 = null,
    change_event_pending: bool = false,
    load_event_pending: bool = false,
    result_event_pending: bool = false,
    result_final_event_pending: bool = false,
    zero_event_pending: bool = false,
    one_event_pending: bool = false,
    focus_event_pending: bool = false,
    owned_prompt: ?[]u8 = null,
    owned_header: ?[]u8 = null,
    owned_footer: ?[]u8 = null,
    owned_preview: ?[]u8 = null,
    print_queue: std.ArrayList([]u8) = .empty,
    input_hidden: bool = false,
    header_hidden: bool = false,
    last_action: []const u8 = "",
    last_key: []const u8 = "",
    timer_last_ms: []u64 = &.{},
    last_activity_ms: u64 = 0,

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
    ) !Ui {
        var query: std.ArrayList(u8) = .empty;
        try query.appendSlice(allocator, options.query);
        const results = try allocator.alloc(usize, candidates.display.len);
        errdefer allocator.free(results);
        const extended_ranks = try allocator.alloc(ExtendedRank, candidates.display.len);
        errdefer allocator.free(extended_ranks);
        const selected = try allocator.alloc(bool, candidates.display.len);
        @memset(selected, false);
        var history: ?QueryHistory = null;
        if (options.history_file) |path| history = try QueryHistory.init(allocator, io, path, options.history_size, options.query);
        errdefer if (history) |*value| value.deinit();
        const timer_last_ms = try allocator.alloc(u64, options.bindings.items.len);
        errdefer allocator.free(timer_last_ms);
        const now_ms = monotonicMilliseconds(io);
        @memset(timer_last_ms, now_ms);
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
            .history = history,
            .query = query,
            .cursor = options.query.len,
            .results = results,
            .extended_ranks = extended_ranks,
            .selected = selected,
            .timer_last_ms = timer_last_ms,
            .last_activity_ms = now_ms,
        };
    }

    fn deinit(self: *Ui) void {
        if (self.history) |*history| history.deinit();
        if (self.pending_track_key) |key| self.allocator.free(key);
        self.query.deinit(self.allocator);
        self.allocator.free(self.results);
        self.allocator.free(self.extended_ranks);
        self.allocator.free(self.selected);
        self.selection_order.deinit(self.allocator);
        if (self.preview_text.len != 0) self.allocator.free(self.preview_text);
        if (self.owned_prompt) |value| self.allocator.free(value);
        if (self.owned_header) |value| self.allocator.free(value);
        if (self.owned_footer) |value| self.allocator.free(value);
        if (self.owned_preview) |value| self.allocator.free(value);
        for (self.print_queue.items) |value| self.allocator.free(value);
        self.print_queue.deinit(self.allocator);
        if (self.timer_last_ms.len != 0) self.allocator.free(self.timer_last_ms);
    }

    fn run(self: *Ui) !u8 {
        try self.refreshSearch(true);
        const input_complete = self.stream == null or self.stream.?.eof;
        if (input_complete and self.options.select_1 and self.result_len == 1) {
            try self.emitSelection(null);
            return 0;
        }
        if (input_complete and self.options.exit_0 and self.result_len == 0) return 1;

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
                if (self.options.select_1 and self.result_len == 1) {
                    try self.emitSelection(null);
                    return 0;
                }
                if (self.options.exit_0 and self.result_len == 0) return 1;
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
            try self.render();
            const key = try readKey(self.terminal);
            if (key != .unknown) self.last_activity_ms = monotonicMilliseconds(self.io);
            if (try self.handleKey(key)) |code| return code;
        }
    }

    fn refreshSearch(self: *Ui, force_all_for_auto: bool) !void {
        const n = self.candidates.display.len;
        var track_key = self.pending_track_key;
        self.pending_track_key = null;
        if (track_key == null and self.trackingActive()) track_key = try self.captureCurrentTrackKey();
        defer if (track_key) |key| self.allocator.free(key);

        const size = self.terminal.size();
        const base_cap = @min(n, @max(@as(usize, 256), size.rows * 8));
        if (self.result_cap == 0) self.result_cap = base_cap;
        if (force_all_for_auto and (self.options.select_1 or self.options.exit_0)) self.result_cap = n;
        if (self.options.no_sort or track_key != null) self.result_cap = n;

        const effective_query: []const u8 = if (self.options.disabled) "" else self.query.items;
        const old_focus_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        const found = try searchCandidates(self.index, self.candidates, self.options, effective_query, self.results, self.extended_ranks, self.result_cap);
        self.result_len = found.len;
        if (self.options.no_sort) std.mem.sort(usize, self.results[0..self.result_len], {}, comptime std.sort.asc(usize));
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
        self.zero_event_pending = self.result_len == 0;
        self.one_event_pending = self.result_len == 1;
        self.result_final_event_pending = self.stream == null or self.stream.?.eof;
        const new_focus_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        if (old_focus_idx != new_focus_idx) self.focus_event_pending = true;
    }

    fn growResults(self: *Ui) !void {
        if (self.result_cap >= self.candidates.display.len) return;
        self.result_cap = @min(self.candidates.display.len, @max(self.result_cap + 1, self.result_cap * 2));
        self.dirty_search = true;
        try self.refreshSearch(false);
    }

    fn paneGeometry(self: *Ui, size: anytype) PaneGeometry {
        const full = Pane{ .row = 1, .col = 1, .rows = size.rows, .cols = size.cols };
        const area = insetPane(full, self.options.margin);
        var main_pane = area;
        const preview_active = self.options.preview.command != null and !self.options.preview.hidden;
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
        const list_rows = self.visibleListRows();
        if (list_rows == 0) return;
        if (self.focus < self.scroll) self.scroll = self.focus;
        if (self.focus >= self.scroll + list_rows) self.scroll = self.focus + 1 - list_rows;
    }

    fn listRows(self: *Ui, rows: usize) usize {
        var fixed: usize = @intFromBool(!self.input_hidden);
        if (self.options.info_style == .default or self.options.info_style == .right) fixed += 1;
        fixed += self.headerRowCount();
        if (self.options.footer != null) fixed += 1;
        const effective = @max(@as(usize, 3), rows);
        return if (effective > fixed) effective - fixed else 1;
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
        for (self.options.bindings.items) |binding| {
            if (!binding.enabled) continue;
            if (std.mem.eql(u8, binding.trigger, "start") or std.mem.eql(u8, binding.trigger, "load") or
                std.mem.eql(u8, binding.trigger, "change") or std.mem.eql(u8, binding.trigger, "result") or
                std.mem.eql(u8, binding.trigger, "result-final") or std.mem.eql(u8, binding.trigger, "zero") or
                std.mem.eql(u8, binding.trigger, "one") or std.mem.eql(u8, binding.trigger, "focus")) continue;
            if (!keyMatchesName(key, binding.trigger)) continue;
            binding_handled = true;
            self.last_action = binding.name;
            self.last_key = binding.trigger;
            if (try self.runAction(binding.action)) |code| return code;
        }
        if (binding_handled) return null;
        for (self.options.expect.items) |expected| {
            if (keyMatchesName(key, expected)) {
                self.accepted_key = expected;
                if (self.result_len == 0 and self.selected_count == 0) return 1;
                try self.emitSelection(expected);
                return 0;
            }
        }
        switch (key) {
            .up => self.move(-1),
            .down => self.move(1),
            .page_up => self.page(-1),
            .page_down => self.page(1),
            .word_left => self.cursor = wordBoundaryBackward(self.query.items, self.cursor),
            .word_right => self.cursor = wordBoundaryForward(self.query.items, self.cursor),
            .home => {
                self.cursor = 0;
            },
            .end => {
                self.cursor = self.query.items.len;
            },
            .left => self.cursor = prevUtf8Boundary(self.query.items, self.cursor),
            .right => self.cursor = nextUtf8Boundary(self.query.items, self.cursor),
            .delete => {
                if (self.cursor < self.query.items.len) {
                    const next = nextUtf8Boundary(self.query.items, self.cursor);
                    self.query.replaceRange(self.allocator, self.cursor, next - self.cursor, &.{}) catch return error.OutOfMemory;
                    self.markQueryChanged();
                }
            },
            .shift_tab => if (self.options.multi) {
                try self.toggleCurrent();
                self.move(-1);
            },
            .mouse => |m| try self.handleMouse(m),
            .byte => |b| switch (b) {
                3, 7, 27 => return 130,
                13 => {
                    if (self.result_len == 0 and self.selected_count == 0) return 1;
                    try self.emitSelection(self.accepted_key);
                    return 0;
                },
                10 => self.move(1),
                9 => if (self.options.multi) {
                    try self.toggleCurrent();
                    self.move(1);
                },
                127, 8 => {
                    if (self.cursor != 0) {
                        const prev = prevUtf8Boundary(self.query.items, self.cursor);
                        self.query.replaceRange(self.allocator, prev, self.cursor - prev, &.{}) catch return error.OutOfMemory;
                        self.cursor = prev;
                        self.markQueryChanged();
                    }
                },
                1 => self.cursor = 0,
                5 => self.cursor = self.query.items.len,
                11 => self.move(-1),
                16 => if (self.history != null) try self.navigateHistory(-1) else self.move(-1),
                14 => if (self.history != null) try self.navigateHistory(1) else self.move(1),
                21 => {
                    self.query.clearRetainingCapacity();
                    self.cursor = 0;
                    self.markQueryChanged();
                },
                23 => {
                    self.deleteWordBackward();
                    self.markQueryChanged();
                },
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
                'b' => self.cursor = wordBoundaryBackward(self.query.items, self.cursor),
                'f' => self.cursor = wordBoundaryForward(self.query.items, self.cursor),
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
        self.dirty_search = true;
        self.change_event_pending = true;
        self.preview_cache_key = null;
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
                        self.last_action = binding.name;
                        self.last_key = "";
                        if (try self.runAction(binding.action)) |code| return code;
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

    fn dumpStatus(self: *Ui, params: listen.GetParams) ![]u8 {
        const StatusItem = struct {
            index: usize,
            text: []const u8,
        };
        const start = @min(params.offset, self.result_len);
        const match_count = @min(params.limit, self.result_len - start);
        const matches = try self.allocator.alloc(StatusItem, match_count);
        defer self.allocator.free(matches);
        for (matches, 0..) |*item, i| {
            const idx = self.results[start + i];
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
            .matchCount = self.result_len,
            .current = current,
            .matches = matches,
            .selected = selected,
        }, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn fireEvent(self: *Ui, event: []const u8) !?u8 {
        for (self.options.bindings.items) |binding| {
            if (!binding.enabled) continue;
            if (!std.mem.eql(u8, binding.trigger, event)) continue;
            self.last_action = binding.name;
            self.last_key = "";
            if (try self.runAction(binding.action)) |code| return code;
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
            self.last_action = binding.name;
            self.last_key = "";
            if (try self.runAction(binding.action)) |code| return code;
        }
        return null;
    }

    fn runAction(self: *Ui, action: Action) anyerror!?u8 {
        switch (action) {
            .up => self.move(-1),
            .down => self.move(1),
            .page_up => self.page(-1),
            .page_down => self.page(1),
            .backward_word => self.cursor = wordBoundaryBackward(self.query.items, self.cursor),
            .forward_word => self.cursor = wordBoundaryForward(self.query.items, self.cursor),
            .backward_kill_word => {
                self.deleteWordBackward();
                self.markQueryChanged();
            },
            .kill_word => {
                const end = wordBoundaryForward(self.query.items, self.cursor);
                if (end != self.cursor) {
                    try self.query.replaceRange(self.allocator, self.cursor, end - self.cursor, &.{});
                    self.markQueryChanged();
                }
            },
            .first => if (self.result_len != 0) {
                if (self.focus != 0) {
                    self.focus_event_pending = true;
                    self.cancelOneShotTracking();
                }
                self.focus = 0;
                self.ensureVisible();
                self.preview_cache_key = null;
            },
            .last => if (self.result_len != 0) {
                const target = self.result_len - 1;
                if (self.focus != target) {
                    self.focus_event_pending = true;
                    self.cancelOneShotTracking();
                }
                self.focus = target;
                self.ensureVisible();
                self.preview_cache_key = null;
            },
            .toggle => try self.toggleCurrent(),
            .select => try self.selectCurrent(),
            .deselect => self.deselectCurrent(),
            .toggle_up => {
                try self.toggleCurrent();
                self.move(-1);
            },
            .select_all => {
                if (self.options.multi) {
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
            .accept => {
                if (self.result_len == 0 and self.selected_count == 0) return 1;
                try self.emitSelection(null);
                return 0;
            },
            .abort => return 130,
            .toggle_preview => {
                self.options.preview.hidden = !self.options.preview.hidden;
                self.preview_cache_key = null;
            },
            .show_preview => {
                self.options.preview.hidden = false;
                self.preview_cache_key = null;
            },
            .hide_preview => self.options.preview.hidden = true,
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
            .change_prompt => |value| self.options.prompt = value,
            .change_header => |value| self.options.header = value,
            .change_footer => |value| self.options.footer = value,
            .change_preview => |value| {
                self.options.preview.command = value;
                self.options.preview.hidden = false;
                self.preview_cache_key = null;
                self.preview_offset = 0;
            },
            .transform => |cmd| return try self.runTransformActions(cmd),
            .transform_query => |cmd| {
                const value = try self.runTransformCommand(cmd);
                defer self.allocator.free(value);
                self.query.clearRetainingCapacity();
                try self.query.appendSlice(self.allocator, value);
                self.cursor = self.query.items.len;
                self.markQueryChanged();
            },
            .transform_prompt => |cmd| {
                const value = try self.runTransformCommand(cmd);
                self.replaceOwnedText(&self.owned_prompt, &self.options.prompt, value);
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
            .print => |value| try self.print_queue.append(self.allocator, try self.allocator.dupe(u8, value)),
            .reload => |cmd| try self.reloadFromCommand(cmd),
            .execute => |cmd| try self.executeCommand(cmd, false),
            .execute_silent => |cmd| try self.executeCommand(cmd, true),
            .become => |cmd| return try self.becomeCommand(cmd),
            .unbind => |targets| self.setBindingsEnabled(targets, .disable),
            .rebind => |targets| self.setBindingsEnabled(targets, .enable),
            .toggle_bind => |targets| self.setBindingsEnabled(targets, .toggle),
        }
        return null;
    }

    const BindingStateChange = enum { disable, enable, toggle };

    fn setBindingsEnabled(self: *Ui, targets: []const u8, change: BindingStateChange) void {
        var target_it = std.mem.splitScalar(u8, targets, ',');
        while (target_it.next()) |raw_target| {
            const target = std.mem.trim(u8, raw_target, " \t");
            if (target.len == 0) continue;
            for (self.options.bindings.items) |*binding| {
                if (!std.mem.eql(u8, binding.trigger, target)) continue;
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
        try env.put("FZF_MATCH_COUNT", try std.fmt.bufPrint(&match_buf, "{d}", .{self.result_len}));
        try env.put("FZF_SELECT_COUNT", try std.fmt.bufPrint(&select_buf, "{d}", .{self.selected_count}));
        try env.put("FZF_POS", try std.fmt.bufPrint(&pos_buf, "{d}", .{if (self.result_len == 0) @as(usize, 0) else self.focus + 1}));
        const item = self.currentItem();
        if (item.len <= 64 * 1024 and std.mem.indexOfScalar(u8, item, 0) == null) try env.put("FZF_CURRENT_ITEM", item);
        if (self.options.border_label) |value| try env.put("FZF_BORDER_LABEL", value);
        if (self.options.preview.label) |value| try env.put("FZF_PREVIEW_LABEL", value);
        const idle_ms = monotonicMilliseconds(self.io) -| self.last_activity_ms;
        var idle_ms_buf: [32]u8 = undefined;
        var idle_s_buf: [32]u8 = undefined;
        try env.put("FZF_IDLE_TIME_MS", try std.fmt.bufPrint(&idle_ms_buf, "{d}", .{idle_ms}));
        try env.put("FZF_IDLE_TIME", try std.fmt.bufPrint(&idle_s_buf, "{d}", .{idle_ms / 1000}));
        return env;
    }

    fn runTransformCommand(self: *Ui, command: []const u8) ![]u8 {
        const expanded = try self.expandedCommand(command);
        defer self.allocator.free(expanded);
        var env = try self.commandEnvironment();
        defer env.deinit();
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded },
            .environ_map = &env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        const text = std.mem.trimEnd(u8, result.stdout, "\r\n");
        return try self.allocator.dupe(u8, text);
    }

    fn runTransformActions(self: *Ui, command: []const u8) anyerror!?u8 {
        const text = try self.runTransformCommand(command);
        defer self.allocator.free(text);
        if (text.len == 0) return null;
        var actions: std.ArrayList(Binding) = .empty;
        defer actions.deinit(self.allocator);
        try appendBindingActions(self.allocator, &actions, "transform", text);
        for (actions.items) |binding| {
            self.last_action = binding.name;
            if (try self.runAction(binding.action)) |code| return code;
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

    fn expandedCommand(self: *Ui, command: []const u8) ![]u8 {
        const current_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        return expandCommand(
            self.allocator,
            command,
            self.query.items,
            self.candidates,
            self.options,
            current_idx,
            self.selection_order.items,
            self.selected,
        );
    }

    fn replaceCandidates(self: *Ui, new_candidates: CandidateSet, new_index: fuzzy.Index, mark_load: bool) !void {
        var track_key = self.pending_track_key;
        self.pending_track_key = null;
        if (track_key == null and self.trackingActive()) track_key = try self.captureCurrentTrackKey();
        errdefer if (track_key) |key| self.allocator.free(key);

        const new_results = try self.allocator.alloc(usize, new_candidates.display.len);
        errdefer self.allocator.free(new_results);
        const new_extended_ranks = try self.allocator.alloc(ExtendedRank, new_candidates.display.len);
        errdefer self.allocator.free(new_extended_ranks);
        const new_selected = try self.allocator.alloc(bool, new_candidates.display.len);
        errdefer self.allocator.free(new_selected);
        @memset(new_selected, false);

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
        self.allocator.free(self.extended_ranks);
        self.allocator.free(self.selected);
        self.selection_order.deinit(self.allocator);

        self.candidates.* = new_candidates;
        self.index.* = new_index;
        self.results = new_results;
        self.extended_ranks = new_extended_ranks;
        self.selected = new_selected;
        self.selection_order = new_order;
        self.selected_count = self.selection_order.items.len;
        self.result_len = 0;
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
        const expanded = try self.expandedCommand(command);
        defer self.allocator.free(expanded);
        var env = try self.commandEnvironment();
        defer env.deinit();
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded },
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

    fn executeCommand(self: *Ui, command: []const u8, silent: bool) !void {
        const expanded = try self.expandedCommand(command);
        defer self.allocator.free(expanded);
        var env = try self.commandEnvironment();
        defer env.deinit();
        if (silent) {
            const result = try std.process.run(self.allocator, self.io, .{
                .argv = &.{ "/bin/sh", "-c", expanded },
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
            .argv = &.{ "/bin/sh", "-c", expanded },
            .environ_map = &env,
            .stdin = .{ .file = self.terminal.file },
            .stdout = .{ .file = self.terminal.file },
            .stderr = .{ .file = self.terminal.file },
        });
        _ = try child.wait(self.io);
        self.preview_cache_key = null;
    }

    fn becomeCommand(self: *Ui, command: []const u8) !u8 {
        const expanded = try self.expandedCommand(command);
        defer self.allocator.free(expanded);
        var env = try self.commandEnvironment();
        defer env.deinit();
        self.terminal.leave();
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded },
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
            self.move(-3);
            return;
        }
        if (m.button == 65) {
            self.move(3);
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
                if (self.result_len == self.result_cap and self.result_cap < self.candidates.display.len) {
                    self.growResults() catch {};
                }
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

    fn page(self: *Ui, delta: isize) void {
        const rows = @max(@as(usize, 1), self.visibleListRows());
        self.move(delta * @as(isize, @intCast(rows)));
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

    fn selectCurrent(self: *Ui) !void {
        if (!self.options.multi or self.result_len == 0) return;
        const idx = self.results[self.focus];
        if (self.selected[idx]) return;
        if (self.options.multi_max) |max| if (self.selected_count >= max) return;
        self.selected[idx] = true;
        try self.selection_order.append(self.allocator, idx);
        self.selected_count += 1;
    }

    fn deselectCurrent(self: *Ui) void {
        if (!self.options.multi or self.result_len == 0) return;
        const idx = self.results[self.focus];
        if (!self.selected[idx]) return;
        self.selected[idx] = false;
        self.selected_count -= 1;
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

    fn toggleCurrent(self: *Ui) !void {
        if (self.result_len == 0) return;
        const idx = self.results[self.focus];
        if (!self.selected[idx]) {
            if (self.options.multi_max) |max| if (self.selected_count >= max) return;
            self.selected[idx] = true;
            try self.selection_order.append(self.allocator, idx);
            self.selected_count += 1;
        } else {
            self.selected[idx] = false;
            self.selected_count -= 1;
            if (std.mem.indexOfScalar(usize, self.selection_order.items, idx)) |pos| _ = self.selection_order.orderedRemove(pos);
        }
    }

    fn deleteWordBackward(self: *Ui) void {
        if (self.cursor == 0) return;
        var p = self.cursor;
        while (p > 0 and std.ascii.isWhitespace(self.query.items[p - 1])) p -= 1;
        while (p > 0 and !std.ascii.isWhitespace(self.query.items[p - 1])) p -= 1;
        self.query.replaceRange(self.allocator, p, self.cursor - p, &.{}) catch return;
        self.cursor = p;
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
        var frame: Io.Writer.Allocating = .init(self.allocator);
        defer frame.deinit();
        const w = &frame.writer;
        if (self.terminal.inline_mode) {
            var clear_row: usize = 1;
            while (clear_row <= size.rows) : (clear_row += 1) {
                try cursorTo(w, clear_row, 1, true);
                try w.writeAll("\x1b[2K");
            }
        } else {
            try w.writeAll("\x1b[H\x1b[2J");
        }

        if (self.options.border) {
            try drawPaneBorder(w, geom.main, self.terminal.inline_mode, self.options.border_style, self.options.theme.border, self.options.theme.enabled, self.options.bold);
            if (self.options.border_label) |label| try drawBorderLabel(w, geom.main, self.terminal.inline_mode, self.options.border_style, label, self.options.border_label_pos, self.options.theme.border, self.options.theme.enabled, self.options.bold);
        }
        const content = self.contentPane(geom.main);
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
            row = try self.renderList(w, row, content, true);
            if (self.options.footer) |f| try self.renderPlainLine(w, row, content.col, f, content.cols, self.options.theme.footer);
        } else {
            row = try self.renderList(w, row, content, false);
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

        try self.terminal.write(frame.written());
    }

    fn statusText(self: *Ui) ![]u8 {
        if (self.result_len == self.result_cap and self.result_cap < self.candidates.display.len) {
            if (self.options.multi) return try std.fmt.allocPrint(self.allocator, "{d}+/{d} ({d})", .{ self.result_len, self.candidates.display.len, self.selected_count });
            return try std.fmt.allocPrint(self.allocator, "{d}+/{d}", .{ self.result_len, self.candidates.display.len });
        }
        if (self.options.multi) return try std.fmt.allocPrint(self.allocator, "{d}/{d} ({d})", .{ self.result_len, self.candidates.display.len, self.selected_count });
        return try std.fmt.allocPrint(self.allocator, "{d}/{d}", .{ self.result_len, self.candidates.display.len });
    }

    fn renderInfo(self: *Ui, w: anytype, row: usize, col: usize, cols: usize) !void {
        if (self.options.info_style == .hidden or self.options.info_style == .inline_left or self.options.info_style == .inline_right) return;
        const status = try self.statusText();
        defer self.allocator.free(status);
        try writeRoleStyle(w, self.options.theme.info, self.options.theme.enabled, self.options.bold);
        if (self.options.info_style == .right) {
            const offset = if (cols > status.len) cols - status.len else 0;
            try cursorTo(w, row, col + offset, self.terminal.inline_mode);
            try writeTruncated(w, status, cols, false, "");
        } else {
            try cursorTo(w, row, col, self.terminal.inline_mode);
            try writeTruncated(w, status, cols, false, "");
            if (self.options.separator) |sep| {
                if (sep.len != 0 and cols > status.len + 1) {
                    try w.writeAll(" ");
                    var used = status.len + 1;
                    while (used < cols) : (used += 1) try w.writeAll(sep);
                }
            }
        }
        try writeReset(w);
    }

    fn renderPrompt(self: *Ui, w: anytype, row: usize, col: usize, cols: usize) !void {
        try cursorTo(w, row, col, self.terminal.inline_mode);
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
        try cursorTo(w, row, col, self.terminal.inline_mode);
        try writeRoleStyle(w, style, self.options.theme.enabled, self.options.bold);
        try writeTruncated(w, text, cols, false, "");
        try writeReset(w);
    }

    fn renderList(self: *Ui, w: anytype, start_row: usize, content: Pane, top_down: bool) !usize {
        const rows = self.listRows(content.rows);
        var line: usize = 0;
        while (line < rows) : (line += 1) {
            const row = start_row + line;
            if (row >= content.row + content.rows) break;
            try cursorTo(w, row, content.col, self.terminal.inline_mode);
            const logical = if (top_down) self.scroll + line else self.scroll + (rows - 1 - line);
            if (logical >= self.result_len) continue;
            const idx = self.results[logical];
            const focused = logical == self.focus;
            const marked = self.selected[idx];
            try writeRoleStyle(w, if (focused) self.options.theme.current else self.options.theme.normal, self.options.theme.enabled, self.options.bold);
            if (focused) {
                try writeRoleStyleOverlay(w, self.options.theme.pointer, self.options.theme.enabled, self.options.bold);
                try w.writeAll(self.options.pointer);
                try writeRoleStyle(w, self.options.theme.current, self.options.theme.enabled, self.options.bold);
            } else try w.writeAll(" ");
            try w.writeAll(" ");
            if (marked) {
                try writeRoleStyleOverlay(w, self.options.theme.marker, self.options.theme.enabled, self.options.bold);
                try w.writeAll(self.options.marker);
                try writeRoleStyle(w, if (focused) self.options.theme.current else self.options.theme.normal, self.options.theme.enabled, self.options.bold);
            } else try w.writeAll(" ");
            try w.writeAll(" ");
            try writeHighlighted(w, self.candidates.display[idx], self.query.items, if (content.cols > 4) content.cols - 4 else content.cols, self.options.wrap, self.options.ansi, &self.options.theme, focused, self.options.bold);
            try writeReset(w);
        }
        return start_row + rows;
    }

    fn ensurePreview(self: *Ui) !void {
        const cmd_template = self.options.preview.command orelse return;
        if (self.result_len == 0) return;
        const idx = self.results[self.focus];
        const qhash = std.hash.Wyhash.hash(0, self.query.items);
        if (self.preview_cache_key == idx and self.preview_cache_query_hash == qhash) return;
        const expanded = try self.expandedCommand(cmd_template);
        defer self.allocator.free(expanded);
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded },
            .environ_map = self.child_env,
            .stdout_limit = .limited(512 * 1024),
            .stderr_limit = .limited(128 * 1024),
        }) catch {
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (self.preview_text.len != 0) self.allocator.free(self.preview_text);
        self.preview_text = try self.allocator.alloc(u8, result.stdout.len + result.stderr.len);
        @memcpy(self.preview_text[0..result.stdout.len], result.stdout);
        @memcpy(self.preview_text[result.stdout.len..], result.stderr);
        self.preview_cache_key = idx;
        self.preview_cache_query_hash = qhash;
        self.preview_offset = 0;
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
            const line = lines.next() orelse break;
            try cursorTo(w, content.row + row, content.col, self.terminal.inline_mode);
            try writeTruncated(w, line, content.cols, self.options.preview.wrap, "");
        }
    }
};

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
    if (std.ascii.eqlIgnoreCase(name, "dark") or std.ascii.eqlIgnoreCase(name, "base16")) {
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
    const prefix = if (colon) |at| text[at + 1 ..] else " < ";
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
        options.border = true;
        options.border_style = .rounded;
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
    if (init.environ_map.get("NO_COLOR") != null) options.theme.enabled = false;
    if (init.environ_map.get("FZF_DEFAULT_OPTS")) |defaults_text| {
        const default_args = try shellSplitArgs(allocator, defaults_text);
        try parseOptionsInto(allocator, &options, default_args, 0);
    }
    try parseOptionsInto(allocator, &options, args, 1);
    defer options.deinit(allocator);

    if (hasArg(args, "--help") or hasArg(args, "-h")) {
        try Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }
    if (hasArg(args, "--version")) {
        try Io.File.stdout().writeStreamingAll(init.io, "zfuzz 0.2.0\n");
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

    const live_stdin = terminal_opt != null and std.c.isatty(std.posix.STDIN_FILENO) != 1 and !options.sync;
    var stream_input: ?StreamInput = if (live_stdin)
        StreamInput.init(allocator, if (options.read0) 0 else '\n', options.tail, options.header_lines)
    else
        null;
    defer if (stream_input) |*stream| stream.deinit();

    var candidates = if (stream_input) |*stream| blk: {
        _ = try stream.readAvailable();
        const blob = try stream.materializeBlob();
        break :blk try candidatesFromOwnedBlob(allocator, blob, &options);
    } else try readCandidates(allocator, init.io, &options, init.environ_map.get("FZF_DEFAULT_COMMAND"));
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

    var ui = try Ui.init(allocator, init.io, &options, &candidates, &index, terminal, if (stream_input) |*stream| stream else null, server, &child_env);
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
    var have = false;
    for (text) |c| {
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

fn parseOptions(allocator: Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    try parseOptionsInto(allocator, &o, args, 1);
    return o;
}

fn parseOptionsInto(allocator: Allocator, o: *Options, args: []const []const u8, start_index: usize) !void {
    var i: usize = start_index;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "--version") or
            std.mem.eql(u8, a, "--bash") or std.mem.eql(u8, a, "--zsh") or std.mem.eql(u8, a, "--fish")) continue;
        if (std.mem.eql(u8, a, "--sync")) {
            o.*.sync = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--listen")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                o.*.listen_addr = args[i];
            } else {
                o.*.listen_addr = "";
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--no-listen")) {
            o.*.listen_addr = null;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--listen=")) {
            o.*.listen_addr = a[9..];
            continue;
        }
        if (std.mem.eql(u8, a, "--listen-unsafe")) {
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
            try o.*.walker_roots.append(allocator, a[14..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--walker-root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try o.*.walker_roots.append(allocator, args[i]);
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
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--multi")) {
            o.*.multi = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--multi=")) {
            o.*.multi = true;
            o.*.multi_max = try std.fmt.parseInt(usize, a[8..], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--read0")) {
            o.*.read0 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--print0")) {
            o.*.print0 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--ansi")) {
            o.*.ansi = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--cycle")) {
            o.*.cycle = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--wrap")) {
            o.*.wrap = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--select-1") or std.mem.eql(u8, a, "-1")) {
            o.*.select_1 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--exit-0") or std.mem.eql(u8, a, "-0")) {
            o.*.exit_0 = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--print-query")) {
            o.*.print_query = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-sort") or std.mem.eql(u8, a, "+s")) {
            o.*.no_sort = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--disabled")) {
            o.*.disabled = true;
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
        if (std.mem.eql(u8, a, "--no-color")) {
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
        if (std.mem.eql(u8, a, "--no-mouse")) {
            o.*.mouse = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--border")) {
            o.*.border = true;
            if (o.*.border_style == .none) o.*.border_style = .rounded;
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
        if (std.mem.eql(u8, a, "--layout=default")) {
            o.*.layout = .default;
            continue;
        }

        if (std.mem.startsWith(u8, a, "--query=")) {
            o.*.query = a[8..];
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
        if (std.mem.startsWith(u8, a, "--pointer=")) {
            o.*.pointer = a[10..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--marker=")) {
            o.*.marker = a[9..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--header=")) {
            o.*.header = a[9..];
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
        if (std.mem.startsWith(u8, a, "--preview-window=")) {
            parsePreviewWindow(&o.*.preview, a[17..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--preview-border")) {
            o.*.preview.border_style = .rounded;
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
            var it = std.mem.splitScalar(u8, a[9..], ',');
            while (it.next()) |k| if (k.len != 0) try o.*.expect.append(allocator, k);
            continue;
        }
        if (std.mem.eql(u8, a, "--expect")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |k| if (k.len != 0) try o.*.expect.append(allocator, k);
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
        return error.UnknownOption;
    }
    return;
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
    if (!std.mem.startsWith(u8, trigger, "every(") or trigger.len < 8 or trigger[trigger.len - 1] != ')') return null;
    const secs = std.fmt.parseFloat(f64, trigger[6 .. trigger.len - 1]) catch return null;
    if (!std.math.isFinite(secs) or secs <= 0) return null;
    const ms_f = secs * 1000.0;
    if (ms_f < 1.0 or ms_f >= 2147483648.0) return null;
    return @intFromFloat(ms_f);
}

fn parseBindings(allocator: Allocator, out: *std.ArrayList(Binding), spec: []const u8) !void {
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) : (i += 1) {
        const at_end = i == spec.len;
        const c: u8 = if (at_end) ',' else spec[i];
        if (!at_end) {
            if (c == '(') depth += 1 else if (c == ')' and depth != 0) depth -= 1;
        }
        if (c != ',' or depth != 0) continue;
        const part = std.mem.trim(u8, spec[start..i], " \t");
        start = i + 1;
        if (part.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidBinding;
        const trigger = std.mem.trim(u8, part[0..colon], " \t");
        if (std.mem.startsWith(u8, trigger, "every(") and everyIntervalMilliseconds(trigger) == null) return error.InvalidEveryEvent;
        const action_text = std.mem.trim(u8, part[colon + 1 ..], " \t");
        try appendBindingActions(allocator, out, trigger, action_text);
    }
}

fn appendBindingActions(allocator: Allocator, out: *std.ArrayList(Binding), trigger: []const u8, text: []const u8) !void {
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const c: u8 = if (at_end) '+' else text[i];
        if (!at_end) {
            if (c == '(') depth += 1 else if (c == ')' and depth != 0) depth -= 1;
        }
        if (c != '+' or depth != 0) continue;
        const action_text = std.mem.trim(u8, text[start..i], " \t");
        start = i + 1;
        if (action_text.len == 0) continue;
        try out.append(allocator, .{ .trigger = trigger, .name = actionName(action_text), .action = try parseAction(action_text) });
    }
}

fn actionName(text: []const u8) []const u8 {
    const paren = std.mem.indexOfScalar(u8, text, '(');
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const end = if (paren) |p| if (colon) |c| @min(p, c) else p else if (colon) |c| c else text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}

fn validateActionSequence(text: []const u8) bool {
    var start: usize = 0;
    var depth: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const c: u8 = if (at_end) '+' else text[i];
        if (!at_end) {
            if (c == '(') depth += 1 else if (c == ')' and depth != 0) depth -= 1;
        }
        if (c != '+' or depth != 0) continue;
        const action_text = std.mem.trim(u8, text[start..i], " \t");
        start = i + 1;
        if (action_text.len == 0) continue;
        _ = parseAction(action_text) catch return false;
        count += 1;
    }
    return count != 0 and depth == 0;
}

fn parseAction(s: []const u8) !Action {
    if (std.mem.eql(u8, s, "up")) return .up;
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "page-up")) return .page_up;
    if (std.mem.eql(u8, s, "page-down")) return .page_down;
    if (std.mem.eql(u8, s, "backward-word")) return .backward_word;
    if (std.mem.eql(u8, s, "forward-word")) return .forward_word;
    if (std.mem.eql(u8, s, "backward-kill-word")) return .backward_kill_word;
    if (std.mem.eql(u8, s, "kill-word")) return .kill_word;
    if (std.mem.eql(u8, s, "first")) return .first;
    if (std.mem.eql(u8, s, "last")) return .last;
    if (std.mem.eql(u8, s, "toggle")) return .toggle;
    if (std.mem.eql(u8, s, "select")) return .select;
    if (std.mem.eql(u8, s, "deselect")) return .deselect;
    if (std.mem.eql(u8, s, "toggle-up")) return .toggle_up;
    if (std.mem.eql(u8, s, "select-all")) return .select_all;
    if (std.mem.eql(u8, s, "deselect-all")) return .deselect_all;
    if (std.mem.eql(u8, s, "clear-query")) return .clear_query;
    if (std.mem.eql(u8, s, "accept")) return .accept;
    if (std.mem.eql(u8, s, "abort")) return .abort;
    if (std.mem.eql(u8, s, "toggle-preview")) return .toggle_preview;
    if (std.mem.eql(u8, s, "show-preview")) return .show_preview;
    if (std.mem.eql(u8, s, "hide-preview")) return .hide_preview;
    if (std.mem.eql(u8, s, "refresh-preview")) return .refresh_preview;
    if (std.mem.eql(u8, s, "toggle-preview-wrap")) return .toggle_preview_wrap;
    if (std.mem.eql(u8, s, "toggle-wrap")) return .toggle_wrap;
    if (std.mem.eql(u8, s, "toggle-input")) return .toggle_input;
    if (std.mem.eql(u8, s, "show-input")) return .show_input;
    if (std.mem.eql(u8, s, "hide-input")) return .hide_input;
    if (std.mem.eql(u8, s, "toggle-header")) return .toggle_header;
    if (std.mem.eql(u8, s, "show-header")) return .show_header;
    if (std.mem.eql(u8, s, "hide-header")) return .hide_header;
    if (std.mem.eql(u8, s, "wait")) return .wait;
    if (std.mem.eql(u8, s, "preview-top")) return .preview_top;
    if (std.mem.eql(u8, s, "preview-bottom")) return .preview_bottom;
    if (std.mem.eql(u8, s, "preview-up")) return .preview_up;
    if (std.mem.eql(u8, s, "preview-down")) return .preview_down;
    if (std.mem.eql(u8, s, "preview-page-up")) return .preview_page_up;
    if (std.mem.eql(u8, s, "preview-page-down")) return .preview_page_down;
    if (std.mem.eql(u8, s, "preview-half-page-up")) return .preview_half_page_up;
    if (std.mem.eql(u8, s, "preview-half-page-down")) return .preview_half_page_down;
    if (std.mem.eql(u8, s, "up-selected") or std.mem.eql(u8, s, "prev-selected")) return .prev_selected;
    if (std.mem.eql(u8, s, "down-selected") or std.mem.eql(u8, s, "next-selected")) return .next_selected;
    if (std.mem.eql(u8, s, "toggle-sort")) return .toggle_sort;
    if (std.mem.eql(u8, s, "enable-search")) return .enable_search;
    if (std.mem.eql(u8, s, "disable-search")) return .disable_search;
    if (std.mem.eql(u8, s, "toggle-search")) return .toggle_search;
    if (std.mem.eql(u8, s, "toggle-track")) return .toggle_track;
    if (std.mem.eql(u8, s, "track") or std.mem.eql(u8, s, "track-current")) return .track_current;
    if (std.mem.eql(u8, s, "untrack-current")) return .untrack_current;
    if (std.mem.eql(u8, s, "toggle-track-current")) return .toggle_track_current;
    if (std.mem.eql(u8, s, "prev-history") or std.mem.eql(u8, s, "previous-history")) return .prev_history;
    if (std.mem.eql(u8, s, "next-history")) return .next_history;
    if (commandAction(s, "change-query")) |value| return .{ .change_query = value };
    if (commandAction(s, "change-prompt")) |value| return .{ .change_prompt = value };
    if (commandAction(s, "change-header")) |value| return .{ .change_header = value };
    if (commandAction(s, "change-footer")) |value| return .{ .change_footer = value };
    if (commandAction(s, "change-preview")) |value| return .{ .change_preview = value };
    if (commandAction(s, "transform-query")) |cmd| return .{ .transform_query = cmd };
    if (commandAction(s, "transform-prompt")) |cmd| return .{ .transform_prompt = cmd };
    if (commandAction(s, "transform-header")) |cmd| return .{ .transform_header = cmd };
    if (commandAction(s, "transform-footer")) |cmd| return .{ .transform_footer = cmd };
    if (commandAction(s, "transform-preview")) |cmd| return .{ .transform_preview = cmd };
    if (commandAction(s, "transform")) |cmd| return .{ .transform = cmd };
    if (commandAction(s, "print")) |value| return .{ .print = value };
    if (commandAction(s, "reload")) |cmd| return .{ .reload = cmd };
    if (commandAction(s, "execute-silent")) |cmd| return .{ .execute_silent = cmd };
    if (commandAction(s, "execute")) |cmd| return .{ .execute = cmd };
    if (commandAction(s, "become")) |cmd| return .{ .become = cmd };
    if (commandAction(s, "unbind")) |targets| return .{ .unbind = targets };
    if (commandAction(s, "rebind")) |targets| return .{ .rebind = targets };
    if (commandAction(s, "toggle-bind")) |targets| return .{ .toggle_bind = targets };
    return error.UnsupportedBindingAction;
}

fn commandAction(s: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, name)) return null;
    const rest = s[name.len..];
    if (rest.len >= 2 and rest[0] == '(' and rest[rest.len - 1] == ')') return rest[1 .. rest.len - 1];
    if (rest.len >= 2 and rest[0] == ':') return rest[1..];
    return null;
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
    if (spec.len == 0) return out;
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "file")) out.file = true else if (std.mem.eql(u8, part, "dir")) out.dir = true else if (std.mem.eql(u8, part, "follow")) out.follow = true else if (std.mem.eql(u8, part, "hidden")) out.hidden = true else return error.InvalidWalkerOption;
    }
    return out;
}

fn appendWalkerSkipExpr(allocator: Allocator, argv: *std.ArrayList([]const u8), options: *const Options) !bool {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = std.mem.splitScalar(u8, options.walker_skip, ',');
    while (it.next()) |name| if (name.len != 0) try names.append(allocator, name);
    const skip_hidden = !options.walker.hidden;
    if (names.items.len == 0 and !skip_hidden) return false;

    try argv.appendSlice(allocator, &.{ "(", "-type", "d", "(" });
    var first = true;
    for (names.items) |name| {
        if (!first) try argv.append(allocator, "-o");
        try argv.appendSlice(allocator, &.{ "-name", name });
        first = false;
    }
    if (skip_hidden) {
        if (!first) try argv.append(allocator, "-o");
        try argv.appendSlice(allocator, &.{ "-name", ".*" });
    }
    try argv.appendSlice(allocator, &.{ ")", ")", "-prune", "-o" });
    return true;
}

fn runWalker(allocator: Allocator, io: Io, options: *const Options) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "/usr/bin/find");
    if (options.walker.follow) try argv.append(allocator, "-L");
    if (options.walker_roots.items.len == 0) try argv.append(allocator, ".") else try argv.appendSlice(allocator, options.walker_roots.items);
    try argv.appendSlice(allocator, &.{ "-mindepth", "1" });
    _ = try appendWalkerSkipExpr(allocator, &argv, options);

    if (options.walker.file and options.walker.dir) {
        try argv.appendSlice(allocator, &.{ "(", "-type", "f", "-o", "-type", "d", ")" });
    } else if (options.walker.file) {
        try argv.appendSlice(allocator, &.{ "-type", "f" });
    } else if (options.walker.dir) {
        try argv.appendSlice(allocator, &.{ "-type", "d" });
    } else {
        return try allocator.alloc(u8, 0);
    }
    try argv.append(allocator, if (options.read0) "-print0" else "-print");

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.WalkerFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.WalkerFailed;
        },
    }
    return result.stdout;
}

fn readCandidates(allocator: Allocator, io: Io, options: *const Options, default_command: ?[]const u8) !CandidateSet {
    if (std.c.isatty(std.posix.STDIN_FILENO) == 1) {
        const blob = if (default_command) |command| blk: {
            if (command.len == 0) break :blk try runWalker(allocator, io, options);
            const result = try std.process.run(allocator, io, .{
                .argv = &.{ "/bin/sh", "-c", command },
                .stdout_limit = .limited(256 * 1024 * 1024),
                .stderr_limit = .limited(4 * 1024 * 1024),
            });
            allocator.free(result.stderr);
            break :blk result.stdout;
        } else try runWalker(allocator, io, options);
        return candidatesFromOwnedBlob(allocator, blob, options);
    }
    if (options.tail) |tail| {
        const blob = try readTailBlobStdin(allocator, tail, options.header_lines, if (options.read0) 0 else '\n');
        return candidatesFromOwnedBlob(allocator, blob, options);
    }
    var buffer: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    const blob = try reader.interface.allocRemaining(allocator, .unlimited);
    return candidatesFromOwnedBlob(allocator, blob, options);
}

const TailRing = struct {
    allocator: Allocator,
    slots: []?[]u8,
    total: usize = 0,

    fn push(self: *TailRing, record: []const u8) !void {
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

fn readTailBlobStdin(allocator: Allocator, tail: usize, header_lines: usize, delim: u8) ![]u8 {
    const slots = try allocator.alloc(?[]u8, tail);
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
    var saw_any = false;
    var last_was_delim = false;
    while (true) {
        const n = std.c.read(std.posix.STDIN_FILENO, &buffer, buffer.len);
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.posix.E.INTR)) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        const count: usize = @intCast(n);
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

    const kept = @min(ring.total, tail);
    const first = if (ring.total > tail) ring.total % tail else 0;
    var bytes: usize = headers.items.len + kept;
    for (headers.items) |line| bytes += line.len;
    for (0..kept) |i| bytes += ring.slots[(first + i) % tail].?.len;
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
        const record = ring.slots[(first + i) % tail].?;
        @memcpy(blob[at .. at + record.len], record);
        at += record.len;
        blob[at] = delim;
        at += 1;
    }
    return blob;
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
    const keep_count = if (options.tail) |tail| @min(body_count, tail) else body_count;
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
            display[idx] = try transformFields(allocator, line, options.delimiter, spec, idx);
            built += 1;
        }
        owned_display = true;
    }

    const base_search = if (options.with_nth != null) display else output;
    if (options.nth == null and !options.ansi) {
        return .{ .blob = blob, .header = header, .output = output, .display = display, .search = base_search, .owned_display = owned_display, .owned_search = false };
    }

    const search = try allocator.alloc([]const u8, count);
    errdefer allocator.free(search);
    var built_search: usize = 0;
    errdefer for (search[0..built_search]) |line| allocator.free(line);
    for (base_search, 0..) |line, idx| {
        var transformed: ?[]u8 = null;
        const scoped: []const u8 = if (options.nth) |spec| blk: {
            const tmp = try transformFields(allocator, line, options.delimiter, spec, idx);
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
    return .{ .blob = blob, .header = header, .output = output, .display = display, .search = search, .owned_display = owned_display, .owned_search = true };
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

fn tiebreakValue(kind: TieBreak, line: []const u8, score: CandidateScore) usize {
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

    if (parsed.direct) |direct| {
        if (!termCaseSensitive(options.case_mode, direct) and options.tiebreak_count == 1 and options.tiebreaks[0] == .length) {
            return try index.search(direct, out[0..cap]);
        }
    }

    // fzf does not sort inverse-only extended queries. --no-sort likewise
    // preserves input order after filtering.
    if (options.no_sort or !parsed.sortable) {
        var write: usize = 0;
        for (candidates.search, 0..) |line, idx| {
            if (scoreParsedCandidate(index, parsed, line, idx, options.case_mode) == null) continue;
            out[write] = idx;
            write += 1;
            if (write == cap) break;
        }
        return out[0..write];
    }

    var source: []usize = out;
    if (parsed.driver) |driver| {
        // A driver is chosen only from a mandatory singleton fuzzy clause, so
        // folded Index.search is a safe prefilter even for case-sensitive terms.
        source = try index.search(driver, out);
    } else {
        for (out, 0..) |*slot, i| slot.* = i;
    }

    var rank_len: usize = 0;
    for (source) |idx| {
        const score = scoreParsedCandidate(index, parsed, candidates.search[idx], idx, options.case_mode) orelse continue;
        rank_scratch[rank_len] = .{ .entry = idx, .score = score };
        rank_len += 1;
    }
    std.mem.sort(ExtendedRank, rank_scratch[0..rank_len], RankContext{ .candidates = candidates, .options = options }, betterExtended);

    const take = @min(cap, rank_len);
    for (rank_scratch[0..take], 0..) |rank, i| out[i] = rank.entry;
    return out[0..take];
}

fn scoreParsedCandidate(index: *fuzzy.Index, parsed: ParsedQuery, line: []const u8, entry_index: usize, mode: CaseMode) ?CandidateScore {
    if (parsed.terms.len == 0) return .{};
    var total: CandidateScore = .{};
    var clause: usize = 0;
    while (clause < parsed.clause_count) : (clause += 1) {
        var matched = false;
        var contribution: ?fuzzy_engine.CliMatch = null;
        for (parsed.terms) |term| {
            if (term.clause != clause) continue;
            const term_match = scoreTerm(index, term, line, entry_index, mode);
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

fn scoreTerm(index: *fuzzy.Index, term: QueryTerm, line: []const u8, entry_index: usize, mode: CaseMode) ?fuzzy_engine.CliMatch {
    const sensitive = termCaseSensitive(mode, term.text);
    return switch (term.kind) {
        .fuzzy => fuzzy_engine.matchFuzzyForCli(index, term.text, line, entry_index, sensitive),
        .exact => fuzzy_engine.scoreExactForCli(index, term.text, line, entry_index, sensitive, false),
        .boundary_exact => fuzzy_engine.scoreExactForCli(index, term.text, line, entry_index, sensitive, true),
        .prefix => fuzzy_engine.scorePrefixForCli(index, term.text, line, entry_index, sensitive),
        .suffix => fuzzy_engine.scoreSuffixForCli(index, term.text, line, entry_index, sensitive),
        .equal => fuzzy_engine.scoreEqualForCli(index, term.text, line, entry_index, sensitive),
    };
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
        .smart => blk: {
            for (text) |c| if (c >= 'A' and c <= 'Z') break :blk true;
            break :blk false;
        },
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
    const out = try allocator.alloc(usize, candidates.display.len);
    defer allocator.free(out);
    const ranks = try allocator.alloc(ExtendedRank, candidates.display.len);
    defer allocator.free(ranks);
    const found = try searchCandidates(index, candidates, options, query, out, ranks, out.len);
    if (options.no_sort) std.mem.sort(usize, found, {}, comptime std.sort.asc(usize));
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
    if (options.exit_0 and found.len == 0) std.process.exit(1);
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

fn readKey(t: *Terminal) !Key {
    const b = t.readByte() catch |err| switch (err) {
        error.Timeout => return .unknown,
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

fn wordBoundaryBackward(s: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0 and std.ascii.isWhitespace(s[p - 1])) p -= 1;
    while (p > 0 and !std.ascii.isWhitespace(s[p - 1])) p -= 1;
    return p;
}

fn wordBoundaryForward(s: []const u8, pos: usize) usize {
    var p = pos;
    while (p < s.len and std.ascii.isWhitespace(s[p])) p += 1;
    while (p < s.len and !std.ascii.isWhitespace(s[p])) p += 1;
    return p;
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

fn writeHighlighted(w: anytype, text: []const u8, query: []const u8, cols: usize, wrap: bool, ansi: bool, theme: *const Theme, focused: bool, bold_enabled: bool) !void {
    var qi: usize = 0;
    var printed: usize = 0;
    var i: usize = 0;
    const base = if (focused) theme.current else theme.normal;
    const highlight = if (focused) theme.highlight_current else theme.highlight;
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
        if (!wrap and printed >= cols) break;
        const c = text[i];
        const match = qi < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[qi]);
        if (match) {
            try writeRoleStyleOverlay(w, highlight, theme.enabled, bold_enabled);
            try w.writeByte(c);
            try writeRoleStyle(w, base, theme.enabled, bold_enabled);
            qi += 1;
        } else try w.writeByte(c);
        printed += 1;
        i += 1;
    }
    if (!wrap and i < text.len and cols >= 1) try w.writeAll("…");
}

fn keyMatchesName(key: Key, name: []const u8) bool {
    return switch (key) {
        .up => std.mem.eql(u8, name, "up"),
        .down => std.mem.eql(u8, name, "down"),
        .left => std.mem.eql(u8, name, "left"),
        .right => std.mem.eql(u8, name, "right"),
        .home => std.mem.eql(u8, name, "home"),
        .end => std.mem.eql(u8, name, "end"),
        .page_up => std.mem.eql(u8, name, "page-up") or std.mem.eql(u8, name, "pgup"),
        .page_down => std.mem.eql(u8, name, "page-down") or std.mem.eql(u8, name, "pgdn"),
        .delete => std.mem.eql(u8, name, "delete"),
        .shift_tab => std.mem.eql(u8, name, "shift-tab") or std.mem.eql(u8, name, "btab"),
        .alt_byte => |b| name.len == 5 and std.mem.startsWith(u8, name, "alt-") and std.ascii.toLower(name[4]) == std.ascii.toLower(b),
        .byte => |b| blk: {
            if ((b == 13 or b == 10) and std.mem.eql(u8, name, "enter")) break :blk true;
            if (b == 9 and std.mem.eql(u8, name, "tab")) break :blk true;
            if (b == 27 and std.mem.eql(u8, name, "esc")) break :blk true;
            if ((b == 127 or b == 8) and std.mem.eql(u8, name, "backspace")) break :blk true;
            if (b >= 1 and b <= 26 and name.len == 6 and std.mem.startsWith(u8, name, "ctrl-"))
                break :blk std.ascii.toLower(name[5]) == ('a' + b - 1);
            break :blk name.len == 1 and std.ascii.toLower(name[0]) == std.ascii.toLower(b);
        },
        else => false,
    };
}

fn writeTruncated(w: anytype, text: []const u8, cols: usize, wrap: bool, prefix: []const u8) !void {
    try w.writeAll(prefix);
    if (wrap or text.len <= cols) return w.writeAll(text);
    if (cols == 0) return;
    const end = @min(text.len, if (cols > 1) cols - 1 else cols);
    try w.writeAll(text[0..end]);
    if (cols > 1) try w.writeAll("…");
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
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < template.len) {
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
        if (std.mem.eql(u8, expr, "q")) {
            try appendShellQuoted(allocator, &out, query);
        } else if (std.mem.eql(u8, expr, "")) {
            if (current_idx) |idx| try appendShellQuoted(allocator, &out, candidates.output[idx]);
        } else if (std.mem.eql(u8, expr, "n")) {
            if (current_idx) |idx| try appendDecimal(allocator, &out, idx);
        } else if (expr.len != 0 and expr[0] == '+') {
            try appendSelectedPlaceholder(allocator, &out, expr[1..], candidates, options, current_idx, selection_order, selected);
        } else if (current_idx) |idx| {
            const transformed = try transformFields(allocator, candidates.output[idx], options.delimiter, expr, idx);
            defer allocator.free(transformed);
            try appendShellQuoted(allocator, &out, transformed);
        }
        i = close + 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn appendSelectedPlaceholder(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    expr: []const u8,
    candidates: *const CandidateSet,
    options: *const Options,
    current_idx: ?usize,
    selection_order: []const usize,
    selected: []const bool,
) !void {
    var wrote = false;
    for (selection_order) |idx| {
        if (idx >= selected.len or !selected[idx]) continue;
        if (wrote) try out.append(allocator, ' ');
        if (expr.len == 0) {
            try appendShellQuoted(allocator, out, candidates.output[idx]);
        } else if (std.mem.eql(u8, expr, "n")) {
            try appendDecimal(allocator, out, idx);
        } else {
            const transformed = try transformFields(allocator, candidates.output[idx], options.delimiter, expr, idx);
            defer allocator.free(transformed);
            try appendShellQuoted(allocator, out, transformed);
        }
        wrote = true;
    }
    if (wrote) return;
    if (current_idx) |idx| {
        if (expr.len == 0) try appendShellQuoted(allocator, out, candidates.output[idx]) else if (std.mem.eql(u8, expr, "n")) {
            try appendDecimal(allocator, out, idx);
        } else {
            const transformed = try transformFields(allocator, candidates.output[idx], options.delimiter, expr, idx);
            defer allocator.free(transformed);
            try appendShellQuoted(allocator, out, transformed);
        }
    }
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
    \\  -e, --exact              exact-match mode; quote prefix flips to fuzzy
    \\  -i, --ignore-case        force case-insensitive matching
    \\  +i, --no-ignore-case     force case-sensitive matching
    \\      --smart-case         smart-case matching (default)
    \\  +x, --no-extended        disable extended query grammar
    \\  -q, --query=STR          start with query
    \\  -f, --filter=STR         non-interactive filter mode
    \\  -1, --select-1           accept when there is exactly one match
    \\  -0, --exit-0             exit immediately when there is no match
    \\      --no-sort            preserve input order after filtering
    \\      --tiebreak=CRI       score tie-breaks: length/chunk/pathname/begin/end/index
    \\      --tail=N             keep only the last N input items in memory
    \\      --track              keep current item focused across result updates
    \\      --id-nth=EXPR        identity fields for tracking/reload selection
    \\      --history=FILE       load and persist query history
    \\      --history-size=N     cap persisted history entries (default 1000)
    \\  -d, --delimiter=STR      literal field delimiter
    \\  -n, --nth=EXPR           limit searchable fields
    \\      --with-nth=EXPR      transform displayed fields
    \\      --accept-nth=EXPR    transform accepted output
    \\      --disabled           do not filter; useful with reload bindings
    \\
    \\Selection and I/O
    \\  -m, --multi[=MAX]        multi-select; Tab / Shift-Tab toggle
    \\      --read0              NUL-delimited input
    \\      --print0             NUL-delimited output
    \\      --print-query        print query before selection
    \\      --expect=KEYS        print accepted key field
    \\      --bind=SPEC          key/event actions: reload/execute/become/toggle...
    \\      --ansi               ignore ANSI CSI sequences while matching
    \\      --tac                reverse input order
    \\
    \\UI
    \\      --reverse            top-down layout
    \\      --height=N%          constrain rendered height
    \\      --cycle              cycle list navigation
    \\      --wrap               wrap long item display
    \\      --prompt=STR         prompt string
    \\      --pointer=STR        current-item pointer
    \\      --marker=STR         selected-item marker
    \\      --header=STR         header text
    \\      --header-lines=N     treat first N input lines as non-selectable header
    \\      --header-first       print header before prompt in reverse layout
    \\      --footer=STR         footer text
    \\      --no-border          disable border reservation
    \\      --no-mouse           disable xterm mouse tracking
    \\
    \\Preview
    \\      --preview=COMMAND    preview focused item; {} and {q} placeholders
    \\      --preview-window=OPT right/left/up/down, SIZE%, hidden, wrap/nowrap
    \\
    \\Keys
    \\  Enter accept, Esc/Ctrl-C abort, arrows/Ctrl-J/Ctrl-K move,
    \\  Ctrl-P/N history when --history is active, Tab toggle,
    \\  Ctrl-A/E line edges, Ctrl-U clear, Ctrl-W erase word.
;

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

    const dirs = try parseWalkerOptions("dir,follow");
    try std.testing.expect(!dirs.file);
    try std.testing.expect(dirs.dir);
    try std.testing.expect(dirs.follow);
    try std.testing.expect(!dirs.hidden);
    try std.testing.expectError(error.InvalidWalkerOption, parseWalkerOptions("file,bogus"));
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

test "header lines remain outside bounded tail" {
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
    try parseOptionsInto(a, &options, &args, 1);
    try std.testing.expectEqual(@as(u8, 40), options.height_percent);
    try std.testing.expect(options.border);
    try std.testing.expect(options.sync);
    const reset = [_][]const u8{ "zfuzz", "--no-height", "--no-border" };
    try parseOptionsInto(a, &options, &reset, 1);
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
    const got = try expandCommand(a, "echo {n} {1} {+} {+2} {q}", "x y", &candidates, &options, 0, &order, &selected);
    defer a.free(got);
    try std.testing.expectEqualStrings("echo 0 'one' 'three,four' 'one,two' 'four' 'two' 'x y'", got);
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
}

test "stateful binding actions parse" {
    try std.testing.expect((try parseAction("toggle-sort")) == .toggle_sort);
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
    const printed = try parseAction("print(ctrl-y)");
    try std.testing.expectEqualStrings("ctrl-y", printed.print);
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

test "word boundaries follow whitespace-separated editing" {
    try std.testing.expectEqual(@as(usize, 4), wordBoundaryBackward("foo bar baz", 7));
    try std.testing.expectEqual(@as(usize, 7), wordBoundaryForward("foo bar baz", 4));
}

test "every event interval parsing" {
    try std.testing.expectEqual(@as(?u64, 200), everyIntervalMilliseconds("every(0.2)"));
    try std.testing.expectEqual(@as(?u64, 2000), everyIntervalMilliseconds("every(2)"));
    try std.testing.expect(everyIntervalMilliseconds("every(0)") == null);
    try std.testing.expect(everyIntervalMilliseconds("every(-1)") == null);
    try std.testing.expect(everyIntervalMilliseconds("every(abc)") == null);
    try std.testing.expect(everyIntervalMilliseconds("every(2147484)") == null);
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

    const args_port = [_][]const u8{ "zfuzz", "--listen", "6266", "--listen-unsafe" };
    var with_port = try parseOptions(a, &args_port);
    defer with_port.deinit(a);
    try std.testing.expectEqualStrings("6266", with_port.listen_addr.?);
    try std.testing.expect(with_port.listen_unsafe);

    const args_ephemeral = [_][]const u8{ "zfuzz", "--listen", "--height=20%" };
    var ephemeral = try parseOptions(a, &args_ephemeral);
    defer ephemeral.deinit(a);
    try std.testing.expectEqualStrings("", ephemeral.listen_addr.?);

    const args_disabled = [_][]const u8{ "zfuzz", "--listen=6267", "--no-listen" };
    var disabled = try parseOptions(a, &args_disabled);
    defer disabled.deinit(a);
    try std.testing.expect(disabled.listen_addr == null);

    try std.testing.expect(validateActionSequence("change-query(foo)+down"));
    try std.testing.expect(validateActionSequence("execute-silent(true)"));
    try std.testing.expect(!validateActionSequence("not-a-real-action"));
}
