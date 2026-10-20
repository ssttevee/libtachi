//! Sockets for the host's OkHttp clients, with TLS done in Zig.
//!
//! JVMs without a JIT (Zero on 32-bit ARM) run Java's TLS interpreted, where
//! loading the trust store and one handshake take seconds each. The host's
//! `NativeTransport` calls these functions instead; OkHttp keeps routing,
//! cookies, redirects and interceptors, and only the bytes go through here.
//! Certificates are verified against the runtime's CA bundle by `std.crypto.tls`.
const std = @import("std");
const Io = std.Io;
const tls = std.crypto.tls;
const jni = @import("jni.zig");

const State = struct {
    gpa: std.mem.Allocator,
    io: Io,
    ca_file: ?[]const u8,
    ca_lock: Io.RwLock = .init,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_loaded: bool = false,
    ca_mutex: Io.Mutex = .init,
};

var state: ?State = null;

const Connection = struct {
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    tls: ?tls.Client = null,
    socket_read: [tls.Client.min_buffer_len]u8 = undefined,
    socket_write: [tls.Client.min_buffer_len]u8 = undefined,
    plain_read: [tls.Client.min_buffer_len]u8 = undefined,
    plain_write: [4096]u8 = undefined,

    fn input(c: *Connection) *Io.Reader {
        return if (c.tls) |*t| &t.reader else &c.reader.interface;
    }
    fn output(c: *Connection) *Io.Writer {
        return if (c.tls) |*t| &t.writer else &c.writer.interface;
    }
};

/// Registers `dev.tachi.host.NativeTransport`'s natives. `ca_file` must
/// outlive the runtime; null uses the system roots.
pub fn register(env: *jni.JNIEnv, gpa: std.mem.Allocator, io: Io, ca_file: ?[]const u8) bool {
    const cls = env.f.FindClass(env, "dev/tachi/host/NativeTransport") orelse {
        env.f.ExceptionClear(env);
        return false;
    };
    defer env.f.DeleteLocalRef(env, cls);
    const methods = [_]jni.JNINativeMethod{
        .{ .name = "connect", .signature = "([BII)J", .fnPtr = @ptrCast(@constCast(&connect)) },
        .{ .name = "startTls", .signature = "(J[B)I", .fnPtr = @ptrCast(@constCast(&startTls)) },
        .{ .name = "read", .signature = "(J[BIII)I", .fnPtr = @ptrCast(@constCast(&read)) },
        .{ .name = "write", .signature = "(J[BII)V", .fnPtr = @ptrCast(@constCast(&write)) },
        .{ .name = "shutdown", .signature = "(J)V", .fnPtr = @ptrCast(@constCast(&shutdown)) },
        .{ .name = "free", .signature = "(J)V", .fnPtr = @ptrCast(@constCast(&free)) },
    };
    if (env.f.RegisterNatives(env, cls, &methods, methods.len) != jni.JNI_OK) {
        env.f.ExceptionClear(env);
        return false;
    }
    state = .{ .gpa = gpa, .io = io, .ca_file = ca_file };
    return true;
}

pub fn unregister() void {
    if (state) |*s| s.ca_bundle.deinit(s.gpa);
    state = null;
}

fn throw(env: *jni.JNIEnv, class: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "native transport error";
    const cls = env.f.FindClass(env, class) orelse return;
    defer env.f.DeleteLocalRef(env, cls);
    _ = env.f.ThrowNew(env, cls, message.ptr);
}

fn copyBytes(env: *jni.JNIEnv, array: jni.jbyteArray, buf: []u8) []u8 {
    const len: usize = @min(@as(usize, @intCast(env.f.GetArrayLength(env, array))), buf.len);
    env.f.GetByteArrayRegion(env, array, 0, @intCast(len), @ptrCast(buf.ptr));
    return buf[0..len];
}

fn handle(value: jni.jlong) *Connection {
    return @ptrFromInt(@as(usize, @intCast(value)));
}

