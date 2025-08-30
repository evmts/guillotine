const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: LOG0 opcode no topics" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG0 with data but no topics
    const bytecode = [_]u8{
        // Store log data in memory
        0x7f, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, // PUSH32 "Hello, World!..."
        0x6f, 0x72, 0x6c, 0x64, 0x21, 0x20, 0x54, 0x68,
        0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x4c, 0x4f,
        0x47, 0x30, 0x20, 0x74, 0x65, 0x73, 0x74, 0x21,
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Emit LOG0
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa0,                   // LOG0 (no topics)
        
        // Continue execution
        0x60, 0x42,             // PUSH1 66
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG0 no topics", &bytecode, &[_]u8{});
}

test "differential: LOG1 opcode one topic" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG1 with one topic
    const bytecode = [_]u8{
        // Store log data
        0x7f, 0x54, 0x72, 0x61, 0x6e, 0x73, 0x66, 0x65, 0x72, // PUSH32 "Transfer data..."
        0x20, 0x64, 0x61, 0x74, 0x61, 0x20, 0x66, 0x6f,
        0x72, 0x20, 0x4c, 0x4f, 0x47, 0x31, 0x20, 0x74,
        0x65, 0x73, 0x74, 0x69, 0x6e, 0x67, 0x21, 0x00,
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Topic 1
        0x7f, 0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b, // PUSH32 Transfer event signature
        0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
        0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
        0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
        
        // Emit LOG1
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa1,                   // LOG1 (one topic)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG1 one topic", &bytecode, &[_]u8{});
}

test "differential: LOG2 opcode two topics" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG2 with two topics (like Transfer event)
    const bytecode = [_]u8{
        // Store amount in memory (32 bytes)
        0x60, 0x64,             // PUSH1 100 (transfer amount)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Topic 1: Transfer event signature
        0x7f, 0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b, // PUSH32 keccak256("Transfer(address,address,uint256)")
        0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
        0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
        0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
        
        // Topic 2: From address
        0x73, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, // PUSH20 from address
        0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78,
        
        // Emit LOG2
        0x60, 0x20,             // PUSH1 32 (data size)  
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa2,                   // LOG2 (two topics)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG2 two topics", &bytecode, &[_]u8{});
}

test "differential: LOG3 opcode three topics" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG3 with three topics (like Transfer event with from/to)
    const bytecode = [_]u8{
        // Store data in memory
        0x61, 0x03, 0xe8,       // PUSH2 1000 (amount)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Topic 1: Event signature
        0x7f, 0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b, // PUSH32 Transfer signature
        0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
        0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
        0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
        
        // Topic 2: From address  
        0x73, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, // PUSH20 from
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
        
        // Topic 3: To address
        0x73, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, // PUSH20 to
        0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55,
        
        // Emit LOG3
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa3,                   // LOG3 (three topics)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG3 three topics", &bytecode, &[_]u8{});
}

test "differential: LOG4 opcode four topics" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG4 with maximum topics
    const bytecode = [_]u8{
        // Store complex data
        0x7f, 0x4c, 0x4f, 0x47, 0x34, 0x20, 0x74, 0x65, 0x73, // PUSH32 "LOG4 test data..."
        0x73, 0x74, 0x20, 0x64, 0x61, 0x74, 0x61, 0x20,
        0x77, 0x69, 0x74, 0x68, 0x20, 0x66, 0x6f, 0x75,
        0x72, 0x20, 0x74, 0x6f, 0x70, 0x69, 0x63, 0x73,
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Topic 1: Event signature
        0x7f, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, // PUSH32 topic1
        0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc,
        0xde, 0xf0,
        
        // Topic 2
        0x7f, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, // PUSH32 topic2
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
        0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xaa, 0xbb,
        
        // Topic 3
        0x7f, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44, 0x55, 0x55, // PUSH32 topic3
        0x66, 0x66, 0x77, 0x77, 0x88, 0x88, 0x99, 0x99, 0xaa, 0xaa,
        0xbb, 0xbb, 0xcc, 0xcc, 0xdd, 0xdd, 0xee, 0xee, 0xff, 0xff,
        0x00, 0x00,
        
        // Topic 4  
        0x7f, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, // PUSH32 topic4
        0x55, 0x44, 0x33, 0x22, 0x11, 0x00, 0xff, 0xee, 0xdd, 0xcc,
        0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22,
        0x11, 0x00,
        
        // Emit LOG4
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa4,                   // LOG4 (four topics - maximum)
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG4 four topics", &bytecode, &[_]u8{});
}

