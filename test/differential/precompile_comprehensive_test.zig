const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: ecRecover precompile (0x01)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test ecRecover precompile with sample signature data
    const bytecode = [_]u8{
        // Store hash in memory (32 bytes)
        0x7f, 0x7c, 0x80, 0xc6, 0x8e, 0x60, 0x3b, 0xf0, 0x9a,
        0xca, 0x17, 0xa5, 0x73, 0xe2, 0xb2, 0x11, 0x42,
        0xed, 0xfb, 0x8e, 0x8d, 0xed, 0x9b, 0xea, 0xb6,
        0x6e, 0x0a, 0x23, 0xbe, 0xbd, 0x02, 0x3c, 0x23, // PUSH32 hash
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store v (32 bytes, value 27)
        0x60, 0x1b, // PUSH1 27
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Store r (32 bytes)
        0x7f, 0xa8, 0x89, 0xc0, 0xea, 0x64, 0xd6, 0xb8, 0xef,
        0x9a, 0x8a, 0x01, 0x96, 0x4f, 0x2f, 0x20, 0x18,
        0x44, 0xfb, 0x60, 0x7f, 0xf0, 0x83, 0xb8, 0xc9,
        0x42, 0x50, 0x5f, 0xd1, 0xa8, 0xee, 0xa6, 0x60, // PUSH32 r
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Store s (32 bytes)
        0x7f, 0x2a, 0x55, 0x0e, 0x6f, 0x48, 0xfb, 0x9d, 0x95,
        0x92, 0xab, 0x48, 0xca, 0x80, 0xf6, 0x77, 0x64,
        0x6c, 0x7f, 0xe7, 0x5e, 0x86, 0x2a, 0xfa, 0xb8,
        0xd2, 0xbc, 0x2e, 0xc8, 0x07, 0x1f, 0xfb, 0x10, // PUSH32 s
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Call ecRecover precompile
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x80, // PUSH1 128 (output offset)
        0x60, 0x80, // PUSH1 128 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (ecRecover address)
        0x61, 0x75, 0x30, // PUSH2 30000 (gas)
        0xf1,       // CALL
        
        // Return output
        0x60, 0x40, // PUSH1 64 (return size)
        0x60, 0x80, // PUSH1 128 (return offset)
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: sha256 precompile (0x02)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SHA-256 precompile with "Hello, World!" input
    const bytecode = [_]u8{
        // Store "Hello, World!" in memory
        0x7f, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57,
        0x6f, 0x72, 0x6c, 0x64, 0x21, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 "Hello, World!"
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Call SHA-256 precompile
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x20, // PUSH1 32 (output offset)
        0x60, 0x0d, // PUSH1 13 (input size - "Hello, World!" length)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x02, // PUSH1 2 (SHA-256 address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        
        // Return SHA-256 hash
        0x60, 0x20, // PUSH1 32
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: ripemd160 precompile (0x03)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test RIPEMD-160 precompile
    const bytecode = [_]u8{
        // Store "abc" in memory
        0x7f, 0x61, 0x62, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 "abc"
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Call RIPEMD-160 precompile
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x20, // PUSH1 32 (output offset)
        0x60, 0x03, // PUSH1 3 (input size - "abc" length)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x03, // PUSH1 3 (RIPEMD-160 address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        
        // Return RIPEMD-160 hash (20 bytes + 12 zero padding)
        0x60, 0x20, // PUSH1 32
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: identity precompile (0x04)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test identity precompile (data copy function)
    const bytecode = [_]u8{
        // Store test pattern in memory
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x0f, 0xed, 0xcb, 0xa9, 0x87, 0x65, 0x43, 0x21, // PUSH32 test pattern
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Call identity precompile
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x20, // PUSH1 32 (output offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        
        // Return copied data
        0x60, 0x20, // PUSH1 32
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: modexp precompile (0x05) simple case" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test modular exponentiation: 3^4 mod 5 = 1
    const bytecode = [_]u8{
        // Store base_len = 1 (32 bytes, big-endian)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store exp_len = 1 (32 bytes, big-endian)
        0x60, 0x01, // PUSH1 1
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Store mod_len = 1 (32 bytes, big-endian)
        0x60, 0x01, // PUSH1 1
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Store base = 3
        0x60, 0x03, // PUSH1 3
        0x60, 0x60, // PUSH1 96
        0x53,       // MSTORE8
        
        // Store exp = 4
        0x60, 0x04, // PUSH1 4
        0x60, 0x61, // PUSH1 97
        0x53,       // MSTORE8
        
        // Store mod = 5
        0x60, 0x05, // PUSH1 5
        0x60, 0x62, // PUSH1 98
        0x53,       // MSTORE8
        
        // Call modexp precompile
        0x60, 0x01, // PUSH1 1 (output size)
        0x60, 0x80, // PUSH1 128 (output offset)
        0x60, 0x63, // PUSH1 99 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x05, // PUSH1 5 (modexp address)
        0x61, 0x75, 0x30, // PUSH2 30000 (gas)
        0xf1,       // CALL
        
        // Return result
        0x60, 0x01, // PUSH1 1
        0x60, 0x80, // PUSH1 128
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: ecAdd precompile (0x06) identity point" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BN254 elliptic curve addition: identity + identity = identity
    const bytecode = [_]u8{
        // Store first point (identity: 0,0) - 64 bytes total
        0x60, 0x00, // PUSH1 0 (x1 = 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0 (y1 = 0)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Store second point (identity: 0,0)
        0x60, 0x00, // PUSH1 0 (x2 = 0)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0 (y2 = 0)
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Call ecAdd precompile
        0x60, 0x40, // PUSH1 64 (output size - x,y coordinates)
        0x60, 0x80, // PUSH1 128 (output offset)
        0x60, 0x80, // PUSH1 128 (input size - 2 points)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x06, // PUSH1 6 (ecAdd address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        
        // Return result (should be identity point)
        0x60, 0x40, // PUSH1 64
        0x60, 0x80, // PUSH1 128
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: ecMul precompile (0x07) identity scalar" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BN254 scalar multiplication: identity_point * 5 = identity
    const bytecode = [_]u8{
        // Store point (identity: 0,0) - 64 bytes
        0x60, 0x00, // PUSH1 0 (x = 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0 (y = 0)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Store scalar = 5 (32 bytes)
        0x60, 0x05, // PUSH1 5
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Call ecMul precompile
        0x60, 0x40, // PUSH1 64 (output size)
        0x60, 0x60, // PUSH1 96 (output offset)
        0x60, 0x60, // PUSH1 96 (input size - point + scalar)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x07, // PUSH1 7 (ecMul address)
        0x61, 0x75, 0x30, // PUSH2 30000 (gas)
        0xf1,       // CALL
        
        // Return result
        0x60, 0x40, // PUSH1 64
        0x60, 0x60, // PUSH1 96
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: ecPairing precompile (0x08) empty input" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BN254 pairing with empty input (should return true)
    const bytecode = [_]u8{
        // Call ecPairing precompile with no input
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size - empty)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x08, // PUSH1 8 (ecPairing address)
        0x62, 0x01, 0x86, 0xa0, // PUSH3 100000 (gas)
        0xf1,       // CALL
        
        // Return result (should be 1 for true pairing)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: blake2f precompile (0x09)" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BLAKE2F compression function with minimal input
    const bytecode = [_]u8{
        // Store rounds (4 bytes) = 12 rounds
        0x60, 0x0c, // PUSH1 12
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store h (64 bytes) - initial BLAKE2b state
        // For simplicity, store zeros (not a valid BLAKE2b state, but tests the precompile)
        0x60, 0x00, // PUSH1 0
        0x60, 0x04, // PUSH1 4
        0x52,       // MSTORE
        // ... (would need to store all 64 bytes, simplified for test)
        
        // Store m (128 bytes) - message block (zeros for simplicity)
        0x60, 0x00, // PUSH1 0
        0x60, 0x44, // PUSH1 68
        0x52,       // MSTORE
        // ... (would need to store all 128 bytes)
        
        // Store t (16 bytes) - counter (zeros)
        0x60, 0x00, // PUSH1 0
        0x60, 0xc4, // PUSH1 196
        0x52,       // MSTORE
        
        // Store f (1 byte) - final flag
        0x60, 0x01, // PUSH1 1
        0x60, 0xd4, // PUSH1 212
        0x53,       // MSTORE8
        
        // Call BLAKE2F precompile
        0x60, 0x40, // PUSH1 64 (output size)
        0x60, 0xe0, // PUSH1 224 (output offset)
        0x60, 0xd5, // PUSH1 213 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x09, // PUSH1 9 (BLAKE2F address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        
        // Return result
        0x60, 0x40, // PUSH1 64
        0x60, 0xe0, // PUSH1 224
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: multiple precompile calls in sequence" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test calling multiple precompiles in sequence
    const bytecode = [_]u8{
        // Store "test" for identity precompile
        0x7f, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 "test"
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Call identity precompile
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x20, // PUSH1 32 (output offset)
        0x60, 0x04, // PUSH1 4 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity address)
        0x61, 0x13, 0x88, // PUSH2 5000 (gas)
        0xf1,       // CALL
        0x50,       // POP result
        
        // Call SHA-256 on same data
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x40, // PUSH1 64 (output offset)
        0x60, 0x04, // PUSH1 4 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x02, // PUSH1 2 (SHA-256 address)
        0x61, 0x13, 0x88, // PUSH2 5000 (gas)
        0xf1,       // CALL
        0x50,       // POP result
        
        // Return both results
        0x60, 0x40, // PUSH1 64
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: pointEvaluation precompile (0x0A) KZG" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test KZG point evaluation precompile (EIP-4844)
    // Note: This requires valid KZG setup which may not be available in test environment
    const bytecode = [_]u8{
        // Store versioned_hash (32 bytes) - mock value
        0x7f, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 versioned_hash
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store z (32 bytes) - evaluation point
        0x60, 0x01, // PUSH1 1
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Store y (32 bytes) - claimed evaluation
        0x60, 0x02, // PUSH1 2
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Store commitment (48 bytes) - mock G1 point
        0x60, 0x00, // PUSH1 0 (simplified, would need valid commitment)
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Store proof (48 bytes) - mock G1 point
        0x60, 0x00, // PUSH1 0 (simplified, would need valid proof)
        0x60, 0x90, // PUSH1 144
        0x52,       // MSTORE
        
        // Call pointEvaluation precompile
        0x60, 0x00, // PUSH1 0 (output size - empty on success)
        0x60, 0xc0, // PUSH1 192 (output offset)
        0x60, 0xc0, // PUSH1 192 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x0a, // PUSH1 10 (pointEvaluation address)
        0x62, 0x01, 0x86, 0xa0, // PUSH3 100000 (gas - expensive operation)
        0xf1,       // CALL
        
        // Store call result (success/failure)
        0x60, 0xc0, // PUSH1 192
        0x52,       // MSTORE
        
        // Return result
        0x60, 0x20, // PUSH1 32
        0x60, 0xc0, // PUSH1 192
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}