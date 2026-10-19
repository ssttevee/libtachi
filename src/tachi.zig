//! zig-tachi: run Mihon/Tachiyomi extensions in-process.
//!
//! ```zig
//! var rt = try tachi.Runtime.init(gpa, .{ .data_dir = "/tmp/tachi" });
//! defer rt.deinit();
//! const ext = try rt.installExtensionParsed("tachiyomi-en.weebcentral-v1.6.25.jar");
//! defer ext.deinit();
//! const id = try ext.value().sources[0].idInt();
//! const page = try rt.callParsed(tachi.models.MangasPage, id, "popular", "{\"page\":1}");
//! defer page.deinit();
//! ```
const std = @import("std");
pub const jvm = @import("jvm.zig");
pub const jni = jvm.jni;
pub const models = @import("models.zig");

pub const Error = jvm.Error || error{
    HostJarNotFound,
    BridgeClassNotFound,
    BridgeMethodNotFound,
    /// The JVM raised an exception the bridge did not catch; see `lastError()`.
    JavaException,
    /// The bridge returned `{"error": ...}`; see `lastError()`.
    ExtensionError,
    InvalidResponse,
};

pub const LogLevel = enum(c_int) { verbose = 2, debug = 3, info = 4, warn = 5, err = 6, assert = 7, _ };

pub const LogFn = *const fn (level: LogLevel, tag: [*:0]const u8, message: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;

pub const Options = struct {
    /// Directory where the host persists preferences, cookies and converted APKs.
    data_dir: []const u8,
    cache_dir: ?[]const u8 = null,
    /// Path to tachi-host.jar. Defaults to $TACHI_HOST_JAR, then ./tachi-host.jar,
    /// then ./host/build/libs/tachi-host.jar.
    host_jar: ?[]const u8 = null,
    /// Extra jars for the JVM classpath (e.g. a JavaScript engine implementation).
    extra_classpath: []const []const u8 = &.{},
    user_agent: ?[]const u8 = null,
    app_version_name: ?[]const u8 = null,
    app_version_code: ?i32 = null,
    package_name: ?[]const u8 = null,
    verbose: bool = false,
    /// Receives android.util.Log output. Called from arbitrary JVM threads.
    log_fn: ?LogFn = null,
    log_user_data: ?*anyopaque = null,
    /// JVM selection; ignored when `existing_vm` is set.
    java_home: ?[]const u8 = null,
    libjvm_path: ?[]const u8 = null,
    jvm_options: []const []const u8 = &.{},
    /// Reuse a VM that already exists (Android: the JavaVM* from JNI_OnLoad).
    /// The host jar/dex must already be loadable by that VM's system class loader.
    existing_vm: ?*jni.JavaVM = null,
};

pub const Image = struct {
    bytes: []u8,
    mime: ?[]u8,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        if (self.mime) |m| gpa.free(m);
    }
};

/// A decoded bridge response; `value()` borrows from the arena freed by `deinit`.
pub fn Result(comptime T: type) type {
    return struct {
        parsed: std.json.Parsed(models.Envelope(T)),

        pub fn value(self: @This()) T {
            return self.parsed.value.ok.?;
        }

        pub fn deinit(self: @This()) void {
            self.parsed.deinit();
        }
    };
}

/// Kept NUL-terminated so the C API can hand the buffer out without copying.
threadlocal var last_error_buf: [8192:0]u8 = @splat(0);
threadlocal var last_error_len: usize = 0;

/// Message for the most recent `JavaException` / `ExtensionError` on this thread.
pub fn lastError() [:0]const u8 {
    return last_error_buf[0..last_error_len :0];
}

pub fn setLastError(msg: []const u8) void {
    const n = @min(msg.len, last_error_buf.len);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_buf[n] = 0;
    last_error_len = n;
}

fn setLastErrorFmt(comptime fmt: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&last_error_buf);
    w.print(fmt, args) catch {}; // truncation is fine for a diagnostic
    last_error_len = w.end;
    last_error_buf[last_error_len] = 0;
}

