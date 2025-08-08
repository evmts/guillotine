/// Central configuration structure for the EVM
/// Manages hardfork settings, EIP flags, and runtime configuration

const std = @import("std");
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;
const EipFlags = @import("eip_flags.zig").EipFlags;
const overrides = @import("overrides.zig");
const EipOverrides = overrides.EipOverrides;
const GasCostOverrides = overrides.GasCostOverrides;
const MemoryConfig = overrides.MemoryConfig;
const GasConfig = overrides.GasConfig;
const DatabaseConfig = overrides.DatabaseConfig;

/// Central EVM configuration structure
/// Provides a unified interface for all EVM behavior configuration
pub const EvmConfig = struct {
    /// Base hardfork that determines default EIP flags
    hardfork: Hardfork,
    
    /// Chain ID for replay protection (EIP-155)
    chain_id: u64 = 1, // Default to mainnet
    
    /// Optional EIP overrides for L2s, custom chains, and testing
    eip_overrides: ?EipOverrides = null,
    
    /// Memory configuration
    memory_config: MemoryConfig = .{},
    
    /// Gas limits and costs
    gas_config: GasConfig = .{},
    
    /// Database configuration
    database_config: DatabaseConfig = .{},
    
    /// Cached EIP flags (computed once from hardfork + overrides)
    cached_eip_flags: ?EipFlags = null,
    
    // ============================================================================
    // Initialization Functions
    // ============================================================================
    
    /// Create config for a specific hardfork with default settings
    pub fn from_hardfork(hardfork: Hardfork) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
        };
    }
    
    /// Create config for mainnet at a specific hardfork
    pub fn mainnet(hardfork: Hardfork) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .chain_id = 1,
        };
    }
    
    /// Create config for a testnet
    pub fn testnet(hardfork: Hardfork, chain_id: u64) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .chain_id = chain_id,
        };
    }
    
    /// Create config with L2/custom chain overrides
    pub fn with_overrides(hardfork: Hardfork, eip_overrides: EipOverrides) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .eip_overrides = eip_overrides,
        };
    }
    
    // ============================================================================
    // Predefined Configurations
    // ============================================================================
    
    /// Latest mainnet configuration (Cancun)
    pub const MAINNET_LATEST = EvmConfig{
        .hardfork = .CANCUN,
        .chain_id = 1,
    };
    
    /// Ethereum Classic configuration
    pub const ETHEREUM_CLASSIC = EvmConfig{
        .hardfork = .PETERSBURG, // ETC doesn't follow ETH hardforks after DAO
        .chain_id = 61,
    };
    
    /// Sepolia testnet configuration
    pub const SEPOLIA = EvmConfig{
        .hardfork = .CANCUN,
        .chain_id = 11155111,
    };
    
    /// Goerli testnet configuration (deprecated but still used)
    pub const GOERLI = EvmConfig{
        .hardfork = .CANCUN,
        .chain_id = 5,
    };
    
    /// Holesky testnet configuration
    pub const HOLESKY = EvmConfig{
        .hardfork = .CANCUN,
        .chain_id = 17000,
    };
    
    // ============================================================================
    // L2 Configurations
    // ============================================================================
    
    /// Optimism mainnet configuration
    pub fn optimism() EvmConfig {
        return EvmConfig{
            .hardfork = .CANCUN,
            .chain_id = 10,
            .eip_overrides = EipOverrides.OPTIMISM,
        };
    }
    
    /// Arbitrum One configuration
    pub fn arbitrum() EvmConfig {
        return EvmConfig{
            .hardfork = .CANCUN,
            .chain_id = 42161,
            .eip_overrides = EipOverrides.ARBITRUM,
        };
    }
    
    /// Polygon (Matic) configuration
    pub fn polygon() EvmConfig {
        return EvmConfig{
            .hardfork = .CANCUN,
            .chain_id = 137,
            .eip_overrides = EipOverrides.POLYGON,
        };
    }
    
    /// Base (Coinbase L2) configuration
    pub fn base() EvmConfig {
        return EvmConfig{
            .hardfork = .CANCUN,
            .chain_id = 8453,
            .eip_overrides = EipOverrides.BASE,
        };
    }
    
    /// zkSync Era configuration
    pub fn zksync() EvmConfig {
        return EvmConfig{
            .hardfork = .CANCUN,
            .chain_id = 324,
            .eip_overrides = EipOverrides.ZKSYNC,
        };
    }
    
    // ============================================================================
    // Configuration Query Functions
    // ============================================================================
    
    /// Get EIP flags for this configuration
    /// Combines hardfork defaults with any overrides
    pub fn get_eip_flags(self: *EvmConfig) EipFlags {
        // Return cached flags if available
        if (self.cached_eip_flags) |flags| {
            return flags;
        }
        
        // Compute flags from hardfork
        var flags = EipFlags.from_hardfork(self.hardfork);
        
        // Apply overrides if present
        if (self.eip_overrides) |eip_overrides| {
            flags.apply_overrides(
                eip_overrides.force_enable,
                eip_overrides.force_disable,
            );
        }
        
        // Cache the result
        self.cached_eip_flags = flags;
        
        return flags;
    }
    
    /// Check if a specific EIP is enabled
    pub fn is_eip_enabled(self: *EvmConfig, eip_num: u32) bool {
        // Check overrides first
        if (self.eip_overrides) |eip_overrides| {
            if (eip_overrides.should_enable_eip(eip_num)) |enabled| {
                return enabled;
            }
        }
        
        // Fall back to hardfork defaults
        const flags = self.get_eip_flags();
        return switch (eip_num) {
            2 => flags.eip2_homestead_transactions,
            7 => flags.eip7_delegatecall,
            140 => flags.eip140_revert,
            145 => flags.eip145_bitwise_shifting,
            150 => flags.eip150_gas_costs,
            155 => flags.eip155_chain_id,
            170 => flags.eip170_code_size_limit,
            211 => flags.eip211_returndatasize,
            214 => flags.eip214_staticcall,
            1014 => flags.eip1014_create2,
            1153 => flags.eip1153_transient_storage,
            1559 => flags.eip1559_fee_market,
            2929 => flags.eip2929_gas_costs,
            2930 => flags.eip2930_access_lists,
            3198 => flags.eip3198_basefee,
            3855 => flags.eip3855_push0,
            4844 => flags.eip4844_blob_transactions,
            5656 => flags.eip5656_mcopy,
            6780 => flags.eip6780_selfdestruct_restriction,
            else => false,
        };
    }
    
    /// Get gas cost for a specific operation
    /// Returns overridden value if present, otherwise returns default
    pub fn get_gas_cost(self: EvmConfig, comptime operation: []const u8) u64 {
        // Check for gas cost overrides
        if (self.eip_overrides) |eip_overrides| {
            if (eip_overrides.gas_costs) |gas_costs| {
                if (std.mem.eql(u8, operation, "sstore_set")) {
                    if (gas_costs.sstore_set) |cost| return cost;
                } else if (std.mem.eql(u8, operation, "call_base")) {
                    if (gas_costs.call_base) |cost| return cost;
                } else if (std.mem.eql(u8, operation, "create_base")) {
                    if (gas_costs.create_base) |cost| return cost;
                }
                // Add more operations as needed
            }
        }
        
        // Return default gas costs based on hardfork
        // This would normally use GasConstants from primitives
        return switch (operation[0]) {
            's' => 20000, // sstore_set default
            'c' => if (operation[1] == 'a') 700 else 32000, // call vs create
            else => 3,
        };
    }
    
    /// Check if this is an L2 configuration
    pub fn is_l2(self: EvmConfig) bool {
        return switch (self.chain_id) {
            10, // Optimism
            42161, // Arbitrum
            137, // Polygon
            8453, // Base
            324, // zkSync
            => true,
            else => false,
        };
    }
    
    /// Check if this is a testnet configuration
    pub fn is_testnet(self: EvmConfig) bool {
        return switch (self.chain_id) {
            5, // Goerli
            11155111, // Sepolia
            17000, // Holesky
            => true,
            else => false,
        };
    }
    
    // ============================================================================
    // Builder Pattern Functions
    // ============================================================================
    
    /// Set chain ID
    pub fn with_chain_id(self: EvmConfig, chain_id: u64) EvmConfig {
        var config = self;
        config.chain_id = chain_id;
        return config;
    }
    
    /// Set memory configuration
    pub fn with_memory_config(self: EvmConfig, memory_config: MemoryConfig) EvmConfig {
        var config = self;
        config.memory_config = memory_config;
        return config;
    }
    
    /// Set gas configuration
    pub fn with_gas_config(self: EvmConfig, gas_config: GasConfig) EvmConfig {
        var config = self;
        config.gas_config = gas_config;
        return config;
    }
    
    /// Set database configuration
    pub fn with_database_config(self: EvmConfig, database_config: DatabaseConfig) EvmConfig {
        var config = self;
        config.database_config = database_config;
        return config;
    }
    
    /// Enable specific EIPs
    pub fn enable_eips(self: EvmConfig, eips: []const u32) EvmConfig {
        var config = self;
        const new_overrides = if (config.eip_overrides) |existing| 
            EipOverrides{
                .force_enable = eips,
                .force_disable = existing.force_disable,
                .gas_costs = existing.gas_costs,
            }
        else 
            EipOverrides{ .force_enable = eips };
        
        config.eip_overrides = new_overrides;
        config.cached_eip_flags = null; // Invalidate cache
        return config;
    }
    
    /// Disable specific EIPs
    pub fn disable_eips(self: EvmConfig, eips: []const u32) EvmConfig {
        var config = self;
        const new_overrides = if (config.eip_overrides) |existing|
            EipOverrides{
                .force_enable = existing.force_enable,
                .force_disable = eips,
                .gas_costs = existing.gas_costs,
            }
        else
            EipOverrides{ .force_disable = eips };
        
        config.eip_overrides = new_overrides;
        config.cached_eip_flags = null; // Invalidate cache
        return config;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EvmConfig - mainnet configuration" {
    var config = EvmConfig.mainnet(.CANCUN);
    
    try std.testing.expectEqual(@as(u64, 1), config.chain_id);
    try std.testing.expectEqual(Hardfork.CANCUN, config.hardfork);
    
    const flags = config.get_eip_flags();
    try std.testing.expect(flags.eip3855_push0); // Shanghai EIP
    try std.testing.expect(flags.eip1153_transient_storage); // Cancun EIP
    try std.testing.expect(flags.eip6780_selfdestruct_restriction); // Cancun EIP
}

