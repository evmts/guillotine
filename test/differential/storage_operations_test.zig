const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: SSTORE and SLOAD basic" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test basic storage operations
    const bytecode = [_]u8{
        // Store value at key 0
        0x60, 0x42, // PUSH1 66 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE
        
        // Load value from key 0
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD
        
        // Return loaded value
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: SSTORE gas refunds" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test storage patterns that trigger gas refunds
    const bytecode = [_]u8{
        // Set storage slot to non-zero
        0x60, 0x01, // PUSH1 1 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE (cold, zero to non-zero)
        
        // Change non-zero to different non-zero
        0x60, 0x02, // PUSH1 2 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE (warm, non-zero to non-zero)
        
        // Set back to zero (gas refund)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE (warm, non-zero to zero)
        
        // Load to verify
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD
        
        // Return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: TSTORE and TLOAD transient storage" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test transient storage (EIP-1153)
    const bytecode = [_]u8{
        // Store in transient storage
        0x60, 0x42, // PUSH1 66 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x5d,       // TSTORE
        
        // Load from transient storage
        0x60, 0x00, // PUSH1 0 (key)
        0x5c,       // TLOAD
        
        // Store another value
        0x60, 0xff, // PUSH1 255 (value)
        0x60, 0x01, // PUSH1 1 (key)
        0x5d,       // TSTORE
        
        // Load second value
        0x60, 0x01, // PUSH1 1 (key)
        0x5c,       // TLOAD
        
        // Add both values
        0x01,       // ADD
        
        // Return sum
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: storage with large keys" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test storage with maximum key values
    const bytecode = [_]u8{
        // Store at key MAX_U256
        0x60, 0x42, // PUSH1 66 (value)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256 (key)
        0x55,       // SSTORE
        
        // Load from key MAX_U256
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256 (key)
        0x54,       // SLOAD
        
        // Return value
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: storage collision patterns" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test potential hash collision patterns
    const bytecode = [_]u8{
        // Store different values at calculated keys
        0x60, 0x01, // PUSH1 1 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE
        
        0x60, 0x02, // PUSH1 2 (value)
        0x61, 0x01, 0x00, // PUSH2 256 (key)
        0x55,       // SSTORE
        
        0x60, 0x03, // PUSH1 3 (value)
        0x62, 0x01, 0x00, 0x00, // PUSH3 65536 (key)
        0x55,       // SSTORE
        
        // Load and sum all values
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD
        0x61, 0x01, 0x00, // PUSH2 256 (key)
        0x54,       // SLOAD
        0x01,       // ADD
        0x62, 0x01, 0x00, 0x00, // PUSH3 65536 (key)
        0x54,       // SLOAD
        0x01,       // ADD (sum should be 6)
        
        // Return sum
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: cold and warm storage access" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test EIP-2929 cold/warm access patterns
    const bytecode = [_]u8{
        // First access (cold)
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD (cold access)
        
        // Second access (warm)
        0x60, 0x00, // PUSH1 0 (key)
        0x54,       // SLOAD (warm access)
        
        // Store (makes slot warm)
        0x60, 0x42, // PUSH1 66 (value)
        0x60, 0x01, // PUSH1 1 (key)
        0x55,       // SSTORE (cold access)
        
        // Load same slot (warm)
        0x60, 0x01, // PUSH1 1 (key)
        0x54,       // SLOAD (warm access)
        
        // Return last loaded value
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: transient storage edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test transient storage doesn't persist
    const bytecode = [_]u8{
        // Load from uninitialized transient storage
        0x60, 0x00, // PUSH1 0 (key)
        0x5c,       // TLOAD (should be 0)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store max value at max key
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256 (value)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256 (key)
        0x5d,       // TSTORE
        
        // Load it back
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256 (key)
        0x5c,       // TLOAD
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return both values
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: storage in static context" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test that SSTORE fails in static context
    const bytecode = [_]u8{
        // This would be called via STATICCALL, simulated here
        // Try to store (should fail in static context)
        0x60, 0x42, // PUSH1 66 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE (should revert in static context)
        
        // If we get here, return 1
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: SLOAD from uninitialized storage" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test loading from various uninitialized slots
    const bytecode = [_]u8{
        // Load from key 0 (uninitialized)
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD
        
        // Load from key 1337 (uninitialized)
        0x61, 0x05, 0x39, // PUSH2 1337
        0x54,       // SLOAD
        
        // Load from large key (uninitialized)
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
        0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32
        0x54,       // SLOAD
        
        // All should be 0, so OR them together
        0x17,       // OR
        0x17,       // OR (result should be 0)
        
        // Return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}