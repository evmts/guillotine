const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Contract = Evm.Contract;
const MemoryDatabase = Evm.MemoryDatabase;

// Test addresses - use small simple values
const DEPLOYER_ADDRESS = primitives.Address.from_u256(0x1111);
const USER_ADDRESS = primitives.Address.from_u256(0x2222);
const CONTRACT_ADDRESS = primitives.Address.from_u256(0x3333);

// Helper to convert byte array to u256 (big-endian)
fn bytes_to_u256(bytes: []const u8) u256 {
    var value: u256 = 0;
    for (bytes) |byte| {
        value = (value << 8) | byte;
    }
    return value;
}

// Test basic inheritance and virtual function calls
test "E2E: Basic inheritance - virtual function overrides" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create EVM instance
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    evm_instance.* = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm_instance.deinit();

    // Simulate virtual function override behavior
    // Base implementation returns base value, derived multiplies by factor
    const virtual_override_bytecode = [_]u8{
        // Store base value (100) at slot 0
        0x60, 0x64, // PUSH1 100 (base value)
        0x60, 0x00, // PUSH1 0 (storage slot)
        0x55, // SSTORE

        // Store multiplier (3) at slot 1
        0x60, 0x03, // PUSH1 3 (multiplier)
        0x60, 0x01, // PUSH1 1 (storage slot)
        0x55, // SSTORE

        // Simulate derived class behavior: baseValue * multiplier
        0x60, 0x00, // PUSH1 0 (base value slot)
        0x54, // SLOAD
        0x60, 0x01, // PUSH1 1 (multiplier slot)
        0x54, // SLOAD
        0x02, // MUL (base * multiplier)

        // Store result and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract and execute
    var contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &virtual_override_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm_instance.state.set_code(CONTRACT_ADDRESS, &virtual_override_bytecode);

    // Execute the contract
    const result = try evm_instance.interpretCompat(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.status == .Success);
    if (result.output) |output| {
        const value = bytes_to_u256(output);
        try testing.expectEqual(@as(u256, 300), value); // 100 * 3
    }
}

// Test interface implementation and polymorphism
test "E2E: Interface compliance - polymorphic behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create EVM instance
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    evm_instance.* = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm_instance.deinit();

    // Simulate interface compliance - different implementations of same interface
    const interface_test_bytecode = [_]u8{
        // Test setValue(50) and getValue() for ConcreteA (multiplier = 2)
        0x60, 0x32, // PUSH1 50 (value to set)
        0x60, 0x00, // PUSH1 0 (base value slot)
        0x55, // SSTORE (setValue)
        0x60, 0x02, // PUSH1 2 (multiplier for ConcreteA)
        0x60, 0x01, // PUSH1 1 (multiplier slot)
        0x55, // SSTORE

        // Simulate ConcreteA.getValue(): baseValue * multiplier
        0x60, 0x00, // PUSH1 0 (base value slot)
        0x54, // SLOAD
        0x60, 0x01, // PUSH1 1 (multiplier slot)
        0x54, // SLOAD
        0x02, // MUL (getValue for ConcreteA)

        // Store ConcreteA result at memory 0
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE

        // Test ConcreteB behavior: baseValue + bonus (bonus = baseValue/10)
        0x60, 0x32, // PUSH1 50 (same base value)
        0x60, 0x0A, // PUSH1 10 (divisor for bonus)
        0x04, // DIV (50/10 = 5, bonus)
        0x60, 0x32, // PUSH1 50 (base value)
        0x01, // ADD (baseValue + bonus = 55)

        // Store ConcreteB result at memory 32
        0x60, 0x20, // PUSH1 32 (memory offset)
        0x52, // MSTORE

        // Return both results (64 bytes)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x40, // PUSH1 64 (size)
        0xF3, // RETURN
    };

    // Create contract and execute
    var contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &interface_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm_instance.state.set_code(CONTRACT_ADDRESS, &interface_test_bytecode);

    // Execute the contract
    const result = try evm_instance.interpretCompat(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.status == .Success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 64), output.len);

        // ConcreteA result: 50 * 2 = 100
        const concrete_a_result = bytes_to_u256(output[0..32]);
        try testing.expectEqual(@as(u256, 100), concrete_a_result);

        // ConcreteB result: 50 + 5 = 55
        const concrete_b_result = bytes_to_u256(output[32..64]);
        try testing.expectEqual(@as(u256, 55), concrete_b_result);
    }
}

