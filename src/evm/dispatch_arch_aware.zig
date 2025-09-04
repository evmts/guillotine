const std = @import("std");
const testing = std.testing;

/// Architecture-aware dispatch metadata that adapts to target platform
/// This module provides compile-time detection of CPU architecture and
/// adapts metadata sizes accordingly for optimal cache utilization
pub fn ArchitectureAwareDispatchMetadata(comptime FrameType: type) type {
    return ArchitectureAwareDispatchMetadataForArch(FrameType, @bitSizeOf(usize));
}

/// Architecture-aware dispatch metadata for specific bit width (for testing)
pub fn ArchitectureAwareDispatchMetadataForArch(comptime FrameType: type, comptime arch_bits: comptime_int) type {
    const InlineSize = switch (arch_bits) {
        32 => u32,
        64 => u64,
        128 => u128,
        else => @compileError("Unsupported architecture bit width"),
    };
    
    const push_inline_threshold = switch (arch_bits) {
        32 => 4,  // PUSH1-PUSH4 inline on 32-bit
        64 => 8,  // PUSH1-PUSH8 inline on 64-bit (current)
        128 => 16, // PUSH1-PUSH16 inline on 128-bit
        else => @compileError("Unsupported architecture bit width"),
    };
    
    return struct {
        pub const InlineSize = InlineSize;
        pub const push_inline_threshold = push_inline_threshold;
        pub const arch_bits = arch_bits;
        
        /// Metadata for JUMPDEST operations with architecture-aware sizing
        pub const JumpDestMetadata = packed struct(InlineSize) {
            gas: u32 = 0,
            min_stack: i16 = 0,
            max_stack: switch (InlineSize) {
                u32 => i8,   // Smaller range on 32-bit to fit
                u64 => i16,  // Current size
                u128 => i32, // Larger range on 128-bit
                else => @compileError("Invalid InlineSize"),
            } = 0,
        };
        
        /// First block metadata same as JumpDest
        pub const FirstBlockMetadata = JumpDestMetadata;
        
        /// PUSH operations with values that fit in architecture word size
        pub const PushInlineMetadata = packed struct(InlineSize) { 
            value: InlineSize 
        };
        
        /// PUSH operations with values larger than architecture word size
        pub const PushPointerMetadata = packed struct(InlineSize) { 
            value: *FrameType.WordType 
        };
        
        /// PC opcode metadata
        pub const PcMetadata = packed struct(InlineSize) { 
            value: FrameType.PcType 
        };
        
        /// CODESIZE opcode metadata
        pub const CodesizeMetadata = packed struct(InlineSize) { 
            size: u32 
        };
        
        /// Test if a value should be inlined based on architecture
        pub fn shouldInline(value: FrameType.WordType) bool {
            return value <= std.math.maxInt(InlineSize);
        }
    };
}

/// Architecture-aware dispatch Item union
pub fn ArchitectureAwareDispatchItem(comptime FrameType: type, comptime HandlerType: type) type {
    return ArchitectureAwareDispatchItemForArch(FrameType, HandlerType, @bitSizeOf(usize));
}

/// Architecture-aware dispatch Item for specific bit width (for testing)
pub fn ArchitectureAwareDispatchItemForArch(comptime FrameType: type, comptime HandlerType: type, comptime arch_bits: comptime_int) type {
    const Metadata = ArchitectureAwareDispatchMetadataForArch(FrameType, arch_bits);
    
    const ItemType = union {
        /// Function pointer to opcode handler
        opcode_handler: HandlerType,
        /// Architecture-aware metadata
        jump_dest: Metadata.JumpDestMetadata,
        push_inline: Metadata.PushInlineMetadata,
        push_pointer: Metadata.PushPointerMetadata,
        pc: Metadata.PcMetadata,
        codesize: Metadata.CodesizeMetadata,
        first_block_gas: Metadata.FirstBlockMetadata,
    };
    
    const expected_size = switch (arch_bits) {
        32 => 4,
        64 => 8,
        128 => 16,
        else => @compileError("Unsupported architecture"),
    };
    
    comptime {
        if (@sizeOf(ItemType) != expected_size) {
            @compileError("Item must be " ++ std.fmt.comptimePrint("{} bytes for {}-bit architecture", .{ expected_size, arch_bits }));
        }
    }
    
    return ItemType;
}

