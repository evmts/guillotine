const std = @import("std");
const constants = @import("constants.zig");

/// Memory implementation for EVM execution contexts.
pub const Memory = @This();

// Re-export error types and constants for convenience
pub const MemoryError = @import("errors.zig").MemoryError;
pub const INITIAL_CAPACITY = constants.INITIAL_CAPACITY;
pub const DEFAULT_MEMORY_LIMIT = constants.DEFAULT_MEMORY_LIMIT;
pub const calculate_num_words = constants.calculate_num_words;

// Core memory struct fields
shared_buffer_ref: *std.ArrayList(u8),
allocator: std.mem.Allocator,
my_checkpoint: usize,
memory_limit: u64,
owns_buffer: bool,

/// Initializes the root Memory context that owns the shared buffer.
/// This is the safe API that eliminates the undefined pointer footgun.
pub fn init(
    allocator: std.mem.Allocator,
    initial_capacity: usize,
    memory_limit: u64,
) !Memory {
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();
    try shared_buffer.ensureTotalCapacity(initial_capacity);

    return Memory{
        .shared_buffer_ref = shared_buffer,
        .allocator = allocator,
        .my_checkpoint = 0,
        .memory_limit = memory_limit,
        .owns_buffer = true,
    };
}

/// Creates a child Memory that shares the buffer with a different checkpoint.
/// Child memory has a view of the shared buffer starting from its checkpoint.
pub fn init_child_memory(self: *Memory, checkpoint: usize) !Memory {
    return Memory{
        .shared_buffer_ref = self.shared_buffer_ref,
        .allocator = self.allocator,
        .my_checkpoint = checkpoint,
        .memory_limit = self.memory_limit,
        .owns_buffer = false,
    };
}

pub fn init_default(allocator: std.mem.Allocator) !Memory {
    return try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
}

/// Deinitializes the Memory. Only root Memory instances clean up the shared buffer.
pub fn deinit(self: *Memory) void {
    if (self.owns_buffer) {
        self.shared_buffer_ref.deinit();
        self.allocator.destroy(self.shared_buffer_ref);
    }
}

// Import and re-export all method implementations
const context_ops = @import("context.zig");
const read_ops = @import("read.zig");
const write_ops = @import("write.zig");
const slice_ops = @import("slice.zig");

// Context operations
pub const context_size = context_ops.context_size;
pub const ensure_context_capacity = context_ops.ensure_context_capacity;
pub const resize_context = context_ops.resize_context;
pub const size = context_ops.size;
pub const total_size = context_ops.total_size;

// Read operations
pub const get_u256 = read_ops.get_u256;
pub const get_slice = read_ops.get_slice;
pub const get_byte = read_ops.get_byte;

// Write operations
pub const set_data = write_ops.set_data;
pub const set_data_bounded = write_ops.set_data_bounded;
pub const set_u256 = write_ops.set_u256;

// Slice operations
pub const slice = slice_ops.slice;