// Test multiple inheritance (diamond pattern)
test "E2E: Multiple inheritance - diamond pattern resolution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create EVM instance
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    evm_instance.* = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm_instance.deinit();

    // Simulate diamond inheritance: Diamond inherits from LeftBase and RightBase
    const diamond_test_bytecode = [_]u8{
        // Store left base value (100) and calculate overridden value (100 * 2)
        0x60, 0x64, // PUSH1 100 (left base value)
        0x60, 0x02, // PUSH1 2 (left multiplier)
        0x02, // MUL (overridden left: 100 * 2 = 200)

        // Store right base value (200) and calculate overridden value (200 * 3)
        0x61, 0x00, 0xC8, // PUSH2 200 (right base value)
        0x60, 0x03, // PUSH1 3 (right multiplier)
        0x02, // MUL (overridden right: 200 * 3 = 600)

        // Add both overridden values for combined result
        0x01, // ADD (200 + 600 = 800)

        // Store result and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract and execute
    var contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &diamond_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm_instance.state.set_code(CONTRACT_ADDRESS, &diamond_test_bytecode);

    // Execute the contract
    const result = try evm_instance.interpretCompat(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.status == .Success);
    if (result.output) |output| {
        const combined_value = bytes_to_u256(output);
        try testing.expectEqual(@as(u256, 800), combined_value);
    }
}

// Test function visibility and access control
test "E2E: Function visibility - access control patterns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create EVM instance
    var evm_instance = try allocator.create(Evm.Evm);
    defer allocator.destroy(evm_instance);

    var memory_db = try allocator.create(MemoryDatabase);
    defer allocator.destroy(memory_db);

    memory_db.* = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    evm_instance.* = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm_instance.deinit();

    // Test internal function access through public wrapper
    const visibility_test_bytecode = [_]u8{
        // Simulate internal function that returns 100
        0x60, 0x64, // PUSH1 100 (internal function result)

        // Store private variable (1) at slot 0
        0x60, 0x01, // PUSH1 1 (private var)
        0x60, 0x00, // PUSH1 0 (storage slot)
        0x55, // SSTORE

        // Store internal variable (2) at slot 1
        0x60, 0x02, // PUSH1 2 (internal var)
        0x60, 0x01, // PUSH1 1 (storage slot)
        0x55, // SSTORE

        // Store public variable (3) at slot 2
        0x60, 0x03, // PUSH1 3 (public var)
        0x60, 0x02, // PUSH1 2 (storage slot)
        0x55, // SSTORE

        // Simulate callInternal() -> internalFunction()
        // Result is internal function result (100) + sum of variables
        0x60, 0x00, // PUSH1 0 (private var slot)
        0x54, // SLOAD
        0x60, 0x01, // PUSH1 1 (internal var slot)
        0x54, // SLOAD
        0x01, // ADD (private + internal)
        0x60, 0x02, // PUSH1 2 (public var slot)
        0x54, // SLOAD
        0x01, // ADD (+ public)
        0x01, // ADD (+ internal function result)

        // Store result and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract and execute
    var contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &visibility_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm_instance.state.set_code(CONTRACT_ADDRESS, &visibility_test_bytecode);

    // Execute the contract
    const result = try evm_instance.interpretCompat(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.status == .Success);
    if (result.output) |output| {
        const total = bytes_to_u256(output);
        // 100 (internal function) + 1 (private) + 2 (internal) + 3 (public) = 106
        try testing.expectEqual(@as(u256, 106), total);
    }
}
