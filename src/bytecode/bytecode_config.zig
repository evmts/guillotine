const std = @import("std");
const builtin = @import("builtin");
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;
const Mode = @import("../internal/safety_counter.zig").Mode;
const verified_ops = @import("../core/verified_ops.zig");
const Hardfork = @import("voltaire").Hardfork;

/// Configure Bytecode validation
pub const BytecodeConfig = struct {
    // https://ziglang.org/documentation/master/#toc-This
    const Self = @This();
    // whether to fuze multiple opcodes into a single instruction for performance
    // defaults to true
    fusions_enabled: bool = true,
    /// Execution fork. Selects the static gas schedule used for basic-block gas.
    hardfork: Hardfork = .CANCUN,
    /// The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,
    /// The maximum amount of bytes allowed in initcode (EIP-3860)
    max_initcode_size: u32 = 49152,
    /// Loop quota for safety counters to prevent infinite loops
    /// null = disabled (default for optimized builds)
    /// value = maximum iterations before panic (default for debug/safe builds)
    loop_quota: ?u32 = if (builtin.mode == .debug or builtin.mode == .safe) 1_000_000 else null,
    /// The largest code this configuration analyzes, in bytes. Deployed code is bounded
    /// by `max_bytecode_size` and initcode by `max_initcode_size`; both run through the
    /// same analysis, so a program counter must be able to address either.
    pub fn maxCodeSize(comptime self: Self) u32 {
        return @max(self.max_bytecode_size, self.max_initcode_size);
    }

    /// True when this fork has no initcode size limit: EIP-3860 (Shanghai) introduced
    /// the 49152-byte cap. Earlier forks run initcode of any length the sender pays
    /// for, and before EIP-170 (Spurious Dragon) deployed code is unbounded too, so
    /// `max_initcode_size` does not bound the code the analyzer sees.
    pub fn initcodeUnbounded(comptime self: Self) bool {
        return !self.hardfork.isAtLeast(.SHANGHAI);
    }

    /// PcType: the smallest program counter type that can hold every offset the
    /// analyzer forms for the largest analyzable code: the code length plus
    /// `verified_ops.pc_headroom` (33) bytes of PUSH32 lookahead. `Bytecode.init`
    /// rejects code for which `len + 33` does not fit, so a type chosen from the code
    /// size alone would reject valid code near its top (223..255, 4063..4095 and
    /// 65503..65535 bytes). Forks without an initcode limit always select `u32`.
    /// The widths are proved in `verify/smt` (`pc_type_width_bits`).
    pub fn PcType(comptime self: Self) type {
        return switch (verified_ops.pcTypeWidthBits(self.maxCodeSize(), self.initcodeUnbounded())) {
            8 => u8,
            12 => u12,
            16 => u16,
            else => u32,
        };
    }
    /// Validate the configuration at compile time
    pub fn validate(comptime self: Self) void {
        if (self.max_bytecode_size == 0) {
            @compileError("max_bytecode_size must be greater than 0");
        }
        if (self.max_initcode_size == 0) {
            @compileError("max_initcode_size must be greater than 0");
        }
        if (self.max_initcode_size < self.max_bytecode_size) {
            @compileError("max_initcode_size must be at least as large as max_bytecode_size");
        }
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
};

test "bytecode config default values" {
    const config = BytecodeConfig{};
    try std.testing.expectEqual(@as(u32, 24576), config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 49152), config.max_initcode_size);
}

test "bytecode config pc type selection" {
    // 222 bytes plus 33 bytes of lookahead is exactly maxInt(u8)
    const config_u8 = comptime BytecodeConfig{ .max_bytecode_size = 222, .max_initcode_size = 222 };
    try std.testing.expectEqual(u8, config_u8.PcType());

    // 4062 + 33 = 4095 = maxInt(u12)
    const config_u12 = comptime BytecodeConfig{ .max_bytecode_size = 4062, .max_initcode_size = 4062 };
    try std.testing.expectEqual(u12, config_u12.PcType());

    // Default sizes: 24576 bytes of code and 49152 bytes of initcode both fit u16
    const config_u16 = comptime BytecodeConfig{};
    try std.testing.expectEqual(u16, config_u16.PcType());

    // 65503 + 33 exceeds maxInt(u16): the program counter is u32
    const config_u32 = comptime BytecodeConfig{ .max_bytecode_size = 65503, .max_initcode_size = 65503 };
    try std.testing.expectEqual(u32, config_u32.PcType());
    comptime config_u32.validate();
}

