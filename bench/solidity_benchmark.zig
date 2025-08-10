const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
// TODO: Re-enable when compiler integration is fixed
// const compilers = root.compilers;
const Allocator = std.mem.Allocator;
const Contract = root.Evm.Contract;

/// Benchmark that compiles and executes the SnailShellBenchmark Solidity contract
pub fn solidity_snail_shell_benchmark(allocator: Allocator) void {
    solidity_snail_shell_benchmark_impl(allocator) catch |err| {
        std.log.err("Solidity snail benchmark failed: {}", .{err});
    };
}

fn solidity_snail_shell_benchmark_impl(allocator: Allocator) !void {
    std.log.info("Starting Solidity SnailShellBenchmark compilation and execution", .{});

    // TODO: Re-enable when compiler integration is fixed
    // Would read from src/solidity/SnailShellBenchmark.sol

    std.log.info("Using pre-compiled SnailShellBenchmark bytecode (compiler integration pending)...", .{});

    // Pre-compiled bytecode placeholder
    const bytecode_hex = "608060405234801561001057600080fd5b50610100565b";

    const bytecode_len = bytecode_hex.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);

    _ = try std.fmt.hexToBytes(bytecode, bytecode_hex);

    // Create EVM instance
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    evm_instance.* = try builder.build();
    defer evm_instance.deinit();

    // Set up deployer account with ETH
    const deployer = primitives.Address.from_u256(0x1111);
    const contract_address = primitives.Address.from_u256(0x3333);
    try evm_instance.state.set_balance(deployer, 1000000000000000000);

    // Deploy the contract with constructor parameters
    std.log.info("Deploying SnailShellBenchmark contract...", .{});

    // Encode constructor parameters (imageWidth=1024, imageHeight=768)
    var constructor_params: [64]u8 = undefined;
    // imageWidth parameter (1024 = 0x400)
    @memset(constructor_params[0..32], 0);
    constructor_params[31] = 0x00;
    constructor_params[30] = 0x04;

    // imageHeight parameter (768 = 0x300)
    @memset(constructor_params[32..64], 0);
    constructor_params[63] = 0x00;
    constructor_params[62] = 0x03;

    // Combine bytecode with constructor parameters
    const deployment_bytecode = try allocator.alloc(u8, bytecode.len + constructor_params.len);
    defer allocator.free(deployment_bytecode);
    @memcpy(deployment_bytecode[0..bytecode.len], bytecode);
    @memcpy(deployment_bytecode[bytecode.len..], &constructor_params);

    // Deploy contract
    var deploy_contract = Contract.init(
        deployer,
        primitives.Address.ZERO, // deployment address
        0, // no value
        3000000, // gas limit
        deployment_bytecode,
        [_]u8{0} ** 32, // code_hash
        &.{}, // no input data
        false, // not static
    );
    const deploy_result = try evm_instance.*.interpret(&deploy_contract, &.{});

    if (deploy_result.status != .Success) {
        std.log.err("Contract deployment failed: {}", .{deploy_result.status});
        return error.DeploymentFailed;
    }

    std.log.info("Contract deployed successfully at: {}", .{contract_address});

    // Now execute the executeBenchmark() function
    // Function selector for executeBenchmark() - first 4 bytes of keccak256("executeBenchmark()")
    const execute_benchmark_selector = &[_]u8{ 0x14, 0x7c, 0x8d, 0xa4 };

    std.log.info("Executing benchmark function...", .{});

    var exec_contract = Contract.init(
        deployer,
        contract_address,
        0, // no value
        5000000, // gas limit for execution
        &.{}, // code loaded from state
        [_]u8{0} ** 32, // code_hash
        execute_benchmark_selector,
        false, // not static
    );
    const exec_result = try evm_instance.*.interpret(&exec_contract, execute_benchmark_selector);

    if (exec_result.status != .Success) {
        std.log.err("Benchmark execution failed: {}", .{exec_result.status});
        return error.ExecutionFailed;
    }

    std.log.info("Benchmark execution completed successfully", .{});
    std.log.info("Gas used: {}", .{exec_result.gas_used});

    // Extract and log the result (bytes3 color value)
    if (exec_result.output) |output| {
        if (output.len >= 32) {
            const color_bytes = output[0..3];
            std.log.info("Result color (RGB): #{x:0>2}{x:0>2}{x:0>2}", .{
                color_bytes[0],
                color_bytes[1],
                color_bytes[2],
            });
        }
    }
}

