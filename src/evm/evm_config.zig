const std = @import("std");
// const PlannerStrategy = @import("planner_strategy.zig").PlannerStrategy;
const FrameConfig = @import("frame_config.zig").FrameConfig;
const BlockInfoConfig = @import("block_info_config.zig").BlockInfoConfig;
const Eips = @import("eips.zig").Eips;
const Hardfork = @import("hardfork.zig").Hardfork;

pub const EvmConfig = struct {
    // TODO update enum to support latest hardfork
    // Comptime known configuration of Eip and hardfork information
    eips: Eips = Eips{ .hardfork = Hardfork.CANCUN },

    /// Maximum call depth allowed in the EVM (defaults to 1024 levels)
    /// This prevents infinite recursion and stack overflow attacks
    max_call_depth: u11 = 1024,

    /// Maximum input size for interpreter operations (128 KB)
    /// This prevents excessive memory usage in single operations
    max_input_size: u18 = 131072, // 128 KB

    /// Enable precompiled contracts support (default: true)
    /// When disabled, precompile calls will fail with an error
    enable_precompiles: bool = true,

    /// Enable bytecode fusion optimizations (default: true)
    /// When enabled, common opcode patterns like PUSH+ADD are fused into single operations
    enable_fusion: bool = true,

    // Frame configuration fields (previously nested)
    /// The maximum stack size for the evm. Defaults to 1024
    stack_size: u12 = 1024,
    /// The size of a single word in the EVM - Defaults to u256
    WordType: type = u256,
    /// The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,
    /// The maximum amount of bytes allowed in contract deployment
    max_initcode_size: u32 = 49152,
    /// The maximum gas limit for a block
    block_gas_limit: u64 = 30_000_000,
    /// Memory configuration
    memory_initial_capacity: usize = 4096,
    memory_limit: u64 = 0xFFFFFF,
    /// Database implementation type for storage operations (always required)
    DatabaseType: type = @import("database.zig").Database,
    /// Tracer type for execution tracing (default: null for no tracing)
    /// Set to a tracer type (e.g., JSONRPCTracer) to enable execution tracing
    TracerType: ?type = null,
    
    /// Block information configuration
    /// Controls the types used for difficulty and base_fee fields
    block_info_config: BlockInfoConfig = .{},

    // Journal configuration fields (consolidating from JournalConfig)
    /// Initial capacity for journal entries
    journal_initial_capacity: usize = 128,
    /// Type used for nonces
    NonceType: type = u64,
    /// Whether to use data-oriented design for entries
    journal_use_soa: bool = false,


    // Computed type methods (consolidating from FrameConfig)
    /// PcType: chosen PC integer type from max_bytecode_size
    pub fn PcType(comptime self: @This()) type {
        return if (self.max_bytecode_size <= std.math.maxInt(u8))
            u8
        else if (self.max_bytecode_size <= std.math.maxInt(u12))
            u12
        else if (self.max_bytecode_size <= std.math.maxInt(u16))
            u16
        else if (self.max_bytecode_size <= std.math.maxInt(u32))
            u32
        else
            @compileError("Bytecode size too large! It must have under u32 bytes");
    }
    
    /// StackIndexType: minimal integer type to index the configured stack
    pub fn StackIndexType(comptime self: @This()) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
        else if (self.stack_size <= std.math.maxInt(u8))
            u8
        else if (self.stack_size <= std.math.maxInt(u12))
            u12
        else
            @compileError("EvmConfig stack_size is too large! It must fit in a u12 bytes");
    }
    
    /// GasType: minimal signed integer type to track gas remaining
    pub fn GasType(comptime self: @This()) type {
        return if (self.block_gas_limit <= std.math.maxInt(i32))
            i32
        else
            i64;
    }

    /// SnapshotIdType: optimal type for journal snapshot IDs based on max_call_depth
    pub fn SnapshotIdType(comptime self: @This()) type {
        return if (self.max_call_depth <= std.math.maxInt(u8))
            u8
        else if (self.max_call_depth <= std.math.maxInt(u16))
            u16
        else
            u32;
    }

    /// Validates the consolidated configuration at compile time
    pub fn validate(comptime self: @This()) void {
        // Frame configuration validation (consolidated from FrameConfig)
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
        if (self.max_bytecode_size > 65535) @compileError("max_bytecode_size must be at most 65535");
        
        // Journal configuration validation
        const snapshot_info = @typeInfo(self.SnapshotIdType());
        if (snapshot_info != .int or snapshot_info.int.signedness != .unsigned) {
            @compileError("SnapshotIdType must be an unsigned integer");
        }
        
        const word_info = @typeInfo(self.WordType);
        if (word_info != .int or word_info.int.signedness != .unsigned) {
            @compileError("WordType must be an unsigned integer");
        }
        
        const nonce_info = @typeInfo(self.NonceType);
        if (nonce_info != .int or nonce_info.int.signedness != .unsigned) {
            @compileError("NonceType must be an unsigned integer");
        }
        
        if (self.journal_initial_capacity == 0) {
            @compileError("journal_initial_capacity must be greater than 0");
        }
        
        // Block info configuration validation
        self.block_info_config.validate();
    }

    /// Gets the appropriate type for depth based on max_call_depth
    pub fn get_depth_type(self: EvmConfig) type {
        return if (self.max_call_depth <= std.math.maxInt(u8))
            u8
        else if (self.max_call_depth <= std.math.maxInt(u11))
            u11
        else
            @compileError("max_call_depth too large");
    }

    /// Predefined configuration optimized for performance
    /// Uses advanced planner strategy for maximum optimization
    pub fn optimizeFast() EvmConfig {
        return EvmConfig{
            // .planner_strategy = .advanced,
        };
    }

    /// Predefined configuration optimized for binary size
    /// Uses minimal planner strategy to reduce executable size
    pub fn optimizeSmall() EvmConfig {
        return EvmConfig{
            // .planner_strategy = .minimal,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "EvmConfig - default initialization" {
    const config = EvmConfig{};
    
    try testing.expectEqual(Hardfork.CANCUN, config.eips.hardfork);
    try testing.expectEqual(@as(u11, 1024), config.max_call_depth);
    try testing.expectEqual(@as(u18, 131072), config.max_input_size);
    try testing.expectEqual(true, config.enable_precompiles);
    try testing.expectEqual(true, config.enable_fusion);
    try testing.expectEqual(@as(?type, null), config.TracerType);
}

test "EvmConfig - custom configuration" {
    const config = EvmConfig{
        .eips = Eips{ .hardfork = Hardfork.BERLIN },
        .max_call_depth = 512,
        .max_input_size = 65536,
        .enable_precompiles = false,
        .enable_fusion = false,
    };
    
    try testing.expectEqual(Hardfork.BERLIN, config.eips.hardfork);
    try testing.expectEqual(@as(u11, 512), config.max_call_depth);
    try testing.expectEqual(@as(u18, 65536), config.max_input_size);
    try testing.expectEqual(false, config.enable_precompiles);
    try testing.expectEqual(false, config.enable_fusion);
}

test "EvmConfig - get_depth_type" {
    const config_u8 = EvmConfig{ .max_call_depth = 255 };
    try testing.expectEqual(u8, config_u8.get_depth_type());
    
    const config_u11 = EvmConfig{ .max_call_depth = 1024 };
    try testing.expectEqual(u11, config_u11.get_depth_type());
    
    // Test boundary values
    const config_boundary = EvmConfig{ .max_call_depth = 256 };
    try testing.expectEqual(u11, config_boundary.get_depth_type());
}

test "EvmConfig - depth type edge cases" {
    const config_min = EvmConfig{ .max_call_depth = 1 };
    try testing.expectEqual(u8, config_min.get_depth_type());
    
    const config_max_u8 = EvmConfig{ .max_call_depth = 255 };
    try testing.expectEqual(u8, config_max_u8.get_depth_type());
    
    const config_beyond_u8 = EvmConfig{ .max_call_depth = 256 };
    try testing.expectEqual(u11, config_beyond_u8.get_depth_type());
    
    const config_max_u11 = EvmConfig{ .max_call_depth = 2047 };
    try testing.expectEqual(u11, config_max_u11.get_depth_type());
}

test "EvmConfig - optimizeFast configuration" {
    const config = EvmConfig.optimizeFast();
    
    // Should have default values since planner_strategy is commented out
    try testing.expectEqual(Hardfork.CANCUN, config.eips.hardfork);
    try testing.expectEqual(@as(u11, 1024), config.max_call_depth);
    try testing.expectEqual(true, config.enable_fusion);
}

test "EvmConfig - optimizeSmall configuration" {
    const config = EvmConfig.optimizeSmall();
    
    // Should have default values since planner_strategy is commented out
    try testing.expectEqual(Hardfork.CANCUN, config.eips.hardfork);
    try testing.expectEqual(@as(u11, 1024), config.max_call_depth);
    try testing.expectEqual(true, config.enable_fusion);
}

test "EvmConfig - hardfork variations" {
    const configs = [_]EvmConfig{
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.FRONTIER } },
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.HOMESTEAD } },
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.BYZANTIUM } },
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.BERLIN } },
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.LONDON } },
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.SHANGHAI } },
        EvmConfig{ .eips = Eips{ .hardfork = Hardfork.CANCUN } },
    };
    
    for (configs) |config| {
        // All should have same default non-hardfork settings
        try testing.expectEqual(@as(u11, 1024), config.max_call_depth);
        try testing.expectEqual(true, config.enable_precompiles);
    }
}

