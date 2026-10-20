//! HTTP for tracking services: one client, the engine's CA file, JSON and
//! form bodies, and the status to act on.
const std = @import("std");
const Io = std.Io;

pub const Http = struct {
    gpa: std.mem.Allocator,
    io: Io,
    ca_file: ?[]const u8 = null,
    client: ?std.http.Client = null,
    user_agent: []const u8 = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36",

    pub fn deinit(self: *Http) void {
        if (self.client) |*c| c.deinit();
    }

    fn get(self: *Http) !*std.http.Client {
        if (self.client) |*client| return client;
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        errdefer client.deinit();
        if (self.ca_file) |ca| {
            const now = Io.Clock.real.now(self.io);
            try client.ca_bundle.addCertsFromFilePath(self.gpa, self.io, now, Io.Dir.cwd(), ca);
            client.now = now;
        }
        // Publish only a fully configured client; failures must retry CA loading.
        self.client = client;
        return &self.client.?;
    }

    pub const Response = struct {
        status: std.http.Status,
        body: []const u8,

        /// The body as `T`, unknown fields ignored.
        pub fn json(self: Response, comptime T: type, arena: std.mem.Allocator) !T {
            return std.json.parseFromSliceLeaky(T, arena, self.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        }

        pub fn ok(self: Response) bool {
            return @backingInt(self.status) >= 200 and @backingInt(self.status) < 300;
        }
    };

    pub const Body = union(enum) {
        none,
        json: []const u8,
        form: []const u8,
    };

    /// Sends a request and reads the whole response into `arena`. A 401
    /// fails with `error.AuthenticationExpired`; other statuses are the
    /// caller's to judge.
    pub fn send(self: *Http, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: Body) !Response {
        return self.sendWithRedirects(arena, method, url, headers, body, true);
    }

    /// Sends server credentials only to the configured URL, without redirects.
    pub fn sendPrivate(self: *Http, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: Body) !Response {
        return self.sendWithRedirects(arena, method, url, headers, body, false);
    }

    fn sendWithRedirects(self: *Http, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: Body, follow_redirects: bool) !Response {
        var all: std.ArrayList(std.http.Header) = .empty;
        try all.appendSlice(arena, headers);
        const explicit_content_type = for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Type")) break true;
        } else false;
        switch (body) {
            .none => {},
            .json => if (!explicit_content_type) try all.append(arena, .{ .name = "Content-Type", .value = "application/json" }),
            .form => if (!explicit_content_type) try all.append(arena, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }),
        }
        var out: Io.Writer.Allocating = .init(arena);
        const result = try (try self.get()).fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = switch (body) {
                .none => null,
                .json, .form => |b| b,
            },
            .headers = .{ .user_agent = .{ .override = self.user_agent } },
            .extra_headers = all.items,
            .redirect_behavior = if (follow_redirects) null else .unhandled,
            .response_writer = &out.writer,
        });
        if (result.status == .unauthorized) return error.AuthenticationExpired;
        return .{ .status = result.status, .body = out.written() };
    }

    /// Exchanges a simple-login form for cookies without following its redirect.
    pub fn loginCookies(self: *Http, arena: std.mem.Allocator, url: []const u8, body: []const u8) ![]const u8 {
        var request = try (try self.get()).request(.POST, try std.Uri.parse(url), .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        });
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = body.len };
        var writer = try request.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(body);
        try writer.end();
        try request.connection.?.flush();
        const response = try request.receiveHead(&.{});
        if (response.head.status != .found and response.head.status != .see_other) return error.AuthenticationExpired;
        var cookies: std.ArrayList(u8) = .empty;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "Set-Cookie")) continue;
            const end = std.mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
            if (cookies.items.len > 0) try cookies.appendSlice(arena, "; ");
            try cookies.appendSlice(arena, header.value[0..end]);
        }
        if (cookies.items.len == 0) return error.AuthenticationExpired;
        return cookies.items;
    }

    /// `name=value&...`, percent-encoded.
    pub fn form(arena: std.mem.Allocator, fields: []const [2][]const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (fields, 0..) |field, i| {
            if (i > 0) try out.append(arena, '&');
            try encode(arena, &out, field[0]);
            try out.append(arena, '=');
            try encode(arena, &out, field[1]);
        }
        return out.items;
    }

    fn encode(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
        for (text) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try out.append(arena, c) else try out.print(arena, "%{X:0>2}", .{c});
        }
    }
};

test "failed CA loading leaves the HTTP client uninitialized" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const missing_ca = try std.fs.path.join(t.allocator, &.{ dir, "missing.pem" });
    defer t.allocator.free(missing_ca);
    var http: Http = .{ .gpa = t.allocator, .io = t.io, .ca_file = missing_ca };
    defer http.deinit();
    for (0..2) |_| {
        try t.expectError(error.FileNotFound, http.get());
        try t.expect(http.client == null);
    }
    http.ca_file = null;
    const client = try http.get();
    try t.expect(client == try http.get());
}
