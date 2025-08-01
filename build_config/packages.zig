const std = @import("std");
const rust_build = @import("../build_utils/rust_build.zig");

pub const PackageConfig = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    no_precompiles: bool,
    no_bn254: bool,
    rust_target: ?[]const u8,
};

pub fn createAllPackages(config: PackageConfig) Packages {
    const b = config.b;
    const target = config.target;
    const optimize = config.optimize;
    
    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "no_precompiles", config.no_precompiles);
    build_options.addOption(bool, "no_bn254", config.no_bn254);
    
    // Create primitives module
    const primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Create crypto module
    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_mod.addImport("primitives", primitives_mod);
    
    // Create utils module
    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Create the trie module
    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/trie/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    trie_mod.addImport("primitives", primitives_mod);
    trie_mod.addImport("utils", utils_mod);
    
    // Create the provider module
    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_mod.addImport("primitives", primitives_mod);
    
    // BN254 Rust library integration
    const bn254_lib = if (!config.no_bn254 and config.rust_target != null) rust_build.buildRustLibrary(b, target, optimize, .{
        .name = "bn254_wrapper",
        .manifest_path = "src/bn254_wrapper/Cargo.toml",
        .target_triple = config.rust_target,
        .profile = if (optimize == .Debug) .dev else .release,
        .library_type = .static_lib,
    }) else null;
    
    // Add include path for C header if BN254 is enabled
    if (bn254_lib) |lib| {
        lib.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    // C-KZG-4844 Zig bindings
    const c_kzg_dep = b.dependency("c_kzg_4844", .{
        .target = target,
        .optimize = optimize,
    });
    const c_kzg_lib = c_kzg_dep.artifact("c_kzg_4844");
    primitives_mod.linkLibrary(c_kzg_lib);
    
    // Create the main evm module
    const evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_mod.addImport("primitives", primitives_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("build_options", build_options.createModule());
    
    // Link BN254 Rust library to EVM module (if enabled)
    if (bn254_lib) |lib| {
        evm_mod.linkLibrary(lib);
        evm_mod.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    // Link c-kzg library to EVM module
    evm_mod.linkLibrary(c_kzg_lib);
    
    // REVM Rust wrapper integration
    const revm_lib = if (config.rust_target != null) blk: {
        const revm_rust_build = rust_build.buildRustLibrary(b, target, optimize, .{
            .name = "revm_wrapper",
            .manifest_path = "src/revm_wrapper/Cargo.toml",
            .target_triple = config.rust_target,
            .profile = if (optimize == .Debug) .dev else .release,
            .library_type = .dynamic_lib,
            .verbose = true,
        });
        break :blk revm_rust_build;
    } else null;
    
    // Create REVM module
    const revm_mod = b.createModule(.{
        .root_source_file = b.path("src/revm_wrapper/revm.zig"),
        .target = target,
        .optimize = optimize,
    });
    revm_mod.addImport("primitives", primitives_mod);
    
    // Link REVM Rust library if available
    if (revm_lib) |lib| {
        revm_mod.linkLibrary(lib);
        revm_mod.addIncludePath(b.path("src/revm_wrapper"));
        
        // Also link the dynamic library directly to the module
        const revm_rust_target_dir = if (optimize == .Debug) "debug" else "release";
        const revm_dylib_path = if (config.rust_target) |target_triple|
            b.fmt("target/{s}/{s}/librevm_wrapper.dylib", .{ target_triple, revm_rust_target_dir })
        else
            b.fmt("target/{s}/librevm_wrapper.dylib", .{ revm_rust_target_dir });
        revm_mod.addObjectFile(b.path(revm_dylib_path));
        
        // Link additional libraries needed by revm
        if (target.result.os.tag == .linux) {
            lib.linkSystemLibrary("m");
            lib.linkSystemLibrary("pthread");
            lib.linkSystemLibrary("dl");
        } else if (target.result.os.tag == .macos) {
            lib.linkSystemLibrary("c++");
            lib.linkFramework("Security");
            lib.linkFramework("SystemConfiguration");
            lib.linkFramework("CoreFoundation");
        }
    }
    
    // EVM Benchmark Rust crate integration
    const evm_bench_lib = if (config.rust_target != null) blk: {
        const guillotine_rust_build = rust_build.buildRustLibrary(b, target, optimize, .{
            .name = "guillotine_ffi",
            .manifest_path = "src/guillotine-rs/Cargo.toml",
            .target_triple = config.rust_target,
            .profile = if (optimize == .Debug) .dev else .release,
            .library_type = .rlib,
            .verbose = true,
        });
        break :blk guillotine_rust_build;
    } else null;
    
    // Create compilers module
    const compilers_mod = b.createModule(.{
        .root_source_file = b.path("src/compilers/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    compilers_mod.addImport("primitives", primitives_mod);
    compilers_mod.addImport("evm", evm_mod);
    
    // Create the main library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path("src/bn254_wrapper"));
    
    // Add modules to lib_mod
    lib_mod.addImport("primitives", primitives_mod);
    lib_mod.addImport("crypto", crypto_mod);
    lib_mod.addImport("evm", evm_mod);
    lib_mod.addImport("provider", provider_mod);
    lib_mod.addImport("compilers", compilers_mod);
    lib_mod.addImport("trie", trie_mod);
    if (revm_lib != null) {
        lib_mod.addImport("revm", revm_mod);
    }
    
    // Create clap dependency for orchestrator
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    
    return .{
        .lib_mod = lib_mod,
        .primitives_mod = primitives_mod,
        .crypto_mod = crypto_mod,
        .utils_mod = utils_mod,
        .trie_mod = trie_mod,
        .provider_mod = provider_mod,
        .evm_mod = evm_mod,
        .revm_mod = if (revm_lib != null) revm_mod else null,
        .compilers_mod = compilers_mod,
        .build_options = build_options,
        .bn254_lib = bn254_lib,
        .c_kzg_lib = c_kzg_lib,
        .revm_lib = revm_lib,
        .evm_bench_lib = evm_bench_lib,
        .clap_dep = clap_dep,
    };
}

pub fn createBenchPackages(config: PackageConfig) BenchPackages {
    const b = config.b;
    const target = config.target;
    
    // Always use ReleaseFast for benchmarks
    const bench_optimize = if (config.optimize == .Debug) .ReleaseFast else config.optimize;
    
    // Get base packages for dependencies
    const base_config = PackageConfig{
        .b = b,
        .target = target,
        .optimize = config.optimize,
        .no_precompiles = config.no_precompiles,
        .no_bn254 = config.no_bn254,
        .rust_target = config.rust_target,
    };
    const base_packages = createAllPackages(base_config);
    
    // Create a separate BN254 library for benchmarks that always uses release mode
    const bench_bn254_lib = if (!config.no_bn254 and config.rust_target != null) blk: {
        const bench_bn254_rust_build = rust_build.buildRustLibrary(b, target, bench_optimize, .{
            .name = "bn254_wrapper",
            .manifest_path = "src/bn254_wrapper/Cargo.toml",
            .target_triple = config.rust_target,
            .profile = .release, // Always use release for benchmarks
            .library_type = .static_lib,
            .verbose = true,
        });
        
        // Add include path for C header
        bench_bn254_rust_build.addIncludePath(b.path("src/bn254_wrapper"));
        
        break :blk bench_bn254_rust_build;
    } else null;
    
    // Create a separate EVM module for benchmarks with release-mode Rust dependencies
    const bench_evm_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_evm_mod.addImport("primitives", base_packages.primitives_mod);
    bench_evm_mod.addImport("crypto", base_packages.crypto_mod);
    bench_evm_mod.addImport("build_options", base_packages.build_options.createModule());
    
    // Link BN254 Rust library to bench EVM module (if enabled)
    if (bench_bn254_lib) |lib| {
        bench_evm_mod.linkLibrary(lib);
        bench_evm_mod.addIncludePath(b.path("src/bn254_wrapper"));
    }
    
    // Link c-kzg library to bench EVM module
    bench_evm_mod.linkLibrary(base_packages.c_kzg_lib);
    
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = bench_optimize,
    });
    
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_mod.addImport("primitives", base_packages.primitives_mod);
    bench_mod.addImport("evm", bench_evm_mod);  // Use the bench-specific EVM module
    bench_mod.addImport("zbench", zbench_dep.module("zbench"));
    if (base_packages.revm_mod != null) {
        bench_mod.addImport("revm", base_packages.revm_mod.?);
    }
    
    // Add bench module to lib_mod
    base_packages.lib_mod.addImport("bench", bench_mod);
    
    return .{
        .bench_mod = bench_mod,
        .bench_evm_mod = bench_evm_mod,
        .zbench_dep = zbench_dep,
        .bench_bn254_lib = bench_bn254_lib,
    };
}

pub fn createWasmPackages(b: *std.Build) WasmPackages {
    const wasm = @import("../build_utils/wasm.zig");
    
    const wasm_target = wasm.setupWasmTarget(b);
    const wasm_optimize = .ReleaseSmall;
    
    // Create WASM-specific modules with minimal dependencies
    const wasm_primitives_mod = wasm.createWasmModule(b, "src/primitives/root.zig", wasm_target, wasm_optimize);
    // Note: WASM build excludes c-kzg-4844 (not available for WASM)
    
    const wasm_crypto_mod = wasm.createWasmModule(b, "src/crypto/root.zig", wasm_target, wasm_optimize);
    wasm_crypto_mod.addImport("primitives", wasm_primitives_mod);
    
    // Build options for WASM (no precompiles)
    const build_options = b.addOptions();
    build_options.addOption(bool, "no_precompiles", true);
    build_options.addOption(bool, "no_bn254", true);
    
    const wasm_evm_mod = wasm.createWasmModule(b, "src/evm/root.zig", wasm_target, wasm_optimize);
    wasm_evm_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_mod.addImport("crypto", wasm_crypto_mod);
    wasm_evm_mod.addImport("build_options", build_options.createModule());
    // Note: WASM build uses pure Zig implementations for BN254 operations
    
    // Main WASM build (includes both primitives and EVM)
    const wasm_lib_mod = wasm.createWasmModule(b, "src/root.zig", wasm_target, wasm_optimize);
    wasm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_lib_mod.addImport("evm", wasm_evm_mod);
    
    // Primitives-only WASM build
    const wasm_primitives_lib_mod = wasm.createWasmModule(b, "src/primitives_c.zig", wasm_target, wasm_optimize);
    wasm_primitives_lib_mod.addImport("primitives", wasm_primitives_mod);
    
    // EVM-only WASM build
    const wasm_evm_lib_mod = wasm.createWasmModule(b, "src/evm_c.zig", wasm_target, wasm_optimize);
    wasm_evm_lib_mod.addImport("primitives", wasm_primitives_mod);
    wasm_evm_lib_mod.addImport("evm", wasm_evm_mod);
    
    return .{
        .wasm_lib_mod = wasm_lib_mod,
        .wasm_primitives_lib_mod = wasm_primitives_lib_mod,
        .wasm_evm_lib_mod = wasm_evm_lib_mod,
        .wasm_primitives_mod = wasm_primitives_mod,
        .wasm_crypto_mod = wasm_crypto_mod,
        .wasm_evm_mod = wasm_evm_mod,
        .wasm_target = wasm_target,
        .wasm_optimize = wasm_optimize,
    };
}

pub const Packages = struct {
    lib_mod: *std.Build.Module,
    primitives_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    utils_mod: *std.Build.Module,
    trie_mod: *std.Build.Module,
    provider_mod: *std.Build.Module,
    evm_mod: *std.Build.Module,
    revm_mod: ?*std.Build.Module,
    compilers_mod: *std.Build.Module,
    build_options: *std.Build.Step.Options,
    bn254_lib: ?*std.Build.Step.Compile,
    c_kzg_lib: *std.Build.Step.Compile,
    revm_lib: ?*std.Build.Step.Compile,
    evm_bench_lib: ?*std.Build.Step.Compile,
    clap_dep: *std.Build.Dependency,
};

pub const BenchPackages = struct {
    bench_mod: *std.Build.Module,
    bench_evm_mod: *std.Build.Module,
    zbench_dep: *std.Build.Dependency,
    bench_bn254_lib: ?*std.Build.Step.Compile,
};

pub const WasmPackages = struct {
    wasm_lib_mod: *std.Build.Module,
    wasm_primitives_lib_mod: *std.Build.Module,
    wasm_evm_lib_mod: *std.Build.Module,
    wasm_primitives_mod: *std.Build.Module,
    wasm_crypto_mod: *std.Build.Module,
    wasm_evm_mod: *std.Build.Module,
    wasm_target: std.Build.ResolvedTarget,
    wasm_optimize: std.builtin.OptimizeMode,
};