//! Chapter downloads without the JVM. `Runtime.imageRequests` plans each page
//! as the request the source's client would send; this module sends the ones
//! that are safe to send natively, honours the source's rate limits, and hands
//! the rest back to the JVM through a `Fallback`. Pages are saved atomically
//! and survive failure or cancellation, so a retry resumes the chapter.
const std = @import("std");
const Io = std.Io;
const models = @import("models.zig");
const library = @import("library.zig");
const parallel = @import("parallel.zig");
const tachi = @import("tachi.zig");

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
    lock: Io.Mutex = .init,

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
        const ms = blk: {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            break :blk try self.delay(rates, millis(io));
        };
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
        return initIn(arena, io, dir, "downloads", chapter_id, plan);
    }

    /// A store under `root` (relative to `dir`) instead of `downloads`.
    pub fn initIn(arena: std.mem.Allocator, io: Io, dir: []const u8, root: []const u8, chapter_id: []const u8, plan: []const ImageRequest) !PageStore {
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
        const folder = try std.fmt.allocPrint(arena, "{s}/{x}/{x}", .{ root, std.hash.Wyhash.hash(0, chapter_id), identity.final() });
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
        for (image_extensions) |ext| {
            const relative_path = try self.relative(index, ext);
            const file = Io.Dir.cwd().openFile(self.io, try self.absolute(relative_path), .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close(self.io);
            var header: [16]u8 = undefined;
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

/// The file extension for an image's signature: the formats Mihon's
/// reader decodes. Null for anything else (an HTML error page, say).
pub fn imageExtension(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "jpg";
    // JP2 and JPX share the signature box. The raw JPEG 2000 codestream
    // starts with SOC/SIZ markers; normalize both forms to one stored suffix.
    if (std.mem.startsWith(u8, bytes, "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a") or std.mem.startsWith(u8, bytes, "\xff\x4f\xff\x51")) return "jp2";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "webp";
    if (std.mem.startsWith(u8, bytes, "\xff\x0a") or std.mem.startsWith(u8, bytes, "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a")) return "jxl";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        const brand = bytes[8..12];
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return "avif";
        if (std.mem.eql(u8, brand, "heic") or std.mem.eql(u8, brand, "heix") or std.mem.eql(u8, brand, "mif1")) return "heif";
    }
    return null;
}

/// Every extension `imageExtension` gives.
pub const image_extensions = [_][]const u8{ "png", "jpg", "gif", "webp", "jxl", "avif", "heif", "jp2" };

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
    /// page cannot be sent natively. Calls may overlap and must honor Io cancellation.
    /// The callback must keep its own mutable state and allocations thread-safe.
    fetch: *const fn (context: *anyopaque, gpa: std.mem.Allocator, request: ImageRequest, reason: []const u8) anyerror![]u8,
};

/// Reports pages as they finish, including resumed ones.
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, done: usize, total: usize) void,
    /// Each page as it is saved: its index and path relative to the library directory.
    page: ?*const fn (context: *anyopaque, index: usize, path: []const u8) void = null,
    /// Each page that failed for good, with `keep_going`.
    failed: ?*const fn (context: *anyopaque, index: usize, err: anyerror) void = null,
};

/// Mihon's waits before retrying a page: three retries, 2, 4 and 8 seconds.
pub const mihon_retry_ms: []const u32 = &.{ 2000, 4000, 8000 };

