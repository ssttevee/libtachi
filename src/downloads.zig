//! Chapter downloads without the JVM. `Runtime.imageRequests` plans each page
//! as the request the source's client would send; this module sends the ones
//! that are safe to send natively, honours the source's rate limits, and hands
//! the rest back to the JVM through a `Fallback`. Pages are saved one at a time
//! and survive failure or cancellation, so a retry resumes the chapter.
const std = @import("std");
const Io = std.Io;
const models = @import("models.zig");
const library = @import("library.zig");

const log = std.log.scoped(.tachi);

pub const ImageRequest = models.ImageRequest;
pub const Rate = models.Rate;

/// Largest image accepted for one page.
pub const max_image = 16 << 20;

/// Whether `request` can be sent without the source's JVM client: no
/// interceptor needs it, and it is a plain HTTP(S) GET.
pub fn nativeEligible(request: ImageRequest) bool {
    return request.fallback == null and std.mem.eql(u8, request.method, "GET") and
        (std.mem.startsWith(u8, request.url, "https://") or std.mem.startsWith(u8, request.url, "http://"));
}

/// Whether every page of a plan can be sent natively, so the JVM is not
/// needed to download it unless a response asks for it.
pub fn allNative(plan: []const ImageRequest) bool {
    for (plan) |request| if (!nativeEligible(request)) return false;
    return true;
}

/// Evenly spaced dispatch, stricter than a permits-per-window burst. A rule's
/// initial wait drains any window the JVM used while planning. Rules are keyed
/// by the source's interceptor, so one shared rule spaces requests across hosts.
pub const Limiter = struct {
    next: std.StringHashMap(i64),

    pub fn init(gpa: std.mem.Allocator) Limiter {
        return .{ .next = .init(gpa) };
    }
    pub fn deinit(self: *Limiter) void {
        self.next.deinit();
    }
    /// Milliseconds to wait before sending a request with `rates` at `now`.
    pub fn delay(self: *Limiter, rates: []const Rate, now: i64) !i64 {
        var until = now;
        for (rates) |rate| {
            if (rate.spacingMs == 0 or rate.initialWaitMs < rate.spacingMs or rate.initialWaitMs > std.math.maxInt(i32)) return error.InvalidRateLimit;
            const entry = try self.next.getOrPut(rate.key);
            if (!entry.found_existing) entry.value_ptr.* = now + @as(i64, @intCast(rate.initialWaitMs));
            until = @max(until, entry.value_ptr.*);
        }
        for (rates) |rate| self.next.getPtr(rate.key).?.* = until + @as(i64, @intCast(rate.spacingMs));
        return until - now;
    }
    pub fn wait(self: *Limiter, io: Io, rates: []const Rate) !void {
        const ms = try self.delay(rates, millis(io));
        if (ms > 0) try io.sleep(.fromMilliseconds(ms), .awake);
    }
};

