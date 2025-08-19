const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const MemoryDatabase = Evm.MemoryDatabase;
const Contract = Evm.Contract;

// Test addresses - use small simple values
const DEPLOYER_ADDRESS = primitives.Address.from_u256(0x1111);
const USER_ADDRESS = primitives.Address.from_u256(0x2222);
const CONTRACT_ADDRESS = primitives.Address.from_u256(0x3333);

// Test revert conditions and error messages
test "E2E: Revert conditions - require and revert opcodes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test REVERT opcode directly
    const revert_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (size)
        0xFD, // REVERT
    };

    // Create a contract at the specified address
    var revert_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &revert_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer revert_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &revert_bytecode);

    // Execute the contract with traditional interpreter
    const revert_result = try evm.interpretCompat(&revert_contract, &[_]u8{}, false);
    // Execute the contract with block interpreter
    const revert_result_block = try evm.interpret_block_write(&revert_contract, &[_]u8{});
    // Test traditional interpreter result
    try testing.expect(revert_result.status == .Revert);
    // Test block interpreter result
    try testing.expect(revert_result_block.status == .Revert);

    // Test conditional revert - should succeed if condition is false
    const conditional_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (false condition)
        0x60, 0x10, // PUSH1 16 (jump target if condition is true)
        0x57, // JUMPI (conditional jump)
        // Success path
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xF3, // RETURN
        // Revert path (offset 16)
        0x5B, // JUMPDEST
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xFD, // REVERT
    };

    // Create a new contract for conditional test
    var conditional_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &conditional_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer conditional_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &conditional_bytecode);

    // Execute the contract with traditional interpreter
    const conditional_result = try evm.interpretCompat(&conditional_contract, &[_]u8{}, false);
    // Execute the contract with block interpreter
    const conditional_result_block = try evm.interpret_block_write(&conditional_contract, &[_]u8{});
    // Test traditional interpreter result
    try testing.expect(conditional_result.status == .Success);
    // Test block interpreter result
    try testing.expect(conditional_result_block.status == .Success);
    
    if (conditional_result.output) |_| {
        var value: u256 = 0;
        for (output) |_| {
            value = (value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 42), value);
    }
    
    if (conditional_result_block.output) |_| {
        var value: u256 = 0;
        for (output) |_| {
            value = (value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 42), value);
    }
}

// Test arithmetic overflow and underflow scenarios
test "E2E: Arithmetic overflow - EVM wraparound behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test MAX_UINT256 + 1 = 0 (wraparound)
    const overflow_test_bytecode = [_]u8{
        // Push MAX_UINT256 (all 0xFF bytes)
        0x7F, // PUSH32 (followed by 32 bytes)
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (should wrap to 0)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract for overflow test
    var overflow_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &overflow_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer overflow_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &overflow_test_bytecode);

    // Execute the contract
    const overflow_result = try evm.interpretCompat(&overflow_contract, &[_]u8{}, false);
    try testing.expect(overflow_result.status == .Success);
    if (overflow_result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Should return 0 (MAX_UINT256 + 1 wraps to 0)
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 0), result_value);
    }

    // Test underflow: 0 - 1 = MAX_UINT256
    const underflow_test_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x01, // PUSH1 1
        0x03, // SUB (0 - 1, should wrap to MAX_UINT256)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract for underflow test
    var underflow_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &underflow_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer underflow_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &underflow_test_bytecode);

    // Execute the contract
    const underflow_result = try evm.interpretCompat(&underflow_contract, &[_]u8{}, false);
    try testing.expect(underflow_result.status == .Success);
    if (underflow_result.output) |_| {
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        try testing.expectEqual(std.math.maxInt(u256), result_value);
    }
}

// Test gas consumption and out-of-gas scenarios
test "E2E: Gas limits - controlled consumption and out-of-gas" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Simple gas consumption test - just do some operations
    const gas_test_bytecode = [_]u8{
        // Do a series of operations to consume gas
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x04, // PUSH1 4
        0x01, // ADD
        0x60, 0x02, // PUSH1 2
        0x04, // DIV

        // Store result in memory and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Test with sufficient gas
    // Create contract for sufficient gas test
    var sufficient_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        10_000, // gas
        &gas_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer sufficient_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &gas_test_bytecode);

    // Execute the contract
    const sufficient_result = try evm.interpretCompat(&sufficient_contract, &[_]u8{}, false);
    try testing.expect(sufficient_result.status == .Success);
    try testing.expect(sufficient_result.gas_used > 0);

    if (sufficient_result.output) |_| {
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        // Result should be: ((1 + 2) * 3 + 4) / 2 = (9 + 4) / 2 = 13 / 2 = 6
        try testing.expectEqual(@as(u256, 6), result_value);
    }

    // Test with insufficient gas
    // Create contract for insufficient gas test
    var insufficient_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        10, // Very low gas limit
        &gas_test_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer insufficient_contract.deinit(allocator, null);

    // Execute the contract with insufficient gas
    const insufficient_result = try evm.interpretCompat(&insufficient_contract, &[_]u8{}, false);
    // Check status
    try testing.expect(insufficient_result.status == .OutOfGas);
}

