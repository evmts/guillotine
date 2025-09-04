/// Stack configuration parameters for EVM stack implementation
///
/// Configures the EVM stack behavior including:
/// - Stack capacity (maximum number of elements, defaults to 1024 per EVM spec)
/// - Word type for stack elements (u256 for standard EVM compatibility)
/// - Index type optimization (automatically selected based on stack size)
/// - Memory alignment for cache performance
///
/// Configuration is validated at compile time to ensure EVM compliance
/// and optimal performance characteristics.
const std = @import("std");

pub const StackConfig = struct {
    const Self = @This();

    /// The maximum stack size for the evm. Defaults to 1024. Maximum supported is 4095
    stack_size: u12 = 1024,
    /// The size of a single word in the EVM - Defaults to u256. Supports any word size up to u512
    WordType: type = u256,
    /// Whether to enable opcode fusions fuzing more than one opcode into a single operation
    fusions_enabled: bool = true,

    /// StackIndexType: smallest integer type to index the stack
    pub fn StackIndexType(comptime self: Self) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
        else if (self.stack_size <= std.math.maxInt(u8))
            u8
        else if (self.stack_size <= std.math.maxInt(u12))
            u12
        else
            @compileError("StackConfig stack_size is too large! It must fit in a u12 bytes");
    }

    pub fn validate(comptime self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
    }
};

// Tests moved to stack_config_test.zig to reduce context window usage
// This demonstrates the migration pattern for separating implementation from tests
