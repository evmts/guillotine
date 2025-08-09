const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Log = Evm.Log;

test "dynamic JUMP with computed destination" {
    const allocator = std.testing.allocator;
    
    // Enable debug logging for this test
    std.testing.log_level = .debug;
    
    // Bytecode that computes jump destination dynamically:
    // PC 0: PUSH1 0x08 (base value)
    // PC 2: PUSH1 0x02 (offset)
    // PC 4: ADD (compute destination: 8 + 2 = 10)
    // PC 5: JUMP (jump to computed destination 10)
    // PC 6: PUSH1 0xFF (should be skipped)
    // PC 8: PUSH1 0xEE (should be skipped)
    // PC 10: JUMPDEST (jump destination)
    // PC 11: PUSH1 0x42 (push success value)
    // PC 13: STOP
    const code = &[_]u8{ 
        0x60, 0x08,  // PUSH1 0x08
        0x60, 0x02,  // PUSH1 0x02
        0x01,        // ADD
        0x56,        // JUMP
        0x60, 0xFF,  // PUSH1 0xFF (skipped)
        0x60, 0xEE,  // PUSH1 0xEE (skipped)
        0x5B,        // JUMPDEST at PC 10
        0x60, 0x42,  // PUSH1 0x42
        0x00         // STOP
    };
    
    var memory_db = Evm.state.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.frame.Contract.init(allocator, code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.frame.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute the code
    try vm.interpret(&frame);
    
    // Verify that the jump worked and we got 0x42 on the stack
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x42), result);
}

test "dynamic JUMPI with computed destination - true condition" {
    const allocator = std.testing.allocator;
    
    // Bytecode with dynamic conditional jump:
    // PC 0: PUSH1 0x0C (base value)
    // PC 2: PUSH1 0x01 (offset)
    // PC 4: ADD (compute destination: 12 + 1 = 13)
    // PC 5: PUSH1 0x01 (condition: true)
    // PC 7: JUMPI (conditional jump to computed destination 13)
    // PC 8: PUSH1 0xFF (should be skipped)
    // PC 10: PUSH1 0xEE (should be skipped)
    // PC 12: STOP (should be skipped)
    // PC 13: JUMPDEST (jump destination)
    // PC 14: PUSH1 0x99 (push success value)
    // PC 16: STOP
    const code = &[_]u8{ 
        0x60, 0x0C,  // PUSH1 0x0C
        0x60, 0x01,  // PUSH1 0x01
        0x01,        // ADD
        0x60, 0x01,  // PUSH1 0x01 (condition)
        0x57,        // JUMPI
        0x60, 0xFF,  // PUSH1 0xFF (skipped)
        0x60, 0xEE,  // PUSH1 0xEE (skipped)
        0x00,        // STOP (skipped)
        0x5B,        // JUMPDEST at PC 13
        0x60, 0x99,  // PUSH1 0x99
        0x00         // STOP
    };
    
    var memory_db = Evm.state.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.frame.Contract.init(allocator, code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.frame.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute the code
    try vm.interpret(&frame);
    
    // Verify that the jump worked and we got 0x99 on the stack
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x99), result);
}

test "dynamic JUMPI with computed destination - false condition" {
    const allocator = std.testing.allocator;
    
    // Bytecode with dynamic conditional jump (false condition):
    // PC 0: PUSH1 0x0B (base value)
    // PC 2: PUSH1 0x01 (offset)
    // PC 4: ADD (compute destination: 11 + 1 = 12)
    // PC 5: PUSH1 0x00 (condition: false)
    // PC 7: JUMPI (conditional jump should NOT happen)
    // PC 8: PUSH1 0xAA (should execute - fall through)
    // PC 10: STOP
    // PC 11: JUMPDEST (should not reach here)
    // PC 12: PUSH1 0xBB (should not execute)
    // PC 14: STOP
    const code = &[_]u8{ 
        0x60, 0x0B,  // PUSH1 0x0B
        0x60, 0x01,  // PUSH1 0x01
        0x01,        // ADD
        0x60, 0x00,  // PUSH1 0x00 (condition: false)
        0x57,        // JUMPI
        0x60, 0xAA,  // PUSH1 0xAA (should execute)
        0x00,        // STOP
        0x5B,        // JUMPDEST at PC 11
        0x60, 0xBB,  // PUSH1 0xBB (should not execute)
        0x00         // STOP
    };
    
    var memory_db = Evm.state.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.frame.Contract.init(allocator, code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.frame.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute the code
    try vm.interpret(&frame);
    
    // Verify that we fell through and got 0xAA on the stack
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xAA), result);
}