test "EvmConfig - max input size variations" {
    const small_config = EvmConfig{ .max_input_size = 1024 };
    try testing.expectEqual(@as(u18, 1024), small_config.max_input_size);
    
    const large_config = EvmConfig{ .max_input_size = 262144 }; // 256 KB
    try testing.expectEqual(@as(u18, 262144), large_config.max_input_size);
    
    // Test maximum value for u18
    const max_config = EvmConfig{ .max_input_size = 262143 }; // 2^18 - 1
    try testing.expectEqual(@as(u18, 262143), max_config.max_input_size);
}

test "EvmConfig - call depth limits" {
    const minimal_depth = EvmConfig{ .max_call_depth = 1 };
    try testing.expectEqual(@as(u11, 1), minimal_depth.max_call_depth);
    
    const standard_depth = EvmConfig{ .max_call_depth = 1024 };
    try testing.expectEqual(@as(u11, 1024), standard_depth.max_call_depth);
    
    const max_depth = EvmConfig{ .max_call_depth = 2047 }; // Maximum u11 value
    try testing.expectEqual(@as(u11, 2047), max_depth.max_call_depth);
}

test "EvmConfig - precompiles and fusion combinations" {
    const configs = [_]EvmConfig{
        EvmConfig{ .enable_precompiles = true, .enable_fusion = true },
        EvmConfig{ .enable_precompiles = true, .enable_fusion = false },
        EvmConfig{ .enable_precompiles = false, .enable_fusion = true },
        EvmConfig{ .enable_precompiles = false, .enable_fusion = false },
    };
    
    try testing.expectEqual(true, configs[0].enable_precompiles);
    try testing.expectEqual(true, configs[0].enable_fusion);
    
    try testing.expectEqual(true, configs[1].enable_precompiles);
    try testing.expectEqual(false, configs[1].enable_fusion);
    
    try testing.expectEqual(false, configs[2].enable_precompiles);
    try testing.expectEqual(true, configs[2].enable_fusion);
    
    try testing.expectEqual(false, configs[3].enable_precompiles);
    try testing.expectEqual(false, configs[3].enable_fusion);
}

