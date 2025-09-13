const std = @import("std");

pub fn createLibraries(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    bn254_lib: ?*std.Build.Step.Compile,
) void {
    // Static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "Guillotine",
        .root_module = lib_mod,
    });

    if (bn254_lib) |bn254| {
        lib.linkLibrary(bn254);
        lib.addIncludePath(b.path("lib/ark"));
    }

    b.installArtifact(lib);

    // Dynamic library
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "Guillotine",
        .root_module = lib_mod,
    });

    if (bn254_lib) |bn254| {
        shared_lib.linkLibrary(bn254);
        shared_lib.addIncludePath(b.path("lib/ark"));
    }

    b.installArtifact(shared_lib);
}

pub fn createDocsStep(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const docs_step = b.step("docs", "Generate and install documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);
}

pub fn createOpcodeTestLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evm_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    build_options_mod: *std.Build.Module,
    bn254_lib: ?*std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "guillotine_opcode_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm_opcode_test_ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    lib.root_module.addImport("evm", evm_mod);
    lib.root_module.addImport("primitives", primitives_mod);
    lib.root_module.addImport("crypto", crypto_mod);
    lib.root_module.addImport("build_options", build_options_mod);

    if (bn254_lib) |bn254| {
        lib.linkLibrary(bn254);
        lib.addIncludePath(b.path("lib/ark"));
    }

    b.installArtifact(lib);
    return lib;
}


pub fn createExternalBuildSteps(b: *std.Build) void {
    const geth_runner_build = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", "runner", "runner.go" });
    geth_runner_build.setCwd(b.path("bench/evms/geth"));

    const evmone_cmake_configure = b.addSystemCommand(&[_][]const u8{ "cmake", "-S", "bench/evms/evmone", "-B", "bench/evms/evmone/build", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" });
    evmone_cmake_configure.setCwd(b.path(""));

    const evmone_cmake_build = b.addSystemCommand(&[_][]const u8{ "cmake", "--build", "bench/evms/evmone/build", "--parallel" });
    evmone_cmake_build.setCwd(b.path(""));
    evmone_cmake_build.step.dependOn(&evmone_cmake_configure.step);
}