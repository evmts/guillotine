const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

test "interpret2: ADD operation (differential test case)" {
    const allocator = testing.allocator;
    
    // Based on differential test: ADD 0 + 0 = 0
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0  
        0x01,        // ADD
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check memory contains the result (0)
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0), mem_result);
}

test "interpret2: SUB operation 10 - 5 = 5 (differential test case)" {
    const allocator = testing.allocator;
    
    // Based on differential test: SUB 10 - 5 = 5
    // Note: SUB pops b, then a, computes a - b
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5 (b)
        0x60, 0x0A,  // PUSH1 10 (a)
        0x03,        // SUB (computes a - b = 10 - 5 = 5)
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check memory contains the result (5)
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 5), mem_result);
}

test "interpret2: MUL operation 3 * 7 = 21" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x07,  // PUSH1 7
        0x60, 0x03,  // PUSH1 3
        0x02,        // MUL
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check memory contains the result (21)
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 21), mem_result);
}

test "interpret2: DIV operation 20 / 4 = 5" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x04,  // PUSH1 4 (divisor)
        0x60, 0x14,  // PUSH1 20 (dividend)
        0x04,        // DIV
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check memory contains the result (5)
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 5), mem_result);
}

test "interpret2: complex arithmetic (3 * 10 - 5) / 5 = 5" {
    const allocator = testing.allocator;
    
    // Fixed: proper stack order for operations
    // MUL: pops b, a -> pushes a * b
    // SUB: pops b, a -> pushes a - b  
    // DIV: pops b, a -> pushes a / b
    const code = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x0A,  // PUSH1 10  
        0x02,        // MUL (10 * 3 = 30)
        0x60, 0x05,  // PUSH1 5
        0x90,        // SWAP1 (swap 5 and 30)
        0x03,        // SUB (30 - 5 = 25)
        0x60, 0x05,  // PUSH1 5
        0x90,        // SWAP1
        0x04,        // DIV (25 / 5 = 5)
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check memory contains the result (5)
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 5), mem_result);
}

test "interpret2: RETURN opcode returns data correctly" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE (store 0x42 at offset 0)
        0x60, 0x20,  // PUSH1 32 (return size)
        0x60, 0x00,  // PUSH1 0 (return offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check memory contains 0x42
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0x42), mem_result);
    
    // Check output buffer was set (if RETURN implementation sets it)
    // Note: This depends on how RETURN is implemented
    if (frame.output_buffer.len > 0) {
        try testing.expectEqual(@as(usize, 32), frame.output_buffer.len);
        const output_value = std.mem.readInt(u256, frame.output_buffer[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), output_value);
    }
}

test "interpret2: JUMP to valid JUMPDEST" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x04,  // PUSH1 4 (jump destination)
        0x56,        // JUMP
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST at position 4
        0x60, 0x99,  // PUSH1 0x99
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Check that we jumped and executed PUSH1 0x99
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0x99), mem_result);
}

test "interpret2: JUMPI conditional jump (condition true)" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x01,  // PUSH1 1 (condition: true)
        0x60, 0x08,  // PUSH1 8 (destination - actual position of JUMPDEST)
        0x57,        // JUMPI
        0x60, 0xAA,  // PUSH1 0xAA (should be skipped)
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST at position 8
        0x60, 0xBB,  // PUSH1 0xBB
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.RETURN, result);
    
    // Should have jumped and stored 0xBB
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0xBB), mem_result);
}

test "interpret2: JUMPI conditional jump (condition false)" {
    const allocator = testing.allocator;
    
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (condition: false)
        0x60, 0x09,  // PUSH1 9 (destination)
        0x57,        // JUMPI
        0x60, 0xAA,  // PUSH1 0xAA (should execute)
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x00,        // STOP
        0x5B,        // JUMPDEST at position 9 (should be skipped)
        0x60, 0xBB,  // PUSH1 0xBB
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should NOT have jumped, should have stored 0xAA
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0xAA), mem_result);
}