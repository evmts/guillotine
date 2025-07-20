const primitives = @import("primitives");

/// Arbitrum L2 precompile addresses
pub const ARBITRUM = struct {
    /// ArbSys - System configuration and chain info
    pub const ARB_SYS = primitives.Address.from_hex("0x0000000000000000000000000000000000000064") catch unreachable;
    
    /// ArbInfo - Chain metadata  
    pub const ARB_INFO = primitives.Address.from_hex("0x0000000000000000000000000000000000000065") catch unreachable;
    
    /// ArbAddressTable - Address aliasing for L1->L2 messages
    pub const ARB_ADDRESS_TABLE = primitives.Address.from_hex("0x0000000000000000000000000000000000000066") catch unreachable;
    
    /// ArbosTest - Testing utilities
    pub const ARB_OS_TEST = primitives.Address.from_hex("0x0000000000000000000000000000000000000069") catch unreachable;
    
    /// ArbRetryableTx - Retryable transaction management
    pub const ARB_RETRYABLE_TX = primitives.Address.from_hex("0x000000000000000000000000000000000000006e") catch unreachable;
    
    /// ArbGasInfo - Gas pricing information
    pub const ARB_GAS_INFO = primitives.Address.from_hex("0x000000000000000000000000000000000000006c") catch unreachable;
    
    /// ArbAggregator - Batch and data availability info
    pub const ARB_AGGREGATOR = primitives.Address.from_hex("0x000000000000000000000000000000000000006d") catch unreachable;
    
    /// ArbStatistics - Chain statistics
    pub const ARB_STATISTICS = primitives.Address.from_hex("0x000000000000000000000000000000000000006f") catch unreachable;
};

/// Optimism L2 precompile addresses  
pub const OPTIMISM = struct {
    /// L1Block - L1 block information
    pub const L1_BLOCK = primitives.Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;
    
    /// L2ToL1MessagePasser - Message passing to L1
    pub const L2_TO_L1_MESSAGE_PASSER = primitives.Address.from_hex("0x4200000000000000000000000000000000000016") catch unreachable;
    
    /// L2CrossDomainMessenger - Cross-domain messaging
    pub const L2_CROSS_DOMAIN_MESSENGER = primitives.Address.from_hex("0x4200000000000000000000000000000000000007") catch unreachable;
    
    /// L2StandardBridge - Token bridging
    pub const L2_STANDARD_BRIDGE = primitives.Address.from_hex("0x4200000000000000000000000000000000000010") catch unreachable;
    
    /// SequencerFeeVault - Sequencer fee collection
    pub const SEQUENCER_FEE_VAULT = primitives.Address.from_hex("0x4200000000000000000000000000000000000011") catch unreachable;
    
    /// OptimismMintableERC20Factory - Token factory
    pub const OPTIMISM_MINTABLE_ERC20_FACTORY = primitives.Address.from_hex("0x4200000000000000000000000000000000000012") catch unreachable;
    
    /// GasPriceOracle - Gas price information
    pub const GAS_PRICE_ORACLE = primitives.Address.from_hex("0x420000000000000000000000000000000000000f") catch unreachable;
};

test "L2 precompile addresses" {
    const std = @import("std");
    
    // Test Arbitrum addresses
    try std.testing.expectEqual(@as(u160, 0x64), ARBITRUM.ARB_SYS.to_u160());
    try std.testing.expectEqual(@as(u160, 0x65), ARBITRUM.ARB_INFO.to_u160());
    
    // Test Optimism addresses  
    try std.testing.expectEqual(@as(u160, 0x4200000000000000000000000000000000000015), OPTIMISM.L1_BLOCK.to_u160());
}