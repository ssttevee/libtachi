//! Extensions in a helper process. `Client` is a `Backend` that runs each call
//! in a worker it starts on demand; the worker's `main` calls `serve`. A JVM
//! crash then only fails the call, and releasing the worker gives its memory
//! back. The two talk over a socketpair on the worker's fd 3, in frames of a
//! little-endian u32 length and UTF-8 JSON; one call runs at a time.
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi.zig");
const models = @import("tachicore").models;
const be = @import("backend.zig");
const manage = @import("manage.zig");

const log = std.log.scoped(.tachi);

extern "c" fn tachi_spawn(exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, parent_fd: *c_int) c_int;
extern "c" fn tachi_poll(fd: c_int, ms: c_int) c_int;
extern "c" fn tachi_send(fd: c_int, buf: [*]const u8, n: usize, nonblocking: c_int) isize;
extern "c" fn tachi_recv(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn tachi_interrupt(pid: c_int, fd: c_int) void;
extern "c" fn tachi_reap(pid: c_int, block: c_int) c_int;
extern "c" fn tachi_eof(fd: c_int) void;
pub extern "c" fn tachi_now_ms() u64;
pub extern "c" fn tachi_rss_kib() usize;
pub extern "c" fn tachi_free_bytes(path: [*:0]const u8) i64;

// ---- protocol --------------------------------------------------------------------

pub const version = 1;
pub const max_frame = 32 << 20;

pub const Command = struct {
    version: u32 = version,
    id: u64,
    kind: enum { call, cancel, shutdown, crash },
    call: ?be.Call = null,
};

pub const Response = struct {
    version: u32 = version,
    id: u64,
    kind: enum { ready, loading, search_result, result, failure },
    search_result: ?be.SourceSearch = null,
    /// `.loading`: the extension being loaded, or null once it has.
    extension: ?[]const u8 = null,
    reply: ?WireReply = null,
    failure: ?[]const u8 = null,
    failure_code: ?enum { browser_verification_required } = null,
    /// The worker's resident memory when it sent this.
    rss_kib: usize = 0,
};

fn responseError(response: Response) tachi.Error {
    tachi.setLastError(response.failure orelse "worker call failed");
    if (response.failure_code == .browser_verification_required) return error.BrowserVerificationRequired;
    return error.ExtensionError;
}

/// `be.Reply` with the image as base64, so frames stay valid JSON.
pub const WireReply = struct {
    sources: []const models.SourceInfo = &.{},
    extensions: []const manage.RepoEntry = &.{},
    extension_updates: ?manage.UpdateResult = null,
    page: ?models.MangasPage = null,
    update: ?models.MangaUpdate = null,
    pages: []const models.Page = &.{},
    image_requests: []const models.ImageRequest = &.{},
    image_base64: ?[]const u8 = null,
    filters: []const models.Filter = &.{},
    mangas: []const models.Manga = &.{},
    preferences: []const models.Preference = &.{},

    fn from(arena: std.mem.Allocator, value: be.Reply) !WireReply {
        var wire: WireReply = undefined;
        inline for (@typeInfo(be.Reply).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "image")) continue;
            @field(wire, name) = @field(value, name);
        }
        wire.image_base64 = if (value.image) |bytes| blk: {
            const encoder = std.base64.standard.Encoder;
            break :blk encoder.encode(try arena.alloc(u8, encoder.calcSize(bytes.len)), bytes);
        } else null;
        return wire;
    }

    fn reply(self: WireReply, arena: std.mem.Allocator) !be.Reply {
        var out: be.Reply = undefined;
        inline for (@typeInfo(be.Reply).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "image")) continue;
            @field(out, name) = @field(self, name);
        }
        out.image = if (self.image_base64) |encoded| blk: {
            const decoder = std.base64.standard.Decoder;
            const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(encoded));
            try decoder.decode(bytes, encoded);
            break :blk bytes;
        } else null;
        return out;
    }
};

