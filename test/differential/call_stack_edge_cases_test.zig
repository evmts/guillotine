const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: deep call stack approaching limit" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test call stack depth (EVM typically limits at 1024)
    const bytecode = [_]u8{
        // Recursive contract creation to build call stack
        // This creates a chain of calls that will eventually hit the limit
        
        // Create contract that makes another call
        0x60, 0x20,             // PUSH1 32 (contract size)
        0x60, 0x0c,             // PUSH1 12 (offset of contract code)
        0x60, 0x00,             // PUSH1 0 (memory dest)
        0x39,                   // CODECOPY
        
        0x60, 0x20,             // PUSH1 32 (contract size)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0xf0,                   // CREATE
        
        // If CREATE succeeded, call the created contract
        0x80,                   // DUP1 (duplicate address)
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input size)
        0x60, 0x00,             // PUSH1 0 (input offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x86,                   // DUP7 (call address)
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        0xf1,                   // CALL
        
        0x00,                   // STOP
        
        // Embedded contract code (creates recursive calls):
        0x30,                   // ADDRESS
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)  
        0x60, 0x00,             // PUSH1 0 (input size)
        0x60, 0x00,             // PUSH1 0 (input offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x30,                   // ADDRESS (call self)
        0x61, 0x27, 0x10,       // PUSH2 10000 (gas)
        0xf1,                   // CALL (recursive call)
        0x00,                   // STOP
    };
    
    try testor.test_differential("deep call stack", &bytecode, &[_]u8{});
}

test "differential: call stack overflow at 1024 limit" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Attempt to exceed the 1024 call depth limit
    const bytecode = [_]u8{
        // Simple recursive caller contract
        0x60, 0x16,             // PUSH1 22 (contract size)
        0x60, 0x0a,             // PUSH1 10 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x16,             // PUSH1 22 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Call the created contract (will recursively call itself)
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x81, 0x5a, 0xf1,       // CALL with remaining gas
        0x00,                   // STOP
        
        // Recursive contract:
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x30,                   // ADDRESS (call self)
        0x61, 0x27, 0x10,       // PUSH2 10000 (gas for recursion)
        0xf1,                   // CALL (recursive)
        0x00,                   // STOP
    };
    
    try testor.test_differential("call stack overflow", &bytecode, &[_]u8{});
}

test "differential: reentrancy attack pattern" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Simulate a reentrancy scenario
    const bytecode = [_]u8{
        // Store some state
        0x60, 0x64,             // PUSH1 100 (initial balance)
        0x60, 0x00,             // PUSH1 0 (storage slot)
        0x55,                   // SSTORE
        
        // Create contract that will call back
        0x60, 0x20,             // PUSH1 32 (contract size)
        0x60, 0x12,             // PUSH1 18 (offset to contract code)
        0x60, 0x00,             // PUSH1 0 (memory dest)
        0x39,                   // CODECOPY
        
        0x60, 0x20,             // PUSH1 32 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Simulate withdrawal call that gets re-entered
        0x60, 0x0a,             // PUSH1 10 (withdraw amount)
        0x60, 0x00,             // PUSH1 0 (storage slot)
        0x54,                   // SLOAD (load balance)
        0x10,                   // LT (check if amount <= balance)
        0x60, 0x2a,             // PUSH1 42 (jump target if valid)
        0x57,                   // JUMPI
        0x00,                   // STOP (insufficient balance)
        
        0x5b,                   // JUMPDEST (withdrawal logic)
        // External call before state update (vulnerable)
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x60, 0x0a,             // PUSH1 10 (value to send)
        0x82,                   // DUP3 (contract address)
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        0xf1,                   // CALL (vulnerable call)
        
        // Update state after call (too late!)
        0x60, 0x00,             // PUSH1 0
        0x54,                   // SLOAD (load balance)
        0x60, 0x0a,             // PUSH1 10
        0x03,                   // SUB (balance - 10)
        0x60, 0x00,             // PUSH1 0
        0x55,                   // SSTORE (update balance)
        
        0x00,                   // STOP
        
        // Reentrancy contract code:
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x33,                   // CALLER (call back to caller)
        0x61, 0x27, 0x10,       // PUSH2 10000 (gas)
        0xf1,                   // CALL (reentrant call)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    
    try testor.test_differential("reentrancy pattern", &bytecode, &[_]u8{});
}

test "differential: staticcall context enforcement" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test that STATICCALL prevents state modifications
    const bytecode = [_]u8{
        // Create contract that tries to modify state
        0x60, 0x18,             // PUSH1 24 (contract size)
        0x60, 0x0e,             // PUSH1 14 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x18,             // PUSH1 24 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Make STATICCALL to the contract
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input size)
        0x60, 0x00,             // PUSH1 0 (input offset)
        0x81,                   // DUP2 (contract address)
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        0xfa,                   // STATICCALL
        
        0x00,                   // STOP
        
        // Contract that tries to modify state in static context:
        0x60, 0x42,             // PUSH1 66 (value)
        0x60, 0x01,             // PUSH1 1 (storage slot)
        0x55,                   // SSTORE (should fail in static context)
        
        0x60, 0x99,             // PUSH1 153 (return value)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x20,             // PUSH1 32
        0x60, 0x00,             // PUSH1 0
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("staticcall context", &bytecode, &[_]u8{});
}