// Fuzz testing functions
pub fn fuzz_memory_operations(allocator: std.mem.Allocator, operations: []const FuzzMemoryOperation) !void {
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    const testing = std.testing;
    
    for (operations) |op| {
        switch (op) {
            .set_data => |data_op| {
                const result = memory.set_data(data_op.offset, data_op.data);
                
                if (data_op.offset > memory.memory_limit or 
                    data_op.data.len > memory.memory_limit or
                    data_op.offset > memory.memory_limit - data_op.data.len) {
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
                    u256_op.offset > memory.memory_limit - 32) {
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
                    get_op.offset > memory.memory_limit - get_op.length) {
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

test "fuzz_memory_basic_operations" {
    const allocator = std.testing.allocator;
    const test_data = "Hello, World!";
    
    const operations = [_]FuzzMemoryOperation{
        .{ .set_data = .{ .offset = 0, .data = test_data } },
        .{ .get_data = .{ .offset = 0, .length = test_data.len } },
        .{ .set_u256 = .{ .offset = 32, .value = 0x123456789ABCDEF } },
        .{ .get_data = .{ .offset = 32, .length = 32 } },
        .{ .resize = 128 },
    };
    
    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_boundary_conditions" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzMemoryOperation{
        .{ .set_data = .{ .offset = 0, .data = "" } }, // Empty data
        .{ .set_u256 = .{ .offset = 0, .value = 0 } }, // Zero value
        .{ .set_u256 = .{ .offset = 0, .value = std.math.maxInt(u256) } }, // Max value
        .{ .get_data = .{ .offset = 0, .length = 0 } }, // Zero length read
        .{ .resize = 0 }, // Resize to zero
    };
    
    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_overflow_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzMemoryOperation{
        .{ .set_data = .{ .offset = std.math.maxInt(usize) - 10, .data = "overflow" } },
        .{ .set_u256 = .{ .offset = std.math.maxInt(usize) - 10, .value = 123 } },
        .{ .get_data = .{ .offset = std.math.maxInt(usize) - 10, .length = 100 } },
        .{ .resize = std.math.maxInt(usize) },
    };
    
    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();
    
    var test_data_storage = std.ArrayList([]u8).init(allocator);
    defer {
        for (test_data_storage.items) |data| {
            allocator.free(data);
        }
        test_data_storage.deinit();
    }
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const op_type = random.intRangeAtMost(u8, 0, 3);
        
        switch (op_type) {
            0 => {
                const data_len = random.intRangeAtMost(usize, 0, 100);
                const data = try allocator.alloc(u8, data_len);
                random.bytes(data);
                try test_data_storage.append(data);
                
                const offset = random.intRangeAtMost(usize, 0, 1000);
                try operations.append(.{ .set_data = .{ .offset = offset, .data = data } });
            },
            1 => {
                const offset = random.intRangeAtMost(usize, 0, 1000);
                const value = random.int(u256);
                try operations.append(.{ .set_u256 = .{ .offset = offset, .value = value } });
            },
            2 => {
                const offset = random.intRangeAtMost(usize, 0, 1000);
                const length = random.intRangeAtMost(usize, 0, 100);
                try operations.append(.{ .get_data = .{ .offset = offset, .length = length } });
            },
            3 => {
                const new_size = random.intRangeAtMost(usize, 0, 2000);
                try operations.append(.{ .resize = new_size });
            },
            else => unreachable,
        }
    }
    
    try fuzz_memory_operations(allocator, operations.items);
}

test "fuzz_memory_edge_values" {
    const allocator = std.testing.allocator;
    
    const edge_values = [_]u256{
        0,
        1,
        std.math.maxInt(u8),
        std.math.maxInt(u16),
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
        1 << 128,
        1 << 255,
    };
    
    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();
    
    for (edge_values, 0..) |value, idx| {
        try operations.append(.{ .set_u256 = .{ .offset = idx * 32, .value = value } });
    }
    
    try fuzz_memory_operations(allocator, operations.items);
}

test "fuzz_memory_alignment_patterns" {
    const allocator = std.testing.allocator;
    
    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();
    
    // Test various alignment patterns
    const alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256 };
    
    for (alignments) |alignment| {
        const offset = alignment;
        try operations.append(.{ .set_u256 = .{ .offset = offset, .value = 0xDEADBEEF } });
        try operations.append(.{ .get_data = .{ .offset = offset, .length = 32 } });
    }
    
    try fuzz_memory_operations(allocator, operations.items);
}

test "fuzz_memory_bounded_operations" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    const source_data = "Hello, World! This is a test string for bounded operations.";
    
    // Test various bounded write scenarios
    const test_cases = [_]struct {
        memory_offset: usize,
        data_offset: usize,
        length: usize,
        should_succeed: bool,
    }{
        .{ .memory_offset = 0, .data_offset = 0, .length = 10, .should_succeed = true },
        .{ .memory_offset = 0, .data_offset = 50, .length = 20, .should_succeed = true }, // Partial copy
        .{ .memory_offset = 0, .data_offset = 100, .length = 10, .should_succeed = true }, // Zero fill
        .{ .memory_offset = 0, .data_offset = 0, .length = 0, .should_succeed = true }, // Empty
    };
    
    for (test_cases) |test_case| {
        const result = memory.set_data_bounded(
            test_case.memory_offset,
            source_data,
            test_case.data_offset,
            test_case.length,
        );
        
        if (test_case.should_succeed) {
            try result;
        } else {
            try std.testing.expectError(MemoryError.InvalidSize, result);
        }
    }
}

// Child Memory Tests

test "child_memory_creation_and_isolation" {
    const allocator = std.testing.allocator;
    
    var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer root.deinit();
    
    // Write data to root memory
    const root_data = "Root memory data";
    try root.set_data(0, root_data);
    
    // Create child at checkpoint 10
    var child = try root.init_child_memory(10);
    defer child.deinit();
    
    // Verify child properties
    try std.testing.expectEqual(false, child.owns_buffer);
    try std.testing.expectEqual(@as(usize, 10), child.my_checkpoint);
    try std.testing.expectEqual(root.shared_buffer_ref, child.shared_buffer_ref);
    try std.testing.expectEqual(root.memory_limit, child.memory_limit);
    
    // Child sees memory from its checkpoint
    try std.testing.expectEqual(@as(usize, root_data.len - 10), child.context_size());
}

test "child_memory_parent_child_interactions" {
    const allocator = std.testing.allocator;
    
    var parent = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer parent.deinit();
    
    // Parent writes initial data
    try parent.set_data(0, "Parent initial data");
    
    // Create child at checkpoint 7
    var child = try parent.init_child_memory(7);
    defer child.deinit();
    
    // Child writes data (at its offset 0 = parent offset 7)
    try child.set_data(0, "child writes");
    
    // Parent should see child's write at offset 7
    const parent_read = try parent.get_slice(7, 12);
    try std.testing.expectEqualSlices(u8, "child writes", parent_read);
    
    // Parent writes more data
    try parent.set_data(20, "parent continues");
    
    // Child should see parent's new data (at child offset 13 = parent offset 20)
    const child_read = try child.get_slice(13, 16);
    try std.testing.expectEqualSlices(u8, "parent continues", child_read);
}

test "multiple_children_sharing_buffer" {
    const allocator = std.testing.allocator;
    
    var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer root.deinit();
    
    // Create multiple children at different checkpoints
    var child1 = try root.init_child_memory(0);
    defer child1.deinit();
    
    var child2 = try root.init_child_memory(10);
    defer child2.deinit();
    
    var child3 = try root.init_child_memory(20);
    defer child3.deinit();
    
    // All children share the same buffer
    try std.testing.expectEqual(root.shared_buffer_ref, child1.shared_buffer_ref);
    try std.testing.expectEqual(root.shared_buffer_ref, child2.shared_buffer_ref);
    try std.testing.expectEqual(root.shared_buffer_ref, child3.shared_buffer_ref);
    
    // Each child writes at its offset 0
    try child1.set_data(0, "child1");
    try child2.set_data(0, "child2");
    try child3.set_data(0, "child3");
    
    // Verify all writes are visible in root
    const data1 = try root.get_slice(0, 6);
    const data2 = try root.get_slice(10, 6);
    const data3 = try root.get_slice(20, 6);
    
    try std.testing.expectEqualSlices(u8, "child1", data1);
    try std.testing.expectEqualSlices(u8, "child2", data2);
    try std.testing.expectEqualSlices(u8, "child3", data3);
}

// Memory Ownership Tests

test "memory_ownership_buffer_cleanup" {
    const allocator = std.testing.allocator;
    
    // Test 1: Root owns buffer and cleans up
    {
        var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
        try std.testing.expectEqual(true, root.owns_buffer);
        root.deinit(); // Should clean up buffer
    }
    
    // Test 2: Child doesn't own buffer and doesn't clean up
    {
        var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
        defer root.deinit();
        
        var child = try root.init_child_memory(10);
        try std.testing.expectEqual(false, child.owns_buffer);
        child.deinit(); // Should not affect shared buffer
        
        // Root should still be able to use buffer
        try root.set_data(0, "still works");
    }
}

test "memory_ownership_multiple_children_cleanup" {
    const allocator = std.testing.allocator;
    
    var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer root.deinit();
    
    // Create and destroy multiple children
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var child = try root.init_child_memory(i * 10);
        try std.testing.expectEqual(false, child.owns_buffer);
        try child.set_data(0, "test");
        child.deinit(); // Should not affect buffer
    }
    
    // Root should still work fine
    try root.set_data(100, "root still owns buffer");
    const data = try root.get_slice(100, 22);
    try std.testing.expectEqualSlices(u8, "root still owns buffer", data);
}

