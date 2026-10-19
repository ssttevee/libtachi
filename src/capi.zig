//! C ABI exported by libtachi. See include/tachi.h for documentation.
const std = @import("std");
const tachi = @import("tachi");

const c_allocator = std.heap.c_allocator;

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
};

const setError = tachi.setLastError;

fn mapError(err: tachi.Error) c_int {
    const mapped: ErrorCode = switch (err) {
        error.LibJvmNotFound, error.LibJvmLoadFailed, error.SymbolNotFound => .jvm_not_found,
        error.JvmCreateFailed, error.AttachFailed => .jvm_create_failed,
        error.HostJarNotFound => .host_jar_not_found,
        error.BridgeClassNotFound, error.BridgeMethodNotFound => .bridge_missing,
        error.JavaException => .java_exception,
        error.ExtensionError => .extension_error,
        error.InvalidResponse => .invalid_response,
        error.OutOfMemory => .out_of_memory,
    };
    switch (err) {
        // tachi already recorded a message for these; keep it.
        error.JavaException, error.ExtensionError, error.InvalidResponse => {},
        else => setError(@errorName(err)),
    }
    return @backingInt(mapped);
}

fn code(c: ErrorCode) c_int {
    return @backingInt(c);
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
    extra_classpath: ?[*]const ?[*:0]const u8 = null,
    jvm_options: ?[*]const ?[*:0]const u8 = null,
    log_fn: ?tachi.LogFn = null,
    log_user_data: ?*anyopaque = null,
    existing_jvm: ?*anyopaque = null,
    app_version_code: c_int = 0,
    verbose: c_int = 0,
};

fn optSlice(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.sliceTo(s, 0) else null;
}

fn collect(gpa: std.mem.Allocator, list: ?[*]const ?[*:0]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    if (list) |l| {
        var i: usize = 0;
        while (l[i]) |s| : (i += 1) try out.append(gpa, std.mem.sliceTo(s, 0));
    }
    return out.toOwnedSlice(gpa);
}

pub export fn tachi_runtime_new(cfg: ?*const tachi_config, out: ?*?*tachi.Runtime) c_int {
    const c = cfg orelse return code(.invalid_argument);
    const data_dir = optSlice(c.data_dir) orelse {
        setError("data_dir is required");
        return code(.invalid_argument);
    };
    const extra_cp = collect(c_allocator, c.extra_classpath) catch return code(.out_of_memory);
    defer c_allocator.free(extra_cp);
    const jvm_opts = collect(c_allocator, c.jvm_options) catch return code(.out_of_memory);
    defer c_allocator.free(jvm_opts);

    const rt = tachi.Runtime.init(c_allocator, .{
        .data_dir = data_dir,
        .cache_dir = optSlice(c.cache_dir),
        .host_jar = optSlice(c.host_jar),
        .extra_classpath = extra_cp,
        .user_agent = optSlice(c.user_agent),
        .app_version_name = optSlice(c.app_version_name),
        .app_version_code = if (c.app_version_code != 0) c.app_version_code else null,
        .package_name = optSlice(c.package_name),
        .verbose = c.verbose != 0,
        .log_fn = c.log_fn,
        .log_user_data = c.log_user_data,
        .java_home = optSlice(c.java_home),
        .libjvm_path = optSlice(c.libjvm_path),
        .jvm_options = jvm_opts,
        .existing_vm = if (c.existing_jvm) |p| @ptrCast(@alignCast(p)) else null,
    }) catch |e| return mapError(e);
    if (out) |o| o.* = rt else rt.deinit();
    return 0;
}

pub export fn tachi_runtime_free(rt: ?*tachi.Runtime) void {
    if (rt) |r| r.deinit();
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

fn returnJson(json: []u8, out: ?*?[*:0]u8) c_int {
    defer c_allocator.free(json);
    const z = c_allocator.dupeSentinel(u8, json, 0) catch return code(.out_of_memory);
    if (out) |o| o.* = z.ptr else c_allocator.free(z);
    return 0;
}

pub export fn tachi_install(rt: ?*tachi.Runtime, path: ?[*:0]const u8, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return code(.invalid_argument);
    const p = optSlice(path) orelse return code(.invalid_argument);
    const json = r.installExtension(p) catch |e| return mapError(e);
    return returnJson(json, out_json);
}

pub export fn tachi_uninstall(rt: ?*tachi.Runtime, pkg: ?[*:0]const u8) c_int {
    const r = rt orelse return code(.invalid_argument);
    const p = optSlice(pkg) orelse return code(.invalid_argument);
    _ = r.uninstallExtension(p) catch |e| return mapError(e);
    return 0;
}

pub export fn tachi_list_extensions(rt: ?*tachi.Runtime, out_json: ?*?[*:0]u8) c_int {
    const r = rt orelse return code(.invalid_argument);
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
    const r = rt orelse return code(.invalid_argument);
    const m = optSlice(method) orelse return code(.invalid_argument);
    const a = optSlice(args_json) orelse "{}";
    const json = r.call(source_id, m, a) catch |e| return mapError(e);
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
    const r = rt orelse return code(.invalid_argument);
    const p = optSlice(page_json) orelse return code(.invalid_argument);
    const img = r.fetchImage(source_id, p) catch |e| return mapError(e);
    // The runtime allocated with c_allocator, so the buffer can be handed to the caller as-is.
    if (out_bytes) |o| o.* = img.bytes.ptr else c_allocator.free(img.bytes);
    if (out_len) |o| o.* = img.bytes.len;
    if (img.mime) |m| {
        defer c_allocator.free(m);
        if (out_mime) |o| o.* = if (c_allocator.dupeSentinel(u8, m, 0)) |z| z.ptr else |_| null;
    } else if (out_mime) |o| o.* = null;
    return 0;
}
