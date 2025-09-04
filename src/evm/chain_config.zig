/// Chain-specific configuration for EVM implementations
/// Supports Ethereum mainnet, Arbitrum L2, and other L2s
const std = @import("std");

/// Chain types supported by Guillotine EVM
pub const ChainType = enum {
    ETHEREUM,
    ARBITRUM,
    OPTIMISM, // Future support
};

/// Chain configuration with precompile support
pub const ChainConfig = struct {
    chain_type: ChainType,
    chain_id: u64,
    
    pub fn from_chain_id(chain_id: u64) ChainConfig {
        return switch (chain_id) {
            // Arbitrum chain IDs
            42161, 421614, 42170 => .{ 
                .chain_type = .ARBITRUM, 
                .chain_id = chain_id 
            },
            // Optimism chain IDs (future)
            10, 420, 11155420 => .{ 
                .chain_type = .OPTIMISM, 
                .chain_id = chain_id 
            },
            // Default to Ethereum for all other chains
            else => .{ 
                .chain_type = .ETHEREUM, 
                .chain_id = chain_id 
            },
        };
    }
    
    pub fn is_arbitrum_chain_id(chain_id: u64) bool {
        return switch (chain_id) {
            42161, 421614, 42170 => true,
            else => false,
        };
    }
    
    pub fn is_optimism_chain_id(chain_id: u64) bool {
        return switch (chain_id) {
            10, 420, 11155420 => true,
            else => false,
        };
    }
    
    pub fn is_ethereum_chain_id(chain_id: u64) bool {
        return switch (chain_id) {
            1, 3, 4, 5, 42, 11155111 => true, // Common Ethereum chain IDs
            else => false,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ChainType enum values" {
    try testing.expectEqual(ChainType.ETHEREUM, ChainType.ETHEREUM);
    try testing.expectEqual(ChainType.ARBITRUM, ChainType.ARBITRUM);
    try testing.expectEqual(ChainType.OPTIMISM, ChainType.OPTIMISM);
}

test "chain_config_from_arbitrum_chain_ids" {
    // Test Arbitrum One (mainnet)
    const arb_one = ChainConfig.from_chain_id(42161);
    try testing.expectEqual(ChainType.ARBITRUM, arb_one.chain_type);
    try testing.expectEqual(@as(u64, 42161), arb_one.chain_id);
    
    // Test Arbitrum Nova
    const arb_nova = ChainConfig.from_chain_id(42170);
    try testing.expectEqual(ChainType.ARBITRUM, arb_nova.chain_type);
    try testing.expectEqual(@as(u64, 42170), arb_nova.chain_id);
    
    // Test Arbitrum Sepolia (testnet)
    const arb_sepolia = ChainConfig.from_chain_id(421614);
    try testing.expectEqual(ChainType.ARBITRUM, arb_sepolia.chain_type);
    try testing.expectEqual(@as(u64, 421614), arb_sepolia.chain_id);
}

test "chain_config_from_ethereum_chain_ids" {
    // Test Ethereum mainnet
    const eth_mainnet = ChainConfig.from_chain_id(1);
    try testing.expectEqual(ChainType.ETHEREUM, eth_mainnet.chain_type);
    try testing.expectEqual(@as(u64, 1), eth_mainnet.chain_id);
    
    // Test unknown chain ID defaults to Ethereum
    const unknown_chain = ChainConfig.from_chain_id(999999);
    try testing.expectEqual(ChainType.ETHEREUM, unknown_chain.chain_type);
    try testing.expectEqual(@as(u64, 999999), unknown_chain.chain_id);
}

test "chain_config_from_optimism_chain_ids" {
    // Test Optimism mainnet
    const op_mainnet = ChainConfig.from_chain_id(10);
    try testing.expectEqual(ChainType.OPTIMISM, op_mainnet.chain_type);
    try testing.expectEqual(@as(u64, 10), op_mainnet.chain_id);
    
    // Test Optimism Sepolia
    const op_sepolia = ChainConfig.from_chain_id(11155420);
    try testing.expectEqual(ChainType.OPTIMISM, op_sepolia.chain_type);
    try testing.expectEqual(@as(u64, 11155420), op_sepolia.chain_id);
}

test "is_arbitrum_chain_id_validation" {
    // Valid Arbitrum chain IDs
    try testing.expect(ChainConfig.is_arbitrum_chain_id(42161)); // Arbitrum One
    try testing.expect(ChainConfig.is_arbitrum_chain_id(421614)); // Arbitrum Sepolia
    try testing.expect(ChainConfig.is_arbitrum_chain_id(42170)); // Arbitrum Nova
    
    // Invalid chain IDs
    try testing.expect(!ChainConfig.is_arbitrum_chain_id(1)); // Ethereum mainnet
    try testing.expect(!ChainConfig.is_arbitrum_chain_id(10)); // Optimism
    try testing.expect(!ChainConfig.is_arbitrum_chain_id(999999)); // Unknown
}

test "is_optimism_chain_id_validation" {
    // Valid Optimism chain IDs
    try testing.expect(ChainConfig.is_optimism_chain_id(10)); // Optimism mainnet
    try testing.expect(ChainConfig.is_optimism_chain_id(420)); // Optimism Goerli (deprecated)
    try testing.expect(ChainConfig.is_optimism_chain_id(11155420)); // Optimism Sepolia
    
    // Invalid chain IDs
    try testing.expect(!ChainConfig.is_optimism_chain_id(1)); // Ethereum mainnet
    try testing.expect(!ChainConfig.is_optimism_chain_id(42161)); // Arbitrum One
    try testing.expect(!ChainConfig.is_optimism_chain_id(999999)); // Unknown
}

test "is_ethereum_chain_id_validation" {
    // Valid Ethereum chain IDs
    try testing.expect(ChainConfig.is_ethereum_chain_id(1)); // Ethereum mainnet
    try testing.expect(ChainConfig.is_ethereum_chain_id(3)); // Ropsten (deprecated)
    try testing.expect(ChainConfig.is_ethereum_chain_id(5)); // Goerli (deprecated)
    try testing.expect(ChainConfig.is_ethereum_chain_id(11155111)); // Sepolia
    
    // Invalid chain IDs
    try testing.expect(!ChainConfig.is_ethereum_chain_id(42161)); // Arbitrum One
    try testing.expect(!ChainConfig.is_ethereum_chain_id(10)); // Optimism
    try testing.expect(!ChainConfig.is_ethereum_chain_id(999999)); // Unknown
}

test "all_chain_types_covered" {
    const arbitrum_config = ChainConfig.from_chain_id(42161);
    const optimism_config = ChainConfig.from_chain_id(10);
    const ethereum_config = ChainConfig.from_chain_id(1);
    
    // Ensure all chain types are properly handled
    try testing.expectEqual(ChainType.ARBITRUM, arbitrum_config.chain_type);
    try testing.expectEqual(ChainType.OPTIMISM, optimism_config.chain_type);
    try testing.expectEqual(ChainType.ETHEREUM, ethereum_config.chain_type);
    
    // Verify chain IDs are preserved
    try testing.expectEqual(@as(u64, 42161), arbitrum_config.chain_id);
    try testing.expectEqual(@as(u64, 10), optimism_config.chain_id);
    try testing.expectEqual(@as(u64, 1), ethereum_config.chain_id);
}

test "boundary_chain_id_values" {
    // Test boundary values and edge cases
    const zero_chain = ChainConfig.from_chain_id(0);
    try testing.expectEqual(ChainType.ETHEREUM, zero_chain.chain_type);
    
    const max_u64_chain = ChainConfig.from_chain_id(std.math.maxInt(u64));
    try testing.expectEqual(ChainType.ETHEREUM, max_u64_chain.chain_type);
    
    // Test specific Arbitrum boundaries
    const almost_arbitrum = ChainConfig.from_chain_id(42160); // One less than Arbitrum One
    try testing.expectEqual(ChainType.ETHEREUM, almost_arbitrum.chain_type);
    
    const beyond_arbitrum = ChainConfig.from_chain_id(42162); // One more than Arbitrum One
    try testing.expectEqual(ChainType.ETHEREUM, beyond_arbitrum.chain_type);
}