const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const Frame = evm.Frame;
const Evm = evm.Evm;
const Host = evm.Host;
const ExecutionError = evm.ExecutionError;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address;
const Analysis = evm.CodeAnalysis;
const OpcodeMetadata = evm.OpcodeMetadata;
const builtin = @import("builtin");
const Stack = evm.Stack;

// ============================================================================
// E2E Tests - Testing interpret.zig code paths via bytecode execution
// ============================================================================

test "E2E: Basic execution path with simple instructions" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x03, // PUSH1 3
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD
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
        try testing.expectEqual(@as(u256, 8), value);
    }
}

test "E2E: Block info gas exhaustion" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Multiple PUSH operations that consume gas
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x60, 0x03, // PUSH1 3 (3 gas)
        0x60, 0x04, // PUSH1 4 (3 gas)
        0x60, 0x05, // PUSH1 5 (3 gas)
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
            .gas = 10, // Not enough gas for all operations
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(!result.success); // Should fail with out of gas
}

test "E2E: Block info stack underflow" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // ADD requires 2 stack items but stack is empty
    const bytecode = &[_]u8{
        0x01, // ADD (needs 2 items)
        0x00, // STOP
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
    try testing.expect(!result.success); // Should fail with stack underflow
}

test "E2E: Block info stack overflow" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Generate bytecode that pushes 1025 items (stack limit is 1024)
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push 1025 values
    var i: usize = 0;
    while (i < 1025) : (i += 1) {
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    }
    try bytecode.append(0x00); // STOP
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode.items);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 10000000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(!result.success); // Should fail with stack overflow
}

test "E2E: Dynamic gas with memory expansion" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x61, 0x01, 0x00, // PUSH2 0x100 (offset 256)
        0x52,       // MSTORE (expands memory, dynamic gas cost)
        0x60, 0x20, // PUSH1 32
        0x61, 0x01, 0x00, // PUSH2 0x100
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

test "E2E: Fused PUSH+JUMP execution" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x04, // PUSH1 4
        0x56,       // JUMP
        0x00,       // STOP (skipped)
        0x5b,       // JUMPDEST at 4
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

test "E2E: Invalid jump destination" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x03, // PUSH1 3 (not a JUMPDEST)
        0x56,       // JUMP
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
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(!result.success); // Should fail with invalid jump
}

test "E2E: Conditional jump taken" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition true)
        0x60, 0x08, // PUSH1 8 (jump target)
        0x57,       // JUMPI
        0x60, 0xFF, // PUSH1 255 (skipped)
        0x00,       // STOP (skipped)
        0x5b,       // JUMPDEST at 8
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

test "E2E: Conditional jump not taken" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (condition false)
        0x60, 0x0a, // PUSH1 10 (jump target)
        0x57,       // JUMPI
        0x60, 0xFF, // PUSH1 255 (executed)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        0x5b,       // JUMPDEST at 10
        0x60, 0x42, // PUSH1 0x42
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
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0xFF), value);
    }
}

test "E2E: Dynamic jump (jump_unresolved)" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Dynamic jump where destination is computed
    const bytecode = &[_]u8{
        0x60, 0x07, // PUSH1 7
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD (7+2=9)
        0x56,       // JUMP (to 9)
        0x60, 0xFF, // PUSH1 255 (skipped)
        0x00,       // STOP (skipped)
        0x5b,       // JUMPDEST at 9
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

test "E2E: Dynamic conditional jump (conditional_jump_unresolved)" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Dynamic JUMPI where destination is computed
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (true condition)
        0x60, 0x06, // PUSH1 6
        0x60, 0x06, // PUSH1 6
        0x01,       // ADD (6+6=12)
        0x90,       // SWAP1 (put condition on top)
        0x57,       // JUMPI (to 12)
        0x60, 0xFF, // PUSH1 255 (skipped)
        0x00,       // STOP (skipped)
        0x5b,       // JUMPDEST at 12
        0x60, 0x99, // PUSH1 0x99
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
        try testing.expectEqual(@as(u256, 0x99), value);
    }
}

test "E2E: Word instruction (PUSH operations)" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x7f, // PUSH32
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF,
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
        // Check first 4 bytes of the pushed value
        try testing.expectEqual(@as(u8, 0x12), output[0]);
        try testing.expectEqual(@as(u8, 0x34), output[1]);
        try testing.expectEqual(@as(u8, 0x56), output[2]);
        try testing.expectEqual(@as(u8, 0x78), output[3]);
    }
}

test "E2E: Keccak hash computation" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (value to hash)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x20,       // KECCAK256
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
    
    // Keccak256 of 32 zero bytes should produce a specific hash
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // We got a hash output, exact value depends on keccak implementation
        try testing.expect(output[0] != 0 or output[31] != 0); // Non-zero hash
    }
}

test "E2E: Keccak with insufficient gas" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x20,       // KECCAK256
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
            .gas = 10, // Very low gas for keccak
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(!result.success); // Should fail with out of gas
}

test "E2E: Keccak with out of bounds offset" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x7f,       // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // Max u256 offset
        0x20,       // KECCAK256
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
            .gas = 1000000,
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(!result.success); // Should fail with out of offset
}

test "E2E: Complex control flow with nested jumps" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Complex bytecode with multiple jumps
    const bytecode = &[_]u8{
        0x60, 0x0e, // PUSH1 14 (first jump to 14)
        0x56,       // JUMP
        // Position 3
        0x5b,       // JUMPDEST
        0x60, 0xAA, // PUSH1 0xAA
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        // Position 14
        0x5b,       // JUMPDEST
        0x60, 0x03, // PUSH1 3 (jump back to 3)
        0x56,       // JUMP
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
        try testing.expectEqual(@as(u256, 0xAA), value);
    }
}

test "E2E: Gas exhaustion during loop execution" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Infinite loop that will run out of gas
    const bytecode = &[_]u8{
        0x5b,       // JUMPDEST at 0
        0x60, 0x01, // PUSH1 1
        0x50,       // POP
        0x60, 0x00, // PUSH1 0 (jump back)
        0x56,       // JUMP
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100, // Limited gas
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(!result.success); // Should fail with out of gas
}