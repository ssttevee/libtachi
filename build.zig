const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("tachicore", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Public Zig module: @import("tachi")
    const tachi_mod = b.addModule("tachi", .{
        .root_source_file = b.path("src/tachi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tachi_mod.addImport("tachicore", core_mod);
    // Compile the pinned amalgamation into every consumer; do not depend on a
    // firmware-provided SQLite shared library or its build options.
    const sqlite = b.dependency("sqlite", .{});
    tachi_mod.addIncludePath(sqlite.path(""));
    tachi_mod.addCSourceFile(.{ .file = sqlite.path("sqlite3.c"), .flags = &.{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_DEFAULT_MMAP_SIZE=0",
    } });
    // Spawning the worker process and its socket calls.
    tachi_mod.addCSourceFile(.{ .file = b.path("src/worker_posix.c"), .flags = &.{} });
    tachi_mod.addCSourceFile(.{ .file = b.path("src/formats_time.c"), .flags = &.{} });

    const android_jar = b.option([]const u8, "android-jar", "android.jar for Gradle (default: newest installed platform)");

    // Kotlin host jar: built by Gradle as a cached step unless -Dhost-jar names one.
    const host_jar = if (b.option(
        []const u8,
        "host-jar",
        "Use this tachi-host.jar instead of building it with Gradle",
    )) |path| sourcePath(b, path) else gradleHostJar(b, android_jar);
    const embed_host_jar = b.option(
        bool,
        "embed-host-jar",
        "Embed tachi-host.jar in the library and CLI so nothing else needs to be distributed (default: false)",
    ) orelse false;
    core_mod.addImport("host_jar", embeddedHostJar(b, if (embed_host_jar) host_jar else null));

    // Modules that depend on the library share one shape; only the root differs.
    const dependent = struct {
        fn module(bb: *std.Build, root: []const u8, lib: *std.Build.Module) *std.Build.Module {
            return bb.createModule(.{
                .root_source_file = bb.path(root),
                .target = lib.resolved_target.?,
                .optimize = lib.optimize.?,
                .link_libc = true,
                .imports = &.{.{ .name = "tachi", .module = lib }},
            });
        }
    }.module;

    // C library (static + shared) exposing include/tachi.h. Each linkage gets
    // its own module because a module can only belong to one compilation.
    const capi_static = dependent(b, "src/capi.zig", tachi_mod);
    const static_lib = b.addLibrary(.{ .name = "tachi", .linkage = .static, .root_module = capi_static });
    static_lib.installHeader(b.path("include/tachi.h"), "tachi.h");
    b.installArtifact(static_lib);

    const capi_shared = dependent(b, "src/capi.zig", tachi_mod);
    const shared_lib = b.addLibrary(.{ .name = "tachi", .linkage = .dynamic, .root_module = capi_shared });
    b.installArtifact(shared_lib);

    // CLI
    const cli = b.addExecutable(.{ .name = "tachi-cli", .root_module = dependent(b, "src/main.zig", tachi_mod) });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    b.step("run", "Run tachi-cli").dependOn(&run_cli.step);

    // Tests (pure Zig; no JVM needed). The library and the C ABI each have their own.
    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ tachi_mod, capi_static }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    const core_tests = b.addRunArtifact(b.addTest(.{ .root_module = core_mod }));
    test_step.dependOn(&core_tests.step);
    b.step("test-core", "Test the independent extension core").dependOn(&core_tests.step);

    // Opt-in integration test: a real JVM and test-only synthetic sources.
    const fixture_jar = b.addSystemCommand(&.{ "./gradlew", "cancellationFixtureJar", "-q" });
    fixture_jar.setCwd(b.path("host"));
    const fixture_dir = fixture_jar.addPrefixedOutputDirectoryArg("-Ptachi.outputDir=", "fixtures");
    if (android_jar) |path|
        fixture_jar.addPrefixedFileArg("-Ptachi.androidJar=", sourcePath(b, path));
    for ([_][]const u8{ "host/src", "host/gradle" }) |dir| addFileInputsUnder(b, fixture_jar, dir);
    fixture_jar.addFileInput(b.path("host/build.gradle.kts"));
    const jvm_test = b.addExecutable(.{ .name = "test-jvm-cancellation", .root_module = dependent(b, "tools/test_jvm_cancellation.zig", tachi_mod) });
    const run_jvm_test = b.addRunArtifact(jvm_test);
    run_jvm_test.addFileArg(host_jar);
    run_jvm_test.addFileArg(fixture_dir.path(b, "cancellation-fixture.jar"));
    b.step("test-jvm", "Test operation cancellation through a real JVM").dependOn(&run_jvm_test.step);

    // Without embedding, the jar ships beside the library; the runtime looks in
    // <prefix>/lib relative to the executable. `zig build host` builds just that.
    const install_jar = b.addInstallLibFile(host_jar, "tachi-host.jar");
    if (!embed_host_jar) b.getInstallStep().dependOn(&install_jar.step);
    b.step("host", "Build tachi-host.jar and copy it to <prefix>/lib").dependOn(&install_jar.step);

    // libzstd's decoder and the JNI bridge behind okhttp3.zstd.Zstd, for -Dtarget.
    // The host loads it from disk, so consumers install the named lazy paths
    // `pocketmanga-zstd` and `zstd-license` wherever their JVM looks.
    const zstd_step = b.step("zstd", "Build libpocketmanga-zstd for -Dtarget into <prefix>/lib");
    if (b.lazyDependency("zstd", .{})) |upstream| {
        const jdk = b.option([]const u8, "jdk", "JDK whose include/jni.h the zstd bridge compiles against (default: $JAVA_HOME)") orelse
            b.graph.environ_map.get("JAVA_HOME");
        const zstd = zstdJni(b, upstream, jdk, target, optimize);
        b.addNamedLazyPath("pocketmanga-zstd", zstd.getEmittedBin());
        b.addNamedLazyPath("zstd-license", upstream.path("LICENSE"));
        zstd_step.dependOn(&b.addInstallArtifact(zstd, .{}).step);
        zstd_step.dependOn(&b.addInstallFile(upstream.path("LICENSE"), "share/licenses/zstd-LICENSE.txt").step);
    }
}

/// Runs `gradlew shadowJar` into a zig cache directory. The step is cached on
/// the Gradle build files and host sources, so it only runs when they change.
fn gradleHostJar(b: *std.Build, android_jar: ?[]const u8) std.Build.LazyPath {
    const gradle = b.addSystemCommand(&.{ "./gradlew", "shadowJar", "-q" });
    gradle.setCwd(b.path("host"));
    const out_dir = gradle.addPrefixedOutputDirectoryArg("-Ptachi.outputDir=", "libs");
    if (android_jar) |path| gradle.addPrefixedFileArg("-Ptachi.androidJar=", sourcePath(b, path));
    gradle.setName("gradle shadowJar");
    for ([_][]const u8{ "build.gradle.kts", "settings.gradle.kts", "gradle.properties", "gradlew" }) |file| {
        gradle.addFileInput(b.path(b.pathJoin(&.{ "host", file })));
    }
    for ([_][]const u8{ "host/gradle", "host/src" }) |dir| addFileInputsUnder(b, gradle, dir);
    return out_dir.path(b, "tachi-host.jar");
}

fn addFileInputsUnder(b: *std.Build, run: *std.Build.Step.Run, sub_path: []const u8) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, fsPath(b, sub_path), .{ .iterate = true }) catch |e|
        std.debug.panic("{s}: {s}", .{ sub_path, @errorName(e) });
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |e| std.debug.panic("{s}: {s}", .{ sub_path, @errorName(e) })) |entry| {
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ sub_path, entry.path })));
    }
}

