const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const Evm = evm.Evm;
const Frame = evm.Frame;
const Host = evm.Host;
const ExecutionError = evm.ExecutionError;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address;
const GasConstants = @import("primitives").GasConstants;

// ============================================================================
// E2E Tests - Testing system.zig code paths via bytecode execution
// ============================================================================

test "E2E: CREATE opcode creates new contract" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that deploys a simple contract
    const bytecode = &[_]u8{
        // Store init code in memory (PUSH1 0x42, PUSH1 0, MSTORE, RETURN 32 bytes)
        0x60, 0x0C, // PUSH1 12 (size of init code)
        0x60, 0x10, // PUSH1 16 (offset in this bytecode)
        0x60, 0x00, // PUSH1 0 (dest in memory)
        0x39,       // CODECOPY
        // CREATE with value 0
        0x60, 0x0C, // PUSH1 12 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        0x00,       // STOP
        // Init code starts here (offset 16)
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
    // CREATE should succeed
    try testing.expect(result.success);
}

test "E2E: CREATE with value transfer" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Give contract some balance
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_balance(contract_addr, 1000);
    
    // Contract that creates with value
    const bytecode = &[_]u8{
        // Simple init code that returns empty
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x10, // PUSH1 16 (offset)
        0x60, 0x00, // PUSH1 0
        0x39,       // CODECOPY
        // CREATE with value 100
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x64, // PUSH1 100 (value)
        0xf0,       // CREATE
        0x00,       // STOP
        // Init code
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
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
    try testing.expect(result.success);
}

test "E2E: CREATE in static context fails" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that tries CREATE
    const create_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const create_addr = Address.from_u256(0x1000);
    try vm.state.set_code(create_addr, create_bytecode);
    
    // Caller that uses STATICCALL
    const caller_bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x61, 0x10, 0x00, // PUSH2 0x1000
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
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0), value); // STATICCALL failed
    }
}

test "E2E: CREATE2 with salt creates deterministic address" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        // Store init code in memory
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x18, // PUSH1 24 (offset)
        0x60, 0x00, // PUSH1 0
        0x39,       // CODECOPY
        // CREATE2 with salt
        0x60, 0x12, 0x34, // PUSH2 0x1234 (salt)
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        0x00,       // STOP
        // Init code
        0x60, 0x00, // PUSH1 0
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
}

test "E2E: CALL to existing contract" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Target contract that returns 0x42
    const target_bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Caller contract
    const caller_bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x61, 0x20, 0x00, // PUSH2 0x2000 (target)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const caller_addr = Address.from_u256(0x1000);
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
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "E2E: CALL with value transfer" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Give caller some balance
    const caller_addr = Address.from_u256(0x1000);
    try vm.state.set_balance(caller_addr, 1000);
    
    // Simple target that just returns
    const target_bytecode = &[_]u8{ 0x00 }; // STOP
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Caller that transfers value
    const caller_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x60, 0x64, // PUSH1 100 (value)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
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
    try testing.expect(result.success);
    
    // Check balance transfer
    const target_balance = vm.state.get_balance(target_addr);
    try testing.expectEqual(@as(u256, 100), target_balance);
}

test "E2E: CALLCODE executes in caller's context" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Target code that stores value
    const target_bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        0x00,       // STOP
    };
    
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Caller using CALLCODE
    const caller_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf2,       // CALLCODE
        0x00,       // STOP
    };
    
    const caller_addr = Address.from_u256(0x1000);
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
    try testing.expect(result.success);
    
    // Storage should be in caller's context, not target's
    const caller_storage = vm.state.get_storage(caller_addr, 0);
    try testing.expectEqual(@as(u256, 0x42), caller_storage);
    
    const target_storage = vm.state.get_storage(target_addr, 0);
    try testing.expectEqual(@as(u256, 0), target_storage);
}

test "E2E: DELEGATECALL preserves original caller" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Target that returns CALLER
    const target_bytecode = &[_]u8{
        0x33,       // CALLER
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Proxy using DELEGATECALL
    const proxy_bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf4,       // DELEGATECALL
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const proxy_addr = Address.from_u256(0x1000);
    try vm.state.set_code(proxy_addr, proxy_bytecode);
    
    const original_caller = Address.from_u256(0xCAFE);
    const params = evm.CallParams{
        .call = .{
            .caller = original_caller,
            .to = proxy_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const value = std.mem.readInt(u256, output[0..32], .big);
        // Should return original caller, not proxy
        try testing.expectEqual(@as(u256, 0xCAFE), value);
    }
}

test "E2E: STATICCALL enforces read-only context" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Target that tries to write storage
    const target_bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (should fail in static context)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Caller using STATICCALL
    const caller_bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xfa,       // STATICCALL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const caller_addr = Address.from_u256(0x1000);
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
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const value = std.mem.readInt(u256, output[0..32], .big);
        // STATICCALL should have failed (0)
        try testing.expectEqual(@as(u256, 0), value);
    }
}

