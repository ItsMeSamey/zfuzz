const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Net = std.Io.net;

pub const GetParams = struct {
    limit: usize = 100,
    offset: usize = 0,
};

pub const Request = union(enum) {
    post: []u8,
    get: *GetWaiter,
};

pub const GetWaiter = struct {
    params: GetParams,
    response: ?[]u8 = null,
    done: bool = false,
};

pub const Config = struct {
    address: []const u8,
    unsafe_remote_exec: bool = false,
    api_key: []const u8 = "",
    validate_actions: ?*const fn ([]const u8) bool = null,
};

pub const Server = struct {
    allocator: Allocator,
    io: Io,
    listener: Net.Server,
    thread: std.Thread,
    mutex: Io.Mutex = .init,
    requests: std.ArrayList(Request) = .empty,
    stopping: bool = false,
    api_key: []u8,
    remote: bool,
    unsafe_remote_exec: bool,
    validate_actions: ?*const fn ([]const u8) bool,
    unix_path: ?[]u8 = null,
    port: u16 = 0,

    pub fn start(allocator: Allocator, io: Io, config: Config) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const api_key = try allocator.dupe(u8, config.api_key);
        errdefer allocator.free(api_key);

        var listener: Net.Server = undefined;
        var remote = false;
        var unix_path: ?[]u8 = null;
        var port: u16 = 0;

        const spec = std.mem.trim(u8, config.address, " \t");
        if (std.mem.endsWith(u8, spec, ".sock")) {
            if (spec.len == 0) return error.InvalidListenAddress;
            deleteSocketPath(io, spec) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            const path_copy = try allocator.dupe(u8, spec);
            errdefer allocator.free(path_copy);
            const ua = try Net.UnixAddress.init(path_copy);
            listener = try ua.listen(io, .{});
            errdefer listener.deinit(io);
            const path_z = try allocator.dupeZ(u8, path_copy);
            defer allocator.free(path_z);
            if (std.c.chmod(path_z.ptr, 0o600) != 0) return error.SocketPermissionFailed;
            unix_path = path_copy;
        } else {
            const parsed = try parseTcpSpec(spec);
            remote = !isLoopbackHost(parsed.host);
            if (remote and api_key.len == 0) return error.ApiKeyRequired;
            const addr = if (std.mem.eql(u8, parsed.host, "localhost"))
                try Net.IpAddress.parse("127.0.0.1", parsed.port)
            else
                try Net.IpAddress.parse(parsed.host, parsed.port);
            listener = try addr.listen(io, .{ .reuse_address = true });
            port = listener.socket.address.getPort();
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .listener = listener,
            .thread = undefined,
            .api_key = api_key,
            .remote = remote,
            .unsafe_remote_exec = config.unsafe_remote_exec,
            .validate_actions = config.validate_actions,
            .unix_path = unix_path,
            .port = port,
        };
        errdefer self.listener.deinit(io);
        errdefer if (self.unix_path) |path| allocator.free(path);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        self.wakeListener();
        self.thread.join();
        self.listener.deinit(self.io);

        self.mutex.lockUncancelable(self.io);
        for (self.requests.items) |req| switch (req) {
            .post => |body| self.allocator.free(body),
            .get => |waiter| {
                if (waiter.response) |response| self.allocator.free(response);
                waiter.done = true;
            },
        };
        self.requests.deinit(self.allocator);
        self.mutex.unlock(self.io);
        if (self.unix_path) |path| {
            deleteSocketPath(self.io, path) catch {};
            self.allocator.free(path);
        }
        self.allocator.free(self.api_key);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn takeRequest(self: *Server) ?Request {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.requests.items.len == 0) return null;
        return self.requests.orderedRemove(0);
    }

    pub fn completeGet(self: *Server, waiter: *GetWaiter, response: []u8) void {
        self.mutex.lockUncancelable(self.io);
        waiter.response = response;
        waiter.done = true;
        self.mutex.unlock(self.io);
    }

    fn enqueuePost(self: *Server, body: []const u8) !void {
        const copy = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(copy);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.ServerStopping;
        try self.requests.append(self.allocator, .{ .post = copy });
    }

    fn enqueueGet(self: *Server, waiter: *GetWaiter) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.ServerStopping;
        try self.requests.append(self.allocator, .{ .get = waiter });
    }

    fn cancelGet(self: *Server, waiter: *GetWaiter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.requests.items, 0..) |request, i| switch (request) {
            .get => |queued| if (queued == waiter) {
                _ = self.requests.orderedRemove(i);
                return true;
            },
            else => {},
        };
        return false;
    }

    fn threadMain(self: *Server) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const stopping = self.stopping;
            self.mutex.unlock(self.io);
            if (stopping) return;
            const stream = self.listener.accept(self.io) catch return;
            self.mutex.lockUncancelable(self.io);
            const stopped = self.stopping;
            self.mutex.unlock(self.io);
            if (stopped) {
                stream.close(self.io);
                return;
            }
            self.handleConnection(stream) catch {};
            stream.close(self.io);
        }
    }

    fn wakeListener(self: *Server) void {
        if (self.unix_path) |path| {
            const ua = Net.UnixAddress.init(path) catch return;
            const stream = ua.connect(self.io) catch return;
            stream.close(self.io);
            return;
        }
        var addr = self.listener.socket.address;
        switch (addr) {
            .ip4 => |*ip4| {
                if (std.mem.eql(u8, &ip4.bytes, &[_]u8{ 0, 0, 0, 0 })) ip4.bytes = [4]u8{ 127, 0, 0, 1 };
            },
            .ip6 => {},
        }
        // The threaded Zig 0.16 network backend does not implement connect
        // timeouts yet. This is a loopback wake-up against our own still-open
        // listener, so an untimed connect is local and immediate.
        const stream = addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch return;
        stream.close(self.io);
    }

    fn handleConnection(self: *Server, stream: Net.Stream) !void {
        const max_body = 1024 * 1024;
        const max_headers = 64 * 1024;
        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);
        var header_end: ?usize = null;
        var content_length: usize = 0;
        var scratch: [16 * 1024]u8 = undefined;

        while (true) {
            const n_raw = std.c.read(stream.socket.handle, &scratch, scratch.len);
            if (n_raw < 0) return error.ReadFailed;
            if (n_raw == 0) break;
            const n: usize = @intCast(n_raw);
            try request.appendSlice(self.allocator, scratch[0..n]);
            if (header_end == null) {
                if (std.mem.indexOf(u8, request.items, "\r\n\r\n")) |at| {
                    header_end = at + 4;
                    const parsed = parseHeaders(request.items[0..at]);
                    content_length = parsed.content_length;
                    if (content_length > max_body) return self.respond(stream, 400, null, "invalid content length\n");
                } else if (request.items.len > max_headers) {
                    return self.respond(stream, 400, null, "request headers too large\n");
                }
            }
            if (header_end) |end| if (request.items.len >= end + content_length) break;
            if (request.items.len > max_headers + max_body) return self.respond(stream, 400, null, "request too large\n");
        }

        const end = header_end orelse return self.respond(stream, 400, null, "incomplete request\n");
        const header_block = request.items[0 .. end - 4];
        const headers = parseHeaders(header_block);
        if (self.api_key.len != 0 and !constantTimeEql(headers.api_key, self.api_key)) {
            return self.respond(stream, 401, null, "invalid api key\n");
        }
        const first_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
        const request_line = header_block[0..first_end];

        if (std.mem.startsWith(u8, request_line, "GET /")) {
            const params = parseGetParams(request_line);
            const waiter = try self.allocator.create(GetWaiter);
            waiter.* = .{ .params = params };
            errdefer self.allocator.destroy(waiter);
            try self.enqueueGet(waiter);
            var tries: usize = 0;
            while (true) : (tries += 1) {
                self.mutex.lockUncancelable(self.io);
                const done = waiter.done;
                const response = waiter.response;
                const stopping = self.stopping;
                self.mutex.unlock(self.io);
                if (done) {
                    defer self.allocator.destroy(waiter);
                    if (response) |json| {
                        defer self.allocator.free(json);
                        return self.respond(stream, 200, "application/json", json);
                    }
                    return self.respond(stream, 503, "application/json", "{\"error\":\"timeout\"}\n");
                }
                if (stopping or tries >= 200) {
                    if (self.cancelGet(waiter)) {
                        self.allocator.destroy(waiter);
                        return self.respond(stream, 503, "application/json", "{\"error\":\"timeout\"}\n");
                    }
                }
                self.io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
            }
        }

        if (!std.mem.startsWith(u8, request_line, "POST / HTTP/")) {
            return self.respond(stream, 400, null, "invalid request method\n");
        }
        if (content_length == 0) return self.respond(stream, 400, null, "content-length header missing\n");
        if (request.items.len < end + content_length) return self.respond(stream, 400, null, "incomplete request\n");
        const body = std.mem.trim(u8, request.items[end .. end + content_length], "\r\n");
        if (body.len == 0) return self.respond(stream, 400, null, "no action specified\n");
        if (self.validate_actions) |validate| if (!validate(body)) return self.respond(stream, 400, null, "invalid action\n");
        if (self.remote and !self.unsafe_remote_exec and containsRemoteExec(body)) {
            return self.respond(stream, 400, null, "remote process execution requires --listen-unsafe\n");
        }
        try self.enqueuePost(body);
        return self.respond(stream, 200, null, "");
    }

    fn respond(self: *Server, stream: Net.Stream, code: u16, content_type: ?[]const u8, body: []const u8) !void {
        _ = self;
        var buffer: [1024]u8 = undefined;
        const reason = switch (code) {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            503 => "Service Unavailable",
            else => "Error",
        };
        const head = if (content_type) |ct|
            try std.fmt.bufPrint(&buffer, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ code, reason, ct, body.len })
        else
            try std.fmt.bufPrint(&buffer, "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ code, reason, body.len });
        try writeAllFd(stream.socket.handle, head);
        if (body.len != 0) try writeAllFd(stream.socket.handle, body);
    }
};

