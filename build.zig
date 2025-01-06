const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zeit = b.dependency("zeit", .{ .target = target, .optimize = optimize }).module("zeit");

    const lsp = b.addModule("lsp", .{
        .root_source_file = b.path("lsp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sls",
        .root_source_file = b.path("sls.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("lsp", lsp);
    exe.root_module.addImport("zeit", zeit);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_source_file = b.path("sls.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("lsp", lsp);
    tests.root_module.addImport("zeit", zeit);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
