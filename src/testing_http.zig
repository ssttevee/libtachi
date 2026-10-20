//! Local HTTP fixture for deterministic repository tests; no external network.
const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    server: Io.net.Server,
    responses: []const []const u8,
    worker: ?Io.Future(anyerror!void) = null,
    requests: usize = 0,
    /// Each request as received, head and body.
    captured: std.ArrayList([]const u8) = .empty,
    /// Optional substrings required in each request, including its body;
    /// a miss is reported at `finish`.
    expected: []const []const []const u8 = &.{},
    requests_match: bool = true,
    /// The same, failing at once.
    expected_requests: []const []const []const u8 = &.{},

    pub fn init(responses: []const []const u8) !Fixture {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .server = try address.listen(std.testing.io, .{}), .responses = responses };
    }

    pub fn start(self: *Fixture) !void {
        self.worker = try Io.concurrent(std.testing.io, serve, .{self});
    }

    pub fn url(self: *const Fixture, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ self.server.socket.address.getPort(), path });
    }

    pub fn finish(self: *Fixture) !void {
        if (self.worker) |*worker| try worker.await(std.testing.io);
        try std.testing.expectEqual(self.responses.len, self.requests);
        try std.testing.expect(self.requests_match);
    }

    pub fn deinit(self: *Fixture) void {
        if (self.worker) |*worker| worker.cancel(std.testing.io) catch {};
        self.server.deinit(std.testing.io);
        for (self.captured.items) |request| std.testing.allocator.free(request);
        self.captured.deinit(std.testing.allocator);
    }

    fn serve(self: *Fixture) anyerror!void {
        const io = std.testing.io;
        const listener: Io.net.Stream = .{ .socket = self.server.socket };
        defer listener.shutdown(io, .both) catch {};
        for (self.responses) |response| {
            const stream = try self.server.accept(io);
            defer stream.close(io);
            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var request: std.ArrayList(u8) = .empty;
            errdefer request.deinit(std.testing.allocator);
            var content_length: usize = 0;
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                try request.appendSlice(std.testing.allocator, line);
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            var remaining = content_length;
            while (remaining > 0) {
                const chunk = try reader.interface.take(@min(remaining, read_buffer.len));
                try request.appendSlice(std.testing.allocator, chunk);
                remaining -= chunk.len;
            }
            const received = try request.toOwnedSlice(std.testing.allocator);
            try self.captured.append(std.testing.allocator, received);
            if (self.expected_requests.len > 0) {
                for (self.expected_requests[self.requests]) |expected| {
                    try std.testing.expect(std.mem.indexOf(u8, received, expected) != null);
                }
            }
            if (self.expected.len > 0) {
                for (self.expected[self.requests]) |needle| {
                    if (std.mem.indexOf(u8, received, needle) == null) {
                        std.debug.print("Missing request text: {s}\nRequest: {s}\n", .{ needle, received });
                        self.requests_match = false;
                    }
                }
            }
            self.requests += 1;
            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(io, &write_buffer);
            try writer.interface.writeAll(response);
            try writer.interface.flush();
        }
    }
};
