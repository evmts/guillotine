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
    exe_mod: *std.Build.Module,
    layer2_mod: *std.Build.Module,
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
    // Use voltaire package modules (voltaire, crypto, precompiles, c_kzg)
    const primitives_mod = primitives_dep.module("voltaire");
    const crypto_mod = primitives_dep.module("crypto");
    const precompiles_mod = primitives_dep.module("precompiles");
    const c_kzg_mod = primitives_dep.module("c_kzg");

    // Trie module
    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/trie/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    trie_mod.addImport("voltaire", primitives_mod);

    // Provider module
    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_mod.addImport("voltaire", primitives_mod);

    // EVM module - unified src module
    // Opcode handlers are a chain of guaranteed tail calls that never return through
    // each other, so a frame pointer buys nothing there and costs a push/pop per
    // instruction. Optimized builds drop it; Debug and ReleaseSafe keep it for traces.
    const omit_frame_pointer: ?bool = if (optimize == .fast or optimize == .small) true else null;

    // `evm`, `voltaire` and `layer2` are the package's public modules:
    // a consumer reaches them with `dep.module("evm")` and so on.
    const evm_mod = b.addModule("evm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
    });
    evm_mod.addImport("voltaire", primitives_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("precompiles", precompiles_mod);
    evm_mod.addImport("build_options", build_options_mod);

    if (bn254_lib) |bn254| {
        evm_mod.linkLibrary(bn254);
        evm_mod.addIncludePath(b.path("lib/ark"));
    }

    // Voltaire's primitives module comes from the vendored dependency; publish
    // that same module rather than a second module over the same files.
    b.modules.put(b.graph.arena, "voltaire", primitives_mod) catch @panic("OOM registering the voltaire module");

    // Layer 2 (Base and OP Stack). Its root re-exports `evm.layer2`, because the
    // `evm` module owns src/layer2/mod.zig.
    const layer2_mod = b.addModule("layer2", .{
        .root_source_file = b.path("src/layer2_package.zig"),
        .target = target,
        .optimize = optimize,
    });
    layer2_mod.addImport("evm", evm_mod);
    layer2_mod.addImport("voltaire", primitives_mod);

    const compilers_mod = createCompilersModule(b, target, optimize, primitives_mod, evm_mod, foundry_lib);
    const root_mods = createLibAndExeModules(
        b,
        target,
        optimize,
        omit_frame_pointer,
        build_options_mod,
        primitives_mod,
        crypto_mod,
        precompiles_mod,
        provider_mod,
        compilers_mod,
        trie_mod,
    );

    return ModuleSet{
        .lib_mod = root_mods.lib_mod,
        .primitives_mod = primitives_mod,
        .crypto_mod = crypto_mod,
        .precompiles_mod = precompiles_mod,
        .trie_mod = trie_mod,
        .provider_mod = provider_mod,
        .evm_mod = evm_mod,
        .compilers_mod = compilers_mod,
        .c_kzg_mod = c_kzg_mod,
        .exe_mod = root_mods.exe_mod,
        .layer2_mod = layer2_mod,
    };
}

fn createCompilersModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    primitives_mod: *std.Build.Module,
    evm_mod: *std.Build.Module,
    foundry_lib: ?*std.Build.Step.Compile,
) *std.Build.Module {
    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("lib/foundry-compilers/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("voltaire", primitives_mod);
    compilers_mod.addImport("evm", evm_mod);
    const foundry_wrapper_c = b.addTranslateC(.{
        .root_source_file = b.path("lib/foundry-compilers/foundry_wrapper.h"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("foundry_wrapper_c", foundry_wrapper_c.createModule());
    if (foundry_lib) |lib| {
        compilers_mod.linkLibrary(lib);
        compilers_mod.addIncludePath(b.path("lib/foundry-compilers"));
    }
    return compilers_mod;
}

fn createLibAndExeModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    omit_frame_pointer: ?bool,
    build_options_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    precompiles_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    compilers_mod: *std.Build.Module,
    trie_mod: *std.Build.Module,
) struct { lib_mod: *std.Build.Module, exe_mod: *std.Build.Module } {
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
    });
    lib_mod.addIncludePath(b.path("lib/ark"));
    lib_mod.addImport("build_options", build_options_mod);
    lib_mod.addImport("voltaire", primitives_mod);
    lib_mod.addImport("crypto", crypto_mod);
    lib_mod.addImport("precompiles", precompiles_mod);
    lib_mod.addImport("provider", provider_mod);
    lib_mod.addImport("compilers", compilers_mod);
    lib_mod.addImport("trie", trie_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("Guillotine_lib", lib_mod);
    return .{ .lib_mod = lib_mod, .exe_mod = exe_mod };
}

test "createModules builder function is exported" {
    try std.testing.expect(@typeInfo(@TypeOf(createModules)) == .@"fn");
}
