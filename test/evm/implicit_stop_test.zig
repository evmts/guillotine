const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const utils = primitives.utils;
const U256 = utils.U256;

test "implicit STOP: basic fall-through execution" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode: PUSH1 0x42, no explicit STOP
    const bytecode = &[_]u8{ 0x60, 0x42 };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Execute until end of bytecode
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should have pushed 0x42 and then implicitly stopped
    const value = try frame.stack.pop();
    try std.testing.expectEqual(@as(U256, 0x42), value);
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
    
    // Frame should be in a valid state with empty return data
    try std.testing.expectEqual(@as(usize, 0), frame.return_data.len);
}

test "implicit STOP: complex execution without explicit halt" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x10, PUSH1 0x20, ADD, no STOP
    const bytecode = &[_]u8{ 
        0x60, 0x10,  // PUSH1 0x10
        0x60, 0x20,  // PUSH1 0x20
        0x01         // ADD
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should have result of addition on stack
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(U256, 0x30), result);
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
}

test "implicit STOP: jump to bytecode end" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x05, JUMP, JUMPDEST (at position 5, which is end of bytecode)
    const bytecode = &[_]u8{ 
        0x60, 0x05,  // PUSH1 0x05
        0x56,        // JUMP
        0x00,        // padding (never executed)
        0x5b         // JUMPDEST at position 5
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should have empty stack after jumping to end
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
    try std.testing.expectEqual(@as(usize, 0), frame.return_data.len);
}

test "implicit STOP: conditional jump falling through" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x08, PUSH1 0x00, JUMPI (condition is 0, so doesn't jump)
    const bytecode = &[_]u8{ 
        0x60, 0x08,  // PUSH1 0x08 (target)
        0x60, 0x00,  // PUSH1 0x00 (condition = false)
        0x57         // JUMPI
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should fall through to end with empty stack
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
}

test "implicit STOP: empty bytecode" {
    const allocator = std.testing.allocator;
    
    // Empty bytecode
    const bytecode = &[_]u8{};
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should complete successfully with no changes
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
    try std.testing.expectEqual(@as(usize, 0), frame.return_data.len);
}

test "implicit STOP: incomplete PUSH instruction at end" {
    const allocator = std.testing.allocator;
    
    // Bytecode with incomplete PUSH2 (missing second byte)
    const bytecode = &[_]u8{ 0x61, 0xFF }; // PUSH2 with only one byte of data
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should push partial value (0xFF00) and then stop
    const value = try frame.stack.pop();
    try std.testing.expectEqual(@as(U256, 0xFF00), value);
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
}

test "implicit STOP: gas consumption at bytecode end" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode to measure gas: PUSH1 0x01
    const bytecode = &[_]u8{ 0x60, 0x01 };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    const initial_gas: u64 = 1000000;
    var frame = try Evm.Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Gas should be consumed for PUSH1 (3 gas) but not for implicit STOP
    const gas_used = initial_gas - frame.gas_remaining;
    try std.testing.expectEqual(@as(u64, 3), gas_used);
}

test "implicit STOP: multiple PUSHes ending at exact bytecode boundary" {
    const allocator = std.testing.allocator;
    
    // Bytecode with PUSH operations that end exactly at bytecode boundary
    const bytecode = &[_]u8{ 
        0x60, 0xAA,  // PUSH1 0xAA
        0x61, 0xBB, 0xCC,  // PUSH2 0xBBCC
        0x62, 0xDD, 0xEE, 0xFF  // PUSH3 0xDDEEFF
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Should have all three values on stack
    try std.testing.expectEqual(@as(usize, 3), frame.stack.size());
    
    const val3 = try frame.stack.pop();
    const val2 = try frame.stack.pop();
    const val1 = try frame.stack.pop();
    
    try std.testing.expectEqual(@as(U256, 0xDDEEFF), val3);
    try std.testing.expectEqual(@as(U256, 0xBBCC), val2);
    try std.testing.expectEqual(@as(U256, 0xAA), val1);
}

test "implicit STOP: PC at bytecode boundary after complex execution" {
    const allocator = std.testing.allocator;
    
    // Complex bytecode that exercises various paths
    const bytecode = &[_]u8{ 
        0x60, 0x05,  // PUSH1 0x05
        0x60, 0x03,  // PUSH1 0x03
        0x01,        // ADD
        0x60, 0x02,  // PUSH1 0x02
        0x02,        // MUL
        0x60, 0x0F,  // PUSH1 0x0F
        0x16         // AND
    };
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var contract = try Evm.Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Evm.Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    vm.table = &Evm.JumpTable.DEFAULT;
    try vm.execute(frame);
    
    // Result should be ((5 + 3) * 2) & 0x0F = 16 & 15 = 0
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(U256, 0), result);
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
}