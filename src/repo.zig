//! Repository acquisition and package-file policy for libtachi.
//! Byte decoding is shared with the independent extension core.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const discovery = @import("discovery.zig");
pub const Error = discovery.Error || error{ Canceled, NetworkError, FileSystemError };
const max_index_len = discovery.max_index_len;
const max_package_len = 256 << 20;
pub const default_index_url = discovery.default_index_url;
pub const ContentWarning = discovery.ContentWarning;
pub const Source = discovery.Source;
pub const Extension = discovery.Extension;
pub const Store = discovery.Store;
pub const parseIndex = discovery.parseIndex;
pub const parseExtensionList = discovery.parseExtensionList;
pub const LegacyRepo = discovery.LegacyRepo;
pub const parseLegacyList = discovery.parseLegacyList;
pub const Fingerprint = discovery.Fingerprint;
pub const certificateFingerprints = discovery.certificateFingerprints;
pub const hex = discovery.hex;
pub const signedBy = discovery.signedBy;
const isGzip = discovery.isGzip;
const gunzip = discovery.gunzip;
const isSignatureBlock = discovery.isSignatureBlock;

// ---- HTTP ------------------------------------------------------------------------

/// One connection pool (and one CA-bundle scan) shared by every request.
pub const Http = struct {
    client: std.http.Client,
    user_agent: []const u8 = "zig-tachi",

    pub fn init(gpa: Allocator, io: Io) Http {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    /// Use explicit PEM roots without changing system files or disabling TLS.
    pub fn useCaFile(h: *Http, path: []const u8) Error!void {
        const now = Io.Clock.real.now(h.client.io);
        h.client.ca_bundle.addCertsFromFilePath(h.client.allocator, h.client.io, now, Io.Dir.cwd(), path) catch |err| return httpError(err);
        h.client.now = now;
    }

    pub fn deinit(h: *Http) void {
        h.client.deinit();
    }

    /// GETs `url` into memory. Follows redirects; non-2xx is `NetworkError`.
    pub fn getAlloc(h: *Http, gpa: Allocator, url: []const u8, limit: usize) Error![]u8 {
        const uri = std.Uri.parse(url) catch return error.NetworkError;
        var request = h.client.request(.GET, uri, .{
            .headers = .{ .user_agent = .{ .override = h.user_agent } },
        }) catch |err| return httpError(err);
        defer request.deinit();
        request.sendBodiless() catch |err| return httpError(request.connection.?.stream_writer.err orelse err);
        var redirect_buffer: [8 << 10]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| {
            if (request.connection) |connection| if (connection.stream_reader.err) |cause| return httpError(cause);
            return httpError(err);
        };
        if (response.head.status.class() != .success) return error.NetworkError;

        const window_len: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .gzip, .deflate => std.compress.flate.max_window_len,
            .zstd => std.compress.zstd.default_window_len,
            .compress => return error.NetworkError,
        };
        const window = try gpa.alloc(u8, window_len);
        defer gpa.free(window);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, window);
        return reader.allocRemaining(gpa, .limited(limit)) catch |err| {
            if (err == error.ReadFailed) {
                if (response.bodyErr()) |cause| return httpError(cause);
                if (request.connection) |connection| if (connection.stream_reader.err) |cause| return httpError(cause);
            }
            return httpError(err);
        };
    }

    /// GETs `url` straight into `dir/sub_path`, replacing any existing file.
    pub fn getToFile(h: *Http, dir: Io.Dir, sub_path: []const u8, url: []const u8) Error!void {
        const io = h.client.io;
        const file = dir.createFile(io, sub_path, .{}) catch return error.FileSystemError;
        defer file.close(io);
        var buf: [64 << 10]u8 = undefined;
        var fw = file.writer(io, &buf);
        try h.get(url, &fw.interface);
        fw.interface.flush() catch return error.FileSystemError;
    }

    fn get(h: *Http, url: []const u8, w: *Io.Writer) Error!void {
        const res = h.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = w,
            .headers = .{ .user_agent = .{ .override = h.user_agent } },
        }) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.FileSystemError,
            else => return error.NetworkError,
        };
        if (res.status.class() != .success) return error.NetworkError;
    }
};

/// Fetches and decodes an index, resolving a separate extension list if needed.
/// All returned slices borrow from `arena` allocations.
pub fn fetchIndex(h: *Http, arena: Allocator, url: []const u8) Error!Store {
    return (try fetchIndexWithBytes(h, arena, url)).store;
}

/// The decoded index and its original response bytes, suitable for caching.
pub const FetchedIndex = struct { store: Store, bytes: []const u8 };

pub fn fetchIndexWithBytes(h: *Http, arena: Allocator, url: []const u8) Error!FetchedIndex {
    return fetchDepth(h, arena, url, 0);
}

