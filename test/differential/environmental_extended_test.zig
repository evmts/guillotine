const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: BALANCE opcode basic functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BALANCE opcode with various addresses
    const bytecode = [_]u8{
        // Get balance of address 0 (usually empty)
        0x60, 0x00, // PUSH1 0 (address)
        0x31,       // BALANCE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Get balance of current contract (self)
        0x30,       // ADDRESS (get current address)
        0x31,       // BALANCE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Get balance of a well-known address (0x1)
        0x60, 0x01, // PUSH1 1
        0x31,       // BALANCE
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BALANCE with constructed addresses" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BALANCE with constructed 20-byte addresses
    const bytecode = [_]u8{
        // Construct address: 0x1234567890123456789012345678901234567890
        0x73, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56,
        0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34,
        0x56, 0x78, 0x90, 0x12, // PUSH20 constructed address
        0x31,       // BALANCE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Test with max address (0xFFFF...FFFF)
        0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH32 with address in last 20 bytes
        0x31,       // BALANCE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: GASPRICE opcode functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test GASPRICE opcode
    const bytecode = [_]u8{
        // Get gas price
        0x3a,       // GASPRICE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Use gas price in calculation
        0x3a,       // GASPRICE
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL (gas_price * 2)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Compare gas price with itself
        0x3a,       // GASPRICE
        0x3a,       // GASPRICE
        0x14,       // EQ (should be 1)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOCKHASH opcode functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BLOCKHASH opcode with various block numbers
    const bytecode = [_]u8{
        // Get hash of block 0 (genesis block)
        0x60, 0x00, // PUSH1 0
        0x40,       // BLOCKHASH
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Get current block number and try to get its hash (should return 0)
        0x43,       // NUMBER (current block number)
        0x40,       // BLOCKHASH (should return 0 for current block)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Get hash of block 1
        0x60, 0x01, // PUSH1 1
        0x40,       // BLOCKHASH
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOCKHASH with block number calculations" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test BLOCKHASH with calculated block numbers
    const bytecode = [_]u8{
        // Calculate: current_block - 1
        0x43,       // NUMBER (current block)
        0x60, 0x01, // PUSH1 1
        0x03,       // SUB (current - 1)
        0x40,       // BLOCKHASH (hash of previous block)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Calculate: current_block - 256 (should be 0 as it's too old)
        0x43,       // NUMBER (current block)
        0x61, 0x01, 0x00, // PUSH2 256
        0x03,       // SUB (current - 256)
        0x40,       // BLOCKHASH (should return 0 for blocks > 256 ago)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Try with a future block number (current + 10)
        0x43,       // NUMBER (current block)
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD (current + 10)
        0x40,       // BLOCKHASH (should return 0 for future blocks)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: COINBASE opcode functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test COINBASE opcode
    const bytecode = [_]u8{
        // Get coinbase address
        0x41,       // COINBASE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Use coinbase address to get its balance
        0x41,       // COINBASE
        0x31,       // BALANCE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Compare coinbase with itself
        0x41,       // COINBASE
        0x41,       // COINBASE
        0x14,       // EQ (should be 1)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: DIFFICULTY opcode functionality" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test DIFFICULTY opcode (PREVRANDAO in post-merge Ethereum)
    const bytecode = [_]u8{
        // Get difficulty/prevrandao
        0x44,       // DIFFICULTY
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Compare with PREVRANDAO (should be same post-merge)
        0x44,       // DIFFICULTY
        0x44,       // DIFFICULTY (get again)
        0x14,       // EQ (should be 1)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Use in arithmetic operation
        0x44,       // DIFFICULTY
        0x60, 0x02, // PUSH1 2
        0x06,       // MOD (difficulty % 2)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: combined environmental opcodes" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test combinations of environmental opcodes
    const bytecode = [_]u8{
        // Get coinbase balance using COINBASE + BALANCE
        0x41,       // COINBASE
        0x31,       // BALANCE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Calculate gas cost: GASPRICE * 21000 (basic tx cost)
        0x3a,       // GASPRICE
        0x61, 0x52, 0x08, // PUSH2 21000
        0x02,       // MUL
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Check if current block is genesis: NUMBER == 0
        0x43,       // NUMBER
        0x15,       // ISZERO
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Get self balance
        0x30,       // ADDRESS
        0x31,       // BALANCE
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x80, // PUSH1 128
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}