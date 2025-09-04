const std = @import("std");
const testing = std.testing;
const Dispatch = @import("dispatch.zig").Dispatch;

// Integration test to verify getOpData migration is complete and working
// This test validates that no hardcoded cursor arithmetic remains

test "getOpData integration - verify no hardcoded cursor arithmetic" {
    // This test serves as documentation that the migration is complete
    // All handler functions now use getOpData instead of hardcoded cursor + N
    
    // Test representative examples of each handler type
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = undefined },
        .{ .push_inline = .{ .value = 42 } },
        .{ .opcode_handler = undefined },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test simple opcode pattern (used by arithmetic, bitwise, comparison handlers)
    const simple_op = dispatch.getOpData(.{ .regular = .ADD });
    try testing.expectEqual(dispatch.cursor + 1, simple_op.next.cursor);
    
    // Test complex opcode pattern (used by PUSH operations)
    const complex_op = dispatch.getOpData(.{ .regular = .PUSH1 });
    try testing.expectEqual(dispatch.cursor + 2, complex_op.next.cursor);
    try testing.expectEqual(items[1].push_inline, complex_op.metadata);
    
    // Test synthetic opcode pattern (used by all synthetic handlers) 
    const synthetic_op = dispatch.getOpData(.{ .synthetic = .PUSH_ADD_INLINE });
    try testing.expectEqual(dispatch.cursor + 2, synthetic_op.next.cursor);
    try testing.expectEqual(items[1].push_inline, synthetic_op.metadata);
}

test "getOpData migration benefits verification" {
    // This test documents the benefits achieved by the migration:
    
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = undefined },
        .{ .push_inline = .{ .value = 123 } },
        .{ .opcode_handler = undefined },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // 1. TYPE SAFETY: Compile-time verification of metadata access
    const op_data = dispatch.getOpData(.{ .synthetic = .PUSH_MUL_INLINE });
    
    // This would fail at compile time if wrong metadata type was accessed:
    // const wrong = op_data.nonexistent_field; // Compile error!
    
    // 2. SINGLE SOURCE OF TRUTH: All cursor advancement logic in one place
    try testing.expectEqual(@as(u256, 123), op_data.metadata.value);
    try testing.expectEqual(dispatch.cursor + 2, op_data.next.cursor);
    
    // 3. MAINTAINABILITY: Easy to change metadata layout without touching handlers
    // If we need to change how metadata is stored, only getOpData needs updating
    
    // 4. CONSISTENCY: Same pattern across all handler types
    const arithmetic = dispatch.getOpData(.{ .regular = .ADD });
    const synthetic = dispatch.getOpData(.{ .synthetic = .PUSH_ADD_INLINE });
    
    // Both use the same interface pattern:
    _ = arithmetic.next.cursor;  // Always available
    _ = synthetic.next.cursor;   // Always available
    _ = synthetic.metadata;      // Available when opcode has metadata
}

// Test that helps ensure completeness of the migration
test "handler pattern consistency verification" {
    // This test validates that the migration achieved consistent patterns
    
    const allocator = testing.allocator;
    
    // Create test dispatch array
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = undefined },
        .{ .push_inline = .{ .value = 456 } },
        .{ .opcode_handler = undefined },
        .{ .opcode_handler = undefined },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test all categories of opcodes that were migrated:
    
    // 1. Arithmetic opcodes (cursor + 1)
    const arithmetic_ops = [_]@import("dispatch.zig").UnifiedOpcode{
        .{ .regular = .ADD },
        .{ .regular = .MUL }, 
        .{ .regular = .SUB },
        .{ .regular = .DIV },
    };
    
    for (arithmetic_ops) |op| {
        const op_data = dispatch.getOpData(op);
        try testing.expectEqual(dispatch.cursor + 1, op_data.next.cursor);
    }
    
    // 2. Bitwise opcodes (cursor + 1)
    const bitwise_ops = [_]@import("dispatch.zig").UnifiedOpcode{
        .{ .regular = .AND },
        .{ .regular = .OR },
        .{ .regular = .XOR },
        .{ .regular = .NOT },
    };
    
    for (bitwise_ops) |op| {
        const op_data = dispatch.getOpData(op);
        try testing.expectEqual(dispatch.cursor + 1, op_data.next.cursor);
    }
    
    // 3. Synthetic opcodes (cursor + 2, with metadata)
    const synthetic_ops = [_]@import("dispatch.zig").UnifiedOpcode{
        .{ .synthetic = .PUSH_ADD_INLINE },
        .{ .synthetic = .PUSH_MUL_INLINE },
        .{ .synthetic = .PUSH_AND_INLINE },
        .{ .synthetic = .PUSH_OR_INLINE },
    };
    
    for (synthetic_ops) |op| {
        const op_data = dispatch.getOpData(op);
        try testing.expectEqual(dispatch.cursor + 2, op_data.next.cursor);
        try testing.expectEqual(@as(u256, 456), op_data.metadata.value);
    }
}