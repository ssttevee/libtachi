//! C ABI exported by libtachi. See include/tachi.h for documentation.
const std = @import("std");
const builtin = @import("builtin");
const tachi = @import("tachi");

const c_allocator = std.heap.c_allocator;

/// C callers cannot supply an Io. Share one initialized backend while any C
/// runtime is alive, including during failed initialization. A single owner
/// also keeps Threaded's process-wide signal-handler setup/restoration paired.
const Backend = struct {
    var bootstrap: std.Io.Threaded = .init_single_threaded;
    var lock: std.Io.Mutex = .init;
    var threaded: std.Io.Threaded = undefined;
    var users: usize = 0;

    fn acquire() std.Io {
        const io = bootstrap.io();
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (users == 0) threaded = .init(c_allocator, .{ .environ = processEnviron() });
        users += 1;
        return threaded.io();
    }

    fn release() void {
        const io = bootstrap.io();
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        std.debug.assert(users > 0);
        users -= 1;
        if (users == 0) threaded.deinit();
    }
};

/// The libc environment block, viewed through `std.process.Environ`.
fn processEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } };
}

pub const ErrorCode = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    jvm_not_found = 2,
    jvm_create_failed = 3,
    host_jar_not_found = 4,
    bridge_missing = 5,
    java_exception = 6,
    extension_error = 7,
    invalid_response = 8,
    out_of_memory = 9,
    network_error = 10,
    invalid_index = 11,
    file_system_error = 12,
    extension_not_in_repo = 13,
    signature_mismatch = 14,
    unsupported_extension = 15,
    canceled = 16,
    concurrency_unavailable = 17,

    fn int(c: ErrorCode) c_int {
        return @backingInt(c);
    }
};

fn fail(c: ErrorCode, msg: []const u8) c_int {
    tachi.setLastError(msg);
    return c.int();
}

fn mapError(err: tachi.Error) c_int {
    const mapped: ErrorCode = switch (err) {
        error.LibJvmNotFound, error.LibJvmLoadFailed, error.SymbolNotFound => .jvm_not_found,
        error.JvmCreateFailed, error.AttachFailed => .jvm_create_failed,
        error.HostJarNotFound => .host_jar_not_found,
        error.BridgeClassNotFound, error.BridgeMethodNotFound => .bridge_missing,
        error.JavaException => .java_exception,
        error.ExtensionError => .extension_error,
        error.InvalidResponse => .invalid_response,
        error.FileSystemError => .file_system_error,
        error.ExtensionNotInRepo => .extension_not_in_repo,
        error.SignatureMismatch => .signature_mismatch,
        error.UnsupportedExtension => .unsupported_extension,
        error.Canceled => .canceled,
        error.ConcurrencyUnavailable => .concurrency_unavailable,
        error.NetworkError => .network_error,
        error.InvalidIndex => .invalid_index,
        error.OutOfMemory => .out_of_memory,
    };
    switch (mapped) {
        // These errors already have a detailed runtime diagnostic.
        .java_exception,
        .extension_error,
        .invalid_response,
        .file_system_error,
        .extension_not_in_repo,
        .signature_mismatch,
        .unsupported_extension,
        => return mapped.int(),
        else => return fail(mapped, @errorName(err)),
    }
}

/// Mirrors `tachi_config` in include/tachi.h; keep the two in sync.
pub const tachi_config = extern struct {
    data_dir: ?[*:0]const u8 = null,
    cache_dir: ?[*:0]const u8 = null,
    host_jar: ?[*:0]const u8 = null,
    java_home: ?[*:0]const u8 = null,
    libjvm_path: ?[*:0]const u8 = null,
    user_agent: ?[*:0]const u8 = null,
    app_version_name: ?[*:0]const u8 = null,
    package_name: ?[*:0]const u8 = null,
    extra_classpath: ?[*:null]const ?[*:0]const u8 = null,
    jvm_options: ?[*:null]const ?[*:0]const u8 = null,
    log_fn: ?tachi.LogFn = null,
    log_user_data: ?*anyopaque = null,
    existing_jvm: ?*anyopaque = null,
    app_version_code: c_int = 0,
    verbose: c_int = 0,
    no_class_data_sharing: c_int = 0,
    native_transport: c_int = 0,
};

fn optSlice(p: ?[*:0]const u8) ?[]const u8 {
    return std.mem.span(p);
}

/// Converts a NULL-terminated `char*[]` into a slice of slices.
fn collect(gpa: std.mem.Allocator, list: ?[*:null]const ?[*:0]const u8) ![]const []const u8 {
    const ptrs = std.mem.sliceTo(list orelse return &.{}, null);
    const out = try gpa.alloc([]const u8, ptrs.len);
    for (out, ptrs) |*dst, src| dst.* = std.mem.span(src.?);
    return out;
}