pub const Options = struct {
    /// The library directory; pages are saved under its `downloads/`.
    dir: []const u8,
    chapter_id: []const u8,
    /// Maximum pages in flight; callbacks are serialized in completion order.
    parallelism: usize = parallel.default_limit,
    /// PEM roots for HTTPS. Null uses the system's.
    ca_file: ?[]const u8 = null,
    /// How pages that need the JVM are fetched; without one they fail with `error.NeedsJvm`.
    fallback: ?Fallback = null,
    progress: ?Progress = null,
    /// Deadline for each native page.
    page_timeout: Io.Duration = .fromSeconds(120),
    /// Where pages go, relative to `dir`.
    root: []const u8 = "downloads",
    /// Dispatch priority, as a permutation of page indexes; null is first to last.
    order: ?[]const usize = null,
    /// Waits before each retry of a failed page.
    retry_ms: []const u32 = mihon_retry_ms,
    /// Another store whose complete pages are copied instead of fetched, as
    /// Mihon's downloader reuses the reader's cache.
    reuse: ?[]const u8 = null,
    /// Go on past a page that failed for good, as a reader does; its path
    /// is left empty.
    keep_going: bool = false,
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

/// Downloads every page of `plan`, resuming pages an earlier attempt saved
/// and retrying a failed page as Mihon does. Cancel through `io`: pages
/// saved so far stay for the next attempt.
pub fn downloadChapter(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, plan: []const ImageRequest, options: Options) !Chapter {
    if (plan.len == 0) return error.EmptyChapter;
    const store = try PageStore.initIn(arena, io, options.dir, options.root, options.chapter_id, plan);
    const reuse: ?PageStore = if (options.reuse) |root| try PageStore.initIn(arena, io, options.dir, root, options.chapter_id, plan) else null;
    const paths = try arena.alloc([]const u8, plan.len);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var limiter: Limiter = .init(gpa);
    defer limiter.deinit();
    var https: Https = .{};
    const started = millis(io);
    const order = options.order orelse blk: {
        const all = try arena.alloc(usize, plan.len);
        for (all, 0..) |*i, n| i.* = n;
        break :blk all;
    };
    // Duplicate indexes would race the same temporary file; missing ones would
    // leave uninitialized paths in the returned chapter.
    if (order.len != plan.len) return error.InvalidPageOrder;
    const seen = try gpa.alloc(bool, plan.len);
    defer gpa.free(seen);
    @memset(seen, false);
    for (order) |i| {
        if (i >= plan.len or seen[i]) return error.InvalidPageOrder;
        seen[i] = true;
    }
    const Pages = struct {
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        io: Io,
        plan: []const ImageRequest,
        order: []const usize,
        options: Options,
        store: PageStore,
        reuse: ?PageStore,
        client: *std.http.Client,
        limiter: *Limiter,
        https: *Https,
        paths: [][]const u8,
        stats: Stats = .{},
        done: usize = 0,

        const Result = struct {
            path: []const u8 = "",
            stats: Stats = .{},
            failure: ?anyerror = null,
            diagnostic: []const u8 = "",
        };

        fn work(ctx: *@This(), scratch: std.mem.Allocator, index: usize) !Result {
            tachi.setLastError("");
            return ctx.fetch(scratch, ctx.order[index]) catch |err| .{
                .failure = err,
                .diagnostic = try scratch.dupe(u8, tachi.lastError()),
            };
        }
        fn fetch(ctx: *@This(), scratch: std.mem.Allocator, i: usize) !Result {
            var page_store = ctx.store;
            page_store.arena = scratch;
            if (try page_store.complete(i)) |path| return .{ .path = path, .stats = .{ .resumed = 1 } };
            if (ctx.reuse) |original| {
                var cached_store = original;
                cached_store.arena = scratch;
                if (try cached_store.complete(i)) |cached| {
                    const bytes = try Io.Dir.cwd().readFileAlloc(ctx.io, try std.fs.path.join(scratch, &.{ ctx.options.dir, cached }), ctx.gpa, .limited(max_image));
                    defer ctx.gpa.free(bytes);
                    return .{ .path = try page_store.put(i, bytes), .stats = .{ .resumed = 1 } };
                }
            }
            var fetcher: Fetcher = .{ .gpa = ctx.gpa, .io = ctx.io, .store = page_store, .options = ctx.options, .client = ctx.client, .limiter = ctx.limiter, .https = ctx.https };
            var stats: Stats = .{};
            var attempt: usize = 0;
            const transfer = while (true) : (attempt += 1) {
                break fetcher.page(ctx.plan, i, &stats) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => {
                        if (attempt >= ctx.options.retry_ms.len or err == error.NeedsJvm) return err;
                        log.info("page {d}/{d} failed ({s}); retrying in {d} ms", .{ i + 1, ctx.plan.len, @errorName(err), ctx.options.retry_ms[attempt] });
                        try ctx.io.sleep(.fromMilliseconds(ctx.options.retry_ms[attempt]), .awake);
                        continue;
                    },
                };
            };
            stats.bytes = transfer.bytes;
            stats.network_ms = transfer.network_ms;
            stats.disk_ms = transfer.disk_ms;
            log.info("page {d}/{d} bytes={d} network_ms={d} head_ms={d} body_ms={d} disk_ms={d}", .{ i + 1, ctx.plan.len, transfer.bytes, transfer.network_ms, transfer.head_ms, transfer.network_ms - transfer.head_ms, transfer.disk_ms });
            return .{ .path = transfer.path, .stats = stats };
        }
        fn publish(ctx: *@This(), index: usize, result: Result, _: *std.heap.ArenaAllocator) !void {
            const i = ctx.order[index];
            if (result.failure) |err| {
                tachi.setLastError(result.diagnostic);
                switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => if (!ctx.options.keep_going) return err,
                }
                ctx.paths[i] = "";
                if (ctx.options.progress) |progress| if (progress.failed) |report| report(progress.context, i, err);
            } else {
                ctx.paths[i] = try ctx.arena.dupe(u8, result.path);
                inline for (.{ "resumed", "native", "bytes", "network_ms", "disk_ms" }) |field| @field(ctx.stats, field) += @field(result.stats, field);
                if (ctx.options.progress) |progress| if (progress.page) |report| report(progress.context, i, ctx.paths[i]);
            }
            ctx.done += 1;
            if (ctx.options.progress) |progress| progress.report(progress.context, ctx.done, ctx.plan.len);
        }
    };
    var pages: Pages = .{ .gpa = gpa, .arena = arena, .io = io, .plan = plan, .order = order, .options = options, .store = store, .reuse = reuse, .client = &client, .limiter = &limiter, .https = &https, .paths = paths };
    try parallel.run(gpa, io, plan.len, options.parallelism, &pages, Pages.work, Pages.publish);
    pages.stats.elapsed_ms = millis(io) - started;
    return .{ .pages = paths, .stats = pages.stats };
}

