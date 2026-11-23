//! Registers standalone ReleaseFast subsystem microbenchmark binaries.
//! Each binary links ONLY its own minimal Zig dependency closure so Smithers
//! PACKAGE.ts targets compile and run incrementally per subsystem.
const std = @import("std");

pub const SuiteOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    directory: std.Build.LazyPath,
    repository: std.Build.LazyPath,
    evm: *std.Build.Module,
    voltaire: *std.Build.Module,
    crypto: *std.Build.Module,
    precompiles: *std.Build.Module,
    build_options: *std.Build.Module,
    native_archive: ?std.Build.LazyPath = null,
};

fn addSuite(
    b: *std.Build,
    name: []const u8,
    mod: *std.Build.Module,
    repository: std.Build.LazyPath,
    link_libc: bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = b.fmt("bench-{s}", .{name}),
        .root_module = mod,
        .use_llvm = true,
    });
    if (link_libc) exe.linkLibC();

    const build_step = b.step(
        b.fmt("bench-{s}-build", .{name}),
        b.fmt("Build {s} subsystem microbenchmarks (ReleaseFast)", .{name}),
    );
    build_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run = b.addRunArtifact(exe);
    run.setCwd(repository);
    run.has_side_effects = true;
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step(
        b.fmt("bench-{s}", .{name}),
        b.fmt("Run {s} subsystem microbenchmarks (ReleaseFast)", .{name}),
    );
    run_step.dependOn(&run.step);

    return exe;
}

pub fn addSuiteSteps(b: *std.Build, opts: SuiteOptions) void {
    const micro_mod = b.createModule(.{
        .root_source_file = opts.directory.path(b, "micro.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const pure_mod = b.createModule(.{
        .root_source_file = opts.repository.path(b, "src/pure_exports.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const voltaire_exports = b.createModule(.{
        .root_source_file = opts.repository.path(b, "src/voltaire_exports.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    voltaire_exports.addImport("voltaire", opts.voltaire);

    // 1. Stack
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/stack_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("stack", voltaire_exports);
        _ = addSuite(b, "stack", mod, opts.repository, true);
    }

    // 2. Memory (pure Zig, zero external deps)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/memory_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("memory", pure_mod);
        _ = addSuite(b, "memory", mod, opts.repository, false);
    }

    // 3. Bytecode analysis (src/bytecode + src/opcodes + src/log)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/bytecode_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("bytecode", pure_mod);
        _ = addSuite(b, "bytecode", mod, opts.repository, false);
    }

    // 4. Layer2 (Optimism / Base FastLZ & DA footprint)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/layer2_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("layer2", voltaire_exports);
        _ = addSuite(b, "layer2", mod, opts.repository, true);
    }

    // 5. Provider (validation, JSON-RPC)
    {
        const prov_mod = b.createModule(.{
            .root_source_file = opts.repository.path(b, "src/provider/root.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        prov_mod.addImport("voltaire", opts.voltaire);
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/provider_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("provider", prov_mod);
        _ = addSuite(b, "provider", mod, opts.repository, true);
    }

    // 6. Storage (Database, Journal, AccessList, LruCache)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/storage_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("voltaire", opts.voltaire);
        mod.addImport("storage_db", voltaire_exports);
        mod.addImport("storage_journal", voltaire_exports);
        mod.addImport("storage_access_list", voltaire_exports);
        mod.addImport("storage_lru", voltaire_exports);
        _ = addSuite(b, "storage", mod, opts.repository, true);
    }

    // 7. Trie (MerkleTrie, HashBuilderOptimized, NodeCache)
    {
        const trie_mod = b.createModule(.{
            .root_source_file = opts.repository.path(b, "src/trie/module.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        trie_mod.addImport("voltaire", opts.voltaire);
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/trie_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("trie", trie_mod);
        _ = addSuite(b, "trie", mod, opts.repository, true);
    }

    // 8. EIPs & Hardforks
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/eips_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("voltaire", opts.voltaire);
        mod.addImport("eips", voltaire_exports);
        _ = addSuite(b, "eips", mod, opts.repository, true);
    }

    // 9. Tracer (RingBuffer)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/tracer_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("ring_buffer", pure_mod);
        _ = addSuite(b, "tracer", mod, opts.repository, false);
    }

    // 10. Preprocessor (Dispatch schedule compilation & JumpTable lookup)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/preprocessor_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("guillotine", opts.evm);
        _ = addSuite(b, "preprocessor", mod, opts.repository, true);
    }

    // 11. Crypto & Primitives (Keccak, SHA256, ModExp, Uint256, Secp256k1)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/crypto_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("voltaire", opts.voltaire);
        mod.addImport("crypto", opts.crypto);
        _ = addSuite(b, "crypto", mod, opts.repository, true);
    }

    // 12. MinimalEvm (reference sequential interpreter)
    {
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/minimal_evm_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("guillotine", opts.evm);
        _ = addSuite(b, "minimal-evm", mod, opts.repository, true);
    }

    // 13. C FFI boundary
    {
        const c_api_mod = b.createModule(.{
            .root_source_file = opts.repository.path(b, "src/evm_c_api.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        c_api_mod.addImport("evm", opts.evm);
        c_api_mod.addImport("voltaire", opts.voltaire);
        c_api_mod.addImport("crypto", opts.crypto);
        c_api_mod.addImport("build_options", opts.build_options);
        const mod = b.createModule(.{
            .root_source_file = opts.directory.path(b, "suites/ffi_bench.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("micro", micro_mod);
        mod.addImport("evm_c_api", c_api_mod);
        _ = addSuite(b, "ffi", mod, opts.repository, true);
    }

    // Unit test for micro.zig harness
    const micro_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = opts.directory.path(b, "micro.zig"),
            .target = opts.target,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    const test_micro = b.step("test-micro-bench", "Test the microbenchmark harness");
    test_micro.dependOn(&b.addRunArtifact(micro_tests).step);
}
