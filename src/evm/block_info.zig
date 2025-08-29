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
const BlockInfoConfig = @import("block_info_config.zig").BlockInfoConfig;

/// Create a BlockInfo type with the given configuration
pub fn BlockInfo(comptime config: BlockInfoConfig) type {
    // Validate configuration at compile time
    config.validate();
    
    const DifficultyType = config.getDifficultyType();
    const BaseFeeType = config.getBaseFeeType();
    
    return struct {
        const Self = @This();
        
        /// Block number
        number: u64,
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
        blob_base_fee: BaseFeeType,
        /// Blob versioned hashes for EIP-4844 blob transactions (cold data)
        /// Empty slice for non-blob transactions
        blob_versioned_hashes: []const [32]u8,
        
        /// Initialize BlockInfo with default values
        pub fn init() Self {
            return Self{
            .number = 0,
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

/// Default BlockInfo type with full u256 compliance (spec-compliant)
pub const DefaultBlockInfo = BlockInfo(.{});

/// Compact BlockInfo type using u64 for efficiency (practical values)
pub const CompactBlockInfo = BlockInfo(.{ .use_compact_types = true });

test "block info initialization" {
    const block = DefaultBlockInfo.init();
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
    const custom_address: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const custom_randao = [_]u8{0xff} ** 32;
    
    const block = DefaultBlockInfo{
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
    var block = DefaultBlockInfo.init();
    block.base_fee = 1000;
    try std.testing.expect(block.hasBaseFee());
    
    // Block with number > 0 (London fork assumption)
    block = DefaultBlockInfo.init();
    block.number = 12965000; // London fork block
    try std.testing.expect(block.hasBaseFee());
    
    // Genesis block without base fee
    block = DefaultBlockInfo.init();
    try std.testing.expect(!block.hasBaseFee()); // Neither condition met
}

test "block info validation" {
    // Valid block
    var block = DefaultBlockInfo.init();
    block.timestamp = 1640995200;
    try std.testing.expect(block.validate());
    
    // Invalid gas limit - zero
    block = DefaultBlockInfo.init();
    block.gas_limit = 0;
    try std.testing.expect(!block.validate());
    
    // Invalid gas limit - too high
    block = DefaultBlockInfo.init();
    block.gas_limit = 200_000_000;
    try std.testing.expect(!block.validate());
    
    // Invalid timestamp - before Ethereum genesis
    block = DefaultBlockInfo.init();
    block.timestamp = 1000000; // Before 2015
    try std.testing.expect(!block.validate());
    
    // Valid timestamp at boundary
    block = DefaultBlockInfo.init();
    block.timestamp = 1438269973; // Ethereum genesis timestamp
    try std.testing.expect(block.validate());
}

test "block info edge cases" {
    // Maximum values
    const max_block = DefaultBlockInfo{
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
    const min_block = DefaultBlockInfo{
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
    
    const block = DefaultBlockInfo{
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