fn connect(env: *jni.JNIEnv, _: jni.jclass, address: jni.jbyteArray, port: jni.jint, _: jni.jint) callconv(.c) jni.jlong {
    const s = if (state) |*st| st else return 0;
    var buf: [64]u8 = undefined;
    const text = copyBytes(env, address, &buf);
    const ip = Io.net.IpAddress.parse(text, @intCast(port)) catch {
        throw(env, "java/net/UnknownHostException", "{s}", .{text});
        return 0;
    };
    const c = s.gpa.create(Connection) catch {
        throw(env, "java/lang/OutOfMemoryError", "native socket", .{});
        return 0;
    };
    // Io.net cannot time out a connect yet; the OS default bounds it.
    c.* = .{ .stream = ip.connect(s.io, .{ .mode = .stream }) catch |err| {
        s.gpa.destroy(c);
        throw(env, "java/net/ConnectException", "{s}:{d}: {s}", .{ text, port, @errorName(err) });
        return 0;
    }, .reader = undefined, .writer = undefined };
    c.reader = c.stream.reader(s.io, &c.socket_read);
    c.writer = c.stream.writer(s.io, &c.socket_write);
    return @intCast(@intFromPtr(c));
}

fn loadBundle(s: *State) !void {
    s.ca_mutex.lockUncancelable(s.io);
    defer s.ca_mutex.unlock(s.io);
    if (s.ca_loaded) return;
    const now = Io.Clock.real.now(s.io);
    if (s.ca_file) |path|
        try s.ca_bundle.addCertsFromFilePath(s.gpa, s.io, now, Io.Dir.cwd(), path)
    else
        try s.ca_bundle.rescan(s.gpa, s.io, now);
    s.ca_loaded = true;
}

/// Handshakes on a connected socket; returns the TLS version (0x0303 or 0x0304).
fn startTls(env: *jni.JNIEnv, _: jni.jclass, h: jni.jlong, host: jni.jbyteArray) callconv(.c) jni.jint {
    const s = if (state) |*st| st else return 0;
    const c = handle(h);
    var host_buf: [256]u8 = undefined;
    const name = copyBytes(env, host, &host_buf);
    // Certificate checks need more stack than a JVM thread may have left,
    // especially under Zero's interpreter, so the handshake gets its own.
    var outcome: anyerror!void = {};
    const thread = std.Thread.spawn(.{ .stack_size = handshake_stack }, handshake, .{ s, c, name, &outcome }) catch |err| {
        throw(env, "javax/net/ssl/SSLHandshakeException", "{s}: {s}", .{ name, @errorName(err) });
        return 0;
    };
    thread.join();
    outcome catch |err| {
        throw(env, "javax/net/ssl/SSLHandshakeException", "{s}: {s}", .{ name, @errorName(err) });
        return 0;
    };
    return @backingInt(c.tls.?.tls_version);
}

const handshake_stack = 1 << 20;
// The worker must return void for Thread.spawn; its error union crosses the join.
fn handshake(s: *State, c: *Connection, name: []const u8, outcome: *anyerror!void) void {
    outcome.* = handshakeConnection(s, c, name);
}

fn handshakeConnection(s: *State, c: *Connection, name: []const u8) !void {
    try loadBundle(s);
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    s.io.random(&entropy);
    c.tls = tls.Client.init(&c.reader.interface, &c.writer.interface, .{
        .host = .{ .explicit = name },
        .ca = .{ .bundle = .{ .gpa = s.gpa, .io = s.io, .lock = &s.ca_lock, .bundle = &s.ca_bundle } },
        .read_buffer = &c.plain_read,
        .write_buffer = &c.plain_write,
        .entropy = &entropy,
        .realtime_now = Io.Clock.real.now(s.io),
        // HTTP frames its bodies, so a missing close_notify cannot truncate silently.
        .allow_truncation_attacks = true,
    }) catch |err| {
        return switch (err) {
            error.ReadFailed => c.reader.err orelse err,
            error.WriteFailed => c.writer.err orelse err,
            else => err,
        };
    };
}

