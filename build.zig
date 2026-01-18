const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{ .name = "zig_http", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Simple server executable
    const simple_exe = b.addExecutable(.{
        .name = "simple_server",

        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simple_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(simple_exe);

    // Simple server run step
    const simple_run_step = b.step("simple", "Run the simple HTTP server");
    const simple_run_cmd = b.addRunArtifact(simple_exe);
    simple_run_step.dependOn(&simple_run_cmd.step);
    simple_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        simple_run_cmd.addArgs(args);
    }
}