fn deleteSocketPath(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return Io.Dir.deleteFileAbsolute(io, path);
    return Io.Dir.cwd().deleteFile(io, path);
}

const TcpSpec = struct { host: []const u8, port: u16 };

fn parseTcpSpec(spec: []const u8) !TcpSpec {
    if (spec.len == 0) return .{ .host = "localhost", .port = 0 };
    if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
        const host = if (colon == 0) "localhost" else spec[0..colon];
        const port_text = spec[colon + 1 ..];
        const port = if (port_text.len == 0) @as(u16, 0) else try std.fmt.parseInt(u16, port_text, 10);
        return .{ .host = host, .port = port };
    }
    return .{ .host = "localhost", .port = try std.fmt.parseInt(u16, spec, 10) };
}

fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1");
}

const ParsedHeaders = struct {
    content_length: usize = 0,
    api_key: []const u8 = "",
};

fn parseHeaders(block: []const u8) ParsedHeaders {
    var out: ParsedHeaders = .{};
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "content-length")) out.content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        if (std.ascii.eqlIgnoreCase(key, "x-api-key")) out.api_key = value;
    }
    return out;
}

fn parseGetParams(line: []const u8) GetParams {
    var out: GetParams = .{};
    const qmark = std.mem.indexOfScalar(u8, line, '?') orelse return out;
    const space = std.mem.indexOfScalarPos(u8, line, qmark, ' ') orelse line.len;
    var pairs = std.mem.splitScalar(u8, line[qmark + 1 .. space], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = std.fmt.parseInt(usize, pair[eq + 1 ..], 10) catch continue;
        if (std.mem.eql(u8, key, "limit")) out.limit = value;
        if (std.mem.eql(u8, key, "offset")) out.offset = value;
    }
    return out;
}

