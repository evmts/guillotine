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

    /// Frame configuration parameters (database now always enabled)
    frame_config: FrameConfig = .{ .DatabaseType = @import("database.zig").Database },

    /// Enable precompiled contracts support (default: true)
    /// When disabled, precompile calls will fail with an error
    enable_precompiles: bool = true,

    /// Planner strategy for bytecode analysis and optimization (default: minimal)
    /// Note: When compiling with -Doptimize=ReleaseSmall, this is always forced to .minimal
    /// regardless of the configured value to minimize binary size.
    // planner_strategy: PlannerStrategy = .minimal,

    /// Block information configuration
    /// Controls the types used for difficulty and base_fee fields
    block_info_config: BlockInfoConfig = .{},

    /// Enable bytecode fusion optimizations (default: true)
    /// When enabled, common opcode patterns like PUSH+ADD are fused into single operations
    enable_fusion: bool = true,

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
