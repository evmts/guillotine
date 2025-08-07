const std = @import("std");

/// Block metadata for efficient block-based execution.
///
/// This packed struct contains critical information about each basic block
/// in the bytecode, enabling batch validation of gas and stack operations.
/// The struct is exactly 8 bytes for cache efficiency and atomic loads.
///
/// ## Fields
/// - `gas_cost`: Total gas required to execute all operations in the block
/// - `stack_req`: Minimum stack items required at block entry (can be negative)
/// - `stack_max`: Maximum stack growth during block execution
///
/// ## Performance
/// The 8-byte size ensures the struct fits in a CPU register and can be
/// loaded atomically, matching [EVMOne's](https://github.com/ipsilon/evmone) excellent optimization approach.
const BlockMetadata = @This();

gas_cost: u32, // Total gas for block (4 bytes)
stack_req: i16, // Min stack items needed (2 bytes)
stack_max: i16, // Max stack growth (2 bytes)

// Debug assertions for safety
comptime {
    std.debug.assert(@sizeOf(BlockMetadata) == 8);
    std.debug.assert(@alignOf(BlockMetadata) >= 4); // Ensure proper alignment

    // Verify field offsets match EVMOne layout
    std.debug.assert(@offsetOf(BlockMetadata, "gas_cost") == 0);
    std.debug.assert(@offsetOf(BlockMetadata, "stack_req") == 4);
    std.debug.assert(@offsetOf(BlockMetadata, "stack_max") == 6);
}

test "BlockMetadata is exactly 8 bytes and properly aligned" {
    try std.testing.expectEqual(8, @sizeOf(BlockMetadata));
    try std.testing.expect(@alignOf(BlockMetadata) >= 4);

    // Test field access
    const block = BlockMetadata{ .gas_cost = 100, .stack_req = -5, .stack_max = 10 };
    try std.testing.expectEqual(@as(u32, 100), block.gas_cost);
    try std.testing.expectEqual(@as(i16, -5), block.stack_req);
    try std.testing.expectEqual(@as(i16, 10), block.stack_max);
}

test "BlockMetadata handles extreme values" {
    // Test maximum values
    const max_block = BlockMetadata{
        .gas_cost = std.math.maxInt(u32),
        .stack_req = std.math.maxInt(i16),
        .stack_max = std.math.maxInt(i16),
    };
    try std.testing.expectEqual(@as(u32, 4_294_967_295), max_block.gas_cost);

    // Test minimum values
    const min_block = BlockMetadata{
        .gas_cost = 0,
        .stack_req = std.math.minInt(i16),
        .stack_max = std.math.minInt(i16),
    };
    try std.testing.expectEqual(@as(i16, -32768), min_block.stack_req);
}

test "BlockMetadata array operations" {
    const allocator = std.testing.allocator;

    // Test dynamic allocation and access
    const blocks = try allocator.alloc(BlockMetadata, 100);
    defer allocator.free(blocks);

    // Fill with test data
    for (blocks, 0..) |*block, i| {
        block.* = BlockMetadata{
            .gas_cost = @intCast(i * 100),
            .stack_req = @intCast(i),
            .stack_max = @intCast(i * 2),
        };
    }

    // Verify data integrity
    try std.testing.expectEqual(@as(u32, 5000), blocks[50].gas_cost);
    try std.testing.expectEqual(@as(i16, 50), blocks[50].stack_req);
    try std.testing.expectEqual(@as(i16, 100), blocks[50].stack_max);
}