// Gas Cost Calculation Tests

test "gas_cost_calculate_num_words_edge_cases" {
    const testing = std.testing;
    
    // Test edge cases for word calculation
    try testing.expectEqual(@as(usize, 0), calculate_num_words(0));
    try testing.expectEqual(@as(usize, 1), calculate_num_words(1));
    try testing.expectEqual(@as(usize, 1), calculate_num_words(31));
    try testing.expectEqual(@as(usize, 1), calculate_num_words(32));
    try testing.expectEqual(@as(usize, 2), calculate_num_words(33));
    try testing.expectEqual(@as(usize, 2), calculate_num_words(63));
    try testing.expectEqual(@as(usize, 2), calculate_num_words(64));
    try testing.expectEqual(@as(usize, 3), calculate_num_words(65));
    
    // Large values
    try testing.expectEqual(@as(usize, 32), calculate_num_words(1024));
    try testing.expectEqual(@as(usize, 1024), calculate_num_words(32768));
    
    // Maximum safe values
    const max_safe = std.math.maxInt(usize) - 31;
    try testing.expectEqual(@as(usize, (max_safe + 31) / 32), calculate_num_words(max_safe));
}

test "memory_expansion_gas_tracking" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    // Track gas costs for various expansions
    const expansions = [_]struct {
        target_size: usize,
        expected_new_words: u64,
    }{
        .{ .target_size = 32, .expected_new_words = 1 },
        .{ .target_size = 64, .expected_new_words = 1 },
        .{ .target_size = 96, .expected_new_words = 1 },
        .{ .target_size = 128, .expected_new_words = 1 },
        .{ .target_size = 256, .expected_new_words = 4 },
        .{ .target_size = 512, .expected_new_words = 8 },
        .{ .target_size = 1024, .expected_new_words = 16 },
    };
    
    for (expansions) |expansion| {
        const new_words = try memory.ensure_context_capacity(expansion.target_size);
        try std.testing.expectEqual(expansion.expected_new_words, new_words);
    }
}

