const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Allocator = std.mem.Allocator;

const Vm = evm.Evm;
const Contract = evm.Contract;
const Frame = evm.Frame;
const MemoryDatabase = evm.MemoryDatabase;
const Address = primitives.Address;
const Stack = evm.Stack;

test "unsafe arithmetic operations" {
    const allocator = testing.allocator;
    
    // Test all arithmetic opcodes in unsafe execution
    const bytecode = [_]u8{
        // ADD
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD (5 + 3 = 8)
        
        // MUL
        0x60, 0x04, // PUSH1 4
        0x02,       // MUL (8 * 4 = 32)
        
        // SUB
        0x60, 0x07, // PUSH1 7
        0x03,       // SUB (32 - 7 = 25)
        
        // DIV
        0x60, 0x05, // PUSH1 5
        0x04,       // DIV (25 / 5 = 5)
        
        // MOD
        0x60, 0x07, // PUSH1 7
        0x60, 0x03, // PUSH1 3
        0x06,       // MOD (7 % 3 = 1)
        
        // ADDMOD
        0x60, 0x05, // PUSH1 5
        0x60, 0x04, // PUSH1 4
        0x60, 0x03, // PUSH1 3
        0x08,       // ADDMOD ((3 + 4) % 5 = 2)
        
        // MULMOD
        0x60, 0x05, // PUSH1 5
        0x60, 0x04, // PUSH1 4
        0x60, 0x03, // PUSH1 3
        0x09,       // MULMOD ((3 * 4) % 5 = 2)
        
        // Check final stack
        0x60, 0x02, // PUSH1 2
        0x14,       // EQ (top should be 2)
        0x60, 0x39, // PUSH1 57
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST (success)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(u8, 1), result.output.?[0]);
}

test "unsafe comparison operations" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // LT
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x10,       // LT (3 < 5 = 1)
        
        // GT
        0x60, 0x03, // PUSH1 3
        0x60, 0x05, // PUSH1 5
        0x11,       // GT (5 > 3 = 1)
        
        // EQ
        0x60, 0x42, // PUSH1 66
        0x60, 0x42, // PUSH1 66
        0x14,       // EQ (66 == 66 = 1)
        
        // ISZERO
        0x60, 0x00, // PUSH1 0
        0x15,       // ISZERO (0 == 0 = 1)
        
        // Verify all comparisons returned 1
        0x01,       // ADD
        0x01,       // ADD
        0x01,       // ADD
        0x60, 0x04, // PUSH1 4
        0x14,       // EQ (sum should be 4)
        
        0x60, 0x22, // PUSH1 34
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe bitwise operations" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // AND
        0x60, 0xFF, // PUSH1 255
        0x60, 0x0F, // PUSH1 15
        0x16,       // AND (255 & 15 = 15)
        
        // OR
        0x60, 0xF0, // PUSH1 240
        0x17,       // OR (15 | 240 = 255)
        
        // XOR
        0x60, 0xF0, // PUSH1 240
        0x18,       // XOR (255 ^ 240 = 15)
        
        // NOT
        0x60, 0x00, // PUSH1 0
        0x19,       // NOT (~0 = MAX_U256)
        
        // BYTE
        0x60, 0x00, // PUSH1 0 (index)
        0x90,       // SWAP1
        0x1a,       // BYTE (get MSB of MAX_U256 = 0xFF)
        
        // SHL
        0x60, 0x04, // PUSH1 4
        0x60, 0x01, // PUSH1 1
        0x1b,       // SHL (1 << 4 = 16)
        
        // SHR
        0x60, 0x02, // PUSH1 2
        0x90,       // SWAP1
        0x1c,       // SHR (16 >> 2 = 4)
        
        // Verify result
        0x60, 0x04, // PUSH1 4
        0x14,       // EQ
        0x60, 0x2A, // PUSH1 42
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe stack operations" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // Push values to test with
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        
        // DUP operations
        0x83,       // DUP4 (duplicate 1)
        0x82,       // DUP3 (duplicate 2)
        0x81,       // DUP2 (duplicate 3)
        0x80,       // DUP1 (duplicate 4)
        
        // SWAP operations
        0x90,       // SWAP1 (swap top two)
        0x91,       // SWAP2
        0x92,       // SWAP3
        0x93,       // SWAP4
        
        // POP operations
        0x50,       // POP
        0x50,       // POP
        0x50,       // POP
        0x50,       // POP
        
        // Verify stack has expected values
        0x60, 0x01, // PUSH1 1
        0x14,       // EQ
        0x60, 0x21, // PUSH1 33
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe memory operations" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // MSTORE
        0x60, 0x42, // PUSH1 66 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x52,       // MSTORE
        
        // MLOAD
        0x60, 0x00, // PUSH1 0 (offset)
        0x51,       // MLOAD
        
        // MSTORE8
        0x60, 0xFF, // PUSH1 255 (value)
        0x60, 0x20, // PUSH1 32 (offset)
        0x53,       // MSTORE8
        
        // MSIZE
        0x59,       // MSIZE (should be at least 64)
        0x60, 0x40, // PUSH1 64
        0x11,       // GT (size > 64)
        0x15,       // ISZERO (should be 0)
        
        // Verify MLOAD result
        0x90,       // SWAP1
        0x60, 0x42, // PUSH1 66
        0x14,       // EQ
        0x60, 0x20, // PUSH1 32
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe environment operations" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // ADDRESS
        0x30,       // ADDRESS (contract address)
        0x50,       // POP
        
        // CALLER
        0x33,       // CALLER
        0x50,       // POP
        
        // CALLVALUE
        0x34,       // CALLVALUE
        0x50,       // POP
        
        // CALLDATASIZE
        0x36,       // CALLDATASIZE
        0x50,       // POP
        
        // CODESIZE
        0x38,       // CODESIZE
        0x60, 0x00, // PUSH1 0
        0x11,       // GT (codesize > 0)
        
        // GAS
        0x5a,       // GAS
        0x60, 0x00, // PUSH1 0
        0x11,       // GT (gas > 0)
        
        // PC
        0x58,       // PC
        0x60, 0x00, // PUSH1 0
        0x11,       // GT (pc > 0)
        
        // Verify all checks passed (3 GT results)
        0x01,       // ADD
        0x01,       // ADD
        0x60, 0x03, // PUSH1 3
        0x14,       // EQ
        
        0x60, 0x20, // PUSH1 32
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe PUSH operations" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // Test various PUSH sizes
        0x5f,       // PUSH0
        0x60, 0xFF, // PUSH1 255
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x62, 0xAB, 0xCD, 0xEF, // PUSH3 0xABCDEF
        
        // Verify values
        0x62, 0xAB, 0xCD, 0xEF, // PUSH3 0xABCDEF
        0x14,       // EQ
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x14,       // EQ
        0x01,       // ADD
        0x60, 0xFF, // PUSH1 255
        0x14,       // EQ
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x14,       // EQ
        0x01,       // ADD
        
        0x60, 0x03, // PUSH1 3
        0x14,       // EQ
        0x60, 0x26, // PUSH1 38
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe execution with JUMPDEST" {
    const allocator = testing.allocator;
    
    // JUMPDEST should be no-op in unsafe execution
    const bytecode = [_]u8{
        0x5b,       // JUMPDEST (no-op)
        0x60, 0x01, // PUSH1 1
        0x5b,       // JUMPDEST (no-op)
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD
        0x5b,       // JUMPDEST (no-op)
        0x60, 0x03, // PUSH1 3
        0x14,       // EQ
        0x60, 0x10, // PUSH1 16
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}