pub export fn tachi_runtime_new(cfg: ?*const tachi_config, out: ?*?*tachi.Runtime) c_int {
    const c = cfg orelse return fail(.invalid_argument, "cfg is NULL");
    const data_dir = optSlice(c.data_dir) orelse return fail(.invalid_argument, "data_dir is required");
    const extra_cp = collect(c_allocator, c.extra_classpath) catch return fail(.out_of_memory, "OutOfMemory");
    defer c_allocator.free(extra_cp);
    const jvm_opts = collect(c_allocator, c.jvm_options) catch return fail(.out_of_memory, "OutOfMemory");
    defer c_allocator.free(jvm_opts);

    const io = Backend.acquire();
    const rt = tachi.Runtime.init(c_allocator, io, .{
        .data_dir = data_dir,
        .cache_dir = optSlice(c.cache_dir),
        .host_jar = optSlice(c.host_jar),
        .extra_classpath = extra_cp,
        .user_agent = optSlice(c.user_agent),
        .app_version_name = optSlice(c.app_version_name),
        .app_version_code = if (c.app_version_code != 0) c.app_version_code else null,
        .package_name = optSlice(c.package_name),
        .verbose = c.verbose != 0,
        .class_data_sharing = c.no_class_data_sharing == 0,
        .native_transport = c.native_transport != 0,
        .log_fn = c.log_fn,
        .log_user_data = c.log_user_data,
        .java_home = optSlice(c.java_home),
        .libjvm_path = optSlice(c.libjvm_path),
        .jvm_options = jvm_opts,
        .existing_vm = @ptrCast(@alignCast(c.existing_jvm)),
        .environ = processEnviron(),
    }) catch |e| {
        Backend.release();
        return mapError(e);
    };
    if (out) |o| o.* = rt else {
        rt.deinit();
        Backend.release();
    }
    return ErrorCode.ok.int();
}

pub export fn tachi_runtime_free(rt: ?*tachi.Runtime) void {
    if (rt) |r| {
        r.deinit();
        Backend.release();
    }
}

pub export fn tachi_thread_detach(rt: ?*tachi.Runtime) void {
    if (rt) |r| r.detachThread();
}

pub export fn tachi_last_error() [*:0]const u8 {
    return tachi.lastError().ptr;
}

pub export fn tachi_free(p: ?*anyopaque) void {
    std.c.free(p);
}

/// Hands a runtime-owned JSON buffer to C as a NUL-terminated string.
fn returnJson(json: []u8, out: ?*?[*:0]u8) c_int {
    defer c_allocator.free(json);
    const o = out orelse return ErrorCode.ok.int();
    const z = c_allocator.dupeSentinel(u8, json, 0) catch return fail(.out_of_memory, "OutOfMemory");
    o.* = z.ptr;
    return ErrorCode.ok.int();
}

