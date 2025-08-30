const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: memory expansion beyond limit" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Try to expand memory beyond maximum limit (16MB typical)
    const bytecode = [_]u8{
        // Try to store at very large offset
        0x60, 0xff,             // PUSH1 255 (value)
        0x63, 0xff, 0xff, 0xff, 0xff, // PUSH4 0xffffffff (max u32 offset)
        0x52,                   // MSTORE (should fail - too large)
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory beyond limit", &bytecode, &[_]u8{});
}

test "differential: memory word boundary expansion" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test memory expansion at 32-byte boundaries
    const bytecode = [_]u8{
        // Store at offset 0 (expands to 32)
        0x60, 0x11,             // PUSH1 17
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x59,                   // MSIZE (should be 32)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE result
        
        // Store at offset 31 (still within first 32 bytes)
        0x60, 0x22,             // PUSH1 34
        0x60, 0x1f,             // PUSH1 31
        0x53,                   // MSTORE8
        0x59,                   // MSIZE (should still be 32)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE result
        
        // Store at offset 32 (expands to 64)
        0x60, 0x33,             // PUSH1 51
        0x60, 0x20,             // PUSH1 32
        0x53,                   // MSTORE8
        0x59,                   // MSIZE (should be 64)
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE result
        
        // Store at offset 63 (still within 64 bytes)
        0x60, 0x44,             // PUSH1 68
        0x60, 0x3f,             // PUSH1 63
        0x53,                   // MSTORE8
        0x59,                   // MSIZE (should still be 64)
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE result
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory word boundaries", &bytecode, &[_]u8{});
}

test "differential: overlapping memory operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test overlapping MLOAD/MSTORE operations
    const bytecode = [_]u8{
        // Store overlapping 32-byte words
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, // PUSH32 word1
        0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
        0xdd, 0xee, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09,
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE (at offset 0)
        
        0x7f, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, // PUSH32 word2
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
        0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xaa, 0xbb,
        0x60, 0x10,             // PUSH1 16 (overlaps with first store)
        0x52,                   // MSTORE (at offset 16)
        
        // Load overlapping regions
        0x60, 0x08,             // PUSH1 8
        0x51,                   // MLOAD (load from offset 8 - spans both stores)
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE (store result)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("overlapping memory ops", &bytecode, &[_]u8{});
}

test "differential: memory access at exact expansion points" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test memory access at points that trigger expansion
    const bytecode = [_]u8{
        // Access at offset 0 (expands to 32)
        0x60, 0x00,             // PUSH1 0
        0x51,                   // MLOAD (should return 0, expand memory)
        0x50,                   // POP
        0x59,                   // MSIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE (store size)
        
        // Access at offset 31 (still within 32 bytes)
        0x60, 0x1f,             // PUSH1 31
        0x51,                   // MLOAD (accesses bytes 31-62, expands to 64)
        0x50,                   // POP
        0x59,                   // MSIZE
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE (store size)
        
        // Access at large offset
        0x61, 0x04, 0x00,       // PUSH2 1024
        0x51,                   // MLOAD (expands to 1056)
        0x50,                   // POP
        0x59,                   // MSIZE
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE (store size)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory expansion points", &bytecode, &[_]u8{});
}

test "differential: large memory copy operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test large MCOPY operations
    const bytecode = [_]u8{
        // Fill initial memory
        0x60, 0xaa,             // PUSH1 170
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0xbb,             // PUSH1 187
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Large copy - 1KB
        0x61, 0x04, 0x00,       // PUSH2 1024 (size)
        0x60, 0x00,             // PUSH1 0 (source)
        0x61, 0x08, 0x00,       // PUSH2 2048 (dest)
        0x5e,                   // MCOPY
        
        // Check final memory size (should be 2048 + 1024 = 3072)
        0x59,                   // MSIZE
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("large memory copy", &bytecode, &[_]u8{});
}

test "differential: memory unaligned byte access patterns" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test unaligned byte operations
    const bytecode = [_]u8{
        // Store pattern with MSTORE8 at various offsets
        0x60, 0x11,             // PUSH1 0x11
        0x60, 0x05,             // PUSH1 5
        0x53,                   // MSTORE8 (store at offset 5)
        
        0x60, 0x22,             // PUSH1 0x22
        0x60, 0x0a,             // PUSH1 10
        0x53,                   // MSTORE8 (store at offset 10)
        
        0x60, 0x33,             // PUSH1 0x33
        0x60, 0x17,             // PUSH1 23
        0x53,                   // MSTORE8 (store at offset 23)
        
        0x60, 0x44,             // PUSH1 0x44
        0x60, 0x2f,             // PUSH1 47
        0x53,                   // MSTORE8 (store at offset 47)
        
        // Load 32-byte word that spans these bytes
        0x60, 0x00,             // PUSH1 0
        0x51,                   // MLOAD (load bytes 0-31)
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE (store result)
        
        0x60, 0x20,             // PUSH1 32
        0x51,                   // MLOAD (load bytes 32-63)
        0x60, 0x80,             // PUSH1 128
        0x52,                   // MSTORE (store result)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("unaligned byte access", &bytecode, &[_]u8{});
}