// ============================
// Tests - Phase 1: Architecture Detection (RED)
// ============================

// Mock frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
    pub const Error = error{TestError};
};

// Mock handler type for testing
const MockHandler = *const fn (frame: *TestFrame, cursor: [*]const anyopaque) TestFrame.Error!noreturn;

test "Architecture detection - @bitSizeOf(usize) returns expected values" {
    // Test that we can detect architecture at compile time
    const arch_size = @bitSizeOf(usize);
    try testing.expect(arch_size == 32 or arch_size == 64 or arch_size == 128);
}

test "ArchDispatchMetadata - detects 32-bit architecture" {
    const ArchMetadata = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    try testing.expectEqual(u32, ArchMetadata.InlineSize);
    try testing.expectEqual(4, ArchMetadata.push_inline_threshold);
    try testing.expectEqual(32, ArchMetadata.arch_bits);
}

test "ArchDispatchMetadata - detects 64-bit architecture" {
    const ArchMetadata = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    try testing.expectEqual(u64, ArchMetadata.InlineSize);
    try testing.expectEqual(8, ArchMetadata.push_inline_threshold);
    try testing.expectEqual(64, ArchMetadata.arch_bits);
}

test "ArchDispatchMetadata - handles 128-bit architecture" {
    const ArchMetadata = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    try testing.expectEqual(u128, ArchMetadata.InlineSize);
    try testing.expectEqual(16, ArchMetadata.push_inline_threshold);
    try testing.expectEqual(128, ArchMetadata.arch_bits);
}

test "ArchDispatchMetadata - rejects unsupported architectures" {
    // This test documents that unsupported architectures cause compile errors
    // Cannot actually test compilation failure in test, but documents behavior
    const supported_architectures = [_]comptime_int{ 32, 64, 128 };
    for (supported_architectures) |arch| {
        _ = ArchitectureAwareDispatchMetadataForArch(TestFrame, arch);
    }
}

test "ArchDispatchItem - 32-bit union is 32 bits" {
    const Item32 = ArchitectureAwareDispatchItemForArch(TestFrame, MockHandler, 32);
    try testing.expectEqual(@as(usize, 4), @sizeOf(Item32));
}

test "ArchDispatchItem - 64-bit union is 64 bits" {
    const Item64 = ArchitectureAwareDispatchItemForArch(TestFrame, MockHandler, 64);
    try testing.expectEqual(@as(usize, 8), @sizeOf(Item64));
}

test "ArchDispatchItem - 128-bit union is 128 bits" {
    const Item128 = ArchitectureAwareDispatchItemForArch(TestFrame, MockHandler, 128);
    try testing.expectEqual(@as(usize, 16), @sizeOf(Item128));
}

test "ArchDispatchMetadata - shouldInline function works correctly" {
    // Test 32-bit architecture
    const ArchMetadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    try testing.expect(ArchMetadata32.shouldInline(std.math.maxInt(u32)));     // Should inline
    try testing.expect(!ArchMetadata32.shouldInline(std.math.maxInt(u32) + 1)); // Should not inline
    
    // Test 64-bit architecture  
    const ArchMetadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    try testing.expect(ArchMetadata64.shouldInline(std.math.maxInt(u64)));     // Should inline
    try testing.expect(!ArchMetadata64.shouldInline(std.math.maxInt(u64) + 1)); // Should not inline
    
    // Test 128-bit architecture
    const ArchMetadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    try testing.expect(ArchMetadata128.shouldInline(std.math.maxInt(u128)));    // Should inline
    // Cannot test maxInt(u128) + 1 as it would overflow u256
}