/// Returns bytes read (at least 1), -1 at end of stream or -2 when
/// `timeout_ms` passes with nothing to read.
fn read(env: *jni.JNIEnv, _: jni.jclass, h: jni.jlong, out: jni.jbyteArray, offset: jni.jint, length: jni.jint, timeout_ms: jni.jint) callconv(.c) jni.jint {
    const c = handle(h);
    const r = c.input();
    // A TLS record can carry no application data (a session ticket, say),
    // so one fill may add nothing; Java streams must not report 0 bytes.
    while (r.bufferedLen() == 0) {
        // A TLS record may already sit in the ciphertext buffer; then the
        // socket can be idle while there is still something to decrypt.
        const ciphertext = c.tls != null and c.reader.interface.bufferedLen() > 0;
        if (!ciphertext and timeout_ms > 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = c.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, timeout_ms) catch |err| {
                throw(env, "java/net/SocketException", "poll: {s}", .{@errorName(err)});
                return 0;
            };
            if (ready == 0) return -2;
        }
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return -1,
            error.ReadFailed => {
                if (c.tls) |t| if (t.read_err) |e| {
                    throw(env, "javax/net/ssl/SSLException", "{s}", .{@errorName(e)});
                    return 0;
                };
                throw(env, "java/net/SocketException", "{s}", .{if (c.reader.err) |e| @errorName(e) else "ReadFailed"});
                return 0;
            },
        };
    }
    const n = @min(@as(usize, @intCast(length)), r.bufferedLen());
    env.f.SetByteArrayRegion(env, out, offset, @intCast(n), @ptrCast(r.buffered()[0..n].ptr));
    r.toss(n);
    return @intCast(n);
}

fn write(env: *jni.JNIEnv, _: jni.jclass, h: jni.jlong, data: jni.jbyteArray, offset: jni.jint, length: jni.jint) callconv(.c) void {
    const c = handle(h);
    const w = c.output();
    var buf: [4096]u8 = undefined;
    var done: usize = 0;
    const total: usize = @intCast(length);
    while (done < total) {
        const n = @min(buf.len, total - done);
        env.f.GetByteArrayRegion(env, data, offset + @as(jni.jint, @intCast(done)), @intCast(n), @ptrCast(&buf));
        w.writeAll(buf[0..n]) catch return writeFailed(env, c);
        done += n;
    }
    w.flush() catch return writeFailed(env, c);
    if (c.tls != null) c.writer.interface.flush() catch return writeFailed(env, c);
}

fn writeFailed(env: *jni.JNIEnv, c: *Connection) void {
    throw(env, "java/net/SocketException", "{s}", .{if (c.writer.err) |e| @errorName(e) else "WriteFailed"});
}

/// Wakes any thread blocked in `read` or `write`; `free` follows once they return.
fn shutdown(_: *jni.JNIEnv, _: jni.jclass, h: jni.jlong) callconv(.c) void {
    const s = if (state) |*st| st else return;
    handle(h).stream.shutdown(s.io, .both) catch {};
}

fn free(_: *jni.JNIEnv, _: jni.jclass, h: jni.jlong) callconv(.c) void {
    const s = if (state) |*st| st else return;
    const c = handle(h);
    c.stream.close(s.io);
    s.gpa.destroy(c);
}

test "handshake worker returns CA errors across the thread join" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/missing.pem", .{tmp.sub_path});
    defer testing.allocator.free(path);
    var s: State = .{ .gpa = testing.allocator, .io = testing.io, .ca_file = path };
    defer s.ca_bundle.deinit(testing.allocator);
    var connection: Connection = undefined; // CA loading fails before socket access.
    var outcome: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = handshake_stack }, handshake, .{ &s, &connection, "example.com", &outcome });
    thread.join();
    try testing.expectError(error.FileNotFound, outcome);
    try testing.expect(!s.ca_loaded);
}