/// Where one chapter's pages are saved: `downloads/<chapter>/<plan>/0001.png`
/// under the library directory. The plan part identifies the pages by their
/// stable URLs, or by image filename when a source has none (MangaDex changes
/// its node and token on every plan), so a retry only resumes the same pages.
pub const PageStore = struct {
    arena: std.mem.Allocator,
    io: Io,
    /// The library directory.
    dir: []const u8,
    /// Relative to `dir`.
    folder: []const u8,

    pub fn init(arena: std.mem.Allocator, io: Io, dir: []const u8, chapter_id: []const u8, plan: []const ImageRequest) !PageStore {
        var identity = std.hash.Wyhash.init(0);
        identity.update(std.mem.asBytes(&plan.len));
        for (plan) |request| {
            identity.update(std.mem.asBytes(&request.page.index));
            identity.update(request.page.url);
            identity.update(&.{0});
            if (request.page.url.len == 0) {
                const image_url = request.page.imageUrl orelse request.url;
                const path = image_url[0 .. std.mem.indexOfAny(u8, image_url, "?#") orelse image_url.len];
                const filename = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidImageUrl) + 1 ..];
                if (filename.len == 0) return error.InvalidImageUrl;
                identity.update(filename);
            }
            identity.update(&.{0});
        }
        const folder = try std.fmt.allocPrint(arena, "downloads/{x}/{x}", .{ std.hash.Wyhash.hash(0, chapter_id), identity.final() });
        const store: PageStore = .{ .arena = arena, .io = io, .dir = dir, .folder = folder };
        try Io.Dir.cwd().createDirPath(io, try store.absolute(folder));
        return store;
    }
    /// A page's path relative to the library directory.
    pub fn relative(self: PageStore, index: usize, ext: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}/{d:0>4}.{s}", .{ self.folder, index + 1, ext });
    }
    fn absolute(self: PageStore, relative_path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.dir, relative_path });
    }
    /// The saved page, if a complete image is there.
    pub fn complete(self: PageStore, index: usize) !?[]const u8 {
        for ([_][]const u8{ "png", "jpg" }) |ext| {
            const relative_path = try self.relative(index, ext);
            const file = Io.Dir.cwd().openFile(self.io, try self.absolute(relative_path), .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close(self.io);
            var header: [8]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &header, 0);
            if (imageExtension(header[0..n])) |actual| {
                if (std.mem.eql(u8, actual, ext) and try file.length(self.io) > 8) return relative_path;
            }
        }
        return null;
    }
    pub fn temp(self: PageStore, index: usize) ![]const u8 {
        return self.absolute(try self.relative(index, "tmp"));
    }
    fn publish(self: PageStore, index: usize, ext: []const u8) ![]const u8 {
        const relative_path = try self.relative(index, ext);
        try Io.Dir.cwd().rename(try self.temp(index), Io.Dir.cwd(), try self.absolute(relative_path), self.io);
        return relative_path;
    }
    /// Saves a complete image atomically; returns its relative path.
    pub fn put(self: PageStore, index: usize, bytes: []const u8) ![]const u8 {
        const ext = imageExtension(bytes) orelse return error.UnsupportedImageFormat;
        const path = try self.temp(index);
        const file = try Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writePositionalAll(self.io, bytes, 0);
        try file.sync(self.io);
        return self.publish(index, ext);
    }
};

/// "png" or "jpg" from an image's signature; other formats are not supported.
pub fn imageExtension(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "jpg";
    return null;
}

fn millis(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

/// Responses the native client must not handle itself; the page goes back
/// through the source's JVM client instead.
pub const HandBack = error{
    /// The next URL may need different cookies, authentication or rate rules.
    JvmRedirect,
    /// A challenge page or authentication the source's client resolves.
    JvmChallengeOrAuthentication,
    /// A compressed body the source's interceptors may expect to decode.
    JvmContentEncoding,
    /// Not an image: likely a page the source's client must interpret.
    JvmImageResponse,
};

pub const Transfer = struct { path: []const u8, bytes: usize, network_ms: i64, disk_ms: i64, head_ms: i64 = 0 };

/// Sends one planned request with `client` and saves the image as page
/// `index`. Redirects are never followed, so the planned headers (cookies
/// included) never reach another origin.
pub fn fetch(client: *std.http.Client, store: PageStore, index: usize, request: ImageRequest) !Transfer {
    const io = store.io;
    const started = millis(io);
    var bytes: usize = 0;
    var disk_ms: i64 = 0;
    var completed = false;
    defer if (!completed) {
        if (!@import("builtin").is_test) log.info("page {d} incomplete bytes_written={d} network_ms={d} disk_ms={d}", .{ index + 1, bytes, millis(io) - started - disk_ms, disk_ms });
    };
    var req = try client.request(.GET, try std.Uri.parse(request.url), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit, .user_agent = .omit },
        .extra_headers = request.headers,
    });
    defer req.deinit();
    req.sendBodiless() catch |err| return req.connection.?.stream_writer.err orelse err;
    var response = req.receiveHead(&.{}) catch |err| switch (err) {
        error.ReadFailed => return req.connection.?.getReadError().?,
        else => return err,
    };
    if (response.head.status.class() == .redirect) return error.JvmRedirect;
    if (response.head.status == .forbidden or response.head.status == .service_unavailable or response.head.status == .unauthorized) return error.JvmChallengeOrAuthentication;
    if (response.head.status.class() != .success) {
        log.warn("page {d} HTTP status {d}", .{ index + 1, @backingInt(response.head.status) });
        return error.HttpStatusFailure;
    }
    if (response.head.content_encoding != .identity) return error.JvmContentEncoding;
    if (response.head.content_length) |length| if (length > max_image) return error.ImageTooLarge;
    const head_ms = millis(io) - started;
    var buffer: [64 << 10]u8 = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const temp_path = try store.temp(index);
    const file = try Io.Dir.cwd().createFile(io, temp_path, .{});
    defer file.close(io);
    var extension: ?[]const u8 = null;
    while (true) {
        const n = reader.readSliceShort(&buffer) catch {
            // HTTP framing can forward the connection's ReadFailed without
            // setting bodyErr. Preserve the underlying Io cancellation.
            if (response.bodyErr()) |err| return err;
            return req.connection.?.getReadError() orelse error.NetworkReadFailed;
        };
        if (n == 0) break;
        if (bytes == 0) extension = imageExtension(buffer[0..n]) orelse return error.JvmImageResponse;
        if (bytes + n > max_image) return error.ImageTooLarge;
        const disk_start = millis(io);
        try file.writePositionalAll(io, buffer[0..n], bytes);
        disk_ms += millis(io) - disk_start;
        bytes += n;
    }
    if (bytes <= 8) return error.EmptyImage;
    const disk_start = millis(io);
    try file.sync(io);
    const path = try store.publish(index, extension orelse return error.EmptyImage);
    disk_ms += millis(io) - disk_start;
    completed = true;
    return .{ .path = path, .bytes = bytes, .network_ms = millis(io) - started - disk_ms, .disk_ms = disk_ms, .head_ms = head_ms };
}

