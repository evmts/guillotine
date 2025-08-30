//! Execution context for EVM transactions and calls
//!
//! Provides transaction-level context information including block data,
//! transaction parameters, and execution environment.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Transaction execution context
pub const Context = struct {
    /// Transaction origin (tx.origin)
    origin: Address,
    
    /// Gas price for the transaction
    gas_price: u256,
    
    /// Chain ID for the current network
    chain_id: u64,
    
    /// Block timestamp
    timestamp: u64,
    
    /// Block number
    block_number: u64,
    
    /// Block gas limit
    gas_limit: u64,
    
    /// Block base fee (EIP-1559)
    base_fee: u256,
    
    /// Block coinbase (miner address)
    coinbase: Address,
    
    /// Block difficulty
    difficulty: u256,
    
    /// Previous block hash (prevrandao in post-merge)
    prevrandao: [32]u8,
    
    /// Blob base fee (EIP-4844)
    blob_base_fee: u128,
    
    /// Static flag for STATICCALL context
    is_static: bool = false,
    
    /// Default initialization
    pub fn init() Context {
        return .{
            .origin = Address.ZERO_ADDRESS,
            .gas_price = 0,
            .chain_id = 1,
            .timestamp = 0,
            .block_number = 0,
            .gas_limit = 30_000_000,
            .base_fee = 0,
            .coinbase = Address.ZERO_ADDRESS,
            .difficulty = 0,
            .prevrandao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .is_static = false,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const std = @import("std");
const testing = std.testing;

test "Context - default initialization" {
    const ctx = Context.init();
    
    try testing.expectEqual(Address.ZERO_ADDRESS, ctx.origin);
    try testing.expectEqual(@as(u256, 0), ctx.gas_price);
    try testing.expectEqual(@as(u64, 1), ctx.chain_id);
    try testing.expectEqual(@as(u64, 0), ctx.timestamp);
    try testing.expectEqual(@as(u64, 0), ctx.block_number);
    try testing.expectEqual(@as(u64, 30_000_000), ctx.gas_limit);
    try testing.expectEqual(@as(u256, 0), ctx.base_fee);
    try testing.expectEqual(Address.ZERO_ADDRESS, ctx.coinbase);
    try testing.expectEqual(@as(u256, 0), ctx.difficulty);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &ctx.prevrandao);
    try testing.expectEqual(@as(u128, 0), ctx.blob_base_fee);
    try testing.expectEqual(false, ctx.is_static);
}

test "Context - custom initialization" {
    const custom_origin = Address{ .bytes = [_]u8{0x01} ** 20 };
    const custom_coinbase = Address{ .bytes = [_]u8{0x02} ** 20 };
    const custom_prevrandao = [_]u8{0xFF} ** 32;
    
    const ctx = Context{
        .origin = custom_origin,
        .gas_price = 20_000_000_000, // 20 gwei
        .chain_id = 137, // Polygon
        .timestamp = 1234567890,
        .block_number = 12345,
        .gas_limit = 15_000_000,
        .base_fee = 15_000_000_000, // 15 gwei
        .coinbase = custom_coinbase,
        .difficulty = 12345678901234567890,
        .prevrandao = custom_prevrandao,
        .blob_base_fee = 1000000,
        .is_static = true,
    };
    
    try testing.expectEqual(custom_origin, ctx.origin);
    try testing.expectEqual(@as(u256, 20_000_000_000), ctx.gas_price);
    try testing.expectEqual(@as(u64, 137), ctx.chain_id);
    try testing.expectEqual(@as(u64, 1234567890), ctx.timestamp);
    try testing.expectEqual(@as(u64, 12345), ctx.block_number);
    try testing.expectEqual(@as(u64, 15_000_000), ctx.gas_limit);
    try testing.expectEqual(@as(u256, 15_000_000_000), ctx.base_fee);
    try testing.expectEqual(custom_coinbase, ctx.coinbase);
    try testing.expectEqual(@as(u256, 12345678901234567890), ctx.difficulty);
    try testing.expectEqualSlices(u8, &custom_prevrandao, &ctx.prevrandao);
    try testing.expectEqual(@as(u128, 1000000), ctx.blob_base_fee);
    try testing.expectEqual(true, ctx.is_static);
}

test "Context - EIP-1559 parameters" {
    const ctx = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 30_000_000_000,
        .chain_id = 1,
        .timestamp = 0,
        .block_number = 15000000, // Post London fork
        .gas_limit = 30_000_000,
        .base_fee = 20_000_000_000, // 20 gwei base fee
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 0, // Post-merge, difficulty should be 0
        .prevrandao = [_]u8{0x12} ** 32,
        .blob_base_fee = 0,
    };
    
    try testing.expectEqual(@as(u256, 30_000_000_000), ctx.gas_price);
    try testing.expectEqual(@as(u256, 20_000_000_000), ctx.base_fee);
    try testing.expectEqual(@as(u256, 0), ctx.difficulty);
}

test "Context - EIP-4844 blob parameters" {
    const ctx = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 0,
        .chain_id = 1,
        .timestamp = 1710000000, // Post Dencun fork
        .block_number = 19500000,
        .gas_limit = 30_000_000,
        .base_fee = 10_000_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 0,
        .prevrandao = [_]u8{0xAB} ** 32,
        .blob_base_fee = 2000000000, // 2 gwei blob base fee
    };
    
    try testing.expectEqual(@as(u128, 2000000000), ctx.blob_base_fee);
    try testing.expectEqual(@as(u64, 1710000000), ctx.timestamp);
}

