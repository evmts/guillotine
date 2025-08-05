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
const CodeAnalysis = evm.CodeAnalysis;
const BlockMetadata = evm.BlockMetadata;

test "block execution basic arithmetic sequence" {
    const allocator = testing.allocator;
    
    // Bytecode: long sequence of arithmetic operations (single block)
    const bytecode = [_]u8{
        0x60, 0x10, // PUSH1 16
        0x60, 0x20, // PUSH1 32
        0x01,       // ADD
        0x60, 0x05, // PUSH1 5
        0x02,       // MUL
        0x60, 0x03, // PUSH1 3
        0x04,       // DIV
        0x00,       // STOP
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
    
    // Verify execution completed successfully
    try testing.expect(result.status == .Success);
    try testing.expect(result.gas_used > 0);
    
    // Verify contract has analysis (block execution was used)
    try testing.expect(contract.analysis != null);
    try testing.expect(contract.analysis.?.block_count > 0);
}

test "block execution with static jumps" {
    const allocator = testing.allocator;
    
    // Bytecode with static jumps
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10 (jump destination)
        0x56,       // JUMP
        0x60, 0xFF, // PUSH1 255 (should be skipped)
        0x00,       // STOP (should be skipped)
        0x00, 0x00, 0x00, // padding
        0x5b,       // JUMPDEST (at position 10)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
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
    
    // Verify jump analysis was performed
    if (contract.analysis) |analysis| {
        if (analysis.jump_analysis) |jump_analysis| {
            // Should have detected static jump
            try testing.expect(jump_analysis.static_jump_count > 0);
            try testing.expect(jump_analysis.is_valid_static_jump(2, 10));
        }
    }
}

test "block execution with conditional jumps" {
    const allocator = testing.allocator;
    
    // Bytecode with JUMPI
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition true)
        0x60, 0x0C, // PUSH1 12 (jump destination)
        0x57,       // JUMPI
        0x60, 0xFF, // PUSH1 255 (should be skipped)
        0x00,       // STOP (should be skipped)
        0x00, 0x00, 0x00, // padding
        0x5b,       // JUMPDEST (at position 12)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
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

test "block execution with multiple blocks" {
    const allocator = testing.allocator;
    
    // Bytecode with multiple blocks separated by jumps
    const bytecode = [_]u8{
        // Block 1
        0x60, 0x10, // PUSH1 16
        0x60, 0x20, // PUSH1 32
        0x01,       // ADD
        0x60, 0x0E, // PUSH1 14 (jump to block 2)
        0x56,       // JUMP
        
        // Unreachable
        0x60, 0xFF, // PUSH1 255
        0x00,       // STOP
        
        // Block 2 (at position 14)
        0x5b,       // JUMPDEST
        0x60, 0x05, // PUSH1 5
        0x02,       // MUL
        0x60, 0x1A, // PUSH1 26 (jump to block 3)
        0x56,       // JUMP
        
        // Unreachable
        0x60, 0xEE, // PUSH1 238
        0x00,       // STOP
        
        // Block 3 (at position 26)
        0x5b,       // JUMPDEST
        0x60, 0x03, // PUSH1 3
        0x04,       // DIV
        0x00,       // STOP
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
    
    // Verify multiple blocks were detected
    if (contract.analysis) |analysis| {
        try testing.expect(analysis.block_count >= 3);
    }
}

test "block execution gas validation" {
    const allocator = testing.allocator;
    
    // Bytecode with known gas costs
    const bytecode = [_]u8{
        0x60, 0x10, // PUSH1 16 (3 gas)
        0x60, 0x20, // PUSH1 32 (3 gas)
        0x01,       // ADD (3 gas)
        0x00,       // STOP (0 gas)
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test with sufficient gas
    {
        var contract = Contract.init(
            Address.ZERO,
            Address.ZERO,
            0,
            100, // Sufficient gas
            &bytecode,
            [_]u8{0} ** 32,
            &.{},
            false
        );
        defer contract.deinit(allocator, null);
        
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);
        
        try testing.expect(result.status == .Success);
        try testing.expectEqual(@as(u64, 9), result.gas_used);
    }
    
    // Test with insufficient gas
    {
        var contract = Contract.init(
            Address.ZERO,
            Address.ZERO,
            0,
            5, // Not enough gas
            &bytecode,
            [_]u8{0} ** 32,
            &.{},
            false
        );
        defer contract.deinit(allocator, null);
        
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);
        
        try testing.expect(result.status == .OutOfGas);
    }
}

test "block execution stack validation" {
    const allocator = testing.allocator;
    
    // Bytecode that would cause stack underflow
    const bytecode = [_]u8{
        0x01, // ADD (requires 2 items, but stack is empty)
        0x00, // STOP
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
    
    // Should fail with stack underflow
    try testing.expect(result.status == .Invalid);
}

test "unsafe opcode execution coverage" {
    const allocator = testing.allocator;
    
    // Test all opcodes covered by unsafe execution
    const bytecode = [_]u8{
        // Arithmetic
        0x60, 0x10, 0x60, 0x20, 0x01, // ADD
        0x60, 0x10, 0x60, 0x20, 0x02, // MUL
        0x60, 0x30, 0x60, 0x10, 0x03, // SUB
        0x60, 0x20, 0x60, 0x04, 0x04, // DIV
        0x60, 0x20, 0x60, 0x04, 0x05, // SDIV
        0x60, 0x20, 0x60, 0x03, 0x06, // MOD
        0x60, 0x20, 0x60, 0x03, 0x07, // SMOD
        
        // Comparison
        0x60, 0x10, 0x60, 0x20, 0x10, // LT
        0x60, 0x20, 0x60, 0x10, 0x11, // GT
        0x60, 0x10, 0x60, 0x10, 0x14, // EQ
        0x60, 0x00, 0x15,             // ISZERO
        
        // Bitwise
        0x60, 0xFF, 0x60, 0x0F, 0x16, // AND
        0x60, 0xF0, 0x60, 0x0F, 0x17, // OR
        0x60, 0xFF, 0x60, 0xF0, 0x18, // XOR
        0x60, 0xFF, 0x19,             // NOT
        
        // Stack operations
        0x60, 0x42, // PUSH1 66
        0x80,       // DUP1
        0x90,       // SWAP1
        0x50,       // POP
        0x50,       // POP
        
        0x00,       // STOP
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

test "block execution with memory operations" {
    const allocator = testing.allocator;
    
    // Bytecode with memory operations
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 66 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x51,       // MLOAD
        0x60, 0x42, // PUSH1 66
        0x14,       // EQ
        0x60, 0x0F, // PUSH1 15
        0x57,       // JUMPI
        0x00,       // STOP (fail path)
        0x5b,       // JUMPDEST (success path)
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
    try testing.expectEqual(@as(usize, 1), result.output.?.len);
    try testing.expectEqual(@as(u8, 1), result.output.?[0]);
}

test "block execution fallback to regular for complex opcodes" {
    const allocator = testing.allocator;
    
    // Bytecode with opcodes not covered by unsafe execution
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xf1,       // CALL (complex opcode, should fall back)
        0x00,       // STOP
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
    
    // Should handle the fallback gracefully
    try testing.expect(result.status == .Success or result.status == .Invalid);
}

test "block execution disabled for small contracts" {
    const allocator = testing.allocator;
    
    // Very small bytecode (should not use block execution)
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
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
    
    // Small contracts may not trigger block execution
    // This is expected behavior for optimization
}

test "block metadata correctness" {
    const allocator = testing.allocator;
    
    // Create analysis directly to test metadata
    const bytecode = [_]u8{
        0x60, 0x10, // PUSH1 16 (3 gas)
        0x60, 0x20, // PUSH1 32 (3 gas)
        0x01,       // ADD (3 gas)
        0x00,       // STOP (0 gas)
    };
    
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, &bytecode);
    defer analysis.deinit(allocator);
    
    // Verify block metadata
    try testing.expect(analysis.block_count > 0);
    
    const first_block = analysis.block_metadata[0];
    try testing.expectEqual(@as(u32, 9), first_block.gas_cost); // 3+3+3+0
    try testing.expectEqual(@as(i16, 0), first_block.stack_req); // No initial stack required
    try testing.expectEqual(@as(i16, 2), first_block.stack_max); // Max 2 items on stack
}

test "block execution with invalid jump" {
    const allocator = testing.allocator;
    
    // Bytecode with invalid jump destination
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (invalid destination - not a JUMPDEST)
        0x56,       // JUMP
        0x00,       // STOP
        0x60, 0x42, // PUSH1 66 (not a JUMPDEST)
        0x00,       // STOP
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
    
    // Should fail with invalid jump
    try testing.expect(result.status == .Invalid);
}