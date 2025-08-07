const std = @import("std");
const BlockMetadata = @import("block_metadata.zig");

/// Heap-allocated Structure of Arrays for block metadata.
///
/// This is an optimized version that allocates exact size needed
/// instead of using fixed MAX_BLOCKS arrays.
const BlockMetadataHeap = @This();

/// Total gas cost for each block (hot data)
gas_costs: []u32,

/// Minimum stack items required at block entry (hot data)
stack_reqs: []i16,

/// Maximum stack growth during block execution (cold data)
stack_max_growths: []i16,

/// Number of valid blocks
count: u16,

/// Allocator used for memory management
allocator: std.mem.Allocator,

/// Initialize with exact number of blocks
pub fn init(allocator: std.mem.Allocator, block_count: u16) !BlockMetadataHeap {
    const gas_costs = try allocator.alloc(u32, block_count);
    errdefer allocator.free(gas_costs);
    
    const stack_reqs = try allocator.alloc(i16, block_count);
    errdefer allocator.free(stack_reqs);
    
    const stack_max_growths = try allocator.alloc(i16, block_count);
    errdefer {
        allocator.free(gas_costs);
        allocator.free(stack_reqs);
    }
    
    return BlockMetadataHeap{
        .gas_costs = gas_costs,
        .stack_reqs = stack_reqs,
        .stack_max_growths = stack_max_growths,
        .count = block_count,
        .allocator = allocator,
    };
}

/// Free allocated memory
pub fn deinit(self: *BlockMetadataHeap) void {
    self.allocator.free(self.gas_costs);
    self.allocator.free(self.stack_reqs);
    self.allocator.free(self.stack_max_growths);
}

/// Set metadata for a specific block
pub fn setBlock(self: *BlockMetadataHeap, index: u16, gas_cost: u32, stack_req: i16, stack_max_growth: i16) void {
    std.debug.assert(index < self.count);
    self.gas_costs[index] = gas_cost;
    self.stack_reqs[index] = stack_req;
    self.stack_max_growths[index] = stack_max_growth;
}

/// Get gas cost for a block (optimized for hot path)
pub inline fn getGasCost(self: *const BlockMetadataHeap, index: u16) u32 {
    std.debug.assert(index < self.count);
    return self.gas_costs[index];
}

/// Get stack requirement for a block (optimized for hot path)
pub inline fn getStackReq(self: *const BlockMetadataHeap, index: u16) i16 {
    std.debug.assert(index < self.count);
    return self.stack_reqs[index];
}

/// Get stack max growth for a block
pub inline fn getStackMaxGrowth(self: *const BlockMetadataHeap, index: u16) i16 {
    std.debug.assert(index < self.count);
    return self.stack_max_growths[index];
}

/// Get all metadata for a block (when all fields are needed)
pub fn getBlock(self: *const BlockMetadataHeap, index: u16) BlockMetadata {
    std.debug.assert(index < self.count);
    return BlockMetadata{
        .gas_cost = self.gas_costs[index],
        .stack_req = self.stack_reqs[index],
        .stack_max = self.stack_max_growths[index],
    };
}

test "BlockMetadataHeap initialization and cleanup" {
    const allocator = std.testing.allocator;
    
    var heap = try BlockMetadataHeap.init(allocator, 100);
    defer heap.deinit();
    
    try std.testing.expectEqual(@as(u16, 100), heap.count);
    try std.testing.expectEqual(@as(usize, 100), heap.gas_costs.len);
    try std.testing.expectEqual(@as(usize, 100), heap.stack_reqs.len);
    try std.testing.expectEqual(@as(usize, 100), heap.stack_max_growths.len);
}

test "BlockMetadataHeap set and get operations" {
    const allocator = std.testing.allocator;
    
    var heap = try BlockMetadataHeap.init(allocator, 10);
    defer heap.deinit();
    
    // Set block metadata
    heap.setBlock(5, 1000, -10, 20);
    
    // Test individual getters
    try std.testing.expectEqual(@as(u32, 1000), heap.getGasCost(5));
    try std.testing.expectEqual(@as(i16, -10), heap.getStackReq(5));
    try std.testing.expectEqual(@as(i16, 20), heap.getStackMaxGrowth(5));
    
    // Test getBlock
    const block = heap.getBlock(5);
    try std.testing.expectEqual(@as(u32, 1000), block.gas_cost);
    try std.testing.expectEqual(@as(i16, -10), block.stack_req);
    try std.testing.expectEqual(@as(i16, 20), block.stack_max);
}

test "BlockMetadataHeap exact size allocation" {
    const allocator = std.testing.allocator;
    
    // Test with small number of blocks
    var small = try BlockMetadataHeap.init(allocator, 5);
    defer small.deinit();
    try std.testing.expectEqual(@as(usize, 5), small.gas_costs.len);
    
    // Test with single block
    var single = try BlockMetadataHeap.init(allocator, 1);
    defer single.deinit();
    try std.testing.expectEqual(@as(usize, 1), single.gas_costs.len);
    
    // Test with larger number
    var large = try BlockMetadataHeap.init(allocator, 1000);
    defer large.deinit();
    try std.testing.expectEqual(@as(usize, 1000), large.gas_costs.len);
}