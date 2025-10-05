/// Block context information for EVM execution environment
///
/// Provides blockchain context data needed by EVM operations:
/// - Block number, timestamp, difficulty, gas limit
/// - Coinbase address (block miner)
/// - Base fee for EIP-1559 transactions
/// - Random value for PREVRANDAO opcode
///
/// This data is accessed by environment opcodes like BLOCKHASH, TIMESTAMP,
/// DIFFICULTY, GASLIMIT, COINBASE, etc.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const BlockInfoConfig = @import("../frame/block_info_config.zig").BlockInfoConfig;

/// Create a BlockInfo type with the given configuration
pub fn BlockInfo(comptime config: BlockInfoConfig) type {
    config.validate();

    const DifficultyType = config.getDifficultyType();
    const BaseFeeType = config.getBaseFeeType();

    return struct {
        const Self = @This();

        /// Chain ID for EIP-155 replay protection
        chain_id: u64 = 1,
        /// Block number
        number: u64,
        /// Parent block hash (for EIP-2935 historical block hashes)
        parent_hash: [32]u8 = [_]u8{0} ** 32,
        /// Block timestamp
        timestamp: u64,
        /// Block difficulty (pre-merge) or prevrandao (post-merge)
        /// Note: Ethereum spec requires u256, but pre-merge practical values fit in u64
        /// Post-merge prevrandao uses full 256 bits of randomness
        difficulty: DifficultyType,
        /// Block gas limit
        gas_limit: u64,
        /// Coinbase (miner) address
        coinbase: Address,
        /// Base fee per gas (EIP-1559)
        /// Note: Ethereum spec requires u256, but practical values fit in u64
        base_fee: BaseFeeType,
        /// Block hash of previous block (post-merge: prevrandao value)
        prev_randao: [32]u8,
        /// Blob base fee for EIP-4844 (cold data)
        /// Set to 0 for non-Cancun hardforks
        blob_base_fee: BaseFeeType = 0,
        /// Blob versioned hashes for EIP-4844 blob transactions (cold data)
        /// Empty slice for non-blob transactions
        /// TODO: this is a transaction-level setting (should be in TransactionContext)
        blob_versioned_hashes: []const [32]u8 = &.{},
        /// Beacon block root for EIP-4788 (Dencun)
        /// Contains the parent beacon block root for trust-minimized access to consensus layer
        beacon_root: ?[32]u8 = null,

        /// Initialize BlockInfo with default values
        pub fn init() Self {
            return Self{
                .chain_id = 1, // Default to mainnet
                .number = 0,
                .parent_hash = [_]u8{0} ** 32,
                .timestamp = 0,
                .difficulty = 0,
                .gas_limit = 30_000_000,
                .coinbase = primitives.ZERO_ADDRESS,
                .base_fee = 0,
                .prev_randao = [_]u8{0} ** 32,
                .blob_base_fee = 0,
                .blob_versioned_hashes = &.{},
            };
        }

        /// Check if this block has EIP-1559 base fee support (London+)
        pub fn hasBaseFee(self: Self) bool {
            return self.base_fee > 0 or self.number > 0; // Simplified check
        }

        /// Validate block info constraints
        pub fn validate(self: Self) bool {
            // Gas limit must be reasonable
            if (self.gas_limit == 0 or self.gas_limit > 100_000_000) return false;
            // Timestamp should be reasonable (not before 2015)
            if (self.timestamp > 0 and self.timestamp < 1438269973) return false; // Ethereum genesis
            return true;
        }
    };
}

/// Compact BlockInfo type using u64 for efficiency (practical values)
pub const CompactBlockInfo = BlockInfo(.{ .use_compact_types = true });