var g_log_fn: ?LogFn = null;
var g_log_ud: ?*anyopaque = null;

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    vm: jvm.Vm,
    bridge: jni.jclass,
    m_init: jni.jmethodID,
    m_install: jni.jmethodID,
    m_uninstall: jni.jmethodID,
    m_list: jni.jmethodID,
    m_call: jni.jmethodID,
    m_fetch_image: jni.jmethodID,
    m_last_image_mime: jni.jmethodID,
    m_last_error: jni.jmethodID,
    m_shutdown: jni.jmethodID,

    pub fn init(gpa: std.mem.Allocator, opts: Options) Error!*Runtime {
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        self.gpa = gpa;

        if (opts.existing_vm) |vm| {
            self.vm = jvm.Vm.adopt(vm);
        } else {
            const host_jar = try findHostJar(gpa, opts.host_jar);
            defer gpa.free(host_jar);
            var cp: std.ArrayList([]const u8) = .empty;
            defer cp.deinit(gpa);
            try cp.append(gpa, host_jar);
            try cp.appendSlice(gpa, opts.extra_classpath);
            self.vm = try jvm.Vm.create(gpa, .{
                .java_home = opts.java_home,
                .libjvm_path = opts.libjvm_path,
                .classpath = cp.items,
                .extra_options = opts.jvm_options,
            });
        }
        errdefer self.vm.destroy();

        const env = try self.vm.env();
        const local = env.f.FindClass(env, "dev/tachi/host/Bridge") orelse {
            describeException(env);
            return error.BridgeClassNotFound;
        };
        self.bridge = env.f.NewGlobalRef(env, local);
        env.f.DeleteLocalRef(env, local);
        errdefer env.f.DeleteGlobalRef(env, self.bridge);

        self.m_init = try staticMethod(env, self.bridge, "init", "([B)[B");
        self.m_install = try staticMethod(env, self.bridge, "install", "([B)[B");
        self.m_uninstall = try staticMethod(env, self.bridge, "uninstall", "([B)[B");
        self.m_list = try staticMethod(env, self.bridge, "listExtensions", "()[B");
        self.m_call = try staticMethod(env, self.bridge, "call", "(J[B[B)[B");
        self.m_fetch_image = try staticMethod(env, self.bridge, "fetchImage", "(J[B)[B");
        self.m_last_image_mime = try staticMethod(env, self.bridge, "lastImageMime", "()[B");
        self.m_last_error = try staticMethod(env, self.bridge, "lastError", "()[B");
        self.m_shutdown = try staticMethod(env, self.bridge, "shutdown", "()V");

        if (opts.log_fn) |f| {
            g_log_fn = f;
            g_log_ud = opts.log_user_data;
            try registerLogHook(env);
        }

        // Build the RuntimeConfig JSON the Kotlin side expects.
        const config = .{
            .dataDir = opts.data_dir,
            .cacheDir = opts.cache_dir,
            .userAgent = opts.user_agent,
            .appVersionName = opts.app_version_name,
            .appVersionCode = opts.app_version_code,
            .packageName = opts.package_name,
            .verbose = opts.verbose,
            .nativeLog = opts.log_fn != null,
        };
        const config_json = std.json.Stringify.valueAlloc(gpa, config, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        defer gpa.free(config_json);
        if (env.f.PushLocalFrame(env, 16) != jni.JNI_OK) return error.OutOfMemory;
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_init, &.{.{ .l = try newByteArray(env, config_json) }});
        defer gpa.free(reply);
        try checkEnvelope(gpa, reply);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.vm.env()) |env| {
            env.f.CallStaticVoidMethodA(env, self.bridge, self.m_shutdown, &[_]jni.jvalue{});
            if (env.f.ExceptionCheck(env) != 0) env.f.ExceptionClear(env);
            env.f.DeleteGlobalRef(env, self.bridge);
        } else |_| {}
        g_log_fn = null;
        self.vm.destroy();
        self.gpa.destroy(self);
    }

    /// Detach the calling thread from the JVM. Call before a thread that used
    /// the runtime exits (not needed for the thread that called `init`).
    pub fn detachThread(self: *Runtime) void {
        self.vm.detach();
    }

    // ---- extensions ------------------------------------------------------------

    /// Loads a `.jar` or `.apk` extension. Returns the `ExtensionInfo` JSON (owned by caller).
    pub fn installExtension(self: *Runtime, path: []const u8) Error![]u8 {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_install, &.{.{ .l = try newByteArray(env, path) }});
        defer self.gpa.free(reply);
        return unwrapOk(self.gpa, reply);
    }

    pub fn installExtensionParsed(self: *Runtime, path: []const u8) Error!Result(models.ExtensionInfo) {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_install, &.{.{ .l = try newByteArray(env, path) }});
        defer self.gpa.free(reply);
        return parseEnvelope(models.ExtensionInfo, self.gpa, reply);
    }

    pub fn uninstallExtension(self: *Runtime, pkg: []const u8) Error!bool {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_uninstall, &.{.{ .l = try newByteArray(env, pkg) }});
        defer self.gpa.free(reply);
        const r = try parseEnvelope(bool, self.gpa, reply);
        defer r.deinit();
        return r.value();
    }

    /// JSON array of `ExtensionInfo` (owned by caller).
    pub fn listExtensions(self: *Runtime) Error![]u8 {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_list, &.{});
        defer self.gpa.free(reply);
        return unwrapOk(self.gpa, reply);
    }

    pub fn listExtensionsParsed(self: *Runtime) Error!Result([]const models.ExtensionInfo) {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_list, &.{});
        defer self.gpa.free(reply);
        return parseEnvelope([]const models.ExtensionInfo, self.gpa, reply);
    }

    // ---- source calls ------------------------------------------------------------

    /// Invokes `method` on a source. `args_json` is a JSON object; see docs/API.md
    /// for the method list. Returns the result JSON (owned by caller).
    pub fn call(self: *Runtime, source_id: i64, method: []const u8, args_json: []const u8) Error![]u8 {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_call, &.{
            .{ .j = source_id },
            .{ .l = try newByteArray(env, method) },
            .{ .l = try newByteArray(env, args_json) },
        });
        defer self.gpa.free(reply);
        return unwrapOk(self.gpa, reply);
    }

    pub fn callParsed(self: *Runtime, comptime T: type, source_id: i64, method: []const u8, args_json: []const u8) Error!Result(T) {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const reply = try self.invokeBytes(env, self.m_call, &.{
            .{ .j = source_id },
            .{ .l = try newByteArray(env, method) },
            .{ .l = try newByteArray(env, args_json) },
        });
        defer self.gpa.free(reply);
        return parseEnvelope(T, self.gpa, reply);
    }

    /// Downloads a page's image through the source's HTTP client.
    /// `page_json` is a `Page` object; `imageUrl` may be null, in which case
    /// the source's `getImageUrl` is consulted first.
    pub fn fetchImage(self: *Runtime, source_id: i64, page_json: []const u8) Error!Image {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);

        const args = [_]jni.jvalue{ .{ .j = source_id }, .{ .l = try newByteArray(env, page_json) } };
        const arr = env.f.CallStaticObjectMethodA(env, self.bridge, self.m_fetch_image, &args);
        if (env.f.ExceptionCheck(env) != 0) {
            describeException(env);
            return error.JavaException;
        }
        if (arr == null) {
            const err_arr = env.f.CallStaticObjectMethodA(env, self.bridge, self.m_last_error, &[_]jni.jvalue{});
            if (err_arr) |e| {
                const msg = try bytesFromArray(self.gpa, env, e);
                defer self.gpa.free(msg);
                if (!setErrorFromJson(self.gpa, msg)) setLastError(msg);
            } else setLastError("fetchImage failed");
            return error.ExtensionError;
        }
        const bytes = try bytesFromArray(self.gpa, env, arr.?);
        errdefer self.gpa.free(bytes);
        var mime: ?[]u8 = null;
        if (env.f.CallStaticObjectMethodA(env, self.bridge, self.m_last_image_mime, &[_]jni.jvalue{})) |m| {
            mime = try bytesFromArray(self.gpa, env, m);
        }
        return .{ .bytes = bytes, .mime = mime };
    }

    // ---- JNI plumbing ------------------------------------------------------------

    /// Attaches the thread and opens a JNI local frame; pair with PopLocalFrame.
    fn frame(self: *Runtime) Error!*jni.JNIEnv {
        const env = try self.vm.env();
        if (env.f.PushLocalFrame(env, 32) != jni.JNI_OK) {
            if (env.f.ExceptionCheck(env) != 0) env.f.ExceptionClear(env);
            return error.OutOfMemory;
        }
        return env;
    }

    /// Calls a static `byte[]`-returning bridge method. Callers build `args`
    /// inside a local frame they own (see `callFrame`), so nothing is freed here.
    fn invokeBytes(self: *Runtime, env: *jni.JNIEnv, mid: jni.jmethodID, args: []const jni.jvalue) Error![]u8 {
        const result = env.f.CallStaticObjectMethodA(env, self.bridge, mid, args.ptr);
        if (env.f.ExceptionCheck(env) != 0) {
            describeException(env);
            return error.JavaException;
        }
        const arr = result orelse return error.InvalidResponse;
        return bytesFromArray(self.gpa, env, arr);
    }
};

