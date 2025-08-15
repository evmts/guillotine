const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const Analysis = evm.CodeAnalysis;
const OpcodeMetadata = evm.OpcodeMetadata;
const Opcode = evm.opcodes.opcode;
const Evm = evm.Evm;
const Frame = evm.Frame;
const Host = evm.Host;
const ExecutionError = evm.ExecutionError;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address;

test {
    std.testing.log_level = .warn;
}

// ============================================================================
// Unit Tests - Testing analysis.zig functions in isolation
// ============================================================================

test "JumpdestArray: from_bitmap with empty bitmap" {
    const allocator = testing.allocator;
    
    // Create empty bitmap
    var bitmap = try std.DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    
    // Convert to JumpdestArray
    var jumpdest_array = try Analysis.JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // Should have no positions
    try testing.expectEqual(@as(usize, 0), jumpdest_array.positions.len);
    try testing.expectEqual(@as(usize, 100), jumpdest_array.code_len);
}

test "JumpdestArray: from_bitmap with single jumpdest" {
    const allocator = testing.allocator;
    
    // Create bitmap with single bit set
    var bitmap = try std.DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    bitmap.set(42);
    
    // Convert to JumpdestArray
    var jumpdest_array = try Analysis.JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // Should have one position
    try testing.expectEqual(@as(usize, 1), jumpdest_array.positions.len);
    try testing.expectEqual(@as(u15, 42), jumpdest_array.positions[0]);
}

test "JumpdestArray: from_bitmap with multiple jumpdests" {
    const allocator = testing.allocator;
    
    // Create bitmap with multiple bits set
    var bitmap = try std.DynamicBitSet.initEmpty(allocator, 200);
    defer bitmap.deinit();
    bitmap.set(10);
    bitmap.set(50);
    bitmap.set(100);
    bitmap.set(150);
    
    // Convert to JumpdestArray
    var jumpdest_array = try Analysis.JumpdestArray.from_bitmap(allocator, &bitmap, 200);
    defer jumpdest_array.deinit(allocator);
    
    // Should have four positions in order
    try testing.expectEqual(@as(usize, 4), jumpdest_array.positions.len);
    try testing.expectEqual(@as(u15, 10), jumpdest_array.positions[0]);
    try testing.expectEqual(@as(u15, 50), jumpdest_array.positions[1]);
    try testing.expectEqual(@as(u15, 100), jumpdest_array.positions[2]);
    try testing.expectEqual(@as(u15, 150), jumpdest_array.positions[3]);
}

test "JumpdestArray: is_valid_jumpdest with empty array" {
    const allocator = testing.allocator;
    
    var bitmap = try std.DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    
    var jumpdest_array = try Analysis.JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // All queries should return false
    try testing.expect(!jumpdest_array.is_valid_jumpdest(0));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(50));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(99));
}

test "JumpdestArray: is_valid_jumpdest with valid positions" {
    const allocator = testing.allocator;
    
    var bitmap = try std.DynamicBitSet.initEmpty(allocator, 200);
    defer bitmap.deinit();
    bitmap.set(10);
    bitmap.set(50);
    bitmap.set(100);
    bitmap.set(150);
    
    var jumpdest_array = try Analysis.JumpdestArray.from_bitmap(allocator, &bitmap, 200);
    defer jumpdest_array.deinit(allocator);
    
    // Valid positions should return true
    try testing.expect(jumpdest_array.is_valid_jumpdest(10));
    try testing.expect(jumpdest_array.is_valid_jumpdest(50));
    try testing.expect(jumpdest_array.is_valid_jumpdest(100));
    try testing.expect(jumpdest_array.is_valid_jumpdest(150));
    
    // Invalid positions should return false
    try testing.expect(!jumpdest_array.is_valid_jumpdest(0));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(11));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(49));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(51));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(99));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(101));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(149));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(151));
}

test "JumpdestArray: is_valid_jumpdest out of bounds" {
    const allocator = testing.allocator;
    
    var bitmap = try std.DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    bitmap.set(50);
    
    var jumpdest_array = try Analysis.JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // Out of bounds should return false
    try testing.expect(!jumpdest_array.is_valid_jumpdest(100));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(200));
    try testing.expect(!jumpdest_array.is_valid_jumpdest(std.math.maxInt(usize)));
}

test "CodeAnalysis: from_code with empty bytecode" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{};
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should have single STOP instruction
    try testing.expectEqual(@as(usize, 1), analysis.instructions.len);
    try testing.expectEqual(@as(usize, 0), analysis.code.len);
    try testing.expectEqual(@as(usize, 0), analysis.jumpdest_array.positions.len);
}

