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
    
    try testor.test_differential("ADDRESS", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("BALANCE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("ORIGIN", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("CALLER", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("CALLVALUE", &bytecode, &[_]u8{});
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
    
    // Provide some calldata
    const calldata = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34, 0x56 };
    
    try testor.test_differential("CALLDATALOAD", &bytecode, &calldata);
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
    
    const calldata = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc };
    
    try testor.test_differential("CALLDATASIZE", &bytecode, &calldata);
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
    
    const calldata = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc };
    
    try testor.test_differential("CALLDATACOPY", &bytecode, &calldata);
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
    
    try testor.test_differential("CODESIZE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("CODECOPY", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("GASPRICE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("EXTCODESIZE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("EXTCODECOPY", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("EXTCODEHASH", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("RETURNDATASIZE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("RETURNDATACOPY", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("BLOCKHASH", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("COINBASE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("TIMESTAMP", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("NUMBER", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("DIFFICULTY/PREVRANDAO", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("GASLIMIT", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("CHAINID", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("SELFBALANCE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("BASEFEE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("BLOBHASH", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("BLOBBASEFEE", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("GAS", &bytecode, &[_]u8{});
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
    
    try testor.test_differential("PC", &bytecode, &[_]u8{});
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
    
    const calldata = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    
    try testor.test_differential("context combined", &bytecode, &calldata);
}