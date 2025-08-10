const std = @import("std");
const builtin = @import("builtin");
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const Stack = @import("stack/stack.zig");
const operation_config = @import("opcode_metadata/operation_config.zig");
const operation_module = @import("opcodes/operation.zig");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const execution = @import("execution/package.zig");

// Import new EIP configuration modules
const eip_flags = @import("config/eip_flags.zig");
const overrides = @import("config/overrides.zig");
pub const EipFlags = eip_flags.EipFlags;
pub const EipOverrides = overrides.EipOverrides;
pub const GasCostOverrides = overrides.GasCostOverrides;
pub const ChainBehavior = overrides.ChainBehavior;

/// Centralized configuration for the EVM runtime.
/// 
/// This struct consolidates all scattered configuration constants and provides
/// compile-time configuration management with zero runtime overhead. All fields
/// are evaluated at compile time, allowing for optimal code generation.
pub const EvmConfig = struct {
    // Execution limits
    max_call_depth: u11 = 1024,
    max_stack_depth: usize = 1024,  // EVM stack depth limit
    max_stack_buffer_size: usize = 43008,
    stack_allocation_threshold: usize = 12800,
    max_input_size: u18 = 128 * 1024,
    max_iterations: usize = 10_000_000,
    max_frame_size: usize = 1024,  // Maximum frame struct size in bytes
    analysis_cache_size: usize = 128,  // LRU cache size for code analysis
    
    // Memory configuration  
    memory_limit: u64 = 32 * 1024 * 1024, // 32MB
    initial_memory_capacity: usize = 4096,
    
    // Runtime behavior flags
    clear_on_pop: bool = builtin.mode != .ReleaseFast,
    optional_balance_check: bool = false,  // Disable balance validation for testing
    optional_nonce_check: bool = false,    // Disable nonce validation for testing  
    optional_base_fee: bool = false,       // Disable EIP-1559 base fee for testing
    
    // Chain configuration  
    chain_id: u64 = 1, // Mainnet default
    
    // Hardfork specification
    hardfork: Hardfork = .CANCUN,
    
    // EIP overrides for L2s and custom chains
    eip_overrides: ?EipOverrides = null,
    
    // Opcode metadata
    opcodes: @import("opcode_metadata/opcode_metadata.zig").OpcodeMetadata,
    
    /// Initialize config for specific hardfork
    pub fn init(comptime hardfork: Hardfork) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .opcodes = @import("opcode_metadata/opcode_metadata.zig").OpcodeMetadata.init_from_hardfork(hardfork),
        };
    }
    
    /// Initialize config with L2 overrides
    pub fn initWithOverrides(comptime hardfork: Hardfork, comptime eip_overrides: EipOverrides) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .eip_overrides = eip_overrides,
            .opcodes = blk: {
                const tmp = EvmConfig{
                    .hardfork = hardfork,
                    .eip_overrides = eip_overrides,
                    .opcodes = undefined,
                };
                const flags = tmp.getEipFlags();
                break :blk @import("opcode_metadata/opcode_metadata.zig").OpcodeMetadata.init_from_eip_flags(flags);
            },
        };
    }
    
    /// Initialize with optional features for testing
    pub fn initWithFeatures(
        comptime hardfork: Hardfork,
        comptime features: struct {
            optional_balance_check: bool = false,
            optional_nonce_check: bool = false,
            optional_base_fee: bool = false,
        }
    ) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .opcodes = @import("opcode_metadata/opcode_metadata.zig").OpcodeMetadata.init_from_hardfork(hardfork),
            .optional_balance_check = features.optional_balance_check,
            .optional_nonce_check = features.optional_nonce_check,
            .optional_base_fee = features.optional_base_fee,
        };
    }
    
    /// Calculate initial allocation size based on config
    pub fn calculateInitialSize(comptime self: EvmConfig) usize {
        return self.max_stack_buffer_size + self.initial_memory_capacity;
    }
    
    /// Validate configuration at compile time
    pub fn validate(comptime self: EvmConfig) void {
        if (self.max_call_depth > 1024) @compileError("max_call_depth cannot exceed 1024");
        if (self.max_iterations < 1000) @compileError("max_iterations too low for practical use");
        if (self.memory_limit > 1 << 32) @compileError("memory_limit exceeds 32-bit addressing");
        if (self.chain_id == 0) @compileError("chain_id cannot be zero");
        if (self.max_stack_buffer_size < self.stack_allocation_threshold) {
            @compileError("max_stack_buffer_size must be >= stack_allocation_threshold");
        }
    }
    
    /// Get EIP flags for this configuration
    pub fn getEipFlags(comptime self: EvmConfig) EipFlags {
        var flags = eip_flags.deriveEipFlagsFromHardfork(self.hardfork);
        
        // Apply optional base fee override
        if (self.optional_base_fee) {
            flags.eip1559_base_fee = false;
            flags.eip3198_basefee = false;
        }
        
        // Apply L2/custom overrides if present
        if (self.eip_overrides) |eip_overrides| {
            overrides.applyOverrides(&flags, eip_overrides);
        }
        
        return flags;
    }
    
    /// Check if specific EIP is enabled for this configuration  
    pub fn hasEip(comptime self: EvmConfig, comptime eip: u16) bool {
        const flags = self.getEipFlags();
        return flags.isEnabled(eip);
    }
    
    /// Get gas cost for operation considering hardfork
    pub fn getGasCost(comptime self: EvmConfig, comptime op: GasOperation) u64 {
        return switch (op) {
            .sload => if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.BERLIN)) 0 
                      else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.ISTANBUL)) 800
                      else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.TANGERINE_WHISTLE)) 200
                      else 50,
            .balance => if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.BERLIN)) 0
                        else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.ISTANBUL)) 700
                        else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.TANGERINE_WHISTLE)) 400
                        else 20,
            else => op.base_cost(),
        };
    }
    
    // Predefined configurations  
    pub const DEFAULT = init(.CANCUN);
    
    pub const DEBUG = blk: {
        var config = init(.CANCUN);
        config.optional_balance_check = true;
        config.optional_nonce_check = true;
        config.clear_on_pop = true;
        break :blk config;
    };
    
    pub const PERFORMANCE = blk: {
        var config = init(.CANCUN);
        config.clear_on_pop = false;
        break :blk config;
    };
    
    pub const TESTING = initWithFeatures(.CANCUN, .{ 
        .optional_balance_check = true,
        .optional_nonce_check = true,
        .optional_base_fee = true,
    });
    
    pub const MINIMAL = blk: {
        var config = init(.FRONTIER);
        config.memory_limit = 1024 * 1024; // 1MB
        config.max_iterations = 100_000;
        break :blk config;
    };
    
    // L2 configurations
    pub const OPTIMISM = initWithOverrides(.CANCUN, EipOverrides.OPTIMISM);
    pub const POLYGON = initWithOverrides(.CANCUN, EipOverrides.POLYGON);
    pub const ARBITRUM = initWithOverrides(.CANCUN, EipOverrides.ARBITRUM);
    pub const BASE = initWithOverrides(.CANCUN, EipOverrides.BASE);
    pub const ZKSYNC = initWithOverrides(.CANCUN, EipOverrides.ZKSYNC);
};

