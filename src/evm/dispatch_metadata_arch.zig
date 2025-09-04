const std = @import("std");

/// Architecture-aware metadata that adapts to target platform
/// This is a minimal proof-of-concept showing the approach for issue #641
pub fn ArchAwareDispatchMetadata(comptime FrameType: type) type {
    // Detect target architecture at compile time
    const arch_bits = @bitSizeOf(usize);
    
    // Choose appropriate inline size based on architecture
    const InlineSize = switch (arch_bits) {
        32 => u32,  // 32-bit systems: use u32 for inline values
        64 => u64,  // 64-bit systems: current behavior (u64) 
        128 => u128, // 128-bit systems: use u128 for larger inline values
        else => u64, // Fallback to current behavior for unknown architectures
    };
    
    // Determine PUSH inlining threshold based on architecture
    const push_inline_threshold = switch (arch_bits) {
        32 => 4,  // PUSH1-PUSH4 inline on 32-bit (fits in u32)
        64 => 8,  // PUSH1-PUSH8 inline on 64-bit (current behavior)
        128 => 16, // PUSH1-PUSH16 inline on 128-bit (fits in u128)
        else => 8, // Fallback to current behavior
    };
    
    return struct {
        /// Architecture-specific inline size type
        pub const InlineType = InlineSize;
        
        /// PUSH inlining threshold for this architecture
        pub const push_inline_threshold = push_inline_threshold;
        
        /// Helper function to determine if a value should be inlined
        pub fn shouldInline(value: FrameType.WordType) bool {
            // TODO: Also check if value size <= push_inline_threshold
            return value <= std.math.maxInt(InlineType);
        }
        
        /// Architecture-aware metadata for PUSH operations with inline values
        /// Size adapts to architecture: 32-bit on 32-bit systems, 64-bit on 64-bit, etc.
        pub const PushInlineMetadata = packed struct(InlineSize) { 
            value: InlineType 
        };
        
        /// Metadata for PUSH operations with pointer values (unchanged for now)
        /// TODO: Could also make pointer size architecture-aware in future
        pub const PushPointerMetadata = packed struct(u64) { 
            value: *FrameType.WordType 
        };
        
        /// Architecture-aware metadata for JUMPDEST operations
        /// Adapts field sizes based on available space
        pub const JumpDestMetadata = packed struct(InlineSize) {
            gas: u32,
            min_stack: i16,
            max_stack: switch (InlineSize) {
                u32 => i16,  // Same as current for 32-bit (fits exactly)
                u64 => i16,  // Current behavior maintained
                u128 => i32, // Larger range available on 128-bit systems  
                else => i16, // Fallback
            },
            // TODO: Additional fields could be added on 128-bit systems
            // padding: switch (InlineSize) {
            //     u128 => u64, // Extra space for future metadata
            //     else => void,
            // } = {},
        };
        
        /// First block metadata (same as JumpDestMetadata)
        pub const FirstBlockMetadata = JumpDestMetadata;
        
        /// PC metadata (unchanged for now)
        /// TODO: Could optimize PC size based on max bytecode size for architecture
        pub const PcMetadata = packed struct { 
            value: FrameType.PcType 
        };
        
        /// Codesize metadata (unchanged for now)
        pub const CodesizeMetadata = packed struct { 
            size: u32 
        };
    };
}

// ============================
// Tests - Proof of Concept
// ============================

const testing = std.testing;

// Mock frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
};

test "ArchAwareDispatchMetadata - 32-bit sizing" {
    // Simulate what 32-bit architecture would look like
    // Note: This test shows the concept, full implementation would need
    // compile-time architecture detection testing
    const ArchMetadata = ArchAwareDispatchMetadata(TestFrame);
    
    // On current 64-bit system, this will be u64
    // TODO: Add proper 32-bit simulation for testing
    const is_32_bit = @bitSizeOf(usize) == 32;
    if (is_32_bit) {
        try testing.expectEqual(u32, @TypeOf(ArchMetadata.InlineType));
        try testing.expectEqual(@as(u8, 4), ArchMetadata.push_inline_threshold);
    }
}

test "ArchAwareDispatchMetadata - 64-bit sizing maintains current behavior" {
    const ArchMetadata = ArchAwareDispatchMetadata(TestFrame);
    
    // On 64-bit systems (current), should maintain existing behavior
    const is_64_bit = @bitSizeOf(usize) == 64;
    if (is_64_bit) {
        try testing.expectEqual(u64, @TypeOf(ArchMetadata.InlineType));
        try testing.expectEqual(@as(u8, 8), ArchMetadata.push_inline_threshold);
        try testing.expectEqual(@as(usize, 8), @sizeOf(ArchMetadata.PushInlineMetadata));
    }
}

test "ArchAwareDispatchMetadata - shouldInline helper works" {
    const ArchMetadata = ArchAwareDispatchMetadata(TestFrame);
    
    // Small values should always inline regardless of architecture
    try testing.expect(ArchMetadata.shouldInline(0x12));
    try testing.expect(ArchMetadata.shouldInline(0x1234));
    
    // Very large values should never inline
    const large_value: u256 = std.math.maxInt(u128) + 1;
    try testing.expect(!ArchMetadata.shouldInline(large_value));
}

test "ArchAwareDispatchMetadata - metadata sizes are architecture appropriate" {
    const ArchMetadata = ArchAwareDispatchMetadata(TestFrame);
    
    // Size should match the architecture's natural word size
    const expected_size = @sizeOf(usize);
    try testing.expectEqual(expected_size, @sizeOf(ArchMetadata.PushInlineMetadata));
    try testing.expectEqual(expected_size, @sizeOf(ArchMetadata.JumpDestMetadata));
}