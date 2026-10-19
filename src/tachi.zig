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

// ---- last error (per thread) ---------------------------------------------------

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

// ---- bridge method table -------------------------------------------------------

/// Static methods of `dev.tachi.host.Bridge`, with their JNI signatures.
/// The enum tag is the Java method name, so adding a bridge method is one line.
pub const BridgeMethod = enum {
    init,
    install,
    uninstall,
    listExtensions,
    call,
    fetchImage,
    lastImageMime,
    lastError,
    shutdown,

    pub fn signature(m: BridgeMethod) [:0]const u8 {
        return switch (m) {
            .init, .install, .uninstall => "([B)[B",
            .listExtensions, .lastImageMime, .lastError => "()[B",
            .call => "(J[B[B)[B",
            .fetchImage => "(J[B)[B",
            .shutdown => "()V",
        };
    }

    /// `true` when the method returns `byte[]`, so `invokeBytes` may be used.
    pub fn returnsBytes(m: BridgeMethod) bool {
        return std.mem.endsWith(u8, m.signature(), ")[B");
    }
};

const MethodIds = std.EnumArray(BridgeMethod, jni.jmethodID);

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    vm: jvm.Vm,
    bridge: jni.jclass,
    methods: MethodIds,

    pub fn init(gpa: std.mem.Allocator, opts: Options) Error!*Runtime {
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        self.gpa = gpa;

        self.vm = if (opts.existing_vm) |vm| jvm.Vm.adopt(vm) else try createVm(gpa, opts);
        errdefer self.vm.destroy();

        const env = try self.vm.env();
        self.bridge = try findGlobalClass(env, "dev/tachi/host/Bridge");
        errdefer env.f.DeleteGlobalRef(env, self.bridge);

        var ids: MethodIds = undefined;
        inline for (comptime std.enums.values(BridgeMethod)) |m| {
            ids.set(m, env.f.GetStaticMethodID(env, self.bridge, @tagName(m), m.signature()) orelse {
                describeException(env);
                return error.BridgeMethodNotFound;
            });
        }
        self.methods = ids;

        if (opts.log_fn) |f| {
            g_log_fn = f;
            g_log_ud = opts.log_user_data;
            try registerLogHook(env);
        }

        // Build the RuntimeConfig JSON the Kotlin side expects.
        const config_json = std.json.Stringify.valueAlloc(gpa, .{
            .dataDir = opts.data_dir,
            .cacheDir = opts.cache_dir,
            .userAgent = opts.user_agent,
            .appVersionName = opts.app_version_name,
            .appVersionCode = opts.app_version_code,
            .packageName = opts.package_name,
            .verbose = opts.verbose,
            .nativeLog = opts.log_fn != null,
        }, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        defer gpa.free(config_json);

        const reply = try self.invokeInFrame(.init, .{config_json});
        defer gpa.free(reply);
        try checkEnvelope(gpa, reply);
        return self;
    }

    fn createVm(gpa: std.mem.Allocator, opts: Options) Error!jvm.Vm {
        const host_jar = try findHostJar(gpa, opts.host_jar);
        defer gpa.free(host_jar);
        const cp = try std.mem.concat(gpa, []const u8, &.{ &.{host_jar}, opts.extra_classpath });
        defer gpa.free(cp);
        return jvm.Vm.create(gpa, .{
            .java_home = opts.java_home,
            .libjvm_path = opts.libjvm_path,
            .classpath = cp,
            .extra_options = opts.jvm_options,
        });
    }

    pub fn deinit(self: *Runtime) void {
        if (self.vm.env()) |env| {
            env.f.CallStaticVoidMethodA(env, self.bridge, self.methods.get(.shutdown), &[_]jni.jvalue{});
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
        return self.invokeJson(.install, .{path});
    }

    pub fn installExtensionParsed(self: *Runtime, path: []const u8) Error!Result(models.ExtensionInfo) {
        return self.invokeParsed(models.ExtensionInfo, .install, .{path});
    }

    pub fn uninstallExtension(self: *Runtime, pkg: []const u8) Error!bool {
        const r = try self.invokeParsed(bool, .uninstall, .{pkg});
        defer r.deinit();
        return r.value();
    }

    /// JSON array of `ExtensionInfo` (owned by caller).
    pub fn listExtensions(self: *Runtime) Error![]u8 {
        return self.invokeJson(.listExtensions, .{});
    }

    pub fn listExtensionsParsed(self: *Runtime) Error!Result([]const models.ExtensionInfo) {
        return self.invokeParsed([]const models.ExtensionInfo, .listExtensions, .{});
    }

    // ---- source calls ------------------------------------------------------------

    /// Invokes `method` on a source. `args_json` is a JSON object; see docs/API.md
    /// for the method list. Returns the result JSON (owned by caller).
    pub fn call(self: *Runtime, source_id: i64, method: []const u8, args_json: []const u8) Error![]u8 {
        return self.invokeJson(.call, .{ source_id, method, args_json });
    }

    pub fn callParsed(self: *Runtime, comptime T: type, source_id: i64, method: []const u8, args_json: []const u8) Error!Result(T) {
        return self.invokeParsed(T, .call, .{ source_id, method, args_json });
    }

    /// Downloads a page's image through the source's HTTP client.
    /// `page_json` is a `Page` object; `imageUrl` may be null, in which case
    /// the source's `getImageUrl` is consulted first.
    pub fn fetchImage(self: *Runtime, source_id: i64, page_json: []const u8) Error!Image {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);

        const arr = try self.callStatic(env, .fetchImage, .{ source_id, page_json }) orelse {
            // fetchImage reports failure out-of-band so the byte[] stays raw image data.
            if (try self.callStatic(env, .lastError, .{})) |e| {
                const msg = try bytesFromArray(self.gpa, env, e);
                defer self.gpa.free(msg);
                if (!setErrorFromJson(self.gpa, msg)) setLastError(msg);
            } else setLastError("fetchImage failed");
            return error.ExtensionError;
        };
        const bytes = try bytesFromArray(self.gpa, env, arr);
        errdefer self.gpa.free(bytes);
        const mime = if (try self.callStatic(env, .lastImageMime, .{})) |m| try bytesFromArray(self.gpa, env, m) else null;
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

    /// Marshals a Zig tuple into `jvalue`s: `i64` -> `J`, `[]const u8` -> `byte[]`.
    /// The arrays are local refs owned by the caller's frame.
    fn marshal(env: *jni.JNIEnv, args: anytype) Error![args.len]jni.jvalue {
        var out: [args.len]jni.jvalue = undefined;
        inline for (args, 0..) |arg, i| {
            out[i] = switch (@TypeOf(arg)) {
                i64, comptime_int => .{ .j = arg },
                else => .{ .l = try newByteArray(env, arg) },
            };
        }
        return out;
    }

    /// Calls a static object-returning bridge method inside the caller's frame.
    fn callStatic(self: *Runtime, env: *jni.JNIEnv, comptime method: BridgeMethod, args: anytype) Error!jni.jobject {
        comptime std.debug.assert(method.returnsBytes());
        const jargs = try marshal(env, args);
        const result = env.f.CallStaticObjectMethodA(env, self.bridge, self.methods.get(method), &jargs);
        if (env.f.ExceptionCheck(env) != 0) {
            describeException(env);
            return error.JavaException;
        }
        return result;
    }

    /// Opens a frame, calls a `byte[]`-returning method and copies the reply out.
    fn invokeInFrame(self: *Runtime, comptime method: BridgeMethod, args: anytype) Error![]u8 {
        const env = try self.frame();
        defer _ = env.f.PopLocalFrame(env, null);
        const arr = try self.callStatic(env, method, args) orelse return error.InvalidResponse;
        return bytesFromArray(self.gpa, env, arr);
    }

    /// Reply's `ok` payload re-serialised as JSON, owned by the caller.
    fn invokeJson(self: *Runtime, comptime method: BridgeMethod, args: anytype) Error![]u8 {
        const reply = try self.invokeInFrame(method, args);
        defer self.gpa.free(reply);
        return unwrapOk(self.gpa, reply);
    }

    /// Reply's `ok` payload decoded as `T`.
    fn invokeParsed(self: *Runtime, comptime T: type, comptime method: BridgeMethod, args: anytype) Error!Result(T) {
        const reply = try self.invokeInFrame(method, args);
        defer self.gpa.free(reply);
        return parseEnvelope(T, self.gpa, reply);
    }
};

fn findGlobalClass(env: *jni.JNIEnv, name: [*:0]const u8) Error!jni.jclass {
    const local = env.f.FindClass(env, name) orelse {
        describeException(env);
        return error.BridgeClassNotFound;
    };
    defer env.f.DeleteLocalRef(env, local);
    return env.f.NewGlobalRef(env, local) orelse error.OutOfMemory;
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

// ---- envelope handling ---------------------------------------------------------

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

// ---- host jar discovery --------------------------------------------------------

const host_jar_candidates = [_][]const u8{
    "tachi-host.jar",
    "host/build/libs/tachi-host.jar",
    "../host/build/libs/tachi-host.jar",
};

fn findHostJar(gpa: std.mem.Allocator, explicit: ?[]const u8) Error![]u8 {
    if (explicit) |p| {
        if (!jvm.fileExists(p)) return error.HostJarNotFound;
        return gpa.dupe(u8, p);
    }
    if (jvm.getenv("TACHI_HOST_JAR")) |p| {
        if (jvm.fileExists(p)) return gpa.dupe(u8, p);
    }
    for (host_jar_candidates) |p| {
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
    f(@fromBackingInt(@intCast(level)), copyArray(env, tag, &tag_buf), copyArray(env, msg, &msg_buf), g_log_ud);
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

// ---- tests ---------------------------------------------------------------------

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

test "every bridge method has a parseable signature" {
    inline for (comptime std.enums.values(BridgeMethod)) |m| {
        try std.testing.expect(m.signature()[0] == '(');
        try std.testing.expect(m.returnsBytes() or m == .shutdown);
    }
}
