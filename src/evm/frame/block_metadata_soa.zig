const std = @import("std");
const BlockMetadata = @import("block_metadata.zig");
const limits = @import("../constants/code_analysis_limits.zig");

/// Structure of Arrays implementation for block metadata.
///
/// This optimized layout separates the BlockMetadata fields into separate arrays
/// for better cache efficiency. Instead of loading 8 bytes per block access
/// (with only partial field usage), this allows loading only the needed data.
///
/// ## Cache Benefits
/// - Gas validation loads only gas_costs array (4 bytes per block)
/// - Stack validation loads only stack arrays (2-4 bytes per block)
/// - 50% less memory bandwidth for common operations
///
/// ## Memory Layout
/// All arrays are fixed-size with MAX_BLOCKS elements.
/// Only the first `count` elements are valid.
const BlockMetadataSoA = @This();

/// Total gas cost for each block (hot data - accessed for gas validation)
gas_costs: [limits.MAX_BLOCKS]u32,

/// Minimum stack items required at block entry (hot data - accessed for stack validation)
/// Can be negative to indicate stack consumption
stack_reqs: [limits.MAX_BLOCKS]i16,

/// Maximum stack growth during block execution (cold data - only for overflow checks)
stack_max_growths: [limits.MAX_BLOCKS]i16,

/// Number of valid blocks (rest are undefined)
count: u16,

/// Initialize with zero blocks
pub fn init() BlockMetadataSoA {
    return BlockMetadataSoA{
        .gas_costs = undefined,
        .stack_reqs = undefined,
        .stack_max_growths = undefined,
        .count = 0,
    };
}

/// Set metadata for a specific block
pub fn setBlock(self: *BlockMetadataSoA, index: u16, gas_cost: u32, stack_req: i16, stack_max_growth: i16) void {
    std.debug.assert(index < self.count);
    std.debug.assert(index < limits.MAX_BLOCKS);
    self.gas_costs[index] = gas_cost;
    self.stack_reqs[index] = stack_req;
    self.stack_max_growths[index] = stack_max_growth;
}

/// Get gas cost for a block (optimized for hot path)
pub inline fn getGasCost(self: *const BlockMetadataSoA, index: u16) u32 {
    std.debug.assert(index < self.count);
    return self.gas_costs[index];
}

/// Get stack requirement for a block (optimized for hot path)
pub inline fn getStackReq(self: *const BlockMetadataSoA, index: u16) i16 {
    std.debug.assert(index < self.count);
    return self.stack_reqs[index];
}

/// Get stack max growth for a block
pub inline fn getStackMaxGrowth(self: *const BlockMetadataSoA, index: u16) i16 {
    std.debug.assert(index < self.count);
    return self.stack_max_growths[index];
}

/// Get all metadata for a block (when all fields are needed)
pub fn getBlock(self: *const BlockMetadataSoA, index: u16) BlockMetadata {
    std.debug.assert(index < self.count);
    return BlockMetadata{
        .gas_cost = self.gas_costs[index],
        .stack_req = self.stack_reqs[index],
        .stack_max = self.stack_max_growths[index],
    };
}

test "BlockMetadataSoA initialization and access" {
    // Test initialization
    var soa = BlockMetadataSoA.init();
    soa.count = 100;

    try std.testing.expectEqual(@as(u16, 100), soa.count);

    // Test setBlock and individual getters
    soa.setBlock(50, 1000, -10, 20);
    try std.testing.expectEqual(@as(u32, 1000), soa.getGasCost(50));
    try std.testing.expectEqual(@as(i16, -10), soa.getStackReq(50));
    try std.testing.expectEqual(@as(i16, 20), soa.getStackMaxGrowth(50));

    // Test getBlock (all fields)
    const block = soa.getBlock(50);
    try std.testing.expectEqual(@as(u32, 1000), block.gas_cost);
    try std.testing.expectEqual(@as(i16, -10), block.stack_req);
    try std.testing.expectEqual(@as(i16, 20), block.stack_max);

    // Test empty initialization
    const empty = BlockMetadataSoA.init();
    try std.testing.expectEqual(@as(u16, 0), empty.count);
}

test "BlockMetadataSoA boundary conditions" {
    // Test with single block
    var single = BlockMetadataSoA.init();
    single.count = 1;
    
    single.setBlock(0, 100, 5, 10);
    try std.testing.expectEqual(@as(u32, 100), single.getGasCost(0));
    try std.testing.expectEqual(@as(i16, 5), single.getStackReq(0));
    try std.testing.expectEqual(@as(i16, 10), single.getStackMaxGrowth(0));
    
    // Test with many blocks
    var large = BlockMetadataSoA.init();
    large.count = limits.MAX_BLOCKS;
    
    // Set first and last blocks
    large.setBlock(0, 1, 1, 1);
    large.setBlock(limits.MAX_BLOCKS - 1, 9999, -9999, 9999);
    
    try std.testing.expectEqual(@as(u32, 1), large.getGasCost(0));
    try std.testing.expectEqual(@as(u32, 9999), large.getGasCost(limits.MAX_BLOCKS - 1));
    try std.testing.expectEqual(@as(i16, -9999), large.getStackReq(limits.MAX_BLOCKS - 1));
}

test "BlockMetadataSoA extreme values" {
    var soa = BlockMetadataSoA.init();
    soa.count = 10;
    
    // Test maximum values
    soa.setBlock(0, std.math.maxInt(u32), std.math.maxInt(i16), std.math.maxInt(i16));
    const max_block = soa.getBlock(0);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), max_block.gas_cost);
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), max_block.stack_req);
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), max_block.stack_max);
    
    // Test minimum values
    soa.setBlock(1, 0, std.math.minInt(i16), std.math.minInt(i16));
    const min_block = soa.getBlock(1);
    try std.testing.expectEqual(@as(u32, 0), min_block.gas_cost);
    try std.testing.expectEqual(@as(i16, std.math.minInt(i16)), min_block.stack_req);
    try std.testing.expectEqual(@as(i16, std.math.minInt(i16)), min_block.stack_max);
}

test "BlockMetadataSoA multiple operations" {
    var soa = BlockMetadataSoA.init();
    soa.count = 5;
    
    // Set all blocks with different values
    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        soa.setBlock(i, @as(u32, i * 100), @as(i16, @intCast(i)) - 2, @as(i16, @intCast(i * 2)));
    }
    
    // Verify all blocks
    i = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(@as(u32, i * 100), soa.getGasCost(i));
        try std.testing.expectEqual(@as(i16, @intCast(i)) - 2, soa.getStackReq(i));
        try std.testing.expectEqual(@as(i16, @intCast(i * 2)), soa.getStackMaxGrowth(i));
        
        const block = soa.getBlock(i);
        try std.testing.expectEqual(@as(u32, i * 100), block.gas_cost);
        try std.testing.expectEqual(@as(i16, @intCast(i)) - 2, block.stack_req);
        try std.testing.expectEqual(@as(i16, @intCast(i * 2)), block.stack_max);
    }
}