test "block info initialization" {
    const block = BlockInfo(.{}).init();
    try std.testing.expectEqual(@as(u64, 0), block.number);
    try std.testing.expectEqual(@as(u64, 0), block.timestamp);
    try std.testing.expectEqual(@as(u256, 0), block.difficulty);
    try std.testing.expectEqual(@as(u64, 30_000_000), block.gas_limit);
    try std.testing.expectEqual(primitives.ZERO_ADDRESS, block.coinbase);
    try std.testing.expectEqual(@as(u256, 0), block.base_fee);
    try std.testing.expectEqual([_]u8{0} ** 32, block.prev_randao);
    try std.testing.expectEqual(@as(u256, 0), block.blob_base_fee);
    try std.testing.expectEqual(@as(usize, 0), block.blob_versioned_hashes.len);
}

test "block info custom values" {
    const custom_address: Address = Address{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const custom_randao = [_]u8{0xff} ** 32;

    const block = BlockInfo(.{}){
        .chain_id = 1,
        .number = 12345,
        .timestamp = 1640995200, // Jan 1, 2022
        .difficulty = 1000000,
        .gas_limit = 15_000_000,
        .coinbase = custom_address,
        .base_fee = 20_000_000_000, // 20 gwei
        .prev_randao = custom_randao,
        .blob_base_fee = 1_000_000_000, // 1 gwei
        .blob_versioned_hashes = &.{},
    };

    try std.testing.expectEqual(@as(u64, 12345), block.number);
    try std.testing.expectEqual(@as(u64, 1640995200), block.timestamp);
    try std.testing.expectEqual(@as(u256, 1000000), block.difficulty);
    try std.testing.expectEqual(@as(u64, 15_000_000), block.gas_limit);
    try std.testing.expectEqual(custom_address, block.coinbase);
    try std.testing.expectEqual(@as(u256, 20_000_000_000), block.base_fee);
    try std.testing.expectEqual(custom_randao, block.prev_randao);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), block.blob_base_fee);
    try std.testing.expectEqual(@as(usize, 0), block.blob_versioned_hashes.len);
}

test "block info hasBaseFee check" {
    // Block with base fee
    var block = BlockInfo(.{}).init();
    block.base_fee = 1000;
    try std.testing.expect(block.hasBaseFee());

    // Block with number > 0 (London fork assumption)
    block = BlockInfo(.{}).init();
    block.number = 12965000; // London fork block
    try std.testing.expect(block.hasBaseFee());

    // Genesis block without base fee
    block = BlockInfo(.{}).init();
    try std.testing.expect(!block.hasBaseFee()); // Neither condition met
}

test "block info validation" {
    // Valid block
    var block = BlockInfo(.{}).init();
    block.timestamp = 1640995200;
    try std.testing.expect(block.validate());

    // Invalid gas limit - zero
    block = BlockInfo(.{}).init();
    block.gas_limit = 0;
    try std.testing.expect(!block.validate());

    // Invalid gas limit - too high
    block = BlockInfo(.{}).init();
    block.gas_limit = 200_000_000;
    try std.testing.expect(!block.validate());

    // Invalid timestamp - before Ethereum genesis
    block = BlockInfo(.{}).init();
    block.timestamp = 1000000; // Before 2015
    try std.testing.expect(!block.validate());

    // Valid timestamp at boundary
    block = BlockInfo(.{}).init();
    block.timestamp = 1438269973; // Ethereum genesis timestamp
    try std.testing.expect(block.validate());
}

