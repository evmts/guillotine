//! Comprehensive tests for EIP-4844 (Shard blob transactions)

const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

const Evm = @import("evm").Evm;
const DatabaseInterface = @import("evm").DatabaseInterface;
const MemoryDatabase = @import("evm").MemoryDatabase;
const BlockInfo = @import("evm").BlockInfo;
const TransactionContext = @import("evm").TransactionContext;
const Hardfork = @import("evm").Hardfork;
const FrameInterpreter = @import("evm").FrameInterpreter;

// Test BLOBHASH opcode with various indices
test "EIP-4844 - BLOBHASH opcode with multiple blobs" {
    const allocator = testing.allocator;
    
    // Create bytecode that tests BLOBHASH with different indices
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x49,       // BLOBHASH
        0x60, 0x01, // PUSH1 1
        0x49,       // BLOBHASH
        0x60, 0x02, // PUSH1 2
        0x49,       // BLOBHASH
        0x60, 0xFF, // PUSH1 255
        0x49,       // BLOBHASH
        0x00,       // STOP
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create unique blob hashes
    var blob_hashes: [6][32]u8 = undefined;
    for (0..6) |i| {
        for (0..32) |j| {
            blob_hashes[i][j] = @as(u8, @intCast((i * 32 + j) % 256));
        }
    }
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    const initial_gas = 100_000;
    var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
        allocator,
        &bytecode,
        initial_gas,
        db_interface,
        evm.to_host()
    );
    defer interpreter.deinit(allocator);
    
    try interpreter.interpret();
    
    // Stack should have 4 values: blob[255] (0), blob[2], blob[1], blob[0]
    try testing.expectEqual(@as(usize, 4), interpreter.frame.stack.size());
}

// Test BLOBHASH with no blobs
test "EIP-4844 - BLOBHASH with no blob hashes returns zero" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x49,       // BLOBHASH
        0x00,       // STOP
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        // No blob hashes
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    const initial_gas = 100_000;
    var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
        allocator,
        &bytecode,
        initial_gas,
        db_interface,
        evm.to_host()
    );
    defer interpreter.deinit(allocator);
    
    try interpreter.interpret();
    
    // Should push 0 for out-of-bounds access
    try testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());
}

// Test BLOBBASEFEE opcode
test "EIP-4844 - BLOBBASEFEE opcode returns correct fee" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x4a, // BLOBBASEFEE
        0x00, // STOP
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const expected_blob_base_fee: u256 = 123_456_789_123_456_789;
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_base_fee = expected_blob_base_fee,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    const initial_gas = 100_000;
    var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
        allocator,
        &bytecode,
        initial_gas,
        db_interface,
        evm.to_host()
    );
    defer interpreter.deinit(allocator);
    
    try interpreter.interpret();
    
    try testing.expectEqual(expected_blob_base_fee, interpreter.frame.stack.peek_unsafe());
}

// Test maximum blob count (current limit is 6 blobs per block)
test "EIP-4844 - Maximum blob count handling" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create maximum allowed blobs (6)
    const max_blobs = 6;
    var blob_hashes: [max_blobs][32]u8 = undefined;
    for (0..max_blobs) |i| {
        // Create versioned hash with proper format (version byte 0x01 for KZG)
        blob_hashes[i][0] = 0x01; // KZG commitment version
        for (1..32) |j| {
            blob_hashes[i][j] = @as(u8, @intCast((i + j) % 256));
        }
    }
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Access all blobs
    for (0..max_blobs) |i| {
        const hash_opt = evm.get_blob_hash(i);
        try testing.expect(hash_opt != null);
        try testing.expectEqual(blob_hashes[i], hash_opt.?);
        try testing.expectEqual(@as(u8, 0x01), hash_opt.?[0]); // Version byte
    }
    
    // Access beyond limit returns null
    const beyond_limit = evm.get_blob_hash(max_blobs);
    try testing.expect(beyond_limit == null);
}

