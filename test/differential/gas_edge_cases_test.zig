const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: out of gas during arithmetic operation" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Use up most gas, then try expensive operation
    const bytecode = [_]u8{
        // Expensive loop to consume gas
        0x60, 0x64,             // PUSH1 100 (loop counter)
        0x5b,                   // JUMPDEST (loop start)
        0x60, 0x01,             // PUSH1 1
        0x90,                   // SWAP1
        0x60, 0x01,             // PUSH1 1
        0x03,                   // SUB
        0x80,                   // DUP1
        0x60, 0x03,             // PUSH1 3 (jump target)
        0x57,                   // JUMPI (jump if counter > 0)
        0x50,                   // POP (clean up counter)
        
        // Try expensive EXP operation (likely out of gas)
        0x60, 0x02,             // PUSH1 2 (base)
        0x61, 0x03, 0xe8,       // PUSH2 1000 (large exponent)
        0x0a,                   // EXP (expensive operation)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("out of gas EXP", &bytecode, &[_]u8{});
}

test "differential: out of gas during memory expansion" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Try to expand memory to very large size
    const bytecode = [_]u8{
        // Consume some initial gas
        0x60, 0x0a,             // PUSH1 10
        0x5b,                   // JUMPDEST
        0x60, 0x01,             // PUSH1 1
        0x90,                   // SWAP1
        0x60, 0x01,             // PUSH1 1
        0x03,                   // SUB
        0x80,                   // DUP1
        0x60, 0x03,             // PUSH1 3
        0x57,                   // JUMPI
        0x50,                   // POP
        
        // Try massive memory expansion (should fail)
        0x60, 0xff,             // PUSH1 255 (value)
        0x63, 0x0f, 0xff, 0xff, 0xff, // PUSH4 268435455 (very large offset)
        0x52,                   // MSTORE (massive memory expansion cost)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("out of gas memory", &bytecode, &[_]u8{});
}

test "differential: out of gas during KECCAK256" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Setup large data and then try KECCAK with insufficient gas
    const bytecode = [_]u8{
        // Consume initial gas with loop
        0x60, 0x32,             // PUSH1 50
        0x5b,                   // JUMPDEST
        0x60, 0x01,             // PUSH1 1
        0x01,                   // ADD
        0x80,                   // DUP1
        0x60, 0x64,             // PUSH1 100
        0x10,                   // LT
        0x60, 0x03,             // PUSH1 3
        0x57,                   // JUMPI
        0x50,                   // POP
        
        // Try KECCAK on large memory region
        0x61, 0x10, 0x00,       // PUSH2 4096 (large size for KECCAK)
        0x60, 0x00,             // PUSH1 0 (offset)
        0x20,                   // KECCAK256 (expensive for large data)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("out of gas KECCAK", &bytecode, &[_]u8{});
}

test "differential: out of gas during CALL operation" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Try CALL with insufficient gas
    const bytecode = [_]u8{
        // Burn most gas with expensive operations
        0x60, 0x02,             // PUSH1 2
        0x61, 0x01, 0x00,       // PUSH2 256 (expensive exponent)
        0x0a,                   // EXP
        0x50,                   // POP
        
        0x60, 0x03,             // PUSH1 3
        0x61, 0x01, 0x00,       // PUSH2 256
        0x0a,                   // EXP
        0x50,                   // POP
        
        // Try CALL (should fail due to insufficient gas)
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input data size)
        0x60, 0x00,             // PUSH1 0 (input data offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x60, 0x01,             // PUSH1 1 (address)
        0x5a,                   // GAS (remaining gas)
        0xf1,                   // CALL
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("out of gas CALL", &bytecode, &[_]u8{});
}

test "differential: gas limit exactly at operation boundary" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Carefully consume gas to test boundary conditions
    const bytecode = [_]u8{
        // Check initial gas
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Consume known amount of gas with simple operations
        0x60, 0x01,             // PUSH1 1 (3 gas)
        0x60, 0x02,             // PUSH1 2 (3 gas)
        0x01,                   // ADD (3 gas)
        0x60, 0x03,             // PUSH1 3 (3 gas)
        0x02,                   // MUL (5 gas)
        0x50,                   // POP (2 gas)
        0x50,                   // POP (2 gas)
        // Total: ~21 gas consumed
        
        // Check remaining gas
        0x5a,                   // GAS
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Try operation that might hit exact limit
        0x60, 0x04,             // PUSH1 4
        0x60, 0x05,             // PUSH1 5
        0x01,                   // ADD
        0x50,                   // POP
        
        // Final gas check
        0x5a,                   // GAS
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("gas boundary", &bytecode, &[_]u8{});
}

test "differential: SSTORE gas costs cold vs warm" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SSTORE gas cost differences
    const bytecode = [_]u8{
        // Check gas before first SSTORE (cold)
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // First SSTORE to slot 1 (cold access - expensive)
        0x60, 0xaa,             // PUSH1 170 (value)
        0x60, 0x01,             // PUSH1 1 (key)
        0x55,                   // SSTORE
        
        // Check gas after first SSTORE
        0x5a,                   // GAS
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Second SSTORE to same slot (warm access - cheaper)
        0x60, 0xbb,             // PUSH1 187 (new value)
        0x60, 0x01,             // PUSH1 1 (same key)
        0x55,                   // SSTORE
        
        // Check gas after second SSTORE
        0x5a,                   // GAS
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // SSTORE to different slot (cold again)
        0x60, 0xcc,             // PUSH1 204 (value)
        0x60, 0x02,             // PUSH1 2 (different key)
        0x55,                   // SSTORE
        
        // Final gas check
        0x5a,                   // GAS
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("SSTORE gas costs", &bytecode, &[_]u8{});
}

