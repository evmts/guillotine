const std = @import("std");
const EipFlags = @import("eip_flags.zig").EipFlags;

/// Gas cost overrides for custom chains
pub const GasCostOverrides = struct {
    // L1 data fee for optimistic rollups
    l1_data_fee: bool = false,
    
    // L2-specific gas costs
    l2_specific_costs: bool = false,
    
    // Custom precompile costs
    custom_precompile_costs: ?std.AutoHashMap(u8, u64) = null,
    
    // Storage cost multipliers
    storage_cost_multiplier: u16 = 100, // 100 = 1.0x, 150 = 1.5x
    
    // Memory expansion cost adjustments
    memory_cost_divisor: u64 = 512, // Standard is 512
};

/// Configuration overrides for L2s and custom chains
pub const EipOverrides = struct {
    /// Force enable specific EIPs regardless of hardfork
    force_enable: []const u16 = &.{},
    
    /// Force disable specific EIPs regardless of hardfork  
    force_disable: []const u16 = &.{},
    
    /// Custom gas costs
    custom_gas_costs: ?GasCostOverrides = null,
    
    /// Chain-specific behavior flags
    chain_behavior: ChainBehavior = .{},
    
    // Predefined L2 configurations
    pub const OPTIMISM = EipOverrides{
        .force_enable = &.{3198}, // BASEFEE enabled earlier
        .custom_gas_costs = .{ 
            .l1_data_fee = true,
            .storage_cost_multiplier = 110, // 10% higher storage costs
        },
        .chain_behavior = .{
            .supports_l1_data_fee = true,
            .custom_block_context = true,
        },
    };
    
    pub const POLYGON = EipOverrides{
        .force_disable = &.{1559}, // No EIP-1559 fee market
        .chain_behavior = .{
            .legacy_gas_only = true,
        },
    };
    
    pub const ARBITRUM = EipOverrides{
        .custom_gas_costs = .{ 
            .l2_specific_costs = true,
            .memory_cost_divisor = 256, // More expensive memory
        },
        .chain_behavior = .{
            .custom_gas_metering = true,
            .supports_l1_data_fee = true,
        },
    };
    
    pub const BASE = EipOverrides{
        .force_enable = &.{3198}, // BASEFEE enabled
        .custom_gas_costs = .{
            .l1_data_fee = true,
        },
        .chain_behavior = .{
            .supports_l1_data_fee = true,
        },
    };
    
    pub const ZKSYNC = EipOverrides{
        .force_disable = &.{
            1153, // No transient storage
            5656, // No MCOPY
        },
        .chain_behavior = .{
            .custom_execution_model = true,
            .zk_specific_opcodes = true,
        },
    };
    
    /// Test configuration with minimal features
    pub const TESTING_MINIMAL = EipOverrides{
        .force_disable = &.{
            1559, // No dynamic fees
            4844, // No blob transactions
            2929, // No access lists
            1153, // No transient storage
        },
    };
    
    /// Test configuration with all features
    pub const TESTING_MAXIMAL = EipOverrides{
        .force_enable = &.{
            3855, // PUSH0
            5656, // MCOPY
            1153, // Transient storage
            7702, // EOA delegation (future)
        },
    };
};

/// Chain-specific behavior flags
pub const ChainBehavior = struct {
    /// Uses legacy gas pricing only (no EIP-1559)
    legacy_gas_only: bool = false,
    
    /// Has custom gas metering rules
    custom_gas_metering: bool = false,
    
    /// Supports L1 data fee calculation
    supports_l1_data_fee: bool = false,
    
    /// Has custom block context fields
    custom_block_context: bool = false,
    
    /// Uses custom execution model (e.g., zkSync)
    custom_execution_model: bool = false,
    
    /// Has ZK-specific opcodes
    zk_specific_opcodes: bool = false,
    
    /// Custom consensus rules
    custom_consensus: bool = false,
};

