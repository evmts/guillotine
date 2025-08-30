const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: PUSH0 opcode (EIP-3855)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test PUSH0 - pushes zero onto stack
    const bytecode = [_]u8{
        0x5f,       // PUSH0
        0x5f,       // PUSH0
        0x01,       // ADD (0 + 0 = 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH0 with arithmetic operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test PUSH0 in various arithmetic contexts
    const bytecode = [_]u8{
        // Test: 42 + 0 = 42
        0x60, 0x2a, // PUSH1 42
        0x5f,       // PUSH0
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Test: 0 * 999 = 0
        0x5f,       // PUSH0
        0x61, 0x03, 0xe7, // PUSH2 999
        0x02,       // MUL
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Test: 0 == 0 = true (1)
        0x5f,       // PUSH0
        0x5f,       // PUSH0
        0x14,       // EQ
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH2 through PUSH8 opcodes" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test various PUSH sizes with representative values
    const bytecode = [_]u8{
        // PUSH2: 0x1234
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // PUSH3: 0x123456
        0x62, 0x12, 0x34, 0x56, // PUSH3 0x123456
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // PUSH4: 0x12345678 (common for function selectors)
        0x63, 0x12, 0x34, 0x56, 0x78, // PUSH4 0x12345678
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // PUSH5: 0x123456789A
        0x64, 0x12, 0x34, 0x56, 0x78, 0x9A, // PUSH5 0x123456789A
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // PUSH6: 0x123456789ABC
        0x65, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, // PUSH6 0x123456789ABC
        0x60, 0x80, // PUSH1 128
        0x52,       // MSTORE
        
        // PUSH7: 0x123456789ABCDE
        0x66, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, // PUSH7 0x123456789ABCDE
        0x60, 0xA0, // PUSH1 160
        0x52,       // MSTORE
        
        // PUSH8: 0x123456789ABCDEF0
        0x67, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, // PUSH8 0x123456789ABCDEF0
        0x60, 0xC0, // PUSH1 192
        0x52,       // MSTORE
        
        // Return all results
        0x60, 0xE0, // PUSH1 224
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH16 and PUSH20 opcodes (address-sized)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test PUSH sizes commonly used for addresses and intermediate values
    const bytecode = [_]u8{
        // PUSH16: 16-byte value
        0x6f, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, // PUSH16
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // PUSH20: Address-sized (20 bytes)
        0x73, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xAA, 0xBB, 0xCC, 0xDD, // PUSH20 (address size)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH24, PUSH28, and PUSH31 opcodes" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test larger PUSH sizes approaching PUSH32
    const bytecode = [_]u8{
        // PUSH24: 24-byte value  
        0x77, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, // PUSH24
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // PUSH28: 28-byte value
        0x7b, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x01, 0x02,
        0x03, 0x04, // PUSH28
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // PUSH31: 31-byte value (one less than PUSH32)
        0x7e, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x01, 0x02,
        0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, // PUSH31
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH opcodes with arithmetic operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test PUSH opcodes in arithmetic contexts
    const bytecode = [_]u8{
        // Add PUSH2 + PUSH3 values
        0x61, 0x01, 0x00, // PUSH2 256
        0x62, 0x02, 0x00, 0x00, // PUSH3 131072
        0x01,       // ADD (256 + 131072 = 131328)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Multiply PUSH4 by PUSH1
        0x63, 0x00, 0x00, 0x03, 0xe8, // PUSH4 1000
        0x60, 0x0a, // PUSH1 10
        0x02,       // MUL (1000 * 10 = 10000)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Compare PUSH5 values
        0x64, 0x00, 0x00, 0x00, 0x00, 0x01, // PUSH5 1
        0x64, 0x00, 0x00, 0x00, 0x00, 0x01, // PUSH5 1
        0x14,       // EQ (should be true = 1)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH opcodes stack depth test" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test multiple PUSH opcodes to verify stack behavior
    const bytecode = [_]u8{
        0x5f,       // PUSH0 (stack: [0])
        0x60, 0x01, // PUSH1 1 (stack: [1, 0])
        0x61, 0x00, 0x02, // PUSH2 2 (stack: [2, 1, 0])
        0x62, 0x00, 0x00, 0x03, // PUSH3 3 (stack: [3, 2, 1, 0])
        
        // Add top 4 values: 3 + 2 + 1 + 0 = 6
        0x01,       // ADD (stack: [5, 1, 0]) 
        0x01,       // ADD (stack: [6, 0])
        0x01,       // ADD (stack: [6])
        
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PUSH opcodes with maximum values" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test PUSH opcodes with maximum values for their size
    const bytecode = [_]u8{
        // PUSH2 max value: 0xFFFF
        0x61, 0xFF, 0xFF, // PUSH2 65535
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // PUSH4 max value: 0xFFFFFFFF  
        0x63, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH4 4294967295
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // PUSH8 max value: 0xFFFFFFFFFFFFFFFF
        0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH8 max u64
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}