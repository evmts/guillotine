const std = @import("std");
const Modules = @import("src/modules.build.zig");
const GuillotineExe = @import("src/build.zig");
const lib_build = @import("lib/build.zig");
// DevtoolExe removed - apps/ not included in package distribution

pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Download KZG trusted setup if it doesn't exist
    const kzg_path = "src/kzg/trusted_setup.txt";
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
    build_options.addOption(bool, "disable_tailcall_dispatch", b.option(bool, "disable-tailcall-dispatch", "Disable tailcall-based dispatch") orelse false);
    build_options.addOption([]const u8, "hardfork", b.option([]const u8, "evm-hardfork", "EVM hardfork (default: OSAKA)") orelse "OSAKA");
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
    const primitives_dep = b.dependency("voltaire", .{ .target = target, .optimize = optimize });

    // Use Rust build step for Guillotine-specific libraries
    const rust_build_step = lib_build.FoundryLib.createRustBuildStep(b, rust_target, optimize);
    const bn254_lib = lib_build.Bn254Lib.createBn254Library(b, target, optimize, .{ .enable_tracy = false }, rust_build_step, rust_target);
    const foundry_lib = lib_build.FoundryLib.createFoundryLibrary(b, target, optimize, rust_build_step, rust_target);

    // Install Guillotine-specific libraries
    if (bn254_lib) |bn254| b.installArtifact(bn254);

    // Modules (zbench no longer needed for core evm_mod)
    const modules = Modules.createModules(b, target, optimize, options_mod, primitives_dep, bn254_lib, foundry_lib);

    // Importing an external module's functions does not run its inline tests.
    // Keep the synchronized ModExp implementation's arithmetic and precompile
    // regressions reachable from this repository's validation surface.
    const modexp_tests_step = b.step("test-modexp", "Run vendored ModExp arithmetic and precompile tests");
    for ([_][]const u8{ "crypto", "precompiles" }) |area| {
        const is_crypto = std.mem.eql(u8, area, "crypto");
        const modexp_test = b.addTest(.{
            .name = b.fmt("modexp-{s}", .{area}),
            .root_module = if (is_crypto) modules.crypto_mod else b.createModule(.{
                .root_source_file = b.path(b.fmt("lib/voltaire/src/{s}/modexp.zig", .{area})),
                .target = target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        if (!is_crypto) {
            modexp_test.root_module.addImport("voltaire", modules.primitives_mod);
            modexp_test.root_module.addImport("crypto", modules.crypto_mod);
        }
        modexp_test.linkLibC();
        modexp_tests_step.dependOn(&b.addRunArtifact(modexp_test).step);
    }

    // ECRECOVER precompile regressions (empty output on failure, strict v, high s allowed).
    const ecrecover_tests_step = b.step("test-ecrecover", "Run vendored ECRECOVER precompile tests");
    {
        const ecrecover_test = b.addTest(.{
            .name = "ecrecover",
            .root_module = b.createModule(.{
                .root_source_file = b.path("lib/voltaire/src/precompiles/ecrecover.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        ecrecover_test.root_module.addImport("crypto", modules.crypto_mod);
        ecrecover_test.linkLibC();
        ecrecover_tests_step.dependOn(&b.addRunArtifact(ecrecover_test).step);
    }

    const bn254_tests_step = b.step("test-bn254", "Run vendored BN254 add, mul, and field tests");
    for ([_][]const u8{
        "precompiles/bn254_add.zig",
        "precompiles/bn254_mul.zig",
        "crypto/bn254/curve_parameters.zig",
        "crypto/bn254/Fp12Mont.zig",
    }) |path| {
        const precompile = std.mem.startsWith(u8, path, "precompiles/");
        const name = std.fs.path.stem(path);
        const bn254_test = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("lib/voltaire/src/{s}", .{path})),
                .target = target,
                .optimize = optimize,
            }),
            .filters = if (precompile) &.{} else if (std.mem.eql(u8, name, "Fp12Mont")) &.{"Fp12Mont"} else &.{"curve parameters"},
            .use_llvm = true,
        });
        if (precompile) {
            bn254_test.root_module.addImport("crypto", modules.crypto_mod);
            bn254_test.linkLibC();
        }
        bn254_tests_step.dependOn(&b.addRunArtifact(bn254_test).step);
    }

    // Executables
    const guillotine_exe = GuillotineExe.createExecutable(b, modules.exe_mod);
    _ = GuillotineExe.createRunStep(b, guillotine_exe);

    // Bench runner executables are removed (moved to separate repo)


    // Shared library for FFI bindings
    const shared_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/evm_c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_lib_mod.addImport("evm", modules.evm_mod);
    shared_lib_mod.addImport("voltaire", modules.primitives_mod);
    shared_lib_mod.addImport("crypto", modules.crypto_mod);
    shared_lib_mod.addImport("build_options", options_mod);

    const shared_lib = b.addLibrary(.{
        .name = "guillotine_ffi",
        .linkage = .dynamic,
        .root_module = shared_lib_mod,
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    if (bn254_lib) |bn254| shared_lib.linkLibrary(bn254);
    shared_lib.linkLibC();
    if (target.result.os.tag == .linux) shared_lib.linkSystemLibrary("unwind");
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
    if (bn254_lib) |bn254| static_lib.linkLibrary(bn254);
    static_lib.linkLibC();
    if (target.result.os.tag == .linux) static_lib.linkSystemLibrary("unwind");
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
        // Temporarily disable custom test runner to debug
        // .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
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
    integration_tests.root_module.addImport("voltaire", modules.primitives_mod);
    integration_tests.root_module.addImport("crypto", modules.crypto_mod);
    integration_tests.root_module.addImport("compilers", modules.compilers_mod);
    integration_tests.root_module.addImport("provider", modules.provider_mod);
    integration_tests.root_module.addImport("trie", modules.trie_mod);
    integration_tests.root_module.addImport("Guillotine_lib", modules.lib_mod);
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

    // Fixture tests - test all Solidity fixtures with both EVMs
    const fixture_tests = b.addTest(.{
        .name = "fixture-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    fixture_tests.root_module.addImport("evm", modules.evm_mod);
    fixture_tests.root_module.addImport("voltaire", modules.primitives_mod);
    if (bn254_lib) |bn254| fixture_tests.linkLibrary(bn254);
    if (foundry_lib) |foundry| {
        fixture_tests.linkLibrary(foundry);
        fixture_tests.addIncludePath(b.path("lib/foundry-compilers"));
    }
    fixture_tests.linkLibC();
    if (test_filter) |filter| {
        fixture_tests.filters = &[_][]const u8{filter};
    }
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    if (test_filter) |filter| {
        run_fixture_tests.setEnvironmentVariable("TEST_FILTER", filter);
    }
    if (test_verbose) run_fixture_tests.setEnvironmentVariable("TEST_VERBOSE", "1");
    if (test_fail_fast) run_fixture_tests.setEnvironmentVariable("TEST_FAIL_FAST", "1");
    if (test_no_color) run_fixture_tests.setEnvironmentVariable("TEST_NO_COLOR", "1");
    if (test_quiet) run_fixture_tests.setEnvironmentVariable("TEST_QUIET", "1");
    const fixture_test_step = b.step("test-fixtures", "Run fixture tests comparing MainEvm and MinimalEvm");
    fixture_test_step.dependOn(&run_fixture_tests.step);

    // Main test step runs tests in priority order: specs -> integration -> unit
    const test_step = b.step("test", "Run all tests (specs -> integration -> unit)");

    // Mini EVM unit tests (guillotine-mini)
    const mini_test_cmd = b.addSystemCommand(&.{ "zig", "build", "unit" });
    mini_test_cmd.setCwd(b.path("mini"));
    const mini_test_step = b.step("test-mini", "Run guillotine-mini unit tests");
    mini_test_step.dependOn(&mini_test_cmd.step);

    // Mini EVM full tests (requires Python dependencies for spec tests)
    const mini_full_test_cmd = b.addSystemCommand(&.{ "zig", "build", "test" });
    mini_full_test_cmd.setCwd(b.path("mini"));
    const mini_full_test_step = b.step("test-mini-full", "Run all guillotine-mini tests (requires Python)");
    mini_full_test_step.dependOn(&mini_full_test_cmd.step);

    // Mini EVM specs tests
    const mini_specs_cmd = b.addSystemCommand(&.{ "zig", "build", "specs" });
    mini_specs_cmd.setCwd(b.path("mini"));
    const mini_specs_step = b.step("test-mini-specs", "Run guillotine-mini spec tests");
    mini_specs_step.dependOn(&mini_specs_cmd.step);

    // Mini EVM fuzz tests (uses current zig executable so custom zig paths work)
    const mini_fuzz_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test-fuzz" });
    mini_fuzz_cmd.setCwd(b.path("mini"));
    const mini_fuzz_step = b.step("test-mini-fuzz", "Run guillotine-mini fuzz tests");
    mini_fuzz_step.dependOn(&mini_fuzz_cmd.step);

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
    erc20_gas_test.root_module.addImport("voltaire", modules.primitives_mod);
    erc20_gas_test.root_module.addImport("crypto", modules.crypto_mod);
    erc20_gas_test.root_module.addImport("build_options", options_mod);
    erc20_gas_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
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
    jump_table_test.root_module.addImport("voltaire", modules.primitives_mod);
    jump_table_test.root_module.addImport("crypto", modules.crypto_mod);
    jump_table_test.root_module.addImport("build_options", options_mod);
    jump_table_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
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
    erc20_deployment_test.root_module.addImport("voltaire", modules.primitives_mod);
    erc20_deployment_test.root_module.addImport("crypto", modules.crypto_mod);
    erc20_deployment_test.root_module.addImport("build_options", options_mod);
    erc20_deployment_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));

    // Using MinimalEvm for differential testing (REVM removed)

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
    fixtures_differential_test.root_module.addImport("voltaire", modules.primitives_mod);
    fixtures_differential_test.root_module.addImport("crypto", modules.crypto_mod);
    fixtures_differential_test.root_module.addImport("build_options", options_mod);
    fixtures_differential_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));

    // Using MinimalEvm for differential testing (REVM removed)

    if (bn254_lib) |bn254| fixtures_differential_test.linkLibrary(bn254);
    fixtures_differential_test.linkLibC();

    const run_fixtures_differential_test = b.addRunArtifact(fixtures_differential_test);
    const fixtures_differential_test_step = b.step("test-fixtures-differential", "Run differential tests for benchmark fixtures (ERC20, etc.)");
    fixtures_differential_test_step.dependOn(&run_fixtures_differential_test.step);

    // GT opcode bug test
    const gt_bug_test = b.addTest(.{
        .name = "gt-bug-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/opcodes/11_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
        .use_llvm = true,
    });
    gt_bug_test.root_module.addImport("evm", modules.evm_mod);
    gt_bug_test.root_module.addImport("voltaire", modules.primitives_mod);
    gt_bug_test.root_module.addImport("crypto", modules.crypto_mod);
    gt_bug_test.root_module.addImport("build_options", options_mod);
    gt_bug_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
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
    dev_test.root_module.addImport("voltaire", modules.primitives_mod);
    dev_test.root_module.addImport("crypto", modules.crypto_mod);
    dev_test.root_module.addImport("build_options", options_mod);
    if (bn254_lib) |bn254| dev_test.linkLibrary(bn254);
    dev_test.linkLibC();
    const test_dev = b.step("test-dev", "Run development test for debugging");
    test_dev.dependOn(&b.addRunArtifact(dev_test).step);

    // Per-opcode differential tests discovered in test/evm/opcodes
    // We dynamically scan the directory and add a test target for each file matching *_test.zig
    const opcode_tests_step = b.step("test-opcodes", "Run all per-opcode differential tests");
    opcode_tests_step.dependOn(modexp_tests_step);
    opcode_tests_step.dependOn(ecrecover_tests_step);
    // Compile the engine once for the complete gate. Linking a separate copy
    // for every opcode consumes gigabytes of cache and repeats LLVM work.
    const all_opcode_tests = b.addTest(.{
        .name = "all-opcodes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/opcodes/all_opcodes.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    if (test_filter) |filter| all_opcode_tests.filters = &.{filter};
    all_opcode_tests.root_module.addImport("evm", modules.evm_mod);
    all_opcode_tests.root_module.addImport("voltaire", modules.primitives_mod);
    all_opcode_tests.root_module.addImport("crypto", modules.crypto_mod);
    all_opcode_tests.root_module.addImport("build_options", options_mod);
    all_opcode_tests.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
    if (bn254_lib) |bn254| all_opcode_tests.linkLibrary(bn254);
    all_opcode_tests.linkLibC();
    if (target.result.os.tag == .linux) all_opcode_tests.linkSystemLibrary("unwind");
    opcode_tests_step.dependOn(&b.addRunArtifact(all_opcode_tests).step);
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
            t.root_module.addImport("voltaire", modules.primitives_mod);
            t.root_module.addImport("crypto", modules.crypto_mod);
            t.root_module.addImport("build_options", options_mod);
            t.root_module.addImport("log", b.createModule(.{
                .root_source_file = b.path("src/log.zig"),
                .target = target,
                .optimize = .Debug,
            }));

            // Link external libs
            if (bn254_lib) |bn254| t.linkLibrary(bn254);
            t.linkLibC();

            // Using MinimalEvm for differential testing (REVM removed)

            const run_t = b.addRunArtifact(t);

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
        erc20_mint_test.root_module.addImport("voltaire", modules.primitives_mod);
        erc20_mint_test.root_module.addImport("crypto", modules.crypto_mod);

        // Using MinimalEvm for differential testing (REVM removed)

        // Link other required libraries
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
        erc20_transfer_test.root_module.addImport("voltaire", modules.primitives_mod);
        erc20_transfer_test.root_module.addImport("crypto", modules.crypto_mod);
        erc20_transfer_test.root_module.addImport("build_options", options_mod);

        // Link required libraries
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
    //     static_jumps_test.root_module.addImport("voltaire", modules.primitives_mod);
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
        codecopy_test.root_module.addImport("voltaire", modules.primitives_mod);
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
        official_state_test.root_module.addImport("voltaire", modules.primitives_mod);
        official_state_test.root_module.addImport("crypto", modules.crypto_mod);
        official_state_test.root_module.addImport("build_options", options_mod);

        // Link libraries used by EVM
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
        official_chain_test.root_module.addImport("voltaire", modules.primitives_mod);
        official_chain_test.root_module.addImport("crypto", modules.crypto_mod);
        official_chain_test.root_module.addImport("build_options", options_mod);

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
                .root_source_file = b.path("test/test_synthetic_opcodes.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });

        // Add module imports needed by the test
        synthetic_test.root_module.addImport("evm", modules.evm_mod);

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
    specs_test.root_module.addImport("voltaire", modules.primitives_mod);
    specs_test.root_module.addImport("crypto", modules.crypto_mod);
    specs_test.root_module.addImport("build_options", options_mod);
    const runner_module = b.createModule(.{
        .root_source_file = b.path("specs/runner.zig"),
    });
    runner_module.addImport("evm", modules.evm_mod);
    runner_module.addImport("voltaire", modules.primitives_mod);
    specs_test.root_module.addImport("runner", runner_module);
    if (bn254_lib) |bn254| specs_test.linkLibrary(bn254);
    specs_test.linkLibC();

    // Spec runner self-tests (expectation index selection). Generated case roots do
    // not reach tests inside the runner module, so they run as part of test-opcodes.
    const runner_unit = b.addTest(.{
        .name = "spec-runner-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("specs/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"expect indexes"},
    });
    runner_unit.root_module.addImport("evm", modules.evm_mod);
    runner_unit.root_module.addImport("voltaire", modules.primitives_mod);
    if (bn254_lib) |bn254| runner_unit.linkLibrary(bn254);
    runner_unit.linkLibC();
    opcode_tests_step.dependOn(&b.addRunArtifact(runner_unit).step);
    const lll_unit = b.addTest(.{
        .name = "spec-lll-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("specs/lll.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    opcode_tests_step.dependOn(&b.addRunArtifact(lll_unit).step);
    const assembler_unit = b.addTest(.{
        .name = "spec-assembler-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("specs/assembler.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"placeholders"},
    });
    opcode_tests_step.dependOn(&b.addRunArtifact(assembler_unit).step);

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

    // Official pre-filled EEST state tests runner (Frontier through Osaka)
    const eest_mod = b.createModule(.{
        .root_source_file = b.path("specs/eest_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    eest_mod.addImport("evm", modules.evm_mod);
    eest_mod.addImport("crypto", modules.crypto_mod);
    const eest_exe = b.addExecutable(.{
        .name = "eest-runner",
        .root_module = eest_mod,
        .use_llvm = true,
    });
    if (bn254_lib) |bn254| eest_exe.linkLibrary(bn254);
    eest_exe.linkLibC();
    if (target.result.os.tag == .linux) eest_exe.linkSystemLibrary("unwind");

    const run_state_tests = b.addRunArtifact(eest_exe);
    if (b.option([]const u8, "spec-fork", "EEST fork(s) to run (comma-separated)")) |fork| {
        run_state_tests.addArg(b.fmt("--fork={s}", .{fork}));
    }
    if (test_filter) |filter| {
        run_state_tests.addArg(b.fmt("--filter={s}", .{filter}));
    }
    if (b.option([]const u8, "spec-report", "Path to write EEST JSON summary report")) |report_path| {
        run_state_tests.addArg(b.fmt("--report={s}", .{report_path}));
    }
    if (test_verbose) run_state_tests.addArg("--verbose");
    if (b.args) |args| run_state_tests.addArgs(args);

    const state_tests_step = b.step("state-tests", "Run official pre-filled EEST state tests (Frontier through Osaka)");
    state_tests_step.dependOn(&run_state_tests.step);

    // Layer 2 (Base + OP Stack) unit tests
    const layer2_tests = b.addTest(.{
        .name = "layer2-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/layer2/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    layer2_tests.root_module.addImport("voltaire", modules.primitives_mod);
    layer2_tests.root_module.addImport("crypto", modules.crypto_mod);
    layer2_tests.root_module.addImport("precompiles", modules.precompiles_mod);
    if (bn254_lib) |bn254| layer2_tests.linkLibrary(bn254);
    layer2_tests.linkLibC();
    if (target.result.os.tag == .linux) layer2_tests.linkSystemLibrary("unwind");
    const layer2_tests_step = b.step("test-layer2", "Run Layer 2 (Base & OP Stack) unit tests");
    layer2_tests_step.dependOn(&b.addRunArtifact(layer2_tests).step);

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
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });
        fusions_basic.root_module.addImport("evm", modules.evm_mod);
        fusions_basic.root_module.addImport("voltaire", modules.primitives_mod);
        fusions_basic.root_module.addImport("crypto", modules.crypto_mod);
        fusions_basic.root_module.addImport("build_options", options_mod);
        fusions_basic.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = optimize }));
        if (bn254_lib) |bn254| fusions_basic.linkLibrary(bn254);
        fusions_basic.linkLibC();

        // Dispatch-specific fusion tests (jump resolution, etc.)
        const fusions_dispatch = b.addTest(.{
            .name = "fusions_dispatch",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/fusions_dispatch.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });
        fusions_dispatch.root_module.addImport("evm", modules.evm_mod);
        fusions_dispatch.root_module.addImport("voltaire", modules.primitives_mod);
        fusions_dispatch.root_module.addImport("crypto", modules.crypto_mod);
        fusions_dispatch.root_module.addImport("build_options", options_mod);
        fusions_dispatch.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = optimize }));
        if (bn254_lib) |bn254| fusions_dispatch.linkLibrary(bn254);
        fusions_dispatch.linkLibC();

        // Differential harness: non-fuseable pattern sanity check
        const fusions_diff_toggle = b.addTest(.{
            .name = "fusions_diff_toggle",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/differential/synthetic_toggle_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            // Force LLVM backend: native Zig backend on Linux x86 doesn't support tail calls yet
            .use_llvm = true,
        });
        fusions_diff_toggle.root_module.addImport("evm", modules.evm_mod);
        fusions_diff_toggle.root_module.addImport("voltaire", modules.primitives_mod);
        fusions_diff_toggle.root_module.addImport("crypto", modules.crypto_mod);
        fusions_diff_toggle.root_module.addImport("build_options", options_mod);
        fusions_diff_toggle.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = optimize }));
        // Using MinimalEvm for differential testing (REVM removed)
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

    // Comprehensive Fuzz Testing Suite (Zig std.testing.fuzz + multi-threaded fuzz-campaign)
    {
        const fuzz_tests = b.addTest(.{
            .name = "fuzz-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/fuzz/root.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        fuzz_tests.root_module.addImport("evm", modules.evm_mod);
        fuzz_tests.root_module.addImport("voltaire", modules.primitives_mod);
        fuzz_tests.root_module.addImport("crypto", modules.crypto_mod);
        fuzz_tests.root_module.addImport("build_options", options_mod);
        fuzz_tests.root_module.addImport("evm_c_api", shared_lib_mod);
        if (bn254_lib) |bn254| fuzz_tests.linkLibrary(bn254);
        fuzz_tests.linkLibC();
        if (test_filter) |filter| {
            const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM");
            filters[0] = filter;
            fuzz_tests.filters = filters;
        }
        const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
        const fuzz_test_step = b.step("test-fuzz", "Run all Zig fuzz targets (pass --fuzz on Linux for LLVM coverage-guided fuzzing)");
        fuzz_test_step.dependOn(&run_fuzz_tests.step);

        // Standalone multi-threaded cross-platform fuzz campaign runner (macOS + Linux)
        const fuzz_campaign_exe = b.addExecutable(.{
            .name = "guillotine-fuzz-campaign",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/fuzz/fuzz_campaign.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        fuzz_campaign_exe.root_module.addImport("evm", modules.evm_mod);
        fuzz_campaign_exe.root_module.addImport("voltaire", modules.primitives_mod);
        fuzz_campaign_exe.root_module.addImport("crypto", modules.crypto_mod);
        fuzz_campaign_exe.root_module.addImport("build_options", options_mod);
        fuzz_campaign_exe.root_module.addImport("evm_c_api", shared_lib_mod);
        if (bn254_lib) |bn254| fuzz_campaign_exe.linkLibrary(bn254);
        fuzz_campaign_exe.linkLibC();

        const run_fuzz_campaign = b.addRunArtifact(fuzz_campaign_exe);
        if (b.args) |args| {
            run_fuzz_campaign.addArgs(args);
        }
        const fuzz_campaign_step = b.step("fuzz-campaign", "Run multi-threaded cross-platform fuzz campaign (pass -- --seconds=N --threads=M)");
        fuzz_campaign_step.dependOn(&run_fuzz_campaign.step);
    }

    // Formal verification suite (LLVM 20 IR equivalence/UB, Bitwuzla/Z3 SMT, Lean 4 proofs)
    {
        const verified_ops_mod = b.createModule(.{
            .root_source_file = b.path("src/verified_ops.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        const verify_exports_mod = b.createModule(.{
            .root_source_file = b.path("verify/zig/verify_exports.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        verify_exports_mod.addImport("verified_ops", verified_ops_mod);
        const verify_exports_obj = b.addObject(.{
            .name = "guillotine_verify_exports",
            .root_module = verify_exports_mod,
            .use_llvm = true,
        });
        const run_verify_ir = b.addSystemCommand(&.{ "python3", "verify/llvm/llvm_ir_verify.py" });
        run_verify_ir.addFileArg(verify_exports_obj.getEmittedLlvmIr());
        const verify_ir_step = b.step("verify-ir", "Verify compiled Zig ReleaseFast LLVM 20 IR equivalence and UB-freedom via Bitwuzla/Z3");
        verify_ir_step.dependOn(&run_verify_ir.step);

        const run_verify_smt = b.addSystemCommand(&.{ "python3", "verify/smt/run_smt_suite.py", "--solver", "auto" });
        const verify_smt_step = b.step("verify-smt", "Run Bitwuzla/Z3 SMT-LIB2 formal proofs for EVM arithmetic, memory, stack, and fusions");
        verify_smt_step.dependOn(&run_verify_smt.step);

        const run_verify_lean = b.addSystemCommand(&.{ "bash", "-c", "export PATH=\"$HOME/.elan/bin:$PATH\" && cd verify/lean && lake build" });
        const verify_lean_step = b.step("verify-lean", "Build and kernel-check Lean 4 formal proofs in verify/lean/");
        verify_lean_step.dependOn(&run_verify_lean.step);

        const verified_ops_unit = b.addTest(.{
            .name = "verified-ops-unit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/verified_ops.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
            }),
            .use_llvm = true,
        });
        const run_verified_ops_unit = b.addRunArtifact(verified_ops_unit);

        const verify_all_step = b.step("verify", "Run full formal verification suite (LLVM 20 IR + SMT + Lean 4 + unit tests)");
        verify_all_step.dependOn(&run_verified_ops_unit.step);
        verify_all_step.dependOn(verify_ir_step);
        verify_all_step.dependOn(verify_smt_step);
        verify_all_step.dependOn(verify_lean_step);
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

    // Self-contained ReleaseFast EVM & per-subsystem benchmark suites
    const benches = @import("bench/bench_step.zig");
    const bench_suites = @import("bench/suites_build.zig");
    const bench_archive = benches.nativeArchive(b, b.path("bench"), b.path("."), target);
    const bench_hardfork = b.option([]const u8, "bench-hardfork", "Benchmark hardfork (default OSAKA)") orelse "OSAKA";
    const bench_gas_limit = b.option(u64, "bench-gas-limit", "Benchmark gas budget");
    const bench_flags = b.addOptions();
    bench_flags.addOption(bool, "enable_tracing", false);
    bench_flags.addOption(bool, "disable_tailcall_dispatch", false);
    bench_flags.addOption(bool, "disable_gas_checks", false);
    bench_flags.addOption(bool, "enable_fusion", true);
    bench_flags.addOption([]const u8, "hardfork", bench_hardfork);
    const bench_flags_mod = bench_flags.createModule();
    var bench_copies: std.AutoHashMap(*std.Build.Module, *std.Build.Module) = .init(b.allocator);
    defer bench_copies.deinit();
    const bench_evm_raw = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_evm_raw.addImport("build_options", bench_flags_mod);
    bench_evm_raw.addImport("voltaire", modules.primitives_mod);
    bench_evm_raw.addImport("crypto", modules.crypto_mod);
    bench_evm_raw.addImport("precompiles", modules.precompiles_mod);
    bench_evm_raw.addImport("provider", modules.provider_mod);
    _ = benches.addBenchSteps(b, .{
        .target = target,
        .evm = bench_evm_raw,
        .native_archive = bench_archive,
        .hardfork = bench_hardfork,
        .gas_limit = bench_gas_limit,
    });
    bench_suites.addSuiteSteps(b, .{
        .target = target,
        .optimize = .ReleaseFast,
        .directory = b.path("bench"),
        .repository = b.path("."),
        .evm = benches.optimized(b, bench_evm_raw, .ReleaseFast, bench_archive, &bench_copies),
        .voltaire = benches.optimized(b, modules.primitives_mod, .ReleaseFast, bench_archive, &bench_copies),
        .crypto = benches.optimized(b, modules.crypto_mod, .ReleaseFast, bench_archive, &bench_copies),
        .precompiles = benches.optimized(b, modules.precompiles_mod, .ReleaseFast, bench_archive, &bench_copies),
        .build_options = bench_flags_mod,
        .native_archive = bench_archive,
    });
}
