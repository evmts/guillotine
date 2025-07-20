const primitives = @import("primitives");

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
    
    // Test Optimism addresses  
    try std.testing.expectEqual(@as(u160, 0x4200000000000000000000000000000000000015), OPTIMISM.L1_BLOCK.to_u160());
    try std.testing.expectEqual(@as(u160, 0x4200000000000000000000000000000000000016), OPTIMISM.L2_TO_L1_MESSAGE_PASSER.to_u160());
}