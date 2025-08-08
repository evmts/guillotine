const std = @import("std");

pub const ModuleConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    no_precompiles: bool,
    no_bn254: bool,
};

pub fn createModules(b: *std.Build, config: ModuleConfig) Modules {
    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "no_precompiles", config.no_precompiles);
    build_options.addOption(bool, "no_bn254", config.no_bn254);
    const build_options_mod = build_options.createModule();

    // Create primitives module
    const primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    // Create crypto module
    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    crypto_mod.addImport("primitives", primitives_mod);

    // Create utils module
    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    // Create the trie module
    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/trie/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    trie_mod.addImport("primitives", primitives_mod);
    trie_mod.addImport("utils", utils_mod);

    // Create the provider module
    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    provider_mod.addImport("primitives", primitives_mod);

    // Create the main evm module that exports everything
    const evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    evm_mod.addImport("primitives", primitives_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("build_options", build_options_mod);

    // Create compilers module
    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("src/compilers/package.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    compilers_mod.addImport("primitives", primitives_mod);
    compilers_mod.addImport("evm", evm_mod);

    // Create main library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    lib_mod.addIncludePath(b.path("src/bn254_wrapper"));
    lib_mod.addImport("build_options", build_options_mod);
    lib_mod.addImport("primitives", primitives_mod);
    lib_mod.addImport("crypto", crypto_mod);
    lib_mod.addImport("evm", evm_mod);
    lib_mod.addImport("provider", provider_mod);
    lib_mod.addImport("compilers", compilers_mod);
    lib_mod.addImport("trie", trie_mod);

    // Create executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    exe_mod.addImport("Guillotine_lib", lib_mod);

    return .{
        .build_options = build_options_mod,
        .primitives = primitives_mod,
        .crypto = crypto_mod,
        .utils = utils_mod,
        .trie = trie_mod,
        .provider = provider_mod,
        .evm = evm_mod,
        .compilers = compilers_mod,
        .lib = lib_mod,
        .exe = exe_mod,
    };
}

pub const Modules = struct {
    build_options: *std.Build.Module,
    primitives: *std.Build.Module,
    crypto: *std.Build.Module,
    utils: *std.Build.Module,
    trie: *std.Build.Module,
    provider: *std.Build.Module,
    evm: *std.Build.Module,
    compilers: *std.Build.Module,
    lib: *std.Build.Module,
    exe: *std.Build.Module,
};

pub fn createWasmModules(b: *std.Build, wasm_target: std.Build.ResolvedTarget, wasm_optimize: std.builtin.OptimizeMode, build_options_mod: *std.Build.Module) WasmModules {
    // Create WASM-specific modules with minimal dependencies
    const wasm_primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });

    const wasm_crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_crypto_mod.addImport("primitives", wasm_primitives_mod);

    const wasm_evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_evm_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options_mod);

    // Main WASM build (includes both primitives and EVM)
    const wasm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_lib_mod.addImport("evm", wasm_evm_mod);

    // Primitives-only WASM build
    const wasm_primitives_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives_c.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_primitives_lib_mod.addImport("primitives", wasm_primitives_mod);

    // EVM-only WASM build
    const wasm_evm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/evm_c.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_evm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_lib_mod.addImport("evm", wasm_evm_mod);

    return .{
        .primitives = wasm_primitives_mod,
        .crypto = wasm_crypto_mod,
        .evm = wasm_evm_mod,
        .lib = wasm_lib_mod,
        .primitives_lib = wasm_primitives_lib_mod,
        .evm_lib = wasm_evm_lib_mod,
    };
}

pub const WasmModules = struct {
    primitives: *std.Build.Module,
    crypto: *std.Build.Module,
    evm: *std.Build.Module,
    lib: *std.Build.Module,
    primitives_lib: *std.Build.Module,
    evm_lib: *std.Build.Module,
};