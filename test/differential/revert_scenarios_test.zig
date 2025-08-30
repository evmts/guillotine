const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: DELEGATECALL that reverts with no data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Create bytecode that will be delegatecalled and reverts immediately
    const revert_target_code = [_]u8{
        0x60, 0x00, // PUSH1 0 (revert data size)
        0x60, 0x00, // PUSH1 0 (revert data offset) 
        0xfd,       // REVERT (revert with no data)
    };
    
    // Store the target code in contract storage for DELEGATECALL
    const bytecode = [_]u8{
        // Store revert target code in memory at offset 100
        0x60, 0x00, 0x60, 0x64, 0x53, // MSTORE8 0x00 at offset 100
        0x60, 0x00, 0x60, 0x65, 0x53, // MSTORE8 0x00 at offset 101  
        0x60, 0xfd, 0x60, 0x66, 0x53, // MSTORE8 0xfd (REVERT) at offset 102
        
        // DELEGATECALL parameters: gas, address, argsOffset, argsSize, retOffset, retSize
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize) 
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x30,       // ADDRESS (use self as target - will execute stored code)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf4,       // DELEGATECALL (should fail due to revert)
        
        // Store result (should be 0 for failure)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Check return data size (should be 0 since no revert data)
        0x3d,       // RETURNDATASIZE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: DELEGATECALL that reverts with custom data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test DELEGATECALL that reverts with specific revert data
    const bytecode = [_]u8{
        // Store revert message "ERROR" in memory
        0x7f, 0x45, 0x52, 0x52, 0x4f, 0x52, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 "ERROR..."
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Create target code that reverts with the stored message
        // Target code: PUSH1 5, PUSH1 0, REVERT (revert with 5 bytes from offset 0)
        0x60, 0x60, 0x60, 0x40, 0x53, // MSTORE8 PUSH1 at offset 64
        0x60, 0x05, 0x60, 0x41, 0x53, // MSTORE8 5 at offset 65
        0x60, 0x60, 0x60, 0x42, 0x53, // MSTORE8 PUSH1 at offset 66  
        0x60, 0x00, 0x60, 0x43, 0x53, // MSTORE8 0 at offset 67
        0x60, 0xfd, 0x60, 0x44, 0x53, // MSTORE8 REVERT at offset 68
        
        // DELEGATECALL to execute the revert code
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x20, // PUSH1 32 (retOffset) 
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x30,       // ADDRESS (self)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf4,       // DELEGATECALL (should fail with revert data)
        
        // Store call result (should be 0)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Copy return data to memory for analysis
        0x3d,       // RETURNDATASIZE
        0x60, 0x00, // PUSH1 0 (destOffset)
        0x60, 0x00, // PUSH1 0 (offset)
        0x3e,       // RETURNDATACOPY
        
        // Store return data size
        0x3d,       // RETURNDATASIZE
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Return all results
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALL that reverts due to insufficient gas" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALL with insufficient gas causing revert
    const bytecode = [_]u8{
        // Store some data for the call
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // CALL parameters: gas, address, value, argsOffset, argsSize, retOffset, retSize  
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x20, // PUSH1 32 (retOffset)
        0x60, 0x20, // PUSH1 32 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile address)
        0x60, 0x01, // PUSH1 1 (very low gas - should fail)
        0xf1,       // CALL (should fail due to insufficient gas)
        
        // Store result (should be 0 for failure)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Check remaining gas
        0x5a,       // GAS
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALL that reverts with invalid precompile input" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CALL to ecRecover precompile with invalid input
    const bytecode = [_]u8{
        // Store invalid data for ecRecover (all zeros - invalid signature)
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (hash = 0)
        
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE (v = 0, invalid)
        
        0x60, 0x00, // PUSH1 0
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE (r = 0, invalid)
        
        0x60, 0x00, // PUSH1 0
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE (s = 0, invalid)
        
        // CALL ecRecover precompile with invalid input
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x80, // PUSH1 128 (retOffset)
        0x60, 0x80, // PUSH1 128 (argsSize - full ecRecover input)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x01, // PUSH1 1 (ecRecover precompile address)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL (should succeed but return empty result)
        
        // Store call result
        0x60, 0xa0, // PUSH1 160
        0x52,       // MSTORE
        
        // Check return data size
        0x3d,       // RETURNDATASIZE
        0x60, 0xc0, // PUSH1 192
        0x52,       // MSTORE
        
        // Return all results
        0x60, 0xe0, // PUSH1 224
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STATICCALL that attempts state modification" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STATICCALL that should fail due to attempted state modification
    const bytecode = [_]u8{
        // Create code that attempts to modify storage (should fail in STATICCALL)
        // Target code: PUSH1 1, PUSH1 0, SSTORE (store 1 at slot 0)
        0x60, 0x60, 0x60, 0x00, 0x53, // MSTORE8 PUSH1 at offset 0
        0x60, 0x01, 0x60, 0x01, 0x53, // MSTORE8 1 at offset 1
        0x60, 0x60, 0x60, 0x02, 0x53, // MSTORE8 PUSH1 at offset 2
        0x60, 0x00, 0x60, 0x03, 0x53, // MSTORE8 0 at offset 3  
        0x60, 0x55, 0x60, 0x04, 0x53, // MSTORE8 SSTORE at offset 4
        0x60, 0x00, 0x60, 0x05, 0x53, // MSTORE8 STOP at offset 5
        
        // STATICCALL parameters: gas, address, argsOffset, argsSize, retOffset, retSize
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x20, // PUSH1 32 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x30,       // ADDRESS (self - will execute code from memory)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xfa,       // STATICCALL (should fail due to SSTORE in static context)
        
        // Store result (should be 0 for failure)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Check if any state was actually modified (should be unchanged)
        0x60, 0x00, // PUSH1 0 (storage slot)
        0x54,       // SLOAD (should still be 0)
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Return results  
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALL chain with multiple reverts" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test a chain of calls where some succeed and some revert
    const bytecode = [_]u8{
        // First, successful CALL to identity precompile
        0x60, 0x42, // PUSH1 0x42 (test data)
        0x60, 0x00, // PUSH1 0
        0x53,       // MSTORE8 (store at memory[0])
        
        0x60, 0x01, // PUSH1 1 (retSize)
        0x60, 0x20, // PUSH1 32 (retOffset)  
        0x60, 0x01, // PUSH1 1 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile)
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,       // CALL (should succeed)
        
        // Store first call result
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Second, failing CALL with insufficient gas
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x60, // PUSH1 96 (retOffset)
        0x60, 0x01, // PUSH1 1 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile)
        0x60, 0x01, // PUSH1 1 (insufficient gas)
        0xf1,       // CALL (should fail)
        
        // Store second call result
        0x60, 0x80, // PUSH1 128
        0x52,       // MSTORE
        
        // Third, successful CALL again
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0xa0, // PUSH1 160 (retOffset)
        0x60, 0x01, // PUSH1 1 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x04, // PUSH1 4 (identity precompile)
        0x61, 0x13, 0x88, // PUSH2 5000 (sufficient gas)
        0xf1,       // CALL (should succeed)
        
        // Store third call result
        0x60, 0xc0, // PUSH1 192
        0x52,       // MSTORE
        
        // Return all results
        0x60, 0xe0, // PUSH1 224
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}