const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const Hardfork = primitives.Hardfork;
const Address = primitives.Address.Address;

/// Custom precompile implementation with optional context pointer for FFI
pub const PrecompileOverride = struct {
    address: Address,
    execute: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!PrecompileOutput,
    context: ?*anyopaque = null, // Optional context for FFI handlers
};

/// Precompile output result
pub const PrecompileOutput = struct {
    output: []const u8,
    gas_used: u64,
    success: bool,
};

/// Custom opcode handler override
pub const OpcodeOverride = struct {
    opcode: u8,
    handler: *const anyopaque,
};

/// Configuration for the minimal EVM
/// This is a simplified version of the performance EVM config
/// focusing on constants and basic settings
pub const EvmConfig = struct {
    /// Default hardfork for the EVM
    hardfork: Hardfork = Hardfork.DEFAULT,

    /// The maximum stack size for the EVM. Defaults to 1024
    stack_size: u12 = 1024,

    /// The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,

    /// The maximum amount of bytes allowed in contract deployment
    max_initcode_size: u32 = 49152,

    /// The maximum gas limit for a block
    block_gas_limit: u64 = 30_000_000,

    /// Memory configuration
    memory_initial_capacity: usize = 4096,

    memory_limit: u64 = 0xFFFFFF,

    /// Maximum call depth allowed in the EVM (defaults to 1024 levels)
    max_call_depth: u16 = 1024,

    /// Custom opcode handler overrides
    /// These will override the default handlers in frame
    /// Set to empty slice for no overrides
    opcode_overrides: []const OpcodeOverride = &.{},

    /// Custom precompile implementations
    /// These will override or add new precompiles
    /// Set to empty slice for no overrides
    precompile_overrides: []const PrecompileOverride = &.{},

    /// Loop quota for safety counters to prevent infinite loops
    /// null = disabled (default for optimized builds)
    /// value = maximum iterations before panic (default for debug/safe builds)
    loop_quota: ?u32 = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 1_000_000 else null,

    /// Enable system contract updates (EIP-4788 beacon roots, EIP-2935 historical block hashes)
    /// When true, these contracts are updated at the start of each transaction
    enable_beacon_roots: bool = true,

    enable_historical_block_hashes: bool = true,

    enable_validator_deposits: bool = true,

    enable_validator_withdrawals: bool = true,

    /// Generate configuration from build options
    pub fn fromBuildOptions() EvmConfig {
        const build_options = @import("build_options");

        var config = EvmConfig{};

        // Apply build options
        config.hardfork = getHardforkFromString(build_options.hardfork);
        config.max_call_depth = build_options.max_call_depth;
        config.stack_size = build_options.stack_size;
        config.max_bytecode_size = build_options.max_bytecode_size;
        config.max_initcode_size = build_options.max_initcode_size;
        config.block_gas_limit = build_options.block_gas_limit;
        config.memory_initial_capacity = build_options.memory_initial_capacity;
        config.memory_limit = build_options.memory_limit;

        return config;
    }

    /// Get the hardfork enum from a string
    fn getHardforkFromString(hardfork_str: []const u8) Hardfork {
        if (std.mem.eql(u8, hardfork_str, "FRONTIER")) return .FRONTIER;
        if (std.mem.eql(u8, hardfork_str, "HOMESTEAD")) return .HOMESTEAD;
        if (std.mem.eql(u8, hardfork_str, "TANGERINE")) return .TANGERINE;
        if (std.mem.eql(u8, hardfork_str, "SPURIOUS")) return .SPURIOUS;
        if (std.mem.eql(u8, hardfork_str, "BYZANTIUM")) return .BYZANTIUM;
        if (std.mem.eql(u8, hardfork_str, "CONSTANTINOPLE")) return .CONSTANTINOPLE;
        if (std.mem.eql(u8, hardfork_str, "ISTANBUL")) return .ISTANBUL;
        if (std.mem.eql(u8, hardfork_str, "BERLIN")) return .BERLIN;
        if (std.mem.eql(u8, hardfork_str, "LONDON")) return .LONDON;
        if (std.mem.eql(u8, hardfork_str, "MERGE")) return .MERGE;
        if (std.mem.eql(u8, hardfork_str, "SHANGHAI")) return .SHANGHAI;
        if (std.mem.eql(u8, hardfork_str, "CANCUN")) return .CANCUN;
        if (std.mem.eql(u8, hardfork_str, "PRAGUE")) return .PRAGUE;
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

    try testing.expectEqual(Hardfork.DEFAULT, config.hardfork);
    try testing.expectEqual(@as(u12, 1024), config.stack_size);
    try testing.expectEqual(@as(u32, 24576), config.max_bytecode_size);
    try testing.expectEqual(@as(u32, 49152), config.max_initcode_size);
    try testing.expectEqual(@as(u64, 30_000_000), config.block_gas_limit);
    try testing.expectEqual(@as(usize, 4096), config.memory_initial_capacity);
    try testing.expectEqual(@as(u64, 0xFFFFFF), config.memory_limit);
    try testing.expectEqual(@as(u16, 1024), config.max_call_depth);
}

test "EvmConfig - custom configuration" {
    const config = EvmConfig{
        .hardfork = .BERLIN,
        .stack_size = 512,
        .max_bytecode_size = 12288,
        .max_call_depth = 512,
    };

    try testing.expectEqual(Hardfork.BERLIN, config.hardfork);
    try testing.expectEqual(@as(u12, 512), config.stack_size);
    try testing.expectEqual(@as(u32, 12288), config.max_bytecode_size);
    try testing.expectEqual(@as(u16, 512), config.max_call_depth);
}

test "EvmConfig - hardfork variations" {
    const configs = [_]EvmConfig{
        EvmConfig{ .hardfork = .FRONTIER },
        EvmConfig{ .hardfork = .HOMESTEAD },
        EvmConfig{ .hardfork = .BYZANTIUM },
        EvmConfig{ .hardfork = .BERLIN },
        EvmConfig{ .hardfork = .LONDON },
        EvmConfig{ .hardfork = .SHANGHAI },
        EvmConfig{ .hardfork = .CANCUN },
        EvmConfig{ .hardfork = .PRAGUE },
    };

    inline for (configs) |config| {
        // All should have same default non-hardfork settings
        try testing.expectEqual(@as(u12, 1024), config.stack_size);
        try testing.expectEqual(@as(u16, 1024), config.max_call_depth);
    }
}

test "EvmConfig - opcode overrides" {
    const config = EvmConfig{
        .opcode_overrides = &[_]OpcodeOverride{
            .{ .opcode = 0x01, .handler = @ptrCast(&struct {
                fn dummy() void {}
            }.dummy) },
        },
    };

    try testing.expectEqual(@as(usize, 1), config.opcode_overrides.len);
    try testing.expectEqual(@as(u8, 0x01), config.opcode_overrides[0].opcode);
}

test "EvmConfig - precompile overrides" {
    const config = EvmConfig{
        .precompile_overrides = &[_]PrecompileOverride{
            .{
                .address = Address.fromU256(1),
                .execute = struct {
                    fn exec(ctx: ?*anyopaque, allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!PrecompileOutput {
                        _ = ctx;
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
                .context = null,
            },
        },
    };

    try testing.expectEqual(@as(usize, 1), config.precompile_overrides.len);
    try testing.expectEqual(Address.fromU256(1), config.precompile_overrides[0].address);
}

test "EvmConfig - loop quota" {
    const debug_config = EvmConfig{ .loop_quota = 1_000_000 };
    try testing.expectEqual(@as(?u32, 1_000_000), debug_config.loop_quota);

    const no_quota_config = EvmConfig{ .loop_quota = null };
    try testing.expectEqual(@as(?u32, null), no_quota_config.loop_quota);
}

test "EvmConfig - system contract flags" {
    const config = EvmConfig{
        .enable_beacon_roots = false,
        .enable_historical_block_hashes = false,
        .enable_validator_deposits = false,
        .enable_validator_withdrawals = false,
    };

    try testing.expectEqual(false, config.enable_beacon_roots);
    try testing.expectEqual(false, config.enable_historical_block_hashes);
    try testing.expectEqual(false, config.enable_validator_deposits);
    try testing.expectEqual(false, config.enable_validator_withdrawals);
}
