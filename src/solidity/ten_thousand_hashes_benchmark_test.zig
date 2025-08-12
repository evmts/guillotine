const std = @import("std");
const expect = std.testing.expect;
const evm = @import("evm");

test "TenThousandHashes benchmark test" {
    std.testing.log_level = .warn;
    const allocator = std.testing.allocator;

    std.debug.print("\n=== TenThousandHashes Benchmark Test ===\n", .{});

    // Initialize memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Initialize EVM using builder pattern
    var builder = evm.Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();

    // Pre-compiled bytecode for TenThousandHashes contract
    // This is the actual bytecode for the contract:
    // pragma solidity ^0.6.12;
    // contract TenThousandHashes {
    //     function Benchmark() external pure {
    //         for (uint256 i = 0; i < 20000; i++) {
    //             keccak256(abi.encodePacked(i));
    //         }
    //     }
    // }
    // Compiled with solc 0.6.12 with optimization enabled (200 runs)
    const benchmark_bytecode = "608060405234801561001057600080fd5b5060c28061001f6000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80638ef077b514602d575b600080fd5b60336035565b005b60005b614e208110156088576040518082815260200191505060405180910390206040518082815260200191505060405180910390208060010191505060388110605e57600080fd5b60010191505080806001019150506038565b5056fea2646970667358221220";

    // Convert hex string to bytes
    const bytecode_len = benchmark_bytecode.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);

    _ = try std.fmt.hexToBytes(bytecode, benchmark_bytecode);

    // Create contract
    const contract_obj = evm.Contract.init(
        evm.primitives.Address.ZERO, // caller
        evm.primitives.Address.ZERO, // address
        0, // value
        10000000, // gas (10M gas for the benchmark)
        bytecode, // code
        [_]u8{0} ** 32, // code_hash
        &.{}, // input
        false, // is_static
    );

    var contract_obj_mut = contract_obj;

    // Initialize frame
    var frame = try evm.Frame.init(allocator, &contract_obj_mut);
    defer frame.deinit();

    // TODO: Once the compilers package is integrated, we would:
    // 1. Compile TenThousandHashesBenchmark.sol at runtime
    // 2. Deploy the contract
    // 3. Call the Benchmark() function
    // 4. Measure gas usage and execution time

    std.debug.print("TenThousandHashes benchmark test completed (placeholder)\n", .{});
    std.debug.print("TODO: Integrate compilers package to compile and run actual benchmark\n", .{});
}

test "TenThousandHashes performance benchmark" {
    // const allocator = std.testing.allocator; // unused for now

    std.debug.print("\n=== TenThousandHashes Performance Metrics ===\n", .{});

    // TODO: Once we can compile the contract, this test will:
    // 1. Compile the TenThousandHashes contract
    // 2. Execute the Benchmark() function
    // 3. Measure execution time
    // 4. Measure gas consumption
    // 5. Calculate hashes per second
    // 6. Compare against baseline performance

    const expected_iterations = 20000;
    std.debug.print("Expected iterations: {d}\n", .{expected_iterations});
    std.debug.print("Each iteration performs keccak256 hash\n", .{});
    std.debug.print("Total expected hashes: {d}\n", .{expected_iterations});

    // Placeholder for actual benchmark results
    std.debug.print("\nPerformance benchmark placeholder - awaiting compiler integration\n", .{});
}