pub const parse_options: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };

// ---- framing -----------------------------------------------------------------------

/// Blocking send, for the worker side.
pub fn send(fd: c_int, gpa: std.mem.Allocator, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(bytes);
    if (bytes.len > max_frame) return error.ProtocolFrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    for ([_][]const u8{ &header, bytes }) |part| {
        var at: usize = 0;
        while (at < part.len) {
            const n = tachi_send(fd, part[at..].ptr, part.len - at, 0);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n <= 0) return error.WorkerCrashed;
            at += @intCast(n);
        }
    }
}

/// Waits up to `timeout_ms` for something to read.
pub fn ready(fd: c_int, timeout_ms: c_int) !bool {
    const n = tachi_poll(fd, timeout_ms);
    if (n < 0) return error.WorkerCrashed;
    return n > 0;
}

fn readAll(fd: c_int, buffer: []u8) !void {
    var at: usize = 0;
    while (at < buffer.len) {
        if (!try ready(fd, 300_000)) return error.WorkerTimedOut;
        const n = tachi_recv(fd, buffer[at..].ptr, buffer.len - at);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.WorkerCrashed;
        at += @intCast(n);
    }
}

/// Blocking receive, for the worker side.
pub fn receive(comptime T: type, fd: c_int, arena: std.mem.Allocator) !T {
    var header: [4]u8 = undefined;
    try readAll(fd, &header);
    const len = std.mem.readInt(u32, &header, .little);
    if (len == 0 or len > max_frame) return error.InvalidProtocolFrame;
    const bytes = try arena.alloc(u8, len);
    try readAll(fd, bytes);
    return std.json.parseFromSliceLeaky(T, arena, bytes, parse_options);
}

fn stream(fd: c_int) Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } };
}

/// Cancelable send through `io`, for the caller's side.
pub fn sendIo(io: Io, fd: c_int, gpa: std.mem.Allocator, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(bytes);
    if (bytes.len > max_frame) return error.ProtocolFrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    var writer = stream(fd).writer(io, &.{});
    writer.interface.writeAll(&header) catch return writer.err orelse error.WorkerCrashed;
    writer.interface.writeAll(bytes) catch return writer.err orelse error.WorkerCrashed;
}

