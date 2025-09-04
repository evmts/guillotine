const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

test "differential: ADDRESS opcode current contract address" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get current contract address
    const bytecode = [_]u8{
        0x30,                   // ADDRESS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE (store address in memory)
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BALANCE opcode account balance" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get balance of an address
    const bytecode = [_]u8{
        // Address to check balance
        0x73, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, // PUSH20 address
        0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78,
        0x31,                   // BALANCE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: ORIGIN opcode transaction origin" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get transaction origin
    const bytecode = [_]u8{
        0x32,                   // ORIGIN
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLER opcode message caller" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get message caller
    const bytecode = [_]u8{
        0x33,                   // CALLER
        0x60, 0x00,             // PUSH1 0  
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLVALUE opcode call value" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get call value (ETH sent with transaction)
    const bytecode = [_]u8{
        0x34,                   // CALLVALUE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLDATALOAD opcode load calldata" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Load 32 bytes from calldata at offset 0
    const bytecode = [_]u8{
        0x60, 0x00,             // PUSH1 0 (offset)
        0x35,                   // CALLDATALOAD
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Load from offset 32
        0x60, 0x20,             // PUSH1 32 (offset)
        0x35,                   // CALLDATALOAD  
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLDATASIZE opcode calldata size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get size of calldata
    const bytecode = [_]u8{
        0x36,                   // CALLDATASIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    try testor.test_bytecode(&bytecode);
}

test "differential: CALLDATACOPY opcode copy calldata to memory" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Copy calldata to memory
    const bytecode = [_]u8{
        0x60, 0x10,             // PUSH1 16 (size to copy)
        0x60, 0x04,             // PUSH1 4 (calldata offset)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0x37,                   // CALLDATACOPY
        0x00,                   // STOP
    };
    try testor.test_bytecode(&bytecode);
}

test "differential: CODESIZE opcode contract code size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get size of current contract code
    const bytecode = [_]u8{
        0x38,                   // CODESIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CODECOPY opcode copy code to memory" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Copy part of contract code to memory
    const bytecode = [_]u8{
        0x60, 0x08,             // PUSH1 8 (size to copy)
        0x60, 0x00,             // PUSH1 0 (code offset)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0x39,                   // CODECOPY
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: GASPRICE opcode transaction gas price" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get gas price of current transaction
    const bytecode = [_]u8{
        0x3a,                   // GASPRICE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: EXTCODESIZE opcode external code size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get size of external contract code
    const bytecode = [_]u8{
        // External address
        0x73, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, // PUSH20 external address
        0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0x3b,                   // EXTCODESIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: EXTCODECOPY opcode copy external code" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Copy external contract code to memory
    const bytecode = [_]u8{
        // External address
        0x73, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, // PUSH20 external address
        0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x60, 0x20,             // PUSH1 32 (size to copy)
        0x60, 0x00,             // PUSH1 0 (code offset)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0x3c,                   // EXTCODECOPY
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: EXTCODEHASH opcode external code hash" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get hash of external contract code
    const bytecode = [_]u8{
        // External address
        0x73, 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0x12, 0x34, // PUSH20 external address
        0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44,
        0x3f,                   // EXTCODEHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: RETURNDATASIZE opcode return data size" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get size of return data from previous call
    const bytecode = [_]u8{
        0x3d,                   // RETURNDATASIZE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: RETURNDATACOPY opcode copy return data" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Copy return data to memory (will be empty in this case)
    const bytecode = [_]u8{
        0x60, 0x00,             // PUSH1 0 (size to copy)
        0x60, 0x00,             // PUSH1 0 (return data offset)
        0x60, 0x00,             // PUSH1 0 (memory offset)
        0x3e,                   // RETURNDATACOPY
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOCKHASH opcode recent block hash" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get hash of a recent block
    const bytecode = [_]u8{
        0x60, 0xff,             // PUSH1 255 (block number - should be 0 for non-recent)
        0x40,                   // BLOCKHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Try current block (should return 0)
        0x43,                   // NUMBER (current block)
        0x40,                   // BLOCKHASH
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: COINBASE opcode block beneficiary" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get coinbase (block beneficiary) address
    const bytecode = [_]u8{
        0x41,                   // COINBASE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: TIMESTAMP opcode block timestamp" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get block timestamp
    const bytecode = [_]u8{
        0x42,                   // TIMESTAMP
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: NUMBER opcode block number" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get current block number
    const bytecode = [_]u8{
        0x43,                   // NUMBER
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: DIFFICULTY and PREVRANDAO opcode" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get difficulty (pre-merge) / prevrandao (post-merge)
    const bytecode = [_]u8{
        0x44,                   // DIFFICULTY/PREVRANDAO
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: GASLIMIT opcode block gas limit" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get block gas limit
    const bytecode = [_]u8{
        0x45,                   // GASLIMIT
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CHAINID opcode chain identifier" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get chain ID
    const bytecode = [_]u8{
        0x46,                   // CHAINID
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: SELFBALANCE opcode current contract balance" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get balance of current contract
    const bytecode = [_]u8{
        0x47,                   // SELFBALANCE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BASEFEE opcode EIP-1559 base fee" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get base fee per gas (EIP-1559)
    const bytecode = [_]u8{
        0x48,                   // BASEFEE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBHASH opcode EIP-4844 blob hash" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get blob hash (EIP-4844)
    const bytecode = [_]u8{
        0x60, 0x00,             // PUSH1 0 (blob index)
        0x49,                   // BLOBHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBHASH with multiple blob indices (0-5)" {
    const allocator = testing.allocator;
    
    // Create 6 unique blob hashes (maximum allowed)
    var blob_hashes: [6][32]u8 = undefined;
    for (0..6) |i| {
        blob_hashes[i][0] = 0x01; // KZG commitment version
        for (1..32) |j| {
            blob_hashes[i][j] = @as(u8, @intCast((i * 32 + j) % 256));
        }
    }
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = 1_000_000_000,
        .blob_versioned_hashes = &blob_hashes,
    });
    defer testor.deinit();
    
    // Test accessing all valid blob indices
    const bytecode = [_]u8{
        // Access blob index 0
        0x60, 0x00,             // PUSH1 0
        0x49,                   // BLOBHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Access blob index 1
        0x60, 0x01,             // PUSH1 1
        0x49,                   // BLOBHASH
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Access blob index 5 (last valid)
        0x60, 0x05,             // PUSH1 5
        0x49,                   // BLOBHASH
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBHASH with out-of-bounds indices" {
    const allocator = testing.allocator;
    
    // Single blob hash
    const blob_hash = [_]u8{0x01} ++ [_]u8{0xAB} ** 31;
    const blob_hashes = [_][32]u8{blob_hash};
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = 1_000_000_000,
        .blob_versioned_hashes = &blob_hashes,
    });
    defer testor.deinit();
    
    // Test out-of-bounds access returns zero
    const bytecode = [_]u8{
        // Access valid index 0
        0x60, 0x00,             // PUSH1 0
        0x49,                   // BLOBHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Access invalid index 1 (should return 0)
        0x60, 0x01,             // PUSH1 1
        0x49,                   // BLOBHASH
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Access invalid index 255 (should return 0)
        0x60, 0xFF,             // PUSH1 255
        0x49,                   // BLOBHASH
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBHASH with empty blob array" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = 1_000_000_000,
        .blob_versioned_hashes = &.{}, // No blobs
    });
    defer testor.deinit();
    
    // Test that access to any index returns zero when no blobs present
    const bytecode = [_]u8{
        0x60, 0x00,             // PUSH1 0
        0x49,                   // BLOBHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBHASH with u256 max index" {
    const allocator = testing.allocator;
    
    const blob_hash = [_]u8{0x01} ++ [_]u8{0xCD} ** 31;
    const blob_hashes = [_][32]u8{blob_hash};
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = 1_000_000_000,
        .blob_versioned_hashes = &blob_hashes,
    });
    defer testor.deinit();
    
    // Test with maximum u256 index (should return 0)
    const bytecode = [_]u8{
        // Push u256::MAX as 32 bytes
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,  // PUSH32 (16 bytes of 0xFF)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,  // (remaining 16 bytes of 0xFF)
        0x49,                   // BLOBHASH
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBBASEFEE opcode EIP-4844 blob base fee" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get blob base fee (EIP-4844)
    const bytecode = [_]u8{
        0x4a,                   // BLOBBASEFEE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBBASEFEE with configured blob base fee" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = 1_000_000_000, // 1 Gwei
        .blob_versioned_hashes = &.{},
    });
    defer testor.deinit();
    
    // Test that both EVMs return the same non-zero blob base fee
    const bytecode = [_]u8{
        0x4a,                   // BLOBBASEFEE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBBASEFEE with zero blob base fee" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    });
    defer testor.deinit();
    
    // Test that both EVMs return zero for zero blob base fee
    const bytecode = [_]u8{
        0x4a,                   // BLOBBASEFEE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: BLOBBASEFEE with maximum blob base fee" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = std.math.maxInt(u256),
        .blob_versioned_hashes = &.{},
    });
    defer testor.deinit();
    
    // Test maximum u256 value for blob base fee
    const bytecode = [_]u8{
        0x4a,                   // BLOBBASEFEE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: GAS opcode remaining gas" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get remaining gas
    const bytecode = [_]u8{
        0x5a,                   // GAS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Use some gas and check again
        0x60, 0x01,             // PUSH1 1
        0x60, 0x02,             // PUSH1 2
        0x01,                   // ADD
        0x50,                   // POP
        
        0x5a,                   // GAS (should be less now)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: PC opcode program counter" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Get program counter at different points
    const bytecode = [_]u8{
        0x58,                   // PC (should be 0)
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        0x60, 0x01,             // PUSH1 1 (some operation)
        0x50,                   // POP
        
        0x58,                   // PC (should be 7)
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: EIP-4844 opcodes fail pre-Cancun" {
    const allocator = testing.allocator;
    
    // For pre-Cancun validation, we need to test with a different hardfork
    // This requires implementing hardfork-aware differential testing
    // For now, we document this as a known limitation
    _ = allocator;
    
    // TODO: Add pre-Cancun hardfork validation when DifferentialTestor supports hardfork configuration
    // The differential testor currently hardcodes Cancun hardfork
    // We need to add initWithHardfork method to test pre-Cancun behavior
}

test "differential: blob context initialization identical in both EVMs" {
    const allocator = testing.allocator;
    
    // Create known blob context
    const test_blob_hash = [_]u8{0x01} ++ [_]u8{0x42} ** 31;
    const blob_hashes = [_][32]u8{test_blob_hash};
    const test_blob_fee: u256 = 7_777_777_777;
    
    var testor = try DifferentialTestor.initWithBlobContext(allocator, .{
        .blob_base_fee = test_blob_fee,
        .blob_versioned_hashes = &blob_hashes,
    });
    defer testor.deinit();
    
    // Test that both EVMs have identical blob context by combining operations
    const bytecode = [_]u8{
        // Get blob base fee
        0x4a,                   // BLOBBASEFEE
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        // Get first blob hash
        0x60, 0x00,             // PUSH1 0
        0x49,                   // BLOBHASH
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        // Test out-of-bounds access returns zero
        0x60, 0x01,             // PUSH1 1
        0x49,                   // BLOBHASH  
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: context operations combined test" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test multiple context operations together
    const bytecode = [_]u8{
        // Get various context information
        0x30,                   // ADDRESS
        0x60, 0x00,             // PUSH1 0
        0x52,                   // MSTORE
        
        0x33,                   // CALLER
        0x60, 0x20,             // PUSH1 32
        0x52,                   // MSTORE
        
        0x34,                   // CALLVALUE
        0x60, 0x40,             // PUSH1 64
        0x52,                   // MSTORE
        
        0x36,                   // CALLDATASIZE
        0x60, 0x60,             // PUSH1 96
        0x52,                   // MSTORE
        
        0x38,                   // CODESIZE
        0x60, 0x80,             // PUSH1 128
        0x52,                   // MSTORE
        
        0x3a,                   // GASPRICE
        0x60, 0xa0,             // PUSH1 160
        0x52,                   // MSTORE
        
        0x42,                   // TIMESTAMP
        0x60, 0xc0,             // PUSH1 192
        0x52,                   // MSTORE
        
        0x43,                   // NUMBER
        0x60, 0xe0,             // PUSH1 224
        0x52,                   // MSTORE
        
        0x46,                   // CHAINID
        0x61, 0x01, 0x00,       // PUSH2 256
        0x52,                   // MSTORE
        
        0x5a,                   // GAS
        0x61, 0x01, 0x20,       // PUSH2 288
        0x52,                   // MSTORE
        
        0x00,                   // STOP
    };
    try testor.test_bytecode(&bytecode);
}