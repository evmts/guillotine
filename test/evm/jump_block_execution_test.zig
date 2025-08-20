const std = @import("std");
const evm = @import("evm");

test "block execution with resolved jump" {
    const allocator = std.testing.allocator;
    
    // Create bytecode with a jump:
    // PUSH1 0x08, JUMP, INVALID, INVALID, INVALID, JUMPDEST, PUSH1 0x42, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x08,  // PUSH1 0x08
        0x56,        // JUMP  
        0xFE,        // INVALID (should be skipped)
        0xFE,        // INVALID (should be skipped)
        0xFE,        // INVALID (should be skipped)
        0x5B,        // JUMPDEST (at position 8)
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN
    };
    
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();
    
    // Create contract
    var contract = try evm.Contract.init(
        allocator, 
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Execute using block-based interpretation (should handle jump)
    const result = try vm.interpret_block(&contract, &.{}, false);
    // Should succeed and return 0x42
    try std.testing.expectEqual(evm.RunResult.Status.Success, result.status);
    try std.testing.expect(result.output != null);
    try std.testing.expectEqual(@as(usize, 32), result.output.?.len);
    
    // Check the value
    var expected = [_]u8{0} ** 32;
    expected[31] = 0x42;
    try std.testing.expectEqualSlices(u8, &expected, result.output.?);
}

test "block execution with conditional jump taken" {
    const allocator = std.testing.allocator;
    
    // Create bytecode: PUSH1 1, PUSH1 0x0A, JUMPI, PUSH1 0, STOP, JUMPDEST, PUSH1 42, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x01,  // PUSH1 1 (condition = true)
        0x60, 0x0A,  // PUSH1 0x0A (jump to position 10)
        0x57,        // JUMPI
        0x60, 0x00,  // PUSH1 0 (should be skipped)
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE (should be skipped)
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST (at position 10)
        0x60, 0x2A,  // PUSH1 42
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN
    };
    
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();
    
    // Create contract
    var contract = try evm.Contract.init(
        allocator, 
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Execute using block-based interpretation
    const result = try vm.interpret_block(&contract, &.{}, false);
    // Should succeed with value 42
    try std.testing.expectEqual(evm.RunResult.Status.Success, result.status);
    try std.testing.expect(result.output != null);
    
    var expected = [_]u8{0} ** 32;
    expected[31] = 0x2A; // 42
    try std.testing.expectEqualSlices(u8, &expected, result.output.?);
}

test "block execution with conditional jump not taken" {
    const allocator = std.testing.allocator;
    
    // Create bytecode: PUSH1 0, PUSH1 0x0A, JUMPI, PUSH1 99, STOP, JUMPDEST, PUSH1 42, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x00,  // PUSH1 0 (condition = false)
        0x60, 0x0A,  // PUSH1 0x0A
        0x57,        // JUMPI (should not jump)
        0x60, 0x63,  // PUSH1 99 (0x63)
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN
        0x5B,        // JUMPDEST (not reached)
        0x60, 0x2A,  // PUSH1 42 (not reached)
        0x00,        // STOP (not reached)
    };
    
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();
    
    // Create contract
    var contract = try evm.Contract.init(
        allocator, 
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Execute using block-based interpretation
    const result = try vm.interpret_block(&contract, &.{}, false);
    // Should succeed with value 99 (not 42)
    try std.testing.expectEqual(evm.RunResult.Status.Success, result.status);
    try std.testing.expect(result.output != null);
    
    var expected = [_]u8{0} ** 32;
    expected[31] = 0x63; // 99
    try std.testing.expectEqualSlices(u8, &expected, result.output.?);
}