//! Local HTTP fixture for deterministic repository tests; no external network.
const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    server: Io.net.Server,
    responses: []const []const u8,
    worker: ?Io.Future(anyerror!void) = null,
    requests: usize = 0,

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
    }

    pub fn deinit(self: *Fixture) void {
        if (self.worker) |*worker| worker.cancel(std.testing.io) catch {};
        self.server.deinit(std.testing.io);
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
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            self.requests += 1;
            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(io, &write_buffer);
            try writer.interface.writeAll(response);
            try writer.interface.flush();
        }
    }
};