// Configure the shared client's trust roots once, before any HTTPS request.
const Https = struct {
    lock: Io.Mutex = .init,
    ready: bool = false,

    fn prepare(self: *Https, client: *std.http.Client, gpa: std.mem.Allocator, io: Io, ca_file: ?[]const u8) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        if (self.ready) return;
        const now = Io.Clock.real.now(io);
        if (ca_file) |ca| {
            try client.ca_bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), ca);
        } else {
            try client.ca_bundle.rescan(gpa, io, now);
        }
        client.now = now;
        self.ready = true;
    }
};

const Fetcher = struct {
    gpa: std.mem.Allocator,
    io: Io,
    store: PageStore,
    options: Options,
    client: *std.http.Client,
    limiter: *Limiter,
    https: *Https,

    /// One attempt at page `i`: natively if it can be, else through the JVM.
    fn page(self: *Fetcher, plan: []const ImageRequest, i: usize, stats: *Stats) !Transfer {
        const io = self.io;
        const request = plan[i];
        try self.limiter.wait(io, request.rates);
        var reason = request.fallback orelse "unsupported URI or method";
        if (nativeEligible(request)) {
            if (std.mem.startsWith(u8, request.url, "https://")) try self.https.prepare(self.client, self.gpa, io, self.options.ca_file);
            if (fetchTimed(self.client, self.store, i, request, self.options.page_timeout)) |transfer| {
                stats.native += 1;
                return transfer;
            } else |err| switch (err) {
                error.JvmRedirect, error.JvmChallengeOrAuthentication, error.JvmContentEncoding, error.JvmImageResponse => reason = @errorName(err),
                else => return err,
            }
        }
        const fallback = self.options.fallback orelse return error.NeedsJvm;
        log.info("page {d}/{d} JVM fallback: {s}", .{ i + 1, plan.len, reason });
        // Native requests are outside the JVM client's rate window:
        // drain it before switching clients, and again before returning.
        var drain: u64 = 0;
        for (request.rates) |rate| drain = @max(drain, rate.initialWaitMs);
        if (drain > 0) try io.sleep(.fromMilliseconds(@intCast(drain)), .awake);
        const network_start = millis(io);
        const bytes = try fallback.fetch(fallback.context, self.gpa, request, reason);
        defer self.gpa.free(bytes);
        if (bytes.len > max_image) return error.ImageTooLarge;
        const disk_start = millis(io);
        const path = try self.store.put(i, bytes);
        const transfer: Transfer = .{ .path = path, .bytes = bytes.len, .network_ms = disk_start - network_start, .disk_ms = millis(io) - disk_start };
        if (drain > 0) try io.sleep(.fromMilliseconds(@intCast(drain)), .awake);
        return transfer;
    }
};

/// Mihon's reader order from page `start`: it, the one before, then the
/// rest forward, then the earlier ones backward.
pub fn readingOrder(arena: std.mem.Allocator, len: usize, start: usize) ![]usize {
    const order = try arena.alloc(usize, len);
    if (len == 0) return order;
    const s = @min(start, len - 1);
    var n: usize = 0;
    order[n] = s;
    n += 1;
    if (s > 0) {
        order[n] = s - 1;
        n += 1;
    }
    for (s + 1..len) |i| {
        order[n] = i;
        n += 1;
    }
    var i = s;
    while (i > 1) {
        i -= 1;
        order[n] = i - 1;
        n += 1;
    }
    return order;
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
    const options: Options = .{ .dir = root, .chapter_id = "1:/c", .parallelism = 1, .fallback = .{ .context = &jvm, .fetch = Jvm.fetchPage } };
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

test "reading order starts at the page, goes back one, forward, then back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(usize, &.{ 3, 2, 4, 5, 1, 0 }, try readingOrder(a, 6, 3));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, try readingOrder(a, 3, 0));
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, try readingOrder(a, 3, 9));
}