test "differential: LOG with zero length data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG with no data
    const bytecode = [_]u8{
        // Topic for LOG1
        0x7f, 0x45, 0x6d, 0x70, 0x74, 0x79, 0x20, 0x6c, 0x6f, // PUSH32 "Empty log topic..."
        0x67, 0x20, 0x74, 0x6f, 0x70, 0x69, 0x63, 0x20,
        0x66, 0x6f, 0x72, 0x20, 0x74, 0x65, 0x73, 0x74,
        0x69, 0x6e, 0x67, 0x20, 0x70, 0x75, 0x72, 0x70,
        
        // Emit LOG1 with zero data length
        0x60, 0x00,             // PUSH1 0 (data size = 0)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa1,                   // LOG1
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG zero data", &bytecode, &[_]u8{});
}

test "differential: LOG with large data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Emit LOG with larger data payload
    const bytecode = [_]u8{
        // Fill memory with pattern
        0x60, 0xaa,             // PUSH1 0xaa
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0xbb,             // PUSH1 0xbb
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        0x60, 0xcc,             // PUSH1 0xcc
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        0x60, 0xdd,             // PUSH1 0xdd  
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        // Topic
        0x7f, 0x4c, 0x61, 0x72, 0x67, 0x65, 0x20, 0x64, 0x61, // PUSH32 "Large data log..."
        0x74, 0x61, 0x20, 0x6c, 0x6f, 0x67, 0x20, 0x65,
        0x76, 0x65, 0x6e, 0x74, 0x20, 0x74, 0x65, 0x73,
        0x74, 0x69, 0x6e, 0x67, 0x20, 0x68, 0x65, 0x72,
        
        // Emit LOG1 with 128 bytes of data
        0x60, 0x80,             // PUSH1 128 (data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa1,                   // LOG1
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG large data", &bytecode, &[_]u8{});
}

test "differential: multiple LOG operations in sequence" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Multiple different LOG operations
    const bytecode = [_]u8{
        // Data for first log
        0x60, 0x11,             // PUSH1 17
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // LOG0 first
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa0,                   // LOG0
        
        // Data for second log
        0x60, 0x22,             // PUSH1 34
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Topic for LOG1
        0x60, 0x99,             // PUSH1 153 (simple topic)
        
        // LOG1 second
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x20,             // PUSH1 32 (data offset)
        0xa1,                   // LOG1
        
        // Data for third log
        0x60, 0x33,             // PUSH1 51
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        // Two topics for LOG2
        0x60, 0x77,             // PUSH1 119 (topic1)
        0x60, 0x88,             // PUSH1 136 (topic2)
        
        // LOG2 third
        0x60, 0x20,             // PUSH1 32 (data size)
        0x60, 0x40,             // PUSH1 64 (data offset)
        0xa2,                   // LOG2
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("multiple LOGs", &bytecode, &[_]u8{});
}

test "differential: LOG operations with gas limit edge case" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Try to emit LOG with large data that might hit gas limits
    const bytecode = [_]u8{
        // Fill lots of memory (expensive)
        0x61, 0x04, 0x00,       // PUSH2 1024 (large amount)
        0x60, 0x00,             // PUSH1 0 (value)
        0x60, 0x00,             // PUSH1 0 (offset)
        0x5e,                   // MCOPY would be here, but using MSTORE pattern
        
        // Pattern to fill memory
        0x60, 0xff,             // PUSH1 255
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0xee,             // PUSH1 238  
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Topic
        0x60, 0x42,             // PUSH1 66 (simple topic)
        
        // Try to LOG large amount (may fail due to gas)
        0x61, 0x01, 0x00,       // PUSH2 256 (large data size)
        0x60, 0x00,             // PUSH1 0 (data offset)
        0xa1,                   // LOG1
        
        0x00,                   // STOP
    };
    
    try testor.test_differential("LOG gas edge case", &bytecode, &[_]u8{});
}