/// Enum for gas operation types
pub const GasOperation = enum {
    sload,
    balance,
    extcodesize,
    extcodecopy,
    extcodehash,
    
    pub fn base_cost(self: GasOperation) u64 {
        return switch (self) {
            .sload => 50,
            .balance => 20,
            .extcodesize => 20,
            .extcodecopy => 20,
            .extcodehash => 400,
        };
    }
};

/// CPU cache line size for optimal memory alignment.
/// Most modern x86/ARM processors use 64-byte cache lines.
const CACHE_LINE_SIZE = 64;

    // Remove the local OpcodeMetadata definition; use the canonical one from opcode_metadata module

test "EvmConfig validation" {
    const testing = std.testing;
    
    // Test default config
    const default_config = EvmConfig.DEFAULT;
    try testing.expectEqual(@as(u11, 1024), default_config.max_call_depth);
    try testing.expectEqual(@as(u64, 1), default_config.chain_id);
    try testing.expectEqual(Hardfork.CANCUN, default_config.hardfork);
    
    // Test debug config
    const debug_config = EvmConfig.DEBUG;
    try testing.expect(debug_config.optional_balance_check);
    try testing.expect(debug_config.optional_nonce_check);
    try testing.expect(debug_config.clear_on_pop);
    
    // Test testing config
    const test_config = EvmConfig.TESTING;
    try testing.expect(test_config.optional_balance_check);
    try testing.expect(test_config.optional_nonce_check);
    try testing.expect(test_config.optional_base_fee);
    
    // Test minimal config
    const minimal_config = EvmConfig.MINIMAL;
    try testing.expectEqual(@as(u64, 1024 * 1024), minimal_config.memory_limit);
    try testing.expectEqual(@as(usize, 100_000), minimal_config.max_iterations);
    try testing.expectEqual(Hardfork.FRONTIER, minimal_config.hardfork);
}

test "EvmConfig compile-time validation" {
    // This should compile successfully
    const valid_config = EvmConfig.init(.CANCUN);
    comptime valid_config.validate();
    
    // Test that calculateInitialSize works
    const initial_size = comptime valid_config.calculateInitialSize();
    try std.testing.expect(initial_size > 0);
}

test "EIP detection" {
    const testing = std.testing;
    
    const cancun_config = EvmConfig.init(.CANCUN);
    try testing.expect(comptime cancun_config.hasEip(155));  // SPURIOUS_DRAGON
    try testing.expect(comptime cancun_config.hasEip(1014)); // CONSTANTINOPLE
    try testing.expect(comptime cancun_config.hasEip(1559)); // LONDON
    try testing.expect(comptime cancun_config.hasEip(3855)); // SHANGHAI
    try testing.expect(comptime cancun_config.hasEip(4844)); // CANCUN
    
    const frontier_config = EvmConfig.init(.FRONTIER);
    try testing.expect(!comptime frontier_config.hasEip(155));
    try testing.expect(!comptime frontier_config.hasEip(1014));
    try testing.expect(!comptime frontier_config.hasEip(1559));
    
    // Test optional base fee disabling
    const no_base_fee = EvmConfig.initWithFeatures(.LONDON, .{ .optional_base_fee = true });
    try testing.expect(!comptime no_base_fee.hasEip(1559));
}

test "Gas cost calculation" {
    const testing = std.testing;
    
    const cancun_config = EvmConfig.init(.CANCUN);
    const frontier_config = EvmConfig.init(.FRONTIER);
    
    // SLOAD gas costs
    try testing.expectEqual(@as(u64, 0), comptime cancun_config.getGasCost(.sload));
    try testing.expectEqual(@as(u64, 50), comptime frontier_config.getGasCost(.sload));
    
    // BALANCE gas costs
    try testing.expectEqual(@as(u64, 0), comptime cancun_config.getGasCost(.balance));
    try testing.expectEqual(@as(u64, 20), comptime frontier_config.getGasCost(.balance));
}