const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Get the voltaire dependency (vendored primitives from parent repo)
    const voltaire_dep = b.dependency("voltaire", .{
        .target = target,
        .optimize = optimize,
    });

    // Use voltaire package exported modules (aliased as "primitives" for source compatibility)
    const primitives_mod = voltaire_dep.module("voltaire");
    const crypto_mod = voltaire_dep.module("crypto");
    const precompiles_mod = voltaire_dep.module("precompiles");

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("guillotine_mini", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "precompiles", .module = precompiles_mod },
            .{ .name = "crypto", .module = crypto_mod },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // business logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // Main executable removed - this is a library-only package

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the relative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests (includes unit tests + spec tests)
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Unit tests only (fast, no spec tests)
    const unit_test_step = b.step("unit", "Run unit tests only (fast)");
    unit_test_step.dependOn(&run_mod_tests.step);

    // Create EVM module for spec tests
    const evm_mod = b.addModule("evm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "precompiles", .module = precompiles_mod },
            .{ .name = "crypto", .module = crypto_mod },
        },
    });

    // Add execution-specs tests
    // Build option to force refreshing the generated Python fixtures
    const refresh_specs_opt = b.option(bool, "refresh-specs", "Force refresh of execution-specs fixtures");
    const force_refresh = refresh_specs_opt orelse false;

    // First, add a build step to generate test fixtures using Python fill command
    const fill_specs = if (force_refresh)
        b.addSystemCommand(&.{
            "sh",
            "-c",
            // Force refresh: always run fill (with --clean) for all deployed forks
            "cd execution-specs && "
            ++ "uv run --extra fill --extra test fill tests/eest --output tests/eest/static/state_tests --clean",
        })
    else
        b.addSystemCommand(&.{
            "sh",
            "-c",
            // No-op only if all fork fixtures are present; otherwise fill all
            "OUT_DIR=execution-specs/tests/eest/static/state_tests; "
            ++ "if [ -d \"$OUT_DIR\" ] && find \"$OUT_DIR\" -type f -name '*.json' | grep -q .; then "
            ++ "echo 'Specs already built, skipping fill'; "
            ++ "else cd execution-specs && "
            ++ "uv run --extra fill --extra test fill tests/eest --output tests/eest/static/state_tests --clean; fi",
        });

    // Generate Zig test wrappers from JSON fixtures for STATE TESTS
    const generate_zig_state_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/generate_spec_tests.py",
        "state",
    });
    generate_zig_state_tests.step.dependOn(&fill_specs.step);

    // Generate Zig test wrappers from JSON fixtures for BLOCKCHAIN TESTS
    const generate_zig_blockchain_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/generate_spec_tests.py",
        "blockchain",
    });
    generate_zig_blockchain_tests.step.dependOn(&fill_specs.step);

    // Update test/specs/root.zig with generated test imports for STATE TESTS
    const update_spec_root_state = b.addSystemCommand(&.{
        "python3",
        "scripts/update_spec_root.py",
        "state",
    });
    update_spec_root_state.step.dependOn(&generate_zig_state_tests.step);

    // Update test/specs/root.zig with generated test imports for BLOCKCHAIN TESTS
    const update_spec_root_blockchain = b.addSystemCommand(&.{
        "python3",
        "scripts/update_spec_root.py",
        "blockchain",
    });
    update_spec_root_blockchain.step.dependOn(&generate_zig_blockchain_tests.step);

    const spec_runner_mod = b.addModule("spec_runner", .{
        .root_source_file = b.path("test/specs/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evm", .module = evm_mod },
            .{ .name = "primitives", .module = primitives_mod },
        },
    });

    // Create separate test executables for state tests and blockchain tests
    const spec_tests_state = b.addTest(.{
        .root_module = spec_runner_mod,
        .test_runner = .{
            .path = b.path("test_runner.zig"),
            .mode = .simple,
        },
    });

    const spec_tests_blockchain = b.addTest(.{
        .root_module = spec_runner_mod,
        .test_runner = .{
            .path = b.path("test_runner.zig"),
            .mode = .simple,
        },
    });

    // Make spec test compilation depend on test generation pipeline
    spec_tests_state.step.dependOn(&update_spec_root_state.step);
    spec_tests_blockchain.step.dependOn(&update_spec_root_blockchain.step);

    // Run artifacts for state tests
    const run_spec_tests_state = b.addRunArtifact(spec_tests_state);
    run_spec_tests_state.setCwd(b.path(".")); // Set working directory to project root for test file paths
    run_spec_tests_state.setEnvironmentVariable("TEST_TYPE", "state");

    // Run artifacts for blockchain tests
    const run_spec_tests_blockchain = b.addRunArtifact(spec_tests_blockchain);
    run_spec_tests_blockchain.setCwd(b.path(".")); // Set working directory to project root for test file paths
    run_spec_tests_blockchain.setEnvironmentVariable("TEST_TYPE", "blockchain");

    // Main spec test step - runs STATE TESTS ONLY by default
    const spec_test_step = b.step("specs", "Run execution-specs STATE tests");
    spec_test_step.dependOn(&run_spec_tests_state.step);

    // Blockchain test step - runs BLOCKCHAIN TESTS ONLY
    const spec_blockchain_test_step = b.step("specs-blockchain", "Run execution-specs BLOCKCHAIN tests");
    spec_blockchain_test_step.dependOn(&run_spec_tests_blockchain.step);

    // Add state tests to main test step (default behavior)
    test_step.dependOn(&run_spec_tests_state.step);

    // Create hardfork-specific test suites
    const hardforks = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "frontier", .desc = "Frontier hardfork tests - runs all frontier-* sub-targets" },
        .{ .name = "homestead", .desc = "Homestead hardfork tests" },
        .{ .name = "byzantium", .desc = "Byzantium hardfork tests" },
        .{ .name = "constantinople", .desc = "Constantinople hardfork tests" },
        .{ .name = "istanbul", .desc = "Istanbul hardfork tests" },
        .{ .name = "berlin", .desc = "Berlin hardfork tests (EIP-2929, EIP-2930) - runs all berlin-* sub-targets" },
        .{ .name = "paris", .desc = "Paris/Merge hardfork tests" },
        .{ .name = "shanghai", .desc = "Shanghai hardfork tests (EIP-3651, EIP-3855, EIP-3860, EIP-4895)" },
        .{ .name = "cancun", .desc = "Cancun hardfork tests (EIP-1153, EIP-4788, EIP-4844, EIP-5656, EIP-6780, EIP-7516) - runs all cancun-* sub-targets" },
        .{ .name = "prague", .desc = "Prague hardfork tests - runs all prague-* sub-targets" },
        .{ .name = "osaka", .desc = "Osaka hardfork tests - runs all osaka-* sub-targets" },
    };

    // Break up large hardforks into smaller sub-targets for faster test iteration
    // Define a common struct type for all sub-targets
    const SubTarget = struct { name: []const u8, filter: []const u8, desc: []const u8 };

    // Berlin has 2772 tests in tx_intrinsic_gas alone
    const berlin_sub_targets = [_]SubTarget{
        .{ .name = "berlin-acl", .filter = "berlin.*acl.*account_storage_warm_cold_state", .desc = "Berlin EIP-2930 access list account storage tests" },
        .{ .name = "berlin-intrinsic-gas-cost", .filter = "berlin.*acl.*transaction_intrinsic_gas_cost", .desc = "Berlin EIP-2930 transaction intrinsic gas cost tests" },
        .{ .name = "berlin-intrinsic-type0", .filter = "berlin.*tx_intrinsic_gas.*tx_type_0", .desc = "Berlin EIP-2930 intrinsic gas type 0 transaction tests" },
        .{ .name = "berlin-intrinsic-type1", .filter = "berlin.*tx_intrinsic_gas.*tx_type_1", .desc = "Berlin EIP-2930 intrinsic gas type 1 transaction tests" },
    };

    // Frontier has 12k+ lines in stack_overflow.zig and 6k+ in push.zig
    const frontier_sub_targets = [_]SubTarget{
        .{ .name = "frontier-precompiles", .filter = "frontier.*precompile", .desc = "Frontier precompile tests" },
        .{ .name = "frontier-identity", .filter = "frontier.*identity", .desc = "Frontier identity precompile tests" },
        .{ .name = "frontier-create", .filter = "frontier.*create", .desc = "Frontier CREATE tests" },
        .{ .name = "frontier-call", .filter = "frontier.*call", .desc = "Frontier CALL/CALLCODE tests" },
        .{ .name = "frontier-calldata", .filter = "frontier.*calldata", .desc = "Frontier calldata opcode tests" },
        .{ .name = "frontier-dup", .filter = "frontier.*dup", .desc = "Frontier DUP tests" },
        .{ .name = "frontier-push", .filter = "frontier.*push", .desc = "Frontier PUSH tests" },
        .{ .name = "frontier-stack", .filter = "frontier.*stack_overflow", .desc = "Frontier stack overflow tests" },
        .{ .name = "frontier-opcodes", .filter = "frontier.*opcodes.*all_opcodes", .desc = "Frontier all opcodes tests" },
    };

    // Cancun has 20k+ lines in sufficient_balance_blob_tx.zig
    // NOTE: Filters use simple substring matching, not regex
    const cancun_sub_targets = [_]SubTarget{
        .{ .name = "cancun-tstore-basic", .filter = "eip1153_tstore_test_tstorage_py", .desc = "Cancun EIP-1153 basic TLOAD/TSTORE tests" },
        .{ .name = "cancun-tstore-reentrancy", .filter = "eip1153_tstore_test_tstore_reentrancy", .desc = "Cancun EIP-1153 reentrancy tests" },
        // Split contexts into smaller chunks (was 410 tests, now ~60-80 each)
        .{ .name = "cancun-tstore-contexts-execution", .filter = "tstorage_execution_contexts", .desc = "Cancun EIP-1153 execution context tests (60 tests)" },
        .{ .name = "cancun-tstore-contexts-tload-reentrancy", .filter = "tload_reentrancy", .desc = "Cancun EIP-1153 tload reentrancy tests (48 tests)" },
        .{ .name = "cancun-tstore-contexts-reentrancy", .filter = "tstorage_reentrancy_contexts", .desc = "Cancun EIP-1153 reentrancy context tests (20 tests)" },
        .{ .name = "cancun-tstore-contexts-create", .filter = "tstorage_create_contexts", .desc = "Cancun EIP-1153 create context tests (20 tests)" },
        .{ .name = "cancun-tstore-contexts-selfdestruct", .filter = "tstorage_selfdestruct", .desc = "Cancun EIP-1153 selfdestruct tests (12 tests)" },
        .{ .name = "cancun-tstore-contexts-clear", .filter = "tstorage_clear_after_tx", .desc = "Cancun EIP-1153 clear after tx tests (4 tests)" },
        .{ .name = "cancun-mcopy", .filter = "eip5656_mcopy", .desc = "Cancun EIP-5656 MCOPY tests" },
        // Split selfdestruct into smaller chunks (was 1166 tests, now ~50-300 each)
        .{ .name = "cancun-selfdestruct-basic", .filter = "test_selfdestruct_py", .desc = "Cancun EIP-6780 basic SELFDESTRUCT tests (306 tests)" },
        .{ .name = "cancun-selfdestruct-collision", .filter = "dynamic_create2_selfdestruct_collision", .desc = "Cancun EIP-6780 create2 collision tests (52 tests)" },
        .{ .name = "cancun-selfdestruct-reentrancy", .filter = "reentrancy_selfdestruct_revert", .desc = "Cancun EIP-6780 reentrancy revert tests (36 tests)" },
        .{ .name = "cancun-selfdestruct-revert", .filter = "test_selfdestruct_revert_py", .desc = "Cancun EIP-6780 revert tests (12 tests)" },
        .{ .name = "cancun-blobbasefee", .filter = "eip7516_blobgasfee", .desc = "Cancun EIP-7516 BLOBBASEFEE tests" },
        // Split blob precompile into smaller chunks (was 1073 tests, now ~50-310 each)
        .{ .name = "cancun-blob-precompile-basic", .filter = "test_point_evaluation_precompile_py", .desc = "Cancun EIP-4844 point evaluation basic tests (310 tests)" },
        .{ .name = "cancun-blob-precompile-gas", .filter = "test_point_evaluation_precompile_gas_py", .desc = "Cancun EIP-4844 point evaluation gas tests (48 tests)" },
        // Split blob opcodes into smaller chunks (was 282 tests, now ~25-75 each)
        .{ .name = "cancun-blob-opcodes-basic", .filter = "test_blobhash_opcode_py__test_blobhash_", .desc = "Cancun EIP-4844 BLOBHASH basic tests (75 tests)" },
        .{ .name = "cancun-blob-opcodes-contexts", .filter = "blobhash_opcode_contexts", .desc = "Cancun EIP-4844 BLOBHASH context tests (23 tests)" },
        .{ .name = "cancun-blob-tx-small", .filter = "blob_tx_attribute", .desc = "Cancun EIP-4844 small blob transaction tests" },
        .{ .name = "cancun-blob-tx-subtraction", .filter = "blob_gas_subtraction_tx", .desc = "Cancun EIP-4844 blob gas subtraction tests" },
        .{ .name = "cancun-blob-tx-insufficient", .filter = "insufficient_balance_blob_tx", .desc = "Cancun EIP-4844 insufficient balance tests" },
        .{ .name = "cancun-blob-tx-sufficient", .filter = "sufficient_balance_blob_tx", .desc = "Cancun EIP-4844 sufficient balance tests" },
        .{ .name = "cancun-blob-tx-valid-combos", .filter = "valid_blob_tx_combinations", .desc = "Cancun EIP-4844 valid combinations tests" },
    };

    // Prague has 4540 lines in transaction_validity_type_1_type_2.zig and many BLS12-381 tests
    const prague_sub_targets = [_]SubTarget{
        .{ .name = "prague-calldata-cost-type0", .filter = "prague.*eip7623.*type_0", .desc = "Prague EIP-7623 calldata cost type 0 tests" },
        .{ .name = "prague-calldata-cost-type1-2", .filter = "prague.*eip7623.*type_1_type_2", .desc = "Prague EIP-7623 calldata cost type 1/2 tests" },
        .{ .name = "prague-calldata-cost-type3", .filter = "prague.*eip7623.*type_3", .desc = "Prague EIP-7623 calldata cost type 3 tests" },
        .{ .name = "prague-calldata-cost-type4", .filter = "prague.*eip7623.*type_4", .desc = "Prague EIP-7623 calldata cost type 4 tests" },
        .{ .name = "prague-calldata-cost-refunds", .filter = "prague.*eip7623.*(refunds|execution_gas)", .desc = "Prague EIP-7623 refunds and gas tests" },
        .{ .name = "prague-bls-g1", .filter = "prague.*bls12.*(g1add|g1mul|g1msm)", .desc = "Prague EIP-2537 BLS12-381 G1 tests" },
        .{ .name = "prague-bls-g2", .filter = "prague.*bls12.*(g2add|g2mul|g2msm)", .desc = "Prague EIP-2537 BLS12-381 G2 tests" },
        .{ .name = "prague-bls-pairing", .filter = "prague.*bls12.*pairing", .desc = "Prague EIP-2537 BLS12-381 pairing tests" },
        .{ .name = "prague-bls-map", .filter = "prague.*bls12.*map", .desc = "Prague EIP-2537 BLS12-381 map tests" },
        .{ .name = "prague-bls-misc", .filter = "prague.*bls12.*(variable_length|before_fork)", .desc = "Prague EIP-2537 BLS12-381 misc tests" },
        .{ .name = "prague-setcode-calls", .filter = "prague.*eip7702.*calls", .desc = "Prague EIP-7702 set code call tests" },
        .{ .name = "prague-setcode-gas", .filter = "prague.*eip7702.*gas", .desc = "Prague EIP-7702 set code gas tests" },
        .{ .name = "prague-setcode-txs", .filter = "prague.*eip7702.*set_code_txs[^_2]", .desc = "Prague EIP-7702 set code transaction tests" },
        .{ .name = "prague-setcode-advanced", .filter = "prague.*eip7702.*set_code_txs_2", .desc = "Prague EIP-7702 advanced set code tests" },
    };

    // Osaka has 5836 lines in modexp_variable_gas_cost.zig
    const osaka_sub_targets = [_]SubTarget{
        .{ .name = "osaka-modexp-variable-gas", .filter = "osaka.*modexp_variable_gas_cost", .desc = "Osaka EIP-7883 modexp variable gas tests" },
        .{ .name = "osaka-modexp-vectors-eip", .filter = "osaka.*vectors_from_eip", .desc = "Osaka EIP-7883 modexp vectors from EIP tests" },
        .{ .name = "osaka-modexp-vectors-legacy", .filter = "osaka.*vectors_from_legacy", .desc = "Osaka EIP-7883 modexp vectors from legacy tests" },
        .{ .name = "osaka-modexp-misc", .filter = "osaka.*modexp.*(call_operations|gas_usage|invalid|entry_points|exceed)", .desc = "Osaka EIP-7883 modexp misc tests" },
        .{ .name = "osaka-other", .filter = "osaka.*(eip7823|eip7825)", .desc = "Osaka other EIP tests" },
    };

    // Shanghai has 558 tests - split initcode (was 558 tests, now ~160-180 each)
    const shanghai_sub_targets = [_]SubTarget{
        .{ .name = "shanghai-push0", .filter = "eip3855_push0", .desc = "Shanghai EIP-3855 PUSH0 tests" },
        .{ .name = "shanghai-warmcoinbase", .filter = "eip3651_warm_coinbase", .desc = "Shanghai EIP-3651 warm coinbase tests" },
        .{ .name = "shanghai-initcode-basic", .filter = "test_initcode_py", .desc = "Shanghai EIP-3860 initcode basic tests (162 tests)" },
        .{ .name = "shanghai-initcode-eof", .filter = "with_eof", .desc = "Shanghai EIP-3860 initcode EOF tests (24 tests)" },
        .{ .name = "shanghai-withdrawals", .filter = "eip4895_withdrawals", .desc = "Shanghai EIP-4895 withdrawal tests" },
    };

    // Byzantium has 352 tests - all modexp precompile
    const byzantium_sub_targets = [_]SubTarget{
        .{ .name = "byzantium-modexp", .filter = "eip198_modexp", .desc = "Byzantium EIP-198 modexp precompile tests (352 tests)" },
    };

    // Constantinople has 508 tests - split by EIP (was 508 tests, now ~250 each)
    const constantinople_sub_targets = [_]SubTarget{
        .{ .name = "constantinople-bitshift", .filter = "eip145_bitwise_shift", .desc = "Constantinople EIP-145 bitwise shift tests (~250 tests)" },
        .{ .name = "constantinople-create2", .filter = "eip1014_create2", .desc = "Constantinople EIP-1014 CREATE2 tests (~250 tests)" },
    };

    // Istanbul has 2165 tests - split by EIP (was 2165 tests, now smaller chunks)
    const istanbul_sub_targets = [_]SubTarget{
        .{ .name = "istanbul-blake2", .filter = "eip152_blake2", .desc = "Istanbul EIP-152 BLAKE2 precompile tests" },
        .{ .name = "istanbul-chainid", .filter = "eip1344_chainid", .desc = "Istanbul EIP-1344 CHAINID tests" },
    };

    // Helper to create sub-targets for a hardfork
    const SubTargetConfig = struct {
        targets: []const SubTarget,
        fork_name: []const u8,
    };

    const sub_target_configs = [_]SubTargetConfig{
        .{ .targets = &berlin_sub_targets, .fork_name = "berlin" },
        .{ .targets = &frontier_sub_targets, .fork_name = "frontier" },
        .{ .targets = &cancun_sub_targets, .fork_name = "cancun" },
        .{ .targets = &prague_sub_targets, .fork_name = "prague" },
        .{ .targets = &osaka_sub_targets, .fork_name = "osaka" },
        .{ .targets = &shanghai_sub_targets, .fork_name = "shanghai" },
        .{ .targets = &byzantium_sub_targets, .fork_name = "byzantium" },
        .{ .targets = &constantinople_sub_targets, .fork_name = "constantinople" },
        .{ .targets = &istanbul_sub_targets, .fork_name = "istanbul" },
    };

    var fork_sub_steps_map = std.StringHashMap(std.ArrayList(*std.Build.Step)).init(b.allocator);
    defer {
        var it = fork_sub_steps_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(b.allocator);
        }
        fork_sub_steps_map.deinit();
    }

    // Initialize arrays for each fork
    for (sub_target_configs) |config| {
        const steps = std.ArrayList(*std.Build.Step){};
        fork_sub_steps_map.put(config.fork_name, steps) catch @panic("OOM");
    }

    // Create all sub-targets
    for (sub_target_configs) |config| {
        const steps = fork_sub_steps_map.getPtr(config.fork_name).?;

        for (config.targets) |sub_target| {
            const sub_tests = b.addTest(.{
                .root_module = spec_runner_mod,
                .test_runner = .{
                    .path = b.path("test_runner.zig"),
                    .mode = .simple,
                },
            });

            sub_tests.step.dependOn(&update_spec_root_state.step);

            const run_sub_tests = b.addRunArtifact(sub_tests);
            run_sub_tests.setCwd(b.path("."));
            run_sub_tests.setEnvironmentVariable("TEST_FILTER", sub_target.filter);
            run_sub_tests.setEnvironmentVariable("TEST_TYPE", "state");

            const step_name = b.fmt("specs-{s}", .{sub_target.name});
            const sub_step = b.step(step_name, sub_target.desc);
            sub_step.dependOn(&run_sub_tests.step);

            steps.append(b.allocator, &run_sub_tests.step) catch @panic("OOM");
        }
    }

    for (hardforks) |fork| {
        const fork_tests = b.addTest(.{
            .root_module = spec_runner_mod,
            .test_runner = .{
                .path = b.path("test_runner.zig"),
                .mode = .simple,
            },
        });

        fork_tests.step.dependOn(&update_spec_root_state.step);

        const run_fork_tests = b.addRunArtifact(fork_tests);
        run_fork_tests.setCwd(b.path("."));
        run_fork_tests.setEnvironmentVariable("TEST_FILTER", fork.name);
        run_fork_tests.setEnvironmentVariable("TEST_TYPE", "state");

        const step_name = b.fmt("specs-{s}", .{fork.name});
        const fork_step = b.step(step_name, fork.desc);

        // For hardforks with sub-targets, make the main target depend on all sub-targets
        if (fork_sub_steps_map.get(fork.name)) |sub_steps| {
            for (sub_steps.items) |sub_step| {
                fork_step.dependOn(sub_step);
            }
        } else {
            fork_step.dependOn(&run_fork_tests.step);
        }
    }

    // Create EIP-specific test suites for hardforks without sub-targets
    // (Berlin, Frontier, Cancun, Prague, Osaka, Shanghai, Byzantium, Constantinople, and Istanbul now have sub-targets defined above)
    // This array is now empty - all test suites have been converted to use sub-targets for better granularity
    const eip_suites = [_]struct { name: []const u8, filter: []const u8, desc: []const u8 }{};

    for (eip_suites) |suite| {
        const eip_tests = b.addTest(.{
            .root_module = spec_runner_mod,
            .test_runner = .{
                .path = b.path("test_runner.zig"),
                .mode = .simple,
            },
        });

        eip_tests.step.dependOn(&update_spec_root_state.step);

        const run_eip_tests = b.addRunArtifact(eip_tests);
        run_eip_tests.setCwd(b.path("."));
        run_eip_tests.setEnvironmentVariable("TEST_FILTER", suite.filter);
        run_eip_tests.setEnvironmentVariable("TEST_TYPE", "state");

        const step_name = b.fmt("specs-{s}", .{suite.name});
        const eip_step = b.step(step_name, suite.desc);
        eip_step.dependOn(&run_eip_tests.step);
    }

    // Add trace test executable
    const trace_test_mod = b.addModule("trace_test_mod", .{
        .root_source_file = b.path("test_trace.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "guillotine", .module = mod },
            .{ .name = "primitives", .module = primitives_mod },
        },
    });

    const trace_test = b.addExecutable(.{
        .name = "trace_test",
        .root_module = trace_test_mod,
    });

    const run_trace_test = b.addRunArtifact(trace_test);
    const trace_test_step = b.step("test-trace", "Run trace capture test");
    trace_test_step.dependOn(&run_trace_test.step);

    // Interactive test runner
    const interactive_spec_tests = b.addTest(.{
        .root_module = spec_runner_mod,
        .test_runner = .{
            .path = b.path("interactive_test_runner.zig"),
            .mode = .simple,
        },
    });

    const run_interactive_tests = b.addRunArtifact(interactive_spec_tests);
    run_interactive_tests.setCwd(b.path(".")); // Set working directory to project root for test file paths
    const interactive_test_step = b.step("test-watch", "Run interactive test runner");
    interactive_test_step.dependOn(&run_interactive_tests.step);

    // WASM build target with ReleaseSmall optimization
    // Using wasi because primitives package includes C libraries (BLST, C-KZG, BN254)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // Get WASM-specific voltaire modules from dependency
    const wasm_voltaire_dep = b.dependency("voltaire", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_primitives_mod = wasm_voltaire_dep.module("voltaire");
    const wasm_crypto_mod = wasm_voltaire_dep.module("crypto");
    const wasm_precompiles_mod = wasm_voltaire_dep.module("precompiles");

    // Create WASM module with all necessary dependencies
    const wasm_mod = b.addModule("guillotine_mini_wasm", .{
        .root_source_file = b.path("src/root_c.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "primitives", .module = wasm_primitives_mod },
            .{ .name = "crypto", .module = wasm_crypto_mod },
            .{ .name = "precompiles", .module = wasm_precompiles_mod },
        },
    });

    const wasm_lib = b.addExecutable(.{
        .name = "guillotine_mini",
        .root_module = wasm_mod,
    });
    wasm_lib.entry = .disabled;
    wasm_lib.export_table = true;

    // Export all functions starting with evm_
    wasm_lib.root_module.export_symbol_names = &.{
        "evm_create",
        "evm_destroy",
        "evm_set_bytecode",
        "evm_set_execution_context",
        "evm_set_blockchain_context",
        "evm_execute",
        "evm_get_gas_remaining",
        "evm_get_gas_used",
        "evm_is_success",
        "evm_get_output_len",
        "evm_get_output",
        "evm_set_storage",
        "evm_get_storage",
        "evm_set_balance",
        "evm_set_code",
        "evm_set_access_list_addresses",
        "evm_set_access_list_storage_keys",
        "evm_set_blob_hashes",
        // Async protocol functions
        "evm_call_ffi",
        "evm_continue_ffi",
        "evm_get_state_changes",
        "evm_enable_storage_injector",
    };

    const wasm_install = b.addInstallArtifact(wasm_lib, .{});

    // Add step to log WASM size
    const wasm_size_step = b.addSystemCommand(&.{
        "sh",
        "-c",
        "ls -lh zig-out/bin/guillotine_mini.wasm | awk '{print \"WASM build size: \" $5}'",
    });
    wasm_size_step.step.dependOn(&wasm_install.step);

    const wasm_step = b.step("wasm", "Build WASM library and show bundle size");
    wasm_step.dependOn(&wasm_size_step.step);

    // Make WASM build part of default install step
    b.getInstallStep().dependOn(&wasm_install.step);

    // Native C library build for Rust FFI integration
    const native_mod = b.addModule("guillotine_mini_native", .{
        .root_source_file = b.path("src/root_c.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "precompiles", .module = precompiles_mod },
        },
    });

    const native_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "guillotine_mini",
        .root_module = native_mod,
    });

    const native_install = b.addInstallArtifact(native_lib, .{});

    const native_step = b.step("native", "Build native static library for FFI");
    native_step.dependOn(&native_install.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
