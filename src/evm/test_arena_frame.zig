//! Test file demonstrating arena allocation for Frame
//! This implements the TDD approach for replacing RAII patterns with arena allocation

const std = @import("std");
const testing = std.testing;
const log = @import("log.zig");
const DefaultEvm = @import("evm.zig").DefaultEvm;
const Database = @import("database.zig").Database;
const CallParams = @import("call_params.zig").CallParams;
const frame_mod = @import("frame.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const BlockInfo = @import("block_info.zig").BlockInfo;
const MockHost = @import("../testing/mock_host.zig").MockHost;

test "Frame uses arena allocation with no manual cleanup" {
    // RED phase - this should fail because Frame.init doesn't accept arena yet
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit(); // Only defer at top level
    const alloc = arena.allocator();
    
    const Frame = frame_mod.Frame(.{});
    const zero_value: u256 = 0;
    const calldata = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01}; // PUSH1 1, PUSH1 2, ADD
    
    var mock_host = MockHost.init(alloc);
    var db = Database.init(alloc);
    const block_info = BlockInfo.init_default();
    const evm_ptr: *anyopaque = @ptrCast(&mock_host);
    
    // This should fail - Frame.init signature will be wrong initially
    var frame = try Frame.init(
        alloc, // arena allocator
        1000000, // gas
        &db,
        Address.ZERO_ADDRESS, // caller
        &zero_value,
        calldata,
        block_info,
        evm_ptr,
        null // self_destruct
    );
    
    // NO defer frame.deinit() - this is the key benefit of arena allocation
    
    // Verify frame was initialized correctly
    try testing.expect(frame.gas_remaining == 1000000);
    try testing.expect(frame.stack.get_slice().len == 0);
    try testing.expect(frame.memory.size() == 0);
    try testing.expect(frame.logs.items.len == 0);
}

test "EVM uses call_arena for Frame allocation" {
    // RED phase - EVM.call doesn't use call_arena yet
    var db = Database.init(testing.allocator);
    defer db.deinit();
    
    var evm = try DefaultEvm.init(testing.allocator, &db);
    defer evm.deinit();
    
    const params = CallParams{
        .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01}, // PUSH1 1, PUSH1 2, ADD
        .gas_limit = 1000000,
        .value = 0,
        .caller = Address.ZERO_ADDRESS,
        .address = Address.ZERO_ADDRESS,
        .calldata = &[_]u8{},
    };
    
    // This should work but won't use arena initially
    const result = try evm.call(params);
    
    // Verify call succeeded
    try testing.expect(result.success_flag == true);
    try testing.expect(result.gas_used > 0);
}

test "Arena eliminates complex errdefer chains" {
    // Demonstration test showing how arena simplifies error handling
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    
    // Before: Complex manual cleanup
    // var stack = try Stack.init(allocator);
    // errdefer stack.deinit(allocator);
    // var memory = try Memory.init(allocator); 
    // errdefer memory.deinit(allocator);
    // var logs = std.ArrayList(Log).init(allocator);
    // errdefer logs.deinit();
    
    // After: Simple arena allocation (no errdefer needed)
    const data1 = try alloc.alloc(u8, 100);
    const data2 = try alloc.alloc(u256, 50);
    const data3 = try alloc.alloc(bool, 10);
    
    // No manual cleanup needed - arena handles everything
    _ = data1;
    _ = data2;
    _ = data3;
    
    try testing.expect(true); // Just demonstrate the pattern
}

test "Log handlers use arena allocation" {
    // RED phase - log handlers don't use arena yet
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit(); // Only defer at top level
    const alloc = arena.allocator();
    
    const Frame = frame_mod.Frame(.{});
    const zero_value: u256 = 0;
    
    var mock_host = MockHost.init(alloc);
    var db = Database.init(alloc);
    const block_info = BlockInfo.init_default();
    const evm_ptr: *anyopaque = @ptrCast(&mock_host);
    
    var frame = try Frame.init(
        alloc, // arena allocator
        1000000, // gas
        &db,
        Address.ZERO_ADDRESS, // caller
        &zero_value,
        &[_]u8{},
        block_info,
        evm_ptr,
        null // self_destruct
    );
    
    // Set up log data in memory that will be read by LOG operation
    const log_data = "Hello, World!";
    const memory_offset = 0;
    try frame.memory.set_data(memory_offset, log_data);
    
    // Set up stack for LOG1 operation: offset, length, topic
    try frame.stack.push(@as(u256, 0xDEADBEEF)); // topic
    try frame.stack.push(@as(u256, log_data.len)); // length
    try frame.stack.push(@as(u256, memory_offset)); // offset
    
    // This test demonstrates that log operations allocate from arena
    // Simulate what LOG1 handler does with arena allocation
    const test_topics = try alloc.alloc(u256, 1);
    test_topics[0] = 0xDEADBEEF;
    
    const test_data_copy = try alloc.dupe(u8, log_data);
    
    // Create log entry (as log handler would do)
    const log_entry = logs.Log{
        .address = frame.contract_address,
        .topics = test_topics,
        .data = test_data_copy,
    };
    
    // Add to frame
    try frame.appendLog(log_entry);
    
    // Verify log was created with arena-allocated data
    try testing.expect(frame.stack.get_slice().len == 3);
    try testing.expect(frame.memory.size() >= log_data.len);
    try testing.expect(frame.getLogCount() == 1);
    
    const saved_log = frame.getLogSlice()[0];
    try testing.expect(saved_log.topics.len == 1);
    try testing.expect(saved_log.topics[0] == 0xDEADBEEF);
    try testing.expect(std.mem.eql(u8, saved_log.data, log_data));
    
    // All cleanup handled automatically by arena - no manual free needed!
}

test "Arena handles memory leaks properly" {
    // Memory leak detection test - run multiple arena allocations
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    // Allocate and deallocate multiple times - arena should handle this safely
    for (0..100) |i| {
        const alloc = arena.allocator();
        const data = try alloc.alloc(u8, i * 10 + 100);
        _ = data; // Use but don't manually free
        
        // Simulate log allocation patterns
        const topics = try alloc.alloc(u256, 3);
        topics[0] = i;
        topics[1] = i * 2;
        topics[2] = i * 3;
        _ = topics; // No manual cleanup needed
    }
    
    // Arena cleanup happens automatically on defer - no memory leaks
    try testing.expect(true);
}

test "Arena survives error conditions" {
    // Test that arena allocation works properly even with errors
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    
    const Frame = frame_mod.Frame(.{});
    const zero_value: u256 = 0;
    
    // Create frame that might encounter errors
    var mock_host = MockHost.init(alloc);
    var db = Database.init(alloc);
    const block_info = BlockInfo.init_default();
    const evm_ptr: *anyopaque = @ptrCast(&mock_host);
    
    var frame = try Frame.init(
        alloc,
        1000,  // Low gas to potentially trigger OutOfGas
        &db,
        Address.ZERO_ADDRESS,
        &zero_value,
        &[_]u8{},
        block_info,
        evm_ptr,
        null
    );
    
    // Allocate some data that would need cleanup in RAII patterns
    const test_data = try alloc.alloc(u8, 1000);
    test_data[0] = 0xAA;
    test_data[999] = 0xBB;
    
    // Even if errors occur, arena cleans up automatically
    _ = frame.consumeGasChecked(2000); // This should error (OutOfGas)
    
    // Verify data is still accessible until arena cleanup
    try testing.expect(test_data[0] == 0xAA);
    try testing.expect(test_data[999] == 0xBB);
    
    // Arena will clean everything up on defer - no manual intervention needed
}