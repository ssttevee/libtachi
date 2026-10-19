//! JVM lifecycle: locate libjvm, create or adopt a VM, attach threads.
//!
//! On desktop the library dlopens HotSpot's `libjvm` and calls
//! `JNI_CreateJavaVM` (the JNI Invocation API), the same approach PatchBukkit
//! uses to run Bukkit plugins inside a Rust server. On Android the host app
//! already has a VM; pass it to `adopt` instead.
const std = @import("std");
const builtin = @import("builtin");
pub const jni = @import("jni.zig");

pub const Error = error{
    LibJvmNotFound,
    LibJvmLoadFailed,
    SymbolNotFound,
    JvmCreateFailed,
    AttachFailed,
    OutOfMemory,
};

pub const Vm = struct {
    vm: *jni.JavaVM,
    lib: ?std.DynLib = null,
    /// True if this struct created the VM (and may destroy it).
    owned: bool,

    pub const CreateOptions = struct {
        /// JDK/JRE home. Falls back to $TACHI_JAVA_HOME, $JAVA_HOME, then well-known install dirs.
        java_home: ?[]const u8 = null,
        /// Direct path to libjvm.{dylib,so} / jvm.dll; overrides java_home discovery.
        libjvm_path: ?[]const u8 = null,
        /// Entries joined with the platform path separator into -Djava.class.path.
        classpath: []const []const u8 = &.{},
        /// Extra raw JVM options, e.g. "-Xmx512m".
        extra_options: []const []const u8 = &.{},
    };

    /// Options every VM gets. Extensions lean on reflection through
    /// kotlinx.serialization, so the module system is opened up; AWT is never
    /// wanted; sources parse large pages recursively, hence the bigger stack.
    const base_options = [_][*:0]const u8{
        "--add-opens=java.base/java.lang=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
        "-Djava.awt.headless=true",
        "-Xss2m",
    };

    /// Create a new JVM in this process. HotSpot only supports one VM per
    /// process, so call this at most once.
    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) Error!Vm {
        const lib_path = if (opts.libjvm_path) |p|
            try gpa.dupeSentinel(u8, p, 0)
        else
            try findLibJvm(gpa, opts.java_home);
        defer gpa.free(lib_path);

        var lib = std.DynLib.open(lib_path) catch return error.LibJvmLoadFailed;
        errdefer lib.close();

        const create_fn = lib.lookup(jni.CreateJavaVMFn, "JNI_CreateJavaVM") orelse return error.SymbolNotFound;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var options = try std.ArrayList(jni.JavaVMOption).initCapacity(
            arena,
            base_options.len + opts.extra_options.len + 1,
        );
        if (opts.classpath.len > 0) {
            const joined = try std.mem.join(arena, &.{std.fs.path.delimiter}, opts.classpath);
            const cp = try std.fmt.allocPrintSentinel(arena, "-Djava.class.path={s}", .{joined}, 0);
            options.appendAssumeCapacity(.{ .optionString = cp });
        }
        for (base_options) |o| options.appendAssumeCapacity(.{ .optionString = o });
        for (opts.extra_options) |o| {
            options.appendAssumeCapacity(.{ .optionString = try arena.dupeSentinel(u8, o, 0) });
        }

        var args = jni.JavaVMInitArgs{
            .version = jni.JNI_VERSION_1_8,
            .nOptions = @intCast(options.items.len),
            .options = options.items.ptr,
            .ignoreUnrecognized = jni.JNI_TRUE,
        };
        var vm: ?*jni.JavaVM = null;
        var main_env: ?*jni.JNIEnv = null;
        const rc = create_fn(&vm, &main_env, &args);
        if (rc != jni.JNI_OK or vm == null) return error.JvmCreateFailed;
        return .{ .vm = vm.?, .lib = lib, .owned = true };
    }

    /// Use a VM that already exists in the process (Android, or a Java host
    /// that loaded this library). `vm` is the `JavaVM*` from JNI_OnLoad.
    pub fn adopt(vm: *jni.JavaVM) Vm {
        return .{ .vm = vm, .lib = null, .owned = false };
    }

    /// JNIEnv for the calling thread, attaching it as a daemon if necessary.
    /// Attached threads should call `detach` before they exit.
    pub fn env(self: *const Vm) Error!*jni.JNIEnv {
        var out: ?*anyopaque = null;
        const rc = self.vm.f.GetEnv(self.vm, &out, jni.JNI_VERSION_1_8);
        if (rc == jni.JNI_OK and out != null) return @ptrCast(@alignCast(out.?));
        if (rc != jni.JNI_EDETACHED) return error.AttachFailed;
        var attach_args = jni.JavaVMAttachArgs{ .version = jni.JNI_VERSION_1_8, .name = "tachi-native" };
        const arc = self.vm.f.AttachCurrentThreadAsDaemon(self.vm, &out, @ptrCast(&attach_args));
        if (arc != jni.JNI_OK or out == null) return error.AttachFailed;
        return @ptrCast(@alignCast(out.?));
    }

    pub fn detach(self: *const Vm) void {
        _ = self.vm.f.DetachCurrentThread(self.vm);
    }

    /// Destroys the VM if owned. HotSpot cannot be re-created afterwards.
    pub fn destroy(self: *Vm) void {
        if (self.owned) _ = self.vm.f.DestroyJavaVM(self.vm);
        if (self.lib) |*l| l.close();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// libjvm discovery
// ---------------------------------------------------------------------------

const lib_rel_paths: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "lib/server/libjvm.dylib", "lib/libjvm.dylib", "jre/lib/server/libjvm.dylib" },
    .windows => &.{ "bin/server/jvm.dll", "bin/client/jvm.dll", "jre/bin/server/jvm.dll" },
    else => &.{ "lib/server/libjvm.so", "lib/libjvm.so", "jre/lib/server/libjvm.so", "jre/lib/amd64/server/libjvm.so" },
};

