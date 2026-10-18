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

    // C library (static + shared) exposing include/tachi.h
    const capi_static = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "tachi", .module = tachi_mod }},
    });
    const static_lib = b.addLibrary(.{ .name = "tachi", .linkage = .static, .root_module = capi_static });
    static_lib.installHeader(b.path("include/tachi.h"), "tachi.h");
    b.installArtifact(static_lib);

    const capi_shared = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "tachi", .module = tachi_mod }},
    });
    const shared_lib = b.addLibrary(.{ .name = "tachi", .linkage = .dynamic, .root_module = capi_shared });
    b.installArtifact(shared_lib);

    // CLI
    const cli = b.addExecutable(.{
        .name = "tachi-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "tachi", .module = tachi_mod }},
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    b.step("run", "Run tachi-cli").dependOn(&run_cli.step);

    // Tests (pure Zig; no JVM needed)
    const tests = b.addTest(.{ .root_module = tachi_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Kotlin host jar via Gradle
    const gradle = b.addSystemCommand(&.{ "./gradlew", "shadowJar", "-q" });
    gradle.setCwd(b.path("host"));
    b.step("host", "Build host/build/libs/tachi-host.jar with Gradle").dependOn(&gradle.step);
}
