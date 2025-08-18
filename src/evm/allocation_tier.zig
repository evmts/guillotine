//! Tiered allocation strategy for EVM execution frames
//!
//! This module defines allocation tiers to minimize memory waste by
//! pre-allocating buffers sized according to bytecode size. Most contracts
//! are small, so we avoid allocating maximum size buffers for every frame.

const std = @import("std");
const Stack = @import("stack/stack.zig");
const analysis2 = @import("evm/analysis2.zig");

/// Allocation tier based on bytecode size
pub const AllocationTier = enum(u32) {
    tiny = 4 * 1024,      // 4KB contracts
    small = 8 * 1024,     // 8KB contracts  
    medium = 16 * 1024,   // 16KB contracts (Snailtracer size)
    large = 32 * 1024,    // 32KB contracts
    huge = 64 * 1024,     // 64KB contracts (theoretical max)

    /// Select appropriate tier based on bytecode size
    pub fn select_tier(bytecode_size: usize) AllocationTier {
        if (bytecode_size <= 4096) return .tiny;
        if (bytecode_size <= 8192) return .small;
        if (bytecode_size <= 16384) return .medium;
        if (bytecode_size <= 32768) return .large;
        return .huge;
    }

    /// Calculate total buffer size needed for tier
    pub fn buffer_size(self: AllocationTier) usize {
        const bytecode_size = @intFromEnum(self);
        
        // Calculate component sizes
        const stack_alloc = Stack.calculate_allocation(bytecode_size);
        const analysis_alloc = analysis2.calculate_analysis_allocation(bytecode_size);
        const metadata_alloc = analysis2.calculate_metadata_allocation(bytecode_size);
        const ops_alloc = analysis2.calculate_ops_allocation(bytecode_size);
        
        // Sum up all allocations with alignment padding
        var total: usize = 0;
        
        // Stack (aligned to u256)
        total = align_forward(total, stack_alloc.alignment);
        total += stack_alloc.size;
        
        // Analysis arrays (aligned to u16)
        total = align_forward(total, analysis_alloc.alignment);
        total += analysis_alloc.size;
        
        // Metadata (aligned to u32)
        total = align_forward(total, metadata_alloc.alignment);
        total += metadata_alloc.size;
        
        // Ops (aligned to pointer)
        total = align_forward(total, ops_alloc.alignment);
        total += ops_alloc.size;
        
        // Add 10% padding for safety
        total = total + total / 10;
        
        return total;
    }
    
    /// Get the maximum bytecode size this tier supports
    pub fn max_bytecode_size(self: AllocationTier) usize {
        return @intFromEnum(self);
    }
};

/// Align address forward to specified alignment
fn align_forward(addr: usize, alignment: usize) usize {
    return (addr + alignment - 1) & ~(alignment - 1);
}

test "allocation tier selection" {
    const testing = std.testing;
    
    try testing.expectEqual(AllocationTier.tiny, AllocationTier.select_tier(1024));
    try testing.expectEqual(AllocationTier.tiny, AllocationTier.select_tier(4096));
    try testing.expectEqual(AllocationTier.small, AllocationTier.select_tier(5000));
    try testing.expectEqual(AllocationTier.small, AllocationTier.select_tier(8192));
    try testing.expectEqual(AllocationTier.medium, AllocationTier.select_tier(10000));
    try testing.expectEqual(AllocationTier.medium, AllocationTier.select_tier(16384));
    try testing.expectEqual(AllocationTier.large, AllocationTier.select_tier(20000));
    try testing.expectEqual(AllocationTier.large, AllocationTier.select_tier(32768));
    try testing.expectEqual(AllocationTier.huge, AllocationTier.select_tier(50000));
    try testing.expectEqual(AllocationTier.huge, AllocationTier.select_tier(65536));
}

test "allocation tier buffer sizes" {
    const testing = std.testing;
    
    // Test that each tier allocates reasonable buffer sizes
    const tiny_size = AllocationTier.tiny.buffer_size();
    const small_size = AllocationTier.small.buffer_size();
    const medium_size = AllocationTier.medium.buffer_size();
    const large_size = AllocationTier.large.buffer_size();
    const huge_size = AllocationTier.huge.buffer_size();
    
    // Each tier should be larger than the previous
    try testing.expect(tiny_size < small_size);
    try testing.expect(small_size < medium_size);
    try testing.expect(medium_size < large_size);
    try testing.expect(large_size < huge_size);
    
    // Verify minimum sizes (at least stack + some analysis)
    const min_size = Stack.calculate_allocation(0).size + 1024; // Stack + 1KB
    try testing.expect(tiny_size >= min_size);
}

test "allocation tier alignment" {
    const testing = std.testing;
    
    // Test alignment function
    try testing.expectEqual(@as(usize, 0), align_forward(0, 8));
    try testing.expectEqual(@as(usize, 8), align_forward(1, 8));
    try testing.expectEqual(@as(usize, 8), align_forward(7, 8));
    try testing.expectEqual(@as(usize, 8), align_forward(8, 8));
    try testing.expectEqual(@as(usize, 16), align_forward(9, 8));
    
    // Test with different alignments
    try testing.expectEqual(@as(usize, 16), align_forward(13, 16));
    try testing.expectEqual(@as(usize, 32), align_forward(17, 32));
    try testing.expectEqual(@as(usize, 64), align_forward(33, 64));
}