test "CodeAnalysis: from_code with single STOP" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{0x00}; // STOP
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should have BEGINBLOCK and STOP instructions
    try testing.expect(analysis.instructions.len >= 2);
    try testing.expectEqual(@as(usize, 1), analysis.code.len);
}

test "CodeAnalysis: from_code with PUSH instruction" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{ 0x60, 0x42 }; // PUSH1 0x42
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should include PUSH instruction
    try testing.expect(analysis.instructions.len >= 2);
    try testing.expectEqual(@as(usize, 2), analysis.code.len);
    
    // No jumpdests
    try testing.expectEqual(@as(usize, 0), analysis.jumpdest_array.positions.len);
}

test "CodeAnalysis: from_code with JUMPDEST" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{ 0x5b, 0x00 }; // JUMPDEST, STOP
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should have jumpdest at position 0
    try testing.expectEqual(@as(usize, 1), analysis.jumpdest_array.positions.len);
    try testing.expectEqual(@as(u15, 0), analysis.jumpdest_array.positions[0]);
}

test "CodeAnalysis: from_code with multiple JUMPDESTs" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{
        0x5b, // JUMPDEST at 0
        0x60, 0x01, // PUSH1 1
        0x5b, // JUMPDEST at 3
        0x60, 0x02, // PUSH1 2
        0x5b, // JUMPDEST at 6
        0x00, // STOP
    };
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should have three jumpdests
    try testing.expectEqual(@as(usize, 3), analysis.jumpdest_array.positions.len);
    try testing.expectEqual(@as(u15, 0), analysis.jumpdest_array.positions[0]);
    try testing.expectEqual(@as(u15, 3), analysis.jumpdest_array.positions[1]);
    try testing.expectEqual(@as(u15, 6), analysis.jumpdest_array.positions[2]);
}

test "CodeAnalysis: from_code with JUMP pattern" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{
        0x60, 0x04, // PUSH1 4
        0x56, // JUMP
        0x00, // STOP (unreachable)
        0x5b, // JUMPDEST at 4
        0x00, // STOP
    };
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should have jumpdest at position 4
    try testing.expectEqual(@as(usize, 1), analysis.jumpdest_array.positions.len);
    try testing.expectEqual(@as(u15, 4), analysis.jumpdest_array.positions[0]);
}

test "CodeAnalysis: from_code ignores JUMPDEST in PUSH data" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    const bytecode = &[_]u8{
        0x61, 0x5b, 0x5b, // PUSH2 0x5b5b (contains JUMPDEST bytes as data)
        0x5b, // Real JUMPDEST at 3
        0x00, // STOP
    };
    var analysis = try Analysis.from_code(allocator, bytecode, table);
    defer analysis.deinit();
    
    // Should only have real jumpdest at position 3
    try testing.expectEqual(@as(usize, 1), analysis.jumpdest_array.positions.len);
    try testing.expectEqual(@as(u15, 3), analysis.jumpdest_array.positions[0]);
}

test "CodeAnalysis: from_code with code too large" {
    const allocator = testing.allocator;
    const table = &OpcodeMetadata.DEFAULT;
    
    // Try to create bytecode larger than MAX_CONTRACT_SIZE (24576 bytes)
    const large_bytecode = try allocator.alloc(u8, 24577);
    defer allocator.free(large_bytecode);
    @memset(large_bytecode, 0x00); // Fill with STOP
    
    // Should return error
    const result = Analysis.from_code(allocator, large_bytecode, table);
    try testing.expectError(error.CodeTooLarge, result);
}

// ============================================================================
// E2E Tests - Testing analysis with bytecode execution via call interface
// ============================================================================

test "E2E: Empty bytecode execution" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{};
    const contract_addr = Address.from_u256(0x1000);
    
    // Set up contract code
    try vm.state.set_code(contract_addr, bytecode);
    
    // Call the contract
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
    // Empty bytecode should execute successfully (implicit STOP)
    try testing.expect(result.success);
}

test "E2E: Simple PUSH and arithmetic execution" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
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
    
    // Output should contain result (5)
    try testing.expect(result.output != null);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 5), value);
    }
}

test "E2E: JUMP to valid JUMPDEST" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5 (jump target)
        0x56, // JUMP
        0x60, 0xFF, // PUSH1 255 (should be skipped)
        0x5b, // JUMPDEST at 5
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
    
    // Output should contain 0x42 (not 0xFF which was skipped)
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "E2E: JUMP to invalid destination" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x03, // PUSH1 3 (not a JUMPDEST)
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
            .gas = 100000,
        },
    };
    
    const result = try vm.call(params);
    // Should fail due to invalid jump
    try testing.expect(!result.success);
}

