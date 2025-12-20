const std = @import("std");

// Sub-modules for specialized test areas
pub const OfficialTests = @import("official/build.zig");
pub const ExecutionSpecTests = @import("execution-spec-tests/build.zig");
pub const SpecsBuild = @import("../specs/build.zig");

pub fn createAllTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config: anytype,
    libs: anytype, // Accept any struct with the required fields
    test_filters: []const []const u8,
) void {
    // Create the main test step
    const test_step = b.step("test", "Run all tests");

    // Unit tests for lib module (src/root.zig)
    const lib_unit_tests = b.addTest(.{
        .root_module = modules.lib_mod,
        .filters = test_filters,
        .use_llvm = true,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    test_step.dependOn(&run_lib_unit_tests.step);

    // Unit tests for EVM module (also src/root.zig)
    const evm_unit_tests = b.addTest(.{
        .root_module = modules.evm_mod,
        .filters = test_filters,
        .use_llvm = true,
    });
    const run_evm_unit_tests = b.addRunArtifact(evm_unit_tests);
    test_step.dependOn(&run_evm_unit_tests.step);

    // Integration tests
    const integration_tests = createIntegrationTests(b, target, optimize, modules, libs.bn254_lib, libs.c_kzg_lib, libs.blst_lib);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    // Root tests
    const root_tests = createRootTests(b, target, optimize, modules, libs, test_filters);
    const run_root_tests = b.addRunArtifact(root_tests);
    test_step.dependOn(&run_root_tests.step);

    // Compiler tests
    createCompilerTests(b, target, optimize, modules, libs.bn254_lib, test_step);

    // Opcode differential tests - returns the step
    const opcodes_step = createOpcodeTests(b, target, optimize, modules, config.options_mod, libs, test_filters);
    test_step.dependOn(opcodes_step);

    // EVM-specific tests - returns multiple steps
    const evm_steps = createEvmTests(b, target, optimize, modules, config.options_mod, libs);
    test_step.dependOn(evm_steps.snailtracer);
    test_step.dependOn(evm_steps.fixtures_differential);
    test_step.dependOn(evm_steps.codecopy_return);
    test_step.dependOn(evm_steps.jump_table);

    // Fusion tests - returns the step
    const fusions_step = createFusionTests(b, target, optimize, modules, config.options_mod, libs);
    test_step.dependOn(fusions_step);

    // Development and debug tests - no need to add to main test step
    createDebugTests(b, target, optimize, modules, config.options_mod, libs);

    // Official tests - returns both steps
    const official_steps = OfficialTests.createOfficialTests(b, target, optimize, modules, config.options_mod, libs.c_kzg_lib, libs.blst_lib, libs.bn254_lib);
    test_step.dependOn(official_steps.state);
    test_step.dependOn(official_steps.blockchain);

    // Execution spec tests - returns both steps
    const fetch_fixtures_step = ExecutionSpecTests.createFetchFixturesStep(b);
    const exec_spec_steps = ExecutionSpecTests.createExecutionSpecTests(b, target, optimize, modules, libs.c_kzg_lib, libs.blst_lib, libs.bn254_lib, fetch_fixtures_step);
    test_step.dependOn(exec_spec_steps.minimal_evm);
    test_step.dependOn(exec_spec_steps.guillotine);

    if (b.top_level_steps.get("test-erc20-mint")) |erc20_mint_step| {
        test_step.dependOn(&erc20_mint_step.step);
    }
    if (b.top_level_steps.get("test-erc20-transfer")) |erc20_transfer_step| {
        test_step.dependOn(&erc20_transfer_step.step);
    }
    if (b.top_level_steps.get("test-codecopy-return")) |codecopy_step| {
        test_step.dependOn(&codecopy_step.step);
    }
    if (b.top_level_steps.get("test-fixtures-differential")) |fixtures_step| {
        test_step.dependOn(&fixtures_step.step);
    }

    // Bun specs tests - add to main test step
    SpecsBuild.createBunSpecsRunner(b);
    if (b.top_level_steps.get("specs")) |specs_step| {
        test_step.dependOn(&specs_step.step);
    }
}

pub fn createIntegrationTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    bn254_lib: ?*std.Build.Step.Compile,
    c_kzg_lib: *std.Build.Step.Compile,
    blst_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    integration_tests.root_module.addImport("evm", modules.evm_mod);
    integration_tests.root_module.addImport("voltaire", modules.primitives_mod);
    integration_tests.root_module.addImport("crypto", modules.crypto_mod);
    integration_tests.root_module.addImport("compilers", modules.compilers_mod);
    integration_tests.root_module.addImport("provider", modules.provider_mod);
    integration_tests.root_module.addImport("trie", modules.trie_mod);
    integration_tests.root_module.addImport("Guillotine_lib", modules.lib_mod);

    if (bn254_lib) |bn254| {
        integration_tests.linkLibrary(bn254);
        integration_tests.addIncludePath(b.path("lib/ark"));
    }

    integration_tests.linkLibrary(c_kzg_lib);
    integration_tests.linkLibrary(blst_lib);
    integration_tests.linkLibC();

    return integration_tests;
}

fn createRootTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    libs: anytype,
    test_filters: []const []const u8,
) *std.Build.Step.Compile {
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
        .use_llvm = true,
    });

    root_tests.root_module.addImport("evm", modules.evm_mod);
    root_tests.root_module.addImport("voltaire", modules.primitives_mod);
    root_tests.root_module.addImport("crypto", modules.crypto_mod);
    root_tests.root_module.addImport("compilers", modules.compilers_mod);
    root_tests.root_module.addImport("provider", modules.provider_mod);
    root_tests.root_module.addImport("trie", modules.trie_mod);
    root_tests.root_module.addImport("Guillotine_lib", modules.lib_mod);

    root_tests.linkLibrary(libs.shared_lib);
    root_tests.linkLibrary(libs.c_kzg_lib);
    root_tests.linkLibrary(libs.blst_lib);
    if (libs.bn254_lib) |bn254| root_tests.linkLibrary(bn254);
    root_tests.linkLibC();

    return root_tests;
}

