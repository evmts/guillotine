const std = @import("std");
const asset_generator = @import("build_utils/asset_generator.zig");
const rust_build = @import("build_utils/rust_build.zig");
const tests = @import("build_utils/tests.zig");
const wasm = @import("build_utils/wasm.zig");
const devtool = @import("build_utils/devtool.zig");
const typescript = @import("build_utils/typescript.zig");

// Import the extracted build modules
const modules = @import("build_config/modules.zig");
const rust = @import("build_config/rust.zig");
const artifacts = @import("build_config/artifacts.zig");
const benchmarks = @import("build_config/benchmarks.zig");
const test_setup = @import("build_config/tests.zig");
const fuzzing = @import("build_config/fuzzing.zig");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Custom build options
    const no_precompiles = b.option(bool, "no_precompiles", "Disable all EVM precompiles for minimal build") orelse false;
    const force_bn254 = b.option(bool, "force_bn254", "Force BN254 even on Ubuntu") orelse false;
    const is_ubuntu_native = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and !force_bn254;
    const no_bn254 = no_precompiles or is_ubuntu_native;

    // Setup modules
    const module_config = modules.ModuleConfig{
        .target = target,
        .optimize = optimize,
        .no_precompiles = no_precompiles,
        .no_bn254 = no_bn254,
    };
    const mods = modules.createModules(b, module_config);

    // Setup Rust integration
    const rust_config = rust.RustConfig{
        .target = target,
        .optimize = optimize,
        .no_bn254 = no_bn254,
    };
    const rust_libs = rust.setupRustIntegration(b, rust_config);

    // Create REVM module if Rust is available
    const revm_mod = rust.createRevmModule(b, rust_config, mods.primitives, rust_libs.revm_lib);
    if (revm_mod) |mod| {
        mods.lib.addImport("revm", mod);
    }

    // C-KZG-4844 Zig bindings
    const c_kzg_dep = b.dependency("c_kzg_4844", .{
        .target = target,
        .optimize = optimize,
    });
    const c_kzg_lib = c_kzg_dep.artifact("c_kzg_4844");
    mods.primitives.linkLibrary(c_kzg_lib);

    // Link BN254 Rust library to EVM module
    if (rust_libs.bn254_lib) |lib| {
        mods.evm.linkLibrary(lib);
        mods.evm.addIncludePath(b.path("src/bn254_wrapper"));
    }

    // Link c-kzg library to EVM module
    mods.evm.linkLibrary(c_kzg_lib);

    // Build artifacts
    artifacts.buildArtifacts(b, mods, rust_libs, target, optimize);

    // Setup WASM builds
    setupWasmBuilds(b, optimize, mods.build_options);

    // Setup devtool
    setupDevtool(b, mods, target, optimize);

    // Setup debug and crash test executables
    setupDebugExecutables_new(b, mods, rust_libs, target, optimize);

    // Setup benchmarks
    benchmarks.setupBenchmarks(b, mods, target);

    // Setup tests
    test_setup.setupTests(b, mods, target, optimize);

    // Setup fuzzing
    fuzzing.setupFuzzing(b, mods, rust_libs, target, optimize);

    // Setup integration tests
    setupIntegrationTests(b, mods, target, optimize);

    // Setup special opcode test
    setupOpcodeRustTests(b, mods, target, optimize);

    // Build artifacts
    artifacts.buildArtifacts(b, mods, rust_libs, target, optimize);
}

fn setupWasmBuilds(b: *std.Build, optimize: std.builtin.OptimizeMode, build_options_mod: *std.Build.Module) void {
    const wasm_target = wasm.setupWasmTarget(b);
    const wasm_optimize = optimize;

    // Create WASM modules
    const wasm_mods = modules.createWasmModules(b, wasm_target, wasm_optimize, build_options_mod);

    // Main WASM build
    const wasm_lib_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "guillotine.wasm",
    }, wasm_mods.lib);

    // Primitives-only WASM build
    const wasm_primitives_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-primitives",
        .root_source_file = "src/primitives_c.zig",
        .dest_sub_path = "guillotine-primitives.wasm",
    }, wasm_mods.primitives_lib);

    // EVM-only WASM build
    const wasm_evm_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-evm",
        .root_source_file = "src/evm_c.zig",
        .dest_sub_path = "guillotine-evm.wasm",
    }, wasm_mods.evm_lib);

    // Add step to report WASM bundle sizes
    const wasm_size_step = wasm.addWasmSizeReportStep(
        b,
        &[_][]const u8{ "guillotine.wasm", "guillotine-primitives.wasm", "guillotine-evm.wasm" },
        &[_]*std.Build.Step{
            &wasm_lib_build.install.step,
            &wasm_primitives_build.install.step,
            &wasm_evm_build.install.step,
        },
    );

    const wasm_step = b.step("wasm", "Build all WASM libraries and show bundle sizes");
    wasm_step.dependOn(&wasm_size_step.step);

    // Individual WASM build steps
    const wasm_primitives_step = b.step("wasm-primitives", "Build primitives-only WASM library");
    wasm_primitives_step.dependOn(&wasm_primitives_build.install.step);

    const wasm_evm_step = b.step("wasm-evm", "Build EVM-only WASM library");
    wasm_evm_step.dependOn(&wasm_evm_build.install.step);

    // Debug WASM build
    const wasm_debug_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, .Debug);
    wasm_debug_mod.addImport("primitives", wasm_mods.primitives);
    wasm_debug_mod.addImport("evm", wasm_mods.evm);

    const wasm_debug_build = wasm.buildWasmExecutable(b, .{
        .name = "guillotine-debug",
        .root_source_file = "src/root.zig",
        .dest_sub_path = "../bin/guillotine-debug.wasm",
        .debug_build = true,
    }, wasm_debug_mod);

    const wasm_debug_step = b.step("wasm-debug", "Build debug WASM for analysis");
    wasm_debug_step.dependOn(&wasm_debug_build.install.step);
}

fn setupDevtool(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Add webui dependency
    const webui = b.dependency("webui", .{
        .target = target,
        .optimize = optimize,
        .dynamic = false,
        .@"enable-tls" = false,
        .verbose = .err,
    });

    // Check and build npm dependencies
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);

    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);

    // Generate assets from the built Solid app
    const generate_assets = asset_generator.GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
    generate_assets.step.dependOn(&npm_build.step);

    const devtool_mod = b.createModule(.{
        .root_source_file = b.path("src/devtool/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_mod.addImport("Guillotine_lib", mods.lib);
    devtool_mod.addImport("evm", mods.evm);
    devtool_mod.addImport("primitives", mods.primitives);
    devtool_mod.addImport("provider", mods.provider);

    const devtool_exe = b.addExecutable(.{
        .name = "guillotine-devtool",
        .root_module = devtool_mod,
    });
    devtool_exe.addIncludePath(webui.path("src"));
    devtool_exe.addIncludePath(webui.path("include"));

    // Add native menu implementation on macOS
    if (target.result.os.tag == .macos) {
        setupMacOSDevtool(b, devtool_exe, target);
    }

    // Link webui library
    devtool_exe.linkLibrary(webui.artifact("webui"));

    // Link external libraries
    devtool_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        devtool_exe.linkFramework("WebKit");
        devtool_exe.linkFramework("AppKit");
        devtool_exe.linkFramework("Foundation");
    }

    // Make devtool build depend on asset generation
    devtool_exe.step.dependOn(&generate_assets.step);

    // TEMPORARILY DISABLED: npm build failing
    // b.installArtifact(devtool_exe);

    const run_devtool_cmd = b.addRunArtifact(devtool_exe);
    run_devtool_cmd.step.dependOn(b.getInstallStep());

    const devtool_step = b.step("devtool", "Build and run the Ethereum devtool");
    devtool_step.dependOn(&run_devtool_cmd.step);

    const build_devtool_step = b.step("build-devtool", "Build the Ethereum devtool (without running)");
    build_devtool_step.dependOn(b.getInstallStep());
}

fn setupMacOSDevtool(b: *std.Build, devtool_exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    // Compile Swift code to dynamic library
    const swift_compile = b.addSystemCommand(&[_][]const u8{
        "swiftc",
        "-emit-library",
        "-parse-as-library",
        "-target",
        "arm64-apple-macosx15.0",
        "-o",
        "zig-out/libnative_menu_swift.dylib",
        "src/devtool/native_menu.swift",
    });

    // Create output directory
    const mkdir_cmd = b.addSystemCommand(&[_][]const u8{
        "mkdir", "-p", "zig-out",
    });
    swift_compile.step.dependOn(&mkdir_cmd.step);

    // Link the compiled Swift dynamic library
    devtool_exe.addLibraryPath(b.path("zig-out"));
    devtool_exe.linkSystemLibrary("native_menu_swift");
    devtool_exe.step.dependOn(&swift_compile.step);

    // Add Swift runtime library search paths
    devtool_exe.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx" });
    devtool_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });

    // macOS app bundle creation
    if (target.result.os.tag == .macos) {
        // Create app bundle structure
        const bundle_dir = "macos/GuillotineDevtool.app/Contents/MacOS";
        const mkdir_bundle = b.addSystemCommand(&[_][]const u8{
            "mkdir", "-p", bundle_dir,
        });

        // Copy executable to app bundle
        const copy_to_bundle = b.addSystemCommand(&[_][]const u8{
            "cp", "-f", "zig-out/bin/guillotine-devtool", bundle_dir,
        });
        copy_to_bundle.step.dependOn(&devtool_exe.step);
        copy_to_bundle.step.dependOn(&mkdir_bundle.step);

        // Create macOS app bundle step
        const macos_app_step = b.step("macos-app", "Create macOS app bundle");
        macos_app_step.dependOn(&copy_to_bundle.step);

        // Create DMG installer step
        const create_dmg = b.addSystemCommand(&[_][]const u8{
            "scripts/create-dmg-fancy.sh",
        });
        create_dmg.step.dependOn(&copy_to_bundle.step);

        const dmg_step = b.step("macos-dmg", "Create macOS DMG installer");
        dmg_step.dependOn(&create_dmg.step);
    }
}