// Test stack operations and underflow conditions
test "E2E: Stack underflow - empty stack operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test stack underflow - POP from empty stack
    const underflow_bytecode = [_]u8{
        0x50, // POP (from empty stack - should fail)
    };

    // Create contract for underflow test
    var underflow_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &underflow_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer underflow_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &underflow_bytecode);

    // Execute the contract
    const underflow_result = try evm.interpretCompat(&underflow_contract, &[_]u8{}, false);
    try testing.expect(underflow_result.status == .Invalid);

    // Test arithmetic with insufficient stack items
    const insufficient_stack_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (only one item on stack)
        0x01, // ADD (needs two items - should fail)
    };

    // Create contract for insufficient stack test
    var insufficient_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &insufficient_stack_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer insufficient_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &insufficient_stack_bytecode);

    // Execute the contract
    const insufficient_result = try evm.interpretCompat(&insufficient_contract, &[_]u8{}, false);
    try testing.expect(insufficient_result.status == .Invalid);
}

// Test division by zero and modulo by zero
test "E2E: Division by zero - EVM behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test division by zero (EVM returns 0)
    const div_zero_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x00, // PUSH1 0
        0x04, // DIV (5 / 0)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract for division by zero test
    var div_zero_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &div_zero_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer div_zero_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &div_zero_bytecode);

    // Execute the contract
    const div_zero_result = try evm.interpretCompat(&div_zero_contract, &[_]u8{}, false);
    try testing.expect(div_zero_result.status == .Success);
    if (div_zero_result.output) |_| {
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 0), result_value); // Division by zero returns 0
    }

    // Test modulo by zero (EVM returns 0)
    const mod_zero_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x00, // PUSH1 0
        0x06, // MOD (5 % 0)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract for modulo by zero test
    var mod_zero_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &mod_zero_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer mod_zero_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &mod_zero_bytecode);

    // Execute the contract
    const mod_zero_result = try evm.interpretCompat(&mod_zero_contract, &[_]u8{}, false);
    try testing.expect(mod_zero_result.status == .Success);
    if (mod_zero_result.output) |_| {
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 0), result_value); // Modulo by zero returns 0
    }
}

// Test memory expansion and large memory access
test "E2E: Memory expansion - large offset testing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test memory expansion with reasonable large offset
    const memory_expansion_bytecode = [_]u8{
        // Store data at memory offset 1024
        0x60, 0x42, // PUSH1 0x42 (value)
        0x61, 0x04, 0x00, // PUSH2 0x0400 (offset = 1024)
        0x52, // MSTORE

        // Load data back from the same offset
        0x61, 0x04, 0x00, // PUSH2 0x0400 (offset = 1024)
        0x51, // MLOAD

        // Return the loaded value
        0x60, 0x00, // PUSH1 0 (memory offset for return)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xF3, // RETURN
    };

    // Create contract for memory expansion test
    var expansion_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        200_000, // More gas for memory expansion
        &memory_expansion_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer expansion_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &memory_expansion_bytecode);

    // Execute the contract
    const expansion_result = try evm.interpretCompat(&expansion_contract, &[_]u8{}, false);
    try testing.expect(expansion_result.status == .Success);
    if (expansion_result.output) |_| {
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 0x42), result_value);
    }

    // Verify memory expansion consumed extra gas
    // Memory expansion consumed gas
    try testing.expect(expansion_result.gas_used > 100); // Should use some gas for expansion
}

// Test invalid jump destinations
test "E2E: Invalid jumps - bad jump destinations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected in test", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test jump to invalid destination (not JUMPDEST)
    const invalid_jump_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (invalid jump target)
        0x56, // JUMP (should fail - destination 5 is not JUMPDEST)
        0x60, 0x42, // PUSH1 42 (never reached)
        0x00, // STOP
    };

    // Create contract for invalid jump test
    var invalid_jump_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &invalid_jump_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer invalid_jump_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &invalid_jump_bytecode);

    // Execute the contract
    const invalid_jump_result = try evm.interpretCompat(&invalid_jump_contract, &[_]u8{}, false);
    try testing.expect(invalid_jump_result.status == .Invalid);

    // Test valid jump to JUMPDEST
    const valid_jump_bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4 (valid jump target - JUMPDEST at position 4)
        0x56, // JUMP
        0x00, // STOP (skipped)
        0x5B, // JUMPDEST (destination 4)
        0x60, 0x42, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xF3, // RETURN
    };

    // Create contract for valid jump test
    var valid_jump_contract = Contract.init_at_address(
        CONTRACT_ADDRESS, // caller
        CONTRACT_ADDRESS, // address where code executes
        0, // value
        100_000, // gas
        &valid_jump_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer valid_jump_contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(CONTRACT_ADDRESS, &valid_jump_bytecode);

    // Execute the contract
    const valid_jump_result = try evm.interpretCompat(&valid_jump_contract, &[_]u8{}, false);
    try testing.expect(valid_jump_result.status == .Success);
    if (valid_jump_result.output) |_| {
        var result_value: u256 = 0;
        for (output) |_| {
            result_value = (result_value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 0x42), result_value); // 0x42 = 66 in decimal
    }
}
