//! Independent C extension interface; see include/tachicore.h.
const std = @import("std");
const tachi = @import("tachicore");
const common = @import("capi_common.zig");
const api = common.Api(tachi);
const c_allocator = std.heap.c_allocator;
pub const tachicore_config = api.Config;
const fail = api.fail;
const mapError = api.mapError;
const returnJson = api.returnJson;

pub export fn tachicore_runtime_new(cfg: ?*const tachicore_config, out: ?*?*tachi.Runtime) c_int {
    return api.runtimeNew(cfg, out);
}

pub export fn tachicore_runtime_free(rt: ?*tachi.Runtime) void {
    return api.runtimeFree(rt);
}

pub export fn tachicore_thread_detach(rt: ?*tachi.Runtime) void {
    return api.threadDetach(rt);
}

pub export fn tachicore_last_error() [*:0]const u8 {
    return api.lastError();
}

pub export fn tachicore_free(p: ?*anyopaque) void {
    return api.freeBuffer(p);
}

pub export fn tachicore_list_extensions(rt: ?*tachi.Runtime, out_json: ?*?[*:0]u8) c_int {
    return api.listExtensions(rt, out_json);
}

pub export fn tachicore_call(
    rt: ?*tachi.Runtime,
    source_id: i64,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_json: ?*?[*:0]u8,
) c_int {
    return api.call(rt, source_id, method, args_json, out_json);
}

pub export fn tachicore_fetch_image(
    rt: ?*tachi.Runtime,
    source_id: i64,
    page_json: ?[*:0]const u8,
    out_bytes: ?*?[*]u8,
    out_len: ?*usize,
    out_mime: ?*?[*:0]u8,
) c_int {
    return api.fetchImage(rt, source_id, page_json, out_bytes, out_len, out_mime);
}

pub export fn tachicore_default_index_url() [*:0]const u8 {
    return tachi.discovery.default_index_url;
}

pub export fn tachicore_load(rt: ?*tachi.Runtime, path: ?[*:0]const u8, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const p = path orelse return fail(.invalid_argument, "path is NULL");
    return returnJson(r.loadPackage(std.mem.span(p)) catch |err| return mapError(err), out_json);
}

pub export fn tachicore_register(rt: ?*tachi.Runtime, path: ?[*:0]const u8, info_json: ?[*:0]const u8, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const p = path orelse return fail(.invalid_argument, "path is NULL");
    const json = info_json orelse return fail(.invalid_argument, "info_json is NULL");
    var arena: std.heap.ArenaAllocator = .init(c_allocator);
    defer arena.deinit();
    const info = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), std.mem.span(json), .{}) catch |err| return switch (err) {
        error.OutOfMemory => fail(.out_of_memory, "OutOfMemory"),
        else => fail(.invalid_argument, "info_json is not valid JSON"),
    };
    if (info != .object) return fail(.invalid_argument, "info_json must be an ExtensionInfo object");
    return returnJson(r.registerPackage(arena.allocator(), std.mem.span(p), info) catch |err| return mapError(err), out_json);
}

pub export fn tachicore_unload(rt: ?*tachi.Runtime, pkg: ?[*:0]const u8, out_removed: ?*c_int) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const p = pkg orelse return fail(.invalid_argument, "pkg is NULL");
    const removed = r.unloadPackage(std.mem.span(p)) catch |err| return mapError(err);
    if (out_removed) |out| out.* = @intFromBool(removed);
    return 0;
}

pub export fn tachicore_cancel_requests(rt: ?*tachi.Runtime, source: i64) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    r.cancelRequests(source) catch |err| return mapError(err);
    return 0;
}

pub export fn tachicore_supports_cancellation(rt: ?*const tachi.Runtime) c_int {
    return if (rt) |r| @intFromBool(r.supportsCancellation()) else 0;
}

fn suppliedBytes(bytes: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const p = bytes orelse {
        _ = fail(.invalid_argument, "bytes is NULL with nonzero length");
        return null;
    };
    return p[0..len];
}

fn encode(value: anytype, out: ?*?[*:0]u8) c_int {
    return returnJson(std.json.Stringify.valueAlloc(c_allocator, value, .{}) catch return fail(.out_of_memory, "OutOfMemory"), out);
}

pub export fn tachicore_parse_index(bytes: ?[*]const u8, len: usize, out_json: ?*?[*:0]u8) c_int {
    const input = suppliedBytes(bytes, len) orelse return common.ErrorCode.invalid_argument.int();
    var arena: std.heap.ArenaAllocator = .init(c_allocator);
    defer arena.deinit();
    return encode(tachi.discovery.parseIndex(arena.allocator(), input) catch |err| return mapError(err), out_json);
}

pub export fn tachicore_parse_extension_list(bytes: ?[*]const u8, len: usize, out_json: ?*?[*:0]u8) c_int {
    const input = suppliedBytes(bytes, len) orelse return common.ErrorCode.invalid_argument.int();
    var arena: std.heap.ArenaAllocator = .init(c_allocator);
    defer arena.deinit();
    return encode(tachi.discovery.parseExtensionList(arena.allocator(), input) catch |err| return mapError(err), out_json);
}