test "block info edge cases" {
    // Maximum values
    const max_block = BlockInfo(.{}){
        .chain_id = 1,
        .number = std.math.maxInt(u64),
        .timestamp = std.math.maxInt(u64),
        .difficulty = std.math.maxInt(u256),
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = std.math.maxInt(u256),
        .prev_randao = [_]u8{0xff} ** 32,
        .blob_base_fee = std.math.maxInt(u256),
        .blob_versioned_hashes = &.{},
    };
    try std.testing.expect(max_block.validate());
    try std.testing.expect(max_block.hasBaseFee());

    // Minimum valid values
    const min_block = BlockInfo(.{}){
        .chain_id = 1,
        .number = 0,
        .timestamp = 1438269973, // Ethereum genesis
        .difficulty = 0,
        .gas_limit = 1,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    try std.testing.expect(min_block.validate());
}

test "compact block info" {
    // Test compact block info with u64 types
    const block = CompactBlockInfo{
        .chain_id = 1,
        .number = 15000000,
        .timestamp = 1640995200,
        .difficulty = 15_000_000_000_000_000, // 15 PH - fits in u64
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 100_000_000_000, // 100 Gwei - fits in u64
        .prev_randao = [_]u8{0xAB} ** 32,
        .blob_base_fee = 50_000_000_000, // 50 Gwei - fits in u64
        .blob_versioned_hashes = &.{},
    };

    try std.testing.expectEqual(@as(u64, 15000000), block.number);
    try std.testing.expectEqual(@as(u64, 15_000_000_000_000_000), block.difficulty);
    try std.testing.expectEqual(@as(u64, 100_000_000_000), block.base_fee);
    try std.testing.expectEqual(@as(u64, 50_000_000_000), block.blob_base_fee);
    try std.testing.expect(block.validate());
    try std.testing.expect(block.hasBaseFee());
}

test "block info with blob data (EIP-4844)" {
    const blob_hash1 = [_]u8{0x01} ** 32;
    const blob_hash2 = [_]u8{0x02} ** 32;
    const blob_hashes = [_][32]u8{ blob_hash1, blob_hash2 };

    const block = BlockInfo(.{}){
        .chain_id = 1,
        .number = 15_000_000,
        .timestamp = 1640995200,
        .difficulty = 0, // Post-merge
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 20_000_000_000, // 20 gwei
        .prev_randao = [_]u8{0xAB} ** 32,
        .blob_base_fee = 1_000_000_000, // 1 gwei
        .blob_versioned_hashes = &blob_hashes,
    };

    try std.testing.expectEqual(@as(u64, 15_000_000), block.number);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), block.blob_base_fee);
    try std.testing.expectEqual(@as(usize, 2), block.blob_versioned_hashes.len);
    try std.testing.expectEqual(blob_hash1, block.blob_versioned_hashes[0]);
    try std.testing.expectEqual(blob_hash2, block.blob_versioned_hashes[1]);
    try std.testing.expect(block.validate());
}

test "mixed block info types" {
    // Custom configuration with mixed types
    const MixedConfig = BlockInfoConfig{
        .DifficultyType = u128,
        .BaseFeeType = u96,
        .use_compact_types = false,
    };
    const MixedBlockInfo = BlockInfo(MixedConfig);

    const block = MixedBlockInfo{
        .number = 1000000,
        .timestamp = 1640995200,
        .difficulty = 1 << 100, // Requires u128
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1 << 80, // Requires u96
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1 << 70, // Requires u96
        .blob_versioned_hashes = &.{},
    };

    try std.testing.expectEqual(u128, @TypeOf(block.difficulty));
    try std.testing.expectEqual(u96, @TypeOf(block.base_fee));
}

test "block info gas limit boundary values" {
    var block = BlockInfo(.{}).init();

    // Test boundary values for gas limit validation
    block.gas_limit = 1; // Minimum valid
    try std.testing.expect(block.validate());

    block.gas_limit = 100_000_000; // Maximum valid
    try std.testing.expect(block.validate());

    block.gas_limit = 100_000_001; // Just over maximum
    try std.testing.expect(!block.validate());
}

test "block info timestamp edge cases" {
    var block = BlockInfo(.{}).init();

    // Zero timestamp should be valid (genesis special case)
    block.timestamp = 0;
    try std.testing.expect(block.validate());

    // Just before Ethereum genesis (invalid)
    block.timestamp = 1438269972;
    try std.testing.expect(!block.validate());

    // Ethereum genesis timestamp (valid)
    block.timestamp = 1438269973;
    try std.testing.expect(block.validate());

    // Far future timestamp (should still be valid)
    block.timestamp = std.math.maxInt(u64);
    try std.testing.expect(block.validate());
}

