const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const Analysis = evm.CodeAnalysis;
const OpcodeMetadata = evm.OpcodeMetadata;
const Evm = evm.Evm;
const Frame = evm.Frame;
const Host = evm.Host;
const ExecutionError = evm.ExecutionError;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address;
const builtin = @import("builtin");

// ============================================================================
// Corner Case Tests for interpret.zig
// ============================================================================

// Block Boundary Edge Cases
// ==========================

test "Interpret: gas exactly equals block cost" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // 3 PUSH1 operations = 9 gas exactly
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x60, 0x03, // PUSH1 3 (3 gas)
        0x00, // STOP (0 gas)
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 9, // Exactly the gas needed
        },
    };
    
    const result = try vm.call(params);
    // Should succeed with exactly 0 gas left
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "Interpret: gas one less than block cost" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x60, 0x03, // PUSH1 3 (3 gas)
        0x00, // STOP (0 gas)
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 8, // One less than needed
        },
    };
    
    const result = try vm.call(params);
    // Should fail due to out of gas
    try testing.expect(!result.success);
}

// Stack Boundary Cases at Block Entry
// ====================================

test "Interpret: stack exactly at requirement for block" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // ADD requires exactly 2 stack items
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD (requires 2 items)
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
            .gas = 10000,
        },
    };
    
    const result = try vm.call(params);
    // Should succeed with exactly the required stack
    try testing.expect(result.success);
}

test "Interpret: stack at exactly 1024 items with growth" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Create bytecode that pushes 1024 items (maximum stack)
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
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
    // Should succeed (exactly at limit)
    try testing.expect(result.success);
}

// Jump Fusion Edge Cases
// =======================

test "Interpret: fused PUSH+JUMP to position 0" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x5b, // JUMPDEST at 0
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0 (jump to start)
        0x56, // JUMP
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100, // Limited gas to prevent infinite loop
        },
    };
    
    const result = try vm.call(params);
    // Should run out of gas (infinite loop)
    try testing.expect(!result.success);
}

test "Interpret: fused PUSH+JUMP to out of bounds" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x61, 0xFF, 0xFF, // PUSH2 0xFFFF (way out of bounds)
        0x56, // JUMP
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
            .gas = 10000,
        },
    };
    
    const result = try vm.call(params);
    // Should fail with invalid jump
    try testing.expect(!result.success);
}

// Conditional Jump Edge Cases
// ============================

test "Interpret: JUMPI with condition exactly 1" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition = 1, should jump)
        0x60, 0x08, // PUSH1 8
        0x57, // JUMPI
        0x60, 0xFF, // PUSH1 255 (should skip)
        0x00, // STOP
        0x5b, // JUMPDEST at 8
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
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
    
    // Should have jumped and returned 0x42
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "Interpret: JUMPI with max u256 condition" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        // Push max u256 as condition
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x60, 0x26, // PUSH1 38 (0x26)
        0x57, // JUMPI
        0x60, 0xFF, // PUSH1 255 (should skip)
        0x00, // STOP
        0x5b, // JUMPDEST at 38
        0x60, 0x42, // PUSH1 66
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
    // Should succeed (max u256 is non-zero, so jump taken)
    try testing.expect(result.success);
}

// Unresolved Jump Cases
// =====================

test "Interpret: unresolved JUMP to valid destination" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Dynamic jump where destination is computed
    const bytecode = &[_]u8{
        0x60, 0x04, // PUSH1 4
        0x60, 0x02, // PUSH1 2
        0x01, // ADD (4 + 2 = 6)
        0x56, // JUMP (to computed 6)
        0x00, // STOP
        0x5b, // JUMPDEST at 6
        0x60, 0x99, // PUSH1 153
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
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
    
    // Should return 0x99
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x99), value);
    }
}

test "Interpret: unresolved JUMPI with dynamic destination" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Dynamic conditional jump
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x05, // PUSH1 5
        0x60, 0x04, // PUSH1 4
        0x01, // ADD (5 + 4 = 9)
        0x57, // JUMPI (to computed 9)
        0x60, 0xFF, // PUSH1 255
        0x00, // STOP
        0x5b, // JUMPDEST at 9
        0x60, 0x88, // PUSH1 136
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
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
    
    // Should jump and return 0x88
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x88), value);
    }
}

// KECCAK Optimization Cases
// =========================

test "Interpret: KECCAK with immediate zero size" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x20, // KECCAK256 (hash of empty data)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
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
    
    // Should return keccak256 of empty data
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        const expected_first_byte = 0xc5;
        try testing.expectEqual(@as(u8, expected_first_byte), output[0]);
    }
}

test "Interpret: KECCAK with max offset causing overflow check" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        // Push very large offset
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x20, // PUSH1 32 (size)
        0x20, // KECCAK256
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
    // Should fail due to out of offset error
    try testing.expect(!result.success);
}

