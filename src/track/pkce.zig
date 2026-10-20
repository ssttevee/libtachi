//! PKCE and expiring OAuth credentials for MangaBaka and Comick.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
pub const Config = struct { client: []const u8, oauth: []const u8, redirect: []const u8, scope: []const u8, resource: ?[]const u8 = null };
pub const Token = struct { access_token: []const u8, refresh_token: []const u8, expires_at: i64, scope: []const u8 = "" };
// Comick's client permits 55 requests per minute, including OAuth requests.
var limit_lock: std.Io.Mutex = .init;
var sent_at: [55]i64 = @splat(0);
var sent_count: usize = 0;
var next_slot: usize = 0;
fn limit(ctx: *driver.Context, config: Config) !void {
    if (config.resource == null) return;
    limit_lock.lockUncancelable(ctx.io);
    defer limit_lock.unlock(ctx.io);
    var current = std.Io.Clock.awake.now(ctx.io).toMilliseconds();
    if (sent_count == sent_at.len) {
        const delay = sent_at[next_slot] + 60000 - current;
        if (delay > 0) {
            try ctx.io.sleep(.fromMilliseconds(delay), .awake);
            current = std.Io.Clock.awake.now(ctx.io).toMilliseconds();
        }
    } else sent_count += 1;
    sent_at[next_slot] = current;
    next_slot = (next_slot + 1) % sent_at.len;
}
pub fn now(ctx: *driver.Context) i64 {
    return std.Io.Clock.real.now(ctx.io).toMilliseconds();
}
pub fn endpoint(ctx: *driver.Context, config: Config, path: []const u8) ![]const u8 {
    const base = if (std.mem.startsWith(u8, ctx.base_url, "http://")) ctx.base_url else config.oauth;
    return std.mem.concat(ctx.arena, u8, &.{ base, path });
}
pub fn authorize(ctx: *driver.Context, config: Config, redirect: []const u8, state: []const u8) !tracking.Reply {
    var random: [32]u8 = undefined;
    try ctx.io.randomSecure(&random);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const verifier = try ctx.arena.alloc(u8, encoder.calcSize(random.len));
    _ = encoder.encode(verifier, &random);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = encoder.encode(&challenge, &digest);
    const query = try Http.form(ctx.arena, &.{ .{ "client_id", config.client }, .{ "response_type", "code" }, .{ "redirect_uri", if (redirect.len > 0) redirect else config.redirect }, .{ "scope", config.scope }, .{ "state", state }, .{ "code_challenge", &challenge }, .{ "code_challenge_method", "S256" } });
    const resource = if (config.resource) |r| try std.mem.concat(ctx.arena, u8, &.{ "&", try Http.form(ctx.arena, &.{.{ "resource", r }}) }) else "";
    return .{ .login_url = try std.mem.concat(ctx.arena, u8, &.{ try endpoint(ctx, config, "/authorize?"), query, resource }), .verifier = verifier };
}
pub fn exchange(ctx: *driver.Context, config: Config, code: []const u8, redirect: []const u8, verifier: []const u8) !Token {
    if (verifier.len == 0) return error.MissingPkceVerifier;
    var fields: std.ArrayList([2][]const u8) = .empty;
    try fields.appendSlice(ctx.arena, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", config.client }, .{ "code", code }, .{ "redirect_uri", if (redirect.len > 0) redirect else config.redirect }, .{ "code_verifier", verifier } });
    if (config.resource) |r| try fields.append(ctx.arena, .{ "resource", r }) else try fields.appendSlice(ctx.arena, &.{ .{ "scope", config.scope }, .{ "code_challenge_method", "S256" } });
    try limit(ctx, config);
    const response = try ctx.http.send(ctx.arena, .POST, try endpoint(ctx, config, "/token"), &.{}, .{ .form = try Http.form(ctx.arena, fields.items) });
    try ok(response);
    if (config.resource != null and std.mem.indexOf(u8, response.body, "refresh_token") == null) return error.MissingScopes;
    return response.json(Token, ctx.arena);
}
pub fn save(ctx: *driver.Context, token: Token) !void {
    ctx.credential.password = token.access_token;
    ctx.credential.token = try std.json.Stringify.valueAlloc(ctx.arena, token, .{});
    ctx.credential.auth_expired = false;
}
pub fn send(ctx: *driver.Context, config: Config, method: std.http.Method, path: []const u8, body: Http.Body) !Http.Response {
    if (!ctx.credential.loggedIn()) return error.NotAuthenticated;
    if (ctx.credential.token.len > 0) {
        const token = try std.json.parseFromSliceLeaky(Token, ctx.arena, ctx.credential.token, .{ .ignore_unknown_fields = true });
        const seconds = @divTrunc(now(ctx), 1000) + 60;
        if (seconds > token.expires_at or (config.resource != null and seconds == token.expires_at)) {
            var fields: std.ArrayList([2][]const u8) = .empty;
            try fields.appendSlice(ctx.arena, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", config.client }, .{ "refresh_token", token.refresh_token } });
            try fields.append(ctx.arena, if (config.resource) |r| .{ "resource", r } else .{ "redirect_uri", config.redirect });
            try limit(ctx, config);
            const response = ctx.http.send(ctx.arena, .POST, try endpoint(ctx, config, "/token"), &.{}, .{ .form = try Http.form(ctx.arena, fields.items) }) catch |err| switch (err) {
                error.AuthenticationExpired => null,
                else => return err,
            };
            if (response) |r| if (r.ok()) try save(ctx, try r.json(Token, ctx.arena));
        }
    }
    try limit(ctx, config);
    return ctx.http.send(ctx.arena, method, try std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, path }), &.{ .{ .name = "Authorization", .value = try std.mem.concat(ctx.arena, u8, &.{ "Bearer ", ctx.credential.password }) }, .{ .name = "Accept", .value = "application/json" } }, body);
}
pub fn ok(response: Http.Response) !void {
    if (!response.ok()) return error.TrackerRequestFailed;
}
