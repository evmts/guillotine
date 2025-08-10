const std = @import("std");
const Memory = @import("memory.zig");
const MemoryError = Memory.MemoryError;
const INITIAL_CAPACITY = Memory.INITIAL_CAPACITY;
const DEFAULT_MEMORY_LIMIT = Memory.DEFAULT_MEMORY_LIMIT;
const calculate_num_words = Memory.calculate_num_words;

// Fuzz testing functions
pub fn fuzz_memory_operations(allocator: std.mem.Allocator, operations: []const FuzzMemoryOperation) !void {
    var memory = try Memory.init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();

    const testing = std.testing;

    for (operations) |op| {
        switch (op) {
            .set_data => |data_op| {
                const result = memory.set_data(data_op.offset, data_op.data);

                if (data_op.offset > memory.memory_limit or
                    data_op.data.len > memory.memory_limit or
                    data_op.offset > memory.memory_limit - data_op.data.len)
                {
                    try testing.expectError(MemoryError.MemoryLimitExceeded, result);
                } else {
                    try result;

                    // Verify the data was written correctly
                    const read_data = try memory.get_slice(data_op.offset, data_op.data.len);
                    try testing.expectEqualSlices(u8, data_op.data, read_data);
                }
            },
            .set_u256 => |u256_op| {
                const result = memory.set_u256(u256_op.offset, u256_op.value);

                if (u256_op.offset > memory.memory_limit or
                    u256_op.offset > memory.memory_limit - 32)
                {
                    try testing.expectError(MemoryError.MemoryLimitExceeded, result);
                } else {
                    try result;

                    // Verify the u256 was written correctly
                    const read_value = try memory.get_u256(u256_op.offset);
                    try testing.expectEqual(u256_op.value, read_value);
                }
            },
            .get_data => |get_op| {
                const result = memory.get_slice(get_op.offset, get_op.length);

                if (get_op.offset > memory.memory_limit or
                    get_op.length > memory.memory_limit or
                    get_op.offset > memory.memory_limit - get_op.length)
                {
                    try testing.expectError(MemoryError.InvalidOffset, result);
                } else {
                    _ = try result;
                }
            },
            .resize => |new_size| {
                const result = memory.resize_context(new_size);

                if (new_size > memory.memory_limit) {
                    try testing.expectError(MemoryError.InvalidSize, result);
                } else {
                    try result;
                    try testing.expect(memory.context_size() >= new_size);
                }
            },
        }

        try validate_memory_invariants(&memory);
    }
}

const FuzzMemoryOperation = union(enum) {
    set_data: struct {
        offset: usize,
        data: []const u8,
    },
    set_u256: struct {
        offset: usize,
        value: u256,
    },
    get_data: struct {
        offset: usize,
        length: usize,
    },
    resize: usize,
};

fn validate_memory_invariants(memory: *const Memory) !void {
    const testing = std.testing;

    // Memory size should never exceed the limit
    try testing.expect(memory.context_size() <= memory.memory_limit);

    // Checkpoint should be valid
    try testing.expect(memory.my_checkpoint <= memory.shared_buffer_ref.items.len);

    // Buffer ownership should be consistent
    try testing.expect(memory.owns_buffer or memory.my_checkpoint > 0);
}

// test "fuzz_memory_basic_operations" {
//     const allocator = std.testing.allocator;
//     const test_data = "Hello, World!";
//
//     const operations = [_]FuzzMemoryOperation{
//         .{ .set_data = .{ .offset = 0, .data = test_data } },
//         .{ .get_data = .{ .offset = 0, .length = test_data.len } },
//         .{ .set_u256 = .{ .offset = 32, .value = 0x123456789ABCDEF } },
//         .{ .get_data = .{ .offset = 32, .length = 32 } },
//         .{ .resize = 128 },
//     };
//
//     try fuzz_memory_operations(allocator, &operations);
// }

// test "fuzz_memory_boundary_conditions" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzMemoryOperation{
//         .{ .set_data = .{ .offset = 0, .data = "" } }, // Empty data
//         .{ .set_u256 = .{ .offset = 0, .value = 0 } }, // Zero value
//         .{ .set_u256 = .{ .offset = 0, .value = std.math.maxInt(u256) } }, // Max value
//         .{ .get_data = .{ .offset = 0, .length = 0 } }, // Zero length read
//         .{ .resize = 0 }, // Resize to zero
//     };
//
//     try fuzz_memory_operations(allocator, &operations);
// }

// test "fuzz_memory_overflow_cases" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzMemoryOperation{
//         .{ .set_data = .{ .offset = std.math.maxInt(usize) - 10, .data = "overflow" } },
//         .{ .set_u256 = .{ .offset = std.math.maxInt(usize) - 10, .value = 123 } },
//         .{ .get_data = .{ .offset = std.math.maxInt(usize) - 10, .length = 100 } },
//         .{ .resize = std.math.maxInt(usize) },
//     };
//
//     try fuzz_memory_operations(allocator, &operations);
// }

