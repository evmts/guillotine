const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: CALL with large gas values" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALL with max u64 gas value
    const bytecode = [_]u8{
        // Push parameters for CALL
        0x60, 0x00, // PUSH1 0 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (address)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 max u64
        0xf1,       // CALL
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALL with overflow gas" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALL with gas > u64 max (should fail)
    const bytecode = [_]u8{
        // Push parameters for CALL
        0x60, 0x00, // PUSH1 0 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (address)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 max u256
        0xf1,       // CALL
        
        // Store result (should be 0 for failure)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: DELEGATECALL preserves msg.sender and value" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Create contract that uses DELEGATECALL
    const bytecode = [_]u8{
        // Store original caller
        0x33,       // CALLER
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Store original value
        0x34,       // CALLVALUE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // DELEGATECALL to address 0x42
        0x60, 0x40, // PUSH1 64 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x42, // PUSH1 0x42 (address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf4,       // DELEGATECALL
        
        // Return stored values
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STATICCALL restrictions" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STATICCALL cannot modify state
    const bytecode = [_]u8{
        // STATICCALL to address that tries to modify state
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x02, // PUSH1 2 (address - usually a precompile)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xfa,       // STATICCALL
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CREATE with large init code" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE with maximum size init code
    const bytecode = [_]u8{
        // Store init code in memory (simple contract that returns 42)
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x1f, // PUSH1 31 (offset to get last byte)
        0xf3,       // RETURN
        
        // The above is our init code, now CREATE
        0x60, 0x08, // PUSH1 8 (size of init code)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        
        // Store created address
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CREATE2 deterministic addresses" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE2 with various salts
    const bytecode = [_]u8{
        // Init code: empty contract
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        
        // CREATE2 with salt 0
        0x60, 0x00, // PUSH1 0 (salt)
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        
        // CREATE2 with salt MAX_U256
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 MAX_U256 (salt)
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        
        // XOR addresses (should be different)
        0x18,       // XOR
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: RETURN with large data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test RETURN with maximum reasonable size
    const bytecode = [_]u8{
        // Fill memory with pattern
        0x7f, 0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe,
        0xef, 0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe,
        0xef, 0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe,
        0xef, 0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, // PUSH32 pattern
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Copy pattern multiple times
        0x60, 0x00, // PUSH1 0 (source)
        0x60, 0x20, // PUSH1 32 (dest)
        0x60, 0x20, // PUSH1 32 (size)
        0x39,       // CODECOPY
        
        // RETURN 64 bytes
        0x60, 0x40, // PUSH1 64 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: REVERT with error data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test REVERT with custom error data
    const bytecode = [_]u8{
        // Store error selector (Error(string))
        0x63, 0x08, 0xc3, 0x79, 0xa0, // PUSH4 0x08c379a0
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (partial)
        
        // Store error string offset
        0x60, 0x20, // PUSH1 32
        0x60, 0x04, // PUSH1 4
        0x52,       // MSTORE
        
        // Store string length
        0x60, 0x0e, // PUSH1 14 ("Out of balance")
        0x60, 0x24, // PUSH1 36
        0x52,       // MSTORE
        
        // Store string data
        0x7f, 0x4f, 0x75, 0x74, 0x20, 0x6f, 0x66, 0x20,
        0x62, 0x61, 0x6c, 0x61, 0x6e, 0x63, 0x65, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 "Out of balance"
        0x60, 0x44, // PUSH1 68
        0x52,       // MSTORE
        
        // REVERT with error data
        0x60, 0x64, // PUSH1 100 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd,       // REVERT
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: SELFDESTRUCT edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test SELFDESTRUCT to various addresses
    const bytecode = [_]u8{
        // Store initial balance
        0x47,       // SELFBALANCE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // SELFDESTRUCT to self (edge case)
        0x30,       // ADDRESS
        0xff,       // SELFDESTRUCT
        
        // This should never execute
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: nested CALL depth limit" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test approaching call depth limit (1024)
    const bytecode = [_]u8{
        // Check if we can make a call
        0x5a,       // GAS
        0x61, 0x27, 0x10, // PUSH2 10000
        0x10,       // LT (gas < 10000?)
        0x60, 0x0e, // PUSH1 14 (jump dest if true)
        0x57,       // JUMPI
        
        // Make recursive CALL
        0x60, 0x00, // PUSH1 0 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x30,       // ADDRESS (call self)
        0x5a,       // GAS
        0x60, 0x64, // PUSH1 100
        0x03,       // SUB (gas - 100)
        0xf1,       // CALL
        
        // Return depth counter
        0x5b,       // JUMPDEST (offset 14)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: memory expansion attacks" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test extreme memory offsets
    const bytecode = [_]u8{
        // Try to CALL with huge memory offsets
        0x60, 0x20, // PUSH1 32 (output size)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 large offset
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (address)
        0x61, 0x01, 0x00, // PUSH2 256 (gas)
        0xf1,       // CALL (should fail due to memory cost)
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: RETURNDATASIZE and RETURNDATACOPY" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test return data handling
    const bytecode = [_]u8{
        // Initial RETURNDATASIZE should be 0
        0x3d,       // RETURNDATASIZE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // CALL to address 0x04 (identity precompile)
        0x60, 0x20, // PUSH1 32 (output size)
        0x60, 0x20, // PUSH1 32 (output offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL
        
        // Get RETURNDATASIZE after call
        0x3d,       // RETURNDATASIZE
        0x60, 0x08, // PUSH1 8
        0x52,       // MSTORE
        
        // Copy return data
        0x3d,       // RETURNDATASIZE
        0x60, 0x00, // PUSH1 0 (dest)
        0x60, 0x00, // PUSH1 0 (offset)
        0x3e,       // RETURNDATACOPY
        
        // Return stored values
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: gas edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test various gas-related edge cases
    const bytecode = [_]u8{
        // Store remaining gas
        0x5a,       // GAS
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // CALL with exactly remaining gas
        0x60, 0x00, // PUSH1 0 (output size)
        0x60, 0x00, // PUSH1 0 (output offset)
        0x60, 0x00, // PUSH1 0 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (address)
        0x5a,       // GAS (all remaining)
        0xf1,       // CALL
        
        // Store result and remaining gas
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        0x5a,       // GAS
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}