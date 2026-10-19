//! JVM lifecycle: locate libjvm, create or adopt a VM, attach threads.
//!
//! On desktop the library dlopens HotSpot's `libjvm` and calls
//! `JNI_CreateJavaVM` (the JNI Invocation API), the same approach PatchBukkit
//! uses to run Bukkit plugins inside a Rust server. On Android the host app
//! already has a VM; pass it to `adopt` instead.
//!
//! All filesystem and environment access goes through `std.Io` and
//! `std.process.Environ` so callers control where the library looks and tests
//! can run without touching the real process environment.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Environ = std.process.Environ;
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
        /// Path of a class-data-sharing archive the JVM should use, creating
        /// it on first exit (`-XX:+AutoCreateSharedArchive`, JDK 19+). Older
        /// JDKs ignore this. Roughly halves VM start-up on later runs.
        cds_archive: ?[]const u8 = null,
        /// Environment used for $TACHI_LIBJVM / $JAVA_HOME lookups.
        environ: Environ = .empty,
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

    /// Dynamic AppCDS: dump an archive at exit when none is usable, and keep
    /// the dump's "Skipping ...: Signed JAR" warnings off the host's stdout.
    const cds_options = [_][*:0]const u8{
        "-XX:+AutoCreateSharedArchive",
        "-Xlog:cds=off",
    };

    /// Create a new JVM in this process. HotSpot only supports one VM per
    /// process, so call this at most once.
    pub fn create(gpa: std.mem.Allocator, io: Io, opts: CreateOptions) Error!Vm {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const lib_path = if (opts.libjvm_path) |p|
            try arena.dupeSentinel(u8, p, 0)
        else
            try findLibJvm(arena, io, opts.environ, opts.java_home);

        var lib = std.DynLib.open(lib_path) catch return error.LibJvmLoadFailed;
        errdefer lib.close();
        const create_fn = lib.lookup(jni.CreateJavaVMFn, "JNI_CreateJavaVM") orelse return error.SymbolNotFound;

        var options = try std.ArrayList(jni.JavaVMOption).initCapacity(
            arena,
            base_options.len + cds_options.len + 1 + opts.extra_options.len + 1,
        );
        if (opts.classpath.len > 0) {
            const joined = try std.mem.join(arena, &.{std.fs.path.delimiter}, opts.classpath);
            const cp = try std.fmt.allocPrintSentinel(arena, "-Djava.class.path={s}", .{joined}, 0);
            options.appendAssumeCapacity(.{ .optionString = cp });
        }
        for (base_options) |o| options.appendAssumeCapacity(.{ .optionString = o });
        if (opts.cds_archive) |archive| if (jdkMajorVersion(arena, io, lib_path) orelse 0 >= 19) {
            for (cds_options) |o| options.appendAssumeCapacity(.{ .optionString = o });
            const file = try std.fmt.allocPrintSentinel(arena, "-XX:SharedArchiveFile={s}", .{archive}, 0);
            options.appendAssumeCapacity(.{ .optionString = file });
        };
        for (opts.extra_options) |o| {
            options.appendAssumeCapacity(.{ .optionString = try arena.dupeSentinel(u8, o, 0) });
        }

        var args: jni.JavaVMInitArgs = .{
            .version = jni.JNI_VERSION_1_8,
            .nOptions = @intCast(options.items.len),
            .options = options.items.ptr,
            .ignoreUnrecognized = jni.JNI_TRUE,
        };
        var vm: ?*jni.JavaVM = null;
        var main_env: ?*jni.JNIEnv = null;
        if (create_fn(&vm, &main_env, &args) != jni.JNI_OK) return error.JvmCreateFailed;
        return .{ .vm = vm orelse return error.JvmCreateFailed, .lib = lib, .owned = true };
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
        switch (self.vm.f.GetEnv(self.vm, &out, jni.JNI_VERSION_1_8)) {
            jni.JNI_OK => {},
            jni.JNI_EDETACHED => {
                var attach_args: jni.JavaVMAttachArgs = .{ .version = jni.JNI_VERSION_1_8, .name = "tachi-native" };
                if (self.vm.f.AttachCurrentThreadAsDaemon(self.vm, &out, @ptrCast(&attach_args)) != jni.JNI_OK)
                    return error.AttachFailed;
            },
            else => return error.AttachFailed,
        }
        return @ptrCast(@alignCast(out orelse return error.AttachFailed));
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

/// Where libjvm lives relative to a Java home, per platform.
const lib_rel_paths: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "lib/server/libjvm.dylib", "lib/libjvm.dylib", "jre/lib/server/libjvm.dylib" },
    .windows => &.{ "bin/server/jvm.dll", "bin/client/jvm.dll", "jre/bin/server/jvm.dll" },
    else => &.{ "lib/server/libjvm.so", "lib/libjvm.so", "jre/lib/server/libjvm.so", "jre/lib/amd64/server/libjvm.so" },
};

/// A directory whose children are Java installations; `suffix` turns a child into a Java home.
const ScanRoot = struct { dir: []const u8, suffix: []const u8 = "" };