/// Upstream lib/common and lib/decompress plus host/native/zstd_jni.c. Legacy
/// formats and assembly stay off, and word access goes through memcpy, so the
/// same source suits ARMv7 with strict alignment.
fn zstdJni(b: *std.Build, upstream: *std.Build.Dependency, jdk: ?[]const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .strip = true });
    module.addIncludePath(b.path("host/native/include"));
    module.addIncludePath(upstream.path("lib"));
    module.addCSourceFiles(.{
        .root = upstream.path("lib"),
        .files = &.{
            "common/debug.c",          "common/entropy_common.c",      "common/error_private.c",
            "common/fse_decompress.c", "common/pool.c",                "common/threading.c",
            "common/xxhash.c",         "common/zstd_common.c",         "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c", "decompress/zstd_decompress.c", "decompress/zstd_decompress_block.c",
        },
        .flags = &.{ "-fvisibility=hidden", "-DZSTD_DISABLE_ASM", "-DZSTD_LEGACY_SUPPORT=0", "-DZSTD_FORCE_MEMORY_ACCESS=0" },
    });
    module.addCSourceFile(.{ .file = b.path("host/native/zstd_jni.c"), .flags = &.{"-fvisibility=hidden"} });
    const lib = b.addLibrary(.{ .name = "pocketmanga-zstd", .linkage = .dynamic, .root_module = module });
    // jni.h comes from a JDK; host/native/include supplies the Linux jni_md.h.
    if (jdk) |home| {
        module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ home, "include" }) });
    } else {
        lib.step.dependOn(&b.addFail("libpocketmanga-zstd needs jni.h: pass -Djdk=<path> or set JAVA_HOME").step);
    }
    return lib;
}

/// `b.path` only takes project-relative paths; options may be absolute.
fn sourcePath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

/// The same path for reading at configure time, which may run outside the project root.
fn fsPath(b: *std.Build, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return b.root.joinString(b.allocator, path) catch @panic("OOM");
}

/// A module exposing `bytes: ?[]const u8` and `hash: []const u8` for the host
/// jar. Without `-Dembed-host-jar`, `bytes` is null and the runtime looks for
/// the jar on disk. Otherwise tools/embed_host_jar.zig hashes the jar in a
/// cached step, and the jar is copied next to the generated source for
/// @embedFile.
fn embeddedHostJar(b: *std.Build, jar: ?std.Build.LazyPath) *std.Build.Module {
    const wf = b.addWriteFiles();
    const source = if (jar) |path| blk: {
        const tool = b.addExecutable(.{ .name = "embed_host_jar", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_host_jar.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }) });
        const gen = b.addRunArtifact(tool);
        gen.addFileArg(path);
        const generated = gen.addOutputFileArg("host_jar.zig");
        _ = wf.addCopyFile(path, "tachi-host.jar");
        break :blk wf.addCopyFile(generated, "host_jar.zig");
    } else wf.add("host_jar.zig",
        \\pub const bytes: ?[]const u8 = null;
        \\pub const hash = "";
        \\
    );
    return b.createModule(.{ .root_source_file = source });
}