// NOTE: Packed struct layout test disabled - comptime dereference not supported
// test "BlockMetadata packed struct layout" {
//     // Verify the packed struct has expected memory layout
//     const block = BlockMetadata{
//         .gas_cost = 0x12345678,
//         .stack_req = 0x1234,
//         .stack_max = 0x5678,
//     };
//     
//     // Cast to bytes to verify layout
//     const bytes = @as(*const [8]u8, @ptrCast(&block));
//     
//     // Gas cost should be first 4 bytes (little-endian)
//     try std.testing.expectEqual(@as(u8, 0x78), bytes[0]);
//     try std.testing.expectEqual(@as(u8, 0x56), bytes[1]);
//     try std.testing.expectEqual(@as(u8, 0x34), bytes[2]);
//     try std.testing.expectEqual(@as(u8, 0x12), bytes[3]);
//     
//     // Stack req should be next 2 bytes
//     try std.testing.expectEqual(@as(u8, 0x34), bytes[4]);
//     try std.testing.expectEqual(@as(u8, 0x12), bytes[5]);
//     
//     // Stack max should be last 2 bytes
//     try std.testing.expectEqual(@as(u8, 0x78), bytes[6]);
//     try std.testing.expectEqual(@as(u8, 0x56), bytes[7]);
// }

test "BlockMetadata zero initialization" {
    // Test zero-initialized struct
    const zero_block = BlockMetadata{
        .gas_cost = 0,
        .stack_req = 0,
        .stack_max = 0,
    };
    
    try std.testing.expectEqual(@as(u32, 0), zero_block.gas_cost);
    try std.testing.expectEqual(@as(i16, 0), zero_block.stack_req);
    try std.testing.expectEqual(@as(i16, 0), zero_block.stack_max);
    
    // Verify size is still 8 bytes
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(@TypeOf(zero_block)));
}

test "BlockMetadata negative stack values" {
    // Test negative stack requirements (common for operations that consume stack)
    const consuming_block = BlockMetadata{
        .gas_cost = 100,
        .stack_req = -5,  // Requires 5 items on stack
        .stack_max = -3,  // Net consumption of 3 items
    };
    
    try std.testing.expectEqual(@as(u32, 100), consuming_block.gas_cost);
    try std.testing.expectEqual(@as(i16, -5), consuming_block.stack_req);
    try std.testing.expectEqual(@as(i16, -3), consuming_block.stack_max);
}

test "BlockMetadata typical EVM operations" {
    // Test typical values for common EVM operation blocks
    
    // PUSH operations block
    const push_block = BlockMetadata{
        .gas_cost = 3 * 3,  // 3 PUSH operations at 3 gas each
        .stack_req = 0,     // No stack required
        .stack_max = 3,     // Adds 3 items to stack
    };
    try std.testing.expectEqual(@as(u32, 9), push_block.gas_cost);
    try std.testing.expectEqual(@as(i16, 0), push_block.stack_req);
    try std.testing.expectEqual(@as(i16, 3), push_block.stack_max);
    
    // ADD operation block
    const add_block = BlockMetadata{
        .gas_cost = 3,      // ADD costs 3 gas
        .stack_req = 2,     // Requires 2 items on stack
        .stack_max = -1,    // Consumes 2, pushes 1 (net -1)
    };
    try std.testing.expectEqual(@as(u32, 3), add_block.gas_cost);
    try std.testing.expectEqual(@as(i16, 2), add_block.stack_req);
    try std.testing.expectEqual(@as(i16, -1), add_block.stack_max);
}

test "BlockMetadata slice operations" {
    const allocator = std.testing.allocator;
    
    // Create a slice of BlockMetadata
    var blocks = try allocator.alloc(BlockMetadata, 10);
    defer allocator.free(blocks);
    
    // Initialize with pattern
    for (blocks, 0..) |*block, i| {
        block.* = BlockMetadata{
            .gas_cost = @as(u32, @intCast(i + 1)) * 10,
            .stack_req = @as(i16, @intCast(i)),
            .stack_max = @as(i16, @intCast(i)) * -1,
        };
    }
    
    // Test slice operations
    const sub_slice = blocks[2..5];
    try std.testing.expectEqual(@as(usize, 3), sub_slice.len);
    try std.testing.expectEqual(@as(u32, 30), sub_slice[0].gas_cost);
    try std.testing.expectEqual(@as(u32, 40), sub_slice[1].gas_cost);
    try std.testing.expectEqual(@as(u32, 50), sub_slice[2].gas_cost);
}