pub export fn tachi_install(rt: ?*tachi.Runtime, path: ?[*:0]const u8, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const p = optSlice(path) orelse return fail(.invalid_argument, "path is NULL");
    const json = r.installExtension(p) catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_uninstall(rt: ?*tachi.Runtime, pkg: ?[*:0]const u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const p = optSlice(pkg) orelse return fail(.invalid_argument, "pkg is NULL");
    _ = r.uninstallExtension(p) catch |e| return mapError(e);
    return ErrorCode.ok.int();
}

pub export fn tachi_restore(rt: ?*tachi.Runtime, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const json = r.restore() catch |e| return mapError(e);
    return returnJson(json, out_json);
}

fn repoOptions(index_url: ?[*:0]const u8, refresh: c_int) tachi.Runtime.RepoOptions {
    return .{ .url = optSlice(index_url), .refresh = refresh != 0 };
}

pub export fn tachi_repo_list(rt: ?*tachi.Runtime, index_url: ?[*:0]const u8, refresh: c_int, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const json = r.repoListJson(repoOptions(index_url, refresh)) catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_repo_install(
    rt: ?*tachi.Runtime,
    index_url: ?[*:0]const u8,
    package_name: ?[*:0]const u8,
    out_json: ?*?[*:0]u8,
) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const pkg = optSlice(package_name) orelse return fail(.invalid_argument, "package_name is NULL");
    const json = r.repoInstall(pkg, repoOptions(index_url, 0)) catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_repo_update(rt: ?*tachi.Runtime, index_url: ?[*:0]const u8, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const json = r.repoUpdate(repoOptions(index_url, 1)) catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_list_extensions(rt: ?*tachi.Runtime, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const json = r.listExtensions() catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_call(
    rt: ?*tachi.Runtime,
    source_id: i64,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_json: ?*?[*:0]u8,
) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const m = optSlice(method) orelse return fail(.invalid_argument, "method is NULL");
    const json = r.call(source_id, m, optSlice(args_json) orelse "{}") catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_fetch_image(
    rt: ?*tachi.Runtime,
    source_id: i64,
    page_json: ?[*:0]const u8,
    out_bytes: ?*?[*]u8,
    out_len: ?*usize,
    out_mime: ?*?[*:0]u8,
) c_int {
    const r = rt orelse return fail(.invalid_argument, "rt is NULL");
    const p = optSlice(page_json) orelse return fail(.invalid_argument, "page_json is NULL");
    const img = r.fetchImage(source_id, p) catch |e| return mapError(e);
    // The runtime allocated with c_allocator, so the buffer can be handed to the caller as-is.
    if (out_bytes) |o| o.* = img.bytes.ptr else c_allocator.free(img.bytes);
    if (out_len) |o| o.* = img.bytes.len;
    if (img.mime) |m| {
        defer c_allocator.free(m);
        if (out_mime) |o| o.* = if (c_allocator.dupeSentinel(u8, m, 0)) |z| z.ptr else |_| null;
    } else if (out_mime) |o| o.* = null;
    return ErrorCode.ok.int();
}

test "config struct stays C-compatible" {
    // Pointer-sized fields first, then three ints (plus tail padding): matches the header.
    const expected = std.mem.alignForward(usize, 13 * @sizeOf(usize) + 3 * @sizeOf(c_int), @alignOf(usize));
    try std.testing.expectEqual(expected, @sizeOf(tachi_config));
}

test "error mapping preserves runtime diagnostics only for detailed errors" {
    const cases = .{
        .{ error.LibJvmNotFound, ErrorCode.jvm_not_found, false },
        .{ error.LibJvmLoadFailed, ErrorCode.jvm_not_found, false },
        .{ error.SymbolNotFound, ErrorCode.jvm_not_found, false },
        .{ error.JvmCreateFailed, ErrorCode.jvm_create_failed, false },
        .{ error.AttachFailed, ErrorCode.jvm_create_failed, false },
        .{ error.HostJarNotFound, ErrorCode.host_jar_not_found, false },
        .{ error.BridgeClassNotFound, ErrorCode.bridge_missing, false },
        .{ error.BridgeMethodNotFound, ErrorCode.bridge_missing, false },
        .{ error.JavaException, ErrorCode.java_exception, true },
        .{ error.ExtensionError, ErrorCode.extension_error, true },
        .{ error.InvalidResponse, ErrorCode.invalid_response, true },
        .{ error.FileSystemError, ErrorCode.file_system_error, true },
        .{ error.ExtensionNotInRepo, ErrorCode.extension_not_in_repo, true },
        .{ error.SignatureMismatch, ErrorCode.signature_mismatch, true },
        .{ error.UnsupportedExtension, ErrorCode.unsupported_extension, true },
        .{ error.NetworkError, ErrorCode.network_error, false },
        .{ error.InvalidIndex, ErrorCode.invalid_index, false },
        .{ error.OutOfMemory, ErrorCode.out_of_memory, false },
        .{ error.Canceled, ErrorCode.canceled, false },
        .{ error.ConcurrencyUnavailable, ErrorCode.concurrency_unavailable, false },
    };
    inline for (cases) |case| {
        tachi.setLastError("runtime detail");
        try std.testing.expectEqual(case[1].int(), mapError(case[0]));
        try std.testing.expectEqualStrings(if (case[2]) "runtime detail" else @errorName(case[0]), tachi.lastError());
    }
}

test "C backend supports concurrency and cancellation until the last owner releases it" {
    const Work = struct {
        fn wait(io: std.Io) std.Io.Cancelable!void {
            try std.Io.sleep(io, .fromSeconds(3600), .awake);
        }
        fn answer() u32 {
            return 42;
        }
    };
    for (0..2) |_| {
        const io = Backend.acquire();
        _ = Backend.acquire();
        Backend.release();
        {
            defer Backend.release();
            var future = try std.Io.concurrent(io, Work.answer, .{});
            try std.testing.expectEqual(42, future.await(io));
            var waiting = try std.Io.concurrent(io, Work.wait, .{io});
            try std.testing.expectError(error.Canceled, waiting.cancel(io));
        }
        try std.testing.expectEqual(0, Backend.users);
    }
}

test "failed C runtime initialization releases its I/O backend" {
    const config: tachi_config = .{ .data_dir = "/dev/null/not-a-directory" };
    try std.testing.expectEqual(ErrorCode.file_system_error.int(), tachi_runtime_new(&config, null));
    try std.testing.expectEqual(0, Backend.users);
    tachi_runtime_free(null);
}
