/// Chain type identification and L2 network configuration
/// This module provides the foundation for supporting different chain types,
/// with initial focus on Optimism L2 support.

const std = @import("std");

/// Chain types supported by the Guillotine EVM
pub const ChainType = enum {
    ethereum,
    optimism,
    
    /// Identify chain type from chain ID
    pub fn from_chain_id(chain_id: u64) ChainType {
        return switch (chain_id) {
            1, 11155111 => .ethereum,                    // Ethereum mainnet & sepolia
            10, 11155420 => .optimism,                   // Optimism mainnet & sepolia
            else => .ethereum,                           // Default to Ethereum for unknown chains
        };
    }
    
    /// Check if this is an Optimism L2 chain
    pub fn is_optimism(self: ChainType) bool {
        return self == .optimism;
    }
    
    /// Check if this chain requires L1 cost calculation
    pub fn requires_l1_cost_calculation(self: ChainType) bool {
        return self.is_optimism();
        // TODO: Add other L2s (Arbitrum, Base, etc.) when implemented
    }
    
    /// Check if this chain supports deposit transactions
    pub fn supports_deposit_transactions(self: ChainType) bool {
        return self.is_optimism();
    }
    
    /// Check if this chain requires L1Block precompile
    pub fn requires_l1block_precompile(self: ChainType) bool {
        return self.is_optimism();
    }
    
    /// Get chain-specific configuration name for logging/debugging
    pub fn name(self: ChainType) []const u8 {
        return switch (self) {
            .ethereum => "Ethereum",
            .optimism => "Optimism",
        };
    }
};

// Tests to verify chain type detection and feature flags
const testing = std.testing;

test "chain type from chain id" {
    try testing.expectEqual(ChainType.ethereum, ChainType.from_chain_id(1));
    try testing.expectEqual(ChainType.ethereum, ChainType.from_chain_id(11155111));
    try testing.expectEqual(ChainType.optimism, ChainType.from_chain_id(10));
    try testing.expectEqual(ChainType.optimism, ChainType.from_chain_id(11155420));
    try testing.expectEqual(ChainType.ethereum, ChainType.from_chain_id(999)); // Unknown defaults to Ethereum
}

test "optimism feature detection" {
    const op_mainnet = ChainType.from_chain_id(10);
    const eth_mainnet = ChainType.from_chain_id(1);
    
    try testing.expect(op_mainnet.is_optimism());
    try testing.expect(!eth_mainnet.is_optimism());
    
    try testing.expect(op_mainnet.requires_l1_cost_calculation());
    try testing.expect(!eth_mainnet.requires_l1_cost_calculation());
    
    try testing.expect(op_mainnet.supports_deposit_transactions());
    try testing.expect(!eth_mainnet.supports_deposit_transactions());
    
    try testing.expect(op_mainnet.requires_l1block_precompile());
    try testing.expect(!eth_mainnet.requires_l1block_precompile());
}

test "chain type naming" {
    try testing.expectEqualStrings("Ethereum", ChainType.ethereum.name());
    try testing.expectEqualStrings("Optimism", ChainType.optimism.name());
}