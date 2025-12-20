/// Synthetic opcodes for EVM optimizations and extensions
///
/// These opcodes are not part of the official EVM specification but can be
/// used for optimizations, intermediate representations, or extended functionality.
const std = @import("std");

/// Synthetic opcodes enumeration
/// Values start at 0x00 and are offset by 0x100 in UnifiedOpcode
pub const OpcodeSynthetic = enum(u8) {
    // Placeholder synthetic opcodes
    // These can be extended based on specific optimization needs

    /// No-op synthetic opcode
    SYNTHETIC_NOP = 0x00,

    /// Synthetic jump table optimization
    SYNTHETIC_JUMP_TABLE = 0x01,

    /// Synthetic function call optimization
    SYNTHETIC_CALL_DIRECT = 0x02,

    /// Synthetic return optimization
    SYNTHETIC_RETURN_DIRECT = 0x03,

    // Additional synthetic opcodes can be added here as needed

    /// Get the name of the synthetic opcode
    pub fn name(self: OpcodeSynthetic) []const u8 {
        return switch (self) {
            .SYNTHETIC_NOP => "SYNTHETIC_NOP",
            .SYNTHETIC_JUMP_TABLE => "SYNTHETIC_JUMP_TABLE",
            .SYNTHETIC_CALL_DIRECT => "SYNTHETIC_CALL_DIRECT",
            .SYNTHETIC_RETURN_DIRECT => "SYNTHETIC_RETURN_DIRECT",
        };
    }

    /// Get a description of what this synthetic opcode does
    pub fn description(self: OpcodeSynthetic) []const u8 {
        return switch (self) {
            .SYNTHETIC_NOP => "No-operation placeholder",
            .SYNTHETIC_JUMP_TABLE => "Optimized jump table dispatch",
            .SYNTHETIC_CALL_DIRECT => "Direct function call optimization",
            .SYNTHETIC_RETURN_DIRECT => "Direct return optimization",
        };
    }
};

test "synthetic opcode names" {
    const testing = std.testing;

    try testing.expectEqualStrings("SYNTHETIC_NOP", OpcodeSynthetic.SYNTHETIC_NOP.name());
    try testing.expectEqualStrings("SYNTHETIC_JUMP_TABLE", OpcodeSynthetic.SYNTHETIC_JUMP_TABLE.name());
    try testing.expectEqualStrings("SYNTHETIC_CALL_DIRECT", OpcodeSynthetic.SYNTHETIC_CALL_DIRECT.name());
    try testing.expectEqualStrings("SYNTHETIC_RETURN_DIRECT", OpcodeSynthetic.SYNTHETIC_RETURN_DIRECT.name());
}

test "synthetic opcode descriptions" {
    const testing = std.testing;

    try testing.expectEqualStrings("No-operation placeholder", OpcodeSynthetic.SYNTHETIC_NOP.description());
    try testing.expectEqualStrings("Optimized jump table dispatch", OpcodeSynthetic.SYNTHETIC_JUMP_TABLE.description());
    try testing.expectEqualStrings("Direct function call optimization", OpcodeSynthetic.SYNTHETIC_CALL_DIRECT.description());
    try testing.expectEqualStrings("Direct return optimization", OpcodeSynthetic.SYNTHETIC_RETURN_DIRECT.description());
}

test "synthetic opcode values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 0x00), @intFromEnum(OpcodeSynthetic.SYNTHETIC_NOP));
    try testing.expectEqual(@as(u8, 0x01), @intFromEnum(OpcodeSynthetic.SYNTHETIC_JUMP_TABLE));
    try testing.expectEqual(@as(u8, 0x02), @intFromEnum(OpcodeSynthetic.SYNTHETIC_CALL_DIRECT));
    try testing.expectEqual(@as(u8, 0x03), @intFromEnum(OpcodeSynthetic.SYNTHETIC_RETURN_DIRECT));
}
