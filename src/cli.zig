const std = @import("std");
const fuzzy = @import("fuzzy");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const esc = "\x1b[";

const Layout = enum { default, reverse };
const CaseMode = enum { smart, ignore, respect };
const PreviewPosition = enum { right, left, up, down };

const PreviewOptions = struct {
    command: ?[]const u8 = null,
    position: PreviewPosition = .right,
    percent: u8 = 50,
    hidden: bool = false,
    wrap: bool = true,
};

const Action = union(enum) {
    up,
    down,
    page_up,
    page_down,
    first,
    last,
    toggle,
    toggle_up,
    select_all,
    deselect_all,
    clear_query,
    accept,
    abort,
    toggle_preview,
    refresh_preview,
    toggle_sort,
    enable_search,
    disable_search,
    toggle_search,
    change_query: []const u8,
    change_prompt: []const u8,
    change_header: []const u8,
    change_footer: []const u8,
    change_preview: []const u8,
    reload: []const u8,
    execute: []const u8,
    execute_silent: []const u8,
    become: []const u8,
};

const Binding = struct {
    trigger: []const u8,
    action: Action,
};

const Options = struct {
    query: []const u8 = "",
    filter: ?[]const u8 = null,
    prompt: []const u8 = "> ",
    pointer: []const u8 = ">",
    marker: []const u8 = ">",
    header: ?[]const u8 = null,
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
    disabled: bool = false,
    extended: bool = true,
    exact: bool = false,
    case_mode: CaseMode = .smart,
    tac: bool = false,
    mouse: bool = true,
    border: bool = true,
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
    }
};

const CandidateSet = struct {
    blob: []u8,
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
        allocator.free(self.output);
        allocator.free(self.blob);
    }
};