fn createCompilerTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    foundry_lib: ?*std.Build.Step.Compile,
    test_step: *std.Build.Step,
) void {
    const compiler_tests = b.addTest(.{
        .name = "compiler-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/compiler_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });

    compiler_tests.root_module.addImport("compilers", modules.compilers_mod);
    compiler_tests.root_module.addImport("voltaire", modules.primitives_mod);

    if (foundry_lib) |foundry| {
        compiler_tests.linkLibrary(foundry);
        compiler_tests.addIncludePath(b.path("lib/foundry-compilers"));
        compiler_tests.linkLibC();

        const run_compiler_tests = b.addRunArtifact(compiler_tests);
        const compiler_test_step = b.step("test-compiler", "Run compiler tests");
        compiler_test_step.dependOn(&run_compiler_tests.step);
        test_step.dependOn(&run_compiler_tests.step);
    }
}

fn createOpcodeTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
    test_filters: []const []const u8,
) *std.Build.Step {
    _ = optimize;
    const opcode_tests_step = b.step("test-opcodes", "Run all per-opcode differential tests. Use -Dtest-filter='<pattern>' to filter tests");

    const all_opcodes_test = b.addTest(.{
        .name = "all-opcodes-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/opcodes/all_opcodes.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        .filters = test_filters,
        .use_llvm = true,
    });

    all_opcodes_test.root_module.addImport("evm", modules.evm_mod);
    all_opcodes_test.root_module.addImport("voltaire", modules.primitives_mod);
    all_opcodes_test.root_module.addImport("crypto", modules.crypto_mod);
    all_opcodes_test.root_module.addImport("build_options", config_options_mod);
    // log module is already part of evm module (evm.log)

    all_opcodes_test.linkLibrary(libs.c_kzg_lib);
    all_opcodes_test.linkLibrary(libs.blst_lib);
    if (libs.bn254_lib) |bn254| all_opcodes_test.linkLibrary(bn254);
    all_opcodes_test.linkLibC();

    const run_opcodes_test = b.addRunArtifact(all_opcodes_test);
    opcode_tests_step.dependOn(&run_opcodes_test.step);
    return opcode_tests_step;
}

const EvmTestSteps = struct {
    snailtracer: *std.Build.Step,
    fixtures_differential: *std.Build.Step,
    codecopy_return: *std.Build.Step,
    jump_table: *std.Build.Step,
};

fn createEvmTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) EvmTestSteps {
    // ERC20 tests (don't need to be in main test)
    createErc20Tests(b, target, optimize, modules, config_options_mod, libs);

    // Snailtracer test
    const snailtracer_step = createSnailTracerTest(b, target, optimize, modules, config_options_mod, libs);

    // Jump table test
    const jump_table_step = createJumpTableTest(b, target, .Debug, modules, config_options_mod, libs);

    // CODECOPY+RETURN test
    const codecopy_step = createCodecopyTest(b, target, optimize, modules, config_options_mod, libs);

    // Fixtures differential test
    const fixtures_step = createFixturesDifferentialTest(b, target, .Debug, modules, config_options_mod, libs);

    return .{
        .snailtracer = snailtracer_step,
        .fixtures_differential = fixtures_step,
        .codecopy_return = codecopy_step,
        .jump_table = jump_table_step,
    };
}