test "EvmConfig - tracer type handling" {
    const no_tracer_config = EvmConfig{};
    try testing.expectEqual(@as(?type, null), no_tracer_config.TracerType);
    
    // Test with a dummy tracer type
    const DummyTracer = struct {
        pub fn trace(_: @This()) void {}
    };
    
    const with_tracer_config = EvmConfig{ .TracerType = DummyTracer };
    try testing.expectEqual(DummyTracer, with_tracer_config.TracerType.?);
}

test "EvmConfig - block info config integration" {
    const config = EvmConfig{};
    
    // Default block info config should be initialized
    try testing.expectEqual(BlockInfoConfig{}, config.block_info_config);
}

test "EvmConfig - complete custom configuration" {
    const DummyTracer = struct {};
    
    const config = EvmConfig{
        .eips = Eips{ .hardfork = Hardfork.ISTANBUL },
        .max_call_depth = 2000,
        .max_input_size = 200000,
        .enable_precompiles = false,
        .enable_fusion = false,
        .TracerType = DummyTracer,
    };
    
    try testing.expectEqual(Hardfork.ISTANBUL, config.eips.hardfork);
    try testing.expectEqual(@as(u11, 2000), config.max_call_depth);
    try testing.expectEqual(@as(u18, 200000), config.max_input_size);
    try testing.expectEqual(false, config.enable_precompiles);
    try testing.expectEqual(false, config.enable_fusion);
    try testing.expectEqual(DummyTracer, config.TracerType.?);
    try testing.expectEqual(u11, config.get_depth_type());
}