test "parallel pages retain reading order, retry independently and publish monotonic progress" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const Fixture = struct {
        io: Io,
        first: Io.Event = .unset,
        release: Io.Event = .unset,
        attempts: [4]std.atomic.Value(usize) = @splat(.init(0)),
        done: usize = 0,
        ready: [3]usize = undefined,
        ready_count: usize = 0,
        failed: usize = 0,

        fn fetchPage(ptr: *anyopaque, gpa: std.mem.Allocator, request: ImageRequest, _: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const i: usize = @intCast(request.page.index);
            const attempt = self.attempts[i].fetchAdd(1, .acq_rel);
            if (i == 0) {
                self.first.set(self.io);
                try self.release.wait(self.io);
            }
            if (i == 1) {
                try self.first.wait(self.io);
                if (attempt == 0) return error.Transient;
            }
            if (i == 2) {
                tachi.setLastError("permanent failure");
                return error.BadPage;
            }
            return std.fmt.allocPrint(gpa, "\x89PNG\r\n\x1a\npage {d}", .{i});
        }
        fn report(ptr: *anyopaque, done: usize, total: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(total == 4 and done == self.done + 1);
            self.done = done;
        }
        fn page(ptr: *anyopaque, index: usize, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ready[self.ready_count] = index;
            self.ready_count += 1;
            if (index == 1) self.release.set(self.io);
        }
        fn failedPage(ptr: *anyopaque, index: usize, err: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(index == 2 and err == error.BadPage);
            std.debug.assert(std.mem.eql(u8, "permanent failure", tachi.lastError()));
            self.failed += 1;
        }
    };
    var fixture: Fixture = .{ .io = io };
    var plan: [4]ImageRequest = undefined;
    for (&plan, 0..) |*request, i| request.* = .{ .page = .{ .index = @intCast(i), .url = try std.fmt.allocPrint(a, "/{d}", .{i}) }, .url = "jvm://page", .method = "GET", .headers = &.{} };
    const chapter = try downloadChapter(std.testing.allocator, a, io, &plan, .{
        .dir = root,
        .chapter_id = "parallel",
        .parallelism = 2,
        .retry_ms = &.{0},
        .keep_going = true,
        .fallback = .{ .context = &fixture, .fetch = Fixture.fetchPage },
        .progress = .{ .context = &fixture, .report = Fixture.report, .page = Fixture.page, .failed = Fixture.failedPage },
    });
    try std.testing.expectEqual(1, fixture.ready[0]);
    try std.testing.expectEqual(4, fixture.done);
    try std.testing.expectEqual(1, fixture.failed);
    try std.testing.expectEqual(2, fixture.attempts[1].load(.acquire));
    try std.testing.expectEqual(2, fixture.attempts[2].load(.acquire));
    try std.testing.expectEqualStrings("", chapter.pages[2]);
    for ([_]usize{ 0, 1, 3 }) |i| {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, chapter.pages[i] }), a, .limited(1024));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "\x89PNG\r\n\x1a\npage {d}", .{i}), bytes);
    }
    const resumed = try downloadChapter(std.testing.allocator, a, io, &plan, .{ .dir = root, .chapter_id = "parallel", .keep_going = true, .retry_ms = &.{} });
    try std.testing.expectEqual(3, resumed.stats.resumed);
}

