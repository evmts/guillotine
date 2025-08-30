const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: MSIZE opcode memory size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MSIZE at different stages
    const bytecode = [_]u8{
        // Initial MSIZE (should be 0)
        0x59,                   // MSIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // MSIZE after first store (should be 32)
        0x59,                   // MSIZE
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Store at higher offset to expand memory
        0x60, 0xff,             // PUSH1 255 (value)
        0x60, 0x80,             // PUSH1 128 (offset)
        0x52,                   // MSTORE
        
        // MSIZE after expansion (should be 160 = 128 + 32)
        0x59,                   // MSIZE
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Store at even higher offset
        0x60, 0xaa,             // PUSH1 170 (value)
        0x61, 0x02, 0x00,       // PUSH2 512 (offset)
        0x52,                   // MSTORE
        
        // MSIZE after large expansion (should be 544 = 512 + 32)
        0x59,                   // MSIZE
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MSIZE progression", &bytecode, &[_]u8{});
}

test "differential: MSIZE with MSTORE8" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MSIZE with byte-level stores
    const bytecode = [_]u8{
        // Initial MSIZE
        0x59,                   // MSIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Store single byte at offset 0
        0x60, 0x42,             // PUSH1 66 (value)
        0x60, 0x00,             // PUSH1 0 (offset)
        0x53,                   // MSTORE8
        
        // MSIZE after byte store (should be 32)
        0x59,                   // MSIZE
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Store byte at offset 100
        0x60, 0x99,             // PUSH1 153 (value)
        0x60, 0x64,             // PUSH1 100 (offset)
        0x53,                   // MSTORE8
        
        // MSIZE after distant byte store (should be 128)
        0x59,                   // MSIZE
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MSIZE with MSTORE8", &bytecode, &[_]u8{});
}

test "differential: MCOPY opcode memory copy basic" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test basic MCOPY operation
    const bytecode = [_]u8{
        // Store source data
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, // PUSH32 source data
        0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
        0xdd, 0xee, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09,
        0x60, 0x00,             // PUSH1 0 (destination)
        0x52,                   // MSTORE
        
        // Copy 16 bytes from offset 0 to offset 64
        0x60, 0x10,             // PUSH1 16 (size)
        0x60, 0x00,             // PUSH1 0 (source offset)
        0x60, 0x40,             // PUSH1 64 (destination offset)
        0x5e,                   // MCOPY
        
        // Check MSIZE after copy (should be 80 = 64 + 16)
        0x59,                   // MSIZE
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MCOPY basic", &bytecode, &[_]u8{});
}

test "differential: MCOPY opcode overlapping regions forward" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY with overlapping memory regions (forward copy)
    const bytecode = [_]u8{
        // Store pattern data
        0x60, 0xaa,             // PUSH1 170
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0xbb,             // PUSH1 187
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        0x60, 0xcc,             // PUSH1 204
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Copy overlapping: from offset 0 to offset 16, size 32
        // This should copy first 32 bytes to position starting at 16
        0x60, 0x20,             // PUSH1 32 (size)
        0x60, 0x00,             // PUSH1 0 (source offset)
        0x60, 0x10,             // PUSH1 16 (destination offset)
        0x5e,                   // MCOPY
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MCOPY overlap forward", &bytecode, &[_]u8{});
}

test "differential: MCOPY opcode overlapping regions backward" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY with overlapping memory regions (backward copy)
    const bytecode = [_]u8{
        // Store pattern data at higher addresses
        0x60, 0x11,             // PUSH1 17
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        0x60, 0x22,             // PUSH1 34
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        0x60, 0x33,             // PUSH1 51
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        // Copy overlapping: from offset 32 to offset 16, size 48
        // This copies backwards from higher to lower address
        0x60, 0x30,             // PUSH1 48 (size)
        0x60, 0x20,             // PUSH1 32 (source offset)
        0x60, 0x10,             // PUSH1 16 (destination offset)
        0x5e,                   // MCOPY
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MCOPY overlap backward", &bytecode, &[_]u8{});
}