test "bytecode config pc type covers initcode" {
    // Initcode runs through the same analysis as deployed code, so the larger of the
    // two limits picks the type.
    const small_code = comptime BytecodeConfig{ .max_bytecode_size = 222, .max_initcode_size = 49152 };
    try std.testing.expectEqual(u16, small_code.PcType());
    try std.testing.expectEqual(@as(u32, 49152), small_code.maxCodeSize());

    const big_initcode = comptime BytecodeConfig{ .max_bytecode_size = 24576, .max_initcode_size = 131072 };
    try std.testing.expectEqual(u32, big_initcode.PcType());
    comptime big_initcode.validate();

    // The headroom sum is computed wide: the largest sizes do not wrap it.
    const max_config = comptime BytecodeConfig{ .max_bytecode_size = std.math.maxInt(u32), .max_initcode_size = std.math.maxInt(u32) };
    try std.testing.expectEqual(u32, max_config.PcType());
    comptime max_config.validate();
}

test "bytecode config pc type boundaries include the 33-byte lookahead" {
    const Case = struct { size: u32, expected: type };
    inline for (.{
        Case{ .size = 222, .expected = u8 },
        Case{ .size = 223, .expected = u12 },
        Case{ .size = 255, .expected = u12 },
        Case{ .size = 4062, .expected = u12 },
        Case{ .size = 4063, .expected = u16 },
        Case{ .size = 4095, .expected = u16 },
        Case{ .size = 65502, .expected = u16 },
        Case{ .size = 65503, .expected = u32 },
        Case{ .size = 65535, .expected = u32 },
    }) |case| {
        const config = comptime BytecodeConfig{ .max_bytecode_size = case.size, .max_initcode_size = case.size };
        try std.testing.expectEqual(case.expected, config.PcType());
    }
}

test "bytecode config pc type is u32 on forks without an initcode limit" {
    // EIP-3860 (Shanghai) introduced the cap. Before it the configured sizes do not
    // bound the code the analyzer is given.
    inline for (.{ Hardfork.FRONTIER, Hardfork.HOMESTEAD, Hardfork.SPURIOUS_DRAGON, Hardfork.LONDON, Hardfork.MERGE }) |hardfork| {
        const config = comptime BytecodeConfig{ .hardfork = hardfork };
        try std.testing.expect(config.initcodeUnbounded());
        try std.testing.expectEqual(u32, config.PcType());
        const tiny = comptime BytecodeConfig{ .hardfork = hardfork, .max_bytecode_size = 1, .max_initcode_size = 1 };
        try std.testing.expectEqual(u32, tiny.PcType());
    }
    inline for (.{ Hardfork.SHANGHAI, Hardfork.CANCUN, Hardfork.PRAGUE, Hardfork.OSAKA }) |hardfork| {
        const config = comptime BytecodeConfig{ .hardfork = hardfork };
        try std.testing.expect(!config.initcodeUnbounded());
        try std.testing.expectEqual(u16, config.PcType());
    }
}

test "bytecode config custom values" {
    const config = BytecodeConfig{
        .max_bytecode_size = 32768,
        .max_initcode_size = 65536,
    };

    try std.testing.expectEqual(@as(u32, 32768), config.max_bytecode_size);
    try std.testing.expectEqual(@as(u32, 65536), config.max_initcode_size);
    try std.testing.expectEqual(u32, config.PcType()); // 65536 bytes of initcode need u32
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
    // Each size selects the smallest type that holds it plus the lookahead.
    const sizes_and_types = [_]struct { size: u32, expected_type: type }{
        .{ .size = 1, .expected_type = u8 },
        .{ .size = 100, .expected_type = u8 },
        .{ .size = 222, .expected_type = u8 },
        .{ .size = 256, .expected_type = u12 },
        .{ .size = 1000, .expected_type = u12 },
        .{ .size = 4062, .expected_type = u12 },
        .{ .size = 4096, .expected_type = u16 },
        .{ .size = 24576, .expected_type = u16 }, // Default
        .{ .size = 65502, .expected_type = u16 },
        .{ .size = 65536, .expected_type = u32 },
    };

    inline for (sizes_and_types) |item| {
        const config = comptime BytecodeConfig{ .max_bytecode_size = item.size, .max_initcode_size = item.size };
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