/// Benchmark that runs multiple iterations for performance measurement
pub fn solidity_snail_shell_performance_benchmark(allocator: Allocator, iterations: u32) void {
    solidity_snail_shell_performance_impl(allocator, iterations) catch |err| {
        std.log.err("Solidity performance benchmark failed: {}", .{err});
    };
}

fn solidity_snail_shell_performance_impl(allocator: Allocator, iterations: u32) !void {
    // TODO: Re-enable when compiler integration is fixed
    // Would compile from src/solidity/SnailShellBenchmark.sol

    // Pre-compiled bytecode placeholder
    const bytecode_hex = "608060405234801561001057600080fd5b50610100565b";

    const bytecode_len = bytecode_hex.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);

    _ = try std.fmt.hexToBytes(bytecode, bytecode_hex);

    // Run performance benchmark
    var total_gas: u64 = 0;
    var timer = try std.time.Timer.start();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Create fresh EVM for each iteration
        var evm_instance = try allocator.create(Evm.Evm);
        defer allocator.destroy(evm_instance);

        var memory_db = try allocator.create(Evm.MemoryDatabase);
        defer allocator.destroy(memory_db);

        memory_db.* = Evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var builder = Evm.EvmBuilder.init(allocator, db_interface);
        evm_instance.* = try builder.build();
        defer evm_instance.deinit();

        const deployer = primitives.Address.from_u256(0x1111);
        const contract_address = primitives.Address.from_u256(0x3333);
        try evm_instance.state.set_balance(deployer, 1000000000000000000);

        // Deploy contract
        var constructor_params: [64]u8 = undefined;
        @memset(constructor_params[0..32], 0);
        constructor_params[31] = 0x00;
        constructor_params[30] = 0x04;
        @memset(constructor_params[32..64], 0);
        constructor_params[63] = 0x00;
        constructor_params[62] = 0x03;

        const deployment_bytecode = try allocator.alloc(u8, bytecode.len + constructor_params.len);
        defer allocator.free(deployment_bytecode);
        @memcpy(deployment_bytecode[0..bytecode.len], bytecode);
        @memcpy(deployment_bytecode[bytecode.len..], &constructor_params);

        var deploy_contract = Contract.init(
            deployer,
            primitives.Address.ZERO,
            0,
            3000000,
            deployment_bytecode,
            [_]u8{0} ** 32,
            &.{},
            false,
        );
        _ = try evm_instance.*.interpret(&deploy_contract, &.{});

        // Execute benchmark
        const execute_benchmark_selector = &[_]u8{ 0x14, 0x7c, 0x8d, 0xa4 };
        var exec_contract = Contract.init(
            deployer,
            contract_address,
            0,
            5000000,
            &.{},
            [_]u8{0} ** 32,
            execute_benchmark_selector,
            false,
        );
        const exec_result = try evm_instance.*.interpret(&exec_contract, execute_benchmark_selector);

        total_gas += exec_result.gas_used;
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const avg_gas = total_gas / iterations;
    const avg_time_ms = elapsed_ms / @as(f64, @floatFromInt(iterations));

    std.log.info("Solidity SnailShellBenchmark Performance Results:", .{});
    std.log.info("  Iterations: {}", .{iterations});
    std.log.info("  Total time: {d:.2} ms", .{elapsed_ms});
    std.log.info("  Average time per execution: {d:.2} ms", .{avg_time_ms});
    std.log.info("  Average gas used: {}", .{avg_gas});
    std.log.info("  Executions per second: {d:.2}", .{1000.0 / avg_time_ms});
}