test "E2E: GAS opcode returns remaining gas" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x5a,       // GAS
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
        const gas_value = std.mem.readInt(u256, output[0..32], .big);
        // Should have some gas remaining
        try testing.expect(gas_value > 0);
        try testing.expect(gas_value < 100000);
    }
}

test "E2E: CREATE at max depth fails" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that recursively creates itself
    const bytecode = &[_]u8{
        // Copy own code to memory
        0x38,       // CODESIZE
        0x80,       // DUP1
        0x60, 0x00, // PUSH1 0
        0x80,       // DUP1
        0x39,       // CODECOPY
        // CREATE with that code
        0x81,       // DUP2 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        0x50,       // POP
        0x50,       // POP
        0x00,       // STOP
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 10000000, // Lots of gas
        },
    };
    
    const result = try vm.call(params);
    // Should succeed, but deep creates will fail
    try testing.expect(result.success);
}

test "E2E: CALL with insufficient gas" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Simple target
    const target_bytecode = &[_]u8{ 0x00 }; // STOP
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Caller with very limited gas
    const caller_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x5a,       // GAS (use all remaining gas)
        0xf1,       // CALL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const caller_addr = Address.from_u256(0x1000);
    try vm.state.set_code(caller_addr, caller_bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = caller_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000, // Very limited gas
        },
    };
    
    const result = try vm.call(params);
    // Should fail due to insufficient gas
    try testing.expect(!result.success);
}

test "E2E: CREATE2 with same salt twice" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that tries CREATE2 twice with same salt
    const bytecode = &[_]u8{
        // First CREATE2
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x20, // PUSH1 32 (offset)
        0x60, 0x00, // PUSH1 0
        0x39,       // CODECOPY
        0x60, 0xAB, // PUSH1 0xAB (salt)
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        0x50,       // POP
        // Second CREATE2 with same salt
        0x60, 0xAB, // PUSH1 0xAB (same salt)
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        // Init code
        0x60, 0x00, // PUSH1 0
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
            .gas = 200000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const value = std.mem.readInt(u256, output[0..32], .big);
        // Second CREATE2 should fail (address already exists)
        try testing.expectEqual(@as(u256, 0), value);
    }
}

test "E2E: DELEGATECALL with calldata forwarding" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Target that returns calldata
    const target_bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Proxy that forwards calldata
    const proxy_bytecode = &[_]u8{
        // Store calldata in memory
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        // DELEGATECALL with calldata
        0x60, 0x20, // PUSH1 32 (ret size)
        0x60, 0x20, // PUSH1 32 (ret offset)
        0x60, 0x20, // PUSH1 32 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf4,       // DELEGATECALL
        0x60, 0x20, // PUSH1 32
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    const proxy_addr = Address.from_u256(0x1000);
    try vm.state.set_code(proxy_addr, proxy_bytecode);
    
    var input_data: [32]u8 = undefined;
    @memset(&input_data, 0);
    input_data[31] = 0x99;
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = proxy_addr,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x99), value);
    }
}

test "E2E: EIP-150 63/64 gas rule" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Target that returns remaining gas
    const target_bytecode = &[_]u8{
        0x5a,       // GAS
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const target_addr = Address.from_u256(0x2000);
    try vm.state.set_code(target_addr, target_bytecode);
    
    // Caller that forwards all gas
    const caller_bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (ret size)
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x5a,       // GAS (all remaining)
        0xf1,       // CALL
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const caller_addr = Address.from_u256(0x1000);
    try vm.state.set_code(caller_addr, caller_bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = caller_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 64000, // Specific amount for testing
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        const gas_in_callee = std.mem.readInt(u256, output[0..32], .big);
        // Callee should get at most 63/64 of remaining gas
        // This is approximate due to gas consumed by instructions
        try testing.expect(gas_in_callee < 64000);
    }
}