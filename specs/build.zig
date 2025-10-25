const std = @import("std");
const Modules = @import("../src/modules.build.zig");
const GuillotineExe = @import("../src/build.zig");
const lib_build = @import("../lib/build.zig");
const DevtoolExe = @import("../src/devtool/build.zig");

fn checkSubmodules() void {
    // Check if critical submodules are initialized
    const submodules = [_]struct {
        path: []const u8,
        name: []const u8,
    }{
        .{ .path = "lib/c-kzg-4844/.git", .name = "c-kzg-4844" },
    };

    var has_error = false;

    for (submodules) |submodule| {
        std.fs.cwd().access(submodule.path, .{}) catch {
            if (!has_error) {
                std.debug.print("\n", .{});
                std.debug.print("❌ ERROR: Git submodules are not initialized!\n", .{});
                std.debug.print("\n", .{});
                std.debug.print("The following required submodules are missing:\n", .{});
                has_error = true;
            }
            std.debug.print("  • {s}\n", .{submodule.name});
        };
    }

    if (has_error) {
        std.debug.print("\n", .{});
        std.debug.print("To fix this, run the following commands:\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  git submodule update --init --recursive\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("This will download and initialize all required dependencies.\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(1);
    }
}

pub fn build(b: *std.Build) void {
    // Check submodules first
    checkSubmodules();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Download KZG trusted setup if it doesn't exist
    const kzg_path = "../src/kzg/trusted_setup.txt";
    std.fs.cwd().access(kzg_path, .{}) catch {
        const download_kzg = b.addSystemCommand(&[_][]const u8{
            "curl",
            "-L",
            "-o",
            kzg_path,
            "https://github.com/ethereum/c-kzg-4844/raw/main/src/trusted_setup.txt",
        });
        b.getInstallStep().dependOn(&download_kzg.step);
    };

    // Build configuration
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tracing", b.option(bool, "enable-tracing", "Enable EVM instruction tracing") orelse false);
    build_options.addOption(bool, "disable_tailcall_dispatch", b.option(bool, "disable-tailcall-dispatch", "Disable tailcall-based dispatch") orelse true);
    build_options.addOption([]const u8, "hardfork", b.option([]const u8, "evm-hardfork", "EVM hardfork (default: CANCUN)") orelse "CANCUN");
    build_options.addOption(bool, "disable_gas_checks", b.option(bool, "evm-disable-gas", "Disable gas checks for testing") orelse false);
    build_options.addOption(bool, "enable_fusion", b.option(bool, "evm-enable-fusion", "Enable bytecode fusion") orelse true);
    build_options.addOption([]const u8, "optimize_strategy", b.option([]const u8, "evm-optimize", "EVM optimization strategy") orelse "safe");
    build_options.addOption(u11, "max_call_depth", b.option(u11, "max-call-depth", "Maximum call depth (default: 1024)") orelse 1024);
    build_options.addOption(u12, "stack_size", b.option(u12, "stack-size", "Maximum stack size (default: 1024)") orelse 1024);
    build_options.addOption(u32, "max_bytecode_size", b.option(u32, "max-bytecode-size", "Maximum bytecode size (default: 24576)") orelse 24576);
    build_options.addOption(u32, "max_initcode_size", b.option(u32, "max-initcode-size", "Maximum initcode size (default: 49152)") orelse 49152);
    build_options.addOption(u64, "block_gas_limit", b.option(u64, "block-gas-limit", "Block gas limit (default: 30000000)") orelse 30_000_000);
    build_options.addOption(usize, "memory_initial_capacity", b.option(usize, "memory-initial-capacity", "Memory initial capacity (default: 4096)") orelse 4096);
    build_options.addOption(u64, "memory_limit", b.option(u64, "memory-limit", "Memory limit (default: 0xFFFFFF)") orelse 0xFFFFFF);
    build_options.addOption(usize, "arena_capacity_limit", b.option(usize, "arena-capacity-limit", "Arena capacity limit (default: 64MB)") orelse (64 * 1024 * 1024));
    build_options.addOption(bool, "disable_balance_checks", b.option(bool, "disable-balance-checks", "Disable balance checks") orelse false);
    const options_mod = build_options.createModule();
    
    const rust_target = b: {
        const os = target.result.os.tag;
        const arch = target.result.cpu.arch;
        
        break :b switch (os) {
            .macos => switch (arch) {
                .aarch64 => "aarch64-apple-darwin",
                .x86_64 => "x86_64-apple-darwin",
                else => "x86_64-apple-darwin",
            },
            .linux => switch (arch) {
                .aarch64 => "aarch64-unknown-linux-gnu",
                .x86_64 => "x86_64-unknown-linux-gnu",
                else => "x86_64-unknown-linux-gnu",
            },
            .windows => "x86_64-pc-windows-msvc",
            else => "x86_64-unknown-linux-gnu",
        };
    };

    // Dependencies
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = optimize }); // retained for module wiring; not used to build benches

    // Libraries
    const blst_lib = lib_build.BlstLib.createBlstLibrary(b, target, optimize);
    const c_kzg_lib = lib_build.CKzgLib.createCKzgLibrary(b, target, optimize, blst_lib);

    const rust_build_step = lib_build.FoundryLib.createRustBuildStep(b, rust_target, optimize);
    const bn254_lib = lib_build.Bn254Lib.createBn254Library(b, target, optimize, .{ .enable_tracy = false }, rust_build_step, rust_target);
    const foundry_lib = lib_build.FoundryLib.createFoundryLibrary(b, target, optimize, rust_build_step, rust_target);
    
    // Install BLS libraries to zig-out/lib for stable paths
    b.installArtifact(blst_lib);
    b.installArtifact(c_kzg_lib);
    if (bn254_lib) |bn254| b.installArtifact(bn254);

    // Modules
    const modules = Modules.createModules(b, target, optimize, options_mod, zbench_dep, c_kzg_lib, blst_lib, bn254_lib, foundry_lib);

    // Executables
    const guillotine_exe = GuillotineExe.createExecutable(b, modules.exe_mod);
    _ = GuillotineExe.createRunStep(b, guillotine_exe);

    // Bench runner executables are removed (moved to separate repo)

    // Asset generation for devtool
    const AssetGenerator = DevtoolExe.AssetGenerator;
    const npm_check = b.addSystemCommand(&[_][]const u8{ "which", "npm" });
    npm_check.addCheck(.{ .expect_stdout_match = "npm" });

    const npm_install = b.addSystemCommand(&[_][]const u8{ "npm", "install" });
    npm_install.setCwd(b.path("src/devtool"));
    npm_install.step.dependOn(&npm_check.step);

    const npm_build = b.addSystemCommand(&[_][]const u8{ "npm", "run", "build" });
    npm_build.setCwd(b.path("src/devtool"));
    npm_build.step.dependOn(&npm_install.step);

    const generate_assets = AssetGenerator.GenerateAssetsStep.init(b, "src/devtool/dist", "src/devtool/assets.zig");
    generate_assets.step.dependOn(&npm_build.step);

    const devtool_exe = DevtoolExe.createDevtoolExecutable(b, target, optimize, modules.lib_mod, modules.evm_mod, modules.primitives_mod, modules.provider_mod, &generate_assets.step);
    DevtoolExe.createDevtoolSteps(b, devtool_exe, target);

    // Pattern analyzer tool (JSON fixtures)
    const pattern_analyzer = b.addExecutable(.{
        .name = "pattern-analyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/analyze_patterns.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    pattern_analyzer.root_module.addImport("evm", modules.evm_mod);
    pattern_analyzer.root_module.addImport("primitives", modules.primitives_mod);
    pattern_analyzer.root_module.addImport("crypto", modules.crypto_mod);
    b.installArtifact(pattern_analyzer);

    const pattern_analyzer_step = b.step("build-pattern-analyzer", "Build JSON fixture pattern analyzer");
    pattern_analyzer_step.dependOn(&b.addInstallArtifact(pattern_analyzer, .{}).step);

    // Bytecode pattern analyzer (text files)
    const bytecode_patterns = b.addExecutable(.{
        .name = "bytecode-patterns",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/bytecode_patterns.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    bytecode_patterns.root_module.addImport("evm", modules.evm_mod);
    bytecode_patterns.root_module.addImport("primitives", modules.primitives_mod);
    bytecode_patterns.root_module.addImport("crypto", modules.crypto_mod);
    b.installArtifact(bytecode_patterns);

    const bytecode_patterns_step = b.step("build-bytecode-patterns", "Build bytecode pattern analyzer");
    bytecode_patterns_step.dependOn(&b.addInstallArtifact(bytecode_patterns, .{}).step);

    // Shared library for FFI bindings
    const shared_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/evm_c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_lib_mod.addImport("evm", modules.evm_mod);
    shared_lib_mod.addImport("primitives", modules.primitives_mod);
    shared_lib_mod.addImport("crypto", modules.crypto_mod);
    shared_lib_mod.addImport("build_options", options_mod);

    const shared_lib = b.addLibrary(.{
        .name = "guillotine_ffi",
        .linkage = .dynamic,
        .root_module = shared_lib_mod,
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    shared_lib.linkLibrary(c_kzg_lib);
    shared_lib.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| shared_lib.linkLibrary(bn254);
    shared_lib.linkLibC();
    // Export all symbols for Linux to ensure BLS symbols are available
    shared_lib.rdynamic = true;
    b.installArtifact(shared_lib);

    const shared_lib_step = b.step("shared", "Build shared library for FFI");
    shared_lib_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);

    // Also create a static library for Rust FFI
    const static_lib = b.addLibrary(.{
        .name = "guillotine_ffi_static",
        .linkage = .static,
        .root_module = shared_lib_mod,
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    static_lib.linkLibrary(c_kzg_lib);
    static_lib.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| static_lib.linkLibrary(bn254);
    static_lib.linkLibC();
    b.installArtifact(static_lib);

    const static_lib_step = b.step("static", "Build static library for FFI");
    static_lib_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);

    // Test configuration options
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by pattern (applies to all test types)");
    const test_verbose = b.option(bool, "test-verbose", "Enable verbose test output") orelse false;
    const test_fail_fast = b.option(bool, "test-fail-fast", "Stop on first test failure") orelse false;
    const test_no_color = b.option(bool, "test-no-color", "Disable colored output") orelse false;
    const test_quiet = b.option(bool, "test-quiet", "Minimal output (dots only)") orelse false;

    // Unit tests from src/root.zig (same as evm_mod, just run its tests)
    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = modules.evm_mod,
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    if (test_filter) |filter| {
        unit_tests.filters = &[_][]const u8{filter};
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // Pass test configuration as environment variables for the custom runner
    if (test_filter) |filter| {
        run_unit_tests.setEnvironmentVariable("TEST_FILTER", filter);
    }
    if (test_verbose) run_unit_tests.setEnvironmentVariable("TEST_VERBOSE", "1");
    if (test_fail_fast) run_unit_tests.setEnvironmentVariable("TEST_FAIL_FAST", "1");
    if (test_no_color) run_unit_tests.setEnvironmentVariable("TEST_NO_COLOR", "1");
    if (test_quiet) run_unit_tests.setEnvironmentVariable("TEST_QUIET", "1");
    const unit_test_step = b.step("test-unit", "Run unit tests from src/**/*.zig");
    unit_test_step.dependOn(&run_unit_tests.step);

    // Library tests from lib/root.zig
    const lib_tests = b.addTest(.{
        .name = "lib-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    if (foundry_lib) |foundry| {
        lib_tests.linkLibrary(foundry);
        lib_tests.addIncludePath(b.path("lib/foundry-compilers"));
    }
    lib_tests.linkLibrary(c_kzg_lib);
    lib_tests.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| lib_tests.linkLibrary(bn254);
    lib_tests.linkLibC();
    if (test_filter) |filter| {
        lib_tests.filters = &[_][]const u8{filter};
    }
    const run_lib_tests = b.addRunArtifact(lib_tests);
    // Pass test configuration as environment variables for the custom runner
    if (test_filter) |filter| {
        run_lib_tests.setEnvironmentVariable("TEST_FILTER", filter);
    }
    if (test_verbose) run_lib_tests.setEnvironmentVariable("TEST_VERBOSE", "1");
    if (test_fail_fast) run_lib_tests.setEnvironmentVariable("TEST_FAIL_FAST", "1");
    if (test_no_color) run_lib_tests.setEnvironmentVariable("TEST_NO_COLOR", "1");
    if (test_quiet) run_lib_tests.setEnvironmentVariable("TEST_QUIET", "1");
    const lib_test_step = b.step("test-lib", "Run library tests from lib/**/*.zig");
    lib_test_step.dependOn(&run_lib_tests.step);

    // Integration tests from test/root.zig
    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    integration_tests.root_module.addImport("evm", modules.evm_mod);
    integration_tests.root_module.addImport("primitives", modules.primitives_mod);
    integration_tests.root_module.addImport("crypto", modules.crypto_mod);
    integration_tests.root_module.addImport("compilers", modules.compilers_mod);
    integration_tests.root_module.addImport("provider", modules.provider_mod);
    integration_tests.root_module.addImport("trie", modules.trie_mod);
    integration_tests.root_module.addImport("Guillotine_lib", modules.lib_mod);
    integration_tests.linkLibrary(c_kzg_lib);
    integration_tests.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| integration_tests.linkLibrary(bn254);
    integration_tests.linkLibC();
    if (test_filter) |filter| {
        integration_tests.filters = &[_][]const u8{filter};
    }
    const run_integration_tests = b.addRunArtifact(integration_tests);
    // Pass test configuration as environment variables for the custom runner
    if (test_filter) |filter| {
        run_integration_tests.setEnvironmentVariable("TEST_FILTER", filter);
    }
    if (test_verbose) run_integration_tests.setEnvironmentVariable("TEST_VERBOSE", "1");
    if (test_fail_fast) run_integration_tests.setEnvironmentVariable("TEST_FAIL_FAST", "1");
    if (test_no_color) run_integration_tests.setEnvironmentVariable("TEST_NO_COLOR", "1");
    if (test_quiet) run_integration_tests.setEnvironmentVariable("TEST_QUIET", "1");
    const integration_test_step = b.step("test-integration", "Run integration tests from test/**/*.zig");
    integration_test_step.dependOn(&run_integration_tests.step);



    // Main test step runs tests in priority order: specs -> integration -> unit
    const test_step = b.step("test", "Run all tests (specs -> integration -> unit)");

    // BN254 benchmarks
    const zbench_module = zbench_dep.module("zbench");
    const zbench_bn254 = b.addExecutable(.{
        .name = "zbench-bn254",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/bn254/zbench_benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
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
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    zbench_evm.root_module.addImport("zbench", zbench_module);
    zbench_evm.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
    }));
    zbench_evm.root_module.addImport("evm", modules.evm_mod);
    zbench_evm.root_module.addImport("primitives", modules.primitives_mod);
    zbench_evm.root_module.addImport("crypto", modules.crypto_mod);
    zbench_evm.root_module.addImport("build_options", options_mod);
    zbench_evm.linkLibrary(c_kzg_lib);
    zbench_evm.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| zbench_evm.linkLibrary(bn254);
    zbench_evm.linkLibC();

    const run_zbench_evm = b.addRunArtifact(zbench_evm);
    const zbench_evm_step = b.step("bench-evm", "Run zbench EVM benchmarks");
    zbench_evm_step.dependOn(&run_zbench_evm.step);

    // ERC20 deployment gas issue test
    const erc20_gas_test = b.addTest(.{
        .name = "test-erc20-gas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/erc20_deployment_gas_issue.zig"),
            .target = target,
            .optimize = .Debug, // Debug for better logging
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    erc20_gas_test.root_module.addImport("evm", modules.evm_mod);
    erc20_gas_test.root_module.addImport("primitives", modules.primitives_mod);
    erc20_gas_test.root_module.addImport("crypto", modules.crypto_mod);
    erc20_gas_test.root_module.addImport("build_options", options_mod);
    erc20_gas_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
    erc20_gas_test.linkLibrary(c_kzg_lib);
    erc20_gas_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| erc20_gas_test.linkLibrary(bn254);
    erc20_gas_test.linkLibC();

    const run_erc20_gas_test = b.addRunArtifact(erc20_gas_test);
    const erc20_gas_test_step = b.step("test-erc20-gas", "Test ERC20 deployment gas issue");
    erc20_gas_test_step.dependOn(&run_erc20_gas_test.step);

    // Jump table issue test
    const jump_table_test = b.addTest(.{
        .name = "test-jump-table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/jump_table_issue.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    jump_table_test.root_module.addImport("evm", modules.evm_mod);
    jump_table_test.root_module.addImport("primitives", modules.primitives_mod);
    jump_table_test.root_module.addImport("crypto", modules.crypto_mod);
    jump_table_test.root_module.addImport("build_options", options_mod);
    jump_table_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
    jump_table_test.linkLibrary(c_kzg_lib);
    jump_table_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| jump_table_test.linkLibrary(bn254);
    jump_table_test.linkLibC();

    const run_jump_table_test = b.addRunArtifact(jump_table_test);
    const jump_table_test_step = b.step("test-jump-table", "Test jump table JUMPDEST recognition");
    jump_table_test_step.dependOn(&run_jump_table_test.step);

    // ERC20 deployment issue test
    const erc20_deployment_test = b.addTest(.{
        .name = "test-erc20-deployment",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/erc20_deployment_issue.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    erc20_deployment_test.root_module.addImport("evm", modules.evm_mod);
    erc20_deployment_test.root_module.addImport("primitives", modules.primitives_mod);
    erc20_deployment_test.root_module.addImport("crypto", modules.crypto_mod);
    erc20_deployment_test.root_module.addImport("build_options", options_mod);
    erc20_deployment_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));

    // Using MinimalEvm for differential testing (REVM removed)

    erc20_deployment_test.linkLibrary(c_kzg_lib);
    erc20_deployment_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| erc20_deployment_test.linkLibrary(bn254);
    erc20_deployment_test.linkLibC();

    const run_erc20_deployment_test = b.addRunArtifact(erc20_deployment_test);
    const erc20_deployment_test_step = b.step("test-erc20-deployment", "Test ERC20 deployment issue");
    erc20_deployment_test_step.dependOn(&run_erc20_deployment_test.step);

    // Fixtures comprehensive differential test
    const fixtures_differential_test = b.addTest(.{
        .name = "fixtures-differential-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential/fixtures_comprehensive_differential_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    fixtures_differential_test.root_module.addImport("evm", modules.evm_mod);
    fixtures_differential_test.root_module.addImport("primitives", modules.primitives_mod);
    fixtures_differential_test.root_module.addImport("crypto", modules.crypto_mod);
    fixtures_differential_test.root_module.addImport("build_options", options_mod);
    fixtures_differential_test.root_module.addImport("log", b.createModule(.{ 
        .root_source_file = b.path("src/log.zig"), 
        .target = target, 
        .optimize = .Debug, 
    }));

    // Using MinimalEvm for differential testing (REVM removed)

    fixtures_differential_test.linkLibrary(c_kzg_lib);
    fixtures_differential_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| fixtures_differential_test.linkLibrary(bn254);
    fixtures_differential_test.linkLibC();

    const run_fixtures_differential_test = b.addRunArtifact(fixtures_differential_test);
    const fixtures_differential_test_step = b.step("test-fixtures-differential", "Run differential tests for benchmark fixtures (ERC20, snailtracer, etc.)");
    fixtures_differential_test_step.dependOn(&run_fixtures_differential_test.step);

    // Snailtracer differential test
    const snailtracer_test = b.addTest(.{
        .name = "snailtracer-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/snailtracer_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    snailtracer_test.root_module.addImport("evm", modules.evm_mod);
    snailtracer_test.root_module.addImport("primitives", modules.primitives_mod);
    snailtracer_test.root_module.addImport("crypto", modules.crypto_mod);
    snailtracer_test.root_module.addImport("build_options", options_mod);
    snailtracer_test.root_module.addImport("log", b.createModule(.{ 
        .root_source_file = b.path("src/log.zig"), 
        .target = target, 
        .optimize = .Debug, 
    }));

    // Using MinimalEvm for differential testing (REVM removed)

    snailtracer_test.linkLibrary(c_kzg_lib);
    snailtracer_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| snailtracer_test.linkLibrary(bn254);
    snailtracer_test.linkLibC();

    const run_snailtracer_test = b.addRunArtifact(snailtracer_test);
    const snailtracer_test_step = b.step("test-snailtracer", "Run snailtracer differential test");
    snailtracer_test_step.dependOn(&run_snailtracer_test.step);

    // GT opcode bug test
    const gt_bug_test = b.addTest(.{
        .name = "gt-bug-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_gt_exact.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    gt_bug_test.root_module.addImport("evm", modules.evm_mod);
    gt_bug_test.root_module.addImport("primitives", modules.primitives_mod);
    gt_bug_test.root_module.addImport("crypto", modules.crypto_mod);
    gt_bug_test.root_module.addImport("build_options", options_mod);
    gt_bug_test.root_module.addImport("log", b.createModule(.{ 
        .root_source_file = b.path("src/log.zig"), 
        .target = target, 
        .optimize = .Debug, 
    }));
    gt_bug_test.linkLibrary(c_kzg_lib);
    gt_bug_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| gt_bug_test.linkLibrary(bn254);
    gt_bug_test.linkLibC();
    const test_gt_bug = b.step("test-gt-bug", "Test GT opcode bug");
    test_gt_bug.dependOn(&b.addRunArtifact(gt_bug_test).step);

    // Development test for quick debugging
    const dev_test = b.addTest(.{
        .name = "dev-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/dev_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    dev_test.root_module.addImport("evm", modules.evm_mod);
    dev_test.root_module.addImport("primitives", modules.primitives_mod);
    dev_test.root_module.addImport("crypto", modules.crypto_mod);
    dev_test.root_module.addImport("build_options", options_mod);
    dev_test.linkLibrary(c_kzg_lib);
    dev_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| dev_test.linkLibrary(bn254);
    dev_test.linkLibC();
    const test_dev = b.step("test-dev", "Run development test for debugging");
    test_dev.dependOn(&b.addRunArtifact(dev_test).step);

    // Per-opcode differential tests discovered in test/evm/opcodes
    // We dynamically scan the directory and add a test target for each file matching *_test.zig
    const opcode_tests_step = b.step("test-opcodes", "Run all per-opcode differential tests");
    if (std.fs.cwd().openDir("test/evm/opcodes", .{ .iterate = true }) catch null) |op_dir_val| {
        var op_dir = op_dir_val; // make mutable for close()
        defer op_dir.close();
        var it = op_dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, "_test.zig")) continue;

            const file_path = b.fmt("test/evm/opcodes/{s}", .{entry.name});
            const test_name = b.fmt("opcode-{s}", .{entry.name});

            // Extract opcode hex from filename (e.g., "01_test.zig" -> "0x01")
            const opcode_hex = entry.name[0 .. std.mem.indexOf(u8, entry.name, "_") orelse continue];
            const individual_step_name = b.fmt("test-opcodes-0x{s}", .{opcode_hex});
            const individual_step_desc = b.fmt("Test opcode 0x{s}", .{opcode_hex});

            const t = b.addTest(.{
                .name = test_name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(file_path),
                    .target = target,
                    .optimize = .Debug,
                }),
                // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
                .use_llvm = true,
            });
            // Apply test filter if specified
            if (test_filter) |filter| {
                t.filters = &[_][]const u8{filter};
            }
            // Inject module dependencies used by the differential harness
            t.root_module.addImport("evm", modules.evm_mod);
            t.root_module.addImport("primitives", modules.primitives_mod);
            t.root_module.addImport("crypto", modules.crypto_mod);
            t.root_module.addImport("build_options", options_mod);
            t.root_module.addImport("log", b.createModule(.{
                .root_source_file = b.path("src/log.zig"),
                .target = target,
                .optimize = .Debug,
            }));

            // Link external libs
            t.linkLibrary(c_kzg_lib);
            t.linkLibrary(blst_lib);
            if (bn254_lib) |bn254| t.linkLibrary(bn254);
            t.linkLibC();

            // Using MinimalEvm for differential testing (REVM removed)

            const run_t = b.addRunArtifact(t);

            // Add to the "all opcodes" step
            opcode_tests_step.dependOn(&run_t.step);

            // Create individual test step for this opcode
            const individual_step = b.step(individual_step_name, individual_step_desc);
            individual_step.dependOn(&run_t.step);
        }
    }

    // ERC20 mint differential test
    {
        const erc20_mint_test = b.addTest(.{
            .name = "erc20_mint_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/erc20_mint_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        // Add all the required dependencies
        erc20_mint_test.root_module.addImport("evm", modules.evm_mod);
        erc20_mint_test.root_module.addImport("primitives", modules.primitives_mod);
        erc20_mint_test.root_module.addImport("crypto", modules.crypto_mod);

        // Using MinimalEvm for differential testing (REVM removed)

        // Link other required libraries
        erc20_mint_test.linkLibrary(c_kzg_lib);
        erc20_mint_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| erc20_mint_test.linkLibrary(bn254);
        erc20_mint_test.linkLibC();

        const run_erc20_mint_test = b.addRunArtifact(erc20_mint_test);

        const erc20_mint_step = b.step("test-erc20-mint", "Run ERC20 mint differential test");
        erc20_mint_step.dependOn(&run_erc20_mint_test.step);
    }

    // ERC20 transfer test
    {
        const erc20_transfer_test = b.addTest(.{
            .name = "erc20_transfer_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/erc20_transfer_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        erc20_transfer_test.root_module.addImport("evm", modules.evm_mod);
        erc20_transfer_test.root_module.addImport("primitives", modules.primitives_mod);
        erc20_transfer_test.root_module.addImport("crypto", modules.crypto_mod);
        erc20_transfer_test.root_module.addImport("build_options", options_mod);

        // Link required libraries
        erc20_transfer_test.linkLibrary(c_kzg_lib);
        erc20_transfer_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| erc20_transfer_test.linkLibrary(bn254);
        erc20_transfer_test.linkLibC();

        const run_erc20_transfer_test = b.addRunArtifact(erc20_transfer_test);
        const erc20_transfer_step = b.step("test-erc20-transfer", "Run ERC20 transfer test");
        erc20_transfer_step.dependOn(&run_erc20_transfer_test.step);
    }

    // Static jumps test - temporarily disabled as file was removed
    // TODO: Re-enable when test/evm/static_jumps.zig is restored
    // {
    //     const static_jumps_test = b.addTest(.{
    //         .name = "static_jumps_test",
    //         .root_module = b.createModule(.{
    //             .root_source_file = b.path("test/evm/static_jumps.zig"),
    //             .target = target,
    //             .optimize = optimize,
    //         }),
    //     });
    //
    //     static_jumps_test.root_module.addImport("evm", modules.evm_mod);
    //     static_jumps_test.root_module.addImport("primitives", modules.primitives_mod);
    //     static_jumps_test.root_module.addImport("crypto", modules.crypto_mod);
    //     static_jumps_test.root_module.addImport("build_options", options_mod);
    //
    //     // Link required libraries
    //     static_jumps_test.linkLibrary(c_kzg_lib);
    //     static_jumps_test.linkLibrary(blst_lib);
    //     if (bn254_lib) |bn254| static_jumps_test.linkLibrary(bn254);
    //     static_jumps_test.linkLibC();
    //
    //     const run_static_jumps_test = b.addRunArtifact(static_jumps_test);
    //     const static_jumps_step = b.step("test-static-jumps", "Run static jumps test");
    //     static_jumps_step.dependOn(&run_static_jumps_test.step);
    //
    //     // Add to main test step
    //     test_step.dependOn(&run_static_jumps_test.step);
    // }

    // CODECOPY+RETURN test
    {
        const codecopy_test = b.addTest(.{
            .name = "codecopy_return_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/codecopy_return_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        codecopy_test.root_module.addImport("evm", modules.evm_mod);
        codecopy_test.root_module.addImport("primitives", modules.primitives_mod);
        codecopy_test.root_module.addImport("crypto", modules.crypto_mod);
        codecopy_test.root_module.addImport("build_options", options_mod);

        const run_codecopy_test = b.addRunArtifact(codecopy_test);
        const codecopy_step = b.step("test-codecopy-return", "Test CODECOPY and RETURN opcodes");
        codecopy_step.dependOn(&run_codecopy_test.step);
    }

    // Official execution-spec state fixture smoke test
    {
        const official_state_test = b.addTest(.{
            .name = "official_state_fixtures_smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/official/state_smoke_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        // Add required imports
        official_state_test.root_module.addImport("evm", modules.evm_mod);
        official_state_test.root_module.addImport("primitives", modules.primitives_mod);
        official_state_test.root_module.addImport("crypto", modules.crypto_mod);
        official_state_test.root_module.addImport("build_options", options_mod);

        // Link libraries used by EVM
        official_state_test.linkLibrary(c_kzg_lib);
        official_state_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| official_state_test.linkLibrary(bn254);
        official_state_test.linkLibC();

        const run_official_state_test = b.addRunArtifact(official_state_test);
        // Non-strict by default to avoid failing on WIP EVM differences
        run_official_state_test.setEnvironmentVariable("OFFICIAL_STRICT", "0");
        const official_state_step = b.step("test-official", "Run execution-spec state fixture smoke test (non-strict)");
        official_state_step.dependOn(&run_official_state_test.step);

        // Strict mode (will compare post-state and likely fail until parity improves)
        const run_official_state_test_strict = b.addRunArtifact(official_state_test);
        run_official_state_test_strict.setEnvironmentVariable("OFFICIAL_STRICT", "1");
        const official_state_strict_step = b.step("test-official-strict", "Run execution-spec state fixture smoke test (strict)");
        official_state_strict_step.dependOn(&run_official_state_test_strict.step);
    }

    // Official execution-spec blockchain fixture smoke test
    {
        const official_chain_test = b.addTest(.{
            .name = "official_blockchain_fixtures_smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/official/blockchain_smoke_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        official_chain_test.root_module.addImport("evm", modules.evm_mod);
        official_chain_test.root_module.addImport("primitives", modules.primitives_mod);
        official_chain_test.root_module.addImport("crypto", modules.crypto_mod);
        official_chain_test.root_module.addImport("build_options", options_mod);

        official_chain_test.linkLibrary(c_kzg_lib);
        official_chain_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| official_chain_test.linkLibrary(bn254);
        official_chain_test.linkLibC();

        const run_official_chain_test = b.addRunArtifact(official_chain_test);
        run_official_chain_test.setEnvironmentVariable("OFFICIAL_STRICT", "0");
        const official_chain_step = b.step("test-official-blockchain", "Run execution-spec blockchain fixture smoke test (non-strict)");
        official_chain_step.dependOn(&run_official_chain_test.step);

        const run_official_chain_test_strict = b.addRunArtifact(official_chain_test);
        run_official_chain_test_strict.setEnvironmentVariable("OFFICIAL_STRICT", "1");
        const official_chain_strict_step = b.step("test-official-blockchain-strict", "Run execution-spec blockchain fixture smoke test (strict)");
        official_chain_strict_step.dependOn(&run_official_chain_test_strict.step);
    }

    // Synthetic opcodes tests
    {
        const synthetic_test = b.addTest(.{
            .name = "synthetic_opcodes_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm/test_synthetic_opcodes.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        // Add module imports needed by the test
        synthetic_test.root_module.addImport("primitives", modules.primitives_mod);
        synthetic_test.root_module.addImport("crypto", modules.crypto_mod);
        synthetic_test.root_module.addImport("build_options", options_mod);

        synthetic_test.linkLibrary(c_kzg_lib);
        synthetic_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| synthetic_test.linkLibrary(bn254);
        synthetic_test.linkLibC();

        const run_synthetic_test = b.addRunArtifact(synthetic_test);
        const synthetic_step = b.step("test-synthetic", "Test synthetic opcodes");
        synthetic_step.dependOn(&run_synthetic_test.step);
    }

    // Zig specs runner (new default)
    const specs_test = b.addTest(.{
        .name = "ethereum-specs-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("specs/cases/root.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    specs_test.root_module.addImport("evm", modules.evm_mod);
    specs_test.root_module.addImport("primitives", modules.primitives_mod);
    specs_test.root_module.addImport("crypto", modules.crypto_mod);
    specs_test.root_module.addImport("build_options", options_mod);
    specs_test.root_module.addImport("runner", b.createModule(.{
        .root_source_file = b.path("specs/runner.zig"),
        .imports = &.{
            .{ .name = "evm", .module = modules.evm_mod },
            .{ .name = "primitives", .module = modules.primitives_mod },
        },
    }));
    specs_test.linkLibrary(c_kzg_lib);
    specs_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| specs_test.linkLibrary(bn254);
    specs_test.linkLibC();
    
    // Apply test filter if specified
    if (test_filter) |filter| {
        specs_test.filters = &[_][]const u8{filter};
    }
    
    const run_specs_test = b.addRunArtifact(specs_test);
    
    // Pass test configuration as environment variables for the custom runner
    if (test_filter) |filter| {
        run_specs_test.setEnvironmentVariable("TEST_FILTER", filter);
    }
    if (test_verbose) run_specs_test.setEnvironmentVariable("TEST_VERBOSE", "1");
    if (test_fail_fast) run_specs_test.setEnvironmentVariable("TEST_FAIL_FAST", "1");
    if (test_no_color) run_specs_test.setEnvironmentVariable("TEST_NO_COLOR", "1");
    if (test_quiet) run_specs_test.setEnvironmentVariable("TEST_QUIET", "1");
    
    // Set MAX_SPEC_FILES environment variable
    const spec_max_files = b.option([]const u8, "spec-max-files", "Maximum number of spec files to run (default: all)");
    if (spec_max_files) |max_files| {
        run_specs_test.setEnvironmentVariable("MAX_SPEC_FILES", max_files);
    } else {
        run_specs_test.setEnvironmentVariable("MAX_SPEC_FILES", "999999"); // Run all test files
    }
    
    // Set SKIP_SPEC_FILES environment variable to skip the first N files
    const spec_skip_files = b.option([]const u8, "spec-skip-files", "Number of spec files to skip from the beginning");
    if (spec_skip_files) |skip_files| {
        run_specs_test.setEnvironmentVariable("SKIP_SPEC_FILES", skip_files);
    }
    
    const specs_step = b.step("specs", "Run Ethereum execution spec tests (Zig version) - use -Dspec-max-files=N to limit, -Dtest-filter=pattern to filter");
    specs_step.dependOn(&run_specs_test.step);
    
    // Bun specs runner (kept as alternative)
    const bun_check = b.addSystemCommand(&[_][]const u8{ "which", "bun" });
    bun_check.addCheck(.{ .expect_stdout_match = "bun" });

    const run_specs_bun = b.addSystemCommand(&[_][]const u8{ "bun", "test", "ethereum-specs.test.ts" });
    run_specs_bun.setCwd(b.path("specs/bun-runner"));
    run_specs_bun.step.dependOn(&bun_check.step);

    // Set MAX_SPEC_FILES to run all tests by default for Bun version
    if (spec_max_files) |max_files| {
        run_specs_bun.setEnvironmentVariable("MAX_SPEC_FILES", max_files);
    } else {
        run_specs_bun.setEnvironmentVariable("MAX_SPEC_FILES", "999999"); // Run all test files
    }

    // Pass test filter to bun tests if specified
    if (test_filter) |filter| {
        run_specs_bun.setEnvironmentVariable("TEST_FILTER", filter);
    }

    const specs_bun_step = b.step("specs-bun", "Run Ethereum execution spec tests (Bun/TypeScript version) - use -Dspec-max-files=N to limit, -Dtest-filter=pattern to filter");
    specs_bun_step.dependOn(&run_specs_bun.step);

    // Language bindings
    // Language bindings - TODO: Re-enable when SDK build files are created
    // _ = WasmBindings.createWasmSteps(b, optimize, options_mod);
    // _ = PythonBindings.createPythonSteps(b);
    // _ = SwiftBindings.createSwiftSteps(b);
    // _ = GoBindings.createGoSteps(b);
    // _ = TypeScriptBindings.createTypeScriptSteps(b);

    // Focused fusion tests aggregator
    {
        // Basic fusion detection and execution tests
        const fusions_basic = b.addTest(.{
            .name = "fusions_basic",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/fusions.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });
        fusions_basic.root_module.addImport("evm", modules.evm_mod);
        fusions_basic.root_module.addImport("primitives", modules.primitives_mod);
        fusions_basic.root_module.addImport("crypto", modules.crypto_mod);
        fusions_basic.root_module.addImport("build_options", options_mod);
        fusions_basic.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
        fusions_basic.linkLibrary(c_kzg_lib);
        fusions_basic.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| fusions_basic.linkLibrary(bn254);
        fusions_basic.linkLibC();

        // Dispatch-specific fusion tests (jump resolution, etc.)
        const fusions_dispatch = b.addTest(.{
            .name = "fusions_dispatch",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/fusions_dispatch.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });
        fusions_dispatch.root_module.addImport("evm", modules.evm_mod);
        fusions_dispatch.root_module.addImport("primitives", modules.primitives_mod);
        fusions_dispatch.root_module.addImport("crypto", modules.crypto_mod);
        fusions_dispatch.root_module.addImport("build_options", options_mod);
        fusions_dispatch.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
        fusions_dispatch.linkLibrary(c_kzg_lib);
        fusions_dispatch.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| fusions_dispatch.linkLibrary(bn254);
        fusions_dispatch.linkLibC();

        // Differential harness: non-fuseable pattern sanity check
        const fusions_diff_toggle = b.addTest(.{
            .name = "fusions_diff_toggle",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/differential/synthetic_toggle_test.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });
        fusions_diff_toggle.root_module.addImport("evm", modules.evm_mod);
        fusions_diff_toggle.root_module.addImport("primitives", modules.primitives_mod);
        fusions_diff_toggle.root_module.addImport("crypto", modules.crypto_mod);
        fusions_diff_toggle.root_module.addImport("build_options", options_mod);
        fusions_diff_toggle.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
        // Using MinimalEvm for differential testing (REVM removed)
        fusions_diff_toggle.linkLibrary(c_kzg_lib);
        fusions_diff_toggle.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| fusions_diff_toggle.linkLibrary(bn254);
        fusions_diff_toggle.linkLibC();

        const run_fusions_basic = b.addRunArtifact(fusions_basic);
        const run_fusions_dispatch = b.addRunArtifact(fusions_dispatch);
        const run_fusions_diff_toggle = b.addRunArtifact(fusions_diff_toggle);

        const test_fusions_step = b.step("test-fusions", "Run focused fusion tests (unit + dispatch + differential)");
        test_fusions_step.dependOn(&run_fusions_basic.step);
        test_fusions_step.dependOn(&run_fusions_dispatch.step);
        test_fusions_step.dependOn(&run_fusions_diff_toggle.step);
    }

    // Configure main test step dependencies in priority order:
    // 1. First: Run specs tests (Ethereum compliance)
    test_step.dependOn(specs_step);

    // 2. Second: Run integration tests (test/**/*.zig)
    test_step.dependOn(&run_integration_tests.step);

    // 3. Third: Run unit tests (src/**/*.zig)
    test_step.dependOn(&run_unit_tests.step);

    // 4. Fourth: Run library tests (lib/**/*.zig)
    test_step.dependOn(&run_lib_tests.step);
}
