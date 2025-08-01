const std = @import("std");
const packages = @import("build_config/packages.zig");
const executables = @import("build_config/executables.zig");
const tests_mod = @import("build_config/tests.zig");
const typescript = @import("build_utils/typescript.zig");
const wasm = @import("build_utils/wasm.zig");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Custom build option to disable precompiles
    const no_precompiles = b.option(bool, "no_precompiles", "Disable all EVM precompiles for minimal build") orelse false;
    
    // Detect Ubuntu native build (has Rust library linking issues)
    const force_bn254 = b.option(bool, "force_bn254", "Force BN254 even on Ubuntu") orelse false;
    const is_ubuntu_native = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and !force_bn254;
    
    // Disable BN254 on Ubuntu native builds to avoid Rust library linking issues
    const no_bn254 = no_precompiles or is_ubuntu_native;
    
    // Determine the Rust target triple based on the Zig target
    const rust_target = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => null,
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => null,
        },
        else => null,
    };
    
    // Create all packages
    const pkgs = packages.createAllPackages(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .no_precompiles = no_precompiles,
        .no_bn254 = no_bn254,
        .rust_target = rust_target,
    });
    
    // Create benchmark packages
    const bench_packages = packages.createBenchPackages(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .no_precompiles = no_precompiles,
        .no_bn254 = no_bn254,
        .rust_target = rust_target,
    });
    
    // Create libraries
    const lib = executables.createStaticLibrary(b, pkgs.lib_mod, pkgs.bn254_lib);
    b.installArtifact(lib);
    
    const shared_lib = executables.createSharedLibrary(b, pkgs.lib_mod, pkgs.bn254_lib);
    b.installArtifact(shared_lib);
    
    // Create main executable
    const exe = executables.createMainExecutable(b, target, optimize, pkgs.lib_mod);
    b.installArtifact(exe);
    
    // Create run step for main executable
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    
    // Create other executables
    const evm_test_runner = executables.createEvmTestRunner(b, target, optimize, pkgs.evm_mod, pkgs.primitives_mod);
    b.installArtifact(evm_test_runner);
    
    const evm_runner_exe = executables.createEvmRunner(b, target, optimize, pkgs.evm_mod, pkgs.primitives_mod);
    b.installArtifact(evm_runner_exe);
    
    const evm_runner_cmd = b.addRunArtifact(evm_runner_exe);
    evm_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        evm_runner_cmd.addArgs(args);
    }
    const evm_runner_step = b.step("evm-runner", "Run the EVM benchmark runner");
    evm_runner_step.dependOn(&evm_runner_cmd.step);
    
    const build_evm_runner_step = b.step("build-evm-runner", "Build the EVM benchmark runner");
    build_evm_runner_step.dependOn(&b.addInstallArtifact(evm_runner_exe, .{}).step);
    
    // Create benchmark orchestrator
    const orchestrator_exe = executables.createOrchestratorExecutable(b, target, optimize, pkgs.clap_dep);
    b.installArtifact(orchestrator_exe);
    
    _ = executables.setupOrchestratorSteps(b, orchestrator_exe);
    
    // Create opcode test library
    const opcode_test_lib = executables.createOpcodeTestLib(b, target, optimize, pkgs);
    b.installArtifact(opcode_test_lib);
    
    // Create benchmark executables
    const bench_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
    const bench_exe = executables.createBenchExecutable(b, target, bench_packages, pkgs, bench_optimize);
    // TEMPORARILY DISABLED: benchmark compilation issue
    // b.installArtifact(bench_exe);
    
    const run_bench_cmd = b.addRunArtifact(bench_exe);
    run_bench_cmd.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench_cmd.step);
    
    const revm_bench_exe = executables.createRevmBenchExecutable(b, target, bench_packages, pkgs, bench_optimize);
    b.installArtifact(revm_bench_exe);
    
    const run_revm_bench_cmd = b.addRunArtifact(revm_bench_exe);
    run_revm_bench_cmd.step.dependOn(b.getInstallStep());
    const revm_bench_step = b.step("bench-revm", "Run revm comparison benchmarks");
    revm_bench_step.dependOn(&run_revm_bench_cmd.step);
    
    // Flamegraph profiling support
    const flamegraph_step = b.step("flamegraph", "Run benchmarks with flamegraph profiling");
    const profile_bench_exe = executables.createProfileBenchExecutable(b, target, bench_packages, pkgs);
    
    // Platform-specific profiling commands
    if (target.result.os.tag == .linux) {
        const perf_cmd = b.addSystemCommand(&[_][]const u8{
            "perf", "record", "-F", "997", "-g", "--call-graph", "dwarf",
            "-o", "perf.data",
        });
        perf_cmd.addArtifactArg(profile_bench_exe);
        perf_cmd.addArg("--profile");
        
        const flamegraph_cmd = b.addSystemCommand(&[_][]const u8{
            "flamegraph", "--perfdata", "perf.data", "-o", "guillotine-bench.svg",
        });
        flamegraph_cmd.step.dependOn(&perf_cmd.step);
        flamegraph_step.dependOn(&flamegraph_cmd.step);
    } else if (target.result.os.tag == .macos) {
        const flamegraph_cmd = b.addSystemCommand(&[_][]const u8{
            "flamegraph", "-o", "guillotine-bench.svg", "--",
        });
        flamegraph_cmd.addArtifactArg(profile_bench_exe);
        flamegraph_cmd.addArg("--profile");
        flamegraph_step.dependOn(&flamegraph_cmd.step);
    } else {
        const warn_cmd = b.addSystemCommand(&[_][]const u8{
            "echo", "Flamegraph profiling is only supported on Linux and macOS",
        });
        flamegraph_step.dependOn(&warn_cmd.step);
    }
    
    // Create devtool executable
    const devtool_setup = executables.setupDevtoolBuildSteps(b);
    const devtool_exe = executables.createDevtoolExecutable(b, target, optimize, pkgs);
    devtool_exe.step.dependOn(&devtool_setup.generate_assets.step);
    b.installArtifact(devtool_exe);
    
    const run_devtool_cmd = b.addRunArtifact(devtool_exe);
    run_devtool_cmd.step.dependOn(b.getInstallStep());
    const devtool_step = b.step("devtool", "Run the devtool");
    devtool_step.dependOn(&run_devtool_cmd.step);
    
    // Setup all tests
    tests_mod.setupAllTests(b, pkgs, target, optimize);
    tests_mod.setupFuzzTests(b, pkgs, target, optimize);
    
    // Create comprehensive comparison executable
    if (pkgs.revm_mod != null) {
        const comprehensive_compare = executables.createComprehensiveCompareExecutable(b, target, optimize, pkgs);
        b.installArtifact(comprehensive_compare);
    }
    
    // WASM builds
    const wasm_packages = packages.createWasmPackages(b);
    const wasm_executables = executables.createWasmExecutables(b, wasm_packages);
    
    // Add step to report WASM bundle sizes
    const wasm_size_step = wasm.addWasmSizeReportStep(
        b,
        &[_][]const u8{"guillotine.wasm", "guillotine-primitives.wasm", "guillotine-evm.wasm"},
        &[_]*std.Build.Step{
            &wasm_executables.wasm_lib_build.install.step,
            &wasm_executables.wasm_primitives_build.install.step,
            &wasm_executables.wasm_evm_build.install.step,
        },
    );
    
    const wasm_step = b.step("wasm", "Build all WASM libraries and show bundle sizes");
    wasm_step.dependOn(&wasm_size_step.step);
    
    // Individual WASM build steps
    const wasm_primitives_step = b.step("wasm-primitives", "Build primitives-only WASM library");
    wasm_primitives_step.dependOn(&wasm_executables.wasm_primitives_build.install.step);
    
    const wasm_evm_step = b.step("wasm-evm", "Build EVM-only WASM library");
    wasm_evm_step.dependOn(&wasm_executables.wasm_evm_build.install.step);
    
    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_executables.wasm_debug_build.install.step);
    
    // FFI bindings
    setupFFIBindings(b, target, optimize);
}

