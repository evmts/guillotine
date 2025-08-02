const std = @import("std");
const packages = @import("packages.zig");

pub const TestConfig = struct {
    name: []const u8,
    root_source_file: []const u8,
    imports: []const TestImport,
    bn254_lib: ?*std.Build.Step.Compile = null,
    revm_lib: ?*std.Build.Step.Compile = null,
    rust_lib: ?*std.Build.Step.Compile = null,
    step_name: []const u8,
    step_description: []const u8,
};

pub const TestImport = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub fn createTest(b: *std.Build, config: TestConfig, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct {
    test_exe: *std.Build.Step.Compile,
    run_step: *std.Build.Step.Run,
    test_step: *std.Build.Step,
} {
    const test_exe = b.addTest(.{
        .root_source_file = b.path(config.root_source_file),
        .target = target,
        .optimize = optimize,
    });
    
    // Add imports
    for (config.imports) |import| {
        test_exe.root_module.addImport(import.name, import.module);
    }
    
    // Link BN254 library if needed
    if (config.bn254_lib) |bn254| {
        test_exe.linkLibrary(bn254);
        test_exe.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    // Link REVM library if needed
    if (config.revm_lib) |revm| {
        test_exe.linkLibrary(revm);
        test_exe.addIncludePath(b.path("src/revm_wrapper"));
    }
    
    // Link any additional Rust library
    if (config.rust_lib) |rust| {
        test_exe.linkLibrary(rust);
    }
    
    const run_step = b.addRunArtifact(test_exe);
    
    const test_step = b.step(config.step_name, config.step_description);
    test_step.dependOn(&run_step.step);
    
    return .{
        .test_exe = test_exe,
        .run_step = run_step,
        .test_step = test_step,
    };
}

pub fn setupAllTests(b: *std.Build, pkgs: packages.Packages, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Main library tests
    const lib_unit_tests = b.addTest(.{
        .root_module = pkgs.lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    
    const exe_mod = b.createModule(.{ 
        .root_source_file = b.path("src/main.zig"), 
        .target = target, 
        .optimize = optimize 
    });
    exe_mod.addImport("Guillotine_lib", pkgs.lib_mod);
    
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    
    // Define all test configurations
    const test_configs = [_]TestConfig{
        .{
            .name = "memory",
            .root_source_file = "test/evm/memory_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-memory",
            .step_description = "Run Memory tests",
        },
        .{
            .name = "memory_leak",
            .root_source_file = "test/evm/memory_leak_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-memory-leak",
            .step_description = "Run Memory leak prevention tests",
        },
        .{
            .name = "stack",
            .root_source_file = "test/evm/stack_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-stack",
            .step_description = "Run Stack tests",
        },
        .{
            .name = "stack_validation",
            .root_source_file = "test/evm/stack_validation_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-stack-validation",
            .step_description = "Run Stack validation tests",
        },
        .{
            .name = "jump_table",
            .root_source_file = "test/evm/jump_table_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "primitives", .module = pkgs.primitives_mod },
                .{ .name = "evm", .module = pkgs.evm_mod },
            },
            .bn254_lib = pkgs.bn254_lib,
            .step_name = "test-jump-table",
            .step_description = "Run Jump table tests",
        },
        .{
            .name = "opcodes",
            .root_source_file = "test/evm/opcodes_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .bn254_lib = pkgs.bn254_lib,
            .step_name = "test-opcodes",
            .step_description = "Run Opcodes tests",
        },
        .{
            .name = "opcode_comparison",
            .root_source_file = "test/evm/opcode_comparison_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
                .{ .name = "revm", .module = pkgs.revm_mod orelse unreachable },
            },
            .bn254_lib = pkgs.bn254_lib,
            .revm_lib = pkgs.revm_lib,
            .step_name = "test-opcode-comparison",
            .step_description = "Run opcode comparison tests",
        },
        .{
            .name = "vm_opcode",
            .root_source_file = "test/evm/vm_opcode_tests.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-vm-opcodes",
            .step_description = "Run VM opcode tests",
        },
        .{
            .name = "integration",
            .root_source_file = "test/evm/integration_tests.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-integration",
            .step_description = "Run Integration tests",
        },
        .{
            .name = "gas",
            .root_source_file = "test/evm/gas_accounting_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-gas",
            .step_description = "Run Gas Accounting tests",
        },
        .{
            .name = "static_protection",
            .root_source_file = "test/evm/static_call_protection_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-static-protection",
            .step_description = "Run Static Call Protection tests",
        },
        .{
            .name = "blake2f",
            .root_source_file = "src/evm/precompiles/blake2f.zig",
            .imports = &[_]TestImport{
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-blake2f",
            .step_description = "Run BLAKE2f precompile tests",
        },
        .{
            .name = "e2e_simple",
            .root_source_file = "test/evm/e2e_simple_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-e2e-simple",
            .step_description = "Run E2E simple tests",
        },
        .{
            .name = "e2e_error",
            .root_source_file = "test/evm/e2e_error_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-e2e-error",
            .step_description = "Run E2E error handling tests",
        },
        .{
            .name = "e2e_data",
            .root_source_file = "test/evm/e2e_data_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-e2e-data",
            .step_description = "Run E2E data structures tests",
        },
        .{
            .name = "e2e_inheritance",
            .root_source_file = "test/evm/e2e_inheritance_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-e2e-inheritance",
            .step_description = "Run E2E inheritance tests",
        },
        .{
            .name = "devtool",
            .root_source_file = "src/devtool/router.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
                .{ .name = "provider", .module = pkgs.provider_mod },
            },
            .step_name = "test-devtool",
            .step_description = "Run Devtool tests",
        },
        .{
            .name = "snail_shell_benchmark",
            .root_source_file = "test/evm/snail_shell_benchmark.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-benchmark",
            .step_description = "Run SnailShellBenchmark tests",
        },
        .{
            .name = "constructor_bug",
            .root_source_file = "test/evm/constructor_bug_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-constructor-bug",
            .step_description = "Run Constructor Bug test",
        },
        .{
            .name = "solidity_constructor",
            .root_source_file = "test/evm/solidity_constructor_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-solidity-constructor",
            .step_description = "Run Solidity Constructor test",
        },
        .{
            .name = "return_opcode_bug",
            .root_source_file = "test/evm/return_opcode_bug_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-return-opcode-bug",
            .step_description = "Run RETURN opcode bug test",
        },
        .{
            .name = "contract_call",
            .root_source_file = "test/evm/contract_call_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-contract-call",
            .step_description = "Run Contract Call tests",
        },
        .{
            .name = "delegatecall",
            .root_source_file = "test/evm/delegatecall_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-delegatecall",
            .step_description = "Run DELEGATECALL tests",
        },
        .{
            .name = "constructor_revert",
            .root_source_file = "test/evm/constructor_revert_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-constructor-revert",
            .step_description = "Run constructor REVERT test",
        },
        .{
            .name = "string_storage",
            .root_source_file = "test/evm/string_storage_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-string-storage",
            .step_description = "Run string storage tests",
        },
        .{
            .name = "jumpi_bug",
            .root_source_file = "test/evm/jumpi_bug_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-jumpi",
            .step_description = "Run JUMPI bug test",
        },
        .{
            .name = "tracer",
            .root_source_file = "test/evm/tracer_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-tracer",
            .step_description = "Run tracer test",
        },
        .{
            .name = "compare",
            .root_source_file = "test/evm/compare_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-compare",
            .step_description = "Run execution comparison test",
        },
    };
    
    // Create main test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    
    // Create all individual tests
    for (test_configs) |config| {
        // Skip tests that require optional dependencies if they're not available
        if (config.name.len >= 5 and std.mem.eql(u8, config.name[0..5], "revm_") and pkgs.revm_mod == null) continue;
        if (std.mem.eql(u8, config.name, "opcode_comparison") and pkgs.revm_mod == null) continue;
        
        const result = createTest(b, config, target, optimize);
        test_step.dependOn(&result.run_step.step);
    }
    
    // Add platform-specific tests
    const no_bn254 = pkgs.bn254_lib == null;
    
    // SHA256 test (skip on native builds without BN254 support)
    if (!no_bn254) {
        const sha256_result = createTest(b, .{
            .name = "sha256",
            .root_source_file = "src/evm/precompiles/sha256.zig",
            .imports = &[_]TestImport{
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-sha256",
            .step_description = "Run SHA256 precompile tests",
        }, target, optimize);
        test_step.dependOn(&sha256_result.run_step.step);
    }
    
    // RIPEMD160 test (skip on native builds without BN254 support)
    if (!no_bn254) {
        const ripemd160_result = createTest(b, .{
            .name = "ripemd160",
            .root_source_file = "src/evm/precompiles/ripemd160.zig",
            .imports = &[_]TestImport{
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .step_name = "test-ripemd160",
            .step_description = "Run RIPEMD160 precompile tests",
        }, target, optimize);
        test_step.dependOn(&ripemd160_result.run_step.step);
    }
    
    // BN254 Rust wrapper test
    if (pkgs.bn254_lib != null) {
        const bn254_result = createTest(b, .{
            .name = "bn254_rust",
            .root_source_file = "test/evm/bn254_rust_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "evm", .module = pkgs.evm_mod },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .bn254_lib = pkgs.bn254_lib,
            .step_name = "test-bn254-rust",
            .step_description = "Run BN254 Rust wrapper precompile tests",
        }, target, optimize);
        test_step.dependOn(&bn254_result.run_step.step);
    }
    
    // REVM wrapper test
    if (pkgs.revm_lib != null) {
        const revm_result = createTest(b, .{
            .name = "revm",
            .root_source_file = "test/revm_wrapper_test.zig",
            .imports = &[_]TestImport{
                .{ .name = "revm", .module = pkgs.revm_mod.? },
                .{ .name = "primitives", .module = pkgs.primitives_mod },
            },
            .revm_lib = pkgs.revm_lib,
            .step_name = "test-revm",
            .step_description = "Run REVM wrapper tests",
        }, target, optimize);
        test_step.dependOn(&revm_result.run_step.step);
    }
    
    // Debug test configurations (not included in main test step)
    _ = createTest(b, .{
        .name = "erc20_mint_debug",
        .root_source_file = "test/evm/erc20_mint_debug_test.zig",
        .imports = &[_]TestImport{
            .{ .name = "evm", .module = pkgs.evm_mod },
            .{ .name = "primitives", .module = pkgs.primitives_mod },
        },
        .step_name = "test-erc20-debug",
        .step_description = "Run ERC20 mint test with full debug logging",
    }, target, optimize);
    
    _ = createTest(b, .{
        .name = "erc20_constructor_debug",
        .root_source_file = "test/evm/erc20_constructor_debug_test.zig",
        .imports = &[_]TestImport{
            .{ .name = "evm", .module = pkgs.evm_mod },
            .{ .name = "primitives", .module = pkgs.primitives_mod },
        },
        .step_name = "test-erc20-constructor",
        .step_description = "Run ERC20 constructor debug test",
    }, target, optimize);
    
    _ = createTest(b, .{
        .name = "trace_erc20",
        .root_source_file = "test/evm/trace_erc20_test.zig",
        .imports = &[_]TestImport{
            .{ .name = "evm", .module = pkgs.evm_mod },
            .{ .name = "primitives", .module = pkgs.primitives_mod },
        },
        .step_name = "test-trace-erc20",
        .step_description = "Trace ERC20 constructor execution",
    }, target, optimize);
    
    _ = createTest(b, .{
        .name = "erc20_trace",
        .root_source_file = "test/evm/erc20_trace_test.zig",
        .imports = &[_]TestImport{
            .{ .name = "evm", .module = pkgs.evm_mod },
            .{ .name = "primitives", .module = pkgs.primitives_mod },
        },
        .step_name = "test-erc20-trace",
        .step_description = "Run ERC20 constructor trace test",
    }, target, optimize);
    
    // E2E all test step - just create dependencies on already-created test steps
    const e2e_all_test_step = b.step("test-e2e", "Run all E2E tests");
    
    // Find and add dependencies for the E2E test steps that were already created
    const e2e_tests = [_][]const u8{
        "test-e2e-simple",
        "test-e2e-error", 
        "test-e2e-data",
        "test-e2e-inheritance",
    };
    
    for (e2e_tests) |step_name| {
        if (b.top_level_steps.get(step_name)) |entry| {
            e2e_all_test_step.dependOn(&entry.step);
        }
    }
}

pub fn setupFuzzTests(b: *std.Build, pkgs: packages.Packages, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const fuzz_test_step = b.step("fuzz", "Run all fuzz tests");
    
    const fuzz_files = [_][]const u8{
        "test/fuzz/add_opcode_fuzz.zig",
        "test/fuzz/sub_opcode_fuzz.zig",
        "test/fuzz/mul_opcode_fuzz.zig",
        "test/fuzz/div_opcode_fuzz.zig",
        "test/fuzz/sdiv_opcode_fuzz.zig",
        "test/fuzz/mod_opcode_fuzz.zig",
        "test/fuzz/smod_opcode_fuzz.zig",
        "test/fuzz/addmod_opcode_fuzz.zig",
        "test/fuzz/mulmod_opcode_fuzz.zig",
        "test/fuzz/exp_opcode_fuzz.zig",
        "test/fuzz/signextend_opcode_fuzz.zig",
    };
    
    for (fuzz_files) |fuzz_file| {
        const fuzz_test = b.addTest(.{
            .root_source_file = b.path(fuzz_file),
            .target = target,
            .optimize = optimize,
        });
        fuzz_test.root_module.addImport("evm", pkgs.evm_mod);
        fuzz_test.root_module.addImport("primitives", pkgs.primitives_mod);
        
        // Link BN254 if available
        if (pkgs.bn254_lib) |bn254| {
            fuzz_test.linkLibrary(bn254);
            fuzz_test.addIncludePath(b.path("src/bn254_wrapper"));
        }
        
        const run_fuzz_test = b.addRunArtifact(fuzz_test);
        fuzz_test_step.dependOn(&run_fuzz_test.step);
    }
}