fn staticMethod(env: *jni.JNIEnv, cls: jni.jclass, name: [*:0]const u8, sig: [*:0]const u8) Error!jni.jmethodID {
    return env.f.GetStaticMethodID(env, cls, name, sig) orelse {
        describeException(env);
        return error.BridgeMethodNotFound;
    };
}

fn newByteArray(env: *jni.JNIEnv, bytes: []const u8) Error!jni.jbyteArray {
    const arr = env.f.NewByteArray(env, @intCast(bytes.len)) orelse return error.OutOfMemory;
    if (bytes.len > 0) env.f.SetByteArrayRegion(env, arr, 0, @intCast(bytes.len), @ptrCast(bytes.ptr));
    return arr;
}

fn bytesFromArray(gpa: std.mem.Allocator, env: *jni.JNIEnv, arr: jni.jbyteArray) Error![]u8 {
    const len: usize = @intCast(env.f.GetArrayLength(env, arr));
    const out = try gpa.alloc(u8, len);
    if (len > 0) env.f.GetByteArrayRegion(env, arr, 0, @intCast(len), @ptrCast(out.ptr));
    return out;
}

/// Records a pending JVM exception into `lastError` and clears it.
fn describeException(env: *jni.JNIEnv) void {
    const exc = env.f.ExceptionOccurred(env) orelse return;
    env.f.ExceptionClear(env);
    defer env.f.DeleteLocalRef(env, exc);
    const obj_cls = env.f.FindClass(env, "java/lang/Object") orelse return;
    defer env.f.DeleteLocalRef(env, obj_cls);
    const to_string = env.f.GetMethodID(env, obj_cls, "toString", "()Ljava/lang/String;") orelse return;
    const str = env.f.CallObjectMethodA(env, exc, to_string, &[_]jni.jvalue{}) orelse return;
    defer env.f.DeleteLocalRef(env, str);
    if (env.f.ExceptionCheck(env) != 0) {
        env.f.ExceptionClear(env);
        setLastError("<exception while describing exception>");
        return;
    }
    const chars = env.f.GetStringUTFChars(env, str, null);
    defer env.f.ReleaseStringUTFChars(env, str, chars);
    setLastError(std.mem.sliceTo(chars, 0));
}