test "Context - static call flag" {
    var ctx = Context.init();
    try testing.expectEqual(false, ctx.is_static);
    
    // Simulate entering static context
    ctx.is_static = true;
    try testing.expectEqual(true, ctx.is_static);
    
    // Simulate exiting static context
    ctx.is_static = false;
    try testing.expectEqual(false, ctx.is_static);
}

test "Context - chain ID variations" {
    const mainnet_ctx = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 0,
        .chain_id = 1, // Ethereum mainnet
        .timestamp = 0,
        .block_number = 0,
        .gas_limit = 30_000_000,
        .base_fee = 0,
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 0,
        .prevrandao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
    };
    
    const polygon_ctx = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 0,
        .chain_id = 137, // Polygon
        .timestamp = 0,
        .block_number = 0,
        .gas_limit = 30_000_000,
        .base_fee = 0,
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 0,
        .prevrandao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
    };
    
    const arbitrum_ctx = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 0,
        .chain_id = 42161, // Arbitrum One
        .timestamp = 0,
        .block_number = 0,
        .gas_limit = 30_000_000,
        .base_fee = 0,
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 0,
        .prevrandao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
    };
    
    try testing.expectEqual(@as(u64, 1), mainnet_ctx.chain_id);
    try testing.expectEqual(@as(u64, 137), polygon_ctx.chain_id);
    try testing.expectEqual(@as(u64, 42161), arbitrum_ctx.chain_id);
}

test "Context - maximum values" {
    const max_ctx = Context{
        .origin = Address{ .bytes = [_]u8{0xFF} ** 20 },
        .gas_price = std.math.maxInt(u256),
        .chain_id = std.math.maxInt(u64),
        .timestamp = std.math.maxInt(u64),
        .block_number = std.math.maxInt(u64),
        .gas_limit = std.math.maxInt(u64),
        .base_fee = std.math.maxInt(u256),
        .coinbase = Address{ .bytes = [_]u8{0xFF} ** 20 },
        .difficulty = std.math.maxInt(u256),
        .prevrandao = [_]u8{0xFF} ** 32,
        .blob_base_fee = std.math.maxInt(u128),
        .is_static = true,
    };
    
    try testing.expectEqual(std.math.maxInt(u256), max_ctx.gas_price);
    try testing.expectEqual(std.math.maxInt(u64), max_ctx.chain_id);
    try testing.expectEqual(std.math.maxInt(u64), max_ctx.timestamp);
    try testing.expectEqual(std.math.maxInt(u64), max_ctx.block_number);
    try testing.expectEqual(std.math.maxInt(u64), max_ctx.gas_limit);
    try testing.expectEqual(std.math.maxInt(u256), max_ctx.base_fee);
    try testing.expectEqual(std.math.maxInt(u256), max_ctx.difficulty);
    try testing.expectEqual(std.math.maxInt(u128), max_ctx.blob_base_fee);
}

test "Context - typical mainnet values" {
    const typical_mainnet = Context{
        .origin = Address{ .bytes = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9A} ++ [_]u8{0} ** 15 },
        .gas_price = 25_000_000_000, // 25 gwei
        .chain_id = 1,
        .timestamp = 1699200000, // Nov 2023
        .block_number = 18500000,
        .gas_limit = 30_000_000,
        .base_fee = 15_000_000_000, // 15 gwei
        .coinbase = Address{ .bytes = [_]u8{0xAB, 0xCD, 0xEF} ++ [_]u8{0} ** 17 },
        .difficulty = 0, // Post-merge
        .prevrandao = [_]u8{0x1A, 0x2B, 0x3C} ++ [_]u8{0} ** 29,
        .blob_base_fee = 1000000000, // 1 gwei
        .is_static = false,
    };
    
    // Verify typical ranges
    try testing.expect(typical_mainnet.gas_price >= 1_000_000_000); // At least 1 gwei
    try testing.expect(typical_mainnet.gas_price <= 100_000_000_000); // At most 100 gwei
    try testing.expect(typical_mainnet.base_fee >= 1_000_000_000);
    try testing.expect(typical_mainnet.base_fee <= 50_000_000_000);
    try testing.expect(typical_mainnet.gas_limit >= 15_000_000);
    try testing.expect(typical_mainnet.gas_limit <= 50_000_000);
}

test "Context - pre-merge vs post-merge" {
    const pre_merge = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 20_000_000_000,
        .chain_id = 1,
        .timestamp = 1640000000, // Early 2022
        .block_number = 14000000,
        .gas_limit = 30_000_000,
        .base_fee = 10_000_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 12500000000000000000000, // Non-zero difficulty
        .prevrandao = [_]u8{0} ** 32, // Would be mix_hash pre-merge
        .blob_base_fee = 0,
    };
    
    const post_merge = Context{
        .origin = Address.ZERO_ADDRESS,
        .gas_price = 20_000_000_000,
        .chain_id = 1,
        .timestamp = 1663200000, // Sep 2022 (post-merge)
        .block_number = 15537393,
        .gas_limit = 30_000_000,
        .base_fee = 10_000_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .difficulty = 0, // Zero difficulty post-merge
        .prevrandao = [_]u8{0xAB} ** 32, // Now actually prevrandao
        .blob_base_fee = 0,
    };
    
    try testing.expect(pre_merge.difficulty > 0);
    try testing.expectEqual(@as(u256, 0), post_merge.difficulty);
    try testing.expect(pre_merge.block_number < post_merge.block_number);
};