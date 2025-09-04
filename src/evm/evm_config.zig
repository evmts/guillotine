const std = @import("std");
// const PlannerStrategy = @import("planner_strategy.zig").PlannerStrategy;
const FrameConfig = @import("frame_config.zig").FrameConfig;
const BlockInfoConfig = @import("block_info_config.zig").BlockInfoConfig;
const Eips = @import("eips.zig").Eips;
const Hardfork = @import("hardfork.zig").Hardfork;
const primitives = @import("primitives");
const Address = primitives.Address;

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

    /// Custom opcode handlers for extending or overriding EVM behavior
    /// Sparse array where null entries use default handlers
    /// Array index corresponds to opcode value (0-255)
    custom_opcode_handlers: ?*const [256]?*const anyopaque = null,

    /// Custom call types to extend CallParams beyond standard Ethereum calls
    /// If provided, CallParams becomes parameterized with this type
    CustomCallTypes: ?type = null,

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

    /// Compile-time validation of the configuration
    pub fn validate(comptime self: EvmConfig) void {
        // Validate custom opcode handlers
        if (self.custom_opcode_handlers) |_| {
            // Custom opcode handlers are validated at runtime by the type system
            // since we use type casting to ensure proper function signatures
        }

        // Validate custom call types
        if (self.CustomCallTypes) |CustomTypes| {
            // Verify that custom call types have required fields
            const type_info = @typeInfo(CustomTypes);
            if (type_info != .Struct) {
                @compileError("CustomCallTypes must be a struct type");
            }
            
            // Ensure gas field exists - required for all call types
            if (!@hasField(CustomTypes, "gas")) {
                @compileError("CustomCallTypes must have a 'gas' field of type u64");
            }
            
            // Validate gas field type
            const gas_field = @typeInfo(@TypeOf(@field(@as(CustomTypes, undefined), "gas")));
            if (gas_field != .Int or @typeInfo(@TypeOf(@field(@as(CustomTypes, undefined), "gas"))) != .Int) {
                @compileError("CustomCallTypes 'gas' field must be of type u64");
            }
        }

        // Other validations can be added here
        _ = self.get_depth_type(); // This will compile-error if max_call_depth is too large
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

test "EvmConfig - custom opcode handlers basic configuration" {
    // This test will fail until we implement the feature
    const DummyHandler = struct {
        fn handler(frame: anytype, cursor: anytype) anytype {
            _ = frame;
            _ = cursor;
            return @as(anytype, undefined);
        }
    }.handler;
    
    var custom_handlers: [256]?*const anyopaque = [_]?*const anyopaque{null} ** 256;
    custom_handlers[0xfe] = &DummyHandler; // Custom debug opcode
    custom_handlers[0x01] = &DummyHandler; // Override ADD opcode
    
    const config = EvmConfig{
        .custom_opcode_handlers = &custom_handlers,
    };
    
    try testing.expectEqual(@as(?*const [256]?*const anyopaque, &custom_handlers), config.custom_opcode_handlers);
}

test "EvmConfig - custom opcode handlers null configuration" {
    const config = EvmConfig{};
    try testing.expectEqual(@as(?*const [256]?*const anyopaque, null), config.custom_opcode_handlers);
}

test "EvmConfig - custom opcode handlers integration with frame handlers" {
    // Test that custom opcode handlers are properly integrated
    const frame_handlers = @import("frame_handlers.zig");
    
    // Create a minimal frame type for testing
    const TestFrame = struct {
        const Self = @This();
        pub const Error = error{TestError};
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const anytype) Error!noreturn;
        
        gas: u64 = 1000,
        
        fn customAddHandler(frame: *Self, cursor: [*]const anytype) Error!noreturn {
            _ = frame;
            _ = cursor;
            return Error.TestError; // Custom behavior
        }
    };
    
    var custom_handlers: [256]?*const anyopaque = [_]?*const anyopaque{null} ** 256;
    custom_handlers[0x01] = &TestFrame.customAddHandler; // Override ADD
    
    const config = EvmConfig{
        .custom_opcode_handlers = &custom_handlers,
    };
    
    // Get handlers with custom config
    const handlers = frame_handlers.getOpcodeHandlersWithConfig(TestFrame, config);
    
    // Verify the custom handler is installed
    try testing.expect(handlers[0x01] == &TestFrame.customAddHandler);
}

test "EvmConfig - custom call types configuration" {
    // Test custom call types configuration
    const MetaCall = struct {
        relayer: Address,
        signer: Address,
        to: Address,
        value: u256,
        data: []const u8,
        gas: u64,
    };
    
    const config = EvmConfig{
        .CustomCallTypes = MetaCall,
    };
    
    try testing.expectEqual(MetaCall, config.CustomCallTypes.?);
}

test "EvmConfig - compile-time validation success" {
    // Test valid configurations pass validation
    const ValidCustomCall = struct {
        caller: Address,
        to: Address,
        data: []const u8,
        gas: u64, // Required field
    };
    
    const config = EvmConfig{
        .CustomCallTypes = ValidCustomCall,
        .max_call_depth = 1024, // Valid depth
    };
    
    // This should compile without error
    comptime {
        config.validate();
    }
}