/// Returns the `ok` payload re-serialised as JSON, or records the error.
fn unwrapOk(gpa: std.mem.Allocator, reply: []const u8) Error![]u8 {
    const r = try parseEnvelope(std.json.Value, gpa, reply);
    defer r.deinit();
    return std.json.Stringify.valueAlloc(gpa, r.value(), .{}) catch return error.OutOfMemory;
}

fn checkEnvelope(gpa: std.mem.Allocator, reply: []const u8) Error!void {
    const r = try parseEnvelope(std.json.Value, gpa, reply);
    r.deinit();
}

fn parseEnvelope(comptime T: type, gpa: std.mem.Allocator, reply: []const u8) Error!Result(T) {
    const parsed = std.json.parseFromSlice(models.Envelope(T), gpa, reply, models.parse_options) catch |e| {
        setLastError(@errorName(e));
        return error.InvalidResponse;
    };
    errdefer parsed.deinit();
    if (parsed.value.@"error") |e| {
        setErrorInfo(e);
        return error.ExtensionError;
    }
    if (parsed.value.ok == null) return error.InvalidResponse;
    return .{ .parsed = parsed };
}

fn setErrorInfo(e: models.ErrorInfo) void {
    setLastErrorFmt("{s}: {s}", .{ e.type, e.message orelse "" });
}