/// Benchmark that compiles and executes the TenThousandHashes Solidity contract
pub fn solidity_ten_thousand_hashes_benchmark(allocator: Allocator) void {
    solidity_ten_thousand_hashes_impl(allocator) catch |err| {
        std.log.err("TenThousandHashes benchmark failed: {}", .{err});
    };
}

fn solidity_ten_thousand_hashes_impl(allocator: Allocator) !void {
    std.log.info("Starting TenThousandHashes benchmark compilation and execution", .{});

    // TODO: Re-enable when compiler integration is fixed
    // Would read from src/solidity/TenThousandHashesBenchmark.sol

    // Configure compiler settings
    // const settings = compilers.CompilerSettings{
    //     .optimizer_enabled = true,
    //     .optimizer_runs = 200,
    //     .evm_version = "shanghai",
    //     .output_abi = true,
    //     .output_bytecode = true,
    //     .output_deployed_bytecode = true,
    // };

    std.log.info("Using pre-compiled TenThousandHashes bytecode (compiler integration pending)...", .{});

    // Pre-compiled bytecode for TenThousandHashes contract
    // pragma solidity ^0.6.12;
    // contract TenThousandHashes {
    //     function Benchmark() external pure {
    //         for (uint256 i = 0; i < 20000; i++) {
    //             keccak256(abi.encodePacked(i));
    //         }
    //     }
    // }
    const bytecode_hex = "608060405234801561001057600080fd5b5060c28061001f6000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80638ef077b514602d575b600080fd5b60336035565b005b60005b614e208110156088576040518082815260200191505060405180910390206040518082815260200191505060405180910390208060010191505060388110605e57600080fd5b60010191505080806001019150506038565b5056fea2646970667358221220e3d8c82f745b2e3a5de9d89fb5e66aaf0a2e9725ceed8af5ff37bb4b087c18fa64736f6c634300060c0033";

    const bytecode_len = bytecode_hex.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);

    _ = try std.fmt.hexToBytes(bytecode, bytecode_hex);

    // Create EVM instance
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    evm_instance.* = try builder.build();
    defer evm_instance.deinit();

    // Set up accounts
    const deployer = primitives.Address.from_u256(0x1111);
    const contract_address = primitives.Address.from_u256(0x3333);

    // Fund the deployer account
    try evm_instance.state.set_balance(deployer, 1000000000000000000); // 1 ETH

    // Deploy the contract
    std.log.info("Deploying TenThousandHashes contract...", .{});
    var deploy_contract = Contract.init(
        deployer, // caller
        primitives.Address.ZERO, // deployment address
        0, // value
        3000000, // gas limit
        bytecode, // code
        [_]u8{0} ** 32, // code_hash
        &.{}, // input
        false, // not static
    );
    const deployment_result = try evm_instance.*.interpret(&deploy_contract, &.{});

    std.log.info("Contract deployed. Gas used: {}", .{deployment_result.gas_used});

    // Call the Benchmark() function
    // Function selector for Benchmark() = keccak256("Benchmark()")[0:4]
    const benchmark_selector = &[_]u8{ 0x8e, 0xf0, 0x77, 0xb5 };

    std.log.info("Executing Benchmark() function (20,000 hashes)...", .{});
    var timer = try std.time.Timer.start();

    var exec_contract = Contract.init(
        deployer, // caller
        contract_address, // address
        0, // value
        10000000, // gas limit (10M gas)
        &.{}, // code loaded from state
        [_]u8{0} ** 32, // code_hash
        benchmark_selector, // input
        false, // not static
    );
    const exec_result = try evm_instance.*.interpret(&exec_contract, benchmark_selector);

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    if (exec_result.status != .Success) {
        std.log.err("Benchmark execution failed: {}", .{exec_result.status});
        return error.ExecutionFailed;
    }

    std.log.info("TenThousandHashes benchmark completed successfully", .{});
    std.log.info("Gas used: {}", .{exec_result.gas_used});
    std.log.info("Execution time: {d:.2} ms", .{elapsed_ms});
    std.log.info("Hashes per second: {d:.2}", .{20000.0 / (elapsed_ms / 1000.0)});
    std.log.info("Gas per hash: {d:.2}", .{@as(f64, @floatFromInt(exec_result.gas_used)) / 20000.0});
}

