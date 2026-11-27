const std = @import("std");

/// Metadata types for dispatch instruction stream
/// These structs contain pre-computed data that helps opcodes execute more efficiently
/// Creates metadata types for a given Frame type
pub fn DispatchMetadata(comptime FrameType: type) type {
    return struct {
        /// Metadata for JUMPDEST operations containing pre-calculated gas and stack requirements.
        /// This enables efficient block-level gas accounting and stack validation.
        /// Instead of calculating static gas every opcode we precalculate it in analysis and then
        /// Add it in one shot when we land on a new jump destination. This turns N gas calculations into 1
        /// The stack validations allows us to use unsafe stack operations such as pop_unsafe that avoid bounds checking
        /// by prevalidating that the stack won't overflow or underflow on jump destination for all following opcodes
        pub const JumpDestMetadata = packed struct(u64) {
            // note: this could be smaller than u32 in future if we needed more space to fit more data
            /// Total gas cost for the entire basic block starting at this JUMPDEST
            gas: u32 = 0,
            // note: this could be smaller than i16 in future if we needed more space to fit more data
            /// Stack requirements we must be at to not underflow
            min_stack: i16 = 0,
            /// Stack requirements we must be at to not overflow
            max_stack: i16 = 0,
        };

        /// The metadata to validate gas and stack sizes for the first block executed by the bytecode
        /// This is the same validation JumpDestinations do
        pub const FirstBlockMetadata = JumpDestMetadata;

        /// One 64-bit word of a PUSH value, stored inline in the dispatch array.
        /// PUSH1-8 and inline fusions use one; PUSH9-32 use two to four, least
        /// significant limb first.
        pub const PushInlineMetadata = packed struct(u64) { value: u64 };

        /// Metadata for fused PUSH+op handlers whose operand is wider than 64 bits.
        /// Points at the value in the schedule's arena. Plain PUSH9-32 do not use it:
        /// they store their value as inline `PushInlineMetadata` limbs.
        pub const PushPointerMetadata = extern struct { value_ptr: *const FrameType.WordType };

        /// Metadata for static jump locations - contains a direct pointer to the jump destination dispatch
        /// This avoids the binary search in findJumpTarget
        pub const JumpStaticMetadata = extern struct { dispatch: *const anyopaque };

        /// Our instruction set does not match the actual bytecode 1 to 1 if we do fusions so we don't actually track pc during execution
        /// Thus we must provide as metadata to avoid the expensive process of mapping back our instruction index to what pc it came from
        /// Padded to exactly 64 bits so it fits an untagged 8-byte schedule item for every `PcType`.
        pub const PcMetadata = packed struct(u64) {
            value: FrameType.PcType,
            _padding: @Int(.unsigned, 64 - @bitSizeOf(FrameType.PcType)) = 0,
        };
    };
}

// ============================
// Tests
// ============================

const testing = std.testing;

// Mock frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
};

test "JumpDestMetadata packs correctly into 64 bits" {
    const Metadata = DispatchMetadata(TestFrame);

    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata.JumpDestMetadata));

    const metadata = Metadata.JumpDestMetadata{
        .gas = 1000,
        .min_stack = -10,
        .max_stack = 100,
    };

    try testing.expectEqual(@as(u32, 1000), metadata.gas);
    try testing.expectEqual(@as(i16, -10), metadata.min_stack);
    try testing.expectEqual(@as(i16, 100), metadata.max_stack);
}

test "PushInlineMetadata stores u64 values" {
    const Metadata = DispatchMetadata(TestFrame);

    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata.PushInlineMetadata));

    const metadata = Metadata.PushInlineMetadata{
        .value = 0xDEADBEEFCAFEBABE,
    };

    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), metadata.value);
}

test "PushPointerMetadata is one pointer to the value" {
    const Metadata = DispatchMetadata(TestFrame);

    try testing.expectEqual(@sizeOf(usize), @sizeOf(Metadata.PushPointerMetadata));

    const value: u256 = 42;
    const metadata = Metadata.PushPointerMetadata{ .value_ptr = &value };

    try testing.expectEqual(@as(u256, 42), metadata.value_ptr.*);
}

test "PcMetadata stores program counter value" {
    const Metadata = DispatchMetadata(TestFrame);

    const metadata = Metadata.PcMetadata{
        .value = 12345,
    };

    try testing.expectEqual(@as(u32, 12345), metadata.value);
}

test "every metadata type fits one 8-byte schedule item" {
    const Metadata = DispatchMetadata(TestFrame);

    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata.JumpDestMetadata));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata.PushInlineMetadata));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata.PcMetadata));
    try testing.expect(@sizeOf(Metadata.PushPointerMetadata) <= 8);
    try testing.expect(@sizeOf(Metadata.JumpStaticMetadata) <= 8);
}

test "FirstBlockMetadata is same as JumpDestMetadata" {
    const Metadata = DispatchMetadata(TestFrame);

    try testing.expectEqual(@TypeOf(Metadata.JumpDestMetadata{}), @TypeOf(Metadata.FirstBlockMetadata{}));
}