/// `fetch` with a deadline for the whole page.
pub fn fetchTimed(client: *std.http.Client, store: PageStore, index: usize, request: ImageRequest, timeout: Io.Duration) !Transfer {
    const Result = union(enum) { transfer: anyerror!Transfer, deadline: Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select: Io.Select(Result) = .init(store.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.transfer, fetch, .{ client, store, index, request });
    try select.concurrent(.deadline, sleep, .{ store.io, timeout });
    return switch (try select.await()) {
        .transfer => |result| result,
        .deadline => |result| {
            try result;
            return error.PageTimedOut;
        },
    };
}

fn sleep(io: Io, duration: Io.Duration) Io.Cancelable!void {
    try io.sleep(duration, .awake);
}

/// Fetches one page through the source's JVM client.
pub const Fallback = struct {
    context: *anyopaque,
    /// Returns the image bytes, allocated with `gpa`. `reason` says why the
    /// page cannot be sent natively.
    fetch: *const fn (context: *anyopaque, gpa: std.mem.Allocator, request: ImageRequest, reason: []const u8) anyerror![]u8,
};

/// Reports pages as they finish, including resumed ones.
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, done: usize, total: usize) void,
};

pub const Options = struct {
    /// The library directory; pages are saved under its `downloads/`.
    dir: []const u8,
    chapter_id: []const u8,
    /// PEM roots for HTTPS. Null uses the system's.
    ca_file: ?[]const u8 = null,
    /// How pages that need the JVM are fetched; without one they fail with `error.NeedsJvm`.
    fallback: ?Fallback = null,
    progress: ?Progress = null,
    /// Deadline for each native page.
    page_timeout: Io.Duration = .fromSeconds(120),
};

pub const Stats = struct {
    /// Pages already saved by an earlier attempt.
    resumed: usize = 0,
    /// Pages sent without the JVM.
    native: usize = 0,
    bytes: usize = 0,
    network_ms: i64 = 0,
    disk_ms: i64 = 0,
    elapsed_ms: i64 = 0,
};

pub const Chapter = struct {
    /// Page paths relative to the library directory, in reading order.
    pages: []const []const u8,
    stats: Stats,
};