// test "fuzz_memory_random_operations" {
//     const global = struct {
//         fn testRandomMemoryOperations(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//
//             const allocator = std.testing.allocator;
//             var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
//             defer operations.deinit();
//
//             var test_data_storage = std.ArrayList([]u8).init(allocator);
//             defer {
//                 for (test_data_storage.items) |data| {
//                     allocator.free(data);
//                 }
//                 test_data_storage.deinit();
//             }
//
//             // Limit operations for performance, using input length as a guide
//             const max_ops = @min((input.len / 16), 50);
//
//             for (0..max_ops) |i| {
//                 const base_idx = i * 16;
//                 if (base_idx + 16 > input.len) break;
//
//                 const op_type = input[base_idx] % 4; // 0-3 operation types
//
//                 switch (op_type) {
//                     0 => {
//                         // set_data operation
//                         const data_len = (input[base_idx + 1] % 100); // 0-99 bytes
//                         const data = try allocator.alloc(u8, data_len);
//
//                         // Fill data with fuzz input
//                         for (data, 0..) |*byte, data_idx| {
//                             const src_idx = base_idx + 2 + (data_idx % 14);
//                             if (src_idx < input.len) {
//                                 byte.* = input[src_idx];
//                             } else {
//                                 byte.* = @as(u8, @intCast(data_idx % 256));
//                             }
//                         }
//                         try test_data_storage.append(data);
//
//                         const offset = std.mem.readInt(u16, input[base_idx + 2..base_idx + 4], .little) % 1000;
//                         try operations.append(.{ .set_data = .{ .offset = offset, .data = data } });
//                     },
//                     1 => {
//                         // set_u256 operation
//                         const offset = std.mem.readInt(u16, input[base_idx + 1..base_idx + 3], .little) % 1000;
//                         const value = std.mem.readInt(u64, input[base_idx + 3..base_idx + 11], .little);
//                         try operations.append(.{ .set_u256 = .{ .offset = offset, .value = @as(u256, value) } });
//                     },
//                     2 => {
//                         // get_data operation
//                         const offset = std.mem.readInt(u16, input[base_idx + 1..base_idx + 3], .little) % 1000;
//                         const length = input[base_idx + 3] % 100;
//                         try operations.append(.{ .get_data = .{ .offset = offset, .length = length } });
//                     },
//                     3 => {
//                         // resize operation
//                         const new_size = std.mem.readInt(u16, input[base_idx + 1..base_idx + 3], .little) % 2000;
//                         try operations.append(.{ .resize = new_size });
//                     },
//                     else => unreachable,
//                 }
//             }
//
//             try fuzz_memory_operations(allocator, operations.items);
//         }
//     };
//     try std.testing.fuzz(global.testRandomMemoryOperations, .{}, .{});
// }

// test "fuzz_memory_edge_values" {
//     const allocator = std.testing.allocator;
//
//     const edge_values = [_]u256{
//         0,
//         1,
//         std.math.maxInt(u8),
//         std.math.maxInt(u16),
//         std.math.maxInt(u32),
//         std.math.maxInt(u64),
//         std.math.maxInt(u128),
//         std.math.maxInt(u256),
//         1 << 128,
//         1 << 255,
//     };
//
//     var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
//     defer operations.deinit();
//
//     for (edge_values, 0..) |value, idx| {
//         try operations.append(.{ .set_u256 = .{ .offset = idx * 32, .value = value } });
//     }
//
//     try fuzz_memory_operations(allocator, operations.items);
// }

// test "fuzz_memory_alignment_patterns" {
//     const allocator = std.testing.allocator;
//
//     var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
//     defer operations.deinit();
//
//     // Test various alignment patterns
//     const alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256 };
//
//     for (alignments) |alignment| {
//         const offset = alignment;
//         try operations.append(.{ .set_u256 = .{ .offset = offset, .value = 0xDEADBEEF } });
//         try operations.append(.{ .get_data = .{ .offset = offset, .length = 32 } });
//     }
//
//     try fuzz_memory_operations(allocator, operations.items);
// }

// test "fuzz_memory_bounded_operations" {
//     const allocator = std.testing.allocator;
//
//     var memory = try Memory.init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
//     defer memory.deinit();
//
//     const source_data = "Hello, World! This is a test string for bounded operations.";
//
//     // Test various bounded write scenarios
//     const test_cases = [_]struct {
//         memory_offset: usize,
//         data_offset: usize,
//         length: usize,
//         should_succeed: bool,
//     }{
//         .{ .memory_offset = 0, .data_offset = 0, .length = 10, .should_succeed = true },
//         .{ .memory_offset = 0, .data_offset = 50, .length = 20, .should_succeed = true }, // Partial copy
//         .{ .memory_offset = 0, .data_offset = 100, .length = 10, .should_succeed = true }, // Zero fill
//         .{ .memory_offset = 0, .data_offset = 0, .length = 0, .should_succeed = true }, // Empty
//     };
//
//     for (test_cases) |test_case| {
//         const result = memory.set_data_bounded(
//             test_case.memory_offset,
//             source_data,
//             test_case.data_offset,
//             test_case.length,
//         );
//
//         if (test_case.should_succeed) {
//             try result;
//         } else {
//             try std.testing.expectError(MemoryError.InvalidSize, result);
//         }
//     }
// }