/// Returns an owned, NUL-terminated path to libjvm.
pub fn findLibJvm(gpa: std.mem.Allocator, java_home: ?[]const u8) Error![:0]u8 {
    if (getenv("TACHI_LIBJVM")) |p| {
        if (fileExists(p)) return try gpa.dupeSentinel(u8, p, 0);
    }
    if (java_home) |h| {
        if (try probeHome(gpa, h)) |p| return p;
    }
    for ([_][]const u8{ "TACHI_JAVA_HOME", "JAVA_HOME" }) |name| {
        if (getenv(name)) |h| {
            if (try probeHome(gpa, h)) |p| return p;
        }
    }
    switch (builtin.os.tag) {
        .macos => {
            for ([_][]const u8{
                "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
                "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
            }) |h| {
                if (try probeHome(gpa, h)) |p| return p;
            }
            if (try scanDir(gpa, "/Library/Java/JavaVirtualMachines", "/Contents/Home")) |p| return p;
            if (try scanDir(gpa, "/opt/homebrew/Cellar/openjdk", "/libexec/openjdk.jdk/Contents/Home")) |p| return p;
        },
        .linux => {
            if (try scanDir(gpa, "/usr/lib/jvm", "")) |p| return p;
            if (try scanDir(gpa, "/usr/lib64/jvm", "")) |p| return p;
            if (try scanDir(gpa, "/opt", "")) |p| return p;
        },
        else => {},
    }
    return error.LibJvmNotFound;
}

fn probeHome(gpa: std.mem.Allocator, home: []const u8) Error!?[:0]u8 {
    for (lib_rel_paths) |rel| {
        const candidate = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ home, rel }, 0);
        if (fileExists(candidate)) return candidate;
        gpa.free(candidate);
    }
    return null;
}

/// Looks at every entry of `dir`, treating `<dir>/<entry><suffix>` as a Java home.
/// Picks the lexicographically greatest match, which tends to be the newest JDK.
fn scanDir(gpa: std.mem.Allocator, dir: []const u8, suffix: []const u8) Error!?[:0]u8 {
    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);
    const d = std.c.opendir(dir_z) orelse return null;
    defer _ = std.c.closedir(d);

    var best: ?[:0]u8 = null;
    var best_name: ?[]u8 = null;
    defer if (best_name) |n| gpa.free(n);

    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (name.len == 0 or name[0] == '.') continue;
        if (best_name) |bn| {
            if (std.mem.order(u8, name, bn) != .gt) continue;
        }
        const home = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, name, suffix });
        defer gpa.free(home);
        if (try probeHome(gpa, home)) |p| {
            if (best) |b| gpa.free(b);
            if (best_name) |bn| gpa.free(bn);
            best = p;
            best_name = try gpa.dupe(u8, name);
        }
    }
    return best;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const v = std.c.getenv(buf[0..name.len :0]) orelse return null;
    const s = std.mem.sliceTo(v, 0);
    return if (s.len == 0) null else s;
}

pub fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0], 0) == 0;
}