// Test blob base fee edge cases
test "EIP-4844 - Blob base fee edge cases" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    
    // Test zero blob base fee
    {
        const context = TransactionContext{
            .gas_limit = 1_000_000,
            .coinbase = ZERO_ADDRESS,
            .chain_id = 1,
            .blob_base_fee = 0,
        };
        
        var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
        defer evm.deinit();
        
        try testing.expectEqual(@as(u256, 0), evm.get_blob_base_fee());
    }
    
    // Test maximum blob base fee
    {
        const context = TransactionContext{
            .gas_limit = 1_000_000,
            .coinbase = ZERO_ADDRESS,
            .chain_id = 1,
            .blob_base_fee = std.math.maxInt(u256),
        };
        
        var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
        defer evm.deinit();
        
        try testing.expectEqual(std.math.maxInt(u256), evm.get_blob_base_fee());
    }
}

// Test pre-Cancun behavior (opcodes should fail)
test "EIP-4844 - Pre-Cancun hardforks reject blob opcodes" {
    const allocator = testing.allocator;
    
    const bytecode_blobhash = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x49,       // BLOBHASH
        0x00,       // STOP
    };
    
    const bytecode_blobbasefee = [_]u8{
        0x4a, // BLOBBASEFEE
        0x00, // STOP
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Test with Shanghai (pre-Cancun)
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // BLOBHASH should fail
    {
        var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
            allocator,
            &bytecode_blobhash,
            100_000,
            db_interface,
            evm.to_host()
        );
        defer interpreter.deinit(allocator);
        
        const result = interpreter.interpret();
        try testing.expectError(error.InvalidOpcode, result);
    }
    
    // BLOBBASEFEE should fail
    {
        var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
            allocator,
            &bytecode_blobbasefee,
            100_000,
            db_interface,
            evm.to_host()
        );
        defer interpreter.deinit(allocator);
        
        const result = interpreter.interpret();
        try testing.expectError(error.InvalidOpcode, result);
    }
}

// Test BLOBHASH with very large indices
test "EIP-4844 - BLOBHASH with large indices" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const blob_hash = [_]u8{0xAB} ** 32;
    const blob_hashes = [_][32]u8{blob_hash};
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Test various large indices
    const test_indices = [_]u256{
        1,                              // Just out of bounds
        100,                            // Well out of bounds
        std.math.maxInt(u64),          // Max u64
        std.math.maxInt(u128),         // Max u128
        std.math.maxInt(u256),         // Max u256
    };
    
    for (test_indices) |index| {
        const result = evm.get_blob_hash(index);
        try testing.expect(result == null);
    }
}

// Test blob transaction with contract execution
test "EIP-4844 - Blob context available during contract execution" {
    const allocator = testing.allocator;
    
    // Contract that reads blob data and stores results
    // BLOBBASEFEE, PUSH1 0, SSTORE (store blob base fee at slot 0)
    // PUSH1 0, BLOBHASH, PUSH1 1, SSTORE (store first blob hash at slot 1)
    const contract_code = [_]u8{
        0x4a,       // BLOBBASEFEE
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        0x60, 0x00, // PUSH1 0
        0x49,       // BLOBHASH
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE
        0x00,       // STOP
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const contract_address = [_]u8{0x42} ** 20;
    const blob_hash = [_]u8{0x01} ++ [_]u8{0xEF} ** 31; // Versioned hash
    const blob_hashes = [_][32]u8{blob_hash};
    const blob_base_fee: u256 = 7_777_777_777;
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = blob_base_fee,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, contract_address, Hardfork.CANCUN);
    defer evm.deinit();
    
    const initial_gas = 1_000_000;
    var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
        allocator,
        &contract_code,
        initial_gas,
        db_interface,
        evm.to_host()
    );
    defer interpreter.deinit(allocator);
    
    try interpreter.interpret();
    
    // Verify storage was updated with blob data
    const stored_base_fee = try memory_db.get_storage(contract_address, 0);
    try testing.expectEqual(blob_base_fee, stored_base_fee);
    
    // Convert blob hash to u256 for comparison
    var blob_hash_u256: u256 = 0;
    for (blob_hash) |byte| {
        blob_hash_u256 = (blob_hash_u256 << 8) | byte;
    }
    
    const stored_blob_hash = try memory_db.get_storage(contract_address, 1);
    try testing.expectEqual(blob_hash_u256, stored_blob_hash);
}