fn setupDebugExecutables_new(b: *std.Build, mods: modules.Modules, rust_libs: rust.RustLibraries, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Crash Debug executable (only if source exists)
    const have_crash_debug = blk: {
        std.fs.cwd().access("src/crash-debug.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_crash_debug) {
        const crash_debug_exe = b.addExecutable(.{
            .name = "crash-debug",
            .root_source_file = b.path("src/crash-debug.zig"),
            .target = target,
            .optimize = .Debug, // Use Debug for better diagnostics
        });
        crash_debug_exe.root_module.addImport("evm", mods.evm);
        crash_debug_exe.root_module.addImport("primitives", mods.primitives);
        b.installArtifact(crash_debug_exe);

        const run_crash_debug_cmd = b.addRunArtifact(crash_debug_exe);
        const crash_debug_step = b.step("crash-debug", "Run crash debugging tool");
        crash_debug_step.dependOn(&run_crash_debug_cmd.step);
    }

    // Simple Crash Test executable (only if source exists)
    const have_simple_crash = blk: {
        std.fs.cwd().access("src/simple-crash-test.zig", .{}) catch break :blk false;
        break :blk true;
    };
    if (have_simple_crash) {
        const simple_crash_test_exe = b.addExecutable(.{
            .name = "simple-crash-test",
            .root_source_file = b.path("src/simple-crash-test.zig"),
            .target = target,
            .optimize = .Debug,
        });
        simple_crash_test_exe.root_module.addImport("evm", mods.evm);
        simple_crash_test_exe.root_module.addImport("primitives", mods.primitives);
        b.installArtifact(simple_crash_test_exe);

        const run_simple_crash_test_cmd = b.addRunArtifact(simple_crash_test_exe);
        const simple_crash_test_step = b.step("simple-crash-test", "Run simple crash test");
        simple_crash_test_step.dependOn(&run_simple_crash_test_cmd.step);
    }

    // EVM Benchmark Runner executable (always optimized for benchmarks)
    const evm_runner_exe = b.addExecutable(.{
        .name = "evm-runner",
        .root_source_file = b.path("bench/official/evms/zig/src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
    });
    evm_runner_exe.root_module.addImport("evm", mods.evm);
    evm_runner_exe.root_module.addImport("primitives", mods.primitives);

    b.installArtifact(evm_runner_exe);

    const run_evm_runner_cmd = b.addRunArtifact(evm_runner_exe);
    if (b.args) |args| {
        run_evm_runner_cmd.addArgs(args);
    }

    const evm_runner_step = b.step("evm-runner", "Run the EVM benchmark runner");
    evm_runner_step.dependOn(&run_evm_runner_cmd.step);

    const build_evm_runner_step = b.step("build-evm-runner", "Build the EVM benchmark runner");
    build_evm_runner_step.dependOn(&b.addInstallArtifact(evm_runner_exe, .{}).step);

    // Benchmark Orchestrator executable
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const orchestrator_exe = b.addExecutable(.{
        .name = "orchestrator",
        .root_source_file = b.path("bench/official/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    orchestrator_exe.root_module.addImport("clap", clap_dep.module("clap"));

    b.installArtifact(orchestrator_exe);

    const run_orchestrator_cmd = b.addRunArtifact(orchestrator_exe);
    if (b.args) |args| {
        run_orchestrator_cmd.addArgs(args);
    }

    const orchestrator_step = b.step("orchestrator", "Run the benchmark orchestrator");
    orchestrator_step.dependOn(&run_orchestrator_cmd.step);

    const build_orchestrator_step = b.step("build-orchestrator", "Build the benchmark orchestrator");
    build_orchestrator_step.dependOn(&b.addInstallArtifact(orchestrator_exe, .{}).step);

    // Add poop benchmark runner and step
    const poop_runner_exe = b.addExecutable(.{
        .name = "poop-runner",
        .root_source_file = b.path("bench/poop_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
    });

    b.installArtifact(poop_runner_exe);

    const run_poop_cmd = b.addRunArtifact(poop_runner_exe);
    run_poop_cmd.step.dependOn(build_evm_runner_step); // Ensure evm-runner is built
    if (b.args) |args| {
        run_poop_cmd.addArgs(args);
    }

    const poop_step = b.step("poop", "Run poop benchmark on snailtracer (Linux only)");
    poop_step.dependOn(&run_poop_cmd.step);

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
    const geth_runner_build = b.addSystemCommand(&[_][]const u8{ "go", "build", "-o", "runner", "runner.go" });
    geth_runner_build.setCwd(b.path("bench/official/evms/geth"));

    // Build evmone runner using CMake
    const evmone_cmake_configure = b.addSystemCommand(&[_][]const u8{ "cmake", "-S", "bench/official/evms/evmone", "-B", "bench/official/evms/evmone/build", "-DCMAKE_BUILD_TYPE=Release" });
    evmone_cmake_configure.setCwd(b.path(""));

    const evmone_cmake_build = b.addSystemCommand(&[_][]const u8{ "cmake", "--build", "bench/official/evms/evmone/build", "--parallel" });
    evmone_cmake_build.setCwd(b.path(""));
    evmone_cmake_build.step.dependOn(&evmone_cmake_configure.step);

    // Make benchmark targets depend on runner builds
    orchestrator_step.dependOn(&geth_runner_build.step);
    orchestrator_step.dependOn(&evmone_cmake_build.step);
    build_orchestrator_step.dependOn(&geth_runner_build.step);
    build_orchestrator_step.dependOn(&evmone_cmake_build.step);
    compare_step.dependOn(&geth_runner_build.step);
    compare_step.dependOn(&evmone_cmake_build.step);

    // Static library for opcode testing FFI
    const opcode_test_lib = b.addStaticLibrary(.{
        .name = "guillotine_opcode_test",
        .root_source_file = b.path("src/evm_opcode_test_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    opcode_test_lib.root_module.addImport("evm", mods.evm);
    opcode_test_lib.root_module.addImport("primitives", mods.primitives);
    opcode_test_lib.root_module.addImport("crypto", mods.crypto);
    opcode_test_lib.root_module.addImport("build_options", mods.build_options);

    // Link BN254 library if available
    if (rust_libs.bn254_lib) |bn254| {
        opcode_test_lib.linkLibrary(bn254);
        opcode_test_lib.addIncludePath(b.path("src/bn254_wrapper"));
    }

    b.installArtifact(opcode_test_lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = mods.lib,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = mods.exe,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Add Memory tests
    const memory_test = b.addTest(.{
        .name = "memory-test",
        .root_source_file = b.path("test/evm/memory_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_test.root_module.addImport("evm", mods.evm);
    memory_test.root_module.addImport("primitives", mods.primitives);

    const run_memory_test = b.addRunArtifact(memory_test);
    const memory_test_step = b.step("test-memory", "Run Memory tests");
    memory_test_step.dependOn(&run_memory_test.step);

    // Add Memory Leak tests
    const memory_leak_test = b.addTest(.{
        .name = "memory-leak-test",
        .root_source_file = b.path("test/evm/memory_leak_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_leak_test.root_module.addImport("evm", mods.evm);
    memory_leak_test.root_module.addImport("primitives", mods.primitives);

    const run_memory_leak_test = b.addRunArtifact(memory_leak_test);
    const memory_leak_test_step = b.step("test-memory-leak", "Run Memory leak prevention tests");
    memory_leak_test_step.dependOn(&run_memory_leak_test.step);

    // Add Stack tests
    const stack_test = b.addTest(.{
        .name = "stack-test",
        .root_source_file = b.path("test/evm/stack_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stack_test.root_module.addImport("evm", mods.evm);

    const run_stack_test = b.addRunArtifact(stack_test);
    const stack_test_step = b.step("test-stack", "Run Stack tests");
    stack_test_step.dependOn(&run_stack_test.step);

    // Add new EVM tests
    const newevm_test = b.addTest(.{
        .name = "newevm-test",
        .root_source_file = b.path("src/evm/newevm_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_test.root_module.addImport("evm", mods.evm);
    newevm_test.root_module.addImport("primitives", mods.primitives);

    const run_newevm_test = b.addRunArtifact(newevm_test);
    const newevm_test_step = b.step("test-newevm", "Run new EVM tests");
    newevm_test_step.dependOn(&run_newevm_test.step);

    // Add arithmetic opcode tests for new EVM
    const newevm_arithmetic_test = b.addTest(.{
        .name = "newevm-arithmetic-test",
        .root_source_file = b.path("test/evm/opcodes/arithmetic_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_arithmetic_test.root_module.addImport("evm", mods.evm);
    newevm_arithmetic_test.root_module.addImport("primitives", mods.primitives);

    const run_newevm_arithmetic_test = b.addRunArtifact(newevm_arithmetic_test);
    newevm_test_step.dependOn(&run_newevm_arithmetic_test.step);

    // Add bitwise opcode tests for new EVM
    const newevm_bitwise_test = b.addTest(.{
        .name = "newevm-bitwise-test",
        .root_source_file = b.path("test/evm/opcodes/bitwise_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_bitwise_test.root_module.addImport("evm", mods.evm);
    newevm_bitwise_test.root_module.addImport("primitives", mods.primitives);

    const run_newevm_bitwise_test = b.addRunArtifact(newevm_bitwise_test);
    newevm_test_step.dependOn(&run_newevm_bitwise_test.step);

    // Add comparison opcode tests for new EVM
    const newevm_comparison_test = b.addTest(.{
        .name = "newevm-comparison-test",
        .root_source_file = b.path("test/evm/opcodes/comparison_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_comparison_test.root_module.addImport("evm", mods.evm);
    newevm_comparison_test.root_module.addImport("primitives", mods.primitives);

    const run_newevm_comparison_test = b.addRunArtifact(newevm_comparison_test);
    newevm_test_step.dependOn(&run_newevm_comparison_test.step);

    // Add block opcode tests for new EVM
    const newevm_block_test = b.addTest(.{
        .name = "newevm-block-test",
        .root_source_file = b.path("test/evm/opcodes/block_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_block_test.root_module.addImport("evm", mods.evm);
    newevm_block_test.root_module.addImport("primitives", mods.primitives);

    const run_newevm_block_test = b.addRunArtifact(newevm_block_test);
    newevm_test_step.dependOn(&run_newevm_block_test.step);

    // Add stack opcode tests for new EVM
    const newevm_stack_test = b.addTest(.{
        .name = "newevm-stack-test",
        .root_source_file = b.path("test/evm/opcodes/stack_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    newevm_stack_test.root_module.addImport("evm", mods.evm);
    newevm_stack_test.root_module.addImport("primitives", mods.primitives);

    const run_newevm_stack_test = b.addRunArtifact(newevm_stack_test);
    newevm_test_step.dependOn(&run_newevm_stack_test.step);

    // Add Stack validation tests
    const stack_validation_test = b.addTest(.{
        .name = "stack-validation-test",
        .root_source_file = b.path("test/evm/stack_validation_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    stack_validation_test.root_module.stack_check = false;
    stack_validation_test.root_module.addImport("evm", mods.evm);

    const run_stack_validation_test = b.addRunArtifact(stack_validation_test);
    const stack_validation_test_step = b.step("test-stack-validation", "Run Stack validation tests");
    stack_validation_test_step.dependOn(&run_stack_validation_test.step);

    // Add Jump table tests
    const jump_table_test = b.addTest(.{
        .name = "jump-table-test",
        .root_source_file = b.path("test/evm/jump_table_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    jump_table_test.root_module.stack_check = false;
    jump_table_test.root_module.addImport("primitives", mods.primitives);
    jump_table_test.root_module.addImport("evm", mods.evm);

    const run_jump_table_test = b.addRunArtifact(jump_table_test);
    const jump_table_test_step = b.step("test-jump-table", "Run Jump table tests");
    jump_table_test_step.dependOn(&run_jump_table_test.step);

    // Add Config tests
    const config_test = b.addTest(.{
        .name = "config-test",
        .root_source_file = b.path("test/evm/config_simple_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    config_test.root_module.stack_check = false;
    config_test.root_module.addImport("primitives", mods.primitives);
    config_test.root_module.addImport("evm", mods.evm);

    const run_config_test = b.addRunArtifact(config_test);
    const config_test_step = b.step("test-config", "Run Config tests");
    config_test_step.dependOn(&run_config_test.step);

    // Add Opcodes tests
    const opcodes_test = b.addTest(.{
        .name = "opcodes-test",
        .root_source_file = b.path("test/evm/opcodes/opcodes_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    opcodes_test.root_module.stack_check = false;
    opcodes_test.root_module.addImport("primitives", mods.primitives);
    opcodes_test.root_module.addImport("evm", mods.evm);

    const run_opcodes_test = b.addRunArtifact(opcodes_test);
    const opcodes_test_step = b.step("test-opcodes", "Run Opcodes tests");
    opcodes_test_step.dependOn(&run_opcodes_test.step);

    // Benchmark Runner test removed - file no longer exists

    // Add Minimal Call Test
    const minimal_call_test = b.addTest(.{
        .name = "minimal-call-test",
        .root_source_file = b.path("test/evm/minimal_call_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    minimal_call_test.root_module.stack_check = false;
    minimal_call_test.root_module.addImport("primitives", mods.primitives);
    minimal_call_test.root_module.addImport("evm", mods.evm);

    const run_minimal_call_test = b.addRunArtifact(minimal_call_test);
    const minimal_call_test_step = b.step("test-minimal-call", "Run Minimal Call test");
    minimal_call_test_step.dependOn(&run_minimal_call_test.step);

    // Add Debug Analysis Test
    const debug_analysis_test = b.addTest(.{
        .name = "debug-analysis-test",
        .root_source_file = b.path("test/evm/debug_analysis_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    debug_analysis_test.root_module.stack_check = false;
    debug_analysis_test.root_module.addImport("primitives", mods.primitives);
    debug_analysis_test.root_module.addImport("evm", mods.evm);

    const run_debug_analysis_test = b.addRunArtifact(debug_analysis_test);
    const debug_analysis_test_step = b.step("test-debug-analysis", "Run Debug Analysis test");
    debug_analysis_test_step.dependOn(&run_debug_analysis_test.step);

    // Add Super Minimal Test
    const super_minimal_test = b.addTest(.{
        .name = "super-minimal-test",
        .root_source_file = b.path("test/evm/super_minimal_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    super_minimal_test.root_module.stack_check = false;
    super_minimal_test.root_module.addImport("primitives", mods.primitives);
    super_minimal_test.root_module.addImport("evm", mods.evm);

    const run_super_minimal_test = b.addRunArtifact(super_minimal_test);
    const super_minimal_test_step = b.step("test-super-minimal", "Run Super Minimal test");
    super_minimal_test_step.dependOn(&run_super_minimal_test.step);

    // Add Generated Opcode Comparison tests
    const opcode_comparison_test = b.addTest(.{
        .name = "opcode-comparison-test",
        .root_source_file = b.path("test/evm/opcodes/generated_opcode_comparison_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    opcode_comparison_test.root_module.stack_check = false;
    opcode_comparison_test.root_module.addImport("primitives", mods.primitives);
    opcode_comparison_test.root_module.addImport("evm", mods.evm);
    opcode_comparison_test.root_module.addImport("Address", mods.primitives);
    opcode_comparison_test.root_module.addImport("crypto", mods.crypto);
    opcode_comparison_test.root_module.addImport("build_options", mods.build_options);

    const run_opcode_comparison_test = b.addRunArtifact(opcode_comparison_test);
    const opcode_comparison_test_step = b.step("test-opcode-comparison", "Run opcode comparison tests");
    opcode_comparison_test_step.dependOn(&run_opcode_comparison_test.step);

    // Add VM opcode tests
    const vm_opcode_test = b.addTest(.{
        .name = "vm-opcode-test",
        .root_source_file = b.path("test/evm/vm_opcode_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    vm_opcode_test.root_module.stack_check = false;
    vm_opcode_test.root_module.addImport("primitives", mods.primitives);
    vm_opcode_test.root_module.addImport("evm", mods.evm);

    const run_vm_opcode_test = b.addRunArtifact(vm_opcode_test);
    const vm_opcode_test_step = b.step("test-vm-opcodes", "Run VM opcode tests");
    vm_opcode_test_step.dependOn(&run_vm_opcode_test.step);

    // Add Integration tests
    const integration_test = b.addTest(.{
        .name = "integration-test",
        .root_source_file = b.path("test/evm/integration/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    integration_test.root_module.stack_check = false;
    integration_test.root_module.addImport("primitives", mods.primitives);
    integration_test.root_module.addImport("evm", mods.evm);

    const run_integration_test = b.addRunArtifact(integration_test);
    const integration_test_step = b.step("test-integration", "Run Integration tests");
    integration_test_step.dependOn(&run_integration_test.step);

    // Add comprehensive EVM tests package
    const evm_package_test = b.addTest(.{
        .name = "evm-package-test",
        .root_source_file = b.path("test/evm/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    evm_package_test.root_module.stack_check = false;
    evm_package_test.root_module.addImport("primitives", mods.primitives);
    evm_package_test.root_module.addImport("evm", mods.evm);
    evm_package_test.root_module.addImport("Address", mods.primitives);

    const run_evm_package_test = b.addRunArtifact(evm_package_test);
    const evm_package_test_step = b.step("test-evm-all", "Run all EVM tests via package");
    evm_package_test_step.dependOn(&run_evm_package_test.step);

    // Add comprehensive opcodes tests package
    const opcodes_package_test = b.addTest(.{
        .name = "opcodes-package-test",
        .root_source_file = b.path("test/evm/opcodes/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    opcodes_package_test.root_module.stack_check = false;
    opcodes_package_test.root_module.addImport("primitives", mods.primitives);
    opcodes_package_test.root_module.addImport("evm", mods.evm);

    const run_opcodes_package_test = b.addRunArtifact(opcodes_package_test);
    const opcodes_package_test_step = b.step("test-opcodes-all", "Run all opcode tests via package");
    opcodes_package_test_step.dependOn(&run_opcodes_package_test.step);

    // Add differential tests package
    const differential_test = b.addTest(.{
        .name = "differential-test",
        .root_source_file = b.path("test/differential/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    differential_test.root_module.stack_check = false;
    differential_test.root_module.addImport("primitives", mods.primitives);
    differential_test.root_module.addImport("evm", mods.evm);

    const run_differential_test = b.addRunArtifact(differential_test);
    const differential_test_step = b.step("test-differential", "Run differential tests");
    differential_test_step.dependOn(&run_differential_test.step);

    // Add comprehensive ALL tests package
    const all_tests_package = b.addTest(.{
        .name = "all-tests-package",
        .root_source_file = b.path("test/package.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    all_tests_package.root_module.stack_check = false;
    all_tests_package.root_module.addImport("primitives", mods.primitives);
    all_tests_package.root_module.addImport("evm", mods.evm);
    all_tests_package.root_module.addImport("Address", mods.primitives);
    // Note: revm import is conditional and added through mods.lib if available
    // all_tests_package.root_module.addImport("revm", revm_mod);

    const run_all_tests_package = b.addRunArtifact(all_tests_package);
    const all_tests_package_step = b.step("test-all-comprehensive", "Run ALL tests via package system");
    all_tests_package_step.dependOn(&run_all_tests_package.step);

    // Add Gas Accounting tests
    const gas_test = b.addTest(.{
        .name = "gas-test",
        .root_source_file = b.path("test/evm/gas/gas_accounting_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    gas_test.root_module.stack_check = false;
    gas_test.root_module.addImport("primitives", mods.primitives);
    gas_test.root_module.addImport("evm", mods.evm);

    const run_gas_test = b.addRunArtifact(gas_test);
    const gas_test_step = b.step("test-gas", "Run Gas Accounting tests");
    gas_test_step.dependOn(&run_gas_test.step);

    // Add Static Call Protection tests
    const static_protection_test = b.addTest(.{
        .name = "static-protection-test",
        .root_source_file = b.path("test/evm/static_call_protection_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    static_protection_test.root_module.stack_check = false;
    static_protection_test.root_module.addImport("primitives", mods.primitives);
    static_protection_test.root_module.addImport("evm", mods.evm);

    const run_static_protection_test = b.addRunArtifact(static_protection_test);
    const static_protection_test_step = b.step("test-static-protection", "Run Static Call Protection tests");
    static_protection_test_step.dependOn(&run_static_protection_test.step);

    // Add Precompile SHA256 tests (only if precompiles are enabled)
    // TODO: Fix precompile detection in modular build
    // var run_sha256_test: ?*std.Build.Step.Run = null;
    // if (!no_precompiles) {
    if (false) { // Temporarily disabled
        const sha256_test = b.addTest(.{
            .name = "sha256-test",
            .root_source_file = b.path("test/evm/precompiles/sha256_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        sha256_test.root_module.stack_check = false;
        sha256_test.root_module.addImport("primitives", mods.primitives);
        sha256_test.root_module.addImport("evm", mods.evm);

        // run_sha256_test = b.addRunArtifact(sha256_test);
        // const sha256_test_step = b.step("test-sha256", "Run SHA256 precompile tests");
        // sha256_test_step.dependOn(&run_sha256_test.?.step);
    }

    // Add RIPEMD160 precompile tests (only if precompiles are enabled)
    // var run_ripemd160_test: ?*std.Build.Step.Run = null;
    if (false) { // Temporarily disabled - was: if (!no_precompiles) {
        const ripemd160_test = b.addTest(.{
            .name = "ripemd160-test",
            .root_source_file = b.path("test/evm/precompiles/ripemd160_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        ripemd160_test.root_module.stack_check = false;
        ripemd160_test.root_module.addImport("primitives", mods.primitives);
        ripemd160_test.root_module.addImport("evm", mods.evm);

        // run_ripemd160_test = b.addRunArtifact(ripemd160_test);
        // const ripemd160_test_step = b.step("test-ripemd160", "Run RIPEMD160 precompile tests");
        // ripemd160_test_step.dependOn(&run_ripemd160_test.?.step);
    }

    // Add BLAKE2f tests
    const blake2f_test = b.addTest(.{
        .name = "blake2f-test",
        .root_source_file = b.path("test/evm/precompiles/blake2f_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    blake2f_test.root_module.stack_check = false;
    blake2f_test.root_module.addImport("primitives", mods.primitives);
    blake2f_test.root_module.addImport("evm", mods.evm);
    const run_blake2f_test = b.addRunArtifact(blake2f_test);
    const blake2f_test_step = b.step("test-blake2f", "Run BLAKE2f precompile tests");
    blake2f_test_step.dependOn(&run_blake2f_test.step);

    // Add BN254 Rust wrapper tests (only if BN254 is enabled)
    const run_bn254_rust_test = if (rust_libs.bn254_lib) |bn254_library| blk: {
        const bn254_rust_test = b.addTest(.{
            .name = "bn254-rust-test",
            .root_source_file = b.path("test/evm/precompiles/bn254_rust_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        bn254_rust_test.root_module.stack_check = false;
        bn254_rust_test.root_module.addImport("primitives", mods.primitives);
        bn254_rust_test.root_module.addImport("evm", mods.evm);
        // Link BN254 Rust library to tests
        bn254_rust_test.linkLibrary(bn254_library);
        bn254_rust_test.addIncludePath(b.path("src/bn254_wrapper"));

        const run_test = b.addRunArtifact(bn254_rust_test);
        const test_step_bn254 = b.step("test-bn254-rust", "Run BN254 Rust wrapper precompile tests");
        test_step_bn254.dependOn(&run_test.step);

        break :blk run_test;
    } else null;

    // Add E2E Simple tests
    const e2e_simple_test = b.addTest(.{
        .name = "e2e-simple-test",
        .root_source_file = b.path("test/evm/e2e_simple_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_simple_test.root_module.stack_check = false;
    e2e_simple_test.root_module.addImport("primitives", mods.primitives);
    e2e_simple_test.root_module.addImport("evm", mods.evm);

    const run_e2e_simple_test = b.addRunArtifact(e2e_simple_test);
    const e2e_simple_test_step = b.step("test-e2e-simple", "Run E2E simple tests");
    e2e_simple_test_step.dependOn(&run_e2e_simple_test.step);

    // Add E2E Error Handling tests
    const e2e_error_test = b.addTest(.{
        .name = "e2e-error-test",
        .root_source_file = b.path("test/evm/e2e_error_handling_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_error_test.root_module.stack_check = false;
    e2e_error_test.root_module.addImport("primitives", mods.primitives);
    e2e_error_test.root_module.addImport("evm", mods.evm);

    const run_e2e_error_test = b.addRunArtifact(e2e_error_test);
    const e2e_error_test_step = b.step("test-e2e-error", "Run E2E error handling tests");
    e2e_error_test_step.dependOn(&run_e2e_error_test.step);

    // Add E2E Data Structures tests
    const e2e_data_test = b.addTest(.{
        .name = "e2e-data-test",
        .root_source_file = b.path("test/evm/e2e_data_structures_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    e2e_data_test.root_module.stack_check = false;
    e2e_data_test.root_module.addImport("primitives", mods.primitives);
    e2e_data_test.root_module.addImport("evm", mods.evm);

    const run_e2e_data_test = b.addRunArtifact(e2e_data_test);
    const e2e_data_test_step = b.step("test-e2e-data", "Run E2E data structures tests");
    e2e_data_test_step.dependOn(&run_e2e_data_test.step);

    // TODO: Misplaced macOS bundle code during conflict resolution - already handled in setupMacOSDevtool
    // const bundle_dir = "macos/GuillotineDevtool.app/Contents/MacOS";
    // const copy_to_bundle = b.addSystemCommand(&[_][]const u8{
    //     "cp", "-f", "zig-out/bin/guillotine-devtool", bundle_dir,
    // });
    // copy_to_bundle.step.dependOn(&devtool_exe.step);
    // copy_to_bundle.step.dependOn(&mkdir_bundle.step);
    //
    // const macos_app_step = b.step("macos-app", "Create macOS app bundle");
    // macos_app_step.dependOn(&copy_to_bundle.step);
    //
    // const create_dmg = b.addSystemCommand(&[_][]const u8{
    //     "scripts/create-dmg-fancy.sh",
    // });
    // create_dmg.step.dependOn(&copy_to_bundle.step);
    //
    // const dmg_step = b.step("macos-dmg", "Create macOS DMG installer");
    // dmg_step.dependOn(&create_dmg.step);

    // TODO: Misplaced compiler test code during conflict resolution - need proper test definition
    // compiler_test.root_module.addImport("primitives", mods.primitives);
    // compiler_test.root_module.addImport("evm", mods.evm);
    //
    // // TODO: Re-enable when Rust integration is fixed
    // // // Make the compiler test depend on the Rust build
    // // compiler_test.step.dependOn(rust_step);
    //
    // // // Link the Rust library to the compiler test
    // // compiler_test.addObjectFile(b.path("zig-out/lib/libfoundry_wrapper.a"));
    // // compiler_test.linkLibC();
    //
    // // // Link system libraries required by Rust static lib
    // // if (target.result.os.tag == .linux) {
    // //     compiler_test.linkSystemLibrary("unwind");
    // //     compiler_test.linkSystemLibrary("gcc_s");
    // // } else if (target.result.os.tag == .macos) {
    // //     compiler_test.linkFramework("CoreFoundation");
    // //     compiler_test.linkFramework("Security");
    // // }
    //
    // const run_compiler_test = b.addRunArtifact(compiler_test);
    // const compiler_test_step = b.step("test-compiler", "Run Compiler tests");
    // compiler_test_step.dependOn(&run_compiler_test.step);

    // Add Devtool tests
    const devtool_test = b.addTest(.{
        .name = "devtool-test",
        .root_source_file = b.path("src/devtool/evm.zig"),
        .target = target,
        .optimize = optimize,
    });
    devtool_test.root_module.addImport("evm", mods.evm);
    devtool_test.root_module.addImport("primitives", mods.primitives);

    const run_devtool_test = b.addRunArtifact(devtool_test);
    const devtool_test_step = b.step("test-devtool", "Run Devtool tests");
    devtool_test_step.dependOn(&run_devtool_test.step);

    // Add SnailShellBenchmark test
    const snail_shell_benchmark_test = b.addTest(.{
        .name = "snail-shell-benchmark-test",
        .root_source_file = b.path("src/solidity/snail_shell_benchmark_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_shell_benchmark_test.root_module.addImport("primitives", mods.primitives);
    snail_shell_benchmark_test.root_module.addImport("evm", mods.evm);

    const run_snail_shell_benchmark_test = b.addRunArtifact(snail_shell_benchmark_test);
    const snail_shell_benchmark_test_step = b.step("test-benchmark", "Run SnailShellBenchmark tests");
    snail_shell_benchmark_test_step.dependOn(&run_snail_shell_benchmark_test.step);

    // Add BN254 fuzz tests
    const bn254_fuzz_test = b.addTest(.{
        .name = "bn254-fuzz-test",
        .root_source_file = b.path("src/crypto/bn254/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fuzz_test.root_module.addImport("primitives", mods.primitives);

    const run_bn254_fuzz_test = b.addRunArtifact(bn254_fuzz_test);
    if (b.args) |args| {
        run_bn254_fuzz_test.addArgs(args);
    }
    const bn254_fuzz_test_step = b.step("fuzz-bn254", "Run BN254 fuzz tests (use: zig build fuzz-bn254 -- --fuzz)");
    bn254_fuzz_test_step.dependOn(&run_bn254_fuzz_test.step);

    // Add ECMUL precompile fuzz tests
    const ecmul_fuzz_test = b.addTest(.{
        .name = "ecmul-fuzz-test",
        .root_source_file = b.path("src/evm/precompiles/ecmul_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    ecmul_fuzz_test.root_module.addImport("primitives", mods.primitives);
    ecmul_fuzz_test.root_module.addImport("crypto", mods.crypto);
    ecmul_fuzz_test.root_module.addImport("evm", mods.evm);

    const run_ecmul_fuzz_test = b.addRunArtifact(ecmul_fuzz_test);
    if (b.args) |args| {
        run_ecmul_fuzz_test.addArgs(args);
    }
    const ecmul_fuzz_test_step = b.step("fuzz-ecmul", "Run ECMUL precompile fuzz tests (use: zig build fuzz-ecmul -- --fuzz)");
    ecmul_fuzz_test_step.dependOn(&run_ecmul_fuzz_test.step);

    // Add ECPAIRING precompile fuzz tests
    const ecpairing_fuzz_test = b.addTest(.{
        .name = "ecpairing-fuzz-test",
        .root_source_file = b.path("src/evm/precompiles/ecpairing_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    ecpairing_fuzz_test.root_module.addImport("primitives", mods.primitives);
    ecpairing_fuzz_test.root_module.addImport("crypto", mods.crypto);
    ecpairing_fuzz_test.root_module.addImport("evm", mods.evm);

    const run_ecpairing_fuzz_test = b.addRunArtifact(ecpairing_fuzz_test);
    if (b.args) |args| {
        run_ecpairing_fuzz_test.addArgs(args);
    }
    const ecpairing_fuzz_test_step = b.step("fuzz-ecpairing", "Run ECPAIRING precompile fuzz tests (use: zig build fuzz-ecpairing -- --fuzz)");
    ecpairing_fuzz_test_step.dependOn(&run_ecpairing_fuzz_test.step);

    // Add BN254 comparison fuzz test (Zig vs Rust)
    const bn254_comparison_fuzz_test = b.addTest(.{
        .name = "bn254-comparison-fuzz-test",
        .root_source_file = b.path("test/fuzz/bn254_comparison_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_comparison_fuzz_test.root_module.addImport("primitives", mods.primitives);
    bn254_comparison_fuzz_test.root_module.addImport("crypto", mods.crypto);
    bn254_comparison_fuzz_test.root_module.addImport("evm", mods.evm);
    if (rust_libs.bn254_lib) |bn254| {
        bn254_comparison_fuzz_test.linkLibrary(bn254);
    }

    const run_bn254_comparison_fuzz_test = b.addRunArtifact(bn254_comparison_fuzz_test);
    if (b.args) |args| {
        run_bn254_comparison_fuzz_test.addArgs(args);
    }
    const bn254_comparison_fuzz_test_step = b.step("fuzz-compare", "Run BN254 comparison fuzz tests (use: zig build fuzz-compare -- --fuzz)");
    bn254_comparison_fuzz_test_step.dependOn(&run_bn254_comparison_fuzz_test.step);

    // Add a master fuzz test step that runs all fuzz tests
    const fuzz_all_step = b.step("fuzz", "Run all fuzz tests (use: zig build fuzz -- --fuzz)");
    fuzz_all_step.dependOn(&run_bn254_fuzz_test.step);
    fuzz_all_step.dependOn(&run_ecmul_fuzz_test.step);
    fuzz_all_step.dependOn(&run_ecpairing_fuzz_test.step);
    fuzz_all_step.dependOn(&run_bn254_comparison_fuzz_test.step);

    // Add Constructor Bug test
    const constructor_bug_test = b.addTest(.{
        .name = "constructor-bug-test",
        .root_source_file = b.path("test/evm/constructor_bug_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    constructor_bug_test.root_module.addImport("primitives", mods.primitives);
    constructor_bug_test.root_module.addImport("evm", mods.evm);
    const run_constructor_bug_test = b.addRunArtifact(constructor_bug_test);
    const constructor_bug_test_step = b.step("test-constructor-bug", "Run Constructor Bug test");
    constructor_bug_test_step.dependOn(&run_constructor_bug_test.step);

    // Add Solidity Constructor test
    const solidity_constructor_test = b.addTest(.{
        .name = "solidity-constructor-test",
        .root_source_file = b.path("test/evm/solidity_constructor_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    solidity_constructor_test.root_module.addImport("primitives", mods.primitives);
    solidity_constructor_test.root_module.addImport("evm", mods.evm);
    const run_solidity_constructor_test = b.addRunArtifact(solidity_constructor_test);
    const solidity_constructor_test_step = b.step("test-solidity-constructor", "Run Solidity Constructor test");
    solidity_constructor_test_step.dependOn(&run_solidity_constructor_test.step);

    // Add RETURN opcode bug test
    const return_opcode_bug_test = b.addTest(.{
        .name = "return-opcode-bug-test",
        .root_source_file = b.path("test/evm/return_opcode_bug_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    return_opcode_bug_test.root_module.addImport("primitives", mods.primitives);
    return_opcode_bug_test.root_module.addImport("evm", mods.evm);
    const run_return_opcode_bug_test = b.addRunArtifact(return_opcode_bug_test);
    const return_opcode_bug_test_step = b.step("test-return-opcode-bug", "Run RETURN opcode bug test");
    return_opcode_bug_test_step.dependOn(&run_return_opcode_bug_test.step);

    const contract_call_test = b.addTest(.{
        .name = "contract-call-test",
        .root_source_file = b.path("test/evm/contract_call_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    contract_call_test.root_module.addImport("primitives", mods.primitives);
    contract_call_test.root_module.addImport("evm", mods.evm);
    const run_contract_call_test = b.addRunArtifact(contract_call_test);
    const contract_call_test_step = b.step("test-contract-call", "Run Contract Call tests");
    contract_call_test_step.dependOn(&run_contract_call_test.step);

    // Hardfork tests removed - provider implementation is broken

    // Add DELEGATECALL test
    const delegatecall_test = b.addTest(.{
        .name = "delegatecall-test",
        .root_source_file = b.path("test/evm/opcodes/delegatecall_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    delegatecall_test.root_module.addImport("primitives", mods.primitives);
    delegatecall_test.root_module.addImport("evm", mods.evm);
    const run_delegatecall_test = b.addRunArtifact(delegatecall_test);
    const delegatecall_test_step = b.step("test-delegatecall", "Run DELEGATECALL tests");
    delegatecall_test_step.dependOn(&run_delegatecall_test.step);

    // Add BN254 individual test targets
    const bn254_fp_test = b.addTest(.{
        .name = "bn254-fp-test",
        .root_source_file = b.path("src/crypto/bn254/FpMont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_fp_test = b.addRunArtifact(bn254_fp_test);
    const bn254_fp_test_step = b.step("test-bn254-fp", "Run BN254 Fp tests");
    bn254_fp_test_step.dependOn(&run_bn254_fp_test.step);

    const bn254_fr_test = b.addTest(.{
        .name = "bn254-fr-test",
        .root_source_file = b.path("src/crypto/bn254/Fr.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fr_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_fr_test = b.addRunArtifact(bn254_fr_test);
    const bn254_fr_test_step = b.step("test-bn254-fr", "Run BN254 Fr tests");
    bn254_fr_test_step.dependOn(&run_bn254_fr_test.step);

    const bn254_fp2_test = b.addTest(.{
        .name = "bn254-fp2-test",
        .root_source_file = b.path("src/crypto/bn254/Fp2Mont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp2_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_fp2_test = b.addRunArtifact(bn254_fp2_test);
    const bn254_fp2_test_step = b.step("test-bn254-fp2", "Run BN254 Fp2 tests");
    bn254_fp2_test_step.dependOn(&run_bn254_fp2_test.step);

    const bn254_fp6_test = b.addTest(.{
        .name = "bn254-fp6-test",
        .root_source_file = b.path("src/crypto/bn254/Fp6Mont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp6_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_fp6_test = b.addRunArtifact(bn254_fp6_test);
    const bn254_fp6_test_step = b.step("test-bn254-fp6", "Run BN254 Fp6 tests");
    bn254_fp6_test_step.dependOn(&run_bn254_fp6_test.step);

    const bn254_fp12_test = b.addTest(.{
        .name = "bn254-fp12-test",
        .root_source_file = b.path("src/crypto/bn254/Fp12Mont.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_fp12_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_fp12_test = b.addRunArtifact(bn254_fp12_test);
    const bn254_fp12_test_step = b.step("test-bn254-fp12", "Run BN254 Fp12 tests");
    bn254_fp12_test_step.dependOn(&run_bn254_fp12_test.step);

    const bn254_g1_test = b.addTest(.{
        .name = "bn254-g1-test",
        .root_source_file = b.path("src/crypto/bn254/G1.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_g1_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_g1_test = b.addRunArtifact(bn254_g1_test);
    const bn254_g1_test_step = b.step("test-bn254-g1", "Run BN254 G1 tests");
    bn254_g1_test_step.dependOn(&run_bn254_g1_test.step);

    const bn254_g2_test = b.addTest(.{
        .name = "bn254-g2-test",
        .root_source_file = b.path("src/crypto/bn254/G2.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_g2_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_g2_test = b.addRunArtifact(bn254_g2_test);
    const bn254_g2_test_step = b.step("test-bn254-g2", "Run BN254 G2 tests");
    bn254_g2_test_step.dependOn(&run_bn254_g2_test.step);

    const bn254_pairing_test = b.addTest(.{
        .name = "bn254-pairing-test",
        .root_source_file = b.path("src/crypto/bn254/pairing.zig"),
        .target = target,
        .optimize = optimize,
    });
    bn254_pairing_test.root_module.addImport("primitives", mods.primitives);
    const run_bn254_pairing_test = b.addRunArtifact(bn254_pairing_test);
    const bn254_pairing_test_step = b.step("test-bn254-pairing", "Run BN254 pairing tests");
    bn254_pairing_test_step.dependOn(&run_bn254_pairing_test.step);

    // Add combined E2E test step
    const e2e_all_test_step = b.step("test-e2e", "Run all E2E tests");
    e2e_all_test_step.dependOn(&run_e2e_simple_test.step);
    e2e_all_test_step.dependOn(&run_e2e_error_test.step);
    e2e_all_test_step.dependOn(&run_e2e_data_test.step);
    e2e_all_test_step.dependOn(&run_e2e_inheritance_test.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_memory_test.step);
    test_step.dependOn(&run_stack_test.step);
    test_step.dependOn(&run_newevm_test.step);
    test_step.dependOn(&run_stack_validation_test.step);
    test_step.dependOn(&run_jump_table_test.step);
    test_step.dependOn(&run_config_test.step);
    // benchmark runner test removed - file no longer exists

    // Add inline ops test
    const inline_ops_test = b.addTest(.{
        .name = "inline-ops-test",
        .root_source_file = b.path("test/evm/inline_ops_test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    inline_ops_test.root_module.stack_check = false;
    inline_ops_test.root_module.addImport("primitives", mods.primitives);
    inline_ops_test.root_module.addImport("evm", mods.evm);
    const run_inline_ops_test = b.addRunArtifact(inline_ops_test);

    // Instruction tests moved to test/evm/instruction_test.zig to avoid circular dependencies
    // The tests are included via the regular test/evm test suite

    const inline_ops_test_step = b.step("test-inline-ops", "Run inline ops performance tests");
    inline_ops_test_step.dependOn(&run_inline_ops_test.step);

    // Block metadata heap test removed - file no longer exists

    // Code analysis optimized test removed - file no longer exists

    test_step.dependOn(&run_blake2f_test.step);
    if (run_bn254_rust_test) |bn254_test| {
        test_step.dependOn(&bn254_test.step);
    }

    // Add SHA256 and RIPEMD160 tests if precompiles are enabled
    if (run_sha256_test) |sha256_test| {
        test_step.dependOn(&sha256_test.step);
    }
    if (run_ripemd160_test) |ripemd160_test| {
        test_step.dependOn(&ripemd160_test.step);
    }

    // Add REVM wrapper tests if available
    if (revm_lib != null) {
        const revm_test = b.addTest(.{
            .name = "revm-test",
            .root_source_file = b.path("src/revm_wrapper/test_revm_wrapper.zig"),
            .target = target,
            .optimize = optimize,
        });
        revm_test.root_module.addImport("primitives", mods.primitives);
        revm_test.linkLibrary(revm_lib.?);
        revm_test.addIncludePath(b.path("src/revm_wrapper"));
        revm_test.linkLibC();

        // Link the compiled Rust dynamic library
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        revm_test.addObjectFile(b.path(revm_dylib_path));

        // Link additional libraries needed by revm
        if (target.result.os.tag == .linux) {
            revm_test.linkSystemLibrary("m");
            revm_test.linkSystemLibrary("pthread");
            revm_test.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            revm_test.linkSystemLibrary("c++");
            revm_test.linkFramework("Security");
            revm_test.linkFramework("SystemConfiguration");
            revm_test.linkFramework("CoreFoundation");
        }

        // Make sure the test depends on the Rust library being built
        revm_test.step.dependOn(&revm_lib.?.step);

        const run_revm_test = b.addRunArtifact(revm_test);
        test_step.dependOn(&run_revm_test.step);

        // Also add a separate step for revm tests
        const revm_test_step = b.step("test-revm", "Run REVM wrapper tests");
        revm_test_step.dependOn(&run_revm_test.step);
    }

    test_step.dependOn(&run_return_opcode_bug_test.step);
    // Hardfork tests removed completely

    // Add all BN254 tests to main test step
    test_step.dependOn(&run_bn254_fp_test.step);
    test_step.dependOn(&run_bn254_fr_test.step);
    test_step.dependOn(&run_bn254_fp2_test.step);
    test_step.dependOn(&run_bn254_fp6_test.step);
    test_step.dependOn(&run_bn254_fp12_test.step);
    test_step.dependOn(&run_bn254_g1_test.step);
    test_step.dependOn(&run_bn254_g2_test.step);
    test_step.dependOn(&run_bn254_pairing_test.step);

    // Add comprehensive test packages to main test step

    // Add ERC20 deployment hang test
    const erc20_deployment_test = b.addTest(.{
        .name = "erc20-deployment-test",
        .root_source_file = b.path("test/evm/erc20_deployment_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_deployment_test.root_module.addImport("evm", mods.evm);
    erc20_deployment_test.root_module.addImport("primitives", mods.primitives);
    const run_erc20_deployment_test = b.addRunArtifact(erc20_deployment_test);
    test_step.dependOn(&run_erc20_deployment_test.step);

    // Add ERC20 mint debug test
    const erc20_mint_debug_test = b.addTest(.{
        .name = "erc20-mint-debug-test",
        .root_source_file = b.path("test/evm/erc20_mint_debug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_mint_debug_test.root_module.addImport("primitives", mods.primitives);
    erc20_mint_debug_test.root_module.addImport("evm", mods.evm);
    erc20_mint_debug_test.root_module.addImport("Address", mods.primitives);
    const run_erc20_mint_debug_test = b.addRunArtifact(erc20_mint_debug_test);
    const erc20_mint_debug_test_step = b.step("test-erc20-debug", "Run ERC20 mint test with full debug logging");
    erc20_mint_debug_test_step.dependOn(&run_erc20_mint_debug_test.step);

    // Add constructor REVERT test
    const constructor_revert_test = b.addTest(.{
        .name = "constructor-revert-test",
        .root_source_file = b.path("test/evm/constructor_revert_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    constructor_revert_test.root_module.addImport("primitives", mods.primitives);
    constructor_revert_test.root_module.addImport("evm", mods.evm);
    constructor_revert_test.root_module.addImport("Address", mods.primitives);
    const run_constructor_revert_test = b.addRunArtifact(constructor_revert_test);
    const constructor_revert_test_step = b.step("test-constructor-revert", "Run constructor REVERT test");
    constructor_revert_test_step.dependOn(&run_constructor_revert_test.step);
    test_step.dependOn(&run_constructor_revert_test.step);

    // Add ERC20 constructor debug test
    const erc20_constructor_debug_test = b.addTest(.{
        .name = "erc20-constructor-debug-test",
        .root_source_file = b.path("test/evm/erc20_constructor_debug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_constructor_debug_test.root_module.addImport("primitives", mods.primitives);
    erc20_constructor_debug_test.root_module.addImport("evm", mods.evm);
    erc20_constructor_debug_test.root_module.addImport("Address", mods.primitives);
    const run_erc20_constructor_debug_test = b.addRunArtifact(erc20_constructor_debug_test);
    const erc20_constructor_debug_test_step = b.step("test-erc20-constructor", "Run ERC20 constructor debug test");
    erc20_constructor_debug_test_step.dependOn(&run_erc20_constructor_debug_test.step);

    // Add trace ERC20 constructor test
    const trace_erc20_test = b.addTest(.{
        .name = "trace-erc20-test",
        .root_source_file = b.path("test/evm/trace_erc20_constructor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    trace_erc20_test.root_module.addImport("primitives", mods.primitives);
    trace_erc20_test.root_module.addImport("evm", mods.evm);
    trace_erc20_test.root_module.addImport("Address", mods.primitives);
    const run_trace_erc20_test = b.addRunArtifact(trace_erc20_test);
    const trace_erc20_test_step = b.step("test-trace-erc20", "Trace ERC20 constructor execution");
    trace_erc20_test_step.dependOn(&run_trace_erc20_test.step);

    // Add string storage test
    const string_storage_test = b.addTest(.{
        .name = "string-storage-test",
        .root_source_file = b.path("test/evm/string_storage_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_storage_test.root_module.addImport("evm", mods.evm);
    string_storage_test.root_module.addImport("Address", mods.primitives);

    const run_string_storage_test = b.addRunArtifact(string_storage_test);
    const string_storage_test_step = b.step("test-string-storage", "Run string storage tests");
    string_storage_test_step.dependOn(&run_string_storage_test.step);

    // Add JUMPI bug test
    const jumpi_bug_test = b.addTest(.{
        .name = "jumpi-bug-test",
        .root_source_file = b.path("test/evm/jumpi_bug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    jumpi_bug_test.root_module.addImport("evm", mods.evm);
    jumpi_bug_test.root_module.addImport("Address", mods.primitives);

    const run_jumpi_bug_test = b.addRunArtifact(jumpi_bug_test);
    test_step.dependOn(&run_jumpi_bug_test.step);

    // Add EIP-2929 warm/cold access test
    const jumpi_bug_test_step = b.step("test-jumpi", "Run JUMPI bug test");
    jumpi_bug_test_step.dependOn(&run_jumpi_bug_test.step);

    // Add block execution ERC20 test
    const block_execution_erc20_test = b.addTest(.{
        .name = "block-execution-erc20-test",
        .root_source_file = b.path("test/evm/block_execution_erc20_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_execution_erc20_test.root_module.addImport("evm", mods.evm);
    block_execution_erc20_test.root_module.addImport("primitives", mods.primitives);

    const run_block_execution_erc20_test = b.addRunArtifact(block_execution_erc20_test);
    const block_execution_erc20_test_step = b.step("test-block-execution-erc20", "Run block execution ERC20 test");
    block_execution_erc20_test_step.dependOn(&run_block_execution_erc20_test.step);

    // Add simple block execution test
    const block_execution_simple_test = b.addTest(.{
        .name = "block-execution-simple-test",
        .root_source_file = b.path("test/evm/block_execution_simple.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_execution_simple_test.root_module.addImport("evm", mods.evm);
    block_execution_simple_test.root_module.addImport("primitives", mods.primitives);

    const run_block_execution_simple_test = b.addRunArtifact(block_execution_simple_test);
    test_step.dependOn(&run_block_execution_simple_test.step);
    const block_execution_simple_test_step = b.step("test-block-execution-simple", "Run simple block execution test");
    block_execution_simple_test_step.dependOn(&run_block_execution_simple_test.step);

    // TRACER REMOVED: Commenting out tracer tests until tracer is reimplemented
    // See: https://github.com/evmts/guillotine/issues/325
    // const tracer_test = b.addTest(.{
    //     .name = "tracer-test",
    //     .root_source_file = b.path("test/evm/tracer_test.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // tracer_test.root_module.addImport("evm", mods.evm);
    // tracer_test.root_module.addImport("Address", mods.primitives);
    //
    // const run_tracer_test = b.addRunArtifact(tracer_test);
    // test_step.dependOn(&run_tracer_test.step);
    // const tracer_test_step = b.step("test-tracer", "Run tracer test");
    // tracer_test_step.dependOn(&run_tracer_test.step);

    // Add compare execution test
    // TODO: Re-enable when tracer is reimplemented
    // const compare_test = b.addTest(.{
    //     .name = "compare-test",
    //     .root_source_file = b.path("test/evm/compare_execution.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // compare_test.root_module.addImport("evm", mods.evm);
    // compare_test.root_module.addImport("primitives", mods.primitives);

    // const run_compare_test = b.addRunArtifact(compare_test);
    // test_step.dependOn(&run_compare_test.step);
    // const compare_test_step = b.step("test-compare", "Run execution comparison test");
    // compare_test_step.dependOn(&run_compare_test.step);

    // Add comprehensive opcode comparison executable
    const comprehensive_compare = b.addExecutable(.{
        .name = "comprehensive-opcode-comparison",
        .root_source_file = b.path("test/evm/comprehensive_opcode_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_compare.root_module.addImport("evm", mods.evm);
    comprehensive_compare.root_module.addImport("primitives", mods.primitives);
    comprehensive_compare.root_module.addImport("Address", mods.primitives);
    // Note: revm import is conditional and added through mods.lib if available
    // comprehensive_compare.root_module.addImport("revm", revm_mod);

    // Link REVM wrapper library if available
    if (rust_libs.revm_lib) |revm_library| {
        comprehensive_compare.linkLibrary(revm_library);
        comprehensive_compare.addIncludePath(b.path("src/revm_wrapper"));
        comprehensive_compare.linkLibC();

        // Link the compiled Rust dynamic library
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir});
        comprehensive_compare.addObjectFile(b.path(revm_dylib_path));

        // Link additional libraries needed by revm
        if (target.result.os.tag == .linux) {
            comprehensive_compare.linkSystemLibrary("m");
            comprehensive_compare.linkSystemLibrary("pthread");
            comprehensive_compare.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            comprehensive_compare.linkSystemLibrary("c++");
            comprehensive_compare.linkFramework("Security");
            comprehensive_compare.linkFramework("CoreFoundation");
        }
    }

    // Link BN254 library if available (required by REVM)
    if (rust_libs.bn254_lib) |bn254_library| {
        comprehensive_compare.linkLibrary(bn254_library);
        comprehensive_compare.addIncludePath(b.path("src/bn254_wrapper"));
    }

    const run_comprehensive_compare = b.addRunArtifact(comprehensive_compare);
    const comprehensive_compare_step = b.step("run-comprehensive-compare", "Run comprehensive opcode comparison");
    comprehensive_compare_step.dependOn(&run_comprehensive_compare.step);

    // Add ERC20 trace test
    const erc20_trace_test = b.addTest(.{
        .name = "erc20-trace-test",
        .root_source_file = b.path("test/evm/trace_erc20_constructor.zig"),
        .target = target,
        .optimize = optimize,
    });
    erc20_trace_test.root_module.addImport("evm", mods.evm);
    erc20_trace_test.root_module.addImport("primitives", mods.primitives);

    const run_erc20_trace_test = b.addRunArtifact(erc20_trace_test);
    const erc20_trace_test_step = b.step("test-erc20-trace", "Run ERC20 constructor trace test");
    erc20_trace_test_step.dependOn(&run_erc20_trace_test.step);

    // TODO: Re-enable when Rust integration is fixed
    // test_step.dependOn(&run_compiler_test.step);
    // test_step.dependOn(&run_snail_tracer_test.step);

    // Add Fuzz Testing using test configuration data
    // Removed duplicate - fuzz step already defined above

    // Create fuzz tests from configuration
    for (tests.fuzz_tests) |test_info| {
        const fuzz_test = b.addTest(.{
            .name = test_info.name,
            .root_source_file = b.path(test_info.source_file),
            .target = target,
            .optimize = optimize,
        });
        fuzz_test.root_module.addImport("evm", mods.evm);

        // Some fuzz tests also need primitives
        if (std.mem.indexOf(u8, test_info.name, "arithmetic") != null or
            std.mem.indexOf(u8, test_info.name, "bitwise") != null or
            std.mem.indexOf(u8, test_info.name, "comparison") != null or
            std.mem.indexOf(u8, test_info.name, "control") != null or
            std.mem.indexOf(u8, test_info.name, "crypto") != null or
            std.mem.indexOf(u8, test_info.name, "environment") != null or
            std.mem.indexOf(u8, test_info.name, "storage") != null or
            std.mem.indexOf(u8, test_info.name, "state") != null)
        {
            fuzz_test.root_module.addImport("primitives", mods.primitives);
        }

        const run_fuzz_test = b.addRunArtifact(fuzz_test);
        if (b.args) |args| {
            run_fuzz_test.addArgs(args);
        }
        fuzz_all_step.dependOn(&run_fuzz_test.step);

        // Create individual test step if specified
        if (test_info.step_name) |step_name| {
            const individual_step = b.step(
                step_name,
                test_info.step_desc orelse "Run test",
            );
            individual_step.dependOn(&run_fuzz_test.step);
        }
    }

    // Documentation generation step
    const docs_step = b.step("docs", "Generate and install documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);

    // Python bindings build step
    const python_build_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py" });
    python_build_cmd.setCwd(b.path("src/guillotine-py"));
    python_build_cmd.step.dependOn(b.getInstallStep()); // Ensure native library is built first

    const python_build_step = b.step("python", "Build Python bindings");
    python_build_step.dependOn(&python_build_cmd.step);

    // Python development install step
    const python_dev_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "build.py", "--dev" });
    python_dev_cmd.setCwd(b.path("src/guillotine-py"));
    python_dev_cmd.step.dependOn(b.getInstallStep());

    const python_dev_step = b.step("python-dev", "Build and install Python bindings in development mode");
    python_dev_step.dependOn(&python_dev_cmd.step);

    // Python tests step
    const python_test_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "-m", "pytest", "tests/", "-v" });
    python_test_cmd.setCwd(b.path("src/guillotine-py"));
    python_test_cmd.step.dependOn(&python_build_cmd.step);

    const python_test_step = b.step("python-test", "Run Python binding tests");
    python_test_step.dependOn(&python_test_cmd.step);

    // Python examples step
    const python_examples_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "examples.py" });
    python_examples_cmd.setCwd(b.path("src/guillotine-py"));
    python_examples_cmd.step.dependOn(&python_build_cmd.step);

    const python_examples_step = b.step("python-examples", "Run Python binding examples");
    python_examples_step.dependOn(&python_examples_cmd.step);

    // Swift build commands
    addSwiftSteps(b);

    // Go build commands
    addGoSteps(b);

    const dmg_step = b.step("macos-dmg", "Create macOS DMG installer");
    dmg_step.dependOn(&create_dmg.step);
}

fn setupDebugExecutables(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget) void {
    _ = b;
    _ = mods;
    _ = target;
    // Debug executables removed - source files don't exist
}

fn setupIntegrationTests(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    _ = b;
    _ = mods;
    _ = target;
    _ = optimize;
    // Integration tests removed - source files don't exist
}

fn setupOpcodeRustTests(b: *std.Build, mods: modules.Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    _ = b;
    _ = mods;
    _ = target;
    _ = optimize;
    // Opcode Rust tests removed - source files don't exist
}