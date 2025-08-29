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

    pub fn validate(comptime self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
        if (self.max_bytecode_size > 65535) @compileError("max_bytecode_size must be at most 65535");
    }
};
