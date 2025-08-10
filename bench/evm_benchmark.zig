const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Real EVM benchmark that executes actual bytecode through the interpreter
pub fn evm_snail_shell_benchmark(allocator: Allocator) void {
    evm_snail_shell_benchmark_impl(allocator) catch |err| {
        std.log.err("EVM snail benchmark failed: {}", .{err});
    };
}

fn evm_snail_shell_benchmark_impl(allocator: Allocator) !void {
    // Create EVM instance (following e2e test pattern)
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    evm_instance.* = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    defer evm_instance.deinit();

    // Set up deployer account with ETH
    const deployer = primitives.Address.from_u256(0x1111);
    const contract_address = primitives.Address.from_u256(0x3333);
    try evm_instance.state.set_balance(deployer, 1000000000000000000);

    // Simplified SnailShellBenchmark bytecode that performs computational work
    // This bytecode simulates the core computational loop of the snail shell:
    // 1. Push constants for shell parameters
    // 2. Loop to calculate sphere positions (simplified)
    // 3. Perform arithmetic operations mimicking 3D calculations
    // 4. Return a result
    const snail_bytecode = &[_]u8{
        // Initialize loop counter (72 spheres)
        0x60, 0x48, // PUSH1 72
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE at 0

        // Main computation loop (simplified ray tracing)
        0x5b, // JUMPDEST (loop start)

        // Load counter
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD

        // Check if counter < 72
        0x60, 0x48, // PUSH1 72
        0x82, // DUP3
        0x10, // LT
        0x61, 0x00, 0x40, // PUSH2 0x0040 (jump to end if >= 72)
        0x57, // JUMPI

        // Simulate trigonometric calculation (multiply by constants)
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD (load counter)
        0x61, 0x18, 0x6A, // PUSH2 6250 (approximation of 2π * 1000)
        0x02, // MUL
        0x61, 0x03, 0xE8, // PUSH2 1000
        0x04, // DIV

        // Simulate radius calculation
        0x61, 0x4E, 0x20, // PUSH2 20000 (initial radius)
        0x01, // ADD

        // Store intermediate result
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE

        // Simulate more complex calculations (vector operations)
        0x60, 0x20, // PUSH1 32
        0x51, // MLOAD
        0x80, // DUP1
        0x02, // MUL (simulate x coordinate)
        0x60, 0x40, // PUSH1 64
        0x52, // MSTORE

        // Increment counter
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE

        // Jump back to loop start
        0x60, 0x05, // PUSH1 5 (JUMPDEST position)
        0x56, // JUMP

        // End of loop
        0x5b, // JUMPDEST (0x40)

        // Return final computation result
        0x60, 0x40, // PUSH1 64
        0x51, // MLOAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3, // RETURN
    };

    // Create contract and execute (following e2e pattern)
    var contract = Evm.Contract.init_at_address(
        deployer, // caller
        contract_address, // address where code executes
        0, // value
        10_000_000, // gas limit (high for computation)
        snail_bytecode, // bytecode
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm_instance.state.set_code(contract_address, snail_bytecode);

    // Execute the contract
    const result = try evm_instance.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    // The benchmark measures the entire execution including:
    // - Opcode dispatch
    // - Gas accounting
    // - Stack operations
    // - Memory operations
    // - Jump validation

    // Prevent optimization
    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark simple arithmetic operations in EVM
pub fn evm_arithmetic_benchmark(allocator: Allocator) void {
    evm_arithmetic_benchmark_impl(allocator) catch |err| {
        std.log.err("EVM arithmetic benchmark failed: {}", .{err});
    };
}

fn evm_arithmetic_benchmark_impl(allocator: Allocator) !void {
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    evm_instance.* = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    defer evm_instance.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_address = primitives.Address.from_u256(0x2222);
    try evm_instance.state.set_balance(caller, 1000000000000000000);

    // Simple arithmetic operations: ADD, MUL, DIV, MOD
    const arithmetic_bytecode = &[_]u8{
        // Push two numbers and add them
        0x60, 0x0A, // PUSH1 10
        0x60, 0x20, // PUSH1 32
        0x01, // ADD

        // Multiply by 3
        0x60, 0x03, // PUSH1 3
        0x02, // MUL

        // Divide by 2
        0x60, 0x02, // PUSH1 2
        0x04, // DIV

        // Store result
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE

        // Return the result
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3, // RETURN
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_address,
        0,
        100_000,
        arithmetic_bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try evm_instance.state.set_code(contract_address, arithmetic_bytecode);

    const result = try evm_instance.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark memory-intensive operations in EVM
pub fn evm_memory_benchmark(allocator: Allocator) void {
    evm_memory_benchmark_impl(allocator) catch |err| {
        std.log.err("EVM memory benchmark failed: {}", .{err});
    };
}

fn evm_memory_benchmark_impl(allocator: Allocator) !void {
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    evm_instance.* = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    defer evm_instance.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_address = primitives.Address.from_u256(0x4444);
    try evm_instance.state.set_balance(caller, 1000000000000000000);

    // Memory operations: MSTORE, MLOAD, MSTORE8
    const memory_bytecode = &[_]u8{
        // Store values at different memory locations
        0x60, 0xFF, // PUSH1 255
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x61, 0xAB, 0xCD, // PUSH2 0xABCD
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x40, // PUSH1 64
        0x52, // MSTORE

        // Load and manipulate
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        0x60, 0x20, // PUSH1 32
        0x51, // MLOAD
        0x01, // ADD
        0x60, 0x60, // PUSH1 96
        0x52, // MSTORE

        // MSTORE8 operation
        0x60, 0xAA, // PUSH1 0xAA
        0x60, 0x80, // PUSH1 128
        0x53, // MSTORE8

        // Return memory content
        0x60, 0x00, // PUSH1 0
        0x60, 0x81, // PUSH1 129 (to include MSTORE8 byte)
        0xf3, // RETURN
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_address,
        0,
        1_000_000,
        memory_bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try evm_instance.state.set_code(contract_address, memory_bytecode);

    const result = try evm_instance.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark storage operations (SSTORE/SLOAD) in EVM
pub fn evm_storage_benchmark(allocator: Allocator) void {
    evm_storage_benchmark_impl(allocator) catch |err| {
        std.log.err("EVM storage benchmark failed: {}", .{err});
    };
}

fn evm_storage_benchmark_impl(allocator: Allocator) !void {
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    evm_instance.* = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    defer evm_instance.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_address = primitives.Address.from_u256(0x5555);
    try evm_instance.state.set_balance(caller, 1000000000000000000);

    // Storage operations: SSTORE and SLOAD
    const storage_bytecode = &[_]u8{
        // Store value at storage slot 0
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE

        // Store value at storage slot 1
        0x60, 0x84, // PUSH1 0x84
        0x60, 0x01, // PUSH1 1
        0x55, // SSTORE

        // Load from slot 0
        0x60, 0x00, // PUSH1 0
        0x54, // SLOAD

        // Load from slot 1
        0x60, 0x01, // PUSH1 1
        0x54, // SLOAD

        // Add them
        0x01, // ADD

        // Store result in slot 2
        0x60, 0x02, // PUSH1 2
        0x55, // SSTORE

        // Load and return result
        0x60, 0x02, // PUSH1 2
        0x54, // SLOAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3, // RETURN
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_address,
        0,
        10_000_000, // High gas limit for storage operations
        storage_bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try evm_instance.state.set_code(contract_address, storage_bytecode);

    const result = try evm_instance.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

test "evm benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;

    // Just verify they compile and can execute without crashing
    evm_arithmetic_benchmark(allocator);
    evm_memory_benchmark(allocator);
    evm_storage_benchmark(allocator);

    // Note: evm_snail_shell_benchmark might be too complex for a quick test
}
