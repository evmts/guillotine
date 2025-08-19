//! End-to-end tests for the pre-allocation system

const std = @import("std");
const StackFrame = @import("stack_frame.zig").StackFrame;
const AllocationTier = @import("allocation_tier.zig").AllocationTier;
const analysis2 = @import("evm/analysis2.zig");
const interpret2 = @import("evm/interpret2.zig");
const Host = @import("host.zig").Host;
const primitives = @import("primitives");
const MemoryDatabase = @import("state/memory_database.zig");

test "pre-allocation tiny contract" {
    const allocator = std.testing.allocator;
    
    // Create a tiny contract (< 4KB)
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0A, // PUSH1 10
        0x01,       // ADD
        0x00,       // STOP
    };
    
    // Create database and host
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create frame with tiered allocation
    var frame = try StackFrame.init_with_bytecode_size(
        bytecode.len,
        1000000, // gas
        primitives.Address.Address.ZERO,
        Host.init(null),
        db_interface,
        allocator,
    );
    defer frame.deinit();
    
    // Verify tier selection
    const tier = AllocationTier.select_tier(bytecode.len);
    try std.testing.expectEqual(AllocationTier.tiny, tier);
    
    // Pre-allocate analysis arrays
    const buffer_allocator = frame.get_buffer_allocator();
    
    const inst_to_pc = try buffer_allocator.alloc(u16, bytecode.len);
    const pc_to_inst = try buffer_allocator.alloc(u16, bytecode.len);
    const metadata = try buffer_allocator.alloc(u32, bytecode.len);
    const ops = try buffer_allocator.alloc(*const anyopaque, bytecode.len + 1);
    
    // Prepare analysis
    const prep_result = try analysis2.prepare_with_buffers(
        inst_to_pc,
        pc_to_inst,
        metadata,
        ops,
        bytecode,
    );
    
    // Update frame
    frame.analysis = prep_result.analysis;
    frame.metadata = prep_result.metadata;
    frame.ops = prep_result.ops;
    
    // Verify stack operations work
    try frame.stack.push(42);
    const val = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 42), val);
}

test "pre-allocation medium contract" {
    const allocator = std.testing.allocator;
    
    // Create a medium contract (~16KB like Snailtracer)
    const bytecode_size = 16000;
    const bytecode = try allocator.alloc(u8, bytecode_size);
    defer allocator.free(bytecode);
    
    // Fill with dummy opcodes
    for (bytecode, 0..) |*byte, i| {
        if (i % 2 == 0) {
            byte.* = 0x60; // PUSH1
        } else {
            byte.* = @intCast(i % 256); // Push value
        }
    }
    bytecode[bytecode.len - 1] = 0x00; // STOP
    
    // Create database and host
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create frame with tiered allocation
    var frame = try StackFrame.init_with_bytecode_size(
        bytecode.len,
        1000000, // gas
        primitives.Address.Address.ZERO,
        Host.init(null),
        db_interface,
        allocator,
    );
    defer frame.deinit();
    
    // Verify tier selection
    const tier = AllocationTier.select_tier(bytecode.len);
    try std.testing.expectEqual(AllocationTier.medium, tier);
    
    // Pre-allocate and prepare analysis
    const buffer_allocator = frame.get_buffer_allocator();
    
    const inst_to_pc = try buffer_allocator.alloc(u16, bytecode.len);
    const pc_to_inst = try buffer_allocator.alloc(u16, bytecode.len);
    const metadata = try buffer_allocator.alloc(u32, bytecode.len);
    const ops = try buffer_allocator.alloc(*const anyopaque, bytecode.len + 1);
    
    const prep_result = try analysis2.prepare_with_buffers(
        inst_to_pc,
        pc_to_inst,
        metadata,
        ops,
        bytecode,
    );
    
    frame.analysis = prep_result.analysis;
    frame.metadata = prep_result.metadata;
    frame.ops = prep_result.ops;
    
    // Verify operations work with medium-sized contract
    try frame.stack.push(100);
    try frame.stack.push(200);
    const sum = try frame.stack.pop() + try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 300), sum);
}

test "pre-allocation huge contract" {
    const allocator = std.testing.allocator;
    
    // Create a huge contract (64KB max)
    const bytecode_size = 60000;
    const bytecode = try allocator.alloc(u8, bytecode_size);
    defer allocator.free(bytecode);
    
    // Fill with pattern
    @memset(bytecode, 0x01); // ADD opcodes
    bytecode[0] = 0x60; // PUSH1
    bytecode[1] = 0x05;
    bytecode[bytecode.len - 1] = 0x00; // STOP
    
    // Create database and host
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create frame with tiered allocation
    var frame = try StackFrame.init_with_bytecode_size(
        bytecode.len,
        1000000, // gas
        primitives.Address.Address.ZERO,
        Host.init(null),
        db_interface,
        allocator,
    );
    defer frame.deinit();
    
    // Verify tier selection
    const tier = AllocationTier.select_tier(bytecode.len);
    try std.testing.expectEqual(AllocationTier.huge, tier);
    
    // Verify we can still allocate everything needed
    const buffer_allocator = frame.get_buffer_allocator();
    
    const inst_to_pc = try buffer_allocator.alloc(u16, bytecode.len);
    const pc_to_inst = try buffer_allocator.alloc(u16, bytecode.len);
    const metadata = try buffer_allocator.alloc(u32, bytecode.len);
    const ops = try buffer_allocator.alloc(*const anyopaque, bytecode.len + 1);
    
    // All allocations should succeed
    try std.testing.expect(inst_to_pc.len >= bytecode.len);
    try std.testing.expect(pc_to_inst.len >= bytecode.len);
    try std.testing.expect(metadata.len >= bytecode.len);
    try std.testing.expect(ops.len >= bytecode.len + 1);
}

test "pre-allocation memory savings" {
    const allocator = std.testing.allocator;
    
    // Test that small contracts use less memory than the old approach
    const small_bytecode_size = 1000;
    const old_allocation_size = 1024 * 1024; // 1MB fixed
    
    // Calculate new allocation size
    const tier = AllocationTier.select_tier(small_bytecode_size);
    const new_allocation_size = tier.buffer_size();
    
    // Verify significant savings
    try std.testing.expect(new_allocation_size < old_allocation_size);
    try std.testing.expect(new_allocation_size < old_allocation_size / 2); // At least 50% savings
    
    // Log the savings
    const savings_percent = (old_allocation_size - new_allocation_size) * 100 / old_allocation_size;
    std.debug.print("\nMemory savings for {d} byte contract: {d}% ({d} KB saved)\n", .{
        small_bytecode_size,
        savings_percent,
        (old_allocation_size - new_allocation_size) / 1024,
    });
}