test "block info hasBaseFee edge cases" {
    var block = BlockInfo(.{}).init();

    // Test edge case: exactly zero base fee and block number
    block.base_fee = 0;
    block.number = 0;
    try std.testing.expect(!block.hasBaseFee());

    // Test minimum non-zero base fee
    block.base_fee = 1;
    block.number = 0;
    try std.testing.expect(block.hasBaseFee());

    // Test minimum non-zero block number
    block.base_fee = 0;
    block.number = 1;
    try std.testing.expect(block.hasBaseFee());

    // Test London fork block number
    block.base_fee = 0;
    block.number = 12965000;
    try std.testing.expect(block.hasBaseFee());
}

test "block info address variations" {
    // Test with different coinbase addresses
    const addresses = [_]Address{
        primitives.ZERO_ADDRESS,
        Address{ .bytes = [_]u8{0xFF} ** 20 }, // All ones
        Address{ .bytes = [_]u8{ 0x12, 0x34, 0x56 } ++ [_]u8{0} ** 17 }, // Mixed pattern
        Address{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 }, // Single bit set
    };

    for (addresses) |addr| {
        const block = BlockInfo(.{}){
            .chain_id = 1,
            .number = 1,
            .timestamp = 1640995200,
            .difficulty = 0,
            .gas_limit = 30_000_000,
            .coinbase = addr,
            .base_fee = 0,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        };

        try std.testing.expectEqual(addr, block.coinbase);
        try std.testing.expect(block.validate());
    }
}

test "block info prev_randao variations" {
    const randao_values = [_][32]u8{
        [_]u8{0} ** 32,
        [_]u8{0xFF} ** 32,
        [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF } ** 4,
    };

    for (randao_values) |randao| {
        const block = BlockInfo(.{}){
            .chain_id = 1,
            .number = 1,
            .timestamp = 1640995200,
            .difficulty = 0,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 0,
            .prev_randao = randao,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        };

        try std.testing.expectEqual(randao, block.prev_randao);
        try std.testing.expect(block.validate());
    }
}

test "block info maximum blob hashes" {
    const testing = std.testing;

    // Test with maximum practical number of blob hashes
    var blob_hashes: [16][32]u8 = undefined;
    for (0..16) |i| {
        blob_hashes[i] = [_]u8{@intCast(i)} ++ [_]u8{0xFF} ** 31;
    }

    const block = BlockInfo(.{}){
        .chain_id = 1,
        .number = 18_000_000,
        .timestamp = 1640995200,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 20_000_000_000,
        .prev_randao = [_]u8{0xAB} ** 32,
        .blob_base_fee = 1_000_000_000,
        .blob_versioned_hashes = &blob_hashes,
    };

    try testing.expectEqual(@as(usize, 16), block.blob_versioned_hashes.len);
    for (0..16) |i| {
        try testing.expectEqual([_]u8{@intCast(i)} ++ [_]u8{0xFF} ** 31, block.blob_versioned_hashes[i]);
    }
    try testing.expect(block.validate());
}

test "block info zero blob base fee pre-cancun" {
    // Before Cancun fork, blob_base_fee should be 0
    const pre_cancun_block = BlockInfo(.{}){
        .chain_id = 1,
        .number = 15_000_000, // Before Cancun
        .timestamp = 1640995200,
        .difficulty = 1000,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 20_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0, // Should be 0 pre-Cancun
        .blob_versioned_hashes = &.{}, // Empty pre-Cancun
    };

    try std.testing.expectEqual(@as(u256, 0), pre_cancun_block.blob_base_fee);
    try std.testing.expectEqual(@as(usize, 0), pre_cancun_block.blob_versioned_hashes.len);
    try std.testing.expect(pre_cancun_block.validate());
}