test "differential: memory quadratic cost scaling" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test gas costs for memory expansion at different scales
    const bytecode = [_]u8{
        // Small expansion (check gas cost)
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        0x60, 0xaa,             // PUSH1 170
        0x60, 0x80,             // PUSH1 128 (small expansion)
        0x52,                   // MSTORE
        
        0x5a,                   // GAS (check remaining)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Medium expansion
        0x60, 0xbb,             // PUSH1 187
        0x61, 0x08, 0x00,       // PUSH2 2048 (medium expansion)
        0x52,                   // MSTORE
        
        0x5a,                   // GAS (check remaining)
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Large expansion (if gas permits)
        0x60, 0xcc,             // PUSH1 204
        0x61, 0x20, 0x00,       // PUSH2 8192 (large expansion)
        0x52,                   // MSTORE
        
        0x5a,                   // GAS (final check)
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory quadratic cost", &bytecode, &[_]u8{});
}

test "differential: memory operations with zero size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test edge cases with zero-size operations
    const bytecode = [_]u8{
        // MCOPY with zero size (should be no-op)
        0x60, 0x00,             // PUSH1 0 (size = 0)
        0x60, 0x00,             // PUSH1 0 (source)
        0x61, 0x10, 0x00,       // PUSH2 4096 (dest - large offset)
        0x5e,                   // MCOPY (should not expand memory)
        
        // Check memory size (should still be 0)
        0x59,                   // MSIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE (this expands to 32)
        
        // Final memory size check
        0x59,                   // MSIZE (should be 32)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory zero size ops", &bytecode, &[_]u8{});
}

test "differential: memory access beyond current size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Access memory beyond currently allocated region
    const bytecode = [_]u8{
        // Establish small memory region
        0x60, 0x12,             // PUSH1 18
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE (memory is now 32 bytes)
        
        // Access far beyond current memory
        0x61, 0x04, 0x00,       // PUSH2 1024 (far beyond 32)
        0x51,                   // MLOAD (should return 0s and expand memory)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE (store the loaded value)
        
        // Check expanded memory size
        0x59,                   // MSIZE (should be 1024 + 32 = 1056)
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory access beyond size", &bytecode, &[_]u8{});
}

test "differential: CODECOPY with large offsets and sizes" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CODECOPY edge cases
    const bytecode = [_]u8{
        // Copy code beyond actual code size
        0x61, 0x01, 0x00,       // PUSH2 256 (size > actual code)
        0x60, 0x00,             // PUSH1 0 (code offset)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0x39,                   // CODECOPY (should pad with zeros)
        
        // Copy from offset beyond code size
        0x60, 0x20,             // PUSH1 32 (size)
        0x61, 0x01, 0x00,       // PUSH2 256 (offset > code size)
        0x61, 0x01, 0x00,       // PUSH2 256 (memory offset)
        0x39,                   // CODECOPY (should copy all zeros)
        
        // Check memory size after operations
        0x59,                   // MSIZE
        0x61, 0x01, 0x20,       // PUSH2 288
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("CODECOPY large offsets", &bytecode, &[_]u8{});
}

test "differential: memory stress test with mixed operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Mix different memory operations to stress the system
    const bytecode = [_]u8{
        // Pattern of mixed operations
        0x60, 0x11,             // PUSH1 17
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        0x60, 0x22,             // PUSH1 34
        0x60, 0x10,             // PUSH1 16
        0x53,                   // MSTORE8
        
        0x60, 0x08,             // PUSH1 8
        0x51,                   // MLOAD
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Copy operations
        0x60, 0x20,             // PUSH1 32 (size)
        0x60, 0x00,             // PUSH1 0 (source)
        0x60, 0x80,             // PUSH1 128 (dest)
        0x5e,                   // MCOPY
        
        // More byte operations
        0x60, 0x33,             // PUSH1 51
        0x60, 0x95,             // PUSH1 149
        0x53,                   // MSTORE8
        
        // Final memory size
        0x59,                   // MSIZE
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory stress test", &bytecode, &[_]u8{});
}