fn fetchDepth(h: *Http, arena: Allocator, url: []const u8, depth: usize) Error!FetchedIndex {
    if (depth >= 16) return error.InvalidIndex;
    const bytes = try h.getAlloc(arena, url, max_index_len);
    const raw = if (isGzip(bytes)) try gunzip(arena, bytes) else bytes;
    if (raw.len == 0) return error.InvalidIndex;
    var canonical = url;
    var metadata = raw;
    var legacy_list: ?[]const u8 = null;
    if (raw[0] == '[') {
        if (!std.mem.endsWith(u8, url, "/index.min.json")) return error.InvalidIndex;
        canonical = try std.mem.concat(arena, u8, &.{ url[0 .. url.len - "index.min.json".len], "repo.json" });
        metadata = try h.getAlloc(arena, canonical, max_index_len);
        if (isGzip(metadata)) metadata = try gunzip(arena, metadata);
        legacy_list = raw;
    }
    if (metadata.len > 0 and metadata[0] == '{') {
        if (discovery.parseLegacyRepo(arena, metadata)) |legacy| {
            if (legacy.index_v2) |next| return fetchDepth(h, arena, next, depth + 1);
            const base = if (std.mem.endsWith(u8, canonical, "/repo.json")) canonical[0 .. canonical.len - "/repo.json".len] else canonical;
            const list = legacy_list orelse try h.getAlloc(arena, try std.mem.concat(arena, u8, &.{ base, "/index.min.json" }), max_index_len);
            return .{ .bytes = bytes, .store = .{
                .index_url = canonical,
                .legacy = true,
                .name = legacy.meta.name,
                .badge = legacy.meta.shortName orelse legacy.meta.name,
                .signing_key = legacy.meta.signingKeyFingerprint,
                .website = legacy.meta.website,
                .extensions = try parseLegacyList(arena, list, base),
            } };
        } else |err| {
            if (err == error.OutOfMemory) return err;
            if (legacy_list != null) return error.InvalidIndex;
        }
    }
    var store = try parseIndex(arena, raw);
    store.index_url = canonical;
    return .{ .store = try resolveExtensionList(h, arena, store), .bytes = bytes };
}

/// Completes either a freshly downloaded or cached index with its external list.
pub fn resolveExtensionList(h: *Http, arena: Allocator, index: Store) Error!Store {
    var store = index;
    if (store.extensions.len == 0) if (store.extension_list_url) |list_url| {
        const list_bytes = try h.getAlloc(arena, list_url, max_index_len);
        store.extensions = try parseExtensionList(arena, list_bytes);
    };
    return store;
}

fn httpError(err: anyerror) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.NetworkError,
    };
}

pub fn signerFingerprints(gpa: Allocator, io: Io, path: []const u8) ![]Fingerprint {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [16 << 10]u8 = undefined;
    var reader = file.reader(io, &buf);

    var out: std.ArrayList(Fingerprint) = .empty;
    errdefer out.deinit(gpa);

    var it = try std.zip.Iterator.init(&reader);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |entry| {
        const name = try entry.getFilename(&reader, &name_buf, .{});
        if (!isSignatureBlock(name)) continue;
        var block: Io.Writer.Allocating = .init(gpa);
        defer block.deinit();
        try entry.extractTo(&reader, &block.writer);
        try certificateFingerprints(gpa, block.written(), &out);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "HTTP allocation limits apply to decoded bodies and preserve redirects" {
    const Fixture = @import("testing_http.zig").Fixture;
    const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x4b\x4c\x4a\x06\x00\xc2\x41\x24\x35\x03\x00\x00\x00";
    const cases = .{
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc", 3, "abc" },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc", 2, null },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 0, "" },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na", 0, null },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n", 2, null },
        .{ "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 23\r\n\r\n" ++ gzip, 3, "abc" },
        .{ "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 23\r\n\r\n" ++ gzip, 2, null },
        .{ "HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabc", 3, null },
    };
    inline for (cases) |case| {
        var fixture = try Fixture.init(&.{case[0]});
        defer fixture.deinit();
        try fixture.start();
        var http = Http.init(testing.allocator, testing.io);
        defer http.deinit();
        const url = try fixture.url(testing.allocator, "/");
        defer testing.allocator.free(url);
        if (@as(?[]const u8, case[2])) |expected| {
            const body = try http.getAlloc(testing.allocator, url, case[1]);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings(expected, body);
        } else {
            try testing.expectError(error.NetworkError, http.getAlloc(testing.allocator, url, case[1]));
        }
        try fixture.finish();
    }
    var fixture = try Fixture.init(&.{
        "HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
    });
    defer fixture.deinit();
    try fixture.start();
    var http = Http.init(testing.allocator, testing.io);
    defer http.deinit();
    const url = try fixture.url(testing.allocator, "/redirect");
    defer testing.allocator.free(url);
    const body = try http.getAlloc(testing.allocator, url, 3);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("abc", body);
    try fixture.finish();
}

fn testResponse(a: Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
}

