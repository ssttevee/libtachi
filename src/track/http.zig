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
        if (self.client == null) {
            self.client = .{ .allocator = self.gpa, .io = self.io };
            if (self.ca_file) |ca| {
                const now = Io.Clock.real.now(self.io);
                try self.client.?.ca_bundle.addCertsFromFilePath(self.gpa, self.io, now, Io.Dir.cwd(), ca);
                self.client.?.now = now;
            }
        }
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
        var all: std.ArrayList(std.http.Header) = .empty;
        try all.appendSlice(arena, headers);
        switch (body) {
            .none => {},
            .json => try all.append(arena, .{ .name = "Content-Type", .value = "application/json" }),
            .form => try all.append(arena, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }),
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
            .response_writer = &out.writer,
        });
        if (result.status == .unauthorized) return error.AuthenticationExpired;
        return .{ .status = result.status, .body = out.written() };
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
