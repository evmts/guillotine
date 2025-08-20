const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add crypto module dependency
    const crypto_module = b.addModule("crypto", .{
        .root_source_file = b.path("../../../../../src/crypto/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "zig-crypto-bench",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("crypto", crypto_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the crypto benchmarks");
    run_step.dependOn(&run_cmd.step);
}