const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;
const Keccak256 = std.crypto.hash.sha3.Keccak256;

// MinimalEvm's CREATE and CREATE2 push 0 without running init code, so these
// tests assert Guillotine against addresses derived from the specification.
// The harness runs code at 0xc0de00..00 with account nonce 1.
const creator = [_]u8{ 0xc0, 0xde } ++ @as([18]u8, @splat(0));
const zero_word: [32]u8 = @splat(0);

/// CREATE address: keccak256(rlp([creator, nonce]))[12..], for 1 <= nonce <= 0x7f.
fn createAddress(nonce: u8) [20]u8 {
    const rlp = [_]u8{ 0xd6, 0x94 } ++ creator ++ [_]u8{nonce};
    var hash: [32]u8 = undefined;
    Keccak256.hash(&rlp, &hash, .{});
    return hash[12..32].*;
}

/// CREATE2 address (EIP-1014): keccak256(0xff ++ creator ++ salt ++ keccak256(init_code))[12..].
fn create2Address(salt: [32]u8, init_code: []const u8) [20]u8 {
    var code_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &code_hash, .{});
    const preimage = [_]u8{0xff} ++ creator ++ salt ++ code_hash;
    var hash: [32]u8 = undefined;
    Keccak256.hash(&preimage, &hash, .{});
    return hash[12..32].*;
}

fn word(address: [20]u8) [32]u8 {
    return @as([12]u8, @splat(0)) ++ address;
}

test "differential: CREATE with insufficient gas" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE with insufficient gas to deploy contract
    const bytecode = [_]u8{
        // Store minimal valid contract code (just STOP)
        0x60, 0x00, // PUSH1 0x00 (STOP opcode)
        0x60, 0x00, // PUSH1 0
        0x53,       // MSTORE8 (store at memory[0])
        
        // CREATE parameters: value, offset, size
        0x60, 0x01, // PUSH1 1 (size - 1 byte contract)
        0x60, 0x00, // PUSH1 0 (offset in memory)  
        0x60, 0x00, // PUSH1 0 (value - no ether)
        
        // Get remaining gas and use almost all of it
        0x5a,       // GAS (get remaining gas)
        0x61, 0x27, 0x10, // PUSH2 10000 (subtract large amount)
        0x03,       // SUB (remaining_gas - 10000)
        0x60, 0x64, // PUSH1 100 (leave only 100 gas units)
        0x03,       // SUB (should leave insufficient gas)
        0x50,       // POP (remove from stack for CREATE)
        
        // Use very little gas for CREATE (should fail)
        0x5a,       // GAS (get remaining gas)
        0x60, 0x64, // PUSH1 100 (very low gas limit)
        0x11,       // GT (check if remaining > 100)
        0x60, 0x16, // PUSH1 22 (jump destination)
        0x57,       // JUMPI (skip CREATE if not enough gas)
        
        // If we have enough gas, try CREATE with minimal gas
        0x60, 0x64, // PUSH1 100 (very low gas for CREATE)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x01, // PUSH1 1 (size)
        // Note: We can't directly limit gas to CREATE, so we'll create normally
        
        0x5b,       // JUMPDEST (offset 22)
        0xf0,       // CREATE (attempt to create contract)
        
        // Store result (should be 0 if failed, address if succeeded)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Check remaining gas
        0x5a,       // GAS
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    try testor.test_bytecode(&bytecode);
}

test "differential: CREATE with invalid bytecode" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE with invalid/malformed bytecode
    const bytecode = [_]u8{
        // Store init code 0x7f 0xff: a PUSH32 truncated by the end of code
        0x60, 0x7f, // PUSH1 0x7f (PUSH32 opcode)
        0x60, 0x00, // PUSH1 0
        0x53,       // MSTORE8 (store 0x7f at memory[0])
        0x60, 0xff, // PUSH1 0xff
        0x60, 0x01, // PUSH1 1
        0x53,       // MSTORE8 (store 0xff at memory[1])
        
        // CREATE with invalid bytecode
        0x60, 0x02, // PUSH1 2 (size - incomplete PUSH32 instruction)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE (should handle invalid bytecode gracefully)
        
        // Store result address (0 if failed)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Return result
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // The truncated PUSH32 reads zero bytes past the end of the init code and
    // execution then stops, so CREATE deploys empty code and returns the address.
    const expected = word(createAddress(1));
    try testor.expect_guillotine(&bytecode, &.{}, true, &expected);
}

test "differential: CREATE2 with invalid salt" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE2 with various salt values
    const bytecode = [_]u8{
        // Store simple contract code (PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN)
        0x60, 0x60, 0x60, 0x00, 0x53, // PUSH1 PUSH1 at memory[0-1]
        0x60, 0x2a, 0x60, 0x01, 0x53, // 42 at memory[1]
        0x60, 0x60, 0x60, 0x02, 0x53, // PUSH1 at memory[2]
        0x60, 0x00, 0x60, 0x03, 0x53, // 0 at memory[3]
        0x60, 0x52, 0x60, 0x04, 0x53, // MSTORE at memory[4]
        0x60, 0x60, 0x60, 0x05, 0x53, // PUSH1 at memory[5]
        0x60, 0x20, 0x60, 0x06, 0x53, // 32 at memory[6]
        0x60, 0x60, 0x60, 0x07, 0x53, // PUSH1 at memory[7]
        0x60, 0x00, 0x60, 0x08, 0x53, // 0 at memory[8]
        0x60, 0xf3, 0x60, 0x09, 0x53, // RETURN at memory[9]
        
        // CREATE2 with salt = 0
        0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 salt=0
        0x60, 0x0a, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        
        // Store first result
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // CREATE2 with same salt (should fail - address already exists)
        0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 salt=0 (same)
        0x60, 0x0a, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2 (should fail - duplicate address)
        
        // Store second result (should be 0)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // The first CREATE2 deploys; the second collides with it and pushes 0.
    // Memory word 0 still holds the 10-byte init code.
    const init_code = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const expected = (init_code ++ @as([22]u8, @splat(0))) ++ word(create2Address(zero_word, &init_code)) ++ zero_word;
    try testor.expect_guillotine(&bytecode, &.{}, true, &expected);
}

