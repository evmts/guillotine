const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const DifferentialTestor = @import("../differential/differential_testor.zig").DifferentialTestor;

const testing = std.testing;
const Address = primitives.Address.Address;

test "tracer: nested CREATE2 should trace both parent and child execution" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Factory contract that creates a child contract via CREATE2
    // Simple factory contract that creates a child via CREATE2  
    // This test exposes that nested CREATE2 calls lose tracer context
    const bytecode = [_]u8{
        // Store simple child contract bytecode: PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
        0x60, 0x60, // PUSH1 0x60 (PUSH1 opcode)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x53,       // MSTORE8
        0x60, 0x2a, // PUSH1 42 (value to store)
        0x60, 0x01, // PUSH1 1
        0x53,       // MSTORE8
        0x60, 0x60, // PUSH1 0x60 (PUSH1 opcode)  
        0x60, 0x02, // PUSH1 2
        0x53,       // MSTORE8
        0x60, 0x00, // PUSH1 0 (memory offset for MSTORE)
        0x60, 0x03, // PUSH1 3
        0x53,       // MSTORE8
        0x60, 0x52, // PUSH1 0x52 (MSTORE opcode)
        0x60, 0x04, // PUSH1 4
        0x53,       // MSTORE8
        // Total child bytecode: 5 bytes
        
        // CREATE2 the child contract  
        0x60, 0x01, // PUSH1 1 (salt - simple salt value)
        0x60, 0x05, // PUSH1 5 (init code size)
        0x60, 0x00, // PUSH1 0 (init code offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2 (should be traced at depth=1)
        
        // Return the created address
        0x60, 0x00, // PUSH1 0 (memory location to store address)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xf3,       // RETURN
    };
    
    // This test should fail initially because nested traces are missing
    try testor.test_bytecode(&bytecode);
}

test "tracer: three-level nested CREATE calls preserve all traces" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Parent contract creates Middle contract, Middle creates Child contract
    // Should trace depth=0 (Parent), depth=1 (Middle CREATE), depth=2 (Child CREATE)
    const bytecode = [_]u8{
        // Store Middle contract bytecode that creates another contract
        // Middle contract will: CREATE a simple child, then return child address
        
        // First, store Child contract code (PUSH1 99, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN)
        0x60, 0x60, 0x60, 0x00, 0x53, // PUSH1 0x60 (PUSH1 opcode) at memory[0]
        0x60, 0x63, 0x60, 0x01, 0x53, // 99 at memory[1]
        0x60, 0x60, 0x60, 0x02, 0x53, // PUSH1 opcode at memory[2]
        0x60, 0x00, 0x60, 0x03, 0x53, // 0 at memory[3]
        0x60, 0x52, 0x60, 0x04, 0x53, // MSTORE opcode at memory[4]
        0x60, 0x60, 0x60, 0x05, 0x53, // PUSH1 opcode at memory[5]
        0x60, 0x20, 0x60, 0x06, 0x53, // 32 at memory[6]
        0x60, 0x60, 0x60, 0x07, 0x53, // PUSH1 opcode at memory[7]  
        0x60, 0x00, 0x60, 0x08, 0x53, // 0 at memory[8]
        0x60, 0xf3, 0x60, 0x09, 0x53, // RETURN opcode at memory[9]
        
        // Store Middle contract code (CREATE child then return)
        0x60, 0x0a, 0x60, 0x0a, 0x53, // Child size (10) at memory[10]
        0x60, 0x00, 0x60, 0x0b, 0x53, // Child offset (0) at memory[11]
        0x60, 0x00, 0x60, 0x0c, 0x53, // Child value (0) at memory[12] 
        0x60, 0xf0, 0x60, 0x0d, 0x53, // CREATE opcode at memory[13]
        0x60, 0x60, 0x60, 0x0e, 0x53, // PUSH1 opcode at memory[14]
        0x60, 0x00, 0x60, 0x0f, 0x53, // 0 at memory[15]
        0x60, 0x52, 0x60, 0x10, 0x53, // MSTORE opcode at memory[16]
        0x60, 0x60, 0x60, 0x11, 0x53, // PUSH1 opcode at memory[17]
        0x60, 0x20, 0x60, 0x12, 0x53, // 32 at memory[18]
        0x60, 0x60, 0x60, 0x13, 0x53, // PUSH1 opcode at memory[19]
        0x60, 0x00, 0x60, 0x14, 0x53, // 0 at memory[20]
        0x60, 0xf3, 0x60, 0x15, 0x53, // RETURN opcode at memory[21]
        
        // CREATE Middle contract (will execute and create Child - 3 levels total)
        0x60, 0x0c, // PUSH1 12 (Middle contract size)
        0x60, 0x0a, // PUSH1 10 (Middle contract offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE (depth=0->1, Middle will CREATE Child at depth=1->2)
        
        // Store final result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Return result  
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // Simplified test - just try basic CREATE2 tracing
    try testor.test_bytecode(&bytecode);
}

test "tracer: simple CREATE2 basic tracing verification" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Very simple CREATE2 that should be traceable
    const bytecode = [_]u8{
        // Store minimal valid contract (just STOP)
        0x60, 0x00, // PUSH1 0 (STOP opcode)
        0x60, 0x00, // PUSH1 0 
        0x53,       // MSTORE8
        
        // CREATE2 with simple salt
        0x60, 0x01, // PUSH1 1 (salt)
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        
        // Return address
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}