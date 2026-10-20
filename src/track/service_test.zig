//! Helpers for local tracking service fixtures.
const std = @import("std");
pub fn response(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
}
pub const missing = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
pub fn contains(request: []const u8, fragment: []const u8) !void {
    if (std.mem.indexOf(u8, request, fragment) == null) {
        std.debug.print("Missing {s} in {s}\n", .{ fragment, request });
        return error.TestExpectedEqual;
    }
}
