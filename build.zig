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

    // Kotlin host jar via Gradle
    const gradle = b.addSystemCommand(&.{ "./gradlew", "shadowJar", "-q" });
    gradle.setCwd(b.path("host"));
    b.step("host", "Build host/build/libs/tachi-host.jar with Gradle").dependOn(&gradle.step);
}