test "E2E: JUMPI conditional jump taken" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition - true)
        0x60, 0x08, // PUSH1 8 (jump target)
        0x57, // JUMPI
        0x60, 0xFF, // PUSH1 255 (should be skipped)
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
    std.log.warn("JUMPI test result: success={}, output_len={?}", .{ 
        result.success, 
        if (result.output) |o| o.len else null
    });
    
    try testing.expect(result.success);
    
    // Output should contain 0x42 (jump was taken)
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "E2E: JUMPI conditional jump not taken" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (condition - false)
        0x60, 0x08, // PUSH1 8 (jump target)
        0x57, // JUMPI
        0x60, 0xFF, // PUSH1 255 (should execute)
        0x00, // STOP
        0x5b, // JUMPDEST at 8
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
    // Should succeed (STOP after push)
    try testing.expect(result.success);
}

test "Debug: JUMPDEST analysis" {
    // Enable debug logging for this test
    std.testing.log_level = .warn;
    
    const allocator = testing.allocator;
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (positions 0-1)
        0x60, 0x08, // PUSH1 8 (positions 2-3)  
        0x57,       // JUMPI   (position 4)
        0x60, 0xFF, // PUSH1 255 (positions 5-6)
        0x00,       // STOP    (position 7)
        0x5b,       // JUMPDEST (position 8)
        0x60, 0x42, // PUSH1 66 (positions 9-10)
        0x60, 0x00, // PUSH1 0  (positions 11-12)
        0x52,       // MSTORE  (position 13)
        0x60, 0x20, // PUSH1 32 (positions 14-15)
        0x60, 0x00, // PUSH1 0  (positions 16-17)
        0xf3,       // RETURN  (position 18)
    };
    
    std.log.warn("\n=== Testing bytecode analysis ===", .{});
    for (bytecode, 0..) |byte, i| {
        std.log.warn("Position {d:2}: 0x{x:0>2}", .{i, byte});
    }
    
    const table = OpcodeMetadata.DEFAULT;
    
    var analysis = try Analysis.from_code(allocator, bytecode, &table);
    defer analysis.deinit();
    
    std.log.warn("\n=== Jumpdest analysis ===", .{});
    std.log.warn("Code length: {}", .{analysis.code_len});
    std.log.warn("Jumpdest array positions: {}", .{analysis.jumpdest_array.positions.len});
    
    for (analysis.jumpdest_array.positions) |pos| {
        std.log.warn("  JUMPDEST at position: {}", .{pos});
    }
    
    // Test jumpdest validation
    std.log.warn("\n=== Testing jumpdest validation ===", .{});
    for (0..bytecode.len) |i| {
        const is_valid = analysis.jumpdest_array.is_valid_jumpdest(i);
        if (is_valid) {
            std.log.warn("Position {}: VALID JUMPDEST", .{i});
        }
    }
    
    // The JUMPDEST should be at position 8
    try testing.expect(analysis.jumpdest_array.is_valid_jumpdest(8));
    try testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(7));
    try testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(9));
}

test "E2E: Loop with backward JUMP" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Simple loop that counts down from 3 to 0
    const bytecode = &[_]u8{
        0x60, 0x03, // PUSH1 3 (counter)
        0x5b, // JUMPDEST at 2 (loop start)
        0x60, 0x01, // PUSH1 1
        0x90, // SWAP1
        0x03, // SUB (counter - 1)
        0x80, // DUP1
        0x60, 0x02, // PUSH1 2 (loop start)
        0x57, // JUMPI (jump if counter != 0)
        0x50, // POP (cleanup stack)
        0x60, 0x00, // PUSH1 0
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
    
    // Output should contain 0 (loop completed)
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0), value);
    }
}

test "E2E: PUSH in data section is not executed" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x63, // PUSH4
        0x60, 0x42, 0x60, 0x43, // Data bytes (look like PUSH1 but are data)
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
    
    // Output should contain the pushed value, not results of executing data as code
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        const value = std.mem.readInt(u256, output[0..32], .big);
        try testing.expectEqual(@as(u256, 0x60426043), value);
    }
}

test "E2E: Out of gas detection" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var vm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer vm.deinit();
    
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (costs 3 gas)
        0x60, 0x02, // PUSH1 2 (costs 3 gas)
        0x01, // ADD (costs 3 gas)
        0x00, // STOP (costs 0 gas)
    };
    
    const contract_addr = Address.from_u256(0x1000);
    try vm.state.set_code(contract_addr, bytecode);
    
    const params = evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 8, // Only provide 8 gas (need 9 for all operations)
        },
    };
    
    const result = try vm.call(params);
    // Should fail due to out of gas
    try testing.expect(!result.success);
}