test "legacy stores: index.min.json fetches its repo.json, as Mihon does" {
    const Fixture = @import("testing_http.zig").Fixture;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(&.{
        try testResponse(a,
            \\[{"name":"Tachiyomi: MangaDex","pkg":"eu.dex","apk":"dex.apk","lang":"all","code":7,"version":"1.4.7","nsfw":1,
            \\  "sources":[{"id":1,"lang":"en","name":"MangaDex","baseUrl":"https://dex"},{"id":2,"lang":"fr","name":"MangaDex","baseUrl":"https://dex"}]},
            \\ {"name":"Plain","pkg":"eu.plain","apk":"plain.apk","lang":"en","code":1,"version":"1.5.1","nsfw":0}]
        ),
        try testResponse(a,
            \\{"meta":{"name":"Legacy Repo","website":"https://legacy","signingKeyFingerprint":"abcd"}}
        ),
    });
    defer fixture.deinit();
    try fixture.start();
    var http = Http.init(testing.allocator, testing.io);
    defer http.deinit();
    const store = try fetchIndex(&http, a, try fixture.url(a, "/repo/index.min.json"));
    try fixture.finish();
    try testing.expect(store.legacy);
    try testing.expect(std.mem.endsWith(u8, store.index_url, "/repo/repo.json"));
    try testing.expectEqualStrings("Legacy Repo", store.badge);
    try testing.expectEqualStrings("abcd", store.signing_key);
    const dex = store.extensions[0];
    try testing.expectEqualStrings("MangaDex", dex.name);
    try testing.expect(std.mem.endsWith(u8, dex.apk_url, "/repo/apk/dex.apk"));
    try testing.expect(std.mem.endsWith(u8, dex.icon_url, "/repo/icon/eu.dex.png"));
    try testing.expectEqualStrings("1.4", dex.lib_version);
    try testing.expect(dex.nsfw());
    try testing.expectEqualStrings("all", dex.lang());
    // No sources: one with id 0 stands in.
    try testing.expectEqual(0, store.extensions[1].sources[0].id);
    try testing.expectEqualStrings("en", store.extensions[1].lang());
}

test "a legacy repo.json can point to a JSON store, whose list may live elsewhere" {
    const Fixture = @import("testing_http.zig").Fixture;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(&.{});
    defer fixture.deinit();
    const next = try fixture.url(a, "/v2/index.json");
    const list = try fixture.url(a, "/v2/list.json");
    fixture.responses = &.{
        try testResponse(a, try std.fmt.allocPrint(a, "{{\"index_v2\":\"{s}\",\"meta\":{{\"name\":\"Old\",\"website\":\"w\",\"signingKeyFingerprint\":\"x\"}}}}", .{next})),
        try testResponse(a, try std.fmt.allocPrint(a,
            \\{{"name":"New","badgeLabel":"N","signingKey":"beef","contact":{{"website":"https://new","discord":"d"}},"extensionListUrl":"{s}"}}
        , .{list})),
        try testResponse(a,
            \\{"extensions":[{"name":"Weeb","packageName":"eu.weeb","resources":{"apkUrl":"https://new/weeb.apk","iconUrl":"https://new/weeb.png"},
            \\  "extensionLib":"1.6","versionCode":3,"versionName":"1.6.3","contentWarning":"CONTENT_WARNING_MIXED",
            \\  "sources":[{"id":9,"name":"Weeb","language":"en","mirrorUrls":["https://m"]}]}]}
        ),
    };
    try fixture.start();
    var http = Http.init(testing.allocator, testing.io);
    defer http.deinit();
    const store = try fetchIndex(&http, a, try fixture.url(a, "/old/repo.json"));
    try fixture.finish();
    try testing.expect(!store.legacy);
    try testing.expectEqualStrings(next, store.index_url);
    try testing.expectEqualStrings("beef", store.signing_key);
    try testing.expectEqualStrings("d", store.discord.?);
    try testing.expectEqual(ContentWarning.mixed, store.extensions[0].content_warning);
    try testing.expectEqualStrings("https://m", store.extensions[0].sources[0].mirror_urls[0]);
}

test "repository HTTP preserves task cancellation while reading a stalled response" {
    const io = testing.io;
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const Fixture = struct {
        server: *Io.net.Server,
        sent: Io.Event = .unset,
        parked: Io.Event = .unset,
        fn serve(self: *@This()) !void {
            const stream = try self.server.accept(testing.io);
            defer stream.close(testing.io);
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(testing.io, &buffer);
            while ((try reader.interface.takeDelimiterInclusive('\n')).len > 2) {}
            var writer = stream.writer(testing.io, &.{});
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n{\"name\":");
            try writer.interface.flush();
            self.sent.set(testing.io);
            try self.parked.wait(testing.io);
        }
        fn fetch(url: []const u8) !void {
            var http: Http = .init(testing.allocator, testing.io);
            defer http.deinit();
            const bytes = try http.getAlloc(testing.allocator, url, max_index_len);
            defer testing.allocator.free(bytes);
        }
    };
    var fixture: Fixture = .{ .server = &server };
    var serving = try io.concurrent(Fixture.serve, .{&fixture});
    defer _ = serving.cancel(io) catch {};
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/index.json", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);
    var fetching = try io.concurrent(Fixture.fetch, .{url});
    defer _ = fetching.cancel(io) catch {};
    try fixture.sent.wait(io);
    try testing.expectError(error.Canceled, fetching.cancel(io));
}
