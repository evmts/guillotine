const std = @import("std");
const modules = @import("modules.zig");

pub fn setupBenchmarks(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget) void {
    // EVM Benchmark Runner executable (always optimized for benchmarks)
    const evm_runner = b.addExecutable(.{
        .name = "evm-runner",
        .root_source_file = b.path("bench/official/evms/zig/src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
    });
    evm_runner.root_module.addImport("evm", mods.evm);
    evm_runner.root_module.addImport("primitives", mods.primitives);
    b.installArtifact(evm_runner);

    const run_evm_runner_cmd = b.addRunArtifact(evm_runner);
    run_evm_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_evm_runner_cmd.addArgs(args);
    }
    const evm_runner_step = b.step("evm-runner", "Run the EVM benchmark runner");
    evm_runner_step.dependOn(&run_evm_runner_cmd.step);

    const build_evm_runner_step = b.step("build-evm-runner", "Build the EVM benchmark runner");
    build_evm_runner_step.dependOn(&evm_runner.step);

    // Benchmark orchestrator
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    
    const orchestrator = b.addExecutable(.{
        .name = "orchestrator",
        .root_source_file = b.path("bench/official/src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    orchestrator.root_module.addImport("clap", clap_dep.module("clap"));
    b.installArtifact(orchestrator);

    const run_orchestrator_cmd = b.addRunArtifact(orchestrator);
    run_orchestrator_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_orchestrator_cmd.addArgs(args);
    }
    const orchestrator_step = b.step("orchestrator", "Run the benchmark orchestrator");
    orchestrator_step.dependOn(&run_orchestrator_cmd.step);

    const build_orchestrator_step = b.step("build-orchestrator", "Build the benchmark orchestrator");
    build_orchestrator_step.dependOn(&orchestrator.step);

    // Poop benchmark runner
    const poop_runner = b.addExecutable(.{
        .name = "poop-runner",
        .root_source_file = b.path("bench/poop_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
    });
    poop_runner.root_module.addImport("primitives", mods.primitives);
    poop_runner.root_module.addImport("evm", mods.evm);
    b.installArtifact(poop_runner);

    const run_poop_cmd = b.addRunArtifact(poop_runner);
    run_poop_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_poop_cmd.addArgs(args);
    }
    const poop_step = b.step("poop", "Run poop benchmark on snailtracer (Linux only)");
    poop_step.dependOn(&run_poop_cmd.step);

    // Comparison benchmarks
    const compare_run = b.addSystemCommand(&[_][]const u8{
        "./bench/official/evms/compare.sh",
        "--guillotine-path",
        "../../zig-out/bin/evm-runner",
        "--js-runs=1",
        "--js-internal-runs=1",
    });
    const compare_step = b.step("bench-compare", "Run EVM comparison benchmarks with --js-runs=1 --js-internal-runs=1 by default");
    compare_step.dependOn(&compare_run.step);

    // Setup external EVM builds for comparison
    const geth_runner_build = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", "../bin/evm-runner", "./runner" });
    geth_runner_build.setCwd(b.path("bench/official/evms/geth"));
    compare_run.step.dependOn(&geth_runner_build.step);

    const evmone_cmake_configure = b.addSystemCommand(&[_][]const u8{ "cmake", "-S", "bench/official/evms/evmone", "-B", "bench/official/evms/evmone/build", "-DCMAKE_BUILD_TYPE=Release" });
    compare_run.step.dependOn(&evmone_cmake_configure.step);

    const evmone_cmake_build = b.addSystemCommand(&[_][]const u8{ "cmake", "--build", "bench/official/evms/evmone/build", "--parallel" });
    evmone_cmake_build.step.dependOn(&evmone_cmake_configure.step);
    compare_run.step.dependOn(&evmone_cmake_build.step);

    // Make benchmark targets depend on runner builds
    compare_run.step.dependOn(&evm_runner.step);

    // Snail shell benchmark test
    const snail_shell_benchmark_test = b.addTest(.{
        .name = "snail-shell-benchmark-test",
        .root_source_file = b.path("src/solidity/snail_shell_benchmark_test.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    snail_shell_benchmark_test.root_module.addImport("primitives", mods.primitives);
    snail_shell_benchmark_test.root_module.addImport("evm", mods.evm);

    const run_snail_shell_benchmark_test = b.addRunArtifact(snail_shell_benchmark_test);
    const snail_shell_benchmark_test_step = b.step("test-benchmark", "Run SnailShellBenchmark tests");
    snail_shell_benchmark_test_step.dependOn(&run_snail_shell_benchmark_test.step);
}