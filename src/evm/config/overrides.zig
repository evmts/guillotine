/// Override system for customizing EVM behavior
/// Supports L2 chains, testing, and custom configurations

const std = @import("std");
const GasConstants = @import("primitives").GasConstants;

/// Custom gas cost overrides for specific operations
pub const GasCostOverrides = struct {
    /// Override for SSTORE operation
    sstore_set: ?u64 = null,
    sstore_reset: ?u64 = null,
    sstore_clear_refund: ?u64 = null,
    
    /// Override for CALL operations
    call_base: ?u64 = null,
    call_value_transfer: ?u64 = null,
    call_new_account: ?u64 = null,
    
    /// Override for CREATE operations
    create_base: ?u64 = null,
    create2_base: ?u64 = null,
    
    /// Override for memory operations
    memory_word: ?u64 = null,
    
    /// Override for transaction costs
    tx_base: ?u64 = null,
    tx_data_zero: ?u64 = null,
    tx_data_nonzero: ?u64 = null,
    
    /// L2-specific costs
    l1_data_fee: ?u64 = null,
    l2_execution_fee: ?u64 = null,
};

/// Memory configuration overrides
pub const MemoryConfig = struct {
    /// Maximum memory size (default: unlimited within gas constraints)
    max_memory_size: ?usize = null,
    
    /// Memory expansion chunk size
    memory_chunk_size: usize = 4096,
    
    /// Enable memory optimization
    optimize_memory: bool = true,
};

/// Gas limit configuration
pub const GasConfig = struct {
    /// Block gas limit
    block_gas_limit: u64 = 30_000_000,
    
    /// Transaction gas limit
    tx_gas_limit: u64 = 30_000_000,
    
    /// Minimum gas price
    min_gas_price: u64 = 0,
    
    /// Enable EIP-1559 fee market
    enable_eip1559: bool = true,
};

/// Database configuration
pub const DatabaseConfig = struct {
    /// Enable state caching
    enable_cache: bool = true,
    
    /// Cache size in entries
    cache_size: usize = 10000,
    
    /// Enable lazy loading
    lazy_loading: bool = true,
    
    /// Enable journaling for reverts
    enable_journaling: bool = true,
};