test "dynamic JUMP with table lookup" {
    const allocator = std.testing.allocator;
    
    // Bytecode that uses a jump table pattern:
    // PC 0: PUSH1 0x02 (index into jump table)
    // PC 2: PUSH1 0x04 (multiplier for offset)
    // PC 4: MUL (compute offset: 2 * 4 = 8)
    // PC 5: PUSH1 0x08 (base of jump table)
    // PC 7: ADD (compute destination: 8 + 8 = 16)
    // PC 8: JUMP
    // PC 9: PUSH1 0x11 (should be skipped)
    // PC 11: PUSH1 0x22 (should be skipped)
    // PC 13: PUSH1 0x33 (should be skipped)
    // PC 15: STOP (should be skipped)
    // PC 16: JUMPDEST (jump table entry 2)
    // PC 17: PUSH1 0x77 (success value for entry 2)
    // PC 19: STOP
    const code = &[_]u8{ 
        0x60, 0x02,  // PUSH1 0x02
        0x60, 0x04,  // PUSH1 0x04
        0x02,        // MUL
        0x60, 0x08,  // PUSH1 0x08
        0x01,        // ADD
        0x56,        // JUMP
        0x60, 0x11,  // PUSH1 0x11 (skipped)
        0x60, 0x22,  // PUSH1 0x22 (skipped)
        0x60, 0x33,  // PUSH1 0x33 (skipped)
        0x00,        // STOP (skipped)
        0x5B,        // JUMPDEST at PC 16
        0x60, 0x77,  // PUSH1 0x77
        0x00         // STOP
    };
    
    var memory_db = Evm.state.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.frame.Contract.init(allocator, code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.frame.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute the code
    try vm.interpret(&frame);
    
    // Verify that the jump worked and we got 0x77 on the stack
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x77), result);
}

test "invalid dynamic JUMP to non-JUMPDEST" {
    const allocator = std.testing.allocator;
    
    // Bytecode with invalid jump (destination is not a JUMPDEST):
    // PC 0: PUSH1 0x04 (base value)
    // PC 2: PUSH1 0x01 (offset)
    // PC 4: ADD (compute destination: 4 + 1 = 5, which is not a JUMPDEST)
    // PC 5: JUMP (should fail - PC 5 is not a JUMPDEST)
    // PC 6: PUSH1 0xFF
    // PC 8: STOP
    const code = &[_]u8{ 
        0x60, 0x04,  // PUSH1 0x04
        0x60, 0x01,  // PUSH1 0x01
        0x01,        // ADD
        0x56,        // JUMP
        0x60, 0xFF,  // PUSH1 0xFF
        0x00         // STOP
    };
    
    var memory_db = Evm.state.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.frame.Contract.init(allocator, code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.frame.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute the code - should fail with InvalidJump
    const result = vm.interpret(&frame);
    try std.testing.expectError(Evm.execution.ExecutionError.Error.InvalidJump, result);
}

test "dynamic JUMP with stack manipulation" {
    const allocator = std.testing.allocator;
    
    // Bytecode that manipulates stack to compute jump destination:
    // PC 0: PUSH1 0x0E (push value 14)
    // PC 2: PUSH1 0x05 (push another value)
    // PC 4: PUSH1 0x03 (push third value)
    // PC 6: SWAP2 (swap top with third: stack becomes [3, 5, 14])
    // PC 7: POP (remove top: stack becomes [5, 14])
    // PC 8: POP (remove top: stack becomes [14])
    // PC 9: JUMP (jump to 14)
    // PC 10: PUSH1 0xDE (should be skipped)
    // PC 12: PUSH1 0xAD (should be skipped)
    // PC 14: JUMPDEST
    // PC 15: PUSH1 0xCA
    // PC 17: PUSH1 0xFE
    // PC 19: STOP
    const code = &[_]u8{ 
        0x60, 0x0E,  // PUSH1 0x0E
        0x60, 0x05,  // PUSH1 0x05
        0x60, 0x03,  // PUSH1 0x03
        0x91,        // SWAP2
        0x50,        // POP
        0x50,        // POP
        0x56,        // JUMP
        0x60, 0xDE,  // PUSH1 0xDE (skipped)
        0x60, 0xAD,  // PUSH1 0xAD (skipped)
        0x5B,        // JUMPDEST at PC 14
        0x60, 0xCA,  // PUSH1 0xCA
        0x60, 0xFE,  // PUSH1 0xFE
        0x00         // STOP
    };
    
    var memory_db = Evm.state.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.frame.Contract.init(allocator, code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.frame.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute the code
    try vm.interpret(&frame);
    
    // Verify that the jump worked and we got 0xCAFE on the stack
    try std.testing.expectEqual(@as(usize, 2), frame.stack.size());
    const result1 = try frame.stack.pop();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFE), result1);
    try std.testing.expectEqual(@as(u256, 0xCA), result2);
}