/// Downloads every page of `plan`, resuming pages an earlier attempt saved.
/// Cancel through `io`: pages saved so far stay for the next attempt.
pub fn downloadChapter(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, plan: []const ImageRequest, options: Options) !Chapter {
    if (plan.len == 0) return error.EmptyChapter;
    const store = try PageStore.init(arena, io, options.dir, options.chapter_id, plan);
    const paths = try arena.alloc([]const u8, plan.len);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var https_ready = false;
    var limiter = Limiter.init(gpa);
    defer limiter.deinit();
    const started = millis(io);
    var stats: Stats = .{};
    for (plan, 0..) |request, i| {
        try io.checkCancel();
        if (try store.complete(i)) |path| {
            paths[i] = path;
            stats.resumed += 1;
        } else {
            try limiter.wait(io, request.rates);
            var transfer: ?Transfer = null;
            var reason = request.fallback orelse "unsupported URI or method";
            if (nativeEligible(request)) {
                if (!https_ready and std.mem.startsWith(u8, request.url, "https://")) {
                    // A given CA file is the only trust source: setting `now`
                    // stops the client rescanning the system's roots.
                    if (options.ca_file) |ca| {
                        const now = Io.Clock.real.now(io);
                        try client.ca_bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), ca);
                        client.now = now;
                    }
                    https_ready = true;
                }
                transfer = fetchTimed(&client, store, i, request, options.page_timeout) catch |err| switch (err) {
                    error.JvmRedirect, error.JvmChallengeOrAuthentication, error.JvmContentEncoding, error.JvmImageResponse => blk: {
                        reason = @errorName(err);
                        break :blk null;
                    },
                    else => return err,
                };
                if (transfer != null) stats.native += 1;
            }
            if (transfer == null) {
                const fallback = options.fallback orelse return error.NeedsJvm;
                log.info("page {d}/{d} JVM fallback: {s}", .{ i + 1, plan.len, reason });
                // Native requests are outside the JVM client's rate window:
                // drain it before switching clients, and again before returning.
                var drain: u64 = 0;
                for (request.rates) |rate| drain = @max(drain, rate.initialWaitMs);
                if (drain > 0) try io.sleep(.fromMilliseconds(@intCast(drain)), .awake);
                const network_start = millis(io);
                const bytes = try fallback.fetch(fallback.context, gpa, request, reason);
                defer gpa.free(bytes);
                if (bytes.len > max_image) return error.ImageTooLarge;
                const disk_start = millis(io);
                const path = try store.put(i, bytes);
                transfer = .{ .path = path, .bytes = bytes.len, .network_ms = disk_start - network_start, .disk_ms = millis(io) - disk_start };
                if (drain > 0) try io.sleep(.fromMilliseconds(@intCast(drain)), .awake);
            }
            const t = transfer.?;
            paths[i] = t.path;
            stats.bytes += t.bytes;
            stats.network_ms += t.network_ms;
            stats.disk_ms += t.disk_ms;
            log.info("page {d}/{d} bytes={d} network_ms={d} head_ms={d} body_ms={d} disk_ms={d}", .{ i + 1, plan.len, t.bytes, t.network_ms, t.head_ms, t.network_ms - t.head_ms, t.disk_ms });
        }
        if (options.progress) |progress| progress.report(progress.context, i + 1, plan.len);
    }
    try io.checkCancel();
    stats.elapsed_ms = millis(io) - started;
    return .{ .pages = paths, .stats = stats };
}

// ---- tests ---------------------------------------------------------------------

test "fallback decision never bypasses non-GETs or extension transforms" {
    const t = std.testing;
    var request: ImageRequest = .{ .page = .{ .index = 0 }, .url = "https://test/image", .method = "GET", .headers = &.{} };
    try t.expect(nativeEligible(request));
    request.method = "POST";
    try t.expect(!nativeEligible(request));
    request.method = "GET";
    request.fallback = "descrambler interceptor";
    try t.expect(!nativeEligible(request));
    request.fallback = null;
    request.url = "data:image/png;base64,...";
    try t.expect(!nativeEligible(request));
}

test "rate limiter drains JVM windows and spaces a shared rule across hosts" {
    var limiter = Limiter.init(std.testing.allocator);
    defer limiter.deinit();
    const rates: []const Rate = &.{.{ .key = "global", .spacingMs = 250, .initialWaitMs = 1000 }};
    try std.testing.expectEqual(1000, try limiter.delay(rates, 0));
    try std.testing.expectEqual(1150, try limiter.delay(rates, 100));
    try std.testing.expectEqual(0, try limiter.delay(rates, 2000));
    try std.testing.expectEqual(250, try limiter.delay(rates, 2000));
}