pub export fn tachicore_parse_legacy_repo(bytes: ?[*]const u8, len: usize, out_json: ?*?[*:0]u8) c_int {
    const input = suppliedBytes(bytes, len) orelse return common.ErrorCode.invalid_argument.int();
    var arena: std.heap.ArenaAllocator = .init(c_allocator);
    defer arena.deinit();
    return encode(tachi.discovery.parseLegacyRepo(arena.allocator(), input) catch |err| return mapError(err), out_json);
}

pub export fn tachicore_parse_legacy_list(bytes: ?[*]const u8, len: usize, base_url: ?[*:0]const u8, out_json: ?*?[*:0]u8) c_int {
    const input = suppliedBytes(bytes, len) orelse return common.ErrorCode.invalid_argument.int();
    const base = base_url orelse return fail(.invalid_argument, "base_url is NULL");
    var arena: std.heap.ArenaAllocator = .init(c_allocator);
    defer arena.deinit();
    return encode(tachi.discovery.parseLegacyList(arena.allocator(), input, std.mem.span(base)) catch |err| return mapError(err), out_json);
}

/// DER signature blocks are supplied by the integrator; no package file is opened.
pub export fn tachicore_certificate_fingerprints(bytes: ?[*]const u8, len: usize, out_json: ?*?[*:0]u8) c_int {
    const input = suppliedBytes(bytes, len) orelse return common.ErrorCode.invalid_argument.int();
    var arena: std.heap.ArenaAllocator = .init(c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fingerprints: std.ArrayList(tachi.discovery.Fingerprint) = .empty;
    tachi.discovery.certificateFingerprints(a, input, &fingerprints) catch |err| return switch (err) {
        error.OutOfMemory => fail(.out_of_memory, "OutOfMemory"),
        else => fail(.invalid_argument, "invalid DER signature block"),
    };
    const hex = a.alloc([]const u8, fingerprints.items.len) catch return fail(.out_of_memory, "OutOfMemory");
    for (hex, fingerprints.items) |*out, fingerprint| out.* = a.dupe(u8, &tachi.discovery.hex(fingerprint)) catch return fail(.out_of_memory, "OutOfMemory");
    return encode(hex, out_json);
}

test "core C discovery owns its result and validates caller buffers" {
    const index = "\x0a\x04Test";
    var json: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), tachicore_parse_index(index, index.len, &json));
    defer tachicore_free(json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(json.?), "Test") != null);
    try std.testing.expectEqual(common.ErrorCode.invalid_argument.int(), tachicore_parse_index(null, 1, null));
    try std.testing.expectEqual(common.ErrorCode.invalid_index.int(), tachicore_parse_index(null, 0, null));
    try std.testing.expectEqualStrings("InvalidIndex", std.mem.span(tachicore_last_error()));
}

test "core C runtime initialization failures release the shared I/O backend" {
    const config: tachicore_config = .{ .data_dir = "/dev/null/not-a-directory" };
    try std.testing.expectEqual(common.ErrorCode.file_system_error.int(), tachicore_runtime_new(&config, null));
    try std.testing.expectEqual(0, api.Backend.users);
    tachicore_runtime_free(null);
}

test "core C loader rejects missing and non-object metadata before entering the JVM" {
    try std.testing.expectEqual(common.ErrorCode.invalid_argument.int(), tachicore_load(null, "package.jar", null));
    // No runtime fields are touched while validating metadata.
    var runtime: tachi.Runtime = undefined;
    try std.testing.expectEqual(common.ErrorCode.invalid_argument.int(), tachicore_register(&runtime, "package.jar", "[]", null));
    try std.testing.expectEqual(common.ErrorCode.invalid_argument.int(), tachicore_register(&runtime, "package.jar", "{", null));
}

test "core C discovery decodes supplied legacy metadata and certificate blocks" {
    const metadata = "{\"meta\":{\"name\":\"Store\",\"website\":\"https://repo\",\"signingKeyFingerprint\":\"key\"},\"index_v2\":\"https://repo/index.pb\"}";
    var repo_json: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), tachicore_parse_legacy_repo(metadata, metadata.len, &repo_json));
    defer tachicore_free(repo_json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(repo_json.?), "https://repo/index.pb") != null);
    const legacy = "[{\"name\":\"Tachiyomi: Example\",\"pkg\":\"example\",\"apk\":\"example.apk\",\"lang\":\"en\",\"code\":1,\"version\":\"1.6.1\",\"nsfw\":0}]";
    var list_json: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), tachicore_parse_legacy_list(legacy, legacy.len, "https://repo", &list_json));
    defer tachicore_free(list_json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(list_json.?), "https://repo/apk/example.apk") != null);
    const der = @embedFile("testdata/keiyoushi-cert.rsa");
    var fingerprints: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), tachicore_certificate_fingerprints(der, der.len, &fingerprints));
    defer tachicore_free(fingerprints);
    try std.testing.expectEqualStrings("[\"9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2\"]", std.mem.span(fingerprints.?));
}
