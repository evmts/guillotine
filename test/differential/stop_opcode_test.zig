const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: STOP opcode basic functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test basic STOP - should terminate execution immediately
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x00,       // STOP - execution should halt here
        
        // These instructions should never execute
        0x60, 0xff, // PUSH1 0xff (should not execute)
        0x60, 0x20, // PUSH1 32 (should not execute)
        0x52,       // MSTORE (should not execute)
        0x60, 0x40, // PUSH1 64 (should not execute)
        0x60, 0x00, // PUSH1 0 (should not execute)
        0xf3,       // RETURN (should not execute)
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STOP vs RETURN behavior comparison" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STOP - should return no data
    const bytecode_stop = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store 0x42 at memory[0])
        0x00,       // STOP - should return no data
    };
    
    try testor.test_bytecode(&bytecode_stop);
}

test "differential: STOP with different stack states" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STOP with items left on stack
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2  
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x60, 0x05, // PUSH1 5
        0x00,       // STOP - should terminate with items on stack
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STOP after memory operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STOP after various memory operations
    const bytecode = [_]u8{
        // Store different values in memory
        0x60, 0xaa, // PUSH1 0xaa
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        0x60, 0xbb, // PUSH1 0xbb
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        0x60, 0xcc, // PUSH1 0xcc
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Load from memory
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD
        0x50,       // POP (discard)
        
        0x00,       // STOP - terminate execution
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STOP after storage operations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STOP after storage operations
    const bytecode = [_]u8{
        // Store values in storage
        0x60, 0x11, // PUSH1 0x11
        0x60, 0x01, // PUSH1 1 (key)
        0x55,       // SSTORE
        
        0x60, 0x22, // PUSH1 0x22
        0x60, 0x02, // PUSH1 2 (key)
        0x55,       // SSTORE
        
        // Load from storage
        0x60, 0x01, // PUSH1 1 (key)
        0x54,       // SLOAD
        0x50,       // POP (discard)
        
        0x00,       // STOP - terminate execution
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STOP in conditional execution branch" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STOP in a branch that should be taken
    const bytecode = [_]u8{
        // Condition: 1 == 1 (true)
        0x60, 0x01, // PUSH1 1
        0x60, 0x01, // PUSH1 1
        0x14,       // EQ (result: 1/true)
        0x60, 0x0e, // PUSH1 14 (jump destination)
        0x57,       // JUMPI (should jump since condition is true)
        
        // This should not execute
        0x60, 0xff, // PUSH1 0xff
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
        
        // This branch should execute (contains STOP)
        0x5b,       // JUMPDEST (offset 14)
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x00,       // STOP - should terminate here
        
        // This should not execute
        0x60, 0x99, // PUSH1 0x99
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: STOP with gas consumption analysis" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test STOP with minimal operations to analyze gas usage
    const bytecode = [_]u8{
        0x5a,       // GAS (get remaining gas)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store initial gas)
        
        // Do some work
        0x60, 0x10, // PUSH1 16
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD (16 + 5 = 21)
        0x50,       // POP (discard result)
        
        0x5a,       // GAS (get remaining gas after work)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE (store final gas)
        
        0x00,       // STOP - should terminate cleanly
    };
    
    try testor.test_bytecode(&bytecode);
}