//! Differential tests for LOG opcode handling
//! 
//! NOTE: These tests currently fail because the REVM wrapper doesn't extract logs
//! from execution results (see lib/revm/src/lib.rs:522,739 - logs_count: 0).
//! Once the REVM wrapper is fixed to extract logs, these tests will properly
//! validate log behavior between REVM and Guillotine, including topic ordering.

const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: LOG2 topic order - demonstrates reversal bug" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test LOG2 topic order with correct bytecode.
    // To get topics[0]=0xAA, topics[1]=0xBB, we push in reverse
    // due to LIFO stack behavior.
    const bytecode = [_]u8{
        // Push values in reverse order for correct result
        0x60, 0xBB,             // PUSH1 0xBB (will become topic1 after LIFO pop)
        0x60, 0xAA,             // PUSH1 0xAA (will become topic0 after LIFO pop)
        0x60, 0x00,             // PUSH1 0 (length)
        0x60, 0x00,             // PUSH1 0 (offset - at top of stack)
        
        // Emit LOG2
        0xa2,                   // LOG2
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: LOG3 topic order - multiple topics" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test with LOG3 to verify order with 3 topics
    const bytecode = [_]u8{
        // Push topics in reverse order for correct result
        0x60, 0xCC,             // PUSH1 0xCC (will become topic2)
        0x60, 0xBB,             // PUSH1 0xBB (will become topic1)
        0x60, 0xAA,             // PUSH1 0xAA (will become topic0)
        
        // Push log data parameters
        0x60, 0x00,             // PUSH1 0 (length)
        0x60, 0x00,             // PUSH1 0 (offset)
        
        // Emit LOG3
        0xa3,                   // LOG3
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: LOG4 topic order - maximum topics" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test with LOG4 (maximum number of topics)
    const bytecode = [_]u8{
        // Push topics in reverse order for correct result
        0x60, 0x04,             // PUSH1 0x04 (will become topic3)
        0x60, 0x03,             // PUSH1 0x03 (will become topic2)
        0x60, 0x02,             // PUSH1 0x02 (will become topic1)
        0x60, 0x01,             // PUSH1 0x01 (will become topic0)
        
        // Push log data parameters
        0x60, 0x00,             // PUSH1 0 (length)
        0x60, 0x00,             // PUSH1 0 (offset)
        
        // Emit LOG4
        0xa4,                   // LOG4
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: LOG2 with data and topics order" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test LOG2 with actual log data to ensure topics are still ordered correctly
    const bytecode = [_]u8{
        // Store some data in memory
        0x60, 0x42,             // PUSH1 0x42 (data value)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0x52,                   // MSTORE
        
        // Push topics in reverse order
        0x60, 0xAD,             // PUSH1 0xAD (will become topic1)
        0x60, 0xDE,             // PUSH1 0xDE (will become topic0)
        
        // Push log data parameters
        0x60, 0x20,             // PUSH1 32 (length - one word)
        0x60, 0x00,             // PUSH1 0 (offset)
        
        // Emit LOG2
        0xa2,                   // LOG2
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: Transfer event LOG3 topic order" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Simulate a Transfer event with indexed parameters (common ERC20 pattern)
    // LOG3: topic0=event_signature, topic1=from_address, topic2=to_address
    const bytecode = [_]u8{
        // Store transfer amount in memory
        0x60, 0x64,             // PUSH1 100 (transfer amount)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Push topics in reverse order for correct result
        // Topic 2: To address (will become topic2)
        0x61, 0x33, 0x33,       // PUSH2 0x3333 (to address)
        
        // Topic 1: From address (will become topic1)
        0x61, 0x22, 0x22,       // PUSH2 0x2222 (from address)
        
        // Topic 0: Event signature (will become topic0)
        0x61, 0x11, 0x11,       // PUSH2 0x1111 (event signature)
        
        // Push log data parameters
        0x60, 0x20,             // PUSH1 32 (data size - amount)
        0x60, 0x00,             // PUSH1 0 (data offset)
        
        // Emit LOG3
        0xa3,                   // LOG3
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}