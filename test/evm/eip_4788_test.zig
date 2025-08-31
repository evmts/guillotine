// EIP-4788: Beacon block root in EVM
// This EIP exposes the beacon chain's block root in the EVM for trust-minimized access to consensus layer
const std = @import("std");
const testing = std.testing;
const evm = @import("../../src/evm/root.zig");
const primitives = @import("../../src/primitives/root.zig");

test "EIP-4788: beacon block root precompile at 0x0B" {
    const allocator = testing.allocator;
    
    // Setup
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // EIP-4788 specifies precompile at address 0x0B
    const beacon_root_precompile = primitives.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x0B} };
    
    // Set up block info with beacon root
    const expected_beacon_root = [32]u8{
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
    };
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 19426587, // Dencun activation block on mainnet
        .timestamp = 1710338135,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1,
        .blob_versioned_hashes = &.{},
        .beacon_root = expected_beacon_root,
    };
    
    // Create transaction context
    const tx_context = evm.TransactionContext{
        .gas_price = 10000000000,
        .origin = primitives.ZERO_ADDRESS,
        .block_info = &block_info,
        .is_static = false,
    };
    
    // Create EVM instance
    var evm_instance = try evm.Evm.init(
        allocator,
        &database,
        tx_context,
        1_000_000, // gas limit
    );
    defer evm_instance.deinit();
    
    // Call the beacon root precompile with timestamp as input
    const timestamp_bytes = std.mem.toBytes(block_info.timestamp);
    const call_params = evm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = beacon_root_precompile,
            .value = 0,
            .input = &timestamp_bytes,
            .gas = 100_000,
        },
    };
    
    const result = try evm_instance.inner_call(call_params);
    
    // Verify the precompile returns the beacon root
    try testing.expect(result.success);
    try testing.expectEqualSlices(u8, &expected_beacon_root, result.output);
}

test "EIP-4788: beacon roots ring buffer storage" {
    const allocator = testing.allocator;
    
    // Setup
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // EIP-4788 uses a ring buffer in storage with HISTORY_BUFFER_LENGTH = 8191
    const HISTORY_BUFFER_LENGTH = 8191;
    const beacon_roots_address = primitives.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x0B} };
    
    // Simulate storing beacon roots for multiple blocks
    const timestamps = [_]u64{ 1000, 2000, 3000, 8192000, 8193000 };
    const beacon_roots = [_][32]u8{
        [_]u8{0x01} ** 32,
        [_]u8{0x02} ** 32,
        [_]u8{0x03} ** 32,
        [_]u8{0x04} ** 32,
        [_]u8{0x05} ** 32,
    };
    
    // Store beacon roots in ring buffer
    for (timestamps, beacon_roots) |timestamp, root| {
        // Calculate storage slot for timestamp (slot = timestamp % HISTORY_BUFFER_LENGTH)
        const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
        
        // Store timestamp -> root mapping
        const timestamp_key = std.mem.asBytes(&timestamp_slot);
        var key: [32]u8 = [_]u8{0} ** 32;
        @memcpy(key[24..32], timestamp_key);
        
        try database.set_storage(beacon_roots_address.bytes, @bitCast(key), @bitCast(root));
        
        // Store root -> timestamp mapping (at slot + HISTORY_BUFFER_LENGTH)
        const root_slot = timestamp_slot + HISTORY_BUFFER_LENGTH;
        const root_key_bytes = std.mem.asBytes(&root_slot);
        var root_key: [32]u8 = [_]u8{0} ** 32;
        @memcpy(root_key[24..32], root_key_bytes);
        
        const timestamp_value: u256 = timestamp;
        try database.set_storage(beacon_roots_address.bytes, @bitCast(root_key), timestamp_value);
    }
    
    // Verify we can retrieve beacon roots
    for (timestamps, beacon_roots) |timestamp, expected_root| {
        const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
        const timestamp_key = std.mem.asBytes(&timestamp_slot);
        var key: [32]u8 = [_]u8{0} ** 32;
        @memcpy(key[24..32], timestamp_key);
        
        const stored_root = try database.get_storage(beacon_roots_address.bytes, @bitCast(key));
        const stored_root_bytes: [32]u8 = @bitCast(stored_root);
        try testing.expectEqualSlices(u8, &expected_root, &stored_root_bytes);
    }
    
    // Verify wraparound works correctly
    const wraparound_timestamp: u64 = 8192000;
    const wraparound_slot = wraparound_timestamp % HISTORY_BUFFER_LENGTH;
    try testing.expectEqual(@as(u64, 1), wraparound_slot); // Should wrap to slot 1
}

test "EIP-4788: system call updates beacon root" {
    const allocator = testing.allocator;
    
    // Setup
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const beacon_roots_address = primitives.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x0B} };
    const system_address = primitives.Address{ .bytes = [_]u8{0xff} ** 20 }; // 0xffffff...
    
    const parent_beacon_root = [32]u8{0xAA} ** 32;
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 19426587,
        .timestamp = 1710338135,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1,
        .blob_versioned_hashes = &.{},
        .beacon_root = parent_beacon_root,
    };
    
    const tx_context = evm.TransactionContext{
        .gas_price = 10000000000,
        .origin = system_address, // System call from special address
        .block_info = &block_info,
        .is_static = false,
    };
    
    // Create EVM instance
    var evm_instance = try evm.Evm.init(
        allocator,
        &database,
        tx_context,
        1_000_000,
    );
    defer evm_instance.deinit();
    
    // Perform system call to update beacon root
    // Input: 32 bytes timestamp + 32 bytes beacon root
    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], block_info.timestamp, .big);
    @memcpy(input[32..64], &parent_beacon_root);
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = system_address,
            .to = beacon_roots_address,
            .value = 0,
            .input = &input,
            .gas = 100_000,
        },
    };
    
    const result = try evm_instance.inner_call(call_params);
    try testing.expect(result.success);
    
    // Verify beacon root was stored
    const HISTORY_BUFFER_LENGTH = 8191;
    const timestamp_slot = block_info.timestamp % HISTORY_BUFFER_LENGTH;
    const timestamp_key = std.mem.asBytes(&timestamp_slot);
    var key: [32]u8 = [_]u8{0} ** 32;
    @memcpy(key[24..32], timestamp_key);
    
    const stored_root = try database.get_storage(beacon_roots_address.bytes, @bitCast(key));
    const stored_root_bytes: [32]u8 = @bitCast(stored_root);
    try testing.expectEqualSlices(u8, &parent_beacon_root, &stored_root_bytes);
}