fn containsRemoteExec(body: []const u8) bool {
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        const c: u8 = if (at_end) '+' else body[i];
        if (!at_end) {
            if (c == '(') depth += 1 else if (c == ')' and depth != 0) depth -= 1;
        }
        if (c != '+' or depth != 0) continue;
        const action = std.mem.trim(u8, body[start..i], " \t");
        start = i + 1;
        const unsafe_names = [_][]const u8{ "execute", "execute-silent", "become", "reload", "reload-sync", "preview", "change-preview", "transform-" };
        for (unsafe_names) |name| {
            if (!std.mem.startsWith(u8, action, name)) continue;
            if (std.mem.eql(u8, name, "transform-") or action.len == name.len or action[name.len] == '(' or action[name.len] == ':') return true;
        }
    }
    return false;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n_raw = std.c.write(fd, bytes.ptr + at, bytes.len - at);
        if (n_raw < 0) return error.WriteFailed;
        if (n_raw == 0) return error.WriteFailed;
        at += @intCast(n_raw);
    }
}

test "listen TCP spec parsing" {
    try std.testing.expectEqual(@as(u16, 0), (try parseTcpSpec("")).port);
    try std.testing.expectEqualStrings("localhost", (try parseTcpSpec("6266")).host);
    try std.testing.expectEqual(@as(u16, 6266), (try parseTcpSpec("127.0.0.1:6266")).port);
}

test "GET parameter parsing" {
    const p = parseGetParams("GET /?limit=12&offset=3 HTTP/1.1");
    try std.testing.expectEqual(@as(usize, 12), p.limit);
    try std.testing.expectEqual(@as(usize, 3), p.offset);
}