fn readAllIo(io: Io, fd: c_int, buffer: []u8) !void {
    var at: usize = 0;
    while (at < buffer.len) {
        var data: [1][]u8 = .{buffer[at..]};
        const result = stream(fd).readWithControl(io, &data, &.{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.WorkerCrashed,
        };
        if (result.data_len == 0) return error.WorkerCrashed;
        at += result.data_len;
    }
}

/// Cancelable receive through `io`, for the caller's side.
pub fn receiveIo(comptime T: type, io: Io, fd: c_int, arena: std.mem.Allocator) !T {
    var header: [4]u8 = undefined;
    try readAllIo(io, fd, &header);
    const len = std.mem.readInt(u32, &header, .little);
    if (len == 0 or len > max_frame) return error.InvalidProtocolFrame;
    const bytes = try arena.alloc(u8, len);
    try readAllIo(io, fd, bytes);
    return std.json.parseFromSliceLeaky(T, arena, bytes, parse_options);
}

/// Sends a cancel without blocking, so a stuck worker cannot stall the caller.
fn cancelNow(fd: c_int, id: u64) void {
    var buffer: [128]u8 = undefined;
    const json = std.fmt.bufPrint(buffer[4..], "{{\"version\":{d},\"id\":{d},\"kind\":\"cancel\"}}", .{ version, id }) catch return;
    std.mem.writeInt(u32, buffer[0..4], @intCast(json.len), .little);
    _ = tachi_send(fd, &buffer, json.len + 4, 1);
}

// ---- client ------------------------------------------------------------------------

/// A `Backend` that runs calls in a worker process it starts when needed.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    spawner: Spawner,
    mutex: std.atomic.Mutex = .unlocked,
    /// Held for the whole of a call: the worker runs one at a time.
    call_lock: Io.Mutex = .init,
    /// Bumped by `cancel`, so a call started before it never spawns or
    /// retries a worker after it.
    cancels: std.atomic.Value(u32) = .init(0),
    interrupted: std.atomic.Value(bool) = .init(false),
    is_ready: std.atomic.Value(bool) = .init(false),
    pid: c_int = -1,
    fd: c_int = -1,
    /// A released worker still exiting (it may be saving its startup cache).
    retiring: c_int = -1,
    spawned_ms: u64 = 0,
    next_id: u64 = 1,
    /// The worker's memory at its last response, in KiB.
    last_rss_kib: std.atomic.Value(usize) = .init(0),
    /// Milliseconds from spawn to ready for the last start.
    last_start_ms: std.atomic.Value(u32) = .init(0),
    /// Makes the next call crash its worker (needs `ServeOptions.testing`).
    test_crash_next: bool = false,

    pub const Options = struct {
        /// The worker executable; it calls `serve`.
        exe: []const u8,
        /// Arguments after the executable name.
        args: []const []const u8 = &.{},
        /// A program that runs the worker, such as an emulator; the worker
        /// executable and its arguments follow it.
        wrapper: ?[]const u8 = null,
        /// How long a released worker may take to exit (saving its startup
        /// cache) before the next start kills it.
        retire_ms: u64 = 15_000,
    };

    /// Starts the thread that spawns workers. `options` must outlive the client.
    pub fn init(self: *Client, gpa: std.mem.Allocator, io: Io, options: Options) !void {
        self.* = .{ .gpa = gpa, .io = io, .options = options, .spawner = undefined };
        try self.spawner.start(io);
    }

    pub fn deinit(self: *Client) void {
        self.close();
        self.reapRetiring(0);
        self.spawner.stop();
    }

    pub fn backend(self: *Client) be.Backend {
        return .{ .ptr = self, .vtable = &.{ .run = runErased, .search = searchErased, .warm = warmErased, .cancel = cancelErased, .release = releaseErased, .idle = idleErased } };
    }

    fn lock(self: *Client) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// Whether a worker is running.
    pub fn alive(self: *Client) bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.pid > 0 and tachi_reap(self.pid, 0) != 0) {
            if (self.fd >= 0) _ = std.c.close(self.fd);
            self.fd = -1;
            self.pid = -1;
        }
        return self.pid > 0;
    }

    /// Whether the running worker has started its JVM.
    pub fn workerReady(self: *Client) bool {
        return self.is_ready.load(.acquire);
    }

    /// The running worker's process id, or -1.
    pub fn workerPid(self: *Client) c_int {
        return self.pid;
    }

    /// Stops the worker and refuses further calls until `resume`. For an app
    /// going to the background or exiting.
    pub fn interrupt(self: *Client) void {
        self.interrupted.store(true, .release);
        self.lock();
        defer self.mutex.unlock();
        tachi_interrupt(self.pid, self.fd);
    }

    pub fn @"resume"(self: *Client) void {
        self.interrupted.store(false, .release);
    }

    /// Kills the worker, if any, and forgets it.
    pub fn close(self: *Client) void {
        self.lock();
        defer self.mutex.unlock();
        tachi_interrupt(self.pid, self.fd);
        if (self.pid > 0) _ = tachi_reap(self.pid, 1);
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.pid = -1;
        self.fd = -1;
        self.is_ready.store(false, .release);
    }

    /// Interrupts the call in progress: wakes its reader and kills the
    /// worker. Descriptors close once the call has stopped using them.
    pub fn cancel(self: *Client) void {
        _ = self.cancels.fetchAdd(1, .acq_rel);
        self.lock();
        defer self.mutex.unlock();
        tachi_interrupt(self.pid, self.fd);
    }

    /// Asks the worker to exit once it has saved anything worth keeping,
    /// without waiting. The next call starts a new one. Does nothing while a
    /// call is running.
    pub fn release(self: *Client) void {
        if (!self.call_lock.tryLock()) return;
        defer self.call_lock.unlock(self.io);
        self.lock();
        defer self.mutex.unlock();
        if (self.pid <= 0) return;
        if (self.fd >= 0) {
            send(self.fd, self.gpa, Command{ .id = 0, .kind = .shutdown }) catch {};
            _ = std.c.close(self.fd);
        }
        self.retiring = self.pid;
        self.pid = -1;
        self.fd = -1;
        self.is_ready.store(false, .release);
    }

    /// Waits up to `ms` for a released worker to exit, then kills it.
    fn reapRetiring(self: *Client, ms: u64) void {
        if (self.retiring <= 0) return;
        const until = tachi_now_ms() + ms;
        while (tachi_reap(self.retiring, 0) == 0) {
            if (tachi_now_ms() >= until) {
                tachi_interrupt(self.retiring, -1);
                _ = tachi_reap(self.retiring, 1);
                break;
            }
            self.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        self.retiring = -1;
    }

    fn waitExit(self: *Client, ms: u64) bool {
        const until = tachi_now_ms() + ms;
        while (self.pid > 0 and tachi_now_ms() < until) {
            if (tachi_reap(self.pid, 0) != 0) {
                self.pid = -1;
                return true;
            }
            _ = ready(self.fd, 20) catch false;
        }
        return self.pid <= 0;
    }

    /// Asks the worker to exit, waits briefly, and kills it if it has not.
    pub fn shutdown(self: *Client) void {
        if (self.fd >= 0) send(self.fd, self.gpa, Command{ .id = 0, .kind = .shutdown }) catch {};
        _ = self.waitExit(1500);
        self.close();
    }

    /// Starts a worker unless one is running.
    pub fn ensure(self: *Client) !void {
        return self.ensureSince(self.cancels.load(.acquire));
    }

    fn ensureSince(self: *Client, epoch: u32) !void {
        if (self.interrupted.load(.acquire)) return error.WorkerStopped;
        {
            self.lock();
            defer self.mutex.unlock();
            if (self.pid > 0 and tachi_reap(self.pid, 0) != 0) {
                _ = std.c.close(self.fd);
                self.fd = -1;
                self.pid = -1;
            }
            if (self.pid > 0) return;
        }
        // Never two JVMs at once: let a released worker finish first.
        self.reapRetiring(self.options.retire_ms);
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        if (self.options.wrapper) |wrapper| try argv.append(a, (try a.dupeSentinel(u8, wrapper, 0)).ptr);
        try argv.append(a, (try a.dupeSentinel(u8, self.options.exe, 0)).ptr);
        for (self.options.args) |arg| try argv.append(a, (try a.dupeSentinel(u8, arg, 0)).ptr);
        try argv.append(a, null);
        const spawned = try self.spawner.spawn(argv.items[0].?, @ptrCast(argv.items.ptr));
        self.lock();
        defer self.mutex.unlock();
        if (self.cancels.load(.acquire) != epoch) {
            tachi_interrupt(spawned.pid, spawned.fd);
            _ = tachi_reap(spawned.pid, 1);
            _ = std.c.close(spawned.fd);
            return error.Canceled;
        }
        self.pid = spawned.pid;
        self.fd = spawned.fd;
        self.is_ready.store(false, .release);
        self.spawned_ms = tachi_now_ms();
    }

    pub fn run(self: *Client, arena: std.mem.Allocator, call: be.Call, status: ?be.Status) !be.Reply {
        const epoch = self.cancels.load(.acquire);
        try self.call_lock.lock(self.io);
        defer self.call_lock.unlock(self.io);
        const was_ready = self.alive() and self.workerReady();
        if (!was_ready) if (status) |s| s.starting(s.context);
        return self.runOnce(arena, call, status, epoch) catch |err| switch (err) {
            // An idle worker exits on its own; one that went away before
            // answering anything was retiring, not crashing. Start another.
            error.WorkerRetired => {
                if (self.cancels.load(.acquire) != epoch) return error.Canceled;
                if (status) |s| s.starting(s.context);
                return self.runOnce(arena, call, status, epoch);
            },
            else => return err,
        };
    }

    fn runOnce(self: *Client, arena: std.mem.Allocator, call: be.Call, status: ?be.Status, epoch: u32) !be.Reply {
        const was_ready = self.alive() and self.workerReady();
        try self.ensureSince(epoch);
        if (self.pid <= 0 or self.interrupted.load(.acquire)) return error.WorkerStopped;
        const id = self.next_id;
        self.next_id += 1;
        var answered = false;
        errdefer {
            cancelNow(self.fd, id);
            _ = self.waitExit(75);
            // Stop the reader through Io first; then terminate a worker stuck in
            // JNI. No frame of this call is ever read after cancellation.
            self.close();
        }
        const crash = self.test_crash_next;
        self.test_crash_next = false;
        const command: Command = if (crash) .{ .id = id, .kind = .crash } else .{ .id = id, .kind = .call, .call = call };
        sendIo(self.io, self.fd, arena, command) catch |err| {
            if (err == error.WorkerCrashed and was_ready) return error.WorkerRetired;
            return err;
        };
        while (true) {
            const response = receiveIo(Response, self.io, self.fd, arena) catch |err| {
                if (err == error.WorkerCrashed and was_ready and !answered and !crash) return error.WorkerRetired;
                return err;
            };
            answered = true;
            if (response.version != version or response.id != id) return error.WorkerProtocolMismatch;
            self.last_rss_kib.store(response.rss_kib, .release);
            switch (response.kind) {
                .ready => {
                    if (!self.is_ready.swap(true, .acq_rel)) {
                        self.last_start_ms.store(@intCast(@min(tachi_now_ms() - self.spawned_ms, std.math.maxInt(u32))), .release);
                        log.info("worker ready startup_ms={d}", .{tachi_now_ms() - self.spawned_ms});
                    }
                    if (status) |s| s.ready(s.context);
                },
                .loading => if (status) |s| s.loading(s.context, response.extension),
                .search_result => if (status) |s| {
                    if (s.search_result) |callback| try callback(s.context, response.search_result orelse return error.InvalidWorkerReply);
                },
                .failure => {
                    return responseError(response);
                },
                .result => return (response.reply orelse return error.InvalidWorkerReply).reply(arena),
            }
        }
    }

    /// Test hook: closes the channel and expects the worker to exit.
    pub fn testEof(self: *Client) !void {
        if (self.fd < 0) return error.NoWorker;
        tachi_eof(self.fd);
        if (!self.waitExit(1500)) return error.WorkerIgnoredEof;
        self.close();
    }

    /// Test hook: expects the worker to exit by itself after its idle time.
    pub fn testIdle(self: *Client) !void {
        if (!self.waitExit(1500 + 60_000)) return error.WorkerIgnoredIdleTimeout;
        self.close();
    }

    fn runErased(ptr: *anyopaque, arena: std.mem.Allocator, call: be.Call, status: ?be.Status) anyerror!be.Reply {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.run(arena, call, status);
    }
    fn searchErased(ptr: *anyopaque, arena: std.mem.Allocator, request: be.Search, status: be.Status) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        _ = try self.run(arena, .{ .search = request }, status);
    }
    fn warmErased(ptr: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.alive() and self.workerReady();
    }
    fn cancelErased(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.cancel();
    }
    fn releaseErased(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.release();
    }
    // The worker saves its startup cache when it is idle itself.
    fn idleErased(_: *anyopaque) void {}
};

