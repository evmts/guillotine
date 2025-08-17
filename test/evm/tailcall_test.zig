const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");

test "tailcall dispatch: simple ADD operation" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode: PUSH1 5, PUSH1 10, ADD, STOP
    const code = &[_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x0A,  // PUSH1 10  
        0x01,        // ADD
        0x00,        // STOP
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute with tailcall dispatch (if enabled)
    const result = vm.table.execute(0, @ptrCast(&vm), @ptrCast(&frame), 0x00);
    
    // Should execute successfully and stop
    try std.testing.expectError(Evm.ExecutionError.Error.STOP, result);
    
    // Stack should have the result: 15
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const sum = try frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 15), sum);
}

test "tailcall dispatch: JUMP operation" {
    const allocator = std.testing.allocator;
    
    // Bytecode with jump: PUSH1 0x08, JUMP, INVALID, JUMPDEST, PUSH1 42, STOP
    const code = &[_]u8{
        0x60, 0x08,  // PUSH1 0x08 (jump target)
        0x56,        // JUMP
        0xFE,        // INVALID (should be skipped)
        0xFE,        // INVALID
        0xFE,        // INVALID  
        0xFE,        // INVALID
        0xFE,        // INVALID (offset 0x07)
        0x5B,        // JUMPDEST (offset 0x08)
        0x60, 0x2A,  // PUSH1 42
        0x00,        // STOP
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute with tailcall dispatch (if enabled)
    const result = vm.table.execute(0, @ptrCast(&vm), @ptrCast(&frame), 0x00);
    
    // Should execute successfully and stop
    try std.testing.expectError(Evm.ExecutionError.Error.STOP, result);
    
    // Stack should have 42
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value = try frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 42), value);
}

test "tailcall dispatch: conditional JUMPI operation" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 1, PUSH1 0x09, JUMPI, PUSH1 99, STOP, JUMPDEST, PUSH1 42, STOP
    const code = &[_]u8{
        0x60, 0x01,  // PUSH1 1 (condition: true)
        0x60, 0x09,  // PUSH1 0x09 (jump target)
        0x57,        // JUMPI
        0x60, 0x63,  // PUSH1 99 (should be skipped)
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST (offset 0x09)
        0x60, 0x2A,  // PUSH1 42
        0x00,        // STOP
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute with tailcall dispatch (if enabled)
    const result = vm.table.execute(0, @ptrCast(&vm), @ptrCast(&frame), 0x00);
    
    // Should execute successfully and stop
    try std.testing.expectError(Evm.ExecutionError.Error.STOP, result);
    
    // Stack should have 42 (jumped over 99)
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value = try frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 42), value);
}