//! Shared ownership, error and runtime mechanics for both C frontends.
const std = @import("std");
const builtin = @import("builtin");
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
    network_error = 10,
    invalid_index = 11,
    file_system_error = 12,
    extension_not_in_repo = 13,
    signature_mismatch = 14,
    unsupported_extension = 15,
    canceled = 16,
    concurrency_unavailable = 17,
    browser_verification_required = 18,

    pub fn int(c: ErrorCode) c_int {
        return @backingInt(c);
    }
};

fn processEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } };
}

fn optSlice(p: ?[*:0]const u8) ?[]const u8 {
    return std.mem.span(p);
}

fn collect(gpa: std.mem.Allocator, list: ?[*:null]const ?[*:0]const u8) ![]const []const u8 {
    const ptrs = std.mem.sliceTo(list orelse return &.{}, null);
    const out = try gpa.alloc([]const u8, ptrs.len);
    for (out, ptrs) |*dst, src| dst.* = std.mem.span(src.?);
    return out;
}

pub fn Api(comptime library: type) type {
    return struct {
        const tachi = library;

        pub const Backend = struct {
            var bootstrap: std.Io.Threaded = .init_single_threaded;
            var lock: std.Io.Mutex = .init;
            var threaded: std.Io.Threaded = undefined;
            pub var users: usize = 0;

            pub fn acquire() std.Io {
                const io = bootstrap.io();
                lock.lockUncancelable(io);
                defer lock.unlock(io);
                if (users == 0) threaded = .init(c_allocator, .{ .environ = processEnviron() });
                users += 1;
                return threaded.io();
            }

            pub fn release() void {
                const io = bootstrap.io();
                lock.lockUncancelable(io);
                defer lock.unlock(io);
                std.debug.assert(users > 0);
                users -= 1;
                if (users == 0) threaded.deinit();
            }
        };

        pub const Config = extern struct {
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

        pub fn fail(c: ErrorCode, msg: []const u8) c_int {
            tachi.setLastError(msg);
            return c.int();
        }

        pub fn mapError(err: anyerror) c_int {
            const mapped: ErrorCode = switch (err) {
                error.LibJvmNotFound, error.LibJvmLoadFailed, error.SymbolNotFound => .jvm_not_found,
                error.JvmCreateFailed, error.AttachFailed => .jvm_create_failed,
                error.HostJarNotFound => .host_jar_not_found,
                error.BridgeClassNotFound, error.BridgeMethodNotFound => .bridge_missing,
                error.JavaException => .java_exception,
                error.ExtensionError => .extension_error,
                error.BrowserVerificationRequired => .browser_verification_required,
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
                else => return fail(.invalid_response, @errorName(err)),
            };
            switch (mapped) {
                // These errors already have a detailed runtime diagnostic.
                .java_exception,
                .extension_error,
                .browser_verification_required,
                .invalid_response,
                .file_system_error,
                .extension_not_in_repo,
                .signature_mismatch,
                .unsupported_extension,
                => return mapped.int(),
                else => return fail(mapped, @errorName(err)),
            }
        }

        pub fn returnJson(json: []u8, out: ?*?[*:0]u8) c_int {
            defer c_allocator.free(json);
            const o = out orelse return ErrorCode.ok.int();
            const z = c_allocator.dupeSentinel(u8, json, 0) catch return fail(.out_of_memory, "OutOfMemory");
            o.* = z.ptr;
            return ErrorCode.ok.int();
        }

        pub fn runtimeNew(cfg: ?*const Config, out: ?*?*tachi.Runtime) callconv(.c) c_int {
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

        pub fn runtimeFree(rt: ?*tachi.Runtime) callconv(.c) void {
            if (rt) |r| {
                r.deinit();
                Backend.release();
            }
        }

        pub fn threadDetach(rt: ?*tachi.Runtime) callconv(.c) void {
            if (rt) |r| r.detachThread();
        }

        pub fn lastError() callconv(.c) [*:0]const u8 {
            return tachi.lastError().ptr;
        }

        pub fn freeBuffer(p: ?*anyopaque) callconv(.c) void {
            std.c.free(p);
        }

        pub fn listExtensions(rt: ?*tachi.Runtime, out_json: ?*?[*:0]u8) callconv(.c) c_int {
            const r = rt orelse return fail(.invalid_argument, "rt is NULL");
            const json = r.listExtensions() catch |e| return mapError(e);
            return returnJson(json, out_json);
        }

        pub fn call(
            rt: ?*tachi.Runtime,
            source_id: i64,
            method: ?[*:0]const u8,
            args_json: ?[*:0]const u8,
            out_json: ?*?[*:0]u8,
        ) callconv(.c) c_int {
            const r = rt orelse return fail(.invalid_argument, "rt is NULL");
            const m = optSlice(method) orelse return fail(.invalid_argument, "method is NULL");
            const json = r.call(source_id, m, optSlice(args_json) orelse "{}") catch |e| return mapError(e);
            return returnJson(json, out_json);
        }

        pub fn fetchImage(
            rt: ?*tachi.Runtime,
            source_id: i64,
            page_json: ?[*:0]const u8,
            out_bytes: ?*?[*]u8,
            out_len: ?*usize,
            out_mime: ?*?[*:0]u8,
        ) callconv(.c) c_int {
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
    };
}
