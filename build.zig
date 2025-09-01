const std = @import("std");
const build_pkg = @import("build/main.zig");

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
    const config = build_pkg.Config.createBuildOptions(b, target);
    const rust_target = build_pkg.Config.getRustTarget(target);

    // Dependencies
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = optimize }); // retained for module wiring; not used to build benches

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

    // Bench runner executables are removed (moved to separate repo)

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

    // Benchmark executables removed (moved to separate repo)

    // Libraries and utilities
    build_pkg.Utils.createLibraries(b, modules.lib_mod, bn254_lib);
    const lib = b.addLibrary(.{ .linkage = .static, .name = "Guillotine", .root_module = modules.lib_mod });
    build_pkg.Utils.createDocsStep(b, lib);
    _ = build_pkg.Utils.createOpcodeTestLib(b, target, optimize, modules.evm_mod, modules.primitives_mod, modules.crypto_mod, config.options_mod, bn254_lib);
    build_pkg.Utils.createExternalBuildSteps(b);
    
    // Shared library for FFI bindings
    const shared_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/evm_c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_lib_mod.addImport("evm", modules.evm_mod);
    shared_lib_mod.addImport("primitives", modules.primitives_mod);
    shared_lib_mod.addImport("crypto", modules.crypto_mod);
    shared_lib_mod.addImport("build_options", config.options_mod);
    
    const shared_lib = b.addLibrary(.{
        .name = "guillotine_ffi",
        .linkage = .dynamic,
        .root_module = shared_lib_mod,
    });
    shared_lib.linkLibrary(c_kzg_lib);
    shared_lib.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| shared_lib.linkLibrary(bn254);
    shared_lib.linkLibC();
    b.installArtifact(shared_lib);
    
    const shared_lib_step = b.step("shared", "Build shared library for FFI");
    shared_lib_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);

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
    zbench_evm.root_module.addImport("evm", modules.evm_mod);
    zbench_evm.root_module.addImport("primitives", modules.primitives_mod);
    zbench_evm.root_module.addImport("crypto", modules.crypto_mod);
    zbench_evm.root_module.addImport("build_options", config.options_mod);
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
            .optimize = .Debug,  // Debug for better logging
        }),
    });
    erc20_gas_test.root_module.addImport("evm", modules.evm_mod);
    erc20_gas_test.root_module.addImport("primitives", modules.primitives_mod);
    erc20_gas_test.root_module.addImport("crypto", modules.crypto_mod);
    erc20_gas_test.root_module.addImport("build_options", config.options_mod);
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
    });
    jump_table_test.root_module.addImport("evm", modules.evm_mod);
    jump_table_test.root_module.addImport("primitives", modules.primitives_mod);
    jump_table_test.root_module.addImport("crypto", modules.crypto_mod);
    jump_table_test.root_module.addImport("build_options", config.options_mod);
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
    });
    erc20_deployment_test.root_module.addImport("evm", modules.evm_mod);
    erc20_deployment_test.root_module.addImport("primitives", modules.primitives_mod);
    erc20_deployment_test.root_module.addImport("crypto", modules.crypto_mod);
    erc20_deployment_test.root_module.addImport("build_options", config.options_mod);
    erc20_deployment_test.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = .Debug,
    }));
    
    // Add REVM module and library for differential testing
    if (modules.revm_mod) |revm_mod| {
        erc20_deployment_test.root_module.addImport("revm", revm_mod);
        if (revm_lib) |revm| {
            erc20_deployment_test.linkLibrary(revm);
            erc20_deployment_test.addIncludePath(b.path("lib/revm"));
            
            const revm_rust_target_dir_test = if (optimize == .Debug) "debug" else "release";
            const revm_dylib_path_test = if (rust_target) |target_triple|
                b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir_test })
            else
                b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir_test});
            erc20_deployment_test.addObjectFile(b.path(revm_dylib_path_test));
            
            if (target.result.os.tag == .linux) {
                erc20_deployment_test.linkSystemLibrary("m");
                erc20_deployment_test.linkSystemLibrary("pthread");
                erc20_deployment_test.linkSystemLibrary("dl");
            } else if (target.result.os.tag == .macos) {
                erc20_deployment_test.linkSystemLibrary("c++");
                erc20_deployment_test.linkFramework("Security");
                erc20_deployment_test.linkFramework("SystemConfiguration");
                erc20_deployment_test.linkFramework("CoreFoundation");
            }
            
            erc20_deployment_test.step.dependOn(&revm.step);
        }
    }
    
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
    });
    fixtures_differential_test.root_module.addImport("evm", modules.evm_mod);
    fixtures_differential_test.root_module.addImport("primitives", modules.primitives_mod);
    fixtures_differential_test.root_module.addImport("crypto", modules.crypto_mod);
    fixtures_differential_test.root_module.addImport("build_options", config.options_mod);
    fixtures_differential_test.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
    
    // Add REVM module and library for differential testing
    if (modules.revm_mod) |revm_mod| {
        fixtures_differential_test.root_module.addImport("revm", revm_mod);
        if (revm_lib) |revm| {
            fixtures_differential_test.linkLibrary(revm);
            fixtures_differential_test.addIncludePath(b.path("lib/revm"));
            
            const revm_rust_target_dir_test = if (optimize == .Debug) "debug" else "release";
            const revm_dylib_path_test = if (rust_target) |target_triple|
                b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir_test })
            else
                b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir_test});
            fixtures_differential_test.addObjectFile(b.path(revm_dylib_path_test));
            
            if (target.result.os.tag == .linux) {
                fixtures_differential_test.linkSystemLibrary("m");
                fixtures_differential_test.linkSystemLibrary("pthread");
                fixtures_differential_test.linkSystemLibrary("dl");
            } else if (target.result.os.tag == .macos) {
                fixtures_differential_test.linkSystemLibrary("c++");
                fixtures_differential_test.linkFramework("Security");
                fixtures_differential_test.linkFramework("SystemConfiguration");
                fixtures_differential_test.linkFramework("CoreFoundation");
            }
            
            fixtures_differential_test.step.dependOn(&revm.step);
        }
    }
    
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
    });
    snailtracer_test.root_module.addImport("evm", modules.evm_mod);
    snailtracer_test.root_module.addImport("primitives", modules.primitives_mod);
    snailtracer_test.root_module.addImport("crypto", modules.crypto_mod);
    snailtracer_test.root_module.addImport("build_options", config.options_mod);
    snailtracer_test.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
    
    // Add REVM module and library for differential testing
    if (modules.revm_mod) |revm_mod| {
        snailtracer_test.root_module.addImport("revm", revm_mod);
        if (revm_lib) |revm| {
            snailtracer_test.linkLibrary(revm);
            snailtracer_test.addIncludePath(b.path("lib/revm"));
            
            const revm_rust_target_dir_test = if (optimize == .Debug) "debug" else "release";
            const revm_dylib_path_test = if (rust_target) |target_triple|
                b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir_test })
            else
                b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir_test});
            snailtracer_test.addObjectFile(b.path(revm_dylib_path_test));
            
            if (target.result.os.tag == .linux) {
                snailtracer_test.linkSystemLibrary("m");
                snailtracer_test.linkSystemLibrary("pthread");
                snailtracer_test.linkSystemLibrary("dl");
            } else if (target.result.os.tag == .macos) {
                snailtracer_test.linkSystemLibrary("c++");
                snailtracer_test.linkFramework("Security");
                snailtracer_test.linkFramework("SystemConfiguration");
                snailtracer_test.linkFramework("CoreFoundation");
            }
            
            snailtracer_test.step.dependOn(&revm.step);
        }
    }
    
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
    });
    gt_bug_test.root_module.addImport("evm", modules.evm_mod);
    gt_bug_test.root_module.addImport("primitives", modules.primitives_mod);
    gt_bug_test.root_module.addImport("crypto", modules.crypto_mod);
    gt_bug_test.root_module.addImport("build_options", config.options_mod);
    gt_bug_test.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
    gt_bug_test.linkLibrary(c_kzg_lib);
    gt_bug_test.linkLibrary(blst_lib);
    if (bn254_lib) |bn254| gt_bug_test.linkLibrary(bn254);
    gt_bug_test.linkLibC();
    const test_gt_bug = b.step("test-gt-bug", "Test GT opcode bug");
    test_gt_bug.dependOn(&b.addRunArtifact(gt_bug_test).step);

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
            const opcode_hex = entry.name[0..std.mem.indexOf(u8, entry.name, "_") orelse continue];
            const individual_step_name = b.fmt("test-opcodes-0x{s}", .{opcode_hex});
            const individual_step_desc = b.fmt("Test opcode 0x{s}", .{opcode_hex});

            const t = b.addTest(.{
                .name = test_name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(file_path),
                    .target = target,
                    .optimize = .Debug,
                }),
            });
            // Inject module dependencies used by the differential harness
            t.root_module.addImport("evm", modules.evm_mod);
            t.root_module.addImport("primitives", modules.primitives_mod);
            t.root_module.addImport("crypto", modules.crypto_mod);
            t.root_module.addImport("build_options", config.options_mod);
            t.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));

            // Link external libs
            t.linkLibrary(c_kzg_lib);
            t.linkLibrary(blst_lib);
            if (bn254_lib) |bn254| t.linkLibrary(bn254);
            t.linkLibC();

            // Add REVM integration for differential tests
            if (modules.revm_mod) |revm_mod| {
                t.root_module.addImport("revm", revm_mod);
                if (revm_lib) |revm| {
                    t.linkLibrary(revm);
                    t.addIncludePath(b.path("lib/revm"));
                    const revm_rust_target_dir_test = if (optimize == .Debug) "debug" else "release";
                    const revm_dylib_path_test = if (rust_target) |target_triple|
                        b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir_test })
                    else
                        b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir_test});
                    t.addObjectFile(b.path(revm_dylib_path_test));

                    if (target.result.os.tag == .linux) {
                        t.linkSystemLibrary("m");
                        t.linkSystemLibrary("pthread");
                        t.linkSystemLibrary("dl");
                    } else if (target.result.os.tag == .macos) {
                        t.linkSystemLibrary("c++");
                        t.linkFramework("Security");
                        t.linkFramework("SystemConfiguration");
                        t.linkFramework("CoreFoundation");
                    }
                    t.step.dependOn(&revm.step);
                }
            }

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
        });

        // Add all the required dependencies
        erc20_mint_test.root_module.addImport("evm", modules.evm_mod);
        erc20_mint_test.root_module.addImport("primitives", modules.primitives_mod);
        erc20_mint_test.root_module.addImport("crypto", modules.crypto_mod);
        
        // Add REVM module and library for differential testing
        if (modules.revm_mod) |revm_mod| {
            erc20_mint_test.root_module.addImport("revm", revm_mod);
            if (revm_lib) |revm| {
                erc20_mint_test.linkLibrary(revm);
                erc20_mint_test.addIncludePath(b.path("lib/revm"));
                
                const revm_rust_target_dir_test = if (optimize == .Debug) "debug" else "release";
                const revm_dylib_path_test = if (rust_target) |target_triple|
                    b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir_test })
                else
                    b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir_test});
                erc20_mint_test.addObjectFile(b.path(revm_dylib_path_test));
                
                if (target.result.os.tag == .linux) {
                    erc20_mint_test.linkSystemLibrary("m");
                    erc20_mint_test.linkSystemLibrary("pthread");
                    erc20_mint_test.linkSystemLibrary("dl");
                } else if (target.result.os.tag == .macos) {
                    erc20_mint_test.linkSystemLibrary("c++");
                    erc20_mint_test.linkFramework("Security");
                    erc20_mint_test.linkFramework("SystemConfiguration");
                    erc20_mint_test.linkFramework("CoreFoundation");
                }
                
                erc20_mint_test.step.dependOn(&revm.step);
            }
        }
        
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
        });

        erc20_transfer_test.root_module.addImport("evm", modules.evm_mod);
        erc20_transfer_test.root_module.addImport("primitives", modules.primitives_mod);
        erc20_transfer_test.root_module.addImport("crypto", modules.crypto_mod);
        erc20_transfer_test.root_module.addImport("build_options", config.options_mod);
        
        // Link required libraries
        erc20_transfer_test.linkLibrary(c_kzg_lib);
        erc20_transfer_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| erc20_transfer_test.linkLibrary(bn254);
        erc20_transfer_test.linkLibC();
        
        const run_erc20_transfer_test = b.addRunArtifact(erc20_transfer_test);
        const erc20_transfer_step = b.step("test-erc20-transfer", "Run ERC20 transfer test");
        erc20_transfer_step.dependOn(&run_erc20_transfer_test.step);
    }

    // Static jumps test
    {
        const static_jumps_test = b.addTest(.{
            .name = "static_jumps_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/static_jumps.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        
        static_jumps_test.root_module.addImport("evm", modules.evm_mod);
        static_jumps_test.root_module.addImport("primitives", modules.primitives_mod);
        static_jumps_test.root_module.addImport("crypto", modules.crypto_mod);
        static_jumps_test.root_module.addImport("build_options", config.options_mod);
        
        // Link required libraries
        static_jumps_test.linkLibrary(c_kzg_lib);
        static_jumps_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| static_jumps_test.linkLibrary(bn254);
        static_jumps_test.linkLibC();
        
        const run_static_jumps_test = b.addRunArtifact(static_jumps_test);
        const static_jumps_step = b.step("test-static-jumps", "Run static jumps test");
        static_jumps_step.dependOn(&run_static_jumps_test.step);
        
        // Add to main test step
        test_step.dependOn(&run_static_jumps_test.step);
    }

    // CODECOPY+RETURN test
    {
        const codecopy_test = b.addTest(.{
            .name = "codecopy_return_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/evm/codecopy_return_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        
        codecopy_test.root_module.addImport("evm", modules.evm_mod);
        codecopy_test.root_module.addImport("primitives", modules.primitives_mod);
        codecopy_test.root_module.addImport("crypto", modules.crypto_mod);
        codecopy_test.root_module.addImport("build_options", config.options_mod);
        
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
        });

        // Add required imports
        official_state_test.root_module.addImport("evm", modules.evm_mod);
        official_state_test.root_module.addImport("primitives", modules.primitives_mod);
        official_state_test.root_module.addImport("crypto", modules.crypto_mod);
        official_state_test.root_module.addImport("build_options", config.options_mod);

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
        });

        official_chain_test.root_module.addImport("evm", modules.evm_mod);
        official_chain_test.root_module.addImport("primitives", modules.primitives_mod);
        official_chain_test.root_module.addImport("crypto", modules.crypto_mod);
        official_chain_test.root_module.addImport("build_options", config.options_mod);

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
        });
        
        // Add module imports needed by the test
        synthetic_test.root_module.addImport("primitives", modules.primitives_mod);
        synthetic_test.root_module.addImport("crypto", modules.crypto_mod);
        synthetic_test.root_module.addImport("build_options", config.options_mod);
        
        synthetic_test.linkLibrary(c_kzg_lib);
        synthetic_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| synthetic_test.linkLibrary(bn254);
        synthetic_test.linkLibC();
        
        const run_synthetic_test = b.addRunArtifact(synthetic_test);
        const synthetic_step = b.step("test-synthetic", "Test synthetic opcodes");
        synthetic_step.dependOn(&run_synthetic_test.step);
    }

    // Language bindings
    build_pkg.WasmBindings.createWasmSteps(b, optimize, config.options_mod);
    build_pkg.PythonBindings.createPythonSteps(b);
    build_pkg.SwiftBindings.createSwiftSteps(b);
    build_pkg.GoBindings.createGoSteps(b);
    build_pkg.TypeScriptBindings.createTypeScriptSteps(b);

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
        });
        fusions_basic.root_module.addImport("evm", modules.evm_mod);
        fusions_basic.root_module.addImport("primitives", modules.primitives_mod);
        fusions_basic.root_module.addImport("crypto", modules.crypto_mod);
        fusions_basic.root_module.addImport("build_options", config.options_mod);
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
        });
        fusions_dispatch.root_module.addImport("evm", modules.evm_mod);
        fusions_dispatch.root_module.addImport("primitives", modules.primitives_mod);
        fusions_dispatch.root_module.addImport("crypto", modules.crypto_mod);
        fusions_dispatch.root_module.addImport("build_options", config.options_mod);
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
        });
        fusions_diff_toggle.root_module.addImport("evm", modules.evm_mod);
        fusions_diff_toggle.root_module.addImport("primitives", modules.primitives_mod);
        fusions_diff_toggle.root_module.addImport("crypto", modules.crypto_mod);
        fusions_diff_toggle.root_module.addImport("build_options", config.options_mod);
        fusions_diff_toggle.root_module.addImport("log", b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = .Debug }));
        if (modules.revm_mod) |revm_mod| {
            fusions_diff_toggle.root_module.addImport("revm", revm_mod);
            if (revm_lib) |revm| {
                fusions_diff_toggle.linkLibrary(revm);
                fusions_diff_toggle.addIncludePath(b.path("lib/revm"));
                const revm_rust_target_dir_test = if (optimize == .Debug) "debug" else "release";
                const revm_dylib_path_test = if (rust_target) |target_triple|
                    b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir_test })
                else
                    b.fmt("target/{s}/librevm_wrapper.dylib", .{revm_rust_target_dir_test});
                fusions_diff_toggle.addObjectFile(b.path(revm_dylib_path_test));
            }
        }
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
}
