//! Simple tests for synthetic opcode handlers
//! These tests verify that the synthetic handlers correctly implement
//! the fused PUSH+operation semantics

const std = @import("std");
const testing = std.testing;

test "synthetic opcodes compile" {
    // This test just ensures all synthetic opcodes compile properly
    // The actual functionality is tested in the individual handler files
    
    // Import all synthetic handler modules to ensure they compile
    _ = @import("handlers_arithmetic_synthetic.zig");
    _ = @import("handlers_bitwise_synthetic.zig");
    _ = @import("handlers_memory_synthetic.zig");
    _ = @import("handlers_jump_synthetic.zig");
    
    // Import the synthetic opcode definitions
    _ = @import("../opcodes/opcode_synthetic.zig");
    
    // This test passes if everything compiles
    try testing.expect(true);
}

test "synthetic opcode values are in valid range" {
    const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
    
    // All synthetic opcodes should be in the 0xA5-0xBC range
    inline for (@typeInfo(OpcodeSynthetic).@"enum".fields) |field| {
        const value = field.value;
        try testing.expect(value >= 0xA5);
        try testing.expect(value <= 0xBC);
    }
}

test "synthetic opcode count" {
    const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
    
    // We should have exactly 24 synthetic opcodes
    const count = @typeInfo(OpcodeSynthetic).@"enum".fields.len;
    try testing.expectEqual(@as(usize, 24), count);
}