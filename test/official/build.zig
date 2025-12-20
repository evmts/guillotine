const std = @import("std");

const OfficialTestSteps = struct {
    state: *std.Build.Step,
    blockchain: *std.Build.Step,
};

pub fn createOfficialTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: anytype,
    config_options_mod: *std.Build.Module,
    c_kzg_lib: *std.Build.Step.Compile,
    blst_lib: *std.Build.Step.Compile,
    bn254_lib: ?*std.Build.Step.Compile,
) OfficialTestSteps {
    // Official execution-spec state fixture smoke test
    var official_state_step: *std.Build.Step = undefined;
    {
        const official_state_test = b.addTest(.{
            .name = "official_state_fixtures_smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/official/state_smoke_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });

        // Add required imports
        official_state_test.root_module.addImport("evm", modules.evm_mod);
        official_state_test.root_module.addImport("voltaire", modules.primitives_mod);
        official_state_test.root_module.addImport("crypto", modules.crypto_mod);
        official_state_test.root_module.addImport("build_options", config_options_mod);

        // Link libraries used by EVM
        official_state_test.linkLibrary(c_kzg_lib);
        official_state_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| official_state_test.linkLibrary(bn254);
        official_state_test.linkLibC();

        const run_official_state_test = b.addRunArtifact(official_state_test);
        // Non-strict by default to avoid failing on WIP EVM differences
        run_official_state_test.setEnvironmentVariable("OFFICIAL_STRICT", "0");
        official_state_step = b.step("test-official", "Run execution-spec state fixture smoke test (non-strict)");
        official_state_step.dependOn(&run_official_state_test.step);

        // Strict mode (will compare post-state and likely fail until parity improves)
        const run_official_state_test_strict = b.addRunArtifact(official_state_test);
        run_official_state_test_strict.setEnvironmentVariable("OFFICIAL_STRICT", "1");
        const official_state_strict_step = b.step("test-official-strict", "Run execution-spec state fixture smoke test (strict)");
        official_state_strict_step.dependOn(&run_official_state_test_strict.step);
    }

    // Official execution-spec blockchain fixture smoke test
    var official_chain_step: *std.Build.Step = undefined;
    {
        const official_chain_test = b.addTest(.{
            .name = "official_blockchain_fixtures_smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/official/blockchain_smoke_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });

        official_chain_test.root_module.addImport("evm", modules.evm_mod);
        official_chain_test.root_module.addImport("voltaire", modules.primitives_mod);
        official_chain_test.root_module.addImport("crypto", modules.crypto_mod);
        official_chain_test.root_module.addImport("build_options", config_options_mod);

        official_chain_test.linkLibrary(c_kzg_lib);
        official_chain_test.linkLibrary(blst_lib);
        if (bn254_lib) |bn254| official_chain_test.linkLibrary(bn254);
        official_chain_test.linkLibC();

        const run_official_chain_test = b.addRunArtifact(official_chain_test);
        run_official_chain_test.setEnvironmentVariable("OFFICIAL_STRICT", "0");
        official_chain_step = b.step("test-official-blockchain", "Run execution-spec blockchain fixture smoke test (non-strict)");
        official_chain_step.dependOn(&run_official_chain_test.step);

        const run_official_chain_test_strict = b.addRunArtifact(official_chain_test);
        run_official_chain_test_strict.setEnvironmentVariable("OFFICIAL_STRICT", "1");
        const official_chain_strict_step = b.step("test-official-blockchain-strict", "Run execution-spec blockchain fixture smoke test (strict)");
        official_chain_strict_step.dependOn(&run_official_chain_test_strict.step);
    }

    // Return the non-strict steps for main test
    return .{
        .state = official_state_step,
        .blockchain = official_chain_step,
    };
}