fn setupFFIBindings(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    _ = target;
    _ = optimize;
    
    // Python bindings
    const python_check = b.addSystemCommand(&[_][]const u8{ "which", "python3" });
    python_check.addCheck(.{ .expect_stdout_match = "python3" });
    
    const venv_create = b.addSystemCommand(&[_][]const u8{ "python3", "-m", "venv", "venv" });
    venv_create.setCwd(b.path("bindings/python"));
    venv_create.step.dependOn(&python_check.step);
    
    const pip_install = b.addSystemCommand(&[_][]const u8{ "./venv/bin/pip", "install", "-e", "." });
    pip_install.setCwd(b.path("bindings/python"));
    pip_install.step.dependOn(&venv_create.step);
    
    const python_test_cmd = b.addSystemCommand(&[_][]const u8{ "./venv/bin/pytest", "tests/" });
    python_test_cmd.setCwd(b.path("bindings/python"));
    python_test_cmd.step.dependOn(&pip_install.step);
    
    const python_test_step = b.step("python-test", "Run Python binding tests");
    python_test_step.dependOn(&python_test_cmd.step);
    
    // Swift bindings
    const swift_check = b.addSystemCommand(&[_][]const u8{ "which", "swift" });
    swift_check.addCheck(.{ .expect_stdout_match = "swift" });
    
    const copy_header_cmd = b.addSystemCommand(&[_][]const u8{ "cp", "../../src/guillotine.h", "Sources/CGuillotine/include/guillotine.h" });
    copy_header_cmd.setCwd(b.path("bindings/swift"));
    copy_header_cmd.step.dependOn(&swift_check.step);
    
    const copy_lib_cmd = b.addSystemCommand(&[_][]const u8{ "cp", "../../zig-out/lib/libGuillotine.a", "Sources/CGuillotine/lib/libGuillotine.a" });
    copy_lib_cmd.setCwd(b.path("bindings/swift"));
    copy_lib_cmd.step.dependOn(&copy_header_cmd.step);
    
    const swift_test_cmd = b.addSystemCommand(&[_][]const u8{ "swift", "test" });
    swift_test_cmd.setCwd(b.path("bindings/swift"));
    swift_test_cmd.step.dependOn(&copy_lib_cmd.step);
    
    const swift_test_step = b.step("swift-test", "Run Swift binding tests");
    swift_test_step.dependOn(&swift_test_cmd.step);
    
    // Go bindings
    const go_check = b.addSystemCommand(&[_][]const u8{ "which", "go" });
    go_check.addCheck(.{ .expect_stdout_match = "go" });
    
    const go_mod_init = b.addSystemCommand(&[_][]const u8{ "go", "mod", "init", "github.com/evmts/guillotine/bindings/go" });
    go_mod_init.setCwd(b.path("bindings/go"));
    go_mod_init.step.dependOn(&go_check.step);
    
    const go_test_cmd = b.addSystemCommand(&[_][]const u8{ "go", "test", "-v" });
    go_test_cmd.setCwd(b.path("bindings/go"));
    go_test_cmd.step.dependOn(&go_mod_init.step);
    
    const go_test_step = b.step("go-test", "Run Go binding tests");
    go_test_step.dependOn(&go_test_cmd.step);
    
    // TypeScript bindings
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });
    
    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("bindings/typescript"));
    npm_install.step.dependOn(&npm_check.step);
    
    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("bindings/typescript"));
    npm_build.step.dependOn(&npm_install.step);
    
    const ts_test_cmd = b.addSystemCommand(&[_][]const u8{ "npm", "test" });
    ts_test_cmd.setCwd(b.path("bindings/typescript"));
    ts_test_cmd.step.dependOn(&npm_build.step);
    
    const ts_test_step = b.step("ts-test", "Run TypeScript binding tests");
    ts_test_step.dependOn(&ts_test_cmd.step);
}