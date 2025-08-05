const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import the main Guillotine project root
    const project_root = b.path("../../../..");
    
    // Create modules by importing from the project
    const evm_module = b.createModule(.{
        .root_source_file = project_root.path("src/evm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const primitives_module = b.createModule(.{
        .root_source_file = project_root.path("src/primitives/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const crypto_module = b.createModule(.{
        .root_source_file = project_root.path("src/crypto/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const build_options_module = b.createModule(.{
        .root_source_file = b.path("build_options.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Set up module dependencies
    evm_module.addImport("primitives", primitives_module);
    evm_module.addImport("crypto", crypto_module);
    evm_module.addImport("build_options", build_options_module);
    crypto_module.addImport("primitives", primitives_module);
    primitives_module.addImport("build_options", build_options_module);

    const exe = b.addExecutable(.{
        .name = "evm-runner-advanced",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("evm", evm_module);
    exe.root_module.addImport("primitives", primitives_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}