// ============================
// Phase 2: Metadata Size Adaptation Tests (RED)
// ============================

test "ArchDispatchMetadata - 32-bit metadata packs correctly" {
    const Metadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    
    // Should be 4 bytes (32 bits) total
    try testing.expectEqual(@as(usize, 4), @sizeOf(Metadata32.PushInlineMetadata));
    try testing.expectEqual(u32, @TypeOf(Metadata32.PushInlineMetadata{}.value));
    
    // JumpDestMetadata should fit in 32 bits
    try testing.expectEqual(@as(usize, 4), @sizeOf(Metadata32.JumpDestMetadata));
}

test "ArchDispatchMetadata - 64-bit metadata maintains current behavior" {
    const Metadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    
    // Should be 8 bytes (64 bits) total - same as current implementation
    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata64.PushInlineMetadata));
    try testing.expectEqual(u64, @TypeOf(Metadata64.PushInlineMetadata{}.value));
    
    // JumpDestMetadata should be 8 bytes like current implementation
    try testing.expectEqual(@as(usize, 8), @sizeOf(Metadata64.JumpDestMetadata));
}

test "ArchDispatchMetadata - 128-bit metadata supports larger values" {
    const Metadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    
    // Should be 16 bytes (128 bits) total
    try testing.expectEqual(@as(usize, 16), @sizeOf(Metadata128.PushInlineMetadata));
    try testing.expectEqual(u128, @TypeOf(Metadata128.PushInlineMetadata{}.value));
    
    // JumpDestMetadata should be 16 bytes
    try testing.expectEqual(@as(usize, 16), @sizeOf(Metadata128.JumpDestMetadata));
}

test "ArchDispatchMetadata - JumpDest field sizing adapts to architecture" {
    // 32-bit: max_stack should be i8 to save space
    const Metadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    try testing.expectEqual(i8, @TypeOf(Metadata32.JumpDestMetadata{}.max_stack));
    
    // 64-bit: max_stack should be i16 (current)
    const Metadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    try testing.expectEqual(i16, @TypeOf(Metadata64.JumpDestMetadata{}.max_stack));
    
    // 128-bit: max_stack should be i32 for larger range
    const Metadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    try testing.expectEqual(i32, @TypeOf(Metadata128.JumpDestMetadata{}.max_stack));
}

test "ArchDispatchMetadata - all metadata types have correct sizes" {
    const Metadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    const Metadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    const Metadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    
    // All metadata types should match the target architecture size
    inline for (.{ "PushInlineMetadata", "PushPointerMetadata", "JumpDestMetadata", "PcMetadata", "CodesizeMetadata" }) |field| {
        try testing.expectEqual(@as(usize, 4), @sizeOf(@field(Metadata32, field)));
        try testing.expectEqual(@as(usize, 8), @sizeOf(@field(Metadata64, field)));
        try testing.expectEqual(@as(usize, 16), @sizeOf(@field(Metadata128, field)));
    }
}

// ============================
// Phase 3: Dynamic PUSH Inlining Tests (RED)
// ============================

test "Dynamic PUSH thresholds - 32-bit PUSH4 uses inline storage" {
    const ArchMetadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    
    // PUSH4 value that fits in u32
    const value: u256 = 0x12345678;
    try testing.expect(ArchMetadata32.shouldInline(value));
    try testing.expectEqual(4, ArchMetadata32.push_inline_threshold);
}

test "Dynamic PUSH thresholds - 32-bit PUSH5 uses pointer storage" {
    const ArchMetadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    
    // PUSH5 value that exceeds u32
    const value: u256 = 0x123456789A;
    try testing.expect(!ArchMetadata32.shouldInline(value));
}

