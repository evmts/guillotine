const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: basic arithmetic operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Bytecode that performs various arithmetic operations and returns the result
    // Operations: 
    // 1. ADD: 5 + 3 = 8
    // 2. SUB: 10 - 4 = 6  
    // 3. MUL: 8 * 6 = 48 (0x30)
    // 4. DIV: 48 / 2 = 24 (0x18)
    // 5. MOD: 24 % 7 = 3
    // 6. ADDMOD: (3 + 5) % 5 = 3
    // 7. MULMOD: (3 * 4) % 5 = 2
    // 8. EXP: 2 ^ 3 = 8
    // 9. Final ADD: 8 + 1 = 9
    // Return 9 as 32-byte word
    
    const bytecode = [_]u8{
        // 1. ADD: 5 + 3
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD (result: 8)
        
        // 2. SUB: 10 - 4
        0x60, 0x0a, // PUSH1 10
        0x60, 0x04, // PUSH1 4
        0x03,       // SUB (result: 6)
        
        // 3. MUL: 8 * 6
        0x02,       // MUL (result: 48)
        
        // 4. DIV: 48 / 2
        0x60, 0x02, // PUSH1 2
        0x04,       // DIV (result: 24)
        
        // 5. MOD: 24 % 7
        0x60, 0x07, // PUSH1 7
        0x06,       // MOD (result: 3)
        
        // 6. ADDMOD: (3 + 5) % 5
        0x60, 0x05, // PUSH1 5
        0x60, 0x05, // PUSH1 5
        0x08,       // ADDMOD (result: 3)
        
        // 7. MULMOD: (3 * 4) % 5
        0x60, 0x04, // PUSH1 4
        0x60, 0x05, // PUSH1 5
        0x09,       // MULMOD (result: 2)
        
        // 8. EXP: 2 ^ 3
        0x60, 0x03, // PUSH1 3
        0x0a,       // EXP (result: 8)
        
        // 9. Final ADD: 8 + 1
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (result: 9)
        
        // Store result in memory and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: signed arithmetic operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SDIV, SMOD, and SIGNEXTEND
    const bytecode = [_]u8{
        // SDIV: -8 / 3 = -2 (in two's complement)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8, // PUSH32 -8
        0x60, 0x03, // PUSH1 3
        0x05,       // SDIV (result: -2)
        
        // Convert to positive for easier testing: -(-2) = 2
        0x60, 0x00, // PUSH1 0
        0x03,       // SUB (0 - (-2) = 2)
        
        // Store and return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: comparison operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test LT, GT, EQ, ISZERO
    const bytecode = [_]u8{
        // LT: 5 < 10 = 1
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10,       // LT (result: 1)
        
        // GT: 10 > 5 = 1
        0x60, 0x0a, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x11,       // GT (result: 1)
        
        // ADD: 1 + 1 = 2
        0x01,       // ADD
        
        // EQ: 2 == 2 = 1
        0x60, 0x02, // PUSH1 2
        0x14,       // EQ (result: 1)
        
        // ISZERO: !1 = 0, then !0 = 1
        0x15,       // ISZERO (result: 0)
        0x15,       // ISZERO (result: 1)
        
        // Store and return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}
