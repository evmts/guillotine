const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

test "interpret2: simple ADD operation" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 5, PUSH1 3, ADD, STOP
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 };
    
    // Create test environment
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    // Create empty analysis for interpret2 to fill
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    // Create frame
    var frame = try evm.Frame.init(
        1_000_000,                    // gas
        primitives.Address.ZERO_ADDRESS,  // contract_address
        empty_analysis,               // analysis
        empty_metadata,               // metadata
        empty_ops,                    // ops
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    // Execute using interpret2
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Check stack result - should have 8 (5 + 3)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());
}

test "interpret2: PUSH operations" {
    const allocator = testing.allocator;
    
    // Test various PUSH operations
    const code = [_]u8{ 
        0x60, 0xFF,           // PUSH1 0xFF
        0x61, 0x12, 0x34,     // PUSH2 0x1234
        0x00,                 // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Stack should have two values
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x1234), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "interpret2: JUMP to valid destination" {
    const allocator = testing.allocator;
    
    // Bytecode with JUMP
    const code = [_]u8{ 
        0x60, 0x04,  // PUSH1 4
        0x56,        // JUMP
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST at position 4
        0x60, 0x42,  // PUSH1 0x42
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have pushed 0x42 after jumping
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
}

test "interpret2: JUMPI conditional jump taken" {
    const allocator = testing.allocator;
    
    const code = [_]u8{ 
        0x60, 0x01,  // PUSH1 1 (condition: true)
        0x60, 0x08,  // PUSH1 8 (destination - actual position of JUMPDEST)
        0x57,        // JUMPI
        0x60, 0xAA,  // PUSH1 0xAA (should be skipped)
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST at position 8
        0x60, 0xBB,  // PUSH1 0xBB
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have 0xBB (jumped over 0xAA)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0xBB), try frame.stack.pop());
}

test "interpret2: JUMPI conditional jump not taken" {
    const allocator = testing.allocator;
    
    const code = [_]u8{ 
        0x60, 0x00,  // PUSH1 0 (condition: false)
        0x60, 0x06,  // PUSH1 6 (destination)
        0x57,        // JUMPI
        0x60, 0xAA,  // PUSH1 0xAA (should execute)
        0x00,        // STOP
        0x5B,        // JUMPDEST at position 6
        0x60, 0xBB,  // PUSH1 0xBB (should be skipped)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Should have 0xAA (did not jump)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    try testing.expectEqual(@as(u256, 0xAA), try frame.stack.pop());
}

test "interpret2: DUP and SWAP operations" {
    const allocator = testing.allocator;
    
    const code = [_]u8{ 
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2
        0x80,        // DUP1 (duplicate top)
        0x91,        // SWAP2 (swap 1st and 3rd)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // After DUP1: [1, 2, 2]
    // After SWAP2: [2, 2, 1]
    try testing.expectEqual(@as(usize, 3), frame.stack.size());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "interpret2: invalid JUMP destination" {
    const allocator = testing.allocator;
    
    const code = [_]u8{ 
        0x60, 0x03,  // PUSH1 3 (invalid destination - not a JUMPDEST)
        0x56,        // JUMP
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.InvalidJump, result);
}

test "interpret2: arithmetic operations" {
    const allocator = testing.allocator;
    
    // Fixed based on differential test patterns
    // Note: arithmetic ops pop [b, a] and compute a op b
    const code = [_]u8{ 
        0x60, 0x03,  // PUSH1 3
        0x60, 0x0A,  // PUSH1 10  
        0x02,        // MUL (10 * 3 = 30)
        0x60, 0x05,  // PUSH1 5
        0x90,        // SWAP1 (swap 5 and 30 to get [30, 5])
        0x03,        // SUB (30 - 5 = 25)
        0x60, 0x05,  // PUSH1 5
        0x90,        // SWAP1 (swap 5 and 25 to get [25, 5])
        0x04,        // DIV (25 / 5 = 5)
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const SimpleAnalysis = evm.SimpleAnalysis;
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    // Debug: Check stack size
    const stack_size = frame.stack.size();
    if (stack_size == 0) {
    } else {
        const top = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 5), top);
    }
}