test "differential: delegatecall context preservation" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test DELEGATECALL context preservation
    const bytecode = [_]u8{
        // Set initial state
        0x60, 0xaa,             // PUSH1 170 (initial value)
        0x60, 0x00,             // PUSH1 0 (storage slot)
        0x55,                   // SSTORE
        
        // Create library contract
        0x60, 0x18,             // PUSH1 24 (contract size)
        0x60, 0x12,             // PUSH1 18 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x18,             // PUSH1 24 (size)
        0x60, 0x00,             // PUSH1 0 (offset)  
        0xf0,                   // CREATE
        
        // Make DELEGATECALL (should execute in our context)
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input size)
        0x60, 0x00,             // PUSH1 0 (input offset)
        0x81,                   // DUP2 (library address)
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        0xf4,                   // DELEGATECALL
        
        // Check if our storage was modified
        0x60, 0x00,             // PUSH1 0 (storage slot)
        0x54,                   // SLOAD (should be 0xbb if delegate worked)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
        
        // Library contract code (modifies caller's storage):
        0x60, 0xbb,             // PUSH1 187 (new value)
        0x60, 0x00,             // PUSH1 0 (storage slot)
        0x55,                   // SSTORE (modify caller's storage)
        
        0x60, 0x01,             // PUSH1 1 (success)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x20,             // PUSH1 32
        0x60, 0x00,             // PUSH1 0
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("delegatecall context", &bytecode, &[_]u8{});
}

test "differential: out of gas during nested calls" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test gas exhaustion in nested call scenarios
    const bytecode = [_]u8{
        // Create gas-consuming contract
        0x60, 0x20,             // PUSH1 32 (contract size)
        0x60, 0x0e,             // PUSH1 14 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x20,             // PUSH1 32 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Call with limited gas
        0x60, 0x00,             // PUSH1 0 (return data size)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input size)
        0x60, 0x00,             // PUSH1 0 (input offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x81,                   // DUP2 (contract address)
        0x61, 0x27, 0x10,       // PUSH2 10000 (limited gas)
        0xf1,                   // CALL
        
        0x00,                   // STOP
        
        // Gas-consuming contract:
        0x60, 0x02,             // PUSH1 2 (base)
        0x61, 0x03, 0xe8,       // PUSH2 1000 (large exponent)
        0x0a,                   // EXP (very expensive)
        0x50,                   // POP
        
        // Try to make another call (may fail due to gas)
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x30,                   // ADDRESS (call self)
        0x5a,                   // GAS (remaining gas)
        0xf1,                   // CALL
        
        0x60, 0x99,             // PUSH1 153
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x60, 0x20, 0x60, 0x00, 0xf3, // RETURN
    };
    
    try testor.test_differential("nested call gas limit", &bytecode, &[_]u8{});
}

test "differential: call return data size limits" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test handling of large return data
    const bytecode = [_]u8{
        // Create contract that returns large data
        0x60, 0x30,             // PUSH1 48 (contract size)
        0x60, 0x12,             // PUSH1 18 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x30,             // PUSH1 48 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Call with small return buffer
        0x60, 0x20,             // PUSH1 32 (small return data size)
        0x60, 0x40,             // PUSH1 64 (return data offset)
        0x60, 0x00,             // PUSH1 0 (input size)
        0x60, 0x00,             // PUSH1 0 (input offset)
        0x60, 0x00,             // PUSH1 0 (value)
        0x81,                   // DUP2 (contract address)
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        0xf1,                   // CALL
        
        // Check actual return data size
        0x3d,                   // RETURNDATASIZE
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x00,                   // STOP
        
        // Contract that returns large data:
        0x60, 0xff, 0x60, 0x00, 0x52,    // Store pattern
        0x60, 0xee, 0x60, 0x20, 0x52,    // Store pattern
        0x60, 0xdd, 0x60, 0x40, 0x52,    // Store pattern
        0x60, 0xcc, 0x60, 0x60, 0x52,    // Store pattern
        0x60, 0xbb, 0x60, 0x80, 0x52,    // Store pattern
        
        0x60, 0xa0,             // PUSH1 160 (return size > call buffer)
        0x60, 0x00,             // PUSH1 0 (return offset)
        0xf3,                   // RETURN (large return data)
    };
    
    try testor.test_differential("large return data", &bytecode, &[_]u8{});
}

test "differential: call value transfer edge cases" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test edge cases with value transfers in calls
    const bytecode = [_]u8{
        // Create simple contract
        0x60, 0x08,             // PUSH1 8 (contract size)
        0x60, 0x0a,             // PUSH1 10 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x08,             // PUSH1 8 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Try to send more value than we have
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x47,                   // SELFBALANCE (our balance)
        0x60, 0x01,             // PUSH1 1
        0x01,                   // ADD (try to send more than we have)
        0x81,                   // DUP2 (contract address)
        0x61, 0x75, 0x30,       // PUSH2 30000 (gas)
        0xf1,                   // CALL (should fail)
        
        0x00,                   // STOP
        
        // Simple contract:
        0x60, 0x01,             // PUSH1 1 (success)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("call value edge cases", &bytecode, &[_]u8{});
}

test "differential: create contract address collision" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE address collision scenarios
    const bytecode = [_]u8{
        // Create first contract
        0x60, 0x08,             // PUSH1 8 (contract size)
        0x60, 0x0c,             // PUSH1 12 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x08,             // PUSH1 8 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE
        
        // Try to create identical contract again (same nonce scenario)
        // This might be handled differently by different EVMs
        0x60, 0x08,             // PUSH1 8 (contract size)
        0x60, 0x0c,             // PUSH1 12 (offset)
        0x60, 0x00,             // PUSH1 0 (dest)
        0x39,                   // CODECOPY
        
        0x60, 0x08,             // PUSH1 8 (size)
        0x60, 0x00,             // PUSH1 0 (offset)
        0xf0,                   // CREATE (duplicate creation)
        
        0x00,                   // STOP
        
        // Simple contract code:
        0x60, 0x42,             // PUSH1 66
        0x60, 0x00,             // PUSH1 0
        0xf3,                   // RETURN
    };
    
    try testor.test_differential("create address collision", &bytecode, &[_]u8{});
}