/// Well-known install locations, tried after the environment. Fixed homes
/// first, then directories scanned for the newest-looking JDK.
const well_known: struct { homes: []const []const u8, scan: []const ScanRoot } = switch (builtin.os.tag) {
    .macos => .{
        .homes = &.{
            "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
            "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        },
        .scan = &.{
            .{ .dir = "/Library/Java/JavaVirtualMachines", .suffix = "/Contents/Home" },
            .{ .dir = "/opt/homebrew/Cellar/openjdk", .suffix = "/libexec/openjdk.jdk/Contents/Home" },
        },
    },
    .linux => .{
        .homes = &.{},
        .scan = &.{ .{ .dir = "/usr/lib/jvm" }, .{ .dir = "/usr/lib64/jvm" }, .{ .dir = "/opt" } },
    },
    else => .{ .homes = &.{}, .scan = &.{} },
};

/// Major Java version of the installation containing `libjvm_path`, read from
/// its `release` file (`JAVA_VERSION="17.0.1"` -> 17, `"1.8.0_292"` -> 8).
pub fn jdkMajorVersion(gpa: std.mem.Allocator, io: Io, libjvm_path: []const u8) ?u32 {
    // <home>/lib/server/libjvm.so or <home>/lib/libjvm.so: walk up until a release file appears.
    var dir = std.fs.path.dirname(libjvm_path);
    var depth: usize = 0;
    while (dir) |d| : ({
        dir = std.fs.path.dirname(d);
        depth += 1;
    }) {
        if (depth > 3) break;
        const release = std.fs.path.join(gpa, &.{ d, "release" }) catch return null;
        defer gpa.free(release);
        const text = Io.Dir.cwd().readFileAlloc(io, release, gpa, .limited(64 << 10)) catch continue;
        defer gpa.free(text);
        return parseJavaVersion(text);
    }
    return null;
}

fn parseJavaVersion(release: []const u8) ?u32 {
    const key = "JAVA_VERSION=\"";
    const start = (std.mem.indexOf(u8, release, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, release, start, '"') orelse return null;
    var it = std.mem.splitScalar(u8, release[start..end], '.');
    const first = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (first != 1) return first;
    // Pre-9 scheme: 1.8.0_292
    return std.fmt.parseInt(u32, it.next() orelse return null, 10) catch null;
}

/// Returns an owned, NUL-terminated path to libjvm.
pub fn findLibJvm(gpa: std.mem.Allocator, io: Io, environ: Environ, java_home: ?[]const u8) Error![:0]u8 {
    if (getenv(environ, "TACHI_LIBJVM")) |p| {
        if (fileExists(io, p)) return try gpa.dupeSentinel(u8, p, 0);
    }
    if (java_home) |h| {
        if (try probeHome(gpa, io, h)) |p| return p;
    }
    for ([_][]const u8{ "TACHI_JAVA_HOME", "JAVA_HOME" }) |name| {
        const h = getenv(environ, name) orelse continue;
        if (try probeHome(gpa, io, h)) |p| return p;
    }
    for (well_known.homes) |h| {
        if (try probeHome(gpa, io, h)) |p| return p;
    }
    for (well_known.scan) |root| {
        if (try scanDir(gpa, io, root)) |p| return p;
    }
    return error.LibJvmNotFound;
}

fn probeHome(gpa: std.mem.Allocator, io: Io, home: []const u8) Error!?[:0]u8 {
    for (lib_rel_paths) |rel| {
        const candidate = try std.fs.path.joinZ(gpa, &.{ home, rel });
        if (fileExists(io, candidate)) return candidate;
        gpa.free(candidate);
    }
    return null;
}

/// Looks at every entry of `root.dir`, treating `<dir>/<entry><suffix>` as a
/// Java home. Picks the lexicographically greatest match, which tends to be
/// the newest JDK.
fn scanDir(gpa: std.mem.Allocator, io: Io, root: ScanRoot) Error!?[:0]u8 {
    var dir = Io.Dir.cwd().openDir(io, root.dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: ?[:0]u8 = null;
    errdefer if (best) |b| gpa.free(b);
    var best_name: std.ArrayList(u8) = .empty;
    defer best_name.deinit(gpa);

    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.name.len == 0 or ent.name[0] == '.') continue;
        if (best != null and std.mem.order(u8, ent.name, best_name.items) != .gt) continue;
        const home = try std.mem.concat(gpa, u8, &.{ root.dir, "/", ent.name, root.suffix });
        defer gpa.free(home);
        const found = try probeHome(gpa, io, home) orelse continue;
        if (best) |b| gpa.free(b);
        best = found;
        best_name.clearRetainingCapacity();
        try best_name.appendSlice(gpa, ent.name);
    }
    return best;
}

/// Environment lookup that treats an empty value as unset.
pub fn getenv(environ: Environ, name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null; // TODO: WTF-16 lookup via getWindows.
    const v = environ.getPosix(name) orelse return null;
    return if (v.len == 0) null else v;
}

pub fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "well-known scan roots exist for the build target" {
    for (well_known.scan) |root| try std.testing.expect(std.fs.path.isAbsolute(root.dir));
}

test "getenv ignores empty values" {
    const block = [_:null]?[*:0]const u8{ "A=1", "EMPTY=", "B=two" };
    const environ: Environ = .{ .block = .{ .slice = &block } };
    try std.testing.expectEqualStrings("1", getenv(environ, "A").?);
    try std.testing.expectEqualStrings("two", getenv(environ, "B").?);
    try std.testing.expect(getenv(environ, "EMPTY") == null);
    try std.testing.expect(getenv(environ, "MISSING") == null);
}