test "Dynamic PUSH thresholds - 64-bit maintains current behavior" {
    const ArchMetadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    
    // PUSH8 value that fits in u64 (current behavior)
    const value8: u256 = 0x123456789ABCDEF0;
    try testing.expect(ArchMetadata64.shouldInline(value8));
    try testing.expectEqual(8, ArchMetadata64.push_inline_threshold);
    
    // PUSH9 value that exceeds u64 (current behavior)
    const value9: u256 = 0x123456789ABCDEF012;
    try testing.expect(!ArchMetadata64.shouldInline(value9));
}

test "Dynamic PUSH thresholds - 128-bit PUSH16 uses inline storage" {
    const ArchMetadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    
    // PUSH16 value that fits in u128
    const value: u256 = 0x123456789ABCDEF0123456789ABCDEF0;
    try testing.expect(ArchMetadata128.shouldInline(value));
    try testing.expectEqual(16, ArchMetadata128.push_inline_threshold);
    
    // PUSH17 value that exceeds u128
    const large_value: u256 = 0x123456789ABCDEF0123456789ABCDEF012;
    try testing.expect(!ArchMetadata128.shouldInline(large_value));
}

test "Boundary value testing - inline vs pointer decisions" {
    // Test values at the boundary between inline and pointer storage
    
    // 32-bit boundary
    const ArchMetadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    try testing.expect(ArchMetadata32.shouldInline(std.math.maxInt(u32)));      // Last inline value
    try testing.expect(!ArchMetadata32.shouldInline(std.math.maxInt(u32) + 1)); // First pointer value
    
    // 64-bit boundary  
    const ArchMetadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    try testing.expect(ArchMetadata64.shouldInline(std.math.maxInt(u64)));      // Last inline value
    try testing.expect(!ArchMetadata64.shouldInline(std.math.maxInt(u64) + 1)); // First pointer value
    
    // 128-bit boundary
    const ArchMetadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    try testing.expect(ArchMetadata128.shouldInline(std.math.maxInt(u128)));    // Last inline value
}

// ============================
// Phase 4: Architecture-Aware Dispatch Complete System (RED)
// ============================

/// Architecture-aware Dispatch that uses the appropriate metadata and item types
pub fn ArchitectureAwareDispatch(comptime FrameType: type) type {
    return ArchitectureAwareDispatchForArch(FrameType, @bitSizeOf(usize));
}

/// Architecture-aware Dispatch for specific bit width (for testing)
pub fn ArchitectureAwareDispatchForArch(comptime FrameType: type, comptime arch_bits: comptime_int) type {
    return struct {
        const Self = @This();
        
        // Use architecture-aware metadata
        const Metadata = ArchitectureAwareDispatchMetadataForArch(FrameType, arch_bits);
        
        // Use architecture-aware Item type
        pub const Item = ArchitectureAwareDispatchItemForArch(
            FrameType, 
            *const fn (frame: *FrameType, cursor: [*]const anyopaque) FrameType.Error!noreturn,
            arch_bits
        );
        
        /// The optimized instruction stream containing opcode handlers and metadata
        cursor: [*]const Item,
        
        // Re-export metadata types for convenience
        pub const JumpDestMetadata = Metadata.JumpDestMetadata;
        pub const FirstBlockMetadata = Metadata.FirstBlockMetadata;
        pub const PushInlineMetadata = Metadata.PushInlineMetadata;
        pub const PushPointerMetadata = Metadata.PushPointerMetadata;
        pub const PcMetadata = Metadata.PcMetadata;
        pub const CodesizeMetadata = Metadata.CodesizeMetadata;
        
        /// Architecture-aware PUSH processing
        pub fn shouldInlineValue(value: FrameType.WordType, size: u8) bool {
            return size <= Metadata.push_inline_threshold and Metadata.shouldInline(value);
        }
        
        /// Get the inline type for this architecture
        pub fn getInlineType() type {
            return Metadata.InlineSize;
        }
        
        /// Get the push inline threshold for this architecture  
        pub fn getPushInlineThreshold() u8 {
            return Metadata.push_inline_threshold;
        }
    };
}

