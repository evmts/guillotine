const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: MSTORE and MLOAD basic" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test basic memory store and load
    const bytecode = [_]u8{
        // Store value at offset 0
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Load value from offset 0
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD
        
        // Store result for return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: memory expansion" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test memory expansion to various sizes
    const bytecode = [_]u8{
        // Store at offset 0
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store at offset 32 (expand to 64 bytes)
        0x60, 0x02, // PUSH1 2
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Store at offset 256 (expand to 288 bytes)
        0x60, 0x03, // PUSH1 3
        0x61, 0x01, 0x00, // PUSH2 256
        0x52,       // MSTORE
        
        // Get memory size
        0x59,       // MSIZE
        
        // Return memory size
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: MSTORE8 operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test byte-level memory operations
    const bytecode = [_]u8{
        // Store 4 bytes individually
        0x60, 0xde, // PUSH1 0xde
        0x60, 0x00, // PUSH1 0
        0x53,       // MSTORE8
        
        0x60, 0xad, // PUSH1 0xad
        0x60, 0x01, // PUSH1 1
        0x53,       // MSTORE8
        
        0x60, 0xbe, // PUSH1 0xbe
        0x60, 0x02, // PUSH1 2
        0x53,       // MSTORE8
        
        0x60, 0xef, // PUSH1 0xef
        0x60, 0x03, // PUSH1 3
        0x53,       // MSTORE8
        
        // Load as word
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD
        
        // Return result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: MCOPY basic" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY operation (EIP-5656)
    const bytecode = [_]u8{
        // Store pattern at offset 0
        0x7f, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, // PUSH32
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Copy 32 bytes from 0 to 32
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (source)
        0x60, 0x20, // PUSH1 32 (dest)
        0x5e,       // MCOPY
        
        // Load from destination
        0x60, 0x20, // PUSH1 32
        0x51,       // MLOAD
        
        // Return copied value
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: MCOPY overlapping regions" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY with overlapping source and destination
    const bytecode = [_]u8{
        // Store pattern
        0x7f, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, // PUSH32
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Copy 24 bytes from offset 8 to offset 0 (overlapping)
        0x60, 0x18, // PUSH1 24 (size)
        0x60, 0x08, // PUSH1 8 (source)
        0x60, 0x00, // PUSH1 0 (dest)
        0x5e,       // MCOPY
        
        // Load result
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD
        
        // Return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: memory zero padding" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test that expanded memory is zero-initialized
    const bytecode = [_]u8{
        // Load from uninitialized memory
        0x61, 0x01, 0x00, // PUSH2 256
        0x51,       // MLOAD (should be 0)
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store something at offset 512
        0x60, 0xff, // PUSH1 255
        0x61, 0x02, 0x00, // PUSH2 512
        0x52,       // MSTORE
        
        // Load from offset 256 again (should still be 0)
        0x61, 0x01, 0x00, // PUSH2 256
        0x51,       // MLOAD
        
        // XOR with first result (should be 0)
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD
        0x18,       // XOR
        
        // Store and return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: MSIZE edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MSIZE at various expansion points
    const bytecode = [_]u8{
        // Initial MSIZE should be 0
        0x59,       // MSIZE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // After first store, MSIZE = 32
        0x59,       // MSIZE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // After second store, MSIZE = 64
        0x59,       // MSIZE
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // MSTORE8 at offset 95 expands to 96
        0x60, 0x42, // PUSH1 66
        0x60, 0x5f, // PUSH1 95
        0x53,       // MSTORE8
        0x59,       // MSIZE (should be 96)
        
        // Store final MSIZE
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Return all MSIZE values
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: memory offset edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test memory operations at edge offsets
    const bytecode = [_]u8{
        // Store at offset MAX_U256 - 31 (edge of addressable memory)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xe1, // PUSH32 MAX_U256 - 31
        0x60, 0x42, // PUSH1 66
        0x81,       // DUP2
        0x52,       // MSTORE (should fail due to gas cost)
        
        // If we get here, push 0
        0x60, 0x00, // PUSH1 0
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLDATALOAD and CALLDATACOPY" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test calldata operations
    const bytecode = [_]u8{
        // Get calldata size
        0x36,       // CALLDATASIZE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Load first 32 bytes of calldata
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Copy all calldata to memory offset 64
        0x36,       // CALLDATASIZE
        0x60, 0x00, // PUSH1 0 (source offset)
        0x60, 0x40, // PUSH1 64 (dest offset)
        0x37,       // CALLDATACOPY
        
        // Return first 96 bytes
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CODECOPY operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test code copying
    const bytecode = [_]u8{
        // Get code size
        0x38,       // CODESIZE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Copy first 32 bytes of code to memory offset 32
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (source)
        0x60, 0x20, // PUSH1 32 (dest)
        0x39,       // CODECOPY
        
        // Load copied code
        0x60, 0x20, // PUSH1 32
        0x51,       // MLOAD
        
        // Store for comparison
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: EXTCODECOPY edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test external code copying
    const bytecode = [_]u8{
        // Get code size of address 0 (should be 0)
        0x60, 0x00, // PUSH1 0 (address)
        0x3b,       // EXTCODESIZE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Try to copy code from address 1 (precompile)
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (source offset)
        0x60, 0x20, // PUSH1 32 (dest offset)
        0x60, 0x01, // PUSH1 1 (address)
        0x3c,       // EXTCODECOPY
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}