// Extended Invariant Tests

test "memory_invariants_checkpoint_bounds" {
    const allocator = std.testing.allocator;
    
    var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer root.deinit();
    
    // Expand root memory
    try root.set_data(0, "x");
    try root.set_data(99, "x");
    
    // Create children and verify checkpoint invariants
    const checkpoints = [_]usize{ 0, 10, 50, 100 };
    for (checkpoints) |checkpoint| {
        var child = try root.init_child_memory(checkpoint);
        defer child.deinit();
        
        // Invariant: checkpoint never exceeds buffer size
        try std.testing.expect(child.my_checkpoint <= child.shared_buffer_ref.items.len);
        
        // Invariant: child checkpoint >= parent checkpoint (parent is 0)
        try std.testing.expect(child.my_checkpoint >= root.my_checkpoint);
    }
}

test "memory_invariants_size_monotonic_growth" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    var prev_size: usize = 0;
    
    // Perform various operations and verify size only grows
    const operations = [_]struct {
        offset: usize,
        data: []const u8,
    }{
        .{ .offset = 0, .data = "test" },
        .{ .offset = 10, .data = "more data" },
        .{ .offset = 5, .data = "overlap" }, // Should not shrink
        .{ .offset = 50, .data = "expand" },
        .{ .offset = 30, .data = "fill gap" }, // Should not shrink
    };
    
    for (operations) |op| {
        try memory.set_data(op.offset, op.data);
        const current_size = memory.context_size();
        
        // Invariant: memory size grows monotonically
        try std.testing.expect(current_size >= prev_size);
        prev_size = current_size;
    }
}

