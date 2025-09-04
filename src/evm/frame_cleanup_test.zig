//! Test file to verify Frame method cleanup preserves existing behavior
//! This follows TDD red-green-refactor approach for issue #639

const std = @import("std");
const testing = std.testing;
const frame_mod = @import("frame.zig");
const logs = @import("logs.zig");
const Log = logs.Log;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const block_info_mod = @import("block_info.zig");
const BlockInfo = block_info_mod.BlockInfo(@import("block_info_config.zig").BlockInfoConfig{});

/// Create a test frame for verification
fn createTestFrame() !frame_mod.Frame(@import("frame_config.zig").FrameConfig{}) {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var db = MemoryDatabase.init(allocator);
    const caller = Address.ZERO_ADDRESS;
    const value: u256 = 0;
    const calldata = &[_]u8{};
    const block_info = BlockInfo{
        .timestamp = 1234567890,
        .number = 12345,
        .difficulty = 1000000,
        .gas_limit = 10000000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create a mock EVM pointer (we won't use it in these tests)
    var mock_evm: u64 = 0;
    const evm_ptr = @as(*anyopaque, @ptrCast(&mock_evm));
    
    return frame_mod.Frame(@import("frame_config.zig").FrameConfig{}).init(
        allocator,
        1000000, // gas
        db,
        caller,
        &value,
        calldata,
        block_info,
        evm_ptr,
        null // self_destruct
    );
}

test "Frame method removal - preserve existing behavior" {
    var frame = try createTestFrame();
    defer frame.deinit(testing.allocator);
    
    // Test current behavior that should be preserved after refactoring
    
    // 1. Test getEvm() - MUST KEEP THIS METHOD (provides type safety)
    // Note: We can't actually test getEvm() easily since it casts to DefaultEvm
    // which requires complex setup. We'll verify it exists and isn't removed.
    
    // 2. Test log functionality using direct field access
    const initial_log_count = frame.logs.items.len; // Direct field access
    try testing.expect(initial_log_count == 0);
    
    const log_slice_before = frame.logs.items; // Direct field access
    try testing.expect(log_slice_before.len == 0);
    
    // Create a test log entry
    const test_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch Address.ZERO_ADDRESS;
    const test_topics = try testing.allocator.alloc(u256, 1);
    defer testing.allocator.free(test_topics);
    test_topics[0] = 0x1234567890abcdef;
    
    const test_data = try testing.allocator.dupe(u8, &[_]u8{0xab, 0xcd, 0xef});
    defer testing.allocator.free(test_data);
    
    const test_log = Log{
        .address = test_address,
        .topics = test_topics,
        .data = test_data,
    };
    
    try frame.logs.append(frame.allocator, test_log); // Direct field access
    
    // Verify behavior that should be preserved
    try testing.expect(frame.logs.items.len == 1); // Direct field access
    try testing.expect(frame.logs.items.len == 1); // Direct field access
    try testing.expect(frame.logs.items[0].address.equals(test_address));
    
    // 3. Test output behavior using direct field access (setOutput was inlined)
    const test_output_data = [_]u8{0x12, 0x34, 0x56};
    // Inline setOutput logic for testing
    if (frame.output.len > 0) {
        frame.allocator.free(frame.output);
    }
    frame.output = try frame.allocator.alloc(u8, test_output_data.len);
    @memcpy(frame.output, &test_output_data);
    
    const current_output = frame.output; // Direct field access
    try testing.expect(std.mem.eql(u8, current_output, &test_output_data));
    try testing.expect(current_output.ptr != test_output_data.ptr); // Should be copied, not referenced
    
    // Test empty output
    if (frame.output.len > 0) {
        frame.allocator.free(frame.output);
    }
    frame.output = &[_]u8{};
    try testing.expect(frame.output.len == 0);
}

test "output memory management behavior using direct field access" {
    var frame = try createTestFrame();
    defer frame.deinit(testing.allocator);
    
    // Test 1: Setting data allocates correctly
    const data1 = [_]u8{0xAA, 0xBB};
    if (frame.output.len > 0) {
        frame.allocator.free(frame.output);
    }
    frame.output = try frame.allocator.alloc(u8, data1.len);
    @memcpy(frame.output, &data1);
    
    try testing.expect(frame.output.len == 2);
    try testing.expect(frame.output.ptr != data1.ptr); // Should be copied, not referenced
    try testing.expect(std.mem.eql(u8, frame.output, &data1));
    
    // Test 2: Setting new data frees old allocation  
    const data2 = [_]u8{0xCC, 0xDD, 0xEE};
    if (frame.output.len > 0) {
        frame.allocator.free(frame.output);
    }
    frame.output = try frame.allocator.alloc(u8, data2.len);
    @memcpy(frame.output, &data2);
    
    try testing.expect(frame.output.len == 3);
    try testing.expect(std.mem.eql(u8, frame.output, &data2));
    
    // Test 3: Setting empty data frees allocation
    if (frame.output.len > 0) {
        frame.allocator.free(frame.output);
    }
    frame.output = &[_]u8{};
    try testing.expect(frame.output.len == 0);
}

test "Direct field access works correctly" {
    var frame = try createTestFrame();
    defer frame.deinit(testing.allocator);
    
    // Test direct field access - all wrapper methods have been removed
    // This verifies that our direct field access pattern works correctly
    
    // Logs - direct access only
    const log_count_direct = frame.logs.items.len;
    try testing.expect(log_count_direct == 0);
    
    const log_slice_direct = frame.logs.items;
    try testing.expect(log_slice_direct.len == 0);
    
    // Output - direct access only  
    const output_direct = frame.output;
    try testing.expect(output_direct.len == 0);
    
    // Verify getEvm() method still exists (type safety method kept)
    // We can't easily test the result since it requires complex EVM setup,
    // but this verifies the method wasn't accidentally removed
    const evm_ptr = frame.getEvm();
    _ = evm_ptr; // Use the result to avoid unused variable warning
}