test "differential: SLOAD gas costs cold vs warm" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SLOAD gas cost differences
    const bytecode = [_]u8{
        // Store initial value
        0x60, 0xff,             // PUSH1 255
        0x60, 0x05,             // PUSH1 5
        0x55,                   // SSTORE
        
        // Check gas before first SLOAD (warm due to SSTORE)
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // First SLOAD from slot 5 (warm)
        0x60, 0x05,             // PUSH1 5
        0x54,                   // SLOAD
        0x50,                   // POP
        
        // Check gas after first SLOAD
        0x5a,                   // GAS
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // SLOAD from different slot (cold)
        0x60, 0x0a,             // PUSH1 10 (different key)
        0x54,                   // SLOAD
        0x50,                   // POP
        
        // Check gas after cold SLOAD
        0x5a,                   // GAS
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // SLOAD from same new slot (now warm)
        0x60, 0x0a,             // PUSH1 10 (same key as before)
        0x54,                   // SLOAD
        0x50,                   // POP
        
        // Final gas check
        0x5a,                   // GAS
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("SLOAD gas costs", &bytecode, &[_]u8{});
}

test "differential: memory expansion gas progression" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test gas costs for memory expansion at different sizes
    const bytecode = [_]u8{
        // Initial gas
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Small expansion (32 bytes)
        0x5a,                   // GAS
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Medium expansion (1KB)
        0x60, 0xdd,             // PUSH1 221
        0x61, 0x04, 0x00,       // PUSH2 1024
        0x52,                   // MSTORE
        
        0x5a,                   // GAS
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Large expansion (8KB)
        0x60, 0xee,             // PUSH1 238
        0x61, 0x20, 0x00,       // PUSH2 8192
        0x52,                   // MSTORE
        
        0x5a,                   // GAS
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        // Very large expansion (64KB)
        0x60, 0xff,             // PUSH1 255
        0x63, 0x01, 0x00, 0x00, 0x00, // PUSH4 65536
        0x52,                   // MSTORE
        
        0x5a,                   // GAS
        0x60, 0x80,             // PUSH1 128
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory expansion gas", &bytecode, &[_]u8{});
}

test "differential: division by zero gas costs" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test that division by zero operations still consume gas
    const bytecode = [_]u8{
        // Check initial gas
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Division by zero (should return 0, still costs gas)
        0x60, 0x0a,             // PUSH1 10 (dividend)
        0x60, 0x00,             // PUSH1 0 (divisor = 0)
        0x04,                   // DIV (10 / 0 = 0 in EVM)
        0x50,                   // POP
        
        // Check gas after DIV
        0x5a,                   // GAS
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Modulo by zero
        0x60, 0x0f,             // PUSH1 15 (dividend)
        0x60, 0x00,             // PUSH1 0 (divisor = 0)
        0x06,                   // MOD (15 % 0 = 0 in EVM)
        0x50,                   // POP
        
        // Check gas after MOD
        0x5a,                   // GAS
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Signed division by zero
        0x60, 0x14,             // PUSH1 20
        0x60, 0x00,             // PUSH1 0
        0x05,                   // SDIV
        0x50,                   // POP
        
        // Final gas check
        0x5a,                   // GAS
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("division by zero gas", &bytecode, &[_]u8{});
}

test "differential: LOG operations gas costs by data size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test LOG gas costs scale with data size
    const bytecode = [_]u8{
        // Fill memory with data
        0x60, 0x11,             // PUSH1 17
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x22,             // PUSH1 34
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        0x60, 0x33,             // PUSH1 51
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Check gas before small LOG
        0x5a,                   // GAS
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        // Small LOG (8 bytes)
        0x60, 0xaa,             // PUSH1 topic
        0x60, 0x08,             // PUSH1 8 (small size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xa1,                   // LOG1
        
        // Check gas after small LOG
        0x5a,                   // GAS
        0x60, 0x80,             // PUSH1 128
        0x52,                   // MSTORE
        
        // Medium LOG (32 bytes)
        0x60, 0xbb,             // PUSH1 topic
        0x60, 0x20,             // PUSH1 32 (medium size)
        0x60, 0x20,             // PUSH1 32 (offset)
        0xa1,                   // LOG1
        
        // Check gas after medium LOG
        0x5a,                   // GAS
        0x60, 0xa0,             // PUSH1 160
        0x52,                   // MSTORE
        
        // Large LOG (96 bytes total)
        0x60, 0xcc,             // PUSH1 topic
        0x60, 0x60,             // PUSH1 96 (large size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xa1,                   // LOG1
        
        // Final gas check
        0x5a,                   // GAS
        0x60, 0xc0,             // PUSH1 192
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG gas costs", &bytecode, &[_]u8{});
}