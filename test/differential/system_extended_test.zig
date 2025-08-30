const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: CALLCODE legacy functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALLCODE opcode (legacy, similar to CALL but changes context)
    const bytecode = [_]u8{
        // CALLCODE parameters: gas, address, value, argsOffset, argsSize, retOffset, retSize
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (address - identity precompile)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf2,       // CALLCODE
        
        // Store result (success/failure)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLCODE with data transfer" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALLCODE with actual data to transfer
    const bytecode = [_]u8{
        // Store data in memory for the call
        0x7f, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f,
        0x72, 0x6c, 0x64, 0x21, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 "Hello World!"
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // CALLCODE to identity precompile with data
        0x60, 0x40, // PUSH1 64 (retSize)
        0x60, 0x40, // PUSH1 64 (retOffset)
        0x60, 0x0d, // PUSH1 13 (argsSize - "Hello World!" length)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf2,       // CALLCODE
        
        // Store call result
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return both input data and result
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLCODE vs CALL behavior comparison" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test showing difference between CALL and CALLCODE context behavior
    const bytecode = [_]u8{
        // First, use CALL to precompile
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x04, // PUSH1 4 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)  
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile)
        0x61, 0x13, 0x88, // PUSH2 5000 (gas)
        0xf1,       // CALL
        
        // Store CALL result
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Then use CALLCODE to same precompile
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x40, // PUSH1 64 (retOffset)
        0x60, 0x04, // PUSH1 4 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile)
        0x61, 0x13, 0x88, // PUSH2 5000 (gas)
        0xf2,       // CALLCODE
        
        // Store CALLCODE result
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return comparison results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLCODE with insufficient gas" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALLCODE with insufficient gas
    const bytecode = [_]u8{
        // CALLCODE with very little gas
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (address)
        0x60, 0x0a, // PUSH1 10 (very low gas)
        0xf2,       // CALLCODE (should fail)
        
        // Store result (should be 0 for failure)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: INVALID opcode behavior" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test INVALID opcode (0xfe) - should cause execution to halt
    const bytecode = [_]u8{
        // Some setup operations
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // INVALID opcode - execution should stop here
        0xfe,       // INVALID
        
        // These should never be reached
        0x60, 0x01, // PUSH1 1
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: INVALID opcode in conditional execution" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test INVALID opcode in a conditional branch that should not be taken
    const bytecode = [_]u8{
        // Condition: 1 == 0 (false)
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x14,       // EQ (result: 0/false)
        0x60, 0x0c, // PUSH1 12 (jump destination)
        0x57,       // JUMPI (should NOT jump since condition is false)
        
        // This should execute - return success value
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        
        // This branch should not execute (contains INVALID)
        0x5b,       // JUMPDEST (offset 12)
        0xfe,       // INVALID (should not be reached)
        0x60, 0x00, // PUSH1 0 (should not be reached)
        0x60, 0x00, // PUSH1 0 (should not be reached) 
        0x52,       // MSTORE (should not be reached)
        0x60, 0x20, // PUSH1 32 (should not be reached)
        0x60, 0x00, // PUSH1 0 (should not be reached)
        0xf3,       // RETURN (should not be reached)
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: INVALID opcode mixed with valid operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test program that does valid work before hitting INVALID
    const bytecode = [_]u8{
        // Do some arithmetic: 10 + 5 * 2 = 20
        0x60, 0x0a, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL (5 * 2 = 10)
        0x01,       // ADD (10 + 10 = 20)
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Now encounter INVALID
        0xfe,       // INVALID - execution should halt here
        
        // This should not execute
        0x60, 0xff, // PUSH1 255
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: edge cases with system opcodes" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test edge cases combining system opcodes
    const bytecode = [_]u8{
        // Get remaining gas before expensive operation
        0x5a,       // GAS
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Try CALLCODE with all remaining gas
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x20, // PUSH1 32 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (ecrecover precompile)
        0x5a,       // GAS (all remaining gas)
        0xf2,       // CALLCODE
        
        // Store result
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Get remaining gas after operation
        0x5a,       // GAS
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Return all results
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}