const Terminal = struct {
    file: Io.File,
    original: std.posix.termios,
    active: bool = false,
    mouse: bool,

    fn open(io: Io, mouse: bool) !Terminal {
        var file = try Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        errdefer file.close(io);
        const original = try std.posix.tcgetattr(file.handle);
        return .{ .file = file, .original = original, .mouse = mouse };
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
        try self.write("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        if (self.mouse) try self.write("\x1b[?1000h\x1b[?1006h");
    }

    fn leave(self: *Terminal) void {
        if (!self.active) return;
        if (self.mouse) self.write("\x1b[?1000l\x1b[?1006l") catch {};
        self.write("\x1b[?25h\x1b[?1049l") catch {};
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

    fn size(self: *Terminal) struct { rows: usize, cols: usize } {
        var ws: std.posix.winsize = undefined;
        const rc = std.c.ioctl(self.file.handle, std.c.T.IOCGWINSZ, &ws);
        if (rc != 0 or ws.row == 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
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

const Ui = struct {
    allocator: Allocator,
    io: Io,
    options: *Options,
    candidates: *CandidateSet,
    index: *fuzzy.Index,
    terminal: *Terminal,
    query: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    results: []usize,
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
    accepted_key: ?[]const u8 = null,
    change_event_pending: bool = false,
    load_event_pending: bool = false,
    result_event_pending: bool = false,
    focus_event_pending: bool = false,

    fn init(
        allocator: Allocator,
        io: Io,
        options: *Options,
        candidates: *CandidateSet,
        index: *fuzzy.Index,
        terminal: *Terminal,
    ) !Ui {
        var query: std.ArrayList(u8) = .empty;
        try query.appendSlice(allocator, options.query);
        const results = try allocator.alloc(usize, candidates.display.len);
        errdefer allocator.free(results);
        const selected = try allocator.alloc(bool, candidates.display.len);
        @memset(selected, false);
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .candidates = candidates,
            .index = index,
            .terminal = terminal,
            .query = query,
            .cursor = options.query.len,
            .results = results,
            .selected = selected,
        };
    }

    fn deinit(self: *Ui) void {
        self.query.deinit(self.allocator);
        self.allocator.free(self.results);
        self.allocator.free(self.selected);
        self.selection_order.deinit(self.allocator);
        if (self.preview_text.len != 0) self.allocator.free(self.preview_text);
    }

    fn run(self: *Ui) !u8 {
        try self.refreshSearch(true);
        if (self.options.select_1 and self.result_len == 1) {
            try self.emitSelection(null);
            return 0;
        }
        if (self.options.exit_0 and self.result_len == 0) return 1;

        try self.terminal.enter();
        defer self.terminal.leave();

        if (try self.fireEvent("start")) |code| return code;
        self.load_event_pending = true;
        while (true) {
            if (self.load_event_pending) {
                self.load_event_pending = false;
                if (try self.fireEvent("load")) |code| return code;
            }
            if (self.change_event_pending) {
                self.change_event_pending = false;
                if (try self.fireEvent("change")) |code| return code;
            }
            if (self.dirty_search) try self.refreshSearch(false);
            if (self.result_event_pending) {
                self.result_event_pending = false;
                if (try self.fireEvent("result")) |code| return code;
            }
            if (self.focus_event_pending) {
                self.focus_event_pending = false;
                if (try self.fireEvent("focus")) |code| return code;
            }
            try self.render();
            const key = try readKey(self.terminal);
            if (try self.handleKey(key)) |code| return code;
        }
    }

    fn refreshSearch(self: *Ui, force_all_for_auto: bool) !void {
        const n = self.candidates.display.len;
        const size = self.terminal.size();
        const base_cap = @min(n, @max(@as(usize, 256), size.rows * 8));
        if (self.result_cap == 0) self.result_cap = base_cap;
        if (force_all_for_auto and (self.options.select_1 or self.options.exit_0)) self.result_cap = n;
        if (self.options.no_sort) self.result_cap = n;

        const effective_query: []const u8 = if (self.options.disabled) "" else self.query.items;
        const old_focus_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        const found = try searchCandidates(self.index, self.candidates, self.options, effective_query, self.results, self.result_cap);
        self.result_len = found.len;
        if (self.options.no_sort) std.mem.sort(usize, self.results[0..self.result_len], {}, comptime std.sort.asc(usize));
        if (self.result_len == 0) {
            self.focus = 0;
            self.scroll = 0;
        } else {
            if (self.focus >= self.result_len) self.focus = self.result_len - 1;
            self.ensureVisible();
        }
        self.dirty_search = false;
        self.preview_cache_key = null;
        self.result_event_pending = true;
        const new_focus_idx: ?usize = if (self.result_len == 0) null else self.results[self.focus];
        if (old_focus_idx != new_focus_idx) self.focus_event_pending = true;
    }

    fn growResults(self: *Ui) !void {
        if (self.result_cap >= self.candidates.display.len) return;
        self.result_cap = @min(self.candidates.display.len, @max(self.result_cap + 1, self.result_cap * 2));
        self.dirty_search = true;
        try self.refreshSearch(false);
    }

    fn ensureVisible(self: *Ui) void {
        const size = self.terminal.size();
        const list_rows = self.listRows(size.rows);
        if (list_rows == 0) return;
        if (self.focus < self.scroll) self.scroll = self.focus;
        if (self.focus >= self.scroll + list_rows) self.scroll = self.focus + 1 - list_rows;
    }

    fn listRows(self: *Ui, rows: usize) usize {
        var fixed: usize = 2;
        if (self.options.header != null) fixed += 1;
        if (self.options.footer != null) fixed += 1;
        if (self.options.border) fixed += 2;
        const effective = @max(@as(usize, 4), rows * self.options.height_percent / 100);
        return if (effective > fixed) effective - fixed else 1;
    }

    fn handleKey(self: *Ui, key: Key) !?u8 {
        for (self.options.bindings.items) |binding| {
            if (std.mem.eql(u8, binding.trigger, "start") or std.mem.eql(u8, binding.trigger, "load") or
                std.mem.eql(u8, binding.trigger, "change") or std.mem.eql(u8, binding.trigger, "result") or
                std.mem.eql(u8, binding.trigger, "focus")) continue;
            if (keyMatchesName(key, binding.trigger)) return try self.runAction(binding.action);
        }
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
                13, 10 => {
                    if (self.result_len == 0 and self.selected_count == 0) return 1;
                    try self.emitSelection(self.accepted_key);
                    return 0;
                },
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
                11, 16 => self.move(-1),
                14 => self.move(1),
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
            .alt_byte => {},
            .unknown => {},
        }
        return null;
    }

    fn markQueryChanged(self: *Ui) void {
        self.dirty_search = true;
        self.change_event_pending = true;
        self.preview_cache_key = null;
    }

    fn fireEvent(self: *Ui, event: []const u8) !?u8 {
        for (self.options.bindings.items) |binding| {
            if (!std.mem.eql(u8, binding.trigger, event)) continue;
            if (try self.runAction(binding.action)) |code| return code;
        }
        return null;
    }

    fn runAction(self: *Ui, action: Action) !?u8 {
        switch (action) {
            .up => self.move(-1),
            .down => self.move(1),
            .page_up => self.page(-1),
            .page_down => self.page(1),
            .first => if (self.result_len != 0) {
                if (self.focus != 0) self.focus_event_pending = true;
                self.focus = 0;
                self.ensureVisible();
                self.preview_cache_key = null;
            },
            .last => if (self.result_len != 0) {
                const target = self.result_len - 1;
                if (self.focus != target) self.focus_event_pending = true;
                self.focus = target;
                self.ensureVisible();
                self.preview_cache_key = null;
            },
            .toggle => try self.toggleCurrent(),
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
            .refresh_preview => self.preview_cache_key = null,
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
            },
            .reload => |cmd| try self.reloadFromCommand(cmd),
            .execute => |cmd| try self.executeCommand(cmd, false),
            .execute_silent => |cmd| try self.executeCommand(cmd, true),
            .become => |cmd| return try self.becomeCommand(cmd),
        }
        return null;
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

    fn reloadFromCommand(self: *Ui, command: []const u8) !void {
        const expanded = try self.expandedCommand(command);
        defer self.allocator.free(expanded);
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded },
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer self.allocator.free(result.stderr);
        var new_candidates = candidatesFromOwnedBlob(self.allocator, result.stdout, self.options) catch |err| {
            self.allocator.free(result.stdout);
            return err;
        };
        errdefer new_candidates.deinit(self.allocator);
        var new_index = try fuzzy.init(self.allocator, new_candidates.search);
        errdefer new_index.deinit();
        const new_results = try self.allocator.alloc(usize, new_candidates.display.len);
        const new_selected = try self.allocator.alloc(bool, new_candidates.display.len);
        @memset(new_selected, false);

        self.index.deinit();
        self.candidates.deinit(self.allocator);
        self.allocator.free(self.results);
        self.allocator.free(self.selected);
        self.candidates.* = new_candidates;
        self.index.* = new_index;
        self.results = new_results;
        self.selected = new_selected;
        self.selected_count = 0;
        self.selection_order.clearRetainingCapacity();
        self.result_len = 0;
        self.result_cap = 0;
        self.focus = 0;
        self.scroll = 0;
        self.dirty_search = true;
        self.preview_cache_key = null;
        self.load_event_pending = true;
        self.focus_event_pending = true;
    }

    fn executeCommand(self: *Ui, command: []const u8, silent: bool) !void {
        const expanded = try self.expandedCommand(command);
        defer self.allocator.free(expanded);
        if (silent) {
            const result = try std.process.run(self.allocator, self.io, .{
                .argv = &.{ "/bin/sh", "-c", expanded },
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
        self.terminal.leave();
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", expanded },
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
        const size = self.terminal.size();
        const rows = self.listRows(size.rows);
        const list_start = if (self.options.layout == .reverse) self.listStartReverse() else 1 + @intFromBool(self.options.border);
        if (m.y < list_start or m.y >= list_start + rows) return;
        const rel = m.y - list_start;
        const item = if (self.options.layout == .reverse) self.scroll + rel else self.scroll + (rows - 1 - rel);
        if (item < self.result_len) {
            if (self.focus != item) self.focus_event_pending = true;
            self.focus = item;
            self.ensureVisible();
            self.preview_cache_key = null;
        }
    }

    fn listStartReverse(self: *Ui) usize {
        var y: usize = 1 + @intFromBool(self.options.border);
        y += 1;
        if (self.options.header != null) y += 1;
        return y;
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
        if (self.focus != old_focus) self.focus_event_pending = true;
    }

    fn page(self: *Ui, delta: isize) void {
        const rows = @max(@as(usize, 1), self.listRows(self.terminal.size().rows));
        self.move(delta * @as(isize, @intCast(rows)));
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
        var frame: Io.Writer.Allocating = .init(self.allocator);
        defer frame.deinit();
        const w = &frame.writer;
        try w.writeAll("\x1b[H\x1b[2J");

        const preview_active = self.options.preview.command != null and !self.options.preview.hidden and size.cols >= 60;
        const preview_cols: usize = if (preview_active and (self.options.preview.position == .left or self.options.preview.position == .right))
            size.cols * self.options.preview.percent / 100
        else
            0;
        const main_cols = if (preview_cols > 0) size.cols - preview_cols - 1 else size.cols;

        if (self.options.layout == .reverse) {
            try self.renderPrompt(w, main_cols);
            if (self.options.header) |h| try self.renderPlainLine(w, h, main_cols);
            try self.renderList(w, main_cols, true);
            if (self.options.footer) |f| try self.renderPlainLine(w, f, main_cols);
        } else {
            try self.renderList(w, main_cols, false);
            if (self.options.header) |h| try self.renderPlainLine(w, h, main_cols);
            try self.renderPrompt(w, main_cols);
            if (self.options.footer) |f| try self.renderPlainLine(w, f, main_cols);
        }

        if (preview_cols > 0) {
            try self.ensurePreview();
            try self.renderPreviewOverlay(&frame, size, preview_cols);
        }

        try self.terminal.write(frame.written());
    }

    fn renderPrompt(self: *Ui, w: anytype, cols: usize) !void {
        _ = cols;
        try w.print("\x1b[1m{s}\x1b[0m", .{self.options.prompt});
        try w.writeAll(self.query.items[0..self.cursor]);
        if (self.cursor < self.query.items.len) {
            const next = nextUtf8Boundary(self.query.items, self.cursor);
            try w.writeAll("\x1b[7m");
            try w.writeAll(self.query.items[self.cursor..next]);
            try w.writeAll("\x1b[0m");
            try w.writeAll(self.query.items[next..]);
        } else {
            try w.writeAll("\x1b[7m \x1b[0m");
        }
        const shown = if (self.result_len == self.result_cap and self.result_cap < self.candidates.display.len)
            try std.fmt.allocPrint(self.allocator, "  {d}+/{d}", .{ self.result_len, self.candidates.display.len })
        else
            try std.fmt.allocPrint(self.allocator, "  {d}/{d}", .{ self.result_len, self.candidates.display.len });
        defer self.allocator.free(shown);
        if (self.options.multi) {
            try w.print("\x1b[2m{s} ({d})\x1b[0m", .{ shown, self.selected_count });
        } else try w.print("\x1b[2m{s}\x1b[0m", .{shown});
        try w.writeByte('\n');
    }

    fn renderPlainLine(self: *Ui, w: anytype, text: []const u8, cols: usize) !void {
        _ = self;
        try writeTruncated(w, text, cols, false, "");
        try w.writeByte('\n');
    }

    fn renderList(self: *Ui, w: anytype, cols: usize, top_down: bool) !void {
        const rows = self.listRows(self.terminal.size().rows);
        var line: usize = 0;
        while (line < rows) : (line += 1) {
            const logical = if (top_down) self.scroll + line else self.scroll + (rows - 1 - line);
            if (logical >= self.result_len) {
                try w.writeByte('\n');
                continue;
            }
            const idx = self.results[logical];
            const focused = logical == self.focus;
            const marked = self.selected[idx];
            if (focused) try w.writeAll("\x1b[7m");
            try w.print("{s} {s} ", .{
                if (focused) self.options.pointer else " ",
                if (marked) self.options.marker else " ",
            });
            try writeHighlighted(w, self.candidates.display[idx], self.query.items, if (cols > 4) cols - 4 else cols, self.options.wrap, self.options.ansi);
            if (focused) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
        }
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
    }

    fn renderPreviewOverlay(self: *Ui, frame: *Io.Writer.Allocating, size: anytype, preview_cols: usize) !void {
        if (self.options.preview.position != .right) return; // right pane is the high-value default
        const start_col = size.cols - preview_cols + 1;
        var lines = std.mem.splitScalar(u8, self.preview_text, '\n');
        var row: usize = 1;
        while (row <= size.rows) : (row += 1) {
            const line = lines.next() orelse break;
            try frame.writer.print("\x1b[{d};{d}H\x1b[2m│\x1b[0m", .{ row, start_col - 1 });
            try frame.writer.print("\x1b[{d};{d}H", .{ row, start_col });
            try writeTruncated(&frame.writer, line, preview_cols, self.options.preview.wrap, "");
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var options: Options = .{};
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

    var candidates = try readCandidates(allocator, init.io, &options, init.environ_map.get("FZF_DEFAULT_COMMAND"));
    defer candidates.deinit(allocator);

    var index = try fuzzy.init(allocator, candidates.search);
    defer index.deinit();

    if (options.filter) |filter| {
        try filterMode(allocator, init.io, &index, &candidates, &options, filter);
        return;
    }

    var terminal = Terminal.open(init.io, options.mouse) catch {
        // No controlling terminal: behave like --filter with the initial query.
        try filterMode(allocator, init.io, &index, &candidates, &options, options.query);
        return;
    };
    defer terminal.close(init.io);

    var ui = try Ui.init(allocator, init.io, &options, &candidates, &index, &terminal);
    defer ui.deinit();
    const code = try ui.run();
    if (code != 0) std.process.exit(code);
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
            std.mem.eql(u8, a, "--bash") or std.mem.eql(u8, a, "--zsh") or std.mem.eql(u8, a, "--fish") or
            std.mem.eql(u8, a, "--sync")) continue;
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
        if (std.mem.eql(u8, a, "--tac")) {
            o.*.tac = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-mouse")) {
            o.*.mouse = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-border")) {
            o.*.border = false;
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
        if (std.mem.startsWith(u8, a, "--footer=")) {
            o.*.footer = a[9..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--height=")) {
            o.*.height_percent = parsePercent(a[9..]);
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
        try out.append(allocator, .{ .trigger = trigger, .action = try parseAction(action_text) });
    }
}

fn parseAction(s: []const u8) !Action {
    if (std.mem.eql(u8, s, "up")) return .up;
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "page-up")) return .page_up;
    if (std.mem.eql(u8, s, "page-down")) return .page_down;
    if (std.mem.eql(u8, s, "first")) return .first;
    if (std.mem.eql(u8, s, "last")) return .last;
    if (std.mem.eql(u8, s, "toggle")) return .toggle;
    if (std.mem.eql(u8, s, "toggle-up")) return .toggle_up;
    if (std.mem.eql(u8, s, "select-all")) return .select_all;
    if (std.mem.eql(u8, s, "deselect-all")) return .deselect_all;
    if (std.mem.eql(u8, s, "clear-query")) return .clear_query;
    if (std.mem.eql(u8, s, "accept")) return .accept;
    if (std.mem.eql(u8, s, "abort")) return .abort;
    if (std.mem.eql(u8, s, "toggle-preview")) return .toggle_preview;
    if (std.mem.eql(u8, s, "refresh-preview")) return .refresh_preview;
    if (std.mem.eql(u8, s, "toggle-sort")) return .toggle_sort;
    if (std.mem.eql(u8, s, "enable-search")) return .enable_search;
    if (std.mem.eql(u8, s, "disable-search")) return .disable_search;
    if (std.mem.eql(u8, s, "toggle-search")) return .toggle_search;
    if (commandAction(s, "change-query")) |value| return .{ .change_query = value };
    if (commandAction(s, "change-prompt")) |value| return .{ .change_prompt = value };
    if (commandAction(s, "change-header")) |value| return .{ .change_header = value };
    if (commandAction(s, "change-footer")) |value| return .{ .change_footer = value };
    if (commandAction(s, "change-preview")) |value| return .{ .change_preview = value };
    if (commandAction(s, "reload")) |cmd| return .{ .reload = cmd };
    if (commandAction(s, "execute-silent")) |cmd| return .{ .execute_silent = cmd };
    if (commandAction(s, "execute")) |cmd| return .{ .execute = cmd };
    if (commandAction(s, "become")) |cmd| return .{ .become = cmd };
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
        if (std.mem.eql(u8, part, "right")) p.position = .right else if (std.mem.eql(u8, part, "left")) p.position = .left else if (std.mem.eql(u8, part, "up")) p.position = .up else if (std.mem.eql(u8, part, "down")) p.position = .down else if (std.mem.eql(u8, part, "hidden")) p.hidden = true else if (std.mem.eql(u8, part, "nohidden")) p.hidden = false else if (std.mem.eql(u8, part, "wrap")) p.wrap = true else if (std.mem.eql(u8, part, "nowrap")) p.wrap = false else if (std.mem.endsWith(u8, part, "%")) p.percent = parsePercent(part);
    }
}

fn readCandidates(allocator: Allocator, io: Io, options: *const Options, default_command: ?[]const u8) !CandidateSet {
    if (std.c.isatty(std.posix.STDIN_FILENO) == 1) {
        const command = default_command orelse
            "find . -path './.git' -prune -o -path './node_modules' -prune -o \\( -type f -o -type d \\) -print";
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", command },
            .stdout_limit = .limited(256 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        allocator.free(result.stderr);
        return candidatesFromOwnedBlob(allocator, result.stdout, options);
    }
    var buffer: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    const blob = try reader.interface.allocRemaining(allocator, .unlimited);
    return candidatesFromOwnedBlob(allocator, blob, options);
}

fn candidatesFromOwnedBlob(allocator: Allocator, blob: []u8, options: *const Options) !CandidateSet {
    errdefer allocator.free(blob);
    const delim: u8 = if (options.read0) 0 else '\n';
    var count: usize = 0;
    var it_count = std.mem.splitScalar(u8, blob, delim);
    while (it_count.next()) |part| {
        if (part.len == 0 and it_count.index == null and blob.len != 0 and blob[blob.len - 1] == delim) break;
        count += 1;
    }
    const output = try allocator.alloc([]const u8, count);
    errdefer allocator.free(output);
    var it = std.mem.splitScalar(u8, blob, delim);
    var n: usize = 0;
    while (it.next()) |part| {
        if (n >= count) break;
        output[n] = if (!options.read0 and part.len != 0 and part[part.len - 1] == '\r') part[0 .. part.len - 1] else part;
        n += 1;
    }
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
        return .{ .blob = blob, .output = output, .display = display, .search = base_search, .owned_display = owned_display, .owned_search = false };
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
    return .{ .blob = blob, .output = output, .display = display, .search = search, .owned_display = owned_display, .owned_search = true };
}

const TermKind = enum { fuzzy, exact, prefix, suffix, boundary_exact };

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
};

fn searchCandidates(
    index: *fuzzy.Index,
    candidates: *const CandidateSet,
    options: *const Options,
    query: []const u8,
    out: []usize,
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
        if (!termCaseSensitive(options.case_mode, direct)) {
            return try index.search(direct, out[0..cap]);
        }
    }

    // Any predicate beyond the direct folded fuzzy path can reject candidates
    // after ranking, so generate a complete ranked stream before compacting.
    var ranked: []usize = out;
    if (parsed.driver) |driver| {
        ranked = try index.search(driver, out);
    } else {
        for (out, 0..) |*slot, i| slot.* = i;
    }

    var write: usize = 0;
    for (ranked) |idx| {
        if (!queryMatches(parsed, candidates.search[idx], options.case_mode)) continue;
        out[write] = idx;
        write += 1;
        if (write == cap) break;
    }
    return out[0..write];
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

    if (count == 0) return .{ .terms = storage[0..0], .clause_count = 0, .driver = null, .direct = "" };

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
    return .{ .terms = storage[0..count], .clause_count = clause + 1, .driver = driver, .direct = direct };
}

fn parseTerm(raw: []const u8, exact_mode: bool, clause: u16) QueryTerm {
    var text = raw;
    var inverse = false;
    if (text.len > 1 and text[0] == '!') {
        inverse = true;
        text = text[1..];
    }

    var kind: TermKind = if (exact_mode) .exact else .fuzzy;
    if (text.len > 1 and text[0] == '\'') {
        text = text[1..];
        kind = if (exact_mode) .fuzzy else .exact;
        if (!exact_mode and text.len > 1 and text[text.len - 1] == '\'') {
            text = text[0 .. text.len - 1];
            kind = .boundary_exact;
        }
    } else if (text.len > 1 and text[0] == '^') {
        text = text[1..];
        kind = .prefix;
    } else if (text.len > 1 and text[text.len - 1] == '$') {
        text = text[0 .. text.len - 1];
        kind = .suffix;
    } else if (inverse) {
        // In extended mode !foo is inverse-exact, matching fzf syntax.
        kind = .exact;
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
    };
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
    const found = try searchCandidates(index, candidates, options, query, out, out.len);
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
    const b3 = try t.readByte();
    return switch (b3) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        '<' => try readMouse(t),
        '1', '2', '3', '4', '5', '6', '7', '8' => blk: {
            var digits: [8]u8 = undefined;
            digits[0] = b3;
            var len: usize = 1;
            while (len < digits.len) {
                const x = try t.readByte();
                if (x == '~') break;
                if (x < '0' or x > '9') break;
                digits[len] = x;
                len += 1;
            }
            const code = std.fmt.parseInt(usize, digits[0..len], 10) catch 0;
            break :blk switch (code) {
                1, 7 => .home,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => .unknown,
            };
        },
        else => .unknown,
    };
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

fn writeHighlighted(w: anytype, text: []const u8, query: []const u8, cols: usize, wrap: bool, ansi: bool) !void {
    var qi: usize = 0;
    var printed: usize = 0;
    var i: usize = 0;
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
            try w.writeAll("\x1b[1;36m");
            try w.writeByte(c);
            try w.writeAll("\x1b[0m");
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
    \\  -q, --query=STR          start with query
    \\  -f, --filter=STR         non-interactive filter mode
    \\  -1, --select-1           accept when there is exactly one match
    \\  -0, --exit-0             exit immediately when there is no match
    \\      --no-sort            preserve input order after filtering
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
    \\  Tab toggle, Ctrl-A/E line edges, Ctrl-U clear, Ctrl-W erase word.
;

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
}

test "binding parser" {
    const a = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(a);
    try parseBindings(a, &bindings, "ctrl-r:reload(printf 'a,b')+change-header(ready),enter:accept");
    try std.testing.expectEqual(@as(usize, 3), bindings.items.len);
    try std.testing.expectEqualStrings("ctrl-r", bindings.items[0].trigger);
    try std.testing.expectEqualStrings("printf 'a,b'", bindings.items[0].action.reload);
    try std.testing.expectEqualStrings("ready", bindings.items[1].action.change_header);
    try std.testing.expect(bindings.items[2].action == .accept);
}