test "canceling parallel pages joins every transfer and preserves completed files" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const Fixture = struct {
        io: Io,
        dir: []const u8,
        arena: std.mem.Allocator,
        plan: []const ImageRequest,
        both: Io.Event = .unset,
        parked: Io.Event = .unset,
        started: std.atomic.Value(usize) = .init(0),
        ended: std.atomic.Value(usize) = .init(0),
        fn fetchPage(ptr: *anyopaque, _: std.mem.Allocator, _: ImageRequest, _: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            defer _ = self.ended.fetchAdd(1, .acq_rel);
            if (self.started.fetchAdd(1, .acq_rel) == 1) self.both.set(self.io);
            try self.parked.wait(self.io);
            return error.Unexpected;
        }
        fn run(self: *@This()) !Chapter {
            return downloadChapter(std.testing.allocator, self.arena, self.io, self.plan, .{ .dir = self.dir, .chapter_id = "cancel", .parallelism = 3, .fallback = .{ .context = self, .fetch = fetchPage } });
        }
    };
    var plan: [3]ImageRequest = undefined;
    for (&plan, 0..) |*request, i| request.* = .{ .page = .{ .index = @intCast(i), .url = try std.fmt.allocPrint(a, "/{d}", .{i}) }, .url = "jvm://page", .method = "GET", .headers = &.{} };
    const store = try PageStore.init(a, io, root, "cancel", &plan);
    _ = try store.put(2, "\x89PNG\r\n\x1a\nsaved");
    var fixture: Fixture = .{ .io = io, .dir = root, .arena = a, .plan = &plan };
    var future = try io.concurrent(Fixture.run, .{&fixture});
    defer _ = future.cancel(io) catch {};
    try fixture.both.wait(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expectEqual(2, fixture.ended.load(.acquire));
    try std.testing.expect(try store.complete(2) != null);
    try std.testing.expect(try store.complete(0) == null);
    try std.testing.expect(try store.complete(1) == null);
}

test "parallel pages reject incomplete, duplicate and out-of-range dispatch orders" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const request: ImageRequest = .{ .page = .{ .index = 0, .url = "/page" }, .url = "jvm://page", .method = "GET", .headers = &.{} };
    for ([_][]const usize{ &.{0}, &.{ 0, 0 }, &.{ 0, 2 } }) |order| {
        try std.testing.expectError(error.InvalidPageOrder, downloadChapter(std.testing.allocator, a, io, &.{ request, request }, .{ .dir = root, .chapter_id = "invalid", .order = order }));
    }
}

test "native chapter pages establish overlapping HTTP transfers" {
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
    const Fixture = struct {
        io: Io,
        server: *Io.net.Server,
        fn serve(self: *@This()) !void {
            const first = try self.server.accept(self.io);
            defer first.close(self.io);
            try readHead(self.io, first);
            // Respond only after another page has sent its request.
            const second = try self.server.accept(self.io);
            defer second.close(self.io);
            try readHead(self.io, second);
            for ([_]Io.net.Stream{ second, first }) |stream| {
                var writer = stream.writer(self.io, &.{});
                try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n\x89PNG\r\n\x1a\npage");
                try writer.interface.flush();
            }
        }
    };
    var fixture: Fixture = .{ .io = io, .server = &server };
    var serving = try io.concurrent(Fixture.serve, .{&fixture});
    defer _ = serving.cancel(io) catch {};
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/page", .{server.socket.address.getPort()});
    var plan: [2]ImageRequest = undefined;
    for (&plan, 0..) |*request, i| request.* = .{ .page = .{ .index = @intCast(i), .url = try std.fmt.allocPrint(a, "/{d}", .{i}) }, .url = url, .method = "GET", .headers = &.{} };
    const chapter = try downloadChapter(std.testing.allocator, a, io, &plan, .{ .dir = root, .chapter_id = "native-parallel", .parallelism = 2, .retry_ms = &.{} });
    try serving.await(io);
    try std.testing.expectEqual(2, chapter.stats.native);
    try std.testing.expectEqual(24, chapter.stats.bytes);
}

test "JPEG 2000 signatures require complete boxed or codestream headers" {
    for ([_][]const u8{ "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a", "\xff\x4f\xff\x51" }) |signature| {
        try std.testing.expectEqualStrings("jp2", imageExtension(signature).?);
        for (0..signature.len) |length| try std.testing.expect(imageExtension(signature[0..length]) == null);
    }
    try std.testing.expect(imageExtension("\x00\x00\x00\x0cjP  \x0d\x0a\x87\x00") == null);
    try std.testing.expect(imageExtension("\xff\x4f\xff\x50") == null);
}

test "JPEG 2000 downloads publish and resume with the canonical suffix" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const store = try PageStore.init(a, io, root, "chapter", &.{});
    const bytes = "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0aJPEG-2000-page";
    const relative = try store.put(0, bytes);
    try std.testing.expect(std.mem.endsWith(u8, relative, ".jp2"));
    const retry = try PageStore.init(a, io, root, "chapter", &.{});
    try std.testing.expectEqualStrings(relative, (try retry.complete(0)).?);
    try std.testing.expectEqualStrings(bytes, try Io.Dir.cwd().readFileAlloc(io, try store.absolute(relative), a, .limited(1024)));
}
