//! Helpers for enhanced tracker fixtures and on-disk source settings.
const std = @import("std");
pub const Fixture = @import("../testing_http.zig").Fixture;
pub const driver = @import("driver.zig");
pub const Http = @import("http.zig").Http;

pub fn ok(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
}

pub fn prefs(a: std.mem.Allocator, tmp: std.Io.Dir, id: i64, values: anytype) ![]const u8 {
    const io = std.testing.io;
    try tmp.createDir(io, "prefs", .default_dir);
    const path = try std.fmt.allocPrint(a, "prefs/source_{d}.json", .{id});
    try tmp.writeFile(io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(a, values, .{}) });
    return tmp.realPathFileAlloc(io, ".", a);
}

pub fn context(a: std.mem.Allocator, http: *Http, id: i32, host: []const u8) driver.Context {
    return .{ .arena = a, .io = std.testing.io, .http = http, .base_url = "", .tracker_id = id, .credential = .{ .tracker_id = id }, .formats = .{}, .host_dir = host };
}

pub fn common(ctx: *driver.Context, comptime service: type) !void {
    const t = std.testing;
    const credential = (try service.call(ctx, .{ .login = .{ .username = "ignored", .password = "ignored" } })).credential.?;
    try t.expectEqualStrings("user", credential.username);
    try t.expectEqualStrings("pass", credential.password);
    try t.expectError(error.PasswordLogin, service.call(ctx, .{ .login_url = .{ .redirect_uri = "", .state = "" } }));
    const track: @import("../tracking.zig").Track = .{ .tracker_id = ctx.tracker_id, .title = "unchanged" };
    try t.expectEqualStrings("unchanged", (try service.call(ctx, .{ .bind = .{ .track = track, .has_read_chapters = true } })).track.?.title);
    try t.expectError(error.UnsupportedDelete, service.call(ctx, .{ .delete = track }));
    try t.expectError(error.UnsupportedSearch, service.call(ctx, .{ .search = "text search" }));
}
