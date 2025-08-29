const std = @import("std");
const builtin = @import("builtin");

/// Configure Bytecode validation
pub const BytecodeConfig = struct {
    // https://ziglang.org/documentation/master/#toc-This
    const Self = @This();
    // whether to fuze multiple opcodes into a single instruction for performance
    // defaults to true
    fusions_enabled: bool = true,
    /// The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,
    /// The maximum amount of bytes allowed in initcode (EIP-3860)
    max_initcode_size: u32 = 49152,
    /// PcType: chosen PC integer type from max_bytecode_size
    pub fn PcType(comptime self: Self) type {
        // https://ziglang.org/documentation/master/std/#std.math.maxInt
        // std.math.maxInt returns the maximum value for the given integer type
        return if (self.max_bytecode_size <= std.math.maxInt(u8))
            u8
        else if (self.max_bytecode_size <= std.math.maxInt(u12))
            u12
        else if (self.max_bytecode_size <= std.math.maxInt(u16))
            u16
        else if (self.max_bytecode_size <= std.math.maxInt(u32))
            u32
        else
            // https://ziglang.org/documentation/master/#compileError
            @compileError("Bytecode size too large! It must have under u32 bytes");
    }
    /// Validate the configuration at compile time
    pub fn validate(comptime self: Self) void {
        _ = self.PcType(); // Ensure PcType is valid
        if (self.max_bytecode_size == 0) {
            @compileError("max_bytecode_size must be greater than 0");
        }
        if (self.max_bytecode_size > std.math.maxInt(u16)) {
            @compileError("max_bytecode_size too large. Currently only u16 is tested and officially supported");
        }
        if (self.max_initcode_size == 0) {
            @compileError("max_initcode_size must be greater than 0");
        }
        if (self.max_initcode_size < self.max_bytecode_size) {
            @compileError("max_initcode_size must be at least as large as max_bytecode_size");
        }
    }
};

test "bytecode config default values" {
    const config = BytecodeConfig{};
    try std.testing.expectEqual(@as(u32, 24576), config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 49152), config.max_initcode_size);
}

test "bytecode config pc type selection" {
    // Test u8 range
    const config_u8 = comptime BytecodeConfig{ .max_bytecode_size = 255 };
    try std.testing.expectEqual(u8, config_u8.PcType());
    
    // Test u12 range (max = 4095)
    const config_u12 = comptime BytecodeConfig{ .max_bytecode_size = 4095 };
    try std.testing.expectEqual(u12, config_u12.PcType());
    
    // Test u16 range
    const config_u16 = comptime BytecodeConfig{ .max_bytecode_size = 24576 };
    try std.testing.expectEqual(u16, config_u16.PcType());
    
    // Test u32 range (but limited by validation)
    const config_u32 = comptime BytecodeConfig{ .max_bytecode_size = 65536 };
    try std.testing.expectEqual(u32, config_u32.PcType());
}

test "bytecode config pc type boundaries" {
    // Test exact boundary values
    const config_u8_max = comptime BytecodeConfig{ .max_bytecode_size = std.math.maxInt(u8) };
    try std.testing.expectEqual(u8, config_u8_max.PcType());
    
    const config_u8_plus1 = comptime BytecodeConfig{ .max_bytecode_size = std.math.maxInt(u8) + 1 };
    try std.testing.expectEqual(u12, config_u8_plus1.PcType());
    
    const config_u12_max = comptime BytecodeConfig{ .max_bytecode_size = std.math.maxInt(u12) };
    try std.testing.expectEqual(u12, config_u12_max.PcType());
    
    const config_u12_plus1 = comptime BytecodeConfig{ .max_bytecode_size = std.math.maxInt(u12) + 1 };
    try std.testing.expectEqual(u16, config_u12_plus1.PcType());
}

test "bytecode config custom values" {
    const config = BytecodeConfig{
        .max_bytecode_size = 32768,
        .max_initcode_size = 65536,
    };
    
    try std.testing.expectEqual(@as(u32, 32768), config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 65536), config.max_initcode_size);
    try std.testing.expectEqual(u16, config.PcType()); // 32768 fits in u16
}

test "bytecode config validation runtime checks" {
    // Test that valid configs don't crash
    const valid_config = BytecodeConfig{
        .max_bytecode_size = 24576,
        .max_initcode_size = 49152,
    };
    
    // These should not cause runtime errors
    try std.testing.expectEqual(@as(u32, 24576), valid_config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 49152), valid_config.max_initcode_size);
    
    // Test small valid values
    const small_config = BytecodeConfig{
        .max_bytecode_size = 1000,
        .max_initcode_size = 2000,
    };
    try std.testing.expectEqual(@as(u32, 1000), small_config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 2000), small_config.max_initcode_size);
}


test "bytecode config pc type consistency" {
    // Test that different sizes produce expected types
    const sizes_and_types = [_]struct{ size: u32, expected_type: type }{
        .{ .size = 1, .expected_type = u8 },
        .{ .size = 100, .expected_type = u8 },
        .{ .size = 255, .expected_type = u8 },
        .{ .size = 256, .expected_type = u12 },
        .{ .size = 1000, .expected_type = u12 },
        .{ .size = 4095, .expected_type = u12 },
        .{ .size = 4096, .expected_type = u16 },
        .{ .size = 24576, .expected_type = u16 }, // Default
        .{ .size = 65535, .expected_type = u16 },
        .{ .size = 65536, .expected_type = u32 },
    };
    
    inline for (sizes_and_types) |item| {
        const config = comptime BytecodeConfig{ .max_bytecode_size = item.size };
        try std.testing.expectEqual(item.expected_type, config.PcType());
    }
}

test "bytecode config ethereum constants" {
    // Test Ethereum mainnet values
    const mainnet_config = BytecodeConfig{
        .max_bytecode_size = 24576, // EIP-170
        .max_initcode_size = 49152, // EIP-3860 
    };
    
    try std.testing.expectEqual(@as(u32, 24576), mainnet_config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 49152), mainnet_config.max_initcode_size);
    try std.testing.expect(mainnet_config.max_initcode_size >= mainnet_config.max_bytecode_size);
    
    // Test that initcode is exactly 2x bytecode (EIP-3860)
    try std.testing.expectEqual(mainnet_config.max_bytecode_size * 2, mainnet_config.max_initcode_size);
}
