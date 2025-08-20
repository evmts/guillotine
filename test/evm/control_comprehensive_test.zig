const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const Evm = evm.Evm;
const Frame = evm.Frame;
const Host = evm.Host;
const ExecutionError = evm.ExecutionError;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address;

// ============================================================================
// E2E Tests - Testing control.zig code paths via bytecode execution
// ============================================================================

test "E2E: STOP opcode halts execution" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x00,       // STOP
        0x60, 0x02, // PUSH1 2 (should not execute)
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // STOP should succeed with no output
    try testing.expect(result.success);
    try testing.expect(result.output == null or result.output.?.len == 0);
}

test "E2E: JUMPDEST is a no-op" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x5b,       // JUMPDEST (no-op)
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "E2E: RETURN with empty data" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    try testing.expect(result.output == null or result.output.?.len == 0);
}

test "E2E: RETURN with data from memory" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "E2E: RETURN with out of bounds offset" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x7f,       // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // Max u256 offset
        0xf3,       // RETURN
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should fail with out of offset
    try testing.expect(!result.success);
}

test "E2E: REVERT with empty data" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd,       // REVERT
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // REVERT should fail
    try testing.expect(!result.success);
}

test "E2E: REVERT with data from memory" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0xDE, // PUSH1 0xDE
        0x60, 0xAD, // PUSH1 0xAD
        0x60, 0xBE, // PUSH1 0xBE
        0x60, 0xEF, // PUSH1 0xEF
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x01, // PUSH1 1
        0x52,       // MSTORE
        0x60, 0x02, // PUSH1 2
        0x52,       // MSTORE
        0x60, 0x03, // PUSH1 3
        0x52,       // MSTORE
        0x60, 0x04, // PUSH1 4 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd,       // REVERT
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // REVERT should fail but provide output
    try testing.expect(!result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 4), output.len);
        try testing.expectEqual(@as(u8, 0xEF), output[0]);
        try testing.expectEqual(@as(u8, 0xBE), output[1]);
        try testing.expectEqual(@as(u8, 0xAD), output[2]);
        try testing.expectEqual(@as(u8, 0xDE), output[3]);
    }
}

test "E2E: INVALID opcode consumes all gas" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0xfe,       // INVALID
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const initial_gas: u64 = 100000;
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = initial_gas,
        },
    };
    
    const result = try vm.call(params);
    // INVALID should fail
    try testing.expect(!result.success);
    // All gas should be consumed (check remaining is 0 instead)
    try testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "E2E: SELFDESTRUCT in static context fails" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Create a contract that calls SELFDESTRUCT
    const bytecode = &[_]u8{
        0x73,       // PUSH20
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // Address 0x1
        0xff,       // SELFDESTRUCT
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    // Use STATICCALL to invoke in static context
    const caller_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x61, 0x10, 0x00, // PUSH2 0x1000 (contract address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xfa,       // STATICCALL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const caller_addr = Address.from_u256(0x2000);
    try vm.state.set_code(caller_addr, caller_bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = caller_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // The call should succeed, but STATICCALL should have failed
    try testing.expect(result.success);
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0), value); // STATICCALL failed
    }
}

test "E2E: SELFDESTRUCT with cold recipient address" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Set some balance to the contract
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_balance(contract_addr, 1000);
    
    const bytecode = &[_]u8{
        0x73,       // PUSH20
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBE, 0xEF, // Address 0xBEEF (cold)
        0xff,       // SELFDESTRUCT
    };
    
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should succeed
    try testing.expect(result.success);
    
    // Check that balance was transferred
    const recipient_addr = Address.from_u256(0xBEEF);
    const recipient_balance = vm.state.get_balance(recipient_addr);
    try testing.expectEqual(@as(u256, 1000), recipient_balance);
}

test "E2E: Complex control flow with JUMPI and RETURN" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that returns different values based on calldata
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        0x60, 0x01, // PUSH1 1
        0x14,       // EQ
        0x60, 0x0E, // PUSH1 14 (jump target)
        0x57,       // JUMPI
        // Return 0xFF if calldata != 1
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        // Jump destination at 14
        0x5b,       // JUMPDEST
        // Return 0x42 if calldata == 1
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    // Test with calldata = 1
    var input_data: [32]u8 = undefined;
    @memset(&input_data, 0);
    input_data[31] = 1;
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "E2E: RETURN with memory expansion gas cost" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Return large memory region
    const bytecode = &[_]u8{
        0x61, 0x01, 0x00, // PUSH2 256 (size)
        0x60, 0x00,       // PUSH1 0 (offset)
        0xf3,             // RETURN
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 256), output.len);
        // Memory should be zero-initialized
        for (output) |_| {
            try testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "E2E: REVERT reverses state changes" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that stores value then reverts
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (should be reverted)
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd,       // REVERT
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should fail due to REVERT
    try testing.expect(!result.success);
    
    // Storage should not have been modified
    const storage_value = vm.state.get_storage(contract_addr, 0);
    try testing.expectEqual(@as(u256, 0), storage_value);
}

test "E2E: INVALID opcode in nested call" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract A with INVALID opcode
    const contract_a_bytecode = &[_]u8{
        0xfe,       // INVALID
    };
    
    const contract_a_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_a_addr, contract_a_bytecode);
    
    // Contract B that calls A
    const contract_b_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x61, 0x10, 0x00, // PUSH2 0x1000 (address A)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_b_addr = Address.from_u256(0x2000);
    try vm.state.set_code(contract_b_addr, contract_b_bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_b_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Outer call should succeed
    try testing.expect(result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        // Inner call should have failed (0)
        try testing.expectEqual(@as(u256, 0), value);
    }
}

test "E2E: SELFDESTRUCT with created contract tracking (EIP-6780)" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Deploy a contract that can selfdestruct
    const init_code = &[_]u8{
        // Constructor: deploy runtime code
        0x60, 0x0A, // PUSH1 10 (size of runtime code)
        0x60, 0x0C, // PUSH1 12 (offset to runtime code)
        0x60, 0x00, // PUSH1 0 (dest offset)
        0x39,       // CODECOPY
        0x60, 0x0A, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
        // Runtime code (SELFDESTRUCT)
        0x73,       // PUSH20
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, // Address 0xDEAD
        0xff,       // SELFDESTRUCT
    };
    
    // Deploy contract
    const create_result = try vm.create_contract(Address.ZERO, 0, init_code, 100000);
    try testing.expect(create_result.success);
    
    const created_addr = create_result.address;
    
    // Set balance to created contract
    try vm.state.set_balance(created_addr, 500);
    
    // Now call the contract to trigger SELFDESTRUCT
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = created_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should succeed
    try testing.expect(result.success);
    
    // Check that balance was transferred to recipient
    const recipient_addr = Address.from_u256(0xDEAD);
    const recipient_balance = vm.state.get_balance(recipient_addr);
    try testing.expectEqual(@as(u256, 500), recipient_balance);
}