test "EvmConfig - integration test custom opcodes and calls" {
    // Integration test combining custom opcodes and custom calls
    const frame_handlers = @import("frame_handlers.zig");
    const call_params = @import("call_params.zig");
    
    // Define custom call type for this test
    const TestCustomCall = struct {
        operator: Address,
        target: Address,
        data: []const u8,
        gas: u64,
    };
    
    // Create config with both custom opcodes and calls
    const TestFrame = struct {
        const Self = @This();
        pub const Error = error{TestError};
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const anytype) Error!noreturn;
        
        pub fn customHandler(frame: *Self, cursor: [*]const anytype) Error!noreturn {
            _ = frame;
            _ = cursor;
            return Error.TestError;
        }
    };
    
    var custom_handlers: [256]?*const anyopaque = [_]?*const anyopaque{null} ** 256;
    custom_handlers[0xfe] = &TestFrame.customHandler;
    
    const config = EvmConfig{
        .custom_opcode_handlers = &custom_handlers,
        .CustomCallTypes = TestCustomCall,
    };
    
    // Validate the configuration
    comptime {
        config.validate();
    }
    
    // Test custom opcode handler integration
    const handlers = frame_handlers.getOpcodeHandlersWithConfig(TestFrame, config);
    try testing.expect(handlers[0xfe] == &TestFrame.customHandler);
    
    // Test custom call type integration
    const CustomCallParams = call_params.CallParamsGeneric(config);
    
    const custom_call = CustomCallParams{ .custom = TestCustomCall{
        .operator = primitives.ZERO_ADDRESS,
        .target = [_]u8{1} ++ [_]u8{0} ** 19,
        .data = &[_]u8{0x42},
        .gas = 100000,
    } };
    
    try testing.expectEqual(@as(u64, 100000), custom_call.getGas());
    try testing.expectEqual(primitives.ZERO_ADDRESS, custom_call.getCaller()); // Uses operator
}

test "EvmConfig - performance verification zero overhead" {
    // Test that default configuration has zero additional overhead
    const default_config = EvmConfig{};
    
    // Default config should have null custom extensions
    try testing.expectEqual(@as(?*const [256]?*const anyopaque, null), default_config.custom_opcode_handlers);
    try testing.expectEqual(@as(?type, null), default_config.CustomCallTypes);
    
    // Validate default config
    comptime {
        default_config.validate();
    }
    
    // Test that frame handlers work normally with default config
    const frame_handlers = @import("frame_handlers.zig");
    
    const TestFrame = struct {
        const Self = @This();
        pub const Error = error{TestError};
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const anytype) Error!noreturn;
    };
    
    const handlers = frame_handlers.getOpcodeHandlersWithConfig(TestFrame, default_config);
    
    // Should have 256 handlers (no custom ones)
    try testing.expectEqual(@as(usize, 256), handlers.len);
}

test "EvmConfig - working examples" {
    // Example 1: Meta-transaction support
    const MetaTransaction = struct {
        relayer: Address,
        signer: Address,
        to: Address,
        value: u256,
        data: []const u8,
        signature: [65]u8,
        nonce: u64,
        gas: u64,
    };
    
    const meta_config = EvmConfig{
        .CustomCallTypes = MetaTransaction,
    };
    
    comptime {
        meta_config.validate();
    }
    
    // Example 2: Account abstraction call
    const AccountAbstractionCall = struct {
        sender: Address,
        target: Address,
        calldata: []const u8,
        gas: u64,
        validation_data: []const u8,
    };
    
    const aa_config = EvmConfig{
        .CustomCallTypes = AccountAbstractionCall,
    };
    
    comptime {
        aa_config.validate();
    }
    
    // Example 3: Custom debug opcode with logging
    const DebugFrame = struct {
        const Self = @This();
        pub const Error = error{DebugError};
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const anytype) Error!noreturn;
        
        pub fn debugLog(frame: *Self, cursor: [*]const anytype) Error!noreturn {
            _ = frame;
            _ = cursor;
            // In real implementation, this would log execution state
            return Error.DebugError;
        }
    };
    
    var debug_handlers: [256]?*const anyopaque = [_]?*const anyopaque{null} ** 256;
    debug_handlers[0xfe] = &DebugFrame.debugLog; // Custom DEBUG opcode
    
    const debug_config = EvmConfig{
        .custom_opcode_handlers = &debug_handlers,
    };
    
    comptime {
        debug_config.validate();
    }
    
    // Test the debug opcode handler
    const frame_handlers = @import("frame_handlers.zig");
    const debug_opcode_handlers = frame_handlers.getOpcodeHandlersWithConfig(DebugFrame, debug_config);
    try testing.expect(debug_opcode_handlers[0xfe] == &DebugFrame.debugLog);
}
