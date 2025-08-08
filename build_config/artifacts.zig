const std = @import("std");
const modules = @import("modules.zig");
const rust = @import("rust.zig");

pub fn buildArtifacts(b: *std.Build, mods: modules.Modules, rust_libs: rust.RustLibraries, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Create compilers module
    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("src/compilers/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("primitives", mods.primitives);
    compilers_mod.addImport("evm", mods.evm);

    // Add compilers module to lib_mod
    mods.lib.addImport("compilers", compilers_mod);

    // Static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "Guillotine",
        .root_module = mods.lib,
    });

    // Link BN254 Rust library to the library artifact (if enabled)
    if (rust_libs.bn254_lib) |bn254| {
        lib.linkLibrary(bn254);
        lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    // Install static library
    b.installArtifact(lib);

    // Create shared library for Python FFI
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "Guillotine",
        .root_module = mods.lib,
    });

    // Link BN254 Rust library to the shared library artifact (if enabled)
    if (rust_libs.bn254_lib) |bn254| {
        shared_lib.linkLibrary(bn254);
        shared_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(shared_lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = mods.exe,
    });
    b.installArtifact(exe);

    // Add run command for the executable
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Add evm_test_runner executable
    const evm_test_runner = b.addExecutable(.{
        .name = "evm_test_runner",
        .root_source_file = b.path("src/evm_test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_test_runner.root_module.addImport("evm", mods.evm);
    evm_test_runner.root_module.addImport("primitives", mods.primitives);
    b.installArtifact(evm_test_runner);
}