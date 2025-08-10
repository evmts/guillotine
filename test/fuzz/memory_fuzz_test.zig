const std = @import("std");
const evm = @import("evm");
const testing = std.testing;

test "fuzz_memory_basic_operations" {
    const allocator = testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    // Test basic data setting and getting
    const test_data = "Hello, World!";
    try memory.set_data(0, test_data);

    const retrieved = try memory.get_slice(0, test_data.len);
    try testing.expectEqualSlices(u8, test_data, retrieved);
}

test "fuzz_memory_u256_operations" {
    const allocator = testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    const test_value: u256 = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0;
    try memory.set_u256(0, test_value);

    const retrieved = try memory.get_u256(0);
    try testing.expectEqual(test_value, retrieved);
}

test "fuzz_memory_expansion" {
    const allocator = testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    // Test memory expansion
    const large_offset = 1000;
    const test_data = "Test data at large offset";

    try memory.set_data(large_offset, test_data);
    const retrieved = try memory.get_slice(large_offset, test_data.len);
    try testing.expectEqualSlices(u8, test_data, retrieved);
}

test "fuzz_memory_edge_cases" {
    const allocator = testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    // Test zero-length operations
    try memory.set_data(0, "");
    const empty_slice = try memory.get_slice(0, 0);
    try testing.expectEqual(@as(usize, 0), empty_slice.len);

    // Test boundary values
    const max_u256 = std.math.maxInt(u256);
    try memory.set_u256(32, max_u256);
    const retrieved_max = try memory.get_u256(32);
    try testing.expectEqual(max_u256, retrieved_max);
}

test "fuzz_memory_bounds_checking" {
    const allocator = testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    // Test that memory properly handles bounds
    const test_data = "Boundary test data";
    try memory.set_data(100, test_data);

    // Should be able to read the data back
    const retrieved = try memory.get_slice(100, test_data.len);
    try testing.expectEqualSlices(u8, test_data, retrieved);

    // Context size should have grown
    const context_size = memory.context_size();
    try testing.expect(context_size >= 100 + test_data.len);
}
