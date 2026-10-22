//! C ABI exported by libtachi. See include/tachi.h for documentation.
const std = @import("std");
const tachi = @import("tachi");
const common = @import("capi_common.zig");
const api = common.Api(tachi);
const c_allocator = std.heap.c_allocator;
pub const ErrorCode = common.ErrorCode;
pub const tachi_config = api.Config;
const Backend = api.Backend;
const fail = api.fail;
const mapError = api.mapError;
const returnJson = api.returnJson;
fn optSlice(p: ?[*:0]const u8) ?[]const u8 {
    return std.mem.span(p);
}

pub export fn tachi_runtime_new(cfg: ?*const tachi_config, out: ?*?*tachi.Runtime) c_int {
    return api.runtimeNew(cfg, out);
}

pub export fn tachi_runtime_free(rt: ?*tachi.Runtime) void {
    return api.runtimeFree(rt);
}

pub export fn tachi_thread_detach(rt: ?*tachi.Runtime) void {
    return api.threadDetach(rt);
}

pub export fn tachi_last_error() [*:0]const u8 {
    return api.lastError();
}

pub export fn tachi_free(p: ?*anyopaque) void {
    return api.freeBuffer(p);
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
    return api.listExtensions(rt, out_json);
}

pub export fn tachi_call(
    rt: ?*tachi.Runtime,
    source_id: i64,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_json: ?*?[*:0]u8,
) c_int {
    return api.call(rt, source_id, method, args_json, out_json);
}

pub export fn tachi_fetch_image(
    rt: ?*tachi.Runtime,
    source_id: i64,
    page_json: ?[*:0]const u8,
    out_bytes: ?*?[*]u8,
    out_len: ?*usize,
    out_mime: ?*?[*:0]u8,
) c_int {
    return api.fetchImage(rt, source_id, page_json, out_bytes, out_len, out_mime);
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
        .{ error.BrowserVerificationRequired, ErrorCode.browser_verification_required, true },
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