// ============================
// Phase 4: Dispatch Integration Tests (RED)  
// ============================

test "ArchDispatch - 32-bit complete type has correct sizes" {
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    
    // Items should be 4 bytes  
    try testing.expectEqual(@as(usize, 4), @sizeOf(Dispatch32.Item));
    
    // Metadata types should be 4 bytes
    try testing.expectEqual(@as(usize, 4), @sizeOf(Dispatch32.PushInlineMetadata));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Dispatch32.JumpDestMetadata));
}

test "ArchDispatch - 64-bit complete type matches current implementation" {
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    
    // Items should be 8 bytes (same as current)
    try testing.expectEqual(@as(usize, 8), @sizeOf(Dispatch64.Item));
    
    // Metadata types should be 8 bytes (same as current)
    try testing.expectEqual(@as(usize, 8), @sizeOf(Dispatch64.PushInlineMetadata));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Dispatch64.JumpDestMetadata));
    
    // Threshold should match current behavior  
    try testing.expectEqual(8, Dispatch64.getPushInlineThreshold());
}

test "ArchDispatch - 128-bit complete type supports larger inlines" {
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    
    // Items should be 16 bytes
    try testing.expectEqual(@as(usize, 16), @sizeOf(Dispatch128.Item));
    
    // Metadata types should be 16 bytes  
    try testing.expectEqual(@as(usize, 16), @sizeOf(Dispatch128.PushInlineMetadata));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Dispatch128.JumpDestMetadata));
    
    // Threshold should be larger
    try testing.expectEqual(16, Dispatch128.getPushInlineThreshold());
}

test "ArchDispatch - shouldInlineValue works across architectures" {
    // Test architecture-specific inlining decisions
    
    // PUSH4 value
    const push4_value: u256 = 0x12345678;
    
    // 32-bit should inline PUSH4
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    try testing.expect(Dispatch32.shouldInlineValue(push4_value, 4));
    
    // 64-bit should inline PUSH4  
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    try testing.expect(Dispatch64.shouldInlineValue(push4_value, 4));
    
    // 128-bit should inline PUSH4
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    try testing.expect(Dispatch128.shouldInlineValue(push4_value, 4));
    
    // PUSH9 value 
    const push9_value: u256 = 0x123456789ABCDEF012;
    
    // 32-bit should NOT inline PUSH9 (size > 4)
    try testing.expect(!Dispatch32.shouldInlineValue(push9_value, 9));
    
    // 64-bit should NOT inline PUSH9 (value > u64::MAX)
    try testing.expect(!Dispatch64.shouldInlineValue(push9_value, 9));
    
    // 128-bit should inline PUSH9 (size <= 16 and value <= u128::MAX)
    try testing.expect(Dispatch128.shouldInlineValue(push9_value, 9));
}

// ============================
// Phase 5: Integration and Backward Compatibility Tests (RED)
// ============================

test "Backward compatibility - architecture-aware preserves 64-bit behavior" {
    // Architecture-aware dispatch should work identically to current implementation on 64-bit
    const CurrentDispatch = ArchitectureAwareDispatchForArch(TestFrame, 64);
    
    // Same metadata sizes as current implementation
    try testing.expectEqual(@as(usize, 8), @sizeOf(CurrentDispatch.PushInlineMetadata));
    try testing.expectEqual(@as(usize, 8), @sizeOf(CurrentDispatch.JumpDestMetadata));
    try testing.expectEqual(@as(usize, 8), @sizeOf(CurrentDispatch.Item));
    
    // Same inlining threshold as current implementation
    try testing.expectEqual(8, CurrentDispatch.getPushInlineThreshold());
    
    // Same inline type as current implementation
    try testing.expectEqual(u64, CurrentDispatch.getInlineType());
}

test "Memory efficiency - 32-bit uses less metadata space" {
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    
    // 32-bit metadata should be exactly half the size of 64-bit
    try testing.expectEqual(@sizeOf(Dispatch64.Item) / 2, @sizeOf(Dispatch32.Item));
    try testing.expectEqual(@sizeOf(Dispatch64.PushInlineMetadata) / 2, @sizeOf(Dispatch32.PushInlineMetadata));
}