// =============================================================================
// Tests for Consolidated Configuration Methods (New TDD Tests)
// =============================================================================

test "EvmConfig - PcType computation" {
    // Test PcType selection based on max_bytecode_size
    const config_u8 = EvmConfig{ .max_bytecode_size = 255 };
    try testing.expectEqual(u8, config_u8.PcType());
    
    const config_u12 = EvmConfig{ .max_bytecode_size = 4095 };
    try testing.expectEqual(u12, config_u12.PcType());
    
    const config_u16 = EvmConfig{ .max_bytecode_size = 65535 };
    try testing.expectEqual(u16, config_u16.PcType());
    
    const config_u32 = EvmConfig{ .max_bytecode_size = 1048576 };
    try testing.expectEqual(u32, config_u32.PcType());
    
    // Test boundary values
    const config_boundary_u8 = EvmConfig{ .max_bytecode_size = 256 };
    try testing.expectEqual(u12, config_boundary_u8.PcType());
    
    const config_boundary_u12 = EvmConfig{ .max_bytecode_size = 4096 };
    try testing.expectEqual(u16, config_boundary_u12.PcType());
    
    const config_boundary_u16 = EvmConfig{ .max_bytecode_size = 65536 };
    try testing.expectEqual(u32, config_boundary_u16.PcType());
}

test "EvmConfig - StackIndexType computation" {
    // Test StackIndexType selection based on stack_size
    const config_u4 = EvmConfig{ .stack_size = 15 };
    try testing.expectEqual(u4, config_u4.StackIndexType());
    
    const config_u8 = EvmConfig{ .stack_size = 255 };
    try testing.expectEqual(u8, config_u8.StackIndexType());
    
    const config_u12 = EvmConfig{ .stack_size = 1024 };
    try testing.expectEqual(u12, config_u12.StackIndexType());
    
    // Test boundary values
    const config_boundary_u4 = EvmConfig{ .stack_size = 16 };
    try testing.expectEqual(u8, config_boundary_u4.StackIndexType());
    
    const config_boundary_u8 = EvmConfig{ .stack_size = 256 };
    try testing.expectEqual(u12, config_boundary_u8.StackIndexType());
}

test "EvmConfig - GasType computation" {
    // Test GasType selection based on block_gas_limit
    const config_i32 = EvmConfig{ .block_gas_limit = 2147483647 }; // max i32
    try testing.expectEqual(i32, config_i32.GasType());
    
    const config_i64 = EvmConfig{ .block_gas_limit = 2147483648 }; // max i32 + 1
    try testing.expectEqual(i64, config_i64.GasType());
    
    // Default configuration should use i32
    const config_default = EvmConfig{};
    try testing.expectEqual(i32, config_default.GasType());
}

test "EvmConfig - SnapshotIdType computation" {
    // Test SnapshotIdType selection based on max_call_depth
    const config_u8 = EvmConfig{ .max_call_depth = 255 };
    try testing.expectEqual(u8, config_u8.SnapshotIdType());
    
    const config_u16 = EvmConfig{ .max_call_depth = 1024 };
    try testing.expectEqual(u16, config_u16.SnapshotIdType());
    
    const config_u32 = EvmConfig{ .max_call_depth = 2047 }; // max u11
    try testing.expectEqual(u16, config_u32.SnapshotIdType());
    
    // Test boundary values
    const config_boundary = EvmConfig{ .max_call_depth = 256 };
    try testing.expectEqual(u16, config_boundary.SnapshotIdType());
}