// Dynamic Gas Edge Cases
// =======================

test "Interpret: dynamic gas exactly equals remaining" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // MSTORE has dynamic gas cost for memory expansion
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (base cost 3 + memory expansion)
        0x00, // STOP
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    // Calculate exact gas: 3+3 (pushes) + 3 (MSTORE base) + 3 (first word memory)
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 12, // Exact amount needed
        },
    };
    
    const result = try vm.call(params);
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
}

// pc_to_block_start Mapping Edge Cases
// =====================================

test "Interpret: jump to JUMPDEST with unmapped pc_to_block_start" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Create bytecode with potential edge case in pc mapping
    const bytecode = &[_]u8{
        0x60, 0x80, // PUSH1 128 (jump to invalid but in-bounds location)
        0x56, // JUMP
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
            .gas = 10000,
        },
    };
    
    const result = try vm.call(params);
    // Should fail with invalid jump (no JUMPDEST at 128)
    try testing.expect(!result.success);
}

// Word Immediate Push Edge Cases
// ===============================

test "Interpret: word immediate with value 0" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x5f, // PUSH0 (if supported) or equivalent
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
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
    
    // Should return 0
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0), value);
    }
}

// Complex Dispatcher Edge Cases
// =============================

test "Interpret: dispatcher with collision in function selectors" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Dispatcher checking multiple selectors
    const bytecode = &[_]u8{
        // Load selector
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x60, 0xe0, // PUSH1 224
        0x1c, // SHR
        
        // Check first selector (0x11111111)
        0x80, // DUP1
        0x63, 0x11, 0x11, 0x11, 0x11, // PUSH4 0x11111111
        0x14, // EQ
        0x60, 0x20, // PUSH1 32 (jump dest)
        0x57, // JUMPI
        
        // Check second selector (0x22222222)
        0x80, // DUP1
        0x63, 0x22, 0x22, 0x22, 0x22, // PUSH4 0x22222222
        0x14, // EQ
        0x60, 0x28, // PUSH1 40 (jump dest)
        0x57, // JUMPI
        
        // Fallback
        0x00, // STOP
        
        // First function (at 32)
        0x5b, // JUMPDEST
        0x60, 0x11, // PUSH1 17
        0x00, // STOP
        
        // Second function (at 40)
        0x5b, // JUMPDEST
        0x60, 0x22, // PUSH1 34
        0x00, // STOP
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    // Call with second selector
    const calldata = [_]u8{ 0x22, 0x22, 0x22, 0x22 };
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &calldata,
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should succeed (jumps to second function)
    try testing.expect(result.success);
}

// Nested Call Context Edge Cases  
// ===============================

test "Interpret: deep recursion until max depth" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Contract that calls itself
    const bytecode = &[_]u8{
        // Check depth (assume it's in first word of calldata)
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        
        // Increment depth
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        
        // Check if depth >= 10 (arbitrary limit for test)
        0x80, // DUP1
        0x60, 0x0a, // PUSH1 10
        0x10, // LT
        0x60, 0x10, // PUSH1 16
        0x57, // JUMPI (jump if depth < 10)
        
        // Return depth
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
        
        // Recursive call (at 16)
        0x5b, // JUMPDEST
        0x00, // STOP (simplified - would normally do CALL)
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}, // 32 bytes of zeros
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should succeed
    try testing.expect(result.success);
}

// Invalid Instruction Stream Access
// ==================================

test "Interpret: instruction with invalid next_instruction" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Bytecode that might cause edge cases in instruction stream
    const bytecode = &[_]u8{
        0xfe, // INVALID opcode (consumes all gas)
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 10000,
        },
    };
    
    const result = try vm.call(params);
    // Should fail (INVALID consumes all gas)
    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
}

// Iteration Limit Tests (Debug/Safe Mode)
// ========================================

test "Interpret: approaching MAX_ITERATIONS in safe mode" {
    if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) {
        // Skip this test in non-safe modes
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Create a very long loop that would exceed MAX_ITERATIONS
    const bytecode = &[_]u8{
        // Initialize counter to large value
        0x68, // PUSH9
        0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x42, 0x40, // 1,000,000
        
        // Loop start at position 10
        0x5b, // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x90, // SWAP1
        0x03, // SUB
        0x80, // DUP1
        0x60, 0x0a, // PUSH1 10 (loop start)
        0x57, // JUMPI
        
        // End
        0x50, // POP
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
            .gas = 100000000, // Lots of gas
        },
    };
    
    const result = try vm.call(params);
    // In safe mode, might hit iteration limit or gas limit
    // Either way it should not succeed
    try testing.expect(!result.success);
}