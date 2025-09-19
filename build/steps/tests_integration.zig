const std = @import("std");
const Modules = @import("../modules.zig");

pub fn createIntegrationTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: Modules.ModuleSet,
    bn254_lib: ?*std.Build.Step.Compile,
    c_kzg_lib: *std.Build.Step.Compile,
    blst_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    // Zig 0.15 switched from LLVM to Zig's self-hosted x86_64 backend, but it lacks tail call support.
    // Force LLVM backend on x86_64 to maintain tail call optimization for EVM dispatch performance
    const use_llvm = if (target.result.cpu.arch == .x86_64) true else null;
    
    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
    });
    
    // Add all necessary imports to integration tests
    integration_tests.root_module.addImport("evm", modules.evm_mod);
    integration_tests.root_module.addImport("primitives", modules.primitives_mod);
    integration_tests.root_module.addImport("crypto", modules.crypto_mod);
    integration_tests.root_module.addImport("compilers", modules.compilers_mod);
    integration_tests.root_module.addImport("provider", modules.provider_mod);
    integration_tests.root_module.addImport("trie", modules.trie_mod);
    integration_tests.root_module.addImport("Guillotine_lib", modules.lib_mod);

    // REVM module removed - using MinimalEvm for differential testing
    
    if (bn254_lib) |bn254| {
        integration_tests.linkLibrary(bn254);
        integration_tests.addIncludePath(b.path("lib/ark"));
    }
    
    integration_tests.linkLibrary(c_kzg_lib);
    integration_tests.linkLibrary(blst_lib);
    
    return integration_tests;
}