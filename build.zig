const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public Zig module: @import("tachi")
    const tachi_mod = b.addModule("tachi", .{
        .root_source_file = b.path("src/tachi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const host_jar = b.option(
        []const u8,
        "host-jar",
        "Path to tachi-host.jar (default: host/build/libs/tachi-host.jar)",
    ) orelse "host/build/libs/tachi-host.jar";
    const embed_host_jar = b.option(
        bool,
        "embed-host-jar",
        "Embed tachi-host.jar in the library and CLI so nothing else needs to be distributed (default: false)",
    ) orelse false;
    tachi_mod.addImport("host_jar", embeddedHostJar(b, if (embed_host_jar) host_jar else null));

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

    // Kotlin host jar via Gradle. `zig build host` builds it and copies it to
    // <prefix>/lib, where the runtime looks next to the executable.
    const gradle = b.addSystemCommand(&.{ "./gradlew", "shadowJar", "-q" });
    gradle.setCwd(b.path("host"));
    const install_built_jar = b.addInstallLibFile(sourcePath(b, host_jar), "tachi-host.jar");
    install_built_jar.step.dependOn(&gradle.step);
    b.step("host", "Build tachi-host.jar with Gradle and copy it to <prefix>/lib").dependOn(&install_built_jar.step);

    // A plain `zig build` copies an already built jar too, unless it is embedded.
    // A missing jar is not an error here: the runtime may be pointed at one.
    if (!embed_host_jar and fileExists(b, host_jar)) {
        b.getInstallStep().dependOn(&b.addInstallLibFile(sourcePath(b, host_jar), "tachi-host.jar").step);
    }
}

/// `b.path` only takes project-relative paths; `-Dhost-jar` may be absolute.
fn sourcePath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

/// The same path for reading at configure time, which may run outside the project root.
fn fsPath(b: *std.Build, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return b.root.joinString(b.allocator, path) catch @panic("OOM");
}

fn fileExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, fsPath(b, path), .{}) catch return false;
    return true;
}

/// A module exposing `bytes: ?[]const u8` and `hash: []const u8` for the host
/// jar. Without `-Dembed-host-jar`, `bytes` is null and the runtime looks for
/// the jar on disk. The hash names the extracted copy and its CDS archive, so a
/// rebuilt jar never collides with a stale cache entry.
fn embeddedHostJar(b: *std.Build, jar: ?[]const u8) *std.Build.Module {
    const wf = b.addWriteFiles();
    const source = if (jar) |path| blk: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, fsPath(b, path), b.allocator, .limited(1 << 30)) catch |e|
            std.debug.panic("-Dembed-host-jar: cannot read {s} ({s}); run `zig build host` first", .{ path, @errorName(e) });
        const hash = std.hash.Wyhash.hash(0, bytes);
        _ = wf.addCopyFile(sourcePath(b, path), "tachi-host.jar");
        break :blk b.fmt(
            \\pub const bytes: ?[]const u8 = @embedFile("tachi-host.jar");
            \\pub const hash = "{x:0>16}";
            \\
        , .{hash});
    } else
        \\pub const bytes: ?[]const u8 = null;
        \\pub const hash = "";
        \\
    ;
    return b.createModule(.{ .root_source_file = wf.add("host_jar.zig", source) });
}
