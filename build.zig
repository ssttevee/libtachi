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
    tachi_mod.addImport("host_jar", embeddedHostJar(b, b.option(
        []const u8,
        "host-jar",
        "Embed this tachi-host.jar in the library so nothing else needs to be distributed",
    )));

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

    // Kotlin host jar via Gradle (`zig build host`, then `zig build -Dhost-jar=host/build/libs/tachi-host.jar`)
    const gradle = b.addSystemCommand(&.{ "./gradlew", "shadowJar", "-q" });
    gradle.setCwd(b.path("host"));
    b.step("host", "Build host/build/libs/tachi-host.jar with Gradle").dependOn(&gradle.step);
}

/// A module exposing `bytes: ?[]const u8` and `hash: []const u8` for the host
/// jar. With no `-Dhost-jar`, `bytes` is null and the runtime looks for the
/// jar on disk. The hash names the extracted copy and its CDS archive, so a
/// rebuilt jar never collides with a stale cache entry.
fn embeddedHostJar(b: *std.Build, jar: ?[]const u8) *std.Build.Module {
    const wf = b.addWriteFiles();
    const source = if (jar) |path| blk: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 30)) catch |e|
            std.debug.panic("-Dhost-jar={s}: {s}", .{ path, @errorName(e) });
        const hash = std.hash.Wyhash.hash(0, bytes);
        _ = wf.addCopyFile(b.path(path), "tachi-host.jar");
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
