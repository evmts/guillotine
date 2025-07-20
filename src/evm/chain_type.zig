const std = @import("std");

/// Chain type enum to identify different blockchain networks
pub const ChainType = enum {
    /// Ethereum mainnet and testnets
    ETHEREUM,
    /// Optimism Layer 2
    OPTIMISM,

    /// Get chain type from chain ID
    pub fn fromChainId(chain_id: u64) ChainType {
        return switch (chain_id) {
            // Ethereum mainnet
            1 => .ETHEREUM,
            // Ethereum testnets
            3, 4, 5, 11155111 => .ETHEREUM, // Ropsten, Rinkeby, Goerli, Sepolia
            
            // Optimism chains  
            10 => .OPTIMISM, // OP Mainnet
            11155420 => .OPTIMISM, // OP Sepolia
            
            // Default to Ethereum for unknown chains
            else => .ETHEREUM,
        };
    }
};

test "ChainType.fromChainId" {
    try std.testing.expectEqual(ChainType.ETHEREUM, ChainType.fromChainId(1));
    try std.testing.expectEqual(ChainType.OPTIMISM, ChainType.fromChainId(10));
    try std.testing.expectEqual(ChainType.ETHEREUM, ChainType.fromChainId(999999));
}