fn createErc20Tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) void {
    // ERC20 deployment gas issue test
    {
        const test_exe = b.addTest(.{
            .name = "test-erc20-gas",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/erc20_deployment_gas_issue.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        configureEvmTest(b, test_exe, modules, config_options_mod, libs, target, .Debug);
        const step = b.step("test-erc20-gas", "Test ERC20 deployment gas issue");
        step.dependOn(&b.addRunArtifact(test_exe).step);
    }

    // ERC20 deployment issue test
    {
        const test_exe = b.addTest(.{
            .name = "test-erc20-deployment",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/erc20_deployment_issue.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        configureEvmTest(b, test_exe, modules, config_options_mod, libs, target, .Debug);
        const step = b.step("test-erc20-deployment", "Test ERC20 deployment issue");
        step.dependOn(&b.addRunArtifact(test_exe).step);
    }

    // ERC20 mint differential test
    {
        const test_exe = b.addTest(.{
            .name = "erc20_mint_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/erc20_mint_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        test_exe.root_module.addImport("evm", modules.evm_mod);
        test_exe.root_module.addImport("voltaire", modules.primitives_mod);
        test_exe.root_module.addImport("crypto", modules.crypto_mod);
        test_exe.linkLibrary(libs.c_kzg_lib);
        test_exe.linkLibrary(libs.blst_lib);
        if (libs.bn254_lib) |bn254| test_exe.linkLibrary(bn254);
        test_exe.linkLibC();

        const step = b.step("test-erc20-mint", "Run ERC20 mint differential test");
        step.dependOn(&b.addRunArtifact(test_exe).step);
    }

    // ERC20 transfer test
    {
        const test_exe = b.addTest(.{
            .name = "erc20_transfer_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/erc20_transfer_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        test_exe.root_module.addImport("evm", modules.evm_mod);
        test_exe.root_module.addImport("voltaire", modules.primitives_mod);
        test_exe.root_module.addImport("crypto", modules.crypto_mod);
        test_exe.root_module.addImport("build_options", config_options_mod);
        test_exe.linkLibrary(libs.c_kzg_lib);
        test_exe.linkLibrary(libs.blst_lib);
        if (libs.bn254_lib) |bn254| test_exe.linkLibrary(bn254);
        test_exe.linkLibC();

        const step = b.step("test-erc20-transfer", "Run ERC20 transfer test");
        step.dependOn(&b.addRunArtifact(test_exe).step);
    }
}

fn createSnailTracerTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) *std.Build.Step {
    _ = optimize;
    const test_exe = b.addTest(.{
        .name = "snailtracer-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/snailtracer_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    configureEvmTest(b, test_exe, modules, config_options_mod, libs, target, .Debug);
    const step = b.step("test-snailtracer", "Run snailtracer differential test");
    step.dependOn(&b.addRunArtifact(test_exe).step);
    return step;
}

fn createJumpTableTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) *std.Build.Step {
    const test_exe = b.addTest(.{
        .name = "test-jump-table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/jump_table_issue.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    configureEvmTest(b, test_exe, modules, config_options_mod, libs, target, optimize);
    const step = b.step("test-jump-table", "Test jump table JUMPDEST recognition");
    step.dependOn(&b.addRunArtifact(test_exe).step);
    return step;
}

fn createCodecopyTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) *std.Build.Step {
    _ = libs;
    const test_exe = b.addTest(.{
        .name = "codecopy_return_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/evm/codecopy_return_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    test_exe.root_module.addImport("evm", modules.evm_mod);
    test_exe.root_module.addImport("voltaire", modules.primitives_mod);
    test_exe.root_module.addImport("crypto", modules.crypto_mod);
    test_exe.root_module.addImport("build_options", config_options_mod);

    const step = b.step("test-codecopy-return", "Test CODECOPY and RETURN opcodes");
    step.dependOn(&b.addRunArtifact(test_exe).step);
    return step;
}

fn createFixturesDifferentialTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) *std.Build.Step {
    const test_exe = b.addTest(.{
        .name = "fixtures-differential-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential/fixtures_comprehensive_differential_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    configureEvmTest(b, test_exe, modules, config_options_mod, libs, target, optimize);
    const step = b.step("test-fixtures-differential", "Run differential tests for benchmark fixtures (ERC20, snailtracer, etc.)");
    step.dependOn(&b.addRunArtifact(test_exe).step);
    return step;
}

fn createFusionTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) *std.Build.Step {
    _ = optimize;
    // Basic fusion detection and execution tests
    const fusions_basic = b.addTest(.{
        .name = "fusions_basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fusions.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    configureEvmTest(b, fusions_basic, modules, config_options_mod, libs, target, .Debug);

    // Dispatch-specific fusion tests
    const fusions_dispatch = b.addTest(.{
        .name = "fusions_dispatch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fusions_dispatch.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    configureEvmTest(b, fusions_dispatch, modules, config_options_mod, libs, target, .Debug);

    // Differential harness: non-fuseable pattern sanity check
    const fusions_diff_toggle = b.addTest(.{
        .name = "fusions_diff_toggle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential/synthetic_toggle_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    configureEvmTest(b, fusions_diff_toggle, modules, config_options_mod, libs, target, .Debug);

    const test_fusions_step = b.step("test-fusions", "Run focused fusion tests (unit + dispatch + differential)");
    test_fusions_step.dependOn(&b.addRunArtifact(fusions_basic).step);
    test_fusions_step.dependOn(&b.addRunArtifact(fusions_dispatch).step);
    test_fusions_step.dependOn(&b.addRunArtifact(fusions_diff_toggle).step);
    return test_fusions_step;
}

fn createDebugTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
) void {
    _ = optimize;
    // GT opcode bug test
    {
        const test_exe = b.addTest(.{
            .name = "gt-bug-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test_gt_exact.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        configureEvmTest(b, test_exe, modules, config_options_mod, libs, target, .Debug);
        const step = b.step("test-gt-bug", "Test GT opcode bug");
        step.dependOn(&b.addRunArtifact(test_exe).step);
    }

    // Development test for quick debugging
    {
        const test_exe = b.addTest(.{
            .name = "dev-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/dev_test.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        test_exe.root_module.addImport("evm", modules.evm_mod);
        test_exe.root_module.addImport("voltaire", modules.primitives_mod);
        test_exe.root_module.addImport("crypto", modules.crypto_mod);
        test_exe.root_module.addImport("build_options", config_options_mod);
        test_exe.linkLibrary(libs.c_kzg_lib);
        test_exe.linkLibrary(libs.blst_lib);
        if (libs.bn254_lib) |bn254| test_exe.linkLibrary(bn254);
        test_exe.linkLibC();

        const step = b.step("test-dev", "Run development test for debugging");
        step.dependOn(&b.addRunArtifact(test_exe).step);
    }
}

// Helper function to configure common EVM test dependencies
fn configureEvmTest(
    _: *std.Build,
    test_exe: *std.Build.Step.Compile,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    libs: anytype,
    _: std.Build.ResolvedTarget,
    _: std.builtin.OptimizeMode,
) void {
    test_exe.root_module.addImport("evm", modules.evm_mod);
    test_exe.root_module.addImport("voltaire", modules.primitives_mod);
    test_exe.root_module.addImport("crypto", modules.crypto_mod);
    test_exe.root_module.addImport("build_options", config_options_mod);
    // log module is already part of evm module (evm.log)
    test_exe.linkLibrary(libs.c_kzg_lib);
    test_exe.linkLibrary(libs.blst_lib);
    if (libs.bn254_lib) |bn254| test_exe.linkLibrary(bn254);
    test_exe.linkLibC();
}