test "EvmConfig - L2 configurations" {
    // Test Optimism config
    {
        var config = EvmConfig.optimism();
        try std.testing.expectEqual(@as(u64, 10), config.chain_id);
        try std.testing.expect(config.is_l2());
        try std.testing.expect(!config.is_testnet());
        
        // Check Optimism-specific overrides are applied
        try std.testing.expect(config.is_eip_enabled(3198)); // BASEFEE
        try std.testing.expect(config.is_eip_enabled(1559)); // Fee market
    }
    
    // Test Polygon config
    {
        var config = EvmConfig.polygon();
        try std.testing.expectEqual(@as(u64, 137), config.chain_id);
        try std.testing.expect(config.is_l2());
        
        // Check Polygon-specific overrides
        try std.testing.expect(!config.is_eip_enabled(1559)); // No EIP-1559
    }
}

test "EvmConfig - testnet configurations" {
    var config = EvmConfig.SEPOLIA;
    try std.testing.expectEqual(@as(u64, 11155111), config.chain_id);
    try std.testing.expect(config.is_testnet());
    try std.testing.expect(!config.is_l2());
}

test "EvmConfig - builder pattern" {
    var config = EvmConfig.from_hardfork(.BERLIN)
        .with_chain_id(12345)
        .enable_eips(&.{ 3855, 1153 }) // Add PUSH0 and transient storage
        .disable_eips(&.{2929}); // Remove Berlin EIP
    
    try std.testing.expectEqual(@as(u64, 12345), config.chain_id);
    try std.testing.expect(config.is_eip_enabled(3855)); // PUSH0 added
    try std.testing.expect(config.is_eip_enabled(1153)); // Transient storage added
    try std.testing.expect(!config.is_eip_enabled(2929)); // Gas costs disabled
}

test "EvmConfig - gas cost overrides" {
    const custom_overrides = EipOverrides{
        .gas_costs = GasCostOverrides{
            .sstore_set = 12345,
            .call_base = 999,
        },
    };
    
    const config = EvmConfig.with_overrides(.CANCUN, custom_overrides);
    
    try std.testing.expectEqual(@as(u64, 12345), config.get_gas_cost("sstore_set"));
    try std.testing.expectEqual(@as(u64, 999), config.get_gas_cost("call_base"));
    try std.testing.expectEqual(@as(u64, 32000), config.get_gas_cost("create_base")); // Default
}

test "EvmConfig - EIP flag caching" {
    var config = EvmConfig.mainnet(.SHANGHAI);
    
    // First call computes flags
    const flags1 = config.get_eip_flags();
    try std.testing.expect(flags1.eip3855_push0);
    
    // Second call should return cached value
    const flags2 = config.get_eip_flags();
    try std.testing.expectEqual(flags1, flags2);
    
    // Modifying config should invalidate cache
    config = config.enable_eips(&.{1153});
    const flags3 = config.get_eip_flags();
    try std.testing.expect(flags3.eip1153_transient_storage);
}