test "differential: MCOPY opcode zero size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY with zero size (should be no-op)
    const bytecode = [_]u8{
        // Store some data
        0x60, 0xff,             // PUSH1 255
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Get MSIZE before copy
        0x59,                   // MSIZE
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Copy zero bytes
        0x60, 0x00,             // PUSH1 0 (size = 0)
        0x60, 0x00,             // PUSH1 0 (source)
        0x60, 0x40,             // PUSH1 64 (destination)
        0x5e,                   // MCOPY
        
        // Get MSIZE after copy (should still be 64)
        0x59,                   // MSIZE
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MCOPY zero size", &bytecode, &[_]u8{});
}

test "differential: MCOPY opcode large copy" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY with larger data
    const bytecode = [_]u8{
        // Fill source memory with pattern
        0x60, 0x01,             // PUSH1 1
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x02,             // PUSH1 2
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        0x60, 0x03,             // PUSH1 3
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        0x60, 0x04,             // PUSH1 4
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        0x60, 0x05,             // PUSH1 5
        0x60, 0x80,             // PUSH1 128
        0x52,                   // MSTORE
        
        // Copy 80 bytes from offset 0 to offset 200
        0x60, 0x50,             // PUSH1 80 (size)
        0x60, 0x00,             // PUSH1 0 (source)
        0x60, 0xc8,             // PUSH1 200 (destination)
        0x5e,                   // MCOPY
        
        // Check final memory size
        0x59,                   // MSIZE
        0x60, 0xa0,             // PUSH1 160
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MCOPY large", &bytecode, &[_]u8{});
}

test "differential: MCOPY opcode memory expansion" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test MCOPY causing memory expansion
    const bytecode = [_]u8{
        // Store minimal data
        0x60, 0xde,             // PUSH1 222
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Copy to high memory address to force expansion
        0x60, 0x20,             // PUSH1 32 (size)
        0x60, 0x00,             // PUSH1 0 (source)
        0x61, 0x04, 0x00,       // PUSH2 1024 (destination - high address)
        0x5e,                   // MCOPY
        
        // Check expanded memory size (should be 1024 + 32 = 1056)
        0x59,                   // MSIZE
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MCOPY expansion", &bytecode, &[_]u8{});
}

test "differential: MSIZE and MCOPY combined operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test various combinations of MSIZE and MCOPY
    const bytecode = [_]u8{
        // Initial MSIZE (0)
        0x59,                   // MSIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Store data and check MSIZE
        0x60, 0x12,             // PUSH1 18
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        0x59,                   // MSIZE (should be 96)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Copy and check MSIZE
        0x60, 0x20,             // PUSH1 32 (size)
        0x60, 0x40,             // PUSH1 64 (source)
        0x60, 0x80,             // PUSH1 128 (dest)
        0x5e,                   // MCOPY
        0x59,                   // MSIZE (should be 160)
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        // Another copy to higher address
        0x60, 0x10,             // PUSH1 16 (size)
        0x60, 0x80,             // PUSH1 128 (source)
        0x61, 0x02, 0x00,       // PUSH2 512 (dest)
        0x5e,                   // MCOPY
        0x59,                   // MSIZE (should be 544)
        0x60, 0x80,             // PUSH1 128
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("MSIZE MCOPY combined", &bytecode, &[_]u8{});
}

test "differential: memory operations gas costs" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test gas consumption patterns with memory operations
    const bytecode = [_]u8{
        // Check gas before operations
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Expand memory significantly
        0x60, 0xff,             // PUSH1 255
        0x61, 0x10, 0x00,       // PUSH2 4096 (large offset)
        0x52,                   // MSTORE
        
        // Check gas after expansion
        0x5a,                   // GAS
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Large MCOPY operation
        0x61, 0x01, 0x00,       // PUSH2 256 (size)
        0x60, 0x00,             // PUSH1 0 (source)
        0x61, 0x20, 0x00,       // PUSH2 8192 (dest)
        0x5e,                   // MCOPY
        
        // Check gas after large copy
        0x5a,                   // GAS
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("memory gas costs", &bytecode, &[_]u8{});
}