test "partial pages survive failure and cancel; retry skips only completed pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();
    const root = try temp_dir.dir.realPathFileAlloc(io, ".", a);
    const plan: []const ImageRequest = &.{.{ .page = .{ .index = 0, .imageUrl = "http://test/page" }, .url = "http://test/page", .method = "GET", .headers = &.{} }};
    const store = try PageStore.init(a, io, root, "chapter", plan);
    const first = try store.put(0, "\x89PNG\r\n\x1a\ncompleted-page");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try store.temp(1), .data = "truncated" });
    const retry = try PageStore.init(a, io, root, "chapter", plan);
    try std.testing.expectEqualStrings(first, (try retry.complete(0)).?);
    try std.testing.expect(try retry.complete(1) == null);
    var renewed = plan[0];
    renewed.page.imageUrl = "http://test/page?renewed-token";
    const renewed_store = try PageStore.init(a, io, root, "chapter", &.{renewed});
    try std.testing.expectEqualStrings(first, (try renewed_store.complete(0)).?);
    const changed = try PageStore.init(a, io, root, "different-chapter", plan);
    try std.testing.expect(try changed.complete(0) == null);
}

/// Reads an HTTP request head up to its blank line, so the server never
/// closes a socket with the request unread (which resets the connection).
fn readHead(io: Io, connection: Io.net.Stream) !void {
    var buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &buffer);
    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (line.len <= 2) return;
    }
}

const StallServer = struct {
    io: Io,
    server: *Io.net.Server,
    sent: Io.Event = .unset,
    fn run(self: *StallServer) !void {
        const connection = try self.server.accept(self.io);
        defer connection.close(self.io);
        try readHead(self.io, connection);
        var writer = connection.writer(self.io, &.{});
        writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 200000\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n") catch return writer.err.?;
        self.sent.set(self.io);
        try self.io.sleep(.fromSeconds(60), .awake);
    }
};

test "cancel interrupts a stalled native body immediately and preserves completed pages" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var stall: StallServer = .{ .io = io, .server = &server };
    var serving = try io.concurrent(StallServer.run, .{&stall});
    defer _ = serving.cancel(io) catch {};
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/stall", .{server.socket.address.getPort()});
    const request: ImageRequest = .{ .page = .{ .index = 0 }, .url = url, .method = "GET", .headers = &.{} };
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const store = try PageStore.init(a, io, root, "chapter", &.{request});
    const completed = try store.put(0, "\x89PNG\r\n\x1a\ncomplete");
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var transfer = try io.concurrent(fetch, .{ &client, store, 1, request });
    defer _ = transfer.cancel(io) catch {};
    try stall.sent.wait(io);
    const started = millis(io);
    try std.testing.expectError(error.Canceled, transfer.cancel(io));
    try std.testing.expect(millis(io) - started < 500);
    try std.testing.expectEqualStrings(completed, (try store.complete(0)).?);
    try std.testing.expect(try store.complete(1) == null);
    // Retry replaces the incomplete temp file without losing the first page.
    _ = try store.put(1, "\x89PNG\r\n\x1a\nretry-complete");
    try std.testing.expect(try store.complete(1) != null);
}

