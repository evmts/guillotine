const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: SIGNEXTEND basic operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SIGNEXTEND with various byte positions
    const bytecode = [_]u8{
        // SIGNEXTEND: Sign extend 0xFF from position 0 (should be -1)
        0x60, 0xFF, // PUSH1 0xFF (value to sign extend)
        0x60, 0x00, // PUSH1 0 (byte position)
        0x0b,       // SIGNEXTEND
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // SIGNEXTEND: Sign extend 0x7F from position 0 (should be 0x7F)  
        0x60, 0x7F, // PUSH1 0x7F (positive value)
        0x60, 0x00, // PUSH1 0 (byte position)
        0x0b,       // SIGNEXTEND
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // SIGNEXTEND: Sign extend from position 1
        0x61, 0xFF, 0x7F, // PUSH2 0xFF7F
        0x60, 0x01, // PUSH1 1 (byte position 1)
        0x0b,       // SIGNEXTEND
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return all results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: SIGNEXTEND edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SIGNEXTEND with edge cases
    const bytecode = [_]u8{
        // SIGNEXTEND with position >= 31 (should return value unchanged)
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x1F, // PUSH1 31 (position 31)
        0x0b,       // SIGNEXTEND
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // SIGNEXTEND with position > 31 (should return value unchanged)
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x20, // PUSH1 32 (position 32, invalid)
        0x0b,       // SIGNEXTEND  
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // SIGNEXTEND with zero value
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x0b,       // SIGNEXTEND
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: SIGNEXTEND with large values" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SIGNEXTEND with 32-byte values
    const bytecode = [_]u8{
        // Large value with sign bit set in byte 2
        0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x80, 0x00, // PUSH32 with sign bit in byte 2
        0x60, 0x02, // PUSH1 2 (extend from byte 2)
        0x0b,       // SIGNEXTEND
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Return result
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BYTE opcode basic operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BYTE extraction from various positions
    const bytecode = [_]u8{
        // BYTE: Extract byte 0 (leftmost) from 0x123456...
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE,
        0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // PUSH32 test pattern
        0x60, 0x00, // PUSH1 0 (byte index 0)
        0x1a,       // BYTE (should get 0x12)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // BYTE: Extract byte 1 from same value
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE,
        0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // PUSH32 test pattern
        0x60, 0x01, // PUSH1 1 (byte index 1)
        0x1a,       // BYTE (should get 0x34)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // BYTE: Extract byte 31 (rightmost) from same value
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE,
        0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // PUSH32 test pattern
        0x60, 0x1F, // PUSH1 31 (byte index 31)
        0x1a,       // BYTE (should get 0x07)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BYTE opcode edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BYTE with out-of-range indices
    const bytecode = [_]u8{
        // BYTE with index >= 32 (should return 0)
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x20, // PUSH1 32 (out of range)
        0x1a,       // BYTE (should return 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // BYTE with large index
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0xFF, // PUSH1 255 (way out of range)
        0x1a,       // BYTE (should return 0)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // BYTE with zero value
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0 (index 0)
        0x1a,       // BYTE (should return 0)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BYTE with dynamic indices" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BYTE with calculated indices
    const bytecode = [_]u8{
        // Calculate index: 10 + 5 = 15
        0x60, 0x0A, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD (index = 15)
        
        // Value to extract from
        0x7f, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
        0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
        0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, // PUSH32 sequential pattern
        
        0x1a,       // BYTE (extract byte at index 15, should get 0x10)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Return result
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: combined BYTE and SIGNEXTEND operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test combination of BYTE extraction and SIGNEXTEND
    const bytecode = [_]u8{
        // Extract a byte and then sign extend it
        0x7f, 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9,
        0xF8, 0x80, 0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x7A,
        0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x72,
        0x71, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, // PUSH32 with mixed signs
        
        // Extract byte 9 (0x80 - negative byte)
        0x60, 0x09, // PUSH1 9
        0x1a,       // BYTE (get 0x80)
        0x60, 0x00, // PUSH1 0
        0x0b,       // SIGNEXTEND (sign extend from byte 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Extract byte 10 (0x7F - positive byte)
        0x7f, 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9,
        0xF8, 0x80, 0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x7A,
        0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x72,
        0x71, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, // PUSH32 with mixed signs
        0x60, 0x0A, // PUSH1 10
        0x1a,       // BYTE (get 0x7F)
        0x60, 0x00, // PUSH1 0
        0x0b,       // SIGNEXTEND (sign extend from byte 0)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}