test "memory_invariants_single_owner" {
    const allocator = std.testing.allocator;
    
    var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer root.deinit();
    
    // Root should own buffer
    try std.testing.expectEqual(true, root.owns_buffer);
    
    // Create multiple children
    var children: [5]Memory = undefined;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        children[i] = try root.init_child_memory(i * 10);
    }
    
    // Verify only root owns buffer
    var owner_count: usize = 0;
    if (root.owns_buffer) owner_count += 1;
    
    for (&children) |*child| {
        if (child.owns_buffer) owner_count += 1;
        child.deinit();
    }
    
    // Invariant: only one owner per shared buffer
    try std.testing.expectEqual(@as(usize, 1), owner_count);
}

// Real EVM Pattern Tests

test "evm_pattern_mload_mstore_sequences" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    // Simulate typical MLOAD/MSTORE patterns
    // Pattern 1: Sequential writes (common in array operations)
    var offset: usize = 0;
    while (offset < 256) : (offset += 32) {
        try memory.set_u256(offset, @as(u256, offset / 32));
    }
    
    // Pattern 2: Random access reads (common in mapping lookups)
    const read_offsets = [_]usize{ 64, 0, 128, 32, 192, 96 };
    for (read_offsets) |read_offset| {
        const value = try memory.get_u256(read_offset);
        try std.testing.expectEqual(@as(u256, read_offset / 32), value);
    }
    
    // Pattern 3: Overlapping writes (common in string operations)
    try memory.set_data(300, "Hello, ");
    try memory.set_data(307, "World!");
    const combined = try memory.get_slice(300, 13);
    try std.testing.expectEqualSlices(u8, "Hello, World!", combined);
}

test "evm_pattern_calldatacopy_simulation" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    // Simulate CALLDATACOPY patterns
    const calldata = "function transfer(address to, uint256 amount) external";
    
    // Copy function selector (first 4 bytes)
    try memory.set_data_bounded(0, calldata, 0, 4);
    
    // Copy parameters (typically at offset 4)
    try memory.set_data_bounded(32, calldata, 4, 32);
    try memory.set_data_bounded(64, calldata, 36, 32);
    
    // Verify memory layout matches EVM expectations
    const selector = try memory.get_slice(0, 4);
    try std.testing.expectEqualSlices(u8, "func", selector);
}

test "evm_pattern_create2_memory_usage" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    // CREATE2 uses memory for: salt (32 bytes) + init code
    const salt_offset: usize = 0;
    const init_code_offset: usize = 32;
    
    // Write salt
    const salt: u256 = 0xDEADBEEFCAFEBABE;
    try memory.set_u256(salt_offset, salt);
    
    // Write init code (typical contract creation bytecode)
    const init_code = [_]u8{
        0x60, 0x80, 0x60, 0x40, 0x52, // PUSH1 0x80 PUSH1 0x40 MSTORE
        0x34, 0x80, 0x15, 0x61, 0x00, // CALLVALUE DUP1 ISZERO PUSH2 0x00
    };
    try memory.set_data(init_code_offset, &init_code);
    
    // Verify memory expansion for CREATE2
    const expected_size = init_code_offset + init_code.len;
    try std.testing.expectEqual(expected_size, memory.context_size());
}

// Performance Stress Tests