test "MangaDex resume ignores node and token but detects changed filenames, order and count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const old: ImageRequest = .{ .page = .{ .index = 0, .imageUrl = "https://old.mangadex.network/old-token/data/hash/001-content.jpg?old#fragment" }, .url = "https://old.mangadex.network/old-token/data/hash/001-content.jpg", .method = "GET", .headers = &.{} };
    var renewed = old;
    renewed.page.imageUrl = "https://new.mangadex.network/new-token/data/hash/001-content.jpg?new#other";
    renewed.url = renewed.page.imageUrl.?;
    const store = try PageStore.init(a, io, root, "chapter", &.{old});
    const path = try store.put(0, "\x89PNG\r\n\x1a\ncompleted-image");
    const retry = try PageStore.init(a, io, root, "chapter", &.{renewed});
    try std.testing.expectEqualStrings(path, (try retry.complete(0)).?);
    var changed = renewed;
    changed.page.imageUrl = "https://new.mangadex.network/token/data/hash/replaced-content.jpg";
    const replaced = try PageStore.init(a, io, root, "chapter", &.{changed});
    try std.testing.expect(try replaced.complete(0) == null);
    changed = renewed;
    changed.page.index = 1;
    const reordered = try PageStore.init(a, io, root, "chapter", &.{changed});
    try std.testing.expect(try reordered.complete(0) == null);
    const longer = try PageStore.init(a, io, root, "chapter", &.{ renewed, changed });
    try std.testing.expect(try longer.complete(0) == null);
    var stable = old;
    stable.page.url = "/stable/page/1";
    const stable_store = try PageStore.init(a, io, root, "stable", &.{stable});
    stable.page.imageUrl = changed.page.imageUrl;
    const stable_retry = try PageStore.init(a, io, root, "stable", &.{stable});
    try std.testing.expectEqualStrings(stable_store.folder, stable_retry.folder);
    stable.page.url = "/stable/page/2";
    const stable_changed = try PageStore.init(a, io, root, "stable", &.{stable});
    try std.testing.expect(!std.mem.eql(u8, stable_store.folder, stable_changed.folder));
}

/// Serves `pages` in order: `.png` bodies, or a redirect for the hand-back test.
const PlanServer = struct {
    io: Io,
    server: *Io.net.Server,
    responses: []const []const u8,
    fn run(self: *PlanServer) !void {
        for (self.responses) |response| {
            const connection = try self.server.accept(self.io);
            defer connection.close(self.io);
            try readHead(self.io, connection);
            var writer = connection.writer(self.io, &.{});
            try writer.interface.writeAll(response);
        }
    }
};

test "downloadChapter sends pages natively, hands redirects to the JVM and resumes" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const png = "\x89PNG\r\n\x1a\nnative-page";
    var plan_server: PlanServer = .{ .io = io, .server = &server, .responses = &.{
        "HTTP/1.1 200 OK\r\nContent-Length: " ++ std.fmt.comptimePrint("{d}", .{png.len}) ++ "\r\nConnection: close\r\n\r\n" ++ png,
        "HTTP/1.1 302 Found\r\nLocation: http://elsewhere/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    } };
    var serving = try io.concurrent(PlanServer.run, .{&plan_server});
    defer _ = serving.cancel(io) catch {};
    const port = server.socket.address.getPort();
    const plan: []const ImageRequest = &.{
        .{ .page = .{ .index = 0, .url = "/p1" }, .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/1", .{port}), .method = "GET", .headers = &.{} },
        .{ .page = .{ .index = 1, .url = "/p2" }, .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/2", .{port}), .method = "GET", .headers = &.{} },
        .{ .page = .{ .index = 2, .url = "/p3" }, .url = "http://unused/3", .method = "GET", .headers = &.{}, .fallback = "descrambler" },
    };
    const Jvm = struct {
        reasons: std.ArrayList([]const u8) = .empty,
        arena: std.mem.Allocator,
        fn fetchPage(context: *anyopaque, gpa: std.mem.Allocator, request: ImageRequest, reason: []const u8) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.reasons.append(self.arena, reason);
            _ = request;
            return gpa.dupe(u8, "\xff\xd8\xffjvm-page");
        }
    };
    var jvm: Jvm = .{ .arena = a };
    const options: Options = .{ .dir = root, .chapter_id = "1:/c", .fallback = .{ .context = &jvm, .fetch = Jvm.fetchPage } };
    const first = try downloadChapter(std.testing.allocator, a, io, plan, options);
    try std.testing.expectEqual(3, first.pages.len);
    try std.testing.expectEqual(1, first.stats.native);
    try std.testing.expectEqualStrings("JvmRedirect", jvm.reasons.items[0]);
    try std.testing.expectEqualStrings("descrambler", jvm.reasons.items[1]);
    try std.testing.expect(std.mem.endsWith(u8, first.pages[0], "0001.png"));
    try std.testing.expect(std.mem.endsWith(u8, first.pages[1], "0002.jpg"));
    // Every page is saved now, so a retry sends nothing.
    const again = try downloadChapter(std.testing.allocator, a, io, plan, .{ .dir = root, .chapter_id = "1:/c" });
    try std.testing.expectEqual(3, again.stats.resumed);
}