/// Decodes an ErrorDto JSON blob into lastError. Returns false if it was not one.
fn setErrorFromJson(gpa: std.mem.Allocator, json: []const u8) bool {
    const parsed = std.json.parseFromSlice(models.ErrorInfo, gpa, json, models.parse_options) catch return false;
    defer parsed.deinit();
    setErrorInfo(parsed.value);
    return true;
}

fn findHostJar(gpa: std.mem.Allocator, explicit: ?[]const u8) Error![]u8 {
    if (explicit) |p| {
        if (!jvm.fileExists(p)) return error.HostJarNotFound;
        return gpa.dupe(u8, p);
    }
    if (jvm.getenv("TACHI_HOST_JAR")) |p| {
        if (jvm.fileExists(p)) return gpa.dupe(u8, p);
    }
    for ([_][]const u8{ "tachi-host.jar", "host/build/libs/tachi-host.jar", "../host/build/libs/tachi-host.jar" }) |p| {
        if (jvm.fileExists(p)) return gpa.dupe(u8, p);
    }
    return error.HostJarNotFound;
}

// ---- log hook (JVM -> native) -------------------------------------------------

fn nativeLog(env: *jni.JNIEnv, cls: jni.jclass, level: jni.jint, tag: jni.jbyteArray, msg: jni.jbyteArray) callconv(.c) void {
    _ = cls;
    const f = g_log_fn orelse return;
    var tag_buf: [256:0]u8 = undefined;
    var msg_buf: [16384:0]u8 = undefined;
    const t = copyArray(env, tag, &tag_buf);
    const m = copyArray(env, msg, &msg_buf);
    f(@fromBackingInt(@intCast(level)), t, m, g_log_ud);
}

fn copyArray(env: *jni.JNIEnv, arr: jni.jbyteArray, buf: [:0]u8) [*:0]const u8 {
    if (arr == null) {
        buf[0] = 0;
        return buf.ptr;
    }
    const len: usize = @min(@as(usize, @intCast(env.f.GetArrayLength(env, arr))), buf.len);
    if (len > 0) env.f.GetByteArrayRegion(env, arr, 0, @intCast(len), @ptrCast(buf.ptr));
    buf[len] = 0;
    return buf.ptr;
}

fn registerLogHook(env: *jni.JNIEnv) Error!void {
    const cls = env.f.FindClass(env, "dev/tachi/host/NativeHooks") orelse {
        describeException(env);
        return error.BridgeClassNotFound;
    };
    defer env.f.DeleteLocalRef(env, cls);
    const methods = [_]jni.JNINativeMethod{.{
        .name = "log",
        .signature = "(I[B[B)V",
        .fnPtr = @ptrCast(@constCast(&nativeLog)),
    }};
    if (env.f.RegisterNatives(env, cls, &methods, methods.len) != jni.JNI_OK) {
        describeException(env);
        return error.BridgeMethodNotFound;
    }
}

test "models decode a representative envelope" {
    const sample =
        \\{"ok":{"mangas":[{"url":"/a","title":"A","status":1}],"hasNextPage":true}}
    ;
    const r = try parseEnvelope(models.MangasPage, std.testing.allocator, sample);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.value().mangas.len);
    try std.testing.expectEqualStrings("A", r.value().mangas[0].title);
    try std.testing.expect(r.value().hasNextPage);
}

test "error envelope surfaces as ExtensionError" {
    const sample =
        \\{"error":{"type":"java.io.IOException","message":"boom"}}
    ;
    try std.testing.expectError(error.ExtensionError, parseEnvelope(models.MangasPage, std.testing.allocator, sample));
    try std.testing.expectEqualStrings("java.io.IOException: boom", lastError());
}

test "unwrapOk re-serialises the ok payload" {
    const out = try unwrapOk(std.testing.allocator, "{\"ok\":{\"a\":[1,2]}}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"a\":[1,2]}", out);
}

test "last error is truncated, never overflowed" {
    const big: [last_error_buf.len * 2]u8 = @splat('x');
    setLastError(&big);
    try std.testing.expectEqual(last_error_buf.len, lastError().len);
    try std.testing.expectEqual(@as(u8, 0), last_error_buf[last_error_buf.len]);
}