test "performance_stress_large_allocations" {
    const allocator = std.testing.allocator;
    
    // Test with reduced memory limit for stress testing
    const stress_limit: u64 = 1024 * 1024; // 1MB limit
    var memory = try init(allocator, INITIAL_CAPACITY, stress_limit);
    defer memory.deinit();
    
    // Test near-limit allocation
    const large_size = stress_limit - 1024;
    _ = try memory.ensure_context_capacity(large_size);
    
    // Verify we can still write at the edge
    try memory.set_u256(large_size - 32, std.math.maxInt(u256));
    
    // Test that exceeding limit fails
    try std.testing.expectError(
        MemoryError.MemoryLimitExceeded, 
        memory.ensure_context_capacity(stress_limit + 1)
    );
}

test "performance_stress_rapid_resize_cycles" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    // Rapid expansion and contraction cycles
    const sizes = [_]usize{ 32, 1024, 64, 2048, 128, 4096, 256, 8192 };
    
    var cycle: usize = 0;
    while (cycle < 5) : (cycle += 1) {
        for (sizes) |target_size| {
            _ = try memory.ensure_context_capacity(target_size);
            
            // Write data at various offsets
            if (target_size >= 32) {
                try memory.set_u256(0, @as(u256, target_size));
                try memory.set_u256(target_size - 32, @as(u256, cycle));
            }
        }
    }
    
    // Verify memory integrity after stress
    try validate_memory_invariants(&memory);
}

test "performance_stress_fragmentation_patterns" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    // Create fragmentation pattern: write at sparse offsets
    const sparse_offsets = [_]usize{ 0, 100, 50, 200, 25, 150, 75, 250 };
    
    for (sparse_offsets) |offset| {
        try memory.set_data(offset, "fragment");
    }
    
    // Fill gaps with different sized writes
    try memory.set_data(10, "small");
    try memory.set_data(60, "medium sized data");
    try memory.set_data(110, "large chunk of data for testing");
    
    // Verify all data is intact
    for (sparse_offsets) |offset| {
        const data = try memory.get_slice(offset, 8);
        try std.testing.expectEqualSlices(u8, "fragment", data);
    }
}

// Concurrent Access Pattern Tests

test "concurrent_pattern_multiple_contexts" {
    const allocator = std.testing.allocator;
    
    // Create multiple independent memory contexts
    var memories: [5]Memory = undefined;
    for (&memories) |*mem| {
        mem.* = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    }
    defer for (&memories) |*mem| {
        mem.deinit();
    };
    
    // Each memory writes unique data
    for (&memories, 0..) |*mem, i| {
        var buf: [16]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "memory_{}", .{i});
        try mem.set_data(0, &buf);
    }
    
    // Verify no interference between memories
    for (&memories, 0..) |*mem, i| {
        const data = try mem.get_slice(0, 8);
        var expected: [16]u8 = undefined;
        _ = try std.fmt.bufPrint(&expected, "memory_{}", .{i});
        try std.testing.expectEqualSlices(u8, expected[0..8], data);
    }
}

test "concurrent_pattern_checkpoint_isolation" {
    const allocator = std.testing.allocator;
    
    var root = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer root.deinit();
    
    // Create children at different checkpoints
    var child1 = try root.init_child_memory(0);
    defer child1.deinit();
    
    var child2 = try root.init_child_memory(100);
    defer child2.deinit();
    
    // Each context writes at offset 0 (their local view)
    try child1.set_data(0, "child1 data");
    try child2.set_data(0, "child2 data");
    
    // Verify checkpoint isolation
    const data1 = try root.get_slice(0, 11);
    const data2 = try root.get_slice(100, 11);
    
    try std.testing.expectEqualSlices(u8, "child1 data", data1);
    try std.testing.expectEqualSlices(u8, "child2 data", data2);
    
    // Verify children see their own writes at offset 0
    const child1_read = try child1.get_slice(0, 11);
    const child2_read = try child2.get_slice(0, 11);
    
    try std.testing.expectEqualSlices(u8, "child1 data", child1_read);
    try std.testing.expectEqualSlices(u8, "child2 data", child2_read);
}