test "Future proofing - 128-bit supports larger inline values" {
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    
    // 128-bit should have double threshold
    try testing.expectEqual(Dispatch64.getPushInlineThreshold() * 2, Dispatch128.getPushInlineThreshold());
    
    // 128-bit should support much larger inline values
    const large_value: u256 = 0x123456789ABCDEF0123456789ABCDEF0;
    try testing.expect(!Dispatch64.shouldInlineValue(large_value, 16));  // Too large for 64-bit
    try testing.expect(Dispatch128.shouldInlineValue(large_value, 16));  // Fits in 128-bit
}

test "Cross-architecture functional equivalence - same EVM semantics" {
    // All architectures should make the same inline/pointer decisions for the same values
    // within their respective capabilities
    
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    
    // Small values should inline on all architectures
    const small_value: u256 = 0x12;
    try testing.expect(Dispatch32.shouldInlineValue(small_value, 1));
    try testing.expect(Dispatch64.shouldInlineValue(small_value, 1));
    try testing.expect(Dispatch128.shouldInlineValue(small_value, 1));
    
    // Values too large for any architecture should not inline anywhere
    const huge_value: u256 = std.math.maxInt(u256);
    try testing.expect(!Dispatch32.shouldInlineValue(huge_value, 32));
    try testing.expect(!Dispatch64.shouldInlineValue(huge_value, 32));
    try testing.expect(!Dispatch128.shouldInlineValue(huge_value, 32));
}

// ============================
// Edge Cases and Error Handling Tests
// ============================

test "Edge case - zero values inline on all architectures" {
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    
    const zero_value: u256 = 0;
    try testing.expect(Dispatch32.shouldInlineValue(zero_value, 1));
    try testing.expect(Dispatch64.shouldInlineValue(zero_value, 1));
    try testing.expect(Dispatch128.shouldInlineValue(zero_value, 1));
}

test "Edge case - one byte values inline on all architectures" {
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    
    const one_value: u256 = 1;
    try testing.expect(Dispatch32.shouldInlineValue(one_value, 1));
    try testing.expect(Dispatch64.shouldInlineValue(one_value, 1));
    try testing.expect(Dispatch128.shouldInlineValue(one_value, 1));
}

test "Edge case - maximum values for each architecture" {
    // Test that each architecture properly handles its maximum inline value
    
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    try testing.expect(Dispatch32.shouldInlineValue(std.math.maxInt(u32), 4));
    
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    try testing.expect(Dispatch64.shouldInlineValue(std.math.maxInt(u64), 8));
    
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    try testing.expect(Dispatch128.shouldInlineValue(std.math.maxInt(u128), 16));
}

test "Real world scenario - common PUSH operations" {
    // Test common real-world PUSH values to ensure they inline appropriately
    
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    const Dispatch64 = ArchitectureAwareDispatchForArch(TestFrame, 64);
    const Dispatch128 = ArchitectureAwareDispatchForArch(TestFrame, 128);
    
    // Common small constants
    const push1_val: u256 = 0x01; // Very common
    try testing.expect(Dispatch32.shouldInlineValue(push1_val, 1));
    try testing.expect(Dispatch64.shouldInlineValue(push1_val, 1));
    try testing.expect(Dispatch128.shouldInlineValue(push1_val, 1));
    
    // Common addresses (20 bytes)
    const address_val: u256 = 0x1234567890ABCDEF1234567890ABCDEF12345678;
    try testing.expect(!Dispatch32.shouldInlineValue(address_val, 20)); // Too large for 32-bit
    try testing.expect(!Dispatch64.shouldInlineValue(address_val, 20));  // Too large for 64-bit
    try testing.expect(Dispatch128.shouldInlineValue(address_val, 20));  // Fits in 128-bit
    
    // 32-byte values (hashes, etc.)
    const hash_val: u256 = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0;
    try testing.expect(!Dispatch32.shouldInlineValue(hash_val, 32));
    try testing.expect(!Dispatch64.shouldInlineValue(hash_val, 32)); 
    try testing.expect(!Dispatch128.shouldInlineValue(hash_val, 32)); // Too large even for 128-bit
}