test "EvmConfig - journal configuration fields" {
    const config = EvmConfig{};
    
    // Test default journal configuration values
    try testing.expectEqual(@as(usize, 128), config.journal_initial_capacity);
    try testing.expectEqual(u64, config.NonceType);
    try testing.expectEqual(false, config.journal_use_soa);
    
    // Test custom journal configuration
    const custom_config = EvmConfig{
        .journal_initial_capacity = 256,
        .NonceType = u32,
        .journal_use_soa = true,
    };
    
    try testing.expectEqual(@as(usize, 256), custom_config.journal_initial_capacity);
    try testing.expectEqual(u32, custom_config.NonceType);
    try testing.expectEqual(true, custom_config.journal_use_soa);
}

test "EvmConfig - consolidated configuration equivalence" {
    // Test that consolidated config produces equivalent behavior to separate configs
    const config = EvmConfig{
        .stack_size = 512,
        .max_bytecode_size = 1024,
        .block_gas_limit = 15000000,
        .max_call_depth = 128,
    };
    
    // Verify computed types match expected values
    try testing.expectEqual(u12, config.PcType());      // 1024 > u8, fits in u12
    try testing.expectEqual(u12, config.StackIndexType()); // 512 > u8, fits in u12  
    try testing.expectEqual(i32, config.GasType());     // 15M < i32 max
    try testing.expectEqual(u8, config.SnapshotIdType()); // 128 < u8 max
}

test "EvmConfig - edge case type computations" {
    // Test exact boundary values that trigger type changes
    const boundary_config = EvmConfig{
        .stack_size = 15,           // Exactly max u4
        .max_bytecode_size = 255,   // Exactly max u8
        .block_gas_limit = 2147483647, // Exactly max i32
        .max_call_depth = 255,      // Exactly max u8
    };
    
    try testing.expectEqual(u4, boundary_config.StackIndexType());
    try testing.expectEqual(u8, boundary_config.PcType());
    try testing.expectEqual(i32, boundary_config.GasType());
    try testing.expectEqual(u8, boundary_config.SnapshotIdType());
    
    // Test one beyond boundary values
    const beyond_boundary_config = EvmConfig{
        .stack_size = 16,           // One beyond max u4
        .max_bytecode_size = 256,   // One beyond max u8
        .block_gas_limit = 2147483648, // One beyond max i32
        .max_call_depth = 256,      // One beyond max u8
    };
    
    try testing.expectEqual(u8, beyond_boundary_config.StackIndexType());
    try testing.expectEqual(u12, beyond_boundary_config.PcType());
    try testing.expectEqual(i64, beyond_boundary_config.GasType());
    try testing.expectEqual(u16, beyond_boundary_config.SnapshotIdType());
}

test "EvmConfig - complete consolidation without frame_config method" {
    // Test that we can create an EVM directly with EvmConfig without frame_config() method
    const config = EvmConfig{
        .stack_size = 512,
        .max_bytecode_size = 4096,
        .block_gas_limit = 25000000,
        .max_call_depth = 512,
        .journal_initial_capacity = 256,
        .NonceType = u32,
        .journal_use_soa = true,
    };
    
    // Verify config validates
    config.validate();
    
    // Verify all computed types work correctly
    try testing.expectEqual(u12, config.PcType());
    try testing.expectEqual(u12, config.StackIndexType());
    try testing.expectEqual(i32, config.GasType());
    try testing.expectEqual(u16, config.SnapshotIdType());
    
    // Verify journal configuration is accessible
    try testing.expectEqual(@as(usize, 256), config.journal_initial_capacity);
    try testing.expectEqual(u32, config.NonceType);
    try testing.expectEqual(true, config.journal_use_soa);
}

test "EvmConfig - validation tests" {
    // Test that default config validates
    const default_config = EvmConfig{};
    default_config.validate();
    
    // Test custom valid config validates
    const custom_config = EvmConfig{
        .stack_size = 1000,
        .max_bytecode_size = 20000,
        .block_gas_limit = 50000000,
        .max_call_depth = 2000,
        .journal_initial_capacity = 512,
        .NonceType = u32,
    };
    custom_config.validate();
}