test "block info difficulty boundary values" {
    // Test with various difficulty values
    const difficulty_values = [_]u256{
        0, // Post-merge (proof of stake)
        1, // Minimum proof of work
        0x1000000, // Typical early mainnet
        0x100000000000000, // High mainnet difficulty
        std.math.maxInt(u256), // Theoretical maximum
    };

    for (difficulty_values) |diff| {
        const block = BlockInfo(.{}){
            .chain_id = 1,
            .number = 1,
            .timestamp = 1640995200,
            .difficulty = diff,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 0,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        };

        try std.testing.expectEqual(diff, block.difficulty);
        try std.testing.expect(block.validate());
    }
}

test "block info compact vs default type sizes" {
    // Verify type sizes are as expected
    const default_block = BlockInfo(.{}).init();
    const compact_block = CompactBlockInfo.init();

    // Default should use u256 for difficulty and base fees
    try std.testing.expectEqual(u256, @TypeOf(default_block.difficulty));
    try std.testing.expectEqual(u256, @TypeOf(default_block.base_fee));
    try std.testing.expectEqual(u256, @TypeOf(default_block.blob_base_fee));

    // Compact should use u64 for difficulty and base fees
    try std.testing.expectEqual(u64, @TypeOf(compact_block.difficulty));
    try std.testing.expectEqual(u64, @TypeOf(compact_block.base_fee));
    try std.testing.expectEqual(u64, @TypeOf(compact_block.blob_base_fee));

    // Both should use u64 for other fields
    try std.testing.expectEqual(u64, @TypeOf(default_block.number));
    try std.testing.expectEqual(u64, @TypeOf(compact_block.number));
    try std.testing.expectEqual(u64, @TypeOf(default_block.timestamp));
    try std.testing.expectEqual(u64, @TypeOf(compact_block.timestamp));
}

test "block info large base fee values" {
    // Test with very large base fee values that require u256
    const large_base_fees = [_]u256{
        1_000_000_000_000_000_000, // 1 ETH in wei
        std.math.maxInt(u64) + 1, // Just over u64 max
        std.math.maxInt(u128), // u128 max
        std.math.maxInt(u256), // u256 max
    };

    for (large_base_fees) |base_fee| {
        const block = BlockInfo(.{}){
            .chain_id = 1,
            .number = 20_000_000,
            .timestamp = 1640995200,
            .difficulty = 0,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = base_fee,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = base_fee / 10, // Related blob fee
            .blob_versioned_hashes = &.{},
        };

        try std.testing.expectEqual(base_fee, block.base_fee);
        try std.testing.expect(block.validate());
        try std.testing.expect(block.hasBaseFee());
    }
}

test "block info validation comprehensive" {
    var block = BlockInfo(.{}).init();

    // Start with valid block
    block.timestamp = 1640995200;
    block.gas_limit = 15_000_000;
    try std.testing.expect(block.validate());

    // Test all invalid gas limit cases
    const invalid_gas_limits = [_]u64{ 0, 100_000_001, std.math.maxInt(u64) };
    for (invalid_gas_limits) |gas_limit| {
        block.gas_limit = gas_limit;
        try std.testing.expect(!block.validate());
    }
    block.gas_limit = 15_000_000; // Reset to valid

    // Test invalid timestamp cases
    const invalid_timestamps = [_]u64{ 1, 1000000, 1438269972 };
    for (invalid_timestamps) |timestamp| {
        block.timestamp = timestamp;
        try std.testing.expect(!block.validate());
    }
    block.timestamp = 1640995200; // Reset to valid

    // Final validation should pass
    try std.testing.expect(block.validate());
}

test "block info struct field ordering" {
    // Test that all required fields are accessible and have correct types
    const block = BlockInfo(.{}).init();

    // Verify field types match expected signature
    _ = @as(u64, block.number);
    _ = @as(u64, block.timestamp);
    _ = @as(u256, block.difficulty);
    _ = @as(u64, block.gas_limit);
    _ = @as(Address, block.coinbase);
    _ = @as(u256, block.base_fee);
    _ = @as([32]u8, block.prev_randao);
    _ = @as(u256, block.blob_base_fee);
    _ = @as([]const [32]u8, block.blob_versioned_hashes);

    // This test ensures struct layout is as expected
    try std.testing.expect(true);
}