// ============================
// Performance and Memory Tests  
// ============================

test "Memory layout - packed structs have expected alignment" {
    // Verify that packed structs maintain expected memory layout
    
    const Metadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    const Metadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    const Metadata128 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 128);
    
    // Verify alignment matches size
    try testing.expectEqual(@sizeOf(Metadata32.PushInlineMetadata), @alignOf(Metadata32.PushInlineMetadata));
    try testing.expectEqual(@sizeOf(Metadata64.PushInlineMetadata), @alignOf(Metadata64.PushInlineMetadata));
    try testing.expectEqual(@sizeOf(Metadata128.PushInlineMetadata), @alignOf(Metadata128.PushInlineMetadata));
}

test "Type compatibility - metadata can be cast safely" {
    // Test that metadata types can be safely handled as generic types
    
    const Metadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    
    const metadata = Metadata64.PushInlineMetadata{ .value = 0x123456789ABCDEF0 };
    
    // Should be able to cast and recover value
    const bytes: [8]u8 = @bitCast(metadata);
    const recovered: Metadata64.PushInlineMetadata = @bitCast(bytes);
    
    try testing.expectEqual(metadata.value, recovered.value);
}

// ============================
// Documentation and API Tests
// ============================

test "API completeness - all required functions available" {
    // Verify that architecture-aware dispatch provides all required APIs
    
    const Dispatch32 = ArchitectureAwareDispatchForArch(TestFrame, 32);
    
    // Should have all metadata types
    _ = Dispatch32.JumpDestMetadata;
    _ = Dispatch32.PushInlineMetadata;
    _ = Dispatch32.PushPointerMetadata;
    _ = Dispatch32.PcMetadata;
    _ = Dispatch32.CodesizeMetadata;
    _ = Dispatch32.FirstBlockMetadata;
    
    // Should have utility functions
    _ = Dispatch32.shouldInlineValue;
    _ = Dispatch32.getInlineType;
    _ = Dispatch32.getPushInlineThreshold;
    
    // Should have Item type
    _ = Dispatch32.Item;
}

test "Type safety - architecture mismatch caught at compile time" {
    // Verify that mixing architecture types is caught at compile time
    
    const Metadata32 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 32);
    const Metadata64 = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    
    // These should be different types
    try testing.expect(@TypeOf(Metadata32.PushInlineMetadata{}) != @TypeOf(Metadata64.PushInlineMetadata{}));
    try testing.expect(@TypeOf(Metadata32.InlineSize) != @TypeOf(Metadata64.InlineSize));
}

// ============================
// Integration with Main Dispatch System
// ============================

test "Integration - can be used as drop-in replacement for current Dispatch on 64-bit" {
    // Architecture-aware dispatch should be usable in place of regular dispatch on 64-bit
    
    const RegularMeta = dispatch_metadata.DispatchMetadata(TestFrame);
    const ArchAwareMeta = ArchitectureAwareDispatchMetadataForArch(TestFrame, 64);
    
    // Metadata should be same size
    try testing.expectEqual(@sizeOf(RegularMeta.PushInlineMetadata), @sizeOf(ArchAwareMeta.PushInlineMetadata));
    try testing.expectEqual(@sizeOf(RegularMeta.JumpDestMetadata), @sizeOf(ArchAwareMeta.JumpDestMetadata));
    
    // Same thresholds
    try testing.expectEqual(8, ArchAwareMeta.push_inline_threshold);
    
    // Same inline type
    try testing.expectEqual(u64, ArchAwareMeta.InlineSize);
}