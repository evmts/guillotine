const std = @import("std");
const packages = @import("packages.zig");
const asset_generator = @import("../build_utils/asset_generator.zig");
const wasm = @import("../build_utils/wasm.zig");

pub fn createMainExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lib_mod: *std.Build.Module) *std.Build.Step.Compile {
    const exe_mod = b.createModule(.{ 
        .root_source_file = b.path("src/main.zig"), 
        .target = target, 
        .optimize = optimize 
    });
    exe_mod.addImport("Guillotine_lib", lib_mod);
    
    const exe = b.addExecutable(.{
        .name = "Guillotine",
        .root_module = exe_mod,
    });
    
    return exe;
}

pub fn createEvmTestRunner(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, evm_mod: *std.Build.Module, primitives_mod: *std.Build.Module) *std.Build.Step.Compile {
    const evm_test_runner = b.addExecutable(.{
        .name = "evm_test_runner",
        .root_source_file = b.path("src/evm_test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_test_runner.root_module.addImport("evm", evm_mod);
    evm_test_runner.root_module.addImport("primitives", primitives_mod);
    
    return evm_test_runner;
}

pub fn createEvmRunner(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, evm_mod: *std.Build.Module, primitives_mod: *std.Build.Module) *std.Build.Step.Compile {
    const evm_runner_exe = b.addExecutable(.{
        .name = "evm-runner",
        .root_source_file = b.path("bench/official/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_runner_exe.root_module.addImport("evm", evm_mod);
    evm_runner_exe.root_module.addImport("primitives", primitives_mod);
    
    return evm_runner_exe;
}

pub fn createOrchestratorExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, clap_dep: *std.Build.Dependency) *std.Build.Step.Compile {
    const orchestrator_exe = b.addExecutable(.{
        .name = "orchestrator",
        .root_source_file = b.path("bench/official/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    orchestrator_exe.root_module.addImport("clap", clap_dep.module("clap"));
    
    return orchestrator_exe;
}

pub fn setupOrchestratorSteps(b: *std.Build, orchestrator_exe: *std.Build.Step.Compile) struct {
    orchestrator_step: *std.Build.Step,
    build_orchestrator_step: *std.Build.Step,
    compare_step: *std.Build.Step,
    geth_runner_build: *std.Build.Step.Run,
    evmone_cmake_build: *std.Build.Step.Run,
} {
    // Run orchestrator step
    const run_orchestrator_cmd = b.addRunArtifact(orchestrator_exe);
    if (b.args) |args| {
        run_orchestrator_cmd.addArgs(args);
    }
    
    const orchestrator_step = b.step("orchestrator", "Run the benchmark orchestrator");
    orchestrator_step.dependOn(&run_orchestrator_cmd.step);
    
    const build_orchestrator_step = b.step("build-orchestrator", "Build the benchmark orchestrator");
    build_orchestrator_step.dependOn(&b.addInstallArtifact(orchestrator_exe, .{}).step);
    
    // Add a comparison step with default --js-runs=1 and --js-internal-runs=1
    const run_comparison_cmd = b.addRunArtifact(orchestrator_exe);
    run_comparison_cmd.addArg("--compare");
    run_comparison_cmd.addArg("--js-runs");
    run_comparison_cmd.addArg("1");
    run_comparison_cmd.addArg("--js-internal-runs");
    run_comparison_cmd.addArg("1");
    run_comparison_cmd.addArg("--export");
    run_comparison_cmd.addArg("markdown");
    if (b.args) |args| {
        run_comparison_cmd.addArgs(args);
    }
    
    const compare_step = b.step("bench-compare", "Run EVM comparison benchmarks with --js-runs=1 --js-internal-runs=1 by default");
    compare_step.dependOn(&run_comparison_cmd.step);
    
    // Build Go (geth) runner
    const geth_runner_build = b.addSystemCommand(&[_][]const u8{
        "go", "build", "-o", "runner", "runner.go"
    });
    geth_runner_build.setCwd(b.path("bench/official/evms/geth"));
    
    // Build evmone runner using CMake
    const evmone_cmake_configure = b.addSystemCommand(&[_][]const u8{
        "cmake", "-S", "bench/official/evms/evmone", "-B", "bench/official/evms/evmone/build", "-DCMAKE_BUILD_TYPE=Release"
    });
    evmone_cmake_configure.setCwd(b.path(""));
    
    const evmone_cmake_build = b.addSystemCommand(&[_][]const u8{
        "cmake", "--build", "bench/official/evms/evmone/build", "--parallel"
    });
    evmone_cmake_build.setCwd(b.path(""));
    evmone_cmake_build.step.dependOn(&evmone_cmake_configure.step);
    
    // Make benchmark targets depend on runner builds
    orchestrator_step.dependOn(&geth_runner_build.step);
    orchestrator_step.dependOn(&evmone_cmake_build.step);
    build_orchestrator_step.dependOn(&geth_runner_build.step);
    build_orchestrator_step.dependOn(&evmone_cmake_build.step);
    compare_step.dependOn(&geth_runner_build.step);
    compare_step.dependOn(&evmone_cmake_build.step);
    
    return .{
        .orchestrator_step = orchestrator_step,
        .build_orchestrator_step = build_orchestrator_step,
        .compare_step = compare_step,
        .geth_runner_build = geth_runner_build,
        .evmone_cmake_build = evmone_cmake_build,
    };
}

pub fn createOpcodeTestLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, pkgs: packages.Packages) *std.Build.Step.Compile {
    const opcode_test_lib = b.addStaticLibrary(.{
        .name = "guillotine_opcode_test",
        .root_source_file = b.path("src/evm_opcode_test_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    opcode_test_lib.root_module.addImport("evm", pkgs.evm_mod);
    opcode_test_lib.root_module.addImport("primitives", pkgs.primitives_mod);
    opcode_test_lib.root_module.addImport("crypto", pkgs.crypto_mod);
    opcode_test_lib.root_module.addImport("build_options", pkgs.build_options.createModule());
    
    // Link BN254 library if available
    if (pkgs.bn254_lib) |bn254| {
        opcode_test_lib.linkLibrary(bn254);
        opcode_test_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    return opcode_test_lib;
}

pub fn createBenchExecutable(b: *std.Build, target: std.Build.ResolvedTarget, bench_packages: packages.BenchPackages, pkgs: packages.Packages, bench_optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const bench_exe = b.addExecutable(.{
        .name = "guillotine-bench",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_exe.root_module.addImport("bench", bench_packages.bench_mod);
    bench_exe.root_module.addImport("zbench", bench_packages.zbench_dep.module("zbench"));
    bench_exe.root_module.addImport("evm", bench_packages.bench_evm_mod);
    bench_exe.root_module.addImport("primitives", pkgs.primitives_mod);
    if (pkgs.revm_mod != null) {
        bench_exe.root_module.addImport("revm", pkgs.revm_mod.?);
    }
    
    // Link the EVM benchmark Rust library if available
    if (pkgs.evm_bench_lib) |evm_bench| {
        bench_exe.linkLibrary(evm_bench);
        bench_exe.addIncludePath(b.path("src/guillotine-rs"));
    }
    
    return bench_exe;
}

pub fn createRevmBenchExecutable(b: *std.Build, target: std.Build.ResolvedTarget, bench_packages: packages.BenchPackages, pkgs: packages.Packages, bench_optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const revm_bench_exe = b.addExecutable(.{
        .name = "revm-comparison",
        .root_source_file = b.path("bench/run_revm_comparison.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    revm_bench_exe.root_module.addImport("evm", bench_packages.bench_evm_mod);
    revm_bench_exe.root_module.addImport("primitives", pkgs.primitives_mod);
    if (pkgs.revm_mod != null) {
        revm_bench_exe.root_module.addImport("revm", pkgs.revm_mod.?);
    }
    
    // Link the EVM benchmark Rust library if available
    if (pkgs.evm_bench_lib) |evm_bench| {
        revm_bench_exe.linkLibrary(evm_bench);
        revm_bench_exe.addIncludePath(b.path("src/guillotine-rs"));
    }
    
    return revm_bench_exe;
}

pub fn createProfileBenchExecutable(b: *std.Build, target: std.Build.ResolvedTarget, bench_packages: packages.BenchPackages, pkgs: packages.Packages) *std.Build.Step.Compile {
    const profile_bench_exe = b.addExecutable(.{
        .name = "guillotine-bench-profile",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,  // Always use optimized build for profiling
    });
    profile_bench_exe.root_module.addImport("bench", bench_packages.bench_mod);
    profile_bench_exe.root_module.addImport("zbench", bench_packages.zbench_dep.module("zbench"));
    profile_bench_exe.root_module.addImport("evm", bench_packages.bench_evm_mod);
    profile_bench_exe.root_module.addImport("primitives", pkgs.primitives_mod);
    if (pkgs.revm_mod != null) {
        profile_bench_exe.root_module.addImport("revm", pkgs.revm_mod.?);
    }
    
    // CRITICAL: Include debug symbols for profiling
    profile_bench_exe.root_module.strip = false;  // Keep symbols
    profile_bench_exe.root_module.omit_frame_pointer = false;  // Keep frame pointers
    
    return profile_bench_exe;
}

pub fn createDevtoolExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, pkgs: packages.Packages) *std.Build.Step.Compile {
    const webui = b.dependency("webui", .{
        .target = target,
        .optimize = optimize,
        .dynamic = false,
        .@"enable-tls" = false,
        .verbose = .err,
    });
    
    const devtool_mod = b.createModule(.{
        .root_source_file = b.path("src/devtool/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_mod.addImport("Guillotine_lib", pkgs.lib_mod);
    devtool_mod.addImport("evm", pkgs.evm_mod);
    devtool_mod.addImport("primitives", pkgs.primitives_mod);
    devtool_mod.addImport("provider", pkgs.provider_mod);
    
    const devtool_exe = b.addExecutable(.{
        .name = "guillotine-devtool",
        .root_module = devtool_mod,
    });
    devtool_exe.linkLibrary(webui.artifact("webui"));
    
    return devtool_exe;
}

pub fn createComprehensiveCompareExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, pkgs: packages.Packages) *std.Build.Step.Compile {
    const comprehensive_compare = b.addExecutable(.{
        .name = "comprehensive-compare",
        .root_source_file = b.path("test/evm/comprehensive_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_compare.root_module.addImport("evm", pkgs.evm_mod);
    comprehensive_compare.root_module.addImport("primitives", pkgs.primitives_mod);
    if (pkgs.revm_mod != null) {
        comprehensive_compare.root_module.addImport("revm", pkgs.revm_mod.?);
    }
    
    return comprehensive_compare;
}

pub fn setupDevtoolBuildSteps(b: *std.Build) struct {
    npm_check: *std.Build.Step.Run,
    npm_install: *std.Build.Step.Run,
    npm_build: *std.Build.Step.Run,
    generate_assets: *asset_generator.GenerateAssetsStep,
} {
    // First, check if npm is installed and build the Solid app
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });
    
    // Install npm dependencies for devtool
    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);
    
    // Build the Solid app
    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);
    
    // Generate assets from the built Solid app
    const generate_assets = asset_generator.GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
    generate_assets.step.dependOn(&npm_build.step);
    
    return .{
        .npm_check = npm_check,
        .npm_install = npm_install,
        .npm_build = npm_build,
        .generate_assets = generate_assets,
    };
}

pub fn createWasmExecutables(b: *std.Build, wasm_packages: packages.WasmPackages) struct {
    wasm_lib_build: struct { exe: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact },
    wasm_primitives_build: struct { exe: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact },
    wasm_evm_build: struct { exe: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact },
    wasm_debug_build: struct { exe: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact },
} {
    const wasm_lib_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "guillotine.wasm",
    }, wasm_packages.wasm_lib_mod);
    
    const wasm_primitives_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-primitives",
        .root_source_file = "src/primitives_c.zig",
        .dest_sub_path = "guillotine-primitives.wasm",
    }, wasm_packages.wasm_primitives_lib_mod);
    
    const wasm_evm_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-evm",
        .root_source_file = "src/evm_c.zig",
        .dest_sub_path = "guillotine-evm.wasm",
    }, wasm_packages.wasm_evm_lib_mod);
    
    // Debug WASM build for analysis
    const wasm_debug_mod = wasm.createWasmModule(b, "src/root.zig", wasm_packages.wasm_target, .Debug);
    wasm_debug_mod.addImport("primitives", wasm_packages.wasm_primitives_mod);
    wasm_debug_mod.addImport("evm", wasm_packages.wasm_evm_mod);
    
    const wasm_debug_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-debug",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "../bin/guillotine-debug.wasm",
        .debug_build = true,
    }, wasm_debug_mod);
    
    return .{
        .wasm_lib_build = .{ .exe = wasm_lib_build.exe, .install = wasm_lib_build.install },
        .wasm_primitives_build = .{ .exe = wasm_primitives_build.exe, .install = wasm_primitives_build.install },
        .wasm_evm_build = .{ .exe = wasm_evm_build.exe, .install = wasm_evm_build.install },
        .wasm_debug_build = .{ .exe = wasm_debug_build.exe, .install = wasm_debug_build.install },
    };
}

pub fn createStaticLibrary(b: *std.Build, lib_mod: *std.Build.Module, bn254_lib: ?*std.Build.Step.Compile) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "Guillotine",
        .root_module = lib_mod,
    });
    
    // Link BN254 Rust library to the library artifact (if enabled)
    if (bn254_lib) |bn254| {
        lib.linkLibrary(bn254);
        lib.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    return lib;
}

pub fn createSharedLibrary(b: *std.Build, lib_mod: *std.Build.Module, bn254_lib: ?*std.Build.Step.Compile) *std.Build.Step.Compile {
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "Guillotine",
        .root_module = lib_mod,
    });
    
    // Link BN254 Rust library to the shared library artifact (if enabled)
    if (bn254_lib) |bn254| {
        shared_lib.linkLibrary(bn254);
        shared_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    return shared_lib;
}