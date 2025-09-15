/// Frame configuration parameters for customizable EVM execution contexts
///
/// Defines compile-time configuration for Frame instances including:
/// - Stack size and word type (u256, u128, etc.)
/// - Memory limits and initial capacity
/// - Gas tracking precision (i32 vs i64)
/// - Database and tracing capabilities
/// - Platform-specific optimizations
///
/// Configuration is validated at compile time to ensure optimal performance
/// and catch invalid parameter combinations early.
const std = @import("std");
const builtin = @import("builtin");
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;
const Mode = @import("../internal/safety_counter.zig").Mode;

// TODO add the Eip type from evm
pub const FrameConfig = struct {
    const Self = @This();
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
    /// Database implementation type for storage operations (always required).
    DatabaseType: type,

    /// Block info configuration for the frame
    block_info_config: @import("block_info_config.zig").BlockInfoConfig = .{},

    /// Disable gas checks for testing/development (default: false)
    /// When enabled, gas consumption methods become no-ops
    disable_gas_checks: bool = false,

    /// Disable balance checks for testing/development (default: false)
    /// When enabled, balance checks always return 0
    disable_balance_checks: bool = false,

    /// Disable fusion optimizations (default: false)
    /// When enabled, bytecode fusion handlers are not registered
    disable_fusion: bool = false,

    /// SIMD vector length for optimized operations
    /// Value of 1 means scalar operations (no SIMD)
    vector_length: comptime_int = 1,

    /// Loop quota for safety counters to prevent infinite loops
    /// null = disabled (default for optimized builds)
    /// value = maximum iterations before panic (default for debug/safe builds)
    loop_quota: ?u32 = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 1_000_000 else null,

    /// PcType: chosen PC integer type from max_bytecode_size
    pub fn PcType(comptime self: Self) type {
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
    pub fn StackIndexType(comptime self: Self) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
        else if (self.stack_size <= std.math.maxInt(u8))
            u8
        else if (self.stack_size <= std.math.maxInt(u12))
            u12
        else
            @compileError("FrameConfig stack_size is too large! It must fit in a u12 bytes");
    }
    /// GasType: minimal signed integer type to track gas remaining
    pub fn GasType(comptime self: Self) type {
        return if (self.block_gas_limit <= std.math.maxInt(i32))
            i32
        else
            i64;
    }

    /// The amount of data the frame plans on allocating based on config
    pub fn get_requested_alloc(comptime self: Self) u32 {
        return @as(u32, self.stack_size) * @as(u32, @intCast(@sizeOf(self.WordType)));
    }

    /// Create a loop safety counter based on the configuration
    /// Returns either an enabled or disabled counter depending on loop_quota
    /// Automatically selects the smallest type that can hold the quota
    pub fn createLoopSafetyCounter(comptime self: Self) type {
        const mode: Mode = if (self.loop_quota != null) .enabled else .disabled;
        const limit = self.loop_quota orelse 0;

        // Choose the smallest type that can hold the limit
        const T = if (limit <= std.math.maxInt(u8))
            u8
        else if (limit <= std.math.maxInt(u16))
            u16
        else if (limit <= std.math.maxInt(u32))
            u32
        else
            u64;

        const Counter = SafetyCounter(T, mode);
        return Counter;
    }

    pub fn validate(comptime self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
        if (self.max_bytecode_size > 65535) @compileError("max_bytecode_size must be at most 65535");
    }
};
