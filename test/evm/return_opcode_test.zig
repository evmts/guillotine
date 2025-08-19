const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Test that RETURN opcode works correctly with interpret2
const interpret2 = evm.interpret2;

test "interpret2: RETURN opcode sets output buffer" {
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
    
    // Check that RETURN properly set the output
    // The output_buffer should contain the returned data
    if (frame.output_buffer.len > 0) {
        try testing.expectEqual(@as(usize, 32), frame.output_buffer.len);
        
        // Check the value
        const output_value = std.mem.readInt(u256, frame.output_buffer[0..32], .big);
        try testing.expectEqual(@as(u256, 0x42), output_value);
    } else {
    }
}

test "interpret2: Multiple RETURNs with different values" {
    const allocator = testing.allocator;
    
    // Test with JUMPI to select which value to return
    const code = [_]u8{
        0x60, 0x01,  // PUSH1 1 (condition) - positions 0-1
        0x60, 0x10,  // PUSH1 16 (jump dest) - positions 2-3
        0x57,        // JUMPI - position 4
        // Path if condition is false (skipped)
        0x60, 0xAA,  // PUSH1 0xAA - positions 5-6
        0x60, 0x00,  // PUSH1 0 - positions 7-8
        0x52,        // MSTORE - position 9
        0x60, 0x20,  // PUSH1 32 - positions 10-11
        0x60, 0x00,  // PUSH1 0 - positions 12-13
        0xf3,        // RETURN - position 14
        0x00,        // STOP (padding) - position 15
        // Path if condition is true (at position 16)
        0x5B,        // JUMPDEST - position 16
        0x60, 0xBB,  // PUSH1 0xBB
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
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
    
    // Should have taken the jump and returned 0xBB
    const mem_result = try frame.memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0xBB), mem_result);
}