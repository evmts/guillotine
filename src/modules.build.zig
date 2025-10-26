const std = @import("std");

pub const ModuleSet = struct {
    lib_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    precompiles_mod: *std.Build.Module,
    trie_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    evm_mod: *std.Build.Module,
    compilers_mod: *std.Build.Module,
    c_kzg_mod: *std.Build.Module,
    // fixtures_mod removed - only for testing/benchmarking, not in package distribution
    // revm_mod removed - using MinimalEvm for differential testing
    exe_mod: *std.Build.Module,
};

pub fn createModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
    primitives_dep: *std.Build.Dependency,
    bn254_lib: ?*std.Build.Step.Compile,
    foundry_lib: ?*std.Build.Step.Compile,
) ModuleSet {
    // Use primitives package modules (primitives, crypto, precompiles, c_kzg)
    const primitives_mod = primitives_dep.module("primitives");
    const crypto_mod = primitives_dep.module("crypto");
    const precompiles_mod = primitives_dep.module("precompiles");
    const c_kzg_mod = primitives_dep.module("c_kzg");

    // Trie module
    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/trie/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    trie_mod.addImport("primitives", primitives_mod);

    // Provider module
    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_mod.addImport("primitives", primitives_mod);

    // EVM module - unified src module
    const evm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_mod.addImport("primitives", primitives_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("precompiles", precompiles_mod);
    evm_mod.addImport("build_options", build_options_mod);
    // zbench import removed - only needed for *_bench.zig files in benchmark executables
    // revm include path removed

    if (bn254_lib) |bn254| {
        evm_mod.linkLibrary(bn254);
        evm_mod.addIncludePath(b.path("lib/ark"));
    }

    // REVM module removed - using MinimalEvm for differential testing

    // Compilers module
    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("lib/foundry-compilers/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("primitives", primitives_mod);
    compilers_mod.addImport("evm", evm_mod);

    // Link with foundry library if available
    if (foundry_lib) |lib| {
        compilers_mod.linkLibrary(lib);
        compilers_mod.addIncludePath(b.path("lib/foundry-compilers"));
    }

    // Main library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path("lib/ark"));
    lib_mod.addImport("build_options", build_options_mod);
    lib_mod.addImport("primitives", primitives_mod);
    lib_mod.addImport("crypto", crypto_mod);
    lib_mod.addImport("precompiles", precompiles_mod);
    // evm_mod is not needed since lib_mod IS the evm module now
    lib_mod.addImport("provider", provider_mod);
    lib_mod.addImport("compilers", compilers_mod);
    lib_mod.addImport("trie", trie_mod);
    // REVM import removed - using MinimalEvm for differential testing


    // Executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize
    });
    exe_mod.addImport("Guillotine_lib", lib_mod);

    return ModuleSet{
        .lib_mod = lib_mod,
        .primitives_mod = primitives_mod,
        .crypto_mod = crypto_mod,
        .precompiles_mod = precompiles_mod,
        .trie_mod = trie_mod,
        .provider_mod = provider_mod,
        .evm_mod = evm_mod,
        .compilers_mod = compilers_mod,
        .c_kzg_mod = c_kzg_mod,
        .exe_mod = exe_mod,
    };
}