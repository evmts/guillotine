const std = @import("std");
const evm = @import("evm");
const EvmConfig = evm.EvmConfig;
const Memory = evm.Memory;
const testing = std.testing;

pub fn calculate_num_words(len: usize) usize {
    return (len + 31) / 32;
}

// Test basic functionality
test "Memory initialization and basic operations" {
    // Test init with default capacity
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    try testing.expectEqual(@as(usize, 0), mem.context_size());

    // Test custom capacity
    var mem2 = try Memory.init(testing.allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem2.deinit();

    try testing.expectEqual(@as(usize, 0), mem2.context_size());

    // Test with custom memory limit
    var mem3 = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, 1024);
    defer mem3.deinit();

    try testing.expectEqual(@as(u64, 1024), mem3.memory_limit);
}

test "Memory data operations" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    // Test set_data and get_slice
    const test_data = [_]u8{0xAB};
    try mem.set_data(10, &test_data);
    try testing.expectEqual(@as(usize, 11), mem.context_size());

    const slice = try mem.get_slice(10, 1);
    try testing.expectEqual(@as(u8, 0xAB), slice[0]);

    // Test out of bounds
    try testing.expectError(Memory.MemoryError.InvalidOffset, mem.get_slice(11, 1));
}

test "Memory 32-byte data operations" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    // Test 32-byte data using set_data and get_slice
    const word = [32]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    };

    try mem.set_data(64, &word);
    try testing.expectEqual(@as(usize, 96), mem.context_size());

    const read_slice = try mem.get_slice(64, 32);
    try testing.expectEqualSlices(u8, &word, read_slice);

    // Test word at boundary
    try mem.set_data(mem.context_size() - 32, &word);
    const boundary_slice = try mem.get_slice(mem.context_size() - 32, 32);
    try testing.expectEqualSlices(u8, &word, boundary_slice);
}

test "Memory U256 read operations" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    // Test reading from zero-initialized memory
    _ = try mem.ensure_context_capacity(32);
    const read_val = try mem.get_u256(0);
    try testing.expectEqual(@as(u256, 0), read_val);
}

test "Memory slice operations" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    // Test setData and getSlice
    const data = "Hello, EVM Memory!";
    try mem.set_data(100, data);

    const slice = try mem.get_slice(100, data.len);
    try testing.expectEqualSlices(u8, data, slice);

    // Test empty slice
    const empty = try mem.get_slice(0, 0);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // Test out of bounds
    try testing.expectError(Memory.MemoryError.InvalidOffset, mem.get_slice(mem.context_size(), 1));
}

test "Memory setDataBounded" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Test normal copy
    try mem.set_data_bounded(10, &data, 2, 4);
    const result1 = try mem.get_slice(10, 4);
    try testing.expectEqualSlices(u8, data[2..6], result1);

    // Test copy with offset beyond data (should zero-fill)
    try mem.set_data_bounded(20, &data, 10, 4);
    const result2 = try mem.get_slice(20, 4);
    try testing.expectEqual(@as(u8, 0), result2[0]);
    try testing.expectEqual(@as(u8, 0), result2[1]);
    try testing.expectEqual(@as(u8, 0), result2[2]);
    try testing.expectEqual(@as(u8, 0), result2[3]);

    // Test partial copy with zero-fill
    try mem.set_data_bounded(30, &data, 6, 4);
    const result3 = try mem.get_slice(30, 4);
    try testing.expectEqual(@as(u8, 7), result3[0]);
    try testing.expectEqual(@as(u8, 8), result3[1]);
    try testing.expectEqual(@as(u8, 0), result3[2]);
    try testing.expectEqual(@as(u8, 0), result3[3]);
}

test "Memory expansion and gas calculation" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer mem.deinit();

    // Test word calculation
    const new_words1 = try mem.ensure_context_capacity(100);
    try testing.expectEqual(@as(u64, 4), new_words1); // ceil(100/32) = 4 words

    // Test expansion when memory already exists
    const new_words2 = try mem.ensure_context_capacity(150);
    try testing.expectEqual(@as(u64, 1), new_words2); // ceil(150/32) = 5, but we already have 4, so 1 new word

    // Test larger expansion
    const new_words3 = try mem.ensure_context_capacity(1024);
    try testing.expectEqual(@as(u64, 27), new_words3); // Updated expected value based on actual implementation
}

test "Memory limit enforcement" {
    var mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, 1024);
    defer mem.deinit();

    // Should succeed
    _ = try mem.ensure_context_capacity(1024);

    // Should fail - exceeds limit
    try testing.expectError(Memory.MemoryError.MemoryLimitExceeded, mem.ensure_context_capacity(2048));

    // Size should remain unchanged
    try testing.expectEqual(@as(usize, 1024), mem.context_size());
}

test "Memory child memory sharing" {
    // Test root memory and child memory sharing the same buffer
    var root_mem = try Memory.init(testing.allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer root_mem.deinit();

    // Write some data to root memory
    const test_data = "Hello, shared memory!";
    try root_mem.set_data(0, test_data);
    try testing.expectEqual(@as(usize, test_data.len), root_mem.context_size());

    // Create child memory starting at checkpoint 10
    var child_mem = try root_mem.init_child_memory(10);
    defer child_mem.deinit();

    // Child should see shared buffer but from its checkpoint
    try testing.expectEqual(@as(usize, test_data.len - 10), child_mem.context_size());

    // Child can read data that was written by root (after its checkpoint)
    const slice = try child_mem.get_slice(0, 5); // Reading from child's offset 0 = root's offset 10
    try testing.expectEqualSlices(u8, "red m", slice);

    // Child can write data that root can see
    try child_mem.set_data(5, " world");
    
    // Root should see the child's write
    const root_slice = try root_mem.get_slice(15, 6); // Root's offset 15 = child's offset 5
    try testing.expectEqualSlices(u8, " world", root_slice);
}

test "Memory word calculation" {
    // Test word calculation function
    try testing.expectEqual(@as(usize, 0), calculate_num_words(0));
    try testing.expectEqual(@as(usize, 1), calculate_num_words(1));
    try testing.expectEqual(@as(usize, 1), calculate_num_words(32));
    try testing.expectEqual(@as(usize, 2), calculate_num_words(33));
    try testing.expectEqual(@as(usize, 2), calculate_num_words(64));
    try testing.expectEqual(@as(usize, 3), calculate_num_words(65));

    // Test with Memory module function
    try testing.expectEqual(@as(usize, 0), Memory.calculate_num_words(0));
    try testing.expectEqual(@as(usize, 1), Memory.calculate_num_words(1));
    try testing.expectEqual(@as(usize, 1), Memory.calculate_num_words(32));
    try testing.expectEqual(@as(usize, 2), Memory.calculate_num_words(33));
    try testing.expectEqual(@as(usize, 2), Memory.calculate_num_words(64));
    try testing.expectEqual(@as(usize, 3), Memory.calculate_num_words(65));
}