/// EIP override configuration
/// Allows forcing specific EIPs on or off regardless of hardfork
pub const EipOverrides = struct {
    /// Force enable specific EIPs by number
    force_enable: []const u32 = &.{},
    
    /// Force disable specific EIPs by number
    force_disable: []const u32 = &.{},
    
    /// Custom gas cost overrides
    gas_costs: ?GasCostOverrides = null,
    
    // ============================================================================
    // Predefined L2 Configurations
    // ============================================================================
    
    /// Optimism configuration overrides
    pub const OPTIMISM = EipOverrides{
        .force_enable = &.{
            3198, // BASEFEE enabled earlier
            1559, // EIP-1559 fee market
        },
        .gas_costs = GasCostOverrides{
            .l1_data_fee = 1000, // Custom L1 data fee
            .l2_execution_fee = 100, // L2 execution fee
        },
    };
    
    /// Arbitrum configuration overrides
    pub const ARBITRUM = EipOverrides{
        .force_enable = &.{
            3198, // BASEFEE
            2930, // Access lists
        },
        .gas_costs = GasCostOverrides{
            .l1_data_fee = 1500,
            .l2_execution_fee = 50,
            .call_base = 500, // Different call costs
        },
    };
    
    /// Polygon (Matic) configuration overrides
    pub const POLYGON = EipOverrides{
        .force_disable = &.{
            1559, // No EIP-1559 initially
        },
        .gas_costs = GasCostOverrides{
            .tx_base = 21000,
            .sstore_set = 15000, // Different storage costs
        },
    };
    
    /// Base (Coinbase L2) configuration overrides
    pub const BASE = EipOverrides{
        .force_enable = &.{
            3855, // PUSH0
            1153, // Transient storage
        },
        .gas_costs = GasCostOverrides{
            .l1_data_fee = 800,
            .l2_execution_fee = 75,
        },
    };
    
    /// zkSync Era configuration overrides
    pub const ZKSYNC = EipOverrides{
        .force_enable = &.{
            3855, // PUSH0
        },
        .force_disable = &.{
            // zkSync has different CREATE2 behavior
            1014, // CREATE2 (uses different implementation)
        },
        .gas_costs = GasCostOverrides{
            .create2_base = 50000, // Higher CREATE2 cost
            .l1_data_fee = 2000,
        },
    };
    
    // ============================================================================
    // Test Configuration Presets
    // ============================================================================
    
    /// Minimal test configuration (most features disabled)
    pub const TEST_MINIMAL = EipOverrides{
        .force_disable = &.{
            1559, // No fee market
            2929, // No access lists
            2930, // No typed transactions
        },
    };
    
    /// Full test configuration (all features enabled)
    pub const TEST_FULL = EipOverrides{
        .force_enable = &.{
            3855, // PUSH0
            1153, // Transient storage
            4844, // Blob transactions
            5656, // MCOPY
            6780, // SELFDESTRUCT restriction
        },
    };
    
    /// Gas testing configuration (custom gas costs)
    pub const TEST_GAS = EipOverrides{
        .gas_costs = GasCostOverrides{
            .sstore_set = 100, // Very low for testing
            .call_base = 50,
            .create_base = 100,
            .memory_word = 1,
        },
    };
    
    // ============================================================================
    // Utility Functions
    // ============================================================================
    
    /// Create custom overrides for specific testing scenarios
    pub fn for_testing(comptime enable: []const u32, comptime disable: []const u32) EipOverrides {
        return EipOverrides{
            .force_enable = enable,
            .force_disable = disable,
        };
    }
    
    /// Merge two override configurations
    /// The second configuration takes precedence for conflicts
    pub fn merge(base: EipOverrides, overrides: EipOverrides) EipOverrides {
        return EipOverrides{
            .force_enable = overrides.force_enable,
            .force_disable = overrides.force_disable,
            .gas_costs = overrides.gas_costs orelse base.gas_costs,
        };
    }
    
    /// Check if an EIP should be enabled based on overrides
    pub fn should_enable_eip(self: EipOverrides, eip_num: u32) ?bool {
        // Check force disable first (takes precedence)
        for (self.force_disable) |disabled| {
            if (disabled == eip_num) return false;
        }
        
        // Check force enable
        for (self.force_enable) |enabled| {
            if (enabled == eip_num) return true;
        }
        
        // No override for this EIP
        return null;
    }
};

test "EipOverrides - L2 configurations" {
    // Test Optimism overrides
    {
        const overrides = EipOverrides.OPTIMISM;
        try std.testing.expect(overrides.should_enable_eip(3198) == true);
        try std.testing.expect(overrides.should_enable_eip(1559) == true);
        try std.testing.expect(overrides.gas_costs != null);
        try std.testing.expect(overrides.gas_costs.?.l1_data_fee == 1000);
    }
    
    // Test Polygon overrides
    {
        const overrides = EipOverrides.POLYGON;
        try std.testing.expect(overrides.should_enable_eip(1559) == false);
        try std.testing.expect(overrides.gas_costs != null);
        try std.testing.expect(overrides.gas_costs.?.sstore_set == 15000);
    }
}

test "EipOverrides - test configurations" {
    // Test minimal configuration
    {
        const overrides = EipOverrides.TEST_MINIMAL;
        try std.testing.expect(overrides.should_enable_eip(1559) == false);
        try std.testing.expect(overrides.should_enable_eip(2929) == false);
    }
    
    // Test full configuration
    {
        const overrides = EipOverrides.TEST_FULL;
        try std.testing.expect(overrides.should_enable_eip(3855) == true);
        try std.testing.expect(overrides.should_enable_eip(1153) == true);
        try std.testing.expect(overrides.should_enable_eip(6780) == true);
    }
}

test "EipOverrides - merge configurations" {
    const base = EipOverrides{
        .force_enable = &.{3855},
        .gas_costs = GasCostOverrides{ .sstore_set = 20000 },
    };
    
    const override = EipOverrides{
        .force_disable = &.{1559},
        .gas_costs = GasCostOverrides{ .call_base = 700 },
    };
    
    const merged = EipOverrides.merge(base, override);
    
    // Override configuration should take precedence
    try std.testing.expect(merged.force_disable.len == 1);
    try std.testing.expect(merged.force_disable[0] == 1559);
    try std.testing.expect(merged.gas_costs != null);
    try std.testing.expect(merged.gas_costs.?.call_base == 700);
}