/// Forks workers from one long-lived thread. On Linux a worker dies with the
/// thread that forked it (PR_SET_PDEATHSIG), and the threads calls run on may
/// come and go, so they ask this thread instead.
const Spawner = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    request: ?*Request = null,
    stopping: bool = false,
    thread: std.Thread = undefined,

    const Request = struct {
        exe: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        pid: c_int = -1,
        fd: c_int = -1,
        done: bool = false,
    };

    fn start(self: *Spawner, io: Io) !void {
        self.* = .{ .io = io };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    fn stop(self: *Spawner) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
    }

    fn loop(self: *Spawner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (self.request == null and !self.stopping) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) return;
            const request = self.request.?;
            var fd: c_int = -1;
            request.pid = tachi_spawn(request.exe, request.argv, &fd);
            request.fd = fd;
            request.done = true;
            self.request = null;
            self.condition.broadcast(self.io);
        }
    }

    fn spawn(self: *Spawner, exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) !struct { pid: c_int, fd: c_int } {
        var request: Request = .{ .exe = exe, .argv = argv };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.request != null) self.condition.waitUncancelable(self.io, &self.mutex);
        self.request = &request;
        self.condition.broadcast(self.io);
        while (!request.done) self.condition.waitUncancelable(self.io, &self.mutex);
        if (request.pid < 0) return error.WorkerStartFailed;
        return .{ .pid = request.pid, .fd = request.fd };
    }
};

