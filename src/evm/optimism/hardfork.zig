const std = @import("std");

/// Optimism hardfork progression
pub const OptimismHardfork = enum(u8) {
    /// Bedrock - Initial Optimism hardfork
    BEDROCK = 0,
    /// Regolith - Improved system transactions
    REGOLITH = 1,
    /// Canyon - EIP-1559 support for L2
    CANYON = 2,
    /// Ecotone - 4844 blob support, new L1 cost calculation
    ECOTONE = 3,
    /// Fjord - Compression ratio updates
    FJORD = 4,
    /// Granite - Minor updates
    GRANITE = 5,
    /// Holocene - Future hardfork
    HOLOCENE = 6,
    /// Isthmus - Operator fees
    ISTHMUS = 7,
    /// Interop - Cross-chain interoperability
    INTEROP = 8,
    /// Osaka - Future hardfork
    OSAKA = 9,

    /// Check if this hardfork is active given the current hardfork
    pub fn isActive(self: OptimismHardfork, current: OptimismHardfork) bool {
        return @intFromEnum(self) <= @intFromEnum(current);
    }
};

/// Optimism-specific chain rules
pub const OptimismRules = struct {
    /// Current Optimism hardfork
    hardfork: OptimismHardfork = .BEDROCK,
    
    /// Check if Regolith is active (improved system transactions)
    pub fn isRegolith(self: OptimismRules) bool {
        return OptimismHardfork.REGOLITH.isActive(self.hardfork);
    }
    
    /// Check if Canyon is active (EIP-1559 for L2)
    pub fn isCanyon(self: OptimismRules) bool {
        return OptimismHardfork.CANYON.isActive(self.hardfork);
    }
    
    /// Check if Ecotone is active (4844 blobs, new L1 cost)
    pub fn isEcotone(self: OptimismRules) bool {
        return OptimismHardfork.ECOTONE.isActive(self.hardfork);
    }
    
    /// Check if Fjord is active (compression updates)
    pub fn isFjord(self: OptimismRules) bool {
        return OptimismHardfork.FJORD.isActive(self.hardfork);
    }
    
    /// Check if Granite is active
    pub fn isGranite(self: OptimismRules) bool {
        return OptimismHardfork.GRANITE.isActive(self.hardfork);
    }
    
    /// Check if Holocene is active
    pub fn isHolocene(self: OptimismRules) bool {
        return OptimismHardfork.HOLOCENE.isActive(self.hardfork);
    }
    
    /// Check if Isthmus is active (operator fees)
    pub fn isIsthmus(self: OptimismRules) bool {
        return OptimismHardfork.ISTHMUS.isActive(self.hardfork);
    }
};

test "OptimismHardfork ordering" {
    const rules = OptimismRules{ .hardfork = .ECOTONE };
    
    try std.testing.expect(rules.isRegolith());
    try std.testing.expect(rules.isCanyon());
    try std.testing.expect(rules.isEcotone());
    try std.testing.expect(!rules.isFjord());
    try std.testing.expect(!rules.isIsthmus());
}