const std = @import("std");
// const PlannerStrategy = @import("planner_strategy.zig").PlannerStrategy;
const FrameConfig = @import("frame/frame_config.zig").FrameConfig;
const BlockInfoConfig = @import("frame/block_info_config.zig").BlockInfoConfig;
const Eips = @import("eips_and_hardforks/eips.zig").Eips;
const Hardfork = @import("eips_and_hardforks/hardfork.zig").Hardfork;
const primitives = @import("primitives");
const Address = primitives.Address;
const NoOpTracer = @import("tracer/tracer.zig").NoOpTracer;

/// Custom opcode handler override
pub const OpcodeOverride = struct {
    opcode: u8,
    handler: *const anyopaque,
};

/// Custom precompile implementation
pub const PrecompileOverride = struct {
    address: Address,
    execute: *const fn (allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!PrecompileOutput,
};

/// Precompile output result (duplicated here to avoid circular dependency)
pub const PrecompileOutput = struct {
    output: []const u8,
    gas_used: u64,
    success: bool,
};

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

    /// Disable gas checks for testing/development (default: false)
    /// When enabled, gas consumption methods become no-ops
    /// WARNING: Only use for testing, never in production
    disable_gas_checks: bool = false,

    /// Disable balance checks for testing/development (default: false)
    /// When enabled, balance checks always return 0
    /// WARNING: Only use for testing, never in production
    disable_balance_checks: bool = false,

    /// Disable fusion optimizations (default: false)
    /// When enabled, bytecode fusion handlers are not registered
    /// WARNING: Only use for testing/debugging
    disable_fusion: bool = false,

    /// SIMD vector length for optimized memory operations
    /// Auto-detected based on target CPU, or explicitly set for testing
    /// Value of 1 disables SIMD and uses scalar operations
    vector_length: comptime_int = 0, // 0 means auto-detect

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

    /// Arena allocator configuration
    /// Initial and maximum retained capacity for the arena allocator (in bytes)
    /// Default: 64MB - optimized for complex EVM operations and modern hardware
    arena_capacity_limit: usize = 64 * 1024 * 1024,
    /// Growth factor for arena allocator (as percentage, e.g., 150 = 50% growth)
    arena_growth_factor: u32 = 150,
    /// Database implementation type for storage operations (always required)
    DatabaseType: type = @import("storage/database.zig").Database,
    /// Tracer type for execution tracing (default: NoOpTracer for zero overhead)
    /// Set to a tracer type (e.g., JSONRPCTracer) to enable execution tracing
    TracerType: type = NoOpTracer,

    /// Block information configuration
    /// Controls the types used for difficulty and base_fee fields
    block_info_config: BlockInfoConfig = .{},

    /// Custom opcode handler overrides
    /// These will override the default handlers in frame_handlers.zig
    /// Set to empty slice for no overrides
    opcode_overrides: []const OpcodeOverride = &.{},

    /// Custom precompile implementations
    /// These will override or add new precompiles
    /// Set to empty slice for no overrides
    precompile_overrides: []const PrecompileOverride = &.{},

    /// Get the effective SIMD vector length for the current target
    pub fn getVectorLength(self: EvmConfig) comptime_int {
        if (self.vector_length > 0) {
            return self.vector_length;
        }
        // Auto-detect based on target CPU
        const target = @import("builtin").target;
        return std.simd.suggestVectorLengthForCpu(u8, target.cpu) orelse 1;
    }

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
            .disable_gas_checks = self.disable_gas_checks,
            .disable_balance_checks = self.disable_balance_checks,
            .disable_fusion = self.disable_fusion,
            .vector_length = self.getVectorLength(),
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

    /// Generate configuration from build options
    pub fn fromBuildOptions() EvmConfig {
        const build_options = @import("build_options");
        const optimize_str = build_options.optimize_strategy;
        
        // Base configuration from optimization strategy
        var config = if (std.mem.eql(u8, optimize_str, "fast"))
            EvmConfig.optimizeFast()
        else if (std.mem.eql(u8, optimize_str, "small"))
            EvmConfig.optimizeSmall()
        else
            EvmConfig{}; // safe/default
        
        // Apply build options
        config.eips = Eips{ .hardfork = getHardforkFromString(build_options.hardfork) };
        config.max_call_depth = build_options.max_call_depth;
        config.stack_size = build_options.stack_size;
        config.max_bytecode_size = build_options.max_bytecode_size;
        config.max_initcode_size = build_options.max_initcode_size;
        config.block_gas_limit = build_options.block_gas_limit;
        config.memory_initial_capacity = build_options.memory_initial_capacity;
        config.memory_limit = build_options.memory_limit;
        config.arena_capacity_limit = build_options.arena_capacity_limit;
        config.enable_fusion = build_options.enable_fusion and !build_options.disable_fusion;
        config.enable_precompiles = !build_options.no_precompiles;
        config.disable_gas_checks = build_options.disable_gas_checks;
        config.disable_balance_checks = build_options.disable_balance_checks;
        config.disable_fusion = build_options.disable_fusion;
        
        // Set tracer if enabled
        if (build_options.enable_tracing) {
            // For now, we'll leave TracerType as null since it requires more complex setup
            // Users can still set up their own tracer through the configuration
            config.TracerType = null;
        }
        
        return config;
    }

    /// Get the hardfork enum from a string
    fn getHardforkFromString(hardfork_str: []const u8) Hardfork {
        if (std.mem.eql(u8, hardfork_str, "FRONTIER")) return .FRONTIER;
        if (std.mem.eql(u8, hardfork_str, "HOMESTEAD")) return .HOMESTEAD;
        if (std.mem.eql(u8, hardfork_str, "BYZANTIUM")) return .BYZANTIUM;
        if (std.mem.eql(u8, hardfork_str, "ISTANBUL")) return .ISTANBUL;
        if (std.mem.eql(u8, hardfork_str, "BERLIN")) return .BERLIN;
        if (std.mem.eql(u8, hardfork_str, "LONDON")) return .LONDON;
        if (std.mem.eql(u8, hardfork_str, "SHANGHAI")) return .SHANGHAI;
        if (std.mem.eql(u8, hardfork_str, "CANCUN")) return .CANCUN;
        
        // Default to CANCUN if unknown
        return .CANCUN;
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
    try testing.expectEqual(false, config.disable_gas_checks);
    try testing.expectEqual(false, config.disable_balance_checks);
    try testing.expectEqual(NoOpTracer, config.TracerType);
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

    inline for (configs) |config| {
        // All should have same default non-hardfork settings
        try testing.expectEqual(@as(u11, 1024), config.max_call_depth);
        try testing.expectEqual(true, config.enable_precompiles);
    }
}

test "EvmConfig - max input size variations" {
    const small_config = EvmConfig{ .max_input_size = 1024 };
    try testing.expectEqual(@as(u18, 1024), small_config.max_input_size);

    // u18 cannot represent 262144 (2^18); use max-1 instead
    const large_config = EvmConfig{ .max_input_size = 262143 }; // 2^18 - 1
    try testing.expectEqual(@as(u18, 262143), large_config.max_input_size);

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
    try testing.expectEqual(NoOpTracer, no_tracer_config.TracerType);

    // Test with a dummy tracer type
    const DummyTracer = struct {
        pub fn trace(_: @This()) void {}
    };

    const with_tracer_config = EvmConfig{ .TracerType = DummyTracer };
    try testing.expectEqual(DummyTracer, with_tracer_config.TracerType);
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
    try testing.expectEqual(DummyTracer, config.TracerType);
    try testing.expectEqual(u11, config.get_depth_type());
}

test "EvmConfig - custom opcode handlers" {
    const frame_handlers = @import("frame/frame_handlers.zig");
    const opcode_data = @import("opcodes/opcode_data.zig");
    const Opcode = opcode_data.Opcode;

    // Create a test frame type
    const TestFrame = struct {
        pub const OpcodeHandler = *const fn (*@This(), cursor: [*]const Dispatch.Item) Error!noreturn;
        pub const Error = error{ TestError, OutOfGas };
        pub const Dispatch = struct {
            pub const Item = u8;
        };

        gas_remaining: u64,
        custom_called: bool,
        invalid_handler_called: bool,
    };

    // Create a custom handler for ADD opcode
    const custom_add = struct {
        fn handler(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = cursor;
            frame.custom_called = true;
            return TestFrame.Error.TestError;
        }
    }.handler;

    // Create a handler for an otherwise invalid opcode (0xFE)
    const custom_invalid = struct {
        fn handler(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = cursor;
            frame.invalid_handler_called = true;
            return TestFrame.Error.TestError;
        }
    }.handler;

    // Test with overrides
    const overrides = [_]struct { opcode: u8, handler: *const anyopaque }{
        .{ .opcode = @intFromEnum(Opcode.ADD), .handler = &custom_add },
        .{ .opcode = 0xFE, .handler = &custom_invalid }, // Invalid opcode
    };

    const handlers = frame_handlers.getOpcodeHandlersWithOverrides(TestFrame, &overrides);

    // Verify ADD was overridden
    try testing.expectEqual(@as(TestFrame.OpcodeHandler, &custom_add), handlers[@intFromEnum(Opcode.ADD)]);

    // Verify invalid opcode 0xFE now has our custom handler
    try testing.expectEqual(@as(TestFrame.OpcodeHandler, &custom_invalid), handlers[0xFE]);

    // Verify other opcodes are not affected (SUB should still have its default)
    try testing.expect(handlers[@intFromEnum(Opcode.SUB)] != &custom_add);
    try testing.expect(handlers[@intFromEnum(Opcode.SUB)] != &custom_invalid);
}

test "EvmConfig - empty opcode overrides" {
    const frame_handlers = @import("frame/frame_handlers.zig");

    const TestFrame = struct {
        pub const OpcodeHandler = *const fn (*@This(), cursor: [*]const Dispatch.Item) Error!noreturn;
        pub const Error = error{OutOfGas};
        pub const Dispatch = struct {
            pub const Item = u8;
        };
        gas_remaining: u64,
    };

    // Test with no overrides
    const handlers_no_override = frame_handlers.getOpcodeHandlers(TestFrame);
    const handlers_empty_override = frame_handlers.getOpcodeHandlersWithOverrides(TestFrame, &.{});

    // Both should produce identical results
    for (0..256) |i| {
        try testing.expectEqual(handlers_no_override[i], handlers_empty_override[i]);
    }
}

test "EvmConfig - multiple opcode overrides" {
    const frame_handlers = @import("frame/frame_handlers.zig");
    const opcode_data = @import("opcodes/opcode_data.zig");
    const Opcode = opcode_data.Opcode;

    const TestFrame = struct {
        pub const OpcodeHandler = *const fn (*@This(), cursor: [*]const Dispatch.Item) Error!noreturn;
        pub const Error = error{ TestError, OutOfGas };
        pub const Dispatch = struct {
            pub const Item = u8;
        };
        last_opcode: u8,
    };

    // Create different handlers for different opcodes
    const handler1 = struct {
        fn h(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = cursor;
            frame.last_opcode = 1;
            return TestFrame.Error.TestError;
        }
    }.h;

    const handler2 = struct {
        fn h(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = cursor;
            frame.last_opcode = 2;
            return TestFrame.Error.TestError;
        }
    }.h;

    const handler3 = struct {
        fn h(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = cursor;
            frame.last_opcode = 3;
            return TestFrame.Error.TestError;
        }
    }.h;

    const overrides = [_]struct { opcode: u8, handler: *const anyopaque }{
        .{ .opcode = @intFromEnum(Opcode.ADD), .handler = &handler1 },
        .{ .opcode = @intFromEnum(Opcode.MUL), .handler = &handler2 },
        .{ .opcode = 0xFC, .handler = &handler3 }, // Invalid opcode
    };

    const handlers = frame_handlers.getOpcodeHandlersWithOverrides(TestFrame, &overrides);

    try testing.expectEqual(@as(TestFrame.OpcodeHandler, &handler1), handlers[@intFromEnum(Opcode.ADD)]);
    try testing.expectEqual(@as(TestFrame.OpcodeHandler, &handler2), handlers[@intFromEnum(Opcode.MUL)]);
    try testing.expectEqual(@as(TestFrame.OpcodeHandler, &handler3), handlers[0xFC]);
}

test "EvmConfig - gas and balance check disabling" {
    const config_default = EvmConfig{};
    try testing.expectEqual(false, config_default.disable_gas_checks);
    try testing.expectEqual(false, config_default.disable_balance_checks);

    const config_gas_disabled = EvmConfig{ .disable_gas_checks = true };
    try testing.expectEqual(true, config_gas_disabled.disable_gas_checks);
    try testing.expectEqual(false, config_gas_disabled.disable_balance_checks);

    const config_balance_disabled = EvmConfig{ .disable_balance_checks = true };
    try testing.expectEqual(false, config_balance_disabled.disable_gas_checks);
    try testing.expectEqual(true, config_balance_disabled.disable_balance_checks);

    const config_both_disabled = EvmConfig{
        .disable_gas_checks = true,
        .disable_balance_checks = true,
    };
    try testing.expectEqual(true, config_both_disabled.disable_gas_checks);
    try testing.expectEqual(true, config_both_disabled.disable_balance_checks);
}

test "EvmConfig - fusion disabling" {
    const config_default = EvmConfig{};
    try testing.expectEqual(false, config_default.disable_fusion);
    try testing.expectEqual(true, config_default.enable_fusion);

    const config_fusion_disabled = EvmConfig{ .disable_fusion = true };
    try testing.expectEqual(true, config_fusion_disabled.disable_fusion);

    const config_all_disabled = EvmConfig{
        .disable_gas_checks = true,
        .disable_balance_checks = true,
        .disable_fusion = true,
    };
    try testing.expectEqual(true, config_all_disabled.disable_gas_checks);
    try testing.expectEqual(true, config_all_disabled.disable_balance_checks);
    try testing.expectEqual(true, config_all_disabled.disable_fusion);
}

test "EvmConfig - precompile overrides" {
    const config = EvmConfig{
        .precompile_overrides = &[_]PrecompileOverride{
            .{
                .address = Address.from_u256(1), // ECRECOVER
                .execute = struct {
                    fn exec(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!PrecompileOutput {
                        _ = allocator;
                        _ = input;
                        _ = gas_limit;
                        return PrecompileOutput{
                            .output = &.{},
                            .gas_used = 3000,
                            .success = true,
                        };
                    }
                }.exec,
            },
            .{
                .address = Address.from_u256(99), // Custom precompile
                .execute = struct {
                    fn exec(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!PrecompileOutput {
                        _ = allocator;
                        _ = input;
                        _ = gas_limit;
                        return PrecompileOutput{
                            .output = &.{0x42},
                            .gas_used = 100,
                            .success = true,
                        };
                    }
                }.exec,
            },
        },
    };

    try testing.expectEqual(@as(usize, 2), config.precompile_overrides.len);
    try testing.expectEqual(Address.from_u256(1), config.precompile_overrides[0].address);
    try testing.expectEqual(Address.from_u256(99), config.precompile_overrides[1].address);
}
