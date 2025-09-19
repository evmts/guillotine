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

        /// Metadata for PUSH operations with values that fit in 64 bits.
        /// Stored inline in the dispatch array for cache efficiency.
        pub const PushInlineMetadata = packed struct(u64) { value: u64 };

        /// Metadata for PUSH operations with values larger than 64 bits.
        /// Contains a direct pointer to the u256 value for efficient access without indirection.
        pub const PushPointerMetadata = packed struct(usize) { value_ptr: *const FrameType.WordType };

        /// Metadata for PC opcode containing the program counter value.
        /// Metadata for static jump locations - contains a direct pointer to the jump destination dispatch
        /// This avoids the binary search in findJumpTarget
        pub const JumpStaticMetadata = packed struct(usize) { dispatch: *const anyopaque };

        /// Our instruction set does not match the actual bytecode 1 to 1 if we do fusions so we don't actually track pc during execution
        /// Thus we must provide as metadata to avoid the expensive process of mapping back our instruction index to what pc it came from
        pub const PcMetadata = packed struct { value: FrameType.PcType };

        /// Metadata for CODESIZE opcode containing the bytecode size.
        /// Only one opcode needs this data so it's better to store it as metadata for that opcode than store on frame
        pub const CodesizeMetadata = packed struct { size: u32 };

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

test "PushPointerMetadata stores index to u256 array" {
    const Metadata = DispatchMetadata(TestFrame);
    
    try testing.expectEqual(@as(usize, 4), @sizeOf(Metadata.PushPointerMetadata));
    
    const metadata = Metadata.PushPointerMetadata{
        .index = 42,
    };
    
    try testing.expectEqual(@as(u32, 42), metadata.index);
}

test "PcMetadata stores program counter value" {
    const Metadata = DispatchMetadata(TestFrame);
    
    const metadata = Metadata.PcMetadata{
        .value = 12345,
    };
    
    try testing.expectEqual(@as(u32, 12345), metadata.value);
}

test "CodesizeMetadata stores bytecode size" {
    const Metadata = DispatchMetadata(TestFrame);
    
    const metadata = Metadata.CodesizeMetadata{
        .size = 65536,
    };
    
    try testing.expectEqual(@as(u32, 65536), metadata.size);
}


test "FirstBlockMetadata is same as JumpDestMetadata" {
    const Metadata = DispatchMetadata(TestFrame);
    
    try testing.expectEqual(@TypeOf(Metadata.JumpDestMetadata{}), @TypeOf(Metadata.FirstBlockMetadata{}));
}