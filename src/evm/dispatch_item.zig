const std = @import("std");
const dispatch_metadata = @import("dispatch_metadata.zig");

/// Creates dispatch item types for a given Frame type
pub fn DispatchItem(comptime FrameType: type) type {
    const Metadata = dispatch_metadata.DispatchMetadata(FrameType);
    
    // Forward declare Item for OpcodeHandler
    const ItemType = union {
        /// Most items are function pointers to an opcode handler
        opcode_handler: *const fn (frame: *FrameType, cursor: [*]const @This()) FrameType.Error!noreturn,
        /// Some opcode handlers are followed by metadata specific to that opcode
        jump_dest: Metadata.JumpDestMetadata,
        push_inline: Metadata.PushInlineMetadata,
        push_pointer: Metadata.PushPointerMetadata,
        pc: Metadata.PcMetadata,
        codesize: Metadata.CodesizeMetadata,
        codecopy: Metadata.CodecopyMetadata,
        first_block_gas: Metadata.FirstBlockMetadata,
        trace_before: Metadata.TraceBeforeMetadata,
        trace_after: Metadata.TraceAfterMetadata,
    };

    comptime {
        if (@sizeOf(ItemType) != 8) @compileError("Item must be 64 bits");
    }

    return ItemType;
}

// ============================
// Tests
// ============================

const testing = std.testing;

// Mock frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
    pub const Error = error{TestError};
};

test "DispatchItem size is exactly 64 bits" {
    const Item = DispatchItem(TestFrame);
    try testing.expectEqual(@as(usize, 8), @sizeOf(Item));
}

test "DispatchItem can store different metadata types" {
    const Item = DispatchItem(TestFrame);
    
    // Test push inline metadata
    const item1: Item = .{ .push_inline = .{ .value = 0x1234567890ABCDEF } };
    try testing.expectEqual(@as(u64, 0x1234567890ABCDEF), item1.push_inline.value);
    
    // Test jump dest metadata
    const item2: Item = .{ .jump_dest = .{ .gas = 100, .min_stack = 5, .max_stack = 10 } };
    try testing.expectEqual(@as(u32, 100), item2.jump_dest.gas);
    try testing.expectEqual(@as(i16, 5), item2.jump_dest.min_stack);
    try testing.expectEqual(@as(i16, 10), item2.jump_dest.max_stack);
    
    // Test PC metadata
    const item3: Item = .{ .pc = .{ .value = 42 } };
    try testing.expectEqual(@as(u32, 42), item3.pc.value);
    
    // Test codesize metadata
    const item4: Item = .{ .codesize = .{ .size = 1024 } };
    try testing.expectEqual(@as(u32, 1024), item4.codesize.size);
}