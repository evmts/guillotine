//! Chain type support for different blockchain networks
//!
//! This module provides chain identification and feature detection for various
//! blockchain networks including Ethereum mainnet, testnets, and Layer 2 networks
//! like Optimism.
//!
//! ## Supported Chains
//!
//! ### Ethereum Networks
//! - Mainnet (1)
//! - Sepolia (11155111) 
//! - Holesky (17000)
//!
//! ### Optimism Networks  
//! - OP Mainnet (10)
//! - OP Sepolia (11155420)
//!
//! ## Usage
//! ```zig
//! const chain_type = ChainType.from_chain_id(10);
//! if (chain_type.is_optimism()) {
//!     // Handle Optimism-specific logic
//! }
//! ```

const std = @import("std");
const testing = std.testing;

/// Supported blockchain network types
pub const ChainType = enum {
    ethereum,
    optimism,
    unknown,

    /// Detect chain type from chain ID
    pub fn from_chain_id(chain_id: u64) ChainType {
        return switch (chain_id) {
            // Ethereum networks
            1, 11155111, 17000 => .ethereum,
            // Optimism networks
            10, 11155420 => .optimism,
            else => .unknown,
        };
    }

    /// Check if this is an Optimism network
    pub fn is_optimism(self: ChainType) bool {
        return self == .optimism;
    }

    /// Check if this is an Ethereum network
    pub fn is_ethereum(self: ChainType) bool {
        return self == .ethereum;
    }

    /// Check if this chain requires L1 cost calculation
    pub fn requires_l1_cost_calculation(self: ChainType) bool {
        return self.is_optimism();
    }

    /// Check if this chain supports deposit transactions
    pub fn supports_deposit_transactions(self: ChainType) bool {
        return self.is_optimism();
    }
};

// Tests following TDD approach

test "chain type identification for ethereum networks" {
    try testing.expectEqual(ChainType.ethereum, ChainType.from_chain_id(1));
    try testing.expectEqual(ChainType.ethereum, ChainType.from_chain_id(11155111));
    try testing.expectEqual(ChainType.ethereum, ChainType.from_chain_id(17000));
}

test "chain type identification for optimism networks" {
    try testing.expectEqual(ChainType.optimism, ChainType.from_chain_id(10));
    try testing.expectEqual(ChainType.optimism, ChainType.from_chain_id(11155420));
}

test "chain type identification for unknown networks" {
    try testing.expectEqual(ChainType.unknown, ChainType.from_chain_id(999999));
    try testing.expectEqual(ChainType.unknown, ChainType.from_chain_id(0));
}

test "optimism chain type detection" {
    const op_mainnet = ChainType.from_chain_id(10);
    const op_sepolia = ChainType.from_chain_id(11155420);
    const ethereum_mainnet = ChainType.from_chain_id(1);
    
    try testing.expect(op_mainnet.is_optimism());
    try testing.expect(op_sepolia.is_optimism());
    try testing.expect(!ethereum_mainnet.is_optimism());
}

test "ethereum chain type detection" {
    const ethereum_mainnet = ChainType.from_chain_id(1);
    const ethereum_sepolia = ChainType.from_chain_id(11155111);
    const optimism_mainnet = ChainType.from_chain_id(10);
    
    try testing.expect(ethereum_mainnet.is_ethereum());
    try testing.expect(ethereum_sepolia.is_ethereum());
    try testing.expect(!optimism_mainnet.is_ethereum());
}

test "l1 cost calculation requirement detection" {
    const op_mainnet = ChainType.from_chain_id(10);
    const ethereum_mainnet = ChainType.from_chain_id(1);
    
    try testing.expect(op_mainnet.requires_l1_cost_calculation());
    try testing.expect(!ethereum_mainnet.requires_l1_cost_calculation());
}

test "deposit transaction support detection" {
    const op_mainnet = ChainType.from_chain_id(10);
    const ethereum_mainnet = ChainType.from_chain_id(1);
    
    try testing.expect(op_mainnet.supports_deposit_transactions());
    try testing.expect(!ethereum_mainnet.supports_deposit_transactions());
}