// ---- worker side -------------------------------------------------------------------

pub const ServeOptions = struct {
    /// The channel to the client; `tachi_spawn` puts it on fd 3.
    fd: c_int = 3,
    /// Exit after this long without a call; zero keeps the worker alive.
    idle_exit_ms: u64 = 60_000,
    /// Save the runtime's startup cache once idle this long after a call.
    cache_idle_ms: u64 = 1_500,
    /// Accept the `crash` command, for tests.
    testing: bool = false,
    /// Runs after each call, before its result is sent; for diagnostics.
    after_call: ?*const fn () void = null,
};

/// The worker's main loop: runs calls on `runtime` until the client closes
/// the channel, asks it to shut down, cancels a call, or it is idle too long.
/// Never returns.
pub fn serve(gpa: std.mem.Allocator, runtime: *be.InProcess, options: ServeOptions) noreturn {
    serveLoop(gpa, runtime, options) catch |err| {
        log.err("worker: {s}", .{@errorName(err)});
        std.c._exit(1);
    };
    std.c._exit(0);
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    runtime: *be.InProcess,
    call: be.Call,
    reply: ?be.Reply = null,
    failure: ?[]const u8 = null,
    failure_code: @FieldType(Response, "failure_code") = null,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    is_ready: std.atomic.Value(bool) = .init(false),
    /// Extension loads reported so far, in order (null once one has
    /// loaded): a load can start and finish between two polls, and the
    /// client must still hear about it.
    events_lock: std.atomic.Mutex = .unlocked,
    events: std.ArrayList(?[]const u8) = .empty,
    searches: std.ArrayList(be.SourceSearch) = .empty,

    fn work(self: *Job) void {
        defer self.done.store(true, .release);
        const status: be.Status = .{ .context = self, .starting = starting, .ready = isReady, .loading = loading, .search_result = searchResult };
        self.reply = self.runtime.run(self.arena.allocator(), self.call, status) catch |err| blk: {
            self.failure_code = if (err == error.BrowserVerificationRequired) .browser_verification_required else null;
            self.failure = std.fmt.allocPrint(self.arena.allocator(), "{s}: {s}", .{ @errorName(err), tachi.lastError() }) catch "Operation failed (out of memory)";
            log.warn("{s}", .{self.failure.?});
            break :blk null;
        };
    }
    fn starting(_: *anyopaque) void {}
    fn isReady(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.is_ready.store(true, .release);
    }
    fn loading(context: *anyopaque, extension: ?[]const u8) void {
        const self: *Job = @ptrCast(@alignCast(context));
        while (!self.events_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.events_lock.unlock();
        const name = if (extension) |n| self.arena.allocator().dupe(u8, n) catch return else null;
        self.events.append(self.arena.allocator(), name) catch {};
    }

    fn searchResult(context: *anyopaque, result: be.SourceSearch) !void {
        const self: *Job = @ptrCast(@alignCast(context));
        while (!self.events_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.events_lock.unlock();
        const a = self.arena.allocator();
        const json = try std.json.Stringify.valueAlloc(a, result, .{});
        try self.searches.append(a, try std.json.parseFromSliceLeaky(be.SourceSearch, a, json, parse_options));
    }

    fn takeSearches(self: *Job, out: *std.ArrayList(be.SourceSearch), gpa: std.mem.Allocator) !void {
        while (!self.events_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.events_lock.unlock();
        try out.appendSlice(gpa, self.searches.items);
        self.searches.clearRetainingCapacity();
    }

    /// Takes the events reported since the last call, into `out`.
    fn takeEvents(self: *Job, out: *std.ArrayList(?[]const u8), gpa: std.mem.Allocator) !void {
        while (!self.events_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.events_lock.unlock();
        try out.appendSlice(gpa, self.events.items);
        self.events.clearRetainingCapacity();
    }
};

fn serveLoop(gpa: std.mem.Allocator, runtime: *be.InProcess, options: ServeOptions) !void {
    const fd = options.fd;
    const cache_idle_ms = if (options.idle_exit_ms == 0) options.cache_idle_ms else @min(options.cache_idle_ms, options.idle_exit_ms / 2);
    var active: ?*Job = null;
    var id: u64 = 0;
    var last_activity = tachi_now_ms();
    var sent_ready = false;
    var calls: usize = 0;
    while (true) {
        if (active) |job| {
            if (!sent_ready and job.is_ready.load(.acquire)) {
                try send(fd, gpa, Response{ .id = id, .kind = .ready, .rss_kib = tachi_rss_kib() });
                sent_ready = true;
            }
            var events: std.ArrayList(?[]const u8) = .empty;
            defer events.deinit(gpa);
            try job.takeEvents(&events, gpa);
            for (events.items) |extension| try send(fd, gpa, Response{ .id = id, .kind = .loading, .extension = extension, .rss_kib = tachi_rss_kib() });
            const done = job.done.load(.acquire);
            // Acquire completion before draining, so the final result cannot
            // overtake a source that finished since the previous poll.
            var searches: std.ArrayList(be.SourceSearch) = .empty;
            defer searches.deinit(gpa);
            try job.takeSearches(&searches, gpa);
            for (searches.items) |result| try send(fd, gpa, Response{ .id = id, .kind = .search_result, .search_result = result, .rss_kib = tachi_rss_kib() });
            if (done) {
                job.thread.?.join();
                if (options.after_call) |after| after();
                const reply: ?WireReply = if (job.reply) |r| try WireReply.from(job.arena.allocator(), r) else null;
                try send(fd, gpa, Response{ .id = id, .kind = if (job.failure != null) .failure else .result, .failure = job.failure, .failure_code = job.failure_code, .reply = reply, .rss_kib = tachi_rss_kib() });
                job.arena.deinit();
                gpa.destroy(job);
                active = null;
                calls += 1;
                last_activity = tachi_now_ms();
            }
        } else if (options.idle_exit_ms > 0 and tachi_now_ms() - last_activity >= options.idle_exit_ms) {
            return;
        } else if (calls > 0 and tachi_now_ms() - last_activity >= cache_idle_ms) {
            runtime.idle();
        }
        if (!try ready(fd, 100)) continue;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        // End of the channel also stops a call in flight immediately.
        const command = receive(Command, fd, arena.allocator()) catch return;
        if (command.version != version) {
            try send(fd, gpa, Response{ .id = command.id, .kind = .failure, .failure = "Unsupported worker protocol version" });
            continue;
        }
        switch (command.kind) {
            .shutdown => {
                if (active == null) runtime.idle();
                return;
            },
            .cancel => if (active != null and command.id == id) {
                runtime.cancel();
                return;
            },
            .crash => {
                if (options.testing) std.c._exit(70);
                return error.InvalidCommand;
            },
            .call => {
                if (active != null) return error.ConcurrentWorkerCall;
                id = command.id;
                const job = try gpa.create(Job);
                job.* = .{ .arena = .init(gpa), .runtime = runtime, .call = undefined };
                // The command's arena ends with this iteration; the job keeps a copy.
                const json = try std.json.Stringify.valueAlloc(job.arena.allocator(), command.call orelse return error.InvalidCommand, .{});
                job.call = try std.json.parseFromSliceLeaky(be.Call, job.arena.allocator(), json, parse_options);
                job.thread = try std.Thread.spawn(.{}, Job.work, .{job});
                active = job;
            },
        }
    }
}

test "replies keep images intact across the wire" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image = "\xff\xd8\xff\x00binary\x80\xfe";
    const wire = try WireReply.from(a, .{ .image = image, .mangas = &.{.{ .url = "/m", .title = "M" }} });
    const json = try std.json.Stringify.valueAlloc(a, Response{ .id = 1, .kind = .result, .reply = wire }, .{});
    const parsed = try std.json.parseFromSliceLeaky(Response, a, json, parse_options);
    const reply = try parsed.reply.?.reply(a);
    try std.testing.expectEqualSlices(u8, image, reply.image.?);
    try std.testing.expectEqualStrings("M", reply.mangas[0].title);
}

test "calls round-trip as JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const command: Command = .{ .id = 7, .kind = .call, .call = .{ .browse = .{ .source = 42, .page = 2, .kind = .{ .search = .{ .query = "one piece" } } } } };
    const json = try std.json.Stringify.valueAlloc(a, command, .{});
    const parsed = try std.json.parseFromSliceLeaky(Command, a, json, parse_options);
    try std.testing.expectEqual(42, parsed.call.?.browse.source);
    try std.testing.expectEqualStrings("one piece", parsed.call.?.browse.kind.search.query);
}

test "worker failures preserve typed browser verification without guessing from diagnostics" {
    const t = std.testing;
    const diagnostic = "BrowserVerificationRequired: Cloudflare challenge on images.example";
    const json = try std.json.Stringify.valueAlloc(t.allocator, Response{ .id = 1, .kind = .failure, .failure = diagnostic, .failure_code = .browser_verification_required }, .{});
    defer t.allocator.free(json);
    const parsed = try std.json.parseFromSlice(Response, t.allocator, json, models.parse_options);
    defer parsed.deinit();
    try t.expectEqual(error.BrowserVerificationRequired, responseError(parsed.value));
    try t.expectEqualStrings(diagnostic, tachi.lastError());
    try t.expectEqual(error.ExtensionError, responseError(.{ .id = 1, .kind = .failure, .failure = diagnostic }));
}

test "parallel search requests and partial results survive worker framing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const command: Command = .{ .id = 9, .kind = .call, .call = .{ .search = .{ .sources = &.{ 1, 2 }, .query = "Title", .parallelism = 2 } } };
    const request_json = try std.json.Stringify.valueAlloc(a, command, .{});
    const request = try std.json.parseFromSliceLeaky(Command, a, request_json, parse_options);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, request.call.?.search.sources);
    try std.testing.expectEqualStrings("Title", request.call.?.search.query);
    const response: Response = .{ .id = 9, .kind = .search_result, .search_result = .{ .source = 2, .mangas = &.{.{ .url = "/two", .title = "Two" }} } };
    const json = try std.json.Stringify.valueAlloc(a, response, .{});
    const parsed = try std.json.parseFromSliceLeaky(Response, a, json, parse_options);
    try std.testing.expectEqual(.search_result, parsed.kind);
    try std.testing.expectEqual(2, parsed.search_result.?.source);
    try std.testing.expectEqualStrings("Two", parsed.search_result.?.mangas[0].title);
}