test "differential: CREATE2 with maximum salt value" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE2 with maximum salt value (all 0xFF)
    const bytecode = [_]u8{
        // Store minimal contract code (just STOP)
        0x60, 0x00, // PUSH1 0 (STOP)
        0x60, 0x00, // PUSH1 0
        0x53,       // MSTORE8
        
        // CREATE2 with max salt
        0x7f, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH32 max salt
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Return result
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const expected = word(create2Address(@splat(0xff), &[_]u8{0x00}));
    try testor.expect_guillotine(&bytecode, &.{}, true, &expected);
}

test "differential: CREATE with zero-length bytecode" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE with zero-length bytecode (empty contract)
    const bytecode = [_]u8{
        // CREATE with zero size (empty contract)
        0x60, 0x00, // PUSH1 0 (size - empty contract)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE (create empty contract)
        
        // Store result address
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Check if the created contract has any code
        0x60, 0x00, // PUSH1 0 (reload created address)
        0x51,       // MLOAD
        0x3b,       // EXTCODESIZE (get code size of created contract)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x40, // PUSH1 64
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // Empty init code deploys an account with no code.
    const expected = word(createAddress(1)) ++ zero_word;
    try testor.expect_guillotine(&bytecode, &.{}, true, &expected);
}

test "differential: CREATE with contract that immediately self-destructs" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE with contract that self-destructs during construction
    const bytecode = [_]u8{
        // Store contract code that self-destructs immediately
        // Code: PUSH1 0 (beneficiary), SELFDESTRUCT
        0x60, 0x60, 0x60, 0x00, 0x53, // PUSH1 opcode at memory[0]
        0x60, 0x00, 0x60, 0x01, 0x53, // 0 (beneficiary) at memory[1]  
        0x60, 0xff, 0x60, 0x02, 0x53, // SELFDESTRUCT opcode at memory[2]
        
        // CREATE the self-destructing contract
        0x60, 0x03, // PUSH1 3 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        
        // Store result address (might be 0 if self-destruct prevents creation)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Check if contract still exists by getting its code size
        0x60, 0x00, // PUSH1 0 (reload address)
        0x51,       // MLOAD
        0x3b,       // EXTCODESIZE
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Check if address was created at all
        0x60, 0x00, // PUSH1 0 (reload address)  
        0x51,       // MLOAD
        0x15,       // ISZERO (check if address is zero)
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Return results
        0x60, 0x60, // PUSH1 96
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // CREATE succeeds; the init code returns no code, so EXTCODESIZE is 0 and
    // ISZERO(address) is 0.
    const expected = word(createAddress(1)) ++ zero_word ++ zero_word;
    try testor.expect_guillotine(&bytecode, &.{}, true, &expected);
}

test "differential: CREATE with maximum size contract" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Test CREATE with large contract (testing size limits)
    const bytecode = [_]u8{
        // Fill memory with a pattern for a larger contract
        // This creates a contract of ~100 bytes of repeated PUSH1 0 POP instructions
        0x60, 0x00, // PUSH1 0 (will be used in loop)
        
        // Create a loop to fill memory with PUSH1 0, POP pattern (0x60, 0x00, 0x50)
        0x60, 0x00, // PUSH1 0 (counter)
        0x5b,       // JUMPDEST (loop start at offset 6)
        
        // Store PUSH1 opcode (0x60)
        0x80,       // DUP1 (duplicate counter)
        0x60, 0x60, // PUSH1 0x60 (PUSH1 opcode)
        0x82,       // DUP3 (get counter)
        0x60, 0x03, // PUSH1 3
        0x02,       // MUL (counter * 3 for offset)
        0x53,       // MSTORE8
        
        // Store 0x00 (argument for PUSH1)
        0x80,       // DUP1 (counter)
        0x60, 0x00, // PUSH1 0x00
        0x82,       // DUP3 (get counter)  
        0x60, 0x03, // PUSH1 3
        0x02,       // MUL (counter * 3)
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (offset + 1)
        0x53,       // MSTORE8
        
        // Store POP opcode (0x50)
        0x80,       // DUP1 (counter)
        0x60, 0x50, // PUSH1 0x50 (POP opcode)
        0x82,       // DUP3 (get counter)
        0x60, 0x03, // PUSH1 3  
        0x02,       // MUL (counter * 3)
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD (offset + 2)
        0x53,       // MSTORE8
        
        // Increment counter and loop
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (counter++)
        0x80,       // DUP1 (duplicate counter)
        0x60, 0x20, // PUSH1 32 (loop limit)
        0x10,       // LT (counter < 32)
        0x60, 0x06, // PUSH1 6 (jump back to loop start)
        0x57,       // JUMPI
        
        // Clean up stack
        0x50,       // POP (remove counter)
        0x50,       // POP (remove initial 0)
        
        // CREATE with the generated bytecode
        0x60, 0x60, // PUSH1 96 (size - 32 * 3 = 96 bytes)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        
        // Store result
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Return result
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // The init code (PUSH1 0, POP, then zero bytes) stops with empty output.
    const expected = word(createAddress(1));
    try testor.expect_guillotine(&bytecode, &.{}, true, &expected);
}