test "unsafe execution performance characteristics" {
    const allocator = testing.allocator;
    
    // Generate a long sequence of operations for performance testing
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Add 1000 arithmetic operations
    for (0..1000) |i| {
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i % 256) }); // PUSH1 i
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
        try bytecode.append(0x01); // ADD
        try bytecode.append(0x50); // POP
    }
    
    try bytecode.append(0x00); // STOP
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        10000000, // High gas limit
        bytecode.items,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
    // Verify significant gas was used
    try testing.expect(result.gas_used > 10000);
}

test "unsafe execution edge cases" {
    const allocator = testing.allocator;
    
    // Test edge cases in unsafe execution
    const bytecode = [_]u8{
        // Division by zero
        0x60, 0x10, // PUSH1 16
        0x60, 0x00, // PUSH1 0
        0x04,       // DIV (16 / 0 = 0)
        0x60, 0x00, // PUSH1 0
        0x14,       // EQ
        
        // Modulo by zero
        0x60, 0x10, // PUSH1 16
        0x60, 0x00, // PUSH1 0
        0x06,       // MOD (16 % 0 = 0)
        0x60, 0x00, // PUSH1 0
        0x14,       // EQ
        
        // ADDMOD with n=0
        0x60, 0x00, // PUSH1 0 (n)
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x08,       // ADDMOD ((3+5) % 0 = 0)
        0x60, 0x00, // PUSH1 0
        0x14,       // EQ
        
        // Verify all edge cases handled correctly (3 true results)
        0x01,       // ADD
        0x01,       // ADD
        0x60, 0x03, // PUSH1 3
        0x14,       // EQ
        
        0x60, 0x20, // PUSH1 32
        0x57,       // JUMPI
        0x00,       // STOP (fail)
        
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO,
        Address.ZERO,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    try testing.expect(result.status == .Success);
}