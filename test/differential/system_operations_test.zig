const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: CREATE opcode basic contract creation" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Create a simple contract that returns 42
    const bytecode = [_]u8{
        // Contract creation code that returns a simple contract
        0x60, 0x0a,             // PUSH1 10 (contract size)
        0x60, 0x0c,             // PUSH1 12 (offset where contract code starts)
        0x60, 0x00,             // PUSH1 0 (destination in memory)
        0x39,                   // CODECOPY (copy contract code to memory)
        0x60, 0x0a,             // PUSH1 10 (contract size)
        0x60, 0x00,             // PUSH1 0 (offset in memory)
        0xf0,                   // CREATE
        // Contract code to be deployed (returns 42):
        0x60, 0x2a,             // PUSH1 42
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x20,             // PUSH1 32
        0x60, 0x00,             // PUSH1 0
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("CREATE basic", &bytecode, &[_]u8{});
}

test "differential: CREATE2 opcode deterministic creation" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Create contract using CREATE2 with salt
    const bytecode = [_]u8{
        // Salt for CREATE2
        0x60, 0xff,             // PUSH1 255 (salt)
        // Contract creation code
        0x60, 0x0a,             // PUSH1 10 (contract size)
        0x60, 0x10,             // PUSH1 16 (offset where contract code starts)  
        0x60, 0x00,             // PUSH1 0 (destination in memory)
        0x39,                   // CODECOPY
        0x60, 0x0a,             // PUSH1 10 (contract size)
        0x60, 0x00,             // PUSH1 0 (offset in memory)
        0xf5,                   // CREATE2
        // Simple contract code:
        0x60, 0x2a,             // PUSH1 42
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x20,             // PUSH1 32
        0x60, 0x00,             // PUSH1 0
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("CREATE2 deterministic", &bytecode, &[_]u8{});
}

test "differential: CALL opcode external call" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Call to address with some data
    const bytecode = [_]u8{
        // Prepare call parameters
        0x60, 0x20,             // PUSH1 32 (return data size)
        0x60, 0x40,             // PUSH1 64 (return data offset)
        0x60, 0x04,             // PUSH1 4 (input data size)
        0x60, 0x00,             // PUSH1 0 (input data offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x73, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, // PUSH20 target address
        0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        // Store some input data
        0x63, 0x12, 0x34, 0x56, 0x78, // PUSH4 test data
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0xf1,                   // CALL
    };
    
    try testor.test_differential("CALL external", &bytecode, &[_]u8{});
}

test "differential: DELEGATECALL opcode delegate call" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Delegate call to address
    const bytecode = [_]u8{
        // Prepare delegate call parameters
        0x60, 0x20,             // PUSH1 32 (return data size)
        0x60, 0x40,             // PUSH1 64 (return data offset)  
        0x60, 0x04,             // PUSH1 4 (input data size)
        0x60, 0x00,             // PUSH1 0 (input data offset)
        0x73, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, // PUSH20 target
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        // Store input data
        0x63, 0xab, 0xcd, 0xef, 0x12, // PUSH4 test data
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0xf4,                   // DELEGATECALL
    };
    
    try testor.test_differential("DELEGATECALL", &bytecode, &[_]u8{});
}

test "differential: STATICCALL opcode static call" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Static call to address (cannot modify state)
    const bytecode = [_]u8{
        // Prepare static call parameters
        0x60, 0x20,             // PUSH1 32 (return data size)
        0x60, 0x40,             // PUSH1 64 (return data offset)
        0x60, 0x04,             // PUSH1 4 (input data size)  
        0x60, 0x00,             // PUSH1 0 (input data offset)
        0x73, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00, // PUSH20 target
        0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66,
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        // Store input data
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 test data
        0x60, 0x00,             // PUSH1 0  
        0x52,                   // MSTORE
        0xfa,                   // STATICCALL
    };
    
    try testor.test_differential("STATICCALL", &bytecode, &[_]u8{});
}

test "differential: RETURN opcode normal return" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Return some data from execution
    const bytecode = [_]u8{
        // Store return data in memory
        0x60, 0xaa,             // PUSH1 170 (test value)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0xbb,             // PUSH1 187 (another value)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        // Return the data
        0x60, 0x40,             // PUSH1 64 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("RETURN normal", &bytecode, &[_]u8{});
}

test "differential: REVERT opcode with data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Revert with error message
    const bytecode = [_]u8{
        // Store revert reason in memory  
        0x7f, 0x45, 0x72, 0x72, 0x6f, 0x72, 0x3a, 0x20, 0x73, // PUSH32 "Error: something..."
        0x6f, 0x6d, 0x65, 0x74, 0x68, 0x69, 0x6e, 0x67,
        0x20, 0x77, 0x65, 0x6e, 0x74, 0x20, 0x77, 0x72,
        0x6f, 0x6e, 0x67, 0x21, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        // Revert with the message
        0x60, 0x1d,             // PUSH1 29 (message length)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xfd,                   // REVERT
    };
    
    try testor.test_differential("REVERT with data", &bytecode, &[_]u8{});
}

test "differential: STOP opcode execution halt" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Simple execution that stops
    const bytecode = [_]u8{
        0x60, 0x42,             // PUSH1 66
        0x60, 0x01,             // PUSH1 1
        0x01,                   // ADD
        0x00,                   // STOP (halt execution)
        0x60, 0x99,             // PUSH1 153 (should not execute)
    };
    
    try testor.test_differential("STOP execution", &bytecode, &[_]u8{});
}

test "differential: SELFDESTRUCT opcode contract destruction" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Self-destruct and send balance to beneficiary
    const bytecode = [_]u8{
        // Beneficiary address
        0x73, 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0xde, 0xad, // PUSH20 beneficiary
        0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0xde, 0xad, 0xbe, 0xef,
        0xff,                   // SELFDESTRUCT
        0x60, 0x99,             // PUSH1 153 (should not execute)
    };
    
    try testor.test_differential("SELFDESTRUCT", &bytecode, &[_]u8{});
}

test "differential: CREATE with insufficient gas" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Try CREATE with very little gas
    const bytecode = [_]u8{
        // Very large contract code (will fail due to gas)
        0x61, 0x03, 0xe8,       // PUSH2 1000 (large size)
        0x60, 0x0c,             // PUSH1 12 (offset)
        0x60, 0x00,             // PUSH1 0
        0x39,                   // CODECOPY (will fail - not enough code)
        0x61, 0x03, 0xe8,       // PUSH2 1000 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE (should fail)
        // Minimal code:
        0x60, 0x00,             // PUSH1 0
        0x60, 0x00,             // PUSH1 0
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("CREATE gas failure", &bytecode, &[_]u8{});
}

test "differential: nested CALL operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Call that triggers another call
    const bytecode = [_]u8{
        // First call setup
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input data size)
        0x60, 0x00,             // PUSH1 0 (input data offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x73, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, // PUSH20 target1
        0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78,
        0x61, 0x27, 0x10,       // PUSH2 10000 (gas)
        0xf1,                   // CALL
        
        // Second nested call
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input data size)
        0x60, 0x00,             // PUSH1 0 (input data offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x73, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, // PUSH20 target2
        0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12,
        0x61, 0x27, 0x10,       // PUSH2 10000 (gas)
        0xf1,                   // CALL
    };
    
    try testor.test_differential("nested CALL", &bytecode, &[_]u8{});
}