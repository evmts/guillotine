const std = @import("std");
const modules = @import("modules.zig");
const rust = @import("rust.zig");

pub fn setupFuzzing(b: *std.Build, mods: modules.Modules, rust_libs: rust.RustLibraries, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // BN254 fuzz tests
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

    // ECMUL precompile fuzz tests
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

    // ECPAIRING precompile fuzz tests
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

    // BN254 comparison fuzz test (Zig vs Rust)
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

    // Master fuzz test step that runs all fuzz tests
    const fuzz_all_step = b.step("fuzz", "Run all fuzz tests (use: zig build fuzz -- --fuzz)");
    fuzz_all_step.dependOn(&run_bn254_fuzz_test.step);
    fuzz_all_step.dependOn(&run_ecmul_fuzz_test.step);
    fuzz_all_step.dependOn(&run_ecpairing_fuzz_test.step);
    fuzz_all_step.dependOn(&run_bn254_comparison_fuzz_test.step);
}