/// Apply overrides to EIP flags
pub fn applyOverrides(flags: *EipFlags, overrides: EipOverrides) void {
    // Apply force enables
    for (overrides.force_enable) |eip| {
        switch (eip) {
            150 => flags.eip150_gas_costs = true,
            155 => flags.eip155_chain_id = true,
            161 => flags.eip161_state_clear = true,
            170 => flags.eip170_code_size_limit = true,
            211 => {
                flags.eip211_returndatasize = true;
                flags.eip211_returndatacopy = true;
            },
            214 => flags.eip214_staticcall = true,
            1014 => flags.eip1014_create2 = true,
            1052 => flags.eip1052_extcodehash = true,
            1153 => flags.eip1153_transient_storage = true,
            1283 => flags.eip1283_sstore_gas = true,
            1344 => flags.eip1344_chainid = true,
            1559 => flags.eip1559_base_fee = true,
            2200 => flags.eip2200_sstore_gas = true,
            2929 => flags.eip2929_gas_costs = true,
            2930 => flags.eip2930_access_lists = true,
            3198 => flags.eip3198_basefee = true,
            3529 => flags.eip3529_selfdestruct = true,
            3651 => flags.eip3651_warm_coinbase = true,
            3855 => flags.eip3855_push0 = true,
            3860 => flags.eip3860_initcode_limit = true,
            4788 => flags.eip4788_beacon_root = true,
            4844 => {
                flags.eip4844_blob_tx = true;
                flags.eip4844_shard_blob_tx = true;
            },
            4895 => flags.eip4895_beacon_withdrawals = true,
            5656 => flags.eip5656_mcopy = true,
            6780 => flags.eip6780_selfdestruct_only_same_tx = true,
            7516 => flags.eip7516_blobbasefee = true,
            7702 => flags.eip7702_eoa_delegation = true,
            else => {}, // Unknown EIP, ignore
        }
    }
    
    // Apply force disables
    for (overrides.force_disable) |eip| {
        switch (eip) {
            150 => flags.eip150_gas_costs = false,
            155 => flags.eip155_chain_id = false,
            161 => flags.eip161_state_clear = false,
            170 => flags.eip170_code_size_limit = false,
            211 => {
                flags.eip211_returndatasize = false;
                flags.eip211_returndatacopy = false;
            },
            214 => flags.eip214_staticcall = false,
            1014 => flags.eip1014_create2 = false,
            1052 => flags.eip1052_extcodehash = false,
            1153 => flags.eip1153_transient_storage = false,
            1283 => flags.eip1283_sstore_gas = false,
            1344 => flags.eip1344_chainid = false,
            1559 => flags.eip1559_base_fee = false,
            2200 => flags.eip2200_sstore_gas = false,
            2929 => flags.eip2929_gas_costs = false,
            2930 => flags.eip2930_access_lists = false,
            3198 => flags.eip3198_basefee = false,
            3529 => flags.eip3529_selfdestruct = false,
            3651 => flags.eip3651_warm_coinbase = false,
            3855 => flags.eip3855_push0 = false,
            3860 => flags.eip3860_initcode_limit = false,
            4788 => flags.eip4788_beacon_root = false,
            4844 => {
                flags.eip4844_blob_tx = false;
                flags.eip4844_shard_blob_tx = false;
            },
            4895 => flags.eip4895_beacon_withdrawals = false,
            5656 => flags.eip5656_mcopy = false,
            6780 => flags.eip6780_selfdestruct_only_same_tx = false,
            7516 => flags.eip7516_blobbasefee = false,
            7702 => flags.eip7702_eoa_delegation = false,
            else => {}, // Unknown EIP, ignore
        }
    }
}

test "L2 override configurations" {
    const testing = std.testing;
    const deriveEipFlagsFromHardfork = @import("eip_flags.zig").deriveEipFlagsFromHardfork;
    
    // Test Optimism overrides
    {
        var flags = deriveEipFlagsFromHardfork(.BERLIN); // Before London
        try testing.expect(!flags.eip3198_basefee); // Not enabled in Berlin
        
        applyOverrides(&flags, EipOverrides.OPTIMISM);
        try testing.expect(flags.eip3198_basefee); // Force enabled for Optimism
    }
    
    // Test Polygon overrides
    {
        var flags = deriveEipFlagsFromHardfork(.LONDON);
        try testing.expect(flags.eip1559_base_fee); // Enabled in London
        
        applyOverrides(&flags, EipOverrides.POLYGON);
        try testing.expect(!flags.eip1559_base_fee); // Force disabled for Polygon
    }
    
    // Test custom overrides
    {
        var flags = deriveEipFlagsFromHardfork(.SHANGHAI);
        try testing.expect(flags.eip3855_push0); // Enabled in Shanghai
        try testing.expect(!flags.eip5656_mcopy); // Not until Cancun
        
        const custom = EipOverrides{
            .force_enable = &.{5656}, // Enable MCOPY early
            .force_disable = &.{3855}, // Disable PUSH0
        };
        
        applyOverrides(&flags, custom);
        try testing.expect(!flags.eip3855_push0); // Disabled
        try testing.expect(flags.eip5656_mcopy); // Enabled early
    }
}

test "Testing configurations" {
    const testing = std.testing;
    const deriveEipFlagsFromHardfork = @import("eip_flags.zig").deriveEipFlagsFromHardfork;
    
    // Test minimal configuration
    {
        var flags = deriveEipFlagsFromHardfork(.CANCUN);
        applyOverrides(&flags, EipOverrides.TESTING_MINIMAL);
        
        try testing.expect(!flags.eip1559_base_fee);
        try testing.expect(!flags.eip4844_blob_tx);
        try testing.expect(!flags.eip2929_gas_costs);
        try testing.expect(!flags.eip1153_transient_storage);
    }
    
    // Test maximal configuration
    {
        var flags = deriveEipFlagsFromHardfork(.FRONTIER); // Start with nothing
        applyOverrides(&flags, EipOverrides.TESTING_MAXIMAL);
        
        try testing.expect(flags.eip3855_push0);
        try testing.expect(flags.eip5656_mcopy);
        try testing.expect(flags.eip1153_transient_storage);
        try testing.expect(flags.eip7702_eoa_delegation);
    }
}