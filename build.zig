const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core module - 核心功能（无外部依赖）
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Utils module - 工具
    const utils_module = b.createModule(.{
        .root_source_file = b.path("src/utils/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Features module - 依赖 core
    const features_module = b.createModule(.{
        .root_source_file = b.path("src/features/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "utils", .module = utils_module },
        },
    });

    // Handlers module - 依赖 core 和 features
    const handlers_module = b.createModule(.{
        .root_source_file = b.path("src/handlers/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "features", .module = features_module },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zig_http",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("core", core_module);
    exe.root_module.addImport("utils", utils_module);
    exe.root_module.addImport("features", features_module);
    exe.root_module.addImport("handlers", handlers_module);

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
