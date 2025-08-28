const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: JUMP to valid destination" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test basic JUMP
    const bytecode = [_]u8{
        // Jump over bad instruction
        0x60, 0x05, // PUSH1 5
        0x56,       // JUMP
        0xfe,       // INVALID (should be skipped)
        0x5b,       // JUMPDEST (offset 5)
        // Return 42
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMP to invalid destination" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test JUMP to non-JUMPDEST (should fail)
    const bytecode = [_]u8{
        // Try to jump to PUSH1 instruction
        0x60, 0x04, // PUSH1 4
        0x56,       // JUMP
        0x60, 0x42, // PUSH1 66 (not a valid jump dest)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMPI conditional taken" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test JUMPI with true condition
    const bytecode = [_]u8{
        // Jump if 1 (true)
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x08, // PUSH1 8 (destination)
        0x57,       // JUMPI
        // This should be skipped
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x00,       // STOP
        0x5b,       // JUMPDEST (offset 8)
        // Return 1
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMPI conditional not taken" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test JUMPI with false condition
    const bytecode = [_]u8{
        // Don't jump if 0 (false)
        0x60, 0x00, // PUSH1 0 (condition)
        0x60, 0x0a, // PUSH1 10 (destination)
        0x57,       // JUMPI
        // This should execute
        0x60, 0x02, // PUSH1 2
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x00,       // STOP
        0x5b,       // JUMPDEST (offset 10)
        // This should not execute
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMP edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test various JUMP edge cases
    const bytecode = [_]u8{
        // Jump to offset 0 (beginning)
        0x5b,       // JUMPDEST (make offset 0 valid)
        0x60, 0x00, // PUSH1 0
        0x56,       // JUMP (infinite loop if not gas limited)
        
        // Never reached
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMPI with various conditions" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test JUMPI with different condition values
    const bytecode = [_]u8{
        // Test with MAX_U256 (true)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256
        0x60, 0x28, // PUSH1 40 (destination)
        0x57,       // JUMPI
        // Should skip this
        0x60, 0x00, // PUSH1 0
        0x00,       // STOP
        
        0x5b,       // JUMPDEST (offset 40)
        // Return success
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: nested jumps" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test complex jump patterns
    const bytecode = [_]u8{
        // First jump
        0x60, 0x05, // PUSH1 5
        0x56,       // JUMP
        0xfe,       // INVALID
        
        0x5b,       // JUMPDEST (offset 5)
        // Second jump
        0x60, 0x0a, // PUSH1 10
        0x56,       // JUMP
        0xfe,       // INVALID
        
        0x5b,       // JUMPDEST (offset 10)
        // Conditional jump back
        0x60, 0x01, // PUSH1 1
        0x60, 0x14, // PUSH1 20
        0x57,       // JUMPI
        0xfe,       // INVALID
        
        0x5b,       // JUMPDEST (offset 20)
        // Return
        0x60, 0x03, // PUSH1 3 (three jumps taken)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMP with stack operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test JUMP with dynamic destination calculation
    const bytecode = [_]u8{
        // Calculate jump destination
        0x60, 0x08, // PUSH1 8
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD (8 + 2 = 10)
        0x56,       // JUMP
        0xfe,       // INVALID
        0xfe,       // INVALID
        0x5b,       // JUMPDEST (offset 10)
        
        // Return calculated value
        0x60, 0x0a, // PUSH1 10
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PC opcode with jumps" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test PC opcode behavior with jumps
    const bytecode = [_]u8{
        // Get PC before jump
        0x58,       // PC (should be 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Jump forward
        0x60, 0x0a, // PUSH1 10
        0x56,       // JUMP
        0xfe,       // INVALID
        
        0x5b,       // JUMPDEST (offset 10)
        // Get PC after jump
        0x58,       // PC (should be 11)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return both PC values
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: jump table edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test jump to last valid offset
    const bytecode = [_]u8{
        // Fill with jumpdests
        0x5b, 0x5b, 0x5b, 0x5b, 0x5b, // JUMPDEST x5
        0x5b, 0x5b, 0x5b, 0x5b, 0x5b, // JUMPDEST x10
        
        // Jump to various offsets
        0x60, 0x00, // PUSH1 0
        0x56,       // JUMP (to offset 0)
        
        0x60, 0x09, // PUSH1 9
        0x56,       // JUMP (to offset 9)
        
        // Return from any point
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMP out of bounds" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test JUMP beyond code size
    const bytecode = [_]u8{
        // Try to jump way out of bounds
        0x61, 0xff, 0xff, // PUSH2 65535
        0x56,       // JUMP
        
        // Should not reach here
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: JUMPDEST in PUSH data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test that JUMPDEST inside PUSH data is not valid
    const bytecode = [_]u8{
        // Try to jump into PUSH data
        0x60, 0x04, // PUSH1 4
        0x56,       // JUMP
        0x61, 0x5b, 0x5b, // PUSH2 0x5b5b (contains JUMPDEST bytes)
        
        // Real JUMPDEST
        0x5b,       // JUMPDEST (offset 7)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}