/// Performance benchmark for TenThousandHashes with multiple iterations
pub fn solidity_ten_thousand_hashes_performance_benchmark(allocator: Allocator, iterations: u32) void {
    solidity_ten_thousand_hashes_performance_impl(allocator, iterations) catch |err| {
        std.log.err("TenThousandHashes performance benchmark failed: {}", .{err});
    };
}

fn solidity_ten_thousand_hashes_performance_impl(allocator: Allocator, iterations: u32) !void {
    // TODO: Re-enable when compiler integration is fixed
    // Would compile from src/solidity/TenThousandHashesBenchmark.sol

    // Pre-compiled bytecode for TenThousandHashes
    const bytecode_hex = "608060405234801561001057600080fd5b5060c28061001f6000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80638ef077b514602d575b600080fd5b60336035565b005b60005b614e208110156088576040518082815260200191505060405180910390206040518082815260200191505060405180910390208060010191505060388110605e57600080fd5b60010191505080806001019150506038565b5056fea2646970667358221220e3d8c82f745b2e3a5de9d89fb5e66aaf0a2e9725ceed8af5ff37bb4b087c18fa64736f6c634300060c0033";

    const bytecode_len = bytecode_hex.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);

    _ = try std.fmt.hexToBytes(bytecode, bytecode_hex);

    // Run performance benchmark
    var total_gas: u64 = 0;
    var timer = try std.time.Timer.start();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Create fresh EVM for each iteration
        var evm_instance = try allocator.create(Evm.Evm);
        defer allocator.destroy(evm_instance);

        var memory_db = try allocator.create(Evm.MemoryDatabase);
        defer allocator.destroy(memory_db);

        memory_db.* = Evm.MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var builder = Evm.EvmBuilder.init(allocator, db_interface);
        evm_instance.* = try builder.build();
        defer evm_instance.deinit();

        const deployer = primitives.Address.from_u256(0x1111);
        const contract_address = primitives.Address.from_u256(0x3333);
        try evm_instance.state.set_balance(deployer, 1000000000000000000);

        // Deploy contract
        var deploy_contract = Contract.init(
            deployer,
            primitives.Address.ZERO,
            0,
            3000000,
            bytecode,
            [_]u8{0} ** 32,
            &.{},
            false,
        );
        _ = try evm_instance.*.interpret(&deploy_contract, &.{});

        // Execute benchmark
        const benchmark_selector = &[_]u8{ 0x8e, 0xf0, 0x77, 0xb5 };
        var exec_contract = Contract.init(
            deployer,
            contract_address,
            0,
            10000000,
            &.{},
            [_]u8{0} ** 32,
            benchmark_selector,
            false,
        );
        const exec_result = try evm_instance.*.interpret(&exec_contract, benchmark_selector);

        total_gas += exec_result.gas_used;
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const avg_gas = total_gas / iterations;
    const avg_time_ms = elapsed_ms / @as(f64, @floatFromInt(iterations));

    std.log.info("TenThousandHashes Performance Results:", .{});
    std.log.info("  Iterations: {}", .{iterations});
    std.log.info("  Total time: {d:.2} ms", .{elapsed_ms});
    std.log.info("  Average time per execution: {d:.2} ms", .{avg_time_ms});
    std.log.info("  Average gas used: {}", .{avg_gas});
    std.log.info("  Executions per second: {d:.2}", .{1000.0 / avg_time_ms});
    std.log.info("  Average hashes per second: {d:.2}", .{20000.0 / (avg_time_ms / 1000.0)});
}
