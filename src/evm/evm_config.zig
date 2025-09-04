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

    /// Custom opcode handlers (sparse array - null means use default handler)
    /// Each entry corresponds to an opcode value (0-255)
    /// Example: custom_opcode_handlers[0xfe] = &myDebugHandler
    /// TODO: Define proper function signature - currently uses anytype for minimal implementation
    custom_opcode_handlers: ?[256]?*const anyopaque = null,

    // TODO: Add custom call type support in future iteration
    // /// Custom call types to extend CallParams beyond standard EVM calls
    // /// Example use cases: meta-transactions, account abstraction, custom precompiles
    // CustomCallTypes: ?type = null,
    // 
    // /// Handlers for custom call types (must implement executeCustomCall interface)
    // custom_call_handlers: ?type = null,

    /// Computed frame configuration from the fields above
    pub fn frame_config(self: EvmConfig) FrameConfig {
        return .{
            .stack_size = self.stack_size,
            .WordType = self.WordType,
            .max_bytecode_size = self.max_bytecode_size,
            .max_initcode_size = self.max_initcode_size,
            .block_gas_limit = self.block_gas_limit,
            .memory_initial_capacity = self.memory_initial_capacity,
            .memory_limit = self.memory_limit,
            .DatabaseType = self.DatabaseType,
            .TracerType = self.TracerType,
            .block_info_config = self.block_info_config,
        };
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

test "EvmConfig - custom opcode handlers basic structure" {
    // Test basic structure for custom opcode handlers
    // This is a minimal proof of concept showing the API design
    
    const config = EvmConfig{
        .custom_opcode_handlers = null, // Default - no custom handlers
    };
    
    try testing.expectEqual(@as(?[256]?*const anyopaque, null), config.custom_opcode_handlers);
    
    // TODO: Test with actual custom handlers once implementation is complete
    // Example of what the future API would look like:
    //
    // const myCustomHandler = struct {
    //     fn debugOpcode(frame: *Frame, cursor: [*]const Dispatch.Item) Frame.Error!noreturn {
    //         // Custom debug opcode at 0xfe
    //         return frame.next(cursor);
    //     }
    // }.debugOpcode;
    //
    // var custom_handlers = [_]?*const anyopaque{null} ** 256;
    // custom_handlers[0xfe] = &myCustomHandler;
    //
    // const config_with_custom = EvmConfig{
    //     .custom_opcode_handlers = custom_handlers,
    // };
}
