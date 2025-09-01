const std = @import("std");
const build_pkg = @import("build/main.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build configuration
    const config = build_pkg.Config.createBuildOptions(b, target);
    const rust_target = build_pkg.Config.getRustTarget(target);

    // Dependencies
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = optimize });
    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });

    // Libraries
    const blst_lib = build_pkg.BlstLib.createBlstLibrary(b, target, optimize);
    const c_kzg_lib = build_pkg.CKzgLib.createCKzgLibrary(b, target, optimize, blst_lib);

    const rust_build_step = build_pkg.RevmLib.createRustBuildStep(b, optimize, rust_target);
    const bn254_lib = build_pkg.Bn254Lib.createBn254Library(b, target, optimize, config.options, rust_build_step, rust_target);
    const revm_lib = build_pkg.RevmLib.createRevmLibrary(b, target, optimize, rust_build_step, rust_target);

    // Modules
    const modules = build_pkg.Modules.createModules(b, target, optimize, config.options_mod, zbench_dep, c_kzg_lib, blst_lib, bn254_lib, revm_lib);

    // Executables
    const guillotine_exe = build_pkg.GuillotineExe.createExecutable(b, modules.exe_mod);
    _ = build_pkg.GuillotineExe.createRunStep(b, guillotine_exe);

    const evm_runner = build_pkg.EvmRunnerExe.createEvmRunner(b, target, modules.evm_mod, modules.primitives_mod, c_kzg_lib, blst_lib, bn254_lib);
    const evm_runner_small = build_pkg.EvmRunnerExe.createEvmRunnerSmall(b, target, modules.evm_mod, modules.primitives_mod, c_kzg_lib, blst_lib, bn254_lib);
    build_pkg.EvmRunnerExe.createRunSteps(b, evm_runner, evm_runner_small);

    // Asset generation for devtool
    const asset_generator = build_pkg.AssetGenerator;
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);

    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);

    const generate_assets = asset_generator.GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
    generate_assets.step.dependOn(&npm_build.step);

    const devtool_exe = build_pkg.DevtoolExe.createDevtoolExecutable(b, target, optimize, modules.lib_mod, modules.evm_mod, modules.primitives_mod, modules.provider_mod, &generate_assets.step);
    build_pkg.DevtoolExe.createDevtoolSteps(b, devtool_exe, target);

    // Benchmark executables
    const debug_runner = build_pkg.BenchmarksExe.createDebugRunner(b, target, modules.evm_mod, modules.primitives_mod);
    const crash_debugger = build_pkg.BenchmarksExe.createCrashDebugger(b, target, modules.evm_mod, modules.primitives_mod);
    const simple_crash_test = build_pkg.BenchmarksExe.createSimpleCrashTest(b, target, modules.evm_mod, modules.primitives_mod);

    // Get the build step created by EvmRunnerExe.createRunSteps
    const build_evm_runner_step = b.step("build-evm-runner-manual", "Build the EVM benchmark runner (ReleaseFast)");
    build_evm_runner_step.dependOn(&b.addInstallArtifact(evm_runner, .{}).step);

    _ = build_pkg.BenchmarksExe.createPoopRunner(b, target, build_evm_runner_step);
    _ = build_pkg.BenchmarksExe.createOrchestrator(b, target, clap_dep);
    build_pkg.BenchmarksExe.createBenchmarkSteps(debug_runner, crash_debugger, simple_crash_test, b);

    // Libraries and utilities
    build_pkg.Utils.createLibraries(b, modules.lib_mod, bn254_lib);
    const lib = b.addLibrary(.{ .linkage = .static, .name = "Guillotine", .root_module = modules.lib_mod });
    build_pkg.Utils.createDocsStep(b, lib);
    _ = build_pkg.Utils.createOpcodeTestLib(b, target, optimize, modules.evm_mod, modules.primitives_mod, modules.crypto_mod, config.options_mod, bn254_lib);
    build_pkg.Utils.createExternalBuildSteps(b);

    // Tests
    const tests_pkg = build_pkg.Tests;
    const lib_unit_tests = b.addTest(.{ .root_module = modules.lib_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const integration_tests = tests_pkg.createIntegrationTests(b, target, optimize, modules, revm_lib, bn254_lib, c_kzg_lib, blst_lib, rust_target);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // BN254 benchmarks
    const zbench_module = zbench_dep.module("zbench");
    const zbench_bn254 = b.addExecutable(.{
        .name = "zbench-bn254",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/zbench_benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    zbench_bn254.root_module.addImport("zbench", zbench_module);

    const run_zbench_bn254 = b.addRunArtifact(zbench_bn254);
    const zbench_bn254_step = b.step("bench-bn254", "Run zbench BN254 benchmarks");
    zbench_bn254_step.dependOn(&run_zbench_bn254.step);

    // EVM benchmarks
    const zbench_evm = b.addExecutable(.{
        .name = "zbench-evm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evm/evm_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    zbench_evm.root_module.addImport("zbench", zbench_module);
    zbench_evm.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
    }));
    zbench_evm.root_module.addImport("primitives", modules.primitives_mod);
    zbench_evm.root_module.addImport("evm", modules.evm_mod);
    zbench_evm.root_module.addImport("crypto", modules.crypto_mod);
    if (modules.revm_mod) |revm_mod| {
        zbench_evm.root_module.addImport("revm", revm_mod);
    }
    if (revm_lib) |revm| zbench_evm.linkLibrary(revm);
    if (bn254_lib) |bn254| zbench_evm.linkLibrary(bn254);
    zbench_evm.linkLibrary(c_kzg_lib);
    zbench_evm.linkLibrary(blst_lib);
    zbench_evm.linkLibC();

    const run_zbench_evm = b.addRunArtifact(zbench_evm);
    const zbench_evm_step = b.step("bench-evm", "Run zbench EVM benchmarks");
    zbench_evm_step.dependOn(&run_zbench_evm.step);

    // Language bindings
    build_pkg.WasmBindings.createWasmSteps(b, optimize, config.options_mod);
    build_pkg.PythonBindings.createPythonSteps(b);
    build_pkg.SwiftBindings.createSwiftSteps(b);
    build_pkg.GoBindings.createGoSteps(b);
    build_pkg.TypeScriptBindings.createTypeScriptSteps(b);
}
